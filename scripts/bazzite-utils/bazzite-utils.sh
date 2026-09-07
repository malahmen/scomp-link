#!/usr/bin/env bash
# description: EA App staged-update fix + Ubisoft Connect offscreen-window fix + KDE greeter refresh-rate fix
# Standalone export (export.sh): no extra setup deps — OS packages are installed at runtime (Linux-only utility).
# -----------------------------------------------------------------------------
# bazzite-utils.sh
# Grab-bag of gaming-on-Linux workaround utilities, gum-ified. Named after
# Bazzite (immutable Fedora Atomic gaming OS) since that's the primary target,
# but works on any dnf/apt/rpm-ostree host — deps.sh's _ensure_pkg auto-detects.
#
#   ea-fix        — copies EA App's staged self-update into place (EA's own
#                    updater frequently stages an update it never applies
#                    under Wine/Proton, leaving the launcher stuck).
#   ubisoft-rws    — finds Ubisoft Connect windows that render off-screen or
#                    invisible under Wine/Proton and repositions/raises them.
#   kwin-greeter-fix — copies your KWin output config (monitor refresh rates,
#                    positions, etc.) to the login-screen account (plasmalogin
#                    or sddm). The greeter runs as its own user with its own
#                    kwinoutputconfig.json, so a refresh-rate fix saved in your
#                    session never reaches the login screen — this syncs it.
#
# Sourced helpers (scripts/_common/):
#   ui.sh   — header/info/success/warn/error_exit
#   deps.sh — _ensure_pkg (dnf/apt/rpm-ostree aware)
#
# Config: ~/.config/bazzite-utils/bazzite-utils.conf (XDG-style, key=value)
# -----------------------------------------------------------------------------

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

trap 'echo ""; gum style --faint "Interrupted."; exit 0' INT TERM

# -----------------------------------------------------------------------------
# Config persistence
# -----------------------------------------------------------------------------

CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/bazzite-utils"
CONFIG_DIR="${CONFIG_DIR/#\~/$HOME}"
CONFIG_FILE="${CONFIG_DIR}/bazzite-utils.conf"
mkdir -p "$CONFIG_DIR"

cfg_load() {
    EA_PREFIX=""
    [[ -f "$CONFIG_FILE" ]] || return 0
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
}

cfg_save() {
    cat > "$CONFIG_FILE" <<EOF
EA_PREFIX="${EA_PREFIX}"
EOF
}

# -----------------------------------------------------------------------------
# ea-fix — apply EA App's staged self-update
# -----------------------------------------------------------------------------

_ea_prompt_prefix() {
    local default="${EA_PREFIX:-$HOME/Games/ea-app}"
    local p
    p=$(gum input --value "$default" \
        --header "Path to your EA App Wine/Proton prefix root (the folder containing drive_c):") || true
    [[ -z "$p" ]] && error_exit "EA prefix path is required."
    EA_PREFIX="${p%/}"
    cfg_save
}

cmd_ea_fix() {
    header "Bazzite Utils — EA App Update Fix"
    cfg_load

    if [[ -z "$EA_PREFIX" ]]; then
        _ea_prompt_prefix
    elif ! gum confirm "Use saved EA prefix: ${EA_PREFIX} ?"; then
        _ea_prompt_prefix
    fi

    local ea_path="${EA_PREFIX}/drive_c/Program Files/Electronic Arts/EA Desktop"
    local main_ea="${ea_path}/EA Desktop"
    local launcher_exe="${main_ea}/EALauncher.exe"

    [[ -d "$ea_path" ]] || error_exit "EA App path not found: ${ea_path}. Check your prefix path (run 'ea-fix' again to re-enter it)."

    info "Scanning for staged update folders..."
    local staged
    staged=$(find "$ea_path" -maxdepth 1 -type d -regex ".*/[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+-[0-9]+" 2>/dev/null | sort)

    if [[ -z "$staged" ]]; then
        success "No staging folders found. EA App appears to be up to date."
        return
    fi

    info "Found staging folder(s):"
    printf '%s\n' "$staged"

    local latest
    latest="$(printf '%s\n' "$staged" | tail -1)"
    info "Using latest: ${latest}"

    if [[ ! -d "${latest}/EA Desktop" ]]; then
        warn "No 'EA Desktop' folder inside the staging area. Contents:"
        ls -la "$latest"
        error_exit "Nothing to copy."
    fi

    gum confirm "Copy staged update into place? (overwrites files under '${main_ea}')" \
        || { info "Cancelled."; return; }

    gum spin --spinner dot --title "Copying update files..." -- \
        cp -rf "${latest}/EA Desktop/." "${main_ea}/" \
        || error_exit "Failed to copy update files."

    [[ -f "$launcher_exe" ]] || error_exit "Launcher not found after copy: ${launcher_exe}"
    success "Launcher verified: ${launcher_exe}"

    if gum confirm "Clean up the staging folder (and its .zip/.sig) to save space?"; then
        rm -rf "$latest"
        rm -f "${ea_path}/$(basename "$latest").zip" "${ea_path}/$(basename "$latest").zip.sig"
        success "Cleanup complete."
    fi

    success "EA App update fix complete."
}

# -----------------------------------------------------------------------------
# ubisoft-rws — Ubisoft Connect "Rogue Window Scan"
# -----------------------------------------------------------------------------

_ubisoft_ensure_deps() {
    _ensure_pkg xwininfo xorg-x11-utils x11-utils
    _ensure_pkg wmctrl   wmctrl         wmctrl
    _ensure_pkg xdotool  xdotool        xdotool
}

# Echoes "WID WIDTH HEIGHT XPOS YPOS" per Ubisoft Connect window found.
# Geometry regex allows a leading '-' on offsets — xwininfo reports negative
# X/Y for windows positioned off the top/left edge, which the original
# script's unsigned-only regex silently dropped (exactly the off-screen case
# this tool exists to fix).
_find_ubisoft_windows() {
    xwininfo -root -tree | grep -i "Ubisoft Connect" | while read -r line; do
        [[ $line =~ (0x[0-9a-f]+) ]] || continue
        local wid="${BASH_REMATCH[1]}"
        if [[ $line =~ ([0-9]+)x([0-9]+)([-+][0-9]+)([-+][0-9]+) ]]; then
            echo "${wid} ${BASH_REMATCH[1]} ${BASH_REMATCH[2]} ${BASH_REMATCH[3]} ${BASH_REMATCH[4]}"
        fi
    done
}

_terminate_ubisoft() {
    warn "Terminating Ubisoft Connect processes..."
    if pkill -f "UbisoftConnect.exe" 2>/dev/null; then
        success "Processes terminated."
    else
        warn "Failed to terminate processes (already stopped?)."
    fi
}

cmd_ubisoft_rws() {
    header "Bazzite Utils — Ubisoft Connect Window Fix"

    _ubisoft_ensure_deps

    info "Searching for Ubisoft Connect windows..."
    local windows=()
    mapfile -t windows < <(_find_ubisoft_windows)

    if [[ "${#windows[@]}" -eq 0 ]]; then
        warn "No Ubisoft Connect windows found."
        # xwininfo/wmctrl/xdotool only see X11 windows. Under a native Wayland
        # session, only XWayland clients are visible — Ubisoft Connect via Proton
        # is XWayland, so it should appear, but a native-Wayland app never will.
        [[ -n "${WAYLAND_DISPLAY:-}" ]] && \
            warn "You're on Wayland — these X11 tools only see XWayland windows. Make sure Ubisoft Connect is actually running (it runs under XWayland via Proton)."
        return
    fi

    success "Found ${#windows[@]} window(s):"
    local i wid width height xpos ypos
    for i in "${!windows[@]}"; do
        read -r wid width height xpos ypos <<< "${windows[$i]}"
        info "  $((i + 1)). ${wid} (${width}x${height} at ${xpos},${ypos})"
    done

    info "Attempting to bring windows into view..."
    local w
    for w in "${windows[@]}"; do
        read -r wid width height xpos ypos <<< "$w"
        if (( xpos > 5000 || xpos < -100 || ypos > 5000 || ypos < -100 )); then
            warn "Window ${wid} appears offscreen at ${xpos},${ypos}. Repositioning..."
            wmctrl -i -r "$wid" -e 0,100,100,"$width","$height" 2>/dev/null \
                || xdotool windowmove "$wid" 100 100 2>/dev/null || true
        else
            success "Window ${wid} is on-screen at ${xpos},${ypos}."
            wmctrl -i -a "$wid" 2>/dev/null || xdotool windowactivate "$wid" 2>/dev/null || true
        fi
    done

    if gum confirm "Are the Ubisoft Connect windows visible and working now?"; then
        local choice
        choice=$(gum choose \
            "Keep them running — they're working" \
            "I'll terminate them manually" \
            "Terminate them automatically" \
            --header "What now?") || true

        case "$choice" in
            "Keep them running"*) success "Done." ;;
            "I'll terminate"*)
                gum confirm "Confirm once you've closed them yourself"
                if pgrep -f "UbisoftConnect.exe" >/dev/null 2>&1; then
                    warn "Still running — falling back to automatic termination."
                    _terminate_ubisoft
                else
                    success "Terminated manually. Done."
                fi
                ;;
            "Terminate them automatically") _terminate_ubisoft ;;
            *) info "Cancelled." ;;
        esac
    else
        warn "Windows still not visible."
        if gum confirm "Terminate the Ubisoft Connect processes automatically?"; then
            _terminate_ubisoft
        else
            info "Leaving processes running — terminate manually if needed."
        fi
    fi
}

# -----------------------------------------------------------------------------
# kwin-greeter-fix — sync KWin output config to the login-screen account
# -----------------------------------------------------------------------------
# KDE's login screen runs as its own system user (plasmalogin, or sddm on
# older setups) with its own ~/.config/kwinoutputconfig.json, separate from
# yours. If your session has a working refresh-rate/layout fix that the
# monitor's EDID-advertised max mode doesn't (e.g. a monitor that reports
# 144Hz but only reliably links at 120Hz), the greeter never sees it and
# defaults to the max mode — causing no-signal/blank screens at boot until
# you replug a cable to force renegotiation. This copies your config over.

_kwin_greeter_user() {
    local dm_unit
    dm_unit="$(basename "$(readlink -f /etc/systemd/system/display-manager.service 2>/dev/null)" .service)"
    case "$dm_unit" in
        plasmalogin|sddm) echo "$dm_unit" ;;
        *)                echo "" ;;
    esac
}

cmd_kwin_greeter_fix() {
    header "Bazzite Utils — KDE Greeter Refresh-Rate Fix"

    local src="${HOME}/.config/kwinoutputconfig.json"
    [[ -f "$src" ]] || error_exit "No KWin output config found at ${src}. Set up your monitors (resolution/refresh rate) in System Settings first, then re-run this."

    local greeter_user
    greeter_user="$(_kwin_greeter_user)"
    [[ -n "$greeter_user" ]] || error_exit "Could not detect a KDE greeter (plasmalogin/sddm) as the active display manager."

    local greeter_home
    greeter_home="$(getent passwd "$greeter_user" | cut -d: -f6)"
    [[ -n "$greeter_home" ]] || error_exit "Could not resolve home directory for user '${greeter_user}'."

    info "Active greeter: ${greeter_user} (${greeter_home})"
    gum confirm "Copy ${src} to ${greeter_home}/.config/kwinoutputconfig.json ? (requires sudo)" \
        || { info "Cancelled."; return; }

    sudo install -d -o "$greeter_user" -g "$greeter_user" -m 0755 "${greeter_home}/.config" \
        || error_exit "Failed to create ${greeter_home}/.config."
    sudo cp -f "$src" "${greeter_home}/.config/kwinoutputconfig.json" \
        || error_exit "Failed to copy output config."
    sudo chown "${greeter_user}:${greeter_user}" "${greeter_home}/.config/kwinoutputconfig.json" \
        || error_exit "Failed to set ownership on copied config."

    success "Greeter output config synced. The login screen should now use your saved refresh rates/layout."
    warn "Re-run this any time you change monitors, cables, or resolutions — the config is matched by monitor EDID, so a hardware change invalidates it."
}

# -----------------------------------------------------------------------------
# Main dispatch
# -----------------------------------------------------------------------------

main() {
    if [[ $# -gt 0 ]]; then
        case "$1" in
            ea-fix)           cmd_ea_fix ;;
            ubisoft-rws)      cmd_ubisoft_rws ;;
            kwin-greeter-fix) cmd_kwin_greeter_fix ;;
            *) error_exit "Unknown command: $1 (expected: ea-fix|ubisoft-rws|kwin-greeter-fix)" ;;
        esac
        exit 0
    fi

    while true; do
        header "Bazzite Utils"
        local action
        action=$(gum choose \
            "ea-fix           — apply EA App's staged self-update" \
            "ubisoft-rws      — fix invisible/offscreen Ubisoft Connect windows" \
            "kwin-greeter-fix — sync monitor refresh rate/layout to the KDE login screen" \
            "quit" \
            --header "Choose a utility:") || true

        [[ -z "$action" || "$action" == "quit" ]] && { gum style --faint "Bye."; exit 0; }

        case "$action" in
            ea-fix*)           cmd_ea_fix ;;
            ubisoft-rws*)      cmd_ubisoft_rws ;;
            kwin-greeter-fix*) cmd_kwin_greeter_fix ;;
        esac

        echo ""
        gum confirm "Back to main menu?" || { gum style --faint "Bye."; exit 0; }
    done
}

main "$@"
