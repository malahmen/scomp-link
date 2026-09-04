# MariaDB

`mariadb/mariadb.sh`

Follows the shared database-script pattern (see [Databases](../../README.md#databases) in the main README): Docker or K8s target, multiple named instances, install/status/connect/uninstall actions.

- Docker image: `mariadb:11` · Port: `3306`
- K8s chart: `groundhog2k/mariadb` (https://groundhog2k.github.io/helm-charts/ — deploys the official `mariadb` image; replaces the deprecated Bitnami chart)
- Configurable: root password, database, username/password
- Connect: uses `mariadb` client, falls back to `mysql`
