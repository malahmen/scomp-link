#!/usr/bin/env bash
# description: protocol - the conversion API (marker · markitdown) on corelia: build, install, status, test (Podman)
# export-setup: curl git
# -----------------------------------------------------------------------------
# protocol.sh
# Installs and manages protocol (https://github.com/malahmen/protocol), the one
# conversion API every converter sits behind: an HTTP API that answers 202 and
# an ID at once, and a worker per lane that does the converting - marker's
# light and heavy lanes, markitdown, and the removals and prunes.
#
# Podman only: rootless, a Quadlet unit per process under the user's systemd,
# with lingering so it starts at boot without a login. The marker worker runs
# inside protocol-droid's marker image (torch and llama-server, 6.8 GB), built
# here from source, so the host that builds is the host that runs - corelia.
#
# What it stores into is not here, and nothing here creates it: the registry
# database and a Redis of its own on meksha, the two buckets on Garage on the
# NAS (kuat's protocol_stores role, Kamino item 22). Their credentials are in
# kuat's vault; `install` asks for each once and keeps it as a podman secret,
# which reaches the containers as an environment variable and never a file
# here or a command line.
#
# The defaults ARE the deployment: re-running `install` on a rebuilt host has
# to bring back the same service, so change a default here (and commit) rather
# than only in the local settings file.
#
# Config: ~/.config/protocol-tui/protocol.conf (key=value)
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

# -----------------------------------------------------------------------------
# Constants
# -----------------------------------------------------------------------------
PR_API_CONTAINER_PORT=8080
PR_IMAGE_API="localhost/protocol:latest"
PR_IMAGE_MARKER="localhost/protocol-marker:latest"
PR_IMAGE_MARKITDOWN="localhost/protocol-markitdown:latest"
# protocol-droid's own names for its images (its Dockerfiles say so), so its
# `container` mode and this share one build.
PR_ENGINE_MARKER="localhost/marker-service:latest"
PR_ENGINE_MARKITDOWN="localhost/markitdown-service:latest"
PR_REVISION_LABEL="org.opencontainers.image.revision"

# One SELinux level for both marker workers. surya downloads a model into a
# temporary folder and moves it into the cache, and the move keeps the
# container's own categories on every file - so under a per-container level
# the light worker could not read what the heavy one downloaded (and the
# warm-up hung on it). A fixed level shared by the two keeps them confined
# from every other container and readable to each other.
PR_MARKER_SELINUX_LEVEL="s0:c470,c471"

# unit -> image and command (python -m protocol.deploy ...)
PR_UNITS=(protocol-api protocol-maintenance protocol-markitdown protocol-marker-light protocol-marker-heavy)

# podman secret -> the variable it becomes in the containers -> its name in kuat's vault
PR_SECRETS=(
    "protocol-mariadb-password:MARIADB_PASSWORD:protocol_db_password"
    "protocol-redis-password:REDIS_PASSWORD:protocol_redis_password"
    "protocol-s3-access-key:S3_ACCESS_KEY_ID:protocol_s3_access_key"
    "protocol-s3-secret-key:S3_SECRET_ACCESS_KEY:protocol_s3_secret_key"
    "protocol-qdrant-api-key:QDRANT_API_KEY:qdrant_api_key"
)

CONFIG_DIR="${SCOMP_PROTOCOL_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/protocol-tui}"
CONFIG_FILE="${CONFIG_DIR}/protocol.conf"
QUADLET_DIR="${SCOMP_PROTOCOL_QUADLET_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/containers/systemd}"
SRC_DIR="${SCOMP_PROTOCOL_SRC_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/scomp-link/protocol-build}"

PURPLE=141

# -----------------------------------------------------------------------------
# Settings - the defaults are what corelia runs
# -----------------------------------------------------------------------------
PR_SETTINGS=(PR_PORT PR_MARIADB_HOST PR_MARIADB_PORT PR_REDIS_URL PR_S3_ENDPOINT
    PR_S3_SOURCES_BUCKET PR_S3_OUTPUTS_BUCKET PR_QDRANT_URL PR_QDRANT_COLLECTIONS
    PR_MODELS_VOLUME PR_PROTOCOL_REPO PR_DROID_REPO PR_REF)

cfg_defaults() {
    PR_PORT=8090
    # meksha: kuat's protocol_stores role. 6380 is protocol's own Redis, with a
    # password - not meksha's podman Redis, which publishes no port.
    PR_MARIADB_HOST="192.168.3.52"
    PR_MARIADB_PORT=3306
    PR_REDIS_URL="redis://192.168.3.52:6380/0"
    # Garage on the NAS (taris); the buckets were made there by hand (item 22).
    PR_S3_ENDPOINT="http://192.168.3.5:3900"
    PR_S3_SOURCES_BUCKET="protocol-sources"
    PR_S3_OUTPUTS_BUCKET="protocol-outputs"
    PR_QDRANT_URL="http://192.168.3.52:6333"
    # Empty until ingestion exists and names its collections: removal then
    # deletes no vectors, and says so in the log and in `status`.
    PR_QDRANT_COLLECTIONS=""
    PR_MODELS_VOLUME="protocol-models"
    PR_PROTOCOL_REPO="https://github.com/malahmen/protocol.git"
    PR_DROID_REPO="https://github.com/malahmen/protocol-droid.git"
    PR_REF="main"               # built for both repositories
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
        printf '# protocol.sh settings - see the defaults in protocol.sh\n'
        local key
        for key in "${PR_SETTINGS[@]}"; do printf '%s=%q\n' "$key" "${!key}"; done
    } > "$CONFIG_FILE"
}

# The containers' settings that are not secret, one NAME=value per line.
pr_env() {
    printf '%s\n' \
        "MARIADB_HOST=${PR_MARIADB_HOST}" "MARIADB_PORT=${PR_MARIADB_PORT}" \
        "REDIS_URL=${PR_REDIS_URL}" \
        "S3_ENDPOINT=${PR_S3_ENDPOINT}" \
        "S3_SOURCES_BUCKET=${PR_S3_SOURCES_BUCKET}" "S3_OUTPUTS_BUCKET=${PR_S3_OUTPUTS_BUCKET}" \
        "QDRANT_URL=${PR_QDRANT_URL}"
    [[ -n "$PR_QDRANT_COLLECTIONS" ]] && echo "QDRANT_COLLECTIONS=${PR_QDRANT_COLLECTIONS}"
    return 0
}

pr_local_url() { echo "http://127.0.0.1:${PR_PORT}"; }

pr_lan_address() { { hostname -I 2>/dev/null || true; } | awk '{print $1}'; }

# unit -> "image|command"
pr_unit_spec() {
    case "$1" in
        protocol-api)          echo "${PR_IMAGE_API}|api" ;;
        protocol-maintenance)  echo "${PR_IMAGE_API}|worker maintenance" ;;
        protocol-markitdown)   echo "${PR_IMAGE_MARKITDOWN}|worker markitdown" ;;
        protocol-marker-light) echo "${PR_IMAGE_MARKER}|worker marker-light" ;;
        protocol-marker-heavy) echo "${PR_IMAGE_MARKER}|worker marker-heavy" ;;
        *) return 1 ;;
    esac
}

# -----------------------------------------------------------------------------
# Renderers - pure, so the tests can read what would be written
# -----------------------------------------------------------------------------
render_quadlet() {
    local unit="$1" spec image cmd line entry
    spec="$(pr_unit_spec "$unit")"; image="${spec%%|*}"; cmd="${spec#*|}"
    cat <<EOF
# Written by scomp-link's protocol.sh - changes here are overwritten by its
# install and config actions. Edit the settings there instead.
[Unit]
Description=protocol - ${cmd}
Wants=network-online.target
After=network-online.target

[Container]
ContainerName=${unit}
Image=${image}
Exec=${cmd}
EOF
    while IFS= read -r line; do echo "Environment=${line}"; done < <(pr_env)
    for entry in "${PR_SECRETS[@]}"; do
        IFS=: read -r secret var _ <<< "$entry"
        echo "Secret=${secret},type=env,target=${var}"
    done
    [[ "$unit" == protocol-api ]] && echo "PublishPort=${PR_PORT}:${PR_API_CONTAINER_PORT}"
    if [[ "$image" == "$PR_IMAGE_MARKER" ]]; then
        echo "Volume=${PR_MODELS_VOLUME}:/models"
        echo "SecurityLabelLevel=${PR_MARKER_SELINUX_LEVEL}"
    fi
    cat <<'EOF'

[Service]
Restart=always
# Not a hot loop while meksha or the NAS is down: the API exits when it cannot
# reach the registry, and comes back on its own once it can.
RestartSec=15

[Install]
WantedBy=default.target
EOF
}

# podman run arguments that hand a one-off container what a unit gets.
pr_run_args() {
    local line entry
    local -a args=(run --rm)
    while IFS= read -r line; do args+=(-e "$line"); done < <(pr_env)
    for entry in "${PR_SECRETS[@]}"; do
        IFS=: read -r secret var _ <<< "$entry"
        args+=(--secret "${secret},type=env,target=${var}")
    done
    printf '%s\n' "${args[@]}"
}

pr_deploy_cmd() {   # pr_deploy_cmd <command...> - python -m protocol.deploy, once
    local -a args; mapfile -t args < <(pr_run_args)
    podman "${args[@]}" "$PR_IMAGE_API" "$@"
}

# -----------------------------------------------------------------------------
# Secrets - asked once, kept by podman
# -----------------------------------------------------------------------------
pr_secret_exists() { podman secret inspect "$1" &>/dev/null; }

pr_missing_secrets() {
    local entry secret
    for entry in "${PR_SECRETS[@]}"; do
        secret="${entry%%:*}"
        pr_secret_exists "$secret" || echo "$secret"
    done
}

# Asks for one secret and stores it. Over stdin, so it is on no command line.
pr_secret_set() {
    local entry="$1" secret var vault value
    IFS=: read -r secret var vault <<< "$entry"
    value=$(gum input --password --header "${vault} (from kuat: ansible-vault view group_vars/all/vault.yml):") || return 1
    [[ -n "$value" ]] || { warn "Empty - ${secret} not set."; return 1; }
    local -a replace=()
    # podman 4.9 fails --replace on a secret that does not exist yet.
    pr_secret_exists "$secret" && replace=(--replace)
    printf '%s' "$value" | podman secret create "${replace[@]}" "$secret" - >/dev/null \
        || { warn "Could not store ${secret}."; return 1; }
    success "${secret} stored (reaches the containers as ${var})"
}

pr_secrets_ensure() {
    local entry secret missing=0
    for entry in "${PR_SECRETS[@]}"; do
        secret="${entry%%:*}"
        pr_secret_exists "$secret" && continue
        pr_secret_set "$entry" || missing=1
    done
    return "$missing"
}

pr_secrets_menu() {
    local choice entry
    header "protocol - secrets"
    for entry in "${PR_SECRETS[@]}"; do
        IFS=: read -r secret var vault <<< "$entry"
        if pr_secret_exists "$secret"; then info "${secret}: set (${var}, vault: ${vault})"
        else warn "${secret}: not set (vault: ${vault})"; fi
    done
    # shellcheck disable=SC2046
    choice=$(gum choose $(printf '%s\n' "${PR_SECRETS[@]}" | cut -d: -f1) "← back" --header "Set or replace which?") || return 0
    [[ "$choice" == "← back" || -z "$choice" ]] && return 0
    for entry in "${PR_SECRETS[@]}"; do
        [[ "${entry%%:*}" == "$choice" ]] && { pr_secret_set "$entry" || true; }
    done
    info "A replaced secret reaches the containers when they restart (install, or systemctl --user restart protocol-*)."
}

# -----------------------------------------------------------------------------
# Images - built from a clean clone of each repository, never a working copy
# -----------------------------------------------------------------------------
# A dev checkout may hold uncommitted work; what runs must be a commit. The
# commit is stamped on each image, and `status` shows it.
pr_src_sync() {   # pr_src_sync <dir> <repo> -> prints the commit
    local dir="$1" repo="$2"
    if [[ ! -d "${dir}/.git" ]]; then
        mkdir -p "$(dirname "$dir")"
        git clone --quiet "$repo" "$dir" >&2 || return 1
    fi
    git -C "$dir" fetch --quiet origin "$PR_REF" >&2 || return 1
    git -C "$dir" checkout --quiet --detach FETCH_HEAD >&2 || return 1
    git -C "$dir" rev-parse --short HEAD
}

pr_image_revision() {
    podman image inspect "$1" --format "{{ index .Labels \"${PR_REVISION_LABEL}\" }}" 2>/dev/null || true
}

pr_build() {   # pr_build <title> <podman build args...>
    local title="$1"; shift
    gum spin --spinner dot --title "${title}..." -- podman build --quiet "$@" >/dev/null \
        || { warn "${title} failed - run it again; podman keeps the layers already built."; return 1; }
    success "${title}"
}

pr_build_images() {
    header "Build the images (${PR_REF})"
    local droid proto
    droid="$(pr_src_sync "${SRC_DIR}/protocol-droid" "$PR_DROID_REPO")" || { warn "Could not fetch protocol-droid."; return 1; }
    proto="$(pr_src_sync "${SRC_DIR}/protocol" "$PR_PROTOCOL_REPO")" || { warn "Could not fetch protocol."; return 1; }
    info "protocol-droid ${droid}, protocol ${proto}"
    info "The first marker build compiles llama.cpp and installs torch: expect a long wait, and 6.8 GB."
    pr_build "marker engine (protocol-droid ${droid})" --label "${PR_REVISION_LABEL}=${droid}" \
        -t "$PR_ENGINE_MARKER" "${SRC_DIR}/protocol-droid" || return 1
    pr_build "markitdown engine (protocol-droid ${droid})" --label "${PR_REVISION_LABEL}=${droid}" \
        -f "${SRC_DIR}/protocol-droid/Dockerfile.markitdown" -t "$PR_ENGINE_MARKITDOWN" "${SRC_DIR}/protocol-droid" || return 1
    pr_build "protocol (${proto})" --label "${PR_REVISION_LABEL}=${proto}" \
        -t "$PR_IMAGE_API" "${SRC_DIR}/protocol" || return 1
    pr_build "protocol on marker" --label "${PR_REVISION_LABEL}=${proto}" \
        --build-arg "BASE=${PR_ENGINE_MARKER}" -t "$PR_IMAGE_MARKER" "${SRC_DIR}/protocol" || return 1
    pr_build "protocol on markitdown" --label "${PR_REVISION_LABEL}=${proto}" \
        --build-arg "BASE=${PR_ENGINE_MARKITDOWN}" -t "$PR_IMAGE_MARKITDOWN" "${SRC_DIR}/protocol" || return 1
}

pr_images_present() {
    local image
    for image in "$PR_IMAGE_API" "$PR_IMAGE_MARKER" "$PR_IMAGE_MARKITDOWN"; do
        podman image exists "$image" || return 1
    done
}

# -----------------------------------------------------------------------------
# Firewall - so the LAN (Padme, n8n) can reach the API
# -----------------------------------------------------------------------------
_fw_tool() {
    if command -v firewall-cmd &>/dev/null && systemctl is-active --quiet firewalld 2>/dev/null; then
        echo firewalld
    elif command -v ufw &>/dev/null; then
        echo ufw
    fi
}

# open | closed | unknown | none. firewalld's --query-port prints yes/no and
# exits 1 on "no", so the answer is the output, not the exit status. It also
# answers "no" for a port inside an open range (corelia opens 1025-65535), so
# ranges are read too.
pr_firewall_state() {
    local port="$1" tool out ranges r lo hi
    tool="$(_fw_tool)"
    case "$tool" in
        firewalld)
            out=$(firewall-cmd --query-port="${port}/tcp" 2>/dev/null || true)
            [[ "$out" == yes || "$out" == no ]] || out=$(sudo -n firewall-cmd --query-port="${port}/tcp" 2>/dev/null || true)
            if [[ "$out" == no ]]; then
                ranges=$(firewall-cmd --list-ports 2>/dev/null || true)
                for r in $ranges; do
                    [[ "$r" =~ ^([0-9]+)-([0-9]+)/tcp$ ]] || continue
                    lo="${BASH_REMATCH[1]}"; hi="${BASH_REMATCH[2]}"
                    (( port >= lo && port <= hi )) && { out=yes; break; }
                done
            fi
            case "$out" in yes) echo open ;; no) echo closed ;; *) echo unknown ;; esac ;;
        ufw)
            if out=$(sudo -n ufw status 2>/dev/null); then
                if grep -q "Status: inactive" <<< "$out"; then echo none
                elif grep -qE "^${port}(/tcp)?[[:space:]]+ALLOW" <<< "$out"; then echo open
                else echo closed; fi
            else
                echo unknown
            fi ;;
        *) echo none ;;
    esac
}

pr_firewall_offer() {
    local port="$1" tool state
    tool="$(_fw_tool)"; state="$(pr_firewall_state "$port")"
    case "$state" in
        open) info "Firewall (${tool}): ${port}/tcp is open."; return 0 ;;
        none) info "No active firewall (firewalld or ufw); nothing to open."; return 0 ;;
    esac
    gum confirm "Open ${port}/tcp in ${tool} so the LAN can reach the API? (needs sudo)" || {
        warn "Port left as it is - the LAN may not reach the API."; return 0; }
    case "$tool" in
        firewalld)
            _require_sudo_or_instruct "Opening ${port}/tcp" \
                "sudo firewall-cmd --permanent --add-port=${port}/tcp && sudo firewall-cmd --reload"
            sudo firewall-cmd --permanent --add-port="${port}/tcp" && sudo firewall-cmd --reload \
                && success "Opened ${port}/tcp (permanent)." || warn "Could not open ${port}/tcp." ;;
        ufw)
            _require_sudo_or_instruct "Opening ${port}/tcp" "sudo ufw allow ${port}/tcp"
            sudo ufw allow "${port}/tcp" && success "Opened ${port}/tcp." || warn "Could not open ${port}/tcp." ;;
    esac
}

# -----------------------------------------------------------------------------
# Install, status, test, logs, uninstall
# -----------------------------------------------------------------------------
_linger_on() { [[ "$(loginctl show-user "$(id -un)" -p Linger --value 2>/dev/null)" == yes ]]; }

pr_healthy() { curl -fsS --max-time 3 "$1/healthz" &>/dev/null; }

# Waits until a worker has warmed its engine and is taking jobs. The first
# marker start downloads its models (1.8 GB) into the volume.
pr_wait_listening() {
    local unit="$1" since="$2" limit="$3"
    gum spin --spinner dot --title "Waiting for ${unit} (warm-up; the first one downloads the models)..." -- \
        bash -c "for i in \$(seq 1 ${limit}); do journalctl --user -u '${unit}.service' --since '@${since}' --no-pager 2>/dev/null | grep -q 'Listening on' && exit 0; sleep 5; done; exit 1"
}

pr_show_settings() {
    gum style --border rounded --padding "0 2" \
        "API:        port ${PR_PORT}" \
        "Registry:   MariaDB ${PR_MARIADB_HOST}:${PR_MARIADB_PORT}, database protocol" \
        "Queues:     ${PR_REDIS_URL}" \
        "Stores:     ${PR_S3_ENDPOINT}  ${PR_S3_SOURCES_BUCKET}, ${PR_S3_OUTPUTS_BUCKET}" \
        "Qdrant:     ${PR_QDRANT_URL}  collections: ${PR_QDRANT_COLLECTIONS:-none yet (removal deletes no vectors)}" \
        "Models:     volume ${PR_MODELS_VOLUME}" \
        "Built from: ${PR_REF} of ${PR_PROTOCOL_REPO##*/} and ${PR_DROID_REPO##*/}" \
        "Settings:   ${CONFIG_FILE}"
}

pr_install() {
    header "Install protocol - Podman (systemd user services)"
    pr_show_settings
    gum confirm "Install with these settings? (change them under 'config')" || return 0
    pr_secrets_ensure || { warn "Every secret is needed - set the rest under 'secrets', then install again."; return 0; }
    if ! pr_images_present; then
        pr_build_images || return 0
    elif gum confirm "Rebuild the images from ${PR_REF} first?" --default=false; then
        pr_build_images || return 0
    fi
    mkdir -p "$QUADLET_DIR"
    local unit start
    for unit in "${PR_UNITS[@]}"; do
        render_quadlet "$unit" > "${QUADLET_DIR}/${unit}.container"
    done
    info "Wrote ${#PR_UNITS[@]} units to ${QUADLET_DIR}"
    systemctl --user daemon-reload
    if ! pr_deploy_cmd check; then
        warn "A backend is unreachable (above). Fix it, then install again - nothing was started."
        return 0
    fi
    start="$(date +%s)"
    # The light worker first, alone: two workers downloading the same model
    # into one cache at once collide. The heavy one starts once it is up.
    systemctl --user restart protocol-api.service protocol-maintenance.service \
        protocol-markitdown.service protocol-marker-light.service || error_exit "Start failed - see 'logs'."
    if pr_wait_listening protocol-marker-light "$start" 240; then
        success "marker's light lane is taking jobs"
    else
        warn "marker's light worker is not taking jobs yet - see 'logs'. Starting the heavy one anyway."
    fi
    systemctl --user restart protocol-marker-heavy.service || warn "The heavy worker did not start - see 'logs'."
    if ! _linger_on; then
        if gum confirm "Enable lingering so protocol starts at boot without a login? (recommended)"; then
            loginctl enable-linger "$(id -un)" || warn "Could not enable linger (run: sudo loginctl enable-linger $(id -un))"
        else
            warn "Without lingering, protocol starts only once you log in."
        fi
    fi
    cfg_save
    pr_healthy "$(pr_local_url)" && success "The API is up at $(pr_local_url)" || warn "The API is not answering yet - see 'logs'."
    pr_firewall_offer "$PR_PORT"
    local lan; lan="$(pr_lan_address)"
    [[ -n "$lan" ]] && info "From the LAN: http://${lan}:${PR_PORT}  (POST /documents)"
    return 0
}

pr_status() {
    header "protocol - status"
    local unit image rev
    for unit in "${PR_UNITS[@]}"; do
        if [[ -f "${QUADLET_DIR}/${unit}.container" ]]; then
            info "${unit}: $(systemctl --user is-active "${unit}.service" 2>/dev/null || true)"
        else
            warn "${unit}: not installed"
        fi
    done
    for image in "$PR_IMAGE_API" "$PR_IMAGE_MARKER" "$PR_IMAGE_MARKITDOWN"; do
        rev="$(pr_image_revision "$image")"
        if podman image exists "$image"; then info "${image}: built from ${rev:-an unknown commit}"
        else warn "${image}: not built"; fi
    done
    if pr_healthy "$(pr_local_url)"; then success "API: ok ($(pr_local_url))"; else warn "API: not answering at $(pr_local_url)"; fi
    if _linger_on; then info "Linger: on - starts at boot"; else warn "Linger: off - starts only after a login"; fi
    case "$(pr_firewall_state "$PR_PORT")" in
        open)    info "Firewall ($(_fw_tool)): ${PR_PORT}/tcp open" ;;
        closed)  warn "Firewall ($(_fw_tool)): ${PR_PORT}/tcp closed - the LAN cannot reach the API" ;;
        unknown) warn "Firewall ($(_fw_tool)): state of ${PR_PORT}/tcp unknown (reading it needs sudo)" ;;
        none)    info "Firewall: none active" ;;
    esac
    local missing; missing="$(pr_missing_secrets)"
    [[ -n "$missing" ]] && warn "Secrets not set: $(tr '\n' ' ' <<< "$missing")(see 'secrets')"
    if [[ -z "$missing" ]] && podman image exists "$PR_IMAGE_API"; then
        echo; pr_deploy_cmd check 2>/dev/null || true
        echo; pr_deploy_cmd queues 2>/dev/null || true
    fi
    return 0
}

# A small CSV through the real service and back out: submit, wait for
# markitdown, read the result's state, then remove it so the test leaves only
# a tombstone in the registry.
pr_test() {
    header "protocol - test ($(pr_local_url))"
    local url tmp reply id state _
    url="$(pr_local_url)"
    pr_healthy "$url" || { warn "Not reachable at ${url}."; return 0; }
    tmp="$(mktemp -t protocol-test.XXXXXX)"
    printf 'probe,host,at\nprotocol.sh,%s,%s\n' "$(hostname -s 2>/dev/null || echo host)" "$(date -u +%FT%TZ)" > "$tmp"
    if ! reply=$(curl -fsS --max-time 30 -F "file=@${tmp};filename=protocol-test.csv" -F "submitted_by=protocol.sh test" "${url}/documents"); then
        rm -f "$tmp"; warn "Submission failed."; return 0
    fi
    rm -f "$tmp"
    id=$(sed -n 's/.*"document_id" *: *"\([^"]*\)".*/\1/p' <<< "$reply")
    [[ -n "$id" ]] || { warn "No document ID in the reply: ${reply}"; return 0; }
    success "Submitted: ${id}"
    state=""
    for _ in $(seq 1 60); do
        state=$(curl -fsS --max-time 5 "${url}/documents/${id}" 2>/dev/null \
            | sed -n 's/^{"document":{[^}]*"state":"\([a-z_]*\)".*/\1/p')
        [[ "$state" == validation_pending || "$state" == conversion_failed ]] && break
        sleep 1
    done
    case "$state" in
        validation_pending) success "Converted by markitdown (state: validation_pending)" ;;
        conversion_failed)  warn "The conversion failed - see 'logs' (protocol-markitdown)." ;;
        *)                  warn "Not converted after 60s (state: ${state:-unknown}) - is protocol-markitdown running?" ;;
    esac
    curl -fsS --max-time 10 -X DELETE "${url}/documents/${id}" -o /dev/null \
        && info "Removal queued, so the test leaves only a tombstone." || warn "Could not queue its removal."
}

pr_logs() {
    local unit
    unit=$(gum choose "${PR_UNITS[@]}" "← back" --header "Logs of which?") || return 0
    [[ "$unit" == "← back" || -z "$unit" ]] && return 0
    journalctl --user -u "${unit}.service" -n 200 --no-pager || true
}

pr_uninstall() {
    header "Uninstall protocol - Podman"
    local unit any=0
    for unit in "${PR_UNITS[@]}"; do [[ -f "${QUADLET_DIR}/${unit}.container" ]] && any=1; done
    (( any )) || { warn "Not installed."; return 0; }
    gum confirm "Stop protocol and remove its units? (the registry, stores and queues on meksha and the NAS are not touched)" || return 0
    for unit in "${PR_UNITS[@]}"; do
        systemctl --user stop "${unit}.service" 2>/dev/null || true
        rm -f "${QUADLET_DIR}/${unit}.container"
    done
    systemctl --user daemon-reload
    success "Removed the units."
    if gum confirm "Also delete the model cache (volume ${PR_MODELS_VOLUME})? marker would download its models again."; then
        podman volume rm "$PR_MODELS_VOLUME" >/dev/null && success "Deleted ${PR_MODELS_VOLUME}." || warn "Could not delete ${PR_MODELS_VOLUME}."
    else
        info "Kept the model cache (${PR_MODELS_VOLUME})."
    fi
    if gum confirm "Also delete the stored secrets? They would be asked for again."; then
        local entry
        for entry in "${PR_SECRETS[@]}"; do podman secret rm "${entry%%:*}" &>/dev/null || true; done
        success "Deleted the secrets."
    else
        info "Kept the secrets."
    fi
}

# Returns 0 when something changed (the caller offers to re-apply).
pr_config() {
    local field value before
    before="$(declare -p "${PR_SETTINGS[@]}")"
    while true; do
        header "protocol - settings"
        pr_show_settings
        field=$(gum choose port "MariaDB host" "Redis URL" "S3 endpoint" "buckets" "Qdrant URL" \
            "Qdrant collections" "models volume" "branch to build" "reset to defaults" "done" --header "Change:") || break
        case "$field" in
            port) value=$(gum input --value "$PR_PORT" --header "The API's port on this host:") || continue
                  [[ "$value" =~ ^[0-9]+$ ]] && (( value > 0 && value < 65536 )) && PR_PORT="$value" || warn "Not a port: ${value}" ;;
            "MariaDB host") value=$(gum input --value "$PR_MARIADB_HOST" --header "MariaDB host:") || continue
                  [[ -n "$value" ]] && PR_MARIADB_HOST="$value" ;;
            "Redis URL") value=$(gum input --value "$PR_REDIS_URL" --header "Redis URL (no password in it - that is a secret):") || continue
                  [[ "$value" == redis://* && "$value" != *@* ]] && PR_REDIS_URL="$value" || warn "A redis:// URL without credentials, please." ;;
            "S3 endpoint") value=$(gum input --value "$PR_S3_ENDPOINT" --header "Garage S3 endpoint:") || continue
                  [[ -n "$value" ]] && PR_S3_ENDPOINT="$value" ;;
            buckets) value=$(gum input --value "$PR_S3_SOURCES_BUCKET" --header "Sources bucket:") || continue
                  [[ -n "$value" ]] && PR_S3_SOURCES_BUCKET="$value"
                  value=$(gum input --value "$PR_S3_OUTPUTS_BUCKET" --header "Outputs bucket:") || continue
                  [[ -n "$value" ]] && PR_S3_OUTPUTS_BUCKET="$value" ;;
            "Qdrant URL") value=$(gum input --value "$PR_QDRANT_URL" --header "Qdrant URL:") || continue
                  [[ -n "$value" ]] && PR_QDRANT_URL="$value" ;;
            "Qdrant collections") value=$(gum input --value "$PR_QDRANT_COLLECTIONS" \
                    --header "The collections ingestion writes, comma-separated (removal deletes points only there):") || continue
                  PR_QDRANT_COLLECTIONS="$value" ;;
            "models volume") value=$(gum input --value "$PR_MODELS_VOLUME" --header "Named volume for marker's models:") || continue
                  [[ -n "$value" ]] && PR_MODELS_VOLUME="$value" ;;
            "branch to build") value=$(gum input --value "$PR_REF" --header "Branch or tag of protocol and protocol-droid to build:") || continue
                  [[ -n "$value" ]] && PR_REF="$value" ;;
            "reset to defaults") gum confirm "Reset every setting to the script's defaults?" && cfg_defaults ;;
            *) break ;;
        esac
    done
    [[ "$before" == "$(declare -p "${PR_SETTINGS[@]}")" ]] && return 1
    cfg_save
    success "Saved to ${CONFIG_FILE}"
    return 0
}

# -----------------------------------------------------------------------------
# Dependencies and the menu
# -----------------------------------------------------------------------------
check_dependencies() {
    [[ "$(uname -s)" == Linux ]] || error_exit "protocol runs as systemd user services: Linux only."
    command -v curl &>/dev/null || _ensure_pkg curl curl
    command -v git &>/dev/null || _ensure_pkg git git
    _ensure_pkg podman podman || error_exit "podman was layered and needs a reboot - re-run this after it."
    local version major minor
    version="$(podman version --format '{{.Client.Version}}' 2>/dev/null || podman --version | awk '{print $NF}')"
    major="${version%%.*}"; minor="${version#*.}"; minor="${minor%%.*}"
    if [[ "$major" =~ ^[0-9]+$ && "$minor" =~ ^[0-9]+$ ]] && (( major < 4 || (major == 4 && minor < 5) )); then
        # SecurityLabelLevel= arrived in Quadlet with 4.5.
        error_exit "podman ${version} is too old for these units (needs 4.5 or later)."
    fi
}

main() {
    gum style --foreground "$PURPLE" --border-foreground "$PURPLE" --border double \
        --align center --width 60 --margin "1 2" --padding "1 4" \
        "protocol" "one conversion API · marker · markitdown" "Podman"
    cfg_load
    check_dependencies
    local action
    while true; do
        header "protocol - $(hostname -s 2>/dev/null || echo this host)"
        action=$(gum choose install status test secrets build logs config uninstall "← back" --header "Action:") || break
        case "$action" in
            install)   pr_install ;;
            status)    pr_status ;;
            test)      pr_test ;;
            secrets)   pr_secrets_menu ;;
            build)     pr_build_images || true ;;
            logs)      pr_logs ;;
            config)    if pr_config && gum confirm "Re-apply now (install with the new settings)?"; then pr_install; fi ;;
            uninstall) pr_uninstall ;;
            *) break ;;
        esac
    done
    gum style --faint "Bye."
}

# Sourced by the tests for its renderers; run otherwise.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
