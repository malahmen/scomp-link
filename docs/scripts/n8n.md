# n8n Workflow Automation

`n8n/n8n.sh`

- Docker image: `n8nio/n8n` · Port: `5678`
- K8s chart: `community-charts/n8n`
- **Database backends**: SQLite (zero-config default) or PostgreSQL (for production / multi-instance)
- **Encryption key**: protects all stored credentials, auto-generated or user-provided; displayed prominently on first install. Changing it after install makes stored credentials unreadable.
- Connect: web UI (Docker: already mapped; K8s: foreground port-forward); first login creates the admin account
