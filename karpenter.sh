#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# karpenter.sh
# Interactive TUI for installing and managing Karpenter locally (dev/testing).
# Uses KWOK as the simulated cloud provider for kind-based local clusters.
# Called by common.sh — expects gum to be available.
# Hard dependencies (abort if missing): docker, kind, go  — install via their
#   dedicated scripts first.
# Soft dependencies (offer to install): ko, make, kubectl.
# Sources: karpenter (kubernetes-sigs/karpenter) + KWOK (kubernetes-sigs/kwok).
# -----------------------------------------------------------------------------

set -euo pipefail

# -----------------------------------------------------------------------------
# Constants
# -----------------------------------------------------------------------------

KARPENTER_REPO="https://github.com/kubernetes-sigs/karpenter"
KWOK_REPO="https://github.com/kubernetes-sigs/kwok"
DEFAULT_WORK_DIR="${HOME}/karpenter-local"
KARPENTER_NAMESPACE="karpenter"
CERT_MANAGER_VERSION="v1.16.1"

# Colours
CYAN=212
RED=196
GREEN=82
YELLOW=220
BLUE=39

# Script-level globals — updated by setup_work_dir()
WORK_DIR="${DEFAULT_WORK_DIR}"
KARPENTER_DIR="${DEFAULT_WORK_DIR}/karpenter"
KWOK_DIR="${DEFAULT_WORK_DIR}/kwok"

# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------

header() {
    gum style \
        --foreground "$CYAN" --border-foreground "$CYAN" --border rounded \
        --align center --width 66 --padding "1 4" --margin "1 0" \
        "$1"
}

info()       { gum log --level info "$1"; }
success()    { gum style --foreground "$GREEN" "[ok] $1"; }
warn()       { gum style --foreground "$YELLOW" "[warn] $1"; }
error_exit() { gum style --foreground "$RED" "[error] $1"; exit 1; }

# -----------------------------------------------------------------------------
# Dependency checks
# -----------------------------------------------------------------------------

_fatal() { printf "\033[0;31m[ERROR] %s\033[0m\n" "$*" >&2; exit 1; }

check_gum() {
    command -v gum &>/dev/null || _fatal "gum not found. Run setup.sh first."
}

# docker — hard dependency, abort if missing
_check_docker() {
    if ! command -v docker &>/dev/null; then
        gum log --level error "docker is not installed or not in PATH."
        gum log --level error "install Docker first."
        exit 1
    fi
    if ! docker info &>/dev/null 2>&1; then
        gum log --level error "Docker daemon is not running. Start Docker and retry."
        exit 1
    fi
    info "docker: $(docker --version 2>/dev/null | head -1)"
}

# kind — hard dependency, abort if missing
_check_kind() {
    if ! command -v kind &>/dev/null; then
        gum log --level error "kind is not installed or not in PATH."
        gum log --level error "Run kind.sh first to install kind."
        exit 1
    fi
    info "kind: $(kind version 2>/dev/null)"
}

# go — hard dependency, abort if missing
_check_go() {
    if ! command -v go &>/dev/null; then
        gum log --level error "Go is not installed or not in PATH."
        gum log --level error "Install Go via its dedicated script or: mise use --global go"
        exit 1
    fi
    info "go: $(go version 2>/dev/null)"
}

# ko — soft dependency, offer to install via go install
ensure_ko() {
    if command -v ko &>/dev/null; then
        info "ko: $(ko version 2>/dev/null || echo 'installed')"
        return
    fi

    gum style \
        --foreground "$YELLOW" --border-foreground "$YELLOW" --border rounded \
        --align center --width 60 --margin "1 2" --padding "1 4" \
        "ko not found" \
        "ko builds and publishes container images for Karpenter."

    if ! gum confirm "Install ko via 'go install github.com/google/ko@latest'?"; then
        error_exit "ko is required. Aborting."
    fi

    if ! gum spin --spinner dot --title "Installing ko..." -- \
        go install github.com/google/ko@latest; then
        error_exit "Failed to install ko. Check your Go environment and retry."
    fi

    # go install puts binaries in $GOPATH/bin or $GOBIN
    local gobin
    gobin="$(go env GOPATH)/bin"
    export PATH="${gobin}:${PATH}"

    if ! command -v ko &>/dev/null; then
        error_exit "ko installed but not found in PATH. Add '$(go env GOPATH)/bin' to your PATH."
    fi
    success "ko installed: $(ko version 2>/dev/null || echo 'ok')"
}

# make — soft dependency, offer to install via system package manager
ensure_make() {
    if command -v make &>/dev/null; then
        info "make: $(make --version 2>/dev/null | head -1)"
        return
    fi

    gum style \
        --foreground "$YELLOW" --border-foreground "$YELLOW" --border rounded \
        --align center --width 60 --margin "1 2" --padding "1 4" \
        "make not found" \
        "make is required to build Karpenter from source."

    if ! gum confirm "Install make?"; then
        error_exit "make is required. Aborting."
    fi

    local os
    os=$(uname -s)

    if [[ "$os" == "Darwin" ]]; then
        if ! gum spin --spinner dot --title "Installing make via brew..." -- \
            brew install make; then
            error_exit "Failed to install make via brew."
        fi
        # brew installs GNU make as 'gmake'; add its gnubin to PATH
        local gnubin
        gnubin="$(brew --prefix)/opt/make/libexec/gnubin"
        [[ -d "$gnubin" ]] && export PATH="${gnubin}:${PATH}"
    elif command -v apt-get &>/dev/null; then
        if ! gum spin --spinner dot --title "Installing make via apt..." -- \
            sudo apt-get install -y make; then
            error_exit "Failed to install make via apt."
        fi
    elif command -v dnf &>/dev/null; then
        if ! gum spin --spinner dot --title "Installing make via dnf..." -- \
            sudo dnf install -y make; then
            error_exit "Failed to install make via dnf."
        fi
    else
        error_exit "Cannot auto-install make on this system. Install it manually and retry."
    fi

    if ! command -v make &>/dev/null; then
        error_exit "make installed but not found in PATH."
    fi
    success "make installed: $(make --version 2>/dev/null | head -1)"
}

# kubectl — soft dependency, offer to install via mise
ensure_kubectl() {
    if command -v kubectl &>/dev/null; then
        info "kubectl: $(kubectl version --client 2>/dev/null | head -1)"
        return
    fi

    gum style \
        --foreground "$YELLOW" --border-foreground "$YELLOW" --border rounded \
        --align center --width 60 --margin "1 2" --padding "1 4" \
        "kubectl not found" \
        "kubectl is required to manage Kubernetes resources."

    if ! gum confirm "Install kubectl via mise?"; then
        error_exit "kubectl is required. Aborting."
    fi

    if ! command -v mise &>/dev/null; then
        error_exit "mise is not installed. Run setup.sh first, then retry."
    fi

    if ! gum spin --spinner dot --title "Installing kubectl via mise..." -- \
        mise install kubectl@latest; then
        error_exit "Failed to install kubectl via mise."
    fi

    export PATH="$HOME/.local/share/mise/shims:$PATH"

    if ! command -v kubectl &>/dev/null; then
        error_exit "kubectl installed but not found in PATH. Check mise shims configuration."
    fi
    success "kubectl installed: $(kubectl version --client 2>/dev/null | head -1)"
}

check_dependencies() {
    info "Checking required dependencies..."

    _check_docker
    _check_kind
    _check_go

    ensure_ko
    ensure_make
    ensure_kubectl

    if ! command -v git &>/dev/null; then
        gum log --level error "git is not installed or not in PATH. Install git and retry."
        exit 1
    fi
    info "git: $(git --version 2>/dev/null)"
}

# -----------------------------------------------------------------------------
# Work directory
# -----------------------------------------------------------------------------

setup_work_dir() {
    local input
    input=$(gum input \
        --placeholder "${DEFAULT_WORK_DIR}" \
        --char-limit 120 \
        --header "Work directory for Karpenter source (leave empty for default):") || true

    WORK_DIR="${input:-${DEFAULT_WORK_DIR}}"
    KARPENTER_DIR="${WORK_DIR}/karpenter"
    KWOK_DIR="${WORK_DIR}/kwok"

    mkdir -p "${WORK_DIR}"
    info "Work directory: ${WORK_DIR}"
}

# -----------------------------------------------------------------------------
# Source management
# -----------------------------------------------------------------------------

clone_or_update_repo() {
    local label="$1"
    local repo_url="$2"
    local target_dir="$3"

    if [[ -d "${target_dir}/.git" ]]; then
        info "${label} source found at ${target_dir} — pulling latest..."
        if ! gum spin --spinner dot --title "Updating ${label}..." -- \
            git -C "${target_dir}" pull --ff-only; then
            warn "Could not fast-forward ${label}. The repository may have local changes."
        fi
        success "${label} source up to date."
    else
        info "Cloning ${label} from ${repo_url}..."
        if ! gum spin --spinner dot --title "Cloning ${label}..." -- \
            git clone "${repo_url}" "${target_dir}"; then
            error_exit "Failed to clone ${label}. Check your internet connection and retry."
        fi
        success "${label} cloned to ${target_dir}."
    fi
}

prepare_sources() {
    setup_work_dir
    clone_or_update_repo "Karpenter" "${KARPENTER_REPO}" "${KARPENTER_DIR}"
    clone_or_update_repo "KWOK"      "${KWOK_REPO}"      "${KWOK_DIR}"
}

# -----------------------------------------------------------------------------
# Cluster — ensure a kind cluster is active
# -----------------------------------------------------------------------------

# Prints all kind cluster names, one per line (empty if none).
_list_kind_clusters() {
    kind get clusters 2>/dev/null || true
}

# Switches kubectl context to the given kind cluster.
_use_kind_cluster() {
    local cluster_name="$1"
    local context="kind-${cluster_name}"
    if ! kubectl config use-context "${context}" &>/dev/null; then
        # kind may not have written the kubeconfig yet — fetch it
        kind export kubeconfig --name "${cluster_name}" 2>/dev/null || true
        kubectl config use-context "${context}" &>/dev/null \
            || error_exit "Could not switch to context '${context}'."
    fi
    info "Switched to context: ${context}"
}

# Creates a new kind cluster with the given name.
_create_kind_cluster() {
    local cluster_name="$1"
    info "Creating kind cluster '${cluster_name}'..."
    if ! gum spin --spinner dot --title "Creating kind cluster '${cluster_name}'..." -- \
        kind create cluster --name "${cluster_name}"; then
        error_exit "Failed to create kind cluster '${cluster_name}'."
    fi
    success "Kind cluster '${cluster_name}' created."
}

# Ensures an active kind cluster context is set.
# - If the current context is already a kind cluster, use it.
# - Otherwise list existing kind clusters and let the user pick one,
#   or create a new one.
check_cluster() {
    info "Checking for a kind cluster..."

    # Is the current context already a kind cluster?
    local current_ctx
    current_ctx=$(kubectl config current-context 2>/dev/null || true)
    if [[ "$current_ctx" == kind-* ]]; then
        local cluster_name="${current_ctx#kind-}"
        if kind get clusters 2>/dev/null | grep -qx "${cluster_name}"; then
            info "Already using kind cluster '${cluster_name}' (context: ${current_ctx})."
            if ! gum spin --spinner dot --title "Connecting to cluster..." -- \
                kubectl cluster-info &>/dev/null; then
                gum log --level error "Cannot reach cluster '${cluster_name}'. Is Docker running?"
                exit 1
            fi
            info "Cluster reachable."
            return
        fi
    fi

    # List available kind clusters
    local clusters
    clusters=$(_list_kind_clusters)

    if [[ -z "$clusters" ]]; then
        gum style \
            --foreground "$YELLOW" --border-foreground "$YELLOW" --border rounded \
            --align center --width 60 --margin "1 2" --padding "1 4" \
            "No kind clusters found." \
            "" \
            "A local kind cluster is required to run Karpenter."

        if ! gum confirm "Create a new kind cluster now?"; then
            error_exit "A kind cluster is required. Use kind.sh to manage clusters."
        fi

        local new_name
        new_name=$(gum input \
            --placeholder "karpenter" \
            --char-limit 40 \
            --header "Cluster name (leave empty for 'karpenter'):") || true
        new_name="${new_name:-karpenter}"

        _create_kind_cluster "${new_name}"
        _use_kind_cluster "${new_name}"
    else
        local cluster_count
        cluster_count=$(echo "$clusters" | wc -l | tr -d ' ')

        local chosen
        if [[ "$cluster_count" -eq 1 ]]; then
            chosen="${clusters}"
            gum style \
                --foreground "$YELLOW" --border-foreground "$YELLOW" --border rounded \
                --align center --width 60 --margin "1 2" --padding "1 4" \
                "Current context is not a kind cluster." \
                "" \
                "Found kind cluster: ${chosen}"

            if ! gum confirm "Switch to kind cluster '${chosen}'?"; then
                error_exit "A kind cluster context is required. Aborting."
            fi
        else
            gum log --level warn "Current context is not a kind cluster."
            chosen=$(echo "$clusters" | gum choose \
                --header "Select a kind cluster to use:" \
                --height 10) || true

            if [[ -z "$chosen" ]]; then
                if gum confirm "No cluster selected. Create a new one?"; then
                    local new_name
                    new_name=$(gum input \
                        --placeholder "karpenter" \
                        --char-limit 40 \
                        --header "Cluster name (leave empty for 'karpenter'):") || true
                    new_name="${new_name:-karpenter}"
                    _create_kind_cluster "${new_name}"
                    chosen="${new_name}"
                else
                    error_exit "A kind cluster context is required. Aborting."
                fi
            fi
        fi

        _use_kind_cluster "${chosen}"
    fi

    if ! gum spin --spinner dot --title "Connecting to cluster..." -- \
        kubectl cluster-info &>/dev/null; then
        gum log --level error "Cannot reach cluster. Is Docker running?"
        exit 1
    fi
    info "Cluster reachable."
}

# -----------------------------------------------------------------------------
# cert-manager
# -----------------------------------------------------------------------------

install_cert_manager() {
    info "Checking cert-manager..."

    if kubectl get namespace cert-manager &>/dev/null 2>&1; then
        info "cert-manager namespace already exists — skipping install."
        return
    fi

    info "Installing cert-manager ${CERT_MANAGER_VERSION}..."
    if ! gum spin --spinner dot --title "Applying cert-manager manifests..." -- \
        kubectl apply -f \
        "https://github.com/cert-manager/cert-manager/releases/download/${CERT_MANAGER_VERSION}/cert-manager.yaml"; then
        error_exit "Failed to apply cert-manager manifests."
    fi

    if ! gum spin --spinner dot --title "Waiting for cert-manager to become ready (up to 2 min)..." -- \
        kubectl rollout status deployment/cert-manager-webhook \
            -n cert-manager --timeout=120s; then
        warn "cert-manager webhook rollout timed out. It may still be starting."
    fi
    success "cert-manager ready."
}

# -----------------------------------------------------------------------------
# KWOK
# -----------------------------------------------------------------------------

install_kwok_in_cluster() {
    info "Checking KWOK operator in cluster..."

    if kubectl get namespace kwok-system &>/dev/null 2>&1; then
        info "KWOK already installed (namespace kwok-system exists)."
        return
    fi

    info "Fetching latest KWOK release tag..."
    local kwok_ver
    kwok_ver=$(gum spin --spinner dot --title "Fetching KWOK release..." -- \
        bash -c "curl -fsSL 'https://api.github.com/repos/kubernetes-sigs/kwok/releases/latest' \
            2>/dev/null | grep '\"tag_name\"' \
            | sed 's/.*\"tag_name\": *\"\(.*\)\".*/\1/'" 2>/dev/null || echo "v0.6.0")
    kwok_ver="${kwok_ver:-v0.6.0}"
    info "Installing KWOK ${kwok_ver}..."

    if ! gum spin --spinner dot --title "Installing KWOK ${kwok_ver}..." -- \
        kubectl apply -f \
        "https://github.com/kubernetes-sigs/kwok/releases/download/${kwok_ver}/kwok.yaml"; then
        error_exit "Failed to install KWOK. Check your cluster connectivity."
    fi

    # Apply default stages (simulated node lifecycle)
    gum spin --spinner dot --title "Applying KWOK default stages..." -- \
        kubectl apply -f \
        "https://github.com/kubernetes-sigs/kwok/releases/download/${kwok_ver}/stage-fast.yaml" \
        2>/dev/null || warn "Could not apply KWOK stage-fast.yaml — nodes may not simulate properly."

    if ! gum spin --spinner dot --title "Waiting for KWOK controller (up to 90 s)..." -- \
        kubectl rollout status deployment/kwok-controller \
            -n kwok-system --timeout=90s; then
        warn "KWOK controller rollout timed out. It may still be starting."
    fi
    success "KWOK ${kwok_ver} installed."
}

# -----------------------------------------------------------------------------
# Build and deploy Karpenter via ko
# -----------------------------------------------------------------------------

build_and_deploy_karpenter() {
    if [[ ! -d "${KARPENTER_DIR}" ]]; then
        error_exit "Karpenter source not found at ${KARPENTER_DIR}. Clone sources first."
    fi

    gum style \
        --foreground "$CYAN" --border-foreground "$CYAN" --border rounded \
        --align left --width 66 --margin "1 2" --padding "1 4" \
        "Build & Deploy Karpenter" \
        "" \
        "ko will build the controller image and deploy it to your cluster." \
        "For kind clusters, use 'ko.local' as the registry." \
        "For a local registry, use 'localhost:5001' (or your registry address)."

    local ko_docker_repo
    ko_docker_repo=$(gum input \
        --placeholder "ko.local" \
        --char-limit 120 \
        --header "KO_DOCKER_REPO (ko.local for kind, or your registry):") || true
    ko_docker_repo="${ko_docker_repo:-ko.local}"

    info "Building Karpenter with KO_DOCKER_REPO=${ko_docker_repo}..."
    info "This may take several minutes on first build."

    if ! gum spin --spinner dot \
        --title "Building and deploying Karpenter (this may take a few minutes)..." -- \
        bash -c "cd '${KARPENTER_DIR}' && KO_DOCKER_REPO='${ko_docker_repo}' make apply"; then
        error_exit "Build/deploy failed. Review the error output above."
    fi

    if ! gum spin --spinner dot \
        --title "Waiting for Karpenter controller (up to 3 min)..." -- \
        kubectl rollout status deployment/karpenter \
            -n "${KARPENTER_NAMESPACE}" --timeout=180s; then
        warn "Karpenter rollout timed out. Check: kubectl get pods -n ${KARPENTER_NAMESPACE}"
    fi

    success "Karpenter deployed from source."
}

# -----------------------------------------------------------------------------
# Install flow
# -----------------------------------------------------------------------------

karpenter_install() {
    header "Install Karpenter (Local)"

    # Ensure sources exist
    if [[ ! -d "${KARPENTER_DIR}/.git" ]]; then
        gum style \
            --foreground "$YELLOW" --border-foreground "$YELLOW" --border rounded \
            --align center --width 60 --margin "1 2" --padding "1 4" \
            "Karpenter source not found at:" \
            "${KARPENTER_DIR}" \
            "" \
            "Sources must be cloned before installing."

        if ! gum confirm "Clone Karpenter and KWOK sources now?"; then
            warn "Install cancelled."
            return
        fi
        prepare_sources
    fi

    check_cluster
    install_cert_manager
    install_kwok_in_cluster
    build_and_deploy_karpenter

    gum style \
        --foreground "$GREEN" --border-foreground "$GREEN" --border rounded \
        --align center --width 66 --margin "1 2" --padding "1 4" \
        "Karpenter is running locally" \
        "" \
        "Source:    ${KARPENTER_DIR}" \
        "KWOK src:  ${KWOK_DIR}" \
        "" \
        "Try: kubectl get pods -n ${KARPENTER_NAMESPACE}" \
        "     kubectl get nodepools"
}

# -----------------------------------------------------------------------------
# Status
# -----------------------------------------------------------------------------

karpenter_status() {
    header "Karpenter Status"
    check_cluster

    gum style --foreground "$CYAN" --bold "── Karpenter pods ──"
    kubectl get pods -n "${KARPENTER_NAMESPACE}" 2>/dev/null \
        || warn "Namespace '${KARPENTER_NAMESPACE}' not found — Karpenter may not be installed."

    echo ""
    gum style --foreground "$CYAN" --bold "── Karpenter CRDs ──"
    kubectl get crd 2>/dev/null | grep -i karpenter \
        || warn "No Karpenter CRDs found."

    echo ""
    gum style --foreground "$CYAN" --bold "── KWOK pods ──"
    kubectl get pods -n kwok-system 2>/dev/null \
        || warn "KWOK not installed (namespace kwok-system not found)."

    echo ""
    gum style --foreground "$CYAN" --bold "── NodePools ──"
    kubectl get nodepools 2>/dev/null \
        || warn "No NodePool CRD found."

    echo ""
    gum style --foreground "$CYAN" --bold "── NodeClaims ──"
    kubectl get nodeclaims 2>/dev/null \
        || warn "No NodeClaim CRD found."

    echo ""
    gum style --foreground "$CYAN" --bold "── Source locations ──"
    if [[ -d "${KARPENTER_DIR}/.git" ]]; then
        local karpenter_rev
        karpenter_rev=$(git -C "${KARPENTER_DIR}" log --oneline -1 2>/dev/null || echo "unknown")
        gum log --level info "Karpenter: ${KARPENTER_DIR} (${karpenter_rev})"
    else
        warn "Karpenter source not found at ${KARPENTER_DIR}."
    fi
    if [[ -d "${KWOK_DIR}/.git" ]]; then
        local kwok_rev
        kwok_rev=$(git -C "${KWOK_DIR}" log --oneline -1 2>/dev/null || echo "unknown")
        gum log --level info "KWOK:      ${KWOK_DIR} (${kwok_rev})"
    else
        warn "KWOK source not found at ${KWOK_DIR}."
    fi
}

# -----------------------------------------------------------------------------
# Uninstall
# -----------------------------------------------------------------------------

karpenter_uninstall() {
    header "Uninstall Karpenter"
    check_cluster

    gum style \
        --foreground "$RED" --border-foreground "$RED" --border rounded \
        --align center --width 66 --margin "1 2" --padding "1 4" \
        "WARNING: Destructive operation" \
        "" \
        "Namespace '${KARPENTER_NAMESPACE}' and all Karpenter CRDs" \
        "will be permanently removed from the cluster."

    if ! gum confirm "Are you sure you want to uninstall Karpenter?"; then
        warn "Uninstall cancelled."
        return
    fi

    if ! gum confirm "Confirm: remove all Karpenter resources from the cluster?"; then
        warn "Uninstall cancelled."
        return
    fi

    # Prefer 'make delete' if source is available
    if [[ -d "${KARPENTER_DIR}" ]]; then
        if gum confirm "Use 'make delete' from source (recommended, cleanest teardown)?"; then
            if gum spin --spinner dot --title "Running make delete..." -- \
                bash -c "cd '${KARPENTER_DIR}' && make delete 2>/dev/null"; then
                success "make delete completed."
            else
                warn "make delete failed or target not available. Falling back to manual cleanup."
                _uninstall_manual
            fi
        else
            _uninstall_manual
        fi
    else
        _uninstall_manual
    fi

    if gum confirm "Also uninstall KWOK from the cluster?"; then
        _uninstall_kwok
    fi

    if gum confirm "Remove local source directories (${WORK_DIR})?"; then
        _remove_sources
    fi
}

_uninstall_manual() {
    info "Removing Karpenter namespace..."
    gum spin --spinner dot --title "Deleting namespace '${KARPENTER_NAMESPACE}'..." -- \
        kubectl delete namespace "${KARPENTER_NAMESPACE}" --ignore-not-found || true

    info "Removing Karpenter CRDs..."
    local crds
    crds=$(kubectl get crd 2>/dev/null | grep -i karpenter | awk '{print $1}' || true)
    if [[ -n "$crds" ]]; then
        echo "$crds" | while IFS= read -r crd; do
            kubectl delete crd "$crd" --ignore-not-found 2>/dev/null \
                && info "  Removed CRD: ${crd}" || true
        done
    else
        info "No Karpenter CRDs found."
    fi

    success "Karpenter removed from cluster."
}

_uninstall_kwok() {
    info "Removing KWOK namespace..."
    gum spin --spinner dot --title "Deleting namespace 'kwok-system'..." -- \
        kubectl delete namespace kwok-system --ignore-not-found || true

    local kwok_crds
    kwok_crds=$(kubectl get crd 2>/dev/null | grep -i kwok | awk '{print $1}' || true)
    if [[ -n "$kwok_crds" ]]; then
        echo "$kwok_crds" | while IFS= read -r crd; do
            kubectl delete crd "$crd" --ignore-not-found 2>/dev/null \
                && info "  Removed CRD: ${crd}" || true
        done
    fi
    success "KWOK removed from cluster."
}

_remove_sources() {
    [[ -d "${KARPENTER_DIR}" ]] && {
        gum spin --spinner dot --title "Removing ${KARPENTER_DIR}..." -- \
            rm -rf "${KARPENTER_DIR}"
        success "Removed ${KARPENTER_DIR}"
    }
    [[ -d "${KWOK_DIR}" ]] && {
        gum spin --spinner dot --title "Removing ${KWOK_DIR}..." -- \
            rm -rf "${KWOK_DIR}"
        success "Removed ${KWOK_DIR}"
    }
    # Remove work dir only if now empty
    [[ -d "${WORK_DIR}" ]] && rmdir "${WORK_DIR}" 2>/dev/null \
        && success "Removed ${WORK_DIR}" || true
}

# -----------------------------------------------------------------------------
# Sources submenu
# -----------------------------------------------------------------------------

sources_menu() {
    while true; do
        header "Source Management"

        local action
        action=$(gum choose \
            "clone / update all" \
            "clone / update karpenter only" \
            "clone / update kwok only" \
            "change work directory" \
            "show source info" \
            "← back" \
            --header "Select action:") || true

        case "$action" in
            "clone / update all")
                clone_or_update_repo "Karpenter" "${KARPENTER_REPO}" "${KARPENTER_DIR}"
                clone_or_update_repo "KWOK"      "${KWOK_REPO}"      "${KWOK_DIR}"
                ;;
            "clone / update karpenter only")
                clone_or_update_repo "Karpenter" "${KARPENTER_REPO}" "${KARPENTER_DIR}"
                ;;
            "clone / update kwok only")
                clone_or_update_repo "KWOK" "${KWOK_REPO}" "${KWOK_DIR}"
                ;;
            "change work directory")
                setup_work_dir
                ;;
            "show source info")
                gum style \
                    --foreground "$CYAN" --border-foreground "$CYAN" --border rounded \
                    --align left --width 66 --margin "1 2" --padding "1 4" \
                    "Work dir:        ${WORK_DIR}" \
                    "Karpenter src:   ${KARPENTER_DIR}" \
                    "  repo:          ${KARPENTER_REPO}" \
                    "KWOK src:        ${KWOK_DIR}" \
                    "  repo:          ${KWOK_REPO}"
                if [[ -d "${KARPENTER_DIR}/.git" ]]; then
                    info "Karpenter HEAD: $(git -C "${KARPENTER_DIR}" log --oneline -1 2>/dev/null)"
                fi
                if [[ -d "${KWOK_DIR}/.git" ]]; then
                    info "KWOK HEAD:      $(git -C "${KWOK_DIR}" log --oneline -1 2>/dev/null)"
                fi
                ;;
            "← back"|"") return ;;
        esac
    done
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------

main() {
    check_gum

    gum style \
        --foreground "$BLUE" --border-foreground "$BLUE" --border double \
        --align center --width 66 --margin "1 2" --padding "1 4" \
        "Karpenter Local" \
        "Kubernetes Node Autoscaler — Local Dev Setup" \
        "(kind + KWOK)"

    check_dependencies

    while true; do
        local action
        action=$(gum choose \
            "install" \
            "status" \
            "uninstall" \
            "sources" \
            "── quit ──" \
            --header "Select action:") || true

        case "$action" in
            "install")   karpenter_install ;;
            "status")    karpenter_status ;;
            "uninstall") karpenter_uninstall ;;
            "sources")   sources_menu ;;
            "── quit ──"|"") break ;;
        esac
    done

    gum style --faint "Bye."
}

main "$@"
