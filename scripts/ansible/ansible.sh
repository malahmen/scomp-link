#!/usr/bin/env bash
# description: Install and manage Ansible (core + collections) via mise
# Standalone export (export.sh): tools the slimmed setup.sh pre-installs.
# export-setup: ansible-playbook
# -----------------------------------------------------------------------------
# ansible.sh
# Install, manage and inspect an Ansible control-node installation, kept
# user-local via mise rather than layered onto the OS — which matters on
# atomic/immutable hosts (Bazzite, Silverblue) where `rpm-ostree install`
# means a reboot and a re-layer on every OS update.
#
# Two things here are not obvious and were learned the hard way:
#
#   1. Install `pipx:ansible-core`, NOT `pipx:ansible`. The `ansible` PyPI
#      meta-package registers exactly one entry point — `ansible-community` —
#      so installing it leaves you without `ansible-playbook`, `ansible-galaxy`
#      or any of the tools you actually wanted. `ansible-core` exposes all ten.
#
#   2. mise's pipx backend needs a Python installer present (uv or pipx) and
#      does not bootstrap one for you; it just fails. cmd_install puts uv in
#      place first, since it's a single static binary and far quicker.
#
# ansible-core ships with no collections at all, so `collections` installs the
# set this project actually depends on. Add to ANSIBLE_COLLECTIONS as needed —
# kubernetes.core is a likely future addition, but note its modules want the
# Python kubernetes library wherever they execute.
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

TOOL="pipx:ansible-core"
UV_TOOL="uv"

# Collections ansible-core does not bundle but plays here rely on.
ANSIBLE_COLLECTIONS=(
    "ansible.posix"      # sysctl, mount, authorized_key
    "community.general"  # broad grab-bag; podman modules live here
)

MISE_SHIMS="$HOME/.local/share/mise/shims"

# -----------------------------------------------------------------------------
# install / uninstall / status
# -----------------------------------------------------------------------------

_ensure_mise() {
    command -v mise &>/dev/null || error_exit "mise is not installed. Run setup.sh first."
}

# mise-installed binaries land in the shims dir, which a shell opened before
# the install won't have on PATH yet. Add it so checks in this same run see
# what we just installed.
_use_shims() {
    [[ -d "$MISE_SHIMS" ]] && export PATH="${MISE_SHIMS}:$PATH"
    return 0
}

_ansible_version() {
    ansible --version 2>/dev/null | head -1
}

cmd_install() {
    header "Ansible — Install"
    _ensure_mise
    _use_shims

    if command -v ansible-playbook &>/dev/null; then
        success "Ansible already installed: $(_ansible_version)"
        return
    fi

    # uv first — mise's pipx backend requires an installer and won't provide one.
    if ! command -v uv &>/dev/null; then
        gum spin --spinner dot --title "Installing uv (required by mise's pipx backend)..." -- \
            mise use --global "$UV_TOOL@latest" \
            || error_exit "mise install failed for ${UV_TOOL}."
        _use_shims
    fi

    gum spin --spinner dot --title "Installing ansible-core via mise..." -- \
        mise use --global "$TOOL" \
        || error_exit "mise install failed for ${TOOL}."

    _use_shims
    command -v ansible-playbook &>/dev/null \
        || error_exit "ansible-core installed but ansible-playbook is not in PATH. Open a new terminal and retry."

    success "Ansible installed: $(_ansible_version)"

    if gum confirm "Install the required collections now?"; then
        cmd_collections
    else
        info "Skipped. Run 'ansible.sh collections' when you need them."
    fi
}

cmd_uninstall() {
    header "Ansible — Uninstall"
    _use_shims

    command -v ansible-playbook &>/dev/null || { warn "Ansible doesn't appear to be installed."; return; }

    gum confirm "Remove ansible-core (via mise)?" || { info "Cancelled."; return; }

    # Older mise spells this `use --global --remove`; newer ones `unuse`.
    mise unuse --global "$TOOL" 2>/dev/null \
        || mise use --global --remove "$TOOL" 2>/dev/null \
        || true
    mise uninstall "$TOOL" --all 2>/dev/null \
        || warn "mise uninstall reported an issue — check 'mise ls ${TOOL}' manually."

    info "Collections under ~/.ansible/collections were left in place (removing them is separate and rarely wanted)."
    success "Ansible uninstalled."
}

cmd_status() {
    header "Ansible — Status"
    _use_shims

    if command -v ansible-playbook &>/dev/null; then
        success "Installed: $(command -v ansible-playbook)"
        info "Version: $(_ansible_version)"
    else
        warn "Not installed. Run: ansible.sh install"
        return
    fi

    gum style --foreground "${CYAN:-212}" --bold "── Collections"
    local missing=0
    local c
    for c in "${ANSIBLE_COLLECTIONS[@]}"; do
        # ansible-galaxy exits 0 even when nothing matches, so grep the output.
        if ansible-galaxy collection list "$c" 2>/dev/null | grep -q "^${c} "; then
            success "${c} present"
        else
            warn "${c} MISSING"
            missing=1
        fi
    done
    [[ "$missing" -eq 1 ]] && info "Run 'ansible.sh collections' to install the missing ones."

    gum style --foreground "${CYAN:-212}" --bold "── Config in effect"
    # Run from wherever the user invoked this: ansible.cfg is resolved relative
    # to the working directory, so this reflects the project they're standing in.
    info "Config file: $(ansible-config dump --only-changed 2>/dev/null | head -1 || echo 'none detected')"
}

cmd_collections() {
    header "Ansible — Collections"
    _use_shims

    command -v ansible-galaxy &>/dev/null \
        || error_exit "ansible-galaxy not found. Run: ansible.sh install"

    local c
    for c in "${ANSIBLE_COLLECTIONS[@]}"; do
        gum spin --spinner dot --title "Installing ${c}..." -- \
            ansible-galaxy collection install "$c" --upgrade \
            || warn "Failed to install ${c}."
    done

    success "Collections up to date (installed under ~/.ansible/collections)."
}

# -----------------------------------------------------------------------------
# Main dispatch
# -----------------------------------------------------------------------------

main() {
    if [[ $# -gt 0 ]]; then
        case "$1" in
            install)     cmd_install ;;
            uninstall)   cmd_uninstall ;;
            status)      cmd_status ;;
            collections) cmd_collections ;;
            *) error_exit "Unknown command: $1 (expected: install|uninstall|status|collections)" ;;
        esac
        exit 0
    fi

    while true; do
        header "Ansible Manager"
        _use_shims

        # Only offer what makes sense for the current state — otherwise the
        # menu just leads to a "not installed" warning instead of an action.
        local -a opts=()
        if command -v ansible-playbook &>/dev/null; then
            opts=("status" "collections" "uninstall" "quit")
        else
            opts=("install" "quit")
        fi

        local action
        action=$(printf '%s\n' "${opts[@]}" | gum choose --header "Choose an action:") || true
        [[ -z "$action" || "$action" == "quit" ]] && { gum style --faint "Bye."; exit 0; }

        # || true on each: under `set -e` a non-zero return from a cmd_* would
        # trigger errexit and drop the user back to init.sh's top-level menu,
        # which is exactly what this loop exists to avoid.
        case "$action" in
            install)     cmd_install     || true ;;
            uninstall)   cmd_uninstall   || true ;;
            status)      cmd_status      || true ;;
            collections) cmd_collections || true ;;
        esac

        echo ""
        gum confirm "Back to the menu?" || { gum style --faint "Bye."; exit 0; }
    done
}

main "$@"
