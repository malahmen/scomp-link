#!/usr/bin/env bash
# The holo-convert front-end, driven through the gum stub against a fake
# engine (HOLO_CONVERT_DIR) that records the arguments it is given.
#
# What it protects: --no-open is reachable from the menus, and passed only
# when the answer is no - the engine opens by default, and a v1.0.0 engine
# (the HOLO_CONVERT_DIR rollback) does not know --open/--no-open at all.
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FRONT="${TEST_DIR}/../scripts/holo-convert/holo-convert.sh"
[[ -f "$FRONT" ]] || { echo "front-end not found at $FRONT" >&2; exit 1; }
if [[ "${BASH_VERSINFO[0]:-0}" -lt 4 ]]; then
    for b in /opt/homebrew/bin/bash /usr/local/bin/bash; do [[ -x "$b" ]] && exec "$b" "$0" "$@"; done
    echo "SKIP - bash 4+ not found (the front-end needs it)"; exit 0
fi

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
FAILS=0
check() { local d="$1"; shift; if "$@"; then echo "   ok   - $d"; else echo "   FAIL - $d"; FAILS=$((FAILS + 1)); fi; }

mkdir -p "$T/engine" "$T/bin" "$T/src"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$@" > "%s/args"\n' "$T" > "$T/engine/holo-convert.sh"
cp "${TEST_DIR}/stubs/gum" "$T/bin/gum"; chmod +x "$T/bin/gum"
: > "$T/src/report.docx"

# drive <answer to "Open ... when done?">
drive() {
    printf '%s\n' "local - the tools installed on this host" "docx" "" "report.docx" "$1" "gfm" "no" > "$T/answers"
    rm -f "$T/args" "$T/state"
    (cd "$T/src" && PATH="$T/bin:$PATH" GUM_ANSWERS="$T/answers" GUM_STATE="$T/state" \
        HOLO_CONVERT_DIR="$T/engine" "$BASH" "$FRONT" > "$T/out" 2>&1)
}

echo "# opening the output"
drive yes
check "the menus ask about opening the output" grep -q "Open the output in its viewer when done" "$T/out"
check "yes: the engine runs" [ -s "$T/args" ]
check "  without --no-open (opening is its default)" bash -c '! grep -qx -- "--no-open" "$1"' _ "$T/args"
check "  and without --open (a v1.0.0 engine would reject it)" bash -c '! grep -qx -- "--open" "$1"' _ "$T/args"
drive no
check "no: --no-open is passed" grep -qx -- "--no-open" "$T/args"
check "  with the file still last" [ "$(tail -1 "$T/args")" = report.docx ]

echo; if (( FAILS == 0 )); then echo "all passed"; else echo "${FAILS} failed"; exit 1; fi
