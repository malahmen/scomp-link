# Harbor Container Registry

`harbor/harbor.sh`

Kubernetes only.

- K8s chart: `harbor/harbor` (official Harbor Helm repo) · Namespace / release: `harbor` / `harbor` (both prompted)
- **Admin password** prompt (user `admin`); leave empty to auto-generate a 24-char one, shown once at install
- Expose: `clusterIP` + port-forward (no ingress required), TLS disabled
- `externalURL` is set to `http://localhost:<port>` at install time (default `8080`), must match the port-forward port for image push/pull to work
- **Storage options** at install:
  - **StorageClass** - dynamic provisioning (covers NFS-backed classes); prompt for class name and registry size
  - **Local path** - hostPath PVs pinned to a selected node; creates PVs + PVCs for all Harbor components (registry, jobservice, database, redis, trivy) under `<base>/<component>` using `DirectoryOrCreate`. Falls back to the cluster default StorageClass if no path or node is given.
- PVs labelled `harbor-release=<name>` for targeted cleanup at uninstall
- **Connect**: background `kubectl port-forward`, PID file `/tmp/scomp-pf-harbor.pid`, toggled from the menu (`connect [● localhost:<port>]` / `[○ stopped]`)
- **Uninstall**: `helm uninstall`, then offers to delete PVs by the `harbor-release` label and to delete the namespace (removes remaining PVCs)
- Menu: `install`, `status`, `connect`, `uninstall`

> For docker push/pull to work via port-forward, add `localhost:<port>` as an insecure registry in your Docker daemon configuration.
