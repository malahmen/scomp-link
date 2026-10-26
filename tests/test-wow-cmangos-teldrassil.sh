#!/usr/bin/env bash
# The wow-cmangos-teldrassil front-end, driven through the gum stub against a
# fake engine (TELDRASSIL_DIR) that records every call it is given, one per
# line, and what it read on stdin.
#
# What it protects: a password reaches the engine on stdin and never as an
# argument; every destructive action does nothing unless confirmed, and
# replacing the whole bot population needs a second, separate yes; the search
# filters arrive as the engine's flags; a table-subset dump is restored with
# --db.
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FRONT="${TEST_DIR}/../scripts/wow-cmangos-teldrassil/wow-cmangos-teldrassil.sh"
[[ -f "$FRONT" ]] || { echo "front-end not found at $FRONT" >&2; exit 1; }
if [[ "${BASH_VERSINFO[0]:-0}" -lt 4 ]]; then
    for b in /opt/homebrew/bin/bash /usr/local/bin/bash; do [[ -x "$b" ]] && exec "$b" "$0" "$@"; done
    echo "SKIP - bash 4+ not found (the front-end needs it)"; exit 77
fi

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
FAILS=0
check() { local d="$1"; shift; if "$@"; then echo "   ok   - $d"; else echo "   FAIL - $d"; FAILS=$((FAILS + 1)); fi; }

mkdir -p "$T/engine" "$T/bin" "$T/config/teldrassil/dumps"
cat > "$T/engine/teldrassil.sh" <<EOF
#!/usr/bin/env bash
# Records the call; answers 'get' with the defaults the front-end reads.
if [[ "\${1:-}" == get ]]; then
    case "\$2" in
        DB_WORLD) echo classicmangos ;; DB_CHARACTERS) echo classiccharacters ;;
        DB_REALMD) echo classicrealmd ;; DB_LOGS) echo classiclogs ;; *) echo "" ;;
    esac
    exit 0
fi
(IFS='|'; printf '%s\n' "\$*") >> "$T/calls"
[[ "\${1:-}" == create-account ]] && cat > "$T/stdin"
exit 0
EOF
cp "${TEST_DIR}/stubs/gum" "$T/bin/gum"; chmod +x "$T/bin/gum"
printf -- '-- a table-subset dump\nCREATE TABLE guild (a INT);\n' > "$T/config/teldrassil/dumps/classiccharacters-tables-20261025-000000.sql"

# drive <answer>... — one answer per prompt, in order; the session ends at Quit.
drive() {
    printf '%s\n' "$@" > "$T/answers"
    rm -f "$T/calls" "$T/stdin" "$T/state"; : > "$T/calls"
    PATH="$T/bin:$PATH" GUM_ANSWERS="$T/answers" GUM_STATE="$T/state" TELDRASSIL_DIR="$T/engine" \
        XDG_CONFIG_HOME="$T/config" "$BASH" "$FRONT" > "$T/out" 2>&1
}
called()     { grep -qxF -- "$1" "$T/calls"; }
not_called() { ! grep -q -- "$1" "$T/calls"; }

echo "# accounts: the password goes on stdin"
drive Accounts create-account Bob 's3cret!' "3 - Administrator" back Quit
check "create-account is called with --pass-stdin" called "create-account|--name|Bob|--pass-stdin|--level|3"
check "the password is in no argument" not_called 's3cret'
check "the password arrives on stdin" [ "$(cat "$T/stdin" 2>/dev/null)" = 's3cret!' ]

echo "# roster apply: nothing without a yes; the population only with two"
drive Roster apply no back Quit
check "declined: the plan is shown" called "roster|plan"
check "declined: no apply" not_called "apply"
drive Roster apply yes no back Quit
check "yes, keep the population: apply --yes" called "roster|apply|--yes"
drive Roster apply yes yes no back Quit
check "the second yes missing: the population is kept" called "roster|apply|--yes"
check "  and --fresh-population is not passed" not_called "fresh-population"
drive Roster apply yes yes yes back Quit
check "both yeses: apply --fresh-population --yes" called "roster|apply|--fresh-population|--yes"

echo "# search: filters become flags; a term is required where the engine needs one"
drive Search Bots "" 'zone\nonline only' Durotar Quit
check "bots in a zone, online" called "search|--kind|bots|--zone|Durotar|--online"
drive Search Bots Bol 'level\nroster bots only' 5-10 Quit
check "a name term, a level range, roster only" called "search|--kind|bots|--term|Bol|--level|5-10|--roster-only"
drive Search Items "" Quit
check "items with no term: the engine is not asked" not_called "search"
drive Search "Objects (herbs, ore, chests)" Peacebloom Quit
check "objects by name" called "search|--kind|objects|--term|Peacebloom"

echo "# server: stopping needs a yes"
drive Server stop no back Quit
check "declined: no stop" not_called "stop"
drive Server stop yes back Quit
check "confirmed: stop" called "stop"
drive Server restart "Graceful (warn players first)" 30 yes back Quit
check "graceful restart in 30s" called "restart|--graceful|30"

echo "# administration"
drive Administration restore "classiccharacters-tables-20261025-000000.sql" classiccharacters yes back Quit
check "a table-subset dump is restored with --db" called "restore|--file|$T/config/teldrassil/dumps/classiccharacters-tables-20261025-000000.sql|--db|classiccharacters|--yes"
drive Administration restore "classiccharacters-tables-20261025-000000.sql" classiccharacters no back Quit
check "declined: no restore" not_called "restore"
drive Administration dump "Accounts only (to move them between servers)" back Quit
check "accounts-only dump: the account tables of the realm database" called "dump|--db|classicrealmd|--tables|account account_banned realmcharacters"

echo "# bots"
drive Bots commands "The ones anyone can use" "" back Quit
check "the commands anyone can use" called "commands|--any"
drive Bots attunements no back Quit
check "attunements: the plan, then nothing without a yes" bash -c 'grep -qxF "attune|plan" "$1" && ! grep -q "attune|apply" "$1"' _ "$T/calls"
drive Bots attunements yes back Quit
check "attunements confirmed: apply --yes" called "attune|apply|--yes"

echo "# provision"
drive Provision install /wow/client "My Realm" 192.168.1.5 40 "" no back Quit
check "the wizard saves its answers" bash -c 'grep -qxF "set|CLIENT_DIR|/wow/client" "$1" && grep -qxF "set|REALM_NAME|My Realm" "$1" && grep -qxF "set|REALM_ADDRESS|192.168.1.5" "$1" && grep -qxF "set|BOTS|40" "$1"' _ "$T/calls"
check "  a blank answer keeps the setting" not_called "set|WORK_DIR"
check "  and declining installs nothing" not_called "install"
drive Provision install "" "" "" "" "" yes back Quit
check "confirmed: install --yes" called "install|--yes"
drive Provision db-init no back Quit
check "db-init declined: nothing" not_called "db-init"
drive Provision db-init yes back Quit
check "db-init confirmed: --yes" called "db-init|--yes"
drive Provision build 16 no back Quit
check "build with jobs, not clean" called "build|--jobs|16"
drive Provision remove yes yes no back Quit
check "remove, second database yes missing: the database is kept" called "remove|--yes"
drive Provision remove yes yes yes back Quit
check "remove with both database yeses: --database" called "remove|--yes|--database"
drive Provision remove no back Quit
check "remove declined: nothing" not_called "remove"

echo "# llm: optional"
drive Bots llm "Leave it" back Quit
check "status is shown, nothing changes" bash -c 'grep -qxF "llm|status" "$1" && ! grep -q "llm|o" "$1"' _ "$T/calls"
drive Bots llm "Turn it off" back Quit
check "off" called "llm|off"
drive Bots llm "Turn it on (or change it)" http://127.0.0.1:1234/v1/chat/completions qwen 80 none 0 "" back Quit
check "on, with the endpoint, model and extras" called "llm|on|--endpoint|http://127.0.0.1:1234/v1/chat/completions|--model|qwen|--max-tokens|80|--reasoning-effort|none|--bot-to-bot|0"
drive Bots llm "Turn it on (or change it)" https://api.example/v1/chat/completions gpt "" "" "" /keys/llm.txt back Quit
check "a hosted endpoint: the key FILE is passed, blanks left out" called "llm|on|--endpoint|https://api.example/v1/chat/completions|--model|gpt|--api-key-file|/keys/llm.txt"
drive Bots llm "Turn it on (or change it)" http://x/v1/chat/completions "" back Quit
check "no model: cancelled" not_called "llm|on"

echo "# profiles: every call carries the chosen one"
drive Settings profile "new profile..." far "Another machine, in Kubernetes (over ssh)" meksha "" "" MARIADB_ROOT_PASSWORD "" kalimdor kalimdor-world kalimdor-bots 8086 "" "" "" "" no back Server status back Quit
check "the remote answers go to the new profile" bash -c 'grep -qxF -- "--profile|far|set|SSH_HOST|meksha" "$1" && grep -qxF -- "--profile|far|set|SERVER_KIND|kube" "$1" && grep -qxF -- "--profile|far|set|BOT_SECRET|kalimdor-bots" "$1"' _ "$T/calls"
check "  the console account is offered, and declining makes none" not_called "console-account"
check "  and a later command acts on it" called "--profile|far|status"
drive Settings profile "base config (no profile)" back Server status back Quit
check "base config: no --profile" called "status"
printf '%s\n' Accounts create-account Bob 's3cret!' "3 - Administrator" back Quit > "$T/answers"; : > "$T/calls"
PATH="$T/bin:$PATH" GUM_ANSWERS="$T/answers" GUM_STATE="$T/state.p" TELDRASSIL_DIR="$T/engine" TELDRASSIL_PROFILE=far \
    XDG_CONFIG_HOME="$T/config" "$BASH" "$FRONT" > "$T/out" 2>&1
check "\$TELDRASSIL_PROFILE starts the session, the password still on stdin" called "--profile|far|create-account|--name|Bob|--pass-stdin|--level|3"
drive Settings console-account yes back Quit
check "console account, confirmed" called "console-account"

echo; if (( FAILS == 0 )); then echo "all passed"; else echo "${FAILS} failed"; exit 1; fi
