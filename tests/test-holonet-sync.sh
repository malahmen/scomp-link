#!/usr/bin/env bash
# The holonet-sync front-end, driven through the gum stub against a fake
# engine (HOLONET_SYNC_DIR) that answers `config` and `repos` and records every
# other call it is given, one per line, its arguments joined with '|'.
#
# What it protects: the --no-api question says that it turns the visibility
# gate (Kamino 129) off, and defaults to no (Kamino 196); a real run with a
# safety check off names it and does nothing on Enter; a real run and a state
# reset do nothing when declined; Esc at any question returns to the menu;
# each menu path reaches the engine with its flags.
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FRONT="${TEST_DIR}/../scripts/holonet-sync/holonet-sync.sh"
[[ -f "$FRONT" ]] || { echo "front-end not found at $FRONT" >&2; exit 1; }
if [[ "${BASH_VERSINFO[0]:-0}" -lt 4 ]]; then
    for b in /opt/homebrew/bin/bash /usr/local/bin/bash; do [[ -x "$b" ]] && exec "$b" "$0" "$@"; done
    echo "SKIP - bash 4+ not found (the front-end needs it)"; exit 77
fi

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
FAILS=0
check() { local d="$1"; shift; if "$@"; then echo "   ok   - $d"; else echo "   FAIL - $d"; FAILS=$((FAILS + 1)); fi; }

mkdir -p "$T/engine" "$T/bin" "$T/cfg"
: > "$T/cfg/config"; : > "$T/cfg/repos.tsv"
cat > "$T/engine/holonet-sync.sh" <<EOF
#!/usr/bin/env bash
case "\${1:-}" in
    config) printf 'config=%s\nconfig_exists=1\nrepos=%s\nrepos_exists=1\nstate=%s\n' \
                "$T/cfg/config" "$T/cfg/repos.tsv" "$T/state-dir"; exit 0 ;;
    repos)  printf 'me/one\tme/one\tprivate\nme/two\tme/two\tpublic\n'; exit 0 ;;
esac
(IFS='|'; printf '%s\n' "\$*") >> "$T/calls"
exit 0
EOF
cat > "$T/bin/editor" <<EOF
#!/usr/bin/env bash
printf 'editor|%s\n' "\$*" >> "$T/calls"
EOF
cp "${TEST_DIR}/stubs/gum" "$T/bin/gum"
chmod +x "$T/bin/"*

# drive <answer>... - one answer per prompt, in order; the session ends at quit.
drive() {
    printf '%s\n' "$@" > "$T/answers"
    rm -f "$T/calls" "$T/state"; : > "$T/calls"
    PATH="$T/bin:$PATH" GUM_ANSWERS="$T/answers" GUM_STATE="$T/state" HOLONET_SYNC_DIR="$T/engine" \
        EDITOR="$T/bin/editor" "$BASH" "$FRONT" > "$T/out" 2>&1
}
called()     { grep -qxF -- "$1" "$T/calls"; }
not_called() { ! grep -q -- "$1" "$T/calls"; }
no_calls()   { [[ ! -s "$T/calls" ]]; }
# The session reached the main menu's quit: every answer before it was read
# by the prompt it was written for.
at_quit()    { grep -q '<choose> quit' "$T/out"; }

echo "# --no-api says it turns the visibility gate off (Kamino 196)"
drive run "every repo" no yes no no no yes quit
check "the --no-api question names the visibility check" \
    grep -q '<confirm> --default=false Skip every API call (--no-api)? This also turns OFF the visibility check' "$T/out"
check "  and says what that means for a private repo" grep -q 'a repo declared private is pushed even if it is now public' "$T/out"
check "  the advanced-options question says these are safety checks" grep -q '<confirm> --default=false Advanced options (.*safety checks off)' "$T/out"
check "  declined: no run (the real run was not confirmed)" no_calls
drive run "every repo" no yes no enter yes yes quit
check "Enter on --no-api: not passed, the plain real run asked" bash -c 'grep -q "<confirm> Run for real on every repo in the list? " "$1"' _ "$T/out"
check "  and run, with no --no-api" called "run"
drive run "every repo" no yes no yes enter yes quit
check "--no-api on: the real run names the visibility check" grep -q '<confirm> --default=false Run for real on every repo in the list, with the visibility check OFF?' "$T/out"
check "  and Enter runs nothing" no_calls
drive run "every repo" no yes no yes yes yes quit
check "  yes: run --no-api" called "run|--no-api"

echo "# --allow-deletions: a real run with the guards off is no on Enter"
drive run me/one no yes yes no enter yes quit
check "guards off: the question names them" grep -q '<confirm> --default=false Run for real on me/one, with the deletion guards OFF?' "$T/out"
check "  Enter runs nothing" no_calls
drive run me/one no yes yes no yes yes quit
check "  yes: run --repo me/one --allow-deletions" called "run|--repo|me/one|--allow-deletions"
drive dry-run me/two no yes yes yes yes quit
check "a dry run asks no real-run question" called "run|--repo|me/two|--dry-run|--allow-deletions|--no-api"

echo "# plain runs"
drive dry-run "every repo" yes enter yes quit
check "dry run, verbose" called "run|--dry-run|--verbose"
drive run me/one no enter no yes quit
check "a real run declined: nothing" no_calls
check "  back at the menu" at_quit
drive run me/one no enter enter yes quit
check "a real run with no guard off: Enter is yes" called "run|--repo|me/one"

echo "# Esc returns to the menu"
drive run esc yes quit
check "Esc on the repo: nothing run, back at the menu" bash -c '[[ ! -s "$1" ]] && grep -q "<choose> quit" "$2"' _ "$T/calls" "$T/out"
drive run me/one esc yes quit
check "Esc on verbose: nothing run, back at the menu" bash -c '[[ ! -s "$1" ]] && grep -q "<choose> quit" "$2"' _ "$T/calls" "$T/out"
drive run me/one no esc yes quit
check "Esc on the advanced options: nothing run" bash -c '[[ ! -s "$1" ]] && grep -q "<choose> quit" "$2"' _ "$T/calls" "$T/out"
drive run me/one no yes yes esc yes quit
check "Esc on --no-api: nothing run" bash -c '[[ ! -s "$1" ]] && grep -q "<choose> quit" "$2"' _ "$T/calls" "$T/out"
drive run me/one no enter esc yes quit
check "Esc on the real-run question: nothing run" bash -c '[[ ! -s "$1" ]] && grep -q "<choose> quit" "$2"' _ "$T/calls" "$T/out"

echo "# reset state, status, check, edit"
drive "reset state" me/one no yes quit
check "reset declined: nothing" no_calls
drive "reset state" me/one yes yes quit
check "reset confirmed: reset --repo me/one" called "reset|--repo|me/one"
drive "reset state" "every repo" yes quit
check "reset on every repo: refused, nothing" no_calls
drive status yes check yes quit
check "status" called "status"
check "check" called "check"
drive "edit config" "$T/cfg/repos.tsv" yes quit
check "edit opens the chosen file in \$EDITOR" called "editor|$T/cfg/repos.tsv"

echo
if (( FAILS )); then echo "FAILED: ${FAILS} check(s)"; exit 1; fi
echo "All holonet-sync checks passed."
