# Docker Manager

`docker/docker.sh`

Installs, uninstalls, starts/stops, and reports status of Docker itself. Most other scripts in this repo check for Docker but don't install it, this fills that gap.

- **Linux-only**: relies on `systemctl` and apt/dnf/rpm-ostree packaging; macOS is unsupported (use Docker Desktop there)
- Uses each distro's own native Docker packaging (Fedora gets `moby-engine` + `docker-cli`, Debian/Ubuntu gets `docker.io`) rather than Docker's official `curl | sh` convenience script or adding Docker's own apt/dnf repo, no GPG key or repo file to maintain
- The Compose v2 plugin (`docker compose`) is installed best-effort and never fatal — `docker-compose-v2` on apt, `docker-compose-plugin` on dnf/rpm-ostree — since Fedora dropped the legacy v1 `docker-compose` package (F41+)
- `rpm-ostree` (Bazzite/immutable Fedora Atomic) supported: the engine packages are layered via `_common/deps.sh`'s `_ensure_pkgs`, while the compose plugin is layered by calling `rpm-ostree install` directly; a reboot is needed for layered packages to apply
- Enables and starts the systemd service and adds the current user to the `docker` group, warns that a fresh login/shell is needed for the group membership to apply
- `start` runs `sudo systemctl start docker` (no-op if already active); `stop` confirms first, since running containers stop too, then runs `sudo systemctl stop docker`
- Commands: `install`, `uninstall`, `status`, `start`, `stop`
