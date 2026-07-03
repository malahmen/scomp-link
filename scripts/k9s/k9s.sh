#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# k9s.sh
# Install, manage, and launch k9s (https://github.com/derailed/k9s) — a
# terminal UI for Kubernetes. k9s has no config file of its own to set up —
# it reads the ambient kubeconfig exactly like kubectl does. The one thing
# worth handling here: launching it with no reachable context (or the wrong
# one active) just gives a blank/broken TUI, so 'launch' picks a context
# explicitly via k9s's own --context flag instead of silently relying on
# whatever kubectl's "current-context" happens to be — this also means
# launching k9s never mutates your ambient kubectl state.
#
# Sourced helpers (scripts/_common/):
#   ui.sh   — header/info/success/warn/error_exit
#   deps.sh — _check_kubectl
# -----------------------------------------------------------------------------

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMON_DIR="${SCRIPT_DIR}/../_common"

# shellcheck source=../_common/ui.sh
source "${COMMON_DIR}/ui.sh"
# shellcheck source=../_common/deps.sh
source "${COMMON_DIR}/deps.sh"

trap 'echo ""; gum style --faint "Interrupted."; exit 0' INT TERM

TOOL="k9s"

# -----------------------------------------------------------------------------
# install / uninstall / status — via mise
# -----------------------------------------------------------------------------

_ensure_mise() {
    command -v mise &>/dev/null || error_exit "mise is not installed. Run setup.sh first."
}

cmd_install() {
    header "k9s — Install"
    _ensure_mise

    if command -v k9s &>/dev/null; then
        success "k9s already installed: $(k9s version --short 2>/dev/null | head -1)"
        return
    fi

    gum spin --spinner dot --title "Installing k9s via mise..." -- \
        mise use --global "$TOOL" \
        || error_exit "mise install failed for ${TOOL}."

    export PATH="$HOME/.local/share/mise/shims:$PATH"
    command -v k9s &>/dev/null \
        || error_exit "k9s installed but not found in PATH. Open a new terminal and retry."
    success "k9s installed: $(k9s version --short 2>/dev/null | head -1)"
}

cmd_uninstall() {
    header "k9s — Uninstall"

    command -v k9s &>/dev/null || { warn "k9s doesn't appear to be installed."; return; }

    gum confirm "Remove k9s (via mise)?" || { info "Cancelled."; return; }

    mise use --global --remove "$TOOL" 2>/dev/null || true
    mise uninstall "$TOOL" --all 2>/dev/null || warn "mise uninstall reported an issue — check 'mise ls ${TOOL}' manually."

    success "k9s uninstalled."
}

cmd_status() {
    header "k9s — Status"

    if command -v k9s &>/dev/null; then
        success "Installed: $(command -v k9s)"
        info "Version: $(k9s version --short 2>/dev/null | head -1)"
    else
        warn "Not installed. Run: k9s.sh install"
    fi

    if command -v kubectl &>/dev/null; then
        local current
        current=$(kubectl config current-context 2>/dev/null || echo "")
        [[ -n "$current" ]] && info "Current kubectl context: ${current}" || warn "No current kubectl context set."
    else
        warn "kubectl not found — k9s needs it (or an equivalent kubeconfig) to do anything."
    fi
}

# -----------------------------------------------------------------------------
# launch — pick a context explicitly (k9s --context), rather than silently
# depending on kubectl's ambient current-context.
# -----------------------------------------------------------------------------

_pick_context() {
    local contexts
    contexts=$(kubectl config get-contexts -o name 2>/dev/null || true)

    if [[ -z "$contexts" ]]; then
        error_exit "No kubectl contexts found. Configure your kubeconfig first."
    fi

    local count
    count=$(echo "$contexts" | wc -l | tr -d ' ')

    if [[ "$count" -eq 1 ]]; then
        echo "$contexts"
        return
    fi

    local current chosen
    current=$(kubectl config current-context 2>/dev/null || echo "")
    chosen=$(echo "$contexts" | gum choose \
        --header "Select a kubectl context for k9s${current:+ (current: ${current})}:" \
        --height 15) || true

    [[ -z "$chosen" ]] && error_exit "No context selected."
    echo "$chosen"
}

cmd_launch() {
    header "k9s — Launch"

    command -v k9s &>/dev/null || error_exit "k9s is not installed. Run: k9s.sh install"
    _check_kubectl

    local context
    context=$(_pick_context)
    info "Launching k9s against context: ${context}"

    # Foreground, not exec — control returns here (and to the menu) on quit.
    k9s --context "$context" || true
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
        header "k9s Manager"
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
