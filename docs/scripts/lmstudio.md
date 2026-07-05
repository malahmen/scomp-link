# LM Studio Manager

`lmstudio/lmstudio.sh`

Installs and manages [LM Studio](https://lmstudio.ai) (Flatpak) so the `lms` CLI works out of the box, with optional headless operation.

- **Sandbox override**: proactively applies `flatpak override --user --filesystem=home ai.lmstudio.lm-studio` before first launch, prevents an "Invalid passkey for lms CLI client" bug caused by LM Studio's identity/passkey files resolving to a different sandboxed `~/.lmstudio` than the rest of its state
- **CLI bootstrap**: launches LM Studio against a throwaway headless Xvfb display so the `lms` CLI gets bootstrapped without needing a real desktop session
- **Headless service** (`service-enable`): sets up a persistent Xvfb + `systemd --user` service pair so LM Studio can run headless and start at boot without anyone logged in (via `loginctl` linger)
- Commands: `install`, `service-enable`, `service-disable`, `status`, `uninstall`
