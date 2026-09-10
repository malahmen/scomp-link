# wow-nordrassil (vanilla WoW server)

`wow-nordrassil/wow-nordrassil.sh`

A gum front-end for **[nordrassil](https://github.com/malahmen/nordrassil)**, a
standalone, gum-free engine that builds, containerizes, and deploys a
[VMaNGOS](https://github.com/vmangos/core)-based vanilla WoW server (1.12.1,
client build 5875) from a repack's own source — natively for local iteration and
as a Docker/K8s deployment for LAN play. scomp-link ships only the interactive
front-end, auto-discovered in the launcher like any other script; the build /
deploy / DB / admin logic lives in the engine's own repo — the same split as
[holo-convert](holo-convert.md), [protocol-droid](protocol-droid.md), and
[younglings-key](younglings-key.md). It's named `wow-nordrassil` so it sorts
next to [wow-dark-portal](wow-dark-portal.md) (the client front-end) in the
launcher.

## Engine resolution

The front-end finds `nordrassil.sh` automatically, in order:

1. `$NORDRASSIL_DIR/nordrassil.sh` (explicit override)
2. `../../../nordrassil/nordrassil.sh` (a local sibling checkout)
3. `~/.cache/scomp-link/nordrassil/` (a cached clone; offers `git pull`)
4. a fresh `git clone --depth 1` from the public repo (`$NORDRASSIL_REPO`
   overrides the clone URL)

The front-end keeps **all** interactivity — it collects options with gum and
persists them into the engine's config store (`~/.config/nordrassil/`) with the
engine's `set` command, then runs the matching flag-driven subcommand. The
engine itself never prompts.

## What it does

- **No Wine required** — builds native Linux `mangosd`/`realmd` from the repack's
  bundled C++ source (not the Windows `.exe`s), using its official Linux Docker
  build recipe as reference.
- **Database**: always a separate MariaDB container/pod, never bundled into the
  server image. One DB-bootstrap sequence (schemas → base/anticheat schemas →
  world dump → migrations routed to their correct database → optional custom
  content → `realmlist` seeding) is shared between local `configure` and a
  one-shot K8s Job.
- **Configure** collects the server's identity and gameplay settings, not just
  the DB import: realm name/zone, game type, player limit, progression content
  patch, MOTD and XP/loot rate multipliers (`mangosd.conf`), plus login-security
  settings — brute-force ban rules, email verification, strict version check,
  strict player names (`realmd.conf`). Each answer is persisted and pre-fills on
  the next run, so re-running only tweaks what changed.
- **Optional custom content** (a repack-provided `sql/Custom/*.sql`) is picked
  file by file, not one all-or-nothing yes/no — repacks bundle unrelated things
  there (e.g. a one-line SQL that spawns every new character in the same spot).
  Already-applied files are skipped on a later run.
- **Source patches**: `build-image` applies scomp-link-maintained fixes to the
  repack's C++ source (`templates/patches/*.patch` in the engine, via
  `git apply`) on top of the pristine unzip, before compiling. Currently one:
  gates the DBC-based profanity/reserved-name check behind `StrictPlayerNames`
  (the same setting that already gates the character-set check next to it),
  which otherwise runs unconditionally and permanently blocks any character
  whose name matches `NamesReserved.dbc`/`NamesProfanity.dbc`. Idempotent per
  patch.
- **Edit**: opens an already-configured conf file (`mangosd`/`realmd`) in
  `$EDITOR` (default vim) for anything the prompts don't cover; deploy commands
  pick up manual edits instead of overwriting them.
- **Status** also prints the exact `set realmlist <address>[:<port>]` line for
  the client's `WTF/realmlist.wtf`.
- **Create / delete / set-level accounts**: game accounts use SRP6 credentials
  (not a hash safe to hand-edit), so these send `account create` / `account set
  gmlevel` / `account delete` through mangosd's own console (fed via a FIFO so a
  backgrounded container still has a reachable console). All account commands
  auto-detect whether the server is running locally, in Docker, or in K8s;
  when it runs in more than one place the engine needs `--where
  local|docker|k8s`, so the front-end asks first (auto-detect / local /
  docker / k8s — the last also asks for the kube target).
  `delete-account` also sweeps a leftover `account_access` row the server's own
  delete misses; `set-account-level` promotes/demotes without recreating (which
  would lose characters).
- **GM level scale**: the picker uses the server's real security levels
  (`src/shared/Common.h` `AccountTypes`): `0` Player … `6` Administrator (most
  in-game GM commands need `6`). Level `7` (Console) is reserved and not offered.
- **List-accounts**: no console command lists every account, so this queries the
  DB directly (touches no credentials).
- **Rename-character**: an immediate, exact rename via a direct DB update —
  deliberately bypassing the normal naming rules for one character. Refuses if
  the character is online, checks the 12-char limit, and clears
  `CHARACTER_FLAG_RENAME` as part of the same update. Use **Search** to find the
  name first.
- **Search**: name lookup across items, NPCs, GM teleport locations
  (`game_tele`), and player characters — plain DB reads, works even if mangosd
  isn't running.
- **Warden anti-cheat modules**: baked into the Docker/K8s image at build time,
  pointed at the repack directly for local native. `configure` can disable
  Warden outright for a private/trusted LAN.
- **LAN exposure**: host networking throughout (`docker run --network host` /
  K8s `hostNetwork: true`) — the realm port (3724) is client-hardcoded and
  outside K8s's default NodePort range.
- **Storage** (K8s): hostPath (default) or a StorageClass-backed PVC, chosen at
  deploy time and persisted to config.

## Menu

Categories mirror the workflow: **Setup** (install-deps, configure, edit) ·
**Local** (start, stop) · **Deploy** (build-image, run-docker, stop-docker,
run-k8s, stop-k8s) · **Accounts** · **Characters** (rename) · **Search** ·
**Status**. For a K8s action the front-end first asks for the target (current
context / a kind cluster / a named context).

## Driving the engine directly

You can skip the TUI and call the engine yourself:

```sh
nordrassil.sh set SOURCE_DIR ~/jaws/MaNGOS
nordrassil.sh configure
nordrassil.sh build-image && nordrassil.sh run-docker --force
nordrassil.sh --kind homelab run-k8s --namespace wow --address 192.168.1.50
nordrassil.sh create-account --name admin --pass secret --level 6
nordrassil.sh --help
```

The engine's native build (`start`/`stop`) targets Debian/Ubuntu first; check
the engine README for Fedora support. The Docker path always builds inside an
Ubuntu stage regardless of host OS. See the
[engine README](https://github.com/malahmen/nordrassil) for the full flag
reference.

Companion script: [Vanilla WoW Client / Multiboxing](wow-dark-portal.md).
