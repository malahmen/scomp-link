#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# dozzle.sh
# Interactive TUI for managing Dozzle (https://dozzle.dev) — a lightweight
# real-time log viewer for Docker / Kubernetes / kind.
#
# Unlike lgtm.sh, Dozzle has no meaningful long-term data to "purge": /data
# only holds the optional auth users file and notification rules, so there
# is no separate purge subcommand. `uninstall` removes everything, including
# that /data volume/PVC.
#
# Sourced helpers (scripts/_common/):
#   ui.sh          — header/info/success/warn/error_exit
#   cluster.sh     — select_target, kubectl_context_flag, target_summary
#   deps.sh        — _check_docker, _check_kubectl
#   gh_releases.sh — select_version
#   portforward.sh — pf_is_running / pf_port / pf_stop (PID-file based)
#
# Config: ~/.config/dozzle/dozzle.conf (XDG-style, key=value, one per line)
# -----------------------------------------------------------------------------

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMON_DIR="${SCRIPT_DIR}/../_common"
TEMPLATES_DIR="${SCRIPT_DIR}/templates"

# shellcheck source=../_common/ui.sh
source "${COMMON_DIR}/ui.sh"
# shellcheck source=../_common/cluster.sh
source "${COMMON_DIR}/cluster.sh"
# shellcheck source=../_common/deps.sh
source "${COMMON_DIR}/deps.sh"
# shellcheck source=../_common/gh_releases.sh
source "${COMMON_DIR}/gh_releases.sh"
# shellcheck source=../_common/portforward.sh
source "${COMMON_DIR}/portforward.sh"

trap 'echo ""; gum style --faint "Interrupted."; exit 0' INT TERM

# -----------------------------------------------------------------------------
# Constants
# -----------------------------------------------------------------------------

DOZZLE_IMAGE="amir20/dozzle"
DOZZLE_GH_API="https://api.github.com/repos/amir20/dozzle/releases"
NAMESPACE="dozzle"
SERVICE_PORT=8080
PVC_SIZE="256Mi"
STORAGE_CLASS="dozzle-manual"

CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/dozzle"
# Expand a literal leading '~' — happens when XDG_CONFIG_HOME is exported as
# "~/.config" (tilde isn't expanded inside ${VAR:-…}).
CONFIG_DIR="${CONFIG_DIR/#\~/$HOME}"
CONFIG_FILE="${CONFIG_DIR}/dozzle.conf"
PF_DIR="${CONFIG_DIR}/pf"

WORKDIR="${CONFIG_DIR}/workdir"
COMPOSE_FILE="${WORKDIR}/docker-compose.yml"
MANIFEST_FILE="${WORKDIR}/manifests.yaml"

mkdir -p "$CONFIG_DIR" "$PF_DIR" "$WORKDIR"

# -----------------------------------------------------------------------------
# Config persistence (flat key=value file)
# -----------------------------------------------------------------------------

cfg_load() {
    TARGET_TYPE=""
    TARGET_CONTEXT=""
    DOZZLE_VERSION=""
    AUTH_ENABLED="false"
    AUTH_USER=""
    STORAGE_MODE=""     # docker: bind ; k8s/kind: hostpath | nfs
    STORAGE_PATH=""      # bind path, or hostPath path
    NFS_SERVER=""
    NFS_PATH=""
    RBAC_SCOPE="cluster" # cluster | namespace
    RESTRICT_NAMESPACE=""

    [[ -f "$CONFIG_FILE" ]] || return 0
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
}

cfg_save() {
    cat > "$CONFIG_FILE" <<EOF
TARGET_TYPE="${TARGET_TYPE}"
TARGET_CONTEXT="${TARGET_CONTEXT}"
DOZZLE_VERSION="${DOZZLE_VERSION}"
AUTH_ENABLED="${AUTH_ENABLED}"
AUTH_USER="${AUTH_USER}"
STORAGE_MODE="${STORAGE_MODE}"
STORAGE_PATH="${STORAGE_PATH}"
NFS_SERVER="${NFS_SERVER:-}"
NFS_PATH="${NFS_PATH:-}"
RBAC_SCOPE="${RBAC_SCOPE:-}"
RESTRICT_NAMESPACE="${RESTRICT_NAMESPACE:-}"
EOF
}

cfg_require() {
    cfg_load
    if [[ -z "$TARGET_TYPE" ]]; then
        error_exit "No saved config found. Run 'install' first."
    fi
}

# -----------------------------------------------------------------------------
# Template rendering
#
# render_template <template-file> <token1=value1> [token2=value2 ...]
#   Reads a template containing __TOKEN__ placeholders and prints it to
#   stdout with each token replaced. Uses '|' as the sed delimiter since
#   substituted values (paths) commonly contain '/'. Values are sed-escaped
#   on the replacement side to keep this safe regardless of what characters
#   end up in a path.
#
# inject_block <template-file> <token> <replacement-file>
#   Like render_template, but the replacement is the full multi-line content
#   of <replacement-file> rather than a single value. Used for the env-vars
#   block in the Deployment template, which has 1-3 lines depending on
#   auth/namespace-restriction choices.
# -----------------------------------------------------------------------------

_sed_escape() {
    # Escapes characters that are special on sed's replacement side.
    printf '%s' "$1" | sed -e 's/[\&|]/\\&/g'
}

render_template() {
    local tpl="$1"; shift
    local content
    content="$(cat "$tpl")"

    local pair token value escaped
    for pair in "$@"; do
        token="${pair%%=*}"
        value="${pair#*=}"
        escaped="$(_sed_escape "$value")"
        content="$(printf '%s' "$content" | sed "s|__${token}__|${escaped}|g")"
    done

    printf '%s\n' "$content"
}

inject_block() {
    local tpl="$1" token="$2" block_file="$3"
    awk -v token="__${token}__" '
        $0 == token { while ((getline line < block_file) > 0) print line; next }
        { print }
    ' block_file="$block_file" "$tpl"
}

# -----------------------------------------------------------------------------
# install — auth (bcrypt generation requires local Docker, any target)
# -----------------------------------------------------------------------------

_prompt_auth() {
    AUTH_ENABLED="false"
    AUTH_USER=""

    gum confirm "Enable Dozzle's built-in authentication (--auth-provider simple)?" || return 0

    _check_docker

    local user pass email name
    user=$(gum input --placeholder "admin" --header "Username:") || true
    [[ -z "$user" ]] && { warn "No username entered. Skipping auth."; return 0; }

    pass=$(gum input --password --header "Password:") || true
    [[ -z "$pass" ]] && { warn "No password entered. Skipping auth."; return 0; }

    email=$(gum input --placeholder "(optional)" --header "Email (for Gravatar, optional):") || true
    name=$(gum input --placeholder "${user}" --header "Display name (optional):") || true
    name="${name:-$user}"

    info "Generating bcrypt hash via 'docker run amir20/dozzle generate'..."

    local users_yml
    if ! users_yml=$(gum spin --spinner dot --title "Generating users.yml..." -- \
        docker run -i --rm "${DOZZLE_IMAGE}:${DOZZLE_VERSION:-latest}" generate "$user" \
            --password "$pass" \
            ${email:+--email "$email"} \
            --name "$name"); then
        error_exit "Failed to generate users.yml. Is Docker reachable and is the image pullable?"
    fi

    if [[ -z "$users_yml" ]]; then
        error_exit "'docker run amir20/dozzle generate' produced no output."
    fi

    AUTH_ENABLED="true"
    AUTH_USER="$user"
    AUTH_USERS_YML="$users_yml"
    success "Auth configured for user '${user}'."
}

# -----------------------------------------------------------------------------
# install — storage
# -----------------------------------------------------------------------------

_prompt_storage_docker() {
    local default_path="${CONFIG_DIR}/data"
    STORAGE_PATH=$(gum input \
        --value "$default_path" \
        --header "Host path to bind-mount as Dozzle's /data:") || true
    STORAGE_PATH="${STORAGE_PATH:-$default_path}"
    STORAGE_MODE="bind"
    mkdir -p "$STORAGE_PATH"
    info "Using bind mount: ${STORAGE_PATH} -> /data"
}

_prompt_storage_k8s() {
    local choice
    choice=$(gum choose "hostPath" "NFS" --header "Storage backend for /data (PVC):") || true
    [[ -z "$choice" ]] && error_exit "Storage backend is required."

    case "$choice" in
        hostPath)
            STORAGE_MODE="hostpath"
            STORAGE_PATH=$(gum input \
                --value "/var/dozzle-data" \
                --header "hostPath on the node for /data:") || true
            STORAGE_PATH="${STORAGE_PATH:-/var/dozzle-data}"
            ;;
        NFS)
            STORAGE_MODE="nfs"
            NFS_SERVER=$(gum input --header "NFS server IP/hostname:") || true
            [[ -z "$NFS_SERVER" ]] && error_exit "NFS server is required."
            NFS_PATH=$(gum input --value "/exports/dozzle" --header "NFS export path:") || true
            NFS_PATH="${NFS_PATH:-/exports/dozzle}"
            ;;
    esac
}

# -----------------------------------------------------------------------------
# install — RBAC scope (k8s/kind only)
# -----------------------------------------------------------------------------

_prompt_rbac_scope() {
    local choice
    choice=$(gum choose \
        "Cluster-wide (ClusterRole — sees all namespaces)" \
        "Restrict to one namespace (Role + DOZZLE_NAMESPACE)" \
        --header "RBAC scope:") || true
    [[ -z "$choice" ]] && error_exit "RBAC scope is required."

    case "$choice" in
        Cluster-wide*)   RBAC_SCOPE="cluster" ;;
        Restrict*)
            RBAC_SCOPE="namespace"
            RESTRICT_NAMESPACE=$(gum input --value "${NAMESPACE}" \
                --header "Namespace to restrict Dozzle to (can be any namespace, including its own '${NAMESPACE}'):") || true
            RESTRICT_NAMESPACE="${RESTRICT_NAMESPACE:-${NAMESPACE}}"
            ;;
    esac
}

# -----------------------------------------------------------------------------
# install — generate Docker Compose
# -----------------------------------------------------------------------------

_write_compose_file() {
    local rendered

    if [[ "$AUTH_ENABLED" == "true" ]]; then
        rendered="$(inject_block "${TEMPLATES_DIR}/docker-compose.yaml" "AUTH_ENV_BLOCK" \
            "${TEMPLATES_DIR}/docker-auth-env.yaml")"
    else
        # Drop the placeholder line entirely when auth is disabled.
        rendered="$(grep -v '^__AUTH_ENV_BLOCK__$' "${TEMPLATES_DIR}/docker-compose.yaml")"
    fi

    printf '%s\n' "$rendered" | \
        sed \
            -e "s|__DOZZLE_IMAGE__|$(_sed_escape "$DOZZLE_IMAGE")|g" \
            -e "s|__DOZZLE_VERSION__|$(_sed_escape "${DOZZLE_VERSION:-latest}")|g" \
            -e "s|__STORAGE_PATH__|$(_sed_escape "$STORAGE_PATH")|g" \
            -e "s|__SERVICE_PORT__|$(_sed_escape "$SERVICE_PORT")|g" \
        > "$COMPOSE_FILE"

    if [[ "$AUTH_ENABLED" == "true" ]]; then
        printf '%s\n' "$AUTH_USERS_YML" > "${STORAGE_PATH}/users.yml"
        info "Wrote ${STORAGE_PATH}/users.yml"
    fi

    info "Wrote ${COMPOSE_FILE}"
}

# -----------------------------------------------------------------------------
# install — generate k8s/kind manifests
# -----------------------------------------------------------------------------

_write_k8s_manifests() {
    local k8s_tpl="${TEMPLATES_DIR}/k8s"
    : > "$MANIFEST_FILE"

    _append_manifest() {
        [[ -s "$MANIFEST_FILE" ]] && printf '%s\n' "---" >> "$MANIFEST_FILE"
        cat >> "$MANIFEST_FILE"
    }

    render_template "${k8s_tpl}/namespace.yaml" "NAMESPACE=${NAMESPACE}" \
        | _append_manifest

    render_template "${k8s_tpl}/serviceaccount.yaml" "NAMESPACE=${NAMESPACE}" \
        | _append_manifest

    if [[ "$RBAC_SCOPE" == "cluster" ]]; then
        render_template "${k8s_tpl}/rbac-cluster.yaml" "NAMESPACE=${NAMESPACE}" \
            | _append_manifest
    else
        render_template "${k8s_tpl}/rbac-namespace.yaml" \
            "NAMESPACE=${NAMESPACE}" \
            "RESTRICT_NAMESPACE=${RESTRICT_NAMESPACE}" \
            | _append_manifest
    fi

    if [[ "$STORAGE_MODE" == "hostpath" ]]; then
        render_template "${k8s_tpl}/pv-hostpath.yaml" \
            "PVC_SIZE=${PVC_SIZE}" \
            "STORAGE_CLASS=${STORAGE_CLASS}" \
            "STORAGE_PATH=${STORAGE_PATH}" \
            | _append_manifest
    elif [[ "$STORAGE_MODE" == "nfs" ]]; then
        render_template "${k8s_tpl}/pv-nfs.yaml" \
            "PVC_SIZE=${PVC_SIZE}" \
            "STORAGE_CLASS=${STORAGE_CLASS}" \
            "NFS_SERVER=${NFS_SERVER}" \
            "NFS_PATH=${NFS_PATH}" \
            | _append_manifest
    fi

    render_template "${k8s_tpl}/pvc.yaml" \
        "NAMESPACE=${NAMESPACE}" \
        "PVC_SIZE=${PVC_SIZE}" \
        "STORAGE_CLASS=${STORAGE_CLASS}" \
        | _append_manifest

    # Deployment has a multi-line env-vars block, built up separately and
    # injected via inject_block rather than a single-value token.
    local env_lines_file="${WORKDIR}/.env_lines.tmp"
    {
        echo "            - name: DOZZLE_MODE"
        echo "              value: \"k8s\""
        if [[ "$RBAC_SCOPE" == "namespace" ]]; then
            echo "            - name: DOZZLE_NAMESPACE"
            echo "              value: \"${RESTRICT_NAMESPACE}\""
        fi
        if [[ "$AUTH_ENABLED" == "true" ]]; then
            echo "            - name: DOZZLE_AUTH_PROVIDER"
            echo "              value: \"simple\""
        fi
    } > "$env_lines_file"

    inject_block "${k8s_tpl}/deployment.yaml" "ENV_LINES" "$env_lines_file" \
        | render_template /dev/stdin \
            "NAMESPACE=${NAMESPACE}" \
            "DOZZLE_IMAGE=${DOZZLE_IMAGE}" \
            "DOZZLE_VERSION=${DOZZLE_VERSION:-latest}" \
        | _append_manifest

    rm -f "$env_lines_file"

    render_template "${k8s_tpl}/service.yaml" \
        "NAMESPACE=${NAMESPACE}" \
        "SERVICE_PORT=${SERVICE_PORT}" \
        | _append_manifest

    unset -f _append_manifest

    info "Wrote ${MANIFEST_FILE}"

    if [[ "$AUTH_ENABLED" == "true" ]]; then
        local ctx_flags
        ctx_flags="$(kubectl_context_flag)"
        printf '%s\n' "$AUTH_USERS_YML" > "${WORKDIR}/users.yml"
        warn "Auth was requested, but a freshly created PVC mounts empty —"
        warn "users.yml cannot be pre-seeded before the pod exists."
        warn "Saved locally at ${WORKDIR}/users.yml. After 'install' finishes and the"
        warn "pod is Running, copy it in once (then restart the pod to pick it up):"
        warn "  POD=\$(kubectl ${ctx_flags} -n ${NAMESPACE} get pod -l app=dozzle -o jsonpath='{.items[0].metadata.name}')"
        warn "  kubectl ${ctx_flags} -n ${NAMESPACE} cp ${WORKDIR}/users.yml \"\${POD}:/data/users.yml\""
        warn "  kubectl ${ctx_flags} -n ${NAMESPACE} delete pod \"\${POD}\""
    fi
}

# -----------------------------------------------------------------------------
# cmd: install
# -----------------------------------------------------------------------------

cmd_install() {
    header "Dozzle — Install"

    select_target || exit 1

    case "$TARGET_TYPE" in
        docker) _check_docker ;;
        kind|k8s) _check_kubectl ;;
    esac

    select_version "$DOZZLE_GH_API" "Dozzle"
    DOZZLE_VERSION="$SELECTED_VERSION"

    _prompt_auth

    case "$TARGET_TYPE" in
        docker)
            _prompt_storage_docker
            _write_compose_file
            info "Starting Dozzle via docker-compose..."
            docker-compose -f "$COMPOSE_FILE" up -d \
                || error_exit "docker-compose up failed."
            success "Dozzle is running. http://localhost:${SERVICE_PORT}"
            ;;
        kind|k8s)
            _prompt_storage_k8s
            _prompt_rbac_scope
            _write_k8s_manifests
            local ctx_flags
            ctx_flags="$(kubectl_context_flag)"
            info "Applying manifests..."
            # shellcheck disable=SC2086
            kubectl $ctx_flags apply -f "$MANIFEST_FILE" \
                || error_exit "kubectl apply failed."
            success "Dozzle deployed to namespace '${NAMESPACE}'."
            info "Use 'dozzle.sh port-forward' to reach it on the LAN."
            ;;
    esac

    cfg_save
    success "Install complete."
}

# -----------------------------------------------------------------------------
# cmd: uninstall
# -----------------------------------------------------------------------------

cmd_uninstall() {
    header "Dozzle — Uninstall"
    cfg_require

    gum confirm "This removes Dozzle AND its /data (auth users, notification rules). Continue?" \
        || { info "Cancelled."; return; }

    case "$TARGET_TYPE" in
        docker)
            docker-compose -f "$COMPOSE_FILE" down -v 2>/dev/null || true
            [[ -n "$STORAGE_PATH" ]] && rm -rf "$STORAGE_PATH"
            ;;
        kind|k8s)
            local ctx_flags
            ctx_flags="$(kubectl_context_flag)"
            # shellcheck disable=SC2086
            kubectl $ctx_flags delete -f "$MANIFEST_FILE" --ignore-not-found 2>/dev/null || true
            # shellcheck disable=SC2086
            kubectl $ctx_flags delete namespace "${NAMESPACE}" --ignore-not-found 2>/dev/null || true
            ;;
    esac

    rm -f "$CONFIG_FILE"
    success "Dozzle uninstalled."
}

# -----------------------------------------------------------------------------
# cmd: start / stop
# -----------------------------------------------------------------------------

cmd_start() {
    header "Dozzle — Start"
    cfg_require
    case "$TARGET_TYPE" in
        docker)
            docker-compose -f "$COMPOSE_FILE" start \
                || error_exit "Failed to start Dozzle."
            ;;
        kind|k8s)
            local ctx_flags
            ctx_flags="$(kubectl_context_flag)"
            # shellcheck disable=SC2086
            kubectl $ctx_flags -n "${NAMESPACE}" scale deployment/dozzle --replicas=1 \
                || error_exit "Failed to scale up Dozzle."
            ;;
    esac
    success "Dozzle started."
}

cmd_stop() {
    header "Dozzle — Stop"
    cfg_require
    case "$TARGET_TYPE" in
        docker)
            docker-compose -f "$COMPOSE_FILE" stop \
                || error_exit "Failed to stop Dozzle."
            ;;
        kind|k8s)
            local ctx_flags
            ctx_flags="$(kubectl_context_flag)"
            # shellcheck disable=SC2086
            kubectl $ctx_flags -n "${NAMESPACE}" scale deployment/dozzle --replicas=0 \
                || error_exit "Failed to scale down Dozzle."
            # The pod backing any active port-forward is going away — tear the
            # tunnel down here so 'status' reflects reality and the wrapper
            # loop (see cmd_port_forward) doesn't spin trying to reconnect.
            local pf_file="${PF_DIR}/dozzle.pid"
            if pf_is_running "$pf_file"; then
                pf_stop "$pf_file"
            fi
            # shellcheck disable=SC2086
            kubectl $ctx_flags -n "${NAMESPACE}" wait --for=delete pod -l app=dozzle \
                --timeout=30s 2>/dev/null || true
            ;;
    esac
    success "Dozzle stopped. (/data is untouched.)"
}

# -----------------------------------------------------------------------------
# cmd: status
# -----------------------------------------------------------------------------

cmd_status() {
    header "Dozzle — Status"
    cfg_require

    gum style --foreground "${CYAN}" --bold "── Target"
    info "$(target_summary)"

    if [[ "$TARGET_TYPE" == "docker" ]]; then
        gum style --foreground "${CYAN}" --bold "── Container Status"
        docker-compose -f "$COMPOSE_FILE" ps 2>/dev/null \
            || warn "Could not read compose status."

        gum style --foreground "${CYAN}" --bold "── Resource Usage"
        docker stats --no-stream dozzle 2>/dev/null \
            || warn "Could not retrieve resource usage (is the container running?)."

        gum style --foreground "${CYAN}" --bold "── Port Mapping"
        info "http://localhost:${SERVICE_PORT}"
        return
    fi

    # kind / k8s
    local ctx_flags
    ctx_flags="$(kubectl_context_flag)"

    gum style --foreground "${CYAN}" --bold "── Pods"
    # shellcheck disable=SC2086
    kubectl $ctx_flags get pods -n "${NAMESPACE}" -o wide 2>/dev/null \
        || warn "Could not list pods."

    gum style --foreground "${CYAN}" --bold "── Resource Usage (top)"
    # shellcheck disable=SC2086
    kubectl $ctx_flags top pods -n "${NAMESPACE}" 2>/dev/null \
        || warn "kubectl top unavailable (metrics-server not installed?)."

    gum style --foreground "${CYAN}" --bold "── PersistentVolumeClaim"
    # shellcheck disable=SC2086
    kubectl $ctx_flags get pvc -n "${NAMESPACE}" 2>/dev/null \
        || warn "Could not list PVC."

    gum style --foreground "${CYAN}" --bold "── Active Port-Forwards"
    local pf_file="${PF_DIR}/dozzle.pid"
    if pf_is_running "$pf_file"; then
        success "Dozzle → localhost:$(pf_port "$pf_file")"
    else
        info "No active port-forward."
    fi
}

# -----------------------------------------------------------------------------
# cmd: port-forward (k8s/kind only)
# -----------------------------------------------------------------------------

cmd_port_forward() {
    header "Dozzle — Port Forward"
    cfg_require

    if [[ "$TARGET_TYPE" == "docker" ]]; then
        warn "Docker mode publishes the port directly; port-forward is not applicable."
        info "Reach Dozzle at http://localhost:${SERVICE_PORT}"
        return
    fi

    local pf_file="${PF_DIR}/dozzle.pid"

    if pf_is_running "$pf_file"; then
        if gum confirm "Port-forward already running on localhost:$(pf_port "$pf_file"). Stop it?"; then
            pf_stop "$pf_file"
        fi
        return
    fi

    local local_port
    local_port=$(gum input --value "${SERVICE_PORT}" --header "Local port to forward to:") || true
    local_port="${local_port:-$SERVICE_PORT}"

    local ctx_flags
    ctx_flags="$(kubectl_context_flag)"

    # Auto-reconnect wrapper: kubectl port-forward dies when the backing pod is
    # replaced (rollout, eviction, crash). Looping in a subshell keeps the tunnel
    # alive across restarts. Trap forwards SIGTERM/HUP to the kubectl child so
    # pf_stop can take the whole thing down cleanly. Disable set -e in the
    # subshell — `wait` returns the child's (non-zero) exit status when it
    # dies, which would otherwise kill the wrapper on the first reconnect.
    (
        set +e
        trap 'kill "${child:-0}" 2>/dev/null; exit 0' TERM INT HUP
        while true; do
            # shellcheck disable=SC2086
            kubectl $ctx_flags -n "${NAMESPACE}" port-forward "svc/dozzle" \
                "${local_port}:${SERVICE_PORT}" >/dev/null 2>&1 &
            child=$!
            wait "$child" 2>/dev/null
            sleep 2
        done
    ) &
    local pid=$!
    sleep 2

    # If nothing is listening on the local port after 2s, kubectl is failing
    # repeatedly (port in use, service not ready) and the wrapper is spinning.
    if ! lsof -i ":${local_port}" -sTCP:LISTEN >/dev/null 2>&1; then
        pkill -P "$pid" 2>/dev/null || true
        kill "$pid" 2>/dev/null || true
        error_exit "Port-forward failed to start (port in use, or service not ready)."
    fi

    echo "${pid}:${local_port}" > "$pf_file"
    success "Port-forward active (auto-reconnect): http://localhost:${local_port}"
}

# -----------------------------------------------------------------------------
# Main dispatch
# -----------------------------------------------------------------------------

main() {
    if [[ $# -gt 0 ]]; then
        case "$1" in
            install)       cmd_install ;;
            uninstall)     cmd_uninstall ;;
            status)        cmd_status ;;
            start)         cmd_start ;;
            stop)          cmd_stop ;;
            port-forward)  cmd_port_forward ;;
            *) error_exit "Unknown command: $1 (expected: install|uninstall|status|start|stop|port-forward)" ;;
        esac
        exit 0
    fi

    while true; do
        header "Dozzle Manager"
        local action
        action=$(gum choose \
            "install" "uninstall" "status" "start" "stop" "port-forward" "quit" \
            --header "Choose an action:") || true

        [[ -z "$action" || "$action" == "quit" ]] && { gum style --faint "Bye."; exit 0; }

        case "$action" in
            install)      cmd_install      ;;
            uninstall)    cmd_uninstall    ;;
            status)       cmd_status       ;;
            start)        cmd_start        ;;
            stop)         cmd_stop         ;;
            port-forward) cmd_port_forward ;;
        esac

        echo ""
        gum confirm "Back to main menu?" || { gum style --faint "Bye."; exit 0; }
    done
}

main "$@"