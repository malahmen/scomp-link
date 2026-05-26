#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# file_conversion.sh
# Interactive TUI for converting files between formats.
# Supported: Markdown → PDF, Markdown → DOCX, DOCX → Markdown
# Called by init.sh — expects gum to already be available.
# Dependencies: gum (managed by init.sh), pandoc + PDF engine (checked at runtime)
# Config: .fcc/pdf/header.tex (created on first run if missing)
#         .fcc/title-pages/<name>.yaml + <name>.md (optional title page templates)
# -----------------------------------------------------------------------------

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

COMMON_DIR="${SCRIPT_DIR}/../_common"
if [[ ! -d "$COMMON_DIR" ]]; then
    printf "\033[0;31m[ERROR] _common directory not found at %s\033[0m\n" "$COMMON_DIR" >&2
    exit 1
fi
# shellcheck source=../_common/ui.sh
source "${COMMON_DIR}/ui.sh"

# -----------------------------------------------------------------------------
# Constants
# -----------------------------------------------------------------------------

FCC_DIR=".fcc"
TITLE_PAGES_DIR=".fcc/title-pages"
OUTPUT_DIR="./output"
DEFAULT_DEPTH=3


# Title page state (set by select_title_page)
USE_TITLE_PAGE=false

# Substitution pass state (set by select_apply_substitutions)
APPLY_SUBSTITUTIONS=false

# Rule stripping state (set by select_strip_rules)
STRIP_RULES=false

# PDF conversion state (set by dispatch → check_deps_md_pdf / select_pdf_engine / select_pdf_font)
PDF_ENGINE=""
PDF_FONT=""
AVAILABLE_ENGINES=()
MONOFONT_TEX=""
HEADER_TEX=""

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

    info "Scanning for .${SOURCE_FORMAT} files (depth ${SEARCH_DEPTH})..."

    local found
    found=$(find . -maxdepth "$SEARCH_DEPTH" -name "$pattern" \
        ! -path "*/node_modules/*" \
        ! -path "*/.git/*" \
        ! -path "*/.astro/*" \
        ! -path "*/dist/*" \
        ! -path "*/${FCC_DIR}/*" \
        ! -path "*/output/*" \
        | sed 's|^\./||' \
        | sort)

    if [[ -z "$found" ]]; then
        error_exit "No .${SOURCE_FORMAT} files found within depth ${SEARCH_DEPTH}."
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
# Config: ensure .fcc/pdf/header.tex exists
# -----------------------------------------------------------------------------

ensure_pdf_config() {
    local pdf_config_dir="${FCC_DIR}/pdf"
    local header_tex="${pdf_config_dir}/header.tex"

    mkdir -p "$pdf_config_dir"

    if [[ ! -f "$header_tex" ]]; then
        info "Creating default ${header_tex}..."
        cat > "$header_tex" << 'EOF'
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
        success "Created ${header_tex}."
    else
        info "Using existing ${header_tex}."
    fi

    HEADER_TEX="$header_tex"
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

select_pdf_font() {
    PDF_FONT=""

    if [[ "$PDF_ENGINE" != "xelatex" && "$PDF_ENGINE" != "lualatex" ]]; then
        warn "Font selection only applies to xelatex/lualatex. Skipping for ${PDF_ENGINE}."
        return
    fi

    local font
    font=$(gum choose \
        "Helvetica" \
        "Times New Roman" \
        "Georgia" \
        "Palatino" \
        "Garamond" \
        "Arial" \
        "None (pandoc default)" \
        --header "Select prose font (body text):") || true

    [[ -z "$font" ]] && { gum style --faint "Cancelled."; exit 0; }
    [[ "$font" == "None (pandoc default)" ]] && { PDF_FONT=""; return; }

    PDF_FONT="$font"
    info "Prose font: ${PDF_FONT}"
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
        --syntax-highlighting="${FCC_DIR}/pdf/p10k.theme"
        --lua-filter="${FCC_DIR}/pdf/widen-tables.lua"
        --lua-filter="${FCC_DIR}/pdf/render-mermaid.lua"
        #--lua-filter="${FCC_DIR}/pdf/wrap-code-urls.lua"
        -H "$HEADER_TEX"
        -H "$MONOFONT_TEX"
        -V colorlinks=true
        -V linkcolor=blue
        -V urlcolor=blue
        -V citecolor=blue
    )

    # PDF_FONT controls prose (mainfont) only — monofont is handled by monofont.tex
    if [[ -n "$PDF_FONT" ]]; then
        pandoc_args+=(-V "mainfont=${PDF_FONT}")
    fi

    #gum spin --spinner dot --title "Converting $(basename "$input_file") → $(basename "$output_file") ..." -- \
    #    pandoc "${pandoc_args[@]}"

    # comment 2 lines above for debug
    # uncomment line below for debug
    pandoc "${pandoc_args[@]}" 2>&1

    if [[ $? -eq 0 ]]; then
        success "$(basename "$output_file") ✓"
        open_file "$output_file"
    else
        warn "Failed to convert: ${input_file}"
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
# Reference doc selection for md → docx
# Scans for .docx files up to SEARCH_DEPTH, offers a manual path escape hatch.
# Sets DOCX_REFERENCE_DOC (empty string = no reference doc).
# -----------------------------------------------------------------------------

select_docx_reference_doc() {
    DOCX_REFERENCE_DOC=""

    if ! gum confirm "Use a reference .docx template for styling?"; then
        info "No reference doc — using pandoc defaults."
        return
    fi

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

    if [[ -n "$DOCX_REFERENCE_DOC" ]]; then
        pandoc_args+=(--reference-doc="$DOCX_REFERENCE_DOC")
    fi

    gum spin --spinner dot --title "Converting $(basename "$input_file") → $(basename "$output_file") ..." -- \
        pandoc "${pandoc_args[@]}"

    if [[ $? -eq 0 ]]; then
        success "$(basename "$output_file") ✓"
        open_file "$output_file"
    else
        warn "Failed to convert: ${input_file}"
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
    grep -E "^${field}:" "$file" | head -1 | sed "s/^${field}:[[:space:]]*//" | tr -d '\r'
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

    # Fall back to first # H1
    grep -m1 '^# ' "$file" | sed 's/^# //'
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
    if [[ -n "$image_rel" ]]; then
        local image_expanded="${image_rel/#\~/$HOME}"
        local image_abs=""
        local candidate
        if [[ "$image_expanded" = /* && -f "$image_expanded" ]]; then
            # Already absolute
            image_abs="$image_expanded"
        else
            # Relative to yaml dir
            candidate="${yaml_dir}/${image_expanded}"
            candidate=$(realpath "$candidate" 2>/dev/null || echo "")
            if [[ -n "$candidate" && -f "$candidate" ]]; then
                image_abs="$candidate"
            else
                # Relative to invocation dir (PWD)
                candidate="${PWD}/${image_expanded}"
                candidate=$(realpath "$candidate" 2>/dev/null || echo "")
                if [[ -n "$candidate" && -f "$candidate" ]]; then
                    image_abs="$candidate"
                fi
            fi
        fi
        if [[ -n "$image_abs" ]]; then
            local image_path_escaped="${image_abs//_/\\_}"
            image_md="\\includegraphics[width=0.3\\textwidth]{${image_path_escaped}}"
        else
            warn "Image not found: '${image_rel}' — {{IMAGE}} will be empty."
            warn "Checked: ${yaml_dir}/${image_rel} and ${PWD}/${image_rel}"
        fi
    fi

    # --- Render template ---
    local rendered
    # awk gsub eats single backslashes in replacement strings — double them first
    local title_awk="${title//\\/\\\\}"
    local image_awk="${image_md//\\/\\\\}"

    rendered=$(awk \
        -v title="$title_awk" \
        -v image="$image_awk" \
        '{gsub(/\{\{TITLE\}\}/, title); gsub(/\{\{IMAGE\}\}/, image); print}' \
        "$template_path")

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
            ;;
        "md→docx")
            check_deps_md_docx
            select_docx_reference_doc
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

run_conversions() {
    header "Converting Files"

    mkdir -p "$OUTPUT_DIR"
    info "Output directory: ${OUTPUT_DIR}"

    local pair="${SOURCE_FORMAT}→${OUTPUT_FORMAT}"
    local failed=0
    local succeeded=0

    while IFS= read -r input_file; do
        [[ -z "$input_file" ]] && continue

        # For md→* pairs: always work on a .tmp.md copy so substitutions
        # and title page injection never touch the original source file.
        local effective_file="$input_file"
        local tmp_file=""

        if [[ "$SOURCE_FORMAT" == "md" ]]; then
            local base
            base=$(basename "$input_file" ".md")
            tmp_file="${OUTPUT_DIR}/${base}.tmp.md"
            cp "$input_file" "$tmp_file"
            effective_file="$tmp_file"

            # Substitution pass (opt-in)
            if [[ "$APPLY_SUBSTITUTIONS" == "true" ]]; then
                apply_substitutions "$tmp_file"
            fi

            # Rule stripping pass (opt-in)
            if [[ "$STRIP_RULES" == "true" ]]; then
                apply_strip_rules "$tmp_file"
            fi

            # Title page injection (opt-in)
            if [[ "$USE_TITLE_PAGE" == "true" ]]; then
                apply_title_page "$input_file" "$tmp_file"
                # apply_title_page writes into tmp_file directly; effective_file unchanged
            fi
        fi

        case "$pair" in
            "md→pdf")
                if convert_md_to_pdf "$effective_file" "$input_file"; then
                    succeeded=$(( succeeded + 1 ))
                else
                    failed=$(( failed + 1 ))
                fi
                ;;
            "md→docx")
                if convert_md_to_docx "$effective_file" "$input_file"; then
                    succeeded=$(( succeeded + 1 ))
                else
                    failed=$(( failed + 1 ))
                fi
                ;;
            "docx→md")
                if convert_docx_to_md "$effective_file"; then
                    succeeded=$(( succeeded + 1 ))
                else
                    failed=$(( failed + 1 ))
                fi
                ;;
        esac

        # Clean up temp file after each conversion
        if [[ -n "$tmp_file" && -f "$tmp_file" ]]; then
            rm -f "$tmp_file"
        fi

    done <<< "$SELECTED_FILES"

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
    select_title_page
    dispatch
    run_conversions
}

main "$@"
