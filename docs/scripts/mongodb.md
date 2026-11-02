# MongoDB

`mongodb/mongodb.sh`

Follows the shared database-script pattern (see [Databases](../../README.md#databases) in the main README): target picked via `select_target` (Docker, any kind cluster, or any kubeconfig context), multiple named instances, install/status/connect/uninstall actions; the K8s menu adds `port-forward`.

- Docker image: `mongo:7` · Port: `27017`
- K8s chart: `groundhog2k/mongodb` (https://groundhog2k.github.io/helm-charts/ — deploys the official `mongo` image; replaces the deprecated Bitnami chart)
- K8s secrets (the root and app passwords): passed to helm in a temporary mode-0600 values file (`-f`, removed afterwards), never `--set` (Kamino 196): so they are not on the command line, where any local user can read them, and arrive exactly (`--set` splits a value at commas and parses `\ . { }` in it)
- Configurable: root user/password, app database, username/password — the app user (`readWrite` on the app database) is created on both targets: K8s via chart `userDatabase.*`, Docker via a generated init script under `~/.config/scomp-link/mongodb/<container>/init/` bind-mounted to `/docker-entrypoint-initdb.d` (runs on first init of an empty volume only; removed with the volume on uninstall)
- Install prompts: image tag and host port (Docker); PVC size, default `8Gi` (K8s)
- Connect: uses `mongosh` (falls back to `mongo`); Docker prefers the app user, falls back to root; K8s needs a local shell (prompted if missing) and asks for the authentication database — `admin` for root, the app database for the app user (the chart creates the user there), defaulted from the username you enter
- K8s `port-forward`/`connect` wait for the tunnel with `nc` (netcat) — required but not auto-checked
- **Network exposure** (Docker, Kamino 196): the port is published on `127.0.0.1` only, and the install summary prints that address. To reach it from other machines, run the script with `SCOMP_BIND_ADDR` set to an IPv4 address: `0.0.0.0` (every interface, the old behaviour) or one LAN address of this host, e.g. `SCOMP_BIND_ADDR=0.0.0.0 bash scripts/mongodb/mongodb.sh`. It takes effect when the container is created: re-install (remove and recreate) an existing one to change it. A value that is not an IPv4 address stops the script. K8s port-forwards listen on localhost as before.
