#!/usr/bin/env bash
# description: Keep every git repo under your folders fresh (commit/stash + pull --rebase) and tidy merged local branches
# Standalone export (export.sh): no extra setup deps — the engine needs only git.
# -----------------------------------------------------------------------------
# astromech.sh — gum front-end for the astromech engine.
#
# scomp-link owns the interactive experience (this file): first-run setup (the
# folders holding repos, then a multi-select of their top-level folders to
# ignore), the one-time "run maintenance now?" prompt, and the menu. The repo
# logic lives in the standalone astromech engine (its own repo): a gum-free,
# flag-driven CLI that also runs from cron. This shim resolves the engine
# (local checkout → cache → clone) and drives it by flags — the holonet-sync
# pattern.
#
# The engine owns the config (~/.config/astromech/astromech.conf); this file
# never reads or writes it directly, it asks the engine (`config`, `roots`,
# `children`) so the menus always match what a run would actually do.
#
# Two of the engine's commands need care here:
#
#   tidy   deletes local branches the trunk already holds, and asks on
#          /dev/tty before it does. That is right for cron and wrong inside
#          gum, so this front-end uses the flags the engine has for exactly
#          this: --dry-run to get the plan, gum to ask, then --yes.
#   prune  toggles git's global fetch.prune. Its explanation is left to stream
#          from the engine rather than restated here — one copy, one place to
#          keep right.
#
# The engine can also be OLDER than this front-end (a stale cached clone), so
# the menu is built from the commands the engine actually reports.
#
# Engine resolution order:
#   1. $ASTROMECH_DIR/astromech.sh             (explicit override)
#   2. ../../../astromech/astromech.sh         (sibling dev checkout)
#   3. ~/.cache/scomp-link/astromech/…         (cached clone; offers git pull)
#   4. git clone --depth 1 (public HTTPS)      (first run)
#
# Sourced helpers (scripts/_common/):
#   ui.sh — header/info/success/warn/error_exit
# -----------------------------------------------------------------------------

if [[ "${BASH_VERSINFO[0]:-0}" -lt 4 ]]; then
    echo "[error] bash 4+ required (you have ${BASH_VERSION}). On macOS: brew install bash" >&2
    exit 1
fi

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Vendor-aware: ../_common in the repo, or alongside this script when exported.
if [[ -d "${SCRIPT_DIR}/../_common" ]]; then
    COMMON_DIR="${SCRIPT_DIR}/../_common"   # scomp-link repo layout
else
    COMMON_DIR="${SCRIPT_DIR}"              # exported standalone: deps sit alongside
fi
# shellcheck source=../_common/ui.sh
source "${COMMON_DIR}/ui.sh"

command -v gum &>/dev/null || { echo "[error] gum is required. Run setup.sh first." >&2; exit 1; }
command -v git &>/dev/null || { echo "[error] git is required." >&2; exit 1; }

ASTROMECH_REPO="${ASTROMECH_REPO:-https://github.com/malahmen/astromech.git}"
ASTROMECH_CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/scomp-link/astromech"
ENGINE=""

# Engine-reported state, filled by _engine_state.
CONFIG_PATH=""; ONBOARDED=0; N_ROOTS=0

trap 'echo ""; gum style --faint "Interrupted."; exit 0' INT TERM

# -----------------------------------------------------------------------------
# Resolve the astromech engine (override → sibling → cache → clone).
# -----------------------------------------------------------------------------
resolve_engine() {
    if [[ -n "${ASTROMECH_DIR:-}" && -f "${ASTROMECH_DIR}/astromech.sh" ]]; then
        ENGINE="${ASTROMECH_DIR}/astromech.sh"; info "Using astromech from \$ASTROMECH_DIR: ${ASTROMECH_DIR}"; return
    fi
    local sib="${SCRIPT_DIR}/../../../astromech/astromech.sh"
    if [[ -f "$sib" ]]; then
        ENGINE="$(cd "$(dirname "$sib")" && pwd)/astromech.sh"; info "Using local astromech checkout: $(dirname "$ENGINE")"; return
    fi
    if [[ -f "${ASTROMECH_CACHE}/astromech.sh" ]]; then
        ENGINE="${ASTROMECH_CACHE}/astromech.sh"; info "Using cached astromech: ${ASTROMECH_CACHE}"
        if [[ -d "${ASTROMECH_CACHE}/.git" ]] && gum confirm "Update astromech (git pull)?"; then
            gum spin --spinner dot --title "Updating astromech..." -- \
                git -C "$ASTROMECH_CACHE" pull --ff-only || warn "Update failed; using the existing copy."
        fi
        return
    fi
    gum confirm "astromech engine not found. Clone it from ${ASTROMECH_REPO}?" \
        || error_exit "astromech engine is unavailable."
    mkdir -p "$(dirname "$ASTROMECH_CACHE")"
    gum spin --spinner dot --title "Cloning astromech..." -- \
        git clone --depth 1 "$ASTROMECH_REPO" "$ASTROMECH_CACHE" \
        || error_exit "Failed to clone astromech from ${ASTROMECH_REPO}"
    ENGINE="${ASTROMECH_CACHE}/astromech.sh"; success "astromech cloned to ${ASTROMECH_CACHE}"
}

# Run the engine. engine_foreground is for maintain: Ctrl-C stops just the
# child and returns to the menu instead of killing the TUI.
engine() { bash "$ENGINE" "$@"; }
engine_foreground() {
    trap ':' INT
    bash "$ENGINE" "$@" || true
    trap 'echo ""; gum style --faint "Interrupted."; exit 0' INT TERM
}

# -----------------------------------------------------------------------------
# Engine-reported state / small gum helpers
# -----------------------------------------------------------------------------

# The resolved engine can be an older clone than this front-end — the cache is
# only updated when you say yes to the pull. Offering a menu item for a command
# it does not have would fail with "unknown command" after the user picked it,
# so the menu is built from what the engine reports in its own help.
ENGINE_CMDS=""
_engine_commands() {
    ENGINE_CMDS=" $(engine --help 2>&1 | sed -n '/^COMMANDS/,/^FLAGS/p' \
        | sed -nE 's/^  ([a-z-]+).*/\1/p' | tr '\n' ' ')"
}
_engine_has() { [[ "$ENGINE_CMDS" == *" $1 "* ]]; }

# Engine logs captured to a file carry a UTC timestamp — the engine adds one
# when its stderr is not a terminal. Strip it and surface only the lines that
# need a person: a repository it had to skip, or a deletion git refused.
_engine_notes() {
    sed -nE 's/^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]+Z //; /\[(warn|error)\]/p' "$1"
}

_engine_state() {
    local key val
    CONFIG_PATH=""; ONBOARDED=0; N_ROOTS=0
    while IFS='=' read -r key val; do
        case "$key" in
            config)    CONFIG_PATH="$val" ;;
            onboarded) ONBOARDED="$val" ;;
            roots)     N_ROOTS="$val" ;;
        esac
    done < <(engine config 2>/dev/null)
    [[ -n "$CONFIG_PATH" ]] || error_exit "The engine did not report its config — is ${ENGINE} runnable?"
}

# _ask <prompt> — 0 yes, 1 no, 2 cancelled. gum confirm exits 130 on Esc /
# Ctrl-C, which a plain `gum confirm … && …` would read as "no" and carry on.
_ask() {
    local rc=0
    gum confirm "$@" || rc=$?
    case "$rc" in
        0)   return 0 ;;
        130) return 2 ;;
        *)   return 1 ;;
    esac
}

# Echoes the chosen root; returns 1 on cancel. A single root is picked silently.
_pick_root() {
    local header="$1" roots
    mapfile -t roots < <(engine roots 2>/dev/null)
    (( ${#roots[@]} )) || { warn "No repository paths configured yet."; return 1; }
    (( ${#roots[@]} == 1 )) && { printf '%s' "${roots[0]}"; return 0; }
    local choice
    choice=$(printf '%s\n' "${roots[@]}" | gum choose --header "$header") || return 1
    [[ -n "$choice" ]] || return 1
    printf '%s' "$choice"
}

# Echoes the chosen repository; returns 1 on cancel. _pick_root's sibling, over
# `repos` (root<TAB>repo) instead of `roots`. A single repo is picked silently.
_pick_repo() {
    local hdr="$1" repos=() root repo choice
    while IFS=$'\t' read -r root repo; do
        [[ -n "$repo" ]] && repos+=("$repo")
    done < <(engine repos 2>/dev/null)
    (( ${#repos[@]} )) || { warn "No repositories found under the configured paths."; return 1; }
    (( ${#repos[@]} == 1 )) && { printf '%s' "${repos[0]}"; return 0; }
    choice=$(printf '%s\n' "${repos[@]}" | gum choose --header "$hdr") || return 1
    [[ -n "$choice" ]] || return 1
    printf '%s' "$choice"
}

# -----------------------------------------------------------------------------
# Actions
# -----------------------------------------------------------------------------

# Prompt for folders holding repos until the user is done. The newly added
# roots land in ADDED_ROOTS, so the caller can ask ignores for each.
ADDED_ROOTS=()
action_add_paths() {
    ADDED_ROOTS=()
    local path added rc
    while true; do
        # shellcheck disable=SC2088  # a literal placeholder; the engine expands ~
        path=$(gum input --placeholder "~/code" --width 70 \
            --header "Folder holding git repositories (empty to finish):") || break
        [[ -n "$path" ]] || break
        # The engine prints the normalised path it added (nothing for a duplicate).
        if added="$(engine add-root "$path")" && [[ -n "$added" ]]; then
            ADDED_ROOTS+=("$added")
        fi
        rc=0; _ask "Add another folder?" || rc=$?
        (( rc == 0 )) || break
    done
}

# action_edit_ignores_for <root> — multi-select of its top-level folders, with
# the currently ignored ones preselected. Enter with nothing selected clears.
action_edit_ignores_for() {
    local root="$1" names=() ignored=() name flag picked rc
    while IFS=$'\t' read -r name flag; do
        names+=("$name"); [[ "$flag" == 1 ]] && ignored+=("$name")
    done < <(engine children "$root" 2>/dev/null)
    if (( ${#names[@]} == 0 )); then info "${root} has no subfolders — nothing to ignore."; return 0; fi

    local sel_args=()
    (( ${#ignored[@]} )) && sel_args=(--selected "$(IFS=,; echo "${ignored[*]}")")
    rc=0
    picked=$(printf '%s\n' "${names[@]}" | gum choose --no-limit "${sel_args[@]}" \
        --header "Folders to IGNORE in ${root/#$HOME/\~} (space toggles, enter confirms, none = ignore nothing):") || rc=$?
    (( rc == 0 )) || { info "Cancelled — ignored folders unchanged."; return 0; }

    local chosen=()
    [[ -n "$picked" ]] && mapfile -t chosen <<< "$picked"
    engine set-ignores "$root" "${chosen[@]}" || warn "Could not update ignored folders."
}

action_edit_ignores() {
    header "Astromech — Ignored folders"
    local root
    root="$(_pick_root "Edit ignored folders of which path?")" || return 0
    action_edit_ignores_for "$root"
}

action_edit_paths() {
    while true; do
        header "Astromech — Repository paths"
        engine roots 2>/dev/null | sed 's/^/  • /' || true
        local choice
        choice=$(gum choose "Add a path" "Remove a path" "← back" --header "Repository paths:") || return 0
        case "$choice" in
            "Add a path")
                action_add_paths
                local r; for r in "${ADDED_ROOTS[@]}"; do action_edit_ignores_for "$r"; done
                ;;
            "Remove a path")
                local roots picked=()
                mapfile -t roots < <(engine roots 2>/dev/null)
                (( ${#roots[@]} )) || { warn "No paths to remove."; continue; }
                local out; out=$(printf '%s\n' "${roots[@]}" | gum choose --no-limit \
                    --header "Paths to REMOVE (space toggles; their ignored folders go too):") || continue
                [[ -n "$out" ]] || continue
                mapfile -t picked <<< "$out"
                _ask "Remove ${#picked[@]} path(s)? Repositories on disk are not touched." || continue
                engine remove-root "${picked[@]}" || warn "Could not remove path(s)."
                ;;
            *) return 0 ;;
        esac
    done
}

action_status() {
    header "Astromech — Status"
    info "Config: ${CONFIG_PATH/#$HOME/\~}"
    engine status || true
}

action_maintain() {
    header "Astromech — Maintenance"
    _engine_state
    (( N_ROOTS )) || { warn "No repository paths configured yet."; return 0; }
    local n; n=$(engine repos 2>/dev/null | wc -l | tr -d ' ')
    (( n )) || { warn "No repositories found under the configured paths."; return 0; }

    local items=("Run maintenance")
    _engine_has tidy && items+=("Run maintenance, then tidy merged branches")
    items+=("Dry run (show what would happen)" "← back")

    local choice
    choice=$(gum choose "${items[@]}" --header "${n} repositories found:") || return 0
    case "$choice" in
        "Dry run"*) engine_foreground maintain --dry-run ;;
        "Run maintenance, then tidy"*)
            gum style --faint \
                "Maintenance as below, and then — in each repo whose pull succeeded — every" \
                "local branch the trunk on origin already holds is deleted with git branch -d." \
                "The pull comes first, so a branch merged since your last fetch counts."
            _ask "Maintain ${n} repositories and delete their merged local branches?" \
                || { info "Cancelled."; return 0; }
            # --yes because gum has already asked: without it the engine would
            # put its own question on /dev/tty, which it can open from here.
            engine_foreground maintain --tidy --yes
            ;;
        "Run maintenance")
            gum style --faint \
                "Feature branches: all changes committed (wip), then switched to main/master." \
                "main/master with changes: stashed (stash kept). Then: git pull --rebase. Nothing is pushed."
            _ask "Run maintenance on ${n} repositories?" || { info "Cancelled."; return 0; }
            engine_foreground maintain
            ;;
        *) return 0 ;;
    esac
}

# The engine's own confirmation is a /dev/tty prompt — right for cron, wrong
# inside gum. So this does what the engine's flags exist for: --dry-run for the
# plan, gum for the answer, --yes to act. The plan is shown VERBATIM: it is the
# engine's, and re-rendering it here is how the two drift apart.
action_tidy() {
    header "Astromech — Tidy merged branches"
    _engine_state
    (( N_ROOTS )) || { warn "No repository paths configured yet."; return 0; }

    local scope=() repo
    case "$(gum choose "Every repository" "One repository" "← back" \
            --header "Delete local branches the trunk already holds:" || true)" in
        "One repository")
            repo="$(_pick_repo "Tidy which repository?")" || return 0
            scope=(--repo "$repo") ;;
        "Every repository") ;;
        *) return 0 ;;
    esac

    local tmp plan notes
    tmp="$(mktemp)" || { warn "Could not create a temporary file."; return 0; }
    plan="$(engine tidy --dry-run "${scope[@]}" 2>"$tmp")" || true
    notes="$(_engine_notes "$tmp")"; rm -f "$tmp"
    [[ -n "$notes" ]] && printf '%s\n' "$notes"
    if [[ -z "$plan" ]]; then
        info "Nothing to tidy — no local branch is already contained in its trunk."
        return 0
    fi
    printf '%s\n' "$plan"
    gum style --faint \
        "\"Merged\" means contained in the trunk ON ORIGIN, as of the last fetch — not the" \
        "local one, which can be behind or hold a merge nobody else has." \
        "Deletion is git branch -d, never -D: one git calls unmerged is reported, not forced."
    _ask "Delete the branch(es) listed above?" || { info "Cancelled — nothing deleted."; return 0; }
    # The plan was just shown. The engine prints it again on stdout before
    # deleting, so only its log (stderr) is new here — hence the redirect, not
    # a second copy of a list the user has already read.
    engine_foreground tidy --yes "${scope[@]}" >/dev/null
}

# fetch.prune is the setting people mean when they ask whether git can do
# tidy's job. The engine's explanation streams straight to the terminal rather
# than being captured and restated here: one copy, one place to keep right.
action_prune() {
    header "Astromech — Fetch pruning"
    local out val="unset" k v orepo okey oval
    out="$(engine prune)" || true
    while IFS='=' read -r k v; do
        case "$k" in
            fetch.prune) val="$v" ;;
            override)
                IFS=$'\t' read -r orepo okey oval <<<"$v"
                gum style --foreground "$YELLOW" "  ${orepo/#$HOME/\~} overrides it: ${okey}=${oval}" ;;
        esac
    done <<<"$out"

    local on=0 choice
    case "${val,,}" in true|yes|on|1) on=1 ;; esac
    if (( on )); then
        choice=$(gum choose "Turn pruning off" "← back" --header "fetch.prune is on (${val})." || true)
    else
        choice=$(gum choose "Turn pruning on" "← back" --header "fetch.prune is ${val} — nothing is pruned." || true)
    fi
    # stdout is the key=value report, which the show pass above has already
    # rendered; what is new is the engine's transition line and the way back,
    # and those are on stderr.
    case "$choice" in
        "Turn pruning on")  engine prune on  >/dev/null || warn "Could not change fetch.prune." ;;
        "Turn pruning off") engine prune off >/dev/null || warn "Could not change fetch.prune." ;;
    esac
}

# -----------------------------------------------------------------------------
# First run: paths → ignores → (once) "run maintenance now?"
# -----------------------------------------------------------------------------
first_run() {
    _engine_state
    if (( N_ROOTS == 0 )); then
        header "Astromech — Setup"
        info "Add the folder(s) that hold your git repositories."
        action_add_paths
        _engine_state
        (( N_ROOTS )) || { warn "No paths added — nothing to maintain."; gum style --faint "Bye."; exit 0; }
        local r; for r in "${ADDED_ROOTS[@]}"; do action_edit_ignores_for "$r"; done
    fi

    if [[ "$ONBOARDED" != 1 ]]; then
        local rc=0
        _ask "Run maintenance on all repositories now?" || rc=$?
        (( rc == 2 )) && return 0                 # cancelled: ask again next launch
        engine mark-onboarded || warn "Could not record first-run state."
        if (( rc == 0 )); then
            header "Astromech — Maintenance"
            engine_foreground maintain
        fi
    fi
}

# -----------------------------------------------------------------------------
main() {
    resolve_engine
    _engine_commands
    gum style --foreground "$CYAN" --border-foreground "$CYAN" --border double \
        --align center --width 60 --margin "1 2" --padding "1 4" \
        "Astromech" "Routine maintenance for your git repos"
    first_run
    while true; do
        _engine_state
        local items=("Trigger maintenance")
        _engine_has tidy  && items+=("Tidy merged branches")
        items+=("Edit repository paths" "Edit ignored folders")
        _engine_has prune && items+=("Fetch pruning (fetch.prune)")
        items+=("Status" "Quit")
        case "$(gum choose "${items[@]}" --header "What would you like to do?" || true)" in
            "Trigger maintenance")      action_maintain ;;
            "Tidy merged branches")     action_tidy ;;
            "Edit repository paths")    action_edit_paths ;;
            "Edit ignored folders")     action_edit_ignores ;;
            "Fetch pruning"*)           action_prune ;;
            "Status")                   action_status ;;
            "Quit"|"")                  gum style --faint "Bye."; exit 0 ;;
        esac
        echo ""
    done
}

main "$@"
