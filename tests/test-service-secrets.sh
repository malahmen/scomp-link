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
#     release, and the script carries on to the end of the install;
#   - the generated secret is never printed (Kamino 235): the output says
#     where it is kept and how to read it back instead.
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

# docker_run_env <VAR> - the value VAR was given in the last `docker run`:
# from the container env the docker stub recorded, as a secret is passed as
# `-e NAME` with its value in docker's environment, not argv (Kamino 196).
docker_run_env() {
    local n; n="$(grep -E '^docker run ' "$STUB_LOG" | tail -1 | sed -nE 's/.* --name ([^ ]+) .*/\1/p')"
    [[ -n "$n" ]] && sed -n "s/^$1=//p" "$STUB_STATE/c/$n/env"
}
# secret_ok <VAR> <len> - VAR reached docker run as <len> alphanumerics.
secret_ok() { grep -qxE "[A-Za-z0-9]{$2}" <<< "$(docker_run_env "$1")"; }
# not_shown <VAR>... - no generated value appears anywhere in the output.
not_shown() { local k v; for k in "$@"; do v="$(docker_run_env "$k")"; [[ -n "$v" ]] && lacks "$v" "$T/out" || return 1; done; }
# kept_said <container> <VAR>... - the output says how to read each back.
kept_said() { local c="$1" k; shift; for k in "$@"; do has "docker exec $c printenv $k" "$T/out" || return 1; done; }

echo "postgres: empty password"
svc_reset
svc_run postgres "" install "" "" "" "" "" "← back"
check "the script finishes (exit 0)" rc_is 0
check "the password is generated (20 alphanumerics) and reaches the container" secret_ok POSTGRES_PASSWORD 20
check "...is never shown (Kamino 235)" not_shown POSTGRES_PASSWORD
check "...and the output says where it is kept" kept_said postgres POSTGRES_PASSWORD
check "the install completes" has "PostgreSQL running" "$T/out"

for svc in mariadb mysql; do
    echo "${svc}: empty root and user passwords"
    svc_reset
    svc_run "$svc" "" install "" "" "" "" "" "" "← back"
    up="$(tr '[:lower:]' '[:upper:]' <<< "$svc")"
    check "the script finishes (exit 0)" rc_is 0
    check "the root password is generated (20)" secret_ok "${up}_ROOT_PASSWORD" 20
    check "the user password is generated (20)" secret_ok "${up}_PASSWORD" 20
    check "neither is shown (Kamino 235)" not_shown "${up}_ROOT_PASSWORD" "${up}_PASSWORD"
    check "  the output says where both are kept" kept_said "$svc" "${up}_ROOT_PASSWORD" "${up}_PASSWORD"
    check "the install completes" grep -q "running" "$T/out"
done

echo "mongodb: empty root and app passwords"
svc_reset
svc_run mongodb "" install "" "" "" "" "" "" "" "← back"
check "the script finishes (exit 0)" rc_is 0
check "the root password is generated (20)" secret_ok MONGO_INITDB_ROOT_PASSWORD 20
check "the app password is generated (20)" secret_ok SCOMP_APP_PASSWORD 20
check "neither is shown (Kamino 235)" not_shown MONGO_INITDB_ROOT_PASSWORD SCOMP_APP_PASSWORD
check "  the output says where both are kept" kept_said mongodb MONGO_INITDB_ROOT_PASSWORD SCOMP_APP_PASSWORD
check "the install completes" has "MongoDB running" "$T/out"

echo "influxdb: empty admin password"
svc_reset
svc_run influxdb "" install "" "" "" "" "" "" "" "← back"
check "the script finishes (exit 0)" rc_is 0
check "the admin password is generated (24)" secret_ok DOCKER_INFLUXDB_INIT_PASSWORD 24
check "...is never shown (Kamino 235)" not_shown DOCKER_INFLUXDB_INIT_PASSWORD
check "...and the output says where it is kept" kept_said influxdb DOCKER_INFLUXDB_INIT_PASSWORD
check "the install completes" has "InfluxDB running" "$T/out"

echo "grafana: empty admin password"
svc_reset
svc_run grafana "" install "" "" "" "" "" no "← back"
check "the script finishes (exit 0)" rc_is 0
check "the admin password is generated (20)" secret_ok GF_SECURITY_ADMIN_PASSWORD 20
check "...is never shown (Kamino 235)" not_shown GF_SECURITY_ADMIN_PASSWORD
check "...and the output says where it is kept" kept_said grafana GF_SECURITY_ADMIN_PASSWORD
check "the install completes" has "Grafana running" "$T/out"

echo "n8n: empty encryption key"
svc_reset
svc_run n8n "" install "" "" "" "" "SQLite (zero-config, single-instance)" "← back"
check "the script finishes (exit 0)" rc_is 0
check "the encryption key is generated (32)" secret_ok N8N_ENCRYPTION_KEY 32
check "...is never shown (Kamino 235)" not_shown N8N_ENCRYPTION_KEY
check "...and the output says where it is kept" kept_said n8n N8N_ENCRYPTION_KEY
check "the install completes" has "n8n running" "$T/out"

echo "harbor (k8s): empty admin password"
svc_reset; touch "$STUB_STATE/no-docker"; echo stub-ctx > "$STUB_STATE/contexts"
svc_run harbor "" "" install "" "" "StorageClass (dynamic provisioning — covers NFS-backed classes)" "" "" "← back"
# Kamino 196: the password reaches helm in a values file (the helm stub keeps
# a copy under values/), not on its argv as --set.
pw="$(sed -n "s/^harborAdminPassword: '\(.*\)'\$/\1/p" "$STUB_STATE"/values/*.yaml 2>/dev/null)"
check "the script finishes (exit 0)" rc_is 0
check "the admin password is generated (24) and reaches the release" grep -qxE '[A-Za-z0-9]{24}' <<< "$pw"
check "...is never shown, the summary included (Kamino 235)" bash -c '[[ -n "$1" ]] && ! grep -qF -- "$1" "$2"' _ "$pw" "$T/out"
check "...and the output says where it is kept" has "helm --kube-context stub-ctx get values harbor -n harbor" "$T/out"
check "the install completes" has "Harbor installed." "$T/out"

echo
if (( FAILS )); then echo "${FAILS} check(s) failed"; exit 1; fi
echo "all checks passed"
