#!/usr/bin/env python3
"""Apply prose + monospace fonts to a generated .docx.

DOCX fonts come from the reference template, whose defaults (Aptos/Calibri/
Cambria for prose via the theme, Consolas for code) are often not installed,
making Word prompt for substitutes. This rewrites, in place:
  - theme1.xml major/minor latin typeface   -> prose font (headings + body,
    which resolve through the document theme)
  - the template's explicit code-font rFonts in styles.xml -> mono font
so the document uses fonts the user actually has. Idempotent.

Usage: apply_docx_fonts.py <file.docx> <prose-font> [mono-font]
  <prose-font> may be empty ("") to leave prose (theme) fonts untouched.
"""
import sys
import os
import re
import zipfile

# Code fonts the bundled reference template uses; replaced with an installed one.
TEMPLATE_MONOS = ('Consolas', 'DejaVu Sans Mono')


def set_theme_font(xml, prose):
    def sub_tag(x, tag):
        def repl(m):
            inner = re.sub(
                r'(<a:latin typeface=")[^"]*(")',
                lambda mm: mm.group(1) + prose + mm.group(2),
                m.group(2), count=1)
            return m.group(1) + inner + m.group(3)
        return re.sub(r'(<a:%s>)(.*?)(</a:%s>)' % (tag, tag), repl, x, count=1, flags=re.S)
    return sub_tag(sub_tag(xml, 'majorFont'), 'minorFont')


def set_mono_font(xml, mono):
    for old in TEMPLATE_MONOS:
        for attr in ('w:ascii', 'w:hAnsi', 'w:cs'):
            xml = xml.replace('%s="%s"' % (attr, old), '%s="%s"' % (attr, mono))
    return xml


def main():
    if len(sys.argv) < 3:
        return
    path, prose = sys.argv[1], sys.argv[2]
    mono = sys.argv[3] if len(sys.argv) > 3 else ''
    try:
        with zipfile.ZipFile(path) as z:
            infos = z.infolist()
            data = {i.filename: z.read(i.filename) for i in infos}
    except (OSError, zipfile.BadZipFile):
        return

    changed = False
    tkey = 'word/theme/theme1.xml'
    if prose and tkey in data:
        t = data[tkey].decode('utf-8')
        nt = set_theme_font(t, prose)
        if nt != t:
            data[tkey] = nt.encode('utf-8')
            changed = True
    skey = 'word/styles.xml'
    if mono and skey in data:
        s = data[skey].decode('utf-8')
        ns = set_mono_font(s, mono)
        if ns != s:
            data[skey] = ns.encode('utf-8')
            changed = True

    if not changed:
        return
    tmp = path + '.tmp'
    with zipfile.ZipFile(tmp, 'w', zipfile.ZIP_DEFLATED) as z:
        for i in infos:
            z.writestr(i, data[i.filename])
    os.replace(tmp, path)
    print(f'applied fonts: prose={prose or "(unchanged)"} mono={mono or "(unchanged)"}')


if __name__ == '__main__':
    main()
