#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# comfyengine.sh
# Interactive TUI to build and install ComfyEngine
# (https://github.com/kashithecomfy/ComfyEngine) — a Linux-native memory
# scanner — from source, with a desktop shortcut.
#
# Sourced helpers (scripts/_common/):
#   ui.sh   — header/info/success/warn/error_exit
#   deps.sh — _ensure_pkg (dnf/apt/rpm-ostree aware), _require_sudo_or_instruct
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
# Constants
# -----------------------------------------------------------------------------

REPO_URL="https://github.com/kashithecomfy/ComfyEngine.git"
INSTALL_DIR="${HOME}/ComfyEngine"
BUILD_DIR="${INSTALL_DIR}/build"
BIN_NAME="comfyengine"
BIN_PATH="/usr/local/bin/${BIN_NAME}"
DESKTOP_FILE="${HOME}/.local/share/applications/comfyengine.desktop"

# -----------------------------------------------------------------------------
# Dependencies
# -----------------------------------------------------------------------------

_ensure_build_deps() {
    _ensure_pkg git      git         git
    _ensure_pkg cmake    cmake       cmake
    _ensure_pkg make     make        make
    _ensure_pkg g++      gcc-c++     g++
}

# -----------------------------------------------------------------------------
# install
# -----------------------------------------------------------------------------

_create_shortcut() {
    info "Creating desktop shortcut..."
    mkdir -p "$(dirname "$DESKTOP_FILE")"
    cat > "$DESKTOP_FILE" <<EOF
[Desktop Entry]
Version=1.0
Name=ComfyEngine
Comment=Linux-native memory scanner
Exec=${BIN_PATH}
Icon=application-x-executable
Terminal=false
Type=Application
Categories=Utility;Development;
EOF
    chmod +x "$DESKTOP_FILE"
    success "Desktop shortcut created at ${DESKTOP_FILE}."
}

cmd_install() {
    header "ComfyEngine — Install"

    _ensure_build_deps

    if [[ -d "$INSTALL_DIR" ]]; then
        gum confirm "Existing checkout found at ${INSTALL_DIR}. Remove and rebuild from scratch?" \
            || { info "Cancelled."; return; }
        rm -rf "$INSTALL_DIR"
    fi

    info "Cloning ComfyEngine..."
    gum spin --spinner dot --title "git clone ${REPO_URL}..." -- \
        git clone "$REPO_URL" "$INSTALL_DIR" \
        || error_exit "Failed to clone repository."

    mkdir -p "$BUILD_DIR"
    info "Configuring and building (this can take a few minutes)..."
    gum spin --spinner dot --title "Building ComfyEngine..." -- \
        bash -c "cd '${BUILD_DIR}' && cmake -S .. -B . -DCMAKE_BUILD_TYPE=Release && cmake --build . --config Release" \
        || error_exit "Build failed. Re-run with 'cd ${BUILD_DIR} && cmake --build .' to see full compiler output."

    _require_sudo_or_instruct "Installing ComfyEngine to /usr/local" "sudo cmake --install ${BUILD_DIR}"
    sudo cmake --install "$BUILD_DIR" || error_exit "Install step failed."

    _create_shortcut

    success "ComfyEngine installed: ${BIN_PATH}"
}

# -----------------------------------------------------------------------------
# uninstall
# -----------------------------------------------------------------------------

cmd_uninstall() {
    header "ComfyEngine — Uninstall"

    gum confirm "This removes the binary, source checkout, and desktop shortcut. Continue?" \
        || { info "Cancelled."; return; }

    if [[ -f "$BIN_PATH" ]]; then
        _require_sudo_or_instruct "Removing ${BIN_PATH}" "sudo rm -f ${BIN_PATH}"
        sudo rm -f "$BIN_PATH" && success "Binary removed."
    fi

    [[ -d "$INSTALL_DIR" ]] && rm -rf "$INSTALL_DIR" && success "Source directory removed."
    [[ -f "$DESKTOP_FILE" ]] && rm -f "$DESKTOP_FILE" && success "Desktop shortcut removed."

    success "Uninstall complete."
}

# -----------------------------------------------------------------------------
# status
# -----------------------------------------------------------------------------

cmd_status() {
    header "ComfyEngine — Status"

    if [[ -x "$BIN_PATH" ]]; then
        success "Installed: ${BIN_PATH}"
    else
        warn "Not installed (${BIN_PATH} not found)."
    fi
    [[ -d "$INSTALL_DIR" ]] && info "Source checkout: ${INSTALL_DIR}"
    [[ -f "$DESKTOP_FILE" ]] && info "Desktop shortcut: ${DESKTOP_FILE}"
}

# -----------------------------------------------------------------------------
# Main dispatch
# -----------------------------------------------------------------------------

main() {
    if [[ $# -gt 0 ]]; then
        case "$1" in
            install)   cmd_install ;;
            uninstall) cmd_uninstall ;;
            status)    cmd_status ;;
            *) error_exit "Unknown command: $1 (expected: install|uninstall|status)" ;;
        esac
        exit 0
    fi

    while true; do
        header "ComfyEngine Manager"
        local action
        action=$(gum choose "install" "uninstall" "status" "quit" --header "Choose an action:") || true
        [[ -z "$action" || "$action" == "quit" ]] && { gum style --faint "Bye."; exit 0; }

        case "$action" in
            install)   cmd_install ;;
            uninstall) cmd_uninstall ;;
            status)    cmd_status ;;
        esac

        echo ""
        gum confirm "Back to main menu?" || { gum style --faint "Bye."; exit 0; }
    done
}

main "$@"
