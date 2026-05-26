#!/usr/bin/env bash
# Generic port-forward helpers.  Sourced by app scripts — do NOT run directly.
# Every function takes the PID-file path as its first argument.
# PID files store "<pid>:<local-port>".

pf_is_running() { local f="$1"; [[ -f "$f" ]] && kill -0 "$(cut -d: -f1 < "$f")" 2>/dev/null; }
pf_port()       { cut -d: -f2 < "$1" 2>/dev/null; }
pf_stop() {
    local f="$1"
    kill "$(cut -d: -f1 < "$f")" 2>/dev/null || true
    rm -f "$f"
    success "Port-forward stopped."
}
