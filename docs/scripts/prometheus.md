# Prometheus

`prometheus/prometheus.sh`

Kubernetes only.

- K8s chart: `prometheus-community/prometheus`
- **Optional components** selected at install: alertmanager, node-exporter, kube-state-metrics, pushgateway
- **Custom `prometheus.yml`**: uploaded as a ConfigMap and wired via `server.configMapOverrideName`, honoured on upgrades
- Connect: foreground port-forward to the web UI (Ctrl+C to stop)
