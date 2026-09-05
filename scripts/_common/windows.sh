#!/usr/bin/env bash
# Shared window-discovery helper. Sourced by app scripts — do NOT run directly.
# Requires wmctrl and xdotool on PATH (callers are responsible for ensuring
# that via _ensure_pkg wmctrl/xdotool — see _common/deps.sh).

# _list_open_windows — echoes "<wid>\t<class>\t<title>" for every currently
# open top-level window (X11/XWayland only — see callers' own notes on the
# Wayland-focus boundary this implies). wid is decimal, matching what
# `xdotool getactivewindow`/`search` themselves use — wmctrl -l reports ids
# in hex, so it's converted here to keep every caller's ids comparable.
_list_open_windows() {
    local id desktop host title class
    while read -r id desktop host title; do
        [[ -z "$id" ]] && continue
        class="$(xdotool getwindowclassname "$id" 2>/dev/null)" || class=""
        printf '%s\t%s\t%s\n' "$((id))" "${class:-?}" "$title"
    done < <(wmctrl -l)
}
