#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# karpenter.sh
# Interactive TUI for installing and managing Karpenter locally (dev/testing).
# Uses KWOK as the simulated cloud provider.
# Works with kind clusters or any existing kubectl-reachable cluster.
# Called by init.sh - expects gum to be available.
# Hard dependencies (abort if missing): docker, go  - install via their
#   dedicated scripts first.
# Soft dependencies (offer to install): ko, make, kubectl.
# kind is only required when choosing to use/create a kind cluster.
# Sources: karpenter (kubernetes-sigs/karpenter) + KWOK (kubernetes-sigs/kwok).
# -----------------------------------------------------------------------------

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

COMMON_DIR="${SCRIPT_DIR}/../_common"
if [[ ! -d "$COMMON_DIR" ]]; then
    printf "\033[0;31m[ERROR] _common directory not found at %s\033[0m\n" "$COMMON_DIR" >&2
    exit 1
fi
# shellcheck source=../_common/ui.sh
source "${COMMON_DIR}/ui.sh"
# shellcheck source=../_common/deps.sh
source "${COMMON_DIR}/deps.sh"

# -----------------------------------------------------------------------------
# Constants
# -----------------------------------------------------------------------------

KARPENTER_REPO="https://github.com/kubernetes-sigs/karpenter"
KWOK_REPO="https://github.com/kubernetes-sigs/kwok"
DEFAULT_WORK_DIR="${HOME}/karpenter-local"
KARPENTER_NAMESPACE="kube-system"
CERT_MANAGER_VERSION="v1.16.1"

# Colours
BLUE=39

# Script-level globals - updated by setup_work_dir()
WORK_DIR="${DEFAULT_WORK_DIR}"
KARPENTER_DIR="${DEFAULT_WORK_DIR}/karpenter"
KWOK_DIR="${DEFAULT_WORK_DIR}/kwok"

# -----------------------------------------------------------------------------
# Dependency checks
# -----------------------------------------------------------------------------

_fatal() { printf "\033[0;31m[ERROR] %s\033[0m\n" "$*" >&2; exit 1; }

check_gum() {
    command -v gum &>/dev/null || _fatal "gum not found. Run setup.sh first."
}

# kind - hard dependency, abort if missing
_check_kind() {
    if ! command -v kind &>/dev/null; then
        gum log --level error "kind is not installed or not in PATH."
        gum log --level error "Run kind.sh first to install kind."
        exit 1
    fi
    info "kind: $(kind version 2>/dev/null)"
}

# go - hard dependency, abort if missing
_check_go() {
    if ! command -v go &>/dev/null; then
        gum log --level error "Go is not installed or not in PATH."
        gum log --level error "Install Go via its dedicated script or: mise use --global go"
        exit 1
    fi
    info "go: $(go version 2>/dev/null)"
}

# ko - soft dependency, offer to install via go install
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

# make - soft dependency, offer to install via system package manager
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

# kubectl - soft dependency, offer to install via mise
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
        info "${label} source found at ${target_dir} - pulling latest..."
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
# Cluster - ensure a kind cluster is active
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
        # kind may not have written the kubeconfig yet - fetch it
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

# Switches to an existing kubectl context chosen from the list.
_select_existing_context() {
    local contexts
    contexts=$(kubectl config get-contexts -o name 2>/dev/null || true)

    if [[ -z "$contexts" ]]; then
        error_exit "No kubectl contexts found. Configure your kubeconfig and retry."
    fi

    local chosen
    chosen=$(echo "$contexts" | gum choose \
        --header "Select a kubectl context:" \
        --height 15) || true

    if [[ -z "$chosen" ]]; then
        error_exit "No context selected. Aborting."
    fi

    kubectl config use-context "$chosen" \
        || error_exit "Could not switch to context '${chosen}'."
    info "Switched to context: ${chosen}"
}

# Selects an existing kind cluster or creates a new one, then switches context.
_select_or_create_kind_cluster() {
    _check_kind

    local clusters
    clusters=$(_list_kind_clusters)

    if [[ -z "$clusters" ]]; then
        gum style \
            --foreground "$YELLOW" --border-foreground "$YELLOW" --border rounded \
            --align center --width 60 --margin "1 2" --padding "1 4" \
            "No kind clusters found." \
            "" \
            "A local kind cluster is required to run Karpenter with kind."

        if ! gum confirm "Create a new kind cluster now?"; then
            error_exit "No kind cluster selected. Aborting."
        fi

        local new_name
        new_name=$(gum input \
            --placeholder "karpenter" \
            --char-limit 40 \
            --header "Cluster name (leave empty for 'karpenter'):") || true
        new_name="${new_name:-karpenter}"

        _create_kind_cluster "${new_name}"
        _use_kind_cluster "${new_name}"
        return
    fi

    local cluster_count
    cluster_count=$(echo "$clusters" | wc -l | tr -d ' ')

    local chosen
    if [[ "$cluster_count" -eq 1 ]]; then
        chosen="${clusters}"
        if ! gum confirm "Use kind cluster '${chosen}'?"; then
            error_exit "No kind cluster selected. Aborting."
        fi
    else
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
                error_exit "No kind cluster selected. Aborting."
            fi
        fi
    fi

    _use_kind_cluster "${chosen}"
}

# Ensures an active cluster context is set.
# Accepts any reachable kubectl context, or offers to use/create a kind cluster.
check_cluster() {
    info "Checking for an active Kubernetes cluster..."

    # If the current context is already reachable, offer to use it as-is.
    local current_ctx
    current_ctx=$(kubectl config current-context 2>/dev/null || true)

    if [[ -n "$current_ctx" ]]; then
        if gum spin --spinner dot --title "Testing current context '${current_ctx}'..." -- \
            kubectl cluster-info &>/dev/null; then
            info "Current context '${current_ctx}' is reachable."
            if gum confirm "Use current context '${current_ctx}'?"; then
                return
            fi
        fi
    fi

    # Let the user decide how to select a cluster.
    local choice
    choice=$(gum choose \
        "use an existing kubectl context" \
        "use / create a kind cluster" \
        --header "How would you like to select a cluster?") || true

    case "$choice" in
        "use an existing kubectl context")
            _select_existing_context
            ;;
        "use / create a kind cluster")
            _select_or_create_kind_cluster
            ;;
        *)
            error_exit "No cluster selected. Aborting."
            ;;
    esac

    if ! gum spin --spinner dot --title "Connecting to cluster..." -- \
        kubectl cluster-info &>/dev/null; then
        gum log --level error "Cannot reach cluster. Check your kubeconfig and retry."
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
        info "cert-manager namespace already exists - skipping install."
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
        2>/dev/null || warn "Could not apply KWOK stage-fast.yaml - nodes may not simulate properly."

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

    local _ctx
    _ctx=$(kubectl config current-context 2>/dev/null || true)

    local make_cmd
    if [[ "$_ctx" == kind-* ]]; then
        # kind clusters: use apply-with-kind which loads the image directly into the cluster
        # via kind.local — no external registry needed. The Makefile's `build` target
        # hardcodes KWOK_REPO internally, so passing KO_DOCKER_REPO via env has no effect.
        local kind_cluster_name="${_ctx#kind-}"

        gum style \
            --foreground "$CYAN" --border-foreground "$CYAN" --border rounded \
            --align left --width 66 --margin "1 2" --padding "1 4" \
            "Build & Deploy Karpenter" \
            "" \
            "kind cluster detected — building and loading image directly into '${kind_cluster_name}'." \
            "No external registry required."

        make_cmd="KWOK_REPO=kind.local KIND_CLUSTER_NAME='${kind_cluster_name}' make apply-with-kind"
    else
        gum style \
            --foreground "$CYAN" --border-foreground "$CYAN" --border rounded \
            --align left --width 66 --margin "1 2" --padding "1 4" \
            "Build & Deploy Karpenter" \
            "" \
            "Provide a registry reachable by your cluster (e.g. ECR, GCR, GHCR, or a local registry)."

        local kwok_repo
        kwok_repo=$(gum input \
            --placeholder "registry.example.com/karpenter" \
            --char-limit 120 \
            --header "KWOK_REPO (container registry):") || true

        if [[ -z "$kwok_repo" ]]; then
            error_exit "KWOK_REPO is required. Provide a container registry address."
        fi

        make_cmd="KWOK_REPO='${kwok_repo}' make apply"
    fi

    # The Makefile hardcodes --set serviceMonitor.enabled=true after $(HELM_OPTS),
    # so it cannot be overridden via env. Patch it temporarily when the CRD is absent.
    local makefile_patched=false
    if ! kubectl get crd servicemonitors.monitoring.coreos.com &>/dev/null 2>&1; then
        warn "ServiceMonitor CRD not found — disabling serviceMonitor for this install."
        sed -i.sm_bak 's/--set serviceMonitor.enabled=true/--set serviceMonitor.enabled=false/' \
            "${KARPENTER_DIR}/Makefile"
        makefile_patched=true
    fi

    info "Building Karpenter... this may take several minutes on first build."

    local build_ok=true
    if ! gum spin --spinner dot \
        --title "Building and deploying Karpenter (this may take a few minutes)..." -- \
        bash -c "cd '${KARPENTER_DIR}' && ${make_cmd}"; then
        build_ok=false
    fi

    if $makefile_patched; then
        mv "${KARPENTER_DIR}/Makefile.sm_bak" "${KARPENTER_DIR}/Makefile"
    fi

    if ! $build_ok; then
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
        || warn "Namespace '${KARPENTER_NAMESPACE}' not found - Karpenter may not be installed."

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
        "Kubernetes Node Autoscaler - Local Dev Setup" \
        "(KWOK - kind or bring your own cluster)"

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
