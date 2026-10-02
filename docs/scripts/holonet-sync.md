# Gitea ↔ GitHub reconciler — holonet-sync

`holonet-sync/holonet-sync.sh` · Engine: [malahmen/holonet-sync](https://github.com/malahmen/holonet-sync)

Listed in the launcher as `holonet-sync/holonet-sync.sh — Reconcile repos both ways between Gitea and GitHub (branches, tags, never force-push)`.

Keeps a list of Gitea repos and their GitHub twins converged **both ways**. Not
a mirror: neither side is the master copy, and nothing is ever force-overwritten.
The reconciliation logic is the standalone, gum-free **holonet-sync** engine
(kept in its own repository); scomp-link ships only the interactive front-end,
which resolves the engine (`$HOLONET_SYNC_DIR` → sibling checkout →
`~/.cache/scomp-link/holonet-sync` → clone from public HTTPS, repo overridable
with `$HOLONET_SYNC_REPO`) and drives it with flags.

The split matters more here than for most: a reconciler's natural home is a cron
job or a systemd timer, and the engine is built for exactly that — no prompts, no
gum, no auto-install, plain UTC-timestamped log lines when there's no terminal.
This menu is for the times you're actually watching.

## What the engine does

Per branch it compares three things — the GitHub tip, the Gitea tip, and the
**last-synced base** (what both sides agreed on at the end of the previous run) —
and from that decides what actually happened:

| Situation | What it does |
| --- | --- |
| One side is behind | Fast-forwards it |
| Branch is new on one side | Creates it on the other |
| Branch deleted on one side, untouched on the other | Deletes it on the surviving side |
| Branch deleted on one side but with new commits on the other | Restores it and alerts |
| Protected branch (`main`, `master`) vanished | Restores it and alerts |
| Branches diverged, merge is clean | Auto-merges and pushes the merge to both sides |
| Branches diverged with conflicts | Leaves both alone and alerts |
| Tag missing on one side | Copies it |
| Tag differs between sides | Leaves both alone and alerts (tag deletions are never propagated) |

Every push and delete carries `--force-with-lease`, so a remote that moved since
the fetch fails the push instead of being overwritten. A converged pair produces
zero pushes, so the tool's own pushes can't start a cascade.

Full details — guards, config reference, tokens, state layout — live in the
[engine's README](https://github.com/malahmen/holonet-sync).

## Menu

The front-end resolves the engine, then asks it where its config lives
(`engine config`) and which pairs are configured (`engine repos`), so the picker
can't disagree with what a run would actually sync. With no config yet, it offers
to write the example one and stops there.

| Action | What it does |
| --- | --- |
| status | Last recorded result per repo (no network) |
| dry-run | Picks a repo (or all), then plans everything and pushes nothing |
| run | Same, for real, after a final confirm naming the scope |
| check | Validates tools, git version, tokens, repo access and Gitea push mirrors |
| edit config | Opens the config or the repo list in `$EDITOR` |
| reset state | Forgets the sync base for one repo (next run re-seeds; deletes nothing) |
| install deps | Ensures `git`, `curl`, `jq`, `flock`, coreutils (dnf/apt/rpm-ostree) |

`run` and `check` run in the foreground with Ctrl-C returning to the menu rather
than killing the TUI. `dry-run` and `run` offer verbose logging, then an
optional "Advanced options" step for the engine's override flags:
`--allow-deletions` (bypasses `MAX_DELETIONS` and the empty-side guard, the only
way past those refusals from the menu) and `--no-api` (skips twin lookup and
creation). Esc at any prompt returns to the menu without running anything.

**Dependency installation lives here, not in the engine.** An engine that layers
OS packages behind your back is not something you put in a timer, so it only
reports what's missing; `install deps` is where there's someone to answer the
prompt.

## Running it unattended

The whole point of the split. Point cron or a systemd timer straight at the
engine — scomp-link isn't needed at all:

```sh
*/15 * * * * /path/to/holonet-sync/holonet-sync.sh run >> /var/log/holonet-sync.log 2>&1
```

Use the menu's `check` (or `holonet-sync.sh check`) once before the first timed
run: it catches a missing `workflow` token scope, a too-old git, and Gitea push
mirrors that would fight the tool over every ref.

## Configuration

Config and state belong to the engine, not to scomp-link:

- `~/.config/holonet-sync/holonet-sync.conf` — sourced by bash; `init` writes a
  commented example. `$HOLONET_SYNC_CONFIG` points elsewhere, and the front-end
  passes it straight through by inheriting the environment.
- `~/.config/holonet-sync/repos.list` — `<gitea owner/name> <github owner/name> [private|public]`, one pair per line.
- `~/.local/state/holonet-sync/` — bare workspaces, the sync base, status lines
  and alert stamps. **Persist it**: losing it loses no data, but the next run
  re-seeds from scratch, and a re-seeding run can only create and merge.

## Notes

- **Requires git ≥ 2.38** for `merge-tree --write-tree`, which is how a clean
  divergence is merged inside the bare workspace with no working tree. `check`
  verifies the version.
- The engine's test suite (`tests/test-local.sh` in its repo) runs the whole
  thing against `file://` repos — no network, no tokens, 19 scenarios.
- Tokens: Gitea needs `write:repository` + `read:user`; GitHub needs a classic
  PAT with `repo` **and** `workflow`.

**Dependencies:** `gum` and `git` for the front-end; the engine additionally
needs `curl`, `jq`, `flock`, `base64`, `sha1sum` and git ≥ 2.38.
