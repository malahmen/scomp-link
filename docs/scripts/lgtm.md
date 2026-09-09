# LGTM Stack

`lgtm/lgtm.sh`

Installs and manages the Grafana observability stack (Loki, Grafana, Tempo, Mimir, OpenTelemetry Collector) in a single script.

- **Targets**: kind/k8s (Helm, namespace `monitoring`) or Docker (generated compose file)
- **Component picker** at install; chart versions and image tags are pinned in the script (bump them by editing it, `update` only refreshes the repo cache)
- **Helm repos**: `grafana` + `open-telemetry`
- **Resource profiles** (`minimal` / `standard` / `custom`): only offered on plain k8s. kind is forced to `minimal`; Docker has no profiles.
- **Storage** (k8s): hostPath or NFS, each component gets a manual StorageClass + PV named `lgtm-<component>`. Skipped on kind (uses the default dynamic provisioner). Docker: bind-mount base dir prompt (default `~/.config/lgtm/data`).
- **Configs**: on Docker the script writes minimal single-node configs for Loki/Tempo/Mimir/OTel and Grafana datasource provisioning under `<base>/<component>/{config,provisioning}`; existing files are never overwritten
- **Grafana datasources** provisioned on all targets: Mimir (default), Loki, Tempo with trace-to-log correlation
- **Default ports**: Grafana `3000`, Loki `3100`, Tempo `3200`, Mimir `9009`, OTel `4317` (gRPC; `4318` HTTP)
- **Port-forward toggle** (k8s/kind): start/stop per-component tunnels interactively; auto-reconnects across pod restarts. Docker just prints the mapped URLs.
- **Import** (k8s only): adopt an LGTM-shaped install deployed outside this script (manual Helm, GitOps). Probes the kube-context, detects components in a chosen namespace and writes a conf so `status` / `port-forward` / `start` / `stop` / `test` work. Marked `INSTALL_METHOD=external` so `uninstall` / `purge` double-confirm.
- **`update`**: `helm repo update` for both repos, nothing else
- **`uninstall`**: removes the stack (Helm releases, or selected compose services), keeps data
- **`purge`**: also deletes PVs and StorageClasses `lgtm-<component>`, the namespace (waits up to 120s for termination), the hostPath base dir and the config file. Warns if the namespace is still terminating but does not block reinstall.
- **`test`** (k8s/kind only, needs `curl`): pushes a sample log, trace and metric and prints the Grafana Explore queries to find them. Assumes `svc/loki`, `svc/otelcol-opentelemetry-collector` and Grafana `admin`/`admin`; re-runs `helm upgrade` on Grafana first if datasources are missing.
- **metrics-server**: offered from the status view when `kubectl top` is unavailable
- Config: `~/.config/lgtm/{lgtm.conf,pf/,compose/}`
- Commands: `install`, `import`, `uninstall`, `purge`, `status`, `port-forward`, `start`, `stop`, `update`, `test`

> Docker target requires the `docker-compose` v1 binary and `lsof`; neither is checked up front.
