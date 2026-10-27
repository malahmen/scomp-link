#!/usr/bin/env bash
# The EDCMEA front-end, driven through the gum stub against a fake engine
# (EDCMEA_DIR) that records its arguments and stdin, with recording crontab,
# systemctl and uname stubs. No network, no mail, no real schedule.
#
# What it protects:
#   - a rule is built from the menus into the engine's flags;
#   - a secret (SMTP password, Resend key) reaches the engine on stdin, never
#     as an argument;
#   - the schedule: a crontab line carrying a marker, replaced not duplicated,
#     removed without touching the user's other lines; or a systemd user
#     timer where systemd runs the session; refused without rules or recipient;
#   - a scheduled run finds everything with cron's PATH and none of this
#     shell's variables: python3, the engine, pop and both folders are written
#     in as absolute paths, quoted, a space or a % in them included (Kamino
#     167, 179) - the crontab line is run here the way cron runs it;
#   - a failing `crontab -l` is not an empty crontab (Kamino 197).
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FRONT="${TEST_DIR}/../scripts/edcmea/edcmea.sh"
[[ -f "$FRONT" ]] || { echo "front-end not found at $FRONT" >&2; exit 1; }
if [[ "${BASH_VERSINFO[0]:-0}" -lt 4 ]]; then
    for b in /opt/homebrew/bin/bash /usr/local/bin/bash; do [[ -x "$b" ]] && exec "$b" "$0" "$@"; done
    echo "SKIP - bash 4+ not found (the front-end needs it)"; exit 77
fi

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
FAILS=0
check() { local d="$1"; shift; if "$@"; then echo "   ok   - $d"; else echo "   FAIL - $d"; FAILS=$((FAILS + 1)); fi; }
has()   { grep -qF -- "$1" "$2"; }
lacks() { ! grep -qF -- "$1" "$2"; }

# The engine, python3 and the folders live where a space, a %, a ' and a $
# are: each breaks an unquoted crontab line or ExecStart=.
ENG="$T/my engine 100%"
CFG="$T/cmdr's cfg dir"
STATE="$T/state dir 100%"
PYDIR="$T/py \$bin"
mkdir -p "$ENG" "$T/bin" "$PYDIR" "$STATE" "$T/home"
# The fake engine: one line per call ("ARGS | stdin"), and the answers the
# front-end reads.
cat > "$ENG/edcmea.sh" <<EOF
#!/usr/bin/env bash
input=""
[[ "\$1" == pop-env && -n "\${2:-}" && "\$2" != --* ]] && input="\$(cat)"
printf '%s | %s\n' "\$*" "\$input" >> "$T/calls"
case "\$1" in
    config) pop="$T/bin/pop"; [[ -z "\${STUB_POP_MISSING:-}" ]] || pop=missing
            printf 'rules=%s\nemail_to=%s\npop=%s\npop_env=POP_FROM\nconfig_file=%s\nstate_file=%s\nrealert_increase_percent=5.0\n' \
                "\$(cat "$T/rules-count" 2>/dev/null || echo 0)" "\$(cat "$T/email-to" 2>/dev/null)" "\$pop" \
                "$CFG/config.json" "$STATE/state.json" ;;
    check) [[ "\${2:-}" == --help && -z "\${STUB_NO_QUIET:-}" ]] && echo "usage: edcmea check [-h] [--dry-run] [--rule RULE] [--quiet]" ;;
    commodities) printf 'lowtemperaturediamond\tbest sell 523,200 cr\nlowtemp.diamonds\tbest sell 1 cr\n' ;;
    rules) [[ "\$2" == list ]] && printf 'ltd\tlowtemperaturediamond >= 600,000 cr\nvoid\tvoidopal >= 1 cr\n' ;;
esac
exit 0
EOF
touch "$ENG/edcmea.py"
# python3 as a scheduled run meets it: what it was given, and the EDCMEA_*
# variables it got, recorded.
cat > "$PYDIR/python3" <<EOF
#!/bin/sh
printf '%s\n' "\$@" > "$T/py-argv"
env | grep '^EDCMEA_' | sort > "$T/py-env"
echo "[alert] from the scheduled run"
EOF
printf '#!/bin/sh\nexit 0\n' > "$T/bin/pop"
cp "${TEST_DIR}/stubs/gum" "$T/bin/gum"
# crontab keeps its table in a file; systemctl and uname record and answer.
# STUB_CRONTAB_FAIL: -l fails the way an unreadable spool does.
cat > "$T/bin/crontab" <<EOF
#!/usr/bin/env bash
case "\$1" in
    -l) if [[ -n "\${STUB_CRONTAB_FAIL:-}" ]]; then echo "crontab: cannot open your crontab: Permission denied" >&2; exit 1; fi
        [[ -f "$T/crontab" ]] && cat "$T/crontab" || { echo "no crontab for user" >&2; exit 1; } ;;
    -)  cat > "$T/crontab" ;;
esac
EOF
cat > "$T/bin/systemctl" <<EOF
#!/usr/bin/env bash
echo "systemctl \$*" >> "$T/calls"
[[ "\$*" == "--user is-active edcmea-check.timer" ]] && echo active
exit 0
EOF
printf '#!/usr/bin/env bash\necho "${STUB_UNAME:-Darwin}"\n' > "$T/bin/uname"
chmod +x "$ENG/edcmea.sh" "$T/bin/"* "$PYDIR/python3"

run() {
    printf '%s\n' "$@" > "$T/answers"; echo 0 > "$T/state"; : > "$T/calls"
    PATH="$T/bin:$PYDIR:$PATH" GUM_ANSWERS="$T/answers" GUM_STATE="$T/state" EDCMEA_DIR="$ENG" \
        EDCMEA_PYTHON="${STUB_PYTHON-$PYDIR/python3}" \
        XDG_STATE_HOME="$T/xstate" SCOMP_EDCMEA_UNIT_DIR="$T/units" "$BASH" "$FRONT" > "$T/out" 2>&1 < /dev/null
}

# The marked crontab line's command as cron runs it: % up to the first
# unescaped one (\% is a %), handed to /bin/sh with cron's bare environment.
cron_run() {
    local line cmd="" rest i c
    line="$(grep -F 'edcmea (scomp-link)' "$T/crontab")" || return 1
    rest="$(cut -d' ' -f6- <<< "$line")"
    for (( i = 0; i < ${#rest}; i++ )); do
        c="${rest:i:1}"
        if [[ "$c" == '\' && "${rest:i+1:1}" == % ]]; then cmd+=%; (( i++ )) || true
        elif [[ "$c" == % ]]; then break
        else cmd+="$c"; fi
    done
    rm -f "$T/py-argv" "$T/py-env"
    env -i PATH=/usr/bin:/bin HOME="$T/home" /bin/sh -c "$cmd"
}

echo "# the menu"
run Quit
for item in "check now" "dry run - what would be sent" "list rules" "add a rule" "remove a rule" \
            "email" "settings" "schedule" "status"; do
    check "'${item}' is offered" has "<option> ${item}" "$T/out"
done

echo "# a rule, from the menus"
run "add a rule" diamond lowtemperaturediamond 600000 ltd L "" "" Sol 200 "" no Quit
check "the commodity search goes to the engine" has "commodities diamond |" "$T/calls"
check "the rule reaches the engine as flags" has "rules add ltd lowtemperaturediamond 600000 --pad L --near Sol --max-ly 200 |" "$T/calls"
check "...without fleet carriers unless asked" lacks "--carriers" "$T/calls"
run "add a rule" diamond lowtemperaturediamond "a lot" Quit
check "a price that is not a number adds nothing" lacks "rules add" "$T/calls"
run "remove a rule" void yes Quit
check "a rule is removed by its name" has "rules remove void |" "$T/calls"

echo "# email: secrets on stdin"
run email "SMTP server (host, port, user, password, encryption)" smtp.example.com 587 me@example.com "hunter2-app-pw" starttls Quit
check "the SMTP password reaches the engine" has "pop-env POP_SMTP_PASSWORD | hunter2-app-pw" "$T/calls"
check "...on stdin, not as an argument" bash -c '! grep -q "^[^|]*hunter2" "$1"' _ "$T/calls"
check "the host goes the same way" has "pop-env POP_SMTP_HOST | smtp.example.com" "$T/calls"
run email "Resend API key" "re_secret_key" Quit
check "a Resend key too" has "pop-env RESEND_API_KEY | re_secret_key" "$T/calls"
run email "copy pop's settings from this shell (POP_*, RESEND_API_KEY)" Quit
check "pop's settings can be copied from the shell" has "pop-env --import |" "$T/calls"
run email "recipient - who gets the alerts" "cmdr@example.com" Quit
check "the recipient is a setting" has "set email_to cmdr@example.com |" "$T/calls"
run email "send a test email" Quit
check "a test email can be sent" has "notify-test |" "$T/calls"
run settings cooldown_hours 6 Quit
check "settings are changed through the engine" has "set cooldown_hours 6 |" "$T/calls"

echo "# the schedule: crontab"
printf '0 3 * * * /usr/bin/backup  # mine\n' > "$T/crontab"
run schedule "run it every few minutes" Quit
check "no rules yet: not scheduled" lacks "edcmea (scomp-link)" "$T/crontab"
check "...and says why" has "No watch rules yet" "$T/out"
echo 2 > "$T/rules-count"; echo cmdr@example.com > "$T/email-to"
run schedule "run it every few minutes" 10 Quit
check "a crontab line runs check every 10 minutes" grep -qE "^\*/10 \* \* \* \* .* check --quiet >> .* # edcmea \(scomp-link\)$" "$T/crontab"
check "...the user's own line kept" has "/usr/bin/backup  # mine" "$T/crontab"
cron_run
check "...cron runs it: python3 by its full path, on the engine's edcmea.py" \
    test "$(cat "$T/py-argv" 2>/dev/null)" == "$ENG/edcmea.py"$'\n'check$'\n'--quiet
check "...with pop and both folders, a space and a % in them intact" \
    test "$(cat "$T/py-env" 2>/dev/null)" == "EDCMEA_CONFIG_DIR=$CFG"$'\n'"EDCMEA_POP=$T/bin/pop"$'\n'"EDCMEA_STATE_DIR=$STATE"
check "...logging to the engine's state folder" has "[alert] from the scheduled run" "$STATE/check.log"
run schedule "stop running it" Quit
STUB_PYTHON=python3 run schedule "run it every few minutes" 10 Quit
check "python3 found on this PATH is written in by its full path" has "'$PYDIR/python3'" "$T/crontab"
STUB_NO_QUIET=1 run schedule "run it every few minutes" 10 Quit
check "an engine without --quiet is not given it" grep -qE " check >> .*# edcmea \(scomp-link\)$" "$T/crontab"
run schedule "run it every few minutes" 30 Quit
check "rescheduling replaces the line, never adds a second" test "$(grep -c 'edcmea (scomp-link)' "$T/crontab")" -eq 1
check "...at the new interval" has "*/30 * * * *" "$T/crontab"
run status Quit
check "status shows the schedule" has "crontab: */30 * * * *" "$T/out"
check "...not the paths and variables after it" lacks "EDCMEA_POP" "$T/out"
run schedule "stop running it" Quit
check "stopping removes the line" lacks "edcmea (scomp-link)" "$T/crontab"
check "...and only that line" has "/usr/bin/backup  # mine" "$T/crontab"

echo "# the schedule: what it refuses"
cp "$T/crontab" "$T/crontab.before"
STUB_POP_MISSING=1 run schedule "run it every few minutes" 10 Quit
check "without pop: not scheduled" lacks "edcmea (scomp-link)" "$T/crontab"
check "...and says why" has "pop is not installed here" "$T/out"
run schedule "run it every few minutes" 10 Quit
cp "$T/crontab" "$T/crontab.before"
STUB_CRONTAB_FAIL=1 run schedule "run it every few minutes" 30 Quit
check "crontab -l failing: the crontab is not rewritten" cmp -s "$T/crontab" "$T/crontab.before"
check "...and it says so" has "crontab -l failed" "$T/out"
STUB_CRONTAB_FAIL=1 run schedule "stop running it" Quit
check "...nor emptied by stopping" cmp -s "$T/crontab" "$T/crontab.before"
STUB_CRONTAB_FAIL=1 run status Quit
check "...and status does not call it unscheduled" has "unknown (crontab -l failed)" "$T/out"
run schedule "stop running it" Quit
rm -f "$T/crontab"
run schedule "run it every few minutes" 10 Quit
check "no crontab yet: one is started" has "edcmea (scomp-link)" "$T/crontab"
run schedule "stop running it" Quit

echo "# the schedule: a systemd user timer"
STUB_UNAME=Linux run schedule "run it every few minutes" 15 Quit
check "a timer every 15 minutes" has "OnCalendar=*:0/15" "$T/units/edcmea-check.timer"
check "...running check: python3 and edcmea.py by full path, quoted, % doubled" \
    has "ExecStart=\"${PYDIR//\$/\$\$}/python3\" \"${ENG//%/%%}/edcmea.py\" check" "$T/units/edcmea-check.service"
check "...with pop" has "Environment=\"EDCMEA_POP=$T/bin/pop\"" "$T/units/edcmea-check.service"
check "...and both folders" has "Environment=\"EDCMEA_STATE_DIR=${STATE//%/%%}\"" "$T/units/edcmea-check.service"
check "...the config one too" has "Environment=\"EDCMEA_CONFIG_DIR=$CFG\"" "$T/units/edcmea-check.service"
check "...a run cannot take all day" has "TimeoutStartSec=" "$T/units/edcmea-check.service"
check "...and a stop lets it record the email it is sending" has "KillMode=mixed" "$T/units/edcmea-check.service"
check "...enabled and started" has "systemctl --user enable --now edcmea-check.timer" "$T/calls"
STUB_UNAME=Linux run schedule "stop running it" Quit
check "stopping disables it and removes the units" test ! -e "$T/units/edcmea-check.timer"
check "...through systemctl" has "systemctl --user disable --now edcmea-check.timer" "$T/calls"

echo; if (( FAILS == 0 )); then echo "all passed"; else echo "${FAILS} failed"; exit 1; fi
