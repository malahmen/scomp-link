# Redis

`redis/redis.sh`

Follows the shared database-script pattern (see [Databases](../../README.md#databases) in the main README): Docker or K8s target, multiple named instances, install/status/connect/uninstall actions.

- Docker image: `redis:7` · Port: `6379`
- K8s chart: `groundhog2k/redis` (https://groundhog2k.github.io/helm-charts/ — deploys the official `redis` image; replaces the deprecated Bitnami chart. A password is applied via `requirepass`; leave it empty to run without auth)
- Password via `--requirepass`; `REDISCLI_AUTH` used internally to keep passwords out of `ps` output
- **Queue / key inspector**: scans all keys using `SCAN` (non-blocking), reports type and size, sorted by size, useful for inspecting BullMQ, Celery, Sidekiq, and Streams queues
- `redis-cli` auto-install: prompted on first use (brew / apt / dnf)
