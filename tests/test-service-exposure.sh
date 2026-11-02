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
#   - Saved settings: dozzle, lgtm, bazzite-utils and lmstudio wrote
#     KEY="<raw value>" and `source`d the file back, so a value with a quote,
#     $(...) or a backtick ran as code. They are written with %q and parsed;
#     such a value round-trips and runs nothing, and an old file still reads.
#   - Declining: `gum confirm ... || return` returns 1, and a menu calling
#     the function bare under set -e then ended the whole TUI. Declining (or
#     cancelling kind's create) goes back to the menu now.
#   - Port-forward PID files: /tmp/scomp-pf-<svc>.pid could be planted (or
#     symlinked) by another local user, and pf_stop killed the PID it read.
#     They live in a per-user 0700 folder, and a symlink or a file that is
#     not the user's is never read or signalled.
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

# ------------------------------------------------------------ saved settings
PWN="$T/pwned"
EVIL="\$(touch $PWN)"          # what a sourced file would run
nothing_ran() { [[ ! -e "$PWN" && ! -e "$T/work/pwned" ]]; }

echo "conf.sh: values round-trip and run nothing"
check "a value with \$(...), backticks, quotes, |, &, a newline, non-ASCII round-trips" \
    bash -c 'warn() { echo "$1" >&2; }; source "$1/_common/conf.sh"; f="$2/rt.conf"
        for v in "$3" "\`touch $4\`" "a \"b\" '"'"'c'"'"' d" "x|y&z\\w" $'"'"'two\nlines'"'"' "é→" ""; do
            K="$v"; conf_write "$f" K; K=unset; conf_load "$f" K
            [[ "$K" == "$v" && "$(conf_get "$f" K)" == "$v" ]] || { echo "lost: [$v] -> [$K]" >&2; exit 1; }
        done' _ "$SVC_DIR" "$T" "$EVIL" "$PWN"
check "...and ran nothing" nothing_ran
check "an old-style KEY=\"\$(...)\" line is read as text, not run" \
    bash -c 'warn() { :; }; source "$1/_common/conf.sh"; printf "K=\"%s\"\n" "$3" > "$2/old.conf"
        conf_load "$2/old.conf" K; [[ "$K" == "$3" ]]' _ "$SVC_DIR" "$T" "$EVIL"
check "...and ran nothing" nothing_ran
check "a hand-edited \$(...) or ;command is never run (skipped, or read as text)" \
    bash -c 'warn() { :; }; source "$1/_common/conf.sh"; printf "K=x;touch %s\nK2=\$(touch %s)\n" "$3" "$3" > "$2/bad.conf"
        K=keep K2=keep; conf_load "$2/bad.conf" K K2; [[ "$K" == "x;touch $3" && "$K2" == keep ]]' _ "$SVC_DIR" "$T" "$PWN"
check "...and ran nothing" nothing_ran
check "only the keys asked for are set" \
    bash -c 'warn() { :; }; source "$1/_common/conf.sh"; printf "PATH=/nowhere\nK=v\n" > "$2/keys.conf"
        conf_load "$2/keys.conf" K; [[ "$K" == v && "$PATH" != /nowhere ]]' _ "$SVC_DIR" "$T"

DOZZLE_CONF="$HOME/.config/dozzle/dozzle.conf"
echo "dozzle: an older config holding \$(...) is not run"
svc_reset; rm -rf "$HOME/.config"; mkdir -p "${DOZZLE_CONF%/*}"
printf '%s\n' 'TARGET_TYPE="docker"' "DOZZLE_VERSION=\"$EVIL\"" 'STORAGE_MODE="bind"' > "$DOZZLE_CONF"
svc_cmd dozzle status
check "status runs (exit 0)" rc_is 0
check "the \$(...) in the config did not run" nothing_ran

echo "dozzle: a data path with quotes and \$(...) round-trips"
svc_reset; rm -rf "$HOME/.config"
ODD="$T/d \"q\" 'a' $EVIL"
svc_cmd dozzle install no "$ODD"
check "install finishes (exit 0)" rc_is 0
check "the config was saved" test -f "$DOZZLE_CONF"
svc_cmd dozzle uninstall no
check "uninstall reads it back exactly (the confirm names it)" has "deletes its data folder ${ODD} " "$T/out"
check "nothing ran" nothing_ran
rm -rf "$ODD"

LGTM_CONF="$HOME/.config/lgtm/lgtm.conf"
echo "lgtm: an older config holding \$(...) is not run"
svc_reset; rm -rf "$HOME/.config"; mkdir -p "${LGTM_CONF%/*}"
: > "$T/compose.yml"
printf '%s\n' 'TARGET_TYPE="docker"' 'ENABLED_COMPONENTS="grafana"' "COMPOSE_FILE=\"$T/compose.yml\"" \
    "NFS_SERVER=\"$EVIL\"" > "$LGTM_CONF"
svc_cmd lgtm status
check "status runs (exit 0)" rc_is 0
check "the \$(...) in the config did not run" nothing_ran

echo "lgtm: a base path with | & quotes and \$(...) round-trips"
svc_reset; rm -rf "$HOME/.config"
ODD="$T/l a|b&c \"q\" $EVIL"
svc_cmd lgtm install 'Grafana' "$ODD"
check "install finishes (exit 0)" rc_is 0
check "HOSTPATH_BASE reads back exactly" \
    bash -c 'warn() { :; }; source "$1/_common/conf.sh"; [[ "$(conf_get "$2" HOSTPATH_BASE)" == "$3" ]]' _ "$SVC_DIR" "$LGTM_CONF" "$ODD"
svc_cmd lgtm purge yes
check "purge names the folder it deletes" has "  $ODD" "$T/out"
check "...and deletes it" test ! -e "$ODD"
check "nothing ran" nothing_ran

BZ_CONF="$HOME/.config/bazzite-utils/bazzite-utils.conf"
echo "bazzite-utils: an EA prefix with quotes and \$(...) round-trips"
svc_reset; rm -rf "$HOME/.config"
ODD="$T/ea \"q\" 'a' $EVIL"
svc_cmd bazzite-utils ea-fix "$ODD"
check "the prefix was saved" test -f "$BZ_CONF"
svc_cmd bazzite-utils ea-fix no "$T/elsewhere"
check "the next run offers it back exactly" has "Use saved EA prefix: ${ODD} ?" "$T/out"
check "nothing ran" nothing_ran

# ----------------------------------------------------------------- declining
echo "_templates/service.sh: declining the uninstall confirm returns to the menu"
svc_reset
mkdir -p "$STUB_STATE/c/foo"; : > "$STUB_STATE/c/foo/env"
printf '%s\n' "" uninstall no status "← back" > "$GUM_ANSWERS"; : > "$GUM_STATE"; : > "$STUB_LOG"
(cd "$T/work" && bash "${SVC_DIR}/_templates/service.sh" > "$T/out" 2>&1 < /dev/null); echo $? > "$T/rc"
check "the script finishes (exit 0)" rc_is 0
check "nothing was removed" bash -c "! grep -q '^docker rm' '$STUB_LOG'"
check "the next pick (status) ran" grep -q '^docker ps -a --filter name=^/foo\$' "$STUB_LOG"
check "the TUI said Bye" has "Bye." "$T/out"

echo "kind: a cancelled create returns to the menu"
svc_reset
printf '#!/usr/bin/env bash\necho "mise 2099.1.1-stub"\n' > "$T/bin/mise"; chmod +x "$T/bin/mise"
svc_run kind "Create new cluster" "Bad_Name" "Refresh" "Quit"
check "the script finishes (exit 0)" rc_is 0
check "the bad name is refused" has "Invalid cluster name 'Bad_Name'" "$T/out"
check "the menu came back (Refresh and Quit were read)" bash -c "[[ \$(cat '$GUM_STATE') -ge 4 ]]"
check "the TUI said Bye" has "Bye!" "$T/out"
echo kind-1 > "$STUB_STATE/kind-clusters"
svc_run kind "── create new cluster ──" "kind-1" "Cancel" "── quit ──"
check "declining to recreate an existing cluster: exit 0" rc_is 0
check "...nothing was deleted" bash -c "! grep -q '^kind delete' '$STUB_LOG'"
check "...and the TUI said Bye" has "Bye!" "$T/out"
rm -f "$T/bin/mise"

# ----------------------------------------------------------------- PID files
PF() {   # PF <bash code> - runs it with ui.sh and portforward.sh sourced
    bash -c 'source "$1/_common/ui.sh"; source "$1/_common/portforward.sh"; eval "$2"' _ "$SVC_DIR" "$1"
}
mode() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }   # GNU, else BSD
export SVC_DIR; export -f PF mode
PFDIR="$XDG_RUNTIME_DIR/scomp-link/pf"
echo "portforward.sh: PID files live in a per-user 0700 folder"
check "pf_file grafana is under \$XDG_RUNTIME_DIR/scomp-link/pf" \
    bash -c '[[ "$(PF "pf_file grafana")" == "$1/grafana.pid" ]]' _ "$PFDIR"
check "the folder is mode 700" bash -c '[[ "$(mode "$1")" == 700 ]]' _ "$PFDIR"
check "without \$XDG_RUNTIME_DIR it is ~/.cache/scomp-link/pf, also 700" \
    bash -c 'f="$(XDG_RUNTIME_DIR= PF "pf_file x")"; d="$HOME/.cache/scomp-link/pf"
        [[ "$f" == "$d/x.pid" && "$(mode "$d")" == 700 ]]'
check "a folder left 755 is tightened to 700" \
    bash -c 'chmod 755 "$1"; PF "pf_dir" >/dev/null; [[ "$(mode "$1")" == 700 ]]' _ "$PFDIR"

echo "portforward.sh: a planted symlink is refused"
/bin/sleep 300 & VICTIM=$!
printf '%s:5432\n' "$VICTIM" > "$T/elsewhere.pid"
ln -sf "$T/elsewhere.pid" "$PFDIR/postgres.pid"
check "pf_is_running does not follow it" bash -c '! PF "pf_is_running \"$1\""' _ "$PFDIR/postgres.pid"
check "pf_port does not read it" bash -c '[[ -z "$(PF "pf_port \"$1\"")" ]]' _ "$PFDIR/postgres.pid"
PF "pf_stop '$PFDIR/postgres.pid'" > "$T/pfout" 2>&1
check "pf_stop refuses it and says so" has "Refusing PID file" "$T/pfout"
check "...and the PID it pointed at was not signalled" kill -0 "$VICTIM"
check "a pid file in a group/other-writable folder is refused" \
    bash -c 'mkdir -p "$1/open"; chmod 777 "$1/open"; printf "%s:1\n" "$2" > "$1/open/x.pid"; ! PF "pf_is_running \"$1/open/x.pid\""' _ "$T" "$VICTIM"
check "pf_write replaces a symlink instead of writing through it" \
    bash -c 'PF "pf_write \"$1\" 123 5432"; [[ ! -L "$1" && "$(cat "$1")" == 123:5432 && "$(cat "$2")" == "$3:5432" ]]' \
    _ "$PFDIR/postgres.pid" "$T/elsewhere.pid" "$VICTIM"
rm -f "$PFDIR/postgres.pid"

echo "grafana k8s: the menu reads the forward from the per-user folder"
svc_reset
touch "$STUB_STATE/no-docker"; echo stub-ctx > "$STUB_STATE/contexts"
printf '%s:9999\n' "$VICTIM" > "$PFDIR/grafana.pid"
svc_run grafana "" "" "← back"
check "the menu shows the running forward" has "connect  [● localhost:9999]" "$T/out"
ln -sf "$T/elsewhere.pid" "$PFDIR/grafana.pid"
svc_run grafana "" "" "← back"
check "a symlinked PID file shows as stopped" has "connect  [○ stopped]" "$T/out"
rm -f "$PFDIR/grafana.pid"
kill "$VICTIM" 2>/dev/null
check "no script names a /tmp/scomp-pf PID file any more" \
    bash -c '! grep -rn "/tmp/scomp-pf" "$1" --include="*.sh" | grep -v "_common/portforward.sh"' _ "$SVC_DIR"

echo
if (( FAILS )); then echo "${FAILS} check(s) failed"; exit 1; fi
echo "all checks passed"
