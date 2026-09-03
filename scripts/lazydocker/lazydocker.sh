#!/usr/bin/env bash
# description: Install and launch lazydocker, the terminal UI for Docker
# Standalone export (export.sh): tools the slimmed setup.sh pre-installs.
# export-setup: lazydocker
# -----------------------------------------------------------------------------
# lazydocker.sh
# Install, manage, and launch lazydocker
# (https://github.com/jesseduffield/lazydocker) — a terminal UI for Docker
# and Docker Compose. No config needed to work: it just talks to whatever
# Docker daemon is reachable, same as the `docker` CLI itself.
#
# Sourced helpers (scripts/_common/):
#   ui.sh — header/info/success/warn/error_exit
# -----------------------------------------------------------------------------

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -d "${SCRIPT_DIR}/../_common" ]]; then
    COMMON_DIR="${SCRIPT_DIR}/../_common"   # scomp-link repo layout
else
    COMMON_DIR="${SCRIPT_DIR}"              # exported standalone: deps sit alongside
fi

# shellcheck source=../_common/ui.sh
source "${COMMON_DIR}/ui.sh"

trap 'echo ""; gum style --faint "Interrupted."; exit 0' INT TERM

TOOL="lazydocker"

# -----------------------------------------------------------------------------
# install / uninstall / status — via mise
# -----------------------------------------------------------------------------

_ensure_mise() {
    command -v mise &>/dev/null || error_exit "mise is not installed. Run setup.sh first."
}

cmd_install() {
    header "lazydocker — Install"
    _ensure_mise

    if command -v lazydocker &>/dev/null; then
        success "lazydocker already installed: $(lazydocker --version 2>/dev/null | head -1)"
        return
    fi

    gum spin --spinner dot --title "Installing lazydocker via mise..." -- \
        mise use --global "$TOOL" \
        || error_exit "mise install failed for ${TOOL}."

    export PATH="$HOME/.local/share/mise/shims:$PATH"
    command -v lazydocker &>/dev/null \
        || error_exit "lazydocker installed but not found in PATH. Open a new terminal and retry."
    success "lazydocker installed: $(lazydocker --version 2>/dev/null | head -1)"
}

cmd_uninstall() {
    header "lazydocker — Uninstall"

    command -v lazydocker &>/dev/null || { warn "lazydocker doesn't appear to be installed."; return; }

    gum confirm "Remove lazydocker (via mise)?" || { info "Cancelled."; return; }

    mise use --global --remove "$TOOL" 2>/dev/null || true
    mise uninstall "$TOOL" --all 2>/dev/null || warn "mise uninstall reported an issue — check 'mise ls ${TOOL}' manually."

    success "lazydocker uninstalled."
}

cmd_status() {
    header "lazydocker — Status"

    if command -v lazydocker &>/dev/null; then
        success "Installed: $(command -v lazydocker)"
        info "Version: $(lazydocker --version 2>/dev/null | head -1)"
    else
        warn "Not installed. Run: lazydocker.sh install"
    fi

    _docker_ready || true
}

# -----------------------------------------------------------------------------
# launch
# -----------------------------------------------------------------------------

# Distinguishes "docker not installed" from "installed but this shell can't
# reach it" — the latter is almost always a stale shell that predates the
# user being added to the docker group (docker.sh install warns about this,
# but it's easy to miss and land back here in the same terminal).
_docker_ready() {
    if ! command -v docker &>/dev/null; then
        warn "docker CLI not found. Run: docker.sh install"
        return 1
    fi

    local err
    if err=$(docker info 2>&1 >/dev/null); then
        success "Docker daemon reachable."
        return 0
    fi

    if [[ "$err" == *"permission denied"* ]]; then
        warn "Docker daemon found, but this shell can't reach it (permission denied on the docker socket)."
        warn "This usually means your user was just added to the 'docker' group but this shell hasn't picked it up yet."
        warn "Open a new terminal (or run: newgrp docker) and try again."
    else
        warn "Docker daemon not reachable: ${err}"
        warn "Check it's running: docker.sh status"
    fi
    return 1
}

cmd_launch() {
    header "lazydocker — Launch"

    # Soft-fail (warn + return), not error_exit — reached from the
    # interactive menu, where a hard exit here would kill the whole script
    # and dump back out to init.sh's top-level menu instead of staying
    # inside lazydocker.sh's own loop for another attempt.
    if ! command -v lazydocker &>/dev/null; then
        warn "lazydocker is not installed. Run: lazydocker.sh install"
        return 1
    fi
    _docker_ready || return 1

    # Foreground, not exec — control returns here (and to the menu) on quit.
    lazydocker || true
}

# -----------------------------------------------------------------------------
# Main dispatch
# -----------------------------------------------------------------------------

main() {
    if [[ $# -gt 0 ]]; then
        case "$1" in
            install)   cmd_install ;;
            uninstall) cmd_uninstall ;;
            status)    cmd_status ;;
            launch)    cmd_launch ;;
            *) error_exit "Unknown command: $1 (expected: install|uninstall|status|launch)" ;;
        esac
        exit 0
    fi

    while true; do
        header "lazydocker Manager"

        # launch/status/uninstall only make sense once lazydocker is
        # actually installed — offering them beforehand just leads to a
        # "not installed" warning instead of doing anything useful.
        local -a opts=()
        if command -v lazydocker &>/dev/null; then
            opts=("launch" "status" "uninstall" "quit")
        else
            opts=("install" "quit")
        fi

        local action
        action=$(printf '%s\n' "${opts[@]}" | gum choose --header "Choose an action:") || true
        [[ -z "$action" || "$action" == "quit" ]] && { gum style --faint "Bye."; exit 0; }

        # || true on each: under `set -e`, a cmd_* returning non-zero here
        # (e.g. cmd_launch's soft-fail warn+return) would otherwise trigger
        # errexit and kill the whole script — exactly the "dumped back to
        # init.sh's top-level menu" behavior this loop exists to avoid.
        case "$action" in
            launch)    cmd_launch    || true ;;
            install)   cmd_install   || true ;;
            uninstall) cmd_uninstall || true ;;
            status)    cmd_status    || true ;;
        esac

        echo ""
        gum confirm "Back to main menu?" || { gum style --faint "Bye."; exit 0; }
    done
}

main "$@"
