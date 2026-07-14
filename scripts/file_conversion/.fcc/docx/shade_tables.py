#!/usr/bin/env python3
"""Apply explicit header + alternating-row shading to every table in a .docx.

Word (and especially LibreOffice / lightweight previewers) do not reliably
render table-*style* conditional banding (w:tblStylePr band1Horz), and faint
striping is easy to miss. This writes explicit cell shading (w:shd) onto each
row so the banding shows in every renderer — the same colours the PDF uses via
\\rowcolors. Idempotent (re-running replaces the shading it added).

  header row     -> HEADER_FILL  (rows flagged with <w:tblHeader/>, else row 0)
  1st data row   -> BAND_FILL, then alternating (matches the PDF's rowcolors)
  even data rows -> no fill (white)

Regex-based on the raw XML (like apply_docx_fonts.py) to preserve namespace
prefixes exactly. Assumes tables are not nested (true for these documents).

Usage: shade_tables.py <file.docx> [header_fill] [band_fill]
"""
import sys
import os
import re
import zipfile

HEADER_FILL = "CCCCCC"
BAND_FILL = "F5F5F5"

SHD_RE = re.compile(r'<w:shd\b[^>]*/>')
TCW_RE = re.compile(r'<w:tcW\b[^>]*/>')
TC_RE = re.compile(r'<w:tc\b[^>]*>.*?</w:tc>', re.S)
TR_RE = re.compile(r'<w:tr\b.*?</w:tr>', re.S)
TBL_RE = re.compile(r'<w:tbl\b.*?</w:tbl>', re.S)


def set_cell_shd(tc, fill):
    """Insert/replace <w:shd> in a <w:tc>'s tcPr (or drop it when fill is None)."""
    shd = '<w:shd w:val="clear" w:color="auto" w:fill="%s"/>' % fill if fill else ''
    m = re.search(r'<w:tcPr>(.*?)</w:tcPr>', tc, re.S)
    if m:
        pr = SHD_RE.sub('', m.group(1))  # strip any shd we set before
        if shd:
            tcw = TCW_RE.search(pr)       # schema: shd comes after tcW
            pr = pr[:tcw.end()] + shd + pr[tcw.end():] if tcw else shd + pr
        return tc[:m.start(1)] + pr + tc[m.end(1):]
    if not shd:
        return tc
    # No tcPr — add one as the first child of the cell.
    return re.sub(r'(<w:tc\b[^>]*>)', r'\1<w:tcPr>' + shd + '</w:tcPr>', tc, count=1)


def process_table(tbl):
    rows = list(TR_RE.finditer(tbl))
    out, last, data_idx = [], 0, 0
    for i, rm in enumerate(rows):
        row = rm.group(0)
        is_header = ('<w:tblHeader' in row) or (i == 0 and '<w:tblHeader' not in tbl)
        if is_header:
            fill = HEADER_FILL
        else:
            fill = BAND_FILL if data_idx % 2 == 0 else None
            data_idx += 1
        out.append(tbl[last:rm.start()])
        out.append(TC_RE.sub(lambda m: set_cell_shd(m.group(0), fill), row))
        last = rm.end()
    out.append(tbl[last:])
    return ''.join(out)


def main():
    if len(sys.argv) < 2:
        return
    path = sys.argv[1]
    global HEADER_FILL, BAND_FILL
    if len(sys.argv) > 2 and sys.argv[2]:
        HEADER_FILL = sys.argv[2]
    if len(sys.argv) > 3 and sys.argv[3]:
        BAND_FILL = sys.argv[3]

    try:
        with zipfile.ZipFile(path) as z:
            infos = z.infolist()
            data = {i.filename: z.read(i.filename) for i in infos}
    except (OSError, zipfile.BadZipFile):
        return

    key = 'word/document.xml'
    if key not in data:
        return
    doc = data[key].decode('utf-8')
    new = TBL_RE.sub(lambda m: process_table(m.group(0)), doc)
    if new == doc:
        return
    data[key] = new.encode('utf-8')

    tmp = path + '.tmp'
    with zipfile.ZipFile(tmp, 'w', zipfile.ZIP_DEFLATED) as z:
        for i in infos:
            z.writestr(i, data[i.filename])
    os.replace(tmp, path)
    print('shaded table rows: header=%s band=%s' % (HEADER_FILL, BAND_FILL))


if __name__ == '__main__':
    main()
