# Danaview 1.2.0: Build Plan

> **Release:** Danaview 1.2.0 (app version `1.2.0+N`). **Date:** 2026-10-21. **Baseline:** `editor-wip` @ `c2ee137` (v1.1: 162 of 166 tickets done; 1.2.0 work starts after v1.1 INT-05).
> **Authority:** [`ARCHITECTURE.md`](ARCHITECTURE.md) (this folder, "ARCH") wins over this plan; this plan wins over the four feature plans: the HOM plan ([`files-media-home/FILES_MEDIA_HOME_PLAN.md`](files-media-home/FILES_MEDIA_HOME_PLAN.md)), the AIS plan ([`ai-studio/AI_STUDIO_PLAN.md`](ai-studio/AI_STUDIO_PLAN.md)), the VED plan ([`video-editor-update/VIDEO_EDITOR_UPDATE_PLAN.md`](video-editor-update/VIDEO_EDITOR_UPDATE_PLAN.md)) and the ST plan ([`speed-test/SPEED_TEST_FALLBACK_PLAN.md`](speed-test/SPEED_TEST_FALLBACK_PLAN.md)). "v1.1 ARCH" and "v1.1 BP" are [`../v1.1/editor/ARCHITECTURE.md`](../v1.1/editor/ARCHITECTURE.md) and [`../v1.1/editor/BUILD_PLAN.md`](../v1.1/editor/BUILD_PLAN.md).
> **Size:** **166 tickets** in 7 milestones (N0–N6): 41 HOM, 54 AIS (one conditional: AIS-27), 52 VED, 5 ST, 7 INT-1xx, 7 QA-1xx. 116 run on the Mac, 31 on the Windows laptop (Android lane), 19 need both (a report with one section per platform). Everything ships together; milestones only order the work.
> **AIS tickets** keep their full specs in the AIS plan §5.5 and §7.9; this plan indexes them, places them in the N milestones and lists the amendments the cross-plan resolutions need (§8). **HOM, VED, ST, INT-1xx and QA-1xx** tickets are specified in full in §4.
> **Validation:** the ticket graph was checked by script: every dependency exists (v1.1 ticket ids count as done), the graph is acyclic, every prefix of §3 is dependency-complete, no ticket depends on a later milestone, every HOM, AIS, VED and ST id of the plans is present, and no two tickets own the same path except the register in §5.

---

## 0. Builder rules

### 0.1 How to work a ticket

v1.1 BP §1 applies, with these 1.2.0 additions:

1. **Read first:** ARCH §1–§5 and the sections your ticket cites, the plan section your ticket implements, v1.1 ARCH §1–§4 for editor tickets, and the code your ticket touches (search the repo before changing an interface).
2. **Size:** about 300–1,500 hand-written lines per ticket (generated code, vendored code, fixtures and goldens don't count). Split inside your own owned files if it grows; never spill into files you don't own.
3. **Stay inside Owns.** You may create or edit only the paths in your ticket's **Owns** and files whose header says `// OWNER: <your ticket>` (placeholders from a skeleton ticket). A file from v1.1 or an earlier 1.2.0 ticket may be edited only if your Owns lists it with "(extends <ticket>)"; keep its `// OWNER:` header and add `// EXTENDED: <your ticket>`. Don't change behaviour that existing tests pin unless your Spec says so, and then update those tests. Anything else is a defect report against the owning ticket.
4. **Definition of done** (every ticket):
   - `dart analyze --fatal-infos` / `flutter analyze` clean for every package you touched; dartdoc on public APIs.
   - Every acceptance criterion met with automated tests where testable; device-only criteria recorded in the PR (device, OS, numbers, screenshots).
   - Existing tests stay green: the root `flutter test`, every touched package, native unit tests for native tickets, and **HOM-15's preservation suite** for anything under `danaview_features/lib/src/library/` (ARCH V2-32).
   - The CI script for your area (`scripts/ci/editor/*.sh`, `scripts/ci/v12/*.sh`) passes locally.
   - UI tickets: ARCH §1.4 (custom components, Figtree chrome, dark UI, computed contrast, targets ≥ 44 px) and **no overflow at 280–1280 px and text scale 0.85–1.35** with the `test/support/` SurfaceMatrix helpers for every surface and state you add; semantics labels on every control.
   - Pure-Dart packages stay pure (ARCH rules 9, 16, 20, 24, 25).
   - Nothing logs file names, paths, document or OCR text, labels, landmarks, captions, queries, keys or prompts (ARCH rule 30).
   - Every [VERIFY] your ticket owns (ARCH §15.2) is answered in the PR; integration tickets record the answer in ARCH.
5. **Flags.** `DANAVIEW_FILES_HOME`, `DANAVIEW_PHOTO_EDITOR`, `DANAVIEW_BEAUTY`, `DANAVIEW_AI_STUDIO` (plus v1.1's `DANAVIEW_EDITOR`, `DANAVIEW_AUTO_CAPTIONS`) default to false and are never flipped in code; AIS-41 passes them in release builds. Develop with all of them `=true`.
6. **Platforms.** Home on iOS 15+, Android 24+ (Danaview folders, viewers), macOS, Windows, Linux per ARCH §3; editor, beauty and AI on iOS 15+ and Android 29+ (v1.1 gates). Desktop builds must keep compiling with the editor hidden (v1.1 D-17).
7. **Time.** Frame-grid rules of v1.1 BP §1 rule 7 apply to every editor ticket (stills are one-frame plans at frame 0).
8. **Spikes** (HOM-27, VED-33/33A, AIS-42, AIS-44) start on day 1 in throwaway hosts under `spikes/` with no product dependency, and report before the ticket that freezes their surface (HOM-28 for HOM-27; INT-102 for VED-33; AIS-08 for AIS-42; AIS-45 for AIS-44). Spike code is deleted or kept only as a reference that no product build includes.
9. **Defects found later** become `FIX-<ticket>-<n>` tickets that own exactly the files of the original ticket that need changing (v1.1 BP §1 rule 8).

### 0.2 Ownership rules

- v1.1 BP §2 applies: exclusive ownership; a path ending in `/` is the whole directory; tests are owned explicitly; skeleton tickets create placeholders (`// OWNER: <ticket>`) that only the named owner edits; barrels and package manifests belong to their skeleton ticket; per-feature binding and string files instead of shared ones; commands self-dispatch in their own `part` files.
- **1.2.0 skeletons:** AIS-01 (AI packages, editor registries for AIS), **INT-101** (the five new non-AI packages, new core barrels `lib/photo.dart` and `lib/beauty.dart`, `part` directives for the VED command files, VED registry entries, Home and settings slots, flags), HOM-02 (`danaview_library_native` Pigeon surface and native stubs), HOM-24 (`danaview_pdf` surface), VED-16 (`danaview_face_tracking` surface), INT-102 (RenderPlan v2, Pigeon v2 amendment, native pass registries).
- **Native surfaces freeze** after their skeleton (ARCH V2-25); a later change is a new lead-approved [INTEGRATION] ticket.
- **Integration tickets** ([INTEGRATION]: AIS-01, AIS-24, AIS-37, AIS-41, AIS-43, INT-101…INT-106, INT-102A) are the only tickets that edit files owned elsewhere or app-root files, in the order of §5.
- **Ticket test directories.** Dart tests live in the ticket's owned `test/<topic>/` directories; root app tests under `test/v12/<topic>/`; native tests in one directory per ticket (`darwin/Tests/<Topic>/` or `example/ios/RunnerTests/<Topic>/`, `android/src/test/kotlin/.../<topic>/`, `android/src/androidTest/kotlin/.../<topic>/`).

### 0.3 Two machines, devices and simulators

- **The Mac** builds every Dart, iOS, macOS, integration, QA-report and doc ticket (lane **Mac**), merges the Android lane, and runs CI's self-hosted iOS jobs. It runs **one iOS Simulator at a time** (never two booted simulators; shut one down before booting another), follows the v1.1 simulator notes (tap duration 0.1 s, no parallel tap and screenshot, `flutter attach` for VM evaluation), and **never runs the Android emulator**.
- **The Windows laptop** builds the Android lane (lane **Android**: every `A` ticket, HOM-25, HOM-27, QA-102, and the Android sections of **Mac + Android** tickets) on `editor-android`, with the v1.1 setup (`docs/v1.1/editor/handoff/WINDOWS_SETUP.md`, `ANDROID_LANE.md`): API 35 Pixel 9 Pro XL, API 29 and 34 AVDs, a tablet AVD, local test media only, no Pigeon runs, no edits to `docs/**`, root `pubspec.yaml` or `android/app/**`.
- **Mac + Android tickets** have one report with a Mac section and an Android section; the ticket is done when both sections are green and merged on `editor-wip`. The Android section's code paths are listed under **Owns (Android)**.
- **Gates between machines:** the Mac announces each N0/N1/N3 skeleton or surface ticket (INT-101, HOM-02, HOM-24, VED-16, INT-102) when it lands on `editor-wip`; the Windows lane merges `origin/editor-wip` before starting the dependent `A` ticket.
- **Devices:** the lab iPhone 7 (iOS 15.8), iPhone 8 (iOS 16.7), iPhone SE 2 and the mid-tier iPhone 12 on the Mac; Android devices on Windows when available, otherwise `deferred: no device available` with the emulator result (never faked).

### 0.4 Git

- Mac work lands on `editor-wip`. The Android lane exists as the remote branch `origin/editor-android`; the Mac brings it in with `git merge --no-ff origin/editor-android` and the message `Merge remote-tracking branch 'origin/editor-android' into editor-wip`. Expect merges, not fast-forwards.
- One commit per ticket (or per ticket half on Windows), pushed when done; no AI attribution lines in commit messages (repo rule).
- `.freebuff/` and scratch files never go into commits.

---

## 1. Milestones

| Milestone | Name | Scope | Exit criteria | Tickets |
|---|---|---|---|---|
| **N0** | Foundations and day-1 spikes | AI foundations (AIS-01), cross-plan skeletons, flags and dependency rules (INT-101), library item model and classifier (HOM-01, HOM-16); spikes: Genkit (AIS-42), diarization (AIS-44), Android PDF write path (HOM-27), face mesh/pose/segmentation runtime (VED-33/33A) | Every new package analyzes and tests green with placeholders; architecture tests catch a planted violation of every rule 9–31; flags off leave the app identical to 1.1; four spike reports with go/no-go and size numbers; the owner has answered ARCH §16 Q-N1 and Q-N2 (from VED-33's numbers) | 9 |
| **N1** | Files & Media Home, documents and the speed test | Library database, folders, Recently deleted, photo library, thumbnails, Home tabs with the 1.1 layout preserved, photo viewer and grid, badges, selection bar, filters, organise, import, Open with and the Share Extension, file actions and getting files out, viewers, PDFKit and `PdfRenderer` viewers, Quick Look, PDF page tools, annotate, sign, compress; speed-test fallback | With `DANAVIEW_FILES_HOME=true` on the iOS Simulator (Mac) and Android Emulator (Windows): import a photo, a PDF and a video; organise them in nested Danaview folders; delete and restore; open each in its viewer; merge, annotate, sign and compress a PDF into new files; share and save out; HOM-15 green; the speed test fails over to M-Lab only after consent | 42 |
| **N2** | AI Studio, rich subtitles, speakers and search | AIS S1 (after AIS-01), S2, S3, S4 and S6 except QA: rich cue model, schema 2, commands, SRT/VTT v2, providers and transport, key store, shared AI layer, rendering, word timings, transcript and style UI, timing, karaoke, fonts and presets, AI Studio core, contracts, settings, sheet, review, Ask AI, translation; diarization plugin, pipeline, lanes, lanes UI, cloud diarization; on-device index, search UI, AI search (a) and (b) | AIS plan §5.2 exit criteria of S1–S4 and S6 met against fakes and the loopback provider; no network used by any AI package test; the index answers the search eval set offline | 44 |
| **N3** | Still Photo Mode | RenderPlan v2 and the engine amendment; intent routing; `.dnphoto`; still render, half float, viewport; tone, HSL, curves, crop/keystone, masks, text; still export, presets and batch, EXIF; schema 2 photo and beauty fields; Add to Video Project | A 24 MP photo edits at 60 fps on the mid tier and exports full-resolution JPEG/HEIC (and PNG/WebP where supported) on the iOS Simulator and Android Emulator; Dart reference goldens for every pass; a photo becomes a timeline clip with its recipe | 26 |
| **N4** | Beauty & Retouching Suite | Face tracking plugin and Beauty pack, pre-tracking and `.dnface`, subjects, easing keyframes, the eight categories (face, eyes/brows, nose/lips, skin, makeup, body, filters/bokeh/stickers, tracking/automation), inspector, comparator, presets and auto-enhance | Every beauty parameter renders in Still Photo Mode and on a moving video on both platforms with smoothed landmarks, up to 4 subjects, keyframes, bypass and compare; Dart reference goldens for the landmark-driven passes | 23 |
| **N5** | Integration and QA | AI legal text and app wiring v3 (AIS-36, AIS-37), app wiring v4 (INT-103), editor wiring v4 (INT-105), legal consolidation (INT-106); plan QA (HOM-14, HOM-32, AIS-38, AIS-39, AIS-40, AIS-54, VED-30, VED-31, VED-32) and cross-plan QA (QA-101…QA-106) | Complete feature set wired in the app behind the flags; every plan QA report green; cross-plan E2E green on the iOS Simulator and Android Emulator; network guard and privacy hosts green; §10 budgets met or renegotiated in writing; persistence and backup survival proven | 20 |
| **N6** | Release | Release-candidate regression on lab devices (QA-107); release (AIS-41, widened to all of 1.2.0) | ARCH §1.2 goals evidenced; release checklist complete; release builds pass every flag `=true` | 2 |

## 2. Critical path and lanes

**Longest dependency chain** (16 tickets, by script): AIS-01 → AIS-02 → AIS-03 → AIS-05 → AIS-06 → AIS-28 → AIS-29 → AIS-32 → AIS-37 → INT-103 → INT-105 → VED-30 → VED-32 → QA-101 → QA-107 → AIS-41.

**Lanes that run in parallel** after INT-101:
- **Library lane** (Mac, Dart): HOM-16 → HOM-17 → HOM-19/HOM-20 → HOM-21/HOM-22; HOM-23 → viewers.
- **Home UI lane** (Mac): HOM-02 → HOM-04 → HOM-05 → HOM-06…HOM-13, HOM-18.
- **Documents lane** (Mac + Android): HOM-24 → HOM-26, HOM-28 → HOM-29 → HOM-30, HOM-31; Android HOM-27 (day 1) → HOM-25 → HOM-28A → HOM-29A/30A/31A.
- **Speed test** (Mac, Dart, ~2 days): ST-01 → ST-05, independent.
- **AI core and providers** (Mac): AIS plan §5.3 lanes (core, providers after AIS-42, key store, rendering, transcription, UI, fonts, AI Studio), then diarization (after AIS-44 and AIS-15) and search (after HOM-17 and HOM-19).
- **Photo lane** (Mac + Android): VED-33/33A (day 1) → INT-102/102A → VED-03/03A → VED-04…VED-13 with their `A` halves; VED-15 after AIS-04.
- **Beauty lane** (Mac + Android): VED-16/16A → VED-17/17A → VED-20…VED-25, VED-34 with `A` halves → VED-26 → VED-27, VED-28.
- **Integration** (Mac): INT-101 first; INT-104 in N1 (needed by HOM-21); INT-102 at the start of N3; INT-103, INT-105, INT-106 in N5 in that order.
- **QA:** plan QA tickets after the features they certify; cross-plan QA last. QA tickets change no product code (defects become FIX tickets).

**Android lane order** (Windows): HOM-27, VED-33A (day 1) → HOM-02A → HOM-04A → HOM-20A → HOM-21A, HOM-22A → HOM-25 → HOM-28A → HOM-29A, HOM-31A → HOM-30A; AIS-11, AIS-24, AIS-44, AIS-45, AIS-50 Android sections; INT-102A → VED-03A → VED-04A, VED-05A, VED-06A → VED-09A, VED-10A, VED-29A → VED-13A; VED-16A → VED-17A → VED-20A, VED-23A, VED-25A, VED-34A → VED-21A, VED-22A, VED-24A; Android sections of N5 QA; QA-102.

## 3. Ticket index (dependency-ordered)

Any prefix of this list has all its dependencies satisfied. v1.1 ticket ids (INT-0x, CORE-, API-, ENG-, IOS-, AND-, AI-, UI-, UX-) are done before 1.2.0 starts. "AIS spec" means the full spec is in the AIS plan (§4.1 lists the amendments).

| # | Ticket | Milestone | Lane | Area | Title | Depends on |
|---|---|---|---|---|---|---|
| 1 | **AIS-01** | N0 | Mac | Integration | [INTEGRATION] 1.2.0 AI foundations: packages, placeholders, contracts, dependency rules 9–15, flag, CI (AIS spec) | INT-05, UX-01, INT-01, CORE-01, CORE-09 |
| 2 | **INT-101** | N0 | Mac | Integration | [INTEGRATION] Cross-plan foundations: Home/documents/PDF/face packages, placeholders, flags, rules 20–31, registry additions, CI | AIS-01 |
| 3 | **AIS-42** | N0 | Mac | AI providers | Spike: Genkit Dart 1.0 behind LlmProvider (AIS spec) | AIS-01 |
| 4 | **AIS-44** | N0 | Mac + Android | AI (diarization) | Spike: sherpa-onnx diarization on device (AIS spec) | AIS-01, AI-10 |
| 5 | **HOM-27** | N0 | Android | Documents (native) | Spike: Android PDF write path | INT-101 |
| 6 | **VED-33A** | N0 | Android | Beauty (native) | Spike (Android half): face mesh, pose and segmentation runtime and models | INT-101 |
| 7 | **VED-33** | N0 | Mac | Beauty (native) | Spike: face mesh, pose and segmentation runtime and models (iOS half and report) | INT-101, VED-33A |
| 8 | **HOM-01** | N0 | Mac | Library (Dart) | MediaItem, VideoMediaItem, PhotoMediaItem; MediaRef interop | INT-101 |
| 9 | **HOM-16** | N0 | Mac | Library (Dart) | File model and classifier | HOM-01 |
| 10 | **HOM-17** | N1 | Mac | Library (Dart) | Library database, Danaview folder store, Recently deleted, backup classes | HOM-16 |
| 11 | **HOM-02** | N1 | Mac | Library (native) | danaview_library_native surface and PhotoKit library (iOS, macOS) | HOM-01 |
| 12 | **HOM-02A** | N1 | Android | Library (native) | Android glue and MediaStore library | HOM-02 |
| 13 | **HOM-03** | N1 | Mac | Library (Dart) | Desktop photo directory discovery (macOS, Windows, Linux) | HOM-01 |
| 14 | **HOM-04** | N1 | Mac | Home UI | Thumbnail cache and Apple thumbnailers | HOM-02 |
| 15 | **HOM-04A** | N1 | Android | Library (native) | Android thumbnailers | HOM-04, HOM-02A |
| 16 | **HOM-05** | N1 | Mac | Home UI | Home shell: filter tabs with the 1.1 layout preserved | HOM-04 |
| 17 | **HOM-06** | N1 | Mac | Home UI | Preserve Now Playing, Continue watching, quick actions | HOM-05 |
| 18 | **HOM-07** | N1 | Mac | Home UI | Preserve Playlists | HOM-05 |
| 19 | **HOM-08** | N1 | Mac | Home UI | Preserve Folders | HOM-05 |
| 20 | **HOM-15** | N1 | Mac | QA | Player and library regression suite (merge gate) | HOM-06, HOM-07, HOM-08 |
| 21 | **HOM-09** | N1 | Mac | Home UI | Recent photos tray on Overview | HOM-04, HOM-05 |
| 22 | **HOM-10** | N1 | Mac | Home UI | Photos tab and masonry grid | HOM-04 |
| 23 | **HOM-11** | N1 | Mac | Home UI | Fullscreen photo viewer and EXIF sheet | HOM-10 |
| 24 | **HOM-12** | N1 | Mac | Home UI | Multi-select bar: Make video montage, Play in Player, Add to playlist | HOM-05 |
| 25 | **HOM-13** | N1 | Mac | Home UI | Media badges | HOM-10 |
| 26 | **HOM-18** | N1 | Mac | Home UI | Filters All/Videos/Photos/Documents and the Folders tab | HOM-05, HOM-16, HOM-17 |
| 27 | **HOM-19** | N1 | Mac | Library (Dart) + UI | Favourites, recents, name search, sort | HOM-17 |
| 28 | **HOM-20** | N1 | Mac | Library (Dart + Apple) | Import pipeline and Apple pickers | HOM-17 |
| 29 | **HOM-20A** | N1 | Android | Library (native) | Android pickers | HOM-20, HOM-02A |
| 30 | **INT-104** | N1 | Mac | Integration | [INTEGRATION] Platform declarations: Share Extension target, App Group, document types, intents, backup rules | HOM-17, HOM-20, CORE-28, INT-03 |
| 31 | **HOM-21** | N1 | Mac | Library (Dart + Apple) | Open with Danaview and the iOS Share Extension | HOM-20, INT-104 |
| 32 | **HOM-21A** | N1 | Android | Library (native) | Android incoming intents | HOM-21, HOM-20A |
| 33 | **HOM-22** | N1 | Mac | Library + UI | File actions, multi-select file actions, getting files out (Apple) | HOM-17, HOM-12 |
| 34 | **HOM-22A** | N1 | Android | Library (native) | Android Save to Downloads, share, open with | HOM-22, HOM-02A |
| 35 | **HOM-23** | N1 | Mac | Documents UI | Viewer router, text/CSV viewer, file card | HOM-16 |
| 36 | **HOM-24** | N1 | Mac | Documents (native) | danaview_pdf surface and the PDFKit viewer (iOS, macOS) | HOM-23 |
| 37 | **HOM-25** | N1 | Android | Documents (native) | Android PdfRenderer viewer and text | HOM-24 |
| 38 | **HOM-26** | N1 | Mac | Documents (native) | Quick Look and document thumbnails (iOS, macOS) | HOM-23, HOM-04 |
| 39 | **HOM-28** | N1 | Mac | Documents | PDF page tools: shared organiser UI and PDFKit | HOM-24, HOM-27 |
| 40 | **HOM-28A** | N1 | Android | Documents (native) | Android PDF page tools | HOM-28, HOM-25 |
| 41 | **HOM-29** | N1 | Mac | Documents | Annotate and highlight (PDFKit) | HOM-28 |
| 42 | **HOM-29A** | N1 | Android | Documents (native) | Android annotate and highlight | HOM-29, HOM-28A |
| 43 | **HOM-30** | N1 | Mac | Documents | Sign and saved signatures (PDFKit) | HOM-29 |
| 44 | **HOM-30A** | N1 | Android | Documents (native) | Android sign | HOM-30, HOM-29A |
| 45 | **HOM-31** | N1 | Mac | Documents | Compress (PDFKit) | HOM-28 |
| 46 | **HOM-31A** | N1 | Android | Documents (native) | Android compress | HOM-31, HOM-28A |
| 47 | **ST-01** | N1 | Mac | Speed test | SpeedTestProvider interface and CloudflareSpeedProvider | INT-101 |
| 48 | **ST-02** | N1 | Mac | Speed test | MLabNdt7Provider | ST-01 |
| 49 | **ST-03** | N1 | Mac | Speed test | SpeedTestCoordinator: health check, failover, skip memory, attribution | ST-01, ST-02 |
| 50 | **ST-04** | N1 | Mac | Speed test | Consent prompt, Settings › Privacy toggle, neutral copy | ST-03 |
| 51 | **ST-05** | N1 | Mac | Speed test | Privacy text and store answers for the speed test | ST-04 |
| 52 | **AIS-02** | N2 | Mac | Core (pure Dart) | Rich cue model (AIS spec) | AIS-01, CORE-03, CORE-08 |
| 53 | **AIS-03** | N2 | Mac | Core (pure Dart) | Cue text algebra, markup, emoji scanner (AIS spec) | AIS-02, CORE-07 |
| 54 | **AIS-04** | N2 | Mac | Core (pure Dart) | Project schema 2, codec, s1→s2 (AIS spec) | AIS-02, AIS-03, CORE-22, CORE-23 |
| 55 | **AIS-05** | N2 | Mac | Core (pure Dart) | Span-aware subtitle commands (AIS spec) | AIS-02, AIS-03, CORE-15, CORE-19, CORE-34 |
| 56 | **AIS-06** | N2 | Mac | Core (pure Dart) | AI batch commands, derived tracks, speakers (AIS spec) | AIS-05 |
| 57 | **AIS-07** | N2 | Mac | Core (pure Dart) | SRT/VTT codec v2 (AIS spec) | AIS-03, CORE-20, CORE-33 |
| 58 | **AIS-08** | N2 | Mac | AI providers | Provider contracts and transport (AIS spec) | AIS-01, AIS-42 |
| 59 | **AIS-09** | N2 | Mac | AI providers | OpenAI-compatible, OpenAI, Gemini adapters (AIS spec) | AIS-08 |
| 60 | **AIS-10** | N2 | Mac | AI providers | Anthropic, OpenRouter, xAI adapters (AIS spec) | AIS-09 |
| 61 | **AIS-11** | N2 | Mac + Android | Native | danaview_secure_keys (AIS spec) | AIS-01 |
| 62 | **AIS-43** | N2 | Mac | Integration | [INTEGRATION] Shared danaview_ai and danaview_ai_ui (AIS spec) | AIS-01, AIS-08, INT-101 |
| 63 | **AIS-12** | N2 | Mac | Core (pure Dart) | Text layout spec v2 (AIS spec) | AIS-02, AIS-03, CORE-07 |
| 64 | **AIS-13** | N2 | Mac | Engine (Dart) | Render prep v2 (AIS spec) | AIS-12, API-04 |
| 65 | **AIS-14** | N2 | Mac | Core (pure Dart) | Lowering v2 for cues (AIS spec) | AIS-12, CORE-29, CORE-30, CORE-31 |
| 66 | **AIS-15** | N2 | Mac | AI (transcription) | Word timings on generated cues (AIS spec) | AIS-06, AI-11, AI-13 |
| 67 | **AIS-16** | N2 | Mac | UI/UX | Preview overlay v2, cue placement (AIS spec) | AIS-13, AIS-05, UX-19, UX-22 |
| 68 | **AIS-17** | N2 | Mac | UI/UX | Transcript view and rich cue editor (AIS spec) | AIS-05, UX-31, UX-14 |
| 69 | **AIS-18** | N2 | Mac | UI/UX | Style toolbar, cue section, speakers, emotion (AIS spec) | AIS-17, AIS-16, AIS-06, UX-30 |
| 70 | **AIS-19** | N2 | Mac | UI/UX | Timing tools (AIS spec) | AIS-15, AIS-17, UX-13, UX-21, CORE-18 |
| 71 | **AIS-20** | N2 | Mac | UI/UX | Karaoke settings and emoji tools (AIS spec) | AIS-14, AIS-16, AIS-17, AIS-06 |
| 72 | **AIS-21** | N2 | Mac | UI/UX | Subtitle file options and export labels (AIS spec) | AIS-07, UX-32, UX-39 |
| 73 | **AIS-22** | N2 | Mac | UI/UX | Bundled fonts and FontCatalog v2 (AIS spec) | AIS-13, AIS-14, UX-30 |
| 74 | **AIS-23** | N2 | Mac | Core (pure Dart) | Font inspector, font library, preset store (AIS spec) | AIS-02, CORE-24, CORE-25 |
| 75 | **AIS-24** | N2 | Mac + Android | Integration | [INTEGRATION] Engine font pick kind (AIS spec) | AIS-01, API-01, ENG-03, ENG-06, IOS-15, AND-14 |
| 76 | **AIS-25** | N2 | Mac | UI/UX | Font picker v2 and import (AIS spec) | AIS-22, AIS-23, AIS-24 |
| 77 | **AIS-26** | N2 | Mac | UI/UX | Subtitle style presets (AIS spec) | AIS-23, AIS-18, AIS-13 |
| 78 | **AIS-27** | N2 | Mac | UI/UX | CJK font packs (conditional, AIS spec) | AIS-22, AIS-25, AI-09 |
| 79 | **AIS-28** | N2 | Mac | AI Studio | AI Studio core (AIS spec) | AIS-06, AIS-08, AIS-43, AI-08, AI-12 |
| 80 | **AIS-29** | N2 | Mac | AI Studio | Contracts I (AIS spec) | AIS-28, AIS-03 |
| 81 | **AIS-30** | N2 | Mac | AI Studio | Contracts II: Ask AI, translation (AIS spec) | AIS-28, AIS-15, AI-11 |
| 82 | **AIS-31** | N2 | Mac | UI/UX | AI Studio settings (AIS spec; paths per ARCH V2-20) | AIS-28, AIS-43, UX-04 |
| 83 | **AIS-32** | N2 | Mac | UI/UX | AI Studio sheet and send view (AIS spec; paths per ARCH V2-20) | AIS-29, AIS-31, AIS-43, AIS-17 |
| 84 | **AIS-33** | N2 | Mac | UI/UX | Review mode panel (AIS spec) | AIS-28, AIS-16, AIS-17 |
| 85 | **AIS-34** | N2 | Mac | UI/UX | Ask AI on selection (AIS spec) | AIS-30, AIS-32, AIS-33, AIS-18 |
| 86 | **AIS-35** | N2 | Mac | UI/UX | Translate track flow (AIS spec) | AIS-30, AIS-32, AIS-33 |
| 87 | **AIS-45** | N2 | Mac + Android | Native | danaview_diarization plugin and model download (AIS spec) | AIS-44, AI-09 |
| 88 | **AIS-46** | N2 | Mac | AI (diarization) | Diarization pipeline and overlap cues (AIS spec) | AIS-45, AIS-15 |
| 89 | **AIS-47** | N2 | Mac | Core (pure Dart) | Per-speaker lanes (AIS spec) | AIS-46, AIS-06, AIS-07, AIS-14 |
| 90 | **AIS-48** | N2 | Mac | UI/UX | Speaker lanes UI (AIS spec) | AIS-47, AIS-18 |
| 91 | **AIS-49** | N2 | Mac | AI Studio | Cloud diarization dv.diarize.v1 (AIS spec) | AIS-46, AIS-28, AIS-29 |
| 92 | **AIS-50** | N2 | Mac + Android | Search | On-device search index (AIS spec; search.db per ARCH V2-07) | AIS-01, HOM-16, HOM-17 |
| 93 | **AIS-51** | N2 | Mac | Search | Search engine and Home search UI (AIS spec) | AIS-50, HOM-19 |
| 94 | **AIS-52** | N2 | Mac | Search + AI Studio | AI search (a): query to filters (AIS spec) | AIS-51, AIS-43, AIS-28 |
| 95 | **AIS-53** | N2 | Mac | Search + AI Studio | AI search (b): deep indexing (AIS spec) | AIS-52 |
| 96 | **INT-102** | N3 | Mac | Integration | [INTEGRATION] RenderPlan v2 and engine interface amendment (Dart, Pigeon, iOS glue) | INT-101, VED-33, ENG-06, INT-06, CORE-29 |
| 97 | **INT-102A** | N3 | Android | Integration | [INTEGRATION] RenderPlan v2 Android decode and glue | INT-102 |
| 98 | **VED-01** | N3 | Mac | UI/UX | Intent routing: Still Photo Mode vs timeline | INT-101, UX-07, UX-41 |
| 99 | **VED-02** | N3 | Mac | Core (pure Dart) | .dnphoto model, codec, repository and migrations | VED-01, CORE-22, CORE-24 |
| 100 | **VED-03** | N3 | Mac | Engine (Dart + iOS) | Still plans: lowering, still service, iOS still renderer | VED-02, INT-102, API-03 |
| 101 | **VED-03A** | N3 | Android | Engine (Android) | Android still renderer | VED-03, INT-102A |
| 102 | **VED-04** | N3 | Mac | Engine (iOS) | Half-float and wide-gamut still pipeline (iOS) | VED-03 |
| 103 | **VED-04A** | N3 | Android | Engine (Android) | Half-float still pipeline (Android) | VED-04, VED-03A |
| 104 | **VED-05** | N3 | Mac | UI/UX + iOS | Still viewport: tiles, zoom, pan (Dart UI, iOS tiles) | VED-03 |
| 105 | **VED-05A** | N3 | Android | Engine (Android) | Android tile rendering for the still viewport | VED-05, VED-03A |
| 106 | **VED-06** | N3 | Mac | Core + iOS + UI | Pro tone: tone v2, grain, vignette (core, reference, iOS, panel) | VED-03 |
| 107 | **VED-06A** | N3 | Android | Engine (Android) | Android tone v2 and grain passes | VED-06, VED-03A |
| 108 | **VED-07** | N3 | Mac | Core + UI | 8-band HSL mixer and Target Adjustment Tool (recipe LUT) | VED-06 |
| 109 | **VED-08** | N3 | Mac | Core + UI | Spline RGB and channel curves (recipe LUT) | VED-06 |
| 110 | **VED-09** | N3 | Mac | Core + iOS + UI | Crop, straighten, horizon, keystone (core, iOS homography, panel) | VED-05 |
| 111 | **VED-09A** | N3 | Android | Engine (Android) | Android keystone homography sampling | VED-09, VED-05A |
| 112 | **VED-10** | N3 | Mac | Core + iOS + UI | Selective masks and local adjustments (core, iOS, panel) | VED-06 |
| 113 | **VED-10A** | N3 | Android | Engine (Android) | Android local-adjustment passes | VED-10, VED-06A |
| 114 | **VED-11** | N3 | Mac | UI/UX | Text, stickers, borders in Still Photo Mode | VED-05 |
| 115 | **VED-29** | N3 | Mac | Engine (Dart + iOS) | High-resolution still export (iOS) | VED-04 |
| 116 | **VED-29A** | N3 | Android | Engine (Android) | High-resolution still export (Android) | VED-29, VED-04A |
| 117 | **VED-12** | N3 | Mac | Core + UI | Photo presets, copy/paste, batch export | VED-06, VED-29 |
| 118 | **VED-13** | N3 | Mac | Engine (Dart + iOS) | EXIF/IPTC keep and strip (iOS) | VED-02, VED-29 |
| 119 | **VED-13A** | N3 | Android | Engine (Android) | EXIF keep and strip (Android) | VED-13, VED-29A |
| 120 | **VED-15** | N3 | Mac | Core (pure Dart) | Schema 2 additions: photo recipe on image clips, BeautyEffectSpec, easing key | CORE-03, VED-02, AIS-04, INT-102 |
| 121 | **VED-14** | N3 | Mac | Core + UI | Add to Video Project, montage sequence, Ken Burns | VED-02, VED-15, CORE-13 |
| 122 | **VED-16** | N4 | Mac | Beauty (native) | danaview_face_tracking surface, iOS trackers, One-Euro, Beauty pack | VED-33, INT-101 |
| 123 | **VED-16A** | N4 | Android | Beauty (native) | Android trackers and glue | VED-16 |
| 124 | **VED-17** | N4 | Mac | Beauty (Dart + iOS) | Background pre-tracking and .dnface cache (iOS sampling) | VED-16, VED-15 |
| 125 | **VED-17A** | N4 | Android | Beauty (native) | Android video sampling for pre-tracking | VED-17, VED-16A |
| 126 | **VED-18** | N4 | Mac | Core (pure Dart) | Multi-subject detection and Face IDs | VED-17 |
| 127 | **VED-19** | N4 | Mac | Core (pure Dart) | Keyframes and easing for beauty and all properties | VED-15, CORE-19 |
| 128 | **VED-20** | N4 | Mac | Beauty (core + iOS) | Face shape and slimming | VED-17, INT-102 |
| 129 | **VED-20A** | N4 | Android | Beauty (Android) | Face shape and slimming (Android) | VED-20, VED-17A, INT-102A |
| 130 | **VED-21** | N4 | Mac | Beauty (core + iOS) | Eyes and eyebrows | VED-20 |
| 131 | **VED-21A** | N4 | Android | Beauty (Android) | Eyes and eyebrows (Android) | VED-21, VED-20A |
| 132 | **VED-22** | N4 | Mac | Beauty (core + iOS) | Nose and lips | VED-20 |
| 133 | **VED-22A** | N4 | Android | Beauty (Android) | Nose and lips (Android) | VED-22, VED-20A |
| 134 | **VED-23** | N4 | Mac | Beauty (core + iOS) | Skin retouching and teeth | VED-17, INT-102 |
| 135 | **VED-23A** | N4 | Android | Beauty (Android) | Skin retouching and teeth (Android) | VED-23, VED-17A, INT-102A |
| 136 | **VED-24** | N4 | Mac | Beauty (core + iOS) | Virtual makeup and appearance (incl. hair colour) | VED-23 |
| 137 | **VED-24A** | N4 | Android | Beauty (Android) | Virtual makeup and appearance (Android) | VED-24, VED-23A |
| 138 | **VED-25** | N4 | Mac | Beauty (core + iOS) | Body reshaping | VED-17, INT-102 |
| 139 | **VED-25A** | N4 | Android | Beauty (Android) | Body reshaping (Android) | VED-25, VED-17A, INT-102A |
| 140 | **VED-34** | N4 | Mac | Beauty (core + iOS) | Beauty filters, portrait bokeh, face-anchored stickers | VED-17, VED-11, INT-102 |
| 141 | **VED-34A** | N4 | Android | Beauty (Android) | Portrait bokeh (Android) | VED-34, VED-17A, INT-102A |
| 142 | **VED-26** | N4 | Mac | UI/UX | Beauty & Retouching inspector, bypass, tier defaults | VED-15, VED-18, VED-19, UX-16 |
| 143 | **VED-27** | N4 | Mac | UI/UX | Split before/after comparator | VED-26, CORE-32 |
| 144 | **VED-28** | N4 | Mac | Core + UI | Beauty presets, copy/paste attributes, automatic enhancement | VED-26 |
| 145 | **AIS-36** | N5 | Mac | UI/UX | Privacy, terms, licences for AI (AIS spec; after ST-05) | UX-42, ST-05 |
| 146 | **AIS-37** | N5 | Mac | Integration | [INTEGRATION] App wiring v3: AI (AIS spec; adapters per ARCH V2-24) | AIS-09, AIS-10, AIS-11, AIS-25, AIS-28, AIS-31, AIS-32, AIS-36, AIS-43, INT-04 |
| 147 | **INT-103** | N5 | Mac | Integration | [INTEGRATION] App wiring v4: search, AI search, /settings/ai, settings sections | AIS-37, AIS-51, AIS-52, AIS-53, ST-04, HOM-19 |
| 148 | **INT-105** | N5 | Mac | Integration | [INTEGRATION] Editor wiring v4: Home bridges, photo and montage intents, face tracking and library adapters | INT-103, VED-01, VED-12, VED-14, VED-17, VED-28, HOM-11, HOM-12, HOM-22 |
| 149 | **INT-106** | N5 | Mac | Integration | [INTEGRATION] Privacy, terms and licences consolidation for 1.2.0 | AIS-36, INT-105, HOM-21, HOM-30, VED-13, VED-16, AIS-45 |
| 150 | **HOM-14** | N5 | Mac + Android | QA | Stress: 50,000-item Home scroll | HOM-10, HOM-18, HOM-04A |
| 151 | **HOM-32** | N5 | Mac + Android | QA | Documents test pass | HOM-18, HOM-19, HOM-20A, HOM-21A, HOM-22A, HOM-25, HOM-26, HOM-29A, HOM-30A, HOM-31A, HOM-15, INT-104 |
| 152 | **AIS-38** | N5 | Mac + Android | QA | On-device E2E, AI Studio and rich subtitles (AIS spec) | AIS-37, AIS-19, AIS-20, AIS-21, AIS-26, AIS-33, AIS-34, AIS-35 |
| 153 | **AIS-39** | N5 | Mac + Android | QA | Render parity and budgets, rich text (AIS spec) | AIS-37, AIS-14, AIS-16, AIS-22, AIS-25 |
| 154 | **AIS-40** | N5 | Mac + Android | QA | Live provider validation (AIS spec) | AIS-37 |
| 155 | **AIS-54** | N5 | Mac + Android | QA | Diarization and search QA (AIS spec) | AIS-48, AIS-49, AIS-53, AIS-37 |
| 156 | **VED-30** | N5 | Mac + Android | QA | 4K export with full beauty (iOS, Android) | VED-15, VED-21A, VED-22A, VED-24A, VED-25A, VED-34A, VED-28, INT-105, IOS-12, AND-11 |
| 157 | **VED-31** | N5 | Mac + Android | QA | Memory stress: 48 MP and 100 MP stills on low-RAM devices | VED-05A, VED-29A, VED-12, VED-13A |
| 158 | **VED-32** | N5 | Mac + Android | QA | Golden parity: Still Photo Mode vs timeline, iOS vs Android | VED-29A, VED-30, VED-14, VED-27 |
| 159 | **QA-101** | N5 | Mac | QA | iOS Simulator E2E for 1.2.0 and the 1.1 suite re-run | INT-105, INT-106, HOM-32, AIS-38, AIS-54, VED-32 |
| 160 | **QA-102** | N5 | Android | QA | Android Emulator E2E for 1.2.0 and the 1.1 suite re-run | INT-105, INT-106, HOM-32, AIS-38, AIS-54, VED-32 |
| 161 | **QA-103** | N5 | Mac + Android | QA | Whole-app network guard and privacy-host consistency | INT-105, INT-106, AIS-54, ST-03 |
| 162 | **QA-104** | N5 | Mac + Android | QA | Performance and memory budgets on the device lab | HOM-14, VED-31, VED-30, AIS-39, INT-105 |
| 163 | **QA-105** | N5 | Mac + Android | QA | Overflow and accessibility matrix for every new surface | INT-105, HOM-32, VED-28, ST-04 |
| 164 | **QA-106** | N5 | Mac + Android | QA | Persistence, migration, originals and backup survival | INT-105, INT-104, VED-15, VED-19, AIS-47, HOM-17 |
| 165 | **QA-107** | N6 | Mac + Android | QA | Release-candidate regression on lab devices (player preservation, 1.1 and 1.2 smoke) | QA-101, QA-102, QA-103, QA-104, QA-105, QA-106, AIS-40 |
| 166 | **AIS-41** | N6 | Mac | Integration | [INTEGRATION] Release 1.2.0 (AIS spec, widened: every flag, every plan) | AIS-38, AIS-39, AIS-40, AIS-36, AIS-37, AIS-54, QA-107, INT-106 |
