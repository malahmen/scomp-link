#!/usr/bin/env bash
# description: Keep every git repo under your folders on a fresh main/master (commit/stash + pull --rebase)
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

    local choice
    choice=$(gum choose "Run maintenance" "Dry run (show what would happen)" "← back" \
        --header "${n} repositories found:") || return 0
    case "$choice" in
        "Dry run"*) engine_foreground maintain --dry-run ;;
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
    gum style --foreground "$CYAN" --border-foreground "$CYAN" --border double \
        --align center --width 60 --margin "1 2" --padding "1 4" \
        "Astromech" "Routine maintenance for your git repos"
    first_run
    while true; do
        _engine_state
        case "$(gum choose "Trigger maintenance" "Edit repository paths" "Edit ignored folders" \
                "Status" "Quit" --header "What would you like to do?" || true)" in
            "Trigger maintenance")   action_maintain ;;
            "Edit repository paths") action_edit_paths ;;
            "Edit ignored folders")  action_edit_ignores ;;
            "Status")                action_status ;;
            "Quit"|"")               gum style --faint "Bye."; exit 0 ;;
        esac
        echo ""
    done
}

main "$@"
