# MySQL

`mysql/mysql.sh`

Follows the shared database-script pattern (see [Databases](../../README.md#databases) in the main README): Docker or K8s target, multiple named instances, install/status/connect/uninstall actions.

- Docker image: `mysql:8.4` · Port: `3306`
- K8s chart: `oci://registry-1.docker.io/bitnamicharts/mysql`
- Configurable: root password, database, username/password
