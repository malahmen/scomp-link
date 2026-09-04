# Notes: standalone flag-driven CLI engines (holo-convert / akinn pattern)

Parked idea — not scheduled work. Direction: over time, factor the scripts whose
core is real, reusable logic into **standalone, gum-free, flag-driven CLI engines**
(their own repos), with scomp-link shipping only a thin **gum TUI front-end** that
drives the engine by flags — the shape of `akinn_tui` → [akinn](https://github.com/malahmen/akinn)
and `holo-convert`. New scripts should be **written flag-driven from the start** so a
front-end is a thin wrapper, not a rewrite.

## The test for splitting
A script is worth extracting only when its core is:
1. **Useful non-interactively** — runnable in CI, a Makefile, cron, or another tool.
2. **Substantial & versionable on its own** — enough real logic for its own repo/releases.
3. **Not a thin veneer over an already-standalone CLI** — the killer. If it mostly
   shells out to `kubectl`/`helm`/`docker`/`npx`, that tool *is* the engine; a new repo
   just re-wraps it and adds nothing but maintenance.

## Already in this shape
- **`akinn_tui`** — front-end for the standalone Akinn repo (resolve → cache → clone). The precedent.
- **`holo-convert`** — engine in its own repo; scomp-link ships the TUI.
- **`younglings-key`** (ignite) — certificate engine in its own repo; scomp-link ships the TUI.
- **`navicomputer`** — SSH-profile engine (ex-`sshger`) in its own repo; scomp-link ships the TUI.
- **`mind-trick`** — git-history trailer scrubber in its own repo; scomp-link ships the TUI. (Small/generic — split mainly to keep the pattern; `export.sh` would also have made it standalone.)
- **`protocol-droid`** — the containerized document-conversion service (Redis queue + enqueue API + scalable marker workers + Docker/k8s templates), split out of `marker`. scomp-link's marker "Deploy as a service" menu is now a thin front-end; local pipx conversion stays in `marker.sh`.

## Worth splitting (real standalone value) — ranked
| Script | Rationale | Lift |
| --- | --- | --- |
| ~~**`sshger`**~~ ✅ done → **navicomputer** | `~/.ssh/config` CRUD as a flag-driven CLI. Split into the navicomputer engine repo + scomp-link TUI. | Small |
| ~~**marker *service***~~ ✅ done → **protocol-droid** | The containerized conversion service (api/worker/redis + Docker/k8s templates) extracted to its own repo; local pipx bits kept as the marker TUI. | Medium |
| **`vanilla-wow-server`** | Real build/containerize/deploy logic + Dockerfile/entrypoint/k8s templates — a genuine "deploy a VMaNGOS server" tool. | Medium |
| **`vanilla-wow-client`** | Non-trivial Wine multiboxing config/launch logic; standalone value for that community. | Medium |
| **`comfyengine`** (maybe) | It's our own ComfyEngine build — the build script arguably belongs *with* ComfyEngine's repo. | Small–Med |

## Not worth splitting (thin CLI wrappers — leave as TUI-over-CLI)
- **Databases** (postgres, mariadb, mysql, mongodb, redis, qdrant, influxdb) — `docker`/`helm` (Bitnami) glue; shared logic already in `_common/`.
- **Observability** (lgtm, prometheus, grafana, dozzle) and **Platform** (harbor, n8n) — helm/docker glue.
- **kind, karpenter, argo, docker, k9s, lazydocker, lazygit** — install/launch veneers over their own CLIs.
- **`bmad`** — `npx bmad-method` is the engine (its own repo already); our script is lifecycle glue.
- **`starlight`** — mostly `npm create astro` scaffolding; its converter already delegates to holo-convert.

## When we pick this up
- Next up: **vanilla-wow-server/client** (bigger lifts). (sshger done → navicomputer; marker service done → protocol-droid.)
- Reuse the holo-convert engine-resolution pattern: `$XXX_DIR` override → sibling checkout → `~/.cache/scomp-link/<name>` clone → `git clone`.
- Engine = gum-free, flags + guardrails (no auto-install); front-end = gum TUI that builds flags and offers `--setup` on missing deps.
