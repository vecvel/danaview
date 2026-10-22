# Danaview 1.2.0: Build Plan

> **Release:** Danaview 1.2.0 is a development milestone, not a store version. **Owner decision 2026-10-22:** nothing has been released to production yet, so the app version stays **`1.0.0+1`** in every 1.1, 1.2 and 1.3 build and candidate; the first store release ships as 1.0.0 (build 1, or the next free build number only if a store already holds an uploaded build 1). **Date:** 2026-10-21. **Baseline:** `editor-wip` @ `c2ee137` (v1.1: 162 of 166 tickets done; 1.2.0 work starts once v1.1 is code-complete; INT-05 itself stays waiting for the owner's go, and AIS-01's INT-05 dependency means "v1.1 code-complete").
> **Authority:** [`ARCHITECTURE.md`](ARCHITECTURE.md) (this folder, "ARCH") wins over this plan; this plan wins over the four feature plans: the HOM plan ([`files-media-home/FILES_MEDIA_HOME_PLAN.md`](files-media-home/FILES_MEDIA_HOME_PLAN.md)), the AIS plan ([`ai-studio/AI_STUDIO_PLAN.md`](ai-studio/AI_STUDIO_PLAN.md)), the VED plan ([`video-editor-update/VIDEO_EDITOR_UPDATE_PLAN.md`](video-editor-update/VIDEO_EDITOR_UPDATE_PLAN.md)) and the ST plan ([`speed-test/SPEED_TEST_FALLBACK_PLAN.md`](speed-test/SPEED_TEST_FALLBACK_PLAN.md)). "v1.1 ARCH" and "v1.1 BP" are [`../v1.1/editor/ARCHITECTURE.md`](../v1.1/editor/ARCHITECTURE.md) and [`../v1.1/editor/BUILD_PLAN.md`](../v1.1/editor/BUILD_PLAN.md).
> **Size:** **166 tickets** in 7 milestones (N0–N6): 41 HOM, 54 AIS (one conditional: AIS-27), 52 VED, 5 ST, 7 INT-1xx, 7 QA-1xx. 116 run on the Mac, 31 on the Windows laptop (Android lane), 19 need both (a report with one section per platform). **Delivery is by release slice (§1A, owner decision 2026-10-22):** nine slices S1–S9, each ending in a production-ready release-candidate build; the N milestones below only describe the content.
> **AIS tickets** keep their full specs in the AIS plan §5.5 and §7.9; this plan indexes them, places them in the N milestones and lists the amendments the cross-plan resolutions need (§4.1, §8). **HOM, VED, ST, INT-1xx and QA-1xx** tickets are specified in full in §4.
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

- 1.2.0 Mac work lands on **`v1.2-wip`** (cut from `editor-wip` @ `d680bd3`), so v1.1's QA re-runs keep testing a frozen `editor-wip`. Late v1.1 fixes land on `editor-wip` and are merged forward into `v1.2-wip` (`git merge --no-ff editor-wip`), never the other way until 1.1 ships.
- The 1.2.0 Android lane works on the remote branch **`origin/v1.2-android`** (cut from `origin/v1.2-wip`); the Mac brings it in with `git merge --no-ff origin/v1.2-android` and the message `Merge remote-tracking branch 'origin/v1.2-android' into v1.2-wip`. `editor-android` stays the v1.1 lane. Expect merges, not fast-forwards.
- Where this plan says `editor-wip` for 1.2.0 work, read `v1.2-wip`.
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

## 1A. Release slices (delivery order)

Owner decision 2026-10-22: 1.2.0 is built and certified **slice by slice**, so a complete, production-ready build appears often instead of once at the end. The N milestones of §1 describe the content; **this section decides the order and the release gates**, and wins over §1 where they differ.

**Every slice ends with three gate tickets** (lane Mac + Android), and a slice is done only when all three are green:

- **S<n>-W · Wiring and legal for the slice.** Wire exactly the slice's features into the app behind their flag (the slice's share of INT-103, INT-105 and AIS-37), add its privacy, terms and licence text (its share of AIS-36 and INT-106), store-answer deltas, and the flag set of the slice's release build. No feature work.
- **S<n>-Q · Slice QA.** Plan QA for the slice's features (its share of HOM-14, HOM-32, AIS-38…40, AIS-54, VED-30…32), the iOS Simulator E2E (Mac) and Android Emulator E2E (Windows) for the new scenarios, **the full v1.1 suite (QA-01/QA-02 scenarios) re-run with the slice's flags on and off**, the network guard (QA-103 scope for the slice), the overflow and accessibility matrix for its new surfaces (QA-105 scope), and persistence of anything it stores (QA-106 scope). Report in `docs/v1.2/qa/S<n>-QA.md`. QA changes no product code; defects become FIX tickets that block the gate.
- **S<n>-R · Release candidate.** Release builds of iOS and Android at version `1.0.0+1` (never bumped; see the header) with **only the flags of S1…S<n> on**, the release checklist for the slice, and an install-and-smoke on the iOS Simulator and Android Emulator (lab devices when available, recorded as `deferred: no device available` otherwise). The owner decides whether a candidate goes to TestFlight / Play internal testing or to the stores; by default candidates stay internal until the owner's go (v1.1 goes live after v1.3).

Flags of later slices stay off in every candidate, so each candidate is the previous one plus one finished slice. A slice may start building while the previous slice is in its gate, but it lands on `v1.2-wip` only behind its own flag (off).

| Slice | Name | User-visible result | Feature tickets | Flag(s) on at S<n>-R |
|---|---|---|---|---|
| **S1** | Foundations + speed test | The app is identical to 1.1 except that the speed test fails over to M-Lab (after consent) when Cloudflare is unavailable, with the Settings › Privacy toggle | AIS-01, INT-101, HOM-01, HOM-16, ST-01…ST-05. **In parallel, not gating S1:** spikes AIS-42, AIS-44, HOM-27, VED-33A, VED-33 (reports with go/no-go and sizes; they gate the slices that need them) | none new (ST is consent-gated, no flag) |
| **S2** | Photos & Files Home | Home with All/Videos/Photos tabs and the 1.1 layout preserved, photo grid and viewer with EXIF, badges, selection bar, favourites/recents/search/sort, import, Danaview folders and Recently deleted, file actions and saving out | HOM-17, HOM-02, HOM-02A, HOM-03, HOM-04, HOM-04A, HOM-05…HOM-13, HOM-15, HOM-18 (Documents tab hidden until S3), HOM-19, HOM-20, HOM-20A, HOM-22, HOM-22A | `DANAVIEW_FILES_HOME` |
| **S3** | Documents: view and share-in | Documents tab, viewer router, text/CSV, PDF viewers (PDFKit, `PdfRenderer`), Quick Look and document thumbnails, Open with Danaview and the iOS Share Extension, Android incoming intents | HOM-23, HOM-24, HOM-25, HOM-26, INT-104, HOM-21, HOM-21A | `DANAVIEW_FILES_HOME` (Documents tab shown) |
| **S4** | Documents: PDF tools | Merge and organise pages, annotate and highlight, sign with saved signatures, compress, each into a new file | HOM-28, HOM-28A, HOM-29, HOM-29A, HOM-30, HOM-30A, HOM-31, HOM-31A (needs the HOM-27 spike) | same |
| **S5** | Rich subtitles (on-device) | Styled captions with spans, word timings, karaoke, timing tools, emoji, fonts and presets, SRT/VTT v2; no cloud | AIS-02…AIS-07, AIS-12…AIS-27 except the cloud-only parts; AIS-11 if S6 is next | `DANAVIEW_AUTO_CAPTIONS` extended (rich subtitles), `DANAVIEW_AI_STUDIO` off |
| **S6** | AI Studio + speakers | Bring-your-own-key providers, AI Studio sheet, review, Ask AI on selection, translation, on-device and cloud multi-speaker transcripts with speaker lanes | AIS-08, AIS-09, AIS-10, AIS-11, AIS-43, AIS-28…AIS-35, AIS-45…AIS-49 (needs AIS-42 and AIS-44); AIS-40 live validation in its gate | `DANAVIEW_AI_STUDIO` |
| **S7** | Search | On-device index, Home search UI, AI search (query to filters, deep indexing) | AIS-50, AIS-51, AIS-52, AIS-53 | same flags as S6 |
| **S8** | Still Photo Mode | Photo editor: tone, HSL, curves, crop/keystone, masks, text and stickers, high-resolution export, presets and batch, EXIF keep/strip, Add to Video Project | INT-102, INT-102A, VED-01…VED-15, VED-29, VED-29A (needs VED-33) | `DANAVIEW_PHOTO_EDITOR` |
| **S9** | Beauty & Retouching | Face tracking and the eight beauty categories on stills and video, inspector, comparator, presets, auto-enhance | VED-16…VED-28, VED-34 with their `A` halves | `DANAVIEW_BEAUTY` |

**After S9:** the cross-plan tickets shrink to a final consolidation: QA-101/QA-102 (the whole-app E2E with every flag on), QA-104 (device-lab budgets), QA-107 (release-candidate regression on lab devices) and AIS-41 (release 1.2.0 with every flag). The rest of N5 is consumed by the slice gates.

**S1 exit criteria:** flags off (and S1's build) leave the app identical to 1.1, proven by the full v1.1 suite on the iOS Simulator and the Android Emulator; architecture tests catch a planted violation of every rule 9–31; `SpeedTestProvider` moved Cloudflare with no behaviour change; failover to M-Lab only after consent, with the toggle off meaning Cloudflare only; neutral copy with no provider names in the result screen beyond the attribution ST-03 requires; privacy text and store answers updated; signed iOS and Android candidates installed and smoked.

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

### 4.3 Unified Photo & Video Editor (VED)

#### VED-33A · Spike (Android half): face mesh, pose and segmentation runtime and models

- **Milestone:** N0 · **Lane:** Android · **Area:** Beauty (native)
- **Depends on:** INT-101
- **Owns (Android):** `spikes/face_android/` (including `REPORT.md`)
- **Spec:** ARCH V2-13, V2-14. On Android, run the candidate runtimes (MediaPipe Tasks Vision, LiteRT/TFLite with the same `.task`/`.tflite` models, ONNX Runtime with converted models) for the face landmarker (478 points), pose landmarker (33 points), person and hair segmentation on the V2-31 face fixtures: AAB size per ABI, model sizes and licences, latency per frame at 720p and 1080p on the emulator and any available device, landmark output dumps for parity with iOS.
- **Acceptance criteria and tests:** report with numbers per candidate and the landmark dumps committed under the spike; no product code.

#### VED-33 · Spike: face mesh, pose and segmentation runtime and models (iOS half and report)

- **Milestone:** N0 · **Lane:** Mac · **Area:** Beauty (native)
- **Depends on:** INT-101, VED-33A
- **Owns (Mac):** `spikes/face_ios/`, `docs/v1.2/video-editor-update/spikes/VED-33-face-runtime.md`, `docs/v1.2/video-editor-update/qa/face_fixtures.md`, `CORE/test/fixtures/faces/`
- **Spec:** the iOS half of VED-33A's comparison (MediaPipe Tasks iOS, Core ML conversion, ONNX Runtime; Apple Vision for rectangles), IPA size growth, the shared-runtime question with AIS-44 (V2-V18), cross-platform landmark difference on the fixtures, the Beauty pack contents, revision and SHA-256 per file, and the face fixture set (synthetic or licensed, V2-31). Recommends one runtime and model set for both platforms; feeds ARCH §16 Q-N1/Q-N2.
- **Acceptance criteria and tests:** report with go/no-go per candidate; mean landmark difference iOS vs Android ≤ 1.5 px at 1080p on the fixtures for the chosen candidate (or the measured value recorded); the owner's answers to Q-N1 and Q-N2 recorded in ARCH (via INT-102, which depends on this ticket). Closes V2-V10, V2-V11.

#### INT-102 · [INTEGRATION] RenderPlan v2 and engine interface amendment (Dart, Pigeon, iOS glue)

- **Milestone:** N3 · **Lane:** Mac · **Area:** Integration
- **Depends on:** INT-101, VED-33, ENG-06, INT-06, CORE-29
- **Owns (Mac):** `CORE/lib/src/plan/{render_plan,plan_json,plan_validator}.dart` (extends CORE-29), `CORE/schema/render_plan.v2.schema.json`, `CORE/test/fixtures/render_plans/contract/v2/`, `CORE/test/plan/v2/`, `API/lib/src/still/`, `API/lib/src/face_tracking.dart`, `API/lib/src/capabilities.dart` (extends API-01), `API/lib/src/fake/` (extends API-01), `API/lib/src/reference/passes/registry.dart`, `API/lib/src/reference/reference_renderer.dart` (extends API-03: calls the registry), `API/test/contract/` (extends API-01), `ENGP/pigeons/engine_api.dart`, `ENGP/lib/src/pigeon/`, `ENGP/ios/Classes/Pigeon/`, `ENGP/android/src/main/kotlin/com/vecvel/danaview/editor/engine/pigeon/` (generated only), `ENGP/lib/src/mobile_editor_engine.dart` (extends ENG-01), `ENGP/ios/Classes/Glue/` (extends ENG-07), `ENGP/ios/Classes/Plan/` (extends IOS-08: v2 decode), `ENGP/ios/Classes/Render/LayerRenderer.swift` (extends IOS-10: registry hook), `ENGP/ios/Classes/{Photo,Beauty}/Registry.swift`, `ENGP/test/glue/` (extends ENG-01), `docs/v1.2/ARCHITECTURE.md` (§6.3 final field names; Q-N1/Q-N2 answers)
- **Spec:** ARCH V2-12, §6.3. RenderPlan `v = 2` with the additive fields and asset kinds of §6.3; validators accept v1 and v2; a v1-shaped plan encodes identically except `v` (fixture). Engine API: `StillPreviewSession`, `StillExportService`, `StillEncodeSettings`, `FaceTrackingPort` (`trackImage`, `trackVideo`, `cancel`, progress), capabilities `stillMaxPixels`, `halfFloatTargets`, `beautyTier`, `segmentationAvailable`; fake engine implementations; reference renderer pass registry (passes added by VED tickets). Pigeon amendment (`StillHostApi`, `JobKindMsg.exportStill`, capability fields, landmark/mask asset messages), regenerated; iOS glue and v2 plan decode; the pass registries and the `LayerRenderer` hook calling registered passes in the §6.2 order; placeholders returning pass-through for every VED pass. A lead-approved amendment exactly like v1.1 INT-06.
- **Acceptance criteria and tests:** contract fixtures decode identically in Dart and Swift; the v1.1 contract and engine suites unchanged; with no passes registered a v2 plan renders pixel-equal to v1; the fake engine passes the extended contract kit.

#### INT-102A · [INTEGRATION] RenderPlan v2 Android decode and glue

- **Milestone:** N3 · **Lane:** Android · **Area:** Integration
- **Depends on:** INT-102
- **Owns (Android):** `ENGK/glue/` (extends ENG-08), `ENGK/plan/` (extends AND-08: v2 decode), `ENGK/effects/LayerEffectChainFactory.kt` (extends AND-09: registry hook), `ENGK/{photo,beauty}/Registry.kt`, `ENGP/android/src/test/kotlin/com/vecvel/danaview/editor/engine/planv2/`, `ENGP/android/src/androidTest/kotlin/com/vecvel/danaview/editor/engine/planv2/`
- **Spec:** the Android side of INT-102: glue for the new host API and job kind, v2 decode with the Kotlin validator, the effect-chain hook and pass registries with pass-through placeholders.
- **Acceptance criteria and tests:** Kotlin decodes every v2 contract fixture identically; the v1.1 Android suites unchanged; a v2 plan with no passes renders pixel-equal to v1 on the emulator.

#### VED-01 · Intent routing: Still Photo Mode vs timeline

- **Milestone:** N3 · **Lane:** Mac · **Area:** UI/UX
- **Depends on:** INT-101, UX-07, UX-41
- **Owns (Mac):** `ED/app/editor_launcher.dart` (extends UX-41), `ED/editor/photo/photo_editor_screen.dart`, `ED/editor/photo/photo_tool_tray.dart`, `packages/danaview_editor/test/photo/routing/`
- **Spec:** ARCH §6.1, V2-315. Typed intents `openPhoto`, `openPhotoBatch`, `newMontage` beside the v1.1 intents; `openPhoto` opens the Still Photo screen (top bar: Back, name and size, Compare, To video, Export; bottom tool tray: Crop, Tone, HSL, Curves, Beauty, Masks, Text, Presets with slots filled by later tickets; tools gated by capabilities and `DANAVIEW_BEAUTY`); the v1.1 timeline is unchanged for every other intent. With `DANAVIEW_PHOTO_EDITOR=false` the photo intents fall back to "Add to new project" (v1.1 behaviour).
- **Acceptance criteria and tests:** widget tests per intent; unsupported tools hidden, not disabled; v1.1 launcher tests unchanged; matrix.

#### VED-02 · .dnphoto model, codec, repository and migrations

- **Milestone:** N3 · **Lane:** Mac · **Area:** Core (pure Dart)
- **Depends on:** VED-01, CORE-22, CORE-24
- **Owns (Mac):** `CORE/lib/src/photo/model/`, `CORE/lib/src/photo/codec/`, `CORE/lib/src/store/photo_store.dart`, `CORE/schema/photo.v1.schema.json`, `CORE/test/photo/{model,codec}/`, `CORE/test/store/photo_store_test.dart`, `CORE/test/fixtures/photos/`
- **Spec:** ARCH V2-10, V2-34, §5.7. `PhotoRecipe` immutable model (tone, color, hsl, curves, geom, masks, lut, fx, overlays, beauty slot typed by VED-15, export defaults, presetRef), `PhotoSource` references (`library`, `media`), two-line codec with header classification and the v1.1 D-12 rules, repair on decode, atomic writes through `StoreFs`, an empty `Migrations` chain, `PhotoStore` (create, open, save, duplicate, delete through `OwnedFileDeleter`, list). Undo history is the v1.1 snapshot model over the recipe (in memory).
- **Acceptance criteria and tests:** round trip of every fixture; unknown keys preserved; a newer `minReader` refused, a newer schema with old `minReader` read-only; random recipes (seeded) survive encode → decode; the store never writes outside `<support>/danaview/editor/photos/`.

#### VED-03 · Still plans: lowering, still service, iOS still renderer

- **Milestone:** N3 · **Lane:** Mac · **Area:** Engine (Dart + iOS)
- **Depends on:** VED-02, INT-102, API-03
- **Owns (Mac):** `CORE/lib/src/photo/lowering/{still_compiler,stages}.dart`, `CORE/test/photo/lowering/`, `API/lib/src/reference/passes/still_source.dart`, `ENGP/lib/src/mobile_still.dart`, `ENGP/ios/Classes/Still/Render/`, `ENGP/example/ios/RunnerTests/StillRender/`, `ED/editor/photo/state/`, `packages/danaview_editor/test/photo/state/`
- **Spec:** ARCH V2-11, §6.2. `StillCompiler` builds a one-frame v2 plan (one image layer, canvas = cropped output size) and runs the photo lowering stages in the §6.2 order (`stages.dart` lists them; each stage file is a placeholder owned by its VED ticket until filled). Mobile Dart implementation of `StillPreviewSession`/`StillExportService` over the Pigeon amendment; iOS still renderer (Core Image on Metal, source decode through ImageIO with orientation, the v1.1 look/place kernels, registry passes); `PhotoEditorController` (recipe state, undo/redo, debounced compile, patch sending, autosave of the recipe).
- **Acceptance criteria and tests:** an identity recipe renders pixel-equal to the source (within 1/255) in the reference and on the simulator; patches update without re-decoding; undo/redo restores recipes exactly; controller tests with the fake engine.

#### VED-03A · Android still renderer

- **Milestone:** N3 · **Lane:** Android · **Area:** Engine (Android)
- **Depends on:** VED-03, INT-102A
- **Owns (Android):** `ENGK/still/render/`, `ENGP/android/src/test/kotlin/com/vecvel/danaview/editor/engine/still/`, `ENGP/android/src/androidTest/kotlin/com/vecvel/danaview/editor/engine/still/`
- **Spec:** GLES 3 still renderer: decode (`ImageDecoder` with orientation, HEIC/AVIF where the device supports them), the v1.1 look/place shaders, registry passes, offscreen FBO.
- **Acceptance criteria and tests:** identity recipe within 1/255 of the source on the emulator; matches the Dart reference within the v1.1 parity tolerance.

#### VED-04 · Half-float and wide-gamut still pipeline (iOS)

- **Milestone:** N3 · **Lane:** Mac · **Area:** Engine (iOS)
- **Depends on:** VED-03
- **Owns (Mac):** `ENGP/ios/Classes/Still/Color/`, `ENGP/example/ios/RunnerTests/StillColor/`, `CORE/lib/src/photo/color_space.dart`, `CORE/test/photo/color_space_test.dart`
- **Spec:** ARCH V2-19. Core Image working format `RGBAh`, linear-light working space in the source gamut (P3 or sRGB), output colour tagging; 10-bit and HDR (gain-map) sources tone-mapped to SDR P3 for display; closes V2-V13's working-format half.
- **Acceptance criteria and tests:** a 16-bit gradient fixture pushed +3 EV and back shows no banding beyond 1 code value (measured); P3 sources keep P3 in output metadata.

#### VED-04A · Half-float still pipeline (Android)

- **Milestone:** N3 · **Lane:** Android · **Area:** Engine (Android)
- **Depends on:** VED-04, VED-03A
- **Owns (Android):** `ENGK/still/color/`, `ENGP/android/src/androidTest/kotlin/com/vecvel/danaview/editor/engine/stillcolor/`
- **Spec:** `RGBA16F` FBOs where `EXT_color_buffer_half_float` (or GLES 3.2) allows, else `RGB10A2`, else `RGBA8` with ordered dithering (minimal tier); Display P3 output where the device supports wide-gamut bitmaps; the choice reported in `halfFloatTargets`. Closes V2-V12.
- **Acceptance criteria and tests:** the banding test of VED-04 on the emulator per fallback; capability reported correctly.

#### VED-05 · Still viewport: tiles, zoom, pan (Dart UI, iOS tiles)

- **Milestone:** N3 · **Lane:** Mac · **Area:** UI/UX + iOS
- **Depends on:** VED-03
- **Owns (Mac):** `ED/editor/photo/viewport/`, `ENGP/ios/Classes/Still/Tiles/`, `ENGP/example/ios/RunnerTests/StillTiles/`, `packages/danaview_editor/test/photo/viewport/`
- **Spec:** V2-304. Viewport widget (pinch, double-tap 1:1, pan with inertia) requesting tiles at the zoom's mip level through `StillPreviewSession.renderTiles`; native tile cache, re-render only visible tiles on patches; press-and-hold shows the original (bypass all).
- **Acceptance criteria and tests:** slider drag on a 24 MP photo updates visible tiles ≤ 16 ms p90 on the mid tier (≤ 33 ms low), recorded; no seams between tiles (golden); memory bounded by the tile cache size.

#### VED-05A · Android tile rendering for the still viewport

- **Milestone:** N3 · **Lane:** Android · **Area:** Engine (Android)
- **Depends on:** VED-05, VED-03A
- **Owns (Android):** `ENGK/still/tiles/`, `ENGP/android/src/androidTest/kotlin/com/vecvel/danaview/editor/engine/stilltiles/`
- **Spec:** tile rendering and cache into the Flutter texture.
- **Acceptance criteria and tests:** as VED-05 on the emulator; no seams.

#### VED-06 · Pro tone: tone v2, grain, vignette (core, reference, iOS, panel)

- **Milestone:** N3 · **Lane:** Mac · **Area:** Core + iOS + UI
- **Depends on:** VED-03
- **Owns (Mac):** `CORE/lib/src/photo/tone/`, `CORE/lib/src/color/recipe_lut.dart`, `CORE/test/photo/tone/`, `CORE/test/color/recipe_lut_test.dart`, `API/lib/src/reference/passes/{tone2,grain}.dart`, `ENGP/ios/Classes/Photo/Tone/`, `ENGP/example/ios/RunnerTests/PhotoTone/`, `ED/editor/photo/tools/tone_panel.dart`, `ED/editor/photo/overlays/clipping_overlay.dart`, `packages/danaview_editor/test/photo/tone/`
- **Spec:** V2-305, ARCH §6.2 steps 6, 7, 10. Exposure ±5 EV (0.01 steps), contrast 0.5–2.0 (v1.1 grade), local highlights/shadows recovery, clarity, texture, dehaze (tone v2 from a ¼-res low-pass base), whites and blacks, temperature 2,000–12,000 K and tint, vibrance and saturation, vignette and seeded grain. `recipe_lut.dart` bakes whites, blacks, extended temperature/tint and vibrance, then calls the HSL and curve stages (placeholder files owned by VED-07 and VED-08, identity until filled), 33³ float16 `.vlut` through CORE-21's writer in an isolate. Clipping warnings (blue/red) from a downsampled histogram. Tone panel with kit sliders and numeric fields.
- **Acceptance criteria and tests:** recipe LUT equals the per-pixel reference functions within 1/1023 on a probe grid; tone v2 and grain reference goldens; iOS output within the v1.1 parity tolerance of the reference; LUT bake ≤ 40 ms (mid); matrix for the panel.

#### VED-06A · Android tone v2 and grain passes

- **Milestone:** N3 · **Lane:** Android · **Area:** Engine (Android)
- **Depends on:** VED-06, VED-03A
- **Owns (Android):** `ENGK/photo/tone/`, `ENGP/android/src/androidTest/kotlin/com/vecvel/danaview/editor/engine/phototone/`
- **Spec:** GLSL ES 3.00 tone v2 (low-pass base, recovery, clarity, texture, dehaze) and grain passes registered in the photo registry.
- **Acceptance criteria and tests:** within the v1.1 parity tolerance of the Dart reference on the emulator.

#### VED-07 · 8-band HSL mixer and Target Adjustment Tool (recipe LUT)

- **Milestone:** N3 · **Lane:** Mac · **Area:** Core + UI
- **Depends on:** VED-06
- **Owns (Mac):** `CORE/lib/src/color/hsl/`, `CORE/test/color/hsl/`, `ED/editor/photo/tools/hsl_panel.dart`, `ED/editor/photo/overlays/target_adjust_overlay.dart`, `packages/danaview_editor/test/photo/hsl/`
- **Spec:** V2-306. Bands Red, Orange, Yellow, Green, Aqua, Blue, Purple, Magenta with smooth hue-weight windows; hue ±100°, saturation and luminance −100…+100; luminance preserved in a perceptual space (OkLCh) so shifts don't clip; baked into the recipe LUT (no native code). TAT: tap and drag on the photo samples the pre-HSL colour (from a downsampled preview buffer) and moves the matching bands.
- **Acceptance criteria and tests:** band weights sum to 1 around the hue circle; neutral greys unaffected by hue/saturation; TAT drag maps to the expected band in tests; panel matrix.

#### VED-08 · Spline RGB and channel curves (recipe LUT)

- **Milestone:** N3 · **Lane:** Mac · **Area:** Core + UI
- **Depends on:** VED-06
- **Owns (Mac):** `CORE/lib/src/color/curves/`, `CORE/test/color/curves/`, `ED/editor/photo/tools/curves_panel.dart`, `packages/danaview_editor/test/photo/curves/`
- **Spec:** V2-307. Monotone cubic (Fritsch–Carlson) splines through ≤ 8 points for RGB, R, G, B; histogram underlay; baked into the recipe LUT, 65³ when any slope > 8. Closes V2-V16.
- **Acceptance criteria and tests:** monotonic for monotonic points; identity curve = identity LUT; 33³ vs 65³ error recorded and within 1/255 after the switch rule.

#### VED-09 · Crop, straighten, horizon, keystone (core, iOS homography, panel)

- **Milestone:** N3 · **Lane:** Mac · **Area:** Core + iOS + UI
- **Depends on:** VED-05
- **Owns (Mac):** `CORE/lib/src/photo/geometry/`, `CORE/test/photo/geometry/`, `API/lib/src/reference/passes/homography.dart`, `ENGP/ios/Classes/Photo/Keystone/`, `ENGP/example/ios/RunnerTests/PhotoKeystone/`, `ED/editor/photo/tools/crop_panel.dart`, `ED/editor/photo/overlays/crop_keystone_overlay.dart`, `packages/danaview_editor/test/photo/crop/`
- **Spec:** V2-309. Aspect ratios (Original, Free, 1:1, 4:5, 9:16, 16:9, 3:2, 4:3, 2.39:1), 90° rotation, flips, straighten ±45° with auto-crop, auto-straighten from line detection on a downsampled image (and gyro metadata when present), H/V keystone as a source-space homography (`layer.src.homography`), crop rect kept inside the warped source.
- **Acceptance criteria and tests:** homography goldens; auto-straighten within 0.5° on fixture horizons; crop never samples outside the source (property test).

#### VED-09A · Android keystone homography sampling

- **Milestone:** N3 · **Lane:** Android · **Area:** Engine (Android)
- **Depends on:** VED-09, VED-05A
- **Owns (Android):** `ENGK/photo/keystone/`, `ENGP/android/src/androidTest/kotlin/com/vecvel/danaview/editor/engine/photokeystone/`
- **Spec:** homography source sampling in GLSL.
- **Acceptance criteria and tests:** matches the reference within tolerance.

#### VED-10 · Selective masks and local adjustments (core, iOS, panel)

- **Milestone:** N3 · **Lane:** Mac · **Area:** Core + iOS + UI
- **Depends on:** VED-06
- **Owns (Mac):** `CORE/lib/src/photo/masks/`, `CORE/test/photo/masks/`, `API/lib/src/photo_prep/`, `API/test/photo_prep/`, `API/lib/src/reference/passes/local_adjust.dart`, `ENGP/ios/Classes/Photo/LocalAdjust/`, `ENGP/example/ios/RunnerTests/PhotoLocal/`, `ED/editor/photo/tools/masks_panel.dart`, `ED/editor/photo/overlays/mask_edit_overlay.dart`, `packages/danaview_editor/test/photo/masks/`
- **Spec:** V2-311. Linear, radial and luminance masks (analytic, in the plan) and brush masks (vector strokes rasterized deterministically by `photo_prep/mask_rasterizer.dart` into an alpha `.vsprite` mask asset keyed by content hash); feather, invert, add/subtract; per-mask exposure, contrast, warmth, saturation, sharpness (ARCH §6.2 step 9); up to 8 masks; mask overlay shows the selection tint.
- **Acceptance criteria and tests:** brush raster deterministic (same strokes → same bytes); local-adjust reference goldens; iOS within tolerance; panel matrix.

#### VED-10A · Android local-adjustment passes

- **Milestone:** N3 · **Lane:** Android · **Area:** Engine (Android)
- **Depends on:** VED-10, VED-06A
- **Owns (Android):** `ENGK/photo/localadjust/`, `ENGP/android/src/androidTest/kotlin/com/vecvel/danaview/editor/engine/photolocal/`
- **Spec:** the local-adjustment pass and mask asset upload in GLSL.
- **Acceptance criteria and tests:** within tolerance of the reference.

#### VED-11 · Text, stickers, borders in Still Photo Mode

- **Milestone:** N3 · **Lane:** Mac · **Area:** UI/UX
- **Depends on:** VED-05
- **Owns (Mac):** `CORE/lib/src/photo/overlays/`, `CORE/test/photo/overlays/`, `ED/editor/photo/tools/{text_tool,stickers_tool,borders_tool}.dart`, `packages/danaview_editor/assets/stickers/`, `packages/danaview_editor/test/photo/overlays/`
- **Spec:** V2-312. Text overlays reuse the v1.1 text model, `FontCatalog` and `TextLayoutEngine` (sprite layers in the still plan); vector stickers (bundled SVG-derived sprites with recorded licences), date stamps, borders and film frames as sprite or solid layers; drag, pinch and rotate on the viewport.
- **Acceptance criteria and tests:** preview text equals export sprite within 1 px (v1.1 UX-19 rule); imported fonts work (AIS-25 after it lands; bundled fonts before); matrix.

#### VED-29 · High-resolution still export (iOS)

- **Milestone:** N3 · **Lane:** Mac · **Area:** Engine (Dart + iOS)
- **Depends on:** VED-04
- **Owns (Mac):** `CORE/lib/src/photo/export/`, `CORE/test/photo/export/`, `ENGP/lib/src/mobile_still_export.dart`, `ENGP/ios/Classes/StillExport/Encode/`, `ENGP/example/ios/RunnerTests/StillExport/`, `ED/editor/photo/export/`, `packages/danaview_editor/test/photo/export/`
- **Spec:** ARCH V2-18, §6.2. Tiled render (≤ 4096 px tiles with apron) and encode from tiles via `CGImageDestination` (JPEG, HEIC, PNG 8/16-bit; WebP only if V2-V14 proves an encoder, else hidden on iOS), quality slider, max long side, tier caps with the export-sheet notice; destinations: library (new entry), Photos (add-only), both; exclusive create, never overwrite. Closes V2-V3/V2-V14 Apple halves.
- **Acceptance criteria and tests:** 24 MP ≤ 3 s and 48 MP ≤ 8 s on the mid tier (device lab), output pixel-equal to a single-pass render of a small fixture; peak memory recorded; the source is unchanged.

#### VED-29A · High-resolution still export (Android)

- **Milestone:** N3 · **Lane:** Android · **Area:** Engine (Android)
- **Depends on:** VED-29, VED-04A
- **Owns (Android):** `ENGK/stillexport/encode/`, `ENGP/android/src/androidTest/kotlin/com/vecvel/danaview/editor/engine/stillexport/`
- **Spec:** tiled render and encode: `Bitmap.compress` JPEG/PNG/WebP (lossy and lossless), HEIC through `androidx.heifwriter` where the device has a HEVC encoder (else hidden), streaming row bands to bound memory.
- **Acceptance criteria and tests:** as VED-29 on the emulator; HEIC availability per device recorded (V2-V14).

#### VED-12 · Photo presets, copy/paste, batch export

- **Milestone:** N3 · **Lane:** Mac · **Area:** Core + UI
- **Depends on:** VED-06, VED-29
- **Owns (Mac):** `CORE/lib/src/photo/{presets,batch}/`, `CORE/lib/src/store/photo_preset_store.dart`, `CORE/test/photo/{presets,batch}/`, `ED/editor/photo/{presets,batch}/`, `packages/danaview_editor/test/photo/{presets,batch}/`
- **Spec:** V2-310, ARCH §5.5. Presets (any subset of tone, color, HSL, curves, LUT, fx; built-ins in code; user presets in `photo_presets.json`), copy and paste with a field picker, apply to many recipes, batch export job (queue, progress, cancel, per-item failure report, format/quality/size/metadata settings) through `StillExportService`; entry from the Home multi-select (wired by INT-105).
- **Acceptance criteria and tests:** applying a preset copies values and records `presetRef`; deleting a preset never changes a recipe; batch of 50 × 12 MP ≤ 90 s (mid) with the app responsive; cancel stops within one item.

#### VED-13 · EXIF/IPTC keep and strip (iOS)

- **Milestone:** N3 · **Lane:** Mac · **Area:** Engine (Dart + iOS)
- **Depends on:** VED-02, VED-29
- **Owns (Mac):** `CORE/lib/src/photo/metadata_policy.dart`, `CORE/test/photo/metadata_policy_test.dart`, `ENGP/ios/Classes/StillExport/Metadata/`, `ENGP/example/ios/RunnerTests/StillMetadata/`, `ED/editor/photo/export/photo_export_sheet.dart` (extends VED-29)
- **Spec:** V2-314 (Q-V3 default). Keep EXIF/IPTC/XMP by default with orientation reset to 1 and dimensions updated; "Strip metadata on export" and "Remove location" switches; batch applies the setting.
- **Acceptance criteria and tests:** fixtures with GPS, camera and IPTC: keep, strip and remove-location outputs verified field by field.

#### VED-13A · EXIF keep and strip (Android)

- **Milestone:** N3 · **Lane:** Android · **Area:** Engine (Android)
- **Depends on:** VED-13, VED-29A
- **Owns (Android):** `ENGK/stillexport/metadata/`, `ENGP/android/src/androidTest/kotlin/com/vecvel/danaview/editor/engine/stillmetadata/`
- **Spec:** `ExifInterface` copy, strip and GPS removal for JPEG, WebP and HEIC.
- **Acceptance criteria and tests:** as VED-13.

#### VED-15 · Schema 2 additions: photo recipe on image clips, BeautyEffectSpec, easing key

- **Milestone:** N3 · **Lane:** Mac · **Area:** Core (pure Dart)
- **Depends on:** CORE-03, VED-02, AIS-04, INT-102
- **Owns (Mac):** `CORE/lib/src/model/{beauty,photo_clip}.dart`, `CORE/lib/src/model/items.dart` (extends AIS-02), `CORE/lib/src/validate/` (extends AIS-02: invariant I12), `CORE/lib/src/codec/project_json.dart` (extends AIS-04), `CORE/schema/project.v2.schema.json` (extends AIS-04), `CORE/lib/src/plan/{lowering_beauty,lowering_photo_clip}.dart`, `CORE/lib/src/plan/lowering_visual.dart` (extends CORE-30), `CORE/lib/src/plan/render_ranges.dart` (extends CORE-37: beauty is heavy), `CORE/test/model/beauty/`, `CORE/test/plan/beauty/`, `CORE/test/fixtures/projects/s2/photo_beauty/`
- **Spec:** ARCH V2-03, §5.8. `MediaClip` gains optional `ph` (photo recipe for image clips) and `bt` (`BeautyEffectSpec` with the full `BeautyParamId` enum, categories, ranges, bypass, ≤ 4 subjects); keyframe key `e` reserved (semantics VED-19); invariant I12 (subjects unique, params in range, ≤ 4 subjects, masks valid); codec and JSON Schema additions with defaults omitted; lowering: image clips with `ph` run the photo stages (the same `stages.dart` as stills), clips with `bt` emit `layer.beauty` (faces asset resolved through an `AssetResolver` hook VED-17 fills); render-range cost counts beauty as heavy (v1.1 D-45).
- **Acceptance criteria and tests:** s1 fixtures still migrate exactly as AIS-04 specifies; s2 fixtures with `ph`/`bt` round trip; a 1.1.x decoder fixture test opens them read-only without loss (V2-V17); lowering goldens; random project fuzzer (CORE-34) extended with `ph`/`bt` generators stays green.

#### VED-14 · Add to Video Project, montage sequence, Ken Burns

- **Milestone:** N3 · **Lane:** Mac · **Area:** Core + UI
- **Depends on:** VED-02, VED-15, CORE-13
- **Owns (Mac):** `CORE/lib/src/ops/commands/photo_bridge_commands.dart`, `CORE/lib/src/photo/ken_burns.dart`, `CORE/test/ops/photo_bridge/`, `ED/editor/photo/bridge/`, `ED/editor/flows/montage/`, `packages/danaview_editor/test/photo/bridge/`
- **Spec:** V2-313, ARCH §6.1. `AddPhotoAsClip(recipe, project?, at)` (3.0 s on the grid, recipe and beauty carried, not baked), `AddMediaSequence(items)` for montages (photos 3 s, videos chronological, V1), Ken Burns presets (pan left/right, zoom in/out) as two eased transform keys; the "To video" sheet (new project or recent project); montage builder used by `EditorLauncher.newMontage`.
- **Acceptance criteria and tests:** one history entry per command; the clip's preview equals the still render of the same recipe at frame 0 (parity test with VED-32 later); montage order matches input.

#### VED-16 · danaview_face_tracking surface, iOS trackers, One-Euro, Beauty pack

- **Milestone:** N4 · **Lane:** Mac · **Area:** Beauty (native)
- **Depends on:** VED-33, INT-101
- **Owns (Mac):** `FACE/pigeons/face_api.dart`, `FACE/lib/src/pigeon/`, `FACE/lib/src/{face_tracker,models}.dart`, `FACE/ios/danaview_face_tracking.podspec`, `FACE/ios/Classes/{Glue,Face,Pose,Segmentation}/`, `FACE/example/ios/RunnerTests/Trackers/`, `FACE/android/src/main/kotlin/com/vecvel/danaview/face/pigeon/` (generated only), `CORE/lib/src/beauty/one_euro.dart`, `CORE/test/beauty/one_euro_test.dart`, `CORE/test/fixtures/vectors/one_euro.json`, `packages/danaview_transcription/lib/src/catalog/beauty_pack.dart`, `packages/danaview_transcription/test/catalog/beauty_pack_test.dart`, `lib/adapters/face_tracking_adapter.dart`
- **Spec:** ARCH V2-13…V2-15, V2-25. The whole plugin surface, frozen after this ticket (`trackImage`, `trackVideoFrames` streaming batches, `segment(frame)`, `loadModels(paths)`, capabilities, cancel); iOS implementation with the VED-33 runtime (face 478, pose 33, person and hair segmentation), loading models only from given paths; One-Euro filter with the parameter sets of ARCH §6.4 and committed vectors; the Beauty pack `ModelSpec` (pinned revision, files, SHA-256, sizes) for v1.1's downloader and consent view (V2-23); the app-root adapter to `FaceTrackingPort`. Closes V2-V15.
- **Acceptance criteria and tests:** tracker output on the face fixtures within the VED-33 tolerance; One-Euro vectors reproduce bit-exactly; jitter metric (mean frame-to-frame landmark motion on a still head) reduced ≥ 80 % at medium with lag ≤ 2 frames on the fast-turn fixture; zero network before consent (spy); rule 21 grep green.

#### VED-16A · Android trackers and glue

- **Milestone:** N4 · **Lane:** Android · **Area:** Beauty (native)
- **Depends on:** VED-16
- **Owns (Android):** `FACE/android/build.gradle.kts`, `FACE/android/src/main/AndroidManifest.xml`, `FACEK/{glue,face,pose,segmentation}/`, `FACE/android/src/test/kotlin/com/vecvel/danaview/face/trackers/`, `FACE/android/src/androidTest/kotlin/com/vecvel/danaview/face/trackers/`
- **Spec:** the Android implementation with the same runtime and models (GPU delegate where available, CPU fallback).
- **Acceptance criteria and tests:** fixture landmarks within the VED-33 tolerance of iOS; emulator latency recorded.

#### VED-17 · Background pre-tracking and .dnface cache (iOS sampling)

- **Milestone:** N4 · **Lane:** Mac · **Area:** Beauty (Dart + iOS)
- **Depends on:** VED-16, VED-15
- **Owns (Mac):** `FACE/lib/src/video_sampler.dart`, `FACE/ios/Classes/VideoSampler/`, `FACE/example/ios/RunnerTests/VideoSampler/`, `CORE/lib/src/formats/dnface.dart`, `CORE/lib/src/beauty/track_smoothing.dart`, `CORE/test/beauty/{dnface,track_smoothing}/`, `ED/editor/beauty/{face_track_service,face_cache_store}.dart`, `packages/danaview_editor/test/beauty/tracking/`
- **Spec:** V2-320, ARCH §5.9, §6.4. Native frame sampling (`AVAssetReader` at analysis size ≤ 720p, every source frame of the clip's used range); `.dnface` codec; job service (background, cancellable, progress, below export priority, resumes per range); cache store (content-addressed, backup-excluded, LRU 512 MB); smoothing with occlusion fade (3 frames) into the smoothed plan asset; the `AssetResolver` hook VED-15 reserved.
- **Acceptance criteria and tests:** a 1080p clip pre-tracks ≤ 0.5× real time on the mid tier; `.dnface` round trip; smoothing deterministic (same input → same bytes); cache hit after reopen; cancel leaves no partial cache file.

#### VED-17A · Android video sampling for pre-tracking

- **Milestone:** N4 · **Lane:** Android · **Area:** Beauty (native)
- **Depends on:** VED-17, VED-16A
- **Owns (Android):** `FACEK/videosampler/`, `FACE/android/src/androidTest/kotlin/com/vecvel/danaview/face/videosampler/`
- **Spec:** `MediaCodec` (surface → `ImageReader`) sampling at analysis size with source PTS, falling back to `MediaMetadataRetriever` for exotic codecs.
- **Acceptance criteria and tests:** sample PTS match the source frame grid on fixtures; speed recorded.

#### VED-18 · Multi-subject detection and Face IDs

- **Milestone:** N4 · **Lane:** Mac · **Area:** Core (pure Dart)
- **Depends on:** VED-17
- **Owns (Mac):** `CORE/lib/src/beauty/subjects/`, `CORE/lib/src/ops/commands/beauty_commands.dart`, `CORE/test/beauty/subjects/`, `CORE/test/ops/beauty/`
- **Spec:** V2-318 (Q-V4 default 4). `FaceSignature` from landmark geometry ratios (no identity model, nothing leaves the device), Hungarian matching across frames with gap tolerance, stable `subjectId` 0..3 per clip, re-identification after occlusion; commands `SetBeautyParam`, `SetBeautyParams`, `AddBeautySubject`, `RemoveBeautySubject`, `SetBeautyBypass`, `ResetBeauty`, each one history entry with coalescing for slider drags.
- **Acceptance criteria and tests:** on a two-face fixture with crossing paths the ids never swap; a face leaving and returning keeps its id; commands round-trip through undo.

#### VED-19 · Keyframes and easing for beauty and all properties

- **Milestone:** N4 · **Lane:** Mac · **Area:** Core (pure Dart)
- **Depends on:** VED-15, CORE-19
- **Owns (Mac):** `CORE/lib/src/model/keyframes/keyframe_data.dart` (extends CORE-03), `CORE/lib/src/model/keyframes/property_keys.dart` (extends CORE-05: `beauty.*` keys), `CORE/lib/src/eval/easing.dart`, `CORE/lib/src/ops/commands/keyframe_easing_commands.dart`, `CORE/lib/src/plan/lowering_visual.dart` (extends VED-15: eased keys lowered to frame-grid linear keys), `CORE/test/eval/easing/`, `ED/editor/panels/keyframes_panel.dart` (extends UX-26: easing control)
- **Spec:** ARCH V2-16, V2-319. Per-key easing `linear` or cubic bezier (presets ease-in, ease-out, ease-in-out, custom handles); evaluation in core; lowering to one linear key per frame across eased spans with collinear merge (1e-4); every numeric beauty parameter and every v1.1 keyframable property can ease.
- **Acceptance criteria and tests:** lowered keys reproduce the eased curve at every frame exactly (frame-grid property test); linear projects lower byte-identically to 1.1; undo of easing changes.

#### VED-20 · Face shape and slimming

- **Milestone:** N4 · **Lane:** Mac · **Area:** Beauty (core + iOS)
- **Depends on:** VED-17, INT-102
- **Owns (Mac):** `CORE/lib/src/beauty/params/face_shape.dart`, `CORE/lib/src/beauty/mesh/`, `CORE/test/beauty/face_shape/`, `API/lib/src/reference/passes/beauty/{mesh_warp,face_shape}.dart`, `ENGP/ios/Classes/Beauty/{Mesh,FaceShape}/`, `ENGP/example/ios/RunnerTests/BeautyFaceShape/`
- **Spec:** VED §5.1: face slimming, V-shape, jawline sharpening, chin width/length/apex, forehead width/height, lower-face slimming, cheekbones, symmetry correction, overall reshape. Shared mesh-warp infrastructure: canonical triangulation of the 478-point topology, displacement fields per parameter normalized to inter-ocular distance, no-flip clamp, background pinning outside the face hull, Metal vertex warp of the source texture before the surface passes (§6.2 step 3).
- **Acceptance criteria and tests:** reference goldens per parameter at 0.5 and 1.0 on the fixtures; no triangle flips over the parameter grid (property test); iOS within the v1.1 parity tolerance of the reference; preview ≥ 30 fps at 1080p mid tier with all face-shape parameters on.

#### VED-20A · Face shape and slimming (Android)

- **Milestone:** N4 · **Lane:** Android · **Area:** Beauty (Android)
- **Depends on:** VED-20, VED-17A, INT-102A
- **Owns (Android):** `ENGK/beauty/{mesh,faceshape}/`, `ENGP/android/src/androidTest/kotlin/com/vecvel/danaview/editor/engine/beautyfaceshape/`
- **Spec:** GLES mesh warp and face-shape passes.
- **Acceptance criteria and tests:** within tolerance of the reference; fps recorded.

#### VED-21 · Eyes and eyebrows

- **Milestone:** N4 · **Lane:** Mac · **Area:** Beauty (core + iOS)
- **Depends on:** VED-20
- **Owns (Mac):** `CORE/lib/src/beauty/params/eyes_brows.dart`, `CORE/test/beauty/eyes_brows/`, `API/lib/src/reference/passes/beauty/eyes_brows.dart`, `ENGP/ios/Classes/Beauty/EyesBrows/`, `ENGP/example/ios/RunnerTests/BeautyEyes/`
- **Spec:** VED §5.2: eye enlargement (iris-centred), shape and canthus angle, spacing and height, brightening (sclera and catchlights), dark circles and eye bags, eyebrow thickness/shape/position, eyelash enhancement (procedural lash strokes along the lid contour).
- **Acceptance criteria and tests:** as VED-20 per parameter.

#### VED-21A · Eyes and eyebrows (Android)

- **Milestone:** N4 · **Lane:** Android · **Area:** Beauty (Android)
- **Depends on:** VED-21, VED-20A
- **Owns (Android):** `ENGK/beauty/eyesbrows/`, `ENGP/android/src/androidTest/kotlin/com/vecvel/danaview/editor/engine/beautyeyes/`
- **Spec:** GLSL equivalents.
- **Acceptance criteria and tests:** within tolerance.

#### VED-22 · Nose and lips

- **Milestone:** N4 · **Lane:** Mac · **Area:** Beauty (core + iOS)
- **Depends on:** VED-20
- **Owns (Mac):** `CORE/lib/src/beauty/params/nose_lips.dart`, `CORE/test/beauty/nose_lips/`, `API/lib/src/reference/passes/beauty/nose_lips.dart`, `ENGP/ios/Classes/Beauty/NoseLips/`, `ENGP/example/ios/RunnerTests/BeautyNoseLips/`
- **Spec:** VED §5.3: nose slimming and alar width, length and bridge, tip; lip size, shape and thickness, Cupid's bow, corners, smile lift.
- **Acceptance criteria and tests:** as VED-20.

#### VED-22A · Nose and lips (Android)

- **Milestone:** N4 · **Lane:** Android · **Area:** Beauty (Android)
- **Depends on:** VED-22, VED-20A
- **Owns (Android):** `ENGK/beauty/noselips/`, `ENGP/android/src/androidTest/kotlin/com/vecvel/danaview/editor/engine/beautynoselips/`
- **Spec:** GLSL equivalents.
- **Acceptance criteria and tests:** within tolerance.

#### VED-23 · Skin retouching and teeth

- **Milestone:** N4 · **Lane:** Mac · **Area:** Beauty (core + iOS)
- **Depends on:** VED-17, INT-102
- **Owns (Mac):** `CORE/lib/src/beauty/params/skin.dart`, `CORE/test/beauty/skin/`, `API/lib/src/reference/passes/beauty/skin.dart`, `ENGP/ios/Classes/Beauty/Skin/`, `ENGP/example/ios/RunnerTests/BeautySkin/`, `ED/editor/beauty/heal_brush_overlay.dart`
- **Spec:** VED §5.4: skin smoothing (frequency separation inside a landmark skin mask that excludes eyes, brows, lips and hair), acne and blemish removal (automatic spot detection plus manual heal spots stored as normalized face-space points so they track on video), dark-spot fading, skin tone shift (palette presets), anti-shine, wrinkle softening, natural glow, teeth whitening (mouth-region mask from lip landmarks).
- **Acceptance criteria and tests:** reference goldens; texture preserved (high-frequency energy outside blemishes ≥ 70 % at default smoothing, measured); heal spots stay on the face across the moving fixture; iOS within tolerance.

#### VED-23A · Skin retouching and teeth (Android)

- **Milestone:** N4 · **Lane:** Android · **Area:** Beauty (Android)
- **Depends on:** VED-23, VED-17A, INT-102A
- **Owns (Android):** `ENGK/beauty/skin/`, `ENGP/android/src/androidTest/kotlin/com/vecvel/danaview/editor/engine/beautyskin/`
- **Spec:** GLSL equivalents.
- **Acceptance criteria and tests:** within tolerance.

#### VED-24 · Virtual makeup and appearance (incl. hair colour)

- **Milestone:** N4 · **Lane:** Mac · **Area:** Beauty (core + iOS)
- **Depends on:** VED-23
- **Owns (Mac):** `CORE/lib/src/beauty/params/makeup.dart`, `CORE/test/beauty/makeup/`, `API/lib/src/reference/passes/beauty/makeup.dart`, `ENGP/ios/Classes/Beauty/{Makeup,Hair}/`, `ENGP/example/ios/RunnerTests/BeautyMakeup/`, `packages/danaview_editor/assets/makeup/`
- **Spec:** VED §5.5: foundation and concealer (coverage, finish), lipstick (matte, gloss, velvet, ombré; curated shade palettes; feathering), blush and contour, eyeliner (winged, tightline, smokey) and eyeshadow gradients, coloured contact lenses (iris mask from iris landmarks), hair colour (segmentation, V2-17), freckles and beauty marks (face-space placement).
- **Acceptance criteria and tests:** reference goldens for landmark-driven makeup; hair colour preview equals export on the simulator (segmentation exemption recorded); shade palettes load from assets.

#### VED-24A · Virtual makeup and appearance (Android)

- **Milestone:** N4 · **Lane:** Android · **Area:** Beauty (Android)
- **Depends on:** VED-24, VED-23A
- **Owns (Android):** `ENGK/beauty/{makeup,hair}/`, `ENGP/android/src/androidTest/kotlin/com/vecvel/danaview/editor/engine/beautymakeup/`
- **Spec:** GLSL equivalents with on-device segmentation for hair.
- **Acceptance criteria and tests:** landmark-driven passes within tolerance; hair colour preview = export on the emulator.

#### VED-25 · Body reshaping

- **Milestone:** N4 · **Lane:** Mac · **Area:** Beauty (core + iOS)
- **Depends on:** VED-17, INT-102
- **Owns (Mac):** `CORE/lib/src/beauty/params/body.dart`, `CORE/test/beauty/body/`, `API/lib/src/reference/passes/beauty/body.dart`, `ENGP/ios/Classes/Beauty/Body/`, `ENGP/example/ios/RunnerTests/BeautyBody/`
- **Spec:** VED §5.6, V2-323 (Q-V5): body reshape, waist, arms and legs, hips and shoulders, leg length anchored to the floor line, height and proportion; a pose-driven coarse mesh with the background pinned outside a dilated body hull (no straight background line bends more than 1 px, D-138); pose track stored in `.dnface` topology 2.
- **Acceptance criteria and tests:** background straight-line fixture stays within 1 px; reference goldens; iOS within tolerance.

#### VED-25A · Body reshaping (Android)

- **Milestone:** N4 · **Lane:** Android · **Area:** Beauty (Android)
- **Depends on:** VED-25, VED-17A, INT-102A
- **Owns (Android):** `ENGK/beauty/body/`, `ENGP/android/src/androidTest/kotlin/com/vecvel/danaview/editor/engine/beautybody/`
- **Spec:** GLSL equivalent.
- **Acceptance criteria and tests:** as VED-25.

#### VED-34 · Beauty filters, portrait bokeh, face-anchored stickers

- **Milestone:** N4 · **Lane:** Mac · **Area:** Beauty (core + iOS)
- **Depends on:** VED-17, VED-11, INT-102
- **Owns (Mac):** `CORE/lib/src/beauty/{params/portrait,filters,anchors}.dart`, `CORE/test/beauty/{portrait,filters,anchors}/`, `API/lib/src/reference/passes/beauty/bokeh.dart`, `ENGP/ios/Classes/Beauty/Portrait/`, `ENGP/example/ios/RunnerTests/BeautyPortrait/`, `packages/danaview_editor/assets/{beauty_looks,face_stickers}/`
- **Spec:** VED §5.7 (added by this plan, ARCH V2-02): beauty filters Natural, Soft, Glam, Vintage 35mm, Pastel, Cinematic as bundled `.vlut` looks plus tone presets; portrait bokeh f/1.4–f/16 with blade count (person segmentation + depth-from-segmentation blur, V2-17); face-anchored stickers, glasses, headbands and frames placed by lowering from the smoothed landmark track (sprite layers, rotation and scale from the face pose).
- **Acceptance criteria and tests:** stickers follow the moving fixture within 2 px of the landmark anchor; bokeh preview equals export on the simulator; filter LUT licences recorded.

#### VED-34A · Portrait bokeh (Android)

- **Milestone:** N4 · **Lane:** Android · **Area:** Beauty (Android)
- **Depends on:** VED-34, VED-17A, INT-102A
- **Owns (Android):** `ENGK/beauty/portrait/`, `ENGP/android/src/androidTest/kotlin/com/vecvel/danaview/editor/engine/beautyportrait/`
- **Spec:** the bokeh pass with on-device segmentation (filters and stickers need no Android code).
- **Acceptance criteria and tests:** preview equals export on the emulator.

#### VED-26 · Beauty & Retouching inspector, bypass, tier defaults

- **Milestone:** N4 · **Lane:** Mac · **Area:** UI/UX
- **Depends on:** VED-15, VED-18, VED-19, UX-16
- **Owns (Mac):** `ED/editor/panels/beauty/`, `ED/editor/actions/bindings/beauty_bindings.dart`, `ED/app/strings/beauty_strings.dart`, `ED/editor/beauty/beauty_tier_policy.dart`, `ED/editor/photo/tools/beauty_tool.dart`, `packages/danaview_editor/test/beauty/panel/`
- **Spec:** V2-324, V2-327, V2-329. Inspector tab in the clip inspector and the photo tool tray: master on/off and intensity, temporal smoothing, subject chips (Face 1–4, "+ Track face"), category tabs (Face shape, Eyes/Brows, Nose/Lips, Skin, Makeup, Body, Filters, Presets) with keyframe toggles per slider, per-category bypass, Reset; the Beauty pack download entry (v1.1 consent view, V2-23) and the "pack missing" state; tier policy (half-res proxies on low tier, video beauty hidden on minimal, ARCH §6.4); tracking progress and failure states.
- **Acceptance criteria and tests:** widget tests for pack missing, downloading, tracking, ready, failed; matrix 280–1280 px × 0.85–1.35; semantics on every slider; flag off hides the tab.

#### VED-27 · Split before/after comparator

- **Milestone:** N4 · **Lane:** Mac · **Area:** UI/UX
- **Depends on:** VED-26, CORE-32
- **Owns (Mac):** `CORE/lib/src/beauty/compare_transient.dart`, `CORE/test/beauty/compare_transient_test.dart`, `ED/editor/preview/compare_overlay.dart`, `ED/editor/photo/overlays/compare_split_overlay.dart`, `packages/danaview_editor/test/beauty/compare/`
- **Spec:** V2-325, ARCH §6.4: a preview transient duplicating the layer without beauty and photo passes under a canvas mask at the divider (video and stills), draggable divider, press-and-hold for the original; no project change and no history entry.
- **Acceptance criteria and tests:** left of the divider equals the bypassed render and right equals the processed render (pixel tests on the reference); export unaffected.

#### VED-28 · Beauty presets, copy/paste attributes, automatic enhancement

- **Milestone:** N4 · **Lane:** Mac · **Area:** Core + UI
- **Depends on:** VED-26
- **Owns (Mac):** `CORE/lib/src/beauty/{presets,auto_enhance}.dart`, `CORE/lib/src/store/beauty_preset_store.dart`, `CORE/test/beauty/{presets,auto_enhance}/`, `ED/editor/panels/beauty_presets/`, `packages/danaview_editor/test/beauty/presets/`
- **Spec:** V2-326, VED §5.8: built-in styles (Natural Glow, Editorial Chic, Sunset Warmth, Clean Beauty), user presets in `beauty_presets.json` (copy values + `presetRef`), copy beauty attributes from a clip or photo and paste onto many clips/photos, one-tap automatic enhancement (local analysis of skin tone variance and facial balance from landmarks → conservative parameter set, never above 40 % per parameter).
- **Acceptance criteria and tests:** presets apply identically to stills and clips; paste to 20 clips is one history entry; auto-enhance is deterministic for a given frame.

#### VED-30 · 4K export with full beauty (iOS, Android)

- **Milestone:** N5 · **Lane:** Mac + Android · **Area:** QA
- **Depends on:** VED-15, VED-21A, VED-22A, VED-24A, VED-25A, VED-34A, VED-28, INT-105, IOS-12, AND-11
- **Owns (Mac):** `integration_test/v12/beauty_export/`, `docs/v1.2/video-editor-update/qa/VED-30-export.md`
- **Spec:** exports of 1080p and 4K projects with every beauty category on one and two subjects through the v1.1 exporters (IOS-12, AND-11) on the simulator, the emulator and the device lab; export conformance per v1.1 ARCH §14.4; render-preview cache behaviour with beauty ranges.
- **Acceptance criteria and tests:** conformance passes; beauty export throughput per ARCH §10.1 recorded; exported frames equal preview frames at sampled times within tolerance.

#### VED-31 · Memory stress: 48 MP and 100 MP stills on low-RAM devices

- **Milestone:** N5 · **Lane:** Mac + Android · **Area:** QA
- **Depends on:** VED-05A, VED-29A, VED-12, VED-13A
- **Owns (Mac):** `integration_test/v12/still_memory/`, `docs/v1.2/video-editor-update/qa/VED-31-memory.md`
- **Spec:** open, edit (every photo tool), compare, export and batch-export 48 MP and 100 MP fixtures on the minimal, low and mid tiers (lab iPhone 7/8/SE 2 and the emulator with low-RAM settings), with Instruments / `dumpsys meminfo` traces.
- **Acceptance criteria and tests:** no OOM or crash; peak extra memory ≤ ARCH §10.1; tier caps applied with the notice (V2-18).

#### VED-32 · Golden parity: Still Photo Mode vs timeline, iOS vs Android

- **Milestone:** N5 · **Lane:** Mac + Android · **Area:** QA
- **Depends on:** VED-29A, VED-30, VED-14, VED-27
- **Owns (Mac):** `packages/danaview_editor/test/parity/photo_vs_timeline/`, `integration_test/v12/photo_parity/`, `docs/v1.2/video-editor-update/qa/VED-32-parity.md`
- **Spec:** V2-322. The same recipe and beauty spec rendered as a still and as frame 0 of an image clip (VED-14) on both platforms and in the Dart reference; landmark-driven passes inside the v1.1 parity tolerance; segmentation passes with their recorded tolerance (V2-17).
- **Acceptance criteria and tests:** parity numbers per pass and platform in the report; failures become FIX tickets.

### 4.4 Speed-test fallback (ST)

#### ST-01 · SpeedTestProvider interface and CloudflareSpeedProvider

- **Milestone:** N1 · **Lane:** Mac · **Area:** Speed test
- **Depends on:** INT-101
- **Owns (Mac):** `packages/danaview_data/lib/src/network/speed_test.dart` (extends v1.0: becomes a facade), `packages/danaview_data/lib/src/network/speed/{speed_test_provider,cloudflare_speed_provider,phase_result}.dart`, `packages/danaview_data/test/network/speed/cloudflare_test.dart`
- **Spec:** V2-401. `SpeedTestProvider` (`latency(health)`, `download`, `upload`, cancel, typed failures `rateLimited`, `forbidden`, `unreachable`, `stalled`); the existing Cloudflare code moved behind it with **no behaviour change** (same endpoints, sizes, stall timeout, parallelism); the public facade API of `speed_test.dart` unchanged.
- **Acceptance criteria and tests:** the existing root suite `test/network_tools_test.dart` stays green unchanged (the ST plan's "network_test.dart" is this file); provider tests against a loopback fake.

#### ST-02 · MLabNdt7Provider

- **Milestone:** N1 · **Lane:** Mac · **Area:** Speed test
- **Depends on:** ST-01
- **Owns (Mac):** `packages/danaview_data/lib/src/network/speed/{mlab_ndt7_provider,mlab_locate}.dart`, `packages/danaview_data/test/network/speed/{mlab_test,fake_ndt7_server}.dart`
- **Spec:** V2-401. M-Lab locate API (`locate.measurementlab.net/v2/nearest/ndt/ndt7`) then NDT7 download and upload over WebSocket (`dart:io`, subprotocol `net.measurementlab.ndt.v7`), measurement messages parsed, single-stream results; no third-party dependency. Runs only with an `OpenNetworkConsent` ticket (ARCH rule 28). Closes V2-V19.
- **Acceptance criteria and tests:** unit tests against a local fake locate + NDT7 server (download, upload, malformed messages, early close); refuses to run without a ticket; no request to M-Lab hosts in any test (no-network bootstrap).

#### ST-03 · SpeedTestCoordinator: health check, failover, skip memory, attribution

- **Milestone:** N1 · **Lane:** Mac · **Area:** Speed test
- **Depends on:** ST-01, ST-02
- **Owns (Mac):** `packages/danaview_data/lib/src/network/speed/{speed_test_coordinator,provider_health_store}.dart`, `packages/danaview_data/test/network/speed/coordinator_test.dart`
- **Spec:** V2-403, V2-404. Zero-byte health request (≈ 1.5 s timeout) folded into the latency phase; on 429, 403, connection failure or stall only the failing phase restarts on the next provider; a failed provider is skipped for 10 minutes (memory and prefs); per-phase provider attribution kept internally; result notes "measured on two servers" and "open network".
- **Acceptance criteria and tests:** injected 429, 403, stalls and connection errors at every phase; phases never mix providers; skip expiry with a fake clock; consent declined → calm failure result.

#### ST-04 · Consent prompt, Settings › Privacy toggle, neutral copy

- **Milestone:** N1 · **Lane:** Mac · **Area:** Speed test
- **Depends on:** ST-03
- **Owns (Mac):** `FEAT/tools/speed_consent_sheet.dart`, `FEAT/tools/danaview_speed_test_screen.dart` (extends v1.0), `FEAT/tools/network_tool_providers.dart` (extends v1.0), `FEAT/tools/network_format.dart` (extends v1.0), `FEAT/more/settings_sections/privacy_section.dart`, `test/v12/speed_test/`
- **Spec:** V2-402, V2-405, V2-23. The one-time prompt (D-ST2 wording; Run on open network / Not now), remembered and changeable in Settings › Privacy; "Testing against a nearby server" and no provider names anywhere in the speed-test UI; details-row notes; `OpenNetworkConsent.accepted(` only in `speed_consent_sheet.dart` (architecture test).
- **Acceptance criteria and tests:** widget tests for first run, accepted, declined, revoked; no provider brand string in any speed-test widget (string scan); matrix 280–1280 px × 0.85–1.35.

#### ST-05 · Privacy text and store answers for the speed test

- **Milestone:** N1 · **Lane:** Mac · **Area:** Speed test
- **Depends on:** ST-04
- **Owns (Mac):** `FEAT/more/legal_texts.dart` (extends v1.1 UX-42; first in the 1.2.0 chain), `test/v12/legal/speed_test_text_test.dart`, `docs/v1.2/speed-test/store_answers.md`
- **Spec:** V2-406: Cloudflare (default; sees connection details such as the IP) and M-Lab (only if you agree; results including the IP are published publicly) named in "When Danaview uses the internet"; store privacy answer notes for AIS-41. The owner reviews the wording (Q-S1).
- **Acceptance criteria and tests:** the text names both hosts; the root privacy-host test (v1.1) passes with the new hosts.

### 4.5 Cross-plan integration (INT-1xx)

#### INT-101 · [INTEGRATION] Cross-plan foundations

- **Milestone:** N0 · **Lane:** Mac · **Area:** Integration
- **Depends on:** AIS-01
- **Owns (Mac):**
  - `packages/danaview_library/{pubspec.yaml, analysis_options.yaml, lib/danaview_library.dart, lib/testing.dart}`
  - `packages/danaview_library_native/{pubspec.yaml, analysis_options.yaml, lib/danaview_library_native.dart}`
  - `packages/danaview_pdf/{pubspec.yaml, analysis_options.yaml, lib/danaview_pdf.dart}`
  - `packages/danaview_documents/{pubspec.yaml, analysis_options.yaml, lib/danaview_documents.dart}`
  - `packages/danaview_face_tracking/{pubspec.yaml, analysis_options.yaml, lib/danaview_face_tracking.dart}`
  - `packages/danaview_search/{pubspec.yaml, analysis_options.yaml, lib/danaview_search.dart, lib/testing.dart}`
  - `CORE/lib/{photo,beauty}.dart` (new barrels)
  - `CORE/lib/src/ops/edit_command.dart` (extends AIS-01: `part` directives for `photo_bridge_commands.dart`, `beauty_commands.dart`, `keyframe_easing_commands.dart`)
  - `ED/editor/contracts/{action_ids,inspector_routes,tool_ids}.dart`, `ED/editor/wiring/action_bindings.dart` (extend AIS-01: photo tools, beauty, compare, To video, batch edit; `BeautyInspector`, photo tool routes; merge `photo_bindings.dart` and `beauty_bindings.dart`)
  - `ED/app/flags_v12.dart`, `FEAT/flags.dart`
  - `packages/danaview_features/pubspec.yaml` ([INTEGRATION]: `danaview_library`, `danaview_library_native`, `danaview_documents`, `danaview_search`)
  - `FEAT/more/danaview_settings_screen.dart` (extends UX-04: settings section slots), `FEAT/more/settings_sections/settings_sections.dart`
  - `test/architecture/dependency_rules_test.dart` (extends AIS-01), `test/architecture/fixtures/v12/`
  - `.github/workflows/editor-ci.yml` (extends AIS-01), `scripts/ci/v12/{library.sh,documents.sh,face.sh,README.md}`
  - `docs/v1.2/ARCHITECTURE.md` (status cells: Q-N5 answer; rule 20's `lib/src/desktop/` allowance)
- **Spec:** ARCH V2-04, V2-05, §4. Package skeletons with every dependency they need in 1.2.0 (manifests owned here; `danaview_search` without `danaview_ai`, added by AIS-52); D-33 placeholders (`// OWNER: <ticket>`) for every new Dart file of §4.2–§4.4 in those packages, `FEAT/library/**`, `ED/editor/photo/**`, `ED/editor/panels/beauty/**`, `ED/editor/beauty/**`, `CORE/lib/src/{photo,color,beauty}/**`, and the photo lowering stage files; the four flags read in one file per package; settings section slots (privacy, library storage, search index) as optional widget builders so the app compiles before the owners land; dependency rules 20–31 with a negative fixture each; CI jobs `v12-dart` (library, search, core photo tests), `v12-flutter` (documents, features), `home-preservation` (HOM-15's script) with path filters.
- **Acceptance criteria and tests:** every new package analyzes and tests green with placeholders; each rule fails on its planted fixture; with all four flags false a widget test shows the 1.1 Home, no photo-editor entry, no beauty tab; v1.1 suites unchanged; desktop builds compile.

#### INT-104 · [INTEGRATION] Platform declarations

- **Milestone:** N1 · **Lane:** Mac · **Area:** Integration
- **Depends on:** HOM-17, HOM-20, CORE-28, INT-03
- **Owns (Mac):** `ios/Runner.xcodeproj/project.pbxproj` (extends INT-03: `DanaviewShare` extension target, embed phase, App Group capability), `ios/Runner/Runner.entitlements` (extends INT-03), `ios/DanaviewShare/DanaviewShare.entitlements`, `ios/DanaviewShare/PrivacyInfo.xcprivacy`, `ios/Runner/Info.plist` (document types at rank Alternate, `UTImportedTypeDeclarations`, `NSPhotoLibraryUsageDescription`), `ios/Runner/PrivacyInfo.xcprivacy` (extends INT-03), `macos/Runner/{Info.plist,DebugProfile.entitlements,Release.entitlements}`, `android/app/src/main/AndroidManifest.xml` ([INTEGRATION]: intent filters, `READ_MEDIA_*` with `maxSdkVersion` rules), `android/app/src/main/res/xml/{danaview_backup_rules,danaview_data_extraction_rules}.xml` (extends CORE-28: include `library/`, exclude `library/imports/`, `search/`, `signatures/`), `ios/fastlane/` signing notes for the extension
- **Spec:** ARCH §8 "Platform declarations". Bundle id `com.vecvel.danaview.share`, App Group `group.com.vecvel.danaview` on both targets, extension deployment target 15.0; video document types keep rank Owner; Android filters for `application/pdf`, Office MIME types, `text/*`, `image/*` on `VIEW`/`SEND`/`SEND_MULTIPLE`.
- **Acceptance criteria and tests:** `flutter build ios --no-codesign` and `flutter build apk` succeed; the extension appears in the share sheet on the simulator; video "Open with" behaves as in 1.1 (P-7); the backup rules parse (lint) and match ARCH §5.2.

#### INT-103 · [INTEGRATION] App wiring v4: search, AI search, settings routes and sections

- **Milestone:** N5 · **Lane:** Mac · **Area:** Integration
- **Depends on:** AIS-37, AIS-51, AIS-52, AIS-53, ST-04, HOM-19
- **Owns (Mac):** `lib/main.dart`, `lib/router/app_router.dart`, root `pubspec.yaml` (all extend AIS-37), `lib/adapters/{media_analysis_adapter,document_text_adapter}.dart`, `lib/wiring/search_wiring.dart`, `FEAT/more/settings_sections/search_index_section.dart`, `test/v12/wiring/search_wiring_test.dart`
- **Spec:** builds the search service (index store, extractors with the media-analysis and PDF-text adapters, scheduler) and the AI search flows (`onSearchWithAi` → `AiClient` plan → the one send view → filters, and deep indexing entry from folder menus); `/settings/ai` route and the Settings › AI Studio and Settings › Video editor rows (V2-20); settings sections for privacy (ST-04), library storage (HOM-17) and the search index (rebuild, delete, status); root pubspec adds `danaview_media_analysis`, `danaview_pdf`.
- **Acceptance criteria and tests:** the wiring test boots the app with fakes and reaches the Home search, AI search disclosure, deep-index disclosure, the settings sections and `/settings/ai`; with AI Studio off no AI entry is visible; macOS boots with the on-device index and no AI.

#### INT-105 · [INTEGRATION] Editor wiring v4: Home bridges, photo and montage intents, adapters

- **Milestone:** N5 · **Lane:** Mac · **Area:** Integration
- **Depends on:** INT-103, VED-01, VED-12, VED-14, VED-17, VED-28, HOM-11, HOM-12, HOM-22
- **Owns (Mac):** `lib/main.dart`, `lib/router/app_router.dart`, root `pubspec.yaml` (extend INT-103), `ED/app/editor_bootstrap.dart` (extends AIS-37), `lib/adapters/library_media_access_adapter.dart`, `lib/wiring/editor_home_bridges.dart`, `test/v12/wiring/editor_bridges_test.dart`
- **Spec:** Home callbacks (`onEditPhoto`, `onBatchEditPhotos`, `onMakeMontage`, `onOpenProjects`) wired to `EditorLauncher` intents; `danaview-library://` resolution for the editor's `MediaAccessPort` (V2-09) and `refs` registration in `library.db` when a project or `.dnphoto` references an entry; the face-tracking adapter (VED-16) and Beauty pack spec registered in the bootstrap; exports with destination "library" create entries (`sourceHint = editorExport`); root pubspec adds `danaview_face_tracking`.
- **Acceptance criteria and tests:** Home photo → Edit → export → new library entry; multi-select → montage project with the right order; delete warning for a referenced entry; editor hidden on desktop (v1.1 D-17 route tests still green).

#### INT-106 · [INTEGRATION] Privacy, terms and licences consolidation for 1.2.0

- **Milestone:** N5 · **Lane:** Mac · **Area:** Integration
- **Depends on:** AIS-36, INT-105, HOM-21, HOM-30, VED-13, VED-16, AIS-45
- **Owns (Mac):** `FEAT/more/legal_texts.dart` (extends AIS-36; last in the chain), `FEAT/more/danaview_licenses_screen.dart` (extends v1.1 if needed for new entries), `lib/licenses_v12.dart`, `test/v12/legal/legal_v12_test.dart`
- **Spec:** ARCH §9.5: Files & Media Home (Danaview folders, what backups include, Recently deleted, Share Extension, saved signatures stay on the device), the on-device search index (stored on device, excluded from backups, rebuild/delete), speaker model and Beauty pack downloads (hosts, sizes from AIS-44/VED-33), photo export metadata choices, AIS §6.4 "Added 2026-10-16" bullets, licences (sherpa-onnx, ONNX Runtime, speaker and face models, the HOM-27 library if any, Genkit if adopted), every bullet with its platform qualifier; `legalEffectiveDate` = release date. The owner reviews the text.
- **Acceptance criteria and tests:** every host of ARCH §9.1 appears in the policy (root host test); every new bullet has a platform qualifier; licences screen lists every bundled third-party component; no overflow at 280 px @ 1.35.

### 4.6 Cross-plan QA (QA-1xx)

QA tickets change no product code; defects become FIX tickets. Each report lives in `docs/v1.2/qa/`.

#### QA-101 · iOS Simulator E2E for 1.2.0 and the 1.1 suite re-run

- **Milestone:** N5 · **Lane:** Mac · **Area:** QA
- **Depends on:** INT-105, INT-106, HOM-32, AIS-38, AIS-54, VED-32
- **Owns (Mac):** `integration_test/v12/e2e/`, `scripts/ci/v12/e2e_ios.sh`, `docs/v1.2/qa/QA-101-ios.md`
- **Spec:** one simulator at a time (iPhone 17 Pro, then iPad Pro with keyboard). Cross-plan scenarios: (1) import a photo, PDF and video via picker and Share Extension → organise → delete → restore; (2) open PDF → merge, annotate, sign, compress → Save to Files; (3) photo → Still Photo Mode → tone, HSL, curves, mask, keystone, beauty → export HEIC to the library → Add to Video Project; (4) multi-select → montage → captions with speakers → karaoke → export; (5) search offline (index) → AI search with the loopback provider → deep index one folder; (6) speed test with Cloudflare blocked by the fake → consent → M-Lab fake; (7) flags off → the app equals 1.1; plus the v1.1 QA-00 and AIS-38/AIS-54 suites re-run.
- **Acceptance criteria and tests:** every scenario passes with evidence (screens, logs without user content); no non-loopback request (spy log).

#### QA-102 · Android Emulator E2E for 1.2.0 and the 1.1 suite re-run

- **Milestone:** N5 · **Lane:** Android · **Area:** QA
- **Depends on:** INT-105, INT-106, HOM-32, AIS-38, AIS-54, VED-32
- **Owns (Android):** `integration_test/v12/e2e_android/` (Android-only steps), `scripts/ci/v12/e2e_android.sh`; the report section is merged by the Mac into `docs/v1.2/qa/QA-102-android.md`
- **Spec:** QA-101's scenarios on the API 35 Pixel, API 29 and the tablet AVD (Share Extension → `SEND` intents; Save to Files → Save to Downloads), plus the API 28 AVD for the Home-only path (editor gated, Home works).
- **Acceptance criteria and tests:** as QA-101; deferred device-only items recorded, never faked.

#### QA-103 · Whole-app network guard and privacy-host consistency

- **Milestone:** N5 · **Lane:** Mac + Android · **Area:** QA
- **Depends on:** INT-105, INT-106, AIS-54, ST-03
- **Owns (Mac):** `test/v12/network/whole_app_guard_test.dart`, `integration_test/v12/network_spy/`, `docs/v1.2/qa/QA-103-network.md`
- **Spec:** ARCH §9: `HttpOverrides` spy through the real wiring plus a device-level spy on the simulator and emulator: a full session over every Home, document, editor, beauty, diarization (with the model present) and search flow with AI Studio off makes zero requests except the §9.1 rows the session starts (and only after their consent); with AI Studio on nothing goes out before Send; every send goes to the chosen host only; ML Kit, Vision, sherpa-onnx and the face runtime make no request; the privacy policy names every §9.1 host.
- **Acceptance criteria and tests:** spy logs attached; any unexpected request is a release blocker.

#### QA-104 · Performance and memory budgets on the device lab

- **Milestone:** N5 · **Lane:** Mac + Android · **Area:** QA
- **Depends on:** HOM-14, VED-31, VED-30, AIS-39, INT-105
- **Owns (Mac):** `integration_test/v12/perf/`, `docs/v1.2/qa/QA-104-performance.md`
- **Spec:** every ARCH §10.1 row not already certified by HOM-14, VED-31, AIS-39, AIS-44 or AIS-51, on the low and mid tiers (iPhone SE 2, iPhone 12, a 4 GB Android, a Pixel 7a or nearest available), with thermal state recorded; install sizes vs 1.1.0 (ARCH §10.3).
- **Acceptance criteria and tests:** budgets met or renegotiated in writing with the owner; size table recorded for AIS-41.

#### QA-105 · Overflow and accessibility matrix for every new surface

- **Milestone:** N5 · **Lane:** Mac + Android · **Area:** QA
- **Depends on:** INT-105, HOM-32, VED-28, ST-04
- **Owns (Mac):** `test/v12/overflow/`, `packages/danaview_editor/test/overflow/photo_beauty/`, `docs/v1.2/qa/QA-105-a11y.md`
- **Spec:** the v1.1 QA-09 method over every HOM, VED and ST surface and state (AIS surfaces are AIS-38's): widths 280–1280, text scale 0.85–1.35, computed contrast, targets ≥ 44 px; VoiceOver and TalkBack passes on the Home tabs, folder operations, the PDF tools, the photo tool tray, the beauty panel and the speed-test consent.
- **Acceptance criteria and tests:** matrix green (PR subset plus nightly full); a11y checklist complete.

#### QA-106 · Persistence, migration, originals and backup survival

- **Milestone:** N5 · **Lane:** Mac + Android · **Area:** QA
- **Depends on:** INT-105, INT-104, VED-15, VED-19, AIS-47, HOM-17
- **Owns (Mac):** `test/v12/persistence/`, `integration_test/v12/persistence/`, `docs/v1.2/qa/QA-106-persistence.md`
- **Spec:** 1.1 projects → schema 2 (with and without captions); schema 2 projects with `ph`, `bt`, lanes and easing opened by a 1.1.x build read-only (V2-V17); `.dnphoto` crash safety; `library.db` fault injection and rebuild-from-files; Recently deleted expiry with a fake clock across app restarts; originals unchanged (bytes and timestamps) after every flow; iOS device backup and restore and Android device-to-device transfer of Danaview folders (search index and signatures absent after restore, rebuilt index works).
- **Acceptance criteria and tests:** every case passes on both platforms with evidence; closes V2-V1 and V2-V17.

#### QA-107 · Release-candidate regression on lab devices

- **Milestone:** N6 · **Lane:** Mac + Android · **Area:** QA
- **Depends on:** QA-101, QA-102, QA-103, QA-104, QA-105, QA-106, AIS-40
- **Owns (Mac):** `docs/v1.2/qa/QA-107-rc.md`
- **Spec:** release builds with every flag on: launch and player preservation (P-1…P-8) on the iPhone 7 (iOS 15.8), iPhone 8 (iOS 16.7), iPhone SE 2, an iPad, an Android 10 and a current Android device; a smoke pass of every pillar; upgrade from 1.1.0 with existing projects, playlists, Continue watching and linked folders intact.
- **Acceptance criteria and tests:** no regression of a 1.1 feature; every pillar's smoke passes; results feed AIS-41's checklist.

---

## 5. Shared and integration file register

These are the only paths edited by more than one ticket. The order is mandatory: each later ticket depends (directly or through the graph) on the earlier one. "v1.0" means code that predates the editor and has no `// OWNER:` header.

| Path | Tickets, in order | What each 1.2.0 edit does |
|---|---|---|
| `packages/danaview_features/lib/src/more/legal_texts.dart` | UX-42 → **ST-05 → AIS-36 → INT-106** | speed-test providers → AI Studio text (AIS §6.4) → Home, documents, index, downloads, metadata, licences, effective date |
| `lib/main.dart`, `lib/router/app_router.dart`, root `pubspec.yaml` | INT-02/INT-04/INT-05 → **AIS-37 → INT-103 → INT-105 → AIS-41** | AI wiring, key store, `/settings/ai` → search and AI search wiring, settings sections → editor bridges, adapters → the version stays `1.0.0+1` (owner decision 2026-10-22) |
| `test/architecture/dependency_rules_test.dart` | INT-01 → **AIS-01 → INT-101 → AIS-43** | rules 9–15 → rules 20–31 → rules 16–19 (rule 17 replaces 13) |
| `.github/workflows/editor-ci.yml` | INT-01 → **AIS-01 → INT-101** | `ai-dart` job → `v12-dart`, `v12-flutter`, `home-preservation` jobs |
| `ED/editor/contracts/{action_ids,inspector_routes,tool_ids}.dart`, `ED/editor/wiring/action_bindings.dart` | UX-01 → **AIS-01 → INT-101** | AIS action ids and sections → photo, beauty, compare, To video, batch ids; beauty inspector and photo tool routes; merge of `photo_bindings.dart`, `beauty_bindings.dart` |
| `packages/danaview_editor/pubspec.yaml` | UX-01 → **AIS-01 → AIS-43** | AI Studio and providers → `danaview_ai`, `danaview_ai_ui` |
| `CORE/lib/src/ops/edit_command.dart` | CORE-09 → **AIS-01 → INT-101** | `part` files for rich-cue and AI commands → photo bridge, beauty and easing commands |
| `CORE/lib/src/model/items.dart`, `CORE/lib/src/validate/` | CORE-03 / CORE-08 → **AIS-02 → VED-15** | rich cue fields, I10/I11 → `ph`, `bt`, I12 |
| `CORE/lib/src/model/subtitle.dart` | CORE-03 → **AIS-02 → AIS-47** | rich track fields → speaker lanes |
| `CORE/lib/src/codec/project_json.dart` | CORE-22 → **AIS-04 → VED-15** | schema 2 → `ph`, `bt`, `e` encoding (same schema 2, V2-03) |
| `CORE/schema/project.v2.schema.json` | **AIS-04 → VED-15** | schema 2 → photo, beauty and easing definitions |
| `CORE/lib/src/plan/lowering_text.dart` | CORE-31 → **AIS-14 → AIS-47** | karaoke layers, placement → lane stacking |
| `CORE/lib/src/formats/` (SRT/VTT files) | CORE-20 → **AIS-07 → AIS-47** | codec v2 → lane group export |
| `CORE/lib/src/plan/lowering_visual.dart` | CORE-30 → **VED-15 → VED-19** | photo stages for image clips and `layer.beauty` → eased keys lowered to grid keys |
| `CORE/lib/src/plan/render_ranges.dart` | CORE-37 → **VED-15** | beauty counts as heavy |
| `CORE/lib/src/plan/{render_plan,plan_json,plan_validator}.dart` | CORE-29 → **INT-102** | RenderPlan v2 additive fields |
| `CORE/lib/src/model/keyframes/{keyframe_data,property_keys}.dart` | CORE-03 / CORE-05 → **VED-19** | easing per key; `beauty.*` property keys |
| `API/lib/src/fake/`, `API/test/contract/` | API-01 → **AIS-24 → INT-102** | font pick in the fake → still, face tracking, capabilities in the fake and contract kit |
| `API/lib/src/capabilities.dart` | API-01 → **INT-102** | still, half-float, beauty tier, segmentation capabilities |
| `API/lib/src/reference/reference_renderer.dart` | API-03 → **INT-102** | pass registry call (passes added in their own files) |
| `ENGP/pigeons/engine_api.dart`, `ENGP/lib/src/pigeon/`, `ENGP/ios/Classes/Pigeon/`, generated Kotlin, `ENGP/lib/src/mobile_editor_engine.dart`, `ENGP/ios/Classes/Glue/` | ENG-01/ENG-06/ENG-07/INT-06 → **AIS-24 → INT-102** | font pick kind → still host API, still export job, capabilities, landmark and mask assets |
| `ENGK/glue/` | ENG-08/INT-06 → **AIS-24 (Android half) → INT-102A** | font pick → v2 glue |
| `ENGP/ios/Classes/Plan/`, `ENGP/ios/Classes/Render/LayerRenderer.swift` | IOS-08, IOS-10 → **INT-102** | v2 decode; registry hook |
| `ENGK/plan/`, `ENGK/effects/LayerEffectChainFactory.kt` | AND-08, AND-09 → **INT-102A** | v2 decode; registry hook |
| `ED/app/editor_launcher.dart` | UX-41 → **VED-01** | photo, batch and montage intents |
| `ED/app/editor_bootstrap.dart` | INT-02 → **AIS-37 → INT-105** | AI Studio service → face tracking, Beauty pack, library media access |
| `ED/editor/panels/keyframes_panel.dart` | UX-26 → **VED-19** | easing control |
| `ED/editor/photo/export/photo_export_sheet.dart` | **VED-29 → VED-13** | export sheet → metadata switches |
| `packages/danaview_transcription/lib/src/catalog/` (new files only) | AI-08 → **AIS-45 → VED-16** | speaker model specs → Beauty pack spec |
| `FEAT/library/danaview_home_screen.dart` | v1.0 → **HOM-05** | tab shell behind `DANAVIEW_FILES_HOME` |
| `FEAT/library/search/library_search_field.dart` | **HOM-19 → AIS-51** | name search → index search and the "Search with AI" entry |
| `FEAT/more/danaview_settings_screen.dart` | v1.0/UX-04 → **INT-101** | settings section slots |
| `packages/danaview_features/pubspec.yaml` | v1.0 → **INT-101** | library, native, documents, search |
| `packages/danaview_search/pubspec.yaml` | **INT-101 → AIS-52** | skeleton → `danaview_ai` |
| `packages/danaview_platform/lib/src/incoming_media_bridge.dart`, `FEAT/player/danaview_player_actions.dart` | v1.0 → **HOM-21** | documents and photos go to import; "Save to Danaview folder" |
| `test/home_screen_test.dart` | v1.0 → **HOM-06** | flag-off/flag-on preservation cases |
| `LN/android/src/main/AndroidManifest.xml` | **HOM-02A → HOM-22A** | plugin manifest → its `FileProvider` |
| `PDF/android/build.gradle.kts` | **HOM-25 → HOM-28A** | plugin build → the HOM-27 library, only if chosen |
| `ios/Runner.xcodeproj/project.pbxproj`, `ios/Runner/{Runner.entitlements,PrivacyInfo.xcprivacy,Info.plist}` | INT-01/INT-03 → **INT-104** | Share Extension target, App Group, document types, photo usage string |
| `android/app/src/main/AndroidManifest.xml`, `android/app/src/main/res/xml/danaview_*_rules.xml` | CORE-28/INT-03 → **INT-104** | intent filters, media permissions; library backup rules |
| `docs/v1.2/ARCHITECTURE.md` | this document → **AIS-01 → INT-101 → INT-102 → AIS-41** | AIS decision status → rule records, Q-N5 → §6.3 field names, Q-N1/Q-N2 → release status and [VERIFY] closures |
| Placeholder files (§0.2) | skeleton ticket → owner ticket | the owner replaces the placeholder |

`danaview_features` tickets add only optional parameters and callbacks, so the app keeps compiling before the integration tickets wire them (the v1.1 pattern).

## 6. Feature coverage (owner's lists → tickets)

Every owner feature of the four plans maps to the tickets that build it and the QA ticket that certifies it.

### 6.1 Files & Media Home (roadmap Pillar 1, HOM plan §1–§9)

| Feature | Tickets |
|---|---|
| Player hub, Continue watching, quick actions, playlists, linked folders, queue, streams, drag-and-drop preserved | HOM-05, HOM-06, HOM-07, HOM-08, HOM-15, QA-107 |
| Filters All / Videos / Photos / Documents; document sub-filters | HOM-16, HOM-18, QA-101, QA-102 |
| Photos tab: masonry grid, albums, system library with limited/partial access | HOM-02, HOM-02A, HOM-10, HOM-04, HOM-04A |
| Desktop photo folders, sidebar, external drives, drag and drop | HOM-03, HOM-08 |
| Recent photos tray on Overview | HOM-09 |
| Fullscreen photo viewer, EXIF sheet, Edit in Editor | HOM-11, INT-105 |
| Badges (duration, resolution, fps, RAW, HDR, Live) | HOM-13 |
| Multi-select: Make video montage, Play in Player, Add to playlist, Batch edit | HOM-12, VED-14, VED-12, INT-105 |
| Danaview folders: app-private, nested, mixed types, included in backups | HOM-17, HOM-18, INT-104, QA-106 |
| Recently deleted for 30 days, Restore, Empty now | HOM-17, HOM-18, QA-106 |
| Favourites, recents, name search, sort per folder | HOM-19 |
| Import from Photos/Gallery and Files, originals never modified | HOM-20, HOM-20A, HOM-32, QA-106 |
| "Open with Danaview" and the iOS Share Extension | INT-104, HOM-21, HOM-21A |
| File actions and the multi-select bar | HOM-22, HOM-22A |
| Save to Files, Save to Downloads, share, Open in another app | HOM-22, HOM-22A |
| Native viewers: photos, the existing player, PDFKit, `PdfRenderer`, Quick Look; Android text/CSV viewer and Office file card | HOM-23, HOM-24, HOM-25, HOM-26 |
| PDF tools: merge, split, reorder, rotate, delete pages | HOM-27, HOM-28, HOM-28A |
| Annotate and highlight | HOM-29, HOM-29A |
| Sign (saved signatures on device) | HOM-30, HOM-30A |
| Compress | HOM-31, HOM-31A |
| No Office editing; Windows/Linux PDF viewing and tools in 1.3.0 | (non-goals, ARCH §1.3, V2-124) |
| 50,000-item scale, 10,000 documents | HOM-14, HOM-32, QA-104 |
| Editor actions only where the editor runs | HOM-05, HOM-11, HOM-12, INT-105 |
| Search over document text, OCR, captions (with the index) | AIS-50, AIS-51 |

### 6.2 AI Studio and rich subtitles (roadmap Pillar 2, AIS plan §5.7)

AIS plan §5.7 maps every owner bullet (groups 1–11 and the rules) to AIS tickets and stays authoritative. Cross-plan additions:

| Feature (AIS §5.7 group) | AIS tickets | Plus in this plan |
|---|---|---|
| 1 BYO key, five providers, settings, Keychain/Keystore, off = v1.1 behaviour | AIS-08…AIS-11, AIS-31, AIS-37 | QA-103 (whole-app guard) |
| 2 Clean-up, emotion (text and voice), emoji, emotion styles, speakers | AIS-28, AIS-29, AIS-32, AIS-33 | QA-101, QA-102 |
| 3 Translation as a new track, timing, RTL, export | AIS-30, AIS-35, AIS-13, AIS-22, AIS-14, AIS-21 | — |
| 4 Transcript view, rich styling, placement, karaoke, timing tools, emoji tools, review | AIS-12…AIS-21, AIS-33 | QA-101 scenario 4 |
| 5 Ask AI with presets and free text, diff review | AIS-30, AIS-34 | — |
| 6 Fonts: bundled scripts, import, picker | AIS-22…AIS-25 (+ AIS-27 conditional) | INT-106 (licences) |
| 7 Subtitle presets | AIS-23, AIS-26 | — |
| 8 Multi-speaker transcription, overlaps, lanes, cloud diarization | AIS-44…AIS-49 | INT-106 (model text), QA-103 |
| 9 On-device search index, AI search (a) and (b) | AIS-50…AIS-53 | INT-103 (wiring, settings), HOM-19 (fallback), QA-101 scenario 5 |
| 10 Shared `danaview_ai` layer, one switch | AIS-43 | V2-20 paths |
| 11 Genkit spike, all or nothing | AIS-42 | — |
| Rules: UI, schema 2, privacy and terms | AIS-01, AIS-04, AIS-36, AIS-37, AIS-38 | V2-03 (one schema), INT-106, QA-105 |

### 6.3 Unified Photo & Video Editor (roadmap Pillar 3, VED plan §3–§6)

| Feature (VED section) | Tickets |
|---|---|
| Intent routing: Still Photo Mode vs timeline (§3.1) | VED-01, INT-105 |
| `.dnphoto` non-destructive recipes (§3.2) | VED-02, QA-106 |
| Shared GPU pipeline, effect order (§3.3) | INT-102, INT-102A, VED-03, VED-03A |
| 16-bit half float, P3 (§3.4) | VED-04, VED-04A |
| Tiled 60 fps viewport (§3.4, §6.1) | VED-05, VED-05A |
| Exposure, contrast, highlights, shadows, whites, blacks, clarity, dehaze, vignette, grain, clipping warnings (§4.1) | VED-06, VED-06A |
| White balance, vibrance, 8-band HSL with TAT (§4.2) | VED-06, VED-07 |
| Spline RGB and channel curves with histogram (§4.3) | VED-08 |
| Crop, aspect ratios, auto-straighten, keystone (§4.4) | VED-09, VED-09A |
| Linear, radial, brush and luminance masks with local adjustments (§4.5) | VED-10, VED-10A |
| Text, stickers, borders, date stamps (§4.6) | VED-11 |
| Presets, copy/paste, batch export (§4.7) | VED-12 |
| EXIF/IPTC keep and strip (§4.7, D-129) | VED-13, VED-13A |
| High-resolution export JPEG/PNG/WebP/HEIC (§3.4, §5.8) | VED-29, VED-29A, VED-31 |
| Add to Video Project with Ken Burns (§4.8) | VED-14, VED-15 |
| `BeautyEffectSpec` in projects (§3.2, D-136) | VED-15 |
| Face shape and slimming (§5.1) | VED-20, VED-20A |
| Eyes and eyebrows, lashes (§5.2) | VED-21, VED-21A |
| Nose and lips, smile (§5.3) | VED-22, VED-22A |
| Skin retouching, blemishes, teeth (§5.4) | VED-23, VED-23A |
| Virtual makeup, lenses, hair colour, freckles (§5.5) | VED-24, VED-24A |
| Body reshaping (§5.6) | VED-25, VED-25A |
| Beauty filters, portrait bokeh, AR stickers (§5.7) | VED-34, VED-34A |
| Before/after split and press-and-hold (§5.7, §6.3) | VED-27 |
| Intensity, per-category bypass, undo/redo (§5.7, D-144) | VED-26, VED-18 |
| 468/478-point landmarks, One-Euro smoothing, occlusion fade (§3.5) | VED-33, VED-33A, VED-16, VED-16A, VED-17, VED-17A |
| Background pre-tracking `.dnface` (D-135) | VED-17, VED-17A |
| Up to 4 subjects with independent settings (§3.6) | VED-18, VED-26 |
| Keyframable beauty with linear and bezier easing (§3.6, D-134) | VED-19 |
| Automatic enhancement, preset styles, recipes (§5.8) | VED-28 |
| Inspector "Beauty & Retouching" tab (§6.2) | VED-26 |
| Low-tier proxies (D-142) | VED-26, VED-15 (heavy ranges) |
| 4K export with beauty, memory stress, golden parity (§8 phase 3) | VED-30, VED-31, VED-32, QA-104 |
| On-device only (D-143) | VED-16 (consented pack), QA-103 |

### 6.4 Speed-test fallback (ST plan §1)

| Goal | Tickets |
|---|---|
| G1 $0 running cost | ST-01, ST-02 (public endpoints only) |
| G2 Resilient failover on 429/403/stall/connection failure | ST-03 |
| G3 Quiet UI with no provider names | ST-04 |
| G4 Honest privacy: both providers named; M-Lab only after consent | ST-02, ST-04, ST-05, INT-106, QA-103 |
| G5 Honest numbers: one provider per phase, notes in details | ST-03, ST-04 |

### 6.5 Cross-cutting rules

| Rule | Tickets |
|---|---|
| Owner UI rules on every surface | every UI ticket's matrix tests, INT-101 (Material ban), QA-105 |
| Originals never modified | HOM-20, HOM-28, HOM-32, VED-29, QA-106 |
| Network inventory closed, nothing silent | AIS-37, AIS-54, QA-103 |
| One project schema, lossless upgrade, 1.1.x read-only | AIS-04, VED-15, QA-106 |
| Install-size records | AIS-22, AIS-44, VED-33, HOM-27, QA-104, AIS-41 |

## 7. Effort per milestone

Planning estimates in **builder-days** (one autonomous builder working one ticket; small ≈ 1 day, medium ≈ 2, large ≈ 3–4), from the plans' own figures where they give them (HOM documents ≈ 2–2.5 weeks with two lanes; ST ≈ 1.5–2 days) and from v1.1's ticket pace otherwise. Calendar ranges assume about three parallel builders on the Mac and one or two on the Windows laptop; milestones overlap where lanes allow (N2 runs alongside N1 and N3).

| Milestone | Tickets | Mac / Android / both | Large tickets (≥ 1,000 lines expected) | Builder-days | Calendar |
|---|---|---|---|---|---|
| N0 Foundations and day-1 spikes | 9 | 6 / 2 / 1 | INT-101 | ≈ 20 | 1–1.5 weeks |
| N1 Files & Media Home, documents, speed test | 42 | 32 / 10 / 0 | HOM-17, HOM-20, HOM-21, HOM-24, HOM-25, HOM-28, HOM-28A | ≈ 75 | 3–4 weeks |
| N2 AI Studio, rich subtitles, speakers, search | 44 | 40 / 0 / 4 | per AIS plan §6.5 (AIS-04, -08, -09, -10, -11, -13, -17, -18, -25, -28, -30, -32, -43, -45, -46, -47, -50, -53) | ≈ 100 | 5–7 weeks (from N0's end, parallel with N1) |
| N3 Still Photo Mode | 26 | 17 / 9 / 0 | INT-102, VED-03, VED-06, VED-10, VED-29 | ≈ 55 | 3–4 weeks |
| N4 Beauty & Retouching Suite | 23 | 14 / 9 / 0 | VED-16, VED-17, VED-20, VED-23, VED-24, VED-26 | ≈ 60 | 3–5 weeks |
| N5 Integration and QA | 20 | 6 / 1 / 13 | INT-105, QA-101, QA-102 | ≈ 40 | 2–3 weeks |
| N6 Release | 2 | 1 / 0 / 1 | — | ≈ 4 | about 1 week (with store review preparation) |
| **Total** | **166** (165 unconditional) | 116 / 31 / 19 | | **≈ 355** | **≈ 14–18 weeks** end to end |

The longest chain (§2, 16 tickets) sets the floor; the beauty lane (VED-33A → VED-33 → INT-102 → … → VED-30 → VED-32) is the second-longest and the largest native unknown, followed by the Android PDF write path (HOM-27 → HOM-28A).

## 8. Corrections and amendments made while sequencing

These were contradictions or ordering problems found while merging the four plans; ARCH §14 lists the reasoning, and the plan tickets are amended as follows (in addition to §4.1).

1. **One schema** (ARCH V2-03): VED-15 extends AIS-04's schema 2 instead of adding schema 3; it moves from the VED plan's phase 2 to N3 and also carries the photo recipe on image clips, so VED-14 can carry recipes (C-9).
2. **HOM-27** runs on day 1 in `spikes/android_pdf/` and depends only on INT-101 (was HOM-24); HOM-28 records its report in `docs/` because the Windows lane doesn't edit docs (C-11).
3. **HOM-11 and HOM-12** expose optional callbacks instead of depending on editor tickets; INT-105 wires them (C-10).
4. **VED-12** depends on VED-29 (batch export needs the exporter) (C-25).
5. **VED-16** no longer depends on VED-03 (the plan's dependency); it depends on the VED-33 spike and INT-101, and its tracker is a separate `danaview_face_tracking` plugin for 1.3.0 reuse (C-29).
6. **VED-20…VED-25** gain the Android halves `VED-20A…VED-25A`; VED-21 and VED-22 depend on VED-20 (shared mesh warp); their scopes cover every bullet of VED §5.1–§5.6, not only the plan's short titles.
7. **New tickets:** VED-33/33A (face runtime spike, C-7, C-26), VED-34/34A (§5.7 filters, bokeh and stickers had no ticket), the remaining `A` halves (Android lane), INT-101…INT-106 and QA-101…QA-107.
8. **VED-01** owns `editor_launcher.dart` (extends UX-41); the photo controller is VED-03's because every tool needs it.
9. **ST-01** cites the real test file `test/network_tools_test.dart` (C-22).
10. **HOM-04** encodes JPEG/HEIC on Apple and WebP on Android (C-21); HOM-26 owns document thumbnails on Apple.
11. **HOM-17** doesn't edit the app's Android backup XML (INT-104 does, after CORE-28); it owns the library side and the Settings note.
12. **AIS-50** writes `search.db`, not tables inside `library.db` (C-5).
13. **The AIS milestones S1–S6** map to N0/N2/N5/N6 as §4.1 lists (C-28); AIS-42 and AIS-43 sit where their dependencies put them (C-30).

## 9. Validation

The ticket graph of §3 was generated from one table and checked by script: 166 unique ids; every dependency is a 1.2.0 ticket earlier in the list or a v1.1 ticket; no ticket depends on a later milestone; HOM-01…HOM-32, AIS-01…AIS-54, VED-01…VED-34 and ST-01…ST-05 are all present; the longest chain is the one in §2. Ownership was checked by hand against the code on `editor-wip` @ `c2ee137` (v1.1 `// OWNER:` headers) and against §5: no path is owned by two tickets except the register rows, in their order.
