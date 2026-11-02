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
#   - no file the scripts write holds a secret readable by other users:
#     dozzle's users.yml is 0600 (also an older 0644 one); mongodb's init
#     script and grafana's Docker datasource file are bind-mounted into the
#     container, which must read them, so they hold no secret at all - the
#     container gets it in its env;
#   - dozzle generate gets the password on stdin, not --password;
#   - redis on Docker gets its password in the container env, written by the
#     container into a config file, not as --requirepass (Kamino 235);
#   - postgres 18+ gets its volume at /var/lib/postgresql (17 and older at
#     .../data, where 18 refuses to start); a kept volume laid out for the
#     other kind is not used without a warning and a confirm.
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
                if (v ~ /^\x27.*\x27$/) {
                    v = substr(v, 2, length(v) - 2)
                    t = v; gsub(/\x27\x27/, "", t)
                    # a lone quote inside ends the scalar early: not valid YAML
                    if (t ~ /\x27/) v = "<invalid single-quoted YAML>"; else gsub(/\x27\x27/, "\x27", v)
                }
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
    grep -qsF "auth(\"root\", \"P,w=1\\\\x.{y}'\\\"z q\")" "$STUB_STATE/exec-stdin"

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

echo "redis docker: install with a password (Kamino 235)"
# The password was --requirepass: on docker's argv, and redis-server's inside
# the container. It goes in the container env, and the container writes it
# into a 0600 config file for redis-server.
svc_reset
svc_run redis "" "" install "" "" "$PW" "← back"
e="${PW//\\/\\\\}"; e="${e//\"/\\\"}"
check "the script finishes (exit 0)" rc_is 0
check "docker run ran" bash -c "grep -q '^docker run ' '$STUB_LOG'"
check "no secret is on any argv" bash -c "$(declare -f argv_clean); argv_clean \"\$1\"" _ "$PW"
check "no --requirepass at all" lacks "--requirepass" "$STUB_LOG"
check "the container gets the requirepass line, the password escaped for redis.conf" \
    env_is redis SCOMP_REDIS_CONF "requirepass \"${e}\""
check "...which its shell writes to a file redis-server is started on" \
    bash -c "grep '^docker run ' '$STUB_LOG' | grep -qF -- 'sh -c umask 077; f=/tmp/scomp-redis.conf; rm -f \"\$f\"; printf \"%s\\n\" \"\$SCOMP_REDIS_CONF\" > \"\$f\"' && grep '^docker run ' '$STUB_LOG' | grep -qF -- 'exec docker-entrypoint.sh redis-server \"\$f\" --appendonly yes'"
svc_reset
svc_run redis "" "" install "" "" "" "← back"
check "no password: plain redis-server, no config file" \
    bash -c "grep '^docker run ' '$STUB_LOG' | grep -qE -- ' redis-server --appendonly yes\$' && ! grep -q SCOMP_REDIS_CONF '$STUB_LOG'"

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
    grep -qsxF 'header = "api-key: P,w=1\\x.{y}'"'"'\"z q"' "$STUB_STATE/curl-config"
check "no secret is on any argv" bash -c "$(declare -f argv_clean); argv_clean \"\$1\"" _ "$PW"
# Published on one LAN address (SCOMP_BIND_ADDR), the port is not on
# 127.0.0.1: the Docker health-check asks where it is published (Kamino 196).
svc_reset
SCOMP_BIND_ADDR=192.0.2.7 svc_run qdrant "" install "" "" "" "$PW" health-check yes "← back"
check "bound to one address: the health-check asks there" \
    bash -c "[[ \$(grep -cE '^curl -sf -K - http://192\.0\.2\.7:.*/(collections)?\$' '$STUB_LOG') == 2 ]]"

# ------------------------------------------------------ secrets in files ---
# mode <file> - its permission bits, as 600.
mode() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }

echo "mongodb docker: install with an app user"
svc_reset
svc_run mongodb "" install "" "" "" "$PW" "" "u" "$PW2" "← back"
INIT="$HOME/.config/scomp-link/mongodb/mongodb/init/create-app-user.js"
check "the script finishes (exit 0)" rc_is 0
check "the init script is written and mounted" \
    bash -c "[[ -f '$INIT' ]] && grep -q 'docker-entrypoint-initdb.d:ro' '$STUB_LOG'"
check "it holds no password" bash -c "! grep -qF -- 'K,e' '$INIT'"
check "it reads the app password from the container env" grep -qF 'pwd: process.env.SCOMP_APP_PASSWORD,' "$INIT"
check "which the container gets" env_is mongodb SCOMP_APP_PASSWORD "$PW2"

echo "mongodb docker: kept data, an init script an older install wrote with the password"
svc_reset
old_container mongodb MONGO_INITDB_ROOT_USERNAME=root "MONGO_INITDB_ROOT_PASSWORD=$PW" \
    MONGO_INITDB_DATABASE=d SCOMP_APP_USERNAME=u "SCOMP_APP_PASSWORD=$PW2"
printf 'db.getSiblingDB("d").createUser({ user: "u", pwd: "%s" });\n' "oldsecret" > "$INIT"
chmod 644 "$INIT"
svc_run mongodb "" install "" "" "Remove and recreate" "← back"
check "the script finishes (exit 0)" rc_is 0
check "the old init script no longer holds the password" bash -c "! grep -q oldsecret '$INIT'"

# Before 6.0 the image runs init scripts with the legacy mongo shell, which
# cannot read the app password from the environment: install used to go on
# without the app user (Kamino 196's regression). Those releases are past
# their end of life, so it refuses them before asking or changing anything
# (Kamino 235).
for tag in 5.0 4.4.29 3.6; do
    echo "mongodb docker: mongo:${tag} (before 6.0) is refused"
    svc_reset; rm -f "$INIT"
    svc_run mongodb "" install "$tag" "← back"
    check "the script finishes (exit 0), back at the menu" rc_is 0
    check "it says why, and what to choose" bash -c 'grep -q "older than 6.0" "$1" && grep -q "Choose 6.0 or later" "$1"' _ "$T/out"
    check "nothing is pulled, removed or started" bash -c "! grep -qE '^docker (pull|rm|run) ' '$STUB_LOG'"
    check "no init script is written" test ! -e "$INIT"
done
echo "mongodb docker: an existing container, recreated as mongo:5.0 - refused, kept"
svc_reset
old_container mongodb MONGO_INITDB_ROOT_USERNAME=root "MONGO_INITDB_ROOT_PASSWORD=$PW"
svc_run mongodb "" install "5.0" "← back"
check "the container is not removed" bash -c "! grep -qE '^docker (rm|run) ' '$STUB_LOG'"
for tag in 6.0 7 8.0.3 latest jammy; do
    svc_reset
    svc_run mongodb "" install "$tag" "" "" "$PW" "" "u" "$PW2" "← back"
    check "mongo:${tag} installs, the app user's init script mounted" \
        bash -c "grep -q '^docker run .*docker-entrypoint-initdb.d' '$STUB_LOG'"
done

echo "mongodb docker: connect to a container from before 6.0 (legacy mongo shell)"
# This file's docker wraps the stub: the container has no mongosh, only mongo.
mv "$T/bin/docker" "$T/bin/docker.stub"
printf '#!/usr/bin/env bash\n[[ "$1 ${3:-} ${4:-}" == "exec which mongosh" ]] && { printf "docker %%s\\n" "$*" >> "$STUB_LOG"; exit 1; }\nexec "$(dirname "$0")/docker.stub" "$@"\n' > "$T/bin/docker"
chmod +x "$T/bin/docker"
svc_reset
old_container mongodb MONGO_INITDB_ROOT_USERNAME=root "MONGO_INITDB_ROOT_PASSWORD=$PW" \
    MONGO_INITDB_DATABASE=d SCOMP_APP_USERNAME=u "SCOMP_APP_PASSWORD=$PW2"
svc_run mongodb "" connect "← back"
check "the script finishes (exit 0)" rc_is 0
check "the legacy shell is asked to prompt: -p last, no value (Kamino 235)" \
    bash -c "grep -qxE -- 'docker(\.stub)? exec -it mongodb mongo d -u u --authenticationDatabase d -p' '$STUB_LOG'"
check "no secret is on any argv" bash -c "$(declare -f argv_clean); argv_clean \"\$1\" && argv_clean \"\$2\"" _ "$PW" "$PW2"
check "it says where the password is" has "docker exec mongodb printenv SCOMP_APP_PASSWORD" "$T/out"
mv "$T/bin/docker.stub" "$T/bin/docker"

echo "grafana docker: an InfluxDB datasource with a token"
svc_reset
svc_run grafana "" install "" "" "" "$PW" "" yes "InfluxDB v2" "" "" "" "$PW2" "← back"
DS="$HOME/.config/scomp-link/grafana/grafana/provisioning/datasources/datasources.yaml"
check "the script finishes (exit 0)" rc_is 0
check "the datasource file holds no token" bash -c "[[ -f '$DS' ]] && ! grep -qF -- 'K,e' '$DS'"
check "...but Grafana's reference to the container env" grep -qxF '    token: ${SCOMP_INFLUXDB_TOKEN}' "$DS"
check "the container gets the token exactly" env_is grafana SCOMP_INFLUXDB_TOKEN "$PW2"
check "no secret is on any argv" bash -c "$(declare -f argv_clean); argv_clean \"\$1\" && argv_clean \"\$2\"" _ "$PW" "$PW2"

echo "grafana k8s: an InfluxDB datasource with a token"
svc_reset; k8s_world
svc_run grafana "" "" install "" "$PW" "" "" "" yes "InfluxDB v2" "" "" "" "$PW2" "← back"
check "the script finishes (exit 0)" rc_is 0
q="'"; q="${q}${PW2//"$q"/"$q$q"}${q}"   # PW2 as a single-quoted YAML scalar
check "the token reaches helm exactly (quoted YAML)" bash -c 'grep -qxF -- "        token: $1" "$2"/values/*.yaml' _ "$q" "$STUB_STATE"
check "the values files were mode 600 and are removed" values_private

echo "dozzle docker: auth - users.yml (password hash)"
svc_reset; rm -rf "$HOME/.config/dozzle"
# This file's docker wraps the stub: `generate` prints a users.yml, as the
# image does, and keeps what it read on stdin.
mv "$T/bin/docker" "$T/bin/docker.stub"
cat > "$T/bin/docker" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == run && " $* " == *" generate "* ]]; then
    printf 'docker %s\n' "$*" >> "$STUB_LOG"
    [[ -t 0 ]] || cat > "$STUB_STATE/generate-stdin"
    printf 'users:\n    admin:\n        password: $2a$11$stubhash\n'
    exit 0
fi
exec "$(dirname "$0")/docker.stub" "$@"
EOF
chmod +x "$T/bin/docker"
mkdir -p "$T/dz"; echo "users: []" > "$T/dz/users.yml"; chmod 644 "$T/dz/users.yml"
svc_cmd dozzle install yes admin "$PW" "" "" "$T/dz"
check "install finishes (exit 0)" rc_is 0
check "users.yml is written" grep -q 'stubhash' "$T/dz/users.yml"
check "...mode 600, though an older one was 644" bash -c "[[ \$($(declare -f mode); mode '$T/dz/users.yml') == 600 ]]"
check "dozzle generate reads the password on stdin" bash -c '[[ "$(cat "$1")" == "$2" ]]' _ "$STUB_STATE/generate-stdin" "$PW"
check "no secret is on any argv" bash -c "$(declare -f argv_clean); argv_clean \"\$1\"" _ "$PW"
rm -rf "$T/dz"
mv "$T/bin/docker.stub" "$T/bin/docker"   # the shared stub again (it logs as `docker`)

# ---------------------------------------------------------- postgres 18 ---
# pg_mount_is <path> - the last docker run mounted postgres-data there.
pg_mount_is() { grep -qxF -- "postgres-data:$1" "$STUB_STATE/c/postgres/mounts"; }
for tag_mount in "18:/var/lib/postgresql" "latest:/var/lib/postgresql" "alpine:/var/lib/postgresql" \
                 "18.1-bookworm:/var/lib/postgresql" "17:/var/lib/postgresql/data" \
                 "16.4-alpine:/var/lib/postgresql/data" "9.6:/var/lib/postgresql/data"; do
    tag="${tag_mount%%:*}" mount_want="${tag_mount#*:}"
    echo "postgres docker: install postgres:${tag}"
    svc_reset
    svc_run postgres "" install "$tag" "" "" "" "" "← back"
    check "the script finishes (exit 0)" rc_is 0
    check "the volume is mounted at ${mount_want}" pg_mount_is "$mount_want"
done

echo "postgres docker: recreate a 16 container (volume at .../data) as 18 - declined"
svc_reset
old_container postgres POSTGRES_DB=d POSTGRES_USER=u "POSTGRES_PASSWORD=$PW"
echo "postgres-data:/var/lib/postgresql/data" > "$STUB_STATE/c/postgres/mounts"
svc_run postgres "" install "18" "" "Remove and recreate" no "← back"
check "the script finishes (exit 0)" rc_is 0
check "it says 18 will not use the data in the volume" grep -q "PostgreSQL 18 moved its data directory" "$T/out"
check "nothing is removed or started" bash -c "! grep -qE '^docker (rm|run) ' '$STUB_LOG'"

echo "postgres docker: recreate a 16 container as 18 - confirmed"
svc_reset
old_container postgres POSTGRES_DB=d POSTGRES_USER=u "POSTGRES_PASSWORD=$PW"
echo "postgres-data:/var/lib/postgresql/data" > "$STUB_STATE/c/postgres/mounts"
svc_run postgres "" install "18" "" "Remove and recreate" yes "← back"
check "the script finishes (exit 0)" rc_is 0
check "18 gets the volume where it needs it" pg_mount_is /var/lib/postgresql

echo "postgres docker: recreate a 16 container as 16.4 - nothing to say"
svc_reset
old_container postgres POSTGRES_DB=d POSTGRES_USER=u "POSTGRES_PASSWORD=$PW"
echo "postgres-data:/var/lib/postgresql/data" > "$STUB_STATE/c/postgres/mounts"
svc_run postgres "" install "16.4" "" "Remove and recreate" "← back"
check "the script finishes (exit 0)" rc_is 0
check "no layout warning" lacks "moved its data directory" "$T/out"
check "the volume stays at .../data" pg_mount_is /var/lib/postgresql/data

echo
if (( FAILS )); then echo "${FAILS} check(s) failed"; exit 1; fi
echo "all checks passed"
