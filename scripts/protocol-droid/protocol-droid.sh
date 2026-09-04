#!/usr/bin/env bash
# description: Convert PDF/Office/audio/etc to Markdown (marker or markitdown) via the protocol-droid engine
# -----------------------------------------------------------------------------
# protocol-droid.sh — gum front-end for the protocol-droid document-conversion engine.
#
# scomp-link owns the interactive experience (this file); the logic lives in the
# standalone protocol-droid engine (its own repo), a multi-backend converter:
#   local --backend marker      datalab-to/marker  (high-fidelity PDF/OCR/layout)
#   local --backend markitdown  Microsoft markitdown (fast, broad; audio/YouTube/ZIP)
#   local --backend auto        route each file by type
#   service                     containerized marker workers (Docker / K8s)
# This shim resolves the engine, gathers options with gum, and runs it by flags —
# the holo-convert / navicomputer / mind-trick pattern.
#
# Engine resolution order:
#   1. $PROTOCOL_DROID_DIR/protocol-droid.sh      (explicit override)
#   2. ../../../protocol-droid/protocol-droid.sh  (sibling dev checkout)
#   3. ~/.cache/scomp-link/protocol-droid/…       (cached clone; offers git pull)
#   4. git clone --depth 1 (public HTTPS)         (first run)
# -----------------------------------------------------------------------------

if [[ "${BASH_VERSINFO[0]:-0}" -lt 4 ]]; then
    echo "[error] bash 4+ required (you have ${BASH_VERSION}). On macOS: brew install bash" >&2
    exit 1
fi

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../_common/ui.sh
source "${SCRIPT_DIR}/../_common/ui.sh"

command -v gum &>/dev/null || { echo "[error] gum is required. Run setup.sh first." >&2; exit 1; }
command -v git &>/dev/null || { echo "[error] git is required." >&2; exit 1; }

PD_REPO="${PROTOCOL_DROID_REPO:-https://github.com/malahmen/protocol-droid.git}"
PD_CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/scomp-link/protocol-droid"
DEFAULT_OUTPUT_DIR="./converted"
# markitdown pip extras (kept in sync with the engine) for the setup picker.
MID_EXTRAS=(pptx docx xlsx xls pdf outlook az-doc-intel az-content-understanding audio-transcription youtube-transcription)
ENGINE=""

trap 'echo ""; gum style --faint "Interrupted."; exit 0' INT TERM

# -----------------------------------------------------------------------------
# Engine resolution
# -----------------------------------------------------------------------------
resolve_engine() {
    if [[ -n "${PROTOCOL_DROID_DIR:-}" && -f "${PROTOCOL_DROID_DIR}/protocol-droid.sh" ]]; then
        ENGINE="${PROTOCOL_DROID_DIR}/protocol-droid.sh"; info "Using protocol-droid from \$PROTOCOL_DROID_DIR: ${PROTOCOL_DROID_DIR}"; return
    fi
    local sib="${SCRIPT_DIR}/../../../protocol-droid/protocol-droid.sh"
    if [[ -f "$sib" ]]; then
        ENGINE="$(cd "$(dirname "$sib")" && pwd)/protocol-droid.sh"; info "Using local protocol-droid checkout: $(dirname "$ENGINE")"; return
    fi
    if [[ -f "${PD_CACHE}/protocol-droid.sh" ]]; then
        ENGINE="${PD_CACHE}/protocol-droid.sh"; info "Using cached protocol-droid: ${PD_CACHE}"
        if [[ -d "${PD_CACHE}/.git" ]] && gum confirm "Update protocol-droid (git pull)?"; then
            gum spin --spinner dot --title "Updating protocol-droid..." -- git -C "$PD_CACHE" pull --ff-only || warn "Update failed; using existing copy."
        fi
        return
    fi
    gum confirm "protocol-droid engine not found. Clone it from ${PD_REPO}?" || error_exit "protocol-droid engine is unavailable."
    mkdir -p "$(dirname "$PD_CACHE")"
    gum spin --spinner dot --title "Cloning protocol-droid..." -- git clone --depth 1 "$PD_REPO" "$PD_CACHE" \
        || error_exit "Failed to clone protocol-droid from ${PD_REPO}"
    ENGINE="${PD_CACHE}/protocol-droid.sh"; success "protocol-droid cloned to ${PD_CACHE}"
}

engine() { bash "$ENGINE" "$@"; }
# Foreground engine command (setup/gui/server/logs) — Ctrl-C stops just the child.
engine_foreground() {
    trap ':' INT
    bash "$ENGINE" "$@" || true
    trap 'echo ""; gum style --faint "Interrupted."; exit 0' INT TERM
}

# -----------------------------------------------------------------------------
# Source selection (shared by every backend). Fills PICKED_PATHS[].
# Scans with markitdown's (superset) extension list so 'auto' sees everything.
# -----------------------------------------------------------------------------
PICKED_PATHS=()
pick_source() {
    PICKED_PATHS=()
    local scan_backend="$1"; [[ "$scan_backend" == auto ]] && scan_backend=markitdown
    local method
    method=$(gum choose "Scan a folder → pick files" "Enter a path (file or folder)" \
        --header "How do you want to choose the source?") || return 1
    case "$method" in
        "Scan a folder → pick files")
            local dir; dir=$(gum input --value "." --header "Folder to scan (subfolders included):") || return 1
            dir="${dir/#\~/$HOME}"; dir="${dir:-.}"
            [[ -d "$dir" ]] || { warn "Not a folder: ${dir}"; return 1; }
            local found; found=$(engine local scan --backend "$scan_backend" "$dir" 2>/dev/null) \
                || { warn "No supported files under ${dir}."; return 1; }
            local count height picked
            count=$(printf '%s\n' "$found" | wc -l | tr -d ' ')
            height=$(( count < 15 ? count + 2 : 17 ))
            picked=$(printf '%s\n' "$found" | gum choose --no-limit --height "$height" \
                --header "Select file(s) — SPACE to toggle, ENTER to confirm (${count} found):") || return 1
            [[ -z "$picked" ]] && { gum style --faint "Nothing selected."; return 1; }
            mapfile -t PICKED_PATHS <<< "$picked" ;;
        "Enter a path (file or folder)")
            local src; src=$(gum input --header "Enter a path to a file or folder:" \
                --placeholder "/path/to/file.pdf   or   /path/to/folder") || return 1
            src="${src/#\~/$HOME}"; [[ -n "$src" ]] || return 1
            [[ -e "$src" ]] || { warn "Path not found: ${src}"; return 1; }
            PICKED_PATHS=("$src") ;;
        *) return 1 ;;
    esac
    return 0
}

# -----------------------------------------------------------------------------
# marker: LLM picker + convert options → EXTRA_ARGS[] / OUTPUT_FORMAT / OUTPUT_DIR
# -----------------------------------------------------------------------------
LLM_ARGS=()
build_llm_args() {
    LLM_ARGS=()
    local svc
    svc=$(gum choose "Google Gemini (default)" "OpenAI / OpenAI-compatible" "Anthropic Claude" "Ollama (local)" \
        --header "Select the LLM service for --use_llm:") || true
    [[ -z "$svc" ]] && { gum style --faint "Cancelled."; return 1; }
    _key() {
        local env_name="$1" label="$2" val=""
        if [[ -n "${!env_name:-}" ]]; then info "Using ${env_name} from environment."; printf '%s' "${!env_name}"; return; fi
        val=$(gum input --password --header "Enter ${label} (leave empty to rely on env/config):") || true
        printf '%s' "$val"
    }
    case "$svc" in
        "Google Gemini (default)")
            LLM_ARGS+=(--llm_service marker.services.gemini.GoogleGeminiService)
            local k; k=$(_key GEMINI_API_KEY "Gemini API key"); [[ -n "$k" ]] && LLM_ARGS+=(--gemini_api_key "$k") ;;
        "OpenAI / OpenAI-compatible")
            LLM_ARGS+=(--llm_service marker.services.openai.OpenAIService)
            local b; b=$(gum input --header "Base URL (blank = OpenAI cloud; local e.g. http://192.168.1.50:1234/v1):") || true
            [[ -n "$b" ]] && LLM_ARGS+=(--openai_base_url "$b")
            local k; k=$(_key OPENAI_API_KEY "API key (a local server usually ignores this — any non-empty value)")
            [[ -n "$k" ]] && LLM_ARGS+=(--openai_api_key "$k")
            local m; m=$(gum input --header "Model name (blank = marker default; local server: the loaded vision model id):") || true
            [[ -n "$m" ]] && LLM_ARGS+=(--openai_model "$m") ;;
        "Anthropic Claude")
            LLM_ARGS+=(--llm_service marker.services.claude.ClaudeService)
            local k; k=$(_key ANTHROPIC_API_KEY "Anthropic API key"); [[ -n "$k" ]] && LLM_ARGS+=(--claude_api_key "$k")
            local m; m=$(gum input --header "Claude model name (blank = marker default):") || true
            [[ -n "$m" ]] && LLM_ARGS+=(--claude_model_name "$m") ;;
        "Ollama (local)")
            LLM_ARGS+=(--llm_service marker.services.ollama.OllamaService)
            local url; url=$(gum input --value "http://localhost:11434" --header "Ollama base URL:") || true
            [[ -n "$url" ]] && LLM_ARGS+=(--ollama_base_url "$url")
            local m; m=$(gum input --header "Ollama model (e.g. llama3.2-vision):") || true
            [[ -n "$m" ]] && LLM_ARGS+=(--ollama_model "$m") ;;
    esac
    info "LLM service configured."
}

EXTRA_ARGS=(); OUTPUT_FORMAT=""; OUTPUT_DIR=""
select_marker_options() {
    EXTRA_ARGS=()
    local fmt; fmt=$(gum choose "markdown" "json" "html" "chunks" --header "Output format:") || return 1
    [[ -z "$fmt" ]] && return 1
    OUTPUT_FORMAT="$fmt"
    OUTPUT_DIR=$(gum input --value "$DEFAULT_OUTPUT_DIR" --header "Output directory:") || return 1
    OUTPUT_DIR="${OUTPUT_DIR:-$DEFAULT_OUTPUT_DIR}"
    gum confirm "Force OCR on the whole document? (slower, fixes bad embedded text)" && EXTRA_ARGS+=(--force_ocr)
    if gum confirm "Use an LLM to improve quality? (--use_llm)"; then
        EXTRA_ARGS+=(--use_llm); build_llm_args || return 1; EXTRA_ARGS+=("${LLM_ARGS[@]}")
    fi
    return 0
}

select_markitdown_options() {
    EXTRA_ARGS=()
    OUTPUT_DIR=$(gum input --value "$DEFAULT_OUTPUT_DIR" --header "Output directory:") || return 1
    OUTPUT_DIR="${OUTPUT_DIR:-$DEFAULT_OUTPUT_DIR}"
    gum confirm "Use installed markitdown plugins? (--use-plugins)" && EXTRA_ARGS+=(--use-plugins)
    if gum confirm "Use Azure Document Intelligence for richer extraction? (-d)"; then
        EXTRA_ARGS+=(-d)
        local ep="${MARKITDOWN_DOCINTEL_ENDPOINT:-}"
        if [[ -n "$ep" ]]; then info "Using MARKITDOWN_DOCINTEL_ENDPOINT from environment."
        else
            ep=$(gum input --header "Document Intelligence endpoint (https://<resource>.cognitiveservices.azure.com/):") || true
            [[ -n "$ep" ]] && EXTRA_ARGS+=(-e "$ep") || warn "No endpoint given — markitdown will look for MARKITDOWN_DOCINTEL_ENDPOINT."
        fi
    fi
    return 0
}

# -----------------------------------------------------------------------------
# Convert
# -----------------------------------------------------------------------------
action_convert() {
    header "Convert documents"
    local backend
    backend=$(gum choose \
        "marker  — high-fidelity PDF / OCR / layout (heavy)" \
        "markitdown  — fast, broad formats; audio / YouTube / ZIP (light)" \
        "auto  — route each file (PDF/images → marker, rest → markitdown)" \
        --header "Which converter?") || return 0
    case "$backend" in
        marker*)     backend=marker ;;
        markitdown*) backend=markitdown ;;
        auto*)       backend=auto ;;
        *) return 0 ;;
    esac

    pick_source "$backend" || { info "Cancelled."; return 0; }

    case "$backend" in
        marker)
            select_marker_options || { info "Cancelled."; return 0; }
            local pos=()
            if (( ${#PICKED_PATHS[@]} == 1 )) && [[ -f "${PICKED_PATHS[0]}" ]]; then
                local pr; pr=$(gum input --header "Page range (blank = all), e.g. 0,5-10,20:") || true
                [[ -n "$pr" ]] && pos+=(--page-range "$pr")
            else
                local w; w=$(gum input --value "4" --header "Parallel workers (each ~3.5GB RAM/VRAM):") || true
                [[ "$w" =~ ^[0-9]+$ ]] && pos+=(--workers "$w") || warn "Invalid worker count — letting the engine decide."
            fi
            header "Converting"
            engine local convert --backend marker --output-format "$OUTPUT_FORMAT" --output-dir "$OUTPUT_DIR" \
                "${pos[@]}" "${PICKED_PATHS[@]}" ${EXTRA_ARGS:+--} "${EXTRA_ARGS[@]}" ;;
        markitdown)
            select_markitdown_options || { info "Cancelled."; return 0; }
            header "Converting"
            engine local convert --backend markitdown --output-dir "$OUTPUT_DIR" \
                "${PICKED_PATHS[@]}" ${EXTRA_ARGS:+--} "${EXTRA_ARGS[@]}" ;;
        auto)
            OUTPUT_DIR=$(gum input --value "$DEFAULT_OUTPUT_DIR" --header "Output directory:") || return 0
            OUTPUT_DIR="${OUTPUT_DIR:-$DEFAULT_OUTPUT_DIR}"
            header "Converting"
            engine local convert --backend auto --output-dir "$OUTPUT_DIR" "${PICKED_PATHS[@]}" ;;
    esac
}

# -----------------------------------------------------------------------------
# Local tool — per-backend pipx management
# -----------------------------------------------------------------------------
menu_local_marker() {
    while true; do
        local c
        c=$(gum choose "Setup / install" "Upgrade" "Status" "Launch GUI (Streamlit)" \
            "Launch API server" "Clear model cache" "Uninstall" "Back" \
            --header "Local marker (pipx):") || true
        case "$c" in
            "Setup / install")        engine_foreground local setup --backend marker ;;
            "Upgrade")                engine_foreground local setup --backend marker --upgrade ;;
            "Status")                 engine local status --backend marker ;;
            "Launch GUI (Streamlit)") engine_foreground local gui --backend marker ;;
            "Launch API server")      engine_foreground local server --backend marker ;;
            "Clear model cache")      gum confirm "Delete ~/.cache/datalab? Models re-download next run." && engine local clear-cache --backend marker --yes ;;
            "Uninstall")              gum confirm "Uninstall marker's pipx env? (model caches kept)" && engine local uninstall --backend marker --yes ;;
            "Back"|"")                return 0 ;;
        esac
        echo ""
    done
}

markitdown_setup_flags() {   # echoes optional "--extras <csv>"
    local mode
    mode=$(gum choose "All formats  (markitdown[all], recommended)" "Pick specific formats" \
        --header "Which format support to install?") || return 1
    [[ "$mode" == "Pick specific formats" ]] || return 0
    local picked; picked=$(printf '%s\n' "${MID_EXTRAS[@]}" | gum choose --no-limit --height 14 \
        --header "Select extras — SPACE to toggle, ENTER to confirm:") || return 0
    [[ -z "$picked" ]] && return 0
    local joined; joined=$(printf '%s,' $picked); joined="${joined%,}"
    printf -- '--extras %s' "$joined"
}

menu_local_markitdown() {
    while true; do
        local c
        c=$(gum choose "Setup / install" "Upgrade" "Status" "Install a plugin" "Uninstall" "Back" \
            --header "Local markitdown (pipx):") || true
        case "$c" in
            "Setup / install")
                local ef; ef=$(markitdown_setup_flags) || { echo ""; continue; }
                # shellcheck disable=SC2086
                engine_foreground local setup --backend markitdown $ef ;;
            "Upgrade")   engine_foreground local setup --backend markitdown --upgrade ;;
            "Status")    engine local status --backend markitdown ;;
            "Install a plugin")
                local pkg; pkg=$(gum input --header "Plugin pip package (e.g. markitdown-sample-plugin):") || true
                [[ -n "$pkg" ]] && engine local install-plugin --backend markitdown "$pkg" || gum style --faint "Cancelled." ;;
            "Uninstall") gum confirm "Uninstall markitdown's pipx env?" && engine local uninstall --backend markitdown --yes ;;
            "Back"|"")   return 0 ;;
        esac
        echo ""
    done
}

menu_local() {
    local backend
    backend=$(gum choose "marker  (high-fidelity)" "markitdown  (fast, broad)" "Back" \
        --header "Manage which local converter?") || return 0
    case "$backend" in
        marker*)     menu_local_marker ;;
        markitdown*) menu_local_markitdown ;;
        *) return 0 ;;
    esac
}

# -----------------------------------------------------------------------------
# Service submenu (marker-only containerized deployment)
# -----------------------------------------------------------------------------
menu_service() {
    header "Deploy the conversion service (marker workers)"
    local target flag
    target=$(gum choose "Docker (compose)" "Kubernetes (kubectl)" --header "Deploy target:") || true
    case "$target" in
        "Docker (compose)")
            command -v docker &>/dev/null || { warn "docker not found."; return 0; }
            docker compose version &>/dev/null || { warn "'docker compose' plugin not available."; return 0; }
            flag=docker ;;
        "Kubernetes (kubectl)")
            command -v kubectl &>/dev/null || { warn "kubectl not found."; return 0; }
            flag=k8s ;;
        *) return 0 ;;
    esac
    while true; do
        local action
        action=$(gum choose "Build image" "Deploy / update" "Status" "Logs (workers)" \
            "Scale workers" "Enqueue a folder (batch)" "Tear down" "Back" \
            --header "protocol-droid service — ${flag}:") || true
        case "$action" in
            "Build image")    engine_foreground service build --target "$flag" ;;
            "Deploy / update")
                if [[ "$flag" == docker ]]; then
                    local indir outdir
                    indir=$(gum input --value "./input"  --header "Host folder with source documents:") || true
                    outdir=$(gum input --value "./output" --header "Host folder for converted output:") || true
                    engine_foreground service deploy --target docker --input "${indir:-./input}" --output "${outdir:-./output}"
                else engine_foreground service deploy --target k8s; fi ;;
            "Status")         engine service status --target "$flag" ;;
            "Logs (workers)") engine_foreground service logs --target "$flag" ;;
            "Scale workers")
                local n; n=$(gum input --value "2" --header "Number of worker replicas:") || true
                [[ "$n" =~ ^[0-9]+$ ]] && engine service scale --target "$flag" --replicas "$n" || warn "Not a number: '${n}'." ;;
            "Enqueue a folder (batch)")
                if [[ "$flag" == docker ]]; then engine service enqueue --target docker
                else
                    warn "First ensure your documents are on the 'marker-input' PVC (e.g. via 'kubectl cp')."
                    gum confirm "Start the batch enqueue job now?" && engine service enqueue --target k8s
                fi ;;
            "Tear down")      gum confirm "Tear down the ${flag} stack? (data/volumes kept)" && engine service teardown --target "$flag" --yes ;;
            "Back"|"")        return 0 ;;
        esac
        echo ""
    done
}

# -----------------------------------------------------------------------------
# Main menu loop
# -----------------------------------------------------------------------------
main() {
    resolve_engine
    gum style \
        --foreground "$CYAN" --border-foreground "$CYAN" --border double \
        --align center --width 62 --margin "1 2" --padding "1 4" \
        'protocol-droid — documents → Markdown (marker · markitdown)'

    while true; do
        local choice
        choice=$(gum choose \
            "Convert documents" \
            "Local tool  (setup · status · manage a backend)" \
            "Deploy as a service  (Docker / K8s · marker)" \
            "Quit" \
            --header "What would you like to do?") || true
        case "$choice" in
            "Convert documents")     action_convert ;;
            "Local tool"*)           menu_local ;;
            "Deploy as a service"*)  menu_service ;;
            "Quit"|"")               gum style --faint "Bye."; exit 0 ;;
        esac
        echo ""
    done
}

main "$@"
