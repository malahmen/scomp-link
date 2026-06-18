#!/usr/bin/env bash
# Generic port-forward helpers.  Sourced by app scripts — do NOT run directly.
# Every function takes the PID-file path as its first argument.
# PID files store "<pid>:<local-port>".

pf_is_running() { local f="$1"; [[ -f "$f" ]] && kill -0 "$(cut -d: -f1 < "$f")" 2>/dev/null; }
pf_port()       { cut -d: -f2 < "$1" 2>/dev/null; }
pf_stop() {
    local f="$1"
    local pid
    pid="$(cut -d: -f1 < "$f")"
    # Kill direct children first (the inner `kubectl port-forward` when the
    # caller wrapped it in a reconnect loop) before signalling the wrapper,
    # so the child can't be orphaned by a faster-exiting parent.
    pkill -P "$pid" 2>/dev/null || true
    kill "$pid" 2>/dev/null || true
    rm -f "$f"
    success "Port-forward stopped."
}
