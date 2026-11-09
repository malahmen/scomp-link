#!/usr/bin/env bash
# Temporary files get an unpredictable name on every OS (Kamino 237).
#
# BSD mktemp (macOS) replaces the X's of a template only where they end it:
# `mktemp /tmp/grafana-values-XXXXXX.yaml` was the literal path
# /tmp/grafana-values-XXXXXX.yaml there - the same at every run, so a second
# run failed with "File exists" and whoever created that path first owned the
# InfluxDB token written into it. GNU mktemp replaces the last run of X's
# anywhere, which is why Linux never showed it.
#
# Checked here on any OS: mktemp is a shim with BSD's rule, ahead of the real
# one on the sandbox PATH, and
#   - grafana's helm values files and kind's cluster config get a different
#     path at each run, with no literal X's, under $TMPDIR, mode 600;
#   - every mktemp template in scripts/ ends in its X's.
set -uo pipefail

# shellcheck source=lib/service-stubs.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/service-stubs.sh"

PW="P,w=1\\x.{y}'\"z q"   # the admin password and the InfluxDB token
PW2="K,e=y\\2.{t}'\"k k"
k8s_world() {  # one kube-context, no docker (as test-service-argv.sh)
    touch "$STUB_STATE/no-docker"; echo stub-ctx > "$STUB_STATE/contexts"
}

REAL_MKTEMP="$(command -v mktemp)"
export REAL_MKTEMP
mkdir -p "$T/tmp"
export TMPDIR="$T/tmp"

# mktemp with BSD's rule for a template: trailing X's are replaced, any others
# kept as they are. The forms without a template (-d alone, -t prefix) go to
# the real mktemp: their semantics differ between the two, and are not what
# this checks.
cat > "$T/bin/mktemp" <<'EOF'
#!/usr/bin/env bash
dir=""; args=("$@")
[[ "${1:-}" == "-d" ]] && { dir=1; shift; }
if (( $# != 1 )) || [[ "$1" == -* ]]; then exec "$REAL_MKTEMP" "${args[@]}"; fi
tpl="$1"; x="${tpl##*[!X]}"; base="${tpl%"$x"}"
for _ in 1 2 3 4 5 6 7 8; do
    path="$base"
    for (( i = 0; i < ${#x}; i++ )); do
        path+="$(LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 1)"
    done
    if [[ -n "$dir" ]]; then mkdir -m 700 "$path" 2>/dev/null && { echo "$path"; exit 0; }
    else (umask 077; set -C; : > "$path") 2>/dev/null && { echo "$path"; exit 0; }
    fi
    [[ -z "$x" ]] && break
done
echo "mktemp: mkstemp failed on $tpl: File exists" >&2; exit 1
EOF
chmod +x "$T/bin/mktemp"

echo "the shim follows BSD's rule"
check "trailing X's are replaced" bash -c '[[ "$("$1/bin/mktemp" "$2/a.XXXXXX")" != *XXXXXX ]]' _ "$T" "$TMPDIR"
check "inner X's are kept as they are" bash -c '[[ "$("$1/bin/mktemp" "$2/b-XXXXXX.yaml")" == "$2/b-XXXXXX.yaml" ]]' _ "$T" "$TMPDIR"
check "...so the same template fails the second time" bash -c '! "$1/bin/mktemp" "$2/b-XXXXXX.yaml" 2>/dev/null' _ "$T" "$TMPDIR"
rm -f "$TMPDIR/b-XXXXXX.yaml"

# paths_ok <file> - the paths in <file>, one per line: at least two, all
# different, none with a literal XXXXXX, all under $TMPDIR.
paths_ok() {
    local n u
    n=$(wc -l < "$1"); u=$(sort -u "$1" | wc -l)
    (( n >= 2 && n == u )) && ! grep -q XXXXXX "$1" && ! grep -qv "^$TMPDIR/" "$1"
}

echo "grafana k8s: the values files of two installs"
: > "$T/grafana-paths"
for run in 1 2; do
    svc_reset; k8s_world
    svc_run grafana "" "" install "" "$PW" "" "" "" yes "InfluxDB v2" "" "" "" "$PW2" "← back"
    check "install $run finishes (exit 0)" rc_is 0
    check "install $run gave helm its values files" bash -c 'compgen -G "$1/values/*.path" > /dev/null' _ "$STUB_STATE"
    for m in "$STUB_STATE"/values/*.mode; do
        [[ -f "$m" ]] || continue
        check "install $run: $(cat "${m%.mode}.path") was mode 600" bash -c '[[ "$(cat "$1")" == 600 ]]' _ "$m"
        cat "${m%.mode}.path" >> "$T/grafana-paths"
    done
done
check "...every path differs, has no literal X's, and is under \$TMPDIR" paths_ok "$T/grafana-paths"
check "...and every one is removed" bash -c '! xargs ls -d < "$1" 2>/dev/null | grep -q .' _ "$T/grafana-paths"

echo "kind: the cluster config of two creates"
: > "$T/kind-paths"
for run in 1 2; do
    out="$(cd "$T/work" && bash -c '
        gum() { :; }
        source <(sed -n "/^create_generate_config()/,/^}/p" "$1")
        CLUSTER_NAME=c PORT_MAPPINGS=() WORKER_COUNT=1 SVC_BIND_ADDR=127.0.0.1
        create_generate_config && grep -q "^kind: Cluster" "$CONFIG_FILE" && printf "%s\n" "$CONFIG_FILE"
    ' _ "$SVC_DIR/kind/kind.sh" 2>&1)"
    [[ "$out" == */kind-config-XXXXXX.yaml ]] && rm -f "$out"   # main's fixed name: not left in /tmp
    check "create $run writes its config" bash -c '[[ -f "$1" ]]' _ "$out"
    printf '%s\n' "$out" >> "$T/kind-paths"
done
check "...every path differs, has no literal X's, and is under \$TMPDIR" paths_ok "$T/kind-paths"

echo "every mktemp template in scripts/ ends in its X's"
# A template is mktemp's first argument that is not an option; one that is
# not followed by its X's at its end (before the closing quote or paren) is
# a fixed name under BSD. Comment lines are not calls.
bad="$(grep -rnE 'mktemp( -[a-z]+)* +"?[^ "$)-]|mktemp( -[a-z]+)* +"\$' "$SVC_DIR" --include='*.sh' \
    | grep -vE '^[^:]+:[0-9]+: *#' \
    | grep -vE 'mktemp( -[a-z]+)* +"?[^ ")]*X{3,}"?\)' || true)"
check "none ends in anything else${bad:+:
$bad}" test -z "$bad"

echo
if (( FAILS )); then echo "FAIL: $FAILS check(s)"; exit 1; fi
echo "PASS"
