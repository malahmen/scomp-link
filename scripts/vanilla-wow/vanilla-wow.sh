#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# vanilla-wow.sh
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
    info "Ensuring realmlist row (id=${REALM_ID}, address=${REALM_ADDRESS}:${WORLD_PORT})..."
    _db_exec "INSERT INTO realmd.realmlist (id, name, address, localAddress, localSubnetMask, port, gamebuild_min, gamebuild_max)
        VALUES (${REALM_ID}, 'VanillaWoW', '${REALM_ADDRESS}', '127.0.0.1', '255.255.255.0', ${WORLD_PORT}, ${CLIENT_BUILD}, ${CLIENT_BUILD})
        ON DUPLICATE KEY UPDATE address='${REALM_ADDRESS}', port=${WORLD_PORT}, gamebuild_min=${CLIENT_BUILD}, gamebuild_max=${CLIENT_BUILD};" \
        || error_exit "Failed to write the realmlist row."
    success "realmlist ready."
}

# -----------------------------------------------------------------------------
# Config file generation — patches the repack's stock conf files rather than
# hand-authoring new ones (they're 3000+ lines of documented settings; only a
# handful need to change for a containerized/local deployment).
# -----------------------------------------------------------------------------

# _render_mangosd_conf <src> <dst> <data_dir> <logs_dir>
_render_mangosd_conf() {
    local src="$1" dst="$2" data_dir="$3" logs_dir="$4"
    cp "$src" "$dst"
    sed -i \
        -e "s|^DataDir[[:space:]]*=.*|DataDir = \"${data_dir}\"|" \
        -e "s|^LogsDir[[:space:]]*=.*|LogsDir = \"${logs_dir}\"|" \
        -e "s|^LoginDatabase\.Info[[:space:]]*=.*|LoginDatabase.Info              = \"${DB_HOST};${DB_PORT};${DB_USER};${DB_PASS};realmd\"|" \
        -e "s|^WorldDatabase\.Info[[:space:]]*=.*|WorldDatabase.Info              = \"${DB_HOST};${DB_PORT};${DB_USER};${DB_PASS};mangos\"|" \
        -e "s|^CharacterDatabase\.Info[[:space:]]*=.*|CharacterDatabase.Info          = \"${DB_HOST};${DB_PORT};${DB_USER};${DB_PASS};characters\"|" \
        -e "s|^LogsDatabase\.Info[[:space:]]*=.*|LogsDatabase.Info               = \"${DB_HOST};${DB_PORT};${DB_USER};${DB_PASS};logs\"|" \
        -e "s|^WorldServerPort[[:space:]]*=.*|WorldServerPort = ${WORLD_PORT}|" \
        -e "s|^RealmID[[:space:]]*=.*|RealmID = ${REALM_ID}|" \
        "$dst"
}

# _render_realmd_conf <src> <dst> <logs_dir>
_render_realmd_conf() {
    local src="$1" dst="$2" logs_dir="$3"
    cp "$src" "$dst"
    sed -i \
        -e "s|^LogsDir[[:space:]]*=.*|LogsDir = \"${logs_dir}\"|" \
        -e "s|^LoginDatabaseInfo[[:space:]]*=.*|LoginDatabaseInfo = \"${DB_HOST};${DB_PORT};${DB_USER};${DB_PASS};realmd\"|" \
        -e "s|^RealmServerPort[[:space:]]*=.*|RealmServerPort = ${REALM_PORT}|" \
        "$dst"
}

# -----------------------------------------------------------------------------
# configure
# -----------------------------------------------------------------------------

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

    _check_docker
    _ensure_local_mariadb
    _db_bootstrap

    info "Generating local conf files (native start/stop path)..."
    mkdir -p "$INSTALL_DIR"
    _render_mangosd_conf "${SOURCE_DIR}/mangosd.conf" "${ETC_DIR}/mangosd.conf" "${INSTALL_DIR}/data" "${INSTALL_DIR}/logs"
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
        (cd "${INSTALL_DIR}/bin" && nohup ./mangosd >> "${INSTALL_DIR}/logs/mangosd.out" 2>&1 < <(sleep infinity) &
         echo "$!:${WORLD_PORT}" > "$mangosd_pf")
        sleep 1
        pf_is_running "$mangosd_pf" && success "mangosd started (port ${WORLD_PORT})." || warn "mangosd did not start — check ${INSTALL_DIR}/logs/mangosd.out"
    fi

    info "Logs: ${INSTALL_DIR}/logs/{realmd,mangosd}.out"
}

cmd_stop() {
    header "vanilla-wow — Stop (local)"

    local realmd_pf="${PF_DIR}/realmd.pid" mangosd_pf="${PF_DIR}/mangosd.pid"

    if pf_is_running "$mangosd_pf"; then pf_stop "$mangosd_pf"; else info "mangosd not running."; fi
    if pf_is_running "$realmd_pf";  then pf_stop "$realmd_pf";  else info "realmd not running.";  fi
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

    _render_mangosd_conf "${SOURCE_DIR}/mangosd.conf" "${ETC_DIR}/mangosd.docker.conf" "/app/data" "/app/logs"
    _render_realmd_conf  "${SOURCE_DIR}/realmd.conf"  "${ETC_DIR}/realmd.docker.conf"  "/app/logs"

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
    _render_mangosd_conf "${SOURCE_DIR}/mangosd.conf" "${ETC_DIR}/mangosd.k8s.conf" "/app/data" "/app/logs"
    _render_realmd_conf  "${SOURCE_DIR}/realmd.conf"  "${ETC_DIR}/realmd.k8s.conf"  "/app/logs"
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
        "REALM_ID=${REALM_ID}" "REALM_ADDRESS=${REALM_ADDRESS}" \
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

main() {
    if [[ $# -gt 0 ]]; then
        case "$1" in
            install-deps) cmd_install_deps ;;
            configure)    cmd_configure ;;
            start)        cmd_start ;;
            stop)         cmd_stop ;;
            status)       cmd_status ;;
            build-image)  cmd_build_image ;;
            run-docker)   cmd_run_docker ;;
            run-k8s)      cmd_run_k8s ;;
            *) error_exit "Unknown command: $1 (expected: install-deps|configure|start|stop|status|build-image|run-docker|run-k8s)" ;;
        esac
        exit 0
    fi

    while true; do
        header "Vanilla WoW (VMaNGOS) Manager"
        local action
        action=$(gum choose \
            "install-deps" "configure" "start" "stop" "status" \
            "build-image" "run-docker" "run-k8s" "quit" \
            --header "Choose an action:") || true

        [[ -z "$action" || "$action" == "quit" ]] && { gum style --faint "Bye."; exit 0; }

        case "$action" in
            install-deps) cmd_install_deps ;;
            configure)    cmd_configure ;;
            start)        cmd_start ;;
            stop)         cmd_stop ;;
            status)       cmd_status ;;
            build-image)  cmd_build_image ;;
            run-docker)   cmd_run_docker ;;
            run-k8s)      cmd_run_k8s ;;
        esac

        echo ""
        gum confirm "Back to main menu?" || { gum style --faint "Bye."; exit 0; }
    done
}

main "$@"
