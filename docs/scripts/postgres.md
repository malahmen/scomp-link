# PostgreSQL

`postgres/postgres.sh`

Follows the shared database-script pattern (see [Databases](../../README.md#databases) in the main README): target picked via `select_target` (Docker, any kind cluster, or any kubeconfig context), multiple named instances, install/status/connect/uninstall actions; the K8s menu adds `port-forward`.

- Docker image: `postgres:16` · Port: `5432`
- K8s chart: `groundhog2k/postgres` (https://groundhog2k.github.io/helm-charts/ — deploys the official `postgres` image; replaces the deprecated Bitnami chart)
- Configurable: database name, username, password (auto-generated if empty)
- Install prompts: image tag and host port (Docker); PVC size, default `8Gi` (K8s)
- K8s `port-forward`/`connect` wait for the tunnel with `nc` (netcat) — required but not auto-checked; K8s `connect` also needs a local `psql` (Docker runs `psql` inside the container)
