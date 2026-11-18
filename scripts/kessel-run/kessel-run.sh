#!/usr/bin/env bash
# description: Connection speed test — internet (latency, jitter, download, upload against Cloudflare's speed endpoints) and LAN (iperf3 to another machine, started there over ssh)
# export-setup: jq
# -----------------------------------------------------------------------------
# kessel-run.sh
# How fast is the connection, and is it the internet line or the home network?
#
#   internet — latency and jitter (TCP handshakes), then download and upload
#              throughput, all against speed.cloudflare.com (the endpoints its
#              own speed test uses) with curl. Nothing to install.
#   lan      — iperf3 to another machine, both directions. Over ssh it starts
#              a one-shot iperf3 server there (`iperf3 -s -1`, bounded by
#              `timeout`), so nothing is left listening; --no-ssh tests
#              against a server that is already running.
#
# A slow internet result with a fast LAN result is the line (or the ISP); a
# slow LAN result is the network in the house - cable, switch, Wi-Fi.
#
# Usage:
#   kessel-run.sh                         menu
#   kessel-run.sh internet [--seconds N] [--streams N]
#   kessel-run.sh lan <host> [--port N] [--seconds N] [--streams N] [--no-ssh]
#
# The results go to stdout (one "Label  value" line each), the progress to
# stderr, so `kessel-run.sh internet >> speed.log` works from cron.
#
# How it measures, and what that means for the numbers:
#   - Latency is the TCP handshake time (curl's time_connect minus its DNS
#     time) of fresh connections: one round trip, without the server's own
#     processing time that a full HTTP request would add. Jitter is the mean
#     difference between consecutive samples.
#   - Throughput is the bytes moved by N parallel streams divided by the
#     wall-clock time, each stream repeating requests until the time is up.
#     Every request is capped by curl --max-time at the time left, so a slow
#     line does not overrun, and the partial bytes of the last one still
#     count. Several streams because one TCP connection rarely fills a fast
#     line; each request is a new connection, so the result is a little under
#     what a single long transfer would reach.
#   - Cloudflare refuses a download over 50 MB (HTTP 403) and may rate-limit
#     (HTTP 429): either stops the test with that code instead of a number.
#   - iperf3 reports what the receiver got (sum_received), not what the sender
#     pushed into its buffers.
#
# Sourced helpers (scripts/_common/):
#   ui.sh   — header/info/success/warn/error_exit
#   deps.sh — _ensure_pkg (dnf/apt/rpm-ostree aware), for a local iperf3
#   conf.sh — the remembered LAN host
#
# Config: ~/.config/kessel-run/kessel-run.conf (XDG-style, key=value)
# -----------------------------------------------------------------------------

if [[ "${BASH_VERSINFO[0]:-0}" -lt 4 ]]; then
    echo "[error] bash 4+ required (you have ${BASH_VERSION}). On macOS: brew install bash" >&2
    exit 1
fi

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
# shellcheck source=../_common/conf.sh
source "${COMMON_DIR}/conf.sh"

command -v gum &>/dev/null || { echo "[error] gum is required. Run setup.sh first." >&2; exit 1; }
command -v curl &>/dev/null || error_exit "curl is required: install it with your package manager."

# Decimal points in awk's output, whatever the locale (only the number
# format: the rest of the locale is left alone for gum's output).
export LC_NUMERIC=C

CF_BASE="${KESSEL_RUN_CF_BASE:-https://speed.cloudflare.com}"
DOWN_CHUNK=50000000     # Cloudflare's largest accepted download (above: HTTP 403)
UP_CHUNK=25000000
PINGS=20
SECONDS_DEFAULT=10
STREAMS_DEFAULT=4
PORT_DEFAULT=5201

CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/kessel-run"
CONFIG_FILE="${CONFIG_DIR}/kessel-run.conf"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
trap 'echo "" >&2; gum style --faint "Interrupted." >&2; exit 130' INT TERM

# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------

# Seconds since the epoch, with a fraction. EPOCHREALTIME (bash 5) uses the
# locale's decimal mark; date +%N is GNU only, hence the order.
_now() {
    if [[ -n "${EPOCHREALTIME:-}" ]]; then printf '%s' "${EPOCHREALTIME/,/.}"
    else date +%s.%N; fi
}

# _result <label> <value> - one line of the report, on stdout.
_result() { printf '  %-10s %s\n' "$1" "$2"; }

# _posint <name> <value> - a whole number above zero, or an error.
_posint() {
    [[ "$2" =~ ^[1-9][0-9]*$ ]] || error_exit "$1 must be a whole number above zero (got \"$2\")."
}

# _mbps <bytes> <seconds> - megabits per second, one decimal.
_mbps() { awk -v b="$1" -v s="$2" 'BEGIN { printf "%.1f", (s > 0) ? b * 8 / s / 1e6 : 0 }'; }

# -----------------------------------------------------------------------------
# Internet: Cloudflare
# -----------------------------------------------------------------------------

# _cf_meta - the Cloudflare location serving this machine, and its public
# address and network, from the headers of an empty download: colo (the
# data centre, an airport code; anycast, so it can change between runs), asn,
# cf-meta-ip. Its city/country headers are where the ADDRESS is, not the
# server, so they are not shown as the server's. HTTP headers end in CRLF:
# the CR is stripped, or it would be printed into the report.
_cf_meta() {
    local headers colo ip asn
    headers="$(curl -s --max-time 10 -D - -o /dev/null "${CF_BASE}/__down?bytes=0" | tr -d '\r')" \
        || error_exit "Could not reach ${CF_BASE}: is this machine online?"
    _hdr() { awk -v k="$1" 'tolower($1) == k ":" { $1 = ""; sub(/^ /, ""); print; exit }' <<< "$headers"; }
    colo="$(_hdr colo)"; ip="$(_hdr cf-meta-ip)"; asn="$(_hdr asn)"
    [[ -n "$colo" ]] || error_exit "${CF_BASE} answered without its colo header: not Cloudflare's speed endpoint?"
    _result "Server" "Cloudflare ${colo}"
    [[ -n "$ip" ]] && _result "You" "${ip}${asn:+ (AS${asn})}"
    return 0
}

# _latency - PINGS fresh TCP handshakes: "median min max jitter count", in
# ms. The max is there because one slow handshake (a lost SYN is resent after
# a second) lifts the jitter on its own, and the report should show why.
_latency() {
    local i t
    : > "$WORK/rtt"
    for ((i = 0; i < PINGS; i++)); do
        t="$(curl -s -o /dev/null --max-time 5 -w '%{time_namelookup} %{time_connect}' \
                "${CF_BASE}/__down?bytes=0")" || continue
        awk '{ printf "%.3f\n", ($2 - $1) * 1000 }' <<< "$t" >> "$WORK/rtt"
    done
    [[ -s "$WORK/rtt" ]] || return 1
    # Jitter on the samples in the order they came, the median on them sorted.
    local jitter
    jitter="$(awk 'NR > 1 { d = $1 - p; s += (d < 0 ? -d : d) } { p = $1 } END { printf "%.1f", (NR > 1) ? s / (NR - 1) : 0 }' "$WORK/rtt")"
    sort -n "$WORK/rtt" | awk -v j="$jitter" '{ v[NR] = $1 }
        END { m = (NR % 2) ? v[(NR + 1) / 2] : (v[NR / 2] + v[NR / 2 + 1]) / 2
              printf "%.1f %.1f %.1f %s %d\n", m, v[1], v[NR], j, NR }'
}

# _stream <down|up> <deadline> <out> - one stream: requests until the deadline,
# each capped at the time left. Appends "<bytes>" per request to <out>, or a
# single "ERR <what>" line and stops when a request fails for another reason
# than running out of time (curl exit 28), so a refused or broken connection
# is reported instead of being retried in a tight loop.
_stream() {
    local dir="$1" deadline="$2" out="$3" left w rc bytes code
    while :; do
        left="$(awk -v d="$deadline" -v n="$(_now)" 'BEGIN { l = d - n; if (l < 0.2) exit 1; printf "%.2f", l }')" || break
        rc=0
        if [[ "$dir" == down ]]; then
            w="$(curl -s -o /dev/null --max-time "$left" -w '%{size_download} %{http_code}' \
                    "${CF_BASE}/__down?bytes=${DOWN_CHUNK}")" || rc=$?
        else
            # No Expect: 100-continue - curl would wait up to a second for
            # the server's go-ahead before every 25 MB body.
            w="$(curl -s -o /dev/null --max-time "$left" -w '%{size_upload} %{http_code}' \
                    -H 'Expect:' --data-binary "@${WORK}/upload" "${CF_BASE}/__up")" || rc=$?
        fi
        read -r bytes code <<< "$w"
        if (( rc != 0 && rc != 28 )); then echo "ERR curl exit ${rc}" >> "$out"; break; fi
        # Only a finished request's status counts: one cut off by --max-time
        # can stop at any point (000, or an interim 100).
        if (( rc == 0 )) && [[ "$code" != 200 ]]; then echo "ERR HTTP ${code}" >> "$out"; break; fi
        echo "${bytes:-0}" >> "$out"
        (( rc == 28 )) && break
    done
}

# _throughput <down|up> <seconds> <streams> - "<mbps> <bytes> <elapsed>", or
# "ERR <what>" (exit 1).
_throughput() {
    local dir="$1" secs="$2" streams="$3" start deadline end i err
    rm -f "$WORK"/"$dir".*
    start="$(_now)"
    deadline="$(awk -v s="$start" -v d="$secs" 'BEGIN { printf "%.3f", s + d }')"
    for ((i = 0; i < streams; i++)); do
        _stream "$dir" "$deadline" "$WORK/${dir}.${i}" &
    done
    wait
    end="$(_now)"
    err="$(cat "$WORK"/"$dir".* 2>/dev/null | grep -m1 '^ERR' || true)"
    if [[ -n "$err" ]]; then printf '%s\n' "$err"; return 1; fi
    local bytes elapsed
    bytes="$(cat "$WORK"/"$dir".* 2>/dev/null | awk '{ s += $1 } END { printf "%.0f", s }')"
    elapsed="$(awk -v a="$start" -v b="$end" 'BEGIN { printf "%.2f", b - a }')"
    printf '%s %s %s\n' "$(_mbps "$bytes" "$elapsed")" "$bytes" "$elapsed"
}

_explain_err() {
    case "$1" in
        "ERR HTTP 429") echo "Cloudflare is rate-limiting this address (HTTP 429): wait a few minutes." ;;
        "ERR HTTP 403") echo "Cloudflare refused the request (HTTP 403)." ;;
        "ERR curl exit 6"|"ERR curl exit 7") echo "Could not connect to ${CF_BASE} (${1#ERR }): is this machine online?" ;;
        *) echo "The transfer failed (${1#ERR })." ;;
    esac
}

cmd_internet() {
    local secs="$SECONDS_DEFAULT" streams="$STREAMS_DEFAULT"
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --seconds) secs="${2:-}"; shift 2 || shift ;;
            --streams) streams="${2:-}"; shift 2 || shift ;;
            *) error_exit "internet: unknown option $1 (expected --seconds N, --streams N)" ;;
        esac
    done
    _posint "--seconds" "$secs"; _posint "--streams" "$streams"

    info "Internet speed against ${CF_BASE} - ${secs} s per direction, ${streams} streams."
    _cf_meta

    local lat
    if lat="$(_latency)"; then
        local med min max jit n; read -r med min max jit n <<< "$lat"
        _result "Latency" "${med} ms (min ${min}, max ${max}, jitter ${jit} ms, ${n} handshakes)"
    else
        warn "No latency sample: every handshake failed."
    fi

    local r mbps bytes elapsed
    info "Download..."
    r="$(_throughput down "$secs" "$streams")" || error_exit "Download: $(_explain_err "$r")"
    read -r mbps bytes elapsed <<< "$r"
    _result "Download" "${mbps} Mbit/s ($(awk -v b="$bytes" 'BEGIN { printf "%.1f", b / 1e6 }') MB in ${elapsed} s)"

    head -c "$UP_CHUNK" /dev/zero > "$WORK/upload"
    info "Upload..."
    r="$(_throughput up "$secs" "$streams")" || error_exit "Upload: $(_explain_err "$r")"
    read -r mbps bytes elapsed <<< "$r"
    _result "Upload" "${mbps} Mbit/s ($(awk -v b="$bytes" 'BEGIN { printf "%.1f", b / 1e6 }') MB in ${elapsed} s)"
}

# -----------------------------------------------------------------------------
# LAN: iperf3
# -----------------------------------------------------------------------------

_need_iperf3() {
    command -v iperf3 &>/dev/null && return 0
    if command -v brew &>/dev/null && gum confirm "iperf3 is not installed here. Install it with Homebrew (no reboot)?"; then
        brew install iperf3 || error_exit "brew install iperf3 failed."
    else
        gum confirm "iperf3 is not installed here. Install it with the system package manager?" \
            || error_exit "The LAN test needs iperf3 on this machine."
        _ensure_pkg iperf3 iperf3 || error_exit "iperf3 is not available yet (a layered package needs the reboot first)."
    fi
    command -v iperf3 &>/dev/null || error_exit "iperf3 is still not on the PATH."
}

# _ssh_hostname <host> - the address an ssh alias stands for (its HostName),
# because iperf3 connects by name too and cannot resolve an ssh alias.
_ssh_hostname() {
    local h
    h="$(ssh -G "$1" 2>/dev/null | awk '$1 == "hostname" { print $2; exit }')"
    printf '%s' "${h:-$1}"
}

# _link_speed <address> - the speed of the local interface that reaches it,
# when the kernel knows (Linux, wired). Empty otherwise.
_link_speed() {
    command -v ip &>/dev/null || return 0
    local dev s
    dev="$(ip route get "$1" 2>/dev/null | awk '{ for (i = 1; i < NF; i++) if ($i == "dev") { print $(i + 1); exit } }')"
    [[ -n "$dev" && -r "/sys/class/net/${dev}/speed" ]] || return 0
    s="$(cat "/sys/class/net/${dev}/speed" 2>/dev/null)" || return 0
    [[ "$s" =~ ^[0-9]+$ ]] && (( s > 0 )) && printf '%s Mbit/s (%s)' "$s" "$dev"
    return 0
}

# _iperf <host> <addr> <port> <secs> <streams> <ssh 0|1> <reverse 0|1> -
# one direction. Prints "<mbps> <retransmits|->", or the error (exit 1).
_iperf() {
    local host="$1" addr="$2" port="$3" secs="$4" streams="$5" use_ssh="$6" rev="$7"
    if (( use_ssh )); then
        # One test, then it exits; timeout ends it if the client never comes.
        # -f backgrounds ssh once the command started, -n keeps it off stdin.
        ssh -f -n -o BatchMode=yes -o ConnectTimeout=5 "$host" \
            "timeout $((secs + 30)) iperf3 -s -1 -p ${port} >/dev/null 2>&1" \
            || { echo "could not start iperf3 on ${host} over ssh"; return 1; }
    fi
    local args=(-c "$addr" -p "$port" -t "$secs" -P "$streams" -J) out err try
    (( rev )) && args+=(-R)
    # The server takes a moment to listen: a refused connection is retried.
    for ((try = 1; try <= 10; try++)); do
        out="$(iperf3 "${args[@]}" 2>/dev/null)" || true
        err="$(jq -r '.error // empty' <<< "$out" 2>/dev/null || echo "unreadable iperf3 output")"
        [[ -z "$out" ]] && err="iperf3 printed nothing"
        case "$err" in
            *"Connection refused"*|*"unable to connect"*) (( use_ssh )) && { sleep 0.5; continue; } ;;
        esac
        break
    done
    if [[ -n "$err" ]]; then
        case "$err" in
            *"Connection refused"*|*"unable to connect"*)
                echo "nothing answers on ${addr}:${port} - a firewall there blocks the port, or the iperf3 server did not start (${err})" ;;
            *) echo "$err" ;;
        esac
        return 1
    fi
    local bps rt
    read -r bps rt < <(jq -r '"\(.end.sum_received.bits_per_second // 0) \(.end.sum_sent.retransmits // "-")"' <<< "$out")
    printf '%s %s\n' "$(_mbps "$(awk -v b="$bps" 'BEGIN { printf "%.0f", b / 8 }')" 1)" "$rt"
}

cmd_lan() {
    local host="" port="$PORT_DEFAULT" secs="$SECONDS_DEFAULT" streams="$STREAMS_DEFAULT" use_ssh=1
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --port)    port="${2:-}"; shift 2 || shift ;;
            --seconds) secs="${2:-}"; shift 2 || shift ;;
            --streams) streams="${2:-}"; shift 2 || shift ;;
            --no-ssh)  use_ssh=0; shift ;;
            -*) error_exit "lan: unknown option $1 (expected --port N, --seconds N, --streams N, --no-ssh)" ;;
            *)  [[ -z "$host" ]] || error_exit "lan: one host only (got \"$host\" and \"$1\")."
                host="$1"; shift ;;
        esac
    done
    [[ -n "$host" ]] || error_exit "lan: which machine? kessel-run.sh lan <host>"
    _posint "--port" "$port"; _posint "--seconds" "$secs"; _posint "--streams" "$streams"
    (( port <= 65535 )) || error_exit "--port must be at most 65535."
    command -v jq &>/dev/null || error_exit "jq is required for the LAN test: install it with your package manager."
    _need_iperf3

    local addr="$host"
    if (( use_ssh )); then
        addr="$(_ssh_hostname "$host")"
        ssh -n -o BatchMode=yes -o ConnectTimeout=5 "$host" 'command -v iperf3' >/dev/null 2>&1 || {
            ssh -n -o BatchMode=yes -o ConnectTimeout=5 "$host" true >/dev/null 2>&1 \
                || error_exit "Cannot ssh to ${host} without a password prompt (BatchMode): set up a key for it first."
            error_exit "iperf3 is not installed on ${host}. Install it there (sudo apt install iperf3 / sudo dnf install iperf3) - this script installs nothing on other machines."
        }
    fi

    info "LAN speed to ${host}$([[ "$addr" != "$host" ]] && printf ' (%s)' "$addr"):${port} - ${secs} s per direction, ${streams} streams."
    _result "Host" "${host}$([[ "$addr" != "$host" ]] && printf ' (%s)' "$addr")"
    local link; link="$(_link_speed "$addr")"
    [[ -n "$link" ]] && _result "Link" "$link"

    local r mbps rt
    info "Upload (this machine -> ${host})..."
    r="$(_iperf "$host" "$addr" "$port" "$secs" "$streams" "$use_ssh" 0)" || error_exit "Upload: ${r}"
    read -r mbps rt <<< "$r"
    _result "Upload" "${mbps} Mbit/s$([[ "$rt" != - ]] && printf ' (%s retransmits)' "$rt")"

    info "Download (${host} -> this machine)..."
    r="$(_iperf "$host" "$addr" "$port" "$secs" "$streams" "$use_ssh" 1)" || error_exit "Download: ${r}"
    read -r mbps rt <<< "$r"
    _result "Download" "${mbps} Mbit/s"
}

# -----------------------------------------------------------------------------
# Menu
# -----------------------------------------------------------------------------

# Concrete Host entries of ~/.ssh/config (no wildcards), one per line.
_ssh_hosts() {
    local f="${HOME}/.ssh/config"
    [[ -r "$f" ]] || return 0
    awk 'tolower($1) == "host" { for (i = 2; i <= NF; i++) if ($i !~ /[*?!]/) print $i }' "$f" | awk '!seen[$0]++'
}

menu_lan() {
    local LAN_HOST="" LAN_SSH=1
    conf_load "$CONFIG_FILE" LAN_HOST LAN_SSH
    local -a opts=()
    [[ -n "$LAN_HOST" ]] && opts+=("last: ${LAN_HOST}")
    local h
    while IFS= read -r h; do [[ -n "$h" && "$h" != "$LAN_HOST" ]] && opts+=("$h"); done < <(_ssh_hosts)
    opts+=("Enter a host…")
    local pick
    pick="$(gum choose "${opts[@]}" --header "Test the LAN to which machine?")" || { info "Cancelled."; return 0; }
    [[ -n "$pick" ]] || { info "Cancelled."; return 0; }
    local use_ssh=1
    case "$pick" in
        "last: "*) h="${pick#last: }"; use_ssh="$LAN_SSH" ;;
        "Enter a host…")
            h="$(gum input --placeholder "hostname or address" --prompt "Host > ")" || { info "Cancelled."; return 0; }
            [[ -n "$h" ]] || { info "Cancelled."; return 0; }
            local rc=0
            gum confirm "Start iperf3 on ${h} over ssh? (No: it already runs iperf3 -s)" || rc=$?
            case "$rc" in 0) use_ssh=1 ;; 130) info "Cancelled."; return 0 ;; *) use_ssh=0 ;; esac ;;
        *) h="$pick" ;;
    esac
    mkdir -p "$CONFIG_DIR"
    LAN_HOST="$h"; LAN_SSH="$use_ssh"
    conf_write "$CONFIG_FILE" LAN_HOST LAN_SSH
    local args=("$h"); (( use_ssh )) || args+=(--no-ssh)
    # A failed test returns to the menu instead of closing it.
    ( cmd_lan "${args[@]}" ) || true
}

main() {
    if [[ $# -gt 0 ]]; then
        local cmd="$1"; shift
        case "$cmd" in
            internet) cmd_internet "$@" ;;
            lan)      cmd_lan "$@" ;;
            -h|--help|help) sed -n '/^# Usage:/,/^# The results/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' | sed '$d' ;;
            *) error_exit "Unknown command: ${cmd} (expected: internet|lan)" ;;
        esac
        exit 0
    fi

    while true; do
        header "Kessel Run — Connection Speed"
        local action
        action=$(gum choose \
            "internet — latency, download and upload (Cloudflare)" \
            "lan      — iperf3 to another machine" \
            "quit" \
            --header "Which test?") || true
        [[ -z "$action" || "$action" == "quit" ]] && { gum style --faint "Bye."; exit 0; }
        case "$action" in
            internet*) ( cmd_internet ) || true ;;
            lan*)      menu_lan ;;
        esac
        echo ""
        gum confirm "Back to main menu?" || { gum style --faint "Bye."; exit 0; }
    done
}

main "$@"
