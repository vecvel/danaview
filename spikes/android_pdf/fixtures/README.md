# HOM-27 PDF fixtures

Generated inputs for the Android PDF write-path spike (HOM-27, V2-123). Nothing
here was downloaded. `tool/make_fixtures.py` builds every file with the Python 3
standard library (raw PDF objects, Helvetica text, zlib/Flate streams).

Regenerate (from the repo root):

```sh
python3 spikes/android_pdf/tool/make_fixtures.py          # write the files
python3 spikes/android_pdf/tool/make_fixtures.py --check  # fail if any file is stale
```

Output is deterministic: fixed dates (`D:20261016000000Z`), a file `/ID` derived
from the content and seeded text. Running the generator again gives the same bytes.

| File | Pages | Size | Purpose |
| --- | --- | --- | --- |
| `text_200p.pdf` | 200 | 281 KB | The 200-page timing file. Real Helvetica text (not outlines) on every page; page *n* carries the token `HOM27T-P000n` (zero-padded to 4 digits). |
| `merge_partner_3p.pdf` | 3 | 5 KB | Merge, reorder and rotate input: page 1 portrait A4, page 2 landscape MediaBox, page 3 `/Rotate 90`. Tokens `HOM27M-P0001..3`. |
| `image_only_2p.pdf` | 2 | 586 KB | Scanned-style pages: one 620x877 8-bit grayscale image each, no text layer. Compress input; image-only merge partner. |
| `annotated_2p.pdf` | 2 | 7 KB | Text pages with annotations. Page 1: Highlight, Underline, StrikeOut (all with `/AP`) and a Text note. Page 2: Ink, FreeText and an `/Approved` Stamp (all with `/AP`). Tokens `HOM27A-P0001..2`. |
| `fixtures.json` | | 6 KB | Manifest: page count, bytes, sha256 and the per-page tokens for each file. |

## Text-preservation check

After any operation (merge, split, reorder, rotate, delete, annotate, stamp,
compress) extract the text of each output page and look for the tokens listed in
`fixtures.json`. A route that turns text into pictures loses the tokens. The
image-only file has no tokens; there, check that it still renders and that the
output is smaller after compression.

## Validated on macOS (2026-10-22)

- Structure: every xref offset points at `N 0 obj`, every stream `/Length` lands on `endstream`.
- `mdimport -t -d3`: `kMDItemNumberOfPages` 200 / 3 / 2 / 2, and `kMDItemTextContent` holds the page text (empty for the image-only file).
- PDFKit: every file opens; `page.string` finds every page token (200/200, 3/3, 2/2);
  `findString("HOM27T-P0150")` gives one hit; rotations `[0, 90]` on the merge partner;
  all 7 annotation types read back on `annotated_2p.pdf`.
- `qlmanage -t` renders every file, including the annotation appearances.

The spec doesn't name a password-protected, form or malformed PDF for HOM-27, so
none is included. Add them to the generator if the spike needs them.
