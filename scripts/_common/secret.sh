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

