#!/usr/bin/env bash
# Secrets stay off command lines and out of world-readable files, and reach
# their tool exactly as typed (Kamino 196). Driven through the gum stub
# against the recording docker/kubectl/helm/curl stubs
# (tests/lib/service-stubs.sh), whose $STUB_LOG holds every argv they got -
# what `ps` would have shown any local user.
#
# What it protects:
#   - helm: a password is never --set (argv, and --set splits it at commas and
#     parses \ . { } in it); it reaches the chart in a mode-0600 values file
#     that holds it exactly and is gone when the script ends;
set -uo pipefail

# shellcheck source=lib/service-stubs.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/service-stubs.sh"

# A password with every character --set mangles, and YAML or a shell cares about.
PW="P,w=1\\x.{y}'\"z q"
PW2="K,e=y\\2.{t}'\"k k"

k8s_world() {  # k8s_world - one kube-context, no docker
    touch "$STUB_STATE/no-docker"; echo stub-ctx > "$STUB_STATE/contexts"
}
# argv_clean <secret> - no recorded argv holds the secret, or its first part
# (what --set would have kept of it, cut at the comma).
argv_clean() { ! grep -qF -- "$1" "$STUB_LOG" && ! grep -qF -- "${1%%,*}," "$STUB_LOG"; }
# helm_values - every values file helm was given, as dotted.key=value lines
# (single-quoted YAML scalars decoded).
helm_values() {
    local f
    for f in "$STUB_STATE"/values/*.yaml; do
        [[ -f "$f" ]] || continue
        awk '{
            match($0, /^ */); ind = RLENGTH / 2; line = substr($0, RLENGTH + 1)
            k = line; sub(/:.*/, "", k); path[ind] = k
            v = line
            if (sub(/^[^:]*: /, "", v)) {
                p = path[0]; for (i = 1; i <= ind; i++) p = p "." path[i]
                if (v ~ /^\x27.*\x27$/) { v = substr(v, 2, length(v) - 2); gsub(/\x27\x27/, "\x27", v) }
                print p "=" v
            }
        }' "$f"
    done
}
# value_is <dotted.key> <value> - helm got exactly <value> for the key.
value_is() { helm_values | grep -qxF -- "$1=$2"; }
# values_private - every values file helm got was mode 600, and is gone now.
values_private() {
    local m ok=0
    for m in "$STUB_STATE"/values/*.mode; do
        [[ -f "$m" ]] || return 1
        [[ "$(cat "$m")" == 600 ]] || ok=1
        [[ ! -e "$(cat "${m%.mode}.path")" ]] || ok=1
    done
    return "$ok"
}
helm_install_line() { grep -E '^helm (--kube-context [^ ]+ )?install ' "$STUB_LOG" | tail -1; }

# ------------------------------------------------------------ helm values ---
# k8s_secret_case <svc> <label> <key=value>... -- <answer>...
k8s_secret_case() {
    local svc="$1" label="$2"; shift 2
    local -a want=()
    while [[ "$1" != -- ]]; do want+=("$1"); shift; done; shift
    echo "${svc} k8s: ${label}"
    svc_reset; k8s_world
    svc_run "$svc" "$@"
    check "the script finishes (exit 0)" rc_is 0
    check "helm install ran" bash -c "grep -qE '^helm (--kube-context [^ ]+ )?install ' '$STUB_LOG'"
    check "no secret is on any argv" bash -c "$(declare -f argv_clean); argv_clean \"\$1\" && argv_clean \"\$2\"" _ "$PW" "$PW2"
    check "no secret is --set" bash -c "! grep -E '^helm ' '$STUB_LOG' | grep -qiE -- '--set(-string)? [^ ]*(password|token|api_key|encryptionKey|requirepass)'"
    local kv
    for kv in "${want[@]}"; do
        check "the values file holds ${kv%%=*} exactly" value_is "${kv%%=*}" "${kv#*=}"
    done
    check "the values files were mode 600 and are removed" values_private
}

k8s_secret_case postgres "install with a password --set would mangle" \
    "settings.superuserPassword=$PW" "userDatabase.password=$PW" -- \
    "" "" install "" "" "$PW" "" "← back"
check "the database and user are still --set" bash -c "$(declare -f helm_install_line); helm_install_line | grep -q 'userDatabase.user=app'"

for svc in mariadb mysql; do
    k8s_secret_case "$svc" "install with root and user passwords --set would mangle" \
        "settings.rootPassword=$PW" "userDatabase.password=$PW2" -- \
        "" "" install "$PW" "" "" "$PW2" "" "← back"
done

k8s_secret_case mongodb "install with root and app passwords --set would mangle" \
    "settings.rootPassword=$PW" "userDatabase.password=$PW2" -- \
    "" "" install "" "$PW" "" "" "$PW2" "" "← back"

k8s_secret_case influxdb "install with a password and a token --set would mangle" \
    "adminUser.password=$PW" "adminUser.token=$PW2" -- \
    "" "" install "" "$PW" "" "" "$PW2" "" "← back"

k8s_secret_case grafana "install with an admin password --set would mangle" \
    "adminPassword=$PW" -- \
    "" "" install "" "$PW" "" "" "" no "← back"

k8s_secret_case harbor "install with an admin password --set would mangle" \
    "harborAdminPassword=$PW" -- \
    "" "" install "$PW" "" "StorageClass (dynamic provisioning — covers NFS-backed classes)" "" "" "← back"

k8s_secret_case n8n "install with Postgres and an encryption key --set would mangle" \
    "config.database.postgresdb.password=$PW" "config.n8n.encryptionKey=$PW2" -- \
    "" "" install "$PW2" "PostgreSQL (production / multi-instance)" "db.example" "" "" "" "$PW" "" "" "← back"

k8s_secret_case qdrant "install with an API key --set would mangle" \
    "config.service.api_key=$PW" -- \
    "" "" install "$PW" "" "" "← back"

k8s_secret_case redis "install with a password --set-string would mangle" \
    "redisConfig=requirepass \"P,w=1\\\\x.{y}'\\\"z q\"" -- \
    "" "" "$PW" install "$PW" "" "← back"

echo "postgres k8s: helm install fails (error_exit)"
svc_reset; k8s_world; touch "$STUB_STATE/helm-fail"
svc_run postgres "" "" install "" "" "$PW" "" "← back"
check "the script stops (non-zero)" bash -c "[[ \$(cat '$T/rc') != 0 ]]"
check "the values file was mode 600 and is removed all the same" values_private

echo "harbor k8s: helm install fails (warn and back to the menu)"
svc_reset; k8s_world; touch "$STUB_STATE/helm-fail"
svc_run harbor "" "" install "$PW" "" "StorageClass (dynamic provisioning — covers NFS-backed classes)" "" "" "← back"
check "the script finishes (exit 0)" rc_is 0
check "the values file was mode 600 and is removed all the same" values_private

echo
if (( FAILS )); then echo "${FAILS} check(s) failed"; exit 1; fi
echo "all checks passed"
