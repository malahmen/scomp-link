#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# init.sh — Interactive script launcher powered by gum
# Discovers .sh files one level deep (one per subdirectory) and lets the user
# pick one to run. Loops until the user quits.
# -----------------------------------------------------------------------------

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="${SCRIPT_DIR}/scripts"

# ── gum check ─────────────────────────────────────────────────────────────────
if ! command -v gum > /dev/null 2>&1; then
    echo "Error: gum is not installed. Run setup.sh first."
    exit 1
fi

# ── helpers ───────────────────────────────────────────────────────────────────

# Folders that contain shared utilities (sourced by other scripts), not
# interactive TUIs. They are excluded from the script picker.
EXCLUDED_DIRS="cluster _common"

# Special picker entry: export a script as a standalone, scomp-link-free folder.
# (holo-convert is a normal script under scripts/ and is auto-discovered.)
EXPORT_ENTRY="Export a script → standalone folder"

_dir_excluded() {
    local dir="$1"
    for ex in $EXCLUDED_DIRS; do
        [ "$dir" = "$ex" ] && return 0
    done
    return 1
}

# Returns "folder/script.sh" relative paths, one per line, sorted.
# Skips any folder listed in EXCLUDED_DIRS.
get_scripts() {
    local scripts=()
    while IFS= read -r -d '' f; do
        local rel="${f#"$SCRIPTS_DIR/"}"
        local dir="${rel%%/*}"
        _dir_excluded "$dir" && continue
        scripts+=("$rel")
    done < <(find "$SCRIPTS_DIR" -mindepth 2 -maxdepth 2 -name "*.sh" -print0 | sort -z)
    printf '%s\n' "${scripts[@]}"
}

# ── main loop ─────────────────────────────────────────────────────────────────
while true; do
    gum style \
        --border rounded --border-foreground 212 \
        --padding "1 3" --margin "1 0" \
        --bold "Script Manager"

    # Collect available scripts
    available=$(get_scripts)

    if [ -z "$available" ]; then
        gum style --foreground 196 "No runnable scripts found in $SCRIPTS_DIR."
        exit 1
    fi

    # Let user pick — type to filter, Enter to run, ESC to quit. The export
    # action is offered as the first entry.
    choice=$(printf '%s\n%s\n' "$EXPORT_ENTRY" "$available" | gum filter \
        --header "Select a script to run" \
        --placeholder "type to filter..." \
        --height 15) || true

    # Empty means user cancelled
    if [ -z "$choice" ]; then
        gum style --faint "Bye."
        exit 0
    fi

    # Pick a bash 4+ binary for the special-entry handoff.
    BASH_BIN="$(command -v bash)"
    for candidate in /opt/homebrew/bin/bash /usr/local/bin/bash; do
        [ -x "$candidate" ] && { BASH_BIN="$candidate"; break; }
    done

    # Export action → hand off to export.sh (interactive), then loop.
    if [ "$choice" = "$EXPORT_ENTRY" ]; then
        "$BASH_BIN" "$SCRIPT_DIR/export.sh" \
            || gum style --foreground 196 "Export exited with errors (code $?)"
        gum confirm "Run another script?" || { gum style --faint "Bye."; exit 0; }
        continue
    fi

    script_path="$SCRIPTS_DIR/$choice"

    if [ ! -f "$script_path" ]; then
        gum style --foreground 196 "Script not found: $script_path"
        continue
    fi

    # Ensure executable
    if [ ! -x "$script_path" ]; then
        chmod +x "$script_path"
    fi

    # Find a bash 4+ binary to run scripts with.
    # macOS ships bash 3.2 at /usr/bin/bash; brew installs 5.x at /usr/local/bin or /opt/homebrew/bin.
    # We can't rely on 'env bash' resolving to 4+ unless the user has configured their PATH.
    BASH_BIN="$(command -v bash)"
    for candidate in /opt/homebrew/bin/bash /usr/local/bin/bash; do
        if [[ -x "$candidate" ]]; then
            BASH_BIN="$candidate"
            break
        fi
    done

    # Run with explicit bash binary so shebang limitations don't apply
    "$BASH_BIN" "$script_path" || gum style --foreground 196 "Script exited with errors (code $?)"

    gum confirm "Run another script?" || { gum style --faint "Bye."; exit 0; }
done