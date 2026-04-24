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

Scomp-Link comes with several ready-to-use scripts:

| Script | Description |
|--------|-------------|
| `kind.sh` | Create and manage Kind Kubernetes clusters |
| `argo.sh` | Install and manage Argo Workflows & Argo CD |
| `starlight_astro.sh` | Create and manage Starlight documentation sites |
| `file_conversion.sh` | Convert documents (MD, PDF, DOCX) |

These are examples of what you can build. **Add your own scripts** to extend the toolkit.

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
| Tool | Required For |
|------|-------------|
| Docker | Kind cluster management |
| Node.js | Starlight documentation sites |
| pandoc | Document conversion |
| TeX Live (xelatex/lualatex) | PDF generation |

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

**That's it.** The launcher auto-discovers all `.sh` files one level deep inside `scripts/` (excluding folders listed in `EXCLUDED_DIRS`, such as `cluster`).

### Script Guidelines

For best results, your scripts should:

1. **Use gum for interaction** - Provides consistent UX across all scripts
2. **Start with the shebang** - `#!/usr/bin/env bash`
3. **Use strict mode** - `set -euo pipefail`
4. **Handle errors gracefully** - Provide meaningful error messages

Example script template:

```bash
#!/usr/bin/env bash
set -euo pipefail

# my-script.sh - Description of what this script does

# Helper functions (will be moved to shared lib in the future)
info()  { printf "\033[0;36m[INFO]  %s\033[0m\n" "$*"; }
error() { printf "\033[0;31m[ERROR] %s\033[0m\n" "$*" >&2; exit 1; }

# Check dependencies
command -v gum &>/dev/null || error "gum is required. Run setup.sh first."

# Your script logic here
ACTION=$(gum choose "Option 1" "Option 2" "Quit")

case "$ACTION" in
    "Option 1") info "Running option 1..." ;;
    "Option 2") info "Running option 2..." ;;
    "Quit") exit 0 ;;
esac
```

## Included Scripts Reference

The following scripts come bundled with Scomp-Link as ready-to-use tools and examples of what you can build.

### Kind Cluster Manager (`kind.sh`)

Manage Kubernetes-in-Docker clusters with an interactive interface:

- **Create clusters** with custom names, K8s versions, and port mappings
- **Port conflict detection** before cluster creation
- **Single-cluster operations**: view nodes, export kubeconfig/logs, load images, delete
- **Bulk operations**: export all configs, delete all clusters

Common port mappings available:
- HTTP (80), HTTPS (443)
- ArgoCD (8080), Grafana (3000)
- Harbor (30003), and more

### Argo Manager (`argo.sh`)

Install and manage Argo tools on your Kubernetes clusters:

**Argo Workflows:**
- Install from GitHub releases
- Port-forward for local access
- View pod status
- Clean uninstall with CRD removal

**Argo CD:**
- Install from GitHub releases
- Retrieve admin password
- Port-forward with HTTPS
- Clean uninstall with warnings for managed applications

### Starlight Documentation (`starlight_astro.sh`)

Create and manage Astro Starlight documentation sites:

- **Project creation** with optional Mermaid diagram support
- **Sidebar management** (autogenerate or manual mode)
- **Section management** (add, rename, remove, reorder)
- **External links** (top-level, grouped, or homepage-only)
- **Content editing** with vim integration
- **Project discovery** to manage existing sites

### Document Conversion (`file_conversion.sh`)

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

## Project Structure

```
scomp-link/
├── setup.sh                        # Bootstrap installer (core)
├── init.sh                         # Main TUI launcher (core)
├── wsl-setup.ps1                   # Windows WSL bootstrap (core)
│
└── scripts/                        # All runnable scripts live here
    ├── argo/
    │   └── argo.sh                 # [Included] Argo Workflows & CD manager
    ├── cluster/
    │   └── cluster.sh              # [Shared] Deployment target helper (sourced, not run directly)
    ├── file_conversion/
    │   └── file_conversion.sh      # [Included] Document format converter
    ├── karpenter/
    │   └── karpenter.sh            # [Included] Karpenter local dev setup
    ├── kind/
    │   └── kind.sh                 # [Included] Kind cluster manager
    ├── starlight/
    │   ├── starlight_astro.sh      # [Included] Starlight documentation manager
    │   ├── converter/              # Assets for document conversion
    │   │   └── convert.sh
    │   └── .fcc/                   # File conversion config assets
    │       ├── title-pages/
    │       └── pdf/
    └── your-script/
        └── your-script.sh          # [Custom] Add your own scripts here!
```

**Core files** (`setup.sh`, `init.sh`) are the framework. Scripts placed under `scripts/<folder>/` are auto-discovered and shown in the menu.

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
mise run dev       # Start development server
mise run build     # Build for production
mise run preview   # Preview production build
mise run convert   # Convert to PDF (full mode)
mise run convert:pdf  # Convert to PDF (fast mode)
```

## Windows Installation

For Windows users with WSL:

```powershell
# Run from PowerShell (as Administrator if needed)
.\wsl-setup.ps1
```

This will detect your WSL distribution and run the setup inside it.

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

For Kind cluster management, ensure Docker is running:
```bash
docker info
```

### Permission Errors

Some operations require sudo. On systems without passwordless sudo, you may need administrator assistance to install system packages.

## Roadmap

Scomp-Link is evolving into a comprehensive shell scripting framework:

- **Shared Library** - Common functions (`lib/shared.sh`) for logging, prompts, validation
- **Gum Helpers** - Reusable TUI patterns (`lib/gum-helpers.sh`)
- **Plugin System** - Auto-discover scripts from `~/.config/scomp-link/plugins/`
- **Tool Management** - Unified TUI for managing development tools via mise
- **Script Templates** - Generators for new scripts with boilerplate

See the full improvements list in the repository discussions or issues.

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

### Contributing Scripts

Have a useful script? Contributions are welcome! Good candidates:
- Scripts that solve common developer tasks
- Scripts with good error handling and user feedback
- Scripts that leverage gum for consistent UX

## License

[Add your license here]

## Acknowledgments

- [Charm](https://charm.sh/) for the excellent gum TUI library
- [mise](https://mise.jdx.dev/) for seamless tool version management
- [Kind](https://kind.sigs.k8s.io/) for Kubernetes-in-Docker
- [Astro](https://astro.build/) and [Starlight](https://starlight.astro.build/) for documentation tooling
- [Pandoc](https://pandoc.org/) for document conversion
