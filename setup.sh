#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# setup.sh — Bootstrap script for gum-based tooling on Linux/macOS
# Detects OS, installs curl if missing, installs mise, installs gum,
# optionally installs Node.js/npm (LTS via mise), runs common.sh
# -----------------------------------------------------------------------------

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

OS=""
PKG_MANAGER=""

# Helpers
info()  { printf "\033[0;36m[INFO]  %s\033[0m\n" "$*"; }
ok()    { printf "\033[0;32m[OK]    %s\033[0m\n" "$*"; }
warn()  { printf "\033[0;33m[WARN]  %s\033[0m\n" "$*"; }
fatal() { printf "\033[0;31m[ERROR] %s\033[0m\n" "$*" >&2; exit 1; }

command_exists() { command -v "$1" &>/dev/null; }

# OS detection
detect_os() {
    case "$(uname -s)" in
        Darwin)
            OS="macos"
            PKG_MANAGER="brew"
            ;;
        Linux)
            OS="linux"
            if [ -f /etc/os-release ]; then
                # shellcheck source=/dev/null
                source /etc/os-release
                case "${ID:-}" in
                    ubuntu|debian|linuxmint|pop)
                        PKG_MANAGER="apt"
                        ;;
                    fedora|rhel|centos|rocky|almalinux)
                        PKG_MANAGER="dnf"
                        ;;
                    *)
                        case "${ID_LIKE:-}" in
                            *debian*|*ubuntu*)
                                PKG_MANAGER="apt"
                                ;;
                            *fedora*|*rhel*)
                                PKG_MANAGER="dnf"
                                ;;
                            *)
                                fatal "Unsupported Linux distribution: ${PRETTY_NAME:-$ID}.
Supported: Ubuntu/Debian and derivatives, Fedora/RHEL and derivatives, macOS."
                                ;;
                        esac
                        ;;
                esac
            else
                fatal "Cannot determine Linux distribution (/etc/os-release not found)."
            fi
            ;;
        *)
            fatal "Unsupported OS: $(uname -s). Supported: Linux, macOS."
            ;;
    esac
}

# curl (extreme edge case — needed to install mise on Linux)
ensure_curl() {
    if command_exists curl; then
        ok "curl found: $(command -v curl)"
        return
    fi

    if [ "$OS" = "macos" ]; then
        # curl ships with macOS, should never reach here
        fatal "curl not found on macOS. This is unexpected. Please install Xcode Command Line Tools:
  xcode-select --install"
    fi

    warn "curl not found. Attempting to install..."

    # curl install requires sudo on Linux
    if ! sudo -n true 2>/dev/null; then
        fatal "curl is not installed and your account does not have passwordless sudo access to install it.
Please ask your administrator to install curl."
    fi

    case "$PKG_MANAGER" in
        apt)
            sudo apt-get update -qq && sudo apt-get install -y curl
            ;;
        dnf)
            sudo dnf install -y curl
            ;;
    esac

    command_exists curl || fatal "curl installation failed. Please install curl manually and re-run."
    ok "curl installed."
}

# mise
ensure_mise() {
    info "Looking for mise..."

    if command_exists mise; then
        ok "mise found: $(command -v mise)"
        return
    fi

    info "mise not found. Attempting to install..."

    case "$OS" in
        macos)
            if ! command_exists brew; then
                info "Homebrew not found. Attempting to install..."
                if ! /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"; then
                    fatal "Homebrew installation failed. Please install it manually: https://brew.sh"
                fi
                if [ -x "/opt/homebrew/bin/brew" ]; then
                    eval "$(/opt/homebrew/bin/brew shellenv)"
                elif [ -x "/usr/local/bin/brew" ]; then
                    eval "$(/usr/local/bin/brew shellenv)"
                else
                    fatal "Homebrew installed but 'brew' not found in expected locations.
Please open a new terminal and re-run."
                fi
                command_exists brew || fatal "Homebrew installed but 'brew' is still not in PATH.
Please open a new terminal and re-run."
                ok "Homebrew installed."
            fi
            brew install mise
            ;;
        linux)
            # mise curl installer — user-local, no sudo needed
            curl -fsSL https://mise.run | sh

            # mise lands in ~/.local/bin — add to PATH for the current session
            export PATH="$HOME/.local/bin:$PATH"
            ;;
    esac

    command_exists mise || fatal "mise installation failed. Please install it manually: https://mise.jdx.dev"
    ok "mise installed: $(command -v mise)"
}

# gum via mise
ensure_gum() {
    info "Looking for gum..."

    if command_exists gum; then
        ok "gum found: $(command -v gum)"
        return
    fi

    info "Installing gum via mise..."
    mise use --global gum

    # mise shims land in ~/.local/share/mise/shims — ensure it's in PATH
    export PATH="$HOME/.local/share/mise/shims:$PATH"

    command_exists gum || fatal "gum installation via mise failed. Please install it manually:
https://github.com/charmbracelet/gum#installation"
    ok "gum installed: $(command -v gum)"
}


# GUM_INPUT_WIDTH — fixes double-render bug in gum v0.15+ on Apple Terminal / zsh
# See: https://github.com/charmbracelet/gum/issues/895
ensure_gum_width() {
    local profile_file=""

    # Determine which shell profile to write to
    case "${SHELL:-}" in
        */zsh)  profile_file="$HOME/.zshrc"  ;;
        */bash) profile_file="$HOME/.bashrc" ;;
        *)      profile_file="$HOME/.profile" ;;
    esac

    # Only applies on macOS or zsh — skip silently on other Linux setups
    if [ "$OS" != "macos" ] && [[ "${SHELL:-}" != */zsh ]]; then
        return
    fi

    # If already configured, respect the existing value and move on
    if grep -qF "GUM_INPUT_WIDTH" "$profile_file" 2>/dev/null; then
        ok "GUM_INPUT_WIDTH already set in ${profile_file}."
        export GUM_INPUT_WIDTH=$(grep "GUM_INPUT_WIDTH" "$profile_file" | grep -oE '[0-9]+' | tail -1)
        return
    fi

    info "gum v0.15+ has a known double-render bug on Apple Terminal / zsh."
    info "Setting GUM_INPUT_WIDTH fixes it by preventing gum from querying the terminal width."
    info "The value should be less than or equal to your terminal window width."
    info "Default of 60 is safe for most terminals. Enter a higher value if you use a wide terminal."
    info "Your current terminal width is: $(tput cols 2>/dev/null || echo "unknown")"

    local width
    width=$(gum input         --placeholder "60"         --header "GUM_INPUT_WIDTH (leave empty for default 60):"         --char-limit 4) || true

    # Validate: must be a number between 20 and 500, default to 60
    if [[ -z "$width" ]] || ! [[ "$width" =~ ^[0-9]+$ ]] || (( width < 20 || width > 500 )); then
        width=60
        info "Using default width: 60"
    fi

    local export_line="export GUM_INPUT_WIDTH=${width}"

    # Set for current session
    export GUM_INPUT_WIDTH="${width}"

    printf '\n# Fix gum input double-render bug (gum v0.15+)\n%s\n' "$export_line" >> "$profile_file"
    ok "Added GUM_INPUT_WIDTH=${width} to ${profile_file}."
    info "Restart your terminal or run: source ${profile_file}"
}
# vim — required by starlight-manage.sh for editing content files
ensure_vim() {
    info "Looking for vim..."

    if command_exists vim; then
        ok "vim found: $(command -v vim)"
        return
    fi

    info "vim not found. Attempting to install..."

    case "$OS" in
        macos)
            brew install vim
            ;;
        linux)
            if ! sudo -n true 2>/dev/null; then
                fatal "vim is not installed and your account does not have passwordless sudo access to install it.
Please ask your administrator to install vim."
            fi
            case "$PKG_MANAGER" in
                apt) sudo apt-get update -qq && sudo apt-get install -y vim ;;
                dnf) sudo dnf install -y vim ;;
            esac
            ;;
    esac

    command_exists vim || fatal "vim installation failed. Please install vim manually and re-run."
    ok "vim installed: $(command -v vim)"
}

# tree — required by starlight-manage.sh for site structure overview
ensure_tree() {
    info "Looking for tree..."

    if command_exists tree; then
        ok "tree found: $(command -v tree)"
        return
    fi

    info "tree not found. Attempting to install..."

    case "$OS" in
        macos)
            brew install tree
            ;;
        linux)
            if ! sudo -n true 2>/dev/null; then
                warn "tree is not installed and sudo access is unavailable."
                warn "Ask your administrator to install tree, or: sudo apt install tree / sudo dnf install tree"
                return
            fi
            case "$PKG_MANAGER" in
                apt) sudo apt-get update -qq && sudo apt-get install -y tree ;;
                dnf) sudo dnf install -y tree ;;
            esac
            ;;
    esac

    if ! command_exists tree; then
        warn "tree installation failed. You can ask your administrator to install it, or install manually."
        warn "Site structure view will be unavailable until tree is installed."
        return
    fi
    ok "tree installed: $(command -v tree)"
}

# Node.js / npm via mise (optional — required by starlight-init.sh and similar scripts)
ensure_node() {
    info "Looking for node / npm..."

    if command_exists node && command_exists npm; then
        ok "node found: $(node --version)  npm: $(npm --version)"
        return
    fi

    warn "Node.js / npm not found."
    warn "Some scripts (e.g. starlight-init.sh) require Node.js."

    if ! gum confirm "Install Node.js LTS via mise?"; then
        warn "Skipping Node.js installation. Re-run setup.sh or install manually if needed."
        return
    fi

    info "Installing Node.js LTS via mise..."
    mise use --global node@lts

    # Ensure mise shims are on PATH for this session
    export PATH="$HOME/.local/share/mise/shims:$PATH"

    if ! command_exists node || ! command_exists npm; then
        fatal "Node.js installation via mise failed.
Please install it manually: https://nodejs.org
Or via mise: mise use --global node@lts"
    fi

    # Verify the installed version is Astro-compatible (not v19 or v21)
    local node_major
    node_major=$(node -e "process.stdout.write(String(process.versions.node.split('.')[0]))")
    if [[ "$node_major" -eq 19 ]] || [[ "$node_major" -eq 21 ]]; then
        fatal "mise installed Node.js v${node_major}, which is not supported by Astro.
Please run: mise use --global node@20
Then re-run setup.sh."
    fi

    ok "Node.js installed: node $(node --version)  npm $(npm --version)"
}

# Main
detect_os
info "Detected OS: $OS, package manager: $PKG_MANAGER"

ensure_curl
ensure_mise
ensure_gum
ensure_gum_width
ensure_vim
ensure_tree
ensure_node

COMMON_SH="$SCRIPT_DIR/common.sh"
if [ ! -f "$COMMON_SH" ]; then
    fatal "common.sh not found next to setup.sh (expected: $COMMON_SH)"
fi

if [ ! -x "$COMMON_SH" ]; then
    chmod +x "$COMMON_SH"
fi

info "Launching common.sh..."
exec "$COMMON_SH"