#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# scripts/lgtm/lgtm.sh — LGTM stack manager (Loki · Grafana · Tempo · Mimir)
# Supports Docker Compose and kind/k8s targets.
# Sourced helpers: _common/ui.sh, _common/cluster.sh, _common/portforward.sh,
#                  _common/deps.sh
# -----------------------------------------------------------------------------

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMON_DIR="${SCRIPT_DIR}/../_common"
if [[ ! -d "$COMMON_DIR" ]]; then
    printf "\033[0;31m[ERROR] _common directory not found at %s\033[0m\n" "$COMMON_DIR" >&2
    exit 1
fi

# source shared helpers
# shellcheck source=../_common/ui.sh
source "${COMMON_DIR}/ui.sh"
# shellcheck source=../_common/cluster.sh
source "${COMMON_DIR}/cluster.sh"
# shellcheck source=../_common/portforward.sh
source "${COMMON_DIR}/portforward.sh"
# shellcheck source=../_common/deps.sh
source "${COMMON_DIR}/deps.sh"

# pinned chart versions
# Update these explicitly when you want to bump a component.
LOKI_CHART_VERSION="6.6.2"
TEMPO_CHART_VERSION="1.10.3"
MIMIR_CHART_VERSION="5.3.0"
GRAFANA_CHART_VERSION="8.0.0"
OTELCOL_CHART_VERSION="0.97.1"

HELM_REPO_NAME="grafana"
HELM_REPO_URL="https://grafana.github.io/helm-charts"

OTEL_HELM_REPO_NAME="open-telemetry"
OTEL_HELM_REPO_URL="https://open-telemetry.github.io/opentelemetry-helm-charts"

NAMESPACE="monitoring"

# XDG config
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/lgtm"
CONFIG_FILE="${CONFIG_DIR}/lgtm.conf"
PF_DIR="${CONFIG_DIR}/pf"          # PID files for port-forwards
COMPOSE_DIR="${CONFIG_DIR}/compose" # generated compose file lives here

mkdir -p "$CONFIG_DIR" "$PF_DIR" "$COMPOSE_DIR"

# component registry
# Order matters for display; used throughout the script.
COMPONENTS=(grafana loki tempo mimir otelcol)

declare -A COMP_LABEL=(
    [grafana]="Grafana"
    [loki]="Loki"
    [tempo]="Tempo"
    [mimir]="Mimir"
    [otelcol]="OTel Collector"
)

# Default local ports for port-forward / Compose mapping
declare -A COMP_PORT=(
    [grafana]="3000"
    [loki]="3100"
    [tempo]="3200"
    [mimir]="9009"
    [otelcol]="4317"   # gRPC; HTTP is 4318
)

# Known Kubernetes service names produced by each Helm chart.
# These are chart-specific and do not simply follow "<release>" naming.
declare -A COMP_SVC=(
    [grafana]="grafana"
    [loki]="loki"
    [tempo]="tempo"
    [mimir]="mimir-nginx"   # mimir-distributed routes external traffic through its nginx component
    [otelcol]="otelcol-opentelemetry-collector"
)

# Helm chart names
declare -A COMP_CHART=(
    [grafana]="grafana/grafana"
    [loki]="grafana/loki"
    [tempo]="grafana/tempo"
    [mimir]="grafana/mimir-distributed"
    [otelcol]="open-telemetry/opentelemetry-collector"
)

declare -A COMP_CHART_VERSION=(
    [grafana]="$GRAFANA_CHART_VERSION"
    [loki]="$LOKI_CHART_VERSION"
    [tempo]="$TEMPO_CHART_VERSION"
    [mimir]="$MIMIR_CHART_VERSION"
    [otelcol]="$OTELCOL_CHART_VERSION"
)

# Container image names (for Compose mode)
declare -A COMP_IMAGE=(
    [grafana]="grafana/grafana:11.0.0"
    [loki]="grafana/loki:3.0.0"
    [tempo]="grafana/tempo:2.5.0"
    [mimir]="grafana/mimir:2.12.0"
    [otelcol]="otel/opentelemetry-collector-contrib:0.102.0"
)

# config helpers────

cfg_get() {
    grep -E "^${1}=" "$CONFIG_FILE" 2>/dev/null \
        | cut -d= -f2- \
        | sed 's/^"\(.*\)"$/\1/' \
        || true
}
cfg_set() {
    local key="$1" val="$2"
    local quoted="\"${val}\""
    if grep -qE "^${key}=" "$CONFIG_FILE" 2>/dev/null; then
        sed -i.bak "s|^${key}=.*|${key}=${quoted}|" "$CONFIG_FILE" && rm -f "${CONFIG_FILE}.bak"
    else
        echo "${key}=${quoted}" >> "$CONFIG_FILE"
    fi
}

cfg_load() {
    [[ -f "$CONFIG_FILE" ]] && source "$CONFIG_FILE" || true
}

# resource profiles─

# Minimal (kind / local dev)
declare -A MINIMAL_CPU_REQ=([grafana]="50m"  [loki]="50m"  [tempo]="50m"  [mimir]="100m" [otelcol]="50m")
declare -A MINIMAL_CPU_LIM=([grafana]="200m" [loki]="200m" [tempo]="200m" [mimir]="500m" [otelcol]="200m")
declare -A MINIMAL_MEM_REQ=([grafana]="64Mi"  [loki]="64Mi"  [tempo]="64Mi"  [mimir]="256Mi" [otelcol]="64Mi")
declare -A MINIMAL_MEM_LIM=([grafana]="256Mi" [loki]="256Mi" [tempo]="256Mi" [mimir]="1Gi"   [otelcol]="256Mi")
declare -A MINIMAL_REPLICAS=([grafana]=1 [loki]=1 [tempo]=1 [mimir]=1 [otelcol]=1)
declare -A MINIMAL_PVC=([grafana]="1Gi" [loki]="5Gi" [tempo]="5Gi" [mimir]="10Gi" [otelcol]="1Gi")
declare -A MINIMAL_RETENTION=([loki]="24h" [tempo]="24h" [mimir]="24h")

# Standard (real k8s cluster)
declare -A STANDARD_CPU_REQ=([grafana]="100m"  [loki]="100m"  [tempo]="100m"  [mimir]="250m"  [otelcol]="100m")
declare -A STANDARD_CPU_LIM=([grafana]="500m"  [loki]="500m"  [tempo]="500m"  [mimir]="2000m" [otelcol]="500m")
declare -A STANDARD_MEM_REQ=([grafana]="128Mi" [loki]="128Mi" [tempo]="128Mi" [mimir]="512Mi" [otelcol]="128Mi")
declare -A STANDARD_MEM_LIM=([grafana]="512Mi" [loki]="512Mi" [tempo]="512Mi" [mimir]="4Gi"   [otelcol]="512Mi")
declare -A STANDARD_REPLICAS=([grafana]=1 [loki]=1 [tempo]=1 [mimir]=2 [otelcol]=1)
declare -A STANDARD_PVC=([grafana]="5Gi" [loki]="20Gi" [tempo]="20Gi" [mimir]="50Gi" [otelcol]="2Gi")
declare -A STANDARD_RETENTION=([loki]="168h" [tempo]="168h" [mimir]="168h")

# Active profile values (populated by _apply_profile or _custom_profile)
declare -A PROF_CPU_REQ PROF_CPU_LIM PROF_MEM_REQ PROF_MEM_LIM
declare -A PROF_REPLICAS PROF_PVC PROF_RETENTION

_apply_profile() {
    local profile="$1"   # "minimal" | "standard"
    local src="MINIMAL"
    [[ "$profile" == "standard" ]] && src="STANDARD"

    for c in "${COMPONENTS[@]}"; do
        eval "PROF_CPU_REQ[$c]=\${${src}_CPU_REQ[$c]}"
        eval "PROF_CPU_LIM[$c]=\${${src}_CPU_LIM[$c]}"
        eval "PROF_MEM_REQ[$c]=\${${src}_MEM_REQ[$c]}"
        eval "PROF_MEM_LIM[$c]=\${${src}_MEM_LIM[$c]}"
        eval "PROF_REPLICAS[$c]=\${${src}_REPLICAS[$c]}"
        eval "PROF_PVC[$c]=\${${src}_PVC[$c]}"
    done
    for c in loki tempo mimir; do
        eval "PROF_RETENTION[$c]=\${${src}_RETENTION[$c]}"
    done
}

_custom_profile() {
    # Start from minimal as baseline
    _apply_profile "minimal"

    gum style --foreground "${CYAN}" --bold "Custom resource profile — configure each component"

    for c in "${COMPONENTS[@]}"; do
        gum style --foreground "${CYAN}" --bold "── ${COMP_LABEL[$c]}"

        PROF_CPU_REQ[$c]=$(gum input --placeholder "${PROF_CPU_REQ[$c]}" \
            --header "  CPU request (e.g. 100m):") || true
        [[ -z "${PROF_CPU_REQ[$c]}" ]] && PROF_CPU_REQ[$c]="${MINIMAL_CPU_REQ[$c]}"

        PROF_CPU_LIM[$c]=$(gum input --placeholder "${PROF_CPU_LIM[$c]}" \
            --header "  CPU limit (e.g. 500m):") || true
        [[ -z "${PROF_CPU_LIM[$c]}" ]] && PROF_CPU_LIM[$c]="${MINIMAL_CPU_LIM[$c]}"

        PROF_MEM_REQ[$c]=$(gum input --placeholder "${PROF_MEM_REQ[$c]}" \
            --header "  Memory request (e.g. 128Mi):") || true
        [[ -z "${PROF_MEM_REQ[$c]}" ]] && PROF_MEM_REQ[$c]="${MINIMAL_MEM_REQ[$c]}"

        PROF_MEM_LIM[$c]=$(gum input --placeholder "${PROF_MEM_LIM[$c]}" \
            --header "  Memory limit (e.g. 512Mi):") || true
        [[ -z "${PROF_MEM_LIM[$c]}" ]] && PROF_MEM_LIM[$c]="${MINIMAL_MEM_LIM[$c]}"

        PROF_REPLICAS[$c]=$(gum input --placeholder "${PROF_REPLICAS[$c]}" \
            --header "  Replicas:") || true
        [[ -z "${PROF_REPLICAS[$c]}" ]] && PROF_REPLICAS[$c]="${MINIMAL_REPLICAS[$c]}"

        PROF_PVC[$c]=$(gum input --placeholder "${PROF_PVC[$c]}" \
            --header "  PVC size (e.g. 10Gi):") || true
        [[ -z "${PROF_PVC[$c]}" ]] && PROF_PVC[$c]="${MINIMAL_PVC[$c]}"
    done

    for c in loki tempo mimir; do
        PROF_RETENTION[$c]=$(gum input --placeholder "${PROF_RETENTION[$c]}" \
            --header "  ${COMP_LABEL[$c]} retention (e.g. 168h):") || true
        [[ -z "${PROF_RETENTION[$c]}" ]] && PROF_RETENTION[$c]="${MINIMAL_RETENTION[$c]}"
    done
}

# storage helpers───

_hostpath_for_component() {
    local c="$1"
    local base
    base=$(cfg_get "HOSTPATH_BASE")
    echo "${base:-/var/lgtm-data}/${c}"
}

_prompt_storage() {
    local target_type="$1"   # "kind" | "k8s" | "docker"

    if [[ "$target_type" == "docker" ]]; then
        local default_base="${CONFIG_DIR}/data"
        local base
        base=$(gum input \
            --placeholder "$default_base" \
            --header "Docker Compose data directory (bind-mount base path):") || true
        [[ -z "$base" ]] && base="$default_base"
        cfg_set "HOSTPATH_BASE" "$base"
        return
    fi

    if [[ "$target_type" == "kind" ]]; then
        local default_base="/var/lgtm-data"
        local base
        base=$(gum input \
            --placeholder "$default_base" \
            --header "hostPath base directory for PVs (kind node path):") || true
        [[ -z "$base" ]] && base="$default_base"
        cfg_set "HOSTPATH_BASE" "$base"
        cfg_set "STORAGE_TYPE" "hostpath"
        return
    fi

    # k8s — detect kind vs real; offer hostpath or NFS
    local storage_type
    storage_type=$(gum choose \
        --header "Storage backend for PersistentVolumes:" \
        "hostPath (single-node, local path)" \
        "NFS (LAN cluster)") || true

    case "$storage_type" in
        hostPath*)
            local base
            base=$(gum input \
                --placeholder "/var/lgtm-data" \
                --header "hostPath base directory on k8s nodes:") || true
            [[ -z "$base" ]] && base="/var/lgtm-data"
            cfg_set "HOSTPATH_BASE" "$base"
            cfg_set "STORAGE_TYPE" "hostpath"
            ;;
        NFS*)
            local nfs_server nfs_path
            nfs_server=$(gum input --placeholder "192.168.1.100" \
                --header "NFS server IP or hostname:") || true
            nfs_path=$(gum input --placeholder "/export/lgtm" \
                --header "NFS export path:") || true
            [[ -z "$nfs_server" ]] && error_exit "NFS server is required."
            [[ -z "$nfs_path" ]]   && error_exit "NFS export path is required."
            cfg_set "NFS_SERVER" "$nfs_server"
            cfg_set "NFS_PATH"   "$nfs_path"
            cfg_set "STORAGE_TYPE" "nfs"
            ;;
        *)
            error_exit "No storage type selected. Aborting."
            ;;
    esac
}

# component toggle picker

# Prompts the user to pick which components to enable.
# Sets ENABLED_COMPONENTS as a space-separated string.
_pick_components() {
    local header="${1:-Select components to enable:}"
    local default_list="${2:-grafana loki tempo mimir}"   # otelcol neutral = not pre-selected

    local labels=()
    for c in "${COMPONENTS[@]}"; do
        labels+=("${COMP_LABEL[$c]}")
    done

    # Pre-select defaults
    local chosen
    chosen=$(printf '%s\n' "${labels[@]}" | gum choose \
        --no-limit \
        --header "$header" \
        --height 10) || true

    [[ -z "$chosen" ]] && error_exit "No components selected. Aborting."

    ENABLED_COMPONENTS=""
    for c in "${COMPONENTS[@]}"; do
        if echo "$chosen" | grep -qF "${COMP_LABEL[$c]}"; then
            ENABLED_COMPONENTS="${ENABLED_COMPONENTS} ${c}"
        fi
    done
    ENABLED_COMPONENTS="${ENABLED_COMPONENTS# }"  # trim leading space
}

# Helm values generation─

_helm_values_grafana() {
    # kind has rancher.io/local-path dynamic provisioner; leave storageClassName empty
    # so the default class is used. k8s clusters use our static lgtm-* class.
    local sc="lgtm-grafana"
    [[ "$TARGET_TYPE" == "kind" ]] && sc=""
    cat <<EOF
replicas: ${PROF_REPLICAS[grafana]}
resources:
  requests:
    cpu: "${PROF_CPU_REQ[grafana]}"
    memory: "${PROF_MEM_REQ[grafana]}"
  limits:
    cpu: "${PROF_CPU_LIM[grafana]}"
    memory: "${PROF_MEM_LIM[grafana]}"
persistence:
  enabled: true
  storageClassName: "${sc}"
  size: "${PROF_PVC[grafana]}"
adminPassword: "admin"
grafana.ini:
  server:
    domain: localhost
EOF
}

_helm_values_loki() {
    # Chart v6.x (Loki v3) uses SingleBinary deployment mode for local/kind targets.
    # SimpleScalable (the v6 default) requires object storage and won't start with filesystem.
    local sc="lgtm-loki"
    [[ "$TARGET_TYPE" == "kind" ]] && sc=""
    cat <<EOF
deploymentMode: SingleBinary
loki:
  auth_enabled: false
  commonConfig:
    replication_factor: 1
  storage:
    type: filesystem
  limits_config:
    retention_period: "${PROF_RETENTION[loki]}"
  schemaConfig:
    configs:
      - from: "2024-01-01"
        store: tsdb
        object_store: filesystem
        schema: v13
        index:
          prefix: index_
          period: 24h
singleBinary:
  replicas: ${PROF_REPLICAS[loki]}
  resources:
    requests:
      cpu: "${PROF_CPU_REQ[loki]}"
      memory: "${PROF_MEM_REQ[loki]}"
    limits:
      cpu: "${PROF_CPU_LIM[loki]}"
      memory: "${PROF_MEM_LIM[loki]}"
  persistence:
    enabled: true
    storageClass: "${sc}"
    size: "${PROF_PVC[loki]}"
# Disable all scalable-mode components (not used in SingleBinary)
read:
  replicas: 0
write:
  replicas: 0
backend:
  replicas: 0
# Disable caches — not needed for SingleBinary and cause extra Pending pods in kind
chunksCache:
  enabled: false
resultsCache:
  enabled: false
EOF
}

_helm_values_tempo() {
    local sc="lgtm-tempo"
    [[ "$TARGET_TYPE" == "kind" ]] && sc=""
    cat <<EOF
tempo:
  retention: "${PROF_RETENTION[tempo]}"
  resources:
    requests:
      cpu: "${PROF_CPU_REQ[tempo]}"
      memory: "${PROF_MEM_REQ[tempo]}"
    limits:
      cpu: "${PROF_CPU_LIM[tempo]}"
      memory: "${PROF_MEM_LIM[tempo]}"
persistence:
  enabled: true
  storageClassName: "${sc}"
  size: "${PROF_PVC[tempo]}"
replicas: ${PROF_REPLICAS[tempo]}
EOF
}

_helm_values_mimir() {
    # Zone-aware replication is on by default (3 zones) and replication_factor must match.
    # For kind, enable the built-in minio so mimir has object storage without external deps.
    local sc="lgtm-mimir"
    local minio_enabled="false"
    [[ "$TARGET_TYPE" == "kind" ]] && sc="" && minio_enabled="true"

    cat <<EOF
mimir:
  structuredConfig:
    ingester:
      ring:
        replication_factor: 3
    limits:
      compactor_blocks_retention_period: "${PROF_RETENTION[mimir]}"
minio:
  enabled: ${minio_enabled}
ingester:
  resources:
    requests:
      cpu: "${PROF_CPU_REQ[mimir]}"
      memory: "${PROF_MEM_REQ[mimir]}"
    limits:
      cpu: "${PROF_CPU_LIM[mimir]}"
      memory: "${PROF_MEM_LIM[mimir]}"
store_gateway:
  resources:
    requests:
      cpu: "${PROF_CPU_REQ[mimir]}"
      memory: "${PROF_MEM_REQ[mimir]}"
    limits:
      cpu: "${PROF_CPU_LIM[mimir]}"
      memory: "${PROF_MEM_LIM[mimir]}"
  persistentVolume:
    enabled: true
    storageClass: "${sc}"
    size: "${PROF_PVC[mimir]}"
EOF
}

_helm_values_otelcol() {
    cat <<EOF
mode: deployment
image:
  repository: "otel/opentelemetry-collector-contrib"
replicaCount: ${PROF_REPLICAS[otelcol]}
resources:
  requests:
    cpu: "${PROF_CPU_REQ[otelcol]}"
    memory: "${PROF_MEM_REQ[otelcol]}"
  limits:
    cpu: "${PROF_CPU_LIM[otelcol]}"
    memory: "${PROF_MEM_LIM[otelcol]}"
config:
  receivers:
    otlp:
      protocols:
        grpc:
          endpoint: 0.0.0.0:4317
        http:
          endpoint: 0.0.0.0:4318
  exporters:
    otlp/tempo:
      endpoint: "http://tempo.${NAMESPACE}.svc.cluster.local:4317"
      tls:
        insecure: true
    loki:
      endpoint: "http://loki.${NAMESPACE}.svc.cluster.local:3100/loki/api/v1/push"
    prometheusremotewrite:
      endpoint: "http://mimir-nginx.${NAMESPACE}.svc.cluster.local/api/v1/push"
  service:
    pipelines:
      traces:
        receivers: [otlp]
        exporters: [otlp/tempo]
      logs:
        receivers: [otlp]
        exporters: [loki]
      metrics:
        receivers: [otlp]
        exporters: [prometheusremotewrite]
EOF
}

# PersistentVolume manifest (hostPath or NFS)

_pv_manifest() {
    local c="$1"
    local storage_type pv_size

    storage_type=$(cfg_get "STORAGE_TYPE")
    pv_size="${PROF_PVC[$c]}"

    if [[ "$storage_type" == "nfs" ]]; then
        local nfs_server nfs_path
        nfs_server=$(cfg_get "NFS_SERVER")
        nfs_path=$(cfg_get "NFS_PATH")
        cat <<EOF
apiVersion: v1
kind: PersistentVolume
metadata:
  name: lgtm-${c}
  namespace: ${NAMESPACE}
spec:
  capacity:
    storage: ${pv_size}
  accessModes: [ReadWriteOnce]
  persistentVolumeReclaimPolicy: Retain
  storageClassName: lgtm-${c}
  nfs:
    server: ${nfs_server}
    path: ${nfs_path}/${c}
EOF
    else
        local host_path
        host_path="$(_hostpath_for_component "$c")"
        cat <<EOF
apiVersion: v1
kind: PersistentVolume
metadata:
  name: lgtm-${c}
  namespace: ${NAMESPACE}
spec:
  capacity:
    storage: ${pv_size}
  accessModes: [ReadWriteOnce]
  persistentVolumeReclaimPolicy: Retain
  storageClassName: lgtm-${c}
  hostPath:
    path: ${host_path}
    type: DirectoryOrCreate
EOF
    fi
}

_storageclass_manifest() {
    local c="$1"
    cat <<EOF
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: lgtm-${c}
provisioner: kubernetes.io/no-provisioner
volumeBindingMode: Immediate
EOF
}

# Docker Compose generation

_generate_compose() {
    local enabled="$1"   # space-separated component names
    local base_path
    base_path=$(cfg_get "HOSTPATH_BASE")

    local compose_file="${COMPOSE_DIR}/docker-compose.yml"

    cat > "$compose_file" <<EOF
# Auto-generated by lgtm.sh — do not edit manually.
# Regenerate with: lgtm.sh install (Docker target)
version: "3.8"

networks:
  lgtm:
    driver: bridge

volumes:
EOF

    for c in $enabled; do
        echo "  lgtm_${c}:" >> "$compose_file"
    done

    echo "" >> "$compose_file"
    echo "services:" >> "$compose_file"

    for c in $enabled; do
        local port="${COMP_PORT[$c]}"
        local image="${COMP_IMAGE[$c]}"
        local data_path="${base_path}/${c}"

        case "$c" in
            grafana)
                cat >> "$compose_file" <<EOF

  grafana:
    image: ${image}
    container_name: lgtm_grafana
    ports:
      - "${port}:3000"
    environment:
      - GF_SECURITY_ADMIN_PASSWORD=admin
    volumes:
      - lgtm_grafana:/var/lib/grafana
      - ${data_path}/provisioning:/etc/grafana/provisioning
    networks:
      - lgtm
    restart: unless-stopped
EOF
                ;;
            loki)
                cat >> "$compose_file" <<EOF

  loki:
    image: ${image}
    container_name: lgtm_loki
    ports:
      - "${port}:3100"
    command: -config.file=/etc/loki/local-config.yaml
    volumes:
      - lgtm_loki:/loki
      - ${data_path}/config:/etc/loki
    networks:
      - lgtm
    restart: unless-stopped
EOF
                ;;
            tempo)
                # Only bind 4317 to the host when otelcol is absent from the stack.
                # When otelcol is enabled it owns 4317 and forwards to tempo internally.
                local tempo_extra_port=""
                [[ " $enabled " != *" otelcol "* ]] && tempo_extra_port="      - \"4317:4317\""

                cat >> "$compose_file" <<EOF

  tempo:
    image: ${image}
    container_name: lgtm_tempo
    ports:
      - "${port}:3200"
${tempo_extra_port}
    command: -config.file=/etc/tempo/tempo.yaml
    volumes:
      - lgtm_tempo:/var/tempo
      - ${data_path}/config:/etc/tempo
    networks:
      - lgtm
    restart: unless-stopped
EOF
                ;;
            mimir)
                cat >> "$compose_file" <<EOF

  mimir:
    image: ${image}
    container_name: lgtm_mimir
    ports:
      - "${port}:9009"
    command: -config.file=/etc/mimir/mimir.yaml
    volumes:
      - lgtm_mimir:/data/mimir
      - ${data_path}/config:/etc/mimir
    networks:
      - lgtm
    restart: unless-stopped
EOF
                ;;
            otelcol)
                cat >> "$compose_file" <<EOF

  otelcol:
    image: ${image}
    container_name: lgtm_otelcol
    ports:
      - "4317:4317"
      - "4318:4318"
    volumes:
      - ${data_path}/config:/etc/otelcol
    networks:
      - lgtm
    restart: unless-stopped
EOF
                ;;
        esac
    done

    echo "$compose_file"
}

# install helpers───

_helm_install_component() {
    local c="$1"
    local helm_flags="$2"
    local kctl_flags="$3"
    local values_file pv_file sc_file
    values_file="$(mktemp /tmp/lgtm-values-XXXXXX)"
    pv_file="$(mktemp /tmp/lgtm-pv-XXXXXX)"
    sc_file="$(mktemp /tmp/lgtm-sc-XXXXXX)"
    # shellcheck disable=SC2064
    trap "rm -f ${values_file} ${pv_file} ${sc_file}" RETURN

    "_helm_values_${c}" > "$values_file"
    info "Values for ${COMP_LABEL[$c]}: $(wc -l < "$values_file") lines (target=${TARGET_TYPE:-UNSET})"

    # kind already has rancher.io/local-path (dynamic provisioner) as its default
    # StorageClass — manual SC/PV creation is unnecessary and was silently failing.
    # For real k8s clusters (no default dynamic provisioner), create them explicitly.
    if [[ "$TARGET_TYPE" != "kind" ]]; then
        _storageclass_manifest "$c" > "$sc_file"
        _pv_manifest "$c"           > "$pv_file"
        # shellcheck disable=SC2086
        kubectl $kctl_flags apply -f "$sc_file" \
            || warn "StorageClass create failed for ${COMP_LABEL[$c]}"
        # shellcheck disable=SC2086
        kubectl $kctl_flags apply -f "$pv_file" \
            || warn "PV create failed for ${COMP_LABEL[$c]}"
    fi

    local helm_out
    # shellcheck disable=SC2086
    if ! helm_out=$(helm upgrade --install "${c}" "${COMP_CHART[$c]}" \
            --version "${COMP_CHART_VERSION[$c]}" \
            --namespace "${NAMESPACE}" \
            --create-namespace \
            --values "$values_file" \
            $helm_flags 2>&1); then
        gum style --foreground "${RED}" "[error] helm install failed for ${COMP_LABEL[$c]}:"
        echo "$helm_out"
        return 1
    fi
}

_install_k8s() {
    local helm_flags kctl_flags
    helm_flags="$(helm_context_flag)"
    kctl_flags="$(kubectl_context_flag)"

    _ensure_helm "LGTM stack"
    _ensure_helm_repo "$HELM_REPO_NAME"      "$HELM_REPO_URL"
    _ensure_helm_repo "$OTEL_HELM_REPO_NAME" "$OTEL_HELM_REPO_URL"

    local enabled
    enabled=$(cfg_get "ENABLED_COMPONENTS")

    for c in $enabled; do
        _helm_install_component "$c" "$helm_flags" "$kctl_flags"
        success "${COMP_LABEL[$c]} installed."
    done

    success "LGTM stack installed in namespace '${NAMESPACE}'."
}

_install_docker() {
    local enabled
    enabled=$(cfg_get "ENABLED_COMPONENTS")

    local base_path
    base_path=$(cfg_get "HOSTPATH_BASE")

    # Ensure data dirs exist
    for c in $enabled; do
        mkdir -p "${base_path}/${c}/config"
    done

    local compose_file
    compose_file=$(_generate_compose "$enabled")
    cfg_set "COMPOSE_FILE" "$compose_file"

    gum spin --spinner dot --title "Starting LGTM stack..." -- \
        docker-compose -f "$compose_file" up -d

    success "LGTM stack started. Compose file: ${compose_file}"
}

# cmd: install

cmd_install() {
    header "LGTM — Install"

    # Config file check
    if [[ -f "$CONFIG_FILE" ]]; then
        local choice
        choice=$(gum choose \
            --header "Existing config found at ${CONFIG_FILE}. How to proceed?" \
            "Use existing config" \
            "Clean install (overwrite config)") || true
        [[ -z "$choice" ]] && { warn "Aborted."; return; }

        if [[ "$choice" == "Use existing config" ]]; then
            cfg_load
            info "Using saved config."
            local saved_profile
            saved_profile=$(cfg_get "RESOURCE_PROFILE")
            if [[ "$TARGET_TYPE" != "docker" ]]; then
                if [[ "$saved_profile" == "minimal" || "$saved_profile" == "standard" ]]; then
                    _apply_profile "$saved_profile"
                elif [[ "$saved_profile" == "custom" ]]; then
                    warn "Custom profile cannot be restored from config — falling back to minimal."
                    _apply_profile "minimal"
                else
                    _apply_profile "minimal"
                fi
            fi
            case "$TARGET_TYPE" in
                docker) _install_docker ;;
                *)      _install_k8s   ;;
            esac
            return
        else
            rm -f "$CONFIG_FILE"
            info "Config cleared. Starting fresh."
        fi
    fi

    # Target selection
    select_target || return 1
    cfg_set "TARGET_TYPE"    "$TARGET_TYPE"
    cfg_set "TARGET_CONTEXT" "$TARGET_CONTEXT"

    # Dependency check
    case "$TARGET_TYPE" in
        docker) _check_docker  ;;
        *)      _check_kubectl ;;
    esac

    # Component selection
    _pick_components "Select components to install:"
    cfg_set "ENABLED_COMPONENTS" "$ENABLED_COMPONENTS"

    # Storage
    _prompt_storage "$TARGET_TYPE"

    # Resource profile
    if [[ "$TARGET_TYPE" == "kind" ]]; then
        info "kind target detected — applying minimal resource profile automatically."
        _apply_profile "minimal"
        cfg_set "RESOURCE_PROFILE" "minimal"
    elif [[ "$TARGET_TYPE" == "docker" ]]; then
        info "Docker target — resource profiles are not applicable (Compose mode)."
    else
        local profile_choice
        profile_choice=$(gum choose \
            --header "Resource profile:" \
            "minimal" "standard" "custom") || true
        [[ -z "$profile_choice" ]] && error_exit "No profile selected. Aborting."

        case "$profile_choice" in
            minimal)  _apply_profile "minimal"  ;;
            standard) _apply_profile "standard" ;;
            custom)   _custom_profile           ;;
        esac
        cfg_set "RESOURCE_PROFILE" "$profile_choice"
    fi

    # Run install
    case "$TARGET_TYPE" in
        docker) _install_docker ;;
        *)      _install_k8s   ;;
    esac
}

# cmd: uninstall────

cmd_uninstall() {
    header "LGTM — Uninstall"

    cfg_load
    local target_type ctx_flags
    target_type=$(cfg_get "TARGET_TYPE")
    [[ -z "$target_type" ]] && error_exit "No saved config found. Nothing to uninstall."

    local enabled
    enabled=$(cfg_get "ENABLED_COMPONENTS")

    if ! gum confirm "Uninstall LGTM stack? Data will be preserved."; then
        warn "Aborted."
        return
    fi

    if [[ "$target_type" == "docker" ]]; then
        local compose_file
        compose_file=$(cfg_get "COMPOSE_FILE")
        [[ -z "$compose_file" || ! -f "$compose_file" ]] && \
            error_exit "Compose file not found: ${compose_file}"

        local components_to_remove
        components_to_remove=$(printf '%s\n' $enabled | \
            gum choose --no-limit --header "Select components to remove:" \
            --height 10) || true
        [[ -z "$components_to_remove" ]] && { warn "Nothing selected."; return; }

        for c in $components_to_remove; do
            gum spin --spinner dot --title "Stopping ${COMP_LABEL[$c]}..." -- \
                docker-compose -f "$compose_file" stop "$c" || true
            gum spin --spinner dot --title "Removing ${COMP_LABEL[$c]}..." -- \
                docker-compose -f "$compose_file" rm -f "$c" || true
            success "${COMP_LABEL[$c]} removed."
        done
    else
        local helm_flags
        helm_flags="$(helm_context_flag)"
        for c in $enabled; do
            # shellcheck disable=SC2086
            gum spin --spinner dot --title "Uninstalling ${COMP_LABEL[$c]}..." -- \
                helm uninstall "$c" --namespace "${NAMESPACE}" $helm_flags 2>/dev/null || \
                warn "${COMP_LABEL[$c]} not found (already removed?)."
            success "${COMP_LABEL[$c]} uninstalled."
        done
    fi

    success "Uninstall complete. Data preserved."
}

# cmd: purge

cmd_purge() {
    header "LGTM — Purge"

    cfg_load
    local target_type
    target_type=$(cfg_get "TARGET_TYPE")
    [[ -z "$target_type" ]] && error_exit "No saved config found. Nothing to purge."

    gum style --foreground "${RED}" --bold \
        "WARNING: Purge will remove ALL stack resources AND delete all data on disk."

    if ! gum confirm --affirmative "Yes, purge everything" --negative "Cancel" \
        "This is irreversible. Are you sure?"; then
        warn "Purge cancelled."
        return
    fi

    # First uninstall resources (reuse uninstall logic silently)
    local enabled
    enabled=$(cfg_get "ENABLED_COMPONENTS")

    if [[ "$target_type" == "docker" ]]; then
        local compose_file
        compose_file=$(cfg_get "COMPOSE_FILE")
        if [[ -f "$compose_file" ]]; then
            gum spin --spinner dot --title "Stopping and removing all containers..." -- \
                docker-compose -f "$compose_file" down -v || true
        fi
    else
        local helm_flags kctl_flags
        helm_flags="$(helm_context_flag)"
        kctl_flags="$(kubectl_context_flag)"
        for c in $enabled; do
            # shellcheck disable=SC2086
            helm uninstall "$c" --namespace "${NAMESPACE}" $helm_flags 2>/dev/null || true
            # shellcheck disable=SC2086
            kubectl $kctl_flags delete pv "lgtm-${c}" 2>/dev/null || true
            # shellcheck disable=SC2086
            kubectl $kctl_flags delete storageclass "lgtm-${c}" 2>/dev/null || true
        done
        # shellcheck disable=SC2086
        if kubectl $kctl_flags delete namespace "${NAMESPACE}" 2>/dev/null; then
            info "Waiting for namespace '${NAMESPACE}' to terminate..."
            # shellcheck disable=SC2086
            kubectl $kctl_flags wait --for=delete \
                namespace/"${NAMESPACE}" --timeout=120s 2>/dev/null || \
                warn "Namespace may still be terminating — wait before reinstalling."
        fi
    fi

    # Wipe data
    local base_path
    base_path=$(cfg_get "HOSTPATH_BASE")
    if [[ -n "$base_path" && -d "$base_path" ]]; then
        gum spin --spinner dot --title "Wiping data at ${base_path}..." -- \
            rm -rf "${base_path}"
        success "Data wiped: ${base_path}"
    fi

    # Wipe config
    rm -f "$CONFIG_FILE"
    success "Config removed."

    success "Purge complete."
}

# cmd: status─

cmd_status() {
    header "LGTM — Status"

    cfg_load
    local target_type
    target_type=$(cfg_get "TARGET_TYPE")
    [[ -z "$target_type" ]] && error_exit "No saved config found. Run install first."

    local enabled
    enabled=$(cfg_get "ENABLED_COMPONENTS")

    if [[ "$target_type" == "docker" ]]; then
        local compose_file
        compose_file=$(cfg_get "COMPOSE_FILE")
        [[ -z "$compose_file" || ! -f "$compose_file" ]] && \
            error_exit "Compose file not found: ${compose_file}"

        gum style --foreground "${CYAN}" --bold "── Container Status"
        docker-compose -f "$compose_file" ps

        gum style --foreground "${CYAN}" --bold "── Resource Usage"
        local containers=()
        for c in $enabled; do containers+=("lgtm_${c}"); done
        docker stats --no-stream "${containers[@]}" 2>/dev/null || \
            warn "Could not retrieve resource usage (are containers running?)."

        gum style --foreground "${CYAN}" --bold "── Port Mappings"
        _print_compose_urls "$enabled"
        return
    fi

    # k8s / kind
    local helm_flags kctl_flags
    helm_flags="$(helm_context_flag)"
    kctl_flags="$(kubectl_context_flag)"

    gum style --foreground "${CYAN}" --bold "── Helm Releases"
    # shellcheck disable=SC2086
    helm list --namespace "${NAMESPACE}" $helm_flags 2>/dev/null || \
        warn "No Helm releases found in namespace '${NAMESPACE}'."

    gum style --foreground "${CYAN}" --bold "── Pods"
    # shellcheck disable=SC2086
    kubectl $kctl_flags get pods -n "${NAMESPACE}" \
        -o wide 2>/dev/null || warn "Could not list pods."

    gum style --foreground "${CYAN}" --bold "── Resource Usage (top)"
    # shellcheck disable=SC2086
    kubectl $kctl_flags top pods -n "${NAMESPACE}" 2>/dev/null || \
        warn "kubectl top unavailable (metrics-server not installed?)."

    gum style --foreground "${CYAN}" --bold "── PersistentVolumeClaims"
    # shellcheck disable=SC2086
    kubectl $kctl_flags get pvc -n "${NAMESPACE}" 2>/dev/null || \
        warn "Could not list PVCs."

    gum style --foreground "${CYAN}" --bold "── PersistentVolumes"
    # shellcheck disable=SC2086
    kubectl $kctl_flags get pv 2>/dev/null | grep "lgtm-" || \
        warn "No LGTM PersistentVolumes found."

    gum style --foreground "${CYAN}" --bold "── Active Port-Forwards"
    local found_pf=false
    for c in "${COMPONENTS[@]}"; do
        local pf_file="${PF_DIR}/${c}.pid"
        if pf_is_running "$pf_file"; then
            local port
            port=$(pf_port "$pf_file")
            success "${COMP_LABEL[$c]} → localhost:${port}"
            found_pf=true
        fi
    done
    $found_pf || info "No active port-forwards."
}

# cmd: port-forward─

_print_compose_urls() {
    local enabled="$1"
    for c in $enabled; do
        local port="${COMP_PORT[$c]}"
        info "${COMP_LABEL[$c]} → http://localhost:${port}"
    done
}

cmd_port_forward() {
    header "LGTM — Port Forward"

    cfg_load
    local target_type
    target_type=$(cfg_get "TARGET_TYPE")
    [[ -z "$target_type" ]] && error_exit "No saved config found. Run install first."

    local enabled
    enabled=$(cfg_get "ENABLED_COMPONENTS")

    if [[ "$target_type" == "docker" ]]; then
        gum style --foreground "${CYAN}" "Docker Compose — port mappings are static:"
        _print_compose_urls "$enabled"
        return
    fi

    # k8s / kind — interactive toggle
    local kctl_flags
    kctl_flags="$(kubectl_context_flag)"

    while true; do
        # Build status lines for each component
        local status_lines=()
        for c in $enabled; do
            local pf_file="${PF_DIR}/${c}.pid"
            if pf_is_running "$pf_file"; then
                local port
                port=$(pf_port "$pf_file")
                status_lines+=("[ACTIVE :${port}]  ${COMP_LABEL[$c]}")
            else
                status_lines+=("[  off  ]          ${COMP_LABEL[$c]}")
            fi
        done

        local choice
        choice=$(printf '%s\n' "${status_lines[@]}" "── Back" | gum choose \
            --header "Toggle port-forward (select to start/stop):" \
            --height 15) || true

        [[ -z "$choice" || "$choice" == "── Back" ]] && break

        # Resolve component from chosen line
        local selected_c=""
        for c in $enabled; do
            if echo "$choice" | grep -qF "${COMP_LABEL[$c]}"; then
                selected_c="$c"
                break
            fi
        done
        [[ -z "$selected_c" ]] && continue

        local pf_file="${PF_DIR}/${selected_c}.pid"

        if pf_is_running "$pf_file"; then
            pf_stop "$pf_file"
            info "Port-forward stopped for ${COMP_LABEL[$selected_c]}."
        else
            # Prompt for local port, default to component's default
            local default_port="${COMP_PORT[$selected_c]}"
            local local_port
            local_port=$(gum input \
                --placeholder "$default_port" \
                --header "Local port for ${COMP_LABEL[$selected_c]} (default: ${default_port}):") || true
            [[ -z "$local_port" ]] && local_port="$default_port"

            # Determine remote port (service port)
            local remote_port="$default_port"

            # Use the known service name from the COMP_SVC map rather than
            # grepping, since chart-generated names don't always match the release name.
            local svc_name="${COMP_SVC[$selected_c]}"
            # shellcheck disable=SC2086
            if ! kubectl $kctl_flags get svc "$svc_name" -n "${NAMESPACE}" &>/dev/null; then
                warn "Service '${svc_name}' not found in namespace '${NAMESPACE}'."
                warn "Verify with: kubectl get svc -n ${NAMESPACE}"
                continue
            fi

            # Start port-forward in background
            # shellcheck disable=SC2086
            kubectl $kctl_flags port-forward \
                -n "${NAMESPACE}" \
                "svc/${svc_name}" \
                "${local_port}:${remote_port}" \
                &>/dev/null &
            local pf_pid=$!

            echo "${pf_pid}:${local_port}" > "$pf_file"
            sleep 0.5

            if pf_is_running "$pf_file"; then
                success "${COMP_LABEL[$selected_c]} → http://localhost:${local_port}"
            else
                rm -f "$pf_file"
                warn "Port-forward failed to start for ${COMP_LABEL[$selected_c]}."
            fi
        fi
    done
}

# cmd: start / stop (Docker only)

cmd_start() {
    header "LGTM — Start"

    cfg_load
    local target_type
    target_type=$(cfg_get "TARGET_TYPE")

    if [[ "$target_type" != "docker" ]]; then
        # k8s scale-up
        local kctl_flags
        kctl_flags="$(kubectl_context_flag)"
        local enabled
        enabled=$(cfg_get "ENABLED_COMPONENTS")

        local components_to_start
        components_to_start=$(printf '%s\n' $enabled | \
            gum choose --no-limit \
            --header "Select components to scale up (→ 1 replica):" \
            --height 10) || true
        [[ -z "$components_to_start" ]] && { warn "Nothing selected."; return; }

        for c in $components_to_start; do
            gum spin --spinner dot --title "Scaling up ${COMP_LABEL[$c]}..." -- \
                kubectl $kctl_flags scale deployment "${c}" \
                --replicas=1 -n "${NAMESPACE}" 2>/dev/null || \
                warn "${COMP_LABEL[$c]}: no deployment found (StatefulSet?)."
            success "${COMP_LABEL[$c]} scaled up."
        done
        return
    fi

    local compose_file
    compose_file=$(cfg_get "COMPOSE_FILE")
    [[ -z "$compose_file" || ! -f "$compose_file" ]] && \
        error_exit "Compose file not found. Run install first."

    local enabled
    enabled=$(cfg_get "ENABLED_COMPONENTS")

    local components_to_start
    components_to_start=$(printf '%s\n' $enabled | \
        gum choose --no-limit \
        --header "Select components to start:" \
        --height 10) || true
    [[ -z "$components_to_start" ]] && { warn "Nothing selected."; return; }

    for c in $components_to_start; do
        gum spin --spinner dot --title "Starting ${COMP_LABEL[$c]}..." -- \
            docker-compose -f "$compose_file" up -d "$c"
        success "${COMP_LABEL[$c]} started."
    done
}

cmd_stop() {
    header "LGTM — Stop"

    cfg_load
    local target_type
    target_type=$(cfg_get "TARGET_TYPE")

    if [[ "$target_type" != "docker" ]]; then
        # k8s scale-down
        local kctl_flags
        kctl_flags="$(kubectl_context_flag)"
        local enabled
        enabled=$(cfg_get "ENABLED_COMPONENTS")

        local components_to_stop
        components_to_stop=$(printf '%s\n' $enabled | \
            gum choose --no-limit \
            --header "Select components to scale down (→ 0 replicas):" \
            --height 10) || true
        [[ -z "$components_to_stop" ]] && { warn "Nothing selected."; return; }

        for c in $components_to_stop; do
            gum spin --spinner dot --title "Scaling down ${COMP_LABEL[$c]}..." -- \
                kubectl $kctl_flags scale deployment "${c}" \
                --replicas=0 -n "${NAMESPACE}" 2>/dev/null || \
                warn "${COMP_LABEL[$c]}: no deployment found (StatefulSet?)."
            success "${COMP_LABEL[$c]} scaled to 0."
        done
        return
    fi

    local compose_file
    compose_file=$(cfg_get "COMPOSE_FILE")
    [[ -z "$compose_file" || ! -f "$compose_file" ]] && \
        error_exit "Compose file not found. Run install first."

    local enabled
    enabled=$(cfg_get "ENABLED_COMPONENTS")

    local components_to_stop
    components_to_stop=$(printf '%s\n' $enabled | \
        gum choose --no-limit \
        --header "Select components to stop:" \
        --height 10) || true
    [[ -z "$components_to_stop" ]] && { warn "Nothing selected."; return; }

    for c in $components_to_stop; do
        gum spin --spinner dot --title "Stopping ${COMP_LABEL[$c]}..." -- \
            docker-compose -f "$compose_file" stop "$c"
        success "${COMP_LABEL[$c]} stopped."
    done
}

# cmd: update (helm repo refresh)

cmd_update() {
    header "LGTM — Update Helm Repos"

    _ensure_helm "LGTM stack"

    gum spin --spinner dot --title "Updating Grafana Helm repo..." -- \
        helm repo update "$HELM_REPO_NAME" 2>/dev/null || \
        warn "Grafana repo update failed (not added yet?)."

    gum spin --spinner dot --title "Updating OpenTelemetry Helm repo..." -- \
        helm repo update "$OTEL_HELM_REPO_NAME" 2>/dev/null || \
        warn "OTel repo update failed (not added yet?)."

    success "Helm repos updated."
    info "Note: chart versions in this script are pinned. Bumping them requires explicit edits."
}

# main TUI

main() {
    if ! command -v gum &>/dev/null; then
        echo "[error] gum is not installed. Run setup.sh first." >&2
        exit 1
    fi

    # If called with a subcommand argument, dispatch directly (non-interactive)
    if [[ $# -gt 0 ]]; then
        case "$1" in
            install)      cmd_install      ;;
            uninstall)    cmd_uninstall    ;;
            purge)        cmd_purge        ;;
            status)       cmd_status       ;;
            port-forward) cmd_port_forward ;;
            start)        cmd_start        ;;
            stop)         cmd_stop         ;;
            update)       cmd_update       ;;
            *)
                error_exit "Unknown subcommand: $1
Usage: lgtm.sh [install|uninstall|purge|status|port-forward|start|stop|update]"
                ;;
        esac
        return
    fi

    # Interactive TUI loop
    while true; do
        header "LGTM Stack Manager"

        local action
        action=$(gum choose \
            --header "Select action:" \
            --height 15 \
            "install       — guided install (k8s or Docker)" \
            "uninstall     — remove stack, keep data" \
            "purge         — remove stack + wipe all data" \
            "status        — stack health, resources, PVCs" \
            "port-forward  — toggle per-component tunnels" \
            "start         — start / scale-up components" \
            "stop          — stop / scale-down components" \
            "update        — refresh Helm repo cache" \
            "── quit") || true

        [[ -z "$action" || "$action" == "── quit" ]] && {
            gum style --faint "Bye."
            exit 0
        }

        case "$action" in
            install*)      cmd_install      ;;
            uninstall*)    cmd_uninstall    ;;
            purge*)        cmd_purge        ;;
            status*)       cmd_status       ;;
            port-forward*) cmd_port_forward ;;
            start*)        cmd_start        ;;
            stop*)         cmd_stop         ;;
            update*)       cmd_update       ;;
        esac

        echo ""
        gum confirm "Back to main menu?" || { gum style --faint "Bye."; exit 0; }
    done
}

main "$@"