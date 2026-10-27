#!/usr/bin/env bash
# The service scripts act on the cluster that was chosen, and only there
# (Kamino 175). Driven through the gum stub against recording kubectl/helm
# stubs (tests/lib/service-stubs.sh): no real cluster is reached.
#
# They used to `kubectl config use-context <chosen>` - rewriting the user's
# kubeconfig for every terminal - and then run `helm uninstall` and
# `kubectl delete namespace` with no context at all, so a context switched
# meanwhile in another terminal redirected the deletes. What this protects:
#   - no script runs `kubectl config use-context`; the user's current context
#     is the same after the run as before;
#   - every kubectl and helm call that reaches a cluster names the chosen one
#     (--context / --kube-context), deletes included, for k8s and for kind.
set -uo pipefail

# shellcheck source=lib/service-stubs.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/service-stubs.sh"

# Calls that do not touch a cluster: listing contexts, versions, chart repos.
offcluster='^(kubectl config get-contexts|kubectl version|helm version|helm repo)'
cluster_calls() { grep -E '^(kubectl|helm) ' "$STUB_LOG" | grep -vE "$offcluster"; }
# all_carry <context> - every cluster call names it, and there was at least one.
all_carry() {
    local n bad
    n="$(cluster_calls | wc -l)"
    bad="$(cluster_calls | grep -vE -- "^kubectl --context $1 |^helm --kube-context $1 " || true)"
    [[ "$n" -gt 0 && -z "$bad" ]] || { [[ -n "$bad" ]] && printf '        without it: %s\n' "$bad" >&2; return 1; }
}
no_use_context() { ! grep -q 'config use-context' "$STUB_LOG"; }
current_is() { [[ "$(cat "$STUB_STATE/current-context")" == "$1" ]]; }

# k8s_world <release> - two contexts, the user's current one is eks-prod, no
# docker, and <release> installed.
k8s_world() {
    svc_reset
    touch "$STUB_STATE/no-docker"
    printf 'eks-prod\nstub-ctx\n' > "$STUB_STATE/contexts"
    echo eks-prod > "$STUB_STATE/current-context"
    mkdir -p "$STUB_STATE/releases"; : > "$STUB_STATE/releases/$1"
}

# uninstall_case <service> <release> <answer>... - uninstall on stub-ctx while
# the user's current context is eks-prod.
uninstall_case() {
    local svc="$1" rel="$2"; shift 2
    echo "${svc}: uninstall on the chosen context"
    k8s_world "$rel"
    svc_run "$svc" "k8s     stub-ctx" "$@" "← back"
    check "the script finishes (exit 0)" rc_is 0
    check "no kubectl config use-context" no_use_context
    check "the user's current context is untouched" current_is eks-prod
    check "helm uninstall names the chosen context" \
        grep -qE "^helm --kube-context stub-ctx uninstall ${rel} " "$STUB_LOG"
    check "kubectl delete namespace names the chosen context" \
        grep -qE "^kubectl --context stub-ctx delete namespace " "$STUB_LOG"
    check "every cluster call names the chosen context" all_carry stub-ctx
}

#              service    release     menu inputs           action    confirms
uninstall_case postgres   postgresql  "" ""                 uninstall yes yes
uninstall_case mariadb    mariadb     "" ""                 uninstall yes yes
uninstall_case mysql      mysql       "" ""                 uninstall yes yes
uninstall_case mongodb    mongodb     "" ""                 uninstall yes yes
uninstall_case influxdb   influxdb    "" ""                 uninstall yes yes
uninstall_case qdrant     qdrant      "" ""                 uninstall yes yes
uninstall_case n8n        n8n         "" ""                 uninstall yes yes
uninstall_case grafana    grafana     "" ""                 uninstall yes yes
uninstall_case redis      redis       "" "" ""              uninstall yes yes
uninstall_case harbor     harbor      "" ""                 uninstall yes yes yes
uninstall_case prometheus prometheus  "" ""                 uninstall yes yes

echo "harbor: the PersistentVolume delete names the chosen context"
k8s_world harbor
svc_run harbor "k8s     stub-ctx" "" "" uninstall yes yes yes "← back"
check "kubectl delete pv -l harbor-release=... names stub-ctx" \
    grep -qE '^kubectl --context stub-ctx delete pv ' "$STUB_LOG"

echo "postgres: install on the chosen context"
k8s_world unrelated
svc_run postgres "k8s     stub-ctx" "" "" install "" "" "" "" "← back"
check "the script finishes (exit 0)" rc_is 0
check "no kubectl config use-context" no_use_context
check "the user's current context is untouched" current_is eks-prod
check "helm install names the chosen context" grep -qE '^helm --kube-context stub-ctx install ' "$STUB_LOG"
check "the namespace is created on the chosen context" \
    grep -qE '^kubectl --context stub-ctx create namespace postgres' "$STUB_LOG"
check "every cluster call names the chosen context" all_carry stub-ctx

echo "postgres: a kind cluster is addressed as kind-<name>"
svc_reset
touch "$STUB_STATE/no-docker"; echo dev > "$STUB_STATE/kind-clusters"
echo eks-prod > "$STUB_STATE/current-context"
mkdir -p "$STUB_STATE/releases"; : > "$STUB_STATE/releases/postgresql"
svc_run postgres "" "" uninstall yes yes "← back"
check "the script finishes (exit 0)" rc_is 0
check "no kubectl config use-context" no_use_context
check "the user's current context is untouched" current_is eks-prod
check "every cluster call names kind-dev" all_carry kind-dev

echo "lgtm: purge on a kind target from its saved config"
# lgtm read its target with target_type=\$(cfg_require): a subshell, so the
# context flags came out empty and purge's helm uninstall / kubectl delete
# namespace went to the user's current context.
svc_reset
echo eks-prod > "$STUB_STATE/current-context"
mkdir -p "$HOME/.config/lgtm"
printf '%s\n' 'TARGET_TYPE="kind"' 'TARGET_CONTEXT="dev"' 'ENABLED_COMPONENTS="grafana loki"' \
    "HOSTPATH_BASE=\"$T/node-path\"" > "$HOME/.config/lgtm/lgtm.conf"
svc_cmd lgtm purge yes
check "the script finishes (exit 0)" rc_is 0
check "helm uninstall names kind-dev" grep -qE '^helm uninstall grafana .*--kube-context kind-dev' "$STUB_LOG"
check "kubectl delete namespace names kind-dev" grep -qE '^kubectl --context kind-dev delete namespace monitoring' "$STUB_LOG"
check "every cluster call names kind-dev" \
    bash -c "n=\$(grep -cE '^(kubectl|helm) ' '$STUB_LOG'); (( n > 0 )) && ! grep -E '^(kubectl|helm) ' '$STUB_LOG' | grep -vqE -- '--(kube-)?context kind-dev'"
check "the user's current context is untouched" current_is eks-prod
rm -rf "$HOME/.config/lgtm"

echo "no service script or template switches the global context"
check "no 'config use-context' outside kind.sh and karpenter.sh" \
    bash -c "! grep -rn 'kubectl config use-context' '$SVC_DIR' --include='*.sh' \
        | grep -vE '^$SVC_DIR/(kind|karpenter)/' | grep -vE ':[0-9]+: *#'"

echo
if (( FAILS )); then echo "${FAILS} check(s) failed"; exit 1; fi
echo "all checks passed"
