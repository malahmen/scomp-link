#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# lazygit.sh
# Install, manage, and launch lazygit (https://github.com/jesseduffield/lazygit)
# — a terminal UI for git. No config needed to work: lazygit just operates on
# whatever git repo it's pointed at, same as the `git` CLI itself.
#
# Sourced helpers (scripts/_common/):
#   ui.sh — header/info/success/warn/error_exit
# -----------------------------------------------------------------------------

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMON_DIR="${SCRIPT_DIR}/../_common"

# shellcheck source=../_common/ui.sh
source "${COMMON_DIR}/ui.sh"

trap 'echo ""; gum style --faint "Interrupted."; exit 0' INT TERM

TOOL="lazygit"

# -----------------------------------------------------------------------------
# install / uninstall / status — via mise (matches setup.sh's ensure_gum
# pattern: `mise use --global`, not just `mise install`, so the version is
# durably pinned in mise's global config rather than relying on it being the
# only installed version).
# -----------------------------------------------------------------------------

_ensure_mise() {
    command -v mise &>/dev/null || error_exit "mise is not installed. Run setup.sh first."
}

cmd_install() {
    header "lazygit — Install"
    _ensure_mise

    if command -v lazygit &>/dev/null; then
        success "lazygit already installed: $(lazygit --version 2>/dev/null | head -1)"
        return
    fi

    gum spin --spinner dot --title "Installing lazygit via mise..." -- \
        mise use --global "$TOOL" \
        || error_exit "mise install failed for ${TOOL}."

    export PATH="$HOME/.local/share/mise/shims:$PATH"
    command -v lazygit &>/dev/null \
        || error_exit "lazygit installed but not found in PATH. Open a new terminal and retry."
    success "lazygit installed: $(lazygit --version 2>/dev/null | head -1)"
}

cmd_uninstall() {
    header "lazygit — Uninstall"

    command -v lazygit &>/dev/null || { warn "lazygit doesn't appear to be installed."; return; }

    gum confirm "Remove lazygit (via mise)?" || { info "Cancelled."; return; }

    mise use --global --remove "$TOOL" 2>/dev/null || true
    mise uninstall "$TOOL" --all 2>/dev/null || warn "mise uninstall reported an issue — check 'mise ls ${TOOL}' manually."

    success "lazygit uninstalled."
}

cmd_status() {
    header "lazygit — Status"

    if command -v lazygit &>/dev/null; then
        success "Installed: $(command -v lazygit)"
        info "Version: $(lazygit --version 2>/dev/null | head -1)"
    else
        warn "Not installed. Run: lazygit.sh install"
    fi
}

# -----------------------------------------------------------------------------
# launch — operates on the current directory's git repo (lazygit's own
# default behavior), or a prompted path if the current directory isn't one.
# -----------------------------------------------------------------------------

cmd_launch() {
    header "lazygit — Launch"

    command -v lazygit &>/dev/null || error_exit "lazygit is not installed. Run: lazygit.sh install"

    local target_dir="$PWD"
    if ! git -C "$target_dir" rev-parse --is-inside-work-tree &>/dev/null; then
        warn "Current directory is not a git repository."
        local path_input
        path_input=$(gum input --placeholder "$HOME/some/repo" --header "Path to a git repository:") || true
        [[ -z "$path_input" ]] && { info "Cancelled."; return; }
        target_dir="${path_input/#\~/$HOME}"
        git -C "$target_dir" rev-parse --is-inside-work-tree &>/dev/null \
            || error_exit "Not a git repository: ${target_dir}"
    fi

    # Foreground, not exec — control returns here (and to the menu) on quit.
    (cd "$target_dir" && lazygit) || true
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
        header "lazygit Manager"
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
