#!/usr/bin/env bash
# description: Speaches - OpenAI-compatible speech server (speech-to-text + text-to-speech): install, models, test (Podman/Docker/K8s)
# export-setup: curl kubectl
# -----------------------------------------------------------------------------
# speaches.sh
# Installs and manages Speaches (https://speaches.ai), a ready-made speech
# server with an OpenAI-compatible API: /v1/audio/transcriptions and
# /v1/audio/speech. Each request names its model, so several models sit side
# by side and are compared by changing `model` - the same way LM Studio serves
# text models.
#
# Targets:
#   podman  rootless podman as a systemd user service (Quadlet) - survives a
#           reboot without a login. The default for corelia.
#   docker  a container with --restart unless-stopped.
#   kind/k8s  plain manifests (Speaches ships no Helm chart). There for the
#           option; a cluster managed by Argo CD should get an Application in
#           its GitOps repository instead.
#
# The defaults ARE the deployment: re-running `install` on a rebuilt host has
# to bring back the same service, so change a default here (and commit) rather
# than only in the local settings file.
#
# Config: ~/.config/speaches-tui/speaches.conf (key=value)
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
# Constants
# -----------------------------------------------------------------------------
SP_IMAGE_REPO="ghcr.io/speaches-ai/speaches"
SP_CONTAINER_PORT=8000
SP_CACHE_MOUNT="/home/ubuntu/.cache/huggingface/hub"   # the image's HF cache; its user is uid 1000
SP_NAME="speaches"                                     # container, unit, namespace and deployment

# Default models, checked against Hugging Face on 2026-10-14. Whisper turbo is
# the CTranslate2 build faster-whisper loads; Kokoro and Piper are Speaches'
# own text-to-speech packages. English voices: the owner's choice.
SP_WHISPER="deepdml/faster-whisper-large-v3-turbo-ct2"
SP_KOKORO="speaches-ai/Kokoro-82M-v1.0-ONNX"
SP_PIPER="speaches-ai/piper-en_US-lessac-medium"
SP_TEST_VOICE="af_heart"                               # a Kokoro voice, for `test`

CONFIG_DIR="${SCOMP_SPEACHES_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/speaches-tui}"
CONFIG_FILE="${CONFIG_DIR}/speaches.conf"
QUADLET_DIR="${SCOMP_SPEACHES_QUADLET_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/containers/systemd}"
QUADLET_FILE="${QUADLET_DIR}/${SP_NAME}.container"
_SP_PF_PID="/tmp/scomp-pf-speaches.pid"

BLUE=39

# -----------------------------------------------------------------------------
# Settings - the defaults are what corelia runs
# -----------------------------------------------------------------------------
cfg_defaults() {
    SP_VERSION="0.8.3"          # latest stable as of 2026-10-14; 0.9.0 is still a release candidate
    SP_VARIANT="auto"           # auto | cpu | cuda  (auto: cuda when nvidia-smi sees a GPU)
    SP_PORT=8000
    SP_TTL=300                  # seconds a model stays loaded after its last request; -1 = never unload
    SP_MODELS="${SP_WHISPER} ${SP_KOKORO} ${SP_PIPER}"
    SP_VOLUME="speaches-hf-cache"
    SP_K8S_STORAGE="20Gi"
    SP_K8S_STORAGE_CLASS=""     # empty = the cluster's default class
}

cfg_load() {
    cfg_defaults
    [[ -f "$CONFIG_FILE" ]] || return 0
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
}

cfg_save() {
    mkdir -p "$CONFIG_DIR"
    {
        printf '# speaches.sh settings - see the defaults in speaches.sh\n'
        local key
        for key in SP_VERSION SP_VARIANT SP_PORT SP_TTL SP_MODELS SP_VOLUME SP_K8S_STORAGE SP_K8S_STORAGE_CLASS; do
            printf '%s=%q\n' "$key" "${!key}"
        done
    } > "$CONFIG_FILE"
}

# cpu or cuda. A cluster's GPUs cannot be seen from here, so `auto` means cpu there.
sp_variant() {
    case "$SP_VARIANT" in
        cpu|cuda) echo "$SP_VARIANT" ;;
        *)
            if [[ "${TARGET_TYPE:-}" != kind && "${TARGET_TYPE:-}" != k8s ]] \
                && command -v nvidia-smi &>/dev/null && nvidia-smi -L &>/dev/null; then
                echo cuda
            else
                echo cpu
            fi ;;
    esac
}

sp_image() { echo "${SP_IMAGE_REPO}:${SP_VERSION}-$(sp_variant)"; }

# 0.8.x reads WHISPER__TTL; 0.9 renamed it and added one for text-to-speech.
# Each version ignores the names it does not know, so all three are set.
sp_env() {
    printf '%s\n' "WHISPER__TTL=${SP_TTL}" "STT_MODEL_TTL=${SP_TTL}" "TTS_MODEL_TTL=${SP_TTL}" "LOG_LEVEL=info"
}

sp_local_url() { echo "http://127.0.0.1:${SP_PORT}"; }

sp_lan_address() {
    if [[ "$(uname -s)" == Darwin ]]; then
        ipconfig getifaddr en0 2>/dev/null || true
    else
        # hostname -I is GNU-only; without it, no LAN address rather than an exit under set -e.
        { hostname -I 2>/dev/null || true; } | awk '{print $1}'
    fi
}

# -----------------------------------------------------------------------------
# Renderers - pure, so the tests can read what would be written
# -----------------------------------------------------------------------------
render_quadlet() {
    local image="$1" line
    cat <<EOF
# Written by scomp-link's speaches.sh - changes here are overwritten by its
# install and config actions. Edit the settings there instead.
[Unit]
Description=Speaches - OpenAI-compatible speech server
Wants=network-online.target
After=network-online.target

[Container]
ContainerName=${SP_NAME}
Image=${image}
PublishPort=${SP_PORT}:${SP_CONTAINER_PORT}
Volume=${SP_VOLUME}:${SP_CACHE_MOUNT}
EOF
    while IFS= read -r line; do echo "Environment=${line}"; done < <(sp_env)
    [[ "$image" == *-cuda ]] && echo "AddDevice=nvidia.com/gpu=all"
    cat <<'EOF'

[Service]
Restart=always
# The first start pulls a multi-gigabyte image.
TimeoutStartSec=900

[Install]
WantedBy=default.target
EOF
}

render_k8s() {
    local image="$1" line class_line=""
    [[ -n "$SP_K8S_STORAGE_CLASS" ]] && class_line="  storageClassName: ${SP_K8S_STORAGE_CLASS}"
    cat <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: ${SP_NAME}
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${SP_NAME}-hf-cache
  namespace: ${SP_NAME}
spec:
  accessModes: [ReadWriteOnce]
${class_line}
  resources:
    requests:
      storage: ${SP_K8S_STORAGE}
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${SP_NAME}
  namespace: ${SP_NAME}
  labels: {app: ${SP_NAME}}
spec:
  replicas: 1
  # One pod owns the ReadWriteOnce cache: the old one must stop before the new one starts.
  strategy: {type: Recreate}
  selector:
    matchLabels: {app: ${SP_NAME}}
  template:
    metadata:
      labels: {app: ${SP_NAME}}
    spec:
      securityContext:
        fsGroup: 1000          # the image runs as uid 1000; the cache must be writable by it
      containers:
        - name: ${SP_NAME}
          image: ${image}
          ports:
            - containerPort: ${SP_CONTAINER_PORT}
          env:
EOF
    while IFS= read -r line; do
        printf '            - {name: %s, value: "%s"}\n' "${line%%=*}" "${line#*=}"
    done < <(sp_env)
    cat <<EOF
          readinessProbe:
            httpGet: {path: /health, port: ${SP_CONTAINER_PORT}}
            periodSeconds: 10
          volumeMounts:
            - {name: hf-cache, mountPath: ${SP_CACHE_MOUNT}}
      volumes:
        - name: hf-cache
          persistentVolumeClaim: {claimName: ${SP_NAME}-hf-cache}
---
apiVersion: v1
kind: Service
metadata:
  name: ${SP_NAME}
  namespace: ${SP_NAME}
spec:
  selector: {app: ${SP_NAME}}
  ports:
    - port: ${SP_CONTAINER_PORT}
      targetPort: ${SP_CONTAINER_PORT}
EOF
}

# -----------------------------------------------------------------------------
# The API - the same for every target once there is a URL
# -----------------------------------------------------------------------------
sp_healthy() { curl -fsS --max-time 3 "$1/health" &>/dev/null; }

# Model IDs from an OpenAI-style list, one per line. No jq: grep is enough for
# '"id":"…"', and a missing jq should not stop a status screen.
_json_ids() { grep -o '"id" *: *"[^"]*"' | sed 's/.*: *"\(.*\)"/\1/'; }

sp_models_installed() { curl -fsS --max-time 10 "$1/v1/models" 2>/dev/null | _json_ids || true; }
sp_models_loaded()    { curl -fsS --max-time 10 "$1/api/ps" 2>/dev/null | _json_ids || true; }

sp_model_download() {
    local url="$1" model="$2"
    gum spin --spinner dot --title "Downloading ${model}..." -- \
        curl -fsS --max-time 3600 -X POST "${url}/v1/models/${model}" -o /dev/null
}

# Downloads every default model that is not installed yet. Idempotent.
sp_download_defaults() {
    local url="$1" installed model failed=0
    installed="$(sp_models_installed "$url")"
    for model in $SP_MODELS; do
        if grep -qxF -- "$model" <<< "$installed"; then
            info "${model}: already installed"
        elif sp_model_download "$url" "$model"; then
            success "${model}: downloaded"
        else
            warn "${model}: download failed - retry from the models menu"
            failed=1
        fi
    done
    return "$failed"
}

sp_models_menu() {
    local url="$1" choice model installed
    while true; do
        header "Speaches - models (${url})"
        choice=$(gum choose list download remove "download the defaults" "← back" --header "Action:") || return 0
        case "$choice" in
            list)
                installed="$(sp_models_installed "$url")"
                [[ -n "$installed" ]] && printf '%s\n' "$installed" || warn "No models installed (or the server is unreachable)."
                ;;
            download)
                model=$(gum input --placeholder "e.g. speaches-ai/piper-en_US-ryan-medium" \
                    --header "Model ID (Hugging Face repo, as Speaches' registry lists it):") || continue
                [[ -n "$model" ]] || continue
                sp_model_download "$url" "$model" && success "${model}: downloaded" || warn "${model}: download failed."
                ;;
            remove)
                installed="$(sp_models_installed "$url")"
                [[ -n "$installed" ]] || { warn "Nothing to remove."; continue; }
                # shellcheck disable=SC2086
                model=$(gum choose $installed "← back" --header "Remove which model?") || continue
                [[ "$model" == "← back" || -z "$model" ]] && continue
                gum confirm "Delete ${model} from the cache?" || continue
                curl -fsS -X DELETE "${url}/v1/models/${model}" -o /dev/null \
                    && success "${model}: removed" || warn "${model}: removal failed."
                ;;
            "download the defaults") sp_download_defaults "$url" || true ;;
            *) return 0 ;;
        esac
    done
}

# A round trip: Kokoro speaks a sentence, Whisper transcribes it back. One run
# shows both directions working, with no sample file needed.
sp_test() {
    local url="$1" tmp text sentence="Speaches is up, and both directions work."
    header "Speaches - test (${url})"
    sp_healthy "$url" || { warn "Not reachable at ${url}."; return 0; }
    tmp="$(mktemp -t speaches-test.XXXXXX)"
    if ! gum spin --spinner dot --title "Text to speech (${SP_KOKORO})..." -- \
        curl -fsS --max-time 300 "${url}/v1/audio/speech" -H 'content-type: application/json' \
            -d "{\"model\":\"${SP_KOKORO}\",\"voice\":\"${SP_TEST_VOICE}\",\"input\":\"${sentence}\",\"response_format\":\"wav\"}" \
            -o "$tmp" || [[ ! -s "$tmp" ]]; then
        warn "Text to speech failed - is ${SP_KOKORO} installed? (models -> list)"
        rm -f "$tmp"; return 0
    fi
    success "Text to speech: $(wc -c < "$tmp" | tr -d ' ') bytes of audio"
    if ! text=$(curl -fsS --max-time 600 "${url}/v1/audio/transcriptions" \
            -F "file=@${tmp};type=audio/wav" -F "model=${SP_WHISPER}" -F "response_format=text"); then
        warn "Speech to text failed - is ${SP_WHISPER} installed? (models -> list)"
        rm -f "$tmp"; return 0
    fi
    rm -f "$tmp"
    success "Speech to text: ${text}"
    info "Sent: ${sentence}"
}

# -----------------------------------------------------------------------------
# Firewall - so the LAN (meksha, Padme) can reach the port
# -----------------------------------------------------------------------------
_fw_tool() {
    if command -v firewall-cmd &>/dev/null && systemctl is-active --quiet firewalld 2>/dev/null; then
        echo firewalld
    elif command -v ufw &>/dev/null; then
        echo ufw
    fi
}

# open | closed | unknown | none
sp_firewall_state() {
    local port="$1" tool out
    tool="$(_fw_tool)"
    case "$tool" in
        firewalld)
            # --query-port prints yes/no and exits 1 on "no", so the answer is
            # the output, not the exit status. Anything else (e.g. a polkit
            # refusal) means it could not be read - try sudo without a prompt.
            out=$(firewall-cmd --query-port="${port}/tcp" 2>/dev/null || true)
            [[ "$out" == yes || "$out" == no ]] || out=$(sudo -n firewall-cmd --query-port="${port}/tcp" 2>/dev/null || true)
            case "$out" in
                yes) echo open ;;
                no)  echo closed ;;
                *)   echo unknown ;;
            esac ;;
        ufw)
            if out=$(sudo -n ufw status 2>/dev/null); then
                if grep -q "Status: inactive" <<< "$out"; then
                    echo none                       # installed, but blocking nothing
                elif grep -qE "^${port}(/tcp)?[[:space:]]+ALLOW" <<< "$out"; then
                    echo open
                else
                    echo closed
                fi
            else
                echo unknown
            fi ;;
        *) echo none ;;
    esac
}

sp_firewall_offer() {
    local port="$1" tool state
    tool="$(_fw_tool)"; state="$(sp_firewall_state "$port")"
    case "$state" in
        open) info "Firewall (${tool}): ${port}/tcp is open."; return 0 ;;
        none) info "No active firewall (firewalld or ufw); nothing to open."; return 0 ;;
    esac
    gum confirm "Open ${port}/tcp in ${tool} so the LAN (e.g. meksha) can reach Speaches? (needs sudo)" || {
        warn "Port left as it is - the LAN may not reach Speaches. 'status' shows the firewall state."
        return 0
    }
    case "$tool" in
        firewalld)
            _require_sudo_or_instruct "Opening ${port}/tcp" \
                "sudo firewall-cmd --permanent --add-port=${port}/tcp && sudo firewall-cmd --reload"
            sudo firewall-cmd --permanent --add-port="${port}/tcp" && sudo firewall-cmd --reload \
                && success "Opened ${port}/tcp (permanent)." || warn "Could not open ${port}/tcp."
            ;;
        ufw)
            _require_sudo_or_instruct "Opening ${port}/tcp" "sudo ufw allow ${port}/tcp"
            sudo ufw allow "${port}/tcp" && success "Opened ${port}/tcp." || warn "Could not open ${port}/tcp."
            ;;
    esac
}

# The part of `status` every local target shares.
sp_status_common() {
    local url="$1" lan installed loaded model missing=()
    if sp_healthy "$url"; then success "Health: ok (${url})"; else warn "Health: unreachable at ${url}"; fi
    lan="$(sp_lan_address)"
    [[ -n "$lan" ]] && info "LAN URL: http://${lan}:${SP_PORT}  (OpenAI base URL: http://${lan}:${SP_PORT}/v1)"
    installed="$(sp_models_installed "$url")"
    loaded="$(sp_models_loaded "$url")"
    info "Installed models: $(tr '\n' ' ' <<< "${installed:-none}")"
    info "Loaded now: $(tr '\n' ' ' <<< "${loaded:-none}")"
    for model in $SP_MODELS; do grep -qxF -- "$model" <<< "$installed" || missing+=("$model"); done
    (( ${#missing[@]} )) && warn "Default models not installed: ${missing[*]} (models -> download the defaults)"
    local fw; fw="$(sp_firewall_state "$SP_PORT")"
    case "$fw" in
        open)    info "Firewall ($(_fw_tool)): ${SP_PORT}/tcp open" ;;
        closed)  warn "Firewall ($(_fw_tool)): ${SP_PORT}/tcp closed - the LAN cannot reach Speaches (install offers to open it)" ;;
        unknown) warn "Firewall ($(_fw_tool)): state of ${SP_PORT}/tcp unknown (reading it needs sudo)" ;;
        none)    info "Firewall: none active (no firewalld, or ufw inactive)" ;;
    esac
    [[ "${TARGET_TYPE:-}" == docker && "$fw" == closed ]] \
        && info "Docker publishes ports through its own iptables rules, so the port may be reachable anyway."
    return 0
}

# The end of every local install: models, firewall, where to find it.
sp_after_install() {
    local url; url="$(sp_local_url)"
    if ! gum spin --spinner dot --title "Waiting for Speaches at ${url}..." -- \
        bash -c "for i in \$(seq 1 120); do curl -fsS --max-time 3 '${url}/health' >/dev/null 2>&1 && exit 0; sleep 2; done; exit 1"; then
        warn "Speaches did not answer yet - check 'logs'. Models can be downloaded later from 'models'."
        return 0
    fi
    success "Speaches is up at ${url}"
    sp_download_defaults "$url" || true
    sp_firewall_offer "$SP_PORT"
    local lan; lan="$(sp_lan_address)"
    [[ -n "$lan" ]] && info "From the LAN: http://${lan}:${SP_PORT}/v1 (OpenAI-compatible base URL)"
    return 0
}

# -----------------------------------------------------------------------------
# Dependencies
# -----------------------------------------------------------------------------
_podman_ensure() {
    _ensure_pkg podman podman || error_exit "podman was layered and needs a reboot - re-run this after it."
    local version major minor
    version="$(podman version --format '{{.Client.Version}}' 2>/dev/null || podman --version | awk '{print $NF}')"
    major="${version%%.*}"; minor="${version#*.}"; minor="${minor%%.*}"
    if [[ "$major" =~ ^[0-9]+$ && "$minor" =~ ^[0-9]+$ ]] && (( major < 4 || (major == 4 && minor < 4) )); then
        error_exit "podman ${version} has no Quadlet support (needs 4.4 or later)."
    fi
    info "podman: ${version}"
}

check_dependencies() {
    info "Checking dependencies..."
    command -v curl &>/dev/null || _ensure_pkg curl curl
    case "$TARGET_TYPE" in
        docker)   _check_docker ;;
        podman)   _podman_ensure ;;
        kind|k8s) _check_kubectl ;;
    esac
}

# -----------------------------------------------------------------------------
# Settings action
# -----------------------------------------------------------------------------
sp_show_settings() {
    gum style --border rounded --padding "0 2" \
        "Image:     $(sp_image)" \
        "Port:      ${SP_PORT}" \
        "Idle time: ${SP_TTL}s before an unused model is unloaded" \
        "Models:    ${SP_MODELS}" \
        "Cache:     ${SP_VOLUME}" \
        "Settings:  ${CONFIG_FILE}"
}

# Returns 0 when something changed (the caller offers to re-apply).
sp_config() {
    local field value before
    before="$(declare -p SP_VERSION SP_VARIANT SP_PORT SP_TTL SP_MODELS SP_VOLUME SP_K8S_STORAGE SP_K8S_STORAGE_CLASS)"
    while true; do
        header "Speaches - settings"
        sp_show_settings
        field=$(gum choose version variant port "idle time" models "cache volume" "k8s storage" "k8s storage class" "reset to defaults" "done" \
            --header "Change:") || break
        case "$field" in
            version)  value=$(gum input --value "$SP_VERSION" --header "Speaches version (image tag without -cpu/-cuda):") || continue
                      [[ -n "$value" ]] && SP_VERSION="$value" ;;
            variant)  value=$(gum choose auto cpu cuda --header "Image variant (auto: cuda when an NVIDIA GPU is visible):") || continue
                      SP_VARIANT="$value" ;;
            port)     value=$(gum input --value "$SP_PORT" --header "Port on this host:") || continue
                      [[ "$value" =~ ^[0-9]+$ ]] && (( value > 0 && value < 65536 )) && SP_PORT="$value" || warn "Not a port: ${value}" ;;
            "idle time") value=$(gum input --value "$SP_TTL" --header "Seconds an unused model stays loaded (-1 = never unload, 0 = unload at once):") || continue
                      [[ "$value" =~ ^-?[0-9]+$ ]] && (( value >= -1 )) && SP_TTL="$value" || warn "Not a valid idle time: ${value}" ;;
            models)   value=$(gum input --value "$SP_MODELS" --width 120 --header "Default models (space-separated):") || continue
                      [[ -n "$value" ]] && SP_MODELS="$value" ;;
            "cache volume") value=$(gum input --value "$SP_VOLUME" --header "Named volume for the model cache:") || continue
                      [[ -n "$value" ]] && SP_VOLUME="$value" ;;
            "k8s storage") value=$(gum input --value "$SP_K8S_STORAGE" --header "PVC size:") || continue
                      [[ -n "$value" ]] && SP_K8S_STORAGE="$value" ;;
            "k8s storage class") value=$(gum input --value "$SP_K8S_STORAGE_CLASS" --header "StorageClass (empty = the cluster's default):") || continue
                      SP_K8S_STORAGE_CLASS="$value" ;;
            "reset to defaults") gum confirm "Reset every setting to the script's defaults?" && cfg_defaults ;;
            *) break ;;
        esac
    done
    [[ "$before" == "$(declare -p SP_VERSION SP_VARIANT SP_PORT SP_TTL SP_MODELS SP_VOLUME SP_K8S_STORAGE SP_K8S_STORAGE_CLASS)" ]] && return 1
    cfg_save
    success "Saved to ${CONFIG_FILE}"
    return 0
}

# -----------------------------------------------------------------------------
# Podman target - a Quadlet unit under the user's systemd
# -----------------------------------------------------------------------------
_linger_on() { [[ "$(loginctl show-user "$(id -un)" -p Linger --value 2>/dev/null)" == yes ]]; }

sp_install_podman() {
    header "Install Speaches - Podman (systemd user service)"
    sp_show_settings
    gum confirm "Install with these settings? (change them under 'config')" || return 0
    local image; image="$(sp_image)"
    gum spin --spinner dot --title "Pulling ${image}..." -- podman pull "$image" >/dev/null \
        || error_exit "Could not pull ${image}."
    mkdir -p "$QUADLET_DIR"
    render_quadlet "$image" > "$QUADLET_FILE"
    info "Wrote ${QUADLET_FILE}"
    systemctl --user daemon-reload
    systemctl --user restart "${SP_NAME}.service" || error_exit "Start failed - see 'logs'."
    if ! _linger_on; then
        if gum confirm "Enable lingering so Speaches starts at boot without a login? (recommended)"; then
            loginctl enable-linger "$(id -un)" \
                || warn "Could not enable linger (run: sudo loginctl enable-linger $(id -un))"
        else
            warn "Without lingering, Speaches starts only once you log in."
        fi
    fi
    cfg_save
    sp_after_install
}

sp_status_podman() {
    header "Speaches - Podman status"
    if [[ -f "$QUADLET_FILE" ]]; then info "Unit: ${QUADLET_FILE}"; else warn "Not installed (no ${QUADLET_FILE})."; fi
    info "Service: $(systemctl --user is-active "${SP_NAME}.service" 2>/dev/null || true)"
    if _linger_on; then info "Linger: on - starts at boot"; else warn "Linger: off - starts only after a login"; fi
    podman ps -a --filter "name=^${SP_NAME}$" --format '{{.Names}}  {{.Image}}  {{.Status}}' 2>/dev/null || true
    sp_status_common "$(sp_local_url)"
}

sp_logs_podman() { journalctl --user -u "${SP_NAME}.service" -n 200 --no-pager || true; }

sp_uninstall_podman() {
    header "Uninstall Speaches - Podman"
    [[ -f "$QUADLET_FILE" ]] || { warn "Not installed."; return 0; }
    gum confirm "Stop Speaches and remove its unit?" || return 0
    systemctl --user stop "${SP_NAME}.service" 2>/dev/null || true
    rm -f "$QUADLET_FILE"
    systemctl --user daemon-reload
    success "Removed the unit."
    if gum confirm "Also delete the model cache (volume ${SP_VOLUME})? Models would download again."; then
        podman volume rm "$SP_VOLUME" >/dev/null && success "Deleted ${SP_VOLUME}." || warn "Could not delete ${SP_VOLUME}."
    else
        info "Kept the model cache (${SP_VOLUME})."
    fi
}

# -----------------------------------------------------------------------------
# Docker target
# -----------------------------------------------------------------------------
_docker_exists() { docker inspect "$SP_NAME" &>/dev/null; }

sp_docker_run_args() {
    local image="$1" line
    local -a args=(run -d --name "$SP_NAME" --restart unless-stopped
        -p "${SP_PORT}:${SP_CONTAINER_PORT}" -v "${SP_VOLUME}:${SP_CACHE_MOUNT}")
    while IFS= read -r line; do args+=(-e "$line"); done < <(sp_env)
    [[ "$image" == *-cuda ]] && args+=(--gpus=all)
    args+=("$image")
    printf '%s\n' "${args[@]}"
}

sp_install_docker() {
    header "Install Speaches - Docker"
    sp_show_settings
    gum confirm "Install with these settings? (change them under 'config')" || return 0
    local image; image="$(sp_image)"
    if _docker_exists; then
        gum confirm "Container '${SP_NAME}' exists - recreate it? (the model cache is kept)" || return 0
        docker rm -f "$SP_NAME" >/dev/null
    fi
    gum spin --spinner dot --title "Pulling ${image}..." -- docker pull "$image" >/dev/null \
        || error_exit "Could not pull ${image}."
    local -a args; mapfile -t args < <(sp_docker_run_args "$image")
    docker "${args[@]}" >/dev/null || error_exit "Could not start '${SP_NAME}'."
    cfg_save
    sp_after_install
}

sp_status_docker() {
    header "Speaches - Docker status"
    _docker_exists || warn "Container '${SP_NAME}' not found."
    docker ps -a --filter "name=^/${SP_NAME}$" --format '{{.Names}}  {{.Image}}  {{.Status}}' 2>/dev/null || true
    sp_status_common "$(sp_local_url)"
}

sp_logs_docker() { docker logs --tail 200 "$SP_NAME" 2>&1 || true; }

sp_uninstall_docker() {
    header "Uninstall Speaches - Docker"
    _docker_exists || { warn "Not installed."; return 0; }
    gum confirm "Remove container '${SP_NAME}'?" || return 0
    docker rm -f "$SP_NAME" >/dev/null && success "Removed."
    if gum confirm "Also delete the model cache (volume ${SP_VOLUME})? Models would download again."; then
        docker volume rm "$SP_VOLUME" >/dev/null && success "Deleted ${SP_VOLUME}." || warn "Could not delete ${SP_VOLUME}."
    fi
}

# -----------------------------------------------------------------------------
# Kubernetes target - plain manifests
# -----------------------------------------------------------------------------
_kctx() { kubectl_context_flag; }

_k8s_check_cluster() {
    # shellcheck disable=SC2046
    gum spin --spinner dot --title "Verifying cluster..." -- kubectl $(_kctx) cluster-info &>/dev/null \
        || { warn "Cannot reach cluster '${TARGET_CONTEXT}'."; return 1; }
}

# A URL for the API: the running port-forward, or a new one.
sp_k8s_url() {
    if ! pf_is_running "$_SP_PF_PID"; then
        sp_port_forward_k8s start || return 1
    fi
    echo "http://127.0.0.1:$(pf_port "$_SP_PF_PID")"
}

sp_port_forward_k8s() {
    local mode="${1:-toggle}" port
    if pf_is_running "$_SP_PF_PID"; then
        [[ "$mode" == start ]] && return 0
        gum confirm "Stop the port-forward on :$(pf_port "$_SP_PF_PID")?" && pf_stop "$_SP_PF_PID"
        return 0
    fi
    port=$(gum input --value "$SP_PORT" --header "Local port for the port-forward:") || return 1
    port="${port:-$SP_PORT}"
    # shellcheck disable=SC2046
    kubectl $(_kctx) -n "$SP_NAME" port-forward "svc/${SP_NAME}" "${port}:${SP_CONTAINER_PORT}" >/dev/null 2>&1 &
    echo "${!}:${port}" > "$_SP_PF_PID"
    sleep 2
    if pf_is_running "$_SP_PF_PID"; then
        success "Port-forward: http://127.0.0.1:${port}" >&2
    else
        warn "Port-forward failed."; rm -f "$_SP_PF_PID"; return 1
    fi
}

sp_install_k8s() {
    header "Install Speaches - Kubernetes (${TARGET_CONTEXT})"
    _k8s_check_cluster || return 0
    warn "A cluster managed by Argo CD should get Speaches as an Application in its GitOps repository; what this applies is outside it."
    sp_show_settings
    gum confirm "Apply the manifests to '${TARGET_CONTEXT}'?" || return 0
    # shellcheck disable=SC2046
    render_k8s "$(sp_image)" | kubectl $(_kctx) apply -f - || error_exit "kubectl apply failed."
    # shellcheck disable=SC2046
    gum spin --spinner dot --title "Waiting for the rollout (the first pull is large)..." -- \
        kubectl $(_kctx) -n "$SP_NAME" rollout status "deploy/${SP_NAME}" --timeout=20m \
        || { warn "Not ready yet - see 'logs'."; return 0; }
    cfg_save
    local url; url="$(sp_k8s_url)" || return 0
    sp_download_defaults "$url" || true
    info "Inside the cluster: http://${SP_NAME}.${SP_NAME}.svc:${SP_CONTAINER_PORT}/v1"
}

sp_status_k8s() {
    header "Speaches - Kubernetes status (${TARGET_CONTEXT})"
    _k8s_check_cluster || return 0
    # shellcheck disable=SC2046
    kubectl $(_kctx) -n "$SP_NAME" get deploy,pods,svc,pvc 2>/dev/null || warn "Nothing in namespace '${SP_NAME}'."
    if pf_is_running "$_SP_PF_PID"; then
        local url; url="http://127.0.0.1:$(pf_port "$_SP_PF_PID")"
        sp_healthy "$url" && success "Health: ok (${url})" || warn "Health: unreachable at ${url}"
        info "Installed models: $(sp_models_installed "$url" | tr '\n' ' ')"
    else
        info "Start a port-forward to see health and models."
    fi
}

# shellcheck disable=SC2046
sp_logs_k8s() { kubectl $(_kctx) -n "$SP_NAME" logs "deploy/${SP_NAME}" --tail 200 2>&1 || true; }

sp_uninstall_k8s() {
    header "Uninstall Speaches - Kubernetes (${TARGET_CONTEXT})"
    _k8s_check_cluster || return 0
    gum confirm "Delete the Speaches deployment and service?" || return 0
    pf_is_running "$_SP_PF_PID" && pf_stop "$_SP_PF_PID"
    # shellcheck disable=SC2046
    kubectl $(_kctx) -n "$SP_NAME" delete deploy,svc "$SP_NAME" --ignore-not-found
    if gum confirm "Also delete the model cache (PVC) and the namespace? Models would download again."; then
        # shellcheck disable=SC2046
        kubectl $(_kctx) delete namespace "$SP_NAME" --ignore-not-found
    fi
    success "Uninstalled."
}

# -----------------------------------------------------------------------------
# Menus
# -----------------------------------------------------------------------------
_local_menu() {
    local t="$TARGET_TYPE" action
    while true; do
        header "Speaches - $(target_summary)"
        action=$(gum choose install status models test logs config uninstall "← back" --header "Action:") || return 0
        case "$action" in
            install)   "sp_install_${t}" ;;
            status)    "sp_status_${t}" ;;
            models)    sp_models_menu "$(sp_local_url)" ;;
            test)      sp_test "$(sp_local_url)" ;;
            logs)      "sp_logs_${t}" ;;
            config)    if sp_config && gum confirm "Re-apply now (re-install with the new settings)?"; then "sp_install_${t}"; fi ;;
            uninstall) "sp_uninstall_${t}" ;;
            *) return 0 ;;
        esac
    done
}

_k8s_menu() {
    local action url
    while true; do
        header "Speaches - $(target_summary)"
        action=$(gum choose install status port-forward models test logs config uninstall "← back" --header "Action:") || return 0
        case "$action" in
            install)      sp_install_k8s ;;
            status)       sp_status_k8s ;;
            port-forward) sp_port_forward_k8s || true ;;
            models)       url="$(sp_k8s_url)" && sp_models_menu "$url" ;;
            test)         url="$(sp_k8s_url)" && sp_test "$url" ;;
            logs)         sp_logs_k8s ;;
            config)       if sp_config && gum confirm "Re-apply now?"; then sp_install_k8s; fi ;;
            uninstall)    sp_uninstall_k8s ;;
            *) return 0 ;;
        esac
    done
}

main() {
    gum style --foreground "$BLUE" --border-foreground "$BLUE" --border double \
        --align center --width 60 --margin "1 2" --padding "1 4" \
        "Speaches" "speech-to-text · text-to-speech" "Podman · Docker · Kubernetes"
    cfg_load
    # shellcheck disable=SC2034  # read by _common/cluster.sh's select_target
    SELECT_TARGET_PODMAN=1
    select_target || exit 1
    check_dependencies
    case "$TARGET_TYPE" in
        docker|podman) _local_menu ;;
        kind|k8s)      _k8s_menu ;;
    esac
    gum style --faint "Bye."
}

# Sourced by the tests for its renderers; run otherwise.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
