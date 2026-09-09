# Argo Manager

`argo/argo.sh`

Install and manage Argo tools on your Kubernetes clusters:

**Argo Workflows:**

- Install from GitHub releases (`releases/download/<tag>/install.yaml`), port-forward for local access, clean uninstall. Commands: `install`, `status`, `port-forward`, `uninstall`

**Argo CD:**

- Install with the version list from the GitHub releases API but the manifest fetched from `raw.githubusercontent.com/argoproj/argo-cd/<tag>/manifests/install.yaml` (falls back to the `stable` branch for "latest"), retrieve admin password, port-forward with HTTPS, clean uninstall. Commands: `install`, `status`, `port-forward`, `get admin password`, `uninstall`

**Argo Events:**

- Install from GitHub releases (`releases/download`) into the `argo-events` namespace, optionally creating a default JetStream EventBus; status (pods, EventBuses, EventSources); event sources list with per-source webhook port-forward (default local port `12000`); clean uninstall including CRDs. Commands: `install`, `status`, `event sources`, `uninstall`
