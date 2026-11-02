#!/usr/bin/env bash
# Generic port-forward and port-publishing helpers.  Sourced by app scripts —
# do NOT run directly (needs ui.sh's warn/success/error_exit sourced first).
# Every pf_* function takes the PID-file path as its first argument.
# PID files store "<pid>:<local-port>".

# -----------------------------------------------------------------------------
# Published ports (Kamino 196)
#
# `docker run -p 8080:80` and a compose `ports: - "8080:80"` listen on EVERY
# interface, while the scripts' summaries said http://localhost:...: a
# database, an admin UI - and Dozzle, which hands out the Docker socket - were
# open to the whole LAN. Ports are now published on 127.0.0.1 unless
# SCOMP_BIND_ADDR names another IPv4 address (0.0.0.0 = every interface, i.e.
# the old behaviour; or one LAN address of this host). kubectl port-forward
# already listens on localhost only and is not affected.
#
# A bad SCOMP_BIND_ADDR stops the script here, before anything is published:
# falling back to a default would publish somewhere the user did not ask for.
#
# A LAN service - one whose whole purpose is to be reached from other
# machines (speaches, protocol) - sets SVC_BIND_DEFAULT=0.0.0.0 before
# sourcing this file: it is published on every interface unless
# SCOMP_BIND_ADDR says otherwise, deliberately, and svc_bind_notice says so
# (Kamino 235).
# -----------------------------------------------------------------------------

_svc_ipv4() {
    local a="$1" o
    [[ "$a" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
    for o in "${BASH_REMATCH[@]:1}"; do (( 10#$o <= 255 )) || return 1; done
}

SVC_BIND_ADDR="${SCOMP_BIND_ADDR:-${SVC_BIND_DEFAULT:-127.0.0.1}}"
_svc_ipv4 "$SVC_BIND_ADDR" \
    || error_exit "SCOMP_BIND_ADDR='${SVC_BIND_ADDR}' is not an IPv4 address (e.g. 127.0.0.1, 0.0.0.0 or this host's LAN address)."

# svc_bind_is_loopback - the ports are reachable from this machine only.
svc_bind_is_loopback() { [[ "$SVC_BIND_ADDR" == 127.* ]]; }

# svc_publish <host-port> <container-port> - the value for `-p` / compose ports.
svc_publish() { printf '%s:%s:%s' "$SVC_BIND_ADDR" "$1" "$2"; }

# svc_host [bind-address] - the address to reach a published port at from
# this machine (and to print): the bind address (default: this run's), or
# 127.0.0.1 when that is "every interface".
svc_host() {
    local a="${1:-$SVC_BIND_ADDR}"
    [[ "$a" == 0.0.0.0 ]] && a=127.0.0.1
    printf '%s' "$a"
}

# svc_bind_notice - said after a publish that is not loopback-only: by
# SCOMP_BIND_ADDR, or by a LAN service's own default.
svc_bind_notice() {
    svc_bind_is_loopback && return 0
    if [[ -n "${SCOMP_BIND_ADDR:-}" ]]; then
        warn "Published on ${SVC_BIND_ADDR} (SCOMP_BIND_ADDR): reachable from other machines, not only this one."
    else
        warn "Published on ${SVC_BIND_ADDR}, every interface: this is a LAN service, so that is its default - reachable from other machines, not only this one. SCOMP_BIND_ADDR=127.0.0.1 keeps it on this machine."
    fi
}

# -----------------------------------------------------------------------------
# PID files (Kamino 196)
#
# They were /tmp/scomp-pf-<svc>.pid: a fixed name in a world-writable folder,
# so another local user could plant one (or a symlink) for pf_stop to `kill`
# whatever PID it held, and two users of one host overwrote each other's.
# They live in a per-user 0700 folder now, and a PID file that is a symlink or
# not the user's own is never read, signalled or written through.
# -----------------------------------------------------------------------------

# pf_dir - the per-user PID folder, created 0700:
# $XDG_RUNTIME_DIR (per-user, cleared at logout) or else ~/.cache, + scomp-link/pf.
pf_dir() {
    local base="${XDG_RUNTIME_DIR:-}"
    [[ -n "$base" && -d "$base" && -O "$base" ]] || base="${XDG_CACHE_HOME:-$HOME/.cache}"
    local d="${base}/scomp-link/pf"
    (umask 077; mkdir -p "$d") 2>/dev/null || true
    [[ -d "$d" && ! -L "$d" && -O "$d" ]] && chmod 700 "$d" 2>/dev/null
    printf '%s' "$d"
}

# pf_file <name> - the PID file for one forward, e.g. pf_file grafana.
pf_file() { printf '%s/%s.pid' "$(pf_dir)" "$1"; }

# _pf_trusted <file> - a regular file of this user's, in a folder of this
# user's that nobody else can write to. Anything else is refused.
_pf_trusted() {
    local f="$1" d
    d="$(dirname "$f")"
    [[ ! -L "$f" && -f "$f" && -O "$f" ]] || return 1
    [[ ! -L "$d" && -O "$d" ]] || return 1
    # Group/other-writable folder: someone else could swap the file.
    [[ -z "$(find "$d" -maxdepth 0 \( -perm -020 -o -perm -002 \) 2>/dev/null)" ]]
}

# pf_write <file> <pid> <port> - records a forward. A symlink in its place is
# removed first, so the write cannot land elsewhere.
pf_write() {
    [[ -L "$1" ]] && rm -f "$1"
    (umask 077; printf '%s:%s\n' "$2" "$3" > "$1")
}

# Extract the PID from a "<pid>:<port>" file, but only if it's a positive
# integer — guards against an empty/partial/garbage file (a bare `cut` would
# otherwise yield "" and turn `kill ""` into a no-op while still deleting the
# file, orphaning a live port-forward). Prints nothing when invalid.
# (Note: this can't defend against PID reuse — a recorded PID that has exited and
# been reassigned will still look "running"; acceptable for these short-lived,
# session-scoped forwards.)
_pf_pid() { local p; p="$(cut -d: -f1 < "$1" 2>/dev/null)"; [[ "$p" =~ ^[0-9]+$ ]] && printf '%s' "$p"; }

pf_is_running() {
    local f="$1" pid
    _pf_trusted "$f" || return 1
    pid="$(_pf_pid "$f")"
    [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null
}

pf_port() { _pf_trusted "$1" && cut -d: -f2 < "$1" 2>/dev/null; }

pf_stop() {
    local f="$1" pid
    if [[ -L "$f" ]] || { [[ -e "$f" ]] && ! _pf_trusted "$f"; }; then
        warn "Refusing PID file ${f}: a symlink, or not yours - nothing signalled."
        return 0
    fi
    [[ -f "$f" ]] || { success "Port-forward stopped."; return; }
    pid="$(_pf_pid "$f")"
    if [[ -n "$pid" ]]; then
        # Kill direct children first (the inner `kubectl port-forward` when the
        # caller wrapped it in a reconnect loop) before signalling the wrapper,
        # so the child can't be orphaned by a faster-exiting parent.
        pkill -P "$pid" 2>/dev/null || true
        kill "$pid" 2>/dev/null || true
    else
        warn "Port-forward PID file was empty/invalid — removing it without signalling."
    fi
    rm -f "$f"
    success "Port-forward stopped."
}
