#!/usr/bin/env bash
# The thermal-exhaust-port front-end, driven through the gum stub.
#
# What it is really protecting: the front-end must never invent the fan curve,
# the sensor list or the unit path. All three come from the engine (`config`,
# `sensors`), and a picker that disagrees with what the service actually reads
# is the whole failure mode the engine split exists to prevent. So the checks
# look at the flags the engine was invoked with, not at what the screen said.
#
# No hardware and no privilege: a fake sysfs tree, a recording ectool, a stub
# systemctl, and TEP_SUDO="" so the engine's install path writes into a temp dir.
# shellcheck disable=SC2016
# The single quotes around every `bash -c` body are the point: the child must
# expand $OUT itself, from the environment, which is why it is exported.
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FRONT="${TEST_DIR}/../scripts/thermal-exhaust-port/thermal-exhaust-port.sh"
[[ -f "$FRONT" ]] || { echo "front-end not found at $FRONT" >&2; exit 1; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
T="$(cd "$T" && pwd)"
export PATH="${TEST_DIR}/stubs:$T/stub:$PATH"
export GUM_ANSWERS="$T/answers" GUM_STATE="$T/state"

# The real engine, resolved the way a user's sibling checkout would be. Without
# one there is nothing to drive, so this skips rather than pretends.
REAL_ENGINE="${TEP:-${TEST_DIR}/../../thermal-exhaust-port/thermal-exhaust-port.sh}"
if [[ ! -f "$REAL_ENGINE" ]]; then
    echo "SKIP - no thermal-exhaust-port engine at ${REAL_ENGINE} (set \$TEP)" >&2
    exit 77
fi
REAL_ENGINE="$(cd "$(dirname "$REAL_ENGINE")" && pwd)/thermal-exhaust-port.sh"

FAILS=0
check() { local d="$1"; shift; if "$@"; then echo "   ok   - $d"; else echo "   FAIL - $d"; FAILS=$((FAILS + 1)); fi; }
has()   { case "$2" in *"$1"*) return 0 ;; *) return 1 ;; esac; }

# ---- fixtures: a fake hwmon tree and recording stubs ------------------------
mkdir -p "$T/stub" "$T/hwmon/hwmon0" "$T/hwmon/hwmon1" "$T/hwmon/hwmon2"
printf 'k10temp\n' > "$T/hwmon/hwmon0/name"; printf '71000\n' > "$T/hwmon/hwmon0/temp1_input"
printf 'amdgpu\n'  > "$T/hwmon/hwmon1/name"; printf '62000\n' > "$T/hwmon/hwmon1/temp1_input"
# A chip with a name but no temperature: it must never be offered as a sensor
# to watch, because a curve cannot be driven from it.
printf 'nothermal\n' > "$T/hwmon/hwmon2/name"

export ECCALLS="$T/eccalls"; : > "$ECCALLS"
cat > "$T/stub/ectool" <<'STUB'
#!/usr/bin/env bash
printf 'ectool %s\n' "$*" >> "$ECCALLS"
[[ "${1:-}" == pwmgetfanrpm ]] && echo "Fan 0 RPM: 1234"
exit 0
STUB
export STATES="$T/states"; mkdir -p "$STATES"
cat > "$T/stub/systemctl" <<'STUB'
#!/usr/bin/env bash
unit=""
for a in "$@"; do case "$a" in --*) ;; *.service) unit="$a"; break ;; esac; done
case "${1:-}" in
    is-active)  [[ "${2:-}" == --quiet ]] && exit 1; echo inactive; exit 3 ;;
    is-enabled)
        if [[ -n "$unit" && -f "$STATES/$unit.enabled" ]]; then
            [[ "${2:-}" == --quiet ]] && exit 0; echo enabled; exit 0
        fi
        [[ "${2:-}" == --quiet ]] && exit 1; echo disabled; exit 1 ;;
esac
exit 0
STUB
chmod +x "$T/stub/ectool" "$T/stub/systemctl"

UNIT="$T/tep.service"; BIN="$T/bin/tep.sh"; mkdir -p "$T/bin" "$T/units"

if command -v timeout &>/dev/null; then LIMIT_CMD=timeout
elif command -v gtimeout &>/dev/null; then LIMIT_CMD=gtimeout
else LIMIT_CMD=""; echo "note - no timeout: menu runs are not time-limited" >&2; fi
limited() { if [[ -n "$LIMIT_CMD" ]]; then "$LIMIT_CMD" 90 "$@"; else "$@"; fi; }

ran() {
    if [[ "$1" == 127 || "$1" == 126 || -z "$OUT" ]]; then
        echo "   FAIL - the front-end did not run (exit $1): ${OUT:0:200}" >&2
        exit 1
    fi
}

# The engine the front-end resolves is a wrapper that RECORDS its argv and
# forwards to the real one, with every path pointed at the temp dir. That is how
# "the front-end passed the curve the user picked" is asserted rather than
# inferred from the screen.
mkdir -p "$T/fake"
cat > "$T/fake/thermal-exhaust-port.sh" <<WRAP
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$T/calls"
cmd="\${1:-}"; shift 2>/dev/null || true
exec env TEP_SUDO="" TEP_SYSTEMCTL="$T/stub/systemctl" bash "$REAL_ENGINE" "\$cmd" \\
    --unit "$UNIT" --bin "$BIN" --hwmon "$T/hwmon" --ectool "$T/stub/ectool" \\
    --unit-dirs "$T/units" "\$@"
WRAP
chmod +x "$T/fake/thermal-exhaust-port.sh"

export OUT=""
CALLS=""
# tui <answer>... — run the front-end with those scripted gum answers.
tui() {
    : > "$T/calls"
    printf '%s\n' "$@" > "$GUM_ANSWERS"; echo 0 > "$GUM_STATE"
    OUT="$(THERMAL_EXHAUST_PORT_DIR="$T/fake" limited bash "$FRONT" </dev/null 2>&1)"; ran $?
    CALLS="$(cat "$T/calls")"
}
calls_with() { grep -q -- "$1" <<<"$CALLS"; }
no_call()    { ! grep -q -- "$1" <<<"$CALLS"; }

echo "## 1. the front-end asks the engine for its state"

tui quit
check "config is the first thing it asks for"  calls_with "config"
check "the unit path shown is the engine's"    has "$UNIT" "$OUT"
check "it says nothing is installed yet"       has "No service installed" "$OUT"
# The engine's default curve must reach the screen from `config`, never be
# duplicated as a literal in the front-end.
check "the engine's default curve is shown"    has "Default curve: 72:35 78:60 84:85 88:100" "$OUT"

echo "## 2. the menu"

tui quit
for item in "status" "try a curve" "install the service" "change the curve" \
            "choose sensors" "fan rpm" "list sensors" "remove the service"; do
    check "'${item}' is offered" has "<option> ${item}" "$OUT"
done

# With nothing installed, the engine still reports its default curve — so the
# picker must not present it as something that is already in place.
tui "try a curve" esc no
check "no 'keep the installed curve' before an install" \
    bash -c '! grep -q "keep the installed curve" <<<"$OUT"'
check "  but the presets are offered"          has "<option> balanced" "$OUT"
check "  and so is free text"                  has "<option> enter my own points" "$OUT"

echo "## 3. try a curve runs simulate, and changes nothing"

tui "try a curve" "balanced — quiet at idle, ramps before the 80s" "68 80 90" no
check "simulate is called"                     calls_with "simulate --curve"
check "with the preset's points"               calls_with "72:35 78:60 84:85 88:100"
check "the walk is shown"                      has "100%" "$OUT"
check "nothing was installed"                  bash -c '[[ ! -e "'"$UNIT"'" ]]'
check "install was never called"               no_call "install"

echo "## 4. install: preview, confirm, then the engine does it"

tui "install the service" "aggressive — airflow early, never reaches the 80s" yes no
# The preview has to come BEFORE the question, or it is not a preview. Checked
# by line order in the transcript, not by the mere presence of both.
check "simulate runs before the install question" calls_with "simulate --curve"
check "  and its output precedes the confirmation" bash -c '
    p=$(grep -n "100%" <<<"$OUT" | head -1 | cut -d: -f1)
    q=$(grep -n "<confirm> Install and enable" <<<"$OUT" | head -1 | cut -d: -f1)
    [[ -n "$p" && -n "$q" && "$p" -lt "$q" ]]'
check "the confirmation mentions sudo"         has "sudo will ask" "$OUT"
check "install carries the chosen curve"       calls_with "install --curve 60:35 70:50 75:75 80:100"
check "the unit was written"                   bash -c '[[ -f "'"$UNIT"'" ]]'
check "  with that curve in it"                grep -qF 'TEP_CURVE=60:35 70:50 75:75 80:100' "$UNIT"
check "  and ExecStart pointing at --bin"      grep -qF "ExecStart=${BIN} run" "$UNIT"

echo "## 5. declining the confirmation installs nothing"

rm -f "$UNIT"
tui "install the service" "quiet — let the EC handle anything below 78C" no no
check "a declined install writes no unit"      bash -c '[[ ! -e "'"$UNIT"'" ]]'
check "  and never calls install"              no_call "install --curve"
# Esc is not "no": gum confirm exits 130, and a plain `&& ...` would read that
# as a decline and carry on. Here both end in nothing installed, but the
# distinction is what _ask exists for.
tui "install the service" "quiet — let the EC handle anything below 78C" esc no
check "Esc at the confirmation also installs nothing" bash -c '[[ ! -e "'"$UNIT"'" ]]'

echo "## 6. an installed unit is reported, and reused"

tui "install the service" "balanced — quiet at idle, ramps before the 80s" yes no
check "the unit exists again"                  bash -c '[[ -f "'"$UNIT"'" ]]'
tui quit
check "the installed curve is read back"       has "72:35 78:60 84:85 88:100" "$OUT"
tui "change the curve" esc no
check "  and offered as 'keep the installed'"  has "<option> keep the installed curve (72:35 78:60 84:85 88:100)" "$OUT"

echo "## 7. change the curve uses set-curve, not a reinstall"

tui "change the curve" "flat out above 70C — loud, simple, cool" yes no
check "set-curve is called"                    calls_with "set-curve 70:100"
check "  not install"                          no_call "install --curve"
check "the unit's curve changed"               grep -qF 'TEP_CURVE=70:100' "$UNIT"

# "keep the current curve" must be a no-op, not a pointless restart of the
# service.
tui "change the curve" "keep the installed curve (70:100)" no
check "keeping the current curve does nothing" no_call "set-curve"
check "  and says so"                          has "already the installed curve" "$OUT"

echo "## 8. a rejected curve leaves the installed one alone"

before="$(cat "$UNIT")"
tui "change the curve" "enter my own points" "80:50 70:40" no
check "a descending curve is refused"          has "rejected" "$OUT"
check "  set-curve is never reached"           no_call "set-curve"
check "  and the unit is untouched"            [ "$(cat "$UNIT")" = "$before" ]

echo "## 9. sensors come from the engine, not from a guess"

tui "list sensors" no
check "sensors is asked of the engine"         calls_with "sensors"
check "k10temp is listed"                      has "k10temp" "$OUT"
check "amdgpu is listed"                       has "amdgpu" "$OUT"
check "the watched ones are marked"            has "yes" "$OUT"

# The picker must offer this host's chips, and must not offer one that reports
# no temperature at all.
tui "choose sensors" "k10temp (71C)" yes no
check "a real chip is offered"                 has "<option> k10temp (71C)" "$OUT"
check "  with its current temperature"         has "<option> amdgpu (62C)" "$OUT"
# A chip that reports no temperature cannot drive a curve, so offering it would
# silently produce an unreadable sensor set.
check "a chip with no temp is NOT offered"     bash -c '! grep -q "<option> nothermal" <<<"$OUT"'
check "the sensor set is written via install --force" calls_with "install --force"
check "  carrying just the chosen sensor"      calls_with "--sensors k10temp"
check "  and preserving the installed curve"   grep -qF 'TEP_CURVE=70:100' "$UNIT"

echo "## 10. a rival fan service is reported, not guessed at"

# This is the failure that looks like "the curve does nothing" with no error
# anywhere: another service writing the EC's one duty register. The front-end
# must not scan systemd itself — the count comes from `config` and the detail
# from `conflicts`, so what it reports is what a run would actually hit.
cat > "$T/units/rival.service" <<'RIVAL'
[Service]
ExecStart=/usr/local/bin/rival.sh
ExecStopPost=/usr/bin/ectool autofanctrl
RIVAL
: > "$STATES/rival.service.enabled"

tui quit
check "the conflict is reported at startup"    has "also drive ectool" "$OUT"
check "  naming the rival unit"                has "rival.service" "$OUT"
check "  and saying it starts at boot"         has "enabled at boot" "$OUT"
check "  with the way out"                     has "systemctl disable --now" "$OUT"
# Asked of the engine, not re-derived here.
check "conflicts is asked of the engine"       calls_with "conflicts"

rm -f "$T/units/rival.service" "$STATES/rival.service.enabled"
tui quit
check "a clean host says nothing about conflicts" bash -c '! grep -q "also drive ectool" <<<"$OUT"'

echo "## 11. remove the service"

tui "remove the service" yes no
check "uninstall carries --yes"                calls_with "uninstall --yes"
check "  so the engine never asks again"       bash -c '! grep -q "no terminal" <<<"$OUT"'
check "the unit is gone"                       bash -c '[[ ! -e "'"$UNIT"'" ]]'
check "the fans were handed back to the EC"    grep -qF 'autofanctrl' "$ECCALLS"

# With nothing installed, the curve actions must say so rather than fail oddly.
tui "change the curve" no
check "change the curve needs an install"      has "Nothing is installed yet" "$OUT"
tui "choose sensors" no
check "choose sensors needs an install"        has "Nothing is installed yet" "$OUT"
tui "remove the service" no
check "removing nothing is reported, not an error" has "Nothing is installed" "$OUT"

echo
if (( FAILS )); then echo "${FAILS} check(s) failed"; exit 1; fi
echo "all checks passed"
