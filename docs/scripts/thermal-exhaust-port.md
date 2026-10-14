# Fan curve for EC-controlled fans — thermal-exhaust-port

`thermal-exhaust-port/thermal-exhaust-port.sh` · Engine: [malahmen/thermal-exhaust-port](https://github.com/malahmen/thermal-exhaust-port)

Listed in the launcher as `thermal-exhaust-port/thermal-exhaust-port.sh — Stepped fan curve for EC-controlled fans (Framework Desktop) — no hwmon PWM needed`.

Runs a stepped temperature → fan-duty curve on machines whose fans sit behind an
embedded controller instead of hwmon PWM. The curve logic is the standalone,
gum-free **thermal-exhaust-port** engine, kept in its own repository, built to
run as a systemd service. scomp-link ships only the interactive front-end. That
front-end finds the engine in this order: `$THERMAL_EXHAUST_PORT_DIR`, a sibling
checkout, `~/.cache/scomp-link/thermal-exhaust-port`, and finally a clone over
public HTTPS (the repo can be overridden with `$THERMAL_EXHAUST_PORT_REPO`). It
then drives the engine with flags.

## Why it exists

On a Framework Desktop (Ryzen AI Max 300), `/sys/class/hwmon` exposes **no
`pwm*` nodes at all**. `cros_ec` offers read-only RPM and temperatures, and
`fan1_target` is not writable, so fan-control, `fancontrol` and coolercontrol
all have nothing to drive. Fan control goes through the EC, via `ectool` — and
the stock EC curve is lazy: the SoC idles near 70 °C and drifts into the 80s and
90s under load before the EC reacts.

The engine is not a wrapper around `ectool`. `ectool fanduty 50` sets one duty
cycle and forgets it; the curve, the hysteresis, the sensor resolution and the
daemon are the engine's.

## Requirements

`ectool`. It is **not a package** — it ships with the host's EC/firmware
tooling. On Bazzite it is already in the image (as `ectool`, `fw-ectool` and
`framework_tool`). The menu reports a missing one rather than offering an
install it cannot deliver, which is why this script declares no export deps.

Installing the service uses `sudo`, so expect a password prompt in the terminal.

## Menu

| Item | Does |
| --- | --- |
| status | Service state, where the config came from, the curve, the hottest watched sensor, fan RPM, and the service's last few step changes from its journal |
| try a curve | Pick a preset or type your own points, then walk it over a list of temperatures — touches no hardware, so it's the safe way to judge a curve |
| install the service | Pick a curve, see what it would do, confirm, then install and enable the systemd unit |
| change the curve | Rewrite just the curve of an installed service and restart it |
| choose sensors | Multi-select which hwmon chips to watch, from the ones this host actually reports |
| fan rpm | Current RPM per fan, straight from the EC |
| list sensors | Every hwmon chip with its temperature and whether it is watched |
| remove the service | Disable it, delete the unit, hand the fans back to the EC |
| quit | |

## Curves

A curve is a list of `degC:duty%` points, ascending. The duty applied is the
highest step the hottest watched sensor has reached; below the first point the
EC's own control is handed back. Four presets are offered, plus free text:

| Preset | Points |
| --- | --- |
| balanced — quiet at idle, ramps before the 80s | `72:35 78:60 84:85 88:100` |
| aggressive — airflow early, never reaches the 80s | `60:35 70:50 75:75 80:100` |
| quiet — let the EC handle anything below 78C | `78:40 84:70 88:100` |
| flat out above 70C — loud, simple, cool | `70:100` |

**Hysteresis is one-sided.** A step is entered at its temperature but only left
once the temperature falls `HYST` (default 4) degrees below it, so a machine
hovering on a threshold does not oscillate:

```
 68C -> auto (EC)
 72C -> 35%
 84C -> 85%
 92C -> 100%
 86C -> 100%      <- held: 86 is not yet 4 below 88
 80C -> 60%
```

**Try a curve, then install it.** Both *install the service* and *change the
curve* show the walk before asking for confirmation, and a curve the engine
rejects (not ascending, duty over 100, malformed) stops there — the installed
one is left alone.

## When something else is driving the fans

The EC has one fan-duty register and no record of who wrote it, and this
firmware answers `pwmgetduty` with `INVALID_COMMAND` for every index — so a duty
set by another process **cannot be read back or detected**. Last write wins,
with nothing in any log to say so. It presents as "the curve does nothing".

Two mitigations, both from the engine:

- The daemon re-sends its current step every `REASSERT` seconds (default 60), so
  a foreign write is overridden back within that window.
- The engine's `conflicts` command lists services whose unit file mentions
  `ectool` — active ones *and* enabled-but-stopped ones, which fight after the
  next boot. The front-end warns at startup and again right after an install,
  naming the unit, its state and its path. The count comes from `config` and the
  detail from `conflicts`; this script never scans systemd itself.

A heuristic, and presented as one: a daemon that calls `ectool` only from inside
a script names it nowhere in its unit and will not be found.

## Where the configuration lives

**In the systemd unit**, as `Environment=` lines — not in `~/.config`. The
daemon runs as root under systemd, so a per-user config would be read by the CLI
and ignored by the service: two sources of truth that disagree exactly when it
matters.

The unit sets the `TEP_`-prefixed variable names, which are the ones the daemon
reads. A unit written before that prefix existed is detected by the engine and
reported, because it would otherwise run defaults while `status` showed the
unit's curve.

This front-end therefore never parses the unit itself. It asks the engine
(`config`, `sensors`, `curve`) for the unit path, the installed curve, the
service state and the host's sensor list. A picker that re-derived any of that
would eventually disagree with what the service actually reads.

*change the curve* uses the engine's `set-curve`, which rewrites only the
`CURVE=` line, so an interval or a dependency added to the unit by hand
survives. *choose sensors* needs `install --force` instead, carrying the
installed curve forward, because the sensor set is not what `set-curve` edits.

## Notes

- **hwmon indices are not stable across reboots** — a driver loading in a
  different order renumbers them — so the engine resolves sensors by `name` on
  every read, and the picker lists names, not indices.
- **A chip with no temperature is not offered** as a sensor to watch; picking it
  would silently produce an unreadable sensor set.
- **An unreadable sensor is not a cold machine.** The engine holds the current
  duty rather than handing a hot machine back to the EC on a failed read.
- **The fans always go back to the EC** when the service stops — an `EXIT` trap,
  signal traps that actually exit, and `ExecStopPost` in the unit.
- **`status` is the honest answer**, not `once`. `once` reports what a cold start
  would pick; a running service can legitimately hold a higher step because of
  hysteresis, so `status` prints the service's own journal lines.
- On an ostree host the install lands in writable overlays (`/usr/local` →
  `/var/usrlocal`, and `/etc`), so it survives `rpm-ostree` updates.

## Tests

`tests/test-thermal-exhaust-port.sh` drives this front-end through the gum stub
against the real engine, with a fake sysfs tree, a recording `ectool`, a stub
`systemctl` and `TEP_SUDO=""`. The assertions are on the flags the engine was
invoked with — that the curve the user picked is the curve that reached
`install`, that *change the curve* uses `set-curve` and not a reinstall, and
that `uninstall` carries `--yes` so the engine never asks a second time.
