#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# convert.sh — Starlight docs-project converter (self-contained gum front-end).
#
# Drives the vendored holo-convert engine (holo-convert.sh + .fcc, copied next
# to this file by the scaffolder). The engine is flag-driven and gum-free; this
# shim owns the project-specific bits: picking docs under ../src/content/docs
# and choosing a format/preset, then running the engine with the matching flags.
# A scaffolded project is fully self-contained — no dependency on scomp-link.
#
#   mise run convert       → bash converter/convert.sh        (interactive)
#   mise run convert:pdf   → bash converter/convert.sh pdf     (fast md→pdf)
#   mise run convert:docx  → bash converter/convert.sh docx    (fast md→docx)
# -----------------------------------------------------------------------------

if [[ "${BASH_VERSINFO[0]:-0}" -lt 4 ]]; then
    echo "[error] bash 4 or higher is required (you have bash ${BASH_VERSION})." >&2
    echo "  On macOS: brew install bash" >&2
    exit 1
fi

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

command -v gum    &>/dev/null || { echo "[error] gum is required. Install via mise or brew." >&2; exit 1; }
command -v pandoc &>/dev/null || { echo "[error] pandoc not found. Run 'mise install' from the project root first." >&2; exit 1; }

ENGINE="${SCRIPT_DIR}/holo-convert.sh"
[[ -f "$ENGINE" ]] || {
    echo "[error] holo-convert.sh not found next to convert.sh (expected the vendored engine)." >&2
    exit 1
}

# Starlight source docs live one level up from converter/.
DOCS_ROOT="../src/content/docs"

# Pick documents into PICKED[].
PICKED=()
pick_docs() {
    local all=()
    mapfile -t all < <(find "$DOCS_ROOT" -type f -name '*.md' 2>/dev/null | sort)
    [[ ${#all[@]} -gt 0 ]] || { echo "[error] no .md files under ${DOCS_ROOT}" >&2; exit 1; }
    local sel
    sel=$(printf '%s\n' "${all[@]}" | gum choose --no-limit \
        --header "Select docs to convert:") || true
    [[ -n "$sel" ]] || { gum style --faint "Cancelled."; exit 0; }
    mapfile -t PICKED <<< "$sel"
}

# Run the engine with the given flags + the picked files, using this same bash
# (guaranteed 4+) so the engine's shell features work regardless of PATH.
run_engine() { exec "${BASH:-bash}" "$ENGINE" "$@" "${PICKED[@]}"; }

case "${1:-interactive}" in
    pdf)
        pick_docs
        run_engine --from md --to pdf --title-page --toc --toc-depth 3 --strip-rules --font Helvetica
        ;;
    docx)
        pick_docs
        run_engine --from md --to docx --reference plain --toc --toc-depth 3
        ;;
    interactive|full)
        pick_docs
        local_fmt=$(gum choose "pdf" "docx" --header "Output format:") || exit 0
        flags=(--from md --to "$local_fmt")
        if gum confirm "Add a table of contents?"; then flags+=(--toc --toc-depth 3); fi
        if gum confirm "Add a title page?"; then flags+=(--title-page); fi
        if [[ "$local_fmt" == pdf ]]; then
            if gum confirm "Strip horizontal rules (---)?"; then flags+=(--strip-rules); fi
        fi
        run_engine "${flags[@]}"
        ;;
    *)
        echo "[error] Unknown mode: '${1}'. Valid modes: (none) | pdf | docx" >&2
        exit 1
        ;;
esac
