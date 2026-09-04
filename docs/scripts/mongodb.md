# MongoDB

`mongodb/mongodb.sh`

Follows the shared database-script pattern (see [Databases](../../README.md#databases) in the main README): Docker or K8s target, multiple named instances, install/status/connect/uninstall actions.

- Docker image: `mongo:7` · Port: `27017`
- K8s chart: `groundhog2k/mongodb` (https://groundhog2k.github.io/helm-charts/ — deploys the official `mongo` image; replaces the deprecated Bitnami chart)
- Configurable: root user/password, app database, username/password
- Connect: uses `mongosh` (falls back to `mongo`)
