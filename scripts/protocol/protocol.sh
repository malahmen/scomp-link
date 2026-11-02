#!/usr/bin/env bash
# description: protocol - the conversion API (marker · markitdown · transcription) on corelia: build, install, status, test (Podman)
# export-setup: curl git
# -----------------------------------------------------------------------------
# protocol.sh
# Installs and manages protocol (https://github.com/malahmen/protocol), the one
# conversion API every converter sits behind: an HTTP API that answers 202 and
# an ID at once, and a worker per lane that does the converting - marker's
# light and heavy lanes, markitdown, transcription (through Speaches on this
# host), and the removals and prunes.
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
# protocol's API is a LAN service - Padme and n8n on other machines submit to
# it - so its port is published on every interface unless SCOMP_BIND_ADDR
# names one (Kamino 235). Deliberate, and install and status say so.
SVC_BIND_DEFAULT=0.0.0.0
# shellcheck source=../_common/portforward.sh
source "${COMMON_DIR}/portforward.sh"
# shellcheck source=../_common/conf.sh
source "${COMMON_DIR}/conf.sh"   # conf_load: the settings file is parsed, never sourced

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
PR_UNITS=(protocol-api protocol-maintenance protocol-markitdown protocol-marker-light protocol-marker-heavy
    protocol-transcription)

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
    PR_SPEACHES_URL PR_MODELS_VOLUME PR_PROTOCOL_REPO PR_DROID_REPO PR_REF)

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
    # Speaches on this host (speaches.sh), for audio. host.containers.internal,
    # not the LAN address: from a rootless container on corelia,
    # 192.168.3.46:8000 is refused and this answers. Empty = audio is refused
    # at submit rather than queued where nothing transcribes it (Kamino 89).
    PR_SPEACHES_URL="http://host.containers.internal:8000"
    PR_MODELS_VOLUME="protocol-models"
    PR_PROTOCOL_REPO="https://github.com/malahmen/protocol.git"
    PR_DROID_REPO="https://github.com/malahmen/protocol-droid.git"
    PR_REF="main"               # built for both repositories
}

# Every key the settings file holds: read by cfg_load, written by cfg_save,
# the same list both ways. PR_BIND_ADDR is where install published the API
# (SCOMP_BIND_ADDR, or every interface): saved by install for status and the
# URLs, not a setting 'config' edits.
PR_KEYS=("${PR_SETTINGS[@]}" PR_BIND_ADDR)

# _pr_port VALUE - a TCP port, 1-65535, written without leading zeros.
_pr_port() { [[ "$1" =~ ^[1-9][0-9]{0,4}$ ]] && (( $1 < 65536 )); }

# _pr_host VALUE - an IPv4 address or a DNS host name (RFC 1123 labels).
# Something made only of digits and dots has to be a real IPv4 address.
_pr_host() {
    local v="$1" label='[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?'
    [[ "$v" =~ ^[0-9.]+$ ]] && { _svc_ipv4 "$v"; return; }
    (( ${#v} <= 253 )) && [[ "$v" =~ ^${label}(\.${label})*$ ]]
}

# _pr_url SCHEMES VALUE [PATH-ERE] - SCHEME://host[:port][path]: SCHEMES is an
# ERE alternation; no credentials (they are podman secrets), no query, and a
# path of plain characters only (PATH-ERE narrows it).
_pr_url() {
    local schemes="$1" v="$2" path_re="${3:-(/[A-Za-z0-9._~/-]*)?}"
    local re="^(${schemes})://([A-Za-z0-9.-]+)(:([0-9]{1,5}))?(.*)$"
    [[ "$v" =~ $re ]] || return 1
    local host="${BASH_REMATCH[2]}" port="${BASH_REMATCH[4]}" path="${BASH_REMATCH[5]}"
    _pr_host "$host" || return 1
    [[ -z "$port" ]] || _pr_port "$port" || return 1
    [[ "$path" =~ ^${path_re}$ ]]
}

# _pr_bucket VALUE - an S3 bucket name, by the S3 naming rules (Garage keeps
# them): 3-63 lower-case letters, digits, dots and hyphens, a letter or digit
# at each end, no "..", not an IPv4 address, none of the reserved prefixes or
# suffixes.
_pr_bucket() {
    local v="$1"
    [[ ${#v} -ge 3 && ${#v} -le 63 && "$v" =~ ^[a-z0-9][a-z0-9.-]*[a-z0-9]$ ]] || return 1
    [[ "$v" != *..* ]] || return 1
    [[ "$v" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && return 1
    case "$v" in
        xn--*|sthree-*|amzn-s3-demo-*|*-s3alias|*--ol-s3|*.mrap|*--x-s3|*--table-s3) return 1 ;;
    esac
    return 0
}

# _pr_repo VALUE - a repository git can clone and nothing it runs: an
# http(s)://, git:// or ssh:// URL (a user only for ssh - a token in an https
# URL would sit in this file), scp-like user@host:path, or an absolute path to
# a local clone. Never a transport like ext:: (it runs a command).
_pr_repo() {
    local v="$1" path='[A-Za-z0-9._~/+-]'
    if [[ "$v" =~ ^(https?|git)://[^@]*$ ]]; then _pr_url 'https?|git' "$v" "/${path}*"
    elif [[ "$v" =~ ^ssh://([A-Za-z0-9._-]+@)?(.*)$ ]]; then _pr_url ssh "ssh://${BASH_REMATCH[2]}" "/${path}*"
    elif [[ "$v" =~ ^[A-Za-z0-9._-]+@([A-Za-z0-9.-]+):(${path}+)$ ]]; then _pr_host "${BASH_REMATCH[1]}"
    else [[ "$v" =~ ^/${path}+$ ]]
    fi
}

# _pr_ref_name VALUE - a branch or tag (or commit) name git accepts
# (check-ref-format, short): not starting with - or ., no "..", "//", "@{",
# nor a trailing / . or .lock.
_pr_ref_name() {
    local v="$1"
    [[ ${#v} -le 255 && "$v" =~ ^[A-Za-z0-9_][A-Za-z0-9._/+-]*$ ]] || return 1
    [[ "$v" != *..* && "$v" != *//* && "$v" != */ && "$v" != *. && "$v" != *.lock && "$v" != */.* ]]
}

# pr_valid <KEY> <value> - the value is one the setting may hold. Every
# setting becomes a unit's Environment= line, a published port, a podman
# volume or a git argument as it is, so each is checked the same way whether
# it was typed under 'config' or read from the settings file (Kamino 236, as
# speaches' sp_valid in 235).
pr_valid() {
    local v="$2"
    case "$1" in
        PR_PORT|PR_MARIADB_PORT) _pr_port "$v" ;;
        PR_MARIADB_HOST) _pr_host "$v" ;;
        # redis-py's form: an optional database number as the path.
        PR_REDIS_URL)    _pr_url 'rediss?' "$v" '(/[0-9]{1,2})?' ;;
        PR_S3_ENDPOINT|PR_QDRANT_URL) _pr_url 'https?' "$v" ;;
        # Empty = audio is refused at submit (Kamino 89).
        PR_SPEACHES_URL) [[ -z "$v" ]] || _pr_url 'https?' "$v" ;;
        PR_S3_SOURCES_BUCKET|PR_S3_OUTPUTS_BUCKET) _pr_bucket "$v" ;;
        # Empty until ingestion names them; else names, comma-separated.
        PR_QDRANT_COLLECTIONS)
            [[ -z "$v" || "$v" =~ ^[A-Za-z0-9_-][A-Za-z0-9._-]{0,254}(,[A-Za-z0-9_-][A-Za-z0-9._-]{0,254})*$ ]] ;;
        # A named volume: a path there is a bind mount of this host's files.
        PR_MODELS_VOLUME) [[ "$v" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]+$ ]] ;;
        PR_PROTOCOL_REPO|PR_DROID_REPO) _pr_repo "$v" ;;
        PR_REF)          _pr_ref_name "$v" ;;
        PR_BIND_ADDR)    [[ -z "$v" ]] || _svc_ipv4 "$v" ;;
        *) return 1 ;;
    esac
}

# pr_valid_hint <KEY> - what pr_valid wants, for the warnings.
pr_valid_hint() {
    case "$1" in
        PR_PORT|PR_MARIADB_PORT) echo "a port (1-65535)" ;;
        PR_MARIADB_HOST) echo "a host name or IPv4 address" ;;
        PR_REDIS_URL)    echo "a redis:// URL without credentials (host[:port][/db])" ;;
        PR_S3_ENDPOINT|PR_QDRANT_URL) echo "an http(s):// URL without credentials" ;;
        PR_SPEACHES_URL) echo "an http(s):// URL without credentials, or empty" ;;
        PR_S3_SOURCES_BUCKET|PR_S3_OUTPUTS_BUCKET) echo "an S3 bucket name (3-63 of a-z 0-9 . -)" ;;
        PR_QDRANT_COLLECTIONS) echo "collection names, comma-separated, or empty" ;;
        PR_MODELS_VOLUME) echo "a volume name (not a path)" ;;
        PR_PROTOCOL_REPO|PR_DROID_REPO) echo "a git URL (https, ssh, git, user@host:path) or an absolute path" ;;
        PR_REF)          echo "a branch or tag name (not starting with -)" ;;
        PR_BIND_ADDR)    echo "an IPv4 address" ;;
        *)               echo "a known setting" ;;
    esac
}

# The settings file is parsed (conf.sh), never sourced: a $(...), a backtick
# or a bare command line in it ran as code (Kamino 236, as speaches in 235).
# A value that is not one the setting may hold keeps the default.
cfg_load() {
    cfg_defaults
    PR_BIND_ADDR=""
    [[ -f "$CONFIG_FILE" ]] || return 0
    local -A dflt=()
    local key
    for key in "${PR_KEYS[@]}"; do dflt[$key]="${!key}"; done
    conf_load "$CONFIG_FILE" "${PR_KEYS[@]}"
    for key in "${PR_KEYS[@]}"; do
        pr_valid "$key" "${!key}" && continue
        warn "Ignoring ${key}='${!key}' in ${CONFIG_FILE}: not $(pr_valid_hint "$key"). Using '${dflt[$key]}' (change it under 'config')."
        printf -v "$key" '%s' "${dflt[$key]}"
    done
}

# KEY=%q lines, the form conf_load reads back (and every version of this
# script wrote).
cfg_save() {
    mkdir -p "$CONFIG_DIR"
    {
        printf '# protocol.sh settings - see the defaults in protocol.sh\n'
        local key
        for key in "${PR_KEYS[@]}"; do printf '%s=%q\n' "$key" "${!key:-}"; done
    } > "$CONFIG_FILE"
}

# _pr_plain VALUE - usable as it is in a unit's Environment= line: no
# whitespace (Quadlet splits the line there), no % (a systemd specifier), no
# quote or backslash. Checked as settings come in, and again before anything
# is written, for a protocol.conf edited by hand (Kamino item 102).
_pr_plain() { [[ -n "$1" && "$1" != *[[:space:]%\"\'\\]* ]]; }

# pr_env_check - every unit setting is usable as it is, checked in the
# caller's shell. pr_env's own check runs where it is read, inside
# `< <(pr_env)`: its error_exit ended only that process substitution, so a
# hand-edited bad setting printed the error and install went on writing every
# unit (the bad line and those after it missing) and ran daemon-reload
# (Kamino 196, item 102's regression). Callers stop on this first.
pr_env_check() {
    local line
    local -a lines
    mapfile -t lines < <(_pr_env_lines)
    for line in "${lines[@]}"; do
        if ! _pr_plain "${line#*=}"; then
            gum style --foreground "${RED:-196}" "[error] Setting ${line%%=*} ('${line#*=}') would break the units: no spaces, %, quotes or backslashes. Fix it under 'config' or in ${CONFIG_FILE}." >&2
            return 1
        fi
    done
    return 0
}

# The containers' settings that are not secret, one NAME=value per line.
pr_env() {
    local line
    while IFS= read -r line; do
        _pr_plain "${line#*=}" \
            || error_exit "Setting ${line%%=*} ('${line#*=}') would break the units: no spaces, %, quotes or backslashes. Fix it under 'config' or in ${CONFIG_FILE}."
        printf '%s\n' "$line"
    done < <(_pr_env_lines)
}

_pr_env_lines() {
    printf '%s\n' \
        "MARIADB_HOST=${PR_MARIADB_HOST}" "MARIADB_PORT=${PR_MARIADB_PORT}" \
        "REDIS_URL=${PR_REDIS_URL}" \
        "S3_ENDPOINT=${PR_S3_ENDPOINT}" \
        "S3_SOURCES_BUCKET=${PR_S3_SOURCES_BUCKET}" "S3_OUTPUTS_BUCKET=${PR_S3_OUTPUTS_BUCKET}" \
        "QDRANT_URL=${PR_QDRANT_URL}"
    [[ -n "$PR_QDRANT_COLLECTIONS" ]] && echo "QDRANT_COLLECTIONS=${PR_QDRANT_COLLECTIONS}"
    # The API reads it to accept audio, the transcription worker to reach it.
    [[ -n "$PR_SPEACHES_URL" ]] && echo "SPEACHES_URL=${PR_SPEACHES_URL}"
    return 0
}

# The address the API is published on: what install used (saved), or this
# run's. pr_local_url reaches it from this machine; pr_lan_url is where other
# machines do, or nothing when it is on loopback only.
pr_bind_addr() { printf '%s' "${PR_BIND_ADDR:-$SVC_BIND_ADDR}"; }
pr_local_url() { echo "http://$(svc_host "$(pr_bind_addr)"):${PR_PORT}"; }
pr_lan_url() {
    local a; a="$(pr_bind_addr)"
    [[ "$a" == 127.* ]] && return 0
    [[ "$a" == 0.0.0.0 ]] && a="$(pr_lan_address)"
    [[ -n "$a" ]] && printf 'http://%s:%s' "$a" "$PR_PORT"
    return 0
}

pr_lan_address() { { hostname -I 2>/dev/null || true; } | awk '{print $1}'; }

# unit -> "image|command"
pr_unit_spec() {
    case "$1" in
        protocol-api)          echo "${PR_IMAGE_API}|api" ;;
        protocol-maintenance)  echo "${PR_IMAGE_API}|worker maintenance" ;;
        protocol-markitdown)   echo "${PR_IMAGE_MARKITDOWN}|worker markitdown" ;;
        protocol-marker-light) echo "${PR_IMAGE_MARKER}|worker marker-light" ;;
        protocol-marker-heavy) echo "${PR_IMAGE_MARKER}|worker marker-heavy" ;;
        # Speaches does the work over HTTP: no engine to import, so the API's image.
        protocol-transcription) echo "${PR_IMAGE_API}|worker transcription" ;;
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
    [[ "$unit" == protocol-api ]] && echo "PublishPort=$(svc_publish "$PR_PORT" "$PR_API_CONTAINER_PORT")"
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
        git clone --quiet -- "$repo" "$dir" >&2 || return 1
    fi
    # The configured repository, not whatever the cached clone was made from:
    # a changed URL was otherwise ignored and the old repository built.
    git -C "$dir" remote set-url origin "$repo" >&2 || return 1
    # After --, so a ref (or a hand-edited PR_REF) that starts with - is a
    # ref git cannot find, never an option (--upload-pack runs a command).
    pr_valid PR_REF "$PR_REF" || { warn "Not a branch or tag: '${PR_REF}' (set it under 'config')."; return 1; }
    git -C "$dir" fetch --quiet -- origin "$PR_REF" >&2 || return 1
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
        "Speaches:   ${PR_SPEACHES_URL:-not set (audio is refused)}" \
        "Models:     volume ${PR_MODELS_VOLUME}" \
        "Built from: ${PR_REF} of ${PR_PROTOCOL_REPO##*/} and ${PR_DROID_REPO##*/}" \
        "Settings:   ${CONFIG_FILE}"
}

pr_install() {
    header "Install protocol - Podman (systemd user services)"
    pr_show_settings
    gum confirm "Install with these settings? (change them under 'config')" || return 0
    pr_secrets_ensure || { warn "Every secret is needed - set the rest under 'secrets', then install again."; return 0; }
    # Before the images, the check and the units: nothing is built, run or
    # written with a setting that would break a unit.
    pr_env_check || { warn "Nothing was built, written or started."; return 0; }
    if ! pr_images_present; then
        pr_build_images || return 0
    elif gum confirm "Rebuild the images from ${PR_REF} first?" --default=false; then
        pr_build_images || return 0
    fi
    # check before the units are written: it needs only pr_run_args. Written
    # first, units with a failing configuration stayed on disk with
    # WantedBy=default.target, and the next boot or restart ran them anyway,
    # crash-looping (Kamino item 95).
    if ! pr_deploy_cmd check; then
        warn "A backend is unreachable (above). Fix it, then install again - nothing was written or started."
        return 0
    fi
    mkdir -p "$QUADLET_DIR"
    PR_BIND_ADDR="$SVC_BIND_ADDR"   # saved below: status and the URLs read it
    local unit start
    for unit in "${PR_UNITS[@]}"; do
        render_quadlet "$unit" > "${QUADLET_DIR}/${unit}.container"
    done
    info "Wrote ${#PR_UNITS[@]} units to ${QUADLET_DIR}"
    systemctl --user daemon-reload
    start="$(date +%s)"
    # The light worker first, alone: two workers downloading the same model
    # into one cache at once collide. The heavy one starts once it is up.
    systemctl --user restart protocol-api.service protocol-maintenance.service \
        protocol-markitdown.service protocol-transcription.service \
        protocol-marker-light.service || error_exit "Start failed - see 'logs'."
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
    # Said, not left to the URL line: reaching it from other machines is the
    # point of the API (Kamino 235).
    if svc_bind_is_loopback; then
        info "Published on ${SVC_BIND_ADDR} only (SCOMP_BIND_ADDR): not reachable from the LAN, so no firewall port is opened."
        return 0
    fi
    svc_bind_notice
    pr_firewall_offer "$PR_PORT"
    local lan; lan="$(pr_lan_url)"
    [[ -n "$lan" ]] && info "From the LAN: ${lan}  (POST /documents)"
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
    if [[ "$(pr_bind_addr)" == 127.* ]]; then
        info "Published on $(pr_bind_addr) only (SCOMP_BIND_ADDR at install): not reachable from the LAN."
    else
        info "Published on $(pr_bind_addr)$([[ "$(pr_bind_addr)" == 0.0.0.0 ]] && echo ', every interface' || true)."
        case "$(pr_firewall_state "$PR_PORT")" in
            open)    info "Firewall ($(_fw_tool)): ${PR_PORT}/tcp open" ;;
            closed)  warn "Firewall ($(_fw_tool)): ${PR_PORT}/tcp closed - the LAN cannot reach the API" ;;
            unknown) warn "Firewall ($(_fw_tool)): state of ${PR_PORT}/tcp unknown (reading it needs sudo)" ;;
            none)    info "Firewall: none active" ;;
        esac
    fi
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
# _pr_set NAME VALUE - set a setting, if VALUE is one it may hold: the same
# pr_valid the settings file is read with (Kamino 236).
_pr_set() {
    if pr_valid "$1" "$2"; then printf -v "$1" '%s' "$2"
    else warn "Not changed: '${2}' - not $(pr_valid_hint "$1")."; fi
}

pr_config() {
    local field value before
    before="$(declare -p "${PR_SETTINGS[@]}")"
    while true; do
        header "protocol - settings"
        pr_show_settings
        field=$(gum choose port "MariaDB host" "MariaDB port" "Redis URL" "S3 endpoint" "buckets" "Qdrant URL" \
            "Qdrant collections" "Speaches URL" "models volume" "branch to build" "repositories" "reset to defaults" "done" \
            --header "Change:") || break
        case "$field" in
            port) value=$(gum input --value "$PR_PORT" --header "The API's port on this host:") || continue
                  _pr_set PR_PORT "$value" ;;
            "MariaDB host") value=$(gum input --value "$PR_MARIADB_HOST" --header "MariaDB host:") || continue
                  _pr_set PR_MARIADB_HOST "$value" ;;
            "MariaDB port") value=$(gum input --value "$PR_MARIADB_PORT" --header "MariaDB port:") || continue
                  _pr_set PR_MARIADB_PORT "$value" ;;
            "Redis URL") value=$(gum input --value "$PR_REDIS_URL" --header "Redis URL (no password in it - that is a secret):") || continue
                  _pr_set PR_REDIS_URL "$value" ;;
            "S3 endpoint") value=$(gum input --value "$PR_S3_ENDPOINT" --header "Garage S3 endpoint:") || continue
                  _pr_set PR_S3_ENDPOINT "$value" ;;
            buckets) value=$(gum input --value "$PR_S3_SOURCES_BUCKET" --header "Sources bucket:") || continue
                  _pr_set PR_S3_SOURCES_BUCKET "$value"
                  value=$(gum input --value "$PR_S3_OUTPUTS_BUCKET" --header "Outputs bucket:") || continue
                  _pr_set PR_S3_OUTPUTS_BUCKET "$value" ;;
            "Qdrant URL") value=$(gum input --value "$PR_QDRANT_URL" --header "Qdrant URL:") || continue
                  _pr_set PR_QDRANT_URL "$value" ;;
            "Qdrant collections") value=$(gum input --value "$PR_QDRANT_COLLECTIONS" \
                    --header "The collections ingestion writes, comma-separated (removal deletes points only there):") || continue
                  # "documents, chunks" is what people type: the spaces go.
                  value="${value//[[:space:]]/}"
                  _pr_set PR_QDRANT_COLLECTIONS "$value" ;;
            "Speaches URL") value=$(gum input --value "$PR_SPEACHES_URL" \
                    --header "Speaches, as a container reaches it (empty = refuse audio):") || continue
                  _pr_set PR_SPEACHES_URL "$value" ;;
            "models volume") value=$(gum input --value "$PR_MODELS_VOLUME" --header "Named volume for marker's models:") || continue
                  _pr_set PR_MODELS_VOLUME "$value" ;;
            "branch to build") value=$(gum input --value "$PR_REF" --header "Branch or tag of protocol and protocol-droid to build:") || continue
                  _pr_set PR_REF "$value" ;;
            repositories) value=$(gum input --value "$PR_PROTOCOL_REPO" --header "protocol's repository:") || continue
                  _pr_set PR_PROTOCOL_REPO "$value"
                  value=$(gum input --value "$PR_DROID_REPO" --header "protocol-droid's repository:") || continue
                  _pr_set PR_DROID_REPO "$value" ;;
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
