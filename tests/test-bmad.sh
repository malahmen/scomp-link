#!/usr/bin/env bash
# The bmad front-end, driven through the gum stub with HOME and the registry in
# a temp dir. Nothing is installed: node/npx/uv are never reached on these paths.
#
# What it protects (Kamino 196): Esc or "no" at any prompt returns to the
# menu. A bare `|| return` after a gum prompt returned gum's status (130 on
# Esc, 1 on no) to a menu that called the action bare under `set -e`, so
# declining ended the whole TUI - and declining the registry prune did too.
# Deleting still needs the typed name.
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FRONT="${TEST_DIR}/../scripts/bmad/bmad.sh"
[[ -f "$FRONT" ]] || { echo "front-end not found at $FRONT" >&2; exit 1; }
if [[ "${BASH_VERSINFO[0]:-0}" -lt 4 ]]; then
    for b in /opt/homebrew/bin/bash /usr/local/bin/bash; do [[ -x "$b" ]] && exec "$b" "$0" "$@"; done
    echo "SKIP - bash 4+ not found (the front-end needs it)"; exit 77
fi
command -v python3 >/dev/null || { echo "SKIP - python3 not found (the registry needs it)"; exit 77; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
T="$(cd "$T" && pwd -P)"
FAILS=0
check() { local d="$1"; shift; if "$@"; then echo "   ok   - $d"; else echo "   FAIL - $d"; FAILS=$((FAILS + 1)); fi; }

mkdir -p "$T/home" "$T/work/proj/_bmad"
drive() {
    printf '%s\n' "$@" > "$T/answers"; : > "$T/state"
    (cd "$T/work" && PATH="${TEST_DIR}/stubs:$PATH" GUM_ANSWERS="$T/answers" GUM_STATE="$T/state" \
        HOME="$T/home" XDG_CONFIG_HOME="$T/home/.config" "$BASH" "$FRONT" > "$T/out" 2>&1)
    echo $? > "$T/rc"
}
listed() { grep -q "proj — $T/work/proj" "$T/out"; }

echo "# delete: Esc at the typed name returns to the menu"
drive "Delete a project" "↻ Scan a folder for BMAD projects…" "$T/work" "$T/work/proj" esc "List managed projects" Quit
check "the project is still there" test -d "$T/work/proj/_bmad"
check "  and the menu came back: List ran" listed
check "  the TUI exited 0" [ "$(cat "$T/rc")" = 0 ]
drive "Delete a project" "$T/work/proj" "wrong" "List managed projects" Quit
check "a name that does not match deletes nothing" test -d "$T/work/proj/_bmad"
check "  and List ran after it" listed

echo "# list: declining the prune keeps the TUI"
mkdir -p "$T/work/gone/_bmad"
drive "Delete a project" "↻ Scan a folder for BMAD projects…" "$T/work" "$T/work/gone" esc Quit
rm -rf "$T/work/gone"
drive "List managed projects" no "List managed projects" no Quit
check "declined prune: List ran a second time" [ "$(grep -c "proj — $T/work/proj" "$T/out")" = 2 ]
check "  and the missing one is kept" grep -q "(missing)" "$T/out"

echo "# update: Esc at the version returns to the menu"
mkdir -p "$T/bin"
printf '#!/usr/bin/env bash\necho v22.0.0\n' > "$T/bin/node"; printf '#!/usr/bin/env bash\nexit 0\n' > "$T/bin/npx"
printf '#!/usr/bin/env bash\nexit 0\n' > "$T/bin/uv"; chmod +x "$T/bin/"*
printf '%s\n' "Update BMAD in a project" "$T/work/proj" esc "List managed projects" no Quit > "$T/answers"; : > "$T/state"
(cd "$T/work" && PATH="${TEST_DIR}/stubs:$T/bin:$PATH" GUM_ANSWERS="$T/answers" GUM_STATE="$T/state" \
    HOME="$T/home" XDG_CONFIG_HOME="$T/home/.config" "$BASH" "$FRONT" > "$T/out" 2>&1)
check "Esc at the version: List ran after it" listed

echo; if (( FAILS == 0 )); then echo "all passed"; else echo "${FAILS} failed"; exit 1; fi
