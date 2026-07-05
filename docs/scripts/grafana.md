# Grafana

`grafana/grafana.sh`

- Docker image: `grafana/grafana` · Port: `3000`
- K8s chart: `grafana/grafana` (official Grafana Helm repo)
- **Datasource provisioning** at install time: Prometheus, InfluxDB v2 (Flux), or custom
  - Docker: written to `~/.config/scomp-link/grafana/<container>/provisioning/` and bind-mounted, persistent across restarts
  - K8s: injected into Helm values via a temp file (`-f`) and stored as a ConfigMap
- **Plugins**: comma-separated list of plugins to pre-install
- Connect: web UI (Docker: already mapped; K8s: foreground port-forward)
