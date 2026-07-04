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

| Script         | Description                                                                 |
| -------------- | --------------------------------------------------------------------------- |
| `kind.sh`      | Create and manage Kind Kubernetes clusters                                  |
| `karpenter.sh` | Install and manage Karpenter on any K8s cluster                             |
| `argo.sh`      | Install and manage Argo Workflows & Argo CD                                 |
| `akinn_tui.sh` | Provision an Ubuntu/Raspberry Pi node as a Kubernetes master/worker (Akinn) |
| `docker.sh`    | Install, uninstall, and check status of Docker itself                       |
| `k9s.sh`       | Install and launch k9s, terminal UI for Kubernetes                         |
| `lazydocker.sh`| Install and launch lazydocker, terminal UI for Docker                      |
| `lazygit.sh`   | Install and launch lazygit, terminal UI for git                            |

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

### AI / ML

| Script        | Description                                                                |
| ------------- | --------------------------------------------------------------------------- |
| `lmstudio.sh` | Install and manage LM Studio (Flatpak), headless service support included |

### Gaming

| Script               | Targets      | Description                                                        |
| -------------------- | ------------ | -------------------------------------------------------------------- |
| `bazzite-utils.sh`   | -            | EA App staged-update fix + Ubisoft Connect offscreen-window fix     |
| `comfyengine.sh`     | -            | Build & install the ComfyEngine memory scanner from source          |
| `gameconqueror.sh`   | -            | Build & install GameConqueror/scanmem (GUI memory scanner) from source |
| `vanilla-wow.sh`     | Docker · K8s | Build, containerize, and deploy a VMaNGOS vanilla WoW server        |

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

#### Akinn - Kubernetes Node Installer (`akinn/akinn_tui.sh`)

gum front-end for **Akinn** (Automated Kubernetes Installation for New Nodes), a standalone POSIX provisioner that turns a fresh Ubuntu / Raspberry Pi machine into a Kubernetes master or worker.
Unlike every other script here, Akinn provisions **the machine it runs on** (as root, via `kubeadm`/`containerd`) rather than talking to a remote Docker/k8s target.
So run this TUI **on the node** you want to set up (or use "print" and paste the command there).

- **Fetches Akinn automatically** - resolves `$AKINN_DIR`, then a sibling checkout, then `git clone`s it into `~/.cache/scomp-link/akinn` (with a `git pull` update option). Override the source with `AKINN_REPO`.
- **Assembles the flags for you** - pick `master` or `worker`, then gum prompts for each parameter. Kubernetes (minor) and Calico/CRDs versions come from live pickers driven by Akinn's own definitions, so a selection always validates; the rest are inputs with sensible defaults.
- **Two hand-off modes** - **run** the assembled command here (Akinn self-elevates with `sudo` and provisions this node) or **print** it to paste on the target node yourself.
- **Standalone-friendly** - experienced users can skip the TUI entirely and call `sh akinn.sh -m node1 -v v1.34 …` directly; the TUI only helps build that command. Akinn itself stays gum-free `/bin/sh` so it runs on a bare node with no extra dependencies.
- Handles Akinn's flag quirks for you (worker flags emitted after `-w`, minor-only K8s versions, master SSH user via `-u`).

**Dependencies (operator side):** `gum`, `git`, `curl`. **On the target node:** Ubuntu 18.04+ / Raspberry Pi OS with sudo; `kubeadm`, `containerd`, and the rest are installed by Akinn.

#### Docker Manager (`docker/docker.sh`)

Installs, uninstalls, and reports status of Docker itself. Most other scripts in this repo check for Docker but don't install it, this fills that gap.

- Uses each distro's own native Docker packaging (Fedora gets `moby-engine` + `docker-cli` + `docker-compose` with no external repo needed, Debian/Ubuntu gets `docker.io` + `docker-compose-v2`) rather than Docker's official `curl | sh` convenience script or adding Docker's own apt/dnf repo, no GPG key or repo file to maintain
- `rpm-ostree` (Bazzite/immutable Fedora Atomic) supported via `_common/deps.sh`'s package helpers, layers the packages and prompts to reboot
- Enables and starts the systemd service and adds the current user to the `docker` group, warns that a fresh login/shell is needed for the group membership to apply
- Commands: `install`, `uninstall`, `status`

#### k9s (`k9s/k9s.sh`)

Install and launch [k9s](https://k9scli.io) - a terminal UI for Kubernetes.

- No config file of its own, k9s reads the ambient kubeconfig exactly like `kubectl` does
- `launch` picks a context explicitly (via k9s's own `--context` flag) instead of silently relying on kubectl's `current-context`, auto-selects if there's only one context, otherwise prompts. Never mutates your ambient kubectl state.
- Install/uninstall via `mise use --global` / `mise uninstall --all` (same pattern `setup.sh` uses for `gum`)
- Commands: `install`, `uninstall`, `status`, `launch`

#### lazydocker (`lazydocker/lazydocker.sh`)

Install and launch [lazydocker](https://github.com/jesseduffield/lazydocker), a terminal UI for Docker and Docker Compose. No config needed since it just talks to whatever Docker daemon is reachable. Commands: `install`, `uninstall`, `status`, `launch`.

#### lazygit (`lazygit/lazygit.sh`)

Install and launch [lazygit](https://github.com/jesseduffield/lazygit), a terminal UI for git. No config needed, operates on the current directory's git repo (prompts for a path if the current directory isn't one), same as the `git` CLI itself. Commands: `install`, `uninstall`, `status`, `launch`.

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

Lightweight real-time log viewer for Docker / Kubernetes / kind, installs from rendered manifests (no Helm dependency).

- Docker image: `amir20/dozzle` · Port: `8080`
- **Targets**: Docker (compose) or kind/k8s (rendered manifests applied directly)
- **RBAC scope** (k8s/kind): cluster-wide (all namespaces) or restricted to a single namespace
- **Storage** (k8s/kind): hostPath PV or NFS-backed PV; Docker uses a host bind-mount
- **Auth**: optional bcrypt-hashed users via Dozzle's built-in `--auth-provider simple` (hash generation runs `docker run amir20/dozzle generate` so Docker must be reachable when enabling auth)
- **Readiness / liveness probes** on `/healthz` to survive kind control-plane warm-up
- **Port-forward** auto-reconnects across pod restarts; `stop` tears it down with the deployment
- **Import**: adopt an existing Dozzle install that was deployed outside this script (docker container or k8s Service named `dozzle`). Detected automatically, if you run any command without a saved config, the script offers to adopt the existing install inline. Marks the conf with `INSTALL_METHOD=external` so `uninstall` double-confirms before acting on something it didn't deploy.
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

### AI / ML

#### LM Studio Manager (`lmstudio/lmstudio.sh`)

Installs and manages [LM Studio](https://lmstudio.ai) (Flatpak) so the `lms` CLI works out of the box, with optional headless operation.

- **Sandbox override**: proactively applies `flatpak override --user --filesystem=home ai.lmstudio.lm-studio` before first launch, prevents an "Invalid passkey for lms CLI client" bug caused by LM Studio's identity/passkey files resolving to a different sandboxed `~/.lmstudio` than the rest of its state
- **CLI bootstrap**: launches LM Studio against a throwaway headless Xvfb display so the `lms` CLI gets bootstrapped without needing a real desktop session
- **Headless service** (`service-enable`): sets up a persistent Xvfb + `systemd --user` service pair so LM Studio can run headless and start at boot without anyone logged in (via `loginctl` linger)
- Commands: `install`, `service-enable`, `service-disable`, `status`, `uninstall`

---

### Gaming

#### Bazzite Utils (`bazzite-utils/bazzite-utils.sh`)

Grab-bag of gaming-on-Linux workaround utilities, named after [Bazzite](https://bazzite.gg/) (the primary target) but works on any dnf/apt/rpm-ostree host.

- **`ea-fix`**: copies EA App's staged self-update into place under Wine/Proton (EA's own updater frequently stages an update it never applies). The Wine/Proton prefix path is prompted once and persisted.
- **`ubisoft-rws`**: finds Ubisoft Connect windows that render off-screen or invisible under Wine/Proton and repositions/raises them
- Commands: `ea-fix`, `ubisoft-rws`

#### ComfyEngine (`comfyengine/comfyengine.sh`)

Builds and installs [ComfyEngine](https://github.com/kashithecomfy/ComfyEngine) (a Linux-native memory scanner) from source, with a desktop shortcut. Dependencies (`git`, `cmake`, `g++`) are checked/installed automatically. Commands: `install`, `uninstall`, `status`.

#### GameConqueror (`gameconqueror/gameconqueror.sh`)

Builds and installs [GameConqueror/scanmem](https://github.com/scanmem/scanmem) (a GUI memory scanner) from source, with a desktop shortcut. Same dependency-checking pattern as ComfyEngine. Commands: `install`, `uninstall`, `status`.

#### Vanilla WoW Server (`vanilla-wow/vanilla-wow.sh`)

Builds, containerizes, and deploys a [VMaNGOS](https://github.com/vmangos/core)-based vanilla WoW server (1.12.1, client build 5875) from a repack's source, natively for local iteration and as a Docker/K8s deployment for LAN play.

- **No Wine required**, builds native Linux `mangosd`/`realmd` binaries from the repack's own bundled C++ source (not the compiled Windows `.exe`s), using its official Linux Docker build recipe as reference
- **Database**: always a separate MariaDB container/pod, never bundled into the server image. One DB-bootstrap sequence (schemas, then base and anticheat schemas, then the full world dump, then migrations each routed to its correct database, then optional custom content, then `realmlist` seeding) is shared between local `configure` and a one-shot K8s Job
- **Configure** also prompts for the server's own identity and gameplay settings, not just the DB import: realm name, realm zone, game type, player limit, and the progression content patch, plus the message of the day and XP/loot rate multipliers in `mangosd.conf`, and login security settings (brute-force ban rules, email verification, strict version check) in `realmd.conf`
- **Edit**: opens the already-configured conf files in vim (installed by `setup.sh`) for anything the prompts don't cover. The deploy commands pick up manual edits automatically instead of overwriting them with a fresh copy from the repack
- **Create-account** / **delete-account**: game accounts use SRP6 credentials, not a hash safe to insert or remove by hand, so both send commands (`account create`/`account set gmlevel`/`account delete`) through mangosd's own console instead, same as the repack's own README and the server's source both use. That console couldn't otherwise be reached from a backgrounded container (it's fed from a FIFO, not a live terminal, to avoid it treating stdin EOF as an implicit quit), so this is what actually lets you create a login and test the server from a real client. All three account commands detect whether the server is running locally, in Docker, or in K8s, and send commands to the right one. `delete-account` also cleans up a leftover `account_access` row the server's own delete command doesn't touch
- **List-accounts**: no console command lists every account (only currently-connected ones), so this queries the database directly instead, this one doesn't touch credentials at all
- **Search**: name lookup across items, NPCs, GM teleport locations, and player characters, a GM convenience for finding an entry ID to spawn or a place to teleport to. All four are plain reference-data reads, so this goes straight to the database and works even if mangosd itself isn't running. "Locations" means the `game_tele` table (the same one the `.tele <name>` GM command searches), not full WoW zone/area names, those live in client-side data this pipeline doesn't extract
- **Warden anti-cheat modules**: baked into the Docker/K8s image at build time (small and static like the compiled binaries, unlike the large, runtime-mounted game data), and pointed at directly from the repack for local native. Without this, Warden still runs (it's enabled by default) but has nothing to scan with, which surfaces as players getting kicked mid-session for a timeout, not just a log warning at startup. `configure` also prompts to disable Warden outright, useful for a private/trusted LAN server with no real need for client-side cheat detection
- **LAN exposure**: host networking throughout (`docker run --network host` / K8s `hostNetwork: true`), since the realm port (3724) is client-hardcoded and falls outside K8s's default NodePort range
- **Storage** (K8s): StorageClass-backed PVC or hostPath, prompted at deploy time, same pattern as Harbor/LGTM
- Commands: `install-deps`, `configure`, `start`, `stop`, `status`, `edit`, `create-account`, `list-accounts`, `delete-account`, `search`, `build-image`, `run-docker`, `run-k8s`
- Local native build (`start`/`stop`) is Debian/Ubuntu-oriented. The ACE toolkit build dependency isn't packaged for Fedora/RHEL. The Docker path (`build-image`) always builds inside an Ubuntu stage regardless of host OS

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

- **add**: create a profile, generate a new `ed25519` / `rsa-4096` key (or reuse an existing one), and copy the public key to the clipboard
- **import**: pull existing `Host` entries from outside the managed section into management, optionally removing the originals
- **remove**: delete a profile (optionally its key files too)
- **view**: show profile details and the public key
- **edit**: change host / hostname / user / port / key path
- **use**: wire a profile to the current git repo (rewrites `origin` URL, optionally sets local `user.name` / `user.email`)
- **test**: verify the SSH connection for a profile (single host or all hosts)
- **list**: show all managed profiles

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
    ├── vanilla-wow/
    │   ├── vanilla-wow.sh            # VMaNGOS server build/deploy (Docker · K8s)
    │   └── templates/                # Dockerfile, entrypoint.sh, k8s manifests
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
