#!/usr/bin/env bash
# bazzite-utils' wine-focus-fix, driven through the gum stub against staged
# prefixes and a staged /proc (BZU_PROC).
#
# What it protects: the fix lands only where it applies (KDE on Wayland, the
# game on Wine's X11 driver, not already set), it never edits user.reg under
# a running wineserver (which would overwrite it on exit) - that goes through
# the session's own wine - and an offline edit changes that one value and
# nothing else, with a backup. The checks read user.reg and the fake wine's
# calls, not what the screen said.
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FRONT="${TEST_DIR}/../scripts/bazzite-utils/bazzite-utils.sh"
[[ -f "$FRONT" ]] || { echo "script not found at $FRONT" >&2; exit 1; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
export PATH="${TEST_DIR}/stubs:$PATH"
export GUM_ANSWERS="$T/answers" GUM_STATE="$T/state"
export HOME="$T/home" XDG_CONFIG_HOME="$T/home/.config" BZU_PROC="$T/proc"
mkdir -p "$HOME"

FAILS=0
check() { local d="$1"; shift; if "$@"; then echo "   ok   - $d"; else echo "   FAIL - $d"; FAILS=$((FAILS + 1)); fi; }
has()   { case "$2" in *"$1"*) return 0 ;; *) return 1 ;; esac; }

if command -v timeout &>/dev/null; then LIMIT_CMD=timeout; else LIMIT_CMD=""; fi
limited() { if [[ -n "$LIMIT_CMD" ]]; then "$LIMIT_CMD" 60 "$@"; else "$@"; fi; }

# A Wine registry as Wine writes it. $1: the prefix; the rest: extra sections.
REG_HEAD='WINE REGISTRY Version 2
;; All keys relative to \\User\\S-1-5-21-0-0-0-1000

#arch=win64

[Control Panel\\Desktop] 1792432429
#time=1dd5ff2cba55a4e
"WheelScrollLines"="3"
'
mkprefix() {
    local p="$1"; shift
    rm -rf "$p"; mkdir -p "$p/drive_c"
    { printf '%s\n' "$REG_HEAD"; local s; for s in "$@"; do printf '%s\n\n' "$s"; done; } > "$p/user.reg"
}
X11_Y='[Software\\Wine\\X11 Driver] 1792432429
#time=1dd5ff2cba55a4e
"KeyboardLayoutList"=str(7):"United States keyboard layout\0"
"UseTakeFocus"="Y"'
X11_N='[Software\\Wine\\X11 Driver] 1792432429
"UseTakeFocus"="N"'
DRV_WL='[Software\\Wine\\Drivers] 1792432429
"Graphics"="wayland,x11"'

# The fake wine records its argv and keeps the value "the session" holds.
# Its reg query ends lines with CRLF, as the real wine's console does.
PROTON="$T/proton"; mkdir -p "$PROTON/files/bin"
cat > "$PROTON/files/bin/wine" <<EOF
#!/usr/bin/env bash
printf '%s|%s\n' "\$WINEPREFIX" "\$*" >> "$T/wine-calls"
case "\$1" in
    # reg add <key> /v <name> /t <type> /d <value> /f: the value is the 9th.
    reg) [[ "\$2" == add ]] && printf '%s' "\${9}" > "$T/live-value"
         [[ "\$2" == query ]] && printf '    UseTakeFocus    REG_SZ    %s\r\n' "\$(cat "$T/live-value" 2>/dev/null)" ;;
esac
exit 0
EOF
printf '#!/usr/bin/env bash\nexit 0\n' > "$PROTON/files/bin/wineserver"
chmod +x "$PROTON/files/bin/wine" "$PROTON/files/bin/wineserver"

# A process in the staged /proc. $1 pid, $2 comm, $3 exe (or ""), rest: env.
proc() {
    local pid="$1" comm="$2" exe="$3"; shift 3
    mkdir -p "$BZU_PROC/$pid"
    printf '%s\n' "$comm" > "$BZU_PROC/$pid/comm"
    printf '%s\0' "$@" > "$BZU_PROC/$pid/environ"
    [[ -n "$exe" ]] && ln -sfn "$exe" "$BZU_PROC/$pid/exe"
}
noproc() { rm -rf "$BZU_PROC"; mkdir -p "$BZU_PROC"; }

export OUT=""
tui() {   # tui <session> <answers...>
    local session="$1"; shift
    : > "$T/wine-calls"
    printf '%s\n' "$@" > "$GUM_ANSWERS"; echo 0 > "$GUM_STATE"
    OUT="$(XDG_CURRENT_DESKTOP="${session%/*}" XDG_SESSION_TYPE="${session#*/}" \
        limited bash "$FRONT" wine-focus-fix </dev/null 2>&1)"
}
KDE="KDE/wayland"
ENTER="Enter a prefix path…"
reg_val() { awk '/^\[/{s=($0 ~ /^\[Software\\\\Wine\\\\X11 Driver\]/);next} s&&/^"UseTakeFocus"=/{print}' "$1/user.reg"; }
n_lines() { grep -c '"UseTakeFocus"=' "$1/user.reg"; }

P="$T/games/bnet/pfx"

echo "## 1. offline, no X11 Driver section: one is added, the rest is kept, with a backup"
noproc; mkprefix "$P"; cp "$P/user.reg" "$T/before"
tui "$KDE" "$ENTER" "$P" yes
check "it says the session is the affected one"           has "KDE Plasma on Wayland" "$OUT"
check "UseTakeFocus=N is in the X11 Driver section"        [ "$(reg_val "$P")" = '"UseTakeFocus"="N"' ]
check "exactly one UseTakeFocus line"                      [ "$(n_lines "$P")" = 1 ]
check "every original line is still there, in order"       bash -c "diff <(grep -v -e 'X11 Driver' -e UseTakeFocus '$P/user.reg' | sed '/^\$/d') <(sed '/^\$/d' '$T/before')"
check "a backup holds the previous registry"               bash -c "cmp -s '$T/before' $P/user.reg.scomp-bak-*"
check "no wine was run on a stopped prefix"                [ ! -s "$T/wine-calls" ]
check "the prefix is remembered"                           grep -q "^WINE_FOCUS_PREFIX=" "$XDG_CONFIG_HOME/bazzite-utils/bazzite-utils.conf"

echo "## 2. offline, Y already in the section: replaced in place, after #time"
noproc; mkprefix "$P" "$X11_Y"
tui "$KDE" "saved: $P" yes
check "the saved prefix was offered and used"              has "saved: $P" "$OUT"
check "it reported the old value"                          has "UseTakeFocus: Y" "$OUT"
check "the value is now N"                                 [ "$(reg_val "$P")" = '"UseTakeFocus"="N"' ]
check "still exactly one UseTakeFocus line"                [ "$(n_lines "$P")" = 1 ]
check "it sits right after the #time line"                 bash -c "grep -A1 '^#time=1dd5ff2cba55a4e' '$P/user.reg' | tail -1 | grep -q UseTakeFocus"
check "the section's other values are kept"                grep -q '"KeyboardLayoutList"' "$P/user.reg"

echo "## 3. already N: nothing to do; the undo prompt defaults to no"
noproc; mkprefix "$P" "$X11_N"; cp "$P/user.reg" "$T/before"
tui "$KDE" "saved: $P" enter
check "it says it is already applied"                      has "Already applied" "$OUT"
check "Enter on the undo prompt changes nothing"           cmp -s "$P/user.reg" "$T/before"
tui "$KDE" "saved: $P" yes
check "a yes to undo puts Wine's default back"             [ "$(reg_val "$P")" = '"UseTakeFocus"="Y"' ]

echo "## 4. Wine's Wayland driver: not needed, nothing written"
noproc; mkprefix "$P" "$DRV_WL"; cp "$P/user.reg" "$T/before"
tui "$KDE" "saved: $P"
check "it says the Wayland driver ignores it"              has "Not needed" "$OUT"
check "user.reg is untouched"                              cmp -s "$P/user.reg" "$T/before"

echo "## 5. another session: refused unless confirmed (default no)"
noproc; mkprefix "$P"; cp "$P/user.reg" "$T/before"
tui "GNOME/x11" "saved: $P" enter
check "it warns this fix is for KDE on Wayland"            has "This fix is for KDE Plasma on Wayland" "$OUT"
check "Enter cancels: user.reg is untouched"               cmp -s "$P/user.reg" "$T/before"

echo "## 6. running under XWayland: through the session's own wine, never the file"
noproc; mkprefix "$P"; cp "$P/user.reg" "$T/before"; rm -f "$T/live-value"
proc 100 Wow.exe "" "WINEPREFIX=$P/" "DISPLAY=:0" "PROTONPATH=$PROTON"
proc 101 wineserver "$PROTON/files/bin/wineserver" "WINEPREFIX=$P"
# A launcher's wrapper in the prefix with no DISPLAY (lutris-wrapper is one):
# it must not make the game look like it is on the Wayland driver.
proc 102 lutris-wrapper: "" "WINEPREFIX=$P"
tui "$KDE" "running: $P  (Wow.exe)" yes
check "the running prefix was offered, with the game"      has "running: $P  (Wow.exe)" "$OUT"
check "it saw the game on the X11 driver"                  has "through XWayland" "$OUT"
check "reg add ran through the session's wine"             grep -qF "$P|reg add HKCU\\Software\\Wine\\X11 Driver /v UseTakeFocus /t REG_SZ /d N /f" "$T/wine-calls"
check "and read the value back"                            grep -qF "$P|reg query" "$T/wine-calls"
check "user.reg was not edited under the wineserver"       cmp -s "$P/user.reg" "$T/before"
check "it says the value reaches disk on a clean exit"     has "close the game AND its launcher normally" "$OUT"

echo "## 7. running with PROTON_ENABLE_WAYLAND=1: not needed, no wine run"
noproc; mkprefix "$P"
proc 200 Wow.exe "" "WINEPREFIX=$P" "DISPLAY=:0" "PROTONPATH=$PROTON" "PROTON_ENABLE_WAYLAND=1"
tui "$KDE" "running: $P  (Wow.exe)"
check "it says the Wayland driver ignores it"              has "PROTON_ENABLE_WAYLAND=1" "$OUT"
check "no wine was run"                                    [ ! -s "$T/wine-calls" ]

echo "## 8. not a prefix, and the EA setting survives this command's save"
noproc; mkdir -p "$T/notapfx"
printf 'EA_PREFIX=%q\n' "$T/ea pfx" > "$XDG_CONFIG_HOME/bazzite-utils/bazzite-utils.conf"
mkprefix "$P"
tui "$KDE" "$ENTER" "$T/notapfx"
check "a folder without user.reg/drive_c is refused"       has "is not a Wine prefix" "$OUT"
tui "$KDE" "$ENTER" "$P" esc
check "EA_PREFIX is kept when this command saves"          grep -qF "EA_PREFIX=$(printf '%q' "$T/ea pfx")" "$XDG_CONFIG_HOME/bazzite-utils/bazzite-utils.conf"

echo "## 9. the real layout: a Proton base folder, a symlinked alias, Wine's own processes"
# Lutris/umu give the base folder as WINEPREFIX and Proton keeps the prefix
# in its pfx/; on Bazzite /home is a symlink to /var/home. Found running the
# command on the real machine (2026-11-16): three entries for one prefix.
noproc; rm -rf "$T/real" "$T/alias"
mkprefix "$T/real/bnet/pfx"; ln -s "$T/real" "$T/alias"
REALP="$(realpath "$T/real/bnet/pfx")"
proc 300 lutris-wrapper: "" "WINEPREFIX=$T/alias/bnet"
proc 301 umu.exe "" "WINEPREFIX=$T/real/bnet" "DISPLAY=:0"
proc 302 services.exe "" "WINEPREFIX=$T/real/bnet/pfx/" "DISPLAY=:0"
proc 303 Wow.exe "" "WINEPREFIX=$T/real/bnet/pfx/" "DISPLAY=:0" "PROTONPATH=$PROTON"
proc 304 Wow.exe "" "WINEPREFIX=$T/real/bnet/pfx/" "DISPLAY=:0"
proc 305 wineserver "$PROTON/files/bin/wineserver" "WINEPREFIX=$T/real/bnet/pfx"
# Another user's process: its environ cannot be read (root reads everything,
# so the check below is only meaningful as a normal user, as CI runs).
proc 306 systemd "" "WINEPREFIX=/nope"; chmod 000 "$BZU_PROC/306/environ"
rm -f "$T/live-value"
tui "$KDE" "running: $REALP  (Wow.exe)" yes
check "an unreadable process prints nothing"              bash -c '! grep -q "Permission denied" <<<"$OUT"' 
check "one entry: the real pfx/, with the game only"       has "<option> running: $REALP  (Wow.exe)" "$OUT"
check "no entry for the base folder or the alias"          bash -c '! grep -E "<option> running: .*/(alias|real)/bnet( |\$)" <<<"$OUT"'
check "the wrapper with no DISPLAY did not mislead it"     has "through XWayland" "$OUT"
check "reg add ran on the real prefix"                     grep -qF "$REALP|reg add" "$T/wine-calls"
check "the real prefix is what is saved"                   grep -qF "WINE_FOCUS_PREFIX=$(printf '%q' "$REALP")" "$XDG_CONFIG_HOME/bazzite-utils/bazzite-utils.conf"

echo
if (( FAILS )); then echo "FAIL - ${FAILS} check(s) failed"; exit 1; fi
echo "PASS"
