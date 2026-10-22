# HOM-27 spike report: Android PDF write path

- **Ticket:** HOM-27 (BUILD_PLAN §HOM-27, V2-123, FILES_MEDIA_HOME_PLAN §8.5, closes V2-V6 once HOM-28 records it)
- **Lane / date:** Windows / Android lane, 2026-10-22, base `origin/v1.2-android` 76ecd060, branch `spike-hom27-android`
  (probe in a1add079)
- **Fixtures:** `spikes/android_pdf/fixtures/` from the Mac (2826428), used unchanged. The four PDFs match the
  sha256 values in `fixtures.json`. Nothing was downloaded for this spike.

## Verdict

**Route (a), platform + Jetpack only: FAIL for the page tools.** The platform has **no page-level write API on any
Android version up to API 37** (no insert, import, move, delete or rotate of pages). The only platform way to make
merge, split, reorder, rotate and delete is to rasterise pages into `android.graphics.pdf.PdfDocument`, and that
**turns text into pictures on every version** (0 of 203 tokens survive, 61 MB from 286 KB). That is exactly the
condition under which the owner's decision (D-98j, V2-123) allows route (b) or (c).

Route (a) **does pass** for annotate, highlight, stamp/sign on devices with SdkExtensions S >= 18
(`android.graphics.pdf.component`, API 36.1, or Android 12+ with a recent Play system update), with text intact.
It **fails** for compress (the API exposes no image objects to recompress) and has no answer at all below S-ext 18.

**Recommendation:** use **(b) PdfBox-Android** (Apache-2.0, pure Java, no native code, all ABIs, min API 19) as the
single write engine for every PDF tool on Android, and keep the platform only for viewing (HOM-25, `PdfRenderer`).
(c) PDFium is not recommended: it needs native builds per ABI and our own JNI for page import/rotate, for the
same result. **Numbers for (b) and (c) are not measured** (see "Open items"): that needs one Maven download, which
this spike was not cleared to make. The owner/Mac should approve the follow-up measurement before HOM-28A starts.

## What was run

`probe/src/Hom27Probe.java` is a dependency-free probe (SDK `android.jar` only), compiled by
`tool/build_probe.sh` (javac + d8, no Gradle) and run on emulators through `app_process` by
`tool/run_probe.sh`. Every result is a `HOM27 {json}` line; raw logs and output PDFs are under
`build/results/<label>/` (not committed). Text preservation is checked as the fixtures README says: extract each
output page's text with the platform (`PdfRenderer.Page.getTextContents()`, API 35+) and count the
`HOM27?-P????` tokens. Annotation survival is checked by reading the `/Subtype` entries of the output bytes.

| Emulator (x86_64) | API | S-ext | Text API | Edit API | Ran |
|---|---|---|---|---|---|
| Medium_Phone | 37 (Android 17) | 22 | yes | yes | everything |
| Pixel_9_Pro_XL_API_35 | 35 | 13 | yes | no | raster + `write()` |
| Pixel_API_34 | 34 | 7 | no | no | raster |
| Pixel_API_29 | 29 | n/a | no | no | raster |

API 24-28 was not booted (Pixel_API_28 was in use by the S2 agent on emulator-5554); the raster path there uses the
same API 21 `PdfRenderer` + API 19 `PdfDocument` calls as API 29. Raster outputs from API 29-35 are the same kind
of file as on API 37 (one image object per page, 0 tokens there). All timings are emulator timings on the laptop,
useful for comparing routes, not as phone numbers.

## Platform API surface (from `android.jar` and `api-versions.xml`, platforms 35, 36, 36.1, 37.0)

| Capability | API | Available from |
|---|---|---|
| Render pages | `PdfRenderer` | API 21 |
| Create new pages (drawn with Canvas) | `android.graphics.pdf.PdfDocument` | API 19 |
| Text extraction, search, selection | `PdfRenderer.Page.getTextContents()` etc. | API 35; `PdfRendererPreV` on API 31-34 with S-ext 13 |
| Save the open document | `PdfRenderer.write(pfd, removePassword)` | API 35; `PdfRendererPreV` with S-ext 13 |
| Add/remove/update annotations (Highlight, FreeText, Stamp only) and page objects (text, image, path) | `android.graphics.pdf.component.*`, `Page.addPageAnnotation/addPageObject` | API 36.1; S-ext 18 on API 31+ |
| Insert, delete, move, import, rotate pages; set `/Rotate`; recompress images | none | **not on any version up to API 37** |

`androidx.pdf` (Jetpack) is a viewer (`PdfViewerFragment`) built on the same platform service; it adds no page
editing either. It was not added to the probe (it is a download), so this row is from its published API, not a run.

## Results per tool and route

Tokens = tokens found / tokens expected in the output. "raster" = route (a) page-image fallback at 144 dpi.

### Page tools (merge, split, reorder, rotate, delete)

| Tool | Route (a) raster, any API | Route (a) "rebuild" by copying page objects, S-ext 18 only |
|---|---|---|
| Merge 200 + 3 pages | **0/203 tokens**, 61.2 MB (inputs 281 KB + 5 KB), 14.8 s (API 37), 21.0-29.9 s (API 29-35) | 203/203 tokens, 4.3 MB, **528 s** |
| Split pages 1-100 | **0/100**, 30.2 MB, 6.0 s (API 37), 6.2-12.8 s (API 29-35) | 100/100, 2.1 MB, 99 s |
| Reorder 3 pages | **0/3**, 786 KB, 0.15-0.44 s | 3/3, 58 KB, 0.2 s |
| Rotate page 1 by 90 | **0/3**, correct orientation | 2/3: no page `/Rotate` API, objects must be transformed by hand (the probe's transform put part of the page off-sheet); the existing `/Rotate 90` of page 3 is dropped |
| Delete page 2 | **0/2**, 524 KB | 2/2, 42 KB |
| Pass? | **FAIL** (text becomes pictures) | **FAIL** (see below) |

The "rebuild" is the only text-keeping trick inside route (a): make blank pages with `PdfDocument`, open them with
`PdfRenderer`, copy every `PdfPageObject` of the source page onto them, `write()`. It keeps the fixture tokens,
but it is not a usable engine:
- the API exposes only text, image and path objects, and fonts only as the 4 standard families (Helvetica, Times,
  Courier, Symbol): embedded fonts, form XObjects, shadings and every annotation type except Highlight, FreeText
  and Stamp are lost (on `annotated_2p.pdf` only the Highlight survived; Underline, StrikeOut, Text note, Ink,
  FreeText and Stamp were dropped);
- the image-only fixture exposes **0 image objects**, so scanned pages come out **blank**;
- it is super-linear: 99 s for 100 pages, 528 s for 203 pages, and 15x the input size;
- it needs S-ext 18 (Android 12+ with a recent Play system update, or 36.1+).

### Annotate, highlight, sign/stamp

| Check | Result (API 37, S-ext 22) |
|---|---|
| Add Highlight + FreeText + Stamp (ink path) annotations, burned-in path + image, `write()` | text 2/2 and 200/200 kept; 18-20 ms; all 7 original annotation subtypes still in the file |
| Signature stamp on all 200 pages + `write()` | 200/200 tokens, 103 ms, 281 KB -> 373 KB |
| `write()` round trip, no change | 200/200 tokens, 12 ms (API 37) / 133 ms (API 35); all annotations kept |
| Underline, StrikeOut, Ink as annotations | **not in the API** (only Highlight, FreeText, Stamp); ink/underline can only be page paths or stamps |
| Reading existing annotations | **platform bug:** `Page.getPageAnnotations()` throws `NullPointerException: Page object should not be null` (from `StampAnnotation.addObject` inside the native call) on fixture page 2 (Ink, FreeText, Stamp with `/AP`). Uncaught, it kills the process. |
| Below S-ext 18 | no annotation API: only raster (0 tokens) |
| Pass? | **PASS on S-ext >= 18 only**, with a reduced annotation set; FAIL below |

### Compress

| Route | Result on `image_only_2p.pdf` (586 KB) |
|---|---|
| (a) edit API: downscale image objects in place | **0 image objects exposed**, output 586 KB (no change) |
| (a) raster at 72 dpi | 736 KB (larger: Skia re-encodes as Flate) |
| (a) raster at 50 dpi | 343 KB (-41 %), but text pages compressed this way lose their text |
| Pass? | **FAIL** |

### Criteria summary

| Criterion | (a) platform + Jetpack | (b) PdfBox-Android | (c) PDFium |
|---|---|---|---|
| Text stays selectable | **FAIL** for page tools and compress on every version; PASS for annotate/stamp on S-ext >= 18 | expected PASS (copies page dictionaries and content streams) - **not measured** | expected PASS (`FPDF_ImportPages`, `FPDFPage_SetRotation`) - **not measured** |
| AAB size per ABI | 0 bytes | expected ~2-3 MB, ABI-independent (Java only) - **not measured** | expected several MB per ABI (native .so) - **not measured** |
| Minimum API | page tools: none; annotate: S-ext 18; text check: 35 or S-ext 13 | 19 (published) | per build |
| 200-page timings | raster merge 14.8-29.9 s, 61 MB; rebuild 528 s | **not measured** | **not measured** |
| Licence | platform | Apache-2.0 | BSD-3-Clause / Apache-2.0 |

## Other findings

- `tool/make_fixtures.py --check` reports `image_only_2p.pdf` and `fixtures.json` as stale on Windows
  (Python 3.14.6). The committed files are intact (sha256 match `fixtures.json`); the generator's Flate output
  depends on the local zlib build, so `--check` is only byte-exact on the Mac's Python. Not a fixture problem.
- `PdfRenderer` draws no annotations in `RENDER_MODE_FOR_DISPLAY` without `RenderParams` flags, so the raster
  fallback also loses annotation appearances unless they are requested explicitly.
- The API 34 emulator image reports S-ext 7, so `PdfRendererPreV` (S-ext 13) is not there; real API 31-34 phones
  only get it through Play system updates. Do not count on text extraction below API 35.
- HOM-25 (viewer) note: guard `getPageAnnotations()` with try/catch because of the NPE above.

## Open items (need the owner / Mac)

1. **Measure (b) and (c):** text preservation, AAB size per ABI (bundletool, already approved for AIS-44),
   min API and 200-page timings. This needs `com.tom-roush:pdfbox-android` (Maven Central, Apache-2.0) and, for
   (c), a PDFium Android build. This spike made no downloads; please approve the PdfBox-Android download (and
   say whether (c) should be measured at all) and the Windows lane runs the same probe against it.
2. The Mac copies this report and the decision into
   `docs/v1.2/files-media-home/spikes/HOM-27-android-pdf-write.md` (HOM-28) and updates D-98j / V2-V6.

## Reproduce

```sh
source ~/danaview_env.sh
bash spikes/android_pdf/tool/build_probe.sh                                     # build/probe.dex
bash spikes/android_pdf/tool/run_probe.sh emulator-5556 api37                   # build/results/api37.log + output PDFs
bash spikes/android_pdf/tool/run_probe.sh emulator-5556 api37_png png <pdf dir> # page PNGs
```
