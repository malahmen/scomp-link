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

Scomp-Link comes with several ready-to-use scripts organized by category. Each links to its full reference under [`docs/scripts/`](docs/scripts/).

### Infrastructure

| Script                                          | Description                                                                 |
| ------------------------------------------------ | --------------------------------------------------------------------------- |
| [`kind.sh`](docs/scripts/kind.md)               | Create and manage Kind Kubernetes clusters                                  |
| [`karpenter.sh`](docs/scripts/karpenter.md)     | Install and manage Karpenter on any K8s cluster                             |
| [`argo.sh`](docs/scripts/argo.md)               | Install and manage Argo Workflows & Argo CD                                 |
| [`akinn_tui.sh`](docs/scripts/akinn.md)         | Provision an Ubuntu/Raspberry Pi node as a Kubernetes master/worker (Akinn) |
| [`docker.sh`](docs/scripts/docker.md)           | Install, uninstall, and check status of Docker itself                       |
| [`k9s.sh`](docs/scripts/k9s.md)                 | Install and launch k9s, terminal UI for Kubernetes                         |
| [`lazydocker.sh`](docs/scripts/lazydocker.md)   | Install and launch lazydocker, terminal UI for Docker                      |
| [`lazygit.sh`](docs/scripts/lazygit.md)         | Install and launch lazygit, terminal UI for git                            |

### Databases

All database scripts follow the same pattern: Docker or K8s target, multiple named instances (namespace/release prompted per session), install/status/connect/uninstall actions.

| Script                                     | Targets      | Description                                    |
| -------------------------------------------- | ------------ | ---------------------------------------------- |
| [`postgres.sh`](docs/scripts/postgres.md)  | Docker · K8s | PostgreSQL - install, connect, manage          |
| [`mariadb.sh`](docs/scripts/mariadb.md)    | Docker · K8s | MariaDB - install, connect, manage             |
| [`mysql.sh`](docs/scripts/mysql.md)        | Docker · K8s | MySQL - install, connect, manage               |
| [`mongodb.sh`](docs/scripts/mongodb.md)    | Docker · K8s | MongoDB - install, connect, manage             |
| [`redis.sh`](docs/scripts/redis.md)        | Docker · K8s | Redis - install, connect, queue listing        |
| [`qdrant.sh`](docs/scripts/qdrant.md)      | Docker · K8s | Qdrant vector database - install, health-check |
| [`influxdb.sh`](docs/scripts/influxdb.md)  | Docker · K8s | InfluxDB 2.x time-series database              |

### Observability

| Script                                     | Targets      | Description                                         |
| --------------------------------------------- | ------------ | --------------------------------------------------- |
| [`lgtm.sh`](docs/scripts/lgtm.md)          | Docker · K8s | Full LGTM stack (Loki, Grafana, Tempo, Mimir, OTel) |
| [`prometheus.sh`](docs/scripts/prometheus.md) | K8s       | Prometheus with optional components                 |
| [`grafana.sh`](docs/scripts/grafana.md)    | Docker · K8s | Grafana with datasource provisioning                |
| [`dozzle.sh`](docs/scripts/dozzle.md)      | Docker · K8s | Real-time container log viewer (no Helm required)   |

### Platform

| Script                                | Targets      | Description               |
| ---------------------------------------- | ------------ | ------------------------- |
| [`harbor.sh`](docs/scripts/harbor.md) | K8s          | Harbor container registry |
| [`n8n.sh`](docs/scripts/n8n.md)       | Docker · K8s | n8n workflow automation   |

### AI / ML

| Script                                      | Description                                                                |
| ---------------------------------------------- | --------------------------------------------------------------------------- |
| [`lmstudio.sh`](docs/scripts/lmstudio.md)   | Install and manage LM Studio (Flatpak), headless service support included |

### Gaming

| Script                                                                  | Targets      | Description                                                        |
| --------------------------------------------------------------------------- | ------------ | -------------------------------------------------------------------- |
| [`bazzite-utils.sh`](docs/scripts/bazzite-utils.md)                     | -            | EA App staged-update fix + Ubisoft Connect offscreen-window fix     |
| [`comfyengine.sh`](docs/scripts/comfyengine.md)                         | -            | Build & install the ComfyEngine memory scanner from source          |
| [`gameconqueror.sh`](docs/scripts/gameconqueror.md)                     | -            | Build & install GameConqueror/scanmem (GUI memory scanner) from source |
| [`vanilla-wow-server/server.sh`](docs/scripts/vanilla-wow-server.md)    | Docker · K8s | Build, containerize, and deploy a VMaNGOS vanilla WoW server |
| [`vanilla-wow-client/client.sh`](docs/scripts/vanilla-wow-client.md)    | -         | Configure & launch multiple vanilla WoW clients under Wine (multiboxing) |

### Utilities

| Script                                                | Description                                     |
| --------------------------------------------------------- | ----------------------------------------------- |
| [`starlight_astro.sh`](docs/scripts/starlight.md)      | Create and manage Starlight documentation sites |
| [`file_conversion.sh`](docs/scripts/file_conversion.md) | Convert documents (MD, PDF, DOCX)               |
| [`sshger.sh`](docs/scripts/sshger.md)                  | Manage SSH profiles in `~/.ssh/config`          |

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
| git, curl                   | Akinn node installer (fetches Akinn + version lists)  |

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

## Project Structure

```
scomp-link/
├── setup.sh                          # Bootstrap installer
├── init.sh                           # Main TUI launcher
├── wsl-setup.ps1                     # Windows WSL bootstrap
│
└── scripts/                          # All runnable scripts live here
    │
    ├── _common/                       # [Shared] Sourced by app scripts, not run directly
    │   ├── cluster.sh                 # Deployment target detection (docker/kind/k8s)
    │   ├── ui.sh                      # gum display helpers (header, info, warn, …)
    │   ├── deps.sh                    # helm/kubectl/docker checks, repo management,
    │   │                              #   dnf/apt/rpm-ostree package install helpers
    │   ├── portforward.sh             # Port-forward pid-file helpers (also reused for
    │   │                              #   tracking arbitrary background processes)
    │   └── gh_releases.sh             # GitHub release fetching helpers
    │
    ├── # Infrastructure
    ├── akinn/
    │   └── akinn_tui.sh              # Akinn node installer front-end (master/worker)
    ├── argo/
    │   └── argo.sh                   # Argo Workflows & CD manager
    ├── karpenter/
    │   └── karpenter.sh              # Karpenter setup (any K8s cluster)
    ├── kind/
    │   └── kind.sh                   # Kind cluster manager
    ├── docker/
    │   └── docker.sh                 # Install/uninstall/status for Docker itself
    ├── k9s/
    │   └── k9s.sh                    # k9s: Kubernetes terminal UI (install + launch)
    ├── lazydocker/
    │   └── lazydocker.sh             # lazydocker: Docker terminal UI (install + launch)
    ├── lazygit/
    │   └── lazygit.sh                # lazygit: git terminal UI (install + launch)
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
    ├── # AI / ML
    ├── lmstudio/
    │   └── lmstudio.sh               # LM Studio install/manage, headless service
    │
    ├── # Gaming
    ├── bazzite-utils/
    │   └── bazzite-utils.sh          # EA App / Ubisoft Connect fixes
    ├── comfyengine/
    │   └── comfyengine.sh            # ComfyEngine memory scanner (build from source)
    ├── gameconqueror/
    │   └── gameconqueror.sh          # GameConqueror/scanmem (build from source)
    ├── vanilla-wow-server/
    │   ├── server.sh                  # VMaNGOS server build/deploy (Docker · K8s)
    │   └── templates/                 # Dockerfile, entrypoint.sh, k8s manifests
    ├── vanilla-wow-client/
    │   └── client.sh                  # Wine client multiboxing manager
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
- [Akinn](https://github.com/malahmen/akinn) for automated Kubernetes node provisioning
- [Bitnami](https://bitnami.com/) for production-grade Helm charts (PostgreSQL, MariaDB, MySQL, MongoDB, Redis, InfluxDB)
- [Prometheus Community](https://github.com/prometheus-community) for the Prometheus Helm chart
- [Grafana](https://grafana.com/) for the Grafana Helm chart and observability tooling
- [Dozzle](https://dozzle.dev/) for the real-time container log viewer
- [Harbor](https://goharbor.io/) for the open-source container registry
- [n8n](https://n8n.io/) for the workflow automation platform
- [Qdrant](https://qdrant.tech/) for the vector database
- [Astro](https://astro.build/) and [Starlight](https://starlight.astro.build/) for documentation tooling
- [Pandoc](https://pandoc.org/) for document conversion
