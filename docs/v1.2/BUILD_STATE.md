# Danaview 1.2.0 build state

Delivery by release slice (BUILD_PLAN §1A). Branch `v1.2-wip`; Android lane `origin/v1.2-android`.
Last update: 2026-10-22 (S2 Mac half complete).

| Slice | State | Notes |
|---|---|---|
| **S1** Foundations + speed test | **Done on both platforms** (owner items open) | Mac: AIS-01, INT-101, HOM-01, HOM-16, ST-01…ST-05, S1-W, S1-Q Mac half, S1-R iOS candidate. **Android (Windows, 968a10e):** S1-Q Android half green (v1.1 suite 17/18 + 4/4 extras with every 1.2 flag off; s13 only on emulator mic silence, accepted), S1-R Android candidate 1.0.0 (1) AAB 95.4 MB passes check_native_libs.sh, release APK smoke green. Device observations to confirm: OBS-S1A-1 (release player barely advanced the 1080p fixture on the emulator), OBS-S1A-2 (VIEW intent to the running app stays on Home). Windows-host test portability FIX-S1Q-A1…A5 being fixed on the Mac. Owner items: legal date, Q-S1 wording, M-Lab store answers, signing, upload (at the 1.0.0 release). Report: `qa/S1-QA.md` |
| **S2** Photos & Files Home | **Done on both platforms** (owner items open) | Mac half as before (S2-Q green, S2-R iOS candidate, FIX-S2R-1, D-7). **Android (Windows, `f125f8c`):** D-3, HOM-02A, HOM-04A, HOM-20A, HOM-22A; D-7 verified; S2-Q Android half green (S2 E2E on API 35, full v1.1 suite with the flag 17/18 + 7/7, bmgr backup checks); S2-R Android AAB 101.0 MB (+5.5 MB), native-lib checks pass, release smoke green. Open, low: FIX-S2Q-A1 (E2E expects the platform's primary save target), FIX-S2Q-A2 (e2e_android.sh define pass-through), OBS-S2A-1 (picker names), OBS-S2A-3 (video-only album chips). Report: `qa/S2-QA.md` |
| **S3** Documents: view and share-in | **Done on both platforms** (2026-10-23) | Mac half as recorded (S3-Q green, iOS RC 26.06 MB). **Android (Windows, 90c7a5b7):** HOM-25, HOM-21A (flag-gated alias); S3-Q Android green (S3 E2E with real intents, v1.1 suite with the flag, flag-off check, tablet grids); S3-R Android AAB 108.2 MB (+7.2 MB), native-lib checks pass. FIX-S3Q-A1 (Office MIME by extension) and A2 (PdfBox-Android + Bouncy Castle licences) fixed. Low items carried to S4. Report: `qa/S3-QA.md` |
| **S4** Documents: PDF tools | **In progress** | Mac half: HOM-31 compress (see "S4: HOM-31 compress" below); **HOM-28 page tools built** on `s4-hom28` (see "S4: HOM-28 page tools" below). Android: HOM-28A, HOM-31A to do (contracts below). |
| S5–S9 | Not started | |

## S4: HOM-31 compress (Mac half, 2026-10-30, branch `s4-hom31`)

**Built.** A compress sheet (`danaview_documents/lib/src/pdf/compress/`): the size now, High quality /
Medium / Small with each preset's estimated ("about 3.1 MB") or measured size, one Compress button,
a cancelable progress bar, then "Saved as “<name> (compressed).pdf”" with before → after and the
saving, or "This PDF is already as small as <preset> can make it. Nothing was saved." (no file is
kept). The result is imported as a NEW library file next to the original (the original's folder;
`Imported` for a linked-folder PDF; a clash gets " (2)"); the original is never modified (G-H6).
Entry points, behind `DANAVIEW_FILES_HOME` (defaults unchanged): "Compress…" in the PDF viewer's
top-bar menu (with the password the file was unlocked with) and HOM-22's file menu of a PDF
(`FileAction.compressPdf`, `compressPdfHandlerProvider`), shown only when the plugin lists
`PdfTool.compress`.

**Apple engine (`danaview_pdf/darwin/Classes/Compress/`).** Stage 1: PDFKit
`write(to:withOptions:)` with `saveImagesAsJPEGOption`, plus `optimizeImagesForScreenOption` (about
144 dpi) for Medium and Small, on iOS 16.4+ / macOS 13.4+ (the options' real availability; the plan
said 16 / 13). Stage 2 (`PdfImageRewriter`): PDFKit has no JPEG quality and a single resolution
step, so High collapsed into "no change" for PDFs of camera JPEGs (measured: 4,852,207 → 4,852,330
B); the image XObjects of stage 1's file (Quartz writes a classic xref table) are re-encoded at the
preset's quality and scale (High q0.75 ×1, Medium q0.6 ×1 after the screen step, Small q0.45 ×0.67
after it; below 16.4 / 13.4 stage 2 alone with ×0.75 / ×0.5), every other object copied byte for
byte, an image replaced only when that saves ≥ 10 %. CMYK, indexed, masked, decode-array and
soft-mask images are left alone; JPX / JBIG2 / CCITT pass through. Encrypted files are compressed
from an unencrypted page copy (PDFKit writes an unlocked document back encrypted, which stage 2
can't read) and written back encrypted with the same password. Off the main thread, cancel polled
before each stage, per image and before the write; only `outPath` is written, once, at the end.

**[VERIFY: HOM-31] closed: PDFKit's options alone do not hit the targets** (no quality control,
High = no change on JPEG PDFs); with the stage-2 image re-encoder they do. Measured (XCTests,
generated fixtures, `run_compress_xctests.sh`; iPhone 17 Pro simulator, iOS 26.5, and macOS 26):

| Fixture (3 pages) | Before | High | Medium | Small | Text |
|---|---|---|---|---|---|
| Scanner style: 300 dpi Flate bitmaps + a text line | 28,196,240 B | 4,042,875 (−85.7 %) | 181,269 (−99.4 %) | 67,738 (−99.8 %) | token found on every page |
| Camera style: the same as q0.92 JPEGs | 4,847,623 B | 3,972,453 (−18.1 %) | 187,741 (−96.1 %) | 68,003 (−98.6 %) | token found on every page |
| Text only (40 lines a page, no images) | 13,708 B | 13,870 | 13,870 | 13,870 | selectable (`PDFPage.selection(for:)`) and searchable (`findString`) with every preset; +162 B, so the sheet says "not smaller" and saves nothing |

(macOS: scan 28,200,824 → 4,039,991 / 191,470 / 72,215; camera 4,852,207 → 3,942,754 / 201,254 /
72,745; text 20,642 → 20,793.) Rendered pages differ from the source by a mean 0.1–0.6 / 255.
Stage 2 alone (the < 16.4 path) on Quartz Flate images: 5,377,298 → 106,716 B (Medium fallback).
Estimates: exact for ≤ 4 pages; a 9-page file sampled from 4 pages estimated Medium at 508,728 B
vs 501,594 B written.

**API surface.** Pigeon: an additive block `PdfCompressEstimateMsg` + `PdfCompressHostApi.estimate
(PdfToolInputMsg)` at the end of `pigeons/pdf_api.dart` (generated Dart / Swift / Kotlin regenerated,
additions only); the job itself is the frozen `PdfToolsHostApi.compress` / `cancel` with
`toolProgress` events (`PdfJob.progress(fraction:pagesDone:pagesTotal:)` added for non-page
progress). Dart (`danaview_pdf`): `PdfCompressPreset`, `PdfCompressEstimate`, `PdfCompressOutput`,
`PdfCompressEngine` (estimate / compress(jobId, path, preset, outPath, password, onProgress) /
cancel), `PlatformPdfCompressEngine`. `danaview_documents`: `showPdfCompressSheet`,
`PdfCompressPanel`, `PdfCompressController`, `PdfCompressSave`, `compressedPdfName`,
`PdfViewer.onCompress` / `pdfViewerBuilder(onCompress:)` (`PdfCompressLauncher`). App wiring
(`lib/wiring/documents_wiring.dart`): `pdfCapabilitiesProvider`, `pdfCompressEngineProvider`,
`saveCompressedPdf` (ImportService, staged copy, keep-both), `pdfCompressLauncher`,
`compressPdfHandler`.

**Tests.** XCTests: `Tests/Compress/run_compress_xctests.sh macos | ios "<simulator>"` (9 core
tests: shrink per preset and High > Medium > Small, same picture, text selectable and searchable,
stage 2 alone on Flate, encrypted stays encrypted, estimates, cancel at every poll leaves no file
and no temp directory, typed errors) and 3 glue tests in `Tests/Compress/Glue/` run by
`Tests/Viewer/run_xctests.sh macos` (tool listed, compress over Pigeon, cancel → `cancelled` and no
file, estimate API). Dart: `danaview_pdf/test/compress` (wrapper), `danaview_documents/test/pdf/
compress` (idle, running, cancel, done, not smaller, error with a fake engine; closing mid-run
cancels; the viewer's menu entry; overflow + 44 pt + labels at 280 / 375 / 1280 × 0.85 / 1.35 in
every state), `test/v12/wiring/s4_compress_wiring_test.dart` (flag off/on, platforms, file menu,
a real library save next to the original). HOM-24's surface test now lists `PdfCompressHostApi`
and no longer treats Compress/ as a placeholder; the architecture test allow-lists the one XCTest
measurement print (`hom31MeasurementLine`, counts only).

**Android contract for Windows' HOM-31A** (PdfBox-Android 2.0.27.0 per HOM-27):
- Implement `PdfToolsHostApi.compress` in `android/.../pdf/compress/` (rule 27's tool directory):
  open the input read-only (password from `PdfToolInputMsg.password`), write only `outPath`, which
  must not exist (`invalidArgument`), once at the end; on cancel (`cancel(jobId)`, polled per image)
  or failure delete it and answer `cancelled` / a typed code; reply `PdfToolResultMsg(outPaths:
  [outPath], pageCounts: [n], sizesBytes: [size])`; emit `toolProgress` with `fraction` 0…1.
- Re-encode image XObjects only (`PDImageXObject` → opaque copy `setHasAlpha(false)` →
  `JPEGFactory`, as HOM-27 found); keep text, fonts and vectors; skip CMYK / indexed / masks /
  1-bit; replace an image only when it saves ≥ 10 %. Presets as the Apple engine's intent (High
  full resolution at high quality, Medium ~144 dpi, Small lower again; HOM-27 measured q0.85/100 %,
  q0.6/75 %, q0.4/50 %; Apple's ImageIO quality scale differs from Java's, so tune by result: outputs
  must shrink High > Medium > Small on an image-heavy file). An encrypted input stays encrypted
  with its password.
- Report `PdfToolKindMsg.compress` in `capabilities().tools`: the viewer's "Compress…" and the file
  menu action appear only then (the app wiring already handles Android).
- Optional: `PdfCompressHostApi.estimate` (register `PdfCompressHostApi.setUp`). Unregistered, the
  Dart side gets `channel-error`, shows no estimates and sizes appear after a run. If implemented:
  exact for ≤ 4 pages, else from 4 evenly spread pages scaled by the file size.
- Never return a larger file as an error: the sheet compares sizes and says "not smaller".

**Open.** Real-world PDFs (Office exports, phone scans) still to be measured on a device in S4-Q
(only generated fixtures here, no downloads). iOS 15.x–16.3 devices take the stage-2-only path
(covered by `testRewriterAloneRecompressesQuartzFlateImages`, not run on an iOS 15 simulator).
Very large files are processed in memory (stage 1's file is read into memory and the output is
built there). The compressed copy's source label in File info is "Files" (no PDF-tool source hint in
the library schema).

## S4: HOM-28 page tools (Mac half, 2026-10-30, branch `s4-hom28`)

**Built.** Behind `DANAVIEW_FILES_HOME` (`lib/wiring/pdf_tools_wiring.dart`; nothing with the flag off).
- **Native (iOS/macOS, PDFKit):** `darwin/Classes/Tools/PdfPageToolsCore.swift` (Flutter-free) and
  `PdfPageTools.swift`: merge (PDFs, and images as pages: orientation applied, ≤ 4096 px, page long
  side 842 pt, opaque images embedded as JPEG), split (ranges), reorder / rotate / delete, and a
  one-pass **organise** (any mix of reorder, rotate, delete, extract). Background queue, per-page
  cancel and progress, sources opened read-only, outputs must not exist and are deleted on cancel
  or failure; permissions that forbid page assembly answer `unsupported`. Capabilities report
  merge, split, reorder, rotate, deletePages.
- **Pigeon amendment** (own block, lead-approved): `PdfPagePlanMsg`, `PdfOrganiseRequestMsg`,
  `PdfOrganiseHostApi.organise`; jobs share `PdfToolsHostApi.cancel`; progress events carry
  `tool: reorder`.
- **Dart API** (`danaview_pdf/lib/src/pdf_tools.dart`): `PdfPageTools` (merge, split, reorder,
  rotate, deletePages, organise) returning `PdfToolJob` (id, progress stream, result, cancel);
  shared validation (`invalidArgument` before the engine), `parsePageRanges`, `rangesEvery`,
  `reorderPlan` / `rotatePlan` / `deletePlan`, `canOrganise(tools)`.
- **UI** (`danaview_documents/lib/src/pdf/organiser/`): the page organiser (thumbnail grid from the
  viewer's thumbnail API, selection, drag to reorder with pointer or long press, screen-reader
  move/rotate actions, toolbar Select all / Rotate / Delete / Extract / Split, Save), the Split
  sheet (ranges, every N pages), the merge screen (order, remove, Add files picker, passwords) and
  the progress sheet with Cancel. Entry points: the PDF viewer's "Organise pages" button and
  "Merge with…" menu item (`PdfToolsScope`), a PDF's file menu ("Organise pages", "Merge with…",
  `FileAction.organisePages` / `mergeWith`), and the multi-select "Merge into PDF".
- **Saving:** results are imported as NEW files next to the original (`Report (edited).pdf`,
  `Report (pages 1–3).pdf`, `Report (merged).pdf`), linked/incoming files into `Imported`. "Replace"
  only for a Danaview folder file: `LibraryWriter.replaceEntryFile` copies the finished file into an
  `imports/` part and renames it over the entry's file (same id, name, folder, favourite, refs;
  crash-tested at every step).

**Tests.** XCTests for every operation on macOS and the iOS Simulator (`run_xctests.sh macos |
ios-sim`, iPhone 17): text stays selectable after merge, split and organise (PDFKit finds and
selects each page's token), sources unchanged, cancel/failure leave no file, HOM-27 fixtures
(200 pages + `/Rotate` partner) keep text and rotation; glue tests through Pigeon. Dart: API
contract with fake host APIs, organiser/merge widget tests, save rules over a real library, the
280/375/1280 px × 0.85/1.35 overflow and a11y matrix, root S4 wiring test.

**Android contract for Windows' HOM-28A** (PdfBox-Android 2.0.27.0 per HOM-27), in
`android/.../pdf/tools/PdfPageTools.kt` (rule 27's tool directory):
- Implement `PdfToolsHostApi.merge / split / reorder / rotate / deletePages` and register
  **`PdfOrganiseHostApi`** (`organise`) in `DanaviewPdfPlugin.kt`; organise jobs use the same job
  registry so `PdfToolsHostApi.cancel(jobId)` stops them.
- Every request: open inputs read-only (`PdfToolInputMsg.password` for encrypted files; a missing or
  wrong one → `passwordRequired`); each output path must not exist (`invalidArgument`) and its
  folder must (`notFound`); write each output once at the end; on cancel (poll per page) or failure
  delete every output and answer `cancelled` / a typed code; reply
  `PdfToolResultMsg(outPaths, pageCounts, sizesBytes)` in request order; emit `toolProgress` events
  (`jobId`, `fraction` 0…1, `pagesDone`, `pagesTotal`; organise uses `tool: reorder`).
- Semantics (match `PdfPageToolsCore.swift`): merge needs ≥ 2 inputs, keeps the first PDF's metadata,
  `isImage` inputs become one page each (EXIF orientation applied, longer side 842 pt, ≤ 4096 px,
  opaque → JPEG); split writes `ranges[i]` (`[start, end)`, may overlap) to `outPaths[i]`; reorder's
  `order` is a permutation; rotate adds `degrees` (multiple of 90, may be negative) to the pages'
  `/Rotate`; delete keeps ≥ 1 page; organise writes `pages` in order, each `rotation` added, pages not
  listed dropped, no page twice, ≥ 1 page. Text must stay text (page content streams copied, never
  rasterised). Respect "no page assembly" permissions with `unsupported`.
- Report merge, split, reorder, rotate, deletePages in `capabilities().tools`: the Android UI
  (viewer button, file menu, Merge into PDF) appears only then; Dart already validates requests and
  handles everything else.

**Open.** An encrypted source's output is written without encryption (PDFKit `write(to:)` without
owner password); decide in S4-Q whether to re-encrypt with the user password. Very large merges
are built in memory by PDFKit. Real-world PDFs to be measured on a device in S4-Q. Android HOM-28A.

## Spikes

| Spike | Result | Open |
|---|---|---|
| AIS-42 Genkit | **No-go**: `danaview_ai_genkit` not created; providers stay on the own adapters (`ai-studio/spikes/AIS-42-genkit.md`) | ARCH V2-203 to record the no-go |
| AIS-44 diarization (Mac half) | Models go (TitaNet-small + pyannote 3.0 int8, RTF 0.094, overlaps kept); **iOS size no-go** with stock sherpa-onnx (+26 MB) (`ai-studio/spikes/AIS-44-diarization.md`) | Owner: Core ML conversion spike (needs coremltools) vs slim build vs +26 MB; TitaNet licence; model hosting; real-speech eval clips. Android half **GO** (87fef930, report §10): matches the Mac's DER |
| HOM-27 Android PDF write | **Decided**: PdfBox-Android 2.0.27.0 (route b), +2.0 MB, every operation passes on API 28–37 (`files-media-home/spikes/HOM-27-android-pdf-write.md`) | |
| VED-33A face tracking (Android) | **Done** (f256d500, `spikes/face_android/REPORT.md`): MediaPipe Tasks Vision 0.10.35, +5.0 MB arm64, the same library as iOS; LiteRT 2.3.0 fallback; ONNX Runtime no-go on size; synthetic heads for committed landmark dumps (no landmarks of the real Pexels people kept) | VED-33 (iOS half) in S8 |
| VED-33 | Waits for VED-33A | |

## Open follow-ups
- **CI on hosted macos-26 (2026-10-23):** the self-hosted Mac runner was never registered, so iOS/macOS jobs queued forever; they now run on GitHub's free hosted macOS (golden jobs too: goldens are rendered on macOS). Still red, tickets:
  - FIX-CI-1 (iOS RunnerTests): `ChannelRoundTripTests.testCapabilitiesRoundTripWithThePlaceholderEngine` and `testPlaceholderServicesFailWithNotSupportedOnDevice` fail on the hosted runner (the cause is hidden by `-quiet`; run without -quiet first).
  - FIX-CI-2 **FIXED** 2026-10-23 (6890d05 on editor-wip, merged forward): the Silero VAD ran with the job's thread count; on a busy or oversubscribed CPU the spinning threads made it 300-500x slower (a real product bug on device too). It now runs single-threaded, the fastest setting measured. CI whisper-host is green on all 4 legs. Follow-up (low): cap the whisper TEST default of 4 threads to the core count on the 3-vCPU macOS runner. Was: `Detect.vad_locates_the_first_speech` and `Real.silero_vad_transcription_and_detection` run 300-500x slower than on Linux (204 s vs 0.6 s; 639 s vs 17 s), CPU path, Metal off. Check the macOS test build's optimisation flags and the NEON/Accelerate paths; it may affect iOS Auto captions.
  - The free plan allows 5 concurrent macOS jobs; a full run uses 6.
- FIX-S1R-1 (INT-05 / release integration, AIS-41): `ios/fastlane/Fastfile` `flutter_ipa` and `android/fastlane/Fastfile` `flutter_aab` pass no release dart-defines (`DANAVIEW_EDITOR`, `DANAVIEW_AUTO_CAPTIONS`, the slice's 1.2.0 flags) and default the build number to 1 / a timestamp / next TestFlight instead of the pubspec; blocks signing through any lane (manual commands in `qa/S1-QA.md` §Signing). S1 candidate commit: `f865874` signed at `1.0.0+1`.
- `legalEffectiveDate` to the S1 candidate's date, owner review of the privacy wording (Q-S1) and the store answers for M-Lab: at S1-R.
- No CI path filter runs `packages/danaview_data` tests (low; review finding).
- `cue_list_performance_test` (8 ms budget) is flaky under `-j 2` on the 8 GB Mac; passes alone.
- Owner questions Q-A1…Q-A10 (ARCH v1.2 §16) still open; recommendations used as working defaults.
- **DV_PERF_STRICT on Android (CI round 6):** every absolute timing, frame-count, throughput or GPU-speed limit in the Android instrumented and JVM unit tests, and the ±25 % export bitrate of the conformance / preset_matrix suites, applies only with `DV_PERF_STRICT=1` (a quiet machine or a real device). Without it (the CI emulator: software GPU and AVC encoder) the limit is a 4x floor, a same-run baseline or a non-vacuity minimum (`harness/PerfGate.kt`), and the bitrate only has to be non-zero and within 0.5x–1.6x of the request (logged as `QA11|bitrate`). Correctness (wrong frames, colours, crashes) fails in both modes; no test is skipped. CI leaves it unset. `android_emulator.sh` passes it on as the instrumentation argument and as `--dart-define`; JVM unit tests read the environment variable.
  - **Strict preset matrix on a real Android device (Windows lane, the tablet):** with the tablet attached (`adb devices` lists its serial), from Git Bash at the repo root:
    `cd packages/danaview_editor_engine/example && flutter test integration_test/preset_matrix_test.dart -d <serial> --dart-define=DV_PERF_STRICT=1`
    Every `QA11|preset` row must show `bitrateStrict=true` and a `bitrateRatio` within 0.75–1.25. The whole strict device run (instrumented batches and every suite): `DV_PERF_STRICT=1 ANDROID_SERIAL=<serial> bash scripts/ci/editor/android_emulator.sh`.
- **DV_PERF_STRICT on iOS, macOS and the Dart tests (CI round 6), the same rule:** every absolute timing or throughput budget in the iOS RunnerTests (`RunnerTests/Support/PerfGate.swift`: preview patch and transient latency, compositor redraw and compose, 2,000-item build, probe, thumbnail and freeze-frame cache hits, quick hash, waveform and speech throughput, voice start latency) and in the Dart host and device tests (`_perfStrict` per file: the editor_core benchmarks, sprite prepass, name search, caption segmenter, text overlay, dry-run, regenerate sheet, photo masonry, whisper FFI, AI captions) applies only with `DV_PERF_STRICT=1`. Without it the budget is 4x as generous, or a same-run baseline (cache hit vs the miss, fragment cache vs a cold encode, compose vs a plain 1080p frame). The measurement always runs and is printed; correctness fails in both modes; no test is skipped. The shared conformance / preset_matrix bitrate rule above (±25 % only when strict, else 0.5x–1.6x) holds on iOS too. CI leaves it unset. How to set it: host Dart tests read the environment (`DV_PERF_STRICT=1 flutter test …`); device suites read `--dart-define=DV_PERF_STRICT=1`; RunnerTests read it from the test process (`TEST_RUNNER_DV_PERF_STRICT=1 xcodebuild test …`); `DV_PERF_STRICT=1 bash scripts/ci/editor/ios.sh` does both. macOS has no timing assertions (`macos/RunnerTests`). Functional deadlines (a cancel that must not wait for a blocked read, a timeout that must fire) are not perf budgets and stay absolute.
- **Export audio dropouts are never shipped (iOS, CI round 6):** an audio read with a time-pitch fault (exact-zero dropout or dropped ramp-seam crossfade) is redone up to 4 times on a fresh composition (a fresh time-pitch unit), after a 0.25/0.5/1/2 s back-off; if the last read still has one, the export fails with a retryable `decodeFailed` ("audio time-pitch fault in all 5 audio reads …", the UI's "The export didn't finish / Try again") and no file is written. A fault that every witness read reproduces at the same place (at least 4 reads, the last included; a read rejected for NaN, silence, a tap range jump or an early end is no witness) is the content (digitally gated audio, a transient on a seam) and is kept. Before, the third faulty read was shipped (run 40741900194: the ramp's tone at −18.4 dB). A read resumed after AVFoundation's hang stopped early (run 40806183679: a 9.95 s audio track under the soak's 39 s video): an AVAssetReaderAudioMixOutput whose range starts inside the timeline ends at the end of whichever track's media ends next (soak on the iOS 26.5 simulator: from 9 s it ended at 10.0 s, from 11 s and 14 s at 17.0 s, from 10 s and 18 s it delivered nothing; from 0 it reads all 39 s). A resume now reads the whole range again on a fresh reader and drops the frames already written (`ExportD7Tests.testHungMixReadPastTheEndOfATrackResumesToTheEnd`, which failed with the old resume: "ended early at 17.02 s"). A read that still ends more than 50 ms early is rejected and never shipped, not even on the last attempt.
