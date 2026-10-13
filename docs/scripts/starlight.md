# Starlight Documentation

`starlight/starlight_astro.sh`

Create and manage Astro Starlight documentation sites:

- **Project creation** with optional Mermaid diagram support
- **Sidebar management** (autogenerate or manual mode)
- **Section management** (add, rename, remove, reorder)
- **File management** (add, edit, rename, move, delete pages within a section)
- **External links** (top-level, grouped, or homepage-only)
- **Content editing** with vim integration (pages, the homepage, `astro.config.mjs`)
- **Sites over an existing folder**: serve a folder of Markdown (e.g. a reports repository) as a Starlight site, live, without copying the documents or putting the site inside that folder
- **Project discovery** to manage existing sites

## Requirements

- **Node ≥ 22.12** (current Astro's floor; older is fatal), **npm**, and **vim** —
  all checked up front. Odd-numbered Node majors (23, 25, …) are outside Astro's
  official support list but work in practice, so they only warn; switch with
  `mise use --global node@lts`.
- **mise** recommended — Create runs `mise trust` + `mise install`, and every
  generated `mise.toml` task needs it. Only a warning if missing (managing an
  existing project works without it).
- **tree** optional — enables the *View site structure* action.

## Manage menu

Pick an existing project (discovery scans for `astro.config.mjs` up to three
levels below the current directory, plus the sites under `$SCOMP_STARLIGHT_HOME`)
or switch to another one at any time. Opening a project whose sidebar still uses
the pre-0.39 group shape (`{ label, autogenerate }`, which Starlight 0.39+
refuses to build) offers to convert it to `{ label, items: [{ autogenerate }] }`.
Actions:

- **Sections** — Add section · Rename section · Remove section · Reorder sections
  (reorder opens `astro.config.mjs` in vim)
- **Files** — Add file (md/mdx with title/description front matter) · Edit file ·
  Rename file · Move file (to another section) · Delete file. Rename/Move warn
  when a strict-mode sidebar entry in `astro.config.mjs` may need updating.
- **Site** — Edit homepage (`index.mdx`/`index.md`, created if missing) ·
  Edit astro.config.mjs · View site structure (only when `tree` is installed;
  ignores `node_modules`, `.git`, `dist`, `.astro`)
- **Switch project** · **Quit**

## Sites over an existing folder

**Create site over an existing folder** builds a Starlight site whose pages are
the `.md`/`.mdx` files of a folder you already have (a reports repository, a
notes folder), read **in place**:

- **Nothing is copied, and nothing is written into the folder.** The content
  collection loads the documents by absolute path (stored in the project's
  `.docs-source`; `$DOCS_SOURCE` overrides it). Edits in the folder show up on
  the next reload of the dev server.
- **The site project lives elsewhere.** Default:
  `${XDG_DATA_HOME:-~/.local/share}/scomp-link/starlight/<name>` (override the
  base with `$SCOMP_STARLIGHT_HOME`), or `./<name>` next to where the TUI was
  started. A location inside the source folder is refused. `node_modules/` and
  `dist/` stay in the project.
- **Plain Markdown documents read as pages:**
  - a file without a front-matter `title` takes its first `# ` heading, and that
    leading H1 is dropped, since Starlight renders the title as the page heading;
  - `README.md` is the homepage (`README.md` in a subfolder is that folder's index);
  - relative links between documents (`[x](other.md#part)`) become page URLs
    (`/other/#part`);
  - `draft: true` in front matter keeps a document out of a build.
- **Its manage menu:**
  - serve (dev server, live; this machine only, or the network with `--host`);
  - build static site (into the project's `dist/`);
  - preview the build;
  - change source folder;
  - edit `astro.config.mjs`.

  Page and section editing doesn't apply, because the content belongs to the
  source folder.

It installs `@astrojs/markdown-remark`, because the two Markdown plugins it uses
run on Astro 7's `unified()` processor. Images referenced from the documents are
served from the source folder: the dev server is allowed to read it.

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
  Mermaid's remark plugin is passed to Astro 7's `markdown.processor:
  unified(…)`, so Create also installs `@astrojs/markdown-remark` (Astro 7 no
  longer ships it, and the old `markdown.remarkPlugins` fails without it).
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
