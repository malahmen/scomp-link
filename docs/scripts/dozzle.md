# Dozzle

`dozzle/dozzle.sh`

Lightweight real-time log viewer for Docker / Kubernetes / kind, installs from rendered manifests (no Helm dependency).

- Docker image: `amir20/dozzle` · Port: `8080`
- **Targets**: Docker (compose) or kind/k8s (rendered manifests applied directly)
- **RBAC scope** (k8s/kind): cluster-wide (all namespaces) or restricted to a single namespace
- **Storage** (k8s/kind): hostPath PV or NFS-backed PV; Docker uses a host bind-mount
- **Auth**: optional bcrypt-hashed users via Dozzle's built-in `--auth-provider simple` (hash generation runs `docker run amir20/dozzle generate` so Docker must be reachable when enabling auth)
- **Readiness / liveness probes** on `/healthz` to survive kind control-plane warm-up
- **Port-forward** auto-reconnects across pod restarts; `stop` tears it down with the deployment
- **Import**: adopt an existing Dozzle install that was deployed outside this script (docker container or k8s Service named `dozzle`). Detected automatically, if you run any command without a saved config, the script offers to adopt the existing install inline. Marks the conf with `INSTALL_METHOD=external` so `uninstall` double-confirms before acting on something it didn't deploy.
- Commands: `install`, `import`, `uninstall`, `status`, `start`, `stop`, `port-forward`
