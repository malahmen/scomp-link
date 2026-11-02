# n8n Workflow Automation

`n8n/n8n.sh`

- Docker image: `n8nio/n8n` · Port: `5678` · Image tag prompted at install
- K8s chart: `community-charts/n8n` · Namespace / release: `n8n` / `n8n` (both prompted)
- **Database backends**: SQLite (zero-config default) or PostgreSQL (for production / multi-instance)
- **Encryption key**: protects all stored credentials. Auto-generated (32 chars, displayed once at install) or user-provided (not echoed back). Changing it after install makes stored credentials unreadable.
- **Timezone** prompt (`GENERIC_TIMEZONE`, default `UTC`), Docker only
- **Docker**: data in the `<container>-data` volume; uninstall optionally removes it
- **K8s**: PV size prompt (default `2Gi`) and optional StorageClass name (empty = cluster default)
- **Connect**: Docker port is already mapped. K8s: background `kubectl port-forward`, PID file `$XDG_RUNTIME_DIR/scomp-link/pf/n8n.pid` (else `~/.cache/scomp-link/pf/`; a per-user 0700 folder, and a PID file that is a symlink or not yours is refused - Kamino 196), toggled from the menu (`connect [● localhost:<port>]` / `[○ stopped]`). First login creates the admin account.
- **Network exposure** (Docker, Kamino 196): the port is published on `127.0.0.1` only, and the install summary prints that address. To reach it from other machines, run the script with `SCOMP_BIND_ADDR` set to an IPv4 address: `0.0.0.0` (every interface, the old behaviour) or one LAN address of this host, e.g. `SCOMP_BIND_ADDR=0.0.0.0 bash scripts/n8n/n8n.sh`. It takes effect when the container is created: re-install (remove and recreate) an existing one to change it. A value that is not an IPv4 address stops the script. K8s port-forwards listen on localhost as before.
