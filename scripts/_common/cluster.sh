#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# cluster/cluster.sh — Deployment target detection and selection
# Meant to be SOURCED by app scripts, not run directly.
#
# Usage in an app script:
#   CLUSTER_SH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../cluster/cluster.sh"
#   source "$CLUSTER_SH"
#   select_target          # prompts the user; sets TARGET_TYPE and TARGET_CONTEXT
#
# After select_target():
#   TARGET_TYPE    = "docker" | "kind" | "k8s"
#   TARGET_CONTEXT = "" (docker) | cluster name (kind) | context name (k8s)
#
# Calling scripts branch on TARGET_TYPE:
#   case "$TARGET_TYPE" in
#     docker) ... docker run / compose ... ;;
#     kind)   ... helm --kube-context "kind-${TARGET_CONTEXT}" ... ;;
#     k8s)    ... helm --kube-context "${TARGET_CONTEXT}" ... ;;
#   esac
# -----------------------------------------------------------------------------

# Exported after select_target()
TARGET_TYPE=""
TARGET_CONTEXT=""

# Colours (reuse caller's values if already set)
_C_CYAN="${CYAN:-212}"
_C_YELLOW="${YELLOW:-220}"
_C_RED="${RED:-196}"

_cluster_log()  { gum log --level info "$1"; }
_cluster_warn() { gum style --foreground "$_C_YELLOW" "[warn] $1"; }
_cluster_err()  { gum style --foreground "$_C_RED" "[error] $1"; }

# -----------------------------------------------------------------------------
# Probes
# -----------------------------------------------------------------------------

_docker_available() {
    command -v docker &>/dev/null && docker info &>/dev/null 2>&1
}

_kind_available() {
    command -v kind &>/dev/null
}

_kubectl_available() {
    command -v kubectl &>/dev/null
}

# Returns newline-separated kind cluster names (empty if none / kind missing).
_kind_clusters() {
    _kind_available || return 0
    kind get clusters 2>/dev/null || true
}

# Returns newline-separated kubeconfig context names that are NOT kind clusters.
# kind contexts follow the "kind-<name>" convention and are already surfaced via
# _kind_clusters(), so we exclude them here to avoid duplicates in the picker.
_k8s_contexts() {
    _kubectl_available || return 0
    kubectl config get-contexts -o name 2>/dev/null \
        | grep -v '^kind-' \
        || true
}

# -----------------------------------------------------------------------------
# Target builder
# -----------------------------------------------------------------------------

# Populates parallel arrays OPTION_LABELS and OPTION_TYPES / OPTION_CONTEXTS
# with every reachable target.
_build_options() {
    OPTION_LABELS=()
    OPTION_TYPES=()
    OPTION_CONTEXTS=()

    # Docker
    if _docker_available; then
        OPTION_LABELS+=("Docker  (local daemon)")
        OPTION_TYPES+=("docker")
        OPTION_CONTEXTS+=("")
    fi

    # kind clusters
    local kind_list
    kind_list=$(_kind_clusters)
    if [[ -n "$kind_list" ]]; then
        while IFS= read -r cluster; do
            [[ -z "$cluster" ]] && continue
            OPTION_LABELS+=("kind    ${cluster}")
            OPTION_TYPES+=("kind")
            OPTION_CONTEXTS+=("${cluster}")
        done <<< "$kind_list"
    fi

    # plain k8s contexts
    local k8s_list
    k8s_list=$(_k8s_contexts)
    if [[ -n "$k8s_list" ]]; then
        while IFS= read -r ctx; do
            [[ -z "$ctx" ]] && continue
            OPTION_LABELS+=("k8s     ${ctx}")
            OPTION_TYPES+=("k8s")
            OPTION_CONTEXTS+=("${ctx}")
        done <<< "$k8s_list"
    fi
}

# -----------------------------------------------------------------------------
# Public API
# -----------------------------------------------------------------------------

# Detects available targets, prompts the user when there are multiple, and
# sets TARGET_TYPE + TARGET_CONTEXT.  Exits (non-zero) if nothing is available
# or the user cancels.
select_target() {
    local -a OPTION_LABELS OPTION_TYPES OPTION_CONTEXTS
    _build_options

    local count="${#OPTION_LABELS[@]}"

    if [[ "$count" -eq 0 ]]; then
        _cluster_err "No deployment targets found."
        _cluster_err "Start Docker, create a kind cluster, or configure a kubeconfig context."
        return 1
    fi

    local chosen_label
    if [[ "$count" -eq 1 ]]; then
        chosen_label="${OPTION_LABELS[0]}"
        _cluster_log "Single target available: ${chosen_label}"
    else
        chosen_label=$(printf '%s\n' "${OPTION_LABELS[@]}" | gum choose \
            --header "Select deployment target:" \
            --height 15) || true

        if [[ -z "$chosen_label" ]]; then
            _cluster_warn "No target selected. Aborting."
            return 1
        fi
    fi

    # Resolve chosen label back to type + context via index match
    local i
    for i in "${!OPTION_LABELS[@]}"; do
        if [[ "${OPTION_LABELS[$i]}" == "$chosen_label" ]]; then
            TARGET_TYPE="${OPTION_TYPES[$i]}"
            TARGET_CONTEXT="${OPTION_CONTEXTS[$i]}"
            break
        fi
    done

    gum style \
        --foreground "$_C_CYAN" --border-foreground "$_C_CYAN" --border rounded \
        --align center --width 60 --margin "1 2" --padding "1 2" \
        "Target: ${TARGET_TYPE}${TARGET_CONTEXT:+  /  ${TARGET_CONTEXT}}"
}

# Returns the --kube-context flag for helm commands.
# Empty string if TARGET_TYPE is docker.
helm_context_flag() {
    case "$TARGET_TYPE" in
        kind)   echo "--kube-context kind-${TARGET_CONTEXT}" ;;
        k8s)    echo "--kube-context ${TARGET_CONTEXT}" ;;
        docker) echo "" ;;
    esac
}

# Returns the --context flag for kubectl commands.
# kubectl uses --context; helm uses --kube-context — they are not interchangeable.
kubectl_context_flag() {
    case "$TARGET_TYPE" in
        kind)   echo "--context kind-${TARGET_CONTEXT}" ;;
        k8s)    echo "--context ${TARGET_CONTEXT}" ;;
        docker) echo "" ;;
    esac
}

# Prints a short human-readable summary of the active target.
target_summary() {
    case "$TARGET_TYPE" in
        docker) echo "Docker (local daemon)" ;;
        kind)   echo "kind cluster: ${TARGET_CONTEXT}" ;;
        k8s)    echo "k8s context: ${TARGET_CONTEXT}" ;;
        *)      echo "(no target selected)" ;;
    esac
}
