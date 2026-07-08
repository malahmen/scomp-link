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

# -----------------------------------------------------------------------------
# UI helpers
#
# Scaffolded projects carry a copy of _common/ui.sh alongside this script
# (placed by starlight_astro.sh at create time), so we source it from the same
# directory rather than depending on the scomp-link repo layout. The project
# folder is then self-contained — copy / move / share it without breaking the
# converter.
# -----------------------------------------------------------------------------
command -v gum &>/dev/null || { echo "[error] gum is required. Install via mise or brew." >&2; exit 1; }

if [[ ! -f "${SCRIPT_DIR}/ui.sh" ]]; then
    printf "\033[0;31m[error] ui.sh not found at %s\033[0m\n" "${SCRIPT_DIR}/ui.sh" >&2
    printf "        If this scaffold pre-dates the ui.sh-shipping fix, copy it in:\n" >&2
    printf "        cp <scomp-link>/scripts/_common/ui.sh %s/\n" "${SCRIPT_DIR}" >&2
    exit 1
fi
# shellcheck source=ui.sh
source "${SCRIPT_DIR}/ui.sh"

# Source files live one level up in the Starlight docs directory
DOCS_DIR="../src/content/docs"

# -----------------------------------------------------------------------------
# Constants
# -----------------------------------------------------------------------------

FCC_DIR=".fcc"
TITLE_PAGES_DIR=".fcc/title-pages"
OUTPUT_DIR="./output"
DEFAULT_DEPTH=3

# Built-in DOCX reference doc: shaded code blocks + aligned table of contents.
# Shipped into the project by the scaffolder alongside the rest of .fcc/.
DOCX_DEFAULT_REFERENCE=".fcc/docx/reference.docx"

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
# DOCX fonts applied to the generated file so it uses installed fonts instead of
# the reference template's Microsoft defaults (Aptos/Calibri/Cambria, Consolas).
DOCX_FONT=""   # prose (headings + body); empty = keep the template's theme
DOCX_MONO=""   # monospace (code); auto-detected
USE_TITLE_PAGE=false
APPLIED_TITLE_PAGE_FILE=""
STRIP_RULES=false
USE_TOC=false
TOC_DEPTH=3
TOC_TITLE="Contents"
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

# Optional index page built from the document's markdown headers (pandoc --toc).
# Applies to md→pdf and md→docx; not meaningful for docx→md.
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

    ensure_pagebreak_filter
}

# -----------------------------------------------------------------------------
# Ensure .fcc/pdf/pagebreak.lua exists.
# Ships with new scaffolds via .fcc/, but older projects predate it — write an
# embedded copy when absent so cross-format page breaks work everywhere.
# -----------------------------------------------------------------------------

ensure_pagebreak_filter() {
    local pagebreak_lua="${FCC_DIR}/pdf/pagebreak.lua"
    mkdir -p "${FCC_DIR}/pdf"

    # Write to a temp file first and only replace when the content differs, so a
    # stale copy from an older scaffold self-heals instead of lingering silently.
    local tmp="${pagebreak_lua}.new"
    cat > "$tmp" << 'EOF'
-- pagebreak.lua
-- Turns an explicit page-break marker into the correct construct per output
-- format, so the same marker works for both PDF (LaTeX) and DOCX.
--
-- Recognised markers (alone on a line):
--   \newpage     \pagebreak     \newpage{}     \pagebreak{}
--
-- Honoured whether the marker is in its own paragraph or on its own line
-- inside a paragraph (the paragraph is split around the break).

local function is_marker(s)
    s = (s or ""):gsub("%s+$", ""):gsub("^%s+", "")
    return s == "\\newpage" or s == "\\pagebreak"
        or s == "\\newpage{}" or s == "\\pagebreak{}"
end

local function supported_format()
    return FORMAT:match("latex") or FORMAT:match("beamer") or FORMAT:match("docx")
end

local function break_block()
    if FORMAT:match("latex") or FORMAT:match("beamer") then
        return pandoc.RawBlock("latex", "\\newpage")
    elseif FORMAT:match("docx") then
        -- Use pageBreakBefore rather than an inline <w:br w:type="page"/> run.
        -- An inline break lives in its own empty paragraph; when the preceding
        -- content ends near a page boundary that empty paragraph spills to the
        -- next page and its break then starts yet another → a blank page. Word
        -- suppresses pageBreakBefore when the paragraph is already at the top of
        -- a page, so it never produces that stray blank page.
        return pandoc.RawBlock(
            "openxml",
            '<w:p><w:pPr><w:pageBreakBefore/></w:pPr></w:p>'
        )
    end
    return nil
end

local function inline_is_marker(inl)
    return (inl.t == "RawInline" or inl.t == "Str") and is_marker(inl.text)
end

local function trim_inlines(inls)
    local function ws(i) return i.t == "Space" or i.t == "SoftBreak" or i.t == "LineBreak" end
    local a, b = 1, #inls
    while a <= b and ws(inls[a]) do a = a + 1 end
    while b >= a and ws(inls[b]) do b = b - 1 end
    local out = {}
    for i = a, b do out[#out + 1] = inls[i] end
    return out
end

function Para(el)
    if not supported_format() then return nil end

    if #el.content == 1 and inline_is_marker(el.content[1]) then
        return break_block()
    end

    local has = false
    for _, inl in ipairs(el.content) do
        if inline_is_marker(inl) then has = true; break end
    end
    if not has then return nil end

    local blocks = {}
    local segment = {}
    local function flush()
        local trimmed = trim_inlines(segment)
        if #trimmed > 0 then blocks[#blocks + 1] = pandoc.Para(trimmed) end
        segment = {}
    end
    for _, inl in ipairs(el.content) do
        if inline_is_marker(inl) then
            flush()
            blocks[#blocks + 1] = break_block()
        else
            segment[#segment + 1] = inl
        end
    end
    flush()
    return blocks
end

function RawBlock(el)
    if (el.format == "tex" or el.format == "latex") and is_marker(el.text) then
        return break_block() or el
    end
    return nil
end

-- Is this block a page break — in any of the forms it can take: the raw marker
-- (\newpage as a RawBlock or a lone-marker paragraph) or the break this filter
-- emits (LaTeX \newpage, or the DOCX openxml page break)? Matching every form
-- keeps the adjacency cleanup below correct regardless of filter traversal order.
local function is_break_block(b)
    if not b then return false end
    if b.t == "RawBlock" then
        local f = (b.format or ""):lower()
        if f == "latex" or f == "tex" or f == "beamer" then return is_marker(b.text) end
        if f == "openxml" then
            return b.text:find('w:type="page"', 1, true) ~= nil
                or b.text:find("pageBreakBefore", 1, true) ~= nil
        end
        return false
    end
    if b.t == "Para" and #b.content == 1 then return inline_is_marker(b.content[1]) end
    return false
end

-- A paragraph with no visible content (only whitespace inlines) — the kind a
-- "quirky" Markdown formatter can leave behind next to a break.
local function is_empty_para(b)
    if not b or (b.t ~= "Para" and b.t ~= "Plain") then return false end
    for _, inl in ipairs(b.content) do
        local t = inl.t
        if t ~= "Space" and t ~= "SoftBreak" and t ~= "LineBreak" then return false end
    end
    return true
end

-- Drop a HorizontalRule (Markdown `---`) or empty paragraph sitting immediately
-- next to a page break. In DOCX both render as an extra empty paragraph, which
-- pushes a blank line onto the top of the new page — and occasionally spills to
-- a whole blank page. The break already provides the separation, so the rule /
-- blank is redundant. Leaves rules/blanks that are NOT next to a break alone.
function Blocks(blocks)
    if not supported_format() then return nil end
    local out = {}
    for i = 1, #blocks do
        local b = blocks[i]
        local drop = false
        if b.t == "HorizontalRule" or is_empty_para(b) then
            if is_break_block(out[#out]) or is_break_block(blocks[i + 1]) then
                drop = true
            end
        end
        if not drop then out[#out + 1] = b end
    end
    return out
end
EOF

    if [[ ! -f "$pagebreak_lua" ]] || ! cmp -s "$tmp" "$pagebreak_lua"; then
        mv "$tmp" "$pagebreak_lua"
        success "Wrote ${pagebreak_lua}."
    else
        rm -f "$tmp"
    fi
}

# -----------------------------------------------------------------------------
# Ensure the DOCX asset tree (.fcc/docx/) exists, kept SEPARATE from .fcc/pdf/
# so the PDF and DOCX paths never share files.
#
# New scaffolds ship .fcc/docx/{pagebreak,render-mermaid,p10k} directly. For
# older scaffolds that lack them, seed once from .fcc/pdf/ (the only in-project
# source); afterwards the copies live independently. pagebreak.lua is also
# refreshed from the embedded current version so it self-heals.
# reference.docx is shipped by the scaffolder.
# -----------------------------------------------------------------------------
ensure_fcc_docx_assets() {
    local docx_dir="${FCC_DIR}/docx"
    mkdir -p "$docx_dir"
    ensure_pagebreak_filter   # writes/heals .fcc/pdf/pagebreak.lua from embedded

    local a
    for a in pagebreak.lua render-mermaid.lua p10k.theme; do
        [[ -f "${FCC_DIR}/pdf/${a}" ]] || continue
        # seed when missing; also keep the managed pagebreak filter current
        if [[ ! -f "${docx_dir}/${a}" ]] || \
           { [[ "$a" == "pagebreak.lua" ]] && ! cmp -s "${FCC_DIR}/pdf/${a}" "${docx_dir}/${a}"; }; then
            cp "${FCC_DIR}/pdf/${a}" "${docx_dir}/${a}"
        fi
    done
}

select_pdf_engine() {
    local engine
    engine=$(printf '%s\n' "${AVAILABLE_ENGINES[@]}" | gum choose \
        --header "Select PDF engine:") || true

    [[ -z "$engine" ]] && { gum style --faint "Cancelled."; exit 0; }

    PDF_ENGINE="$engine"
    info "PDF engine: ${PDF_ENGINE}"
}

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

# Is a font family installed? fontconfig when available (reliable on Linux and
# macOS-with-Homebrew-fontconfig), with a macOS system-registry fallback so
# system fonts like Helvetica are never wrongly hidden; optimistic if neither.
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

select_pdf_font() {
    PDF_FONT=""

    if [[ "$PDF_ENGINE" != "xelatex" && "$PDF_ENGINE" != "lualatex" ]]; then
        warn "Font selection only applies to xelatex/lualatex. Skipping for ${PDF_ENGINE}."
        return
    fi

    # Only offer installed fonts — a missing font makes xelatex abort the run.
    local candidates=("JetBrains Mono" "Fira Code" "Inconsolata" "Source Code Pro" \
                      "Courier New" "Monaco" "Menlo" "Helvetica")
    local avail=()
    local c
    for c in "${candidates[@]}"; do
        font_installed "$c" && avail+=("$c")
    done

    if [[ ${#avail[@]} -eq 0 ]]; then
        warn "None of the preset fonts are installed — using pandoc default."
        PDF_FONT=""
        return
    fi
    avail+=("None (pandoc default)")

    local font
    font=$(printf '%s\n' "${avail[@]}" | gum choose \
        --header "Select font — only installed fonts shown:") || true

    [[ -z "$font" ]] && { gum style --faint "Cancelled."; exit 0; }
    [[ "$font" == "None (pandoc default)" ]] && { PDF_FONT=""; return; }

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
        -H "$HEADER_TEX"
        -H "${FCC_DIR}/pdf/monofont.tex"
        -V colorlinks=true
        -V linkcolor=blue
        -V urlcolor=blue
        -V citecolor=blue
    )

    # Add optional assets only when present, so a missing file degrades
    # gracefully instead of failing the whole conversion.
    [[ -f "${FCC_DIR}/pdf/p10k.theme" ]] && \
        pandoc_args+=(--syntax-highlighting="${FCC_DIR}/pdf/p10k.theme")
    local lf
    for lf in widen-tables.lua render-mermaid.lua pagebreak.lua; do
        [[ -f "${FCC_DIR}/pdf/${lf}" ]] && pandoc_args+=(--lua-filter="${FCC_DIR}/pdf/${lf}")
    done

    if [[ -n "$PDF_FONT" ]]; then
        pandoc_args+=(-V "mainfont=${PDF_FONT}")
    fi

    # Table of contents (opt-in) — pandoc builds it from the headers.
    if [[ "$USE_TOC" == "true" ]]; then
        pandoc_args+=(--toc --toc-depth="$TOC_DEPTH" -V "toc-title=${TOC_TITLE}")
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

    local have_default=false
    [[ -f "$DOCX_DEFAULT_REFERENCE" ]] && have_default=true

    if ! gum confirm "Use a custom reference .docx template? (No = built-in styled template)"; then
        if [[ "$have_default" == "true" ]]; then
            DOCX_REFERENCE_DOC="$DOCX_DEFAULT_REFERENCE"
            info "Using built-in styled reference: ${DOCX_REFERENCE_DOC}"
        else
            warn "Built-in reference template unavailable — using pandoc defaults (plain code blocks, unstyled TOC)."
        fi
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
        # Manual paths are stored as-is (already directly usable).
        DOCX_REFERENCE_DOC="$manual"
        info "Reference doc: ${DOCX_REFERENCE_DOC}"
        return
    fi

    # Scanned entries are relative to DOCS_DIR — resolve to a directly usable path.
    DOCX_REFERENCE_DOC="${DOCS_DIR}/${selected}"
    info "Reference doc: ${DOCX_REFERENCE_DOC}"
}

# Post-process a generated .docx: fold each pageBreakBefore break paragraph onto
# the following paragraph, so a heading after \newpage starts the new page with
# no blank line above it. Skipped cleanly if python3 is unavailable (the break
# paragraph then remains — no blank page, just a blank line; nothing is dropped).
# NOTE: keep this logic in sync with starlight/.fcc/docx/fold_pagebreaks.py.
fold_docx_pagebreaks() {
    local docx="$1"
    command -v python3 &>/dev/null || {
        info "python3 not found — leaving page-break paragraphs as-is (a blank line may show above headings)."
        return 0
    }
    python3 - "$docx" <<'PYEOF'
import re, sys, os, zipfile
BREAK = '<w:p><w:pPr><w:pageBreakBefore/></w:pPr></w:p>'
PREFIX = re.compile(r'(\s*(?:<w:bookmark(?:Start|End)\b[^>]*>\s*)*)')

def fold(xml):
    out, pos, n = [], 0, 0
    while True:
        idx = xml.find(BREAK, pos)
        if idx == -1:
            out.append(xml[pos:]); break
        out.append(xml[pos:idx])
        after = idx + len(BREAK)
        pm = PREFIX.match(xml[after:])
        prefix = pm.group(1)
        p_at = after + pm.end()
        m = re.match(r'<w:p\b[^>]*>', xml[p_at:])
        if not m:
            out.append(BREAK); pos = after; continue
        out.append(prefix)
        popen = m.group(0)
        rest_start = p_at + m.end()
        mppr = re.match(r'\s*<w:pPr>(.*?)</w:pPr>', xml[rest_start:], re.S)
        if mppr:
            inner = mppr.group(1)
            if '<w:pageBreakBefore' not in inner:
                ms = re.match(r'(<w:pStyle\b[^>]*>)', inner)
                inner = (ms.group(1) + '<w:pageBreakBefore/>' + inner[ms.end():]) if ms \
                        else '<w:pageBreakBefore/>' + inner
            out.append(popen + '<w:pPr>' + inner + '</w:pPr>')
            pos = rest_start + mppr.end()
        else:
            out.append(popen + '<w:pPr><w:pageBreakBefore/></w:pPr>')
            pos = rest_start
        n += 1
    return ''.join(out), n

path = sys.argv[1]
try:
    with zipfile.ZipFile(path) as z:
        infos = z.infolist()
        data = {i.filename: z.read(i.filename) for i in infos}
except (OSError, zipfile.BadZipFile):
    sys.exit(0)
key = 'word/document.xml'
if key in data:
    xml = data[key].decode('utf-8')
    new, n = fold(xml)
    if n and new != xml:
        data[key] = new.encode('utf-8')
        tmp = path + '.tmp'
        with zipfile.ZipFile(tmp, 'w', zipfile.ZIP_DEFLATED) as z:
            for i in infos:
                z.writestr(i, data[i.filename])
        os.replace(tmp, path)
        print(f'folded {n} page break(s)')
PYEOF
}

# DOCX prose font picker (parity with the PDF font picker). Applied to the
# generated .docx theme (headings + body) so Word does not substitute the
# reference template's fonts. "None" keeps the template's own fonts.
select_docx_font() {
    DOCX_FONT=""
    local candidates=("Helvetica" "Arial" "Times New Roman" "Georgia" "Palatino" "Garamond")
    local avail=() f
    for f in "${candidates[@]}"; do font_installed "$f" && avail+=("$f"); done
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

# Pick an installed monospace font for DOCX code (auto). Falls back to Courier New.
detect_docx_mono() {
    DOCX_MONO=""
    local candidates=("Menlo" "DejaVu Sans Mono" "Monaco" "Consolas" "Courier New") f
    for f in "${candidates[@]}"; do
        if font_installed "$f"; then DOCX_MONO="$f"; break; fi
    done
    [[ -z "$DOCX_MONO" ]] && DOCX_MONO="Courier New"
    info "DOCX monospace font: ${DOCX_MONO}"
}

# Apply DOCX_FONT (prose, via theme) + DOCX_MONO (code, via styles) to a
# generated .docx so it uses installed fonts. No-op for prose if DOCX_FONT is
# empty. Skipped cleanly if python3 is unavailable.
# NOTE: keep this logic in sync with starlight/.fcc/docx/apply_docx_fonts.py.
apply_docx_fonts() {
    local docx="$1"
    [[ -z "$DOCX_FONT" && -z "$DOCX_MONO" ]] && return 0
    command -v python3 &>/dev/null || {
        info "python3 not found — leaving DOCX fonts as the template defaults."
        return 0
    }
    python3 - "$docx" "$DOCX_FONT" "$DOCX_MONO" <<'PYEOF'
import sys, os, re, zipfile
TEMPLATE_MONOS = ('Consolas', 'DejaVu Sans Mono')

def set_theme_font(xml, prose):
    def sub_tag(x, tag):
        def repl(m):
            inner = re.sub(r'(<a:latin typeface=")[^"]*(")',
                           lambda mm: mm.group(1) + prose + mm.group(2), m.group(2), count=1)
            return m.group(1) + inner + m.group(3)
        return re.sub(r'(<a:%s>)(.*?)(</a:%s>)' % (tag, tag), repl, x, count=1, flags=re.S)
    return sub_tag(sub_tag(xml, 'majorFont'), 'minorFont')

def set_mono_font(xml, mono):
    for old in TEMPLATE_MONOS:
        for attr in ('w:ascii', 'w:hAnsi', 'w:cs'):
            xml = xml.replace('%s="%s"' % (attr, old), '%s="%s"' % (attr, mono))
    return xml

path = sys.argv[1]
prose = sys.argv[2] if len(sys.argv) > 2 else ''
mono = sys.argv[3] if len(sys.argv) > 3 else ''
try:
    with zipfile.ZipFile(path) as z:
        infos = z.infolist()
        data = {i.filename: z.read(i.filename) for i in infos}
except (OSError, zipfile.BadZipFile):
    sys.exit(0)
changed = False
tkey = 'word/theme/theme1.xml'
if prose and tkey in data:
    t = data[tkey].decode('utf-8'); nt = set_theme_font(t, prose)
    if nt != t: data[tkey] = nt.encode('utf-8'); changed = True
skey = 'word/styles.xml'
if mono and skey in data:
    s = data[skey].decode('utf-8'); ns = set_mono_font(s, mono)
    if ns != s: data[skey] = ns.encode('utf-8'); changed = True
if changed:
    tmp = path + '.tmp'
    with zipfile.ZipFile(tmp, 'w', zipfile.ZIP_DEFLATED) as z:
        for i in infos:
            z.writestr(i, data[i.filename])
    os.replace(tmp, path)
    print(f'applied fonts: prose={prose or "(unchanged)"} mono={mono or "(unchanged)"}')
PYEOF
}

# Write explicit header + alternating-row cell shading onto every table, matching
# the PDF's row colours. Word — and especially LibreOffice / previewers — don't
# reliably render the reference table style's conditional banding.
# NOTE: keep this logic in sync with starlight/.fcc/docx/shade_tables.py.
shade_docx_tables() {
    local docx="$1"
    command -v python3 &>/dev/null || {
        info "python3 not found — leaving table rows unbanded."
        return 0
    }
    python3 - "$docx" <<'PYEOF'
import re, sys, os, zipfile
HEADER_FILL, BAND_FILL = "CCCCCC", "F5F5F5"
SHD_RE = re.compile(r'<w:shd\b[^>]*/>')
TCW_RE = re.compile(r'<w:tcW\b[^>]*/>')
TC_RE  = re.compile(r'<w:tc\b[^>]*>.*?</w:tc>', re.S)
TR_RE  = re.compile(r'<w:tr\b.*?</w:tr>', re.S)
TBL_RE = re.compile(r'<w:tbl\b.*?</w:tbl>', re.S)

def set_cell_shd(tc, fill):
    shd = '<w:shd w:val="clear" w:color="auto" w:fill="%s"/>' % fill if fill else ''
    m = re.search(r'<w:tcPr>(.*?)</w:tcPr>', tc, re.S)
    if m:
        pr = SHD_RE.sub('', m.group(1))
        if shd:
            tcw = TCW_RE.search(pr)
            pr = pr[:tcw.end()] + shd + pr[tcw.end():] if tcw else shd + pr
        return tc[:m.start(1)] + pr + tc[m.end(1):]
    if not shd:
        return tc
    return re.sub(r'(<w:tc\b[^>]*>)', r'\1<w:tcPr>' + shd + '</w:tcPr>', tc, count=1)

def process_table(tbl):
    out, last, di = [], 0, 0
    for i, rm in enumerate(TR_RE.finditer(tbl)):
        row = rm.group(0)
        is_header = ('<w:tblHeader' in row) or (i == 0 and '<w:tblHeader' not in tbl)
        if is_header:
            fill = HEADER_FILL
        else:
            fill = BAND_FILL if di % 2 == 0 else None
            di += 1
        out.append(tbl[last:rm.start()])
        out.append(TC_RE.sub(lambda mm: set_cell_shd(mm.group(0), fill), row))
        last = rm.end()
    out.append(tbl[last:])
    return ''.join(out)

path = sys.argv[1]
try:
    with zipfile.ZipFile(path) as z:
        infos = z.infolist()
        data = {i.filename: z.read(i.filename) for i in infos}
except (OSError, zipfile.BadZipFile):
    sys.exit(0)
key = 'word/document.xml'
if key in data:
    xml = data[key].decode('utf-8')
    new = TBL_RE.sub(lambda m: process_table(m.group(0)), xml)
    if new != xml:
        data[key] = new.encode('utf-8')
        tmp = path + '.tmp'
        with zipfile.ZipFile(tmp, 'w', zipfile.ZIP_DEFLATED) as z:
            for i in infos:
                z.writestr(i, data[i.filename])
        os.replace(tmp, path)
        print('shaded table rows: header=%s band=%s' % (HEADER_FILL, BAND_FILL))
PYEOF
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

    # DOCX filters — from the DOCX asset tree (.fcc/docx/), kept fully separate
    # from the PDF assets so the two paths never share files.
    local lf
    for lf in pagebreak.lua render-mermaid.lua; do
        [[ -f "${FCC_DIR}/docx/${lf}" ]] && pandoc_args+=(--lua-filter="${FCC_DIR}/docx/${lf}")
    done

    # Table of contents (opt-in) — Word builds a native TOC field.
    if [[ "$USE_TOC" == "true" ]]; then
        pandoc_args+=(--toc --toc-depth="$TOC_DEPTH")
    fi

    if [[ -n "$DOCX_REFERENCE_DOC" ]]; then
        pandoc_args+=(--reference-doc="$DOCX_REFERENCE_DOC")
    fi

    # The p10k syntax theme for code — from the DOCX tree, only with the built-in
    # reference (whose code styles are dark to suit it). A custom template keeps
    # its own code styling.
    if [[ "$DOCX_REFERENCE_DOC" == "$DOCX_DEFAULT_REFERENCE" && -f "${FCC_DIR}/docx/p10k.theme" ]]; then
        pandoc_args+=(--syntax-highlighting="${FCC_DIR}/docx/p10k.theme")
    fi

    gum spin --spinner dot --title "Converting $(basename "$input_file") → $(basename "$output_file") ..." -- \
        pandoc "${pandoc_args[@]}"

    if [[ $? -eq 0 ]]; then
        fold_docx_pagebreaks "$output_file"
        apply_docx_fonts "$output_file"
        # Explicit table banding — only with the built-in reference (a custom
        # template owns its own table styling).
        [[ "$DOCX_REFERENCE_DOC" == "$DOCX_DEFAULT_REFERENCE" ]] && shade_docx_tables "$output_file"
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
            ensure_fcc_docx_assets   # DOCX-only asset tree; never reads .fcc/pdf/ at convert time
            select_docx_reference_doc
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
    select_toc
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

    # Hardcoded: md → pdf via xelatex, Helvetica, with title page + TOC, rules stripped
    SOURCE_FORMAT="md"
    OUTPUT_FORMAT="pdf"
    PDF_ENGINE="xelatex"
    PDF_FONT="Helvetica"
    USE_TITLE_PAGE=true
    STRIP_RULES=true
    USE_TOC=true
    TOC_DEPTH="$DEFAULT_DEPTH"

    # Fall back to the pandoc default if Helvetica isn't installed, so xelatex
    # never aborts on a missing font in fast mode.
    if ! font_installed "$PDF_FONT"; then
        warn "Font '${PDF_FONT}' not installed — using pandoc default."
        PDF_FONT=""
    fi

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
