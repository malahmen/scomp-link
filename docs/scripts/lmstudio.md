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
- Commands: `install`, `status`, `bench` (how fast, below), `fix-rocm`, `service-enable`, `service-disable`, `uninstall`

## bench

How fast each local model runs on this host, through LM Studio's own server (default `http://127.0.0.1:1234`, or `SCOMP_LMSTUDIO_URL`):

- **Generation**, in tokens per second: the median of several runs (default 3) of a 300-token answer, after an untimed warm-up. On a unified-memory APU this is set by memory bandwidth.
- **Prefill**, in prompt tokens per second: prompt tokens / time to first token, at RAG-sized prompts (default about 4,000 and 16,000 tokens). This is what a long retrieved context waits on. The prompt text is generated, since prefill speed does not depend on it; `SCOMP_LMSTUDIO_BENCH_TEXT` names a file to use instead. Every prompt starts with a unique tag, so no cached prefix is reused.
- **One model at a time**, loaded at the context asked for (default 32768) and fully on the GPU, after unloading everything; none is left loaded. Models already loaded are named first, and unloaded only if confirmed. A model that fails to load is recorded with the reason, and the rest still bench.
- **Bandwidth actually used**: for a dense model every weight is read once per token, so size x generation rate is the bandwidth it got (`gb_per_second_if_dense`). An MoE reads only its active experts, so for one that figure is not a bandwidth; the report gives each model's parameters as `lms ls` has them (`30B-A3B`: 3B active).
- **A busy host** (load above an eighth of the CPUs, or anything running under Wine) is said so and benches only if confirmed; the conditions go into the report.
- **Report**: `~/lmstudio-bench-<host>-<date>.json` (or `SCOMP_LMSTUDIO_BENCH_OUT`), schema `scomp-link/lmstudio-bench/1`: load time, generation and prefill medians with their runs, GTT in use, size and parameters, per model.

`lms` is found in `~/.lmstudio` when `install` granted the sandbox the home folder, or else in the Flatpak's own copy (`~/.var/app/ai.lmstudio.lm-studio/.lmstudio`), which only finds its key with `HOME` pointed there.
