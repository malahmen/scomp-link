#!/usr/bin/env bash
# description: EA App staged-update fix + Ubisoft Connect offscreen-window fix + KDE greeter refresh-rate fix + Lofree Edge keyd keyboard remap + Wine keyboard-focus fix
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
#   lofree-edge-fix  — installs keyd and a per-device remap (templates/
#                    lofree-edge.conf) so a Lofree Edge Bluetooth keyboard
#                    types plain US punctuation while the rest of the system
#                    stays on a different XKB layout (KWin/Wayland only
#                    supports one global layout for every keyboard at once).
#                    See the template file's header comment for the (very
#                    non-obvious) reasoning: macro(<ascii char>) doesn't
#                    bypass the active layout, this specific board has its
#                    grave/apostrophe keys hardware-swapped, and keyd v2.6.0
#                    segfaults on macro(102nd)/macro(S-102nd).
#   wine-focus-fix  — a Wine/Proton game on KDE Wayland that keeps the mouse
#                    but never gets the keyboard back after a click on
#                    another window: checks the prefix needs it, then sets
#                    UseTakeFocus=N (Wine's X11 driver) in it.
#
# Sourced helpers (scripts/_common/):
#   ui.sh   — header/info/success/warn/error_exit
#   deps.sh — _ensure_pkg, _pkg_manager, _require_sudo_or_instruct (dnf/apt/rpm-ostree aware)
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
TEMPLATES_DIR="${SCRIPT_DIR}/templates"

# shellcheck source=../_common/ui.sh
source "${COMMON_DIR}/ui.sh"
# shellcheck source=../_common/deps.sh
source "${COMMON_DIR}/deps.sh"
# shellcheck source=../_common/conf.sh
source "${COMMON_DIR}/conf.sh"

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
    WINE_FOCUS_PREFIX=""
    # Parsed, not sourced: a typed path holding a quote or $(...) ran as
    # code on the next start (Kamino 196).
    conf_load "$CONFIG_FILE" EA_PREFIX WINE_FOCUS_PREFIX
}

cfg_save() {
    conf_write "$CONFIG_FILE" EA_PREFIX WINE_FOCUS_PREFIX
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
# lofree-edge-fix — per-device keyd remap for a Lofree Edge keyboard
# -----------------------------------------------------------------------------
# See templates/lofree-edge.conf's header comment for the full story. Short
# version: KWin/Wayland only supports one global XKB layout for every
# keyboard at once, so a second keyboard that needs different punctuation
# can't be fixed via System Settings. keyd (github.com/rvaiya/keyd) is a
# udev-matched, per-device input remapper that runs below KWin and can give
# just this one device its own behavior.

LOFREE_EDGE_CONF="/etc/keyd/lofree-edge.conf"

_ensure_keyd() {
    command -v keyd &>/dev/null && { info "keyd found: $(command -v keyd)"; return 0; }

    local pm; pm="$(_pkg_manager)"
    [[ -z "$pm" ]] && error_exit "No supported package manager found (need dnf, apt, or rpm-ostree) to install keyd."

    info "keyd not found. It ships via COPR (alternateved/keyd) on Fedora-based systems."
    gum confirm "Install keyd now? (requires sudo)" || error_exit "keyd is required for this fix."

    case "$pm" in
        rpm-ostree)
            # Bazzite/Fedora Atomic: dnf5 is the copr-capable frontend even
            # though the image itself is managed via rpm-ostree.
            _require_sudo_or_instruct "Enabling the keyd COPR repo" "sudo dnf5 copr enable -y alternateved/keyd"
            if [[ ! -f /etc/yum.repos.d/_copr_alternateved-keyd.repo ]]; then
                sudo dnf5 copr enable -y alternateved/keyd \
                    || error_exit "Failed to enable the alternateved/keyd COPR repo."
            fi
            _require_sudo_or_instruct "Layering keyd via rpm-ostree" "sudo rpm-ostree install keyd"
            sudo rpm-ostree install keyd || error_exit "rpm-ostree install failed for keyd."
            warn "keyd layered via rpm-ostree — a REBOOT is required before it's available."
            if gum confirm "Reboot now?"; then
                systemctl reboot
            fi
            return 1
            ;;
        dnf)
            # Plain (mutable) Fedora — use dnf's own copr plugin, not dnf5,
            # since older Fedora releases may not have dnf5 at all.
            _require_sudo_or_instruct "Enabling the keyd COPR repo" "sudo dnf copr enable -y alternateved/keyd"
            if [[ ! -f /etc/yum.repos.d/_copr_alternateved-keyd.repo ]]; then
                sudo dnf copr enable -y alternateved/keyd \
                    || error_exit "Failed to enable the alternateved/keyd COPR repo."
            fi
            _require_sudo_or_instruct "Installing keyd" "sudo dnf install -y keyd"
            sudo dnf install -y keyd || error_exit "dnf install failed for keyd."
            ;;
        apt)
            _require_sudo_or_instruct "Installing keyd" "sudo apt-get update -qq && sudo apt-get install -y keyd"
            sudo apt-get update -qq && sudo apt-get install -y keyd \
                || error_exit "apt install failed for keyd. It may need a third-party repo on non-Fedora distros — see https://github.com/rvaiya/keyd#installation"
            ;;
    esac
    command -v keyd &>/dev/null || error_exit "keyd installation appears to have failed."
    success "keyd installed."
}

cmd_lofree_edge_fix() {
    header "Bazzite Utils — Lofree Edge Keyboard Fix"

    _ensure_keyd || return 0   # rpm-ostree path returns 1 pending reboot

    local template="${TEMPLATES_DIR}/lofree-edge.conf"
    [[ -f "$template" ]] || error_exit "Template not found: ${template}"

    gum confirm "Write ${LOFREE_EDGE_CONF} and (re)start the keyd service? (requires sudo)" \
        || { info "Cancelled."; return; }

    sudo mkdir -p "$(dirname "$LOFREE_EDGE_CONF")" \
        || error_exit "Failed to create $(dirname "$LOFREE_EDGE_CONF")."
    sudo cp "$template" "$LOFREE_EDGE_CONF" \
        || error_exit "Failed to write ${LOFREE_EDGE_CONF}."
    success "Wrote ${LOFREE_EDGE_CONF}."

    sudo systemctl enable --now keyd \
        || error_exit "Failed to enable/start the keyd service."

    if sudo keyd reload 2>/dev/null; then
        success "keyd reloaded — changes are live, no reboot needed."
    else
        warn "keyd reload failed (daemon may have just started) — check status."
    fi

    if systemctl is-active --quiet keyd; then
        success "keyd is running."
    else
        error_exit "keyd is not active after setup. Check: sudo journalctl -eu keyd"
    fi

    info "Test every remapped key on the Edge now (especially \` ~ [ ] { } @ < > ' \" \\ |)."
    warn "If a key is wrong, don't guess — re-derive it against /usr/share/X11/xkb/symbols/pt and re-edit ${template}, then re-run this command (or just edit ${LOFREE_EDGE_CONF} and \`sudo keyd reload\` directly for fast iteration)."
}

# -----------------------------------------------------------------------------
# wine-focus-fix — a Wine/Proton game that never gets the keyboard back
# -----------------------------------------------------------------------------
# On KDE Plasma (Wayland), a Wine/Proton game running through XWayland keeps
# the mouse but loses the keyboard after a click on another window (a
# terminal on the second monitor): clicking back into the game does not give
# it the keys again, only alt-tab does. Wine's X11 driver defaults to
# UseTakeFocus=Y - it asks the window manager for focus with the
# WM_TAKE_FOCUS handshake instead of taking it - and KWin drops that request.
# UseTakeFocus=N (HKCU\Software\Wine\X11 Driver) makes focus follow the click.
# Found 2026-11-16 on retail WoW (Battle.net prefix, GE-Proton 11-12).
#
# Per prefix, and only where it applies: a game on Wine's own Wayland driver
# (PROTON_ENABLE_WAYLAND=1, Graphics="wayland", no DISPLAY) never reads the
# X11 driver's settings. Never runs a Wine of its own choosing on a prefix:
# a different Wine than the prefix's "updates" it. So a live prefix is
# changed through its running session's own wine, and a stopped one by
# editing user.reg, after a backup.

# Overridable so the tests can stage processes and a session.
BZU_PROC="${BZU_PROC:-/proc}"

_wf_norm() { local p="${1%/}"; printf '%s' "${p:-/}"; }

# _wf_resolve <path> - the prefix a WINEPREFIX value really means. Proton and
# umu (Lutris, Heroic) are given the base folder and keep the prefix in its
# pfx/, so the base is followed there; then the real path, since on Bazzite
# /home is a symlink to /var/home and one prefix showed up twice.
_wf_resolve() {
    local p; p="$(_wf_norm "$1")"
    [[ ! -f "$p/user.reg" && -f "$p/pfx/user.reg" ]] && p="$p/pfx"
    _wf_norm "$(realpath -m -- "$p" 2>/dev/null || printf '%s' "$p")"
}

# Wine's own processes, left out of the names shown beside a prefix.
_WF_WINE_SYSTEM=" services.exe winedevice.exe svchost.exe plugplay.exe lsass.exe explorer.exe rpcss.exe tabtip.exe xalia.exe conhost.exe start.exe wineboot.exe rundll32.exe umu.exe steam.exe "

# _wf_env <pid> <VAR> - one variable from a process's environment.
_wf_env() {
    # The braces matter: in `tr < file 2>/dev/null` the < fails before the
    # 2> applies, and every other user's process printed "Permission denied".
    { tr '\0' '\n' < "${BZU_PROC}/$1/environ"; } 2>/dev/null | sed -n "s/^$2=//p" | head -1
}

# Prints "pid<TAB>prefix<TAB>name" for every readable process with a WINEPREFIX.
_wf_scan() {
    local d pid pfx
    for d in "${BZU_PROC}"/[0-9]*; do
        pid="${d##*/}"
        pfx="$(_wf_env "$pid" WINEPREFIX)"
        [[ -n "$pfx" ]] || continue
        printf '%s\t%s\t%s\n' "$pid" "$(_wf_resolve "$pfx")" "$(cat "$d/comm" 2>/dev/null)"
    done
}

# _wf_pids <prefix> - the processes running in that prefix.
_wf_pids() { _wf_scan | awk -F'\t' -v p="$1" '$2 == p { print $1 }'; }

# _wf_reg_value <prefix> - UseTakeFocus as user.reg holds it, or nothing.
_wf_reg_value() {
    awk '
        /^\[/ { insec = ($0 ~ /^\[Software\\\\Wine\\\\X11 Driver\]/); next }
        insec && /^"UseTakeFocus"=/ { v = $0; sub(/^"UseTakeFocus"="/, "", v); sub(/".*$/, "", v); print v; exit }
    ' "$1/user.reg"
}

# _wf_graphics_driver <prefix> - Graphics under HKCU\Software\Wine\Drivers.
_wf_graphics_driver() {
    awk '
        /^\[/ { insec = ($0 ~ /^\[Software\\\\Wine\\\\Drivers\]/); next }
        insec && /^"Graphics"=/ { v = $0; sub(/^"Graphics"="/, "", v); sub(/".*$/, "", v); print v; exit }
    ' "$1/user.reg"
}

# _wf_wine_for <prefix> - the wine binary of the session running in it: the
# one beside its wineserver, else $PROTONPATH's.
_wf_wine_for() {
    local pid exe pp
    for pid in $(_wf_pids "$1"); do
        exe="$(readlink "${BZU_PROC}/${pid}/exe" 2>/dev/null)" || continue
        if [[ "${exe##*/}" == wineserver* && -x "${exe%/*}/wine" ]]; then
            printf '%s' "${exe%/*}/wine"; return 0
        fi
    done
    for pid in $(_wf_pids "$1"); do
        pp="$(_wf_env "$pid" PROTONPATH)"
        if [[ -n "$pp" && -x "${pp%/}/files/bin/wine" ]]; then
            printf '%s' "${pp%/}/files/bin/wine"; return 0
        fi
    done
    return 1
}

# _wf_write_offline <prefix> <Y|N> - sets the value in user.reg, which must
# not be in use (the wineserver rewrites it on exit). Backed up first.
_wf_write_offline() {
    local reg="$1/user.reg" val="$2" tmp backup
    backup="${reg}.scomp-bak-$(date +%Y%m%d-%H%M%S)"
    cp -p "$reg" "$backup" || error_exit "Could not back up ${reg}."
    tmp="$(mktemp "${reg}.XXXXXX")" || error_exit "Could not create a temporary file next to ${reg}."
    # The value goes right after the section's header (and its #time line),
    # any old UseTakeFocus line in the section is dropped, and a prefix that
    # has no such section yet gets one at the end.
    awk -v val="$val" -v now="$(date +%s)" '
        function emit() { print "\"UseTakeFocus\"=\"" val "\"" }
        pending { if ($0 ~ /^#time=/) { print; emit(); pending = 0; next } emit(); pending = 0 }
        /^\[/ {
            insec = ($0 ~ /^\[Software\\\\Wine\\\\X11 Driver\]/)
            if (insec) { found = 1; print; pending = 1; next }
        }
        insec && /^"UseTakeFocus"=/ { next }
        { print }
        END {
            if (pending) emit()
            if (!found) { print ""; print "[Software\\\\Wine\\\\X11 Driver] " now; emit() }
        }
    ' "$reg" > "$tmp" || { rm -f "$tmp"; error_exit "Could not rewrite ${reg}."; }
    chmod --reference="$reg" "$tmp" 2>/dev/null || true
    mv -f "$tmp" "$reg" || error_exit "Could not replace ${reg} (backup: ${backup})."
    info "Backup of the previous registry: ${backup}"
}

# _wf_set <prefix> <Y|N> - live through the running session, else offline.
_wf_set() {
    local prefix="$1" val="$2" wine
    if [[ -n "$(_wf_pids "$prefix")" ]]; then
        wine="$(_wf_wine_for "$prefix")" \
            || error_exit "Wine is running in ${prefix}, but its wine binary could not be found. Close the game and its launcher, then run this again: the change is then written straight into user.reg."
        info "The prefix is running: setting it through its own session (${wine})."
        WINEPREFIX="$prefix" "$wine" reg add 'HKCU\Software\Wine\X11 Driver' \
            /v UseTakeFocus /t REG_SZ /d "$val" /f >/dev/null 2>&1 \
            || error_exit "wine reg add failed in ${prefix}."
        # wine's console output ends lines with CRLF: without stripping the
        # CR the value reads "N\r", never equal, and the CR garbles the error.
        local now
        now="$(WINEPREFIX="$prefix" "$wine" reg query 'HKCU\Software\Wine\X11 Driver' /v UseTakeFocus 2>/dev/null \
            | awk '/UseTakeFocus/ { sub(/\r$/, ""); print $NF }')"
        [[ "$now" == "$val" ]] || error_exit "The running session reports UseTakeFocus=${now:-unset} after setting ${val}."
        success "UseTakeFocus=${val} is set in the running session."
        warn "Wine writes it to user.reg only when the session ends: close the game AND its launcher normally (not killed), then start the game again. Running this command afterwards confirms it is on disk."
    else
        _wf_write_offline "$prefix" "$val"
        [[ "$(_wf_reg_value "$prefix")" == "$val" ]] \
            || error_exit "user.reg does not read back UseTakeFocus=${val}."
        success "UseTakeFocus=${val} written to ${prefix}/user.reg. Start the game to use it."
    fi
}

_wf_pick_prefix() {
    local -A seen=() names=()
    local pid pfx name opts=() choice
    while IFS=$'\t' read -r pid pfx name; do
        seen[$pfx]=1
        # The game's own .exe names, once each; Wine's processes left out.
        [[ "$name" == *.exe && "$_WF_WINE_SYSTEM" != *" ${name} "* ]] || continue
        [[ ", ${names[$pfx]:-}, " == *", ${name}, "* ]] && continue
        names[$pfx]+="${names[$pfx]:+, }${name}"
    done < <(_wf_scan)
    for pfx in "${!seen[@]}"; do
        opts+=("running: ${pfx}${names[$pfx]:+  (${names[$pfx]})}")
    done
    [[ -n "$WINE_FOCUS_PREFIX" && -z "${seen[$WINE_FOCUS_PREFIX]:-}" ]] && opts+=("saved: ${WINE_FOCUS_PREFIX}")
    opts+=("Enter a prefix path…")
    choice=$(gum choose "${opts[@]}" --header "Which Wine/Proton prefix does the game run in?") || true
    case "$choice" in
        running:*) pfx="${choice#running: }"; pfx="${pfx%%  (*}" ;;
        saved:*)   pfx="${choice#saved: }" ;;
        Enter*)
            pfx=$(gum input --value "${WINE_FOCUS_PREFIX:-}" \
                --header "Path to the prefix (the folder holding drive_c and user.reg):") || true ;;
        *) return 1 ;;
    esac
    [[ -n "$pfx" ]] || return 1
    pfx="${pfx/#\~/$HOME}"
    _wf_resolve "$pfx"
}

cmd_wine_focus_fix() {
    header "Bazzite Utils — Wine Keyboard-Focus Fix"
    cfg_load

    local prefix
    prefix="$(_wf_pick_prefix)" || { info "Cancelled."; return; }
    [[ -f "${prefix}/user.reg" && -d "${prefix}/drive_c" ]] \
        || error_exit "${prefix} is not a Wine prefix (no user.reg and drive_c there)."
    WINE_FOCUS_PREFIX="$prefix"
    cfg_save

    info "Checking whether ${prefix} needs it…"
    local current; current="$(_wf_reg_value "$prefix")"
    if [[ "$current" == "N" ]]; then
        success "Already applied: user.reg has UseTakeFocus=N. Nothing to do."
        if gum confirm --default=false "Undo it (back to Wine's default, Y)?"; then
            _wf_set "$prefix" Y
        fi
        return
    fi
    # Not "${current:-...Wine's...}": inside a ${...:-word}, bash reads the
    # apostrophe as an opening quote, even within double quotes.
    if [[ -n "$current" ]]; then
        info "UseTakeFocus: ${current}"
    else
        info "UseTakeFocus: not set (Wine's default, Y)"
    fi

    # 1. The setup the fix is for: KWin on Wayland.
    local desktop="${XDG_CURRENT_DESKTOP:-}" session="${XDG_SESSION_TYPE:-}"
    if [[ "$desktop" == *KDE* && "$session" == wayland ]]; then
        success "Session: KDE Plasma on Wayland - the setup that drops Wine's focus requests."
    else
        warn "Session: ${desktop:-unknown desktop} on ${session:-unknown}. This fix is for KDE Plasma on Wayland; elsewhere the cause is likely something else."
        gum confirm --default=false "Apply anyway?" || { info "Cancelled."; return; }
    fi

    # 2. The game must be on the X11 driver: Wine's Wayland driver never reads it.
    local graphics; graphics="$(_wf_graphics_driver "$prefix")"
    if [[ "$graphics" == wayland* ]]; then
        warn "The prefix's Graphics driver is \"${graphics}\": the game uses Wine's Wayland driver, which ignores UseTakeFocus. Not needed."
        return
    fi
    # DISPLAY is judged on the game's own .exe processes only: a launcher's
    # wrapper can carry the prefix without a DISPLAY (lutris-wrapper does).
    local pid running=0 wl="" nodisp=""
    for pid in $(_wf_pids "$prefix"); do
        running=1
        if [[ "$(_wf_env "$pid" PROTON_ENABLE_WAYLAND)" == 1 ]]; then wl=1; fi
        if [[ "$(cat "${BZU_PROC}/${pid}/comm" 2>/dev/null)" == *.exe && -z "$(_wf_env "$pid" DISPLAY)" ]]; then
            nodisp=1
        fi
    done
    if [[ -n "$wl" ]]; then
        warn "The game runs with PROTON_ENABLE_WAYLAND=1 (Wine's Wayland driver), which ignores UseTakeFocus. Not needed."
        return
    fi
    if (( running )); then
        if [[ -n "$nodisp" ]]; then
            warn "A process in this prefix has no DISPLAY, so it may be on Wine's Wayland driver, where this setting does nothing."
        else
            success "The game is running through XWayland (Wine's X11 driver): the setting applies."
        fi
    else
        info "Nothing is running in this prefix: it will use the X11 driver unless launched with PROTON_ENABLE_WAYLAND=1."
    fi

    gum confirm "Set UseTakeFocus=N in ${prefix}?" || { info "Cancelled."; return; }
    _wf_set "$prefix" N
    info "Test: click a window on another monitor, then click once back into the game and press a key."
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
            lofree-edge-fix)  cmd_lofree_edge_fix ;;
            wine-focus-fix)   cmd_wine_focus_fix ;;
            *) error_exit "Unknown command: $1 (expected: ea-fix|ubisoft-rws|kwin-greeter-fix|lofree-edge-fix|wine-focus-fix)" ;;
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
            "lofree-edge-fix  — fix punctuation on a Lofree Edge Bluetooth keyboard" \
            "wine-focus-fix   — give a Wine/Proton game the keyboard back after clicking away" \
            "quit" \
            --header "Choose a utility:") || true

        [[ -z "$action" || "$action" == "quit" ]] && { gum style --faint "Bye."; exit 0; }

        case "$action" in
            ea-fix*)           cmd_ea_fix ;;
            ubisoft-rws*)      cmd_ubisoft_rws ;;
            kwin-greeter-fix*) cmd_kwin_greeter_fix ;;
            lofree-edge-fix*)  cmd_lofree_edge_fix ;;
            wine-focus-fix*)   cmd_wine_focus_fix ;;
        esac

        echo ""
        gum confirm "Back to main menu?" || { gum style --faint "Bye."; exit 0; }
    done
}

main "$@"
