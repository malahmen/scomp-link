# Dozzle

`dozzle/dozzle.sh`

Lightweight real-time log viewer for Docker / Kubernetes / kind, installs from rendered manifests (no Helm dependency).

- Docker image: `amir20/dozzle` · Port: `8080` · Version picked interactively from GitHub releases
- **Targets**: Docker (compose) or kind/k8s (rendered manifests applied directly, namespace `dozzle`)
- **RBAC scope** (k8s/kind): cluster-wide (all namespaces) or restricted to a single namespace
- **Storage** (k8s/kind): hostPath PV or NFS-backed PV, PVC `256Mi` with StorageClass `dozzle-manual`; Docker uses a host bind-mount
- **Auth**: optional bcrypt-hashed users via Dozzle's built-in `--auth-provider simple` (hash generation runs `docker run amir20/dozzle generate` so Docker must be reachable when enabling auth). The password reaches `generate` on stdin (Dozzle v11 reads it there), not `--password` on docker's command line; an older Dozzle version that refuses that gets `--password`, with a warning. `users.yml` is written mode 0600 (an existing one is made 0600 too); Dozzle runs as root in its container and still reads it (Kamino 196)
  - On k8s/kind the fresh PVC mounts empty, so `users.yml` cannot be pre-seeded. It is saved to `~/.config/dozzle/workdir/users.yml`; once the pod is Running, `kubectl cp` it to `/data/users.yml` and delete the pod (the script prints the exact commands)
- **Readiness / liveness probes** on `/healthz` to survive kind control-plane warm-up
- **Port-forward** auto-reconnects across pod restarts; `stop` tears it down with the deployment
- **Import**: adopt an existing Dozzle install that was deployed outside this script (docker container or k8s Service named `dozzle`). Detected automatically, if you run any command without a saved config, the script offers to adopt the existing install inline. Marks the conf with `INSTALL_METHOD=external` so `uninstall` double-confirms before acting on something it didn't deploy.
- **Uninstall** (Docker): `docker-compose down -v`; the bind-mounted data folder is deleted only if `dozzle.sh` created it (it marks the folders it creates), and the confirm names it. A folder that already existed is kept; `/` and `$HOME` are refused at install and at uninstall
- Config: `~/.config/dozzle/{dozzle.conf,pf/,workdir/}` (workdir holds the rendered compose file / manifests). The file holds `KEY=value` lines written with shell quoting (`printf %q`) and is parsed, never `source`d (Kamino 196): a value with quotes, `$(...)` or backticks is kept as text and runs nothing; a line the script did not write is skipped with a warning. Files from older versions (`KEY="value"`) still read.
- Commands: `install`, `import`, `uninstall`, `status`, `start`, `stop`, `port-forward`
- **Network exposure** (Docker, Kamino 196): the port is published on `127.0.0.1` only. Dozzle mounts the Docker socket, so it is published elsewhere only with authentication on: `SCOMP_BIND_ADDR=0.0.0.0` (or one LAN address of this host) at `install` is refused while auth is off. To reach it from the LAN, re-run `install` with `SCOMP_BIND_ADDR` set and auth enabled. The address is saved (`BIND_ADDR` in `dozzle.conf`) and written into the compose file; `status` prints it. K8s/kind port-forwards listen on localhost and are unaffected.

> Docker target requires the `docker-compose` v1 binary; it is not checked up front.
