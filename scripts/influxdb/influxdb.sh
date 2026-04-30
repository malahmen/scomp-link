#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# influxdb.sh
# Interactive TUI for installing and managing InfluxDB 2.x.
# Supports Docker (local container) and Kubernetes (Bitnami Helm chart).
# Called by init.sh — expects gum to be available.
# Hard dependencies: docker (Docker target) | kubectl + helm (K8s target).
# Sources: scripts/cluster/cluster.sh for deployment target selection.
#
# InfluxDB 2.x uses an org/bucket/token model.
# Docker: init env vars configure admin user, org, bucket, and optional token.
# K8s:   same via Bitnami chart Helm values.
# Connect: web UI at :8086 (Docker: already mapped; K8s: port-forward).
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

IDB_NAMESPACE="influxdb"
IDB_HELM_RELEASE="influxdb"
IDB_HELM_CHART="oci://registry-1.docker.io/bitnamicharts/influxdb"
IDB_DEFAULT_PORT=8086
IDB_DEFAULT_IMAGE_TAG="2"
IDB_DEFAULT_ADMIN_USER="admin"
IDB_DEFAULT_ORG="myorg"
IDB_DEFAULT_BUCKET="default"

# Colours
CYAN=212
RED=196
GREEN=82
YELLOW=220
BLUE=39

# Session state — populated by _docker_menu / _k8s_menu
IDB_CONTAINER_NAME="influxdb"
IDB_IMAGE_TAG="$IDB_DEFAULT_IMAGE_TAG"
IDB_ADMIN_USER="$IDB_DEFAULT_ADMIN_USER"
IDB_ADMIN_PASSWORD=""
IDB_ORG="$IDB_DEFAULT_ORG"
IDB_BUCKET="$IDB_DEFAULT_BUCKET"
IDB_TOKEN=""
IDB_PORT=$IDB_DEFAULT_PORT

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
        "helm is required to install InfluxDB on Kubernetes."

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

_prompt_admin_config() {
    IDB_ADMIN_USER=$(gum input \
        --placeholder "$IDB_DEFAULT_ADMIN_USER" \
        --header "Admin username (leave empty for '${IDB_DEFAULT_ADMIN_USER}'):") || true
    IDB_ADMIN_USER="${IDB_ADMIN_USER:-$IDB_DEFAULT_ADMIN_USER}"

    IDB_ADMIN_PASSWORD=$(gum input \
        --placeholder "leave empty to auto-generate" \
        --password \
        --header "Admin password (leave empty to auto-generate):") || true

    if [[ -z "$IDB_ADMIN_PASSWORD" ]]; then
        IDB_ADMIN_PASSWORD=$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24)
        gum style \
            --foreground "$YELLOW" --border-foreground "$YELLOW" --border rounded \
            --align center --width 60 --margin "1 0" --padding "0 4" \
            "Generated password: ${IDB_ADMIN_PASSWORD}" \
            "Save this — it will not be shown again."
    fi

    IDB_ORG=$(gum input \
        --placeholder "$IDB_DEFAULT_ORG" \
        --header "Organisation name (leave empty for '${IDB_DEFAULT_ORG}'):") || true
    IDB_ORG="${IDB_ORG:-$IDB_DEFAULT_ORG}"

    IDB_BUCKET=$(gum input \
        --placeholder "$IDB_DEFAULT_BUCKET" \
        --header "Initial bucket name (leave empty for '${IDB_DEFAULT_BUCKET}'):") || true
    IDB_BUCKET="${IDB_BUCKET:-$IDB_DEFAULT_BUCKET}"

    IDB_TOKEN=$(gum input \
        --placeholder "leave empty to auto-generate" \
        --password \
        --header "Admin token (leave empty to auto-generate):") || true

    if [[ -z "$IDB_TOKEN" ]]; then
        gum style --foreground "$YELLOW" \
            "[warn] Token will be auto-generated. Retrieve it from the web UI under" \
            "       Data → API Tokens after the container starts."
    fi
}

# -----------------------------------------------------------------------------
# Docker helpers
# -----------------------------------------------------------------------------

_docker_container_exists()  { docker inspect "$1" &>/dev/null 2>&1; }
_docker_container_running() {
    [[ "$(docker inspect --format='{{.State.Running}}' "$1" 2>/dev/null)" == "true" ]]
}

_docker_get_port() {
    docker inspect \
        --format='{{range $p, $c := .NetworkSettings.Ports}}{{if eq $p "8086/tcp"}}{{(index $c 0).HostPort}}{{end}}{{end}}' \
        "$1" 2>/dev/null || echo "$IDB_DEFAULT_PORT"
}

_docker_get_env() {
    local container="$1" key="$2"
    docker inspect --format='{{range .Config.Env}}{{println .}}{{end}}' "$container" 2>/dev/null \
        | grep "^${key}=" | cut -d= -f2- || true
}

# -----------------------------------------------------------------------------
# Docker — install / status / connect / uninstall
# -----------------------------------------------------------------------------

influxdb_install_docker() {
    header "Install InfluxDB — Docker"

    IDB_IMAGE_TAG=$(gum input \
        --placeholder "$IDB_DEFAULT_IMAGE_TAG" \
        --header "InfluxDB image tag (leave empty for '${IDB_DEFAULT_IMAGE_TAG}'):") || true
    IDB_IMAGE_TAG="${IDB_IMAGE_TAG:-$IDB_DEFAULT_IMAGE_TAG}"

    local port_input
    port_input=$(gum input \
        --placeholder "$IDB_DEFAULT_PORT" \
        --header "Host port (leave empty for ${IDB_DEFAULT_PORT}):") || true
    IDB_PORT="${port_input:-$IDB_DEFAULT_PORT}"

    _prompt_admin_config

    local image="influxdb:${IDB_IMAGE_TAG}"
    local volume="${IDB_CONTAINER_NAME}-data"

    if _docker_container_exists "$IDB_CONTAINER_NAME"; then
        gum style \
            --foreground "$YELLOW" --border-foreground "$YELLOW" --border rounded \
            --align center --width 60 --margin "1 2" --padding "1 4" \
            "Container '${IDB_CONTAINER_NAME}' already exists."

        local action
        action=$(gum choose \
            "Remove and recreate" \
            "Cancel" \
            --header "What would you like to do?") || true

        case "$action" in
            "Remove and recreate")
                gum spin --spinner dot --title "Removing existing container..." -- \
                    docker rm -f "$IDB_CONTAINER_NAME" ;;
            *) warn "Cancelled."; return ;;
        esac
    fi

    gum spin --spinner dot --title "Pulling ${image}..." -- \
        docker pull "$image" \
        || error_exit "Failed to pull image ${image}."

    local docker_args=(
        run -d
        --name "$IDB_CONTAINER_NAME"
        -p "${IDB_PORT}:8086"
        -e DOCKER_INFLUXDB_INIT_MODE=setup
        -e DOCKER_INFLUXDB_INIT_USERNAME="$IDB_ADMIN_USER"
        -e DOCKER_INFLUXDB_INIT_PASSWORD="$IDB_ADMIN_PASSWORD"
        -e DOCKER_INFLUXDB_INIT_ORG="$IDB_ORG"
        -e DOCKER_INFLUXDB_INIT_BUCKET="$IDB_BUCKET"
        -v "${volume}:/var/lib/influxdb2"
        --restart unless-stopped
    )

    if [[ -n "$IDB_TOKEN" ]]; then
        docker_args+=(-e DOCKER_INFLUXDB_INIT_ADMIN_TOKEN="$IDB_TOKEN")
    fi

    docker_args+=("$image")

    if ! docker "${docker_args[@]}" &>/dev/null; then
        error_exit "Failed to start container '${IDB_CONTAINER_NAME}'."
    fi

    info "Waiting for InfluxDB to be ready..."
    local attempts=0
    until curl -sf "http://127.0.0.1:${IDB_PORT}/ping" &>/dev/null; do
        attempts=$((attempts + 1))
        if [[ $attempts -ge 40 ]]; then
            warn "Timed out waiting for readiness. Check: docker logs ${IDB_CONTAINER_NAME}"
            break
        fi
        sleep 1
    done

    gum style \
        --foreground "$GREEN" --border-foreground "$GREEN" --border rounded \
        --align center --width 60 --margin "1 2" --padding "1 4" \
        "InfluxDB running" \
        "" \
        "Web UI:   http://localhost:${IDB_PORT}" \
        "User:     ${IDB_ADMIN_USER}" \
        "Org:      ${IDB_ORG}" \
        "Bucket:   ${IDB_BUCKET}" \
        "Volume:   ${volume}"
}

influxdb_status_docker() {
    header "Status — InfluxDB Docker"

    if ! _docker_container_exists "$IDB_CONTAINER_NAME"; then
        warn "Container '${IDB_CONTAINER_NAME}' not found."
        return
    fi

    local status image ports
    status=$(docker inspect --format='{{.State.Status}}' "$IDB_CONTAINER_NAME" 2>/dev/null)
    image=$(docker inspect  --format='{{.Config.Image}}'  "$IDB_CONTAINER_NAME" 2>/dev/null)
    ports=$(docker inspect \
        --format='{{range $k,$v := .NetworkSettings.Ports}}{{$k}} -> {{range $v}}{{.HostIP}}:{{.HostPort}}{{end}}  {{end}}' \
        "$IDB_CONTAINER_NAME" 2>/dev/null)

    gum style \
        --foreground "$CYAN" --border-foreground "$CYAN" --border rounded \
        --align left --width 60 --margin "1 2" --padding "1 4" \
        "Container: ${IDB_CONTAINER_NAME}" \
        "Status:    ${status}" \
        "Image:     ${image}" \
        "Ports:     ${ports}"

    local port
    port=$(_docker_get_port "$IDB_CONTAINER_NAME")

    echo ""
    info "Health check (http://127.0.0.1:${port}/health):"
    if curl -sf "http://127.0.0.1:${port}/health" 2>/dev/null | python3 -m json.tool 2>/dev/null; then
        :
    else
        warn "Could not reach InfluxDB — container may still be starting."
    fi

    echo ""
    gum confirm "Press Enter to continue" --affirmative "OK" --negative "" || true
}

influxdb_connect_docker() {
    header "Connect — InfluxDB Docker"

    if ! _docker_container_exists "$IDB_CONTAINER_NAME"; then
        warn "Container '${IDB_CONTAINER_NAME}' not found."
        return
    fi
    if ! _docker_container_running "$IDB_CONTAINER_NAME"; then
        warn "Container '${IDB_CONTAINER_NAME}' is not running."
        return
    fi

    local port
    port=$(_docker_get_port "$IDB_CONTAINER_NAME")

    local admin_user org bucket
    admin_user=$(_docker_get_env "$IDB_CONTAINER_NAME" "DOCKER_INFLUXDB_INIT_USERNAME")
    org=$(_docker_get_env        "$IDB_CONTAINER_NAME" "DOCKER_INFLUXDB_INIT_ORG")
    bucket=$(_docker_get_env     "$IDB_CONTAINER_NAME" "DOCKER_INFLUXDB_INIT_BUCKET")

    gum style \
        --foreground "$CYAN" --border-foreground "$CYAN" --border rounded \
        --align left --width 60 --margin "1 2" --padding "1 4" \
        "InfluxDB Web UI → http://localhost:${port}" \
        "" \
        "Username: ${admin_user:-<see container env>}" \
        "Org:      ${org:-<see container env>}" \
        "Bucket:   ${bucket:-<see container env>}" \
        "" \
        "API Tokens: Data → API Tokens in the web UI."

    echo ""

    local choice
    choice=$(gum choose \
        "Open influx CLI (in container)" \
        "Done" \
        --header "What would you like to do?") || true

    case "$choice" in
        "Open influx CLI"*)
            info "Opening influx CLI inside '${IDB_CONTAINER_NAME}'. Type exit to quit."
            echo ""
            docker exec -it "$IDB_CONTAINER_NAME" influx
            ;;
        *) ;;
    esac
}

influxdb_uninstall_docker() {
    header "Uninstall InfluxDB — Docker"

    if ! _docker_container_exists "$IDB_CONTAINER_NAME"; then
        warn "Container '${IDB_CONTAINER_NAME}' not found."
        return
    fi

    local volume="${IDB_CONTAINER_NAME}-data"

    gum style \
        --foreground "$RED" --border-foreground "$RED" --border rounded \
        --width 60 --margin "0 2" --padding "1 2" \
        "This will remove container '${IDB_CONTAINER_NAME}'." \
        "" \
        "Data volume: ${volume}"

    if ! gum confirm "Remove container '${IDB_CONTAINER_NAME}'?"; then
        warn "Cancelled."
        return
    fi

    local remove_volume=false
    gum confirm "Also remove data volume '${volume}'? (all data will be lost)" \
        && remove_volume=true || true

    gum spin --spinner dot --title "Removing container '${IDB_CONTAINER_NAME}'..." -- \
        docker rm -f "$IDB_CONTAINER_NAME" || true

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
# Kubernetes helpers
# -----------------------------------------------------------------------------

_k8s_detect_installed() {
    helm status "$IDB_HELM_RELEASE" -n "$IDB_NAMESPACE" &>/dev/null 2>&1
}

_k8s_ensure_namespace() {
    if kubectl get namespace "$IDB_NAMESPACE" &>/dev/null; then
        info "Namespace '${IDB_NAMESPACE}' already exists."
    else
        info "Creating namespace '${IDB_NAMESPACE}'..."
        kubectl create namespace "$IDB_NAMESPACE"
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

# Starts a background port-forward to the InfluxDB service.
# Prints the PID to stdout; caller must kill it when done.
_k8s_start_port_forward() {
    local port="$1"
    local svc="${IDB_HELM_RELEASE}-influxdb"
    if ! kubectl get svc "$svc" -n "$IDB_NAMESPACE" &>/dev/null 2>&1; then
        svc="$IDB_HELM_RELEASE"
    fi
    kubectl -n "$IDB_NAMESPACE" port-forward "svc/${svc}" "${port}:8086" >/dev/null 2>&1 &
    echo $!
}

# -----------------------------------------------------------------------------
# Kubernetes — install / status / connect / uninstall
# -----------------------------------------------------------------------------

influxdb_install_k8s() {
    header "Install InfluxDB — Kubernetes"
    _k8s_check_cluster || return 0

    _prompt_admin_config

    local storage_size
    storage_size=$(gum input \
        --placeholder "8Gi" \
        --header "Persistent volume size (leave empty for '8Gi'):") || true
    storage_size="${storage_size:-8Gi}"

    _k8s_ensure_namespace

    local helm_args=(
        "$IDB_HELM_RELEASE" "$IDB_HELM_CHART"
        --namespace "$IDB_NAMESPACE"
        --set auth.admin.username="$IDB_ADMIN_USER"
        --set auth.admin.password="$IDB_ADMIN_PASSWORD"
        --set auth.admin.org="$IDB_ORG"
        --set auth.admin.bucket="$IDB_BUCKET"
        --set persistence.size="$storage_size"
        --wait --timeout 5m
    )

    if [[ -n "$IDB_TOKEN" ]]; then
        helm_args+=(--set auth.admin.token="$IDB_TOKEN")
    fi

    if _k8s_detect_installed; then
        gum style \
            --foreground "$YELLOW" --border-foreground "$YELLOW" --border rounded \
            --align center --width 60 --margin "1 2" --padding "1 4" \
            "Release '${IDB_HELM_RELEASE}' already exists in '${IDB_NAMESPACE}'."

        local action
        action=$(gum choose \
            "Upgrade (apply new values)" \
            "Cancel" \
            --header "What would you like to do?") || true

        case "$action" in
            "Upgrade"*) ;;
            *) warn "Cancelled."; return ;;
        esac

        if ! gum spin --spinner dot --title "Upgrading InfluxDB (this may take a few minutes)..." -- \
            helm upgrade "${helm_args[@]}"; then
            warn "Upgrade failed. Check 'helm status ${IDB_HELM_RELEASE} -n ${IDB_NAMESPACE}' for details."
            return
        fi
        success "InfluxDB upgraded."
    else
        if ! gum spin --spinner dot --title "Installing InfluxDB (this may take a few minutes)..." -- \
            helm install "${helm_args[@]}"; then
            warn "Install failed. Check 'helm status ${IDB_HELM_RELEASE} -n ${IDB_NAMESPACE}' for details."
            return
        fi
        success "InfluxDB installed."
    fi

    echo ""
    gum style --foreground "$CYAN" \
        "Use 'connect' to open the web UI via port-forward." \
        "API Tokens are managed under Data → API Tokens in the web UI."
}

influxdb_status_k8s() {
    header "Status — InfluxDB Kubernetes"
    _k8s_check_cluster || return 0

    if ! _k8s_detect_installed; then
        warn "Release '${IDB_HELM_RELEASE}' not found in namespace '${IDB_NAMESPACE}'."
        return
    fi

    info "Helm release:"
    helm status "$IDB_HELM_RELEASE" -n "$IDB_NAMESPACE" 2>/dev/null | head -10
    echo ""

    info "Pods:"
    kubectl get pods -n "$IDB_NAMESPACE" --no-headers 2>/dev/null
    echo ""

    info "Services:"
    kubectl get svc -n "$IDB_NAMESPACE" --no-headers 2>/dev/null
    echo ""

    info "PersistentVolumeClaims:"
    kubectl get pvc -n "$IDB_NAMESPACE" --no-headers 2>/dev/null || true
}

influxdb_connect_k8s() {
    header "Connect — InfluxDB Kubernetes"
    _k8s_check_cluster || return 0

    if ! _k8s_detect_installed; then
        warn "Release '${IDB_HELM_RELEASE}' not found in namespace '${IDB_NAMESPACE}'."
        return
    fi

    local port_input
    port_input=$(gum input \
        --placeholder "$IDB_DEFAULT_PORT" \
        --header "Local port for port-forward (leave empty for ${IDB_DEFAULT_PORT}):") || true
    local port="${port_input:-$IDB_DEFAULT_PORT}"

    gum style \
        --foreground "$CYAN" --border-foreground "$CYAN" --border rounded \
        --width 60 --margin "0 2" --padding "1 2" \
        "InfluxDB Web UI → http://localhost:${port}" \
        "" \
        "Press Ctrl+C to stop the port-forward."

    local svc="${IDB_HELM_RELEASE}-influxdb"
    if ! kubectl get svc "$svc" -n "$IDB_NAMESPACE" &>/dev/null 2>&1; then
        svc="$IDB_HELM_RELEASE"
    fi

    kubectl -n "$IDB_NAMESPACE" port-forward "svc/${svc}" "${port}:8086"
}

influxdb_uninstall_k8s() {
    header "Uninstall InfluxDB — Kubernetes"
    _k8s_check_cluster || return 0

    if ! _k8s_detect_installed; then
        warn "Release '${IDB_HELM_RELEASE}' not found in namespace '${IDB_NAMESPACE}'."
        return
    fi

    gum style \
        --foreground "$RED" --border-foreground "$RED" --border rounded \
        --width 60 --margin "0 2" --padding "1 2" \
        "This will remove Helm release '${IDB_HELM_RELEASE}'" \
        "from namespace '${IDB_NAMESPACE}'." \
        "" \
        "PersistentVolumeClaims are NOT removed automatically by Helm." \
        "Delete them manually to fully purge data:" \
        "  kubectl delete pvc --all -n ${IDB_NAMESPACE}"

    if ! gum confirm "Uninstall InfluxDB?"; then
        warn "Cancelled."
        return
    fi

    gum spin --spinner dot --title "Running helm uninstall..." -- \
        helm uninstall "$IDB_HELM_RELEASE" -n "$IDB_NAMESPACE" || true

    if gum confirm "Also delete namespace '${IDB_NAMESPACE}' (removes remaining PVCs too)?"; then
        gum spin --spinner dot --title "Deleting namespace '${IDB_NAMESPACE}'..." -- \
            kubectl delete namespace "$IDB_NAMESPACE" --ignore-not-found || true
        success "Namespace deleted."
    fi

    success "InfluxDB uninstalled."
}

# -----------------------------------------------------------------------------
# Menus
# -----------------------------------------------------------------------------

_docker_menu() {
    local name_input
    name_input=$(gum input \
        --placeholder "influxdb" \
        --header "Container name for this session (leave empty for 'influxdb'):") || true
    IDB_CONTAINER_NAME="${name_input:-influxdb}"

    while true; do
        header "InfluxDB — Docker  (${IDB_CONTAINER_NAME})"

        local action
        action=$(gum choose \
            "install" \
            "status" \
            "connect" \
            "uninstall" \
            "← back" \
            --header "Select action:") || true

        case "$action" in
            "install")   influxdb_install_docker ;;
            "status")    influxdb_status_docker ;;
            "connect")   influxdb_connect_docker ;;
            "uninstall") influxdb_uninstall_docker ;;
            "← back"|"") return ;;
        esac
    done
}

_k8s_menu() {
    local ns_input
    ns_input=$(gum input \
        --placeholder "$IDB_NAMESPACE" \
        --header "Kubernetes namespace (leave empty for '${IDB_NAMESPACE}'):") || true
    IDB_NAMESPACE="${ns_input:-$IDB_NAMESPACE}"

    local release_input
    release_input=$(gum input \
        --placeholder "$IDB_HELM_RELEASE" \
        --header "Helm release name (leave empty for '${IDB_HELM_RELEASE}'):") || true
    IDB_HELM_RELEASE="${release_input:-$IDB_HELM_RELEASE}"

    while true; do
        header "InfluxDB — ${TARGET_TYPE}: ${TARGET_CONTEXT} / ns: ${IDB_NAMESPACE} / release: ${IDB_HELM_RELEASE}"

        local action
        action=$(gum choose \
            "install" \
            "status" \
            "connect" \
            "uninstall" \
            "← back" \
            --header "Select action:") || true

        case "$action" in
            "install")   influxdb_install_k8s ;;
            "status")    influxdb_status_k8s ;;
            "connect")   influxdb_connect_k8s ;;
            "uninstall") influxdb_uninstall_k8s ;;
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
        "InfluxDB 2.x" \
        "Docker  ·  Kubernetes"

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
