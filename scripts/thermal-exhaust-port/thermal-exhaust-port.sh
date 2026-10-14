#!/usr/bin/env bash
# description: Stepped fan curve for EC-controlled fans (Framework Desktop) — no hwmon PWM needed
# Standalone export (export.sh): no extra setup deps — ectool comes from the
# host's firmware tooling (already present on Bazzite) and cannot be installed
# from a package manager, so the menu reports it rather than promising a fix.
# -----------------------------------------------------------------------------
# thermal-exhaust-port.sh — gum front-end for the thermal-exhaust-port engine.
#
# scomp-link owns the interactive experience (this file); the fan-curve logic
# lives in the standalone thermal-exhaust-port engine (its own repo): a gum-free,
# flag-driven CLI built to run unattended as a systemd service. This shim
# resolves the engine (local checkout → cache → clone), collects a curve and a
# sensor set via gum, and runs the engine with the matching flags — the
# holonet-sync pattern.
#
# The engine is the one that knows where its unit lives, what the installed
# curve is and which sensors the host actually has, so this front-end asks it
# (`engine config`, `engine sensors`, `engine curve`) instead of re-deriving any
# of it. A picker that disagrees with what the service actually reads is worse
# than no picker at all.
#
# Engine resolution order:
#   1. $THERMAL_EXHAUST_PORT_DIR/thermal-exhaust-port.sh   (explicit override)
#   2. ../../../thermal-exhaust-port/thermal-exhaust-port.sh (sibling checkout)
#   3. ~/.cache/scomp-link/thermal-exhaust-port/…          (cached clone; offers git pull)
#   4. git clone --depth 1 (public HTTPS)                   (first run)
#
# Sourced helpers (scripts/_common/):
#   ui.sh — header/info/success/warn/error_exit
# -----------------------------------------------------------------------------

if [[ "${BASH_VERSINFO[0]:-0}" -lt 4 ]]; then
    echo "[error] bash 4+ required (you have ${BASH_VERSION}). On macOS: brew install bash" >&2
    exit 1
fi

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Vendor-aware: ../_common in the repo, or alongside this script when exported.
if [[ -d "${SCRIPT_DIR}/../_common" ]]; then
    COMMON_DIR="${SCRIPT_DIR}/../_common"   # scomp-link repo layout
else
    COMMON_DIR="${SCRIPT_DIR}"              # exported standalone: deps sit alongside
fi

# shellcheck source=../_common/ui.sh
source "${COMMON_DIR}/ui.sh"

command -v gum &>/dev/null || { echo "[error] gum is required. Run setup.sh first." >&2; exit 1; }
command -v git &>/dev/null || { echo "[error] git is required to fetch the engine." >&2; exit 1; }

trap 'echo ""; gum style --faint "Interrupted."; exit 0' INT TERM

TEP_REPO="${THERMAL_EXHAUST_PORT_REPO:-https://github.com/malahmen/thermal-exhaust-port.git}"
TEP_CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/scomp-link/thermal-exhaust-port"
ENGINE=""

# Engine-reported state, filled by _engine_state.
UNIT_PATH=""; UNIT_EXISTS=0; CURVE=""; HYST=""; SENSORS=""
ACTIVE=""; ECTOOL=""; ECTOOL_OK=0; CONFLICTS=0

# A curve is a fiddly thing to type, so the common intents are offered ready
# made. The labels say what each one is FOR, because "72:35 78:60" tells you
# nothing about whether your machine will be audible at idle.
declare -A PRESETS=(
    ["balanced — quiet at idle, ramps before the 80s"]="72:35 78:60 84:85 88:100"
    ["aggressive — airflow early, never reaches the 80s"]="60:35 70:50 75:75 80:100"
    ["quiet — let the EC handle anything below 78C"]="78:40 84:70 88:100"
    ["flat out above 70C — loud, simple, cool"]="70:100"
)

# -----------------------------------------------------------------------------
# Resolve the thermal-exhaust-port engine (override → sibling → cache → clone).
# -----------------------------------------------------------------------------
resolve_engine() {
    if [[ -n "${THERMAL_EXHAUST_PORT_DIR:-}" && -f "${THERMAL_EXHAUST_PORT_DIR}/thermal-exhaust-port.sh" ]]; then
        ENGINE="${THERMAL_EXHAUST_PORT_DIR}/thermal-exhaust-port.sh"
        info "Using thermal-exhaust-port from \$THERMAL_EXHAUST_PORT_DIR: ${THERMAL_EXHAUST_PORT_DIR}"
        return
    fi

    local sib="${SCRIPT_DIR}/../../../thermal-exhaust-port/thermal-exhaust-port.sh"
    if [[ -f "$sib" ]]; then
        ENGINE="$(cd "$(dirname "$sib")" && pwd)/thermal-exhaust-port.sh"
        info "Using local thermal-exhaust-port checkout: $(dirname "$ENGINE")"
        return
    fi

    if [[ -f "${TEP_CACHE}/thermal-exhaust-port.sh" ]]; then
        ENGINE="${TEP_CACHE}/thermal-exhaust-port.sh"
        info "Using cached thermal-exhaust-port: ${TEP_CACHE}"
        if [[ -d "${TEP_CACHE}/.git" ]] && gum confirm "Update thermal-exhaust-port (git pull)?"; then
            gum spin --spinner dot --title "Updating thermal-exhaust-port..." -- \
                git -C "$TEP_CACHE" pull --ff-only || warn "Update failed; using the existing copy."
        fi
        return
    fi

    gum confirm "thermal-exhaust-port engine not found. Clone it from ${TEP_REPO}?" \
        || error_exit "thermal-exhaust-port engine is unavailable."
    mkdir -p "$(dirname "$TEP_CACHE")"
    gum spin --spinner dot --title "Cloning thermal-exhaust-port..." -- \
        git clone --depth 1 "$TEP_REPO" "$TEP_CACHE" \
        || error_exit "Failed to clone thermal-exhaust-port from ${TEP_REPO}"
    ENGINE="${TEP_CACHE}/thermal-exhaust-port.sh"
    success "thermal-exhaust-port cloned to ${TEP_CACHE}"
}

engine() { bash "$ENGINE" "$@"; }
# For the ones that can sit asking sudo for a password, or print for a while:
# Ctrl-C stops just the child and returns to the menu instead of killing the TUI.
engine_foreground() {
    trap ':' INT
    bash "$ENGINE" "$@" || true
    trap 'echo ""; gum style --faint "Interrupted."; exit 0' INT TERM
}

# -----------------------------------------------------------------------------
# Engine-reported state
# -----------------------------------------------------------------------------

# Ask the engine what its unit path is, what curve is installed and whether the
# service is running. Everything the menu shows comes from here.
_engine_state() {
    local key val
    UNIT_PATH=""; UNIT_EXISTS=0; CURVE=""; HYST=""; SENSORS=""
    ACTIVE=""; ECTOOL=""; ECTOOL_OK=0; CONFLICTS=0
    while IFS='=' read -r key val; do
        case "$key" in
            unit)          UNIT_PATH="$val" ;;
            unit_exists)   UNIT_EXISTS="$val" ;;
            curve)         CURVE="$val" ;;
            hyst)          HYST="$val" ;;
            sensors)       SENSORS="$val" ;;
            active)        ACTIVE="$val" ;;
            ectool)        ECTOOL="$val" ;;
            ectool_exists) ECTOOL_OK="$val" ;;
            conflicts)     CONFLICTS="$val" ;;
        esac
    done < <(engine config 2>/dev/null)
    [[ -n "$UNIT_PATH" ]] || error_exit "The engine did not report its config — is ${ENGINE} runnable?"
}

# _ask <prompt> — 0 yes, 1 no, 2 cancelled. gum confirm exits 130 on Esc /
# Ctrl-C, which a plain `gum confirm … && …` would read as "no" and carry on.
_ask() {
    local rc=0
    gum confirm "$@" || rc=$?
    case "$rc" in
        0)   return 0 ;;
        130) return 2 ;;
        *)   return 1 ;;
    esac
}

# Echoes a curve, or "" when cancelled. Presets plus a free-text option, and
# whatever is already installed offered first so "keep this" is one keypress.
_pick_curve() {
    local -a labels=()
    # Only when a unit exists: with nothing installed the engine still reports
    # its DEFAULT curve, and offering that as "the current curve" would claim an
    # install that has not happened.
    (( UNIT_EXISTS )) && [[ -n "$CURVE" ]] && labels+=("keep the installed curve (${CURVE})")
    local k
    for k in "balanced — quiet at idle, ramps before the 80s" \
             "aggressive — airflow early, never reaches the 80s" \
             "quiet — let the EC handle anything below 78C" \
             "flat out above 70C — loud, simple, cool"; do
        labels+=("$k")
    done
    labels+=("enter my own points")

    # Items as arguments, not on stdin: gum reads a list from stdin only when it
    # is given none, and arguments are what a stubbed gum can echo back.
    local choice
    choice=$(gum choose "${labels[@]}" --header "Which curve?") || return 1
    [[ -n "$choice" ]] || return 1

    case "$choice" in
        "keep the installed curve"*) printf '%s' "$CURVE" ;;
        "enter my own points")
            local points
            points=$(gum input --placeholder "72:35 78:60 84:85 88:100" \
                        --prompt "degC:duty% points, ascending > ") || return 1
            [[ -n "$points" ]] || return 1
            printf '%s' "$points" ;;
        *) printf '%s' "${PRESETS[$choice]}" ;;
    esac
}

# -----------------------------------------------------------------------------
# Actions
# -----------------------------------------------------------------------------

action_status() {
    header "Thermal Exhaust Port — Status"
    (( ECTOOL_OK )) || warn "${ECTOOL} not found — the service cannot drive the fans without it."
    engine status || true
}

# The EC has one duty register and this firmware cannot be read back, so two
# services driving it fight with nothing in any log to say so. The engine does
# the looking; this just reports what it found.
_warn_conflicts() {
    (( CONFLICTS )) || return 0
    warn "${CONFLICTS} other service(s) also drive ${ECTOOL##*/} — they would fight over the EC:"
    local u st f
    while IFS=$'\t' read -r u st f; do
        [[ -n "$u" ]] || continue
        warn "  ${u}  [${st}]"
        warn "    ${f}"
    done < <(engine conflicts 2>/dev/null)
    warn "  stop one with: sudo systemctl disable --now <unit>"
}

action_sensors() {
    header "Thermal Exhaust Port — Sensors"
    # Straight from the engine, so the list is what a run would actually read.
    local out
    out=$(engine sensors 2>/dev/null) || { warn "Could not read the sensors."; return 1; }
    printf '%-32s %6s  %s\n' "SENSOR" "degC" "WATCHED"
    local name temp watched
    while IFS=$'\t' read -r name temp watched; do
        printf '%-32s %6s  %s\n' "$name" "$temp" "$( (( watched )) && echo "yes" || echo "-")"
    done <<< "$out"
}

action_fans() {
    header "Thermal Exhaust Port — Fan RPM"
    # Needs root, so it may ask for a password; foreground so Ctrl-C at the
    # prompt returns to the menu.
    engine_foreground fans
}

action_simulate() {
    header "Thermal Exhaust Port — Try a curve"

    local curve
    curve="$(_pick_curve)" || { info "Cancelled."; return 0; }
    [[ -n "$curve" ]] || { info "Cancelled."; return 0; }

    local temps
    temps=$(gum input --value "68 72 76 80 84 88 92 86 80 74 68" \
                --prompt "Temperatures to walk through > ") || { info "Cancelled."; return 0; }
    [[ -n "$temps" ]] || { info "Cancelled."; return 0; }

    info "curve: ${curve}"
    # Unquoted on purpose: the temperatures are separate arguments.
    # shellcheck disable=SC2086
    engine simulate --curve "$curve" -- $temps || return 1
}

action_install() {
    header "Thermal Exhaust Port — Install the service"
    (( ECTOOL_OK )) || warn "${ECTOOL} not found — install the host's EC tooling first."

    local curve
    curve="$(_pick_curve)" || { info "Cancelled."; return 0; }
    [[ -n "$curve" ]] || { info "Cancelled."; return 0; }

    # Show the walk before committing: a curve is much easier to judge as a
    # list of duties than as a list of points.
    info "This curve would do:"
    engine simulate --curve "$curve" -- 68 72 76 80 84 88 92 86 80 74 68 || {
        warn "That curve was rejected — nothing was installed."; return 1; }

    local args=(install --curve "$curve") rc=0
    if (( UNIT_EXISTS )); then
        # Keeping an existing unit is the engine's default, so the question is
        # only about the opposite — and it is the destructive direction.
        _ask --default=false "A unit already exists at ${UNIT_PATH}. Replace its settings?" || rc=$?
        case "$rc" in
            0) args+=(--force) ;;
            2) info "Cancelled."; return 0 ;;
            *) info "Keeping the existing unit; the engine copy will still be refreshed." ;;
        esac
    fi

    _ask "Install and enable the service now? (sudo will ask for your password)" \
        || { info "Cancelled."; return 0; }

    engine_foreground "${args[@]}"
    _engine_state
    # Worth repeating here: a rival service left running is the one failure that
    # looks like "the curve does nothing" with no error anywhere.
    _warn_conflicts
}

action_set_curve() {
    header "Thermal Exhaust Port — Change the curve"
    if (( ! UNIT_EXISTS )); then
        warn "Nothing is installed yet — use 'install the service' first."
        return 0
    fi

    local curve
    curve="$(_pick_curve)" || { info "Cancelled."; return 0; }
    [[ -n "$curve" ]] || { info "Cancelled."; return 0; }
    if [[ "$curve" == "$CURVE" ]]; then info "That is already the installed curve."; return 0; fi

    info "This curve would do:"
    engine simulate --curve "$curve" -- 68 72 76 80 84 88 92 86 80 74 68 || {
        warn "That curve was rejected — the installed one is unchanged."; return 1; }

    _ask "Write this curve and restart the service? (sudo will ask for your password)" \
        || { info "Cancelled."; return 0; }

    engine_foreground set-curve "$curve"
    _engine_state
}

action_pick_sensors() {
    header "Thermal Exhaust Port — Which sensors to watch"
    if (( ! UNIT_EXISTS )); then
        warn "Nothing is installed yet — use 'install the service' first."
        return 0
    fi

    # The list comes from the engine, so it offers exactly the chips this host
    # has rather than a guess at what a Framework board exposes.
    local out
    out=$(engine sensors 2>/dev/null) || { warn "Could not read the sensors."; return 1; }

    local -a names=() selected=()
    local name temp watched
    while IFS=$'\t' read -r name temp watched; do
        # A chip with no temperature at all cannot drive a curve, so it is not
        # offered — picking it would silently produce an unreadable sensor set.
        [[ "$temp" == "-" ]] && continue
        names+=("${name} (${temp}C)")
        (( watched )) && selected+=("${name} (${temp}C)")
    done <<< "$out"
    (( ${#names[@]} )) || { warn "No sensor on this host reports a temperature."; return 1; }

    local sel
    sel=$(gum choose "${names[@]}" --no-limit \
            --selected "$(IFS=,; echo "${selected[*]}")" \
            --header "Space toggles, Enter confirms:") || { info "Cancelled."; return 0; }
    [[ -n "$sel" ]] || { warn "Nothing selected — the curve needs at least one sensor."; return 0; }

    # Back to bare names: the temperature was only there to help you choose.
    local picked=""
    while IFS= read -r name; do picked+="${name%% (*} "; done <<< "$sel"
    picked="${picked% }"

    _ask "Watch: ${picked}? (sudo will ask for your password)" || { info "Cancelled."; return 0; }

    # set-curve only rewrites CURVE, so the sensor set goes in via install
    # --force with the current curve preserved.
    engine_foreground install --force --curve "$CURVE" --hyst "$HYST" --sensors "$picked"
    _engine_state
}

action_uninstall() {
    header "Thermal Exhaust Port — Remove the service"
    if (( ! UNIT_EXISTS )); then info "Nothing is installed."; return 0; fi

    _ask --default=false "Remove ${UNIT_PATH} and hand the fans back to the EC?" \
        || { info "Cancelled."; return 0; }

    engine_foreground uninstall --yes
    _engine_state
}

# -----------------------------------------------------------------------------
# Menu
# -----------------------------------------------------------------------------

main() {
    resolve_engine
    gum style --foreground "${CYAN:-212}" --border-foreground "${CYAN:-212}" --border double \
        --align center --width 64 --margin "1 2" --padding "1 4" \
        "thermal-exhaust-port" "A fan curve for fans the EC owns"

    _engine_state

    # ectool is the one dependency, and it is not a package anywhere — it ships
    # with the host's firmware tooling. Saying so once is more use than a menu
    # item that cannot deliver.
    (( ECTOOL_OK )) || warn "${ECTOOL} not found. On Bazzite it ships in the image; elsewhere it comes from the EC/firmware tooling for your board."
    _warn_conflicts

    if (( ! UNIT_EXISTS )); then
        info "No service installed yet (${UNIT_PATH}). Default curve: ${CURVE}"
    else
        info "Service: ${ACTIVE:-unknown} · curve: ${CURVE} · sensors: ${SENSORS}"
    fi

    while true; do
        local action
        action=$(gum choose \
            "status" "try a curve" "install the service" "change the curve" \
            "choose sensors" "fan rpm" "list sensors" "remove the service" "quit" \
            --header "Choose an action:") || true
        [[ -z "$action" || "$action" == "quit" ]] && { gum style --faint "Bye."; exit 0; }

        # || true on each: under `set -e` a non-zero return from an action would
        # trigger errexit and drop the user back to init.sh's top-level menu,
        # which is exactly what this loop exists to avoid.
        case "$action" in
            status)                 action_status       || true ;;
            "try a curve")          action_simulate     || true ;;
            "install the service")  action_install      || true ;;
            "change the curve")     action_set_curve    || true ;;
            "choose sensors")       action_pick_sensors || true ;;
            "fan rpm")              action_fans         || true ;;
            "list sensors")         action_sensors      || true ;;
            "remove the service")   action_uninstall    || true ;;
        esac

        echo ""
        gum confirm "Back to the menu?" || { gum style --faint "Bye."; exit 0; }
    done
}

main "$@"
