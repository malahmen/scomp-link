# Script templates

Starting points for new scomp-link scripts, one per recurring archetype in this
repo. They're **skeletons, not runnable tools** — this folder is excluded from
the launcher menu (via `EXCLUDED_DIRS` in `init.sh`). Each is valid Bash (passes
`bash -n`) with `TODO` / `foo` placeholders to replace.

## Which one to start from

| Template | Use it for | Modelled on |
| --- | --- | --- |
| [`service.sh`](service.sh) | A tool you deploy as a **Docker container or a Kubernetes Helm release** (install / status / connect / port-forward / uninstall, target chosen at runtime). | the database + platform scripts (postgres, redis, n8n, grafana, …) |
| [`engine-frontend.sh`](engine-frontend.sh) | A **thin gum front-end for a standalone, flag-driven engine** kept in its own repo (resolve → cache → clone, then drive it by flags). The preferred shape for new reusable tools. | holo-convert, navicomputer, mind-trick, protocol-droid |
| [`build-from-source.sh`](build-from-source.sh) | A **Linux-native tool built from source** (clone → deps → build → install → desktop shortcut), guarded to Linux. | comfyengine, gameconqueror |

## How to use

```sh
mkdir -p scripts/mytool
cp scripts/_templates/service.sh scripts/mytool/mytool.sh   # pick the right template
$EDITOR scripts/mytool/mytool.sh                            # replace every TODO / foo
```

The launcher auto-discovers `scripts/<name>/<name>.sh`, so the folder and file
must share a name. Then:

1. Set the `# description:` header — the launcher shows and filters on it.
2. Set the `# export-setup:` manifest (tools the standalone [export](../../docs/export.md)
   should pre-install) if the script has extra deps beyond the floor.
3. Keep the **vendor-aware `COMMON_DIR`** block so the script also works when exported.
4. Replace the `foo` / `FOO_*` / `TODO` placeholders with your tool's specifics.

## Conventions these encode

- `set -euo pipefail`; source `_common/ui.sh` (+ `deps.sh` / `cluster.sh` /
  `portforward.sh` as needed) vendor-aware.
- Prompt and confirm with **gum**; never auto-install system packages silently —
  use `_common/deps.sh`'s `_ensure_pkg` / `_ensure_pkgs` (dnf/apt/rpm-ostree aware).
- For anything reusable non-interactively, prefer the **engine-frontend** split
  (gum-free engine in its own repo + this thin TUI) — see
  [`docs/engine-split-candidates.md`](../../docs/engine-split-candidates.md).
