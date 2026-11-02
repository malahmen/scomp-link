# Redis

`redis/redis.sh`

Follows the shared database-script pattern (see [Databases](../../README.md#databases) in the main README): target picked via `select_target` (Docker, any kind cluster, or any kubeconfig context), multiple named instances, install/status/connect/list-queues/uninstall actions; the K8s menu adds `port-forward`. The instance password is prompted once at menu entry on both targets (leave empty for no auth).

- Docker image: `redis:7` · Port: `6379` · Docker install starts `redis-server --appendonly yes` (AOF persistence)
- K8s chart: `groundhog2k/redis` (https://groundhog2k.github.io/helm-charts/ — deploys the official `redis` image; replaces the deprecated Bitnami chart. A password is applied via `requirepass`; leave it empty to run without auth)
- Password via `--requirepass`; `REDISCLI_AUTH` used internally to keep passwords out of `ps` output
- Install prompts: image tag and host port (Docker); PVC size, default `8Gi` (K8s)
- **`list-queues` (queue / key inspector)**: `SCAN`s keys (non-blocking), capped at 500 keys (`RD_QUEUE_SCAN_LIMIT`), reports type and size, sorted by size, useful for inspecting BullMQ, Celery, Sidekiq, and Streams queues
- `redis-cli`: Docker runs it inside the container; K8s uses the local binary, with an auto-install prompt on first use (brew / apt / dnf)
- K8s `port-forward`/`connect` wait for the tunnel with `nc` (netcat) — required but not auto-checked
- **Network exposure** (Docker, Kamino 196): the port is published on `127.0.0.1` only, and the install summary prints that address. To reach it from other machines, run the script with `SCOMP_BIND_ADDR` set to an IPv4 address: `0.0.0.0` (every interface, the old behaviour) or one LAN address of this host, e.g. `SCOMP_BIND_ADDR=0.0.0.0 bash scripts/redis/redis.sh`. It takes effect when the container is created: re-install (remove and recreate) an existing one to change it. A value that is not an IPv4 address stops the script. K8s port-forwards listen on localhost as before. A Redis without a password is open to anyone who reaches the port: set one before publishing beyond `127.0.0.1`.
