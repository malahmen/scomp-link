#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# postgres.sh
# Interactive TUI for installing and managing PostgreSQL.
# Supports Docker (local container) and Kubernetes (Bitnami Helm chart).
# Called by init.sh — expects gum to be available.
# Hard dependencies: docker (Docker target) | kubectl + helm (K8s target).
# Soft dependency:   psql (connect feature — prompted if missing).
# Sources: scripts/cluster/cluster.sh for deployment target selection.
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

PG_NAMESPACE="postgres"
PG_HELM_RELEASE="postgresql"
PG_HELM_CHART="oci://registry-1.docker.io/bitnamicharts/postgresql"
PG_DEFAULT_PORT=5432
PG_DEFAULT_DB="app"
PG_DEFAULT_USER="app"
PG_DEFAULT_IMAGE_TAG="16"

# Colours
CYAN=212
RED=196
GREEN=82
YELLOW=220
BLUE=39

# Session state — populated by _docker_menu / _k8s_menu
PG_CONTAINER_NAME="postgres"
PG_IMAGE_TAG="$PG_DEFAULT_IMAGE_TAG"
PG_DB="$PG_DEFAULT_DB"
PG_USER="$PG_DEFAULT_USER"
PG_PASSWORD=""
PG_PORT=$PG_DEFAULT_PORT

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
        "helm is required to install PostgreSQL on Kubernetes."

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

_ensure_psql() {
    if command -v psql &>/dev/null; then
        info "psql: $(psql --version 2>/dev/null)"
        return 0
    fi
    warn "psql not found."
    warn "macOS: brew install libpq && brew link libpq --force"
    warn "Linux: apt install postgresql-client  /  dnf install postgresql"
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

_prompt_db_credentials() {
    PG_DB=$(gum input \
        --placeholder "$PG_DEFAULT_DB" \
        --header "Database name (leave empty for '${PG_DEFAULT_DB}'):") || true
    PG_DB="${PG_DB:-$PG_DEFAULT_DB}"

    PG_USER=$(gum input \
        --placeholder "$PG_DEFAULT_USER" \
        --header "Username (leave empty for '${PG_DEFAULT_USER}'):") || true
    PG_USER="${PG_USER:-$PG_DEFAULT_USER}"

    PG_PASSWORD=$(gum input \
        --placeholder "leave empty to auto-generate" \
        --password \
        --header "Password (leave empty to auto-generate):") || true

    if [[ -z "$PG_PASSWORD" ]]; then
        PG_PASSWORD=$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 20)
        gum style \
            --foreground "$YELLOW" --border-foreground "$YELLOW" --border rounded \
            --align center --width 60 --margin "1 0" --padding "0 4" \
            "Generated password: ${PG_PASSWORD}" \
            "Save this — it will not be shown again."
    fi
}

# -----------------------------------------------------------------------------
# Docker — install / status / connect / uninstall
# -----------------------------------------------------------------------------

_docker_container_exists()  { docker inspect "$1" &>/dev/null 2>&1; }
_docker_container_running() { [[ "$(docker inspect --format='{{.State.Running}}' "$1" 2>/dev/null)" == "true" ]]; }

postgres_install_docker() {
    header "Install PostgreSQL — Docker"

    PG_IMAGE_TAG=$(gum input \
        --placeholder "$PG_DEFAULT_IMAGE_TAG" \
        --header "PostgreSQL image tag (leave empty for '${PG_DEFAULT_IMAGE_TAG}'):") || true
    PG_IMAGE_TAG="${PG_IMAGE_TAG:-$PG_DEFAULT_IMAGE_TAG}"

    local port_input
    port_input=$(gum input \
        --placeholder "$PG_DEFAULT_PORT" \
        --header "Host port (leave empty for ${PG_DEFAULT_PORT}):") || true
    PG_PORT="${port_input:-$PG_DEFAULT_PORT}"

    _prompt_db_credentials

    local image="postgres:${PG_IMAGE_TAG}"
    local volume="${PG_CONTAINER_NAME}-data"

    if _docker_container_exists "$PG_CONTAINER_NAME"; then
        gum style \
            --foreground "$YELLOW" --border-foreground "$YELLOW" --border rounded \
            --align center --width 60 --margin "1 2" --padding "1 4" \
            "Container '${PG_CONTAINER_NAME}' already exists."

        local action
        action=$(gum choose \
            "Remove and recreate" \
            "Cancel" \
            --header "What would you like to do?") || true

        case "$action" in
            "Remove and recreate")
                gum spin --spinner dot --title "Removing existing container..." -- \
                    docker rm -f "$PG_CONTAINER_NAME" ;;
            *) warn "Cancelled."; return ;;
        esac
    fi

    gum spin --spinner dot --title "Pulling ${image}..." -- \
        docker pull "$image" \
        || error_exit "Failed to pull image ${image}."

    if ! docker run -d \
        --name "$PG_CONTAINER_NAME" \
        -e POSTGRES_DB="$PG_DB" \
        -e POSTGRES_USER="$PG_USER" \
        -e POSTGRES_PASSWORD="$PG_PASSWORD" \
        -p "${PG_PORT}:5432" \
        -v "${volume}:/var/lib/postgresql/data" \
        --restart unless-stopped \
        "$image" &>/dev/null; then
        error_exit "Failed to start container '${PG_CONTAINER_NAME}'."
    fi

    info "Waiting for PostgreSQL to accept connections..."
    local attempts=0
    until docker exec "$PG_CONTAINER_NAME" pg_isready -U "$PG_USER" &>/dev/null 2>&1; do
        attempts=$((attempts + 1))
        [[ $attempts -ge 30 ]] && {
            warn "Timed out waiting for readiness. Check: docker logs ${PG_CONTAINER_NAME}"
            break
        }
        sleep 1
    done

    gum style \
        --foreground "$GREEN" --border-foreground "$GREEN" --border rounded \
        --align center --width 60 --margin "1 2" --padding "1 4" \
        "PostgreSQL running" \
        "" \
        "Container:  ${PG_CONTAINER_NAME}" \
        "Image:      ${image}" \
        "Database:   ${PG_DB}" \
        "User:       ${PG_USER}" \
        "Port:       localhost:${PG_PORT}" \
        "Volume:     ${volume}"
}

postgres_status_docker() {
    header "PostgreSQL — Docker Status"

    if ! _docker_container_exists "$PG_CONTAINER_NAME"; then
        warn "Container '${PG_CONTAINER_NAME}' not found."
        return
    fi

    local status image ports
    status=$(docker inspect --format='{{.State.Status}}' "$PG_CONTAINER_NAME" 2>/dev/null)
    image=$(docker inspect --format='{{.Config.Image}}'  "$PG_CONTAINER_NAME" 2>/dev/null)
    ports=$(docker inspect \
        --format='{{range $k,$v := .NetworkSettings.Ports}}{{$k}} -> {{range $v}}{{.HostIP}}:{{.HostPort}}{{end}}  {{end}}' \
        "$PG_CONTAINER_NAME" 2>/dev/null)

    gum style \
        --foreground "$CYAN" --border-foreground "$CYAN" --border rounded \
        --align left --width 60 --margin "1 2" --padding "1 4" \
        "Container: ${PG_CONTAINER_NAME}" \
        "Status:    ${status}" \
        "Image:     ${image}" \
        "Ports:     ${ports}"

    echo ""
    gum confirm "Press Enter to continue" --affirmative "OK" --negative "" || true
}

postgres_connect_docker() {
    header "Connect — Docker (psql)"

    if ! _docker_container_exists "$PG_CONTAINER_NAME"; then
        warn "Container '${PG_CONTAINER_NAME}' not found."
        return
    fi
    if ! _docker_container_running "$PG_CONTAINER_NAME"; then
        warn "Container '${PG_CONTAINER_NAME}' is not running."
        return
    fi

    # Read user/db from the running container's env so we don't need to re-prompt.
    local env_vars user db
    env_vars=$(docker inspect --format='{{range .Config.Env}}{{println .}}{{end}}' "$PG_CONTAINER_NAME" 2>/dev/null)
    user=$(echo "$env_vars" | grep '^POSTGRES_USER='     | cut -d= -f2 || echo "postgres")
    db=$(echo   "$env_vars" | grep '^POSTGRES_DB='       | cut -d= -f2 || echo "$user")

    info "Connecting as ${user} → ${db}. Type \\q to exit."
    echo ""
    docker exec -it "$PG_CONTAINER_NAME" psql -U "$user" -d "$db"
}

postgres_uninstall_docker() {
    header "Uninstall PostgreSQL — Docker"

    if ! _docker_container_exists "$PG_CONTAINER_NAME"; then
        warn "Container '${PG_CONTAINER_NAME}' not found."
        return
    fi

    local volume="${PG_CONTAINER_NAME}-data"

    gum style \
        --foreground "$RED" --border-foreground "$RED" --border rounded \
        --width 60 --margin "0 2" --padding "1 2" \
        "This will remove container '${PG_CONTAINER_NAME}'." \
        "" \
        "Data volume: ${volume}"

    if ! gum confirm "Remove container '${PG_CONTAINER_NAME}'?"; then
        warn "Cancelled."
        return
    fi

    local remove_volume=false
    gum confirm "Also remove data volume '${volume}'? (all data will be lost)" \
        && remove_volume=true || true

    gum spin --spinner dot --title "Removing container '${PG_CONTAINER_NAME}'..." -- \
        docker rm -f "$PG_CONTAINER_NAME" || true

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
# Kubernetes — install / status / port-forward / connect / uninstall
# -----------------------------------------------------------------------------

_k8s_detect_installed() {
    helm status "$PG_HELM_RELEASE" -n "$PG_NAMESPACE" &>/dev/null 2>&1
}

_k8s_ensure_namespace() {
    if kubectl get namespace "$PG_NAMESPACE" &>/dev/null; then
        info "Namespace '${PG_NAMESPACE}' already exists."
    else
        info "Creating namespace '${PG_NAMESPACE}'..."
        kubectl create namespace "$PG_NAMESPACE"
    fi
}

# Switches to the selected context and verifies the cluster is reachable.
# Must be called at the start of every K8s operation.
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

postgres_install_k8s() {
    header "Install PostgreSQL — Kubernetes"
    _k8s_check_cluster || return 0
    _prompt_db_credentials

    local storage_size
    storage_size=$(gum input \
        --placeholder "8Gi" \
        --header "Persistent volume size (leave empty for '8Gi'):") || true
    storage_size="${storage_size:-8Gi}"

    _k8s_ensure_namespace

    # auth.postgresPassword = superuser; auth.username/password/database = app user
    local helm_args=(
        "$PG_HELM_RELEASE" "$PG_HELM_CHART"
        --namespace "$PG_NAMESPACE"
        --set auth.postgresPassword="$PG_PASSWORD"
        --set auth.username="$PG_USER"
        --set auth.password="$PG_PASSWORD"
        --set auth.database="$PG_DB"
        --set primary.persistence.size="$storage_size"
        --wait --timeout 5m
    )

    if _k8s_detect_installed; then
        gum style \
            --foreground "$YELLOW" --border-foreground "$YELLOW" --border rounded \
            --align center --width 60 --margin "1 2" --padding "1 4" \
            "Release '${PG_HELM_RELEASE}' already exists in '${PG_NAMESPACE}'."

        local action
        action=$(gum choose \
            "Upgrade (apply new values)" \
            "Cancel" \
            --header "What would you like to do?") || true

        case "$action" in
            "Upgrade"*) ;;
            *) warn "Cancelled."; return ;;
        esac

        gum spin --spinner dot --title "Upgrading PostgreSQL via Helm..." -- \
            helm upgrade "${helm_args[@]}" \
            || error_exit "Helm upgrade failed. Check: kubectl get pods -n ${PG_NAMESPACE}"
    else
        gum spin --spinner dot --title "Installing PostgreSQL via Helm (may take a few minutes)..." -- \
            helm install "${helm_args[@]}" \
            || error_exit "Helm install failed. Check: kubectl get pods -n ${PG_NAMESPACE}"
    fi

    gum style \
        --foreground "$GREEN" --border-foreground "$GREEN" --border rounded \
        --align center --width 60 --margin "1 2" --padding "1 4" \
        "PostgreSQL installed" \
        "" \
        "Release:    ${PG_HELM_RELEASE}" \
        "Namespace:  ${PG_NAMESPACE}" \
        "Database:   ${PG_DB}" \
        "User:       ${PG_USER}" \
        "" \
        "Use 'port-forward' or 'connect' from the menu to access it."
}

postgres_status_k8s() {
    header "PostgreSQL — Kubernetes Status"
    _k8s_check_cluster || return 0

    if ! _k8s_detect_installed; then
        warn "Release '${PG_HELM_RELEASE}' not found in namespace '${PG_NAMESPACE}'."
        return
    fi

    gum style --foreground "$CYAN" --bold "── Helm release ──"
    helm status "$PG_HELM_RELEASE" -n "$PG_NAMESPACE" 2>/dev/null || true

    echo ""
    gum style --foreground "$CYAN" --bold "── Pods ──"
    kubectl get pods -n "$PG_NAMESPACE" 2>/dev/null || true

    echo ""
    gum style --foreground "$CYAN" --bold "── Services ──"
    kubectl get svc -n "$PG_NAMESPACE" 2>/dev/null || true

    echo ""
    gum confirm "Press Enter to continue" --affirmative "OK" --negative "" || true
}

postgres_port_forward_k8s() {
    header "PostgreSQL — Port Forward"
    _k8s_check_cluster || return 0

    if ! _k8s_detect_installed; then
        warn "Release '${PG_HELM_RELEASE}' not found in namespace '${PG_NAMESPACE}'."
        return
    fi

    local port_input
    port_input=$(gum input \
        --placeholder "$PG_DEFAULT_PORT" \
        --header "Local port (leave empty for ${PG_DEFAULT_PORT}):") || true
    local port="${port_input:-$PG_DEFAULT_PORT}"

    info "Forwarding localhost:${port} → ${PG_HELM_RELEASE}:5432"
    info "Connect with: psql -h localhost -p ${port} -U <user> -d <db>"
    info "Press Ctrl+C to stop."
    echo ""

    kubectl -n "$PG_NAMESPACE" port-forward "svc/${PG_HELM_RELEASE}" "${port}:5432" || true
}

postgres_connect_k8s() {
    header "Connect — Kubernetes (psql)"
    _k8s_check_cluster || return 0

    if ! _k8s_detect_installed; then
        warn "Release '${PG_HELM_RELEASE}' not found in namespace '${PG_NAMESPACE}'."
        return
    fi

    if ! _ensure_psql; then
        warn "Install psql first, then use 'port-forward' to connect with any client."
        return
    fi

    local port_input
    port_input=$(gum input \
        --placeholder "$PG_DEFAULT_PORT" \
        --header "Local port for port-forward (leave empty for ${PG_DEFAULT_PORT}):") || true
    local port="${port_input:-$PG_DEFAULT_PORT}"

    local user
    user=$(gum input \
        --placeholder "$PG_DEFAULT_USER" \
        --header "Username (leave empty for '${PG_DEFAULT_USER}'):") || true
    user="${user:-$PG_DEFAULT_USER}"

    local db
    db=$(gum input \
        --placeholder "$PG_DEFAULT_DB" \
        --header "Database (leave empty for '${PG_DEFAULT_DB}'):") || true
    db="${db:-$PG_DEFAULT_DB}"

    info "Starting port-forward in background..."
    kubectl -n "$PG_NAMESPACE" port-forward "svc/${PG_HELM_RELEASE}" "${port}:5432" >/dev/null 2>&1 &
    local pf_pid=$!

    # Wait for the port-forward to bind before handing off to psql.
    local attempts=0
    until nc -z localhost "$port" 2>/dev/null; do
        attempts=$((attempts + 1))
        if [[ $attempts -ge 20 ]]; then
            warn "Port-forward did not become ready in time. Check kubectl connectivity."
            kill "$pf_pid" 2>/dev/null || true
            return
        fi
        sleep 0.5
    done

    info "Connected on localhost:${port}. Type \\q to exit."
    echo ""

    psql -h localhost -p "$port" -U "$user" -d "$db" || true

    kill "$pf_pid" 2>/dev/null || true
    wait "$pf_pid" 2>/dev/null || true
}

postgres_uninstall_k8s() {
    header "Uninstall PostgreSQL — Kubernetes"
    _k8s_check_cluster || return 0

    if ! _k8s_detect_installed; then
        warn "Release '${PG_HELM_RELEASE}' not found in namespace '${PG_NAMESPACE}'."
        return
    fi

    gum style \
        --foreground "$RED" --border-foreground "$RED" --border rounded \
        --width 60 --margin "0 2" --padding "1 2" \
        "This will remove Helm release '${PG_HELM_RELEASE}'" \
        "from namespace '${PG_NAMESPACE}'." \
        "" \
        "PersistentVolumeClaims are NOT removed automatically by Helm." \
        "Delete them manually to fully purge data:" \
        "  kubectl delete pvc --all -n ${PG_NAMESPACE}"

    if ! gum confirm "Uninstall PostgreSQL?"; then
        warn "Cancelled."
        return
    fi

    gum spin --spinner dot --title "Running helm uninstall..." -- \
        helm uninstall "$PG_HELM_RELEASE" -n "$PG_NAMESPACE" || true

    if gum confirm "Also delete namespace '${PG_NAMESPACE}' (removes remaining PVCs too)?"; then
        gum spin --spinner dot --title "Deleting namespace '${PG_NAMESPACE}'..." -- \
            kubectl delete namespace "$PG_NAMESPACE" --ignore-not-found || true
        success "Namespace deleted."
    fi

    success "PostgreSQL uninstalled."
}

# -----------------------------------------------------------------------------
# Menus
# -----------------------------------------------------------------------------

_docker_menu() {
    local name_input
    name_input=$(gum input \
        --placeholder "postgres" \
        --header "Container name for this session (leave empty for 'postgres'):") || true
    PG_CONTAINER_NAME="${name_input:-postgres}"

    while true; do
        header "PostgreSQL — Docker  (${PG_CONTAINER_NAME})"

        local action
        action=$(gum choose \
            "install" \
            "status" \
            "connect" \
            "uninstall" \
            "← back" \
            --header "Select action:") || true

        case "$action" in
            "install")    postgres_install_docker ;;
            "status")     postgres_status_docker ;;
            "connect")    postgres_connect_docker ;;
            "uninstall")  postgres_uninstall_docker ;;
            "← back"|"") return ;;
        esac
    done
}

_k8s_menu() {
    local ns_input
    ns_input=$(gum input \
        --placeholder "$PG_NAMESPACE" \
        --header "Kubernetes namespace for this session (leave empty for '${PG_NAMESPACE}'):") || true
    PG_NAMESPACE="${ns_input:-$PG_NAMESPACE}"

    local release_input
    release_input=$(gum input \
        --placeholder "$PG_HELM_RELEASE" \
        --header "Helm release name (leave empty for '${PG_HELM_RELEASE}'):") || true
    PG_HELM_RELEASE="${release_input:-$PG_HELM_RELEASE}"

    while true; do
        header "PostgreSQL — Kubernetes  (${TARGET_TYPE}: ${TARGET_CONTEXT} / ns: ${PG_NAMESPACE} / release: ${PG_HELM_RELEASE})"

        local action
        action=$(gum choose \
            "install" \
            "status" \
            "port-forward" \
            "connect" \
            "uninstall" \
            "← back" \
            --header "Select action:") || true

        case "$action" in
            "install")      postgres_install_k8s ;;
            "status")       postgres_status_k8s ;;
            "port-forward") postgres_port_forward_k8s ;;
            "connect")      postgres_connect_k8s ;;
            "uninstall")    postgres_uninstall_k8s ;;
            "← back"|"")   return ;;
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
        "PostgreSQL" \
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
