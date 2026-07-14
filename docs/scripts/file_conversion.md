# Document Conversion

`file_conversion/file_conversion.sh`

Convert documents between formats with extensive customization:

**Supported Conversions:**

- Markdown to PDF (multiple engines: xelatex, lualatex, pdflatex, wkhtmltopdf, weasyprint)
- Markdown to DOCX
- DOCX to Markdown (with media extraction)

**Features:**

- Font selection (Helvetica, Times, Georgia, Palatino, etc.)
- Title page injection with templates
- Table of contents / index page built from the document headers (opt-in, selectable depth)
- Cross-format page breaks: a lone `\newpage` (or `\pagebreak`) line becomes a real break in both PDF and DOCX
- Syntax highlighting for code blocks (p10k theme + boxed code blocks in PDF; shaded, bordered code blocks in DOCX via a built-in reference template)
- Only installed fonts are offered for PDF prose (verified with fontconfig), so xelatex never aborts on a missing font
- Table layout fixes: wide tables are forced to fit the page width, and code-heavy first columns are widened
- Mermaid diagram rendering
- Character substitution options
- Collision-safe output filenames

**DOCX letterhead & document features:**

- **Reference styles**: choose **letterhead** (running header with optional logo +
  title/version, footer with date · classification · `Page X / Y`), **plain** (styled,
  no header/footer), a **custom** `.docx` template, or **none**
- **Configurable metadata**: author / classification / version resolve from
  `.fcc/docx/config` (key=value) → per-file YAML front matter → TUI prompt for anything
  missing (title auto-extracts from the first `#`; date defaults to today). Filled into
  the header/footer + core document properties after conversion
- **Page size**: A4 or Letter for the built-in references
- **Concatenate** several selected Markdown files into one document (optional page break
  between; the first `#` becomes the document Title)
- **`[[wikilink]]` unwrapping** to plain text
- **Local `.svg` → PNG** rasterization (via `rsvg-convert`) so images embed in DOCX/PDF
- **Image fit + centering**: wide images are scaled to the text column and centred
- The built-in `reference.docx` is generated reproducibly by
  [`build-reference.py`](../../scripts/starlight/.fcc/docx/build-reference.py) from
  declarative specs (fonts/colours/spacing + header/footer XML + optional logo)

**Modes:**

- Full mode: All options interactive
- Fast mode: Quick PDF generation with defaults

See also: [File Conversion Templates](../../README.md#file-conversion-templates) in the main README.
