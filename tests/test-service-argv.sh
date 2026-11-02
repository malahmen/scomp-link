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
#   - docker/podman: a secret is `-e NAME` (the value comes from docker's own
#     environment), and reaches the container exactly; the clients run inside
#     it get theirs from the environment (MYSQL_PWD, REDISCLI_AUTH, mongosh
#     reading process.env) or stdin (the mongo readiness check), never -p/-a;
#   - connect reads the container's env with cut -f2-: a value with '=' in it
#     is not cut short;
#   - qdrant's health-check sends the API key as a header in a curl config
#     on stdin (-K -), not as an unquoted, word-split -H on curl's argv;
set -uo pipefail

# shellcheck source=lib/service-stubs.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/service-stubs.sh"

# A password with every character --set mangles, and YAML or a shell cares about.
PW="P,w=1\\x.{y}'\"z q"
PW2="K,e=y\\2.{t}'\"k k"
PW3="C,o\\n.{c}'\"c c"   # no '=' (connect reads it back from the container env)

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

# ---------------------------------------------------------------- docker ---
# env_is <container> <VAR> <value> - the container got VAR=value exactly.
env_is() { grep -qxF -- "$2=$3" "$STUB_STATE/c/$1/env"; }
# exec_env_has <VAR> <value> - a docker exec got VAR=value from the environment.
exec_env_has() { grep -qxF -- "$1=$2" "$STUB_STATE/exec-env" 2>/dev/null; }
# old_container <name> <ENV=VAL>... - a running container this script made.
old_container() {
    local name="$1"; shift
    mkdir -p "$STUB_STATE/c/$name" "$STUB_STATE/v"
    printf '%s\n' "$@" PATH=/usr/bin > "$STUB_STATE/c/$name/env"
    : > "$STUB_STATE/v/${name}-data"
}

# docker_secret_case <svc> <label> <VAR=value>... -- <answer>...
docker_secret_case() {
    local svc="$1" label="$2"; shift 2
    local -a want=()
    while [[ "$1" != -- ]]; do want+=("$1"); shift; done; shift
    echo "${svc} docker: ${label}"
    svc_reset
    svc_run "$svc" "$@"
    check "the script finishes (exit 0)" rc_is 0
    check "docker run ran" bash -c "grep -q '^docker run ' '$STUB_LOG'"
    check "no secret is on any argv" bash -c "$(declare -f argv_clean); argv_clean \"\$1\" && argv_clean \"\$2\"" _ "$PW" "$PW2"
    local kv
    for kv in "${want[@]}"; do
        check "the container gets ${kv%%=*} exactly" env_is "$svc" "${kv%%=*}" "${kv#*=}"
    done
}

docker_secret_case postgres "install" "POSTGRES_PASSWORD=$PW" -- \
    "" install "" "" "" "" "$PW" "← back"

for svc in mariadb mysql; do
    up="$(tr '[:lower:]' '[:upper:]' <<< "$svc")"
    docker_secret_case "$svc" "install" "${up}_ROOT_PASSWORD=$PW" "${up}_PASSWORD=$PW2" -- \
        "" install "" "" "$PW" "" "" "$PW2" "← back"
    check "the readiness ping gets the root password as MYSQL_PWD" exec_env_has MYSQL_PWD "$PW"
    check "...not as -p" bash -c "! grep -qE '^docker exec .* -p' '$STUB_LOG'"

    echo "${svc} docker: connect"
    svc_reset
    old_container "$svc" "${up}_ROOT_PASSWORD=$PW" "${up}_USER=u" "${up}_PASSWORD=$PW3" "${up}_DATABASE=d"
    svc_run "$svc" "" connect "← back"
    check "the script finishes (exit 0)" rc_is 0
    check "the client gets the password as MYSQL_PWD" exec_env_has MYSQL_PWD "$PW3"
    check "no secret is on any argv" bash -c "$(declare -f argv_clean); argv_clean \"\$1\"" _ "$PW3"
done

docker_secret_case mongodb "install" "MONGO_INITDB_ROOT_PASSWORD=$PW" "SCOMP_APP_PASSWORD=$PW2" -- \
    "" install "" "" "" "$PW" "" "" "$PW2" "← back"
check "the readiness check logs in from a script on stdin, with the password exactly" \
    grep -qF "auth(\"root\", \"P,w=1\\\\x.{y}'\\\"z q\")" "$STUB_STATE/exec-stdin"

echo "mongodb docker: connect"
svc_reset
old_container mongodb MONGO_INITDB_ROOT_USERNAME=root "MONGO_INITDB_ROOT_PASSWORD=$PW" \
    MONGO_INITDB_DATABASE=d SCOMP_APP_USERNAME=u "SCOMP_APP_PASSWORD=$PW2"
svc_run mongodb "" connect "← back"
check "the script finishes (exit 0)" rc_is 0
check "mongosh gets the app password from its environment" exec_env_has SCOMP_MONGO_PW "$PW2"
check "...and logs in with it from --eval, then stays interactive" \
    bash -c "grep -E '^docker exec -it -e SCOMP_MONGO_PW ' '$STUB_LOG' | grep -qF -- '--shell --eval db.getSiblingDB(\"d\").auth(\"u\", process.env.SCOMP_MONGO_PW)'"
check "no secret is on any argv" bash -c "$(declare -f argv_clean); argv_clean \"\$1\" && argv_clean \"\$2\"" _ "$PW" "$PW2"

docker_secret_case influxdb "install" "DOCKER_INFLUXDB_INIT_PASSWORD=$PW" "DOCKER_INFLUXDB_INIT_ADMIN_TOKEN=$PW2" -- \
    "" install "" "" "" "$PW" "" "" "$PW2" "← back"

docker_secret_case grafana "install" "GF_SECURITY_ADMIN_PASSWORD=$PW" -- \
    "" install "" "" "" "$PW" "" no "← back"

docker_secret_case n8n "install with Postgres" "N8N_ENCRYPTION_KEY=$PW2" "DB_POSTGRESDB_PASSWORD=$PW" -- \
    "" install "" "" "" "$PW2" "PostgreSQL (production / multi-instance)" "db.example" "" "" "" "$PW" "← back"

docker_secret_case qdrant "install" "QDRANT__SERVICE__API_KEY=$PW" -- \
    "" install "" "" "" "$PW" "← back"

echo "redis docker: status with a password"
svc_reset
old_container redis
svc_run redis "" "$PW" status "" "← back"
check "the script finishes (exit 0)" rc_is 0
check "redis-cli gets the password as REDISCLI_AUTH" exec_env_has REDISCLI_AUTH "$PW"
check "no secret is on any argv" bash -c "$(declare -f argv_clean); argv_clean \"\$1\"" _ "$PW"

# ------------------------------------------------------- values with '=' ---
for svc in mariadb mysql; do
    up="$(tr '[:lower:]' '[:upper:]' <<< "$svc")"
    echo "${svc} docker: connect, the user, database and password contain '='"
    svc_reset
    old_container "$svc" "${up}_ROOT_PASSWORD=$PW" "${up}_USER=u=1" "${up}_PASSWORD=$PW2" "${up}_DATABASE=d=b"
    svc_run "$svc" "" connect "← back"
    check "the script finishes (exit 0)" rc_is 0
    check "the password reaches the client whole" exec_env_has MYSQL_PWD "$PW2"
    check "...and the user and database" bash -c "grep -E '^docker exec -it ' '$STUB_LOG' | grep -qE -- ' -uu=1 d=b\$'"
done

echo "postgres docker: connect, the user and database contain '='"
svc_reset
old_container postgres "POSTGRES_PASSWORD=$PW" "POSTGRES_USER=us=er" "POSTGRES_DB=d=b"
svc_run postgres "" connect "← back"
check "the script finishes (exit 0)" rc_is 0
check "psql gets them whole" bash -c "grep -qE -- '^docker exec -it postgres psql -U us=er -d d=b\$' '$STUB_LOG'"

echo "grafana docker: connect, the admin user contains '='"
svc_reset
old_container grafana "GF_SECURITY_ADMIN_USER=ad=min" "GF_SECURITY_ADMIN_PASSWORD=$PW"
svc_run grafana "" connect yes "← back"
check "the script finishes (exit 0)" rc_is 0
check "the username shown is whole" grep -qE 'Username: ad=min( |$)' "$T/out"

# ---------------------------------------------------------- qdrant curl ---
echo "qdrant docker: health-check with an API key"
# This file's curl stub also keeps what curl reads as its config from stdin.
cat > "$T/bin/curl" <<'EOF'
#!/usr/bin/env bash
printf 'curl %s\n' "$*" >> "$STUB_LOG"
prev=""; for a in "$@"; do [[ "$prev" == -K && "$a" == - ]] && cat >> "$STUB_STATE/curl-config"; prev="$a"; done
exit 0
EOF
svc_reset
svc_run qdrant "" install "" "" "" "$PW" health-check yes "← back"
check "the script finishes (exit 0)" rc_is 0
# (the docker stub answers every port lookup with the same string)
check "both REST calls read a config from stdin" \
    bash -c "[[ \$(grep -cE '^curl -sf -K - http://127\.0\.0\.1:.*/(collections)?\$' '$STUB_LOG') == 2 ]]"
check "the config holds the api-key header, the key escaped for its double quotes" \
    grep -qxF 'header = "api-key: P,w=1\\x.{y}'"'"'\"z q"' "$STUB_STATE/curl-config"
check "no secret is on any argv" bash -c "$(declare -f argv_clean); argv_clean \"\$1\"" _ "$PW"

echo
if (( FAILS )); then echo "${FAILS} check(s) failed"; exit 1; fi
echo "all checks passed"
