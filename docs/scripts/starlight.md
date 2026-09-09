# Starlight Documentation

`starlight/starlight_astro.sh`

Create and manage Astro Starlight documentation sites:

- **Project creation** with optional Mermaid diagram support
- **Sidebar management** (autogenerate or manual mode)
- **Section management** (add, rename, remove, reorder)
- **File management** (add, edit, rename, move, delete pages within a section)
- **External links** (top-level, grouped, or homepage-only)
- **Content editing** with vim integration (pages, the homepage, `astro.config.mjs`)
- **Project discovery** to manage existing sites

## Requirements

- **Node ≥ 22 with an even major** (current Astro dropped Node 18/20 and odd
  releases), **npm**, and **vim** — all checked up front; a miss is fatal.
- **mise** recommended — Create runs `mise trust` + `mise install`, and every
  generated `mise.toml` task needs it. Only a warning if missing (managing an
  existing project works without it).
- **tree** optional — enables the *View site structure* action.

## Manage menu

Pick an existing project (discovery scans for `astro.config.mjs`) or switch to
another one at any time. Actions:

- **Sections** — Add section · Rename section · Remove section · Reorder sections
  (reorder opens `astro.config.mjs` in vim)
- **Files** — Add file (md/mdx with title/description front matter) · Edit file ·
  Rename file · Move file (to another section) · Delete file. Rename/Move warn
  when a strict-mode sidebar entry in `astro.config.mjs` may need updating.
- **Site** — Edit homepage (`index.mdx`/`index.md`, created if missing) ·
  Edit astro.config.mjs · View site structure (only when `tree` is installed;
  ignores `node_modules`, `.git`, `dist`, `.astro`)
- **Switch project** · **Quit**

## What Create generates

Besides the Astro Starlight scaffold itself, Create writes:

- **`init.sh`** — a project-local starter: installs `node_modules` if missing,
  then runs `npm run dev` (http://localhost:4321).
- **`mise.toml`** with tasks:

  | Task | Runs |
  | --- | --- |
  | `dev` / `build` / `preview` | `npm run dev` / `build` / `preview` |
  | `convert` | `bash converter/convert.sh` — interactive: pick docs, choose pdf/docx, then TOC (depth 3), title-page and (PDF only) strip-rules prompts |
  | `convert:pdf` | `bash converter/convert.sh pdf` — fixed preset: `--from md --to pdf --title-page --toc --toc-depth 3 --strip-rules --font Helvetica` |
  | `convert:docx` | `bash converter/convert.sh docx` — fixed preset: `--from md --to docx --reference plain --toc --toc-depth 3` |

  When Mermaid is enabled, `[tools]` also pins `npm:@mermaid-js/mermaid-cli`
  (11.12.0) via mise. Create then runs `mise trust mise.toml` + `mise install`.
- **`converter/`** — the project's own gum front-end (`convert.sh`) plus a
  vendored copy of the [holo-convert](holo-convert.md) engine
  (`holo-convert.sh` and its `.fcc/` assets copied to `converter/.fcc/`), so the
  project has no runtime dependency on scomp-link. The engine is resolved from
  `$HOLO_CONVERT_DIR` → a sibling `holo-convert/` checkout →
  `~/.cache/scomp-link/holo-convert` → a `git clone --depth 1` (repo overridable
  with `$HOLO_CONVERT_REPO`). If none is found, an empty `converter/.fcc/` is
  created and a warning tells you where to get the engine.

`convert.sh` executes that vendored copy and requires **pandoc** (plus a LaTeX
engine for PDF) — `mise.toml` does not install it. Run
`bash converter/holo-convert.sh --setup --to pdf` from the project root, or
install pandoc via brew/apt/dnf.

See also: [Starlight Projects](../../README.md#starlight-projects) in the main README for generated-project `mise.toml` tasks.
