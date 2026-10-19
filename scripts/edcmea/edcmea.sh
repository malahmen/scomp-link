#!/usr/bin/env bash
# description: Elite Dangerous market alerts - watch rules, email through pop, run on a schedule
# -----------------------------------------------------------------------------
# Front-end for the EDCMEA engine (Elite Dangerous Commodity Market Email
# Alert, https://github.com/malahmen/EDCMEA): a Python CLI made for cron that
# watches commodity markets (Ardent Insight's data) and emails through Charm's
# pop. Everything the engine does is reachable here, and the schedule too: a
# systemd user timer where systemd runs the user's session, a crontab line
# anywhere else.
#
# Engine resolution order:
#   1. $EDCMEA_DIR/edcmea.sh              (explicit override)
#   2. ../../../EDCMEA/edcmea.sh          (sibling checkout next to scomp-link)
#   3. ~/.cache/scomp-link/edcmea/...     (cached clone; offers git pull)
#   4. git clone --depth 1                (first run)
#
# Secrets (an SMTP password, a Resend key) go to the engine on stdin, never as
# an argument: they would show in every process listing while it runs.
# -----------------------------------------------------------------------------

if [[ "${BASH_VERSINFO[0]:-0}" -lt 4 ]]; then
    echo "[error] bash 4+ required (you have ${BASH_VERSION}). On macOS: brew install bash" >&2
    exit 1
fi

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -d "${SCRIPT_DIR}/../_common" ]]; then
    COMMON_DIR="${SCRIPT_DIR}/../_common"
else
    COMMON_DIR="${SCRIPT_DIR}"
fi
# shellcheck source=../_common/ui.sh
source "${COMMON_DIR}/ui.sh"

command -v gum &>/dev/null || { echo "[error] gum is required. Run setup.sh first." >&2; exit 1; }

EDCMEA_REPO="${EDCMEA_REPO:-https://github.com/malahmen/EDCMEA.git}"
EDCMEA_CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/scomp-link/edcmea"
ENGINE=""

# The schedule: a systemd user timer, or a crontab line carrying this marker.
UNIT_DIR="${SCOMP_EDCMEA_UNIT_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user}"
UNIT="edcmea-check"
CRON_MARK="# edcmea (scomp-link)"
LOG_FILE="${XDG_STATE_HOME:-$HOME/.local/state}/edcmea/check.log"

trap 'echo ""; gum style --faint "Interrupted."; exit 0' INT TERM

resolve_engine() {
    if [[ -n "${EDCMEA_DIR:-}" && -f "${EDCMEA_DIR}/edcmea.sh" ]]; then
        ENGINE="${EDCMEA_DIR}/edcmea.sh"; info "Using EDCMEA from \$EDCMEA_DIR: ${EDCMEA_DIR}"; return
    fi
    local sib="${SCRIPT_DIR}/../../../EDCMEA/edcmea.sh"
    if [[ -f "$sib" ]]; then
        ENGINE="$(cd "$(dirname "$sib")" && pwd)/edcmea.sh"; info "Using local EDCMEA checkout: $(dirname "$ENGINE")"; return
    fi
    if [[ -f "${EDCMEA_CACHE}/edcmea.sh" ]]; then
        ENGINE="${EDCMEA_CACHE}/edcmea.sh"; info "Using cached EDCMEA: ${EDCMEA_CACHE}"
        if [[ -d "${EDCMEA_CACHE}/.git" ]] && command -v git &>/dev/null && gum confirm "Update EDCMEA (git pull)?"; then
            gum spin --spinner dot --title "Updating EDCMEA..." -- git -C "$EDCMEA_CACHE" pull --ff-only || warn "Update failed; using the existing copy."
        fi
        return
    fi
    need_git "to fetch the EDCMEA engine"
    gum confirm "EDCMEA engine not found. Clone it from ${EDCMEA_REPO}?" || error_exit "EDCMEA engine is unavailable."
    mkdir -p "$(dirname "$EDCMEA_CACHE")"
    gum spin --spinner dot --title "Cloning EDCMEA..." -- git clone --depth 1 "$EDCMEA_REPO" "$EDCMEA_CACHE" \
        || error_exit "Failed to clone EDCMEA from ${EDCMEA_REPO}"
    ENGINE="${EDCMEA_CACHE}/edcmea.sh"; success "EDCMEA cloned to ${EDCMEA_CACHE}"
}

engine() { bash "$ENGINE" "$@"; }

# The engine's `config` as KEY=value; cfg KEY reads one.
CONFIG=""
load_config() { CONFIG="$(engine config 2>/dev/null || true)"; }
cfg() { sed -n "s/^$1=//p" <<< "$CONFIG" | head -1; }

# _ask PROMPT -> 0 yes, 1 no, 2 cancelled (Esc)
_ask() {
    local rc=0
    gum confirm "$@" || rc=$?
    case "$rc" in 0) return 0 ;; 130) return 2 ;; *) return 1 ;; esac
}

# -----------------------------------------------------------------------------
# Rules
# -----------------------------------------------------------------------------
action_rules_list() {
    header "EDCMEA - watch rules"
    engine rules list || true
}

action_rules_add() {
    header "EDCMEA - add a watch rule"
    local search found commodity name price
    search=$(gum input --header "Commodity (part of its name, e.g. diamond, painite):") || return 0
    [[ -n "$search" ]] || return 0
    found="$(engine commodities "$search" 2>/dev/null || true)"
    [[ -n "$found" ]] || { warn "No commodity matching '${search}' on Ardent."; return 0; }
    commodity=$(cut -f1 <<< "$found" | gum choose --header "Which one?") || return 0
    [[ -n "$commodity" ]] || return 0
    price=$(gum input --header "Alert at this sell price (credits) or more:" --placeholder "600000") || return 0
    [[ "$price" =~ ^[0-9]+$ ]] && (( price > 0 )) || { warn "Not a price: ${price}"; return 0; }
    name=$(gum input --header "A short name for the rule (a-z 0-9 _ -):" --value "${commodity:0:20}") || return 0

    local -a args=(rules add "$name" "$commodity" "$price")
    local pad near ly ls demand age
    pad=$(gum choose "any" "S" "M" "L" --header "Landing pad your ship needs:") || return 0
    [[ "$pad" == any || -z "$pad" ]] || args+=(--pad "$pad")
    demand=$(gum input --header "Minimum demand (blank = any):") || return 0
    [[ -z "$demand" ]] || args+=(--min-demand "$demand")
    age=$(gum input --header "Ignore market data older than how many days? (blank = any):") || return 0
    [[ -z "$age" ]] || args+=(--max-age-days "$age")
    near=$(gum input --header "Only near a system? Its name (blank = anywhere):") || return 0
    if [[ -n "$near" ]]; then
        ly=$(gum input --header "Within how many light years of ${near}?" --placeholder "200") || return 0
        args+=(--near "$near" --max-ly "$ly")
    fi
    ls=$(gum input --header "At most how many ls from the arrival star? (blank = any):") || return 0
    [[ -z "$ls" ]] || args+=(--max-arrival-ls "$ls")
    if _ask "Include fleet carriers? (their prices are often bait)" --default=false; then
        args+=(--carriers)
    fi
    engine "${args[@]}" || true
}

action_rules_remove() {
    header "EDCMEA - remove a watch rule"
    local names name
    names="$(engine rules list 2>/dev/null | grep -v '^no rules' | cut -f1 || true)"
    [[ -n "$names" ]] || { info "No rules yet."; return 0; }
    name=$(gum choose --header "Remove which rule?" <<< "$names") || return 0
    [[ -n "$name" ]] || return 0
    _ask "Remove '${name}'?" || return 0
    engine rules remove "$name" || true
}

# -----------------------------------------------------------------------------
# Email (pop)
# -----------------------------------------------------------------------------
pop_set() {   # pop_set KEY [--secret] - the value goes to the engine on stdin
    local key="$1" value
    if [[ "${2:-}" == --secret ]]; then
        value=$(gum input --password --header "${key} (hidden; blank removes it):") || return 0
    else
        value=$(gum input --header "${key} (blank removes it):") || return 0
    fi
    printf '%s\n' "$value" | engine pop-env "$key" || true
}

action_email() {
    header "EDCMEA - email"
    command -v pop &>/dev/null || warn "pop is not installed here: brew install pop, or see https://github.com/charmbracelet/pop"
    local to choice
    load_config
    to="$(cfg email_to)"
    info "Alerts go to: ${to:-nobody yet}    pop settings set: $(cfg pop_env)"
    choice=$(gum choose \
        "recipient - who gets the alerts" \
        "copy pop's settings from this shell (POP_*, RESEND_API_KEY)" \
        "sender (POP_FROM)" \
        "Resend API key" \
        "SMTP server (host, port, user, password, encryption)" \
        "send a test email" \
        "← back" --header "Email:") || return 0
    case "$choice" in
        recipient*)
            to=$(gum input --header "Send alerts to:" --value "$to") || return 0
            [[ -n "$to" ]] && { engine set email_to "$to" || true; } ;;
        copy*)        engine pop-env --import || true ;;
        sender*)      pop_set POP_FROM ;;
        "Resend API key") pop_set RESEND_API_KEY --secret ;;
        SMTP*)
            pop_set POP_SMTP_HOST
            pop_set POP_SMTP_PORT
            pop_set POP_SMTP_USERNAME
            pop_set POP_SMTP_PASSWORD --secret
            local enc
            enc=$(gum choose "starttls" "ssl" "none" "(leave as it is)" --header "SMTP encryption:") || return 0
            [[ "$enc" == "(leave as it is)" || -z "$enc" ]] || { printf '%s\n' "$enc" | engine pop-env POP_SMTP_ENCRYPTION || true; } ;;
        "send a test email") engine notify-test || true ;;
        *) return 0 ;;
    esac
}

# -----------------------------------------------------------------------------
# Settings
# -----------------------------------------------------------------------------
action_settings() {
    header "EDCMEA - settings"
    load_config
    local key value
    key=$(gum choose \
        "realert_increase_percent" "cooldown_hours" "matches_in_alert" "← back" \
        --header "Change (the same best station is mailed again after a price rise or the cooldown):") || return 0
    [[ "$key" == "← back" || -z "$key" ]] && return 0
    value=$(gum input --header "${key}:" --value "$(cfg "$key")") || return 0
    [[ -n "$value" ]] && { engine set "$key" "$value" || true; }
}

# -----------------------------------------------------------------------------
# Schedule
# -----------------------------------------------------------------------------
_use_systemd() { [[ "$(uname -s)" == Linux ]] && command -v systemctl &>/dev/null && systemctl --user show-environment &>/dev/null; }

schedule_state() {
    if _use_systemd; then
        if [[ -f "${UNIT_DIR}/${UNIT}.timer" ]]; then
            echo "systemd timer $(systemctl --user is-active "${UNIT}.timer" 2>/dev/null || true), $(sed -n 's/^OnCalendar=//p' "${UNIT_DIR}/${UNIT}.timer")"
        else
            echo "not scheduled"
        fi
    else
        local line; line="$(crontab -l 2>/dev/null | grep -F "$CRON_MARK" || true)"
        [[ -n "$line" ]] && echo "crontab: ${line%% /*}" || echo "not scheduled"
    fi
}

render_service() {
    cat <<EOF
# Written by scomp-link's edcmea.sh - changed by its schedule action.
[Unit]
Description=EDCMEA: check Elite Dangerous markets once

[Service]
Type=oneshot
ExecStart=${ENGINE} check
EOF
}

render_timer() {   # render_timer MINUTES
    cat <<EOF
# Written by scomp-link's edcmea.sh - changed by its schedule action.
[Unit]
Description=EDCMEA: check Elite Dangerous markets every $1 minutes

[Timer]
OnCalendar=*:0/$1
Persistent=true
RandomizedDelaySec=30

[Install]
WantedBy=timers.target
EOF
}

schedule_install() {   # schedule_install MINUTES
    local every="$1"
    if _use_systemd; then
        mkdir -p "$UNIT_DIR"
        render_service > "${UNIT_DIR}/${UNIT}.service"
        render_timer "$every" > "${UNIT_DIR}/${UNIT}.timer"
        systemctl --user daemon-reload
        systemctl --user enable --now "${UNIT}.timer" || { warn "Could not start the timer."; return 1; }
        success "Every ${every} minutes (systemd user timer). Logs: journalctl --user -u ${UNIT}"
    else
        mkdir -p "$(dirname "$LOG_FILE")"
        local line="*/${every} * * * * ${ENGINE} check >> ${LOG_FILE} 2>&1 ${CRON_MARK}" current
        # Read whole before writing: the user's own lines must survive.
        current="$(crontab -l 2>/dev/null | grep -vF "$CRON_MARK" || true)"
        { [[ -z "$current" ]] || printf '%s\n' "$current"; echo "$line"; } | crontab - \
            || { warn "Could not write the crontab."; return 1; }
        success "Every ${every} minutes (crontab). Log: ${LOG_FILE}"
    fi
}

schedule_remove() {
    if _use_systemd; then
        systemctl --user disable --now "${UNIT}.timer" 2>/dev/null || true
        rm -f "${UNIT_DIR}/${UNIT}.service" "${UNIT_DIR}/${UNIT}.timer"
        systemctl --user daemon-reload || true
    else
        local current
        current="$(crontab -l 2>/dev/null | grep -vF "$CRON_MARK" || true)"
        { [[ -z "$current" ]] || printf '%s\n' "$current"; } | crontab - || { warn "Could not write the crontab."; return 1; }
    fi
    success "No longer scheduled."
}

action_schedule() {
    header "EDCMEA - schedule"
    info "Now: $(schedule_state)"
    local choice every
    choice=$(gum choose "run it every few minutes" "stop running it" "← back" --header "Schedule:") || return 0
    case "$choice" in
        run*)
            load_config
            [[ "$(cfg rules)" != 0 ]] || { warn "No watch rules yet - add one first."; return 0; }
            [[ -n "$(cfg email_to)" ]] || { warn "No recipient yet - set one under Email first."; return 0; }
            every=$(gum choose 5 10 15 30 60 --header "Every how many minutes?" --selected 10) || return 0
            [[ -n "$every" ]] && schedule_install "$every" ;;
        stop*) schedule_remove ;;
        *) return 0 ;;
    esac
}

# -----------------------------------------------------------------------------
# Status
# -----------------------------------------------------------------------------
action_status() {
    header "EDCMEA - status"
    load_config
    gum style --border rounded --padding "0 2" \
        "Rules:     $(cfg rules)" \
        "Alerts to: $(cfg email_to)" \
        "pop:       $(cfg pop) - settings: $(cfg pop_env)" \
        "Schedule:  $(schedule_state)" \
        "Config:    $(cfg config_file)"
    engine status || true
}

main() {
    resolve_engine
    gum style --foreground "$CYAN" --border-foreground "$CYAN" --border double \
        --align center --width 60 --margin "1 2" --padding "1 4" \
        "EDCMEA" "Elite Dangerous commodity market alerts"
    while true; do
        case "$(gum choose "check now" "dry run - what would be sent" "list rules" "add a rule" "remove a rule" \
                "email" "settings" "schedule" "status" "Quit" --header "What would you like to do?")" in
            "check now")   header "EDCMEA - check"; engine check || true ;;
            "dry run"*)    header "EDCMEA - dry run"; engine check --dry-run || true ;;
            "list rules")  action_rules_list ;;
            "add a rule")  action_rules_add ;;
            "remove a rule") action_rules_remove ;;
            email)         action_email ;;
            settings)      action_settings ;;
            schedule)      action_schedule ;;
            status)        action_status ;;
            "Quit"|"")     gum style --faint "Bye."; exit 0 ;;
        esac
        echo ""
    done
}

main "$@"
