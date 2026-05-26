#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# convert.sh
# Standalone document conversion TUI for Starlight projects.
# Lives in <project-root>/converter/ — called by mise tasks.
#
# Usage (via mise):
#   mise run convert       → full interactive mode (all options)
#   mise run convert:pdf   → fast mode (file picker only, md→pdf, xelatex, Helvetica, title page)
#
# Usage (direct):
#   bash converter/convert.sh full
#   bash converter/convert.sh pdf
#
# Dependencies: gum, pandoc, xelatex (fast mode), PDF engine of choice (full mode)
# Config:       converter/.fcc/pdf/header.tex      (created on first run if missing)
#               converter/.fcc/pdf/monofont.tex     (written on every run — detected font)
#               converter/.fcc/pdf/p10k.theme       (must be present for PDF)
#               converter/.fcc/pdf/widen-tables.lua
#               converter/.fcc/pdf/render-mermaid.lua
#               converter/.fcc/title-pages/         (optional)
# -----------------------------------------------------------------------------

# -----------------------------------------------------------------------------
# Bash version guard — requires bash 4+ (associative arrays, nameref, etc.)
# macOS ships bash 3.2; install via brew and ensure it's first on PATH.
# -----------------------------------------------------------------------------
if [[ "${BASH_VERSINFO[0]}" -lt 4 ]]; then
    echo "[error] bash 4 or higher is required (you have bash ${BASH_VERSION})."
    echo "  On macOS: brew install bash"
    echo "  Then ensure /opt/homebrew/bin or /usr/local/bin is before /usr/bin in PATH."
    exit 1
fi

set -euo pipefail

# -----------------------------------------------------------------------------
# Directory anchoring
# Always run from converter/ regardless of where mise calls us from.
# All .fcc/ and output/ paths are relative to this directory.
# -----------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

COMMON_DIR="${SCRIPT_DIR}/../../_common"
if [[ ! -d "$COMMON_DIR" ]]; then
    printf "\033[0;31m[ERROR] _common directory not found at %s\033[0m\n" "$COMMON_DIR" >&2
    exit 1
fi
# shellcheck source=../../_common/ui.sh
source "${COMMON_DIR}/ui.sh"

# Source files live one level up in the Starlight docs directory
DOCS_DIR="../src/content/docs"

# -----------------------------------------------------------------------------
# Constants
# -----------------------------------------------------------------------------

FCC_DIR=".fcc"
TITLE_PAGES_DIR=".fcc/title-pages"
OUTPUT_DIR="./output"
DEFAULT_DEPTH=3

# Conversion state globals
SOURCE_FORMAT=""
OUTPUT_FORMAT=""
SEARCH_DEPTH="$DEFAULT_DEPTH"
SELECTED_FILES=""
PDF_ENGINE=""
PDF_FONT=""
MONO_FONT=""
HEADER_TEX=""
DOCX_REFERENCE_DOC=""
MD_VARIANT=""
USE_TITLE_PAGE=false
APPLIED_TITLE_PAGE_FILE=""
STRIP_RULES=false
AVAILABLE_ENGINES=()
OUTPUT_FILE=""

trap 'echo ""; gum style --faint "Interrupted."; exit 0' INT TERM

# -----------------------------------------------------------------------------
# Preflight: check required tools are available
# -----------------------------------------------------------------------------

preflight_checks() {
    if ! command -v gum &>/dev/null; then
        echo "[error] gum is not installed. Please run setup.sh first."
        exit 1
    fi

    # pandoc is managed by mise (declared in mise.toml).
    # If it's not on PATH here, mise install has not been run.
    if ! command -v pandoc &>/dev/null; then
        error_exit "pandoc not found. Run 'mise install' from the project root first."
    fi
}

# -----------------------------------------------------------------------------
# Cross-platform file opener
# -----------------------------------------------------------------------------

open_file() {
    local file="$1"
    if command -v xdg-open &>/dev/null; then
        xdg-open "$file" &>/dev/null &
    elif command -v open &>/dev/null; then
        open "$file"
    fi
}

# =============================================================================
# MONOSPACE FONT DETECTION
# Detects OS, tries a fallback chain of fonts with box-drawing coverage.
# Writes the resolved font to .fcc/pdf/monofont.tex on every run.
# Sets MONO_FONT to the resolved font name.
# =============================================================================

detect_mono_font() {
    local pdf_config_dir="${FCC_DIR}/pdf"
    local monofont_tex="${pdf_config_dir}/monofont.tex"

    mkdir -p "$pdf_config_dir"

    local os=""
    case "$(uname -s)" in
        Darwin) os="macos" ;;
        Linux)  os="linux" ;;
        *)      os="unknown" ;;
    esac

    local resolved=""

    if [[ "$os" == "macos" ]]; then
        # On macOS, fc-list lags after Homebrew cask installs because
        # com.apple.FontRegistry updates asynchronously. Use file existence
        # as the primary detection method — it's always reliable.
        local user_fonts="$HOME/Library/Fonts"
        local sys_fonts="/Library/Fonts"

        if ls "${user_fonts}"/DejaVuSansMono.ttf &>/dev/null 2>&1 || \
           ls "${sys_fonts}"/DejaVuSansMono.ttf &>/dev/null 2>&1; then
            resolved="DejaVu Sans Mono"
        elif ls "${user_fonts}"/NotoMono-Regular.ttf &>/dev/null 2>&1 || \
             ls "${sys_fonts}"/NotoMono-Regular.ttf &>/dev/null 2>&1; then
            resolved="Noto Mono"
        elif ls "${user_fonts}"/LiberationMono-Regular.ttf &>/dev/null 2>&1 || \
             ls "${sys_fonts}"/LiberationMono-Regular.ttf &>/dev/null 2>&1; then
            resolved="Liberation Mono"
        fi
    else
        # Linux: fc-list is synchronous and reliable
        if ! command -v fc-list &>/dev/null; then
            warn "fc-list not found — cannot query installed fonts. Falling back to Courier New."
            warn "Install fontconfig: sudo apt install fontconfig / sudo dnf install fontconfig"
            resolved="Courier New"
        else
            for candidate in "DejaVu Sans Mono" "Noto Mono" "Liberation Mono"; do
                if fc-list | grep -qi "$candidate"; then
                    resolved="$candidate"
                    break
                fi
            done
        fi
    fi

    # Attempt install of DejaVu Sans Mono if nothing found
    if [[ -z "$resolved" ]]; then
        warn "No suitable monospace font found. Attempting to install DejaVu Sans Mono..."

        local installed=false

        case "$os" in
            macos)
                if command -v brew &>/dev/null; then
                    if brew install --cask font-dejavu 2>/dev/null; then
                        installed=true
                    else
                        warn "brew install --cask font-dejavu failed."
                    fi
                else
                    warn "Homebrew not found. Cannot auto-install DejaVu Sans Mono."
                    warn "Install manually: https://dejavu-fonts.github.io"
                fi
                ;;
            linux)
                if sudo -n true 2>/dev/null; then
                    if command -v apt-get &>/dev/null; then
                        sudo apt-get install -y fonts-dejavu &>/dev/null && installed=true
                    elif command -v dnf &>/dev/null; then
                        sudo dnf install -y dejavu-sans-mono-fonts &>/dev/null && installed=true
                    else
                        warn "No supported package manager found (apt/dnf)."
                    fi
                else
                    warn "sudo access unavailable. Cannot auto-install fonts-dejavu."
                    warn "Ask your administrator to install fonts-dejavu / dejavu-sans-mono-fonts."
                fi
                ;;
            *)
                warn "Unknown OS — cannot auto-install fonts."
                ;;
        esac

        if [[ "$installed" == "true" ]]; then
            if [[ "$os" == "macos" ]]; then
                local user_fonts="$HOME/Library/Fonts"
                if ls "${user_fonts}"/DejaVuSansMono.ttf &>/dev/null 2>&1 || \
                   ls /Library/Fonts/DejaVuSansMono.ttf &>/dev/null 2>&1; then
                    resolved="DejaVu Sans Mono"
                    success "DejaVu Sans Mono installed and detected."
                fi
            else
                fc-cache -f 2>/dev/null || true
                if fc-list | grep -qi "DejaVu Sans Mono"; then
                    resolved="DejaVu Sans Mono"
                    success "DejaVu Sans Mono installed and detected."
                fi
            fi
        fi
    fi

    # Hard fail if still nothing
    if [[ -z "$resolved" ]]; then
        error_exit "No monospace font with box-drawing coverage found and auto-install failed.
Please install one of the following manually and re-run:
  DejaVu Sans Mono:   https://dejavu-fonts.github.io
  Noto Mono:          https://fonts.google.com/noto
  Liberation Mono:    https://github.com/liberationfonts/liberation-fonts"
    fi

    MONO_FONT="$resolved"
    info "Monospace font: ${MONO_FONT}"

    # On macOS: use explicit Path= to bypass XeLaTeX font DB (OSFONTDIR not set
    # by default in Homebrew TeX Live). Construct path from known locations.
    # On Linux: name-based lookup via fontspec works correctly.
    if [[ "$os" == "macos" ]]; then
        local font_path=""

        # Prefer fc-list derived path (most accurate) — fall back to known cask path
        if command -v fc-list &>/dev/null; then
            font_path=$(fc-list | grep -i "DejaVu Sans Mono" | grep "style=Book" | head -1 | cut -d: -f1 | tr -d ' ')
        fi
        if [[ -z "$font_path" ]]; then
            font_path="$HOME/Library/Fonts/DejaVuSansMono.ttf"
        fi

        local font_dir font_file
        font_dir="$(dirname "$font_path")/"
        font_file="$(basename "$font_path")"

        printf '\\setmonofont{%s}[Path=%s]\n' \
            "$font_file" "$font_dir" > "$monofont_tex"
    else
        printf '\\setmonofont{%s}\n' "$MONO_FONT" > "$monofont_tex"
    fi

    info "Written: ${monofont_tex}"
}

# =============================================================================
# SUBSTITUTION PASS
# Runs on every .tmp.md working copy before conversion.
# Replaces problematic Unicode characters in prose only.
# Box-drawing characters (├ └ ─) are left untouched — they must be inside
# fenced code blocks, where the monospace font handles them.
# Substitutions (outside fenced code blocks only):
#   →   →  ->
#   —   →  -
#   ✓   →  (removed)
# =============================================================================

apply_substitutions() {
    local file="$1"

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
        "$file" > "${file}.sub" && mv "${file}.sub" "$file"
}

# =============================================================================
# RULE STRIPPING PASS
# Removes thematic breaks (---) from prose, preserving:
#   - YAML front matter (--- block starting on line 1)
#   - Fenced code blocks (``` ... ```)
#   - Table separator rows (contain | or non-space chars alongside ---)
# =============================================================================

apply_strip_rules() {
    local file="$1"
    local tmp_strip="${file%.md}.strip.md"

    awk '
        NR == 1 && /^---[[:space:]]*$/ { in_fm = 1; print; next }
        in_fm && /^---[[:space:]]*$/ { in_fm = 0; print; next }
        in_fm { print; next }
        /^```/ { in_code = !in_code; print; next }
        in_code { print; next }
        /^---[[:space:]]*$/ { next }
        { print }
    ' "$file" > "$tmp_strip"

    mv "$tmp_strip" "$file"
}

select_strip_rules() {
    [[ "$SOURCE_FORMAT" != "md" ]] && return

    if gum confirm "Strip horizontal rules (---) from output?"; then
        STRIP_RULES=true
        info "Horizontal rule stripping enabled."
    else
        STRIP_RULES=false
    fi
}

# =============================================================================
# SHARED SELECTION — used by both full and fast modes
# =============================================================================

select_files() {
    local pattern="*.${SOURCE_FORMAT}"

    info "Scanning ${DOCS_DIR} for .${SOURCE_FORMAT} files..."

    local found
    found=$(find "$DOCS_DIR" -maxdepth "$SEARCH_DEPTH" -name "$pattern" \
        ! -path "*/.git/*" \
        ! -path "*/${FCC_DIR}/*" \
        ! -path "*/output/*" \
        | sed "s|^${DOCS_DIR}/||" \
        | sort)

    if [[ -z "$found" ]]; then
        error_exit "No .${SOURCE_FORMAT} files found in ${DOCS_DIR} (depth ${SEARCH_DEPTH})."
    fi

    local file_count
    file_count=$(echo "$found" | wc -l | tr -d ' ')
    local list_height=$(( file_count < 15 ? file_count + 2 : 17 ))

    local selected
    selected=$(echo "$found" | gum choose --no-limit \
        --height "$list_height" \
        --header "Select file(s) — SPACE to select, ENTER to confirm:") || true

    [[ -z "$selected" ]] && { gum style --faint "Cancelled."; exit 0; }

    # Prepend DOCS_DIR so paths are usable from converter/ working directory
    local prefixed=""
    while IFS= read -r f; do
        prefixed+="${DOCS_DIR}/${f}"$'\n'
    done <<< "$selected"
    SELECTED_FILES="${prefixed%$'\n'}"

    local selected_count
    selected_count=$(echo "$SELECTED_FILES" | wc -l | tr -d ' ')
    info "Selected ${selected_count} file(s)."
}

# =============================================================================
# FULL MODE — interactive, all options
# =============================================================================

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

select_depth() {
    local raw
    raw=$(gum input \
        --placeholder "${DEFAULT_DEPTH}" \
        --header "Search depth for source files (leave empty for default ${DEFAULT_DEPTH}):") || true

    local depth="${raw:-${DEFAULT_DEPTH}}"

    if ! [[ "$depth" =~ ^[0-9]+$ ]] || (( depth < 1 || depth > 10 )); then
        warn "Invalid depth '${depth}', using default ${DEFAULT_DEPTH}."
        depth="${DEFAULT_DEPTH}"
    fi

    SEARCH_DEPTH="$depth"
    info "Search depth: ${SEARCH_DEPTH}"
}

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

select_title_page() {
    [[ "$SOURCE_FORMAT" != "md" ]] && return

    if ! gum confirm "Add a title page to the output?"; then
        USE_TITLE_PAGE=false
        return
    fi

    USE_TITLE_PAGE=true

    if [[ ! -d "$TITLE_PAGES_DIR" ]] || \
       [[ -z "$(find "$TITLE_PAGES_DIR" -maxdepth 1 -name '*.yaml' 2>/dev/null)" ]]; then
        warn "No templates found in ${TITLE_PAGES_DIR}/. Create at least default.yaml to use title pages."
    else
        local count
        count=$(find "$TITLE_PAGES_DIR" -maxdepth 1 -name '*.yaml' | wc -l | tr -d ' ')
        info "Title page enabled — ${count} template(s) available in ${TITLE_PAGES_DIR}/."
    fi
}

# =============================================================================
# FORMAT-PAIR: Markdown → PDF
# =============================================================================

check_deps_md_pdf() {
    header "Checking Dependencies"

    local pandoc_ver
    pandoc_ver=$(pandoc --version | head -1 | awk '{print $2}')
    success "pandoc ${pandoc_ver} (mise)"

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

    detect_mono_font
}

check_deps_md_pdf_fast() {
    header "Checking Dependencies"

    local pandoc_ver
    pandoc_ver=$(pandoc --version | head -1 | awk '{print $2}')
    success "pandoc ${pandoc_ver} (mise)"

    if ! command -v xelatex &>/dev/null; then
        warn "xelatex is not installed."
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
            else
                error_exit "xelatex installation failed.
Install TeX Live manually: https://tug.org/texlive/
  macOS:  brew install --cask mactex-no-gui
  Linux:  sudo apt install texlive-xetex  /  sudo dnf install texlive-xetex
If you want to use a different PDF engine, run: mise run convert"
            fi
        else
            error_exit "xelatex is required for fast PDF conversion.
Install TeX Live: https://tug.org/texlive/
If you want to use a different PDF engine, run: mise run convert"
        fi
    fi

    success "xelatex found."
    AVAILABLE_ENGINES=("xelatex")

    detect_mono_font
}

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

select_pdf_engine() {
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
        "JetBrains Mono" \
        "Fira Code" \
        "Inconsolata" \
        "Source Code Pro" \
        "Courier New" \
        "Monaco" \
        "Menlo" \
        "Helvetica" \
        --header "Select monofont:") || true

    [[ -z "$font" ]] && { gum style --faint "Cancelled."; exit 0; }

    PDF_FONT="$font"
    info "Font: ${PDF_FONT}"
}

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

    local flat_name
    flat_name=$(echo "${source_path%.${SOURCE_FORMAT}}" | tr '/' '_')
    local flat_candidate="${out_dir}/${flat_name}.${ext}"

    if [[ ! -f "$flat_candidate" ]]; then
        info "Name collision for '${base}.${ext}' — using path-derived name: ${flat_name}.${ext}"
        OUTPUT_FILE="$flat_candidate"
        return
    fi

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

convert_md_to_pdf() {
    local input_file="$1"
    local name_source="${2:-$input_file}"

    resolve_output_path "$name_source" "$OUTPUT_DIR" "pdf"
    local output_file="$OUTPUT_FILE"

    local pandoc_args=(
        "$input_file"
        -o "$output_file"
        --pdf-engine="$PDF_ENGINE"
        --syntax-highlighting="${FCC_DIR}/pdf/p10k.theme"
        --lua-filter="${FCC_DIR}/pdf/widen-tables.lua"
        --lua-filter="${FCC_DIR}/pdf/render-mermaid.lua"
        -H "$HEADER_TEX"
        -H "${FCC_DIR}/pdf/monofont.tex"
        -V colorlinks=true
        -V linkcolor=blue
        -V urlcolor=blue
        -V citecolor=blue
    )

    if [[ -n "$PDF_FONT" ]]; then
        pandoc_args+=(-V "mainfont=${PDF_FONT}")
    fi

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

check_deps_md_docx() {
    header "Checking Dependencies"
    local pandoc_ver
    pandoc_ver=$(pandoc --version | head -1 | awk '{print $2}')
    success "pandoc ${pandoc_ver} (mise)"
}

select_docx_reference_doc() {
    DOCX_REFERENCE_DOC=""

    if ! gum confirm "Use a reference .docx template for styling?"; then
        info "No reference doc — using pandoc defaults."
        return
    fi

    info "Scanning for .docx files (depth ${SEARCH_DEPTH})..."

    local found
    found=$(find "$DOCS_DIR" -maxdepth "$SEARCH_DEPTH" -name "*.docx" \
        ! -path "*/.git/*" \
        ! -path "*/${FCC_DIR}/*" \
        ! -path "*/output/*" \
        | sed "s|^${DOCS_DIR}/||" \
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
        pandoc_args+=(--reference-doc="${DOCS_DIR}/${DOCX_REFERENCE_DOC}")
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

check_deps_docx_md() {
    header "Checking Dependencies"
    success "pandoc $(pandoc --version | head -1 | awk '{print $2}') found."
}

select_md_variant() {
    local variant
    variant=$(gum choose \
        "gfm (GitHub-Flavored Markdown)" \
        "markdown (Pandoc extended)" \
        "commonmark" \
        --header "Select Markdown output variant:") || true

    [[ -z "$variant" ]] && { gum style --faint "Cancelled."; exit 0; }

    MD_VARIANT="${variant%% *}"
    info "Markdown variant: ${MD_VARIANT}"
}

convert_docx_to_md() {
    local input_file="$1"

    resolve_output_path "$input_file" "$OUTPUT_DIR" "md"
    local output_file="$OUTPUT_FILE"

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
# TITLE PAGE
# =============================================================================

resolve_title_page_yaml() {
    local source_path="$1"

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

parse_yaml_field() {
    local file="$1"
    local field="$2"
    grep -E "^${field}:" "$file" | head -1 | sed "s/^${field}:[[:space:]]*//" | tr -d '\r'
}

extract_title() {
    local file="$1"

    if head -1 "$file" | grep -qE '^---[[:space:]]*$'; then
        local fm_title
        fm_title=$(awk '/^---/{if(NR==1){in_fm=1;next} else {exit}} in_fm && /^title:/{sub(/^title:[[:space:]]*/,""); print; exit}' "$file" \
                   | tr -d '"' | tr -d "'")
        if [[ -n "$fm_title" ]]; then
            echo "$fm_title"
            return
        fi
    fi

    grep -m1 '^# ' "$file" | sed 's/^# //'
}

strip_title() {
    local file="$1"

    if head -1 "$file" | grep -qE '^---[[:space:]]*$'; then
        sed '/^title:[[:space:]]*/d' "$file"
    else
        awk 'found || !/^# /{print} !found && /^# /{found=1}' "$file"
    fi
}

apply_title_page() {
    local source_path="$1"
    local tmp_file="$2"
    APPLIED_TITLE_PAGE_FILE=""

    local yaml_file
    yaml_file=$(resolve_title_page_yaml "$source_path")

    if [[ -z "$yaml_file" ]]; then
        warn "No title page template for '${source_path}' — skipping title page."
        return
    fi

    local yaml_dir
    yaml_dir=$(dirname "$yaml_file")

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

    local title
    title=$(extract_title "$source_path")
    if [[ -z "$title" ]]; then
        warn "No title found in '${source_path}' — skipping title page."
        return
    fi

    local image_md=""
    if [[ -n "$image_rel" ]]; then
        local image_expanded="${image_rel/#\~/$HOME}"
        local image_abs
        # Resolve relative to project root (one level up from converter/)
        image_abs=$(cd "$SCRIPT_DIR/.." && realpath "$image_expanded" 2>/dev/null || echo "")
        if [[ -n "$image_abs" && -f "$image_abs" ]]; then
            local image_path_escaped="${image_abs//_/\\_}"
            image_md="\\includegraphics[width=0.3\\textwidth]{${image_path_escaped}}"
        else
            warn "Image not found: '${image_rel}' — {{IMAGE}} will be empty."
        fi
    fi

    local rendered
    # awk gsub eats single backslashes in replacement strings — double them first
    local title_awk="${title//\\/\\\\}"
    local image_awk="${image_md//\\/\\\\}"

    rendered=$(awk \
        -v title="$title_awk" \
        -v image="$image_awk" \
        '{gsub(/\{\{TITLE\}\}/, title); gsub(/\{\{IMAGE\}\}/, image); print}' \
        "$template_path")

    # Prepend title page to the already-substituted working copy,
    # stripping the title from the body to avoid duplication
    local body
    body=$(strip_title "$tmp_file")

    {
        echo "$rendered"
        echo ""
        echo "$body"
    } > "${tmp_file}.titled"

    mv "${tmp_file}.titled" "$tmp_file"

    info "Title page applied (template: $(basename "$yaml_file"))"
    APPLIED_TITLE_PAGE_FILE="$tmp_file"
}

# =============================================================================
# CONVERSION RUNNER — shared by both modes
#
# Per-file pipeline:
#   1. Copy source → .tmp.md (working copy, original untouched)
#   2. apply_substitutions on .tmp.md
#   3. apply_title_page on .tmp.md (if enabled, prepends to substituted copy)
#   4. Convert .tmp.md → output
#   5. Delete .tmp.md
# =============================================================================

dispatch() {
    local pair="${SOURCE_FORMAT}→${OUTPUT_FORMAT}"

    case "$pair" in
        "md→pdf")
            ensure_pdf_config
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

run_conversions() {
    header "Converting Files"

    mkdir -p "$OUTPUT_DIR"
    info "Output directory: ${OUTPUT_DIR}"

    local pair="${SOURCE_FORMAT}→${OUTPUT_FORMAT}"
    local failed=0
    local succeeded=0

    while IFS= read -r input_file; do
        [[ -z "$input_file" ]] && continue

        local base
        base=$(basename "$input_file" ".${SOURCE_FORMAT}")
        local tmp_file="${OUTPUT_DIR}/${base}.tmp.md"

        # Step 1: always create working copy — original never modified
        cp "$input_file" "$tmp_file"

        # Step 2: substitution pass (md only)
        if [[ "$SOURCE_FORMAT" == "md" ]]; then
            apply_substitutions "$tmp_file"
        fi

        # Step 3: strip horizontal rules (opt-in, md only)
        if [[ "$STRIP_RULES" == "true" && "$SOURCE_FORMAT" == "md" ]]; then
            apply_strip_rules "$tmp_file"
        fi

        # Step 4: title page prepended to substituted working copy
        if [[ "$USE_TITLE_PAGE" == "true" && "$SOURCE_FORMAT" == "md" ]]; then
            apply_title_page "$input_file" "$tmp_file"
        fi

        # Step 5: convert
        case "$pair" in
            "md→pdf")
                if convert_md_to_pdf "$tmp_file" "$input_file"; then
                    succeeded=$(( succeeded + 1 ))
                else
                    failed=$(( failed + 1 ))
                fi
                ;;
            "md→docx")
                if convert_md_to_docx "$tmp_file" "$input_file"; then
                    succeeded=$(( succeeded + 1 ))
                else
                    failed=$(( failed + 1 ))
                fi
                ;;
            "docx→md")
                if convert_docx_to_md "$tmp_file"; then
                    succeeded=$(( succeeded + 1 ))
                else
                    failed=$(( failed + 1 ))
                fi
                ;;
        esac

        # Step 6: always clean up working copy
        [[ -f "$tmp_file" ]] && rm -f "$tmp_file"

    done <<< "$SELECTED_FILES"

    echo ""
    gum style \
        --foreground "$GREEN" --border-foreground "$GREEN" --border rounded \
        --align center --width 60 --margin "1 2" --padding "1 2" \
        "Conversion complete — ${succeeded} succeeded, ${failed} failed."
}

# =============================================================================
# ENTRY POINTS
# =============================================================================

main_full() {
    gum style \
        --foreground "$CYAN" --border-foreground "$CYAN" --border double \
        --align center --width 60 --margin "1 2" --padding "1 4" \
        'File Conversion'

    select_source_format
    select_depth
    select_files
    select_output_format
    select_strip_rules
    select_title_page

    # Dep check for md→pdf must run before dispatch so AVAILABLE_ENGINES is set
    # and detect_mono_font runs before ensure_pdf_config writes monofont.tex
    if [[ "$SOURCE_FORMAT" == "md" && "$OUTPUT_FORMAT" == "pdf" ]]; then
        check_deps_md_pdf
    fi

    dispatch
    run_conversions
}

main_fast() {
    gum style \
        --foreground "$CYAN" --border-foreground "$CYAN" --border double \
        --align center --width 60 --margin "1 2" --padding "1 4" \
        'Convert to PDF'

    # Hardcoded: md → pdf via xelatex, Helvetica, with title page, rules stripped
    SOURCE_FORMAT="md"
    OUTPUT_FORMAT="pdf"
    PDF_ENGINE="xelatex"
    PDF_FONT="Helvetica"
    USE_TITLE_PAGE=true
    STRIP_RULES=true

    check_deps_md_pdf_fast

    # Upfront title page check — warn before file picker, non-fatal
    if [[ ! -d "$TITLE_PAGES_DIR" ]] || \
       [[ -z "$(find "$TITLE_PAGES_DIR" -maxdepth 1 -name '*.yaml' 2>/dev/null)" ]]; then
        warn "No title page templates found in ${TITLE_PAGES_DIR}/."
        warn "Title page will be skipped per file. Create ${TITLE_PAGES_DIR}/default.yaml to enable it."
    else
        local count
        count=$(find "$TITLE_PAGES_DIR" -maxdepth 1 -name '*.yaml' | wc -l | tr -d ' ')
        info "Title page enabled — ${count} template(s) found in ${TITLE_PAGES_DIR}/."
    fi

    SEARCH_DEPTH="$DEFAULT_DEPTH"

    select_files
    ensure_pdf_config
    run_conversions
}

# =============================================================================
# DISPATCH
# =============================================================================

case "${1:-full}" in
    full) preflight_checks; main_full ;;
    pdf)  preflight_checks; main_fast ;;
    *)
        echo "[error] Unknown mode: '${1}'. Valid modes: full, pdf"
        echo "  Usage: bash converter/convert.sh [full|pdf]"
        exit 1
        ;;
esac
