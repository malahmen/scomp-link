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
# What it protects (Kamino item 178): the question is asked only after the
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
case "\${1:-}" in get|profiles) exit 0 ;; esac
(IFS='|'; printf '%s\n' "\$*") >> "$T/calls"
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
    rm -f "$T/calls" "$T/state"; : > "$T/calls"
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

echo; if (( FAILS == 0 )); then echo "all passed"; else echo "${FAILS} failed"; exit 1; fi
