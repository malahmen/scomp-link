# mind-trick (scrub git history trailers)

`mind-trick/mind-trick.sh`

> "These aren't the commits you're looking for."

A gum front-end for **[mind-trick](https://github.com/malahmen/mind-trick)**, a
standalone, gum-free CLI that removes matching **commit-message trailer lines**
(default `Co-Authored-By: Claude …`) from every commit across **all branches** of a
repo, then optionally force-pushes. scomp-link ships only the front-end; the logic
lives in the engine's own repo — the same split as [holo-convert](holo-convert.md)
and [navicomputer](navicomputer.md).

## Engine resolution

The front-end finds `mind-trick.sh` automatically, in order:

1. `$MIND_TRICK_DIR/mind-trick.sh` (explicit override)
2. `../../../mind-trick/mind-trick.sh` (a local sibling checkout)
3. `~/.cache/scomp-link/mind-trick/` (a cached clone; offers `git pull`)
4. a fresh `git clone --depth 1` from the public repo

## Interactive flow

Launched from the scomp-link menu it:

1. Asks for a path — a **git repo** (used directly) *or* a **folder containing
   repos**, in which case it lists the repos inside and you pick **one** (never
   several — it's a sensitive op).
2. Asks for the pattern to remove (`grep -iE`, default the AI co-author trailer).
3. Shows a **dry-run** report of the matching commits/branches. If nothing
   matches, it stops there.
4. If this machine has no history-rewriting tool (git 2.55 removed
   `filter-branch`), offers to install **git filter-repo**: one pinned,
   checksum-verified file into `~/.local/bin`, no root (the engine's `--setup`).
5. Asks before **rewriting**, and again before **force-pushing**.

## Safety

- **Dry-run first**; nothing changes until you confirm.
- **Backup** — a `git bundle` of the whole repo is written to `~/.cache/mind-trick/`
  before any rewrite (restore: `git clone <bundle>`).
- Refuses a dirty working tree (untracked files count as dirty too); force-push
  is a separate confirmation.
- Only commit *messages* change — content (trees) is identical.

## Limitations (read before pushing)

- **Rewritten:** every local branch, all tags (re-created on the rewritten
  commits) and the `origin/*` tracking refs.
- **Push scope**: local branches that have a matching `origin/<branch>`, with
  `--force-with-lease` (a remote someone pushed to meanwhile is refused, not
  overwritten), then all tags with `--force`. Other remotes and remote-only
  branches are left untouched.
- **Signatures are stripped** — rewritten commits lose their GPG/SSH signatures.
- **Shallow clones are unsupported** — use a full clone.

## What it can't do

It cannot remove commits GitHub keeps in **`refs/pull/*`** — merged-PR pages still
show their original commits. Only **branch history** and, once GitHub recomputes,
the **Contributors graph** are cleaned.

## Driving the engine directly

Skip the TUI:

```sh
mind-trick.sh --repo ~/code/myrepo --apply --push
mind-trick.sh --repo . --pattern '^Signed-off-by:' --apply
mind-trick.sh --help
```

See the [engine README](https://github.com/malahmen/mind-trick) for the full flag
reference. Requires **git**, plus **git filter-repo** (`mind-trick.sh --setup`
installs it; needs `python3` and `curl`). `git filter-branch` is used where it
still exists, which is no longer the case from git 2.55.
