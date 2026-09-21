# Ansible - Control Node Installer

`ansible/ansible.sh`

Installs and manages an Ansible **control node** installation via mise, keeping it user-local instead of layering it onto the OS. That distinction matters on atomic/immutable hosts (Bazzite, Silverblue, Kinoite), where `rpm-ostree install ansible` costs a reboot and has to be re-layered on every OS update.

- **`install`** - puts `uv` in place first (mise's pipx backend needs a Python installer and won't bootstrap one), then installs `ansible-core`, then offers to pull the required collections.
- **`collections`** - installs/upgrades the collections listed in `ANSIBLE_COLLECTIONS` (currently `ansible.posix` and `community.general`) into `~/.ansible/collections`.
- **`status`** - install path and version, which required collections are present or missing, and the effective config for the directory you ran it from.
- **`uninstall`** - removes `ansible-core` via mise. Deliberately leaves `~/.ansible/collections` alone, since wiping those is rarely what you want and is easy to redo.

## Two non-obvious details this script exists to encode

**Install `ansible-core`, not `ansible`.** The `ansible` PyPI meta-package registers exactly one entry point, `ansible-community`. Installing it through a tool manager leaves you with no `ansible-playbook`, no `ansible-galaxy`, and a confusing "it's installed but nothing works" state. `ansible-core` exposes all ten executables.

**mise's pipx backend needs uv or pipx already present.** It does not install one for you - it just fails with a message pointing at both options. `install` handles this by putting `uv` in first.

## Notes

- ansible-core ships **no collections**. Anything beyond the builtin modules (`ansible.posix.sysctl`, `community.general.*`, etc.) needs an explicit `collections` run.
- `kubernetes.core` is a likely future addition to `ANSIBLE_COLLECTIONS`, but its modules want the Python `kubernetes` library available wherever they execute - which is the target host by default, not the control node.
- mise installs land in `~/.local/share/mise/shims`. A shell opened before installing won't have that on PATH; the script adds it for its own checks, but a fresh shell (or `source ~/.bashrc`) is needed for interactive use.

**Dependencies:** `mise`, `gum`. Everything else is installed by the script.
