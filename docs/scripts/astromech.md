# Repo maintenance droid — astromech

`astromech/astromech.sh` · Engine: [malahmen/astromech](https://github.com/malahmen/astromech)

Listed in the launcher as `astromech/astromech.sh — Keep every git repo under your folders on a fresh main/master (commit/stash + pull --rebase)`.

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
| Trigger maintenance | Run it (after a confirmation), or do a dry run that shows what would happen and changes nothing |
| Edit repository paths | Add paths (each followed by its ignore picker) or remove paths (multi-select; their ignores go too; nothing on disk is touched) |
| Edit ignored folders | Pick a path (if you have several), then the multi-select, with the current ignores already ticked |
| Status | A tree per path: repos (relative path, `[branch]`, `*` = uncommitted changes) and ignored folders |
| Quit | |

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
astromech.sh status
astromech.sh --help
```

See the [engine README](https://github.com/malahmen/astromech) for the full
command list and a cron example.
