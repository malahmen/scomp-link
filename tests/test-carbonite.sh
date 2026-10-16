#!/usr/bin/env bash
# The carbonite front-end, driven through the gum stub against the real engine
# and the engine's fake CoolerControl (a curl stand-in with state on disk).
#
# What it protects is the same as for thermal-exhaust-port: the front-end must
# never invent the curve, the sensors or the fans. They come from the engine
# (`config`, `sensors`, `channels`), which reads them from CoolerControl. So the
# checks look at the flags the engine was run with and at what reached the fake
# daemon, not at what the screen said.
# shellcheck disable=SC2016
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FRONT="${TEST_DIR}/../scripts/carbonite/carbonite.sh"
[[ -f "$FRONT" ]] || { echo "front-end not found at $FRONT" >&2; exit 1; }

REAL_DIR="${CARBONITE:-${TEST_DIR}/../../carbonite}"
if [[ ! -f "${REAL_DIR}/carbonite.sh" || ! -f "${REAL_DIR}/tests/fake-coolercontrol" ]]; then
    echo "SKIP - no carbonite engine at ${REAL_DIR} (set \$CARBONITE)" >&2
    exit 0
fi
command -v jq &>/dev/null || { echo "SKIP - jq is required" >&2; exit 0; }
REAL_DIR="$(cd "$REAL_DIR" && pwd)"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
export PATH="${TEST_DIR}/stubs:$PATH"
export GUM_ANSWERS="$T/answers" GUM_STATE="$T/state"
export FAKE_CC="$T/cc" CARB_CURL="${REAL_DIR}/tests/fake-coolercontrol"
export CARB_CONFIG_DIR="$T/conf" CARB_URL="http://cc.test:11987" CARB_TOKEN="tok"
export CARB_SYSTEMCTL="$T/systemctl"
printf '#!/usr/bin/env bash\nexit 1\n' > "$CARB_SYSTEMCTL"; chmod +x "$CARB_SYSTEMCTL"
# shellcheck source=/dev/null
source "${REAL_DIR}/tests/fixture.sh"

FAILS=0
check() { local d="$1"; shift; if "$@"; then echo "   ok   - $d"; else echo "   FAIL - $d"; FAILS=$((FAILS + 1)); fi; }
has()   { case "$2" in *"$1"*) return 0 ;; *) return 1 ;; esac; }

if command -v timeout &>/dev/null; then LIMIT_CMD=timeout; else LIMIT_CMD=""; fi
limited() { if [[ -n "$LIMIT_CMD" ]]; then "$LIMIT_CMD" 90 "$@"; else "$@"; fi; }

# The engine the front-end resolves records its argv, then runs the real one.
mkdir -p "$T/fake"
cat > "$T/fake/carbonite.sh" <<WRAP
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$T/calls"
exec bash "${REAL_DIR}/carbonite.sh" "\$@"
WRAP

export OUT=""
CALLS=""
tui() {
    : > "$T/calls"
    printf '%s\n' "$@" > "$GUM_ANSWERS"; echo 0 > "$GUM_STATE"
    OUT="$(CARBONITE_DIR="$T/fake" limited bash "$FRONT" </dev/null 2>&1)"
    [[ -n "$OUT" ]] || { echo "   FAIL - the front-end did not run" >&2; exit 1; }
    CALLS="$(cat "$T/calls")"
}
calls_with() { grep -q -- "$1" <<<"$CALLS"; }
no_call()    { ! grep -q -- "$1" <<<"$CALLS"; }
cc_wrote()   { grep -qE "^(POST|PUT|DELETE) /(profiles|functions|devices)" "$FAKE_CC/calls"; }

NCT8="${NCT:0:8}"; CPU8="${CPU:0:8}"; GPU8="${GPU:0:8}"
FAN1="${NCT8}:fan1  CPU Fan (1120 rpm · 35%) — nct6687"
FAN2="${NCT8}:fan2  Pump Fan (2850 rpm · 100%) — nct6687"
FAN3="${NCT8}:fan3  System Fan #1 (3022 rpm · 60%) — nct6687"
SCPU="${CPU8}:temp1  CPU Temp Package Id 0 (43C) — 12th Gen Intel(R) Core(TM) i5-12400F"
SGPU="${GPU8}:GPU_Temp  GPU Temp (36C) — NVIDIA GeForce RTX 5060 Ti"
BAL="balanced — near-silent at idle, full by 85C"
NOPUMP="no AIO pump here (air cooler)"
NOSTALL="none — they all keep spinning at low speed"
# The fake daemon and the engine's own config (pins) start clean each time.
fresh() { reset_cc; rm -rf "$CARB_CONFIG_DIR"; }
setting() { jq -r --arg c "$2" ".settings[] | select(.channel_name == \$c) | .$3 // \"null\"" "$FAKE_CC/settings-$1.json" 2>/dev/null; }
# The `bash -c` checks read these from the environment.
export NCT FAN1 FAN2 FAN3; export -f setting

echo "## 1. the front-end asks the engine for its state"
reset_cc
tui quit
check "config is the first thing it asks for"   calls_with "config"
check "nothing applied is said"                 has "No curve applied" "$OUT"
check "the engine's default curve is shown"     has "Default curve: 30:25 50:35 65:55 75:75 85:100" "$OUT"
for item in "status" "try a curve" "apply a curve" "change the curve" "list sensors" \
            "list fans" "unpin a fan" "hand back to the board" "set the access token"; do
    check "'${item}' is offered" has "<option> ${item}" "$OUT"
done

echo "## 2. no daemon, no token: said once, nothing attempted"
touch "$FAKE_CC/down"
tui "apply a curve" no
check "a down daemon is reported"               has "not answering" "$OUT"
check "  and apply never reaches the engine"    no_call "apply"
rm "$FAKE_CC/down"
CARB_TOKEN="" tui "apply a curve" no
check "a missing token is reported"             has "No working access token" "$OUT"
check "  and apply never reaches the engine"    no_call "apply"

echo "## 3. try a curve simulates and writes nothing"
fresh
tui "try a curve" "$BAL" "57 80" no
check "simulate carries the preset"             calls_with "simulate --curve 30:25 50:35 65:55 75:75 85:100 -- 57 80"
check "the walk is shown"                       has "57   44%" "$OUT"
check "CoolerControl was not written"           bash -c '! grep -qE "^(POST|PUT|DELETE) /(profiles|functions|devices)" "$FAKE_CC/calls"'

echo "## 4. apply, the MSI way: pump on CPU_FAN1, radiator fans on 'Pump Fan' with a floor"
fresh
tui "apply a curve" "enter my own points" "30:30 50:50 80:100" \
    "${SCPU}\\n${SGPU}" "$FAN1" "$FAN3\\n$FAN2" "$FAN2" "45" yes no
check "the pump question does not trust labels"  has "Header labels can lie" "$OUT"
check "  and offers 'no pump'"                  has "<option> ${NOPUMP}" "$OUT"
check "the pump is not offered for the curve"   bash -c '[[ $(grep -c "<option> ${FAN1}" <<<"$OUT") == 1 ]]'
check "the preview precedes the confirmation"   bash -c '
    p=$(grep -n "80   100%" <<<"$OUT" | head -1 | cut -d: -f1)
    q=$(grep -n "<confirm> Apply" <<<"$OUT" | head -1 | cut -d: -f1)
    [[ -n "$p" && -n "$q" && "$p" -lt "$q" ]]'
check "apply carries the curve"                 calls_with "apply --curve 30:30 50:50 80:100"
check "  both picked sensors"                   calls_with "--sensors ${CPU8}:temp1 ${GPU8}:GPU_Temp"
check "  the fans, the stalling one floored"    calls_with "--channels ${NCT8}:fan3 ${NCT8}:fan2@45"
check "  and the pump pinned at 100%"           calls_with "--pin ${NCT8}:fan1@100"
check "the daemon holds the pump at 100%"       bash -c '[[ $(setting "$NCT" fan1 speed_fixed) == 100 ]]'
check "  and the radiator fans on the 45% set"  bash -c '[[ $(setting "$NCT" fan2 profile_uid) == carbonite-m45 ]]'
tui quit
check "the state is read back"                  has "fans: ${NCT8}:fan2@45 ${NCT8}:fan3 · pinned: ${NCT8}:fan1@100" "$OUT"

echo "## 5. an air cooler: no pin, no floor"
fresh
tui "apply a curve" "$BAL" "$SCPU" "$NOPUMP" "$FAN1\\n$FAN3" "$NOSTALL" yes no
check "apply has no --pin"                      no_call "--pin"
check "the fans go on the curve"                calls_with "--channels ${NCT8}:fan1 ${NCT8}:fan3"
check "  with no floor"                         bash -c '! grep -q "@" <<<"$(grep -- "--channels" <<<"'"$CALLS"'")"'

echo "## 6. declining, Esc or a bad floor writes nothing"
fresh
tui "apply a curve" "$BAL" "$SCPU" "$FAN1" "$FAN3" "$NOSTALL" no no
check "a declined apply never calls apply"      no_call "apply --curve"
tui "apply a curve" "$BAL" "$SCPU" "$FAN1" "$FAN3" "$NOSTALL" esc no
check "Esc never calls apply"                   no_call "apply --curve"
tui "apply a curve" "$BAL" "$SCPU" "$FAN1" "$FAN3" "$FAN3" "lots" no
check "a floor that is not a number stops it"   no_call "apply --curve"
check "  and says so"                           has "Not a duty" "$OUT"
check "CoolerControl was not written"           bash -c '! grep -qE "^(POST|PUT|DELETE) /(profiles|functions|devices)" "$FAKE_CC/calls"'

echo "## 7. a second apply offers what is there now"
fresh
bash "${REAL_DIR}/carbonite.sh" apply --curve "30:30 80:100" --pin "${NCT8}:fan1@100" --channels "${NCT8}:fan2@45 ${NCT8}:fan3" &>/dev/null
tui "apply a curve" esc no
tui "apply a curve" "$BAL" "$SCPU" "" no
check "the pinned pump is offered first"        bash -c '
    a=$(grep -n "<option> ${FAN1}" <<<"$OUT" | head -1 | cut -d: -f1)
    b=$(grep -n "<option> ${FAN2}" <<<"$OUT" | head -1 | cut -d: -f1)
    [[ -n "$a" && -n "$b" && "$a" -lt "$b" ]]'
tui "apply a curve" "$BAL" "$SCPU" "$NOPUMP" "$FAN3" "$NOSTALL" yes no
check "an old pin left out stays pinned"        has "${NCT8}:fan1 stays pinned" "$OUT"
check "  and is not released"                   bash -c '[[ $(setting "$NCT" fan1 speed_fixed) == 100 ]]'

echo "## 8. change the curve uses set-curve"
fresh
bash "${REAL_DIR}/carbonite.sh" apply --curve "30:30 80:100" --channels "${NCT8}:fan3" &>/dev/null
tui "change the curve" esc no
check "the applied curve is offered to keep"    has "<option> keep the applied curve (30:30 80:100)" "$OUT"
tui "change the curve" "$BAL" yes no
check "set-curve is called"                     calls_with "set-curve 30:25 50:35 65:55 75:75 85:100"
check "  not apply"                             no_call "apply --curve"
tui "change the curve" "keep the applied curve (30:25 50:35 65:55 75:75 85:100)" no
check "keeping the curve does nothing"          no_call "set-curve"

echo "## 9. list fans says what controls each"
fresh
bash "${REAL_DIR}/carbonite.sh" apply --curve "30:30 80:100" --pin "${NCT8}:fan1@100" --channels "${NCT8}:fan2@45 ${NCT8}:fan3" &>/dev/null
tui "list fans" no
check "a pin"                                   has "pinned at 100%" "$OUT"
check "a floor"                                 has "curve, never below 45%" "$OUT"
check "a fan the board runs"                    has "board" "$OUT"

echo "## 10. unpin and hand back"
tui "unpin a fan" "$FAN1" no no
check "a declined unpin changes nothing"        no_call "unpin"
tui "hand back to the board" yes no
check "release carries --yes"                   calls_with "release --yes"
check "  and says the pin is kept"              has "kept" "$OUT"
check "the pump is still pinned"                bash -c '[[ $(setting "$NCT" fan1 speed_fixed) == 100 ]]'
tui "unpin a fan" "$FAN1" yes no
check "unpin carries --yes"                     calls_with "unpin ${NCT8}:fan1 --yes"
check "the pump went back to the board"         bash -c '[[ $(setting "$NCT" fan1 profile_uid) == 0 ]]'

echo
(( FAILS == 0 )) && { echo "all passed"; exit 0; }
echo "${FAILS} failed"; exit 1
