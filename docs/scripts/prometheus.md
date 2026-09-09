# Prometheus

`prometheus/prometheus.sh`

Kubernetes only.

- K8s chart: `prometheus-community/prometheus` · Namespace / release: `monitoring` / `prometheus` (both prompted)
- **Optional components** selected at install: alertmanager, node-exporter, kube-state-metrics, pushgateway
- **PV size** prompt for the server (default `8Gi`)
- **Custom `prometheus.yml`**: uploaded as a ConfigMap and wired via `server.configMapOverrideName`, honoured on upgrades
- Re-running `install` on an existing release upgrades it in place
- **Connect**: background `kubectl port-forward` to `<release>-server:80`, default local port `9090`; PID file `/tmp/scomp-pf-prometheus.pid`. Toggled from the menu (`connect [● localhost:<port>]` stops it, `connect [○ stopped]` starts it). Readiness is polled with `nc`.
- **Uninstall**: `helm uninstall`, then optionally deletes the namespace (removes remaining PVCs)
- Menu: `install`, `status`, `connect`, `uninstall`
