# BMAD project manager

`bmad/bmad.sh`

Manage [BMAD-METHOD](https://github.com/bmad-code-org/BMAD-METHOD) projects — create
them, keep their BMAD version current, and delete whole project folders from disk —
from one gum TUI. BMAD itself is driven through its own installer (`npx bmad-method
install`); this script is a lifecycle wrapper around it plus a small project registry.

## Requirements

BMAD needs **Node.js ≥ 20.12** (for `npx`), **Python ≥ 3.10**, and **uv** (Astral's
Python package manager). The script checks these before Create/Update and offers to
install `uv` (Homebrew or the official installer); Node/Python it guides you to
install. `python3` is also used for the registry, so it's always required.

## Menu

| Action | What it does |
| ------ | ------------ |
| **Create a new project** | Prompts a name + parent dir, creates the folder, runs `npx bmad-method install` interactively (you answer BMAD's own module/tool prompts), and registers the project. |
| **Update BMAD in a project** | Pick a project (registry or folder scan), choose **stable** or **prerelease** (`@next`), and rerun the installer — BMAD detects the existing install and updates it. |
| **Delete a project** | Pick a project, see a git-safety report, retype the project name to confirm, then the **entire folder** is removed and dropped from the registry. |
| **List managed projects** | Shows registered projects (flags any whose folder is gone) and offers to prune stale entries. |

## Project registry

The script remembers the projects it manages in a JSON file at
`${XDG_CONFIG_HOME:-~/.config}/scomp-link/bmad/projects.json` (each entry: `path`,
`name`, `created`, `last_update`), managed with `python3` (no extra dependency, since
BMAD needs Python anyway). This means a project created in an unusual folder is still
found later. Update/Delete also offer a **folder scan** — any directory containing a
`_bmad/` folder is a BMAD project — and register what you pick. `List` prunes entries
whose folder no longer exists.

## Create

Interactive passthrough: the script makes the directory and hands off to
`npx bmad-method install`, so you get BMAD's real prompts (modules, target AI tools,
etc.). If a `_bmad/` directory appears afterward the project is registered; if you
cancel the installer, nothing is registered.

## Update

BMAD has no separate "update" command — you rerun the installer from a project that
already has a `_bmad/` directory and it offers the update/modify paths. This script
just locates the project and runs `npx bmad-method install` (or `bmad-method@next
install` for prereleases) there.

## Delete — safety

Delete removes the **whole project directory** (`rm -rf`), for quickly reclaiming disk
once a project is safe in git. Before deleting it shows a git-safety report:

- **Not a git repo** → warns nothing is backed up.
- **Uncommitted changes** → warns with the file count.
- **No remote** / **unpushed commits** → warns the work exists only on this disk.
- **Clean and pushed** → confirms it's safe.

Either way you must **retype the exact project name** to proceed — a plain yes/no
isn't enough for an `rm -rf`.

## Notes

- There is no official BMAD uninstaller; "Delete" is a *project* delete, not a
  BMAD-from-project uninstall.
- The installer is interactive here; for CI/headless use BMAD supports
  `npx bmad-method install --yes --modules <m> --tools <t>` directly.
