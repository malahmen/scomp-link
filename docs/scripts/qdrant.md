# Qdrant

`qdrant/qdrant.sh`

Follows the shared database-script pattern (see [Databases](../../README.md#databases) in the main README): target picked via `select_target` (Docker, any kind cluster, or any kubeconfig context), multiple named instances, install/status/health-check/uninstall actions (no `connect`); the K8s menu adds `port-forward` (REST + gRPC).

- Docker image: `qdrant/qdrant:latest` · Ports: `6333` (REST) · `6334` (gRPC)
- K8s chart: `qdrant/qdrant` (official Qdrant Helm repo)
- Optional API key authentication
- Install prompts: image tag, REST and gRPC host ports (Docker); PVC size, default `10Gi`, and replica count (K8s)
- **Health check**: hits `/` and `/collections` via `curl`; JSON is pretty-printed only when `python3` is present
- K8s `port-forward`/`health-check` wait for the tunnel with `nc` (netcat) — required but not auto-checked
