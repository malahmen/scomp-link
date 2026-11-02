#!/usr/bin/env bash
# Secret helpers.  Sourced by app scripts — do NOT run directly.

# _gen_secret <length> [tr-charset] - a random string of exactly <length>
# characters from [tr-charset] (default A-Za-z0-9).
#
# Safe under `set -euo pipefail`. The obvious one-liner,
#   tr -dc 'A-Za-z0-9' </dev/urandom | head -c 20
# is not: head exits after 20 bytes, tr dies of SIGPIPE writing the next block,
# pipefail makes the pipeline fail with 141 and errexit ends the script with no
# message - every "leave empty to auto-generate" prompt did that (Kamino 173).
# Here every pipe stage reads its input to the end: head reads a fixed block
# from /dev/urandom and tr filters all of it, so no stage is cut off.
_gen_secret() {
    local len="${1:?_gen_secret: length required}" charset="${2:-A-Za-z0-9}" out="" chunk
    [[ "$len" =~ ^[1-9][0-9]*$ ]] || { echo "_gen_secret: bad length '${len}'" >&2; return 2; }
    while (( ${#out} < len )); do
        chunk="$(LC_ALL=C head -c 512 /dev/urandom | LC_ALL=C tr -dc "$charset")"
        out+="$chunk"
    done
    printf '%s' "${out:0:len}"
}


# -----------------------------------------------------------------------------
# Kept data keeps its credentials (Kamino 174)
#
# A database image applies its credential env (POSTGRES_PASSWORD, MARIADB_*,
# MONGO_INITDB_*, GF_SECURITY_ADMIN_*, DOCKER_INFLUXDB_INIT_*, n8n's encryption
# key) only when it initialises an EMPTY data directory. Recreating the
# container on a kept volume - or `helm upgrade` on a kept PVC - with new
# values changes nothing in the data: the old password keeps working, the new
# one fails, and a script that printed "Generated password: ..." lied. So when
# the data exists, the scripts ask for nothing new: they carry the old values
# over (from the old container's env, or `helm upgrade --reuse-values`), or,
# with nothing to read them from, ask for the existing ones - never generate.
# -----------------------------------------------------------------------------

# _container_env <container> <VAR> - the value VAR had in the container's
# environment, or nothing. Never fails: a missing container or variable
# prints nothing.
_container_env() {
    local container="$1" key="$2" env line
    [[ -n "$container" ]] || return 0
    env="$(docker inspect --format='{{range .Config.Env}}{{println .}}{{end}}' "$container" 2>/dev/null)" || return 0
    while IFS= read -r line; do
        if [[ "$line" == "${key}="* ]]; then printf '%s' "${line#"${key}="}"; return 0; fi
    done <<< "$env"
    return 0
}

# _kept_data_notice <volume> [old-container] - says, before anything is asked,
# that the credentials of the kept data stay in force.
_kept_data_notice() {
    local volume="$1" old="${2:-}"
    if [[ -n "$old" ]]; then
        info "Data volume '${volume}' is kept: it keeps the credentials it was created with, read back from container '${old}'. No new ones are asked for - the data would ignore them."
    else
        warn "Data volume '${volume}' already exists (its container is gone): the credentials it was created with remain in force. No new ones are asked for or generated."
    fi
}

# _keep_credential <VAR> <old-container|""> <ENV_KEY> <label> <mode>
# Sets VAR to ENV_KEY's value in the old container; when it is not there,
# asks for the EXISTING value (never generates one). <mode>:
#   secret     a password, required - empty input returns 1 (the caller cancels)
#   secret?    a password, may stay empty
#   =default   a name; empty input means <default>
#   ?          a name, may stay empty
_keep_credential() {
    local var="$1" old="$2" key="$3" label="$4" mode="$5" v
    v="$(_container_env "$old" "$key")"
    if [[ -z "$v" ]]; then
        case "$mode" in
            secret|secret\?)
                v=$(gum input --password \
                    --placeholder "the ${label} the existing data was created with" \
                    --header "Existing ${label} (the kept data keeps it; this does not change it):") || true
                [[ -n "$v" || "$mode" == "secret?" ]] || return 1 ;;
            =*)
                v=$(gum input --placeholder "${mode#=}" \
                    --header "Existing ${label} (leave empty for '${mode#=}'):") || true
                v="${v:-${mode#=}}" ;;
            *)
                v=$(gum input --header "Existing ${label} (leave empty if none):") || true ;;
        esac
    fi
    printf -v "$var" '%s' "$v"
}


# -----------------------------------------------------------------------------
# Secrets kept off argv and out of world-readable files (Kamino 196)
#
# A command line is readable by every local user (ps, /proc/<pid>/cmdline)
# for as long as the command runs. And `helm --set k=v` parses its value:
# a comma splits it into two keys, and backslashes, dots and braces are
# syntax - so a password with any of them reached the chart changed. Secrets
# go to helm in a values file (mode 0600, removed again), to docker/podman as
# `-e NAME` (the value is taken from the client's environment), and to the
# database clients through their environment variables or stdin.
# -----------------------------------------------------------------------------

# _yaml_squote <value> - <value> as a single-quoted YAML scalar: the only
# escape there is '' for '. Returns 1 for a value with control characters
# (a newline would be folded into a space), printing nothing.
_yaml_squote() {
    local s="$1" q="'"
    [[ "$s" == *[[:cntrl:]]* ]] && return 1
    printf "'%s'" "${s//"$q"/"$q$q"}"
}

_SCOMP_SECRET_FILES=()
_scomp_secret_files_rm() {
    (( ${#_SCOMP_SECRET_FILES[@]} )) && rm -f -- "${_SCOMP_SECRET_FILES[@]}"
    return 0
}

# _helm_secret_values <VAR> <dotted.key> <value> [<dotted.key> <value>]...
# Writes the pairs as nested YAML to a new mode-0600 temp file and sets VAR
# to its path, for `helm ... -f "$VAR"`. Keys that share a parent must be
# given next to each other (a.b.x a.b.y). The file is removed at exit, also on
# error_exit; remove it sooner with _secret_file_rm. Returns 1 (no file) when
# a value cannot be written safely (control characters).
_helm_secret_values() {
    local __var="$1"; shift
    (( $# % 2 == 0 )) || { echo "_helm_secret_values: key without value" >&2; return 2; }
    local yaml="" q i n file
    local -a cur prev=()
    while (( $# )); do
        q="$(_yaml_squote "$2")" || return 1
        IFS=. read -r -a cur <<< "$1"
        n=${#cur[@]}
        # The parents this key shares with the previous one are already open.
        i=0
        while (( i < n - 1 && i < ${#prev[@]} - 1 )) && [[ "${cur[i]}" == "${prev[i]}" ]]; do
            i=$((i + 1))
        done
        for (( ; i < n - 1; i++ )); do
            yaml+="$(printf '%*s' $((i * 2)) '')${cur[i]}:"$'\n'
        done
        yaml+="$(printf '%*s' $(((n - 1) * 2)) '')${cur[n - 1]}: ${q}"$'\n'
        prev=("${cur[@]}")
        shift 2
    done
    file="$(umask 077 && mktemp "${TMPDIR:-/tmp}/scomp-helm-values.XXXXXX")" || return 1
    _SCOMP_SECRET_FILES+=("$file")
    trap _scomp_secret_files_rm EXIT
    printf '%s' "$yaml" > "$file" || return 1
    printf -v "$__var" '%s' "$file"
}

# _secret_file_rm <file> - removes a file made by _helm_secret_values now.
_secret_file_rm() { [[ -n "${1:-}" ]] && rm -f -- "$1"; return 0; }
