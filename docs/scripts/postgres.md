# PostgreSQL

`postgres/postgres.sh`

Follows the shared database-script pattern (see [Databases](../../README.md#databases) in the main README): target picked via `select_target` (Docker, any kind cluster, or any kubeconfig context), multiple named instances, install/status/connect/uninstall actions; the K8s menu adds `port-forward`.

- Docker image: `postgres:16` · Port: `5432`
- K8s chart: `groundhog2k/postgres` (https://groundhog2k.github.io/helm-charts/ — deploys the official `postgres` image; replaces the deprecated Bitnami chart)
- K8s secrets (the password): passed to helm in a temporary mode-0600 values file (`-f`, removed afterwards), never `--set` (Kamino 196): so they are not on the command line, where any local user can read them, and arrive exactly (`--set` splits a value at commas and parses `\ . { }` in it)
- Configurable: database name, username, password (auto-generated if empty)
- Install prompts: image tag and host port (Docker); PVC size, default `8Gi` (K8s)
- K8s `port-forward`/`connect` wait for the tunnel with `nc` (netcat) — required but not auto-checked; K8s `connect` also needs a local `psql` (Docker runs `psql` inside the container)
- **Network exposure** (Docker, Kamino 196): the port is published on `127.0.0.1` only, and the install summary prints that address. To reach it from other machines, run the script with `SCOMP_BIND_ADDR` set to an IPv4 address: `0.0.0.0` (every interface, the old behaviour) or one LAN address of this host, e.g. `SCOMP_BIND_ADDR=0.0.0.0 bash scripts/postgres/postgres.sh`. It takes effect when the container is created: re-install (remove and recreate) an existing one to change it. A value that is not an IPv4 address stops the script. K8s port-forwards listen on localhost as before.
