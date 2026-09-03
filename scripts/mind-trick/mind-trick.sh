#!/usr/bin/env bash
# description: Scrub commit-message trailers from git history via the mind-trick engine
# -----------------------------------------------------------------------------
# mind-trick.sh — gum front-end for the mind-trick git-history-scrub engine.
#
# scomp-link owns the interactive experience (this file); the logic lives in the
# standalone mind-trick engine (its own repo). This shim resolves the engine
# (local checkout → cache → clone), lets you pick a repo, and runs the engine
# with the matching flags — the holo-convert / navicomputer pattern.
#
# Engine resolution order:
#   1. $MIND_TRICK_DIR/mind-trick.sh          (explicit override)
#   2. ../../../mind-trick/mind-trick.sh      (sibling dev checkout)
#   3. ~/.cache/scomp-link/mind-trick/…       (cached clone; offers git pull)
#   4. git clone --depth 1 (public HTTPS)     (first run)
# -----------------------------------------------------------------------------

if [[ "${BASH_VERSINFO[0]:-0}" -lt 4 ]]; then
    echo "[error] bash 4+ required (you have ${BASH_VERSION}). On macOS: brew install bash" >&2
    exit 1
fi

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../_common/ui.sh
source "${SCRIPT_DIR}/../_common/ui.sh"

command -v gum &>/dev/null || { echo "[error] gum is required. Run setup.sh first." >&2; exit 1; }
command -v git &>/dev/null || { echo "[error] git is required." >&2; exit 1; }

MT_REPO="${MIND_TRICK_REPO:-https://github.com/malahmen/mind-trick.git}"
MT_CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/scomp-link/mind-trick"
ENGINE=""

resolve_engine() {
    if [[ -n "${MIND_TRICK_DIR:-}" && -f "${MIND_TRICK_DIR}/mind-trick.sh" ]]; then
        ENGINE="${MIND_TRICK_DIR}/mind-trick.sh"; info "Using mind-trick from \$MIND_TRICK_DIR: ${MIND_TRICK_DIR}"; return
    fi
    local sib="${SCRIPT_DIR}/../../../mind-trick/mind-trick.sh"
    if [[ -f "$sib" ]]; then
        ENGINE="$(cd "$(dirname "$sib")" && pwd)/mind-trick.sh"; info "Using local mind-trick checkout: $(dirname "$ENGINE")"; return
    fi
    if [[ -f "${MT_CACHE}/mind-trick.sh" ]]; then
        ENGINE="${MT_CACHE}/mind-trick.sh"; info "Using cached mind-trick: ${MT_CACHE}"
        if [[ -d "${MT_CACHE}/.git" ]] && gum confirm "Update mind-trick (git pull)?"; then
            gum spin --spinner dot --title "Updating mind-trick..." -- git -C "$MT_CACHE" pull --ff-only || warn "Update failed; using existing copy."
        fi
        return
    fi
    gum confirm "mind-trick engine not found. Clone it from ${MT_REPO}?" || error_exit "mind-trick engine is unavailable."
    mkdir -p "$(dirname "$MT_CACHE")"
    gum spin --spinner dot --title "Cloning mind-trick..." -- git clone --depth 1 "$MT_REPO" "$MT_CACHE" \
        || error_exit "Failed to clone mind-trick from ${MT_REPO}"
    ENGINE="${MT_CACHE}/mind-trick.sh"; success "mind-trick cloned to ${MT_CACHE}"
}

engine() { bash "$ENGINE" "$@"; }

# Ask for a git repo OR a folder of repos; if a folder, pick exactly one (this
# is a sensitive op — never batch). Echoes the chosen repo path.
pick_repo() {
    local base
    base=$(gum input --value "$(pwd)" --header "Path to a git repo, or a folder containing repos:") || return 1
    base="${base/#\~/$HOME}"
    [[ -d "$base" ]] || { warn "Not a directory: $base"; return 1; }
    if git -C "$base" rev-parse --is-inside-work-tree &>/dev/null; then printf '%s' "$base"; return 0; fi
    local repos
    repos=$(find "$base" -mindepth 2 -maxdepth 2 -type d -name .git 2>/dev/null | sed 's|/\.git$||' | sort)
    [[ -n "$repos" ]] || { warn "No git repositories found in or under: $base"; return 1; }
    printf '%s\n' "$repos" | gum choose --header "Select a repository:"
}

main() {
    resolve_engine
    header "mind-trick — scrub git history"

    local repo; repo=$(pick_repo) || { info "Cancelled."; exit 0; }
    [[ -n "$repo" ]] || { info "Cancelled."; exit 0; }
    info "Repository: $repo"

    local pattern
    pattern=$(gum input --value '^Co-Authored-By: Claude' \
        --header "Remove commit-message lines matching (grep -iE):") || exit 0
    [[ -n "$pattern" ]] || { warn "A pattern is required."; exit 0; }

    # Show the dry-run report (engine). If nothing matches, we're done.
    if ! git -C "$repo" log --all -i -E --grep="$pattern" --format='%H' 2>/dev/null | grep -q .; then
        engine --repo "$repo" --pattern "$pattern" || true
        exit 0
    fi
    engine --repo "$repo" --pattern "$pattern" || true   # prints the matches

    gum confirm "Rewrite history to remove them? (a backup bundle is made first)" \
        || { info "Cancelled — nothing changed."; exit 0; }
    local push_args=()
    gum confirm "Also force-push the rewritten branches now?" && push_args=(--push)
    engine --repo "$repo" --pattern "$pattern" --apply "${push_args[@]}"
}

main "$@"
