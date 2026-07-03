#!/usr/bin/env bash
# Dependency check helpers.  Sourced by app scripts — do NOT run directly.

_check_docker() {
    if ! command -v docker &>/dev/null; then
        gum log --level error "docker is not installed or not in PATH. Run: docker.sh install (scripts/docker/docker.sh)"
        exit 1
    fi
    if ! docker info &>/dev/null 2>&1; then
        gum log --level error "Docker daemon is not running/reachable. Try: docker.sh status (scripts/docker/docker.sh) to diagnose, or start Docker and retry."
        exit 1
    fi
    info "docker: $(docker --version 2>/dev/null | head -1)"
}

_check_kubectl() {
    if ! command -v kubectl &>/dev/null; then
        gum log --level error "kubectl is not installed or not in PATH."
        gum log --level error "Install kubectl: https://kubernetes.io/docs/tasks/tools/"
        exit 1
    fi
    info "kubectl: $(kubectl version --client 2>/dev/null | head -1)"
}

# _ensure_helm [app-label]
_ensure_helm() {
    local label="${1:-this service}"
    if command -v helm &>/dev/null; then
        info "helm: $(helm version --short 2>/dev/null)"
        return
    fi

    gum style \
        --foreground "${YELLOW:-220}" --border-foreground "${YELLOW:-220}" --border rounded \
        --align center --width 60 --margin "1 2" --padding "1 4" \
        "helm not found" \
        "helm is required to install ${label} on Kubernetes."

    if ! gum confirm "Install helm via mise?"; then
        error_exit "helm is required for Kubernetes installs. Aborting."
    fi

    if ! command -v mise &>/dev/null; then
        error_exit "mise is not installed. Run setup.sh first, then retry."
    fi

    if ! gum spin --spinner dot --title "Installing helm via mise..." -- \
        mise install helm@latest; then
        error_exit "Failed to install helm. Check your mise configuration."
    fi

    export PATH="$HOME/.local/share/mise/shims:$PATH"

    command -v helm &>/dev/null \
        || error_exit "helm installed but not found in PATH. Check mise shims."
    success "helm installed: $(helm version --short 2>/dev/null)"
}

# _pkg_manager — echoes "rpm-ostree" | "dnf" | "apt" | "" (none supported).
# rpm-ostree takes priority: on immutable Fedora Atomic hosts (e.g. Bazzite),
# dnf usually isn't meant to be used directly even if present.
_pkg_manager() {
    if command -v rpm-ostree &>/dev/null; then echo "rpm-ostree";
    elif command -v dnf &>/dev/null; then echo "dnf";
    elif command -v apt-get &>/dev/null; then echo "apt";
    else echo ""; fi
}

# _require_sudo_or_instruct <description> <command to hand back to the user>
# Bails with clear manual instructions when passwordless sudo / a TTY for a
# password prompt isn't available, instead of hanging or silently failing.
_require_sudo_or_instruct() {
    local desc="$1"; shift
    # Already has a cached/passwordless credential — nothing to prompt for.
    sudo -n true 2>/dev/null && return 0
    # No cached credential, but a real terminal is attached — sudo can just
    # prompt for the password normally here; no need to bail.
    [[ -t 0 && -t 1 ]] && return 0
    # No TTY at all (e.g. a non-interactive tool/CI session) — sudo would
    # hang waiting for a password it can never receive. Bail with manual
    # instructions instead of hanging.
    warn "${desc} requires sudo, and this session has no TTY for a password prompt."
    error_exit "Please run this yourself in a terminal, then re-run this script:
  $*"
}

# _ensure_pkg <binary-to-check> <dnf/rpm-ostree-pkg-name> [apt-pkg-name]
# Installs a system package via whichever package manager is available.
# On rpm-ostree (immutable systems like Bazzite), the package is layered and
# requires a reboot before the binary becomes available — the function warns
# and offers to reboot rather than pretending the install is immediately live.
_ensure_pkg() {
    local check_bin="$1" pkg_dnf="$2" pkg_apt="${3:-$2}"
    if command -v "$check_bin" &>/dev/null; then
        info "${check_bin} found: $(command -v "$check_bin")"
        return 0
    fi

    local pm; pm="$(_pkg_manager)"
    [[ -z "$pm" ]] && error_exit "No supported package manager found (need dnf, apt, or rpm-ostree) to install '${pkg_dnf}'."

    info "${check_bin} not found. Installing '${pkg_dnf}' via ${pm}..."
    case "$pm" in
        rpm-ostree)
            _require_sudo_or_instruct "Layering ${pkg_dnf} via rpm-ostree" "rpm-ostree install -y ${pkg_dnf}"
            rpm-ostree install -y "$pkg_dnf" || error_exit "rpm-ostree install failed for ${pkg_dnf}."
            warn "Package layered via rpm-ostree — a REBOOT is required before '${check_bin}' becomes available."
            if gum confirm "Reboot now?"; then
                systemctl reboot
            fi
            return 1
            ;;
        dnf)
            _require_sudo_or_instruct "Installing ${pkg_dnf}" "sudo dnf install -y ${pkg_dnf}"
            sudo dnf install -y "$pkg_dnf" || error_exit "dnf install failed for ${pkg_dnf}."
            ;;
        apt)
            _require_sudo_or_instruct "Installing ${pkg_apt}" "sudo apt-get update -qq && sudo apt-get install -y ${pkg_apt}"
            sudo apt-get update -qq && sudo apt-get install -y "$pkg_apt" || error_exit "apt install failed for ${pkg_apt}."
            ;;
    esac
    command -v "$check_bin" &>/dev/null || error_exit "${check_bin} installation appears to have failed."
    success "${check_bin} installed."
}

# _ensure_pkgs <dnf-pkg-list> <apt-pkg-list>
# Bulk-installs packages that have no single checkable binary — typically
# -dev/-devel libraries (e.g. libace-dev / libtbb-dev). Unlike _ensure_pkg,
# this always runs the install command; apt/dnf no-op cleanly on packages
# that are already installed, so this stays safe to call on every run.
# Each list is space-separated, e.g.: _ensure_pkgs "ace-devel tbb-devel" "libace-dev libtbb-dev"
_ensure_pkgs() {
    local dnf_pkgs="$1" apt_pkgs="$2"
    local pm; pm="$(_pkg_manager)"
    [[ -z "$pm" ]] && error_exit "No supported package manager found (need dnf, apt, or rpm-ostree)."

    info "Ensuring packages installed via ${pm}: $([[ "$pm" == "apt" ]] && echo "$apt_pkgs" || echo "$dnf_pkgs")"
    case "$pm" in
        rpm-ostree)
            _require_sudo_or_instruct "Layering packages via rpm-ostree" "rpm-ostree install -y ${dnf_pkgs}"
            # shellcheck disable=SC2086
            rpm-ostree install -y $dnf_pkgs || error_exit "rpm-ostree install failed for: ${dnf_pkgs}"
            warn "Packages layered via rpm-ostree — a REBOOT is required before they're available."
            if gum confirm "Reboot now?"; then
                systemctl reboot
            fi
            ;;
        dnf)
            _require_sudo_or_instruct "Installing packages" "sudo dnf install -y ${dnf_pkgs}"
            # shellcheck disable=SC2086
            sudo dnf install -y $dnf_pkgs || error_exit "dnf install failed for: ${dnf_pkgs}"
            ;;
        apt)
            _require_sudo_or_instruct "Installing packages" "sudo apt-get update -qq && sudo apt-get install -y ${apt_pkgs}"
            # shellcheck disable=SC2086
            sudo apt-get update -qq && sudo apt-get install -y $apt_pkgs \
                || error_exit "apt install failed for: ${apt_pkgs}"
            ;;
    esac
    success "Packages installed."
}

# _ensure_helm_repo <repo-name> <repo-url>
_ensure_helm_repo() {
    local repo_name="$1"
    local repo_url="$2"
    if helm repo list 2>/dev/null | grep -q "^${repo_name}[[:space:]]"; then
        info "Helm repo '${repo_name}' already present."
    else
        info "Adding Helm repo '${repo_name}'..."
        gum spin --spinner dot --title "Adding Helm repo '${repo_name}'..." -- \
            helm repo add "$repo_name" "$repo_url" \
            || error_exit "Failed to add Helm repo '${repo_name}'."
    fi
    gum spin --spinner dot --title "Updating Helm repo '${repo_name}'..." -- \
        helm repo update "$repo_name" 2>/dev/null || true
}
