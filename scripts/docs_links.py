#!/usr/bin/env python3
"""Check the repository's Markdown: every image exists, every relative link and #anchor resolves.

Used by scripts/gate-figures.sh. Usage: docs_links.py ROOT images|links
Prints one FAIL line per problem and exits 1 on any; prints what it read either way, and
refuses (exit 2) when there is nothing to read, so a moved tree cannot pass by being empty.
"""
import os
import re
import sys

root, mode = sys.argv[1], sys.argv[2]
files = [os.path.join(root, f) for f in ("README.md", "CONTRIBUTING.md", "SECURITY.md") if os.path.isfile(os.path.join(root, f))]
docs = os.path.join(root, "docs")
if os.path.isdir(docs):
    files += sorted(os.path.join(docs, f) for f in os.listdir(docs) if f.endswith(".md"))
if not files:
    print("measured nothing: no Markdown under " + root)
    sys.exit(2)

FENCE = re.compile(r"(?ms)^```.*?^```")


def slug(h):
    h = re.sub(r"[`*]", "", h).strip().lower()
    h = re.sub(r"[^\w\- ]", "", h)
    return h.replace(" ", "-")


def anchors(path):
    seen, out = {}, set()
    for m in re.finditer(r"(?m)^#{1,6} (.+)$", FENCE.sub("", open(path, encoding="utf-8").read())):
        s = slug(m.group(1))
        n = seen.get(s, 0)
        out.add(s if n == 0 else f"{s}-{n}")
        seen[s] = n + 1
    return out


bad, read = 0, 0
for path in files:
    body = FENCE.sub("", open(path, encoding="utf-8").read())
    here = os.path.dirname(path)
    rel = os.path.relpath(path, root)
    for m in re.finditer(r"(!?)\[[^\]]*\]\(([^)\s]+)\)", body):
        is_img, target = m.group(1) == "!", m.group(2)
        if target.startswith(("http://", "https://", "mailto:")):
            continue
        if (mode == "images") != is_img:
            continue
        read += 1
        file_part, _, anchor = target.partition("#")
        dest = os.path.normpath(os.path.join(here, file_part)) if file_part else path
        if not os.path.exists(dest):
            print(f"FAIL: {rel}: {target}: no such file")
            bad += 1
            continue
        if anchor and dest.endswith(".md") and anchor not in anchors(dest):
            print(f"FAIL: {rel}: {target}: no heading gives #{anchor}")
            bad += 1
if read == 0:
    print(f"measured nothing: no {mode} in {len(files)} files")
    sys.exit(2)
print(f"{mode}: {read} read in {len(files)} files, {bad} broken")
sys.exit(1 if bad else 0)
