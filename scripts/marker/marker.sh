#!/usr/bin/env bash
# Standalone export (export.sh): tools the slimmed setup.sh pre-installs.
# export-setup: pipx
# -----------------------------------------------------------------------------
# marker.sh
# Interactive TUI to manage datalab-to/marker — convert documents
# (PDF/DOCX/PPTX/XLSX/HTML/EPUB/images) INTO Markdown / JSON / HTML / chunks,
# ready for later LLM ingestion. The inverse of holo-convert (Markdown -> PDF/DOCX).
#
# Called by init.sh — expects gum to already be available.
# marker itself is installed in an isolated pipx environment (managed here),
# so it never pollutes system Python.
#
# Dependencies: gum (managed by init.sh), python 3.10–3.13, pipx (offered on setup).
# Project home: https://github.com/datalab-to/marker
# -----------------------------------------------------------------------------

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Shared helpers: ../_common in the repo, or alongside this script when exported.
if [[ -d "${SCRIPT_DIR}/../_common" ]]; then
    COMMON_DIR="${SCRIPT_DIR}/../_common"   # scomp-link repo layout
else
    COMMON_DIR="${SCRIPT_DIR}"              # exported standalone: deps sit alongside
fi
if [[ ! -f "${COMMON_DIR}/ui.sh" ]]; then
    printf "\033[0;31m[ERROR] ui.sh not found in %s\033[0m\n" "$COMMON_DIR" >&2
    exit 1
fi
# shellcheck source=../_common/ui.sh
source "${COMMON_DIR}/ui.sh"

# -----------------------------------------------------------------------------
# Constants
# -----------------------------------------------------------------------------

MARKER_PKG="marker-pdf"          # the pip package name
MARKER_SPEC="marker-pdf[full]"   # [full] = non-PDF inputs (docx/pptx/xlsx/epub/html)
DEFAULT_OUTPUT_DIR="./marker-output"
# marker + PyTorch support Python 3.10–3.13 (NOT 3.14 yet). find_marker_python
# picks a working one; the system default python3 may be newer/unusable.

# Input formats marker accepts (used to build the file picker).
INPUT_EXTS=(pdf docx pptx xlsx html epub png jpg jpeg tiff tif webp gif bmp)

PIPX=""   # resolved to "pipx" or "python3 -m pipx" by resolve_pipx()

# Containerized service (Docker/K8s) — the scalable RAG-ingestion deployment.
SERVICE_DIR="${SCRIPT_DIR}/templates/service"
COMPOSE_FILE="${SERVICE_DIR}/docker-compose.yaml"
K8S_DIR="${SERVICE_DIR}/k8s"
MARKER_IMAGE="marker-service:latest"
K8S_NS="marker"
SVC_TARGET=""   # "docker" or "k8s", chosen in menu_service

trap 'echo ""; gum style --faint "Interrupted."; exit 0' INT TERM

# -----------------------------------------------------------------------------
# Cross-platform opener (used to reveal the output folder)
# -----------------------------------------------------------------------------

open_path() {
    local p="$1"
    if command -v xdg-open &>/dev/null; then
        xdg-open "$p" &>/dev/null &
    elif command -v open &>/dev/null; then
        open "$p"
    fi
}

# -----------------------------------------------------------------------------
# Environment helpers
# -----------------------------------------------------------------------------

# Detect the OS family once.
os_family() {
    case "$(uname -s)" in
        Darwin) echo "macos" ;;
        Linux)  echo "linux" ;;
        *)      echo "other" ;;
    esac
}

# Find a marker-compatible Python interpreter and echo its path.
# marker + PyTorch ship wheels for 3.10–3.13; the system default may be newer
# (e.g. 3.14, whose `venv`/ensurepip is also broken on this setup), so we pick
# an explicit supported version whose venv actually works — preferring the most
# torch-tested one. Returns non-zero if none is usable.
find_marker_python() {
    local v cand path tmp
    for v in 3.12 3.13 3.11 3.10; do
        path="$(command -v "python${v}" 2>/dev/null || true)"
        [[ -n "$path" ]] || continue
        tmp="$(mktemp -d)"
        if "$path" -m venv "${tmp}/v" &>/dev/null; then
            rm -rf "$tmp"
            printf '%s' "$path"
            return 0
        fi
        rm -rf "$tmp"
    done
    return 1
}

# Resolve how to invoke pipx: prefer the `pipx` binary, else `python3 -m pipx`.
# Sets the global PIPX. Returns non-zero if pipx is not available at all.
resolve_pipx() {
    if command -v pipx &>/dev/null; then
        PIPX="pipx"
        return 0
    fi
    if command -v python3 &>/dev/null && python3 -m pipx --version &>/dev/null; then
        PIPX="python3 -m pipx"
        return 0
    fi
    PIPX=""
    return 1
}

# Resolve a marker CLI (marker_single / marker / marker_gui / marker_server) to a
# runnable path: prefer PATH, else the pipx venv's bin (covers a not-yet-sourced
# PATH right after install).
marker_cli() {
    local name="$1"
    if command -v "$name" &>/dev/null; then
        echo "$name"
        return 0
    fi
    resolve_pipx || return 1
    local venvs
    venvs=$($PIPX environment --value PIPX_LOCAL_VENVS 2>/dev/null || echo "${HOME}/.local/pipx/venvs")
    local cand="${venvs}/${MARKER_PKG}/bin/${name}"
    [[ -x "$cand" ]] && { echo "$cand"; return 0; }
    return 1
}

# Python interpreter inside marker's pipx venv (for torch device detection).
marker_python() {
    resolve_pipx || return 1
    local venvs
    venvs=$($PIPX environment --value PIPX_LOCAL_VENVS 2>/dev/null || echo "${HOME}/.local/pipx/venvs")
    local cand="${venvs}/${MARKER_PKG}/bin/python"
    [[ -x "$cand" ]] && { echo "$cand"; return 0; }
    return 1
}

marker_installed() { marker_cli marker_single &>/dev/null; }

marker_version() {
    resolve_pipx || { echo "unknown"; return; }
    $PIPX list --short 2>/dev/null | awk -v p="$MARKER_PKG" '$1==p{print $2}' | head -1
}

# -----------------------------------------------------------------------------
# Setup: ensure pipx, then install or upgrade marker
# -----------------------------------------------------------------------------

ensure_pipx() {
    resolve_pipx && return 0

    warn "pipx is not installed."
    gum confirm "Install pipx now?" || error_exit "pipx is required. See https://pipx.pypa.io/stable/installation/"

    local os; os="$(os_family)"
    case "$os" in
        macos)
            if command -v brew &>/dev/null; then
                brew install pipx && pipx ensurepath || true
            else
                python3 -m pip install --user pipx && python3 -m pipx ensurepath || true
            fi
            ;;
        linux)
            if command -v apt-get &>/dev/null && sudo -n true 2>/dev/null; then
                sudo apt-get install -y pipx || python3 -m pip install --user pipx
            elif command -v dnf &>/dev/null && sudo -n true 2>/dev/null; then
                sudo dnf install -y pipx || python3 -m pip install --user pipx
            else
                python3 -m pip install --user pipx
            fi
            python3 -m pipx ensurepath 2>/dev/null || true
            ;;
        *)
            python3 -m pip install --user pipx && python3 -m pipx ensurepath || true
            ;;
    esac

    resolve_pipx || error_exit "pipx installation failed. Install it manually, then re-run."
    success "pipx ready ($PIPX)."
}

# Ensure a Python import is satisfiable inside marker's venv, injecting pip
# packages if not. Cheap + idempotent (skips when already importable), so it's
# safe to call before every run.
#   $1  = import statement to test (e.g. "psutil" or "fastapi, uvicorn")
#   $2… = pip package(s) to `pipx inject` if the import fails
# Returns non-zero if an inject was needed but failed.
ensure_injected() {
    local import_stmt="$1"; shift
    local py; py=$(marker_python 2>/dev/null) || py=""
    [[ -n "$py" ]] && "$py" -c "import ${import_stmt}" 2>/dev/null && return 0
    resolve_pipx || return 1
    info "Adding $* to marker's environment (one-time)..."
    $PIPX inject "$MARKER_PKG" "$@" >/dev/null 2>&1 || { warn "Could not inject: $*"; return 1; }
}

# marker-pdf[full] doesn't pull psutil, but the batch/chunk entrypoints import it.
ensure_marker_deps() { ensure_injected psutil psutil; }

# marker's venv bin dir — prepended to PATH when launching marker_gui/marker_server
# so the tools they shell out to (streamlit, uvicorn) are found even though pipx
# only exposes marker's own entrypoints on PATH.
marker_venv_bin() {
    resolve_pipx || return 1
    local venvs
    venvs=$($PIPX environment --value PIPX_LOCAL_VENVS 2>/dev/null || echo "${HOME}/.local/pipx/venvs")
    printf '%s' "${venvs}/${MARKER_PKG}/bin"
}

# Run a long-lived foreground server (GUI/API server) such that Ctrl-C stops
# just that server and returns to the menu — instead of the script's global INT
# trap firing and exiting marker.sh entirely. A non-empty (no-op) INT handler
# keeps the script alive while the child still receives SIGINT and shuts down.
run_foreground() {
    trap ':' INT
    "$@" || true
    trap 'echo ""; gum style --faint "Interrupted."; exit 0' INT TERM
}

# -----------------------------------------------------------------------------
# Surya OCR backend (llama.cpp / vLLM)
#
# marker's OCR/recognition engine (surya) no longer runs on plain PyTorch — it
# serves its recognition model through an inference backend, chosen by hardware:
# vLLM on an NVIDIA GPU, else llama.cpp (macOS / CPU), which needs the
# `llama-server` binary. Without it, conversions crash the moment OCR runs.
# SURYA_INFERENCE_BACKEND overrides the auto-choice; LLAMA_CPP_BINARY points at
# a llama-server outside PATH.
# -----------------------------------------------------------------------------

surya_backend() {
    if [[ -n "${SURYA_INFERENCE_BACKEND:-}" ]]; then
        echo "${SURYA_INFERENCE_BACKEND}"; return
    fi
    if [[ -e /dev/nvidia0 ]] || command -v nvidia-smi &>/dev/null; then
        echo "vllm"
    else
        echo "llamacpp"
    fi
}

llama_server_present() {
    command -v llama-server &>/dev/null && return 0
    [[ -n "${LLAMA_CPP_BINARY:-}" && -x "${LLAMA_CPP_BINARY}" ]]
}

# Install llama.cpp (provides llama-server). Returns non-zero if it can't.
install_llama_server() {
    if llama_server_present; then info "llama-server already available."; return 0; fi
    case "$(os_family)" in
        macos)
            command -v brew &>/dev/null || {
                warn "Homebrew not found — install it, then 'brew install llama.cpp' (or set LLAMA_CPP_BINARY)."
                return 1
            }
            info "Installing llama.cpp via Homebrew (provides llama-server)..."
            run_foreground brew install llama.cpp
            ;;
        linux)
            if command -v brew &>/dev/null; then
                info "Installing llama.cpp via Homebrew..."
                run_foreground brew install llama.cpp
            else
                warn "No automatic installer for this Linux host. Either:"
                warn "  • download a llama-server build: https://github.com/ggml-org/llama.cpp/releases"
                warn "    then: export LLAMA_CPP_BINARY=/path/to/llama-server"
                warn "  • or install Homebrew and 'brew install llama.cpp'"
                return 1
            fi
            ;;
        *)
            warn "Unsupported OS for automatic install — set LLAMA_CPP_BINARY to a llama-server path."
            return 1
            ;;
    esac
    if llama_server_present; then
        success "llama-server is available."
    else
        warn "llama-server still not found after install — check the output above."
        return 1
    fi
}

# Ensure the OCR backend is runnable; offer to install llama-server when the
# llamacpp backend is selected and the binary is missing. Non-fatal.
ensure_surya_backend() {
    [[ "$(surya_backend)" == "llamacpp" ]] || return 0   # vLLM path: nothing here
    llama_server_present && return 0
    warn "marker's OCR engine (surya) uses the 'llamacpp' backend here, which needs 'llama-server' — not found."
    if gum confirm "Install llama.cpp now (provides llama-server)?"; then
        install_llama_server || return 1
    else
        warn "Skipping. OCR-dependent conversions will fail until it's installed"
        warn "  (brew install llama.cpp, or set LLAMA_CPP_BINARY)."
        return 1
    fi
}

action_setup() {
    header "Setup / Install marker"

    local marker_py
    if ! marker_py="$(find_marker_python)"; then
        error_exit "No marker-compatible Python (3.10–3.13, with a working venv) was found.
Your default 'python3' is $(python3 --version 2>&1 || echo 'missing') — too new for marker/PyTorch
(and 3.14's venv is broken on this system). Install a supported version, e.g.:
  macOS:  brew install python@3.12
  Linux:  your package manager's python3.12 (or 3.11/3.13)
then re-run setup."
    fi
    success "Using $("$marker_py" --version 2>&1) at ${marker_py} for marker's isolated environment."

    ensure_pipx

    if marker_installed; then
        info "marker is already installed (version: $(marker_version))."
        gum confirm "Upgrade marker to the latest version?" || { info "Leaving current install untouched."; return; }
        info "Upgrading ${MARKER_PKG} (this pulls model/torch updates — may take a while)..."
        $PIPX upgrade "$MARKER_PKG" || error_exit "Upgrade failed."
        ensure_marker_deps
        success "marker upgraded to $(marker_version)."
        ensure_surya_backend || true   # newer surya needs llama-server (mac/CPU)
        return
    fi

    warn "marker downloads PyTorch and several GB of models on first run."
    gum confirm "Install ${MARKER_SPEC} now?" || { info "Setup cancelled."; return; }
    info "Installing ${MARKER_SPEC} via pipx on $("$marker_py" --version 2>&1) (this can take several minutes)..."
    # Pin the interpreter for BOTH pipx's shared venv (PIPX_DEFAULT_PYTHON) and
    # marker's app venv (--python), so a broken/too-new default python3 is never
    # used.
    PIPX_DEFAULT_PYTHON="$marker_py" $PIPX install --python "$marker_py" "$MARKER_SPEC" \
        || error_exit "Installation failed."
    ensure_marker_deps

    if marker_installed; then
        success "marker installed (version: $(marker_version))."
        if ! command -v marker_single &>/dev/null; then
            warn "marker CLIs aren't on your PATH yet. Run 'pipx ensurepath' and restart your shell."
            warn "This session will still work — it resolves them from the pipx venv directly."
        fi
        ensure_surya_backend || true   # OCR engine needs llama-server (mac/CPU)
    else
        error_exit "Install reported success but marker_single wasn't found."
    fi
}

# Guard used by actions that need marker present.
require_marker() {
    marker_installed && return 0
    warn "marker is not installed yet."
    if gum confirm "Run setup now?"; then
        action_setup
        marker_installed || error_exit "marker still not available."
    else
        return 1
    fi
}

# -----------------------------------------------------------------------------
# LLM service selection (only when --use_llm is enabled)
# Populates the global LLM_ARGS array with the flags marker needs.
# -----------------------------------------------------------------------------

LLM_ARGS=()

build_llm_args() {
    LLM_ARGS=()

    local svc
    svc=$(gum choose \
        "Google Gemini (default)" \
        "OpenAI / OpenAI-compatible" \
        "Anthropic Claude" \
        "Ollama (local)" \
        --header "Select the LLM service for --use_llm:") || true
    [[ -z "$svc" ]] && { gum style --faint "Cancelled."; return 1; }

    # Prompt for a key, preferring an already-exported env var so it never has
    # to be typed (and never echoed). Returns the value on stdout.
    _key() {
        local env_name="$1" label="$2" val=""
        if [[ -n "${!env_name:-}" ]]; then
            info "Using ${env_name} from environment."
            printf '%s' "${!env_name}"
            return
        fi
        val=$(gum input --password --header "Enter ${label} (leave empty to rely on env/config):") || true
        printf '%s' "$val"
    }

    case "$svc" in
        "Google Gemini (default)")
            LLM_ARGS+=(--llm_service marker.services.gemini.GoogleGeminiService)
            local k; k=$(_key GEMINI_API_KEY "Gemini API key")
            [[ -n "$k" ]] && LLM_ARGS+=(--gemini_api_key "$k")
            ;;
        "OpenAI / OpenAI-compatible")
            # OpenAIService talks to any OpenAI-compatible endpoint, so this also
            # covers a local/LAN server (LM Studio, LocalAI, vLLM, llama.cpp) —
            # point the base URL at it and name the loaded vision model.
            LLM_ARGS+=(--llm_service marker.services.openai.OpenAIService)
            local b; b=$(gum input \
                --header "Base URL (blank = OpenAI cloud; local e.g. http://192.168.1.50:1234/v1):") || true
            [[ -n "$b" ]] && LLM_ARGS+=(--openai_base_url "$b")
            local k; k=$(_key OPENAI_API_KEY "API key (a local server usually ignores this — any non-empty value)")
            [[ -n "$k" ]] && LLM_ARGS+=(--openai_api_key "$k")
            local m; m=$(gum input --header "Model name (blank = marker default; for a local server: the loaded vision model's id):") || true
            [[ -n "$m" ]] && LLM_ARGS+=(--openai_model "$m")
            ;;
        "Anthropic Claude")
            LLM_ARGS+=(--llm_service marker.services.claude.ClaudeService)
            local k; k=$(_key ANTHROPIC_API_KEY "Anthropic API key")
            [[ -n "$k" ]] && LLM_ARGS+=(--claude_api_key "$k")
            local m; m=$(gum input --header "Claude model name (blank = marker default):") || true
            [[ -n "$m" ]] && LLM_ARGS+=(--claude_model_name "$m")
            ;;
        "Ollama (local)")
            LLM_ARGS+=(--llm_service marker.services.ollama.OllamaService)
            local url; url=$(gum input --value "http://localhost:11434" --header "Ollama base URL:") || true
            [[ -n "$url" ]] && LLM_ARGS+=(--ollama_base_url "$url")
            local m; m=$(gum input --header "Ollama model (e.g. llama3.2-vision):") || true
            [[ -n "$m" ]] && LLM_ARGS+=(--ollama_model "$m")
            ;;
    esac
    info "LLM service configured."
}

# -----------------------------------------------------------------------------
# Convert
# -----------------------------------------------------------------------------

# Shared options prompt — sets OUTPUT_FORMAT, OUTPUT_DIR, and EXTRA_ARGS[].
EXTRA_ARGS=()
OUTPUT_FORMAT=""
OUTPUT_DIR=""

select_common_options() {
    EXTRA_ARGS=()

    local fmt
    fmt=$(gum choose "markdown" "json" "html" "chunks" \
        --header "Select output format:") || true
    [[ -z "$fmt" ]] && { gum style --faint "Cancelled."; return 1; }
    OUTPUT_FORMAT="$fmt"

    OUTPUT_DIR=$(gum input --value "$DEFAULT_OUTPUT_DIR" --header "Output directory:") || true
    OUTPUT_DIR="${OUTPUT_DIR:-$DEFAULT_OUTPUT_DIR}"

    gum confirm "Force OCR on the whole document? (slower, fixes bad embedded text)" \
        && EXTRA_ARGS+=(--force_ocr)

    if gum confirm "Use an LLM to improve quality? (--use_llm)"; then
        EXTRA_ARGS+=(--use_llm)
        build_llm_args || return 1
        EXTRA_ARGS+=("${LLM_ARGS[@]}")
    fi
    # Note: language is auto-detected by marker's OCR (surya) — there is no
    # --languages flag in current versions, so we don't offer one.
}

# Ask for a folder, scan it recursively for supported files, and let the user
# multi-select. Echoes the chosen paths (newline-separated) on stdout; returns 1
# (with a message) on no-folder / nothing-found / cancelled.
pick_files_from_folder() {
    local folder
    folder=$(gum input --value "." --header "Folder to scan for documents (searches subfolders too):") || true
    folder="${folder:-.}"
    folder="${folder/#\~/$HOME}"
    [[ -d "$folder" ]] || { warn "Not a folder: ${folder}" >&2; return 1; }

    local find_args=() ext
    for ext in "${INPUT_EXTS[@]}"; do
        find_args+=(-iname "*.${ext}" -o)
    done
    unset 'find_args[${#find_args[@]}-1]'   # drop trailing -o

    local found
    found=$(find "$folder" -type f \( "${find_args[@]}" \) \
        ! -path "*/node_modules/*" ! -path "*/.git/*" \
        ! -path "*/.fcc/*" ! -path "*/marker-output/*" \
        2>/dev/null | sed 's|^\./||' | sort || true)
    [[ -z "$found" ]] && { warn "No supported files found under ${folder}." >&2; return 1; }

    local count height picked
    count=$(printf '%s\n' "$found" | wc -l | tr -d ' ')
    height=$(( count < 15 ? count + 2 : 17 ))
    picked=$(printf '%s\n' "$found" | gum choose --no-limit --height "$height" \
        --header "Select file(s) — SPACE to select, ENTER to confirm (${count} found):") || true
    [[ -z "$picked" ]] && { gum style --faint "Cancelled." >&2; return 1; }
    printf '%s' "$picked"
}

# Clamp a page-range string to a PDF's real pages so out-of-range values don't
# trip marker's in-bounds assertion. Echoes a comma list of valid 0-based pages;
# empty output = no valid pages (caller converts the whole document). If the page
# count can't be determined, the raw range is echoed unchanged.
clamp_page_range() {
    local file="$1" rng="$2" py
    py=$(marker_python) || { printf '%s' "$rng"; return 0; }
    "$py" - "$file" "$rng" <<'PY'
import sys
path, rng = sys.argv[1], sys.argv[2]
try:
    from marker.util import parse_range_str
    import pypdfium2 as pdfium
    n = len(pdfium.PdfDocument(path))
    pages = sorted({p for p in parse_range_str(rng) if 0 <= p < n})
except Exception:
    print(rng); sys.exit(0)          # can't introspect → let marker validate
if pages:
    print(",".join(map(str, pages)))  # else: print nothing → whole document
PY
}

# Optional page range for a SINGLE pdf (default: whole document). Populates
# PAGE_ARGS[]. Out-of-range values are dropped rather than failing the run.
PAGE_ARGS=()
maybe_page_range() {
    PAGE_ARGS=()
    local file="$1"
    [[ "${file,,}" == *.pdf ]] || return 0            # ranges only meaningful for PDFs
    gum confirm "Convert the whole document?" && return 0
    local raw; raw=$(gum input --header "Pages to convert (0-based), e.g. 0,5-10,20:") || true
    [[ -z "$raw" ]] && return 0                        # blank → whole document
    local clamped; clamped=$(clamp_page_range "$file" "$raw")
    if [[ -z "$clamped" ]]; then
        warn "None of those pages exist in this document — converting the whole file."
        return 0
    fi
    [[ "$clamped" != "$raw" ]] && info "Range clamped to existing pages: ${clamped}"
    PAGE_ARGS=(--page_range "$clamped")
}

# Convert ONE file with marker_single (honours EXTRA_ARGS + PAGE_ARGS).
run_one() {
    local file="$1"
    local bin; bin=$(marker_cli marker_single) || { warn "marker_single not found — run Setup first."; return 0; }
    mkdir -p "$OUTPUT_DIR"
    header "Converting"
    info "${file} → ${OUTPUT_FORMAT} in ${OUTPUT_DIR}/"
    # Run directly (no spinner): marker prints its own progress and may download
    # models on first run.
    if "$bin" "$file" --output_format "$OUTPUT_FORMAT" --output_dir "$OUTPUT_DIR" "${EXTRA_ARGS[@]}" "${PAGE_ARGS[@]}"; then
        success "Done → ${OUTPUT_DIR}/"
        open_path "$OUTPUT_DIR"
    else
        warn "Conversion failed for: ${file}"
    fi
}

# Convert several selected files in one batch run. Marker's batch CLI lists a
# single folder (os.listdir, non-recursive, follows symlinks), so we stage the
# selection as symlinks in a flat temp dir — models load once for the whole set.
# Whole documents only (no page range across a mixed selection).
run_selected() {
    ensure_marker_deps   # batch CLI needs psutil (not pulled by marker-pdf[full])
    local bin; bin=$(marker_cli marker) || { warn "marker (batch CLI) not found — run Setup first."; return 0; }

    local workers; workers=$(gum input --value "4" --header "Parallel workers (each ~3.5GB RAM/VRAM):") || true
    workers="${workers:-4}"
    local wargs=()
    if [[ "$workers" =~ ^[0-9]+$ ]] && (( workers >= 1 )); then
        wargs=(--workers "$workers")
    else
        warn "Invalid worker count '${workers}', letting marker decide."
    fi

    local staging
    staging=$(mktemp -d "${TMPDIR:-/tmp}/marker-sel.XXXXXX") || { warn "Could not create a staging dir."; return 0; }
    local -A used; local f abs base name i
    for f in "$@"; do
        abs="$(cd "$(dirname "$f")" && pwd)/$(basename "$f")"
        base=$(basename "$f"); name="$base"; i=1
        while [[ -n "${used[$name]:-}" ]]; do          # keep names unique across subfolders
            name="${base%.*}-${i}.${base##*.}"; i=$((i + 1))
        done
        used[$name]=1
        ln -s "$abs" "${staging}/${name}"
    done

    mkdir -p "$OUTPUT_DIR"
    header "Converting"
    info "${#used[@]} file(s) → ${OUTPUT_FORMAT} in ${OUTPUT_DIR}/"
    if "$bin" "$staging" --output_format "$OUTPUT_FORMAT" --output_dir "$OUTPUT_DIR" "${wargs[@]}" "${EXTRA_ARGS[@]}"; then
        success "Done → ${OUTPUT_DIR}/"
        open_path "$OUTPUT_DIR"
    else
        warn "Batch conversion reported errors."
    fi
    rm -rf "$staging"
}

action_convert() {
    require_marker || return
    ensure_surya_backend || true   # OCR needs llama-server on mac/CPU
    header "Convert documents"

    # Pick a folder, scan it (+ subfolders), multi-select the files to convert.
    local picked
    picked=$(pick_files_from_folder) || return 0
    local -a sel
    mapfile -t sel <<< "$picked"
    (( ${#sel[@]} )) || return 0

    select_common_options || return 0

    if (( ${#sel[@]} == 1 )); then
        maybe_page_range "${sel[0]}"     # opt-in range (whole doc by default)
        run_one "${sel[0]}"
    else
        run_selected "${sel[@]}"         # staged batch, whole documents
    fi
}

# -----------------------------------------------------------------------------
# Status / GUI / server / uninstall
# -----------------------------------------------------------------------------

action_status() {
    header "marker status"

    if marker_installed; then
        success "Installed — version $(marker_version)"
    else
        warn "Not installed. Use 'Setup / install' first."
        return
    fi

    command -v marker_single &>/dev/null \
        && info "CLIs on PATH: yes" \
        || warn "CLIs on PATH: no (resolved from pipx venv; run 'pipx ensurepath' to fix)"

    # torch device
    local py device
    if py=$(marker_python); then
        device=$("$py" - <<'PY' 2>/dev/null || echo "unknown"
try:
    import torch
    if torch.cuda.is_available():
        print("cuda")
    elif getattr(torch.backends, "mps", None) and torch.backends.mps.is_available():
        print("mps")
    else:
        print("cpu")
except Exception:
    print("unknown")
PY
)
        info "Torch device: ${device}${TORCH_DEVICE:+ (TORCH_DEVICE=$TORCH_DEVICE overrides)}"
    fi

    # OCR (surya) inference backend + its runtime requirement.
    local be; be="$(surya_backend)"
    info "OCR backend (surya): ${be}${SURYA_INFERENCE_BACKEND:+ (SURYA_INFERENCE_BACKEND=$SURYA_INFERENCE_BACKEND)}"
    if [[ "$be" == "llamacpp" ]]; then
        if llama_server_present; then
            info "llama-server: found ($(command -v llama-server 2>/dev/null || echo "$LLAMA_CPP_BINARY"))"
        else
            warn "llama-server: MISSING — OCR will fail. Install via Setup, or 'brew install llama.cpp'."
        fi
    fi

    # model caches
    local c
    for c in "${HOME}/.cache/datalab" "${HOME}/.cache/huggingface/hub"; do
        if [[ -d "$c" ]]; then
            info "Cache ${c}: $(du -sh "$c" 2>/dev/null | awk '{print $1}')"
        fi
    done

    if [[ -d "${HOME}/.cache/datalab" ]] && gum confirm "Clear marker's model cache (~/.cache/datalab)? Models re-download on next run."; then
        rm -rf "${HOME}/.cache/datalab" && success "Cache cleared."
    fi
}

action_gui() {
    require_marker || return
    ensure_surya_backend || true   # GUI converts too — OCR needs llama-server on mac/CPU
    # marker_gui shells out to `streamlit`, which isn't part of marker-pdf[full].
    ensure_injected streamlit streamlit || { warn "streamlit unavailable — cannot launch the GUI."; return 0; }
    local bin vbin
    bin=$(marker_cli marker_gui) || { warn "marker_gui not found — run Setup first."; return 0; }
    vbin=$(marker_venv_bin 2>/dev/null) || vbin=""
    info "Launching the Streamlit GUI — open http://localhost:8501, press Ctrl-C here to stop and return."
    PATH="${vbin:+$vbin:}$PATH" run_foreground "$bin"
}

action_server() {
    require_marker || return
    ensure_surya_backend || true   # server converts too — OCR needs llama-server on mac/CPU
    # marker_server needs fastapi + uvicorn + python-multipart (not in [full]).
    ensure_injected "fastapi, uvicorn, multipart" fastapi uvicorn python-multipart \
        || { warn "server deps unavailable — cannot launch the API server."; return 0; }
    local bin vbin
    bin=$(marker_cli marker_server) || { warn "marker_server not found — run Setup first."; return 0; }
    vbin=$(marker_venv_bin 2>/dev/null) || vbin=""
    info "Launching the FastAPI server — press Ctrl-C here to stop and return."
    PATH="${vbin:+$vbin:}$PATH" run_foreground "$bin"
}

action_uninstall() {
    header "Uninstall marker"
    marker_installed || { info "marker is not installed."; return; }
    resolve_pipx || error_exit "pipx not found."
    gum confirm "Uninstall ${MARKER_PKG} (its pipx env)? Model caches are kept." || return
    $PIPX uninstall "$MARKER_PKG" && success "marker uninstalled."
}

# =============================================================================
# SERVICE — deploy marker as a scalable containerized ingestion service
# (Redis queue + HTTP enqueue API + worker replicas + batch enqueuer).
# Templates live in templates/service/ (+ k8s/). Static — this drives docker
# compose / kubectl; it does not run the heavy image build here.
# =============================================================================

svc_build() {
    command -v docker &>/dev/null || { warn "docker not found — needed to build the image."; return 0; }
    info "Building ${MARKER_IMAGE} (large: installs torch + deps)..."
    if docker build -t "$MARKER_IMAGE" "$SERVICE_DIR"; then
        success "Built ${MARKER_IMAGE}."
        [[ "$SVC_TARGET" == k8s ]] && info "For K8s, load/push it to the cluster (e.g. 'kind load docker-image ${MARKER_IMAGE}')."
    else
        warn "Build failed."
    fi
}

svc_deploy() {
    if [[ "$SVC_TARGET" == docker ]]; then
        local indir outdir
        indir=$(gum input --value "./input"  --header "Host folder with source documents:") || true
        outdir=$(gum input --value "./output" --header "Host folder for converted output:") || true
        info "Building image + starting stack (first run downloads models — several GB)..."
        MARKER_INPUT="${indir:-./input}" MARKER_OUTPUT="${outdir:-./output}" \
            docker compose -f "$COMPOSE_FILE" up -d --build \
            && success "Service up — API at http://localhost:8000 (POST /jobs)." \
            || warn "docker compose up failed."
    else
        info "Applying manifests to namespace '${K8S_NS}'..."
        kubectl apply -f "${K8S_DIR}/namespace.yaml" || { warn "apply failed."; return 0; }
        kubectl apply -f "${K8S_DIR}/pvc.yaml" -f "${K8S_DIR}/redis.yaml" \
                      -f "${K8S_DIR}/api.yaml" -f "${K8S_DIR}/worker.yaml" \
            && success "Applied. Make image '${MARKER_IMAGE}' available to the cluster (push/registry or 'kind load')." \
            || warn "kubectl apply failed."
        info "Reach the API: kubectl -n ${K8S_NS} port-forward svc/marker-api 8000:8000"
    fi
}

svc_status() {
    if [[ "$SVC_TARGET" == docker ]]; then
        docker compose -f "$COMPOSE_FILE" ps || warn "Is the stack deployed?"
    else
        kubectl -n "$K8S_NS" get pods,svc,pvc || warn "Is the namespace deployed?"
    fi
}

svc_logs() {
    info "Streaming worker logs — Ctrl-C to stop and return."
    if [[ "$SVC_TARGET" == docker ]]; then
        run_foreground docker compose -f "$COMPOSE_FILE" logs -f worker
    else
        run_foreground kubectl -n "$K8S_NS" logs -f deploy/marker-worker
    fi
}

svc_scale() {
    local n
    n=$(gum input --value "2" --header "Number of worker replicas:") || true
    [[ "$n" =~ ^[0-9]+$ ]] || { warn "Not a number: '${n}'."; return 0; }
    if [[ "$SVC_TARGET" == docker ]]; then
        docker compose -f "$COMPOSE_FILE" up -d --scale worker="$n" \
            && success "Workers scaled to ${n}." || warn "Scale failed."
    else
        kubectl -n "$K8S_NS" scale deploy/marker-worker --replicas="$n" \
            && success "Workers scaled to ${n}." || warn "Scale failed."
    fi
}

svc_ingest() {
    if [[ "$SVC_TARGET" == docker ]]; then
        info "Enqueuing every supported file under the mounted /data/input ..."
        docker compose -f "$COMPOSE_FILE" run --rm api python enqueue_batch.py /data/input \
            || warn "Batch enqueue failed (is the stack up?)."
    else
        warn "First ensure your documents are on the 'marker-input' PVC (e.g. via 'kubectl cp')."
        gum confirm "Start the batch enqueue job now?" || return 0
        kubectl -n "$K8S_NS" delete job/marker-batch --ignore-not-found >/dev/null 2>&1
        kubectl apply -f "${K8S_DIR}/batch-job.yaml" \
            && success "Batch job started — watch: kubectl -n ${K8S_NS} logs -f job/marker-batch" \
            || warn "Failed to start batch job."
    fi
}

svc_teardown() {
    if [[ "$SVC_TARGET" == docker ]]; then
        gum confirm "Stop and remove the Docker stack? (named volumes kept)" || return 0
        docker compose -f "$COMPOSE_FILE" down && success "Stack stopped." || warn "compose down failed."
    else
        gum confirm "Delete the marker workloads in namespace '${K8S_NS}'? (PVCs/namespace kept)" || return 0
        kubectl delete -f "${K8S_DIR}/worker.yaml" -f "${K8S_DIR}/api.yaml" -f "${K8S_DIR}/redis.yaml" --ignore-not-found
        info "Data kept. To remove everything: kubectl delete ns ${K8S_NS}"
    fi
}

menu_service() {
    header "Deploy marker as a service"
    if [[ ! -d "$SERVICE_DIR" ]]; then
        warn "Service templates not found at ${SERVICE_DIR}."
        return 0
    fi

    local target
    target=$(gum choose "Docker (compose)" "Kubernetes (kubectl)" \
        --header "Deploy target:") || true
    case "$target" in
        "Docker (compose)")
            command -v docker &>/dev/null || { warn "docker not found."; return 0; }
            docker compose version &>/dev/null || { warn "'docker compose' plugin not available."; return 0; }
            SVC_TARGET=docker ;;
        "Kubernetes (kubectl)")
            command -v kubectl &>/dev/null || { warn "kubectl not found."; return 0; }
            SVC_TARGET=k8s ;;
        *) return 0 ;;
    esac

    while true; do
        local action
        action=$(gum choose \
            "Build image" \
            "Deploy / update" \
            "Status" \
            "Logs (workers)" \
            "Scale workers" \
            "Ingest a folder (batch)" \
            "Tear down" \
            "Back" \
            --header "marker service — ${SVC_TARGET}:") || true
        case "$action" in
            "Build image")               svc_build ;;
            "Deploy / update")           svc_deploy ;;
            "Status")                    svc_status ;;
            "Logs (workers)")            svc_logs ;;
            "Scale workers")             svc_scale ;;
            "Ingest a folder (batch)")   svc_ingest ;;
            "Tear down")                 svc_teardown ;;
            "Back"|"")                   return 0 ;;
        esac
        echo ""
    done
}

# -----------------------------------------------------------------------------
# Local-tool submenu (pipx install on this machine)
# -----------------------------------------------------------------------------

menu_local() {
    while true; do
        local choice
        choice=$(gum choose \
            "Setup / install / upgrade" \
            "Status" \
            "Launch GUI (Streamlit)" \
            "Launch API server" \
            "Uninstall" \
            "Back" \
            --header "Local marker (pipx):") || true
        case "$choice" in
            "Setup / install / upgrade") action_setup ;;
            "Status")                    action_status ;;
            "Launch GUI (Streamlit)")    action_gui ;;
            "Launch API server")         action_server ;;
            "Uninstall")                 action_uninstall ;;
            "Back"|"")                   return 0 ;;
        esac
        echo ""
    done
}

# -----------------------------------------------------------------------------
# Main menu loop
# -----------------------------------------------------------------------------

main() {
    gum style \
        --foreground "$CYAN" --border-foreground "$CYAN" --border double \
        --align center --width 60 --margin "1 2" --padding "1 4" \
        'marker — documents → Markdown / JSON'

    while true; do
        local choice
        choice=$(gum choose \
            "Convert documents" \
            "Local tool  (setup · status · GUI · server · uninstall)" \
            "Deploy as a service  (Docker / K8s)" \
            "Quit" \
            --header "What would you like to do?") || true

        case "$choice" in
            "Convert documents")   action_convert ;;
            "Local tool"*)         menu_local ;;
            "Deploy as a service"*) menu_service ;;
            "Quit"|"")             gum style --faint "Bye."; exit 0 ;;
        esac
        echo ""
    done
}

main "$@"
