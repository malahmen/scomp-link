#!/usr/bin/env bash
# Run every tests/test-*.sh and exit non-zero if any fails. No network, no
# terminal: the front-ends are driven through a gum stub (tests/stubs/gum).
#
# A test that cannot run here - no sibling engine checkout, no jq, no bash 4 -
# exits 77 and is reported as SKIP, not PASS: a skipped file used to print
# PASS, and three front-ends' suites had never run in CI while it said so
# (Kamino item 24). `--strict` makes a skip fail the run; CI passes it.
#
# Usage: tests/run-all.sh [--strict]
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
strict=0
case "${1:-}" in
    --strict) strict=1 ;;
    "") ;;
    *) echo "usage: tests/run-all.sh [--strict]" >&2; exit 2 ;;
esac
failed=() skipped=()
# The gum stub logs every answer it refused here (see tests/stubs/gum): a
# test whose front-end was offered the wrong menu fails even if every one of
# its checks passed.
errlog="$(mktemp)"; trap 'rm -f "$errlog"' EXIT
export GUM_STUB_ERRLOG="$errlog"
for t in "$TEST_DIR"/test-*.sh; do
    name="$(basename "$t")"
    : > "$errlog"
    out="$(bash "$t" 2>&1)"; rc=$?
    if [[ -s "$errlog" ]] && (( rc == 0 )); then
        out+=$'\n'"$(sed 's/^/FAIL - gum stub: /' "$errlog")"; rc=1
    fi
    if (( rc == 0 )); then
        echo "PASS  ${name}"
    elif (( rc == 77 )); then
        echo "SKIP  ${name}"; grep -E '^ *SKIP' <<< "$out" | sed 's/^/        /'
        skipped+=("$name")
    else
        echo "FAIL  ${name}"; grep -E '^ *FAIL' <<< "$out" | sed 's/^/        /'
        failed+=("$name")
    fi
done
echo
if (( ${#skipped[@]} )); then echo "${#skipped[@]} test file(s) skipped: ${skipped[*]}"; fi
if (( ${#failed[@]} )); then echo "${#failed[@]} test file(s) failed: ${failed[*]}"; exit 1; fi
if (( ${#skipped[@]} && strict )); then echo "--strict: a skipped file is a failure here"; exit 1; fi
echo "all test files passed"
