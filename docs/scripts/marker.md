# Marker (Document -> Markdown / JSON)

`marker/marker.sh`

Manage [datalab-to/marker](https://github.com/datalab-to/marker) and convert documents **into** Markdown, JSON, HTML, or chunks, the inverse of [`file_conversion.sh`](file_conversion.md). \
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

## Menu

The top level has three entries:

- **Convert documents** - single file or batch folder -> pick output format, output dir, options (local pipx).
- **Local tool** - submenu for the local pipx install:

  | Action                    | What it does                                                                                 |
  | ------------------------- | -------------------------------------------------------------------------------------------- |
  | Setup / install / upgrade | Check Python, install pipx if needed, install/upgrade marker                                 |
  | Status                    | Version, CLIs-on-`PATH`, Torch device (CPU/MPS/CUDA), model-cache size, optional cache clear |
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
  Google Gemini, OpenAI, Anthropic Claude, or Ollama (local). API keys are read from
  the environment when present (`GEMINI_API_KEY`, `OPENAI_API_KEY`, `ANTHROPIC_API_KEY`)
  or prompted for (hidden input).
- **Page range** (`--page_range`, single-file only) - e.g. `0,5-10,20`
- **Workers** (`--workers`, batch only) - parallel processes (~3.5 GB RAM/VRAM each)

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

## Notes

- First conversion downloads models; subsequent runs are faster.
- Set `TORCH_DEVICE` (e.g. `cuda`, `mps`, `cpu`) to override the detected device.
- Model caches live under `~/.cache/datalab` (and `~/.cache/huggingface`); the **Status**
  action reports their size and can clear the datalab cache.
