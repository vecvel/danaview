# Danaview Editor: Architecture (single source of truth)

> **Release:** Danaview 1.1.0, "Editor". **Date:** 2026-10-07. **Baseline:** `main` @ `19cae59`, Flutter 3.44.2, Dart 3.12.2, Xcode 26.6, AGP 9.0.1, Kotlin 2.3.20.
> **Status:** approved by the lead architect; revised 2026-10-08 after the architecture review (decisions D-35 to D-44; resolutions listed in `BUILD_PLAN.md` §11). Implementation follows `docs/v1.1/editor/BUILD_PLAN.md`.
> **Authority:** this document wins over `BUILD_PLAN.md`, and both win over the area designs in `docs/v1.1/editor/design/` (`domain.md`, `native.md`, `ux.md`, `ai.md`). The area designs remain the detailed reference for anything this document doesn't restate; §2 lists every point where they disagreed and how it was settled. Later changes to this file are made only by tickets marked **[INTEGRATION]**.
> **Corrections to the brief, confirmed in the repo:** the iOS bundle id and the Android `applicationId`/namespace are both `com.vecvel.danaview` (not `com.vecvel.danaviewplayer` / `com.vecvel.danaview`). Android `minSdk = flutter.minSdkVersion`, which is **24** in Flutter 3.44.2, not 21. The iOS deployment target is 13.0 today and this release raises it to 15.0 (§3).

---

## 1. Goals, non-goals, product rules

### 1.1 Goals

| # | Goal | Where it is guaranteed |
|---|---|---|
| G1 | Every feature in the owner's list ships in **one release** on iOS and Android | `BUILD_PLAN.md` coverage table |
| G2 | **Non-destructive editing.** Original media is never modified, moved, renamed or deleted | §9.6 `OwnedFileDeleter`, read-only native opens, §20.1 |
| G3 | Production reliability: autosave, crash recovery, schema migration, typed failures, no editor action can crash the app | §8, §19 |
| G4 | **Frame-accurate seeking and A/V sync.** Preview equals export on each platform; iOS and Android match within the parity tolerance | §5, §11.5, §11.7, §21.3 |
| G5 | Smooth on low-tier phones (4 GB Android, iPhone SE 2) at the budgets in §18 | §18 |
| G6 | Privacy: everything on device. The only network use is the speech-model download, after explicit consent | §16.3, §20 |
| G7 | Desktop editor later **without UI or core changes**: a desktop engine implements the same API | §25 |
| G8 | The owner's standing UI rules (below) hold on every editor surface | §17.9, QA-08, QA-09 |

### 1.2 Non-goals for v1

- A desktop editor engine (macOS/Windows/Linux). Entry points are hidden there (§3.3).
- FFmpeg anywhere in the editor. Containers the platform can't decode are refused with a clear message (iOS: MKV/WebM/AVI).
- HDR export (SDR BT.709 only; HDR sources are tone-mapped), MOV on Android (Media3 has no MOV muxer), non-integer project frame rates (23.976/29.97/59.94 sources conform to 24/30/60).
- AI features other than subtitles: no translation, diarization, summaries, auto-edit or cloud fallback.
- Keyframe easing curves (linear only), video "animation" presets, an audio limiter, text placed *behind* a picture-in-picture overlay (§11.4 band order), drop-frame timecode, editing while an export runs, collaboration, persisted undo history, telemetry or remote config.

### 1.3 Owner's standing UI rules (binding on every ticket)

1. Custom components only. No Material chrome: `AlertDialog`, `Slider`, `RangeSlider`, `ListTile`, `ExpansionTile`, `showDatePicker`, `LinearProgressIndicator`, `CircularProgressIndicator`, `Switch`, `Checkbox`, `PopupMenuButton`, `showMenu`, `MenuAnchor`, `DropdownButton`, `DropdownMenu`, `showModalBottomSheet`, `showDialog`, `Dialog`, `SimpleDialog`, `SnackBar`, `LicensePage`, `TextField`, `TextFormField`, `ElevatedButton`, `TextButton`, `OutlinedButton`, `FilledButton`, `IconButton`, `FloatingActionButton`, `Chip`, `ChoiceChip`, `FilterChip`, `TabBar`, `ReorderableListView`, `Card`. Architecture tests match these as **whole identifiers** (so `DanaviewTextField`, `DanaviewIconButton` and other kit wrappers pass) in `packages/danaview_editor/lib` (UX-01) and in every `danaview_features` file an editor ticket touches (INT-01's `dependency_rules_test.dart`, with a file list and an empty baseline; the existing files have zero matches today). A shared widget-test helper (`expectOwnerUiRules`, UX-01 `test/support/`) fails when a `DanaviewPressable` with a text label has a circular shape, or when chrome text resolves to a family other than Figtree.
2. Solid surfaces, soft shadows only (`DanaviewShadows.subtle/soft`), very low-opacity borders (`DanaviewBorders.hairline`).
3. Text and icon+text buttons use the standard rounded rectangle (`DanaviewRadius`); only single-icon buttons are fully round (`DanaviewIconButton`).
4. Foreground contrast is computed (`DanaviewColors.foregroundOn`), never guessed; ≥ 4.5:1 for text.
5. **Nothing overflows** at widths 280–1280 px and text scale 0.85–1.35 (the app already clamps to this range). Enforced by the layout planner unit tests and the overflow matrix (QA-09).
6. **Figtree is the only UI font.** User content (text overlays, subtitles) may use the curated content-font set in §17.8; that is content, not chrome.
7. Dark UI.

---

## 2. Decision log (conflicts and open questions resolved by the lead)

Each row is final. "Area" names the design doc whose proposal was overridden or confirmed.

| ID | Decision | Resolves | Rationale |
|---|---|---|---|
| D-01 | **RenderPlan v1 is a flat, fully lowered layer list** (domain.md shape). Transitions, fades, text animations, dips, speed ramps and the blurred background are lowered in Dart to layers, piecewise-linear maps, linear keyframes, solids and canvas masks. Engines contain **no transition or text-animation code**. | domain §12 vs native §4.2 (lanes + transition primitives) | Parity by construction: one lowering implementation, golden-tested in Dart, instead of three implementations of seven transitions. Engines get smaller. Android sequences are derived by grouping layers by `z` and interval-colouring, exactly what native planned for lanes. Native's patch classification, wire transport, `.vsprite` and `.vlut` are kept (D-05, D-06, D-07). |
| D-02 | `danaview_editor_core` owns the RenderPlan **Dart types, JSON codec, JSON Schema, validator, compiler, diff and fixtures**. `danaview_editor_engine_api` owns transport (`PlanSync`, isolate encoding), the CPU reference renderer, render-math vectors and render prep (text layout, sprites). Native code owns decoding and rendering. | native §0.2 vs domain §12.8 | The compiler and codec must run in isolates and under `dart test`, so they belong in the pure package. |
| D-03 | **Project and export frame rates are integers**: 24, 25, 30, 48, 50, 60. `FrameRate(num, den)` stays rational in the type (forward compatible) but v1 accepts only `den == 1`. NTSC sources conform to the nearest integer rate. Frame *k* starts at `ceil(k·10⁶/fps)` µs in every plan and model time. **Platform clocks do not use that rounding** (iOS composes frame *k* at the rational time `k/fps`; Media3's clock band stamps it `round(k·10⁶/fps)`), so every platform time is mapped back to a frame index by rounding (`frameIndexNearest`, §5) and evaluated at `timeOfFrame(k)`, never at the raw platform µs (D-35). | native D2 vs domain rational rates | Media3 image items and the Android clock band take an `int` frame rate. One integer grid removes a class of µs drift and makes timecode exact. A 29.97 source in a 30 fps project repeats one frame every ~33 s, which is invisible in consumer edits. |
| D-04 | **Source-frame rule.** Plan maps are **exact (unbiased)**. Normative selection: for a video layer at frame time *t*, display the source sample with the greatest PTS ≤ `map(t) + 500 µs`. Each engine implements the ε its own way (iOS shifts inserted source ranges by +500 µs; Android's mechanism is settled by spike AND-01). Mixed-rate sources (source fps ≠ project fps) may pick a different source frame per platform (iOS floor, Media3 nearest); each platform is consistent between preview and export. | domain §3 (+500 µs baked into the plan) vs native D8 | Baking the bias into maps is wrong for Media3 clipping, which drops samples before the clip start. Keeping the plan exact and the rule normative lets each engine meet it and lets the frame-counter test (QA-03) check it. Cross-platform differences for mixed-rate sources are not user-visible because a user edits on one platform. |
| D-05 | **Text and subtitles in preview are drawn by a Flutter overlay** above the native texture, using the same `TextLayoutEngine` that rasterizes export sprites. Preview plans contain **no** text or subtitle layers. Export plans contain sprite layers. | domain decision 9 vs native §4.7 (sprite bands in preview) | Zero-latency typing and direct manipulation, no preview sprite scheduling, fewer Android sequences (less GPU memory). Layout parity holds because preview, handles and sprites all use one Flutter layout implementation. Consequence: text and subtitles always composite above video and overlays (accepted, O2). |
| D-06 | Export sprites use **`.vsprite` v1** (zlib-compressed premultiplied RGBA, optional u16 glyph-order map) instead of PNG. Typewriter is **one sprite plus a `reveal` animation channel**, not one sprite per step. | native §4.7 vs domain §12.5 | No PNG encode cost in Dart, no ImageIO/BitmapFactory colour-management differences, tiny native decoders. One sprite per text item regardless of length. |
| D-07 | **`.vlut` v1 is native's format**: `'VLUT'`, u16 version, u16 N (2–65), N³ float16 RGB, red fastest, domain already normalized. Engines upload it as a tiled 2D texture. No resampling of 65³ LUTs. Written in pure Dart by `danaview_editor_core` (CORE-21). | domain §11.2 (float32, resample to 64) vs native §4.7 | The tiled 2D texture avoids Core Image's colour-cube limits entirely (domain V5 becomes moot) and needs no GLES 3 3D textures. |
| D-08 | **Effect order** per visual layer: crop → chroma key + spill → grade (exposure → brightness/contrast → highlights/shadows → saturation → temperature/tint) → LUT → blur → sharpen → vignette → mask → place (transform, flip, opacity) → canvas masks → premultiplied source-over. Formulas: §11.6 (native's formulas, restated in model units). | domain §4.6 vs native §4.8 | Keying on **source** colours makes the eyedropper (which samples the pre-key source) and the key agree, and grading can't shift the key. Blur-then-sharpen matches the Android effect chain (blur is its own GL pass before the place shader). |
| D-09 | **Display lane order** (top → bottom): subtitle lanes, text lanes, overlay lanes, extra video lanes, **main video lane**, audio lanes. Higher on screen = higher in the composite. | ux §8.3 vs domain §4.3 | One consistent rule: visual lanes are drawn in reverse z order. |
| D-10 | **Ripple** affects the edited lanes plus lanes of linked partners. No global sync-lock in v1. | domain O1 | Predictable for phone users; linked audio stays in sync. |
| D-11 | Non-ripple moves, pastes and inserts into occupied space go to the **nearest free lane of the same kind, creating one if needed**. Never overwrite. | ux Q8, domain §6.3 | Non-destructive by default. |
| D-12 | A project saved by a newer schema opens **read-only** when `minReader ≤ supported`, and is **blocked** otherwise. | domain O3 | Users can still view and export; saving would drop unknown fields. |
| D-13 | Imports: iOS Photos → **managed copy** (content-addressed); iOS Files → **security-scoped bookmark** (reference); Android Photo Picker/SAF → **persisted URI grant** with managed-copy fallback when < 32 grants remain or the URI isn't persistable; external drops → managed copy. | domain O4, ux Q6 | No photo-library permission needed; Files references save storage; grants are bounded. |
| D-14 | Limits: project ≤ 24 h, ≤ 5,000 items. Two caps, both from `EditorCapabilities`: (1) **concurrent decoder-backed video layers** at any instant (2 minimal / 3 low / 4 mid / 6 high, and on Android ≤ codec instances − 1); (2) **visual sequences** (`maxVisualSequences`): the number of decoder-backed sequences/composition tracks the project needs for its whole duration after packing (§13.5; Android 2 minimal / 3 low / 4 mid / 6 high, each further capped at (codec `maxSupportedInstances` − 2) / 2 because the AND-16 preview engine needs two decoders per slot, set by AND-01's 6-lane sparse-PiP measurement V-N25 and recorded by ENG-06 2026-10-11, re-measured on devices by QA-04; iOS 16). Both are counted in core by one implementation (`eval/visual_packing.dart`, CORE-36) and enforced by `LayerLimits` (CORE-09). Commands that would exceed the item or duration limit return `LimitExceeded(what, limit)`; once CORE-38 lands, the two layer caps never reject a command (owner decision below). A project that already exceeds a cap (opened from another device) opens and shows a banner; **the caps limit live preview only** (owner decision 2026-10-11, D-43(e) point 7): above them preview uses proxies, paused-exact still frames and the render-preview cache, and **export never refuses**: when the plan needs more simultaneous decoders than the device allows, export runs a multi-pass precompose (D-45). **Editing is never blocked by the layer caps either:** CORE-09 shipped command-time enforcement of both caps (`LimitExceeded`), and **CORE-38** (M4) removes it; `LayerLimits` then reports an informational `aboveLivePreviewCap` state (with the counts and caps) that the preview layer (proxies, still frames, render-preview cache) and the export layer (multi-pass precompose) use. Until CORE-38 lands, CORE-09 still rejects such edits. Images, solids and sprites don't count. | domain O5, native D9; review issue 3 | Hard rejection on open would lock users out of their own projects. Decoders, players and GPU passes on Android scale with sequences, not with instantaneous concurrency. |
| D-15 | Speed range **0.1×–10×**, ramps of 2–16 points (the UI edits 3–7). Audio above `capabilities.maxAudioSpeed` (default 4×) is muted for that span and the speed panel says so. | ux Q12 | Matches both engines' stretch limits. |
| D-16 | **Cut = clipboard cut (⌘/Ctrl+X)**; **Split** = blade at the playhead. **Fade** = outgoing fades to the canvas background, then incoming fades in (no overlap); **Cross dissolve** = overlapping blend using handles. | ux Q5 | Distinct, standard meanings for each owner bullet. |
| D-17 | Desktop entry points are **hidden** (no Home edit button, no player Edit, no Settings "Video editor" row, no editor or speech storage contributors). There is no "coming to desktop" teaser and no teaser flag. `/projects` and `/editor/*` redirect to `/` on desktop. Asserted by macOS-targeted widget and route tests in INT-02 and INT-04. | ux Q1, owner decision 1; review issue 29 | Owner allowed either; hidden avoids a dead end and an untested dialog. |
| D-18 | **External drag and drop ships in v1** on iPad/iPhone (UIDropInteraction) and Android (`View.OnDragListener` + drag permissions), in addition to in-app bin → timeline drag. Dropped items become managed copies. | ux Q7 (deferred) | "Drag and drop media" is an owner bullet and the desktop editor is later, so tablets must carry it. |
| D-19 | Auto captions: the user picks the language (device locale preselected). "Detect automatically" is a **secondary** row; low confidence (< 0.6) asks the user to choose from the top 3. | ux Q9 | Owner requires a user choice. |
| D-20 | Model host: **Hugging Face**, pinned revisions (ai.md §5.1). Privacy text names `huggingface.co` and its CDN on `hf.co`. No mirror in v1. Accurate tier hidden on devices < 4 GB RAM. No libmpv audio fallback (no FFmpeg). Leaving the editor stops a job and keeps the checkpoint. Transcripts and models are **excluded from backups**. | ux Q13, ai Q2–Q6 | Verified host, smallest privacy surface, consistent backup policy (all regenerable data excluded). |
| D-21 | `TranscriptionService` adopts ai.md's extended interface (`offers`, `preflight`, `resegment`, `activeJob`, `resumableFor`, `provideLanguage`). | ai Q7 | UX needs every one of them. |
| D-22 | Background export: Android foreground service, type `mediaProcessing` on API 35+ and `dataSync` on API 29–34, with a notification Cancel action; a finished export is saved natively when no Dart listener is attached (D-39). **iOS treats backgrounding as an interruption**: `AVAssetWriter` loses its encoder in the background and cannot resume, so iOS export is **segment-resumable** (closed-GOP video segments + a persisted checkpoint, §14.2): on background the current segment is discarded, and on return the export resumes from the last complete segment and finishes with a passthrough concat. `backgroundKind` is set honestly per device: iPhone = `paused` ("stops in the background and continues where it stopped when you return"); iPad on iOS 26+ with `BGTaskScheduler.supportedResources.contains(.gpu)` and the GPU entitlement = `continued` (`BGContinuedProcessingTask` with `.gpu`). No software Core Image background path unless spike IOS-01 proves the Metal CI kernels run on the CPU renderer (V-N22). Proxy, reverse and freeze jobs follow the same interruption semantics (§15). Request the Apple GPU entitlement now (iPad benefit only). | native D5, D6; review issue 4 | Apple: the asset writer gives up its encoder in the background with no reliable way to continue; background GPU is iPad-only. Honest UX copy. |
| D-23 | Output: MP4 everywhere, **MOV on iOS only**; H.264 everywhere; **H.265 only where a hardware encoder is probed**; SDR BT.709 8-bit. | native D4 | Owner's "where supported". |
| D-24 | Editing is blocked while an export runs (export sheet is modal). | ux Q10 | Encoder and GPU are saturated; simpler state. |
| D-25 | Voice recordings are **WAV PCM s16 48 kHz mono** in the project bundle. | domain (m4a) vs native (WAV) | Lossless, sample-accurate start, no encoder dependency; size (5.8 MB/min) is acceptable for voiceovers. |
| D-26 | One cache layout (§8.1): `<cache>/danaview/editor/{thumbs,waves,proxies,sprites,looks,work}`; cache keys use `MediaFingerprint.quickHash`. | domain §9.1 vs native §8.1 | One place for "Clear editor cache"; caches survive relink. |
| D-27 | `ProjectRepository.save` takes the `EditSession`; `MediaRef` is not used by editor code: use `MediaId` + `ResolvedMedia` (core). `EngineMedia` is a typedef of `ResolvedMedia`; `MediaProbe` exists once (core). Engine-level encode parameters are `EncodeSettings` (core); user-level choices are `ExportSettings` (core). | domain §17 deltas, native §3 | One type per concept across packages. |
| D-28 | `SpeechAudioExtractor` and `BackgroundLeaseProvider` are ports **defined in `danaview_transcription`**; `danaview_editor` adapts them to `EditorEngine.jobs.extractSpeechAudio` and `EditorEngine.background`. | ai §7.1, native §2.3 | Keeps `danaview_transcription` independent of the engine package. |
| D-29 | **iOS deployment target raised from 13.0 to 15.0** (§3.1). Android `minSdk` stays 24; the editor is gated at runtime to API 29+. | native D1, ai Q1, ux Q2 (all proposed keeping 13.0) | Zero devices lost; removes the "app fails to launch on old iOS" risk from two new native modules. |
| D-30 | Font selection uses a curated, bundled set of 10 OFL families for **user content only** (§17.8). | ux Q4 | Reconciles "Figtree only" (chrome) with "Font selection" (content). |
| D-31 | Feature flags (compile time, no remote config): `DANAVIEW_EDITOR` (entry points; default **false** until INT-05 flips release builds to true) and `DANAVIEW_AUTO_CAPTIONS` (default false until QA-07 passes). | ai §18 | `main` stays releasable while ~160 tickets land. |
| D-32 | CI: `editor-ci.yml` runs Dart/Flutter/Android jobs on GitHub-hosted Ubuntu and iOS jobs on a **self-hosted macOS runner** (the dev Mac), with an input to fall back to `macos-15`. | native D7 | Owner cost decision; self-hosted avoids per-minute cost and has Xcode 26.6. |
| D-33 | **Skeleton-first ownership.** Skeleton tickets create placeholders for files that later tickets own (§4.5 and `BUILD_PLAN.md` §2). | — | Lets ~160 tickets run in parallel with exclusive file ownership. |
| D-34 | **Sequencing corrections** made while writing `BUILD_PLAN.md`: `MediaAccessPort`/`PickedMedia` live in `model/pool` (CORE-04) so the engine API can implement them at M0; `ops/limits.dart` is CORE-09 (generic post-command check); keyframe data types are CORE-03; CORE-27 precedes CORE-25; `/settings/editor` and `/settings/licenses` are explicit routes; the privacy-host test is INT-04's. | — | Exclusive ownership and an acyclic, milestone-monotonic dependency graph (validated by script; see `BUILD_PLAN.md` §9). |
| D-35 | **Platform-time rule (normative, §5).** Plans and the model keep the `ceil` grid. Any time that comes from a platform clock or presentation timestamp (iOS `compositionTime`, item time, output-buffer PTS; Media3 effect/compositor `pts`, `onVideoFrameAboutToBeRendered` pts, `currentPosition`) is turned into a frame index with `frameIndexNearest(τ) = round(τ·fps/10⁶)`, and layer activity, gating, keyframe/animation/`reveal` evaluation, `ParamSnapshot` lookup and seek acks all use `timeOfFrame(k)`. iOS expresses every grid time it hands to AVFoundation (edit `at:` points, scaled durations, instruction ranges, spacer) as `CMTime(k, gridFps)`; source ranges stay µs. Android anchors every sequence item and gap boundary at the platform frame time `P(k) = round(k·10⁶/fps)`. Plans carry `canvas.gridFps` (the project rate) so export plans at another output rate keep exact edit points. | review issue 1 (blocker) | With `ceil` edges and platform times rounded differently, layers started, were gated and were acked one frame off at 24/30/48/60 fps (two-thirds of frames at 30 fps). Rounding to the nearest frame is exact because platform and plan times of one frame differ by < 1 µs while frames are ≥ 16,666 µs apart. |
| D-36 | **Android paused-edit path does not use `experimentalRedrawLastFrame`** (Media3 redraws only input 0, our transparent clock band). While paused, param patches, transients, editing modes and structural edits are drawn by our own `PausedFrameRenderer` (AND-17): EXACT source frames from `SourceFrameCache`/`FrameExtractor` for the layers active at the current frame + the same `LayerLook`/blur/`LayerPlace` shaders + premultiplied blend, rendered onto the `SurfaceProducer` with the player surface detached (the `showSourceFrame` mechanism). Active-layer frames are prefetched on pause and after each exact seek settles. Structural patches are debounced (150 ms trailing, 600 ms max wait) and `setComposition` runs in the background while the paused frame stays on screen; the player surface is reattached on play or seek. Android structural budgets are renegotiated (§13.4). The documented no-go path is the contingency engine AND-16 (N `ExoPlayer`s into `SurfaceTexture`s composited by our GL compositor on a frame clock, sharing AND-17's compositor), not the single-input fallback. | review issues 2, 8 | `setComposition` releases and recreates every sequence player and the video graph; redraw only re-renders input 0. The single-input fallback could not preview two-source transitions or video-over-video. |
| D-37 | **iOS applies audio gain per sample in an `MTAudioProcessingTap`** on every `AVMutableAudioMixInputParameters` (preview `AVPlayerItem.audioMix` and export `AVAssetReaderAudioMixOutput.audioMix`), evaluating the plan's `gain` envelope (0–2, i.e. up to +6.02 dB) at composition time; `setVolumeRamp` is not used. The export pump clamps Float32 samples to [−1, 1] before the AAC input (the §11.6 hard clip). Owner: IOS-18. | review issue 5 | AVFoundation mix volume only attenuates (0–1); 200% volume would be silently missing on iOS while Android applies it. The tap is also sample-exact. |
| D-38 | **Every export has an AAC 48 kHz stereo track.** iOS: when `plan.audio` is empty, the pipeline never creates an `AVAssetReaderAudioMixOutput` (an empty track array raises an uncatchable Objective-C exception) and writes silent LPCM across `[0, durUs)` instead. Android: the clock-band sequence is built with `EditedMediaItemSequence.Builder(setOf(TRACK_TYPE_VIDEO, TRACK_TYPE_AUDIO))`, so silence is produced when nothing else is audible; the deprecated `experimentalSetForce{Audio,Video}Track` setters are not used (Media3 1.11 `trackTypes`). | review issues 6, 19 | G3 (no editor action can crash the app) and the §14.4 conformance rule. |
| D-39 | **Export completion without a Dart listener.** `ExportService.start` takes `whenDetached: saveToGallery (default) \| keepForLater`. If a job finishes while no Dart listener is attached (activity destroyed, engine gone), the engine saves natively to the default destination (Android `MediaStore` insert with `IS_PENDING`; iOS `PHAssetCreationRequest` add-only when authorized) and persists a `completed(path?, savedUri?, settings)` record in `ActiveExportStore`; the output file is exempt from the `work/` wipe until the record is consumed or 7 days pass. On the next open, `activeJobs()` returns the record once and UX-39 shows "Your export finished" with Share / Save to Files / Delete. | review issue 7 | The copy promises a notification when the export is done; a finished file must never be wiped unseen. |
| D-40 | **`minimal` device tier instead of a higher device floor.** iOS < 3 GB RAM (A9–A11: iPhone 6s/7/8/SE 1st gen) and Android < 3 GB RAM or `isLowRamDevice` are `minimal`: proxies forced for every video, 2 concurrent video layers, 2 visual sequences (Android; set by ENG-06 2026-10-11, live preview only, D-45), preview long side ≤ 640 px, export ≤ 1080p H.264, Auto captions Fast tier only, `lowMemoryDevice = true` (the player is released during editing). Hard floor stays: iOS Metal device; Android API 29 + GLES 3 + ≥ 2 GB RAM. Minimal-tier promise: no crash or OOM, usable editing, ≥ 24 fps preview at ≤ 2 layers; no other budget. Verified on the iPhone 7 (iOS 15) and iPhone 8 (iOS 16) lab devices and one 2–3 GB Android Go device (QA-04). | review issue 20 | Keeps the owner's reach (issue 28) without applying low-tier budgets to devices weaker than the low tier. |
| D-41 | **iOS 15/16 verification uses devices, not simulators.** Xcode 26.6 on the dev Mac has iOS 18.2–26.5 simulator runtimes only, so the device lab adds an **iPhone 7 on iOS 15.8.x** and an **iPhone 8 on iOS 16.7.x** (both at their final OS). Both pods compile with `-Werror=unguarded-availability-new`; `scripts/ci/editor/check_ios_min_os.sh` (ENG-09) fails on any strongly bound symbol introduced after iOS 15.0 (`xcrun vtool -show-build`, `nm -um`, `otool -L`) in the engine pod, `WhisperCore.xcframework` and the app binary. The self-hosted runner setup installs CMake (`brew install cmake`, ≥ 3.28; not installed today). APIs newer than 15.0 are behind `#available` (e.g. the VideoToolbox hardware-encoder keys are iOS 17.4+, §14.2). | review issues 10, 11 | D-29's launch-safety argument only holds if iOS 15/16 are actually exercised. |
| D-42 | **De-risking order.** IOS-01 and AND-01 start on day 1 in throwaway spike host projects (`spikes/ios_engine/`, `spikes/android_engine/`), using ENG-05 fixtures (no plugin dependency) or self-generated media. The Pigeon surface and plugin build configuration are frozen by ENG-06 only after both extended spikes report. The former ENG-01 is split into ENG-01 (Pigeon definitions, generated code, Dart engine), ENG-07 (iOS glue and placeholders), ENG-08 (Android glue and placeholders) and ENG-09 (example host and CI scripts). | review issue 9 | The riskiest questions were answered late, behind the largest ticket. |
| D-43 | **Platform narrowings need the owner's written sign-off before M0 closes** (INT-01 exit; recorded in this row with the date): (a) Android API 24–28 devices get the player but not the editor (gate API 29 + GLES 3); (b) `armeabi-v7a` devices get no Auto captions; (c) the iOS deployment target rises from 13.0 to 15.0 (no device is dropped); (d) the player's Edit cannot edit MKV/WebM/AVI on iOS (R7). Offered option for (d): a pure-Dart stream-copy MKV/WebM → MP4 remux (H.264/HEVC with AAC/AC-3, managed copy, reusing the `danaview_data` MKV inspector, no FFmpeg) as an extra ticket, scheduled only if the owner asks; otherwise the R7 copy stays; (e) Android contingency-engine degradations if AND-16 is activated (sign-off before M1 ends); (f) on Android, editing projects (including voice recordings) are not in Auto Backup or device transfer (§8.1). **Status: owner defaults 2026-10-08, revisable** (recorded by INT-01; the owner skipped the sign-off questions, so the recommended defaults apply until the owner revises them): (a) accepted: editor gate API 29 + GLES 3 + ≥ 2 GB RAM; (b) accepted: no Auto captions on `armeabi-v7a`; (c) accepted: iOS deployment target 15.0 (done in INT-01); (d) the R7 message stays for MKV/WebM/AVI on iOS, and the remux ticket is not scheduled; (f) accepted: the Android editor and speech trees are excluded from Auto Backup and device transfer; (e) **signed off: owner decision 2026-10-11** (closes the open item; **M1 exit is no longer blocked by D-43**). AND-01 reported a no-go (R1) and ENG-06 activated AND-16 on 2026-10-11 (§13.3); the four degradations of AND-01.md §7 were put to the owner. Principle: **preview adapts to the device; export is never real-time, so it is always full quality on every supported device, only slower on weak ones; no device in the supported range is refused an export.** (1) **Proxies on by default on the minimal and low tiers** (Android and iOS), generated in the background; preview uses them, export always uses the originals; mid and high keep Auto (§9.5). (2) **Adaptive preview quality**: preview resolution steps full → 1/2 → 1/4 automatically under load and recovers; the user can pin a fixed quality (the existing preview quality option, UX-18; §12.2 `PreviewQuality.auto`). (3) **Degradation 1 accepted, narrowed**: layers beyond the tier's live decode budget show paused-exact still frames **only during playback**; paused, scrubbing and seeking are always exact for every layer. (4) **New render-preview cache** (D-45): heavy ranges (above the live budget, or with chroma key or many effects) can be pre-rendered in the background into a temporary preview file that then plays smoothly; a timeline marker shows rendered and unrendered ranges; any edit touching a range invalidates its cache; files live in the editor cache, count in the "Editor cache" storage contributor, can be cleared and are never exported. Default: automatic on the minimal and low tiers when the editor is idle and the device is charging, otherwise off; the manual "Render preview" action exists on every tier. (5) **Degradation 2 accepted**: exact seek may be up to +30% slower on AND-16 (§13.4); the nearest decoded frame shows instantly, then refines to the exact frame. (6) **Degradation 3 accepted**: under load a frame is dropped rather than a late or wrong one shown. (7) **Degradation 4 changed**: `maxVisualSequences` (Android 2 / 3 / 4 / 6) limits **live preview only**; **export never refuses**. When a project needs more simultaneous decoders than the device allows, export runs a **multi-pass precompose** (D-45): a first pass renders intermediates for the excess layers at full resolution and high quality (intra-only or very high bitrate, same frame grid, same colour handling, so the result matches a single pass), then the final export. This replaces "export refuses until reduced"; preview above the cap uses proxies, still frames and the render-preview cache. iOS gets the same behaviour wherever the device decoder limit is hit. Also an owner default: there are no iOS 15/16 lab devices, so D-41's iPhone 7/8 checks are recorded as "deferred: no device available", and iOS 15/16 are verified only by `-Werror=unguarded-availability-new` and `check_ios_min_os.sh`. | review issues 8, 16, 28 | Owner decision 1 only says the editor ships on iOS and Android first. |
| D-44 | **Writes into `Documents` go through one guarded writer.** `DocumentsExportWriter` (core store, CORE-24) is the only code that writes under `Documents` ("Keep a copy in Danaview"): target directory `Documents/Exports/` only, exclusive create (never overwrite), `'<name> (2).mp4'` naming reusing the `LibraryStorage._uniqueTarget` scheme, refuses symlinked targets or parents. `MediaAccessPort.excludeFromBackup` refuses paths outside the editor roots. | review issue 27 | `Documents` is the user's "On This Device" library and is treated as originals. |
| D-45 | **Render-preview cache and multi-pass export** (owner decision 2026-10-11, D-43(e) points 4 and 7). **(A) Render-preview cache.** Core (`CORE-37`, pure Dart) splits the preview RenderPlan into ranges at layer edges and hashes each range from everything that can change its pixels (the plan's layers, assets' `fp`, params, keyframes, sprites and LUT ids clipped to the range, canvas and `gridFps`; never paths or plan `rev`), so any edit touching a range changes its hash and invalidates its entry, and an undo that restores a range finds its old entry again. A range is **heavy** when its peak decoder-backed layers exceed the tier's live budget (`maxConcurrentVideoLayers`, or the slots of `maxVisualSequences` on Android), or it has a chroma-keyed layer, or its effect cost (blur, LUT, mask, chroma, sharpen per layer) passes a per-tier threshold. The cache index (`<cache>/danaview/editor/renders/index.json`, files `<cache>/danaview/editor/renders/<rangeHash>.mp4`, written atomically) maps hash → file, size and last use, LRU-bounded at 1 GB (minimal/low 512 MB) and trimmed on memory pressure and low disk. Native renderers (AND-18 Android, IOS-19 iOS) render a range plan to a preview-quality intermediate (preview canvas size, project fps on the frame grid, intra-only or short-GOP H.264, video only; audio always plays live) and, during playback, swap the cached file in for every layer of a rendered range at its exact frame boundaries; paused, scrubbing and exact seeks keep the normal exact path (§12.2 semantics are unchanged). The timeline shows a render marker over the ruler (rendered / heavy-unrendered / not needed; UX-44). **Default:** automatic on the minimal and low tiers while the editor is idle (no playback, edit or job for 5 s) and the device is charging, otherwise off; the manual "Render preview" action (whole timeline or selection/loop range) is available on every tier; setting `editor.renderPreview` Auto/Manual. Files count in the "Editor cache" storage contributor, are cleared with it, are owned files for `OwnedFileDeleter`, and **are never exported** (export plans never reference them, like proxies, §9.5). **(B) Multi-pass export.** `maxVisualSequences` and `maxConcurrentVideoLayers` limit live preview only; export preflight never refuses for layer or sequence counts. When the export plan needs more simultaneous decoders than the device allows (Android: more packed slots than `maxVisualSequences`, or peak decoders above codec instances − 2; iOS: wherever the decoder limit is hit, `decoderInitFailed` on a composition track), the exporter runs a **precompose**: pass 1 composites the **bottom** slots (the background plus the lowest slots, in z order, as many as fit the device) into a full-resolution, opaque, video-only intermediate (audio is mixed once, in the final pass) at the export size, intra-only or very high bitrate (≥ 4× the export bitrate, HEVC or H.264 as available), on the export frame grid and with the same working colour space and tone mapping as a single pass; it repeats until the remaining slots plus one intermediate fit; the final pass is the normal export with the intermediate as the new bottom layer. Because each intermediate is the opaque result of everything below it, no alpha is carried between passes and blending order is unchanged. Intermediates live in `<cache>/danaview/editor/work/export-<jobId>/` and are deleted when the job ends; disk preflight counts them. Acceptance: a precomposed export matches a single-pass export of the same plan on a device that can do both (SSIM ≥ 0.995 per frame, grid-cut barcodes 100%, frame count equal). Progress is one continuous fraction across passes within the existing phases; no message changes. **Contract (D-45 amendment).** The RenderPlan is unchanged. The engine API gains `MediaJobs.renderPreview(RenderPlan rangePlan, {required String outputPath})` (a preview plan cut to the range, times relative to its start) and `PreviewSession.setRenderedRanges(List<RenderedRange>)` (`RenderedRange {TimeRange range; String uri; String hash}`); the engine drops any rendered range that an applied patch touches until the next `setRenderedRanges`, so a stale render can never play. The auto default also needs an idle-and-charging signal (`PlatformServices.powerState`; as landed by INT-06: `EditorEngine.background.powerState()` and `powerStateChanged`, `PowerState {bool charging; bool lowPowerMode}`, native `powerStateChanged` signal events). The Pigeon surface and glue are frozen (§12.6), so these additions (`JobKindMsg.renderPreview` and its request fields, `PreviewHostApi.setRenderedRanges`, `powerState`, the matching API-01 types and fake, ENG-02/ENG-03 Dart glue, ENG-07/ENG-08 glue) are one lead-approved [INTEGRATION] amendment, ticketed as **INT-06** (M4; after ENG-06 and CORE-37; BUILD_PLAN §6, §7), which must land before UX-44, AND-18 and IOS-19 call them; those three tickets depend on INT-06. INT-06 leaves the native implementations as `notSupportedOnDevice` placeholders that IOS-19 and AND-18 fill. Multi-pass export needs no contract change. | owner decision 2026-10-11 (D-43(e)) | Preview adapts to the device; export is never real-time, so it stays full quality everywhere and only gets slower on weak devices. Refusing an export, or forcing users to simplify a project made on another device, was the worst outcome. |

---

## 3. Platform minimums and gating

### 3.1 iOS: deployment target 15.0 (raised from 13.0)

**Exactly what changes:** `IPHONEOS_DEPLOYMENT_TARGET = 15.0` in every Runner and RunnerTests build configuration (`ios/Runner.xcodeproj/project.pbxproj`), `platform :ios, '15.0'` in `ios/Podfile`, a `post_install` hook that lifts any pod below 15.0 to 15.0, and `s.platform = :ios, '15.0'` in the new podspecs (`danaview_editor_engine`, `danaview_whisper`). Done in INT-01.

**Why:**
1. **No device is dropped.** iOS 13, 14 and 15 support exactly the same hardware (iPhone 6s/6s Plus/SE 1st gen and later, iPod touch 7th gen). Only users who never updated past iOS 14 keep the current version through the App Store's "last compatible version".
2. **Launch safety.** Two new native modules (the engine and ggml/whisper) load at launch. Below their real floor, one strongly bound symbol would stop the whole app, including the player, from launching. A 15.0 floor makes Xcode's availability checking cover the editor's API set at compile time.
3. The editor uses iOS 15 APIs throughout: async `AVAsset.load…`/`loadTracks` (the sync `tracks` API is deprecated in iOS 18), `PHPickerViewController` with `.current` representation, `UTType`, `CIKernel(functionName:fromMetalLibraryData:)`.
4. One fewer OS generation to test, and Xcode 26 simulators don't offer iOS 13/14 runtimes anyway.

Runtime gates still in place: `BGContinuedProcessingTask` behind `#available(iOS 26, *)` (BackgroundTasks weak-linked); VideoToolbox hardware-encoder keys behind `#available(iOS 17.4, *)` (§14.2); `AVAudioApplication` behind `#available(iOS 17, *)`; whisper Metal only on iOS ≥ 16.4 and Apple GPU family ≥ 6 (A13+); Accelerate/BLAS stay **off** in ggml (no `NEWLAPACK` symbols; checked with `nm -um` in AI-05). The editor requires a Metal device (every iOS 15 device has one); devices below 3 GB RAM run the `minimal` tier (D-40).

**How 15.0 is verified (D-41):** both pods build with `-Werror=unguarded-availability-new`; `check_ios_min_os.sh` (ENG-09) runs in the `ios` CI job and in INT-05's release lane; launch, player and editor smoke tests run on the iPhone 7 (iOS 15.8.x) and iPhone 8 (iOS 16.7.x) lab devices (AI-05, IOS-01, QA-01). iOS 15/16 simulator runtimes are not available for Xcode 26.6 on the dev Mac, so no acceptance criterion depends on them; the oldest simulator runtime used is iOS 18.2.

### 3.2 Android

- `minSdk` stays **24** (Flutter 3.44 default), `compileSdk`/`targetSdk` 36. The player keeps working on API 24–28.
- **Editor runtime gate: API ≥ 29, an EGL context with GLES 3.0 and ≥ 2 GB RAM.** Below that, `EditorCapabilities.supported = false` with `unsupportedReason = 'android_too_old'`, `'gles3_missing'` or `'insufficient_memory'`, and the Projects screen shows the unsupported state (the entry points stay visible so the explanation is reachable; the player's Edit explains on tap, UX-41). Reasons: OpenGL HDR→SDR tone mapping, `MediaCodecInfo.isHardwareAccelerated`, the thermal API, `MediaStore` pending inserts without storage permission, HardwareBuffer-backed `SurfaceProducer`. 2–3 GB devices and Go devices run the `minimal` tier (D-40). QA-02 runs an API 28 emulator to prove the below-gate behaviour and that the player is unaffected. This narrowing awaits owner sign-off (D-43).
- Auto captions additionally need `arm64-v8a` or `x86_64` (`armeabi-v7a` → "Auto captions aren't available on this device"; D-43).
- Media3 **1.11.1** pinned. Files that use Media3 opt in with `@OptIn(UnstableApi::class, ExperimentalApi::class)` (`CompositionPlayer` is `@ExperimentalApi` since 1.9.0); the module's lint configuration treats both as opt-in-required (ENG-08). Deprecated `experimentalSetForce{Audio,Video}Track` are not used; sequences declare `trackTypes` (D-38).

### 3.3 Desktop and flags

| Condition | Home button / player Edit | `/projects`, `/editor/*` |
|---|---|---|
| iOS/Android, `DANAVIEW_EDITOR=true` | shown | allowed (device gate checked on open) |
| iOS/Android, `DANAVIEW_EDITOR=false` (development default) | hidden | redirect to `/` |
| macOS/Windows/Linux | hidden (also the Settings "Video editor" row and the editor/speech storage contributors; D-17) | redirect to `/` |

`EditorAvailability.platform` is synchronous and platform-only (routes and headers decide without awaiting). `editorDeviceSupportProvider` (async, from `EditorEngine.capabilities()`) decides the device gate.

---

## 4. Package graph and file layout

### 4.1 Graph

```
app root (lib/: main.dart, app.dart, router/)
 ├─ danaview_features ─────────────► danaview_ui_kit, danaview_domain, danaview_data, danaview_engine, danaview_platform   (unchanged deps)
 ├─ danaview_editor (NEW, UX)
 │    ├─ danaview_editor_core (NEW, pure Dart)
 │    ├─ danaview_editor_engine_api (NEW, Flutter, no native code) ──► danaview_editor_core
 │    ├─ danaview_transcription (NEW, AI logic) ──► danaview_editor_core, danaview_whisper, danaview_data
 │    ├─ danaview_editor_fonts (NEW, assets only)
 │    ├─ danaview_ui_kit, danaview_data, danaview_platform, danaview_domain
 │    └─ danaview_features  (ONLY via package:danaview_features/{chrome,orientation,storage}.dart)
 ├─ danaview_editor_engine (NEW, Flutter plugin iOS+Android) ──► danaview_editor_engine_api, danaview_editor_core
 └─ danaview_whisper (NEW, FFI plugin iOS+Android) ──► ffi
```

Only the app root constructs platform implementations (`MobileEditorEngine`, `TranscriptionServiceImpl`) and passes them to `EditorBootstrap` (in `danaview_editor`), which returns the provider overrides.

### 4.2 Dependency rules (enforced by `test/architecture/dependency_rules_test.dart`, INT-01, plus per-package architecture tests)

1. `danaview_features` depends on **no** editor package. It exposes the Home edit button and the player Edit action as callbacks.
2. `danaview_editor_core` depends only on `meta`, `collection`, `crypto`, `path`, `characters`. No `package:flutter`, no `danaview_*`. `dart:io` and `dart:isolate` only under `lib/src/store/` (purity test, CORE-01).
3. `danaview_editor_engine_api` → `flutter`, `meta`, `collection`, `danaview_editor_core`. Never the plugin, `danaview_editor`, `danaview_transcription`, `danaview_features`.
4. `danaview_editor_engine` → `danaview_editor_engine_api`, `danaview_editor_core`. Never `danaview_editor`, `danaview_features`, `danaview_transcription`.
5. `danaview_whisper` → no `danaview_*` package.
6. `danaview_transcription` → never the engine packages, `danaview_editor` or `danaview_features`; no widget code.
7. `danaview_editor` → `danaview_editor_engine_api` (never the plugin). It may import `danaview_features` only through `chrome.dart`, `orientation.dart` and `storage.dart`.
8. `UserConsent.accepted(` appears only in `packages/danaview_editor/lib/src/editor/flows/captions/model_consent_view.dart` (architecture test, UX-01).

### 4.3 `packages/danaview_editor_core` (pure Dart)

```
pubspec.yaml analysis_options.yaml                       CORE-01
schema/render_plan.v1.schema.json schema/effects_reference.md   CORE-29
schema/project.v1.schema.json                            CORE-22
tool/gen_frame_vectors.dart                              CORE-02
benchmark/                                               CORE-35
lib/{model,ops,eval,formats,plan,codec,store}.dart       CORE-01 (barrels)
lib/src/time/  lib/src/ids/                              CORE-02
lib/src/model/*.dart, lib/src/model/keyframes/keyframe_data.dart   CORE-03
lib/src/model/pool/                                      CORE-04   (incl. resolved_media.dart, media_probe.dart, picked_media.dart, media_access_port.dart)
lib/src/model/keyframes/ (except keyframe_data.dart)  lib/src/eval/evaluate.dart     CORE-05
lib/src/eval/{clip_time_map,speed_math}.dart             CORE-06
lib/src/eval/{geometry,text_layout_spec,text_animation_eval}.dart   CORE-07
lib/src/eval/transition_limits.dart                      CORE-16
lib/src/eval/visual_packing.dart                         CORE-36   (sequence packing + per-platform counts, §13.5)
lib/src/validate/                                        CORE-08
lib/src/ops/{edit_command,rejections,outcome,edit_context,placement,dry_run,limits}.dart, commands/composite.dart   CORE-09
lib/src/ops/commands/{clip_commands,ripple}.dart         CORE-10
lib/src/ops/commands/clipboard_commands.dart, ops/{clipboard,selection}.dart   CORE-11
lib/src/ops/commands/speed_commands.dart                 CORE-12
lib/src/ops/commands/{property_commands,keyframe_commands}.dart   CORE-13
lib/src/ops/commands/text_commands.dart                  CORE-14
lib/src/ops/commands/{subtitle_commands,caption_commands}.dart   CORE-15
lib/src/ops/commands/transition_commands.dart            CORE-16
lib/src/ops/commands/{track_commands,marker_commands,project_commands}.dart, ops/requantize.dart   CORE-17
lib/src/ops/snapping.dart                                CORE-18
lib/src/session/                                         CORE-19
lib/src/formats/{subtitle_codec,srt,vtt,text_decoding}.dart   CORE-20
lib/src/formats/{cube_lut,vlut,float16}.dart             CORE-21
lib/src/codec/{project_json,fragment_cache,schema_version}.dart   CORE-22
lib/src/codec/migrations/                                CORE-23
lib/src/store/{store_roots,store_fs,atomic_file,dnproj_format,owned_file_deleter,documents_export_writer}.dart   CORE-24
lib/src/store/{project_repository,file_project_repository,project_summary,storage_report,writer_isolate}.dart   CORE-25
lib/src/store/{autosave_scheduler,journal,recovery}.dart CORE-26
lib/src/store/{media_pool_service,import_policy,managed_store,dart_io_media_access}.dart   CORE-27   (MediaAccessPort itself is model/pool, CORE-04)
lib/src/store/{availability,relink,gc}.dart              CORE-28
lib/src/plan/{render_plan,plan_json,plan_validator,sprite_request,encode_settings}.dart   CORE-29
lib/src/plan/{compiler,asset_resolver,lowering_visual,z_order}.dart   CORE-30
lib/src/plan/{lowering_transitions,lowering_text,lowering_audio,sprite_requests}.dart   CORE-31
lib/src/plan/{plan_diff,plan_memo,transients}.dart       CORE-32
lib/src/plan/{export_settings,export_presets,bitrate,compile_export}.dart   CORE-33
lib/render_cache.dart (new barrel), lib/src/plan/render_ranges.dart, lib/src/store/render_cache_index.dart   CORE-37   (render-preview cache model, D-45)
test/fuzz/                                               CORE-34
```

### 4.4 Engine packages

```
packages/danaview_editor_engine_api/            (Flutter package, no native code)
  pubspec.yaml, lib/danaview_editor_engine_api.dart, lib/testing.dart, lib/src/{engine,preview,media_services,
    export,recorder,platform_services,capabilities,failures,config}.dart, lib/src/fake/, test/contract/   API-01
  lib/src/{plan_sync,plan_transport}.dart                                         API-02
  lib/src/math/, lib/src/reference/, test_fixtures/{vectors,images}/, tool/regen_goldens.dart   API-03
  lib/src/render_prep/ (text_layout_engine, text_sprite_rasterizer, vsprite_codec, sprite_prepass)   API-04

packages/danaview_editor_engine/                (Flutter plugin: ios, android)
  pubspec.yaml, pigeons/engine_api.dart, lib/danaview_editor_engine.dart, lib/src/{mobile_editor_engine,
    event_router,error_mapper}.dart, lib/src/pigeon/, ios/Classes/Pigeon/, android/.../engine/pigeon/   ENG-01
  ios/danaview_editor_engine.podspec, ios/Resources/PrivacyInfo.xcprivacy,
    ios/Classes/{DanaviewEditorEnginePlugin.swift, Glue/, Core/{EngineContext,ErrorCodes,EventHub,Log,Paths}.swift}   ENG-07
  android/{build.gradle.kts, lint.xml, src/main/AndroidManifest.xml, src/main/res/xml/danaview_editor_file_paths.xml},
    android/src/main/kotlin/com/vecvel/danaview/editor/engine/{DanaviewEditorEnginePlugin.kt, glue/,
    core/{EngineContext,ErrorCodes,EventHub,EngineThreads,Paths}.kt}                                   ENG-08
  example/ (host app, RunnerTests/Glue, android source sets), scripts/ci/editor/{ios,android_unit,
    android_emulator,check_ios_min_os}.sh                                                             ENG-09
  lib/src/mobile_preview_session.dart                                             ENG-02
  lib/src/{mobile_jobs,mobile_recorder,mobile_platform_services,mobile_media_access}.dart   ENG-03
  lib/src/mobile_export.dart                                                      ENG-04
  tool/make_fixtures.swift, test_fixtures/media/, barcode readers                 ENG-05
  iOS ios/Classes/…  Media/{Probe,Compatibility} Core/{DeviceProfile,Capabilities} IOS-02 · Media/{ThumbnailService,DiskCache} IOS-03 ·
     Media/{PcmReader,WaveformService,SpeechAudioExtractor} IOS-04 · Core/JobRegistry Media/{ProxyJob,ProxyRegistry} IOS-05 ·
     Media/FreezeFrameJob Preview/SourceFrameCache IOS-06 · Media/ReverseJob IOS-07 · Plan/ Composition/ IOS-08 ·
     Render/{Shaders/DanaviewKernels.metal,Kernels,LutStore,SpriteStore,ImageLayerCache} IOS-09 ·
     Render/{DVCompositor,DVInstruction,LayerRenderer,RedrawCache} IOS-10 · Preview/{PreviewSession,PreviewSessionManager,
     TextureBridge,DisplayLinkDriver,SeekController,QualityGovernor,AudioSessionCoordinator} IOS-11 ·
     Export/{ExportJob,ReaderWriterPipeline,EncoderSettings,ExportCoordinator} IOS-12 · Export/{BackgroundExecution,
     ActiveExportStore} Platform/{PhotosSaver,FileHandoff} IOS-13 · Recording/VoiceRecorder IOS-14 ·
     Platform/{MediaPicker,MediaAccess,Permissions,BackgroundGuard} IOS-15 · Platform/DropTarget IOS-16 ·
     Media/{SegmentedWriter,SegmentConcat,SegmentCheckpoint} Core/JobInterruption IOS-17 · Audio/{GainTap,TapEnvelope} IOS-18 ·
     RenderPreview/ IOS-19 (D-45) · Export/Precompose/ IOS-20 (D-45)
  Android …/engine/  media/{Probe,Compatibility} core/{DeviceProfile,Capabilities} AND-02 · media/{ThumbnailService,DiskCache} AND-03 ·
     media/{PcmDecoder,WaveformService,SpeechAudioExtractor} AND-04 · core/JobRegistry media/{ProxyJob,ProxyRegistry} AND-05 ·
     media/FreezeFrameJob preview/SourceFrameCache AND-06 · media/ReverseJob AND-07 · plan/ composition/ AND-08 ·
     effects/ + src/main/assets/danaview_shaders/ AND-09 · preview/{PreviewSession,PreviewSessionManager,SurfaceBridge,
     SeekController,QualityGovernor} AND-10 · export/{ExportCoordinator,TransformerExport,EncoderSettings,
     HardwareEncoderSelector,ActiveExportStore} AND-11 · export/{ExportService,ExportNotification}
     platform/{BackgroundGuard,MediaStoreSaver,FileHandoff} AND-12 · recording/VoiceRecorder AND-13 ·
     platform/{MediaPicker,MediaAccess,Permissions} AND-14 · platform/DropTarget AND-15 ·
     preview/fallback/ AND-16 (contingency, only on AND-01 no-go) · preview/{PausedFrameRenderer,LayerCompositorGl,
     StructuralDebouncer} AND-17 · preview/render/ AND-18 (D-45) · export/precompose/ AND-19 (D-45)
spikes/ios_engine/ IOS-01 · spikes/android_engine/ AND-01   (throwaway spike hosts, D-42; kept for reference, not shipped)
```

Native glue classes (`ios/Classes/Glue/*HostApiImpl.swift`, `android/.../glue/*`) are thin: they validate arguments, hop to the engine queue and delegate to the service protocols above. ENG-07 (iOS) and ENG-08 (Android) write them against ENG-01's Pigeon definitions; feature tickets never edit them. Changes to the Pigeon surface or glue after that go through ENG-06 [INTEGRATION], which freezes them after the extended spikes report (D-42).

### 4.5 AI packages

```
packages/danaview_whisper/   third_party/, tool/vendor_whisper.sh, LICENSE-THIRD-PARTY.md                       AI-01
  pubspec.yaml, ffigen.yaml, lib/danaview_whisper.dart, lib/src/ffi/dv_whisper_bindings.g.dart, lib/src/support.dart, src/dv_whisper.h   AI-02
  src/dv_*.{h,cpp} (except dv_whisper.h), src/CMakeLists.txt, src/tests/                                      AI-03
  android/{build.gradle.kts, src/main/AndroidManifest.xml}, src/cmake/android.cmake, src/dv_exports.map        AI-04
  ios/danaview_whisper.podspec, ios/Classes/dv_whisper_forwarder.cpp, ios/Resources/, tool/build_ios_xcframework.sh   AI-05
  lib/src/device/, ios/Classes/{DanaviewWhisperPlugin,DeviceProfiler}.swift, android/src/main/kotlin/…/whisper/   AI-06
  lib/src/runtime/, lib/src/ffi/library_loader.dart                                                         AI-07
packages/danaview_transcription/  pubspec, lib/danaview_transcription.dart, lib/src/{contracts,catalog,languages}/  AI-08
  lib/src/models_store/ AI-09 · lib/src/transcript/ AI-10 · lib/src/segmentation/ AI-11 · lib/src/timeline/ AI-12 ·
  lib/src/{pipeline,governor}/ AI-13 · lib/src/catalog/tuning.dart, tool/eval/ QA-06
```

### 4.6 `packages/danaview_editor` (UX) and changes elsewhere

```
pubspec.yaml, lib/danaview_editor.dart, lib/src/app/{editor_availability,editor_providers,editor_prefs}.dart,
  lib/src/editor/contracts/{action_ids,tool_ids,inspector_routes}.dart, lib/src/editor/wiring/, lib/src/debug/     UX-01
lib/src/app/editor_bootstrap.dart, lib/src/editor/state/default_plan_compiler.dart                           INT-02
lib/src/app/adapters/                                                                                         INT-04
lib/src/projects/{projects_screen,projects_controller,project_card,project_actions}.dart                      UX-05
lib/src/projects/new_project_sheet.dart, lib/src/editor/flows/import_media_sheet.dart                         UX-06
lib/src/editor/{editor_screen,editor_scope,editor_lifecycle}.dart, lib/src/editor/layout/                     UX-07
lib/src/editor/state/{editor_state,editor_controller,edit_transaction,editor_session,editor_events,plan_compiler_port}.dart,
  lib/src/app/editor_messages.dart                                                                           UX-08
timeline/{timeline_viewport,ruler,timeline_metrics,timeline_style} UX-09 · timeline/{timeline_snapshot,render_timeline_canvas,
  timeline_hit,playhead_layer}, caches/paragraph_cache UX-10 · timeline/{track_headers,track_menu_sheet} UX-11 ·
  timeline/{timeline_view,timeline_gestures,timeline_semantics} UX-12 · timeline/{timeline_interaction,snapping},
  state/editor_clipboard UX-13 · state/{playhead_controller,transport_controller}, transport/ UX-14 ·
  actions/{editor_action_registry,editor_shortcuts,shortcuts_sheet} UX-15 · toolbar/, inspector/{inspector_host,
  inspector_dock,inspector_header,inspector_rows,keyframe_toggle,color_field} UX-16 · timeline/marker_sheet UX-17 ·
  preview/{preview_region,preview_surface,fullscreen_preview,preview_status} UX-18 · preview/{text_overlay_layer,
  text_overlay_painter} UX-19 · caches/thumbnail_cache UX-20 · caches/waveform_cache UX-21 · preview/{canvas_geometry,
  manipulation_overlay,manipulation_painter,snap_guides} UX-22 · panels/{transform,crop,mask}_panel + preview/{crop,mask,
  eyedropper}_overlay UX-23 · panels/{adjust,filters}_panel + assets/looks/ + tool/gen_looks.dart UX-24 ·
  panels/{speed_panel,speed_curve_editor} UX-25 · panels/keyframes_panel UX-26 · panels/transitions_panel UX-27 ·
  panels/{overlay,chroma}_panel UX-28 · panels/canvas_panel, flows/{project_sheet,history_sheet} UX-29 ·
  panels/{text_panel,font_picker}, text/font_catalog + packages/danaview_editor_fonts/ UX-30 · panels/subtitles_panel UX-31 ·
  panels/subtitle_io UX-32 · panels/audio_panel UX-33 · panels/voiceover_panel UX-34 · panels/clip_info_panel,
  flows/tasks_sheet, state/tasks_controller UX-35 · panels/media_panel, timeline/timeline_drop_target UX-36 ·
  flows/captions/{auto_captions_sheet,auto_captions_controller,language_picker,model_consent_view,captions_progress_panel} UX-37 ·
  flows/captions/{regenerate_sheet,interrupted_notice}, settings/captions_settings_section, app/speech_storage_contributor UX-38 ·
  flows/export/ UX-39 · flows/relink/, state/media_health_controller, projects/recovery_banner UX-40 ·
  app/editor_launcher UX-41 · app/editor_storage_contributor, settings/editor_settings_screen UX-04 ·
  timeline/timeline_tiles (conditional) UX-43 · state/render_preview_controller, timeline/render_marker_strip,
  settings/render_preview_settings_section, app/editor_tier_defaults UX-44 (D-45)
Per-feature action bindings: lib/src/editor/actions/bindings/<feature>_bindings.dart, owned by the feature ticket.
Per-feature copy: lib/src/app/strings/<feature>_strings.dart, owned by the feature ticket (no shared strings file).

danaview_features: player/{danaview_player_actions,screen_orientation_policy}.dart + lib/orientation.dart  UX-02 ·
  library/danaview_home_screen.dart + lib/chrome.dart  UX-03 · tools/{storage_usage,danaview_storage_screen}.dart,
  more/danaview_settings_screen.dart + lib/storage.dart  UX-04 (settings_destination.dart unchanged) ·
  player/{danaview_controls_overlay,danaview_player_screen}.dart, controllers/player_controller.dart,
  settings/danaview_settings_panel.dart (player shortcuts cheat sheet: 'E – Edit video')  UX-41 ·
  more/{legal_texts,danaview_licenses_screen,danaview_about_screen}.dart + lib/licenses.dart  UX-42
danaview_ui_kit: components/{danaview_progress_bar,danaview_number_field,danaview_color_picker,danaview_docked_panel,
  danaview_search_field,danaview_step_indicator}.dart + barrel export lines  UI-01
App root: lib/main.dart, lib/router/app_router.dart, pubspec.yaml  INT-02, INT-04, INT-05 (integration only)
```

**Placeholder rule (D-33).** A skeleton ticket (CORE-01, CORE-09 for the command `part` files, API-01, ENG-01 for the Dart `mobile_*` files, ENG-07 for iOS service classes, ENG-08 for Android service classes, AI-02, AI-08, UX-01) may create a placeholder for a file another ticket owns. The placeholder holds only the declared public names (throwing `UnimplementedError`, or a "not available yet" widget, or a native stub returning `notSupportedOnDevice`) and the header `// OWNER: <ticket>`. From then on only the owner edits it.

---
## 5. Time model and frame grid

```dart
typedef TimeUs = int;                      // microseconds, int64; projects ≤ 24 h
final class FrameRate { final int num, den; // v1 projects/exports: den == 1, num ∈ {24,25,30,48,50,60}
  TimeUs timeOfFrame(int k) => ceilDiv(k * 1000000 * den, num);
  int frameIndexOf(TimeUs t) => floorDiv(t * num, 1000000 * den);
  TimeUs quantize(TimeUs t) => timeOfFrame(frameIndexOf(t));     // floor to frame start
  TimeUs quantizeNearest(TimeUs t); bool isOnGrid(TimeUs t);
  // Platform-time rule (D-35): for times produced by a platform clock or presentation timestamp.
  int frameIndexNearest(TimeUs tau) => floorDiv(tau * num + 500000 * den, 1000000 * den);   // round(tau·fps/1e6)
  TimeUs platformTimeOfFrame(int k) => floorDiv(2 * k * 1000000 * den + num, 2 * num); }   // P(k) = round(k·1e6/fps)
final class TimeRange { final TimeUs start, end; }                 // half-open [start, end)
```

- `frameIndexOf(timeOfFrame(k)) == k` and `frameIndexOf(timeOfFrame(k+1) − 1) == k` for every k (property-tested up to 24 h). Products stay below 2.2·10¹⁶.
- **Grid invariant.** Every item start and end, keyframe, marker, transition boundary and fade length sits on the project grid, so durations are whole frame counts. Changing the frame rate runs `requantize` (§7.2). **Source times are not quantized.**
- **Platform-time rule (normative, D-35).** Plan and model times use `timeOfFrame(k) = ceil(k·10⁶/fps)`. Platforms present frame k at a slightly different time: iOS at the rational `k/fps` (`CMTime(k, fps)`), Media3's clock band at `P(k) = round(k·10⁶/fps)` (`ConstantRateTimestampIterator`). For 25 and 50 fps all three agree; for 24/30/48/60 fps `k·10⁶/fps` has a fractional part of ⅓ or ⅔ and the platform time is up to 1 µs **before** the plan edge. Therefore:
  1. Every platform time τ (iOS `compositionTime`, item time, output-buffer PTS; Media3 `pts` in effects and `getOverlaySettings`, `onVideoFrameAboutToBeRendered` pts, `currentPosition`) becomes a frame index with `k = frameIndexNearest(τ)` (equivalently `frameIndexOf(τ + 500 µs)` near frame times). Layer activity (`t0 ≤ T < t1`), Android gating, keyframe/animation/`reveal` evaluation, `ParamSnapshot` lookup, the `danaview.frame` stamp and seek acks use `T = timeOfFrame(k)` of the **output** rate, never τ.
  2. **iOS** hands AVFoundation grid times as exact rationals: edit `at:` points, scaled target durations, instruction time ranges and the spacer duration are `CMTime(value: k, timescale: gridFps)` with `k = frameIndexOf(t)` (exact because `t` is on the grid); source ranges (not quantized) stay `CMTime(value: µs, timescale: 1_000_000)`. The compositor computes `k = round(compositionTime × fps)`.
  3. **Android** builds every sequence so that each item and gap boundary falls exactly on `P(k)` (durations are differences of `P`; a media item's clipping end is adjusted by ≤ 1 µs × rate, which is invisible), so secondary-frame selection never straddles a 1 µs gap whatever Media3's nearest/≤ policy is (V-N18). Gating and seek acks use `frameIndexNearest(pts)`.
  4. For export at an output rate different from the project rate, plans carry `canvas.gridFps` (the project rate, §11.2): edit points are on the `gridFps` grid, output frames on the `fps` grid. Exact rational times of two different integer grids are either equal or ≥ 1/1200 s apart, so deciding activity with the `ceil` µs values and with the platforms' rational or rounded times always agrees.
- **Shared vectors.** `packages/danaview_editor_core/test/fixtures/vectors/frame_grid.json` (CORE-02) is read by the Dart, Swift and Kotlin tests. Per fps ∈ {24, 25, 30, 48, 50, 60} it lists, for sampled k (incl. k ≡ 0, 1, 2 mod 3 around 1 s, 1 h and 24 h): `timeOfFrame(k)`, `floor(k·10⁶/fps)`, `P(k)`, the rational `(k, fps)`, and the expected `frameIndexNearest` of each (always k), plus `frameIndexNearest` at `P(k) ± (half a frame − 1 µs)`. The contract fixture `render_plans/contract/grid_cuts_30fps.json` (CORE-29) has layer edges at frames k ≡ 1 and 2 (mod 3) with an `expected_active.json` per frame, checked by IOS-08 (instruction lookup at `CMTime(k, 30)`) and AND-08 (sequence boundaries equal `P(k)`; gating at `P(k)`). An Android exact seek to frame k targets `P(k)` rounded to ms in the direction AND-01 measures for Media3's seek semantics (floor if the first frame with pts ≥ position is shown, ceil if the last frame ≤ position is shown; recorded in `frame_grid.json` as `androidSeekMsRounding`) and is acknowledged when `frameIndexNearest(pts) == k`. **Measured (AND-01 V-N18, recorded by ENG-06 2026-10-11): Media3 shows the first frame with pts ≥ position (ExoPlayer `SeekParameters.EXACT` 16/16 floor hits, 0/16 ceil), so `androidSeekMsRounding = "floor"`.** On the AND-16 preview engine (§13.3) the rounding applies to the slot decks' item positions: `floor((ruleFramePts − clipStart) / 1000)` ms with `SeekParameters.EXACT`. Because every grid frame is more than 1 ms after its predecessor, a seek to `floor(P(k) / 1000)` ms lands on frame k for every shared vector (ENG-06's `BuildConfigTest`), and so does a seek to that value − 1 ms (used by AND-16's stuck-deck watchdog).
- **Source-frame rule (D-04)** is in §11.5. Audio uses exact maps, sample-accurate.
- **Display.** Timecodes count frame indices (`mm:ss:ff`, `h:mm:ss:ff` from one hour). Parse accepts `1:23`, `1:23:12`, `83.5s`, `+2s`, `-10f`.
- **Export frame rate** may differ from the project rate (export grid re-quantizes only output frame times; keyframes are evaluated at true times). Android produces the export grid from its clock band (§13.3); `capabilities.fpsUpconversion` reports whether rates above the source are honoured: **true on both platforms** (AND-01 V-N15: 30→60, 24→48 and 30→50 exports have every output frame at a constant step; the repeated source frame follows Media3's nearest-frame choice rather than the floor rule, so 16–24% of up-converted frames show the next source frame, always an adjacent one).

---

## 6. Domain model (`danaview_editor_core`, immutable, structurally shared)

### 6.1 Ids and root

Ids are `extension type`s over `String`: `ProjectId 'pr_'`, `TrackId 'tr_'`, `ItemId 'it_'` (clips, text items, cues), `MediaId 'md_'`, `MarkerId 'mk_'`, `TransitionId 'tx_'`, `LinkId 'ln_'`; each is the prefix plus 12 base62 characters from `Random.secure()`. Tests use `SeededIdGenerator`.

```dart
final class EditProject { ProjectId id; ProjectMeta meta /*name, createdAt, updatedAt, origin, editCount*/;
  Timeline timeline /*history-tracked*/; MediaPool pool /*not snapshotted*/; ViewState view /*persisted, not history*/;
  int docRevision; /* getters: settings, tracks, markers, media, duration, revision, index */ }
final class Timeline { ProjectSettings settings; List<Track> tracks; List<Marker> markers; int revision /*session-monotonic stamp*/; }
final class ProjectSettings { CanvasSpec canvas /*aspect w:h + baseShortSide 720|1080|2160 → even px*/; FrameRate frameRate;
  BackgroundSpec background /*Solid(color) | BlurOfMain(radius)*/; int audioSampleRate /*48000*/; }
```

All canvas-space values are normalized (positions as canvas fractions with 0 = centre; text sizes in points at a 1,080 px short side), so changing the canvas never rewrites items.

### 6.2 Tracks and compositing bands

```dart
enum TrackKind { video, overlay, audio, text, subtitle }
enum AudioRole { original, voice, music, effects }
final class Track { TrackId id; TrackKind kind; String name; bool isMain /*exactly one: first video track*/;
  bool locked, hidden, muted, solo; AudioRole? audioRole; SubtitleTrackData? subtitle;
  List<TimelineItem> items /*sorted, non-overlapping*/; List<Transition> transitions; int changedAt; }
```

- Canonical order `[video…, overlay…, text…, subtitle…, audio…]`. **Z bands, bottom → top:** video (main lowest) → overlay → text → subtitle. Display order is reverse z (D-09).
- `solo` affects audio only. `hidden` removes visual layers; `muted` removes audio; `locked` rejects every command targeting the track (`TrackLocked`).
- Allowed items: video/overlay lanes → `MediaClip` (video, image, still); audio lanes → `MediaClip` (audio stream of audio or video media); text → `TextItem`; subtitle → `SubtitleCue`. Transitions only on video/overlay lanes.

### 6.3 Items

```dart
sealed class TimelineItem { ItemId id; TimeUs start, duration; LinkId? link; String? label; }
final class MediaClip extends TimelineItem { MediaId media; TimeUs sourceIn; SpeedSpec speed; bool maintainPitch /*true*/;
  bool reversed; int? audioStream; VisualProps? visual; AudioProps audio; bool detachedAudio; KeyframeSet keyframes; }
final class TextItem extends TimelineItem { String text; TextStyleSpec style; TextAnimation animation; Transform2D transform; KeyframeSet keyframes; }
final class SubtitleCue extends TimelineItem { String text /*'\n' breaks; inline <i>,<b>*/; CueOrigin origin /*manual|imported|generated*/;
  bool editedAfterGeneration; }
```

**Duration authority:** a clip stores `(sourceIn, duration, speed)`; `sourceOut` is derived from the time map. A speed change keeps the source range and recomputes `duration = max(1 frame, quantizeNearest(T(range)))`.

### 6.4 Speed and time maps

`SpeedSpec = ConstantSpeed(rate ∈ [0.1, 10]) | SpeedRamp(points 2..16 over normalized source position, y ∈ [0.1, 10], presetId?)`. `ClipTimeMap` gives `toSource(t)`, `timelineTimeOf(s)` (exact inverse, null if trimmed away; used by AI mapping), `speedAt(t)` and `lower(maxErrorUs: 250)` → piecewise-linear `MapSegment[t0,t1,s0,s1]`. Ramp time is closed-form: segment time `(L/b)·ln(v1/v0)` (or `L·Δx/v0` when b = 0), inverse `x(τ) = x0 + v0·(e^{bτ/L} − 1)/b`. Reversed clips use `s' = sourceIn + sourceOut − s` and render from a reversed rendition (§15.5).

### 6.5 Visual properties

```dart
final class VisualProps { Transform2D transform; FitMode fit /*fit|fill|stretch*/; CropRect crop; ColorAdjust adjust;
  DetailFx detail; LookRef? look; ChromaKey chroma; MaskSpec mask; }
Transform2D { Vec2 position /*[-2,2] canvas fractions*/; double scale /*[0.01,8], 1 = fit base*/; double rotationDeg /*[-360,360] cw*/;
  bool flipH, flipV; double opacity /*[0,1]*/ }
ColorAdjust { exposure, brightness, contrast, highlights, shadows, saturation, temperature, tint }   // each [-1,1]; UI shows ×100
DetailFx { sharpness, blur, vignette }                                                             // [0,1]
LookRef = BuiltinLook(presetId, intensity) | ImportedLut(MediaId lut, intensity)                   // intensity [0,1]
ChromaKey { bool enabled; int color 0xRRGGBB; double similarity 0.4, smoothness 0.1, spill 0.3 }
MaskSpec { MaskShape none|rectangle|ellipse; Vec2 center, size /*item-local normalized*/; double rotationDeg, cornerRadius,
  feather [0,1], opacity [0,1]; bool invert }
```

Brightness…tint exist **once** (`ColorAdjust`) and serve both "Video Effects" and "Color & LUT". "Color presets" are 12 bundled looks sharing the LUT pipeline and its intensity control. Opacity lives in `Transform2D`; the Adjust panel mirrors it.

### 6.6 Audio, text, subtitles, transitions, markers, links

- `AudioProps { double volume [0,2] (1 = 0 dB, keyframable); bool muted; TimeUs fadeIn, fadeOut }` (each fade ≤ duration/2, on grid). Background music = audio track with `AudioRole.music`; recordings get `voice`; extracted audio gets `original`. A video clip and its extracted audio share one `ClipTimeMap` and one `LinkId`.
- `TextStyleSpec { fontFamily (content-font id, unknown → Figtree); fontSizePt [8,200]; bold; italic; align; color ARGB; letterSpacing [-20,100] (em/100); lineHeight [0.6,3]; maxWidth (canvas fraction, 0.9); background BoxStyle?; stroke StrokeStyle?; shadow ShadowStyle? }`.
- `TextAnimation { inKind none|fade|slide(dir)|scale|typewriter; inDuration; outKind none|fade|slide(dir)|scale; outDuration }`. `evaluateTextAnimation(item, t, canvas)` is the **one** implementation used by the preview overlay and the compiler: ease-out cubic (`1 − (1−x)³`) sampled at 6 linear segments; fade = opacity 0→1; slide = offset 10% of `min(W,H)` from the direction plus fade; scale = scale 0.6→1 plus fade; typewriter reveals `floor(n·p)` grapheme clusters (layout computed on the full text). Out animations mirror in reverse.
- `SubtitleTrackData { String? language (BCP-47); SubtitleStyle style (font, size, bold/italic, colour, box, outline, shadow, maxLines 1..3, maxWidth, align); SubtitlePosition bottom|top|custom(y) (safe margin 0.06); bool burnIn; CaptionProvenance? provenance }`. Cues on a track are sorted, non-overlapping, non-empty after trim.
- `CaptionProvenance { generator, engineVersion, modelId, modelSha256, language, languageDetected, languageConfidence?, segmentation, scope, transcriptKeys, generatedAt, schema }`; `SubtitleCueDraft { TimeRange range; String text }` (ai.md §10.2, adopted verbatim, schema 1).
- `Transition { TransitionId id; ItemId left, right /*touching*/; TransitionKind fade|crossDissolve|dipToBlack|dipToWhite|slide|wipe|zoom; int durationFrames; TransitionDirection? (l|r|u|d for slide/wipe; in|out for zoom) }`, centred on the cut: `[cut − ⌊n/2⌋f, cut + ⌈n/2⌉f)`. `TransitionRef = (TrackId, left, right)`.
- `Marker { MarkerId id; TimeUs time; String name; int colorIndex; String? note }`. `LinkId` groups items that move, split, delete and duplicate together.

### 6.7 Keyframes

`PropertyKey<T>` metadata (stable id, displayName, unit, min, max, step, default, displayScale, keyframable, channels, appliesTo, static read/write). **Keyframable:** position, scale, rotation, opacity, volume, the 8 adjust values, sharpness, blur, vignette, mask centre/size/rotation/feather/opacity. **Not keyframable:** chroma, look intensity, crop, flips, text style, transition parameters. `Keyframe { TimeUs t (item-local, on grid); double v }`; `KeyframeTrack` sorted and unique; `KeyframeSet` maps channel ids (`transform.position.x` …) to tracks; Vec2 properties write both channels at the same t. Interpolation is **linear**, held outside the first/last key, rotation in plain degrees. Keys stay attached to content: start trim shifts them, speed change scales them, split partitions them with boundary keys; keys outside `[0, duration)` are kept (un-trim restores them) and ignored by evaluation. `evaluate<T>(item, key, t)` returns the keyframed or static value.

### 6.8 Media pool

```dart
final class MediaAsset { MediaId id; MediaKind kind /*video|audio|image|lut|still|recording*/; String displayName;
  MediaLocator locator; MediaOwnership ownership /*external|managedCopy|projectOwned*/; MediaFingerprint fingerprint;
  MediaProbe probe; MediaOrigin origin; DerivedSpec? derived /*reversed(media, range)|still(media, time)*/;
  AssetStatus status /*ready|pending(jobId)|failed*/; ProxyState proxy; DateTime addedAt; }
sealed class MediaLocator {}  // AppRelativeLocator(root documents|support|cache, relPath) | FileLocator(path)
                              // | ContentUriLocator(uri) | BookmarkLocator(bookmarkB64, lastKnownPath)
final class MediaFingerprint { int sizeBytes; String quickHash /*sha1(head 64 KiB + tail 64 KiB + ':' + size)*/; int? modifiedMs; TimeUs duration; }
final class ResolvedMedia { String uri /*file:// or content://*/; String fingerprint /*quickHash*/; Uint8List? bookmark; bool isProxy; }
final class MediaProbe { MediaKind kind; TimeUs duration; bool hasVideo, hasAudio; int? width, height /*display, rotation applied*/;
  int rotation; FrameRate? nominalFrameRate; double? nominalFps; bool variableFrameRate; String? container, videoCodec, audioCodec;
  int audioStreams; int? channels, sampleRate, bitDepth; ColorTransfer transfer /*sdr|hlg|pq*/; int sizeBytes; bool editable; List<String> issues; }
```

`quickHash` reproduces `danaview_data` `MediaIdentityService.computeQuickHash` exactly (tested on fixtures), so player, editor caches and AI transcripts agree.

### 6.9 Invariants (validator, CORE-08)

I1 grid (all edges, keys, markers, transitions; durations ≥ 1 frame; ≤ 24 h). I2 per-track sorted, non-overlapping; ids unique. I3 item kind vs track kind; exactly one main track, first video track; band order. I4 media exists with a compatible kind; `0 ≤ sourceIn`, `sourceOut ≤ probe.duration`; speed bounds. I5 transitions reference touching neighbours and respect `TransitionLimits`. I6 keyframe tracks sorted, unique, non-empty, within bounds, keyframable only. I7 link groups ≥ 2 members on different tracks. I8 cue text non-empty; `SubtitleTrackData` exactly on subtitle tracks. I9 canvas even and ≥ 16 px; supported frame rate; fades fit. Validation runs on changed tracks after every command (a violation turns the result into `InternalInconsistency` and leaves the project unchanged), on the whole project after decode (followed by `repair()`, which never refuses to open and emits `ProjectOpenWarning`s), and fully after every step in tests, debug builds and the fuzzer.

---

## 7. Editing commands, history and transactions

### 7.1 Command framework

```dart
sealed class EditCommand { String get label; }               // library ops/edit_command.dart + one part file per group
final class EditContext { IdGenerator ids; MediaPool pool; DateTime now; EditPolicy policy; }
final class EditPolicy { OverlapPolicy overlap /*newLane*/; TimeUs defaultImageUs, defaultTextUs /*3 s*/, defaultCueUs /*2 s*/;
  int maxConcurrentVideoLayers /*from capabilities, D-14*/; int maxItems /*5000*/; }
final class EditOutcome { EditProject project; Set<ItemId> affected; Set<TrackId> changedTracks, createdTracks;
  SelectionHint? selection; List<EditNotice> notices; EditRejection? rejection; bool noop; }
final class EditPreview { Map<ItemId, Placement> placements; List<NewTrack> createsTracks; TimeRange? clampedTo; EditRejection? rejection; }
EditOutcome applyCommand(EditProject p, EditCommand c, EditContext ctx);   // pure
EditPreview dryRun(EditProject p, EditCommand c, EditContext ctx);         // same code path
```

`EditRejection` is data and is never thrown: `TrackLocked · ItemNotFound · WouldOverlap · OutOfSourceRange · BelowMinDuration · NothingAtTime · UnsupportedForKind · IncompatibleTrack · NotAdjacent · TransitionTooLong(maxFrames) · KeyframeExists · EmptyText · NoRoom · RippleBlockedByLinkedItem · LimitExceeded(what, limit) · MediaUnavailable · CannotDeleteMainTrack · InvalidValue · InternalInconsistency`. Exceptions inside a command are caught by the session and become `InternalInconsistency`. `CompositeCommand` is atomic. Gesture commands accept `clamp: true` and return the nearest valid result (`EditPreview.clampedTo`). Commands never snap; the UI snaps the proposed time before calling `dryRun`.

### 7.2 Catalogue (owners in brackets)

| Group | Commands |
|---|---|
| Structural [CORE-10] | `InsertMedia(media, track?, at, mode auto/ripple/overwrite-disabled/newLane)`, `MoveItems(ids, delta, toTrack?, ripple)`, `TrimItem(id, edge, newTime, ripple, clamp)`, `SplitItems(ids, at)`, `DeleteItems(ids, ripple)`, `DeleteGap(gap)` |
| Clipboard and media [CORE-11] | `DuplicateItems`, `PasteItems(payload, at, preferTrack?)` (cross-project paste adds pool entries, mints ids), `ReplaceMedia` (keeps range/effects/keys, shortens with notice), `ExtractAudio` (linked audio clip, `detachedAudio`), `LinkItems`/`UnlinkItems`; `copyItems` and `SelectionRules.expand` (link partners, drops locked) |
| Speed and derived [CORE-12] | `SetSpeed(item, spec, maintainPitch)`, `SetReversed`, `FreezeFrame(item, at, duration, stillMedia)` |
| Properties [CORE-13] | `SetProperty<T>(items, key, value, at?)` (keyframe-aware), `SetVisual/SetAudio/SetLook/SetChroma/SetMask/SetCrop/ResetTransform`, `Add/Remove/Move/SetKeyframeValue/ClearKeyframes` |
| Text [CORE-14] | `AddText`, `SetText` (coalesce key `text:<id>`), `SetTextStyle`, `SetTextAnimation` |
| Subtitles and captions [CORE-15] | `AddCue`, `SetCueText`, `SetCueRange`, `SplitCue(at, textSplit?)`, `MergeCues`, `DeleteCues`, `ShiftCues(track, deltaUs, range?)` (re-times a whole track or a range in one history entry; on grid, no overlap, clamped at 0), `ImportSubtitles` (overlaps spill to a second track), `SetSubtitleStyle/Position/BurnIn/Language`, `AddGeneratedCaptionTrack`, `ReplaceGeneratedCaptions(track, range?)` |
| Transitions [CORE-16] | `SetTransition(ref, spec?)`, `ApplyTransitionToAll`; `TransitionLimits.of(project, ref)` |
| Tracks, markers, project [CORE-17] | `AddTrack/DeleteTrack/MoveTrack/RenameTrack/SetTrackFlags/SetAudioRole`, `AddMarker/UpdateMarker/DeleteMarker`, `SetCanvas`, `SetFrameRate` (runs `requantize`), `SetBackground`. (`LayerLimits` is CORE-09 and checks the D-14 limits after every command using CORE-36's `visual_packing.dart`; from CORE-38 the two layer caps only set the informational `aboveLivePreviewCap` state and never reject.) |

Overlap and ripple per D-10/D-11; on the main lane with ripple on, inserts and moves snap to the nearest cut. Transition limits: all kinds ≤ `2·min(leftAvail, rightAvail)`; overlap kinds (cross dissolve, slide, wipe, zoom) also ≤ `2·min(leftHandle, rightHandle)` (handles divided by edge speed, mirrored for reversed clips, infinite for stills). Edits that break adjacency drop the transition; undo restores it.

### 7.3 History (snapshots, CORE-19)

```dart
final class EditSession {
  EditProject get project; HistoryStatus get history /*canUndo, canRedo, undoLabel, redoLabel, position*/;
  EditOutcome apply(EditCommand c, {String? coalesceKey, Duration coalesceWindow = const Duration(seconds: 1)});
  EditPreview dryRun(EditCommand c); SessionTransaction begin(String label);
  HistoryStep? undo(); HistoryStep? redo(); HistoryStep? jump(int steps);
  void applyPoolChange(PoolChange c);   // sticky: imports, probe/proxy/status updates
  EditOutcome applyPoolEdit(PoolEdit e);// undoable: RelinkAssets, RemoveAssets (unused only)
  void updateView(ViewState Function(ViewState) f); Set<MediaId> retainedMedia(); }
```

- Undo stores **snapshots** of the `Timeline` root (structural sharing makes an entry ≈ 4–40 KB), not inverse commands: correct by construction, compound edits and caption batches are free.
- The pool is outside snapshots: imports are sticky (undo never empties the bin); relink and remove are undoable `PoolDelta`s.
- Limits: 200 entries or ≈ 48 MB (approximate bytes), oldest evicted. History is not persisted.
- `Timeline.revision` and `Track.changedAt` are **session-monotonic stamps**, never reused after undo (UI tile caches and engine plan revisions can't collide). `editCount` counts committed entries and is never decremented ("touched stays touched").
- **Transactions** (gestures): `update(cmd)` applies to the base captured at `begin`, never cumulatively; `commit` adds exactly one entry (no-op if unchanged); `cancel` restores the base. A second `begin` cancels the first. The UI wrapper (`EditTransaction`, UX-08) adds per-frame state coalescing and transient overrides (§11.8).

---

## 8. Persistence (CORE-22 … CORE-28)

### 8.1 Roots and bundle layout

`StoreRoots { support, cache, documents }` are plain paths built by `EditorBootstrap` from `danaview_data` `AppStorage` (`getApplicationSupportDirectory()`, `getTemporaryDirectory()`, Documents). **Editor files never go into `Documents`** (that folder is the user's "On This Device" library).

```
<support>/danaview/editor/
  projects/<projectId>/project.dnproj   project.dnproj.bak   journal/{a,b}.dnproj   journal/recovered-<ts>.dnproj
                       meta.json (summary; rebuildable)   refs.json (GC input)   poster.jpg
                       assets/luts/<id>.cube + <id>.vlut   assets/recordings/<id>.wav   assets/stills/<id>.png
                       backups/pre-migration-s<N>.dnproj
  media/<hh>/<quickHash>/<sanitized name>     managed copies, content-addressed, shared by projects   (backup-excluded)
  derived/<specHash>.mp4                      reversed renditions, shared, regenerable                (backup-excluded)
  trash/<projectId>-<ts>/                     staged deletes
<support>/danaview/speech/{models,transcripts,jobs,work}/   (AI, all backup-excluded, D-20)
<cache>/danaview/editor/{thumbs,waves,proxies,sprites,looks,work}/   engine-owned formats; "Clear editor cache" target
```

Backup exclusion: iOS `NSURLIsExcludedFromBackupKey` on `media/`, `derived/` and `danaview/speech/` (set through `MediaAccessPort.excludeFromBackup`, which refuses paths outside the editor roots, D-44); project bundles, including voice recordings, stay in iOS backups. **Android excludes the whole `files/danaview/editor/` and `files/danaview/speech/` trees** from Auto Backup and device transfer (`res/xml/danaview_data_extraction_rules.xml` for API 31+ and `danaview_backup_rules.xml` for ≤ 30, referenced from the app manifest, CORE-28): Android backup rules take no wildcards, so per-project `assets/recordings` (WAV at 5.8 MB/min) and stills cannot be excluded selectively, and exceeding the 25 MB Auto Backup quota fails the **whole** app backup (player library and profile included); persisted URI grants and managed copies don't survive a restore anyway. Documented in the user guide and privacy text ("On Android, video editing projects are not included in device backups"); owner sign-off D-43(f); verified with the `bmgr` procedure (V-A7, QA-10). After an iOS restore, projects open with missing managed copies and the relink flow handles them, including "Relink several" (§9.3).

### 8.2 File format

Two lines, UTF-8:

```
{"format":"danaview.editor.project","schema":1,"minReader":1,"app":"1.1.0+3","savedAt":"…","docRevision":812,"saveId":"sv_…","bodyBytes":48213,"bodySha256":"…"}\n
{"id":"pr_…","meta":{…},"settings":{…},"tracks":[…],"markers":[…],"pool":{…},"view":{…}}\n
```

Body conventions: integer µs times; colours `"#RRGGBBAA"`; shortest round-trip doubles; default-valued fields omitted; fixed key order (deterministic bytes); items tagged `"t":"clip"|"text"|"cue"`; enums as lower-camel strings; unknown enum values decode to the default with a `ProjectOpenWarning`. The header can be read without the body (Projects list, `needsNewerApp`). The normative body schema is `schema/project.v1.schema.json` (CORE-22). **No persisted string holds an absolute app-container path** (iOS changes the container UUID on every update; the player needed `resolveStoredPath` for exactly this): editor files use `AppRelativeLocator(root, relPath)`, `meta.json` stores the poster as a bundle-relative name (`ProjectSummary.thumbnailPath` is resolved at runtime), and `refs.json` stores root-relative paths. The only exception is `BookmarkLocator.lastKnownPath`, a display hint never used to open a file. CORE-22 and CORE-25 tests encode every locator kind under a fake `/var/mobile/Containers/Data/Application/<uuid>/` root and assert no persisted byte sequence contains the container prefix.

### 8.3 Atomic writes, autosave, recovery

- Every filesystem call goes through `StoreFs` (`LocalStoreFs`, and `FaultInjectingFs` for tests). `AtomicFile.write`: write `path.tmp-<rand>`, flush (fsync [VERIFY V-D1]), rename `path → path.bak`, rename tmp → `path`. Read order: `path` if its checksum is valid, else the newest valid of `{tmp-*, .bak}`; none valid → `ProjectHealth.corrupt` with "Restore last good version" when a backup or journal exists. CORE-24 crashes the fake at every step and asserts a valid document is always recoverable.
- Encoding is incremental on the main isolate (`FragmentCache`, an `Expando` keyed by object identity: ≤ 3 ms after a typical edit at 2,000 items); a long-lived **writer isolate** hashes and writes. One serial queue per project, latest request wins.

| Trigger | Writes |
|---|---|
| Commit, pool change, view change | Autosave to the next journal slot (a/b), debounced 2 s idle, forced at 10 s; skipped while a transaction is open |
| ⌘/Ctrl+S, Project › Save | Main + meta + refs; journal truncated; clears "Recovered" |
| App hidden/paused, editor close (waits ≤ 3 s) | Main + meta + refs + poster |

Recovery: at app start, `recoverable()` lists projects whose newest valid journal slot has `docRevision > main.docRevision` and `baseSaveId == main.saveId` (only after a crash, kill or failed background save). `restore` promotes the journal atomically; `discard` deletes it; opening with a pending recovery returns `LoadedProject.pendingRecovery`; "Open last saved" keeps the journal as `recovered-<ts>` until the next successful save. Save failures surface as `SaveStatus.failed(StoreFailure)`; edits stay in memory and the next trigger retries.

### 8.4 Repository

```dart
abstract interface class ProjectRepository {
  Stream<List<ProjectSummary>> watchSummaries();
  Future<ProjectId> create(NewProjectSpec spec);   // empty(name, canvas?) | fromMedia(picks, name, initialPlayhead, origin)
  Future<LoadedProject> open(ProjectId id);        // read → migrate → decode → validate → repair → recovery check; isolate; ProjectBusy if open
  Future<SaveReceipt> save(EditSession s, {required SaveReason reason}); void requestAutosave(EditSession s);
  Future<void> flush(ProjectId id); Future<void> close(ProjectId id);
  Future<void> rename(ProjectId id, String name);  // 1–80 chars after trim
  Future<ProjectId> duplicate(ProjectId id, {String? name});   // "<name> copy", "<name> copy 2"; shares managed media
  Future<void> delete(ProjectId id);               // atomic move to trash/, guarded delete, then GC
  Future<List<RecoverableSession>> recoverable(); Future<LoadedProject> restore(RecoverableSession s); Future<void> discard(RecoverableSession s);
  Future<ProjectId?> findUntouchedProjectFor(String pathOrUri);   // origin.fromPlayer fingerprint match && editCount == 0
  Future<ProjectStorageReport> storageReport(); }
final class ProjectSummary { ProjectId id; String name; DateTime updatedAt; TimeUs duration; AspectRatio aspect; String? thumbnailPath;
  int missingMediaCount; bool hasRecovery; int bytesOwned; ProjectHealth health /*ok|needsNewerApp|readOnlyNewer|corrupt*/; }
```

`create(fromMedia)` probes media through the engine, imports it (§9.1) and derives settings from the first video: aspect snapped to a standard ratio within 1%; frame rate snapped to the nearest supported integer rate (cap 60); base short side 720 if the source ≤ 720 px, else 1080, or 2160 when the source is ≥ 2160 and capabilities allow; `view.playhead = quantize(initialPlayhead)`. No global index: the Projects list scans `projects/*/meta.json` (cheap at 1,000) and rebuilds bad ones in an isolate.

### 8.5 Migrations and versioning

`schema` increments on every format change; `minReader` increments only when an older app would misread. Migrations are pure functions on **raw JSON maps** in the decode isolate (`Migrations.chain`, `s<N> → s<N+1>`), idempotent; opening never writes; the first save after a migration copies the original to `backups/pre-migration-s<N>.dnproj`. `LoadedProject.migratedFrom` drives a one-time toast. Newer schema per D-12. v1 ships the framework plus a test-only `s0 → s1` migration; every schema keeps fixtures in `test/fixtures/projects/s<N>/` that must migrate, validate, re-encode and round-trip. ai.md's provenance/origin fields are part of s1 (no bump).

---

## 9. Media management (CORE-27, CORE-28, engines)

### 9.1 Import policy (originals are never touched)

| Source | Engine hands over | Stored as | Ownership |
|---|---|---|---|
| iOS Photos (PHPicker, `.current`, no transcode) | a file the **native** completion handler has already cloned (APFS `clonefile`, copy fallback) into `<cache>/danaview/editor/work/picks/<uuid>/<name>` before returning, because the system deletes the provider's temp file when the handler returns and Dart only runs after the channel hop | Dart hashes it and moves it into `media/…` (dedupe by quickHash); `OwnedFileDeleter.canConsume` allows files under `work/picks/` and `work/drops/` | managedCopy |
| iOS Files (document picker, open in place) | security-scoped URL | `BookmarkLocator` | external |
| Android Photo Picker / SAF | `content://` URI | `ContentUriLocator` + `takePersistableUriPermission(READ)`; managed copy if not persistable or < 32 grants remain | external / managedCopy |
| Player "Edit": file under `Documents` | path | `AppRelativeLocator(documents, rel)` | external |
| Player "Edit": Android incoming cache copy | path in purgeable cache | copied into `media/…` after a free-space preflight (size + 64 MB) with a cancellable progress dialog (UX-41; the same dialog serves large drops) | managedCopy |
| Player "Edit": iOS in-place URL | path with access started by AppDelegate | bookmark via the port | external |
| External drop (iOS/Android) | temp file / temporary URI grant | copied into `media/…` | managedCopy |
| Voice recording, freeze still, LUT | engine output / picked `.cube` | `projects/<id>/assets/…` (LUT copied + `.vlut`) | projectOwned |
| Reversed rendition | engine job output | `derived/<specHash>.mp4` | projectOwned (shared) |
| Desktop (later) | path | `FileLocator` | external |

Only app-owned temp files may be moved, and only into editor roots (`OwnedFileDeleter.canConsume`). Re-picking the same file reuses the same `MediaId` within a project.

### 9.2 Ports

```dart
abstract interface class MediaAccessPort {                 // core interface (model/pool, CORE-04); implemented by the engine plugin (ENG-03)
  Future<ResolvedMedia> resolve(MediaLocator l);          // refreshes stale bookmarks
  Future<MediaStat?> stat(MediaLocator l);                // null = missing; throws MediaAccessFailure.accessLost
  Future<String> quickHash(MediaLocator l);
  Future<MediaLocator> persist(PickedMediaHandle h);      // bookmark / persisted grant / managed copy decision input
  Future<void> release(MediaLocator l); Future<void> excludeFromBackup(String dirPath); Future<int> remainingGrantBudget(); }
abstract interface class MediaPoolService {
  Future<List<ImportOutcome>> import(EditSession s, List<PickedMedia> picked, {ImportTarget? target});
  Stream<MediaAvailabilityReport> watchAvailability(EditSession s);   // on open, resume, after relink
  Future<RelinkCheck> checkRelink(EditSession s, MediaId id, PickedMedia candidate);
  Future<List<RelinkProposal>> autoMatch(EditSession s, List<PickedMedia> picks);   // "Relink several": each pick → best missing asset via checkRelink
  Future<EditOutcome> relink(EditSession s, Map<MediaId, PickedMedia> picks);   // one undoable "Relink media"
  Future<List<RelinkCandidate>> findInSameFolder(EditSession s, PickedMedia anchor); }  // path locators only
```

`DartIoMediaAccess` (core, CORE-27) is the default for plain paths and the desktop path later.

### 9.3 Availability and relink

States: `available`, `missing`, `accessLost` (grant revoked, bookmark unresolvable), `changed` (found but hash differs: "Use updated file" or Relink), `derivedMissing` (rendition/still/proxy gone: requeue silently). Offline clips stay on the timeline; preview shows placeholders; export is blocked. `checkRelink` → `match` (fingerprint equal, or duration ±100 ms with equal kind and dimensions) | `durationMismatch` (accept clamps clips, with a notice) | `differentKind` | `unsupported(reason)`. `findInSameFolder` works only where the folder is readable (app `Documents`, desktop); the UI hides that button for content URIs and document-picker files. **Relink several** (for restored devices where every Photos copy is missing): one multi-pick from Photos or Files → `autoMatch` pairs each pick with a missing asset (`match` first by fingerprint, then by duration ±100 ms with equal kind and dimensions; ties left unassigned) → a confirm list → one undoable `relink`.

### 9.4 Garbage collection

Mark = union of every `refs.json` (managed paths, derived spec hashes, persisted grants, `retainedMedia()` of open sessions) plus in-flight imports and jobs. Sweep = unreferenced files under `media/` and `derived/` older than 24 h, and unreferenced URI grants (released). Runs 30 s after start (idle), after a project delete, and from Settings › Storage; **never during an export**.

### 9.5 Proxies

Proxy state lives on the pool asset; the file sits in `<cache>/danaview/editor/proxies/<quickHash>-540.mp4`. Preview plans carry `proxyUri` when ready and the engine chooses based on `setUseProxies`; **export plans never carry proxies**. Setting: Auto (default: proxy when long side > 1920, fps > 60, HDR, 10-bit or bitrate > 40 Mbps, **or when any clip plays the media faster than 2×** — at up to 10× the preview would otherwise decode 300–600 source fps) / Always / Off. **Default by tier (owner decision 2026-10-11, D-43(e) point 1):** Always on the `minimal` and `low` tiers on both platforms (proxies are generated in the background after import; D-40), Auto on mid and high. Preview uses proxies; export always uses the originals. On Android, fast items additionally cap their decoded frame rate at the project fps with Media3's `setFrameRate` (AND-08).

### 9.6 The deletion guard

`OwnedFileDeleter` is the **only** delete path in the editor (Dart). It canonicalizes and resolves symlinks, requires the target to be inside `editorSupport` or `editorCache` and outside `documents`, and refuses any asset whose ownership is `external`. A refused delete throws `OwnershipViolation` (a bug: logged, asserted in debug, never performed). Native code deletes only its own partial outputs inside Dart-supplied paths under the editor roots. Tests fuzz the guard with symlinks, `..`, case variants and Unicode normalization. Its write-side counterpart is `DocumentsExportWriter` (D-44), the only writer into `Documents`.

---

## 10. Formats

### 10.1 SRT and WebVTT (CORE-20)

`SubtitleCodec.parse(bytes, hint?) → SubtitleParseResult { format, cues, issues (line, kind), strippedTags, ignoredSettings, detectedEncoding }` (run in `Isolate.run`); `serialize(cues, format, offset, bom)`. Decoding: BOM wins (UTF-8/16LE/16BE) → NUL pattern ⇒ UTF-16 → strict UTF-8 → Windows-1252 → Latin-1; `\r\n`, `\r`, `\n`. SRT is tolerant (index optional, `,` or `.`, 1–3 digit fractions, > 99 h, trailing coordinates ignored). VTT requires `WEBVTT`, skips `NOTE/STYLE/REGION`, ignores cue settings, decodes entities. `<i>`/`<b>` kept and balanced; other tags and `{\an8}` stripped. Invalid cues become issues; the rest import. On insert, starts round to the nearest frame and ends are ≥ start + 1 frame. Serialization: half-up ms; SRT numbered from 1 with CRLF; VTT with LF; UTF-8 without BOM; blank lines inside a cue collapsed; `-->` → `->`. `parse(serialize(x)) == x` (property-tested) over a corpus with BOMs, UTF-16, CJK, RTL and malformed files. Suggested export name `<project>.<bcp47>.srt|vtt`.

### 10.2 `.cube` and `.vlut` (CORE-21, D-07)

Parser: `TITLE`, `LUT_3D_SIZE` 2–65, `LUT_1D_SIZE` (converted to 3D 33³ with a notice), `DOMAIN_MIN/MAX`, Resolve's `LUT_*_INPUT_RANGE`, comments, blank lines; errors carry line numbers ("Line 14: expected 3 numbers"); > 65 or > 16 MB → "LUTs up to 65×65×65 are supported." `.vlut` v1 (little-endian): `'VLUT'`, u16 version = 1, u16 N, then N³ × RGB **float16**, red fastest, domain remapped to [0,1]. On import the original `.cube` and the `.vlut` are written to `assets/luts/`. Engines load only `.vlut`, uploaded as a tiled 2D texture (N tiles of N×N in a ⌈√N⌉ grid; ≤ 585×520 for N = 65), sampled trilinearly. The 12 built-in looks (Teal & Orange, Warm, Cool, Vivid, Matte, Fade, Mono, Noir, Sepia, Vintage, Cinematic, Pastel) are generated deterministically by `packages/danaview_editor/tool/gen_looks.dart` (UX-24) and shipped as `.vlut` assets, extracted to `<cache>/danaview/editor/looks/` on first use.

### 10.3 `.vsprite` (API-04, D-06)

Little-endian header `'VSPR'`, u16 version = 1, u16 flags (bit0 = hasReveal), u32 w, u32 h, f32 scale (sprite px per canvas px); then a zlib stream of `w·h·4` bytes **premultiplied RGBA8, sRGB-encoded**; if hasReveal, a second zlib stream of `w·h·2` bytes = u16 glyph order per pixel (0xFFFF = background). Content-addressed under `<cache>/danaview/editor/sprites/<sha1(TextLayoutSpec JSON, scale, canvas, fontsVersion)>.vsprite`. **Raster scale** (CORE-31 `collectSpriteRequests`, per item, not per export): `exportScale × maxAnimatedScale(item)`, where `maxAnimatedScale` is the largest `xf.s` the item reaches over its range (static scale, keyframes up to 8×, and text-animation scale channels), then reduced so that neither sprite side exceeds `min(capabilities.maxTextureSize, 2 × output long side)`; engines draw with `sscale`, so an animated 8× title is as sharp as the vector preview up to that clamp. `EditorCapabilities.maxTextureSize` is `GL_MAX_TEXTURE_SIZE` on Android (often 4096 on low-end Mali/Adreno) and 16384 on iOS Metal.

---
## 11. RenderPlan contract v1 (Dart ↔ native engines)

### 11.1 Principles

1. **Resolved, flat, engine-ready.** Engines see layers with time maps, a fixed effect set, linear keyframes, canvas masks, solids, sprites and audio segments with gain envelopes. No ripple, transition kinds, text animations, ramps, track flags or mute/solo reach native code (D-01).
2. **One animation primitive**: `[[tUs, v], …]` in **absolute timeline µs**, linear between keys, held outside them. Easing is pre-sampled by the compiler.
3. **Pure compile in Dart** (`compileRenderPlan(project, target, resolver)`; isolate when > 300 items), memoized by item identity, with stable layer ids for cheap diffs.
4. **Transport:** UTF-8 JSON bytes inside the Pigeon control API (§12.6), encoded in an isolate, decoded natively off the main thread (`JSONDecoder` / `android.util.JsonReader`). Plans are never Pigeon object graphs.
5. **Normative sources:** `packages/danaview_editor_core/schema/render_plan.v1.schema.json` (JSON Schema 2020-12) and `schema/effects_reference.md` (render math), both from CORE-29. This section and those files must agree; the fixture corpus in `test/fixtures/render_plans/contract/` is decoded by the Dart, Swift and Kotlin tests.

### 11.2 Plan schema v1

Plain JSON. Times are integer µs; colours `"#RRGGBBAA"`; numbers are JSON numbers; unknown keys **must be ignored** by decoders; omitted optional keys take the stated default.

**Plan**

| Key | Type | Req | Meaning |
|---|---|---|---|
| `v` | int = 1 | ✓ | Schema version |
| `rev` | int ≥ 0 | ✓ | Revision stamp (session-monotonic) |
| `target` | `"preview"` \| `"export"` | ✓ | |
| `canvas` | Canvas | ✓ | |
| `durUs` | int ≥ 0 | ✓ | Timeline duration (end of last layer/segment) |
| `assets` | object<id, Asset> | ✓ | Every id referenced by layers/segments |
| `layers` | Layer[] | ✓ | Sorted by (`z`, `t[0]`, `id`) |
| `audio` | AudioSeg[] | ✓ | Sorted by (`t[0]`, `id`) |
| `req` | Requirements | – | Preview only, informational |

**Canvas** `{ "w": even int ≥ 16, "h": even int ≥ 16, "fps": 24|25|30|48|50|60, "gridFps": 24|25|30|48|50|60 (default = fps), "bg": colour }`. For export, `w/h/fps` are the output size and rate (the compiler letterboxes the project canvas inside; never silent crop) and `gridFps` is the project rate, the grid every layer edge and map breakpoint lies on (§5, D-35).

**Asset**

| Key | Type | Meaning |
|---|---|---|
| `kind` | `"video"`\|`"audio"`\|`"image"`\|`"lut"`\|`"sprite"` | |
| `uri` | string | `file://…` or `content://…` (never http) |
| `bookmark` | base64? | iOS security-scoped bookmark; native refcounts `startAccessingSecurityScopedResource` per session |
| `fp` | string | `quickHash`, cache key (video/audio/image) |
| `proxyUri` | string? | Preview only; same timestamps as the source |
| `w`, `h`, `rot` | int? | Display size (rotation applied) and rotation 0/90/180/270 |
| `durUs` | int? | |
| `transfer` | `"sdr"`\|`"hlg"`\|`"pq"` (default sdr) | HDR sources are tone-mapped to SDR before effects |
| `hasAudio` | bool? | |
| `n` | int | `lut` only: `.vlut` size (2–65) |
| `sw`, `sh`, `sscale`, `reveal` | int, int, number, bool | `sprite` only: pixel size, sprite px per canvas px, has glyph-order map |

**Layer**

| Key | Type | Default | Meaning |
|---|---|---|---|
| `id` | string | | Stable: `<itemId>#v` (clip/text), `<itemId>#bd` (blurred backdrop), `<itemId>#tx<n>` (transition helper solid), `<cueId>#c` (burned cue) |
| `z` | int | | Opaque sort key (§11.4) |
| `seq` | int ≥ 0 | | `media` layers only: the visual sequence/composition-track slot assigned by core packing (§13.5, CORE-36). Layers sharing a `seq` never overlap in time; engines use it as-is (Android sequence index above the clock band, iOS composition video track) |
| `t` | [t0, t1] | | Half-open timeline range, t0 < t1 |
| `kind` | `"media"`\|`"image"`\|`"solid"`\|`"sprite"` | | |
| `asset` | string | | media/image/sprite |
| `map` | [[t0,t1,s0,s1], …] | | `media` only. Segments are contiguous, cover `t`, and have `s1 ≥ s0`; rate = `(s1−s0)/(t1−t0)` ∈ [0.1, 10]. Exact (unbiased) source µs |
| `hold` | bool | false | `media`: show the frame at `map[0].s0` for the whole range (pending freeze still) |
| `color` | colour | | `solid` |
| `base` | [w, h] number | | Size in canvas px of the cropped source after fit, before transform (`sprite`: `sw/sscale, sh/sscale`) |
| `crop` | [l, t, r, b] | [0,0,1,1] | Normalized, display-oriented source |
| `xf` | `{cx, cy, s, r, fx, fy, op}` | `{W/2, H/2, 1, 0, false, false, 1}` | Centre in canvas px, scale ×, rotation degrees clockwise (y down), flips, opacity [0,1] |
| `fx` | Effects | none | |
| `anim` | object<channel, [[tUs, v], …]> | none | Absolute µs; overrides the static value of that channel |
| `cmasks` | CanvasMask[] | none | Canvas-space masks (wipe) |

**Effects**: `adj {exposure, brightness, contrast, highlights, shadows, saturation, temperature, tint}` each [-1,1] (omitted = 0); `detail {sharpen, blur, vignette}` each [0,1]; `lut {asset, i}` (i ∈ [0,1]); `chroma {key "#RRGGBB", sim, smooth, spill}` each [0,1]; `mask {shape "rect"|"ellipse", cx, cy, w, h (layer-normalized over `base`), r (deg), corner [0,0.5] (fraction of min(w,h)), feather [0,1], op [0,1], inv bool}`.

**Animatable channels**: `xf.cx xf.cy xf.s xf.r xf.op`, `adj.<name>`, `detail.<name>`, `mask.cx mask.cy mask.w mask.h mask.r mask.feather mask.op`, and `reveal` (sprite: number of glyphs shown, floor applied). LUT intensity, chroma, crop, flips and colours are not animatable.

**CanvasMask** `{cx, cy, w, h (canvas px), r (deg), feather (px), inv bool, anim?: {cx, cy, w, h}}`: multiplies the layer's alpha after placement.

**AudioSeg** `{id ("<itemId>#a"), asset, stream (int, default 0), t [t0,t1], map [[t0,t1,s0,s1], …], gain [[tUs, g], …] (linear, ≥ 0, ≥ 1 point), pitch bool (true = keep pitch)}`.

**Requirements** (preview) `{offline: [mediaId], pendingReverse: [itemId], pendingStill: [mediaId]}`. Export compilation returns `ExportBlocked(requirements)` instead of a plan when anything is pending or offline.

**Patch** `{v, from, to, canvas?, durUs?, assets?: {upsert: {id: Asset}, remove: [id]}, layers?: {upsert: [Layer], remove: [id]}, audio?: {upsert: [AudioSeg], remove: [id]}}`. Applied atomically and only when `from` equals the engine's current `rev`; otherwise the engine fails with `planOutOfSync` and `PlanSync` sends the full plan (a second failure → `PreviewFailed`). Upsert replaces the whole object by id; the engine re-sorts.

**Transient** `{v, item, layers: [{id, xf?, crop?, base?, fx?, anim?, cmasks?}]}`: param fields only, merged over the current layer (last write wins), never assigned a revision, never persisted. Dropped by the next plan/patch touching that layer or by `clearTransient(item)`. Timing fields in a transient are ignored (debug counter).

**Patch classification (native).** *Structural*: layer set change, or any change of a layer's `kind`, `z`, `t`, `asset`, `map`, `hold`; any audio segment change except `gain`; canvas, `durUs`, asset set. *Param-only*: `xf`, `crop`, `base`, `fx`, `anim`, `cmasks`, `color`, audio `gain`. Param-only patches swap an atomic `ParamSnapshot` and redraw when paused (≤ 50 ms low / 30 ms mid; iOS through the compositor's redraw cache, Android through `PausedFrameRenderer`, D-36); structural ones rebuild the platform composition and restore playhead and play state (budgets in §13.4; Android debounces them and keeps the paused frame on screen). The ack reports `{rev, structural, applyMs}`.

### 11.3 Plan invariants (CORE-29 validator; native validators mirror them)

Layer ids unique; every referenced asset exists with a compatible kind; `t0 < t1 ≤ durUs`; **every layer `t` edge, every `map` breakpoint, every audio segment `t` edge and `durUs` lie on the `canvas.gridFps` grid** (D-35; CORE-06 places ramp breakpoints on frame starts); media maps contiguous over `t` with positive rates in [0.1, 10]; `media` layers carry a `seq` and layers sharing a `seq` don't overlap in time; keyframe arrays sorted with unique times; values within the ranges above; `z` bands consistent (§11.4); within one `z`, layers overlap only inside lowered transition windows (at most two at once); sprite `reveal` only on sprite layers whose asset has `reveal: true`; audio maps contiguous; gain ≥ 0. A violation natively is `planInvalid` (a bug: logged with the layer id, preview shows the last good frame).

### 11.4 Z order and bands

`z = band·10000 + (laneIndexInBand + 1)·10 + sub`; bands video 0, overlay 1, text 2, subtitle 3; `sub` 0 for clip layers, +5 for transition helper solids, −5 for `#bd` backdrops. Main lane = 10, its backdrop = 5, first text lane = 20010, first burned subtitle track = 30010. Engines treat `z` as an opaque sort key; within one `z` a later `t0` draws on top (the incoming clip of a transition). Text and subtitles are always the top bands (D-05).

### 11.5 Time semantics

- **Which frame is being rendered** is decided by the platform-time rule (§5, D-35): an output frame's platform time maps to `k = frameIndexNearest(τ)` and every evaluation below uses `t = timeOfFrame(k)` of the output rate.
- Media layer at timeline time *t* ∈ `t`: `s = s0 + (t − t0)·(s1 − s0)/(t1 − t0)` on the containing segment. **Displayed source frame = the sample with the greatest PTS ≤ s + 500 µs** (PTS on the asset's presentation timeline with edit lists applied). `hold`: `s = map[0].s0` throughout. Images ignore `map`.
- Audio: sample-accurate `s(t)` with no ε. A clip's video layer and audio segment are compiled from one `ClipTimeMap` and share segment boundaries, which is the A/V-sync contract (≤ 1 frame and ≤ 20 ms over 10 min; QA-03 clap/flash test).
- `pitch: true` → time-stretch keeping pitch (iOS `.timeDomain` per §13.2 / IOS-01 V-N21, Android Sonic `shouldMaintainPitch`); `false` → varispeed/resample.
- Reversed clips reference the rendition asset with an increasing map (`r = R.end − s`); engines never see "reverse".
- Frame-rate conform for sources whose rate differs from the plan's: iOS floor, Android nearest (D-04); consistent between preview and export per platform.

### 11.6 Render math (normative; implemented in Metal CI kernels, GLSL ES 1.00 and the Dart reference renderer)

All maths runs on **straight-alpha, gamma-encoded BT.709 RGB in [0,1]** with colour management off (iOS `CIContext` working/output colour space `NSNull`; Android `WORKING_COLOR_SPACE_ORIGINAL`). HDR sources arrive tone-mapped to SDR (iOS `supportsHDRSourceFrames = false`; Android `HDR_MODE_TONE_MAP_HDR_TO_SDR_USING_OPEN_GL`). `Y(c) = dot(c, (0.2126, 0.7152, 0.0722))`. Values are the plan's model units (adjust ∈ [-1,1]; detail, chroma, mask ∈ [0,1]).

Per layer, in order (D-08): **sample** (video frame / image / solid / sprite) → **crop** → **chroma key + spill** → **grade** → **LUT** → **blur** → **sharpen** → **vignette** → **mask** → **place** → **canvas masks** → **composite**. Sprites and solids skip crop through mask.

| Stage | Formula |
|---|---|
| Chroma key | `Cb = (B−Y)/1.8556`, `Cr = (R−Y)/1.5748` for pixel and key; `d = ‖(Cb,Cr) − (Cbk,Crk)‖`; `a = smoothstep(s0, s0 + s1, d)` with `s0 = sim·0.25`, `s1 = max(0.001, smooth·0.25)`. Spill: `k = normalize(Cbk,Crk)`; `(Cb,Cr) −= k·max(0, dot((Cb,Cr), k))·spill`; rebuild RGB keeping Y. `alpha *= a` |
| Exposure | `c = pow(pow(c, 2.2)·exp2(2·exposure), 1/2.2)` (±2 EV) |
| Brightness, contrast | `c += brightness/4`; `c = (c − 0.5)·(1 + contrast) + 0.5` |
| Highlights, shadows | `c += highlights/4 · smoothstep(0.5, 1, Y)`; `c += shadows/4 · (1 − smoothstep(0, 0.5, Y))` |
| Saturation | `c = mix(vec3(Y), c, 1 + saturation)` |
| Temperature, tint | `c.r *= 1 + temperature/10`; `c.b *= 1 − temperature/10`; `c.g *= 1 − tint/10`; then `clamp(c, 0, 1)` |
| LUT | trilinear lookup in the N³ table (tiled 2D texture); `c = mix(c, lut(c), i)` |
| Blur | separable Gaussian, `σ = blur·0.03·min(W,H)` in **plan-canvas px**, converted to source px by the layer's current scale and to render px by the render scale; radius `ceil(3σ)`, clamp-to-edge; skip when σ < 0.5 |
| Sharpen | `c += sharpen·1.5·(c − box3x3(c))` at render resolution, clamp |
| Vignette | `d = ‖(uv − 0.5)·(aspect, 1)‖ / ‖(aspect, 1)·0.5‖` over the layer box; `c *= 1 − vignette·smoothstep(0.35, 1, d)` |
| Mask | signed distance `sd` of a rotated rounded box (corner) or ellipse in layer-normalized space; `f = feather·0.25·min(w,h)`; `a = 1 − smoothstep(−f, f, sd)` (step when f = 0); `inv → 1 − a`; `alpha *= mix(1, a, op)` |
| Place | source rotated to display orientation (`rot`), cropped, scaled to `base`; `M = T(cx, cy)·R(r° cw, y-down)·S(s·(fx ? −1 : 1), s·(fy ? −1 : 1))·T(−base.w/2, −base.h/2)`; `alpha *= op`. **`boxAt` in Dart uses the same M** (CORE-07) |
| Canvas mask | same SDF as Mask, evaluated in canvas px, after placement |
| Composite | premultiplied source-over, bottom → top, onto the opaque `bg` |
| Sprite | premultiplied RGBA sampled with M; if `reveal` is animated, a pixel is drawn iff `glyph < floor(reveal(t))` |
| Audio | `out = Σ seg(t)·gain(t)` (linear interpolation of `gain`, range 0–2 = up to +6.02 dB, applied per sample: iOS `MTAudioProcessingTap` D-37, Android `GainProcessor`), 48 kHz stereo (mono duplicated; > 2 channels downmixed with ITU coefficients), hard-clipped to [−1, 1] (no limiter in v1; the iOS export pump clamps explicitly). The Dart reference mixer (API-03 `reference/audio_mix.dart`) implements this row and is the oracle for QA-11's PCM checks |

**Parity tolerance** (device output vs the Dart reference, and iOS vs Android): mean absolute error ≤ 1.5/255 per channel, 99th percentile ≤ 6/255, SSIM ≥ 0.98 on transform fixtures with edge pixels excluded. **Exported frames** (H.264/HEVC 4:2:0) additionally exclude content edges: pixels whose 3×3 range exceeds 48/255, dilated by 1 px, because chroma subsampling smears them; preview frames are compared without this exclusion (lead decision 2026-10-15, QA-03). QA-03's iOS reference renders live in `docs/v1.1/editor/qa/QA-03-parity/ios/` so the Android lane can compare against them.

### 11.7 Lowering table (compiler, CORE-30/31)

| Domain concept | Lowered to |
|---|---|
| Track hidden / muted / solo | layers / segments omitted |
| Fit + crop | `base` via the shared `baseSize()` |
| Item keyframes | `anim` channels shifted to absolute time |
| Volume keyframes × fades × mute/solo | one `gain` envelope; extra samples every 20 ms where products are non-linear (≤ 0.1 dB error) |
| **Fade** (cut c, duration d) | left `xf.op` ×(1→0) over [c−d/2, c]; right ×(0→1) over [c, c+d/2]; audio dips the same way |
| **Cross dissolve** | left extended to c+d/2 and right to c−d/2 using handle source at the edge speed; right on top with `xf.op` 0→1 over the window; audio equal-power crossfade sampled linearly |
| **Dip to black/white** | solid layer (`#tx`, z + 5) with `xf.op` 0→1 over [c−d/2, c] then 1→0 over [c, c+d/2]; no overlap; audio dips |
| **Slide (dir u)** | extended as cross dissolve; incoming `xf.cx/cy` from off-canvas to final and outgoing from final to off-canvas along u (ease-in-out cubic, 8 linear segments) |
| **Wipe (dir u)** | extended; a `cmasks` rect on the incoming layer sweeps across the canvas along u, feather 2% of the canvas dimension |
| **Zoom in/out** | extended; in: outgoing `xf.s` ×(1→1.25) with `op` 1→0, incoming `xf.s` ×(0.8→1) with `op` 0→1; out mirrors (outgoing ×1→0.8, incoming ×1.25→1) |
| Text animations | `xf.op`, `xf.cx/cy`, `xf.s` channels from `evaluateTextAnimation` breakpoints; typewriter → `reveal` channel 0→n over the in-duration |
| Speed ramps | multi-segment `map` with ≤ 250 µs source error at every frame start (typically 10–40 segments); every breakpoint is a frame start of the project grid (§11.3) |
| Visual packing | `seq` per media layer from `visual_packing.dart` (CORE-36, §13.5); the same function feeds `LayerLimits` |
| Background `BlurOfMain(r)` | `#bd` layer per main-lane clip: same map, `base` = fill canvas, `detail.blur = r`, z − 5 |
| Missing media | `solid` dark-grey placeholder + `req.offline` (preview); export blocked |
| Pending reverse | forward media layer + `req.pendingReverse` (preview); export blocked |
| Pending freeze still | `hold: true` media layer (or a neutral solid when `capabilities.holdFrame == false`) + `req.pendingStill`; export blocked |
| Text item / subtitle cue (export only) | sprite layer: `base` from the sprite, `xf` from the transform (cues anchored by `SubtitlePosition` using the sprite height), `anim` from the animation |
| Transition helper channels × user keyframes | evaluated on a merged breakpoint set into one channel per property (opacity multiplies; translate/scale compose) |

### 11.8 Diff, patches and transients (CORE-32)

`diffPlans(a, b)` is identity-first (memoized layers are `identical` when unchanged); `apply(diff(a, b), a) == b` is property-tested. `PlanMemo` keys compiled layers by item identity plus a context signature (track flags, neighbours, transitions, settings, asset identity), so a one-item edit at 2,000 items recompiles that item and its transition neighbours only (≤ 3 ms compile + diff). `transientFor(working, itemId)` compiles one item's layers for `setTransient`. During a gesture the UI sends transients ≤ 60 Hz; structural changes during a gesture are shown as timeline ghosts and reach native only on commit (one patch).

### 11.9 Versioning and contract tests

Every plan, patch and transient carries `"v"`. `EditorCapabilities.planVersions` lists what the engine decodes; the compiler emits the highest common version. Additive optional fields need no bump (decoders ignore unknown keys); any change of meaning bumps `v`, and the compiler keeps the previous emitter for one release. Contract tests: about 25 hand-written fixtures in `test/fixtures/render_plans/contract/` (CORE-29) validate against the JSON Schema and round-trip in Dart; the iOS XCTest (IOS-08) and Android JUnit (AND-08) suites decode, re-encode and compare every fixture; compile goldens (CORE-30/31) pin `compile(project) == plan`; render goldens compare devices with the Dart reference (QA-03).

---

## 12. Engine API contract (`danaview_editor_engine_api`, API-01)

### 12.1 Root

```dart
typedef EngineMedia = ResolvedMedia;                       // core type (D-27)
final class EditorEngineConfig { final String cacheRoot /*<cache>/danaview/editor*/, supportRoot /*<support>/danaview/editor*/; }
abstract interface class EditorEngine {
  Future<EditorCapabilities> capabilities();               // cached after first call
  Future<EditCompatibility> compatibility(String pathOrUri);   // ≤ 300 ms; Editable | NotEditable(code, message)
  Future<MediaProbe> probe(EngineMedia media);
  Future<PreviewSession> openPreview(PreviewConfig config);
  ThumbnailSource get thumbnails; WaveformSource get waveforms; MediaJobs get jobs; ExportService get exporter;
  VoiceRecorder? get voiceRecorder;                        // null when !capabilities.voiceRecording
  MediaPicker get picker; FileHandoff get files; MediaAccess get access /*implements core MediaAccessPort*/;
  BackgroundWorkGuard get background; ExternalDropTarget get drops;
  Future<int> freeBytes(String path); Stream<EngineSignal> get signals /*memoryWarning, thermal(level)*/;
  Future<void> trimCaches(CacheTrimLevel level); }
```

### 12.2 Preview

```dart
final class PreviewConfig { final int canvasWidth, canvasHeight, fps; final PreviewQuality quality /*auto|full|half|quarter*/; final bool useProxies; }
abstract interface class PreviewSession {
  int get textureId; ValueListenable<Size?> get frameSize;
  Future<PlanAck> setPlan(RenderPlan plan);                // encoded in an isolate
  Future<PlanAck> applyPatch(RenderPlanPatch patch);       // throws EngineFailure(planOutOfSync) → PlanSync resends full
  void setTransient(ItemId item, PlanTransient t); void clearTransient(ItemId item);   // fire-and-forget, ≤ 1/frame natively
  Future<void> play({TimeRange? loop}); Future<void> pause();
  Future<SeekAck> seek(TimeUs t, {SeekKind kind = SeekKind.exact});   // exact | scrub
  Future<void> setQuality(PreviewQuality q); Future<void> setUseProxies(bool on);
  Future<void> setRenderedRanges(List<RenderedRange> ranges);   // D-45 render-preview cache, playback only (added by INT-06)
  Future<void> setEditingMode(PreviewEditingMode m);       // normal | cropSource(item) | matte(item)
  Future<void> showSourceFrame(EngineMedia m, TimeUs sourceTime);   // trim-edge preview; cleared by seek/play
  Future<Color?> sampleColor(ItemId item, Offset normalizedSourcePoint);   // pre-key source, 3×3 average
  Future<List<Uint8List>> renderLookStills(ItemId item, List<LookSpec> looks, {required int heightPx});
  Future<void> refresh(); Future<Uint8List> debugCaptureFrame();   // RGBA of the displayed frame (debug/profile; QA)
  Stream<PreviewClock> get clock;                          // state changes + 10 Hz while playing
  Stream<PreviewEvent> get events;                         // firstFrame | stalled | recovered | degraded(q) | surfaceLost | failed(f)
  Future<void> dispose(); }
final class PreviewClock { final TimeUs time; final bool playing; final double rate; final int seq; }
final class SeekAck { final TimeUs requested, displayedFrameTime; final int displayedFrame, seq; }
final class PlanAck { final int rev; final bool structural; final int applyMs; }
final class RenderedRange { final TimeRange range /*plan µs, on the grid*/; final String uri /*file:// in <cache>/danaview/editor/renders/*/; final String hash /*CORE-37 rangeHash*/; }   // INT-06
```

Normative semantics: `seq` increases with every seek, play and pause, and each clock sample carries the `seq` of the last command it reflects. `seek(exact)` completes only after the composed frame for `frameIndexOf(t)` is in the texture; engines identify the displayed frame with `frameIndexNearest` of its platform time (D-35) and report `displayedFrameTime = timeOfFrame(displayedFrame)`. `seek(scrub)` may show any frame within ±1 GOP (proxy GOP when proxies are on) and still reports the displayed frame. Transients never touch the plan revision, history or disk.

**Adaptive preview (owner decision 2026-10-11, D-43(e)).** `PreviewQuality.auto` (the default) steps the preview resolution full → 1/2 → 1/4 under load (dropped frames, slow composites, thermal) and steps back up after a sustained recovery, reporting each step with `degraded(q)`; `full|half|quarter` pin the quality (UX-18's preview quality option). While playing, an exact seek may first show the nearest decoded frame and then refine to the exact frame; the `SeekAck` still reports only the exact frame. Under load a frame is dropped rather than a late or wrong one shown. Layers beyond the tier's live decode budget play as paused-exact still frames during playback only, and a rendered range of the render-preview cache (D-45) plays from its cached file; paused, scrubbing and exact seeks are always exact for every layer.

**Rendered ranges (D-45, INT-06).** `setRenderedRanges` replaces the session's whole set; the list must be sorted, non-overlapping, with non-empty ranges, a hash and a file inside `<cache>/danaview/editor/renders/` (`renderedRangesProblem`; otherwise `planInvalid`, or `permissionDenied` for a file outside the renders directory). During playback only, a rendered range plays from its file at its exact frame boundaries; paused, scrub and exact seeks use the live composition. The engine drops every range an applied patch touches until the next `setRenderedRanges`, so a stale render never plays: a removed or upserted layer whose old or new span overlaps it, a canvas change (every range), a duration change (the ranges ending after the shorter duration), a changed or removed asset the old plan had (every range); audio-only changes touch nothing; `setPlan` drops every range. The reference rule is `patchTouchesRange` (API-01 fake, `testing.dart`); IOS-19 and AND-18 implement it natively. The mobile Dart session sends `setRenderedRanges` on its plan queue, after every plan or patch sent before it.

### 12.3 Media services and jobs

```dart
abstract interface class ThumbnailSource { ThumbnailHandle request(ThumbnailRequest r, {required ThumbPriority priority}); }
final class ThumbnailRequest { EngineMedia media; int intervalMs; int tileIndex; int heightPx; int framesPerTile /*8*/; bool proxy; }
final class ThumbnailTile { Uint8List encoded /*JPEG strip*/; int frames; int frameWidthPx; }   // handle: result, cancel()
abstract interface class WaveformSource { MediaJob<WaveformPeaks> peaks(EngineMedia media, {int audioStream = 0}); }  // int8 min/max at 200 pairs/s
abstract interface class MediaJobs {
  MediaJob<GeneratedAsset> proxy(EngineMedia media);
  MediaJob<GeneratedAsset> reverse(EngineMedia media, TimeRange source, {required String outputPath});
  MediaJob<GeneratedAsset> freezeFrame(EngineMedia media, TimeUs sourceTime, {required String outputPath});
  MediaJob<ExtractedSpeechAudio> extractSpeechAudio(SpeechAudioJobRequest r);   // 16 kHz s16 mono WAV, sample-accurate
  MediaJob<GeneratedAsset> renderPreview(RenderPlan rangePlan, {required String outputPath});   // D-45 render-preview cache (added by INT-06)
  ProxyStatus proxyStatus(EngineMedia media); }
abstract interface class MediaJob<T> { String get id; Stream<double> get progress; Future<T> get result; void cancel(); void setPriority(JobPriority p); }
```

`renderPreview` (D-45, INT-06): `rangePlan` is a preview plan (`PlanTarget.preview`) cut to one range with times relative to its start; `outputPath` lies inside `<cache>/danaview/editor/renders/` (`renderPreviewDirName`). It runs through the ordinary job path (`startJob` with `JobKindMsg.renderPreview`, the plan as `PlanTransport` JSON in `JobRequestMsg.plan`; `cancelJob`; progress ≤ 4 Hz and done/failed as job events), default priority `background`; cancel deletes the partial file; refusals are `EngineFailure`s (`planInvalid` for a non-preview or invalid plan, `permissionDenied` for an output outside the renders directory). Until IOS-19 and AND-18 land, the native services are placeholders that fail with `notSupportedOnDevice`.

### 12.4 Export, recording, platform services

```dart
abstract interface class ExportService {
  Future<ExportPreflight> preflight(RenderPlan plan, EncodeSettings s);   // ok, maxHeightForPlan, warnings
  Future<ExportJob> start(RenderPlan plan, EncodeSettings s, {required String outputPath, required String title,
      ExportDetachedHandoff whenDetached = ExportDetachedHandoff.saveToGallery /*| keepForLater; D-39*/});
  Future<ExportJob> resume(String jobId);                  // iOS segment-resumable jobs (D-22); notSupportedOnDevice elsewhere
  Future<List<ExportJobState>> activeJobs(); }             // running (reattach) | resumable(jobId, doneFraction) | interrupted (one-shot)
                                                           // | completedWhileDetached(ExportResult, savedToGallery) (one-shot, D-39)
final class EncodeSettings { ExportContainer container /*mp4|mov*/; VideoCodec codec /*h264|hevc*/; int width, height, fps,
  videoBitrate, audioBitrate; int audioSampleRate /*48000*/, audioChannels /*2*/; int keyframeIntervalMs /*2000*/; bool stripLocation /*true*/; }
final class ExportProgress { ExportPhase phase /*preparing|rendering|finishing*/; double fraction; int framesDone, framesTotal;
  bool backgrounded, pausedInBackground /*iOS: stopped at background, resumes from the last complete segment on return*/;
  List<ExportWarning> warnings; }
final class ExportResult { String path; int bytes; TimeUs duration; String videoEncoderName; bool hardwareEncoder; }
abstract interface class VoiceRecorder { Future<MicPermission> permission(); Future<MicPermission> requestPermission();
  Future<void> openSystemSettings(); Future<RecordingSession> start({required String outputPath}); }   // WAV s16 48 kHz mono
abstract interface class RecordingSession { Stream<double> get levels /*20 Hz*/; Stream<RecordingInterruption> get interruptions;
  Future<RecordedAsset> stop() /*path, durationUs, startLatencyUs*/; Future<void> cancel(); }
abstract interface class MediaPicker { Future<List<PickedMedia>> pick(MediaPickRequest r); }   // photos | files; kinds video, audio, image, lut, subtitle
final class PickedMedia { String uri; String displayName; bool isTemporaryCopy; Uint8List? bookmark; int? sizeBytes; }   // core type (CORE-04), re-exported
abstract interface class FileHandoff { Future<FileHandoffResult> saveToPhotos(String path);
  Future<FileHandoffResult> saveToFiles(String path, String suggestedName); Future<FileHandoffResult> share(String path); }
abstract interface class MediaAccess implements MediaAccessPort { Future<bool> requestNotificationPermission(); }
abstract interface class BackgroundWorkGuard { Future<BackgroundLease?> acquire({required String title, required Stream<double> progress});
  Future<PowerState> powerState(); Stream<PowerState> get powerStateChanged; }   // D-45 `PlatformServices.powerState` (INT-06)
final class PowerState { bool charging; bool lowPowerMode; }   // reached as engine.background; native `powerStateChanged` signal
abstract interface class ExternalDropTarget { Future<void> setEnabled(bool on); Stream<ExternalDrop> get drops; }  // items + logical position
```

### 12.5 Capabilities and failures

```dart
final class EditorCapabilities { bool supported; String? unsupportedReason; DeviceTier tier /*minimal|low|mid|high*/; bool lowMemoryDevice;
  bool h264Encode, hevcEncode, hardwareH264, hardwareHevc, movContainer; Size maxExportSize; Map<int, int> maxFpsByHeight;
  int maxConcurrentVideoLayers /*2|3|4|6*/; int maxVisualSequences /*Android 2|3|4|6, ≤ (codec instances − 2) / 2 (AND-01); iOS 16; live preview only, export never refuses (D-45)*/;
  int maxTextureSize /*GL_MAX_TEXTURE_SIZE | 16384*/; int maxPreviewLongSide /*640|960|1280|1920*/; BackgroundExportKind backgroundKind
  /*none|paused (iOS iPhone: stops, resumes from last segment on return)|continued (iPad iOS 26+ with background GPU)|foregroundService*/;
  bool backgroundGpu; bool voiceRecording, proxiesRecommended, holdFrame,
  fpsUpconversion, externalDrop; double minSpeed /*0.1*/, maxSpeed /*10*/, maxAudioSpeed /*4*/; int maxLutSize /*65*/; List<int> planVersions; }
enum EngineErrorCode { mediaOffline, permissionDenied, unsupportedMedia, decoderInitFailed, decodeFailed, encoderUnavailable,
  encoderSizeLimit, encodingFailed, diskFull, io, planInvalid, planOutOfSync, gpuUnavailable, surfaceLost, interrupted,
  cancelled, busy, notSupportedOnDevice, internal }
sealed class EngineFailure implements Exception { EngineErrorCode get code; String get debugDetail /*never paths*/; }
```

**Spike-settled values (recorded by ENG-06, 2026-10-11).** Android `maxVisualSequences` = minimal 2 / low 3 / mid 4 / high 6, each further capped at `(MediaCodecInfo maxSupportedInstances − 2) / 2` (AND-01 V-N25: decoders and prepare time grow with sequences, not with clips on screen; on the AND-16 preview engine every slot holds two decoders, playing + standby, and two instances stay free for `FrameExtractor` and thumbnails); `maxConcurrentVideoLayers` stays 2 / 3 / 4 / 6. Both caps limit live preview only: above them preview uses proxies, playback-only still frames and the render-preview cache, and export runs a multi-pass precompose instead of refusing (owner decision 2026-10-11, D-43(e) point 7, D-45). QA-04 re-measures on the lab devices and may raise the values, or lower high to 4 if a 6-slot warm exact seek misses §13.4. `fpsUpconversion = true` on both platforms (§5, V-N15). iOS `backgroundKind`: `paused` on iPhone; the simulator reports `BGTaskScheduler.supportedResources.contains(.gpu) = false` and never suspends GPU work, so `continued` stays unverified until a real iPad/iPhone run (V-N20, §14.2). `backgroundGpu` stays false wherever `.gpu` is not reported. Android HDR editability (`unsupportedMedia` vs tone-mapped) needs `GL_EXT_YUV_target` and a 10-bit decoder for the OpenGL tone map; otherwise AND-02 uses `HDR_MODE_TONE_MAP_HDR_TO_SDR_USING_MEDIACODEC` (API 31+) or the SDR proxy (V-N5).

No raw `PlatformException` leaves the plugin (`error_mapper.dart`; unknown code → `internal`). Device tiers: **minimal** < 3 GB RAM (iOS A9–A11 2 GB: iPhone 6s/7/8/SE 1st gen; Android < 3 GB or `isLowRamDevice`; D-40), low 3–4 GB (iOS: iPhone X/SE 2; Android ≤ 4 GB), mid 4–6 GB, high ≥ 8 GB or iOS A15+ with 6 GB.

### 12.6 Pigeon surface (definitions ENG-01, glue ENG-07/ENG-08, frozen by ENG-06; pigeon ^29.0.0; generated files committed)

| Host API | Methods (`@async` unless noted) |
|---|---|
| `EngineHostApi` | `initialize(EngineConfigMsg)`, `capabilities() → CapabilitiesMsg`, `compatibility(uri)`, `probe(ResolvedMediaMsg) → ProbeMsg`, `freeBytes(path)`, `trimCaches(level)` (sync) |
| `PreviewHostApi` | `open(PreviewConfigMsg) → {sessionId, textureId}`, `setPlan(session, Uint8List) → PlanAckMsg`, `applyPatch(session, Uint8List) → PlanAckMsg`, `setTransient(session, itemId, Uint8List)` (sync, no reply), `clearTransient` (sync), `play(session, LoopMsg?)`, `pause`, `seek(session, timeUs, exact) → SeekAckMsg`, `setQuality`, `setUseProxies`, `setRenderedRanges(session, List<RenderedRangeMsg{startUs, endUs, uri, hash}>)` (INT-06), `setEditingMode`, `showSourceFrame`, `sampleColor → ColorMsg?`, `renderLookStills → List<Uint8List>`, `refresh`, `debugCaptureFrame → Uint8List`, `dispose` |
| `JobsHostApi` | `thumbnailTile(requestId, ThumbnailRequestMsg, priority) → ThumbnailTileMsg`, `cancelThumbnail(requestId)` (sync), `startJob(JobRequestMsg{kind: waveform\|proxy\|reverse\|freeze\|speechAudio\|renderPreview (INT-06: `plan` bytes and `outputPath`), …}) → jobId`, `cancelJob` (sync), `setJobPriority` (sync), `proxyStatus(fingerprint)` |
| `ExportHostApi` | `preflight(Uint8List plan, EncodeSettingsMsg)`, `start(Uint8List plan, EncodeSettingsMsg, outputPath, title, whenDetached) → jobId`, `resume(jobId)`, `cancel(jobId)`, `activeJobs()`, `consumeJobRecord(jobId)` (sync) |
| `RecorderHostApi` | `permission`, `requestPermission`, `openSettings`, `start(outputPath) → id`, `stop(id) → RecordedAssetMsg`, `cancel(id)` |
| `PlatformHostApi` | `pick(MediaPickRequestMsg)`, `saveToPhotos`, `saveToFiles`, `share`, `createBookmark`, `resolveBookmark`, `persistUriGrant`, `releaseUriGrant`, `remainingGrantBudget`, `stat(uri)`, `quickHash(uri)`, `excludeFromBackup(path)`, `requestNotificationPermission`, `acquireBackground(title) → leaseId`, `updateBackground(id, progress)`, `releaseBackground(id)`, `setDropTargetEnabled(bool)`, `powerState() → PowerStateMsg{charging, lowPowerMode}` (INT-06) |
| `EngineEventsApi` (`@EventChannelApi`) | one multiplexed stream of `EngineEventMsg {kind, sessionId?, jobId?, clock?, previewEvent?, progress?, jobDone?, failure?, exportProgress?, recorderLevel?, interruption?, signal?, drop?}`; `SignalMsg{kind: memoryWarning\|thermal\|powerStateChanged (INT-06), thermalLevel?, powerState?}` |

Rules: host handlers run on the platform main thread, validate, post to an engine queue and reply asynchronously; they never block on media work. Events are emitted on the main thread with native rate limits (clock ≤ 10 Hz, job and export progress ≤ 4 Hz, recorder levels 20 Hz). Binary payloads are `Uint8List`. Errors are `FlutterError(code: EngineErrorCode.name, message: debug text without paths, details: {itemId?, mediaFingerprint?, retryable})`.

**Frozen 2026-10-11 (ENG-06, D-42).** Neither spike needed a message change (IOS-01.md §3, AND-01.md §6.5: AND-16 consumes the same plan, patch, transient, seek, clock and texture messages behind AND-10's `PreviewBackend`); only the `maxVisualSequences` and `fpsUpconversion` docs were amended, and regeneration is byte-identical. Frozen with it: `pigeons/`, the generated Dart/Swift/Kotlin, `mobile_editor_engine.dart`, the iOS glue (`ios/Classes/Glue/`, ENG-07) and the Android glue (`android/.../glue/`, ENG-08), the podspec, `build.gradle.kts` and `lint.xml`. Service tickets implement the service classes the glue already calls; any later change to these files needs a new lead-approved [INTEGRATION] ticket. **Approved amendment: INT-06** (owner decision 2026-10-11, D-45 'Contract'): `JobKindMsg.renderPreview` and its request fields (start through `startJob`, cancel through `cancelJob`, progress and done/failed through the job events), `PreviewHostApi.setRenderedRanges`, and the power/idle signal (`powerState` plus a `powerStateChanged` signal event) with the matching generated code, glue on both platforms, `mobile_editor_engine.dart`, engine API contract, `FakeEditorEngine` and contract kit; the native services stay `notSupportedOnDevice` placeholders for IOS-19 and AND-18. The surface is frozen again after INT-06. **V-N8 is confirmed**: on iOS native → Dart delivery through the `@EventChannelApi` stream (`ChannelRoundTripTests.testEventChannelDeliversEngineEvents`, ENG-07), on Android the Dart → Kotlin subscription round-trips on the API 35 emulator (ENG-08); Kotlin → Dart delivery of a native event is asserted by the first Android ticket that emits one with a Dart listener test.

### 12.7 Textures

iOS: `FlutterTexture.copyPixelBuffer` returns the latest BGRA IOSurface-backed `CVPixelBuffer` (zero-copy into Impeller), driven by a `CADisplayLink` at the project fps; registration and `textureFrameAvailable` on the platform thread. **Preview A/V latency:** Flutter composites a texture 1–2 vsyncs after it is marked available while audio is not delayed, so iOS asks for `itemTime(forHostTime: displayLink.targetTimestamp + measuredTextureLatency)` (latency measured once per session from Flutter frame timings) and Android measures the SurfaceProducer → raster latency and, if Media3's audio sink allows a presentation delay, delays audio to match (V-N23). Preview A/V tolerance: ≤ 1 frame and ≤ 40 ms after compensation; export keeps ≤ 1 frame and ≤ 20 ms (§11.5). **Measured (V-N23; simulator and emulator, device numbers deferred to QA-03, recorded by ENG-06 2026-10-11):** iOS (IOS-01 §2.8, Flutter 3.44.2 Impeller, 60 Hz, 30 fps content): the Flutter texture adds **exactly one vsync** (16.67 ms p50 and p95); compensated with `targetTimestamp + 16.67 ms` the A/V offset is 10–14 ms mean (the 30 fps / 60 Hz phase), 148/148 and 146/147 frames within ≤ 1 frame and ≤ 40 ms. `FrameTiming` timestamps are `CLOCK_MONOTONIC_RAW` while `CADisplayLink`/`CACurrentMediaTime` are `mach_absolute_time`, so the latency measurement converts with a natively sampled offset (`clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) − CACurrentMediaTime()`); texture-only frames produce no `FrameTiming`, so it runs while the playhead painter rebuilds every vsync. The first ticks after `play()` may deliver one stale frame: hold the paused frame until the first new one. Android (AND-01): video release vs audible audio −6.6 to −9.5 ms; the `ImageReader` stand-in for the `SurfaceProducer` receives each frame 43–45 ms before its release time; **Media3's audio sink can shift audio**: a `ForwardingAudioSink` reporting position + 40 ms moved video 34–36 ms relative to audio, so AND-16 applies one signed offset to its audio slots (or to its frame clock). The end-to-end Android number including Flutter's raster delay is QA-03's. Android: `TextureRegistry.createSurfaceProducer(SurfaceLifecycle.resetInBackground)`; `onSurfaceCleanup` detaches the player surface (main thread waits ≤ 500 ms on a latch; the preview thread never waits on main); `onSurfaceAvailable` reattaches and redraws the last frame. One texture id may back two `Texture` widgets (editor and fullscreen; P2 verified in UX-18, fallback: move the single widget).

---
## 13. Preview pipeline

### 13.1 Shared flow

```
EditorController.apply(cmd) ─► EditSession (pure, main isolate) ─► EditorState (selective rebuilds)
        │                                  └─► PlanSync.schedule(project)  (API-02; ≤ 1 compile in flight, latest wins)
        │                                          compile (isolate > 300 items) ─► diff ─► PreviewSession.applyPatch
        │                                          planOutOfSync ─► setPlan(full) (once) ─► else PreviewFailed
        ├─► ProjectRepository.requestAutosave(session)
        └─► gestures: EditTransaction.update ─► transientFor(item) ─► setTransient (≤ 60 Hz; param-only)
Native preview ─► PreviewClock (10 Hz) ─► PlayheadController (extrapolates per vsync, outside Riverpod)
              ─► painters: playhead layer, timecode, Flutter text/subtitle overlay (D-05), manipulation handles
```

The preview plan never contains text or subtitle layers; `TextOverlayLayer` (UX-19) paints active text items and cues above the `Texture`, letterboxed with the same `CanvasGeometry`, using `TextLayoutEngine` (API-04), `textLayoutSpecOf`/`cueLayoutSpecOf` and `evaluateTextAnimation` at `PlayheadController.value`. Fullscreen preview hosts the same overlay.

### 13.2 iOS (AVFoundation + Core Image on Metal)

- **Composition** (`CompositionBuilder`, `previewControlQueue`): one `AVURLAsset` per media (`AVURLAssetPreferPreciseDurationAndTimingKey`), tracks loaded with `loadTracks`; `CompositionBuilder` **retains the assets for the composition's lifetime** (holding only the `AVAssetTrack` makes every `insertTimeRange` fail with `-11800` / Fig `-12780`, IOS-01). Media layers go to the composition video track named by their `seq` (§13.5; created on demand). Per map segment: `insertTimeRange(srcRange shifted by +500 µs (ε), of:, at: CMTime(k0, gridFps))` then `scaleTimeRange` of that range to `CMTime(k1 − k0, gridFps)`; grid times are never converted to µs `CMTime`s (D-35). A 16×16 one-frame spacer video, generated at runtime with `AVAssetWriter` (H.264, no compression properties; the simulator has no JPEG encoder) into `<cache>/danaview/editor/engine/spacer_16x16_v1.mov` when missing (no bundled resource), is scaled across `CMTime(0…K, gridFps)` so the compositor runs for every output frame, including gaps. Images, solids and sprites are compositor layers, not composition tracks. `InstructionBuilder` splits at every layer boundary into `DVInstruction`s (time ranges in `CMTime(k, gridFps)`; layers bottom → top, required source track ids); validated with `isValid(for:)` in debug. `AVMutableVideoComposition` with `customVideoCompositorClass = DVCompositor`, `frameDuration = 1/fps`, BT.709 colour properties, `sourceTrackIDForFrameTiming = kCMPersistentTrackID_Invalid`.
- **Audio**: audio segments interval-coloured × `pitch` into composition audio tracks; `AVMutableAudioMixInputParameters` per track with `audioTimePitchAlgorithm = .timeDomain` (keep pitch; **not `.spectral`**, IOS-01 V-N21: in `AVAssetReaderAudioMixOutput` over `scaleTimeRange`d ranges `.spectral` goes silent after the first rate change and can hang in `copyNextSampleBuffer`, while `.timeDomain` is complete and deterministic; the preview item uses the same algorithm so preview and export sound alike) or `.varispeed` (pitch off; `.varispeed` showed the same reader failure on the iOS 26.5 simulator and not on 18.2, so IOS-18/QA-11 verify `pitch: false` export reads over scaled ranges before relying on it), and an `audioTapProcessor` (`GainTap`, IOS-18, D-37) that multiplies each sample by the track's gain envelope evaluated at composition time (0–2, sample-exact); no `setVolumeRamp`. Gain-only patches swap the tap's envelope atomically (no rebuild). Tap rules from IOS-01 (V-N21: gain 2.0 = +6.0206 dB at 1×, 2× and 0.5× in the reader and +6.02 dB in `AVPlayer`; range starts are composition time within 0.04 ms): the tap evaluates the envelope from `range.start` and advances by `numberFrames / sampleRate`, **never `range.duration`** (inside scaled segments it is scaled by the rate again); the first `AVPlayer` call can carry an invalid range (evaluate at the last known time); it zero-fills its buffers when `MTAudioProcessingTapGetSourceAudio` fails; in `AVPlayer` it runs 150–280 ms ahead of the item clock, so live envelope swaps take effect with that delay in preview. Speed-ramp audio stays per-segment `scaleTimeRange`; QA-11's click test guards the segment seams, and if it fails, ramp audio alternates between two composition tracks with 5 ms equal-power tap crossfades at each seam (IOS-18).
- **Compositor** (`DVCompositor: AVVideoCompositing`): BGRA IOSurface/Metal source buffers (VideoToolbox does YUV→RGB); `supportsHDRSourceFrames = false`; one `CIContext(mtlDevice:)` with colour management off; precompiled Metal CI kernels (`-fcikernel`) loaded with `CIKernel(functionName:fromMetalLibraryData:)`: `dv_look` (crop sampling, chroma + spill, grade, LUT), `dv_blur_h/v`, `dv_sharpen`, `dv_vignette_mask`, `dv_cmask`, `dv_reveal`, `dv_matte`. Transforms via `CIImage.transformed(by:)` with the §11.6 matrix; `CISourceOverCompositing`. `ParamSnapshot` is swapped atomically and never locked during a render. Each request computes `k = round(compositionTime × fps)`, renders the plan at `timeOfFrame(k)` (layer activity, anim channels, `reveal`) and stamps `danaview.frame = k` (D-35). **Redraw-from-cache**: the compositor keeps the last request's source buffers and renders param patches, transients, editing modes and look stills on the same code path while paused (≤ 30 ms). Cancellation by generation counter. Compositor rules from IOS-01 (IOS-08/IOS-09): source images are built zero-copy through a `CVMetalTextureCache` → `CIImage(mtlTexture:)` with a y flip (keep the `CVMetalTexture` alive until the render task completes), **not** `CIImage(cvPixelBuffer:)`, which composited the lower of two decoded layers black on the iOS 18.2 simulator (101/200 seeks wrong; unknown on devices, the Metal path costs nothing); every kernel that samples a `clampedToExtent()` input (`dv_blur_h/v`, `dv_sharpen`, `dv_reveal` when it reads neighbours) is applied with `extent: .infinite` and then `cropped(to: sourceExtent)`: with the declared extent equal to the crop, Core Image elides the crop and a placed, blurred layer covers the whole canvas; every kernel is pre-warmed once at session start (a 16×16 render through each; the first blur compile took 1–3 s). Measured on the iOS 26.5/18.2 simulators: redraw-from-cache p50 13.0–15.4 ms, p95 ≤ 20.8 ms (1080p, 2 layers, look + blur); zero-copy texture (the `copyPixelBuffer` buffer is the compositor's render buffer, same IOSurface, 4/4); an HLG source with `supportsHDRSourceFrames = false` arrives as BGRA tagged `ITU_R_709_2`; the Metal CI kernels also run on a `.useSoftwareRenderer` `CIContext` with identical output (V-N22, speed on device deferred).
- **Build (V-N9, IOS-01 §3, applied by ENG-06 to `danaview_editor_engine.podspec`, frozen).** Platform iOS 15.0; frameworks AVFoundation, CoreImage, CoreMedia, CoreVideo, Metal, MediaToolbox, VideoToolbox, with BackgroundTasks weak-linked; `OTHER_CFLAGS = -Werror=unguarded-availability-new` (D-41). Xcode 26 ships no Metal toolchain, so the app build never compiles `.metal` files and `MTL_COMPILER_FLAGS`/`MTLLINKER_FLAGS` are not used: the kernels are **prebuilt** `-fcikernel` metallibs, one per SDK (`metal -c -fcikernel -target air64-apple-ios15.0[-simulator]` + `metallib -cikernel` → `dv_kernels.iphoneos.metallib`, `dv_kernels.iphonesimulator.metallib`, ≈ 8 KB each, with `BUILD_INFO.txt` recording source and output SHA-256), built by IOS-09 from `Classes/Render/Shaders/` into `Classes/Render/Shaders/Prebuilt/` and committed. Both ship in the `DVEditorKernels` resource bundle, which lands at `App.app/DVEditorKernels.bundle` (static library or static framework) or `App.app/Frameworks/danaview_editor_engine.framework/DVEditorKernels.bundle` (dynamic frameworks), so `Kernels.swift` loads it with `Bundle(for: <a class of the pod>)`, never `Bundle.main`, picks the SDK with `#if targetEnvironment(simulator)` and calls `CIKernel(functionName:fromMetalLibraryData:)` (1.5–3 ms per kernel). Verified in the spike for static-library, static-framework and dynamic-framework linkage × simulator and device builds (6/6); kernels load and match the CPU reference within 1/255 on the iOS 26.5 and 18.2 simulators; loading on a device is deferred (no device available). `example/ios/RunnerTests/BuildConfig/BuildConfigTests.swift` guards the bundle placement, the 15.0 floor and the frameworks, and loads every §13.2 kernel once IOS-09 ships the metallibs.
- **Session**: `AVPlayer` (`automaticallyWaitsToMinimizeStalling = false`), `AVPlayerItem.seekingWaitsForVideoCompositionRendering = true`; `AVPlayerItemVideoOutput` → `TextureBridge` driven by `DisplayLinkDriver` (`preferredFrameRateRange` = project fps, paused when idle; item time queried for `targetTimestamp` + measured texture latency, §12.7). Exact seek: `seek(to: CMTime(k, fps), tolerance .zero)`, then query the video output **with the seek target** `CMTime(k, fps)` (not `currentTime()`) until the buffer's `danaview.frame` attachment (set with `.shouldPropagate`) == k (500 ms timeout) and ack. Measured (IOS-01 V-N10): 200/200 acked with 0 content errors on the iOS 26.5 and 18.2 simulators, p50 11.6–14.0 ms, p95 17.2–21.6 ms; grid cuts (D-35) 100% in export, exact seek and playback. The iPhone 7 / iOS 15.8 run is deferred: no device available (D-43). The session reports ready only after the **first composited frame** (36–113 ms on iOS 26, up to 1.9 s on a loaded 18.2 run), so the first user seek does not pay decoder start-up. Scrub: tolerance ±0.5 s at high drag velocity, one seek in flight, latest wins. Structural rebuild: new item, `replaceCurrentItem`, exact seek to the current frame, restore play state, keep the old frame on screen until the first new one. Quality: render size = canvas × {1, ½, ¼} capped by `maxPreviewLongSide`; `QualityGovernor` steps down after > 10% missed frames over 2 s, up after 10 s clean; thermal `.serious` forces ≤ half. Lifecycle: resign active → pause and stop display link; background → release CI intermediates; active → `refresh()`; memory warning → trim caches to 25% and emit `signals.memoryWarning`. Audio session `.playback/.moviePlayback` while playing; previous category restored on dispose (player handoff §17.3).

- **Adaptive preview and the render-preview cache (owner decision 2026-10-11, D-43(e), D-45).** `PreviewQuality.auto` steps full → 1/2 → 1/4 by changing the compositor's render size and recovers after sustained headroom; proxies are on by default on the minimal and low tiers (§9.5). During playback a rendered range plays from its cached file (IOS-19: the cached file replaces the range's video tracks in the preview composition as one segment, switching at the range's exact frame boundaries; audio stays live); paused, scrub and exact seek always use the full composition. Where the device decoder limit is hit, preview shows the excess tracks as paused-exact stills during playback only, and export uses D-45's multi-pass precompose (§14.2).

### 13.3 Android (Media3 1.11.1)

- **Sequence stack** (the **Transformer export** composition, AND-08's mapper with `target = export`; AND-01: **GO** for export; index 0 = top = frame clock): 0 = transparent clock band (one 2×2 transparent image item, `setDurationUs(durUs)`, `setFrameRate(fps)`; export: export fps), built with `EditedMediaItemSequence.Builder(setOf(TRACK_TYPE_VIDEO, TRACK_TYPE_AUDIO))` so every composition has video frames exactly on the output grid **and** an audio track (silence when nothing is audible, D-38); 1…n = one sequence per packing slot `seq` (§13.5), ordered top → bottom, built with `setOf(TRACK_TYPE_VIDEO)`, padded to `durUs` with **transparent image items at the output fps, never `addGap`** (AND-01 V-N18/V-N25: with `addGap` every secondary sequence exported fully black frames at its item→gap edges, and at 60 fps one item start showed one output frame early because a gap has fewer frames than the output grid), every item and gap boundary on the platform frame time `P(k)` (§5); n+1 = background solid; n+2… = audio-only sequences per interval colour (`setOf(TRACK_TYPE_AUDIO)`). Export plans add sprite layers as `SpriteBandEffect` sequences. The deprecated `experimentalSetForce{Audio,Video}Track` setters are not used (Media3 1.11 `trackTypes`). Files opt in with `@OptIn(UnstableApi::class, ExperimentalApi::class)`.
- **Items**: `MediaItem` with `ClippingConfiguration` from the map (ε rule by. **`SNAP_TO_RULE_FRAME`**, AND-01 V-N16: the clip start is the PTS of the rule frame, the greatest sample PTS ≤ s0 + 500 µs read with `MediaExtractorCompat` with edit lists applied, 0 mismatches over 7 offsets on plain and B-frame sources, where clipping at s0 gave 15; end adjusted ≤ 1 µs × rate to land on `P(k)`; `setDurationUs` = the full source duration on every media item), `setRemoveAudio(true)` for video, `setSpeed(SpeedParameters(SegmentSpeedProvider(map), keepPitch))` (honoured by both CompositionPlayer and Transformer), items faster than 1× cap their output frame rate at the project fps with `EditedMediaItem.setFrameRate(gridFps)` (V-N17: a 4× item 240 → 60 effect calls, barcode exact), effects `[LayerLookEffect(id), SeparableBlurEffect(id)?, LayerPlaceEffect(id)]`; images via the image decoder path with `setDurationUs` and `setFrameRate(fps)`; audio items with `setRemoveVideo(true)`, `GainProcessor(KeyframedGainProvider(id))` (sample-exact envelope 0–2, `isUnityUntil` spans).
- **Compositing**: every visual sequence's last effect outputs a **canvas-render-size straight-alpha texture**; `DefaultVideoCompositor` only blends (verified: index 0 on top, `glBlendFuncSeparate(SRC_ALPHA, ONE_MINUS_SRC_ALPHA, ONE, ONE_MINUS_SRC_ALPHA)`); `LayerGatingCompositorSettings.getOverlaySettings(inputId, pts)` computes `k = frameIndexNearest(pts)` and returns `alphaScale = 0` when no layer of that sequence covers `timeOfFrame(k)`, because Media3 renders gaps opaque black. `Composition.setHdrMode(HDR_MODE_TONE_MAP_HDR_TO_SDR_USING_OPEN_GL)` where the device has `GL_EXT_YUV_target` and a 10-bit decoder, else `HDR_MODE_TONE_MAP_HDR_TO_SDR_USING_MEDIACODEC` (API 31+) or the SDR proxy (AND-02; V-N5 deferred to a device, the emulator has neither); composition audio effects `SonicAudioProcessor(48 kHz)` + `ChannelMixingAudioProcessor(→ stereo)`. **Verified for Transformer by AND-01:** input ids = sequence indices and `pts` = composition time within −1…+500 µs of `P(k)` (V-N1); effect pts sequence-cumulative (V-N2); straight alpha preserved within 0.002 (V-N4); rotated sources upright (V-N6); grid-cut export 100% at 24/30/60 fps on composited and decoded frames; export vs composited frame SSIM ≥ 0.9997; the clock band's `trackTypes {VIDEO, AUDIO}` (image or video band) yields a silent AAC track (`audio/mp4a-latm` 44.1 kHz stereo, V-N24), so the `SonicAudioProcessor(48 kHz)` stays. Open observation: one packed export at extreme emulator load (35–48) composited the previous source frame at one output frame (k = 68), not reproduced in about 40 other exports including 8 diagnostic repeats; AND-11 and QA-04 keep repeatable frame-checked export fixtures with `packedExport_repeated_vn25`'s diagnostics.
- **GL effects** (`danaview-gl` single thread, the only thread touching GL): `LayerLookEffect` (`dv_look.glsl`: crop via texcoords, chroma + spill, grade, LUT tiled sampler; `configure` allocates the largest footprint the layer can need over its keyframes, capped at min(4096, `GL_MAX_TEXTURE_SIZE`) (AND-09: the earlier source-size cap failed parity), which can reach ≈ 150 MB of GPU memory at 8× zoom; QA-04 and AND-11 watch low tiers, and a per-tier cap follows if a device fails; matte flag), `SeparableBlurEffect` (only when blur > 0 at any time), `LayerPlaceEffect` (`dv_place.glsl`: sharpen, vignette, mask SDF, inverse-mapped §11.6 matrix, opacity, canvas masks, 1 px antialiased edges), `SpriteBandEffect` (export: sprite quads with M and reveal map). Params from an `AtomicReference<ParamSnapshot>` at `drawFrame(…, ptsUs)` with `k = frameIndexNearest(ptsUs)`. **Early exit:** when `timeOfFrame(k)` is outside the sequence's layers (gap or gated), every effect clears to transparent and skips sampling, LUT and blur passes, so sparse lanes cost one clear per frame.
- **Preview session: AND-16 `MultiPlayerBackend` (activated by ENG-06 on 2026-10-11 after AND-01's no-go, R1; AND-01.md §2, §6, §7).** AND-10 ships the `PreviewSession` shell and the `PreviewBackend` interface and meets its playback criteria through AND-16; preview builds no Media3 `Composition`.
  - **Decks.** Each packing slot `seq` (§13.5) has **two decks**. A deck is an `ExoPlayer` with `SeekParameters.EXACT` and `pauseAtEndOfMediaItems`, playing the slot's layers as one clipped playlist (rule-frame clip starts, AND-08's speed providers) into its own PRIVATE `ImageReader` (8 images, `USAGE_GPU_SAMPLED_IMAGE`) with epoch-tagged frames. HardwareBuffers become OES textures through a small JNI shim (`eglCreateImageKHR` + `glEGLImageTargetTexture2DOES`; API 29 has no SDK `HardwareBuffer` → `EGLClientBuffer` call), the engine's only native code. One deck plays layer i; the standby deck pre-rolls layer i + 1, paused at its first frame, once that layer is less than 1 s away, so a cut never waits for a seek. `SurfaceTexture` slots (they latch only the newest frame) and the original one-deck, no-lead design are **not used**: both showed wrong frames at cuts (100–159 and 57–65 wrong slot frames per 30 fps run).
  - **Frame clock.** Choreographer-driven at the project fps on the one preview thread, which also owns EGL/GL and the decks' application looper. Decks lead the compositor by **2 output frames**; each deck's queue holds frames until their output frame is composited. **Hold/miss:** output frame k is composited only when every active slot has latched its **rule frame** (§11.5, by pts), never another frame; otherwise it retries on the next vsync, or drops k once a deck has passed it, so a late slot frame becomes a dropped output frame, never a wrong one. While a playing deck rebuffers the frame clock stops, for at most 2 s at a time. Drift beyond one frame seeks the late deck (1 s cooldown). Gating follows the plan; compositing is AND-17's `LayerCompositorGl` with the same place shader and straight-alpha blend as the Media3 effects; every composited frame carries pts = `P(k)`.
  - **Stuck-deck watchdog.** A deck that sits in `STATE_BUFFERING` for 3 s without its frame is re-seeked, alternating between ms − 1 and ms (ExoPlayer ignores a seek to the millisecond it already reports; both land on the rule frame, §5). It covers every exact seek and pre-roll (before it, 4 of 6 cold starts with 4–6 slots never rendered).
  - **Audio.** One `ExoPlayer` per audio interval colour with AND-08's speed and `GainProcessor` chain; the frame clock follows the audio master; preview A/V compensation is one signed `ForwardingAudioSink` position offset (V-N23, §12.7).
  - **Operations.** Exact seek: decks seek to `floor((ruleFramePts − clipStart) / 1000)` ms (§5) and the ack fires when output frame k is composited; the timeout before acking the actual frame is per backend, `PreviewBackend.exactSeekTimeoutMs`: 500 ms by default, 5 s for `StillFramesBackend`, 8 s for `ContingencyPreviewBackend` (owner decision 2026-10-15: a fixed 500 ms acked wrong frames on cold decks; waiting is preferred to a wrong frame, D-43(e) point 6). Scrub: through the decks, one seek in flight, latest wins. **Structural patches** (debounced 150 ms trailing, 600 ms max wait) re-plan by slot diff: `setMediaItems` on the affected slots' decks only, then an exact seek; the current frame stays on screen meanwhile. Surface from `SurfaceProducer`; `onSurfaceCleanup`/`onSurfaceAvailable` detach and reattach. Quality steps resize the `ImageReader`s. Thermal `SEVERE` forces ≤ half.
  - **Paused edits (D-36)** do not use `experimentalRedrawLastFrame()`: on pause and after each exact seek settles, `PausedFrameRenderer` (AND-17) prefetches EXACT source frames of the layers active at the current frame (`SourceFrameCache`), and param patches, transients, editing modes and structural edits while paused are drawn by our own GL pass (same shaders, `LayerCompositorGl` blend) onto the `SurfaceProducer`; play or seek hands the surface back to the frame clock. Proven by AND-01 (V-N19): the prototype reproduces the paused frame exactly (0 barcode mismatches, grey difference 0), a tint change on a secondary sequence shows 20/20, transient round trip p50 5.0–6.8 ms. Look stills, colour sampling and trim-edge frames use `FrameExtractor` (`media3-inspector-frame`, `SeekParameters.EXACT`) with `LayerLookEffect` overrides.
  - **Measured on the emulator** (`Pixel_9_Pro_XL_API_35`, host shared with other builds; device numbers are QA-04's): grid-cut playback at 24/30/60 fps **0 wrong** of 495–647 composited slot frames (118/120 frames composited at 30 fps at host load 5–10, the rest dropped); exact seek **200/200** with 3 slots at 720p, p50 143–318 ms, p90 220–609 ms; scrub 0 wrong frames; cold engine → exact frame at the playhead 0.64–4.24 s over 2/4/6 slots; warm exact seek p50 168–179 / 348–522 / 1,076–1,234 ms with 2 / 4 / 6 slots.
  - **Size and schedule (recorded by ENG-06).** ≈ 1,700–2,100 lines of Kotlin, ≈ 60 lines of C++ (JNI + CMake) and ≈ 850 lines of instrumented tests ported from the spike's `ContingencyEngineTest`: **about 3.5 weeks** of the Android lane, half a week more than the 3 weeks planned (standby decks, hold/miss, watchdog and the JNI import were not in the original estimate). The owner signed off its degradations on 2026-10-11 (D-43(e)), so M1 exit is no longer blocked by them.
  - **Over-budget layers and the render-preview cache (owner decision 2026-10-11, D-43(e), D-45).** When the active layers exceed the tier's live decode budget, the excess slots (chosen by AND-16; never the slot holding the main track) show paused-exact still frames from `SourceFrameCache` **during playback only**; paused, scrub and exact seek decode every layer exactly. During playback a rendered range of the render-preview cache plays from its cached file through one deck in place of all of that range's slots, switching at the range's exact frame boundaries (AND-18). Exact seeks may show the nearest decoded frame first and then refine (+30% allowed, §13.4).
- **Why not `CompositionPlayer` (R1 no-go, AND-01.md §1).** On Media3 1.11.1 `CompositionPlayer` with `MultipleInputVideoGraph` (the only graph that composites several sequences): video in a secondary sequence stalls at its first item/gap boundary and the player never ends; a paused `seekTo` renders nothing (`DefaultVideoCompositor.queueInputTexture` `checkState(!inputSource.isInputEnded)` after a flush); a paused or playing `setComposition` never renders and a later rebuild fails with `ExoTimeoutException: Player release timed out`; `experimentalRedrawLastFrame` throws (V-N3). Each failure has a minimal reproduction in `spikes/android_engine` that turns red with "rerun AND-01" once a Media3 version fixes it; Media3 stays pinned at 1.11.1 and an upgrade reruns AND-01. Wherever a `CompositionPlayer` is still used (tests, AND-17 experiments), detach with `clearVideoSurface(surface)`: the no-arg overload throws `IllegalArgumentException` in 1.11.1. With an image clock band a `CompositionPlayer` never reaches `STATE_ENDED` (Transformer is unaffected).
- **Build (applied by ENG-06 to `android/build.gradle.kts` and `lint.xml`, frozen; AND-01.md §6.3–6.4).** Media3 1.11.1 pinned, one version for `common`, `exoplayer` (AND-16 decks), `effect`, `transformer`, `muxer`, `inspector` (`MediaExtractorCompat` rule-frame PTS, V-N16) and `inspector-frame` (`FrameExtractor` EXACT); `kotlin { compilerOptions { optIn.add("kotlin.RequiresOptIn") } }`. The JNI shim's native build is declared there (CMake 3.22.1 from the Android SDK, `src/main/cpp/CMakeLists.txt` owned by AND-16, linking `EGL`, `GLESv2`, `android`, `nativewindow`, `log`, ABIs `arm64-v8a`, `armeabi-v7a`, `x86_64`, compiled for `android-29`, NDK 28.2.13676358) and switches on when AND-16 adds the file. The library's `minSdk` stays **24**, not the 29 AND-01 proposed: the app's `minSdk` is 24 (§3.2) and a library manifest with a higher `minSdk` cannot merge; the editor gates on API 29 at runtime and API 29+ code carries `@RequiresApi(29)` under lint's `NewApi` check. `lint.xml` makes `UnsafeOptInUsageError` and `UnsafeOptInUsageWarning` errors with `abortOnError`, and deliberately **omits** the spike's `<option name="opt-in" …>`, which is lint's project-wide opt-in and silently disables the check; every Media3 file starts with `@file:OptIn(UnstableApi::class, ExperimentalApi::class)` using `androidx.annotation.OptIn` (proven by ENG-08's negative fixture).

### 13.4 Preview budgets

Open → first frame (200 items) ≤ 1.8 s low / 1.0 s mid; compose one 1080p frame with 2 video layers + LUT ≤ 14 / 8 ms; playback at preview size 30 fps with ≤ 2% / ≤ 1% dropped; param patch or transient → texture (paused) ≤ 50 / 30 ms; structural patch → frame at playhead ≤ 400 / 250 ms; exact seek on original 1080p H.264 (GOP ≤ 2 s) ≤ 300 / 200 ms, with proxies ≤ 150 / 100 ms. Native preview memory ≤ 160 / 250 / 350 MB (low/mid/high) excluding decoder buffers. Preview A/V offset ≤ 1 frame and ≤ 40 ms after latency compensation (§12.7).

**iOS (IOS-01, simulator only, recorded by ENG-06 2026-10-11):** exact seek p50 11.6–14.0 ms / p95 ≤ 21.6 ms (200/200, 1080p and half size) and redraw-from-cache p50 13.0–15.4 ms / p95 ≤ 20.8 ms are inside the budgets above; the first blur render needs the session-start kernel pre-warm (§13.2) to stay inside the paused-edit budget; device numbers are QA-04's (iPhone 7/8 runs deferred: no device available, D-43).

**Android budgets on the AND-16 engine (D-36 structural renegotiation, then AND-01.md §5; recorded by ENG-06 2026-10-11).** Minimal tier: no latency budget (D-40).

| Budget (low / mid) | Status | Evidence (emulator, loaded shared host; device runs are QA-04's) |
|---|---|---|
| Param patch or transient → texture while paused (after prefetch) ≤ 50 / 30 ms (≤ 2 frames at 30 fps) | **Confirmed** | `PausedFrameRenderer` transient round trip p50 5.0–6.8 ms, p90 15.9–16.4 ms |
| Paused structural edit → updated frame via `PausedFrameRenderer` ≤ 400 / 250 ms (first frame of a newly added layer includes one EXACT extraction; ≤ 600 / 400 ms when its GOP > 2 s) | **Kept, unconfirmed** | 1,389–1,487 ms in a fresh renderer at host load 20–60 (extraction plus GL setup); AND-17 keeps one long-lived renderer so setup is paid once |
| Playback-ready after a structural edit | **Renegotiated:** affected-slot re-plan → exact frame at the playhead **≤ 600 / 400 ms** (replaces `setComposition` → first frame ≤ 1,000 / 600 ms with ≤ 4 sequences; there is no `setComposition` under AND-16) | a re-plan is `setMediaItems` on the changed slots' decks plus an exact seek; warm exact seek with 2 slots p50 168–344 ms; a cold rebuild of every slot (0.64–4.24 s) is the upper bound a re-plan does not repeat |
| Exact seek on original 1080p H.264 (GOP ≤ 2 s) ≤ 300 / 200 ms | **Kept, +30% allowed on AND-16** (D-43(e) point 5, owner decision 2026-10-11; the nearest decoded frame shows at once, then refines to the exact frame) | 3 slots at 720p: p50 143–318 ms, p90 220–609 ms, always 200/200 exact; 6 slots p50 0.6–1.2 s (high tier drops to 4 slots if a device misses the budget, §12.5) |
| Playback at preview size 30 fps with ≤ 2% / ≤ 1% dropped | **Kept, for QA-04 on devices** (D-43(e) point 6: drop, never late or wrong; adaptive quality steps down first, §12.2) | 118/120 composited at load 5–10 (1.7% dropped), 86/120 at load 10–20; frames are dropped, never wrong |
| Preview A/V offset ≤ 1 frame and ≤ 40 ms after compensation | **Kept** | audio-sink offset mechanism shown (V-N23, §12.7); end-to-end number is QA-03's |

### 13.5 Visual packing (CORE-36; used by `LayerLimits`, the compiler and both engines)

Input: the media layers' `(id, z, t0, t1)` after lowering (transition extensions included; computed from the model with the same rules so `LayerLimits` can run after every command without compiling). Output: a slot `seq` per layer and the slot count. Rules: (1) layers in one slot never overlap in time; (2) slots have a fixed stacking order, so two lanes may share a slot only if no layer of another slot that overlaps either of them in time lies between them in `z` during that overlap (z-interleave check); (3) greedy first-fit in ascending `z`, then by `t0`, deterministic; transition A/B overlaps on one lane take two slots only for the overlap windows' layers. Counts: `visualSequences = slot count` (D-14 cap `maxVisualSequences`), `peakConcurrentDecoders = max over t of active decoder-backed layers` (D-14 cap `maxConcurrentVideoLayers`). Example: six overlay lanes with short, non-overlapping PiP clips pack into 1–2 slots instead of 6–12 sequences. iOS uses `seq` as the composition video track (its compositor orders layers itself, so packing is always valid there).

---

## 14. Export pipeline

### 14.1 Shared flow (UX-39 → ENG-04 → native)

1. **Pre-checks**: missing media → relink sheet; pending reverse/freeze jobs → wait with progress or cancel; empty timeline; free space vs estimate `(video + audio bps)·sec/8·1.02` (+ one segment on iOS, §14.2); first-export background notice.
2. `ExportSettings` (user level, CORE-33) → `EncodeSettings` (engine level) using presets, capability clamps and the auto-bitrate table.
3. `compileExport(project, settings, spriteManifest)` (CORE-33): original media only (never proxies), output canvas = output size, letterbox fit, burn-in subtitle tracks per `settings.burnInSubtitles`.
4. **Sprite pre-pass** (API-04 `SpritePrepass`): `collectSpriteRequests` → rasterize missing `.vsprite`s at export scale in ≤ 4 ms UI slices + zlib in `Isolate.run`; shown as the "Preparing" phase; cached by content key.
5. `exporter.preflight(plan, encode)` (warnings: software encoder, HEVC unavailable, background pauses, layers vs resolution, portrait size refused; preflight **never refuses for layer or sequence counts**: above the device's decoder limit the export runs the multi-pass precompose of D-45, which is slower and needs the intermediates' disk space, counted in the disk check) → `start(plan, encode, outputPath: <cache>/danaview/editor/work/export-<jobId>.<ext>, title, whenDetached: saveToGallery)`.
6. Progress ≤ 4 Hz → completion → handoff: Photos/Gallery (default), Files, Share, optional "Keep a copy in Danaview" (`Documents/Exports/` through `DocumentsExportWriter`: new file, exclusive create, `'<name> (2).mp4'` naming, never overwrites, no symlinks; D-44; appears in the existing library). The temp file is deleted after handoff by `OwnedFileDeleter`. **Completed while detached** (no Dart listener: activity destroyed, app swiped away on Android): the engine saves to the gallery natively and keeps a one-shot `completedWhileDetached` record; the next editor or Projects open offers Share / Save to Files / Delete (D-39).
7. Cancel (confirmed) deletes the partial file (and, on iOS, all segments). Process death → `activeJobs()` reports `interrupted` once on next launch; on iOS a job with complete segments reports `resumable` and UX-39 offers "Resume export" (D-22).

**Encoder size and orientation.** Every preset size must encode or fail visibly: on `encoderSizeLimit` or a refused portrait configuration, the engine retries once with a landscape-encoded buffer plus rotation metadata (Android `setPortraitEncodingEnabled(false)` path; iOS `preferredTransform` on the writer input), and if that also fails the export fails with `encoderSizeLimit` and UX-39 offers "Lower resolution". It never fails silently; QA-11 exports every preset on emulator, simulator and the low/mid lab devices.

**Presets** (CORE-33; non-binding platform hints [VERIFY V-D9]):

| Preset | Size | FPS | Codec | Video bitrate | Audio |
|---|---|---|---|---|---|
| YouTube | short side 1080, project aspect | project, ≤ 60 | H.264 High | 8 Mbps (≤ 30 fps) / 12 Mbps (> 30) | AAC 192 kbps 48 kHz |
| YouTube 4K | short side 2160 (capability-gated) | project, ≤ 60 | HEVC if available, else H.264 | H.264 40/60 Mbps; HEVC ×0.6 | 256 kbps |
| YouTube Shorts | 1080×1920 | project, ≤ 60 | H.264 | 8 / 12 Mbps | 192 kbps |
| Instagram Reels | 1080×1920 | 30 | H.264 | 8 Mbps | 128 kbps |
| Instagram Feed | 1080×1350 | 30 | H.264 | 6 Mbps | 128 kbps |
| TikTok | 1080×1920 | 30 (60 if the project is 60) | H.264 | 8 Mbps | 128 kbps |
| Custom | short side 720/1080/1440/2160; fps **Match project** (default) or 24/25/30/48/50/60, clamped by `maxFpsByHeight`; MP4/MOV*; H.264/H.265* | | | 2–100 Mbps, clamped | 96–320 kbps |

Auto bitrate table by short side {720: 5/7.5, 1080: 8/12, 1440: 16/24, 2160: 40/60} Mbps (≤ 30 / > 30 fps) × 0.6 for HEVC × quality (Smaller 0.6, Balanced 1.0, High 1.5, Maximum 2.0), clamped by capabilities. Aspect mismatch → notice with "Change project to 9:16"; never silent crop. Location metadata is never written.

### 14.2 iOS export (IOS-12, IOS-17, IOS-13, IOS-18, IOS-20)

`AVAssetReader(asset: composition)` with `AVAssetReaderVideoCompositionOutput` (export variant: renderSize = output, frameDuration = 1/export fps) and, **only when `plan.audio` is non-empty**, `AVAssetReaderAudioMixOutput` (LPCM Float32 48 kHz stereo, `.timeDomain` for keep-pitch, with the IOS-18 gain taps; see §13.2 for why not `.spectral`); when `plan.audio` is empty the audio pump writes silent LPCM across `[0, durUs)` instead (an `AVAssetReaderAudioMixOutput` over zero tracks raises an uncatchable `NSInvalidArgumentException`; D-38). Output: `AVAssetWriter(.mp4 | .mov, shouldOptimizeForNetworkUse)` with H.264 High AutoLevel or HEVC Main AutoLevel (`hvc1`), `AverageBitRate`, `ExpectedSourceFrameRate`, `MaxKeyFrameIntervalDuration`, BT.709 colour properties, and AAC-LC 48 kHz stereo; Float32 samples are clamped to [−1, 1] before the AAC input. Pumps on serial queues via `requestMediaDataWhenReady`; progress = last video PTS / duration. Hardware: VideoToolbox; `Capabilities` probes hardware encoders with `kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder` / `kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder` **only under `#available(iOS 17.4, *)`** (both keys are iOS 17.4+); below 17.4 device encoders are treated as hardware (the simulator as software) and HEVC is detected with `AVOutputSettingsAssistant(preset: .hevc1920x1080) != nil` plus a successful `VTCompressionSession` create and one-frame test encode at the target size; HEVC hidden without it; the simulator falls back to software H.264 (`hardwareEncoder = false`).

**Segmented, resumable export (IOS-17 writer, checkpoint and concat; IOS-12 pipeline; IOS-13 lifecycle; D-22).** Video is written as closed-GOP segments of 10 s of output (each segment its own `AVAssetWriter` file `work/export-<jobId>/v-<n>.mp4`, starting with an IDR), audio as one AAC file for the whole duration (cheap to redo). After each finished segment a checkpoint (`SegmentCheckpoint`: plan hash, encode settings, completed segment count and their durations) is written atomically. **Backgrounding is an interruption:** on `didEnterBackground` the pumps stop, the in-progress segment is discarded, the checkpoint is kept and progress reports `pausedInBackground`; on return (or after relaunch via `activeJobs()` → `resumable`) the job re-reads from the next segment's start time (`AVAssetReader.timeRange`) and continues. Completion is a passthrough concat (`AVAssetReader` with `nil` output settings per segment → one `AVAssetWriter` input using the first segment's format description as `sourceFormatHint`; segments must share SPS/PPS, asserted, otherwise the mismatching segment is re-encoded); each segment is deleted after it is appended, so peak disk ≈ estimate + one segment. **Background kinds:** iPhone → `paused` (as above). iPad on iOS 26+ with `BGTaskScheduler.shared.supportedResources.contains(.gpu)` and the GPU entitlement → `continued`: submit `BGContinuedProcessingTaskRequest("com.vecvel.danaview.export.<jobId>", title, subtitle)` with `strategy = .fail` and `requiredResources = .gpu`; expiration → the same checkpoint interruption. No software-`CIContext` background path unless IOS-01 proves our Metal CI kernels run on the CPU renderer at ≥ 0.2× real time (V-N22). Thermal `.critical` pauses pumps. Proxy and reverse jobs use the same interruption semantics (§15). Destinations: `PHPhotoLibrary` add-only (`PHAssetCreationRequest`), `UIDocumentPickerViewController(forExporting:asCopy:true)`, `UIActivityViewController`.

**Spike results (IOS-01, iOS 26.5 and 18.2 simulators; recorded by ENG-06 2026-10-11).**
- **Pipeline.** `AVAssetReader(composition)` with the same compositor → `AVAssetWriter` (H.264 High AutoLevel, `MaxKeyFrameIntervalDuration` 1 s, `AllowFrameReordering = false`) exports the D-35 grid case 90/90 frames correct after encode and read-back.
- **Segmented writer (IOS-17).** Interrupt 10 frames into segment 1 → the checkpoint keeps segment 0 and the partial segment is deleted; resume renders only the remaining frames; every segment starts with a sync sample; the passthrough concat (first segment's format description as `sourceFormatHint`) gives every frame on the grid, exact duration, SPS/PPS identical across segments (90/90 in XCTest; 1,200/1,200 frames of 1080p30 in the UI test that backgrounds the app on `didEnterBackground` and resumes on return).
- **Background facts (D-22, V-N11/V-N20).** The simulator **cannot answer them**: on the iPhone 17 Pro simulator (iOS 26.5) a plain export and a `beginBackgroundTask` export both kept running in the background (`backgroundTimeRemaining` = `Double.greatestFiniteMagnitude`, no encoder or Metal error, writer `.completed`), and `BGTaskScheduler.shared.supportedResources.contains(.gpu)` = **false**. The real-iPhone runs on iOS 18 and 26 (writer status and error code after > 30 s in the background, the `.gpu` value) are **deferred: no device available** (D-43); the spike's `DVSpikeBackground` UI tests are ready for them. D-22 stands unchanged: iPhone = `paused` with segment resume, and `continued` is enabled only on a device that reports `.gpu` (IOS-13 after the device run; `BGTaskSchedulerPermittedIdentifiers` for `com.vecvel.danaview.export.*` and the GPU entitlement are app-side, INT-03).
- **Software Core Image path (V-N22).** The Metal CI kernels run on a `.useSoftwareRenderer` `CIContext` with output identical to the GPU path (barcode decodes, mean difference 0); simulator speed (look 9.7–11.7×, look + blur σ4 2.8–3.0× real time at 1080p) uses the Mac's CPU and is not representative, so **no software background path is enabled** until the device speed (≥ 0.2× real time) is measured (deferred: no device available).
- **Audio (IOS-12, IOS-18).** `.timeDomain` + tap reads were complete in 30/30 reliability runs, but the reader output runs 0.01–0.10 s past the composition (overlap-add tail), so the audio pump **trims to the composition duration** (`endSession(atSourceTime:)`). About one read in 70 on iOS 26.5 came back silent or NaN from the start: the tap zero-fills on `GetSourceAudio` failure and IOS-12 validates the rendered audio (NaN, or a fully silent read while the plan has audible audio → redo the read once). Inside time-stretched segments the grain placement shifts seams by +10 ms at 2× and −29.5 ms at 0.5× (identical in every read), which is within the preview tolerance but above the 20 ms export A/V target of §14.4, so QA-11/IOS-18 measure A/V offset at segment starts, not inside stretched audio. **D-37 premise corrected:** `AVMutableAudioMixInputParameters.setVolume(2.0)` does amplify (+6.02 dB) in the reader on both simulators; the tap remains the design (sample-exact envelopes, one code path for preview and export) and mix volume is simply not relied on.

**Multi-pass fallback (IOS-20, D-45).** When a composition track cannot get a decoder (`decoderInitFailed`, or the plan needs more simultaneous decoders than the device sustains), IOS-12's pipeline runs D-45's precompose: the bottom tracks are rendered into opaque full-resolution intermediates in `work/export-<jobId>/pre-<n>.mov` (intra-only or ≥ 4× bitrate, export frame grid, same Core Image working space), then the final segmented export uses them as its bottom layer. Intermediates are part of the job's checkpoint, so a resumed job does not redo a finished pass.

### 14.3 Android export (AND-11, AND-12, AND-19)

Process-scoped `ExportCoordinator` owns one `Transformer` per job on a `danaview-export` looper: `setVideoMimeType(H264|H265)`, `setAudioMimeType(AAC)`, `DefaultEncoderFactory` with `HardwareEncoderSelector` (hardware first, `isHardwareAccelerated`), requested bitrate and I-frame interval, `setEnableFallback(true)`; `InAppMp4Muxer.Factory().setAttemptStreamableOutputEnabled(true)`; same ORIGINAL working-space frame processor; `setPortraitEncodingEnabled(true)` with the landscape-plus-rotation retry of §14.1 when the encoder refuses a portrait size. The export composition comes from the same mapper with `target = export` (export size, clock band at export fps with `trackTypes {VIDEO, AUDIO}` so a silent AAC track is always produced, originals, sprite bands; D-38). Progress via `getProgress` every 250 ms; `ExportException` codes map to `EngineErrorCode` (encoder init/format → `encoderUnavailable`/`encoderSizeLimit`; file not found → `mediaOffline`; no permission → `permissionDenied`; decoding → `decodeFailed`; ENOSPC → `diskFull`); `onFallbackApplied` → progress warning. **Foreground service** `ExportService` (types `mediaProcessing` on API 35+, `dataSync` on 29–34; notification with determinate progress ≤ 1 Hz and a Cancel action; API 35 `onTimeout` → `interrupted`); it also hosts `BackgroundWorkGuard` leases for captions. **When a job completes with no Dart listener attached** (activity destroyed or app swiped from recents while the service keeps running), `ExportService` performs the `whenDetached` handoff itself (default: `MediaStore` insert with `IS_PENDING`, then clear it), records `completedWhileDetached` in `ActiveExportStore`, exempts the output from the `work/` wipe, and posts a "Saved to Gallery" notification that opens the app (D-39). On minimal/low/mid tiers the preview session is suspended during export (through AND-10's `PreviewSessionManager`). Destinations: `MediaStore.Video` with `RELATIVE_PATH = Movies/Danaview` and `IS_PENDING`, SAF `ACTION_CREATE_DOCUMENT`, `ACTION_SEND` with `FileProvider` authority `${applicationId}.danaview.editor.files`.

**Multi-pass precompose (AND-19, D-45).** Export never refuses for sequence counts. When the packed export plan has more slots than the device can decode at once (more than `maxVisualSequences`, or peak decoders above codec `maxSupportedInstances` − 2), `ExportCoordinator` runs D-45's precompose: pass 1 is a video-only `Transformer` export of the background plus the lowest slots that fit (the same AND-08 mapper with `target = export`, same frame processor, HDR mode and working space) to `work/export-<jobId>/pre-<n>.mp4` at the export size, all-intra (I-frame interval 0) or ≥ 4× the export bitrate; passes repeat until the rest fits; the final pass maps the intermediate as an ordinary bottom video layer on the export frame grid (rule-frame clipping, §13.3) and mixes audio once. Progress is one fraction over all passes; cancel and failures clean up the intermediates; AND-12's foreground service covers every pass.

**Facts recorded 2026-10-15 (AND-12, AND-11).** androidx.core 1.13.1 `ServiceCompat.startForeground` drops `FOREGROUND_SERVICE_TYPE_MEDIA_PROCESSING`, so AND-12 calls the framework `Service.startForeground(id, notification, type)` directly on API 29+. Every Android export's AAC track is padded with silence to the video's end (owner decision 2026-10-15; before the fix it ended 41–49 ms early), matching iOS, which covers `[0, durUs)` (D-38); QA-11 keeps a tight tolerance rather than allowing the gap.

### 14.4 Export budgets and conformance

1080p30 H.264 with 2 layers + text ≥ 0.7× real time (low) / ≥ 1.5× (mid); 4K30 HEVC single layer ≥ 0.6× (high). Export working set ≤ 220 / 300 / 400 MB. Max export size by tier: 1080p low, 1440p mid (4K if ≤ 2 layers), 4K high (on Android, more than 3 visual sequences at 4K go through the multi-pass precompose, D-45). Multi-pass exports (D-45) have no real-time budget; they must pass the same conformance and match a single-pass export (SSIM ≥ 0.995 per frame, grid-cut 100%). Conformance (QA-11): container, `avc1`/`hvc1`, size, display orientation and rotation metadata, fps, frame count = duration × fps ± 1, AAC 48 kHz stereo **on every export, including projects with no audio, everything muted or soloed out, and images/text only**, bitrate within ±25%, hardware-encoder flag, A/V offset ≤ 1 frame and ≤ 20 ms; every preset of §14.1 (plus 4K where capabilities allow) on the API 35 emulator, the iOS simulator and the low/mid lab devices; output PCM matches the Dart reference mixer (RMS per 20 ms window ±0.5 dB; muted lanes < −60 dBFS; 200% volume = +6.02 ± 0.1 dB vs 100%; keep-pitch at 2×/0.5× keeps the dominant FFT bin within ±2%).

---

## 15. Media services, recording and platform services

| Service | iOS | Android |
|---|---|---|
| Probe / compatibility (≤ 300 ms) | `AVURLAsset` async loads (`duration`, `isPlayable`, `isComposable`, `hasProtectedContent`), format descriptions (codec, bit depth, transfer → HDR), `preferredTransform` → rotation; Dart `MediaInspector` container sniff first: MKV/WebM/AVI → `NotEditable('container_unsupported_ios')` | `MetadataRetriever` + `MediaExtractorCompat`; decoder availability via `MediaCodecList` per mime/profile/size; MKV/WebM editable when decoders exist; HDR editable via tone mapping with an automatic proxy |
| Thumbnails (JPEG strips of 8 frames) | `AVAssetImageGenerator` per (media, proxy), `appliesPreferredTrackTransform`, `dynamicRangePolicy = .forceSDR` (iOS 18+), ImageIO JPEG q 0.7 | `FrameExtractor` `CLOSEST_SYNC` + `Presentation.createForHeight` (GPU downscale), `Bitmap.compress(JPEG, 70)` |
| Waveforms (`.dvpk`, int8 min/max at 200 pairs/s) | `PcmReader` (`AVAssetReader`, LPCM Float32) | `PcmDecoder` (`MediaExtractorCompat` + async `MediaCodec`, PCM float) |
| Speech audio (16 kHz s16 mono WAV, sample-accurate, ±20 ms clap test) | `PcmReader` + fixed downmix (mono copy; stereo 0.5/0.5; 5.1 → 0.5·C + 0.25·(L+R) + 0.125·(Ls+Rs), LFE dropped) + `AVAudioConverter` (.high) | `PcmDecoder` + `ChannelMixingAudioProcessor` (same coefficients) + `SonicAudioProcessor(16 kHz)` |
| Proxies (540p short side, H.264 3 Mbps, GOP 10 frames / 0.33 s, SDR, AAC 128k, **same PTS**) | reader → IOS-17 segmented writer (resumes after backgrounding) → concat to `.part` + rename | `Transformer` + `Presentation.createForShortSide(540)`, paused while exporting |
| Freeze frame (PNG at Dart path) | `AVAssetImageGenerator` zero tolerance | `FrameExtractor` `EXACT` |
| Reverse (bounded memory and disk) | processed in **GOP-aligned chunks from the end** of the range (≈ 2 s of source each): chunk → all-intra H.264 intermediate in `work/` read back with `AVAssetReaderTrackOutput` (`supportsRandomAccess = true`, `reset(forReadingTimeRanges:)`, decoding to **420v** buffers, never copied to a second file) → frames in reverse order → writer with mirrored PTS; the intermediate never exceeds one chunk; audio reversed in 64k-frame blocks → AAC. Memory ≈ 3 decoded 420v frames (≈ 37 MB at 4K) + encoder | same chunked three stages: `Transformer` all-intra per chunk → `MediaExtractorCompat` + `MediaCodec` reverse feed → encoder surface; audio via `PcmDecoder` → WAV → AAC → `Mp4Muxer` |
| Reverse preflight (both) | `MediaJobs.reverse` refuses ranges > 10 min (`LimitExceeded('reverseRange')`, UI copy suggests trimming) and checks `freeBytes ≥ 2 × estimated output + one chunk intermediate + 64 MB` (`diskFull` otherwise) | same |
| Voice recording (WAV s16 48 kHz mono, levels 20 Hz, start latency) | `AVAudioEngine` input tap; `.playAndRecord` + `.defaultToSpeaker` + Bluetooth HFP; interruptions/route changes stop and keep the file; `AVAudioApplication.requestRecordPermission` (17+) / `AVAudioSession` (15–16) | `AudioRecord(MIC, 48k, mono, 16-bit)` on its own thread; latency from `AudioRecord.getTimestamp`; device removal or focus loss stops and keeps the file; `RECORD_AUDIO` runtime request |
| Pickers | `PHPickerViewController` (`preferredAssetRepresentationMode = .current`, multi-select; inside `loadFileRepresentation`'s completion handler the temp file is cloned with `clonefile` (copy fallback) into `<cache>/danaview/editor/work/picks/<uuid>/` and that path is returned with `isTemporaryCopy = true`, §9.1) + `UIDocumentPickerViewController` (video, audio, image, `.cube` via `public.data` + extension check, srt/vtt) | Photo Picker `PickMultipleVisualMedia` + SAF `OpenMultipleDocuments` (audio, LUT, subtitles) |
| Media access | bookmarks (create/resolve/stale refresh), `stat`, `quickHash` via file read, `isExcludedFromBackup` | `takePersistableUriPermission`/release, grant budget (`persistedUriPermissions` count vs 512/128), `ContentResolver` stat and hash |
| Background guard | `beginBackgroundTask` lease (pause semantics) | lease hosted by `ExportService` FGS |
| Job interruption (D-22) | backgrounding interrupts every reader/writer job: proxies resume from their last complete segment (IOS-17 segmented writer), reverse from its last complete chunk, freeze frames and waveforms restart; jobs are re-queued automatically on foreground (`Core/JobInterruption`, IOS-17) | jobs keep running under the FGS lease |
| External drop (D-18) | `UIDropInteraction` on the Flutter view; `NSItemProvider.loadFileRepresentation` → temp copy → Dart (managed copy); position in logical px | `View.setOnDragListener` on the FlutterView + `Activity.requestDragAndDropPermissions`; URIs copied while permissions are held |

Disk caches (`<cache>/danaview/editor/`, LRU by access time): `thumbs/` 300 MB, `waves/` 64 MB, `proxies/` min(4 GB, 10% free), `sprites/` 400 MB, `looks/`, `engine/` (spacer asset), `work/` (wiped at launch except files of active or resumable jobs and outputs referenced by an unconsumed `completedWhileDetached` record, which expire after 7 days; `work/picks/` and `work/drops/` older than 24 h are wiped). Files used by an open session are pinned; "Clear editor cache" is disabled while a session or job is active. Native job queues: 1 concurrent job on low tier, 2 otherwise; export and interactive jobs pre-empt background jobs.

---

## 16. AI subtitles pipeline (on-device whisper.cpp)

### 16.1 Components

- **`danaview_whisper`** (FFI plugin, iOS + Android only): whisper.cpp **v1.9.4** (commit `927cfce34f31707e17f2bff35c349632fb9e2c3a`, ggml 0.23.0; v1.9.5 `d1be6fde` was released 2026-10-06 — AI-01 reviews its changelog and either re-pins or records why v1.9.4 stays) vendored and pruned (≈ 7.8 MB, re-vendor script with tarball sha256). C ABI shim (`dv_whisper.h`, ABI 1): every job runs on a **native `std::thread`**; Dart polls a mutex-guarded status and segment buffer every 250 ms with leaf FFI calls; cancel/pause are atomic flags read by `abort_callback` and `encoder_begin_callback`; no Dart callbacks cross threads; strings copied in. iOS: static `WhisperCore.xcframework` built by `tool/build_ios_xcframework.sh` (CMake ≥ 3.28) with deployment target 15.0, Metal (embedded library) used only on iOS ≥ 16.4 and Apple GPU family ≥ 6, Accelerate/BLAS **off**, CPU NEON otherwise; CocoaPods only. Android: two arm64 shims (`armv8-a` baseline, `armv8.2-a+fp16+dotprod`) chosen at runtime from `getauxval(AT_HWCAP)`, plus x86_64; `c++_static`; 16 KB page alignment; only `dv_*` exported; no armeabi-v7a.
- **`danaview_transcription`** (Dart): model catalog and store, resumable downloader, job pipeline, transcript cache with checkpoints, segmenter, timeline mapping, resource governor. Implements `TranscriptionService` (D-21).
- **UI** in `danaview_editor/lib/src/editor/flows/captions/` (UX-37, UX-38).

### 16.2 Models (pinned revision `5359861c739e955e79d9a303bcbc70fb988958b1`, `huggingface.co/ggerganov/whisper.cpp`)

| Tier | File | Bytes | SHA-256 | Min RAM |
|---|---|---|---|---|
| Fast | `ggml-tiny-q5_1.bin` | 32,152,673 | `818710568da3ca15689e31a743197b520007872ff9576237bda97bd1b469c3d7` | 2 GB |
| Balanced (default) | `ggml-base-q5_1.bin` | 59,707,625 | `422f1ae452ade6f30a004d7e5c6a43195e4433bc370bf23fac9cc591f01a8898` | 3 GB |
| Accurate | `ggml-small-q5_1.bin` | 190,085,487 | `ae85e4a935d7a567bd102fe55afc16bb595bdb618e11b2fc7591bc08120411bb` | 4 GB (hidden below) |
| VAD (always) | `ggml-silero-v6.2.0.bin` (`ggml-org/whisper-vad` @ `9ffd54a1e1ee413ddf265af9913beaf518d1639b`) | 885,098 | `2aa269b785eeb53a82983a20501ddf7c1d9c48e33ab63a41391ac6c9f7fb6987` | – |

Stored in `<support>/danaview/speech/models/` (backup-excluded), with a `.part` + sidecar and an atomic `manifest.json`.

### 16.3 Consent and download

`ConsentDisclosure.of(spec)` = exactly what the consent view displays (model id, file, total bytes incl. VAD, sha256, host). `UserConsent.accepted(disclosure, acceptedAt)` is constructed **only** in `model_consent_view.dart` (architecture test). Consent is per download; nothing is remembered; after deletion the user is asked again. Downloader: plain `dart:io` `HttpClient`, `GET` with `followRedirects = false` and `User-Agent: Danaview/<version>` (no identifiers); expect `302` and check `x-linked-size`/`x-linked-etag` against the catalog **before** downloading; ranged `GET` on the signed CDN `Location` (`206` append, `200` restart, `416` verify-or-restart), sidecar every 4 MiB, 15 s connect / 30 s idle timeouts, 3 retries with 2/4/8 s backoff + jitter re-resolving the redirect; SHA-256 in `Isolate.run`; ggml magic check; atomic rename; `excludeFromBackup`. Pre-flight: free space ≥ remaining + 64 MiB. Wakelock during download; iOS background → keep until the task expires, then pause with the partial kept.

### 16.4 Job pipeline

1. **Plan** (pure): `TimelineView` (adapter over `EditProject`) → units `{media, audioStream, sourceRange, clips, priority}`; include audible clips; exclude muted/zero-volume/soloed-out, reversed (reported), stills/images, no-audio media, music tracks (default unchecked); merge clips of the same media within 5 s; pad 0.5 s.
2. **Cache**: `TranscriptKey = sha256(quickHash | audioStream | modelSha256 | language | paramsVersion | vad)`; a cached transcript covering the range is reused.
3. **Model**: consent/download if missing; load (reuse a loaded handle; released 60 s after the job, immediately on low memory).
4. **Extract** each missing unit to `<support>/danaview/speech/work/<job>/<unit>.wav` through `SpeechAudioExtractor` (engine job; D-28), pipeline depth 1.
5. **Language**: explicit language from the user; "Detect automatically" runs DETECT on ≤ 30 s of speech (top-1 p ≥ 0.6 accepted, else `needsLanguage` with the top 3).
6. **Transcribe** in ≈ 180 s chunks cut at the quietest point (RMS, ±15 s) with Silero VAD, `suppress_nst`, token timestamps; each finished chunk checkpointed to `<key>.partial.jsonl`; normalize (annotation removal, repetition-loop collapse, silence-hallucination gating, timing sanity); write `<key>.json` (schema 1, source µs).
7. **Map** words through `ClipTimeMap.timelineTimeOf` using a **fresh** timeline (edits during the job are honoured); drop < 50% visible words; overlap priority voice > main video > other video > other audio > music.
8. **Segment** (deterministic DP): presets Standard (2 × 42 graphemes; 32 for 9:16), Single line, Short phrases; script profiles (CJK 16, Korean 18, no-space SE Asian 35, RTL); CPS 17 (CJK 9, Korean 12); min 0.83 s, max 7 s, 2-frame gap; kinsoku; cut-crossing penalty; edges on the frame grid.
9. **Apply** as one history entry (`AddGeneratedCaptionTrack` / `ReplaceGeneratedCaptions`) with `CaptionProvenance`. Regenerate = instant re-split from cached transcripts or a fresh transcription; edited cues trigger a confirm.

### 16.5 Resources, lifecycle, failures

Threads = clamp(perf cores, 2, 4); halved at thermal `serious` (+2 s cooldown between chunks), paused at `critical`; low-power −1. Memory preflight: available ≥ 1.3 × the tier's peak budget (tiny 200 MB, base 300 MB, small 650 MB). Generation waits while an export runs and pauses at a chunk boundary if one starts. iOS background → pause (abort current chunk), resume on foreground (≤ 1 chunk lost); Android → keep running under a `BackgroundWorkGuard` lease (FGS). Leaving the editor asks, then cancels and keeps the checkpoint; a killed app offers "Resume" via the job record (7-day expiry). Failures are typed (`TranscriptionFailure`: unsupportedDevice, modelMissing, modelDownload(kind), modelCorrupt, insufficientMemory(suggestedTier), diskFull, mediaOffline, noAudio, unsupportedAudio, audioDecode, noSpeech, inference, cancelled, interrupted) and mapped to copy in `captions_strings.dart`. Unsupported codecs skip the clip with a summary note. Audio, video and text never leave the device; logs never contain transcript text or paths (grep test).

---
## 17. UI architecture (`danaview_editor`)

### 17.1 Routes and entry points

| Route | Screen | Gate |
|---|---|---|
| `/projects` | `ProjectsScreen` | `EditorAvailability.platform is EditorSupported && DANAVIEW_EDITOR` else redirect `/` |
| `/editor/:projectId?t=<µs>` | `EditorScreen` (exact seek to `quantize(t)` on open) | same; unknown id → empty state "This project isn't available" with "Go to Projects" |
| `/settings/editor` | `EditorSettingsScreen` (explicit child route of `/settings`, reached through `DanaviewSettingsScreen.onOpenEditorSettings`; `SettingsDestination` is unchanged so the router's exhaustive switch never breaks) | hidden when unavailable |
| `/settings/licenses` | `DanaviewLicensesScreen` (custom, no Material `LicensePage`; explicit route, reached through `DanaviewAboutScreen.onOpenLicenses`) | always |

- **Home header** (`_HomeHeader` in `danaview_home_screen.dart`): `DanaviewIconButton(icon: Icons.movie_edit, variant: tonal, size: 44, iconSize: 22, tooltip: 'Video editor', semanticLabel: 'Open video editor')` placed **immediately left of the settings gear**, through a new `DanaviewHomeScreen.onOpenEditor` callback (null hides it). At 280 px and 1.35× the title keeps 96 px.
- **Player** (`danaview_controls_overlay.dart`, `danaview_player_screen.dart`): `DanaviewPlayerScreen.onEditVideo(PlayerEditRequest{media, position, wasPlaying})`; a top-bar `DanaviewIconButton(Icons.movie_edit)` "Edit video (E)" first in the trailing group, an "Edit video" row in the Playback more sheet, the `E` key, and an "E – Edit video" line in the player's Keyboard Shortcuts cheat sheet (`settings/danaview_settings_panel.dart`, shown only when `onEditVideo != null`). Shown only for local media on supported platforms; **hidden while the player controls are locked** (the `E` key is ignored then); unsupported local formats and devices below the editor gate show the button and explain on tap (platform- and reason-specific copy).
- **`EditorLauncher.openFromPlayer`** (UX-41): pause → `File.exists` and `engine.compatibility` (≤ 300 ms; platform-specific copy, e.g. iOS MKV) → `findUntouchedProjectFor(path)` or `create(fromMedia, initialPlayhead: position)` ("Preparing editor…" dialog after 300 ms; when the import needs a managed copy, e.g. the Android "open with" cache, a free-space preflight (size + 64 MB) runs first and the dialog shows copy progress with Cancel, which deletes the partial copy) → `PlayerHandoff.suspend(pause | release on lowMemoryDevice)` → push `/editor/:id?t=` → on pop, `resumeAfterEditor` (paused at the original position, orientation restored).
- **Orientation**: `ScreenOrientationPolicy` owner stack (`enter/release/toggle`) replaces the single static owner; the editor uses `OrientationMode.free` on phones; `PlayerOrientation` keeps its API as a wrapper.
- `danaview_features` never imports the editor; the router (app root) wires callbacks (`EditorAvailability.showsEntryPoints ? … : null`).

### 17.2 Layout

`EditorLayoutSpec.resolve(size, padding, viewInsets, textScaler, touch, splitRatio, inspectorOpen)` is pure and unit-tested over the full matrix. Kinds: `compactLandscape` (usable height < 520 and landscape), `compactPortrait` (width < 600), `medium` (< 1000), `expanded`. Regions: top bar (close, title button with save status, undo, redo, export), preview, transport, timeline, tool strip (bottom) or rail (side), inspector (non-modal `DanaviewDockedPanel` dock in compactPortrait; side pane elsewhere). Sizes derive from the text scale (tool tile 60/64 px; lanes video 52/60/76, audio 40/48/64, text/subtitle ≥ 32). A deterministic degradation ladder (timeline min → preview 112 → icon-only tool tiles → transport merged into top bar → keyboard-up text editing hides the preview) is recorded in `spec.degrade` for tests. Modal `showDanaviewSheet` is used only for flows (export, auto captions, relink, import, project, track menu, markers, history, tasks).

### 17.3 State management (Riverpod 2, `StateNotifier`)

Root providers (overridden by `EditorBootstrap`): `editorEngineProvider`, `projectRepositoryProvider`, `mediaPoolServiceProvider`, `transcriptionServiceProvider`, `editorPrefsProvider`, `editorCapabilitiesProvider`. Per-project families keyed by `ProjectId` (`autoDispose` + `keepAlive` until `close()` completes): `editorSessionProvider`, `editorControllerProvider` (`EditorState`), `playheadProvider`, `transportProvider`, `viewportProvider`, `interactionProvider`, `timelineSnapshotProvider`, `exportControllerProvider`, `autoCaptionsControllerProvider`, `relinkControllerProvider`. `EditorScope` (InheritedWidget) supplies the id.

```dart
class EditorState { EditorPhase phase; EditorFailure? failure; EditProject? project; bool inTransaction; HistoryStatus history;
  SaveStatus save; EditorSelection selection; ToolId? tool; InspectorRoute? inspector; EditModes modes; PreviewStatus preview;
  MediaHealth media; List<EditorTaskInfo> tasks; }
class EditorController extends StateNotifier<EditorState> {
  Future<void> open({TimeUs? initialPlayhead}); Future<CloseOutcome> close(); Future<SaveOutcome> saveNow({bool manual});
  EditResult apply(EditCommand c); EditTransaction beginTransaction(String label); bool undo(); bool redo(); void jumpHistory(int n);
  /* selection, tool, inspector, modes; lifecycle hooks; Stream<EditorEvent> events (toasts, haptics, announcements) */ }
```

Not in `EditorState` (high frequency or local): playhead (`PlayheadController`, a `ValueListenable<TimeUs>` that extrapolates `PreviewClock` samples per vsync, notifies only on frame change, drops stale `seq`, coalesces scrub seeks with ≤ 1 in flight and adopts `SeekAck.displayedFrameTime`), transport state, zoom/scroll, drag ghosts, gesture state, panel-local UI. **Nothing in `EditorState` changes per playback frame.**

Every mutation is `EditorController.apply(cmd)`: commit → history → `PlanSync` patch → autosave request → event. Continuous gestures use `EditTransaction` (§7.3) with state emission coalesced to one per frame and transients to native.

### 17.4 Timeline

One custom `RenderTimelineCanvas` (`RenderBox`, repaint boundary) paints only the visible window (binary search per lane, O(log n + visible)); track headers are real widgets; ruler, interaction layer (ghosts, guides, marquee, trim pills) and playhead are separate repaint layers. `TimelineSnapshotBuilder` reuses `LaneModel`/`ItemModel` instances when domain objects are `identical`. `TimelineViewportController`: zoom from "whole project + margin" to 48 px per frame; anchor at focal point (or playhead when centre-locked); centre-locked playhead is the touch default (scrolling scrubs), free mode the pointer default. `TimelineGestureArbiter` on hit type: eager handle drags (trim, keyframe, playhead knob, marker), pointer drag of selected items, long-press lift (touch) and context menu, tap select (Shift/⌘ toggles), scale recognizer (axis-locked pan, horizontal pinch zoom, fling), marquee (mouse), secondary click menus, hover cursors. Moves/trims call `dryRun` per pointer move (≤ 2 ms) and render the returned placements; snapping uses core `SnapIndex` (8 px pointer, 12 px touch, haptic on engage, Alt disables); auto-scroll at edges. Thumbnails (JPEG strips → `ui.Image` LRU 48/96 MB, priority queue, cancel off-screen, defer during fast fling) and waveforms (mip pyramid built in an isolate, LRU 24 MB) are lazy. A picture-tile cache (UX-43) is added only if QA-04 shows a budget miss.

### 17.5 Preview region

`PreviewSurface` (black → `AspectRatio(canvas)` → `Texture`), status overlays (starting, failed with "Restart preview", offline media card with "Relink…", degraded badge), `TextOverlayLayer` (D-05), `ManipulationOverlay` (one `ScaleGestureRecognizer` for move/pinch/rotate including trackpad pan-zoom; corner and rotate handles; snapping to centre/edges/safe margins; keyframe-aware writes at the playhead), crop/mask/eyedropper modes (`setEditingMode`, `sampleColor` throttled to 15 Hz), fullscreen route with the same texture id and overlay. Quality menu: Auto (adaptive full → 1/2 → 1/4, the default) or a pinned Full / 1/2 / 1/4 (§12.2, D-43(e)). **Render preview (UX-44, D-45):** a thin render marker strip under the ruler shows rendered (green), heavy-unrendered (amber) and not-needed (none) ranges; the "Render preview" action renders the selection, loop range or whole timeline on every tier; on the minimal and low tiers heavy ranges render automatically while idle and charging.

### 17.6 Action registry and shortcuts

`EditorActionId` (complete list, UX-01): playback `playPause, prevFrame, nextFrame, back1s, forward1s, prevEdit, nextEdit, goStart, goEnd, fullscreenPreview`; editing `split, delete, rippleDelete, deleteGap, undo, redo, save, copy, cut, paste, duplicate, selectAll, escape, multiSelect, moveToTrack`; timeline `toggleSnapping, toggleRipple, zoomIn, zoomOut, zoomFit, centerPlayhead, laneHeight, safeGuides, addTrack`; markers `addMarker, editMarker, deleteMarker`; tools `media, addMusic, recordVoiceover, extractAudio, addText, captions, autoCaptions, addCaption, importSubtitles, exportSubtitles, regenerateCaptions, addOverlay, adjust, filters, transitions, format, transform, crop, mask, chromaKey, speed, volume, fades, keyframes, keyframeAtPlayhead, resetTransform, bringForward, sendBackward, reverse, freeze, replace, clipInfo, export, renderPreview, showShortcuts, projectSheet, history, tasks, relink`. One `EditorActionRegistry` feeds tool tiles, context menus, keyboard shortcuts, semantics custom actions and the shortcuts sheet. Handlers come from per-feature binding files (`actions/bindings/<feature>_bindings.dart`) merged by `wiring/action_bindings.dart`.

Shortcuts (`⌘` = Command on Apple platforms, Ctrl elsewhere): Space/K play-pause; ←/→ frame; Shift+←/→ 1 s; ↑/↓ edit points and markers; Home/End; S split; Delete/Backspace delete; Shift+Delete ripple delete; ⌘Z undo; ⌘⇧Z (and Ctrl+Y off Apple) redo; ⌘S save (works in text fields); ⌘C/⌘X/⌘V/⌘D copy/cut/paste/duplicate; ⌘A select all; Esc cancel → close panel → clear selection → exit fullscreen; M marker; N snapping; R ripple; ⌘=/⌘−/Shift+Z zoom; F fullscreen; ⌘/ or ? shortcuts sheet. A focus guard disables non-text-safe actions while an `EditableText` has focus. The editor-level `Shortcuts` scope **overrides Flutter's defaults** outside `EditableText`: Space/Enter map to `playPause` instead of `ActivateIntent` (so a focused tool tile is not pressed), and the arrow keys map to frame/edit-point navigation instead of `DirectionalFocusIntent`; this holds after a tool tile was tapped. Pointer: wheel scrolls lanes vertically, Shift+wheel scrolls time, ⌘/Ctrl+wheel zooms anchored at the cursor, secondary click opens context menus, drag on empty lanes draws a marquee. Verified on an iPad simulator with a hardware keyboard and on a tablet emulator (QA-00 scenario 12).

### 17.7 Panels and flows (owner feature → surface)

Media (bin, import, add at playhead, add as overlay, replace, relink, drag to timeline, external drop), Audio (music, record voiceover, extract audio, volume/mute/fades/keep pitch), Text (edit, font, style, background, stroke, shadow, animation with loop preview), Captions (cue list, add, edit, timing, split, merge, delete, style, position, burn-in, import/export SRT/VTT, Auto captions, Regenerate), Overlay (PiP video/image, bring forward/back), Effects (Adjust: Light/Color/Detail + before/after + apply to all), Filters (12 looks + My LUTs, intensity, `.cube` import), Transitions (7 types + None, duration limited by `TransitionLimits`, direction, loop preview, apply to all cuts), Format (aspect, background colour/blur, frame rate, resolution base), clip context tools (split, speed constant/curve, volume, transform, crop, adjust, filters, chroma key with matte preview and eyedropper, mask, keyframes, reverse, freeze, extract audio, replace, duplicate, copy, ripple delete, delete, info), Export sheet (presets, custom settings gated by capabilities, burn-in per subtitle track, SRT/VTT side files, destinations, progress, cancel, completion, failure fallbacks), Relink sheet, Recovery dialog, Project sheet (rename, format, save, media in project, shortcuts, tasks), History sheet (last 50 entries; jump = one plan patch), Tasks sheet (proxies, reverse, freeze, waveforms, captions, download).

### 17.8 Content fonts (D-30)

`packages/danaview_editor_fonts` bundles 10 OFL-1.1 families for **user content only** (regular, bold, italic where available; ≈ 5.6 MB as built: the upstream variable-font files are used; lead decision 2026-10-15 accepts this over the earlier 3–4 MB estimate rather than subsetting, which would drop scripts users may type): Figtree (default), Inter, Montserrat, Oswald, Bebas Neue, Playfair Display, Lora, Caveat, Pacifico, JetBrains Mono. `FontCatalog` maps stable ids to family names; scripts the family lacks (CJK, Arabic, Devanagari…) use Flutter's system font fallback, identical in preview and export because both are rendered by Flutter. The font picker previews each family in itself. Licences appear in the licences screen.

### 17.9 Accessibility and no-overflow

Semantics on every painted element (clips with custom actions for split/delete/move/trim by frame and second; playhead as an adjustable slider; markers, transitions, keyframes as nodes; manipulation overlay with move/scale/rotate actions); live announcements throttled to 1/s through an `editorAnnounce()` wrapper; touch targets ≥ 44×44; contrast ≥ 4.5:1 computed; reduced motion honoured; RTL chrome mirrors while the time axis stays left → right. No-overflow: pure planners are unit-tested over the matrix (widths 280–1280 incl. 280×500, 320×568, 360×740, 390×844, 412×915, 568×320, 667×375, 844×390, 932×430, 744×1133, 834×1194, 1133×744, 1194×834, 1280×800; text scale 0.85/1.0/1.35; keyboard inset none/40%); every surface and state has a widget matrix test (`takeException() == null`, `expectInside`, `fitsFully`) with long-content fixtures; PRs run a 6-surface subset including 280×500 @1.35 and 568×320 @1.35, nightly runs the full matrix.

### 17.10 Settings and storage

`StorageContributor` extension point in `danaview_features` (`package:danaview_features/storage.dart`): "Video editor projects" (no clear action; opens Projects), "Editor cache" (clear thumbnails, waveforms, proxies, sprites and render-preview files, D-45; disabled while a session or job is active), "Speech model" (delete; blocked while a job runs). Editor settings (`editor.` prefs keys): proxy media Auto/Always/Off (default Always on the minimal and low tiers, Auto on mid and high; §9.5), default preview quality (Auto adaptive, or pinned Full / 1/2 / 1/4), render preview Auto/Manual (default Auto on the minimal and low tiers: renders heavy ranges while idle and charging; Manual elsewhere; D-45), centre playhead on touch, snapping haptics, default new-project aspect, Auto captions model status/delete.

---

## 18. Threading, performance budgets and caching

### 18.1 Where work runs

| Work | Where |
|---|---|
| Widgets, gestures, painting, commands, `dryRun`, incremental compile + diff (≤ 300 items), autosave encode | UI isolate (budgets below) |
| Full plan compile (> 300 items), plan JSON encode, project open (read/migrate/decode/validate/repair, returned with `Isolate.exit`) | `Isolate.run` |
| Project hashing + atomic writes | long-lived writer isolate |
| SRT/VTT/.cube parse, waveform mip pyramid, sprite zlib, model SHA-256, segmentation > 4k words | `Isolate.run` |
| Decode, composite, encode, thumbnails, proxies, reverse, speech audio | native engine queues (iOS: main for API/KVO/display link, `previewControlQueue`, per-compositor `renderQueue`, `jobQueue`, export pumps; Android: main, `danaview-preview`, `danaview-gl`, `danaview-export`, `danaview-jobs`, `danaview-io`) |
| whisper inference | native `std::thread` per job + ggml pool |

Channel budgets: clock ≤ 10 Hz (4 Hz suffices with extrapolation), transients ≤ 60 Hz coalesced natively, ≤ 1 seek in flight, ≤ 8 thumbnail tiles in flight, progress ≤ 4 Hz.

### 18.2 Budgets (p90 unless stated; low tier = 4 GB Android / iPhone SE 2, mid = Pixel 7a / iPhone 12; the `minimal` tier has only the D-40 promise)

| Metric | Low | Mid | Owner |
|---|---|---|---|
| `apply` one lane at 1,000 items / `dryRun` | ≤ 2 ms / ≤ 1 ms | same | CORE-35 |
| Incremental compile + diff at 2,000 items | ≤ 3 ms | same | CORE-35 |
| Full compile at 2,000 items (isolate) + encode | ≤ 60 + 25 ms | same | CORE-35 |
| Project open at 2,000 items | ≤ 150 ms (core) | same | CORE-35 |
| Editor open → first preview frame (200 items) | ≤ 2.5 s | ≤ 1.5 s | QA-04 |
| Projects screen first paint (40 projects) | ≤ 400 ms | ≤ 250 ms | QA-04 |
| Timeline fling/pinch UI thread per frame | ≤ 8 ms (p99 ≤ 14) | ≤ 5 ms (p99 ≤ 10) | QA-04 |
| Timeline raster per frame | ≤ 10 ms | ≤ 7 ms | QA-04 |
| Playback with centre-follow: UI per frame; widget rebuilds | ≤ 3 ms; 0 except `TimecodeText` | same | QA-04 |
| Commit → preview shows a property edit / structural edit (paused) | ≤ 150 / 400 ms | ≤ 80 / 250 ms | QA-04 |
| Android structural edit during playback → playing again (D-36) | ≤ 1,000 ms | ≤ 600 ms | QA-04, AND-01 |
| Slider transient → preview | ≤ 3 frames | ≤ 2 frames | QA-04 |
| Scrub lag while dragging / exact frame after release | ≤ 200 / 300 ms | ≤ 120 / 200 ms | QA-04 |
| Thumbnail tile after scroll stop (miss) | ≤ 400 ms | ≤ 250 ms | QA-04 |
| Dart heap with 1,000 items open | ≤ 180 MB | ≤ 150 MB | QA-04 |
| Autosave block on main isolate | ≤ 2 ms | ≤ 1 ms | QA-04 |
| Export 1080p30 H.264 (2 layers + text) | ≥ 0.7× RT | ≥ 1.5× RT | QA-04 |
| Captions: Balanced, 1 min speech | est. 25–50 s (Android low) | 7–15 s (Android mid), 3–6 s (iPhone 11) | QA-06 |

Design target for large projects: 2,000 items, 32 lanes, 3 h timeline, 300 media files, 3,000+ cues. Remedy order if a UI budget fails: tile cache (UX-43) → lower overscan → fling-deferred requests → lane-height buckets → proxies by default.

### 18.3 Memory and caches

Native per-tier budgets in §13.4/§14.4; caches in §15; Dart: thumbnails 48/96 MB (25% after memory pressure), waveforms 24 MB, paragraphs 512 entries, history ≤ 48 MB. `didHaveMemoryPressure` / `signals.memoryWarning` trim all of them and the preview's native caches. Device tier from `EditorCapabilities`.

---

## 19. Error handling

```
native error ─► FlutterError(code = EngineErrorCode.name, no paths) ─► error_mapper.dart ─► EngineFailure
store/codec/port errors ─► StoreFailure {diskFull, permissionDenied, notFound, corrupt, newerSchema, busy, io} / MediaAccessFailure
command rejections ─► EditRejection (data)        AI ─► TranscriptionFailure / ModelDownloadFailureKind
                    └──────────────► danaview_editor maps to EditorFailure ─► editor_messages.dart / feature strings ─► toast | dialog | inline
```

`EditorFailure` (sealed): `ProjectNotFound, ProjectNeedsNewerApp, ProjectCorrupt, SaveFailed(kind), MediaUnavailable, MediaUnsupported(reason), ImportFailed, PreviewFailed(recoverable), ExportFailed(encoderUnavailable|encoderSizeLimit|diskFull|interrupted|destinationDenied|unknown), PermissionDenied(microphone|photosAdd|notifications), ParseFailed(srt|vtt|cube, line), ModelDownloadFailed, TranscriptionFailed, UnknownFailure`. Rules: boundaries convert platform exceptions; controllers wrap anything else as `UnknownFailure`; **no editor action can crash the app**; every subtype has tested copy (plain, specific, with a next step); rejections are info toasts; logging is `debugPrint`/`os_log`/`Log` only, never media paths or transcript text; "Copy details" copies a code and settings only. Engine mapping: `mediaOffline → MediaUnavailable`; `permissionDenied → PermissionDenied`; `unsupportedMedia, notSupportedOnDevice → MediaUnsupported`; `decoderInitFailed, decodeFailed, gpuUnavailable → PreviewFailed(recoverable)` in preview, `ExportFailed(unknown)` in export; `encoderUnavailable → ExportFailed(encoderUnavailable)` ("Export with H.264"); `encoderSizeLimit → "Lower resolution"`; `diskFull`; `interrupted`; `planInvalid, internal → UnknownFailure` + debug assert; `planOutOfSync` handled by `PlanSync`; `surfaceLost` auto-recovered; `cancelled` is not a failure. Open never throws for content problems (health + warnings).

---

## 20. Security and privacy

### 20.1 Originals and files

1. Original media is opened **read-only** (iOS `AVURLAsset`/`AVAssetReader`; Android `ContentResolver` read, `MediaExtractorCompat`). The engine writes only to Dart-supplied paths under the editor roots and its cache.
2. Every Dart delete goes through `OwnedFileDeleter` (§9.6). Project delete removes only project-owned files and managed copies no other project references (GC), never `Documents` or external assets.
3. Bookmarks and persisted grants are released when no project references them. iOS security-scoped access is refcounted per session.
4. Exports go to Photos (add-only), Files/SAF or the share sheet chosen by the user; "Keep a copy" writes a **new** file to `Documents/Exports/` only through `DocumentsExportWriter` (exclusive create, unique name, never overwrites, refuses symlinks; D-44). Location metadata is stripped.
5. No `READ_MEDIA_IMAGES`; pickers only (Photo Picker, PHPicker), so the app never browses the photo library.

### 20.2 Model download consent (§16.3)

No download without a `UserConsent` built from the exact `ConsentDisclosure` shown (size, host, hash); a test restricts construction to the consent view; consent is never remembered; the downloader re-checks the disclosure against the catalog and the server's `x-linked-size`/`x-linked-etag` before any byte is written. Only the model file name is requested; no identifiers in headers.

### 20.3 Privacy policy and terms (UX-42, `packages/danaview_features/lib/src/more/legal_texts.dart`; `legalEffectiveDate` = release date)

- **Summary (replace):** "Danaview keeps everything on your device. There are no accounts, no analytics, no ads and no tracking, and nothing you watch, edit or type is sent to us. The only extra download is the optional speech model for Auto captions, and only after you agree." (This agrees with the existing "Danaview connects to the internet only when you ask it to" section, which gains the speech-model entry below.)
- **Platform scope:** `legal_texts.dart` is shared with the macOS, Windows and Linux builds, so every editor and Auto captions bullet is qualified "On iPhone, iPad and Android, …" (static text; no platform-conditional code).
- **What Danaview stores on your device (add):** (1) "On iPhone, iPad and Android, video editing projects: your edits and the files the editor makes for them, such as voice recordings, freeze frames, reversed clips, optimized copies for smoother editing, thumbnails and audio waveforms. Projects refer to your original videos, photos and music where they are. Editing never changes, moves, renames or deletes your originals. On Android, video editing projects are not included in device backups." (2) "On iPhone, iPad and Android, videos and photos you add to a project from your photo library, and files you drop into the editor, are copied into Danaview's own storage so the project keeps working. Deleting a project removes copies no other project uses." (3) "On iPhone, iPad and Android, if you use Auto captions: the speech model you downloaded, and the text transcribed from your videos so captions can be adjusted later without transcribing again. They are never uploaded."
- **When Danaview uses the internet (add, lead "Speech model for Auto captions"):** "On iPhone, iPad and Android, only if you choose to create captions automatically, and only after you agree, Danaview downloads a speech recognition model (about 31 to 181 MB, depending on the quality you pick) from Hugging Face (huggingface.co), which delivers it through its download network on hf.co. The request contains only the model's file name. No video, audio, captions or personal data are sent. Hugging Face sees the usual details of the connection, such as your IP address, and handles them under its own policies. After the download, captions are created entirely on your device, even when you are offline." Closing paragraph: "Files on your device that you play, edit, inspect, export or browse are processed on your device and are never uploaded."
- **Files and permissions (replace):** paragraph "Danaview reads only the files and folders you choose to open, add to your library or add to a project, and on phones and tablets the videos you place in its own folder. It doesn't scan the rest of your storage, and it never changes, moves or deletes your videos, photos or music." plus bullets **Photo library** ("When you add photos or videos to a project, Danaview receives only the items you pick. When you save an export to Photos or your gallery, Danaview adds that video and doesn't read the rest of your library."), **Microphone** ("Used only while you record a voiceover in the editor. Recordings stay in that project on your device."), **Notifications (Android)** ("Used only to show export and caption progress while Danaview is in the background, if you allow it.").
- **Your choices (add):** "On iPhone, iPad and Android, delete video editing projects in the editor's Projects screen. This removes the project and the files made for it, never your originals." and "Delete the Auto captions speech model, and clear editor thumbnails, waveforms and optimized copies, in Settings › Storage & history or Settings › Video editor."
- **Terms:** "Your content" adds responsibility for rights to footage, music, images and fonts used and published; new "Editing and exports" (non-destructive, keep backups, presets are conveniences and not endorsed by YouTube/Instagram/TikTok); new "Auto captions" (may contain mistakes; review before publishing; third-party open-source licences in Settings › About › Open-source licences); "Trademarks" adds YouTube, Instagram and TikTok; "No warranty" adds export size estimates and automatic captions as approximate.
- A test asserts the policy contains `SpeechModelSpec.host` (`huggingface.co`) and `hf.co` (`test/privacy_policy_host_test.dart`, INT-04, because only the app root depends on both packages), and UX-42's own test checks the effective date changed. INT-04 also proves **zero network access before consent**: an `HttpOverrides` spy wraps the real `TranscriptionServiceImpl` through the Auto captions flow up to the consent view and asserts no `HttpClient` request was opened before `UserConsent.accepted`, and that the first one afterwards targets `huggingface.co`.
- **Hosted copies:** INT-05 publishes the updated policy and terms, generated from `legal_texts.dart`, at the store privacy URLs (`https://vecvel.com/ios/danaview/privacy` for iOS and macOS — `ios/fastlane/metadata*/en-US/privacy_url.txt` — and the Play listing's privacy URL), with a diff or screenshot as release evidence.

### 20.4 Platform declarations

| Platform | Item |
|---|---|
| iOS `Info.plist` (INT-03) | `NSMicrophoneUsageDescription` "Danaview uses the microphone only while you record a voiceover in the video editor."; `NSPhotoLibraryAddUsageDescription` "Danaview saves the videos you export to your photo library."; `BGTaskSchedulerPermittedIdentifiers` = [`com.vecvel.danaview.export.*`] (plus any background mode IOS-13 proves necessary); **no** `NSPhotoLibraryUsageDescription` |
| iOS entitlements (INT-03) | `com.apple.developer.background-tasks.continued-processing.gpu` once Apple grants it (behind an Xcode build setting until then) |
| iOS privacy manifests | `danaview_editor_engine` pod: FileTimestamp C617.1, DiskSpace E174.1, SystemBootTime 35F9.1; `danaview_whisper` pod: DiskSpace E174.1; Runner: `NSPrivacyTracking = false`, no collected data types |
| Android plugin manifest (ENG-08) | `RECORD_AUDIO`, `POST_NOTIFICATIONS` (requested in context), `FOREGROUND_SERVICE_MEDIA_PROCESSING`, `FOREGROUND_SERVICE_DATA_SYNC`, `WRITE_EXTERNAL_STORAGE maxSdkVersion=28`, `ExportService` with `foregroundServiceType="mediaProcessing|dataSync"`, `FileProvider` (`${applicationId}.danaview.editor.files`), the Photo Picker backport `ModuleDependencies` service entry (`com.google.android.gms.metadata.ModuleDependencies` with the `photopicker` module) |
| Example host app (ENG-09) | pre-declares every key and entry native tests need: `NSMicrophoneUsageDescription`, `NSPhotoLibraryAddUsageDescription`, `BGTaskSchedulerPermittedIdentifiers` in `example/ios/Runner/Info.plist`; the app's own declarations stay INT-03's |
| Android app manifest (CORE-28) | `android:dataExtractionRules`, `android:fullBackupContent` |
| Stores (INT-05) | Privacy labels / Data safety unchanged ("No data collected"); Play FGS declaration (`dataSync` 29–34, `mediaProcessing` 35+) with a demo video; App Review note: the model download is data, not code |
| Licences screen (UX-42) | `LicenseRegistry` entries plus whisper.cpp/ggml (MIT), OpenAI Whisper weights (MIT), Silero VAD (MIT), AndroidX Media3 (Apache-2.0), content fonts and Figtree (OFL-1.1), and the player's existing mpv/FFmpeg (LGPL) notices |

---

## 21. Testing strategy

### 21.1 Layers

| Layer | What | Where (ticket) |
|---|---|---|
| Pure Dart unit | time math properties; every command's goldens and rejections; keyframe partitioning; ramp closed forms vs numeric integration (≤ 1 µs); `boxAt` = compiler matrix; snapping; history, coalescing, transactions; codecs; formats corpora; compile goldens per lowering row; diff/patch property; export presets | `packages/danaview_editor_core/test` (CORE-02 … CORE-33), `dart test` |
| Model fuzzer | random projects × command sequences (200 seeds × 500 steps in CI, 10k nightly): validator after each step, undo^n/redo^n identity, stamps never repeat, JSON round trip, diff/patch | CORE-34 |
| Persistence fault injection | crash at every `StoreFs` step → always recoverable; recovery listing; GC/deleter fuzz (symlinks, `..`, case) | CORE-24, CORE-26, CORE-28 |
| Cross-language contract | ~25 RenderPlan fixtures (incl. `grid_cuts_30fps.json` with edges at k ≡ 1, 2 mod 3) + frame-grid (ceil, floor, `P(k)`, rational inputs), packing, keyframe, transform and render-math vectors decoded and evaluated in Dart, Swift (XCTest) and Kotlin (JUnit) | CORE-02, CORE-29, CORE-36, API-03, IOS-08, AND-08 |
| Reference renderer goldens | Dart CPU renderer vs committed PNGs (regenerated only by `tool/regen_goldens.dart` with review); Dart reference audio mixer (gain envelopes, fades, crossfades, mute/solo, downmix, clip) vs analytic vectors | API-03 |
| Engine Dart | `MobileEditorEngine` with mocked Pigeon channels: error mapping, out-of-sync retry, event routing, cancellation, export reattach, resumable and completed-while-detached records | ENG-01 … ENG-04 |
| Native unit | XCTest on the simulator (plan decode, composition layout within 1 µs, instruction validity, audio ramps, kernels on 8×8 images through a software `CIContext`, loaders, PCM trim); JUnit (mapper structure, gating, speed/gain providers, classification) | IOS-02 … IOS-16, AND-02 … AND-15 |
| Widget | fakes (`FakeEditorEngine`, in-memory repository, `FakeTranscriptionService`); every flow; rebuild budget (300 items, 120 clock samples: scaffold/timeline/toolstrip build counts unchanged); a11y guidelines; no Material chrome | UX-xx |
| Golden (Ahem, DPR 1 and 3) | timeline at four zooms with every item kind/state, ruler, manipulation handles, speed curve | UX-10, UX-22, UX-25 |
| Overflow matrix | §17.9 | QA-09 |
| On-device E2E | §21.2 | QA-00, QA-01, QA-02, QA-07, QA-10 |
| Parity, accuracy, A/V sync | frame-counter barcode exact seeks 200/200 (also through speed segments); **grid-cut case**: cuts at k ≡ 1 and 2 (mod 3) at 24/30/48/60 fps, every frame of a 3 s window around each cut shows the expected barcode in preview and export; clap/flash sync ≤ 1 frame & ≤ 20 ms (export) / ≤ 40 ms (preview, §12.7) at 1×, 2× keep-pitch, 0.5× ramp, cross dissolve; render parity vs reference; reverse barcode strictly decreasing; freeze barcode exact; proxy PTS equal | QA-03 (fixtures ENG-05) |
| Export conformance and audio | §14.4 conformance on every preset (+4K where allowed) incl. no-audio and all-muted projects; portrait-encoder fallback; PCM checks against the Dart reference mixer (3-lane mix with music fades, volume keyframes, muted and soloed-out lanes, cross-dissolve audio: RMS per 20 ms ±0.5 dB, muted < −60 dBFS; 200% = +6.02 ± 0.1 dB); keep-pitch FFT (1 kHz tone at 2× and 0.5×: dominant bin ±2%; keep-pitch off → 2 kHz / 500 Hz); ramp-seam click test | QA-11 (fixtures ENG-05) |
| Performance and soak | §18.2 budgets in profile mode (`TimelineSummary`, heap snapshots, native signposts); 1 h random-edit soak with interruptions, low storage, offline media, process death | QA-04, QA-05 |
| AI | C++ host tests incl. TSan; Dart runtime with fake bindings; downloader with fake HTTP; segmenter goldens in 9 languages + properties; orchestration with fakes; accuracy eval (WER/CER, boundary error, hallucination rate) nightly | AI-03 … AI-13, QA-06 |

### 21.2 On-device verification on the iOS Simulator and an Android Emulator

The shared app-level suite lives in `integration_test/editor/` (QA-00) and runs against the real app wiring with test fixtures and a pre-staged tiny model (no network in CI). QA-01 runs it on the **iOS Simulator** (iPhone 17 Pro and iPad Pro with a hardware keyboard, iOS 26 runtime; iOS 18.2 as the oldest installed runtime) plus a launch/player/editor smoke on the **iPhone 7 (iOS 15.8.x) and iPhone 8 (iOS 16.7.x)** lab devices (D-41), and QA-02 on an **Android Emulator** (API 35 x86_64 Pixel profile; API 29 for the gate and minimal tier with 2 GB RAM; API 34 for the `dataSync` FGS; **API 28** for the below-gate behaviour; a tablet profile for drops, keyboard and mouse). Scenarios: (1) Home edit button left of the gear opens Projects; (2) player → Edit on `frame_counter_1080p30.mp4` at 0:05:10 opens the editor with the playhead at 5 s + 10 frames and the captured frame's barcode equal to 160; (3) create/rename/duplicate/delete project; (4) split, trim, move with snap, ripple delete, undo/redo, copy/paste, duplicate; (5) text with animation, subtitle cue add/split/merge, SRT import and export round trip; (6) speed 2× and a ramp, reverse, freeze frame, transition cross dissolve, LUT import, chroma key, mask, keyframes; (7) export **of a project built through the UI** (one text item with typewriter, one burned SRT track, one track with burn-in off, a LUT and a cross dissolve on `frame_counter`) at 720p H.264 MP4, verified by `MediaInspector` (container, `avc1`, size, duration ± 1 frame, AAC) and, where the probe allows, HEVC/MOV, then frames pulled with the engine's freeze job: the subtitle safe area differs from a burn-in-off export at each cue midpoint and is identical between cues, the burn-in-off track never appears, the typewriter glyph count increases across its in-animation, and blended (unreadable or mixed) barcodes occur only inside `[cut − d/2, cut + d/2)`; SRT/VTT side files parse back to the same cues; (8) auto captions with the tiny model on `speech_10s.m4a` (≥ 1 cue, SRT parses back, undo removes all in one step); (9) recovery after killing the app; (10) missing media + relink on a sandbox copy, including "Relink several"; (11) background/foreground during playback (no black frame after 1 s); (12) **hardware keyboard and pointer**: Space/K, ←/→ frame step (barcode-checked), Shift+←/→, S, Delete/Backspace, ⌘/Ctrl+Z, ⌘/Ctrl+Shift+Z, ⌘S inside a text field, ⌘C/⌘V/⌘D, Space after tapping a tool tile still toggles playback, wheel/Shift+wheel/⌘+wheel zoom, right-click menu and marquee; (13) **voiceover**: grant permission, record 3 s (simulator host mic / emulator virtual mic), a WAV clip lands on a voice lane at the playhead plus latency and is audible in the export; (14) a PiP video overlay moved, scaled and faded, then exported; (15) extract audio, then add music with a fade-in; (16) add a marker and snap a clip to it; (17) ⌘X cut then paste; (18) close and reopen a project: timeline JSON, playhead and zoom are equal. Background, foreground, kill and relaunch steps are driven from the e2e shell scripts (`xcrun simctl`, `adb shell am` / `input keyevent`) synchronized with the in-app test through a file handshake; cross-app drags from Files/Photos are manual checklist items with recorded evidence (iPad simulator and tablet emulator). Platform extras: Android — export continues in the FGS with the activity destroyed, notification Cancel works, swiping the app from recents mid-export ends with the video in the Gallery and a "finished" card on relaunch (D-39), process death → one `interrupted` record; iOS — backgrounding mid-export ends with `pausedInBackground`, and on return the export resumes from its last segment and passes conformance (the encoder loss itself is verified on real iPhones in IOS-01/IOS-13); API 28 — Home edit button shows, Projects shows the `android_too_old` copy, the player's Edit explains, and the player suite is green. Simulator/emulator realities (no hardware HEVC, software H.264, meaningless performance) are reported, not failed; performance, HEVC, thermal and background behaviour run in the device lab (iPhone 7 on iOS 15.8, iPhone 8 on iOS 16.7, iPhone SE 2, iPhone 12, iPhone 15 Pro, one iPad with background GPU if available; one 2–3 GB Android Go device, 4 GB Helio/SD6xx Android, Pixel 7a, Pixel 9/Galaxy S24, one API 29 device).

---

## 22. CI and tooling

`.github/workflows/editor-ci.yml` (INT-01) runs on PRs that touch editor packages, `test/architecture/` or the workflow: `dart-core` (ubuntu: `scripts/ci/editor/core.sh`: analyze + test + fuzz-lite + benchmarks with a 25% regression gate after CORE-35), `flutter-packages` (ubuntu: engine API, transcription, editor, whisper Dart, root architecture tests), `whisper-host` (ubuntu + self-hosted macOS: C++ host tests incl. a TSan job), `android-unit` (ubuntu: Gradle JUnit through the example app), `android-emulator` (ubuntu KVM, `reactivecircus/android-emulator-runner`, API 35 x86_64: instrumented engine tests at 540p), `ios` (self-hosted macOS, Xcode 26.6, iOS 26 simulator: XCTest + engine integration tests; input `runner=macos-15` as fallback). Each job runs its `scripts/ci/editor/<job>.sh` if present (created by the owning ticket) and skips with a notice otherwise. The existing release workflows (`android-release.yml`, `linux-release.yml`, `windows-release.yml`) and fastlane lanes keep working; INT-05 adds the release dart-defines. Tooling prerequisites: `brew install cmake` (≥ 3.28) for the whisper xcframework (not installed on the dev Mac today; the self-hosted runner setup in `scripts/ci/editor/README.md` installs it and `ios.sh` fails early with that instruction when it is missing); Android SDK CMake 3.22.1 (or the pinned version AI-04 documents). The `ios` job also runs `check_ios_min_os.sh` (D-41), and both pods build with `-Werror=unguarded-availability-new`.

---

## 23. Release checklist (INT-05 owns `docs/v1.1/editor/release-checklist.md`)

1. All tickets merged; `editor-ci.yml` green on `main`; existing player tests green; app builds for iOS, Android, macOS, Windows, Linux (desktop with the editor hidden).
2. QA-01 (iOS Simulator) and QA-02 (Android Emulator) reports attached with every scenario passing; QA-03 parity/accuracy/A-V and QA-11 export conformance, preset matrix and audio measurements green on simulator, emulator and device lab; QA-04 budgets met (or renegotiated in writing); QA-05 soak clean; QA-06 eval within thresholds; QA-07 AI device matrix green; QA-08 a11y checklist (VoiceOver + TalkBack) done; QA-09 full overflow matrix green; QA-10 persistence/bookmark/grant survival verified.
3. iOS: deployment target 15.0 everywhere; launch, player and editor smoke on the iPhone 7 (iOS 15.8) and iPhone 8 (iOS 16.7) lab devices and on iOS 26; `check_ios_min_os.sh` clean; `nm -um` shows no `NEWLAPACK`; privacy manifests valid; Info.plist strings present; App Store Connect validation clean; IPA growth ≤ 6 MB for whisper plus the engine; GPU continued-processing entitlement status recorded.
4. Android: AAB contains `libdanaview_whisper*.so` for arm64-v8a/x86_64 only, 16 KB aligned; only `dv_*` exported; FGS declaration submitted; Play pre-launch report clean; `POST_NOTIFICATIONS`/`RECORD_AUDIO` flows verified; backup rules verified.
5. Privacy policy and terms updated in the app and published at every store privacy URL (`https://vecvel.com/ios/danaview/privacy` for iOS/macOS and the Play listing URL) with diff or screenshot evidence; owner sign-offs of D-43 recorded; store descriptions, release notes ("Auto captions run on your device; a one-time model download is needed") and screenshots updated through fastlane metadata; privacy labels unchanged.
6. Flags: release builds pass `--dart-define=DANAVIEW_EDITOR=true --dart-define=DANAVIEW_AUTO_CAPTIONS=true`; desktop builds keep the editor hidden.
7. Version bumped to `1.1.0+3`; the project schema is 1, `minReader` 1, RenderPlan `v` 1; the migration fixtures are committed.
8. Rollback plan: the flags can be turned off in a hotfix build; project files are forward-compatible (`minReader`).

---

## 24. Risks and [VERIFY] register

### 24.1 Top risks

| # | Risk | Mitigation (ticket) |
|---|---|---|
| R1 | Media3 `CompositionPlayer` multi-sequence preview (`@UnstableApi` + `@ExperimentalApi`) misbehaves (gap gating, redraw only re-renders input 0, `setComposition` rebuilds every player, effect pts, HDR) | AND-01 spike on day 1 with go/no-go (D-42); paused edits never depend on redraw (`PausedFrameRenderer`, AND-17, D-36); structural debounce; sized contingency engine AND-16 with owner sign-off on its degradations before M1 ends; export unaffected; pin 1.11.1 |
| R2 | Android decoders, players and GPU memory scale with visual sequences (≈ 3 canvas-size textures each; ≈ 200 MB at 1080p × 8) | core packing and the `maxVisualSequences` cap (D-14, CORE-36), effect early exit for gated frames, preview size caps, preview suspended during export, preflight, multi-pass export precompose above the cap instead of refusing and the render-preview cache (D-45); 6-lane sparse-PiP measurement in AND-01 (AND-08, AND-10, AND-11) |
| R3 | iOS background export: the asset writer loses its encoder in the background; background GPU is iPad-only | segment-resumable export with checkpoints (IOS-17), honest per-device `backgroundKind`, iPad continued processing with the GPU entitlement, real-iPhone measurement on iOS 18 and 26 (IOS-01), honest copy (IOS-13, UX-39) |
| R4 | Parity drift across three render-math implementations | one normative spec, Dart reference goldens, device parity suite gating release (API-03, QA-03) |
| R5 | Structural rebuild latency on large projects | most edits are param-only; ≤ 150 ms composition build target; keep last frame (IOS-08, AND-08, QA-04) |
| R6 | Two decoding engines in memory (mpv + editor) on 3–4 GB devices | `PlayerHandoffMode.release` on low-memory devices (UX-41) |
| R7 | iOS can't edit MKV/WebM/AVI (common for this player's users) | clear platform-specific copy before project creation (UX-41) |
| R8 | whisper jetsam/OOM or thermal slowdown | RAM gating, memory preflight, chunking + checkpoints, thread policy (AI-13, QA-06) |
| R9 | Hugging Face unavailable or blocked | pinned revisions + hashes, clear error; mirror deferred (AI-09) |
| R10 | Play policy on the `dataSync` FGS for API 29–34 | declaration with justification; fallback `backgroundKind = none` there (AND-12, INT-05) |
| R11 | Scope (166 tickets, one release) | skeleton-first parallelism, fakes first, internal milestones, flags keep `main` releasable |
| R12 | Sprite pre-pass time for very long subtitle tracks | content-addressed cache, progress shown (≈ 8 s per 1,000 cues mid) (API-04) |
| R13 | Audio-session conflicts between media_kit and the editor (iOS) | explicit category set/restore, player → editor → player test (IOS-11, UX-41) |
| R14 | Off-by-one frames from µs rounding differences between plan and platform clocks | normative platform-time rule (D-35), shared vectors with floor/round/rational inputs, grid-cut contract fixture and QA-03 barcode case (CORE-02, CORE-29, IOS-08, AND-08, QA-03) |
| R15 | iOS 15/16-only failures (strongly bound newer symbols brick the whole app) | lab devices on iOS 15.8 and 16.7, `-Werror=unguarded-availability-new`, `check_ios_min_os.sh` in CI and release (D-41) |
| R16 | Devices weaker than the low tier | `minimal` tier caps, tested on iPhone 7/8 and a 2–3 GB Android Go device (D-40, QA-04) |

### 24.2 [VERIFY] items (each closed by the named ticket's acceptance criteria)

| ID | Claim | Ticket |
|---|---|---|
| V-D1 | `RandomAccessFile.flush()` performs fsync on iOS/Android | CORE-24, QA-10 |
| V-D2 | Android Photo Picker URIs are persistable; grant caps 512 (API 30+) / 128 | AND-14, CORE-27 |
| V-D3 | iOS document-picker URLs bookmark and resolve across launches | IOS-15, QA-10 |
| V-D4 | `NSURLIsExcludedFromBackupKey` on a directory excludes its contents | IOS-15, CORE-28 |
| V-D7 | Sprite pre-pass time (3,000 cues ≤ 15 s first export, mid tier) | API-04, QA-04 |
| V-D8 | `File.copy` uses APFS clones on iOS (performance only) | CORE-27 |
| V-D9 | Export preset bitrates/sizes match current platform guidance | CORE-33 |
| V-N1–V-N6 | Media3: `getOverlaySettings` input id = sequence index and pts = composition time; effect pts are sequence-cumulative in player and Transformer; whether `experimentalRedrawLastFrame` re-runs effects on **secondary** sequences (expected: no, only input 0; the design no longer depends on it, D-36); straight alpha preserved; `hdrMode` honoured; upright frames. **Answered by AND-01 (recorded by ENG-06 2026-10-11):** V-N1 yes (input id = sequence index, pts within −1…+500 µs of `P(k)`, player and Transformer); V-N2 yes (sequence-cumulative in both); V-N3 **no, unusable**: without the replayable cache `IllegalStateException`, with it `MultipleInputVideoGraph.redraw()` throws `UnsupportedOperationException` on the playback thread (D-36 confirmed, paused edits use `PausedFrameRenderer`); V-N4 yes (within 0.002 in export and player); V-N5 **deferred: device** (the OpenGL tone map needs `GL_EXT_YUV_target`, which the emulator lacks, and it has no Main10 decoder; AND-02 falls back to the MediaCodec tone map on API 31+ or a proxy, §12.5); V-N6 yes (60/60 export, 59/59 player). | AND-01 |
| V-N7 | GLES 3 context on API 29 low-tier devices | AND-02 |
| V-N8 | Pigeon 29 `@EventChannelApi` for Swift + Kotlin. **Confirmed (ENG-06 record):** iOS native → Dart event delivery (`ChannelRoundTripTests.testEventChannelDeliversEngineEvents`, ENG-07); Android Dart → Kotlin subscription on the API 35 emulator (ENG-08); Kotlin → Dart delivery of a native event is asserted by the first Android ticket that emits one (§12.6). | ENG-09 |
| V-N9 | `-fcikernel` metallib builds inside a CocoaPods target and loads on simulator + device. **Yes (IOS-01):** prebuilt per-SDK `-fcikernel` metallibs in the `DVEditorKernels` resource bundle load with `Bundle(for:)` + `CIKernel(functionName:fromMetalLibraryData:)` and match the CPU reference within 1/255 on the iOS 26.5 and 18.2 simulators; library, static- and dynamic-framework linkage build for simulator and device (6/6). Device load deferred: no device available. Applied to the podspec by ENG-06 (§13.2). | IOS-01 |
| V-N10 | Deterministic exact-seek ack on iOS 15 (iPhone 7 lab device), 18 and 26. **Simulator: yes (IOS-01):** 200/200 acked, 0 content errors on iOS 26.5 and 18.2 (with Metal-texture sources), p50 11.6–14.0 ms. iPhone 7 / iOS 15.8: **deferred: no device available** (D-43). | IOS-01 |
| V-N11 | iOS background GPU failure mode (foreground gate prevents errors). **Not answerable on the simulator (IOS-01):** it never suspends the app or takes the GPU/encoder away (exports complete in the background). Deferred: real iPhone on iOS 18 and 26 (no device available); D-22 unchanged (§14.2). | IOS-01 |
| V-N12 | `BGContinuedProcessingTask` wildcard registration timing and required Info.plist keys | IOS-13, INT-03 |
| V-N13 | `InAppMp4Muxer` writes `hvc1` for HEVC | AND-11 |
| V-N14 | `activity`/`concurrent-futures` versions compatible with AGP 9.0.1 + Kotlin 2.3.20 | ENG-08 |
| V-N15 | Android clock band yields export fps above the source rate (frame count). **Yes (AND-01):** 30→60 120/120, 24→48 96/96, 30→50 100/100 frames at a constant step; the repeated source frame is Media3's nearest (adjacent) frame; `fpsUpconversion = true` (§5). | AND-01 |
| V-N16 | Android mechanism meeting the ε source-frame rule at clip starts. **`SNAP_TO_RULE_FRAME` (AND-01):** clip start = PTS of the rule frame read with `MediaExtractorCompat`; 0 mismatches over 7 offsets on plain and B-frame sources in export, 0/9 in the player (§13.3). | AND-01 |
| V-N17 | Media3 `setFrameRate` caps decoded frames of items faster than 1×. **Yes (AND-01):** `EditedMediaItem.setFrameRate(gridFps)` cuts a 4× item's effect calls 240 → 60 in export and ≈ 235 → 56 in the player, barcode exact. | AND-01 |
| V-N18 | Media3 seek semantics (first frame ≥ position vs last ≤ position → `androidSeekMsRounding`), clock-band pts after a seek or scrub (stay within ±1 ms of `P(k)`), and secondary-frame selection policy; with `P(k)`-anchored boundaries the grid-cut barcode case passes 100%. **Answered (AND-01):** Media3 shows the first frame with pts ≥ position → `androidSeekMsRounding = "floor"` (written to `frame_grid.json` by ENG-06, §5); secondary-frame selection is nearest to the primary pts, so gaps are transparent image items at the output fps, never `addGap`; grid-cut export 100% at 24/30/60 fps; on the AND-16 engine playback 0 wrong frames, exact seek 200/200, scrubs 0 wrong, all at pts = `P(k)`. `CompositionPlayer` with `MultipleInputVideoGraph` cannot seek (R1). | AND-01 |
| V-N19 | `setComposition` → first frame latency with 2, 4 and 6 sequences on the 4 GB device; paused secondary-sequence effect change visible through `PausedFrameRenderer`; transient round-trip latency. **Answered (AND-01):** `setComposition` never renders on Media3 1.11.1 (R1 no-go), so the 4 GB-device measurement is moot; the AND-16 replacement budget is in §13.4 (cold rebuild 0.64–4.24 s over 2/4/6 slots). `PausedFrameRenderer` prototype: paused frame reproduced exactly, secondary-sequence tint change visible 20/20, transient round trip p50 5.0–6.8 ms. | AND-01 |
| V-N20 | Real iPhone on iOS 18 and iOS 26: export backgrounded > 30 s (encoder loss −11847 or other), segment resume, `BGTaskScheduler.supportedResources.contains(.gpu)` value. **Partly answered (IOS-01, simulator):** segmented interrupt → resume → passthrough concat is frame-exact (1,200/1,200); `supportedResources.contains(.gpu)` = false on the iPhone 17 Pro simulator, which never suspends a background export. The real-iPhone runs on iOS 18 and 26 are **deferred: no device available** (§14.2). | IOS-01, IOS-13 |
| V-N21 | `MTAudioProcessingTap` on composition audio tracks receives composition-time ranges after `scaleTimeRange` and a gain of 2.0 measures +6.02 ± 0.1 dB in `AVPlayer` and `AVAssetReaderAudioMixOutput`. **Yes, with `.timeDomain` (IOS-01):** +6.0206 dB at 1×/2×/0.5× in the reader and +6.02 dB in `AVPlayer`; range starts are composition time (≤ 0.04 ms), durations inside scaled ranges are not (advance by frames); `.spectral` (and `.varispeed` on iOS 26.5) fail in the reader over scaled ranges (§13.2, §14.2). IOS-18 still closes it in production code. | IOS-01, IOS-18 |
| V-N22 | Whether the Metal CI kernels run on a software (`.useSoftwareRenderer`) `CIContext` at ≥ 0.2× real time (otherwise no software background path). **Runs, identical output (IOS-01):** simulator speed (look 9.7–11.7×, look + blur 2.8–3.0× real time) is not representative; the device speed is **deferred: no device available**, so no software background path is enabled (§14.2). | IOS-01 |
| V-N23 | Preview A/V latency through the Flutter texture path on both platforms, and whether Media3's audio sink can delay audio to compensate. **Measured on simulator/emulator (IOS-01, AND-01):** iOS texture latency exactly one vsync, compensated offset 10–14 ms mean within ≤ 1 frame / ≤ 40 ms; Android audio sink can shift audio (`ForwardingAudioSink` offset), `ImageReader` frames arrive 43–45 ms before release (§12.7). Device and end-to-end numbers: QA-03. | IOS-01, AND-01, QA-03 |
| V-N24 | `EditedMediaItemSequence.Builder(setOf(TRACK_TYPE_VIDEO, TRACK_TYPE_AUDIO))` on an image-only clock band produces a silent AAC track in Transformer output. **Yes (AND-01):** image and video clock bands give a silent `audio/mp4a-latm` 44.1 kHz stereo track; AND-11 keeps `SonicAudioProcessor(48 kHz)`. AND-11 still closes it in production code. | AND-01, AND-11 |
| V-N25 | Six overlay lanes of short, non-overlapping PiP clips: decoder instances, GPU memory and dropped frames before and after packing. **Answered (AND-01):** decoders and prepare time grow with sequences (12 sequences: 13 decoders, 15.1 s prepare; packed into 2 slots: 4 decoders, 2.1 s; export ≈ 5× faster); `addGap` gives black edge frames, transparent-image gaps are exact; tiers set to 2 / 3 / 4 / 6 with the `(instances − 2) / 2` cap (D-14, §12.5). GPU memory deferred to QA-04 (the emulator reports 0). | AND-01 |
| V-A1 | No strongly bound post-15.0 or `NEWLAPACK` symbols in the whisper framework (`check_ios_min_os.sh`) | AI-05 |
| V-A2 | `os_proc_available_memory` availability | AI-06 |
| V-A3 | Metal failure mode in the background | AI-13 |
| V-A4 | A12 vs A13 Metal policy; first Metal init time | QA-06 |
| V-A5 | ggml magic byte order | AI-09 |
| V-A6 | `AVAssetReader.timeRange` / `MediaExtractorCompat` edit-list sample accuracy (clap ±20 ms) | IOS-04, AND-04 |
| V-A7 | Android Auto Backup excludes the editor and speech trees (`bmgr` procedure) | CORE-28, QA-10 |
| V-A8 | NDK CMake 3.22.1 is sufficient | AI-04 |
| V-A9 | Pruned vendor tree builds | AI-01 |
| V-A10 | CJK/Korean CPS defaults | QA-06 |
| V-A11 | Figtree script coverage (fallback for CJK/Arabic/Devanagari burn-in) | API-04 |
| V-A12 | Silero VAD upstream copyright line | UX-42 |
| V-A13 | Required-reason status of ggml's `sysctlbyname`/`clock_gettime` | AI-05 |
| V-A14 | App Review stance on post-install model downloads | INT-05 |
| V-U2 | One texture id backing two `Texture` widgets | UX-18 |
| V-U3 | `PopScope(canPop: false)` disables the iOS edge back-swipe on 3.44 | UX-07 |
| V-U4 | `SemanticsService.announce` vs view-aware announcements on 3.44 | UX-12 |
| V-U5 | iPad hardware-keyboard ⌘ combos reach Flutter (recorded by UX-15 on the iPad simulator; certified by QA-00 scenario 12 in QA-01) | UX-15, QA-01 |
| V-U6 | Fixture regeneration is semantically equivalent across OS updates (barcodes, durations, stream layout), not byte-identical | ENG-05 |

---

## 25. Desktop later (designed now, not built)

1. A new plugin `danaview_editor_engine_desktop` implements `danaview_editor_engine_api`. macOS reuses ≈ 90% of the iOS Swift (AVFoundation, Core Image, Metal) with `sharedDarwinSource: true`; Windows/Linux need their own engines (Media Foundation/GStreamer) against the same RenderPlan contract and parity suite.
2. `MediaAccessPort` uses `DartIoMediaAccess` (`FileLocator`) on desktop; external drops reuse `desktop_drop` as the player does; `findInSameFolder` relink works there.
3. The UI already supports pointer, keyboard, hover, right-click, marquee and the `expanded` layout; the overflow matrix includes macOS pointer runs.
4. Enabling desktop = flip `EditorAvailability.platform` for that OS, add the engine override in `main.dart`, run the parity suite on that engine. No change to the core, plan schema or UI.
5. `danaview_whisper` would add desktop builds (CPU/Metal on macOS) behind the same Dart API; `WhisperSupport` returns `unsupported(platform)` there today.
