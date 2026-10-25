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

echo; if (( FAILS == 0 )); then echo "all passed"; else echo "${FAILS} failed"; exit 1; fi
