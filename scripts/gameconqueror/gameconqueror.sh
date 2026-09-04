#!/usr/bin/env bash
# description: Build & install GameConqueror/scanmem (GUI memory scanner)
# Standalone export (export.sh): no extra setup deps — OS packages are installed at runtime (Linux-only).
# -----------------------------------------------------------------------------
# gameconqueror.sh
# Interactive TUI to build and install GameConqueror
# (https://github.com/scanmem/scanmem) — a GTK front-end for the scanmem
# memory scanner — from source, with a desktop shortcut.
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

REPO_URL="https://github.com/scanmem/scanmem.git"
INSTALL_DIR="${HOME}/scanmem"
DESKTOP_FILE="${HOME}/.local/share/applications/gameconqueror.desktop"

# -----------------------------------------------------------------------------
# Dependencies
# -----------------------------------------------------------------------------

# scanmem/GameConqueror is a Linux-native tool (ptrace + /proc, GTK); nothing to
# build elsewhere.
_require_linux() {
    [[ "$(uname -s)" == "Linux" ]] && return 0
    error_exit "GameConqueror/scanmem is Linux-only (ptrace + GTK); it can't be built or run on $(uname -s)."
}

_ensure_build_deps() {
    _ensure_pkg git          git                  git
    _ensure_pkg make         make                 make
    _ensure_pkg gcc          gcc                  gcc
    _ensure_pkg autoreconf   autoconf             autoconf
    _ensure_pkg pkg-config   pkgconf-pkg-config    pkg-config
    # autogen.sh drives aclocal/libtoolize/intltoolize; configure.ac needs readline
    # and a python interpreter (AM_PATH_PYTHON) — none provided by the tools above.
    _ensure_pkg aclocal      automake             automake
    _ensure_pkg libtoolize   libtool              libtool
    _ensure_pkg intltoolize  intltool             intltool
    _ensure_pkg python3      python3              python3
    _ensure_pkgs "readline-devel" "libreadline-dev"
}

# GameConqueror is a Python/GTK app; without these the built /usr/bin/gameconqueror
# fails to launch (ModuleNotFoundError: gi) and pkexec privilege escalation won't work.
_ensure_gui_runtime_deps() {
    _ensure_pkgs "python3-gobject gtk3 polkit" "python3-gi gir1.2-gtk-3.0 policykit-1"
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
Name=GameConqueror
Comment=Graphical memory scanner frontend for scanmem
Exec=/usr/bin/gameconqueror
Icon=application-x-executable
Terminal=false
Type=Application
Categories=Utility;
EOF
    chmod +x "$DESKTOP_FILE"
    success "Desktop shortcut created at ${DESKTOP_FILE}."
}

cmd_install() {
    header "GameConqueror — Install"

    _ensure_build_deps
    _ensure_gui_runtime_deps

    if [[ -d "$INSTALL_DIR" ]]; then
        gum confirm "Existing checkout found at ${INSTALL_DIR}. Remove and rebuild from scratch?" \
            || { info "Cancelled."; return; }
        rm -rf "$INSTALL_DIR"
    fi

    info "Cloning scanmem/GameConqueror..."
    gum spin --spinner dot --title "git clone ${REPO_URL}..." -- \
        git clone "$REPO_URL" "$INSTALL_DIR" \
        || error_exit "Failed to clone repository."

    info "Generating build files and building (GUI enabled, this can take a few minutes)..."
    gum spin --spinner dot --title "Building GameConqueror..." -- \
        bash -c "cd '${INSTALL_DIR}' && ./autogen.sh && ./configure --prefix=/usr --enable-gui && make" \
        || error_exit "Build failed. Re-run with 'cd ${INSTALL_DIR} && make' to see full compiler output."

    _require_sudo_or_instruct "Installing GameConqueror to /usr" "sudo make -C ${INSTALL_DIR} install"
    sudo make -C "$INSTALL_DIR" install || error_exit "Install step failed."

    _create_shortcut

    success "GameConqueror installed: /usr/bin/gameconqueror (and /usr/bin/scanmem)"
}

# -----------------------------------------------------------------------------
# uninstall
# -----------------------------------------------------------------------------

cmd_uninstall() {
    header "GameConqueror — Uninstall"

    gum confirm "This removes the binaries, source checkout, and desktop shortcut. Continue?" \
        || { info "Cancelled."; return; }

    # Prefer 'make uninstall' from the build tree — it removes everything the build
    # installed (binaries, libscanmem, the polkit policy, python modules, its own
    # desktop entry). Fall back to removing the known paths when it isn't available.
    if [[ -f "${INSTALL_DIR}/Makefile" ]]; then
        _require_sudo_or_instruct "Uninstalling via make" "sudo make -C ${INSTALL_DIR} uninstall"
        sudo make -C "$INSTALL_DIR" uninstall \
            && success "Ran 'make uninstall'." \
            || warn "'make uninstall' failed — falling back to manual removal."
    fi
    _require_sudo_or_instruct "Removing /usr/bin/scanmem and /usr/bin/gameconqueror" \
        "sudo rm -f /usr/bin/scanmem /usr/bin/gameconqueror"
    sudo rm -f /usr/bin/scanmem /usr/bin/gameconqueror \
        && success "Binaries removed."
    sudo rm -rf /usr/share/gameconqueror /usr/share/scanmem \
        || warn "Could not remove some data files under /usr/share — check manually."

    [[ -d "$INSTALL_DIR" ]] && rm -rf "$INSTALL_DIR" && success "Source directory removed."
    [[ -f "$DESKTOP_FILE" ]] && rm -f "$DESKTOP_FILE" && success "Desktop shortcut removed."

    success "Uninstall complete."
}

# -----------------------------------------------------------------------------
# status
# -----------------------------------------------------------------------------

cmd_status() {
    header "GameConqueror — Status"

    if [[ -x /usr/bin/gameconqueror ]]; then
        success "Installed: /usr/bin/gameconqueror"
    else
        warn "Not installed (/usr/bin/gameconqueror not found)."
    fi
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
        header "GameConqueror Manager"
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
