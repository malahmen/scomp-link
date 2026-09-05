#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# broadcaster.sh
# Generic key-stroke broadcaster: pick any currently open app window(s) into
# a named group, configure a hotkey per group, and pressing that hotkey while
# focused on a member of the group sends the same plain key to every other
# live member too. Works with any X11/XWayland app — not tied to any one game
# or launcher.
#
# How it actually works:
#   - xdotool can *send* synthetic key events to a specific window, but it
#     has no "listen for a global hotkey" mode of its own — that's what
#     xbindkeys is for here. 'start' generates an xbindkeys config (one
#     binding per configured key per group, e.g. "control + 1") pointed at
#     this script's own 'send' subcommand, and runs xbindkeys as a background
#     daemon. Only the exact modifier+key combos you configure are grabbed;
#     everything else (typing, movement, mouse look) is never intercepted,
#     since xbindkeys only grabs what's explicitly bound.
#   - 'send <group> <key>' (invoked by xbindkeys, not meant to be run by
#     hand) is the actual broadcast: it reads xdotool's currently active
#     window as a safety gate — only proceeds if that window is a live
#     member of the named group, so mis-fires while focused on an unrelated
#     app do nothing — then re-discovers every currently-open window that
#     matches the group's rule (live, not cached, so closed/renamed windows
#     are naturally skipped) and sends the plain key (no modifier) to each
#     one, INCLUDING the currently focused one: since xbindkeys grabs the
#     combo globally, the focused window's own keypress never reaches the
#     app natively any more, so it needs the same synthetic copy as every
#     other member.
#   - A group matches windows one of two ways, chosen when it's created:
#     by exact window title(s) (pins down specific windows you picked), or
#     by window class (follows any window of that same app, including ones
#     opened later).
#   - This only reliably sees key events while an XWayland window has
#     compositor focus. It won't fire while focused on a native-Wayland app
#     instead; that's a Wayland security-model boundary, not a bug here.
#
# Sourced helpers (scripts/_common/):
#   ui.sh      — header/info/success/warn/error_exit
#   deps.sh    — _ensure_pkg/_pkg_manager (dnf/apt/rpm-ostree)
#   windows.sh — _list_open_windows (wmctrl/xdotool-backed window discovery)
#
# Config: ~/.config/vanilla-wow-broadcaster/groups/<name>/{group.conf,titles.list}
# -----------------------------------------------------------------------------

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELF="${SCRIPT_DIR}/$(basename "${BASH_SOURCE[0]}")"
COMMON_DIR="${SCRIPT_DIR}/../_common"

# shellcheck source=../_common/ui.sh
source "${COMMON_DIR}/ui.sh"
# shellcheck source=../_common/deps.sh
source "${COMMON_DIR}/deps.sh"
# shellcheck source=../_common/windows.sh
source "${COMMON_DIR}/windows.sh"

trap 'echo ""; gum style --faint "Interrupted."; exit 0' INT TERM

# -----------------------------------------------------------------------------
# Constants / config
# -----------------------------------------------------------------------------

CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/vanilla-wow-broadcaster"
CONFIG_DIR="${CONFIG_DIR/#\~/$HOME}"
GROUPS_DIR="${CONFIG_DIR}/groups"
XBINDKEYSRC_FILE="${CONFIG_DIR}/xbindkeysrc"
PIDFILE="${CONFIG_DIR}/broadcaster.pid"
LOG_FILE="${CONFIG_DIR}/broadcaster.log"

mkdir -p "$GROUPS_DIR"

MODIFIER_CHOICES=("control" "alt" "control+shift" "control+alt" "super")
GROUP_NAME_RE='^[A-Za-z0-9_-]{1,32}$'

# -----------------------------------------------------------------------------
# Config persistence — same simple KEY="value" convention as client.sh
# -----------------------------------------------------------------------------

_cfg_get() {
    local file="$1" key="$2"
    grep -E "^${key}=" "$file" 2>/dev/null | cut -d= -f2- | sed 's/^"\(.*\)"$/\1/' || true
}
_cfg_set() {
    local file="$1" key="$2" val="$3" quoted
    quoted="\"${val}\""
    touch "$file"
    if grep -qE "^${key}=" "$file" 2>/dev/null; then
        sed -i.bak "s|^${key}=.*|${key}=${quoted}|" "$file" && rm -f "${file}.bak"
    else
        echo "${key}=${quoted}" >> "$file"
    fi
}

# -----------------------------------------------------------------------------
# Group helpers — mirrors client.sh's per-instance directory convention
# -----------------------------------------------------------------------------

_group_dir()   { echo "${GROUPS_DIR}/$1"; }
_group_conf()  { echo "$(_group_dir "$1")/group.conf"; }
_group_titles(){ echo "$(_group_dir "$1")/titles.list"; }

_list_group_names() {
    find "$GROUPS_DIR" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | sort
}

# _pick_group <header> — gum-choose an existing group name, empty on cancel/none.
_pick_group() {
    local hdr="$1" names
    names="$(_list_group_names)"
    [[ -z "$names" ]] && { warn "No groups configured yet — run 'add-group' first."; return 1; }
    printf '%s\n' "$names" | gum choose --header "$hdr"
}

# _group_settings <name> — loads a group's config into GROUP_* globals.
_group_settings() {
    local name="$1" conf; conf="$(_group_conf "$name")"
    GROUP_MATCH_MODE="$(_cfg_get "$conf" MATCH_MODE)"
    GROUP_MATCH_CLASS="$(_cfg_get "$conf" MATCH_CLASS)"
    GROUP_MODIFIER="$(_cfg_get "$conf" MODIFIER)"; GROUP_MODIFIER="${GROUP_MODIFIER:-control}"
    GROUP_KEYS="$(_cfg_get "$conf" KEYS)"
}

# _group_target_windows <name> — echoes "<title>\t<wid>" for every currently
# open window that matches this group's rule. Live, not cached, so a
# closed/renamed window is naturally skipped without any extra bookkeeping.
_group_target_windows() {
    local name="$1"
    _group_settings "$name"

    local wid class title
    while IFS=$'\t' read -r wid class title; do
        [[ -z "$wid" ]] && continue
        case "$GROUP_MATCH_MODE" in
            class)
                [[ "$class" == "$GROUP_MATCH_CLASS" ]] && printf '%s\t%s\n' "$title" "$wid"
                ;;
            titles)
                grep -qxF "$title" "$(_group_titles "$name")" 2>/dev/null && printf '%s\t%s\n' "$title" "$wid"
                ;;
        esac
    done < <(_list_open_windows)
}

# -----------------------------------------------------------------------------
# install-deps
# -----------------------------------------------------------------------------

cmd_install_deps() {
    header "Broadcaster — Install dependencies"

    _ensure_pkg xbindkeys xbindkeys xbindkeys
    _ensure_pkg xdotool xdotool xdotool
    _ensure_pkg wmctrl wmctrl wmctrl

    success "Dependencies checked."
}

# -----------------------------------------------------------------------------
# Window selection / group CRUD
# -----------------------------------------------------------------------------

# _format_window_line <wid> <class> <title> — one gum-choose candidate line.
_format_window_line() {
    printf '%s  [%s] (id:%s)' "$3" "$2" "$1"
}

# _select_windows — interactively picks open windows, echoes "<wid>\t<class>\t<title>"
# for each selection. Empty output on cancel/none.
_select_windows() {
    local open; open="$(_list_open_windows)"
    [[ -z "$open" ]] && { warn "No open windows found."; return 0; }

    local candidates=""
    local wid class title line
    declare -A by_line=()
    while IFS=$'\t' read -r wid class title; do
        [[ -z "$wid" ]] && continue
        line="$(_format_window_line "$wid" "$class" "$title")"
        by_line["$line"]="${wid}"$'\t'"${class}"$'\t'"${title}"
        candidates+="${line}"$'\n'
    done <<< "$open"

    local picked
    picked=$(printf '%s' "$candidates" | gum choose --no-limit --header "Select window(s) — SPACE to select, ENTER to confirm:") || true
    [[ -z "$picked" ]] && return 0

    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        printf '%s\n' "${by_line[$line]}"
    done <<< "$picked"
}

# _configure_group_keys <name> — prompts for modifier + keys, writes group.conf.
_configure_group_keys() {
    local name="$1" conf; conf="$(_group_conf "$name")"
    _group_settings "$name"

    local mod_choice
    mod_choice=$(printf '%s\n' "${MODIFIER_CHOICES[@]}" | gum choose --header "Modifier held down while pressing a broadcast key (current: ${GROUP_MODIFIER}):") || true
    GROUP_MODIFIER="${mod_choice:-$GROUP_MODIFIER}"
    _cfg_set "$conf" MODIFIER "$GROUP_MODIFIER"

    local keys_input
    keys_input=$(gum input --value "$GROUP_KEYS" --placeholder "1 2 3 4 5 6 7 8 9 0 F1 F2 F3 F4" \
        --header "Space-separated keys to broadcast (pressed as ${GROUP_MODIFIER}+<key>, sent as plain <key>):") || true
    GROUP_KEYS="${keys_input:-$GROUP_KEYS}"
    [[ -n "$GROUP_KEYS" ]] || error_exit "At least one key must be configured."
    _cfg_set "$conf" KEYS "$GROUP_KEYS"
}

cmd_add_group() {
    header "Broadcaster — New group"

    local name
    name=$(gum input --placeholder "wow-boxes" --header "Group name (letters/digits/-/_ only):") || true
    [[ -z "$name" ]] && { info "Cancelled."; return 0; }
    [[ "$name" =~ $GROUP_NAME_RE ]] || error_exit "Invalid name '${name}' — only letters, digits, '-' and '_' allowed (max 32 chars)."
    [[ -d "$(_group_dir "$name")" ]] && error_exit "Group '${name}' already exists."

    local selected; selected="$(_select_windows)"
    [[ -z "$selected" ]] && { info "Cancelled — no windows selected."; return 0; }

    mkdir -p "$(_group_dir "$name")"

    local wid class title classes=() titles=()
    while IFS=$'\t' read -r wid class title; do
        [[ -z "$wid" ]] && continue
        classes+=("$class")
        titles+=("$title")
    done <<< "$selected"

    local common_class=""
    local distinct; distinct="$(printf '%s\n' "${classes[@]}" | sort -u)"
    [[ "$(printf '%s\n' "$distinct" | wc -l)" -eq 1 ]] && common_class="$distinct"

    local mode
    if [[ -n "$common_class" ]]; then
        mode=$(printf '%s\n' \
            "Only these exact window title(s)" \
            "Any window with class '${common_class}' (now or later)" \
            | gum choose --header "How should this group match windows going forward?") || true
        [[ "$mode" == "Any window"* ]] && mode="class" || mode="titles"
    else
        info "Selection spans multiple window classes — matching by exact title(s)."
        mode="titles"
    fi

    if [[ "$mode" == "class" ]]; then
        _cfg_set "$(_group_conf "$name")" MATCH_MODE "class"
        _cfg_set "$(_group_conf "$name")" MATCH_CLASS "$common_class"
    else
        _cfg_set "$(_group_conf "$name")" MATCH_MODE "titles"
        printf '%s\n' "${titles[@]}" > "$(_group_titles "$name")"
    fi

    _configure_group_keys "$name"

    success "Group '${name}' created. Run 'start' to begin broadcasting (restart it after editing a group to pick up changes)."
}

cmd_edit_group() {
    header "Broadcaster — Edit group"
    local name; name="$(_pick_group "Choose a group to edit:")" || return 1
    [[ -z "$name" ]] && { info "Cancelled."; return 0; }

    local action
    action=$(gum choose "Modifier/keys" "Window selection" --header "What to change on '${name}':") || true
    case "$action" in
        "Modifier/keys")
            _configure_group_keys "$name"
            ;;
        "Window selection")
            local selected; selected="$(_select_windows)"
            [[ -z "$selected" ]] && { info "Cancelled."; return 0; }

            local wid class title classes=() titles=()
            while IFS=$'\t' read -r wid class title; do
                [[ -z "$wid" ]] && continue
                classes+=("$class")
                titles+=("$title")
            done <<< "$selected"

            local common_class=""
            local distinct; distinct="$(printf '%s\n' "${classes[@]}" | sort -u)"
            [[ "$(printf '%s\n' "$distinct" | wc -l)" -eq 1 ]] && common_class="$distinct"

            local mode
            if [[ -n "$common_class" ]]; then
                mode=$(printf '%s\n' \
                    "Only these exact window title(s)" \
                    "Any window with class '${common_class}' (now or later)" \
                    | gum choose --header "How should this group match windows going forward?") || true
                [[ "$mode" == "Any window"* ]] && mode="class" || mode="titles"
            else
                info "Selection spans multiple window classes — matching by exact title(s)."
                mode="titles"
            fi

            rm -f "$(_group_titles "$name")"
            if [[ "$mode" == "class" ]]; then
                _cfg_set "$(_group_conf "$name")" MATCH_MODE "class"
                _cfg_set "$(_group_conf "$name")" MATCH_CLASS "$common_class"
            else
                _cfg_set "$(_group_conf "$name")" MATCH_MODE "titles"
                printf '%s\n' "${titles[@]}" > "$(_group_titles "$name")"
            fi
            ;;
        *) info "Cancelled."; return 0 ;;
    esac

    success "Group '${name}' updated. Restart broadcasting to pick up changes."
}

cmd_remove_group() {
    header "Broadcaster — Remove group"
    local name; name="$(_pick_group "Choose a group to remove:")" || return 1
    [[ -z "$name" ]] && { info "Cancelled."; return 0; }

    gum confirm "Remove group '${name}'?" || { info "Cancelled."; return 0; }
    rm -rf "$(_group_dir "$name")"
    success "Group '${name}' removed."
}

cmd_list_groups() {
    header "Broadcaster — Groups"
    local names; names="$(_list_group_names)"
    if [[ -z "$names" ]]; then
        info "No groups configured yet — run 'add-group'."
        return 0
    fi

    local name targets count
    while IFS= read -r name; do
        [[ -z "$name" ]] && continue
        _group_settings "$name"
        targets="$(_group_target_windows "$name")"
        count=0; [[ -n "$targets" ]] && count="$(printf '%s\n' "$targets" | grep -c . || true)"
        gum style --foreground "${CYAN}" --bold "── ${name}"
        info "  mode: ${GROUP_MATCH_MODE} | modifier: ${GROUP_MODIFIER} | keys: ${GROUP_KEYS} | live windows: ${count}"
    done <<< "$names"
}

# -----------------------------------------------------------------------------
# start / stop / status
# -----------------------------------------------------------------------------

_daemon_running() {
    [[ -f "$PIDFILE" ]] && kill -0 "$(cat "$PIDFILE" 2>/dev/null)" 2>/dev/null
}

# _generate_xbindkeysrc — one binding per configured key per group, each
# running this script's own 'send' subcommand. xbindkeys' own config syntax:
#   "command"
#       modifier + key
_generate_xbindkeysrc() {
    : > "$XBINDKEYSRC_FILE"
    local name key
    while IFS= read -r name; do
        [[ -z "$name" ]] && continue
        _group_settings "$name"
        for key in $GROUP_KEYS; do
            {
                printf '"%s send %s %s"\n' "$SELF" "$name" "$key"
                printf '    %s + %s\n\n' "$GROUP_MODIFIER" "$key"
            } >> "$XBINDKEYSRC_FILE"
        done
    done < <(_list_group_names)
}

cmd_start() {
    header "Broadcaster — Start"

    command -v xbindkeys &>/dev/null || error_exit "xbindkeys not found — run 'install-deps' first."
    [[ -n "$(_list_group_names)" ]] || error_exit "No groups configured yet — run 'add-group' first."

    if _daemon_running; then
        warn "Already running (pid $(cat "$PIDFILE"))."
        return 0
    fi

    _generate_xbindkeysrc
    nohup xbindkeys -f "$XBINDKEYSRC_FILE" -n >> "$LOG_FILE" 2>&1 &
    echo "$!" > "$PIDFILE"

    sleep 1
    if _daemon_running; then
        success "Broadcaster running."
    else
        warn "Did not seem to start — check ${LOG_FILE}."
    fi
}

cmd_stop() {
    header "Broadcaster — Stop"

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
    header "Broadcaster — Status"

    if _daemon_running; then
        success "Running (pid $(cat "$PIDFILE"))."
    else
        info "Not running."
    fi

    cmd_list_groups
}

# -----------------------------------------------------------------------------
# send <group> <key> — invoked by xbindkeys, not meant for direct interactive
# use. Deliberately avoids gum entirely (this runs on every keypress; gum's
# own subprocess spawn overhead would add perceptible input lag).
# -----------------------------------------------------------------------------

cmd_send() {
    local group="${1:-}" key="${2:-}"
    [[ -z "$group" || -z "$key" ]] && exit 0

    local active_win
    active_win="$(xdotool getactivewindow 2>/dev/null)" || exit 0

    local line wid
    local is_member=0
    while IFS=$'\t' read -r line wid; do
        [[ -z "$wid" ]] && continue
        [[ "$wid" == "$active_win" ]] && is_member=1
    done < <(_group_target_windows "$group")

    # Safety gate: only broadcast if currently focused on a live member of
    # the named group — protects against misfires while focused elsewhere.
    [[ "$is_member" -eq 1 ]] || exit 0

    while IFS=$'\t' read -r line wid; do
        [[ -z "$wid" ]] && continue
        xdotool key --window "$wid" "$key" 2>/dev/null || true
    done < <(_group_target_windows "$group")
}

# -----------------------------------------------------------------------------
# Dashboard loop — the interactive entry point
# -----------------------------------------------------------------------------

_render_dashboard() {
    if _daemon_running; then
        success "Daemon running (pid $(cat "$PIDFILE"))."
    else
        info "Daemon stopped."
    fi

    local names; names="$(_list_group_names)"
    if [[ -z "$names" ]]; then
        info "No groups configured yet — choose 'New group' below."
        return 0
    fi

    local name targets count
    while IFS= read -r name; do
        [[ -z "$name" ]] && continue
        _group_settings "$name"
        targets="$(_group_target_windows "$name")"
        count=0; [[ -n "$targets" ]] && count="$(printf '%s\n' "$targets" | grep -c . || true)"
        gum style --foreground "${CYAN}" --bold "── ${name}"
        info "  mode: ${GROUP_MATCH_MODE} | modifier: ${GROUP_MODIFIER} | keys: ${GROUP_KEYS} | live windows: ${count}"
    done <<< "$names"
}

main_menu() {
    while true; do
        clear
        header "Broadcaster"
        _render_dashboard

        local action
        action=$(gum choose "New group" "Edit group" "Remove group" "Start broadcasting" "Stop broadcasting" "Install dependencies" "Quit" --header "Action:") || true
        [[ -z "$action" || "$action" == "Quit" ]] && { gum style --faint "Bye."; exit 0; }

        case "$action" in
            "New group")            cmd_add_group      || true ;;
            "Edit group")           cmd_edit_group      || true ;;
            "Remove group")         cmd_remove_group    || true ;;
            "Start broadcasting")   cmd_start           || true ;;
            "Stop broadcasting")    cmd_stop            || true ;;
            "Install dependencies") cmd_install_deps    || true ;;
        esac

        echo ""
        gum input --placeholder "Press Enter to continue..." >/dev/null || true
    done
}

# -----------------------------------------------------------------------------
# Main dispatch
# -----------------------------------------------------------------------------

main() {
    if [[ $# -gt 0 ]]; then
        case "$1" in
            install-deps) cmd_install_deps ;;
            add-group)    cmd_add_group ;;
            list-groups)  cmd_list_groups ;;
            edit-group)   cmd_edit_group ;;
            remove-group) cmd_remove_group ;;
            start)        cmd_start ;;
            stop)         cmd_stop ;;
            status)       cmd_status ;;
            send)         shift; cmd_send "${1:-}" "${2:-}" ;;
            *) error_exit "Unknown command: $1 (expected: install-deps|add-group|list-groups|edit-group|remove-group|start|stop|status|send)" ;;
        esac
        exit 0
    fi

    main_menu
}

main "$@"
