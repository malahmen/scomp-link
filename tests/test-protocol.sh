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
#   - the six units: the API publishes its port, both marker workers share the
#     model volume and one SELinux level, nothing else gets either; the
#     transcription worker runs in the API's image and reaches Speaches;
#   - an unreachable backend starts nothing, and marker's heavy worker starts
#     only after the light one is taking jobs;
#   - a port inside firewalld's open range reads as open (corelia opens
#     1025-65535, and --query-port says "no" for it);
#   - uninstall keeps the model cache and the secrets unless asked;
#   - the API is published on every interface by default - a LAN service,
#     deliberately, and install says so - or where SCOMP_BIND_ADDR says, with
#     the URLs, the firewall and status following it (Kamino 235);
#   - the settings file is parsed, never sourced: shell code in it runs
#     nothing, and every key is checked like a typed value - a bad one is
#     ignored with a warning and the default kept; files the earlier versions
#     wrote still load (Kamino 236).
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
unset SCOMP_BIND_ADDR

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
# -- before the URL (Kamino 196): a repository setting is never an option.
check "both repositories are cloned" has "git clone --quiet -- https://github.com/malahmen/protocol-droid.git $T/src/protocol-droid" "$T/calls"
check "...and built at a fetched commit, not a working copy" has "checkout --quiet --detach FETCH_HEAD" "$T/calls"
check "the marker engine is built from protocol-droid" has "-t localhost/marker-service:latest $T/src/protocol-droid" "$T/calls"
check "the worker image goes on the engine's" has "--build-arg BASE=localhost/marker-service:latest -t localhost/protocol-marker:latest" "$T/calls"
check "every image carries its commit" has "--label org.opencontainers.image.revision=abc1234" "$T/calls"
check "an unreachable backend starts nothing" lacks "systemctl --user restart" "$T/calls"
check "...and writes no unit: a later boot cannot run it (item 95)" test "$(find "$Q" -name 'protocol-*.container' 2>/dev/null | wc -l)" -eq 0
check "...nor reloads systemd" lacks "daemon-reload" "$T/calls"
check "...and says so" has "A backend is unreachable" "$T/out"

rm -f "$T/state/backends-down"
run install yes no yes "← back"
check "with the backends reachable, six units are written" test "$(find "$Q" -name 'protocol-*.container' | wc -l)" -eq 6
check "...after the check passed" before "localhost/protocol:latest check" "daemon-reload" "$T/calls"
check "secrets already stored are not asked again" lacks "secret create" "$T/calls"
check "present images are not rebuilt unless asked" lacks "podman build" "$T/calls"
check "the light marker worker starts with the others" has "protocol-markitdown.service protocol-transcription.service protocol-marker-light.service" "$T/calls"
check "...and the heavy one only after it is taking jobs" before "journalctl --user -u protocol-marker-light.service" "restart protocol-marker-heavy.service" "$T/calls"
check "lingering is enabled" has "loginctl enable-linger" "$T/calls"
check "a port inside an open range is not offered again" lacks "add-port" "$T/calls"
check "the settings are saved" test -f "$T/config/protocol.conf"
check "it says the API is on every interface, a LAN service (Kamino 235)" has "every interface: this is a LAN service" "$T/out"

# ---- the units ------------------------------------------------------------------
echo "units"
check "the API publishes its port, on every interface (Kamino 235)" has "PublishPort=0.0.0.0:8090:8080" "$Q/protocol-api.container"
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
# Kamino item 89: audio had no worker, and waited in its queue for good.
check "a transcription worker, on the API's image" has "Image=localhost/protocol:latest" "$Q/protocol-transcription.container"
check "...running the transcription lane" has "Exec=worker transcription" "$Q/protocol-transcription.container"
check "...with no model volume: Speaches holds the model" lacks "Volume=" "$Q/protocol-transcription.container"
check "it reaches Speaches as a container can" has "Environment=SPEACHES_URL=http://host.containers.internal:8000" "$Q/protocol-transcription.container"
check "...and so does the API, which then accepts audio" has "Environment=SPEACHES_URL=http://host.containers.internal:8000" "$Q/protocol-api.container"

echo "where the API is published (Kamino 235)"
SCOMP_BIND_ADDR=127.0.0.1 run install yes no "← back"
check "SCOMP_BIND_ADDR=127.0.0.1: loopback only" has "PublishPort=127.0.0.1:8090:8080" "$Q/protocol-api.container"
check "...said, and no firewall or LAN URL offered" bash -c 'grep -q "not reachable from the LAN" "$1" && ! grep -q "From the LAN" "$1"' _ "$T/out"
run status "← back"
check "status, later, still says loopback only" has "Published on 127.0.0.1 only" "$T/out"
check "...and reads no firewall" lacks "Firewall" "$T/out"
SCOMP_BIND_ADDR=192.0.2.9 run install yes no "← back"
check "SCOMP_BIND_ADDR=192.0.2.9: published there" has "PublishPort=192.0.2.9:8090:8080" "$Q/protocol-api.container"
check "...health asked there" has "http://192.0.2.9:8090/healthz" "$T/calls"
check "...the LAN URL is that address" has "From the LAN: http://192.0.2.9:8090" "$T/out"
run install yes no "← back"
check "unset again: every interface" has "PublishPort=0.0.0.0:8090:8080" "$Q/protocol-api.container"

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
run config "Qdrant collections" "documents, chunks" "done" yes yes no "← back"
check "named collections reach the units, without the typed space (item 102)" has "Environment=QDRANT_COLLECTIONS=documents,chunks" "$Q/protocol-api.container"
check "every setting is in the menu: the MariaDB port" has "<option> MariaDB port" "$T/out"
check "...and Speaches" has "<option> Speaches URL" "$T/out"
# The field opens holding the URL (gum --value), so emptying it is <clear>:
# Enter alone keeps it (Kamino 196).
run config "Speaches URL" "<clear>" "done" yes yes no "← back"
check "an empty Speaches URL leaves it out of the units: audio is refused" lacks "SPEACHES_URL" "$Q/protocol-api.container"
check "...and says so" has "not set (audio is refused)" "$T/out"
check "...and the repositories" has "<option> repositories" "$T/out"
run config "MariaDB host" "meksha lan" "S3 endpoint" "http://nas:3900/50%" "done" "← back"
check "a value with a space is refused (the file holds it %q-escaped)" lacks "meksha" "$T/config/protocol.conf"
check "...and one with a %" lacks "50%" "$T/config/protocol.conf"
check "...saying why" has "not a host name or IPv4 address" "$T/out"
run config "MariaDB port" "3307" "done" no "← back"
check "the MariaDB port can be changed" grep -q "^PR_MARIADB_PORT=3307" "$T/config/protocol.conf"
run config "repositories" "https://example.test/protocol.git" "https://example.test/protocol-droid.git" "done" yes yes yes "← back"
check "a changed repository is the one fetched from" has "remote set-url origin https://example.test/protocol.git" "$T/calls"
check "...set before its clone fetches (protocol-droid is fetched first)" before "remote set-url origin https://example.test/protocol-droid.git" "fetch --quiet -- origin" "$T/calls"
printf 'PR_S3_OUTPUTS_BUCKET=%q\n' "out puts" >> "$T/config/protocol.conf"
# Since Kamino 236 a hand-edited value is checked as the file is read: one
# that would break a unit is ignored with a warning, and install goes on with
# the default.
run install yes no "← back"
check "a hand-edited value that would break a unit is ignored, by name" has "Ignoring PR_S3_OUTPUTS_BUCKET='out puts'" "$T/out"
check "...never reaching a unit" lacks "out puts" <(cat "$Q"/*.container)
check "...which carry the default" has "Environment=S3_OUTPUTS_BUCKET=protocol-outputs" "$Q/protocol-api.container"
# pr_env_check stays as the backstop before anything is built or written.
# It ran inside `< <(pr_env)`, where its error_exit ended only the process
# substitution: every unit was rewritten and daemon-reload ran anyway
# (Kamino 196). A setting the checks miss still stops install in the caller.
check "a setting that would break a unit still fails pr_env_check" bash -c '
    source "$1" >/dev/null 2>&1; set +e; cfg_defaults; PR_S3_OUTPUTS_BUCKET="out puts"
    ! pr_env_check 2>/dev/null' _ "$FRONT"
sed -i.bak '/^PR_S3_OUTPUTS_BUCKET=/d' "$T/config/protocol.conf"

echo "PR_REF reaches git as a ref, never an option (Kamino 196)"
run config "branch to build" "--upload-pack=touch" "done" "← back"
check "a branch starting with - is refused under config" lacks "upload-pack" "$T/config/protocol.conf"
printf 'PR_REF=%q\n' "--upload-pack=x" >> "$T/config/protocol.conf"
run build "← back"
check "a hand-edited one: git is never handed it" lacks "upload-pack" "$T/calls"
check "...it is ignored as the file is read, saying why (Kamino 236)" has "Ignoring PR_REF='--upload-pack=x'" "$T/out"
check "...and the default branch built" has "fetch --quiet -- origin main" "$T/calls"
sed -i.bak '/^PR_REF=/d' "$T/config/protocol.conf"
run build "← back"
check "the fetch puts -- before the remote and ref" has "fetch --quiet -- origin main" "$T/calls"

# ---- the settings file: parsed and checked, never sourced (Kamino 236) ---------------
echo "the settings file is parsed and checked, never sourced (Kamino 236)"
cp "$T/config/protocol.conf" "$T/conf.kept"
# Every key the file holds, named here rather than read from the script, so
# the same checks run against any version of it.
KEYS="PR_PORT PR_MARIADB_HOST PR_MARIADB_PORT PR_REDIS_URL PR_S3_ENDPOINT PR_S3_SOURCES_BUCKET
      PR_S3_OUTPUTS_BUCKET PR_QDRANT_URL PR_QDRANT_COLLECTIONS PR_SPEACHES_URL PR_MODELS_VOLUME
      PR_PROTOCOL_REPO PR_DROID_REPO PR_REF PR_BIND_ADDR"
# settings_of - every key as cfg_load leaves it, KEY=value per line.
settings_of() {
    bash -c 'source "$1" >/dev/null 2>&1; set +e; cfg_load 2>/dev/null
             for k in $2; do printf "%s=%s\n" "$k" "${!k}"; done' _ "$FRONT" "$KEYS"
}
defaults_of() {
    bash -c 'source "$1" >/dev/null 2>&1; set +e; cfg_defaults; PR_BIND_ADDR=""
             for k in $2; do printf "%s=%s\n" "$k" "${!k}"; done' _ "$FRONT" "$KEYS"
}

# Shell code in the file: a $(...), a backtick, a command after a ;, and a
# line that is only a command. Sourced, every one of them ran.
{ printf '%s\n' "PR_PORT=\$(touch $T/pwned-subst)" "PR_REF=\`touch $T/pwned-backtick\`" \
      "PR_MARIADB_HOST=meksha; touch $T/pwned-semicolon" "touch $T/pwned-line" \
      "PR_MODELS_VOLUME=x && touch $T/pwned-and"; } > "$T/config/protocol.conf"
run "← back"
for f in subst backtick semicolon line and; do
    check "shell code in the settings file runs nothing: ${f}" test ! -e "$T/pwned-${f}"
done
check "...a \$(...) value is ignored, naming its key" has "Ignoring PR_PORT" "$T/out"
check "...a value with a command after it too" has "Ignoring PR_MARIADB_HOST" "$T/out"
check "...and the TUI still starts" has "Bye." "$T/out"
check "...with the defaults in their place" cmp -s <(settings_of) <(defaults_of)

# One bad value per key: each is ignored with a warning naming it, and the
# default kept. %q-written, as cfg_save writes, so only the check stops them.
bad=(
    "PR_PORT=99999" "PR_MARIADB_HOST=999.1.1.1" "PR_MARIADB_PORT=0"
    "PR_REDIS_URL=redis://user:pw@192.168.3.52:6380/0" "PR_S3_ENDPOINT=ftp://192.168.3.5:3900"
    "PR_S3_SOURCES_BUCKET=Protocol_Sources" "PR_S3_OUTPUTS_BUCKET=192.168.3.5"
    "PR_QDRANT_URL=http://192.168.3.52:6333/?api-key=x" "PR_QDRANT_COLLECTIONS=documents,,chunks"
    "PR_SPEACHES_URL=http://host.containers.internal:70000" "PR_MODELS_VOLUME=/etc"
    "PR_PROTOCOL_REPO=ext::sh -c touch\ /tmp/x" "PR_DROID_REPO=https://token@github.com/malahmen/protocol-droid.git"
    "PR_REF=main..evil" "PR_BIND_ADDR=lan"
)
{ for kv in "${bad[@]}"; do printf '%s=%q\n' "${kv%%=*}" "${kv#*=}"; done; } > "$T/config/protocol.conf"
run "← back"
for kv in "${bad[@]}"; do
    check "a bad ${kv%%=*} in the file is ignored, with a warning naming it" has "Ignoring ${kv%%=*}=" "$T/out"
done
check "...saying which default is kept" has "Ignoring PR_PORT='99999' in $T/config/protocol.conf: not a port (1-65535). Using '8090'" "$T/out"
settings_of > "$T/settings.bad"
for kv in "${bad[@]}"; do
    check "...and ${kv%%=*} keeps its default" grep -qxF -- "$(defaults_of | grep "^${kv%%=*}=")" "$T/settings.bad"
done

# Files the earlier versions wrote: every cfg_save since the first (6ba376a)
# wrote KEY=%q lines under a comment - 13 keys at first, PR_SPEACHES_URL
# since item 89, PR_BIND_ADDR since 235 - and a hand edit under `source`
# could use "..." or '...'. All of them still load.
cat > "$T/config/protocol.conf" <<'CONF'
# protocol.sh settings - see the defaults in protocol.sh
PR_PORT=8091
PR_MARIADB_HOST=meksha.lan
PR_MARIADB_PORT=3307
PR_REDIS_URL=redis://192.168.3.52:6380/1
PR_S3_ENDPOINT=http://192.168.3.5:3901
PR_S3_SOURCES_BUCKET=protocol-sources-2
PR_S3_OUTPUTS_BUCKET=protocol.outputs
PR_QDRANT_URL=https://qdrant.lan
PR_QDRANT_COLLECTIONS=documents,chunks
PR_MODELS_VOLUME=protocol-models-2
PR_PROTOCOL_REPO=git@github.com:malahmen/protocol.git
PR_DROID_REPO=/srv/git/protocol-droid.git
PR_REF=release/1.2
CONF
run "← back"
check "a file the first version wrote loads without a warning" lacks "Ignoring" "$T/out"
settings_of > "$T/settings.old"
for kv in PR_PORT=8091 PR_MARIADB_HOST=meksha.lan PR_MARIADB_PORT=3307 PR_REDIS_URL=redis://192.168.3.52:6380/1 \
          PR_S3_ENDPOINT=http://192.168.3.5:3901 PR_S3_SOURCES_BUCKET=protocol-sources-2 PR_S3_OUTPUTS_BUCKET=protocol.outputs \
          PR_QDRANT_URL=https://qdrant.lan PR_QDRANT_COLLECTIONS=documents,chunks PR_MODELS_VOLUME=protocol-models-2 \
          PR_PROTOCOL_REPO=git@github.com:malahmen/protocol.git PR_DROID_REPO=/srv/git/protocol-droid.git PR_REF=release/1.2 \
          PR_SPEACHES_URL=http://host.containers.internal:8000 PR_BIND_ADDR=; do
    check "...${kv%%=*} as written (or its default, for a key it did not have)" grep -qxF -- "$kv" "$T/settings.old"
done
cat > "$T/config/protocol.conf" <<'CONF'
# protocol.sh settings - see the defaults in protocol.sh
PR_PORT=8090
PR_QDRANT_COLLECTIONS=''
PR_SPEACHES_URL=''

PR_REF="feature/x"
PR_MODELS_VOLUME='protocol-models'
PR_BIND_ADDR=0.0.0.0
CONF
run "← back"
check "the 235 format, '' and hand-quoted values load without a warning" lacks "Ignoring" "$T/out"
settings_of > "$T/settings.old"
for kv in PR_QDRANT_COLLECTIONS= PR_SPEACHES_URL= PR_REF=feature/x PR_MODELS_VOLUME=protocol-models PR_BIND_ADDR=0.0.0.0; do
    check "...${kv%%=*} as written" grep -qxF -- "$kv" "$T/settings.old"
done
# Read and write are symmetric: what cfg_save writes, cfg_load reads back.
# conf.kept is what install and 'config' above wrote (collections, repositories, ...).
cp "$T/conf.kept" "$T/config/protocol.conf"
check "a file this version wrote loads without a warning" bash -c '! { source "$1"; cfg_load; } 2>&1 >/dev/null | grep -q Ignoring' _ "$FRONT"
check "...and what cfg_save writes, cfg_load reads back the same" bash -c '
    source "$1" >/dev/null 2>&1; set +e; cfg_load 2>/dev/null; a="$(declare -p $2)"
    cfg_save; cfg_load 2>/dev/null; [[ "$a" == "$(declare -p $2)" ]]' _ "$FRONT" "$KEYS"

# Typed under 'config': the same checks. Each refused value leaves the file as it was.
cp "$T/config/protocol.conf" "$T/conf.before"
run config port "0" "MariaDB host" "999.1.1.1" "MariaDB port" "65536" "Redis URL" "redis://192.168.3.52:6380/abc" \
    "S3 endpoint" "ftp://192.168.3.5:3900" buckets "Protocol_Sources" "192.168.3.5" \
    "Qdrant URL" "http://192.168.3.52:6333/?api-key=x" "Qdrant collections" "documents,,chunks" \
    "Speaches URL" "http://host.containers.internal:70000" "models volume" "/etc" "branch to build" "main..evil" \
    repositories "ext::sh" "https://token@github.com/malahmen/protocol-droid.git" "done" "← back"
for v in "0" "999.1.1.1" "65536" "redis://192.168.3.52:6380/abc" "ftp://192.168.3.5:3900" "Protocol_Sources" "192.168.3.5" \
         "http://192.168.3.52:6333/?api-key=x" "documents,,chunks" "http://host.containers.internal:70000" "/etc" "main..evil" \
         "ext::sh" "https://token@github.com/malahmen/protocol-droid.git"; do
    check "a typed '${v}' is refused" has "Not changed: '${v}'" "$T/out"
done
check "...and nothing refused was saved" cmp -s "$T/config/protocol.conf" "$T/conf.before"
cp "$T/conf.kept" "$T/config/protocol.conf"

# ---- uninstall ---------------------------------------------------------------------
echo "uninstall"
run uninstall yes no no "← back"
check "the units are removed" test "$(find "$Q" -name 'protocol-*.container' | wc -l)" -eq 0
check "the model cache is kept unless asked" lacks "podman volume rm" "$T/calls"
check "the secrets are kept unless asked" test -f "$T/state/secret-protocol-redis-password"

echo
if (( FAILS )); then echo "${FAILS} check(s) failed"; exit 1; fi
echo "all checks passed"
