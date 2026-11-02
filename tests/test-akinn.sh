#!/usr/bin/env bash
# The akinn front-end, driven through the gum stub against a fake akinn
# checkout (AKINN_DIR: akinn.sh, constants.sh, regex.sh) whose akinn.sh
# records every call, its arguments joined with '|'. curl is a stub that
# fetches nothing, so the versions are typed (the front-end's fallback).
#
# What it protects: every value reaches akinn as one argument - in the run and
# in the command printed to paste on the node, where a space or a glob
# character used to split or expand (Kamino 196); running akinn, which
# provisions this machine as root, does nothing on Enter or no
# (--default=false); Esc or a blank required answer returns to the menu; the
# master and worker flags.
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FRONT="${TEST_DIR}/../scripts/akinn/akinn_tui.sh"
[[ -f "$FRONT" ]] || { echo "front-end not found at $FRONT" >&2; exit 1; }
if [[ "${BASH_VERSINFO[0]:-0}" -lt 4 ]]; then
    for b in /opt/homebrew/bin/bash /usr/local/bin/bash; do [[ -x "$b" ]] && exec "$b" "$0" "$@"; done
    echo "SKIP - bash 4+ not found (the tests need it)"; exit 77
fi

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
FAILS=0
check() { local d="$1"; shift; if "$@"; then echo "   ok   - $d"; else echo "   FAIL - $d"; FAILS=$((FAILS + 1)); fi; }

mkdir -p "$T/akinn" "$T/bin" "$T/home" "$T/globdir"
cat > "$T/akinn/akinn.sh" <<EOF
#!/bin/sh
(IFS='|'; printf '%s\n' "\$*") >> "$T/calls"
exit 0
EOF
printf 'K_RELEASES=https://example.invalid/k8s\nCRDS_RELEASES=https://example.invalid/calico\n' > "$T/akinn/constants.sh"
printf 're_kver="v[0-9]+[.][0-9]+[.][0-9]+"\nre_crds_ver="release-v[0-9.]+"\n' > "$T/akinn/regex.sh"
printf '#!/bin/sh\nexit 0\n' > "$T/bin/curl"
cp "${TEST_DIR}/stubs/gum" "$T/bin/gum"
chmod +x "$T/bin/"*
# A file the glob in the node name below matches, where the printed command
# is pasted: an unquoted "my node*" would expand to it.
: > "$T/globdir/node-glob-hit"

MASTER="master — initialize a new control-plane node"
WORKER="worker — join this node to an existing cluster"
RUN="run    — execute on THIS machine now (provisions it as root)"
PRINT="print  — just show the command to run on the node yourself"
QUIT="── quit"

# drive <answer>... - one answer per prompt, in order; the session ends at quit.
drive() {
    printf '%s\n' "$@" > "$T/answers"
    rm -f "$T/calls" "$T/state"; : > "$T/calls"
    PATH="$T/bin:$PATH" HOME="$T/home" GUM_ANSWERS="$T/answers" GUM_STATE="$T/state" \
        AKINN_DIR="$T/akinn" "$BASH" "$FRONT" > "$T/out" 2>&1
}
called()   { grep -qxF -- "$1" "$T/calls"; }
no_calls() { [[ ! -s "$T/calls" ]]; }
at_quit()  { grep -q "<choose> $QUIT" "$T/out"; }
# The arguments the printed command gives when pasted into a shell, in the
# glob directory, one per line, joined with '|'.
# shellcheck disable=SC2120  # $* is what the eval'd `set --` put there
pasted() {
    local line
    line="$(grep 'sh akinn.sh' "$T/out" | tail -1)"; line="${line#*sh akinn.sh }"
    (cd "$T/globdir" && eval "set -- $line" && IFS='|' && printf '%s\n' "$*")
}

NODE='my node*'
MFLAGS="-m|${NODE}|-a|arm64|-v|v1.30|-c|v3.25.2|-n|10.244.0.0/16"

echo "# every value is one argument, run or pasted (Kamino 196)"
drive "$MASTER" "$NODE" arm64 v1.30 v3.25.2 "" "" "$PRINT" yes "$QUIT"
check "printed: the pasted command gives the node name whole" [ "$(pasted)" = "$MFLAGS" ]
check "  print runs nothing" no_calls
check "  back at the menu" at_quit
drive "$MASTER" "$NODE" arm64 v1.30 v3.25.2 "" "" "$RUN" yes yes "$QUIT"
check "run: akinn gets the node name as one argument" called "$MFLAGS"
check "  the command shown before it pastes the same way" [ "$(pasted)" = "$MFLAGS" ]

echo "# running akinn needs a yes"
drive "$MASTER" "$NODE" arm64 v1.30 v3.25.2 "" "" "$RUN" enter yes "$QUIT"
check "Enter: akinn is not run" no_calls
drive "$MASTER" "$NODE" arm64 v1.30 v3.25.2 "" "" "$RUN" no yes "$QUIT"
check "no: akinn is not run" no_calls
check "  back at the menu" at_quit

echo "# flags"
drive "$MASTER" k8s-master-1 arm64 v1.31 v3.28.0 "10.10.0.0/16" 192.168.1.10 "$RUN" yes yes "$QUIT"
check "master with a CIDR and an advertise IP" called "-m|k8s-master-1|-a|arm64|-v|v1.31|-c|v3.28.0|-n|10.10.0.0/16|-i|192.168.1.10"
drive "$WORKER" w1 arm64 v1.30 192.168.1.10 "" pi "" "" "" "$RUN" yes yes "$QUIT"
check "worker: the pre-filled port and files" called "-w|w1|-a|arm64|-v|v1.30|-i|192.168.1.10|-p|6443|-u|pi|-l|$T/home/.akinn/master_login|-t|$T/home/master_node/token|-h|$T/home/master_node/hash"
drive "$WORKER" w1 arm64 v1.30 192.168.1.10 "" "pi" "$T/home/my login" "" "" "$PRINT" yes "$QUIT"
check "worker printed: a login path with a space pastes whole" bash -c '[[ "$1" == *"|-l|$2/home/my login|"* ]]' _ "$(pasted)" "$T"

echo "# Esc or a blank required answer returns to the menu"
drive "$MASTER" esc yes "$QUIT"
check "Esc on the node name" bash -c '[[ ! -s "$1" ]] && grep -q "<choose> ── quit" "$2"' _ "$T/calls" "$T/out"
drive "$MASTER" "" yes "$QUIT"
check "blank node name" bash -c '[[ ! -s "$1" ]] && grep -q "<choose> ── quit" "$2"' _ "$T/calls" "$T/out"
drive "$MASTER" k1 arm64 "" yes "$QUIT"
check "blank Kubernetes version" bash -c '[[ ! -s "$1" ]] && grep -q "<choose> ── quit" "$2"' _ "$T/calls" "$T/out"
drive "$WORKER" w1 arm64 v1.30 "" yes "$QUIT"
check "blank master IP" bash -c '[[ ! -s "$1" ]] && grep -q "<choose> ── quit" "$2"' _ "$T/calls" "$T/out"
drive "$MASTER" k1 arm64 v1.30 v3.25.2 "" "" esc yes "$QUIT"
check "Esc on run/print: nothing run" bash -c '[[ ! -s "$1" ]] && grep -q "<choose> ── quit" "$2"' _ "$T/calls" "$T/out"

echo
if (( FAILS )); then echo "FAILED: ${FAILS} check(s)"; exit 1; fi
echo "All akinn checks passed."
