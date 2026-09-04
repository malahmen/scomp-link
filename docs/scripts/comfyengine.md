# ComfyEngine

`comfyengine/comfyengine.sh`

Builds and installs [ComfyEngine](https://github.com/kashithecomfy/ComfyEngine) (a **Linux-only**, Qt 6 memory scanner) from source with CMake, adding a desktop shortcut. Build dependencies — `git`, `cmake`, `make`, `g++`, **Qt 6 (Widgets)** and **Capstone** — are checked/installed automatically (dnf/apt). Commands: `install`, `uninstall`, `status`. On non-Linux hosts it exits early (the tool is Qt 6 + ptrace, Linux-first).

Upstream defines **no CMake `install()` rule**, so after building, the script copies the produced binaries into `/usr/local/bin` itself: the main `comfyengine` (from `build/src/`) and, best-effort, its `ce_watch` runtime helper (from `build/ce_watch/`). `uninstall` removes both, the source checkout, and the shortcut; `status` reports both binaries.
