# Grafana

`grafana/grafana.sh`

- Docker image: `grafana/grafana` · Port: `3000` · Image tag prompted at install
- K8s chart: `grafana/grafana` (official Grafana Helm repo)
- **Admin credentials** prompt (default user `admin`); leave the password empty to auto-generate a 20-char one, shown once at install
- **Datasource provisioning** at install time: Prometheus, InfluxDB v2 (Flux), or custom
  - Docker: written to `~/.config/scomp-link/grafana/<container>/provisioning/` and bind-mounted, persistent across restarts
  - K8s: passed to the Helm chart as a values file (`-f`); the chart renders it as a ConfigMap
- **Plugins**: comma-separated list of plugins to pre-install
- **Docker**: container name chosen per session (default `grafana`), data in the `<container>-data` volume; uninstall optionally removes that volume
- **K8s**: PV size prompt (default `2Gi`) and optional StorageClass name (empty = cluster default)
- **Connect**: Docker port is already mapped. K8s: background `kubectl port-forward`, PID file `/tmp/scomp-pf-grafana.pid`, toggled from the menu (`connect [● localhost:<port>]` / `[○ stopped]`)
