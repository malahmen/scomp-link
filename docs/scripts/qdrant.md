# Qdrant

`qdrant/qdrant.sh`

Follows the shared database-script pattern (see [Databases](../../README.md#databases) in the main README): target picked via `select_target` (Docker, any kind cluster, or any kubeconfig context), multiple named instances, install/status/health-check/uninstall actions (no `connect`); the K8s menu adds `port-forward` (REST + gRPC).

- Docker image: `qdrant/qdrant:latest` · Ports: `6333` (REST) · `6334` (gRPC)
- Docker secrets: the API key is passed to `docker run` as `-e NAME`, the value taken from docker's own environment, so it is not on a command line any local user can read (Kamino 196)
- K8s chart: `qdrant/qdrant` (official Qdrant Helm repo)
- K8s secrets (the API key): passed to helm in a temporary mode-0600 values file (`-f`, removed afterwards), never `--set` (Kamino 196): so they are not on the command line, where any local user can read them, and arrive exactly (`--set` splits a value at commas and parses `\ . { }` in it)
- Optional API key authentication
- Install prompts: image tag, REST and gRPC host ports (Docker); PVC size, default `10Gi`, and replica count (K8s)
- **Health check**: hits `/` and `/collections` via `curl`; JSON is pretty-printed only when `python3` is present; with an API key set, curl gets the `api-key` header from a config on stdin (`curl -K -`), so the key is not on its command line and reaches Qdrant exactly, spaces and `*` included (Kamino 196)
- K8s `port-forward`/`health-check` wait for the tunnel with `nc` (netcat) — required but not auto-checked
- **Network exposure** (Docker, Kamino 196): the ports are published on `127.0.0.1` only, and the install summary prints that address. To reach them from other machines, run the script with `SCOMP_BIND_ADDR` set to an IPv4 address: `0.0.0.0` (every interface, the old behaviour) or one LAN address of this host, e.g. `SCOMP_BIND_ADDR=0.0.0.0 bash scripts/qdrant/qdrant.sh`. It takes effect when the container is created: re-install (remove and recreate) an existing one to change it. A value that is not an IPv4 address stops the script. K8s port-forwards listen on localhost as before. Likewise set an API key first.
