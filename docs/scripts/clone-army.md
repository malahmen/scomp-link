# clone-army (keystroke broadcaster)

`clone-army/clone-army.sh`

> "One command, and the whole army acts as one."

A **generic** key-stroke broadcaster: group any currently-open X11/XWayland
windows, bind a hotkey to the group, and pressing it while focused on a member
sends the same key to **every** live member at once. Not tied to any one app —
useful for WoW-style multiboxing, parallel terminals, or any "do this everywhere
at once" workflow. (Formerly `vanilla-wow-broadcaster`; renamed since the tool is
game-agnostic.)

**Linux only** — X11 or XWayland. It can't intercept the hotkey while a
native-Wayland window has focus (a Wayland security boundary, not a bug).

## How it works

- **xbindkeys** grabs the configured hotkeys globally (it's the "listen for a
  global hotkey" piece xdotool lacks); each binding calls this script's own
  `send` subcommand.
- **`send`** reads the active window as a safety gate — it only fires when the
  focused window is a live member of the group — then re-discovers every matching
  open window and uses **xdotool** to send the plain key to each (including the
  focused one, since xbindkeys swallowed the physical press).
- A group matches windows by **exact title(s)** (windows you pick) or by **window
  class** (any window of that app, including ones opened later).

## Menu

| Action | What it does |
| --- | --- |
| New group | Pick open windows (or a class) + a modifier + keys to broadcast |
| Edit group | Change an existing group's windows/keys/modifier |
| Remove group | Delete a group |
| Start / Stop broadcasting | Run/stop the xbindkeys daemon for all groups |
| Install dependencies | Ensure `xbindkeys`, `xdotool`, `wmctrl` (dnf/apt/rpm-ostree) |

Config lives in `~/.config/clone-army/groups/<name>/`. Restart broadcasting after
editing a group to pick up changes.

## Multiboxing with vanilla WoW

Pairs naturally with [`vanilla-wow-client`](vanilla-wow-client.md): that script's
per-instance "title keeper" gives each game window a stable, unique title, which
you then capture as a **titles** group here — so a single keypress drives every
box. clone-army itself knows nothing about WoW; it just targets windows.

## Requirements

Bash 4+, and (Linux) `xbindkeys` + `xdotool` + `wmctrl` — installed via **Install
dependencies**.
