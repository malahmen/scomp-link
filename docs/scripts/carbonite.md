# Fan curve for hwmon fans, through CoolerControl — carbonite

`carbonite/carbonite.sh` · Engine: [malahmen/carbonite](https://github.com/malahmen/carbonite)

Listed in the launcher as `carbonite/carbonite.sh — Fan curve for hwmon fans (MSI/NCT6687 desktops) — applied through CoolerControl, AIO pump pinned`.

Puts the fans of a desktop board on a temperature → duty curve, kept in
CoolerControl. The logic is the standalone, gum-free **carbonite** engine in its
own repository; scomp-link ships only the interactive front-end. That front-end
finds the engine in this order: `$CARBONITE_DIR`, a sibling checkout,
`~/.cache/scomp-link/carbonite`, and finally a clone over public HTTPS (the repo
can be overridden with `$CARBONITE_REPO`). It then drives the engine with flags.

## Why it exists

It is the desktop sibling of [thermal-exhaust-port](thermal-exhaust-port.md):
the same end problem, on the opposite hardware.

- On a Framework Desktop there is no hwmon PWM at all, so thermal-exhaust-port
  is its own daemon driving the EC through `ectool`.
- On a desktop board with a Super I/O chip (an MSI PRO B760's **NCT6687**, via
  the out-of-tree `nct6687` driver) every header is a writable `pwmN`. The
  problem is the BIOS curve: with every channel left "Unmanaged" in
  CoolerControl, the board is in charge, and on the machine this was written
  for that meant a header pinned at 100% and the rest at a flat 60%.

CoolerControl is already a good daemon for hwmon fans, so carbonite is **not**
one. It writes the curve into CoolerControl over its REST API and reads it back:

| Object | CoolerControl id | What it is |
| --- | --- | --- |
| function | `carbonite-fn` | Smoothing: hysteresis (`deviance`) and a response delay, applied only on the way down |
| profile | `carbonite-g-N` | One Graph profile per watched sensor, all with the same curve |
| profile | `carbonite` | The curve: the Graph itself for one sensor, or a Mix taking the **max** of them |
| profile | `carbonite-mN` | The same curve, never below N%, for fans that stall at low duty |

There are also **pins**: a header held at a fixed duty whatever the
temperature, for an AIO pump. The engine stores which fixed duties are its own
pins in its config, so a fixed speed set in the CoolerControl GUI is never
mistaken for one.

CoolerControl saves all of it and re-applies it at boot. The objects show up
in its GUI like any others, and editing them there is fine. `status` reads back
whatever is there now.

## Requirements

- **coolercontrold** running (`sudo systemctl enable --now coolercontrold`).
  It is a host package with a GUI of its own, so the menu reports a missing
  daemon rather than installing one.
- **An access token with write access.** Create it in CoolerControl under
  Settings → Access Tokens, then use *set the access token* in the menu. It is
  saved to `~/.config/carbonite/config` with mode 600.
- `curl` and `jq` for the engine. No `sudo`: CoolerControl does the writing.

## Menu

| Item | Does |
| --- | --- |
| status | The applied curve, hysteresis and delay, the watched temperatures, and every fan with RPM, duty and whether it follows the curve |
| try a curve | Pick a preset or type points, then walk them over a list of temperatures. Touches nothing. |
| apply a curve | Curve and preview, then sensors, which header is the AIO pump (pinned at 100%), which fans follow the curve, which of those stall at low speed (they get a floor), then confirm. A curve that reaches 0% names the fans without a floor that would stop, and asks before letting them (`--allow-stop`) |
| change the curve | Replace just the curve. Sensors and fans stay as they are. |
| list sensors | Every temperature source CoolerControl sees, with its id and reading |
| list fans | Every fan channel CoolerControl can drive, with RPM, duty and curve |
| unpin a fan | Hand a pinned fan back to the board, after a warning in case it is the pump |
| hand back to the board | Put the curve fans back on CoolerControl's Default profile (the BIOS curve) and delete the carbonite objects. Pins are kept. |
| set the access token | Save a CoolerControl token |
| quit | |

## Curves

A curve is a list of `degC:duty%` points with rising temperatures and
non-falling duties, and at least two points. Between points the duty is
**interpolated linearly**, exactly as CoolerControl does it. Below the first
point the fan holds the first duty, and above the last point it holds the last
duty. The temperature is the **hottest** of the watched sensors.

| Preset | Points |
| --- | --- |
| balanced — near-silent at idle, full by 85C | `30:25 50:35 65:55 75:75 85:100` |
| quiet — slow until the 60s, full by 90C | `40:20 60:30 70:50 80:75 90:100` |
| aggressive — airflow early, full by 78C | `30:35 45:50 60:70 70:90 78:100` |

```
$ carbonite.sh simulate --curve "30:25 50:35 65:55 75:75 85:100" 20 57 80 95
20   25%
57   44%
80   88%
95   100%
```

**Hysteresis is one-sided**, as in thermal-exhaust-port: the fans speed up at
once, but slow down only after the temperature has fallen `--hyst` degrees
(default 3) and stayed down for `--delay` seconds (default 3).

A curve CoolerControl would quietly rewrite is refused instead. For example,
CoolerControl raises a falling duty to the one before it. Refusing such a curve
means *try a curve* never shows something different from what will run.

## The pump, and header labels that lie

On the MSI board this was written for, the AIO **pump** is on `CPU_FAN1`
(label "CPU Fan") and the two **radiator fans** are on `PUMP_FAN1` (label
"Pump Fan"). Many AIO manuals tell you to wire it that way. A label is no
guide, so:

- **No fan is ever chosen for you.** The engine's `apply` requires
  `--channels`. The front-end preselects only what is applied already.
- **The pump is asked for by name**, with "no AIO pump here" as an answer for
  air coolers. It is pinned at 100% and written *before* any curve change, so
  if a later step fails, the pump is already safe.
- **Only *unpin a fan* removes a pin.** Re-applying with a different answer,
  or *hand back to the board*, leaves an old pin in place and says so.

With no `--sensors`, the engine watches the CPU package sensor and the GPU core
(`GPU Temp`).

## Floors: fans that stall

Some fans stop below a certain duty and need more than that to start again.
The radiator fans here stopped at 35% and restarted at 40%, so they run with a
45% floor: they follow the same curve but never drop below 45%. The case fans
on the plain curve can go down to its first point. In the engine this is
`--channels "ID@45"`, which produces a `carbonite-m45` profile set. To find a
fan's floor, look for the lowest duty that starts it from a standstill, then
add a margin.

*apply a curve* is the whole list: a fan that was on the curve and is left out
goes back to the board.

## Ids

Sensors and fans are named `<first 8 of the device uid>:<name>`, for example
`7bfee7e1:fan3` or `e5345c5f:GPU_Temp`. Spaces become `_`, so a list of ids can
be space-separated. CoolerControl's device uids are stable across reboots,
unlike hwmon indices.

## A fan that does not slow down

If *list fans* shows a channel following the curve at a low duty but its RPM
does not move, the fan is ignoring PWM. This is almost always a 3-pin (DC) fan,
a hub, or a pump on a header set to PWM mode. The NCT6687 driver does not
expose the header mode, so change it in the BIOS: Hardware Monitor → that header
→ DC instead of PWM.

## When something else drives the fans

Any other service writing `pwm` fights CoolerControl. The engine's `conflicts`
command checks `fancontrol`, `fan2go`, `thermal-exhaust-port` and `nbfc`,
whether active or enabled at boot. `apply` and `status` mention them, and the
front-end warns at startup.

## Tests

The engine's `tests/test-engine.sh` runs it against a curl stand-in that
behaves like a small, stateful CoolerControl 4.3.1. The fixture is this board,
with its misleading labels. The tests cover the interpolation; curve and spec
validation; no fan chosen without `--channels`; the pin written before any
profile; floored profile sets; `set-curve` carrying the floors; `apply` as the
whole list, with dropped fans going back to the board and profiles pruned only
once unused; a GUI-set fixed duty not mistaken for a pin; `release` keeping
pins; and token and daemon errors.

`tests/test-carbonite.sh` here drives the front-end through the gum stub against
the real engine and that same fake daemon. It checks that the picked curve,
sensors and fans reach `apply`, that declining, Esc or a bad floor writes nothing, that the pump answer
becomes `--pin …@100` and is not offered again for the curve, that an air
cooler gets no pin, that an old pin left out stays pinned, and that *change
the curve* uses `set-curve`.
