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

---

## 4. Tickets

Conventions: **Owns (Mac)** and **Owns (Android)** split the paths by machine. Package paths are relative to the repo root; `lib/` inside a ticket's package means that package's `lib/`. `LN/` abbreviates `packages/danaview_library_native/`, `PDF/` abbreviates `packages/danaview_pdf/`, `DOC/` abbreviates `packages/danaview_documents/`, `FEAT/` abbreviates `packages/danaview_features/lib/src/`, `CORE/` abbreviates `packages/danaview_editor_core/`, `API/` abbreviates `packages/danaview_editor_engine_api/`, `ENGP/` abbreviates `packages/danaview_editor_engine/`, `ED/` abbreviates `packages/danaview_editor/lib/src/`, `FACE/` abbreviates `packages/danaview_face_tracking/`. Android Kotlin roots: `LN/android/src/main/kotlin/com/vecvel/danaview/library/` = `LNK/`, `PDF/android/src/main/kotlin/com/vecvel/danaview/pdf/` = `PDFK/`, `ENGP/android/src/main/kotlin/com/vecvel/danaview/editor/engine/` = `ENGK/`, `FACE/android/src/main/kotlin/com/vecvel/danaview/face/` = `FACEK/`.

### 4.1 AIS tickets: placement and amendments

The 54 AIS tickets keep the specs of AIS plan §5.5 and §7.9. Their milestones in this plan: AIS-01, AIS-42, AIS-44 → N0; AIS-02…AIS-35, AIS-43, AIS-45…AIS-53 → N2; AIS-36…AIS-40, AIS-54 → N5; AIS-41 → N6. These amendments apply (ARCH §14 gives the reasons):

| Ticket | Amendment |
|---|---|
| AIS-01 | Records decisions and status in `docs/v1.2/ARCHITECTURE.md` (V2-33), not v1.1 ARCH. Otherwise unchanged; INT-101 extends its registry, barrel-part and CI edits afterwards (§5). |
| AIS-04 | Schema 2 is the **only** 1.2.0 schema (V2-03): pin the lane keys (AIS-47) and reserve `ph`, `bt` and keyframe `e` for VED-15; add 1.1.x-decoder fixtures proving unknown keys survive read-only open (V2-V17). |
| AIS-11 | Mac + Android: the Android Keystore half is committed by the Windows lane under `packages/danaview_secure_keys/android/`. |
| AIS-24 | Mac + Android: the Android picker half (`ENGP/android/.../MediaPicker.kt`) by the Windows lane; Pigeon regeneration on the Mac only. |
| AIS-31, AIS-32 | Own the moved paths (V2-20): `packages/danaview_ai_ui/lib/src/settings/` (AIS-31) and `packages/danaview_ai_ui/lib/src/{ai_send_view,ai_progress_panel,ai_failure_copy}.dart` (AIS-32); the editor-side files `ED/editor/flows/ai/{ai_studio_sheet,ai_studio_controller}.dart` stay with AIS-32; the route is `/settings/ai` (wired by AIS-37). |
| AIS-36 | Depends on ST-05 (legal text order ST-05 → AIS-36 → INT-106); AIS §6.4's "Added 2026-10-16" bullets move to INT-106. |
| AIS-37 | Adapters live at the app root (V2-24): `lib/adapters/{secure_key_store_adapter,engine_ai_audio_extractor,prefs_usage_ledger}.dart` replace the `ED/app/adapters/` paths; `editor_bootstrap.dart` stays (extends INT-02). Route `/settings/ai` with a row in Settings › Video editor. |
| AIS-38, AIS-39, AIS-40, AIS-54 | Mac + Android: Android Emulator runs belong to the Windows lane; the report is one file with two sections. |
| AIS-41 | Widened to the whole 1.2.0 release: passes every flag of ARCH V2-04, depends on QA-107 and INT-106, records install sizes (ARCH §10.3) and status in `docs/v1.2/ARCHITECTURE.md`; adds one pointer line to v1.1 ARCH's header. |
| AIS-43 | Depends on INT-101 (rules 16–19 go into the test after rules 20–31 exist); extends `packages/danaview_editor/pubspec.yaml` (after AIS-01) to add `danaview_ai`, `danaview_ai_ui`; no `editor.ai.enabled` migration (V2-20). |
| AIS-44, AIS-45, AIS-50 | Mac + Android as the AIS plan's lane notes say; AIS-50's index lives in `search.db` (V2-07), and `packages/danaview_search/` is created by INT-101 (skeleton) so AIS-50 owns `lib/src/index/` only, as written. |
| AIS-51 | Extends `FEAT/library/search/library_search_field.dart` (after HOM-19); the "Search with AI" entry calls an `onSearchWithAi` callback that INT-103 wires (ARCH rule 23). |
| AIS-52 | Extends `packages/danaview_search/pubspec.yaml` (after INT-101) to add `danaview_ai`; the chip in `FEAT/library/search/ai_search_chip.dart`, the flow at the app root through INT-103. |

### 4.2 Files & Media Home (HOM)

#### HOM-01 · MediaItem, VideoMediaItem, PhotoMediaItem; MediaRef interop

- **Milestone:** N0 · **Lane:** Mac · **Area:** Library (Dart)
- **Depends on:** INT-101
- **Owns (Mac):** `packages/danaview_library/lib/src/model/{media_item,media_ref_bridge,ids}.dart`, `packages/danaview_library/test/model/`
- **Spec:** ARCH §5.1 and V2-09. Sealed `MediaItem` with `VideoMediaItem`, `PhotoMediaItem` (and the `DocumentItem` slot HOM-16 fills); id namespaces `fe_`, `fd_`, `lk:`, `ph:`, `ms:` as extension types with parsing and validation; `VideoMediaItem.toMediaRef()` and `MediaRefBridge.fromMediaRef()` so `danaviewPlayItems(ref, items)`, `LibraryController` and the player keep receiving `MediaRef` unchanged (HOM §4.1). Equality and hashing by id.
- **Acceptance criteria and tests:** round trip `MediaRef → VideoMediaItem → MediaRef` equal for every field `MediaRef` has; id parsing rejects malformed ids; package purity (rule 20) green; no `danaview_domain` file changes.

#### HOM-16 · File model and classifier

- **Milestone:** N0 · **Lane:** Mac · **Area:** Library (Dart)
- **Depends on:** HOM-01
- **Owns (Mac):** `packages/danaview_library/lib/src/model/{file_entry,file_kind,document_item,source_hint}.dart`, `packages/danaview_library/lib/src/classify/`, `packages/danaview_library/test/classify/`
- **Spec:** ARCH §5.1, V2-114. `FileEntry`, `FileKind` (open, append-only; unknown → `other`), `DocumentItem`, `SourceHint`. `classify/type_table.dart` is the single table of HOM §8.1 rows; `classify(uti?, mime?, fileName)` applies UTType → MIME → extension, deferring on generic types (`public.data`, `application/octet-stream`).
- **Acceptance criteria and tests:** one test per table row and per sub-filter; conflicting inputs resolved as specified; a `savedCode` kind string decodes to `other` without loss of the raw string.

#### HOM-17 · Library database, Danaview folder store, Recently deleted, backup classes

- **Milestone:** N1 · **Lane:** Mac · **Area:** Library (Dart)
- **Depends on:** HOM-16
- **Owns (Mac):** `packages/danaview_library/lib/src/{db,store,refs}/`, `packages/danaview_library/test/{db,store,refs}/`, `FEAT/library/files/library_store_providers.dart`, `FEAT/more/settings_sections/library_storage_section.dart`, `test/v12/library_storage/`
- **Spec:** ARCH V2-06, V2-08, §5.2–§5.4. `library.db` schema v1 and migrations framework; one writer isolate (WAL, transactions per multi-row change); paged read-only queries; `LibraryFs` (the only writer under the root: id directories, atomic renames, `imports/` part files); folder tree (create, rename, move, nest any depth, cycle check), entries, favourites, recents (50, trigger), `refs` for editor holders; Recently deleted (`trashed_at`, `expires_at`, subtree delete in one transaction, restore to the original folder or `Imported`, Empty now, sweep on launch and daily); invariants check on open and rebuild-from-files recovery (`library.db.corrupt-<date>`, `Recovered` folder); backup classes: Apple `isExcludedFromBackup` on `imports/` only via the port the native plugin provides (`BackupFlagPort`, stub until HOM-02), Android rules are INT-104's. The settings section shows library size, Recently deleted size and, on Android, the plain Auto Backup note (V2-V1).
- **Acceptance criteria and tests:** 1,000 seeded random operation sequences keep every invariant and match an in-memory model; a deleted file restores to its folder; a deleted folder restores its subtree; restore into a vanished folder lands in `Imported`; with a fake clock an item older than 30 days is purged and a clock set backwards doesn't change `expires_at`; Empty now removes everything; a crash injected at every step of move, delete and import leaves the database and files consistent; 200-row page query ≤ 2 ms on the mid tier (benchmark recorded).

#### HOM-02 · danaview_library_native surface and PhotoKit library (iOS, macOS)

- **Milestone:** N1 · **Lane:** Mac · **Area:** Library (native)
- **Depends on:** HOM-01
- **Owns (Mac):** `LN/pigeons/library_api.dart`, `LN/lib/src/pigeon/`, `LN/lib/src/native_photo_library.dart`, `LN/darwin/danaview_library_native.podspec`, `LN/darwin/Classes/{Glue,PhotoLibrary}/`, `LN/darwin/Tests/PhotoLibrary/`, `LN/android/src/main/kotlin/com/vecvel/danaview/library/pigeon/` (generated only), `FEAT/library/sources/system_photos_source.dart`
- **Spec:** ARCH V2-25, §8. The **whole** Pigeon surface of the plugin, frozen after this ticket: `PhotoLibraryApi` (authorization state, request, limited-library picker, paged fetch with change tokens, asset metadata, change events), `PickerApi`, `ThumbnailApi` (`mediaThumbnail`, `documentThumbnail`), `ExportOutApi`, `ShareApi`, `OpenInApi`, `QuickLookApi`, `InboxApi`, `IncomingApi`, `BackupFlagApi`; generated Dart, Swift and Kotlin; darwin glue routing each API to a class; stubs returning `notSupportedOnDevice` for every class owned by later tickets (placeholders with `// OWNER:`). PhotoKit implementation: `PHFetchResult` paging, `PHPhotoLibraryChangeObserver` → change events (V2-111), limited access honoured, metadata (RAW/HDR/Live flags, EXIF basics). `system_photos_source.dart` maps assets to `PhotoMediaItem`/`VideoMediaItem` with `ph:` ids. Closes the Apple half of V2-V2 (HEIC, AVIF, RAW, Live).
- **Acceptance criteria and tests:** XCTest on the simulator with a seeded photo library (`xcrun simctl addmedia`): paging, change events on add/delete, limited access; macOS build and test; generated files committed; every stub returns `notSupportedOnDevice`; no socket API in the plugin (rule 21 grep).

#### HOM-02A · Android glue and MediaStore library

- **Milestone:** N1 · **Lane:** Android · **Area:** Library (native)
- **Depends on:** HOM-02
- **Owns (Android):** `LN/android/build.gradle.kts`, `LN/android/src/main/AndroidManifest.xml`, `LNK/{glue,photolibrary}/`, stubs in `LNK/{pickers,thumbnails,exportout,share,openin,incoming}/` (placeholders for their owners), `LN/android/src/test/kotlin/com/vecvel/danaview/library/photolibrary/`, `LN/android/src/androidTest/kotlin/com/vecvel/danaview/library/photolibrary/`
- **Spec:** Kotlin glue for the frozen surface; MediaStore paging (`query` with `LIMIT/OFFSET` bundles on 11+), `ContentObserver` change events, `READ_MEDIA_IMAGES`/`READ_MEDIA_VIDEO` and `READ_MEDIA_VISUAL_USER_SELECTED` (14+) partial access, legacy `READ_EXTERNAL_STORAGE` on API ≤ 32 declared with `maxSdkVersion`; `ms:` ids. Closes the Android half of V2-V2.
- **Acceptance criteria and tests:** JVM tests for cursor mapping; emulator tests on API 35 and 29 with seeded media: paging, change events, partial access; Gradle builds the example; lint clean.

#### HOM-03 · Desktop photo directory discovery

- **Milestone:** N1 · **Lane:** Mac · **Area:** Library (Dart)
- **Depends on:** HOM-01
- **Owns (Mac):** `packages/danaview_library/lib/src/desktop/`, `packages/danaview_library/test/desktop/`, `FEAT/library/sources/desktop_photos_source.dart`, `FEAT/library/desktop/`
- **Spec:** V2-109. Pictures folders (macOS `~/Pictures` outside the Photos library package, Windows Known Folder Pictures via environment, XDG `PICTURES`), external volumes (`/Volumes`, mounted drives, `/media`, `/run/media`), incremental rescan by modification time, read-only (rule 27); sidebar shortcuts and drag-and-drop targets (P-8 unchanged). macOS PhotoKit comes from HOM-02. ARCH rule 20 allows `dart:io` in `lib/src/desktop/` (INT-101 records it).
- **Acceptance criteria and tests:** fixture directory trees scanned with correct kinds; symlink loops ignored; a removed drive disappears without errors; Windows and Linux compile in CI; no write call on any scanned path (test with a read-only temp tree).

#### HOM-04 · Thumbnail cache and Apple thumbnailers

- **Milestone:** N1 · **Lane:** Mac · **Area:** Home UI
- **Depends on:** HOM-02
- **Owns (Mac):** `FEAT/library/thumbs/`, `LN/lib/src/native_thumbnails.dart`, `LN/darwin/Classes/Thumbnails/`, `LN/darwin/Tests/Thumbnails/`, `test/v12/thumbs/`
- **Spec:** V2-28, V2-104. Memory LRU 64 MB (byte-accounted), disk cache under `<cache>/danaview/library/thumbs/` keyed by item id + modification time + size class (S/M/L), backup-excluded; request coalescing and cancellation when cells leave the viewport; Apple: `PHCachingImageManager` for `ph:` assets, `QLThumbnailGenerator` for files (photos and videos; documents come from HOM-26), JPEG (HEIC on iOS 17+) encode; closes V2-V3 (no WebP encoder).
- **Acceptance criteria and tests:** memory never exceeds 64 MB under a 10,000-cell fling (test with fake decoder); cache survives restart and is invalidated by modification time; visible-cell miss ≤ 120 ms on the mid tier for a 12 MP HEIC (recorded); XCTests for both thumbnail paths.

#### HOM-04A · Android thumbnailers

- **Milestone:** N1 · **Lane:** Android · **Area:** Library (native)
- **Depends on:** HOM-04, HOM-02A
- **Owns (Android):** `LNK/thumbnails/`, `LN/android/src/test/kotlin/com/vecvel/danaview/library/thumbnails/`, `LN/android/src/androidTest/kotlin/com/vecvel/danaview/library/thumbnails/`
- **Spec:** `ContentResolver.loadThumbnail` (29+), `ThumbnailUtils` and `MediaMetadataRetriever` for files, `PdfRenderer` first page for PDFs in `documentThumbnail`, WebP lossy encode at the requested size class.
- **Acceptance criteria and tests:** emulator tests for images, videos and PDFs on API 35 and 29; a corrupt file yields a typed failure, not a crash.

#### HOM-05 · Home shell: filter tabs with the 1.1 layout preserved

- **Milestone:** N1 · **Lane:** Mac · **Area:** Home UI
- **Depends on:** HOM-04
- **Owns (Mac):** `FEAT/library/danaview_home_screen.dart` (extends v1.0), `FEAT/library/home/`, `test/v12/home_shell/`
- **Spec:** V2-101, V2-32. With `DANAVIEW_FILES_HOME=false` the file renders exactly the 1.1 tree. With it on: a kit tab strip (`Home`, `All`, `Videos`, `Photos`, `Documents`, `Playlists`, `Folders`, plus `Projects` where the editor runs) over a tab host; the `Home` tab hosts the 1.1 sections unchanged (Now Playing, quick actions, Continue watching, playlists, folders) plus slots for the Recent photos tray (HOM-09) and favourites row (HOM-19). `home/home_callbacks.dart` declares every optional callback later wiring needs (`onEditPhoto`, `onBatchEditPhotos`, `onMakeMontage`, `onOpenProjects`, `onSearchWithAi`, `onOpenAiSettings`), all nullable so the app compiles before INT-103/INT-105. Creates placeholders (owned elsewhere) for `FEAT/library/tabs/*.dart`, `home/recent_photos_tray.dart`, `selection/selection_bar.dart`.
- **Acceptance criteria and tests:** flag off: the 1.1 `test/home_screen_test.dart` and HOM-06…HOM-08 goldens unchanged; flag on: every tab reachable by tap and keyboard; matrix 280–1280 px × 0.85–1.35 with no overflow; semantics labels on tabs; desktop builds show no editor tab.

#### HOM-06 · Preserve Now Playing, Continue watching, quick actions

- **Milestone:** N1 · **Lane:** Mac · **Area:** Home UI
- **Depends on:** HOM-05
- **Owns (Mac):** `test/home_screen_test.dart` (extends v1.0), `test/v12/preservation/hub/`
- **Spec:** P-1, P-2, P-3. Behaviour and golden tests with the flag off and on: Now Playing card return-to-player, Continue watching progress, episode badges, Clear history, Show all N, the item menu (Play, Add to playlist…, Remove from history), Open file / Open folder / Open link (all protocols of P-7 in the link dialog).
- **Acceptance criteria and tests:** goldens identical between flag off and the `Home` tab with flag on (pixel-equal at three widths); every callback receives the same `MediaRef` as in 1.1.

#### HOM-07 · Preserve Playlists

- **Milestone:** N1 · **Lane:** Mac · **Area:** Home UI
- **Depends on:** HOM-05
- **Owns (Mac):** `test/v12/preservation/playlists/`
- **Spec:** P-4, P-6: New playlist, rename, delete, drag-reorder, shuffle, Play all, add-to-playlist sheets, queue integration and repeat modes, flag off and on.
- **Acceptance criteria and tests:** behaviour tests and goldens as HOM-06.

#### HOM-08 · Preserve Folders

- **Milestone:** N1 · **Lane:** Mac · **Area:** Home UI
- **Depends on:** HOM-05
- **Owns (Mac):** `test/v12/preservation/folders/`
- **Spec:** P-5, P-8: device storage root, user-added folders, breadcrumbs, natural sort, Play all, Shuffle, Add to queue, desktop drop and `danaview://` links, flag off and on; the Folders tab shows them under "Linked folders" unchanged.
- **Acceptance criteria and tests:** behaviour tests and goldens as HOM-06.

#### HOM-15 · Player and library regression suite (merge gate)

- **Milestone:** N1 · **Lane:** Mac · **Area:** QA
- **Depends on:** HOM-06, HOM-07, HOM-08
- **Owns (Mac):** `test/v12/preservation/suite_test.dart`, `scripts/ci/v12/home_preservation.sh`
- **Spec:** V2-32. One entry point running the 1.1 Home, player, playlist, queue, library and incoming-media tests plus HOM-06…HOM-08 with the flag off and on; INT-101's CI job calls the script on every PR touching `FEAT/library/**`, `packages/danaview_platform/**` or `packages/danaview_library*/**`.
- **Acceptance criteria and tests:** suite green on `editor-wip`; a planted regression (a changed Continue watching label) fails it.

#### HOM-09 · Recent photos tray on Overview

- **Milestone:** N1 · **Lane:** Mac · **Area:** Home UI
- **Depends on:** HOM-04, HOM-05
- **Owns (Mac):** `FEAT/library/home/recent_photos_tray.dart`, `test/v12/recent_photos/`
- **Spec:** HOM §2 item 6: horizontal carousel of the latest photos from Danaview folders and (if allowed, Q-N8) the system library; See all opens the Photos tab; tap opens the viewer (HOM-11); hidden when there are none.
- **Acceptance criteria and tests:** widget tests for empty, few, many; matrix; tray absent when the flag is off.

#### HOM-10 · Photos tab and masonry grid

- **Milestone:** N1 · **Lane:** Mac · **Area:** Home UI
- **Depends on:** HOM-04
- **Owns (Mac):** `FEAT/library/tabs/photos_tab.dart`, `FEAT/library/photos/`, `test/v12/photos_tab/`
- **Spec:** V2-102, V2-108. Virtualized masonry grid (fixed-aspect buckets so layout is O(visible)), date grouping (Today, Yesterday, This month, months), album chips (Danaview folders, Favourites, and system albums when the system library is shown), "Show my photo library" opt-in row (Q-N8 default), pinch to change density.
- **Acceptance criteria and tests:** layout of 50,000 synthetic items computes visible ranges in ≤ 1 ms; scroll position restored across tab switches; matrix.

#### HOM-11 · Fullscreen photo viewer and EXIF sheet

- **Milestone:** N1 · **Lane:** Mac · **Area:** Home UI
- **Depends on:** HOM-10
- **Owns (Mac):** `FEAT/library/photo_viewer/`, `test/v12/photo_viewer/`
- **Spec:** V2-106. Pinch and double-tap zoom, swipe between items, info sheet (EXIF date, camera, lens, exposure, dimensions, size, source), Live Photo indicator; toolbar: Share, Favourite, Delete, File info, and **Edit** that calls `onEditPhoto` (shown only when the callback is set and the editor runs, ARCH §3).
- **Acceptance criteria and tests:** gestures and toolbar in widget tests; Edit hidden with a null callback and on desktop; RAW and HEIC display on the simulator.

#### HOM-12 · Multi-select bar: Make video montage, Play in Player, Add to playlist

- **Milestone:** N1 · **Lane:** Mac · **Area:** Home UI
- **Depends on:** HOM-05
- **Owns (Mac):** `FEAT/library/selection/` (except `file_actions.dart`), `test/v12/selection/`
- **Spec:** V2-107 (Q-H2 default). Selection model across tabs (tap to toggle, drag-select, select all in group); the bar takes **action groups** from providers so HOM-22 adds file actions without editing this ticket's files; media group: Make video montage (calls `onMakeMontage`), Batch edit photos (calls `onBatchEditPhotos`), Play in Player (queues `MediaRef`s; photos per V2-V4: shown with libmpv `image-display-duration` if verified, else skipped with a notice), Add to playlist (videos).
- **Acceptance criteria and tests:** bar shows the right groups for photos-only, videos-only, mixed and documents selections; callbacks receive items in selection order; closes V2-V4 on iOS and records the Android result.

#### HOM-13 · Media badges

- **Milestone:** N1 · **Lane:** Mac · **Area:** Home UI
- **Depends on:** HOM-10
- **Owns (Mac):** `FEAT/library/badges/`, `test/v12/badges/`
- **Spec:** V2-110: duration pill, 4K/1080p, frame rate (≥ 50), RAW, HDR, Live; computed contrast on thumbnails (scrim).
- **Acceptance criteria and tests:** goldens per badge combination; contrast ≥ 4.5:1 computed over light and dark thumbnails.

#### HOM-18 · Filters All/Videos/Photos/Documents and the Folders tab

- **Milestone:** N1 · **Lane:** Mac · **Area:** Home UI
- **Depends on:** HOM-05, HOM-16, HOM-17
- **Owns (Mac):** `FEAT/library/tabs/{all_tab,videos_tab,documents_tab,folders_tab}.dart`, `FEAT/library/filters/`, `FEAT/library/folders/`, `test/v12/filters/`, `test/v12/folders_tab/`
- **Spec:** V2-114, V2-115, HOM §5.2. `All` (chronological, every kind), `Videos` (Now Playing, Continue watching, playlists, video folders, grid with badges), `Documents` with sub-filter chips and rows (type icon or first-page thumbnail, name, size, date, page count), `Folders` with two groups: **Danaview folders** (browse, create, rename, move, nest, Recently deleted view with days left, Restore, Empty now) and **Linked folders** (the 1.1 browser unchanged, read-only for documents).
- **Acceptance criteria and tests:** each filter shows exactly the classifier's kinds over a fixture library; folder operations call HOM-17 and update in one frame; Recently deleted rows show correct days left with a fake clock; linked-folder files offer no rename/move/delete; HOM-15 green.

#### HOM-19 · Favourites, recents, name search, sort

- **Milestone:** N1 · **Lane:** Mac · **Area:** Library (Dart) + UI
- **Depends on:** HOM-17
- **Owns (Mac):** `packages/danaview_library/lib/src/organise/`, `packages/danaview_library/test/organise/`, `FEAT/library/organise/`, `FEAT/library/search/{library_search_field,name_search_controller}.dart`, `test/v12/organise/`
- **Spec:** V2-119. Favourites (files and folders; Overview row; chip), recents (last 50 opened in any viewer; Clear; never synced), as-you-type name search over names, folder names and types across Danaview folders, linked folders and (if shown) the system library, with a hook (`SearchBackend`) that AIS-51 replaces by the index when enabled; sort by name (natural, the 1.1 `natural_sort.dart`), date added, date modified, size, type, ascending or descending, remembered per folder.
- **Acceptance criteria and tests:** first results ≤ 50 ms per keystroke over 50,000 names on the mid tier (benchmark); sort stable and remembered; recents capped at 50; trashed items never appear.

#### HOM-20 · Import pipeline and Apple pickers

- **Milestone:** N1 · **Lane:** Mac · **Area:** Library (Dart + Apple)
- **Depends on:** HOM-17
- **Owns (Mac):** `packages/danaview_library/lib/src/import/`, `packages/danaview_library/test/import/`, `LN/lib/src/native_pickers.dart`, `LN/darwin/Classes/Pickers/`, `LN/darwin/Tests/Pickers/`, `FEAT/library/import/`, `test/v12/import/`
- **Spec:** V2-116, ARCH §5.6. `ImportService` (queue, read-only source open, streamed copy into `imports/<job>.part`, progress, resume after kill while the source is readable, duplicate rules, fsync + rename + one transaction, `sourceHint`), Apple pickers (`PHPickerViewController` with `.current` representation and no library permission, `UIDocumentPickerViewController` import mode multiple, macOS `NSOpenPanel`), desktop `file_selector`; import sheet with folder choice (default `Imported`) and progress rows.
- **Acceptance criteria and tests:** the source file's bytes and timestamps are unchanged after import (test); kill at 50 % and relaunch resumes from `bytes_done`; duplicates suffixed or skipped as chosen; a 2 GB import keeps memory flat; XCTests for picker result mapping.

#### HOM-20A · Android pickers

- **Milestone:** N1 · **Lane:** Android · **Area:** Library (native)
- **Depends on:** HOM-20, HOM-02A
- **Owns (Android):** `LNK/pickers/`, `LN/android/src/test/kotlin/com/vecvel/danaview/library/pickers/`, `LN/android/src/androidTest/kotlin/com/vecvel/danaview/library/pickers/`
- **Spec:** Photo Picker `ACTION_PICK_IMAGES` (multiple, back-ported through Play services where available, `ACTION_OPEN_DOCUMENT` image/video fallback), SAF `ACTION_OPEN_DOCUMENT` multiple with read-only `openFileDescriptor(uri, "r")`; no persisted grants needed (imports copy).
- **Acceptance criteria and tests:** emulator tests on API 35 and 29 importing an image, a PDF and a video; the source URI is never opened for writing (instrumented check).

#### HOM-21 · Open with Danaview and the iOS Share Extension

- **Milestone:** N1 · **Lane:** Mac · **Area:** Library (Dart + Apple)
- **Depends on:** HOM-20, INT-104
- **Owns (Mac):** `packages/danaview_library/lib/src/inbox/`, `packages/danaview_library/test/inbox/`, `LN/lib/src/native_inbox.dart`, `LN/darwin/Classes/Inbox/`, `LN/darwin/Tests/Inbox/`, `ios/DanaviewShare/` (extension sources: `ShareViewController.swift`, `FolderPickerView.swift`, `InboxWriter.swift`, `Info.plist`), `packages/danaview_platform/lib/src/incoming_media_bridge.dart` (extends v1.0), `FEAT/player/danaview_player_actions.dart` (extends v1.0), `test/v12/incoming/`
- **Spec:** V2-116, ARCH §5.6 (owner 2026-10-16). Incoming documents and photos (Open with, `danaview://` unchanged) are imported into `Imported` and opened in their viewer; incoming videos still play at once (P-7, P-8); player menu "Save to Danaview folder". Share Extension: folder picker (reads a folder list snapshot the app writes into the App Group, never `library.db`), streamed copy into `Inbox/<batchId>/` with `manifest.json` written last, close; `InboxImporter` on launch and foreground; stale incomplete batches deleted after 24 h. Closes V2-V8.
- **Acceptance criteria and tests:** sharing a photo, a PDF and a 2 GB video from Photos and Files on the simulator lands each in the chosen folder; the extension stays under its memory limit (Instruments recorded); an interrupted share leaves no half-imported entry; a video opened from another app plays at once as in 1.1.

#### HOM-21A · Android incoming intents

- **Milestone:** N1 · **Lane:** Android · **Area:** Library (native)
- **Depends on:** HOM-21, HOM-20A
- **Owns (Android):** `LNK/incoming/`, `LN/lib/src/native_incoming.dart`, `LN/android/src/test/kotlin/com/vecvel/danaview/library/incoming/`, `LN/android/src/androidTest/kotlin/com/vecvel/danaview/library/incoming/`
- **Spec:** `ACTION_VIEW`, `ACTION_SEND`, `ACTION_SEND_MULTIPLE` handled in the plugin through `ActivityAware` and `addOnNewIntentListener` (no `MainActivity` edit); the manifest filters are INT-104's; video intents keep the 1.1 path (handed to `incoming_media_bridge` unchanged).
- **Acceptance criteria and tests:** emulator: share a PDF and two images from Files, open a PDF with Danaview, open a video (plays at once); cold-start and warm-start intents both handled once.

#### HOM-22 · File actions, multi-select file actions, getting files out (Apple)

- **Milestone:** N1 · **Lane:** Mac · **Area:** Library + UI
- **Depends on:** HOM-17, HOM-12
- **Owns (Mac):** `packages/danaview_library/lib/src/actions/`, `packages/danaview_library/test/actions/`, `LN/lib/src/native_{export_out,share,open_in}.dart`, `LN/darwin/Classes/{ExportOut,Share,OpenIn}/`, `LN/darwin/Tests/{ExportOut,Share,OpenIn}/`, `FEAT/library/file_actions/`, `FEAT/library/selection/file_actions.dart`, `test/v12/file_actions/`
- **Spec:** V2-117, V2-118. Single-file menu (Share, Copy to…, Move to…, Rename, File info, Open in another app, Favourite, Delete with the "Used in N projects" warning, V2-08); multi-select file group (Share, Move, Copy, Favourite, Delete, Save out; "Merge into PDF" when only PDFs/images, routed to HOM-28); Save to Files (`forExporting:`), share sheet (`UIActivityViewController`, `NSSharingServicePicker`), Open in (`UIDocumentInteractionController`, `NSWorkspace`), Save to Photos (add-only) for media; desktop save dialogs. Shared copies are temporary read-only copies.
- **Acceptance criteria and tests:** every action updates the database and UI; Save to Files writes a copy and never moves the library file; share hands a temporary copy that is cleaned up; the delete warning shows for a referenced entry; XCTests for each native path.

#### HOM-22A · Android Save to Downloads, share, open with

- **Milestone:** N1 · **Lane:** Android · **Area:** Library (native)
- **Depends on:** HOM-22, HOM-02A
- **Owns (Android):** `LNK/{exportout,share,openin}/`, `LN/android/src/main/res/xml/library_file_paths.xml`, `LN/android/src/main/AndroidManifest.xml` (extends HOM-02A: the plugin's `FileProvider`), `LN/android/src/test/kotlin/com/vecvel/danaview/library/{exportout,share,openin}/`, `LN/android/src/androidTest/kotlin/com/vecvel/danaview/library/{exportout,share,openin}/`
- **Spec:** `MediaStore.Downloads` with `IS_PENDING` (29+; the editor floor), `ACTION_CREATE_DOCUMENT` below that for the Home on API 24–28, MediaStore `Pictures`/`Movies` for media, `ACTION_SEND(_MULTIPLE)` and `ACTION_VIEW` with read-only `FileProvider` grants on temporary copies.
- **Acceptance criteria and tests:** emulator API 35, 29 and an API 28 AVD for the Home-only path: each action works with no storage permission; grants are read-only.

#### HOM-23 · Viewer router, text/CSV viewer, file card

- **Milestone:** N1 · **Lane:** Mac · **Area:** Documents UI
- **Depends on:** HOM-16
- **Owns (Mac):** `DOC/lib/src/{router,text,card}/`, `DOC/test/{router,text,card}/`
- **Spec:** V2-120, V2-121, HOM §8.4. Router by kind and platform (ARCH §3 table) with capability probes; in-app text viewer (UTF-8, UTF-16 by BOM, Latin-1 fallback with a change-encoding menu, virtualized lines, 50 MB cap with "Open in another app"); CSV/TSV read-only grid (delimiter sniffing, fixed header); file card (icon, name, size, dates, Open in another app, Share). Recents updated on open.
- **Acceptance criteria and tests:** a 50 MB log scrolls at the grid budget; encoding fixtures decode; CSV with `,`, `;` and tab; router picks the right viewer per platform in tests; matrix.

#### HOM-24 · danaview_pdf surface and the PDFKit viewer (iOS, macOS)

- **Milestone:** N1 · **Lane:** Mac · **Area:** Documents (native)
- **Depends on:** HOM-23
- **Owns (Mac):** `PDF/pigeons/pdf_api.dart`, `PDF/lib/src/pigeon/`, `PDF/lib/src/{pdf_document,pdf_view,pdf_text}.dart`, `PDF/darwin/danaview_pdf.podspec`, `PDF/darwin/Classes/{Glue,Viewer,Text}/`, `PDF/darwin/Tests/Viewer/`, `PDF/android/src/main/kotlin/com/vecvel/danaview/pdf/pigeon/` (generated only), `DOC/lib/src/pdf/viewer/`, `DOC/test/pdf/viewer/`
- **Spec:** V2-120, V2-123, ARCH V2-25. The whole plugin surface, frozen after this ticket: `PdfDocumentApi` (open with optional password, page count, page sizes, outline, close), `PdfViewApi` (platform view: zoom, page thumbnails, search, selection, go to page), `PdfTextApi` (`extractText(range)` for the search index), `PdfToolsApi` (merge, split, reorder, rotate, delete, annotate, sign, compress, all writing new files with progress and cancel), stubs for tool classes. PDFKit viewer: `PDFView` in a `UiKitView`/`AppKitView`, password prompt (kit sheet), outline, search with result list, text selection and copy; read-only open (rule 27).
- **Acceptance criteria and tests:** first page ≤ 500 ms for a 200-page fixture on the mid tier; search finds fixture strings; password PDF opens after the prompt; XCTests; macOS build.

#### HOM-25 · Android PdfRenderer viewer and text

- **Milestone:** N1 · **Lane:** Android · **Area:** Documents (native)
- **Depends on:** HOM-24
- **Owns (Android):** `PDF/android/build.gradle.kts`, `PDF/android/src/main/AndroidManifest.xml`, `PDFK/{glue,viewer,text}/`, stubs in `PDFK/{tools,annotate,sign,compress}/`, `PDF/android/src/test/kotlin/com/vecvel/danaview/pdf/viewer/`, `PDF/android/src/androidTest/kotlin/com/vecvel/danaview/pdf/viewer/`
- **Spec:** `PdfRenderer` tiled rendering into a `TextureRegistry` surface, zoom and page thumbnails; text search and selection where the platform offers them (newer `PdfRenderer` APIs, `androidx.pdf`), else hidden; password files → file card where unsupported; `extractText` where available. Closes V2-V5.
- **Acceptance criteria and tests:** emulator API 35 and 29: render, zoom, thumbnails; a support table per API level for search, selection and passwords in the PR; no crash on damaged fixtures.

#### HOM-26 · Quick Look and document thumbnails (iOS, macOS)

- **Milestone:** N1 · **Lane:** Mac · **Area:** Documents (native)
- **Depends on:** HOM-23, HOM-04
- **Owns (Mac):** `LN/lib/src/native_quick_look.dart`, `LN/darwin/Classes/QuickLook/`, `LN/darwin/Tests/QuickLook/`, `DOC/lib/src/quicklook/`, `DOC/test/quicklook/`
- **Spec:** V2-120: `QLPreviewController` (iOS) / `QLPreviewView` (macOS) for Office, text, CSV and other types, **editing disabled** (`previewController(_:editingModeFor:)` → `.disabled`); `documentThumbnail` through `QLThumbnailGenerator` into the HOM-04 cache; falls back to the file card when Quick Look can't preview.
- **Acceptance criteria and tests:** docx, xlsx, pptx, txt, csv and an unknown type previewed or carded; a Markup attempt cannot change the stored file (bytes compared); thumbnails cached.

#### HOM-27 · Spike: Android PDF write path

- **Milestone:** N0 · **Lane:** Android · **Area:** Documents (native)
- **Depends on:** INT-101
- **Owns (Android):** `spikes/android_pdf/` (including `spikes/android_pdf/REPORT.md`)
- **Spec:** V2-123 (owner 2026-10-16). Compare (a) platform + Jetpack (`PdfRenderer` editing additions on 15+, `androidx.pdf`, page images as the fallback on older versions), (b) PdfBox-Android, (c) PDFium for merge, split, reorder, rotate, delete, annotate, stamp and compress, on generated fixtures. Criteria: text stays selectable, AAB size per ABI, minimum API, timings on a 200-page file, licence. Route (a) is the default; (b) or (c) only if the report shows (a) turns text into pictures on supported versions. Runs on day 1; no product dependency. HOM-28 (Mac) copies the report and the decision into `docs/v1.2/files-media-home/spikes/HOM-27-android-pdf-write.md` (the Windows lane doesn't edit `docs/`).
- **Acceptance criteria and tests:** a report with pass/fail per criterion and route, numbers, and a recommendation; closes V2-V6 once HOM-28 records it.

#### HOM-28 · PDF page tools: shared organiser UI and PDFKit

- **Milestone:** N1 · **Lane:** Mac · **Area:** Documents
- **Depends on:** HOM-24, HOM-27
- **Owns (Mac):** `PDF/lib/src/pdf_tools.dart`, `PDF/darwin/Classes/Tools/`, `PDF/darwin/Tests/Tools/`, `DOC/lib/src/pdf/organiser/`, `DOC/test/pdf/organiser/`, `docs/v1.2/files-media-home/spikes/HOM-27-android-pdf-write.md`
- **Spec:** V2-123, HOM §8.5. Page organiser (drag thumbnails, select, rotate 90°, delete, extract), merge (2+ PDFs and images, ordered), split (ranges, every N pages, extract selected), all off the UI thread with progress and cancel; results saved as new files next to the original (`Report (edited).pdf`) or **Replace** inside a Danaview folder only (write new, then rename over); PDFKit `insert`, `exchangePage`, `removePage`, `rotation`, `write(to:)`. Records HOM-27's decision.
- **Acceptance criteria and tests:** text stays selectable after every operation (PDFKit text extraction compared); 200-page merge ≤ 10 s on the mid tier; cancel leaves no partial file; the original is unchanged (bytes).

#### HOM-28A · Android PDF page tools

- **Milestone:** N1 · **Lane:** Android · **Area:** Documents (native)
- **Depends on:** HOM-28, HOM-25
- **Owns (Android):** `PDFK/tools/`, `PDF/android/build.gradle.kts` (extends HOM-25: the HOM-27 library only if chosen), `PDF/android/LICENSE-THIRD-PARTY.md` (only if a library is chosen), `PDF/android/src/test/kotlin/com/vecvel/danaview/pdf/tools/`, `PDF/android/src/androidTest/kotlin/com/vecvel/danaview/pdf/tools/`
- **Spec:** the HOM-27 route for merge, split, reorder, rotate, delete; same new-file and Replace rules; progress and cancel.
- **Acceptance criteria and tests:** as HOM-28 on the emulator (API 35 and 29), with the text-preservation result per API level in the PR.

#### HOM-29 · Annotate and highlight (PDFKit)

- **Milestone:** N1 · **Lane:** Mac · **Area:** Documents
- **Depends on:** HOM-28
- **Owns (Mac):** `PDF/darwin/Classes/Annotate/`, `PDF/darwin/Tests/Annotate/`, `DOC/lib/src/pdf/annotate/`, `DOC/test/pdf/annotate/`
- **Spec:** highlight, underline, strike-through on selected text, freehand ink (PencilKit on iPad, kit drawing elsewhere), text notes; colour and width; undo/redo in the tool; saved into a new file (or Replace in a Danaview folder).
- **Acceptance criteria and tests:** annotations survive reopen in PDFKit and in a second reader (fixture check of annotation dictionaries); undo/redo; matrix.

#### HOM-29A · Android annotate and highlight

- **Milestone:** N1 · **Lane:** Android · **Area:** Documents (native)
- **Depends on:** HOM-29, HOM-28A
- **Owns (Android):** `PDFK/annotate/`, `PDF/android/src/test/kotlin/com/vecvel/danaview/pdf/annotate/`, `PDF/android/src/androidTest/kotlin/com/vecvel/danaview/pdf/annotate/`
- **Spec:** the same tool set on the HOM-27 route.
- **Acceptance criteria and tests:** as HOM-29 on the emulator.

#### HOM-30 · Sign and saved signatures (PDFKit)

- **Milestone:** N1 · **Lane:** Mac · **Area:** Documents
- **Depends on:** HOM-29
- **Owns (Mac):** `PDF/darwin/Classes/Sign/`, `PDF/darwin/Tests/Sign/`, `DOC/lib/src/{pdf/sign,signatures}/`, `DOC/test/{pdf/sign,signatures}/`
- **Spec:** V2-29. Draw, type (content font) or import a signature; saved signatures in the backup-excluded store (ARCH §5.2), deletable; place, resize, rotate on a page; burned into the page content on save (visual signature, not a certificate). Closes the Apple half of V2-V7.
- **Acceptance criteria and tests:** the burned signature renders in a second reader and is not an editable annotation; saved signatures are excluded from backup (flag checked); deleting removes the file.

#### HOM-30A · Android sign

- **Milestone:** N1 · **Lane:** Android · **Area:** Documents (native)
- **Depends on:** HOM-30, HOM-29A
- **Owns (Android):** `PDFK/sign/`, `PDF/android/src/test/kotlin/com/vecvel/danaview/pdf/sign/`, `PDF/android/src/androidTest/kotlin/com/vecvel/danaview/pdf/sign/`
- **Spec:** burn-in on the HOM-27 route; signatures in `noBackupFilesDir/signatures/` (path supplied by Dart).
- **Acceptance criteria and tests:** as HOM-30 on the emulator.

#### HOM-31 · Compress (PDFKit)

- **Milestone:** N1 · **Lane:** Mac · **Area:** Documents
- **Depends on:** HOM-28
- **Owns (Mac):** `PDF/darwin/Classes/Compress/`, `PDF/darwin/Tests/Compress/`, `DOC/lib/src/pdf/compress/`, `DOC/test/pdf/compress/`
- **Spec:** presets High / Medium / Small (image downsampling and JPEG quality through `write(to:withOptions:)` on iOS 16+ / macOS 13+, page re-render fallback below), before/after size, cancellable progress, new file. Closes V2-V7's compression half.
- **Acceptance criteria and tests:** each preset shrinks an image-heavy fixture and keeps text selectable; sizes shown match the written file.

#### HOM-31A · Android compress

- **Milestone:** N1 · **Lane:** Android · **Area:** Documents (native)
- **Depends on:** HOM-31, HOM-28A
- **Owns (Android):** `PDFK/compress/`, `PDF/android/src/test/kotlin/com/vecvel/danaview/pdf/compress/`, `PDF/android/src/androidTest/kotlin/com/vecvel/danaview/pdf/compress/`
- **Spec:** the same presets on the HOM-27 route.
- **Acceptance criteria and tests:** as HOM-31 on the emulator.

#### HOM-14 · Stress: 50,000-item Home scroll

- **Milestone:** N5 · **Lane:** Mac + Android · **Area:** QA
- **Depends on:** HOM-10, HOM-18, HOM-04A
- **Owns (Mac):** `integration_test/v12/home_stress/`, `tool/v12/make_library_fixture.dart`, `docs/v1.2/files-media-home/qa/HOM-14-stress.md`; **(Android):** the Android section's run (no files beyond the report section the Mac merges from the lane's notes)
- **Spec:** G-H2, ARCH §10.1. A generated library of 50,000 mixed items (Danaview folders) and a 10,000-document set; fling and drag scripts on every tab; frame timings, memory and thumbnail cache behaviour recorded on the simulator, the emulator and the device lab.
- **Acceptance criteria and tests:** the §10.1 Home budgets met (or renegotiated in writing) on the mid tier; no frame > 2× budget in a 10 s fling more than twice.

#### HOM-32 · Documents test pass

- **Milestone:** N5 · **Lane:** Mac + Android · **Area:** QA
- **Depends on:** HOM-18, HOM-19, HOM-20A, HOM-21A, HOM-22A, HOM-25, HOM-26, HOM-29A, HOM-30A, HOM-31A, HOM-15, INT-104
- **Owns (Mac):** `integration_test/v12/documents/`, `scripts/ci/v12/documents_e2e.sh`, `docs/v1.2/files-media-home/qa/HOM-32-documents.md`
- **Spec:** HOM-32 of the plan: originals never modified across import, viewers and every PDF tool (bytes and timestamps); backup and restore of Danaview folders on a test device (iOS device backup; Android device-to-device transfer); 10,000-file library scroll and search timings; a11y labels and text scale 0.85–1.35 on every new screen; a full re-run of HOM-15.
- **Acceptance criteria and tests:** every scenario passes on the iOS Simulator and the Android Emulator with evidence; backup results recorded per platform (closes V2-V1 with QA-106).
