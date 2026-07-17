# Exporting a script

`export.sh` bundles a single script into a **flat, standalone folder** that runs
with no scomp-link checkout, no `init.sh`, and no `_common/` parent directory.
Use it to hand a tool to someone (or drop it into another project) without
shipping the whole repo.

## Usage

```bash
./export.sh                          # pick a script + target directory interactively
./export.sh postgres                 # pick the target interactively
./export.sh postgres ~/pg            # fully non-interactive
```

From the launcher, choose **“Export a script → standalone folder”** — one of the
special entries in the `init.sh` menu.

You can pass either a folder name (`postgres`) or the discovered
`folder/script.sh` path.

## What you get

A flat directory — everything the script needs, side by side:

```
~/pg/
  postgres.sh                              the script + any co-located assets
  ui.sh deps.sh cluster.sh portforward.sh  only the _common helpers it sources
  setup.sh                                 slimmed bootstrap (framework floor + this script's deps)
  wsl-setup.ps1                            Windows/WSL bootstrap (runs setup.sh inside WSL)
```

Run it anywhere:

```bash
cd ~/pg
bash setup.sh          # once — installs dependencies
bash postgres.sh
```

On Windows, run `wsl-setup.ps1` (it bootstraps `setup.sh` inside WSL).

## How it works

**Vendor-aware sourcing.** Every script resolves its shared helpers like this:

```bash
if [[ -d "${SCRIPT_DIR}/../_common" ]]; then
    COMMON_DIR="${SCRIPT_DIR}/../_common"   # inside the scomp-link repo
else
    COMMON_DIR="${SCRIPT_DIR}"              # exported — helpers sit alongside
fi
```

So the same script works both in the repo and when its `_common` helpers are
copied next to it. `_common` files don't source each other, so a script's
`source` lines are the complete dependency set — no hidden closure.

**What `export.sh` does:**

1. Copies the script's folder contents (the `.sh` + co-located assets like
   `.fcc/`) flat into the target.
2. Greps the script's `source` lines and copies **only** the `_common` helpers
   it references (`ui.sh`, `deps.sh`, `gh_releases.sh`, `portforward.sh`,
   `cluster.sh`).
3. Generates a slimmed `setup.sh` (see below).
4. Copies `wsl-setup.ps1` (already scomp-link-agnostic).

There is **no `init.sh`** — you run the script directly.

## The generated `setup.sh`

The repo's `setup.sh` is split at a `# === bootstrap entrypoint ===` marker: all
the helper and `ensure_*` functions **above** the marker are reused verbatim
(single source of truth), and `export.sh` generates a slimmed entrypoint below
it. That entrypoint always installs the **framework floor**…

```
curl → mise → bash (4+) → gum
```

…then the extras your script declares in its manifest. It never launches
anything (no `exec init.sh`); it just prepares dependencies and tells you how to
run the tool.

## The export manifest

Declare what a standalone `setup.sh` should install **beyond the floor** with a
comment near the top of the script:

```bash
# export-setup: kubectl helm
```

| Token type            | How it's installed                                             |
|-----------------------|----------------------------------------------------------------|
| `vim`, `tree`, `node` | the repo `setup.sh`'s own `ensure_vim` / `ensure_tree` / `ensure_node` |
| anything else         | `ensure_tool`: `mise use --global <tok>`, falling back to `brew` / `apt` / `dnf` |

`ensure_tool` mirrors how `gum` itself is installed (via `mise`), so it covers
most CLIs cross-platform: `kubectl`, `helm`, `k9s`, `kind`, `lazygit`,
`lazydocker`, `jq`, and so on. It is **never fatal** — anything it can't
pre-install is resolved by the script's own runtime checks, exactly as inside
scomp-link.

**Floor-only scripts.** Tools that are OS packages, daemons, or full
applications (Docker Engine, LM Studio, Wine/Flatpak desktop apps, Linux-only
system utilities) are *not* declared — those scripts carry a documentary note
instead and export the floor only, provisioning their deps at runtime:

```bash
# Standalone export (export.sh): no extra setup deps — Docker Engine + Compose
# are checked/instructed at runtime.
```

## Notes & limitations

- **Heavy deps can stay at runtime.** A manifest need only declare what's worth
  pre-installing; large or specialized tools can be left to the script's own
  runtime checks rather than pulled in by every export.
- **`mise` shims.** Tools installed by `ensure_tool` land in
  `~/.local/share/mise/shims`; `setup.sh` adds that to `PATH` for the session,
  and `mise` activation (configured by the floor) keeps them available in new
  shells.
- **Re-exporting** into an existing folder overwrites its contents (after a
  confirmation prompt).
