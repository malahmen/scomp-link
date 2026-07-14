#!/usr/bin/env python3
"""Stamp letterhead tokens (and optionally a header logo) into a generated .docx.

The built-in reference doc carries {{TOKENS}} in its running header/footer
(see build-reference.py). This replaces them with the resolved per-document
values, stamps the core document properties (Title / Author), and — when a
--logo is given — injects that image into the header at conversion time (so the
logo is config/prompt-driven, not baked into the reference). Stdlib only.

Usage:
    stamp_docx_tokens.py <file.docx> \\
        --title "…" --version-suffix ", v1.0" \\
        --author "…" --date "13 July 2026" --classification "INTERNAL USE ONLY" \\
        [--logo /path/to/logo.png]

Any token left unset stamps to an empty string; --logo omitted/missing → no logo.
"""
import argparse
import os
import re
import zipfile

R = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
PR = "http://schemas.openxmlformats.org/package/2006/relationships"
HF_RE = re.compile(r"word/(header|footer)\d+\.xml$")
HDR_RE = re.compile(r"word/header\d+\.xml$")

LOGO_W_EMU = 1280160  # ~1.4in wide; height derived from the PNG's aspect ratio
LOGO_MEDIA = "media/logo_letterhead.png"
LOGO_RID = "rIdLetterheadLogo"
FTR_RE = re.compile(r"word/footer\d+\.xml$")

HDR_TYPE = R + "/header"
FTR_TYPE = R + "/footer"
FIRST_HDR = "word/header_first.xml"
FIRST_FTR = "word/footer_first.xml"
RID_HDR_FIRST = "rIdHdrFirst"
RID_FTR_FIRST = "rIdFtrFirst"
_WNS = 'xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"'
EMPTY_HDR = f'<?xml version="1.0" encoding="UTF-8" standalone="yes"?><w:hdr {_WNS}><w:p/></w:hdr>'
EMPTY_FTR = f'<?xml version="1.0" encoding="UTF-8" standalone="yes"?><w:ftr {_WNS}><w:p/></w:ftr>'


def xml_escape(s: str) -> str:
    return (s.replace("&", "&amp;").replace("<", "&lt;")
            .replace(">", "&gt;").replace('"', "&quot;"))


def stamp_core_props(xml: str, title: str, author: str) -> str:
    def set_tag(x, tag, val):
        if not val:
            return x
        val = xml_escape(val)
        pat = re.compile(rf"<{tag}>.*?</{tag}>", re.S)
        if pat.search(x):
            return pat.sub(f"<{tag}>{val}</{tag}>", x, count=1)
        return x.replace("</cp:coreProperties>", f"<{tag}>{val}</{tag}></cp:coreProperties>")
    return set_tag(set_tag(xml, "dc:title", title), "dc:creator", author)


def png_dims(path):
    with open(path, "rb") as f:
        b = f.read(24)
    if len(b) < 24 or b[:8] != b"\x89PNG\r\n\x1a\n":
        return 0, 0
    return int.from_bytes(b[16:20], "big"), int.from_bytes(b[20:24], "big")


def logo_paragraph(cx, cy):
    # Inline (not floating) image in its own header paragraph: the header grows
    # to fit it, so every renderer pushes the body below it — no overlap, no
    # top-margin math (a floating anchor can spill over the body instead).
    return (
        '<w:p><w:pPr><w:jc w:val="left"/><w:spacing w:before="0" w:after="40" w:line="240" w:lineRule="auto"/></w:pPr>'
        '<w:r><w:rPr><w:noProof/></w:rPr><w:drawing>'
        f'<wp:inline distT="0" distB="0" distL="0" distR="0"><wp:extent cx="{cx}" cy="{cy}"/>'
        '<wp:effectExtent l="0" t="0" r="0" b="0"/><wp:docPr id="1" name="Logo"/>'
        '<wp:cNvGraphicFramePr><a:graphicFrameLocks noChangeAspect="1"/></wp:cNvGraphicFramePr>'
        '<a:graphic><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture">'
        f'<pic:pic><pic:nvPicPr><pic:cNvPr id="0" name="logo.png"/><pic:cNvPicPr/></pic:nvPicPr>'
        f'<pic:blipFill><a:blip r:embed="{LOGO_RID}"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill>'
        f'<pic:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="{cx}" cy="{cy}"/></a:xfrm>'
        '<a:prstGeom prst="rect"><a:avLst/></a:prstGeom></pic:spPr></pic:pic>'
        '</a:graphicData></a:graphic></wp:inline></w:drawing></w:r></w:p>'
    )


def inject_logo(data, logo_path):
    """Embed logo_path as an inline image in a new first paragraph of the header."""
    headers = sorted(n for n in data if HDR_RE.match(n))
    if not headers:
        return False
    hdr = headers[0]
    hs = data[hdr].decode("utf-8")
    if LOGO_RID in hs:            # already injected
        return False
    pw, ph = png_dims(logo_path)
    cx = LOGO_W_EMU
    cy = int(cx * ph / pw) if pw else 588872

    with open(logo_path, "rb") as f:
        data["word/" + LOGO_MEDIA] = f.read()

    # header rels
    relname = "word/_rels/" + os.path.basename(hdr) + ".rels"
    rel = f'<Relationship Id="{LOGO_RID}" Type="{R}/image" Target="{LOGO_MEDIA}"/>'
    if relname in data:
        s = data[relname].decode("utf-8")
        if LOGO_RID not in s:
            s = s.replace("</Relationships>", rel + "</Relationships>")
        data[relname] = s.encode("utf-8")
    else:
        data[relname] = (
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
            f'<Relationships xmlns="{PR}">{rel}</Relationships>'
        ).encode("utf-8")

    # prepend a dedicated logo paragraph as the header's first block
    hs = re.sub(r"(<w:hdr\b[^>]*>)", lambda m: m.group(1) + logo_paragraph(cx, cy), hs, count=1)
    data[hdr] = hs.encode("utf-8")

    # png content type
    ct = data["[Content_Types].xml"].decode("utf-8")
    if 'Extension="png"' not in ct:
        ct = ct.replace("</Types>", '<Default Extension="png" ContentType="image/png"/></Types>')
        data["[Content_Types].xml"] = ct.encode("utf-8")
    return True


def strip_pagenum(ftr):
    """Drop the 'Page N / M' cluster from a footer, keeping date/classification."""
    pat = re.compile(
        r'<w:r>(?:(?!</w:r>).)*?<w:t[^>]*>Page\s*</w:t></w:r>'
        r'\s*<w:fldSimple w:instr=" PAGE ">.*?</w:fldSimple>'
        r'\s*<w:r>.*?</w:r>'
        r'\s*<w:fldSimple w:instr=" NUMPAGES ">.*?</w:fldSimple>',
        re.S)
    return pat.sub("", ftr, count=1)


def add_first_page_chrome(data, show_header, show_footer, show_pagenum):
    """Give page 1 (the title page) its own header/footer via <w:titlePg/>, so
    the letterhead header / footer / page number can each be suppressed there
    while the rest of the document keeps them. Returns True if it changed the doc.

    With titlePg set, page 1 uses the 'first'-type parts; a 'first' part we leave
    empty shows nothing, and one we copy from the default looks identical. The
    page number lives in the footer, so it only survives when the footer does.
    """
    doc_key = "word/document.xml"
    if doc_key not in data:
        return False
    doc = data[doc_key].decode("utf-8")
    if "<w:titlePg" in doc:
        return False
    # Insert the first-page references just before <w:pgSz>. Anchoring on pgSz
    # (rather than the default footerReference) is robust to attribute reordering
    # by upstream post-processors AND keeps the refs in their schema-required slot
    # (all header/footer references precede pgSz). Bail if there's no section.
    doc, n = re.subn(
        r"(<w:pgSz\b)",
        f'<w:headerReference w:type="first" r:id="{RID_HDR_FIRST}"/>'
        f'<w:footerReference w:type="first" r:id="{RID_FTR_FIRST}"/>' + r"\1",
        doc, count=1)
    if n == 0:
        return False
    doc = doc.replace("</w:sectPr>", "<w:titlePg/></w:sectPr>", 1)

    hdrs = sorted(n for n in data if HDR_RE.match(n))
    ftrs = sorted(n for n in data if FTR_RE.match(n))
    def_hdr = hdrs[0] if hdrs else None
    def_ftr = ftrs[0] if ftrs else None

    # First-page header: copy the default (incl. any injected logo) or leave empty.
    if show_header and def_hdr:
        data[FIRST_HDR] = data[def_hdr]
        src_rels = "word/_rels/" + os.path.basename(def_hdr) + ".rels"
        if src_rels in data:                      # carry the logo relationship over
            data["word/_rels/header_first.xml.rels"] = data[src_rels]
    else:
        data[FIRST_HDR] = EMPTY_HDR.encode("utf-8")

    # First-page footer: empty / page-number-stripped / full copy.
    if not show_footer or not def_ftr:
        data[FIRST_FTR] = EMPTY_FTR.encode("utf-8")
    elif not show_pagenum:
        data[FIRST_FTR] = strip_pagenum(data[def_ftr].decode("utf-8")).encode("utf-8")
    else:
        data[FIRST_FTR] = data[def_ftr]

    # document rels → the two first-page references
    rels_key = "word/_rels/document.xml.rels"
    rels = data[rels_key].decode("utf-8")
    rels = rels.replace("</Relationships>",
        f'<Relationship Id="{RID_HDR_FIRST}" Type="{HDR_TYPE}" Target="header_first.xml"/>'
        f'<Relationship Id="{RID_FTR_FIRST}" Type="{FTR_TYPE}" Target="footer_first.xml"/>'
        "</Relationships>")
    data[rels_key] = rels.encode("utf-8")

    # content-type overrides for the new parts
    ct = data["[Content_Types].xml"].decode("utf-8")
    ct = ct.replace("</Types>",
        '<Override PartName="/word/header_first.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.header+xml"/>'
        '<Override PartName="/word/footer_first.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.footer+xml"/>'
        "</Types>")
    data["[Content_Types].xml"] = ct.encode("utf-8")

    data[doc_key] = doc.encode("utf-8")
    return True


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("docx")
    ap.add_argument("--title", default="")
    ap.add_argument("--version-suffix", default="")
    ap.add_argument("--author", default="")
    ap.add_argument("--date", default="")
    ap.add_argument("--classification", default="")
    ap.add_argument("--logo", default="")
    # Title-page chrome — passed only when a title page is active. "show" keeps
    # page 1 identical to the rest; "hide" suppresses that element on page 1.
    ap.add_argument("--tp-header", choices=["show", "hide"], default="show")
    ap.add_argument("--tp-footer", choices=["show", "hide"], default="show")
    ap.add_argument("--tp-pagenum", choices=["show", "hide"], default="show")
    args = ap.parse_args()

    tokens = {
        "TITLE": args.title, "VERSION_SUFFIX": args.version_suffix,
        "AUTHOR": args.author, "DATE": args.date, "CLASSIFICATION": args.classification,
    }

    try:
        with zipfile.ZipFile(args.docx) as z:
            infos = z.infolist()
            data = {i.filename: z.read(i.filename) for i in infos}
    except (OSError, zipfile.BadZipFile):
        return

    changed = False
    for name, raw in list(data.items()):
        if HF_RE.match(name):
            s = raw.decode("utf-8")
            for k, v in tokens.items():
                s = s.replace("{{%s}}" % k, xml_escape(v))
            if s != raw.decode("utf-8"):
                data[name] = s.encode("utf-8")
                changed = True

    core = "docProps/core.xml"
    if core in data:
        s = data[core].decode("utf-8")
        ns = stamp_core_props(s, args.title, args.author)
        if ns != s:
            data[core] = ns.encode("utf-8")
            changed = True

    if args.logo and os.path.isfile(args.logo):
        changed = inject_logo(data, args.logo) or changed

    # First-page chrome — only when something is actually being suppressed.
    if "hide" in (args.tp_header, args.tp_footer, args.tp_pagenum):
        changed = add_first_page_chrome(
            data,
            args.tp_header != "hide",
            args.tp_footer != "hide",
            args.tp_pagenum != "hide",
        ) or changed

    if not changed:
        return
    tmp = args.docx + ".tmp"
    written = set()
    with zipfile.ZipFile(tmp, "w", zipfile.ZIP_DEFLATED) as z:
        for i in infos:                       # preserve original entries/metadata
            z.writestr(i, data[i.filename])
            written.add(i.filename)
        for name, content in data.items():    # plus any parts we added (media/rels)
            if name not in written:
                z.writestr(name, content)
    os.replace(tmp, args.docx)
    print("stamped letterhead" + (" + logo" if (args.logo and os.path.isfile(args.logo)) else ""))


if __name__ == "__main__":
    main()
