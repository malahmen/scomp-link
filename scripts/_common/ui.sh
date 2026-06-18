#!/usr/bin/env bash
# Common gum-based display helpers.  Sourced by app scripts — do NOT run directly.
# Callers may override these before sourcing; otherwise the defaults below apply.

: "${CYAN:=212}"
: "${GREEN:=82}"
: "${YELLOW:=220}"
: "${RED:=196}"

header() {
    gum style \
        --foreground "${CYAN:-212}" --border-foreground "${CYAN:-212}" --border rounded \
        --align center --width 60 --padding "1 4" --margin "1 0" \
        "$1"
}

info()       { gum log --level info "$1"; }
success()    { gum style --foreground "${GREEN:-82}" "[ok] $1"; }
# warn / error_exit go to stderr so they remain visible when callers capture
# stdout via $() (e.g. `target_type=$(cfg_require)`).
warn()       { gum style --foreground "${YELLOW:-220}" "[warn] $1" >&2; }
error_exit() { gum style --foreground "${RED:-196}" "[error] $1" >&2; exit 1; }
