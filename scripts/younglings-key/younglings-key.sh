#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# younglings-key.sh — gum front-end for the ignite certificate engine.
#
# scomp-link owns the interactive experience (this file); the generation logic
# lives in the standalone younglings-key engine (ignite.sh, its own repo). This
# shim resolves the engine (local checkout → cache → clone), collects options
# via gum, and runs the engine with the matching flags — the holo-convert pattern.
#
# Engine resolution order:
#   1. $YOUNGLINGS_KEY_DIR/ignite.sh             (explicit override)
#   2. ../../../younglings-key/ignite.sh         (sibling dev checkout)
#   3. ~/.cache/scomp-link/younglings-key/…      (cached clone; offers git pull)
#   4. git clone --depth 1 (public HTTPS)        (first run)
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
command -v git &>/dev/null || { echo "[error] git is required to fetch the engine." >&2; exit 1; }

YK_REPO="${YOUNGLINGS_KEY_REPO:-https://github.com/malahmen/younglings-key.git}"
YK_CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/scomp-link/younglings-key"

ENGINE=""
FLAGS=()

# -----------------------------------------------------------------------------
# Resolve the ignite engine (local → cache → clone).
# -----------------------------------------------------------------------------
resolve_engine() {
    if [[ -n "${YOUNGLINGS_KEY_DIR:-}" && -f "${YOUNGLINGS_KEY_DIR}/ignite.sh" ]]; then
        ENGINE="${YOUNGLINGS_KEY_DIR}/ignite.sh"
        info "Using younglings-key from \$YOUNGLINGS_KEY_DIR: ${YOUNGLINGS_KEY_DIR}"
        return
    fi

    local sib="${SCRIPT_DIR}/../../../younglings-key/ignite.sh"
    if [[ -f "$sib" ]]; then
        ENGINE="$(cd "$(dirname "$sib")" && pwd)/ignite.sh"
        info "Using local younglings-key checkout: $(dirname "$ENGINE")"
        return
    fi

    if [[ -f "${YK_CACHE}/ignite.sh" ]]; then
        ENGINE="${YK_CACHE}/ignite.sh"
        info "Using cached younglings-key: ${YK_CACHE}"
        if [[ -d "${YK_CACHE}/.git" ]] && gum confirm "Update younglings-key (git pull)?"; then
            gum spin --spinner dot --title "Updating younglings-key..." -- \
                git -C "$YK_CACHE" pull --ff-only || warn "Update failed; using the existing copy."
        fi
        return
    fi

    gum confirm "younglings-key engine not found. Clone it from ${YK_REPO}?" \
        || error_exit "younglings-key engine is unavailable."
    mkdir -p "$(dirname "$YK_CACHE")"
    gum spin --spinner dot --title "Cloning younglings-key..." -- \
        git clone --depth 1 "$YK_REPO" "$YK_CACHE" \
        || error_exit "Failed to clone younglings-key from ${YK_REPO}"
    ENGINE="${YK_CACHE}/ignite.sh"
    success "younglings-key cloned to ${YK_CACHE}"
}

# -----------------------------------------------------------------------------
# openssl guardrail (the engine's only dependency) — offer to install it.
# -----------------------------------------------------------------------------
install_openssl() {
    if command -v brew &>/dev/null; then
        gum spin --spinner dot --title "Installing openssl (brew)..." -- brew install openssl
    elif command -v apt-get &>/dev/null; then
        sudo apt-get update -y && sudo apt-get install -y openssl
    elif command -v dnf &>/dev/null; then
        sudo dnf install -y openssl
    else
        warn "No supported package manager found — install openssl manually."
    fi
    command -v openssl &>/dev/null
}

ensure_openssl() {
    command -v openssl &>/dev/null && return 0
    warn "openssl not found — it's required to generate certificates."
    if gum confirm "Install openssl now?"; then
        install_openssl && return 0
    fi
    return 1
}

# -----------------------------------------------------------------------------
# Small helpers
# -----------------------------------------------------------------------------
open_path() {
    if command -v xdg-open &>/dev/null; then xdg-open "$1" &>/dev/null &
    elif command -v open &>/dev/null; then open "$1" &>/dev/null || true
    fi
}

# Trim whitespace + keep only the first line (a pasted value can carry extra).
_clean_input() {
    local s="$1"
    s="${s%%$'\n'*}"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

# Prompt for an existing file path; re-prompts up to 3x. Echoes it (empty = none).
prompt_path() {  # $1 header, $2 placeholder
    local header="$1" placeholder="$2" val try=0
    while (( try < 3 )); do
        try=$(( try + 1 ))
        val=$(_clean_input "$(gum input --header "$header" --placeholder "$placeholder" || true)")
        [[ -z "$val" ]] && return 0
        [[ "$val" == "~"* ]] && val="${val/#\~/$HOME}"
        [[ -f "$val" ]] && { printf '%s' "$val"; return 0; }
        warn "Not a file: ${val} — try again (or leave blank to cancel)."
    done
    return 0
}

# Required domain prompt. Echoes it, or non-zero if cancelled/blank.
prompt_domain() {
    local d; d=$(_clean_input "$(gum input --header "Domain to certify:" --placeholder "example.com" || true)")
    [[ -n "$d" ]] && { printf '%s' "$d"; return 0; }
    warn "A domain is required."; return 1
}

pick_numbits() { gum choose "2048" "3072" "4096" --header "RSA key size:" || echo "2048"; }

# Subject source shared by self-signed + CSR: a subject string or a config file.
# Appends the matching flag(s) to FLAGS. Returns non-zero on cancel.
gather_subject_source() {  # $1 domain
    local how
    how=$(gum choose "Subject string (-i)" "openssl config file (-f)" \
        --header "How to define the subject?") || return 1
    if [[ "$how" == Subject* ]]; then
        local s
        s=$(_clean_input "$(gum input --header "Subject (must include /C= /O= /CN=):" \
            --placeholder "/C=PT/O=Acme/CN=${1}" || true)")
        [[ -n "$s" ]] || { warn "Subject is required."; return 1; }
        FLAGS+=(-i "$s")
    else
        local f
        f=$(prompt_path "Path to openssl config file:" "./certificates/${1}.cfg")
        [[ -n "$f" ]] || { warn "A config file is required."; return 1; }
        FLAGS+=(-f "$f")
    fi
}

# -----------------------------------------------------------------------------
# Modes
# -----------------------------------------------------------------------------
mode_self_signed() {
    local domain; domain=$(prompt_domain) || return
    local numbits; numbits=$(pick_numbits)
    local duration; duration=$(_clean_input "$(gum input --value "3650" --header "Validity in days (1-3650):" || true)")
    duration="${duration:-3650}"
    FLAGS=(-d "$domain" -s 1 -n "$numbits" -t "$duration")
    gather_subject_source "$domain" || { info "Cancelled."; return; }
    local ca
    ca=$(_clean_input "$(gum input --header "CA subject (blank = engine default):" \
        --placeholder "/C=PT/O=Acme/CN=Acme Root CA" || true)")
    [[ -n "$ca" ]] && FLAGS+=(-a "$ca")
    run_engine
}

mode_csr() {
    local domain; domain=$(prompt_domain) || return
    local numbits; numbits=$(pick_numbits)
    FLAGS=(-d "$domain" -s 0 -n "$numbits")
    gather_subject_source "$domain" || { info "Cancelled."; return; }
    run_engine
}

mode_template() {
    local domain; domain=$(prompt_domain) || return
    local numbits; numbits=$(pick_numbits)
    FLAGS=(-d "$domain" -g 1 -n "$numbits")
    run_engine
}

mode_convert() {
    local domain; domain=$(prompt_domain) || return
    FLAGS=(-d "$domain")
    local crt
    crt=$(_clean_input "$(gum input --header "Path to the .crt (or a name under ./certificates):" \
        --placeholder "./certificates/${domain}.crt" || true)")
    [[ -n "$crt" ]] || { warn "A .crt is required."; return; }
    FLAGS+=(-r "$crt")
    if gum confirm "Also produce a .pem? (needs the matching .key)"; then
        local key
        key=$(_clean_input "$(gum input --header "Path to the .key (or a name under ./certificates):" \
            --placeholder "./certificates/${domain}.key" || true)")
        [[ -n "$key" ]] && FLAGS+=(-k "$key")
    fi
    run_engine
}

# -----------------------------------------------------------------------------
# Run the engine with the gathered flags.
# -----------------------------------------------------------------------------
run_engine() {
    ensure_openssl || { warn "openssl unavailable — cannot generate certificates."; return; }
    # Copy-paste-safe preview: %q quotes each arg so subject strings with spaces
    # or slashes don't bleed across flags if reused.
    local preview; printf -v preview ' %q' ignite.sh "${FLAGS[@]}"
    info "Running:${preview}"
    info "Output goes to ./certificates/ under: $(pwd)"
    if bash "$ENGINE" "${FLAGS[@]}"; then
        success "Done."
        [[ -d ./certificates ]] && open_path ./certificates
    else
        warn "ignite.sh reported an error (see the output above)."
    fi
}

# -----------------------------------------------------------------------------
main() {
    resolve_engine
    while true; do
        header "younglings-key — certificates"
        local action
        # Ordered as a typical workflow, for people who don't do this often:
        # prepare a config → make a cert locally → post-process it → (advanced)
        # request one from a real CA.
        action=$(gum choose \
            "Config template (.cfg)" \
            "Self-signed certificate" \
            "Convert .crt → .cert/.pem" \
            "Certificate request (CSR)" \
            "Quit" \
            --header "Certificate task (listed in a typical order):") || exit 0
        case "$action" in
            "Config template (.cfg)")    mode_template ;;
            "Self-signed certificate")   mode_self_signed ;;
            "Convert .crt → .cert/.pem") mode_convert ;;
            "Certificate request (CSR)") mode_csr ;;
            "Quit"|"")                   exit 0 ;;
        esac
    done
}

main "$@"
