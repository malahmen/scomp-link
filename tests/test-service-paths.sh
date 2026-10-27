#!/usr/bin/env bash
# dozzle `uninstall` and lgtm `purge` delete only the folders they created
# (Kamino 176). Driven through the gum stub against recording docker,
# docker-compose and kubectl stubs (tests/lib/service-stubs.sh); every folder
# involved lives in this test's temp dir, $HOME included.
#
# They used to `rm -rf` whatever data path the user had typed at install - a
# `projects` folder was deleted in the reproduction - with a confirm that did
# not name it; lgtm also wiped a kind/k8s NODE path on this machine, and
# stopped half way under set -e when a delete failed. What this protects:
#   - a non-empty folder the user already had survives, and the confirm says
#     it is kept; a folder the script created is deleted, and the confirm
#     names it;
#   - / and $HOME are refused, at install and at removal;
#   - lgtm purge never deletes a node hostPath here, and a failed delete is
#     reported at the end instead of ending the script half way.
#
# The two removal cases that name / are run only against a script that has
# the guard (owned_dirs.sh): run against the old code they would be
# `rm -rf /`. Without the guard they are reported as failures, not run.
set -uo pipefail

# shellcheck source=lib/service-stubs.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/service-stubs.sh"

guarded() { grep -q 'owned_dir_plan' "${SVC_DIR}/$1/$1.sh"; }
# conf_set <file> <KEY> <value> - writes a saved config the way the scripts do.
conf_set() { mkdir -p "$(dirname "$1")"; printf '%s="%s"\n' "$2" "$3" >> "$1"; }
DOZZLE_CONF="$HOME/.config/dozzle/dozzle.conf"
LGTM_CONF="$HOME/.config/lgtm/lgtm.conf"
world() { svc_reset; rm -rf "$HOME/.config"; }

# ---------------------------------------------------------------- dozzle ----
echo "dozzle: a non-empty folder the user already had"
world
mkdir -p "$T/projects/src"; echo "work" > "$T/projects/src/main.c"
svc_cmd dozzle install no "$T/projects"
check "install finishes (exit 0)" rc_is 0
check "it is not marked as dozzle.sh's" test ! -e "$T/projects/.scomp-link-owned"
svc_cmd dozzle uninstall yes
check "uninstall finishes (exit 0)" rc_is 0
check "the folder and its files survive" test -f "$T/projects/src/main.c"
check "the confirm names the folder and says it is kept" \
    grep -qF "Its data folder $T/projects was not created by dozzle.sh and will be kept" "$T/out"

echo "dozzle: a folder dozzle.sh created"
world
svc_cmd dozzle install no "$T/dozzle-data"
check "install creates and marks it" test -f "$T/dozzle-data/.scomp-link-owned"
echo "users: []" > "$T/dozzle-data/users.yml"
svc_cmd dozzle uninstall yes
check "uninstall finishes (exit 0)" rc_is 0
check "the confirm names the folder it deletes" \
    grep -qF "deletes its data folder $T/dozzle-data" "$T/out"
check "the folder is deleted" test ! -e "$T/dozzle-data"

echo "dozzle: declining the confirm deletes nothing"
world
svc_cmd dozzle install no "$T/dozzle-data"
svc_cmd dozzle uninstall no
check "the folder is still there" test -d "$T/dozzle-data"
rm -rf "$T/dozzle-data"

echo "dozzle: / and \$HOME are refused at install"
world
svc_cmd dozzle install no "/"
check "/ is refused (non-zero, said so)" bash -c "[[ \$(cat '$T/rc') != 0 ]] && grep -q 'Refusing' '$T/out'"
svc_cmd dozzle install no "$HOME"
check "\$HOME is refused (non-zero, said so)" bash -c "[[ \$(cat '$T/rc') != 0 ]] && grep -q 'Refusing' '$T/out'"
check "nothing was started" bash -c "! grep -q 'docker-compose .* up' '$STUB_LOG'"

echo "dozzle: a saved config naming \$HOME (an older install)"
world
echo "precious" > "$HOME/precious.txt"
conf_set "$DOZZLE_CONF" TARGET_TYPE docker
conf_set "$DOZZLE_CONF" STORAGE_MODE bind
conf_set "$DOZZLE_CONF" STORAGE_PATH "$HOME"
svc_cmd dozzle uninstall yes
check "uninstall finishes (exit 0)" rc_is 0
check "\$HOME and its files survive" test -f "$HOME/precious.txt"
check "the confirm says it will not be deleted" grep -qF "$HOME is / or your home folder and will NOT be deleted" "$T/out"

echo "dozzle: a saved config naming /"
if guarded dozzle; then
    world
    conf_set "$DOZZLE_CONF" TARGET_TYPE docker
    conf_set "$DOZZLE_CONF" STORAGE_MODE bind
    conf_set "$DOZZLE_CONF" STORAGE_PATH "/"
    svc_cmd dozzle uninstall yes
    check "uninstall finishes (exit 0)" rc_is 0
    check "/ is refused and said so" grep -qF "Not deleting /: refused" "$T/out"
else
    check "dozzle.sh has the removal guard (not run: it would rm -rf /)" false
fi

# ------------------------------------------------------------------ lgtm ----
echo "lgtm: a non-empty base folder the user already had (Docker)"
world
mkdir -p "$T/obs"; echo "notes" > "$T/obs/notes.md"
svc_cmd lgtm install 'Grafana\nLoki' "$T/obs"
check "install finishes (exit 0)" rc_is 0
check "the base is not marked as lgtm.sh's" test ! -e "$T/obs/.scomp-link-owned"
check "the component folders it made are" test -f "$T/obs/grafana/.scomp-link-owned" -a -f "$T/obs/loki/.scomp-link-owned"
svc_cmd lgtm purge yes
check "purge finishes (exit 0)" rc_is 0
check "the user's file survives" test -f "$T/obs/notes.md"
check "the component folders lgtm.sh made are deleted" test ! -e "$T/obs/grafana" -a ! -e "$T/obs/loki"
check "the warning names each folder it deletes" \
    bash -c "grep -qF '  $T/obs/grafana' '$T/out' && grep -qF '  $T/obs/loki' '$T/out'"
check "...and says the base is kept" grep -qF "$T/obs  (not created by lgtm.sh)" "$T/out"
check "the config is removed" test ! -e "$LGTM_CONF"

echo "lgtm: a base folder lgtm.sh created (Docker)"
world
svc_cmd lgtm install 'Grafana' "$T/lgtm-data"
check "install creates and marks it" test -f "$T/lgtm-data/.scomp-link-owned"
svc_cmd lgtm purge yes
check "purge finishes (exit 0)" rc_is 0
check "the base is deleted" test ! -e "$T/lgtm-data"
check "the warning names it" grep -qF "  $T/lgtm-data" "$T/out"

echo "lgtm: / and \$HOME are refused at install"
world
svc_cmd lgtm install 'Grafana' "/"
check "/ is refused (non-zero, said so)" bash -c "[[ \$(cat '$T/rc') != 0 ]] && grep -q 'Refusing' '$T/out'"
world
svc_cmd lgtm install 'Grafana' "$HOME"
check "\$HOME is refused (non-zero, said so)" bash -c "[[ \$(cat '$T/rc') != 0 ]] && grep -q 'Refusing' '$T/out'"

echo "lgtm: a saved config naming \$HOME (an older install, Docker)"
world
echo "precious" > "$HOME/precious.txt"
conf_set "$LGTM_CONF" TARGET_TYPE docker
conf_set "$LGTM_CONF" ENABLED_COMPONENTS grafana
conf_set "$LGTM_CONF" HOSTPATH_BASE "$HOME"
svc_cmd lgtm purge yes
check "purge finishes (exit 0)" rc_is 0
check "\$HOME and its files survive" test -f "$HOME/precious.txt"

echo "lgtm: a saved config naming / (Docker)"
if guarded lgtm; then
    world
    conf_set "$LGTM_CONF" TARGET_TYPE docker
    conf_set "$LGTM_CONF" ENABLED_COMPONENTS grafana
    conf_set "$LGTM_CONF" HOSTPATH_BASE "/"
    svc_cmd lgtm purge yes
    check "purge finishes (exit 0)" rc_is 0
    check "/ is listed as refused" grep -qF "/  (/ or your home folder: refused)" "$T/out"
else
    check "lgtm.sh has the removal guard (not run: it would rm -rf /)" false
fi

echo "lgtm: kind - the hostPath base is a NODE path, never deleted here"
world
mkdir -p "$T/node-path"; echo "local" > "$T/node-path/file"
conf_set "$LGTM_CONF" TARGET_TYPE kind
conf_set "$LGTM_CONF" TARGET_CONTEXT dev
conf_set "$LGTM_CONF" ENABLED_COMPONENTS grafana
conf_set "$LGTM_CONF" HOSTPATH_BASE "$T/node-path"
svc_cmd lgtm purge yes
check "purge finishes (exit 0)" rc_is 0
check "the local folder of the same name survives" test -f "$T/node-path/file"
check "it says node data is not touched from here" grep -qF "hostPath data on the node(s) under $T/node-path is not touched" "$T/out"

echo "lgtm: a delete that fails is reported, not a half-done exit"
if [[ "$(id -u)" == 0 ]]; then
    check "runs as non-root (root ignores the permissions this case relies on)" false
else
    world
    svc_cmd lgtm install 'Grafana' "$T/lgtm-data"
    mkdir -p "$T/lgtm-data/grafana/owned-by-container"; : > "$T/lgtm-data/grafana/owned-by-container/db"
    chmod 555 "$T/lgtm-data/grafana/owned-by-container"
    svc_cmd lgtm purge yes
    chmod -R u+w "$T/lgtm-data" 2>/dev/null
    check "purge finishes (exit 0)" rc_is 0
    check "the failure is reported with the path" grep -qF "could not delete $T/lgtm-data" "$T/out"
    check "the summary says purge had problems" grep -q "Purge finished with 1 problem" "$T/out"
    check "the config is kept so purge can run again" test -f "$LGTM_CONF"
    rm -rf "$T/lgtm-data"
fi

echo
if (( FAILS )); then echo "${FAILS} check(s) failed"; exit 1; fi
echo "all checks passed"
