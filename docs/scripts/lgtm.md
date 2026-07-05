# LGTM Stack

`lgtm/lgtm.sh`

Installs and manages the full Grafana observability stack in a single script:

- **Components**: Loki (logs), Grafana (dashboards), Tempo (traces), Mimir (metrics), OpenTelemetry Collector
- **Targets**: kind/k8s (Helm) or Docker Compose
- **Resource profiles**: minimal (kind/local) or standard (production clusters), fully customisable
- **Grafana datasources** auto-provisioned at install: Mimir, Loki, Tempo with trace-to-log correlation
- **Import**: adopt an existing LGTM-shaped install that was deployed outside this script (manual Helm, GitOps, etc.). Probes the current kube-context, detects which components are present in a chosen namespace, and writes a conf so `status` / `port-forward` / `start` / `stop` / `test` work normally against the live stack. Marks the conf with `INSTALL_METHOD=external` so `uninstall` and `purge` double-confirm before acting on a stack the tool didn't deploy.
- **Port-forward toggle**: start/stop per-component tunnels interactively; auto-reconnects across pod restarts
- **Test command**: pushes a sample log, trace, and metric through the stack and prints the exact Grafana Explore queries to find them
- **metrics-server**: offered for install from the status view when `kubectl top` is unavailable
- **Purge**: removes all Helm releases and waits for namespace termination before allowing reinstall
