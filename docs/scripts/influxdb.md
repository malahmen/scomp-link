# InfluxDB 2.x

`influxdb/influxdb.sh`

Follows the shared database-script pattern (see [Databases](../../README.md#databases) in the main README): target picked via `select_target` (Docker, any kind cluster, or any kubeconfig context), multiple named instances, install/status/connect/uninstall actions (no separate `port-forward` action — K8s `connect` starts/stops the port-forward itself).

- Docker image: `influxdb:2` · Port: `8086`
- Docker secrets: the admin password and token are passed to `docker run` as `-e NAME`, the value taken from docker's own environment, so it is not on a command line any local user can read (Kamino 196)
- K8s chart: `influxdata/influxdb2` (https://helm.influxdata.com/ — official InfluxDB 2.x chart/image; replaces the deprecated Bitnami chart)
- K8s secrets (the admin password and token): passed to helm in a temporary mode-0600 values file (`-f`, removed afterwards), never `--set` (Kamino 196): so they are not on the command line, where any local user can read them, and arrive exactly (`--set` splits a value at commas and parses `\ . { }` in it)
- Configurable: admin user, password, organisation, bucket, optional admin token (auto-generated if empty)
- Install prompts: image tag and host port (Docker); PVC size, default `8Gi` (K8s)
- Docker `status` runs a `curl` against `/health` (JSON pretty-printed when `python3` is present)
- Connect: web UI at `:8086` (Docker: already mapped; K8s: port-forward, waits for the tunnel with `nc` (netcat) — required but not auto-checked); optionally opens `influx` CLI inside the container
- **Network exposure** (Docker, Kamino 196): the port is published on `127.0.0.1` only, and the install summary prints that address. To reach it from other machines, run the script with `SCOMP_BIND_ADDR` set to an IPv4 address: `0.0.0.0` (every interface, the old behaviour) or one LAN address of this host, e.g. `SCOMP_BIND_ADDR=0.0.0.0 bash scripts/influxdb/influxdb.sh`. It takes effect when the container is created: re-install (remove and recreate) an existing one to change it. A value that is not an IPv4 address stops the script. K8s port-forwards listen on localhost as before.
