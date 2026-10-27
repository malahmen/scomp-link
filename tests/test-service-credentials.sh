#!/usr/bin/env bash
# Kept data keeps its credentials (Kamino 174), driven through the gum stub
# against recording docker/kubectl/helm stubs (tests/lib/service-stubs.sh).
#
# A database image applies its credential env only to an EMPTY data dir, and
# a chart's password only on first install. Recreating the container on a kept
# volume, or upgrading a release, used to ask for new credentials, pass them
# (ignored by the data), and print them - the old one kept working, the shown
# one failed. What this protects:
#   - Docker recreate: no credential is asked for or generated; the old
#     container's values reach the new one unchanged;
#   - Docker, volume without its container: nothing is generated; the existing
#     credentials are asked for and used;
#   - k8s upgrade: no credential is asked for, none is --set, the release's
#     values are reused (--reuse-values), and none is printed;
#   - a fresh install still asks, generates and passes them.
set -uo pipefail

# shellcheck source=lib/service-stubs.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/service-stubs.sh"

last_run() { grep -E '^docker run ' "$STUB_LOG" | tail -1; }
run_has()  { last_run | tr ' ' '\n' | grep -qxF -- "$1"; }
run_lacks() { ! last_run | tr ' ' '\n' | grep -qE -- "$1"; }
helm_cmd() { grep -E "^helm (--kube-context [^ ]+ )?$1 " "$STUB_LOG" | tail -1; }

# old_container <name> <ENV=VAL>... - a container this script made, and its volume.
old_container() {
    local name="$1"; shift
    mkdir -p "$STUB_STATE/c/$name" "$STUB_STATE/v"
    printf '%s\n' "$@" PATH=/usr/bin > "$STUB_STATE/c/$name/env"
    : > "$STUB_STATE/v/${name}-data"
}
k8s_world() {  # k8s_world [release] - one kube-context, no docker, release installed if given
    touch "$STUB_STATE/no-docker"; echo stub-ctx > "$STUB_STATE/contexts"
    if [[ -n "${1:-}" ]]; then mkdir -p "$STUB_STATE/releases"; : > "$STUB_STATE/releases/$1"; fi
}

# ---------------------------------------------------------------- Docker ----
echo "postgres: recreate on a kept volume"
svc_reset
old_container postgres POSTGRES_DB=olddb POSTGRES_USER=olduser POSTGRES_PASSWORD=oldpw
svc_run postgres "" install "" "" "Remove and recreate" "← back"
check "the script finishes (exit 0)" rc_is 0
check "it says the credentials are kept" has "keeps the credentials it was created with" "$T/out"
check "no password is generated" lacks "Generated" "$T/out"
check "the old password reaches the new container" run_has POSTGRES_PASSWORD=oldpw
check "...with the old user and database" bash -c "$(declare -f last_run run_has); run_has POSTGRES_USER=olduser && run_has POSTGRES_DB=olddb"
check "the old container is read before it is removed" \
    bash -c "grep -n . '$STUB_LOG' | grep -m1 -E 'Config.Env|rm -f' | grep -q Config.Env"

echo "postgres: a volume without its container"
svc_reset
mkdir -p "$STUB_STATE/v"; : > "$STUB_STATE/v/postgres-data"
svc_run postgres "" install "" "" olddb olduser oldpw "← back"
check "the script finishes (exit 0)" rc_is 0
check "it says the old credentials remain in force" has "remain in force" "$T/out"
check "nothing is generated" lacks "Generated" "$T/out"
check "the existing credentials given are the ones used" \
    bash -c "$(declare -f last_run run_has); run_has POSTGRES_PASSWORD=oldpw && run_has POSTGRES_USER=olduser && run_has POSTGRES_DB=olddb"

echo "postgres: a fresh install still asks and generates"
svc_reset
svc_run postgres "" install "" "" "" "" "" "← back"
check "a password is generated" has "Generated password" "$T/out"
check "...and passed" bash -c "$(declare -f last_run); last_run | grep -qE 'POSTGRES_PASSWORD=[A-Za-z0-9]{20} '"

for svc in mariadb mysql; do
    up="$(tr '[:lower:]' '[:upper:]' <<< "$svc")"
    echo "${svc}: recreate on a kept volume"
    svc_reset
    old_container "$svc" "${up}_ROOT_PASSWORD=oldroot" "${up}_DATABASE=olddb" "${up}_USER=olduser" "${up}_PASSWORD=oldpw"
    svc_run "$svc" "" install "" "" "Remove and recreate" "← back"
    check "the script finishes (exit 0)" rc_is 0
    check "nothing is generated" lacks "Generated" "$T/out"
    check "the old root password reaches the new container" run_has "${up}_ROOT_PASSWORD=oldroot"
    check "the old user password reaches the new container" run_has "${up}_PASSWORD=oldpw"
    check "...with the old user" run_has "${up}_USER=olduser"
done

echo "mongodb: recreate on a kept volume"
svc_reset
old_container mongodb MONGO_INITDB_ROOT_USERNAME=r00t MONGO_INITDB_ROOT_PASSWORD=oldroot \
    MONGO_INITDB_DATABASE=olddb SCOMP_APP_USERNAME=oldapp SCOMP_APP_PASSWORD=oldapppw
svc_run mongodb "" install "" "" "Remove and recreate" "← back"
check "the script finishes (exit 0)" rc_is 0
check "nothing is generated" lacks "Generated" "$T/out"
check "the old root pair reaches the new container" \
    bash -c "$(declare -f last_run run_has); run_has MONGO_INITDB_ROOT_USERNAME=r00t && run_has MONGO_INITDB_ROOT_PASSWORD=oldroot"
check "the old app user is kept for connect" run_has SCOMP_APP_PASSWORD=oldapppw
check "no app-user init script is mounted (it would not run)" run_lacks 'docker-entrypoint-initdb.d'

echo "mongodb: a volume without its container, root password not given"
svc_reset
mkdir -p "$STUB_STATE/v"; : > "$STUB_STATE/v/mongodb-data"
svc_run mongodb "" install "" "" "" "" "← back"
check "nothing is generated" lacks "Generated" "$T/out"
check "without the existing root password nothing is started" bash -c "! grep -q '^docker run' '$STUB_LOG'"

echo "influxdb: recreate on a kept volume"
svc_reset
old_container influxdb DOCKER_INFLUXDB_INIT_MODE=setup DOCKER_INFLUXDB_INIT_USERNAME=olduser \
    DOCKER_INFLUXDB_INIT_PASSWORD=oldpw DOCKER_INFLUXDB_INIT_ORG=oldorg DOCKER_INFLUXDB_INIT_BUCKET=oldbucket
svc_run influxdb "" install "" "" "Remove and recreate" "← back"
check "the script finishes (exit 0)" rc_is 0
check "nothing is generated" lacks "Generated" "$T/out"
check "the old password and org are carried over" \
    bash -c "$(declare -f last_run run_has); run_has DOCKER_INFLUXDB_INIT_PASSWORD=oldpw && run_has DOCKER_INFLUXDB_INIT_ORG=oldorg"
check "no setup is requested on the kept data" run_lacks 'DOCKER_INFLUXDB_INIT_MODE'

echo "grafana: recreate on a kept volume"
svc_reset
old_container grafana GF_SECURITY_ADMIN_USER=oldadmin GF_SECURITY_ADMIN_PASSWORD=oldpw
svc_run grafana "" install "" "" "Remove and recreate" "" no "← back"
check "the script finishes (exit 0)" rc_is 0
check "nothing is generated" lacks "Generated" "$T/out"
check "the old admin pair reaches the new container" \
    bash -c "$(declare -f last_run run_has); run_has GF_SECURITY_ADMIN_USER=oldadmin && run_has GF_SECURITY_ADMIN_PASSWORD=oldpw"

echo "grafana: a volume without its container"
svc_reset
mkdir -p "$STUB_STATE/v"; : > "$STUB_STATE/v/grafana-data"
svc_run grafana "" install "" "" "" no "← back"
check "the script finishes (exit 0)" rc_is 0
check "nothing is generated" lacks "Generated" "$T/out"
check "no admin password is passed (the kept one stays)" run_lacks 'GF_SECURITY_ADMIN_PASSWORD'

echo "n8n: recreate on a kept volume"
svc_reset
old_container n8n N8N_ENCRYPTION_KEY=oldkey0123456789 GENERIC_TIMEZONE=UTC
svc_run n8n "" install "" "" "" "Remove and recreate" "SQLite (zero-config, single-instance)" "← back"
check "the script finishes (exit 0)" rc_is 0
check "no key is generated" lacks "Generated" "$T/out"
check "the old encryption key reaches the new container" run_has N8N_ENCRYPTION_KEY=oldkey0123456789

echo "n8n: a volume without its container"
svc_reset
mkdir -p "$STUB_STATE/v"; : > "$STUB_STATE/v/n8n-data"
svc_run n8n "" install "" "" "" "SQLite (zero-config, single-instance)" "← back"
check "the script finishes (exit 0)" rc_is 0
check "no key is generated" lacks "Generated" "$T/out"
check "no key is passed: n8n uses the one saved in the volume" run_lacks 'N8N_ENCRYPTION_KEY'

# ------------------------------------------------------------ Kubernetes ----
UPGRADE="Upgrade (keep credentials, apply other values)"

# k8s_upgrade_ok <label> <forbidden --set regex> - the upgrade reused values
# and set no credential.
k8s_upgrade_ok() {
    local up; up="$(helm_cmd upgrade)"
    check "$1: the script finishes (exit 0)" rc_is 0
    check "$1: helm upgrade ran with --reuse-values" grep -q -- '--reuse-values' <<< "$up"
    check "$1: no credential is --set on the upgrade" bash -c '! grep -qE -- "$1" <<< "$2"' _ "$2" "$up"
    check "$1: nothing is generated or asked" lacks "Generated" "$T/out"
}

echo "postgres k8s: upgrade"
svc_reset; k8s_world postgresql
svc_run postgres "" "" install "$UPGRADE" "" "← back"
k8s_upgrade_ok postgres 'password|superuserPassword'
check "postgres: it says the credentials are kept" has "Keeping the release's existing credentials" "$T/out"

echo "postgres k8s: fresh install still sets them"
svc_reset; k8s_world
svc_run postgres "" "" install "" "" "" "" "← back"
check "the password is --set on install" bash -c "grep -E '^helm .*install ' '$STUB_LOG' | grep -qE 'userDatabase.password=[A-Za-z0-9]{20}'"

echo "mariadb / mysql / mongodb k8s: upgrade"
for svc in mariadb mysql mongodb; do
    svc_reset
    case "$svc" in mariadb) k8s_world mariadb ;; mysql) k8s_world mysql ;; mongodb) k8s_world mongodb ;; esac
    svc_run "$svc" "" "" install "$UPGRADE" "" "← back"
    k8s_upgrade_ok "$svc" 'rootPassword|userDatabase.password|rootUsername'
done

echo "influxdb k8s: upgrade"
svc_reset; k8s_world influxdb
svc_run influxdb "" "" install "$UPGRADE" "" "← back"
k8s_upgrade_ok influxdb 'adminUser\.'

echo "grafana k8s: upgrade"
svc_reset; k8s_world grafana
svc_run grafana "" "" install "$UPGRADE" "" "" "" no "← back"
k8s_upgrade_ok grafana 'adminPassword|adminUser='
check "grafana: no login password is printed" bash -c "! grep -E 'Login: .* / ' '$T/out'"

echo "harbor k8s: upgrade"
svc_reset; k8s_world harbor
svc_run harbor "" "" install "Upgrade (keep admin password, apply other values)" "" \
    "StorageClass (dynamic provisioning — covers NFS-backed classes)" "" "" "← back"
k8s_upgrade_ok harbor 'harborAdminPassword'
check "harbor: the login shown is not a new password" has "Login: admin / (unchanged" "$T/out"

echo "n8n k8s: upgrade"
svc_reset; k8s_world n8n
svc_run n8n "" "" install "Upgrade (keep encryption key, apply other values)" \
    "SQLite (zero-config, single-instance)" "" "" "← back"
k8s_upgrade_ok n8n 'encryptionKey'

echo
if (( FAILS )); then echo "${FAILS} check(s) failed"; exit 1; fi
echo "all checks passed"
