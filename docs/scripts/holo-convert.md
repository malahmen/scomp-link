# Document Conversion — holo-convert

`holo-convert/holo-convert.sh` · Engine: [malahmen/holo-convert](https://github.com/malahmen/holo-convert)

Listed in the launcher as `holo-convert/holo-convert.sh — Convert documents (Markdown <-> PDF/DOCX) via the holo-convert engine`. There is no sub-menu: the script is a single linear flow (source format → output format → file picker → options → convert).

Convert documents between formats. The conversion logic is the standalone,
gum-free **holo-convert** engine (kept in its own repository); scomp-link ships
only the interactive front-end, which resolves the engine (`$HOLO_CONVERT_DIR`
→ sibling checkout → `~/.cache/scomp-link/holo-convert` → clone from public
HTTPS, repo overridable with `$HOLO_CONVERT_REPO`) and drives it with flags.

**Supported conversions:**

- Markdown → PDF (engines: xelatex, lualatex, pdflatex, wkhtmltopdf, weasyprint, pagedjs-cli)
- Markdown → DOCX
- DOCX → Markdown (with media extraction)

**Features:**

- Font selection — only installed fonts are offered (verified via fontconfig / the macOS font registry), so xelatex never aborts on a missing font
- PDF-engine picker — lists only the engines actually installed (blank = let the engine auto-pick)
- Title page injection with templates (`{{TITLE}}` / `{{IMAGE}}`), rendered natively per format
- Table of contents built from the document headers (opt-in, selectable depth), placed after the title page
- Cross-format page breaks: a lone `\newpage` (or `\pagebreak`) line becomes a real break in both PDF and DOCX
- Syntax highlighting for code blocks (p10k theme — boxed blocks in PDF, shaded/bordered in DOCX)
- Table layout fixes: wide tables are fit to the page width, code-heavy first columns are widened
- Mermaid diagram rendering
- Character substitutions, horizontal-rule stripping, `[[wikilink]]` unwrapping
- Local `.svg` → PNG (via `rsvg-convert`) and non-PDF-safe images (e.g. GIF) → PNG for PDF output
- Image fit + centering; collision-safe output filenames

**Picking files:**

- The picker searches under `SOURCE_ROOT` (env var; default `.`) — set it to point the front-end at a docs tree elsewhere
- Search depth is prompted (default 3); `.fcc/`, `output/`, `node_modules/` and `.git/` are excluded
- Multi-select: SPACE to select, ENTER to confirm

**Broken-link check (Markdown sources):**

Before converting `.md` files the front-end offers to check internal links for
broken anchors. It uses `python3` and the engine's `.fcc/docx/check_links.py`
(skipped silently when either is missing), walks each broken `#anchor` with the
closest matching heading as a suggestion, and offers to apply the fix in place
in the source file before conversion runs.

**DOCX letterhead & document options:**

- **Reference styles**: **letterhead** (running header with optional logo + title/version, footer with date · classification · `Page X / Y`), **plain** (styled, no header/footer), or **none** (pandoc default)
- **Metadata**: author / classification / version / logo resolve from `.fcc/docx/config` (key=value) → per-file YAML front matter → flags (title auto-extracts from the first `#`; date defaults to today)
- **Page size**: A4 or Letter (built-in references)
- **Title-page chrome toggles**: show/hide the header, footer, and page number on the title page (page number nested under the footer)
- **Concatenate** several Markdown files into one document (optional page break; the first `#` becomes the Title)
- The built-in `reference.docx` is generated reproducibly by `build-reference.py` in the engine repo

**Using it:**

From the launcher, pick `holo-convert/holo-convert.sh`. Or drive the engine directly (no TUI):

```sh
holo-convert.sh --from md --to pdf --toc --title-page doc.md
holo-convert.sh --from md --to docx --letterhead --author "ACME" report.md
holo-convert.sh --from docx --to md --md-variant gfm report.docx
holo-convert.sh --setup --to pdf      # install core dependencies
holo-convert.sh --with-optional       # core + optional tools (rsvg, ImageMagick, fontconfig, mermaid)
holo-convert.sh --help                # full flag list
```

Dependencies are checked, never installed automatically: `bash` 4+ and `pandoc` always; a LaTeX engine for PDF; `python3` (stdlib) for DOCX; optional `rsvg-convert`, ImageMagick/`sips`, fontconfig, and `mermaid-cli`. Run `--setup` to install the core, or `--with-optional` for the core plus the optional tools.

See the [holo-convert repository](https://github.com/malahmen/holo-convert) for engine internals and the complete option reference.
