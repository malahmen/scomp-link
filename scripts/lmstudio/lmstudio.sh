#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# lmstudio.sh
# Interactive TUI for installing and managing LM Studio (Flatpak) so that the
# `lms` CLI works out of the box, with an optional headless boot-time service.
#
# Background (why this script exists):
#   LM Studio's Flatpak has a static `persistent=.lmstudio` permission that
#   sandboxes `~/.lmstudio` to `~/.var/app/ai.lmstudio.lm-studio/.lmstudio`.
#   If "LM Studio Home" ever gets pointed at the real `~/.lmstudio` (e.g. a
#   leftover from a prior non-Flatpak install), the app's identity/passkey
#   machinery still resolves to the sandboxed copy while other state resolves
#   to the real one — two divergent passkeys, and `lms` fails with
#   "Invalid passkey for lms CLI client". Granting the sandbox full
#   `--filesystem=home` access (done unconditionally by cmd_install below)
#   makes path resolution consistent everywhere and prevents this outright.
#
# Sourced helpers (scripts/_common/):
#   ui.sh — header/info/success/warn/error_exit
#
# Config: ~/.config/lmstudio-tui/lmstudio.conf (XDG-style, key=value)
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

trap 'echo ""; gum style --faint "Interrupted."; exit 0' INT TERM

# -----------------------------------------------------------------------------
# Constants
# -----------------------------------------------------------------------------

APP_ID="ai.lmstudio.lm-studio"
FLATHUB_REPO="https://flathub.org/repo/flathub.flatpakrepo"
LMSTUDIO_HOME="${HOME}/.lmstudio"

CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/lmstudio-tui"
CONFIG_DIR="${CONFIG_DIR/#\~/$HOME}"
CONFIG_FILE="${CONFIG_DIR}/lmstudio.conf"

SYSTEMD_USER_DIR="${HOME}/.config/systemd/user"
XVFB_UNIT="${SYSTEMD_USER_DIR}/lmstudio-xvfb.service"
APP_UNIT="${SYSTEMD_USER_DIR}/lmstudio.service"
WRAPPER_SCRIPT="${CONFIG_DIR}/lmstudio-headless.sh"

mkdir -p "$CONFIG_DIR"

# -----------------------------------------------------------------------------
# Config persistence
# -----------------------------------------------------------------------------

cfg_load() {
    INSTALL_SCOPE="user"
    XVFB_DISPLAY="99"
    SERVICE_ENABLED="false"

    [[ -f "$CONFIG_FILE" ]] || return 0
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
}

cfg_save() {
    cat > "$CONFIG_FILE" <<EOF
INSTALL_SCOPE="${INSTALL_SCOPE}"
XVFB_DISPLAY="${XVFB_DISPLAY}"
SERVICE_ENABLED="${SERVICE_ENABLED}"
EOF
}

# -----------------------------------------------------------------------------
# Dependency helpers
# -----------------------------------------------------------------------------

_pkg_manager() {
    if command -v dnf &>/dev/null; then echo "dnf";
    elif command -v apt-get &>/dev/null; then echo "apt";
    else error_exit "Unsupported distro — need dnf or apt to install flatpak/Xvfb."
    fi
}

_require_sudo_or_instruct() {
    # $1: human description, $2...: the command to hand back to the user
    local desc="$1"; shift
    if sudo -n true 2>/dev/null; then
        return 0
    fi
    warn "${desc} requires sudo, and this session has no passwordless sudo / TTY for a password prompt."
    error_exit "Please run this yourself in a terminal, then re-run this script:
  $*"
}

_ensure_flatpak() {
    if command -v flatpak &>/dev/null; then
        info "flatpak found: $(flatpak --version)"
        return
    fi
    info "flatpak not found. Installing..."
    local pm; pm="$(_pkg_manager)"
    case "$pm" in
        dnf) _require_sudo_or_instruct "Installing flatpak" "sudo dnf install -y flatpak"
             sudo dnf install -y flatpak ;;
        apt) _require_sudo_or_instruct "Installing flatpak" "sudo apt-get update -qq && sudo apt-get install -y flatpak"
             sudo apt-get update -qq && sudo apt-get install -y flatpak ;;
    esac
    command -v flatpak &>/dev/null || error_exit "flatpak installation failed."
    success "flatpak installed."
}

_ensure_xvfb() {
    if command -v Xvfb &>/dev/null; then
        info "Xvfb found: $(command -v Xvfb)"
        return
    fi
    info "Xvfb not found. Installing (needed to run LM Studio headless)..."
    local pm; pm="$(_pkg_manager)"
    case "$pm" in
        dnf) _require_sudo_or_instruct "Installing Xvfb" "sudo dnf install -y xorg-x11-server-Xvfb"
             sudo dnf install -y xorg-x11-server-Xvfb ;;
        apt) _require_sudo_or_instruct "Installing Xvfb" "sudo apt-get update -qq && sudo apt-get install -y xvfb"
             sudo apt-get update -qq && sudo apt-get install -y xvfb ;;
    esac
    command -v Xvfb &>/dev/null || error_exit "Xvfb installation failed."
    success "Xvfb installed."
}

_ensure_flathub_remote() {
    if [[ "$INSTALL_SCOPE" == "user" ]]; then
        flatpak remote-add --user --if-not-exists flathub "$FLATHUB_REPO"
    else
        _require_sudo_or_instruct "Adding the flathub remote system-wide" \
            "sudo flatpak remote-add --if-not-exists flathub $FLATHUB_REPO"
        sudo flatpak remote-add --if-not-exists flathub "$FLATHUB_REPO"
    fi
}

_app_installed() {
    flatpak list --app --columns=application 2>/dev/null | grep -qx "$APP_ID"
}

# -----------------------------------------------------------------------------
# install — core steps
# -----------------------------------------------------------------------------

_install_app() {
    if _app_installed; then
        info "LM Studio (${APP_ID}) is already installed."
        return
    fi

    info "Installing LM Studio via Flatpak (${INSTALL_SCOPE} scope)..."
    if [[ "$INSTALL_SCOPE" == "user" ]]; then
        gum spin --spinner dot --title "flatpak install --user flathub ${APP_ID}..." -- \
            flatpak install --user -y flathub "$APP_ID" \
            || error_exit "flatpak install failed."
    else
        _require_sudo_or_instruct "Installing LM Studio system-wide" \
            "sudo flatpak install -y flathub $APP_ID"
        gum spin --spinner dot --title "flatpak install flathub ${APP_ID}..." -- \
            sudo flatpak install -y flathub "$APP_ID" \
            || error_exit "flatpak install failed."
    fi
    success "LM Studio installed."
}

# The fix for the passkey bug: grant the sandbox full home access so every
# code path inside the app (identity/passkey included) resolves the same
# `~/.lmstudio` regardless of any custom "LM Studio Home" setting.
_apply_sandbox_override() {
    info "Granting LM Studio's sandbox consistent home-directory access..."
    flatpak override --user --filesystem=home "$APP_ID" \
        || error_exit "flatpak override failed."
    success "Sandbox override applied (filesystems=home)."
}

# Launches the app against a throwaway Xvfb display just long enough for its
# first-run bootstrap (copies the lms binary into ~/.lmstudio/bin, patches
# shell rc files, generates the passkey) to complete, then kills it.
_bootstrap_cli() {
    if [[ -x "${LMSTUDIO_HOME}/bin/lms" ]] && "${LMSTUDIO_HOME}/bin/lms" status &>/dev/null; then
        info "lms CLI already bootstrapped and talking to a running server."
        return
    fi

    _ensure_xvfb

    local bootstrap_display=":77"
    info "Starting a throwaway headless display for first-run setup..."
    Xvfb "$bootstrap_display" -screen 0 1280x1024x24 -nolisten tcp &
    local xvfb_pid=$!
    sleep 1

    info "Launching LM Studio once to complete first-run bootstrap..."
    DISPLAY="$bootstrap_display" flatpak run "$APP_ID" &
    local app_pid=$!

    if ! gum spin --spinner dot --title "Waiting for lms CLI to become available..." -- \
        bash -c '
            for i in $(seq 1 60); do
                [[ -x "'"${LMSTUDIO_HOME}"'/bin/lms" ]] && "'"${LMSTUDIO_HOME}"'/bin/lms" status &>/dev/null && exit 0
                sleep 1
            done
            exit 1
        '; then
        kill "$app_pid" 2>/dev/null || true
        kill "$xvfb_pid" 2>/dev/null || true
        error_exit "LM Studio did not finish first-run bootstrap in time. Try running 'lmstudio.sh install' again."
    fi

    flatpak kill "$APP_ID" 2>/dev/null || true
    kill "$xvfb_pid" 2>/dev/null || true
    sleep 1

    export PATH="${LMSTUDIO_HOME}/bin:$PATH"
    command -v lms &>/dev/null || warn "lms not yet on PATH for this shell — open a new terminal (bootstrap already patched your shell rc files)."
    success "lms CLI bootstrapped: $("${LMSTUDIO_HOME}/bin/lms" version 2>/dev/null | grep -m1 'lms' || echo 'ok')"
}

# -----------------------------------------------------------------------------
# service — headless boot-time autostart (Xvfb + LM Studio, no login required)
# -----------------------------------------------------------------------------

_write_wrapper_script() {
    cat > "$WRAPPER_SCRIPT" <<EOF
#!/usr/bin/env bash
set -euo pipefail
export DISPLAY=:${XVFB_DISPLAY}
export PATH="${LMSTUDIO_HOME}/bin:\$PATH"

flatpak run ${APP_ID} &
app_pid=\$!

# Guarantee the local API server is up regardless of the app's own
# "start server on launch" setting.
for i in \$(seq 1 60); do
    if lms status &>/dev/null; then
        lms server start &>/dev/null || true
        break
    fi
    sleep 1
done

wait "\$app_pid"
EOF
    chmod +x "$WRAPPER_SCRIPT"
}

_write_systemd_units() {
    mkdir -p "$SYSTEMD_USER_DIR"

    cat > "$XVFB_UNIT" <<EOF
[Unit]
Description=Headless X server for LM Studio

[Service]
ExecStart=/usr/bin/Xvfb :${XVFB_DISPLAY} -screen 0 1280x1024x24 -nolisten tcp
Restart=on-failure

[Install]
WantedBy=default.target
EOF

    cat > "$APP_UNIT" <<EOF
[Unit]
Description=LM Studio (headless, autostart)
After=lmstudio-xvfb.service network-online.target
Requires=lmstudio-xvfb.service
Wants=network-online.target

[Service]
ExecStart=${WRAPPER_SCRIPT}
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
EOF
}

cmd_service_enable() {
    header "LM Studio — Enable headless boot service"
    cfg_load

    _ensure_xvfb
    _apply_sandbox_override

    local display
    display=$(gum input --value "${XVFB_DISPLAY}" --header "Xvfb display number to use:") || true
    XVFB_DISPLAY="${display:-$XVFB_DISPLAY}"

    _write_wrapper_script
    _write_systemd_units

    systemctl --user daemon-reload
    systemctl --user enable lmstudio-xvfb.service lmstudio.service

    if gum confirm "Enable lingering so this starts at boot even when you're not logged in? (recommended)"; then
        loginctl enable-linger "$(whoami)" \
            || warn "Could not enable linger (needs polkit permission for your own user, or run: sudo loginctl enable-linger $(whoami))"
    else
        warn "Skipped linger — the service will only start once you log in."
    fi

    info "Starting services now..."
    systemctl --user restart lmstudio-xvfb.service
    sleep 2
    systemctl --user restart lmstudio.service

    if ! gum spin --spinner dot --title "Waiting for LM Studio server to come up..." -- \
        bash -c 'export PATH="'"${LMSTUDIO_HOME}"'/bin:$PATH"; for i in $(seq 1 60); do lms status &>/dev/null && exit 0; sleep 1; done; exit 1'; then
        warn "Server did not respond yet — check: journalctl --user -u lmstudio.service -f"
    else
        success "LM Studio is running headless. lms status:"
        PATH="${LMSTUDIO_HOME}/bin:$PATH" lms status || true
    fi

    SERVICE_ENABLED="true"
    cfg_save
    success "Headless service enabled. It will survive reboots (and logins, if linger is on)."
    info "Manage it with: systemctl --user {status|restart|stop} lmstudio.service"
}

cmd_service_disable() {
    header "LM Studio — Disable headless boot service"
    cfg_load

    systemctl --user stop lmstudio.service lmstudio-xvfb.service 2>/dev/null || true
    systemctl --user disable lmstudio.service lmstudio-xvfb.service 2>/dev/null || true

    if gum confirm "Also disable lingering for your user (only if nothing else relies on it)?"; then
        loginctl disable-linger "$(whoami)" 2>/dev/null || true
    fi

    SERVICE_ENABLED="false"
    cfg_save
    success "Headless service disabled. Unit files left in place under ${SYSTEMD_USER_DIR} — re-run 'service-enable' to turn it back on."
}

# -----------------------------------------------------------------------------
# cmd: install
# -----------------------------------------------------------------------------

cmd_install() {
    header "LM Studio — Install"
    cfg_load

    local scope
    scope=$(gum choose \
        "user  (recommended — no root needed)" \
        "system  (requires root)" \
        --header "Install scope:") || true
    [[ -z "$scope" ]] && error_exit "Install scope is required."
    case "$scope" in
        user*)   INSTALL_SCOPE="user" ;;
        system*) INSTALL_SCOPE="system" ;;
    esac

    _ensure_flatpak
    _ensure_flathub_remote
    _install_app

    # Applied unconditionally and BEFORE first launch — this is what prevents
    # the "Invalid passkey" bug from ever showing up on this machine.
    _apply_sandbox_override

    _bootstrap_cli

    cfg_save

    if gum confirm "Set up LM Studio to run as a background service, starting even without login?"; then
        cmd_service_enable
    else
        info "Skipping headless service. Launch normally with: flatpak run ${APP_ID}"
    fi

    success "Install complete."
}

# -----------------------------------------------------------------------------
# cmd: status
# -----------------------------------------------------------------------------

cmd_status() {
    header "LM Studio — Status"
    cfg_load

    gum style --foreground "${CYAN}" --bold "── Flatpak"
    if _app_installed; then
        flatpak info "$APP_ID" 2>/dev/null | head -5
    else
        warn "Not installed."
    fi

    gum style --foreground "${CYAN}" --bold "── Sandbox permissions"
    flatpak info --show-permissions "$APP_ID" 2>/dev/null | grep -E "^filesystems|^persistent" || warn "Could not read permissions."

    gum style --foreground "${CYAN}" --bold "── Headless service"
    if [[ -f "$APP_UNIT" ]]; then
        systemctl --user status lmstudio.service --no-pager 2>/dev/null | head -6 || true
        info "Linger: $(loginctl show-user "$(whoami)" -p Linger 2>/dev/null || echo unknown)"
    else
        info "Not configured. Run: lmstudio.sh service-enable"
    fi

    gum style --foreground "${CYAN}" --bold "── API server"
    if command -v lms &>/dev/null; then
        lms status 2>&1 || true
    else
        PATH="${LMSTUDIO_HOME}/bin:$PATH" "${LMSTUDIO_HOME}/bin/lms" status 2>&1 || warn "lms CLI not found."
    fi
}

# -----------------------------------------------------------------------------
# cmd: uninstall
# -----------------------------------------------------------------------------

cmd_uninstall() {
    header "LM Studio — Uninstall"
    cfg_load

    gum confirm "This stops the headless service (if any) and removes the LM Studio Flatpak app. Continue?" \
        || { info "Cancelled."; return; }

    systemctl --user stop lmstudio.service lmstudio-xvfb.service 2>/dev/null || true
    systemctl --user disable lmstudio.service lmstudio-xvfb.service 2>/dev/null || true
    rm -f "$XVFB_UNIT" "$APP_UNIT" "$WRAPPER_SCRIPT"
    systemctl --user daemon-reload 2>/dev/null || true

    if _app_installed; then
        flatpak uninstall -y "$APP_ID" 2>/dev/null \
            || sudo flatpak uninstall -y "$APP_ID" \
            || warn "flatpak uninstall failed — remove manually."
    fi

    if [[ -d "$LMSTUDIO_HOME" ]]; then
        warn "Model files and data live at ${LMSTUDIO_HOME} (can be large)."
        if gum confirm "Delete ${LMSTUDIO_HOME} too?"; then
            rm -rf "$LMSTUDIO_HOME"
            success "Removed ${LMSTUDIO_HOME}."
        fi
    fi

    rm -f "$CONFIG_FILE"
    success "LM Studio uninstalled."
}

# -----------------------------------------------------------------------------
# Main dispatch
# -----------------------------------------------------------------------------

main() {
    if [[ $# -gt 0 ]]; then
        case "$1" in
            install)          cmd_install ;;
            uninstall)        cmd_uninstall ;;
            status)           cmd_status ;;
            service-enable)   cmd_service_enable ;;
            service-disable)  cmd_service_disable ;;
            *) error_exit "Unknown command: $1 (expected: install|uninstall|status|service-enable|service-disable)" ;;
        esac
        exit 0
    fi

    while true; do
        header "LM Studio Manager"
        local action
        action=$(gum choose \
            "install" "status" "service-enable" "service-disable" "uninstall" "quit" \
            --header "Choose an action:") || true

        [[ -z "$action" || "$action" == "quit" ]] && { gum style --faint "Bye."; exit 0; }

        case "$action" in
            install)         cmd_install ;;
            status)          cmd_status ;;
            service-enable)  cmd_service_enable ;;
            service-disable) cmd_service_disable ;;
            uninstall)       cmd_uninstall ;;
        esac

        echo ""
        gum confirm "Back to main menu?" || { gum style --faint "Bye."; exit 0; }
    done
}

main "$@"
