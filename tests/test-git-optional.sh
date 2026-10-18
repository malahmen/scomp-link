#!/usr/bin/env bash
# git is needed to FETCH an engine, not to run one (Kamino item 81). Every
# engine front-end used to stop at startup without git, even with the engine
# checked out next to it or cached. Driven through the gum stub with git
# removed from PATH: no network, nothing installed.
#
# What it protects:
#   - no fetch-only front-end (nor the template they are made from) checks for
#     git at startup;
#   - with a local engine and no git, a front-end starts and reaches its menu;
#   - with no engine and no git, it stops saying git is needed to fetch one,
#     BEFORE asking whether to clone - not after the user said yes.
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$TEST_DIR/.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
FAILS=0
check() { local d="$1"; shift; if "$@"; then echo "   ok   - $d"; else echo "   FAIL - $d"; FAILS=$((FAILS + 1)); fi; }
has()   { grep -qF -- "$1" "$2"; }
lacks() { ! grep -qF -- "$1" "$2"; }

echo "## no startup check"
# mind-trick's own work is rewriting git history, so it keeps one.
for f in "$ROOT"/scripts/*/*.sh; do   # the template included: scripts/_templates
    case "$f" in */mind-trick/*|*/_common/*) continue ;; esac
    rel="${f#"$ROOT"/}"
    if grep -qE '^command -v git ' "$f"; then
        echo "   FAIL - ${rel} checks for git at startup"; FAILS=$((FAILS + 1))
    fi
done
echo "   ok   - checked every front-end"

# ---- a PATH with everything but git -----------------------------------------
mkdir -p "$T/nogit"
for d in /usr/local/bin /usr/bin /bin; do
    [[ -d "$d" ]] || continue
    for b in "$d"/*; do
        n="${b##*/}"
        [[ "$n" == git || "$n" == git-* || -e "$T/nogit/$n" ]] && continue
        ln -s "$b" "$T/nogit/$n"
    done
done
NOGIT_PATH="${TEST_DIR}/stubs:$T/nogit"
PATH="$NOGIT_PATH" command -v git >/dev/null && { echo "git is still on the test PATH" >&2; exit 1; }

# The astromech front-end in a tree of its own, so no sibling checkout is found
# next to it, and an empty cache.
mkdir -p "$T/tree/x/y/scripts" "$T/cache"
cp -r "$ROOT/scripts/astromech" "$ROOT/scripts/_common" "$T/tree/x/y/scripts/"
FRONT="$T/tree/x/y/scripts/astromech/astromech.sh"

# A stand-in engine: just enough of the interface for the menu to come up.
mkdir -p "$T/engine"
cat > "$T/engine/astromech.sh" <<'EOF'
#!/usr/bin/env bash
case "$1" in
    --help) printf 'COMMANDS\n  maintain   x\n  status     x\nFLAGS\n' ;;
    config) printf 'config=/tmp/x.conf\nonboarded=1\nroots=1\n' ;;
esac
exit 0
EOF

run() {
    printf '%s\n' "$@" > "$T/answers"; echo 0 > "$T/state"
    env -i HOME="$T" PATH="$NOGIT_PATH" XDG_CACHE_HOME="$T/cache" \
        GUM_ANSWERS="$T/answers" GUM_STATE="$T/state" ${ENGINE_DIR:+ASTROMECH_DIR="$ENGINE_DIR"} \
        bash "$FRONT" > "$T/out" 2>&1 < /dev/null
}

echo "## a local engine, no git"
ENGINE_DIR="$T/engine" run Quit; rc=$?
check "it starts"                       [ "$rc" -eq 0 ]
check "  and reaches its menu"          has "Bye." "$T/out"
check "  never asking for git"          lacks "git is required" "$T/out"

echo "## no engine, no git"
ENGINE_DIR="" run yes Quit; rc=$?
check "it stops"                        [ "$rc" -ne 0 ]
check "  saying git is needed to fetch the engine" has "git is required to fetch the astromech engine" "$T/out"
check "  before offering to clone"      lacks "Clone it from" "$T/out"

echo
if (( FAILS )); then echo "${FAILS} check(s) failed"; exit 1; fi
echo "all checks passed"
