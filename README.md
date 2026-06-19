# Scomp-Link

A TUI-powered shell script launcher and management framework. Drop your scripts into the folder and access them through a beautiful interactive menu.

## What is Scomp-Link?

Scomp-Link is a **framework for organizing and launching shell scripts** via an interactive terminal interface. It automatically discovers any `.sh` script in its directory and presents them in a gum-powered TUI menu.

**Use it to:**

- Organize your personal automation scripts in one place
- Launch scripts without remembering file names or paths
- Share script collections with your team
- Build your own TUI-driven tooling

## Features

- **Auto-Discovery** - Any `.sh` file in the directory appears in the menu automatically
- **Interactive TUI** - Powered by [gum](https://github.com/charmbracelet/gum) for beautiful terminal interfaces
- **Zero Config** - Just drop scripts in and they work
- **Cross-Platform** - Supports macOS, Linux, and Windows (via WSL)
- **Bash 4+ Handling** - Automatically finds modern bash on macOS (which ships with bash 3.2)

## Included Scripts

Scomp-Link comes with several ready-to-use scripts organized by category:

### Infrastructure

| Script         | Description                                     |
| -------------- | ----------------------------------------------- |
| `kind.sh`      | Create and manage Kind Kubernetes clusters      |
| `karpenter.sh` | Install and manage Karpenter on any K8s cluster |
| `argo.sh`      | Install and manage Argo Workflows & Argo CD     |

### Databases

| Script        | Targets      | Description                                    |
| ------------- | ------------ | ---------------------------------------------- |
| `postgres.sh` | Docker · K8s | PostgreSQL - install, connect, manage          |
| `mariadb.sh`  | Docker · K8s | MariaDB - install, connect, manage             |
| `mysql.sh`    | Docker · K8s | MySQL - install, connect, manage               |
| `mongodb.sh`  | Docker · K8s | MongoDB - install, connect, manage             |
| `redis.sh`    | Docker · K8s | Redis - install, connect, queue listing        |
| `qdrant.sh`   | Docker · K8s | Qdrant vector database - install, health-check |
| `influxdb.sh` | Docker · K8s | InfluxDB 2.x time-series database              |

### Observability

| Script          | Targets      | Description                                         |
| --------------- | ------------ | --------------------------------------------------- |
| `lgtm.sh`       | Docker · K8s | Full LGTM stack (Loki, Grafana, Tempo, Mimir, OTel) |
| `prometheus.sh` | K8s          | Prometheus with optional components                 |
| `grafana.sh`    | Docker · K8s | Grafana with datasource provisioning                |
| `dozzle.sh`     | Docker · K8s | Real-time container log viewer (no Helm required)   |

### Platform

| Script      | Targets      | Description               |
| ----------- | ------------ | ------------------------- |
| `harbor.sh` | K8s          | Harbor container registry |
| `n8n.sh`    | Docker · K8s | n8n workflow automation   |

### Utilities

| Script               | Description                                     |
| -------------------- | ----------------------------------------------- |
| `starlight_astro.sh` | Create and manage Starlight documentation sites |
| `file_conversion.sh` | Convert documents (MD, PDF, DOCX)               |
| `sshger.sh`          | Manage SSH profiles in `~/.ssh/config`          |

---

## Quick Start

```bash
# Clone the repository
git clone https://github.com/your-username/scomp-link.git
cd scomp-link

# Run the bootstrap installer (one-time setup)
./setup.sh
```

The setup script will:

1. Detect your operating system
2. Install required dependencies (mise, gum, vim, tree)
3. Optionally install Node.js LTS
4. Launch the main menu

## Requirements

### Automatically Installed

- [mise](https://mise.jdx.dev/) - Version manager for development tools
- [gum](https://github.com/charmbracelet/gum) - TUI library
- vim - Text editor
- tree - Directory visualization

### System Requirements

- **macOS**: Xcode Command Line Tools (`xcode-select --install`)
- **Linux**: apt (Debian/Ubuntu) or dnf (Fedora/RHEL) package manager
- **Windows**: WSL2 with a Linux distribution installed

### Optional Dependencies

| Tool                        | Required For                                          |
| --------------------------- | ----------------------------------------------------- |
| Docker                      | Any Docker-target script                              |
| kubectl                     | Any Kubernetes-target script                          |
| helm                        | K8s database, observability, and platform scripts     |
| kind                        | Kind cluster management                               |
| Node.js                     | Starlight documentation sites                         |
| pandoc                      | Document conversion                                   |
| TeX Live (xelatex/lualatex) | PDF generation                                        |
| redis-cli                   | Redis connect and queue listing (prompted at runtime) |
| jq                          | SSH profile manager (`sshger.sh`)                     |

> **Helm and kubectl** are checked at runtime and can be auto-installed via `mise` if missing.

## Usage

After setup, run the main launcher:

```bash
./init.sh
```

Or re-run setup to bootstrap dependencies:

```bash
./setup.sh
```

## Adding Your Own Scripts

Create a folder under `scripts/` and drop your `.sh` file inside it:

```bash
# Example: add your custom script
mkdir -p scripts/deploy
cp ~/my-scripts/deploy.sh scripts/deploy/

# It will appear in the menu next time you run init.sh
./init.sh
```

**That's it.** The launcher auto-discovers all `.sh` files one level deep inside `scripts/` (excluding folders listed in `EXCLUDED_DIRS`, such as `_common`).

### Script Guidelines

For best results, your scripts should:

1. **Use gum for interaction** - Provides consistent UX across all scripts
2. **Start with the shebang** - `#!/usr/bin/env bash`
3. **Use strict mode** - `set -euo pipefail`
4. **Source `_common/`** - Use the shared helpers instead of duplicating them

Example script template:

```bash
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../_common/ui.sh"
source "${SCRIPT_DIR}/../_common/cluster.sh"

# Check dependencies
command -v gum &>/dev/null || { echo "[error] gum is required. Run setup.sh first." >&2; exit 1; }

header "My Script"

# Your script logic here
ACTION=$(gum choose "Option 1" "Option 2" "Quit")

case "$ACTION" in
    "Option 1") info "Running option 1..." ;;
    "Option 2") info "Running option 2..." ;;
    "Quit") exit 0 ;;
esac
```

---

## Included Scripts Reference

### Infrastructure

#### Kind Cluster Manager (`kind/kind.sh`)

Manage Kubernetes-in-Docker clusters with an interactive interface:

- **Create clusters** with custom names, K8s versions, and port mappings
- **Port conflict detection** before cluster creation
- **Single-cluster operations**: view nodes, export kubeconfig/logs, load images, delete
- **Bulk operations**: export all configs, delete all clusters

#### Karpenter Manager (`karpenter/karpenter.sh`)

Install and manage Karpenter on any Kubernetes cluster (not just Kind):

- **Flexible cluster targeting** - connects to the current kubectl context, any existing context, or a Kind cluster
- **Build and deploy** using `ko` for local development
- **Manage NodePools and NodeClasses** interactively

#### Argo Manager (`argo/argo.sh`)

Install and manage Argo tools on your Kubernetes clusters:

**Argo Workflows:**

- Install from GitHub releases, port-forward for local access, clean uninstall

**Argo CD:**

- Install from GitHub releases, retrieve admin password, port-forward with HTTPS, clean uninstall

---

### Databases

All database scripts follow the same pattern:

- **Docker target**: runs a local container with a named data volume
- **K8s target**: installs via Bitnami Helm chart into a configurable namespace and release name
- **Multiple instances**: namespace and Helm release name are prompted at session start, so multiple instances of the same database can coexist
- **Actions**: install, status, connect, uninstall (port-forward where applicable)

#### PostgreSQL (`postgres/postgres.sh`)

- Docker image: `postgres:16` · Port: `5432`
- K8s chart: `oci://registry-1.docker.io/bitnamicharts/postgresql`
- Configurable: database name, username, password (auto-generated if empty)

#### MariaDB (`mariadb/mariadb.sh`)

- Docker image: `mariadb:11` · Port: `3306`
- K8s chart: `oci://registry-1.docker.io/bitnamicharts/mariadb`
- Configurable: root password, database, username/password
- Connect: uses `mariadb` client, falls back to `mysql`

#### MySQL (`mysql/mysql.sh`)

- Docker image: `mysql:8.4` · Port: `3306`
- K8s chart: `oci://registry-1.docker.io/bitnamicharts/mysql`
- Configurable: root password, database, username/password

#### MongoDB (`mongodb/mongodb.sh`)

- Docker image: `mongo:7` · Port: `27017`
- K8s chart: `oci://registry-1.docker.io/bitnamicharts/mongodb`
- Configurable: root user/password, app database, username/password
- Connect: uses `mongosh` (falls back to `mongo`)

#### Redis (`redis/redis.sh`)

- Docker image: `redis:7` · Port: `6379`
- K8s chart: `oci://registry-1.docker.io/bitnamicharts/redis`
- Password via `--requirepass`; `REDISCLI_AUTH` used internally to keep passwords out of `ps` output
- **Queue / key inspector**: scans all keys using `SCAN` (non-blocking), reports type and size, sorted by size, useful for inspecting BullMQ, Celery, Sidekiq, and Streams queues
- `redis-cli` auto-install: prompted on first use (brew / apt / dnf)

#### Qdrant (`qdrant/qdrant.sh`)

- Docker image: `qdrant/qdrant:latest` · Ports: `6333` (REST) · `6334` (gRPC)
- K8s chart: `qdrant/qdrant` (official Qdrant Helm repo)
- Optional API key authentication
- **Health check**: hits `/` and `/collections`, pretty-prints JSON response

#### InfluxDB 2.x (`influxdb/influxdb.sh`)

- Docker image: `influxdb:2` · Port: `8086`
- K8s chart: `oci://registry-1.docker.io/bitnamicharts/influxdb`
- Configurable: admin user, password, organisation, bucket, optional admin token (auto-generated if empty)
- Connect: web UI at `:8086` (Docker: already mapped; K8s: port-forward); optionally opens `influx` CLI inside the container

---

### Observability

#### Prometheus (`prometheus/prometheus.sh`)

Kubernetes only.

- K8s chart: `prometheus-community/prometheus`
- **Optional components** selected at install: alertmanager, node-exporter, kube-state-metrics, pushgateway
- **Custom `prometheus.yml`**: uploaded as a ConfigMap and wired via `server.configMapOverrideName`, honoured on upgrades
- Connect: foreground port-forward to the web UI (Ctrl+C to stop)

#### LGTM Stack (`lgtm/lgtm.sh`)

Installs and manages the full Grafana observability stack in a single script:

- **Components**: Loki (logs), Grafana (dashboards), Tempo (traces), Mimir (metrics), OpenTelemetry Collector
- **Targets**: kind/k8s (Helm) or Docker Compose
- **Resource profiles**: minimal (kind/local) or standard (production clusters), fully customisable
- **Grafana datasources** auto-provisioned at install: Mimir, Loki, Tempo with trace-to-log correlation
- **Import**: adopt an existing LGTM-shaped install that was deployed outside this script (manual Helm, GitOps, etc.). Probes the current kube-context, detects which components are present in a chosen namespace, and writes a conf so `status` / `port-forward` / `start` / `stop` / `test` work normally against the live stack. Marks the conf with `INSTALL_METHOD=external` so `uninstall` and `purge` double-confirm before acting on a stack the tool didn't deploy.
- **Port-forward toggle**: start/stop per-component tunnels interactively; auto-reconnects across pod restarts
- **Test command**: pushes a sample log, trace, and metric through the stack and prints the exact Grafana Explore queries to find them
- **metrics-server**: offered for install from the status view when `kubectl top` is unavailable
- **Purge**: removes all Helm releases and waits for namespace termination before allowing reinstall

#### Grafana (`grafana/grafana.sh`)

- Docker image: `grafana/grafana` · Port: `3000`
- K8s chart: `grafana/grafana` (official Grafana Helm repo)
- **Datasource provisioning** at install time: Prometheus, InfluxDB v2 (Flux), or custom
  - Docker: written to `~/.config/scomp-link/grafana/<container>/provisioning/` and bind-mounted, persistent across restarts
  - K8s: injected into Helm values via a temp file (`-f`) and stored as a ConfigMap
- **Plugins**: comma-separated list of plugins to pre-install
- Connect: web UI (Docker: already mapped; K8s: foreground port-forward)

#### Dozzle (`dozzle/dozzle.sh`)

Lightweight real-time log viewer for Docker / Kubernetes / kind — installs from rendered manifests (no Helm dependency).

- Docker image: `amir20/dozzle` · Port: `8080`
- **Targets**: Docker (compose) or kind/k8s (rendered manifests applied directly)
- **RBAC scope** (k8s/kind): cluster-wide (all namespaces) or restricted to a single namespace
- **Storage** (k8s/kind): hostPath PV or NFS-backed PV; Docker uses a host bind-mount
- **Auth**: optional bcrypt-hashed users via Dozzle's built-in `--auth-provider simple` (hash generation runs `docker run amir20/dozzle generate` so Docker must be reachable when enabling auth)
- **Readiness / liveness probes** on `/healthz` to survive kind control-plane warm-up
- **Port-forward** auto-reconnects across pod restarts; `stop` tears it down with the deployment
- **Import**: adopt an existing Dozzle install that was deployed outside this script (docker container or k8s Service named `dozzle`). Detected automatically — if you run any command without a saved config, the script offers to adopt the existing install inline. Marks the conf with `INSTALL_METHOD=external` so `uninstall` double-confirms before acting on something it didn't deploy.
- Commands: `install`, `import`, `uninstall`, `status`, `start`, `stop`, `port-forward`

---

### Platform

#### Harbor Container Registry (`harbor/harbor.sh`)

Kubernetes only.

- K8s chart: `harbor/harbor` (official Harbor Helm repo)
- Expose: `clusterIP` + port-forward (no ingress required)
- `externalURL` is set to `http://localhost:<port>` at install time, must match the port-forward port for image push/pull to work
- **Storage options** at install:
  - **StorageClass** - dynamic provisioning (covers NFS-backed classes); prompt for class name and registry size
  - **Local path** - hostPath PVs pinned to a selected node; creates PVs + PVCs for all Harbor components (registry, jobservice, database, redis, trivy) under `<base>/<component>` using `DirectoryOrCreate`
- PVs labelled `harbor-release=<name>` for targeted cleanup at uninstall

> For docker push/pull to work via port-forward, add `localhost:<port>` as an insecure registry in your Docker daemon configuration.

#### n8n Workflow Automation (`n8n/n8n.sh`)

- Docker image: `n8nio/n8n` · Port: `5678`
- K8s chart: `community-charts/n8n`
- **Database backends**: SQLite (zero-config default) or PostgreSQL (for production / multi-instance)
- **Encryption key**: protects all stored credentials, auto-generated or user-provided; displayed prominently on first install. Changing it after install makes stored credentials unreadable.
- Connect: web UI (Docker: already mapped; K8s: foreground port-forward); first login creates the admin account

---

### Utilities

#### Starlight Documentation (`starlight/starlight_astro.sh`)

Create and manage Astro Starlight documentation sites:

- **Project creation** with optional Mermaid diagram support
- **Sidebar management** (autogenerate or manual mode)
- **Section management** (add, rename, remove, reorder)
- **External links** (top-level, grouped, or homepage-only)
- **Content editing** with vim integration
- **Project discovery** to manage existing sites

#### SSH Profile Manager (`ssh/sshger.sh`)

Manage SSH connection profiles directly in `~/.ssh/config`. The script owns a delimited managed section (between `# BEGIN sshger` / `# END sshger` markers); everything outside that section is left untouched, and existing unmanaged hosts can be imported.

**Actions:**

- **add** — create a profile, generate a new `ed25519` / `rsa-4096` key (or reuse an existing one), and copy the public key to the clipboard
- **import** — pull existing `Host` entries from outside the managed section into management, optionally removing the originals
- **remove** — delete a profile (optionally its key files too)
- **view** — show profile details and the public key
- **edit** — change host / hostname / user / port / key path
- **use** — wire a profile to the current git repo (rewrites `origin` URL, optionally sets local `user.name` / `user.email`)
- **test** — verify the SSH connection for a profile (single host or all hosts)
- **list** — show all managed profiles

**Dependencies:** `jq` (prompted on first run if missing).

#### Document Conversion (`file_conversion/file_conversion.sh`)

Convert documents between formats with extensive customization:

**Supported Conversions:**

- Markdown to PDF (multiple engines: xelatex, lualatex, pdflatex, wkhtmltopdf, weasyprint)
- Markdown to DOCX
- DOCX to Markdown (with media extraction)

**Features:**

- Font selection (Helvetica, Times, Georgia, Palatino, etc.)
- Title page injection with templates
- Syntax highlighting for code blocks
- Mermaid diagram rendering
- Character substitution options
- Collision-safe output filenames

**Modes:**

- Full mode: All options interactive
- Fast mode: Quick PDF generation with defaults

---

## Project Structure

```
scomp-link/
├── setup.sh                          # Bootstrap installer
├── init.sh                           # Main TUI launcher
├── wsl-setup.ps1                     # Windows WSL bootstrap
│
└── scripts/                          # All runnable scripts live here
    │
    ├── _common/                       # [Shared] Sourced by app scripts — not run directly
    │   ├── cluster.sh                 # Deployment target detection (docker/kind/k8s)
    │   ├── ui.sh                      # gum display helpers (header, info, warn, …)
    │   ├── deps.sh                    # helm/kubectl checks and repo management
    │   ├── portforward.sh             # Port-forward pid-file helpers
    │   └── gh_releases.sh             # GitHub release fetching helpers
    │
    ├── # Infrastructure
    ├── argo/
    │   └── argo.sh                   # Argo Workflows & CD manager
    ├── karpenter/
    │   └── karpenter.sh              # Karpenter setup (any K8s cluster)
    ├── kind/
    │   └── kind.sh                   # Kind cluster manager
    │
    ├── # Databases
    ├── postgres/
    │   └── postgres.sh               # PostgreSQL (Docker · K8s)
    ├── mariadb/
    │   └── mariadb.sh                # MariaDB (Docker · K8s)
    ├── mysql/
    │   └── mysql.sh                  # MySQL (Docker · K8s)
    ├── mongodb/
    │   └── mongodb.sh                # MongoDB (Docker · K8s)
    ├── redis/
    │   └── redis.sh                  # Redis + queue inspector (Docker · K8s)
    ├── qdrant/
    │   └── qdrant.sh                 # Qdrant vector database (Docker · K8s)
    ├── influxdb/
    │   └── influxdb.sh               # InfluxDB 2.x (Docker · K8s)
    │
    ├── # Observability
    ├── lgtm/
    │   └── lgtm.sh                   # LGTM stack: Loki, Grafana, Tempo, Mimir, OTel
    ├── prometheus/
    │   └── prometheus.sh             # Prometheus (K8s only)
    ├── grafana/
    │   └── grafana.sh                # Grafana + datasource provisioning (Docker · K8s)
    ├── dozzle/
    │   ├── dozzle.sh                 # Dozzle log viewer (Docker · K8s)
    │   └── templates/                # docker-compose + k8s manifest templates
    │
    ├── # Platform
    ├── harbor/
    │   └── harbor.sh                 # Harbor container registry (K8s only)
    ├── n8n/
    │   └── n8n.sh                    # n8n workflow automation (Docker · K8s)
    │
    ├── # Utilities
    ├── starlight/
    │   ├── starlight_astro.sh        # Starlight documentation manager
    │   └── converter/
    │       └── convert.sh
    ├── file_conversion/
    │   └── file_conversion.sh        # Document format converter
    ├── ssh/
    │   └── sshger.sh                 # SSH profile manager (~/.ssh/config)
    │
    └── your-script/
        └── your-script.sh            # Add your own scripts here
```

**Core files** (`setup.sh`, `init.sh`) are the framework. Scripts placed under `scripts/<folder>/` are auto-discovered and shown in the menu. The `_common/` folder is excluded from the menu since it contains shared libraries sourced by other scripts.

---

## Configuration

### GUM_INPUT_WIDTH

On macOS/zsh, gum v0.15+ has a known double-render bug. The setup script will prompt you to set `GUM_INPUT_WIDTH` to fix this. This value is saved to your shell profile.

### File Conversion Templates

Title page templates are stored in `.fcc/title-pages/`. The default template supports:

- `{{TITLE}}` placeholder for document title
- `{{IMAGE}}` placeholder for cover image

### Starlight Projects

Generated projects include a `mise.toml` with useful tasks:

```bash
mise run dev          # Start development server
mise run build        # Build for production
mise run preview      # Preview production build
mise run convert      # Convert to PDF (full mode)
mise run convert:pdf  # Convert to PDF (fast mode)
```

---

## Windows Installation

For Windows users with WSL:

```powershell
# Run from PowerShell (as Administrator if needed)
.\wsl-setup.ps1
```

This will detect your WSL distribution and run the setup inside it.

---

## Troubleshooting

### Bash Version Issues (macOS)

macOS ships with Bash 3.2, but some scripts require Bash 4+. The launcher automatically detects and uses a newer bash from Homebrew if available:

- `/opt/homebrew/bin/bash` (Apple Silicon)
- `/usr/local/bin/bash` (Intel)

If you encounter issues, install bash via Homebrew:

```bash
brew install bash
```

### Missing Dependencies

Re-run the setup script to install missing dependencies:

```bash
./setup.sh
```

### Docker Issues

For Docker-target scripts, ensure Docker is running:

```bash
docker info
```

### Kubernetes Connectivity

If a script reports it cannot reach the cluster, verify your kubeconfig context:

```bash
kubectl config current-context
kubectl cluster-info
```

### Permission Errors

Some operations require sudo. On systems without passwordless sudo, you may need administrator assistance to install system packages.

---

## Roadmap

Scomp-Link is evolving into a comprehensive shell scripting framework:

- ~~**Shared Library** - Common functions for logging, prompts, validation~~ ✓ done (`scripts/_common/`)
- **Plugin System** - Auto-discover scripts from `~/.config/scomp-link/plugins/`
- **Tool Management** - Unified TUI for managing development tools via mise
- **Script Templates** - Generators for new scripts with boilerplate

---

## Contributing

1. Fork the repository
2. Create a feature branch
3. Make your changes
4. Test on both macOS and Linux if possible
5. Submit a pull request

### Code Style

- Use `set -euo pipefail` at the start of scripts
- Follow existing patterns for error handling and user interaction
- Use gum for all user prompts and selections
- Add new scripts under `scripts/<folder>/` (auto-discovered by `init.sh`)
- Source `scripts/_common/cluster.sh` for deployment target selection (`select_target`)
- Source `scripts/_common/ui.sh` for consistent gum-based display helpers

### Contributing Scripts

Have a useful script? Contributions are welcome! Good candidates:

- Scripts that solve common developer tasks
- Scripts with good error handling and user feedback
- Scripts that leverage gum for consistent UX

---

## License

[Add your license here]

## Acknowledgments

- [Charm](https://charm.sh/) for the excellent gum TUI library
- [mise](https://mise.jdx.dev/) for seamless tool version management
- [Kind](https://kind.sigs.k8s.io/) for Kubernetes-in-Docker
- [Bitnami](https://bitnami.com/) for production-grade Helm charts (PostgreSQL, MariaDB, MySQL, MongoDB, Redis, InfluxDB)
- [Prometheus Community](https://github.com/prometheus-community) for the Prometheus Helm chart
- [Grafana](https://grafana.com/) for the Grafana Helm chart and observability tooling
- [Dozzle](https://dozzle.dev/) for the real-time container log viewer
- [Harbor](https://goharbor.io/) for the open-source container registry
- [n8n](https://n8n.io/) for the workflow automation platform
- [Qdrant](https://qdrant.tech/) for the vector database
- [Astro](https://astro.build/) and [Starlight](https://starlight.astro.build/) for documentation tooling
- [Pandoc](https://pandoc.org/) for document conversion
