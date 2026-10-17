#!/usr/bin/env bash
# The protocol front-end, driven through the gum stub. No network and nothing
# real is touched: podman, git, systemctl, loginctl, journalctl, curl,
# firewall-cmd, sudo, hostname and uname are recording stubs, and the Quadlet,
# settings and source directories point into a temporary folder.
#
# What it protects:
#   - a secret is asked for once, stored over stdin, and never written into a
#     unit or onto a command line;
#   - the images are built from a clean clone of each repository, stamped with
#     the commit, and each worker image on its engine's;
#   - the five units: the API publishes its port, both marker workers share the
#     model volume and one SELinux level, nothing else gets either;
#   - an unreachable backend starts nothing, and marker's heavy worker starts
#     only after the light one is taking jobs;
#   - a port inside firewalld's open range reads as open (corelia opens
#     1025-65535, and --query-port says "no" for it);
#   - uninstall keeps the model cache and the secrets unless asked.
# shellcheck disable=SC2016
# Single-quoted heredoc stubs expand their own $1/$@ at run time, on purpose.
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FRONT="${TEST_DIR}/../scripts/protocol/protocol.sh"
[[ -f "$FRONT" ]] || { echo "front-end not found at $FRONT" >&2; exit 1; }

T="$(mktemp -d)"; trap '[[ -n "${KEEP_TMP:-}" ]] && echo "kept: $T" || rm -rf "$T"' EXIT
T="$(cd "$T" && pwd -P)"
FAILS=0
check() { local d="$1"; shift; if "$@"; then echo "   ok   - $d"; else echo "   FAIL - $d"; FAILS=$((FAILS + 1)); fi; }
has()   { grep -qF -- "$1" "$2"; }
lacks() { ! grep -qF -- "$1" "$2"; }
# before <a> <b> <file> - the first line with a comes before the first with b
before() { local a b; a=$(grep -nF -- "$1" "$3" | head -1 | cut -d: -f1); b=$(grep -nF -- "$2" "$3" | head -1 | cut -d: -f1); [[ -n "$a" && -n "$b" && "$a" -lt "$b" ]]; }

# ---- stubs --------------------------------------------------------------------
mkdir -p "$T/bin" "$T/state"
cat > "$T/bin/podman" <<'EOF'
#!/usr/bin/env bash
echo "podman $*" >> "$STUB_LOG"
key() { printf '%s' "$1" | tr '/:' '__'; }
case "$1 $2" in
    "version --format") echo "5.2.0"; exit 0 ;;
    "secret inspect")   [[ -f "$STUB_STATE/secret-$3" ]]; exit ;;
    "secret create")    name="${*: -2:1}"; cat > "$STUB_STATE/secret-$name"; exit 0 ;;
    "secret rm")        rm -f "$STUB_STATE/secret-$3"; exit 0 ;;
    "image exists")     [[ -f "$STUB_STATE/image-$(key "$3")" ]]; exit ;;
    "image inspect")    [[ -f "$STUB_STATE/image-$(key "$3")" ]] && echo abc1234; exit 0 ;;
    "volume rm")        exit 0 ;;
esac
if [[ "$1" == build ]]; then
    while [[ $# -gt 0 ]]; do [[ "$1" == -t ]] && : > "$STUB_STATE/image-$(key "$2")"; shift; done
    exit 0
fi
if [[ "$1" == run ]]; then
    case "${*: -1}" in
        check)  echo "ok    MariaDB: reachable"; [[ -f "$STUB_STATE/backends-down" ]] && exit 1; exit 0 ;;
        queues) echo "maintenance   waiting 0   dead 0   worker maintenance"; exit 0 ;;
    esac
fi
exit 0
EOF
cat > "$T/bin/git" <<'EOF'
#!/usr/bin/env bash
echo "git $*" >> "$STUB_LOG"
case "$1" in
    clone)  mkdir -p "${*: -1}/.git" ;;
    -C)     [[ "$3" == rev-parse ]] && echo abc1234 ;;
esac
exit 0
EOF
for cmd in systemctl loginctl sudo; do
    cat > "$T/bin/$cmd" <<'EOF'
#!/usr/bin/env bash
name="$(basename "$0")"
echo "$name $*" >> "$STUB_LOG"
case "$name $*" in
    "loginctl show-user"*)               [[ -f "$STUB_STATE/linger" ]] && echo yes || echo no ;;
    "loginctl enable-linger"*)           : > "$STUB_STATE/linger" ;;
    "systemctl is-active --quiet firewalld") exit 0 ;;
    "systemctl --user is-active"*)       echo active ;;
    "sudo -n true")                      exit 0 ;;
esac
exit 0
EOF
done
cat > "$T/bin/journalctl" <<'EOF'
#!/usr/bin/env bash
echo "journalctl $*" >> "$STUB_LOG"
[[ "$*" == *protocol-marker-light* ]] && echo "*** Listening on convert.marker.light..."
exit 0
EOF
# corelia's firewall: one wide open range, so --query-port answers no.
cat > "$T/bin/firewall-cmd" <<'EOF'
#!/usr/bin/env bash
echo "firewall-cmd $*" >> "$STUB_LOG"
case "$*" in
    --list-ports) echo "1025-65535/tcp 1025-65535/udp" ;;
    --query-port=*) echo no; exit 1 ;;
esac
exit 0
EOF
cat > "$T/bin/curl" <<'EOF'
#!/usr/bin/env bash
echo "curl $*" >> "$STUB_LOG"
method=GET url=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        -X) method="$2"; shift 2 ;;
        -o|-F|-H|--max-time) shift 2 ;;
        http*) url="$1"; shift ;;
        *) shift ;;
    esac
done
case "$method $url" in
    "GET "*/healthz)          exit 0 ;;
    *" "*/documents)          echo '{"document_id":"d0c","state":"conversion_pending","created":true}' ;;
    "GET "*/documents/d0c)    echo '{"document":{"document_id":"d0c","state":"validation_pending","size":1},"conversions":[]}' ;;
    "DELETE "*/documents/d0c) : ;;
    *)                        exit 22 ;;
esac
exit 0
EOF
printf '#!/usr/bin/env bash\necho corelia\n' > "$T/bin/hostname"
printf '#!/usr/bin/env bash\necho Linux\n' > "$T/bin/uname"
chmod +x "$T/bin/"*

export PATH="${TEST_DIR}/stubs:$T/bin:$PATH"
export GUM_ANSWERS="$T/answers" GUM_STATE="$T/gumstate" STUB_LOG="$T/calls" STUB_STATE="$T/state"
export SCOMP_PROTOCOL_CONFIG_DIR="$T/config" SCOMP_PROTOCOL_QUADLET_DIR="$T/quadlet" SCOMP_PROTOCOL_SRC_DIR="$T/src"
Q="$T/quadlet"

run() {
    printf '%s\n' "$@" > "$GUM_ANSWERS"; : > "$GUM_STATE"; : > "$STUB_LOG"
    bash "$FRONT" > "$T/out" 2>&1
}

# ---- install, from nothing ------------------------------------------------------
echo "install"
: > "$T/state/backends-down"
run install yes db-pw-111 redis-pw-222 GKaccess333 s3-secret-444 qdrant-key-555 "← back"
check "every secret is stored" test -f "$T/state/secret-protocol-qdrant-api-key"
check "...from stdin: the value is what was typed" grep -qx "redis-pw-222" "$T/state/secret-protocol-redis-password"
check "...and on no command line" lacks "redis-pw-222" "$T/calls"
check "both repositories are cloned" has "git clone --quiet https://github.com/malahmen/protocol-droid.git $T/src/protocol-droid" "$T/calls"
check "...and built at a fetched commit, not a working copy" has "checkout --quiet --detach FETCH_HEAD" "$T/calls"
check "the marker engine is built from protocol-droid" has "-t localhost/marker-service:latest $T/src/protocol-droid" "$T/calls"
check "the worker image goes on the engine's" has "--build-arg BASE=localhost/marker-service:latest -t localhost/protocol-marker:latest" "$T/calls"
check "every image carries its commit" has "--label org.opencontainers.image.revision=abc1234" "$T/calls"
check "five units are written" test "$(find "$Q" -name 'protocol-*.container' | wc -l)" -eq 5
check "an unreachable backend starts nothing" lacks "systemctl --user restart" "$T/calls"
check "...and says so" has "A backend is unreachable" "$T/out"

rm -f "$T/state/backends-down"
run install yes no yes "← back"
check "secrets already stored are not asked again" lacks "secret create" "$T/calls"
check "present images are not rebuilt unless asked" lacks "podman build" "$T/calls"
check "the light marker worker starts with the others" has "protocol-markitdown.service protocol-marker-light.service" "$T/calls"
check "...and the heavy one only after it is taking jobs" before "journalctl --user -u protocol-marker-light.service" "restart protocol-marker-heavy.service" "$T/calls"
check "lingering is enabled" has "loginctl enable-linger" "$T/calls"
check "a port inside an open range is not offered again" lacks "add-port" "$T/calls"
check "the settings are saved" test -f "$T/config/protocol.conf"

# ---- the units ------------------------------------------------------------------
echo "units"
check "the API publishes its port" has "PublishPort=8090:8080" "$Q/protocol-api.container"
check "...and runs the API" has "Exec=api" "$Q/protocol-api.container"
check "no worker publishes a port" lacks "PublishPort" "$Q/protocol-markitdown.container"
check "the light worker runs the light lane" has "Exec=worker marker-light" "$Q/protocol-marker-light.container"
check "both marker workers share the model volume" has "Volume=protocol-models:/models" "$Q/protocol-marker-heavy.container"
check "...at one SELinux level" has "SecurityLabelLevel=s0:c470,c471" "$Q/protocol-marker-light.container"
check "...which markitdown does not get" lacks "SecurityLabelLevel" "$Q/protocol-markitdown.container"
check "the Redis password arrives as a secret" has "Secret=protocol-redis-password,type=env,target=REDIS_PASSWORD" "$Q/protocol-maintenance.container"
check "no secret value is in any unit" lacks "db-pw-111" <(cat "$Q"/*.container)
check "meksha's protocol Redis, not the podman one" has "Environment=REDIS_URL=redis://192.168.3.52:6380/0" "$Q/protocol-api.container"
check "the buckets are protocol's" has "Environment=S3_SOURCES_BUCKET=protocol-sources" "$Q/protocol-api.container"
check "no collections until ingestion names them" lacks "QDRANT_COLLECTIONS" "$Q/protocol-api.container"

# ---- status, test --------------------------------------------------------------------
echo "status and test"
run status "← back"
check "status shows the commit each image was built from" has "built from abc1234" "$T/out"
check "status reports the open port" has "8090/tcp open" "$T/out"
check "status runs the backend check" has "ok    MariaDB: reachable" "$T/out"
check "...and the queues" has "worker maintenance" "$T/out"
run test "← back"
check "test submits a document" has "-F file=@" "$T/calls"
check "...sees it converted" has "Converted by markitdown" "$T/out"
check "...and removes it again" has "-X DELETE http://127.0.0.1:8090/documents/d0c" "$T/calls"

# ---- settings ----------------------------------------------------------------------
echo "settings"
run config "Redis URL" "redis://user:pw@192.168.3.52:6380/0" "done" "← back"
check "a Redis URL with credentials in it is refused" lacks "user:pw" "$T/config/protocol.conf"
run config "Qdrant collections" "documents,chunks" "done" yes yes no "← back"
check "named collections reach the units" has "Environment=QDRANT_COLLECTIONS=documents,chunks" "$Q/protocol-api.container"

# ---- uninstall ---------------------------------------------------------------------
echo "uninstall"
run uninstall yes no no "← back"
check "the units are removed" test "$(find "$Q" -name 'protocol-*.container' | wc -l)" -eq 0
check "the model cache is kept unless asked" lacks "podman volume rm" "$T/calls"
check "the secrets are kept unless asked" test -f "$T/state/secret-protocol-redis-password"

echo
if (( FAILS )); then echo "${FAILS} check(s) failed"; exit 1; fi
echo "all checks passed"
