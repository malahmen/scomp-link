#!/usr/bin/env bash
# The protocol-droid front-end, driven through the gum stub against a fake
# engine (PROTOCOL_DROID_DIR) that answers `local scan` and records every other
# call, one per line, its arguments joined with '|', plus the API key it found
# in its environment.
#
# What it protects: a relative path starting with "-" reaches the engine as
# ./-path, never as something it reads as a flag (Kamino 196) - typed, picked
# from a scan of ".", or as the folder scanned; an LLM API key reaches the
# engine in its environment and never on argv; clearing the model cache,
# uninstalling a backend and tearing a stack down do nothing on Enter or no
# (--default=false); Esc returns to the menu; each path's flags.
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FRONT="${TEST_DIR}/../scripts/protocol-droid/protocol-droid.sh"
[[ -f "$FRONT" ]] || { echo "front-end not found at $FRONT" >&2; exit 1; }
if [[ "${BASH_VERSINFO[0]:-0}" -lt 4 ]]; then
    for b in /opt/homebrew/bin/bash /usr/local/bin/bash; do [[ -x "$b" ]] && exec "$b" "$0" "$@"; done
    echo "SKIP - bash 4+ not found (the front-end needs it)"; exit 77
fi

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
FAILS=0
check() { local d="$1"; shift; if "$@"; then echo "   ok   - $d"; else echo "   FAIL - $d"; FAILS=$((FAILS + 1)); fi; }

mkdir -p "$T/engine" "$T/bin" "$T/home" "$T/work/-notes"
: > "$T/work/-notes/a.pdf"; : > "$T/work/doc.pdf"
cat > "$T/engine/protocol-droid.sh" <<EOF
#!/usr/bin/env bash
# As the engine's scan: the files under the folder, as "folder/name" - with
# no leading ./ when the folder is ".".
if [[ "\${1:-} \${2:-}" == "local scan" ]]; then
    d="\${@: -1}"
    if [[ "\$d" == . ]]; then printf -- '-notes/a.pdf\ndoc.pdf\n'; else printf '%s/a.pdf\n' "\${d%/}"; fi
    exit 0
fi
(IFS='|'; printf '%s\n' "\$*") >> "$T/calls"
printf '%s\n' "\${GOOGLE_API_KEY:-}" > "$T/env-key"
exit 0
EOF
# docker (with compose) and podman only have to exist for the menus to open.
printf '#!/bin/sh\nexit 0\n' > "$T/bin/docker"
printf '#!/bin/sh\nexit 0\n' > "$T/bin/podman"
cp "${TEST_DIR}/stubs/gum" "$T/bin/gum"
chmod +x "$T/bin/"*

CONVERT="Convert documents"
MARKER="marker  — high-fidelity PDF / OCR / layout (heavy)"
MID="markitdown  — fast, broad formats; audio / YouTube / ZIP (light)"
AUTO="auto  — route each file (PDF/images → marker, rest → markitdown)"
SCAN="Scan a folder → pick files"
PATHIN="Enter a path (file or folder)"
LOCAL="Local tool  (setup · status · manage a backend)"
CONTAINER="marker in a container  (nothing installed · convert · benchmark)"
SERVICE="Deploy as a service  (Docker / K8s · marker)"

# drive <answer>... - one answer per prompt, in order; the session ends at Quit.
drive() {
    printf '%s\n' "$@" > "$T/answers"
    rm -f "$T/calls" "$T/state" "$T/env-key"; : > "$T/calls"
    (cd "$T/work" && env -u GOOGLE_API_KEY -u GEMINI_API_KEY PATH="$T/bin:$PATH" HOME="$T/home" \
        GUM_ANSWERS="$T/answers" GUM_STATE="$T/state" PROTOCOL_DROID_DIR="$T/engine" \
        "$BASH" "$FRONT") > "$T/out" 2>&1
}
called()     { grep -qxF -- "$1" "$T/calls"; }
not_called() { ! grep -q -- "$1" "$T/calls"; }
no_calls()   { [[ ! -s "$T/calls" ]]; }
at_quit()    { grep -q '<choose> Quit' "$T/out"; }

echo "# a path starting with - is a path, not a flag (Kamino 196)"
drive "$CONVERT" "$MID" "$PATHIN" "-notes/" "" enter no no Quit
check "typed -notes/: reaches the engine as ./-notes/" called "local|convert|--backend|markitdown|--output-dir|./converted|./-notes/"
drive "$CONVERT" "$MARKER" "$SCAN" "" "-notes/a.pdf" markdown "" no no "" Quit
check "picked from a scan of '.': ./-notes/a.pdf" called "local|convert|--backend|marker|--output-format|markdown|--output-dir|./converted|./-notes/a.pdf"
drive "$CONVERT" "$AUTO" "$SCAN" "-notes" "./-notes/a.pdf" "" Quit
check "the folder scanned is ./-notes" bash -c 'grep -q "<option> ./-notes/a.pdf" "$1"' _ "$T/out"
check "  and its file converts as ./-notes/a.pdf" called "local|convert|--backend|auto|--output-dir|./converted|./-notes/a.pdf"
drive "$CONTAINER" "$CONVERT" "$PATHIN" "-notes/a.pdf" markdown "" no Back Quit
check "the container convert too" called "container|convert|--output-format|markdown|--output-dir|./converted|./-notes/a.pdf"
drive "$CONVERT" "$MID" "$PATHIN" "doc.pdf" "" enter no no Quit
check "a path not starting with - is left alone" called "local|convert|--backend|markitdown|--output-dir|./converted|doc.pdf"

echo "# an API key travels in the environment"
drive "$CONVERT" "$MARKER" "$PATHIN" "doc.pdf" markdown "" no yes "Google Gemini (default)" "sekrit-key" "" Quit
check "marker with an LLM: the service after --" called "local|convert|--backend|marker|--output-format|markdown|--output-dir|./converted|doc.pdf|--|--use_llm|--llm_service|marker.services.gemini.GoogleGeminiService"
check "  the key is in no argument" not_called "sekrit"
check "  the engine has it as GOOGLE_API_KEY" [ "$(cat "$T/env-key" 2>/dev/null)" = sekrit-key ]

echo "# options"
drive "$CONVERT" "$MID" "$PATHIN" "doc.pdf" "out dir" yes yes no Quit
check "markitdown: --no-clobber and --use-plugins, the output dir one argument" called "local|convert|--backend|markitdown|--output-dir|out dir|--no-clobber|doc.pdf|--|--use-plugins"
drive "$CONVERT" "$MARKER" "$PATHIN" "doc.pdf" json "" yes no "0,5-10" Quit
check "marker: --force_ocr, a page range" called "local|convert|--backend|marker|--output-format|json|--output-dir|./converted|--page-range|0,5-10|doc.pdf|--|--force_ocr"

echo "# Esc returns to the menu"
drive "$CONVERT" esc Quit
check "Esc on the converter" bash -c '[[ ! -s "$1" ]] && grep -q "<choose> Quit" "$2"' _ "$T/calls" "$T/out"
drive "$CONVERT" "$MID" esc Quit
check "Esc on the source" bash -c '[[ ! -s "$1" ]] && grep -q "<choose> Quit" "$2"' _ "$T/calls" "$T/out"
drive "$CONVERT" "$MID" "$PATHIN" esc Quit
check "Esc on the path" bash -c '[[ ! -s "$1" ]] && grep -q "<choose> Quit" "$2"' _ "$T/calls" "$T/out"
drive "$CONVERT" "$MID" "$PATHIN" "doc.pdf" esc Quit
check "Esc on the output directory" bash -c '[[ ! -s "$1" ]] && grep -q "<choose> Quit" "$2"' _ "$T/calls" "$T/out"

echo "# what deletes asks, and Enter is no"
for a in enter no; do
    drive "$LOCAL" "marker  (high-fidelity)" "Clear model cache" "$a" Back Quit
    check "clear the model cache, $a: nothing" no_calls
    drive "$LOCAL" "marker  (high-fidelity)" Uninstall "$a" Back Quit
    check "uninstall marker, $a: nothing" no_calls
    drive "$LOCAL" "markitdown  (fast, broad)" Uninstall "$a" Back Quit
    check "uninstall markitdown, $a: nothing" no_calls
    drive "$SERVICE" "Docker (compose)" "Tear down" "$a" Back Quit
    check "tear down, $a: nothing" no_calls
done
drive "$LOCAL" "marker  (high-fidelity)" "Clear model cache" yes Back Quit
check "clear the model cache, yes" called "local|clear-cache|--backend|marker|--yes"
drive "$LOCAL" "marker  (high-fidelity)" Uninstall yes Back Quit
check "uninstall marker, yes" called "local|uninstall|--backend|marker|--yes"
drive "$LOCAL" "markitdown  (fast, broad)" Uninstall yes Back Quit
check "uninstall markitdown, yes" called "local|uninstall|--backend|markitdown|--yes"
drive "$SERVICE" "Docker (compose)" "Tear down" yes Back Quit
check "tear down, yes" called "service|teardown|--target|docker|--yes"
check "  and back at the menu" at_quit

echo "# local and service"
drive "$LOCAL" "markitdown  (fast, broad)" "Setup / install" "Pick specific formats" 'pdf\ndocx' Back Quit
check "markitdown setup with picked extras" called "local|setup|--backend|markitdown|--extras|pdf,docx"
drive "$LOCAL" "markitdown  (fast, broad)" "Setup / install" "Pick specific formats" esc Back Quit
check "  Esc in the extras: no setup at all" no_calls
drive "$SERVICE" "Docker (compose)" "Deploy / update" "" "" "Scale workers" 3 Back Quit
check "docker deploy with the pre-filled folders" called "service|deploy|--target|docker|--input|./input|--output|./output"
check "scale to 3" called "service|scale|--target|docker|--replicas|3"

echo
if (( FAILS )); then echo "FAILED: ${FAILS} check(s)"; exit 1; fi
echo "All protocol-droid checks passed."
