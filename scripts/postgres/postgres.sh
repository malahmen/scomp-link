#!/usr/bin/env bash
# description: PostgreSQL: install, connect, manage (Docker/K8s)
# Standalone export (export.sh): tools the slimmed setup.sh pre-installs.
# export-setup: kubectl helm
# -----------------------------------------------------------------------------
# postgres.sh
# Interactive TUI for installing and managing PostgreSQL.
# Supports Docker (local container) and Kubernetes (groundhog2k Helm chart,
# which deploys the official postgres image — replaces the deprecated Bitnami chart).
# Called by init.sh — expects gum to be available.
# Hard dependencies: docker (Docker target) | kubectl + helm (K8s target).
# Soft dependency:   psql (connect feature — prompted if missing).
# Sources: scripts/_common/cluster.sh (deployment target selection), ui.sh,
#          deps.sh, portforward.sh.
# -----------------------------------------------------------------------------

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ -d "${SCRIPT_DIR}/../_common" ]]; then
    COMMON_DIR="${SCRIPT_DIR}/../_common"   # scomp-link repo layout
else
    COMMON_DIR="${SCRIPT_DIR}"              # exported standalone: deps sit alongside
fi
if [[ ! -d "$COMMON_DIR" ]]; then
    printf "\033[0;31m[ERROR] _common directory not found at %s\033[0m\n" "$COMMON_DIR" >&2
    exit 1
fi
# shellcheck source=../_common/ui.sh
source "${COMMON_DIR}/ui.sh"
# shellcheck source=../_common/secret.sh
source "${COMMON_DIR}/secret.sh"
# shellcheck source=../_common/deps.sh
source "${COMMON_DIR}/deps.sh"
# shellcheck source=../_common/portforward.sh
source "${COMMON_DIR}/portforward.sh"
# shellcheck source=../_common/cluster.sh
source "${COMMON_DIR}/cluster.sh"

# -----------------------------------------------------------------------------
# Constants / defaults
# -----------------------------------------------------------------------------

PG_NAMESPACE="postgres"
PG_HELM_RELEASE="postgresql"
# Bitnami's free catalog was gutted in 2025 (images moved to bitnamilegacy and
# purged), so we use groundhog2k's chart, which deploys the official `postgres`
# image — mirroring the Docker target. fullnameOverride keeps the Service named
# after the release, so port-forward/connect below can address svc/<release>.
PG_HELM_REPO_NAME="groundhog2k"
PG_HELM_REPO_URL="https://groundhog2k.github.io/helm-charts/"
PG_HELM_CHART="groundhog2k/postgres"
PG_DEFAULT_PORT=5432
_PG_PF_PID="$(pf_file postgres)"
PG_DEFAULT_DB="app"
PG_DEFAULT_USER="app"
PG_DEFAULT_IMAGE_TAG="16"

# Colours
BLUE=39

# Session state — populated by _docker_menu / _k8s_menu
PG_CONTAINER_NAME="postgres"
PG_IMAGE_TAG="$PG_DEFAULT_IMAGE_TAG"
PG_DB="$PG_DEFAULT_DB"
PG_USER="$PG_DEFAULT_USER"
PG_PASSWORD=""
PG_PORT=$PG_DEFAULT_PORT

# -----------------------------------------------------------------------------
# Dependency checks
# -----------------------------------------------------------------------------

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
        kind|k8s) _check_kubectl; _ensure_helm "PostgreSQL" ;;
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
        PG_PASSWORD=$(_gen_secret 20)
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

# _pg_data_mount <image-tag> - where the data volume is mounted. The official
# image 18+ keeps PGDATA in /var/lib/postgresql/<major>/docker and declares
# /var/lib/postgresql as its volume; it refuses to start with a mount at
# /var/lib/postgresql/data, where 17 and older keep it (Kamino 196). A tag
# without a leading version (latest, alpine, bookworm...) is 18 or newer.
_pg_data_mount() {
    if [[ "$1" =~ ^([0-9]+) ]] && (( 10#${BASH_REMATCH[1]} <= 17 )); then
        echo /var/lib/postgresql/data
    else
        echo /var/lib/postgresql
    fi
}

# _docker_volume_mount <container> <volume> - where the container mounts the
# volume, or nothing.
_docker_volume_mount() {
    docker inspect --format '{{range .Mounts}}{{.Name}}:{{.Destination}}{{println}}{{end}}' "$1" 2>/dev/null \
        | sed -n "s|^$2:||p" | head -1
}
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

    local image="postgres:${PG_IMAGE_TAG}"
    local volume="${PG_CONTAINER_NAME}-data"
    local data_mount
    data_mount="$(_pg_data_mount "$PG_IMAGE_TAG")"

    local old=""
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
            "Remove and recreate") old="$PG_CONTAINER_NAME" ;;
            *) warn "Cancelled."; return ;;
        esac
    fi

    # The image applies POSTGRES_* only to an empty data dir: on a kept volume
    # the old credentials stay in force, so they are carried over, not asked
    # for again (Kamino 174). Read before the old container is removed.
    if docker volume inspect "$volume" &>/dev/null; then
        # 17 and older and 18+ lay the volume out differently: a kept volume
        # of the other kind is not used - 18+ would initialise a new, empty
        # cluster next to the old one - and data from another major version
        # needs pg_upgrade (or a dump and restore) anyway (Kamino 196).
        local old_mount=""
        [[ -n "$old" ]] && old_mount="$(_docker_volume_mount "$old" "$volume")"
        if [[ -n "$old_mount" && "$old_mount" != "$data_mount" ]]; then
            gum style \
                --foreground "$YELLOW" --border-foreground "$YELLOW" --border rounded \
                --width 60 --margin "1 2" --padding "1 2" \
                "Volume '${volume}' was mounted at ${old_mount};" \
                "postgres:${PG_IMAGE_TAG} needs it at ${data_mount}." \
                "" \
                "PostgreSQL 18 moved its data directory: it will not use" \
                "the cluster in this volume (and 17 or older will not use" \
                "an 18+ one). Upgrade the data with pg_upgrade, or a dump" \
                "and restore, or keep the image's major version."
            if ! gum confirm "Start postgres:${PG_IMAGE_TAG} on this volume anyway?" --default=false; then
                warn "Cancelled."; return
            fi
        elif [[ -z "$old_mount" && "$data_mount" == /var/lib/postgresql ]]; then
            warn "If volume '${volume}' was created by PostgreSQL 17 or older, postgres:${PG_IMAGE_TAG} will not use its data (18 moved the data directory): upgrade it with pg_upgrade first, or use a tag of that major version."
        fi
        _kept_data_notice "$volume" "$old"
        _keep_credential PG_DB       "$old" POSTGRES_DB       "database name" "=${PG_DEFAULT_DB}" \
            && _keep_credential PG_USER     "$old" POSTGRES_USER     "username"      "=${PG_DEFAULT_USER}" \
            && _keep_credential PG_PASSWORD "$old" POSTGRES_PASSWORD "password"      "secret?" \
            || { warn "Cancelled."; return; }
    else
        _prompt_db_credentials
    fi

    if [[ -n "$old" ]]; then
        gum spin --spinner dot --title "Removing existing container..." -- \
            docker rm -f "$PG_CONTAINER_NAME"
    fi

    gum spin --spinner dot --title "Pulling ${image}..." -- \
        docker pull "$image" \
        || error_exit "Failed to pull image ${image}."

    # The password is passed as -e NAME, the value taken from docker's own
    # environment: not on its command line, where any local user can read it
    # (Kamino 196).
    if ! POSTGRES_PASSWORD="$PG_PASSWORD" docker run -d \
        --name "$PG_CONTAINER_NAME" \
        -e POSTGRES_DB="$PG_DB" \
        -e POSTGRES_USER="$PG_USER" \
        -e POSTGRES_PASSWORD \
        -p "$(svc_publish "$PG_PORT" 5432)" \
        -v "${volume}:${data_mount}" \
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
        "Port:       $(svc_host):${PG_PORT}" \
        "Volume:     ${volume}"
    svc_bind_notice
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
    # cut -f2-, not -f2: a value may contain '=' itself (Kamino 196).
    user=$(echo "$env_vars" | grep '^POSTGRES_USER='     | cut -d= -f2- || echo "postgres")
    db=$(echo   "$env_vars" | grep '^POSTGRES_DB='       | cut -d= -f2- || echo "$user")

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
    helm --kube-context "$KUBE_CONTEXT" status "$PG_HELM_RELEASE" -n "$PG_NAMESPACE" &>/dev/null 2>&1
}

_k8s_ensure_namespace() {
    if kubectl --context "$KUBE_CONTEXT" get namespace "$PG_NAMESPACE" &>/dev/null; then
        info "Namespace '${PG_NAMESPACE}' already exists."
    else
        info "Creating namespace '${PG_NAMESPACE}'..."
        kubectl --context "$KUBE_CONTEXT" create namespace "$PG_NAMESPACE"
    fi
}

# Sets KUBE_CONTEXT to the chosen context and verifies the cluster is
# reachable. Must be called at the start of every K8s operation.
_k8s_check_cluster() {
    # Never `kubectl config use-context`: that rewrote the user's kubeconfig for
    # every terminal, and the deletes that followed (without --context) went to
    # whatever the current context had become by then (Kamino 175). Every
    # kubectl/helm call names the chosen context instead.
    KUBE_CONTEXT="$(kube_context_name)"
    [[ -n "$KUBE_CONTEXT" ]] || error_exit "No Kubernetes context selected."

    if ! gum spin --spinner dot --title "Verifying cluster connectivity..." -- \
        kubectl --context "$KUBE_CONTEXT" cluster-info &>/dev/null; then
        gum log --level error "Cannot reach cluster '${KUBE_CONTEXT}'."
        gum log --level error "Verify the cluster is running and your kubeconfig is up to date."
        return 1
    fi
    info "Cluster reachable."
}

postgres_install_k8s() {
    header "Install PostgreSQL — Kubernetes"
    _k8s_check_cluster || return 0

    # An existing release keeps its credentials: the database in its PVC was
    # initialised with them and ignores new ones, so an upgrade asks for none
    # and reuses the release's values (Kamino 174).
    local upgrade=false
    if _k8s_detect_installed; then
        gum style \
            --foreground "$YELLOW" --border-foreground "$YELLOW" --border rounded \
            --align center --width 60 --margin "1 2" --padding "1 4" \
            "Release '${PG_HELM_RELEASE}' already exists in '${PG_NAMESPACE}'."

        local action
        action=$(gum choose \
            "Upgrade (keep credentials, apply other values)" \
            "Cancel" \
            --header "What would you like to do?") || true

        case "$action" in
            "Upgrade"*) upgrade=true ;;
            *) warn "Cancelled."; return ;;
        esac
        info "Keeping the release's existing credentials (helm --reuse-values): the database in its volume keeps the ones it was created with."
    else
        _prompt_db_credentials
    fi

    local storage_size
    storage_size=$(gum input \
        --placeholder "8Gi" \
        --header "Persistent volume size (leave empty for '8Gi'):") || true
    storage_size="${storage_size:-8Gi}"

    _ensure_helm_repo "$PG_HELM_REPO_NAME" "$PG_HELM_REPO_URL"
    _k8s_ensure_namespace

    # groundhog2k/postgres keys: settings.superuserPassword = the 'postgres'
    # superuser; userDatabase.* creates an app database + user. fullnameOverride
    # pins the Service name to the release so svc/<release> resolves.
    local helm_args=(
        "$PG_HELM_RELEASE" "$PG_HELM_CHART"
        --namespace "$PG_NAMESPACE"
        --set fullnameOverride="$PG_HELM_RELEASE"
        --set storage.requestedSize="$storage_size"
        --wait --timeout 5m
    )

    if [[ "$upgrade" == true ]]; then
        helm_args+=(--reuse-values)
        gum spin --spinner dot --title "Upgrading PostgreSQL via Helm..." -- \
            helm --kube-context "$KUBE_CONTEXT" upgrade "${helm_args[@]}" \
            || error_exit "Helm upgrade failed. Check: kubectl --context ${KUBE_CONTEXT} get pods -n ${PG_NAMESPACE}"
    else
        # The passwords go in a 0600 values file, not --set: on argv they are
        # readable by every local user, and --set splits a value at commas and
        # parses \ . { } in it (Kamino 196).
        local secret_values
        _helm_secret_values secret_values \
            settings.superuserPassword "$PG_PASSWORD" \
            userDatabase.password      "$PG_PASSWORD" \
            || error_exit "The password contains control characters; it cannot be passed to helm."
        helm_args+=(
            -f "$secret_values"
            --set userDatabase.name="$PG_DB"
            --set userDatabase.user="$PG_USER"
        )
        gum spin --spinner dot --title "Installing PostgreSQL via Helm (may take a few minutes)..." -- \
            helm --kube-context "$KUBE_CONTEXT" install "${helm_args[@]}" \
            || error_exit "Helm install failed. Check: kubectl --context ${KUBE_CONTEXT} get pods -n ${PG_NAMESPACE}"
        _secret_file_rm "$secret_values"
    fi

    local shown_db="$PG_DB" shown_user="$PG_USER"
    [[ "$upgrade" == true ]] && shown_db="(unchanged)" shown_user="(unchanged)"
    gum style \
        --foreground "$GREEN" --border-foreground "$GREEN" --border rounded \
        --align center --width 60 --margin "1 2" --padding "1 4" \
        "PostgreSQL installed" \
        "" \
        "Release:    ${PG_HELM_RELEASE}" \
        "Namespace:  ${PG_NAMESPACE}" \
        "Database:   ${shown_db}" \
        "User:       ${shown_user}" \
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
    helm --kube-context "$KUBE_CONTEXT" status "$PG_HELM_RELEASE" -n "$PG_NAMESPACE" 2>/dev/null || true

    echo ""
    gum style --foreground "$CYAN" --bold "── Pods ──"
    kubectl --context "$KUBE_CONTEXT" get pods -n "$PG_NAMESPACE" 2>/dev/null || true

    echo ""
    gum style --foreground "$CYAN" --bold "── Services ──"
    kubectl --context "$KUBE_CONTEXT" get svc -n "$PG_NAMESPACE" 2>/dev/null || true

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

    if pf_is_running "$_PG_PF_PID"; then
        gum style --foreground "$GREEN" --border-foreground "$GREEN" --border rounded \
            --width 60 --margin "0 2" --padding "1 2" \
            "Port-forward is running" \
            "localhost:$(pf_port "$_PG_PF_PID") → ${PG_HELM_RELEASE}:5432" \
            "" \
            "Connect: psql -h localhost -p $(pf_port "$_PG_PF_PID") -U <user> -d <db>"
        gum confirm "Stop port-forward?" && pf_stop "$_PG_PF_PID" || true
        return
    fi

    local port_input
    port_input=$(gum input \
        --placeholder "$PG_DEFAULT_PORT" \
        --header "Local port (leave empty for ${PG_DEFAULT_PORT}):") || true
    local port="${port_input:-$PG_DEFAULT_PORT}"

    kubectl --context "$KUBE_CONTEXT" -n "$PG_NAMESPACE" port-forward "svc/${PG_HELM_RELEASE}" "${port}:5432" >/dev/null 2>&1 &
    pf_write "$_PG_PF_PID" "${!}" "${port}"

    local attempts=0
    until nc -z 127.0.0.1 "$port" 2>/dev/null || [[ $attempts -ge 20 ]]; do
        sleep 0.25; attempts=$((attempts + 1))
    done

    if ! pf_is_running "$_PG_PF_PID"; then
        warn "Port-forward failed to start. Check kubectl connectivity."
        rm -f "$_PG_PF_PID"; return
    fi

    success "Port-forward started: localhost:${port} → ${PG_HELM_RELEASE}:5432"
    info "Connect: psql -h localhost -p ${port} -U <user> -d <db>"
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
    kubectl --context "$KUBE_CONTEXT" -n "$PG_NAMESPACE" port-forward "svc/${PG_HELM_RELEASE}" "${port}:5432" >/dev/null 2>&1 &
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
        "  kubectl --context ${KUBE_CONTEXT} delete pvc --all -n ${PG_NAMESPACE}"

    if ! gum confirm "Uninstall PostgreSQL?"; then
        warn "Cancelled."
        return
    fi

    gum spin --spinner dot --title "Running helm uninstall..." -- \
        helm --kube-context "$KUBE_CONTEXT" uninstall "$PG_HELM_RELEASE" -n "$PG_NAMESPACE" || true

    if gum confirm "Also delete namespace '${PG_NAMESPACE}' (removes remaining PVCs too)?"; then
        gum spin --spinner dot --title "Deleting namespace '${PG_NAMESPACE}'..." -- \
            kubectl --context "$KUBE_CONTEXT" delete namespace "$PG_NAMESPACE" --ignore-not-found || true
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

        local pf_label
        pf_is_running "$_PG_PF_PID" \
            && pf_label="port-forward  [● localhost:$(pf_port "$_PG_PF_PID")]" \
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
            "install")       postgres_install_k8s ;;
            "status")        postgres_status_k8s ;;
            "port-forward"*) postgres_port_forward_k8s ;;
            "connect")       postgres_connect_k8s ;;
            "uninstall")     postgres_uninstall_k8s ;;
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
