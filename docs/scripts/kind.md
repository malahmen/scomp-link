# Kind Cluster Manager

`kind/kind.sh`

Manage Kubernetes-in-Docker clusters with an interactive interface:

- **Create clusters** with custom names, port mappings, and a pinned kind release: the version picker lists kind releases (each bundles a specific K8s version) and runs the chosen one via `mise exec kind@<ver>`. Clusters get 0 workers by default; a name collision offers delete-and-recreate
- **Port conflict detection** before cluster creation (uses `lsof` or `ss` when available)
- **Single-cluster operations**: set as active context (runs `kubectl config use-context`, so it mutates your ambient context), view nodes, get kubeconfig (prints to stdout), export kubeconfig (merges into default or a custom path), export logs (default dir `./kind-logs`), load image, delete
- **Bulk operations**: export kubeconfig (all), export logs (all), load image (all), delete all clusters
- **Dependencies**: hard-requires a running Docker daemon and mise; kind and kubectl are auto-installed via mise if missing
