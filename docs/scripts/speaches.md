# Speaches

`speaches/speaches.sh`

Installs and manages [Speaches](https://speaches.ai), a ready-made speech server with an OpenAI-compatible API: speech-to-text (`/v1/audio/transcriptions`, faster-whisper) and text-to-speech (`/v1/audio/speech`, Kokoro and Piper). Each request names its model, so several sit side by side and are compared by changing `model` - the way LM Studio serves text models.

- **Targets**: **Podman** - rootless, a Quadlet unit under the user's systemd with lingering, so it starts at boot without a login (Linux only; podman is installed if missing) · **Docker** - a container with `--restart unless-stopped` · **kind / K8s** - plain manifests through `kubectl` (Speaches has no Helm chart). A cluster managed by Argo CD should get an Application in its GitOps repository instead; the K8s target says so.
- **Image**: `ghcr.io/speaches-ai/speaches:<version>-<cpu|cuda>`, pinned to `0.8.3` (latest stable; `0.9.0` is a release candidate). `auto` picks CUDA only when `nvidia-smi` sees a GPU.
- **Default models**, downloaded by `install` through Speaches' own API (`POST /v1/models/{id}`), only those missing: `deepdml/faster-whisper-large-v3-turbo-ct2` (speech-to-text), `speaches-ai/Kokoro-82M-v1.0-ONNX` and `speaches-ai/piper-en_US-lessac-medium` (text-to-speech, English voices).
- **Whisper on CPU**: `cpu threads` (default **16**) and `compute type` (default **`int8`**), as `WHISPER__CPU_THREADS` and `WHISPER__COMPUTE_TYPE` - corelia's, measured with `bench` (32 CPUs, large-v3-turbo):

  | Setting | 4.5 s command | 70 s poem |
  | --- | --- | --- |
  | Speaches' own (`0`, `default`) | 7.7 s | 18.0 s |
  | 16 threads | 4.7 s | 10.4 s |
  | 32 threads | 5.2 s | 13.3 s |
  | **16 threads, `int8`** | **3.0 s** | **6.6 s** |

  32 threads lose to 16: likely 16 cores with two threads each, where the extra threads only contend. `int8` kept the words (the command exactly; the poem but one homophone). On another host, bench it and set these in `config`; `0` and `default` give Speaches' own.
- **Idle time**: seconds an unused model stays loaded (default 300; `-1` never unloads). Set for both 0.8 (`WHISPER__TTL`) and 0.9 (`STT_MODEL_TTL`, `TTS_MODEL_TTL`); each version ignores the names it doesn't know.
- **Firewall**: `install` offers to open the port in firewalld or ufw (sudo) so the LAN can reach it; `status` reports open / closed / unknown.
- **The defaults are the deployment**: re-running `install` on a rebuilt host has to bring back the same service, so a lasting change belongs in the script's defaults, not only in the settings file.
- Model cache: named volume `speaches-hf-cache` (a PVC on K8s); `uninstall` keeps it unless you confirm.
- Config: `~/.config/speaches-tui/speaches.conf`
- Commands: `install`, `status` (health, LAN URL, installed and loaded models, missing defaults, firewall, lingering), `models` (list, download, remove, download the defaults), `test` (Kokoro speaks a sentence, Whisper transcribes it back), `bench` (how fast, below), `logs`, `config`, `uninstall`; K8s adds `port-forward`

## Bench

`bench` measures what `test` cannot: speed on this host. Recordings may have any name (a `,` or `;` in it used to fail every run), and are found on macOS too.

- **Speech to text**: each recording in a folder (default `~/speaches-bench-audio`; wav, mp3, flac, ogg, opus or m4a - ideally real speech of about 1, 5 and 30 minutes) is transcribed several times warm, and the median reported as the **real-time factor**: processing seconds per second of audio, so under 1 is faster than real time. The audio's length is Speaches' own (`verbose_json`), so no ffprobe is needed.
- **A short command**: Kokoro speaks a one-sentence command first (about 5 s, the length Padme mostly hears), and it is timed like a recording - no recording that short, and no ffmpeg, needed. The report gives what was said beside its transcript.
- **Load**: when Whisper is not loaded (absent from `/api/ps` - after a restart, or `idle time` seconds unused), the smallest file, the spoken command, runs cold; the load is cold minus its warm median - the wait for the first command after `idle time`. Bench never unloads a model to get there: on corelia, unloading a loaded Whisper through `DELETE /api/ps` froze Speaches 0.8.3 - `/health` still answered, every transcription waited until a restart. With Whisper already loaded, the load is left unmeasured and the report says why; restart Speaches and bench before anything else to measure it.
- **Text to speech**: Kokoro and Piper read a fixed paragraph; reported as seconds of audio made per second (above 1 can stream). Speaches 0.8.3 cannot unload them, so their load is not measured; an untimed first request keeps it out of the warm runs.
- **Which Whisper**: bench asks which model to time (default: the turbo model), downloads it if needed, and records it with the thread count and compute type speaches.sh has configured - so a smaller model, or another setting, is compared run against run. Those are the settings as configured: change them in `config` and re-apply before benching them.
- **Conditions**: the CPU count, the load and anything running under Wine are recorded, and a host that is not idle is named and benched only if you confirm - a game beside the first marker bench made it 1.12x slow.

Writes `~/speaches-bench-<host>-<date>.json` (schema `scomp-link/speaches-bench/1`) and, beside it, every transcript, to read against the recordings for accuracy.
