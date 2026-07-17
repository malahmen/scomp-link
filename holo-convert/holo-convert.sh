#!/usr/bin/env bash
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
#   2. ../../holo-convert/holo-convert.sh       (sibling dev checkout)
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
# shellcheck source=../scripts/_common/ui.sh
source "${SCRIPT_DIR}/../scripts/_common/ui.sh"

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

    local sib="${SCRIPT_DIR}/../../holo-convert/holo-convert.sh"
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

confirm_flag() {  # $1 prompt, $2 flag-if-yes, [$3 flag-if-no]
    if gum confirm "$1"; then
        [[ -n "$2" ]] && FLAGS+=("$2")
    else
        [[ -n "${3:-}" ]] && FLAGS+=("$3")
    fi
    return 0   # never let the trailing test's status trip set -e in the caller
}

gather_options() {
    header "holo-convert"

    local src to
    src=$(gum choose "md" "docx" --header "Source format:") || exit 0
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
            local img; img=$(gum input --header "Title-page image path (blank = none):" \
                --placeholder "/path/to/logo.png") || true
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
            a=$(gum input --header "Author (header 'Created By'), blank to omit:" --placeholder "e.g. Platform Team") || true
            c=$(gum input --header "Classification (footer), blank to omit:"       --placeholder "e.g. INTERNAL") || true
            v=$(gum input --header "Version, blank to omit:"                        --placeholder "e.g. v1.0") || true
            l=$(gum input --header "Header logo path, blank = none:"                --placeholder "/path/to/logo.png") || true
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
    font=$(gum input --header "Prose font (blank = template default):" --placeholder "e.g. Helvetica") || true
    [[ -n "$font" ]] && FLAGS+=(--font "$font")
    return 0
}

gather_pdf_options() {
    local font
    font=$(gum input --header "Prose font (blank = pandoc default):" --placeholder "e.g. Helvetica") || true
    [[ -n "$font" ]] && FLAGS+=(--font "$font")
    # PDF engine is auto-selected by the engine (xelatex preferred); override here.
    local eng
    eng=$(gum input --header "PDF engine (blank = auto):" --placeholder "xelatex") || true
    [[ -n "$eng" ]] && FLAGS+=(--pdf-engine "$eng")
    return 0
}

# -----------------------------------------------------------------------------
main() {
    resolve_engine
    gather_options

    info "Running: holo-convert.sh ${FLAGS[*]} ${FILES[*]}"
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
