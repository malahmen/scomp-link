# MySQL

`mysql/mysql.sh`

Follows the shared database-script pattern (see [Databases](../../README.md#databases) in the main README): target picked via `select_target` (Docker, any kind cluster, or any kubeconfig context), multiple named instances, install/status/connect/uninstall actions; the K8s menu adds `port-forward`.

- Docker image: `mysql:8.4` · Port: `3306`
- K8s chart: `groundhog2k/mysql` (https://groundhog2k.github.io/helm-charts/ — deploys the official `mysql` image; replaces the deprecated Bitnami chart)
- Configurable: root password, database, username/password
- Install prompts: image tag and host port (Docker); PVC size, default `8Gi` (K8s)
- Connect: Docker runs `mysql` inside the container; K8s uses the local `mysql` client (checked, install hints shown if missing)
- K8s `port-forward`/`connect` wait for the tunnel with `nc` (netcat) — required but not auto-checked
