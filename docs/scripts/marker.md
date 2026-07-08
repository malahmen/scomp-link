# Marker (Document → Markdown / JSON)

`marker/marker.sh`

Manage [datalab-to/marker](https://github.com/datalab-to/marker) and convert documents
**into** Markdown, JSON, HTML, or chunks — the inverse of
[`file_conversion.sh`](file_conversion.md). The output is intended as a first step
toward LLM ingestion (chunking/embedding is **not** done here).

**Supported inputs:** PDF, DOCX, PPTX, XLSX, HTML, EPUB, and images (PNG/JPG/TIFF/…).

**Output formats:** `markdown`, `json`, `html`, `chunks`.

## Isolation (pipx)

marker pulls in PyTorch and downloads several GB of models on first run, so it is
installed in an **isolated pipx environment** — it never touches system Python.

- Requires a **Python 3.10–3.13** and **pipx** (the script offers to install pipx if missing).
  marker/PyTorch do **not** support Python 3.14 yet, so the script auto-selects a supported
  interpreter (preferring 3.12) with a working `venv` — it does **not** use the system
  default `python3` if that's too new.
- Install command used: `PIPX_DEFAULT_PYTHON=<py3.12> pipx install --python <py3.12> "marker-pdf[full]"`
  — pinning the interpreter for both pipx's shared venv and marker's app venv. The `[full]`
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

| Action | What it does |
|--------|--------------|
| **Convert documents** | Single file or batch folder → pick output format, output dir, and options |
| **Setup / install / upgrade** | Check Python, install pipx if needed, install or upgrade marker |
| **Status** | Version, whether CLIs are on `PATH`, detected Torch device (CPU/MPS/CUDA), model-cache size, optional cache clear |
| **Launch GUI (Streamlit)** | Runs `marker_gui` for interactive testing |
| **Launch API server** | Runs `marker_server` (FastAPI) |
| **Uninstall** | Removes marker's pipx env (model caches are kept) |

## Choosing the source

Convert first asks **how** to pick the source:

- **Detect files (scan this folder)** — scans the current folder tree (depth 3) for
  supported files and lets you pick one → single-file conversion.
- **Enter a path (file or folder)** — type a path (a leading `~` is expanded). If it's a
  **file** → single-file conversion; if it's a **folder** → batch conversion of every
  supported file inside.

## Conversion options

- **Output format** — `markdown` / `json` / `html` / `chunks`
- **Output directory** — default `./marker-output`
- **Force OCR** (`--force_ocr`) — re-OCR the whole document (fixes bad embedded text)
- **Use an LLM** (`--use_llm`) — higher quality; pick a service:
  Google Gemini, OpenAI, Anthropic Claude, or Ollama (local). API keys are read from
  the environment when present (`GEMINI_API_KEY`, `OPENAI_API_KEY`, `ANTHROPIC_API_KEY`)
  or prompted for (hidden input).
- **Page range** (`--page_range`, single-file only) — e.g. `0,5-10,20`
- **Workers** (`--workers`, batch only) — parallel processes (~3.5 GB RAM/VRAM each)

## Notes

- First conversion downloads models; subsequent runs are faster.
- Set `TORCH_DEVICE` (e.g. `cuda`, `mps`, `cpu`) to override the detected device.
- Model caches live under `~/.cache/datalab` (and `~/.cache/huggingface`); the **Status**
  action reports their size and can clear the datalab cache.
