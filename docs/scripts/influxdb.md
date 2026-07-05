# InfluxDB 2.x

`influxdb/influxdb.sh`

Follows the shared database-script pattern (see [Databases](../../README.md#databases) in the main README): Docker or K8s target, multiple named instances, install/status/connect/uninstall actions.

- Docker image: `influxdb:2` · Port: `8086`
- K8s chart: `oci://registry-1.docker.io/bitnamicharts/influxdb`
- Configurable: admin user, password, organisation, bucket, optional admin token (auto-generated if empty)
- Connect: web UI at `:8086` (Docker: already mapped; K8s: port-forward); optionally opens `influx` CLI inside the container
