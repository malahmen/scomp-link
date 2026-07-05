# Akinn - Kubernetes Node Installer

`akinn/akinn_tui.sh`

gum front-end for **Akinn** (Automated Kubernetes Installation for New Nodes), a standalone POSIX provisioner that turns a fresh Ubuntu / Raspberry Pi machine into a Kubernetes master or worker.
Unlike every other script here, Akinn provisions **the machine it runs on** (as root, via `kubeadm`/`containerd`) rather than talking to a remote Docker/k8s target.
So run this TUI **on the node** you want to set up (or use "print" and paste the command there).

- **Fetches Akinn automatically** - resolves `$AKINN_DIR`, then a sibling checkout, then `git clone`s it into `~/.cache/scomp-link/akinn` (with a `git pull` update option). Override the source with `AKINN_REPO`.
- **Assembles the flags for you** - pick `master` or `worker`, then gum prompts for each parameter. Kubernetes (minor) and Calico/CRDs versions come from live pickers driven by Akinn's own definitions, so a selection always validates; the rest are inputs with sensible defaults.
- **Two hand-off modes** - **run** the assembled command here (Akinn self-elevates with `sudo` and provisions this node) or **print** it to paste on the target node yourself.
- **Standalone-friendly** - experienced users can skip the TUI entirely and call `sh akinn.sh -m node1 -v v1.34 …` directly; the TUI only helps build that command. Akinn itself stays gum-free `/bin/sh` so it runs on a bare node with no extra dependencies.
- Handles Akinn's flag quirks for you (worker flags emitted after `-w`, minor-only K8s versions, master SSH user via `-u`).

**Dependencies (operator side):** `gum`, `git`, `curl`. **On the target node:** Ubuntu 18.04+ / Raspberry Pi OS with sudo; `kubeadm`, `containerd`, and the rest are installed by Akinn.
