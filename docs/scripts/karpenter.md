# Karpenter Manager

`karpenter/karpenter.sh`

Local dev/test install of Karpenter built from source, using KWOK as the simulated cloud provider (no real cloud account needed):

- **Flexible cluster targeting** - connects to the current kubectl context, any existing context, or a Kind cluster. Switches the active kubectl context (`use-context`) to the chosen target
- **Install**: clones/updates the `kubernetes-sigs/karpenter` and `kubernetes-sigs/kwok` sources, installs cert-manager `v1.20.1` and the KWOK operator into the cluster, then builds and deploys with `ko`: `make apply-with-kind` on a kind cluster, or `make apply` with a user-supplied `KWOK_REPO` container registry elsewhere
- **Status**: cert-manager, Karpenter and KWOK pods, plus the current NodePools and NodeClaims (read-only listing; no interactive editing)
- **Uninstall**: `make delete` from source (recommended) or manual CRD/namespace cleanup; optionally also removes KWOK from the cluster and the local source directories
- **Sources** submenu: clone/update all, karpenter only, or kwok only; change work directory; show source info (checked-out revisions)
- **Defaults**: work dir `~/karpenter-local`, namespace `kube-system`
- **Dependencies**: hard `docker` (running daemon), `go`, `git`; soft (offered for install) `ko` via `go install`, `make` via brew/apt/dnf, `kubectl` via mise. `kind` is required only for the kind path and is not auto-installed ("Run kind.sh first")

Commands: `install`, `status`, `uninstall`, `sources`, `quit`
