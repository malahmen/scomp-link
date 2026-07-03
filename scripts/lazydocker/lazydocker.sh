#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# lazydocker.sh
# Install, manage, and launch lazydocker
# (https://github.com/jesseduffield/lazydocker) — a terminal UI for Docker
# and Docker Compose. No config needed to work: it just talks to whatever
# Docker daemon is reachable, same as the `docker` CLI itself.
#
# Sourced helpers (scripts/_common/):
#   ui.sh   — header/info/success/warn/error_exit
#   deps.sh — _check_docker
# -----------------------------------------------------------------------------

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMON_DIR="${SCRIPT_DIR}/../_common"

# shellcheck source=../_common/ui.sh
source "${COMMON_DIR}/ui.sh"
# shellcheck source=../_common/deps.sh
source "${COMMON_DIR}/deps.sh"

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

    if command -v docker &>/dev/null && docker info &>/dev/null 2>&1; then
        success "Docker daemon reachable."
    else
        warn "Docker daemon not reachable — lazydocker needs it. Run: docker.sh status"
    fi
}

# -----------------------------------------------------------------------------
# launch
# -----------------------------------------------------------------------------

cmd_launch() {
    header "lazydocker — Launch"

    command -v lazydocker &>/dev/null || error_exit "lazydocker is not installed. Run: lazydocker.sh install"
    _check_docker

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
        local action
        action=$(gum choose "launch" "install" "uninstall" "status" "quit" --header "Choose an action:") || true
        [[ -z "$action" || "$action" == "quit" ]] && { gum style --faint "Bye."; exit 0; }

        case "$action" in
            launch)    cmd_launch ;;
            install)   cmd_install ;;
            uninstall) cmd_uninstall ;;
            status)    cmd_status ;;
        esac

        echo ""
        gum confirm "Back to main menu?" || { gum style --faint "Bye."; exit 0; }
    done
}

main "$@"
