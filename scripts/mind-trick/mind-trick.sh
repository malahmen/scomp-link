#!/usr/bin/env bash
# description: Scrub commit-message trailers from git history ("these aren't the commits you're looking for")
# export-setup: git
# -----------------------------------------------------------------------------
# mind-trick.sh — remove matching trailer lines (e.g. Co-Authored-By: Claude)
# from every commit message across all branches of a repo, then optionally
# force-push. Safe by default: dry-run unless --apply, always backs up first.
#
# Runs flag-driven (scriptable / exportable) or, with no args, via a gum flow.
#
# WARNING: --apply rewrites history and --push force-pushes it. It CANNOT touch
# GitHub's refs/pull/* — merged-PR pages keep their old commits; only branch
# history (and the Contributors graph, on recompute) is cleaned.
# -----------------------------------------------------------------------------

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Shared helpers: ../_common in the repo, or alongside this script when exported.
if [[ -d "${SCRIPT_DIR}/../_common" ]]; then COMMON_DIR="${SCRIPT_DIR}/../_common"; else COMMON_DIR="${SCRIPT_DIR}"; fi
if [[ ! -f "${COMMON_DIR}/ui.sh" ]]; then
    printf "\033[0;31m[ERROR] ui.sh not found in %s\033[0m\n" "$COMMON_DIR" >&2; exit 1
fi
# shellcheck source=../_common/ui.sh
source "${COMMON_DIR}/ui.sh"

command -v git &>/dev/null || error_exit "git is required."

# Defaults
REPO="."
PATTERN='^Co-Authored-By: Claude'   # grep -iE, matched per message line
APPLY=false
PUSH=false
ASSUME_YES=false
BACKUP_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/scomp-link/mind-trick"

usage() {
    cat >&2 <<'EOF'
mind-trick — scrub commit-message trailers from git history

USAGE
  mind-trick.sh [--repo DIR] [--pattern REGEX] [--apply] [--push] [--yes]
  mind-trick.sh                # no args → interactive (gum)

FLAGS
  --repo DIR       repository to operate on (default: current directory)
  --pattern REGEX  message lines to remove (grep -iE); default '^Co-Authored-By: Claude'
  --apply          actually rewrite history (default: dry-run only)
  --push           force-push the rewritten branches after --apply
  --yes            skip confirmations (non-interactive)
  -h, --help

Safe by default: without --apply it only reports. --apply always writes a
git bundle backup first. It cannot remove commits kept by GitHub's refs/pull/*
(merged-PR pages) — only branch history + the Contributors graph clear.
EOF
}

# ---- helpers ----------------------------------------------------------------
_git()  { git -C "$REPO" "$@"; }

_matching_commits() { _git log --all -i -E --grep="$PATTERN" --format='%H'; }

_report() {
    local n; n=$(_matching_commits | wc -l | tr -d ' ')
    if [[ "$n" -eq 0 ]]; then success "No commits match /$PATTERN/ — nothing to do."; return 1; fi
    warn "${n} commit(s) contain a line matching /$PATTERN/:"
    _git log --all -i -E --grep="$PATTERN" --format='  %h %an | %s' | head -20 >&2
    info "Affected branches:"
    local b
    while IFS= read -r b; do
        [[ -z "$b" ]] && continue
        [[ -n "$(_git log "$b" -i -E --grep="$PATTERN" --format='%H' | head -1)" ]] && printf '    %s\n' "$b" >&2
    done < <(_git for-each-ref --format='%(refname:short)' refs/heads)
    return 0
}

_backup() {
    mkdir -p "$BACKUP_DIR"
    local name ts bundle
    name=$(basename "$(cd "$REPO" && pwd)")
    ts=$(date +%Y%m%d-%H%M%S)
    bundle="${BACKUP_DIR}/${name}-${ts}.bundle"
    _git bundle create "$bundle" --all >&2 && success "Backup: $bundle (restore: git clone $bundle)"
}

_rewrite() {
    # Build a msg-filter helper that drops lines matching the pattern; trailing
    # blank lines fall away via command substitution.
    local helper esc; helper=$(mktemp)
    esc=$(printf '%s' "$PATTERN" | sed "s/'/'\\\\''/g")   # single-quote-safe
    cat > "$helper" <<EOF
#!/usr/bin/env bash
export PATH=/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin
msg="\$(cat)"
msg="\$(printf '%s\n' "\$msg" | grep -v -iE '${esc}' || true)"
printf '%s\n' "\$msg"
EOF
    FILTER_BRANCH_SQUELCH_WARNING=1 _git filter-branch -f --msg-filter "bash '$helper'" -- --all >&2
    rm -f "$helper"
    # cleanup backups + reflog so old objects can be pruned
    _git for-each-ref --format='%(refname)' refs/original/ 2>/dev/null | while read -r r; do _git update-ref -d "$r"; done
    _git reflog expire --expire=now --all 2>/dev/null || true
    _git gc --prune=now --quiet 2>/dev/null || true
}

_force_push() {
    local b
    while IFS= read -r b; do
        [[ -z "$b" ]] && continue
        _git show-ref --verify --quiet "refs/remotes/origin/$b" || { info "skip $b (no origin branch)"; continue; }
        if _git push --force origin "$b" >&2; then success "force-pushed $b"; else warn "push failed: $b"; fi
    done < <(_git for-each-ref --format='%(refname:short)' refs/heads)
    warn "GitHub keeps merged-PR commits via refs/pull/* — those pages still show old commits; the Contributors graph clears on recompute."
}

_preflight() {
    _git rev-parse --is-inside-work-tree &>/dev/null || error_exit "Not a git repository: $REPO"
    [[ -z "$(_git status --porcelain)" ]] || error_exit "Working tree not clean in $REPO — commit/stash first."
}

# Ask for a repo OR a folder of repos. If a folder, list the git repos inside it
# and let the user pick exactly one (this is a sensitive op — never batch).
# Echoes the chosen repo path.
pick_repo() {
    local base
    base=$(gum input --value "$(pwd)" \
        --header "Path to a git repo, or a folder containing repos:") || return 1
    base="${base/#\~/$HOME}"
    [[ -d "$base" ]] || { warn "Not a directory: $base"; return 1; }
    # The path is itself a repo → use it directly.
    if git -C "$base" rev-parse --is-inside-work-tree &>/dev/null; then
        printf '%s' "$base"; return 0
    fi
    # Otherwise scan one level down for repos and pick one.
    local repos
    repos=$(find "$base" -mindepth 2 -maxdepth 2 -type d -name .git 2>/dev/null | sed 's|/\.git$||' | sort)
    [[ -n "$repos" ]] || { warn "No git repositories found in or under: $base"; return 1; }
    printf '%s\n' "$repos" | gum choose --header "Select a repository:"
}

# ---- interactive (gum) ------------------------------------------------------
run_interactive() {
    command -v gum &>/dev/null || error_exit "gum is required for interactive mode (or pass flags)."
    header "mind-trick — scrub git history"
    REPO=$(pick_repo) || { info "Cancelled."; exit 0; }
    [[ -n "$REPO" ]] || { info "Cancelled."; exit 0; }
    info "Repository: $REPO"
    _preflight
    PATTERN=$(gum input --value "$PATTERN" --header "Remove message lines matching (grep -iE):") || exit 0
    _report || exit 0
    gum confirm "Rewrite history to remove them? (a backup bundle is made first)" || { info "Cancelled."; exit 0; }
    _backup
    _rewrite
    _report >/dev/null && warn "Some still match — check the pattern." || success "History cleaned locally."
    if gum confirm "Force-push the rewritten branches to origin now?"; then _force_push; else
        info "Not pushed. Review, then: cd $REPO && git push --force origin <branch>"
    fi
}

# ---- flag-driven ------------------------------------------------------------
run_flags() {
    _preflight
    if ! _report; then exit 0; fi
    if [[ "$APPLY" != true ]]; then
        info "Dry run — re-run with --apply to rewrite (and --push to force-push)."; exit 0
    fi
    if [[ "$ASSUME_YES" != true ]]; then
        command -v gum &>/dev/null && { gum confirm "Rewrite history in $REPO?" || { info "Cancelled."; exit 0; }; }
    fi
    _backup
    _rewrite
    success "History cleaned locally."
    if [[ "$PUSH" == true ]]; then
        if [[ "$ASSUME_YES" == true ]] || { command -v gum &>/dev/null && gum confirm "Force-push rewritten branches?"; }; then
            _force_push
        fi
    else
        info "Not pushed. Use --push, or: cd $REPO && git push --force origin <branch>"
    fi
}

main() {
    if [[ $# -eq 0 ]]; then run_interactive; return; fi
    while [[ $# -gt 0 ]]; do case "$1" in
        --repo) REPO="$2"; shift 2 ;;
        --pattern) PATTERN="$2"; shift 2 ;;
        --apply) APPLY=true; shift ;;
        --push) PUSH=true; shift ;;
        --yes|-y) ASSUME_YES=true; shift ;;
        -h|--help) usage; exit 0 ;;
        *) usage; error_exit "unknown flag: $1" ;;
    esac; done
    REPO="${REPO/#\~/$HOME}"
    run_flags
}

main "$@"
