#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# server.sh
# Builds and runs a VMaNGOS-based vanilla WoW (1.12.1 / client build 5875)
# server from the repack at SOURCE_DIR (default ~/jaws/MaNGOS), natively for
# fast local iteration and as a Docker/k8s deployment for LAN-wide play.
#
# The repack ships compiled Windows binaries (mangosd.exe/realmd.exe) and a
# bundled Windows MySQL, but also its own C++ source
# (source/Repack 25 Source.zip — a standard out-of-source CMake project with
# an official Linux Docker build recipe at contrib/docker-build/). This script
# always builds the native Linux binaries from that source — no Wine, no
# Windows MySQL. The Windows .exe files and mysql5/ directory are unused.
#
# Two independent paths:
#   - Local native (install-deps/configure/start/stop): builds mangosd/realmd
#     directly on this host via cmake+make for fast iteration. ACE toolkit
#     (a hard build dependency) isn't packaged for Fedora/RHEL — this path is
#     Debian/Ubuntu-oriented; on other distros use the Docker path instead.
#   - Container (build-image/run-docker/run-k8s): always builds inside an
#     Ubuntu build stage regardless of host OS, so it works everywhere Docker
#     does. This is the actual LAN-deployable artifact.
#
# The database is always a separate MariaDB container/pod — never bundled
# into the server image, and never installed natively on the host. The same
# DB bootstrap sequence (schemas + world dump + migrations + optional custom
# content) is reused by 'configure' (local dev) and the k8s db-init Job.
#
# Sourced helpers (scripts/_common/):
#   ui.sh          — header/info/success/warn/error_exit
#   deps.sh        — _ensure_pkg/_ensure_pkgs/_pkg_manager (dnf/apt/rpm-ostree)
#   cluster.sh     — select_target (kind/k8s) for run-k8s
#   portforward.sh — pf_is_running/pf_port/pf_stop (PID-file tracking), reused
#                    here for the local mangosd/realmd background processes,
#                    not just port-forwards — the "<pid>:<port>" format fits.
#
# Config: ~/.config/vanilla-wow/vanilla-wow.conf (XDG-style, key=value)
# -----------------------------------------------------------------------------

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMON_DIR="${SCRIPT_DIR}/../_common"
TEMPLATES_DIR="${SCRIPT_DIR}/templates"

# shellcheck source=../_common/ui.sh
source "${COMMON_DIR}/ui.sh"
# shellcheck source=../_common/deps.sh
source "${COMMON_DIR}/deps.sh"
# shellcheck source=../_common/cluster.sh
source "${COMMON_DIR}/cluster.sh"
# shellcheck source=../_common/portforward.sh
source "${COMMON_DIR}/portforward.sh"

trap 'echo ""; gum style --faint "Interrupted."; exit 0' INT TERM

# -----------------------------------------------------------------------------
# Constants / config
# -----------------------------------------------------------------------------

CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/vanilla-wow"
CONFIG_DIR="${CONFIG_DIR/#\~/$HOME}"
CONFIG_FILE="${CONFIG_DIR}/vanilla-wow.conf"
BUILD_DIR="${CONFIG_DIR}/build"
INSTALL_DIR="${CONFIG_DIR}/install"
SRC_UNPACK_DIR="${CONFIG_DIR}/src"
ETC_DIR="${CONFIG_DIR}/etc"
PF_DIR="${CONFIG_DIR}/pf"
MIGRATIONS_MARKER_DIR="${CONFIG_DIR}/applied-migrations"
IMAGE_BUILD_CONTEXT="${CONFIG_DIR}/image-build-context"

mkdir -p "$CONFIG_DIR" "$ETC_DIR" "$PF_DIR" "$MIGRATIONS_MARKER_DIR"

CLIENT_BUILD_DEFAULT=5875

# -----------------------------------------------------------------------------
# Config persistence (flat key=value file, lgtm.sh style — enough knobs here
# that partial get/set beats dozzle.sh's plain whole-file source)
# -----------------------------------------------------------------------------

cfg_get() {
    grep -E "^${1}=" "$CONFIG_FILE" 2>/dev/null | cut -d= -f2- | sed 's/^"\(.*\)"$/\1/' || true
}
cfg_set() {
    local key="$1" val="$2" quoted
    quoted="\"${val}\""
    touch "$CONFIG_FILE"
    if grep -qE "^${key}=" "$CONFIG_FILE" 2>/dev/null; then
        sed -i.bak "s|^${key}=.*|${key}=${quoted}|" "$CONFIG_FILE" && rm -f "${CONFIG_FILE}.bak"
    else
        echo "${key}=${quoted}" >> "$CONFIG_FILE"
    fi
}
cfg_default() {
    # cfg_default KEY DEFAULT — returns existing value or DEFAULT (does not persist)
    local val
    val="$(cfg_get "$1")"
    echo "${val:-$2}"
}

# -----------------------------------------------------------------------------
# Resolved settings (read fresh each invocation so cfg_set changes take effect
# without re-sourcing)
# -----------------------------------------------------------------------------

# Best-effort LAN IP for the realmlist "address" field — the WoW client
# connects to this after authenticating via realmd, so it must be a real,
# reachable IP (not 127.0.0.1, not 0.0.0.0). Falls back to 127.0.0.1 if
# nothing better can be determined (local-only testing).
_detect_lan_ip() {
    ip route get 1.1.1.1 2>/dev/null | grep -oP 'src \K\S+' || echo "127.0.0.1"
}

_settings() {
    SOURCE_DIR="$(cfg_default SOURCE_DIR "${HOME}/jaws/MaNGOS")"
    CLIENT_BUILD="$(cfg_default CLIENT_BUILD "$CLIENT_BUILD_DEFAULT")"
    DB_HOST="$(cfg_default DB_HOST 127.0.0.1)"
    DB_PORT="$(cfg_default DB_PORT 3306)"
    DB_USER="$(cfg_default DB_USER root)"
    DB_PASS="$(cfg_default DB_PASS root)"
    DB_CONTAINER_NAME="$(cfg_default DB_CONTAINER_NAME vanilla-wow-mariadb)"
    DB_VOLUME="$(cfg_default DB_VOLUME vanilla-wow-mariadb-data)"
    REALM_ID="$(cfg_default REALM_ID 1)"
    REALM_PORT="$(cfg_default REALM_PORT 3724)"
    WORLD_PORT="$(cfg_default WORLD_PORT 8085)"
    REALM_ADDRESS="$(cfg_default REALM_ADDRESS "$(_detect_lan_ip)")"
    REALM_NAME="$(cfg_default REALM_NAME "VanillaWoW")"
    REALM_ZONE="$(cfg_default REALM_ZONE 1)"
    GAME_TYPE="$(cfg_default GAME_TYPE 1)"  # matches the repack's own stock default (1 = PvP)
    PLAYER_LIMIT="$(cfg_default PLAYER_LIMIT 100)"
    # WowPatch: content/progression cap (quest, NPC, dungeon, raid data) —
    # distinct from CLIENT_BUILD (what the compiled binary itself supports).
    # 10 = patch 1.12, matching the CLIENT_BUILD_DEFAULT (5875) target.
    WOW_PATCH="$(cfg_default WOW_PATCH 10)"
    MOTD="$(cfg_default MOTD "Welcome to ${REALM_NAME}!")"
    XP_RATE="$(cfg_default XP_RATE 1)"
    DROP_RATE="$(cfg_default DROP_RATE 1)"
    # realmd.conf security/behavior settings — all match the repack's own
    # stock defaults unless changed in 'configure'.
    WRONG_PASS_MAX_COUNT="$(cfg_default WRONG_PASS_MAX_COUNT 0)"
    WRONG_PASS_BAN_TIME="$(cfg_default WRONG_PASS_BAN_TIME 600)"
    WRONG_PASS_BAN_TYPE="$(cfg_default WRONG_PASS_BAN_TYPE 0)"
    REQ_EMAIL_VERIFICATION="$(cfg_default REQ_EMAIL_VERIFICATION 0)"
    STRICT_VERSION_CHECK="$(cfg_default STRICT_VERSION_CHECK 1)"
    # Warden anti-cheat — matches the repack's own stock default (enabled).
    # Controls both Warden.WinEnabled/Warden.OSXEnabled together, a private
    # LAN server has no real use for per-platform cheat detection control.
    WARDEN_ENABLED="$(cfg_default WARDEN_ENABLED 1)"
    IMAGE_TAG="$(cfg_default IMAGE_TAG vanilla-wow-server:latest)"
    SERVER_CONTAINER_NAME="$(cfg_default SERVER_CONTAINER_NAME vanilla-wow-server)"
    K8S_NAMESPACE="$(cfg_default K8S_NAMESPACE vanilla-wow)"
}

# -----------------------------------------------------------------------------
# install-deps
# -----------------------------------------------------------------------------

_ensure_ace() {
    command -v pkg-config &>/dev/null && pkg-config --exists ACE 2>/dev/null && { info "ACE toolkit found."; return 0; }
    [[ -f /usr/include/ace/ACE.h ]] && { info "ACE toolkit found (/usr/include/ace)."; return 0; }

    local pm; pm="$(_pkg_manager)"
    if [[ "$pm" == "apt" ]]; then
        _require_sudo_or_instruct "Installing libace-dev" "sudo apt-get update -qq && sudo apt-get install -y libace-dev"
        sudo apt-get update -qq && sudo apt-get install -y libace-dev \
            && { success "libace-dev installed."; return 0; }
    fi

    warn "ACE toolkit (a hard build dependency for local native builds) isn't packaged for ${pm:-this distro}."
    warn "The local native path (start/stop) needs it; the Docker path (build-image/run-docker/run-k8s) does not"
    warn "— it always builds inside an Ubuntu stage regardless of host OS. Prefer the Docker path on this machine."
    return 1
}

cmd_install_deps() {
    header "vanilla-wow — Install dependencies"

    info "Build toolchain (for the local native path)..."
    _ensure_pkg git    git    git
    _ensure_pkg cmake  cmake  cmake
    _ensure_pkg g++    gcc-c++ g++
    _ensure_pkgs "tbb-devel mariadb-devel openssl-devel zlib-ng-compat-devel p7zip" \
                 "libtbb-dev libmysqlclient-dev libssl-dev zlib1g-dev p7zip-full"
    _ensure_ace || true

    info "Docker (required for the DB container and the Docker/k8s deployment paths)..."
    _check_docker

    success "Dependencies checked."
}

# -----------------------------------------------------------------------------
# DB bootstrap — shared by 'configure' (local) and the k8s db-init Job
# -----------------------------------------------------------------------------

_db_exec() {
    # _db_exec <sql>
    docker exec "$DB_CONTAINER_NAME" mariadb -u"$DB_USER" -p"$DB_PASS" -e "$1"
}

_db_import() {
    # _db_import <database> <file>
    local db="$1" file="$2"
    [[ -f "$file" ]] || { warn "Missing SQL file, skipping: ${file}"; return 0; }
    docker exec -i "$DB_CONTAINER_NAME" mariadb -u"$DB_USER" -p"$DB_PASS" "$db" < "$file"
}

_ensure_local_mariadb() {
    if docker inspect --type container "$DB_CONTAINER_NAME" &>/dev/null; then
        docker start "$DB_CONTAINER_NAME" &>/dev/null || true
    else
        info "Starting local MariaDB container '${DB_CONTAINER_NAME}'..."
        docker run -d \
            --name "$DB_CONTAINER_NAME" \
            -e MARIADB_ROOT_PASSWORD="$DB_PASS" \
            -p "127.0.0.1:${DB_PORT}:3306" \
            -v "${DB_VOLUME}:/var/lib/mysql" \
            --restart unless-stopped \
            mariadb:11 &>/dev/null \
            || error_exit "Failed to start MariaDB container '${DB_CONTAINER_NAME}'."
    fi

    info "Waiting for MariaDB to accept connections..."
    local attempts=0
    until docker exec "$DB_CONTAINER_NAME" mariadb-admin ping -u"$DB_USER" -p"$DB_PASS" --silent &>/dev/null; do
        attempts=$((attempts + 1))
        [[ $attempts -ge 40 ]] && error_exit "Timed out waiting for MariaDB. Check: docker logs ${DB_CONTAINER_NAME}"
        sleep 1
    done
    success "MariaDB ready."
}

# _db_bootstrap — creates schemas, imports Base + world dump + Migrations
# (idempotent via marker files), optionally applies sql/Custom/*.sql.
_db_bootstrap() {
    local sql_dir="${SOURCE_DIR}/sql"
    [[ -d "$sql_dir" ]] || error_exit "sql/ directory not found under SOURCE_DIR: ${sql_dir}"

    info "Creating databases (realmd, mangos, characters, logs) if missing..."
    _db_exec "CREATE DATABASE IF NOT EXISTS realmd; CREATE DATABASE IF NOT EXISTS mangos; CREATE DATABASE IF NOT EXISTS characters; CREATE DATABASE IF NOT EXISTS logs;"

    if [[ ! -f "${MIGRATIONS_MARKER_DIR}/.base-imported" ]]; then
        info "Importing base schemas (sql/Base/*.sql)..."
        gum spin --spinner dot --title "Importing sql/Base/logon.sql -> realmd..." -- \
            bash -c "_db_import() { docker exec -i '${DB_CONTAINER_NAME}' mariadb -u'${DB_USER}' -p'${DB_PASS}' \"\$1\" < \"\$2\"; }; _db_import realmd '${sql_dir}/Base/logon.sql'" \
            || error_exit "Failed to import Base/logon.sql"
        _db_import mangos     "${sql_dir}/Base/world.sql"
        _db_import characters "${sql_dir}/Base/characters.sql"
        _db_import logs       "${sql_dir}/Base/logs.sql"
        touch "${MIGRATIONS_MARKER_DIR}/.base-imported"
        success "Base schemas imported."
    else
        info "Base schemas already imported (marker present) — skipping."
    fi

    # sql/Anticheat/*.sql — despite living next to the optional Custom/
    # content, this is REQUIRED: the repack's Anticheat/Warden/antispam
    # features are always compiled in and mangosd hard-crashes at startup
    # (uncaught C++ exception) if e.g. realmd.antispam_blacklist doesn't
    # exist. Same per-database file naming as Base/.
    if [[ -d "${sql_dir}/Anticheat" ]] && [[ ! -f "${MIGRATIONS_MARKER_DIR}/.anticheat-imported" ]]; then
        info "Importing anticheat schemas (sql/Anticheat/*.sql) — required, not optional..."
        _db_import realmd     "${sql_dir}/Anticheat/realmd.sql"
        _db_import mangos     "${sql_dir}/Anticheat/world.sql"
        _db_import characters "${sql_dir}/Anticheat/characters.sql"
        touch "${MIGRATIONS_MARKER_DIR}/.anticheat-imported"
        success "Anticheat schemas imported."
    else
        info "Anticheat schemas already imported (marker present) — skipping."
    fi

    if [[ ! -f "${MIGRATIONS_MARKER_DIR}/.world-full-imported" ]]; then
        local dump="${sql_dir}/world_full_14_june_2021.sql"
        [[ -f "$dump" ]] || error_exit "World dump not found: ${dump}"
        warn "Importing the full world dump (~250MB) — this can take several minutes."
        gum spin --spinner dot --title "Importing world_full_14_june_2021.sql..." -- \
            docker exec -i "$DB_CONTAINER_NAME" mariadb -u"$DB_USER" -p"$DB_PASS" mangos < "$dump" \
            || error_exit "Failed to import world_full_14_june_2021.sql"
        touch "${MIGRATIONS_MARKER_DIR}/.world-full-imported"
        success "World dump imported."
    else
        info "World dump already imported (marker present) — skipping."
    fi

    # Migrations/ holds per-migration files for all 4 databases, distinguished
    # by suffix (_world.sql -> mangos, _characters.sql -> characters,
    # _logon.sql -> realmd, _logs.sql -> logs), each with a numeric timestamp
    # prefix. It also holds 4 pre-merged "*_db_updates.sql" aggregates (one
    # per database, presumably produced by merge.sh/merge.bat from the
    # individual files) and merge.bat/merge.sh/README — none of those have a
    # numeric prefix, and applying the aggregates on top of the individual
    # migrations would double-apply the same changes, so both are excluded
    # by requiring the ^[0-9]+_ prefix.
    local mfile mname target_db applied=0 skipped=0
    while IFS= read -r mfile; do
        [[ -z "$mfile" ]] && continue
        mname="$(basename "$mfile")"
        if [[ -f "${MIGRATIONS_MARKER_DIR}/${mname}.done" ]]; then
            skipped=$((skipped + 1))
            continue
        fi
        case "$mname" in
            *_world.sql)      target_db=mangos ;;
            *_characters.sql) target_db=characters ;;
            *_logon.sql)      target_db=realmd ;;
            *_logs.sql)       target_db=logs ;;
            *) warn "Skipping migration with unrecognized suffix: ${mname}"; continue ;;
        esac
        _db_import "$target_db" "$mfile" || error_exit "Migration failed: ${mname} (target db: ${target_db})"
        touch "${MIGRATIONS_MARKER_DIR}/${mname}.done"
        applied=$((applied + 1))
    done < <(find "${sql_dir}/Migrations" -maxdepth 1 -name "[0-9]*.sql" 2>/dev/null | sort)
    info "Migrations: ${applied} applied, ${skipped} already up to date."

    if [[ -d "${sql_dir}/Custom" ]] && gum confirm "Apply optional custom content (GM Island vendors/trainers, custom items)?"; then
        local cfile cname
        while IFS= read -r cfile; do
            [[ -z "$cfile" ]] && continue
            cname="$(basename "$cfile")"
            if [[ -f "${MIGRATIONS_MARKER_DIR}/custom-${cname}.done" ]]; then
                continue
            fi
            _db_import mangos "$cfile" || warn "Custom script failed (continuing): ${cname}"
            touch "${MIGRATIONS_MARKER_DIR}/custom-${cname}.done"
            info "Applied: ${cname}"
        done < <(find "${sql_dir}/Custom" -maxdepth 1 -name "*.sql" 2>/dev/null | sort)
        success "Custom content applied."
    fi

    _ensure_realmlist
}

# None of the SQL dumps seed the realmlist table — the realm's reachable
# address/port is inherently deployment-specific, so every MaNGOS-family
# server needs this set by the operator. Without it mangosd refuses to start
# ("Config contains invalid realmID"). ON DUPLICATE KEY UPDATE keeps this in
# sync with the current REALM_ADDRESS/WORLD_PORT/CLIENT_BUILD on every run.
_ensure_realmlist() {
    info "Ensuring realmlist row (id=${REALM_ID}, name=${REALM_NAME}, address=${REALM_ADDRESS}:${WORLD_PORT})..."
    _db_exec "INSERT INTO realmd.realmlist (id, name, address, localAddress, localSubnetMask, port, gamebuild_min, gamebuild_max)
        VALUES (${REALM_ID}, '${REALM_NAME}', '${REALM_ADDRESS}', '127.0.0.1', '255.255.255.0', ${WORLD_PORT}, ${CLIENT_BUILD}, ${CLIENT_BUILD})
        ON DUPLICATE KEY UPDATE name='${REALM_NAME}', address='${REALM_ADDRESS}', port=${WORLD_PORT}, gamebuild_min=${CLIENT_BUILD}, gamebuild_max=${CLIENT_BUILD};" \
        || error_exit "Failed to write the realmlist row."
    success "realmlist ready."
}

# -----------------------------------------------------------------------------
# Config file generation — patches the repack's stock conf files rather than
# hand-authoring new ones (they're 3000+ lines of documented settings; only a
# handful need to change for a containerized/local deployment).
# -----------------------------------------------------------------------------

# _render_mangosd_conf <src> <dst> <data_dir> <logs_dir> <warden_dir>
_render_mangosd_conf() {
    local src="$1" dst="$2" data_dir="$3" logs_dir="$4" warden_dir="$5"
    local motd_escaped; motd_escaped="$(_sed_escape "$MOTD")"
    cp "$src" "$dst"
    # The repack's conf files ship with Windows CRLF line endings (they were
    # distributed alongside .exe binaries). Left as-is, sed's substitutions
    # below strip the trailing \r only on the handful of lines they touch
    # (matched by .* and not present in the replacement) while every other
    # line keeps its \r — a mixed-line-ending file, which shows up as a wall
    # of ^M in vim/cmd_edit and is generally fragile. Normalize to LF first.
    sed -i 's/\r$//' "$dst"
    sed -i \
        -e "s|^DataDir[[:space:]]*=.*|DataDir = \"${data_dir}\"|" \
        -e "s|^LogsDir[[:space:]]*=.*|LogsDir = \"${logs_dir}\"|" \
        -e "s|^Warden\.ModuleDir[[:space:]]*=.*|Warden.ModuleDir             = \"${warden_dir}\"|" \
        -e "s|^Warden\.WinEnabled[[:space:]]*=.*|Warden.WinEnabled            = ${WARDEN_ENABLED}|" \
        -e "s|^Warden\.OSXEnabled[[:space:]]*=.*|Warden.OSXEnabled            = ${WARDEN_ENABLED}|" \
        -e "s|^LoginDatabase\.Info[[:space:]]*=.*|LoginDatabase.Info              = \"${DB_HOST};${DB_PORT};${DB_USER};${DB_PASS};realmd\"|" \
        -e "s|^WorldDatabase\.Info[[:space:]]*=.*|WorldDatabase.Info              = \"${DB_HOST};${DB_PORT};${DB_USER};${DB_PASS};mangos\"|" \
        -e "s|^CharacterDatabase\.Info[[:space:]]*=.*|CharacterDatabase.Info          = \"${DB_HOST};${DB_PORT};${DB_USER};${DB_PASS};characters\"|" \
        -e "s|^LogsDatabase\.Info[[:space:]]*=.*|LogsDatabase.Info               = \"${DB_HOST};${DB_PORT};${DB_USER};${DB_PASS};logs\"|" \
        -e "s|^WorldServerPort[[:space:]]*=.*|WorldServerPort = ${WORLD_PORT}|" \
        -e "s|^RealmID[[:space:]]*=.*|RealmID = ${REALM_ID}|" \
        -e "s|^GameType[[:space:]]*=.*|GameType = ${GAME_TYPE}|" \
        -e "s|^RealmZone[[:space:]]*=.*|RealmZone = ${REALM_ZONE}|" \
        -e "s|^PlayerLimit[[:space:]]*=.*|PlayerLimit = ${PLAYER_LIMIT}|" \
        -e "s|^WowPatch[[:space:]]*=.*|WowPatch = ${WOW_PATCH}|" \
        -e "s|^Motd[[:space:]]*=.*|Motd = \"${motd_escaped}\"|" \
        -e "s|^Rate\.XP\.Kill[[:space:]]*=.*|Rate.XP.Kill    = ${XP_RATE}|" \
        -e "s|^Rate\.XP\.Kill\.Elite[[:space:]]*=.*|Rate.XP.Kill.Elite = ${XP_RATE}|" \
        -e "s|^Rate\.XP\.Quest[[:space:]]*=.*|Rate.XP.Quest   = ${XP_RATE}|" \
        -e "s|^Rate\.XP\.Explore[[:space:]]*=.*|Rate.XP.Explore = ${XP_RATE}|" \
        -e "s|^Rate\.Drop\.Item\.Poor[[:space:]]*=.*|Rate.Drop.Item.Poor = ${DROP_RATE}|" \
        -e "s|^Rate\.Drop\.Item\.Normal[[:space:]]*=.*|Rate.Drop.Item.Normal = ${DROP_RATE}|" \
        -e "s|^Rate\.Drop\.Item\.Uncommon[[:space:]]*=.*|Rate.Drop.Item.Uncommon = ${DROP_RATE}|" \
        -e "s|^Rate\.Drop\.Item\.Rare[[:space:]]*=.*|Rate.Drop.Item.Rare = ${DROP_RATE}|" \
        -e "s|^Rate\.Drop\.Item\.Epic[[:space:]]*=.*|Rate.Drop.Item.Epic = ${DROP_RATE}|" \
        -e "s|^Rate\.Drop\.Item\.Legendary[[:space:]]*=.*|Rate.Drop.Item.Legendary = ${DROP_RATE}|" \
        -e "s|^Rate\.Drop\.Item\.Artifact[[:space:]]*=.*|Rate.Drop.Item.Artifact = ${DROP_RATE}|" \
        -e "s|^Rate\.Drop\.Item\.Referenced[[:space:]]*=.*|Rate.Drop.Item.Referenced = ${DROP_RATE}|" \
        -e "s|^Rate\.Drop\.Money[[:space:]]*=.*|Rate.Drop.Money = ${DROP_RATE}|" \
        "$dst"
}

# _render_realmd_conf <src> <dst> <logs_dir>
_render_realmd_conf() {
    local src="$1" dst="$2" logs_dir="$3"
    cp "$src" "$dst"
    # See the matching comment in _render_mangosd_conf — same CRLF-source,
    # mixed-line-ending issue applies here too.
    sed -i 's/\r$//' "$dst"
    sed -i \
        -e "s|^LogsDir[[:space:]]*=.*|LogsDir = \"${logs_dir}\"|" \
        -e "s|^LoginDatabaseInfo[[:space:]]*=.*|LoginDatabaseInfo = \"${DB_HOST};${DB_PORT};${DB_USER};${DB_PASS};realmd\"|" \
        -e "s|^RealmServerPort[[:space:]]*=.*|RealmServerPort = ${REALM_PORT}|" \
        -e "s|^WrongPass\.MaxCount[[:space:]]*=.*|WrongPass.MaxCount = ${WRONG_PASS_MAX_COUNT}|" \
        -e "s|^WrongPass\.BanTime[[:space:]]*=.*|WrongPass.BanTime = ${WRONG_PASS_BAN_TIME}|" \
        -e "s|^WrongPass\.BanType[[:space:]]*=.*|WrongPass.BanType = ${WRONG_PASS_BAN_TYPE}|" \
        -e "s|^ReqEmailVerification[[:space:]]*=.*|ReqEmailVerification = ${REQ_EMAIL_VERIFICATION}|" \
        -e "s|^StrictVersionCheck[[:space:]]*=.*|StrictVersionCheck = ${STRICT_VERSION_CHECK}|" \
        "$dst"
}

# _effective_conf_source <filename> — prefer the already-configured copy
# under ETC_DIR (which carries both the 'configure' prompts and any manual
# `edit` tweaks) over the repack's pristine file. Used by the deploy paths
# (run-docker/run-k8s) so a hand edit isn't silently discarded on the next
# build/deploy; 'configure' itself always re-derives from the pristine
# SOURCE_DIR file, since re-establishing the baseline is its whole job.
_effective_conf_source() {
    local filename="$1"
    if [[ -f "${ETC_DIR}/${filename}" ]]; then
        echo "${ETC_DIR}/${filename}"
    else
        echo "${SOURCE_DIR}/${filename}"
    fi
}

# -----------------------------------------------------------------------------
# configure
# -----------------------------------------------------------------------------


# Value/label picker — presents labels via gum choose, echoes the matching
# value on stdout. Used for RealmZone/GameType, where the numeric value
# mangosd.conf actually wants isn't self-explanatory on its own.
# _pick_value_label <header> <current-value> <default-label-on-cancel> "value|Label" ...
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

# _pick_gm_level <header> <current> — account security level picker, using
# the actual scale confirmed directly from src/shared/Common.h's
# AccountTypes enum (0 Player, 1 Moderator, 2 Ticketmaster, 3 Gamemaster,
# 4 Basic Admin, 5 Developer, 6 Administrator), not the 4-level Player/
# Moderator/Gamemaster/Admin scale this originally (and wrongly) exposed —
# found live when a user needed level 6 for most in-game GM commands and
# the old picker topped out at what was actually level 3 (Gamemaster).
# SEC_CONSOLE (7) is deliberately excluded — the source itself says real
# accounts must stay below it ("must be always last in list, accounts must
# have less security level always also").
_pick_gm_level() {
    local hdr="$1" current="$2"
    _pick_value_label "$hdr" "$current" "Player" \
        "0|Player (no GM powers)" "1|Moderator" "2|Ticketmaster" "3|Gamemaster" \
        "4|Basic Admin" "5|Developer" "6|Administrator (full GM access)"
}

# Prompts for the server-identity/gameplay settings mangosd.conf actually
# needs beyond DB wiring — realm name/zone, game type, player cap, and the
# progression content patch. Values persist and pre-fill on future runs, so
# re-running configure to pick up new SQL doesn't force re-answering these
# every time — just confirm-or-change like the rest of configure already works.
_prompt_server_settings() {
    local name_input
    name_input=$(gum input --value "$REALM_NAME" --header "Realm name (shown in the realm list):") || true
    REALM_NAME="${name_input:-$REALM_NAME}"
    cfg_set REALM_NAME "$REALM_NAME"

    REALM_ZONE=$(_pick_value_label "Realm zone (character-name alphabet / client compatibility)" "$REALM_ZONE" "Development" \
        "1|Development (any language)" "2|United States" "3|Oceanic" "4|Latin America" \
        "6|Korea" "8|English" "9|German" "10|French" "11|Spanish" "12|Russian" \
        "14|Taiwan" "16|China" "26|Test Server" "28|QA Server")
    cfg_set REALM_ZONE "$REALM_ZONE"

    GAME_TYPE=$(_pick_value_label "Realm style" "$GAME_TYPE" "Normal" \
        "0|Normal" "1|PvP" "6|RP" "8|RP-PvP" "16|FFA PvP (custom — arena rules everywhere)")
    cfg_set GAME_TYPE "$GAME_TYPE"

    local limit_input
    limit_input=$(gum input --value "$PLAYER_LIMIT" \
        --header "Player limit (0 = infinite, -1 = mods/GMs/admins only, -2 = GMs/admins only, -3 = admins only):") || true
    PLAYER_LIMIT="${limit_input:-$PLAYER_LIMIT}"
    cfg_set PLAYER_LIMIT "$PLAYER_LIMIT"

    WOW_PATCH=$(_pick_value_label "Progression content patch (quest/NPC/dungeon/raid data — independent of the compiled client build)" "$WOW_PATCH" "1.12" \
        "0|1.2" "1|1.3" "2|1.4" "3|1.5" "4|1.6" "5|1.7" "6|1.8" "7|1.9" "8|1.10" "9|1.11" "10|1.12")
    cfg_set WOW_PATCH "$WOW_PATCH"

    # MOTD — strip literal quotes so it can't break the conf file's own
    # quoting; sed-escaping (|, &) happens in _render_mangosd_conf itself.
    local motd_input
    motd_input=$(gum input --value "$MOTD" --header "Message of the day (shown at login):") || true
    MOTD="${motd_input:-$MOTD}"
    MOTD="${MOTD//\"/}"
    cfg_set MOTD "$MOTD"

    # A single multiplier is applied to every leveling-XP source
    # (kill/kill-elite/quest/explore) and every loot source (money + all
    # item-quality drop rates) — exposing the ~13 underlying Rate.* knobs
    # individually would be a lot of prompts for something almost nobody
    # tunes separately from "2x server" / "half rate server".
    local xp_input drop_input
    xp_input=$(gum input --value "$XP_RATE" --header "XP rate multiplier (1 = normal, 2 = double, 0.5 = half):") || true
    XP_RATE="${xp_input:-$XP_RATE}"
    cfg_set XP_RATE "$XP_RATE"

    drop_input=$(gum input --value "$DROP_RATE" --header "Loot/gold drop rate multiplier (1 = normal, 2 = double, 0.5 = half):") || true
    DROP_RATE="${drop_input:-$DROP_RATE}"
    cfg_set DROP_RATE "$DROP_RATE"

    # realmd.conf — login/security behavior.
    local wp_count_input wp_time_input
    wp_count_input=$(gum input --value "$WRONG_PASS_MAX_COUNT" \
        --header "Wrong-password attempts before a ban (0 = disabled):") || true
    WRONG_PASS_MAX_COUNT="${wp_count_input:-$WRONG_PASS_MAX_COUNT}"
    cfg_set WRONG_PASS_MAX_COUNT "$WRONG_PASS_MAX_COUNT"

    if [[ "$WRONG_PASS_MAX_COUNT" != "0" ]]; then
        wp_time_input=$(gum input --value "$WRONG_PASS_BAN_TIME" --header "Ban duration in seconds:") || true
        WRONG_PASS_BAN_TIME="${wp_time_input:-$WRONG_PASS_BAN_TIME}"
        cfg_set WRONG_PASS_BAN_TIME "$WRONG_PASS_BAN_TIME"

        WRONG_PASS_BAN_TYPE=$(_pick_value_label "Ban target" "$WRONG_PASS_BAN_TYPE" "Ban IP" \
            "0|Ban IP" "1|Ban Account")
        cfg_set WRONG_PASS_BAN_TYPE "$WRONG_PASS_BAN_TYPE"
    fi

    # _pick_value_label, not gum confirm: a cancelled/no-TTY gum confirm
    # always resolves false, which would force these to "off" on every run
    # regardless of the actual current/stock value (same bug class already
    # caught once with GAME_TYPE) — _pick_value_label correctly falls back
    # to whatever the current value already is instead.
    REQ_EMAIL_VERIFICATION=$(_pick_value_label "Require email verification before login" "$REQ_EMAIL_VERIFICATION" "No" \
        "0|No" "1|Yes")
    cfg_set REQ_EMAIL_VERIFICATION "$REQ_EMAIL_VERIFICATION"

    STRICT_VERSION_CHECK=$(_pick_value_label "Reject modified/mismatched game clients (strict version check)" "$STRICT_VERSION_CHECK" "Yes" \
        "1|Yes" "0|No")
    cfg_set STRICT_VERSION_CHECK "$STRICT_VERSION_CHECK"

    WARDEN_ENABLED=$(_pick_value_label "Warden anti-cheat (client-side scans; irrelevant on a private/trusted LAN server)" "$WARDEN_ENABLED" "Enabled" \
        "1|Enabled" "0|Disabled")
    cfg_set WARDEN_ENABLED "$WARDEN_ENABLED"
}

cmd_configure() {
    header "vanilla-wow — Configure"
    _settings

    local src_input
    src_input=$(gum input --value "$SOURCE_DIR" --header "Path to the repack (contains mangosd.conf, sql/, data/):") || true
    SOURCE_DIR="${src_input:-$SOURCE_DIR}"
    [[ -d "$SOURCE_DIR" ]] || error_exit "SOURCE_DIR not found: ${SOURCE_DIR}"
    [[ -f "${SOURCE_DIR}/mangosd.conf" && -f "${SOURCE_DIR}/realmd.conf" ]] \
        || error_exit "mangosd.conf/realmd.conf not found under ${SOURCE_DIR} — is this really the repack root?"
    cfg_set SOURCE_DIR "$SOURCE_DIR"

    local addr_input
    addr_input=$(gum input --value "$REALM_ADDRESS" \
        --header "LAN-reachable address for this realm (what WoW clients connect to after login):") || true
    REALM_ADDRESS="${addr_input:-$REALM_ADDRESS}"
    cfg_set REALM_ADDRESS "$REALM_ADDRESS"

    _prompt_server_settings

    _check_docker
    _ensure_local_mariadb
    _db_bootstrap

    info "Generating local conf files (native start/stop path)..."
    mkdir -p "$INSTALL_DIR"
    # Warden.ModuleDir points straight at the repack's own warden_modules —
    # local native runs directly against SOURCE_DIR, no copy/mount needed.
    _render_mangosd_conf "${SOURCE_DIR}/mangosd.conf" "${ETC_DIR}/mangosd.conf" "${INSTALL_DIR}/data" "${INSTALL_DIR}/logs" "${SOURCE_DIR}/warden_modules"
    _render_realmd_conf  "${SOURCE_DIR}/realmd.conf"  "${ETC_DIR}/realmd.conf"  "${INSTALL_DIR}/logs"
    success "Conf files written to ${ETC_DIR}."

    success "Configure complete. Run 'start' to build and launch the local server."
}

# -----------------------------------------------------------------------------
# start / stop — native local build (cmake+make, cached) for fast iteration
# -----------------------------------------------------------------------------

_unpack_source() {
    if [[ -f "${SRC_UNPACK_DIR}/CMakeLists.txt" ]]; then
        return 0
    fi
    local zip="${SOURCE_DIR}/source/Repack 25 Source.zip"
    [[ -f "$zip" ]] || error_exit "Source zip not found: ${zip}"
    mkdir -p "$SRC_UNPACK_DIR"
    info "Unpacking VMaNGOS source (one-time)..."
    gum spin --spinner dot --title "Unzipping source..." -- \
        unzip -q -o "$zip" -d "$SRC_UNPACK_DIR" \
        || error_exit "Failed to unpack ${zip}"
}

_build_native() {
    _unpack_source
    mkdir -p "$BUILD_DIR"
    export ACE_ROOT="${ACE_ROOT:-/usr/include/ace}"
    export TBB_ROOT_DIR="${TBB_ROOT_DIR:-/usr/include/tbb}"

    info "Configuring (cmake, client build ${CLIENT_BUILD})..."
    gum spin --spinner dot --title "cmake configure..." -- \
        cmake -S "$SRC_UNPACK_DIR" -B "$BUILD_DIR" \
            -DDEBUG=0 -DUSE_EXTRACTORS=0 \
            -DSUPPORTED_CLIENT_BUILD="${CLIENT_BUILD}" \
            -DCMAKE_INSTALL_PREFIX="$INSTALL_DIR" \
        || error_exit "cmake configure failed. See output above."

    local jobs; jobs="$(nproc 2>/dev/null || echo 2)"
    info "Building (make -j${jobs}) — first build compiles ~1600 files, this takes a while..."
    gum spin --spinner dot --title "Building mangosd/realmd..." -- \
        bash -c "make -C '${BUILD_DIR}' -j${jobs} && make -C '${BUILD_DIR}' install" \
        || error_exit "Build failed. Re-run with 'make -C ${BUILD_DIR}' to see full compiler output."

    success "Built and installed to ${INSTALL_DIR}."
}

cmd_start() {
    header "vanilla-wow — Start (local)"
    _settings

    [[ -f "${ETC_DIR}/mangosd.conf" ]] || error_exit "Not configured yet — run 'configure' first."
    _ensure_local_mariadb

    if [[ ! -x "${INSTALL_DIR}/bin/mangosd" || ! -x "${INSTALL_DIR}/bin/realmd" ]]; then
        _build_native
    else
        info "Using existing build at ${INSTALL_DIR} (delete it to force a rebuild)."
    fi

    mkdir -p "${INSTALL_DIR}/logs"
    cp -f "${ETC_DIR}/mangosd.conf" "${INSTALL_DIR}/bin/mangosd.conf"
    cp -f "${ETC_DIR}/realmd.conf"  "${INSTALL_DIR}/bin/realmd.conf"

    local realmd_pf="${PF_DIR}/realmd.pid" mangosd_pf="${PF_DIR}/mangosd.pid"

    # < <(sleep infinity): mangosd/realmd run an interactive console reader
    # on stdin. A backgrounded process normally inherits this shell's stdin,
    # which under nohup/non-interactive invocation delivers an immediate
    # EOF — the console reads that as an implicit quit, so the server fully
    # starts and then shuts itself down seconds later. Feeding stdin from a
    # process substitution that never writes and never exits keeps it open
    # without ever producing EOF (the container path hits the same issue —
    # fixed there with 'docker run -i' / pod stdin: true).
    if pf_is_running "$realmd_pf"; then
        warn "realmd already running (pid file present)."
    else
        (cd "${INSTALL_DIR}/bin" && nohup ./realmd >> "${INSTALL_DIR}/logs/realmd.out" 2>&1 < <(sleep infinity) &
         echo "$!:${REALM_PORT}" > "$realmd_pf")
        sleep 1
        pf_is_running "$realmd_pf" && success "realmd started (port ${REALM_PORT})." || warn "realmd did not start — check ${INSTALL_DIR}/logs/realmd.out"
    fi

    if pf_is_running "$mangosd_pf"; then
        warn "mangosd already running (pid file present)."
    else
        # mangosd gets a real FIFO instead of the sleep-infinity trick, so
        # 'create-account' can still reach its console. Unlike the container
        # path (where entrypoint.sh's own long-lived PID 1 process holds the
        # FIFO's write end open for free), this command returns immediately
        # after backgrounding mangosd, so nothing would otherwise keep a
        # writer attached — the FIFO would report EOF to mangosd on its next
        # read and trigger the same implicit-quit bug this whole thing exists
        # to avoid. A small detached 'sleep infinity' holds fd 9 open on the
        # FIFO for as long as mangosd itself is meant to run; 'stop' kills it
        # alongside mangosd.
        local mangosd_fifo="${INSTALL_DIR}/bin/mangosd.stdin"
        rm -f "$mangosd_fifo"
        mkfifo "$mangosd_fifo"
        ( exec 9<>"$mangosd_fifo"; exec sleep infinity ) &
        echo "$!" > "${PF_DIR}/mangosd-stdin-holder.pid"

        (cd "${INSTALL_DIR}/bin" && nohup ./mangosd >> "${INSTALL_DIR}/logs/mangosd.out" 2>&1 < "$mangosd_fifo" &
         echo "$!:${WORLD_PORT}" > "$mangosd_pf")
        sleep 1
        pf_is_running "$mangosd_pf" && success "mangosd started (port ${WORLD_PORT})." || warn "mangosd did not start — check ${INSTALL_DIR}/logs/mangosd.out"
    fi

    info "Logs: ${INSTALL_DIR}/logs/{realmd,mangosd}.out"
}

cmd_stop() {
    header "vanilla-wow — Stop (local)"
    _settings

    local realmd_pf="${PF_DIR}/realmd.pid" mangosd_pf="${PF_DIR}/mangosd.pid"
    local holder_pf="${PF_DIR}/mangosd-stdin-holder.pid"

    if pf_is_running "$mangosd_pf"; then pf_stop "$mangosd_pf"; else info "mangosd not running."; fi
    if pf_is_running "$realmd_pf";  then pf_stop "$realmd_pf";  else info "realmd not running.";  fi

    # Companion 'sleep infinity' that kept mangosd's console FIFO writable
    # (see 'start') — no longer needed once mangosd itself is stopped.
    if [[ -f "$holder_pf" ]]; then
        kill "$(cat "$holder_pf")" 2>/dev/null || true
        rm -f "$holder_pf"
    fi
    rm -f "${INSTALL_DIR}/bin/mangosd.stdin"
}

cmd_status() {
    header "vanilla-wow — Status"
    _settings

    gum style --foreground "${CYAN}" --bold "── Local MariaDB"
    docker inspect --type container "$DB_CONTAINER_NAME" --format='{{.State.Status}}' 2>/dev/null || warn "Not created."

    gum style --foreground "${CYAN}" --bold "── Local native processes"
    pf_is_running "${PF_DIR}/realmd.pid"  && success "realmd running (port $(pf_port "${PF_DIR}/realmd.pid"))"  || info "realmd not running."
    pf_is_running "${PF_DIR}/mangosd.pid" && success "mangosd running (port $(pf_port "${PF_DIR}/mangosd.pid"))" || info "mangosd not running."

    # --type container: SERVER_CONTAINER_NAME and IMAGE_TAG share a base
    # name ("vanilla-wow-server"), and plain 'docker inspect' falls back to
    # matching images when no container matches — without this it would
    # always report the image's (unrelated) state here instead of "Not created".
    gum style --foreground "${CYAN}" --bold "── Server container"
    docker inspect --type container "$SERVER_CONTAINER_NAME" --format='{{.State.Status}}' 2>/dev/null || info "Not created."

    gum style --foreground "${CYAN}" --bold "── Docker image"
    docker image inspect "$IMAGE_TAG" --format='{{.Id}}' 2>/dev/null || info "Not built."

    # realmlist.wtf syntax: 'set realmlist <address>[:<port>]' — the port
    # suffix is only needed when it's non-standard, the client already
    # assumes 3724 if omitted.
    gum style --foreground "${CYAN}" --bold "── Client setup"
    local realmlist_value="$REALM_ADDRESS"
    [[ "$REALM_PORT" != "3724" ]] && realmlist_value+=":${REALM_PORT}"
    info "In the client's WTF/realmlist.wtf, set:"
    gum style --bold "  set realmlist ${realmlist_value}"
}

# -----------------------------------------------------------------------------
# create-account / list-accounts / delete-account — accounts live in the
# realmd DB with SRP6 verifier/salt columns, not a hash that's safe to
# compute by hand, so any command that creates or removes one goes through
# mangosd's own console instead ('account create'/'account delete', same as
# the repack's own README and the source's command table use), via the FIFO
# set up in 'start'/entrypoint.sh. Listing doesn't touch credentials at all,
# so that one queries the DB directly instead — there's no console command
# for it anyway (only 'account onlinelist', currently-connected accounts
# only, confirmed by checking the source's command table directly rather
# than guessing).
# -----------------------------------------------------------------------------

# _detect_running_target — echoes "local"/"docker"/"k8s" on stdout for
# whichever deployment mangosd is actually running in right now, prompting
# if more than one qualifies. warn+return 1 if none does. Shared by every
# command below that needs to reach a live mangosd console.
_detect_running_target() {
    local -a targets=()
    pf_is_running "${PF_DIR}/mangosd.pid" && targets+=("local")
    [[ "$(docker inspect --type container "$SERVER_CONTAINER_NAME" --format='{{.State.Status}}' 2>/dev/null)" == "running" ]] \
        && targets+=("docker")
    if command -v kubectl &>/dev/null; then
        kubectl get pods -n "$K8S_NAMESPACE" -l app=vanilla-wow-server --no-headers 2>/dev/null | grep -q Running \
            && targets+=("k8s")
    fi

    if [[ ${#targets[@]} -eq 0 ]]; then
        warn "mangosd doesn't appear to be running anywhere (checked local, docker, k8s). Start it first."
        return 1
    fi

    local chosen="${targets[0]}"
    if [[ ${#targets[@]} -gt 1 ]]; then
        chosen=$(printf '%s\n' "${targets[@]}" | gum choose --header "mangosd is running in more than one place. Which one?") || true
        if [[ -z "$chosen" ]]; then
            warn "No target selected."
            return 1
        fi
    fi

    # k8s only: resolve once here, rather than in every caller — K8S_CTX_FLAGS/
    # K8S_POD are globals _send_console_cmd/_db_query read for the k8s case.
    K8S_CTX_FLAGS="" K8S_POD=""
    if [[ "$chosen" == "k8s" ]]; then
        K8S_CTX_FLAGS="$(kubectl_context_flag)"
        K8S_POD=$(kubectl $K8S_CTX_FLAGS get pods -n "$K8S_NAMESPACE" -l app=vanilla-wow-server -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
        if [[ -z "$K8S_POD" ]]; then
            warn "No running vanilla-wow-server pod found in namespace ${K8S_NAMESPACE}."
            return 1
        fi
    fi

    echo "$chosen"
}

# _detect_db_target — like _detect_running_target, but for queries that only
# need the database, not mangosd itself (e.g. search, which reads static
# reference tables that don't require the server to be up at all). Local
# native and Docker share the exact same local MariaDB container, so unlike
# _detect_running_target there's nothing to disambiguate between them —
# echoes "docker" for that shared container, "k8s" for the cluster's own
# separate MariaDB pod.
_detect_db_target() {
    if [[ "$(docker inspect --type container "$DB_CONTAINER_NAME" --format='{{.State.Status}}' 2>/dev/null)" == "running" ]]; then
        echo "docker"
        return 0
    fi
    if command -v kubectl &>/dev/null; then
        if kubectl get pods -n "$K8S_NAMESPACE" -l app=vanilla-wow-mariadb --no-headers 2>/dev/null | grep -q Running; then
            echo "k8s"
            return 0
        fi
    fi
    warn "No reachable database found (checked the local MariaDB container and K8s). Run 'configure' or 'run-k8s' first."
    return 1
}

# Escapes a value for embedding inside a single-quoted SQL string literal
# (backslash first, so it isn't double-escaped by the quote pass after it).
_sql_escape() { printf '%s' "$1" | sed -e "s/\\\\/\\\\\\\\/g" -e "s/'/\\\\'/g"; }

# _db_query <target: local|docker|k8s> <sql> — local/docker share the same
# local MariaDB container (_db_exec); k8s has its own separate MariaDB pod
# in the cluster (see the architecture note on templates/k8s/mariadb.yaml),
# so that one needs its own kubectl exec instead of _db_exec's docker exec.
_db_query() {
    local tgt="$1" sql="$2"
    case "$tgt" in
        local|docker)
            # -t (table format), not _db_exec's plain tab-separated output —
            # every _db_query caller is a human-facing read, not the DB
            # bootstrap machinery _db_exec also serves.
            docker exec "$DB_CONTAINER_NAME" mariadb -u"$DB_USER" -p"$DB_PASS" -t -e "$sql"
            ;;
        k8s)
            local ctx_flags pod
            ctx_flags="$(kubectl_context_flag)"
            pod=$(kubectl $ctx_flags get pods -n "$K8S_NAMESPACE" -l app=vanilla-wow-mariadb -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
            if [[ -z "$pod" ]]; then
                warn "No running vanilla-wow-mariadb pod found in namespace ${K8S_NAMESPACE}."
                return 1
            fi
            kubectl $ctx_flags exec -n "$K8S_NAMESPACE" "$pod" -- mariadb -u"$DB_USER" -p"$DB_PASS" -t -e "$sql"
            ;;
    esac
}

# _db_query_raw <target> <sql> — like _db_query, but -N -B (no column
# headers, tab-separated, no ASCII table borders) for callers that need to
# actually parse a single value out of the result, not display it.
_db_query_raw() {
    local tgt="$1" sql="$2"
    case "$tgt" in
        local|docker)
            docker exec "$DB_CONTAINER_NAME" mariadb -u"$DB_USER" -p"$DB_PASS" -N -B -e "$sql"
            ;;
        k8s)
            local ctx_flags pod
            ctx_flags="$(kubectl_context_flag)"
            pod=$(kubectl $ctx_flags get pods -n "$K8S_NAMESPACE" -l app=vanilla-wow-mariadb -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
            if [[ -z "$pod" ]]; then
                warn "No running vanilla-wow-mariadb pod found in namespace ${K8S_NAMESPACE}."
                return 1
            fi
            kubectl $ctx_flags exec -n "$K8S_NAMESPACE" "$pod" -- mariadb -u"$DB_USER" -p"$DB_PASS" -N -B -e "$sql"
            ;;
    esac
}

# _send_console_cmd <local|docker|k8s> <single console command line>
# Globals used for the k8s case: K8S_CTX_FLAGS, K8S_POD (set by the caller).
_send_console_cmd() {
    local tgt="$1" line="$2"
    case "$tgt" in
        local)
            local fifo="${INSTALL_DIR}/bin/mangosd.stdin"
            if [[ ! -p "$fifo" ]]; then
                warn "mangosd's console FIFO isn't there (${fifo}). Was it started via this script's 'start'?"
                return 1
            fi
            printf '%s\n' "$line" > "$fifo"
            ;;
        docker)
            printf '%s\n' "$line" | docker exec -i "$SERVER_CONTAINER_NAME" sh -c "cat > /app/mangosd.stdin" \
                || { warn "Failed to reach the container's console FIFO."; return 1; }
            ;;
        k8s)
            printf '%s\n' "$line" | kubectl $K8S_CTX_FLAGS exec -i -n "$K8S_NAMESPACE" "$K8S_POD" -- sh -c "cat > /app/mangosd.stdin" \
                || { warn "Failed to reach the pod's console FIFO."; return 1; }
            ;;
    esac
}

cmd_create_account() {
    header "vanilla-wow — Create account"
    _settings

    local target
    target=$(_detect_running_target) || return 1

    local user_input pass_input
    user_input=$(gum input --placeholder "username" --header "New account username:") || true
    [[ -z "$user_input" ]] && { info "Cancelled."; return 1; }

    pass_input=$(gum input --password --placeholder "password" --header "New account password:") || true
    [[ -z "$pass_input" ]] && { info "Cancelled."; return 1; }

    local gm_num
    gm_num=$(_pick_gm_level "Account access level" "0")

    # 'account create' and 'account set gmlevel' can't be sent as one burst:
    # live-tested, sending both in a single write reliably fails the gmlevel
    # half with "Account not exist" — the newly created account isn't visible
    # to the very next console command yet (an in-memory cache/registration
    # lag, not a DB write issue, the account itself is created correctly
    # either way). A few seconds between the two is enough.
    _send_console_cmd "$target" "account create ${user_input} ${pass_input}" || return 1

    if [[ "$gm_num" != "0" ]]; then
        sleep 3
        _send_console_cmd "$target" "account set gmlevel ${user_input} ${gm_num}" || return 1
    fi

    case "$target" in
        local)  info "Check ${INSTALL_DIR}/logs/mangosd.out to confirm." ;;
        docker) info "Check: docker logs ${SERVER_CONTAINER_NAME}" ;;
        k8s)    info "Check: kubectl -n ${K8S_NAMESPACE} logs ${K8S_POD}" ;;
    esac

    success "Account '${user_input}' created (GM level: ${gm_num})."
}

# _print_accounts_table <target> — shared by list-accounts and
# delete-account (as a courtesy display before prompting for a username),
# so delete-account doesn't need to run _detect_running_target a second time
# (and risk a second "which target?" prompt) just to show the same list.
_print_accounts_table() {
    local target="$1"
    # GM level lives in account_access (per-realm), not account.gmlevel,
    # which is vestigial (see create-account's notes). LEFT JOIN so an
    # account with no account_access row still shows up, as GM level 0.
    _db_query "$target" \
        "SELECT a.id, a.username, COALESCE(aa.gmlevel, 0) AS gmlevel, a.online, a.locked, a.last_login
         FROM realmd.account a LEFT JOIN realmd.account_access aa ON aa.id = a.id AND aa.RealmID = ${REALM_ID}
         ORDER BY a.username;"
}

cmd_list_accounts() {
    header "vanilla-wow — List accounts"
    _settings

    local target
    target=$(_detect_running_target) || return 1

    _print_accounts_table "$target" || return 1
}

cmd_delete_account() {
    header "vanilla-wow — Delete account"
    _settings

    local target
    target=$(_detect_running_target) || return 1

    _print_accounts_table "$target"
    echo ""

    local user_input
    user_input=$(gum input --placeholder "username" --header "Account to delete:") || true
    [[ -z "$user_input" ]] && { info "Cancelled."; return 1; }

    gum confirm "Delete account '${user_input}'? This also removes its characters." \
        || { info "Cancelled."; return 1; }

    # Needed for the account_access cleanup below: that row can only be
    # looked up by account id, and 'account delete' removes the account row
    # itself, so the id has to be captured before the console command runs.
    local acc_id
    acc_id=$(_db_query_raw "$target" "SELECT id FROM realmd.account WHERE username='${user_input^^}';" 2>/dev/null)

    _send_console_cmd "$target" "account delete ${user_input}" || return 1

    # AccountMgr::DeleteAccount (confirmed directly in the source) cleans up
    # characters/character_tutorial/account/realmcharacters, but never
    # account_access — a real, if harmless, upstream gap (an orphaned row
    # can never rejoin a real account again, ids aren't reused). Sweep it
    # here so repeated create/delete cycles don't quietly accumulate junk.
    if [[ "$acc_id" =~ ^[0-9]+$ ]]; then
        sleep 2
        _db_query "$target" "DELETE FROM realmd.account_access WHERE id=${acc_id};" &>/dev/null || true
    fi

    case "$target" in
        local)  info "Check ${INSTALL_DIR}/logs/mangosd.out to confirm." ;;
        docker) info "Check: docker logs ${SERVER_CONTAINER_NAME}" ;;
        k8s)    info "Check: kubectl -n ${K8S_NAMESPACE} logs ${K8S_POD}" ;;
    esac

    success "Delete command sent for '${user_input}'."
}

cmd_set_account_level() {
    header "vanilla-wow — Set account GM level"
    _settings

    local target
    target=$(_detect_running_target) || return 1

    _print_accounts_table "$target"
    echo ""

    local user_input
    user_input=$(gum input --placeholder "username" --header "Account to change:") || true
    [[ -z "$user_input" ]] && { info "Cancelled."; return 1; }

    local current_level
    current_level=$(_db_query_raw "$target" \
        "SELECT COALESCE(aa.gmlevel,0) FROM realmd.account a LEFT JOIN realmd.account_access aa ON aa.id=a.id AND aa.RealmID=${REALM_ID} WHERE a.username='${user_input^^}';" 2>/dev/null)
    [[ "$current_level" =~ ^[0-9]+$ ]] || current_level=0

    local gm_num
    gm_num=$(_pick_gm_level "New access level" "$current_level")

    _send_console_cmd "$target" "account set gmlevel ${user_input} ${gm_num}" || return 1

    case "$target" in
        local)  info "Check ${INSTALL_DIR}/logs/mangosd.out to confirm." ;;
        docker) info "Check: docker logs ${SERVER_CONTAINER_NAME}" ;;
        k8s)    info "Check: kubectl -n ${K8S_NAMESPACE} logs ${K8S_POD}" ;;
    esac

    success "GM level command sent for '${user_input}' (level: ${gm_num})."
}

# rename-character — a direct, immediate rename, not the server's own
# 'character rename <name>' console command. That command (confirmed in
# CharacterCommands.cpp) only flags the character; the actual new name gets
# picked through the client's own name-picker UI at next login, which
# re-enforces the same server-side naming rules this exists to deliberately
# sidestep for a specific character on a case-by-case basis, without
# touching those rules for everyone else. This is a pure database
# operation, not a console command, so it works even if mangosd isn't
# running at all (_detect_db_target, not _detect_running_target) — but the
# character must be offline: mangosd only reads a character's row from the
# database at login, an online character's data lives in memory and a
# logout would overwrite this change with whatever's already loaded there.
cmd_rename_character() {
    header "vanilla-wow — Rename character"
    _settings

    local target
    target=$(_detect_db_target) || return 1

    local old_name
    old_name=$(gum input --placeholder "current name" --header "Character to rename (use 'search' to find one):") || true
    [[ -z "$old_name" ]] && { info "Cancelled."; return 1; }

    local old_name_escaped; old_name_escaped="$(_sql_escape "$old_name")"
    local row guid online
    row=$(_db_query_raw "$target" "SELECT guid, online FROM characters.characters WHERE name='${old_name_escaped}';" 2>/dev/null)
    if [[ -z "$row" ]]; then
        warn "No character named '${old_name}' found."
        return 1
    fi
    guid="${row%%$'\t'*}"
    online="${row##*$'\t'}"

    if [[ "$online" != "0" ]]; then
        warn "'${old_name}' is currently online — log them out first. A live session holds its own copy of the name in memory, and logging out afterward would overwrite this change with the old one."
        return 1
    fi

    local new_name
    new_name=$(gum input --placeholder "new name" --header "New name for '${old_name}' (up to 12 characters, bypasses normal naming rules):") || true
    [[ -z "$new_name" ]] && { info "Cancelled."; return 1; }

    if [[ ${#new_name} -gt 12 ]]; then
        warn "'${new_name}' is ${#new_name} characters — the characters.name column allows at most 12."
        return 1
    fi

    local new_name_escaped; new_name_escaped="$(_sql_escape "$new_name")"
    local existing
    existing=$(_db_query_raw "$target" "SELECT guid FROM characters.characters WHERE name='${new_name_escaped}';" 2>/dev/null)
    if [[ -n "$existing" && "$existing" != "$guid" ]]; then
        warn "'${new_name}' is already taken by another character."
        return 1
    fi

    _db_query "$target" "UPDATE characters.characters SET name='${new_name_escaped}' WHERE guid=${guid};" &>/dev/null || return 1
    success "'${old_name}' renamed to '${new_name}'."
}

# -----------------------------------------------------------------------------
# search — name lookup for items, NPCs, GM teleport locations, and player
# characters. All four are plain reference-data reads (no SRP6/console
# involved, unlike the account commands), so this goes straight to the
# database via _db_query, and works even if mangosd itself isn't running —
# only the database needs to be up (_detect_db_target, not
# _detect_running_target).
# -----------------------------------------------------------------------------

cmd_search() {
    header "vanilla-wow — Search"
    _settings

    local target
    target=$(_detect_db_target) || return 1

    local kind
    kind=$(printf '%s\n' "Items" "NPCs" "Teleport locations" "Player characters" \
        | gum choose --header "Search what?") || true
    [[ -z "$kind" ]] && { info "Cancelled."; return 1; }

    local term
    term=$(gum input --placeholder "name (partial match)" --header "Search term:") || true
    [[ -z "$term" ]] && { info "Cancelled."; return 1; }
    local term_escaped; term_escaped="$(_sql_escape "$term")"

    case "$kind" in
        Items)
            # item_template/creature_template key on (entry, patch) — the
            # same entry can have a different row per patch it changed in.
            # Without filtering, a search can show stale/duplicate rows for
            # an item that changed since; the correlated subquery picks the
            # latest row at or before the configured WOW_PATCH, matching
            # what's actually loaded on this server.
            _db_query "$target" \
                "SELECT it.entry, it.name, it.quality FROM mangos.item_template it
                 WHERE it.name LIKE '%${term_escaped}%' AND it.patch = (
                     SELECT MAX(patch) FROM mangos.item_template it2 WHERE it2.entry = it.entry AND it2.patch <= ${WOW_PATCH}
                 ) ORDER BY it.name LIMIT 50;" || return 1
            ;;
        NPCs)
            _db_query "$target" \
                "SELECT ct.entry, ct.name, ct.subname FROM mangos.creature_template ct
                 WHERE ct.name LIKE '%${term_escaped}%' AND ct.patch = (
                     SELECT MAX(patch) FROM mangos.creature_template ct2 WHERE ct2.entry = ct.entry AND ct2.patch <= ${WOW_PATCH}
                 ) ORDER BY ct.name LIMIT 50;" || return 1
            ;;
        "Teleport locations")
            # game_tele — the table the '.tele <name>' GM command itself
            # searches, no patch column here.
            _db_query "$target" \
                "SELECT id, name, map, ROUND(position_x,1) AS x, ROUND(position_y,1) AS y
                 FROM mangos.game_tele WHERE name LIKE '%${term_escaped}%' ORDER BY name LIMIT 50;" || return 1
            ;;
        "Player characters")
            _db_query "$target" \
                "SELECT guid, name, race, class, level FROM characters.characters
                 WHERE name LIKE '%${term_escaped}%' ORDER BY name LIMIT 50;" || return 1
            ;;
    esac
}

# -----------------------------------------------------------------------------
# edit — escape hatch for anything 'configure' doesn't prompt for. Opens the
# already-configured conf files (not the repack's pristine copies) in vim,
# which setup.sh already installs. Picked up automatically by run-docker/
# run-k8s afterward via _effective_conf_source; 'start' just needs a restart.
# -----------------------------------------------------------------------------

cmd_edit() {
    header "vanilla-wow — Edit conf files"

    if [[ ! -f "${ETC_DIR}/mangosd.conf" ]]; then
        warn "Not configured yet — run 'configure' first."
        return 1
    fi
    if ! command -v vim &>/dev/null; then
        warn "vim not found (setup.sh normally installs it) — edit these files with any editor: ${ETC_DIR}"
        return 1
    fi

    local choice
    choice=$(gum choose "mangosd.conf (server settings, rates, MOTD, ...)" "realmd.conf (login/security settings)" "cancel" \
        --header "Which file to edit?") || true

    case "$choice" in
        mangosd.conf*) vim "${ETC_DIR}/mangosd.conf" ;;
        realmd.conf*)  vim "${ETC_DIR}/realmd.conf" ;;
        *) info "Cancelled."; return ;;
    esac

    success "Saved. Restart 'start' for the local process, or re-run 'run-docker'/'run-k8s' to apply it to a container/pod (conf files are mounted at runtime, not baked into the image — no need to 'build-image' again)."
}

# -----------------------------------------------------------------------------
# build-image — multi-stage Dockerfile, builder compiles inside Ubuntu
# regardless of host OS, runtime stage is slim.
# -----------------------------------------------------------------------------

cmd_build_image() {
    header "vanilla-wow — Build Docker image"
    _settings
    _check_docker

    [[ -d "$SOURCE_DIR" ]] || error_exit "SOURCE_DIR not set or missing — run 'configure' first."
    _unpack_source

    info "Preparing build context..."
    rm -rf "$IMAGE_BUILD_CONTEXT"
    mkdir -p "$IMAGE_BUILD_CONTEXT"
    cp -r "$SRC_UNPACK_DIR" "${IMAGE_BUILD_CONTEXT}/src"
    cp "${TEMPLATES_DIR}/Dockerfile"    "${IMAGE_BUILD_CONTEXT}/Dockerfile"
    cp "${TEMPLATES_DIR}/entrypoint.sh" "${IMAGE_BUILD_CONTEXT}/entrypoint.sh"

    # Warden anti-cheat modules — small and static like the binaries, baked
    # into the image (see the Dockerfile's own note). Without them, Warden
    # still runs (it's enabled by default in the repack's stock conf) but
    # has nothing to actually scan with, which surfaces as players getting
    # kicked for "Client response timeout" during normal play, not just a
    # log warning at startup. Not every repack/fork ships this directory,
    # so an empty one here is a soft warning, not a hard failure.
    if [[ -d "${SOURCE_DIR}/warden_modules" ]]; then
        cp -r "${SOURCE_DIR}/warden_modules" "${IMAGE_BUILD_CONTEXT}/warden_modules"
    else
        warn "No warden_modules/ found under SOURCE_DIR — Warden anti-cheat will run with no modules loaded, which can kick players unexpectedly. Building an empty directory instead."
        mkdir -p "${IMAGE_BUILD_CONTEXT}/warden_modules"
    fi

    info "Building image '${IMAGE_TAG}' (client build ${CLIENT_BUILD})..."
    docker build \
        --build-arg "SUPPORTED_CLIENT_BUILD=${CLIENT_BUILD}" \
        -t "$IMAGE_TAG" \
        "$IMAGE_BUILD_CONTEXT" \
        || error_exit "docker build failed. See compiler output above."

    success "Image built: ${IMAGE_TAG}"
}

# -----------------------------------------------------------------------------
# run-docker — LAN-exposed via host networking; server reaches the DB via
# 127.0.0.1 on the published MariaDB port (host networking bypasses Docker's
# embedded DNS, so container-name resolution isn't available here).
# -----------------------------------------------------------------------------

cmd_run_docker() {
    header "vanilla-wow — Run (Docker, LAN)"
    _settings
    _check_docker

    docker image inspect "$IMAGE_TAG" &>/dev/null || error_exit "Image '${IMAGE_TAG}' not built — run 'build-image' first."
    _ensure_local_mariadb
    _db_bootstrap

    # --type container avoids docker inspect's fallback-to-image lookup —
    # without it, "vanilla-wow-server" (no tag) ambiguously matches the
    # "vanilla-wow-server:latest" image too, since they share a base name.
    if docker inspect --type container "$SERVER_CONTAINER_NAME" &>/dev/null; then
        gum confirm "Container '${SERVER_CONTAINER_NAME}' already exists. Remove and recreate?" \
            || { info "Cancelled."; return; }
        docker rm -f "$SERVER_CONTAINER_NAME" &>/dev/null || true
    fi

    # /app/bin/warden_modules — baked into the image at build time (see
    # cmd_build_image/Dockerfile), mangosd's cwd is /app/bin at runtime.
    _render_mangosd_conf "$(_effective_conf_source mangosd.conf)" "${ETC_DIR}/mangosd.docker.conf" "/app/data" "/app/logs" "/app/bin/warden_modules"
    _render_realmd_conf  "$(_effective_conf_source realmd.conf)"  "${ETC_DIR}/realmd.docker.conf"  "/app/logs"

    # :Z (private SELinux relabel) is required on Fedora/RHEL hosts with
    # SELinux enforcing — without it the container's unprivileged user gets
    # "Permission denied" reading these bind mounts, since host files default
    # to a context (e.g. config_home_t) containers aren't allowed to read.
    # First run relabels the whole data/ tree (3.2GB, one-time cost).
    # -i keeps stdin open (even detached) — mangosd/realmd run an interactive
    # console reader on stdin, and without it Docker delivers an immediate
    # EOF, which the console reads as an implicit quit: the server would
    # otherwise fully start (DB connected, world initialized, ports bound)
    # and then shut itself down cleanly seconds later.
    info "Starting server container (host networking — realm ${REALM_PORT}, world ${WORLD_PORT})..."
    docker run -d -i \
        --name "$SERVER_CONTAINER_NAME" \
        --network host \
        -v "${SOURCE_DIR}/data:/app/data:ro,Z" \
        -v "${ETC_DIR}/mangosd.docker.conf:/app/etc/mangosd.conf:ro,Z" \
        -v "${ETC_DIR}/realmd.docker.conf:/app/etc/realmd.conf:ro,Z" \
        --restart unless-stopped \
        "$IMAGE_TAG" \
        || error_exit "Failed to start container '${SERVER_CONTAINER_NAME}'."

    success "Server running: realm port ${REALM_PORT}, world port ${WORLD_PORT} (host network — reachable on your LAN IP)."
    info "Logs: docker logs -f ${SERVER_CONTAINER_NAME}"
}

# -----------------------------------------------------------------------------
# run-k8s — hostNetwork so the fixed client-expected ports work without a
# LoadBalancer controller. Reuses cluster.sh's select_target and the
# StorageClass-vs-hostPath storage prompt pattern from harbor.sh/lgtm.sh.
# -----------------------------------------------------------------------------

_sed_escape() { printf '%s' "$1" | sed -e 's/[\&|]/\\&/g'; }

# render_template <template-file> <token1=value1> [...]
# Single-line token substitution only — do not pass multi-line values (sed
# can't do that safely). Use inject_block below for multi-line content.
render_template() {
    local tpl="$1"; shift
    local content; content="$(cat "$tpl")"
    local pair token value escaped
    for pair in "$@"; do
        token="${pair%%=*}"
        value="${pair#*=}"
        escaped="$(_sed_escape "$value")"
        content="$(printf '%s' "$content" | sed "s|__${token}__|${escaped}|g")"
    done
    printf '%s\n' "$content"
}

# inject_block <template-file> <token> <replacement-file>
# Splices the full multi-line content of <replacement-file> in place of a
# line that is exactly "__<token>__" — for content sed's single-line 's'
# command can't hold (e.g. the hostPath-vs-PVC volume source block, whose
# line count varies). Same pattern dozzle.sh uses for the same reason.
inject_block() {
    local tpl="$1" token="$2" block_file="$3"
    # Matches on the trimmed line so an indented "          __TOKEN__"
    # placeholder (kept indented in the template for YAML readability) still
    # matches — unlike a bare $0 == token check, which only fires on an
    # unindented, column-0 placeholder.
    awk -v token="__${token}__" '
        { trimmed = $0; sub(/^[ \t]+/, "", trimmed) }
        trimmed == token { while ((getline line < block_file) > 0) print line; next }
        { print }
    ' block_file="$block_file" "$tpl"
}

_prompt_k8s_storage() {
    # Sets GAME_DATA_VOLUME_YAML and DB_VOLUME_YAML (inline volume snippets)
    local choice
    choice=$(gum choose \
        "hostPath (single-node / home-lab — path on the node)" \
        "StorageClass (dynamic provisioning)" \
        --header "Storage backend for game data + DB:") || true

    case "$choice" in
        hostPath*)
            local data_path db_path
            data_path=$(gum input --value "${SOURCE_DIR}/data" --header "hostPath for game data (on the k8s node):") || true
            data_path="${data_path:-${SOURCE_DIR}/data}"
            db_path=$(gum input --value "/var/vanilla-wow-mariadb" --header "hostPath for MariaDB data (on the k8s node):") || true
            db_path="${db_path:-/var/vanilla-wow-mariadb}"
            cfg_set K8S_STORAGE_TYPE hostpath
            cfg_set K8S_DATA_HOSTPATH "$data_path"
            cfg_set K8S_DB_HOSTPATH "$db_path"
            ;;
        StorageClass*)
            local sc
            sc=$(gum input --placeholder "leave empty for cluster default" --header "StorageClass name:") || true
            cfg_set K8S_STORAGE_TYPE storageclass
            cfg_set K8S_STORAGECLASS "$sc"
            warn "StorageClass-backed game data still needs the 3.2GB data/ directory copied into the PVC once — this script does not automate that copy (no assumptions about how the target cluster reaches this host's filesystem). hostPath is the zero-copy option for a single-node cluster."
            ;;
        *) error_exit "No storage backend selected." ;;
    esac
}

cmd_run_k8s() {
    header "vanilla-wow — Run (Kubernetes, LAN via hostNetwork)"
    _settings

    docker image inspect "$IMAGE_TAG" &>/dev/null || error_exit "Image '${IMAGE_TAG}' not built — run 'build-image' first (kind: also 'kind load docker-image')."

    select_target || return 1
    [[ "$TARGET_TYPE" == "docker" ]] && error_exit "run-k8s needs a kind or k8s target, not docker."

    local ns_input
    ns_input=$(gum input --value "$K8S_NAMESPACE" --header "Kubernetes namespace:") || true
    K8S_NAMESPACE="${ns_input:-$K8S_NAMESPACE}"
    cfg_set K8S_NAMESPACE "$K8S_NAMESPACE"

    local addr_input
    addr_input=$(gum input --value "$REALM_ADDRESS" \
        --header "LAN-reachable address for this realm (the k8s NODE's IP, since the pod uses hostNetwork):") || true
    REALM_ADDRESS="${addr_input:-$REALM_ADDRESS}"
    cfg_set REALM_ADDRESS "$REALM_ADDRESS"

    _prompt_k8s_storage

    if [[ "$TARGET_TYPE" == "kind" ]]; then
        info "kind target — loading image into the cluster (kind can't pull local-only images)..."
        gum spin --spinner dot --title "kind load docker-image..." -- \
            kind load docker-image "$IMAGE_TAG" --name "$TARGET_CONTEXT" \
            || error_exit "kind load docker-image failed."
    fi

    local ctx_flags; ctx_flags="$(kubectl_context_flag)"
    local k8s_tpl="${TEMPLATES_DIR}/k8s"
    local manifest; manifest="$(mktemp /tmp/vanilla-wow-k8s-XXXXXX.yaml)"
    local storage_type; storage_type="$(cfg_get K8S_STORAGE_TYPE)"
    local data_source_file db_source_file
    data_source_file="$(mktemp /tmp/vanilla-wow-data-src-XXXXXX)"
    db_source_file="$(mktemp /tmp/vanilla-wow-db-src-XXXXXX)"
    # One trap for all three temp files — a second 'trap ... RETURN' would
    # silently replace the first rather than adding to it.
    # shellcheck disable=SC2064
    trap "rm -f '${manifest}' '${data_source_file}' '${db_source_file}'" RETURN

    # inject_block splices these lines in VERBATIM (no reindentation) in place
    # of the "__DATA_SOURCE__"/"__DB_SOURCE__" placeholder line in the
    # templates below — the indentation here (10 spaces for the key, 12 for
    # its children) must match where that placeholder sits: nested under
    # spec.template.spec.volumes[].<key>, both templates use the same depth.
    if [[ "$storage_type" == "hostpath" ]]; then
        printf '          hostPath:\n            path: %s\n            type: Directory\n' \
            "$(cfg_get K8S_DATA_HOSTPATH)" > "$data_source_file"
        printf '          hostPath:\n            path: %s\n            type: DirectoryOrCreate\n' \
            "$(cfg_get K8S_DB_HOSTPATH)" > "$db_source_file"
    else
        printf '          persistentVolumeClaim:\n            claimName: vanilla-wow-data\n' > "$data_source_file"
        printf '          persistentVolumeClaim:\n            claimName: vanilla-wow-db\n' > "$db_source_file"
        warn "StorageClass path selected — remember to copy game data into the vanilla-wow-data PVC before the server pod will start cleanly."
    fi

    render_template "${k8s_tpl}/namespace.yaml" "NAMESPACE=${K8S_NAMESPACE}" > "$manifest"

    if [[ "$storage_type" != "hostpath" ]]; then
        local sc; sc="$(cfg_get K8S_STORAGECLASS)"
        local sc_line=""
        [[ -n "$sc" ]] && sc_line="  storageClassName: ${sc}"
        echo "---" >> "$manifest"
        render_template "${k8s_tpl}/pvc.yaml" \
            "NAMESPACE=${K8S_NAMESPACE}" "NAME=vanilla-wow-data" "SIZE=5Gi" "STORAGECLASS_LINE=${sc_line}" >> "$manifest"
        echo "---" >> "$manifest"
        render_template "${k8s_tpl}/pvc.yaml" \
            "NAMESPACE=${K8S_NAMESPACE}" "NAME=vanilla-wow-db" "SIZE=10Gi" "STORAGECLASS_LINE=${sc_line}" >> "$manifest"
    fi

    echo "---" >> "$manifest"
    inject_block "${k8s_tpl}/mariadb.yaml" "DB_SOURCE" "$db_source_file" \
        | render_template /dev/stdin "NAMESPACE=${K8S_NAMESPACE}" "DB_PASS=${DB_PASS}" >> "$manifest"
    echo "---" >> "$manifest"
    inject_block "${k8s_tpl}/server.yaml" "DATA_SOURCE" "$data_source_file" \
        | render_template /dev/stdin \
            "NAMESPACE=${K8S_NAMESPACE}" "IMAGE_TAG=${IMAGE_TAG}" \
            "REALM_PORT=${REALM_PORT}" "WORLD_PORT=${WORLD_PORT}" >> "$manifest"

    info "Applying manifests..."
    # shellcheck disable=SC2086
    kubectl $ctx_flags apply -f "$manifest" || error_exit "kubectl apply failed."

    # ConfigMap for the server's conf files, DB host pointed at the in-cluster
    # mariadb Service (hostNetworked pods can still reach ClusterIP services;
    # DNS resolution for that needs dnsPolicy: ClusterFirstWithHostNet, set in
    # server.yaml). --from-file avoids hand-escaping a 3000+ line conf file
    # as an inline YAML string.
    local saved_db_host="$DB_HOST"
    DB_HOST="mariadb.${K8S_NAMESPACE}.svc.cluster.local"
    # /app/bin/warden_modules — same image as run-docker, same baked-in path.
    _render_mangosd_conf "$(_effective_conf_source mangosd.conf)" "${ETC_DIR}/mangosd.k8s.conf" "/app/data" "/app/logs" "/app/bin/warden_modules"
    _render_realmd_conf  "$(_effective_conf_source realmd.conf)"  "${ETC_DIR}/realmd.k8s.conf"  "/app/logs"
    DB_HOST="$saved_db_host"

    info "Creating server config ConfigMap..."
    # shellcheck disable=SC2086
    kubectl $ctx_flags -n "$K8S_NAMESPACE" create configmap vanilla-wow-conf \
        --from-file=mangosd.conf="${ETC_DIR}/mangosd.k8s.conf" \
        --from-file=realmd.conf="${ETC_DIR}/realmd.k8s.conf" \
        --dry-run=client -o yaml | kubectl $ctx_flags apply -f - \
        || error_exit "Failed to create the server ConfigMap."

    info "Running DB bootstrap Job (schemas + world dump + migrations)..."
    render_template "${k8s_tpl}/db-init-job.yaml" \
        "NAMESPACE=${K8S_NAMESPACE}" "DB_PASS=${DB_PASS}" \
        "REALM_ID=${REALM_ID}" "REALM_NAME=${REALM_NAME}" "REALM_ADDRESS=${REALM_ADDRESS}" \
        "WORLD_PORT=${WORLD_PORT}" "CLIENT_BUILD=${CLIENT_BUILD}" \
        "SQL_HOSTPATH=${SOURCE_DIR}/sql" > "${manifest}.job"
    # shellcheck disable=SC2086
    kubectl $ctx_flags apply -f "${manifest}.job" || error_exit "db-init Job apply failed."
    # shellcheck disable=SC2086
    gum spin --spinner dot --title "Waiting for db-init Job to complete (world dump import can take a while)..." -- \
        kubectl $ctx_flags -n "$K8S_NAMESPACE" wait --for=condition=complete job/vanilla-wow-db-init --timeout=900s \
        || warn "db-init Job did not complete in time. Check: kubectl -n ${K8S_NAMESPACE} logs job/vanilla-wow-db-init"
    rm -f "${manifest}.job"

    # shellcheck disable=SC2086
    gum spin --spinner dot --title "Waiting for server rollout..." -- \
        kubectl $ctx_flags -n "$K8S_NAMESPACE" rollout status deployment/vanilla-wow-server --timeout=120s \
        || warn "Server rollout did not complete. Check: kubectl -n ${K8S_NAMESPACE} get pods"

    success "Deployed. hostNetwork pod — reachable on the node's LAN IP: realm ${REALM_PORT}, world ${WORLD_PORT}."
}

# -----------------------------------------------------------------------------
# Main dispatch
# -----------------------------------------------------------------------------

# _run_category_menu <title> <action> [action...] — one submenu's loop.
# Picking an action runs it, then the same submenu reappears (no "back to
# X menu?" confirm — "back" is already a plain choice in the list, and a
# separate confirm on top of that is just an extra step for no benefit).
# Loops until "back"/empty is chosen, which returns to the top-level
# category picker in main()'s own loop.
_run_category_menu() {
    local title="$1"; shift
    local -a opts=("$@")

    while true; do
        header "Vanilla WoW — ${title}"
        local action
        action=$(printf '%s\n' "${opts[@]}" "back" | gum choose --header "Choose an action:") || true
        [[ -z "$action" || "$action" == "back" ]] && return

        # || true: under `set -e`, a cmd_* returning non-zero here (e.g.
        # cmd_edit's soft-fail warn+return) would otherwise trigger errexit
        # and kill the whole script instead of returning to this submenu.
        case "$action" in
            install-deps)   cmd_install_deps   || true ;;
            configure)      cmd_configure      || true ;;
            edit)           cmd_edit           || true ;;
            start)          cmd_start          || true ;;
            stop)           cmd_stop           || true ;;
            build-image)    cmd_build_image    || true ;;
            run-docker)     cmd_run_docker     || true ;;
            run-k8s)        cmd_run_k8s        || true ;;
            create-account)     cmd_create_account     || true ;;
            list-accounts)      cmd_list_accounts      || true ;;
            delete-account)     cmd_delete_account     || true ;;
            set-account-level)  cmd_set_account_level  || true ;;
            rename-character)   cmd_rename_character   || true ;;
        esac
        echo ""
    done
}

main() {
    if [[ $# -gt 0 ]]; then
        case "$1" in
            install-deps)       cmd_install_deps ;;
            configure)          cmd_configure ;;
            start)              cmd_start ;;
            stop)               cmd_stop ;;
            status)             cmd_status ;;
            edit)               cmd_edit ;;
            create-account)     cmd_create_account ;;
            list-accounts)      cmd_list_accounts ;;
            delete-account)     cmd_delete_account ;;
            set-account-level)  cmd_set_account_level ;;
            rename-character)   cmd_rename_character ;;
            search)             cmd_search ;;
            build-image)        cmd_build_image ;;
            run-docker)         cmd_run_docker ;;
            run-k8s)            cmd_run_k8s ;;
            *) error_exit "Unknown command: $1 (expected: install-deps|configure|start|stop|status|edit|create-account|list-accounts|delete-account|set-account-level|rename-character|search|build-image|run-docker|run-k8s)" ;;
        esac
        exit 0
    fi

    while true; do
        header "Vanilla WoW (VMaNGOS) Manager"
        local category
        category=$(gum choose "Setup" "Local" "Deploy" "Accounts" "Characters" "Search" "Status" "Quit" \
            --header "Choose a category:") || true

        [[ -z "$category" || "$category" == "Quit" ]] && { gum style --faint "Bye."; exit 0; }

        case "$category" in
            Setup)      _run_category_menu "Setup"      install-deps configure edit ;;
            Local)      _run_category_menu "Local"      start stop ;;
            Deploy)     _run_category_menu "Deploy"     build-image run-docker run-k8s ;;
            Accounts)   _run_category_menu "Accounts"   create-account list-accounts delete-account set-account-level ;;
            Characters) _run_category_menu "Characters" rename-character ;;
            Search)   cmd_search || true ;;
            Status)   cmd_status || true ;;
        esac
    done
}

main "$@"
