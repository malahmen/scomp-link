# n8n Workflow Automation

`n8n/n8n.sh`

- Docker image: `n8nio/n8n` · Port: `5678` · Image tag prompted at install
- K8s chart: `community-charts/n8n` · Namespace / release: `n8n` / `n8n` (both prompted)
- **Database backends**: SQLite (zero-config default) or PostgreSQL (for production / multi-instance)
- **Encryption key**: protects all stored credentials. Auto-generated (32 chars, displayed once at install) or user-provided (not echoed back). Changing it after install makes stored credentials unreadable.
- **Timezone** prompt (`GENERIC_TIMEZONE`, default `UTC`), Docker only
- **Docker**: data in the `<container>-data` volume; uninstall optionally removes it
- **K8s**: PV size prompt (default `2Gi`) and optional StorageClass name (empty = cluster default)
- **Connect**: Docker port is already mapped. K8s: background `kubectl port-forward`, PID file `/tmp/scomp-pf-n8n.pid`, toggled from the menu (`connect [● localhost:<port>]` / `[○ stopped]`). First login creates the admin account.
