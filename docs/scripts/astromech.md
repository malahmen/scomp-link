# Repo maintenance droid — astromech

`astromech/astromech.sh` · Engine: [malahmen/astromech](https://github.com/malahmen/astromech)

Listed in the launcher as `astromech/astromech.sh — Keep every git repo under your folders fresh (commit/stash + pull --rebase) and tidy merged local branches`.

Keeps every git repository under one or more folders on an up-to-date default
branch. The repo logic is the standalone, gum-free **astromech** engine, kept in
its own repository. scomp-link ships only the interactive front-end. That
front-end finds the engine in this order: `$ASTROMECH_DIR`, a sibling checkout,
`~/.cache/scomp-link/astromech`, and finally a clone over public HTTPS (the repo
can be overridden with `$ASTROMECH_REPO`). It then drives the engine with flags.
With no prompts, the engine can also run from cron.

## First run

1. **Repository paths.** You're asked for a folder holding git repositories, and
   asked again until you leave the field empty or answer *No* to "Add another
   folder?". You can add several.
2. **Ignored folders.** For each new path you get a multi-select of its
   top-level folders. Space toggles a folder and Enter confirms. Pressing Enter
   with nothing selected means nothing is ignored.
3. **"Run maintenance on all repositories now?"** This is asked **once**. *Yes*
   runs maintenance and then opens the menu. *No* opens the menu directly. Esc
   skips the question, so it comes back next launch. Every later launch goes
   straight to the menu.

## Menu

| Item | Does |
| --- | --- |
| Trigger maintenance | Run it (after a confirmation), run it **and then tidy merged branches**, or do a dry run that shows what would happen and changes nothing |
| Tidy merged branches | List the local branches the trunk already holds, then delete them after a confirmation — all repos or one |
| Edit repository paths | Add paths (each followed by its ignore picker) or remove paths (multi-select; their ignores go too; nothing on disk is touched) |
| Edit ignored folders | Pick a path (if you have several), then the multi-select, with the current ignores already ticked |
| Fetch pruning (fetch.prune) | Show whether git prunes stale `origin/*` refs on fetch, what it does and does not prune, any repo overriding it — and toggle it |
| Status | A tree per path: repos (relative path, `[branch]`, `*` = uncommitted changes), the branches **Tidy merged branches** would delete, and ignored folders |
| Quit | |

The last two items only appear if the resolved engine actually has those
commands. A cached engine can be older than this front-end, and a menu item
that fails after you pick it is worse than one that is absent, so the menu is
built from the command list the engine reports in its own `--help`.

## Tidy merged branches

Deletes local branches whose work the trunk already holds — what's left behind
after a PR is merged and the forge deletes its own copy. **No git setting does
this**; see [Fetch pruning](#fetch-pruning) for the one people confuse it with.

You pick every repository or just one, then get the plan before anything
happens:

```
branches already contained in their trunk — these would be deleted:

  ~/code/astromech  (merged into origin/main)
      ci/github-actions                            4055a00
      fix/lock-handling                            afdef48

  1 branch(es) in 1 repo(s).
```

The short sha is the recovery handle (`git branch <name> <sha>`). Then a
confirmation, and only then the deletion.

- **"Merged" means contained in the trunk on `origin`**, as of the last fetch —
  not the local trunk, which can be behind or hold a merge nobody else has.
- **Deletion is `git branch -d`, never `-D`.** One git considers unmerged is
  reported with the `-D` command to run yourself, not forced.
- Branches that are the trunk, checked out, or held by another worktree are
  never listed. Repos mid-rebase, detached, or with no trunk are reported and
  left alone.

**Status** lists the same branches under each repo, with a count at the end, so
you can see what has piled up without being asked to delete anything. It comes
from the same function tidy plans with — not a second similar-looking query —
so the two can never disagree.

*Run maintenance, then tidy* does the pull first, so a branch merged since your
last fetch counts. Tidy on its own never touches the network, which can only
make it see **fewer** branches as merged, never more.

The engine asks on `/dev/tty` when driven from a shell — right for cron, wrong
inside gum. So the front-end uses the flags that exist for this: `--dry-run`
for the plan, gum for the answer, `--yes` to act. You are asked exactly once.

## Fetch pruning

The setting people mean when they ask whether git can do tidy's job. It can't,
but it can do the *other* half:

| | Prunes |
| --- | --- |
| `fetch.prune` | stale `origin/*` **remote-tracking refs**, on every fetch — and maintenance's `git pull --rebase` is a fetch |
| A forge's *delete branch on merge* | the branch **on the forge** |
| Tidy merged branches | merged **local** branches — nothing in git configures this |

The menu shows the current state with the engine's own explanation, lists any
repository that overrides it (a repo-local `fetch.prune`, or
`remote.origin.prune`, which beats `fetch.prune` at any scope), and offers the
toggle. Toggling writes `--global` and prints the exact way back.

`fetch.pruneTags` is deliberately not offered: it prunes local tags the remote
no longer has, a much bigger promise than dropping a stale branch ref.

## What maintenance does, per repo

| Repo state | Action |
| --- | --- |
| On a feature branch | `git add -A` (untracked files included) + commit `wip: auto-commit before astromech maintenance (YYYY-MM-DD)`, then check out main/master |
| On main/master with changes | `git stash push -u`. The stash is **left for you** and never popped. |
| Then | `git pull --rebase` |

- **Nothing is pushed**, including the wip commit on the feature branch.
- **Default branch:** `main` if it exists locally or on `origin`, otherwise `master`.
- **If a step fails,** the repo is reported and left as that step left it, and
  the run continues with the next repo. A rebase that stops on a conflict stays
  stopped for you to resolve (`git status`, then `git rebase --continue` or
  `--abort`). If a commit fails (a hook, or no git identity configured), the
  changes are unstaged again, so the repo is unchanged.
- **Skipped and reported, never touched:** a rebase, merge, cherry-pick, revert
  or bisect in progress; detached HEAD; neither main nor master exists.
- The run ends with a summary (ok / skipped / failed) that lists every skipped
  and failed repo with the reason.

## Discovery

Repos are found **recursively** below each path. Any folder containing `.git`
counts. The search never goes inside a repo it has already found, and it skips
hidden folders, symlinks and ignored folders. Depth is capped at 6 levels below
the path (`ASTROMECH_MAX_DEPTH`). Ignores apply to a path's top-level folders,
and an ignored folder's whole subtree is skipped.

## Config

The engine owns `~/.config/astromech/astromech.conf`: plain `key=value` lines
(`root=`, `ignore=`, `onboarded=`). The front-end never edits the file itself.
It asks the engine (`config`, `roots`, `children`, `set-ignores`, …), so the
menus always match what a run will do.

## Without the TUI

```bash
astromech.sh maintain --dry-run
astromech.sh maintain               # exit 1 if any repo failed (skips don't count)
astromech.sh maintain --tidy --yes  # …and delete merged local branches after each pull
astromech.sh tidy --dry-run         # the plan, and nothing else
astromech.sh tidy                   # the plan, then it asks on /dev/tty
astromech.sh prune                  # fetch.prune: state, explanation, overrides
astromech.sh prune on
astromech.sh status
astromech.sh --help
```

Unattended runs must pass `--yes` to tidy: with no terminal to ask on it
refuses and exits non-zero rather than assume consent.

See the [engine README](https://github.com/malahmen/astromech) for the full
command list and a cron example.
