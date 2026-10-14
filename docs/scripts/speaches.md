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
- Commands: `install`, `status` (health, LAN URL, installed and loaded models, missing defaults, firewall, lingering), `models` (list, download, remove, download the defaults), `test` (Kokoro speaks a sentence, Whisper transcribes it back), `logs`, `config`, `uninstall`; K8s adds `port-forward`
