#!/usr/bin/env bash
# description: Build & install the ComfyEngine memory scanner from source
# Standalone export (export.sh): no extra setup deps — build deps (cmake/g++/Qt6/Capstone) are installed at runtime.
# -----------------------------------------------------------------------------
# comfyengine.sh
# Interactive TUI to build and install ComfyEngine
# (https://github.com/kashithecomfy/ComfyEngine) — a Linux-native memory
# scanner — from source, with a desktop shortcut. Linux-only (Qt 6 + ptrace).
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
WATCH_NAME="ce_watch"                              # runtime helper produced by the build
WATCH_PATH="/usr/local/bin/${WATCH_NAME}"
# Upstream's CMake defines NO install() rule, so we copy the built binaries
# ourselves. They land under the build tree at these paths (add_executable names).
BUILT_MAIN="${BUILD_DIR}/src/${BIN_NAME}"
BUILT_WATCH="${BUILD_DIR}/${WATCH_NAME}/${WATCH_NAME}"
DESKTOP_FILE="${HOME}/.local/share/applications/comfyengine.desktop"

# -----------------------------------------------------------------------------
# Dependencies
# -----------------------------------------------------------------------------

# ComfyEngine is a Linux-native, Qt 6 + ptrace tool; nothing to build elsewhere.
_require_linux() {
    [[ "$(uname -s)" == "Linux" ]] && return 0
    error_exit "ComfyEngine is Linux-only (Qt 6 + ptrace); it can't be built or run on $(uname -s)."
}

_ensure_build_deps() {
    _ensure_pkg git      git         git
    _ensure_pkg cmake    cmake       cmake
    _ensure_pkg make     make        make
    _ensure_pkg g++      gcc-c++     g++
    # ComfyEngine's CMake build needs Qt 6 (Widgets) + Capstone; these are -dev
    # libraries with no single checkable binary, so install them in bulk.
    _ensure_pkgs "qt6-qtbase-devel capstone-devel" "qt6-base-dev libcapstone-dev"
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
        bash -c "cmake -S '${INSTALL_DIR}' -B '${BUILD_DIR}' -DCMAKE_BUILD_TYPE=Release && cmake --build '${BUILD_DIR}'" \
        || error_exit "Build failed. Re-run 'cmake --build ${BUILD_DIR}' to see the full compiler output."

    # Upstream ships no install() rule, so place the built binaries ourselves.
    [[ -x "$BUILT_MAIN" ]] || error_exit "Build finished but ${BUILT_MAIN} was not produced (upstream build layout may have changed)."
    local cmd="sudo install -Dm755 ${BUILT_MAIN} ${BIN_PATH}"
    [[ -x "$BUILT_WATCH" ]] && cmd+=" && sudo install -Dm755 ${BUILT_WATCH} ${WATCH_PATH}"
    _require_sudo_or_instruct "Installing ComfyEngine to /usr/local/bin" "$cmd"
    sudo install -Dm755 "$BUILT_MAIN" "$BIN_PATH" || error_exit "Install step failed."
    success "Installed ${BIN_PATH}"
    if [[ -x "$BUILT_WATCH" ]]; then
        sudo install -Dm755 "$BUILT_WATCH" "$WATCH_PATH" \
            && info "Installed runtime helper ${WATCH_PATH}" \
            || warn "Could not install the ce_watch helper (the app may need it at runtime)."
    else
        warn "ce_watch helper not found in the build — the app may need it at runtime."
    fi

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

    local b
    for b in "$BIN_PATH" "$WATCH_PATH"; do
        [[ -f "$b" ]] || continue
        _require_sudo_or_instruct "Removing ${b}" "sudo rm -f ${b}"
        sudo rm -f "$b" && success "Removed ${b}."
    done

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
    [[ -x "$WATCH_PATH" ]] && info "Runtime helper: ${WATCH_PATH}" || info "Runtime helper: ${WATCH_NAME} not installed"
    [[ -d "$INSTALL_DIR" ]] && info "Source checkout: ${INSTALL_DIR}"
    [[ -f "$DESKTOP_FILE" ]] && info "Desktop shortcut: ${DESKTOP_FILE}"
}

# -----------------------------------------------------------------------------
# Main dispatch
# -----------------------------------------------------------------------------

main() {
    _require_linux
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
