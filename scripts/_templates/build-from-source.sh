#!/usr/bin/env bash
# description: TODO one-line summary (e.g. "Build & install <tool> from source")
# Standalone export (export.sh): no extra setup deps — OS build packages are installed at runtime (Linux-only).
# -----------------------------------------------------------------------------
# TEMPLATE — build a Linux-native tool from source.
#
# The shape shared by comfyengine and gameconqueror: clone an upstream repo,
# install the build (and runtime) dependencies via the shared, package-manager-
# aware helpers, build, install into /usr/local (or /usr), add a desktop shortcut,
# and offer status / uninstall. Guarded to Linux since these tools don't build
# elsewhere.
#
# HOW TO USE: copy to scripts/<name>/<name>.sh, set REPO_URL and the paths, fill
# in _ensure_build_deps and the build/install commands FROM UPSTREAM'S OWN docs
# (don't guess — verify the deps, the build system, and whether upstream defines
# an install rule). Delete this block.
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
source "${COMMON_DIR}/deps.sh"   # _ensure_pkg <bin> <dnf-pkg> [apt-pkg]; _ensure_pkgs "<dnf…>" "<apt…>"; _require_sudo_or_instruct

trap 'echo ""; gum style --faint "Interrupted."; exit 0' INT TERM

# -----------------------------------------------------------------------------
# Constants   — TODO: set the repo, paths, and produced binary
# -----------------------------------------------------------------------------
REPO_URL="https://github.com/OWNER/foo.git"
INSTALL_DIR="${HOME}/foo"
BUILD_DIR="${INSTALL_DIR}/build"
BIN_NAME="foo"
BIN_PATH="/usr/local/bin/${BIN_NAME}"
BUILT_BIN="${BUILD_DIR}/${BIN_NAME}"   # TODO: where the build actually drops the binary (verify!)
DESKTOP_FILE="${HOME}/.local/share/applications/${BIN_NAME}.desktop"

# -----------------------------------------------------------------------------
# Guards & dependencies
# -----------------------------------------------------------------------------
_require_linux() {
    [[ "$(uname -s)" == "Linux" ]] && return 0
    error_exit "${BIN_NAME} is Linux-only; it can't be built or run on $(uname -s)."
}

_ensure_build_deps() {
    # _ensure_pkg for tools with a checkable binary; _ensure_pkgs for -dev libs
    # that have none. TODO: replace with the EXACT deps from upstream's build docs.
    _ensure_pkg git   git   git
    _ensure_pkg cmake cmake cmake
    _ensure_pkg make  make  make
    _ensure_pkg g++   gcc-c++ g++
    # _ensure_pkgs "somelib-devel" "libsome-dev"
}

# Runtime deps the built app needs to actually launch (GUI libs, etc.), if any.
_ensure_runtime_deps() {
    : # TODO: e.g. _ensure_pkgs "gtk3 polkit" "gir1.2-gtk-3.0 policykit-1"
}

_create_shortcut() {
    mkdir -p "$(dirname "$DESKTOP_FILE")"
    cat > "$DESKTOP_FILE" <<EOF
[Desktop Entry]
Version=1.0
Name=Foo
Comment=TODO
Exec=${BIN_PATH}
Icon=application-x-executable
Terminal=false
Type=Application
Categories=Utility;
EOF
    chmod +x "$DESKTOP_FILE"; success "Desktop shortcut: ${DESKTOP_FILE}"
}

# -----------------------------------------------------------------------------
cmd_install() {
    header "Foo — Install"
    _ensure_build_deps
    _ensure_runtime_deps

    if [[ -d "$INSTALL_DIR" ]]; then
        gum confirm "Existing checkout at ${INSTALL_DIR}. Remove and rebuild?" || { info "Cancelled."; return; }
        rm -rf "$INSTALL_DIR"
    fi
    gum spin --spinner dot --title "Cloning ${REPO_URL}..." -- git clone "$REPO_URL" "$INSTALL_DIR" \
        || error_exit "clone failed."

    # TODO: replace with upstream's real build commands.
    gum spin --spinner dot --title "Building..." -- \
        bash -c "cmake -S '${INSTALL_DIR}' -B '${BUILD_DIR}' -DCMAKE_BUILD_TYPE=Release && cmake --build '${BUILD_DIR}'" \
        || error_exit "Build failed. Re-run 'cmake --build ${BUILD_DIR}' to see the full output."

    # Many projects define NO cmake/make install rule — check before relying on one.
    # If they don't, copy the built binary yourself (as below); if they do, use it.
    [[ -x "$BUILT_BIN" ]] || error_exit "Build finished but ${BUILT_BIN} was not produced (verify the path)."
    _require_sudo_or_instruct "Installing to ${BIN_PATH}" "sudo install -Dm755 ${BUILT_BIN} ${BIN_PATH}"
    sudo install -Dm755 "$BUILT_BIN" "$BIN_PATH" || error_exit "Install failed."

    _create_shortcut
    success "Installed: ${BIN_PATH}"
}

cmd_uninstall() {
    header "Foo — Uninstall"
    gum confirm "Remove binary, source checkout, and shortcut?" || { info "Cancelled."; return; }
    # If upstream has an uninstall target, prefer it: sudo make -C "$BUILD_DIR" uninstall
    [[ -f "$BIN_PATH" ]] && { _require_sudo_or_instruct "Removing ${BIN_PATH}" "sudo rm -f ${BIN_PATH}"; sudo rm -f "$BIN_PATH" && success "Binary removed."; }
    [[ -d "$INSTALL_DIR" ]] && rm -rf "$INSTALL_DIR" && success "Source removed."
    [[ -f "$DESKTOP_FILE" ]] && rm -f "$DESKTOP_FILE" && success "Shortcut removed."
}

cmd_status() {
    header "Foo — Status"
    [[ -x "$BIN_PATH" ]] && success "Installed: ${BIN_PATH}" || warn "Not installed (${BIN_PATH} not found)."
    [[ -d "$INSTALL_DIR" ]] && info "Source checkout: ${INSTALL_DIR}"
}

# -----------------------------------------------------------------------------
main() {
    _require_linux
    if [[ $# -gt 0 ]]; then
        case "$1" in
            install) cmd_install ;; uninstall) cmd_uninstall ;; status) cmd_status ;;
            *) error_exit "Unknown command: $1 (expected: install|uninstall|status)" ;;
        esac
        exit 0
    fi
    while true; do
        header "Foo Manager"
        case "$(gum choose install uninstall status quit --header "Choose an action:")" in
            install) cmd_install ;; uninstall) cmd_uninstall ;; status) cmd_status ;;
            *) gum style --faint "Bye."; exit 0 ;;
        esac
        echo ""
        gum confirm "Back to main menu?" || { gum style --faint "Bye."; exit 0; }
    done
}

main "$@"
