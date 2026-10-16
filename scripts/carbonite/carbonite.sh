#!/usr/bin/env bash
# description: Fan curve for hwmon fans (MSI/NCT6687 desktops) — applied through CoolerControl, AIO pump pinned
# Standalone export (export.sh): no extra setup deps — curl and jq are the
# engine's, and CoolerControl is a host package with a GUI of its own, so the
# menu reports a missing daemon rather than installing one.
# -----------------------------------------------------------------------------
# carbonite.sh — gum front-end for the carbonite engine.
#
# The desktop sibling of thermal-exhaust-port. Same end problem — the board's
# own fan behaviour is wrong (here: a BIOS curve with headers pinned at full
# speed) — but the opposite hardware: every header is a writable hwmon pwmN, and
# CoolerControl is already the daemon for that. So the engine is not a daemon;
# it writes a curve into CoolerControl over its API and reads it back.
#
# As with thermal-exhaust-port, this file never re-derives anything: the curve,
# the sensors and the fans all come from the engine (`config`, `sensors`,
# `channels`), which gets them from CoolerControl. A picker that disagrees with
# what the daemon actually runs is worse than none.
#
# Engine resolution order:
#   1. $CARBONITE_DIR/carbonite.sh              (explicit override)
#   2. ../../../carbonite/carbonite.sh          (sibling checkout)
#   3. ~/.cache/scomp-link/carbonite/…          (cached clone; offers git pull)
#   4. git clone --depth 1 (public HTTPS)       (first run)
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

CARB_REPO="${CARBONITE_REPO:-https://github.com/malahmen/carbonite.git}"
CARB_CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/scomp-link/carbonite"
ENGINE=""

# Engine-reported state, filled by _engine_state.
URL=""; TOKEN=""; REACHABLE=0; AUTHORIZED=0; APPLIED=0
CURVE=""; DEFAULT_CURVE=""; SENSORS=""; CHANNELS=""; PINS=""; HYST=""; DELAY=""; CONFLICTS=0

# Desktop presets, read against a CPU package sensor (TjMax 100C on a 12th-gen
# Intel) and a GPU core sensor. Labelled by what they are FOR.
declare -A PRESETS=(
    ["balanced — near-silent at idle, full by 85C"]="30:25 50:35 65:55 75:75 85:100"
    ["quiet — slow until the 60s, full by 90C"]="40:20 60:30 70:50 80:75 90:100"
    ["aggressive — airflow early, full by 78C"]="30:35 45:50 60:70 70:90 78:100"
)
PRESET_ORDER=("balanced — near-silent at idle, full by 85C"
              "quiet — slow until the 60s, full by 90C"
              "aggressive — airflow early, full by 78C")
WALK="30 40 50 60 70 80 90"

# -----------------------------------------------------------------------------
# Resolve the carbonite engine (override → sibling → cache → clone).
# -----------------------------------------------------------------------------
resolve_engine() {
    if [[ -n "${CARBONITE_DIR:-}" && -f "${CARBONITE_DIR}/carbonite.sh" ]]; then
        ENGINE="${CARBONITE_DIR}/carbonite.sh"
        info "Using carbonite from \$CARBONITE_DIR: ${CARBONITE_DIR}"
        return
    fi

    local sib="${SCRIPT_DIR}/../../../carbonite/carbonite.sh"
    if [[ -f "$sib" ]]; then
        ENGINE="$(cd "$(dirname "$sib")" && pwd)/carbonite.sh"
        info "Using local carbonite checkout: $(dirname "$ENGINE")"
        return
    fi

    if [[ -f "${CARB_CACHE}/carbonite.sh" ]]; then
        ENGINE="${CARB_CACHE}/carbonite.sh"
        info "Using cached carbonite: ${CARB_CACHE}"
        if [[ -d "${CARB_CACHE}/.git" ]] && gum confirm "Update carbonite (git pull)?"; then
            gum spin --spinner dot --title "Updating carbonite..." -- \
                git -C "$CARB_CACHE" pull --ff-only || warn "Update failed; using the existing copy."
        fi
        return
    fi

    gum confirm "carbonite engine not found. Clone it from ${CARB_REPO}?" \
        || error_exit "carbonite engine is unavailable."
    mkdir -p "$(dirname "$CARB_CACHE")"
    gum spin --spinner dot --title "Cloning carbonite..." -- \
        git clone --depth 1 "$CARB_REPO" "$CARB_CACHE" \
        || error_exit "Failed to clone carbonite from ${CARB_REPO}"
    ENGINE="${CARB_CACHE}/carbonite.sh"
    success "carbonite cloned to ${CARB_CACHE}"
}

engine() { bash "$ENGINE" "$@"; }

# -----------------------------------------------------------------------------
# Engine-reported state
# -----------------------------------------------------------------------------
_engine_state() {
    local key val
    URL=""; TOKEN=""; REACHABLE=0; AUTHORIZED=0; APPLIED=0
    CURVE=""; DEFAULT_CURVE=""; SENSORS=""; CHANNELS=""; PINS=""; HYST=""; DELAY=""; CONFLICTS=0
    while IFS='=' read -r key val; do
        case "$key" in
            url)           URL="$val" ;;
            token)         TOKEN="$val" ;;
            reachable)     REACHABLE="$val" ;;
            authorized)    AUTHORIZED="$val" ;;
            applied)       APPLIED="$val" ;;
            curve)         CURVE="$val" ;;
            default_curve) DEFAULT_CURVE="$val" ;;
            sensors)       SENSORS="$val" ;;
            channels)      CHANNELS="$val" ;;
            pins)          PINS="$val" ;;
            hyst)          HYST="$val" ;;
            delay)         DELAY="$val" ;;
            conflicts)     CONFLICTS="$val" ;;
        esac
    done < <(engine config 2>/dev/null)
    [[ -n "$URL" ]] || error_exit "The engine did not report its config — is ${ENGINE} runnable?"
}

# _ask <prompt> — 0 yes, 1 no, 2 cancelled (gum confirm exits 130 on Esc).
_ask() {
    local rc=0
    gum confirm "$@" || rc=$?
    case "$rc" in
        0)   return 0 ;;
        130) return 2 ;;
        *)   return 1 ;;
    esac
}

# Every action that talks to CoolerControl needs the daemon and a token. Said
# once, with the way out, instead of an API error per menu item.
_need_auth() {
    if (( ! REACHABLE )); then
        warn "CoolerControl is not answering at ${URL}."
        warn "  start it with: sudo systemctl enable --now coolercontrold"
        return 1
    fi
    if (( ! AUTHORIZED )); then
        warn "No working access token — use 'set the access token' first."
        return 1
    fi
}

# Echoes a curve, or returns 1 when cancelled.
_pick_curve() {
    local -a labels=()
    (( APPLIED )) && [[ -n "$CURVE" ]] && labels+=("keep the applied curve (${CURVE})")
    labels+=("${PRESET_ORDER[@]}" "enter my own points")

    local choice
    choice=$(gum choose "${labels[@]}" --header "Which curve? (degC:duty%, CPU package / GPU core)") || return 1
    [[ -n "$choice" ]] || return 1

    case "$choice" in
        "keep the applied curve"*) printf '%s' "$CURVE" ;;
        "enter my own points")
            local points
            points=$(gum input --placeholder "${DEFAULT_CURVE}" \
                        --prompt "degC:duty% points, ascending > ") || return 1
            [[ -n "$points" ]] || return 1
            printf '%s' "$points" ;;
        *) printf '%s' "${PRESETS[$choice]}" ;;
    esac
}

# Ids out of specs: "7bfee7e1:fan2@45" → "7bfee7e1:fan2".
_ids() { local s out=""; for s in $1; do out+="${s%@*} "; done; printf '%s' "${out% }"; }
# The @N of ID in a spec list, or nothing.
_n_of() { local s; for s in $2; do [[ "${s%@*}" == "$1" && "$s" == *@* ]] && { printf '%s' "${s##*@}"; return; }; done; }

# Engine rows as picker items. gum's --selected splits on commas, so no item
# text may carry one. Items start with the id and two spaces; _item_id undoes it.
_items() {  # KIND EXCLUDE_IDS — prints one item per line
    local kind="$1" ex=" $2 " id dev label a b c
    engine "$kind" 2>/dev/null | while IFS=$'\t' read -r id dev label a b c; do
        [[ -n "$id" && "$ex" != *" $id "* ]] || continue
        if [[ "$kind" == sensors ]]; then
            [[ "$a" == "-" ]] && continue      # no reading, cannot drive a curve
            printf '%s  %s (%sC) — %s\n' "$id" "$label" "$a" "$dev"
        else
            printf '%s  %s (%s rpm · %s%%) — %s\n' "$id" "$label" "$a" "$b" "$dev"
        fi
    done
}
_item_id() { printf '%s' "${1%%  *}"; }

# _pick_many KIND HEADER PRESELECTED_IDS EXCLUDE_IDS — multi-select; echoes ids.
# The list is the engine's, so it offers what CoolerControl sees and nothing else.
_pick_many() {
    local kind="$1" header="$2" pre=" $3 " ex="$4"
    local -a items=() selected=()
    local item
    while IFS= read -r item; do
        items+=("$item")
        [[ "$pre" == *" $(_item_id "$item") "* ]] && selected+=("$item")
    done < <(_items "$kind" "$ex")
    (( ${#items[@]} )) || { warn "Nothing to choose from."; return 1; }

    local sel picked=""
    sel=$(gum choose "${items[@]}" --no-limit \
            --selected "$(IFS=,; echo "${selected[*]}")" \
            --header "${header} (space toggles, enter confirms)") || return 1
    [[ -n "$sel" ]] || return 1
    while IFS= read -r item; do picked+="$(_item_id "$item") "; done <<< "$sel"
    printf '%s' "${picked% }"
}

NO_PUMP="no AIO pump here (air cooler)"
# Echoes the pump's channel id, "" for none, or returns 1 when cancelled. The
# label is no guide — an MSI board often has the pump on CPU_FAN1 and the
# radiator fans on the "Pump Fan" header — so this always asks.
_pick_pump() {
    local -a items=() first=()
    local item cur; cur="$(_ids "$PINS")"
    while IFS= read -r item; do
        if [[ " $cur " == *" $(_item_id "$item") "* ]]; then first+=("$item"); else items+=("$item"); fi
    done < <(_items channels "")
    local sel
    sel=$(gum choose "${first[@]}" "${items[@]}" "$NO_PUMP" \
            --header "Which header is the AIO pump on? It is held at 100%. Header labels can lie: follow the cable.") || return 1
    [[ -n "$sel" ]] || return 1
    [[ "$sel" == "$NO_PUMP" ]] && return 0
    _item_id "$sel"
}

# -----------------------------------------------------------------------------
# Actions
# -----------------------------------------------------------------------------

action_status() {
    header "Carbonite — Status"
    _need_auth || return 0
    engine status || true
}

action_token() {
    header "Carbonite — Access token"
    info "In CoolerControl: Settings → Access Tokens → create one WITH write access."
    local tok
    tok=$(gum input --password --placeholder "cc_…" --prompt "token > ") || { info "Cancelled."; return 0; }
    [[ -n "$tok" ]] || { info "Cancelled."; return 0; }
    engine login --token "$tok" || true
    _engine_state
}

action_simulate() {
    header "Carbonite — Try a curve"
    local curve
    curve="$(_pick_curve)" || { info "Cancelled."; return 0; }
    local temps
    temps=$(gum input --value "$WALK" --prompt "Temperatures to walk through > ") || { info "Cancelled."; return 0; }
    [[ -n "$temps" ]] || { info "Cancelled."; return 0; }
    info "curve: ${curve}"
    # shellcheck disable=SC2086
    engine simulate --curve "$curve" -- $temps || return 1
}

# The one flow that writes: curve → sensors → pump → fans → floors → confirm.
action_apply() {
    header "Carbonite — Apply a curve"
    _need_auth || return 0

    local curve sensors pump channels
    curve="$(_pick_curve)" || { info "Cancelled."; return 0; }
    info "This curve would do:"
    # shellcheck disable=SC2086
    engine simulate --curve "$curve" -- $WALK || { warn "That curve was rejected — nothing was changed."; return 1; }

    sensors="$(_pick_many sensors "Watch which sensors? The hottest wins" "$SENSORS" "")" \
        || { info "Cancelled."; return 0; }
    pump="$(_pick_pump)" || { info "Cancelled."; return 0; }
    channels="$(_pick_many channels "Which fans follow the curve?" "$(_ids "$CHANNELS")" "$pump")" \
        || { info "Cancelled."; return 0; }

    # Fans that stall below some duty (radiator fans often do) get a floor:
    # they follow the curve but never drop under it.
    local stall="none — they all keep spinning at low speed" floored="" min=""
    local -a fitems=()
    local id item
    while IFS= read -r item; do
        [[ " $channels " == *" $(_item_id "$item") "* ]] && fitems+=("$item")
    done < <(_items channels "$pump")
    local fsel
    fsel=$(gum choose "$stall" "${fitems[@]}" --no-limit \
            --header "Any of these stop spinning at low speed? (radiator fans often do)") \
        || { info "Cancelled."; return 0; }
    if [[ -n "$fsel" && "$fsel" != "$stall"* ]]; then
        while IFS= read -r item; do
            [[ "$item" == "$stall" ]] || floored+="$(_item_id "$item") "
        done <<< "$fsel"
        local cur=""; for id in $floored; do cur="$(_n_of "$id" "$CHANNELS")"; [[ -n "$cur" ]] && break; done
        min=$(gum input --value "${cur:-45}" --prompt "Never below what % (try the lowest where they still start)? > ") \
            || { info "Cancelled."; return 0; }
        [[ "$min" =~ ^[0-9]{1,3}$ ]] && (( min >= 1 && min <= 100 )) \
            || { warn "Not a duty: ${min} — nothing was changed."; return 0; }
    fi

    local specs=""
    for id in $channels; do
        if [[ " $floored " == *" $id "* ]]; then specs+="${id}@${min} "; else specs+="${id} "; fi
    done
    specs="${specs% }"

    local -a args=(apply --curve "$curve" --sensors "$sensors" --channels "$specs")
    [[ -n "$pump" ]] && args+=(--pin "${pump}@100")
    info "pump: ${pump:-none} · curve: ${specs}"
    # A pin from before that is neither the pump now nor on the curve stays
    # pinned — never released by surprise. Said here so it is not a mystery.
    local p
    for p in $(_ids "$PINS"); do
        [[ "$p" == "$pump" || " $channels " == *" $p "* ]] || info "${p} stays pinned — unpin it from the menu if it is no longer the pump."
    done
    _ask "Apply? (fans you leave out go back to the board)" || { info "Cancelled."; return 0; }
    engine "${args[@]}" || true
    _engine_state
}

action_set_curve() {
    header "Carbonite — Change the curve"
    _need_auth || return 0
    (( APPLIED )) || { warn "Nothing applied yet — use 'apply a curve' first."; return 0; }

    local curve
    curve="$(_pick_curve)" || { info "Cancelled."; return 0; }
    [[ "$curve" == "$CURVE" ]] && { info "That is already the applied curve."; return 0; }
    info "This curve would do:"
    # shellcheck disable=SC2086
    engine simulate --curve "$curve" -- $WALK || { warn "That curve was rejected — the applied one is unchanged."; return 1; }
    _ask "Write this curve?" || { info "Cancelled."; return 0; }
    engine set-curve "$curve" || true
    _engine_state
}

action_list() {
    local kind="$1"
    header "Carbonite — ${kind^}"
    _need_auth || return 0
    if [[ "$kind" == sensors ]]; then
        printf '%-20s %-28s %6s  %s\n' "ID" "LABEL" "degC" "WATCHED"
        local id dev label t w
        while IFS=$'\t' read -r id dev label t w; do
            printf '%-20s %-28s %6s  %s\n' "$id" "$label" "$t" "$( (( w )) && echo yes || echo -)"
        done < <(engine sensors 2>/dev/null)
    else
        printf '%-20s %-18s %6s %5s  %s\n' "ID" "LABEL" "RPM" "DUTY" "CONTROL"
        local id dev label rpm duty c
        while IFS=$'\t' read -r id dev label rpm duty c; do
            case "$c" in
                curve:*) c="curve, never below ${c#curve:}%" ;;
                pin:*)   c="pinned at ${c#pin:}%" ;;
                fixed:*) c="fixed ${c#fixed:}% (set elsewhere)" ;;
                -)       c="board" ;;
            esac
            printf '%-20s %-18s %6s %4s%%  %s\n' "$id" "$label" "$rpm" "$duty" "$c"
        done < <(engine channels 2>/dev/null)
    fi
}

action_unpin() {
    header "Carbonite — Unpin a fan"
    _need_auth || return 0
    [[ -n "$PINS" ]] || { info "Nothing is pinned."; return 0; }
    local -a items=()
    local item
    while IFS= read -r item; do
        [[ " $(_ids "$PINS") " == *" $(_item_id "$item") "* ]] && items+=("$item")
    done < <(_items channels "")
    local sel
    sel=$(gum choose "${items[@]}" --header "Hand which pinned fan back to the board?") || { info "Cancelled."; return 0; }
    [[ -n "$sel" ]] || { info "Cancelled."; return 0; }
    local id; id="$(_item_id "$sel")"
    _ask --default=false "Unpin ${id}? If it is the AIO pump, the board decides its speed from now on." \
        || { info "Cancelled."; return 0; }
    engine unpin "$id" --yes || true
    _engine_state
}

action_release() {
    header "Carbonite — Hand the fans back to the board"
    _need_auth || return 0
    (( APPLIED )) || { info "Nothing applied."; return 0; }
    _ask --default=false "Put ${CHANNELS:-the managed fans} back on the BIOS curve and delete the carbonite profiles?${PINS:+ (pinned: ${PINS} — kept)}" \
        || { info "Cancelled."; return 0; }
    engine release --yes || true
    _engine_state
}

# -----------------------------------------------------------------------------
# Menu
# -----------------------------------------------------------------------------

main() {
    resolve_engine
    gum style --foreground "${CYAN:-212}" --border-foreground "${CYAN:-212}" --border double \
        --align center --width 64 --margin "1 2" --padding "1 4" \
        "carbonite" "A fan curve for hwmon fans, kept in CoolerControl"

    _engine_state

    if (( ! REACHABLE )); then
        warn "CoolerControl is not answering at ${URL} — start it: sudo systemctl enable --now coolercontrold"
    elif (( ! AUTHORIZED )); then
        warn "No working access token yet — 'set the access token' first."
    elif (( APPLIED )); then
        info "Applied: ${CURVE} · sensors: ${SENSORS} · fans: ${CHANNELS:-none} · pinned: ${PINS:-none}"
    else
        info "No curve applied — the board is in charge. Default curve: ${DEFAULT_CURVE}"
    fi
    (( CONFLICTS )) && warn "Another service also writes pwm and will fight CoolerControl — see 'status'."

    while true; do
        local action
        action=$(gum choose \
            "status" "try a curve" "apply a curve" "change the curve" \
            "list sensors" "list fans" "unpin a fan" "hand back to the board" "set the access token" "quit" \
            --header "Choose an action:") || true
        [[ -z "$action" || "$action" == "quit" ]] && { gum style --faint "Bye."; exit 0; }

        # || true on each: under `set -e` a failing action would drop back to
        # init.sh's top-level menu, which this loop exists to avoid.
        case "$action" in
            status)                   action_status      || true ;;
            "try a curve")            action_simulate    || true ;;
            "apply a curve")          action_apply       || true ;;
            "change the curve")       action_set_curve   || true ;;
            "list sensors")           action_list sensors  || true ;;
            "list fans")              action_list channels || true ;;
            "unpin a fan")            action_unpin       || true ;;
            "hand back to the board") action_release     || true ;;
            "set the access token")   action_token       || true ;;
        esac

        echo ""
        gum confirm "Back to the menu?" || { gum style --faint "Bye."; exit 0; }
    done
}

main "$@"
