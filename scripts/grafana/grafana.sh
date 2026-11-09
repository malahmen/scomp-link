#!/usr/bin/env bash
# description: Grafana with datasource provisioning (Docker/K8s)
# Standalone export (export.sh): tools the slimmed setup.sh pre-installs.
# export-setup: kubectl helm
# -----------------------------------------------------------------------------
# grafana.sh
# Interactive TUI for installing and managing Grafana.
# Supports Docker (local container) and Kubernetes (official Grafana Helm chart).
# Called by init.sh — expects gum to be available.
# Hard dependencies: docker (Docker target) | kubectl + helm (K8s target).
# Sources: scripts/_common/cluster.sh (deployment target selection), ui.sh, deps.sh, portforward.sh
#
# Optional datasource provisioning at install time:
#   Prometheus, InfluxDB (v2), or a custom HTTP datasource.
#   Docker:  written to a bind-mounted provisioning directory.
#   K8s:     injected into Helm values via a temp file (-f).
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

GRF_NAMESPACE="grafana"
GRF_HELM_RELEASE="grafana"
GRF_HELM_REPO_NAME="grafana"
GRF_HELM_REPO_URL="https://grafana.github.io/helm-charts"
GRF_HELM_CHART="grafana/grafana"
GRF_DEFAULT_PORT=3000
_GRF_PF_PID="$(pf_file grafana)"
GRF_SVC_PORT=80        # Grafana chart service listens on 80 → pod :3000
GRF_DEFAULT_IMAGE_TAG="latest"
GRF_DEFAULT_ADMIN_USER="admin"

# Colours
BLUE=39

# Session state
GRF_CONTAINER_NAME="grafana"
GRF_INFLUX_TOKEN=""   # Docker: the InfluxDB datasource token, for the container env
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
        GRF_ADMIN_PASSWORD=$(_gen_secret 20)
        _secret_notice "admin password" GF_SECURITY_ADMIN_PASSWORD "$GRF_CONTAINER_NAME" "$GRF_HELM_RELEASE" "$GRF_NAMESPACE"
    fi
}

# _ds_q <value> [k8s] - a typed datasource field as a YAML scalar (Kamino 235).
# Single-quoted (_yaml_squote): unquoted, a ': ' or ' #' in a URL or name, a
# leading quote, or a value like `yes` changed the YAML or its meaning. Every
# $ is doubled: Grafana expands $VAR and ${VAR} in provisioning files, and $$
# is its literal $. Returns 1 for control characters, and on k8s for '{{',
# which the chart's tpl would run as a template.
_ds_q() {
    [[ "${2:-}" == k8s && "$1" == *'{{'* ]] && return 1
    _yaml_squote "${1//\$/\$\$}"
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

        local q_url
        if ! q_url="$(_ds_q "$url" k8s)"; then
            warn "Prometheus skipped: its URL has control characters or '{{'."
        else
        {
            echo "    - name: Prometheus"
            echo "      type: prometheus"
            echo "      url: ${q_url}"
            echo "      access: proxy"
            [[ "$is_default" == true ]] && echo "      isDefault: true"
        } >> "$out_file"
        is_default=false
        fi
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

        local q_url q_org q_bucket q_token
        if ! { q_url="$(_ds_q "$url" k8s)" && q_org="$(_ds_q "$org" k8s)" \
                && q_bucket="$(_ds_q "$bucket" k8s)" && q_token="$(_ds_q "$token" k8s)"; }; then
            warn "InfluxDB skipped: a field has control characters or '{{'."
        else
        {
            echo "    - name: InfluxDB"
            echo "      type: influxdb"
            echo "      url: ${q_url}"
            echo "      access: proxy"
            echo "      jsonData:"
            echo "        version: Flux"
            echo "        organization: ${q_org}"
            echo "        defaultBucket: ${q_bucket}"
            echo "      secureJsonData:"
            # Quoted: the token reaches Grafana as typed (Kamino 196, 235).
            echo "        token: ${q_token}"
            [[ "$is_default" == true ]] && echo "      isDefault: true"
        } >> "$out_file"
        is_default=false
        fi
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

        local q_name q_type q_url
        if ! { q_name="$(_ds_q "$name" k8s)" && q_type="$(_ds_q "$ds_type" k8s)" && q_url="$(_ds_q "$url" k8s)"; }; then
            warn "${name} skipped: a field has control characters or '{{'."
        else
        {
            echo "    - name: ${q_name}"
            echo "      type: ${q_type}"
            echo "      url: ${q_url}"
            echo "      access: proxy"
            [[ "$is_default" == true ]] && echo "      isDefault: true"
        } >> "$out_file"
        fi
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

        local q_url
        if ! q_url="$(_ds_q "$url")"; then
            warn "Prometheus skipped: its URL has control characters."
        else
        {
            echo "- name: Prometheus"
            echo "  type: prometheus"
            echo "  url: ${q_url}"
            echo "  access: proxy"
            [[ "$is_default" == true ]] && echo "  isDefault: true"
        } >> "$ds_file"
        is_default=false
        fi
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
        GRF_INFLUX_TOKEN="$token"

        local q_url q_org q_bucket
        if ! { q_url="$(_ds_q "$url")" && q_org="$(_ds_q "$org")" && q_bucket="$(_ds_q "$bucket")"; }; then
            warn "InfluxDB skipped: a field has control characters."
            GRF_INFLUX_TOKEN=""
        else
        {
            echo "- name: InfluxDB"
            echo "  type: influxdb"
            echo "  url: ${q_url}"
            echo "  access: proxy"
            echo "  jsonData:"
            echo "    version: Flux"
            echo "    organization: ${q_org}"
            echo "    defaultBucket: ${q_bucket}"
            echo "  secureJsonData:"
            # Not the token itself: Grafana substitutes it from the container
            # env (Kamino 196). This file is bind-mounted into the container,
            # which must read it - on Linux as its own grafana user, not the
            # host user owning the file - so it cannot be made 0600 instead.
            # shellcheck disable=SC2016
            echo '    token: ${SCOMP_INFLUXDB_TOKEN}'
            [[ "$is_default" == true ]] && echo "  isDefault: true"
        } >> "$ds_file"
        is_default=false
        fi
    fi

    if echo "$selected" | grep -q "Custom"; then
        local name ds_type url
        name=$(gum input --placeholder "My Datasource" --header "Datasource name:") || true
        name="${name:-My Datasource}"
        ds_type=$(gum input --placeholder "prometheus" --header "Datasource type:") || true
        ds_type="${ds_type:-prometheus}"
        url=$(gum input --placeholder "http://my-service:9090" --header "URL:") || true
        url="${url:-http://my-service:9090}"

        local q_name q_type q_url
        if ! { q_name="$(_ds_q "$name")" && q_type="$(_ds_q "$ds_type")" && q_url="$(_ds_q "$url")"; }; then
            warn "${name} skipped: a field has control characters."
        else
        {
            echo "- name: ${q_name}"
            echo "  type: ${q_type}"
            echo "  url: ${q_url}"
            echo "  access: proxy"
            [[ "$is_default" == true ]] && echo "  isDefault: true"
        } >> "$ds_file"
        fi
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

    local image="grafana/grafana:${GRF_IMAGE_TAG}"
    local volume="${GRF_CONTAINER_NAME}-data"
    local prov_dir
    prov_dir=$(_docker_provisioning_dir)

    local old=""
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
            "Remove and recreate") old="$GRF_CONTAINER_NAME" ;;
            *) warn "Cancelled."; return ;;
        esac
    fi

    # GF_SECURITY_ADMIN_* only create the admin in an empty grafana.db: on a
    # kept volume the old admin password stays in force, so nothing new is
    # asked for; the old container's values are carried over (Kamino 174).
    if docker volume inspect "$volume" &>/dev/null; then
        _kept_data_notice "$volume" "$old"
        GRF_ADMIN_USER="$(_container_env "$old" GF_SECURITY_ADMIN_USER)"
        GRF_ADMIN_PASSWORD="$(_container_env "$old" GF_SECURITY_ADMIN_PASSWORD)"
    else
        _prompt_admin_credentials
    fi

    local plugins_input
    plugins_input=$(gum input \
        --placeholder "leave empty for no extra plugins" \
        --header "Plugins to pre-install (comma-separated, e.g. grafana-piechart-panel):") || true

    if [[ -n "$old" ]]; then
        gum spin --spinner dot --title "Removing existing container..." -- \
            docker rm -f "$GRF_CONTAINER_NAME"
    fi

    GRF_INFLUX_TOKEN=""
    _docker_write_datasources

    gum spin --spinner dot --title "Pulling ${image}..." -- \
        docker pull "$image" \
        || error_exit "Failed to pull image ${image}."

    local docker_args=(
        run -d
        --name "$GRF_CONTAINER_NAME"
        -p "$(svc_publish "$GRF_PORT" 3000)"
        -v "${volume}:/var/lib/grafana"
        --restart unless-stopped
    )
    [[ -n "$GRF_ADMIN_USER" ]]     && docker_args+=(-e "GF_SECURITY_ADMIN_USER=${GRF_ADMIN_USER}")
    [[ -n "$GRF_ADMIN_PASSWORD" ]] && docker_args+=(-e GF_SECURITY_ADMIN_PASSWORD)

    [[ -n "$plugins_input" ]] && docker_args+=(-e "GF_INSTALL_PLUGINS=${plugins_input}")
    [[ -n "$GRF_INFLUX_TOKEN" ]] && docker_args+=(-e SCOMP_INFLUXDB_TOKEN)

    # Mount provisioning dir only if datasources were configured
    if [[ -d "${prov_dir}/datasources" ]] && \
       [[ -f "${prov_dir}/datasources/datasources.yaml" ]]; then
        docker_args+=(-v "${prov_dir}:/etc/grafana/provisioning")
    fi

    docker_args+=("$image")

    # Secrets are passed as -e NAME, the value taken from docker's own
    # environment: not on its command line, where any local user can read it
    # (Kamino 196).
    if ! GF_SECURITY_ADMIN_PASSWORD="$GRF_ADMIN_PASSWORD" SCOMP_INFLUXDB_TOKEN="$GRF_INFLUX_TOKEN" \
        docker "${docker_args[@]}" &>/dev/null; then
        error_exit "Failed to start container '${GRF_CONTAINER_NAME}'."
    fi

    info "Waiting for Grafana to be ready..."
    local attempts=0
    until curl -sf "http://$(svc_host):${GRF_PORT}/api/health" &>/dev/null; do
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
        "Web UI:   http://$(svc_host):${GRF_PORT}" \
        "Username: ${GRF_ADMIN_USER:-(unchanged)}" \
        "Volume:   ${volume}"
    svc_bind_notice
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
    if curl -sf "http://$(svc_host):${host_port}/api/health" 2>/dev/null \
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
    # cut -f2-, not -f2: a value may contain '=' itself (Kamino 196).
    admin_user=$(docker inspect \
        --format='{{range .Config.Env}}{{println .}}{{end}}' "$GRF_CONTAINER_NAME" 2>/dev/null \
        | grep '^GF_SECURITY_ADMIN_USER=' | cut -d= -f2- || echo "$GRF_DEFAULT_ADMIN_USER")

    gum style \
        --foreground "$CYAN" --border-foreground "$CYAN" --border rounded \
        --align left --width 60 --margin "1 2" --padding "1 4" \
        "Grafana Web UI → http://$(svc_host):${host_port}" \
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
    helm --kube-context "$KUBE_CONTEXT" status "$GRF_HELM_RELEASE" -n "$GRF_NAMESPACE" &>/dev/null 2>&1
}

_k8s_ensure_namespace() {
    if kubectl --context "$KUBE_CONTEXT" get namespace "$GRF_NAMESPACE" &>/dev/null; then
        info "Namespace '${GRF_NAMESPACE}' already exists."
    else
        info "Creating namespace '${GRF_NAMESPACE}'..."
        kubectl --context "$KUBE_CONTEXT" create namespace "$GRF_NAMESPACE"
    fi
}

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

# -----------------------------------------------------------------------------
# Kubernetes — install / status / connect / uninstall
# -----------------------------------------------------------------------------

grafana_install_k8s() {
    header "Install Grafana — Kubernetes"
    _k8s_check_cluster || return 0

    _ensure_helm_repo "$GRF_HELM_REPO_NAME" "$GRF_HELM_REPO_URL"

    # An existing release keeps its admin credentials: Grafana created the
    # admin with them in the grafana.db on its PVC and ignores new ones, so an
    # upgrade asks for none and reuses the release's values (Kamino 174).
    local upgrade=false
    if _k8s_detect_installed; then
        gum style \
            --foreground "$YELLOW" --border-foreground "$YELLOW" --border rounded \
            --align center --width 60 --margin "1 2" --padding "1 4" \
            "Release '${GRF_HELM_RELEASE}' already exists in '${GRF_NAMESPACE}'."

        local action
        action=$(gum choose \
            "Upgrade (keep credentials, apply other values)" \
            "Cancel" \
            --header "What would you like to do?") || true

        case "$action" in
            "Upgrade"*) upgrade=true ;;
            *) warn "Cancelled."; return ;;
        esac
        info "Keeping the release's existing admin credentials (helm --reuse-values)."
    else
        _prompt_admin_credentials
    fi

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
    # The X's end the template: BSD mktemp (macOS) replaces them only there,
    # and "grafana-values-XXXXXX.yaml" was that literal name - fixed, so a
    # second run failed and whoever made the path first owned the InfluxDB
    # token written into it (Kamino 237). helm needs no .yaml extension.
    values_file=$(umask 077 && mktemp "${TMPDIR:-/tmp}/grafana-values.XXXXXX") \
        || error_exit "Could not create a temporary values file."
    # shellcheck disable=SC2064
    trap "rm -f '${values_file}'" RETURN

    _prompt_datasources "$values_file"

    _k8s_ensure_namespace

    local helm_args=(
        "$GRF_HELM_RELEASE" "$GRF_HELM_CHART"
        --namespace "$GRF_NAMESPACE"
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

    if [[ "$upgrade" == true ]]; then
        helm_args+=(--reuse-values)
    else
        # The admin password goes in a 0600 values file, not --set: on argv it
        # is readable by every local user, and --set splits a value at commas
        # and parses \ . { } in it (Kamino 196). Removed with values_file.
        local secret_values
        _helm_secret_values secret_values adminPassword "$GRF_ADMIN_PASSWORD" \
            || error_exit "The admin password contains control characters; it cannot be passed to helm."
        # shellcheck disable=SC2064
        trap "rm -f '${values_file}' '${secret_values}'" RETURN
        helm_args+=(--set "adminUser=${GRF_ADMIN_USER}" -f "$secret_values")
    fi

    if [[ "$upgrade" == true ]]; then
        if ! gum spin --spinner dot --title "Upgrading Grafana..." -- \
            helm --kube-context "$KUBE_CONTEXT" upgrade "${helm_args[@]}"; then
            warn "Upgrade failed. Check 'helm --kube-context ${KUBE_CONTEXT} status ${GRF_HELM_RELEASE} -n ${GRF_NAMESPACE}'."
            return
        fi
        success "Grafana upgraded."
    else
        if ! gum spin --spinner dot --title "Installing Grafana..." -- \
            helm --kube-context "$KUBE_CONTEXT" install "${helm_args[@]}"; then
            warn "Install failed. Check 'helm --kube-context ${KUBE_CONTEXT} status ${GRF_HELM_RELEASE} -n ${GRF_NAMESPACE}'."
            return
        fi
        success "Grafana installed."
    fi

    echo ""
    if [[ "$upgrade" == true ]]; then
        gum style --foreground "$CYAN" \
            "Use 'connect' to open the web UI via port-forward." \
            "Login: unchanged - the admin credentials the release was installed with" \
            "(Secret '${GRF_HELM_RELEASE}' in '${GRF_NAMESPACE}', key admin-password)."
    else
        gum style --foreground "$CYAN" \
            "Use 'connect' to open the web UI via port-forward." \
            "Login: ${GRF_ADMIN_USER} / ${GRF_ADMIN_PASSWORD}"
    fi
}

grafana_status_k8s() {
    header "Status — Grafana Kubernetes"
    _k8s_check_cluster || return 0

    if ! _k8s_detect_installed; then
        warn "Release '${GRF_HELM_RELEASE}' not found in namespace '${GRF_NAMESPACE}'."
        return
    fi

    info "Helm release:"
    helm --kube-context "$KUBE_CONTEXT" status "$GRF_HELM_RELEASE" -n "$GRF_NAMESPACE" 2>/dev/null | head -10
    echo ""

    info "Pods:"
    kubectl --context "$KUBE_CONTEXT" get pods -n "$GRF_NAMESPACE" --no-headers 2>/dev/null
    echo ""

    info "Services:"
    kubectl --context "$KUBE_CONTEXT" get svc -n "$GRF_NAMESPACE" --no-headers 2>/dev/null
    echo ""

    info "PersistentVolumeClaims:"
    kubectl --context "$KUBE_CONTEXT" get pvc -n "$GRF_NAMESPACE" --no-headers 2>/dev/null || true
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
    if ! kubectl --context "$KUBE_CONTEXT" get svc "$svc" -n "$GRF_NAMESPACE" &>/dev/null 2>&1; then
        svc="$GRF_HELM_RELEASE"
    fi

    kubectl --context "$KUBE_CONTEXT" -n "$GRF_NAMESPACE" port-forward "svc/${svc}" "${port}:${GRF_SVC_PORT}" >/dev/null 2>&1 &
    pf_write "$_GRF_PF_PID" "${!}" "${port}"

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
        "  kubectl --context ${KUBE_CONTEXT} delete pvc --all -n ${GRF_NAMESPACE}"

    if ! gum confirm "Uninstall Grafana?"; then
        warn "Cancelled."
        return
    fi

    gum spin --spinner dot --title "Running helm uninstall..." -- \
        helm --kube-context "$KUBE_CONTEXT" uninstall "$GRF_HELM_RELEASE" -n "$GRF_NAMESPACE" || true

    if gum confirm "Also delete namespace '${GRF_NAMESPACE}' (removes remaining PVCs too)?"; then
        gum spin --spinner dot --title "Deleting namespace '${GRF_NAMESPACE}'..." -- \
            kubectl --context "$KUBE_CONTEXT" delete namespace "$GRF_NAMESPACE" --ignore-not-found || true
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
