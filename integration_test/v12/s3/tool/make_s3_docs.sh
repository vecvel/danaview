#!/usr/bin/env bash
# OWNER: S3-Q
#
# Generates the local test documents of the S3 E2E scenario (integration_test/v12/s3): nothing is
# downloaded. Writes into <out> (default build/e2e/s3_docs, ignored by git):
#
#   s3_report.pdf      200 A4 pages, one token per page (HOM27T-P0001 …), a copy of the committed
#                      spike fixture spikes/android_pdf/fixtures/text_200p.pdf
#   s3_openwith.pdf    3 pages (copy of merge_partner_3p.pdf): opened with Danaview from "Files"
#   s3_shared.pdf      2 pages with annotations (copy of annotated_2p.pdf): the Share Extension batch
#   s3_shared.jpg      1200 x 800 JPEG drawn by Pillow: the Share Extension batch
#   s3_notes.txt       UTF-8 text, 3000 lines with accents, CJK and emoji
#   s3_table.csv       comma CSV, header + 400 rows, quoted fields with commas and newlines
#   s3_brief.docx      a minimal Office Open XML document (zipfile, no Office needed): Quick Look
#   s3_bundle.zip      a zip archive (no viewer: the file card)
#
# Usage: integration_test/v12/s3/tool/make_s3_docs.sh [out]
# Needs python3 with Pillow (local tool). bash 3.2 compatible.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
OUT="${1:-$ROOT/build/e2e/s3_docs}"
FIX="$ROOT/spikes/android_pdf/fixtures"
mkdir -p "$OUT"

cp "$FIX/text_200p.pdf" "$OUT/s3_report.pdf"
cp "$FIX/merge_partner_3p.pdf" "$OUT/s3_openwith.pdf"
cp "$FIX/annotated_2p.pdf" "$OUT/s3_shared.pdf"

python3 - "$OUT" <<'PY'
import csv, io, sys, zipfile
from PIL import Image, ImageDraw

out = sys.argv[1]

img = Image.new("RGB", (1200, 800))
d = ImageDraw.Draw(img)
for y in range(0, 800, 8):
    d.rectangle([0, y, 1200, y + 8], fill=(30 + y * 100 // 800, 90, 160 - y * 80 // 800))
d.ellipse([450, 250, 750, 550], fill=(250, 190, 70))
img.save(f"{out}/s3_shared.jpg", "JPEG", quality=88)

with open(f"{out}/s3_notes.txt", "w", encoding="utf-8", newline="\n") as f:
    f.write("S3 QA notes - Danaview documents\n")
    for i in range(1, 3000):
        f.write(f"Line {i:04d}: café crème, naïve façade, 日本語のテキスト, emoji 📄 — token S3Q-T{i:04d}\n")

with open(f"{out}/s3_table.csv", "w", encoding="utf-8", newline="") as f:
    w = csv.writer(f)
    w.writerow(["Id", "Name", "City", "Amount", "Note"])
    for i in range(1, 401):
        note = "multi\nline" if i % 50 == 0 else ("has, comma" if i % 7 == 0 else "")
        w.writerow([i, f"Person {i:03d}", ["Kolkata", "Zürich", "São Paulo", "Tokyo"][i % 4], f"{i * 12.5:.2f}", note])

def docx(path, paragraphs):
    ct = ('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
          '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
          '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
          '<Default Extension="xml" ContentType="application/xml"/>'
          '<Override PartName="/word/document.xml" '
          'ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>'
          '</Types>')
    rels = ('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
            '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
            '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" '
            'Target="word/document.xml"/></Relationships>')
    body = "".join(f'<w:p><w:r><w:t xml:space="preserve">{p}</w:t></w:r></w:p>' for p in paragraphs)
    doc = ('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
           '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">'
           f'<w:body>{body}</w:body></w:document>')
    with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as z:
        z.writestr("[Content_Types].xml", ct)
        z.writestr("_rels/.rels", rels)
        z.writestr("word/document.xml", doc)

docx(f"{out}/s3_brief.docx", ["S3 QA brief", "Danaview opens this Word file read-only in Quick Look."] +
     [f"Paragraph {i}: token S3Q-D{i:03d}" for i in range(1, 40)])

with zipfile.ZipFile(f"{out}/s3_bundle.zip", "w", zipfile.ZIP_DEFLATED) as z:
    z.writestr("readme.txt", "S3 QA bundle\n" * 50)
PY

# Fixed timestamps, so "unchanged" is checked against a known value.
touch -t 202610200900 "$OUT"/s3_*
ls -l "$OUT"
