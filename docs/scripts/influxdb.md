# InfluxDB 2.x

`influxdb/influxdb.sh`

Follows the shared database-script pattern (see [Databases](../../README.md#databases) in the main README): target picked via `select_target` (Docker, any kind cluster, or any kubeconfig context), multiple named instances, install/status/connect/uninstall actions (no separate `port-forward` action — K8s `connect` starts/stops the port-forward itself).

- Docker image: `influxdb:2` · Port: `8086`
- K8s chart: `influxdata/influxdb2` (https://helm.influxdata.com/ — official InfluxDB 2.x chart/image; replaces the deprecated Bitnami chart)
- Configurable: admin user, password, organisation, bucket, optional admin token (auto-generated if empty)
- Install prompts: image tag and host port (Docker); PVC size, default `8Gi` (K8s)
- Docker `status` runs a `curl` against `/health` (JSON pretty-printed when `python3` is present)
- Connect: web UI at `:8086` (Docker: already mapped; K8s: port-forward, waits for the tunnel with `nc` (netcat) — required but not auto-checked); optionally opens `influx` CLI inside the container
