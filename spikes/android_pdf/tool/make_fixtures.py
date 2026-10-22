#!/usr/bin/env python3
"""Generate the HOM-27 PDF fixtures (Android PDF write-path spike).

Standard library only: no downloads, no third-party PDF library. Writes raw
PDF 1.7 objects with a correct xref table and trailer. Output is
deterministic (fixed dates, fixed /ID, seeded pseudo-random text), so running
it again produces byte-identical files.

Usage:
    python3 spikes/android_pdf/tool/make_fixtures.py [--out DIR] [--check]

    --out DIR   output directory (default: spikes/android_pdf/fixtures)
    --check     regenerate in memory and fail if any file on disk differs

Fixtures (see ../fixtures/README.md):
    text_200p.pdf        200 A4 pages of real Helvetica text (timings, text kept)
    merge_partner_3p.pdf 3 pages: portrait, landscape, /Rotate 90 (merge/rotate)
    image_only_2p.pdf    2 scanned-style pages, grayscale image only, no text
    annotated_2p.pdf     2 text pages carrying markup, ink, note and stamp
                         annotations (annotate/stamp round-trips)
    fixtures.json        manifest: page counts, sizes, sha256, per-page tokens
"""

import argparse
import hashlib
import json
import os
import sys
import zlib

FIXED_DATE = "D:20261016000000Z"  # V2-123 owner decision date
PRODUCER = "Danaview HOM-27 fixture generator 1"
A4 = (595, 842)

WORDS = (
    "danaview library document page merge split rotate reorder delete "
    "annotate stamp compress android platform jetpack renderer selectable "
    "text fixture timing route report licence bundle archive folder share "
    "preview thumbnail search index quick brown fox jumps over lazy dog "
    "alpha bravo charlie delta echo foxtrot golf hotel india juliet kilo"
).split()


class Lcg:
    """Tiny deterministic generator (same numbers on every Python)."""

    def __init__(self, seed):
        self.state = seed & 0xFFFFFFFF

    def next(self):
        self.state = (1103515245 * self.state + 12345) & 0x7FFFFFFF
        return self.state


def pdf_str(text):
    """Literal string, escaped, ASCII only."""
    text.encode("ascii")
    return "(" + text.replace("\\", "\\\\").replace("(", "\\(").replace(")", "\\)") + ")"


class PdfWriter:
    """Collects numbered objects, then serialises them with an xref table."""

    def __init__(self):
        self.objects = []  # index i holds object number i + 1

    def reserve(self):
        self.objects.append(None)
        return len(self.objects)

    def set(self, num, body):
        self.objects[num - 1] = body if isinstance(body, bytes) else body.encode("latin-1")

    def add(self, body):
        num = self.reserve()
        self.set(num, body)
        return num

    def add_stream(self, data, extra="", compress=True):
        if compress:
            data = zlib.compress(data, 9)
            extra = "/Filter /FlateDecode " + extra
        head = "<< %s/Length %d >>\nstream\n" % (extra, len(data))
        return self.add(head.encode("latin-1") + data + b"\nendstream")

    def serialise(self, root, info):
        out = bytearray(b"%PDF-1.7\n%\xe2\xe3\xcf\xd3\n")
        offsets = []
        for i, body in enumerate(self.objects, start=1):
            assert body is not None, "object %d never set" % i
            offsets.append(len(out))
            out += b"%d 0 obj\n" % i + body + b"\nendobj\n"
        xref_at = len(out)
        out += b"xref\n0 %d\n" % (len(self.objects) + 1)
        out += b"0000000000 65535 f\r\n"
        for off in offsets:
            out += b"%010d 00000 n\r\n" % off
        # Deterministic file identifier: hash of everything before the xref.
        fid = hashlib.md5(bytes(out[:xref_at])).hexdigest().upper()
        out += (
            "trailer\n<< /Size %d /Root %d 0 R /Info %d 0 R /ID [<%s> <%s>] >>\n"
            "startxref\n%d\n%%%%EOF\n"
            % (len(self.objects) + 1, root, info, fid, fid, xref_at)
        ).encode("latin-1")
        return bytes(out)


def add_info(w, title):
    return w.add(
        "<< /Title %s /Author (Danaview) /Producer %s /Creator %s "
        "/CreationDate (%s) /ModDate (%s) >>"
        % (pdf_str(title), pdf_str(PRODUCER), pdf_str(PRODUCER), FIXED_DATE, FIXED_DATE)
    )


def add_font(w):
    return w.add(
        "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>"
    )


def text_page_content(token, title, page_no, page_count, rng, width, height, lines=40):
    """Content stream: heading, unique token line, body text, footer."""
    ops = ["BT", "/F1 16 Tf", "56 %d Td" % (height - 72), pdf_str(title) + " Tj", "ET"]
    ops += ["BT", "/F1 11 Tf", "56 %d Td" % (height - 96),
            pdf_str("Token %s - page %d of %d" % (token, page_no, page_count)) + " Tj", "ET"]
    ops += ["BT", "/F1 10 Tf", "13 TL", "56 %d Td" % (height - 124)]
    usable = min(lines, int((height - 124 - 60) / 13))
    for _ in range(usable):
        n = 9 + rng.next() % 5
        sentence = " ".join(WORDS[rng.next() % len(WORDS)] for _ in range(n))
        ops.append(pdf_str(sentence.capitalize() + ".") + " Tj T*")
    ops += ["ET", "BT", "/F1 9 Tf", "%d 36 Td" % (width // 2 - 20),
            pdf_str("- %d -" % page_no) + " Tj", "ET"]
    return "\n".join(ops).encode("latin-1")


def build_text_pdf(title, token_prefix, page_specs, seed, annotate=None):
    """page_specs: list of (width, height, rotate). annotate(w, page_index, font) -> [annot refs]."""
    w = PdfWriter()
    catalog = w.reserve()
    pages = w.reserve()
    font = add_font(w)
    rng = Lcg(seed)
    kids, tokens = [], []
    count = len(page_specs)
    for i, (pw, ph, rot) in enumerate(page_specs, start=1):
        token = "%s-P%04d" % (token_prefix, i)
        tokens.append(token)
        content = w.add_stream(text_page_content(token, title, i, count, rng, pw, ph))
        page = w.reserve()
        extra = ""
        if rot:
            extra += " /Rotate %d" % rot
        if annotate:
            refs = annotate(w, i - 1, page, font)
            if refs:
                extra += " /Annots [%s]" % " ".join("%d 0 R" % r for r in refs)
        w.set(page, "<< /Type /Page /Parent %d 0 R /MediaBox [0 0 %d %d] "
                    "/Resources << /Font << /F1 %d 0 R >> /ProcSet [/PDF /Text] >> "
                    "/Contents %d 0 R%s >>" % (pages, pw, ph, font, content, extra))
        kids.append(page)
    w.set(pages, "<< /Type /Pages /Count %d /Kids [%s] >>"
          % (count, " ".join("%d 0 R" % k for k in kids)))
    w.set(catalog, "<< /Type /Catalog /Pages %d 0 R >>" % pages)
    info = add_info(w, title)
    return w.serialise(catalog, info), tokens


def scan_image(width, height, seed):
    """8-bit grayscale 'scan': paper tone, dark text-like bars, light noise."""
    rng = Lcg(seed)
    rows = []
    margin = width // 12
    for y in range(height):
        band = (y // 14) % 3 != 2 and margin < y < height - margin
        row = bytearray(width)
        seg_end = margin + rng.next() % (width - 2 * margin)
        for x in range(width):
            v = 236 - (x * 10) // width  # slight shading across the page
            if band and margin < x < seg_end and (x // 23) % 5 != 4:
                v = 48
            v += (rng.next() >> 8) % 9 - 4  # sensor noise
            row[x] = max(0, min(255, v))
        rows.append(bytes(row))
    return b"".join(rows)


def build_image_pdf(title, page_count, seed):
    w = PdfWriter()
    catalog = w.reserve()
    pages = w.reserve()
    kids = []
    iw, ih = 620, 877  # ~75 dpi A4 scan
    for i in range(page_count):
        pixels = scan_image(iw, ih, seed + i)
        img = w.add_stream(pixels, "/Type /XObject /Subtype /Image /Width %d /Height %d "
                                   "/ColorSpace /DeviceGray /BitsPerComponent 8 " % (iw, ih))
        content = w.add_stream(("q %d 0 0 %d 0 0 cm /Im0 Do Q" % A4).encode("latin-1"))
        page = w.add("<< /Type /Page /Parent %d 0 R /MediaBox [0 0 %d %d] "
                     "/Resources << /XObject << /Im0 %d 0 R >> /ProcSet [/PDF /ImageB] >> "
                     "/Contents %d 0 R >>" % (pages, A4[0], A4[1], img, content))
        kids.append(page)
    w.set(pages, "<< /Type /Pages /Count %d /Kids [%s] >>"
          % (page_count, " ".join("%d 0 R" % k for k in kids)))
    w.set(catalog, "<< /Type /Catalog /Pages %d 0 R >>" % pages)
    info = add_info(w, title)
    return w.serialise(catalog, info)


def quad(x1, y1, x2, y2):
    # QuadPoints order used by Acrobat/PDFKit: top-left, top-right, bottom-left, bottom-right.
    return "[%d %d %d %d %d %d %d %d]" % (x1, y2, x2, y2, x1, y1, x2, y1)


def annotate_page(w, index, page, font):
    """Annotations on the two pages of annotated_2p.pdf, all with fixed /M dates."""
    common = "/P %d 0 R /M (%s) /T (Danaview fixture) /F 4" % (page, FIXED_DATE)
    top = A4[1]
    refs = []
    if index == 0:
        # Markup over the heading, token and first body lines, each with an
        # appearance stream so readers that don't synthesise one still draw it.
        def markup(subtype, x1, y1, x2, y2, rgb, ops, label, multiply=False):
            res = "/Resources << /ExtGState << /G0 << /BM /Multiply /CA 1 /ca 1 >> >> >> " if multiply else ""
            ap = w.add_stream(ops.encode("latin-1"), "/Type /XObject /Subtype /Form /BBox [0 0 %d %d] %s"
                              % (x2 - x1, y2 - y1, res), compress=False)
            return w.add("<< /Type /Annot /Subtype /%s %s /Rect [%d %d %d %d] /QuadPoints %s "
                         "/C [%s] /AP << /N %d 0 R >> /Contents (%s) >>"
                         % (subtype, common, x1, y1, x2, y2, quad(x1, y1, x2, y2), rgb, ap, label))
        refs.append(markup("Highlight", 52, top - 78, 400, top - 54, "1 0.9 0",
                           "/G0 gs 1 0.9 0 rg 0 0 348 24 re f", "fixture highlight", multiply=True))
        refs.append(markup("Underline", 52, top - 100, 300, top - 86, "0 0.4 1",
                           "0 0.4 1 RG 1 w 0 1 m 248 1 l S", "fixture underline"))
        refs.append(markup("StrikeOut", 52, top - 140, 400, top - 126, "1 0 0",
                           "1 0 0 RG 1 w 0 6 m 348 6 l S", "fixture strike-out"))
        refs.append(w.add("<< /Type /Annot /Subtype /Text %s /Rect [520 %d 544 %d] "
                          "/Name /Comment /Open false /C [1 1 0] "
                          "/Contents (fixture sticky note) >>" % (common, top - 90, top - 66)))
    else:
        ink_ap = w.add_stream(b"0 0 1 RG 2 w 1 J 1 j 10 10 m 60 80 l 110 20 l 160 90 l 210 30 l S",
                              "/Type /XObject /Subtype /Form /BBox [0 0 220 100] ", compress=False)
        refs.append(w.add("<< /Type /Annot /Subtype /Ink %s /Rect [100 300 320 400] "
                          "/InkList [[110 310 160 380 210 320 260 390 310 330]] "
                          "/BS << /W 2 >> /C [0 0 1] /AP << /N %d 0 R >> "
                          "/Contents (fixture ink) >>" % (common, ink_ap)))
        ft_ap = w.add_stream(("0.2 0.2 0.2 RG 1 w 0.5 0.5 239 39 re S BT /F1 12 Tf 0 g "
                              "6 15 Td (Fixture free text note) Tj ET").encode("latin-1"),
                             "/Type /XObject /Subtype /Form /BBox [0 0 240 40] "
                             "/Resources << /Font << /F1 %d 0 R >> >> " % font, compress=False)
        refs.append(w.add("<< /Type /Annot /Subtype /FreeText %s /Rect [300 200 540 240] "
                          "/DA (/Helv 12 Tf 0 g) /AP << /N %d 0 R >> "
                          "/Contents (Fixture free text note) >>" % (common, ft_ap)))
        st_ap = w.add_stream(("0.8 0 0 RG 3 w 1.5 1.5 177 57 re S BT /F1 22 Tf 0.8 0 0 rg "
                              "20 20 Td (APPROVED) Tj ET").encode("latin-1"),
                             "/Type /XObject /Subtype /Form /BBox [0 0 180 60] "
                             "/Resources << /Font << /F1 %d 0 R >> >> " % font, compress=False)
        refs.append(w.add("<< /Type /Annot /Subtype /Stamp %s /Rect [360 80 540 140] "
                          "/Name /Approved /AP << /N %d 0 R >> "
                          "/Contents (fixture stamp) >>" % (common, st_ap)))
    return refs


def build_all():
    files = {}
    manifest = {"generator": "spikes/android_pdf/tool/make_fixtures.py",
                "date": FIXED_DATE, "fixtures": {}}

    def record(name, data, pages, tokens, notes):
        files[name] = data
        manifest["fixtures"][name] = {
            "pages": pages, "bytes": len(data),
            "sha256": hashlib.sha256(data).hexdigest(),
            "text": bool(tokens), "page_tokens": tokens, "notes": notes,
        }

    data, tokens = build_text_pdf("Danaview HOM-27 text fixture", "HOM27T",
                                  [(A4[0], A4[1], 0)] * 200, seed=27)
    record("text_200p.pdf", data, 200, tokens,
           "200 A4 pages, Helvetica text in Flate streams; token per page for "
           "text-preservation checks; 200-page timings")

    data, tokens = build_text_pdf("Danaview HOM-27 merge partner", "HOM27M",
                                  [(A4[0], A4[1], 0), (A4[1], A4[0], 0), (A4[0], A4[1], 90)],
                                  seed=2701)
    record("merge_partner_3p.pdf", data, 3, tokens,
           "page 1 portrait, page 2 landscape MediaBox, page 3 /Rotate 90; merge, "
           "reorder and rotate input")

    data = build_image_pdf("Danaview HOM-27 scanned fixture", 2, seed=2702)
    record("image_only_2p.pdf", data, 2, [],
           "2 pages, each one 620x877 8-bit DeviceGray image (Flate), no text layer; "
           "compress input and image-only merge partner")

    data, tokens = build_text_pdf("Danaview HOM-27 annotated fixture", "HOM27A",
                                  [(A4[0], A4[1], 0)] * 2, seed=2703, annotate=annotate_page)
    record("annotated_2p.pdf", data, 2, tokens,
           "page 1: Highlight, Underline, StrikeOut, Text note; page 2: Ink, FreeText, "
           "Stamp (with /AP); annotations must survive every write route")

    files["fixtures.json"] = (json.dumps(manifest, indent=2, sort_keys=True) + "\n").encode()
    return files


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--out", default=os.path.join(here, "..", "fixtures"))
    ap.add_argument("--check", action="store_true")
    args = ap.parse_args()
    files = build_all()
    out = os.path.normpath(args.out)
    if args.check:
        stale = []
        for name, data in files.items():
            path = os.path.join(out, name)
            if not os.path.exists(path) or open(path, "rb").read() != data:
                stale.append(name)
        if stale:
            print("stale fixtures: " + ", ".join(stale), file=sys.stderr)
            return 1
        print("fixtures up to date (%d files)" % len(files))
        return 0
    os.makedirs(out, exist_ok=True)
    for name, data in sorted(files.items()):
        with open(os.path.join(out, name), "wb") as fh:
            fh.write(data)
        print("%-22s %9d bytes" % (name, len(data)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
