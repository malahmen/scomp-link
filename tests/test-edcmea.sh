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
#     timer where systemd runs the session; refused without rules or recipient.
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

mkdir -p "$T/engine" "$T/bin"
# The fake engine: one line per call ("ARGS | stdin"), and the answers the
# front-end reads.
cat > "$T/engine/edcmea.sh" <<EOF
#!/usr/bin/env bash
input=""
[[ "\$1" == pop-env && -n "\${2:-}" && "\$2" != --* ]] && input="\$(cat)"
printf '%s | %s\n' "\$*" "\$input" >> "$T/calls"
case "\$1" in
    config) printf 'rules=%s\nemail_to=%s\npop=/bin/pop\npop_env=POP_FROM\nconfig_file=/x/config.json\nrealert_increase_percent=5.0\n' \
                "\$(cat "$T/rules-count" 2>/dev/null || echo 0)" "\$(cat "$T/email-to" 2>/dev/null)" ;;
    commodities) printf 'lowtemperaturediamond\tbest sell 523,200 cr\nlowtemp.diamonds\tbest sell 1 cr\n' ;;
    rules) [[ "\$2" == list ]] && printf 'ltd\tlowtemperaturediamond >= 600,000 cr\nvoid\tvoidopal >= 1 cr\n' ;;
esac
exit 0
EOF
cp "${TEST_DIR}/stubs/gum" "$T/bin/gum"
# crontab keeps its table in a file; systemctl and uname record and answer.
cat > "$T/bin/crontab" <<EOF
#!/usr/bin/env bash
case "\$1" in
    -l) [[ -f "$T/crontab" ]] && cat "$T/crontab" || { echo "no crontab for user" >&2; exit 1; } ;;
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
chmod +x "$T/engine/edcmea.sh" "$T/bin/"*

run() {
    printf '%s\n' "$@" > "$T/answers"; echo 0 > "$T/state"; : > "$T/calls"
    PATH="$T/bin:$PATH" GUM_ANSWERS="$T/answers" GUM_STATE="$T/state" EDCMEA_DIR="$T/engine" \
        XDG_STATE_HOME="$T/xstate" SCOMP_EDCMEA_UNIT_DIR="$T/units" "$BASH" "$FRONT" > "$T/out" 2>&1 < /dev/null
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
check "a crontab line runs check every 10 minutes" grep -qE "^\*/10 \* \* \* \* $T/engine/edcmea.sh check >> .* # edcmea \(scomp-link\)$" "$T/crontab"
check "...the user's own line kept" has "/usr/bin/backup  # mine" "$T/crontab"
run schedule "run it every few minutes" 30 Quit
check "rescheduling replaces the line, never adds a second" test "$(grep -c 'edcmea (scomp-link)' "$T/crontab")" -eq 1
check "...at the new interval" has "*/30 * * * *" "$T/crontab"
run status Quit
check "status shows the schedule" has "crontab: */30 * * * *" "$T/out"
run schedule "stop running it" Quit
check "stopping removes the line" lacks "edcmea (scomp-link)" "$T/crontab"
check "...and only that line" has "/usr/bin/backup  # mine" "$T/crontab"

echo "# the schedule: a systemd user timer"
STUB_UNAME=Linux run schedule "run it every few minutes" 15 Quit
check "a timer every 15 minutes" has "OnCalendar=*:0/15" "$T/units/edcmea-check.timer"
check "...running check on the engine" has "ExecStart=$T/engine/edcmea.sh check" "$T/units/edcmea-check.service"
check "...enabled and started" has "systemctl --user enable --now edcmea-check.timer" "$T/calls"
STUB_UNAME=Linux run schedule "stop running it" Quit
check "stopping disables it and removes the units" test ! -e "$T/units/edcmea-check.timer"
check "...through systemctl" has "systemctl --user disable --now edcmea-check.timer" "$T/calls"

echo; if (( FAILS == 0 )); then echo "all passed"; else echo "${FAILS} failed"; exit 1; fi
