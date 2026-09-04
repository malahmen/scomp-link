# protocol-droid (Documents -> Markdown / JSON)

`protocol-droid/protocol-droid.sh`

> "I am fluent in over six million forms of communication."

A gum front-end for **[protocol-droid](https://github.com/malahmen/protocol-droid)**,
a standalone, gum-free engine that drives
[datalab-to/marker](https://github.com/datalab-to/marker) to convert documents
**into** Markdown, JSON, HTML, or chunks — the inverse of
[`holo-convert`](holo-convert.md). scomp-link ships only the front-end; the logic
(and the marker dependency) lives in the engine's own repo — the same split as
[holo-convert](holo-convert.md), [navicomputer](navicomputer.md), and
[mind-trick](mind-trick.md).

The output is a first step toward LLM ingestion — protocol-droid **prepares**
documents; chunking/embedding/indexing is **not** done here.

**Supported inputs:** PDF, DOCX, PPTX, XLSX, HTML, EPUB, and images (PNG/JPG/TIFF/…). \
**Output formats:** `markdown`, `json`, `html`, `chunks`.

## Engine resolution

The front-end finds `protocol-droid.sh` automatically, in order:

1. `$PROTOCOL_DROID_DIR/protocol-droid.sh` (explicit override)
2. `../../../protocol-droid/protocol-droid.sh` (a local sibling checkout)
3. `~/.cache/scomp-link/protocol-droid/` (a cached clone; offers `git pull`)
4. a fresh `git clone --depth 1` from the public repo

## Two modes

The engine (and this menu) work in two modes:

- **local** — run marker on this machine, isolated in a pipx environment.
- **service** — deploy a scalable containerized service (Redis queue + enqueue
  API + marker workers) via Docker or Kubernetes.

## Menu

The top level has three entries:

- **Convert documents** — single file or a folder → pick output format, output
  dir, options; drives `protocol-droid local convert` (local pipx).
- **Local tool** — submenu for the local pipx install:

  | Action                    | What it does                                                                                 |
  | ------------------------- | -------------------------------------------------------------------------------------------- |
  | Setup / install           | Check Python, install pipx if needed, install marker, install `llama-server` (OCR backend) |
  | Upgrade                   | `protocol-droid local setup --upgrade`                                                        |
  | Status                    | Version, CLIs-on-`PATH`, Torch device (CPU/MPS/CUDA), OCR backend + `llama-server`, model-cache sizes |
  | Launch GUI (Streamlit)    | Runs marker's `marker_gui` for interactive testing                                            |
  | Launch API server         | Runs marker's `marker_server` (FastAPI), single local process                                |
  | Clear model cache         | Deletes `~/.cache/datalab` (models re-download next run)                                      |
  | Uninstall                 | Removes marker's pipx env (model caches kept)                                                 |

- **Deploy as a service (Docker / K8s)** — the scalable deployment (see below).

## Isolation (pipx)

marker pulls in PyTorch and downloads several GB of models on first run, so the
engine installs it in an **isolated pipx environment**; it never touches system
Python.

- Requires **Python 3.10–3.13** and **pipx** (the engine installs pipx during
  `setup` if missing). marker/PyTorch do **not** support Python 3.14 yet, so the
  engine auto-selects a supported interpreter (preferring 3.12) with a working
  `venv`; it does **not** use a too-new default `python3`.
- Install command used: `PIPX_DEFAULT_PYTHON=<py3.12> pipx install --python <py3.12> "marker-pdf[full]"`.
  The `[full]` extra enables the non-PDF input formats.
- The four marker CLIs (`marker_single`, `marker`, `marker_gui`, `marker_server`)
  are resolved from `PATH`, falling back to the pipx venv directly if `PATH`
  isn't sourced yet.
- Some features need packages `marker-pdf[full]` doesn't pull; the engine injects
  them on demand (`pipx inject`): **psutil** (batch converter), **streamlit**
  (GUI), and **fastapi/uvicorn/python-multipart** (API server).
- Language is auto-detected by marker's OCR, so there's no language option.
- **OCR backend (`llama-server`)**: marker's OCR engine (surya) no longer runs on
  plain PyTorch — it serves its recognition model through an inference backend
  chosen by hardware: **vLLM** on an NVIDIA GPU, else **llama.cpp** (macOS / CPU),
  which needs the `llama-server` binary. Without it, conversions crash the moment
  OCR runs. **Setup** installs it (macOS: `brew install llama.cpp`), **Status**
  reports the backend and whether `llama-server` is found, and every convert path
  checks it first. Override with `SURYA_INFERENCE_BACKEND`, or point at an
  out-of-`PATH` binary with `LLAMA_CPP_BINARY`.

## Choosing the source (Convert)

Convert first asks **how** to pick the source:

- **Scan a folder → pick files** — the engine scans the folder tree (depth 3) for
  supported files (`protocol-droid local scan`) and you multi-select 1..N.
- **Enter a path (file or folder)** — a leading `~` is expanded. A **file** →
  single-file conversion; a **folder** → scan + multi-select.

One file → marker's single CLI; several files (or a whole folder) → marker's
batch CLI, which loads its models once (a selection is symlinked into a temp dir
first).

## Conversion options

- **Output format** — `markdown` / `json` / `html` / `chunks`
- **Output directory** — default `./marker-output`
- **Force OCR** (`--force_ocr`) — re-OCR the whole document (fixes bad embedded text)
- **Use an LLM** (`--use_llm`) — higher quality; pick a service: Google Gemini,
  OpenAI / OpenAI-compatible, Anthropic Claude, or Ollama (local). API keys are
  read from the environment when present (`GEMINI_API_KEY`, `OPENAI_API_KEY`,
  `ANTHROPIC_API_KEY`) or prompted for (hidden input). **OpenAI / OpenAI-compatible**
  also asks for a **base URL**, so it can target a local/LAN server (see below).
- **Page range** (`--page_range`, single-file only) — e.g. `0,5-10,20`
- **Workers** (`--workers`, batch only) — parallel processes (~3.5 GB RAM/VRAM each)

The front-end builds these into flags; anything marker-specific (force OCR, LLM
service + keys) is forwarded to the engine after a `--` separator.

## Local / LAN LLM

You can point `--use_llm` at a model on your own machine or LAN instead of a
cloud API, keeping documents on your network. Two routes:

- **Ollama** — pick **Ollama (local)**, set the base URL (default
  `http://localhost:11434`, or a LAN host) and a model.
- **OpenAI-compatible servers** (LM Studio, LocalAI, vLLM, llama.cpp `server`) —
  pick **OpenAI / OpenAI-compatible**, set the **base URL** (e.g. LM Studio's
  `http://192.168.1.50:1234/v1`), name the loaded model, and pass any non-empty
  API key (local servers usually ignore it).

Things to keep in mind:

- **Must be a vision model** — marker sends image crops of blocks, so the model
  has to accept images (`llama3.2-vision`, `qwen2-vl`, `minicpm-v`, `llava`, …).
- **Speed is GPU-bound, not network-bound** — on a LAN the transport latency is
  negligible; what costs time is inference per block.
- **Quality varies** — local open models generally handle complex tables/forms
  less well than frontier cloud models.
- **Give the LLM its own host** — running it on the same machine as marker makes
  the two contend for the GPU. If you later scale the [service](#deploy-as-a-service-for-rag-ingestion)
  to many workers against one LLM host, that host is the throughput ceiling —
  scale it too, not just the workers.

## Deploy as a service (for RAG ingestion)

The **Deploy as a service** menu deploys a scalable, containerized **conversion
service** — the right shape for feeding a RAG pipeline (conversion is an
offline/async step that *prepares* documents, decoupled from your RAG query
service; chunking/embedding/indexing happens downstream, not here). Each menu
action maps to a `protocol-droid service <command> --target docker|k8s` call.

**Architecture** (HTTP, batch, and replicas are producers/knobs around a queue +
workers):

```
HTTP enqueue API ─┐
batch enqueuer  ──┴─▶ Redis queue ─▶ worker × N (marker, models loaded once) ─▶ output (volume/PVC) ─▶ embed/index
```

- **Redis** — the job queue (RQ).
- **worker** — pulls jobs, converts via marker's Python API, writes output.
  **Replicas = your scale.** Each worker loads models once (far faster than
  looping the CLI). Runs as an RQ `SimpleWorker` (no fork) so models/GPU context
  are reused safely.
- **enqueue API** (FastAPI) — `POST /jobs {path, output_format, …}` → job id;
  `GET /jobs/{id}` → status.
- **batch enqueuer** — walks a folder and enqueues one job per file; workers
  process in parallel.

**Menu actions** (after choosing Docker or K8s): Build image · Deploy/update ·
Status · Logs · Scale workers · Enqueue a folder (batch) · Tear down.

**Targets:**

- **Docker** — `docker compose` stack (Redis + API + N workers). Put docs in the
  mounted input folder; results in the output folder. CPU-only on macOS (no CUDA).
- **Kubernetes** — `namespace` + PVCs (model cache / input / output) + Redis +
  worker `Deployment` (replicas, GPU-ready) + API `Deployment`/`Service` + a batch `Job`.

**Caveats:**

- The image uses the default (CUDA) torch, runs on CPU, uses the GPU automatically
  on NVIDIA-runtime hosts / K8s GPU nodes.
- Models download on first run into a shared `/models` volume/PVC (K8s: needs an
  RWX StorageClass so replicas share it).
- The image is **not** built for you (multi-GB); **Build image** runs
  `docker build`, and for K8s you must push/`kind load` it to the cluster.
- This TUI is a management convenience; production RAG would call the API /
  Python worker (or `protocol-droid.sh`) directly. See the
  [protocol-droid README](https://github.com/malahmen/protocol-droid) for details.

## Model downloads (Hugging Face) & offline use

marker runs inference **locally**, but the model weights are **not bundled** — on
first use they download from the **Hugging Face Hub** (the surya/marker models
plus the `surya-2` GGUFs for the llama.cpp OCR backend) into
`~/.cache/huggingface`, with a little metadata under `~/.cache/datalab`. So a
**connected first run is required**; after that it runs from cache.

- **No TTL.** The caches never expire — a re-download only happens if the upstream
  model **revision** changes.
- **The recurring `unauthenticated requests to the HF Hub` warning** isn't a
  re-download: `huggingface_hub` pings the Hub on every load to check the cached
  files are current. Set **`HF_TOKEN`** (free HF account → read token) to
  authenticate that check — silences the warning and raises rate limits.
- **Offline mode (automatic once cached).** When the cache is populated, the
  convert paths set **`HF_HUB_OFFLINE=1`** for you: no network round-trip, no
  warning, faster startup. Override with **`MARKER_HF_ONLINE=1`** to force update
  checks; an explicit `HF_HUB_OFFLINE` in your environment always wins. **Status**
  shows the mode the next conversion will use.
- **Air-gapped**: pre-populate `~/.cache/huggingface` (and `~/.cache/datalab`) on
  a connected machine, copy them over, and marker runs fully offline.

## Driving the engine directly

Skip the TUI:

```sh
protocol-droid.sh local setup
protocol-droid.sh local convert report.pdf --output-format markdown
protocol-droid.sh local convert ./docs --workers 4 -- --force_ocr
protocol-droid.sh service deploy --input ./input --output ./output
protocol-droid.sh --help
```

See the [engine README](https://github.com/malahmen/protocol-droid) for the full
flag reference.

## Notes

- Set `TORCH_DEVICE` (e.g. `cuda`, `mps`, `cpu`) to override the detected device.
- Model caches live under `~/.cache/datalab` (and `~/.cache/huggingface`); the
  **Status** action reports their sizes, and **Clear model cache** clears the
  datalab cache.
