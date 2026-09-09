# Dozzle

`dozzle/dozzle.sh`

Lightweight real-time log viewer for Docker / Kubernetes / kind, installs from rendered manifests (no Helm dependency).

- Docker image: `amir20/dozzle` · Port: `8080` · Version picked interactively from GitHub releases
- **Targets**: Docker (compose) or kind/k8s (rendered manifests applied directly, namespace `dozzle`)
- **RBAC scope** (k8s/kind): cluster-wide (all namespaces) or restricted to a single namespace
- **Storage** (k8s/kind): hostPath PV or NFS-backed PV, PVC `256Mi` with StorageClass `dozzle-manual`; Docker uses a host bind-mount
- **Auth**: optional bcrypt-hashed users via Dozzle's built-in `--auth-provider simple` (hash generation runs `docker run amir20/dozzle generate` so Docker must be reachable when enabling auth)
  - On k8s/kind the fresh PVC mounts empty, so `users.yml` cannot be pre-seeded. It is saved to `~/.config/dozzle/workdir/users.yml`; once the pod is Running, `kubectl cp` it to `/data/users.yml` and delete the pod (the script prints the exact commands)
- **Readiness / liveness probes** on `/healthz` to survive kind control-plane warm-up
- **Port-forward** auto-reconnects across pod restarts; `stop` tears it down with the deployment
- **Import**: adopt an existing Dozzle install that was deployed outside this script (docker container or k8s Service named `dozzle`). Detected automatically, if you run any command without a saved config, the script offers to adopt the existing install inline. Marks the conf with `INSTALL_METHOD=external` so `uninstall` double-confirms before acting on something it didn't deploy.
- **Uninstall** (Docker): `docker-compose down -v` followed by `rm -rf` of the storage path
- Config: `~/.config/dozzle/{dozzle.conf,pf/,workdir/}` (workdir holds the rendered compose file / manifests)
- Commands: `install`, `import`, `uninstall`, `status`, `start`, `stop`, `port-forward`

> Docker target requires the `docker-compose` v1 binary; it is not checked up front.
