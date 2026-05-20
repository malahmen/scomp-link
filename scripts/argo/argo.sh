#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# argo.sh
# Interactive TUI for installing and managing Argo Workflows and Argo CD.
# Called by init.sh — expects gum and kubectl to already be available.
# Dependencies: gum (managed by init.sh), kubectl, curl
# -----------------------------------------------------------------------------

set -euo pipefail

# -----------------------------------------------------------------------------
# Constants
# -----------------------------------------------------------------------------

# Argo Workflows
WORKFLOWS_NAMESPACE="argo"
WORKFLOWS_GH_API="https://api.github.com/repos/argoproj/argo-workflows/releases"
WORKFLOWS_INSTALL_BASE="https://github.com/argoproj/argo-workflows/releases/download"
WORKFLOWS_PORT=2746
_WORKFLOWS_PF_PID="/tmp/scomp-pf-argo-workflows.pid"

# Argo CD
ARGOCD_NAMESPACE="argocd"
ARGOCD_GH_API="https://api.github.com/repos/argoproj/argo-cd/releases"
ARGOCD_INSTALL_BASE="https://raw.githubusercontent.com/argoproj/argo-cd"
ARGOCD_PORT=8080
_ARGOCD_PF_PID="/tmp/scomp-pf-argocd.pid"

# Argo Events
ARGOEVENTS_NAMESPACE="argo-events"
ARGOEVENTS_GH_API="https://api.github.com/repos/argoproj/argo-events/releases"
ARGOEVENTS_INSTALL_BASE="https://github.com/argoproj/argo-events/releases/download"
ARGOEVENTS_DEFAULT_WEBHOOK_PORT=12000
_ARGOEVENTS_PF_PID="/tmp/scomp-pf-argo-events.pid"

# Colours
CYAN=212
RED=196
GREEN=82
YELLOW=220
PURPLE=99

# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------

header() {
    gum style \
        --foreground "$CYAN" --border-foreground "$CYAN" --border rounded \
        --align center --width 60 --padding "1 4" --margin "1 0" \
        "$1"
}

info()       { gum log --level info "$1"; }
success()    { gum style --foreground "$GREEN" "[ok] $1"; }
warn()       { gum style --foreground "$YELLOW" "[warn] $1"; }
error_exit() { gum style --foreground "$RED" "[error] $1"; exit 1; }

# -----------------------------------------------------------------------------
# Shared dependency checks
# -----------------------------------------------------------------------------

check_dependencies() {
    info "Checking dependencies..."

    if ! command -v kubectl &>/dev/null; then
        gum log --level error "kubectl is not installed or not in PATH."
        gum log --level error "Install kubectl: https://kubernetes.io/docs/tasks/tools/"
        exit 1
    fi
    info "kubectl found: $(kubectl version --client 2>/dev/null | head -1)"

    if ! command -v curl &>/dev/null; then
        gum log --level error "curl is not installed. Required to fetch release versions."
        exit 1
    fi
    info "curl found."
}

# -----------------------------------------------------------------------------
# Shared cluster check
# -----------------------------------------------------------------------------

check_cluster() {
    info "Verifying cluster connectivity..."

    local context
    context=$(kubectl config current-context 2>/dev/null || true)

    if [[ -z "$context" ]]; then
        gum log --level error "No active kubectl context found. Is your kubeconfig configured?"
        exit 1
    fi

    info "Active context: ${context}"

    if ! gum spin --spinner dot --title "Connecting to cluster..." -- \
        kubectl cluster-info &>/dev/null; then
        gum log --level error "Cannot reach cluster. Verify your context and cluster status."
        exit 1
    fi

    info "Cluster reachable."
}

# -----------------------------------------------------------------------------
# Shared version fetcher
# -----------------------------------------------------------------------------

fetch_versions() {
    local api_url="$1"
    curl -fsSL "${api_url}?per_page=30" 2>/dev/null \
        | grep '"tag_name"' \
        | sed 's/.*"tag_name": *"\(.*\)".*/\1/' \
        | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$'
}

select_version() {
    local api_url="$1"
    local label="$2"    # e.g. "Argo Workflows"

    info "Fetching available ${label} versions from GitHub..."

    local versions
    if ! versions=$(gum spin --spinner dot --title "Fetching release list..." -- \
        bash -c "curl -fsSL '${api_url}?per_page=30' 2>/dev/null \
            | grep '\"tag_name\"' \
            | sed 's/.*\"tag_name\": *\"\(.*\)\".*/\1/' \
            | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+\$'"); then
        gum log --level warn "Failed to fetch version list. Falling back to latest stable."
        SELECTED_VERSION="latest"
        return
    fi

    if [[ -z "$versions" ]]; then
        gum log --level error "No stable releases found. Check your internet connection."
        exit 1
    fi

    SELECTED_VERSION=$(echo "$versions" | gum choose \
        --header "Select ${label} version (stable releases only):" \
        --height 10) || true

    if [[ -z "$SELECTED_VERSION" ]]; then
        gum log --level warn "No version selected. Aborting."
        exit 0
    fi

    info "Selected version: ${SELECTED_VERSION}"
}

# =============================================================================
# ARGO WORKFLOWS
# =============================================================================

workflows_detect_installed() {
    kubectl get deployment workflow-controller -n "${WORKFLOWS_NAMESPACE}" \
        -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null \
        | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' || true
}

workflows_install() {
    header "Install Argo Workflows"
    check_cluster
    select_version "$WORKFLOWS_GH_API" "Argo Workflows"

    local installed
    installed=$(workflows_detect_installed)

    if [[ -n "$installed" ]]; then
        gum style \
            --foreground "$YELLOW" --border-foreground "$YELLOW" --border rounded \
            --align center --width 60 --margin "1 2" --padding "1 4" \
            "Argo Workflows already installed" \
            "Detected version: ${installed}" \
            "Target version:   ${SELECTED_VERSION}"

        local action
        action=$(gum choose \
            "Upgrade / Reinstall (apply selected version)" \
            "Cancel" \
            --header "What would you like to do?") || true

        case "$action" in
            "Upgrade / Reinstall"*) info "Proceeding with reinstall to ${SELECTED_VERSION}..." ;;
            *) warn "Cancelled."; return ;;
        esac
    fi

    # Ensure namespace
    if kubectl get namespace "${WORKFLOWS_NAMESPACE}" &>/dev/null; then
        info "Namespace '${WORKFLOWS_NAMESPACE}' already exists."
    else
        info "Creating namespace '${WORKFLOWS_NAMESPACE}'..."
        kubectl create namespace "${WORKFLOWS_NAMESPACE}"
    fi

    local install_url="${WORKFLOWS_INSTALL_BASE}/${SELECTED_VERSION}/install.yaml"
    info "Manifest URL: ${install_url}"

    # --server-side required for v4.0+ — CRD validation schemas exceed client-side annotation limit
    if ! gum spin --spinner dot \
        --title "Applying Argo Workflows manifests..." -- \
        kubectl apply --server-side -n "${WORKFLOWS_NAMESPACE}" -f "${install_url}"; then
        gum log --level error "kubectl apply failed. Check the URL and cluster permissions."
        exit 1
    fi

    info "Manifests applied. Waiting for rollout..."

    for deploy in workflow-controller argo-server; do
        if ! gum spin --spinner dot \
            --title "Waiting for ${deploy}..." -- \
            kubectl rollout status "deployment/${deploy}" \
                -n "${WORKFLOWS_NAMESPACE}" --timeout=120s; then
            warn "${deploy} rollout did not complete within 120s. Check: kubectl get pods -n ${WORKFLOWS_NAMESPACE}"
        else
            info "${deploy} is ready."
        fi
    done

    gum style \
        --foreground "$GREEN" --border-foreground "$GREEN" --border rounded \
        --align center --width 60 --margin "1 2" --padding "1 4" \
        "Argo Workflows ${SELECTED_VERSION} installed" \
        "Namespace: ${WORKFLOWS_NAMESPACE}"

    info "Access via port-forward — select it from the Workflows menu."
}

workflows_status() {
    header "Argo Workflows — Status"

    local installed
    installed=$(workflows_detect_installed)

    if [[ -z "$installed" ]]; then
        warn "Argo Workflows does not appear to be installed in namespace '${WORKFLOWS_NAMESPACE}'."
        return
    fi

    info "Installed version: ${installed}"
    info ""
    info "Deployments:"
    kubectl get deployments -n "${WORKFLOWS_NAMESPACE}" 2>/dev/null || warn "Could not retrieve deployments."

    info ""
    info "Pods:"
    kubectl get pods -n "${WORKFLOWS_NAMESPACE}" 2>/dev/null || warn "Could not retrieve pods."

    echo ""
    gum confirm "Press Enter to continue" --affirmative "OK" --negative "" || true
}

_wf_pf_is_running() { [[ -f "$_WORKFLOWS_PF_PID" ]] && kill -0 "$(cut -d: -f1 < "$_WORKFLOWS_PF_PID")" 2>/dev/null; }
_wf_pf_port()       { cut -d: -f2 < "$_WORKFLOWS_PF_PID" 2>/dev/null; }
_wf_pf_stop()       { kill "$(cut -d: -f1 < "$_WORKFLOWS_PF_PID")" 2>/dev/null || true; rm -f "$_WORKFLOWS_PF_PID"; success "Port-forward stopped."; }

workflows_port_forward() {
    header "Argo Workflows — Port Forward"

    local installed
    installed=$(workflows_detect_installed)

    if [[ -z "$installed" ]]; then
        warn "Argo Workflows does not appear to be installed."
        return
    fi

    if _wf_pf_is_running; then
        gum style --foreground "$GREEN" --border-foreground "$GREEN" --border rounded \
            --width 60 --margin "0 2" --padding "1 2" \
            "Port-forward is running" \
            "http://localhost:$(_wf_pf_port)"
        gum confirm "Stop port-forward?" && _wf_pf_stop || true
        return
    fi

    local port
    port=$(gum input \
        --placeholder "${WORKFLOWS_PORT}" \
        --header "Local port (leave empty for default ${WORKFLOWS_PORT}):") || true
    port="${port:-${WORKFLOWS_PORT}}"

    kubectl -n "${WORKFLOWS_NAMESPACE}" port-forward deployment/argo-server "${port}:2746" >/dev/null 2>&1 &
    echo "${!}:${port}" > "$_WORKFLOWS_PF_PID"

    local attempts=0
    until nc -z 127.0.0.1 "$port" 2>/dev/null || [[ $attempts -ge 20 ]]; do
        sleep 0.25; attempts=$((attempts + 1))
    done

    if ! _wf_pf_is_running; then
        warn "Port-forward failed to start. Check kubectl connectivity."
        rm -f "$_WORKFLOWS_PF_PID"; return
    fi

    success "Port-forward started: http://localhost:${port}"
}

workflows_uninstall() {
    header "Uninstall Argo Workflows"

    local installed
    installed=$(workflows_detect_installed)

    if [[ -z "$installed" ]]; then
        warn "Argo Workflows does not appear to be installed in namespace '${WORKFLOWS_NAMESPACE}'."
        return
    fi

    gum style \
        --foreground "$RED" --border-foreground "$RED" --border rounded \
        --width 60 --margin "0 2" --padding "1 2" \
        "You are about to uninstall Argo Workflows ${installed}." \
        "" \
        "This will delete namespace '${WORKFLOWS_NAMESPACE}' and all its resources," \
        "including any running workflows and their history." \
        "" \
        "CRDs installed by Argo Workflows will also be removed." \
        "This cannot be undone."

    if ! gum confirm "Uninstall Argo Workflows?"; then
        warn "Cancelled."
        return
    fi

    gum spin --spinner dot --title "Deleting namespace '${WORKFLOWS_NAMESPACE}'..." -- \
        kubectl delete namespace "${WORKFLOWS_NAMESPACE}" --ignore-not-found

    info "Removing Argo Workflows CRDs..."
    kubectl get crd 2>/dev/null \
        | grep 'argoproj.io' \
        | grep -v 'application\|appproject\|applicationset' \
        | awk '{print $1}' \
        | xargs -r kubectl delete crd 2>/dev/null || true

    success "Argo Workflows uninstalled."
}

workflows_menu() {
    while true; do
        header "Argo Workflows"

        local pf_label
        _wf_pf_is_running \
            && pf_label="port-forward  [● localhost:$(_wf_pf_port)]" \
            || pf_label="port-forward  [○ stopped]"

        local action
        action=$(gum choose \
            "install" \
            "status" \
            "$pf_label" \
            "uninstall" \
            "← back" \
            --header "Select action:") || true

        case "$action" in
            "install")       workflows_install ;;
            "status")        workflows_status ;;
            "port-forward"*) workflows_port_forward ;;
            "uninstall")     workflows_uninstall ;;
            "← back"|"")    return ;;
        esac
    done
}

# =============================================================================
# ARGO CD
# =============================================================================

argocd_detect_installed() {
    kubectl get deployment argocd-server -n "${ARGOCD_NAMESPACE}" \
        -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null \
        | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' || true
}

argocd_install() {
    header "Install Argo CD"
    check_cluster
    select_version "$ARGOCD_GH_API" "Argo CD"

    local installed
    installed=$(argocd_detect_installed)

    if [[ -n "$installed" ]]; then
        gum style \
            --foreground "$YELLOW" --border-foreground "$YELLOW" --border rounded \
            --align center --width 60 --margin "1 2" --padding "1 4" \
            "Argo CD already installed" \
            "Detected version: ${installed}" \
            "Target version:   ${SELECTED_VERSION}"

        local action
        action=$(gum choose \
            "Upgrade / Reinstall (apply selected version)" \
            "Cancel" \
            --header "What would you like to do?") || true

        case "$action" in
            "Upgrade / Reinstall"*) info "Proceeding with reinstall to ${SELECTED_VERSION}..." ;;
            *) warn "Cancelled."; return ;;
        esac
    fi

    # Ensure namespace
    if kubectl get namespace "${ARGOCD_NAMESPACE}" &>/dev/null; then
        info "Namespace '${ARGOCD_NAMESPACE}' already exists."
    else
        info "Creating namespace '${ARGOCD_NAMESPACE}'..."
        kubectl create namespace "${ARGOCD_NAMESPACE}"
    fi

    local install_url="${ARGOCD_INSTALL_BASE}/${SELECTED_VERSION}/manifests/install.yaml"
    info "Manifest URL: ${install_url}"

    if ! gum spin --spinner dot \
        --title "Applying Argo CD manifests..." -- \
        kubectl apply -n "${ARGOCD_NAMESPACE}" -f "${install_url}"; then
        gum log --level error "kubectl apply failed. Check the URL and cluster permissions."
        exit 1
    fi

    info "Manifests applied. Waiting for rollout..."

    for deploy in argocd-server argocd-application-controller argocd-repo-server; do
        if ! gum spin --spinner dot \
            --title "Waiting for ${deploy}..." -- \
            kubectl rollout status "deployment/${deploy}" \
                -n "${ARGOCD_NAMESPACE}" --timeout=180s 2>/dev/null; then
            warn "${deploy} rollout did not complete within 180s. Check: kubectl get pods -n ${ARGOCD_NAMESPACE}"
        else
            info "${deploy} is ready."
        fi
    done

    # argocd-application-controller is a StatefulSet, not a Deployment
    if ! gum spin --spinner dot \
        --title "Waiting for argocd-application-controller (StatefulSet)..." -- \
        kubectl rollout status statefulset/argocd-application-controller \
            -n "${ARGOCD_NAMESPACE}" --timeout=180s 2>/dev/null; then
        warn "argocd-application-controller rollout timed out. Check: kubectl get pods -n ${ARGOCD_NAMESPACE}"
    else
        info "argocd-application-controller is ready."
    fi

    gum style \
        --foreground "$GREEN" --border-foreground "$GREEN" --border rounded \
        --align center --width 60 --margin "1 2" --padding "1 4" \
        "Argo CD ${SELECTED_VERSION} installed" \
        "Namespace: ${ARGOCD_NAMESPACE}"

    warn "Retrieve the initial admin password from the Argo CD menu before first login."
    info "Access via port-forward — select it from the Argo CD menu."
}

argocd_status() {
    header "Argo CD — Status"

    local installed
    installed=$(argocd_detect_installed)

    if [[ -z "$installed" ]]; then
        warn "Argo CD does not appear to be installed in namespace '${ARGOCD_NAMESPACE}'."
        return
    fi

    info "Installed version: ${installed}"
    info ""
    info "Deployments:"
    kubectl get deployments -n "${ARGOCD_NAMESPACE}" 2>/dev/null || warn "Could not retrieve deployments."

    info ""
    info "Pods:"
    kubectl get pods -n "${ARGOCD_NAMESPACE}" 2>/dev/null || warn "Could not retrieve pods."

    echo ""
    gum confirm "Press Enter to continue" --affirmative "OK" --negative "" || true
}

_acd_pf_is_running() { [[ -f "$_ARGOCD_PF_PID" ]] && kill -0 "$(cut -d: -f1 < "$_ARGOCD_PF_PID")" 2>/dev/null; }
_acd_pf_port()       { cut -d: -f2 < "$_ARGOCD_PF_PID" 2>/dev/null; }
_acd_pf_stop()       { kill "$(cut -d: -f1 < "$_ARGOCD_PF_PID")" 2>/dev/null || true; rm -f "$_ARGOCD_PF_PID"; success "Port-forward stopped."; }

argocd_port_forward() {
    header "Argo CD — Port Forward"

    local installed
    installed=$(argocd_detect_installed)

    if [[ -z "$installed" ]]; then
        warn "Argo CD does not appear to be installed."
        return
    fi

    if _acd_pf_is_running; then
        gum style --foreground "$GREEN" --border-foreground "$GREEN" --border rounded \
            --width 60 --margin "0 2" --padding "1 2" \
            "Port-forward is running" \
            "https://localhost:$(_acd_pf_port)  (self-signed cert expected)"
        gum confirm "Stop port-forward?" && _acd_pf_stop || true
        return
    fi

    local port
    port=$(gum input \
        --placeholder "${ARGOCD_PORT}" \
        --header "Local port (leave empty for default ${ARGOCD_PORT}):") || true
    port="${port:-${ARGOCD_PORT}}"

    kubectl -n "${ARGOCD_NAMESPACE}" port-forward svc/argocd-server "${port}:443" >/dev/null 2>&1 &
    echo "${!}:${port}" > "$_ARGOCD_PF_PID"

    local attempts=0
    until nc -z 127.0.0.1 "$port" 2>/dev/null || [[ $attempts -ge 20 ]]; do
        sleep 0.25; attempts=$((attempts + 1))
    done

    if ! _acd_pf_is_running; then
        warn "Port-forward failed to start. Check kubectl connectivity."
        rm -f "$_ARGOCD_PF_PID"; return
    fi

    success "Port-forward started: https://localhost:${port}"
    warn "Self-signed cert — browser warning is expected for local use."
}

argocd_get_admin_password() {
    header "Argo CD — Initial Admin Password"

    local installed
    installed=$(argocd_detect_installed)

    if [[ -z "$installed" ]]; then
        warn "Argo CD does not appear to be installed."
        return
    fi

    local password
    password=$(kubectl -n "${ARGOCD_NAMESPACE}" get secret argocd-initial-admin-secret \
        -o jsonpath="{.data.password}" 2>/dev/null | base64 -d 2>/dev/null || true)

    if [[ -z "$password" ]]; then
        warn "argocd-initial-admin-secret not found."
        warn "It may have already been deleted after the password was changed — this is expected."
        warn "If you need to reset it: https://argo-cd.readthedocs.io/en/stable/faq/#i-forgot-the-admin-password-how-do-i-reset-it"
        return
    fi

    gum style \
        --foreground "$CYAN" --border-foreground "$CYAN" --border rounded \
        --align center --width 60 --margin "1 2" --padding "1 4" \
        "Initial admin credentials" \
        "" \
        "Username: admin" \
        "Password: ${password}"

    warn "Change this password after first login."
    warn "Delete the secret once done: kubectl delete secret argocd-initial-admin-secret -n ${ARGOCD_NAMESPACE}"

    echo ""
    gum confirm "Press Enter to continue" --affirmative "OK" --negative "" || true
}

argocd_uninstall() {
    header "Uninstall Argo CD"

    local installed
    installed=$(argocd_detect_installed)

    if [[ -z "$installed" ]]; then
        warn "Argo CD does not appear to be installed in namespace '${ARGOCD_NAMESPACE}'."
        return
    fi

    gum style \
        --foreground "$RED" --border-foreground "$RED" --border rounded \
        --width 60 --margin "0 2" --padding "1 2" \
        "You are about to uninstall Argo CD ${installed}." \
        "" \
        "⚠  WARNING: If you have applications managed by Argo CD, deleting" \
        "the namespace may orphan their resources in the cluster." \
        "" \
        "Recommended: remove all Argo CD applications before uninstalling." \
        "" \
        "CRDs (Application, AppProject, ApplicationSet) will also be removed." \
        "This cannot be undone."

    if ! gum confirm "Uninstall Argo CD?"; then
        warn "Cancelled."
        return
    fi

    if ! gum confirm "Last chance — confirm Argo CD uninstall?"; then
        warn "Cancelled."
        return
    fi

    gum spin --spinner dot --title "Deleting namespace '${ARGOCD_NAMESPACE}'..." -- \
        kubectl delete namespace "${ARGOCD_NAMESPACE}" --ignore-not-found

    info "Removing Argo CD CRDs..."
    for crd in applications.argoproj.io appprojects.argoproj.io applicationsets.argoproj.io; do
        kubectl delete crd "$crd" --ignore-not-found 2>/dev/null && info "  Removed CRD: ${crd}" || true
    done

    success "Argo CD uninstalled."
    warn "If any application resources remain in the cluster, remove them manually."
}

argocd_menu() {
    while true; do
        header "Argo CD"

        local pf_label
        _acd_pf_is_running \
            && pf_label="port-forward  [● localhost:$(_acd_pf_port)]" \
            || pf_label="port-forward  [○ stopped]"

        local action
        action=$(gum choose \
            "install" \
            "status" \
            "$pf_label" \
            "get admin password" \
            "uninstall" \
            "← back" \
            --header "Select action:") || true

        case "$action" in
            "install")             argocd_install ;;
            "status")              argocd_status ;;
            "port-forward"*)       argocd_port_forward ;;
            "get admin password")  argocd_get_admin_password ;;
            "uninstall")           argocd_uninstall ;;
            "← back"|"")          return ;;
        esac
    done
}

# =============================================================================
# ARGO EVENTS
# =============================================================================

argoevents_detect_installed() {
    kubectl get deployment controller-manager -n "${ARGOEVENTS_NAMESPACE}" \
        -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null \
        | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' || true
}

argoevents_install() {
    header "Install Argo Events"
    check_cluster
    select_version "$ARGOEVENTS_GH_API" "Argo Events"

    local installed
    installed=$(argoevents_detect_installed)

    if [[ -n "$installed" ]]; then
        gum style \
            --foreground "$YELLOW" --border-foreground "$YELLOW" --border rounded \
            --align center --width 60 --margin "1 2" --padding "1 4" \
            "Argo Events already installed" \
            "Detected version: ${installed}" \
            "Target version:   ${SELECTED_VERSION}"

        local action
        action=$(gum choose \
            "Upgrade / Reinstall (apply selected version)" \
            "Cancel" \
            --header "What would you like to do?") || true

        case "$action" in
            "Upgrade / Reinstall"*) info "Proceeding with reinstall to ${SELECTED_VERSION}..." ;;
            *) warn "Cancelled."; return ;;
        esac
    fi

    if kubectl get namespace "${ARGOEVENTS_NAMESPACE}" &>/dev/null; then
        info "Namespace '${ARGOEVENTS_NAMESPACE}' already exists."
    else
        info "Creating namespace '${ARGOEVENTS_NAMESPACE}'..."
        kubectl create namespace "${ARGOEVENTS_NAMESPACE}"
    fi

    local install_url="${ARGOEVENTS_INSTALL_BASE}/${SELECTED_VERSION}/install.yaml"
    info "Manifest URL: ${install_url}"

    if ! gum spin --spinner dot \
        --title "Applying Argo Events manifests..." -- \
        kubectl apply -n "${ARGOEVENTS_NAMESPACE}" -f "${install_url}"; then
        gum log --level error "kubectl apply failed. Check the URL and cluster permissions."
        exit 1
    fi

    info "Manifests applied. Waiting for rollout..."

    if ! gum spin --spinner dot \
        --title "Waiting for controller-manager..." -- \
        kubectl rollout status deployment/controller-manager \
            -n "${ARGOEVENTS_NAMESPACE}" --timeout=120s; then
        warn "controller-manager rollout did not complete within 120s."
        warn "Check: kubectl get pods -n ${ARGOEVENTS_NAMESPACE}"
    else
        info "controller-manager is ready."
    fi

    gum style \
        --foreground "$CYAN" --border-foreground "$CYAN" --border rounded \
        --align center --width 60 --margin "1 2" --padding "1 4" \
        "Argo Events ${SELECTED_VERSION} installed" \
        "Namespace: ${ARGOEVENTS_NAMESPACE}" \
        "" \
        "An EventBus is required before EventSources and Sensors can work." \
        "A default native-NATS EventBus is recommended for Kind clusters."

    if gum confirm "Create default EventBus (native NATS, no auth)?"; then
        kubectl apply -n "${ARGOEVENTS_NAMESPACE}" -f - <<'EOF'
apiVersion: argoproj.io/v1alpha1
kind: EventBus
metadata:
  name: default
spec:
  nats:
    native:
      auth: none
EOF
        info "Default EventBus created."
        kubectl get eventbus -n "${ARGOEVENTS_NAMESPACE}" 2>/dev/null || true
    fi

    success "Argo Events installed."
    info "Next: create an EventSource and a Sensor from your manifests."
}

argoevents_status() {
    header "Argo Events — Status"

    local installed
    installed=$(argoevents_detect_installed)

    if [[ -z "$installed" ]]; then
        warn "Argo Events does not appear to be installed in namespace '${ARGOEVENTS_NAMESPACE}'."
        return
    fi

    info "Installed version: ${installed}"

    echo ""
    gum style --foreground "$CYAN" --bold "── Deployments ──"
    kubectl get deployments -n "${ARGOEVENTS_NAMESPACE}" 2>/dev/null || warn "Could not retrieve deployments."

    echo ""
    gum style --foreground "$CYAN" --bold "── Pods ──"
    kubectl get pods -n "${ARGOEVENTS_NAMESPACE}" 2>/dev/null || warn "Could not retrieve pods."

    echo ""
    gum style --foreground "$CYAN" --bold "── EventBuses ──"
    kubectl get eventbus -n "${ARGOEVENTS_NAMESPACE}" 2>/dev/null || warn "No EventBuses found (required — run install to create one)."

    echo ""
    gum style --foreground "$CYAN" --bold "── EventSources ──"
    kubectl get eventsource -n "${ARGOEVENTS_NAMESPACE}" 2>/dev/null || warn "No EventSources found."

    echo ""
    gum style --foreground "$CYAN" --bold "── Sensors ──"
    kubectl get sensor -n "${ARGOEVENTS_NAMESPACE}" 2>/dev/null || warn "No Sensors found."

    echo ""
    gum confirm "Press Enter to continue" --affirmative "OK" --negative "" || true
}

_ae_pf_is_running() { [[ -f "$_ARGOEVENTS_PF_PID" ]] && kill -0 "$(cut -d: -f1 < "$_ARGOEVENTS_PF_PID")" 2>/dev/null; }
_ae_pf_port()       { cut -d: -f2 < "$_ARGOEVENTS_PF_PID" 2>/dev/null; }
_ae_pf_stop()       { kill "$(cut -d: -f1 < "$_ARGOEVENTS_PF_PID")" 2>/dev/null || true; rm -f "$_ARGOEVENTS_PF_PID"; success "Port-forward stopped."; }

argoevents_list_sources() {
    header "Argo Events — EventSources"

    local installed
    installed=$(argoevents_detect_installed)

    if [[ -z "$installed" ]]; then
        warn "Argo Events does not appear to be installed."
        return
    fi

    local sources
    sources=$(kubectl get eventsource -n "${ARGOEVENTS_NAMESPACE}" \
        --no-headers -o custom-columns="NAME:.metadata.name" 2>/dev/null || true)

    if [[ -z "$sources" ]]; then
        warn "No EventSources found in namespace '${ARGOEVENTS_NAMESPACE}'."
        info "Apply an EventSource manifest to get started."
        echo ""
        gum confirm "Press Enter to continue" --affirmative "OK" --negative "" || true
        return
    fi

    local selected
    selected=$(echo "$sources" | gum choose \
        --header "Select EventSource:") || true

    [[ -z "$selected" ]] && return

    # Argo Events names the service <eventsource-name>-eventsource-svc for HTTP-based sources
    local svc_name="${selected}-eventsource-svc"
    local svc_port
    svc_port=$(kubectl get svc "$svc_name" -n "${ARGOEVENTS_NAMESPACE}" \
        -o jsonpath='{.spec.ports[0].port}' 2>/dev/null || true)

    if [[ -z "$svc_port" ]]; then
        gum style --foreground "$YELLOW" --border-foreground "$YELLOW" --border rounded \
            --width 60 --margin "0 2" --padding "1 2" \
            "EventSource: ${selected}" \
            "" \
            "No service found — this EventSource type does not expose an HTTP endpoint." \
            "(calendar, resource, S3, and similar sources are internal-only)"
        echo ""
        gum confirm "Press Enter to continue" --affirmative "OK" --negative "" || true
        return
    fi

    # Service exists — this is a webhook/HTTP source; handle port-forward
    if _ae_pf_is_running; then
        local current_port
        current_port=$(_ae_pf_port)
        gum style --foreground "$GREEN" --border-foreground "$GREEN" --border rounded \
            --width 60 --margin "0 2" --padding "1 2" \
            "EventSource: ${selected}" \
            "Service:     ${svc_name}  (cluster port ${svc_port})" \
            "" \
            "Port-forward active: http://localhost:${current_port}"

        local action
        action=$(gum choose \
            "stop port-forward" \
            "← back" \
            --header "Port-forward is running:") || true

        case "$action" in
            "stop"*) _ae_pf_stop ;;
            *) return ;;
        esac
        return
    fi

    gum style --foreground "$CYAN" --border-foreground "$CYAN" --border rounded \
        --width 60 --margin "0 2" --padding "1 2" \
        "EventSource: ${selected}" \
        "Service:     ${svc_name}  (cluster port ${svc_port})"

    local port_input
    port_input=$(gum input \
        --placeholder "${ARGOEVENTS_DEFAULT_WEBHOOK_PORT}" \
        --header "Local port (leave empty for default ${ARGOEVENTS_DEFAULT_WEBHOOK_PORT}):") || true
    local port="${port_input:-${ARGOEVENTS_DEFAULT_WEBHOOK_PORT}}"

    kubectl -n "${ARGOEVENTS_NAMESPACE}" port-forward "svc/${svc_name}" "${port}:${svc_port}" >/dev/null 2>&1 &
    echo "${!}:${port}" > "$_ARGOEVENTS_PF_PID"

    local attempts=0
    until nc -z 127.0.0.1 "$port" 2>/dev/null || [[ $attempts -ge 20 ]]; do
        sleep 0.25; attempts=$((attempts + 1))
    done

    if ! _ae_pf_is_running; then
        warn "Port-forward failed to start. Check kubectl connectivity."
        rm -f "$_ARGOEVENTS_PF_PID"; return
    fi

    success "Port-forward started: http://localhost:${port}"
    info "POST events to: http://localhost:${port}/<event-name>"
}

argoevents_uninstall() {
    header "Uninstall Argo Events"

    local installed
    installed=$(argoevents_detect_installed)

    if [[ -z "$installed" ]]; then
        warn "Argo Events does not appear to be installed in namespace '${ARGOEVENTS_NAMESPACE}'."
        return
    fi

    gum style \
        --foreground "$RED" --border-foreground "$RED" --border rounded \
        --width 60 --margin "0 2" --padding "1 2" \
        "You are about to uninstall Argo Events ${installed}." \
        "" \
        "This will delete namespace '${ARGOEVENTS_NAMESPACE}' and all its resources," \
        "including EventBuses, EventSources, and Sensors." \
        "" \
        "CRDs installed by Argo Events will also be removed." \
        "This cannot be undone."

    if ! gum confirm "Uninstall Argo Events?"; then
        warn "Cancelled."
        return
    fi

    _ae_pf_is_running && _ae_pf_stop || true

    gum spin --spinner dot --title "Deleting namespace '${ARGOEVENTS_NAMESPACE}'..." -- \
        kubectl delete namespace "${ARGOEVENTS_NAMESPACE}" --ignore-not-found

    info "Removing Argo Events CRDs..."
    for crd in eventbus.argoproj.io eventsources.argoproj.io sensors.argoproj.io; do
        kubectl delete crd "$crd" --ignore-not-found 2>/dev/null \
            && info "  Removed CRD: ${crd}" || true
    done

    success "Argo Events uninstalled."
}

argoevents_menu() {
    while true; do
        header "Argo Events"

        local sources_label
        _ae_pf_is_running \
            && sources_label="event sources  [● pf: localhost:$(_ae_pf_port)]" \
            || sources_label="event sources"

        local action
        action=$(gum choose \
            "install" \
            "status" \
            "$sources_label" \
            "uninstall" \
            "← back" \
            --header "Select action:") || true

        case "$action" in
            "install")        argoevents_install ;;
            "status")         argoevents_status ;;
            "event sources"*) argoevents_list_sources ;;
            "uninstall")      argoevents_uninstall ;;
            "← back"|"")     return ;;
        esac
    done
}

# =============================================================================
# MAIN
# =============================================================================

main() {
    gum style \
        --foreground "$PURPLE" --border-foreground "$PURPLE" --border double \
        --align center --width 60 --margin "1 2" --padding "1 4" \
        'Argo'

    check_dependencies

    while true; do
        local tool
        tool=$(gum choose \
            "Argo Workflows" \
            "Argo CD" \
            "Argo Events" \
            "── quit ──" \
            --header "Select Argo tool:") || true

        case "$tool" in
            "Argo Workflows") workflows_menu ;;
            "Argo CD")        argocd_menu ;;
            "Argo Events")    argoevents_menu ;;
            "── quit ──"|"")  break ;;
        esac
    done

    gum style --faint "Bye."
}

main "$@"