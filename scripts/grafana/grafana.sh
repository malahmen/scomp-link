#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# grafana.sh
# Interactive TUI for installing and managing Grafana.
# Supports Docker (local container) and Kubernetes (official Grafana Helm chart).
# Called by init.sh — expects gum to be available.
# Hard dependencies: docker (Docker target) | kubectl + helm (K8s target).
# Sources: scripts/cluster/cluster.sh for deployment target selection.
#
# Optional datasource provisioning at install time:
#   Prometheus, InfluxDB (v2), or a custom HTTP datasource.
#   Docker:  written to a bind-mounted provisioning directory.
#   K8s:     injected into Helm values via a temp file (-f).
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

GRF_NAMESPACE="grafana"
GRF_HELM_RELEASE="grafana"
GRF_HELM_REPO_NAME="grafana"
GRF_HELM_REPO_URL="https://grafana.github.io/helm-charts"
GRF_HELM_CHART="grafana/grafana"
GRF_DEFAULT_PORT=3000
_GRF_PF_PID="/tmp/scomp-pf-grafana.pid"
GRF_SVC_PORT=80        # Grafana chart service listens on 80 → pod :3000
GRF_DEFAULT_IMAGE_TAG="latest"
GRF_DEFAULT_ADMIN_USER="admin"

# Colours
BLUE=39

# Session state
GRF_CONTAINER_NAME="grafana"
GRF_IMAGE_TAG="$GRF_DEFAULT_IMAGE_TAG"
GRF_ADMIN_USER="$GRF_DEFAULT_ADMIN_USER"
GRF_ADMIN_PASSWORD=""
GRF_PORT=$GRF_DEFAULT_PORT

# -----------------------------------------------------------------------------
# Dependency checks
# -----------------------------------------------------------------------------

check_dependencies() {
    info "Checking dependencies..."
    case "$TARGET_TYPE" in
        docker)   _check_docker ;;
        kind|k8s) _check_kubectl; _ensure_helm "Grafana" ;;
    esac
}

# -----------------------------------------------------------------------------
# Shared config prompts
# -----------------------------------------------------------------------------

_prompt_admin_credentials() {
    GRF_ADMIN_USER=$(gum input \
        --placeholder "$GRF_DEFAULT_ADMIN_USER" \
        --header "Admin username (leave empty for '${GRF_DEFAULT_ADMIN_USER}'):") || true
    GRF_ADMIN_USER="${GRF_ADMIN_USER:-$GRF_DEFAULT_ADMIN_USER}"

    GRF_ADMIN_PASSWORD=$(gum input \
        --placeholder "leave empty to auto-generate" \
        --password \
        --header "Admin password (leave empty to auto-generate):") || true

    if [[ -z "$GRF_ADMIN_PASSWORD" ]]; then
        GRF_ADMIN_PASSWORD=$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 20)
        gum style \
            --foreground "$YELLOW" --border-foreground "$YELLOW" --border rounded \
            --align center --width 60 --margin "1 0" --padding "0 4" \
            "Generated password: ${GRF_ADMIN_PASSWORD}" \
            "Save this — it will not be shown again."
    fi
}

# Prompts the user to select and configure datasources.
# Writes the datasource YAML block to the file path passed as $1.
_prompt_datasources() {
    local out_file="$1"

    if ! gum confirm "Pre-configure datasources now?"; then
        return 0
    fi

    gum style \
        --foreground "$CYAN" --margin "0 2" \
        "Select datasources to add (space to toggle, enter to confirm):"

    local selected
    selected=$(gum choose --no-limit \
        "Prometheus" \
        "InfluxDB v2" \
        "Custom") || true

    [[ -z "$selected" ]] && return 0

    {
        echo "datasources:"
        echo "  datasources.yaml:"
        echo "    apiVersion: 1"
        echo "    datasources:"
    } >> "$out_file"

    local is_default=true   # first datasource becomes the default

    if echo "$selected" | grep -q "Prometheus"; then
        local url
        url=$(gum input \
            --placeholder "http://prometheus-server.monitoring.svc.cluster.local" \
            --header "Prometheus URL:") || true
        url="${url:-http://prometheus-server.monitoring.svc.cluster.local}"

        {
            echo "    - name: Prometheus"
            echo "      type: prometheus"
            echo "      url: ${url}"
            echo "      access: proxy"
            [[ "$is_default" == true ]] && echo "      isDefault: true"
        } >> "$out_file"
        is_default=false
    fi

    if echo "$selected" | grep -q "InfluxDB"; then
        local url org token bucket
        url=$(gum input \
            --placeholder "http://influxdb.influxdb.svc.cluster.local:8086" \
            --header "InfluxDB URL:") || true
        url="${url:-http://influxdb.influxdb.svc.cluster.local:8086}"

        org=$(gum input \
            --placeholder "myorg" \
            --header "InfluxDB organisation:") || true
        org="${org:-myorg}"

        bucket=$(gum input \
            --placeholder "default" \
            --header "InfluxDB default bucket:") || true
        bucket="${bucket:-default}"

        token=$(gum input \
            --placeholder "" \
            --password \
            --header "InfluxDB API token:") || true

        {
            echo "    - name: InfluxDB"
            echo "      type: influxdb"
            echo "      url: ${url}"
            echo "      access: proxy"
            echo "      jsonData:"
            echo "        version: Flux"
            echo "        organization: ${org}"
            echo "        defaultBucket: ${bucket}"
            echo "      secureJsonData:"
            echo "        token: ${token}"
            [[ "$is_default" == true ]] && echo "      isDefault: true"
        } >> "$out_file"
        is_default=false
    fi

    if echo "$selected" | grep -q "Custom"; then
        local name ds_type url
        name=$(gum input \
            --placeholder "My Datasource" \
            --header "Datasource name:") || true
        name="${name:-My Datasource}"

        ds_type=$(gum input \
            --placeholder "prometheus" \
            --header "Datasource type (e.g. prometheus, loki, elasticsearch):") || true
        ds_type="${ds_type:-prometheus}"

        url=$(gum input \
            --placeholder "http://my-service:9090" \
            --header "URL:") || true
        url="${url:-http://my-service:9090}"

        {
            echo "    - name: ${name}"
            echo "      type: ${ds_type}"
            echo "      url: ${url}"
            echo "      access: proxy"
            [[ "$is_default" == true ]] && echo "      isDefault: true"
        } >> "$out_file"
    fi
}

# -----------------------------------------------------------------------------
# Docker helpers
# -----------------------------------------------------------------------------

_docker_container_exists()  { docker inspect "$1" &>/dev/null 2>&1; }
_docker_container_running() {
    [[ "$(docker inspect --format='{{.State.Running}}' "$1" 2>/dev/null)" == "true" ]]
}

# Returns the host-side provisioning directory for the container.
_docker_provisioning_dir() {
    echo "${HOME}/.config/scomp-link/grafana/${GRF_CONTAINER_NAME}/provisioning"
}

# Writes a Grafana provisioning datasources YAML under the container's config dir.
_docker_write_datasources() {
    local prov_dir
    prov_dir=$(_docker_provisioning_dir)
    mkdir -p "${prov_dir}/datasources"

    local ds_file="${prov_dir}/datasources/datasources.yaml"
    # Header expected by Grafana provisioning (not the Helm wrapper structure).
    {
        echo "apiVersion: 1"
        echo "datasources:"
    } > "$ds_file"

    # Re-use the shared prompt but translate the Helm YAML structure to Docker format.
    # We prompt inline here to keep it consistent.
    if ! gum confirm "Pre-configure datasources now?"; then
        rm -f "$ds_file"
        return 0
    fi

    gum style \
        --foreground "$CYAN" --margin "0 2" \
        "Select datasources to add (space to toggle, enter to confirm):"

    local selected
    selected=$(gum choose --no-limit \
        "Prometheus" \
        "InfluxDB v2" \
        "Custom") || true

    if [[ -z "$selected" ]]; then
        rm -f "$ds_file"
        return 0
    fi

    local is_default=true

    if echo "$selected" | grep -q "Prometheus"; then
        local url
        url=$(gum input \
            --placeholder "http://host.docker.internal:9090" \
            --header "Prometheus URL:") || true
        url="${url:-http://host.docker.internal:9090}"

        {
            echo "- name: Prometheus"
            echo "  type: prometheus"
            echo "  url: ${url}"
            echo "  access: proxy"
            [[ "$is_default" == true ]] && echo "  isDefault: true"
        } >> "$ds_file"
        is_default=false
    fi

    if echo "$selected" | grep -q "InfluxDB"; then
        local url org token bucket
        url=$(gum input \
            --placeholder "http://host.docker.internal:8086" \
            --header "InfluxDB URL:") || true
        url="${url:-http://host.docker.internal:8086}"

        org=$(gum input --placeholder "myorg" --header "InfluxDB organisation:") || true
        org="${org:-myorg}"

        bucket=$(gum input --placeholder "default" --header "InfluxDB default bucket:") || true
        bucket="${bucket:-default}"

        token=$(gum input --placeholder "" --password --header "InfluxDB API token:") || true

        {
            echo "- name: InfluxDB"
            echo "  type: influxdb"
            echo "  url: ${url}"
            echo "  access: proxy"
            echo "  jsonData:"
            echo "    version: Flux"
            echo "    organization: ${org}"
            echo "    defaultBucket: ${bucket}"
            echo "  secureJsonData:"
            echo "    token: ${token}"
            [[ "$is_default" == true ]] && echo "  isDefault: true"
        } >> "$ds_file"
        is_default=false
    fi

    if echo "$selected" | grep -q "Custom"; then
        local name ds_type url
        name=$(gum input --placeholder "My Datasource" --header "Datasource name:") || true
        name="${name:-My Datasource}"
        ds_type=$(gum input --placeholder "prometheus" --header "Datasource type:") || true
        ds_type="${ds_type:-prometheus}"
        url=$(gum input --placeholder "http://my-service:9090" --header "URL:") || true
        url="${url:-http://my-service:9090}"

        {
            echo "- name: ${name}"
            echo "  type: ${ds_type}"
            echo "  url: ${url}"
            echo "  access: proxy"
            [[ "$is_default" == true ]] && echo "  isDefault: true"
        } >> "$ds_file"
    fi

    success "Datasource config written to ${ds_file}"
}

# -----------------------------------------------------------------------------
# Docker — install / status / connect / uninstall
# -----------------------------------------------------------------------------

grafana_install_docker() {
    header "Install Grafana — Docker"

    GRF_IMAGE_TAG=$(gum input \
        --placeholder "$GRF_DEFAULT_IMAGE_TAG" \
        --header "Grafana image tag (leave empty for '${GRF_DEFAULT_IMAGE_TAG}'):") || true
    GRF_IMAGE_TAG="${GRF_IMAGE_TAG:-$GRF_DEFAULT_IMAGE_TAG}"

    local port_input
    port_input=$(gum input \
        --placeholder "$GRF_DEFAULT_PORT" \
        --header "Host port (leave empty for ${GRF_DEFAULT_PORT}):") || true
    GRF_PORT="${port_input:-$GRF_DEFAULT_PORT}"

    _prompt_admin_credentials

    local plugins_input
    plugins_input=$(gum input \
        --placeholder "leave empty for no extra plugins" \
        --header "Plugins to pre-install (comma-separated, e.g. grafana-piechart-panel):") || true

    local image="grafana/grafana:${GRF_IMAGE_TAG}"
    local volume="${GRF_CONTAINER_NAME}-data"
    local prov_dir
    prov_dir=$(_docker_provisioning_dir)

    if _docker_container_exists "$GRF_CONTAINER_NAME"; then
        gum style \
            --foreground "$YELLOW" --border-foreground "$YELLOW" --border rounded \
            --align center --width 60 --margin "1 2" --padding "1 4" \
            "Container '${GRF_CONTAINER_NAME}' already exists."

        local action
        action=$(gum choose \
            "Remove and recreate" \
            "Cancel" \
            --header "What would you like to do?") || true

        case "$action" in
            "Remove and recreate")
                gum spin --spinner dot --title "Removing existing container..." -- \
                    docker rm -f "$GRF_CONTAINER_NAME" ;;
            *) warn "Cancelled."; return ;;
        esac
    fi

    _docker_write_datasources

    gum spin --spinner dot --title "Pulling ${image}..." -- \
        docker pull "$image" \
        || error_exit "Failed to pull image ${image}."

    local docker_args=(
        run -d
        --name "$GRF_CONTAINER_NAME"
        -p "${GRF_PORT}:3000"
        -e "GF_SECURITY_ADMIN_USER=${GRF_ADMIN_USER}"
        -e "GF_SECURITY_ADMIN_PASSWORD=${GRF_ADMIN_PASSWORD}"
        -v "${volume}:/var/lib/grafana"
        --restart unless-stopped
    )

    [[ -n "$plugins_input" ]] && docker_args+=(-e "GF_INSTALL_PLUGINS=${plugins_input}")

    # Mount provisioning dir only if datasources were configured
    if [[ -d "${prov_dir}/datasources" ]] && \
       [[ -f "${prov_dir}/datasources/datasources.yaml" ]]; then
        docker_args+=(-v "${prov_dir}:/etc/grafana/provisioning")
    fi

    docker_args+=("$image")

    if ! docker "${docker_args[@]}" &>/dev/null; then
        error_exit "Failed to start container '${GRF_CONTAINER_NAME}'."
    fi

    info "Waiting for Grafana to be ready..."
    local attempts=0
    until curl -sf "http://127.0.0.1:${GRF_PORT}/api/health" &>/dev/null; do
        attempts=$((attempts + 1))
        if [[ $attempts -ge 40 ]]; then
            warn "Timed out waiting for readiness. Check: docker logs ${GRF_CONTAINER_NAME}"
            break
        fi
        sleep 1
    done

    gum style \
        --foreground "$GREEN" --border-foreground "$GREEN" --border rounded \
        --align center --width 60 --margin "1 2" --padding "1 4" \
        "Grafana running" \
        "" \
        "Web UI:   http://localhost:${GRF_PORT}" \
        "Username: ${GRF_ADMIN_USER}" \
        "Volume:   ${volume}"
}

grafana_status_docker() {
    header "Status — Grafana Docker"

    if ! _docker_container_exists "$GRF_CONTAINER_NAME"; then
        warn "Container '${GRF_CONTAINER_NAME}' not found."
        return
    fi

    local status image ports
    status=$(docker inspect --format='{{.State.Status}}' "$GRF_CONTAINER_NAME" 2>/dev/null)
    image=$(docker inspect  --format='{{.Config.Image}}'  "$GRF_CONTAINER_NAME" 2>/dev/null)
    ports=$(docker inspect \
        --format='{{range $k,$v := .NetworkSettings.Ports}}{{$k}} -> {{range $v}}{{.HostIP}}:{{.HostPort}}{{end}}  {{end}}' \
        "$GRF_CONTAINER_NAME" 2>/dev/null)

    gum style \
        --foreground "$CYAN" --border-foreground "$CYAN" --border rounded \
        --align left --width 60 --margin "1 2" --padding "1 4" \
        "Container: ${GRF_CONTAINER_NAME}" \
        "Status:    ${status}" \
        "Image:     ${image}" \
        "Ports:     ${ports}"

    local host_port
    host_port=$(docker inspect \
        --format='{{range $p,$c := .NetworkSettings.Ports}}{{if eq $p "3000/tcp"}}{{(index $c 0).HostPort}}{{end}}{{end}}' \
        "$GRF_CONTAINER_NAME" 2>/dev/null || echo "$GRF_DEFAULT_PORT")

    echo ""
    info "Health check:"
    if curl -sf "http://127.0.0.1:${host_port}/api/health" 2>/dev/null \
            | python3 -m json.tool 2>/dev/null; then
        :
    else
        warn "Grafana not responding — container may still be starting."
    fi

    echo ""
    gum confirm "Press Enter to continue" --affirmative "OK" --negative "" || true
}

grafana_connect_docker() {
    header "Connect — Grafana Docker"

    if ! _docker_container_exists "$GRF_CONTAINER_NAME"; then
        warn "Container '${GRF_CONTAINER_NAME}' not found."
        return
    fi
    if ! _docker_container_running "$GRF_CONTAINER_NAME"; then
        warn "Container '${GRF_CONTAINER_NAME}' is not running."
        return
    fi

    local host_port
    host_port=$(docker inspect \
        --format='{{range $p,$c := .NetworkSettings.Ports}}{{if eq $p "3000/tcp"}}{{(index $c 0).HostPort}}{{end}}{{end}}' \
        "$GRF_CONTAINER_NAME" 2>/dev/null || echo "$GRF_DEFAULT_PORT")

    local admin_user
    admin_user=$(docker inspect \
        --format='{{range .Config.Env}}{{println .}}{{end}}' "$GRF_CONTAINER_NAME" 2>/dev/null \
        | grep '^GF_SECURITY_ADMIN_USER=' | cut -d= -f2 || echo "$GRF_DEFAULT_ADMIN_USER")

    gum style \
        --foreground "$CYAN" --border-foreground "$CYAN" --border rounded \
        --align left --width 60 --margin "1 2" --padding "1 4" \
        "Grafana Web UI → http://localhost:${host_port}" \
        "" \
        "Username: ${admin_user}"

    echo ""
    gum confirm "Press Enter to continue" --affirmative "OK" --negative "" || true
}

grafana_uninstall_docker() {
    header "Uninstall Grafana — Docker"

    if ! _docker_container_exists "$GRF_CONTAINER_NAME"; then
        warn "Container '${GRF_CONTAINER_NAME}' not found."
        return
    fi

    local volume="${GRF_CONTAINER_NAME}-data"
    local prov_dir
    prov_dir=$(_docker_provisioning_dir)

    gum style \
        --foreground "$RED" --border-foreground "$RED" --border rounded \
        --width 60 --margin "0 2" --padding "1 2" \
        "This will remove container '${GRF_CONTAINER_NAME}'." \
        "" \
        "Data volume:         ${volume}" \
        "Provisioning config: ${prov_dir}"

    if ! gum confirm "Remove container '${GRF_CONTAINER_NAME}'?"; then
        warn "Cancelled."
        return
    fi

    local remove_volume=false
    gum confirm "Also remove data volume '${volume}'? (dashboards and settings will be lost)" \
        && remove_volume=true || true

    gum spin --spinner dot --title "Removing container '${GRF_CONTAINER_NAME}'..." -- \
        docker rm -f "$GRF_CONTAINER_NAME" || true

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
    helm status "$GRF_HELM_RELEASE" -n "$GRF_NAMESPACE" &>/dev/null 2>&1
}

_k8s_ensure_namespace() {
    if kubectl get namespace "$GRF_NAMESPACE" &>/dev/null; then
        info "Namespace '${GRF_NAMESPACE}' already exists."
    else
        info "Creating namespace '${GRF_NAMESPACE}'..."
        kubectl create namespace "$GRF_NAMESPACE"
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

grafana_install_k8s() {
    header "Install Grafana — Kubernetes"
    _k8s_check_cluster || return 0

    _ensure_helm_repo "$GRF_HELM_REPO_NAME" "$GRF_HELM_REPO_URL"
    _prompt_admin_credentials

    local storage_size
    storage_size=$(gum input \
        --placeholder "2Gi" \
        --header "Persistent volume size (leave empty for '2Gi'):") || true
    storage_size="${storage_size:-2Gi}"

    local sc_input
    sc_input=$(gum input \
        --placeholder "leave empty for cluster default" \
        --header "StorageClass name (leave empty for cluster default):") || true

    local plugins_input
    plugins_input=$(gum input \
        --placeholder "leave empty for no extra plugins" \
        --header "Plugins to pre-install (comma-separated):") || true

    # Build a temp values file for datasources (and anything else needing YAML structure)
    local values_file
    values_file=$(mktemp /tmp/grafana-values-XXXXXX.yaml)
    # shellcheck disable=SC2064
    trap "rm -f '${values_file}'" RETURN

    _prompt_datasources "$values_file"

    _k8s_ensure_namespace

    local helm_args=(
        "$GRF_HELM_RELEASE" "$GRF_HELM_CHART"
        --namespace "$GRF_NAMESPACE"
        --set "adminUser=${GRF_ADMIN_USER}"
        --set "adminPassword=${GRF_ADMIN_PASSWORD}"
        --set persistence.enabled=true
        --set persistence.size="$storage_size"
        --wait --timeout 5m
    )

    [[ -n "$sc_input" ]]      && helm_args+=(--set "persistence.storageClassName=${sc_input}")
    [[ -n "$plugins_input" ]] && helm_args+=(--set "plugins={${plugins_input}}")

    # Attach datasource values file only if it has content
    if [[ -s "$values_file" ]]; then
        helm_args+=(-f "$values_file")
    fi

    if _k8s_detect_installed; then
        gum style \
            --foreground "$YELLOW" --border-foreground "$YELLOW" --border rounded \
            --align center --width 60 --margin "1 2" --padding "1 4" \
            "Release '${GRF_HELM_RELEASE}' already exists in '${GRF_NAMESPACE}'."

        local action
        action=$(gum choose \
            "Upgrade (apply new values)" \
            "Cancel" \
            --header "What would you like to do?") || true

        case "$action" in
            "Upgrade"*) ;;
            *) warn "Cancelled."; return ;;
        esac

        if ! gum spin --spinner dot --title "Upgrading Grafana..." -- \
            helm upgrade "${helm_args[@]}"; then
            warn "Upgrade failed. Check 'helm status ${GRF_HELM_RELEASE} -n ${GRF_NAMESPACE}'."
            return
        fi
        success "Grafana upgraded."
    else
        if ! gum spin --spinner dot --title "Installing Grafana..." -- \
            helm install "${helm_args[@]}"; then
            warn "Install failed. Check 'helm status ${GRF_HELM_RELEASE} -n ${GRF_NAMESPACE}'."
            return
        fi
        success "Grafana installed."
    fi

    echo ""
    gum style --foreground "$CYAN" \
        "Use 'connect' to open the web UI via port-forward." \
        "Login: ${GRF_ADMIN_USER} / ${GRF_ADMIN_PASSWORD}"
}

grafana_status_k8s() {
    header "Status — Grafana Kubernetes"
    _k8s_check_cluster || return 0

    if ! _k8s_detect_installed; then
        warn "Release '${GRF_HELM_RELEASE}' not found in namespace '${GRF_NAMESPACE}'."
        return
    fi

    info "Helm release:"
    helm status "$GRF_HELM_RELEASE" -n "$GRF_NAMESPACE" 2>/dev/null | head -10
    echo ""

    info "Pods:"
    kubectl get pods -n "$GRF_NAMESPACE" --no-headers 2>/dev/null
    echo ""

    info "Services:"
    kubectl get svc -n "$GRF_NAMESPACE" --no-headers 2>/dev/null
    echo ""

    info "PersistentVolumeClaims:"
    kubectl get pvc -n "$GRF_NAMESPACE" --no-headers 2>/dev/null || true
}

grafana_connect_k8s() {
    header "Connect — Grafana Kubernetes"
    _k8s_check_cluster || return 0

    if ! _k8s_detect_installed; then
        warn "Release '${GRF_HELM_RELEASE}' not found in namespace '${GRF_NAMESPACE}'."
        return
    fi

    if pf_is_running "$_GRF_PF_PID"; then
        gum style --foreground "$GREEN" --border-foreground "$GREEN" --border rounded \
            --width 60 --margin "0 2" --padding "1 2" \
            "Port-forward is running" \
            "http://localhost:$(pf_port "$_GRF_PF_PID")" \
            "" \
            "Username: ${GRF_ADMIN_USER}"
        gum confirm "Stop port-forward?" && pf_stop "$_GRF_PF_PID" || true
        return
    fi

    local port_input
    port_input=$(gum input \
        --placeholder "$GRF_DEFAULT_PORT" \
        --header "Local port (leave empty for ${GRF_DEFAULT_PORT}):") || true
    local port="${port_input:-$GRF_DEFAULT_PORT}"

    local svc="${GRF_HELM_RELEASE}-grafana"
    if ! kubectl get svc "$svc" -n "$GRF_NAMESPACE" &>/dev/null 2>&1; then
        svc="$GRF_HELM_RELEASE"
    fi

    kubectl -n "$GRF_NAMESPACE" port-forward "svc/${svc}" "${port}:${GRF_SVC_PORT}" >/dev/null 2>&1 &
    echo "${!}:${port}" > "$_GRF_PF_PID"

    local attempts=0
    until nc -z 127.0.0.1 "$port" 2>/dev/null || [[ $attempts -ge 20 ]]; do
        sleep 0.25; attempts=$((attempts + 1))
    done

    if ! pf_is_running "$_GRF_PF_PID"; then
        warn "Port-forward failed to start. Check kubectl connectivity."
        rm -f "$_GRF_PF_PID"; return
    fi

    success "Port-forward started: http://localhost:${port}"
    info "Username: ${GRF_ADMIN_USER}"
}

grafana_uninstall_k8s() {
    header "Uninstall Grafana — Kubernetes"
    _k8s_check_cluster || return 0

    if ! _k8s_detect_installed; then
        warn "Release '${GRF_HELM_RELEASE}' not found in namespace '${GRF_NAMESPACE}'."
        return
    fi

    gum style \
        --foreground "$RED" --border-foreground "$RED" --border rounded \
        --width 60 --margin "0 2" --padding "1 2" \
        "This will remove Helm release '${GRF_HELM_RELEASE}'" \
        "from namespace '${GRF_NAMESPACE}'." \
        "" \
        "PersistentVolumeClaims are NOT removed automatically by Helm." \
        "Delete manually to fully purge:" \
        "  kubectl delete pvc --all -n ${GRF_NAMESPACE}"

    if ! gum confirm "Uninstall Grafana?"; then
        warn "Cancelled."
        return
    fi

    gum spin --spinner dot --title "Running helm uninstall..." -- \
        helm uninstall "$GRF_HELM_RELEASE" -n "$GRF_NAMESPACE" || true

    if gum confirm "Also delete namespace '${GRF_NAMESPACE}' (removes remaining PVCs too)?"; then
        gum spin --spinner dot --title "Deleting namespace '${GRF_NAMESPACE}'..." -- \
            kubectl delete namespace "$GRF_NAMESPACE" --ignore-not-found || true
        success "Namespace deleted."
    fi

    success "Grafana uninstalled."
}

# -----------------------------------------------------------------------------
# Menus
# -----------------------------------------------------------------------------

_docker_menu() {
    local name_input
    name_input=$(gum input \
        --placeholder "grafana" \
        --header "Container name for this session (leave empty for 'grafana'):") || true
    GRF_CONTAINER_NAME="${name_input:-grafana}"

    while true; do
        header "Grafana — Docker  (${GRF_CONTAINER_NAME})"

        local action
        action=$(gum choose \
            "install" \
            "status" \
            "connect" \
            "uninstall" \
            "← back" \
            --header "Select action:") || true

        case "$action" in
            "install")   grafana_install_docker ;;
            "status")    grafana_status_docker ;;
            "connect")   grafana_connect_docker ;;
            "uninstall") grafana_uninstall_docker ;;
            "← back"|"") return ;;
        esac
    done
}

_k8s_menu() {
    local ns_input
    ns_input=$(gum input \
        --placeholder "$GRF_NAMESPACE" \
        --header "Kubernetes namespace (leave empty for '${GRF_NAMESPACE}'):") || true
    GRF_NAMESPACE="${ns_input:-$GRF_NAMESPACE}"

    local release_input
    release_input=$(gum input \
        --placeholder "$GRF_HELM_RELEASE" \
        --header "Helm release name (leave empty for '${GRF_HELM_RELEASE}'):") || true
    GRF_HELM_RELEASE="${release_input:-$GRF_HELM_RELEASE}"

    while true; do
        header "Grafana — ${TARGET_TYPE}: ${TARGET_CONTEXT} / ns: ${GRF_NAMESPACE} / release: ${GRF_HELM_RELEASE}"

        local pf_label
        pf_is_running "$_GRF_PF_PID" \
            && pf_label="connect  [● localhost:$(pf_port "$_GRF_PF_PID")]" \
            || pf_label="connect  [○ stopped]"

        local action
        action=$(gum choose \
            "install" \
            "status" \
            "$pf_label" \
            "uninstall" \
            "← back" \
            --header "Select action:") || true

        case "$action" in
            "install")   grafana_install_k8s ;;
            "status")    grafana_status_k8s ;;
            "connect"*)  grafana_connect_k8s ;;
            "uninstall") grafana_uninstall_k8s ;;
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
        "Grafana" \
        "Observability  ·  Docker  ·  Kubernetes"

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
