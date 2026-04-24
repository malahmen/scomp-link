#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# mariadb.sh
# Interactive TUI for installing and managing MariaDB.
# Supports Docker (local container) and Kubernetes (Bitnami Helm chart).
# Called by init.sh — expects gum to be available.
# Hard dependencies: docker (Docker target) | kubectl + helm (K8s target).
# Soft dependency:   mariadb/mysql CLI (connect feature — prompted if missing).
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

MDB_NAMESPACE="mariadb"
MDB_HELM_RELEASE="mariadb"
MDB_HELM_CHART="oci://registry-1.docker.io/bitnamicharts/mariadb"
MDB_DEFAULT_PORT=3306
MDB_DEFAULT_DB="app"
MDB_DEFAULT_USER="app"
MDB_DEFAULT_IMAGE_TAG="11"

# Colours
CYAN=212
RED=196
GREEN=82
YELLOW=220
BLUE=39

# Session state — populated by _docker_menu / _k8s_menu
MDB_CONTAINER_NAME="mariadb"
MDB_IMAGE_TAG="$MDB_DEFAULT_IMAGE_TAG"
MDB_DB="$MDB_DEFAULT_DB"
MDB_USER="$MDB_DEFAULT_USER"
MDB_PASSWORD=""
MDB_ROOT_PASSWORD=""
MDB_PORT=$MDB_DEFAULT_PORT

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
        "helm is required to install MariaDB on Kubernetes."

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

# Resolves the available MariaDB/MySQL CLI binary, prefers mariadb over mysql.
_mysql_client() {
    if command -v mariadb &>/dev/null; then
        echo "mariadb"
    elif command -v mysql &>/dev/null; then
        echo "mysql"
    else
        echo ""
    fi
}

_ensure_mysql_client() {
    local client
    client=$(_mysql_client)
    if [[ -n "$client" ]]; then
        info "mysql client: ${client} ($(${client} --version 2>/dev/null | head -1))"
        return 0
    fi
    warn "No MariaDB/MySQL client found (mariadb or mysql)."
    warn "macOS: brew install mariadb-client"
    warn "Linux: apt install mariadb-client  /  dnf install mariadb"
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
    MDB_DB=$(gum input \
        --placeholder "$MDB_DEFAULT_DB" \
        --header "Database name (leave empty for '${MDB_DEFAULT_DB}'):") || true
    MDB_DB="${MDB_DB:-$MDB_DEFAULT_DB}"

    MDB_USER=$(gum input \
        --placeholder "$MDB_DEFAULT_USER" \
        --header "Username (leave empty for '${MDB_DEFAULT_USER}'):") || true
    MDB_USER="${MDB_USER:-$MDB_DEFAULT_USER}"

    MDB_PASSWORD=$(gum input \
        --placeholder "leave empty to auto-generate" \
        --password \
        --header "Password (leave empty to auto-generate):") || true

    if [[ -z "$MDB_PASSWORD" ]]; then
        MDB_PASSWORD=$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 20)
        gum style \
            --foreground "$YELLOW" --border-foreground "$YELLOW" --border rounded \
            --align center --width 60 --margin "1 0" --padding "0 4" \
            "Generated password: ${MDB_PASSWORD}" \
            "Save this — it will not be shown again."
    fi
}

_prompt_root_password() {
    MDB_ROOT_PASSWORD=$(gum input \
        --placeholder "leave empty to auto-generate" \
        --password \
        --header "Root password (leave empty to auto-generate):") || true

    if [[ -z "$MDB_ROOT_PASSWORD" ]]; then
        MDB_ROOT_PASSWORD=$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 20)
        gum style \
            --foreground "$YELLOW" --border-foreground "$YELLOW" --border rounded \
            --align center --width 60 --margin "1 0" --padding "0 4" \
            "Generated root password: ${MDB_ROOT_PASSWORD}" \
            "Save this — it will not be shown again."
    fi
}

# -----------------------------------------------------------------------------
# Docker — install / status / connect / uninstall
# -----------------------------------------------------------------------------

_docker_container_exists()  { docker inspect "$1" &>/dev/null 2>&1; }
_docker_container_running() { [[ "$(docker inspect --format='{{.State.Running}}' "$1" 2>/dev/null)" == "true" ]]; }

mariadb_install_docker() {
    header "Install MariaDB — Docker"

    MDB_IMAGE_TAG=$(gum input \
        --placeholder "$MDB_DEFAULT_IMAGE_TAG" \
        --header "MariaDB image tag (leave empty for '${MDB_DEFAULT_IMAGE_TAG}'):") || true
    MDB_IMAGE_TAG="${MDB_IMAGE_TAG:-$MDB_DEFAULT_IMAGE_TAG}"

    local port_input
    port_input=$(gum input \
        --placeholder "$MDB_DEFAULT_PORT" \
        --header "Host port (leave empty for ${MDB_DEFAULT_PORT}):") || true
    MDB_PORT="${port_input:-$MDB_DEFAULT_PORT}"

    _prompt_root_password
    _prompt_db_credentials

    local image="mariadb:${MDB_IMAGE_TAG}"
    local volume="${MDB_CONTAINER_NAME}-data"

    if _docker_container_exists "$MDB_CONTAINER_NAME"; then
        gum style \
            --foreground "$YELLOW" --border-foreground "$YELLOW" --border rounded \
            --align center --width 60 --margin "1 2" --padding "1 4" \
            "Container '${MDB_CONTAINER_NAME}' already exists."

        local action
        action=$(gum choose \
            "Remove and recreate" \
            "Cancel" \
            --header "What would you like to do?") || true

        case "$action" in
            "Remove and recreate")
                gum spin --spinner dot --title "Removing existing container..." -- \
                    docker rm -f "$MDB_CONTAINER_NAME" ;;
            *) warn "Cancelled."; return ;;
        esac
    fi

    gum spin --spinner dot --title "Pulling ${image}..." -- \
        docker pull "$image" \
        || error_exit "Failed to pull image ${image}."

    if ! docker run -d \
        --name "$MDB_CONTAINER_NAME" \
        -e MARIADB_ROOT_PASSWORD="$MDB_ROOT_PASSWORD" \
        -e MARIADB_DATABASE="$MDB_DB" \
        -e MARIADB_USER="$MDB_USER" \
        -e MARIADB_PASSWORD="$MDB_PASSWORD" \
        -p "${MDB_PORT}:3306" \
        -v "${volume}:/var/lib/mysql" \
        --restart unless-stopped \
        "$image" &>/dev/null; then
        error_exit "Failed to start container '${MDB_CONTAINER_NAME}'."
    fi

    info "Waiting for MariaDB to accept connections..."
    local attempts=0
    until docker exec "$MDB_CONTAINER_NAME" \
        mariadb-admin ping -uroot -p"${MDB_ROOT_PASSWORD}" --silent &>/dev/null 2>&1; do
        attempts=$((attempts + 1))
        if [[ $attempts -ge 40 ]]; then
            warn "Timed out waiting for readiness. Check: docker logs ${MDB_CONTAINER_NAME}"
            break
        fi
        sleep 1
    done

    gum style \
        --foreground "$GREEN" --border-foreground "$GREEN" --border rounded \
        --align center --width 60 --margin "1 2" --padding "1 4" \
        "MariaDB running" \
        "" \
        "Container:  ${MDB_CONTAINER_NAME}" \
        "Image:      ${image}" \
        "Database:   ${MDB_DB}" \
        "User:       ${MDB_USER}" \
        "Port:       localhost:${MDB_PORT}" \
        "Volume:     ${volume}"
}

mariadb_status_docker() {
    header "MariaDB — Docker Status"

    if ! _docker_container_exists "$MDB_CONTAINER_NAME"; then
        warn "Container '${MDB_CONTAINER_NAME}' not found."
        return
    fi

    local status image ports
    status=$(docker inspect --format='{{.State.Status}}' "$MDB_CONTAINER_NAME" 2>/dev/null)
    image=$(docker inspect --format='{{.Config.Image}}'  "$MDB_CONTAINER_NAME" 2>/dev/null)
    ports=$(docker inspect \
        --format='{{range $k,$v := .NetworkSettings.Ports}}{{$k}} -> {{range $v}}{{.HostIP}}:{{.HostPort}}{{end}}  {{end}}' \
        "$MDB_CONTAINER_NAME" 2>/dev/null)

    gum style \
        --foreground "$CYAN" --border-foreground "$CYAN" --border rounded \
        --align left --width 60 --margin "1 2" --padding "1 4" \
        "Container: ${MDB_CONTAINER_NAME}" \
        "Status:    ${status}" \
        "Image:     ${image}" \
        "Ports:     ${ports}"

    echo ""
    gum confirm "Press Enter to continue" --affirmative "OK" --negative "" || true
}

mariadb_connect_docker() {
    header "Connect — Docker (mariadb)"

    if ! _docker_container_exists "$MDB_CONTAINER_NAME"; then
        warn "Container '${MDB_CONTAINER_NAME}' not found."
        return
    fi
    if ! _docker_container_running "$MDB_CONTAINER_NAME"; then
        warn "Container '${MDB_CONTAINER_NAME}' is not running."
        return
    fi

    # Read user/db/password from the running container's env.
    local env_vars user db password
    env_vars=$(docker inspect --format='{{range .Config.Env}}{{println .}}{{end}}' "$MDB_CONTAINER_NAME" 2>/dev/null)
    user=$(echo     "$env_vars" | grep '^MARIADB_USER='     | cut -d= -f2 || echo "root")
    db=$(echo       "$env_vars" | grep '^MARIADB_DATABASE=' | cut -d= -f2 || echo "")
    password=$(echo "$env_vars" | grep '^MARIADB_PASSWORD=' | cut -d= -f2 || echo "")

    info "Connecting as ${user}${db:+ → ${db}}. Type exit or \\q to quit."
    echo ""

    # mariadb is preferred; the official image ships both mariadb and mysql.
    local cli
    if docker exec "$MDB_CONTAINER_NAME" which mariadb &>/dev/null 2>&1; then
        cli="mariadb"
    else
        cli="mysql"
    fi

    docker exec -it "$MDB_CONTAINER_NAME" \
        "$cli" -u"$user" ${password:+-p"$password"} ${db:+"$db"}
}

mariadb_uninstall_docker() {
    header "Uninstall MariaDB — Docker"

    if ! _docker_container_exists "$MDB_CONTAINER_NAME"; then
        warn "Container '${MDB_CONTAINER_NAME}' not found."
        return
    fi

    local volume="${MDB_CONTAINER_NAME}-data"

    gum style \
        --foreground "$RED" --border-foreground "$RED" --border rounded \
        --width 60 --margin "0 2" --padding "1 2" \
        "This will remove container '${MDB_CONTAINER_NAME}'." \
        "" \
        "Data volume: ${volume}"

    if ! gum confirm "Remove container '${MDB_CONTAINER_NAME}'?"; then
        warn "Cancelled."
        return
    fi

    local remove_volume=false
    gum confirm "Also remove data volume '${volume}'? (all data will be lost)" \
        && remove_volume=true || true

    gum spin --spinner dot --title "Removing container '${MDB_CONTAINER_NAME}'..." -- \
        docker rm -f "$MDB_CONTAINER_NAME" || true

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
    helm status "$MDB_HELM_RELEASE" -n "$MDB_NAMESPACE" &>/dev/null 2>&1
}

_k8s_ensure_namespace() {
    if kubectl get namespace "$MDB_NAMESPACE" &>/dev/null; then
        info "Namespace '${MDB_NAMESPACE}' already exists."
    else
        info "Creating namespace '${MDB_NAMESPACE}'..."
        kubectl create namespace "$MDB_NAMESPACE"
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

mariadb_install_k8s() {
    header "Install MariaDB — Kubernetes"
    _k8s_check_cluster || return 0

    _prompt_root_password
    _prompt_db_credentials

    local storage_size
    storage_size=$(gum input \
        --placeholder "8Gi" \
        --header "Persistent volume size (leave empty for '8Gi'):") || true
    storage_size="${storage_size:-8Gi}"

    _k8s_ensure_namespace

    # auth.rootPassword = MariaDB root; auth.username/password/database = app user
    local helm_args=(
        "$MDB_HELM_RELEASE" "$MDB_HELM_CHART"
        --namespace "$MDB_NAMESPACE"
        --set auth.rootPassword="$MDB_ROOT_PASSWORD"
        --set auth.username="$MDB_USER"
        --set auth.password="$MDB_PASSWORD"
        --set auth.database="$MDB_DB"
        --set primary.persistence.size="$storage_size"
        --wait --timeout 5m
    )

    if _k8s_detect_installed; then
        gum style \
            --foreground "$YELLOW" --border-foreground "$YELLOW" --border rounded \
            --align center --width 60 --margin "1 2" --padding "1 4" \
            "Release '${MDB_HELM_RELEASE}' already exists in '${MDB_NAMESPACE}'."

        local action
        action=$(gum choose \
            "Upgrade (apply new values)" \
            "Cancel" \
            --header "What would you like to do?") || true

        case "$action" in
            "Upgrade"*) ;;
            *) warn "Cancelled."; return ;;
        esac

        gum spin --spinner dot --title "Upgrading MariaDB via Helm..." -- \
            helm upgrade "${helm_args[@]}" \
            || error_exit "Helm upgrade failed. Check: kubectl get pods -n ${MDB_NAMESPACE}"
    else
        gum spin --spinner dot --title "Installing MariaDB via Helm (may take a few minutes)..." -- \
            helm install "${helm_args[@]}" \
            || error_exit "Helm install failed. Check: kubectl get pods -n ${MDB_NAMESPACE}"
    fi

    gum style \
        --foreground "$GREEN" --border-foreground "$GREEN" --border rounded \
        --align center --width 60 --margin "1 2" --padding "1 4" \
        "MariaDB installed" \
        "" \
        "Release:    ${MDB_HELM_RELEASE}" \
        "Namespace:  ${MDB_NAMESPACE}" \
        "Database:   ${MDB_DB}" \
        "User:       ${MDB_USER}" \
        "" \
        "Use 'port-forward' or 'connect' from the menu to access it."
}

mariadb_status_k8s() {
    header "MariaDB — Kubernetes Status"
    _k8s_check_cluster || return 0

    if ! _k8s_detect_installed; then
        warn "Release '${MDB_HELM_RELEASE}' not found in namespace '${MDB_NAMESPACE}'."
        return
    fi

    gum style --foreground "$CYAN" --bold "── Helm release ──"
    helm status "$MDB_HELM_RELEASE" -n "$MDB_NAMESPACE" 2>/dev/null || true

    echo ""
    gum style --foreground "$CYAN" --bold "── Pods ──"
    kubectl get pods -n "$MDB_NAMESPACE" 2>/dev/null || true

    echo ""
    gum style --foreground "$CYAN" --bold "── Services ──"
    kubectl get svc -n "$MDB_NAMESPACE" 2>/dev/null || true

    echo ""
    gum confirm "Press Enter to continue" --affirmative "OK" --negative "" || true
}

mariadb_port_forward_k8s() {
    header "MariaDB — Port Forward"
    _k8s_check_cluster || return 0

    if ! _k8s_detect_installed; then
        warn "Release '${MDB_HELM_RELEASE}' not found in namespace '${MDB_NAMESPACE}'."
        return
    fi

    local port_input
    port_input=$(gum input \
        --placeholder "$MDB_DEFAULT_PORT" \
        --header "Local port (leave empty for ${MDB_DEFAULT_PORT}):") || true
    local port="${port_input:-$MDB_DEFAULT_PORT}"

    info "Forwarding localhost:${port} → ${MDB_HELM_RELEASE}:3306"
    info "Connect with: mariadb -h 127.0.0.1 -P ${port} -u <user> -p <db>"
    info "Press Ctrl+C to stop."
    echo ""

    kubectl -n "$MDB_NAMESPACE" port-forward "svc/${MDB_HELM_RELEASE}" "${port}:3306" || true
}

mariadb_connect_k8s() {
    header "Connect — Kubernetes (mariadb)"
    _k8s_check_cluster || return 0

    if ! _k8s_detect_installed; then
        warn "Release '${MDB_HELM_RELEASE}' not found in namespace '${MDB_NAMESPACE}'."
        return
    fi

    if ! _ensure_mysql_client; then
        warn "Install a MariaDB/MySQL client first, then use 'port-forward' to connect."
        return
    fi

    local port_input
    port_input=$(gum input \
        --placeholder "$MDB_DEFAULT_PORT" \
        --header "Local port for port-forward (leave empty for ${MDB_DEFAULT_PORT}):") || true
    local port="${port_input:-$MDB_DEFAULT_PORT}"

    local user
    user=$(gum input \
        --placeholder "$MDB_DEFAULT_USER" \
        --header "Username (leave empty for '${MDB_DEFAULT_USER}'):") || true
    user="${user:-$MDB_DEFAULT_USER}"

    local db
    db=$(gum input \
        --placeholder "$MDB_DEFAULT_DB" \
        --header "Database (leave empty for '${MDB_DEFAULT_DB}'):") || true
    db="${db:-$MDB_DEFAULT_DB}"

    info "Starting port-forward in background..."
    kubectl -n "$MDB_NAMESPACE" port-forward "svc/${MDB_HELM_RELEASE}" "${port}:3306" >/dev/null 2>&1 &
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
    client=$(_mysql_client)

    info "Connected on 127.0.0.1:${port}. Type exit or \\q to quit."
    echo ""

    # -h 127.0.0.1 forces TCP; localhost would try a Unix socket which won't exist locally.
    "$client" -h 127.0.0.1 -P "$port" -u "$user" -p "$db" || true

    kill "$pf_pid" 2>/dev/null || true
    wait "$pf_pid" 2>/dev/null || true
}

mariadb_uninstall_k8s() {
    header "Uninstall MariaDB — Kubernetes"
    _k8s_check_cluster || return 0

    if ! _k8s_detect_installed; then
        warn "Release '${MDB_HELM_RELEASE}' not found in namespace '${MDB_NAMESPACE}'."
        return
    fi

    gum style \
        --foreground "$RED" --border-foreground "$RED" --border rounded \
        --width 60 --margin "0 2" --padding "1 2" \
        "This will remove Helm release '${MDB_HELM_RELEASE}'" \
        "from namespace '${MDB_NAMESPACE}'." \
        "" \
        "PersistentVolumeClaims are NOT removed automatically by Helm." \
        "Delete them manually to fully purge data:" \
        "  kubectl delete pvc --all -n ${MDB_NAMESPACE}"

    if ! gum confirm "Uninstall MariaDB?"; then
        warn "Cancelled."
        return
    fi

    gum spin --spinner dot --title "Running helm uninstall..." -- \
        helm uninstall "$MDB_HELM_RELEASE" -n "$MDB_NAMESPACE" || true

    if gum confirm "Also delete namespace '${MDB_NAMESPACE}' (removes remaining PVCs too)?"; then
        gum spin --spinner dot --title "Deleting namespace '${MDB_NAMESPACE}'..." -- \
            kubectl delete namespace "$MDB_NAMESPACE" --ignore-not-found || true
        success "Namespace deleted."
    fi

    success "MariaDB uninstalled."
}

# -----------------------------------------------------------------------------
# Menus
# -----------------------------------------------------------------------------

_docker_menu() {
    local name_input
    name_input=$(gum input \
        --placeholder "mariadb" \
        --header "Container name for this session (leave empty for 'mariadb'):") || true
    MDB_CONTAINER_NAME="${name_input:-mariadb}"

    while true; do
        header "MariaDB — Docker  (${MDB_CONTAINER_NAME})"

        local action
        action=$(gum choose \
            "install" \
            "status" \
            "connect" \
            "uninstall" \
            "← back" \
            --header "Select action:") || true

        case "$action" in
            "install")    mariadb_install_docker ;;
            "status")     mariadb_status_docker ;;
            "connect")    mariadb_connect_docker ;;
            "uninstall")  mariadb_uninstall_docker ;;
            "← back"|"") return ;;
        esac
    done
}

_k8s_menu() {
    local ns_input
    ns_input=$(gum input \
        --placeholder "$MDB_NAMESPACE" \
        --header "Kubernetes namespace for this session (leave empty for '${MDB_NAMESPACE}'):") || true
    MDB_NAMESPACE="${ns_input:-$MDB_NAMESPACE}"

    local release_input
    release_input=$(gum input \
        --placeholder "$MDB_HELM_RELEASE" \
        --header "Helm release name (leave empty for '${MDB_HELM_RELEASE}'):") || true
    MDB_HELM_RELEASE="${release_input:-$MDB_HELM_RELEASE}"

    while true; do
        header "MariaDB — Kubernetes  (${TARGET_TYPE}: ${TARGET_CONTEXT} / ns: ${MDB_NAMESPACE} / release: ${MDB_HELM_RELEASE})"

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
            "install")      mariadb_install_k8s ;;
            "status")       mariadb_status_k8s ;;
            "port-forward") mariadb_port_forward_k8s ;;
            "connect")      mariadb_connect_k8s ;;
            "uninstall")    mariadb_uninstall_k8s ;;
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
        "MariaDB" \
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
