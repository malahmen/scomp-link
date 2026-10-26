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
# Section 6 writes the global git config. GIT_CONFIG_GLOBAL is honoured from
# git 2.32 only; an older git would write the real ~/.gitconfig, so HOME is a
# throwaway too (Kamino item 143), and the honour check below says which one
# this git used.
export HOME="$T/home"; mkdir -p "$HOME"
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
    exit 77
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
# A run that hangs on a prompt must not hang the suite, so menu runs are
# time-limited - but GNU `timeout` is not on macOS (coreutils installs it as
# `gtimeout`). Without either, run unbounded rather than not at all: a missing
# `timeout` once made every run die with "command not found", and the checks
# below then read an empty transcript.
if command -v timeout &>/dev/null; then LIMIT_CMD=timeout
elif command -v gtimeout &>/dev/null; then LIMIT_CMD=gtimeout
else LIMIT_CMD=""; echo "note - no timeout or gtimeout: menu runs are not time-limited" >&2; fi
limited() { if [[ -n "$LIMIT_CMD" ]]; then "$LIMIT_CMD" 120 "$@"; else "$@"; fi; }

# ran <status> - stop if the front-end never started: 127/126 is a launcher
# that was not found or not executable (the missing `timeout` was exactly that,
# with "command not found" as the whole transcript), and an empty transcript is
# no run at all. Going on would let the checks that assert something is ABSENT
# pass on nothing.
ran() {
    if [[ "$1" == 127 || "$1" == 126 || -z "$OUT" ]]; then
        echo "   FAIL - the front-end did not run (exit $1): ${OUT:0:200}" >&2
        exit 1
    fi
}

# tui <answer>... — run the front-end against the REAL engine with those
# answers. OUT is the whole transcript.
export OUT=""
tui() {
    printf '%s\n' "$@" > "$GUM_ANSWERS"; echo 0 > "$GUM_STATE"
    OUT="$(ASTROMECH_DIR="$(dirname "$REAL_ENGINE")" limited bash "$FRONT" </dev/null 2>&1)"; ran $?
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
    OUT="$(ASTROMECH_DIR="$T/fake" limited bash "$FRONT" </dev/null 2>&1)"; ran $?
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
       ASTROMECH_DIR="$T/old" limited bash "$FRONT" </dev/null 2>&1)"; ran $?
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

echo "## 9. a folder whose name starts with '-' can be ignored"
mkdir -p "$R/-scratch"
rec "Edit ignored folders" "-scratch" Quit
check "set-ignores ends its flags first"      calls_with "set-ignores -- $R -scratch"
check "  and the folder is ignored"           bash -c 'bash "'"$REAL_ENGINE"'" ignores | grep -qx -- "'"$R"'/-scratch"'

echo "## 10. plain maintenance is plain (Kamino item 143)"
rec "Trigger maintenance" "Run maintenance" yes Quit
check "the engine runs maintain"               bash -c 'grep -qx "maintain" <<<"$CALLS"'
check "  with no --tidy"                       bash -c '! grep -q -- "--tidy" <<<"$CALLS"'
check "  and no --yes"                         bash -c '! grep -q -- "maintain.*--yes" <<<"$CALLS"'

echo "## 11. the dry run only looks"
rec "Trigger maintenance" "Dry run (show what would happen)" Quit
check "the engine gets maintain --dry-run"     bash -c 'grep -qx "maintain --dry-run" <<<"$CALLS"'
check "  and no real maintenance"              bash -c '! grep -qx "maintain" <<<"$CALLS"'

echo "## 12. first run: No records the answer and maintains nothing"
printf 'onboarded=0\nroot=%s\n' "$R" > "$ASTROMECH_CONFIG"
rec no Quit
check "the question was put"                   has "<confirm> Run maintenance on all repositories now?" "$OUT"
check "  the answer is recorded"               calls_with "mark-onboarded"
check "  and nothing is maintained"            bash -c '! grep -q "^maintain" <<<"$CALLS"'
rec Quit
check "it is not asked again"                  bash -c '! grep -q "<confirm> Run maintenance on all" <<<"$OUT"'

echo "## 13. tidy: an engine that cannot plan is not 'nothing to tidy'"
git -C "$R/alpha" branch --no-track held origin/main
# astromech's run lock (since astromech #11, Kamino 193): a file under $HOME -
# this test's own - holding a live pid; a blank boot id is accepted as current.
LOCK="${HOME}/.local/state/astromech/run.lock"; mkdir -p "${LOCK%/*}"; printf '%s\n' "$$" > "$LOCK"
rec "Tidy merged branches" "Every repository" Quit
rm -f "$LOCK"
check "it says the list could not be made"     has "could not make its list" "$OUT"
check "  not that there is nothing to tidy"    bash -c '! grep -q "Nothing to tidy" <<<"$OUT"'
check "  and deletes nothing"                  git -C "$R/alpha" show-ref --verify -q refs/heads/held

echo "## 14. tidy: a list that changed after it was shown is asked about again"
# The wrapper merges a new branch into the list on the SECOND plan, i.e. while
# the question about the first one was open.
mkdir -p "$T/fake2"
cat > "$T/fake2/astromech.sh" <<WRAP
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$T/calls"
if [[ "\$1 \$2" == "tidy --dry-run" ]]; then
    n=\$(( \$(cat "$T/plans" 2>/dev/null || echo 0) + 1 )); echo "\$n" > "$T/plans"
    (( n == 2 )) && git -C "$R/alpha" branch sneaked origin/main
fi
exec bash "$REAL_ENGINE" "\$@"
WRAP
chmod +x "$T/fake2/astromech.sh"; : > "$T/calls"; rm -f "$T/plans"
printf '%s\n' "Tidy merged branches" "Every repository" yes no Quit > "$GUM_ANSWERS"; echo 0 > "$GUM_STATE"
OUT="$(ASTROMECH_DIR="$T/fake2" limited bash "$FRONT" </dev/null 2>&1)"; ran $?
CALLS="$(cat "$T/calls")"
check "the change is shown"                    has "The list changed since it was shown" "$OUT"
check "  naming the new branch"                has "sneaked" "$OUT"
check "  and asked about again"                bash -c '[[ "$(grep -c "<confirm> Delete the branch" <<<"$OUT")" -eq 2 ]]'
check "declining then deletes nothing"         bash -c '! grep -q -- "tidy --yes" <<<"$CALLS"'
check "  the branch nobody was shown survives" git -C "$R/alpha" show-ref --verify -q refs/heads/sneaked
check "  and so does the one that was shown"   git -C "$R/alpha" show-ref --verify -q refs/heads/held

echo
if (( FAILS )); then echo "${FAILS} check(s) failed"; exit 1; fi
echo "all checks passed"
