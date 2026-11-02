# MySQL

`mysql/mysql.sh`

Follows the shared database-script pattern (see [Databases](../../README.md#databases) in the main README): target picked via `select_target` (Docker, any kind cluster, or any kubeconfig context), multiple named instances, install/status/connect/uninstall actions; the K8s menu adds `port-forward`.

- Docker image: `mysql:8.4` · Port: `3306`
- Docker secrets: the passwords are passed to `docker run` as `-e NAME`, the value taken from docker's own environment, so it is not on a command line any local user can read (Kamino 196); the readiness ping and `connect` give the client its password as `MYSQL_PWD` (passed the same way), not `-p`
- K8s chart: `groundhog2k/mysql` (https://groundhog2k.github.io/helm-charts/ — deploys the official `mysql` image; replaces the deprecated Bitnami chart)
- K8s secrets (the root and user passwords): passed to helm in a temporary mode-0600 values file (`-f`, removed afterwards), never `--set` (Kamino 196): so they are not on the command line, where any local user can read them, and arrive exactly (`--set` splits a value at commas and parses `\ . { }` in it)
- Configurable: root password, database, username/password
- Install prompts: image tag and host port (Docker); PVC size, default `8Gi` (K8s)
- Connect: Docker runs `mysql` inside the container; K8s uses the local `mysql` client (checked, install hints shown if missing)
- K8s `port-forward`/`connect` wait for the tunnel with `nc` (netcat) — required but not auto-checked
- **Network exposure** (Docker, Kamino 196): the port is published on `127.0.0.1` only, and the install summary prints that address. To reach it from other machines, run the script with `SCOMP_BIND_ADDR` set to an IPv4 address: `0.0.0.0` (every interface, the old behaviour) or one LAN address of this host, e.g. `SCOMP_BIND_ADDR=0.0.0.0 bash scripts/mysql/mysql.sh`. It takes effect when the container is created: re-install (remove and recreate) an existing one to change it. A value that is not an IPv4 address stops the script. K8s port-forwards listen on localhost as before.
