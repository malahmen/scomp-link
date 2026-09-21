#!/usr/bin/env bash
# description: Provision this Debian/Ubuntu machine as a single-node kubeadm control-plane (idempotent)
# -----------------------------------------------------------------------------
# kubeadm-bootstrap.sh — Debian/Ubuntu-native kubeadm bootstrap for a single-node
# control plane that also runs workloads.
#
# Run AS ROOT (or via sudo) ON the machine you want to turn into the cluster.
# Every step checks real system state first and skips what's already done, so
# this is safe to re-run after fixing whatever caused a previous run to fail —
# that is the intended failure-recovery loop: run, hit an error, fix the root
# cause by hand, re-run, repeat until it completes clean.
#
# Required environment variables (no defaults — verify these yourself before
# running rather than trust a guess baked into this script):
#   K8S_MINOR       e.g. v1.31   — check https://pkgs.k8s.io for the current
#                                  supported minor release branch
#   CALICO_VERSION  e.g. v3.29.1 — check Calico's releases page for the
#                                  current manifest tag
#
# Optional overrides:
#   POD_CIDR   (default 10.244.0.0/16 — chosen to NOT overlap a 192.168.0.0/16
#               or 192.168.3.0/24-style LAN; change if your LAN uses 10.244.x)
#
# Usage:
#   K8S_MINOR=v1.31 CALICO_VERSION=v3.29.1 sudo -E ./kubeadm-bootstrap.sh
# -----------------------------------------------------------------------------

set -euo pipefail

# ── helpers (same style as scomp-link/setup.sh) ─────────────────────────────
info()  { printf "\033[0;36m[INFO]  %s\033[0m\n" "$*"; }
ok()    { printf "\033[0;32m[OK]    %s\033[0m\n" "$*"; }
warn()  { printf "\033[0;33m[WARN]  %s\033[0m\n" "$*"; }
fatal() { printf "\033[0;31m[ERROR] %s\033[0m\n" "$*" >&2; exit 1; }

command_exists() { command -v "$1" &>/dev/null; }

# Writes $2 to file $1 only if the content differs (or the file is missing).
# Echoes "changed" or "unchanged" so callers can decide whether to restart
# a dependent service.
write_if_changed() {
    local target="$1" content="$2"
    if [[ -f "$target" ]] && [[ "$(cat "$target")" == "$content" ]]; then
        printf 'unchanged\n'
        return
    fi
    printf '%s\n' "$content" > "$target"
    printf 'changed\n'
}

# ── preconditions ────────────────────────────────────────────────────────────
[[ -f /etc/os-release ]] || fatal "Cannot determine distro (/etc/os-release not found)."
# shellcheck source=/dev/null
source /etc/os-release
case "${ID:-}" in
    debian|ubuntu) ;;
    *) fatal "This script targets Debian and Ubuntu only (found ID=${ID:-unknown}). Refusing to guess on another distro." ;;
esac

: "${K8S_MINOR:?Set K8S_MINOR (e.g. v1.31) after checking the current branch at https://pkgs.k8s.io — no default is assumed on purpose.}"
: "${CALICO_VERSION:?Set CALICO_VERSION (e.g. v3.29.1) after checking the Calico releases page — no default is assumed on purpose.}"
POD_CIDR="${POD_CIDR:-10.244.0.0/16}"

# Self-elevate rather than require the caller to already be root — same idea
# as Akinn's own self-elevation, and needed for this to work when launched
# from scomp-link's TUI picker (which runs scripts as the invoking user, not
# via sudo). -E preserves K8S_MINOR/CALICO_VERSION/POD_CIDR across the re-exec;
# export them (or set them before entering the TUI) so they survive this.
if [[ "$(id -u)" -ne 0 ]]; then
    info "Re-executing with sudo (root is required for kubeadm bootstrap)..."
    exec sudo -E "$0" "$@"
fi

info "${NAME:-Linux} ${VERSION_CODENAME:-unknown}, K8S_MINOR=${K8S_MINOR}, CALICO_VERSION=${CALICO_VERSION}, POD_CIDR=${POD_CIDR}"

# ── real apt sources sanity check ───────────────────────────────────────────
# The exact failure mode we already hit once on this box: a sources.list left
# pointing only at a disabled cdrom entry, so apt "succeeds" against an empty
# index and every install fails with "unable to locate package". Fail fast and
# say so, rather than letting apt-get install below produce a confusing error.
if ! apt-cache policy 2>/dev/null | grep -q 'http'; then
    fatal "No usable apt sources found (apt-cache policy shows no http:// origin). Fix your apt sources first — /etc/apt/sources.list, or /etc/apt/sources.list.d/*.sources on newer installs — then re-run."
fi

# ── swap off (kubeadm hard requirement) ─────────────────────────────────────
if swapon --summary | grep -q .; then
    info "Disabling active swap..."
    swapoff -a
else
    ok "Swap already off."
fi

if grep -qE '^[^#].*\sswap\s' /etc/fstab; then
    info "Commenting out swap entry in /etc/fstab..."
    sed -i -E '/^[^#].*\sswap\s/ s/^/#/' /etc/fstab
else
    ok "/etc/fstab already has no active swap entry."
fi

# ── kernel modules ───────────────────────────────────────────────────────────
mod_state=$(write_if_changed /etc/modules-load.d/k8s.conf $'overlay\nbr_netfilter')
[[ "$mod_state" == "changed" ]] && info "Wrote /etc/modules-load.d/k8s.conf" || ok "/etc/modules-load.d/k8s.conf already correct."
modprobe overlay
modprobe br_netfilter

# ── sysctl params ────────────────────────────────────────────────────────────
sysctl_state=$(write_if_changed /etc/sysctl.d/k8s.conf \
$'net.bridge.bridge-nf-call-iptables  = 1\nnet.bridge.bridge-nf-call-ip6tables = 1\nnet.ipv4.ip_forward                 = 1')
[[ "$sysctl_state" == "changed" ]] && info "Wrote /etc/sysctl.d/k8s.conf" || ok "/etc/sysctl.d/k8s.conf already correct."
sysctl --system > /dev/null

# ── containerd ───────────────────────────────────────────────────────────────
if command_exists containerd; then
    ok "containerd already installed."
else
    info "Installing containerd..."
    apt-get update -qq
    apt-get install -y containerd
fi

containerd_changed=0
if [[ ! -f /etc/containerd/config.toml ]]; then
    info "Generating default containerd config..."
    mkdir -p /etc/containerd
    containerd config default > /etc/containerd/config.toml
    containerd_changed=1
fi
if grep -q 'SystemdCgroup = false' /etc/containerd/config.toml; then
    info "Switching containerd to the systemd cgroup driver..."
    sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
    containerd_changed=1
fi
systemctl enable --now containerd > /dev/null
if [[ "$containerd_changed" -eq 1 ]]; then
    systemctl restart containerd
    ok "containerd configured and restarted."
else
    ok "containerd config already correct."
fi

# ── kubeadm / kubelet / kubectl ──────────────────────────────────────────────
KEYRING=/etc/apt/keyrings/kubernetes-apt-keyring.gpg
REPO_LINE="deb [signed-by=${KEYRING}] https://pkgs.k8s.io/core:/stable:/${K8S_MINOR}/deb/ /"

if [[ -f /etc/apt/sources.list.d/kubernetes.list ]] && grep -qF "$REPO_LINE" /etc/apt/sources.list.d/kubernetes.list; then
    ok "Kubernetes apt repo already configured for ${K8S_MINOR}."
else
    info "Configuring Kubernetes apt repo for ${K8S_MINOR}..."
    apt-get install -y apt-transport-https ca-certificates gpg
    mkdir -p /etc/apt/keyrings
    curl -fsSL "https://pkgs.k8s.io/core:/stable:/${K8S_MINOR}/deb/Release.key" | gpg --dearmor -o "$KEYRING"
    printf '%s\n' "$REPO_LINE" > /etc/apt/sources.list.d/kubernetes.list
    apt-get update -qq
fi

if command_exists kubeadm && command_exists kubelet && command_exists kubectl; then
    installed_minor=$(kubeadm version -o short 2>/dev/null | grep -oE '^v[0-9]+\.[0-9]+')
    if [[ "$installed_minor" != "$K8S_MINOR" ]]; then
        fatal "Installed kubeadm is ${installed_minor:-unknown}, but K8S_MINOR=${K8S_MINOR} was requested.
Switching versions under a possibly-live cluster is destructive (it needs a full reset), so this script
won't do it silently. Do it deliberately:
  sudo kubeadm reset -f
  sudo rm -rf /etc/cni/net.d
  sudo apt-mark unhold kubelet kubeadm kubectl
  apt-cache madison kubeadm | head -5   # find the exact version string for ${K8S_MINOR}
  sudo apt-get install --allow-downgrades -y kubelet=<version> kubeadm=<version> kubectl=<version>
Then re-run this script."
    fi
    ok "kubeadm/kubelet/kubectl already installed at ${installed_minor}."
else
    info "Installing kubeadm, kubelet, kubectl..."
    apt-get install -y kubelet kubeadm kubectl
fi
apt-mark hold kubelet kubeadm kubectl > /dev/null

# ── kubeadm init ─────────────────────────────────────────────────────────────
if [[ -f /etc/kubernetes/admin.conf ]] && KUBECONFIG=/etc/kubernetes/admin.conf kubectl get nodes &>/dev/null; then
    ok "Cluster already initialized (admin.conf present and API server responding). Skipping kubeadm init."
else
    if [[ -d /etc/kubernetes/manifests ]] && [[ -n "$(ls -A /etc/kubernetes/manifests 2>/dev/null)" ]]; then
        # admin.conf is already confirmed unusable above (else we'd have taken
        # the "already initialized" branch) — so this is unambiguously a dead
        # partial init, never a working cluster. Safe to auto-clean, unlike a
        # precondition that could be a false positive on a healthy setup.
        warn "A previous kubeadm init looks like it partially ran (/etc/kubernetes/manifests is non-empty) but admin.conf isn't usable. Cleaning up with 'kubeadm reset -f' before retrying..."
        kubeadm reset -f
        rm -rf /etc/cni/net.d
    fi

    # kubeadm init's preflight talks to the CRI socket, and containerd may be
    # mid-restart right now — either from the config change earlier, or because
    # 'kubeadm reset -f' above unmounted /var/lib/kubelet out from under it and
    # systemd bounced it. Without this wait, init fails preflight with
    # "connection refused" on containerd.sock purely because it asked too early.
    info "Waiting for containerd to answer on its socket..."
    for _ in $(seq 1 60); do
        ctr version &>/dev/null && break
        sleep 1
    done
    ctr version &>/dev/null || fatal "containerd is not responding on /run/containerd/containerd.sock after 60s. Check: systemctl status containerd"

    info "Running kubeadm init (this pulls control-plane images — needs working internet)..."
    kubeadm init --pod-network-cidr="${POD_CIDR}" --cri-socket unix:///run/containerd/containerd.sock
    ok "kubeadm init complete."
fi

export KUBECONFIG=/etc/kubernetes/admin.conf

# ── kubeconfig for the invoking (non-root) user ─────────────────────────────
TARGET_USER="${SUDO_USER:-}"
if [[ -n "$TARGET_USER" ]]; then
    TARGET_HOME=$(getent passwd "$TARGET_USER" | cut -d: -f6)
    mkdir -p "${TARGET_HOME}/.kube"
    cp -f /etc/kubernetes/admin.conf "${TARGET_HOME}/.kube/config"
    chown "$(id -u "$TARGET_USER"):$(id -g "$TARGET_USER")" "${TARGET_HOME}/.kube/config"
    ok "kubeconfig copied to ${TARGET_HOME}/.kube/config (usable as ${TARGET_USER}, no sudo needed for kubectl)."
else
    warn "Running with no SUDO_USER set (invoked as root directly?) — skipping per-user kubeconfig copy. Use /etc/kubernetes/admin.conf directly."
fi

# ── CNI (Calico) ─────────────────────────────────────────────────────────────
# kubectl apply is inherently idempotent — safe to always run.
info "Applying Calico ${CALICO_VERSION}..."
kubectl apply -f "https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/calico.yaml"

# ── untaint for single-node scheduling ──────────────────────────────────────
# Removing a taint that's already gone is a normal, expected outcome on a
# re-run — not a real failure — so it doesn't trip `set -e` here.
kubectl taint nodes --all node-role.kubernetes.io/control-plane- 2>/dev/null || true
ok "Control-plane taint removed (or already absent) — workloads can schedule on this single node."

# ── wait for real readiness before reporting ────────────────────────────────
# Right after applying Calico, the node is NotReady and static pods show
# Pending — that's normal (images still pulling, CNI not up yet), not a
# failure. Poll briefly so the final summary reflects settled state instead
# of a snapshot taken seconds after apply, which looks alarming by
# construction on every single run otherwise.
info "Waiting for node to report Ready (pulling Calico images, CNI coming up — can take a couple of minutes on first run)..."
if kubectl wait --for=condition=Ready node --all --timeout=180s &>/dev/null; then
    ok "Node is Ready."
else
    warn "Node did not reach Ready within 180s — not necessarily broken, first-run image pulls can be slow on a fresh connection. Check manually: kubectl get pods -A"
fi

# ── verify ───────────────────────────────────────────────────────────────────
info "Current state:"
kubectl get nodes -o wide
kubectl get pods -A
