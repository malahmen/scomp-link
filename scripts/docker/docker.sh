#!/usr/bin/env bash
# description: Install, uninstall, and check the status of Docker itself
# Standalone export (export.sh): no extra setup deps — Docker Engine + Compose are checked/instructed at runtime.
# -----------------------------------------------------------------------------
# docker.sh
# Install, uninstall, and check status of Docker itself. About 15 other
# scripts in this repo check for Docker via _common/deps.sh's _check_docker
# but never install it — this fills that gap so there's one place that
# actually does the install, instead of every script telling the user to go
# figure it out themselves.
#
# Uses each distro's own native Docker packaging rather than the official
# docker.com convenience script (curl | sh) or adding Docker's own apt/dnf
# repo — no external repo/GPG-key management to maintain, consistent with
# this repo's existing convention of never piping curl into a shell.
#   Fedora/RHEL (dnf):  moby-engine + docker-cli + docker-compose (Fedora's
#                       own packaging — no external repo needed)
#   Debian/Ubuntu (apt): docker.io + docker-compose-v2
#   rpm-ostree:          layered via _ensure_pkgs, same as any other package
#
# Sourced helpers (scripts/_common/):
#   ui.sh   — header/info/success/warn/error_exit
#   deps.sh — _ensure_pkgs (dnf/apt/rpm-ostree aware), _require_sudo_or_instruct
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
# shellcheck source=../_common/deps.sh
source "${COMMON_DIR}/deps.sh"

trap 'echo ""; gum style --faint "Interrupted."; exit 0' INT TERM

# -----------------------------------------------------------------------------
# install
# -----------------------------------------------------------------------------

# Compose v2 ("docker compose"). Package names differ per distro and Fedora
# dropped the legacy v1 "docker-compose" package (F41+), so install best-effort
# and never abort the run — the engine is usable without it.
_ensure_compose_v2() {
    docker compose version &>/dev/null 2>&1 && { info "docker compose plugin already present."; return 0; }
    local pm; pm="$(_pkg_manager)"
    case "$pm" in
        apt)        sudo apt-get install -y docker-compose-v2 2>/dev/null && return 0 ;;
        dnf)        sudo dnf install -y docker-compose-plugin 2>/dev/null && return 0
                    sudo dnf install -y docker-compose 2>/dev/null && return 0 ;;
        rpm-ostree) rpm-ostree install -y docker-compose-plugin 2>/dev/null && return 0 ;;
    esac
    warn "Could not install the Docker Compose v2 plugin automatically — install it"
    warn "  manually if you need 'docker compose' (https://docs.docker.com/compose/install/)."
    return 1
}

cmd_install() {
    header "Docker — Install"

    if command -v docker &>/dev/null && docker info &>/dev/null 2>&1; then
        success "Docker is already installed and running: $(docker --version)"
        return
    fi

    if command -v docker &>/dev/null; then
        info "docker CLI found but the daemon isn't running/reachable — will (re)enable the service below."
    else
        # Core engine + CLI (required). Compose v2 is installed separately below so
        # a missing/renamed compose package can't abort the whole install.
        _ensure_pkgs "moby-engine docker-cli" "docker.io"
        _ensure_compose_v2 || true
    fi

    info "Enabling and starting the docker service..."
    _require_sudo_or_instruct "Enabling and starting the docker service" "sudo systemctl enable --now docker"
    sudo systemctl enable --now docker || error_exit "Failed to enable/start the docker service."

    local user; user="$(whoami)"
    if ! groups "$user" 2>/dev/null | grep -qw docker; then
        info "Adding ${user} to the docker group (lets you run docker without sudo)..."
        _require_sudo_or_instruct "Adding ${user} to the docker group" "sudo usermod -aG docker ${user}"
        sudo usermod -aG docker "$user" || warn "Could not add ${user} to the docker group — you'll need sudo for docker commands, or add it manually."
        warn "Group membership needs a fresh login session to take effect — log out/in, or start a new shell (e.g. 'newgrp docker') before using docker without sudo."
    fi

    if docker info &>/dev/null 2>&1; then
        success "Docker installed and running: $(docker --version)"
    else
        warn "Docker installed but not yet usable in this shell — likely the group membership above. Open a new terminal and run 'docker.sh status' to confirm."
    fi
}

# -----------------------------------------------------------------------------
# uninstall
# -----------------------------------------------------------------------------

cmd_uninstall() {
    header "Docker — Uninstall"

    command -v docker &>/dev/null || { warn "Docker doesn't appear to be installed."; return; }

    gum confirm "This stops the docker service and removes the docker packages. Continue?" \
        || { info "Cancelled."; return; }

    _require_sudo_or_instruct "Stopping the docker service" "sudo systemctl disable --now docker"
    sudo systemctl disable --now docker 2>/dev/null || true

    local pm; pm="$(_pkg_manager)"
    case "$pm" in
        dnf)
            _require_sudo_or_instruct "Removing docker packages" "sudo dnf remove -y moby-engine docker-cli"
            sudo dnf remove -y moby-engine docker-cli || warn "Package removal failed — check manually."
            # Compose removed separately/best-effort: 'dnf remove' fails the whole
            # transaction if a named package isn't installed.
            for p in docker-compose-plugin docker-compose; do sudo dnf remove -y "$p" 2>/dev/null || true; done
            ;;
        apt)
            _require_sudo_or_instruct "Removing docker packages" "sudo apt-get remove -y docker.io docker-compose-v2"
            sudo apt-get remove -y docker.io docker-compose-v2 || warn "Package removal failed — check manually."
            ;;
        rpm-ostree)
            _require_sudo_or_instruct "Removing layered docker packages" "rpm-ostree uninstall moby-engine docker-cli"
            rpm-ostree uninstall moby-engine docker-cli || warn "Package removal failed — check manually."
            for p in docker-compose-plugin docker-compose; do rpm-ostree uninstall "$p" 2>/dev/null || true; done
            warn "A reboot is required to fully remove the layered packages."
            ;;
        *) warn "Unknown package manager — remove docker packages manually." ;;
    esac

    if [[ -d /var/lib/docker ]] && gum confirm "Also delete /var/lib/docker (all images, containers, volumes)? This cannot be undone."; then
        _require_sudo_or_instruct "Deleting /var/lib/docker" "sudo rm -rf /var/lib/docker"
        sudo rm -rf /var/lib/docker && success "/var/lib/docker removed."
    fi

    success "Docker uninstalled."
}

# -----------------------------------------------------------------------------
# status
# -----------------------------------------------------------------------------

cmd_status() {
    header "Docker — Status"

    if ! command -v docker &>/dev/null; then
        warn "docker CLI not found. Run: docker.sh install"
        return
    fi
    success "docker CLI: $(docker --version)"

    if systemctl is-active docker &>/dev/null; then
        success "docker service: active"
    else
        warn "docker service: not active (sudo systemctl start docker)"
    fi

    if docker info &>/dev/null 2>&1; then
        success "docker daemon reachable."
    else
        warn "docker daemon not reachable from this shell — check group membership (are you in the 'docker' group? try a new shell) or run with sudo."
    fi

    command -v docker-compose &>/dev/null && info "docker-compose: $(docker-compose --version)"
    docker compose version &>/dev/null 2>&1 && info "docker compose plugin: $(docker compose version)"
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
            *) error_exit "Unknown command: $1 (expected: install|uninstall|status)" ;;
        esac
        exit 0
    fi

    while true; do
        header "Docker Manager"
        local action
        action=$(gum choose "install" "uninstall" "status" "quit" --header "Choose an action:") || true
        [[ -z "$action" || "$action" == "quit" ]] && { gum style --faint "Bye."; exit 0; }

        case "$action" in
            install)   cmd_install ;;
            uninstall) cmd_uninstall ;;
            status)    cmd_status ;;
        esac

        echo ""
        gum confirm "Back to main menu?" || { gum style --faint "Bye."; exit 0; }
    done
}

main "$@"
