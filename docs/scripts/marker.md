# Marker (Document -> Markdown / JSON)

`marker/marker.sh`

Manage [datalab-to/marker](https://github.com/datalab-to/marker) and convert documents **into** Markdown, JSON, HTML, or chunks, the inverse of [`holo-convert`](holo-convert.md). \
The output is intended as a first step toward LLM ingestion (chunking/embedding is **not** done here).

**Supported inputs:** PDF, DOCX, PPTX, XLSX, HTML, EPUB, and images (PNG/JPG/TIFF/…).

**Output formats:** `markdown`, `json`, `html`, `chunks`.

## Isolation (pipx)

marker pulls in PyTorch and downloads several GB of models on first run, so it is installed in an **isolated pipx environment**, it never touches system Python.

- Requires a **Python 3.10–3.13** and **pipx** (the script offers to install pipx if missing).
  marker/PyTorch do **not** support Python 3.14 yet, so the script auto-selects a supported
  interpreter (preferring 3.12) with a working `venv`. it does **not** use the system
  default `python3` if that's too new.
- Install command used: `PIPX_DEFAULT_PYTHON=<py3.12> pipx install --python <py3.12> "marker-pdf[full]"`,
  pinning the interpreter for both pipx's shared venv and marker's app venv. The `[full]`
  extra enables the non-PDF input formats.
- The four marker CLIs (`marker_single`, `marker`, `marker_gui`, `marker_server`) are
  resolved from `PATH`, falling back to the pipx venv directly if `PATH` isn't sourced yet.
- Some marker features need packages `marker-pdf[full]` doesn't pull; the script injects
  them into the venv on demand (via `pipx inject`), only when you use the feature:
  **psutil** (batch converter, injected at setup), **streamlit** (GUI), and
  **fastapi/uvicorn/python-multipart** (API server). The GUI/server also launch with the
  venv's bin on `PATH` so their `streamlit`/`uvicorn` subprocesses resolve.
- Language is auto-detected by marker's OCR, so there's no language option.
- **OCR backend (`llama-server`)**: marker's OCR engine (surya) no longer runs on plain
  PyTorch — it serves its recognition model through an inference backend chosen by
  hardware: **vLLM** on an NVIDIA GPU, else **llama.cpp** (macOS / CPU), which needs the
  `llama-server` binary. Without it, conversions crash the moment OCR runs. **Setup**
  offers to `brew install llama.cpp` (Linux: Homebrew or a downloaded build +
  `LLAMA_CPP_BINARY`), **Status** reports the backend and whether `llama-server` is found,
  and every convert path checks it first. Override the choice with
  `SURYA_INFERENCE_BACKEND`, or point at an out-of-`PATH` binary with `LLAMA_CPP_BINARY`.

## Menu

The top level has three entries:

- **Convert documents** - single file or batch folder -> pick output format, output dir, options (local pipx).
- **Local tool** - submenu for the local pipx install:

  | Action                    | What it does                                                                                 |
  | ------------------------- | -------------------------------------------------------------------------------------------- |
  | Setup / install / upgrade | Check Python, install pipx if needed, install/upgrade marker, install `llama-server` (OCR backend) |
  | Status                    | Version, CLIs-on-`PATH`, Torch device (CPU/MPS/CUDA), OCR backend + `llama-server`, model-cache size, optional cache clear |
  | Launch GUI (Streamlit)    | Runs `marker_gui` for interactive testing                                                    |
  | Launch API server         | Runs `marker_server` (FastAPI), single local process                                         |
  | Uninstall                 | Removes marker's pipx env (model caches kept)                                                |

- **Deploy as a service (Docker / K8s)** is the scalable ingestion deployment (see below).

## Choosing the source

Convert first asks **how** to pick the source:

- **Detect files (scan this folder)** - scans the current folder tree (depth 3) for
  supported files and lets you pick one -> single-file conversion.
- **Enter a path (file or folder)** - type a path (a leading `~` is expanded). If it's a
  **file** -> single-file conversion; if it's a **folder** -> batch conversion of every
  supported file inside.

## Conversion options

- **Output format** - `markdown` / `json` / `html` / `chunks`
- **Output directory** - default `./marker-output`
- **Force OCR** (`--force_ocr`) - re-OCR the whole document (fixes bad embedded text)
- **Use an LLM** (`--use_llm`) - higher quality; pick a service:
  Google Gemini, OpenAI / OpenAI-compatible, Anthropic Claude, or Ollama (local). API keys
  are read from the environment when present (`GEMINI_API_KEY`, `OPENAI_API_KEY`,
  `ANTHROPIC_API_KEY`) or prompted for (hidden input). The **OpenAI / OpenAI-compatible**
  option also asks for a **base URL**, so it can target a local/LAN server (see below).
- **Page range** (`--page_range`, single-file only) - e.g. `0,5-10,20`
- **Workers** (`--workers`, batch only) - parallel processes (~3.5 GB RAM/VRAM each)

## Local / LAN LLM

You can point `--use_llm` at a model on your own machine or LAN instead of a cloud
API, keeping documents on your network and removing the WAN round-trip. Two routes:

- **Ollama** - pick **Ollama (local)**, set the base URL (default
  `http://localhost:11434`, or a LAN host) and a model.
- **OpenAI-compatible servers** (LM Studio, LocalAI, vLLM, llama.cpp `server`) - pick
  **OpenAI / OpenAI-compatible**, set the **base URL** to the server (e.g. LM Studio's
  `http://192.168.1.50:1234/v1`), name the loaded model, and pass any non-empty API key
  (local servers usually ignore it).

Things to keep in mind:

- **Must be a vision model** - marker sends image crops of blocks, so the model has to
  accept images (e.g. `llama3.2-vision`, `qwen2-vl`, `minicpm-v`, `llava`, or a vision
  build loaded in LM Studio). A text-only model will fail or return garbage.
- **Speed is GPU-bound, not network-bound** - on a LAN the transport latency is
  negligible; what costs time is the model's inference per block. A strong GPU on the
  LLM host keeps the overhead small; a weak GPU or CPU can be *slower* than a cloud API.
- **Quality varies** - local open models generally handle complex tables/forms less well
  than frontier cloud models. Worth a side-by-side on one hard page before committing.
- **Give the LLM its own host** - running it on the same machine as marker makes the two
  contend for the same GPU. A separate LAN GPU box lets marker's layout/OCR models and
  the LLM each run unimpeded. If you later scale the [service](#deploy-as-a-service-for-rag-ingestion)
  to many workers against one LLM host, that host is the throughput ceiling (inference
  serializes) - scale it too, not just the workers.

## Deploy as a service (for RAG ingestion)

The **Deploy as a service** menu deploys marker as a scalable, containerized
ingestion service, the right shape for feeding a RAG pipeline (conversion is an
offline/async indexing step, decoupled from your RAG query service). Templates
live in [`scripts/marker/templates/service/`](../../scripts/marker/templates/service/).

**Architecture** (one system; HTTP, batch, and replicas are just producers/knobs
around a queue + workers):

```
HTTP enqueue API ─┐
batch enqueuer  ──┴─▶ Redis queue ─▶ worker × N (marker, models loaded once) ─▶ output (volume/PVC) ─▶ embed/index
```

- **Redis** - the job queue (RQ).
- **worker** - pulls jobs, converts via marker's Python API, writes output. **Replicas = your scale.** Each worker loads models once and reuses them (far faster than looping the CLI). Runs as an RQ `SimpleWorker` (no fork) so models/GPU context are reused safely.
- **enqueue API** (FastAPI) - `POST /jobs {path, output_format, …}` -> job id; `GET /jobs/{id}` -> status.
- **batch enqueuer** - walks a folder and enqueues one job per file (the "convert a whole folder in one shot" path); workers process in parallel.

**Menu actions** (after choosing Docker or K8s): Build image · Deploy/update ·
Status · Logs · Scale workers · Ingest a folder (batch) · Tear down.

**Targets:**

- **Docker** - `docker compose` stack (Redis + API + N workers). Put docs in the
  mounted input folder; results in the output folder. CPU-only on macOS (no CUDA).
- **Kubernetes** - `namespace` + PVCs (model cache / input / output) + Redis +
  worker `Deployment` (replicas, GPU-ready) + API `Deployment`/`Service` + a batch `Job`.

**Caveats:**

- The image uses the default (CUDA) torch, runs on CPU, uses the GPU automatically on
  NVIDIA-runtime hosts / K8s GPU nodes (uncomment the GPU bits in `worker.yaml` / compose).
- Models download on first run into a shared `/models` volume/PVC (K8s: `ReadWriteMany`
  so replicas share it, needs an RWX StorageClass).
- The image is **not** built here (it's multi-GB); **Build image** runs `docker build`, and
  for K8s you must push/`kind load` it to the cluster.
- The `marker.sh` TUI is a management convenience; production RAG would call the API /
  Python worker directly.

## Model downloads (Hugging Face) & offline use

marker runs inference **locally**, but the model weights are **not bundled** — on
first use they download from the **Hugging Face Hub** (the surya/marker models plus
the `surya-2` GGUFs for the llama.cpp OCR backend) into `~/.cache/huggingface`, with
a little metadata under `~/.cache/datalab`. So a **connected first run is required**;
after that it runs from cache.

- **No TTL.** The caches never expire — they're kept and reused indefinitely. A
  re-download only happens if the upstream model **revision** changes.
- **The recurring `unauthenticated requests to the HF Hub` warning** isn't a
  re-download: `huggingface_hub` pings the Hub on every load to check the cached
  files are current (an ETag check). Set **`HF_TOKEN`** (free HF account → read token)
  to authenticate that check — silences the warning and raises rate limits.
- **Offline mode (automatic once cached).** When the model cache is populated, the
  convert paths set **`HF_HUB_OFFLINE=1`** for you: `huggingface_hub` uses the cache
  exclusively and skips the per-run Hub check — **no network round-trip, no warning,
  faster startup.** Override with **`MARKER_HF_ONLINE=1`** to force update checks; an
  explicit `HF_HUB_OFFLINE` in your environment always wins. **Status** shows the mode
  the next conversion will use.
- **Air-gapped**: pre-populate `~/.cache/huggingface` (and `~/.cache/datalab`) on a
  connected machine, copy them over, and marker runs fully offline.

## Notes

- First conversion downloads models; subsequent runs are faster and offline (above).
- Set `TORCH_DEVICE` (e.g. `cuda`, `mps`, `cpu`) to override the detected device.
- Model caches live under `~/.cache/datalab` (and `~/.cache/huggingface`); the **Status**
  action reports their size and can clear the datalab cache.
