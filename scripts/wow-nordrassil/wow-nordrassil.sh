#!/usr/bin/env bash
# description: Vanilla WoW (VMaNGOS) server — gum front-end for the nordrassil engine
# Standalone export (export.sh): no extra setup deps — git is checked at runtime (engine clone).
# -----------------------------------------------------------------------------
# gum front-end for the standalone, flag-driven `nordrassil` engine (the World
# Tree for a VMaNGOS vanilla WoW server). The real logic — native/Docker/k8s
# builds, DB bootstrap, account/character admin — lives in its own repo as a
# gum-free CLI; this file only resolves that engine, collects options with gum,
# and drives it by flags. Same split as protocol-droid / navicomputer /
# holo-convert / mind-trick / younglings-key.
#
# Named wow-nordrassil (not just "nordrassil") so it sorts next to
# wow-dark-portal (the client front-end) in the launcher.
#
# Engine resolution order:
#   1. $NORDRASSIL_DIR/nordrassil.sh        (explicit override — a checkout you control)
#   2. ../../../nordrassil/nordrassil.sh    (sibling dev checkout next to scomp-link)
#   3. ~/.cache/scomp-link/nordrassil/…     (cached clone; offers git pull)
#   4. git clone --depth 1 (public HTTPS)   (first run)
# -----------------------------------------------------------------------------

if [[ "${BASH_VERSINFO[0]:-0}" -lt 4 ]]; then
    echo "[error] bash 4+ required (you have ${BASH_VERSION}). On macOS: brew install bash" >&2
    exit 1
fi

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -d "${SCRIPT_DIR}/../_common" ]]; then
    COMMON_DIR="${SCRIPT_DIR}/../_common"   # scomp-link repo layout
else
    COMMON_DIR="${SCRIPT_DIR}"              # exported standalone: deps sit alongside
fi

# shellcheck source=../_common/ui.sh
source "${COMMON_DIR}/ui.sh"

command -v gum &>/dev/null || { echo "[error] gum is required. Run setup.sh first." >&2; exit 1; }
command -v git &>/dev/null || { echo "[error] git is required." >&2; exit 1; }

NORDRASSIL_REPO="${NORDRASSIL_REPO:-https://github.com/malahmen/nordrassil.git}"
NORDRASSIL_CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/scomp-link/nordrassil"
ENGINE=""

trap 'echo ""; gum style --faint "Interrupted."; exit 0' INT TERM

resolve_engine() {
    if [[ -n "${NORDRASSIL_DIR:-}" && -f "${NORDRASSIL_DIR}/nordrassil.sh" ]]; then
        ENGINE="${NORDRASSIL_DIR}/nordrassil.sh"; info "Using nordrassil from \$NORDRASSIL_DIR: ${NORDRASSIL_DIR}"; return
    fi
    local sib="${SCRIPT_DIR}/../../../nordrassil/nordrassil.sh"
    if [[ -f "$sib" ]]; then
        ENGINE="$(cd "$(dirname "$sib")" && pwd)/nordrassil.sh"; info "Using local nordrassil checkout: $(dirname "$ENGINE")"; return
    fi
    if [[ -f "${NORDRASSIL_CACHE}/nordrassil.sh" ]]; then
        ENGINE="${NORDRASSIL_CACHE}/nordrassil.sh"; info "Using cached nordrassil: ${NORDRASSIL_CACHE}"
        if [[ -d "${NORDRASSIL_CACHE}/.git" ]] && gum confirm "Update nordrassil (git pull)?"; then
            gum spin --spinner dot --title "Updating nordrassil..." -- git -C "$NORDRASSIL_CACHE" pull --ff-only || warn "Update failed; using existing copy."
        fi
        return
    fi
    gum confirm "nordrassil engine not found. Clone it from ${NORDRASSIL_REPO}?" || error_exit "nordrassil engine is unavailable."
    mkdir -p "$(dirname "$NORDRASSIL_CACHE")"
    gum spin --spinner dot --title "Cloning nordrassil..." -- git clone --depth 1 "$NORDRASSIL_REPO" "$NORDRASSIL_CACHE" \
        || error_exit "Failed to clone nordrassil from ${NORDRASSIL_REPO}"
    ENGINE="${NORDRASSIL_CACHE}/nordrassil.sh"; success "nordrassil cloned to ${NORDRASSIL_CACHE}"
}

# Engine drivers. GLOBAL_FLAGS carries the kube target (--context/--kind) chosen
# for a deploy action; it precedes the subcommand. engine_foreground runs
# long-lived/streaming work (builds, deploys) so Ctrl-C stops just the child.
GLOBAL_FLAGS=()
engine()     { bash "$ENGINE" "${GLOBAL_FLAGS[@]}" "$@"; }
eget()       { bash "$ENGINE" get "$1" 2>/dev/null || true; }
engine_foreground() {
    trap ':' INT
    bash "$ENGINE" "${GLOBAL_FLAGS[@]}" "$@" || true
    trap 'echo ""; gum style --faint "Interrupted."; exit 0' INT TERM
}

# -----------------------------------------------------------------------------
# gum pickers — all interactivity lives here; each pushes its answer into the
# engine's config store with `set`, or echoes a value for the caller to use.
# -----------------------------------------------------------------------------

# _pick_value_label <header> <current-value> <default-label-on-cancel> "value|Label" ...
# Presents labels via gum choose, echoes the matching value on stdout.
_pick_value_label() {
    local hdr="$1" current="$2" fallback_label="$3"; shift 3
    local -a values=() labels=()
    local pair
    for pair in "$@"; do
        values+=("${pair%%|*}")
        labels+=("${pair#*|}")
    done

    local current_label="$fallback_label" i
    for i in "${!values[@]}"; do
        [[ "${values[$i]}" == "$current" ]] && current_label="${labels[$i]}"
    done

    local chosen
    chosen=$(printf '%s\n' "${labels[@]}" | gum choose --header "${hdr} (current: ${current_label}):") || true
    [[ -z "$chosen" ]] && { echo "$current"; return; }

    for i in "${!labels[@]}"; do
        [[ "${labels[$i]}" == "$chosen" ]] && { echo "${values[$i]}"; return; }
    done
    echo "$current"
}

# Account security level, matching src/shared/Common.h's AccountTypes enum.
_pick_gm_level() {
    local hdr="$1" current="$2"
    _pick_value_label "$hdr" "$current" "Player" \
        "0|Player (no GM powers)" "1|Moderator" "2|Ticketmaster" "3|Gamemaster" \
        "4|Basic Admin" "5|Developer" "6|Administrator (full GM access)"
}

# Collects every server-identity/gameplay/security setting and persists each
# into the engine's config store. Pre-fills from the engine's effective values
# (config value or its default), so re-running only tweaks what changed.
_prompt_server_settings() {
    local v

    v=$(gum input --value "$(eget REALM_NAME)" --header "Realm name (shown in the realm list):") || true
    [[ -n "$v" ]] && engine set REALM_NAME "$v"

    v=$(_pick_value_label "Realm zone (character-name alphabet / client compatibility)" "$(eget REALM_ZONE)" "Development" \
        "1|Development (any language)" "2|United States" "3|Oceanic" "4|Latin America" \
        "6|Korea" "8|English" "9|German" "10|French" "11|Spanish" "12|Russian" \
        "14|Taiwan" "16|China" "26|Test Server" "28|QA Server")
    engine set REALM_ZONE "$v"

    v=$(_pick_value_label "Realm style" "$(eget GAME_TYPE)" "Normal" \
        "0|Normal" "1|PvP" "6|RP" "8|RP-PvP" "16|FFA PvP (custom — arena rules everywhere)")
    engine set GAME_TYPE "$v"

    v=$(gum input --value "$(eget PLAYER_LIMIT)" \
        --header "Player limit (0 = infinite, -1 = mods/GMs/admins only, -2 = GMs/admins only, -3 = admins only):") || true
    [[ -n "$v" ]] && engine set PLAYER_LIMIT "$v"

    v=$(_pick_value_label "Progression content patch (quest/NPC/dungeon/raid data — independent of the compiled client build)" "$(eget WOW_PATCH)" "1.12" \
        "0|1.2" "1|1.3" "2|1.4" "3|1.5" "4|1.6" "5|1.7" "6|1.8" "7|1.9" "8|1.10" "9|1.11" "10|1.12")
    engine set WOW_PATCH "$v"

    # MOTD — strip literal quotes so it can't break the conf file's own quoting.
    v=$(gum input --value "$(eget MOTD)" --header "Message of the day (shown at login):") || true
    [[ -n "$v" ]] && engine set MOTD "${v//\"/}"

    v=$(gum input --value "$(eget XP_RATE)" --header "XP rate multiplier (1 = normal, 2 = double, 0.5 = half):") || true
    [[ -n "$v" ]] && engine set XP_RATE "$v"

    v=$(gum input --value "$(eget DROP_RATE)" --header "Loot/gold drop rate multiplier (1 = normal, 2 = double, 0.5 = half):") || true
    [[ -n "$v" ]] && engine set DROP_RATE "$v"

    # realmd.conf — login/security behavior.
    v=$(gum input --value "$(eget WRONG_PASS_MAX_COUNT)" \
        --header "Wrong-password attempts before a ban (0 = disabled):") || true
    [[ -n "$v" ]] && engine set WRONG_PASS_MAX_COUNT "$v"

    if [[ "$(eget WRONG_PASS_MAX_COUNT)" != "0" ]]; then
        v=$(gum input --value "$(eget WRONG_PASS_BAN_TIME)" --header "Ban duration in seconds:") || true
        [[ -n "$v" ]] && engine set WRONG_PASS_BAN_TIME "$v"

        v=$(_pick_value_label "Ban target" "$(eget WRONG_PASS_BAN_TYPE)" "Ban IP" "0|Ban IP" "1|Ban Account")
        engine set WRONG_PASS_BAN_TYPE "$v"
    fi

    v=$(_pick_value_label "Require email verification before login" "$(eget REQ_EMAIL_VERIFICATION)" "No" "0|No" "1|Yes")
    engine set REQ_EMAIL_VERIFICATION "$v"

    v=$(_pick_value_label "Reject modified/mismatched game clients (strict version check)" "$(eget STRICT_VERSION_CHECK)" "Yes" "1|Yes" "0|No")
    engine set STRICT_VERSION_CHECK "$v"

    v=$(_pick_value_label "Warden anti-cheat (client-side scans; irrelevant on a private/trusted LAN server)" "$(eget WARDEN_ENABLED)" "Enabled" "1|Enabled" "0|Disabled")
    engine set WARDEN_ENABLED "$v"

    v=$(_pick_value_label "Strict player names (character-set + profanity/reserved-name checks on every login)" "$(eget STRICT_PLAYER_NAMES)" "Disabled" \
        "0|Disabled" "1|Basic Latin only" "2|Realm zone specific" "3|Basic Latin + server timezone")
    engine set STRICT_PLAYER_NAMES "$v"
}

# Kube target for the deploy actions → sets GLOBAL_FLAGS (--kind/--context/none).
_prompt_kube_target() {
    GLOBAL_FLAGS=()
    local choice
    choice=$(gum choose "Current kube-context" "A kind cluster" "A named kube-context" \
        --header "Which Kubernetes target?") || return 1
    case "$choice" in
        "A kind cluster")
            local clusters cluster
            clusters=$(kind get clusters 2>/dev/null || true)
            if [[ -n "$clusters" ]]; then
                cluster=$(printf '%s\n' "$clusters" | gum choose --header "kind cluster:") || return 1
            else
                cluster=$(gum input --placeholder "cluster name" --header "kind cluster name:") || return 1
            fi
            [[ -n "$cluster" ]] || return 1
            GLOBAL_FLAGS=(--kind "$cluster")
            ;;
        "A named kube-context")
            local ctx
            ctx=$(gum input --placeholder "context name" --header "kube-context:") || return 1
            [[ -n "$ctx" ]] || return 1
            GLOBAL_FLAGS=(--context "$ctx")
            ;;
        *) GLOBAL_FLAGS=() ;;   # current context
    esac
}

# -----------------------------------------------------------------------------
# Actions — collect with gum, run the engine by flags.
# -----------------------------------------------------------------------------

action_configure() {
    header "nordrassil — Configure"
    local src
    src=$(gum input --value "$(eget SOURCE_DIR)" --header "Path to the repack (contains mangosd.conf, sql/, data/):") || return 0
    [[ -n "$src" ]] && engine set SOURCE_DIR "$src"

    local addr
    addr=$(gum input --value "$(eget REALM_ADDRESS)" \
        --header "LAN-reachable address for this realm (what WoW clients connect to after login):") || return 0
    [[ -n "$addr" ]] && engine set REALM_ADDRESS "$addr"

    _prompt_server_settings

    # Optional custom SQL — list what the engine sees under sql/Custom and let
    # the operator pick; the engine skips any already applied on a re-run.
    local custom=""
    local -a avail=()
    while IFS= read -r line; do [[ -n "$line" ]] && avail+=("$line"); done < <(engine list-custom 2>/dev/null | grep -vE '^\[' || true)
    if [[ ${#avail[@]} -gt 0 ]]; then
        local -a picked=()
        while IFS= read -r line; do [[ -n "$line" ]] && picked+=("$line"); done < <(
            printf '%s\n' "${avail[@]}" | gum choose --no-limit \
                --header "Optional custom content — space to select, enter to apply only what's checked:" || true)
        [[ ${#picked[@]} -gt 0 ]] && custom="$(IFS=,; echo "${picked[*]}")"
    fi

    if [[ -n "$custom" ]]; then
        engine_foreground configure --custom "$custom"
    else
        engine_foreground configure
    fi
}

action_edit() {
    local file
    file=$(gum choose "mangosd (server settings, rates, MOTD, ...)" "realmd (login/security settings)" "cancel" \
        --header "Which conf file to edit?") || return 0
    case "$file" in
        mangosd*) engine edit --file mangosd ;;
        realmd*)  engine edit --file realmd ;;
        *) info "Cancelled." ;;
    esac
}

action_run_docker() {
    header "nordrassil — Run (Docker, LAN)"
    if gum confirm "Recreate the server container if it already exists?"; then
        engine_foreground run-docker --force
    else
        engine_foreground run-docker
    fi
}

action_run_k8s() {
    header "nordrassil — Run (Kubernetes, LAN via hostNetwork)"
    _prompt_kube_target || { info "Cancelled."; return 0; }

    local ns addr
    ns=$(gum input --value "$(eget K8S_NAMESPACE)" --header "Kubernetes namespace:") || return 0
    addr=$(gum input --value "$(eget REALM_ADDRESS)" \
        --header "LAN-reachable address for this realm (the k8s NODE's IP, since the pod uses hostNetwork):") || return 0

    # Storage backend → persisted config the engine reads on run-k8s.
    local st
    st=$(_pick_value_label "Storage backend for game data + DB" "$(eget K8S_STORAGE_TYPE)" "hostPath" \
        "hostpath|hostPath (single-node / home-lab — path on the node)" \
        "storageclass|StorageClass (dynamic provisioning)")
    engine set K8S_STORAGE_TYPE "$st"
    if [[ "$st" == "hostpath" ]]; then
        local dp bp
        dp=$(gum input --value "$(eget K8S_DATA_HOSTPATH)" --header "hostPath for game data (on the k8s node):") || return 0
        [[ -n "$dp" ]] && engine set K8S_DATA_HOSTPATH "$dp"
        bp=$(gum input --value "$(eget K8S_DB_HOSTPATH)" --header "hostPath for MariaDB data (on the k8s node):") || return 0
        [[ -n "$bp" ]] && engine set K8S_DB_HOSTPATH "$bp"
    else
        local sc
        sc=$(gum input --value "$(eget K8S_STORAGECLASS)" --placeholder "leave empty for cluster default" --header "StorageClass name:") || true
        engine set K8S_STORAGECLASS "$sc"
    fi

    local -a args=(run-k8s)
    [[ -n "$ns" ]]   && args+=(--namespace "$ns")
    [[ -n "$addr" ]] && args+=(--address "$addr")
    engine_foreground "${args[@]}"
}

action_stop_k8s() {
    _prompt_kube_target || { info "Cancelled."; return 0; }
    engine_foreground stop-k8s
}

action_create_account() {
    header "nordrassil — Create account"
    local name pass level
    name=$(gum input --placeholder "username" --header "New account username:") || return 0
    [[ -n "$name" ]] || { info "Cancelled."; return 0; }
    pass=$(gum input --password --placeholder "password" --header "New account password:") || return 0
    [[ -n "$pass" ]] || { info "Cancelled."; return 0; }
    level=$(_pick_gm_level "Account access level" "0")
    engine create-account --name "$name" --pass "$pass" --level "$level"
}

action_delete_account() {
    header "nordrassil — Delete account"
    engine list-accounts || true
    echo ""
    local name
    name=$(gum input --placeholder "username" --header "Account to delete:") || return 0
    [[ -n "$name" ]] || { info "Cancelled."; return 0; }
    gum confirm "Delete account '${name}'? This also removes its characters." || { info "Cancelled."; return 0; }
    engine delete-account --name "$name"
}

action_set_account_level() {
    header "nordrassil — Set account level"
    engine list-accounts || true
    echo ""
    local name level
    name=$(gum input --placeholder "username" --header "Account to change:") || return 0
    [[ -n "$name" ]] || { info "Cancelled."; return 0; }
    level=$(_pick_gm_level "New access level" "0")
    engine set-account-level --name "$name" --level "$level"
}

action_rename_character() {
    header "nordrassil — Rename character"
    local from to
    from=$(gum input --placeholder "current name" --header "Character to rename (use 'Search' to find one):") || return 0
    [[ -n "$from" ]] || { info "Cancelled."; return 0; }
    to=$(gum input --placeholder "new name" --header "New name for '${from}' (up to 12 characters, bypasses normal naming rules):") || return 0
    [[ -n "$to" ]] || { info "Cancelled."; return 0; }
    engine rename-character --from "$from" --to "$to"
}

action_search() {
    header "nordrassil — Search"
    local label kind term
    label=$(gum choose "Items" "NPCs" "Teleport locations" "Player characters" --header "Search what?") || return 0
    case "$label" in
        Items)                kind="items" ;;
        NPCs)                 kind="npcs" ;;
        "Teleport locations") kind="teleports" ;;
        "Player characters")  kind="characters" ;;
        *) info "Cancelled."; return 0 ;;
    esac
    term=$(gum input --placeholder "name (partial match)" --header "Search term:") || return 0
    [[ -n "$term" ]] || { info "Cancelled."; return 0; }
    engine search --kind "$kind" --term "$term"
}

# -----------------------------------------------------------------------------
# Menus — mirror the original category layout.
# -----------------------------------------------------------------------------

_submenu() {
    local title="$1"; shift
    local -a opts=("$@")
    while true; do
        header "Vanilla WoW — ${title}"
        local action
        action=$(printf '%s\n' "${opts[@]}" "back" | gum choose --header "Choose an action:") || true
        [[ -z "$action" || "$action" == "back" ]] && return
        GLOBAL_FLAGS=()   # only the k8s actions repopulate this (a kube target)
        case "$action" in
            install-deps)      engine_foreground install-deps ;;
            configure)         action_configure || true ;;
            edit)              action_edit || true ;;
            start)             engine_foreground start ;;
            stop)              engine_foreground stop ;;
            build-image)       engine_foreground build-image ;;
            run-docker)        action_run_docker || true ;;
            stop-docker)       engine_foreground stop-docker ;;
            run-k8s)           action_run_k8s || true ;;
            stop-k8s)          action_stop_k8s || true ;;
            create-account)    action_create_account || true ;;
            list-accounts)     engine list-accounts || true ;;
            delete-account)    action_delete_account || true ;;
            set-account-level) action_set_account_level || true ;;
            rename-character)  action_rename_character || true ;;
        esac
        echo ""
    done
}

main() {
    resolve_engine
    gum style --foreground "$CYAN" --border-foreground "$CYAN" --border double \
        --align center --width 60 --margin "1 2" --padding "1 4" \
        "nordrassil" "vanilla WoW (VMaNGOS) server — the World Tree"
    while true; do
        local category
        category=$(gum choose "Setup" "Local" "Deploy" "Accounts" "Characters" "Search" "Status" "Quit" \
            --header "Choose a category:") || true
        [[ -z "$category" || "$category" == "Quit" ]] && { gum style --faint "Bye."; exit 0; }
        case "$category" in
            Setup)      _submenu "Setup"      install-deps configure edit ;;
            Local)      _submenu "Local"      start stop ;;
            Deploy)     _submenu "Deploy"     build-image run-docker stop-docker run-k8s stop-k8s ;;
            Accounts)   _submenu "Accounts"   create-account list-accounts delete-account set-account-level ;;
            Characters) _submenu "Characters" rename-character ;;
            Search)     action_search || true ;;
            Status)     engine status || true ;;
        esac
    done
}

main "$@"
