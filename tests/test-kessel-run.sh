#!/usr/bin/env bash
# kessel-run, with curl, ssh, iperf3 and ip stubbed: no network.
#
# What it protects: the numbers. Latency is the TCP handshake (connect minus
# DNS) and its median/min/max/jitter are computed from known samples; a
# refused or rate-limited transfer must stop with the reason, not print a
# speed; Cloudflare's CRLF headers must not leak a CR into the report (the
# bug wine-focus-fix had); the LAN test must connect to the ssh alias's real
# HostName, start a one-shot server bounded by timeout, retry while it comes
# up, report what the receiver got, and never install anything remotely.
# shellcheck disable=SC2016
# The single quotes around `bash -c` bodies are the point: the child expands
# $OUT itself, from the environment, which is why it is exported.
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FRONT="${TEST_DIR}/../scripts/kessel-run/kessel-run.sh"
[[ -f "$FRONT" ]] || { echo "kessel-run not found at $FRONT" >&2; exit 1; }
command -v jq &>/dev/null || { echo "SKIP - jq is not installed (the LAN test parses iperf3's JSON with it)" >&2; exit 77; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
T="$(cd "$T" && pwd)"
mkdir -p "$T/stub" "$T/home/.ssh"
export PATH="${TEST_DIR}/stubs:$T/stub:$PATH"
export GUM_ANSWERS="$T/answers" GUM_STATE="$T/state"
export HOME="$T/home" XDG_CONFIG_HOME="$T/home/.config"
export CALLS="$T/calls" STUBDIR="$T"

FAILS=0
check() { local d="$1"; shift; if "$@"; then echo "   ok   - $d"; else echo "   FAIL - $d"; FAILS=$((FAILS + 1)); fi; }
has()   { case "$2" in *"$1"*) return 0 ;; *) return 1 ;; esac; }

if command -v timeout &>/dev/null; then LIMIT_CMD=timeout; else LIMIT_CMD=""; fi
limited() { if [[ -n "$LIMIT_CMD" ]]; then "$LIMIT_CMD" 60 "$@"; else "$@"; fi; }

# ---- stubs ------------------------------------------------------------------
# curl: headers for -D -, handshake times for the latency -w, and 0.2 s per
# transfer so a timed stream makes a handful of requests, not thousands.
# $STUBDIR/http (a status) and $STUBDIR/curl-rc (an exit code) make it fail.
cat > "$T/stub/curl" <<'STUB'
#!/usr/bin/env bash
printf 'curl %s\n' "$*" >> "$CALLS"
args=" $* "
if [[ "$args" == *" -D - "* ]]; then
    printf 'HTTP/1.1 200 OK\r\ncolo: LIS\r\nasn: 12353\r\ncf-meta-ip: 203.0.113.7\r\ncity: Somewhere\r\n\r\n'
    exit 0
fi
if [[ "$args" == *"time_connect"* ]]; then
    # DNS 2 ms, then these TCP handshakes in turn: 10 12 10 11 500 10 ...
    n="$(cat "$STUBDIR/rtt-n" 2>/dev/null || echo 0)"; echo $((n + 1)) > "$STUBDIR/rtt-n"
    ms=(10 12 10 11 500 10 12 10 11 10 10 12 10 11 10 10 12 10 11 10)
    awk -v t="${ms[$((n % 20))]}" 'BEGIN { printf "0.002 %.4f", 0.002 + t / 1000 }'
    exit 0
fi
rc="$(cat "$STUBDIR/curl-rc" 2>/dev/null || echo 0)"
code="$(cat "$STUBDIR/http" 2>/dev/null || echo 200)"
if [[ "$args" == *"--data-binary @"* ]]; then
    f="${args#*--data-binary @}"; f="${f%% *}"
    stat -c %s "$f" > "$STUBDIR/upload-size" 2>/dev/null || wc -c < "$f" > "$STUBDIR/upload-size"
fi
sleep 0.2
printf '1000000 %s' "$code"
exit "$rc"
STUB

# ssh: -G resolves the alias, `command -v iperf3` answers from
# $STUBDIR/remote-iperf3 (default present), everything else succeeds.
cat > "$T/stub/ssh" <<'STUB'
#!/usr/bin/env bash
printf 'ssh %s\n' "$*" >> "$CALLS"
if [[ "${1:-}" == -G ]]; then printf 'user me\nhostname 10.0.0.9\nport 22\n'; exit 0; fi
case "${*: -1}" in
    "command -v iperf3") [[ "$(cat "$STUBDIR/remote-iperf3" 2>/dev/null || echo yes)" == yes ]] && { echo /usr/bin/iperf3; exit 0; }; exit 1 ;;
esac
exit 0
STUB

# iperf3: refuses the first $STUBDIR/refusals connections (the server is still
# starting), then reports 941.25 Mbit/s received (-R: 935.5) as iperf3 -J does.
cat > "$T/stub/iperf3" <<'STUB'
#!/usr/bin/env bash
printf 'iperf3 %s\n' "$*" >> "$CALLS"
left="$(cat "$STUBDIR/refusals" 2>/dev/null || echo 0)"
if (( left > 0 )); then
    echo $((left - 1)) > "$STUBDIR/refusals"
    printf '{"start":{},"intervals":[],"end":{},"error":"unable to connect to server - server may have gone away: Connection refused"}\n'
    exit 1
fi
if [[ " $* " == *" -R "* ]]; then bps=935500000; else bps=941250000; fi
printf '{"end":{"sum_sent":{"bits_per_second":%s,"retransmits":12},"sum_received":{"bits_per_second":%s}}}\n' $((bps + 5000000)) "$bps"
STUB

# ip: no route information, so the link speed line is simply left out.
printf '#!/usr/bin/env bash\nexit 0\n' > "$T/stub/ip"
chmod +x "$T/stub/"*

reset() { : > "$CALLS"; rm -f "$T/http" "$T/curl-rc" "$T/rtt-n" "$T/refusals" "$T/remote-iperf3" "$T/upload-size"; }
export OUT=""
run() { OUT="$(limited bash "$FRONT" "$@" </dev/null 2>&1)"; RC=$?; }

echo "## 1. internet: server, address, latency from known handshakes, both directions"
reset
run internet --seconds 1 --streams 2
check "it exits 0"                                       [ "$RC" = 0 ]
check "the server is the colo header"                     has "Server     Cloudflare LIS" "$OUT"
check "the address and network are shown"                 has "You        203.0.113.7 (AS12353)" "$OUT"
check "no CR from the CRLF headers reaches the report"    bash -c '! grep -q $'"'"'\r'"'"' <<<"$OUT"'
check "the address's city is not shown as the server's"   bash -c '! grep -q Somewhere <<<"$OUT"'
# 20 samples, DNS subtracted: sixteen of 10-12 ms and one 500 ms spike.
# median 10.0, min 10.0, max 500.0; jitter = sum|diffs| / 19.
check "latency is the handshake: median, min, max"        has "Latency    10.0 ms (min 10.0, max 500.0," "$OUT"
check "jitter comes from consecutive differences"         has "jitter 52.7 ms, 20 handshakes)" "$OUT"
check "a download line with a speed"                      bash -c 'grep -Eq "Download   [0-9]+\.[0-9] Mbit/s \([0-9.]+ MB in [0-9.]+ s\)" <<<"$OUT"'
check "an upload line with a speed"                       bash -c 'grep -Eq "Upload     [0-9]+\.[0-9] Mbit/s \([0-9.]+ MB in [0-9.]+ s\)" <<<"$OUT"'
check "downloads ask for Cloudflare's 50 MB maximum"      grep -q '__down?bytes=50000000' "$CALLS"
check "every transfer is capped by --max-time"            bash -c '! grep -E "__down\?bytes=50000000|__up" "$CALLS" | grep -vq -- "--max-time"'
check "uploads send no Expect: 100-continue"              bash -c 'grep "__up" "$CALLS" | grep -q -- "-H Expect:"'
check "uploads send a 25 MB body"                         [ "$(cat "$T/upload-size" 2>/dev/null)" = 25000000 ]

echo "## 2. internet: a refused or failed transfer stops with the reason, no speed"
reset; echo 429 > "$T/http"
run internet --seconds 1 --streams 2
check "rate-limited: it exits non-zero"                   [ "$RC" != 0 ]
check "it says Cloudflare is rate-limiting"               has "rate-limiting this address (HTTP 429)" "$OUT"
check "no download speed is printed"                      bash -c '! grep -q "Mbit/s" <<<"$OUT"'
check "the stream stopped instead of retrying"            [ "$(grep -c '__down?bytes=50000000' "$CALLS")" -le 2 ]
reset; echo 7 > "$T/curl-rc"
run internet --seconds 1 --streams 1
check "no connection: it says so"                         has "Could not connect to https://speed.cloudflare.com (curl exit 7)" "$OUT"

echo "## 3. internet: options are checked"
reset
run internet --seconds 0
check "--seconds 0 is refused"                            has "--seconds must be a whole number above zero" "$OUT"
run internet --streams x
check "--streams x is refused"                            has "--streams must be a whole number above zero" "$OUT"
run internet --bogus
check "an unknown option is named"                        has "unknown option --bogus" "$OUT"

echo "## 4. lan over ssh: the alias's address, a one-shot server, retries, both directions"
reset; echo 2 > "$T/refusals"
run lan meksha --seconds 3 --streams 2
check "it exits 0"                                        [ "$RC" = 0 ]
check "the alias is resolved to its HostName"             has "Host       meksha (10.0.0.9)" "$OUT"
check "iperf3 connects to the address, not the alias"     bash -c '! grep "^iperf3 -c" "$CALLS" | grep -vq -- "-c 10.0.0.9 "'
check "a one-shot server bounded by timeout, via ssh -f"  grep -qF 'ssh -f -n -o BatchMode=yes -o ConnectTimeout=5 meksha timeout 33 iperf3 -s -1 -p 5201' "$CALLS"
check "one server per direction"                          [ "$(grep -c 'iperf3 -s -1' "$CALLS")" = 2 ]
check "the refused connections were retried"              [ "$(grep -c '^iperf3 -c' "$CALLS")" = 4 ]
check "streams and seconds reach iperf3"                  grep -q -- '^iperf3 -c 10.0.0.9 -p 5201 -t 3 -P 2 -J$' "$CALLS"
check "the download runs reversed"                        grep -q -- '^iperf3 -c 10.0.0.9 -p 5201 -t 3 -P 2 -J -R$' "$CALLS"
check "upload: what the receiver got, with retransmits"   has "Upload     941.2 Mbit/s (12 retransmits)" "$OUT"
check "download: the reversed test's received rate"       has "Download   935.5 Mbit/s" "$OUT"

echo "## 5. lan: iperf3 missing there is reported, never installed"
reset; echo no > "$T/remote-iperf3"
run lan meksha
check "it exits non-zero"                                 [ "$RC" != 0 ]
check "it says iperf3 is not installed there"             has "iperf3 is not installed on meksha" "$OUT"
check "nothing ran on the remote but the checks"          bash -c '! grep "^ssh" "$CALLS" | grep -Eq "apt|dnf|install|iperf3 -s"'
check "no test was attempted"                             bash -c '! grep -q "^iperf3" "$CALLS"'

echo "## 6. lan --no-ssh: straight to the host, no ssh, a refusal is not retried"
reset
run lan 192.168.1.20 --no-ssh --port 5300 --seconds 2 --streams 1
check "it exits 0"                                        [ "$RC" = 0 ]
check "no ssh at all"                                     bash -c '! grep -q "^ssh" "$CALLS"'
check "the port reaches iperf3"                           grep -q -- '^iperf3 -c 192.168.1.20 -p 5300 -t 2 -P 1 -J$' "$CALLS"
reset; echo 1 > "$T/refusals"
run lan 192.168.1.20 --no-ssh
check "refused: it names the likely causes"               has "nothing answers on 192.168.1.20:5201 - a firewall there blocks the port" "$OUT"
check "and tried once"                                    [ "$(grep -c '^iperf3 -c' "$CALLS")" = 1 ]
run lan
check "no host: it asks for one"                          has "lan: which machine?" "$OUT"
run lan 192.168.1.20 --port 70000 --no-ssh
check "a port above 65535 is refused"                     has "--port must be at most 65535" "$OUT"

echo "## 7. menu: ssh-config hosts offered, the choice remembered"
reset
printf 'Host *\n    ServerAliveInterval 30\nHost meksha\n    HostName 10.0.0.9\nHost corelia kamino\n' > "$HOME/.ssh/config"
printf '%s\n' "lan      — iperf3 to another machine" "meksha" "no" > "$GUM_ANSWERS"; echo 0 > "$GUM_STATE"
OUT="$(limited bash "$FRONT" </dev/null 2>&1)"
check "ssh-config hosts are offered"                      bash -c 'grep -q "<option> meksha" <<<"$OUT" && grep -q "<option> kamino" <<<"$OUT"'
check "a wildcard Host is not"                            bash -c '! grep -q "<option> \*" <<<"$OUT"'
check "the test ran against the pick"                     has "Host       meksha (10.0.0.9)" "$OUT"
check "the pick is saved"                                 grep -q '^LAN_HOST=meksha$' "$XDG_CONFIG_HOME/kessel-run/kessel-run.conf"
reset
printf '%s\n' "lan      — iperf3 to another machine" "last: meksha" "no" > "$GUM_ANSWERS"; echo 0 > "$GUM_STATE"
OUT="$(limited bash "$FRONT" </dev/null 2>&1)"
check "the last host is offered first"                    bash -c 'grep "<option>" <<<"$OUT" | sed -n 4p | grep -q "last: meksha"'
check "and not offered twice"                             [ "$(grep -c '<option> .*meksha' <<<"$OUT")" = 1 ]
check "picking it runs the test"                          has "Download   935.5 Mbit/s" "$OUT"

echo
if (( FAILS )); then echo "FAIL - ${FAILS} check(s) failed"; exit 1; fi
echo "PASS"
