# OWNER: S4-Q
#
# Second reader for the S4 E2E results (integration_test/v12/s4): reads the copies and the
# manifest the scenario wrote into DV_S4_OUT and checks each with poppler (pdfinfo, pdftotext,
# pdftoppm), not PDFKit:
#
#   pages, encryption (and that the password opens it), page rotations, every expected page token
#   in the extracted text (text stays text), annotation subtypes present (or absent: a burned-in
#   signature is no Stamp annotation), size limits (compress), and for the signed copy that each
#   placed signature changed the pixels of its rectangle against the same page of the original.
#
# Usage: python3 integration_test/v12/s4/tool/check_s4_outputs.py <out dir> <s4_docs dir>
# Needs poppler (pdfinfo, pdftotext, pdftoppm) and Pillow. Prints one line per check; exit 1 on a
# failure.

import json
import os
import re
import subprocess
import sys
import tempfile
import zlib

from PIL import Image, ImageChops, ImageStat

out_dir, docs = sys.argv[1], sys.argv[2]
manifest = json.load(open(os.path.join(out_dir, "manifest.json")))
failed = 0


def run(args):
    return subprocess.run(args, capture_output=True, text=True).stdout


def check(ok, tag, what):
    global failed
    print(f"{'PASS' if ok else 'FAIL'} {tag}: {what}")
    if not ok:
        failed += 1


def subtypes(path):
    data = open(path, "rb").read()
    found = {}

    def scan(b):
        for m in re.finditer(rb"/Subtype\s*/([A-Za-z]+)", b):
            k = m.group(1).decode()
            found[k] = found.get(k, 0) + 1

    scan(data)
    for m in re.finditer(rb"stream\r?\n", data):
        end = data.find(b"endstream", m.end())
        if end < 0 or b"/ObjStm" not in data[max(0, m.start() - 300):m.start()]:
            continue
        try:
            scan(zlib.decompress(data[m.end():end]))
        except zlib.error:
            pass
    return found


def render(path, page, password=None):
    d = tempfile.mkdtemp()
    args = ["pdftoppm", "-r", "72", "-f", str(page), "-l", str(page), "-png"]
    if password:
        args += ["-upw", password]
    subprocess.run(args + [path, os.path.join(d, "p")], check=True)
    f = [x for x in os.listdir(d) if x.endswith(".png")][0]
    return Image.open(os.path.join(d, f)).convert("L")


for item in manifest:
    tag, path = item["tag"], os.path.join(out_dir, item["file"])
    pw = item.get("password")
    pwa = ["-upw", pw] if pw else []
    info = run(["pdfinfo", *pwa, path])
    pages = int(re.search(r"Pages:\s+(\d+)", info).group(1)) if "Pages:" in info else -1
    if "pages" in item:
        check(pages == item["pages"], tag, f"pages {pages} (expected {item['pages']})")
    enc = re.search(r"Encrypted:\s+(\w+)", info)
    if item.get("encrypted"):
        check(enc is not None and enc.group(1) == "yes", tag, f"encrypted ({enc.group(1) if enc else '?'})")
        nopw = run(["pdftotext", path, "-"])
        check(not any(t in nopw for t in item.get("tokens", [])), tag, "no text readable without the password")
    if "rot" in item:
        rots = [int(x) for x in re.findall(r"rot:\s+(\d+)", run(["pdfinfo", "-f", "1", "-l", str(pages), path]))]
        check(rots == item["rot"], tag, f"rotations {rots}")
    if item.get("tokens"):
        text = run(["pdftotext", *pwa, path, "-"])
        missing = [t for t in item["tokens"] if t not in text]
        check(not missing, tag, f"{len(item['tokens']) - len(missing)}/{len(item['tokens'])} page tokens in poppler's text" + (f", missing {missing[:3]}" if missing else ""))
    if not pw:
        st = subtypes(path)
        for k in item.get("annots", []):
            check(st.get(k, 0) > 0, tag, f"/{k} annotation present ({st.get(k, 0)})")
        for k in item.get("noAnnots", []):
            check(st.get(k, 0) == 0, tag, f"no /{k} annotation ({st.get(k, 0)})")
    if "maxBytes" in item:
        size = os.path.getsize(path)
        check(size < item["maxBytes"], tag, f"{size} B < {item['maxBytes']} B")
    for s in item.get("stamps", []):
        page = s["page"] + 1
        a, b = render(os.path.join(docs, "s4_report.pdf"), page), render(path, page)
        h = a.size[1]
        box = (int(s["x"]), int(h - s["y"] - s["h"]), int(s["x"] + s["w"]), int(h - s["y"]))
        diff = ImageStat.Stat(ImageChops.difference(a.crop(box), b.crop(box))).mean[0]
        outside = ImageStat.Stat(ImageChops.difference(a.crop((0, 0, a.size[0], 40)), b.crop((0, 0, b.size[0], 40)))).mean[0]
        check(diff > 2 and outside < 1, tag, f"signature on page {page} drawn in its rect (mean diff {diff:.1f}; header strip {outside:.2f})")

print(f"{'ALL PASS' if not failed else f'{failed} FAILED'} ({len(manifest)} files)")
sys.exit(1 if failed else 0)
