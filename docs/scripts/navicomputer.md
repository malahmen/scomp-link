# navicomputer (SSH profile manager)

`navicomputer/navicomputer.sh`

A gum front-end for **[navicomputer](https://github.com/malahmen/navicomputer)**,
a standalone, gum-free SSH-profile engine (a flag-driven CLI over `~/.ssh/config`).
scomp-link ships only the interactive front-end, auto-discovered in the launcher;
the logic lives in the engine's own repo — the same split as
[holo-convert](holo-convert.md) and [younglings-key](younglings-key.md). It
replaces the former in-repo `sshger.sh`.

## Engine resolution

The front-end finds `navicomputer.sh` automatically, in order:

1. `$NAVICOMPUTER_DIR/navicomputer.sh` (explicit override)
2. `../../../navicomputer/navicomputer.sh` (a local sibling checkout)
3. `~/.cache/scomp-link/navicomputer/` (a cached clone; offers `git pull`)
4. a fresh `git clone --depth 1` from the public repo

## Requirements

- **`jq`** — the engine's core dependency (and the front-end parses its JSON). If
  missing, the front-end offers to install it (Homebrew / apt / dnf).
- `ssh-keygen` (key generation), `ssh` (test/import), `git` (use) — as needed.
- `gum`, `git` (framework floor).

## What it manages

Each **profile** is a `Host` alias in `~/.ssh/config` (its `HostName`, `User`,
`Port`, `IdentityFile`, and any extra options), kept between the
`# === BEGIN sshger ===` / `# === END sshger ===` markers. The `sshger` marker is
retained for backward compatibility, so profiles from the old `sshger.sh` are
picked up unchanged.

## Menu

| Action | What it does |
| ------ | ------------ |
| **add** | Create a profile; generate a new key (ed25519/rsa) or point at an existing one; optional extra options; shows the public key + offers to copy/test |
| **import** | Adopt hosts you added to `~/.ssh/config` by hand (optionally remove the originals) |
| **list** | Show all managed profiles |
| **view** | Show one profile and its public key |
| **edit** | Change a profile's HostName/User/Port/Key/options |
| **use** | Wire a profile to a git repo (`core.sshCommand` uses its key; optional remote + git identity) |
| **test** | Verify SSH auth for selected hosts or all |
| **remove** | Delete a profile (optionally its key files) |

The **profile name is the Host alias** — the thing you type after `ssh`. To
rename, remove and re-add.

## Driving the engine directly

You can skip the TUI:

```sh
navicomputer.sh add --name github-work --hostname github.com --user git --gen-key ed25519
navicomputer.sh list --json
navicomputer.sh use --name github-work --repo ~/code/proj --init
navicomputer.sh --help
```

See the [engine README](https://github.com/malahmen/navicomputer) for the full
flag reference.
