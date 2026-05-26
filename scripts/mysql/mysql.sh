#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# mysql.sh
# Interactive TUI for installing and managing MySQL.
# Supports Docker (local container) and Kubernetes (Bitnami Helm chart).
# Called by init.sh — expects gum to be available.
# Hard dependencies: docker (Docker target) | kubectl + helm (K8s target).
# Soft dependency:   mysql CLI (connect feature — prompted if missing).
# Sources: scripts/cluster/cluster.sh for deployment target selection.
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
# shellcheck source=../_common/portforward.sh
source "${COMMON_DIR}/portforward.sh"
# shellcheck source=../_common/cluster.sh
source "${COMMON_DIR}/cluster.sh"

# -----------------------------------------------------------------------------
# Constants / defaults
# -----------------------------------------------------------------------------

MY_NAMESPACE="mysql"
MY_HELM_RELEASE="mysql"
MY_HELM_CHART="oci://registry-1.docker.io/bitnamicharts/mysql"
MY_DEFAULT_PORT=3306
_MY_PF_PID="/tmp/scomp-pf-mysql.pid"
MY_DEFAULT_DB="app"
MY_DEFAULT_USER="app"
MY_DEFAULT_IMAGE_TAG="8.4"

# Colours
BLUE=39

# Session state — populated by _docker_menu / _k8s_menu
MY_CONTAINER_NAME="mysql"
MY_IMAGE_TAG="$MY_DEFAULT_IMAGE_TAG"
MY_DB="$MY_DEFAULT_DB"
MY_USER="$MY_DEFAULT_USER"
MY_PASSWORD=""
MY_ROOT_PASSWORD=""
MY_PORT=$MY_DEFAULT_PORT

# -----------------------------------------------------------------------------
# Dependency checks
# -----------------------------------------------------------------------------

_ensure_mysql_client() {
    if command -v mysql &>/dev/null; then
        info "mysql client: $(mysql --version 2>/dev/null | head -1)"
        return 0
    fi
    warn "mysql client not found."
    warn "macOS: brew install mysql-client && brew link mysql-client --force"
    warn "Linux: apt install mysql-client  /  dnf install mysql"
    return 1
}

check_dependencies() {
    info "Checking dependencies..."
    case "$TARGET_TYPE" in
        docker)   _check_docker ;;
        kind|k8s) _check_kubectl; _ensure_helm "MySQL" ;;
    esac
}

# -----------------------------------------------------------------------------
# Shared config prompts
# -----------------------------------------------------------------------------

_prompt_db_credentials() {
    MY_DB=$(gum input \
        --placeholder "$MY_DEFAULT_DB" \
        --header "Database name (leave empty for '${MY_DEFAULT_DB}'):") || true
    MY_DB="${MY_DB:-$MY_DEFAULT_DB}"

    MY_USER=$(gum input \
        --placeholder "$MY_DEFAULT_USER" \
        --header "Username (leave empty for '${MY_DEFAULT_USER}'):") || true
    MY_USER="${MY_USER:-$MY_DEFAULT_USER}"

    MY_PASSWORD=$(gum input \
        --placeholder "leave empty to auto-generate" \
        --password \
        --header "Password (leave empty to auto-generate):") || true

    if [[ -z "$MY_PASSWORD" ]]; then
        MY_PASSWORD=$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 20)
        gum style \
            --foreground "$YELLOW" --border-foreground "$YELLOW" --border rounded \
            --align center --width 60 --margin "1 0" --padding "0 4" \
            "Generated password: ${MY_PASSWORD}" \
            "Save this — it will not be shown again."
    fi
}

_prompt_root_password() {
    MY_ROOT_PASSWORD=$(gum input \
        --placeholder "leave empty to auto-generate" \
        --password \
        --header "Root password (leave empty to auto-generate):") || true

    if [[ -z "$MY_ROOT_PASSWORD" ]]; then
        MY_ROOT_PASSWORD=$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 20)
        gum style \
            --foreground "$YELLOW" --border-foreground "$YELLOW" --border rounded \
            --align center --width 60 --margin "1 0" --padding "0 4" \
            "Generated root password: ${MY_ROOT_PASSWORD}" \
            "Save this — it will not be shown again."
    fi
}

# -----------------------------------------------------------------------------
# Docker — install / status / connect / uninstall
# -----------------------------------------------------------------------------

_docker_container_exists()  { docker inspect "$1" &>/dev/null 2>&1; }
_docker_container_running() { [[ "$(docker inspect --format='{{.State.Running}}' "$1" 2>/dev/null)" == "true" ]]; }

mysql_install_docker() {
    header "Install MySQL — Docker"

    MY_IMAGE_TAG=$(gum input \
        --placeholder "$MY_DEFAULT_IMAGE_TAG" \
        --header "MySQL image tag (leave empty for '${MY_DEFAULT_IMAGE_TAG}'):") || true
    MY_IMAGE_TAG="${MY_IMAGE_TAG:-$MY_DEFAULT_IMAGE_TAG}"

    local port_input
    port_input=$(gum input \
        --placeholder "$MY_DEFAULT_PORT" \
        --header "Host port (leave empty for ${MY_DEFAULT_PORT}):") || true
    MY_PORT="${port_input:-$MY_DEFAULT_PORT}"

    _prompt_root_password
    _prompt_db_credentials

    local image="mysql:${MY_IMAGE_TAG}"
    local volume="${MY_CONTAINER_NAME}-data"

    if _docker_container_exists "$MY_CONTAINER_NAME"; then
        gum style \
            --foreground "$YELLOW" --border-foreground "$YELLOW" --border rounded \
            --align center --width 60 --margin "1 2" --padding "1 4" \
            "Container '${MY_CONTAINER_NAME}' already exists."

        local action
        action=$(gum choose \
            "Remove and recreate" \
            "Cancel" \
            --header "What would you like to do?") || true

        case "$action" in
            "Remove and recreate")
                gum spin --spinner dot --title "Removing existing container..." -- \
                    docker rm -f "$MY_CONTAINER_NAME" ;;
            *) warn "Cancelled."; return ;;
        esac
    fi

    gum spin --spinner dot --title "Pulling ${image}..." -- \
        docker pull "$image" \
        || error_exit "Failed to pull image ${image}."

    if ! docker run -d \
        --name "$MY_CONTAINER_NAME" \
        -e MYSQL_ROOT_PASSWORD="$MY_ROOT_PASSWORD" \
        -e MYSQL_DATABASE="$MY_DB" \
        -e MYSQL_USER="$MY_USER" \
        -e MYSQL_PASSWORD="$MY_PASSWORD" \
        -p "${MY_PORT}:3306" \
        -v "${volume}:/var/lib/mysql" \
        --restart unless-stopped \
        "$image" &>/dev/null; then
        error_exit "Failed to start container '${MY_CONTAINER_NAME}'."
    fi

    info "Waiting for MySQL to accept connections..."
    local attempts=0
    until docker exec "$MY_CONTAINER_NAME" \
        mysqladmin ping -uroot -p"${MY_ROOT_PASSWORD}" --silent &>/dev/null 2>&1; do
        attempts=$((attempts + 1))
        if [[ $attempts -ge 40 ]]; then
            warn "Timed out waiting for readiness. Check: docker logs ${MY_CONTAINER_NAME}"
            break
        fi
        sleep 1
    done

    gum style \
        --foreground "$GREEN" --border-foreground "$GREEN" --border rounded \
        --align center --width 60 --margin "1 2" --padding "1 4" \
        "MySQL running" \
        "" \
        "Container:  ${MY_CONTAINER_NAME}" \
        "Image:      ${image}" \
        "Database:   ${MY_DB}" \
        "User:       ${MY_USER}" \
        "Port:       localhost:${MY_PORT}" \
        "Volume:     ${volume}"
}

mysql_status_docker() {
    header "MySQL — Docker Status"

    if ! _docker_container_exists "$MY_CONTAINER_NAME"; then
        warn "Container '${MY_CONTAINER_NAME}' not found."
        return
    fi

    local status image ports
    status=$(docker inspect --format='{{.State.Status}}' "$MY_CONTAINER_NAME" 2>/dev/null)
    image=$(docker inspect --format='{{.Config.Image}}'  "$MY_CONTAINER_NAME" 2>/dev/null)
    ports=$(docker inspect \
        --format='{{range $k,$v := .NetworkSettings.Ports}}{{$k}} -> {{range $v}}{{.HostIP}}:{{.HostPort}}{{end}}  {{end}}' \
        "$MY_CONTAINER_NAME" 2>/dev/null)

    gum style \
        --foreground "$CYAN" --border-foreground "$CYAN" --border rounded \
        --align left --width 60 --margin "1 2" --padding "1 4" \
        "Container: ${MY_CONTAINER_NAME}" \
        "Status:    ${status}" \
        "Image:     ${image}" \
        "Ports:     ${ports}"

    echo ""
    gum confirm "Press Enter to continue" --affirmative "OK" --negative "" || true
}

mysql_connect_docker() {
    header "Connect — Docker (mysql)"

    if ! _docker_container_exists "$MY_CONTAINER_NAME"; then
        warn "Container '${MY_CONTAINER_NAME}' not found."
        return
    fi
    if ! _docker_container_running "$MY_CONTAINER_NAME"; then
        warn "Container '${MY_CONTAINER_NAME}' is not running."
        return
    fi

    local env_vars user db password
    env_vars=$(docker inspect --format='{{range .Config.Env}}{{println .}}{{end}}' "$MY_CONTAINER_NAME" 2>/dev/null)
    user=$(echo     "$env_vars" | grep '^MYSQL_USER='     | cut -d= -f2 || echo "root")
    db=$(echo       "$env_vars" | grep '^MYSQL_DATABASE=' | cut -d= -f2 || echo "")
    password=$(echo "$env_vars" | grep '^MYSQL_PASSWORD=' | cut -d= -f2 || echo "")

    info "Connecting as ${user}${db:+ → ${db}}. Type exit or \\q to quit."
    echo ""

    docker exec -it "$MY_CONTAINER_NAME" \
        mysql -u"$user" ${password:+-p"$password"} ${db:+"$db"}
}

mysql_uninstall_docker() {
    header "Uninstall MySQL — Docker"

    if ! _docker_container_exists "$MY_CONTAINER_NAME"; then
        warn "Container '${MY_CONTAINER_NAME}' not found."
        return
    fi

    local volume="${MY_CONTAINER_NAME}-data"

    gum style \
        --foreground "$RED" --border-foreground "$RED" --border rounded \
        --width 60 --margin "0 2" --padding "1 2" \
        "This will remove container '${MY_CONTAINER_NAME}'." \
        "" \
        "Data volume: ${volume}"

    if ! gum confirm "Remove container '${MY_CONTAINER_NAME}'?"; then
        warn "Cancelled."
        return
    fi

    local remove_volume=false
    gum confirm "Also remove data volume '${volume}'? (all data will be lost)" \
        && remove_volume=true || true

    gum spin --spinner dot --title "Removing container '${MY_CONTAINER_NAME}'..." -- \
        docker rm -f "$MY_CONTAINER_NAME" || true

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
    helm status "$MY_HELM_RELEASE" -n "$MY_NAMESPACE" &>/dev/null 2>&1
}

_k8s_ensure_namespace() {
    if kubectl get namespace "$MY_NAMESPACE" &>/dev/null; then
        info "Namespace '${MY_NAMESPACE}' already exists."
    else
        info "Creating namespace '${MY_NAMESPACE}'..."
        kubectl create namespace "$MY_NAMESPACE"
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

mysql_install_k8s() {
    header "Install MySQL — Kubernetes"
    _k8s_check_cluster || return 0

    _prompt_root_password
    _prompt_db_credentials

    local storage_size
    storage_size=$(gum input \
        --placeholder "8Gi" \
        --header "Persistent volume size (leave empty for '8Gi'):") || true
    storage_size="${storage_size:-8Gi}"

    _k8s_ensure_namespace

    local helm_args=(
        "$MY_HELM_RELEASE" "$MY_HELM_CHART"
        --namespace "$MY_NAMESPACE"
        --set auth.rootPassword="$MY_ROOT_PASSWORD"
        --set auth.username="$MY_USER"
        --set auth.password="$MY_PASSWORD"
        --set auth.database="$MY_DB"
        --set primary.persistence.size="$storage_size"
        --wait --timeout 5m
    )

    if _k8s_detect_installed; then
        gum style \
            --foreground "$YELLOW" --border-foreground "$YELLOW" --border rounded \
            --align center --width 60 --margin "1 2" --padding "1 4" \
            "Release '${MY_HELM_RELEASE}' already exists in '${MY_NAMESPACE}'."

        local action
        action=$(gum choose \
            "Upgrade (apply new values)" \
            "Cancel" \
            --header "What would you like to do?") || true

        case "$action" in
            "Upgrade"*) ;;
            *) warn "Cancelled."; return ;;
        esac

        gum spin --spinner dot --title "Upgrading MySQL via Helm..." -- \
            helm upgrade "${helm_args[@]}" \
            || error_exit "Helm upgrade failed. Check: kubectl get pods -n ${MY_NAMESPACE}"
    else
        gum spin --spinner dot --title "Installing MySQL via Helm (may take a few minutes)..." -- \
            helm install "${helm_args[@]}" \
            || error_exit "Helm install failed. Check: kubectl get pods -n ${MY_NAMESPACE}"
    fi

    gum style \
        --foreground "$GREEN" --border-foreground "$GREEN" --border rounded \
        --align center --width 60 --margin "1 2" --padding "1 4" \
        "MySQL installed" \
        "" \
        "Release:    ${MY_HELM_RELEASE}" \
        "Namespace:  ${MY_NAMESPACE}" \
        "Database:   ${MY_DB}" \
        "User:       ${MY_USER}" \
        "" \
        "Use 'port-forward' or 'connect' from the menu to access it."
}

mysql_status_k8s() {
    header "MySQL — Kubernetes Status"
    _k8s_check_cluster || return 0

    if ! _k8s_detect_installed; then
        warn "Release '${MY_HELM_RELEASE}' not found in namespace '${MY_NAMESPACE}'."
        return
    fi

    gum style --foreground "$CYAN" --bold "── Helm release ──"
    helm status "$MY_HELM_RELEASE" -n "$MY_NAMESPACE" 2>/dev/null || true

    echo ""
    gum style --foreground "$CYAN" --bold "── Pods ──"
    kubectl get pods -n "$MY_NAMESPACE" 2>/dev/null || true

    echo ""
    gum style --foreground "$CYAN" --bold "── Services ──"
    kubectl get svc -n "$MY_NAMESPACE" 2>/dev/null || true

    echo ""
    gum confirm "Press Enter to continue" --affirmative "OK" --negative "" || true
}

mysql_port_forward_k8s() {
    header "MySQL — Port Forward"
    _k8s_check_cluster || return 0

    if ! _k8s_detect_installed; then
        warn "Release '${MY_HELM_RELEASE}' not found in namespace '${MY_NAMESPACE}'."
        return
    fi

    if pf_is_running "$_MY_PF_PID"; then
        gum style --foreground "$GREEN" --border-foreground "$GREEN" --border rounded \
            --width 60 --margin "0 2" --padding "1 2" \
            "Port-forward is running" \
            "localhost:$(pf_port "$_MY_PF_PID") → ${MY_HELM_RELEASE}:3306" \
            "" \
            "Connect: mysql -h 127.0.0.1 -P $(pf_port "$_MY_PF_PID") -u <user> -p"
        gum confirm "Stop port-forward?" && pf_stop "$_MY_PF_PID" || true
        return
    fi

    local port_input
    port_input=$(gum input \
        --placeholder "$MY_DEFAULT_PORT" \
        --header "Local port (leave empty for ${MY_DEFAULT_PORT}):") || true
    local port="${port_input:-$MY_DEFAULT_PORT}"

    kubectl -n "$MY_NAMESPACE" port-forward "svc/${MY_HELM_RELEASE}" "${port}:3306" >/dev/null 2>&1 &
    echo "${!}:${port}" > "$_MY_PF_PID"

    local attempts=0
    until nc -z 127.0.0.1 "$port" 2>/dev/null || [[ $attempts -ge 20 ]]; do
        sleep 0.25; attempts=$((attempts + 1))
    done

    if ! pf_is_running "$_MY_PF_PID"; then
        warn "Port-forward failed to start. Check kubectl connectivity."
        rm -f "$_MY_PF_PID"; return
    fi

    success "Port-forward started: localhost:${port} → ${MY_HELM_RELEASE}:3306"
    info "Connect: mysql -h 127.0.0.1 -P ${port} -u <user> -p"
}

mysql_connect_k8s() {
    header "Connect — Kubernetes (mysql)"
    _k8s_check_cluster || return 0

    if ! _k8s_detect_installed; then
        warn "Release '${MY_HELM_RELEASE}' not found in namespace '${MY_NAMESPACE}'."
        return
    fi

    if ! _ensure_mysql_client; then
        warn "Install the mysql client first, then use 'port-forward' to connect."
        return
    fi

    local port_input
    port_input=$(gum input \
        --placeholder "$MY_DEFAULT_PORT" \
        --header "Local port for port-forward (leave empty for ${MY_DEFAULT_PORT}):") || true
    local port="${port_input:-$MY_DEFAULT_PORT}"

    local user
    user=$(gum input \
        --placeholder "$MY_DEFAULT_USER" \
        --header "Username (leave empty for '${MY_DEFAULT_USER}'):") || true
    user="${user:-$MY_DEFAULT_USER}"

    local db
    db=$(gum input \
        --placeholder "$MY_DEFAULT_DB" \
        --header "Database (leave empty for '${MY_DEFAULT_DB}'):") || true
    db="${db:-$MY_DEFAULT_DB}"

    info "Starting port-forward in background..."
    kubectl -n "$MY_NAMESPACE" port-forward "svc/${MY_HELM_RELEASE}" "${port}:3306" >/dev/null 2>&1 &
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

    info "Connected on 127.0.0.1:${port}. Type exit or \\q to quit."
    echo ""

    # -h 127.0.0.1 forces TCP; localhost would try a Unix socket which won't exist locally.
    mysql -h 127.0.0.1 -P "$port" -u "$user" -p "$db" || true

    kill "$pf_pid" 2>/dev/null || true
    wait "$pf_pid" 2>/dev/null || true
}

mysql_uninstall_k8s() {
    header "Uninstall MySQL — Kubernetes"
    _k8s_check_cluster || return 0

    if ! _k8s_detect_installed; then
        warn "Release '${MY_HELM_RELEASE}' not found in namespace '${MY_NAMESPACE}'."
        return
    fi

    gum style \
        --foreground "$RED" --border-foreground "$RED" --border rounded \
        --width 60 --margin "0 2" --padding "1 2" \
        "This will remove Helm release '${MY_HELM_RELEASE}'" \
        "from namespace '${MY_NAMESPACE}'." \
        "" \
        "PersistentVolumeClaims are NOT removed automatically by Helm." \
        "Delete them manually to fully purge data:" \
        "  kubectl delete pvc --all -n ${MY_NAMESPACE}"

    if ! gum confirm "Uninstall MySQL?"; then
        warn "Cancelled."
        return
    fi

    gum spin --spinner dot --title "Running helm uninstall..." -- \
        helm uninstall "$MY_HELM_RELEASE" -n "$MY_NAMESPACE" || true

    if gum confirm "Also delete namespace '${MY_NAMESPACE}' (removes remaining PVCs too)?"; then
        gum spin --spinner dot --title "Deleting namespace '${MY_NAMESPACE}'..." -- \
            kubectl delete namespace "$MY_NAMESPACE" --ignore-not-found || true
        success "Namespace deleted."
    fi

    success "MySQL uninstalled."
}

# -----------------------------------------------------------------------------
# Menus
# -----------------------------------------------------------------------------

_docker_menu() {
    local name_input
    name_input=$(gum input \
        --placeholder "mysql" \
        --header "Container name for this session (leave empty for 'mysql'):") || true
    MY_CONTAINER_NAME="${name_input:-mysql}"

    while true; do
        header "MySQL — Docker  (${MY_CONTAINER_NAME})"

        local action
        action=$(gum choose \
            "install" \
            "status" \
            "connect" \
            "uninstall" \
            "← back" \
            --header "Select action:") || true

        case "$action" in
            "install")    mysql_install_docker ;;
            "status")     mysql_status_docker ;;
            "connect")    mysql_connect_docker ;;
            "uninstall")  mysql_uninstall_docker ;;
            "← back"|"") return ;;
        esac
    done
}

_k8s_menu() {
    local ns_input
    ns_input=$(gum input \
        --placeholder "$MY_NAMESPACE" \
        --header "Kubernetes namespace for this session (leave empty for '${MY_NAMESPACE}'):") || true
    MY_NAMESPACE="${ns_input:-$MY_NAMESPACE}"

    local release_input
    release_input=$(gum input \
        --placeholder "$MY_HELM_RELEASE" \
        --header "Helm release name (leave empty for '${MY_HELM_RELEASE}'):") || true
    MY_HELM_RELEASE="${release_input:-$MY_HELM_RELEASE}"

    while true; do
        header "MySQL — Kubernetes  (${TARGET_TYPE}: ${TARGET_CONTEXT} / ns: ${MY_NAMESPACE} / release: ${MY_HELM_RELEASE})"

        local pf_label
        pf_is_running "$_MY_PF_PID" \
            && pf_label="port-forward  [● localhost:$(pf_port "$_MY_PF_PID")]" \
            || pf_label="port-forward  [○ stopped]"

        local action
        action=$(gum choose \
            "install" \
            "status" \
            "$pf_label" \
            "connect" \
            "uninstall" \
            "← back" \
            --header "Select action:") || true

        case "$action" in
            "install")       mysql_install_k8s ;;
            "status")        mysql_status_k8s ;;
            "port-forward"*) mysql_port_forward_k8s ;;
            "connect")       mysql_connect_k8s ;;
            "uninstall")     mysql_uninstall_k8s ;;
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
        "MySQL" \
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
