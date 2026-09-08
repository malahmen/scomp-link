# wow-dark-portal (vanilla WoW multibox client)

`wow-dark-portal/wow-dark-portal.sh`

A gum front-end for **[dark-portal](https://github.com/malahmen/dark-portal)**, a
standalone, gum-free engine that provisions and launches multiple vanilla WoW
(1.12.1) game clients under Wine on a single Linux PC, for **multiboxing**.
scomp-link ships only the interactive front-end, auto-discovered in the launcher
like any other script; the provisioning/launch logic lives in the engine's own
repo — the same split as [wow-nordrassil](wow-nordrassil.md) (the server side),
[holo-convert](holo-convert.md), and [protocol-droid](protocol-droid.md). It's
named `wow-dark-portal` so it sorts next to `wow-nordrassil`.

Companion to [Vanilla WoW Server](wow-nordrassil.md) but entirely independent —
it never touches the server, only the client(s) that connect to one (this repo's
own server or any other vanilla-family realm on the LAN).

## Engine resolution

The front-end finds `dark-portal.sh` automatically, in order:

1. `$DARK_PORTAL_DIR/dark-portal.sh` (explicit override)
2. `../../../dark-portal/dark-portal.sh` (a local sibling checkout)
3. `~/.cache/scomp-link/dark-portal/` (a cached clone; offers `git pull`)
4. a fresh `git clone --depth 1` from the public repo

All interactivity stays in the front-end — it collects options with gum and
persists them into the engine's config store (`~/.config/dark-portal/`) with the
engine's `set` command, then runs the matching flag-driven subcommand. The
engine itself never prompts.

## What it does

- **Wine runtime is Bottles (Flatpak, `com.usebottles.bottles`)**, not a
  host-layered `wine`/`wine-core` package — on immutable/atomic hosts (e.g.
  Bazzite) a layered `wine-core` needs a reboot and its `wineboot --init` has
  been observed to hang; Bottles bundles a known-good runner, needs no reboot,
  and works the same on any distro with Flatpak+Flathub.
- **Multiple simultaneous instances**: each "box" gets its own Bottles bottle (a
  real, independent Wine prefix — registry/DirectX state can't collide) and its
  own WTF/Cache/Logs (account state, saved vars, addon cache can't collide).
- **Two file-isolation modes** (`set CLIENT_ISOLATION_MODE`): `full` (a complete
  copy per instance — more disk, but avoids the read contention/disconnects that
  many Wine processes hitting a symlink-shared install cause at higher instance
  counts on one SSD) or `shared` (symlinks the large/static dirs, private
  WTF/Cache/Logs/Errors/Screenshots/realmlist.wtf — minimal disk, best at low
  counts).
- **Each instance launches WoW.exe directly** in ordinary decorated windowed
  mode (sized via `Config.wtf`'s `gxWindow`/`gxResolution`) — not wrapped in a
  Wine virtual desktop, since that wrapper is itself a borderless window some
  WMs force-fullscreen regardless of size, defeating multi-box tiling.
- **Window identity for key broadcasters**: `launch` spawns a small background
  "title keeper" that finds the window this instance just created (a
  before/after window-ID diff, since Wine doesn't reliably expose `_NET_WM_PID`
  or a unique `WM_CLASS` here) and re-asserts its title to the instance name for
  as long as the game runs — a stable, unique handle to target (e.g. from
  [clone-army](clone-army.md)). Requires `xdotool`.
- **LAN realm discovery**: `discover-realm` scans the local `/24` for hosts with
  the realm port (3724 by default) open — via `nmap` if installed, a parallel
  pure-bash `/dev/tcp` sweep otherwise — and lets you pick one to prefill the
  default realm. A port probe, not a full protocol handshake; always a prefill
  you can override.
- **`launch` re-renders the realm every time** (the instance's own override if
  set, otherwise the global default): both the client-root `realmlist.wtf`
  (vanilla 1.12 reads it there, not `WTF/`) and any cached `SET realmList`/`SET
  realmName` cvars in `WTF/Config.wtf` some builds prioritize over it — so a
  `set`/`edit-instance` change is never silently stale.
- **`winecfg`**: the standard Wine configuration GUI scoped to one instance's
  bottle, for DirectX/sound/DLL tuning the script doesn't guess per distro.
- **`stop`** kills via `wineserver -k` scoped to that instance's own bottle,
  with a `pkill` fallback on the instance's own client path — each bottle's
  `wineserver` is independent, so this can never affect another instance.

Account creation/login isn't handled here — same as real WoW, that happens in
the client's own login/character-creation screens against the server.

> **Platform:** Linux + Flatpak/Bottles + X11/XWayland. macOS can drive the
> config subcommands, but provisioning and launching clients needs Linux.

## Menu

Categories mirror the workflow: **Setup** (install-deps, configure,
discover-realm, winecfg) · **Instances** (add / list / edit / remove) · **Launch**
(launch, stop, stop-all) · **Status**.

## Driving the engine directly

You can skip the TUI and call the engine yourself:

```sh
dark-portal.sh set CLIENT_SOURCE_DIR ~/games/vanilla-wow
dark-portal.sh set BOTTLES_RUNNER soda-9.0-1
dark-portal.sh configure
dark-portal.sh add-instance --name box1 --resolution 1280x720
dark-portal.sh launch --name box1
dark-portal.sh --help
```

See the [engine README](https://github.com/malahmen/dark-portal) for the full
flag reference.

Companion script: [Vanilla WoW Server](wow-nordrassil.md).
