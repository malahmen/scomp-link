# PostgreSQL

`postgres/postgres.sh`

Follows the shared database-script pattern (see [Databases](../../README.md#databases) in the main README): Docker or K8s target, multiple named instances, install/status/connect/uninstall actions.

- Docker image: `postgres:16` · Port: `5432`
- K8s chart: `groundhog2k/postgres` (https://groundhog2k.github.io/helm-charts/ — deploys the official `postgres` image; replaces the deprecated Bitnami chart)
- Configurable: database name, username, password (auto-generated if empty)
