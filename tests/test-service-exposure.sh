#!/usr/bin/env bash
# What the service scripts expose, and to whom (Kamino 196). Driven through the
# gum stub against recording docker/docker-compose/kubectl stubs
# (tests/lib/service-stubs.sh); nothing real is reached.
#
#   - Published ports: `-p 5432:5432` and compose `"3000:3000"` listen on every
#     interface while the summaries said localhost - a database, an admin UI,
#     and Dozzle (the Docker socket, auth off) open to the LAN. They are
#     published on 127.0.0.1 now, SCOMP_BIND_ADDR overrides, and the summary
#     prints the address used. Dozzle is never published beyond loopback with
#     its auth off.
set -uo pipefail

# shellcheck source=lib/service-stubs.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/service-stubs.sh"

runs()      { grep -E '^docker run ' "$STUB_LOG"; }
# published <host-port> <container-port> - every `-p` for it names 127.0.0.1,
# and there is one.
published() {
    local got; got="$(runs | grep -oE -- "-p [^ ]*:$1:$2( |$)|-p $1:$2( |$)" || true)"
    [[ -n "$got" ]] && ! grep -vqE -- "-p ${3:-127\.0\.0\.1}:$1:$2" <<< "$got"
}
blanks() { local i; for (( i = 0; i < $1; i++ )); do printf '\n'; done; }
# svc_run with N blank answers after <svc> "" install: every prompt of a fresh
# install takes its default, and the next menu read is Esc (back, then Bye).
fresh_install() {
    local svc="$1" n="$2"
    printf '%s\n' "" install > "$GUM_ANSWERS"; blanks "$n" >> "$GUM_ANSWERS"
    : > "$GUM_STATE"; : > "$STUB_LOG"
    (cd "$T/work" && bash "${SVC_DIR}/${svc}/${svc}.sh" > "$T/out" 2>&1 < /dev/null)
    echo $? > "$T/rc"
}

# ------------------------------------------------------------ published ports
#            service   blanks  host:container ports
for spec in "postgres  5  5432:5432" \
            "mariadb   6  3306:3306" \
            "mysql     6  3306:3306" \
            "mongodb   6  27017:27017" \
            "influxdb  6  8086:8086" \
            "grafana   6  3000:3000" \
            "n8n       6  5678:5678" \
            "qdrant    5  6333:6333 6334:6334"; do
    read -r svc n ports <<< "$spec"
    echo "${svc}: a fresh Docker install publishes on 127.0.0.1"
    svc_reset
    fresh_install "$svc" "$n"
    check "the script finishes (exit 0)" rc_is 0
    for p in $ports; do
        check "-p 127.0.0.1:${p}" published "${p%%:*}" "${p##*:}"
        check "the summary names 127.0.0.1:${p%%:*}, not localhost" \
            bash -c 'grep -qF "127.0.0.1:$1" "$2" && ! grep -qF "localhost:$1" "$2"' _ "${p%%:*}" "$T/out"
    done
    check "no 'reachable from other machines' notice" lacks "reachable from other machines" "$T/out"
done

echo "redis: a fresh Docker install publishes on 127.0.0.1"
svc_reset
printf '%s\n' "" "" install > "$GUM_ANSWERS"; blanks 5 >> "$GUM_ANSWERS"
: > "$GUM_STATE"; : > "$STUB_LOG"
(cd "$T/work" && bash "${SVC_DIR}/redis/redis.sh" > "$T/out" 2>&1 < /dev/null); echo $? > "$T/rc"
check "the script finishes (exit 0)" rc_is 0
check "-p 127.0.0.1:6379:6379" published 6379 6379
check "the summary names 127.0.0.1:6379" has "127.0.0.1:6379" "$T/out"

echo "postgres: SCOMP_BIND_ADDR=0.0.0.0 publishes on every interface, and says so"
svc_reset
SCOMP_BIND_ADDR=0.0.0.0 fresh_install postgres 5
check "the script finishes (exit 0)" rc_is 0
check "-p 0.0.0.0:5432:5432" published 5432 5432 '0\.0\.0\.0'
check "the summary warns it is reachable from other machines" has "reachable from other machines" "$T/out"

echo "postgres: SCOMP_BIND_ADDR=192.168.1.10 (one LAN address)"
svc_reset
SCOMP_BIND_ADDR=192.168.1.10 fresh_install postgres 5
check "-p 192.168.1.10:5432:5432" published 5432 5432 '192\.168\.1\.10'
check "the summary names 192.168.1.10:5432" has "192.168.1.10:5432" "$T/out"

echo "postgres: a SCOMP_BIND_ADDR that is not an IPv4 address stops the script"
for bad in "localhost" "0.0.0.0:80" "256.1.1.1" "1.2.3" "\$(touch pwned)"; do
    svc_reset
    SCOMP_BIND_ADDR="$bad" fresh_install postgres 5
    check "'${bad}': non-zero exit, said so, nothing run" \
        bash -c '[[ "$(cat "$1/rc")" != 0 ]] && grep -q "SCOMP_BIND_ADDR" "$1/out" && ! grep -q "^docker run" "$2" && [[ ! -e "$1/work/pwned" ]]' _ "$T" "$STUB_LOG"
done

DOZZLE_COMPOSE="$HOME/.config/dozzle/workdir/docker-compose.yml"
echo "dozzle: Docker install (auth off) publishes on 127.0.0.1"
svc_reset; rm -rf "$HOME/.config"
svc_cmd dozzle install no "$T/dozzle-data"
check "install finishes (exit 0)" rc_is 0
check "the compose file publishes 127.0.0.1:8080:8080" grep -qF '"127.0.0.1:8080:8080"' "$DOZZLE_COMPOSE"
check "the summary names http://127.0.0.1:8080" has "http://127.0.0.1:8080" "$T/out"
svc_cmd dozzle status
check "status names http://127.0.0.1:8080" has "http://127.0.0.1:8080" "$T/out"

echo "dozzle: SCOMP_BIND_ADDR=0.0.0.0 with auth off is refused"
svc_reset; rm -rf "$HOME/.config" "$T/dozzle-data"
SCOMP_BIND_ADDR=0.0.0.0 svc_cmd dozzle install no "$T/dozzle-data"
check "install refuses (non-zero, says why)" \
    bash -c '[[ "$(cat "$1/rc")" != 0 ]] && grep -q "Refusing to publish Dozzle on 0.0.0.0" "$1/out"' _ "$T"
check "nothing is started" bash -c "! grep -q 'docker-compose .* up' '$STUB_LOG'"
check "no compose file publishes beyond loopback" \
    bash -c '[[ ! -f "$1" ]] || ! grep -qE "\"(0\.0\.0\.0:)?8080:8080\"" "$1"' _ "$DOZZLE_COMPOSE"
SCOMP_BIND_ADDR=192.168.1.10 svc_cmd dozzle install no "$T/dozzle-data"
check "...and so is one LAN address" bash -c '[[ "$(cat "$1/rc")" != 0 ]] && ! grep -q "docker-compose .* up" "$2"' _ "$T" "$STUB_LOG"

echo "lgtm: Docker compose ports are on 127.0.0.1"
svc_reset; rm -rf "$HOME/.config" "$T/lgtm-data"
svc_cmd lgtm install 'Grafana\nLoki\nTempo' "$T/lgtm-data"
check "install finishes (exit 0)" rc_is 0
LGTM_COMPOSE="$(find "$HOME/.config/lgtm/compose" -name '*.y*ml' 2>/dev/null | head -1)"
check "a compose file was written" test -n "$LGTM_COMPOSE"
check "every published port is on 127.0.0.1" \
    bash -c 'n=$(grep -cE "^      - \"[0-9.:]+\"$" "$1"); (( n >= 4 )) && ! grep -E "^      - \"[0-9.:]+\"$" "$1" | grep -vq "\"127\.0\.0\.1:"' _ "$LGTM_COMPOSE"
check "the URLs printed name 127.0.0.1" has "http://127.0.0.1:3000" "$T/out"
rm -rf "$T/lgtm-data"

echo "kind: extraPortMappings listen on 127.0.0.1"
check "the generated config sets listenAddress from the bind address" \
    grep -qF 'listenAddress: "${SVC_BIND_ADDR}"' "${SVC_DIR}/kind/kind.sh"

echo
if (( FAILS )); then echo "${FAILS} check(s) failed"; exit 1; fi
echo "all checks passed"
