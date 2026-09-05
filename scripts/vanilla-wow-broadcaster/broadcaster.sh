#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# broadcaster.sh
# Key-stroke broadcaster for vanilla-wow-client multiboxing: press a
# configured hotkey while focused on one box, and the same key is sent to
# every other currently-running box too. Companion to
# scripts/vanilla-wow-client/client.sh — reads that script's own instance
# registry (~/.config/vanilla-wow-client/instances/) as the list of known
# box names, but is otherwise independent (client.sh doesn't need this
# running, and this doesn't touch client.sh's config).
#
# How it actually works:
#   - xdotool can *send* synthetic key events to a specific window, but it
#     has no "listen for a global hotkey" mode of its own — that's what
#     xbindkeys is for here. 'start' generates an xbindkeys config (one
#     binding per configured key, e.g. "control + 1") pointed at this
#     script's own 'send' subcommand, and runs xbindkeys as a background
#     daemon. Only the exact modifier+key combos you configure are grabbed;
#     everything else (chat typing, WASD movement, mouse look) is never
#     intercepted, since xbindkeys only grabs what's explicitly bound.
#   - 'send <key>' (invoked by xbindkeys, not meant to be run by hand) is the
#     actual broadcast: it reads xdotool's currently active window as a
#     safety gate — only proceeds if you're focused on a window titled
#     exactly like one of client.sh's known instances, so mis-fires while
#     focused on an unrelated app do nothing — then re-discovers every
#     currently-open window titled like a known instance (live, not cached,
#     so stopped/renamed boxes are naturally skipped) and sends the plain key
#     (no modifier) to each one, INCLUDING the currently focused one: since
#     xbindkeys grabs the combo globally, the focused window's own keypress
#     never reaches the game natively any more, so it needs the same
#     synthetic copy as every other box.
#   - This only reliably sees key events while an XWayland window has
#     compositor focus (which is exactly what client.sh's game windows are —
#     see its own header notes on why). It won't fire while focused on a
#     native-Wayland app instead; that's a Wayland security-model boundary,
#     not a bug here.
#
# Sourced helpers (scripts/_common/):
#   ui.sh   — header/info/success/warn/error_exit
#   deps.sh — _ensure_pkg/_pkg_manager (dnf/apt/rpm-ostree)
#
# Config: ~/.config/vanilla-wow-broadcaster/broadcaster.conf
# Reads (not writes):  ~/.config/vanilla-wow-client/instances/ (client.sh's)
# -----------------------------------------------------------------------------

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELF="${SCRIPT_DIR}/$(basename "${BASH_SOURCE[0]}")"
COMMON_DIR="${SCRIPT_DIR}/../_common"

# shellcheck source=../_common/ui.sh
source "${COMMON_DIR}/ui.sh"
# shellcheck source=../_common/deps.sh
source "${COMMON_DIR}/deps.sh"

trap 'echo ""; gum style --faint "Interrupted."; exit 0' INT TERM

# -----------------------------------------------------------------------------
# Constants / config
# -----------------------------------------------------------------------------

CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/vanilla-wow-broadcaster"
CONFIG_DIR="${CONFIG_DIR/#\~/$HOME}"
CONFIG_FILE="${CONFIG_DIR}/broadcaster.conf"
XBINDKEYSRC_FILE="${CONFIG_DIR}/xbindkeysrc"
PIDFILE="${CONFIG_DIR}/broadcaster.pid"
LOG_FILE="${CONFIG_DIR}/broadcaster.log"

mkdir -p "$CONFIG_DIR"

# client.sh's own instance registry — this script only reads it.
CLIENT_INSTANCES_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/vanilla-wow-client/instances"
CLIENT_INSTANCES_DIR="${CLIENT_INSTANCES_DIR/#\~/$HOME}"

MODIFIER_CHOICES=("control" "alt" "control+shift" "control+alt" "super")

# -----------------------------------------------------------------------------
# Config persistence — same simple KEY="value" convention as client.sh
# -----------------------------------------------------------------------------

_cfg_get() {
    local key="$1"
    grep -E "^${key}=" "$CONFIG_FILE" 2>/dev/null | cut -d= -f2- | sed 's/^"\(.*\)"$/\1/' || true
}
_cfg_set() {
    local key="$1" val="$2" quoted
    quoted="\"${val}\""
    touch "$CONFIG_FILE"
    if grep -qE "^${key}=" "$CONFIG_FILE" 2>/dev/null; then
        sed -i.bak "s|^${key}=.*|${key}=${quoted}|" "$CONFIG_FILE" && rm -f "${CONFIG_FILE}.bak"
    else
        echo "${key}=${quoted}" >> "$CONFIG_FILE"
    fi
}

_settings() {
    BROADCAST_MODIFIER="$(_cfg_get MODIFIER)"; BROADCAST_MODIFIER="${BROADCAST_MODIFIER:-control}"
    BROADCAST_KEYS="$(_cfg_get KEYS)"
}

# -----------------------------------------------------------------------------
# Known instances (from client.sh) / live target windows
# -----------------------------------------------------------------------------

# _known_instance_names — echoes one client.sh instance name per line.
_known_instance_names() {
    find "$CLIENT_INSTANCES_DIR" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | sort
}

# _live_target_windows — echoes "name wid" pairs, one per currently-open
# window whose title exactly matches a known instance name. Live, not
# cached, so a stopped/renamed box is naturally skipped without any extra
# bookkeeping on this script's part.
_live_target_windows() {
    local name wid
    while IFS= read -r name; do
        [[ -z "$name" ]] && continue
        while IFS= read -r wid; do
            [[ -z "$wid" ]] && continue
            echo "${name} ${wid}"
        done < <(xdotool search --name "^${name}$" 2>/dev/null)
    done < <(_known_instance_names)
}

# -----------------------------------------------------------------------------
# install-deps
# -----------------------------------------------------------------------------

cmd_install_deps() {
    header "vanilla-wow-broadcaster — Install dependencies"

    _ensure_pkg xbindkeys xbindkeys xbindkeys
    _ensure_pkg xdotool xdotool xdotool

    success "Dependencies checked."
}

# -----------------------------------------------------------------------------
# configure
# -----------------------------------------------------------------------------

cmd_configure() {
    header "vanilla-wow-broadcaster — Configure"
    _settings

    local mod_choice
    mod_choice=$(printf '%s\n' "${MODIFIER_CHOICES[@]}" | gum choose --header "Modifier held down while pressing a broadcast key (current: ${BROADCAST_MODIFIER}):") || true
    BROADCAST_MODIFIER="${mod_choice:-$BROADCAST_MODIFIER}"
    _cfg_set MODIFIER "$BROADCAST_MODIFIER"

    local keys_input
    keys_input=$(gum input --value "$BROADCAST_KEYS" --placeholder "1 2 3 4 5 6 7 8 9 0 F1 F2 F3 F4" \
        --header "Space-separated keys to broadcast (pressed as ${BROADCAST_MODIFIER}+<key>, sent as plain <key>):") || true
    BROADCAST_KEYS="${keys_input:-$BROADCAST_KEYS}"
    [[ -n "$BROADCAST_KEYS" ]] || error_exit "At least one key must be configured."
    _cfg_set KEYS "$BROADCAST_KEYS"

    success "Configure complete. Run 'start' to begin broadcasting (restart it after re-running configure to pick up changes)."
}

# -----------------------------------------------------------------------------
# start / stop / status
# -----------------------------------------------------------------------------

_daemon_running() {
    [[ -f "$PIDFILE" ]] && kill -0 "$(cat "$PIDFILE" 2>/dev/null)" 2>/dev/null
}

# _generate_xbindkeysrc — one binding per configured key, each running this
# script's own 'send' subcommand. xbindkeys' own config syntax:
#   "command"
#       modifier + key
_generate_xbindkeysrc() {
    : > "$XBINDKEYSRC_FILE"
    local key
    for key in $BROADCAST_KEYS; do
        {
            printf '"%s send %s"\n' "$SELF" "$key"
            printf '    %s + %s\n\n' "$BROADCAST_MODIFIER" "$key"
        } >> "$XBINDKEYSRC_FILE"
    done
}

cmd_start() {
    header "vanilla-wow-broadcaster — Start"
    _settings

    command -v xbindkeys &>/dev/null || error_exit "xbindkeys not found — run 'install-deps' first."
    [[ -n "$BROADCAST_KEYS" ]] || error_exit "Not configured yet — run 'configure' first."

    if _daemon_running; then
        warn "Already running (pid $(cat "$PIDFILE"))."
        return 0
    fi

    _generate_xbindkeysrc
    nohup xbindkeys -f "$XBINDKEYSRC_FILE" -n >> "$LOG_FILE" 2>&1 &
    echo "$!" > "$PIDFILE"

    sleep 1
    if _daemon_running; then
        success "Broadcaster running (modifier: ${BROADCAST_MODIFIER}, keys: ${BROADCAST_KEYS})."
    else
        warn "Did not seem to start — check ${LOG_FILE}."
    fi
}

cmd_stop() {
    header "vanilla-wow-broadcaster — Stop"

    if ! _daemon_running; then
        info "Not running."
        rm -f "$PIDFILE"
        return 0
    fi

    kill "$(cat "$PIDFILE")" 2>/dev/null || true
    rm -f "$PIDFILE"
    success "Broadcaster stopped."
}

cmd_status() {
    header "vanilla-wow-broadcaster — Status"
    _settings

    if _daemon_running; then
        success "Running (pid $(cat "$PIDFILE"))."
    else
        info "Not running."
    fi
    info "Modifier: ${BROADCAST_MODIFIER:-<not configured>} | Keys: ${BROADCAST_KEYS:-<not configured>}"

    local targets; targets="$(_live_target_windows)"
    if [[ -z "$targets" ]]; then
        info "No known instances currently have an open window."
    else
        gum style --foreground "${CYAN}" --bold "── Live targets"
        printf '%s\n' "$targets" | while IFS= read -r line; do info "  ${line}"; done
    fi
}

# -----------------------------------------------------------------------------
# send <key> — invoked by xbindkeys, not meant for direct interactive use.
# Deliberately avoids gum entirely (this runs on every keypress; gum's own
# subprocess spawn overhead would add perceptible input lag).
# -----------------------------------------------------------------------------

cmd_send() {
    local key="${1:-}"
    [[ -z "$key" ]] && exit 0

    local active_win active_name
    active_win="$(xdotool getactivewindow 2>/dev/null)" || exit 0
    active_name="$(xdotool getwindowname "$active_win" 2>/dev/null)" || exit 0

    # Safety gate: only broadcast if currently focused on a recognized,
    # running instance — protects against misfires while focused elsewhere.
    _known_instance_names | grep -qxF "$active_name" || exit 0

    local line wid
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        wid="${line##* }"
        xdotool key --window "$wid" "$key" 2>/dev/null || true
    done < <(_live_target_windows)
}

# -----------------------------------------------------------------------------
# Main dispatch
# -----------------------------------------------------------------------------

_run_category_menu() {
    local title="$1"; shift
    local -a opts=("$@")

    while true; do
        header "Vanilla WoW Broadcaster — ${title}"
        local action
        action=$(printf '%s\n' "${opts[@]}" "back" | gum choose --header "Choose an action:") || true
        [[ -z "$action" || "$action" == "back" ]] && return

        case "$action" in
            install-deps) cmd_install_deps || true ;;
            configure)    cmd_configure    || true ;;
            start)        cmd_start        || true ;;
            stop)         cmd_stop         || true ;;
            status)       cmd_status       || true ;;
        esac
        echo ""
    done
}

main() {
    if [[ $# -gt 0 ]]; then
        case "$1" in
            install-deps) cmd_install_deps ;;
            configure)    cmd_configure ;;
            start)        cmd_start ;;
            stop)         cmd_stop ;;
            status)       cmd_status ;;
            send)         shift; cmd_send "${1:-}" ;;
            *) error_exit "Unknown command: $1 (expected: install-deps|configure|start|stop|status|send)" ;;
        esac
        exit 0
    fi

    while true; do
        header "Vanilla WoW Broadcaster"
        local category
        category=$(gum choose "Setup" "Control" "Status" "Quit" --header "Choose a category:") || true

        [[ -z "$category" || "$category" == "Quit" ]] && { gum style --faint "Bye."; exit 0; }

        case "$category" in
            Setup)   _run_category_menu "Setup"   install-deps configure ;;
            Control) _run_category_menu "Control" start stop ;;
            Status)  cmd_status || true ;;
        esac
    done
}

main "$@"
