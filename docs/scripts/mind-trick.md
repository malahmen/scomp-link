# mind-trick (scrub git history trailers)

`mind-trick/mind-trick.sh`

> "These aren't the commits you're looking for."

Removes matching **commit-message trailer lines** (default `Co-Authored-By: Claude …`)
from every commit across **all branches** of a repository, then optionally
force-pushes. Handy for stripping AI co-author attribution — or any unwanted
trailer — from history.

Runs **flag-driven** (scriptable, and works when [exported](../export.md)) or, with
no arguments, through an interactive gum flow.

## Safety

History rewriting is destructive, so mind-trick is conservative:

- **Dry-run by default** — without `--apply` it only reports which commits/branches
  match; nothing changes.
- **Backup first** — `--apply` always writes a `git bundle` of the whole repo to
  `~/.cache/scomp-link/mind-trick/` before rewriting (restore with `git clone <bundle>`).
- **Refuses a dirty working tree** and non-git directories.
- **Force-push is opt-in** (`--push`) and confirmed — never automatic.
- Content is untouched — only commit *messages* change (verified: trees stay identical).

## What it can't do

It cannot remove commits GitHub keeps in **`refs/pull/*`** — a merged PR's page will
still show its original commits. Only **branch history** and, after GitHub recomputes,
the **Contributors graph** are cleaned. The tool prints this reminder after pushing.

## Usage

```sh
# Dry run in the current repo (default pattern: Co-Authored-By: Claude)
mind-trick.sh

# Non-interactive: rewrite a specific repo and force-push
mind-trick.sh --repo ~/code/myrepo --apply --push --yes

# Strip a different trailer
mind-trick.sh --repo . --pattern '^Signed-off-by:' --apply
```

Launched from the scomp-link menu (no args) it first asks for a path: give it a
**git repo** (used directly) *or* a **folder containing repos** — in which case it
lists the repos inside and lets you pick **one** (it never operates on several at
once). Then it prompts for the pattern, shows the dry run, and asks before rewriting
and before pushing. (The `--repo` flag always takes a direct repo path.)

## Flags

| Flag | Meaning |
| ---- | ------- |
| `--repo DIR` | repository to operate on (default: current directory) |
| `--pattern REGEX` | message lines to remove, `grep -iE` (default `^Co-Authored-By: Claude`) |
| `--apply` | actually rewrite history (default: dry-run) |
| `--push` | force-push the rewritten branches after `--apply` |
| `--yes` | skip confirmations (non-interactive) |
| `-h`, `--help` | show help |

## Requirements

- **git** (uses `git filter-branch`, built in). No other dependencies; `gum` only
  for the interactive mode.
