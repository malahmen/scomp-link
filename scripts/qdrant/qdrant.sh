#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# qdrant.sh
# Interactive TUI for installing and managing Qdrant vector database.
# Supports Docker (local container) and Kubernetes (official Qdrant Helm chart).
# Called by init.sh — expects gum to be available.
# Hard dependencies: docker (Docker target) | kubectl + helm (K8s target).
# Soft dependency:   curl (health-check feature).
# Sources: scripts/cluster/cluster.sh for deployment target selection.
#
# Ports:  6333 — REST / HTTP API
#         6334 — gRPC
# Auth:   optional API key (no auth by default).
# Helm:   https://qdrant.github.io/qdrant-helm  (not Bitnami)
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

QD_NAMESPACE="qdrant"
QD_HELM_RELEASE="qdrant"
QD_HELM_REPO_NAME="qdrant"
QD_HELM_REPO_URL="https://qdrant.github.io/qdrant-helm"
QD_HELM_CHART="qdrant/qdrant"
QD_DEFAULT_REST_PORT=6333
QD_DEFAULT_GRPC_PORT=6334
QD_DEFAULT_IMAGE_TAG="latest"
_QD_REST_PF_PID="/tmp/scomp-pf-qdrant-rest.pid"
_QD_GRPC_PF_PID="/tmp/scomp-pf-qdrant-grpc.pid"

# Colours
CYAN=212
RED=196
GREEN=82
YELLOW=220
BLUE=39

# Session state — populated by _docker_menu / _k8s_menu
QD_CONTAINER_NAME="qdrant"
QD_IMAGE_TAG="$QD_DEFAULT_IMAGE_TAG"
QD_API_KEY=""
QD_REST_PORT=$QD_DEFAULT_REST_PORT
QD_GRPC_PORT=$QD_DEFAULT_GRPC_PORT

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

# Builds the curl auth header arg if an API key is set.
_curl_auth() { [[ -n "$QD_API_KEY" ]] && echo "-H api-key:${QD_API_KEY}" || echo ""; }

# -----------------------------------------------------------------------------
# Dependency checks
# -----------------------------------------------------------------------------

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

_ensure_helm() {
    if command -v helm &>/dev/null; then
        info "helm: $(helm version --short 2>/dev/null)"
        return
    fi

    gum style \
        --foreground "$YELLOW" --border-foreground "$YELLOW" --border rounded \
        --align center --width 60 --margin "1 2" --padding "1 4" \
        "helm not found" \
        "helm is required to install Qdrant on Kubernetes."

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
    if helm repo list 2>/dev/null | grep -q "^${QD_HELM_REPO_NAME}[[:space:]]"; then
        info "Helm repo '${QD_HELM_REPO_NAME}' already present."
    else
        info "Adding Qdrant Helm repo..."
        gum spin --spinner dot --title "Adding Qdrant Helm repo..." -- \
            helm repo add "$QD_HELM_REPO_NAME" "$QD_HELM_REPO_URL" \
            || error_exit "Failed to add Qdrant Helm repo."
    fi
    gum spin --spinner dot --title "Updating Helm repo..." -- \
        helm repo update "$QD_HELM_REPO_NAME" 2>/dev/null || true
}

_ensure_curl() {
    if command -v curl &>/dev/null; then
        return 0
    fi
    warn "curl not found — health-check feature unavailable."
    warn "macOS: brew install curl   Linux: apt install curl / dnf install curl"
    return 1
}

check_dependencies() {
    info "Checking dependencies..."
    case "$TARGET_TYPE" in
        docker)   _check_docker ;;
        kind|k8s) _check_kubectl; _ensure_helm ;;
    esac
}

# -----------------------------------------------------------------------------
# Shared config prompts
# -----------------------------------------------------------------------------

_prompt_api_key() {
    QD_API_KEY=$(gum input \
        --placeholder "leave empty to disable authentication" \
        --password \
        --header "API key (optional — leave empty for no auth):") || true

    if [[ -n "$QD_API_KEY" ]]; then
        info "API key configured. All requests must include 'api-key: <key>' header."
    else
        warn "No API key set — Qdrant will be accessible without authentication."
    fi
}

# -----------------------------------------------------------------------------
# Health check (shared — hits the REST API on localhost:port)
# -----------------------------------------------------------------------------

_rest_health_check() {
    local port="$1"
    local auth_header
    auth_header=$(_curl_auth)

    if ! _ensure_curl; then
        return
    fi

    info "Querying Qdrant REST API at http://127.0.0.1:${port} ..."
    echo ""

    # Cluster info
    gum style --foreground "$CYAN" --bold "── Cluster info ──"
    # shellcheck disable=SC2086
    curl -sf $auth_header "http://127.0.0.1:${port}/" 2>/dev/null \
        | (command -v python3 &>/dev/null && python3 -m json.tool || cat) \
        || warn "Could not reach http://127.0.0.1:${port}/ — is Qdrant running?"

    echo ""
    gum style --foreground "$CYAN" --bold "── Collections ──"
    # shellcheck disable=SC2086
    curl -sf $auth_header "http://127.0.0.1:${port}/collections" 2>/dev/null \
        | (command -v python3 &>/dev/null && python3 -m json.tool || cat) \
        || warn "Could not list collections."

    echo ""
    gum confirm "Press Enter to continue" --affirmative "OK" --negative "" || true
}

# -----------------------------------------------------------------------------
# Docker — install / status / health-check / uninstall
# -----------------------------------------------------------------------------

_docker_container_exists()  { docker inspect "$1" &>/dev/null 2>&1; }
_docker_container_running() { [[ "$(docker inspect --format='{{.State.Running}}' "$1" 2>/dev/null)" == "true" ]]; }

qdrant_install_docker() {
    header "Install Qdrant — Docker"

    QD_IMAGE_TAG=$(gum input \
        --placeholder "$QD_DEFAULT_IMAGE_TAG" \
        --header "Qdrant image tag (leave empty for '${QD_DEFAULT_IMAGE_TAG}'):") || true
    QD_IMAGE_TAG="${QD_IMAGE_TAG:-$QD_DEFAULT_IMAGE_TAG}"

    local rest_input grpc_input
    rest_input=$(gum input \
        --placeholder "$QD_DEFAULT_REST_PORT" \
        --header "REST host port (leave empty for ${QD_DEFAULT_REST_PORT}):") || true
    QD_REST_PORT="${rest_input:-$QD_DEFAULT_REST_PORT}"

    grpc_input=$(gum input \
        --placeholder "$QD_DEFAULT_GRPC_PORT" \
        --header "gRPC host port (leave empty for ${QD_DEFAULT_GRPC_PORT}):") || true
    QD_GRPC_PORT="${grpc_input:-$QD_DEFAULT_GRPC_PORT}"

    _prompt_api_key

    local image="qdrant/qdrant:${QD_IMAGE_TAG}"
    local volume="${QD_CONTAINER_NAME}-data"

    if _docker_container_exists "$QD_CONTAINER_NAME"; then
        gum style \
            --foreground "$YELLOW" --border-foreground "$YELLOW" --border rounded \
            --align center --width 60 --margin "1 2" --padding "1 4" \
            "Container '${QD_CONTAINER_NAME}' already exists."

        local action
        action=$(gum choose \
            "Remove and recreate" \
            "Cancel" \
            --header "What would you like to do?") || true

        case "$action" in
            "Remove and recreate")
                gum spin --spinner dot --title "Removing existing container..." -- \
                    docker rm -f "$QD_CONTAINER_NAME" ;;
            *) warn "Cancelled."; return ;;
        esac
    fi

    gum spin --spinner dot --title "Pulling ${image}..." -- \
        docker pull "$image" \
        || error_exit "Failed to pull image ${image}."

    # Build env args — API key is optional
    local env_args=()
    [[ -n "$QD_API_KEY" ]] && env_args+=(-e "QDRANT__SERVICE__API_KEY=${QD_API_KEY}")

    if ! docker run -d \
        --name "$QD_CONTAINER_NAME" \
        "${env_args[@]}" \
        -p "${QD_REST_PORT}:6333" \
        -p "${QD_GRPC_PORT}:6334" \
        -v "${volume}:/qdrant/storage" \
        --restart unless-stopped \
        "$image" &>/dev/null; then
        error_exit "Failed to start container '${QD_CONTAINER_NAME}'."
    fi

    info "Waiting for Qdrant REST API to become ready..."
    local attempts=0
    until curl -sf "http://127.0.0.1:${QD_REST_PORT}/healthz" &>/dev/null 2>&1; do
        attempts=$((attempts + 1))
        if [[ $attempts -ge 30 ]]; then
            warn "Timed out waiting for readiness. Check: docker logs ${QD_CONTAINER_NAME}"
            break
        fi
        sleep 1
    done

    gum style \
        --foreground "$GREEN" --border-foreground "$GREEN" --border rounded \
        --align center --width 60 --margin "1 2" --padding "1 4" \
        "Qdrant running" \
        "" \
        "Container:   ${QD_CONTAINER_NAME}" \
        "Image:       ${image}" \
        "REST API:    http://127.0.0.1:${QD_REST_PORT}" \
        "gRPC:        127.0.0.1:${QD_GRPC_PORT}" \
        "Volume:      ${volume}" \
        "Auth:        ${QD_API_KEY:+API key set}${QD_API_KEY:-none (open access)}"
}

qdrant_status_docker() {
    header "Qdrant — Docker Status"

    if ! _docker_container_exists "$QD_CONTAINER_NAME"; then
        warn "Container '${QD_CONTAINER_NAME}' not found."
        return
    fi

    local status image ports
    status=$(docker inspect --format='{{.State.Status}}' "$QD_CONTAINER_NAME" 2>/dev/null)
    image=$(docker inspect --format='{{.Config.Image}}'  "$QD_CONTAINER_NAME" 2>/dev/null)
    ports=$(docker inspect \
        --format='{{range $k,$v := .NetworkSettings.Ports}}{{$k}} -> {{range $v}}{{.HostIP}}:{{.HostPort}}{{end}}  {{end}}' \
        "$QD_CONTAINER_NAME" 2>/dev/null)

    gum style \
        --foreground "$CYAN" --border-foreground "$CYAN" --border rounded \
        --align left --width 60 --margin "1 2" --padding "1 4" \
        "Container: ${QD_CONTAINER_NAME}" \
        "Status:    ${status}" \
        "Image:     ${image}" \
        "Ports:     ${ports}"

    echo ""
    gum confirm "Press Enter to continue" --affirmative "OK" --negative "" || true
}

qdrant_health_check_docker() {
    header "Qdrant — Health Check"

    if ! _docker_container_exists "$QD_CONTAINER_NAME"; then
        warn "Container '${QD_CONTAINER_NAME}' not found."
        return
    fi
    if ! _docker_container_running "$QD_CONTAINER_NAME"; then
        warn "Container '${QD_CONTAINER_NAME}' is not running."
        return
    fi

    # Resolve the mapped REST port from the running container.
    local port
    port=$(docker inspect \
        --format='{{range $k,$v := .NetworkSettings.Ports}}{{if eq $k "6333/tcp"}}{{range $v}}{{.HostPort}}{{end}}{{end}}{{end}}' \
        "$QD_CONTAINER_NAME" 2>/dev/null)
    port="${port:-$QD_DEFAULT_REST_PORT}"

    _rest_health_check "$port"
}

qdrant_uninstall_docker() {
    header "Uninstall Qdrant — Docker"

    if ! _docker_container_exists "$QD_CONTAINER_NAME"; then
        warn "Container '${QD_CONTAINER_NAME}' not found."
        return
    fi

    local volume="${QD_CONTAINER_NAME}-data"

    gum style \
        --foreground "$RED" --border-foreground "$RED" --border rounded \
        --width 60 --margin "0 2" --padding "1 2" \
        "This will remove container '${QD_CONTAINER_NAME}'." \
        "" \
        "Data volume: ${volume}"

    if ! gum confirm "Remove container '${QD_CONTAINER_NAME}'?"; then
        warn "Cancelled."
        return
    fi

    local remove_volume=false
    gum confirm "Also remove data volume '${volume}'? (all vectors will be lost)" \
        && remove_volume=true || true

    gum spin --spinner dot --title "Removing container '${QD_CONTAINER_NAME}'..." -- \
        docker rm -f "$QD_CONTAINER_NAME" || true

    if [[ "$remove_volume" == true ]]; then
        gum spin --spinner dot --title "Removing volume '${volume}'..." -- \
            docker volume rm "$volume" 2>/dev/null \
            || warn "Volume '${volume}' not found or already removed."
        success "Container and volume removed."
    else
        success "Container removed. Volume '${volume}' retained."
    fi
}

# -----------------------------------------------------------------------------
# Kubernetes — install / status / port-forward / health-check / uninstall
# -----------------------------------------------------------------------------

_k8s_detect_installed() {
    helm status "$QD_HELM_RELEASE" -n "$QD_NAMESPACE" &>/dev/null 2>&1
}

_k8s_ensure_namespace() {
    if kubectl get namespace "$QD_NAMESPACE" &>/dev/null; then
        info "Namespace '${QD_NAMESPACE}' already exists."
    else
        info "Creating namespace '${QD_NAMESPACE}'..."
        kubectl create namespace "$QD_NAMESPACE"
    fi
}

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

qdrant_install_k8s() {
    header "Install Qdrant — Kubernetes"
    _k8s_check_cluster || return 0

    _prompt_api_key

    local storage_size
    storage_size=$(gum input \
        --placeholder "10Gi" \
        --header "Persistent volume size (leave empty for '10Gi'):") || true
    storage_size="${storage_size:-10Gi}"

    local replicas
    replicas=$(gum input \
        --placeholder "1" \
        --header "Replica count (leave empty for 1):") || true
    replicas="${replicas:-1}"

    _k8s_ensure_namespace
    _ensure_helm_repo

    local helm_args=(
        "$QD_HELM_RELEASE" "$QD_HELM_CHART"
        --namespace "$QD_NAMESPACE"
        --set replicaCount="$replicas"
        --set persistence.size="$storage_size"
        --wait --timeout 5m
    )
    [[ -n "$QD_API_KEY" ]] && helm_args+=(--set "config.service.api_key=${QD_API_KEY}")

    if _k8s_detect_installed; then
        gum style \
            --foreground "$YELLOW" --border-foreground "$YELLOW" --border rounded \
            --align center --width 60 --margin "1 2" --padding "1 4" \
            "Release '${QD_HELM_RELEASE}' already exists in '${QD_NAMESPACE}'."

        local action
        action=$(gum choose \
            "Upgrade (apply new values)" \
            "Cancel" \
            --header "What would you like to do?") || true

        case "$action" in
            "Upgrade"*) ;;
            *) warn "Cancelled."; return ;;
        esac

        gum spin --spinner dot --title "Upgrading Qdrant via Helm..." -- \
            helm upgrade "${helm_args[@]}" \
            || error_exit "Helm upgrade failed. Check: kubectl get pods -n ${QD_NAMESPACE}"
    else
        gum spin --spinner dot --title "Installing Qdrant via Helm (may take a few minutes)..." -- \
            helm install "${helm_args[@]}" \
            || error_exit "Helm install failed. Check: kubectl get pods -n ${QD_NAMESPACE}"
    fi

    gum style \
        --foreground "$GREEN" --border-foreground "$GREEN" --border rounded \
        --align center --width 60 --margin "1 2" --padding "1 4" \
        "Qdrant installed" \
        "" \
        "Release:    ${QD_HELM_RELEASE}" \
        "Namespace:  ${QD_NAMESPACE}" \
        "Replicas:   ${replicas}" \
        "Auth:       ${QD_API_KEY:+API key set}${QD_API_KEY:-none (open access)}" \
        "" \
        "Use 'port-forward' or 'health-check' from the menu to access it."
}

qdrant_status_k8s() {
    header "Qdrant — Kubernetes Status"
    _k8s_check_cluster || return 0

    if ! _k8s_detect_installed; then
        warn "Release '${QD_HELM_RELEASE}' not found in namespace '${QD_NAMESPACE}'."
        return
    fi

    gum style --foreground "$CYAN" --bold "── Helm release ──"
    helm status "$QD_HELM_RELEASE" -n "$QD_NAMESPACE" 2>/dev/null || true

    echo ""
    gum style --foreground "$CYAN" --bold "── Pods ──"
    kubectl get pods -n "$QD_NAMESPACE" 2>/dev/null || true

    echo ""
    gum style --foreground "$CYAN" --bold "── Services ──"
    kubectl get svc -n "$QD_NAMESPACE" 2>/dev/null || true

    echo ""
    gum confirm "Press Enter to continue" --affirmative "OK" --negative "" || true
}

_qd_rest_pf_is_running() { [[ -f "$_QD_REST_PF_PID" ]] && kill -0 "$(cut -d: -f1 < "$_QD_REST_PF_PID")" 2>/dev/null; }
_qd_rest_pf_port()       { cut -d: -f2 < "$_QD_REST_PF_PID" 2>/dev/null; }
_qd_rest_pf_stop()       { kill "$(cut -d: -f1 < "$_QD_REST_PF_PID")" 2>/dev/null || true; rm -f "$_QD_REST_PF_PID"; }
_qd_grpc_pf_is_running() { [[ -f "$_QD_GRPC_PF_PID" ]] && kill -0 "$(cut -d: -f1 < "$_QD_GRPC_PF_PID")" 2>/dev/null; }
_qd_grpc_pf_port()       { cut -d: -f2 < "$_QD_GRPC_PF_PID" 2>/dev/null; }
_qd_grpc_pf_stop()       { kill "$(cut -d: -f1 < "$_QD_GRPC_PF_PID")" 2>/dev/null || true; rm -f "$_QD_GRPC_PF_PID"; }

qdrant_port_forward_k8s() {
    header "Qdrant — Port Forward"
    _k8s_check_cluster || return 0

    if ! _k8s_detect_installed; then
        warn "Release '${QD_HELM_RELEASE}' not found in namespace '${QD_NAMESPACE}'."
        return
    fi

    if _qd_rest_pf_is_running || _qd_grpc_pf_is_running; then
        local rest_info grpc_info
        _qd_rest_pf_is_running \
            && rest_info="REST  http://localhost:$(_qd_rest_pf_port)" \
            || rest_info="REST  stopped"
        _qd_grpc_pf_is_running \
            && grpc_info="gRPC  localhost:$(_qd_grpc_pf_port)" \
            || grpc_info="gRPC  stopped"
        gum style --foreground "$GREEN" --border-foreground "$GREEN" --border rounded \
            --width 60 --margin "0 2" --padding "1 2" \
            "Port-forwards are running" \
            "$rest_info" \
            "$grpc_info"
        if gum confirm "Stop port-forwards?"; then
            _qd_rest_pf_stop
            _qd_grpc_pf_stop
            success "Port-forwards stopped."
        fi
        return
    fi

    local rest_input grpc_input
    rest_input=$(gum input \
        --placeholder "$QD_DEFAULT_REST_PORT" \
        --header "Local REST port (leave empty for ${QD_DEFAULT_REST_PORT}):") || true
    local rest_port="${rest_input:-$QD_DEFAULT_REST_PORT}"

    grpc_input=$(gum input \
        --placeholder "$QD_DEFAULT_GRPC_PORT" \
        --header "Local gRPC port (leave empty for ${QD_DEFAULT_GRPC_PORT}):") || true
    local grpc_port="${grpc_input:-$QD_DEFAULT_GRPC_PORT}"

    kubectl -n "$QD_NAMESPACE" port-forward "svc/${QD_HELM_RELEASE}" "${grpc_port}:6334" >/dev/null 2>&1 &
    echo "${!}:${grpc_port}" > "$_QD_GRPC_PF_PID"

    kubectl -n "$QD_NAMESPACE" port-forward "svc/${QD_HELM_RELEASE}" "${rest_port}:6333" >/dev/null 2>&1 &
    echo "${!}:${rest_port}" > "$_QD_REST_PF_PID"

    local attempts=0
    until nc -z 127.0.0.1 "$rest_port" 2>/dev/null || [[ $attempts -ge 20 ]]; do
        sleep 0.25; attempts=$((attempts + 1))
    done

    if ! _qd_rest_pf_is_running; then
        warn "REST port-forward failed to start. Check kubectl connectivity."
        _qd_grpc_pf_stop
        rm -f "$_QD_REST_PF_PID"
        return
    fi

    success "Port-forwards started:"
    success "  REST  http://localhost:${rest_port}"
    success "  gRPC  localhost:${grpc_port}"
}

qdrant_health_check_k8s() {
    header "Qdrant — Health Check"
    _k8s_check_cluster || return 0

    if ! _k8s_detect_installed; then
        warn "Release '${QD_HELM_RELEASE}' not found in namespace '${QD_NAMESPACE}'."
        return
    fi

    local port_input
    port_input=$(gum input \
        --placeholder "$QD_DEFAULT_REST_PORT" \
        --header "Local REST port for port-forward (leave empty for ${QD_DEFAULT_REST_PORT}):") || true
    local port="${port_input:-$QD_DEFAULT_REST_PORT}"

    info "Starting REST port-forward in background..."
    kubectl -n "$QD_NAMESPACE" port-forward "svc/${QD_HELM_RELEASE}" "${port}:6333" >/dev/null 2>&1 &
    local pf_pid=$!

    local attempts=0
    until nc -z 127.0.0.1 "$port" 2>/dev/null; do
        attempts=$((attempts + 1))
        if [[ $attempts -ge 20 ]]; then
            warn "Port-forward did not become ready in time."
            kill "$pf_pid" 2>/dev/null || true
            return
        fi
        sleep 0.5
    done

    _rest_health_check "$port"

    kill "$pf_pid" 2>/dev/null || true
    wait "$pf_pid" 2>/dev/null || true
}

qdrant_uninstall_k8s() {
    header "Uninstall Qdrant — Kubernetes"
    _k8s_check_cluster || return 0

    if ! _k8s_detect_installed; then
        warn "Release '${QD_HELM_RELEASE}' not found in namespace '${QD_NAMESPACE}'."
        return
    fi

    gum style \
        --foreground "$RED" --border-foreground "$RED" --border rounded \
        --width 60 --margin "0 2" --padding "1 2" \
        "This will remove Helm release '${QD_HELM_RELEASE}'" \
        "from namespace '${QD_NAMESPACE}'." \
        "" \
        "PersistentVolumeClaims are NOT removed automatically by Helm." \
        "Delete them manually to fully purge data:" \
        "  kubectl delete pvc --all -n ${QD_NAMESPACE}"

    if ! gum confirm "Uninstall Qdrant?"; then
        warn "Cancelled."
        return
    fi

    gum spin --spinner dot --title "Running helm uninstall..." -- \
        helm uninstall "$QD_HELM_RELEASE" -n "$QD_NAMESPACE" || true

    if gum confirm "Also delete namespace '${QD_NAMESPACE}' (removes remaining PVCs too)?"; then
        gum spin --spinner dot --title "Deleting namespace '${QD_NAMESPACE}'..." -- \
            kubectl delete namespace "$QD_NAMESPACE" --ignore-not-found || true
        success "Namespace deleted."
    fi

    success "Qdrant uninstalled."
}

# -----------------------------------------------------------------------------
# Menus
# -----------------------------------------------------------------------------

_docker_menu() {
    local name_input
    name_input=$(gum input \
        --placeholder "qdrant" \
        --header "Container name for this session (leave empty for 'qdrant'):") || true
    QD_CONTAINER_NAME="${name_input:-qdrant}"

    while true; do
        header "Qdrant — Docker  (${QD_CONTAINER_NAME})"

        local action
        action=$(gum choose \
            "install" \
            "status" \
            "health-check" \
            "uninstall" \
            "← back" \
            --header "Select action:") || true

        case "$action" in
            "install")      qdrant_install_docker ;;
            "status")       qdrant_status_docker ;;
            "health-check") qdrant_health_check_docker ;;
            "uninstall")    qdrant_uninstall_docker ;;
            "← back"|"")   return ;;
        esac
    done
}

_k8s_menu() {
    local ns_input
    ns_input=$(gum input \
        --placeholder "$QD_NAMESPACE" \
        --header "Kubernetes namespace for this session (leave empty for '${QD_NAMESPACE}'):") || true
    QD_NAMESPACE="${ns_input:-$QD_NAMESPACE}"

    local release_input
    release_input=$(gum input \
        --placeholder "$QD_HELM_RELEASE" \
        --header "Helm release name (leave empty for '${QD_HELM_RELEASE}'):") || true
    QD_HELM_RELEASE="${release_input:-$QD_HELM_RELEASE}"

    while true; do
        header "Qdrant — Kubernetes  (${TARGET_TYPE}: ${TARGET_CONTEXT} / ns: ${QD_NAMESPACE} / release: ${QD_HELM_RELEASE})"

        local pf_label
        if _qd_rest_pf_is_running || _qd_grpc_pf_is_running; then
            local rest_part grpc_part
            _qd_rest_pf_is_running && rest_part="REST:$(_qd_rest_pf_port)" || rest_part="REST:stopped"
            _qd_grpc_pf_is_running && grpc_part="gRPC:$(_qd_grpc_pf_port)" || grpc_part="gRPC:stopped"
            pf_label="port-forward  [● ${rest_part} ${grpc_part}]"
        else
            pf_label="port-forward  [○ stopped]"
        fi

        local action
        action=$(gum choose \
            "install" \
            "status" \
            "$pf_label" \
            "health-check" \
            "uninstall" \
            "← back" \
            --header "Select action:") || true

        case "$action" in
            "install")       qdrant_install_k8s ;;
            "status")        qdrant_status_k8s ;;
            "port-forward"*) qdrant_port_forward_k8s ;;
            "health-check")  qdrant_health_check_k8s ;;
            "uninstall")     qdrant_uninstall_k8s ;;
            "← back"|"")    return ;;
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
        "Qdrant" \
        "Vector Database  ·  Docker  ·  Kubernetes"

    info "Select a deployment target..."
    select_target || exit 1

    check_dependencies

    case "$TARGET_TYPE" in
        docker)   _docker_menu ;;
        kind|k8s) _k8s_menu ;;
    esac

    gum style --faint "Bye."
}

main "$@"
