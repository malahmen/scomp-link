#!/usr/bin/env bash
# The wow-dark-portal front-end, driven through the gum stub against a fake
# engine (DARK_PORTAL_DIR) that answers `get`, the listings and the LAN scan,
# and records every other call, one per line, its arguments joined with '|'.
#
# What it protects: removing an instance (which deletes its bottle and client
# files) does nothing on Enter or no (--default=false, Kamino 196); Esc on a
# question returns to the menu with nothing set; configure saves what was
# picked, with ~ expanded; add, edit, launch (several at once), stop, discover
# and status reach the engine with their flags.
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FRONT="${TEST_DIR}/../scripts/wow-dark-portal/wow-dark-portal.sh"
[[ -f "$FRONT" ]] || { echo "front-end not found at $FRONT" >&2; exit 1; }
if [[ "${BASH_VERSINFO[0]:-0}" -lt 4 ]]; then
    for b in /opt/homebrew/bin/bash /usr/local/bin/bash; do [[ -x "$b" ]] && exec "$b" "$0" "$@"; done
    echo "SKIP - bash 4+ not found (the front-end needs it)"; exit 77
fi

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
FAILS=0
check() { local d="$1"; shift; if "$@"; then echo "   ok   - $d"; else echo "   FAIL - $d"; FAILS=$((FAILS + 1)); fi; }

mkdir -p "$T/engine" "$T/bin" "$T/home"
cat > "$T/engine/dark-portal.sh" <<EOF
#!/usr/bin/env bash
if [[ "\${1:-}" == get ]]; then
    case "\$2" in
        CLIENT_SOURCE_DIR) echo /wow/client ;; CLIENT_ISOLATION_MODE) echo full ;;
        WINE_ARCH) echo win32 ;; BOTTLES_RUNNER) echo soda-9 ;;
        DEFAULT_RESOLUTION) echo 1024x768 ;; DEFAULT_REALM_ADDRESS) echo 192.168.1.50 ;;
        DEFAULT_REALM_PORT) echo 3724 ;; *) echo "" ;;
    esac
    exit 0
fi
case "\$*" in
    "list-instances --names") printf 'box1\nbox2\n'; exit 0 ;;
    list-runners)             printf 'soda-9\ncaffe-8\n'; exit 0 ;;
    discover-realm)           printf '192.168.1.60\n'; exit 0 ;;
esac
(IFS='|'; printf '%s\n' "\$*") >> "$T/calls"
exit 0
EOF
cp "${TEST_DIR}/stubs/gum" "$T/bin/gum"
chmod +x "$T/bin/"*

SHARED="shared (symlinked install, private WTF/Cache only — lowest disk use)"
WIN32="win32 (matches this 32-bit-era client)"

# drive <answer>... - one answer per prompt, in order; the session ends at Quit.
drive() {
    printf '%s\n' "$@" > "$T/answers"
    rm -f "$T/calls" "$T/state"; : > "$T/calls"
    PATH="$T/bin:$PATH" HOME="$T/home" GUM_ANSWERS="$T/answers" GUM_STATE="$T/state" \
        DARK_PORTAL_DIR="$T/engine" "$BASH" "$FRONT" > "$T/out" 2>&1
}
called()     { grep -qxF -- "$1" "$T/calls"; }
not_called() { ! grep -q -- "$1" "$T/calls"; }
no_calls()   { [[ ! -s "$T/calls" ]]; }
at_quit()    { grep -q '<choose> Quit' "$T/out"; }

echo "# removing an instance needs a yes (Kamino 196)"
drive Instances remove-instance box1 enter back Quit
check "Enter: nothing removed" no_calls
check "  back at the menu" at_quit
drive Instances remove-instance box1 no back Quit
check "no: nothing removed" no_calls
drive Instances remove-instance box1 yes back Quit
check "yes: remove-instance --name box1" called "remove-instance|--name|box1"
drive Instances remove-instance esc back Quit
check "Esc on the picker: nothing removed" no_calls

echo "# configure"
# shellcheck disable=SC2088  # a literal ~, typed: the front-end must expand it
drive Setup configure "~/games/wow" "$SHARED" "$WIN32" caffe-8 "" "Enter manually" "" 3725 back Quit
check "the client path is saved with ~ expanded" called "set|CLIENT_SOURCE_DIR|$T/home/games/wow"
check "the picks are saved" bash -c 'grep -qxF "set|CLIENT_ISOLATION_MODE|shared" "$1" && grep -qxF "set|WINE_ARCH|win32" "$1" && grep -qxF "set|BOTTLES_RUNNER|caffe-8" "$1"' _ "$T/calls"
check "the realm port typed is saved" called "set|DEFAULT_REALM_PORT|3725"
check "  and configure validates at the end" called "configure"
drive Setup configure esc back Quit
check "Esc on the client path: nothing set, nothing configured" no_calls
check "  back at the menu" at_quit
drive Setup configure "" esc esc esc "" esc back Quit
check "Esc on each picker keeps the current value" bash -c 'grep -qxF "set|CLIENT_ISOLATION_MODE|full" "$1" && grep -qxF "set|WINE_ARCH|win32" "$1" && ! grep -q "BOTTLES_RUNNER" "$1"' _ "$T/calls"
drive Setup discover-realm 192.168.1.60 back Quit
check "discover: the picked realm becomes the default" called "set|DEFAULT_REALM_ADDRESS|192.168.1.60"

echo "# instances"
drive Instances add-instance box3 "" "" back Quit
check "add: blank resolution and realm follow the defaults" called "add-instance|--name|box3"
drive Instances add-instance box3 800x600 10.0.0.5 "" back Quit
check "add with overrides: the port is pre-filled" called "add-instance|--name|box3|--resolution|800x600|--realm|10.0.0.5|--port|3724"
drive Instances add-instance "" back Quit
check "add with a blank name: nothing" no_calls
drive Instances edit-instance box1 "" "" back Quit
check "edit with nothing changed: nothing" no_calls
drive Instances edit-instance box1 1280x720 "" back Quit
check "edit the resolution" called "edit-instance|--name|box1|--resolution|1280x720"
drive Instances list-instances back Quit
check "list" called "list-instances"

echo "# launch and status"
drive Launch launch 'box1\nbox2' stop box2 stop-all back Status Quit
check "launch two at once" bash -c 'grep -qxF "launch|--name|box1" "$1" && grep -qxF "launch|--name|box2" "$1"' _ "$T/calls"
check "stop one" called "stop|--name|box2"
check "stop all" called "stop-all"
check "status" called "status"
drive Launch launch esc back Quit
check "Esc on the launch picker: nothing launched" not_called "launch"

echo
if (( FAILS )); then echo "FAILED: ${FAILS} check(s)"; exit 1; fi
echo "All wow-dark-portal checks passed."
