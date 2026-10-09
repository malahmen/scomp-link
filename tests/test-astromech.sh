#!/usr/bin/env bash
# The astromech front-end, driven through the gum stub.
#
# What it is really protecting: the front-end asks with gum and then tells the
# engine the answer with --yes. If that pairing breaks, the engine falls back
# to its own /dev/tty prompt — which it CAN open from inside the TUI — and the
# user is asked the same question twice; or worse, --yes is sent without gum
# having asked at all. Both are checked here by looking at the flags the engine
# was actually invoked with, not at what the screen said.
#
# No network and no terminal: file:// remotes, a stubbed gum, and a recording
# wrapper in place of the engine where the flags are the thing under test.
# shellcheck disable=SC2016
# The single quotes around every `bash -c` body are the point: the child must
# expand $OUT/$CALLS itself, from the environment, which is why they are
# exported. Double-quoting them would interpolate a whole captured transcript
# into a command line. A directive covers only the next COMMAND, so this is
# file-scoped and has to sit above the first one.
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FRONT="${TEST_DIR}/../scripts/astromech/astromech.sh"
[[ -f "$FRONT" ]] || { echo "front-end not found at $FRONT" >&2; exit 1; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
T="$(cd "$T" && pwd)"
export PATH="${TEST_DIR}/stubs:$PATH"
export GUM_ANSWERS="$T/answers" GUM_STATE="$T/state"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL="$T/gitconfig"; : > "$GIT_CONFIG_GLOBAL"
export ASTROMECH_CONFIG="$T/cfg/astromech.conf"; mkdir -p "$T/cfg"
export XDG_RUNTIME_DIR="$T/run"; mkdir -p "$T/run"

FAILS=0
check() { local d="$1"; shift; if "$@"; then echo "   ok   - $d"; else echo "   FAIL - $d"; FAILS=$((FAILS + 1)); fi; }
has()   { case "$2" in *"$1"*) return 0 ;; *) return 1 ;; esac; }

# The real engine, resolved the way a user's sibling checkout would be. Without
# one there is nothing to drive, so this skips rather than pretends.
REAL_ENGINE="${ASTROMECH:-${TEST_DIR}/../../astromech/astromech.sh}"
if [[ ! -f "$REAL_ENGINE" ]]; then
    echo "SKIP - no astromech engine at ${REAL_ENGINE} (set \$ASTROMECH)" >&2
    exit 0
fi
REAL_ENGINE="$(cd "$(dirname "$REAL_ENGINE")" && pwd)/astromech.sh"

# ---- fixtures: a root with two repos, one carrying a merged branch ----------
R="$T/code"; mkdir -p "$R"
mk() {
    local n="$1" c="$R/$1"
    git init -q --bare -b main "$T/remotes/${n}.git"
    git clone -q "$T/remotes/${n}.git" "$c" 2>/dev/null
    git -C "$c" symbolic-ref HEAD refs/heads/main
    echo base > "$c/f"; git -C "$c" add f; git -C "$c" commit -qm base
    git -C "$c" push -q -u origin main
    git -C "$c" remote set-head origin main
}
mk alpha; mk beta
git -C "$R/alpha" checkout -q -b feat/old
echo x > "$R/alpha/x"; git -C "$R/alpha" add x; git -C "$R/alpha" commit -qm old
git -C "$R/alpha" checkout -q main
git -C "$R/alpha" merge -q --no-ff -m "merge feat/old" feat/old
git -C "$R/alpha" push -q origin main
printf 'onboarded=1\nroot=%s\n' "$R" > "$ASTROMECH_CONFIG"

# ---- drivers ----------------------------------------------------------------
# tui <answer>... — run the front-end against the REAL engine with those
# answers. OUT is the whole transcript.
export OUT=""
tui() {
    printf '%s\n' "$@" > "$GUM_ANSWERS"; echo 0 > "$GUM_STATE"
    OUT="$(ASTROMECH_DIR="$(dirname "$REAL_ENGINE")" timeout 120 bash "$FRONT" </dev/null 2>&1)"
}
# rec <answer>... — the same, but the engine is a wrapper that RECORDS its
# argv and forwards to the real one. CALLS is one line per invocation, which is
# how the --yes pairing is asserted rather than inferred.
export CALLS=""
rec() {
    mkdir -p "$T/fake"
    cat > "$T/fake/astromech.sh" <<WRAP
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$T/calls"
exec bash "$REAL_ENGINE" "\$@"
WRAP
    chmod +x "$T/fake/astromech.sh"
    : > "$T/calls"
    printf '%s\n' "$@" > "$GUM_ANSWERS"; echo 0 > "$GUM_STATE"
    OUT="$(ASTROMECH_DIR="$T/fake" timeout 120 bash "$FRONT" </dev/null 2>&1)"
    CALLS="$(cat "$T/calls")"
}
calls_with() { grep -q -- "$1" <<<"$CALLS"; }

echo "## 1. the menu is built from the engine's own command list"
tui Quit
check "tidy is offered"                       has "Tidy merged branches" "$OUT"
check "prune is offered"                      has "Fetch pruning" "$OUT"
# An engine without them must not be offered them: a menu item that fails after
# it is picked is worse than one that is absent.
mkdir -p "$T/old"
sed -e '/^  tidy /d' -e '/^  prune /d' -e 's/^        tidy)/        __no_tidy)/' \
    -e 's/^        prune)/        __no_prune)/' "$REAL_ENGINE" > "$T/old/astromech.sh"
OUT="$(printf 'Quit\n' > "$GUM_ANSWERS"; echo 0 > "$GUM_STATE"
       ASTROMECH_DIR="$T/old" timeout 120 bash "$FRONT" </dev/null 2>&1)"
check "an engine without tidy is not offered it"  bash -c '! grep -q "Tidy merged branches" <<<"$OUT"'
check "  nor prune"                               bash -c '! grep -q "Fetch pruning" <<<"$OUT"'
check "  and the rest of the menu still works"    has "Trigger maintenance" "$OUT"

echo "## 2. tidy: plan, then ask, then act"
rec "Tidy merged branches" "Every repository" yes Quit
check "the plan is fetched with --dry-run"    calls_with "tidy --dry-run"
check "the branch is listed before the question" bash -c '
    p=$(grep -n "feat/old" <<<"$OUT" | head -1 | cut -d: -f1)
    q=$(grep -n "<confirm> Delete" <<<"$OUT" | head -1 | cut -d: -f1)
    [[ -n "$p" && -n "$q" && "$p" -lt "$q" ]]'
check "  measured against origin, and it says so" has "merged into origin/main" "$OUT"
check "the deletion run carries --yes"        calls_with "tidy --yes"
check "  so the engine never asks a second time" bash -c '! grep -q "no terminal to confirm on" <<<"$OUT"'
check "the branch is gone"                    bash -c '! git -C "'"$R"'/alpha" show-ref --verify -q refs/heads/feat/old'
check "and it reported what it deleted"       has "deleted feat/old" "$OUT"

echo "## 3. tidy: declining deletes nothing"
git -C "$R/alpha" branch back/again origin/main
rec "Tidy merged branches" "Every repository" no Quit
check "the plan was still shown"              has "back/again" "$OUT"
check "no --yes run happened"                 bash -c '! grep -q -- "tidy --yes" <<<"$CALLS"'
check "the branch survives"                   git -C "$R/alpha" show-ref --verify -q refs/heads/back/again
check "and it says so"                        has "Cancelled" "$OUT"

echo "## 4. tidy: one repository is scoped with --repo"
rec "Tidy merged branches" "One repository" "$R/alpha" yes Quit
check "the scope reaches the engine"          calls_with "--repo $R/alpha"
check "  on the dry run"                      bash -c 'grep -q -- "tidy --dry-run --repo" <<<"$CALLS"'
check "  and on the deletion"                 bash -c 'grep -q -- "tidy --yes --repo" <<<"$CALLS"'
check "the branch is gone"                    bash -c '! git -C "'"$R"'/alpha" show-ref --verify -q refs/heads/back/again'

echo "## 5. tidy: nothing to do says so and asks nothing"
rec "Tidy merged branches" "Every repository" Quit
check "no question is put"                    bash -c '! grep -q "<confirm>" <<<"$OUT"'
check "  and it says why"                     has "Nothing to tidy" "$OUT"
check "  without running a deletion"          bash -c '! grep -q -- "--yes" <<<"$CALLS"'

echo "## 6. prune: the toggle writes the global setting"
tui "Fetch pruning (fetch.prune)" "Turn pruning on" Quit
check "the state is shown first"              has "fetch.prune is unset" "$OUT"
check "  with the engine's own explanation"   has "stale origin/* remote-tracking refs" "$OUT"
check "  including what it does NOT prune"    has "No git setting deletes those" "$OUT"
check "the global config is written"          test "$(git config --global --get fetch.prune)" = true
check "the transition is reported"            has "unset -> true" "$OUT"
check "  with the way back"                   has "--unset fetch.prune" "$OUT"
check "  and the why is not repeated"         bash -c '[[ "$(grep -c "stale origin/\* remote" <<<"$OUT")" -eq 1 ]]'

echo "## 7. prune: an on setting offers off, and overrides are surfaced"
git -C "$R/beta" config --local remote.origin.prune false
tui "Fetch pruning (fetch.prune)" "Turn pruning off" Quit
check "it reports the setting as on"          has "fetch.prune is on (true)" "$OUT"
check "the local override is named"           has "overrides it: remote.origin.prune=false" "$OUT"
check "  with the repo it is in"              has "beta overrides it" "$OUT"
check "  and a warning that it wins"          has "overridden locally" "$OUT"
check "the toggle turns it off"               test "$(git config --global --get fetch.prune)" = false

echo "## 8. maintain --tidy is gated by gum, not by the engine"
git -C "$R/alpha" branch spent origin/main
rec "Trigger maintenance" "Run maintenance, then tidy merged branches" yes Quit
check "the engine gets both flags"            calls_with "maintain --tidy --yes"
check "gum asked first"                       has "<confirm> Maintain" "$OUT"
check "  and the branch was tidied"           bash -c '! git -C "'"$R"'/alpha" show-ref --verify -q refs/heads/spent'
rec "Trigger maintenance" "Run maintenance, then tidy merged branches" no Quit
check "declining runs no maintenance at all"  bash -c '! grep -q "maintain" <<<"$CALLS"'

echo
if (( FAILS )); then echo "${FAILS} check(s) failed"; exit 1; fi
echo "all checks passed"
