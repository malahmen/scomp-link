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
# shellcheck disable=SC2046
# $(rep N value) is split on purpose: one argument per scripted handshake.
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FRONT="${TEST_DIR}/../scripts/kessel-run/kessel-run.sh"
[[ -f "$FRONT" ]] || { echo "kessel-run not found at $FRONT" >&2; exit 1; }
command -v jq &>/dev/null || { echo "SKIP - jq is not installed (the LAN test parses iperf3's JSON with it)" >&2; exit 77; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
T="$(cd "$T" && pwd)"
mkdir -p "$T/stub" "$T/home/.ssh" "$T/tcp"
# The real timeout, taken before the stub that times handshakes shadows it.
LIMIT_CMD="$(command -v timeout || command -v gtimeout || true)"
# The PATH before the stubs, for the sandbox without timeout (section 15).
SYS_PATH="$PATH"
export PATH="${TEST_DIR}/stubs:$T/stub:$PATH"
export GUM_ANSWERS="$T/answers" GUM_STATE="$T/state"
export HOME="$T/home" XDG_CONFIG_HOME="$T/home/.config"
export CALLS="$T/calls" STUBDIR="$T"

FAILS=0
check() { local d="$1"; shift; if "$@"; then echo "   ok   - $d"; else echo "   FAIL - $d"; FAILS=$((FAILS + 1)); fi; }
has()   { case "$2" in *"$1"*) return 0 ;; *) return 1 ;; esac; }

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
    wc -c < "$f" | tr -d " " > "$STUBDIR/upload-size"   # BSD wc pads, BSD stat has no -c
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

# mtr: prints $STUBDIR/mtr.json (exit 1 without it, as an mtr that cannot
# send probes). tracepath: prints $STUBDIR/tracepath.txt.
cat > "$T/stub/mtr" <<'STUB'
#!/usr/bin/env bash
printf 'mtr %s\n' "$*" >> "$CALLS"
[[ -f "$STUBDIR/mtr.json" ]] || exit 1
cat "$STUBDIR/mtr.json"
STUB
cat > "$T/stub/tracepath" <<'STUB'
#!/usr/bin/env bash
printf 'tracepath %s\n' "$*" >> "$CALLS"
cat "$STUBDIR/tracepath.txt" 2>/dev/null
STUB
# traceroute: prints $STUBDIR/traceroute.txt; nothing (no route) without it.
# Stubbed always: macOS has a real one, which would probe the network.
cat > "$T/stub/traceroute" <<'STUB'
#!/usr/bin/env bash
printf 'traceroute %s\n' "$*" >> "$CALLS"
cat "$STUBDIR/traceroute.txt" 2>/dev/null
STUB

# timeout: kessel-run's handshake timer runs `timeout N bash -c ... _ host
# port`. This answers from $STUBDIR/tcp/<host>_<port>, one line per
# connection in turn (cycling): microseconds, or F for no answer (exit 124).
# No file: the port refuses (exit 1).
cat > "$T/stub/timeout" <<'STUB'
#!/usr/bin/env bash
host="${*: -2:1}" port="${*: -1}"
printf 'tcp %s %s\n' "$host" "$port" >> "$CALLS"
printf '%s\n' "$2" >> "$STUBDIR/child"    # the shell that times the handshake
f="$STUBDIR/tcp/${host}_${port}"
[[ -f "$f" ]] || exit 1
n="$(cat "$f.n" 2>/dev/null || echo 0)"; echo $((n + 1)) > "$f.n"
total="$(grep -c . "$f")"
v="$(sed -n "$(( n % total + 1 ))p" "$f")"
[[ "$v" == F ]] && exit 124
echo "$v"
STUB

# ip: no route information, so the link speed line is simply left out.
printf '#!/usr/bin/env bash\nexit 0\n' > "$T/stub/ip"
chmod +x "$T/stub/"*

reset() { : > "$CALLS"; rm -f "$T/http" "$T/curl-rc" "$T/rtt-n" "$T/refusals" "$T/remote-iperf3" "$T/upload-size" "$T/mtr.json" "$T/tracepath.txt" "$T/traceroute.txt" "$T/child"; rm -rf "$T/tcp"; mkdir -p "$T/tcp"; }
export KESSEL_RUN_HANDSHAKE_GAP=0

# mtr_hops "host loss avg worst" ... - the stub's JSON, as mtr -j writes it.
mtr_hops() {
    local i=0 h l a w out=""
    for spec in "$@"; do
        read -r h l a w <<< "$spec"; i=$((i + 1))
        out+="${out:+,}{\"count\":$i,\"host\":\"$h\",\"Loss%\":$l,\"Snt\":20,\"Last\":$a,\"Avg\":$a,\"Best\":$a,\"Wrst\":$w,\"StDev\":0.1}"
    done
    printf '{"report":{"mtr":{"src":"t","dst":"x","tests":20},"hubs":[%s]}}\n' "$out" > "$T/mtr.json"
}
# tcp <host> <port> <value>... - the handshake times (us) or F, in turn.
tcp() { local h="$1" p="$2"; shift 2; printf '%s\n' "$@" > "$T/tcp/${h}_${p}"; }
# n copies of a value
rep() { local n="$1" v="$2"; for ((k = 0; k < n; k++)); do echo "$v"; done; }
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
check "the last host is offered first"                    bash -c 'grep "<option>" <<<"$OUT" | sed -n 5p | grep -q "last: meksha"'
check "and not offered twice"                             [ "$(grep -c '<option> .*meksha' <<<"$OUT")" = 1 ]
check "picking it runs the test"                          has "Download   935.5 Mbit/s" "$OUT"

echo "## 8. path: hops, handshakes to the private ones only, the stalling router named"
reset
mtr_hops "192.168.3.1 0 2.9 3.5" "192.168.1.1 5 4.0 5.2" "5.158.0.3 70 8.8 9.7" "??? 100 0 0" "1.1.1.1 0 9.1 10.7"
# The Huawei: 2.7 ms, but 3 handshakes of 400 ms and 1 with no answer, in 20.
tcp 192.168.3.1 80 $(rep 16 2700) 400000 400000 400000 F
# The Vodafone answers only on 53.
tcp 192.168.1.1 53 $(rep 20 3000)
tcp 1.1.1.1 443 $(rep 20 9000)
run path --handshakes 20 --cycles 7
check "it exits 0"                                        [ "$RC" = 0 ]
check "mtr ran numeric, JSON, with the cycles, to the default target"  grep -q '^mtr -n -j -c 7 1.1.1.1$' "$CALLS"
check "the trace tool is named"                           has "Trace      mtr, 7 cycles" "$OUT"
check "every hop is listed, the silent one as ???"        bash -c 'for h in 192.168.3.1 192.168.1.1 5.158.0.3 "???" ; do grep -q "  $h " <<<"$OUT" || exit 1; done'
check "hop 1: port 80, median, worst, slow count"         bash -c 'grep -E "^ +1 +192\.168\.3\.1 +0% +2\.9 +3\.5 +:80 +2\.7 +400\.0 +4/20$" <<<"$OUT"'
check "hop 2: 80 and 443 refuse, 53 is used"              bash -c 'grep -q "tcp 192.168.1.1 80" "$CALLS" && grep -q "tcp 192.168.1.1 443" "$CALLS" && grep -E "^ +2 +192\.168\.1\.1 .*:53 +3\.0 +3\.0 +0/20$" <<<"$OUT"'
check "no handshake to a public hop"                      bash -c '! grep -q "tcp 5.158.0.3" "$CALLS"'
check "the target row: port 443, no stall"                bash -c 'grep -E "→ +1\.1\.1\.1 +:443 +9\.0 +9\.0 +0/20$" <<<"$OUT"'
check "the stalling router is named, with the numbers"    has "Hop 1 (192.168.3.1) stalls new connections to itself: 3 of 20 handshakes took over 100 ms (worst 400.0 ms, median 2.7 ms), 1 of 20 got no answer within 3 s, while it answers trace probes in 2.9 ms" "$OUT"
check "forwarded connections fine: said so, not blamed"   has "Connections through it to 1.1.1.1 did not stall in this run" "$OUT"
check "loss at middle hops only is explained away"        has "Hops 2 (192.168.1.1), 3 (5.158.0.3) lose trace replies, but the target does not" "$OUT"
check "no 'nothing wrong' alongside a finding"            bash -c '! grep -q "Nothing wrong found" <<<"$OUT"'

echo "## 9. path: two routers stall - the first is blamed - and the target through them"
reset
mtr_hops "192.168.3.1 0 2.9 3.5" "192.168.1.1 0 4.0 5.0" "1.1.1.1 0 9.1 10.7"
tcp 192.168.3.1 80 $(rep 17 2700) 400000 400000 400000
tcp 192.168.1.1 80 $(rep 17 3000) 500000 500000 500000
tcp 1.1.1.1 443 $(rep 17 9000) 450000 450000 450000
run path --handshakes 20
check "the first stalling router is the one blamed"        has "Verdict    Hop 1 (192.168.3.1) stalls new connections to itself" "$OUT"
check "the one behind it is named as maybe its stalls"     has "Hop 2 stalls too, but connections to it pass through hop 1" "$OUT"
check "connections through it stalled too: restart advice" has "Connections through it to 1.1.1.1 stalled too (3 of 20 over 100 ms, worst 450.0 ms)" "$OUT"
check "access-point mode suggested if it persists"         has "access-point or bridge mode" "$OUT"

echo "## 9b. path: a router that only drops handshakes is flagged"
reset
mtr_hops "192.168.3.1 0 2.9 3.5" "1.1.1.1 0 9.1 10.7"
tcp 192.168.3.1 80 $(rep 19 2700) F
tcp 1.1.1.1 443 $(rep 20 9000)
run path --handshakes 20
check "one unanswered handshake is enough, said as such"   has "Hop 1 (192.168.3.1) stalls new connections to itself: 1 of 20 got no answer within 3 s, while" "$OUT"

echo "## 10. path: stalls only at the target, loss from a hop onwards, a latency step"
reset
mtr_hops "192.168.3.1 0 2.9 3.5" "10.0.0.1 0 4.0 5.0" "5.5.5.5 10 40.0 44.0" "6.6.6.6 12 42.0 45.0" "1.1.1.1 15 41.0 46.0"
tcp 192.168.3.1 80 $(rep 20 2700)
tcp 10.0.0.1 443 $(rep 20 4000)
tcp 1.1.1.1 443 $(rep 16 41000) 300000 300000 300000 F
run path --handshakes 20
check "loss traced to the hop where it starts"            has "Packets are lost from hop 3 (5.5.5.5) onwards, 15% at the target" "$OUT"
check "target stalls with clean routers: beyond your network" has "New connections to 1.1.1.1 stall (3 of 20 over 123 ms, worst 300.0 ms) but none of your routers does" "$OUT"
check "the latency step is located"                       has "Latency rises by 36.0 ms at hop 3 (5.5.5.5) and stays up" "$OUT"
check "the slow threshold follows a distant target's median (3 x 41)"  bash -c 'grep -E "→ +1\.1\.1\.1 +:443 +41\.0 +300\.0 +4/20$" <<<"$OUT"'

echo "## 11. path: a clean path, a closed router, private and public ranges"
reset
mtr_hops "172.31.255.1 0 1.0 1.5" "172.32.0.1 0 3.0 4.0" "100.100.0.1 0 5.0 6.0" "192.168.9.1 0 6.0 7.0" "1.1.1.1 0 9.0 10.0"
tcp 172.31.255.1 22 $(rep 20 900)
tcp 100.100.0.1 80 $(rep 20 5000)
tcp 1.1.1.1 443 $(rep 20 9000)
run path --handshakes 20
check "172.31/12 and 100.64/10 are private: probed"       bash -c 'grep -q "tcp 172.31.255.1 80" "$CALLS" && grep -q "tcp 100.100.0.1 80" "$CALLS"'
check "172.32 is public: not probed"                      bash -c '! grep -q "tcp 172.32.0.1" "$CALLS"'
check "a router on port 22 is timed there"                bash -c 'grep -E "^ +1 +172\.31\.255\.1 .*:22 +0\.9" <<<"$OUT"'
check "a router answering no port is said so"             has "Hop 4 (192.168.9.1) accepts none of ports 80 443 53 22" "$OUT"
check "and shown as closed in the table"                  bash -c 'grep -E "^ +4 +192\.168\.9\.1 .* closed" <<<"$OUT"'
check "nothing wrong found"                               has "Nothing wrong found: no loss reaching 1.1.1.1, and no connection stalls" "$OUT"

echo "## 12. path: tracepath when mtr cannot run; neither is an error"
reset
cat > "$T/tracepath.txt" <<'TP'
 1?: [LOCALHOST]                      pmtu 1500
 1:  192.168.3.1                                           2.539ms
 1:  192.168.3.1                                           1.887ms
 2:  192.168.1.1                                           3.609ms
 3:  no reply
 4:  83.174.50.140                                         9.344ms asymm  5
     Too many hops: pmtu 1500
TP
tcp 192.168.3.1 80 $(rep 20 2000)
tcp 192.168.1.1 80 $(rep 20 3000)
tcp 1.1.1.1 443 $(rep 20 9000)
run path --handshakes 20
check "tracepath is used and named"                       has "Trace      tracepath, 1 probe per hop (no loss figure)" "$OUT"
check "its first time per hop, no loss figure"            bash -c 'grep -E "^ +1 +192\.168\.3\.1 +- +2\.5 +2\.5" <<<"$OUT"'
check "a hop with no reply is ???"                        bash -c 'grep -E "^ +3 +\?\?\? " <<<"$OUT"'
check "the last hop parsed despite its asymm note"        bash -c 'grep -E "^ +4 +83\.174\.50\.140 +- +9\.3" <<<"$OUT"'
reset
run path
check "no tool traces: it says so, and what to install"   has "No route trace: mtr, tracepath and traceroute all failed" "$OUT"
check "and exits non-zero"                                [ "$RC" != 0 ]

echo "## 13. path: options and the menu"
reset
run path --cycles 0
check "--cycles 0 is refused"                             has "--cycles must be a whole number above zero" "$OUT"
run path --port 70000
check "a port above 65535 is refused"                     has "--port must be at most 65535" "$OUT"
run path a.example b.example
check "two targets are refused"                           has "path: one target only" "$OUT"
reset
mtr_hops "192.168.3.1 0 2.0 3.0" "9.9.9.9 0 9.0 10.0"
tcp 192.168.3.1 80 $(rep 40 2000)
tcp 9.9.9.9 443 $(rep 40 9000)
printf '%s\n' "path     — every hop on the way, and which one is slow" "9.9.9.9" "no" > "$GUM_ANSWERS"; echo 0 > "$GUM_STATE"
OUT="$(limited bash "$FRONT" </dev/null 2>&1)"
check "the menu offers path and runs it to the typed target" bash -c 'grep -q "^mtr -n -j -c 20 9.9.9.9$" "$CALLS" && grep -q "Nothing wrong found: no loss reaching 9.9.9.9" <<<"$OUT"'

echo "## 14. path: traceroute when mtr and tracepath give nothing (macOS has only it)"
reset
cat > "$T/traceroute.txt" <<'TR'
traceroute to 1.1.1.1 (1.1.1.1), 30 hops max, 40 byte packets
 1  192.168.3.1  2.512 ms
 2  *
 3  83.174.50.140  9.344 ms
TR
tcp 192.168.3.1 80 $(rep 20 2000)
tcp 1.1.1.1 443 $(rep 20 9000)
run path --handshakes 20
check "it exits 0"                                        [ "$RC" = 0 ]
check "traceroute is used and named"                      has "Trace      traceroute, 1 probe per hop (no loss figure)" "$OUT"
check "numeric, one probe per hop"                        grep -q '^traceroute -n -q 1 -w 2 -m 30 1.1.1.1$' "$CALLS"
check "its time per hop, no loss figure"                  bash -c 'grep -E "^ +1 +192\.168\.3\.1 +- +2\.5 +2\.5" <<<"$OUT"'
check "a hop with no reply is ???"                        bash -c 'grep -E "^ +2 +\?\?\? " <<<"$OUT"'

echo "## 15. path: handshakes are timed by the bash running the script, not the first on PATH"
check "the child is \$BASH, an absolute path"           bash -c '[[ "$(sort -u "$1")" == "$2" ]]' _ "$T/child" "$(command -v bash)"

echo "## 16. path without timeout: gtimeout, or coreutils offered"
# A PATH with everything this machine has except timeout, gtimeout and brew,
# so the case is the same on Linux (which has timeout) and macOS.
mkdir -p "$T/sys" "$T/stub2" "$T/gt" "$T/brewdir"
IFS=: read -r -a sysdirs <<< "$SYS_PATH"
for d in "${sysdirs[@]}"; do
    for f in "$d"/*; do
        b="${f##*/}"
        case "$b" in timeout|gtimeout|brew) continue ;; esac
        [[ -x "$f" && ! -e "$T/sys/$b" ]] && ln -s "$f" "$T/sys/$b"
    done
done
for f in "$T/stub/"*; do [[ "${f##*/}" == timeout ]] || cp "$f" "$T/stub2/"; done
cat > "$T/brewdir/brew" <<STUB
#!/usr/bin/env bash
printf 'brew %s\n' "\$*" >> "\$CALLS"
[[ "\$*" == "install coreutils" ]] && cp "$T/stub/timeout" "$T/gt/gtimeout"
exit 0
STUB
chmod +x "$T/brewdir/brew"
NOTO_PATH="${TEST_DIR}/stubs:$T/stub2:$T/gt:$T/sys"
path_noto() { OUT="$(PATH="$1" limited "$(command -v bash)" "$FRONT" path 9.9.9.9 --handshakes 3 </dev/null 2>&1)"; RC=$?; }
setup16() { reset; mtr_hops "192.168.3.1 0 2.0 3.0" "9.9.9.9 0 9.0 10.0"; tcp 192.168.3.1 80 $(rep 9 2000); tcp 9.9.9.9 443 $(rep 9 9000); rm -f "$T/gt/gtimeout"; : > "$GUM_ANSWERS"; echo 0 > "$GUM_STATE"; }

setup16
cp "$T/stub/timeout" "$T/gt/gtimeout"
path_noto "$NOTO_PATH"
check "gtimeout alone: it is used, and path runs"         bash -c '[[ "$1" == 0 ]] && grep -q "^tcp 9.9.9.9 443$" "$2"' _ "$RC" "$CALLS"

setup16
printf '%s\n' yes > "$GUM_ANSWERS"
path_noto "$T/brewdir:$NOTO_PATH"
check "neither, with Homebrew: coreutils is offered and installed" grep -q '^brew install coreutils$' "$CALLS"
check "...and path then runs with gtimeout"               bash -c '[[ "$1" == 0 ]] && grep -q "^tcp 9.9.9.9 443$" "$2"' _ "$RC" "$CALLS"

setup16
printf '%s\n' no > "$GUM_ANSWERS"
path_noto "$T/brewdir:$NOTO_PATH"
check "declined: it says why and stops"                   bash -c '[[ "$1" != 0 ]] && grep -q "path needs timeout (coreutils) to bound each handshake" <<<"$2"' _ "$RC" "$OUT"
check "...and installs nothing"                           bash -c '! grep -q "^brew install" "$1"' _ "$CALLS"

echo
if (( FAILS )); then echo "FAIL - ${FAILS} check(s) failed"; exit 1; fi
echo "PASS"
