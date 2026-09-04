# Docker Manager

`docker/docker.sh`

Installs, uninstalls, and reports status of Docker itself. Most other scripts in this repo check for Docker but don't install it, this fills that gap.

- Uses each distro's own native Docker packaging (Fedora gets `moby-engine` + `docker-cli`, Debian/Ubuntu gets `docker.io`) rather than Docker's official `curl | sh` convenience script or adding Docker's own apt/dnf repo, no GPG key or repo file to maintain
- The Compose v2 plugin (`docker compose`) is installed best-effort and never fatal — `docker-compose-v2` on apt, `docker-compose-plugin` on dnf/rpm-ostree — since Fedora dropped the legacy v1 `docker-compose` package (F41+)
- `rpm-ostree` (Bazzite/immutable Fedora Atomic) supported via `_common/deps.sh`'s package helpers, layers the packages and prompts to reboot
- Enables and starts the systemd service and adds the current user to the `docker` group, warns that a fresh login/shell is needed for the group membership to apply
- Commands: `install`, `uninstall`, `status`
