#!/usr/bin/env bash
# description: TODO one-line summary — front-end for the <name> engine
# -----------------------------------------------------------------------------
# TEMPLATE — gum front-end for a standalone, flag-driven engine.
#
# The scomp-link split pattern (holo-convert, navicomputer, mind-trick,
# protocol-droid, younglings-key, akinn): the real logic lives in its OWN repo as
# a gum-free, flag-driven CLI ("the engine"); this file is just the interactive
# front-end that resolves the engine, collects options with gum, and runs the
# engine by flags. New reusable tools should be built this way from the start.
#
# HOW TO USE: copy to scripts/<name>/<name>.sh, replace FOO/foo and the repo URL,
# and build the real flags in main(). Delete this block.
#
# Engine resolution order:
#   1. $FOO_DIR/foo.sh                     (explicit override — a checkout you control)
#   2. ../../../foo/foo.sh                 (sibling dev checkout next to scomp-link)
#   3. ~/.cache/scomp-link/foo/…           (cached clone; offers git pull)
#   4. git clone --depth 1 (public HTTPS)  (first run)
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

# TODO: rename FOO/foo and point at the engine's public repo.
FOO_REPO="${FOO_REPO:-https://github.com/OWNER/foo.git}"
FOO_CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/scomp-link/foo"
ENGINE=""

trap 'echo ""; gum style --faint "Interrupted."; exit 0' INT TERM

resolve_engine() {
    if [[ -n "${FOO_DIR:-}" && -f "${FOO_DIR}/foo.sh" ]]; then
        ENGINE="${FOO_DIR}/foo.sh"; info "Using foo from \$FOO_DIR: ${FOO_DIR}"; return
    fi
    local sib="${SCRIPT_DIR}/../../../foo/foo.sh"
    if [[ -f "$sib" ]]; then
        ENGINE="$(cd "$(dirname "$sib")" && pwd)/foo.sh"; info "Using local foo checkout: $(dirname "$ENGINE")"; return
    fi
    if [[ -f "${FOO_CACHE}/foo.sh" ]]; then
        ENGINE="${FOO_CACHE}/foo.sh"; info "Using cached foo: ${FOO_CACHE}"
        if [[ -d "${FOO_CACHE}/.git" ]] && gum confirm "Update foo (git pull)?"; then
            gum spin --spinner dot --title "Updating foo..." -- git -C "$FOO_CACHE" pull --ff-only || warn "Update failed; using existing copy."
        fi
        return
    fi
    gum confirm "foo engine not found. Clone it from ${FOO_REPO}?" || error_exit "foo engine is unavailable."
    mkdir -p "$(dirname "$FOO_CACHE")"
    gum spin --spinner dot --title "Cloning foo..." -- git clone --depth 1 "$FOO_REPO" "$FOO_CACHE" \
        || error_exit "Failed to clone foo from ${FOO_REPO}"
    ENGINE="${FOO_CACHE}/foo.sh"; success "foo cloned to ${FOO_CACHE}"
}

# Run the engine. Use engine_foreground for long-lived/streaming commands so
# Ctrl-C stops just the child and returns to the menu.
engine()            { bash "$ENGINE" "$@"; }
engine_foreground() {
    trap ':' INT
    bash "$ENGINE" "$@" || true
    trap 'echo ""; gum style --faint "Interrupted."; exit 0' INT TERM
}

# Example: collect options with gum and hand them to the engine as flags.
# Keep ALL interactivity here; the engine stays gum-free and flag-only.
action_do_thing() {
    header "Foo — do thing"
    local input; input=$(gum input --header "Some value the engine needs:") || return 0
    [[ -n "$input" ]] || { warn "A value is required."; return 0; }
    # TODO: map gum answers to the engine's real flags.
    engine do-thing --value "$input"
}

main() {
    resolve_engine
    gum style --foreground "$CYAN" --border-foreground "$CYAN" --border double \
        --align center --width 60 --margin "1 2" --padding "1 4" "foo — TODO tagline"
    while true; do
        case "$(gum choose "Do thing" "Setup deps" "Quit" --header "What would you like to do?")" in
            "Do thing")   action_do_thing ;;
            "Setup deps") engine_foreground --setup ;;   # TODO: engine's real setup flag, if any
            "Quit"|"")    gum style --faint "Bye."; exit 0 ;;
        esac
        echo ""
    done
}

main "$@"
