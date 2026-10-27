#!/usr/bin/env bash
# The service scripts' "leave empty to auto-generate" secrets (Kamino 173),
# driven through the gum stub against recording docker/kubectl/helm stubs
# (tests/lib/service-stubs.sh) - no container runtime, no cluster.
#
# What it protects:
#   - _gen_secret gives exactly the length asked, from the charset asked, and
#     returns 0 under `set -euo pipefail` (the `tr </dev/urandom | head -c`
#     it replaces exited 141 there and took the script with it);
#   - in each of the eight scripts that offer it, an empty answer produces a
#     secret of the right length and charset, it reaches the container or the
#     release, and the script carries on to the end of the install.
set -uo pipefail

# shellcheck source=lib/service-stubs.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/service-stubs.sh"

echo "_gen_secret"
gen() { bash -c 'set -euo pipefail; source "$1"; s="$(_gen_secret "$2" ${3:+"$3"})"; printf "%s\nrc=0\n" "$s"' _ "${SVC_DIR}/_common/secret.sh" "$@"; }
out="$(gen 20)"
check "returns under set -euo pipefail" grep -qx 'rc=0' <<< "$out"
check "20 characters of A-Za-z0-9" grep -qxE '[A-Za-z0-9]{20}' <<< "$out"
out="$(gen 200)"
check "a length beyond one urandom block is filled exactly (200; one block gives ~124)" grep -qxE '[A-Za-z0-9]{200}' <<< "$out"
out="$(gen 16 'a-f0-9')"
check "a charset narrows the output (16 hex digits)" grep -qxE '[a-f0-9]{16}' <<< "$out"
check "a bad length is refused" bash -c 'source "$1"; ! _gen_secret 0 2>/dev/null' _ "${SVC_DIR}/_common/secret.sh"

# docker_run_env <VAR> - the value VAR was given in the last `docker run`.
docker_run_env() { grep -E '^docker run ' "$STUB_LOG" | tail -1 | tr ' ' '\n' | sed -n "s/^$1=//p"; }
# secret_ok <VAR> <len> - VAR reached docker run as <len> alphanumerics.
secret_ok() { grep -qxE "[A-Za-z0-9]{$2}" <<< "$(docker_run_env "$1")"; }

echo "postgres: empty password"
svc_reset
svc_run postgres "" install "" "" "" "" "" "← back"
check "the script finishes (exit 0)" rc_is 0
check "the password is generated (20 alphanumerics) and reaches the container" secret_ok POSTGRES_PASSWORD 20
check "...and is shown once" has "Generated password: $(docker_run_env POSTGRES_PASSWORD)" "$T/out"
check "the install completes" has "PostgreSQL running" "$T/out"

for svc in mariadb mysql; do
    echo "${svc}: empty root and user passwords"
    svc_reset
    svc_run "$svc" "" install "" "" "" "" "" "" "← back"
    up="$(tr '[:lower:]' '[:upper:]' <<< "$svc")"
    check "the script finishes (exit 0)" rc_is 0
    check "the root password is generated (20)" secret_ok "${up}_ROOT_PASSWORD" 20
    check "the user password is generated (20)" secret_ok "${up}_PASSWORD" 20
    check "the install completes" grep -q "running" "$T/out"
done

echo "mongodb: empty root and app passwords"
svc_reset
svc_run mongodb "" install "" "" "" "" "" "" "" "← back"
check "the script finishes (exit 0)" rc_is 0
check "the root password is generated (20)" secret_ok MONGO_INITDB_ROOT_PASSWORD 20
check "the app password is generated (20)" secret_ok SCOMP_APP_PASSWORD 20
check "the install completes" has "MongoDB running" "$T/out"

echo "influxdb: empty admin password"
svc_reset
svc_run influxdb "" install "" "" "" "" "" "" "" "← back"
check "the script finishes (exit 0)" rc_is 0
check "the admin password is generated (24)" secret_ok DOCKER_INFLUXDB_INIT_PASSWORD 24
check "the install completes" has "InfluxDB running" "$T/out"

echo "grafana: empty admin password"
svc_reset
svc_run grafana "" install "" "" "" "" "" no "← back"
check "the script finishes (exit 0)" rc_is 0
check "the admin password is generated (20)" secret_ok GF_SECURITY_ADMIN_PASSWORD 20
check "the install completes" has "Grafana running" "$T/out"

echo "n8n: empty encryption key"
svc_reset
svc_run n8n "" install "" "" "" "" "SQLite (zero-config, single-instance)" "← back"
check "the script finishes (exit 0)" rc_is 0
check "the encryption key is generated (32)" secret_ok N8N_ENCRYPTION_KEY 32
check "the install completes" has "n8n running" "$T/out"

echo "harbor (k8s): empty admin password"
svc_reset; touch "$STUB_STATE/no-docker"; echo stub-ctx > "$STUB_STATE/contexts"
svc_run harbor "" "" install "" "" "StorageClass (dynamic provisioning — covers NFS-backed classes)" "" "" "← back"
pw="$(grep -E '^helm (--kube-context [^ ]+ )?install ' "$STUB_LOG" | tr ' ' '\n' | sed -n 's/^harborAdminPassword=//p')"
check "the script finishes (exit 0)" rc_is 0
check "the admin password is generated (24) and reaches the release" grep -qxE '[A-Za-z0-9]{24}' <<< "$pw"
check "the install completes" has "Harbor installed." "$T/out"

echo
if (( FAILS )); then echo "${FAILS} check(s) failed"; exit 1; fi
echo "all checks passed"
