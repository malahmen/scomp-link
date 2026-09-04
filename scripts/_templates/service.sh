#!/usr/bin/env bash
# description: TODO one-line summary the launcher shows (e.g. "Foo: install, connect, manage (Docker/K8s)")
# export-setup: kubectl helm
# -----------------------------------------------------------------------------
# TEMPLATE — Docker/K8s service manager.
#
# The shape shared by the database + platform scripts (postgres, mariadb, redis,
# n8n, grafana, …): pick a deployment target (Docker container or a Kubernetes
# Helm release), then install / status / connect / uninstall against it, with the
# instance name (container / namespace+release) prompted per session.
#
# HOW TO USE: copy this folder to scripts/<name>/, rename this file to <name>.sh,
# then find every TODO and replace the FOO_* names, the image/chart, the ports,
# and the connect command with your tool's specifics. Delete this block.
# -----------------------------------------------------------------------------

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -d "${SCRIPT_DIR}/../_common" ]]; then
    COMMON_DIR="${SCRIPT_DIR}/../_common"   # scomp-link repo layout
else
    COMMON_DIR="${SCRIPT_DIR}"              # exported standalone: deps sit alongside
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
# Constants / defaults   — TODO: rename FOO_* and set real values
# -----------------------------------------------------------------------------
FOO_NAMESPACE="foo"
FOO_HELM_RELEASE="foo"
FOO_HELM_REPO_NAME="TODO-repo"                         # e.g. groundhog2k
FOO_HELM_REPO_URL="https://TODO.example/helm-charts/"  # a maintained chart repo (avoid Bitnami)
FOO_HELM_CHART="TODO-repo/foo"
FOO_DEFAULT_PORT=1234
FOO_DEFAULT_IMAGE_TAG="latest"                         # prefer the official image + a pinned tag
_FOO_PF_PID="/tmp/scomp-pf-foo.pid"

# Session state — populated by the menus
FOO_CONTAINER_NAME="foo"
FOO_IMAGE_TAG="$FOO_DEFAULT_IMAGE_TAG"
FOO_PORT=$FOO_DEFAULT_PORT

BLUE=39

# -----------------------------------------------------------------------------
# Dependencies
# -----------------------------------------------------------------------------
check_dependencies() {
    info "Checking dependencies..."
    case "$TARGET_TYPE" in
        docker)   _check_docker ;;
        kind|k8s) _check_kubectl; _ensure_helm "Foo" ;;
    esac
}

# -----------------------------------------------------------------------------
# Docker target
# -----------------------------------------------------------------------------
_docker_container_exists()  { docker inspect "$1" &>/dev/null 2>&1; }
_docker_container_running() { [[ "$(docker inspect --format='{{.State.Running}}' "$1" 2>/dev/null)" == "true" ]]; }

foo_install_docker() {
    header "Install Foo — Docker"
    # TODO: prompt for image tag / port / credentials as needed, then:
    local image="foo:${FOO_IMAGE_TAG}"   # TODO: real official image
    _docker_container_exists "$FOO_CONTAINER_NAME" && gum confirm "Recreate '${FOO_CONTAINER_NAME}'?" \
        && docker rm -f "$FOO_CONTAINER_NAME" >/dev/null 2>&1 || true
    gum spin --spinner dot --title "Pulling ${image}..." -- docker pull "$image" || error_exit "pull failed."
    docker run -d --name "$FOO_CONTAINER_NAME" \
        -p "${FOO_PORT}:${FOO_DEFAULT_PORT}" \
        --restart unless-stopped "$image" >/dev/null \
        || error_exit "Failed to start '${FOO_CONTAINER_NAME}'."   # TODO: -e ENV / -v volume
    success "Foo running — localhost:${FOO_PORT}"
}

foo_status_docker() {
    header "Foo — Docker Status"
    _docker_container_exists "$FOO_CONTAINER_NAME" || { warn "Container '${FOO_CONTAINER_NAME}' not found."; return; }
    docker ps -a --filter "name=^/${FOO_CONTAINER_NAME}$"
}

foo_connect_docker() {
    header "Connect — Docker"
    _docker_container_running "$FOO_CONTAINER_NAME" || { warn "Not running."; return; }
    # TODO: replace with your client, e.g. docker exec -it "$FOO_CONTAINER_NAME" psql -U ...
    docker exec -it "$FOO_CONTAINER_NAME" sh
}

foo_uninstall_docker() {
    header "Uninstall Foo — Docker"
    _docker_container_exists "$FOO_CONTAINER_NAME" || { warn "Not found."; return; }
    gum confirm "Remove container '${FOO_CONTAINER_NAME}'?" || return
    docker rm -f "$FOO_CONTAINER_NAME" >/dev/null && success "Removed."   # TODO: offer to drop the data volume
}

# -----------------------------------------------------------------------------
# Kubernetes target
# -----------------------------------------------------------------------------
_k8s_detect_installed() { helm status "$FOO_HELM_RELEASE" -n "$FOO_NAMESPACE" &>/dev/null 2>&1; }
_k8s_ensure_namespace() { kubectl get namespace "$FOO_NAMESPACE" &>/dev/null || kubectl create namespace "$FOO_NAMESPACE"; }

_k8s_check_cluster() {
    local ctx="$TARGET_CONTEXT"; [[ "$TARGET_TYPE" == "kind" ]] && ctx="kind-${TARGET_CONTEXT}"
    kubectl config use-context "$ctx" &>/dev/null || error_exit "Cannot switch to context '${ctx}'."
    gum spin --spinner dot --title "Verifying cluster..." -- kubectl cluster-info &>/dev/null \
        || { warn "Cannot reach cluster '${TARGET_CONTEXT}'."; return 1; }
}

foo_install_k8s() {
    header "Install Foo — Kubernetes"
    _k8s_check_cluster || return 0
    _ensure_helm_repo "$FOO_HELM_REPO_NAME" "$FOO_HELM_REPO_URL"
    _k8s_ensure_namespace
    # fullnameOverride keeps the Service named after the release so svc/<release> resolves.
    local helm_args=(
        "$FOO_HELM_RELEASE" "$FOO_HELM_CHART"
        --namespace "$FOO_NAMESPACE"
        --set fullnameOverride="$FOO_HELM_RELEASE"
        # TODO: --set auth.* / persistence size / etc. for your chart
        --wait --timeout 5m
    )
    if _k8s_detect_installed; then
        gum confirm "Release exists — upgrade?" || return
        gum spin --spinner dot --title "Upgrading..." -- helm upgrade "${helm_args[@]}" || error_exit "upgrade failed."
    else
        gum spin --spinner dot --title "Installing..." -- helm install "${helm_args[@]}" || error_exit "install failed."
    fi
    success "Installed. Use port-forward / connect to reach it."
}

foo_status_k8s() {
    header "Foo — Kubernetes Status"; _k8s_check_cluster || return 0
    _k8s_detect_installed || { warn "Not installed in '${FOO_NAMESPACE}'."; return; }
    kubectl get pods,svc -n "$FOO_NAMESPACE"
}

foo_port_forward_k8s() {
    header "Foo — Port Forward"; _k8s_check_cluster || return 0
    _k8s_detect_installed || { warn "Not installed."; return; }
    if pf_is_running "$_FOO_PF_PID"; then
        gum confirm "Stop port-forward on :$(pf_port "$_FOO_PF_PID")?" && pf_stop "$_FOO_PF_PID"; return
    fi
    local port; port=$(gum input --value "$FOO_DEFAULT_PORT" --header "Local port:") || return
    port="${port:-$FOO_DEFAULT_PORT}"
    kubectl -n "$FOO_NAMESPACE" port-forward "svc/${FOO_HELM_RELEASE}" "${port}:${FOO_DEFAULT_PORT}" >/dev/null 2>&1 &
    echo "${!}:${port}" > "$_FOO_PF_PID"
    pf_is_running "$_FOO_PF_PID" && success "Port-forward: localhost:${port}" || { warn "Failed."; rm -f "$_FOO_PF_PID"; }
}

foo_uninstall_k8s() {
    header "Uninstall Foo — Kubernetes"; _k8s_check_cluster || return 0
    _k8s_detect_installed || { warn "Not installed."; return; }
    gum confirm "Uninstall release '${FOO_HELM_RELEASE}'? (PVCs are NOT auto-removed)" || return
    helm uninstall "$FOO_HELM_RELEASE" -n "$FOO_NAMESPACE" || true
    success "Uninstalled."
}

# -----------------------------------------------------------------------------
# Menus
# -----------------------------------------------------------------------------
_docker_menu() {
    FOO_CONTAINER_NAME=$(gum input --value "foo" --header "Container name:") || true
    FOO_CONTAINER_NAME="${FOO_CONTAINER_NAME:-foo}"
    while true; do
        header "Foo — Docker (${FOO_CONTAINER_NAME})"
        case "$(gum choose install status connect uninstall "← back" --header "Action:")" in
            install)   foo_install_docker ;;   status) foo_status_docker ;;
            connect)   foo_connect_docker ;;   uninstall) foo_uninstall_docker ;;
            *) return ;;
        esac
    done
}

_k8s_menu() {
    FOO_NAMESPACE=$(gum input --value "$FOO_NAMESPACE" --header "Namespace:") || true; FOO_NAMESPACE="${FOO_NAMESPACE:-foo}"
    FOO_HELM_RELEASE=$(gum input --value "$FOO_HELM_RELEASE" --header "Release:") || true; FOO_HELM_RELEASE="${FOO_HELM_RELEASE:-foo}"
    while true; do
        header "Foo — Kubernetes (${TARGET_CONTEXT} / ns:${FOO_NAMESPACE})"
        case "$(gum choose install status port-forward uninstall "← back" --header "Action:")" in
            install)      foo_install_k8s ;;      status) foo_status_k8s ;;
            port-forward) foo_port_forward_k8s ;; uninstall) foo_uninstall_k8s ;;
            *) return ;;
        esac
    done
}

# -----------------------------------------------------------------------------
main() {
    gum style --foreground "$BLUE" --border-foreground "$BLUE" --border double \
        --align center --width 60 --margin "1 2" --padding "1 4" "Foo" "Docker · Kubernetes"
    select_target || exit 1
    check_dependencies
    case "$TARGET_TYPE" in docker) _docker_menu ;; kind|k8s) _k8s_menu ;; esac
    gum style --faint "Bye."
}

main "$@"
