# Qdrant

`qdrant/qdrant.sh`

Follows the shared database-script pattern (see [Databases](../../README.md#databases) in the main README): Docker or K8s target, multiple named instances, install/status/connect/uninstall actions.

- Docker image: `qdrant/qdrant:latest` · Ports: `6333` (REST) · `6334` (gRPC)
- K8s chart: `qdrant/qdrant` (official Qdrant Helm repo)
- Optional API key authentication
- **Health check**: hits `/` and `/collections`, pretty-prints JSON response
