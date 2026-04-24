#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# mongodb.sh
# Interactive TUI for installing and managing MongoDB.
# Supports Docker (local container) and Kubernetes (Bitnami Helm chart).
# Called by init.sh — expects gum to be available.
# Hard dependencies: docker (Docker target) | kubectl + helm (K8s target).
# Soft dependency:   mongosh/mongo CLI (connect feature — prompted if missing).
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

MNG_NAMESPACE="mongodb"
MNG_HELM_RELEASE="mongodb"
MNG_HELM_CHART="oci://registry-1.docker.io/bitnamicharts/mongodb"
MNG_DEFAULT_PORT=27017
MNG_DEFAULT_DB="app"
MNG_DEFAULT_USER="app"
MNG_DEFAULT_ROOT_USER="root"
MNG_DEFAULT_IMAGE_TAG="7"

# Colours
CYAN=212
RED=196
GREEN=82
YELLOW=220
BLUE=39

# Session state — populated by _docker_menu / _k8s_menu
MNG_CONTAINER_NAME="mongodb"
MNG_IMAGE_TAG="$MNG_DEFAULT_IMAGE_TAG"
MNG_DB="$MNG_DEFAULT_DB"
MNG_USER="$MNG_DEFAULT_USER"
MNG_PASSWORD=""
MNG_ROOT_USER="$MNG_DEFAULT_ROOT_USER"
MNG_ROOT_PASSWORD=""
MNG_PORT=$MNG_DEFAULT_PORT

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
        "helm is required to install MongoDB on Kubernetes."

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

# Resolves the available MongoDB shell binary — mongosh (6.0+) preferred over legacy mongo.
_mongosh_bin() {
    if command -v mongosh &>/dev/null; then echo "mongosh"
    elif command -v mongo &>/dev/null; then echo "mongo"
    else echo ""
    fi
}

_ensure_mongosh() {
    local client
    client=$(_mongosh_bin)
    if [[ -n "$client" ]]; then
        info "mongo shell: ${client} ($(${client} --version 2>/dev/null | head -1))"
        return 0
    fi
    warn "No MongoDB shell found (mongosh or mongo)."
    warn "macOS: brew install mongosh"
    warn "Linux: https://www.mongodb.com/docs/mongodb-shell/install/"
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
    MNG_DB=$(gum input \
        --placeholder "$MNG_DEFAULT_DB" \
        --header "Database name (leave empty for '${MNG_DEFAULT_DB}'):") || true
    MNG_DB="${MNG_DB:-$MNG_DEFAULT_DB}"

    MNG_USER=$(gum input \
        --placeholder "$MNG_DEFAULT_USER" \
        --header "Username (leave empty for '${MNG_DEFAULT_USER}'):") || true
    MNG_USER="${MNG_USER:-$MNG_DEFAULT_USER}"

    MNG_PASSWORD=$(gum input \
        --placeholder "leave empty to auto-generate" \
        --password \
        --header "Password (leave empty to auto-generate):") || true

    if [[ -z "$MNG_PASSWORD" ]]; then
        MNG_PASSWORD=$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 20)
        gum style \
            --foreground "$YELLOW" --border-foreground "$YELLOW" --border rounded \
            --align center --width 60 --margin "1 0" --padding "0 4" \
            "Generated password: ${MNG_PASSWORD}" \
            "Save this — it will not be shown again."
    fi
}

_prompt_root_credentials() {
    MNG_ROOT_USER=$(gum input \
        --placeholder "$MNG_DEFAULT_ROOT_USER" \
        --header "Root username (leave empty for '${MNG_DEFAULT_ROOT_USER}'):") || true
    MNG_ROOT_USER="${MNG_ROOT_USER:-$MNG_DEFAULT_ROOT_USER}"

    MNG_ROOT_PASSWORD=$(gum input \
        --placeholder "leave empty to auto-generate" \
        --password \
        --header "Root password (leave empty to auto-generate):") || true

    if [[ -z "$MNG_ROOT_PASSWORD" ]]; then
        MNG_ROOT_PASSWORD=$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 20)
        gum style \
            --foreground "$YELLOW" --border-foreground "$YELLOW" --border rounded \
            --align center --width 60 --margin "1 0" --padding "0 4" \
            "Generated root password: ${MNG_ROOT_PASSWORD}" \
            "Save this — it will not be shown again."
    fi
}

# -----------------------------------------------------------------------------
# Docker — install / status / connect / uninstall
# -----------------------------------------------------------------------------

_docker_container_exists()  { docker inspect "$1" &>/dev/null 2>&1; }
_docker_container_running() { [[ "$(docker inspect --format='{{.State.Running}}' "$1" 2>/dev/null)" == "true" ]]; }

# Resolves the mongo shell binary available inside a running container.
_container_mongosh_bin() {
    local container="$1"
    if docker exec "$container" which mongosh &>/dev/null 2>&1; then echo "mongosh"
    elif docker exec "$container" which mongo &>/dev/null 2>&1; then echo "mongo"
    else echo ""
    fi
}

mongodb_install_docker() {
    header "Install MongoDB — Docker"

    MNG_IMAGE_TAG=$(gum input \
        --placeholder "$MNG_DEFAULT_IMAGE_TAG" \
        --header "MongoDB image tag (leave empty for '${MNG_DEFAULT_IMAGE_TAG}'):") || true
    MNG_IMAGE_TAG="${MNG_IMAGE_TAG:-$MNG_DEFAULT_IMAGE_TAG}"

    local port_input
    port_input=$(gum input \
        --placeholder "$MNG_DEFAULT_PORT" \
        --header "Host port (leave empty for ${MNG_DEFAULT_PORT}):") || true
    MNG_PORT="${port_input:-$MNG_DEFAULT_PORT}"

    _prompt_root_credentials
    _prompt_db_credentials

    local image="mongo:${MNG_IMAGE_TAG}"
    local volume="${MNG_CONTAINER_NAME}-data"

    if _docker_container_exists "$MNG_CONTAINER_NAME"; then
        gum style \
            --foreground "$YELLOW" --border-foreground "$YELLOW" --border rounded \
            --align center --width 60 --margin "1 2" --padding "1 4" \
            "Container '${MNG_CONTAINER_NAME}' already exists."

        local action
        action=$(gum choose \
            "Remove and recreate" \
            "Cancel" \
            --header "What would you like to do?") || true

        case "$action" in
            "Remove and recreate")
                gum spin --spinner dot --title "Removing existing container..." -- \
                    docker rm -f "$MNG_CONTAINER_NAME" ;;
            *) warn "Cancelled."; return ;;
        esac
    fi

    gum spin --spinner dot --title "Pulling ${image}..." -- \
        docker pull "$image" \
        || error_exit "Failed to pull image ${image}."

    if ! docker run -d \
        --name "$MNG_CONTAINER_NAME" \
        -e MONGO_INITDB_ROOT_USERNAME="$MNG_ROOT_USER" \
        -e MONGO_INITDB_ROOT_PASSWORD="$MNG_ROOT_PASSWORD" \
        -e MONGO_INITDB_DATABASE="$MNG_DB" \
        -p "${MNG_PORT}:27017" \
        -v "${volume}:/data/db" \
        --restart unless-stopped \
        "$image" &>/dev/null; then
        error_exit "Failed to start container '${MNG_CONTAINER_NAME}'."
    fi

    info "Waiting for MongoDB to accept connections..."
    local cli attempts=0
    until cli=$(_container_mongosh_bin "$MNG_CONTAINER_NAME") && [[ -n "$cli" ]] && \
        docker exec "$MNG_CONTAINER_NAME" \
            "$cli" --eval "db.adminCommand('ping')" --quiet \
            -u "$MNG_ROOT_USER" -p "$MNG_ROOT_PASSWORD" \
            --authenticationDatabase admin &>/dev/null 2>&1; do
        attempts=$((attempts + 1))
        if [[ $attempts -ge 40 ]]; then
            warn "Timed out waiting for readiness. Check: docker logs ${MNG_CONTAINER_NAME}"
            break
        fi
        sleep 1
    done

    gum style \
        --foreground "$GREEN" --border-foreground "$GREEN" --border rounded \
        --align center --width 60 --margin "1 2" --padding "1 4" \
        "MongoDB running" \
        "" \
        "Container:  ${MNG_CONTAINER_NAME}" \
        "Image:      ${image}" \
        "Database:   ${MNG_DB}" \
        "User:       ${MNG_USER}" \
        "Root user:  ${MNG_ROOT_USER}" \
        "Port:       localhost:${MNG_PORT}" \
        "Volume:     ${volume}"
}

mongodb_status_docker() {
    header "MongoDB — Docker Status"

    if ! _docker_container_exists "$MNG_CONTAINER_NAME"; then
        warn "Container '${MNG_CONTAINER_NAME}' not found."
        return
    fi

    local status image ports
    status=$(docker inspect --format='{{.State.Status}}' "$MNG_CONTAINER_NAME" 2>/dev/null)
    image=$(docker inspect --format='{{.Config.Image}}'  "$MNG_CONTAINER_NAME" 2>/dev/null)
    ports=$(docker inspect \
        --format='{{range $k,$v := .NetworkSettings.Ports}}{{$k}} -> {{range $v}}{{.HostIP}}:{{.HostPort}}{{end}}  {{end}}' \
        "$MNG_CONTAINER_NAME" 2>/dev/null)

    gum style \
        --foreground "$CYAN" --border-foreground "$CYAN" --border rounded \
        --align left --width 60 --margin "1 2" --padding "1 4" \
        "Container: ${MNG_CONTAINER_NAME}" \
        "Status:    ${status}" \
        "Image:     ${image}" \
        "Ports:     ${ports}"

    echo ""
    gum confirm "Press Enter to continue" --affirmative "OK" --negative "" || true
}

mongodb_connect_docker() {
    header "Connect — Docker (mongosh)"

    if ! _docker_container_exists "$MNG_CONTAINER_NAME"; then
        warn "Container '${MNG_CONTAINER_NAME}' not found."
        return
    fi
    if ! _docker_container_running "$MNG_CONTAINER_NAME"; then
        warn "Container '${MNG_CONTAINER_NAME}' is not running."
        return
    fi

    local cli
    cli=$(_container_mongosh_bin "$MNG_CONTAINER_NAME")
    if [[ -z "$cli" ]]; then
        warn "No mongo shell found in container '${MNG_CONTAINER_NAME}'."
        return
    fi

    local env_vars root_user root_pass db
    env_vars=$(docker inspect --format='{{range .Config.Env}}{{println .}}{{end}}' "$MNG_CONTAINER_NAME" 2>/dev/null)
    root_user=$(echo "$env_vars" | grep '^MONGO_INITDB_ROOT_USERNAME=' | cut -d= -f2 || echo "root")
    root_pass=$(echo "$env_vars" | grep '^MONGO_INITDB_ROOT_PASSWORD=' | cut -d= -f2 || echo "")
    db=$(echo        "$env_vars" | grep '^MONGO_INITDB_DATABASE='       | cut -d= -f2 || echo "admin")

    info "Connecting as ${root_user} → ${db}. Type exit or quit() to quit."
    echo ""

    docker exec -it "$MNG_CONTAINER_NAME" \
        "$cli" -u "$root_user" -p "$root_pass" \
        --authenticationDatabase admin "$db"
}

mongodb_uninstall_docker() {
    header "Uninstall MongoDB — Docker"

    if ! _docker_container_exists "$MNG_CONTAINER_NAME"; then
        warn "Container '${MNG_CONTAINER_NAME}' not found."
        return
    fi

    local volume="${MNG_CONTAINER_NAME}-data"

    gum style \
        --foreground "$RED" --border-foreground "$RED" --border rounded \
        --width 60 --margin "0 2" --padding "1 2" \
        "This will remove container '${MNG_CONTAINER_NAME}'." \
        "" \
        "Data volume: ${volume}"

    if ! gum confirm "Remove container '${MNG_CONTAINER_NAME}'?"; then
        warn "Cancelled."
        return
    fi

    local remove_volume=false
    gum confirm "Also remove data volume '${volume}'? (all data will be lost)" \
        && remove_volume=true || true

    gum spin --spinner dot --title "Removing container '${MNG_CONTAINER_NAME}'..." -- \
        docker rm -f "$MNG_CONTAINER_NAME" || true

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
    helm status "$MNG_HELM_RELEASE" -n "$MNG_NAMESPACE" &>/dev/null 2>&1
}

_k8s_ensure_namespace() {
    if kubectl get namespace "$MNG_NAMESPACE" &>/dev/null; then
        info "Namespace '${MNG_NAMESPACE}' already exists."
    else
        info "Creating namespace '${MNG_NAMESPACE}'..."
        kubectl create namespace "$MNG_NAMESPACE"
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

mongodb_install_k8s() {
    header "Install MongoDB — Kubernetes"
    _k8s_check_cluster || return 0

    _prompt_root_credentials
    _prompt_db_credentials

    local storage_size
    storage_size=$(gum input \
        --placeholder "8Gi" \
        --header "Persistent volume size (leave empty for '8Gi'):") || true
    storage_size="${storage_size:-8Gi}"

    _k8s_ensure_namespace

    # auth.rootUser/rootPassword = admin; auth.username/password/database = app user
    local helm_args=(
        "$MNG_HELM_RELEASE" "$MNG_HELM_CHART"
        --namespace "$MNG_NAMESPACE"
        --set auth.rootUser="$MNG_ROOT_USER"
        --set auth.rootPassword="$MNG_ROOT_PASSWORD"
        --set auth.username="$MNG_USER"
        --set auth.password="$MNG_PASSWORD"
        --set auth.database="$MNG_DB"
        --set persistence.size="$storage_size"
        --wait --timeout 5m
    )

    if _k8s_detect_installed; then
        gum style \
            --foreground "$YELLOW" --border-foreground "$YELLOW" --border rounded \
            --align center --width 60 --margin "1 2" --padding "1 4" \
            "Release '${MNG_HELM_RELEASE}' already exists in '${MNG_NAMESPACE}'."

        local action
        action=$(gum choose \
            "Upgrade (apply new values)" \
            "Cancel" \
            --header "What would you like to do?") || true

        case "$action" in
            "Upgrade"*) ;;
            *) warn "Cancelled."; return ;;
        esac

        gum spin --spinner dot --title "Upgrading MongoDB via Helm..." -- \
            helm upgrade "${helm_args[@]}" \
            || error_exit "Helm upgrade failed. Check: kubectl get pods -n ${MNG_NAMESPACE}"
    else
        gum spin --spinner dot --title "Installing MongoDB via Helm (may take a few minutes)..." -- \
            helm install "${helm_args[@]}" \
            || error_exit "Helm install failed. Check: kubectl get pods -n ${MNG_NAMESPACE}"
    fi

    gum style \
        --foreground "$GREEN" --border-foreground "$GREEN" --border rounded \
        --align center --width 60 --margin "1 2" --padding "1 4" \
        "MongoDB installed" \
        "" \
        "Release:    ${MNG_HELM_RELEASE}" \
        "Namespace:  ${MNG_NAMESPACE}" \
        "Database:   ${MNG_DB}" \
        "User:       ${MNG_USER}" \
        "Root user:  ${MNG_ROOT_USER}" \
        "" \
        "Use 'port-forward' or 'connect' from the menu to access it."
}

mongodb_status_k8s() {
    header "MongoDB — Kubernetes Status"
    _k8s_check_cluster || return 0

    if ! _k8s_detect_installed; then
        warn "Release '${MNG_HELM_RELEASE}' not found in namespace '${MNG_NAMESPACE}'."
        return
    fi

    gum style --foreground "$CYAN" --bold "── Helm release ──"
    helm status "$MNG_HELM_RELEASE" -n "$MNG_NAMESPACE" 2>/dev/null || true

    echo ""
    gum style --foreground "$CYAN" --bold "── Pods ──"
    kubectl get pods -n "$MNG_NAMESPACE" 2>/dev/null || true

    echo ""
    gum style --foreground "$CYAN" --bold "── Services ──"
    kubectl get svc -n "$MNG_NAMESPACE" 2>/dev/null || true

    echo ""
    gum confirm "Press Enter to continue" --affirmative "OK" --negative "" || true
}

mongodb_port_forward_k8s() {
    header "MongoDB — Port Forward"
    _k8s_check_cluster || return 0

    if ! _k8s_detect_installed; then
        warn "Release '${MNG_HELM_RELEASE}' not found in namespace '${MNG_NAMESPACE}'."
        return
    fi

    local port_input
    port_input=$(gum input \
        --placeholder "$MNG_DEFAULT_PORT" \
        --header "Local port (leave empty for ${MNG_DEFAULT_PORT}):") || true
    local port="${port_input:-$MNG_DEFAULT_PORT}"

    info "Forwarding localhost:${port} → ${MNG_HELM_RELEASE}:27017"
    info "Connect with: mongosh --port ${port} -u <user> --authenticationDatabase admin"
    info "Press Ctrl+C to stop."
    echo ""

    kubectl -n "$MNG_NAMESPACE" port-forward "svc/${MNG_HELM_RELEASE}" "${port}:27017" || true
}

mongodb_connect_k8s() {
    header "Connect — Kubernetes (mongosh)"
    _k8s_check_cluster || return 0

    if ! _k8s_detect_installed; then
        warn "Release '${MNG_HELM_RELEASE}' not found in namespace '${MNG_NAMESPACE}'."
        return
    fi

    if ! _ensure_mongosh; then
        warn "Install mongosh first, then use 'port-forward' to connect."
        return
    fi

    local port_input
    port_input=$(gum input \
        --placeholder "$MNG_DEFAULT_PORT" \
        --header "Local port for port-forward (leave empty for ${MNG_DEFAULT_PORT}):") || true
    local port="${port_input:-$MNG_DEFAULT_PORT}"

    local user
    user=$(gum input \
        --placeholder "$MNG_DEFAULT_USER" \
        --header "Username (leave empty for '${MNG_DEFAULT_USER}'):") || true
    user="${user:-$MNG_DEFAULT_USER}"

    local db
    db=$(gum input \
        --placeholder "$MNG_DEFAULT_DB" \
        --header "Database (leave empty for '${MNG_DEFAULT_DB}'):") || true
    db="${db:-$MNG_DEFAULT_DB}"

    info "Starting port-forward in background..."
    kubectl -n "$MNG_NAMESPACE" port-forward "svc/${MNG_HELM_RELEASE}" "${port}:27017" >/dev/null 2>&1 &
    local pf_pid=$!

    local attempts=0
    until nc -z 127.0.0.1 "$port" 2>/dev/null; do
        attempts=$((attempts + 1))
        if [[ $attempts -ge 20 ]]; then
            warn "Port-forward did not become ready in time. Check kubectl connectivity."
            kill "$pf_pid" 2>/dev/null || true
            return
        fi
        sleep 0.5
    done

    local client
    client=$(_mongosh_bin)

    info "Connected on 127.0.0.1:${port}. Type exit or quit() to quit."
    echo ""

    "$client" --host 127.0.0.1 --port "$port" \
        -u "$user" --authenticationDatabase admin "$db" || true

    kill "$pf_pid" 2>/dev/null || true
    wait "$pf_pid" 2>/dev/null || true
}

mongodb_uninstall_k8s() {
    header "Uninstall MongoDB — Kubernetes"
    _k8s_check_cluster || return 0

    if ! _k8s_detect_installed; then
        warn "Release '${MNG_HELM_RELEASE}' not found in namespace '${MNG_NAMESPACE}'."
        return
    fi

    gum style \
        --foreground "$RED" --border-foreground "$RED" --border rounded \
        --width 60 --margin "0 2" --padding "1 2" \
        "This will remove Helm release '${MNG_HELM_RELEASE}'" \
        "from namespace '${MNG_NAMESPACE}'." \
        "" \
        "PersistentVolumeClaims are NOT removed automatically by Helm." \
        "Delete them manually to fully purge data:" \
        "  kubectl delete pvc --all -n ${MNG_NAMESPACE}"

    if ! gum confirm "Uninstall MongoDB?"; then
        warn "Cancelled."
        return
    fi

    gum spin --spinner dot --title "Running helm uninstall..." -- \
        helm uninstall "$MNG_HELM_RELEASE" -n "$MNG_NAMESPACE" || true

    if gum confirm "Also delete namespace '${MNG_NAMESPACE}' (removes remaining PVCs too)?"; then
        gum spin --spinner dot --title "Deleting namespace '${MNG_NAMESPACE}'..." -- \
            kubectl delete namespace "$MNG_NAMESPACE" --ignore-not-found || true
        success "Namespace deleted."
    fi

    success "MongoDB uninstalled."
}

# -----------------------------------------------------------------------------
# Menus
# -----------------------------------------------------------------------------

_docker_menu() {
    local name_input
    name_input=$(gum input \
        --placeholder "mongodb" \
        --header "Container name for this session (leave empty for 'mongodb'):") || true
    MNG_CONTAINER_NAME="${name_input:-mongodb}"

    while true; do
        header "MongoDB — Docker  (${MNG_CONTAINER_NAME})"

        local action
        action=$(gum choose \
            "install" \
            "status" \
            "connect" \
            "uninstall" \
            "← back" \
            --header "Select action:") || true

        case "$action" in
            "install")    mongodb_install_docker ;;
            "status")     mongodb_status_docker ;;
            "connect")    mongodb_connect_docker ;;
            "uninstall")  mongodb_uninstall_docker ;;
            "← back"|"") return ;;
        esac
    done
}

_k8s_menu() {
    local ns_input
    ns_input=$(gum input \
        --placeholder "$MNG_NAMESPACE" \
        --header "Kubernetes namespace for this session (leave empty for '${MNG_NAMESPACE}'):") || true
    MNG_NAMESPACE="${ns_input:-$MNG_NAMESPACE}"

    local release_input
    release_input=$(gum input \
        --placeholder "$MNG_HELM_RELEASE" \
        --header "Helm release name (leave empty for '${MNG_HELM_RELEASE}'):") || true
    MNG_HELM_RELEASE="${release_input:-$MNG_HELM_RELEASE}"

    while true; do
        header "MongoDB — Kubernetes  (${TARGET_TYPE}: ${TARGET_CONTEXT} / ns: ${MNG_NAMESPACE} / release: ${MNG_HELM_RELEASE})"

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
            "install")      mongodb_install_k8s ;;
            "status")       mongodb_status_k8s ;;
            "port-forward") mongodb_port_forward_k8s ;;
            "connect")      mongodb_connect_k8s ;;
            "uninstall")    mongodb_uninstall_k8s ;;
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
        "MongoDB" \
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
