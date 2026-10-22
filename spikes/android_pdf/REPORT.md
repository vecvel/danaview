# HOM-27 spike report: Android PDF write path

- **Ticket:** HOM-27 (BUILD_PLAN §HOM-27, V2-123, FILES_MEDIA_HOME_PLAN §8.5, closes V2-V6 once HOM-28 records it)
- **Lane / date:** Windows / Android lane, 2026-10-22, base `origin/v1.2-android` 76ecd060, branch `spike-hom27-android`
  (route (a) probe a1add079, first report 318cb320, route (b) measured in the commit that adds this version)
- **Fixtures:** `spikes/android_pdf/fixtures/` from the Mac (2826428), used unchanged. The four PDFs match the
  sha256 values in `fixtures.json`.

## Verdict

**Route (a), platform + Jetpack only: FAIL** for merge, split, reorder, rotate, delete and compress. No Android
version up to API 37 has a page-level write API, and the only platform way (rasterising pages into
`android.graphics.pdf.PdfDocument`) turns text into pictures on every version. It passes annotate/stamp only on
SdkExtensions S >= 18. That meets the D-98j / V2-123 condition for an open-source library.

**Route (b), PdfBox-Android 2.0.27.0: PASS on every criterion.** Every tool (merge, split, reorder, rotate,
delete, insert/import, annotate/highlight, sign/stamp, compress) keeps all text on API 28, 29, 34 and 37; 200-page
operations take 40-400 ms on the emulator (up to 1.1 s under host load); it adds **2.0 MB to the APK, the same for
every ABI** (pure Java, no native code); it runs from API 24 (library minSdk 14); licence Apache-2.0 (plus
BouncyCastle's MIT-style licence).

**Route (c), PDFium: not measured, not approved** (owner, 2026-10-22).

**Recommendation:** PdfBox-Android 2.0.27.0 is the one Android write engine for every PDF tool (HOM-28A,
HOM-29A, HOM-30A, HOM-31A), on all supported API levels. The platform `PdfRenderer` stays the viewer (HOM-25).

## Route (b) artifacts (downloaded by the lead with the owner's approval, kept in `build/m2/`, not committed)

Fetched from Maven Central, SHA-1 verified against Maven Central by the lead; SHA-256 re-checked here.

| Artifact | Bytes | SHA-256 |
|---|---|---|
| `com.tom-roush:pdfbox-android:2.0.27.0` (.aar) | 3,254,019 | `30277f879cfd571db2a137582c95516a0d4ea6778e945519bc58ca93d57d88c7` |
| `pdfbox-android-2.0.27.0.pom` | 1,846 | `92438da87a07bc5e1acf4de9e27c2fb3f4015a61e13c493975c7e1d5bb2060b6` |
| `org.bouncycastle:bcprov-jdk15to18:1.72` (.jar) | 9,342,484 | `ea66ea8a450810b2193e8bf9a7ad3e46307c9896224c0f407d1b7d96ba1221cc` |
| `bcprov-jdk15to18-1.72.pom` | 1,145 | `96de53b7e4cd5b156a59c9748986bbd26c4e4739afb80d56abf59ac9f6154e9e` |
| `org.bouncycastle:bcpkix-jdk15to18:1.72` (.jar) | 1,022,720 | `d9b97477b72499bcee02f5a906510810257ff36a94bf69fbca0b1e65e7ffdb6e` |
| `bcpkix-jdk15to18-1.72.pom` | 1,649 | `f08dc01210f4d1c8ea9de1350b6a7fd9d25ad355e46f5b0a99f5509cabb49feb` |
| `org.bouncycastle:bcutil-jdk15to18:1.72` (.jar) | 677,620 | `d92184bdeb3105a11ad9e36acbd66b5f8eed091b08b9c8f3e2549e42b7f131f1` |
| `bcutil-jdk15to18-1.72.pom` | 1,325 | `b5a6fee3e65ff71cb5b0c0261ef2b64718a043bf21241e9eced0f1092d0c75cf` |

The three BouncyCastle jars are the AAR's declared dependencies (used only for encrypted PDFs). The AAR manifest
says minSdk 14, targetSdk 33; it ships `proguard.txt` keep rules for its security handlers.

## How it was measured

- **Route (a):** `probe/src/Hom27Probe.java`, SDK `android.jar` only, built by `tool/build_probe.sh` (javac + d8),
  run through `app_process` by `tool/run_probe.sh`.
- **Route (b):** `probe_b/src/.../Hom27PdfBox.java`, an instrumentation-only APK (PdfBox-Android needs a Context
  for its assets), built by `tool/build_probe_b.sh` from the SDK only (javac, R8 8.10.9 / D8 from build-tools
  36.0.0, aapt2, zipalign, apksigner; no Gradle, nothing downloaded), run by `tool/run_probe_b.sh`
  (`am instrument -w`). The measured runs use the **R8-minified release-like build** (`full-r8.apk`), so the
  shrunk library is what was exercised. Never part of the app or `v1.2-android` code.
- **Text check:** count the `HOM27?-P????` tokens per output page. Route (b) outputs were checked twice: with
  PDFBox's own `PDFTextStripper` on every device, and independently with the platform
  (`PdfRenderer.Page.getTextContents()`, route (a) probe in verify mode) on API 37. `PDFTextStripper` does not
  return text from pages with `/Rotate 90` (it reports 2/3 even on the untouched `merge_partner_3p.pdf`), so for
  rotated pages the platform count is the one that counts. **Annotations:** `/Subtype` per page via PDFBox.
  **Visual:** pages rendered to PNG by the platform on API 37 (`build/results/b_api37_png/`).
- Evidence (not committed): `build/results/<label>.log` (`HOM27 {json}` lines) and `build/results/<label>/`.

| Emulator (x86_64) | API | S-ext | Route (a) | Route (b) |
|---|---|---|---|---|
| Medium_Phone | 37 (Android 17) | 22 | everything | everything + platform text check + PNGs |
| Pixel_9_Pro_XL_API_35 | 35 | 13 | raster + `write()` | **not run**: the AVD was taken by the S2 agent on emulator-5554 when route (b) ran |
| Pixel_API_34 | 34 | 7 | raster | everything |
| Pixel_API_29 | 29 | n/a | raster | everything |
| Pixel_API_28 | 28 | n/a | not run (S2 agent had it then) | everything |

No API 24-27 AVD exists on this laptop; API 28 is the lowest run. Timings are emulator timings on the laptop; the
API 34 route (b) run shared the host with two other emulators (S2 and QA agents), so its numbers are 5-10x slower
and should be read as a worst case, not as a device comparison.

## Route (b) results: PdfBox-Android 2.0.27.0 (R8 build)

Time = load + operation + save, in ms. Tokens = platform check on API 37 (found / expected); PDFBox's own
check gave the same on API 28, 29, 34 and 37 except on `/Rotate` pages (see above). Sizes are identical on all
devices (signed outputs differ by a few hundred bytes of image encoding).

| Tool | Output | Tokens | API 37 | API 34* | API 29 | API 28 |
|---|---|---|---|---|---|---|
| Load + save 200 pages, no change | 281,808 B | 200/200 | 183 | 874 | 390 | 176 |
| Merge 200 + 3 pages | 286,392 B (inputs 281,010 + 4,727) | 203/203 | 73 | 640 | 95 | 87 |
| Merge 3 text + 2 scans + 2 annotated | 597,409 B, 7 pages | 5/5 text pages; scans intact; all 7 annotation types kept; `/Rotate 90` kept | 34 | 125 | 45 | 30 |
| Split 1-100 and 101-200 | 146,109 + 146,034 B | 100/100 and 100/100 | 142 | 944 | 215 | 170 |
| Reorder 3,1,2 | 4,733 B | 3/3, order P0003,P0001,P0002 | 7 | 50 | 3 | 2 |
| Reorder: reverse 200 pages | 281,808 B | 200/200, order P0200,P0199,... | 85 | 682 | 46 | 41 |
| Rotate page 1 by 90 | 4,744 B, rotations 90,0,90 | 3/3 | 3 | 34 | 4 | 8 |
| Rotate all 200 pages | 284,008 B | 200/200 | 62 | 564 | 56 | 48 |
| Delete page 2 of 3 | 3,489 B | 2/2 (P0001, P0003) | 6 | 22 | 3 | 2 |
| Delete 100 of 200 pages | 141,206 B | 100/100 | 124 | 457 | 60 | 48 |
| Insert/import page 2 of the partner after page 1 | 283,226 B, 201 pages | 201/201, order P0001,M-P0002,P0002 | 65 | 668 | 99 | 51 |
| Annotate: Highlight, Underline, StrikeOut, Ink, FreeText, Text note (with appearances) on `annotated_2p` | 10,575 B | 2/2; the 7 original + 6 new annotations | 46 | 118 | 36 | 24 |
| Same on the 200-page file | 285,923 B | 200/200 | 133 | 572 | 80 | 55 |
| Sign: signature image burned into page content + image Stamp annotation | 11,021 B | 2/2; the original 7 + 1 Stamp | 54 | 80 | 26 | 16 |
| Sign: burned in on all 200 pages (image shared once) | 342,239 B | 200/200 | 398 | 1,139 | 188 | 169 |
| Compress High (JPEG q0.85, 100 %) on `image_only_2p` (586,365 B) | 194,751 B (-67 %) | n/a, renders | 158 | 101 | 141 | 94 |
| Compress Medium (q0.6, 75 %) | 69,793 B (-88 %) | n/a, renders | 200 | 79 | 106 | 57 |
| Compress Small (q0.4, 50 %) | 34,588 B (-94 %) | n/a, renders | 121 | 76 | 96 | 75 |
| Compress Small on the 200-page text file (no images) | 281,808 B (no growth) | 200/200 | 120 | 363 | 60 | 57 |

\* API 34 ran with two other emulators on the host.

- **Visual check (API 37 PNGs):** the rotated page shows upright-to-landscape correctly and page 3 keeps its
  original rotation; the inserted landscape page sits at position 2; the burned-in signature is drawn where
  placed; compressed scans render. (The platform renderer does not draw annotations without `RenderParams`
  flags, so annotation appearances were checked by subtype and `/AP`, not by PNG.)
- **Init and memory:** `PDFBoxResourceLoader.init()` 2-4 ms; default main-memory mode; emulator heap limit
  192 MB; no out-of-memory on any 200-page operation.
- **Compress note:** `PDImageXObject.getImage()` returns an ARGB bitmap; pass an opaque copy
  (`setHasAlpha(false)`) to `JPEGFactory`, or it adds a lossless alpha mask and the file grows (first run: 780 KB
  for "High"). HOM-31A must do the same.
- **Text extraction for search/QA:** `PDFTextStripper` skips text on `/Rotate` pages; use the platform (API 35+)
  or test rotated pages separately.

### App size (route (b))

Measured on signed, zip-aligned APKs built from the same manifest; there is no native code, so **the cost is the
same for arm64-v8a, armeabi-v7a and x86_64**. bundletool was not run; per-ABI AAB splits would each carry the
same ~2.0 MB, because nothing in the library is ABI-specific.

| APK | Bytes |
|---|---|
| Baseline: same instrumentation APK without PdfBox (R8) | 8,595 |
| With PdfBox-Android + BouncyCastle, **R8-minified** | 2,063,937 (**+2,055,342, about 2.0 MB**) |
| With PdfBox-Android + BouncyCastle, D8 only (no shrinking) | 4,460,097 (+4.45 MB; dex 6.5 MB uncompressed) |

R8 build breakdown (compressed / uncompressed in the APK): dex 332 KB / 695 KB (BouncyCastle shrinks to 168
classes kept by the library's security-handler rule); CJK CMap assets 1,239 KB / 3,227 KB; LiberationSans
fallback font 209 KB / 401 KB; AFM metrics, glyph lists and other assets 197 KB / 898 KB. The CJK CMaps are about
60 % of the cost; they are needed to parse CJK text fonts, so trimming them is possible only with a test on CJK
PDFs (not done here; don't trim by default).

## Route (a) results (platform + Jetpack), from the first run

Platform API surface (`android.jar` and `api-versions.xml` for 35, 36, 36.1, 37.0): `PdfRenderer` (render, API 21),
`android.graphics.pdf.PdfDocument` (draw new pages, API 19), text/search/selection and `PdfRenderer.write()` (API 35,
or `PdfRendererPreV` on 31-34 with S-ext 13), annotations (Highlight, FreeText, Stamp only) and page objects
(API 36.1 or S-ext 18). **No API on any version inserts, imports, moves, deletes or rotates pages, sets `/Rotate`
or recompresses images.** `androidx.pdf` is a viewer on the same service (from its published API; not downloaded).

| Tool | Route (a) raster (any API) | Route (a) "rebuild" by copying page objects (S-ext 18) |
|---|---|---|
| Merge 200 + 3 | **0/203 tokens**, 61.2 MB, 14.8-29.9 s | 203/203, 4.3 MB, 528 s |
| Split 1-100 | **0/100**, 30.2 MB, 6.0-12.8 s | 100/100, 2.1 MB, 99 s |
| Reorder / delete | **0 tokens** | kept on the fixtures |
| Rotate | **0 tokens** | no `/Rotate` API; existing `/Rotate` dropped |
| Annotate / stamp | **0 tokens** (burned as pictures) | `write()` path keeps text: PASS on S-ext >= 18 only, Highlight/FreeText/Stamp only |
| Compress | 50 dpi: -41 % but text lost; 72 dpi: larger | **0 image objects exposed**, no change |

The rebuild only exposes text, image and path objects and the 4 standard fonts; scans came out blank (0 image
objects), only Highlight survived of the 7 annotations, and time grows super-linearly. **Platform bug:**
`PdfRenderer.Page.getPageAnnotations()` throws `NullPointerException: Page object should not be null` (inside the
native call, from `StampAnnotation.addObject`) on `annotated_2p.pdf` page 2 (Ink, FreeText, Stamp with `/AP`);
uncaught it kills the process. Seen again on the route (b) outputs that contain those annotations, so it is the
platform reader, not the files. HOM-25 must guard that call.

## Criteria summary

| Criterion | (a) platform + Jetpack | (b) PdfBox-Android 2.0.27.0 | (c) PDFium |
|---|---|---|---|
| Text stays selectable | **FAIL** for page tools and compress on every version; PASS for annotate/stamp on S-ext >= 18 only | **PASS** for every tool on API 28, 29, 34, 37 | not measured, not approved |
| AAB size per ABI | 0 bytes | **+2.0 MB per ABI** (R8), same for every ABI; +4.45 MB unshrunk | not measured, not approved |
| Minimum API | page tools: none; annotate: S-ext 18 | **library minSdk 14; ran on API 28** (lowest AVD here); app minSdk 24 is covered | not measured, not approved |
| 200-page timings | raster merge 14.8-29.9 s and 61 MB; rebuild 528 s | **merge 73-95 ms, split 142-215 ms, rotate 48-62 ms, delete 48-124 ms, sign every page 169-398 ms** (API 28-37; up to 1.1 s under host load) | not measured, not approved |
| Licence | platform | Apache-2.0; BouncyCastle MIT-style | not measured, not approved |
| Verdict | **FAIL** | **PASS** | not measured, not approved |

## Other findings

- `tool/make_fixtures.py --check` reports `image_only_2p.pdf` and `fixtures.json` stale on Windows
  (Python 3.14.6). The committed files are intact (sha256 match); Flate output depends on the local zlib, so
  `--check` is only byte-exact on the Mac.
- The API 34 emulator image reports S-ext 7, so `PdfRendererPreV` (S-ext 13) is missing there; don't count on
  platform text extraction below API 35.

## For HOM-28A onwards (Android)

1. Add `com.tom-roush:pdfbox-android:2.0.27.0` (and its BouncyCastle 1.72 dependencies) to
   `PDF/android/build.gradle.kts` only; record it in `LICENSE-THIRD-PARTY` and the install-size records (ARCH:
   "PDF library, recorded per ABI": 2.0 MB each, R8).
2. Call `PDFBoxResourceLoader.init(context)` once at plugin start (2-4 ms).
3. Keep the library's consumer `proguard.txt` and add `-dontwarn` for `javax.**`, `java.awt.**`,
   `org.bouncycastle.**`, `com.gemalto.jp2.**`, `org.apache.**` (as in `probe_b/proguard-rules.pro`).
4. Run tools off the main thread (they are fast, but 200-page saves can take 0.2-1 s on a busy device).
5. The Mac copies this report into `docs/v1.2/files-media-home/spikes/HOM-27-android-pdf-write.md` (HOM-28)
   and updates D-98j and V2-V6.

## Reproduce

```sh
source ~/danaview_env.sh
bash spikes/android_pdf/tool/build_probe.sh                       # route (a): build/probe.dex
bash spikes/android_pdf/tool/run_probe.sh emulator-5556 api37     # route (a) run
bash spikes/android_pdf/tool/build_probe_b.sh                     # route (b): needs build/m2/ (see the table above)
bash spikes/android_pdf/tool/run_probe_b.sh emulator-5556 b_api37 # route (b) run
bash spikes/android_pdf/tool/run_probe.sh emulator-5556 chk verify <dir of pdfs>   # platform text check (API 35+)
```
