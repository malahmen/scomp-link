#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# convert.sh — Starlight docs-project converter (thin shim).
#
# Reuses the SAME implementation as scomp-link's file_conversion.sh instead of
# duplicating it. The scaffolder vendors this file plus file_conversion.sh,
# ui.sh, and .fcc/ into <project>/starlight/converter/, so a scaffolded docs
# project is fully self-contained — no runtime dependency on scomp-link.
#
# This shim only supplies the Starlight-specific bits:
#   - source documents live one level up (../src/content/docs)
#   - mise task entry points:
#       mise run convert      → bash converter/convert.sh full   (interactive)
#       mise run convert:pdf  → bash converter/convert.sh pdf     (fast md→pdf)
# -----------------------------------------------------------------------------

# bash 4+ required (macOS ships 3.2 — install a modern bash with `brew install bash`).
if [[ "${BASH_VERSINFO[0]:-0}" -lt 4 ]]; then
    echo "[error] bash 4 or higher is required (you have bash ${BASH_VERSION})." >&2
    echo "  On macOS: brew install bash" >&2
    exit 1
fi

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Preflight — the implementation + gum/pandoc must be present. All are vendored
# or installed via mise; none reach back to scomp-link.
command -v gum    &>/dev/null || { echo "[error] gum is required. Install via mise or brew." >&2; exit 1; }
command -v pandoc &>/dev/null || { echo "[error] pandoc not found. Run 'mise install' from the project root first." >&2; exit 1; }
[[ -f "${SCRIPT_DIR}/file_conversion.sh" ]] || {
    echo "[error] file_conversion.sh not found next to convert.sh (expected the vendored copy)." >&2
    exit 1
}

# Starlight source docs live one level up from converter/. file_conversion.sh
# honours SOURCE_ROOT (default ".") for its file picker.
SOURCE_ROOT="../src/content/docs"

# Load the shared implementation. Its bottom guard won't auto-run because it's
# being sourced, not executed — we drive main / main_fast below.
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/file_conversion.sh"

case "${1:-full}" in
    full) main ;;
    pdf)  main_fast ;;
    *)
        echo "[error] Unknown mode: '${1}'. Valid modes: full, pdf" >&2
        echo "  Usage: bash converter/convert.sh [full|pdf]" >&2
        exit 1
        ;;
esac
