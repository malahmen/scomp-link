#!/usr/bin/env bash
# The navicomputer front-end, driven through the gum stub against the REAL
# engine with $SSH_DIR and $HOME pointed at a temp dir.
#
# What it protects is the one irreversible thing the menu can do: delete
# private keys (Kamino item 177). "Also delete its key files?" named nothing,
# and the engine deleted whatever the profile pointed at - ~/.ssh/id_ed25519
# included, while other profiles used it. So the question must name the exact
# paths, the engine's refusal must reach the screen with nothing removed, and
# the way on - remove the profile, keep the keys - must be offered, not taken.
#
# The other menu flows are driven too (Kamino 196): add, list, view, edit,
# use and import each reach the engine with what was typed, and the edit's
# `gum write` for the additional options keeps the profile's text on Enter
# and on Esc, replaces it with what was typed, and clears it only on purpose.
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FRONT="${TEST_DIR}/../scripts/navicomputer/navicomputer.sh"
[[ -f "$FRONT" ]] || { echo "front-end not found at $FRONT" >&2; exit 1; }
if [[ "${BASH_VERSINFO[0]:-0}" -lt 4 ]]; then
    for b in /opt/homebrew/bin/bash /usr/local/bin/bash; do [[ -x "$b" ]] && exec "$b" "$0" "$@"; done
    echo "SKIP - bash 4+ not found (the front-end needs it)"; exit 77
fi
command -v jq >/dev/null || { echo "SKIP - jq not installed (the engine needs it)"; exit 77; }

# The real engine, from a sibling checkout the way a user has it, or $NAVICOMPUTER.
REAL_ENGINE="${NAVICOMPUTER:-${TEST_DIR}/../../navicomputer/navicomputer.sh}"
if [[ ! -f "$REAL_ENGINE" ]]; then
    echo "SKIP - no navicomputer engine at ${REAL_ENGINE} (set \$NAVICOMPUTER)"; exit 77
fi
REAL_ENGINE="$(cd "$(dirname "$REAL_ENGINE")" && pwd)/$(basename "$REAL_ENGINE")"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
T="$(cd "$T" && pwd)"
FAILS=0
check() { local d="$1"; shift; if "$@"; then echo "   ok   - $d"; else echo "   FAIL - $d"; FAILS=$((FAILS + 1)); fi; }
has()   { case "$2" in *"$1"*) return 0 ;; *) return 1 ;; esac; }
hasnt() { ! has "$@"; }

# Nothing here may reach the real ~/.ssh: the engine honours $SSH_DIR, and
# $HOME is moved too, for anything that falls back to it.
export HOME="$T/home" SSH_DIR="$T/home/.ssh"
mkdir -p "$SSH_DIR"; chmod 700 "$SSH_DIR"
export PATH="${TEST_DIR}/stubs:$PATH"
export GUM_ANSWERS="$T/answers" GUM_STATE="$T/state"

# The engine the front-end resolves records its argv and runs the real one.
mkdir -p "$T/engine"
cat > "$T/engine/navicomputer.sh" <<WRAP
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$T/calls"
exec bash "$REAL_ENGINE" "\$@"
WRAP

OUT=""; CALLS=""
# tui <answer>... - one front-end run with those scripted gum answers.
tui() {
    : > "$T/calls"
    printf '%s\n' "$@" > "$GUM_ANSWERS"; echo 0 > "$GUM_STATE"
    OUT="$(NAVICOMPUTER_DIR="$T/engine" bash "$FRONT" </dev/null 2>&1)"
    CALLS="$(cat "$T/calls")"
}
eng()     { bash "$REAL_ENGINE" "$@" >/dev/null 2>&1; }
profile() { bash "$REAL_ENGINE" view --name "$1" --json >/dev/null 2>&1; }
# In this shell, not `bash -c '! profile x'`: the child has no such function,
# exits 127, and the negation passes.
gone()    { ! profile "$1"; }
key()     { printf 'PRIVATE\n' > "$SSH_DIR/$1"; printf 'PUBLIC\n' > "$SSH_DIR/$1.pub"; }
REMOVE="remove  — delete a profile"

echo "## 1. the question names the files, and a generated key goes"
key id_gen_ed25519
eng add --name gen --hostname gen.example --key "$SSH_DIR/id_gen_ed25519"
tui "$REMOVE" gen yes yes no
check "the question names the private key"      has "<confirm> Also delete these key files? $SSH_DIR/id_gen_ed25519 " "$OUT"
check "  and the public one"                    has "$SSH_DIR/id_gen_ed25519.pub -> yes" "$OUT"
check "remove is called with --delete-keys"     grep -qx -- "remove --name gen --delete-keys" <<<"$CALLS"
check "the private key is gone"                 test ! -e "$SSH_DIR/id_gen_ed25519"
check "the public key too"                      test ! -e "$SSH_DIR/id_gen_ed25519.pub"
check "so is the profile"                       gone gen

echo "## 2. a shared key: the engine refuses, the screen says so"
key id_ed25519
eng add --name gh --hostname github.com --key "$SSH_DIR/id_ed25519"
eng add --name gl --hostname gitlab.com --key "$SSH_DIR/id_ed25519"
tui "$REMOVE" gh yes yes no no
check "the question names ~/.ssh/id_ed25519"    has "Also delete these key files? $SSH_DIR/id_ed25519 $SSH_DIR/id_ed25519.pub" "$OUT"
check "the engine's refusal reaches the screen" has "not deleting $SSH_DIR/id_ed25519" "$OUT"
check "  with its reason"                       has "still in use by" "$OUT"
check "the front-end says nothing was removed"  has "Nothing was removed" "$OUT"
check "the key is still there"                  test -f "$SSH_DIR/id_ed25519"
check "  and its .pub"                          test -f "$SSH_DIR/id_ed25519.pub"
check "declined: gh is still a profile"         profile gh
check "remove was called once, with --delete-keys" test "$(grep -c '^remove ' <<<"$CALLS")" = 1

echo "## 3. ...and the profile can go with the key kept"
tui "$REMOVE" gh yes yes yes no
check "keeping the keys is offered"             has "<confirm> Remove profile 'gh' and keep its key files? -> yes" "$OUT"
check "then remove runs without --delete-keys"  grep -qx -- "remove --name gh" <<<"$CALLS"
check "gh is gone"                              gone gh
check "the key is still there"                  test -f "$SSH_DIR/id_ed25519"
check "gl is untouched"                         profile gl

echo "## 4. declining the key question removes only the profile"
key id_mine
eng add --name mine --hostname m.example --key "$SSH_DIR/id_mine"
tui "$REMOVE" mine yes no no
check "remove is called without --delete-keys"  grep -qx -- "remove --name mine" <<<"$CALLS"
check "the profile is gone"                     gone mine
check "the key is kept"                         test -f "$SSH_DIR/id_mine"
check "no keep-the-keys question was needed"    hasnt "and keep its key files" "$OUT"

echo "## 5. no key files, no key question"
eng add --name bare --hostname b.example --key "$SSH_DIR/id_absent"
tui "$REMOVE" bare yes no
check "the key question is not asked"           hasnt "Also delete" "$OUT"
check "the profile is gone"                     gone bare

echo "## 6. add: typed fields, an existing key, multi-line options"
ADD="add     — create a profile (generate/assign a key)"
EDIT="edit    — modify a profile"
key id_web
tui "$ADD" web "deploy@web.example" "" 2222 no "$SSH_DIR/id_web" 'ForwardAgent no\nProxyJump jump' yes no no no
J="$(bash "$REAL_ENGINE" view --name web --json 2>/dev/null)"
check "the profile exists"                       profile web
check "user@host split: User deploy"             [ "$(jq -r .user <<<"$J")" = deploy ]
check "  HostName web.example"                   [ "$(jq -r .hostname <<<"$J")" = web.example ]
check "port 2222"                                [ "$(jq -r .port <<<"$J")" = 2222 ]
check "the picked key"                           [ "$(jq -r .key <<<"$J")" = "$SSH_DIR/id_web" ]
check "both option lines, as typed"              [ "$(jq -r .additional <<<"$J")" = $'ForwardAgent no\nProxyJump jump' ]
check "the Host block is in ssh's config"        grep -q "^Host web$" "$SSH_DIR/config"

echo "## 7. add with no options: Enter in the empty editor passes none"
key id_plain
tui "$ADD" plain "" "" "" no "$SSH_DIR/id_plain" "" yes no no no
check "add has no --additional"                  bash -c '! grep -q -- "--additional" <<<"$1"' _ "$CALLS"
check "  HostName defaults to the alias"         [ "$(bash "$REAL_ENGINE" view --name plain --json | jq -r .hostname)" = plain ]
check "  user git, port 22"                      [ "$(bash "$REAL_ENGINE" view --name plain --json | jq -r '.user + ":" + .port')" = git:22 ]

echo "## 8. list and view"
tui "list    — show all profiles" no
check "list shows the profiles"                  bash -c 'grep -q web <<<"$1" && grep -q plain <<<"$1"' _ "$OUT"
tui "view    — show one profile + public key" web no
check "view shows the profile"                   has "web.example" "$OUT"
check "  and its public key"                     has "PUBLIC" "$OUT"

echo "## 9. edit: Enter everywhere keeps the profile as it was"
before="$(bash "$REAL_ENGINE" view --name web --json)"
tui "$EDIT" web "" "" "" "" "" no
check "the editor opened with the current options" has "(pre-filled: ForwardAgent no" "$OUT"
check "edit ran"                                 grep -q "^edit --name web " <<<"$CALLS"
check "  and nothing changed"                    [ "$(bash "$REAL_ENGINE" view --name web --json)" = "$before" ]

echo "## 10. edit: Esc in the editor keeps the options; typed fields change"
tui "$EDIT" web web2.example "" 2200 "" esc no
J="$(bash "$REAL_ENGINE" view --name web --json)"
check "HostName and port changed"                [ "$(jq -r '.hostname + ":" + .port' <<<"$J")" = web2.example:2200 ]
check "  the options kept"                       [ "$(jq -r .additional <<<"$J")" = $'ForwardAgent no\nProxyJump jump' ]

echo "## 11. edit: typed options replace them; a cleared editor clears them"
tui "$EDIT" web "" "" "" "" "ProxyJump other" no
check "the new options"                          [ "$(bash "$REAL_ENGINE" view --name web --json | jq -r .additional)" = "ProxyJump other" ]
check "  in ssh's config"                        grep -q "ProxyJump other" "$SSH_DIR/config"
tui "$EDIT" web "" "" "" "" "<clear>" no
check "cleared on purpose: no options"           [ -z "$(bash "$REAL_ENGINE" view --name web --json | jq -r '.additional // empty')" ]
check "  and gone from ssh's config"             bash -c '! grep -q "ProxyJump" "$1"' _ "$SSH_DIR/config"

echo "## 12. use: a new repository wired to the profile"
mkdir -p "$T/repo"
tui "use     — wire a profile to a git repo" "$T/repo" web yes "git@web:me/r.git" yes "Me" "me@example.com" no
check "use --init --remote --git-name --git-email" grep -qx -- "use --name web --repo $T/repo --init --remote git@web:me/r.git --git-name Me --git-email me@example.com" <<<"$CALLS"
check "the repository exists"                    test -d "$T/repo/.git"
check "  with the remote"                        [ "$(git -C "$T/repo" config remote.origin.url)" = "git@web:me/r.git" ]
check "  and the identity"                       [ "$(git -C "$T/repo" config user.email)" = "me@example.com" ]

echo "## 13. import: an unmanaged Host is adopted"
printf '\nHost legacy\n    HostName legacy.example\n    User old\n' >> "$SSH_DIR/config"
tui "import  — adopt unmanaged ~/.ssh/config hosts" legacy yes no
check "import --host legacy --remove-original"   grep -qx -- "import --host legacy --remove-original" <<<"$CALLS"
check "legacy is now a profile"                  profile legacy
check "  with its HostName"                      [ "$(bash "$REAL_ENGINE" view --name legacy --json | jq -r .hostname)" = legacy.example ]

echo
if (( FAILS )); then echo "${FAILS} check(s) failed"; exit 1; fi
echo "all checks passed"
