#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# prometheus.sh
# Interactive TUI for installing and managing Prometheus on Kubernetes.
# Kubernetes only — uses prometheus-community/prometheus Helm chart.
# Called by init.sh — expects gum to be available.
# Hard dependencies: kubectl + helm.
# Sources: scripts/cluster/cluster.sh for deployment target selection.
#
# Optional components (selected at install time):
#   alertmanager, node-exporter, kube-state-metrics, pushgateway
#
# Custom prometheus.yml is uploaded as a ConfigMap and wired via
#   server.configMapOverrideName so Helm honours it on upgrades too.
# -----------------------------------------------------------------------------

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

CLUSTER_SH="${SCRIPT_DIR}/../cluster/cluster.sh"
if [[ ! -f "$CLUSTER_SH" ]]; then
    printf "\033[0;31m[ERROR] cluster.sh not found at %s\033[0m\n" "$CLUSTER_SH" >&2
    exit 1
fi
# shellcheck source=../cluster/cluster.sh
source "$CLUSTER_SH"

# -----------------------------------------------------------------------------
# Constants / defaults
# -----------------------------------------------------------------------------

PROM_NAMESPACE="monitoring"
PROM_HELM_RELEASE="prometheus"
PROM_HELM_REPO_NAME="prometheus-community"
PROM_HELM_REPO_URL="https://prometheus-community.github.io/helm-charts"
PROM_HELM_CHART="prometheus-community/prometheus"
PROM_DEFAULT_PORT=9090
# Service created by the chart: <release>-server, exposed on port 80 → pod :9090
PROM_SVC_PORT=80

# Colours
CYAN=212
RED=196
GREEN=82
YELLOW=220
BLUE=39

# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------

header() {
    gum style \
        --foreground "$CYAN" --border-foreground "$CYAN" --border rounded \
        --align center --width 60 --padding "1 4" --margin "1 0" \
        "$1"
}

info()       { gum log --level info "$1"; }
success()    { gum style --foreground "$GREEN" "[ok] $1"; }
warn()       { gum style --foreground "$YELLOW" "[warn] $1"; }
error_exit() { gum style --foreground "$RED" "[error] $1"; exit 1; }

# -----------------------------------------------------------------------------
# Dependency checks
# -----------------------------------------------------------------------------

_check_kubectl() {
    if ! command -v kubectl &>/dev/null; then
        gum log --level error "kubectl is not installed or not in PATH."
        gum log --level error "Install kubectl: https://kubernetes.io/docs/tasks/tools/"
        exit 1
    fi
    info "kubectl: $(kubectl version --client 2>/dev/null | head -1)"
}

_ensure_helm() {
    if command -v helm &>/dev/null; then
        info "helm: $(helm version --short 2>/dev/null)"
        return
    fi

    gum style \
        --foreground "$YELLOW" --border-foreground "$YELLOW" --border rounded \
        --align center --width 60 --margin "1 2" --padding "1 4" \
        "helm not found" \
        "helm is required to install Prometheus on Kubernetes."

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

_ensure_helm_repo() {
    info "Adding/updating '${PROM_HELM_REPO_NAME}' helm repo..."
    helm repo add "$PROM_HELM_REPO_NAME" "$PROM_HELM_REPO_URL" 2>/dev/null || true
    gum spin --spinner dot --title "Updating helm repo..." -- \
        helm repo update "$PROM_HELM_REPO_NAME"
}

check_dependencies() {
    info "Checking dependencies..."
    _check_kubectl
    _ensure_helm
}

# -----------------------------------------------------------------------------
# K8s helpers
# -----------------------------------------------------------------------------

_k8s_check_cluster() {
    if [[ "$TARGET_TYPE" == "kind" ]]; then
        kubectl config use-context "kind-${TARGET_CONTEXT}" &>/dev/null \
            || error_exit "Could not switch to kind context 'kind-${TARGET_CONTEXT}'."
    else
        kubectl config use-context "${TARGET_CONTEXT}" &>/dev/null \
            || error_exit "Could not switch to context '${TARGET_CONTEXT}'."
    fi

    if ! gum spin --spinner dot --title "Verifying cluster connectivity..." -- \
        kubectl cluster-info &>/dev/null; then
        gum log --level error "Cannot reach cluster '${TARGET_CONTEXT}'."
        gum log --level error "Verify the cluster is running and your kubeconfig is up to date."
        return 1
    fi
    info "Cluster reachable."
}

_k8s_ensure_namespace() {
    if kubectl get namespace "$PROM_NAMESPACE" &>/dev/null; then
        info "Namespace '${PROM_NAMESPACE}' already exists."
    else
        info "Creating namespace '${PROM_NAMESPACE}'..."
        kubectl create namespace "$PROM_NAMESPACE"
    fi
}

_k8s_detect_installed() {
    helm status "$PROM_HELM_RELEASE" -n "$PROM_NAMESPACE" &>/dev/null 2>&1
}

# -----------------------------------------------------------------------------
# Component selection
# -----------------------------------------------------------------------------

_select_components() {
    gum style \
        --foreground "$CYAN" --margin "0 2" \
        "Select optional components to enable (space to toggle, enter to confirm):"

    gum choose --no-limit \
        "alertmanager" \
        "node-exporter" \
        "kube-state-metrics" \
        "pushgateway" || true
}

# Appends --set flags to the given array name based on selected components.
# Usage: _apply_component_flags selected_str helm_args_array
_apply_component_flags() {
    local selected="$1"
    shift
    local -n _arr="$1"

    if echo "$selected" | grep -q "alertmanager"; then
        _arr+=(--set alertmanager.enabled=true)
    else
        _arr+=(--set alertmanager.enabled=false)
    fi

    if echo "$selected" | grep -q "node-exporter"; then
        _arr+=(--set prometheus-node-exporter.enabled=true)
    else
        _arr+=(--set prometheus-node-exporter.enabled=false)
    fi

    if echo "$selected" | grep -q "kube-state-metrics"; then
        _arr+=(--set kube-state-metrics.enabled=true)
    else
        _arr+=(--set kube-state-metrics.enabled=false)
    fi

    if echo "$selected" | grep -q "pushgateway"; then
        _arr+=(--set prometheus-pushgateway.enabled=true)
    else
        _arr+=(--set prometheus-pushgateway.enabled=false)
    fi
}

# -----------------------------------------------------------------------------
# Custom prometheus.yml handling
# -----------------------------------------------------------------------------

_apply_custom_config() {
    local -n _arr="$1"

    if ! gum confirm "Use a custom prometheus.yml config file?"; then
        return 0
    fi

    local config_path
    config_path=$(gum input \
        --placeholder "/path/to/prometheus.yml" \
        --header "Path to your prometheus.yml:") || true

    if [[ -z "$config_path" ]]; then
        warn "No path provided — using chart defaults."
        return 0
    fi

    if [[ ! -f "$config_path" ]]; then
        warn "File not found: ${config_path} — using chart defaults."
        return 0
    fi

    local cm_name="${PROM_HELM_RELEASE}-custom-config"
    info "Uploading '${config_path}' as ConfigMap '${cm_name}'..."

    kubectl create configmap "$cm_name" \
        --from-file=prometheus.yml="$config_path" \
        -n "$PROM_NAMESPACE" \
        --dry-run=client -o yaml | kubectl apply -f - &>/dev/null

    success "ConfigMap '${cm_name}' applied."
    _arr+=(--set "server.configMapOverrideName=${cm_name}")
}

# -----------------------------------------------------------------------------
# Actions
# -----------------------------------------------------------------------------

prometheus_install_k8s() {
    header "Install Prometheus — Kubernetes"
    _k8s_check_cluster || return 0

    _ensure_helm_repo

    local storage_size
    storage_size=$(gum input \
        --placeholder "8Gi" \
        --header "Persistent volume size for Prometheus server (leave empty for '8Gi'):") || true
    storage_size="${storage_size:-8Gi}"

    local selected_components
    selected_components=$(_select_components)

    _k8s_ensure_namespace

    local helm_args=(
        "$PROM_HELM_RELEASE" "$PROM_HELM_CHART"
        --namespace "$PROM_NAMESPACE"
        --set server.persistentVolume.size="$storage_size"
        --wait --timeout 5m
    )

    _apply_component_flags "$selected_components" helm_args
    _apply_custom_config helm_args

    if _k8s_detect_installed; then
        gum style \
            --foreground "$YELLOW" --border-foreground "$YELLOW" --border rounded \
            --align center --width 60 --margin "1 2" --padding "1 4" \
            "Release '${PROM_HELM_RELEASE}' already exists in '${PROM_NAMESPACE}'."

        local action
        action=$(gum choose \
            "Upgrade (apply new values)" \
            "Cancel" \
            --header "What would you like to do?") || true

        case "$action" in
            "Upgrade"*) ;;
            *) warn "Cancelled."; return ;;
        esac

        if ! gum spin --spinner dot --title "Upgrading Prometheus (this may take a few minutes)..." -- \
            helm upgrade "${helm_args[@]}"; then
            warn "Upgrade failed. Check 'helm status ${PROM_HELM_RELEASE} -n ${PROM_NAMESPACE}' for details."
            return
        fi
        success "Prometheus upgraded."
    else
        if ! gum spin --spinner dot --title "Installing Prometheus (this may take a few minutes)..." -- \
            helm install "${helm_args[@]}"; then
            warn "Install failed. Check 'helm status ${PROM_HELM_RELEASE} -n ${PROM_NAMESPACE}' for details."
            return
        fi
        success "Prometheus installed."
    fi

    echo ""
    gum style --foreground "$CYAN" \
        "Use 'connect' to open the web UI via port-forward."
}

prometheus_status_k8s() {
    header "Status — Prometheus Kubernetes"
    _k8s_check_cluster || return 0

    if ! _k8s_detect_installed; then
        warn "Release '${PROM_HELM_RELEASE}' not found in namespace '${PROM_NAMESPACE}'."
        return
    fi

    info "Helm release:"
    helm status "$PROM_HELM_RELEASE" -n "$PROM_NAMESPACE" 2>/dev/null | head -10
    echo ""

    info "Pods:"
    kubectl get pods -n "$PROM_NAMESPACE" \
        -l "app.kubernetes.io/instance=${PROM_HELM_RELEASE}" \
        --no-headers 2>/dev/null \
        || kubectl get pods -n "$PROM_NAMESPACE" --no-headers 2>/dev/null
    echo ""

    info "Services:"
    kubectl get svc -n "$PROM_NAMESPACE" --no-headers 2>/dev/null
    echo ""

    info "PersistentVolumeClaims:"
    kubectl get pvc -n "$PROM_NAMESPACE" --no-headers 2>/dev/null || true
}

prometheus_connect_k8s() {
    header "Connect — Prometheus Web UI"
    _k8s_check_cluster || return 0

    if ! _k8s_detect_installed; then
        warn "Release '${PROM_HELM_RELEASE}' not found in namespace '${PROM_NAMESPACE}'."
        return
    fi

    local port_input
    port_input=$(gum input \
        --placeholder "$PROM_DEFAULT_PORT" \
        --header "Local port for port-forward (leave empty for ${PROM_DEFAULT_PORT}):") || true
    local port="${port_input:-$PROM_DEFAULT_PORT}"

    local svc="${PROM_HELM_RELEASE}-server"

    gum style \
        --foreground "$CYAN" --border-foreground "$CYAN" --border rounded \
        --width 60 --margin "0 2" --padding "1 2" \
        "Prometheus UI → http://localhost:${port}" \
        "" \
        "Press Ctrl+C to stop the port-forward."

    kubectl -n "$PROM_NAMESPACE" port-forward "svc/${svc}" "${port}:${PROM_SVC_PORT}"
}

prometheus_uninstall_k8s() {
    header "Uninstall Prometheus — Kubernetes"
    _k8s_check_cluster || return 0

    if ! _k8s_detect_installed; then
        warn "Release '${PROM_HELM_RELEASE}' not found in namespace '${PROM_NAMESPACE}'."
        return
    fi

    gum style \
        --foreground "$RED" --border-foreground "$RED" --border rounded \
        --width 60 --margin "0 2" --padding "1 2" \
        "This will remove Helm release '${PROM_HELM_RELEASE}'" \
        "from namespace '${PROM_NAMESPACE}'." \
        "" \
        "PersistentVolumeClaims are NOT removed automatically by Helm." \
        "Delete them manually to fully purge data:" \
        "  kubectl delete pvc --all -n ${PROM_NAMESPACE}"

    if ! gum confirm "Uninstall Prometheus?"; then
        warn "Cancelled."
        return
    fi

    gum spin --spinner dot --title "Running helm uninstall..." -- \
        helm uninstall "$PROM_HELM_RELEASE" -n "$PROM_NAMESPACE" || true

    if gum confirm "Also delete namespace '${PROM_NAMESPACE}' (removes remaining PVCs too)?"; then
        gum spin --spinner dot --title "Deleting namespace '${PROM_NAMESPACE}'..." -- \
            kubectl delete namespace "$PROM_NAMESPACE" --ignore-not-found || true
        success "Namespace deleted."
    fi

    success "Prometheus uninstalled."
}

# -----------------------------------------------------------------------------
# Menu
# -----------------------------------------------------------------------------

_k8s_menu() {
    local ns_input
    ns_input=$(gum input \
        --placeholder "$PROM_NAMESPACE" \
        --header "Kubernetes namespace (leave empty for '${PROM_NAMESPACE}'):") || true
    PROM_NAMESPACE="${ns_input:-$PROM_NAMESPACE}"

    local release_input
    release_input=$(gum input \
        --placeholder "$PROM_HELM_RELEASE" \
        --header "Helm release name (leave empty for '${PROM_HELM_RELEASE}'):") || true
    PROM_HELM_RELEASE="${release_input:-$PROM_HELM_RELEASE}"

    while true; do
        header "Prometheus — ${TARGET_TYPE}: ${TARGET_CONTEXT} / ns: ${PROM_NAMESPACE} / release: ${PROM_HELM_RELEASE}"

        local action
        action=$(gum choose \
            "install" \
            "status" \
            "connect" \
            "uninstall" \
            "← back" \
            --header "Select action:") || true

        case "$action" in
            "install")   prometheus_install_k8s ;;
            "status")    prometheus_status_k8s ;;
            "connect")   prometheus_connect_k8s ;;
            "uninstall") prometheus_uninstall_k8s ;;
            "← back"|"") return ;;
        esac
    done
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------

main() {
    gum style \
        --foreground "$BLUE" --border-foreground "$BLUE" --border double \
        --align center --width 60 --margin "1 2" --padding "1 4" \
        "Prometheus" \
        "Kubernetes Monitoring"

    info "Select a deployment target..."
    select_target || exit 1

    if [[ "$TARGET_TYPE" == "docker" ]]; then
        gum style \
            --foreground "$RED" --border-foreground "$RED" --border rounded \
            --align center --width 60 --margin "1 2" --padding "1 2" \
            "Docker target not supported." \
            "This script manages Prometheus on Kubernetes only." \
            "Please re-run and select a kind or k8s target."
        exit 1
    fi

    check_dependencies
    _k8s_menu

    gum style --faint "Bye."
}

main "$@"
