#!/usr/bin/env bash
# description: Install and launch k9s, the terminal UI for Kubernetes
# Standalone export (export.sh): tools the slimmed setup.sh pre-installs.
# export-setup: kubectl k9s
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

# Prints the chosen context on stdout and returns 0, or warns and returns 1
# — never error_exit, since exit can't be caught by a caller's `|| return`,
# and this is reached from the interactive menu (see cmd_launch).
_pick_context() {
    local contexts
    contexts=$(kubectl config get-contexts -o name 2>/dev/null || true)

    if [[ -z "$contexts" ]]; then
        warn "No kubectl contexts found. Configure your kubeconfig first."
        return 1
    fi

    local count
    count=$(echo "$contexts" | wc -l | tr -d ' ')

    if [[ "$count" -eq 1 ]]; then
        echo "$contexts"
        return 0
    fi

    local current chosen
    current=$(kubectl config current-context 2>/dev/null || echo "")
    chosen=$(echo "$contexts" | gum choose \
        --header "Select a kubectl context for k9s${current:+ (current: ${current})}:" \
        --height 15) || true

    if [[ -z "$chosen" ]]; then
        warn "No context selected."
        return 1
    fi
    echo "$chosen"
}

_kubectl_ready() {
    if ! command -v kubectl &>/dev/null; then
        warn "kubectl not found. k9s needs it (or an equivalent kubeconfig) to do anything."
        return 1
    fi
    return 0
}

cmd_launch() {
    header "k9s — Launch"

    # Soft-fail (warn + return), not error_exit — reached from the
    # interactive menu, where a hard exit here would kill the whole script
    # and dump back out to init.sh's top-level menu instead of staying
    # inside k9s.sh's own loop for another attempt.
    if ! command -v k9s &>/dev/null; then
        warn "k9s is not installed. Run: k9s.sh install"
        return 1
    fi
    _kubectl_ready || return 1

    local context
    context=$(_pick_context) || return 1
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

        # launch/status/uninstall only make sense once k9s is actually
        # installed — offering them beforehand just leads to a "not
        # installed" warning instead of doing anything useful.
        local -a opts=()
        if command -v k9s &>/dev/null; then
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
