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

METRICS_SERVER_HELM_REPO_NAME="metrics-server"
METRICS_SERVER_HELM_REPO_URL="https://kubernetes-sigs.github.io/metrics-server/"
METRICS_SERVER_CHART_VERSION="3.12.2"

NAMESPACE="monitoring"

# XDG config
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/lgtm"
# Expand a literal leading '~' — happens when XDG_CONFIG_HOME is exported as
# "~/.config" (tilde isn't expanded inside ${VAR:-…}).
CONFIG_DIR="${CONFIG_DIR/#\~/$HOME}"
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

# Actual service ports exposed by each Helm chart (remote side of kubectl port-forward).
# These differ from COMP_PORT when the chart fronts traffic through a gateway/nginx on port 80.
declare -A COMP_SVC_PORT=(
    [grafana]="80"     # grafana chart service listens on 80, proxies to container 3000
    [loki]="3100"
    [tempo]="3100"
    [mimir]="80"       # mimir-nginx gateway listens on 80
    [otelcol]="4317"
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
    [[ -f "$CONFIG_FILE" ]] || return 0
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
}

# cfg_require [error-message]
# Loads config, validates TARGET_TYPE is set, echoes it for capture.
# Use as: target_type=$(cfg_require "Nothing to uninstall.")
cfg_require() {
    local msg="${1:-No saved config found. Run install first.}"
    cfg_load
    local target_type
    target_type=$(cfg_get "TARGET_TYPE")
    if [[ -z "$target_type" ]]; then
        # Before failing, see if the cluster has an existing LGTM install we
        # could adopt — and offer to run import inline. Saves the user from
        # having to know about a separate subcommand when the stack is right
        # there in the current context.
        if _lgtm_detect_in_cluster; then
            warn "Detected LGTM-like resources in the current kube-context."
            # gum confirm reads /dev/tty directly, so stdin redirection (the
            # outer $() captures stdout, not stdin) doesn't break the prompt.
            if gum confirm "Adopt them now (run import)?"; then
                # cmd_import's stdout (header, info, success) must NOT be
                # captured by the outer $(cfg_require) — redirect to stderr so
                # the user sees the import UX live and the caller still gets a
                # clean target_type back from our trailing printf.
                cmd_import >&2
                cfg_load
                target_type=$(cfg_get "TARGET_TYPE")
                if [[ -n "$target_type" ]]; then
                    printf '%s\n' "$target_type"
                    return 0
                fi
            fi
        fi
        error_exit "$msg"
    fi
    printf '%s\n' "$target_type"
}

# Cheap probe: does the current kube-context have any LGTM-shaped services?
# Used by cfg_require to nudge toward 'import' when the user's stack was
# deployed outside this script.
_lgtm_detect_in_cluster() {
    command -v kubectl &>/dev/null || return 1
    kubectl get svc -A -o name 2>/dev/null \
        | grep -qiE '/(grafana|loki|tempo|mimir|otelcol|opentelemetry)'
}

# Check whether a single LGTM component is present in a namespace.
# Tries the canonical Service name from COMP_SVC first (fast path), then falls
# back to a name-pattern match across svc/deploy/sts (so non-standard releases
# with prefixes/suffixes still get picked up).
_component_present() {
    local ns="$1" component="$2" ctx="$3"
    local canonical="${COMP_SVC[$component]}"
    # shellcheck disable=SC2086
    kubectl $ctx -n "$ns" get svc "$canonical" &>/dev/null && return 0
    local pattern
    case "$component" in
        otelcol) pattern='otel|opentelemetry' ;;
        *)       pattern="(^|/)${component}" ;;
    esac
    # shellcheck disable=SC2086
    kubectl $ctx -n "$ns" get svc,deploy,sts -o name 2>/dev/null \
        | grep -qiE "$pattern"
}

# resource profiles─

# Minimal (kind / local dev)
declare -A MINIMAL_CPU_REQ=([grafana]="50m"  [loki]="50m"  [tempo]="50m"  [mimir]="100m" [otelcol]="100m")
declare -A MINIMAL_CPU_LIM=([grafana]="200m" [loki]="200m" [tempo]="200m" [mimir]="500m" [otelcol]="500m")
declare -A MINIMAL_MEM_REQ=([grafana]="64Mi"  [loki]="64Mi"  [tempo]="64Mi"  [mimir]="256Mi" [otelcol]="128Mi")
declare -A MINIMAL_MEM_LIM=([grafana]="256Mi" [loki]="256Mi" [tempo]="256Mi" [mimir]="1Gi"   [otelcol]="512Mi")
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
datasources:
  datasources.yaml:
    apiVersion: 1
    datasources:
      - name: Mimir
        type: prometheus
        uid: mimir
        url: http://mimir-nginx.${NAMESPACE}.svc.cluster.local/prometheus
        isDefault: true
        jsonData:
          timeInterval: 15s
      - name: Loki
        type: loki
        uid: loki
        url: http://loki.${NAMESPACE}.svc.cluster.local:3100
      - name: Tempo
        type: tempo
        uid: tempo
        url: http://tempo.${NAMESPACE}.svc.cluster.local:3100
        jsonData:
          tracesToLogsV2:
            datasourceUid: loki
            spanStartTimeShift: "-1h"
            spanEndTimeShift: "1h"
            tags:
              - key: service.name
                value: app
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
# The contrib image is heavier than the core image; give the Go runtime time to
# settle before the probes start and tolerate brief GC-induced stalls.
livenessProbe:
  httpGet:
    path: /
    port: 13133
  initialDelaySeconds: 10
  periodSeconds: 15
  timeoutSeconds: 5
  failureThreshold: 5
readinessProbe:
  httpGet:
    path: /
    port: 13133
  initialDelaySeconds: 10
  periodSeconds: 10
  timeoutSeconds: 5
  failureThreshold: 3
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

_install_metrics_server() {
    local helm_flags="$1"
    # kind uses self-signed kubelet certs — insecure TLS is required.
    # On real clusters the flag is harmless but unnecessary; helm values handle it.
    local extra_args=""
    [[ "$TARGET_TYPE" == "kind" ]] && extra_args="--set args={--kubelet-insecure-tls}"

    _ensure_helm_repo "$METRICS_SERVER_HELM_REPO_NAME" "$METRICS_SERVER_HELM_REPO_URL"

    local out
    # shellcheck disable=SC2086
    if ! out=$(helm upgrade --install metrics-server \
            "${METRICS_SERVER_HELM_REPO_NAME}/metrics-server" \
            --version "${METRICS_SERVER_CHART_VERSION}" \
            --namespace kube-system \
            $extra_args \
            $helm_flags 2>&1); then
        warn "metrics-server install failed:"
        echo "$out"
        return 1
    fi
    success "metrics-server installed."
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

# cmd: import — adopt an existing LGTM-shaped install
#
# Useful when the stack was deployed outside this script (manual helm, GitOps,
# other tooling). Probes the chosen kube-context, lets the user pick a
# namespace, detects which components are present, and writes a conf that
# points at the live stack. Subsequent commands (status, port-forward, start,
# stop, test) then work normally. uninstall/purge are gated by the
# INSTALL_METHOD=external marker so the tool can't accidentally delete a
# stack it didn't deploy.
# ─────────────────────────────────────────────────────────────────────────────

cmd_import() {
    header "LGTM — Import existing install"

    select_target

    if [[ "$TARGET_TYPE" == "docker" ]]; then
        error_exit "Import is for Kubernetes installs. For Docker, just run 'install'."
    fi

    local ctx_flags
    ctx_flags="$(kubectl_context_flag)"

    info "Scanning '${TARGET_CONTEXT}' for LGTM-like services..."

    # Find namespaces containing at least one matching service. jsonpath lets
    # us cheaply emit "namespace|service" pairs without spawning yq/jq.
    local candidates
    # shellcheck disable=SC2086
    candidates=$(kubectl $ctx_flags get svc -A \
        -o jsonpath='{range .items[*]}{.metadata.namespace}|{.metadata.name}{"\n"}{end}' 2>/dev/null \
        | grep -iE '\|(grafana|loki|tempo|mimir|otelcol|opentelemetry)' \
        | cut -d'|' -f1 | sort -u)

    local target_ns
    if [[ -z "$candidates" ]]; then
        warn "No LGTM-shaped services found via name match."
        if ! gum confirm "Pick a namespace manually anyway?"; then
            error_exit "Import cancelled."
        fi
        # shellcheck disable=SC2086
        candidates=$(kubectl $ctx_flags get ns -o name 2>/dev/null \
            | sed 's|namespace/||' \
            | grep -vE '^(kube-|default$)')
        [[ -z "$candidates" ]] && error_exit "No namespaces available."
        target_ns=$(echo "$candidates" | gum choose --header "Select namespace:") || true
        [[ -z "$target_ns" ]] && error_exit "No namespace selected."
    else
        local n_ns
        n_ns=$(echo "$candidates" | wc -l | tr -d ' ')
        if [[ "$n_ns" -eq 1 ]]; then
            target_ns="$candidates"
            info "Detected LGTM components in namespace: ${target_ns}"
        else
            target_ns=$(echo "$candidates" | gum choose \
                --header "Multiple namespaces have LGTM components — pick one:") || true
            [[ -z "$target_ns" ]] && error_exit "No namespace selected."
        fi
    fi

    # Detect which components are present in that namespace
    info "Probing components in '${target_ns}'..."
    local found_components="" missing_components=""
    local c
    for c in "${COMPONENTS[@]}"; do
        if _component_present "$target_ns" "$c" "$ctx_flags"; then
            found_components+="$c "
        else
            missing_components+="$c "
        fi
    done
    found_components=$(echo "$found_components" | xargs)
    missing_components=$(echo "$missing_components" | xargs)

    if [[ -z "$found_components" ]]; then
        error_exit "No managed LGTM components found in '${target_ns}'."
    fi

    success "Found: ${found_components}"
    [[ -n "$missing_components" ]] && info "Not present (won't be managed): ${missing_components}"

    # Profile is informational only — import doesn't reapply Helm values.
    local profile
    profile=$(gum choose --header "Resource profile (informational only, no reapply):" \
        "minimal" "standard" "custom") || true
    profile="${profile:-standard}"

    # Persist config. NAMESPACE is the live one (may differ from the default
    # "monitoring"); subsequent commands source the conf via cfg_load and
    # override the default constant set at script load.
    cfg_set "TARGET_TYPE"        "$TARGET_TYPE"
    cfg_set "TARGET_CONTEXT"     "$TARGET_CONTEXT"
    cfg_set "NAMESPACE"          "$target_ns"
    cfg_set "ENABLED_COMPONENTS" "$found_components"
    cfg_set "RESOURCE_PROFILE"   "$profile"
    cfg_set "INSTALL_METHOD"     "external"

    success "Imported. Config written to ${CONFIG_FILE}."
    info  "Try: lgtm.sh status   or   lgtm.sh port-forward"
    warn  "'uninstall' and 'purge' will require extra confirmation for imported stacks."
}

# cmd: uninstall────

cmd_uninstall() {
    header "LGTM — Uninstall"

    local target_type ctx_flags
    target_type=$(cfg_require "No saved config found. Nothing to uninstall.")

    # Imported stack guard: this stack wasn't deployed by lgtm.sh, so its
    # Helm release names may not match what this script expects. uninstall
    # could fail or partially remove. Make the user opt in explicitly.
    local install_method
    install_method=$(cfg_get "INSTALL_METHOD")
    if [[ "$install_method" == "external" ]]; then
        warn "This stack was IMPORTED — not deployed by lgtm.sh."
        warn "Helm release names may differ from what this script assumes;"
        warn "uninstall may fail or only partially remove resources."
        warn "Prefer 'helm uninstall <release>' directly for imported stacks."
        if ! gum confirm "Proceed with lgtm.sh uninstall anyway?"; then
            info "Cancelled."
            return
        fi
    fi

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

    local target_type
    target_type=$(cfg_require "No saved config found. Nothing to purge.")

    # Imported stack guard — purge does helm uninstall + wipe data. For a stack
    # this tool didn't deploy, that's almost never what the user wants.
    local install_method
    install_method=$(cfg_get "INSTALL_METHOD")
    if [[ "$install_method" == "external" ]]; then
        warn "This stack was IMPORTED — not deployed by lgtm.sh."
        warn "Purging will attempt to helm-uninstall releases this script didn't create"
        warn "and wipe data this script didn't provision. Almost certainly not what you want."
        if ! gum confirm --affirmative "Yes, purge anyway" --negative "Cancel" \
            "Continue with purge of an imported stack?"; then
            info "Cancelled."
            return
        fi
    fi

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
            # Wrap the wait in gum spin so the user sees a live spinner instead
            # of a silent 60-120s pause that reads like a hang. Namespace
            # termination on a stack with many CRD instances / finalizers can
            # easily take that long.
            # shellcheck disable=SC2086
            if gum spin --spinner dot \
                --title "Waiting for namespace '${NAMESPACE}' to terminate..." -- \
                kubectl $kctl_flags wait --for=delete \
                    namespace/"${NAMESPACE}" --timeout=120s; then
                success "Namespace '${NAMESPACE}' terminated."
            else
                warn "Namespace did not terminate within 120s — wait before reinstalling."
                warn "Inspect stuck finalizers with: kubectl get ns ${NAMESPACE} -o yaml"
            fi
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

    local target_type
    target_type=$(cfg_require)

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
    if ! kubectl $kctl_flags top pods -n "${NAMESPACE}" 2>/dev/null; then
        warn "kubectl top unavailable — metrics-server not installed."
        if gum confirm "Install metrics-server now?"; then
            _install_metrics_server "$helm_flags" "$kctl_flags"
            # shellcheck disable=SC2086
            kubectl $kctl_flags top pods -n "${NAMESPACE}" 2>/dev/null || \
                info "metrics-server is starting — re-run status in ~30 s."
        fi
    fi

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

    local target_type
    target_type=$(cfg_require)

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

            # Determine remote port (actual service port, may differ from local)
            local remote_port="${COMP_SVC_PORT[$selected_c]}"

            # Use the known service name from the COMP_SVC map rather than
            # grepping, since chart-generated names don't always match the release name.
            local svc_name="${COMP_SVC[$selected_c]}"
            # shellcheck disable=SC2086
            if ! kubectl $kctl_flags get svc "$svc_name" -n "${NAMESPACE}" &>/dev/null; then
                warn "Service '${svc_name}' not found in namespace '${NAMESPACE}'."
                warn "Verify with: kubectl get svc -n ${NAMESPACE}"
                continue
            fi

            # Auto-reconnect wrapper: kubectl port-forward dies when the backing pod
            # is replaced (rollout, eviction, crash). Looping in a subshell keeps the
            # tunnel alive across restarts. Trap forwards signals to the kubectl child
            # so pf_stop can take the whole thing down cleanly. set +e because `wait`
            # returns the child's non-zero exit when killed, which would otherwise kill
            # the wrapper on the first reconnect.
            (
                set +e
                trap 'kill "${child:-0}" 2>/dev/null; exit 0' TERM INT HUP
                while true; do
                    # shellcheck disable=SC2086
                    kubectl $kctl_flags port-forward \
                        -n "${NAMESPACE}" \
                        "svc/${svc_name}" \
                        "${local_port}:${remote_port}" \
                        &>/dev/null &
                    child=$!
                    wait "$child" 2>/dev/null
                    sleep 2
                done
            ) &
            local pf_pid=$!

            echo "${pf_pid}:${local_port}" > "$pf_file"
            sleep 2

            # Verify something is listening — if not, the wrapper is spinning on
            # failed kubectl invocations (port in use, service not ready).
            if lsof -i ":${local_port}" -sTCP:LISTEN >/dev/null 2>&1; then
                success "${COMP_LABEL[$selected_c]} → http://localhost:${local_port} (auto-reconnect)"
            else
                pkill -P "$pf_pid" 2>/dev/null || true
                kill "$pf_pid" 2>/dev/null || true
                rm -f "$pf_file"
                warn "Port-forward failed to start for ${COMP_LABEL[$selected_c]} (port in use, or service not ready)."
            fi
        fi
    done
}

# cmd: start / stop (Docker only)

cmd_start() {
    header "LGTM — Start"

    local target_type
    target_type=$(cfg_require)

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

    local target_type
    target_type=$(cfg_require)

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
            # Tear down the per-component port-forward first — the backing pod
            # is about to disappear, and the auto-reconnect wrapper (see
            # cmd_port_forward) would otherwise spin trying to reconnect.
            local pf_file="${PF_DIR}/${c}.pid"
            if pf_is_running "$pf_file"; then
                pf_stop "$pf_file"
            fi

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

# cmd: test ───────────────────────────────────────────────────────────────────
# Pushes one log (Loki), one trace (Tempo via OTel), one metric (Mimir via OTel)
# and prints where to find them in Grafana.

cmd_test() {
    header "LGTM — Send Test Data"

    local target_type
    target_type=$(cfg_require)
    if [[ "$target_type" == "docker" ]]; then
        error_exit "Test command requires k8s or kind."
    fi

    command -v curl &>/dev/null || error_exit "curl is required for this command."

    local helm_flags kctl_flags
    helm_flags="$(helm_context_flag)"
    kctl_flags="$(kubectl_context_flag)"

    # Ensure PROF_* arrays are populated so _helm_values_grafana can render properly
    _apply_profile "$(cfg_get "RESOURCE_PROFILE")"

    # Upgrade grafana to provision datasources if they are not yet configured
    # shellcheck disable=SC2086
    if ! helm get values grafana -n "${NAMESPACE}" $helm_flags 2>/dev/null \
            | grep -q "datasources:"; then
        info "Provisioning Grafana datasources (first-time setup)..."
        _helm_install_component "grafana" "$helm_flags" "$kctl_flags" || \
            warn "Grafana upgrade failed — datasources may not be configured yet."
    fi

    # Temporary port-forwards on high ports to avoid colliding with active ones
    local loki_port=13100 otel_port=14318
    local loki_pf_pid otel_pf_pid

    info "Starting temporary port-forwards..."
    # shellcheck disable=SC2086
    kubectl $kctl_flags port-forward svc/loki \
        -n "${NAMESPACE}" "${loki_port}:3100" &>/dev/null &
    loki_pf_pid=$!
    # shellcheck disable=SC2086
    kubectl $kctl_flags port-forward \
        svc/otelcol-opentelemetry-collector \
        -n "${NAMESPACE}" "${otel_port}:4318" &>/dev/null &
    otel_pf_pid=$!
    # Use INT/TERM only — RETURN fires on every function return within this function,
    # which would kill the port-forwards before curl can use them.
    # shellcheck disable=SC2064
    trap "kill ${loki_pf_pid} ${otel_pf_pid} 2>/dev/null || true" INT TERM

    sleep 2  # give port-forwards time to establish

    local ts_ns
    ts_ns=$(date +%s%N)
    local trace_id span_id
    trace_id=$(openssl rand -hex 16 2>/dev/null \
        || printf '%08x%08x%08x%08x' $RANDOM $RANDOM $RANDOM $RANDOM)
    span_id=$(openssl rand -hex 8 2>/dev/null \
        || printf '%08x%08x' $RANDOM $RANDOM)
    local end_ns=$(( ts_ns + 500000000 ))

    # ── Loki: push log directly via push API ──────────────────────────────────
    info "Pushing test log to Loki..."
    if curl -sf -X POST "http://localhost:${loki_port}/loki/api/v1/push" \
            -H "Content-Type: application/json" \
            -d "{\"streams\":[{\"stream\":{\"app\":\"lgtm-test\",\"env\":\"${TARGET_TYPE}\"},\
\"values\":[[\"${ts_ns}\",\"[lgtm-test] hello from cmd_test trace_id=${trace_id}\"]]}]}" \
            &>/dev/null; then
        success "Log sent to Loki."
    else
        warn "Loki push failed — check: kubectl get pods -n ${NAMESPACE}"
    fi

    # ── Tempo: OTLP HTTP via OTel collector ───────────────────────────────────
    info "Pushing test trace to Tempo via OTel collector..."
    if curl -sf -X POST "http://localhost:${otel_port}/v1/traces" \
            -H "Content-Type: application/json" \
            -d "{\"resourceSpans\":[{\"resource\":{\"attributes\":[{\"key\":\"service.name\",\
\"value\":{\"stringValue\":\"lgtm-test\"}}]},\"scopeSpans\":[{\"scope\":{\"name\":\
\"lgtm-test\"},\"spans\":[{\"traceId\":\"${trace_id}\",\"spanId\":\"${span_id}\",\
\"name\":\"test-span\",\"kind\":1,\"startTimeUnixNano\":\"${ts_ns}\",\
\"endTimeUnixNano\":\"${end_ns}\",\"status\":{}}]}]}]}" \
            &>/dev/null; then
        success "Trace sent to Tempo."
    else
        warn "OTel push failed — check: kubectl get pods -n ${NAMESPACE}"
    fi

    # ── Mimir: OTLP HTTP via OTel collector ───────────────────────────────────
    info "Pushing test metric to Mimir via OTel collector..."
    if curl -sf -X POST "http://localhost:${otel_port}/v1/metrics" \
            -H "Content-Type: application/json" \
            -d "{\"resourceMetrics\":[{\"resource\":{\"attributes\":[{\"key\":\
\"service.name\",\"value\":{\"stringValue\":\"lgtm-test\"}}]},\"scopeMetrics\":\
[{\"metrics\":[{\"name\":\"lgtm_test_requests_total\",\"sum\":{\"dataPoints\":\
[{\"attributes\":[{\"key\":\"env\",\"value\":{\"stringValue\":\"${TARGET_TYPE}\"}}],\
\"startTimeUnixNano\":\"${ts_ns}\",\"timeUnixNano\":\"${ts_ns}\",\"asInt\":\"1\"}],\
\"aggregationTemporality\":2,\"isMonotonic\":true}}]}]}]}" \
            &>/dev/null; then
        success "Metric sent to Mimir."
    else
        warn "OTel push failed — check: kubectl get pods -n ${NAMESPACE}"
    fi

    kill "$loki_pf_pid" "$otel_pf_pid" 2>/dev/null || true
    trap - INT TERM

    gum style \
        --foreground "${CYAN}" --border-foreground "${CYAN}" --border rounded \
        --align left --width 70 --margin "1 2" --padding "1 2" \
        "$(printf 'Open Grafana → localhost:3000  (admin / admin)\n\nLogs    Explore → Loki  → {app="lgtm-test"}\nTraces  Explore → Tempo → Trace ID:\n        %s\nMetrics Explore → Mimir → lgtm_test_requests_total' "$trace_id")"
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
            import)       cmd_import       ;;
            uninstall)    cmd_uninstall    ;;
            purge)        cmd_purge        ;;
            status)       cmd_status       ;;
            port-forward) cmd_port_forward ;;
            start)        cmd_start        ;;
            stop)         cmd_stop         ;;
            update)       cmd_update       ;;
            test)         cmd_test         ;;
            *)
                error_exit "Unknown subcommand: $1
Usage: lgtm.sh [install|import|uninstall|purge|status|port-forward|start|stop|update|test]"
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
            "import        — adopt an existing install (no Helm changes)" \
            "uninstall     — remove stack, keep data" \
            "purge         — remove stack + wipe all data" \
            "status        — stack health, resources, PVCs" \
            "port-forward  — toggle per-component tunnels" \
            "start         — start / scale-up components" \
            "stop          — stop / scale-down components" \
            "update        — refresh Helm repo cache" \
            "test          — push sample log, trace, metric and print where to find them" \
            "── quit") || true

        [[ -z "$action" || "$action" == "── quit" ]] && {
            gum style --faint "Bye."
            exit 0
        }

        case "$action" in
            install*)      cmd_install      ;;
            import*)       cmd_import       ;;
            uninstall*)    cmd_uninstall    ;;
            purge*)        cmd_purge        ;;
            status*)       cmd_status       ;;
            port-forward*) cmd_port_forward ;;
            start*)        cmd_start        ;;
            stop*)         cmd_stop         ;;
            update*)       cmd_update       ;;
            test*)         cmd_test         ;;
        esac

        echo ""
        gum confirm "Back to main menu?" || { gum style --faint "Bye."; exit 0; }
    done
}

main "$@"