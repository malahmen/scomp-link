# Bazzite Utils

`bazzite-utils/bazzite-utils.sh`

EA App staged-update fix + Ubisoft Connect offscreen-window fix + KDE greeter refresh-rate fix. A grab-bag of gaming-on-Linux workaround utilities, named after [Bazzite](https://bazzite.gg/) (the primary target) but works on any dnf/apt/rpm-ostree host.

- **`ea-fix`**: copies EA App's staged self-update into place under Wine/Proton (EA's own updater frequently stages an update it never applies). The saved Wine/Proton prefix is offered each run (`Use saved EA prefix…`) and re-prompted on decline; it's persisted in `~/.config/bazzite-utils/bazzite-utils.conf` (default `~/Games/ea-app`).
- **`ubisoft-rws`**: finds Ubisoft Connect windows that render off-screen or invisible under Wine/Proton and repositions/raises them.
- `ubisoft-rws` auto-installs `xwininfo`/`wmctrl`/`xdotool` via the shared package helpers (dnf/apt/rpm-ostree), warns on Wayland (these X11 tools only see XWayland windows), moves any window detected offscreen (x/y > 5000 or < -100) to 100,100 and raises the rest, then offers to terminate the `UbisoftConnect.exe` processes (automatically, or after you close them yourself).
- **`kwin-greeter-fix`**: copies your KWin output config (`~/.config/kwinoutputconfig.json` — monitor refresh rates, positions, layout) to the KDE login-screen account (`plasmalogin`, or `sddm` on older setups, detected from the active `display-manager.service`). The greeter runs as its own user with its own config, so a refresh-rate fix saved in your session never reaches the login screen, which falls back to the monitor's EDID-advertised max mode (blank/no-signal screens at boot). Needs `sudo`; re-run after changing monitors, cables, or resolutions, since the config is matched by monitor EDID.
- Commands: `ea-fix`, `ubisoft-rws`, `kwin-greeter-fix`
