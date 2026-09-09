# MongoDB

`mongodb/mongodb.sh`

Follows the shared database-script pattern (see [Databases](../../README.md#databases) in the main README): target picked via `select_target` (Docker, any kind cluster, or any kubeconfig context), multiple named instances, install/status/connect/uninstall actions; the K8s menu adds `port-forward`.

- Docker image: `mongo:7` · Port: `27017`
- K8s chart: `groundhog2k/mongodb` (https://groundhog2k.github.io/helm-charts/ — deploys the official `mongo` image; replaces the deprecated Bitnami chart)
- Configurable: root user/password, app database, username/password — the app user (`readWrite` on the app database) is created on both targets: K8s via chart `userDatabase.*`, Docker via a generated init script under `~/.config/scomp-link/mongodb/<container>/init/` bind-mounted to `/docker-entrypoint-initdb.d` (runs on first init of an empty volume only; removed with the volume on uninstall)
- Install prompts: image tag and host port (Docker); PVC size, default `8Gi` (K8s)
- Connect: uses `mongosh` (falls back to `mongo`); Docker prefers the app user, falls back to root; K8s needs a local shell (prompted if missing) and asks for the authentication database — `admin` for root, the app database for the app user (the chart creates the user there), defaulted from the username you enter
- K8s `port-forward`/`connect` wait for the tunnel with `nc` (netcat) — required but not auto-checked
