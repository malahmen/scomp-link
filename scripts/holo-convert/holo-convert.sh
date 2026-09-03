#!/usr/bin/env bash
# description: Convert documents (Markdown <-> PDF/DOCX) via the holo-convert engine
# -----------------------------------------------------------------------------
# holo-convert.sh — gum front-end for the holo-convert engine.
#
# scomp-link owns the interactive experience (this file); the conversion logic
# lives in the standalone holo-convert engine (its own repo). This shim resolves
# the engine (local checkout → cache → clone), collects options via gum, and
# runs the engine with the matching flags — the akinn_tui pattern.
#
# Engine resolution order:
#   1. $HOLO_CONVERT_DIR/holo-convert.sh        (explicit override)
#   2. ../../../holo-convert/holo-convert.sh    (sibling dev checkout)
#   3. ~/.cache/scomp-link/holo-convert/…       (cached clone; offers git pull)
#   4. git clone --depth 1 (public HTTPS)       (first run)
# -----------------------------------------------------------------------------

if [[ "${BASH_VERSINFO[0]:-0}" -lt 4 ]]; then
    echo "[error] bash 4+ required (you have ${BASH_VERSION}). On macOS: brew install bash" >&2
    exit 1
fi

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
USE_TP=false

# Shared UI helpers (info/warn/success/error_exit/header) from scomp-link.
# shellcheck source=../_common/ui.sh
source "${SCRIPT_DIR}/../_common/ui.sh"

command -v gum &>/dev/null || { echo "[error] gum is required. Run setup.sh first." >&2; exit 1; }
command -v git &>/dev/null || { echo "[error] git is required to fetch the engine." >&2; exit 1; }

HOLO_REPO="${HOLO_CONVERT_REPO:-https://github.com/malahmen/holo-convert.git}"
HOLO_CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/scomp-link/holo-convert"

# Where to look for source documents (the file picker root).
SOURCE_ROOT="${SOURCE_ROOT:-.}"

ENGINE=""

# -----------------------------------------------------------------------------
# Resolve the holo-convert engine (local → cache → clone).
# -----------------------------------------------------------------------------
resolve_engine() {
    if [[ -n "${HOLO_CONVERT_DIR:-}" && -f "${HOLO_CONVERT_DIR}/holo-convert.sh" ]]; then
        ENGINE="${HOLO_CONVERT_DIR}/holo-convert.sh"
        info "Using holo-convert from \$HOLO_CONVERT_DIR: ${HOLO_CONVERT_DIR}"
        return
    fi

    local sib="${SCRIPT_DIR}/../../../holo-convert/holo-convert.sh"
    if [[ -f "$sib" ]]; then
        ENGINE="$(cd "$(dirname "$sib")" && pwd)/holo-convert.sh"
        info "Using local holo-convert checkout: $(dirname "$ENGINE")"
        return
    fi

    if [[ -f "${HOLO_CACHE}/holo-convert.sh" ]]; then
        ENGINE="${HOLO_CACHE}/holo-convert.sh"
        info "Using cached holo-convert: ${HOLO_CACHE}"
        if [[ -d "${HOLO_CACHE}/.git" ]] && gum confirm "Update holo-convert (git pull)?"; then
            gum spin --spinner dot --title "Updating holo-convert..." -- \
                git -C "$HOLO_CACHE" pull --ff-only || warn "Update failed; using the existing copy."
        fi
        return
    fi

    gum confirm "holo-convert engine not found. Clone it from ${HOLO_REPO}?" \
        || error_exit "holo-convert engine is unavailable."
    mkdir -p "$(dirname "$HOLO_CACHE")"
    gum spin --spinner dot --title "Cloning holo-convert..." -- \
        git clone --depth 1 "$HOLO_REPO" "$HOLO_CACHE" \
        || error_exit "Failed to clone holo-convert from ${HOLO_REPO}"
    ENGINE="${HOLO_CACHE}/holo-convert.sh"
    success "holo-convert cloned to ${HOLO_CACHE}"
}

# -----------------------------------------------------------------------------
# Collect options interactively and build the engine flag list in FLAGS[].
# -----------------------------------------------------------------------------
FLAGS=()
FILES=()
SRC_FMT=""      # source format chosen in gather_options (md/docx)

confirm_flag() {  # $1 prompt, $2 flag-if-yes, [$3 flag-if-no]
    if gum confirm "$1"; then
        [[ -n "$2" ]] && FLAGS+=("$2")
    else
        [[ -n "${3:-}" ]] && FLAGS+=("$3")
    fi
    return 0   # never let the trailing test's status trip set -e in the caller
}

# Strip surrounding whitespace and take only the first line — a pasted value
# can arrive with a trailing newline or stray scrollback appended.
_clean_input() {
    local s="$1"
    s="${s%%$'\n'*}"                 # first line only
    s="${s#"${s%%[![:space:]]*}"}"   # ltrim
    s="${s%"${s##*[![:space:]]}"}"   # rtrim
    printf '%s' "$s"
}

# Prompt for an OPTIONAL file path; blank = none. Re-prompts (up to 3x) when the
# path doesn't resolve to a file, so a contaminated paste can't silently pass a
# bogus path to the engine (which would drop the image). Echoes the clean path
# (empty = skip). Expands a leading ~.
prompt_path() {  # $1 header, $2 placeholder
    local header="$1" placeholder="$2" val try=0
    while (( try < 3 )); do
        try=$(( try + 1 ))
        val=$(_clean_input "$(gum input --header "$header" --placeholder "$placeholder" || true)")
        [[ -z "$val" ]] && return 0            # blank → none
        [[ "$val" == "~"* ]] && val="${val/#\~/$HOME}"
        [[ -f "$val" ]] && { printf '%s' "$val"; return 0; }
        warn "Not a file: ${val} — please re-enter (or leave blank to skip)."
    done
    warn "No valid path after 3 tries — skipping."
    return 0
}

# --- Font picker: list only installed fonts (like the old select_*_font) -----
_MACOS_FONTS_LOADED=""
_MACOS_FONT_FAMILIES=""

_ensure_macos_fonts() {
    [[ -n "$_MACOS_FONTS_LOADED" ]] && return
    _MACOS_FONTS_LOADED=1
    command -v system_profiler &>/dev/null || return
    _MACOS_FONT_FAMILIES=$(system_profiler SPFontsDataType 2>/dev/null \
        | sed -n 's/^[[:space:]]*Family:[[:space:]]*//p' | sort -u)
}

font_installed() {
    local family="$1"
    if command -v fc-list &>/dev/null \
       && fc-list : family | tr ',' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' \
            | grep -qixF "$family"; then
        return 0
    fi
    if [[ "$(uname)" == "Darwin" ]]; then
        _ensure_macos_fonts
        printf '%s\n' "$_MACOS_FONT_FAMILIES" | grep -qixF "$family"
        return
    fi
    command -v fc-list &>/dev/null && return 1   # fc-list gave a definitive "no"
    return 0                                      # no detector ⇒ stay optimistic
}

# Prompt for a prose font from the installed candidates. Echoes the chosen font
# (empty = keep the default). $1 = label for the "keep default" option.
pick_font() {
    local none_label="$1"
    # The macOS font registry (system_profiler) is slow, so warm it under a
    # spinner for a visible "processing" indicator; fontconfig (Linux) is fast.
    if [[ "$(uname)" == Darwin && -z "$_MACOS_FONTS_LOADED" ]] && command -v system_profiler &>/dev/null; then
        _MACOS_FONT_FAMILIES=$(gum spin --spinner dot --title "Detecting installed fonts…" --show-output -- \
            system_profiler SPFontsDataType | sed -n 's/^[[:space:]]*Family:[[:space:]]*//p' | sort -u || true)
        _MACOS_FONTS_LOADED=1
    fi
    local candidates=("Helvetica" "Arial" "Times New Roman" "Georgia" "Palatino" "Garamond")
    local avail=() f
    for f in "${candidates[@]}"; do font_installed "$f" && avail+=("$f"); done
    if [[ ${#avail[@]} -eq 0 ]]; then
        warn "None of the preset prose fonts are installed — using the default."
        return 0
    fi
    avail+=("$none_label")
    local font
    font=$(printf '%s\n' "${avail[@]}" | gum choose \
        --header "Prose font — only installed fonts shown:") || true
    [[ -z "$font" || "$font" == "$none_label" ]] && return 0
    printf '%s' "$font"
}

gather_options() {
    header "holo-convert"

    local src to
    src=$(gum choose "md" "docx" --header "Source format:") || exit 0
    SRC_FMT="$src"
    FLAGS+=(--from "$src")

    # Output format depends on the source.
    if [[ "$src" == md ]]; then
        to=$(gum choose "pdf" "docx" --header "Output format:") || exit 0
    else
        to="md"
        info "Output format: md"
    fi
    FLAGS+=(--to "$to")

    # File picker.
    local depth
    depth=$(gum input --header "Search depth for .${src} files (blank = 3):" --placeholder "3") || true
    [[ -z "$depth" ]] && depth=3
    local found
    found=$(find "$SOURCE_ROOT" -maxdepth "$depth" -type f -name "*.${src}" \
        ! -path '*/.fcc/*' ! -path '*/output/*' ! -path '*/node_modules/*' ! -path '*/.git/*' \
        2>/dev/null | sed 's|^\./||' | sort || true)
    [[ -n "$found" ]] || error_exit "No .${src} files found under ${SOURCE_ROOT} (depth ${depth})."
    local picked
    picked=$(printf '%s\n' "$found" | gum choose --no-limit \
        --header "Select file(s) — SPACE to select, ENTER to confirm:") || true
    [[ -n "$picked" ]] || { info "Cancelled."; exit 0; }
    mapfile -t FILES <<< "$picked"

    # Shared md-source pre-passes.
    if [[ "$src" == md ]]; then
        confirm_flag "Apply character substitutions (smart quotes/dashes)?" --substitutions --no-substitutions
        confirm_flag "Strip horizontal rules (---)?"                        --strip-rules   --no-strip-rules
        confirm_flag "Unwrap [[wikilinks]] to plain text?"                  --unwrap-wikilinks --no-unwrap-wikilinks
        confirm_flag "Rasterize local .svg images to PNG?"                  --raster-svg    --no-raster-svg

        if gum confirm "Add a table of contents?"; then
            local td; td=$(gum input --header "TOC depth (blank = 3):" --placeholder "3") || true
            [[ -z "$td" ]] && td=3
            FLAGS+=(--toc --toc-depth "$td")
        fi

        if gum confirm "Add a title page?"; then
            FLAGS+=(--title-page); USE_TP=true
            local img; img=$(prompt_path "Title-page image path (blank = none):" "/path/to/logo.png")
            [[ -n "$img" ]] && FLAGS+=(--image "$img")
        fi

        if (( ${#FILES[@]} > 1 )) && gum confirm "Combine the ${#FILES[@]} files into ONE document?"; then
            FLAGS+=(--concat)
            gum confirm "Insert a page break between files?" || FLAGS+=(--no-concat-pagebreak)
        fi
    fi

    # Format-specific.
    case "${src}->${to}" in
        "md->docx") gather_docx_options ;;
        "md->pdf")  gather_pdf_options  ;;
        "docx->md")
            local variant
            variant=$(gum choose "gfm" "markdown" "commonmark" --header "Markdown variant:") || true
            [[ -n "$variant" ]] && FLAGS+=(--md-variant "$variant")
            ;;
    esac
    return 0
}

gather_docx_options() {
    local ref
    ref=$(gum choose \
        "letterhead — header (logo/title) + footer (date · classification · page)" \
        "plain — styled, no header/footer" \
        "none — pandoc default" \
        --header "DOCX styling:") || true
    case "$ref" in
        letterhead*)
            FLAGS+=(--reference letterhead)
            local a c v l
            a=$(_clean_input "$(gum input --header "Author (header 'Created By'), blank to omit:" --placeholder "e.g. Platform Team" || true)")
            c=$(_clean_input "$(gum input --header "Classification (footer), blank to omit:"       --placeholder "e.g. INTERNAL" || true)")
            v=$(_clean_input "$(gum input --header "Version, blank to omit:"                        --placeholder "e.g. v1.0" || true)")
            l=$(prompt_path "Header logo path, blank = none:" "/path/to/logo.png")
            [[ -n "$a" ]] && FLAGS+=(--author "$a")
            [[ -n "$c" ]] && FLAGS+=(--classification "$c")
            [[ -n "$v" ]] && FLAGS+=(--version "$v")
            [[ -n "$l" ]] && FLAGS+=(--logo "$l")
            # Title-page chrome (only meaningful with a title page + letterhead).
            if [[ "$USE_TP" == true ]]; then
                confirm_flag "Show the header on the title page?"      "" --no-tp-header
                if gum confirm "Show the footer on the title page?"; then
                    confirm_flag "Show the page number on the title page?" "" --no-tp-pagenum
                else
                    FLAGS+=(--no-tp-footer)
                fi
            fi
            ;;
        plain*) FLAGS+=(--reference plain) ;;
        none*)  FLAGS+=(--reference none) ;;
        *) : ;;  # default (plain) if cancelled
    esac

    local size
    size=$(gum choose "a4" "letter" --header "Page size:") || true
    [[ -n "$size" ]] && FLAGS+=(--page-size "$size")

    local font
    font=$(pick_font "None (template default)")
    [[ -n "$font" ]] && FLAGS+=(--font "$font")
    return 0
}

# Prompt for a PDF engine from those actually installed. Echoes the choice, or
# empty to let holo-convert auto-pick. Detection is instant (command -v).
pick_pdf_engine() {
    local candidates=(xelatex lualatex pdflatex wkhtmltopdf weasyprint pagedjs-cli)
    local avail=() e
    for e in "${candidates[@]}"; do command -v "$e" &>/dev/null && avail+=("$e"); done
    [[ ${#avail[@]} -eq 0 ]] && return 0    # none installed → the engine guards/errors
    avail+=("auto (let holo-convert pick)")
    local sel
    sel=$(printf '%s\n' "${avail[@]}" | gum choose \
        --header "PDF engine — only installed shown:") || true
    [[ -z "$sel" || "$sel" == auto* ]] && return 0
    printf '%s' "$sel"
}

gather_pdf_options() {
    local font eng
    font=$(pick_font "None (pandoc default)")
    [[ -n "$font" ]] && FLAGS+=(--font "$font")
    eng=$(pick_pdf_engine)
    [[ -n "$eng" ]] && FLAGS+=(--pdf-engine "$eng")
    return 0
}

# -----------------------------------------------------------------------------
# Interactive broken-internal-link check. For each selected md file, ask the
# engine's checker for broken anchor links (JSON) and walk them one by one:
# accept the suggested fix (written straight into the source) or skip. Opt-in —
# offered only for md sources, and only when python3 + the checker are present.
# -----------------------------------------------------------------------------
interactive_link_check() {
    [[ "$SRC_FMT" == md ]] || return 0
    command -v python3 &>/dev/null || return 0
    local check="$(cd "$(dirname "$ENGINE")" && pwd)/.fcc/docx/check_links.py"
    [[ -f "$check" ]] || return 0

    gum confirm "Check internal links for broken anchors before converting?" || return 0

    local f line anchor sug conf heading total=0 fixed=0
    for f in "${FILES[@]}"; do
        # TSV: anchor <tab> suggestion <tab> confident(1/0) <tab> heading
        local tsv
        tsv=$(python3 "$check" --json "$f" 2>/dev/null | python3 -c '
import json,sys
try: data=json.load(sys.stdin)
except Exception: data=[]
for x in data:
    print("\t".join([x["anchor"], x.get("suggestion") or "", "1" if x.get("confident") else "0", x.get("heading") or ""]))
' 2>/dev/null || true)
        [[ -z "$tsv" ]] && continue
        info "Broken internal links in ${f}:"
        while IFS=$'\t' read -r anchor sug conf heading; do
            [[ -z "$anchor" ]] && continue
            total=$(( total + 1 ))
            if [[ -z "$sug" ]]; then
                warn "  '#${anchor}' — no similar heading found; fix it manually."
                continue
            fi
            local tag=""; [[ "$conf" == 0 ]] && tag="  (unsure — verify!)"
            gum style --foreground 220 "  '#${anchor}' → suggested '#${sug}'  (# ${heading})${tag}"
            if gum confirm "  Accept fix for '#${anchor}'?"; then
                if python3 "$check" --apply "$anchor" "$sug" "$f" 2>/dev/null; then
                    success "  fixed '#${anchor}' → '#${sug}' in ${f}"
                    fixed=$(( fixed + 1 ))
                else
                    warn "  could not rewrite '#${anchor}' (link syntax not found)."
                fi
            else
                info "  skipped '#${anchor}'."
            fi
        done <<< "$tsv"
    done
    (( total == 0 )) && info "No broken internal links found." || \
        info "Link check done — ${fixed}/${total} fixed."
}

# -----------------------------------------------------------------------------
main() {
    resolve_engine
    gather_options
    interactive_link_check

    # Shell-quote every argument so the preview is copy-paste safe: unquoted
    # ${FLAGS[*]} would render multi-word values (e.g. --author Platform
    # Infrastructure Team) as bare words that bleed across flags when reused.
    local preview; printf -v preview ' %q' holo-convert.sh "${FLAGS[@]}" "${FILES[@]}"
    info "Running:${preview}"
    # Guardrails only: if a dependency is missing the engine errors; offer --setup.
    if ! bash "$ENGINE" "${FLAGS[@]}" "${FILES[@]}"; then
        warn "Conversion failed — a dependency may be missing."
        if gum confirm "Run 'holo-convert --setup' to install dependencies, then retry?"; then
            # Scope the setup to the chosen target (--from/--to are already in FLAGS).
            bash "$ENGINE" --setup "${FLAGS[@]}" || error_exit "Setup failed."
            bash "$ENGINE" "${FLAGS[@]}" "${FILES[@]}" || error_exit "Conversion failed after setup."
        else
            exit 1
        fi
    fi
}

main "$@"
