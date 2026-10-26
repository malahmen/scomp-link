#!/usr/bin/env bash
# description: Vanilla WoW (cmangos + playerbots) server — gum front-end for the teldrassil engine
# Standalone export (export.sh): no extra setup deps — git is checked at runtime (engine clone).
# -----------------------------------------------------------------------------
# gum front-end for the standalone, flag-driven `teldrassil` engine: a
# cmangos-classic vanilla WoW server (1.12.1) built with playerbots, and the
# bots shaped to live in it. The logic - building and installing the server,
# the containers, the remote console, accounts, the roster, search, LLM chat,
# attunements, dumps - lives in its own repo as a gum-free CLI; this file only
# resolves that engine, collects options with gum, and drives it by flags.
#
# Named wow-cmangos-teldrassil: wow- so the WoW tools sort together in the
# launcher, then the server it is for. The VMaNGOS server has its own,
# wow-vmangos-nordrassil, and the two are not mixed; wow-dark-portal is the
# client side and serves both.
#
# The engine prompts for nothing, so every confirmation is this file's job,
# and the destructive ones default to "no". Passwords reach the engine on
# stdin, never as an argument.
#
# Engine resolution order:
#   1. $TELDRASSIL_DIR/teldrassil.sh        (explicit override - a checkout you control)
#   2. ../../../teldrassil/teldrassil.sh    (sibling dev checkout next to scomp-link)
#   3. ~/.cache/scomp-link/teldrassil/...   (cached clone; offers git pull)
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

TELDRASSIL_REPO="${TELDRASSIL_REPO:-https://github.com/malahmen/teldrassil.git}"
TELDRASSIL_CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/scomp-link/teldrassil"
ENGINE=""

# Which server everything acts on: an engine profile, or the base config.
# $TELDRASSIL_PROFILE would be read by the engine itself at every call, so it
# is taken once as this session's starting point and cleared: from then on
# PROFILE_FLAGS alone says where a command goes, and choosing "base config"
# really means the base config.
INITIAL_PROFILE="${TELDRASSIL_PROFILE:-}"
unset TELDRASSIL_PROFILE
PROFILE_FLAGS=()
PROFILE_LABEL="base config"
_set_profile() {
    if [[ -n "$1" ]]; then PROFILE_FLAGS=(--profile "$1"); PROFILE_LABEL="$1"
    else PROFILE_FLAGS=(); PROFILE_LABEL="base config"; fi
}

trap 'echo ""; gum style --faint "Interrupted."; exit 0' INT TERM

resolve_engine() {
    if [[ -n "${TELDRASSIL_DIR:-}" && -f "${TELDRASSIL_DIR}/teldrassil.sh" ]]; then
        ENGINE="${TELDRASSIL_DIR}/teldrassil.sh"; info "Using teldrassil from \$TELDRASSIL_DIR: ${TELDRASSIL_DIR}"; return
    fi
    local sib="${SCRIPT_DIR}/../../../teldrassil/teldrassil.sh"
    if [[ -f "$sib" ]]; then
        ENGINE="$(cd "$(dirname "$sib")" && pwd)/teldrassil.sh"; info "Using local teldrassil checkout: $(dirname "$ENGINE")"; return
    fi
    if [[ -f "${TELDRASSIL_CACHE}/teldrassil.sh" ]]; then
        ENGINE="${TELDRASSIL_CACHE}/teldrassil.sh"; info "Using cached teldrassil: ${TELDRASSIL_CACHE}"
        if [[ -d "${TELDRASSIL_CACHE}/.git" ]] && command -v git &>/dev/null && gum confirm "Update teldrassil (git pull)?"; then
            gum spin --spinner dot --title "Updating teldrassil..." -- git -C "$TELDRASSIL_CACHE" pull --ff-only || warn "Update failed; using existing copy."
        fi
        return
    fi
    need_git "to fetch the teldrassil engine"
    gum confirm "teldrassil engine not found. Clone it from ${TELDRASSIL_REPO}?" || error_exit "teldrassil engine is unavailable."
    mkdir -p "$(dirname "$TELDRASSIL_CACHE")"
    gum spin --spinner dot --title "Cloning teldrassil..." -- git clone --depth 1 "$TELDRASSIL_REPO" "$TELDRASSIL_CACHE" \
        || error_exit "Failed to clone teldrassil from ${TELDRASSIL_REPO}"
    ENGINE="${TELDRASSIL_CACHE}/teldrassil.sh"; success "teldrassil cloned to ${TELDRASSIL_CACHE}"
}

# engine_foreground runs every action: under `set -e` a bare call that exits
# non-zero (a refused command, a stopped server) or a Ctrl-C would end the
# whole TUI, where an error or an interrupt has to leave the operator back in
# the menu. eget reads one setting, for pre-filling a prompt.
engine_foreground() {
    trap ':' INT
    bash "$ENGINE" "${PROFILE_FLAGS[@]}" "$@" || true
    trap 'echo ""; gum style --faint "Interrupted."; exit 0' INT TERM
}
eget() { bash "$ENGINE" "${PROFILE_FLAGS[@]}" get "$1" 2>/dev/null || true; }

# _ask <header> [current] — a gum input; empty output means cancelled or blank.
_ask() { gum input --value "${2:-}" --header "$1" || true; }

# _set_if <KEY> <header> — prompt pre-filled with the current value, saved
# only when an answer was given (empty keeps the setting).
_set_if() {
    local v; v="$(_ask "$2" "$(eget "$1")")"
    [[ -n "$v" ]] && engine_foreground set "$1" "$v"
    return 0
}

# cmangos-classic's account levels.
_pick_gm_level() {
    local hdr="$1" choice
    choice=$(gum choose "0 - Player" "1 - Moderator" "2 - Gamemaster" "3 - Administrator" --header "$hdr") || return 1
    printf '%s' "${choice%% *}"
}

# -----------------------------------------------------------------------------
# Settings — where the server is.
# -----------------------------------------------------------------------------

action_setup() {
    header "teldrassil — Where the server is (${PROFILE_LABEL})"
    info "Each answer is saved with the engine's 'set'; leave one blank to keep it."
    local where
    where=$(gum choose --header "Where does this server run?" \
        "Here, in containers" \
        "Another machine, in containers (over ssh)" \
        "Another machine, in Kubernetes (over ssh)") || return 0
    case "$where" in
        Here*)
            engine_foreground set SSH_HOST ""
            engine_foreground set SERVER_KIND podman ;;
        *)
            _set_if SSH_HOST "ssh host (a ~/.ssh/config alias or user@host; key login, no prompts):"
            if [[ "$where" == *Kubernetes* ]]; then engine_foreground set SERVER_KIND kube
            else engine_foreground set SERVER_KIND podman; fi ;;
    esac
    _set_if DB_CONTAINER "MariaDB container name:"
    _set_if DB_USER      "MariaDB user:"
    _set_if DB_PASS_ENV  "Variable holding that user's password inside the MariaDB container (blank: the file below):"
    _set_if DB_PASS_FILE "Password file inside the MariaDB container:"
    if [[ "$where" == *Kubernetes* ]]; then
        _set_if KUBE_NAMESPACE       "Namespace:"
        _set_if SERVER_CONTAINER     "World server Deployment:"
        _set_if BOT_SECRET           "Secret holding aiplayerbot.conf and the card file:"
        _set_if WORLD_PORT           "World server port:"
        _set_if CARDS_FILE_IN_SERVER "The card file's path as the server sees it:"
    else
        _set_if PODMAN           "Container runtime (podman or docker):"
        _set_if SERVER_CONTAINER "World server (mangosd) container name:"
        _set_if REALM_CONTAINER  "Realm server (realmd) container name:"
        [[ "$where" == Here* ]] && _set_if ETC_DIR "Server config directory on this host (holds aiplayerbot.conf):"
    fi
    _set_if RA_PASS_FILE "File with the remote-console account's password (this machine; blank: none yet):"
    _set_if ROSTER_FILE  "Roster JSON (the shaped bots):"
    _set_if DBC_DIR      "Extracted client dbc directory (zone names in search):"
    success "Saved. 'Status' shows whether the engine can reach it all."
    [[ -n "$(eget RA_PASS_FILE)" ]] && return 0
    info "No console account yet: stop, save and the console need one."
    gum confirm --default=false "Create teldrassil's console account (TELDRASSIL, level 3) on ${PROFILE_LABEL} now?" \
        && engine_foreground console-account
    return 0
}

# action_profile — which server the rest of the menus act on.
action_profile() {
    header "teldrassil — Profile (now: ${PROFILE_LABEL})"
    local -a names; mapfile -t names < <(bash "$ENGINE" profiles 2>/dev/null | sed -E 's/^[*[:space:]]+//' | grep -vE '^$|=' || true)
    local choice name
    choice=$(printf '%s\n' "${names[@]}" "new profile..." "base config (no profile)" \
        | gum choose --header "Act on which server?") || return 0
    case "$choice" in
        "base config (no profile)") _set_profile "" ;;
        "new profile...")
            name="$(_ask "New profile name (letters, digits, then . _ -):")"
            [[ -n "$name" ]] || return 0
            [[ "$name" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ && "$name" != *..* ]] || { warn "'${name}' is not a valid profile name."; return 0; }
            _set_profile "$name"
            info "Profile ${name} is created by its first setting."
            action_setup ;;
        *) _set_profile "$choice" ;;
    esac
    success "Acting on: ${PROFILE_LABEL}"
}

# -----------------------------------------------------------------------------
# Provision — from nothing to a running server.
# -----------------------------------------------------------------------------

action_install() {
    header "teldrassil — Install a server"
    info "Builds from pinned sources, extracts the client's data, creates the databases"
    info "and starts it all in containers. Steps already done are skipped."
    _set_if CLIENT_DIR    "The 1.12.1 client folder (it holds Data/):"
    _set_if REALM_NAME    "Realm name (in the realm list):"
    _set_if REALM_ADDRESS "Address players connect to (this machine's LAN address for LAN play):"
    _set_if BOTS          "How many random bots:"
    _set_if WORK_DIR      "Where teldrassil keeps its files (blank keeps the current place):"
    warn "The first install compiles for tens of minutes and extracts for about 20 (~7 GB in all)."
    gum confirm --default=false "Install now?" || { info "Cancelled."; return 0; }
    engine_foreground install --yes
}

action_step() {
    case "$1" in
        build)
            local jobs; jobs="$(_ask "Compile jobs (blank: one per CPU):")"
            local -a args=(build); [[ -n "$jobs" ]] && args+=(--jobs "$jobs")
            gum confirm --default=false "Start from a clean build tree (much slower)?" && args+=(--clean)
            engine_foreground "${args[@]}" ;;
        extract)
            local -a args=(extract)
            gum confirm --default=false "Extract again even if the data is there?" && args+=(--force)
            engine_foreground "${args[@]}" ;;
        db-init)
            warn "This creates the four databases and REPLACES any that exist: every account and character."
            gum confirm --default=false "Recreate the databases on ${PROFILE_LABEL}?" || { info "Cancelled."; return 0; }
            engine_foreground db-init --yes ;;
        configure)
            local -a args=(configure)
            if gum confirm --default=false "Rewrite existing config files from their templates (the roster's settings are lost until it is applied again)?"; then args+=(--force); fi
            engine_foreground "${args[@]}" ;;
        create)
            local -a args=(create)
            gum confirm --default=false "Recreate the containers if they exist?" && args+=(--force)
            engine_foreground "${args[@]}" ;;
        source)
            local -a args=(source)
            gum confirm --default=false "Move the checkouts to the pinned commits if they differ?" && args+=(--update)
            engine_foreground "${args[@]}" ;;
        build-image) engine_foreground build-image ;;
    esac
}

action_remove() {
    header "teldrassil — Remove the server"
    warn "This deletes the realm and world server containers; the files stay."
    gum confirm --default=false "Remove the server's containers on ${PROFILE_LABEL}?" || { info "Cancelled."; return 0; }
    local -a args=(remove --yes)
    if gum confirm --default=false "Also delete the DATABASE - every account and character?"; then
        if gum confirm --default=false "Really delete every account and character? Dump first if in doubt."; then
            args+=(--database)
        else
            info "Keeping the database."
        fi
    fi
    engine_foreground "${args[@]}"
}

# -----------------------------------------------------------------------------
# LLM chat — optional, off on a new server.
# -----------------------------------------------------------------------------

action_llm() {
    header "teldrassil — LLM chat"
    engine_foreground llm status
    local choice
    choice=$(gum choose "Turn it on (or change it)" "Turn it off" "Leave it" --header "Bots' chat through a language model:") || return 0
    case "$choice" in
        "Turn it off")
            engine_foreground llm off
            info "Takes effect at the next restart." ;;
        "Turn it on"*)
            local endpoint model tokens effort b2b key
            endpoint="$(_ask "Endpoint (an OpenAI-style .../v1/chat/completions):" "http://127.0.0.1:1234/v1/chat/completions")"
            [[ -n "$endpoint" ]] || { info "Cancelled."; return 0; }
            model="$(_ask "Model name, as the endpoint knows it:")"
            [[ -n "$model" ]] || { info "Cancelled."; return 0; }
            tokens="$(_ask "Longest reply, in tokens:" 80)"
            effort="$(_ask "Reasoning effort (blank to leave out; 'none' stops thinking models from thinking):")"
            b2b="$(_ask "Chance bots answer each other through it, in % (0 keeps it to players):" 0)"
            key="$(_ask "File holding an API key (blank for a local endpoint):")"
            local -a args=(llm on --endpoint "$endpoint" --model "$model")
            [[ -n "$tokens" ]] && args+=(--max-tokens "$tokens")
            [[ -n "$effort" ]] && args+=(--reasoning-effort "$effort")
            [[ -n "$b2b" ]] && args+=(--bot-to-bot "$b2b")
            [[ -n "$key" ]] && args+=(--api-key-file "$key")
            engine_foreground "${args[@]}"
            info "Takes effect at the next restart (Server -> restart)." ;;
    esac
}

# -----------------------------------------------------------------------------
# Server
# -----------------------------------------------------------------------------

action_stop() {
    warn "Stopping saves the world, then disconnects everyone."
    gum confirm --default=false "Stop the world server on ${PROFILE_LABEL}?" || { info "Cancelled."; return 0; }
    engine_foreground stop
}

action_restart() {
    header "teldrassil — Restart"
    local how
    how=$(gum choose "Now (stop and start)" "Graceful (warn players first)" --header "Restart how?") || return 0
    case "$how" in
        "Now (stop and start)")
            gum confirm --default=false "Restart the world server now?" || { info "Cancelled."; return 0; }
            engine_foreground restart ;;
        "Graceful (warn players first)")
            local secs; secs="$(_ask "Seconds before mangosd stops (players are warned, the world saved):" 60)"
            [[ "$secs" =~ ^[0-9]+$ ]] || { warn "'${secs}' is not a number of seconds."; return 0; }
            gum confirm --default=false "Restart in ${secs}s?" || { info "Cancelled."; return 0; }
            engine_foreground restart --graceful "$secs" ;;
    esac
}

action_console() {
    header "teldrassil — Console"
    info "Remote-console commands, one at a time; blank to go back."
    info "Bot chat commands ('rndbot c', 'rndbot do') are refused: send those in game."
    local c
    while true; do
        c="$(_ask "Console command:")"
        [[ -n "$c" ]] || return 0
        engine_foreground console "$c"
    done
}

# -----------------------------------------------------------------------------
# Accounts and characters
# -----------------------------------------------------------------------------

action_create_account() {
    header "teldrassil — Create account"
    local name pass level
    name="$(_ask "New account name (3-16 letters or digits):")"
    [[ -n "$name" ]] || { info "Cancelled."; return 0; }
    pass=$(gum input --password --header "Password (4-16 characters):") || { info "Cancelled."; return 0; }
    [[ -n "$pass" ]] || { info "Cancelled."; return 0; }
    level="$(_pick_gm_level "Account level:")" || { info "Cancelled."; return 0; }
    # On stdin: an argument would show in the process list and shell history.
    trap ':' INT
    printf '%s\n' "$pass" | bash "$ENGINE" "${PROFILE_FLAGS[@]}" create-account --name "$name" --pass-stdin --level "$level" || true
    trap 'echo ""; gum style --faint "Interrupted."; exit 0' INT TERM
    unset pass
}

action_set_account_level() {
    header "teldrassil — Set account level"
    engine_foreground list-accounts
    local name level
    name="$(_ask "Account to change:")"
    [[ -n "$name" ]] || { info "Cancelled."; return 0; }
    level="$(_pick_gm_level "New level for ${name}:")" || { info "Cancelled."; return 0; }
    engine_foreground set-account-level --name "$name" --level "$level"
}

action_delete_account() {
    header "teldrassil — Delete account"
    engine_foreground list-accounts
    local name; name="$(_ask "Account to delete (only one with no characters):")"
    [[ -n "$name" ]] || { info "Cancelled."; return 0; }
    gum confirm --default=false "Delete account '${name}' on ${PROFILE_LABEL} for good?" || { info "Cancelled."; return 0; }
    engine_foreground delete-account --name "$name" --yes
}

action_rename_character() {
    header "teldrassil — Rename character"
    local from to
    from="$(_ask "Character to rename (it must be offline):")"
    [[ -n "$from" ]] || { info "Cancelled."; return 0; }
    to="$(_ask "New name for ${from} (2-12 letters, capital first):")"
    [[ -n "$to" ]] || { info "Cancelled."; return 0; }
    engine_foreground rename-character --from "$from" --to "$to"
}

# -----------------------------------------------------------------------------
# Search
# -----------------------------------------------------------------------------

action_search() {
    header "teldrassil — Search"
    local label kind term
    label=$(gum choose "Bots" "Characters (bots and players)" "Guilds" "Items" "NPCs" \
            "Objects (herbs, ore, chests)" "Quests" "Teleport locations" --header "Search what?") || return 0
    case "$label" in
        Bots)             kind=bots ;;
        Characters*)      kind=characters ;;
        Guilds)           kind=guilds ;;
        Items)            kind=items ;;
        NPCs)             kind=npcs ;;
        Objects*)         kind=objects ;;
        Quests)           kind=quests ;;
        "Teleport locations") kind=teleports ;;
        *) return 0 ;;
    esac
    local -a args=(search --kind "$kind")
    case "$kind" in
        bots|characters|guilds) term="$(_ask "Name contains (blank for all):")" ;;
        *) term="$(_ask "Name contains:")"; [[ -n "$term" ]] || { info "Cancelled."; return 0; } ;;
    esac
    [[ -n "$term" ]] && args+=(--term "$term")
    if [[ "$kind" == bots || "$kind" == characters ]]; then
        local -a picked=()
        local f v
        mapfile -t picked < <(gum choose --no-limit "zone" "level" "class" "race" "guild" "online only" \
            "roster bots only" "random bots only" --header "Filters (space to pick, enter when done; none is fine):" || true)
        for f in "${picked[@]}"; do
            case "$f" in
                zone)  v="$(_ask "Zone (part of its name, e.g. Durotar):")"; [[ -n "$v" ]] && args+=(--zone "$v") ;;
                level) v="$(_ask "Level, or a range (e.g. 10-20):")";       [[ -n "$v" ]] && args+=(--level "$v") ;;
                class) v=$(gum choose warrior paladin hunter rogue priest shaman mage warlock druid --header "Class:") && args+=(--class "$v") ;;
                race)  v=$(gum choose human dwarf "night elf" gnome orc undead tauren troll --header "Race:") && args+=(--race "$v") ;;
                guild) v="$(_ask "Guild (part of its name):")";             [[ -n "$v" ]] && args+=(--guild "$v") ;;
                "online only")      args+=(--online) ;;
                "roster bots only") args+=(--roster-only) ;;
                "random bots only") args+=(--random-only) ;;
            esac
        done
    fi
    engine_foreground "${args[@]}"
}

# -----------------------------------------------------------------------------
# Roster and bots
# -----------------------------------------------------------------------------

action_roster_apply() {
    header "teldrassil — Apply the roster"
    info "First, what would change:"
    engine_foreground roster plan
    echo ""
    warn "Applying stops the world server for about a minute (everyone is disconnected)."
    gum confirm --default=false "Apply the roster to ${PROFILE_LABEL}?" || { info "Cancelled."; return 0; }
    local -a extra=()
    if gum confirm --default=false "Also replace the WHOLE random-bot population first (new bots at the roster's counts)?"; then
        warn "Every random bot, and every guild a bot leads, is deleted and created anew. The roster's own are rebuilt."
        if gum confirm --default=false "Really replace every random bot?"; then
            extra=(--fresh-population)
        else
            info "Keeping the population; applying the roster only."
        fi
    fi
    engine_foreground roster apply "${extra[@]}" --yes
}

action_attune() {
    header "teldrassil — Attunements"
    info "Bots that meet a rule but lack the attunement:"
    engine_foreground attune plan
    echo ""
    gum confirm --default=false "Grant them? (stops the world server for about a minute)" || { info "Cancelled."; return 0; }
    engine_foreground attune apply --yes
}

action_commands() {
    header "teldrassil — Bot commands"
    info "Plain words go to the LLM, which only talks; bots act on these, typed exactly."
    local which term
    which=$(gum choose "The ones anyone can use" "All of them" --header "Which commands?") || return 0
    term="$(_ask "Containing (blank for all):")"
    local -a args=(commands)
    [[ "$which" == "The ones anyone can use" ]] && args+=(--any)
    [[ -n "$term" ]] && args+=(--search "$term" --verbose)
    engine_foreground "${args[@]}"
}

# -----------------------------------------------------------------------------
# Administration
# -----------------------------------------------------------------------------

_pick_db() {
    gum choose "$(eget DB_WORLD)" "$(eget DB_CHARACTERS)" "$(eget DB_REALMD)" "$(eget DB_LOGS)" --header "$1"
}

action_apply_sql() {
    header "teldrassil — Apply SQL"
    local file db
    file="$(_ask "SQL file to apply:")"
    [[ -n "$file" ]] || { info "Cancelled."; return 0; }
    db="$(_pick_db "Apply it to which database?")" || { info "Cancelled."; return 0; }
    gum confirm --default=false "Apply $(basename "$file") to ${db}?" || { info "Cancelled."; return 0; }
    engine_foreground apply-sql --file "$file" --db "$db"
}

action_dump() {
    header "teldrassil — Dump"
    local what realmd; realmd="$(eget DB_REALMD)"
    what=$(gum choose "All four databases" "World ($(eget DB_WORLD))" "Characters ($(eget DB_CHARACTERS))" \
           "Accounts only (to move them between servers)" "Realm, whole ($(eget DB_REALMD), includes this realm's address)" \
           "Logs ($(eget DB_LOGS))" --header "Dump what?") || return 0
    case "$what" in
        "All four databases") engine_foreground dump --all ;;
        World*)               engine_foreground dump --db "$(eget DB_WORLD)" ;;
        Characters*)          engine_foreground dump --db "$(eget DB_CHARACTERS)" ;;
        # realmlist holds this realm's address: a whole realmd dump restored
        # elsewhere would point that server's clients here.
        "Accounts only"*)     engine_foreground dump --db "$realmd" --tables "account account_banned realmcharacters" ;;
        "Realm, whole"*)      engine_foreground dump --db "$realmd" ;;
        Logs*)                engine_foreground dump --db "$(eget DB_LOGS)" ;;
    esac
}

action_restore() {
    header "teldrassil — Restore"
    local dir="${XDG_CONFIG_HOME:-$HOME/.config}/teldrassil/dumps" pick file
    local -a files=()
    if [[ -d "$dir" ]]; then
        # shellcheck disable=SC2010  # -t sorts by time, which no glob can; these are the engine's own names
        mapfile -t files < <(ls -1t "$dir" 2>/dev/null | grep -E '\.sql(\.gz)?$' || true)
    fi
    pick=$(printf '%s\n' "${files[@]}" "another path..." | gum choose --header "Dump to restore (newest first):") || return 0
    if [[ "$pick" == "another path..." ]]; then file="$(_ask "Path to the dump:")"; else file="${dir}/${pick}"; fi
    [[ -n "$file" ]] || { info "Cancelled."; return 0; }
    local -a dbflag=() head=()
    if [[ "$file" == *.gz ]]; then mapfile -t head < <(gzip -dc -- "$file" 2>/dev/null | head -200 || true)
    else mapfile -t head < <(head -200 -- "$file" 2>/dev/null || true); fi
    if ! printf '%s\n' "${head[@]}" | grep -qiE '^CREATE DATABASE'; then
        local into; into="$(_pick_db "This dump names no database (a table subset) - restore into which?")" || { info "Cancelled."; return 0; }
        dbflag=(--db "$into")
    fi
    warn "RESTORE REPLACES DATA and cannot be undone. The world server must be stopped first."
    gum confirm --default=false "Restore $(basename "$file") onto ${PROFILE_LABEL}?" || { info "Cancelled."; return 0; }
    engine_foreground restore --file "$file" "${dbflag[@]}" --yes
}

# -----------------------------------------------------------------------------
# Menus
# -----------------------------------------------------------------------------

_submenu() {
    local title="$1"; shift
    local -a opts=("$@")
    while true; do
        header "Vanilla WoW (cmangos) — ${title} · ${PROFILE_LABEL}"
        local action
        action=$(printf '%s\n' "${opts[@]}" "back" | gum choose --header "Choose an action:") || true
        [[ -z "$action" || "$action" == "back" ]] && return
        case "$action" in
            start)             engine_foreground start ;;
            stop)              action_stop || true ;;
            restart)           action_restart || true ;;
            status)            engine_foreground status ;;
            save)              engine_foreground save ;;
            console)           action_console || true ;;
            where-is-it)       action_setup || true ;;
            profile)           action_profile || true ;;
            console-account)   gum confirm --default=false "Create (or renew) the console account TELDRASSIL on ${PROFILE_LABEL}?" && engine_foreground console-account ;;
            install)           action_install || true ;;
            source|build-image|build|extract|db-init|configure|create) action_step "$action" || true ;;
            remove)            action_remove || true ;;
            llm)               action_llm || true ;;
            settings)          engine_foreground config ;;
            create-account)    action_create_account || true ;;
            list-accounts)     engine_foreground list-accounts ;;
            set-account-level) action_set_account_level || true ;;
            delete-account)    action_delete_account || true ;;
            rename-character)  action_rename_character || true ;;
            check)             engine_foreground roster check ;;
            plan)              engine_foreground roster plan ;;
            show)              engine_foreground roster show ;;
            apply)             action_roster_apply || true ;;
            attunements)       action_attune || true ;;
            commands)          action_commands || true ;;
            apply-sql)         action_apply_sql || true ;;
            dump)              action_dump || true ;;
            restore)           action_restore || true ;;
        esac
        echo ""
    done
}

main() {
    resolve_engine
    _set_profile "$INITIAL_PROFILE"
    gum style --foreground "$CYAN" --border-foreground "$CYAN" --border double \
        --align center --width 60 --margin "1 2" --padding "1 4" \
        "teldrassil" "vanilla WoW (cmangos + playerbots) — where the bots live"
    while true; do
        local category
        category=$(printf '%s\n' Server Provision Settings Accounts Characters Search Roster Bots Administration Quit \
            | gum choose --header "Choose a category (acting on: ${PROFILE_LABEL}):") || true
        [[ -z "$category" || "$category" == "Quit" ]] && { gum style --faint "Bye."; exit 0; }
        case "$category" in
            Server)         _submenu "Server"         status start stop restart save console ;;
            Provision)      _submenu "Provision"      install source build-image build extract db-init configure create remove ;;
            Settings)       _submenu "Settings"       profile where-is-it console-account settings ;;
            Accounts)       _submenu "Accounts"       create-account list-accounts set-account-level delete-account ;;
            Characters)     _submenu "Characters"     rename-character ;;
            Search)         action_search || true ;;
            Roster)         _submenu "Roster"         show plan check apply ;;
            Bots)           _submenu "Bots"           llm attunements commands ;;
            Administration) _submenu "Administration" dump restore apply-sql ;;
        esac
    done
}

main "$@"
