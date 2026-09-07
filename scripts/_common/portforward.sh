#!/usr/bin/env bash
# Generic port-forward helpers.  Sourced by app scripts — do NOT run directly.
# Every function takes the PID-file path as its first argument.
# PID files store "<pid>:<local-port>".

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
