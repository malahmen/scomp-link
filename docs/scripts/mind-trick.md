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
3. Shows a **dry-run** report of the matching commits/branches.
4. Asks before **rewriting**, and again before **force-pushing**.

## Safety

- **Dry-run first**; nothing changes until you confirm.
- **Backup** — a `git bundle` of the whole repo is written to `~/.cache/mind-trick/`
  before any rewrite (restore: `git clone <bundle>`).
- Refuses a dirty working tree; force-push is a separate confirmation.
- Only commit *messages* change — content (trees) is identical.

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
reference. Requires only **git**.
