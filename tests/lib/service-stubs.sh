#!/usr/bin/env bash
# Sourced by the service-script tests (test-service-*.sh): a hermetic sandbox
# in which scripts/<service>/<service>.sh runs against recording stubs of
# docker, podman, kubectl, helm and kind. Nothing real is reached: PATH holds
# only tests/stubs (gum), the stubs written here, and the system directories
# /usr/bin:/bin:/usr/sbin:/sbin - not /usr/local/bin or /opt/homebrew/bin,
# where a workstation's real kubectl and helm live (this one has EKS contexts).
#
# State lives in files under $STUB_STATE, so a test arranges a world
# (a container with this env, a volume, a release, a kube-context) and reads
# back every call each stub received from $STUB_LOG, one argv per line.
#
# Sets: T (temp dir), SVC_DIR (scripts/), FAILS, check/has/lacks, svc_run.
# shellcheck disable=SC2016
# Single-quoted heredoc stubs expand their own $1/$@ at run time, on purpose.

SVC_TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SVC_DIR="${SVC_TEST_DIR}/../scripts"

T="$(mktemp -d)"; trap '[[ -n "${KEEP_TMP:-}" ]] && echo "kept: $T" || rm -rf "$T"' EXIT
T="$(cd "$T" && pwd -P)"
FAILS=0
check() { local d="$1"; shift; if "$@"; then echo "   ok   - $d"; else echo "   FAIL - $d"; FAILS=$((FAILS + 1)); fi; }
has()   { grep -qF -- "$1" "$2"; }
lacks() { ! grep -qF -- "$1" "$2"; }

mkdir -p "$T/bin" "$T/home" "$T/work"   # work: the scripts' cwd, so a relative path stays in here
# bash 4+ is what the gum stub and the scripts need; it may live outside the
# system directories (macOS: /bin/bash is 3.2), so it is linked in by name.
ln -s "$(command -v bash)" "$T/bin/bash"

# docker / podman: containers are $STUB_STATE/c/<name>/{env,image}, volumes are
# $STUB_STATE/v/<name>. `run` creates both from its -e and -v arguments.
cat > "$T/bin/docker" <<'EOF'
#!/usr/bin/env bash
printf '%s %s\n' "$(basename "$0")" "$*" >> "$STUB_LOG"
S="$STUB_STATE"; mkdir -p "$S/c" "$S/v"
fmt=""
case "$1" in
    info) [[ ! -e "$S/no-docker" ]]; exit $? ;;
    pull|exec|logs|network|start|stop|restart|cp|compose) exit 0 ;;
    --version|version) echo "Docker version 99.0.0-stub"; exit 0 ;;
    inspect)
        shift
        while [[ $# -gt 1 ]]; do
            case "$1" in --format=*) fmt="${1#--format=}" ;; --format|-f) fmt="$2"; shift ;; esac
            shift
        done
        [[ "$1" == --format=* ]] && exit 1
        name="$1"; [[ -d "$S/c/$name" ]] || exit 1
        case "$fmt" in
            *Config.Env*)   cat "$S/c/$name/env" ;;
            *State.Running*) echo true ;;
            *State.Status*)  echo running ;;
            *Config.Image*)  cat "$S/c/$name/image" ;;
            *Mounts*)        cat "$S/c/$name/mounts" 2>/dev/null ;;
            *NetworkSettings.Ports*) echo "5432/tcp -> 0.0.0.0:5432" ;;
            *) echo '[{}]' ;;
        esac
        exit 0 ;;
    volume)
        case "$2" in
            inspect) [[ -e "$S/v/$3" ]] ;;
            rm)      rm -f "$S/v/$3" ;;
            create)  : > "$S/v/$3" ;;
            ls)      ls "$S/v" ;;
            *)       exit 0 ;;
        esac
        exit $? ;;
    rm)
        for a in "${@:2}"; do [[ "$a" == -* ]] || rm -rf "$S/c/$a"; done; exit 0 ;;
    run)
        shift; name="" env=() mounts=() image=""
        while [[ $# -gt 0 ]]; do
            case "$1" in
                --name) name="$2"; shift 2 ;;
                --name=*) name="${1#--name=}"; shift ;;
                -e|--env) env+=("$2"); shift 2 ;;
                -v|--volume) mounts+=("$2"); shift 2 ;;
                -p|--restart|--network|--user|-u|--entrypoint|-w|--add-host|--label) shift 2 ;;
                -*) shift ;;
                *) image="$1"; break ;;
            esac
        done
        [[ -n "$name" ]] || exit 0
        mkdir -p "$S/c/$name"
        printf '%s\n' "${env[@]}" > "$S/c/$name/env"
        printf '%s\n' "$image" > "$S/c/$name/image"
        printf '%s\n' "${mounts[@]}" > "$S/c/$name/mounts"
        for m in "${mounts[@]}"; do
            src="${m%%:*}"; [[ "$src" == /* ]] || : > "$S/v/$src"
        done
        echo "0123456789ab"; exit 0 ;;
    *) exit 0 ;;
esac
EOF
cp "$T/bin/docker" "$T/bin/podman"

# kubectl: contexts from $STUB_STATE/contexts; `config use-context` writes the
# "global" current context to $STUB_STATE/current-context, as the real one
# writes ~/.kube/config. Namespaces are $STUB_STATE/ns/<name>.
cat > "$T/bin/kubectl" <<'EOF'
#!/usr/bin/env bash
printf 'kubectl %s\n' "$*" >> "$STUB_LOG"
S="$STUB_STATE"; mkdir -p "$S/ns"
args=() ; while [[ $# -gt 0 ]]; do
    case "$1" in
        --context|-n|--namespace) args+=("$1" "$2"); shift 2 ;;
        *) args+=("$1"); shift ;;
    esac
done
set -- "${args[@]}"
pos=(); skip=0
for a in "$@"; do
    if (( skip )); then skip=0; continue; fi
    case "$a" in --context|-n|--namespace) skip=1 ;; -*) ;; *) pos+=("$a") ;; esac
done
case "${pos[0]:-} ${pos[1]:-}" in
    "config get-contexts") cat "$S/contexts" 2>/dev/null ;;
    "config current-context") cat "$S/current-context" 2>/dev/null ;;
    "config use-context") echo "${pos[2]}" > "$S/current-context" ;;
    "get namespace") [[ -d "$S/ns/${pos[2]:-}" ]] || exit 1 ;;
    "create namespace") mkdir -p "$S/ns/${pos[2]}" ;;
    "get nodes") echo "node/stub-node" ;;
    "get secret") [[ -f "$S/secret" ]] && cat "$S/secret" ;;
    "get pvc"|"get pv") cat "$S/${pos[1]}" 2>/dev/null ;;
    *) : ;;
esac
exit 0
EOF

# helm: releases are $STUB_STATE/releases/<name>.
cat > "$T/bin/helm" <<'EOF'
#!/usr/bin/env bash
printf 'helm %s\n' "$*" >> "$STUB_LOG"
S="$STUB_STATE"; mkdir -p "$S/releases"
pos=(); skip=0
for a in "$@"; do
    if (( skip )); then skip=0; continue; fi
    case "$a" in --kube-context|-n|--namespace|--set|--version|-f|--values|--timeout) skip=1 ;; -*) ;; *) pos+=("$a") ;; esac
done
case "${pos[0]:-}" in
    version) echo "v3.99.0-stub" ;;
    status)  [[ -e "$S/releases/${pos[1]}" ]] || exit 1 ;;
    install) : > "$S/releases/${pos[1]}" ;;
    uninstall) rm -f "$S/releases/${pos[1]}" ;;
    repo)    [[ "${pos[1]:-}" == list ]] && cat "$S/helm-repos" 2>/dev/null ;;
    *) : ;;
esac
exit 0
EOF

cat > "$T/bin/kind" <<'EOF'
#!/usr/bin/env bash
printf 'kind %s\n' "$*" >> "$STUB_LOG"
[[ "$1 $2" == "get clusters" ]] && cat "$STUB_STATE/kind-clusters" 2>/dev/null
exit 0
EOF
# docker-compose (v1, what dozzle and lgtm call): records, succeeds.
printf '#!/usr/bin/env bash\nprintf "docker-compose %%s\\n" "$*" >> "$STUB_LOG"\nexit 0\n' > "$T/bin/docker-compose"
# Readiness loops: answer at once, and do not wait.
printf '#!/usr/bin/env bash\nprintf "curl %%s\\n" "$*" >> "$STUB_LOG"\nexit 0\n' > "$T/bin/curl"
printf '#!/usr/bin/env bash\nexit 0\n' > "$T/bin/nc"
printf '#!/usr/bin/env bash\nexit 0\n' > "$T/bin/sleep"
chmod +x "$T/bin/"*

export PATH="${SVC_TEST_DIR}/stubs:$T/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export HOME="$T/home" XDG_CONFIG_HOME="$T/home/.config"
export GUM_ANSWERS="$T/answers" GUM_STATE="$T/gumstate" STUB_LOG="$T/calls" STUB_STATE="$T/state"
mkdir -p "$STUB_STATE"

# svc_reset - an empty world: no containers, volumes, releases, contexts.
svc_reset() { rm -rf "$STUB_STATE"; mkdir -p "$STUB_STATE"; : > "$STUB_LOG"; }

# svc_run <service> <answer>... - runs scripts/<service>/<service>.sh with the
# scripted gum answers; output in $T/out, exit status in $T/rc.
svc_run() {
    local svc="$1"; shift
    printf '%s\n' "$@" > "$GUM_ANSWERS"; : > "$GUM_STATE"; : > "$STUB_LOG"
    (cd "$T/work" && bash "${SVC_DIR}/${svc}/${svc}.sh" > "$T/out" 2>&1 < /dev/null)
    echo $? > "$T/rc"
}
# svc_cmd <service> <subcommand> <answer>... - the same, for the scripts
# driven by a subcommand (dozzle.sh uninstall, lgtm.sh purge).
svc_cmd() {
    local svc="$1" sub="$2"; shift 2
    printf '%s\n' "$@" > "$GUM_ANSWERS"; : > "$GUM_STATE"; : > "$STUB_LOG"
    (cd "$T/work" && bash "${SVC_DIR}/${svc}/${svc}.sh" "$sub" > "$T/out" 2>&1 < /dev/null)
    echo $? > "$T/rc"
}
rc_is() { [[ "$(cat "$T/rc")" == "$1" ]]; }
