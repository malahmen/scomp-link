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
- **Connect**: Docker port is already mapped. K8s: background `kubectl port-forward`, PID file `$XDG_RUNTIME_DIR/scomp-link/pf/grafana.pid` (else `~/.cache/scomp-link/pf/`; a per-user 0700 folder, and a PID file that is a symlink or not yours is refused - Kamino 196), toggled from the menu (`connect [● localhost:<port>]` / `[○ stopped]`)
- **Network exposure** (Docker, Kamino 196): the port is published on `127.0.0.1` only, and the install summary prints that address. To reach it from other machines, run the script with `SCOMP_BIND_ADDR` set to an IPv4 address: `0.0.0.0` (every interface, the old behaviour) or one LAN address of this host, e.g. `SCOMP_BIND_ADDR=0.0.0.0 bash scripts/grafana/grafana.sh`. It takes effect when the container is created: re-install (remove and recreate) an existing one to change it. A value that is not an IPv4 address stops the script. K8s port-forwards listen on localhost as before.
