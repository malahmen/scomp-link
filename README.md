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
- **Standalone Export** - Bundle any script into a self-contained, scomp-link-free folder (`export.sh`)

## Included Scripts

Scomp-Link comes with several ready-to-use scripts organized by category. Each links to its full reference under [`docs/scripts/`](docs/scripts/).

### Infrastructure

| Script                                        | Description                                                                 |
| --------------------------------------------- | --------------------------------------------------------------------------- |
| [`kind.sh`](docs/scripts/kind.md)             | Create and manage Kind Kubernetes clusters                                  |
| [`karpenter.sh`](docs/scripts/karpenter.md)   | Install and manage Karpenter on any K8s cluster                             |
| [`argo.sh`](docs/scripts/argo.md)             | Install and manage Argo Workflows & Argo CD                                 |
| [`akinn_tui.sh`](docs/scripts/akinn.md)       | Provision an Ubuntu/Raspberry Pi node as a Kubernetes master/worker (Akinn) |
| [`docker.sh`](docs/scripts/docker.md)         | Install, uninstall, and check status of Docker itself                       |
| [`k9s.sh`](docs/scripts/k9s.md)               | Install and launch k9s, terminal UI for Kubernetes                          |
| [`lazydocker.sh`](docs/scripts/lazydocker.md) | Install and launch lazydocker, terminal UI for Docker                       |
| [`lazygit.sh`](docs/scripts/lazygit.md)       | Install and launch lazygit, terminal UI for git                             |

### Databases

All database scripts follow the same pattern: Docker or K8s target, multiple named instances (namespace/release prompted per session), install/status/connect/uninstall actions.

| Script                                    | Targets      | Description                                    |
| ----------------------------------------- | ------------ | ---------------------------------------------- |
| [`postgres.sh`](docs/scripts/postgres.md) | Docker · K8s | PostgreSQL - install, connect, manage          |
| [`mariadb.sh`](docs/scripts/mariadb.md)   | Docker · K8s | MariaDB - install, connect, manage             |
| [`mysql.sh`](docs/scripts/mysql.md)       | Docker · K8s | MySQL - install, connect, manage               |
| [`mongodb.sh`](docs/scripts/mongodb.md)   | Docker · K8s | MongoDB - install, connect, manage             |
| [`redis.sh`](docs/scripts/redis.md)       | Docker · K8s | Redis - install, connect, queue listing        |
| [`qdrant.sh`](docs/scripts/qdrant.md)     | Docker · K8s | Qdrant vector database - install, health-check |
| [`influxdb.sh`](docs/scripts/influxdb.md) | Docker · K8s | InfluxDB 2.x time-series database              |

### Observability

| Script                                        | Targets      | Description                                         |
| --------------------------------------------- | ------------ | --------------------------------------------------- |
| [`lgtm.sh`](docs/scripts/lgtm.md)             | Docker · K8s | Full LGTM stack (Loki, Grafana, Tempo, Mimir, OTel) |
| [`prometheus.sh`](docs/scripts/prometheus.md) | K8s          | Prometheus with optional components                 |
| [`grafana.sh`](docs/scripts/grafana.md)       | Docker · K8s | Grafana with datasource provisioning                |
| [`dozzle.sh`](docs/scripts/dozzle.md)         | Docker · K8s | Real-time container log viewer (no Helm required)   |

### Platform

| Script                                | Targets      | Description               |
| ------------------------------------- | ------------ | ------------------------- |
| [`harbor.sh`](docs/scripts/harbor.md) | K8s          | Harbor container registry |
| [`n8n.sh`](docs/scripts/n8n.md)       | Docker · K8s | n8n workflow automation   |

### AI / ML

| Script                                    | Description                                                               |
| ----------------------------------------- | ------------------------------------------------------------------------- |
| [`lmstudio.sh`](docs/scripts/lmstudio.md) | Install and manage LM Studio (Flatpak), headless service support included |

### Gaming

| Script                                                               | Targets      | Description                                                              |
| -------------------------------------------------------------------- | ------------ | ------------------------------------------------------------------------ |
| [`bazzite-utils.sh`](docs/scripts/bazzite-utils.md)                  | -            | EA App staged-update fix + Ubisoft Connect offscreen-window fix          |
| [`comfyengine.sh`](docs/scripts/comfyengine.md)                      | -            | Build & install the ComfyEngine memory scanner from source               |
| [`gameconqueror.sh`](docs/scripts/gameconqueror.md)                  | -            | Build & install GameConqueror/scanmem (GUI memory scanner) from source   |
| [`vanilla-wow-server/server.sh`](docs/scripts/vanilla-wow-server.md) | Docker · K8s | Build, containerize, and deploy a VMaNGOS vanilla WoW server             |
| [`vanilla-wow-client/client.sh`](docs/scripts/vanilla-wow-client.md) | -            | Configure & launch multiple vanilla WoW clients under Wine (multiboxing) |

### Utilities

| Script                                                  | Description                                                                 |
| ------------------------------------------------------- | --------------------------------------------------------------------------- |
| [`starlight_astro.sh`](docs/scripts/starlight.md)       | Create and manage Starlight documentation sites                             |                            |
| [`protocol-droid/protocol-droid.sh`](docs/scripts/protocol-droid.md) | Convert PDF/Office/audio/etc -> Markdown/JSON (local or scalable service) — front-end for the standalone [protocol-droid](https://github.com/malahmen/protocol-droid) engine, a multi-backend converter driving [marker](https://github.com/datalab-to/marker) and [Microsoft markitdown](https://github.com/microsoft/markitdown) |
| [`holo-convert`](docs/scripts/holo-convert.md)         | Convert documents (Markdown ↔ PDF/DOCX) — front-end for the standalone [holo-convert](https://github.com/malahmen/holo-convert) engine |
| [`bmad/bmad.sh`](docs/scripts/bmad.md)                 | Manage BMAD-METHOD projects — create, update BMAD version, delete project |
| [`younglings-key/younglings-key.sh`](docs/scripts/younglings-key.md) | Generate certificates (self-signed/CSR/template/convert) — front-end for the standalone [younglings-key](https://github.com/malahmen/younglings-key) engine |
| [`navicomputer/navicomputer.sh`](docs/scripts/navicomputer.md) | Manage SSH profiles in `~/.ssh/config` — front-end for the standalone [navicomputer](https://github.com/malahmen/navicomputer) engine |
| [`mind-trick/mind-trick.sh`](docs/scripts/mind-trick.md) | Scrub commit-message trailers (e.g. AI co-author) from git history — front-end for the standalone [mind-trick](https://github.com/malahmen/mind-trick) engine |

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
| pandoc                      | holo-convert (document conversion)                    |
| TeX Live (xelatex/lualatex) | holo-convert PDF output                               |
| openssl                     | younglings-key certificate generation                 |
| redis-cli                   | Redis connect and queue listing (prompted at runtime) |
| jq                          | navicomputer (SSH profile manager)                    |
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

## File conversion — holo-convert

Markdown ↔ PDF / DOCX conversion is provided by **[holo-convert](https://github.com/malahmen/holo-convert)**, a standalone, gum-free engine kept in its own repository. scomp-link ships only the interactive front-end (`scripts/holo-convert/holo-convert.sh`), auto-discovered in the launcher menu like any other script.

The front-end resolves the engine automatically — an explicit `$HOLO_CONVERT_DIR`, then a local sibling checkout, then a cached clone under `~/.cache/scomp-link/`, then a fresh `git clone` from the public repo — collects options via gum, and runs the engine with the matching flags. On a missing dependency it offers to run the engine's `--setup` and retry.

You can also drive the engine directly, without the TUI:

```bash
holo-convert.sh --from md --to pdf --toc --title-page doc.md
holo-convert.sh --setup --to docx        # install dependencies
holo-convert.sh --help
```

## Exporting a Script

Any script can be exported as a **standalone, self-contained folder** that runs
on its own — no scomp-link checkout, no `init.sh`, no `_common/` parent.

```bash
./export.sh                   # pick a script + target interactively
./export.sh postgres ~/pg     # or pass them directly
```

You can also trigger it from the launcher: pick **“⇱ Export a script → standalone folder”** at the top of the `init.sh` menu.

The result is a **flat** directory:

```
~/pg/
  postgres.sh                             # the script (+ any co-located assets)
  ui.sh deps.sh cluster.sh portforward.sh # only the _common helpers it sources
  setup.sh                                # slimmed bootstrap — floor + this script's deps
  wsl-setup.ps1                           # Windows/WSL bootstrap
```

Run it anywhere:

```bash
cd ~/pg
bash setup.sh          # once — installs dependencies
bash postgres.sh
```

This works because every script is **vendor-aware**: it sources shared helpers
from `../_common` when run inside this repo, and falls back to helpers sitting
**alongside** it when exported. What the slimmed `setup.sh` installs is driven
by each script's [export manifest](#export-manifest). See
[docs on exporting](docs/export.md) for the full mechanics.

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
4. **Source `_common/` vendor-aware** - Resolve `COMMON_DIR` so the script also works when [exported](#exporting-a-script) (deps sit alongside it instead of in `../_common`)
5. **Declare an export manifest** - so a standalone export knows what to install
6. **Add a `# description:` header** - a one-line summary the launcher shows next to the script in the picker (and filters on), e.g. `# description: Manage SSH profiles in ~/.ssh/config`

Example script template:

```bash
#!/usr/bin/env bash
# export-setup: kubectl helm      # tools the standalone-export setup.sh installs
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Shared helpers: ../_common in the repo, or alongside this script when exported.
if [[ -d "${SCRIPT_DIR}/../_common" ]]; then
    COMMON_DIR="${SCRIPT_DIR}/../_common"
else
    COMMON_DIR="${SCRIPT_DIR}"
fi
source "${COMMON_DIR}/ui.sh"
source "${COMMON_DIR}/cluster.sh"

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

<a name="export-manifest"></a>
#### Export manifest

Add a `# export-setup:` comment near the top so [`export.sh`](#exporting-a-script)
knows what the standalone `setup.sh` should install beyond the framework floor
(`curl` / `mise` / `bash` / `gum`):

```bash
# export-setup: kubectl helm     # installed via mise (fallback: brew/apt/dnf)
```

- `vim`, `tree`, `node` map to `setup.sh`'s own `ensure_*` steps.
- Any other token is installed best-effort via `mise` (then `brew`/`apt`/`dnf`);
  whatever can't be pre-installed is resolved by your script's runtime checks.
- **No manifest** (or a plain `# ... no extra setup deps` note) → the export
  ships the floor only, which is right for OS packages, daemons, or apps that
  your script provisions at runtime.

---

## Project Structure

```
scomp-link/
├── setup.sh                          # Bootstrap installer
├── init.sh                           # Main TUI launcher
├── export.sh                         # Export a script as a standalone folder
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
    │       └── convert.sh            # per-project doc converter (vendors the holo-convert engine)
    ├── holo-convert/
    │   └── holo-convert.sh           # front-end for the holo-convert engine (its own repo)
    ├── navicomputer/
    │   └── navicomputer.sh           # front-end for the navicomputer SSH-profile engine (its own repo)
    ├── mind-trick/
    │   └── mind-trick.sh             # front-end for the mind-trick git-history-scrub engine (its own repo)
    ├── protocol-droid/
    │   └── protocol-droid.sh         # front-end for the protocol-droid doc-conversion engine (marker + markitdown backends; its own repo)
    │
    └── your-script/
        └── your-script.sh            # Add your own scripts here
```

**Core files** (`setup.sh`, `init.sh`) are the framework. Scripts placed under `scripts/<folder>/` are auto-discovered and shown in the menu. The `_common/` folder is excluded from the menu since it contains shared libraries sourced by other scripts.

---

## Configuration

### GUM_INPUT_WIDTH

On macOS/zsh, gum v0.15+ has a known double-render bug. The setup script will prompt you to set `GUM_INPUT_WIDTH` to fix this. This value is saved to your shell profile.

### Document conversion assets

Conversion assets — pandoc Lua filters, the code-block theme, the DOCX reference
documents, and title-page templates — ship with the **holo-convert** engine in
its `.fcc/` directory and are copied into a working `./.fcc/` in the current
directory on first run (so they can be customized per project). Title-page
templates live in `.fcc/title-pages/` and support `{{TITLE}}` and `{{IMAGE}}`
placeholders.

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
- ~~**Standalone Export** - Bundle a script into a self-contained folder~~ ✓ done (`export.sh`)
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
