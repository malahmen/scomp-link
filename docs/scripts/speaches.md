# Speaches

`speaches/speaches.sh`

Installs and manages [Speaches](https://speaches.ai), a ready-made speech server with an OpenAI-compatible API: speech-to-text (`/v1/audio/transcriptions`, faster-whisper) and text-to-speech (`/v1/audio/speech`, Kokoro and Piper). Each request names its model, so several sit side by side and are compared by changing `model` - the way LM Studio serves text models.

- **Targets**: **Podman** - rootless, a Quadlet unit under the user's systemd with lingering, so it starts at boot without a login (Linux only; podman is installed if missing) · **Docker** - a container with `--restart unless-stopped` · **kind / K8s** - plain manifests through `kubectl` (Speaches has no Helm chart). A cluster managed by Argo CD should get an Application in its GitOps repository instead; the K8s target says so.
- **Image**: `ghcr.io/speaches-ai/speaches:<version>-<cpu|cuda>`, pinned to `0.8.3` (latest stable; `0.9.0` is a release candidate). `auto` picks CUDA only when `nvidia-smi` sees a GPU.
- **Default models**, downloaded by `install` through Speaches' own API (`POST /v1/models/{id}`), only those missing: `deepdml/faster-whisper-large-v3-turbo-ct2` (speech-to-text), `speaches-ai/Kokoro-82M-v1.0-ONNX` and `speaches-ai/piper-en_US-lessac-medium` (text-to-speech, English voices).
- **Idle time**: seconds an unused model stays loaded (default 300; `-1` never unloads). Set for both 0.8 (`WHISPER__TTL`) and 0.9 (`STT_MODEL_TTL`, `TTS_MODEL_TTL`); each version ignores the names it doesn't know.
- **Firewall**: `install` offers to open the port in firewalld or ufw (sudo) so the LAN can reach it; `status` reports open / closed / unknown.
- **The defaults are the deployment**: re-running `install` on a rebuilt host has to bring back the same service, so a lasting change belongs in the script's defaults, not only in the settings file.
- Model cache: named volume `speaches-hf-cache` (a PVC on K8s); `uninstall` keeps it unless you confirm.
- Config: `~/.config/speaches-tui/speaches.conf`
- Commands: `install`, `status` (health, LAN URL, installed and loaded models, missing defaults, firewall, lingering), `models` (list, download, remove, download the defaults), `test` (Kokoro speaks a sentence, Whisper transcribes it back), `bench` (how fast, below), `logs`, `config`, `uninstall`; K8s adds `port-forward`

## Bench

`bench` measures what `test` cannot: speed on this host.

- **Speech to text**: each recording in a folder (default `~/speaches-bench-audio`; wav, mp3, flac, ogg, opus or m4a - ideally real speech of about 1, 5 and 30 minutes) is transcribed several times warm, and the median reported as the **real-time factor**: processing seconds per second of audio, so under 1 is faster than real time. The audio's length is Speaches' own (`verbose_json`), so no ffprobe is needed.
- **Load**: Whisper is unloaded (`DELETE /api/ps/...`) and the smallest recording run cold; the load is cold minus that recording's warm median - what the first request after `idle time` pays.
- **Text to speech**: Kokoro and Piper read a fixed paragraph; reported as seconds of audio made per second (above 1 can stream). Speaches 0.8.3 cannot unload them, so their load is not measured; an untimed first request keeps it out of the warm runs.
- **Conditions**: the CPU count, the load and anything running under Wine are recorded, and a host that is not idle is named and benched only if you confirm - a game beside the first marker bench made it 1.12x slow.

Writes `~/speaches-bench-<host>-<date>.json` (schema `scomp-link/speaches-bench/1`) and, beside it, every transcript, to read against the recordings for accuracy.
