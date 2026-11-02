# Harbor Container Registry

`harbor/harbor.sh`

Kubernetes only.

- K8s chart: `harbor/harbor` (official Harbor Helm repo) · Namespace / release: `harbor` / `harbor` (both prompted)
- K8s secrets (the admin password): passed to helm in a temporary mode-0600 values file (`-f`, removed afterwards), never `--set` (Kamino 196): so they are not on the command line, where any local user can read them, and arrive exactly (`--set` splits a value at commas and parses `\ . { }` in it)
- **Admin password** prompt (user `admin`); leave empty to auto-generate a 24-char one, shown once at install
- Expose: `clusterIP` + port-forward (no ingress required), TLS disabled
- `externalURL` is set to `http://localhost:<port>` at install time (default `8080`), must match the port-forward port for image push/pull to work
- **Storage options** at install:
  - **StorageClass** - dynamic provisioning (covers NFS-backed classes); prompt for class name and registry size
  - **Local path** - hostPath PVs pinned to a selected node; creates PVs + PVCs for all Harbor components (registry, jobservice, database, redis, trivy) under `<base>/<component>` using `DirectoryOrCreate`. Falls back to the cluster default StorageClass if no path or node is given.
- PVs labelled `harbor-release=<name>` for targeted cleanup at uninstall
- **Connect**: background `kubectl port-forward`, PID file `$XDG_RUNTIME_DIR/scomp-link/pf/harbor.pid` (else `~/.cache/scomp-link/pf/`; a per-user 0700 folder, and a PID file that is a symlink or not yours is refused - Kamino 196), toggled from the menu (`connect [● localhost:<port>]` / `[○ stopped]`)
- **Uninstall**: `helm uninstall`, then offers to delete PVs by the `harbor-release` label and to delete the namespace (removes remaining PVCs)
- Menu: `install`, `status`, `connect`, `uninstall`

> For docker push/pull to work via port-forward, add `localhost:<port>` as an insecure registry in your Docker daemon configuration.
