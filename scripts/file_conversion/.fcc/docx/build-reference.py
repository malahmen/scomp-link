#!/usr/bin/env python3
"""
build-reference.py — regenerate .fcc/docx/reference.docx from declarative specs.

This is a BUILD-TIME / maintainer tool (not run during conversion). It replaces
the old hand-patched reference.docx with a reproducible build: start from
Pandoc's own default reference (so every style Pandoc maps Markdown onto is
present), then overlay scomp-link's look + a letterhead (header/footer/logo).

What it produces, on top of Pandoc's default:
  * page size + margins (A4 by default; --page-size letter for US Letter)
  * a running HEADER : optional logo + "{{TITLE}}{{VERSION_SUFFIX}}"
                       + "Created By: {{AUTHOR}} ({{DATE}})"
  * a running FOOTER : "{{DATE}}   {{CLASSIFICATION}}   Page X / Y"
  * scomp-link code/table/TOC styling, preserved 1:1:
      - SourceCode  : dark #262626 background (p10k code block)
      - VerbatimChar: teal #0087AF inline code, no background
      - Table       : grid borders + shaded header (#CCCCCC) + banded rows (#F5F5F5)
      - TOC 1..3    : right dot-leader tab (aligned page numbers)
  * settings/updateFields=true so Word refreshes the TOC + Page X/Y on open

The header/footer carry {{TOKENS}} that the conversion-time stamper
(stamp_docx_tokens.py) replaces per document. Empty tokens stamp to "".

Requires: pandoc (on PATH) and python-lxml (`pip install lxml`). Runtime
conversion does NOT need lxml — only this regeneration step does.

Usage:
    python3 build-reference.py                 # A4, no logo
    python3 build-reference.py --page-size letter
    python3 build-reference.py --logo /path/to/logo.png
    python3 build-reference.py --output /somewhere/reference.docx
"""
import argparse
import os
import shutil
import subprocess
import tempfile
import zipfile

from lxml import etree

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_OUT = os.path.join(HERE, "reference.docx")

W = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"
R = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
CT = "http://schemas.openxmlformats.org/package/2006/content-types"
PR = "http://schemas.openxmlformats.org/package/2006/relationships"
NS = {"w": W}


def w(t):
    return f"{{{W}}}{t}"


# --- page geometry (twips; 1440 = 1 inch) ----------------------------------
PAGE_SIZES = {
    "a4":     dict(pw=11906, ph=16838),
    "letter": dict(pw=12240, ph=15840),
}
MARGINS = dict(top=1440, right=1080, bottom=1440, left=1080, header=720, footer=600, gutter=0)

# --- scomp-link code/table/TOC styling to preserve (data, not CSS) ----------
CODE_BG = "262626"      # SourceCode paragraph background (p10k dark)
INLINE_FG = "0087AF"    # VerbatimChar inline-code text (p10k teal)
TBL_HEADER = "CCCCCC"   # table header row fill
TBL_BAND = "F5F5F5"     # odd body-row fill
TBL_BORDER = "808080"   # grid line colour
FOOT_GREY = "6B7280"    # header/footer secondary text colour


def sub(parent, tag, **attrs):
    e = etree.SubElement(parent, w(tag))
    for k, v in attrs.items():
        e.set(w(k), str(v))
    return e


def only(parent, tag, index=0):
    found = parent.findall(w(tag), NS)
    if found:
        return found[0]
    e = etree.Element(w(tag))
    parent.insert(index, e)
    return e


def clear(parent, *tags):
    for tag in tags:
        for el in parent.findall(w(tag), NS):
            parent.remove(el)


# ---------------------------------------------------------------------------
# styles.xml — preserve scomp-link's code/table/TOC look
# ---------------------------------------------------------------------------
def patch_styles(path):
    tree = etree.parse(path)
    root = tree.getroot()
    by_id = {s.get(w("styleId")): s for s in root.findall(w("style"), NS)}

    # SourceCode (code blocks): dark background via paragraph shading.
    sc = by_id.get("SourceCode")
    if sc is not None:
        ppr = only(sc, "pPr")
        clear(ppr, "shd")
        sub(ppr, "shd", val="clear", color="auto", fill=CODE_BG)

    # VerbatimChar (inline code + token base): teal text, no background.
    vc = by_id.get("VerbatimChar")
    if vc is not None:
        rpr = only(vc, "rPr")
        clear(rpr, "color", "shd")
        sub(rpr, "color", val=INLINE_FG)

    # Table: grid borders + bold shaded header + banded odd rows.
    tbl = by_id.get("Table")
    if tbl is not None:
        clear(tbl, "tblPr", "tblStylePr")
        name_el = tbl.find(w("name"), NS)
        idx = (list(tbl).index(name_el) + 1) if name_el is not None else 0
        tblPr = etree.Element(w("tblPr"))
        tbl.insert(idx, tblPr)
        borders = sub(tblPr, "tblBorders")
        for side in ("top", "left", "bottom", "right", "insideH", "insideV"):
            sub(borders, side, val="single", sz="4", space="0", color=TBL_BORDER)
        mar = sub(tblPr, "tblCellMar")
        for side, v in (("top", 20), ("left", 108), ("bottom", 20), ("right", 108)):
            sub(mar, side, w=v, type="dxa")
        # header row
        fr = sub(tbl, "tblStylePr", type="firstRow")
        sub(only(fr, "rPr"), "b")
        frpr = sub(fr, "tcPr")
        sub(frpr, "shd", val="clear", color="auto", fill=TBL_HEADER)
        # banded odd rows
        b1 = sub(tbl, "tblStylePr", type="band1Horz")
        b1pr = sub(b1, "tcPr")
        sub(b1pr, "shd", val="clear", color="auto", fill=TBL_BAND)

    # TOC 1..3: right-aligned dot-leader tab so page numbers align.
    styles_el = root
    for i, sid in enumerate(("TOC1", "TOC2", "TOC3"), start=1):
        if sid in by_id:
            st = by_id[sid]
        else:
            st = etree.SubElement(styles_el, w("style"))
            st.set(w("type"), "paragraph")
            st.set(w("styleId"), sid)
            sub(st, "name", val=f"toc {i}")
            sub(st, "basedOn", val="Normal")
            sub(st, "uiPriority", val="39")
        ppr = only(st, "pPr")
        clear(ppr, "tabs", "ind")
        if i > 1:
            sub(ppr, "ind", left=str((i - 1) * 220))
        tabs = sub(ppr, "tabs")
        sub(tabs, "tab", val="right", leader="dot", pos="9350")

    tree.write(path, xml_declaration=True, encoding="UTF-8", standalone=True)


# ---------------------------------------------------------------------------
# document.xml — page size/margins + header/footer references
# ---------------------------------------------------------------------------
def patch_sectpr(path, page_size):
    tree = etree.parse(path)
    root = tree.getroot()
    body = root.find(w("body"), NS)
    sect = body.find(w("sectPr"), NS)
    if sect is None:
        sect = etree.SubElement(body, w("sectPr"))
    for el in list(sect):
        sect.remove(el)
    h = sub(sect, "headerReference", type="default")
    h.set(f"{{{R}}}id", "rIdHdr")
    f = sub(sect, "footerReference", type="default")
    f.set(f"{{{R}}}id", "rIdFtr")
    sz = PAGE_SIZES[page_size]
    sub(sect, "pgSz", w=sz["pw"], h=sz["ph"])
    m = sub(sect, "pgMar")
    for k, v in MARGINS.items():
        m.set(w(k), str(v))
    sub(sect, "cols", space="720")
    tree.write(path, xml_declaration=True, encoding="UTF-8", standalone=True)


# ---------------------------------------------------------------------------
# header / footer parts (with {{TOKENS}})
# ---------------------------------------------------------------------------
NSDECL = (
    'xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" '
    'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" '
    'xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing" '
    'xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" '
    'xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture"'
)
LOGO_CX, LOGO_CY = 1280160, 588872  # ~1.4in wide, ratio for a 600x276 logo


def logo_drawing():
    return (
        '<w:r><w:rPr><w:noProof/></w:rPr><w:drawing>'
        '<wp:anchor distT="0" distB="0" distL="114300" distR="114300" simplePos="0" '
        'relativeHeight="251659264" behindDoc="0" locked="0" layoutInCell="1" allowOverlap="1">'
        '<wp:simplePos x="0" y="0"/>'
        '<wp:positionH relativeFrom="margin"><wp:posOffset>0</wp:posOffset></wp:positionH>'
        '<wp:positionV relativeFrom="paragraph"><wp:posOffset>-63500</wp:posOffset></wp:positionV>'
        f'<wp:extent cx="{LOGO_CX}" cy="{LOGO_CY}"/>'
        '<wp:effectExtent l="0" t="0" r="0" b="0"/><wp:wrapNone/>'
        '<wp:docPr id="1" name="Logo"/>'
        '<wp:cNvGraphicFramePr><a:graphicFrameLocks noChangeAspect="1"/></wp:cNvGraphicFramePr>'
        '<a:graphic><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture">'
        '<pic:pic><pic:nvPicPr><pic:cNvPr id="0" name="logo.png"/><pic:cNvPicPr/></pic:nvPicPr>'
        '<pic:blipFill><a:blip r:embed="rIdLogo"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill>'
        '<pic:spPr><a:xfrm><a:off x="0" y="0"/>'
        f'<a:ext cx="{LOGO_CX}" cy="{LOGO_CY}"/></a:xfrm>'
        '<a:prstGeom prst="rect"><a:avLst/></a:prstGeom></pic:spPr></pic:pic>'
        '</a:graphicData></a:graphic></wp:anchor></w:drawing></w:r>'
    )


def header_xml(with_logo):
    return (
        f'<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n<w:hdr {NSDECL}>'
        '<w:p><w:pPr><w:jc w:val="right"/>'
        '<w:spacing w:before="0" w:after="60" w:line="240" w:lineRule="auto"/></w:pPr>'
        + (logo_drawing() if with_logo else "")
        + '<w:r><w:rPr><w:b/><w:color w:val="111827"/><w:sz w:val="20"/></w:rPr>'
        '<w:t xml:space="preserve">{{TITLE}}{{VERSION_SUFFIX}}</w:t></w:r></w:p>'
        '<w:p><w:pPr><w:jc w:val="right"/>'
        '<w:spacing w:before="0" w:after="60" w:line="240" w:lineRule="auto"/></w:pPr>'
        f'<w:r><w:rPr><w:color w:val="{FOOT_GREY}"/><w:sz w:val="16"/></w:rPr>'
        '<w:t xml:space="preserve">Created By: {{AUTHOR}} ({{DATE}})</w:t></w:r></w:p></w:hdr>'
    )


def footer_xml():
    grey = f'<w:rPr><w:color w:val="{FOOT_GREY}"/><w:sz w:val="16"/></w:rPr>'
    greyb = f'<w:rPr><w:b/><w:color w:val="{FOOT_GREY}"/><w:sz w:val="16"/></w:rPr>'
    return (
        f'<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n<w:ftr {NSDECL}>'
        '<w:p><w:pPr><w:tabs><w:tab w:val="center" w:pos="4680"/>'
        '<w:tab w:val="right" w:pos="9350"/></w:tabs><w:spacing w:after="0"/>'
        f'{grey}</w:pPr>'
        f'<w:r>{grey}<w:t xml:space="preserve">{{{{DATE}}}}</w:t></w:r>'
        f'<w:r>{greyb}<w:tab/><w:t xml:space="preserve">{{{{CLASSIFICATION}}}}</w:t></w:r>'
        f'<w:r>{grey}<w:tab/><w:t xml:space="preserve">Page </w:t></w:r>'
        f'<w:fldSimple w:instr=" PAGE "><w:r>{grey}<w:t>1</w:t></w:r></w:fldSimple>'
        f'<w:r>{grey}<w:t xml:space="preserve"> / </w:t></w:r>'
        f'<w:fldSimple w:instr=" NUMPAGES "><w:r>{grey}<w:t>1</w:t></w:r></w:fldSimple>'
        '</w:p></w:ftr>'
    )


HEADER_RELS = (
    f'<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n'
    f'<Relationships xmlns="{PR}">'
    f'<Relationship Id="rIdLogo" Type="{R}/image" Target="media/logo.png"/></Relationships>'
)


def add_parts(work, logo):
    word = os.path.join(work, "word")
    with_logo = bool(logo)
    open(os.path.join(word, "header2.xml"), "w", encoding="utf-8").write(header_xml(with_logo))
    open(os.path.join(word, "footer2.xml"), "w", encoding="utf-8").write(footer_xml())
    os.makedirs(os.path.join(word, "_rels"), exist_ok=True)
    if with_logo:
        media = os.path.join(word, "media")
        os.makedirs(media, exist_ok=True)
        shutil.copy(logo, os.path.join(media, "logo.png"))
        open(os.path.join(word, "_rels", "header2.xml.rels"), "w", encoding="utf-8").write(HEADER_RELS)

    # document.xml.rels : rIdHdr/rIdFtr -> the new parts
    relp = os.path.join(word, "_rels", "document.xml.rels")
    tree = etree.parse(relp)
    root = tree.getroot()
    for rid, typ, tgt in (("rIdHdr", "header", "header2.xml"), ("rIdFtr", "footer", "footer2.xml")):
        e = etree.SubElement(root, f"{{{PR}}}Relationship")
        e.set("Id", rid)
        e.set("Type", f"{R}/{typ}")
        e.set("Target", tgt)
    tree.write(relp, xml_declaration=True, encoding="UTF-8", standalone=True)

    # [Content_Types].xml : png default + header/footer overrides
    ctp = os.path.join(work, "[Content_Types].xml")
    tree = etree.parse(ctp)
    root = tree.getroot()
    if with_logo and not any(d.get("Extension") == "png" for d in root.findall(f"{{{CT}}}Default")):
        d = etree.SubElement(root, f"{{{CT}}}Default")
        d.set("Extension", "png")
        d.set("ContentType", "image/png")
    for part, ct in (("/word/header2.xml", "header"), ("/word/footer2.xml", "footer")):
        o = etree.SubElement(root, f"{{{CT}}}Override")
        o.set("PartName", part)
        o.set("ContentType", f"application/vnd.openxmlformats-officedocument.wordprocessingml.{ct}+xml")
    tree.write(ctp, xml_declaration=True, encoding="UTF-8", standalone=True)


def patch_settings(work):
    """Force Word to refresh fields (TOC + Page X/Y) on open."""
    sp = os.path.join(work, "word", "settings.xml")
    if not os.path.exists(sp):
        return
    tree = etree.parse(sp)
    root = tree.getroot()
    if root.find(w("updateFields"), NS) is None:
        uf = etree.Element(w("updateFields"))
        uf.set(w("val"), "true")
        root.insert(0, uf)
    tree.write(sp, xml_declaration=True, encoding="UTF-8", standalone=True)


def main():
    ap = argparse.ArgumentParser(description="Regenerate .fcc/docx/reference.docx from specs.")
    ap.add_argument("--page-size", choices=list(PAGE_SIZES), default="a4")
    ap.add_argument("--logo", default=None, help="PNG logo to embed in the header (optional)")
    ap.add_argument("--output", default=DEFAULT_OUT)
    ap.add_argument("--no-letterhead", action="store_true",
                    help="styling only — no running header/footer/page-size (plain variant)")
    args = ap.parse_args()

    if args.logo and not os.path.isfile(args.logo):
        raise SystemExit(f"logo not found: {args.logo}")

    work = tempfile.mkdtemp(prefix="build-ref-")
    try:
        # Pandoc's default reference is the base (guarantees every mapped style).
        base = os.path.join(work, "_pandoc-default.docx")
        with open(base, "wb") as fh:
            subprocess.run(["pandoc", "--print-default-data-file", "reference.docx"],
                           check=True, stdout=fh)
        extract = os.path.join(work, "x")
        with zipfile.ZipFile(base) as z:
            z.extractall(extract)

        patch_styles(os.path.join(extract, "word", "styles.xml"))
        if not args.no_letterhead:
            patch_sectpr(os.path.join(extract, "word", "document.xml"), args.page_size)
            add_parts(extract, args.logo)
        patch_settings(extract)

        os.makedirs(os.path.dirname(os.path.abspath(args.output)), exist_ok=True)
        if os.path.exists(args.output):
            os.remove(args.output)
        with zipfile.ZipFile(args.output, "w", zipfile.ZIP_DEFLATED) as z:
            for folder, _dirs, files in os.walk(extract):
                for fn in files:
                    full = os.path.join(folder, fn)
                    z.write(full, os.path.relpath(full, extract))
        kind = "plain" if args.no_letterhead else "letterhead"
        print(f"wrote {args.output}  ({kind}, page-size={args.page_size}, logo={'yes' if args.logo else 'none'})")
    finally:
        shutil.rmtree(work, ignore_errors=True)


if __name__ == "__main__":
    main()
