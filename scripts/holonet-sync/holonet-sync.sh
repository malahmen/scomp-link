#!/usr/bin/env bash
# description: Reconcile repos both ways between Gitea and GitHub (branches, tags, never force-push)
# Standalone export (export.sh): no extra setup deps — the engine's tools (git, curl,
# jq, flock) are installed at runtime from the menu's "install deps" action.
# -----------------------------------------------------------------------------
# holonet-sync.sh — gum front-end for the holonet-sync engine.
#
# scomp-link owns the interactive experience (this file); the reconciliation
# logic lives in the standalone holonet-sync engine (its own repo): a gum-free,
# flag-driven CLI built to run unattended in a cron job or systemd timer. This
# shim resolves the engine (local checkout → cache → clone), collects options
# via gum, and runs the engine with the matching flags — the holo-convert
# pattern.
#
# The engine is the one that knows where its config lives, so this front-end
# asks it (`engine config`, `engine repos`) instead of re-deriving the XDG paths
# — a picker that disagrees with what a run would actually sync is worse than no
# picker at all.
#
# Engine resolution order:
#   1. $HOLONET_SYNC_DIR/holonet-sync.sh        (explicit override)
#   2. ../../../holonet-sync/holonet-sync.sh    (sibling dev checkout)
#   3. ~/.cache/scomp-link/holonet-sync/…       (cached clone; offers git pull)
#   4. git clone --depth 1 (public HTTPS)       (first run)
#
# Sourced helpers (scripts/_common/):
#   ui.sh   — header/info/success/warn/error_exit
#   deps.sh — _ensure_pkg (dnf/apt/rpm-ostree), for the engine's tools
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
# shellcheck source=../_common/deps.sh
source "${COMMON_DIR}/deps.sh"

command -v gum &>/dev/null || { echo "[error] gum is required. Run setup.sh first." >&2; exit 1; }
command -v git &>/dev/null || { echo "[error] git is required to fetch the engine." >&2; exit 1; }

trap 'echo ""; gum style --faint "Interrupted."; exit 0' INT TERM

HOLONET_REPO="${HOLONET_SYNC_REPO:-https://github.com/malahmen/holonet-sync.git}"
HOLONET_CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/scomp-link/holonet-sync"
ENGINE=""

# Engine-reported paths, filled by _engine_paths.
CONFIG_PATH=""; CONFIG_EXISTS=0; REPOS_PATH=""; REPOS_EXISTS=0; STATE_PATH=""

# -----------------------------------------------------------------------------
# Resolve the holonet-sync engine (override → sibling → cache → clone).
# -----------------------------------------------------------------------------
resolve_engine() {
    if [[ -n "${HOLONET_SYNC_DIR:-}" && -f "${HOLONET_SYNC_DIR}/holonet-sync.sh" ]]; then
        ENGINE="${HOLONET_SYNC_DIR}/holonet-sync.sh"
        info "Using holonet-sync from \$HOLONET_SYNC_DIR: ${HOLONET_SYNC_DIR}"
        return
    fi

    local sib="${SCRIPT_DIR}/../../../holonet-sync/holonet-sync.sh"
    if [[ -f "$sib" ]]; then
        ENGINE="$(cd "$(dirname "$sib")" && pwd)/holonet-sync.sh"
        info "Using local holonet-sync checkout: $(dirname "$ENGINE")"
        return
    fi

    if [[ -f "${HOLONET_CACHE}/holonet-sync.sh" ]]; then
        ENGINE="${HOLONET_CACHE}/holonet-sync.sh"
        info "Using cached holonet-sync: ${HOLONET_CACHE}"
        if [[ -d "${HOLONET_CACHE}/.git" ]] && gum confirm "Update holonet-sync (git pull)?"; then
            gum spin --spinner dot --title "Updating holonet-sync..." -- \
                git -C "$HOLONET_CACHE" pull --ff-only || warn "Update failed; using the existing copy."
        fi
        return
    fi

    gum confirm "holonet-sync engine not found. Clone it from ${HOLONET_REPO}?" \
        || error_exit "holonet-sync engine is unavailable."
    mkdir -p "$(dirname "$HOLONET_CACHE")"
    gum spin --spinner dot --title "Cloning holonet-sync..." -- \
        git clone --depth 1 "$HOLONET_REPO" "$HOLONET_CACHE" \
        || error_exit "Failed to clone holonet-sync from ${HOLONET_REPO}"
    ENGINE="${HOLONET_CACHE}/holonet-sync.sh"
    success "holonet-sync cloned to ${HOLONET_CACHE}"
}

# Run the engine. engine_foreground is for the long ones (run/check): Ctrl-C
# stops just the child and returns to the menu instead of killing the TUI.
engine() { bash "$ENGINE" "$@"; }
engine_foreground() {
    trap ':' INT
    bash "$ENGINE" "$@" || true
    trap 'echo ""; gum style --faint "Interrupted."; exit 0' INT TERM
}

# -----------------------------------------------------------------------------
# Engine-reported state
# -----------------------------------------------------------------------------

# Ask the engine where its config, repo list and state actually live.
_engine_paths() {
    local key val
    CONFIG_PATH=""; CONFIG_EXISTS=0; REPOS_PATH=""; REPOS_EXISTS=0; STATE_PATH=""
    while IFS='=' read -r key val; do
        case "$key" in
            config)        CONFIG_PATH="$val" ;;
            config_exists) CONFIG_EXISTS="$val" ;;
            repos)         REPOS_PATH="$val" ;;
            repos_exists)  REPOS_EXISTS="$val" ;;
            state)         STATE_PATH="$val" ;;
        esac
    done < <(engine config 2>/dev/null)
    [[ -n "$CONFIG_PATH" ]] || error_exit "The engine did not report its paths — is ${ENGINE} runnable?"
}

# Echoes the chosen "owner/name", or "" for every repo / on cancel. The list
# comes from the engine, so it matches exactly what a run would iterate.
_pick_repo() {
    local repos choice
    repos=$(engine repos 2>/dev/null | cut -f1) || true
    [[ -z "$repos" ]] && { printf ''; return 0; }

    choice=$(printf 'every repo\n%s\n' "$repos" | gum choose --header "Which repo?") || true
    [[ -z "$choice" || "$choice" == "every repo" ]] && { printf ''; return 0; }
    printf '%s' "$choice"
}

# -----------------------------------------------------------------------------
# Actions
# -----------------------------------------------------------------------------

action_status() {
    header "Holonet Sync — Status"
    info "State: ${STATE_PATH}"
    engine status || true
}

# action_run <dry|wet>
action_run() {
    local mode="$1" repo args=(run)
    header "Holonet Sync — $( [[ "$mode" == dry ]] && echo "Dry run" || echo "Run" )"

    repo="$(_pick_repo)"
    [[ -n "$repo" ]] && args+=(--repo "$repo")
    [[ "$mode" == dry ]] && args+=(--dry-run)
    gum confirm "Verbose (debug) logging?" && args+=(--verbose)

    engine_foreground "${args[@]}"
}

action_check() {
    header "Holonet Sync — Check"
    engine_foreground check
}

action_init() {
    header "Holonet Sync — Init"
    engine init || return 1
    _engine_paths
    gum confirm "Edit the config now?" && action_edit
}

action_edit() {
    header "Holonet Sync — Edit configuration"
    _engine_paths

    local target
    target=$(gum choose "$CONFIG_PATH" "$REPOS_PATH" --header "Which file?") || true
    [[ -z "$target" ]] && { info "Cancelled."; return 0; }
    # warn, not error_exit: inside an action, exiting would close the whole TUI.
    [[ -e "$target" ]] || { warn "${target} does not exist yet — run 'init' first."; return 1; }

    "${EDITOR:-vi}" "$target"
}

action_reset() {
    header "Holonet Sync — Reset sync state"

    local repo; repo="$(_pick_repo)"
    if [[ -z "$repo" ]]; then
        warn "Reset works on one repo at a time — pick a single repo."
        return 0
    fi
    gum confirm "Forget sync state for '${repo}'? (nothing is deleted on either side)" \
        || { info "Cancelled."; return 0; }

    engine reset --repo "$repo" || true
}

# The engine deliberately installs nothing itself — that belongs here, where
# there's someone to answer a prompt.
action_deps() {
    header "Holonet Sync — Dependencies"

    # Each in its own subshell: _ensure_pkg calls error_exit on an install
    # failure (which would close the TUI) and returns 1 after an rpm-ostree
    # layer (which would skip the rest). Keep going and report at the end.
    local spec bin pkg_dnf pkg_apt missing=()
    for spec in "git git git" "curl curl curl" "jq jq jq" "flock util-linux-core util-linux" \
                "base64 coreutils coreutils" "sha1sum coreutils coreutils"; do
        read -r bin pkg_dnf pkg_apt <<< "$spec"
        ( _ensure_pkg "$bin" "$pkg_dnf" "$pkg_apt" ) || missing+=("$bin")
    done

    if (( ${#missing[@]} )); then
        warn "Not available yet: ${missing[*]} (after an rpm-ostree layer, reboot first)."
        return 1
    fi
    success "Dependencies checked. Run 'check' to validate tokens and repo access."
}

# -----------------------------------------------------------------------------
# Menu
# -----------------------------------------------------------------------------

main() {
    resolve_engine
    gum style --foreground "${CYAN:-212}" --border-foreground "${CYAN:-212}" --border double \
        --align center --width 60 --margin "1 2" --padding "1 4" \
        "holonet-sync" "Gitea <-> GitHub, both ways, no force-push"

    _engine_paths

    # Nothing works without a config, and writing the example one is the only
    # useful first action — so offer exactly that instead of a dead menu.
    if (( ! CONFIG_EXISTS )); then
        warn "No configuration at ${CONFIG_PATH}."
        gum confirm "Write an example config and repo list now?" || { gum style --faint "Bye."; exit 0; }
        action_init || true
        info "Fill in the tokens and the repo list, then run this again."
        exit 0
    fi
    if (( ! REPOS_EXISTS )); then
        warn "No repo list at ${REPOS_PATH} — there is nothing to reconcile until it exists."
    fi

    while true; do
        local action
        action=$(gum choose \
            "status" "dry-run" "run" "check" "edit config" "reset state" "install deps" "quit" \
            --header "Choose an action:") || true
        [[ -z "$action" || "$action" == "quit" ]] && { gum style --faint "Bye."; exit 0; }

        # || true on each: under `set -e` a non-zero return from an action would
        # trigger errexit and drop the user back to init.sh's top-level menu,
        # which is exactly what this loop exists to avoid.
        case "$action" in
            status)         action_status    || true ;;
            dry-run)        action_run dry   || true ;;
            run)            action_run wet   || true ;;
            check)          action_check     || true ;;
            "edit config")  action_edit      || true ;;
            "reset state")  action_reset     || true ;;
            "install deps") action_deps      || true ;;
        esac

        echo ""
        gum confirm "Back to the menu?" || { gum style --faint "Bye."; exit 0; }
    done
}

main "$@"
