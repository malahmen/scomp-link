#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# kind.sh
# Interactive TUI for creating and managing kind Kubernetes clusters.
# Called by init.sh — expects gum to already be available.
# Dependencies: gum (managed by init.sh), mise, docker
#               kind and kubectl are installed automatically via mise if missing.
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

# -----------------------------------------------------------------------------
# Constants
# -----------------------------------------------------------------------------

GH_KIND_API="https://api.github.com/repos/kubernetes-sigs/kind/releases"
DEFAULT_CLUSTER_NAME="kind"
WORKER_COUNT=0 # Fixed - more workers consume significant memory for no POC benefit
LOG_DEFAULT_BASE="./kind-logs"

# Suggested port mappings: "label|host_port|container_port"
# Host ports are all unique to avoid conflicts regardless of combination selected.
SUGGESTED_PORTS=(
    "HTTP                |  80  |  80"
    "HTTPS               | 443  | 443"
    "Argo Workflows      |2746  |2746"
    "ArgoCD              |8080  |8080"
    "Harbor registry     |8081  |  80"
    "Harbor HTTPS        |8443  | 443"
    "Grafana             |3000  |3000"
    "Astro Starlight     |4321  |4321"
    "Generic NodePort    |30000 |30000"
    "Generic HTTP alt    |8888  |8888"
)

# Script-level globals set during create flow
CLUSTER_NAME=""
KIND_VERSION=""
PORT_MAPPINGS=()
CONFIG_FILE=""

# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------

_fatal() { printf "\033[0;31m[ERROR] %s\033[0m\n" "$*" >&2; exit 1; }

# -----------------------------------------------------------------------------
# Dependency checks — installs kind and kubectl via mise if missing
# -----------------------------------------------------------------------------

check_dependencies() {
    gum log --level info "Checking dependencies..."

    if ! command -v docker &>/dev/null; then
        gum log --level error "docker is not installed or not in PATH."
        gum log --level error "Install Docker Desktop: https://www.docker.com/products/docker-desktop/"
        exit 1
    fi

    if ! docker info &>/dev/null; then
        gum log --level error "Docker daemon is not running. Start Docker Desktop and retry."
        exit 1
    fi
    gum log --level info "Docker found and running."

    if ! command -v mise &>/dev/null; then
        gum log --level error "mise is not installed or not in PATH."
        gum log --level error "Run setup.sh first to bootstrap mise."
        exit 1
    fi
    gum log --level info "mise found: $(mise --version 2>/dev/null | head -1)"

    ensure_kind
    ensure_kubectl
}

ensure_kind() {
    if command -v kind &>/dev/null; then
        gum log --level info "kind found: $(kind version)"
        return
    fi

    gum log --level info "kind not found — installing via mise..."
    if ! gum spin --spinner dot --title "Installing kind via mise..." -- \
        mise install kind@latest; then
        gum log --level error "Failed to install kind via mise."
        exit 1
    fi

    export PATH="$HOME/.local/share/mise/shims:$PATH"

    if ! command -v kind &>/dev/null; then
        gum log --level error "kind installed but not found in PATH. Check mise shims configuration."
        exit 1
    fi
    gum log --level info "kind installed: $(kind version)"
}

ensure_kubectl() {
    if command -v kubectl &>/dev/null; then
        gum log --level info "kubectl found: $(kubectl version --client 2>/dev/null | head -1)"
        return
    fi

    gum log --level info "kubectl not found — installing via mise..."
    if ! gum spin --spinner dot --title "Installing kubectl via mise..." -- \
        mise install kubectl@latest; then
        gum log --level error "Failed to install kubectl via mise."
        exit 1
    fi

    export PATH="$HOME/.local/share/mise/shims:$PATH"

    if ! command -v kubectl &>/dev/null; then
        gum log --level error "kubectl installed but not found in PATH. Check mise shims configuration."
        exit 1
    fi
    gum log --level info "kubectl installed: $(kubectl version --client 2>/dev/null | head -1)"
}

# -----------------------------------------------------------------------------
# Cluster list
# -----------------------------------------------------------------------------

get_clusters() {
    # Returns newline-separated cluster names, empty string if none
    kind get clusters 2>/dev/null || true
}

# =============================================================================
# CREATE FLOW
# =============================================================================

create_select_name() {
    local input
    input=$(gum input \
        --placeholder "${DEFAULT_CLUSTER_NAME}" \
        --header "Cluster name (leave empty for default '${DEFAULT_CLUSTER_NAME}'):") || true

    CLUSTER_NAME="${input:-${DEFAULT_CLUSTER_NAME}}"

    if ! echo "${CLUSTER_NAME}" | grep -qE '^[a-z0-9][a-z0-9-]*[a-z0-9]$|^[a-z0-9]$'; then
        gum log --level error "Invalid cluster name '${CLUSTER_NAME}'. Use lowercase letters, numbers, and hyphens only."
        return 1
    fi

    gum log --level info "Cluster name: ${CLUSTER_NAME}"
}

create_check_existing() {
    if ! kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
        return 0  # No conflict, proceed
    fi

    gum style \
        --foreground 214 --border-foreground 214 --border rounded \
        --align center --width 60 --margin "1 2" --padding "1 4" \
        "Cluster '${CLUSTER_NAME}' already exists"

    local action
    action=$(gum choose \
        "Delete and recreate" \
        "Cancel" \
        --header "What would you like to do?") || true

    case "$action" in
        "Delete and recreate")
            gum log --level warn "Deleting existing cluster '${CLUSTER_NAME}'..."
            gum spin --spinner dot --title "Deleting cluster..." -- \
                kind delete cluster --name "${CLUSTER_NAME}"
            gum log --level info "Cluster deleted."
            ;;
        "Cancel"|"")
            gum log --level warn "Create cancelled."
            return 1
            ;;
    esac
}

create_select_version() {
    gum log --level info "Fetching available kind releases from GitHub..."

    local versions
    if ! versions=$(gum spin --spinner dot --title "Fetching release list..." -- \
        bash -c "curl -fsSL '${GH_KIND_API}?per_page=20' 2>/dev/null \
            | grep '\"tag_name\"' \
            | sed 's/.*\"tag_name\": *\"\(.*\)\".*/\1/' \
            | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+\$'"); then
        gum log --level warn "Failed to fetch kind release list. Using latest."
        KIND_VERSION="latest"
        return
    fi

    if [ -z "$versions" ]; then
        gum log --level warn "No stable releases found. Using latest."
        KIND_VERSION="latest"
        return
    fi

    KIND_VERSION=$(echo "$versions" | gum choose \
        --header "Select kind version (each bundles a specific Kubernetes version):" \
        --height 10) || true

    if [ -z "$KIND_VERSION" ]; then
        gum log --level warn "No version selected. Aborting."
        return 1
    fi

    gum log --level info "Selected kind version: ${KIND_VERSION}"

    if ! gum spin --spinner dot --title "Installing kind ${KIND_VERSION} via mise..." -- \
        mise install "kind@${KIND_VERSION#v}"; then
        gum log --level warn "Could not install kind ${KIND_VERSION}, falling back to current."
    fi
}

create_select_ports() {
    PORT_MAPPINGS=()

    gum style \
        --foreground 99 --border-foreground 99 --border normal \
        --width 60 --margin "0 2" --padding "0 2" \
        "Port mappings are set at cluster creation and cannot be changed afterwards." \
        "Select all ports you may need for apps you plan to run in this cluster."

    local display_items=()
    for entry in "${SUGGESTED_PORTS[@]}"; do
        local label host_port container_port
        label=$(echo "$entry" | cut -d'|' -f1 | xargs)
        host_port=$(echo "$entry" | cut -d'|' -f2 | xargs)
        container_port=$(echo "$entry" | cut -d'|' -f3 | xargs)
        display_items+=("${label}  (localhost:${host_port} → container:${container_port})")
    done

    local selected
    selected=$(printf '%s\n' "${display_items[@]}" | gum choose \
        --no-limit \
        --header "Select port mappings (Space to select, Enter to confirm):") || true

    if [ -z "$selected" ]; then
        gum log --level warn "No suggested ports selected."
    else
        while IFS= read -r line; do
            for entry in "${SUGGESTED_PORTS[@]}"; do
                local label host_port container_port
                label=$(echo "$entry" | cut -d'|' -f1 | xargs)
                host_port=$(echo "$entry" | cut -d'|' -f2 | xargs)
                container_port=$(echo "$entry" | cut -d'|' -f3 | xargs)
                if [[ "$line" == "${label}"* ]]; then
                    PORT_MAPPINGS+=("${host_port}:${container_port}")
                fi
            done
        done <<< "$selected"
    fi

    while gum confirm "Add a custom port mapping?"; do
        local host_port container_port
        host_port=$(gum input --placeholder "Host port (e.g. 9090)" --header "Host port (localhost side):") || true
        container_port=$(gum input --placeholder "Container port (e.g. 9090)" --header "Container port (inside cluster):") || true

        if [[ -n "$host_port" && -n "$container_port" ]]; then
            PORT_MAPPINGS+=("${host_port}:${container_port}")
            gum log --level info "Added mapping: localhost:${host_port} → container:${container_port}"
        else
            gum log --level warn "Skipping empty port mapping."
        fi
    done

    if [ ${#PORT_MAPPINGS[@]} -eq 0 ]; then
        gum log --level warn "No port mappings configured. Access will require port-forward."
    else
        gum log --level info "Port mappings configured: ${PORT_MAPPINGS[*]}"
    fi

    create_check_port_conflicts
}

create_check_port_conflicts() {
    [ ${#PORT_MAPPINGS[@]} -eq 0 ] && return

    local conflicting=()

    for mapping in "${PORT_MAPPINGS[@]}"; do
        local host_port
        host_port=$(echo "$mapping" | cut -d':' -f1)

        local in_use=""
        if command -v lsof &>/dev/null; then
            in_use=$(lsof -iTCP:"${host_port}" -sTCP:LISTEN -n -P 2>/dev/null \
                | awk 'NR>1 {print $1 " (PID " $2 ")"}' | head -1 || true)
        elif command -v ss &>/dev/null; then
            in_use=$(ss -tlnp 2>/dev/null \
                | awk -v port=":${host_port}" '$4 ~ port {match($6,/pid=([0-9]+)/,a); print "PID " a[1]}' \
                | head -1 || true)
        fi

        if [ -n "$in_use" ]; then
            conflicting+=("${mapping}|${in_use}")
            gum log --level warn "Port ${host_port} already in use by: ${in_use}"
        fi
    done

    [ ${#conflicting[@]} -eq 0 ] && return

    gum style \
        --foreground 196 --border-foreground 196 --border rounded \
        --width 60 --margin "0 2" --padding "0 2" \
        "Port conflicts detected." \
        "These host ports are already bound on your machine." \
        "Remove them or kind cluster creation will fail."

    local conflict_labels=()
    for entry in "${conflicting[@]+"${conflicting[@]}"}"; do
        local mapping process host_port container_port
        mapping=$(echo "$entry" | cut -d'|' -f1)
        process=$(echo "$entry" | cut -d'|' -f2)
        host_port=$(echo "$mapping" | cut -d':' -f1)
        container_port=$(echo "$mapping" | cut -d':' -f2)
        conflict_labels+=("localhost:${host_port} → container:${container_port}  [${process}]")
    done

    local to_keep
    to_keep=$(printf '%s\n' "${conflict_labels[@]+"${conflict_labels[@]}"}" | gum choose \
        --no-limit \
        --header "Conflicting ports listed below. Select any you want to KEEP (leave empty to remove all):") || true

    local conflict_ports=()
    for entry in "${conflicting[@]}"; do
        local m
        m=$(echo "$entry" | cut -d'|' -f1)
        conflict_ports+=("$(echo "$m" | cut -d':' -f1)")
    done

    local cleaned=()
    for mapping in "${PORT_MAPPINGS[@]}"; do
        local host_port container_port
        host_port=$(echo "$mapping" | cut -d':' -f1)
        container_port=$(echo "$mapping" | cut -d':' -f2)
        local label="localhost:${host_port} → container:${container_port}"

        local is_conflict=false
        for cp in "${conflict_ports[@]+"${conflict_ports[@]}"}"; do
            [ "$cp" = "$host_port" ] && is_conflict=true && break
        done

        if $is_conflict; then
            if echo "$to_keep" | grep -q "^${label}"; then
                gum log --level warn "Keeping conflicting mapping as requested: ${label}"
                cleaned+=("$mapping")
            else
                gum log --level warn "Removed conflicting mapping: ${label}"
            fi
        else
            cleaned+=("$mapping")
        fi
    done

    PORT_MAPPINGS=("${cleaned[@]+"${cleaned[@]}"}")

    if [ ${#PORT_MAPPINGS[@]} -eq 0 ]; then
        gum log --level warn "No port mappings remaining after conflict resolution. Access will require port-forward."
    else
        gum log --level info "Final port mappings: ${PORT_MAPPINGS[*]}"
    fi
}

create_generate_config() {
    CONFIG_FILE=$(mktemp /tmp/kind-config-XXXXXX.yaml)

    cat > "${CONFIG_FILE}" <<EOF
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: ${CLUSTER_NAME}
nodes:
  - role: control-plane
EOF

    if [ ${#PORT_MAPPINGS[@]} -gt 0 ]; then
        echo "    extraPortMappings:" >> "${CONFIG_FILE}"
        for mapping in "${PORT_MAPPINGS[@]}"; do
            local host_port container_port
            host_port=$(echo "$mapping" | cut -d':' -f1)
            container_port=$(echo "$mapping" | cut -d':' -f2)
            cat >> "${CONFIG_FILE}" <<EOF
      - containerPort: ${container_port}
        hostPort: ${host_port}
        protocol: TCP
EOF
        done
    fi

    for _ in $(seq 1 "${WORKER_COUNT}"); do
        echo "  - role: worker" >> "${CONFIG_FILE}"
    done

    gum log --level info "Generated cluster config:"
    while IFS= read -r line; do
        gum log --level info "  ${line}"
    done < "${CONFIG_FILE}"
}

create_run() {
    gum log --level info "Creating kind cluster '${CLUSTER_NAME}'..."
    gum log --level warn "This may take a few minutes on first run — kind pulls node images from Docker Hub."

    # No gum spin — kind prints progress to stderr, swallowing it makes failures impossible to diagnose
    if ! kind create cluster --config "${CONFIG_FILE}"; then
        gum log --level error "kind cluster creation failed. See output above for details."
        rm -f "${CONFIG_FILE}"
        return 1
    fi

    rm -f "${CONFIG_FILE}"
    gum log --level info "Cluster '${CLUSTER_NAME}' created."
}

create_verify() {
    gum log --level info "Verifying cluster..."

    if ! gum spin --spinner dot --title "Checking cluster health..." -- \
        kubectl cluster-info --context "kind-${CLUSTER_NAME}" &>/dev/null; then
        gum log --level error "Cluster created but not reachable. Check Docker and kind status."
        return 1
    fi

    local nodes
    nodes=$(kubectl get nodes --context "kind-${CLUSTER_NAME}" --no-headers 2>/dev/null \
        | awk '{print $1 "\t" $2}')

    gum style \
        --foreground 212 --border-foreground 212 --border rounded \
        --align center --width 60 --margin "1 2" --padding "1 4" \
        "Cluster '${CLUSTER_NAME}' ready"

    gum log --level info "Nodes:"
    echo "$nodes" | while IFS=$'\t' read -r node status; do
        gum log --level info "  ${node}  →  ${status}"
    done

    gum log --level info "Active context: kind-${CLUSTER_NAME}"

    if [ ${#PORT_MAPPINGS[@]} -gt 0 ]; then
        gum log --level info "Configured port mappings:"
        for mapping in "${PORT_MAPPINGS[@]}"; do
            local host_port container_port
            host_port=$(echo "$mapping" | cut -d':' -f1)
            container_port=$(echo "$mapping" | cut -d':' -f2)
            gum log --level info "  localhost:${host_port} → cluster node:${container_port}"
        done
        gum log --level warn "Note: on macOS/Windows with Docker Desktop, port mappings are reachable via localhost only — not via Docker bridge IPs."
    fi
}

# Orchestrates the full create flow — returns to main loop on completion or cancellation
create_cluster_flow() {
    gum style \
        --foreground 99 --border-foreground 99 --border rounded \
        --align center --width 60 --margin "1 2" --padding "1 2" \
        'Create New Cluster'

    # Reset globals for this create run
    CLUSTER_NAME=""
    KIND_VERSION=""
    PORT_MAPPINGS=()
    CONFIG_FILE=""

    create_select_name      || return
    create_check_existing   || return
    create_select_version   || return
    create_select_ports
    create_generate_config
    create_run              || return
    create_verify
}

# =============================================================================
# MANAGE ACTIONS — single cluster
# =============================================================================

action_get_nodes() {
    local cluster="$1"
    gum log --level info "Nodes in cluster '${cluster}':"
    kubectl get nodes --context "kind-${cluster}" -o wide
}

action_get_kubeconfig() {
    local cluster="$1"
    gum log --level info "kubeconfig for cluster '${cluster}':"
    kind get kubeconfig --name "${cluster}"
}

action_export_kubeconfig() {
    local cluster="$1"
    local default_path="$HOME/.kube/config"

    gum log --level info "Leave empty to merge into default kubeconfig, or enter a custom path."

    local path
    path=$(gum input \
        --placeholder "${default_path}" \
        --header "Export kubeconfig to:") || true
    path="${path:-${default_path}}"

    local dir
    dir=$(dirname "$path")
    if [ ! -d "$dir" ]; then
        if gum confirm "Directory '${dir}' does not exist. Create it?"; then
            mkdir -p "$dir"
            gum log --level info "Created directory: ${dir}"
        else
            gum log --level warn "Export cancelled."
            return
        fi
    fi

    gum spin --spinner dot --title "Exporting kubeconfig for '${cluster}'..." -- \
        kind export kubeconfig --name "${cluster}" --kubeconfig "${path}"
    gum log --level info "kubeconfig exported to: ${path}"
}

action_export_logs() {
    local cluster="$1"
    local timestamp
    timestamp=$(date +%Y%m%d-%H%M%S)
    local default_path="${LOG_DEFAULT_BASE}/${cluster}-${timestamp}"

    gum log --level info "kind exports cluster logs (API server, kubelet, containers, etc.)"

    local path
    path=$(gum input \
        --placeholder "${default_path}" \
        --header "Export logs to (leave empty for default):") || true
    path="${path:-${default_path}}"

    mkdir -p "${path}"

    gum spin --spinner dot --title "Exporting logs for '${cluster}'..." -- \
        kind export logs "${path}" --name "${cluster}"
    gum log --level info "Logs exported to: ${path}"
}

action_load_image() {
    local cluster="$1"

    local image
    image=$(gum input \
        --placeholder "e.g. myapp:latest" \
        --header "Docker image to load into cluster '${cluster}':") || true

    if [ -z "$image" ]; then
        gum log --level warn "No image specified. Cancelled."
        return
    fi

    if ! docker image inspect "${image}" &>/dev/null; then
        gum log --level error "Image '${image}' not found in local Docker. Pull or build it first."
        return
    fi

    gum spin --spinner dot --title "Loading '${image}' into '${cluster}'..." -- \
        kind load docker-image "${image}" --name "${cluster}"
    gum log --level info "Image '${image}' loaded into cluster '${cluster}'."
}

action_use_context() {
    local cluster="$1"
    kubectl config use-context "kind-${cluster}"
    gum log --level info "Active context set to: kind-${cluster}"
}

action_delete_cluster() {
    local cluster="$1"

    gum style \
        --foreground 196 --border-foreground 196 --border rounded \
        --width 60 --margin "0 2" --padding "0 2" \
        "You are about to delete cluster '${cluster}'." \
        "This will remove all containers, data, and the kubeconfig context." \
        "This cannot be undone."

    if ! gum confirm "Delete cluster '${cluster}'?"; then
        gum log --level warn "Delete cancelled."
        return
    fi

    gum spin --spinner dot --title "Deleting cluster '${cluster}'..." -- \
        kind delete cluster --name "${cluster}"
    gum log --level info "Cluster '${cluster}' deleted."
}

# =============================================================================
# MANAGE ACTIONS — all clusters
# =============================================================================

action_export_kubeconfig_all() {
    local clusters=("$@")
    local default_path="$HOME/.kube/config"

    gum log --level info "All cluster contexts will be merged into the kubeconfig."

    local path
    path=$(gum input \
        --placeholder "${default_path}" \
        --header "Export all kubeconfigs to (leave empty for default):") || true
    path="${path:-${default_path}}"

    local dir
    dir=$(dirname "$path")
    if [ ! -d "$dir" ]; then
        if gum confirm "Directory '${dir}' does not exist. Create it?"; then
            mkdir -p "$dir"
        else
            gum log --level warn "Export cancelled."
            return
        fi
    fi

    for cluster in "${clusters[@]}"; do
        gum spin --spinner dot --title "Exporting kubeconfig for '${cluster}'..." -- \
            kind export kubeconfig --name "${cluster}" --kubeconfig "${path}"
        gum log --level info "  '${cluster}' → ${path}"
    done

    gum log --level info "All kubeconfigs exported to: ${path}"
}

action_export_logs_all() {
    local clusters=("$@")
    local timestamp
    timestamp=$(date +%Y%m%d-%H%M%S)
    local default_base="${LOG_DEFAULT_BASE}/all-${timestamp}"

    gum log --level info "Logs for each cluster will be saved in separate subdirectories."

    local base
    base=$(gum input \
        --placeholder "${default_base}" \
        --header "Base directory for log export (leave empty for default):") || true
    base="${base:-${default_base}}"

    mkdir -p "${base}"

    for cluster in "${clusters[@]}"; do
        local cluster_path="${base}/${cluster}"
        mkdir -p "${cluster_path}"
        gum spin --spinner dot --title "Exporting logs for '${cluster}'..." -- \
            kind export logs "${cluster_path}" --name "${cluster}"
        gum log --level info "  '${cluster}' → ${cluster_path}"
    done

    gum log --level info "All logs exported under: ${base}"
}

action_load_image_all() {
    local clusters=("$@")

    local image
    image=$(gum input \
        --placeholder "e.g. myapp:latest" \
        --header "Docker image to load into ALL clusters:") || true

    if [ -z "$image" ]; then
        gum log --level warn "No image specified. Cancelled."
        return
    fi

    if ! docker image inspect "${image}" &>/dev/null; then
        gum log --level error "Image '${image}' not found in local Docker. Pull or build it first."
        return
    fi

    for cluster in "${clusters[@]}"; do
        gum spin --spinner dot --title "Loading '${image}' into '${cluster}'..." -- \
            kind load docker-image "${image}" --name "${cluster}"
        gum log --level info "  '${image}' → '${cluster}'"
    done

    gum log --level info "Image '${image}' loaded into all clusters."
}

action_delete_all_clusters() {
    local clusters=("$@")

    gum style \
        --foreground 196 --border-foreground 196 --border rounded \
        --width 60 --margin "0 2" --padding "1 2" \
        "⚠  WARNING: You are about to delete ALL kind clusters." \
        "" \
        "Clusters to be deleted:" \
        "$(printf '  • %s\n' "${clusters[@]}")" \
        "" \
        "All containers, data, and kubeconfig contexts will be removed." \
        "This cannot be undone."

    if ! gum confirm "Are you sure you want to delete ALL clusters?"; then
        gum log --level warn "Delete all cancelled."
        return
    fi

    if ! gum confirm "Last chance — really delete everything?"; then
        gum log --level warn "Delete all cancelled."
        return
    fi

    for cluster in "${clusters[@]}"; do
        gum spin --spinner dot --title "Deleting cluster '${cluster}'..." -- \
            kind delete cluster --name "${cluster}"
        gum log --level info "Deleted: '${cluster}'"
    done

    gum log --level info "All clusters deleted."
}

# =============================================================================
# MENUS
# =============================================================================

single_cluster_menu() {
    local cluster="$1"

    while true; do
        local current_ctx active_marker
        current_ctx=$(kubectl config current-context 2>/dev/null || true)
        if [[ "$current_ctx" == "kind-${cluster}" ]]; then
            active_marker=" (active)"
        else
            active_marker=""
        fi

        gum style \
            --foreground 99 --border-foreground 99 --border normal \
            --width 60 --margin "0 2" --padding "0 2" \
            "Cluster: ${cluster}${active_marker}"

        local action
        action=$(gum choose \
            "set as active context" \
            "get nodes" \
            "get kubeconfig" \
            "export kubeconfig" \
            "export logs" \
            "load image" \
            "delete cluster" \
            "← back" \
            --header "Select action:") || true

        case "$action" in
            "set as active context") action_use_context       "${cluster}" ;;
            "get nodes")             action_get_nodes         "${cluster}" ;;
            "get kubeconfig")        action_get_kubeconfig    "${cluster}" ;;
            "export kubeconfig")     action_export_kubeconfig "${cluster}" ;;
            "export logs")           action_export_logs       "${cluster}" ;;
            "load image")            action_load_image        "${cluster}" ;;
            "delete cluster")
                action_delete_cluster "${cluster}"
                return  # Cluster may no longer exist — back to main
                ;;
            "← back"|"")
                return
                ;;
        esac

        # Pause after output-heavy operations so user can read before menu redraws
        case "$action" in
            "get nodes"|"get kubeconfig")
                gum confirm "Press Enter to continue..." --affirmative "Continue" --negative "" || true
                ;;
        esac
    done
}

all_clusters_menu() {
    local clusters=("$@")

    while true; do
        gum style \
            --foreground 214 --border-foreground 214 --border normal \
            --width 60 --margin "0 2" --padding "0 2" \
            "All clusters selected (${#clusters[@]}): $(printf '%s  ' "${clusters[@]}")"

        local action
        action=$(gum choose \
            "export kubeconfig (all)" \
            "export logs (all)" \
            "load image (all)" \
            "delete all clusters" \
            "← back" \
            --header "Select action:") || true

        case "$action" in
            "export kubeconfig (all)") action_export_kubeconfig_all "${clusters[@]}" ;;
            "export logs (all)")       action_export_logs_all       "${clusters[@]}" ;;
            "load image (all)")        action_load_image_all        "${clusters[@]}" ;;
            "delete all clusters")
                action_delete_all_clusters "${clusters[@]}"
                return  # All clusters gone — back to main
                ;;
            "← back"|"")
                return
                ;;
        esac
    done
}

# =============================================================================
# MAIN LOOP
# =============================================================================

main() {
    check_dependencies

    gum style \
        --foreground 99 --border-foreground 99 --border double \
        --align center --width 60 --margin "1 2" --padding "1 4" \
        'kind Cluster Manager'

    while true; do
        local cluster_list
        cluster_list=$(get_clusters)

        if [ -z "$cluster_list" ]; then
            gum style \
                --foreground 214 --border-foreground 214 --border rounded \
                --align center --width 60 --margin "1 2" --padding "1 2" \
                "No kind clusters found."

            local choice
            choice=$(gum choose \
                "Create new cluster" \
                "Refresh" \
                "Quit" \
                --header "What would you like to do?") || true

            case "$choice" in
                "Create new cluster") create_cluster_flow ;;
                "Refresh")            continue ;;
                "Quit"|"")            break ;;
            esac
            continue
        fi

        # Build menu: create option + individual clusters + select all + quit
        local menu_items=("── create new cluster ──")
        while IFS= read -r cluster; do
            menu_items+=("$cluster")
        done <<< "$cluster_list"
        menu_items+=("── select all ──")
        menu_items+=("── quit ──")

        local selection
        selection=$(printf '%s\n' "${menu_items[@]}" | gum choose \
            --header "kind clusters ($(echo "$cluster_list" | wc -l | tr -d ' ') running):") || true

        case "$selection" in
            "── create new cluster ──")
                create_cluster_flow
                ;;
            "── select all ──")
                local all_clusters=()
                while IFS= read -r c; do
                    all_clusters+=("$c")
                done <<< "$cluster_list"
                all_clusters_menu "${all_clusters[@]}"
                ;;
            "── quit ──"|"")
                break
                ;;
            *)
                if echo "$cluster_list" | grep -q "^${selection}$"; then
                    single_cluster_menu "$selection"
                else
                    gum log --level warn "Cluster '${selection}' no longer exists."
                fi
                ;;
        esac
    done

    gum style \
        --foreground 99 --border-foreground 99 --border rounded \
        --align center --width 60 --margin "1 2" --padding "1 2" \
        'Bye!'
}

# =============================================================================
# build node-image — excluded for now, left for future reference
# =============================================================================
# action_build_node_image() {
#     local dockerfile_path
#     dockerfile_path=$(gum input \
#         --placeholder "./Dockerfile" \
#         --header "Path to Dockerfile for node image:") || true
#
#     if [ -z "$dockerfile_path" ] || [ ! -f "$dockerfile_path" ]; then
#         gum log --level error "Dockerfile not found: ${dockerfile_path}"
#         return
#     fi
#
#     local image_tag
#     image_tag=$(gum input \
#         --placeholder "kindest/node:custom" \
#         --header "Image tag for the built node image:") || true
#     image_tag="${image_tag:-kindest/node:custom}"
#
#     gum spin --spinner dot --title "Building node image (this may take a while)..." -- \
#         kind build node-image --image "${image_tag}" "$(dirname "$dockerfile_path")"
#     gum log --level info "Node image built: ${image_tag}"
# }

main "$@"