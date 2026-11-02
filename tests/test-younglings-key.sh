#!/usr/bin/env bash
# The younglings-key front-end, driven through the gum stub against a fake
# ignite.sh (YOUNGLINGS_KEY_DIR) that records every call it is given, one per
# line, its arguments joined with '|'.
#
# What it protects: a blank or Esc'd answer anywhere in a mode goes back to
# the menu - a blank domain used to close the whole TUI under set -e (Kamino
# 196, the class of Kamino 104); each menu entry reaches the engine with its
# flags, a subject with spaces as one argument; the CA passphrase is asked as
# a file and only that path reaches argv; moving a CA key and installing into
# the trust store do nothing on Enter or no (both --default=false), and the
# trust store install is the only thing that reaches sudo.
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FRONT="${TEST_DIR}/../scripts/younglings-key/younglings-key.sh"
[[ -f "$FRONT" ]] || { echo "front-end not found at $FRONT" >&2; exit 1; }
if [[ "${BASH_VERSINFO[0]:-0}" -lt 4 ]]; then
    for b in /opt/homebrew/bin/bash /usr/local/bin/bash; do [[ -x "$b" ]] && exec "$b" "$0" "$@"; done
    echo "SKIP - bash 4+ not found (the front-end needs it)"; exit 77
fi

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
FAILS=0
check() { local d="$1"; shift; if "$@"; then echo "   ok   - $d"; else echo "   FAIL - $d"; FAILS=$((FAILS + 1)); fi; }

mkdir -p "$T/engine" "$T/bin" "$T/home" "$T/work"
cat > "$T/engine/ignite.sh" <<EOF
#!/usr/bin/env bash
(IFS='|'; printf '%s\n' "\$*") >> "$T/calls"
exit 0
EOF
# sudo records what it was asked to run and runs nothing; openssl only has to
# exist (the front-end checks for it); open/xdg-open must never be reached
# for real.
cat > "$T/bin/sudo" <<EOF
#!/usr/bin/env bash
(IFS='|'; printf 'sudo|%s\n' "\$*") >> "$T/calls"
EOF
printf '#!/bin/sh\nexit 0\n' > "$T/bin/openssl"
printf '#!/bin/sh\nexit 0\n' > "$T/bin/open"
printf '#!/bin/sh\nexit 0\n' > "$T/bin/xdg-open"
cp "${TEST_DIR}/stubs/gum" "$T/bin/gum"
chmod +x "$T/bin/"*
printf '[req]\n' > "$T/work/site.cfg"
printf 'not a real certificate\n' > "$T/work/ca.crt"
OUT="$T/out-certs"   # never created: the engine is fake

# drive <answer>... - one answer per prompt, in order; the session ends at Quit.
drive() {
    printf '%s\n' "$@" > "$T/answers"
    rm -f "$T/calls" "$T/state"; : > "$T/calls"
    (cd "$T/work" && PATH="$T/bin:$PATH" HOME="$T/home" GUM_ANSWERS="$T/answers" GUM_STATE="$T/state" \
        YOUNGLINGS_KEY_DIR="$T/engine" "$BASH" "$FRONT") > "$T/out" 2>&1
}
called()     { grep -qxF -- "$1" "$T/calls"; }
not_called() { ! grep -q -- "$1" "$T/calls"; }
no_calls()   { [[ ! -s "$T/calls" ]]; }
# The answer to the second main menu was read: the TUI went back to the menu.
back_at_menu() { grep -q '<choose> Quit' "$T/out"; }

echo "# a blank or Esc'd answer goes back to the menu (Kamino 196)"
drive "Self-signed certificate" "" Quit
check "blank domain: back at the menu, not out of the TUI" back_at_menu
check "  and the engine is not run" no_calls
for m in "Config template (.cfg)" "Certificate request (CSR)" "Convert .crt → .cert/.pem"; do
    drive "$m" "" Quit
    check "blank domain in '$m': back at the menu" back_at_menu
done
drive "Self-signed certificate" esc Quit
check "Esc on the domain: back at the menu" back_at_menu
drive "Self-signed certificate" example.com esc Quit
check "Esc on the key size: back at the menu" back_at_menu
check "  and no run with a key size nobody picked" no_calls
drive "Certificate request (CSR)" example.com 2048 "<clear>" Quit
check "output directory emptied: back at the menu, nothing run" bash -c 'grep -q "<choose> Quit" "$1" && [[ ! -s "$2" ]]' _ "$T/out" "$T/calls"
drive "Certificate request (CSR)" example.com 2048 "$OUT" "Subject string (-i)" "" Quit
check "blank subject: back at the menu, nothing run" bash -c 'grep -q "<choose> Quit" "$1" && [[ ! -s "$2" ]]' _ "$T/out" "$T/calls"

echo "# each mode's flags"
drive "Self-signed certificate" example.com 4096 "" "" "$OUT" "Subject string (-i)" "/C=PT/O=Acme Corp/CN=example.com" "" enter Quit
check "self-signed: Enter keeps 398/3650, the subject is one argument" called "-d|example.com|-s|1|-n|4096|-t|398|-c|3650|-o|$OUT|-i|/C=PT/O=Acme Corp/CN=example.com"
check "  and the TUI is back at the menu after the run" back_at_menu
drive "Self-signed certificate" example.com 2048 90 1000 "$OUT" "Subject string (-i)" "/CN=example.com" "/CN=Acme Root CA" yes "$T/home/ca.pass" Quit
check "an encrypted CA: -a, then -p <file> and -E" called "-d|example.com|-s|1|-n|2048|-t|90|-c|1000|-o|$OUT|-i|/CN=example.com|-a|/CN=Acme Root CA|-p|$T/home/ca.pass|-E"
drive "Self-signed certificate" example.com 2048 "" "" "$OUT" "Subject string (-i)" "/CN=example.com" "" yes "" Quit
check "encryption asked but no file given: no -E, no -p" bash -c 'grep -q "^-d|example.com" "$1" && ! grep -q -- "|-E" "$1" && ! grep -q -- "|-p|" "$1"' _ "$T/calls"
drive "Certificate request (CSR)" site.example 3072 "$OUT" "openssl config file (-f)" "site.cfg" Quit
check "CSR from a config file" called "-d|site.example|-s|0|-n|3072|-o|$OUT|-f|site.cfg"
drive "Config template (.cfg)" site.example 2048 "$OUT" Quit
check "config template" called "-d|site.example|-g|1|-n|2048|-o|$OUT"
drive "Convert .crt → .cert/.pem" site.example "$OUT" "my site.crt" yes "my site.key" Quit
check "convert with a .pem: -r and -k, each one argument" called "-d|site.example|-o|$OUT|-r|my site.crt|-k|my site.key"

echo "# moving a CA key: nothing without a yes"
drive "Protect an existing CA key (move to 0700)" "" enter Quit
check "Enter on 'Move the CA key?' moves nothing" no_calls
drive "Protect an existing CA key (move to 0700)" "" no Quit
check "no moves nothing" no_calls
drive "Protect an existing CA key (move to 0700)" "" yes Quit
check "yes: -R on the pre-filled directory" called "-R|-o|$T/home/.local/share/kuat-pki"

echo "# installing into the trust store: sudo only on a yes"
drive "Install a certificate (trust store)" "ca.crt" "" enter Quit
check "Enter: the dry view, without sudo" called "-I|ca.crt"
check "  sudo is not run" not_called "sudo"
drive "Install a certificate (trust store)" "ca.crt" "Acme Root" no Quit
check "no: the dry view with the name" called "-I|ca.crt|-N|Acme Root"
check "  sudo is not run" not_called "sudo"
drive "Install a certificate (trust store)" "ca.crt" "" yes Quit
check "yes: the engine under sudo" bash -c 'grep -q "^sudo|bash|.*/ignite.sh|-I|ca.crt$" "$1"' _ "$T/calls"
drive "Install a certificate (trust store)" "" Quit
check "blank certificate path: back at the menu, nothing run" bash -c 'grep -q "<choose> Quit" "$1" && [[ ! -s "$2" ]]' _ "$T/out" "$T/calls"

echo
if (( FAILS )); then echo "FAILED: ${FAILS} check(s)"; exit 1; fi
echo "All younglings-key checks passed."
