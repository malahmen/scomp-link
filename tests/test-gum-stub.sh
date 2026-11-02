#!/usr/bin/env bash
# The gum stub itself (tests/stubs/gum): every other test trusts it to answer
# as gum would, so where it differs from gum a front-end's bug passes there.
#
# What it protects (Kamino item 196): `input` and `write` open holding
# --value, so Enter (a blank answer) returns it - the stub used to drop it,
# and a prompt that saves whatever comes back looked as if Enter kept the
# setting; "<clear>" empties the field; Esc, or no answer left, exits 130 as
# gum does; `confirm` answers Enter with --default; `filter` refuses an answer
# it did not offer, as `choose` does; a command gum lacks exits 80 and one the
# stub does not model fails, where both used to print nothing and exit 0.
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUM="${TEST_DIR}/stubs/gum"
if [[ "${BASH_VERSINFO[0]:-0}" -lt 4 ]]; then
    for b in /opt/homebrew/bin/bash /usr/local/bin/bash; do [[ -x "$b" ]] && exec "$b" "$0" "$@"; done
    echo "SKIP - bash 4+ not found (the stub needs it)"; exit 77
fi

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
FAILS=0
check() { local d="$1"; shift; if "$@"; then echo "   ok   - $d"; else echo "   FAIL - $d"; FAILS=$((FAILS + 1)); fi; }
export GUM_ANSWERS="$T/answers" GUM_STATE="$T/state"
# This file provokes refusals on purpose: they go to its own log, not to
# run-all.sh's, which would fail the run for them.
export GUM_STUB_ERRLOG="$T/errlog"

# g <answer>... -- <gum args>: the stub's stdout in $T/o, its status in $T/rc.
g() {
    local -a ans=()
    while [[ "$1" != -- ]]; do ans+=("$1"); shift; done; shift
    if (( ${#ans[@]} )); then printf '%s\n' "${ans[@]}" > "$GUM_ANSWERS"; else : > "$GUM_ANSWERS"; fi
    : > "$GUM_STATE"; : > "$GUM_STUB_ERRLOG"
    bash "$GUM" "$@" > "$T/o" 2> "$T/e" < /dev/null; echo $? > "$T/rc"
}
out() { [[ "$(cat "$T/o")" == "$1" ]]; }
rc()  { [[ "$(cat "$T/rc")" == "$1" ]]; }

echo "# input: --value is in the field when it opens"
g "" -- input --value "Teldrassil" --header "Realm name:"
check "Enter on a pre-filled field returns the value" out "Teldrassil"
check "  and exits 0" rc 0
g "" -- input --header "x" --value=120
check "--value=V is the same" out "120"
g "" -- input --header "x"
check "Enter on an empty field returns nothing" out ""
g "Darnassus" -- input --value "Teldrassil"
check "an answer is what the user left in the field" out "Darnassus"
g "<clear>" -- input --value "Teldrassil"
check "<clear>: the user emptied it" out ""
check "  and exits 0" rc 0
g esc -- input --value "Teldrassil"
check "esc exits 130" rc 130
check "  printing nothing" out ""
g -- input --value "Teldrassil"
check "no answer left is Esc: 130, not an empty answer" rc 130
g 's3cret' -- input --password --header "Password:"
check "--password takes no value: the answer comes back" out "s3cret"

echo "# write: the same, several lines"
g "" -- write --value "Host a"
check "Enter keeps --value" out "Host a"
g 'IdentitiesOnly yes\nProxyJump j' -- write --placeholder "x"
check "a \\n in the answer is a line break" out $'IdentitiesOnly yes\nProxyJump j'
g esc -- write
check "esc exits 130" rc 130

echo "# confirm: Enter is --default"
g enter -- confirm --default=false "Delete?"
check "--default=false: Enter is no (exit 1)" rc 1
g enter -- confirm "Go?"
check "no --default: Enter is yes" rc 0
g esc -- confirm "Go?"
check "esc exits 130" rc 130

echo "# filter: choose with a search box"
printf 'a.sh\nb.sh\n' > "$T/list"
printf '%s\n' b.sh > "$GUM_ANSWERS"; : > "$GUM_STATE"
bash "$GUM" filter --header "Pick" --placeholder "type to filter..." --height 15 < "$T/list" > "$T/o" 2>/dev/null; echo $? > "$T/rc"
check "an offered item is picked (flags' values are not items)" out "b.sh"
printf '%s\n' "type to filter..." > "$GUM_ANSWERS"; : > "$GUM_STATE"; : > "$GUM_STUB_ERRLOG"
bash "$GUM" filter --placeholder "type to filter..." < "$T/list" > "$T/o" 2>/dev/null; echo $? > "$T/rc"
check "the placeholder is not an item: refused" rc 1
check "  and logged" grep -q 'not offered' "$GUM_STUB_ERRLOG"
g -- filter a b
check "no answer is Esc: 130" rc 130

echo "# commands"
g -- frobnicate
check "a command gum lacks exits 80, as gum does" rc 80
check "  and is logged" grep -q 'no such gum command' "$GUM_STUB_ERRLOG"
g -- table
check "a gum command the stub does not model fails" rc 1
check "  and is logged" grep -q 'not modelled' "$GUM_STUB_ERRLOG"
g -- style --foreground 1 "hi"
check "style still draws, exit 0" rc 0

echo; if (( FAILS == 0 )); then echo "all passed"; else echo "${FAILS} failed"; exit 1; fi
