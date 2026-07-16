#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# file_conversion.sh
# Interactive TUI for converting files between formats.
# Supported: Markdown → PDF, Markdown → DOCX, DOCX → Markdown
# Called by init.sh — expects gum to already be available.
# Dependencies: gum (managed by init.sh), pandoc + PDF engine (checked at runtime)
# Config: .fcc/pdf/header.tex (created on first run if missing)
#         .fcc/title-pages/<name>.yaml + <name>.md (optional title page templates)
#
# export-setup: pandoc
#   Extra tools the standalone-export setup.sh should install beyond the
#   framework floor (curl/mise/bash/gum). A PDF engine (xelatex/…) and rsvg are
#   still resolved at runtime — pandoc is the one worth having up front.
# -----------------------------------------------------------------------------

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Canonical .fcc assets — the single source of truth, co-located with this
# script. ensure_fcc_*_assets copy missing pieces from here into the working
# ./.fcc/ so the code theme, filters, and reference docs travel with the tool.
# (The Starlight scaffolder also copies this bundle into project converters.)
CANONICAL_FCC="${SCRIPT_DIR}/.fcc"

# UI helpers. In the scomp-link repo they live in ../_common/ui.sh; when this
# script is vendored (e.g. into a Starlight project's converter/), a copy sits
# next to it. Prefer the repo location, fall back to the co-located one — so the
# same script works both in-repo and standalone.
if [[ -f "${SCRIPT_DIR}/../_common/ui.sh" ]]; then
    # shellcheck source=../_common/ui.sh
    source "${SCRIPT_DIR}/../_common/ui.sh"
elif [[ -f "${SCRIPT_DIR}/ui.sh" ]]; then
    # shellcheck source=/dev/null
    source "${SCRIPT_DIR}/ui.sh"
else
    printf "\033[0;31m[ERROR] ui.sh not found (looked in ../_common/ and alongside this script)\033[0m\n" >&2
    exit 1
fi

# Source root for the file picker. Default: the current directory. A vendored /
# embedding caller (e.g. the Starlight shim) can export SOURCE_ROOT to point at
# its docs directory before sourcing/running this script.
SOURCE_ROOT="${SOURCE_ROOT:-.}"

# -----------------------------------------------------------------------------
# Constants
# -----------------------------------------------------------------------------

FCC_DIR=".fcc"
TITLE_PAGES_DIR=".fcc/title-pages"
OUTPUT_DIR="./output"
DEFAULT_DEPTH=3

# Non-interactive (engine) mode — set true by the flag parser (parse_args).
# When true the code must NOT prompt (no gum input/choose/confirm) and must NOT
# offer to install missing dependencies — it only checks for them (guardrails).
# The interactive gum UI (main / main_fast) leaves this false.
NONINTERACTIVE=false
MD_VARIANT="gfm"          # docx→md output variant (overridable via --md-variant)
_ENGINE_FONT=""           # deferred --font value (applied once --to is known)
_ENGINE_REFERENCE=""      # deferred --reference value (docx)

# Plain, gum-free status output for the engine path. The interactive path uses
# ui.sh's gum-based helpers; the CLI layer must stay usable without gum.
enote() { printf '\033[0;36m[info]\033[0m  %s\n' "$*" >&2; }
edie()  { printf '\033[0;31m[error]\033[0m %s\n' "$*" >&2; exit 1; }

# Built-in DOCX reference docs. Both carry the shaded code + aligned TOC styling;
# the letterhead one adds a running header (logo + title) + footer (date ·
# classification · Page X/Y). reference-plain has no header/footer.
DOCX_DEFAULT_REFERENCE=".fcc/docx/reference.docx"          # letterhead
DOCX_PLAIN_REFERENCE=".fcc/docx/reference-plain.docx"      # no header/footer
DOCX_CONFIG=".fcc/docx/config"                             # key=value defaults

# Letterhead token state (set by select_docx_reference_doc → resolve_letterhead)
DOCX_LETTERHEAD=false
DOCX_AUTHOR=""
DOCX_CLASSIFICATION=""
DOCX_VERSION=""
DOCX_DATE=""
DOCX_LOGO=""

# Title-page image prompt cache (so batch runs ask at most once)
TITLE_IMG_ASKED=false
TITLE_IMG_CACHE=""


# Title page state (set by select_title_page)
USE_TITLE_PAGE=false

# Title-page letterhead chrome (resolved by resolve_title_page_chrome when a
# title page is active). Default = show everything, i.e. current behaviour.
TP_HEADER=true
TP_FOOTER=true
TP_PAGENUM=true

# Set by apply_title_page (per file) when it emits the TOC itself, after the
# title page. The converters then skip pandoc's --toc so it isn't ALSO placed
# at the very top (above the cover).
TOC_PLACED_IN_TITLE=false

# Substitution pass state (set by select_apply_substitutions)
APPLY_SUBSTITUTIONS=false

# Rule stripping state (set by select_strip_rules)
STRIP_RULES=false

# Wikilink unwrap state (set by select_unwrap_wikilinks)
UNWRAP_WIKILINKS=false

# SVG rasterization state (set by select_svg_raster)
RASTER_SVG=false

# Concat state (set by select_concat) — combine several md into one document
CONCAT=false
CONCAT_PAGEBREAK=true

# DOCX page size (set by select_docx_page_size): a4 | letter
DOCX_PAGE_SIZE="a4"

# Table of contents state (set by select_toc)
USE_TOC=false
TOC_DEPTH=3
TOC_TITLE="Contents"

# PDF conversion state (set by dispatch → check_deps_md_pdf / select_pdf_engine / select_pdf_font)
PDF_ENGINE=""
PDF_FONT=""
AVAILABLE_ENGINES=()
MONOFONT_TEX=""
HEADER_TEX=""

# DOCX conversion state (set by dispatch → select_docx_font / detect_docx_mono).
# Applied to the generated .docx so it uses installed fonts instead of the
# reference template's Microsoft defaults (Aptos/Calibri/Cambria, Consolas).
DOCX_FONT=""   # prose (headings + body); empty = leave the template's theme
DOCX_MONO=""   # monospace (code); auto-detected

trap 'echo ""; gum style --faint "Interrupted."; exit 0' INT TERM

# -----------------------------------------------------------------------------
# Cross-platform file opener
# Tries xdg-open (Linux), then open (macOS).
# Silent no-op if neither is available.
# -----------------------------------------------------------------------------

open_file() {
    local file="$1"
    if command -v xdg-open &>/dev/null; then
        xdg-open "$file" &>/dev/null &
    elif command -v open &>/dev/null; then
        open "$file"
    fi
}

# -----------------------------------------------------------------------------
# Source format selection
# Add new entries here as new source formats are supported.
# -----------------------------------------------------------------------------

select_source_format() {
    local format
    format=$(gum choose \
        "Markdown (.md)" \
        "DOCX (.docx)" \
        --header "Select source format:") || true

    [[ -z "$format" ]] && { gum style --faint "Cancelled."; exit 0; }

    case "$format" in
        "Markdown (.md)") SOURCE_FORMAT="md" ;;
        "DOCX (.docx)")   SOURCE_FORMAT="docx" ;;
        *) error_exit "Unknown format: ${format}" ;;
    esac

    info "Source format: ${format}"
}

# -----------------------------------------------------------------------------
# Depth selection
# -----------------------------------------------------------------------------

select_depth() {
    local raw
    raw=$(gum input \
        --placeholder "${DEFAULT_DEPTH}" \
        --header "Search depth for source files (leave empty for default ${DEFAULT_DEPTH}):") || true

    local depth="${raw:-${DEFAULT_DEPTH}}"

    # Validate: must be a positive integer between 1 and 10
    if ! [[ "$depth" =~ ^[0-9]+$ ]] || (( depth < 1 || depth > 10 )); then
        warn "Invalid depth '${depth}', using default ${DEFAULT_DEPTH}."
        depth="${DEFAULT_DEPTH}"
    fi

    SEARCH_DEPTH="$depth"
    info "Search depth: ${SEARCH_DEPTH}"
}

# -----------------------------------------------------------------------------
# File selection
# Finds files matching SOURCE_FORMAT up to SEARCH_DEPTH, strips leading ./
# Handles name collisions by using path-derived names at conversion time.
# -----------------------------------------------------------------------------

select_files() {
    local pattern="*.${SOURCE_FORMAT}"

    info "Scanning ${SOURCE_ROOT} for .${SOURCE_FORMAT} files (depth ${SEARCH_DEPTH})..."

    # Paths are kept relative to the current directory (SOURCE_ROOT may be "."
    # for the repo tool, or e.g. ../src/content/docs when vendored) so they're
    # usable directly at conversion time. Only a leading "./" is stripped.
    local found
    found=$(find "$SOURCE_ROOT" -maxdepth "$SEARCH_DEPTH" -name "$pattern" \
        ! -path "*/node_modules/*" \
        ! -path "*/.git/*" \
        ! -path "*/.astro/*" \
        ! -path "*/dist/*" \
        ! -path "*/${FCC_DIR}/*" \
        ! -path "*/output/*" \
        | sed 's|^\./||' \
        | sort)

    if [[ -z "$found" ]]; then
        error_exit "No .${SOURCE_FORMAT} files found in ${SOURCE_ROOT} (depth ${SEARCH_DEPTH})."
    fi

    local file_count
    file_count=$(echo "$found" | wc -l | tr -d ' ')
    local list_height=$(( file_count < 15 ? file_count + 2 : 17 ))

    local selected
    selected=$(echo "$found" | gum choose --no-limit \
        --height "$list_height" \
        --header "Select file(s) — SPACE to select, ENTER to confirm:") || true

    [[ -z "$selected" ]] && { gum style --faint "Cancelled."; exit 0; }

    SELECTED_FILES="$selected"
    local selected_count
    selected_count=$(echo "$selected" | wc -l | tr -d ' ')
    info "Selected ${selected_count} file(s)."
}

# -----------------------------------------------------------------------------
# Output format selection
# Add new entries here as new output formats are supported.
# -----------------------------------------------------------------------------

select_output_format() {
    local format

    case "$SOURCE_FORMAT" in
        "md")
            format=$(gum choose \
                "PDF (.pdf)" \
                "DOCX (.docx)" \
                --header "Select output format:") || true
            ;;
        "docx")
            format=$(gum choose \
                "Markdown (.md)" \
                --header "Select output format:") || true
            ;;
        *)
            error_exit "No output formats defined for source format: ${SOURCE_FORMAT}"
            ;;
    esac

    [[ -z "$format" ]] && { gum style --faint "Cancelled."; exit 0; }

    case "$format" in
        "PDF (.pdf)")      OUTPUT_FORMAT="pdf" ;;
        "DOCX (.docx)")    OUTPUT_FORMAT="docx" ;;
        "Markdown (.md)")  OUTPUT_FORMAT="md" ;;
        *) error_exit "Unknown output format: ${format}" ;;
    esac

    info "Output format: ${format}"
}

# =============================================================================
# FORMAT-PAIR: Markdown → PDF
# =============================================================================

# -----------------------------------------------------------------------------
# Dependency check: md → pdf
# -----------------------------------------------------------------------------

check_deps_md_pdf() {
    header "Checking Dependencies"

    if ! command -v pandoc &>/dev/null; then
        warn "pandoc is not installed."
        if gum confirm "Attempt to install pandoc now?"; then
            local os=""
            case "$(uname -s)" in
                Darwin) os="macos" ;;
                Linux)  os="linux" ;;
            esac

            local installed=false
            case "$os" in
                macos)
                    if command -v brew &>/dev/null; then
                        brew install pandoc && installed=true
                    else
                        warn "Homebrew not found. Cannot auto-install pandoc."
                    fi
                    ;;
                linux)
                    if sudo -n true 2>/dev/null; then
                        if command -v apt-get &>/dev/null; then
                            sudo apt-get install -y pandoc && installed=true
                        elif command -v dnf &>/dev/null; then
                            sudo dnf install -y pandoc && installed=true
                        else
                            warn "No supported package manager found (apt/dnf)."
                        fi
                    else
                        warn "sudo access unavailable. Cannot auto-install pandoc."
                    fi
                    ;;
            esac

            if [[ "$installed" == "true" ]] && command -v pandoc &>/dev/null; then
                success "pandoc installed: $(pandoc --version | head -1)"
            else
                error_exit "pandoc installation failed.
Install it manually from: https://pandoc.org/installing.html
  macOS:  brew install pandoc
  Linux:  sudo apt install pandoc  /  sudo dnf install pandoc"
            fi
        else
            error_exit "pandoc is required. Install it from: https://pandoc.org/installing.html"
        fi
    fi
    local _pandoc_ver
    _pandoc_ver=$(pandoc --version | head -1 | awk '{print $2}')
    success "pandoc ${_pandoc_ver} found."

    # Verify at least one usable PDF engine is available
    local engines_found=()
    for eng in xelatex lualatex pdflatex wkhtmltopdf weasyprint pagedjs-cli; do
        command -v "$eng" &>/dev/null && engines_found+=("$eng")
    done

    if [[ ${#engines_found[@]} -eq 0 ]]; then
        warn "No PDF engine found."
        if gum confirm "Attempt to install TeX Live (xelatex) now? This may take several minutes."; then
            local os=""
            case "$(uname -s)" in
                Darwin) os="macos" ;;
                Linux)  os="linux" ;;
            esac

            local installed=false
            case "$os" in
                macos)
                    if command -v brew &>/dev/null; then
                        brew install --cask mactex-no-gui && installed=true
                    else
                        warn "Homebrew not found. Cannot auto-install TeX Live."
                    fi
                    ;;
                linux)
                    if sudo -n true 2>/dev/null; then
                        if command -v apt-get &>/dev/null; then
                            sudo apt-get install -y texlive-xetex && installed=true
                        elif command -v dnf &>/dev/null; then
                            sudo dnf install -y texlive-xetex && installed=true
                        else
                            warn "No supported package manager found (apt/dnf)."
                        fi
                    else
                        warn "sudo access unavailable. Cannot auto-install TeX Live."
                    fi
                    ;;
            esac

            if [[ "$installed" == "true" ]] && command -v xelatex &>/dev/null; then
                success "xelatex installed."
                engines_found=("xelatex")
            else
                error_exit "TeX Live installation failed.
Install a PDF engine manually:
  xelatex / lualatex / pdflatex:  https://tug.org/texlive/
  wkhtmltopdf:                     https://wkhtmltopdf.org
  weasyprint:                      pip install weasyprint
  pagedjs-cli:                     npm install -g pagedjs-cli"
            fi
        else
            error_exit "A PDF engine is required. Install at least one:
  xelatex / lualatex / pdflatex:  install TeX Live or MiKTeX
  wkhtmltopdf:                     https://wkhtmltopdf.org
  weasyprint:                      pip install weasyprint
  pagedjs-cli:                     npm install -g pagedjs-cli"
        fi
    fi

    success "PDF engines available: ${engines_found[*]}"
    AVAILABLE_ENGINES=("${engines_found[@]}")
}

# -----------------------------------------------------------------------------
# Config: ensure the .fcc/pdf/ asset set exists.
#
# Copies any missing asset from the canonical bundle (CANONICAL_FCC/pdf/) into
# the working ./.fcc/pdf/. Existing files are never overwritten, so a project
# can customise them. header.tex has a minimal built-in fallback for the case
# where the bundle is unavailable (script run outside the repo).
#
# Arguments: asset filenames to ensure. With none, ensures the full PDF set.
# -----------------------------------------------------------------------------

_write_basic_header() {
    # Minimal fallback used only when the canonical header.tex is unavailable.
    cat > "$1" << 'EOF'
\usepackage{listings}
\usepackage{xcolor}
\lstset{
  breaklines=true,
  breakatwhitespace=true,
  basicstyle=\small\ttfamily,
  columns=flexible,
  backgroundcolor=\color{gray!10},
  frame=single,
  framesep=3pt
}
EOF
}

ensure_fcc_pdf_assets() {
    local assets=("$@")
    if [[ ${#assets[@]} -eq 0 ]]; then
        assets=(header.tex p10k.theme widen-tables.lua render-mermaid.lua pagebreak.lua)
    fi

    local pdf_config_dir="${FCC_DIR}/pdf"
    local src="${CANONICAL_FCC}/pdf"
    mkdir -p "$pdf_config_dir"

    # ALL PDF assets are behaviour-critical and kept in sync with the bundle, so
    # a stale copy from an older run never lingers. This specifically prevents
    # the old basic `listings` header.tex (no fvextra line-breaking) from
    # surviving and making code blocks overflow the box.
    local a dest
    for a in "${assets[@]}"; do
        dest="${pdf_config_dir}/${a}"
        if [[ -f "${src}/${a}" ]]; then
            if [[ ! -f "$dest" ]] || ! cmp -s "${src}/${a}" "$dest"; then
                cp "${src}/${a}" "$dest"
                info "Synced ${dest} (bundled)."
            fi
        elif [[ "$a" == "header.tex" && ! -f "$dest" ]]; then
            _write_basic_header "$dest"
            warn "Bundled header.tex not found — wrote minimal fallback to ${dest}."
        elif [[ ! -f "$dest" ]]; then
            warn "Bundled asset '${a}' not found at ${src}/ — feature relying on it will be skipped."
        fi
    done
}

ensure_pdf_config() {
    ensure_fcc_pdf_assets
    HEADER_TEX="${FCC_DIR}/pdf/header.tex"
    info "Using ${HEADER_TEX}."
}

# -----------------------------------------------------------------------------
# Seed the working .fcc/title-pages/ with the bundled default template.
# Unlike the PDF/DOCX asset trees these are user-customisable, so we only copy
# the bundled default.* when MISSING — never clobbering a project's own default
# or its file-specific <flattened_path>.yaml templates.
# -----------------------------------------------------------------------------
ensure_fcc_title_pages() {
    local src="${CANONICAL_FCC}/title-pages"
    [[ -d "$src" ]] || return 0
    mkdir -p "$TITLE_PAGES_DIR"
    local base dest f
    for f in "${src}/default.yaml" "${src}/default.md"; do
        [[ -f "$f" ]] || continue
        base=$(basename "$f")
        dest="${TITLE_PAGES_DIR}/${base}"
        if [[ ! -f "$dest" ]]; then
            cp "$f" "$dest"
            info "Seeded ${dest} (bundled default title page)."
        fi
    done
}

# -----------------------------------------------------------------------------
# Resolve a lua filter to a usable path.
# Prefer the working ./.fcc/ copy (so per-project customisation wins), but fall
# back to the canonical bundle so a missing or partial .fcc never silently
# disables a behaviour-critical filter (e.g. page breaks in DOCX).
# Prints the path, or nothing if the filter can't be found in either location.
# -----------------------------------------------------------------------------

resolve_lua_filter() {
    local name="$1"
    if [[ -f "${FCC_DIR}/pdf/${name}" ]]; then
        printf '%s' "${FCC_DIR}/pdf/${name}"
    elif [[ -f "${CANONICAL_FCC}/pdf/${name}" ]]; then
        printf '%s' "${CANONICAL_FCC}/pdf/${name}"
    fi
}

# Same, but for the DOCX asset tree (.fcc/docx/) — kept separate from PDF so the
# two paths never share files.
resolve_docx_asset() {
    local name="$1"
    if [[ -f "${FCC_DIR}/docx/${name}" ]]; then
        printf '%s' "${FCC_DIR}/docx/${name}"
    elif [[ -f "${CANONICAL_FCC}/docx/${name}" ]]; then
        printf '%s' "${CANONICAL_FCC}/docx/${name}"
    fi
}

# -----------------------------------------------------------------------------
# Ensure the DOCX asset tree (.fcc/docx/) is present AND current.
#
# DOCX is kept COMPLETELY SEPARATE from the PDF assets (.fcc/pdf/): it has its
# own copies of the reference doc, the lua filters it uses, and the syntax
# theme. This way PDF changes can never affect DOCX and vice-versa. All are
# managed (synced from the bundle) so stale copies self-heal.
#
# Returns non-zero only if the bundle is absent and no local reference exists,
# so the caller can fall back to pandoc defaults.
# -----------------------------------------------------------------------------

ensure_fcc_docx_assets() {
    local docx_dir="${FCC_DIR}/docx"
    local src="${CANONICAL_FCC}/docx"
    mkdir -p "$docx_dir"

    local a dest
    for a in reference.docx reference-plain.docx stamp_docx_tokens.py docx_layout.py pagebreak.lua render-mermaid.lua p10k.theme; do
        dest="${docx_dir}/${a}"
        if [[ -f "${src}/${a}" ]]; then
            if [[ ! -f "$dest" ]] || ! cmp -s "${src}/${a}" "$dest"; then
                cp "${src}/${a}" "$dest"
                info "Synced ${dest} (bundled)."
            fi
        elif [[ ! -f "$dest" ]]; then
            warn "Bundled DOCX asset '${a}' not found at ${src}/ — related styling will be skipped."
        fi
    done

    # Usable if the reference doc ended up available (bundle or pre-existing).
    [[ -f "$DOCX_DEFAULT_REFERENCE" ]] && return 0
    return 1
}

# -----------------------------------------------------------------------------
# Post-process a generated .docx: fold each pageBreakBefore break paragraph onto
# the following paragraph so a heading after \newpage starts the new page with
# no blank line above it. The fold_pagebreaks.py helper is behaviour-critical
# code, so keep the working copy in sync with the bundle (like the lua filters).
# Skipped cleanly if python3 is unavailable — the break paragraph then remains
# (no blank page, just a blank line), so nothing is ever dropped.
# -----------------------------------------------------------------------------

fold_docx_pagebreaks() {
    local docx="$1"
    command -v python3 &>/dev/null || {
        info "python3 not found — leaving page-break paragraphs as-is (a blank line may show above headings)."
        return 0
    }

    local dest="${FCC_DIR}/docx/fold_pagebreaks.py"
    local src="${CANONICAL_FCC}/docx/fold_pagebreaks.py"
    mkdir -p "$(dirname "$dest")"
    if [[ -f "$src" ]] && { [[ ! -f "$dest" ]] || ! cmp -s "$src" "$dest"; }; then
        cp "$src" "$dest"
        info "Synced ${dest} (bundled)."
    fi

    local script="$dest"
    [[ -f "$script" ]] || script="$src"
    [[ -f "$script" ]] || { warn "fold_pagebreaks.py not found — skipping page-break tidy."; return 0; }

    python3 "$script" "$docx"
}

# -----------------------------------------------------------------------------
# Post-process a generated .docx: write explicit header + alternating-row cell
# shading onto every table, matching the PDF's row colours. Word — and
# especially LibreOffice / previewers — don't reliably render the reference
# table style's conditional banding, so we set it per cell instead.
# Skipped cleanly if python3 is unavailable (tables just stay unbanded).
# -----------------------------------------------------------------------------

shade_docx_tables() {
    local docx="$1"
    command -v python3 &>/dev/null || {
        info "python3 not found — leaving table rows unbanded."
        return 0
    }

    local dest="${FCC_DIR}/docx/shade_tables.py"
    local src="${CANONICAL_FCC}/docx/shade_tables.py"
    mkdir -p "$(dirname "$dest")"
    if [[ -f "$src" ]] && { [[ ! -f "$dest" ]] || ! cmp -s "$src" "$dest"; }; then
        cp "$src" "$dest"
        info "Synced ${dest} (bundled)."
    fi

    local script="$dest"
    [[ -f "$script" ]] || script="$src"
    [[ -f "$script" ]] || { warn "shade_tables.py not found — skipping table shading."; return 0; }

    python3 "$script" "$docx"
}

# True when the chosen reference is one of our built-ins (letterhead or plain) —
# gates the p10k theme + explicit table banding.
is_builtin_docx_ref() {
    [[ "$DOCX_REFERENCE_DOC" == "$DOCX_DEFAULT_REFERENCE" \
       || "$DOCX_REFERENCE_DOC" == "$DOCX_PLAIN_REFERENCE" ]]
}

# -----------------------------------------------------------------------------
# Letterhead: fill the reference doc's header/footer {{TOKENS}} for this doc.
# Title comes from the document (front-matter title: or first #); author /
# classification / version / date come from the session defaults, overridden by
# this file's YAML front matter when it sets them. Date defaults to today.
# -----------------------------------------------------------------------------

stamp_docx_letterhead() {
    local docx="$1" source="$2"
    command -v python3 &>/dev/null || { warn "python3 not found — letterhead tokens left unstamped."; return 0; }
    local script; script="$(resolve_docx_asset stamp_docx_tokens.py)"
    [[ -n "$script" ]] || { warn "stamp_docx_tokens.py not found — skipping letterhead."; return 0; }

    # `|| true` on each: an absent front-matter key exits non-zero (pipefail),
    # which a bare x="$(...)" assignment propagates into set -e.
    local title author classification version date vsuffix logo
    title="$(extract_title "$source" || true)"
    author="$(parse_yaml_field "$source" author || true)";                author="${author:-$DOCX_AUTHOR}"
    classification="$(parse_yaml_field "$source" classification || true)"; classification="${classification:-$DOCX_CLASSIFICATION}"
    version="$(parse_yaml_field "$source" version || true)";               version="${version:-$DOCX_VERSION}"
    date="$(parse_yaml_field "$source" date || true)";                     date="${date:-$DOCX_DATE}"
    logo="$(parse_yaml_field "$source" logo || true)";                     logo="${logo:-$DOCX_LOGO}"
    logo="${logo/#\~/$HOME}"
    [[ -n "$logo" && ! -f "$logo" ]] && { warn "Logo not found: ${logo} — skipping."; logo=""; }
    [[ -z "$date" || "$date" == "auto" ]] && date="$(date +'%d %B %Y' | sed 's/^0//')"
    [[ -n "$version" ]] && vsuffix=", ${version}" || vsuffix=""

    local logo_args=()
    [[ -n "$logo" ]] && logo_args=(--logo "$logo")

    # Title-page chrome: only when a title page is active (it owns page 1). Maps
    # the TP_* booleans to the stamper's show/hide flags.
    local tp_args=()
    if [[ "$USE_TITLE_PAGE" == "true" ]]; then
        local _sh _sf _sp
        [[ "$TP_HEADER"  == true ]] && _sh=show || _sh=hide
        [[ "$TP_FOOTER"  == true ]] && _sf=show || _sf=hide
        [[ "$TP_PAGENUM" == true ]] && _sp=show || _sp=hide
        tp_args=(--tp-header "$_sh" --tp-footer "$_sf" --tp-pagenum "$_sp")
    fi

    python3 "$script" "$docx" \
        --title "$title" --version-suffix "$vsuffix" \
        --author "$author" --date "$date" --classification "$classification" \
        "${logo_args[@]}" "${tp_args[@]}"
}

# -----------------------------------------------------------------------------
# Adjust the generated .docx layout: page size (DOCX_PAGE_SIZE) + fit wide images
# to the text column + centre image paragraphs. Skipped if python3 is missing.
# -----------------------------------------------------------------------------

layout_docx() {
    local docx="$1"
    command -v python3 &>/dev/null || return 0
    local script; script="$(resolve_docx_asset docx_layout.py)"
    [[ -n "$script" ]] || return 0
    python3 "$script" "$docx" --page-size "$DOCX_PAGE_SIZE"
}

# -----------------------------------------------------------------------------
# Apply the selected prose font (DOCX_FONT) and monospace font (DOCX_MONO) to a
# generated .docx, so it uses installed fonts instead of the reference
# template's Microsoft defaults. No-op for prose if DOCX_FONT is empty (template
# default kept). Skipped cleanly if python3 is unavailable.
# -----------------------------------------------------------------------------

apply_docx_fonts() {
    local docx="$1"
    [[ -z "$DOCX_FONT" && -z "$DOCX_MONO" ]] && return 0
    command -v python3 &>/dev/null || {
        info "python3 not found — leaving DOCX fonts as the template defaults."
        return 0
    }

    local dest="${FCC_DIR}/docx/apply_docx_fonts.py"
    local src="${CANONICAL_FCC}/docx/apply_docx_fonts.py"
    mkdir -p "$(dirname "$dest")"
    if [[ -f "$src" ]] && { [[ ! -f "$dest" ]] || ! cmp -s "$src" "$dest"; }; then
        cp "$src" "$dest"
        info "Synced ${dest} (bundled)."
    fi

    local script="$dest"
    [[ -f "$script" ]] || script="$src"
    [[ -f "$script" ]] || { warn "apply_docx_fonts.py not found — skipping DOCX font apply."; return 0; }

    python3 "$script" "$docx" "$DOCX_FONT" "$DOCX_MONO"
}

# -----------------------------------------------------------------------------
# Detect a usable monospace font and write .fcc/pdf/monofont.tex.
# Called once per md→pdf run before conversion begins.
#
# Resolution order: DejaVu Sans Mono → Noto Mono → Liberation Mono → Courier New
# On macOS: uses path-based \setmonofont (bypasses XeLaTeX font DB lag).
# On Linux: uses name-based \setmonofont (fc-list is reliable).
# Falls back to Courier New if nothing else found (always present on both).
# Writes monofont.tex into .fcc/pdf/ for -H inclusion at pandoc time.
# -----------------------------------------------------------------------------

detect_mono_font() {
    local pdf_config_dir="${FCC_DIR}/pdf"
    local monofont_tex="${pdf_config_dir}/monofont.tex"
    local os=""
    case "$(uname -s)" in
        Darwin) os="macos" ;;
        Linux)  os="linux" ;;
        *)      os="linux" ;;
    esac

    mkdir -p "$pdf_config_dir"

    local chosen_font=""
    local font_tex_line=""

    if [[ "$os" == "macos" ]]; then
        # On macOS, fc-list lags after Homebrew cask installs because
        # com.apple.FontRegistry updates asynchronously. Use file existence
        # as the primary detection method — it's always reliable.
        local user_fonts="${HOME}/Library/Fonts"
        local sys_fonts="/Library/Fonts"

        if ls "${user_fonts}"/DejaVuSansMono.ttf &>/dev/null 2>&1 || \
           ls "${sys_fonts}"/DejaVuSansMono.ttf &>/dev/null 2>&1; then
            chosen_font="DejaVu Sans Mono"
            font_tex_line='\setmonofont{DejaVuSansMono.ttf}[Path='"${user_fonts}"'/, BoldFont=DejaVuSansMono-Bold.ttf, ItalicFont=DejaVuSansMono-Oblique.ttf, BoldItalicFont=DejaVuSansMono-BoldOblique.ttf]'
            # Prefer system-wide path if that's where it lives
            if ls "${sys_fonts}"/DejaVuSansMono.ttf &>/dev/null 2>&1; then
                font_tex_line='\setmonofont{DejaVuSansMono.ttf}[Path='"${sys_fonts}"'/, BoldFont=DejaVuSansMono-Bold.ttf, ItalicFont=DejaVuSansMono-Oblique.ttf, BoldItalicFont=DejaVuSansMono-BoldOblique.ttf]'
            fi
        elif ls "${user_fonts}"/NotoMono-Regular.ttf &>/dev/null 2>&1 || \
             ls "${sys_fonts}"/NotoMono-Regular.ttf &>/dev/null 2>&1; then
            chosen_font="Noto Mono"
            local noto_path="${user_fonts}"
            ls "${sys_fonts}"/NotoMono-Regular.ttf &>/dev/null 2>&1 && noto_path="${sys_fonts}"
            font_tex_line='\setmonofont{NotoMono-Regular.ttf}[Path='"${noto_path}"'/]'
        elif ls "${user_fonts}"/LiberationMono-Regular.ttf &>/dev/null 2>&1 || \
             ls "${sys_fonts}"/LiberationMono-Regular.ttf &>/dev/null 2>&1; then
            chosen_font="Liberation Mono"
            local lib_path="${user_fonts}"
            ls "${sys_fonts}"/LiberationMono-Regular.ttf &>/dev/null 2>&1 && lib_path="${sys_fonts}"
            font_tex_line='\setmonofont{LiberationMono-Regular.ttf}[Path='"${lib_path}"'/]'
        else
            # Attempt to install DejaVu via Homebrew cask
            if command -v brew &>/dev/null; then
                info "No preferred monospace font found. Attempting: brew install --cask font-dejavu..."
                brew install --cask font-dejavu 2>/dev/null || true
                if ls "${user_fonts}"/DejaVuSansMono.ttf &>/dev/null 2>&1; then
                    chosen_font="DejaVu Sans Mono"
                    font_tex_line='\setmonofont{DejaVuSansMono.ttf}[Path='"${user_fonts}"'/, BoldFont=DejaVuSansMono-Bold.ttf, ItalicFont=DejaVuSansMono-Oblique.ttf, BoldItalicFont=DejaVuSansMono-BoldOblique.ttf]'
                fi
            fi
            if [[ -z "$chosen_font" ]]; then
                chosen_font="Courier New"
                font_tex_line='\setmonofont{Courier New}'
                warn "Falling back to Courier New for monospace. For better code rendering, install DejaVu fonts: brew install --cask font-dejavu"
            fi
        fi
    else
        # Linux: fc-list is reliable
        if fc-list : family | grep -qi "DejaVu Sans Mono"; then
            chosen_font="DejaVu Sans Mono"
            font_tex_line='\setmonofont{DejaVu Sans Mono}'
        elif fc-list : family | grep -qi "Noto Mono"; then
            chosen_font="Noto Mono"
            font_tex_line='\setmonofont{Noto Mono}'
        elif fc-list : family | grep -qi "Liberation Mono"; then
            chosen_font="Liberation Mono"
            font_tex_line='\setmonofont{Liberation Mono}'
        else
            if command -v apt-get &>/dev/null && sudo -n true 2>/dev/null; then
                info "No preferred monospace font found. Attempting: sudo apt-get install fonts-dejavu..."
                sudo apt-get install -y fonts-dejavu 2>/dev/null || true
                fc-cache -f 2>/dev/null || true
                if fc-list : family | grep -qi "DejaVu Sans Mono"; then
                    chosen_font="DejaVu Sans Mono"
                    font_tex_line='\setmonofont{DejaVu Sans Mono}'
                fi
            fi
            if [[ -z "$chosen_font" ]]; then
                chosen_font="Courier New"
                font_tex_line='\setmonofont{Courier New}'
                warn "Falling back to Courier New for monospace. For better code rendering, install DejaVu fonts: sudo apt-get install fonts-dejavu"
            fi
        fi
    fi

    printf '%s\n' "${font_tex_line}" > "$monofont_tex"

    MONOFONT_TEX="$monofont_tex"
    success "Monospace font: ${chosen_font} → $(basename "$monofont_tex")"
}

# -----------------------------------------------------------------------------
# Conversion options: engine + font
# select_pdf_font controls the prose (main) font only.
# Monospace font is handled by detect_mono_font.
# -----------------------------------------------------------------------------

select_pdf_engine() {
    if [[ ${#AVAILABLE_ENGINES[@]} -eq 0 ]]; then
        error_exit "No PDF engines available. Run dependency check first."
    fi

    local engine
    engine=$(printf '%s\n' "${AVAILABLE_ENGINES[@]}" | gum choose \
        --header "Select PDF engine:") || true

    [[ -z "$engine" ]] && { gum style --faint "Cancelled."; exit 0; }

    PDF_ENGINE="$engine"
    info "PDF engine: ${PDF_ENGINE}"
}

# -----------------------------------------------------------------------------
# Is a font family installed on this system?
# Uses fontconfig (fc-list) when available — reliable on Linux and on macOS
# with Homebrew fontconfig. If fc-list is absent we cannot verify, so we
# optimistically report "installed" (best effort) rather than hide everything.
# -----------------------------------------------------------------------------

# macOS system font registry (families), loaded once. fontconfig is an add-on on
# macOS and its cache/config does not always index /System/Library/Fonts, so a
# system font like Helvetica can be missing from fc-list even though it exists
# and XeLaTeX/LuaLaTeX can load it by name. system_profiler is authoritative.
_MACOS_FONT_FAMILIES=""
_MACOS_FONTS_LOADED=""
_ensure_macos_fonts() {
    [[ -n "$_MACOS_FONTS_LOADED" ]] && return
    _MACOS_FONTS_LOADED=1
    command -v system_profiler &>/dev/null || return
    _MACOS_FONT_FAMILIES=$(system_profiler SPFontsDataType 2>/dev/null \
        | sed -n 's/^[[:space:]]*Family:[[:space:]]*//p' | sort -u)
}

font_installed() {
    local family="$1"

    # fontconfig first (fast): reliable on Linux and macOS-with-Homebrew-fontconfig.
    if command -v fc-list &>/dev/null \
       && fc-list : family | tr ',' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' \
            | grep -qixF "$family"; then
        return 0
    fi

    # macOS fallback: the authoritative system font registry, so system fonts
    # like Helvetica are offered even when fontconfig does not see them.
    if [[ "$(uname)" == "Darwin" ]]; then
        _ensure_macos_fonts
        printf '%s\n' "$_MACOS_FONT_FAMILIES" | grep -qixF "$family"
        return
    fi

    command -v fc-list &>/dev/null && return 1   # fc-list gave a definitive "no"
    return 0                                      # no detector ⇒ stay optimistic
}

select_pdf_font() {
    PDF_FONT=""

    if [[ "$PDF_ENGINE" != "xelatex" && "$PDF_ENGINE" != "lualatex" ]]; then
        warn "Font selection only applies to xelatex/lualatex. Skipping for ${PDF_ENGINE}."
        return
    fi

    # Only offer fonts that are actually installed — a missing font makes
    # xelatex/lualatex abort the whole conversion.
    local candidates=("Helvetica" "Times New Roman" "Georgia" "Palatino" "Garamond" "Arial")
    local avail=()
    local f
    for f in "${candidates[@]}"; do
        font_installed "$f" && avail+=("$f")
    done
    avail+=("None (pandoc default)")

    if [[ ${#avail[@]} -eq 1 ]]; then
        warn "None of the preset prose fonts are installed — using pandoc default."
        PDF_FONT=""
        return
    fi

    local font
    font=$(printf '%s\n' "${avail[@]}" | gum choose \
        --header "Select prose font (body text) — only installed fonts shown:") || true

    [[ -z "$font" ]] && { gum style --faint "Cancelled."; exit 0; }
    [[ "$font" == "None (pandoc default)" ]] && { PDF_FONT=""; return; }

    PDF_FONT="$font"
    info "Prose font: ${PDF_FONT}"
}

# -----------------------------------------------------------------------------
# DOCX prose font picker (parity with select_pdf_font). The chosen font is
# applied to the generated .docx theme (headings + body) by apply_docx_fonts, so
# Word does not substitute the reference template's fonts. "None" keeps the
# template's own fonts (which may not be installed).
# -----------------------------------------------------------------------------

select_docx_font() {
    DOCX_FONT=""

    local candidates=("Helvetica" "Arial" "Times New Roman" "Georgia" "Palatino" "Garamond")
    local avail=()
    local f
    for f in "${candidates[@]}"; do
        font_installed "$f" && avail+=("$f")
    done
    avail+=("None (template default)")

    if [[ ${#avail[@]} -eq 1 ]]; then
        warn "None of the preset prose fonts are installed — keeping the template's fonts."
        return
    fi

    local font
    font=$(printf '%s\n' "${avail[@]}" | gum choose \
        --header "Select DOCX prose font (body + headings) — only installed fonts shown:") || true

    [[ -z "$font" ]] && { gum style --faint "Cancelled."; exit 0; }
    [[ "$font" == "None (template default)" ]] && { DOCX_FONT=""; return; }

    DOCX_FONT="$font"
    info "DOCX prose font: ${DOCX_FONT}"
}

# -----------------------------------------------------------------------------
# Pick an installed monospace font for DOCX code (auto, like detect_mono_font
# for PDF). Falls back to Courier New, which ships broadly.
# -----------------------------------------------------------------------------

detect_docx_mono() {
    DOCX_MONO=""
    local candidates=("Menlo" "DejaVu Sans Mono" "Monaco" "Consolas" "Courier New")
    local f
    for f in "${candidates[@]}"; do
        if font_installed "$f"; then
            DOCX_MONO="$f"
            break
        fi
    done
    [[ -z "$DOCX_MONO" ]] && DOCX_MONO="Courier New"
    info "DOCX monospace font: ${DOCX_MONO}"
}

# -----------------------------------------------------------------------------
# Collision-safe output filename
# Flattens path separators to underscores when a name collision is detected.
#
# Arguments:
#   $1 — relative source path (e.g. "docs/guides/index.md")
#   $2 — output directory
#   $3 — output extension (e.g. "pdf")
#
# Sets OUTPUT_FILE to the resolved path.
# -----------------------------------------------------------------------------

resolve_output_path() {
    local source_path="$1"
    local out_dir="$2"
    local ext="$3"

    local base
    base=$(basename "$source_path" ".${SOURCE_FORMAT}")

    local candidate="${out_dir}/${base}.${ext}"

    if [[ ! -f "$candidate" ]]; then
        OUTPUT_FILE="$candidate"
        return
    fi

    # Collision — check if another source file would also produce this name
    local flat_name
    flat_name=$(echo "${source_path%.${SOURCE_FORMAT}}" | tr '/' '_')
    local flat_candidate="${out_dir}/${flat_name}.${ext}"

    if [[ ! -f "$flat_candidate" ]]; then
        info "Name collision for '${base}.${ext}' — using path-derived name: ${flat_name}.${ext}"
        OUTPUT_FILE="$flat_candidate"
        return
    fi

    # Flat name also exists — prompt user
    gum style \
        --foreground "$YELLOW" --border-foreground "$YELLOW" --border rounded \
        --width 60 --margin "0 2" --padding "0 2" \
        "Output file already exists: ${flat_candidate}"

    if gum confirm "Overwrite?"; then
        OUTPUT_FILE="$flat_candidate"
    else
        local timestamp
        timestamp=$(date +%s)
        OUTPUT_FILE="${out_dir}/${flat_name}_${timestamp}.${ext}"
        info "Saving as: $(basename "$OUTPUT_FILE")"
    fi
}

# -----------------------------------------------------------------------------
# Run conversion: md → pdf (single file)
# $1 — file to convert (may be a .tmp.md if title page is active)
# $2 — (optional) original source path, used for output filename resolution
# -----------------------------------------------------------------------------

convert_md_to_pdf() {
    local input_file="$1"
    local name_source="${2:-$input_file}"

    if [[ -z "$PDF_ENGINE" ]]; then
        warn "PDF_ENGINE is not set — skipping: ${input_file}"
        return 1
    fi

    resolve_output_path "$name_source" "$OUTPUT_DIR" "pdf"
    local output_file="$OUTPUT_FILE"

    local pandoc_args=(
        "$input_file"
        -o "$output_file"
        --pdf-engine="$PDF_ENGINE"
        -H "$HEADER_TEX"
        -H "$MONOFONT_TEX"
        -V colorlinks=true
        -V linkcolor=blue
        -V urlcolor=blue
        -V citecolor=blue
    )

    # Add optional assets only when present, so a missing bundle degrades
    # gracefully instead of failing the whole conversion.
    [[ -f "${FCC_DIR}/pdf/p10k.theme" ]] && \
        pandoc_args+=(--syntax-highlighting="${FCC_DIR}/pdf/p10k.theme")
    local lf lf_path
    for lf in widen-tables.lua render-mermaid.lua pagebreak.lua; do
        lf_path="$(resolve_lua_filter "$lf")"
        [[ -n "$lf_path" ]] && pandoc_args+=(--lua-filter="$lf_path")
    done

    # PDF_FONT controls prose (mainfont) only — monofont is handled by monofont.tex
    if [[ -n "$PDF_FONT" ]]; then
        pandoc_args+=(-V "mainfont=${PDF_FONT}")
    fi

    # Table of contents (opt-in) — pandoc builds it from the headers. Skipped
    # when a title page already emitted \tableofcontents after the cover (else
    # pandoc would ALSO place one above the title page).
    if [[ "$USE_TOC" == "true" && "$TOC_PLACED_IN_TITLE" != "true" ]]; then
        pandoc_args+=(--toc --toc-depth="$TOC_DEPTH" -V "toc-title=${TOC_TITLE}")
    fi

    #gum spin --spinner dot --title "Converting $(basename "$input_file") → $(basename "$output_file") ..." -- \
    #    pandoc "${pandoc_args[@]}"

    # comment 2 lines above for debug
    # uncomment line below for debug
    pandoc "${pandoc_args[@]}" 2>&1
    local rc=$?

    if [[ $rc -eq 0 ]]; then
        success "$(basename "$output_file") ✓"
        open_file "$output_file"
        return 0        # don't let open_file's exit status mask success
    else
        warn "Failed to convert: ${input_file}"
        return 1
    fi
}

# =============================================================================
# FORMAT-PAIR: Markdown → DOCX
# =============================================================================

# -----------------------------------------------------------------------------
# Dependency check: md → docx
# -----------------------------------------------------------------------------

check_deps_md_docx() {
    header "Checking Dependencies"

    if ! command -v pandoc &>/dev/null; then
        error_exit "pandoc is not installed.
Install it from: https://pandoc.org/installing.html
  macOS:  brew install pandoc
  Linux:  sudo apt install pandoc  /  sudo dnf install pandoc"
    fi
    local _pandoc_ver
    _pandoc_ver=$(pandoc --version | head -1 | awk '{print $2}')
    success "pandoc ${_pandoc_ver} found."
}

# -----------------------------------------------------------------------------
# Letterhead config + token resolution
# Read a value from .fcc/docx/config (key=value). Empty if absent.
# -----------------------------------------------------------------------------

docx_cfg() {
    [[ -f "$DOCX_CONFIG" ]] || return 0
    # `|| true`: a missing key makes grep exit non-zero which, under pipefail,
    # would fail the whole substitution and trip set -e in the caller.
    { grep -E "^${1}=" "$DOCX_CONFIG" | head -1 | sed "s/^${1}=//" | tr -d '\r'; } || true
}

# Resolve the letterhead tokens once per run: config file → prompt for anything
# still missing. Title is per-document (from the file) and date defaults to
# today, so we only prompt for author / classification / version here. A
# per-file YAML front-matter override is applied later, at stamp time.
resolve_letterhead() {
    # Values already set (e.g. by engine flags) win; otherwise fall back to the
    # config file. `:-` keeps a flag-provided value from being overwritten.
    DOCX_AUTHOR="${DOCX_AUTHOR:-$(docx_cfg author)}"
    DOCX_CLASSIFICATION="${DOCX_CLASSIFICATION:-$(docx_cfg classification)}"
    DOCX_VERSION="${DOCX_VERSION:-$(docx_cfg version)}"
    DOCX_DATE="${DOCX_DATE:-$(docx_cfg date)}"
    [[ "$DOCX_DATE" == "auto" ]] && DOCX_DATE=""   # empty → today, stamped later

    # Interactive only: prompt for anything still unset. Engine mode leaves
    # unset fields empty (guardrail: prompt nothing).
    if [[ "$NONINTERACTIVE" != true ]]; then
        if [[ -z "$DOCX_AUTHOR" ]]; then
            DOCX_AUTHOR=$(gum input --header "Author (header 'Created By'), blank to omit:" \
                --placeholder "e.g. Platform Team") || true
        fi
        if [[ -z "$DOCX_CLASSIFICATION" ]]; then
            DOCX_CLASSIFICATION=$(gum input --header "Classification (footer), blank to omit:" \
                --placeholder "e.g. INTERNAL USE ONLY") || true
        fi
        if [[ -z "$DOCX_VERSION" ]]; then
            DOCX_VERSION=$(gum input --header "Version (footer/header), blank to omit:" \
                --placeholder "e.g. v1.0") || true
        fi
    fi

    # Header logo: flag/config → validate → (interactive) prompt if unset.
    DOCX_LOGO="${DOCX_LOGO:-$(docx_cfg logo)}"
    DOCX_LOGO="${DOCX_LOGO/#\~/$HOME}"
    if [[ -n "$DOCX_LOGO" && ! -f "$DOCX_LOGO" ]]; then
        warn "Configured logo not found: ${DOCX_LOGO}"
        DOCX_LOGO=""
    fi
    if [[ "$NONINTERACTIVE" != true && -z "$DOCX_LOGO" ]]; then
        local p
        p=$(gum input --header "Header logo image path (blank = no logo):" \
            --placeholder "/path/to/logo.png") || true
        p="${p/#\~/$HOME}"
        if [[ -n "$p" && -f "$p" ]]; then
            DOCX_LOGO="$p"
        elif [[ -n "$p" ]]; then
            warn "Logo not found: ${p} — skipping."
        fi
    fi

    if [[ "$NONINTERACTIVE" == true ]]; then
        enote "Letterhead — author='${DOCX_AUTHOR}' classification='${DOCX_CLASSIFICATION}' version='${DOCX_VERSION}' logo='${DOCX_LOGO:-none}'"
    else
        info "Letterhead — author='${DOCX_AUTHOR}' classification='${DOCX_CLASSIFICATION}' version='${DOCX_VERSION}' logo='${DOCX_LOGO:-none}'"
        # Interactive: resolve title-page chrome by prompting. In engine mode the
        # TP_* globals come from flags, so we must not reset/prompt here.
        resolve_title_page_chrome docx
    fi
}

# Read a boolean-ish config key from .fcc/docx/config → prints "true"/"false".
# Recognised true: true/yes/1/on/show; false: false/no/0/off/hide. Anything else
# (incl. an absent key) → prompt via gum confirm (Yes = true), matching how the
# other letterhead keys fall back to the TUI when not configured.
resolve_bool_cfg() {
    local key="$1" prompt="$2" val
    val="$(docx_cfg "$key")"
    case "$(printf '%s' "$val" | tr '[:upper:]' '[:lower:]')" in
        true|yes|1|on|show)  printf 'true';  return ;;
        false|no|0|off|hide) printf 'false'; return ;;
    esac
    # Unset/unrecognised: engine mode defaults to "show" (no prompt); the UI asks.
    [[ "$NONINTERACTIVE" == true ]] && { printf 'true'; return; }
    if gum confirm "$prompt"; then printf 'true'; else printf 'false'; fi
}

# Resolve which letterhead chrome appears on the title page (page 1). Only
# meaningful when a title page is enabled.
#   mode=docx — header + footer + page number (page number nested under footer:
#               no footer ⇒ no page number).
#   mode=pdf  — the PDF has no running header/footer, only a page number, so
#               that is the only thing to (optionally) suppress.
# Sets TP_HEADER / TP_FOOTER / TP_PAGENUM (true/false).
resolve_title_page_chrome() {
    local mode="$1"
    TP_HEADER=true; TP_FOOTER=true; TP_PAGENUM=true
    [[ "$USE_TITLE_PAGE" == "true" ]] || return 0

    if [[ "$mode" == "docx" ]]; then
        TP_HEADER=$(resolve_bool_cfg title_page_header "Show the header on the title page?")
        TP_FOOTER=$(resolve_bool_cfg title_page_footer "Show the footer on the title page?")
        if [[ "$TP_FOOTER" == "true" ]]; then
            TP_PAGENUM=$(resolve_bool_cfg title_page_page_number "Show the page number on the title page?")
        else
            TP_PAGENUM=false   # nested: no footer → no page number
        fi
    else
        TP_PAGENUM=$(resolve_bool_cfg title_page_page_number "Show the page number on the title page?")
    fi
    info "Title-page chrome — header=${TP_HEADER} footer=${TP_FOOTER} page#=${TP_PAGENUM}"
}

# -----------------------------------------------------------------------------
# Reference doc selection for md → docx
# Scans for .docx files up to SEARCH_DEPTH, offers a manual path escape hatch.
# Sets DOCX_REFERENCE_DOC (empty string = no reference doc).
# -----------------------------------------------------------------------------

select_docx_reference_doc() {
    DOCX_REFERENCE_DOC=""
    DOCX_LETTERHEAD=false

    # Make the built-in templates available (shaded code + aligned TOC; the
    # letterhead one adds header/footer/page numbers).
    local have_default=false
    if ensure_fcc_docx_assets; then
        have_default=true
    fi

    local choice
    choice=$(gum choose \
        "Built-in — letterhead (header + footer + page numbers)" \
        "Built-in — plain (no header/footer)" \
        "Custom template (.docx)" \
        "None (pandoc default)" \
        --header "DOCX styling / reference template:") || true
    [[ -z "$choice" ]] && { gum style --faint "Cancelled."; return 0; }

    case "$choice" in
        "Built-in — letterhead"*)
            if [[ "$have_default" == true && -f "$DOCX_DEFAULT_REFERENCE" ]]; then
                DOCX_REFERENCE_DOC="$DOCX_DEFAULT_REFERENCE"
                DOCX_LETTERHEAD=true
                resolve_letterhead
                info "Using built-in letterhead reference."
            else
                warn "Letterhead reference unavailable — using pandoc defaults."
            fi
            return ;;
        "Built-in — plain"*)
            if [[ -f "$DOCX_PLAIN_REFERENCE" ]]; then
                DOCX_REFERENCE_DOC="$DOCX_PLAIN_REFERENCE"
                info "Using built-in plain reference."
            elif [[ "$have_default" == true ]]; then
                DOCX_REFERENCE_DOC="$DOCX_DEFAULT_REFERENCE"
                warn "Plain reference missing — falling back to the letterhead one (header/footer will show)."
            else
                warn "Built-in reference unavailable — using pandoc defaults."
            fi
            return ;;
        "None (pandoc default)")
            info "No reference doc — pandoc defaults."
            return ;;
        "Custom template (.docx)")
            : ;;  # fall through to the scan/pick below
    esac

    info "Scanning for .docx files (depth ${SEARCH_DEPTH})..."

    local found
    found=$(find . -maxdepth "$SEARCH_DEPTH" -name "*.docx" \
        ! -path "*/node_modules/*" \
        ! -path "*/.git/*" \
        ! -path "*/.astro/*" \
        ! -path "*/dist/*" \
        ! -path "*/${FCC_DIR}/*" \
        ! -path "*/output/*" \
        | sed 's|^\./||' \
        | sort)

    local choices=()
    if [[ -n "$found" ]]; then
        while IFS= read -r f; do
            choices+=("$f")
        done <<< "$found"
    fi
    choices+=("Enter path manually")

    local file_count="${#choices[@]}"
    local list_height=$(( file_count < 15 ? file_count + 2 : 17 ))

    local selected
    selected=$(printf '%s\n' "${choices[@]}" | gum choose \
        --height "$list_height" \
        --header "Select reference .docx — or enter path manually:") || true

    [[ -z "$selected" ]] && { gum style --faint "Cancelled."; exit 0; }

    if [[ "$selected" == "Enter path manually" ]]; then
        local manual
        manual=$(gum input \
            --placeholder "/path/to/template.docx" \
            --header "Enter path to reference .docx:") || true

        [[ -z "$manual" ]] && { gum style --faint "Cancelled."; exit 0; }

        if [[ ! -f "$manual" ]]; then
            error_exit "File not found: ${manual}"
        fi
        selected="$manual"
    fi

    DOCX_REFERENCE_DOC="$selected"
    info "Reference doc: ${DOCX_REFERENCE_DOC}"
}

# -----------------------------------------------------------------------------
# Run conversion: md → docx (single file)
# $1 — file to convert (may be a .tmp.md if title page is active)
# $2 — (optional) original source path, used for output filename resolution
# -----------------------------------------------------------------------------

convert_md_to_docx() {
    local input_file="$1"
    local name_source="${2:-$input_file}"

    resolve_output_path "$name_source" "$OUTPUT_DIR" "docx"
    local output_file="$OUTPUT_FILE"

    local pandoc_args=(
        "$input_file"
        -o "$output_file"
        --from=markdown
        --to=docx
    )

    # DOCX filters — resolved from the DOCX asset tree (.fcc/docx/), kept fully
    # separate from the PDF assets. Falls back to the bundle so a missing copy
    # never silently drops \newpage from the output.
    local lf lf_path
    for lf in pagebreak.lua render-mermaid.lua; do
        lf_path="$(resolve_docx_asset "$lf")"
        [[ -n "$lf_path" ]] && pandoc_args+=(--lua-filter="$lf_path")
    done

    # Table of contents (opt-in) — Word builds a native TOC field. Skipped when
    # a title page already emitted the TOC after the cover (else it'd double up
    # at the top of the document).
    if [[ "$USE_TOC" == "true" && "$TOC_PLACED_IN_TITLE" != "true" ]]; then
        pandoc_args+=(--toc --toc-depth="$TOC_DEPTH")
    fi

    if [[ -n "$DOCX_REFERENCE_DOC" ]]; then
        pandoc_args+=(--reference-doc="$DOCX_REFERENCE_DOC")
    fi

    # The p10k syntax theme for code — with either built-in reference (whose code
    # styles suit it). A custom template keeps its own code styling.
    if is_builtin_docx_ref; then
        local theme_path
        theme_path="$(resolve_docx_asset "p10k.theme")"
        [[ -n "$theme_path" ]] && pandoc_args+=(--syntax-highlighting="$theme_path")
    fi

    gum spin --spinner dot --title "Converting $(basename "$input_file") → $(basename "$output_file") ..." -- \
        pandoc "${pandoc_args[@]}"
    local rc=$?

    if [[ $rc -eq 0 ]]; then
        fold_docx_pagebreaks "$output_file"
        apply_docx_fonts "$output_file"
        # Explicit table banding — only with a built-in reference (a custom
        # template owns its own table styling).
        is_builtin_docx_ref && shade_docx_tables "$output_file"
        # Layout: page size + image fit/centering (built-in refs only).
        is_builtin_docx_ref && layout_docx "$output_file"
        # Letterhead: fill the header/footer tokens (+ core props) per document.
        [[ "$DOCX_LETTERHEAD" == true ]] && stamp_docx_letterhead "$output_file" "$name_source"
        success "$(basename "$output_file") ✓"
        open_file "$output_file"
        return 0        # don't let open_file's exit status mask success
    else
        warn "Failed to convert: ${input_file}"
        return 1
    fi
}

# =============================================================================
# FORMAT-PAIR: DOCX → Markdown
# =============================================================================

# -----------------------------------------------------------------------------
# Dependency check: docx → md
# -----------------------------------------------------------------------------

check_deps_docx_md() {
    header "Checking Dependencies"

    if ! command -v pandoc &>/dev/null; then
        error_exit "pandoc is not installed.
Install it from: https://pandoc.org/installing.html
  macOS:  brew install pandoc
  Linux:  sudo apt install pandoc  /  sudo dnf install pandoc"
    fi
    local _pandoc_ver
    _pandoc_ver=$(pandoc --version | head -1 | awk '{print $2}')
    success "pandoc ${_pandoc_ver} found."
}

# -----------------------------------------------------------------------------
# Markdown variant selection for docx → md
# -----------------------------------------------------------------------------

select_md_variant() {
    local variant
    variant=$(gum choose \
        "gfm (GitHub-Flavored Markdown)" \
        "markdown (Pandoc extended)" \
        "commonmark" \
        --header "Select Markdown output variant:") || true

    [[ -z "$variant" ]] && { gum style --faint "Cancelled."; exit 0; }

    # Extract the short token before the first space
    MD_VARIANT="${variant%% *}"
    info "Markdown variant: ${MD_VARIANT}"
}

# -----------------------------------------------------------------------------
# Run conversion: docx → md (single file)
# Media extracted to ./output/media/<source_basename>/
# -----------------------------------------------------------------------------

convert_docx_to_md() {
    local input_file="$1"

    resolve_output_path "$input_file" "$OUTPUT_DIR" "md"
    local output_file="$OUTPUT_FILE"

    # Derive a per-file media directory from the output basename (no extension)
    local media_base
    media_base=$(basename "$output_file" ".md")
    local media_dir="${OUTPUT_DIR}/media/${media_base}"

    local pandoc_args=(
        "$input_file"
        -o "$output_file"
        --from=docx
        --to="$MD_VARIANT"
        --extract-media="$media_dir"
    )

    gum spin --spinner dot --title "Converting $(basename "$input_file") → $(basename "$output_file") ..." -- \
        pandoc "${pandoc_args[@]}"

    if [[ $? -eq 0 ]]; then
        success "$(basename "$output_file") ✓"
        if [[ -d "$media_dir" ]]; then
            local media_count
            media_count=$(find "$media_dir" -type f | wc -l | tr -d ' ')
            if (( media_count > 0 )); then
                info "Extracted ${media_count} media file(s) → ${media_dir}"
            fi
        fi
        open_file "$output_file"
    else
        warn "Failed to convert: ${input_file}"
    fi
}

# =============================================================================
# SUBSTITUTIONS
# Optional character substitution pass — applies to all md→* conversion pairs.
#
# Replaces typographic and arrow characters that may not survive the LaTeX/
# DOCX pipeline cleanly:
#   →   U+2192  →  ->
#   —   U+2014  →  -
#   ✓   U+2713  →  (removed)
#
# Substitutions are applied ONLY outside fenced code blocks (``` ... ```).
# Box-drawing characters (├ └ ─ etc.) are left untouched — they are
# intentionally rendered in monospace and handled by the monofont.
#
# Opt-in: user is prompted before conversion begins.
# =============================================================================

# -----------------------------------------------------------------------------
# Prompt user: apply character substitutions?
# Only offered for md→* pairs.
# Sets APPLY_SUBSTITUTIONS=true/false.
# -----------------------------------------------------------------------------

select_apply_substitutions() {
    [[ "$SOURCE_FORMAT" != "md" ]] && return

    if gum confirm "Apply character substitutions? (→ to ->, — to -, removes ✓)"; then
        APPLY_SUBSTITUTIONS=true
        info "Character substitutions enabled."
    else
        APPLY_SUBSTITUTIONS=false
    fi
}

# -----------------------------------------------------------------------------
# Apply character substitutions to a temp file in-place.
# Operates only outside fenced code blocks.
#
# Arguments:
#   $1 — path to the .tmp.md file to modify in-place
# -----------------------------------------------------------------------------

apply_substitutions() {
    local tmp_file="$1"

    # BSD sed does not support \xNN hex escapes in match patterns (GNU only).
    # $'...' ANSI-C quoting produces literal UTF-8 bytes in bash, which then
    # expand into the sed -e double-quoted expressions correctly.
    # /^```/,/^```/ range skips fenced code blocks; ! inverts to prose-only.
    local arrow=$'\xe2\x86\x92'  # →  U+2192
    local mdash=$'\xe2\x80\x94'  # —  U+2014
    local check=$'\xe2\x9c\x93'  # ✓  U+2713

    sed -e "/^\`\`\`/,/^\`\`\`/!s/${arrow}/->/g" \
        -e "/^\`\`\`/,/^\`\`\`/!s/${mdash}/-/g" \
        -e "/^\`\`\`/,/^\`\`\`/!s/${check}//g" \
        "$tmp_file" > "${tmp_file}.sub" && mv "${tmp_file}.sub" "$tmp_file"
}

# =============================================================================
# RULE STRIPPING
# Optional thematic break removal — applies to all md→* conversion pairs.
#
# Removes lines matching ^---[[:space:]]*$ (thematic breaks / horizontal rules)
# from prose, while preserving:
#   - YAML front matter (--- block starting on line 1)
#   - Fenced code blocks (``` ... ```)
# =============================================================================

select_strip_rules() {
    [[ "$SOURCE_FORMAT" != "md" ]] && return

    if gum confirm "Strip horizontal rules (---) from output?"; then
        STRIP_RULES=true
        info "Horizontal rule stripping enabled."
    else
        STRIP_RULES=false
    fi
}

apply_strip_rules() {
    local tmp_file="$1"

    awk '
        NR == 1 && /^---[[:space:]]*$/ { in_fm = 1; print; next }
        in_fm && /^---[[:space:]]*$/ { in_fm = 0; print; next }
        in_fm { print; next }
        /^```/ { in_code = !in_code; print; next }
        in_code { print; next }
        /^---[[:space:]]*$/ { next }
        { print }
    ' "$tmp_file" > "${tmp_file}.strip" && mv "${tmp_file}.strip" "$tmp_file"
}

# =============================================================================
# WIKILINK UNWRAP
# [[Target|Label]] -> Label ; [[Target#anchor]] -> Target. Cross-document
# wikilinks can't resolve inside a single output file, so we drop to plain text.
# Skips fenced code blocks. Applies to all md→* pairs (helps PDF + DOCX).
# =============================================================================

select_unwrap_wikilinks() {
    [[ "$SOURCE_FORMAT" != "md" ]] && return
    if gum confirm "Unwrap [[wikilinks]] to plain text?"; then
        UNWRAP_WIKILINKS=true
        info "Wikilink unwrapping enabled."
    else
        UNWRAP_WIKILINKS=false
    fi
}

apply_wikilink_unwrap() {
    local tmp_file="$1"
    # Two passes (piped form first, then bare); range skips fenced code blocks.
    sed -E \
        -e '/^```/,/^```/!s/\[\[[^]|]*\|([^]]+)\]\]/\1/g' \
        -e '/^```/,/^```/!s/\[\[([^]#|]+)[^]]*\]\]/\1/g' \
        "$tmp_file" > "${tmp_file}.wl" && mv "${tmp_file}.wl" "$tmp_file"
}

# =============================================================================
# SVG RASTERIZATION
# Local .svg images -> PNG (via rsvg-convert, faithful vector rasterization),
# so pandoc can embed them for both DOCX and PDF (xelatex can't embed SVG).
# Remote (http) SVGs are left untouched. Applies to all md→* pairs.
# =============================================================================

select_svg_raster() {
    [[ "$SOURCE_FORMAT" != "md" ]] && return
    if gum confirm "Rasterize local .svg images to PNG (needs rsvg-convert)?"; then
        RASTER_SVG=true
        info "SVG rasterization enabled."
    else
        RASTER_SVG=false
    fi
}

ensure_rsvg() {
    command -v rsvg-convert &>/dev/null && return 0
    warn "rsvg-convert (librsvg) is not installed."
    gum confirm "Install librsvg now?" || return 1
    case "$(uname -s)" in
        Darwin) command -v brew &>/dev/null && brew install librsvg || return 1 ;;
        Linux)
            if command -v apt-get &>/dev/null && sudo -n true 2>/dev/null; then
                sudo apt-get install -y librsvg2-bin
            elif command -v dnf &>/dev/null && sudo -n true 2>/dev/null; then
                sudo dnf install -y librsvg2-tools
            else
                return 1
            fi ;;
        *) return 1 ;;
    esac
    command -v rsvg-convert &>/dev/null
}

# Ensure an image is embeddable by xelatex (pdf/png/jpg/jpeg/eps). Formats it
# can't size (gif, webp, tiff, bmp, svg…) are converted to PNG in OUTPUT_DIR
# using whatever raster tool is available (rsvg for svg; sips on macOS; else
# ImageMagick). Prints a usable path, or exits non-zero if none can be produced
# (the caller then skips the image instead of failing the whole PDF).
ensure_pdf_image() {
    local src="$1" ext png
    ext="$(printf '%s' "${src##*.}" | tr '[:upper:]' '[:lower:]')"
    case "$ext" in
        pdf|png|jpg|jpeg|eps) printf '%s' "$src"; return 0 ;;
    esac
    mkdir -p "$OUTPUT_DIR"
    png="${OUTPUT_DIR}/title_img_$(basename "${src%.*}").png"
    if [[ "$ext" == "svg" ]]; then
        ensure_rsvg && rsvg-convert --zoom 2 -o "$png" "$src" 2>/dev/null \
            && { printf '%s' "$png"; return 0; }
    elif command -v sips &>/dev/null; then
        sips -s format png "$src" --out "$png" &>/dev/null && { printf '%s' "$png"; return 0; }
    elif command -v magick &>/dev/null; then
        magick "$src" "$png" 2>/dev/null && { printf '%s' "$png"; return 0; }
    elif command -v convert &>/dev/null; then
        convert "$src" "$png" 2>/dev/null && { printf '%s' "$png"; return 0; }
    fi
    return 1
}

apply_svg_raster() {
    local tmp_file="$1" srcdir="$2"
    # Any local .svg image refs? (skip if none)
    grep -qiE '!\[[^]]*\]\([^)]*\.svg' "$tmp_file" || return 0
    ensure_rsvg || { warn "rsvg-convert unavailable — leaving .svg images as-is."; return 0; }

    local media="${OUTPUT_DIR}/media"; mkdir -p "$media"
    local svgs
    svgs=$(grep -oiE '!\[[^]]*\]\([^)]*\.svg\)' "$tmp_file" \
        | sed -E 's/^!\[[^]]*\]\(([^)]+)\).*/\1/' | sort -u)

    local svg abs png i=0
    while IFS= read -r svg; do
        [[ -z "$svg" ]] && continue
        [[ "$svg" =~ ^https?:// ]] && continue                 # leave remote SVGs
        local expanded="${svg/#\~/$HOME}"
        if [[ "$expanded" = /* ]]; then abs="$expanded"; else abs="${srcdir}/${expanded}"; fi
        abs="$(cd "$(dirname "$abs")" 2>/dev/null && pwd)/$(basename "$abs")"
        [[ -f "$abs" ]] || { warn "SVG not found: ${svg}"; continue; }
        i=$(( i + 1 ))
        png="${media}/svg_${i}_$(basename "${abs%.svg}").png"
        if rsvg-convert --zoom 2 -o "$png" "$abs" 2>/dev/null; then
            # rewrite this svg path -> the PNG (absolute), everywhere it appears
            local esc_svg="${svg//&/\\&}"
            sed -i.bak "s|(${svg})|(${png})|g" "$tmp_file" && rm -f "${tmp_file}.bak"
        else
            warn "Failed to rasterize: ${svg}"
        fi
    done <<< "$svgs"
}

# =============================================================================
# CONCAT — combine several selected md files into ONE document
# Offered only when >1 md file is selected and the target is a single document
# (pdf/docx). The first "# H1" becomes the document Title; page break optional.
# =============================================================================

select_concat() {
    CONCAT=false
    [[ "$SOURCE_FORMAT" != "md" ]] && return
    [[ "$OUTPUT_FORMAT" != "pdf" && "$OUTPUT_FORMAT" != "docx" ]] && return
    local n; n=$(echo "$SELECTED_FILES" | grep -c .)
    (( n < 2 )) && return

    if gum confirm "Combine the ${n} selected files into ONE document?"; then
        CONCAT=true
        if gum confirm "Insert a page break between files?"; then
            CONCAT_PAGEBREAK=true
        else
            CONCAT_PAGEBREAK=false
        fi
        info "Concatenation enabled — ${n} files → one document."
    fi
}

# =============================================================================
# DOCX PAGE SIZE — only for the built-in references (a custom template owns its
# own page geometry). The layout post-processor rewrites pgSz in the output.
# =============================================================================

select_docx_page_size() {
    is_builtin_docx_ref || return 0
    local p
    p=$(gum choose "A4" "Letter" --header "Page size:") || true
    case "$p" in
        Letter) DOCX_PAGE_SIZE="letter" ;;
        *)      DOCX_PAGE_SIZE="a4" ;;
    esac
    info "Page size: ${DOCX_PAGE_SIZE}"
}

# =============================================================================
# TABLE OF CONTENTS
# Optional index page built from the document's markdown headers.
# Applies to md→pdf and md→docx (pandoc's native --toc). Not meaningful for
# docx→md, so it is only offered when the source is markdown.
# =============================================================================

select_toc() {
    [[ "$SOURCE_FORMAT" != "md" ]] && return
    [[ "$OUTPUT_FORMAT" != "pdf" && "$OUTPUT_FORMAT" != "docx" ]] && return

    if ! gum confirm "Add a table of contents (index) built from headers?"; then
        USE_TOC=false
        return
    fi

    USE_TOC=true

    local raw
    raw=$(gum input \
        --placeholder "${DEFAULT_DEPTH}" \
        --header "Header depth to include in the TOC (1-6, default ${DEFAULT_DEPTH}):") || true

    local depth="${raw:-${DEFAULT_DEPTH}}"
    if ! [[ "$depth" =~ ^[0-9]+$ ]] || (( depth < 1 || depth > 6 )); then
        warn "Invalid TOC depth '${depth}', using ${DEFAULT_DEPTH}."
        depth="${DEFAULT_DEPTH}"
    fi
    TOC_DEPTH="$depth"
    info "Table of contents enabled (depth ${TOC_DEPTH})."
}

# =============================================================================
# TITLE PAGE
# Optional title page injection — applies to all md→* conversion pairs.
#
# Template resolution order (per source file):
#   1. .fcc/title-pages/<flattened_source_path>.yaml  (specific)
#   2. .fcc/title-pages/default.yaml                  (fallback)
#   3. No match → skip title page for that file, emit a warning.
#
# YAML schema:
#   template: relative/path/to/template.md   # relative to the YAML file
#   image:    relative/path/to/logo.png      # relative to the YAML file
#
# Template .md placeholders:
#   {{TITLE}}   — replaced with the extracted document title
#   {{IMAGE}}   — replaced with a markdown image tag: ![](absolute/path)
#
# Title extraction priority:
#   1. YAML front matter  ---\ntitle: ...\n---
#   2. First # H1 line
# =============================================================================

# -----------------------------------------------------------------------------
# Prompt user: enable title page?
# Only offered for md→* pairs (not meaningful for docx→md).
# Sets USE_TITLE_PAGE=true/false.
# -----------------------------------------------------------------------------

select_title_page() {
    # Only relevant when source is markdown
    [[ "$SOURCE_FORMAT" != "md" ]] && return

    if ! gum confirm "Add a title page to the output?"; then
        USE_TITLE_PAGE=false
        return
    fi

    USE_TITLE_PAGE=true

    # Seed the bundled default template into the working copy if absent, so a
    # fresh project isn't left with no templates.
    ensure_fcc_title_pages

    # Warn if no templates exist at all — non-fatal, per-file resolution will
    # emit its own warning and skip gracefully.
    if [[ ! -d "$TITLE_PAGES_DIR" ]] || \
       [[ -z "$(find "$TITLE_PAGES_DIR" -maxdepth 1 -name '*.yaml' 2>/dev/null)" ]]; then
        warn "No templates found in ${TITLE_PAGES_DIR}/. Create at least default.yaml to use title pages."
    else
        local count
        count=$(find "$TITLE_PAGES_DIR" -maxdepth 1 -name '*.yaml' | wc -l | tr -d ' ')
        info "Title page enabled — ${count} template(s) available in ${TITLE_PAGES_DIR}/."
    fi
}

# -----------------------------------------------------------------------------
# Resolve which YAML template applies to a given source file.
#
# Arguments:
#   $1 — relative source path (e.g. "docs/rabbitmq-guide.md")
#
# Outputs (stdout): path to resolved YAML, or empty string if none found.
# -----------------------------------------------------------------------------

resolve_title_page_yaml() {
    local source_path="$1"

    # Flatten: strip extension, replace / with _
    local flat
    flat=$(echo "${source_path%.md}" | tr '/' '_')

    local specific="${TITLE_PAGES_DIR}/${flat}.yaml"
    local default="${TITLE_PAGES_DIR}/default.yaml"

    if [[ -f "$specific" ]]; then
        echo "$specific"
    elif [[ -f "$default" ]]; then
        echo "$default"
    else
        echo ""
    fi
}

# -----------------------------------------------------------------------------
# Parse a YAML field (value after "key: ") from a file.
# Intentionally minimal — no external YAML parser required.
# Only handles simple scalar values on a single line.
#
# Arguments:
#   $1 — YAML file path
#   $2 — field name (e.g. "template" or "image")
#
# Outputs (stdout): trimmed value, or empty string if not found.
# -----------------------------------------------------------------------------

parse_yaml_field() {
    local file="$1"
    local field="$2"
    # `|| true`: a missing key means grep exits non-zero, which under
    # `set -euo pipefail` would abort the caller's `x=$(parse_yaml_field …)`.
    # A missing field is a normal "unset" here, not an error.
    grep -E "^${field}:" "$file" | head -1 | sed "s/^${field}:[[:space:]]*//" | tr -d '\r' || true
}

# -----------------------------------------------------------------------------
# Extract the document title from a markdown file.
# Priority: YAML front matter title: field → first # H1 line.
#
# Arguments:
#   $1 — source markdown file path
#
# Outputs (stdout): title string, or empty if none found.
# -----------------------------------------------------------------------------

extract_title() {
    local file="$1"

    # Check for YAML front matter block (starts at line 1 with ---)
    if head -1 "$file" | grep -qE '^---[[:space:]]*$'; then
        local fm_title
        fm_title=$(awk '/^---/{if(NR==1){in_fm=1;next} else {exit}} in_fm && /^title:/{sub(/^title:[[:space:]]*/,""); print; exit}' "$file" \
                   | tr -d '"' | tr -d "'")
        if [[ -n "$fm_title" ]]; then
            echo "$fm_title"
            return
        fi
    fi

    # Fall back to first # H1 (|| true: no H1 is "no title", not a fatal error)
    grep -m1 '^# ' "$file" | sed 's/^# //' || true
}

# -----------------------------------------------------------------------------
# Strip the title from a markdown file.
# - Front matter: removes only the "title:" line, leaves other fields intact.
# - H1: removes the first "# Title" line.
# Writes result to stdout (caller redirects to temp file).
#
# Arguments:
#   $1 — source markdown file path
# -----------------------------------------------------------------------------

strip_title() {
    local file="$1"

    if head -1 "$file" | grep -qE '^---[[:space:]]*$'; then
        # Remove only the title: line from front matter
        sed '/^title:[[:space:]]*/d' "$file"
    else
        # Remove first # H1 line only
        awk 'found || !/^# /{print} !found && /^# /{found=1}' "$file"
    fi
}

# -----------------------------------------------------------------------------
# Prepend title page to a working temp file.
#
# Resolves YAML, reads template .md, substitutes {{TITLE}} and {{IMAGE}},
# strips the title from the source, and rewrites the temp file as:
#   [title page content] + [stripped source]
#
# Arguments:
#   $1 — original source markdown file path (for title extraction + YAML lookup)
#   $2 — path to the .tmp.md working copy (already created by run_conversions)
#
# On failure (no template, no title, missing files): warns and returns without
# modifying the temp file — conversion continues with the original content.
# -----------------------------------------------------------------------------

apply_title_page() {
    local source_path="$1"
    local tmp_file="$2"

    # --- Resolve YAML ---
    local yaml_file
    yaml_file=$(resolve_title_page_yaml "$source_path")

    if [[ -z "$yaml_file" ]]; then
        warn "No title page template for '${source_path}' — skipping title page."
        return
    fi

    local yaml_dir
    yaml_dir=$(dirname "$yaml_file")

    # --- Read YAML fields ---
    local template_rel image_rel
    template_rel=$(parse_yaml_field "$yaml_file" "template")
    image_rel=$(parse_yaml_field "$yaml_file" "image")

    if [[ -z "$template_rel" ]]; then
        warn "YAML '${yaml_file}' missing 'template:' field — skipping title page."
        return
    fi

    local template_path="${yaml_dir}/${template_rel}"
    if [[ ! -f "$template_path" ]]; then
        warn "Template file not found: '${template_path}' — skipping title page."
        return
    fi

    # --- Extract title ---
    local title
    title=$(extract_title "$source_path")
    if [[ -z "$title" ]]; then
        warn "No title found in '${source_path}' — skipping title page."
        return
    fi

    # --- Resolve image to absolute path (pandoc needs a reachable path) ---
    # Resolution order:
    #   1. Absolute path as-is
    #   2. Relative to yaml file directory
    #   3. Relative to PWD (project root where the script is invoked)
    local image_md=""
    local image_abs=""
    if [[ -n "$image_rel" ]]; then
        local image_expanded="${image_rel/#\~/$HOME}"
        local candidate
        if [[ "$image_expanded" = /* && -f "$image_expanded" ]]; then
            image_abs="$image_expanded"                          # absolute
        else
            candidate=$(realpath "${yaml_dir}/${image_expanded}" 2>/dev/null || echo "")
            if [[ -n "$candidate" && -f "$candidate" ]]; then
                image_abs="$candidate"                           # relative to yaml dir
            else
                candidate=$(realpath "${PWD}/${image_expanded}" 2>/dev/null || echo "")
                [[ -n "$candidate" && -f "$candidate" ]] && image_abs="$candidate"  # relative to PWD
            fi
        fi
        [[ -z "$image_abs" ]] && warn "Configured title-page image not found: '${image_rel}'."
    fi

    # Not configured or not found → prompt once (cached across files); blank = skip.
    if [[ -z "$image_abs" ]]; then
        if [[ "$TITLE_IMG_ASKED" != "true" ]]; then
            TITLE_IMG_ASKED=true
            local p
            p=$(gum input --header "Title-page image path (blank = none):" \
                --placeholder "/path/to/logo.png") || true
            p="${p/#\~/$HOME}"
            if [[ -n "$p" && -f "$p" ]]; then
                TITLE_IMG_CACHE="$p"
            elif [[ -n "$p" ]]; then
                warn "Image not found: ${p} — skipping."
            fi
        fi
        [[ -n "$TITLE_IMG_CACHE" ]] && image_abs="$TITLE_IMG_CACHE"
    fi

    # --- Build the title-page content (format-specific) ---
    # The LaTeX template (\includegraphics, \textbf, \begin{center}) renders in
    # PDF but is dropped wholesale by pandoc for DOCX, so DOCX gets a native
    # block instead: a markdown image (centered by the layout post-processor) +
    # a Title-styled heading + a page break — all first-class in .docx.
    local rendered
    if [[ "$OUTPUT_FORMAT" == "docx" ]]; then
        local img_line=""
        [[ -n "$image_abs" ]] && img_line="![](${image_abs}){width=35%}"
        rendered=$(printf '%s\n\n::: {custom-style="Title"}\n%s\n:::\n\n\\newpage\n' \
            "$img_line" "$title")
    else
        if [[ -n "$image_abs" ]]; then
            # xelatex only embeds pdf/png/jpg/eps — convert anything else (gif,
            # webp, svg, …) to PNG, or skip the image rather than fail the PDF.
            local pdf_img
            pdf_img="$(ensure_pdf_image "$image_abs")" || pdf_img=""
            if [[ -n "$pdf_img" ]]; then
                local image_path_escaped="${pdf_img//_/\\_}"
                image_md="\\includegraphics[width=0.3\\textwidth]{${image_path_escaped}}"
            else
                warn "Title-page image can't be embedded in PDF (unsupported format, no converter): ${image_abs} — skipping."
            fi
        fi
        # awk gsub eats single backslashes in replacement strings — double first
        local title_awk="${title//\\/\\\\}"
        local image_awk="${image_md//\\/\\\\}"
        rendered=$(awk \
            -v title="$title_awk" \
            -v image="$image_awk" \
            '{gsub(/\{\{TITLE\}\}/, title); gsub(/\{\{IMAGE\}\}/, image); print}' \
            "$template_path")
        # The PDF has no running header/footer — only a page number (plain
        # style). Suppress it on the title page via \thispagestyle{empty}.
        [[ "${TP_PAGENUM:-true}" == "false" ]] && rendered=$'\\thispagestyle{empty}\n'"$rendered"
    fi

    # Table of contents belongs AFTER the title page. pandoc's --toc always puts
    # it at the very top (above the cover), so when a title page is active we
    # emit the TOC right here and the converter skips --toc (TOC_PLACED_IN_TITLE).
    if [[ "$USE_TOC" == "true" ]]; then
        local _depth="${TOC_DEPTH:-3}"
        if [[ "$OUTPUT_FORMAT" == "docx" ]]; then
            local _toc
            _toc=$(printf '<w:sdt><w:sdtPr><w:docPartObj><w:docPartGallery w:val="Table of Contents"/><w:docPartUnique/></w:docPartObj></w:sdtPr><w:sdtContent><w:p><w:pPr><w:pStyle w:val="TOCHeading"/></w:pPr><w:r><w:t xml:space="preserve">Table of Contents</w:t></w:r></w:p><w:p><w:r><w:fldChar w:fldCharType="begin" w:dirty="true"/><w:instrText xml:space="preserve">TOC \\o "1-%s" \\h \\z \\u</w:instrText><w:fldChar w:fldCharType="separate"/><w:fldChar w:fldCharType="end"/></w:r></w:p></w:sdtContent></w:sdt>' "$_depth")
            rendered="${rendered}"$'\n\n```{=openxml}\n'"${_toc}"$'\n```\n\n\\newpage'
        else
            rendered="${rendered}"$'\n\\setcounter{tocdepth}{'"${_depth}"$'}\n\\tableofcontents\n\\newpage'
        fi
        TOC_PLACED_IN_TITLE=true
    fi

    # --- Rewrite tmp file: title page + stripped source ---
    # strip_title reads from tmp_file — substitutions and rule stripping have
    # already been applied to it. Reading source_path here would discard that work.
    local stripped
    stripped=$(strip_title "$tmp_file")

    {
        echo "$rendered"
        echo ""
        echo "$stripped"
    } > "$tmp_file"

    info "Title page applied (template: $(basename "$yaml_file")) → $(basename "$tmp_file")"
}

# Routes to the correct dep check + config + options + conversion
# based on SOURCE_FORMAT and OUTPUT_FORMAT.
# Add new format pairs here.
# =============================================================================

dispatch() {
    local pair="${SOURCE_FORMAT}→${OUTPUT_FORMAT}"

    case "$pair" in
        "md→pdf")
            check_deps_md_pdf
            ensure_pdf_config
            detect_mono_font
            select_pdf_engine
            select_pdf_font
            resolve_title_page_chrome pdf
            ;;
        "md→docx")
            check_deps_md_docx
            ensure_fcc_docx_assets   # DOCX-only asset tree; never touches .fcc/pdf/
            select_docx_reference_doc
            select_docx_page_size
            select_docx_font
            detect_docx_mono
            ;;
        "docx→md")
            check_deps_docx_md
            select_md_variant
            ;;
        *)
            error_exit "Conversion '${pair}' is not yet implemented."
            ;;
    esac
}

# =============================================================================
# CONVERT ALL SELECTED FILES
# =============================================================================

# Apply the opt-in md pre-passes to a working .tmp.md copy. `do_tp` gates the
# title page (skipped in concat mode — the letterhead Title covers it).
preprocess_md_tmp() {
    local tmp="$1" input="$2" do_tp="$3"
    TOC_PLACED_IN_TITLE=false
    [[ "$APPLY_SUBSTITUTIONS" == "true" ]] && apply_substitutions "$tmp"
    [[ "$STRIP_RULES" == "true" ]]         && apply_strip_rules "$tmp"
    [[ "$UNWRAP_WIKILINKS" == "true" ]]    && apply_wikilink_unwrap "$tmp"
    [[ "$RASTER_SVG" == "true" ]]          && apply_svg_raster "$tmp" "$(dirname "$input")"
    [[ "$do_tp" == "true" && "$USE_TITLE_PAGE" == "true" ]] && apply_title_page "$input" "$tmp"
    return 0
}

# Combine every selected md file into one working copy and convert it once.
# The first "# H1" becomes the document Title (via front matter); files are
# separated by an optional page break. Output is named after the first file.
run_concat() {
    local combined="${OUTPUT_DIR}/_concat.tmp.md"
    local first_input="" first_h1="" idx=0
    : > "$combined"

    while IFS= read -r input_file; do
        [[ -z "$input_file" ]] && continue
        idx=$(( idx + 1 ))
        [[ -z "$first_input" ]] && first_input="$input_file"

        local part="${OUTPUT_DIR}/_part.tmp.md"
        cp "$input_file" "$part"
        preprocess_md_tmp "$part" "$input_file" false

        if (( idx == 1 )); then
            first_h1="$(grep -m1 '^# ' "$part" | sed 's/^# //' || true)"
            awk 'stripped || !/^# /{print} !stripped && /^# /{stripped=1}' \
                "$part" > "${part}.h" && mv "${part}.h" "$part"
        fi

        (( idx > 1 )) && [[ "$CONCAT_PAGEBREAK" == "true" ]] && printf '\n\n\\newpage\n\n' >> "$combined"
        cat "$part" >> "$combined"
        printf '\n\n' >> "$combined"
        rm -f "$part"
    done <<< "$SELECTED_FILES"

    if [[ -n "$first_h1" ]]; then
        local fm="${combined}.fm"
        { printf -- '---\ntitle: "%s"\n---\n\n' "$first_h1"; cat "$combined"; } > "$fm" && mv "$fm" "$combined"
    fi

    local rc=0
    case "${SOURCE_FORMAT}→${OUTPUT_FORMAT}" in
        "md→pdf")  convert_md_to_pdf  "$combined" "$first_input" || rc=1 ;;
        "md→docx") convert_md_to_docx "$combined" "$first_input" || rc=1 ;;
        *) warn "Concat not supported for ${SOURCE_FORMAT}→${OUTPUT_FORMAT}."; rc=1 ;;
    esac
    rm -f "$combined"
    return "$rc"
}

run_conversions() {
    header "Converting Files"

    mkdir -p "$OUTPUT_DIR"
    info "Output directory: ${OUTPUT_DIR}"

    local pair="${SOURCE_FORMAT}→${OUTPUT_FORMAT}"
    local failed=0
    local succeeded=0

    if [[ "$CONCAT" == "true" && "$SOURCE_FORMAT" == "md" ]]; then
        if run_concat; then succeeded=1; else failed=1; fi
    else
        while IFS= read -r input_file; do
            [[ -z "$input_file" ]] && continue

            # For md→* pairs: always work on a .tmp.md copy so the pre-passes
            # never touch the original source file.
            local effective_file="$input_file"
            local tmp_file=""

            if [[ "$SOURCE_FORMAT" == "md" ]]; then
                local base
                base=$(basename "$input_file" ".md")
                tmp_file="${OUTPUT_DIR}/${base}.tmp.md"
                cp "$input_file" "$tmp_file"
                effective_file="$tmp_file"
                preprocess_md_tmp "$tmp_file" "$input_file" true
            fi

            case "$pair" in
                "md→pdf")
                    if convert_md_to_pdf "$effective_file" "$input_file"; then
                        succeeded=$(( succeeded + 1 )); else failed=$(( failed + 1 )); fi ;;
                "md→docx")
                    if convert_md_to_docx "$effective_file" "$input_file"; then
                        succeeded=$(( succeeded + 1 )); else failed=$(( failed + 1 )); fi ;;
                "docx→md")
                    if convert_docx_to_md "$effective_file"; then
                        succeeded=$(( succeeded + 1 )); else failed=$(( failed + 1 )); fi ;;
            esac

            [[ -n "$tmp_file" && -f "$tmp_file" ]] && rm -f "$tmp_file"
        done <<< "$SELECTED_FILES"
    fi

    echo ""
    gum style \
        --foreground "$GREEN" --border-foreground "$GREEN" --border rounded \
        --align center --width 60 --margin "1 2" --padding "1 2" \
        "Conversion complete — ${succeeded} succeeded, ${failed} failed."
}

# =============================================================================
# MAIN
# =============================================================================

main() {
    gum style \
        --foreground "$CYAN" --border-foreground "$CYAN" --border double \
        --align center --width 60 --margin "1 2" --padding "1 4" \
        'File Conversion'

    select_source_format
    select_depth
    select_files
    select_output_format
    select_apply_substitutions
    select_strip_rules
    select_unwrap_wikilinks
    select_svg_raster
    select_toc
    select_title_page
    select_concat
    dispatch
    run_conversions
}

# Fast preset: md → PDF with sensible defaults (xelatex, Helvetica, title page +
# TOC, rules stripped), only the file picker is interactive. Reuses the same
# functions as the full flow. Used by the Starlight shim's `pdf` mode.
main_fast() {
    gum style \
        --foreground "$CYAN" --border-foreground "$CYAN" --border double \
        --align center --width 60 --margin "1 2" --padding "1 4" \
        'Convert to PDF'

    SOURCE_FORMAT="md"
    OUTPUT_FORMAT="pdf"
    SEARCH_DEPTH="$DEFAULT_DEPTH"
    USE_TITLE_PAGE=true
    STRIP_RULES=true
    USE_TOC=true
    TOC_DEPTH="$DEFAULT_DEPTH"
    PDF_FONT="Helvetica"

    select_files
    check_deps_md_pdf   # sets AVAILABLE_ENGINES (offers install if none)
    if printf '%s\n' "${AVAILABLE_ENGINES[@]}" | grep -qx "xelatex"; then
        PDF_ENGINE="xelatex"
    else
        PDF_ENGINE="${AVAILABLE_ENGINES[0]}"
        warn "xelatex not available — using ${PDF_ENGINE}."
    fi
    font_installed "$PDF_FONT" || { warn "Font '${PDF_FONT}' not installed — using pandoc default."; PDF_FONT=""; }
    ensure_pdf_config
    detect_mono_font
    run_conversions
}

# =============================================================================
# ENGINE (non-interactive) — flag-driven entrypoint
# Runs a conversion from CLI flags with NO prompts and NO dependency installs
# (guardrails only). The interactive gum UI (main / main_fast) sits on top of
# the same conversion core; this engine layer is what is intended to eventually
# become a standalone, UI-free tool.
# =============================================================================

usage() {
    cat >&2 <<'EOF'
file_conversion.sh — convert Markdown <-> PDF / DOCX

INTERACTIVE (default):
  file_conversion.sh                 launch the gum UI
  file_conversion.sh pdf             fast md->pdf preset (UI file picker only)

NON-INTERACTIVE (engine):
  file_conversion.sh --from <fmt> --to <fmt> [options] <file>...

REQUIRED
  --from md|docx                     source format
  --to   pdf|docx|md                 output format
  <file>...                          one or more input files

COMMON
  -o, --output DIR                   output directory (default: ./output)
  --toc [--toc-depth N]              table of contents (depth default 3)
  --title-page [--image PATH]        add a title page (optional image)
  --[no-]substitutions               smart quote/dash substitutions
  --[no-]strip-rules                 strip horizontal rules
  --[no-]unwrap-wikilinks            unwrap [[wikilinks]]
  --[no-]raster-svg                  rasterize SVG images
  --concat [--no-concat-pagebreak]   combine inputs into one document

DOCX
  --reference letterhead|plain|none|PATH   reference doc (default: plain)
  --letterhead                       shorthand for --reference letterhead
  --page-size a4|letter
  --font NAME   --mono NAME          prose / monospace fonts
  --author|--classification|--version|--date|--logo VALUE   letterhead fields
  --[no-]tp-header --[no-]tp-footer --[no-]tp-pagenum        title-page chrome

PDF
  --pdf-engine xelatex|lualatex|pdflatex|...
  --font NAME                        prose font

DOCX->MD
  --md-variant gfm|markdown|commonmark

In engine mode dependencies are CHECKED but never installed.
EOF
}

# Guardrail dependency checks — verify presence, never install. Sets
# AVAILABLE_ENGINES for md->pdf. Uses gum-free output (edie/enote).
guard_deps() {
    command -v pandoc &>/dev/null || edie \
        "pandoc not found — install it (https://pandoc.org/installing.html), or run this tool via scomp-link which can install it for you."
    case "${SOURCE_FORMAT}->${OUTPUT_FORMAT}" in
        "md->pdf")
            local found=() e
            for e in xelatex lualatex pdflatex wkhtmltopdf weasyprint pagedjs-cli; do
                command -v "$e" &>/dev/null && found+=("$e")
            done
            [[ ${#found[@]} -gt 0 ]] || edie \
                "no PDF engine found (need one of: xelatex, lualatex, pdflatex, wkhtmltopdf, weasyprint, pagedjs-cli)."
            AVAILABLE_ENGINES=("${found[@]}")
            ;;
        "md->docx")
            command -v python3 &>/dev/null || edie \
                "python3 not found — required for DOCX post-processing (letterhead, layout, fonts)."
            ;;
        "docx->md") : ;;
        *) edie "conversion '${SOURCE_FORMAT} -> ${OUTPUT_FORMAT}' is not supported." ;;
    esac
    enote "dependencies OK for ${SOURCE_FORMAT}->${OUTPUT_FORMAT}."
}

# Parse engine flags into the same globals the select_* prompts would set.
# Positional (non-flag) arguments become the input file list.
parse_args() {
    NONINTERACTIVE=true
    local files=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --from)                SOURCE_FORMAT="$2"; shift 2 ;;
            --to)                  OUTPUT_FORMAT="$2"; shift 2 ;;
            -o|--output)           OUTPUT_DIR="$2"; shift 2 ;;
            --toc)                 USE_TOC=true; shift ;;
            --no-toc)              USE_TOC=false; shift ;;
            --toc-depth)           TOC_DEPTH="$2"; shift 2 ;;
            --title-page)          USE_TITLE_PAGE=true; shift ;;
            --no-title-page)       USE_TITLE_PAGE=false; shift ;;
            --image)               TITLE_IMG_CACHE="$2"; TITLE_IMG_ASKED=true; shift 2 ;;
            --substitutions)       APPLY_SUBSTITUTIONS=true; shift ;;
            --no-substitutions)    APPLY_SUBSTITUTIONS=false; shift ;;
            --strip-rules)         STRIP_RULES=true; shift ;;
            --no-strip-rules)      STRIP_RULES=false; shift ;;
            --unwrap-wikilinks)    UNWRAP_WIKILINKS=true; shift ;;
            --no-unwrap-wikilinks) UNWRAP_WIKILINKS=false; shift ;;
            --raster-svg)          RASTER_SVG=true; shift ;;
            --no-raster-svg)       RASTER_SVG=false; shift ;;
            --concat)              CONCAT=true; shift ;;
            --no-concat)           CONCAT=false; shift ;;
            --concat-pagebreak)    CONCAT_PAGEBREAK=true; shift ;;
            --no-concat-pagebreak) CONCAT_PAGEBREAK=false; shift ;;
            --reference)           _ENGINE_REFERENCE="$2"; shift 2 ;;
            --letterhead)          DOCX_LETTERHEAD=true; shift ;;
            --no-letterhead)       DOCX_LETTERHEAD=false; shift ;;
            --page-size)           DOCX_PAGE_SIZE="$2"; shift 2 ;;
            --font)                _ENGINE_FONT="$2"; shift 2 ;;
            --mono)                DOCX_MONO="$2"; shift 2 ;;
            --pdf-engine)          PDF_ENGINE="$2"; shift 2 ;;
            --author)              DOCX_AUTHOR="$2"; shift 2 ;;
            --classification)      DOCX_CLASSIFICATION="$2"; shift 2 ;;
            --version)             DOCX_VERSION="$2"; shift 2 ;;
            --date)                DOCX_DATE="$2"; shift 2 ;;
            --logo)                DOCX_LOGO="$2"; shift 2 ;;
            --tp-header)           TP_HEADER=true; shift ;;
            --no-tp-header)        TP_HEADER=false; shift ;;
            --tp-footer)           TP_FOOTER=true; shift ;;
            --no-tp-footer)        TP_FOOTER=false; shift ;;
            --tp-pagenum)          TP_PAGENUM=true; shift ;;
            --no-tp-pagenum)       TP_PAGENUM=false; shift ;;
            --md-variant)          MD_VARIANT="$2"; shift 2 ;;
            -h|--help)             usage; exit 0 ;;
            --)                    shift; while [[ $# -gt 0 ]]; do files+=("$1"); shift; done ;;
            -*)                    edie "unknown flag: $1 (try --help)" ;;
            *)                     files+=("$1"); shift ;;
        esac
    done
    # `if` (not `&&`) so an empty file list doesn't make parse_args return
    # non-zero and trip set -e in the caller — main_engine reports it instead.
    if [[ ${#files[@]} -gt 0 ]]; then
        SELECTED_FILES="$(printf '%s\n' "${files[@]}")"
    fi
}

main_engine() {
    parse_args "$@"

    [[ -n "${SOURCE_FORMAT:-}" ]]  || edie "missing --from <md|docx>"
    [[ -n "${OUTPUT_FORMAT:-}" ]]  || edie "missing --to <pdf|docx|md>"
    [[ -n "${SELECTED_FILES:-}" ]] || edie "no input files given (pass one or more paths)"

    # Deferred --font → prose font for the chosen target ("none" = pandoc default).
    if [[ -n "$_ENGINE_FONT" ]]; then
        [[ "$_ENGINE_FONT" == none ]] && _ENGINE_FONT=""
        if [[ "$OUTPUT_FORMAT" == pdf ]]; then PDF_FONT="$_ENGINE_FONT"; else DOCX_FONT="$_ENGINE_FONT"; fi
    fi
    # Title-page chrome nesting: no footer => no page number.
    [[ "$TP_FOOTER" == false ]] && TP_PAGENUM=false

    guard_deps

    case "${SOURCE_FORMAT}->${OUTPUT_FORMAT}" in
        "md->pdf")
            ensure_pdf_config
            detect_mono_font
            if [[ -z "$PDF_ENGINE" ]]; then
                if printf '%s\n' "${AVAILABLE_ENGINES[@]}" | grep -qx xelatex; then
                    PDF_ENGINE=xelatex
                else
                    PDF_ENGINE="${AVAILABLE_ENGINES[0]}"
                fi
            elif ! printf '%s\n' "${AVAILABLE_ENGINES[@]}" | grep -qx "$PDF_ENGINE"; then
                edie "--pdf-engine '$PDF_ENGINE' not available (have: ${AVAILABLE_ENGINES[*]})."
            fi
            if [[ -n "$PDF_FONT" ]] && ! font_installed "$PDF_FONT"; then
                enote "font '$PDF_FONT' not installed — using pandoc default."; PDF_FONT=""
            fi
            ;;
        "md->docx")
            ensure_fcc_docx_assets
            case "$_ENGINE_REFERENCE" in
                letterhead) DOCX_REFERENCE_DOC="$DOCX_DEFAULT_REFERENCE"; DOCX_LETTERHEAD=true ;;
                plain)      DOCX_REFERENCE_DOC="$DOCX_PLAIN_REFERENCE";   DOCX_LETTERHEAD=false ;;
                none)       DOCX_REFERENCE_DOC="";                        DOCX_LETTERHEAD=false ;;
                "")         if [[ "$DOCX_LETTERHEAD" == true ]]; then
                                DOCX_REFERENCE_DOC="$DOCX_DEFAULT_REFERENCE"
                            else
                                DOCX_REFERENCE_DOC="$DOCX_PLAIN_REFERENCE"
                            fi ;;
                *)          [[ -f "$_ENGINE_REFERENCE" ]] || edie "--reference file not found: $_ENGINE_REFERENCE"
                            DOCX_REFERENCE_DOC="$_ENGINE_REFERENCE"; DOCX_LETTERHEAD=false ;;
            esac
            [[ "$DOCX_LETTERHEAD" == true ]] && resolve_letterhead
            [[ -n "$DOCX_MONO" ]] || detect_docx_mono
            ;;
        "docx->md")
            : ;;  # pandoc + MD_VARIANT suffice
    esac

    run_conversions
}

# Only auto-run when executed directly. When sourced (e.g. by the Starlight
# converter shim), the caller drives main / main_fast / main_engine itself.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    case "${1:-full}" in
        full)      main ;;
        pdf)       main_fast ;;
        -h|--help) usage ;;
        -*)        main_engine "$@" ;;
        *) error_exit "Unknown mode '${1}'. Valid modes: full | pdf | --from … (see --help)" ;;
    esac
fi
