#!/usr/bin/env bash
# Dependency check helpers.  Sourced by app scripts — do NOT run directly.

_check_docker() {
    if ! command -v docker &>/dev/null; then
        gum log --level error "docker is not installed or not in PATH."
        exit 1
    fi
    if ! docker info &>/dev/null 2>&1; then
        gum log --level error "Docker daemon is not running. Start Docker and retry."
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
