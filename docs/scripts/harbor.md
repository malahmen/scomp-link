# Harbor Container Registry

`harbor/harbor.sh`

Kubernetes only.

- K8s chart: `harbor/harbor` (official Harbor Helm repo)
- Expose: `clusterIP` + port-forward (no ingress required)
- `externalURL` is set to `http://localhost:<port>` at install time, must match the port-forward port for image push/pull to work
- **Storage options** at install:
  - **StorageClass** - dynamic provisioning (covers NFS-backed classes); prompt for class name and registry size
  - **Local path** - hostPath PVs pinned to a selected node; creates PVs + PVCs for all Harbor components (registry, jobservice, database, redis, trivy) under `<base>/<component>` using `DirectoryOrCreate`
- PVs labelled `harbor-release=<name>` for targeted cleanup at uninstall

> For docker push/pull to work via port-forward, add `localhost:<port>` as an insecure registry in your Docker daemon configuration.
