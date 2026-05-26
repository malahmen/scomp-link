#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# redis.sh
# Interactive TUI for installing and managing Redis.
# Supports Docker (local container) and Kubernetes (Bitnami Helm chart).
# Called by init.sh — expects gum to be available.
# Hard dependencies: docker (Docker target) | kubectl + helm (K8s target).
# Soft dependency:   redis-cli (connect + queue listing — prompted if missing).
# Sources: scripts/cluster/cluster.sh for deployment target selection.
#
# Queue listing scans all keys and reports type + size, useful for inspecting
# job queues (BullMQ / Celery / Sidekiq / Resque / Streams).
# Uses SCAN (non-blocking) rather than KEYS to be safe on live instances.
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

RD_NAMESPACE="redis"
RD_HELM_RELEASE="redis"
RD_HELM_CHART="oci://registry-1.docker.io/bitnamicharts/redis"
RD_DEFAULT_PORT=6379
_RD_PF_PID="/tmp/scomp-pf-redis.pid"
RD_DEFAULT_IMAGE_TAG="7"
RD_QUEUE_SCAN_LIMIT=500     # max keys to inspect during queue listing

# Colours
BLUE=39

# Session state — populated by _docker_menu / _k8s_menu
RD_CONTAINER_NAME="redis"
RD_IMAGE_TAG="$RD_DEFAULT_IMAGE_TAG"
RD_PASSWORD=""
RD_PORT=$RD_DEFAULT_PORT

# -----------------------------------------------------------------------------
# Dependency checks
# -----------------------------------------------------------------------------

_ensure_redis_cli() {
    if command -v redis-cli &>/dev/null; then
        info "redis-cli: $(redis-cli --version 2>/dev/null)"
        return 0
    fi

    gum style \
        --foreground "$YELLOW" --border-foreground "$YELLOW" --border rounded \
        --align center --width 60 --margin "1 2" --padding "1 4" \
        "redis-cli not found" \
        "Required for connect and queue listing."

    if ! gum confirm "Install redis-cli now?"; then
        warn "Skipping — connect and list-queues will be unavailable this session."
        return 1
    fi

    local os
    os=$(uname -s)

    if [[ "$os" == "Darwin" ]]; then
        if ! gum spin --spinner dot --title "Installing redis via brew..." -- \
            brew install redis; then
            warn "Failed to install redis via brew."
            return 1
        fi
    elif command -v apt-get &>/dev/null; then
        if ! gum spin --spinner dot --title "Installing redis-tools via apt..." -- \
            sudo apt-get install -y redis-tools; then
            warn "Failed to install redis-tools via apt."
            return 1
        fi
    elif command -v dnf &>/dev/null; then
        if ! gum spin --spinner dot --title "Installing redis via dnf..." -- \
            sudo dnf install -y redis; then
            warn "Failed to install redis via dnf."
            return 1
        fi
    else
        warn "Cannot auto-install redis-cli on this system."
        warn "Install manually: https://redis.io/docs/connect/cli/"
        return 1
    fi

    if ! command -v redis-cli &>/dev/null; then
        warn "redis-cli installed but not found in PATH."
        return 1
    fi
    success "redis-cli installed: $(redis-cli --version 2>/dev/null)"
}

check_dependencies() {
    info "Checking dependencies..."
    case "$TARGET_TYPE" in
        docker)   _check_docker ;;
        kind|k8s) _check_kubectl; _ensure_helm "Redis" ;;
    esac
}

# -----------------------------------------------------------------------------
# Config prompts
# -----------------------------------------------------------------------------

_prompt_password() {
    RD_PASSWORD=$(gum input \
        --placeholder "leave empty to disable authentication" \
        --password \
        --header "Password (optional — leave empty for no auth):") || true

    if [[ -z "$RD_PASSWORD" ]]; then
        warn "No password set — Redis will be accessible without authentication."
    fi
}

# -----------------------------------------------------------------------------
# redis-cli wrappers
# Prefer REDISCLI_AUTH env var over -a flag to keep passwords out of ps output.
# -----------------------------------------------------------------------------

# Run redis-cli inside the Docker container.
_docker_cli() {
    REDISCLI_AUTH="$RD_PASSWORD" \
        docker exec -e REDISCLI_AUTH="$RD_PASSWORD" \
        "$RD_CONTAINER_NAME" redis-cli "$@"
}

# Run redis-cli on the host against a local port (after port-forward or direct Docker mapping).
_local_cli() {
    local port="$1"; shift
    REDISCLI_AUTH="$RD_PASSWORD" redis-cli -h 127.0.0.1 -p "$port" "$@"
}

# -----------------------------------------------------------------------------
# Queue / key listing (shared — takes a "cli function" name + port as context)
# -----------------------------------------------------------------------------

# _scan_and_list <mode> [port]
#   mode = "docker"  → uses _docker_cli
#   mode = "local"   → uses _local_cli <port>
_scan_and_list() {
    local mode="$1"
    local port="${2:-}"

    _cli() {
        if [[ "$mode" == "docker" ]]; then
            _docker_cli "$@"
        else
            _local_cli "$port" "$@"
        fi
    }

    info "Scanning keys (limit: ${RD_QUEUE_SCAN_LIMIT})..."

    # Collect keys via SCAN — non-blocking, safe on live instances.
    local -a all_keys=()
    local cursor=0
    local total=0

    while true; do
        local raw
        raw=$(_cli SCAN "$cursor" COUNT 100 2>/dev/null) || { warn "Could not reach Redis."; return; }

        cursor=$(echo "$raw" | head -1 | tr -d '\r')
        while IFS= read -r key; do
            [[ -z "$key" ]] && continue
            all_keys+=("$key")
            total=$((total + 1))
        done < <(echo "$raw" | tail -n +2)

        [[ "$cursor" == "0" || $total -ge $RD_QUEUE_SCAN_LIMIT ]] && break
    done

    if [[ $total -ge $RD_QUEUE_SCAN_LIMIT ]]; then
        warn "Key scan limited to ${RD_QUEUE_SCAN_LIMIT} keys. Instance may have more."
    fi

    if [[ ${#all_keys[@]} -eq 0 ]]; then
        warn "No keys found."
        echo ""
        gum confirm "Press Enter to continue" --affirmative "OK" --negative "" || true
        return
    fi

    info "Found ${#all_keys[@]} keys — fetching types and sizes..."

    # For each key, get type and the size metric relevant to that type.
    local -a rows=()
    for key in "${all_keys[@]}"; do
        local type size
        type=$(_cli TYPE "$key" 2>/dev/null | tr -d '\r') || continue
        case "$type" in
            list)   size=$(_cli LLEN  "$key" 2>/dev/null | tr -d '\r') ;;
            stream) size=$(_cli XLEN  "$key" 2>/dev/null | tr -d '\r') ;;
            zset)   size=$(_cli ZCARD "$key" 2>/dev/null | tr -d '\r') ;;
            set)    size=$(_cli SCARD "$key" 2>/dev/null | tr -d '\r') ;;
            hash)   size=$(_cli HLEN  "$key" 2>/dev/null | tr -d '\r') ;;
            string) size=1 ;;
            none)   continue ;; # key expired between scan and type check
            *)      size=0 ;;
        esac
        rows+=("$(printf '%010d' "${size:-0}")|${type}|${key}")
    done

    # Sort by size descending, then print as a formatted table.
    echo ""
    printf "%-10s  %8s  %s\n" "TYPE" "SIZE" "KEY"
    printf "%-10s  %8s  %s\n" "──────────" "────────" "──────────────────────────────"

    local queue_total=0
    while IFS='|' read -r padded_size type key; do
        local size=$(( 10#$padded_size ))  # strip leading zeros
        local label="$type"
        # Flag types that are commonly used as job queues
        case "$type" in
            list|stream|zset) label="${type} ◂" ;;
        esac
        printf "%-10s  %8s  %s\n" "$label" "$size" "$key"
        case "$type" in list|stream|zset) queue_total=$((queue_total + size)) ;; esac
    done < <(printf '%s\n' "${rows[@]}" | sort -t'|' -k1 -rn)

    echo ""
    gum style --foreground "$CYAN" \
        "◂ = common queue type (list / stream / zset)"
    [[ $queue_total -gt 0 ]] && \
        gum style --foreground "$YELLOW" "Total items across queue-type keys: ${queue_total}"

    echo ""
    gum confirm "Press Enter to continue" --affirmative "OK" --negative "" || true

    unset -f _cli
}

# -----------------------------------------------------------------------------
# Docker — install / status / connect / list-queues / uninstall
# -----------------------------------------------------------------------------

_docker_container_exists()  { docker inspect "$1" &>/dev/null 2>&1; }
_docker_container_running() { [[ "$(docker inspect --format='{{.State.Running}}' "$1" 2>/dev/null)" == "true" ]]; }

redis_install_docker() {
    header "Install Redis — Docker"

    RD_IMAGE_TAG=$(gum input \
        --placeholder "$RD_DEFAULT_IMAGE_TAG" \
        --header "Redis image tag (leave empty for '${RD_DEFAULT_IMAGE_TAG}'):") || true
    RD_IMAGE_TAG="${RD_IMAGE_TAG:-$RD_DEFAULT_IMAGE_TAG}"

    local port_input
    port_input=$(gum input \
        --placeholder "$RD_DEFAULT_PORT" \
        --header "Host port (leave empty for ${RD_DEFAULT_PORT}):") || true
    RD_PORT="${port_input:-$RD_DEFAULT_PORT}"

    _prompt_password

    local image="redis:${RD_IMAGE_TAG}"
    local volume="${RD_CONTAINER_NAME}-data"

    if _docker_container_exists "$RD_CONTAINER_NAME"; then
        gum style \
            --foreground "$YELLOW" --border-foreground "$YELLOW" --border rounded \
            --align center --width 60 --margin "1 2" --padding "1 4" \
            "Container '${RD_CONTAINER_NAME}' already exists."

        local action
        action=$(gum choose \
            "Remove and recreate" \
            "Cancel" \
            --header "What would you like to do?") || true

        case "$action" in
            "Remove and recreate")
                gum spin --spinner dot --title "Removing existing container..." -- \
                    docker rm -f "$RD_CONTAINER_NAME" ;;
            *) warn "Cancelled."; return ;;
        esac
    fi

    gum spin --spinner dot --title "Pulling ${image}..." -- \
        docker pull "$image" \
        || error_exit "Failed to pull image ${image}."

    # Build the redis-server command args: always enable AOF persistence;
    # add requirepass only when a password was provided.
    local server_args=(redis-server --appendonly yes)
    [[ -n "$RD_PASSWORD" ]] && server_args+=(--requirepass "$RD_PASSWORD")

    if ! docker run -d \
        --name "$RD_CONTAINER_NAME" \
        -p "${RD_PORT}:6379" \
        -v "${volume}:/data" \
        --restart unless-stopped \
        "$image" "${server_args[@]}" &>/dev/null; then
        error_exit "Failed to start container '${RD_CONTAINER_NAME}'."
    fi

    info "Waiting for Redis to accept connections..."
    local attempts=0
    until docker exec \
        -e REDISCLI_AUTH="$RD_PASSWORD" \
        "$RD_CONTAINER_NAME" redis-cli ping &>/dev/null 2>&1; do
        attempts=$((attempts + 1))
        if [[ $attempts -ge 30 ]]; then
            warn "Timed out waiting for readiness. Check: docker logs ${RD_CONTAINER_NAME}"
            break
        fi
        sleep 1
    done

    gum style \
        --foreground "$GREEN" --border-foreground "$GREEN" --border rounded \
        --align center --width 60 --margin "1 2" --padding "1 4" \
        "Redis running" \
        "" \
        "Container:  ${RD_CONTAINER_NAME}" \
        "Image:      ${image}" \
        "Port:       localhost:${RD_PORT}" \
        "Volume:     ${volume}" \
        "Auth:       ${RD_PASSWORD:+password set}${RD_PASSWORD:-none (open access)}" \
        "Persistence: AOF enabled"
}

redis_status_docker() {
    header "Redis — Docker Status"

    if ! _docker_container_exists "$RD_CONTAINER_NAME"; then
        warn "Container '${RD_CONTAINER_NAME}' not found."
        return
    fi

    local status image ports
    status=$(docker inspect --format='{{.State.Status}}' "$RD_CONTAINER_NAME" 2>/dev/null)
    image=$(docker inspect --format='{{.Config.Image}}'  "$RD_CONTAINER_NAME" 2>/dev/null)
    ports=$(docker inspect \
        --format='{{range $k,$v := .NetworkSettings.Ports}}{{$k}} -> {{range $v}}{{.HostIP}}:{{.HostPort}}{{end}}  {{end}}' \
        "$RD_CONTAINER_NAME" 2>/dev/null)

    gum style \
        --foreground "$CYAN" --border-foreground "$CYAN" --border rounded \
        --align left --width 60 --margin "1 2" --padding "1 4" \
        "Container: ${RD_CONTAINER_NAME}" \
        "Status:    ${status}" \
        "Image:     ${image}" \
        "Ports:     ${ports}"

    # Show INFO server summary if running
    if _docker_container_running "$RD_CONTAINER_NAME"; then
        echo ""
        gum style --foreground "$CYAN" --bold "── Redis INFO (server) ──"
        _docker_cli INFO server 2>/dev/null \
            | grep -E '^(redis_version|uptime_in_days|connected_clients|used_memory_human|role):' \
            | sed 's/^/  /' || true
        echo ""
        gum style --foreground "$CYAN" --bold "── Redis INFO (keyspace) ──"
        _docker_cli INFO keyspace 2>/dev/null | sed 's/^/  /' || true
    fi

    echo ""
    gum confirm "Press Enter to continue" --affirmative "OK" --negative "" || true
}

redis_connect_docker() {
    header "Connect — Docker (redis-cli)"

    if ! _docker_container_exists "$RD_CONTAINER_NAME"; then
        warn "Container '${RD_CONTAINER_NAME}' not found."
        return
    fi
    if ! _docker_container_running "$RD_CONTAINER_NAME"; then
        warn "Container '${RD_CONTAINER_NAME}' is not running."
        return
    fi

    info "Opening redis-cli inside '${RD_CONTAINER_NAME}'. Type quit or Ctrl+C to exit."
    echo ""

    docker exec -it \
        -e REDISCLI_AUTH="$RD_PASSWORD" \
        "$RD_CONTAINER_NAME" redis-cli
}

redis_list_queues_docker() {
    header "Queue / Key Inspector — Docker"

    if ! _docker_container_exists "$RD_CONTAINER_NAME"; then
        warn "Container '${RD_CONTAINER_NAME}' not found."
        return
    fi
    if ! _docker_container_running "$RD_CONTAINER_NAME"; then
        warn "Container '${RD_CONTAINER_NAME}' is not running."
        return
    fi

    _scan_and_list "docker"
}

redis_uninstall_docker() {
    header "Uninstall Redis — Docker"

    if ! _docker_container_exists "$RD_CONTAINER_NAME"; then
        warn "Container '${RD_CONTAINER_NAME}' not found."
        return
    fi

    local volume="${RD_CONTAINER_NAME}-data"

    gum style \
        --foreground "$RED" --border-foreground "$RED" --border rounded \
        --width 60 --margin "0 2" --padding "1 2" \
        "This will remove container '${RD_CONTAINER_NAME}'." \
        "" \
        "Data volume: ${volume}"

    if ! gum confirm "Remove container '${RD_CONTAINER_NAME}'?"; then
        warn "Cancelled."
        return
    fi

    local remove_volume=false
    gum confirm "Also remove data volume '${volume}'? (all data will be lost)" \
        && remove_volume=true || true

    gum spin --spinner dot --title "Removing container '${RD_CONTAINER_NAME}'..." -- \
        docker rm -f "$RD_CONTAINER_NAME" || true

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
# Kubernetes — install / status / port-forward / connect / list-queues / uninstall
# -----------------------------------------------------------------------------

_k8s_detect_installed() {
    helm status "$RD_HELM_RELEASE" -n "$RD_NAMESPACE" &>/dev/null 2>&1
}

_k8s_ensure_namespace() {
    if kubectl get namespace "$RD_NAMESPACE" &>/dev/null; then
        info "Namespace '${RD_NAMESPACE}' already exists."
    else
        info "Creating namespace '${RD_NAMESPACE}'..."
        kubectl create namespace "$RD_NAMESPACE"
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

# Starts a background port-forward to the Redis master service.
# Prints the PID to stdout; caller must kill it when done.
_k8s_start_port_forward() {
    local port="$1"
    # Bitnami Redis chart creates svc/<release>-master for standalone/replication
    local svc="${RD_HELM_RELEASE}-master"
    # Fallback to plain release name (standalone without -master suffix on older charts)
    if ! kubectl get svc "$svc" -n "$RD_NAMESPACE" &>/dev/null 2>&1; then
        svc="$RD_HELM_RELEASE"
    fi
    kubectl -n "$RD_NAMESPACE" port-forward "svc/${svc}" "${port}:6379" >/dev/null 2>&1 &
    echo $!
}

redis_install_k8s() {
    header "Install Redis — Kubernetes"
    _k8s_check_cluster || return 0

    _prompt_password

    local storage_size
    storage_size=$(gum input \
        --placeholder "8Gi" \
        --header "Persistent volume size (leave empty for '8Gi'):") || true
    storage_size="${storage_size:-8Gi}"

    _k8s_ensure_namespace

    # auth.enabled is automatically true when auth.password is non-empty in Bitnami chart.
    local helm_args=(
        "$RD_HELM_RELEASE" "$RD_HELM_CHART"
        --namespace "$RD_NAMESPACE"
        --set architecture=standalone
        --set master.persistence.size="$storage_size"
        --wait --timeout 5m
    )

    if [[ -n "$RD_PASSWORD" ]]; then
        helm_args+=(--set auth.password="$RD_PASSWORD")
    else
        helm_args+=(--set auth.enabled=false)
    fi

    if _k8s_detect_installed; then
        gum style \
            --foreground "$YELLOW" --border-foreground "$YELLOW" --border rounded \
            --align center --width 60 --margin "1 2" --padding "1 4" \
            "Release '${RD_HELM_RELEASE}' already exists in '${RD_NAMESPACE}'."

        local action
        action=$(gum choose \
            "Upgrade (apply new values)" \
            "Cancel" \
            --header "What would you like to do?") || true

        case "$action" in
            "Upgrade"*) ;;
            *) warn "Cancelled."; return ;;
        esac

        gum spin --spinner dot --title "Upgrading Redis via Helm..." -- \
            helm upgrade "${helm_args[@]}" \
            || error_exit "Helm upgrade failed. Check: kubectl get pods -n ${RD_NAMESPACE}"
    else
        gum spin --spinner dot --title "Installing Redis via Helm (may take a few minutes)..." -- \
            helm install "${helm_args[@]}" \
            || error_exit "Helm install failed. Check: kubectl get pods -n ${RD_NAMESPACE}"
    fi

    gum style \
        --foreground "$GREEN" --border-foreground "$GREEN" --border rounded \
        --align center --width 60 --margin "1 2" --padding "1 4" \
        "Redis installed" \
        "" \
        "Release:    ${RD_HELM_RELEASE}" \
        "Namespace:  ${RD_NAMESPACE}" \
        "Auth:       ${RD_PASSWORD:+password set}${RD_PASSWORD:-none (open access)}" \
        "" \
        "Use 'port-forward', 'connect', or 'list-queues' from the menu."
}

redis_status_k8s() {
    header "Redis — Kubernetes Status"
    _k8s_check_cluster || return 0

    if ! _k8s_detect_installed; then
        warn "Release '${RD_HELM_RELEASE}' not found in namespace '${RD_NAMESPACE}'."
        return
    fi

    gum style --foreground "$CYAN" --bold "── Helm release ──"
    helm status "$RD_HELM_RELEASE" -n "$RD_NAMESPACE" 2>/dev/null || true

    echo ""
    gum style --foreground "$CYAN" --bold "── Pods ──"
    kubectl get pods -n "$RD_NAMESPACE" 2>/dev/null || true

    echo ""
    gum style --foreground "$CYAN" --bold "── Services ──"
    kubectl get svc -n "$RD_NAMESPACE" 2>/dev/null || true

    echo ""
    gum confirm "Press Enter to continue" --affirmative "OK" --negative "" || true
}

redis_port_forward_k8s() {
    header "Redis — Port Forward"
    _k8s_check_cluster || return 0

    if ! _k8s_detect_installed; then
        warn "Release '${RD_HELM_RELEASE}' not found in namespace '${RD_NAMESPACE}'."
        return
    fi

    if pf_is_running "$_RD_PF_PID"; then
        gum style --foreground "$GREEN" --border-foreground "$GREEN" --border rounded \
            --width 60 --margin "0 2" --padding "1 2" \
            "Port-forward is running" \
            "localhost:$(pf_port "$_RD_PF_PID") → ${RD_HELM_RELEASE}:6379" \
            "" \
            "Connect: redis-cli -h 127.0.0.1 -p $(pf_port "$_RD_PF_PID")"
        gum confirm "Stop port-forward?" && pf_stop "$_RD_PF_PID" || true
        return
    fi

    local port_input
    port_input=$(gum input \
        --placeholder "$RD_DEFAULT_PORT" \
        --header "Local port (leave empty for ${RD_DEFAULT_PORT}):") || true
    local port="${port_input:-$RD_DEFAULT_PORT}"

    local pf_pid
    pf_pid=$(_k8s_start_port_forward "$port")
    echo "${pf_pid}:${port}" > "$_RD_PF_PID"

    local attempts=0
    until nc -z 127.0.0.1 "$port" 2>/dev/null || [[ $attempts -ge 20 ]]; do
        sleep 0.25; attempts=$((attempts + 1))
    done

    if ! pf_is_running "$_RD_PF_PID"; then
        warn "Port-forward failed to start. Check kubectl connectivity."
        rm -f "$_RD_PF_PID"; return
    fi

    success "Port-forward started: localhost:${port} → ${RD_HELM_RELEASE}:6379"
    info "Connect: redis-cli -h 127.0.0.1 -p ${port}"
}

redis_connect_k8s() {
    header "Connect — Kubernetes (redis-cli)"
    _k8s_check_cluster || return 0

    if ! _k8s_detect_installed; then
        warn "Release '${RD_HELM_RELEASE}' not found in namespace '${RD_NAMESPACE}'."
        return
    fi

    if ! _ensure_redis_cli; then
        warn "Install redis-cli first, then use 'port-forward' to connect manually."
        return
    fi

    local port_input
    port_input=$(gum input \
        --placeholder "$RD_DEFAULT_PORT" \
        --header "Local port for port-forward (leave empty for ${RD_DEFAULT_PORT}):") || true
    local port="${port_input:-$RD_DEFAULT_PORT}"

    info "Starting port-forward in background..."
    local pf_pid
    pf_pid=$(_k8s_start_port_forward "$port")

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

    info "Opening redis-cli. Type quit or Ctrl+C to exit."
    echo ""

    REDISCLI_AUTH="$RD_PASSWORD" redis-cli -h 127.0.0.1 -p "$port" || true

    kill "$pf_pid" 2>/dev/null || true
    wait "$pf_pid" 2>/dev/null || true
}

redis_list_queues_k8s() {
    header "Queue / Key Inspector — Kubernetes"
    _k8s_check_cluster || return 0

    if ! _k8s_detect_installed; then
        warn "Release '${RD_HELM_RELEASE}' not found in namespace '${RD_NAMESPACE}'."
        return
    fi

    if ! _ensure_redis_cli; then
        warn "Install redis-cli first to use the queue inspector."
        return
    fi

    local port_input
    port_input=$(gum input \
        --placeholder "$RD_DEFAULT_PORT" \
        --header "Local port for port-forward (leave empty for ${RD_DEFAULT_PORT}):") || true
    local port="${port_input:-$RD_DEFAULT_PORT}"

    info "Starting port-forward in background..."
    local pf_pid
    pf_pid=$(_k8s_start_port_forward "$port")

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

    _scan_and_list "local" "$port"

    kill "$pf_pid" 2>/dev/null || true
    wait "$pf_pid" 2>/dev/null || true
}

redis_uninstall_k8s() {
    header "Uninstall Redis — Kubernetes"
    _k8s_check_cluster || return 0

    if ! _k8s_detect_installed; then
        warn "Release '${RD_HELM_RELEASE}' not found in namespace '${RD_NAMESPACE}'."
        return
    fi

    gum style \
        --foreground "$RED" --border-foreground "$RED" --border rounded \
        --width 60 --margin "0 2" --padding "1 2" \
        "This will remove Helm release '${RD_HELM_RELEASE}'" \
        "from namespace '${RD_NAMESPACE}'." \
        "" \
        "PersistentVolumeClaims are NOT removed automatically by Helm." \
        "Delete them manually to fully purge data:" \
        "  kubectl delete pvc --all -n ${RD_NAMESPACE}"

    if ! gum confirm "Uninstall Redis?"; then
        warn "Cancelled."
        return
    fi

    gum spin --spinner dot --title "Running helm uninstall..." -- \
        helm uninstall "$RD_HELM_RELEASE" -n "$RD_NAMESPACE" || true

    if gum confirm "Also delete namespace '${RD_NAMESPACE}' (removes remaining PVCs too)?"; then
        gum spin --spinner dot --title "Deleting namespace '${RD_NAMESPACE}'..." -- \
            kubectl delete namespace "$RD_NAMESPACE" --ignore-not-found || true
        success "Namespace deleted."
    fi

    success "Redis uninstalled."
}

# -----------------------------------------------------------------------------
# Menus
# -----------------------------------------------------------------------------

_docker_menu() {
    local name_input
    name_input=$(gum input \
        --placeholder "redis" \
        --header "Container name for this session (leave empty for 'redis'):") || true
    RD_CONTAINER_NAME="${name_input:-redis}"

    # Load the password for this session so connect / list-queues can use it.
    _prompt_password

    while true; do
        header "Redis — Docker  (${RD_CONTAINER_NAME})"

        local action
        action=$(gum choose \
            "install" \
            "status" \
            "connect" \
            "list-queues" \
            "uninstall" \
            "← back" \
            --header "Select action:") || true

        case "$action" in
            "install")     redis_install_docker ;;
            "status")      redis_status_docker ;;
            "connect")     redis_connect_docker ;;
            "list-queues") redis_list_queues_docker ;;
            "uninstall")   redis_uninstall_docker ;;
            "← back"|"")  return ;;
        esac
    done
}

_k8s_menu() {
    local ns_input
    ns_input=$(gum input \
        --placeholder "$RD_NAMESPACE" \
        --header "Kubernetes namespace for this session (leave empty for '${RD_NAMESPACE}'):") || true
    RD_NAMESPACE="${ns_input:-$RD_NAMESPACE}"

    local release_input
    release_input=$(gum input \
        --placeholder "$RD_HELM_RELEASE" \
        --header "Helm release name (leave empty for '${RD_HELM_RELEASE}'):") || true
    RD_HELM_RELEASE="${release_input:-$RD_HELM_RELEASE}"

    # Load password for this session so connect / list-queues can use it.
    _prompt_password

    while true; do
        header "Redis — Kubernetes  (${TARGET_TYPE}: ${TARGET_CONTEXT} / ns: ${RD_NAMESPACE} / release: ${RD_HELM_RELEASE})"

        local pf_label
        pf_is_running "$_RD_PF_PID" \
            && pf_label="port-forward  [● localhost:$(pf_port "$_RD_PF_PID")]" \
            || pf_label="port-forward  [○ stopped]"

        local action
        action=$(gum choose \
            "install" \
            "status" \
            "$pf_label" \
            "connect" \
            "list-queues" \
            "uninstall" \
            "← back" \
            --header "Select action:") || true

        case "$action" in
            "install")       redis_install_k8s ;;
            "status")        redis_status_k8s ;;
            "port-forward"*) redis_port_forward_k8s ;;
            "connect")       redis_connect_k8s ;;
            "list-queues")   redis_list_queues_k8s ;;
            "uninstall")     redis_uninstall_k8s ;;
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
        "Redis" \
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
