#!/usr/bin/env bash
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

MARKER_PKG="marker-pdf"          # the pip package name
MARKER_SPEC="marker-pdf[full]"   # [full] = non-PDF inputs (docx/pptx/xlsx/epub/html)
DEFAULT_OUTPUT_DIR="./marker-output"
DEFAULT_DEPTH=3
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
        "OpenAI" \
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
        "OpenAI")
            LLM_ARGS+=(--llm_service marker.services.openai.OpenAIService)
            local k; k=$(_key OPENAI_API_KEY "OpenAI API key")
            [[ -n "$k" ]] && LLM_ARGS+=(--openai_api_key "$k")
            local m; m=$(gum input --header "OpenAI model (blank = marker default):") || true
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

# Choose a source by scanning the current folder tree. Echoes the selected file
# path on stdout; returns 1 (with a message) if nothing is found or cancelled.
detect_source_file() {
    info "Scanning for supported files (depth ${DEFAULT_DEPTH})..." >&2
    local find_args=() ext
    for ext in "${INPUT_EXTS[@]}"; do
        find_args+=(-iname "*.${ext}" -o)
    done
    unset 'find_args[${#find_args[@]}-1]'   # drop trailing -o

    local found
    found=$(find . -maxdepth "$DEFAULT_DEPTH" -type f \( "${find_args[@]}" \) \
        ! -path "*/node_modules/*" ! -path "*/.git/*" \
        ! -path "*/${DEFAULT_OUTPUT_DIR#./}/*" ! -path "*/marker-output/*" \
        | sed 's|^\./||' | sort)

    [[ -z "$found" ]] && { warn "No supported files found within depth ${DEFAULT_DEPTH}."; return 1; }

    local count height file
    count=$(echo "$found" | wc -l | tr -d ' ')
    height=$(( count < 15 ? count + 2 : 17 ))
    file=$(echo "$found" | gum choose --height "$height" \
        --header "Select a file to convert:") || true
    [[ -z "$file" ]] && { gum style --faint "Cancelled." >&2; return 1; }
    printf '%s' "$file"
}

# Ask the user to type a path to a file OR folder. Echoes the (existing) path on
# stdout; returns 1 (with a message) if empty or not found.
prompt_source_path() {
    local p
    p=$(gum input --header "Enter a path to a file or folder:" \
        --placeholder "/path/to/file.pdf   or   /path/to/folder") || true
    [[ -z "$p" ]] && { gum style --faint "Cancelled." >&2; return 1; }
    p="${p/#\~/$HOME}"   # expand a leading ~
    [[ -e "$p" ]] || { warn "Path not found: ${p}"; return 1; }
    printf '%s' "$p"
}

# Convert a single file (marker_single); prompts for an optional page range.
run_single() {
    local file="$1"
    local page_range
    page_range=$(gum input --header "Page range (blank = all), e.g. 0,5-10,20:") || true
    [[ -n "$page_range" ]] && EXTRA_ARGS+=(--page_range "$page_range")

    local bin; bin=$(marker_cli marker_single) || { warn "marker_single not found — run Setup first."; return 0; }
    mkdir -p "$OUTPUT_DIR"

    header "Converting"
    info "${file} → ${OUTPUT_FORMAT} in ${OUTPUT_DIR}/"
    # Run directly (no spinner): marker prints its own progress and may download
    # models on first run.
    if "$bin" "$file" --output_format "$OUTPUT_FORMAT" --output_dir "$OUTPUT_DIR" "${EXTRA_ARGS[@]}"; then
        success "Done → ${OUTPUT_DIR}/"
        open_path "$OUTPUT_DIR"
    else
        warn "Conversion failed for: ${file}"
    fi
}

# Batch-convert every supported file in a folder (marker); prompts for workers.
run_batch() {
    local in_dir="$1"
    local workers
    workers=$(gum input --value "4" --header "Parallel workers (each ~3.5GB RAM/VRAM):") || true
    workers="${workers:-4}"
    if [[ "$workers" =~ ^[0-9]+$ ]] && (( workers >= 1 )); then
        EXTRA_ARGS+=(--workers "$workers")
    else
        warn "Invalid worker count '${workers}', letting marker decide."
    fi

    ensure_marker_deps   # batch CLI needs psutil (not pulled by marker-pdf[full])
    local bin; bin=$(marker_cli marker) || { warn "marker (batch CLI) not found — run Setup first."; return 0; }
    mkdir -p "$OUTPUT_DIR"

    header "Converting"
    info "${in_dir}/ → ${OUTPUT_FORMAT} in ${OUTPUT_DIR}/"
    if "$bin" "$in_dir" --output_format "$OUTPUT_FORMAT" --output_dir "$OUTPUT_DIR" "${EXTRA_ARGS[@]}"; then
        success "Done → ${OUTPUT_DIR}/"
        open_path "$OUTPUT_DIR"
    else
        warn "Batch conversion reported errors."
    fi
}

action_convert() {
    require_marker || return
    header "Convert documents"

    # Pick HOW to choose the source: scan-and-detect, or type a path.
    local method
    method=$(gum choose \
        "Detect files (scan this folder)" \
        "Enter a path (file or folder)" \
        --header "How do you want to choose the source?") || true

    local src=""
    case "$method" in
        "Detect files (scan this folder)") src=$(detect_source_file) || return 0 ;;
        "Enter a path (file or folder)")   src=$(prompt_source_path) || return 0 ;;
        *) gum style --faint "Cancelled."; return 0 ;;
    esac
    [[ -z "$src" ]] && return 0

    select_common_options || return 0

    # A folder → batch; anything else → single file.
    if [[ -d "$src" ]]; then
        run_batch "$src"
    else
        run_single "$src"
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
