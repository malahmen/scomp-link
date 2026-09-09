# MariaDB

`mariadb/mariadb.sh`

Follows the shared database-script pattern (see [Databases](../../README.md#databases) in the main README): target picked via `select_target` (Docker, any kind cluster, or any kubeconfig context), multiple named instances, install/status/connect/uninstall actions; the K8s menu adds `port-forward`.

- Docker image: `mariadb:11` · Port: `3306`
- K8s chart: `groundhog2k/mariadb` (https://groundhog2k.github.io/helm-charts/ — deploys the official `mariadb` image; replaces the deprecated Bitnami chart)
- Configurable: root password, database, username/password
- Install prompts: image tag and host port (Docker); PVC size, default `8Gi` (K8s)
- Connect: uses `mariadb` client, falls back to `mysql` (Docker: inside the container; K8s: local client, prompted if missing)
- K8s `port-forward`/`connect` wait for the tunnel with `nc` (netcat) — required but not auto-checked
