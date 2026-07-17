#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# export.sh — Export a single script as a standalone, scomp-link-free folder.
#
# Produces a FLAT directory containing:
#   <name>.sh            the script (+ its co-located assets, e.g. .fcc/)
#   ui.sh deps.sh …      only the _common helpers the script actually sources
#   setup.sh             slimmed bootstrap (framework floor + the script's
#                        declared `# export-setup:` extras); no init.sh
#   wsl-setup.ps1        Windows/WSL bootstrap (runs setup.sh inside WSL)
#
# The exported script relies on every script being "vendor-aware" (it falls
# back to co-located helpers when ../_common is absent). Run it directly:
#   bash setup.sh          # once, to install deps
#   bash <name>.sh         # the tool
#
# Usage:  ./export.sh [<script-name>] [<target-dir>]
#         (prompts for anything not given on the command line)
# -----------------------------------------------------------------------------

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="${SCRIPT_DIR}/scripts"
COMMON_DIR="${SCRIPTS_DIR}/_common"
SETUP_SH="${SCRIPT_DIR}/setup.sh"
WSL_PS1="${SCRIPT_DIR}/wsl-setup.ps1"
BOOTSTRAP_MARKER='# === bootstrap entrypoint ==='

# Known shared helpers that may be copied alongside an exported script.
COMMON_FILES="ui deps gh_releases portforward cluster"

info()  { printf "\033[0;36m[INFO]  %s\033[0m\n" "$*"; }
ok()    { printf "\033[0;32m[OK]    %s\033[0m\n" "$*"; }
warn()  { printf "\033[0;33m[WARN]  %s\033[0m\n" "$*"; }
fatal() { printf "\033[0;31m[ERROR] %s\033[0m\n" "$*" >&2; exit 1; }

command -v gum >/dev/null 2>&1 || fatal "gum is required (run setup.sh first)."
[[ -f "$SETUP_SH" ]] || fatal "setup.sh not found at ${SETUP_SH}."
grep -qF "$BOOTSTRAP_MARKER" "$SETUP_SH" || fatal "setup.sh is missing the '${BOOTSTRAP_MARKER}' marker."

# --- Discover runnable scripts (folder/script.sh, one level deep) ------------
get_scripts() {
    find "$SCRIPTS_DIR" -mindepth 2 -maxdepth 2 -name "*.sh" \
        ! -path "*/_common/*" ! -path "*/cluster/*" -print \
        | sed "s|^${SCRIPTS_DIR}/||" | sort
}

# --- Resolve the script to export -------------------------------------------
choice="${1:-}"
if [[ -z "$choice" ]]; then
    choice=$(get_scripts | gum filter --header "Select a script to export" \
        --placeholder "type to filter..." --height 15) || true
    [[ -z "$choice" ]] && { info "Cancelled."; exit 0; }
elif [[ "$choice" != */*.sh ]]; then
    # allow a bare folder name (e.g. "postgres")
    choice=$(get_scripts | grep -E "^${choice}/" | head -1 || true)
    [[ -z "$choice" ]] && fatal "No script matching '${1}'."
fi

src_script="${SCRIPTS_DIR}/${choice}"
[[ -f "$src_script" ]] || fatal "Script not found: ${src_script}"
src_folder="$(dirname "$src_script")"
script_base="$(basename "$src_script")"
name="$(basename "$src_folder")"

# --- Resolve the target directory -------------------------------------------
target="${2:-}"
if [[ -z "$target" ]]; then
    target=$(gum input --header "Export '${name}' to which directory?" \
        --value "$HOME/${name}" --placeholder "/path/to/${name}") || true
    [[ -z "$target" ]] && { info "Cancelled."; exit 0; }
fi
target="${target/#\~/$HOME}"

if [[ -e "$target" ]]; then
    gum confirm "Target '${target}' exists — overwrite its contents?" \
        || { info "Cancelled."; exit 0; }
fi
mkdir -p "$target"

info "Exporting '${name}' → ${target}"

# --- 1. Copy the script folder (script + co-located assets), flattened ------
# `/.` copies the folder's contents (incl. dotdirs like .fcc) into target.
cp -R "${src_folder}/." "$target/"
find "$target" -name '.DS_Store' -delete 2>/dev/null || true
ok "Copied ${name}/ (script + assets)."

# --- 2. Copy only the shared helpers this script sources --------------------
copied_common=()
for c in $COMMON_FILES; do
    if grep -qE "/${c}\.sh" "$src_script"; then
        if [[ -f "${COMMON_DIR}/${c}.sh" ]]; then
            cp "${COMMON_DIR}/${c}.sh" "$target/"
            copied_common+=("${c}.sh")
        else
            warn "Script sources ${c}.sh but ${COMMON_DIR}/${c}.sh is missing."
        fi
    fi
done
if [[ ${#copied_common[@]} -gt 0 ]]; then
    ok "Copied shared helpers: ${copied_common[*]}"
else
    info "No _common helpers referenced."
fi

# --- 3. Parse the setup manifest --------------------------------------------
manifest="$(grep -E '^#[[:space:]]*export-setup:' "$src_script" | head -1 \
            | sed -E 's/^#[[:space:]]*export-setup:[[:space:]]*//' || true)"
extras=()      # framework ensure_* steps (vim/tree/node)
pkgs=()        # generic package installs (pandoc, …)
for tok in $manifest; do
    case "$tok" in
        curl|mise|bash|gum) : ;;                 # already in the floor
        vim|tree|node)      extras+=("ensure_${tok}") ;;
        *)                  pkgs+=("$tok") ;;
    esac
done

# --- 4. Generate the slimmed setup.sh ---------------------------------------
# Everything ABOVE the marker (helpers + ensure_* functions) is reused verbatim.
out_setup="${target}/setup.sh"
awk -v m="$BOOTSTRAP_MARKER" 'index($0,m){exit} {print}' "$SETUP_SH" > "$out_setup"
# Scrub scomp-link-internal names from the reused functions' comments/messages
# so the standalone setup doesn't reference tooling that isn't shipped with it.
# (starlight-init.sh first, else the init.sh rule would mangle it.)
perl -pi -e 's/\bstarlight-init\.sh\b/this tool/g; s/\binit\.sh\b/this tool/g' "$out_setup"

# A best-effort tool installer (only appended when the manifest lists tools).
# Prefers mise (already bootstrapped, cross-platform — same path gum uses), then
# the OS package manager. Never fatal: anything it can't install is resolved by
# the tool's own runtime checks, exactly as in scomp-link.
if [[ ${#pkgs[@]} -gt 0 ]]; then
    cat >> "$out_setup" <<'PKGFN'

ensure_tool() {
    local bin="$1"
    if command_exists "$bin"; then ok "${bin} found: $(command -v "$bin")"; return 0; fi
    info "Installing ${bin}..."
    if command_exists mise && mise use --global "$bin" 2>/dev/null; then
        export PATH="$HOME/.local/share/mise/shims:$PATH"
    elif [ "$OS" = "macos" ] && command_exists brew; then
        brew install "$bin" || true
    elif command_exists apt-get; then
        sudo apt-get install -y "$bin" || true
    elif command_exists dnf; then
        sudo dnf install -y "$bin" || true
    fi
    command_exists "$bin" && ok "${bin} ready." \
        || warn "Couldn't pre-install ${bin} — it'll be resolved when you run the tool."
}
PKGFN
fi

# The generated entrypoint: framework floor → manifest extras → done.
{
    printf '\n%s (generated by export.sh for standalone %s)\n' "$BOOTSTRAP_MARKER" "$name"
    printf 'detect_os\n'
    printf 'info "Detected OS: $OS, package manager: $PKG_MANAGER"\n'
    printf 'ensure_curl\nensure_mise\nensure_mise_activation\nensure_bash\nensure_gum\nensure_gum_width\n'
    for e in "${extras[@]}"; do printf '%s\n' "$e"; done
    for p in "${pkgs[@]}";   do printf 'ensure_tool %q\n' "$p"; done
    printf 'ok "Setup complete."\n'
    printf 'info "Run this tool with:  bash %s"\n' "$script_base"
} >> "$out_setup"
summary="floor"
[[ ${#extras[@]} -gt 0 ]] && summary="${summary} + ${extras[*]}"
[[ ${#pkgs[@]}   -gt 0 ]] && summary="${summary} + pkgs: ${pkgs[*]}"
ok "Generated setup.sh (${summary})."

# --- 5. Copy the Windows/WSL bootstrap (already scomp-link-agnostic) ---------
if [[ -f "$WSL_PS1" ]]; then
    cp "$WSL_PS1" "$target/"
    ok "Copied wsl-setup.ps1."
fi

# --- Done -------------------------------------------------------------------
echo
ok "Exported '${name}' to: ${target}"
cat <<EOF

  Run it standalone (no scomp-link needed):
    cd "${target}"
    bash setup.sh        # once — installs deps
    bash ${script_base}  # the tool

  On Windows: run wsl-setup.ps1 (bootstraps setup.sh inside WSL).
EOF
