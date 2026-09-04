# GameConqueror

`gameconqueror/gameconqueror.sh`

Builds and installs [GameConqueror/scanmem](https://github.com/scanmem/scanmem) (a **Linux-only**, GTK memory scanner) from source with autotools, adding a desktop shortcut. Same dependency-checking pattern as ComfyEngine. Commands: `install`, `uninstall`, `status`. On non-Linux hosts it exits early (the tool is ptrace + GTK, Linux-first).

Build dependencies checked/installed automatically (dnf/apt): `git`, `make`, `gcc`, `autoconf`, `automake`, `libtool`, `intltool`, `pkg-config`, `python3`, and readline headers. The GTK front-end's runtime deps — **PyGObject**, **GTK 3**, and **polkit** — are installed too, so the built `/usr/bin/gameconqueror` launches. `uninstall` prefers `make uninstall` from the build tree (falls back to removing the known paths).
