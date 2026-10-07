#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# trash-compactor.sh — Delete scripts from scripts/ (the whole script folder:
# the .sh, its subfolders and files).
#
# Lists every script folder for multi-select (Tab to mark, Enter to proceed),
# then asks for confirmation once PER FOLDER before deleting it. Shared folders
# (_common, _templates, cluster) are never offered.
#
# Usage:  ./trash-compactor.sh [<script-folder>...]
#         (prompts for the selection when none is given; always confirms)
# -----------------------------------------------------------------------------

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="${SCRIPT_DIR}/scripts"

# Same exclusions as init.sh: shared helpers, not standalone scripts.
EXCLUDED_DIRS="cluster _common _templates"

MENU_SEP=" — "   # separates the folder from its description in the picker

info()  { printf "\033[0;36m[INFO]  %s\033[0m\n" "$*"; }
ok()    { printf "\033[0;32m[OK]    %s\033[0m\n" "$*"; }
warn()  { printf "\033[0;33m[WARN]  %s\033[0m\n" "$*"; }
fatal() { printf "\033[0;31m[ERROR] %s\033[0m\n" "$*" >&2; exit 1; }

command -v gum >/dev/null 2>&1 || fatal "gum is required (run setup.sh first)."
[[ -d "$SCRIPTS_DIR" ]] || fatal "scripts/ not found at ${SCRIPTS_DIR}."

_dir_excluded() {
    local dir="$1" ex
    for ex in $EXCLUDED_DIRS; do
        [[ "$dir" == "$ex" ]] && return 0
    done
    return 1
}

# Script folder names (direct children of scripts/), sorted, exclusions skipped.
get_folders() {
    local d name
    for d in "$SCRIPTS_DIR"/*/; do
        [[ -d "$d" ]] || continue
        name="$(basename "$d")"
        _dir_excluded "$name" && continue
        printf '%s\n' "$name"
    done
}

# One-line "# description:" header from the folder's first .sh (empty if none).
_describe() {
    local f
    f="$(find "$SCRIPTS_DIR/$1" -mindepth 1 -maxdepth 1 -name '*.sh' | sort | head -n1)"
    [[ -n "$f" ]] || return 0
    sed -n 's/^#[[:space:]]*description:[[:space:]]*//p' "$f" 2>/dev/null | head -n1
}

# Picker rows: "<folder>/   — <description>", padded so descriptions line up.
build_menu() {
    local folders="$1" f d w=0
    while IFS= read -r f; do
        if [[ -n "$f" ]] && (( ${#f} + 1 > w )); then w=$(( ${#f} + 1 )); fi
    done <<< "$folders"
    while IFS= read -r f; do
        [[ -z "$f" ]] && continue
        d="$(_describe "$f")"
        if [[ -n "$d" ]]; then
            printf '%-*s%s%s\n' "$w" "$f/" "$MENU_SEP" "$d"
        else
            printf '%s\n' "$f/"
        fi
    done <<< "$folders"
}

# Recover the folder name from a picker row (drop description, padding, slash).
strip_choice() {
    local c="$1"
    c="${c%%"$MENU_SEP"*}"
    c="${c%"${c##*[![:space:]]}"}"
    printf '%s' "${c%/}"
}

# --- Resolve the selection ---------------------------------------------------
available="$(get_folders)"
[[ -n "$available" ]] || { info "No scripts to delete in ${SCRIPTS_DIR}."; exit 0; }

selected=()
if (( $# > 0 )); then
    for arg in "$@"; do
        arg="${arg%/}"; arg="${arg#scripts/}"; arg="${arg%%/*}"
        grep -qxF -- "$arg" <<< "$available" || fatal "No deletable script folder named '${arg}'."
        selected+=("$arg")
    done
else
    picked=$(build_menu "$available" | gum filter --no-limit \
        --header "Select scripts to delete (Tab to mark, Enter to continue)" \
        --placeholder "type to filter..." --height 15) || true
    while IFS= read -r row; do
        [[ -n "$row" ]] && selected+=("$(strip_choice "$row")")
    done <<< "$picked"
fi

(( ${#selected[@]} > 0 )) || { info "Nothing selected."; exit 0; }

# --- Delete, confirming per folder ------------------------------------------
deleted=0 skipped=0
for name in "${selected[@]}"; do
    # Guard: a plain, non-excluded direct child of scripts/ — nothing else.
    if [[ -z "$name" || "$name" == *"/"* || "$name" == "." || "$name" == ".." ]] \
        || _dir_excluded "$name"; then
        warn "Refusing to delete '${name}'."
        skipped=$((skipped + 1)); continue
    fi
    target="${SCRIPTS_DIR}/${name}"
    if [[ ! -d "$target" || -L "$target" ]]; then
        warn "Not a script folder: scripts/${name}"
        skipped=$((skipped + 1)); continue
    fi

    files="$(find "$target" -type f ! -name '.DS_Store' | sed "s|^${SCRIPTS_DIR}/||" | sort)"
    count="$(grep -c . <<< "$files" || true)"

    echo
    gum style --border rounded --border-foreground 196 --padding "0 2" \
        --bold "scripts/${name}/  (${count} file(s))"
    if [[ -n "$files" ]]; then sed 's/^/  /' <<< "$files"; fi

    if gum confirm "Delete scripts/${name}/ and everything in it?" --default=false; then
        rm -rf -- "$target"
        ok "Deleted scripts/${name}/"
        deleted=$((deleted + 1))
    else
        info "Kept scripts/${name}/"
        skipped=$((skipped + 1))
    fi
done

echo
info "Done: ${deleted} deleted, ${skipped} kept."
