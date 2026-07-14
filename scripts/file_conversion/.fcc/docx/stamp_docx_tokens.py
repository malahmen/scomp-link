#!/usr/bin/env python3
"""Stamp letterhead tokens into a generated .docx (runtime post-processor).

The built-in reference doc carries {{TOKENS}} in its running header/footer
(see build-reference.py). This replaces them with the resolved per-document
values, and stamps the core document properties (Title / Author) so the file's
metadata matches. Stdlib only (zipfile + regex) — no lxml at runtime.

Usage:
    stamp_docx_tokens.py <file.docx> \\
        --title "…" --version-suffix ", v1.0" \\
        --author "…" --date "13 July 2026" --classification "INTERNAL USE ONLY"

Any token left unset stamps to an empty string (so a minimal letterhead — just
title + page numbers — still renders cleanly).
"""
import argparse
import os
import re
import sys
import zipfile

HF_RE = re.compile(r"word/(header|footer)\d+\.xml$")


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
    xml = set_tag(xml, "dc:title", title)
    xml = set_tag(xml, "dc:creator", author)
    return xml


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("docx")
    ap.add_argument("--title", default="")
    ap.add_argument("--version-suffix", default="")
    ap.add_argument("--author", default="")
    ap.add_argument("--date", default="")
    ap.add_argument("--classification", default="")
    args = ap.parse_args()

    tokens = {
        "TITLE": args.title,
        "VERSION_SUFFIX": args.version_suffix,
        "AUTHOR": args.author,
        "DATE": args.date,
        "CLASSIFICATION": args.classification,
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

    if not changed:
        return
    tmp = args.docx + ".tmp"
    with zipfile.ZipFile(tmp, "w", zipfile.ZIP_DEFLATED) as z:
        for i in infos:
            z.writestr(i, data[i.filename])
    os.replace(tmp, args.docx)
    print("stamped letterhead tokens")


if __name__ == "__main__":
    main()
