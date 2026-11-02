# MariaDB

`mariadb/mariadb.sh`

Follows the shared database-script pattern (see [Databases](../../README.md#databases) in the main README): target picked via `select_target` (Docker, any kind cluster, or any kubeconfig context), multiple named instances, install/status/connect/uninstall actions; the K8s menu adds `port-forward`.

- Docker image: `mariadb:11` · Port: `3306`
- K8s chart: `groundhog2k/mariadb` (https://groundhog2k.github.io/helm-charts/ — deploys the official `mariadb` image; replaces the deprecated Bitnami chart)
- Configurable: root password, database, username/password
- Install prompts: image tag and host port (Docker); PVC size, default `8Gi` (K8s)
- Connect: uses `mariadb` client, falls back to `mysql` (Docker: inside the container; K8s: local client, prompted if missing)
- K8s `port-forward`/`connect` wait for the tunnel with `nc` (netcat) — required but not auto-checked
- **Network exposure** (Docker, Kamino 196): the port is published on `127.0.0.1` only, and the install summary prints that address. To reach it from other machines, run the script with `SCOMP_BIND_ADDR` set to an IPv4 address: `0.0.0.0` (every interface, the old behaviour) or one LAN address of this host, e.g. `SCOMP_BIND_ADDR=0.0.0.0 bash scripts/mariadb/mariadb.sh`. It takes effect when the container is created: re-install (remove and recreate) an existing one to change it. A value that is not an IPv4 address stops the script. K8s port-forwards listen on localhost as before.
