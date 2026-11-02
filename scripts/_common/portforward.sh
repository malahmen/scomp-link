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
# -----------------------------------------------------------------------------

_svc_ipv4() {
    local a="$1" o
    [[ "$a" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
    for o in "${BASH_REMATCH[@]:1}"; do (( 10#$o <= 255 )) || return 1; done
}

SVC_BIND_ADDR="${SCOMP_BIND_ADDR:-127.0.0.1}"
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

# svc_bind_notice - said after a publish that is not loopback-only.
svc_bind_notice() {
    svc_bind_is_loopback && return 0
    warn "Published on ${SVC_BIND_ADDR} (SCOMP_BIND_ADDR): reachable from other machines, not only this one."
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
    [[ -f "$f" ]] || return 1
    pid="$(_pf_pid "$f")"
    [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null
}

pf_port() { [[ -f "$1" ]] && cut -d: -f2 < "$1" 2>/dev/null; }

pf_stop() {
    local f="$1" pid
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
