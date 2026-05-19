#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# harbor.sh
# Interactive TUI for installing and managing Harbor container registry.
# Kubernetes only — uses the official Harbor Helm chart.
# Called by init.sh — expects gum to be available.
# Hard dependencies: kubectl + helm.
# Sources: scripts/cluster/cluster.sh for deployment target selection.
#
# Storage options (selected at install time):
#   StorageClass — dynamic provisioning (covers NFS-backed classes too)
#   Local path   — hostPath PVs pinned to a node; good for kind / bare-metal
#
# Expose: clusterIP + port-forward (no ingress required).
# For docker push/pull to work the local port must match externalURL,
# and the daemon must trust localhost:<port> as an insecure registry.
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

HARBOR_NAMESPACE="harbor"
HARBOR_HELM_RELEASE="harbor"
HARBOR_HELM_REPO_NAME="harbor"
HARBOR_HELM_REPO_URL="https://helm.goharbor.io"
HARBOR_HELM_CHART="harbor/harbor"
HARBOR_DEFAULT_PORT=8080
_HARBOR_PF_PID="/tmp/scomp-pf-harbor.pid"
HARBOR_ADMIN_PASSWORD=""

# Component PVC sizes — registry is the only user-configurable one.
HARBOR_REGISTRY_SIZE="10Gi"
HARBOR_JOBSERVICE_SIZE="1Gi"
HARBOR_DATABASE_SIZE="1Gi"
HARBOR_REDIS_SIZE="512Mi"
HARBOR_TRIVY_SIZE="5Gi"

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
        "helm is required to install Harbor on Kubernetes."

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
    info "Adding/updating '${HARBOR_HELM_REPO_NAME}' helm repo..."
    helm repo add "$HARBOR_HELM_REPO_NAME" "$HARBOR_HELM_REPO_URL" 2>/dev/null || true
    gum spin --spinner dot --title "Updating helm repo..." -- \
        helm repo update "$HARBOR_HELM_REPO_NAME"
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
    if kubectl get namespace "$HARBOR_NAMESPACE" &>/dev/null; then
        info "Namespace '${HARBOR_NAMESPACE}' already exists."
    else
        info "Creating namespace '${HARBOR_NAMESPACE}'..."
        kubectl create namespace "$HARBOR_NAMESPACE"
    fi
}

_k8s_detect_installed() {
    helm status "$HARBOR_HELM_RELEASE" -n "$HARBOR_NAMESPACE" &>/dev/null 2>&1
}

# -----------------------------------------------------------------------------
# Storage
# -----------------------------------------------------------------------------

_storage_select_node() {
    local nodes
    nodes=$(kubectl get nodes -o jsonpath='{.items[*].metadata.name}' 2>/dev/null \
        | tr ' ' '\n')

    local node_count
    node_count=$(echo "$nodes" | wc -l | tr -d ' ')

    if [[ "$node_count" -eq 1 ]]; then
        echo "$nodes"
        return
    fi

    echo "$nodes" | gum choose \
        --header "Select the node where local storage will be created:"
}

# Creates hostPath PVs + PVCs for each Harbor component under base_path/component.
# Appends existingClaim helm args to the named array.
_storage_apply_local_path() {
    local base_path="$1"
    local node="$2"
    local -n _arr="$3"

    declare -A components=(
        [registry]="$HARBOR_REGISTRY_SIZE"
        [jobservice]="$HARBOR_JOBSERVICE_SIZE"
        [database]="$HARBOR_DATABASE_SIZE"
        [redis]="$HARBOR_REDIS_SIZE"
        [trivy]="$HARBOR_TRIVY_SIZE"
    )

    for component in registry jobservice database redis trivy; do
        local size="${components[$component]}"
        local pv_name="${HARBOR_HELM_RELEASE}-${component}"
        local pvc_name="${HARBOR_HELM_RELEASE}-${component}"
        local path="${base_path}/${component}"

        kubectl apply -f - &>/dev/null <<EOF
apiVersion: v1
kind: PersistentVolume
metadata:
  name: ${pv_name}
  labels:
    harbor-release: ${HARBOR_HELM_RELEASE}
    harbor-component: ${component}
spec:
  capacity:
    storage: ${size}
  accessModes:
    - ReadWriteOnce
  persistentVolumeReclaimPolicy: Retain
  storageClassName: ""
  hostPath:
    path: ${path}
    type: DirectoryOrCreate
  nodeAffinity:
    required:
      nodeSelectorTerms:
        - matchExpressions:
            - key: kubernetes.io/hostname
              operator: In
              values:
                - ${node}
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${pvc_name}
  namespace: ${HARBOR_NAMESPACE}
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: ""
  volumeName: ${pv_name}
  resources:
    requests:
      storage: ${size}
EOF
        info "PV/PVC '${pv_name}' created (${size} → ${path})."
    done

    # Wire existing PVCs into Helm
    _arr+=(
        --set "persistence.persistentVolumeClaim.registry.existingClaim=${HARBOR_HELM_RELEASE}-registry"
        --set "persistence.persistentVolumeClaim.jobservice.jobLog.existingClaim=${HARBOR_HELM_RELEASE}-jobservice"
        --set "persistence.persistentVolumeClaim.database.existingClaim=${HARBOR_HELM_RELEASE}-database"
        --set "persistence.persistentVolumeClaim.redis.existingClaim=${HARBOR_HELM_RELEASE}-redis"
        --set "persistence.persistentVolumeClaim.trivy.existingClaim=${HARBOR_HELM_RELEASE}-trivy"
    )
}

# Appends StorageClass helm args to the named array.
_storage_apply_storageclass() {
    local class="$1"
    local -n _arr="$2"

    if [[ -n "$class" ]]; then
        _arr+=(
            --set "persistence.persistentVolumeClaim.registry.storageClass=${class}"
            --set "persistence.persistentVolumeClaim.jobservice.jobLog.storageClass=${class}"
            --set "persistence.persistentVolumeClaim.database.storageClass=${class}"
            --set "persistence.persistentVolumeClaim.redis.storageClass=${class}"
            --set "persistence.persistentVolumeClaim.trivy.storageClass=${class}"
        )
        info "Using StorageClass '${class}' for all Harbor PVCs."
    else
        info "Using cluster default StorageClass for all Harbor PVCs."
    fi

    _arr+=(--set "persistence.persistentVolumeClaim.registry.size=${HARBOR_REGISTRY_SIZE}")
}

_prompt_storage() {
    local -n _arr="$1"

    local storage_type
    storage_type=$(gum choose \
        "StorageClass (dynamic provisioning — covers NFS-backed classes)" \
        "Local path (hostPath PVs — good for kind / bare-metal)" \
        --header "Storage backend for Harbor:") || true

    case "$storage_type" in
        "StorageClass"*)
            local class_input
            class_input=$(gum input \
                --placeholder "leave empty for cluster default" \
                --header "StorageClass name:") || true

            local size_input
            size_input=$(gum input \
                --placeholder "$HARBOR_REGISTRY_SIZE" \
                --header "Registry storage size (leave empty for '${HARBOR_REGISTRY_SIZE}'):") || true
            HARBOR_REGISTRY_SIZE="${size_input:-$HARBOR_REGISTRY_SIZE}"

            _storage_apply_storageclass "$class_input" _arr
            ;;

        "Local path"*)
            local path_input
            path_input=$(gum input \
                --placeholder "/data/harbor" \
                --header "Base path on the host node (e.g. /data/harbor or /mnt/nas/harbor):") || true

            if [[ -z "$path_input" ]]; then
                warn "No path provided. Falling back to cluster default StorageClass."
                _storage_apply_storageclass "" _arr
                return
            fi

            local size_input
            size_input=$(gum input \
                --placeholder "$HARBOR_REGISTRY_SIZE" \
                --header "Registry storage size (leave empty for '${HARBOR_REGISTRY_SIZE}'):") || true
            HARBOR_REGISTRY_SIZE="${size_input:-$HARBOR_REGISTRY_SIZE}"

            info "Selecting target node for hostPath PVs..."
            local node
            node=$(_storage_select_node) || true

            if [[ -z "$node" ]]; then
                warn "No node selected. Falling back to cluster default StorageClass."
                _storage_apply_storageclass "" _arr
                return
            fi

            _k8s_ensure_namespace
            _storage_apply_local_path "$path_input" "$node" _arr
            ;;
    esac
}

# -----------------------------------------------------------------------------
# Actions
# -----------------------------------------------------------------------------

harbor_install_k8s() {
    header "Install Harbor — Kubernetes"
    _k8s_check_cluster || return 0

    _ensure_helm_repo

    HARBOR_ADMIN_PASSWORD=$(gum input \
        --placeholder "leave empty to auto-generate" \
        --password \
        --header "Harbor admin password (leave empty to auto-generate):") || true

    if [[ -z "$HARBOR_ADMIN_PASSWORD" ]]; then
        HARBOR_ADMIN_PASSWORD=$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24)
        gum style \
            --foreground "$YELLOW" --border-foreground "$YELLOW" --border rounded \
            --align center --width 60 --margin "1 0" --padding "0 4" \
            "Generated admin password: ${HARBOR_ADMIN_PASSWORD}" \
            "Save this — it will not be shown again."
    fi

    local port_input
    port_input=$(gum input \
        --placeholder "$HARBOR_DEFAULT_PORT" \
        --header "Local port for port-forward / externalURL (leave empty for ${HARBOR_DEFAULT_PORT}):") || true
    local port="${port_input:-$HARBOR_DEFAULT_PORT}"

    local helm_args=(
        "$HARBOR_HELM_RELEASE" "$HARBOR_HELM_CHART"
        --namespace "$HARBOR_NAMESPACE"
        --set expose.type=clusterIP
        --set "expose.clusterIP.name=${HARBOR_HELM_RELEASE}"
        --set expose.tls.enabled=false
        --set "externalURL=http://localhost:${port}"
        --set "harborAdminPassword=${HARBOR_ADMIN_PASSWORD}"
        --set persistence.enabled=true
        --wait --timeout 10m
    )

    _prompt_storage helm_args

    _k8s_ensure_namespace

    if _k8s_detect_installed; then
        gum style \
            --foreground "$YELLOW" --border-foreground "$YELLOW" --border rounded \
            --align center --width 60 --margin "1 2" --padding "1 4" \
            "Release '${HARBOR_HELM_RELEASE}' already exists in '${HARBOR_NAMESPACE}'."

        local action
        action=$(gum choose \
            "Upgrade (apply new values)" \
            "Cancel" \
            --header "What would you like to do?") || true

        case "$action" in
            "Upgrade"*) ;;
            *) warn "Cancelled."; return ;;
        esac

        if ! gum spin --spinner dot --title "Upgrading Harbor (this may take several minutes)..." -- \
            helm upgrade "${helm_args[@]}"; then
            warn "Upgrade failed. Check 'helm status ${HARBOR_HELM_RELEASE} -n ${HARBOR_NAMESPACE}'."
            return
        fi
        success "Harbor upgraded."
    else
        if ! gum spin --spinner dot --title "Installing Harbor (this may take several minutes)..." -- \
            helm install "${helm_args[@]}"; then
            warn "Install failed. Check 'helm status ${HARBOR_HELM_RELEASE} -n ${HARBOR_NAMESPACE}'."
            return
        fi
        success "Harbor installed."
    fi

    echo ""
    gum style \
        --foreground "$CYAN" --border-foreground "$CYAN" --border rounded \
        --align left --width 60 --margin "1 2" --padding "1 4" \
        "Harbor installed." \
        "" \
        "Use 'connect' to start port-forward → http://localhost:${port}" \
        "Login: admin / ${HARBOR_ADMIN_PASSWORD}" \
        "" \
        "To push images, add localhost:${port} as an insecure registry" \
        "in your Docker daemon (or use HTTP in your registry config)."
}

harbor_status_k8s() {
    header "Status — Harbor Kubernetes"
    _k8s_check_cluster || return 0

    if ! _k8s_detect_installed; then
        warn "Release '${HARBOR_HELM_RELEASE}' not found in namespace '${HARBOR_NAMESPACE}'."
        return
    fi

    info "Helm release:"
    helm status "$HARBOR_HELM_RELEASE" -n "$HARBOR_NAMESPACE" 2>/dev/null | head -10
    echo ""

    info "Pods:"
    kubectl get pods -n "$HARBOR_NAMESPACE" --no-headers 2>/dev/null
    echo ""

    info "Services:"
    kubectl get svc -n "$HARBOR_NAMESPACE" --no-headers 2>/dev/null
    echo ""

    info "PersistentVolumeClaims:"
    kubectl get pvc -n "$HARBOR_NAMESPACE" --no-headers 2>/dev/null || true
}

_harbor_pf_is_running() { [[ -f "$_HARBOR_PF_PID" ]] && kill -0 "$(cut -d: -f1 < "$_HARBOR_PF_PID")" 2>/dev/null; }
_harbor_pf_port()       { cut -d: -f2 < "$_HARBOR_PF_PID" 2>/dev/null; }
_harbor_pf_stop()       { kill "$(cut -d: -f1 < "$_HARBOR_PF_PID")" 2>/dev/null || true; rm -f "$_HARBOR_PF_PID"; success "Port-forward stopped."; }

harbor_connect_k8s() {
    header "Connect — Harbor Web UI"
    _k8s_check_cluster || return 0

    if ! _k8s_detect_installed; then
        warn "Release '${HARBOR_HELM_RELEASE}' not found in namespace '${HARBOR_NAMESPACE}'."
        return
    fi

    if _harbor_pf_is_running; then
        gum style --foreground "$GREEN" --border-foreground "$GREEN" --border rounded \
            --width 60 --margin "0 2" --padding "1 2" \
            "Port-forward is running" \
            "http://localhost:$(_harbor_pf_port)" \
            "" \
            "Username: admin"
        gum confirm "Stop port-forward?" && _harbor_pf_stop || true
        return
    fi

    local port_input
    port_input=$(gum input \
        --placeholder "$HARBOR_DEFAULT_PORT" \
        --header "Local port (must match externalURL set at install — leave empty for ${HARBOR_DEFAULT_PORT}):") || true
    local port="${port_input:-$HARBOR_DEFAULT_PORT}"

    local svc="$HARBOR_HELM_RELEASE"
    if ! kubectl get svc "$svc" -n "$HARBOR_NAMESPACE" &>/dev/null 2>&1; then
        svc=$(kubectl get svc -n "$HARBOR_NAMESPACE" \
            --field-selector spec.type=ClusterIP \
            -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "$HARBOR_HELM_RELEASE")
    fi

    kubectl -n "$HARBOR_NAMESPACE" port-forward "svc/${svc}" "${port}:80" >/dev/null 2>&1 &
    echo "${!}:${port}" > "$_HARBOR_PF_PID"

    local attempts=0
    until nc -z 127.0.0.1 "$port" 2>/dev/null || [[ $attempts -ge 20 ]]; do
        sleep 0.25; attempts=$((attempts + 1))
    done

    if ! _harbor_pf_is_running; then
        warn "Port-forward failed to start. Check kubectl connectivity."
        rm -f "$_HARBOR_PF_PID"; return
    fi

    success "Port-forward started: http://localhost:${port}"
    info "Username: admin"
}

harbor_uninstall_k8s() {
    header "Uninstall Harbor — Kubernetes"
    _k8s_check_cluster || return 0

    if ! _k8s_detect_installed; then
        warn "Release '${HARBOR_HELM_RELEASE}' not found in namespace '${HARBOR_NAMESPACE}'."
        return
    fi

    gum style \
        --foreground "$RED" --border-foreground "$RED" --border rounded \
        --width 60 --margin "0 2" --padding "1 2" \
        "This will remove Helm release '${HARBOR_HELM_RELEASE}'" \
        "from namespace '${HARBOR_NAMESPACE}'." \
        "" \
        "PersistentVolumeClaims and PersistentVolumes are NOT removed" \
        "automatically. Delete them manually to fully purge data:" \
        "  kubectl delete pvc --all -n ${HARBOR_NAMESPACE}" \
        "  kubectl delete pv -l harbor-release=${HARBOR_HELM_RELEASE}"

    if ! gum confirm "Uninstall Harbor?"; then
        warn "Cancelled."
        return
    fi

    gum spin --spinner dot --title "Running helm uninstall..." -- \
        helm uninstall "$HARBOR_HELM_RELEASE" -n "$HARBOR_NAMESPACE" || true

    if gum confirm "Also delete PersistentVolumes created for this release?"; then
        gum spin --spinner dot --title "Deleting PersistentVolumes..." -- \
            kubectl delete pv -l "harbor-release=${HARBOR_HELM_RELEASE}" \
            --ignore-not-found 2>/dev/null || true
        success "PersistentVolumes removed."
    fi

    if gum confirm "Also delete namespace '${HARBOR_NAMESPACE}' (removes remaining PVCs too)?"; then
        gum spin --spinner dot --title "Deleting namespace '${HARBOR_NAMESPACE}'..." -- \
            kubectl delete namespace "$HARBOR_NAMESPACE" --ignore-not-found || true
        success "Namespace deleted."
    fi

    success "Harbor uninstalled."
}

# -----------------------------------------------------------------------------
# Menu
# -----------------------------------------------------------------------------

_k8s_menu() {
    local ns_input
    ns_input=$(gum input \
        --placeholder "$HARBOR_NAMESPACE" \
        --header "Kubernetes namespace (leave empty for '${HARBOR_NAMESPACE}'):") || true
    HARBOR_NAMESPACE="${ns_input:-$HARBOR_NAMESPACE}"

    local release_input
    release_input=$(gum input \
        --placeholder "$HARBOR_HELM_RELEASE" \
        --header "Helm release name (leave empty for '${HARBOR_HELM_RELEASE}'):") || true
    HARBOR_HELM_RELEASE="${release_input:-$HARBOR_HELM_RELEASE}"

    while true; do
        header "Harbor — ${TARGET_TYPE}: ${TARGET_CONTEXT} / ns: ${HARBOR_NAMESPACE} / release: ${HARBOR_HELM_RELEASE}"

        local pf_label
        _harbor_pf_is_running \
            && pf_label="connect  [● localhost:$(_harbor_pf_port)]" \
            || pf_label="connect  [○ stopped]"

        local action
        action=$(gum choose \
            "install" \
            "status" \
            "$pf_label" \
            "uninstall" \
            "← back" \
            --header "Select action:") || true

        case "$action" in
            "install")   harbor_install_k8s ;;
            "status")    harbor_status_k8s ;;
            "connect"*)  harbor_connect_k8s ;;
            "uninstall") harbor_uninstall_k8s ;;
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
        "Harbor" \
        "Container Registry  ·  Kubernetes"

    info "Select a deployment target..."
    select_target || exit 1

    if [[ "$TARGET_TYPE" == "docker" ]]; then
        gum style \
            --foreground "$RED" --border-foreground "$RED" --border rounded \
            --align center --width 60 --margin "1 2" --padding "1 2" \
            "Docker target not supported." \
            "Harbor is a multi-service application — Kubernetes only." \
            "Please re-run and select a kind or k8s target."
        exit 1
    fi

    check_dependencies
    _k8s_menu

    gum style --faint "Bye."
}

main "$@"
