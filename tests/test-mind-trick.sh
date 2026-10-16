#!/usr/bin/env bash
# The mind-trick front-end, driven through the gum stub against a fake engine
# that records its argv and fails its dry run on demand.
#
# What it protects: a dry run that fails (no rewrite tool on the machine, a
# dirty tree) must end the run. The front-end used to swallow that failure,
# ask to rewrite and force-push anyway, and then fail the same way again.
# shellcheck disable=SC2016
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FRONT="${TEST_DIR}/../scripts/mind-trick/mind-trick.sh"
[[ -f "$FRONT" ]] || { echo "front-end not found at $FRONT" >&2; exit 1; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
export PATH="${TEST_DIR}/stubs:$PATH"
export GUM_ANSWERS="$T/answers" GUM_STATE="$T/state"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

FAILS=0
check() { local d="$1"; shift; if "$@"; then echo "   ok   - $d"; else echo "   FAIL - $d"; FAILS=$((FAILS + 1)); fi; }
has()   { case "$2" in *"$1"*) return 0 ;; *) return 1 ;; esac; }

# The fake engine: records every call; a dry run exits $DRY_RC.
mkdir -p "$T/engine"
cat > "$T/engine/mind-trick.sh" <<FAKE
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$T/calls"
case " \$* " in *" --apply "*) exit 0 ;; esac
exit "\${DRY_RC:-0}"
FAKE

git init -q "$T/dirty-history"
git -C "$T/dirty-history" commit -q --allow-empty -m "x" -m "Co-Authored-By: Claude <noreply@anthropic.com>"
git init -q "$T/clean-history"
git -C "$T/clean-history" commit -q --allow-empty -m "nothing to scrub"

OUT="" RC=0 CALLS=""
tui() {   # tui <repo> <dry-run rc> <answers…>
    local repo="$1" rc="$2"; shift 2
    : > "$T/calls"
    printf '%s\n' "$repo" '^Co-Authored-By: Claude' "$@" > "$GUM_ANSWERS"; echo 0 > "$GUM_STATE"
    OUT="$(DRY_RC="$rc" MIND_TRICK_DIR="$T/engine" bash "$FRONT" </dev/null 2>&1)"; RC=$?
    CALLS="$(cat "$T/calls")"
}

echo "## 1. a failing dry run ends the run"
tui "$T/dirty-history" 1 yes yes
check "it exits non-zero"                  [ "$RC" -ne 0 ]
check "it never asks to rewrite"           bash -c '! grep -q "Rewrite history" <<<"$1"' _ "$OUT"
check "it never asks to force-push"        bash -c '! grep -q "force-push" <<<"$1"' _ "$OUT"
check "the engine ran once, as a dry run"  [ "$CALLS" = "--repo $T/dirty-history --pattern ^Co-Authored-By: Claude" ]

echo "## 2. a clean history asks nothing"
tui "$T/clean-history" 0 yes yes
check "it exits zero"                      [ "$RC" -eq 0 ]
check "it never asks to rewrite"           bash -c '! grep -q "Rewrite history" <<<"$1"' _ "$OUT"
check "no --apply reached the engine"      bash -c '! grep -q -- "--apply" <<<"$1"' _ "$CALLS"

echo "## 3. matches and a working engine: confirm, then apply"
tui "$T/dirty-history" 0 yes yes
check "it asks to rewrite"                 has "Rewrite history" "$OUT"
check "it asks to force-push"              has "force-push" "$OUT"
check "--apply --push reached the engine"  bash -c 'grep -q -- "--apply --push" <<<"$1"' _ "$CALLS"

echo "## 4. declining the rewrite applies nothing"
tui "$T/dirty-history" 0 no
check "it exits zero"                      [ "$RC" -eq 0 ]
check "no --apply reached the engine"      bash -c '! grep -q -- "--apply" <<<"$1"' _ "$CALLS"

echo
if (( FAILS )); then echo "${FAILS} check(s) failed"; exit 1; fi
echo "all checks passed"
