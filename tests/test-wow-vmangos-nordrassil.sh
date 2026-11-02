#!/usr/bin/env bash
# The wow-vmangos-nordrassil front-end's restore, driven through the gum stub
# against a fake engine (NORDRASSIL_DIR) that records every call it is given
# and keeps the real engine's restore contract (nordrassil lib/db.sh
# cmd_restore): without --yes it reads the dump, prints 'target:' and
# 'OVERWRITES:' on stderr and exits 1 having changed nothing; with --yes it
# restores. It can also refuse outright, printing no OVERWRITES line, as the
# real one does for an unreadable file, --db on a self-describing dump or no
# reachable database.
#
# The main menu's other paths are driven too (Kamino 196): each action reaches
# the engine with the flags its answers mean, and every destructive question
# (delete-account, apply-sql, restart) runs nothing on a no or on Enter.
#
# What the restore part protects (Kamino item 178): the question is asked only after the
# engine has said what it would overwrite, and its words are in the question;
# declining, or pressing Enter, runs nothing with --yes; a restore the engine
# refuses is never offered for confirmation.
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FRONT="${TEST_DIR}/../scripts/wow-vmangos-nordrassil/wow-vmangos-nordrassil.sh"
[[ -f "$FRONT" ]] || { echo "front-end not found at $FRONT" >&2; exit 1; }
if [[ "${BASH_VERSINFO[0]:-0}" -lt 4 ]]; then
    for b in /opt/homebrew/bin/bash /usr/local/bin/bash; do [[ -x "$b" ]] && exec "$b" "$0" "$@"; done
    echo "SKIP - bash 4+ not found (the front-end needs it)"; exit 77
fi

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
FAILS=0
check() { local d="$1"; shift; if "$@"; then echo "   ok   - $d"; else echo "   FAIL - $d"; FAILS=$((FAILS + 1)); fi; }

mkdir -p "$T/engine" "$T/bin" "$T/config/nordrassil/dumps"
cat > "$T/engine/nordrassil.sh" <<EOF
#!/usr/bin/env bash
# get answers from \$T/settings (KEY=VALUE lines) when a test writes one:
# the values the prompts open holding.
if [[ "\${1:-}" == get ]]; then
    [[ -f "$T/settings" ]] && sed -n "s/^\$2=//p" "$T/settings" | tail -1
    exit 0
fi
[[ "\${1:-}" == profiles ]] && exit 0
(IFS='|'; printf '%s\n' "\$*") >> "$T/calls"
[[ "\${1:-}" == create-account ]] && cat > "$T/stdin"
if [[ "\${1:-}" == restore ]]; then
    yes=0; db=""
    while [[ \$# -gt 0 ]]; do case "\$1" in --yes) yes=1; shift ;; --db) db="\$2"; shift 2 ;; *) shift ;; esac; done
    if [[ -n "\${STUB_REFUSE:-}" ]]; then
        printf '\033[31m[error]\033[0m restore: refusing --db on a self-describing dump.\n' >&2; exit 1
    fi
    printf '\033[33m[warn]\033[0m  target:   <base config> - tcp 10.0.0.9:3306, as mangos\n' >&2
    printf '\033[33m[warn]\033[0m  OVERWRITES: %s\n' "\${db:+\$db (forced with --db)}\${db:-mangos realmd}" >&2
    if (( ! yes )); then
        printf '\033[31m[error]\033[0m restore: refusing without --yes.\n' >&2; exit 1
    fi
    echo RESTORED >> "$T/calls"
fi
exit 0
EOF
cp "${TEST_DIR}/stubs/gum" "$T/bin/gum"; chmod +x "$T/bin/gum"
D="$T/config/nordrassil/dumps"
printf -- '-- MariaDB dump\nCREATE DATABASE IF NOT EXISTS `mangos`;\nUSE `mangos`;\n' > "$D/full-20261025-000000.sql"
printf -- '-- MariaDB dump\nINSERT INTO `account` VALUES (1);\n' > "$D/tables-20261024-000000.sql"
touch -t 202610250000 "$D/full-20261025-000000.sql"; touch -t 202610240000 "$D/tables-20261024-000000.sql"

# drive <answer>... — one answer per prompt, in order; the session ends at Quit.
drive() {
    printf '%s\n' "$@" > "$T/answers"
    rm -f "$T/calls" "$T/state" "$T/stdin"; : > "$T/calls"
    PATH="$T/bin:$PATH" GUM_ANSWERS="$T/answers" GUM_STATE="$T/state" NORDRASSIL_DIR="$T/engine" \
        XDG_CONFIG_HOME="$T/config" "$BASH" "$FRONT" > "$T/out" 2>&1
}
called()     { grep -qxF -- "$1" "$T/calls"; }
not_called() { ! grep -q -- "$1" "$T/calls"; }
# The text of the restore confirmation, as the stub echoed it (it may span lines).
question()   { awk '/^<confirm> .*Restore /{on=1} on{print} on && / -> /{exit}' "$T/out"; }
asked()      { question | grep -qF -- "$1"; }
no_colour()  { [[ "$(question)" != *$'\e'* ]]; }

FULL="$D/full-20261025-000000.sql"
echo "# restore: the engine says what it would overwrite, then the question"
drive Administration restore full-20261025-000000.sql no back Quit
check "the engine is asked first, without --yes" called "restore|--file|$FULL"
check "the question carries the engine's OVERWRITES line" asked "OVERWRITES: mangos realmd"
check "  and its target" asked "target:   <base config> - tcp 10.0.0.9:3306, as mangos"
check "  with no colour codes in it" no_colour
check "declined: no restore with --yes" not_called "--yes"
check "  and nothing restored" not_called RESTORED

drive Administration restore full-20261025-000000.sql enter back Quit
check "Enter (the default): no restore with --yes" not_called "--yes"

drive Administration restore full-20261025-000000.sql yes back Quit
check "confirmed: restore --yes, after the preview" bash -c 'sed -n 1p "$1" | grep -qxF "restore|--file|$2" && sed -n 2p "$1" | grep -qxF "restore|--file|$2|--yes"' _ "$T/calls" "$FULL"
check "  and it restores" called RESTORED

echo "# a table subset: --db in the preview and in the question"
drive Administration restore tables-20261024-000000.sql characters yes back Quit
check "the preview carries --db" called "restore|--file|$D/tables-20261024-000000.sql|--db|characters"
check "the question names the forced database" asked "OVERWRITES: characters (forced with --db)"
check "confirmed: --db and --yes" called "restore|--file|$D/tables-20261024-000000.sql|--db|characters|--yes"

echo "# the engine refuses: nothing to confirm"
STUB_REFUSE=1 drive Administration restore full-20261025-000000.sql back Quit
check "no question is asked" bash -c '! grep -q "^<confirm> .*Restore " "$1"' _ "$T/out"
check "no restore with --yes" not_called "--yes"
check "the refusal is shown" grep -q "refusing --db on a self-describing dump" "$T/out"

echo "# Server"
drive Server choose-server "base config (no profile)" settings forget-password \
    ownership "something else — Ansible, GitOps, CI (administration only)" back Quit
check "settings: config" called "config"
check "forget-password: forget" called "forget"
check "ownership: MANAGED_EXTERNALLY set from the pick" called "set|MANAGED_EXTERNALLY|1"

drive Server transports "this tool — configure, run-docker, run-k8s" \
    "connect straight to a MariaDB port" "10.0.0.9" "3307" "wow" \
    "Ask once per session (never written to disk)" \
    "docker exec into a container" "" "/opt/mangos/fifo" "mangosd" back Quit
check "transports: DB over tcp" called "set|DB_TRANSPORT|tcp"
check "  host and port" bash -c 'grep -qxF "set|DB_HOST|10.0.0.9" "$1" && grep -qxF "set|DB_PORT|3307" "$1"' _ "$T/calls"
check "  user" called "set|DB_USER|wow"
check "  password: ask (never stored)" called "set|DB_PASS|ask"
check "  server over docker" called "set|SERVER_TRANSPORT|docker"
check "  this machine (blank), already blank: not re-set (Kamino 235)" not_called "set|SERVER_SSH_HOST"
check "  FIFO and container" bash -c 'grep -qxF "set|SERVER_FIFO|/opt/mangos/fifo" "$1" && grep -qxF "set|SERVER_CONTAINER_NAME|mangosd" "$1"' _ "$T/calls"

echo "# Setup"
drive Setup install-deps edit "realmd (login/security settings)" back Quit
check "install-deps" called "install-deps"
check "edit: --file realmd" called "edit|--file|realmd"
# configure: every setting prompt, in order. Enter on an empty pre-fill
# writes nothing; the picks are the values behind the labels.
drive Setup configure /repack 10.0.0.5 "My Realm" "United States" PvP "" 1.12 'Hi "all"' 2 "" \
    "" "" "Ban Account" "No" "Yes" "Disabled" "Basic Latin only" back Quit
check "configure: SOURCE_DIR and REALM_ADDRESS" bash -c 'grep -qxF "set|SOURCE_DIR|/repack" "$1" && grep -qxF "set|REALM_ADDRESS|10.0.0.5" "$1"' _ "$T/calls"
check "  realm name, zone 2, PvP 1, patch 10" bash -c 'grep -qxF "set|REALM_NAME|My Realm" "$1" && grep -qxF "set|REALM_ZONE|2" "$1" && grep -qxF "set|GAME_TYPE|1" "$1" && grep -qxF "set|WOW_PATCH|10" "$1"' _ "$T/calls"
check "  Enter on an empty field sets nothing" bash -c '! grep -q "^set|PLAYER_LIMIT\|^set|DROP_RATE\|^set|WRONG_PASS_MAX_COUNT" "$1"' _ "$T/calls"
check "  MOTD without its double quotes" called "set|MOTD|Hi all"
check "  XP rate" called "set|XP_RATE|2"
check "  ban type, warden off, strict names 1" bash -c 'grep -qxF "set|WRONG_PASS_BAN_TYPE|1" "$1" && grep -qxF "set|WARDEN_ENABLED|0" "$1" && grep -qxF "set|STRICT_PLAYER_NAMES|1" "$1"' _ "$T/calls"
check "  then configure, with no custom SQL" bash -c 'tail -1 "$1" | grep -qxF configure' _ "$T/calls"

echo "# pre-filled answers are not saved again (Kamino 235)"
# Every prompt opens holding the engine's current value (gum --value, the
# picker's current choice): Enter hands it back. Saving it anyway pinned an
# inherited value into the profile - teldrassil's _set_if class (Kamino 196).
cat > "$T/settings" <<'SETTINGS'
REALM_NAME=Nordrassil
REALM_ZONE=1
GAME_TYPE=0
PLAYER_LIMIT=100
WOW_PATCH=10
MOTD=Welcome
XP_RATE=1
DROP_RATE=1
WRONG_PASS_MAX_COUNT=0
REQ_EMAIL_VERIFICATION=0
STRICT_VERSION_CHECK=1
WARDEN_ENABLED=1
STRICT_PLAYER_NAMES=0
SOURCE_DIR=/repack
REALM_ADDRESS=10.0.0.5
MANAGED_EXTERNALLY=0
DB_TRANSPORT=docker
DB_SSH_HOST=meksha
DB_CONTAINER_NAME=mariadb
DB_USER=mangos
DB_PASS=ask
SERVER_TRANSPORT=docker
SERVER_SSH_HOST=meksha
SERVER_FIFO=/opt/fifo
SERVER_CONTAINER_NAME=mangosd
K8S_NAMESPACE=wow
K8S_STORAGE_TYPE=hostpath
K8S_DATA_HOSTPATH=/srv/data
K8S_DB_HOSTPATH=/srv/db
SETTINGS
drive Setup configure "" "" "" esc esc "" esc "" "" "" "" esc esc esc esc back Quit
check "configure, Enter and Esc throughout: nothing is set" not_called "set|"
check "  configure still runs" called configure
drive Setup configure "" "" "" esc esc "" esc "" 3 "" "" esc esc esc esc back Quit
check "  a changed answer is set" called "set|XP_RATE|3"
check "  and only that one" bash -c '[ "$(grep -c "^set|" "$1")" = 1 ]' _ "$T/calls"
drive Server transports esc esc "" "" "" esc esc "" "" "" back Quit
check "transports, Enter and Esc throughout: nothing is set" not_called "set|"
drive Server transports esc esc "" "" "" "Ask once per session (never written to disk)" esc "" "" "" back Quit
check "  picking the password mode it already has: not set" not_called "set|DB_PASS"
drive Server transports esc esc "" "" root esc esc "" "" "" back Quit
check "  a changed user is set, alone" bash -c 'grep -qxF "set|DB_USER|root" "$1" && [ "$(grep -c "^set|" "$1")" = 1 ]' _ "$T/calls"
drive Deploy run-k8s "Current kube-context" "" "" esc "" "" back Quit
check "run-k8s, Enter throughout: nothing is set" not_called "set|"
check "  and run-k8s still gets the namespace and address" called "run-k8s|--namespace|wow|--address|10.0.0.5"
rm -f "$T/settings"

echo "# Local and Deploy"
drive Local start stop back Quit
check "start and stop" bash -c 'grep -qxF start "$1" && grep -qxF stop "$1"' _ "$T/calls"
drive Deploy build-image run-docker no run-docker enter stop-docker back Quit
check "build-image" called "build-image"
check "run-docker, declined recreate: no --force" called "run-docker"
check "run-docker, Enter (default yes): --force" called "run-docker|--force"
check "stop-docker" called "stop-docker"
drive Deploy run-k8s "A named kube-context" lab wow 10.0.0.7 \
    "hostPath (single-node / home-lab — path on the node)" /srv/data /srv/db \
    stop-k8s "Current kube-context" back Quit
check "run-k8s: settings saved against the chosen context" bash -c 'grep -qxF -- "--context|lab|set|K8S_NAMESPACE|wow" "$1" && grep -qxF -- "--context|lab|set|K8S_STORAGE_TYPE|hostpath" "$1" && grep -qxF -- "--context|lab|set|K8S_DB_HOSTPATH|/srv/db" "$1"' _ "$T/calls"
check "  then run-k8s with namespace and address" called "--context|lab|run-k8s|--namespace|wow|--address|10.0.0.7"
check "stop-k8s on the current context: no target flags" called "stop-k8s"

echo "# Accounts"
drive Accounts create-account "docker (run-docker)" bob 'hunter2!' Gamemaster back Quit
check "create-account: --pass-stdin, level 3, --where docker (Kamino 233)" called "create-account|--name|bob|--pass-stdin|--level|3|--where|docker"
check "  the password is on no argv" not_called "hunter2"
check "  it arrives on stdin" [ "$(cat "$T/stdin" 2>/dev/null)" = 'hunter2!' ]
check "  the prompt no longer says it goes on argv" bash -c '! grep -q "Passed to the engine as an argument" "$1"' _ "$T/out"
drive Accounts create-account "Auto-detect (mangosd runs in one place)" bob 'two words' back Quit
check "a password the console would refuse is never sent" not_called "create-account"
check "  and the reason is given" grep -q "no spaces; nothing was sent" "$T/out"
drive Accounts list-accounts "local (native start)" back Quit
check "list-accounts --where local" called "list-accounts|--where|local"
drive Accounts set-account-level "Auto-detect (mangosd runs in one place)" bob Moderator back Quit
check "set-account-level: level 1, auto-detect (no --where)" called "set-account-level|--name|bob|--level|1"
drive Accounts delete-account "Auto-detect (mangosd runs in one place)" bob no back Quit
check "delete-account lists the accounts first" called "list-accounts"
check "  declined: nothing deleted" not_called "delete-account"
drive Accounts delete-account "Auto-detect (mangosd runs in one place)" bob enter back Quit
check "  Enter (the default): nothing deleted" not_called "delete-account"
drive Accounts delete-account "Auto-detect (mangosd runs in one place)" bob yes back Quit
check "  confirmed: delete-account --name bob" called "delete-account|--name|bob"

echo "# Characters, Search, Status"
drive Characters rename-character Oldname Newname back Search NPCs Hogger Status Quit
check "rename-character --from --to" called "rename-character|--from|Oldname|--to|Newname"
check "search --kind npcs --term" called "search|--kind|npcs|--term|Hogger"
check "status" called "status"

echo "# Administration: apply-sql, restart, dump"
for a in no enter; do
    drive Administration apply-sql /tmp/change.sql characters "$a" back Quit
    check "apply-sql, $a: nothing applied" not_called "apply-sql"
done
drive Administration apply-sql /tmp/change.sql characters yes back Quit
check "apply-sql, yes: --file --db" called "apply-sql|--file|/tmp/change.sql|--db|characters"
for a in no enter; do
    drive Administration restart "Now (at the orchestrator)" "$a" restart "Graceful (warn players first)" 30 "$a" back Quit
    check "restart now and graceful, $a: no restart" not_called "restart"
done
drive Administration restart "Now (at the orchestrator)" yes restart "Graceful (warn players first)" 30 yes back Quit
check "restart now, yes" called "restart"
check "restart graceful, yes: --graceful 30" called "restart|--graceful|30"
drive Administration dump "accounts only (to move between servers)" dump "All four databases" back Quit
check "dump accounts only: realmd's account tables" called "dump|--db|realmd|--tables|account account_access account_banned realmcharacters"
check "dump all" called "dump|--all"

echo; if (( FAILS == 0 )); then echo "all passed"; else echo "${FAILS} failed"; exit 1; fi
