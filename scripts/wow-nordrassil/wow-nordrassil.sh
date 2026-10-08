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

# $NORDRASSIL_PROFILE is read by the ENGINE at its own startup, so an exported
# one silently applied to every call made here — including the ones made after
# picking "base config (no profile)", which passes no --profile and so left the
# engine falling back to the environment. The menu then said "base config"
# while the actions ran against a server.
#
# Taken once as this session's starting point and then cleared, so PROFILE_FLAGS
# is the only thing that decides. Done by clearing the variable rather than by
# passing the engine's --no-profile: the engine may be an older cached clone
# (see resolve_engine), and a flag it does not know would break every action.
INITIAL_PROFILE="${NORDRASSIL_PROFILE:-}"
unset NORDRASSIL_PROFILE

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
# for a deploy action; it precedes the subcommand.
#
# engine: only for calls whose stdout is captured and whose exit status the
# caller inspects itself (`list-custom`). Every action a menu runs goes through
# engine_foreground instead: under `set -e` a bare `engine` that exits non-zero
# (a rejected setting, a failed deploy, an unreachable DB) or a Ctrl-C (our INT
# trap is `exit 0`) would end the whole TUI, while an error or an interrupt has
# to leave the operator back in the menu.
GLOBAL_FLAGS=()

# PROFILE_FLAGS is separate from GLOBAL_FLAGS on purpose: _submenu clears
# GLOBAL_FLAGS before every action (it only ever holds a kube target for one
# deploy call), and the chosen server has to survive that.
PROFILE=""
PROFILE_FLAGS=()
PROFILE_LABEL="base config"
MANAGED=0

_set_profile() {
    PROFILE="$1"
    if [[ -n "$PROFILE" ]]; then
        PROFILE_FLAGS=(--profile "$PROFILE")
        PROFILE_LABEL="$PROFILE"
    else
        PROFILE_FLAGS=()
        PROFILE_LABEL="base config"
    fi
    # Read only after PROFILE_FLAGS is set, or eget answers from the wrong
    # layer and the menu would offer provisioning actions the engine then
    # refuses — or worse, hide them for a profile that does own its server.
    MANAGED="$(eget MANAGED_EXTERNALLY)"
    [[ "$MANAGED" == "1" ]] || MANAGED=0
    [[ "$MANAGED" == "1" ]] && PROFILE_LABEL+=" · managed elsewhere"
}

engine()     { bash "$ENGINE" "${PROFILE_FLAGS[@]}" "${GLOBAL_FLAGS[@]}" "$@"; }
# eget MUST carry the profile too. Without it every prompt below would
# pre-fill from the base config while the action it then runs uses the
# profile — the settings wizard would quietly show one server's values and
# write them onto another.
eget()       { bash "$ENGINE" "${PROFILE_FLAGS[@]}" get "$1" 2>/dev/null || true; }
engine_foreground() {
    trap ':' INT
    bash "$ENGINE" "${PROFILE_FLAGS[@]}" "${GLOBAL_FLAGS[@]}" "$@" || true
    trap 'echo ""; gum style --faint "Interrupted."; exit 0' INT TERM
}

# _engine_profiles — profile names, one per line. The engine prints these on
# stdout and every diagnostic on stderr, so this needs no filtering.
_engine_profiles() {
    bash "$ENGINE" profiles 2>/dev/null | sed -E 's/^[*[:space:]]+//' | grep -v '^$' || true
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
    [[ -n "$v" ]] && engine_foreground set REALM_NAME "$v"

    v=$(_pick_value_label "Realm zone (character-name alphabet / client compatibility)" "$(eget REALM_ZONE)" "Development" \
        "1|Development (any language)" "2|United States" "3|Oceanic" "4|Latin America" \
        "6|Korea" "8|English" "9|German" "10|French" "11|Spanish" "12|Russian" \
        "14|Taiwan" "16|China" "26|Test Server" "28|QA Server")
    engine_foreground set REALM_ZONE "$v"

    v=$(_pick_value_label "Realm style" "$(eget GAME_TYPE)" "Normal" \
        "0|Normal" "1|PvP" "6|RP" "8|RP-PvP" "16|FFA PvP (custom — arena rules everywhere)")
    engine_foreground set GAME_TYPE "$v"

    v=$(gum input --value "$(eget PLAYER_LIMIT)" \
        --header "Player limit (0 = infinite, -1 = mods/GMs/admins only, -2 = GMs/admins only, -3 = admins only):") || true
    [[ -n "$v" ]] && engine_foreground set PLAYER_LIMIT "$v"

    v=$(_pick_value_label "Progression content patch (quest/NPC/dungeon/raid data — independent of the compiled client build)" "$(eget WOW_PATCH)" "1.12" \
        "0|1.2" "1|1.3" "2|1.4" "3|1.5" "4|1.6" "5|1.7" "6|1.8" "7|1.9" "8|1.10" "9|1.11" "10|1.12")
    engine_foreground set WOW_PATCH "$v"

    # MOTD — strip literal quotes so it can't break the conf file's own quoting.
    v=$(gum input --value "$(eget MOTD)" --header "Message of the day (shown at login):") || true
    [[ -n "$v" ]] && engine_foreground set MOTD "${v//\"/}"

    v=$(gum input --value "$(eget XP_RATE)" --header "XP rate multiplier (1 = normal, 2 = double, 0.5 = half):") || true
    [[ -n "$v" ]] && engine_foreground set XP_RATE "$v"

    v=$(gum input --value "$(eget DROP_RATE)" --header "Loot/gold drop rate multiplier (1 = normal, 2 = double, 0.5 = half):") || true
    [[ -n "$v" ]] && engine_foreground set DROP_RATE "$v"

    # realmd.conf — login/security behavior.
    v=$(gum input --value "$(eget WRONG_PASS_MAX_COUNT)" \
        --header "Wrong-password attempts before a ban (0 = disabled):") || true
    [[ -n "$v" ]] && engine_foreground set WRONG_PASS_MAX_COUNT "$v"

    if [[ "$(eget WRONG_PASS_MAX_COUNT)" != "0" ]]; then
        v=$(gum input --value "$(eget WRONG_PASS_BAN_TIME)" --header "Ban duration in seconds:") || true
        [[ -n "$v" ]] && engine_foreground set WRONG_PASS_BAN_TIME "$v"

        v=$(_pick_value_label "Ban target" "$(eget WRONG_PASS_BAN_TYPE)" "Ban IP" "0|Ban IP" "1|Ban Account")
        engine_foreground set WRONG_PASS_BAN_TYPE "$v"
    fi

    v=$(_pick_value_label "Require email verification before login" "$(eget REQ_EMAIL_VERIFICATION)" "No" "0|No" "1|Yes")
    engine_foreground set REQ_EMAIL_VERIFICATION "$v"

    v=$(_pick_value_label "Reject modified/mismatched game clients (strict version check)" "$(eget STRICT_VERSION_CHECK)" "Yes" "1|Yes" "0|No")
    engine_foreground set STRICT_VERSION_CHECK "$v"

    v=$(_pick_value_label "Warden anti-cheat (client-side scans; irrelevant on a private/trusted LAN server)" "$(eget WARDEN_ENABLED)" "Enabled" "1|Enabled" "0|Disabled")
    engine_foreground set WARDEN_ENABLED "$v"

    v=$(_pick_value_label "Strict player names (character-set + profanity/reserved-name checks on every login)" "$(eget STRICT_PLAYER_NAMES)" "Disabled" \
        "0|Disabled" "1|Basic Latin only" "2|Realm zone specific" "3|Basic Latin + server timezone")
    engine_foreground set STRICT_PLAYER_NAMES "$v"
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

# Where mangosd is running, for the console-driven account commands. The
# engine auto-detects a single running target, but with mangosd up in more
# than one place (native + Docker while iterating, say) it refuses and asks
# for `--where local|docker|k8s` — which this front-end never sent, so those
# actions dead-ended. Sets WHERE_FLAGS (empty = let the engine detect) and,
# for k8s, GLOBAL_FLAGS: the engine's detection helpers run kubectl with the
# global --context/--kind target, which _submenu resets before every action.
# Only the account commands take --where; search/rename-character read the
# DB directly and have no such flag.
WHERE_FLAGS=()
_prompt_where() {
    WHERE_FLAGS=()
    local choice
    choice=$(gum choose "Auto-detect (mangosd runs in one place)" "local (native start)" "docker (run-docker)" "k8s (run-k8s)" \
        --header "Where is mangosd running?") || return 1
    case "$choice" in
        local*)  WHERE_FLAGS=(--where local) ;;
        docker*) WHERE_FLAGS=(--where docker) ;;
        k8s*)    WHERE_FLAGS=(--where k8s); _prompt_kube_target || return 1 ;;
        *) ;;   # auto-detect
    esac
}

# -----------------------------------------------------------------------------
# Actions — collect with gum, run the engine by flags.
# -----------------------------------------------------------------------------

action_configure() {
    header "nordrassil — Configure"
    local src
    src=$(gum input --value "$(eget SOURCE_DIR)" --header "Path to the repack (contains mangosd.conf, sql/, data/):") || return 0
    [[ -n "$src" ]] && engine_foreground set SOURCE_DIR "$src"

    local addr
    addr=$(gum input --value "$(eget REALM_ADDRESS)" \
        --header "LAN-reachable address for this realm (what WoW clients connect to after login):") || return 0
    [[ -n "$addr" ]] && engine_foreground set REALM_ADDRESS "$addr"

    _prompt_server_settings

    # Optional custom SQL — list what the engine sees under sql/Custom and let
    # the operator pick; the engine skips any already applied on a re-run.
    local custom=""
    local -a avail=()
    # Bare `engine`: stdout is the data here and the `|| true` is the caller's own
    # handling of a non-zero exit (no custom SQL / no repack yet) — an empty list.
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
        mangosd*) engine_foreground edit --file mangosd ;;
        realmd*)  engine_foreground edit --file realmd ;;
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
    # Persisted HERE, not left to the engine's --namespace/--address.
    #
    # The engine does save both, but only after its "image not built" check —
    # so answering these prompts and then hitting that check discarded both
    # answers silently. The operator types an address, sees an error about an
    # image, and the setting never changed. Both prompts are pre-filled from
    # the current value, which makes them look like settings; now they are.
    [[ -n "$ns" ]] && engine_foreground set K8S_NAMESPACE "$ns"
    addr=$(gum input --value "$(eget REALM_ADDRESS)" \
        --header "LAN-reachable address for this realm (the k8s NODE's IP, since the pod uses hostNetwork):") || return 0
    [[ -n "$addr" ]] && engine_foreground set REALM_ADDRESS "$addr"

    # Storage backend → persisted config the engine reads on run-k8s.
    local st
    st=$(_pick_value_label "Storage backend for game data + DB" "$(eget K8S_STORAGE_TYPE)" "hostPath" \
        "hostpath|hostPath (single-node / home-lab — path on the node)" \
        "storageclass|StorageClass (dynamic provisioning)")
    engine_foreground set K8S_STORAGE_TYPE "$st"
    if [[ "$st" == "hostpath" ]]; then
        local dp bp
        dp=$(gum input --value "$(eget K8S_DATA_HOSTPATH)" --header "hostPath for game data (on the k8s node):") || return 0
        [[ -n "$dp" ]] && engine_foreground set K8S_DATA_HOSTPATH "$dp"
        bp=$(gum input --value "$(eget K8S_DB_HOSTPATH)" --header "hostPath for MariaDB data (on the k8s node):") || return 0
        [[ -n "$bp" ]] && engine_foreground set K8S_DB_HOSTPATH "$bp"
    else
        local sc
        sc=$(gum input --value "$(eget K8S_STORAGECLASS)" --placeholder "leave empty for cluster default" --header "StorageClass name:") || true
        engine_foreground set K8S_STORAGECLASS "$sc"
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
    _prompt_where || { info "Cancelled."; return 0; }
    local name pass level
    name=$(gum input --placeholder "username" --header "New account username:") || return 0
    [[ -n "$name" ]] || { info "Cancelled."; return 0; }
    pass=$(gum input --password --placeholder "password" --header "New account password:") || return 0
    [[ -n "$pass" ]] || { info "Cancelled."; return 0; }
    level=$(_pick_gm_level "Account access level" "0")
    engine_foreground create-account --name "$name" --pass "$pass" --level "$level" ${WHERE_FLAGS[@]+"${WHERE_FLAGS[@]}"}
}

action_list_accounts() {
    header "nordrassil — List accounts"
    _prompt_where || { info "Cancelled."; return 0; }
    engine_foreground list-accounts ${WHERE_FLAGS[@]+"${WHERE_FLAGS[@]}"}
}

action_delete_account() {
    header "nordrassil — Delete account"
    _prompt_where || { info "Cancelled."; return 0; }
    engine_foreground list-accounts ${WHERE_FLAGS[@]+"${WHERE_FLAGS[@]}"}
    echo ""
    local name
    name=$(gum input --placeholder "username" --header "Account to delete:") || return 0
    [[ -n "$name" ]] || { info "Cancelled."; return 0; }
    gum confirm "Delete account '${name}'? This also removes its characters." || { info "Cancelled."; return 0; }
    engine_foreground delete-account --name "$name" ${WHERE_FLAGS[@]+"${WHERE_FLAGS[@]}"}
}

action_set_account_level() {
    header "nordrassil — Set account level"
    _prompt_where || { info "Cancelled."; return 0; }
    engine_foreground list-accounts ${WHERE_FLAGS[@]+"${WHERE_FLAGS[@]}"}
    echo ""
    local name level
    name=$(gum input --placeholder "username" --header "Account to change:") || return 0
    [[ -n "$name" ]] || { info "Cancelled."; return 0; }
    level=$(_pick_gm_level "New access level" "0")
    engine_foreground set-account-level --name "$name" --level "$level" ${WHERE_FLAGS[@]+"${WHERE_FLAGS[@]}"}
}

action_rename_character() {
    header "nordrassil — Rename character"
    local from to
    from=$(gum input --placeholder "current name" --header "Character to rename (use 'Search' to find one):") || return 0
    [[ -n "$from" ]] || { info "Cancelled."; return 0; }
    to=$(gum input --placeholder "new name" --header "New name for '${from}' (up to 12 characters, bypasses normal naming rules):") || return 0
    [[ -n "$to" ]] || { info "Cancelled."; return 0; }
    engine_foreground rename-character --from "$from" --to "$to"
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
    engine_foreground search --kind "$kind" --term "$term"
}

# -----------------------------------------------------------------------------
# Profiles — which server everything else acts on.
#
# This is the first thing to get right in a front-end that can now restore a
# database and restart a server: every destructive action below names the
# profile in its confirmation, and the category menu shows it, because the
# only thing worse than a mistaken restore is a mistaken restore onto the
# wrong machine.
# -----------------------------------------------------------------------------

# Asks for the settings that say WHERE a server is. Only the questions that
# matter for the chosen transport get asked.
_prompt_transport_settings() {
    local v h

    # Asked first because it frames everything after it: a server something
    # else provisions is one this tool only administers.
    v=$(_pick_value_label "Who provisions this server" "$(eget MANAGED_EXTERNALLY)" "this tool" \
        "0|this tool — configure, run-docker, run-k8s" \
        "1|something else — Ansible, GitOps, CI (administration only)")
    engine_foreground set MANAGED_EXTERNALLY "$v"

    v=$(_pick_value_label "Where this profile's DATABASE is reached" "$(eget DB_TRANSPORT)" "auto" \
        "auto|auto — probe this machine (local servers only)" \
        "docker|docker exec into a container" \
        "podman|podman exec into a container" \
        "kubectl|kubectl exec into a pod" \
        "tcp|connect straight to a MariaDB port")
    engine_foreground set DB_TRANSPORT "$v"

    # Empty is a meaningful answer for the ssh hosts (it means "this
    # machine"), so these use `if gum input` rather than the
    # `[[ -n "$v" ]] && set` pattern used for settings that cannot be blank:
    # that pattern cannot clear a value, and an inherited DB_SSH_HOST which
    # cannot be cleared would send every query to the wrong host.
    if [[ "$v" != auto && "$v" != tcp ]]; then
        if h=$(gum input --value "$(eget DB_SSH_HOST)" \
                 --header "ssh host the database's engine runs on (empty = this machine):"); then
            engine_foreground set DB_SSH_HOST "$h"
        fi
    fi

    case "$v" in
        docker|podman)
            if h=$(gum input --value "$(eget DB_CONTAINER_NAME)" --header "MariaDB container name:"); then
                [[ -n "$h" ]] && engine_foreground set DB_CONTAINER_NAME "$h"
            fi
            ;;
        kubectl)
            if h=$(gum input --value "$(eget DB_POD_SELECTOR)" --header "Label selector for the MariaDB pod:"); then
                [[ -n "$h" ]] && engine_foreground set DB_POD_SELECTOR "$h"
            fi
            ;;
        tcp)
            if h=$(gum input --value "$(eget DB_HOST)" --header "MariaDB host:"); then
                [[ -n "$h" ]] && engine_foreground set DB_HOST "$h"
            fi
            if h=$(gum input --value "$(eget DB_PORT)" --header "MariaDB port:"); then
                [[ -n "$h" ]] && engine_foreground set DB_PORT "$h"
            fi
            ;;
    esac

    if h=$(gum input --value "$(eget DB_USER)" --header "MariaDB user:"); then
        [[ -n "$h" ]] && engine_foreground set DB_USER "$h"
    fi
    v=$(_pick_value_label "MariaDB password" "$(eget DB_PASS)" "stored" \
        "ask|Ask once per session (never written to disk)" \
        "root|Store it in the profile")
    if [[ "$v" == "root" ]]; then
        # Typed with --password so it is not echoed; it does land in the
        # profile file, which is why 'ask' is offered first.
        if h=$(gum input --password --header "MariaDB password (stored in the profile file):"); then
            [[ -n "$h" ]] && engine_foreground set DB_PASS "$h"
        fi
    else
        engine_foreground set DB_PASS ask
    fi

    v=$(_pick_value_label "Where this profile's SERVER (mangosd) is reached" "$(eget SERVER_TRANSPORT)" "auto" \
        "auto|auto — probe this machine (local servers only)" \
        "local|started by this script, natively" \
        "docker|docker exec into a container" \
        "podman|podman exec into a container" \
        "kubectl|kubectl exec into a pod")
    engine_foreground set SERVER_TRANSPORT "$v"

    if [[ "$v" != auto && "$v" != local ]]; then
        if h=$(gum input --value "$(eget SERVER_SSH_HOST)" \
                 --header "ssh host the server's orchestrator runs on (empty = this machine):"); then
            engine_foreground set SERVER_SSH_HOST "$h"
        fi
        if h=$(gum input --value "$(eget SERVER_FIFO)" \
                 --header "mangosd's console FIFO path INSIDE the container:"); then
            [[ -n "$h" ]] && engine_foreground set SERVER_FIFO "$h"
        fi
    fi
    case "$v" in
        docker|podman)
            if h=$(gum input --value "$(eget SERVER_CONTAINER_NAME)" --header "Server container name:"); then
                [[ -n "$h" ]] && engine_foreground set SERVER_CONTAINER_NAME "$h"
            fi
            ;;
        kubectl)
            if h=$(gum input --value "$(eget K8S_NAMESPACE)" --header "Kubernetes namespace:"); then
                [[ -n "$h" ]] && engine_foreground set K8S_NAMESPACE "$h"
            fi
            if h=$(gum input --value "$(eget SERVER_POD_SELECTOR)" --header "Label selector for the server pod:"); then
                [[ -n "$h" ]] && engine_foreground set SERVER_POD_SELECTOR "$h"
            fi
            if h=$(gum input --value "$(eget SERVER_K8S_CONTAINER)" \
                     --header "Container in that pod (empty = let kubectl choose):"); then
                engine_foreground set SERVER_K8S_CONTAINER "$h"
            fi
            ;;
    esac

    success "Transports saved for ${PROFILE_LABEL}."
}

action_profile() {
    header "nordrassil — Choose a server"
    local -a names=()
    local n
    while IFS= read -r n; do [[ -n "$n" ]] && names+=("$n"); done < <(_engine_profiles)

    local pick
    pick=$(printf '%s\n' "${names[@]}" "base config (no profile)" "new profile..." \
           | gum choose --header "Act on which server? (current: ${PROFILE_LABEL})") || return 0
    [[ -n "$pick" ]] || { info "Cancelled."; return 0; }

    case "$pick" in
        "base config (no profile)")
            _set_profile ""
            success "Now acting on the base config."
            ;;
        "new profile...")
            local name
            name=$(gum input --placeholder "meksha" --header "Name for the new profile:") || return 0
            [[ -n "$name" ]] || { info "Cancelled."; return 0; }
            # Validated here as well as in the engine: the engine rejects a
            # bad name, but doing it before the wizard means the operator is
            # told immediately rather than after a dozen prompts.
            [[ "$name" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] \
                || { warn "Invalid name '${name}' (letters, digits, then . _ -)."; return 0; }
            _set_profile "$name"
            info "A profile only carries what differs from the base config."
            _prompt_transport_settings
            ;;
        *)
            _set_profile "$pick"
            success "Now acting on '${PROFILE}'."
            ;;
    esac
}

# Who provisions the server this profile points at. Offered on its own as
# well as inside the wizard, because it is the one setting whose answer
# changes which menus exist.
action_profile_managed() {
    header "nordrassil — Ownership"
    local v
    v=$(_pick_value_label "Who provisions ${PROFILE_LABEL}" "$(eget MANAGED_EXTERNALLY)" "this tool" \
        "0|this tool — configure, run-docker, run-k8s" \
        "1|something else — Ansible, GitOps, CI (administration only)")
    engine_foreground set MANAGED_EXTERNALLY "$v"
    # Re-read so the category list changes now rather than next launch.
    _set_profile "$PROFILE"
    success "Saved. Acting on: ${PROFILE_LABEL}."
}

action_profile_transports() {
    header "nordrassil — Transports"
    info "Editing transports for ${PROFILE_LABEL}."
    _prompt_transport_settings
}

action_profile_show() {
    header "nordrassil — Settings"
    engine_foreground config
}

action_forget() {
    header "nordrassil — Forget password"
    engine_foreground forget
}

# -----------------------------------------------------------------------------
# Administration — the destructive half. Every one of these confirms, because
# the engine deliberately does not prompt (it has to stay scriptable), so the
# confirmation is this front-end's job.
# -----------------------------------------------------------------------------

action_apply_sql() {
    header "nordrassil — Apply SQL"
    local file db
    file=$(gum input --placeholder "/path/to/change.sql" --header "SQL file to apply:") || return 0
    [[ -n "$file" ]] || { info "Cancelled."; return 0; }
    db=$(gum choose mangos characters realmd logs --header "Apply it to which database?") || return 0
    [[ -n "$db" ]] || { info "Cancelled."; return 0; }
    warn "This modifies the '${db}' database on ${PROFILE_LABEL}."
    gum confirm --default=false "Apply $(basename "$file") to ${db} on ${PROFILE_LABEL}?" \
        || { info "Cancelled."; return 0; }
    engine_foreground apply-sql --file "$file" --db "$db"
}

action_dump() {
    header "nordrassil — Dump"
    local what
    what=$(gum choose \
             "accounts only (to move between servers)" \
             "All four databases" "mangos (world)" "characters" \
             "realmd (whole — includes this realm's address)" "logs" \
           --header "Dump what from ${PROFILE_LABEL}?") || return 0
    case "$what" in
        # The realm pointer lives in realmd.realmlist, so a WHOLE realmd dump
        # restored onto another server takes this server's address with it and
        # sends that server's clients here. Moving accounts is the common
        # reason to dump realmd at all, so it gets its own entry and the whole
        # database one is labelled with what it drags along.
        "accounts only"*)
            engine_foreground dump --db realmd \
                --tables "account account_access account_banned realmcharacters" ;;
        "All four databases") engine_foreground dump --all ;;
        "mangos (world)")     engine_foreground dump --db mangos ;;
        characters)           engine_foreground dump --db characters ;;
        "realmd (whole"*)     engine_foreground dump --db realmd ;;
        logs)                 engine_foreground dump --db logs ;;
        *) info "Cancelled." ;;
    esac
}

action_restore() {
    header "nordrassil — Restore"
    # Offers what's in the engine's dump directory, newest first, because
    # that is where 'dump' puts things; any other file can still be typed.
    local dir="${XDG_CONFIG_HOME:-$HOME/.config}/nordrassil/dumps"
    local -a files=()
    local f
    if [[ -d "$dir" ]]; then
        while IFS= read -r f; do [[ -n "$f" ]] && files+=("$f"); done \
            < <(ls -1t "$dir" 2>/dev/null | grep -vE '\.partial$' || true)
    fi

    local pick
    pick=$(printf '%s\n' "${files[@]}" "another path..." \
           | gum choose --header "Dump to restore onto ${PROFILE_LABEL} (newest first):") || return 0
    [[ -n "$pick" ]] || { info "Cancelled."; return 0; }

    local file
    if [[ "$pick" == "another path..." ]]; then
        file=$(gum input --placeholder "/path/to/dump.sql.gz" --header "Path to the dump:") || return 0
    else
        file="${dir}/${pick}"
    fi
    [[ -n "$file" ]] || { info "Cancelled."; return 0; }

    # A table-level dump carries no CREATE DATABASE, so the engine cannot know
    # where it goes and refuses without --db. Detected rather than asked every
    # time, using the same signal the engine itself looks for.
    local -a dbflag=()
    local headtxt
    if [[ "$file" == *.gz ]]; then headtxt="$(gzip -dc "$file" 2>/dev/null | head -200 || true)"
    else                           headtxt="$(head -200 "$file" 2>/dev/null || true)"; fi
    if ! grep -qiE '^(CREATE DATABASE|USE )' <<<"$headtxt"; then
        local intodb
        intodb=$(gum choose mangos characters realmd logs \
                 --header "This dump names no database (a table subset) — restore into which?") || return 0
        [[ -n "$intodb" ]] || { info "Cancelled."; return 0; }
        dbflag=(--db "$intodb")
        warn "Only the tables in the dump are replaced; the rest of '${intodb}' is left alone."
    fi

    warn "RESTORE REPLACES DATA on ${PROFILE_LABEL}. It cannot be undone."
    warn "The engine prints which databases the dump will overwrite before it starts."
    gum confirm --default=false "Restore $(basename "$file") onto ${PROFILE_LABEL}?" \
        || { info "Cancelled."; return 0; }
    engine_foreground restore --file "$file" "${dbflag[@]}" --yes
}

action_restart() {
    header "nordrassil — Restart"
    local how
    how=$(gum choose "Now (at the orchestrator)" "Graceful (warn players first)" \
          --header "Restart ${PROFILE_LABEL} how?") || return 0
    case "$how" in
        "Now (at the orchestrator)")
            warn "Players are disconnected immediately."
            gum confirm --default=false "Restart ${PROFILE_LABEL} now?" || { info "Cancelled."; return 0; }
            engine_foreground restart
            ;;
        "Graceful (warn players first)")
            local secs
            secs=$(gum input --value "60" \
                   --header "Seconds before mangosd stops (players are warned and the world is saved):") || return 0
            [[ "$secs" =~ ^[0-9]+$ ]] || { warn "'${secs}' is not a number of seconds."; return 0; }
            info "That is how long mangosd waits, not how long the restart takes:"
            info "it comes back when its supervisor notices it stopped."
            gum confirm --default=false "Tell ${PROFILE_LABEL} to restart in ${secs}s?" \
                || { info "Cancelled."; return 0; }
            engine_foreground restart --graceful "$secs"
            ;;
        *) info "Cancelled." ;;
    esac
}

# -----------------------------------------------------------------------------
# Menus — mirror the original category layout.
# -----------------------------------------------------------------------------

_submenu() {
    local title="$1"; shift
    local -a opts=("$@")
    while true; do
        header "Vanilla WoW — ${title}  [${PROFILE_LABEL}]"
        local action
        action=$(printf '%s\n' "${opts[@]}" "back" | gum choose --header "Choose an action:") || true
        [[ -z "$action" || "$action" == "back" ]] && return
        GLOBAL_FLAGS=()   # only the k8s / --where=k8s actions repopulate this (a kube target)
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
            list-accounts)     action_list_accounts || true ;;
            delete-account)    action_delete_account || true ;;
            set-account-level) action_set_account_level || true ;;
            rename-character)  action_rename_character || true ;;
            apply-sql)         action_apply_sql || true ;;
            restart)           action_restart || true ;;
            dump)              action_dump || true ;;
            restore)           action_restore || true ;;
            choose-server)     action_profile || true ;;
            ownership)         action_profile_managed || true ;;
            transports)        action_profile_transports || true ;;
            settings)          action_profile_show || true ;;
            forget-password)   action_forget || true ;;
        esac
        echo ""
    done
}

main() {
    resolve_engine
    # An exported profile is honoured as the starting server, but only if it
    # exists — the engine refuses a profile whose file is missing, and adopting
    # one here would label the session with a server every action then rejects.
    if [[ -n "$INITIAL_PROFILE" ]]; then
        if printf '%s\n' "$(_engine_profiles)" | grep -qxF "$INITIAL_PROFILE"; then
            _set_profile "$INITIAL_PROFILE"
            info "\$NORDRASSIL_PROFILE: starting on '${INITIAL_PROFILE}'."
        else
            warn "\$NORDRASSIL_PROFILE='${INITIAL_PROFILE}' is not an existing profile — starting on the base config."
        fi
    fi
    gum style --foreground "$CYAN" --border-foreground "$CYAN" --border double \
        --align center --width 60 --margin "1 2" --padding "1 4" \
        "nordrassil" "vanilla WoW (VMaNGOS) server — the World Tree"
    # If any profile exists, ask up front which server this session acts on.
    # Everything below can restore a database and restart a server, and the
    # only thing worse than a mistaken restore is one onto the wrong machine.
    # Declining is one keystroke; with no profiles at all, nothing is asked.
    if [[ -n "$(_engine_profiles)" ]]; then
        action_profile || true
    fi

    while true; do
        local category
        local -a cats=(Server Setup Local Deploy Accounts Characters Search Administration Status Quit)
        # A profile marked MANAGED_EXTERNALLY describes a server something else
        # provisions, so the categories that provision one are not offered.
        # The engine refuses those commands anyway; not listing them is so the
        # operator is never led to them — in particular 'configure', which
        # re-runs the world import over live data.
        [[ "$MANAGED" == "1" ]] && cats=(Server Accounts Characters Search Administration Status Quit)
        category=$(printf '%s\n' "${cats[@]}" \
            | gum choose --header "Choose a category:  [acting on: ${PROFILE_LABEL}]") || true
        [[ -z "$category" || "$category" == "Quit" ]] && { gum style --faint "Bye."; exit 0; }
        case "$category" in
            Server)     _submenu "Server"     choose-server ownership transports settings forget-password ;;
            Setup)      _submenu "Setup"      install-deps configure edit ;;
            Local)      _submenu "Local"      start stop ;;
            Deploy)     _submenu "Deploy"     build-image run-docker stop-docker run-k8s stop-k8s ;;
            Accounts)   _submenu "Accounts"   create-account list-accounts delete-account set-account-level ;;
            Characters) _submenu "Characters" rename-character ;;
            Administration) _submenu "Administration" apply-sql restart dump restore ;;
            Search)     action_search || true ;;
            Status)     engine_foreground status ;;
        esac
    done
}

main "$@"
