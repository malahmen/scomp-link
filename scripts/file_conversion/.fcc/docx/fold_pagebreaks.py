#!/usr/bin/env python3
"""Fold empty pageBreakBefore paragraphs into the following paragraph.

pagebreak.lua emits a DOCX page break as a standalone empty paragraph:

    <w:p><w:pPr><w:pageBreakBefore/></w:pPr></w:p>

That avoids the blank *page* an inline <w:br w:type="page"/> can cause, but it
still renders as a blank *line* above whatever follows (e.g. a heading). This
post-processor moves <w:pageBreakBefore/> onto the *next* paragraph's properties
and removes the empty one, so that paragraph starts the new page with nothing
above it — matching how \\newpage behaves in the PDF/LaTeX output.

Between the break and the next paragraph pandoc may emit bookmarkStart/End
anchors (heading link targets); those are preserved in place. If there is no
following paragraph the break is left untouched. Idempotent and safe to re-run.

Usage: fold_pagebreaks.py <file.docx>
"""
import re
import sys
import os
import zipfile

BREAK = '<w:p><w:pPr><w:pageBreakBefore/></w:pPr></w:p>'
# Leading whitespace + any run of bookmarkStart/End elements (kept verbatim).
PREFIX = re.compile(r'(\s*(?:<w:bookmark(?:Start|End)\b[^>]*>\s*)*)')


def fold(xml):
    out, pos, n = [], 0, 0
    while True:
        idx = xml.find(BREAK, pos)
        if idx == -1:
            out.append(xml[pos:])
            break
        out.append(xml[pos:idx])
        after = idx + len(BREAK)
        pm = PREFIX.match(xml[after:])
        prefix = pm.group(1)
        p_at = after + pm.end()
        m = re.match(r'<w:p\b[^>]*>', xml[p_at:])
        if not m:                                   # nothing to fold into
            out.append(BREAK)
            pos = after
            continue
        out.append(prefix)                          # preserve bookmarks / whitespace
        popen = m.group(0)
        rest_start = p_at + m.end()
        mppr = re.match(r'\s*<w:pPr>(.*?)</w:pPr>', xml[rest_start:], re.S)
        if mppr:
            inner = mppr.group(1)
            if '<w:pageBreakBefore' not in inner:
                # Keep the schema element order: pageBreakBefore after pStyle.
                ms = re.match(r'(<w:pStyle\b[^>]*>)', inner)
                inner = (ms.group(1) + '<w:pageBreakBefore/>' + inner[ms.end():]) if ms \
                        else '<w:pageBreakBefore/>' + inner
            out.append(popen + '<w:pPr>' + inner + '</w:pPr>')
            pos = rest_start + mppr.end()
        else:
            out.append(popen + '<w:pPr><w:pageBreakBefore/></w:pPr>')
            pos = rest_start
        n += 1
    return ''.join(out), n


def main():
    if len(sys.argv) < 2:
        return
    path = sys.argv[1]
    try:
        with zipfile.ZipFile(path) as z:
            infos = z.infolist()
            data = {i.filename: z.read(i.filename) for i in infos}
    except (OSError, zipfile.BadZipFile):
        return
    key = 'word/document.xml'
    if key not in data:
        return
    xml = data[key].decode('utf-8')
    new, n = fold(xml)
    if n == 0 or new == xml:
        return
    data[key] = new.encode('utf-8')
    tmp = path + '.tmp'
    with zipfile.ZipFile(tmp, 'w', zipfile.ZIP_DEFLATED) as z:
        for i in infos:
            z.writestr(i, data[i.filename])
    os.replace(tmp, path)
    print(f'folded {n} page break(s)')


if __name__ == '__main__':
    main()
