#!/usr/bin/env bash
# OWNER: S4-Q
#
# Generates the local test documents of the S4 E2E scenario (integration_test/v12/s4): nothing is
# downloaded. Writes into <out> (default build/e2e/s4_docs, ignored by git):
#
#   s4_report.pdf    6 A4 pages, two columns of text in embedded system fonts and a photo-like
#                    picture on page 1 (make_s4_docs.swift; tokens S4QR-P0001…6): an Office export
#   s4_form.pdf      2 pages with AcroForm fields (text, check box) and annotations (highlight,
#                    note, free text) (make_s4_docs.swift; tokens S4QF-P0001…2)
#   s4_locked.pdf    3 pages, user password "s4qa-open" (make_s4_docs.swift; tokens S4QL-P0001…3)
#   s4_long.pdf      200 pages, one token per page (HOM27T-P0001 …): HOM-27's committed fixture
#                    spikes/android_pdf/fixtures/text_200p.pdf
#   s4_partner.pdf   3 pages, portrait / landscape / rotated (HOM-27's merge_partner_3p.pdf)
#   s4_scan.pdf      4 phone-scan pages: grey paper, skewed "text" bands, sensor noise, JPEG at
#                    200 dpi through Pillow (no text layer)
#   s4_photo.jpg     2400 x 1600 photo (Pillow): the image input of Merge into PDF
#   s4_signature.jpg 1200 x 480 photo of a hand signature on paper (Pillow): "Import" in Sign
#
# Usage: integration_test/v12/s4/tool/make_s4_docs.sh [out]
# Needs Xcode's swift and python3 with Pillow (local tools). bash 3.2 compatible.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
TOOL="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="${1:-$ROOT/build/e2e/s4_docs}"
FIX="$ROOT/spikes/android_pdf/fixtures"
mkdir -p "$OUT"
rm -f "$OUT"/s4_*

xcrun swift "$TOOL/make_s4_docs.swift" "$OUT"
cp "$FIX/text_200p.pdf" "$OUT/s4_long.pdf"
cp "$FIX/merge_partner_3p.pdf" "$OUT/s4_partner.pdf"

python3 - "$OUT" <<'PY'
import math, random, sys
from PIL import Image, ImageDraw, ImageFilter

out = sys.argv[1]
rnd = random.Random(5401)

def scan_page(n):
    w, h = 1654, 2339  # A4 at 200 dpi
    img = Image.new("L", (w, h), 236)
    d = ImageDraw.Draw(img)
    # Uneven lighting, like a phone photo of a page.
    for y in range(0, h, 6):
        shade = int(236 - 26 * (y / h) - 10 * math.sin(y / 300))
        d.rectangle([0, y, w, y + 6], fill=shade)
    d.text((140, 120), f"Scanned page {n}", fill=40)
    y = 260
    while y < h - 200:
        x = 140
        while x < w - 200:
            word = rnd.randint(40, 180)
            d.rectangle([x, y, x + word, y + 18], fill=rnd.randint(30, 70))
            x += word + rnd.randint(14, 30)
        y += rnd.choice([40, 40, 40, 90])
    img = img.rotate(rnd.uniform(-1.6, 1.6), resample=Image.BICUBIC, fillcolor=200)
    noise = Image.effect_noise((w, h), 18)
    img = Image.blend(img, noise, 0.12).filter(ImageFilter.GaussianBlur(0.6))
    return img.convert("RGB")

pages = [scan_page(n) for n in range(1, 5)]
pages[0].save(f"{out}/s4_scan.pdf", "PDF", resolution=200, save_all=True, append_images=pages[1:], quality=90)

photo = Image.new("RGB", (2400, 1600))
d = ImageDraw.Draw(photo)
for y in range(0, 1600, 4):
    d.rectangle([0, y, 2400, y + 4], fill=(40 + y * 120 // 1600, 110 + y * 60 // 1600, 190 - y * 100 // 1600))
d.ellipse([1500, 300, 1900, 700], fill=(250, 200, 80))
d.polygon([(0, 1600), (700, 900), (1300, 1600)], fill=(50, 90, 60))
d.polygon([(900, 1600), (1700, 1000), (2400, 1600)], fill=(70, 110, 70))
photo = Image.blend(photo, Image.effect_noise((2400, 1600), 30).convert("RGB"), 0.08)
photo.save(f"{out}/s4_photo.jpg", "JPEG", quality=90)

sig = Image.new("RGB", (1200, 480), (246, 243, 236))
d = ImageDraw.Draw(sig)
for y in range(0, 480, 4):
    v = 246 - y // 24
    d.rectangle([0, y, 1200, y + 4], fill=(v, v - 3, v - 10))
pts = []
for i in range(0, 900):
    t = i / 900.0
    x = 120 + t * 960
    yv = 260 + 90 * math.sin(t * 18) * math.exp(-t * 1.2) - 40 * math.sin(t * 5)
    pts.append((x, yv))
d.line(pts, fill=(20, 30, 90), width=7, joint="curve")
d.line([(300, 330), (980, 310)], fill=(20, 30, 90), width=5)
sig = sig.filter(ImageFilter.GaussianBlur(0.8))
sig.save(f"{out}/s4_signature.jpg", "JPEG", quality=88)
PY

# Fixed timestamps, so "unchanged" is checked against a known value.
touch -t 202610300900 "$OUT"/s4_*
ls -l "$OUT"
