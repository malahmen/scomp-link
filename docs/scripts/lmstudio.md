# LM Studio Manager

`lmstudio/lmstudio.sh`

Installs and manages [LM Studio](https://lmstudio.ai) (Flatpak) so the `lms` CLI works out of the box, with optional headless operation. Linux only (Flatpak + `systemd --user`).

- **Install scope**: `user` or `system` Flatpak install (system needs sudo); `install` offers to run `service-enable` inline at the end
- **Sandbox override**: proactively applies `flatpak override --user --filesystem=home ai.lmstudio.lm-studio` before first launch, prevents an "Invalid passkey for lms CLI client" bug caused by LM Studio's identity/passkey files resolving to a different sandboxed `~/.lmstudio` than the rest of its state
- **CLI bootstrap**: launches LM Studio against a throwaway headless Xvfb display so the `lms` CLI gets bootstrapped without needing a real desktop session
- **`fix-rocm`**: on hosts with a ROCm-capable AMD GPU (`/dev/kfd` present), grants the sandbox `--device=all` so the bundled ROCm llama.cpp backend can see the GPU, then offers to restart LM Studio; no-op when no such GPU is detected or the fix is already applied
- **Headless service** (`service-enable`): sets up a persistent Xvfb + `systemd --user` service pair so LM Studio can run headless and start at boot without anyone logged in (via `loginctl` linger). `service-disable` stops and disables the units but leaves the unit files under `~/.config/systemd/user`.
- **`status`**: install state, sandbox overrides (including ROCm fix applied / not), service state and `lms status`
- **`uninstall`**: removes the Flatpak and service units, then offers to delete `~/.lmstudio` (models and data)
- Config: `~/.config/lmstudio-tui/lmstudio.conf`
- Commands: `install`, `status`, `fix-rocm`, `service-enable`, `service-disable`, `uninstall`
