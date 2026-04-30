#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# n8n.sh
# Interactive TUI for installing and managing n8n workflow automation.
# Supports Docker (local container) and Kubernetes (community Helm chart).
# Called by init.sh — expects gum to be available.
# Hard dependencies: docker (Docker target) | kubectl + helm (K8s target).
# Sources: scripts/cluster/cluster.sh for deployment target selection.
#
# Database backends:
#   SQLite    — default, zero-config, single-instance only.
#   PostgreSQL — for multi-instance or production use.
#
# The encryption key protects all stored credentials.
# Loss or change of the key makes stored credentials unreadable — save it.
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

N8N_NAMESPACE="n8n"
N8N_HELM_RELEASE="n8n"
N8N_HELM_REPO_NAME="community-charts"
N8N_HELM_REPO_URL="https://community-charts.github.io/helm-charts"
N8N_HELM_CHART="community-charts/n8n"
N8N_DEFAULT_PORT=5678
N8N_DEFAULT_IMAGE_TAG="latest"
N8N_DEFAULT_TIMEZONE="UTC"

# Colours
CYAN=212
RED=196
GREEN=82
YELLOW=220
BLUE=39

# Session state — populated by _docker_menu / _k8s_menu
N8N_CONTAINER_NAME="n8n"
N8N_IMAGE_TAG="$N8N_DEFAULT_IMAGE_TAG"
N8N_PORT=$N8N_DEFAULT_PORT
N8N_ENCRYPTION_KEY=""
N8N_DB_TYPE="sqlite"      # sqlite | postgresdb
N8N_PG_HOST=""
N8N_PG_PORT="5432"
N8N_PG_DATABASE="n8n"
N8N_PG_USER="n8n"
N8N_PG_PASSWORD=""

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
        "helm is required to install n8n on Kubernetes."

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
    info "Adding/updating '${N8N_HELM_REPO_NAME}' helm repo..."
    helm repo add "$N8N_HELM_REPO_NAME" "$N8N_HELM_REPO_URL" 2>/dev/null || true
    gum spin --spinner dot --title "Updating helm repo..." -- \
        helm repo update "$N8N_HELM_REPO_NAME"
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

_prompt_encryption_key() {
    local key_input
    key_input=$(gum input \
        --placeholder "leave empty to auto-generate" \
        --password \
        --header "Encryption key (protects stored credentials — save it!):") || true

    if [[ -z "$key_input" ]]; then
        N8N_ENCRYPTION_KEY=$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 32)
        gum style \
            --foreground "$YELLOW" --border-foreground "$YELLOW" --border rounded \
            --align center --width 60 --margin "1 0" --padding "0 4" \
            "Generated encryption key:" \
            "${N8N_ENCRYPTION_KEY}" \
            "" \
            "SAVE THIS. Changing it makes all stored credentials unreadable."
    else
        N8N_ENCRYPTION_KEY="$key_input"
    fi
}

_prompt_postgres_config() {
    N8N_PG_HOST=$(gum input \
        --placeholder "localhost" \
        --header "PostgreSQL host:") || true
    N8N_PG_HOST="${N8N_PG_HOST:-localhost}"

    local port_input
    port_input=$(gum input \
        --placeholder "5432" \
        --header "PostgreSQL port (leave empty for 5432):") || true
    N8N_PG_PORT="${port_input:-5432}"

    N8N_PG_DATABASE=$(gum input \
        --placeholder "n8n" \
        --header "Database name (leave empty for 'n8n'):") || true
    N8N_PG_DATABASE="${N8N_PG_DATABASE:-n8n}"

    N8N_PG_USER=$(gum input \
        --placeholder "n8n" \
        --header "Username (leave empty for 'n8n'):") || true
    N8N_PG_USER="${N8N_PG_USER:-n8n}"

    N8N_PG_PASSWORD=$(gum input \
        --placeholder "" \
        --password \
        --header "Password:") || true
}

_prompt_db_backend() {
    local db_choice
    db_choice=$(gum choose \
        "SQLite (zero-config, single-instance)" \
        "PostgreSQL (production / multi-instance)" \
        --header "Database backend:") || true

    case "$db_choice" in
        "PostgreSQL"*)
            N8N_DB_TYPE="postgresdb"
            _prompt_postgres_config
            ;;
        *)
            N8N_DB_TYPE="sqlite"
            ;;
    esac
}

# -----------------------------------------------------------------------------
# Docker helpers
# -----------------------------------------------------------------------------

_docker_container_exists()  { docker inspect "$1" &>/dev/null 2>&1; }
_docker_container_running() {
    [[ "$(docker inspect --format='{{.State.Running}}' "$1" 2>/dev/null)" == "true" ]]
}

_docker_get_env() {
    local container="$1" key="$2"
    docker inspect --format='{{range .Config.Env}}{{println .}}{{end}}' "$container" 2>/dev/null \
        | grep "^${key}=" | cut -d= -f2- || true
}

# -----------------------------------------------------------------------------
# Docker — install / status / connect / uninstall
# -----------------------------------------------------------------------------

n8n_install_docker() {
    header "Install n8n — Docker"

    N8N_IMAGE_TAG=$(gum input \
        --placeholder "$N8N_DEFAULT_IMAGE_TAG" \
        --header "n8n image tag (leave empty for '${N8N_DEFAULT_IMAGE_TAG}'):") || true
    N8N_IMAGE_TAG="${N8N_IMAGE_TAG:-$N8N_DEFAULT_IMAGE_TAG}"

    local port_input
    port_input=$(gum input \
        --placeholder "$N8N_DEFAULT_PORT" \
        --header "Host port (leave empty for ${N8N_DEFAULT_PORT}):") || true
    N8N_PORT="${port_input:-$N8N_DEFAULT_PORT}"

    local tz_input
    tz_input=$(gum input \
        --placeholder "$N8N_DEFAULT_TIMEZONE" \
        --header "Timezone (leave empty for '${N8N_DEFAULT_TIMEZONE}'):") || true
    local timezone="${tz_input:-$N8N_DEFAULT_TIMEZONE}"

    _prompt_encryption_key
    _prompt_db_backend

    local image="n8nio/n8n:${N8N_IMAGE_TAG}"
    local volume="${N8N_CONTAINER_NAME}-data"

    if _docker_container_exists "$N8N_CONTAINER_NAME"; then
        gum style \
            --foreground "$YELLOW" --border-foreground "$YELLOW" --border rounded \
            --align center --width 60 --margin "1 2" --padding "1 4" \
            "Container '${N8N_CONTAINER_NAME}' already exists."

        local action
        action=$(gum choose \
            "Remove and recreate" \
            "Cancel" \
            --header "What would you like to do?") || true

        case "$action" in
            "Remove and recreate")
                gum spin --spinner dot --title "Removing existing container..." -- \
                    docker rm -f "$N8N_CONTAINER_NAME" ;;
            *) warn "Cancelled."; return ;;
        esac
    fi

    gum spin --spinner dot --title "Pulling ${image}..." -- \
        docker pull "$image" \
        || error_exit "Failed to pull image ${image}."

    local docker_args=(
        run -d
        --name "$N8N_CONTAINER_NAME"
        -p "${N8N_PORT}:5678"
        -e N8N_ENCRYPTION_KEY="$N8N_ENCRYPTION_KEY"
        -e GENERIC_TIMEZONE="$timezone"
        -v "${volume}:/home/node/.n8n"
        --restart unless-stopped
    )

    if [[ "$N8N_DB_TYPE" == "postgresdb" ]]; then
        docker_args+=(
            -e DB_TYPE=postgresdb
            -e DB_POSTGRESDB_HOST="$N8N_PG_HOST"
            -e DB_POSTGRESDB_PORT="$N8N_PG_PORT"
            -e DB_POSTGRESDB_DATABASE="$N8N_PG_DATABASE"
            -e DB_POSTGRESDB_USER="$N8N_PG_USER"
            -e DB_POSTGRESDB_PASSWORD="$N8N_PG_PASSWORD"
        )
    fi

    docker_args+=("$image")

    if ! docker "${docker_args[@]}" &>/dev/null; then
        error_exit "Failed to start container '${N8N_CONTAINER_NAME}'."
    fi

    info "Waiting for n8n to be ready..."
    local attempts=0
    until curl -sf "http://127.0.0.1:${N8N_PORT}/healthz" &>/dev/null; do
        attempts=$((attempts + 1))
        if [[ $attempts -ge 40 ]]; then
            warn "Timed out waiting for readiness. Check: docker logs ${N8N_CONTAINER_NAME}"
            break
        fi
        sleep 1
    done

    gum style \
        --foreground "$GREEN" --border-foreground "$GREEN" --border rounded \
        --align center --width 60 --margin "1 2" --padding "1 4" \
        "n8n running" \
        "" \
        "Web UI:   http://localhost:${N8N_PORT}" \
        "Database: ${N8N_DB_TYPE}" \
        "Volume:   ${volume}"
}

n8n_status_docker() {
    header "Status — n8n Docker"

    if ! _docker_container_exists "$N8N_CONTAINER_NAME"; then
        warn "Container '${N8N_CONTAINER_NAME}' not found."
        return
    fi

    local status image ports db_type
    status=$(docker inspect  --format='{{.State.Status}}' "$N8N_CONTAINER_NAME" 2>/dev/null)
    image=$(docker inspect   --format='{{.Config.Image}}'  "$N8N_CONTAINER_NAME" 2>/dev/null)
    ports=$(docker inspect \
        --format='{{range $k,$v := .NetworkSettings.Ports}}{{$k}} -> {{range $v}}{{.HostIP}}:{{.HostPort}}{{end}}  {{end}}' \
        "$N8N_CONTAINER_NAME" 2>/dev/null)
    db_type=$(_docker_get_env "$N8N_CONTAINER_NAME" "DB_TYPE")
    db_type="${db_type:-sqlite}"

    gum style \
        --foreground "$CYAN" --border-foreground "$CYAN" --border rounded \
        --align left --width 60 --margin "1 2" --padding "1 4" \
        "Container: ${N8N_CONTAINER_NAME}" \
        "Status:    ${status}" \
        "Image:     ${image}" \
        "Ports:     ${ports}" \
        "Database:  ${db_type}"

    local host_port
    host_port=$(docker inspect \
        --format='{{range $p,$c := .NetworkSettings.Ports}}{{if eq $p "5678/tcp"}}{{(index $c 0).HostPort}}{{end}}{{end}}' \
        "$N8N_CONTAINER_NAME" 2>/dev/null || echo "$N8N_DEFAULT_PORT")

    echo ""
    info "Health check:"
    if curl -sf "http://127.0.0.1:${host_port}/healthz" &>/dev/null; then
        success "n8n is healthy."
    else
        warn "n8n is not responding at http://127.0.0.1:${host_port}/healthz"
    fi

    echo ""
    gum confirm "Press Enter to continue" --affirmative "OK" --negative "" || true
}

n8n_connect_docker() {
    header "Connect — n8n Docker"

    if ! _docker_container_exists "$N8N_CONTAINER_NAME"; then
        warn "Container '${N8N_CONTAINER_NAME}' not found."
        return
    fi
    if ! _docker_container_running "$N8N_CONTAINER_NAME"; then
        warn "Container '${N8N_CONTAINER_NAME}' is not running."
        return
    fi

    local host_port
    host_port=$(docker inspect \
        --format='{{range $p,$c := .NetworkSettings.Ports}}{{if eq $p "5678/tcp"}}{{(index $c 0).HostPort}}{{end}}{{end}}' \
        "$N8N_CONTAINER_NAME" 2>/dev/null || echo "$N8N_DEFAULT_PORT")

    local db_type
    db_type=$(_docker_get_env "$N8N_CONTAINER_NAME" "DB_TYPE")
    db_type="${db_type:-sqlite}"

    gum style \
        --foreground "$CYAN" --border-foreground "$CYAN" --border rounded \
        --align left --width 60 --margin "1 2" --padding "1 4" \
        "n8n Web UI → http://localhost:${host_port}" \
        "" \
        "Database: ${db_type}" \
        "" \
        "First login creates your admin account."

    echo ""
    gum confirm "Press Enter to continue" --affirmative "OK" --negative "" || true
}

n8n_uninstall_docker() {
    header "Uninstall n8n — Docker"

    if ! _docker_container_exists "$N8N_CONTAINER_NAME"; then
        warn "Container '${N8N_CONTAINER_NAME}' not found."
        return
    fi

    local volume="${N8N_CONTAINER_NAME}-data"

    gum style \
        --foreground "$RED" --border-foreground "$RED" --border rounded \
        --width 60 --margin "0 2" --padding "1 2" \
        "This will remove container '${N8N_CONTAINER_NAME}'." \
        "" \
        "Data volume: ${volume}" \
        "(workflows, credentials, settings)"

    if ! gum confirm "Remove container '${N8N_CONTAINER_NAME}'?"; then
        warn "Cancelled."
        return
    fi

    local remove_volume=false
    gum confirm "Also remove data volume '${volume}'? (all workflows and credentials will be lost)" \
        && remove_volume=true || true

    gum spin --spinner dot --title "Removing container '${N8N_CONTAINER_NAME}'..." -- \
        docker rm -f "$N8N_CONTAINER_NAME" || true

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
    helm status "$N8N_HELM_RELEASE" -n "$N8N_NAMESPACE" &>/dev/null 2>&1
}

_k8s_ensure_namespace() {
    if kubectl get namespace "$N8N_NAMESPACE" &>/dev/null; then
        info "Namespace '${N8N_NAMESPACE}' already exists."
    else
        info "Creating namespace '${N8N_NAMESPACE}'..."
        kubectl create namespace "$N8N_NAMESPACE"
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

# -----------------------------------------------------------------------------
# Kubernetes — install / status / connect / uninstall
# -----------------------------------------------------------------------------

n8n_install_k8s() {
    header "Install n8n — Kubernetes"
    _k8s_check_cluster || return 0

    _ensure_helm_repo
    _prompt_encryption_key
    _prompt_db_backend

    local storage_size
    storage_size=$(gum input \
        --placeholder "2Gi" \
        --header "Persistent volume size (leave empty for '2Gi'):") || true
    storage_size="${storage_size:-2Gi}"

    local sc_input
    sc_input=$(gum input \
        --placeholder "leave empty for cluster default" \
        --header "StorageClass name (leave empty for cluster default):") || true

    _k8s_ensure_namespace

    local helm_args=(
        "$N8N_HELM_RELEASE" "$N8N_HELM_CHART"
        --namespace "$N8N_NAMESPACE"
        --set config.n8n.encryptionKey="$N8N_ENCRYPTION_KEY"
        --set persistence.enabled=true
        --set persistence.size="$storage_size"
        --wait --timeout 5m
    )

    [[ -n "$sc_input" ]] && helm_args+=(--set persistence.storageClass="$sc_input")

    if [[ "$N8N_DB_TYPE" == "postgresdb" ]]; then
        helm_args+=(
            --set config.database.type=postgresdb
            --set config.database.postgresdb.host="$N8N_PG_HOST"
            --set config.database.postgresdb.port="$N8N_PG_PORT"
            --set config.database.postgresdb.database="$N8N_PG_DATABASE"
            --set config.database.postgresdb.user="$N8N_PG_USER"
            --set config.database.postgresdb.password="$N8N_PG_PASSWORD"
        )
    fi

    if _k8s_detect_installed; then
        gum style \
            --foreground "$YELLOW" --border-foreground "$YELLOW" --border rounded \
            --align center --width 60 --margin "1 2" --padding "1 4" \
            "Release '${N8N_HELM_RELEASE}' already exists in '${N8N_NAMESPACE}'."

        local action
        action=$(gum choose \
            "Upgrade (apply new values)" \
            "Cancel" \
            --header "What would you like to do?") || true

        case "$action" in
            "Upgrade"*) ;;
            *) warn "Cancelled."; return ;;
        esac

        if ! gum spin --spinner dot --title "Upgrading n8n..." -- \
            helm upgrade "${helm_args[@]}"; then
            warn "Upgrade failed. Check 'helm status ${N8N_HELM_RELEASE} -n ${N8N_NAMESPACE}'."
            return
        fi
        success "n8n upgraded."
    else
        if ! gum spin --spinner dot --title "Installing n8n..." -- \
            helm install "${helm_args[@]}"; then
            warn "Install failed. Check 'helm status ${N8N_HELM_RELEASE} -n ${N8N_NAMESPACE}'."
            return
        fi
        success "n8n installed."
    fi

    echo ""
    gum style --foreground "$CYAN" \
        "Use 'connect' to open the web UI via port-forward." \
        "First login creates your admin account."
}

n8n_status_k8s() {
    header "Status — n8n Kubernetes"
    _k8s_check_cluster || return 0

    if ! _k8s_detect_installed; then
        warn "Release '${N8N_HELM_RELEASE}' not found in namespace '${N8N_NAMESPACE}'."
        return
    fi

    info "Helm release:"
    helm status "$N8N_HELM_RELEASE" -n "$N8N_NAMESPACE" 2>/dev/null | head -10
    echo ""

    info "Pods:"
    kubectl get pods -n "$N8N_NAMESPACE" --no-headers 2>/dev/null
    echo ""

    info "Services:"
    kubectl get svc -n "$N8N_NAMESPACE" --no-headers 2>/dev/null
    echo ""

    info "PersistentVolumeClaims:"
    kubectl get pvc -n "$N8N_NAMESPACE" --no-headers 2>/dev/null || true
}

n8n_connect_k8s() {
    header "Connect — n8n Kubernetes"
    _k8s_check_cluster || return 0

    if ! _k8s_detect_installed; then
        warn "Release '${N8N_HELM_RELEASE}' not found in namespace '${N8N_NAMESPACE}'."
        return
    fi

    local port_input
    port_input=$(gum input \
        --placeholder "$N8N_DEFAULT_PORT" \
        --header "Local port for port-forward (leave empty for ${N8N_DEFAULT_PORT}):") || true
    local port="${port_input:-$N8N_DEFAULT_PORT}"

    # Chart typically names the service <release>-n8n; fall back to <release>
    local svc="${N8N_HELM_RELEASE}-n8n"
    if ! kubectl get svc "$svc" -n "$N8N_NAMESPACE" &>/dev/null 2>&1; then
        svc="$N8N_HELM_RELEASE"
    fi

    gum style \
        --foreground "$CYAN" --border-foreground "$CYAN" --border rounded \
        --width 60 --margin "0 2" --padding "1 2" \
        "n8n Web UI → http://localhost:${port}" \
        "" \
        "First login creates your admin account." \
        "" \
        "Press Ctrl+C to stop the port-forward."

    kubectl -n "$N8N_NAMESPACE" port-forward "svc/${svc}" "${port}:5678"
}

n8n_uninstall_k8s() {
    header "Uninstall n8n — Kubernetes"
    _k8s_check_cluster || return 0

    if ! _k8s_detect_installed; then
        warn "Release '${N8N_HELM_RELEASE}' not found in namespace '${N8N_NAMESPACE}'."
        return
    fi

    gum style \
        --foreground "$RED" --border-foreground "$RED" --border rounded \
        --width 60 --margin "0 2" --padding "1 2" \
        "This will remove Helm release '${N8N_HELM_RELEASE}'" \
        "from namespace '${N8N_NAMESPACE}'." \
        "" \
        "PersistentVolumeClaims are NOT removed automatically by Helm." \
        "(workflows, credentials, and settings will survive in the PVC)" \
        "Delete manually to fully purge:" \
        "  kubectl delete pvc --all -n ${N8N_NAMESPACE}"

    if ! gum confirm "Uninstall n8n?"; then
        warn "Cancelled."
        return
    fi

    gum spin --spinner dot --title "Running helm uninstall..." -- \
        helm uninstall "$N8N_HELM_RELEASE" -n "$N8N_NAMESPACE" || true

    if gum confirm "Also delete namespace '${N8N_NAMESPACE}' (removes remaining PVCs too)?"; then
        gum spin --spinner dot --title "Deleting namespace '${N8N_NAMESPACE}'..." -- \
            kubectl delete namespace "$N8N_NAMESPACE" --ignore-not-found || true
        success "Namespace deleted."
    fi

    success "n8n uninstalled."
}

# -----------------------------------------------------------------------------
# Menus
# -----------------------------------------------------------------------------

_docker_menu() {
    local name_input
    name_input=$(gum input \
        --placeholder "n8n" \
        --header "Container name for this session (leave empty for 'n8n'):") || true
    N8N_CONTAINER_NAME="${name_input:-n8n}"

    while true; do
        header "n8n — Docker  (${N8N_CONTAINER_NAME})"

        local action
        action=$(gum choose \
            "install" \
            "status" \
            "connect" \
            "uninstall" \
            "← back" \
            --header "Select action:") || true

        case "$action" in
            "install")   n8n_install_docker ;;
            "status")    n8n_status_docker ;;
            "connect")   n8n_connect_docker ;;
            "uninstall") n8n_uninstall_docker ;;
            "← back"|"") return ;;
        esac
    done
}

_k8s_menu() {
    local ns_input
    ns_input=$(gum input \
        --placeholder "$N8N_NAMESPACE" \
        --header "Kubernetes namespace (leave empty for '${N8N_NAMESPACE}'):") || true
    N8N_NAMESPACE="${ns_input:-$N8N_NAMESPACE}"

    local release_input
    release_input=$(gum input \
        --placeholder "$N8N_HELM_RELEASE" \
        --header "Helm release name (leave empty for '${N8N_HELM_RELEASE}'):") || true
    N8N_HELM_RELEASE="${release_input:-$N8N_HELM_RELEASE}"

    while true; do
        header "n8n — ${TARGET_TYPE}: ${TARGET_CONTEXT} / ns: ${N8N_NAMESPACE} / release: ${N8N_HELM_RELEASE}"

        local action
        action=$(gum choose \
            "install" \
            "status" \
            "connect" \
            "uninstall" \
            "← back" \
            --header "Select action:") || true

        case "$action" in
            "install")   n8n_install_k8s ;;
            "status")    n8n_status_k8s ;;
            "connect")   n8n_connect_k8s ;;
            "uninstall") n8n_uninstall_k8s ;;
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
        "n8n" \
        "Workflow Automation  ·  Docker  ·  Kubernetes"

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
