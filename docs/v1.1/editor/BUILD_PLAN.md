# Danaview Editor: Build Plan

> **Release:** Danaview 1.1.0 "Editor". **Date:** 2026-10-07. **Baseline:** `main` @ `19cae59`.
> **Authority:** `docs/v1.1/editor/ARCHITECTURE.md` wins over this plan; this plan wins over the area designs in `docs/v1.1/editor/design/`. Section references like "ARCH §11.2" point into ARCHITECTURE.md; "domain.md §6.2", "native.md", "ux.md", "ai.md" point into the area designs, which remain the detailed reference wherever a ticket says so — except that ARCHITECTURE.md overrides them (notably ARCH §11 overrides native.md §4.2: the RenderPlan is a flat, fully lowered layer list).
> **Size:** 166 tickets in 7 internal milestones (M0–M6), two of them conditional (AND-16 only on an AND-01 no-go, UX-43 only on a QA-04 budget miss). Everything ships together in one release; milestones only order the work.
> **Revision:** 2026-10-08, after the architecture review; every resolution and every rejected point is listed in §11. 2026-10-11: the owner's D-43(e) decision added six tickets (CORE-37, UX-44, IOS-19, IOS-20, AND-18, AND-19; ARCH D-45) and amended AND-16, AND-11, IOS-11, IOS-12, UX-18 and UX-04 (§9). Later on 2026-10-11 two more M4 tickets followed from the same decision: INT-06 (the engine interface additions for render preview, a lead-approved amendment of the frozen Pigeon surface) and CORE-38 (edits are no longer blocked above the live-preview cap) (§9 item 12).
> **Validation:** the ticket graph below was checked by script (re-run after the review edits): every dependency exists, the graph is acyclic, no ticket depends on a later milestone, every prefix of §5 is dependency-complete, no two tickets own the same file except the integration tickets in §7, and every owner feature bullet maps to at least one ticket (§8).

---

## 1. How to work a ticket

1. **Read first:** ARCHITECTURE.md §1–§4 and the sections your ticket cites, then the cited area-design sections. Read the existing code you integrate with (search the repo) before changing interfaces.
2. **Size:** each ticket is sized for one autonomous engineer, roughly 300–1,500 hand-written lines (generated code, vendored code, binary fixtures and goldens don't count). If a ticket clearly exceeds that, split it inside your own owned files; never spill into files you don't own.
3. **Stay inside `owns`.** You may create or edit only the files and directories your ticket owns (§2), plus files whose header says `// OWNER: <your ticket>` (placeholders created for you by a skeleton ticket). Need something from another ticket's file? Depend on it; if it's missing or wrong, report it as a defect against that ticket instead of editing it.
4. **Definition of done** (every ticket):
   - `dart analyze --fatal-infos` / `flutter analyze` clean for every package you touched; new code has dartdoc on public APIs.
   - All acceptance criteria met with automated tests where the criterion is testable; manual or device-only criteria are recorded in the PR description (device, OS, numbers, screenshots).
   - Existing tests stay green (`flutter test` at the root and in every touched package; native unit tests for native tickets).
   - The CI script for your area (`scripts/ci/editor/*.sh`, owners in INT-01's README) passes locally.
   - UI tickets: no Material chrome (ARCH §1.3; the architecture test enforces it), custom kit components only, Figtree only for chrome, dark UI, computed contrast, and **no overflow** at widths 280–1280 and text scale 0.85–1.35 using `test/support/` SurfaceMatrix helpers for every surface and state you add.
   - Pure-Dart tickets keep `danaview_editor_core` free of `package:flutter` and of `dart:io` outside `lib/src/store/` (purity test).
   - Nothing logs media paths, transcript text or user content.
   - Every [VERIFY] item your ticket owns (ARCH §24.2) is answered in the PR and, for integration tickets, recorded in ARCHITECTURE.md.
5. **Flags.** `DANAVIEW_EDITOR` (entry points) and `DANAVIEW_AUTO_CAPTIONS` (captions UI) are compile-time `--dart-define`s that default to false (D-31). There is no desktop teaser flag (D-17). Never flip defaults in code; INT-05 passes them in release builds. Run with `--dart-define=DANAVIEW_EDITOR=true` (and `DANAVIEW_AUTO_CAPTIONS=true`) during development.
6. **Platforms.** The editor runs on iOS (15.0+, Metal) and Android (API 29+, GLES 3, ≥ 2 GB RAM); devices below 3 GB run the `minimal` tier (D-40). Desktop builds must keep compiling with the editor hidden (D-17). The iOS simulator and Android emulator are the default verification targets; follow the memory notes for the simulator (tap duration 0.1 s, no parallel tap + screenshot, use `flutter attach` for VM evaluation). iOS 15/16 simulator runtimes are not available for Xcode 26.6, so criteria that need iOS 15 or 16 run on the lab's iPhone 7 (iOS 15.8.x) and iPhone 8 (iOS 16.7.x) (D-41); the oldest simulator runtime is iOS 18.2.
7. **Time.** Any code that turns a platform clock or presentation time into a frame uses `frameIndexNearest` and evaluates at `timeOfFrame(k)` (ARCH §5, D-35). Never compare a raw platform µs with a plan edge.
8. **Defects found later** (by QA or another ticket) are fixed in follow-up `FIX-<ticket>-<n>` tickets that own exactly the files of the original ticket that need changing; the original owner's rules apply.

## 2. Ownership rules

- **Exclusive ownership.** Each path in a ticket's `owns` list belongs to that ticket only. A path ending in `/` means the whole directory. Tests are owned explicitly (listed in `owns`); keep new test files inside your owned test directories or prefixed by your owned class names (native tests: one directory per ticket under `example/ios/RunnerTests/<Topic>/`, `android/src/test/kotlin/com/vecvel/danaview/editor/engine/<topic>/` and `android/src/androidTest/kotlin/com/vecvel/danaview/editor/engine/<topic>/`).
- **Skeleton tickets and placeholders (D-33).** CORE-01 (every file exported by the core barrels), CORE-09 (the command `part` files), API-01 (plan sync/transport, math, reference, render prep), ENG-01 (the Dart `mobile_*` files), ENG-07 (every iOS service class of ARCH §4.4 returning `notSupportedOnDevice`), ENG-08 (every Android service class of ARCH §4.4 returning `notSupportedOnDevice`), AI-02 (whisper runtime, loader, device, podspec, Gradle, plugin classes), AI-08 (transcription subsystems and `catalog/tuning.dart`) and UX-01 (every danaview_editor file in ARCH §4.6, every `actions/bindings/<feature>_bindings.dart`, `assets/looks/`, and the `danaview_editor_fonts` pubspec) create placeholders for files that later tickets own. A placeholder holds only the declared public names (throwing `UnimplementedError`, a "not available yet" widget, a native stub, or an empty library) and the header `// OWNER: <ticket>`. Placeholders are not listed in the skeleton ticket's `owns`; after the skeleton lands only the named owner edits them.
- **Barrels and entry points never change after their skeleton ticket.** `danaview_editor_core` barrels export the files in ARCH §4.3 (a directory is exported through `<dir>/<dirname>.dart`, owned by that directory's ticket). A ticket that needs more public files re-exports them from one of its own files.
- **Per-feature files instead of shared files.** Each danaview_editor feature ticket owns its own `lib/src/editor/actions/bindings/<feature>_bindings.dart` (merged by UX-01's `wiring/action_bindings.dart`) and its own `lib/src/app/strings/<feature>_strings.dart`. There is no shared strings file and no shared bindings file.
- **Dependencies (pubspec/Gradle/podspec).** Each package manifest is owned by its skeleton ticket, which declares every dependency the package needs in this release (ARCH §4). Adding an unplanned dependency requires a lead-approved integration change; don't edit another ticket's manifest.
- **Commands are self-dispatching.** Each `EditCommand` subclass implements its own `applyTo`/`previewOn` inside its group's `part` file, so command tickets never edit `edit_command.dart`.
- **Native glue is frozen after ENG-06.** ENG-01 defines the Pigeon surface, ENG-07/ENG-08 write the glue, and ENG-06 applies the spike outcomes and freezes both after IOS-01 and AND-01 report (D-42). Service tickets implement the service classes the glue already calls; Pigeon or glue changes after ENG-06 need a new lead-approved [INTEGRATION] ticket.
- **Integration tickets** (marked [INTEGRATION]: INT-01…INT-06, ENG-06, and CORE-28's two-attribute touch of the app manifest), plus CORE-38's change to two CORE-09 files (§7), are the only tickets that edit files owned elsewhere or shared app-root files, in the order of §7.

## 3. Milestones

| Milestone | Name | Scope | Exit criteria | Tickets |
|---|---|---|---|---|
| **M0** | Foundations and contracts | iOS target 15.0, editor CI, pure core types, RenderPlan v1 contract and fixtures, engine API + fake, plugin scaffold split into Pigeon/Dart engine (ENG-01), iOS glue (ENG-07), Android glue (ENG-08) and example host + CI (ENG-09), test media, whisper vendoring + C ABI, transcription contracts, UI kit additions, danaview_editor skeleton, Home edit button, orientation stack. | Every new package analyzes and tests green in danaview-ci; contract fixtures (incl. the grid-cut fixture) committed; FakeEditorEngine passes the contract kit; Home button hidden behind DANAVIEW_EDITOR; the owner's sign-off on the D-43 platform narrowings (a)–(d), (f) is recorded in ARCH D-43. | 21 |
| **M1** | Editing core and de-risking spikes | All editing commands, visual packing and layer limits, snapshot history and transactions, SRT/VTT and .cube formats, geometry and text animation evaluation, render-math and audio-mix reference + goldens, iOS and Android engine spikes (started on day 1 in spike hosts) with go/no-go, Pigeon/build config frozen after the spikes (ENG-06), whisper shim with host tests, device channel. | Every ARCH §7.2 command implemented with goldens; spikes answered every [VERIFY] they own; Android go/no-go recorded and, on no-go, the owner's sign-off on AND-16's degradations (D-43e) recorded (done: owner decision 2026-10-11, ARCH D-43(e), D-45); whisper host tests green (TSan/ASan). | 22 |
| **M2** | Persistence, RenderPlan compiler, native media services, speech core | Project codec/migrations/atomic store/repository/autosave/recovery/media pool/relink/GC, full compiler + diff + export settings, PlanSync, text sprites, Dart service glue, probe/thumbnails/waveforms/speech audio/proxies/freeze/reverse on iOS and Android, whisper native builds, model store/downloader, transcript cache, segmenter, timeline mapping, iOS segmented writer/job interruption and audio gain tap. | Core persistence survives fault injection; compile goldens for every lowering row; media services pass native tests on simulator and emulator; whisper builds for both platforms and the app still launches on the iOS 15.8 and 16.7 lab devices. | 34 |
| **M3** | Editor shell, timeline and live preview | Projects screen, new project/import, editor layout, controller/transactions, timeline (viewport, canvas, headers, gestures, move/trim/split/ripple/clipboard, markers), transport/playhead, action registry + shortcuts, toolbar + inspector host, preview surface + text overlay + manipulation, thumbnail/waveform caches, native composition/compositor/preview sessions, Android paused-frame renderer (and the contingency engine only on an AND-01 no-go), app wiring v1, model fuzzer. | On the iOS simulator and Android emulator with DANAVIEW_EDITOR=true: Home -> Projects -> editor with live frame-accurate preview; timeline edits reflected in preview within budget (Android structural budgets per ARCH §13.4); fuzz-lite green. | 32 |
| **M4** | Editing features and native export | Transform/crop/mask, adjust/filters/LUT, speed, keyframes, transitions, PiP/chroma, format/project/history, text, subtitles + SRT/VTT, audio, voiceover, freeze/reverse/replace/tasks, media bin + drag and drop, export pipelines (iOS on the segmented resumable writer, Android, Dart glue), multi-pass export precompose on both platforms, render-preview cache (core model, engine interface additions INT-06, UI, iOS and Android renderers), edits allowed above the live-preview cap (CORE-38), recorder, pickers, drop targets, whisper runtime and orchestrator. | Every owner feature except the export sheet, captions UI, media-health flows and the player entry works end to end on simulator/emulator; native export passes conformance on both platforms, including projects without audio; a project above the device's decoder limit exports through the precompose and matches a single pass (D-45). | 32 |
| **M5** | Export UI, auto captions, media health, player entry, legal, platform declarations | Auto captions flow + regenerate, export sheet, relink/recovery/migration UX, player Edit + handoff, privacy/terms/licences, iOS background export + Android FGS, iOS Info.plist/entitlements/privacy manifest, app wiring v2. | Complete feature set wired in the app behind the flags; privacy text matches the model host. | 10 |
| **M6** | Hardening, QA and release | On-device E2E on iOS Simulator and Android Emulator, parity/accuracy/A-V, export conformance + preset matrix + audio measurements, performance budgets, soak, AI eval and AI E2E, accessibility, overflow matrix, persistence survival, core benchmarks, conditional tile cache, release. | ARCH §23 release checklist complete with evidence; release builds pass DANAVIEW_EDITOR=true and DANAVIEW_AUTO_CAPTIONS=true. | 15 |

## 4. Critical path and parallel lanes

**Longest dependency chain** (24 tickets; unchanged after the review edits, re-computed by script): INT-01 → CORE-01 → CORE-02 → CORE-04 → CORE-03 → CORE-05 → CORE-08 → CORE-09 → CORE-10 → CORE-16 → CORE-31 → CORE-32 → API-02 → UX-08 → UX-14 → UX-18 → UX-19 → UX-31 → UX-37 → UX-38 → INT-04 → QA-00 → QA-01 → INT-05.

**Lanes that run in parallel** once M0 lands:
- **Core lane** (CORE-xx, pure Dart, `dart test` only): commands → persistence → compiler. Unblocks everything else through types and fixtures; CORE-29 (plan contract) is deliberately in M0.
- **Engine lane** (API-xx, ENG-01…09): contract + fake first so UI work never waits on native code; ENG-01 (Pigeon + Dart engine + minimal native plugin placeholders) → ENG-09 (example host + CI) → ENG-07 (iOS glue) and ENG-08 (Android glue) in parallel → ENG-06 freeze after the spikes.
- **iOS lane** (IOS-xx) and **Android lane** (AND-xx): **IOS-01 and AND-01 start on day 1** in throwaway spike hosts (`spikes/ios_engine/`, `spikes/android_engine/`; no dependencies; self-generated media until ENG-05 lands) and must report before ENG-06 freezes the Pigeon surface (D-42); then media services (incl. IOS-17 segmented writer and IOS-18 audio tap), then composition/compositor/preview (Android: AND-17 paused-frame renderer; AND-16 only on an AND-01 no-go, adding about 3 weeks to the Android lane), then export and platform services.
- **AI lane** (AI-xx): vendoring and C shim in parallel with core; the orchestrator (AI-13) needs the runtime, the stores and CORE-15.
- **UI lane** (UI-01, UX-xx): skeleton in M0; shell/timeline/preview in M3 against fakes; panels in M4; flows and entry points in M5.
- **Integration** (INT-xx): INT-01 first; INT-02 makes the editor reachable in the app in M3; INT-06 (render-preview engine interface additions) in M4; INT-03/INT-04 in M5; INT-05 last.
- **QA** (QA-xx): M6, after the features they certify; QA tickets don't change product code (defects become FIX tickets).

## 5. Ticket index (dependency-ordered)

A valid execution order: any prefix of this list has all its dependencies satisfied.

| # | Ticket | Milestone | Area | Title | Depends on |
|---|---|---|---|---|---|
| 1 | **INT-01** | M0 | Integration | Repo foundations: iOS 15.0 target, dependency rules, editor CI | — |
| 2 | **CORE-01** | M0 | Core (pure Dart) | danaview_editor_core package scaffold, barrels, purity test | INT-01 |
| 3 | **CORE-02** | M0 | Core (pure Dart) | Time, frame grid, timecode and ids | CORE-01 |
| 4 | **CORE-04** | M0 | Core (pure Dart) | Media pool model, MediaAccessPort and quickHash | CORE-02 |
| 5 | **CORE-03** | M0 | Core (pure Dart) | Core immutable model types | CORE-02, CORE-04 |
| 6 | **CORE-05** | M0 | Core (pure Dart) | Property keys, keyframe evaluation | CORE-03 |
| 7 | **CORE-06** | M0 | Core (pure Dart) | Clip time map and speed math | CORE-03 |
| 8 | **CORE-29** | M0 | Core (pure Dart) | RenderPlan v1 types, JSON codec, JSON Schema, validator, contract fixtures | CORE-02 |
| 9 | **API-01** | M0 | Engine (Dart) | Engine API package: contract, value types, failures, fake engine, contract kit | CORE-03, CORE-04, CORE-29 |
| 10 | **ENG-01** | M0 | Engine (Dart) | Engine plugin: Pigeon surface definitions and generated code, MobileEditorEngine, event router, error mapper | API-01, INT-01 |
| 11 | **ENG-05** | M0 | Engine (Dart) | Test media fixtures and frame barcode readers | ENG-01 |
| 12 | **ENG-09** | M0 | Engine (Dart) | Example host app, native test harness and editor CI scripts | ENG-01, ENG-05 |
| 13 | **ENG-07** | M0 | iOS native | iOS plugin glue, engine core and native service placeholders | ENG-09 |
| 14 | **ENG-08** | M0 | Android native | Android plugin glue, engine core, Gradle, manifest and native service placeholders | ENG-09 |
| 15 | **AI-01** | M0 | AI (whisper + transcription) | Vendor whisper.cpp v1.9.4 (pruned) with re-vendor script | — |
| 16 | **AI-02** | M0 | AI (whisper + transcription) | danaview_whisper FFI plugin skeleton and C ABI header | AI-01 |
| 17 | **AI-08** | M0 | AI (whisper + transcription) | danaview_transcription package: contracts, catalog, languages, consent types, fake | AI-02, CORE-03 |
| 18 | **UI-01** | M0 | UI/UX | danaview_ui_kit additions: progress bar, number field, colour picker, docked panel, search field, step indicator | — |
| 19 | **UX-01** | M0 | UI/UX | danaview_editor package scaffold, availability gate, providers, contracts, wiring, placeholders | API-01, AI-08, UI-01, CORE-04 |
| 20 | **UX-02** | M0 | UI/UX | Orientation owner stack (ScreenOrientationPolicy) | — |
| 21 | **UX-03** | M0 | UI/UX | Home header edit button and features chrome entry point | — |
| 22 | **IOS-01** | M1 | iOS native | iOS spike (day 1, spike host): Metal CI kernels, compositor, grid timing, exact seek, texture, audio tap, background encoder, reader/writer | — |
| 23 | **AND-01** | M1 | Android native | Android spike (day 1, spike host): Media3 1.11.1 multi-sequence CompositionPlayer + Transformer, grid timing, paused edits, rebuild latency, packing | — |
| 24 | **CORE-07** | M1 | Core (pure Dart) | Geometry, text layout spec and text animation evaluation | CORE-05, CORE-06 |
| 25 | **CORE-08** | M1 | Core (pure Dart) | Validator and repair | CORE-05, CORE-06 |
| 26 | **CORE-36** | M1 | Core (pure Dart) | Visual packing and per-platform layer counts | CORE-03 |
| 27 | **CORE-09** | M1 | Core (pure Dart) | Command framework, dry run, placement and limits | CORE-08, CORE-36 |
| 28 | **CORE-10** | M1 | Core (pure Dart) | Structural clip commands and ripple | CORE-09, CORE-06 |
| 29 | **CORE-11** | M1 | Core (pure Dart) | Duplicate, clipboard, replace, extract audio, links, selection | CORE-10 |
| 30 | **CORE-12** | M1 | Core (pure Dart) | Speed, reverse and freeze-frame commands | CORE-10 |
| 31 | **CORE-13** | M1 | Core (pure Dart) | Property and keyframe commands | CORE-09, CORE-05 |
| 32 | **CORE-14** | M1 | Core (pure Dart) | Text commands | CORE-13, CORE-07 |
| 33 | **CORE-15** | M1 | Core (pure Dart) | Subtitle and generated-caption commands | CORE-10 |
| 34 | **CORE-16** | M1 | Core (pure Dart) | Transitions and transition limits | CORE-10 |
| 35 | **CORE-17** | M1 | Core (pure Dart) | Track, marker and project-setting commands, requantize | CORE-09 |
| 36 | **CORE-18** | M1 | Core (pure Dart) | Snapping index | CORE-03 |
| 37 | **CORE-19** | M1 | Core (pure Dart) | EditSession: snapshot history, transactions, coalescing | CORE-09 |
| 38 | **CORE-20** | M1 | Core (pure Dart) | SRT and WebVTT codec | CORE-02 |
| 39 | **CORE-21** | M1 | Core (pure Dart) | .cube parser, .vlut writer/reader, float16 | CORE-01 |
| 40 | **API-03** | M1 | Engine (Dart) | Render-math vectors, Dart CPU reference renderer, goldens | API-01, CORE-07, CORE-29 |
| 41 | **ENG-06** | M1 | Engine (Dart) | [INTEGRATION] Spike outcomes into plugin build config and Pigeon surface | IOS-01, AND-01, ENG-07, ENG-08 |
| 42 | **AI-03** | M1 | AI (whisper + transcription) | whisper native C shim and host tests | AI-02 |
| 43 | **AI-06** | M1 | AI (whisper + transcription) | whisper device profile, thermal/memory events, backup exclusion channel | AI-02 |
| 44 | **CORE-22** | M2 | Core (pure Dart) | Project JSON codec, fragment cache, schema version | CORE-03, CORE-04, CORE-05 |
| 45 | **CORE-23** | M2 | Core (pure Dart) | Migration framework and schema fixtures | CORE-22 |
| 46 | **CORE-24** | M2 | Core (pure Dart) | Store filesystem, atomic writes, .dnproj format, OwnedFileDeleter | CORE-22 |
| 47 | **CORE-27** | M2 | Core (pure Dart) | Media pool service, import policy, managed store, DartIoMediaAccess | CORE-24, CORE-19 |
| 48 | **CORE-25** | M2 | Core (pure Dart) | ProjectRepository and writer isolate | CORE-27, CORE-23 |
| 49 | **CORE-26** | M2 | Core (pure Dart) | Autosave scheduler, journal and crash recovery | CORE-25 |
| 50 | **CORE-28** | M2 | Core (pure Dart) | Availability, relink, garbage collection, backup rules | CORE-25, CORE-27 |
| 51 | **CORE-30** | M2 | Core (pure Dart) | RenderPlan compiler: visual lowering, assets, z-order | CORE-29, CORE-07, CORE-08, CORE-36 |
| 52 | **CORE-31** | M2 | Core (pure Dart) | Lowering: transitions, text and subtitle sprites, audio | CORE-30, CORE-16 |
| 53 | **CORE-32** | M2 | Core (pure Dart) | Plan diff, patches, memoization and transients | CORE-31 |
| 54 | **CORE-33** | M2 | Core (pure Dart) | Export settings, presets, bitrate table, compileExport | CORE-31 |
| 55 | **API-02** | M2 | Engine (Dart) | PlanSync and plan transport | API-01, CORE-32 |
| 56 | **API-04** | M2 | Engine (Dart) | Render prep: text layout engine, sprite rasterizer, .vsprite codec, sprite pre-pass | API-01, CORE-07, CORE-31 |
| 57 | **ENG-03** | M2 | Engine (Dart) | Dart glue: jobs, recorder, platform services, media access | ENG-06 |
| 58 | **IOS-02** | M2 | iOS native | iOS probe, compatibility, device profile, capabilities | ENG-06, ENG-05 |
| 59 | **IOS-17** | M2 | iOS native | iOS segmented writer, checkpoint, passthrough concat and job interruption | ENG-06, ENG-05 |
| 60 | **IOS-03** | M2 | iOS native | iOS thumbnails and disk cache | IOS-02 |
| 61 | **IOS-04** | M2 | iOS native | iOS PCM reader, waveforms, speech audio extraction | IOS-02 |
| 62 | **IOS-05** | M2 | iOS native | iOS job registry, proxy job and proxy registry | IOS-02, IOS-17 |
| 63 | **IOS-06** | M2 | iOS native | iOS freeze frame and source-frame cache | IOS-05 |
| 64 | **IOS-07** | M2 | iOS native | iOS reverse rendition job | IOS-05 |
| 65 | **IOS-18** | M2 | iOS native | iOS audio gain tap (sample-exact envelopes up to +6 dB) and ramp-seam crossfade | ENG-06, API-03 |
| 66 | **AND-02** | M2 | Android native | Android probe, compatibility, device profile, capabilities | ENG-06, ENG-05 |
| 67 | **AND-03** | M2 | Android native | Android thumbnails and disk cache | AND-02 |
| 68 | **AND-04** | M2 | Android native | Android PCM decoder, waveforms, speech audio extraction | AND-02 |
| 69 | **AND-05** | M2 | Android native | Android job registry, proxy job and registry | AND-02 |
| 70 | **AND-06** | M2 | Android native | Android freeze frame and source-frame cache | AND-05 |
| 71 | **AND-07** | M2 | Android native | Android reverse rendition job | AND-05 |
| 72 | **AI-04** | M2 | AI (whisper + transcription) | whisper Android native build | AI-03 |
| 73 | **AI-05** | M2 | AI (whisper + transcription) | whisper iOS native build (static xcframework) | AI-03, INT-01, ENG-09 |
| 74 | **AI-09** | M2 | AI (whisper + transcription) | Model store and resumable, verified downloader | AI-08, AI-06 |
| 75 | **AI-10** | M2 | AI (whisper + transcription) | Transcript normalizer, cache and checkpoints | AI-08 |
| 76 | **AI-11** | M2 | AI (whisper + transcription) | Caption segmentation engine | AI-08 |
| 77 | **AI-12** | M2 | AI (whisper + transcription) | Timeline planner, word mapping and merge | AI-08, CORE-06 |
| 78 | **CORE-34** | M3 | Core (pure Dart) | Model fuzzer (commands, history, codec, plan diff) | CORE-11, CORE-12, CORE-14, CORE-15, CORE-16, CORE-17, CORE-19, CORE-22, CORE-32 |
| 79 | **ENG-02** | M3 | Engine (Dart) | Dart glue: mobile preview session | ENG-06, API-02 |
| 80 | **IOS-08** | M3 | iOS native | iOS plan decode, ParamSnapshot, composition builder, instructions, audio mix | ENG-06, CORE-29, CORE-32, API-03, IOS-18 |
| 81 | **IOS-09** | M3 | iOS native | iOS render kernels, LUT/sprite/image stores | ENG-06, API-03, API-04, CORE-21 |
| 82 | **IOS-10** | M3 | iOS native | iOS DVCompositor, layer renderer, redraw cache | IOS-08, IOS-09 |
| 83 | **IOS-11** | M3 | iOS native | iOS preview session: texture, display link, clock, seek, patches, quality, lifecycle | IOS-10, IOS-06, ENG-02 |
| 84 | **AND-08** | M3 | Android native | Android plan reader, ParamSnapshot, composition mapper, gating, speed and gain providers | ENG-06, CORE-29, CORE-32, API-03 |
| 85 | **AND-09** | M3 | Android native | Android GL effects, shaders, LUT and sprite textures | ENG-06, API-03, API-04, CORE-21 |
| 86 | **AND-17** | M3 | Android native | Android paused-frame renderer, layer GL compositor and structural debounce | AND-08, AND-09, AND-06 |
| 87 | **AND-10** | M3 | Android native | Android preview session: SurfaceProducer, clock, seek/scrub, transients, redraw, quality, lifecycle | AND-08, AND-09, AND-06, ENG-02, AND-17 |
| 88 | **AND-16** | M3 | Android native | Android contingency preview engine (conditional: only on an AND-01 no-go) | AND-10, AND-17 |
| 89 | **AI-07** | M3 | AI (whisper + transcription) | whisper Dart runtime (WhisperRuntime, WhisperModel, WhisperJob) | AI-03, AI-06, AI-04, AI-05 |
| 90 | **UX-04** | M3 | UI/UX | Storage contributors, Settings row and Editor settings screen | UX-01, CORE-25 |
| 91 | **UX-05** | M3 | UI/UX | Projects screen and controller | UX-01, CORE-25 |
| 92 | **UX-06** | M3 | UI/UX | New project sheet and import media sheet | UX-05, CORE-27 |
| 93 | **UX-07** | M3 | UI/UX | Editor screen shell, scope, lifecycle and layout planner | UX-01, UI-01 |
| 94 | **UX-08** | M3 | UI/UX | EditorController, EditorState, EditTransaction, session wiring, events, messages | UX-01, CORE-19, CORE-26, API-02 |
| 95 | **INT-02** | M3 | Integration | [INTEGRATION] App wiring v1: EditorBootstrap, default plan compiler, routes, Home and Settings entry points | UX-03, UX-04, UX-05, UX-07, UX-08, ENG-06, CORE-26, CORE-28, CORE-33, AI-04, AI-05 |
| 96 | **UX-09** | M3 | UI/UX | Timeline viewport controller, ruler, metrics and style | UX-01, CORE-02 |
| 97 | **UX-10** | M3 | UI/UX | Timeline snapshot, RenderTimelineCanvas painting, hit testing, playhead layer | UX-08, UX-09 |
| 98 | **UX-11** | M3 | UI/UX | Track headers, track menu and lane flags | UX-10, CORE-17 |
| 99 | **UX-12** | M3 | UI/UX | Timeline view, gesture arbiter, semantics | UX-10 |
| 100 | **UX-13** | M3 | UI/UX | Move, trim, split, delete, ripple, snapping UI, clipboard | UX-12, CORE-11, CORE-18 |
| 101 | **UX-14** | M3 | UI/UX | Playhead controller, transport controller and transport bar | UX-08 |
| 102 | **UX-15** | M3 | UI/UX | Action registry, keyboard shortcuts, shortcuts sheet | UX-08 |
| 103 | **UX-16** | M3 | UI/UX | Tool strip/rail, context tool sets, inspector host and dock | UX-07, UX-15, CORE-05 |
| 104 | **UX-17** | M3 | UI/UX | Markers sheet and marker actions | UX-13, UX-14, CORE-17 |
| 105 | **UX-18** | M3 | UI/UX | Preview region, preview surface, status overlays, fullscreen preview, quality | UX-07, UX-14 |
| 106 | **UX-19** | M3 | UI/UX | Text and subtitle overlay layer for preview | UX-18, API-04, CORE-07 |
| 107 | **UX-20** | M3 | UI/UX | Thumbnail cache and strip painting | UX-10 |
| 108 | **UX-21** | M3 | UI/UX | Waveform cache and painting | UX-10 |
| 109 | **UX-22** | M3 | UI/UX | Canvas geometry, manipulation overlay (move/scale/rotate), snap guides | UX-18, CORE-13, CORE-32 |
| 110 | **ENG-04** | M4 | Engine (Dart) | Dart glue: export service and job reattach | ENG-06 |
| 111 | **IOS-12** | M4 | iOS native | iOS export pipeline: reader/writer, encoder settings, coordinator | IOS-10, ENG-04, IOS-11, IOS-17, IOS-18 |
| 112 | **IOS-14** | M4 | iOS native | iOS voice recorder | ENG-03 |
| 113 | **IOS-15** | M4 | iOS native | iOS pickers, media access (bookmarks), permissions, background guard | ENG-03 |
| 114 | **IOS-16** | M4 | iOS native | iOS external drop target | ENG-03 |
| 115 | **AND-11** | M4 | Android native | Android export: coordinator, Transformer, encoder settings, hardware selector, active store | AND-09, ENG-04, AND-08, AND-10 |
| 116 | **AND-13** | M4 | Android native | Android voice recorder | ENG-03 |
| 117 | **AND-14** | M4 | Android native | Android pickers, URI grants (media access), permissions | ENG-03 |
| 118 | **AND-15** | M4 | Android native | Android external drop target | ENG-03 |
| 119 | **AI-13** | M4 | AI (whisper + transcription) | Transcription orchestrator (TranscriptionServiceImpl) and resource governor | AI-07, AI-09, AI-10, AI-11, AI-12, CORE-15 |
| 120 | **UX-23** | M4 | UI/UX | Transform, crop and mask panels; crop, mask and eyedropper preview modes | UX-22, UX-16 |
| 121 | **UX-24** | M4 | UI/UX | Adjust and Filters/LUT panels, built-in looks | UX-16, CORE-13, CORE-21, CORE-27 |
| 122 | **UX-25** | M4 | UI/UX | Speed panel and speed curve editor | UX-16, CORE-12 |
| 123 | **UX-26** | M4 | UI/UX | Keyframes panel and keyframe actions | UX-16, CORE-13 |
| 124 | **UX-27** | M4 | UI/UX | Transitions panel and loop preview | UX-16, UX-18, CORE-16 |
| 125 | **UX-28** | M4 | UI/UX | Overlay (picture-in-picture) and chroma key panels | UX-23 |
| 126 | **UX-29** | M4 | UI/UX | Canvas/Format panel, project sheet, history sheet | UX-16, CORE-17, CORE-19 |
| 127 | **UX-30** | M4 | UI/UX | Text tool, text panel, font picker, content fonts package | UX-19, CORE-14, API-04 |
| 128 | **UX-31** | M4 | UI/UX | Subtitles lane tools and subtitles panel | UX-16, UX-19, CORE-15 |
| 129 | **UX-32** | M4 | UI/UX | SRT/VTT import and export UI | UX-31, CORE-20 |
| 130 | **UX-33** | M4 | UI/UX | Audio panel: volume, fades, mute, pitch, extract audio, background music | UX-16, CORE-13, CORE-11 |
| 131 | **UX-34** | M4 | UI/UX | Voiceover recording UI | UX-33 |
| 132 | **UX-35** | M4 | UI/UX | Freeze, reverse, replace, clip info, background tasks | UX-16, CORE-12, CORE-11 |
| 133 | **UX-36** | M4 | UI/UX | Media panel (bin), add/replace, in-app and external drag and drop | UX-06, UX-13 |
| 134 | **CORE-37** | M4 | Core (pure Dart) | Render-preview cache model: range hashing, invalidation, cache index | CORE-32 |
| 135 | **CORE-38** | M4 | Core (pure Dart) | Allow edits above the live-preview sequence cap | CORE-09, CORE-37 |
| 136 | **INT-06** | M4 | Integration | [INTEGRATION] Engine interface additions for render preview | ENG-06, CORE-37 |
| 137 | **UX-44** | M4 | UI/UX | Render-preview UI: timeline render marker, action, settings, tier defaults | UX-18, UX-04, CORE-37, INT-06 |
| 138 | **IOS-19** | M4 | iOS native | iOS render-preview renderer and playback swap-in | IOS-11, INT-06 |
| 139 | **IOS-20** | M4 | iOS native | iOS multi-pass export fallback (precompose above the decoder limit) | IOS-12 |
| 140 | **AND-18** | M4 | Android native | Android render-preview renderer and playback swap-in | AND-16, AND-10, INT-06 |
| 141 | **AND-19** | M4 | Android native | Android multi-pass export precompose | AND-11 |
| 142 | **IOS-13** | M5 | iOS native | iOS background export, active-export store, Photos and Files handoff | IOS-12 |
| 143 | **INT-03** | M5 | Integration | [INTEGRATION] iOS app declarations: Info.plist, entitlements, privacy manifest, BG task ids | INT-01, IOS-13, IOS-14, IOS-15 |
| 144 | **AND-12** | M5 | Android native | Android export foreground service, notification, background guard, MediaStore, file handoff | AND-11 |
| 145 | **UX-37** | M5 | UI/UX | Auto captions flow: sheet, controller, language picker, consent, progress | UX-31, AI-08, CORE-15 |
| 146 | **UX-38** | M5 | UI/UX | Regenerate captions, interrupted-job notice, captions settings, speech storage contributor | UX-37, UX-04 |
| 147 | **UX-39** | M5 | UI/UX | Export sheet, export controller, progress, handoff | UX-08, CORE-33, API-04 |
| 148 | **UX-40** | M5 | UI/UX | Missing media, relink, recovery and migration UX | UX-05, UX-08, CORE-26, CORE-28 |
| 149 | **UX-41** | M5 | UI/UX | Player 'Edit' action, EditorLauncher and player handoff | UX-02, UX-07, UX-08, CORE-25 |
| 150 | **UX-42** | M5 | UI/UX | Privacy policy and terms update, custom licences screen, About row | — |
| 151 | **INT-04** | M5 | Integration | [INTEGRATION] App wiring v2: auto captions service, adapters, player Edit, licences route | INT-02, AI-13, UX-38, UX-41, UX-42, ENG-03, ENG-04 |
| 152 | **CORE-35** | M6 | Core (pure Dart) | Core benchmarks, large-project fixture, README | CORE-26, CORE-32, CORE-34, CORE-33 |
| 153 | **QA-00** | M6 | QA | Shared on-device E2E suite (integration_test/editor) | INT-04, ENG-05, UX-05, UX-06, UX-11, UX-17, UX-20, UX-21, UX-23, UX-24, UX-25, UX-26, UX-27, UX-28, UX-29, UX-30, UX-32, UX-34, UX-35, UX-36, UX-38, UX-39, UX-40, UX-41, UX-42, IOS-13, IOS-14, IOS-15, IOS-16, AND-12, AND-13, AND-14, AND-15 |
| 154 | **QA-01** | M6 | QA | Run and certify the E2E suite on the iOS Simulator | QA-00, INT-03 |
| 155 | **QA-02** | M6 | QA | Run and certify the E2E suite on an Android Emulator | QA-00 |
| 156 | **QA-03** | M6 | QA | Frame accuracy, grid-cut, A/V sync and render parity suite | IOS-11, AND-10, IOS-12, AND-11, API-03, ENG-05 |
| 157 | **QA-11** | M6 | QA | Export conformance, preset matrix and audio measurement suite | IOS-13, AND-12, IOS-18, API-03, ENG-05, IOS-20, AND-19, CORE-38 |
| 158 | **QA-04** | M6 | QA | Performance and memory budgets (profile mode, device lab) | INT-04, CORE-35, UX-44, AND-18, IOS-19 |
| 159 | **UX-43** | M6 | UI/UX | Timeline picture-tile cache (conditional on QA-04 budget miss) | QA-04 |
| 160 | **QA-05** | M6 | QA | Robustness soak | QA-00 |
| 161 | **QA-06** | M6 | QA | Auto captions benchmarks, accuracy evaluation and tuning | AI-13, AI-07 |
| 162 | **QA-07** | M6 | QA | Auto captions on-device E2E and AI device matrix | QA-06, UX-38, INT-04 |
| 163 | **QA-08** | M6 | QA | Accessibility pass (guidelines, VoiceOver, TalkBack) | UX-05, UX-06, UX-11, UX-17, UX-20, UX-21, UX-23, UX-24, UX-25, UX-26, UX-27, UX-28, UX-29, UX-30, UX-32, UX-34, UX-35, UX-36, UX-38, UX-39, UX-40, UX-41, UX-42, UX-44 |
| 164 | **QA-09** | M6 | QA | No-overflow matrix suite (full nightly, PR subset) | UX-05, UX-06, UX-11, UX-17, UX-20, UX-21, UX-23, UX-24, UX-25, UX-26, UX-27, UX-28, UX-29, UX-30, UX-32, UX-34, UX-35, UX-36, UX-38, UX-39, UX-40, UX-41, UX-42, UX-44 |
| 165 | **QA-10** | M6 | QA | Persistence, crash recovery and media-access survival on device | INT-04, IOS-15, AND-14, CORE-26, CORE-28 |
| 166 | **INT-05** | M6 | Integration | [INTEGRATION] Release 1.1.0: flags, version, release pipelines, store metadata, docs | QA-01, QA-02, QA-03, QA-04, QA-05, QA-07, QA-08, QA-09, QA-10, CORE-35, UX-43, INT-03, INT-04, QA-11 |

## 6. Tickets

### M0: Foundations and contracts

#### INT-01 · Repo foundations: iOS 15.0 target, dependency rules, editor CI [INTEGRATION]

- **Milestone:** M0 · **Area:** Integration
- **Depends on:** —
- **Owns:**
  - `ios/Podfile`
  - `ios/Runner.xcodeproj/project.pbxproj`
  - `test/architecture/dependency_rules_test.dart`
  - `test/architecture/fixtures/`
  - `.github/workflows/danaview-ci.yml`
  - `scripts/ci/editor/flutter_packages.sh`
  - `scripts/ci/editor/nightly.sh`
  - `scripts/ci/editor/README.md`
  - `docs/v1.1/editor/ARCHITECTURE.md` (D-43 sign-off status only)
- **Spec:** [INTEGRATION] (1) Raise the iOS deployment target 13.0 -> 15.0 exactly as ARCH §3.1/D-29: IPHONEOS_DEPLOYMENT_TARGET = 15.0 in every iOS Runner and RunnerTests build configuration of ios/Runner.xcodeproj/project.pbxproj (leave macOS untouched), `platform :ios, '15.0'` in ios/Podfile plus a post_install hook that lifts any pod below 15.0 to 15.0. (2) test/architecture/dependency_rules_test.dart parses every packages/*/pubspec.yaml and scans Dart imports to enforce ARCH §4.2 rules 1-7 (packages not yet created are skipped; rule 8 is UX-01's), and scans every danaview_features file an editor ticket touches (UX-02, UX-03, UX-04, UX-41, UX-42 owns lists) for the ARCH §1.3 forbidden Material names as whole identifiers (so Danaview* wrappers pass; empty baseline, the files have zero matches today). Negative fixtures in test/architecture/fixtures/ prove each rule fires. (3) .github/workflows/danaview-ci.yml per ARCH §22: jobs dart-core, flutter-packages, whisper-host, android-unit, android-emulator, ios (self-hosted macOS, workflow input `runner` falls back to macos-15), nightly (cron). Each job runs scripts/ci/editor/<job>.sh when present and prints a skip notice otherwise; nightly runs every scripts/ci/editor/nightly.d/*.sh. Path filters: packages/danaview_editor*/**, packages/danaview_transcription/**, packages/danaview_whisper/**, test/architecture/**, scripts/ci/editor/**, the workflow. (4) flutter_packages.sh (analyze + test for each editor Flutter package that exists + root test/architecture), nightly.sh, README.md naming script owners (core.sh CORE-01; whisper_host.sh AI-03; android_unit.sh, android_emulator.sh, ios.sh, check_ios_min_os.sh ENG-09; e2e_ios.sh QA-01; e2e_android.sh QA-02; nightly.d/* per ticket) and the self-hosted runner prerequisites (Xcode 26.6, `brew install cmake` ≥ 3.28, the device lab list incl. the iPhone 7 on iOS 15.8 and iPhone 8 on iOS 16.7, D-41). (5) Present the D-43 platform narrowings (a)–(d), (f) to the owner with the remux option for (d) and record the answer and date in ARCHITECTURE.md D-43 (status cell only).
- **Acceptance criteria and tests:** existing `flutter test` suite and `flutter build ios --no-codesign --debug` pass; no iOS config keeps 13.0; dependency and forbidden-Material tests green on main and red on every negative fixture; actionlint clean; existing release workflows unchanged; D-43 owner sign-off recorded (M0 exit criterion).

#### CORE-01 · danaview_editor_core package scaffold, barrels, purity test

- **Milestone:** M0 · **Area:** Core (pure Dart)
- **Depends on:** INT-01
- **Owns:**
  - `packages/danaview_editor_core/pubspec.yaml`
  - `packages/danaview_editor_core/analysis_options.yaml`
  - `packages/danaview_editor_core/lib/model.dart`
  - `packages/danaview_editor_core/lib/ops.dart`
  - `packages/danaview_editor_core/lib/eval.dart`
  - `packages/danaview_editor_core/lib/formats.dart`
  - `packages/danaview_editor_core/lib/plan.dart`
  - `packages/danaview_editor_core/lib/codec.dart`
  - `packages/danaview_editor_core/lib/store.dart`
  - `packages/danaview_editor_core/test/purity_test.dart`
  - `scripts/ci/editor/core.sh`
- **Spec:** Create packages/danaview_editor_core: pure Dart, deps exactly meta, collection, crypto, path, characters (dev: test, checks, json_schema for CORE-29's schema tests); strict analysis (strict-casts, strict-inference, strict-raw-types). Barrels lib/{model,ops,eval,formats,plan,codec,store}.dart export exactly the files of ARCH §4.3 (as corrected: MediaAccessPort lives in model/pool; ops/limits.dart is CORE-09; model/keyframes/keyframe_data.dart is CORE-03). A directory entry is exported through its sub-barrel `<dir>/<dirname>.dart`, owned by that directory's ticket. Create D-33 placeholders (header `// OWNER: CORE-xx`; may be empty libraries) for every exported file so the package analyzes from day one. Barrels never change after this ticket: a ticket that needs more public files re-exports them from one of its own files. test/purity_test.dart fails on any package:flutter or package:danaview_* import, and on dart:io / dart:isolate outside lib/src/store/ (source scan, with negative fixtures). scripts/ci/editor/core.sh: dart pub get, dart analyze --fatal-infos, dart test, and `dart run benchmark/run.dart --check` when benchmark/ exists.
- **Acceptance criteria and tests:** `dart test` passes with no Flutter SDK on PATH; purity test catches each negative fixture; package analyzes clean; core.sh runs in the dart-core CI job.

#### CORE-02 · Time, frame grid, timecode and ids

- **Milestone:** M0 · **Area:** Core (pure Dart)
- **Depends on:** CORE-01
- **Owns:**
  - `packages/danaview_editor_core/lib/src/time/`
  - `packages/danaview_editor_core/lib/src/ids/`
  - `packages/danaview_editor_core/tool/gen_frame_vectors.dart`
  - `packages/danaview_editor_core/test/fixtures/vectors/frame_grid.json`
  - `packages/danaview_editor_core/test/time/`
  - `packages/danaview_editor_core/test/ids/`
- **Spec:** Implement ARCH §5. lib/src/time/: TimeUs, FrameRate(num, den) with timeOfFrame(k)=ceilDiv(k*1e6*den, num), frameIndexOf, quantize, quantizeNearest, isOnGrid, and the platform-time rule of ARCH §5/D-35: frameIndexNearest(tau) = floorDiv(tau*num + 500000*den, 1000000*den) and platformTimeOfFrame(k) = P(k) = round(k*1e6/fps); FrameRate.project validation (v1: den == 1 and num in {24,25,30,48,50,60}, D-03; the type stays rational); TimeRange (half-open, intersect/contains/shift); negative-safe ceilDiv/floorDiv; Timecode format `mm:ss:ff` (`h:mm:ss:ff` from 1 h) and parse of `1:23`, `1:23:12`, `83.5s`, `+2s`, `-10f` relative to a base. lib/src/ids/: extension types over String ProjectId 'pr_', TrackId 'tr_', ItemId 'it_', MediaId 'md_', MarkerId 'mk_', TransitionId 'tx_', LinkId 'ln_' (prefix + 12 base62 chars from Random.secure), IdGenerator, SeededIdGenerator. tool/gen_frame_vectors.dart writes test/fixtures/vectors/frame_grid.json (per fps in {24,25,30,48,50,60}: k in {0,1,2,3,fps-1,fps,fps+1,fps+2,1000, 1 h, 1 h+1, 1 h+2, 24 h-1} so k ≡ 0, 1, 2 (mod 3) are all covered, with timeOfFrame, frameIndexOf at t-1, t, t+1, floor(k·1e6/fps), P(k), the rational (k, fps), the expected frameIndexNearest of each platform form (= k), frameIndexNearest at P(k) ± (half a frame − 1 µs), and a placeholder `androidSeekMsRounding` filled from AND-01's measurement by ENG-06's record); the committed file is read by Swift/Kotlin tests.
- **Acceptance criteria and tests:** properties frameIndexOf(timeOfFrame(k)) == k and frameIndexOf(timeOfFrame(k+1)-1) == k for every supported fps, sampled k plus edges up to 24 h; frameIndexNearest(x) == k for x in {timeOfFrame(k), floor(k·1e6/fps), P(k)} and for every x within half a frame − 1 µs of k·1e6/fps; P(k) equals Media3's double formula round((1e6/fps)·k) for all sampled k up to 24 h; no product exceeds 2^53; Timecode.parse(format(t)) == quantize(t); seeded ids deterministic, secure ids unique over 1e6 draws; regenerating vectors yields no diff.

#### CORE-03 · Core immutable model types

- **Milestone:** M0 · **Area:** Core (pure Dart)
- **Depends on:** CORE-02, CORE-04
- **Owns:**
  - `packages/danaview_editor_core/lib/src/model/model.dart`
  - `packages/danaview_editor_core/lib/src/model/project.dart`
  - `packages/danaview_editor_core/lib/src/model/timeline.dart`
  - `packages/danaview_editor_core/lib/src/model/settings.dart`
  - `packages/danaview_editor_core/lib/src/model/track.dart`
  - `packages/danaview_editor_core/lib/src/model/items.dart`
  - `packages/danaview_editor_core/lib/src/model/speed_spec.dart`
  - `packages/danaview_editor_core/lib/src/model/visual_props.dart`
  - `packages/danaview_editor_core/lib/src/model/audio_props.dart`
  - `packages/danaview_editor_core/lib/src/model/text_style.dart`
  - `packages/danaview_editor_core/lib/src/model/subtitle.dart`
  - `packages/danaview_editor_core/lib/src/model/transition.dart`
  - `packages/danaview_editor_core/lib/src/model/marker.dart`
  - `packages/danaview_editor_core/lib/src/model/view_state.dart`
  - `packages/danaview_editor_core/lib/src/model/project_index.dart`
  - `packages/danaview_editor_core/lib/src/model/keyframes/keyframe_data.dart`
  - `packages/danaview_editor_core/test/model/core/`
- **Spec:** All immutable model types of ARCH §6.1-6.6 (domain.md §4): EditProject (id, meta, timeline, pool, view, docRevision; getters settings, tracks, markers, media, duration, revision and a lazily built cached `index` for id lookups), ProjectMeta (name, createdAt, updatedAt, origin incl. fromPlayer path+fingerprint, editCount), Timeline (settings, tracks, markers, revision), ProjectSettings/CanvasSpec (aspect w:h + baseShortSide -> even px)/BackgroundSpec (Solid | BlurOfMain), ViewState, TrackKind, AudioRole, Track (isMain, locked, hidden, muted, solo, audioRole, subtitle, items, transitions, changedAt), sealed TimelineItem with MediaClip/TextItem/SubtitleCue, SpeedSpec (ConstantSpeed | SpeedRamp), VisualProps with Transform2D/FitMode/CropRect/ColorAdjust/DetailFx/LookRef/ChromaKey/MaskSpec, AudioProps, TextStyleSpec (+BoxStyle, StrokeStyle, ShadowStyle), TextAnimation, SubtitleTrackData/SubtitleStyle/SubtitlePosition, CaptionProvenance, CueOrigin, SubtitleCueDraft, Transition/TransitionKind/TransitionDirection/TransitionRef, Marker, Vec2, and keyframe data (Keyframe, KeyframeTrack, KeyframeSet) in model/keyframes/keyframe_data.dart (PropertyKey metadata is CORE-05). Defaults and ranges exactly as ARCH §6. Structural sharing: unmodifiable lists, copy-on-write per track; canonical track order helpers (D-09 display order is reverse z).
- **Acceptance criteria and tests:** every type @immutable with copyWith, ==, hashCode; lists unmodifiable; `index` built once per instance; canonical order and band helpers tested; ux.md §2.1 getters exist; no dart:io.

#### CORE-04 · Media pool model, MediaAccessPort and quickHash

- **Milestone:** M0 · **Area:** Core (pure Dart)
- **Depends on:** CORE-02
- **Owns:**
  - `packages/danaview_editor_core/lib/src/model/pool/`
  - `packages/danaview_editor_core/test/model/pool/`
  - `packages/danaview_editor_core/test/fixtures/quickhash/`
- **Spec:** lib/src/model/pool/ (sub-barrel pool/pool.dart), ARCH §6.8 and §9.2: MediaKind, MediaAsset, sealed MediaLocator (AppRelativeLocator(root documents|support|cache, relPath), FileLocator, ContentUriLocator, BookmarkLocator(bookmarkB64, lastKnownPath)), MediaOwnership, MediaFingerprint, MediaOrigin, DerivedSpec (reversed(media, range) | still(media, time)) with a stable specHash, AssetStatus, ProxyState, immutable MediaPool, PoolChange (sticky) and PoolEdit/PoolDelta (undoable) value types, ResolvedMedia, MediaProbe, ColorTransfer, PickedMedia {uri, displayName, isTemporaryCopy, bookmark, sizeBytes}, PickedMediaHandle, MediaStat, MediaAccessFailure and the MediaAccessPort interface (moved here from store/ so API-01 can implement it at M0; no dart:io). quickHash: pure `computeQuickHash(Uint8List head, Uint8List tail, int size)` reproducing packages/danaview_data/lib/src/scanner/media_identity.dart byte for byte (sha1(first min(size,64 KiB) + last 64 KiB only when size > 64 KiB, overlapping when size < 128 KiB, + utf8(':$size')); empty file -> '').
- **Acceptance criteria and tests:** value equality/hashCode/copyWith on all types; sealed switch exhaustiveness tests; test/fixtures/quickhash/*.json holds expected hashes for 6 files (1 byte, 64 KiB, 64 KiB+1, 100 KiB, 128 KiB, 3 MiB) produced once with danaview_data's implementation (procedure in the fixture README) and the core function matches all of them.

#### CORE-05 · Property keys, keyframe evaluation

- **Milestone:** M0 · **Area:** Core (pure Dart)
- **Depends on:** CORE-03
- **Owns:**
  - `packages/danaview_editor_core/lib/src/model/keyframes/keyframes.dart`
  - `packages/danaview_editor_core/lib/src/model/keyframes/property_keys.dart`
  - `packages/danaview_editor_core/lib/src/model/keyframes/keyframe_ops.dart`
  - `packages/danaview_editor_core/lib/src/eval/evaluate.dart`
  - `packages/danaview_editor_core/test/keyframes/`
- **Spec:** PropertyKey<T> registry (ARCH §6.7, domain.md §4.11) with stable id, displayName, unit, min/max/step/default, displayScale, keyframable flag, channel ids (`transform.position.x` ...), appliesTo item kinds, and static read/write against items, for every property: position, scale, rotation, opacity, flips, crop, the 8 ColorAdjust values, sharpness, blur, vignette, look intensity, chroma (color, similarity, smoothness, spill), mask (shape, center, size, rotation, corner, feather, opacity, invert), volume, mute, fades, and text style fields. Keyframable set exactly as ARCH §6.7. keyframe_ops: shift (start trim), scale (speed change), partition at a split with boundary keys, keys outside [0, duration) kept. eval/evaluate.dart: evaluate<T>(item, key, t) linear, held outside first/last key, rotation in plain degrees, Vec2 channels.
- **Acceptance criteria and tests:** table test covers every property with ranges/defaults; interpolation and hold exact; Vec2 writes both channels at the same t; out-of-range keys kept and ignored by evaluation; partition preserves evaluated values at every frame of both halves; non-keyframable keys reject keyframe writes.

#### CORE-06 · Clip time map and speed math

- **Milestone:** M0 · **Area:** Core (pure Dart)
- **Depends on:** CORE-03
- **Owns:**
  - `packages/danaview_editor_core/lib/src/eval/clip_time_map.dart`
  - `packages/danaview_editor_core/lib/src/eval/speed_math.dart`
  - `packages/danaview_editor_core/test/time_map/`
- **Spec:** ClipTimeMap for a MediaClip (ARCH §6.4, domain.md §4.5): constant speed in [0.1, 10] and SpeedRamp (2-16 points over normalized source position, y in [0.1, 10]); reversed clips via s' = sourceIn + sourceOut - s. API: toSource(t), timelineTimeOf(s) (exact inverse, null if trimmed away; used by AI-12), speedAt(t), sourceOut, durationFor(sourceRange, speed) = max(1 frame, quantizeNearest(T)), lower({maxErrorUs: 250}) -> contiguous List<MapSegment(t0, t1, s0, s1)> covering the clip, each with rate in [0.1, 10] and **every breakpoint t on a frame start of the project grid** (ARCH §11.3, D-35). Closed forms: segment time (L/b)·ln(v1/v0) (L·dx/v0 when b = 0), inverse x(tau) = x0 + v0(e^{b·tau/L} - 1)/b. A clip's video layer and audio segment are lowered from the same map (A/V sync contract, ARCH §11.5).
- **Acceptance criteria and tests:** closed forms vs numerical integration within 1 µs over 10k seeded random ramps; timelineTimeOf(toSource(t)) == t ± 1 µs; lowered maps within 250 µs at every frame start and every breakpoint on the grid; maps of the two halves of a split equal the original at every frame; reversed maps verified; lower() of a 7-point ramp <= 0.2 ms (benchmark test).

#### CORE-29 · RenderPlan v1 types, JSON codec, JSON Schema, validator, contract fixtures

- **Milestone:** M0 · **Area:** Core (pure Dart)
- **Depends on:** CORE-02
- **Owns:**
  - `packages/danaview_editor_core/lib/src/plan/render_plan.dart`
  - `packages/danaview_editor_core/lib/src/plan/plan_json.dart`
  - `packages/danaview_editor_core/lib/src/plan/plan_validator.dart`
  - `packages/danaview_editor_core/lib/src/plan/sprite_request.dart`
  - `packages/danaview_editor_core/lib/src/plan/encode_settings.dart`
  - `packages/danaview_editor_core/schema/render_plan.v1.schema.json`
  - `packages/danaview_editor_core/schema/effects_reference.md`
  - `packages/danaview_editor_core/test/fixtures/render_plans/contract/`
  - `packages/danaview_editor_core/test/plan/schema/`
- **Spec:** Delivered early: it unblocks the engine contract and native work. Dart types for ARCH §11.2 exactly (RenderPlan, Canvas incl. gridFps, PlanAsset, PlanLayer incl. seq, Effects (adj, detail, lut, chroma, mask), AnimChannel [[tUs, v]...], CanvasMask, AudioSeg, Requirements, RenderPlanPatch, PlanTransient), deterministic JSON encode/decode (integer µs, '#RRGGBBAA', unknown keys ignored, defaults omitted), the JSON Schema 2020-12 file, effects_reference.md (ARCH §11.6 render math restated normatively with the D-08 order), validator for ARCH §11.3 invariants incl. grid edges on canvas.gridFps and non-overlapping seq slots (returns layer ids), SpriteRequest/SpriteManifest types, EncodeSettings (+ExportContainer mp4|mov, VideoCodec h264|hevc) per ARCH §12.4. About 25 hand-written fixtures in test/fixtures/render_plans/contract/ covering every key, every animatable channel, transitions-as-lowered windows, holds, sprites with reveal, LUT assets, audio gain envelopes up to 2.0, patches and transients, **grid_cuts_30fps.json** (layer edges at frames k ≡ 1 and 2 mod 3, e.g. 31, 32, 61, 62, with `grid_cuts_30fps.expected_active.json` listing the active layer ids for every frame), an export plan with gridFps 30 and fps 24, a plan with an empty `audio` array (no-audio export), plus invalid fixtures for each invariant.
- **Acceptance criteria and tests:** every valid fixture validates against the schema (schema test via a small Dart validator or vendored JSON-Schema checker in dev deps) and round-trips byte-identically; every invalid fixture fails with the right layer id; encode of a 2,000-layer plan <= 40 ms in Isolate.run on the CI host (benchmark test).

#### API-01 · Engine API package: contract, value types, failures, fake engine, contract kit

- **Milestone:** M0 · **Area:** Engine (Dart)
- **Depends on:** CORE-03, CORE-04, CORE-29
- **Owns:**
  - `packages/danaview_editor_engine_api/pubspec.yaml`
  - `packages/danaview_editor_engine_api/lib/danaview_editor_engine_api.dart`
  - `packages/danaview_editor_engine_api/lib/testing.dart`
  - `packages/danaview_editor_engine_api/lib/src/engine.dart`
  - `packages/danaview_editor_engine_api/lib/src/preview.dart`
  - `packages/danaview_editor_engine_api/lib/src/media_services.dart`
  - `packages/danaview_editor_engine_api/lib/src/export.dart`
  - `packages/danaview_editor_engine_api/lib/src/recorder.dart`
  - `packages/danaview_editor_engine_api/lib/src/platform_services.dart`
  - `packages/danaview_editor_engine_api/lib/src/capabilities.dart`
  - `packages/danaview_editor_engine_api/lib/src/failures.dart`
  - `packages/danaview_editor_engine_api/lib/src/config.dart`
  - `packages/danaview_editor_engine_api/lib/src/fake/`
  - `packages/danaview_editor_engine_api/test/contract/`
- **Spec:** Flutter package (no native code), deps flutter, meta, collection, danaview_editor_core. Declare the complete contract of ARCH §12.1-12.5 verbatim: EditorEngine, EditorEngineConfig, PreviewConfig/PreviewSession/PreviewClock/SeekAck/PlanAck/SeekKind/PreviewQuality/PreviewEditingMode/PreviewEvent, ThumbnailSource/ThumbnailRequest/ThumbnailTile/ThumbnailHandle/ThumbPriority, WaveformSource/WaveformPeaks, MediaJobs/MediaJob/JobPriority/GeneratedAsset/ProxyStatus, SpeechAudioJobRequest/ExtractedSpeechAudio, ExportService/ExportPreflight/ExportJob/ExportJobState/ExportProgress/ExportPhase/ExportResult/ExportWarning, VoiceRecorder/RecordingSession/MicPermission/RecordedAsset/RecordingInterruption, MediaPicker/MediaPickRequest, FileHandoff/FileHandoffResult, MediaAccess (implements core MediaAccessPort), BackgroundWorkGuard/BackgroundLease, ExternalDropTarget/ExternalDrop, EngineSignal/CacheTrimLevel, EditorCapabilities, DeviceTier, BackgroundExportKind, EngineErrorCode, sealed EngineFailure. `typedef EngineMedia = ResolvedMedia`; PickedMedia/MediaProbe/EncodeSettings/RenderPlan are re-exported core types (D-27). D-33 skeleton: placeholders for lib/src/{plan_sync,plan_transport}.dart (API-02), lib/src/math/ and lib/src/reference/ (API-03), lib/src/render_prep/ (API-04). FakeEditorEngine (lib/testing.dart): deterministic fake clock, configurable capabilities, applies plans/patches with core applyPatch and checks `from` revisions (planOutOfSync), exact-seek acks on the frame grid, jobs with scripted progress/cancel, failure injection, call log, a fake texture placeholder. test/contract/engine_contract.dart: reusable contract kit (exported from lib/testing.dart) checking clock seq rules, exact-seek ack, patch revision semantics, transient non-persistence, job cancel semantics, export reattach.
- **Acceptance criteria and tests:** package analyzes clean; FakeEditorEngine passes the contract kit; dependency rules hold (INT-01 test); every public type has dartdoc linking ARCH sections.

#### ENG-01 · Engine plugin: Pigeon surface definitions and generated code, MobileEditorEngine, event router, error mapper

- **Milestone:** M0 · **Area:** Engine (Dart)
- **Depends on:** API-01, INT-01
- **Owns:**
  - `packages/danaview_editor_engine/pubspec.yaml`
  - `packages/danaview_editor_engine/pigeons/engine_api.dart`
  - `packages/danaview_editor_engine/lib/danaview_editor_engine.dart`
  - `packages/danaview_editor_engine/lib/src/mobile_editor_engine.dart`
  - `packages/danaview_editor_engine/lib/src/event_router.dart`
  - `packages/danaview_editor_engine/lib/src/error_mapper.dart`
  - `packages/danaview_editor_engine/lib/src/pigeon/`
  - `packages/danaview_editor_engine/ios/Classes/Pigeon/`
  - `packages/danaview_editor_engine/android/src/main/kotlin/com/vecvel/danaview/editor/engine/pigeon/`
  - `packages/danaview_editor_engine/test/glue/`
- **Spec:** (Split from the former ENG-01 by the review, D-42.) Flutter plugin package (ios, android; desktop not declared) per ARCH §4.4 and §12.6. pigeons/engine_api.dart with pigeon ^29.0.0 (EngineHostApi, PreviewHostApi, JobsHostApi, ExportHostApi incl. `start(..., whenDetached)`, `resume`, `consumeJobRecord`, RecorderHostApi, PlatformHostApi, EngineEventsApi @EventChannelApi multiplexed stream; capabilities message with tier minimal, maxVisualSequences, maxTextureSize) with generated Dart/Swift/Kotlin committed. MobileEditorEngine implements EditorEngine over Pigeon; error_mapper maps FlutterError codes to EngineFailure (unknown -> internal; never a raw PlatformException); event_router demultiplexes EngineEventMsg by sessionId/jobId with native rate limits (clock <= 10 Hz, progress <= 4 Hz, levels 20 Hz). D-33 skeleton: Dart placeholders for mobile_preview_session/mobile_jobs/mobile_recorder/mobile_platform_services/mobile_media_access/mobile_export, and **minimal native placeholders** so the plugin builds from M0: `ios/danaview_editor_engine.podspec`, `ios/Classes/DanaviewEditorEnginePlugin.swift`, `android/build.gradle.kts`, `android/src/main/AndroidManifest.xml` and `DanaviewEditorEnginePlugin.kt` (headers `OWNER: ENG-07` / `OWNER: ENG-08`; the plugin registers no host API, so every call fails with notSupportedOnDevice). The Pigeon surface may still change until ENG-06 freezes it after the spikes.
- **Acceptance criteria and tests:** Dart tests with mocked channels: every EngineErrorCode maps; events demultiplexed and throttled; resumable and completedWhileDetached job records decode; Pigeon regeneration produces no diff; package and placeholders analyze clean.

#### ENG-05 · Test media fixtures and frame barcode readers

- **Milestone:** M0 · **Area:** Engine (Dart)
- **Depends on:** ENG-01
- **Owns:**
  - `packages/danaview_editor_engine/tool/make_fixtures.swift`
  - `packages/danaview_editor_engine/test_fixtures/media/`
  - `packages/danaview_editor_engine/lib/src/testing/frame_barcode.dart`
  - `packages/danaview_editor_engine/example/ios/RunnerTests/Support/FrameBarcode.swift`
  - `packages/danaview_editor_engine/android/src/androidTest/kotlin/com/vecvel/danaview/editor/engine/support/FrameBarcode.kt`
  - `packages/danaview_editor_engine/android/src/test/kotlin/com/vecvel/danaview/editor/engine/support/`
- **Spec:** tool/make_fixtures.swift (macOS, AVAssetWriter + Core Graphics) generates small fixtures into test_fixtures/media/ (total <= 30 MB, committed): frame_counter_1080p30.mp4 (8 s, per-frame barcode + digits), frame_counter_720p25.mp4 and _24 / _48 / _60 variants, clap_flash_av.mp4 (flash frame + click at known times, AAC with edit list and priming), vfr_720p.mp4, hlg_10bit_720p.mov (HEVC Main10 HLG), rotated_90.mov, speech_10s.m4a (synthesized or CC0 speech; licence recorded), surround_5_1.m4a with a centre-only tone, **mono tone fixtures tone_440hz.wav and tone_1khz.wav (10 s, −12 dBFS) and tone_under_video.mp4 (frame_counter video + 1 kHz tone)** for QA-11's pitch and mix checks, still_4k.jpg, alpha.png, mono/stereo WAV. AVFoundation cannot write Matroska or WebM, so **sample_h264_aac.mkv and sample_vp9_opus.webm are small CC0/public-domain files committed with their source URL and licence in the README** (used for iOS refusal paths and Android 'editable when decoders exist'). README with the generation command and, per file, its semantic description (stream layout, durations, barcode ranges). Barcode readers: Dart (decode frame index from an RGBA buffer, used by integration tests via debugCaptureFrame), Swift and Kotlin equivalents for native tests (loading through the example host is verified by ENG-09).
- **Acceptance criteria and tests:** regeneration is **semantically equivalent** (V-U6: same barcodes per frame, durations ±1 frame, stream layout, tone frequency ±1 Hz), not byte-identical, because hardware encoders and synthesized speech change across OS updates; the Dart reader decodes all 240 frames of frame_counter_1080p30 from frames extracted on the dev Mac and the Kotlin reader does the same from PNG frames in a JVM unit test; the MKV/WebM files probe with the expected streams.

#### ENG-09 · Example host app, native test harness and editor CI scripts

- **Milestone:** M0 · **Area:** Engine (Dart)
- **Depends on:** ENG-01, ENG-05
- **Owns:**
  - `packages/danaview_editor_engine/example/pubspec.yaml`
  - `packages/danaview_editor_engine/example/lib/`
  - `packages/danaview_editor_engine/example/ios/Runner/`
  - `packages/danaview_editor_engine/example/ios/Runner.xcodeproj/`
  - `packages/danaview_editor_engine/example/ios/Podfile`
  - `packages/danaview_editor_engine/example/android/`
  - `packages/danaview_editor_engine/example/integration_test/engine_smoke_test.dart`
  - `scripts/ci/editor/android_unit.sh`
  - `scripts/ci/editor/android_emulator.sh`
  - `scripts/ci/editor/ios.sh`
  - `scripts/ci/editor/check_ios_min_os.sh`
- **Spec:** (Split from the former ENG-01, D-42.) example/: host app whose ios RunnerTests target uses an Xcode synchronized folder (so later tickets add test directories without editing the pbxproj) with folder references to ../test_fixtures, core test/fixtures and engine_api test_fixtures; Android source sets expose the same fixtures to src/test and src/androidTest. The example Info.plist **pre-declares every key native tests need** (NSMicrophoneUsageDescription, NSPhotoLibraryAddUsageDescription, BGTaskSchedulerPermittedIdentifiers = [com.vecvel.danaview.export.*]) so IOS-13/14/15 never edit it. CI scripts: android_unit.sh, android_emulator.sh, ios.sh (fails early with the `brew install cmake` instruction when CMake ≥ 3.28 is missing; builds packages/danaview_whisper's xcframework with tool/build_ios_xcframework.sh --if-missing when that script exists; runs check_ios_min_os.sh). check_ios_min_os.sh (D-41): for the engine pod, WhisperCore.xcframework and a built app, fails on any strongly bound symbol introduced after iOS 15.0 or any linked framework/minimum OS above 15.0 (`xcrun vtool -show-build`, `nm -um`, `otool -L`, with an allowlist of weak-linked frameworks such as BackgroundTasks).
- **Acceptance criteria and tests:** `flutter build ios --no-codesign` and `flutter build apk` of the example pass with ENG-01's placeholder plugin classes; ENG-05 fixtures load in RunnerTests and androidTest; CI scripts green in danaview-ci; check_ios_min_os.sh fails on a negative fixture (a binary with a strongly bound iOS 17 symbol) and passes on the example; V-N8 (@EventChannelApi on Swift + Kotlin) confirmed once ENG-07/ENG-08 land (recorded in their PRs).

#### ENG-07 · iOS plugin glue, engine core and native service placeholders

- **Milestone:** M0 · **Area:** iOS native
- **Depends on:** ENG-09
- **Owns:**
  - `packages/danaview_editor_engine/ios/danaview_editor_engine.podspec`
  - `packages/danaview_editor_engine/ios/Resources/PrivacyInfo.xcprivacy`
  - `packages/danaview_editor_engine/ios/Classes/DanaviewEditorEnginePlugin.swift`
  - `packages/danaview_editor_engine/ios/Classes/Glue/`
  - `packages/danaview_editor_engine/ios/Classes/Core/EngineContext.swift`
  - `packages/danaview_editor_engine/ios/Classes/Core/ErrorCodes.swift`
  - `packages/danaview_editor_engine/ios/Classes/Core/EventHub.swift`
  - `packages/danaview_editor_engine/ios/Classes/Core/Log.swift`
  - `packages/danaview_editor_engine/ios/Classes/Core/Paths.swift`
  - `packages/danaview_editor_engine/example/ios/RunnerTests/Glue/`
- **Spec:** (Split from the former ENG-01, D-42.) Thin Swift glue for every host API of ARCH §12.6 against ENG-01's generated Pigeon code: validate arguments, hop to engine queues, delegate to service protocols, reply asynchronously, never block. D-33 skeleton: placeholder classes for every iOS service file of ARCH §4.4 (IOS-02..IOS-18, incl. Media/{SegmentedWriter,SegmentConcat,SegmentCheckpoint}, Core/JobInterruption and Audio/{GainTap,TapEnvelope}) returning notSupportedOnDevice. Core: EngineContext, ErrorCodes, EventHub, Log (no paths), Paths (Dart-supplied roots only). podspec: platform :ios '15.0', Swift, source_files Classes/**, `OTHER_CFLAGS` with `-Werror=unguarded-availability-new` (Swift already rejects unguarded newer APIs), resource bundle with PrivacyInfo.xcprivacy (FileTimestamp C617.1, DiskSpace E174.1, SystemBootTime 35F9.1); no bundled media resources (the spacer is generated at runtime by IOS-08).
- **Acceptance criteria and tests:** `pod lib lint` (static, iOS 15) passes; capabilities() round-trips on the iOS simulator through the example host (placeholder capabilities: supported false); glue tests in RunnerTests/Glue green (argument validation, error code mapping, queue hops); V-N8 recorded.

#### ENG-08 · Android plugin glue, engine core, Gradle, manifest and native service placeholders

- **Milestone:** M0 · **Area:** Android native
- **Depends on:** ENG-09
- **Owns:**
  - `packages/danaview_editor_engine/android/build.gradle.kts`
  - `packages/danaview_editor_engine/android/lint.xml`
  - `packages/danaview_editor_engine/android/src/main/AndroidManifest.xml`
  - `packages/danaview_editor_engine/android/src/main/res/xml/danaview_editor_file_paths.xml`
  - `packages/danaview_editor_engine/android/src/main/kotlin/com/vecvel/danaview/editor/engine/DanaviewEditorEnginePlugin.kt`
  - `packages/danaview_editor_engine/android/src/main/kotlin/com/vecvel/danaview/editor/engine/glue/`
  - `packages/danaview_editor_engine/android/src/main/kotlin/com/vecvel/danaview/editor/engine/core/EngineContext.kt`
  - `packages/danaview_editor_engine/android/src/main/kotlin/com/vecvel/danaview/editor/engine/core/ErrorCodes.kt`
  - `packages/danaview_editor_engine/android/src/main/kotlin/com/vecvel/danaview/editor/engine/core/EventHub.kt`
  - `packages/danaview_editor_engine/android/src/main/kotlin/com/vecvel/danaview/editor/engine/core/EngineThreads.kt`
  - `packages/danaview_editor_engine/android/src/main/kotlin/com/vecvel/danaview/editor/engine/core/Paths.kt`
  - `packages/danaview_editor_engine/android/src/test/kotlin/com/vecvel/danaview/editor/engine/glue/`
- **Spec:** (Split from the former ENG-01, D-42.) Thin Kotlin glue for every host API against ENG-01's generated Pigeon code. D-33 skeleton: placeholder classes for every Android service file of ARCH §4.4 (AND-02..AND-17, incl. preview/{PausedFrameRenderer,LayerCompositorGl,StructuralDebouncer} and the empty preview/fallback/ package) returning notSupportedOnDevice. Core: EngineContext, ErrorCodes, EventHub, EngineThreads (danaview-preview, danaview-gl, danaview-export, danaview-jobs, danaview-io), Paths. build.gradle.kts: minSdk 24, Media3 1.11.1 (transformer, effect, exoplayer, common, inspector, inspector-frame, muxer), concurrent-futures, activity (V-N14); lint.xml makes `UnstableApi` and `ExperimentalApi` opt-in-required errors so every Media3 file carries `@OptIn(UnstableApi::class, ExperimentalApi::class)`. Plugin manifest per ARCH §20.4 (RECORD_AUDIO, POST_NOTIFICATIONS, FOREGROUND_SERVICE_MEDIA_PROCESSING, FOREGROUND_SERVICE_DATA_SYNC, WRITE_EXTERNAL_STORAGE maxSdk 28, ExportService mediaProcessing|dataSync, FileProvider ${applicationId}.danaview.editor.files, Photo Picker backport ModuleDependencies entry).
- **Acceptance criteria and tests:** capabilities() round-trips on an Android emulator through the example host; glue JVM tests green; lint fails on a negative fixture missing the opt-in; V-N14 recorded; manifest merge of the example app clean.

#### AI-01 · Vendor whisper.cpp v1.9.4 (pruned) with re-vendor script

- **Milestone:** M0 · **Area:** AI (whisper + transcription)
- **Depends on:** —
- **Owns:**
  - `packages/danaview_whisper/third_party/`
  - `packages/danaview_whisper/tool/vendor_whisper.sh`
  - `packages/danaview_whisper/LICENSE-THIRD-PARTY.md`
- **Spec:** ai.md §4.2: vendor whisper.cpp v1.9.4 (commit 927cfce34f31707e17f2bff35c349632fb9e2c3a, ggml 0.23.0) pruned to ~7.8 MB / ~192 files under third_party/whisper.cpp with third_party/VENDORED.md (commit, tarball sha256, pruning list). tool/vendor_whisper.sh downloads the tagged tarball, checks its sha256 and reproduces the tree byte for byte. LICENSE-THIRD-PARTY.md with MIT notices for whisper.cpp and ggml. Review the v1.9.5 (`d1be6fde`, 2026-10-06) changelog: either re-pin to v1.9.5 (update the commit, tarball sha256 and ARCH §16.1) or record in VENDORED.md why v1.9.4 stays.
- **Acceptance criteria and tests:** the script reproduces the committed tree with no diff; a host CMake configure + build of libwhisper with the ai.md §4.3 (Android) and §4.4 (iOS) option sets succeeds on macOS using only the pruned tree (V-A9); the v1.9.5 decision is recorded.

#### AI-02 · danaview_whisper FFI plugin skeleton and C ABI header

- **Milestone:** M0 · **Area:** AI (whisper + transcription)
- **Depends on:** AI-01
- **Owns:**
  - `packages/danaview_whisper/pubspec.yaml`
  - `packages/danaview_whisper/ffigen.yaml`
  - `packages/danaview_whisper/lib/danaview_whisper.dart`
  - `packages/danaview_whisper/lib/src/ffi/dv_whisper_bindings.g.dart`
  - `packages/danaview_whisper/lib/src/support.dart`
  - `packages/danaview_whisper/src/dv_whisper.h`
  - `packages/danaview_whisper/test/abi/`
- **Spec:** ai.md §4.5/§4.7: FFI plugin (ffiPlugin: true for ios and android only; no desktop plugin platforms) exposing WhisperSupport (supported | unsupported(platform|abi|osVersion)), and the public Dart API names of ai.md §4.7 (WhisperRuntime, WhisperModel, WhisperJob, ...). src/dv_whisper.h is the C ABI version 1 (jobs on native threads, poll status/segments, cancel/pause flags, dv_shutdown_all, dv_model_info). ffigen output committed and regenerated without diff in CI. D-33 skeleton: placeholders for lib/src/runtime/ and lib/src/ffi/library_loader.dart (AI-07), lib/src/device/ (AI-06), ios/danaview_whisper.podspec (AI-05; builds without the native library), android/build.gradle.kts + manifest (AI-04; no CMake yet), ios/Classes and android kotlin plugin classes (AI-06). No DynamicLibrary is opened at import time.
- **Acceptance criteria and tests:** on macOS/Windows/Linux the package compiles and WhisperRuntime.open() returns unsupported(platform); desktop release workflows stay green; ABI version check test; ffigen regeneration has no diff.

#### AI-08 · danaview_transcription package: contracts, catalog, languages, consent types, fake

- **Milestone:** M0 · **Area:** AI (whisper + transcription)
- **Depends on:** AI-02, CORE-03
- **Owns:**
  - `packages/danaview_transcription/pubspec.yaml`
  - `packages/danaview_transcription/lib/danaview_transcription.dart`
  - `packages/danaview_transcription/lib/testing.dart`
  - `packages/danaview_transcription/lib/src/contracts/`
  - `packages/danaview_transcription/lib/src/catalog/speech_model_catalog.dart`
  - `packages/danaview_transcription/lib/src/catalog/catalog.dart`
  - `packages/danaview_transcription/lib/src/languages/`
  - `packages/danaview_transcription/test/contracts/`
  - `packages/danaview_transcription/test/catalog/`
- **Spec:** Pure Dart logic package (deps: danaview_editor_core, danaview_whisper, danaview_data; no widgets). contracts/: TranscriptionService with the D-21 extended interface (offers, preflight, start, resegment, activeJob, resumableFor, provideLanguage, cancel, events), job/phase/progress/ETA types, TranscriptionFailure and ModelDownloadFailureKind (ARCH §16.5), ConsentDisclosure.of(spec) and UserConsent (UserConsent.accepted(disclosure, acceptedAt) constructor; its call site is restricted by UX-01's architecture test), the D-28 ports SpeechAudioExtractor and BackgroundLeaseProvider, TimelineView adapter interface. catalog/: SpeechModelSpec with host constant 'huggingface.co' and CDN 'hf.co', pinned revisions, the four files with exact bytes and sha256 (ARCH §16.2), tiers Fast/Balanced/Accurate gated by RAM (Accurate hidden < 4 GB), and a placeholder catalog/tuning.dart holding ai.md defaults (owned by QA-06 afterwards). languages/: the 99 whisper languages (yue excluded) with BCP-47 tags, native names and script profiles. D-33 skeleton placeholders for models_store/ (AI-09), transcript/ (AI-10), segmentation/ (AI-11), timeline/ (AI-12), pipeline/ and governor/ (AI-13). lib/testing.dart: FakeTranscriptionService (scriptable phases, failures, download progress, resumable jobs).
- **Acceptance criteria and tests:** catalog and language tests (sizes, hashes, tier gating, BCP-47 mapping); fake drives every phase; package analyzes clean; dependency rules hold.

#### UI-01 · danaview_ui_kit additions: progress bar, number field, colour picker, docked panel, search field, step indicator

- **Milestone:** M0 · **Area:** UI/UX
- **Depends on:** —
- **Owns:**
  - `packages/danaview_ui_kit/lib/src/components/danaview_progress_bar.dart`
  - `packages/danaview_ui_kit/lib/src/components/danaview_number_field.dart`
  - `packages/danaview_ui_kit/lib/src/components/danaview_color_picker.dart`
  - `packages/danaview_ui_kit/lib/src/components/danaview_docked_panel.dart`
  - `packages/danaview_ui_kit/lib/src/components/danaview_search_field.dart`
  - `packages/danaview_ui_kit/lib/src/components/danaview_step_indicator.dart`
  - `packages/danaview_ui_kit/lib/danaview_ui_kit.dart`
  - `packages/danaview_ui_kit/test/editor_components_test.dart`
- **Spec:** ux.md §3.2: six generic components built from existing kit tokens (DanaviewColors, DanaviewRadius, DanaviewShadows.subtle/soft, DanaviewBorders.hairline, Figtree via DanaviewTextStyles), no Material visuals: DanaviewProgressBar (determinate/indeterminate, semantics value), DanaviewNumberField (typed numeric entry with unit, step buttons, clamping, keyboard up/down, semantics adjustable), DanaviewColorPicker (HSV area + hue strip + hex field + swatches + optional eyedropper callback), DanaviewDockedPanel (non-modal bottom dock with default/expanded detents and drag handle, used by the inspector in compactPortrait), DanaviewSearchField, DanaviewStepIndicator. Export lines added to lib/danaview_ui_kit.dart (only this ticket edits the barrel in this release).
- **Acceptance criteria and tests:** each component passes the kit's existing surface/overflow helpers at widths 280-1280 and text scale 0.85-1.35; keyboard, focus and semantics tests; foreground contrast via DanaviewColors.foregroundOn; no forbidden Material widgets (grep test in the test file).

#### UX-01 · danaview_editor package scaffold, availability gate, providers, contracts, wiring, placeholders

- **Milestone:** M0 · **Area:** UI/UX
- **Depends on:** API-01, AI-08, UI-01, CORE-04
- **Owns:**
  - `packages/danaview_editor/pubspec.yaml`
  - `packages/danaview_editor/analysis_options.yaml`
  - `packages/danaview_editor/lib/danaview_editor.dart`
  - `packages/danaview_editor/lib/src/app/editor_availability.dart`
  - `packages/danaview_editor/lib/src/app/editor_providers.dart`
  - `packages/danaview_editor/lib/src/app/editor_prefs.dart`
  - `packages/danaview_editor/lib/src/editor/contracts/`
  - `packages/danaview_editor/lib/src/editor/wiring/`
  - `packages/danaview_editor/lib/src/debug/`
  - `packages/danaview_editor/test/support/`
  - `packages/danaview_editor/test/architecture/`
  - `packages/danaview_editor/test/app/availability/`
- **Spec:** Create packages/danaview_editor (no go_router dependency: screens take navigation callbacks supplied by the app router; deps: flutter, flutter_riverpod 2, danaview_editor_core, danaview_editor_engine_api, danaview_transcription, danaview_editor_fonts, danaview_ui_kit, danaview_data, danaview_platform, danaview_domain, danaview_features (only via chrome/orientation/storage)). editor_availability: EditorAvailability.platform (synchronous: supported on iOS/Android when DANAVIEW_EDITOR define is true; hidden on desktop, D-17, no teaser state), showsEntryPoints; editorDeviceSupportProvider (async from capabilities). editor_providers: root providers of ARCH §17.3 (overridden by EditorBootstrap) and per-project family declarations; editor_prefs: `editor.` SharedPreferences keys. contracts/: EditorActionId (complete list of ARCH §17.6), ToolId, InspectorRoute. wiring/action_bindings.dart merges the per-feature binding files. debug/: rebuild counters and perf hooks used by QA-04. D-33 skeleton: placeholders (owner header, declared public widget/class names, 'not available yet' UI) for every danaview_editor file listed in ARCH §4.6, every actions/bindings/<feature>_bindings.dart named in BUILD_PLAN, assets/looks/ (README placeholder, folder declared in pubspec) and packages/danaview_editor_fonts/pubspec.yaml (package placeholder owned by UX-30). The pubspec declares every dependency the package needs in this release (incl. dev: flutter_test, integration_test). test/support/: FakeProjectRepository wrapper over core InMemoryProjectRepository (once available; stub until CORE-25), EditorTestHarness (ProviderScope with FakeEditorEngine, fake repo, FakeTranscriptionService), SurfaceMatrix helpers (ARCH §17.9 sizes and text scales, takeException/expectInside/fitsFully), and `expectOwnerUiRules(tester)` (fails when a DanaviewPressable with a text label has a circular shape, or chrome text resolves to a family other than Figtree; content text inside the preview overlay is exempt). test/architecture/: no-Material-chrome scan of lib/ (ARCH §1.3 list, whole-identifier matching), UserConsent.accepted( call-site restriction (rule 8), pubspec import rule 7.
- **Acceptance criteria and tests:** package and placeholders analyze clean; availability matrix tests (platform × flags; desktop always hidden); architecture tests green and failing on negative fixtures (incl. `TextField` used directly, while `DanaviewTextField` passes); expectOwnerUiRules fails on a round text button fixture and a non-Figtree chrome fixture; harness boots a placeholder EditorScreen.

#### UX-02 · Orientation owner stack (ScreenOrientationPolicy)

- **Milestone:** M0 · **Area:** UI/UX
- **Depends on:** —
- **Owns:**
  - `packages/danaview_features/lib/src/player/danaview_player_actions.dart`
  - `packages/danaview_features/lib/src/player/screen_orientation_policy.dart`
  - `packages/danaview_features/lib/orientation.dart`
  - `test/editor_entry/orientation_policy_test.dart`
- **Spec:** ux.md §4.5: ScreenOrientationPolicy owner stack with enter(owner, mode)/release(owner)/toggle, OrientationMode (appDefault, playerLandscape, free ...); the top owner's mode is applied; releasing a non-top owner keeps the top; PlayerOrientation keeps its public API as a thin wrapper so existing player code and tests are unchanged. New entry point lib/orientation.dart exports the policy for danaview_editor.
- **Acceptance criteria and tests:** existing player orientation tests pass unchanged; new tests: editor over player -> pop restores the player mode; non-top release keeps top; app default restored when the stack empties; desktop no-op.

#### UX-03 · Home header edit button and features chrome entry point

- **Milestone:** M0 · **Area:** UI/UX
- **Depends on:** —
- **Owns:**
  - `packages/danaview_features/lib/src/library/danaview_home_screen.dart`
  - `packages/danaview_features/lib/chrome.dart`
  - `test/editor_entry/home_edit_button_test.dart`
- **Spec:** ARCH §17.1: new optional DanaviewHomeScreen.onOpenEditor callback (null hides the button) threaded to _HomeHeader; DanaviewIconButton(icon: Icons.movie_edit, variant: tonal, size: 44, iconSize: 22, tooltip: 'Video editor', semanticLabel: 'Open video editor') placed immediately LEFT of the settings gear with DanaviewSpacing.sm between them; the title keeps >= 96 px at 280 px width and text scale 1.35 (ellipsizes before the buttons shrink). lib/chrome.dart exports the shared screen chrome danaview_editor may reuse (screen scaffold/header/back button/settings row widgets as listed in ux.md §3.3); danaview_features never imports editor packages.
- **Acceptance criteria and tests:** widget tests: button order [logo, title, edit, gear]; hidden when callback null; tap invokes callback; no overflow at 280/320/390 px × 0.85/1.0/1.35; existing home tests pass unchanged.

### M1: Editing core and de-risking spikes

#### CORE-07 · Geometry, text layout spec and text animation evaluation

- **Milestone:** M1 · **Area:** Core (pure Dart)
- **Depends on:** CORE-05, CORE-06
- **Owns:**
  - `packages/danaview_editor_core/lib/src/eval/geometry.dart`
  - `packages/danaview_editor_core/lib/src/eval/text_layout_spec.dart`
  - `packages/danaview_editor_core/lib/src/eval/text_animation_eval.dart`
  - `packages/danaview_editor_core/test/geometry/`
- **Spec:** The single implementation of placement math used by the UI, compiler and AI. geometry.dart: baseSize(fit, crop, source display size, canvas), the placement matrix M = T(cx,cy)·R(r° cw, y-down)·S(s·(fx?-1:1), s·(fy?-1:1))·T(-base.w/2, -base.h/2) exactly as ARCH §11.6 'Place', boxAt(item, t, canvas) (keyframe-aware via evaluate), inverse mapping and hit tests, canvas <-> normalized conversions (positions are canvas fractions with 0 = centre; text sizes in points at a 1,080 px short side). text_layout_spec.dart: TextLayoutSpec data (text, style, maxWidth px, canvas, scale), textLayoutSpecOf(item, canvas) and cueLayoutSpecOf(cue, track, canvas) (layout itself is Flutter, API-04). text_animation_eval.dart: evaluateTextAnimation(item, t, canvas) per ARCH §6.6 (ease-out cubic 1-(1-x)^3 sampled at 6 linear segments; fade, slide 10% of min(W,H) + fade, scale 0.6->1 + fade, typewriter floor(n·p) grapheme clusters via package:characters; out mirrors) returning {opacity, offset, scale, revealCount} plus breakpoints(item) for the compiler.
- **Acceptance criteria and tests:** matrix unit tests incl. flips, 90° rotations, crop+fit combinations; boxAt of keyframed items exact at keys; animation values exact at breakpoints; typewriter counts graphemes (emoji ZWJ, combining marks, CJK).

#### CORE-08 · Validator and repair

- **Milestone:** M1 · **Area:** Core (pure Dart)
- **Depends on:** CORE-05, CORE-06
- **Owns:**
  - `packages/danaview_editor_core/lib/src/validate/`
  - `packages/danaview_editor_core/test/validate/`
  - `packages/danaview_editor_core/test/support/random_project.dart`
- **Spec:** lib/src/validate/: validate(project, {Set<TrackId>? only}) -> List<Violation> for invariants I1-I9 (ARCH §6.9, domain.md §5); repair(project) -> (EditProject, List<ProjectOpenWarning>) that never refuses: snaps edges/keys/markers to the grid, moves overlapping items to new lanes, drops dangling transitions/links/keys, clamps source ranges and speeds, restores exactly one main track, removes empty cues, fixes band order and fades. test/support/random_project.dart: seeded random valid-project generator (tracks of every kind, ramps, keys, transitions, links, cues) shared with CORE-34 and benchmarks.
- **Acceptance criteria and tests:** each invariant has a failing fixture and a repair test (repair output validates); incremental `only:` equals full validation on 500 random projects; full validate of 2,000 items <= 5 ms and one track <= 0.5 ms on the CI host (benchmark test with a 3x CI factor).

#### CORE-36 · Visual packing and per-platform layer counts

- **Milestone:** M1 · **Area:** Core (pure Dart)
- **Depends on:** CORE-03
- **Owns:**
  - `packages/danaview_editor_core/lib/src/eval/visual_packing.dart`
  - `packages/danaview_editor_core/test/eval/packing/`
  - `packages/danaview_editor_core/test/fixtures/vectors/packing.json`
- **Spec:** ARCH §13.5 and D-14 (review issue 3). `packVisualLayers(List<PackInput(id, z, t0, t1, decoderBacked)>) -> PackResult {seqOf(id), slotCount, peakConcurrentDecoders}`: layers in one slot never overlap in time; slots have a fixed stacking order, so two lanes share a slot only when no layer of another slot that overlaps either in time lies between them in z during the overlap; deterministic greedy first-fit in ascending z then t0; transition A/B windows take a second slot only for the overlapping layers. `packingInputsOf(project, {laneFilter})` derives the inputs from the model with the lowering rules for overlap transitions (left extended to c + d/2, right to c − d/2) so LayerLimits can run after every command without compiling, incrementally per changed lane. The compiler (CORE-30) assigns `seq` from the same function; packing.json vectors (inputs → seq, slotCount, peak) are read by IOS-08 and AND-08 tests.
- **Acceptance criteria and tests:** rule properties on 1,000 seeded random layer sets (no time overlap within a slot, z order preserved against every overlapping slot, determinism); six short non-overlapping PiP lanes pack into ≤ 2 slots; an interleaving case refuses to share; model-derived inputs equal the compiled layers' ranges on compile fixtures (checked again in CORE-30); incremental update of one lane at 2,000 items <= 0.5 ms (benchmark test).

#### CORE-09 · Command framework, dry run, placement and limits

- **Milestone:** M1 · **Area:** Core (pure Dart)
- **Depends on:** CORE-08, CORE-36
- **Owns:**
  - `packages/danaview_editor_core/lib/src/ops/edit_command.dart`
  - `packages/danaview_editor_core/lib/src/ops/rejections.dart`
  - `packages/danaview_editor_core/lib/src/ops/outcome.dart`
  - `packages/danaview_editor_core/lib/src/ops/edit_context.dart`
  - `packages/danaview_editor_core/lib/src/ops/placement.dart`
  - `packages/danaview_editor_core/lib/src/ops/dry_run.dart`
  - `packages/danaview_editor_core/lib/src/ops/limits.dart`
  - `packages/danaview_editor_core/lib/src/ops/commands/composite.dart`
  - `packages/danaview_editor_core/test/ops/framework/`
- **Spec:** ARCH §7.1. edit_command.dart is the library declaring `sealed class EditCommand` with `part` directives for every group file of ARCH §7.2 (clip_commands, ripple, clipboard_commands, speed_commands, property_commands, keyframe_commands, text_commands, subtitle_commands, caption_commands, transition_commands, track_commands, marker_commands, project_commands, composite). This ticket is a D-33 skeleton for those part files: create `part of` placeholders with `// OWNER: CORE-xx`. Each command implements `EditOutcome applyTo(EditProject, EditContext)` and `EditPreview previewOn(...)` so no central switch exists and group tickets never edit edit_command.dart. applyCommand/dryRun share one code path; EditRejection sealed set exactly as ARCH §7.1 (data, never thrown); exceptions -> InternalInconsistency; post-step validation of changed tracks (violation -> InternalInconsistency, project unchanged); noop detection; EditContext/EditPolicy; placement.dart: nearest free lane of the same kind, creating one (D-11), clamp support; limits.dart: LayerLimits (peak concurrent decoder-backed video layers vs policy.maxConcurrentVideoLayers and packed visual sequences vs policy.maxVisualSequences, both from CORE-36's visual_packing.dart computed incrementally for the changed lanes; maxItems 5,000; 24 h) checked generically after every command -> LimitExceeded(what, limit) (D-14). CompositeCommand is atomic.
- **Acceptance criteria and tests:** purity (same input + seeded ids -> equal output); rejections never throw; composite all-or-nothing; both limits enforced on fixtures (incl. six sparse PiP lanes that pass the sequence cap after packing and a seventh overlapping lane that fails it); dryRun incl. limits <= 1 ms at 1,000 items (benchmark test).

#### CORE-10 · Structural clip commands and ripple

- **Milestone:** M1 · **Area:** Core (pure Dart)
- **Depends on:** CORE-09, CORE-06
- **Owns:**
  - `packages/danaview_editor_core/lib/src/ops/commands/clip_commands.dart`
  - `packages/danaview_editor_core/lib/src/ops/commands/ripple.dart`
  - `packages/danaview_editor_core/test/ops/clip/`
- **Spec:** InsertMedia(media, track?, at, mode auto|ripple|newLane), MoveItems(ids, delta, toTrack?, ripple), TrimItem(id, edge, newTime, ripple, clamp), SplitItems(ids, at), DeleteItems(ids, ripple), DeleteGap(gap) per ARCH §7.2 and domain.md §6.2-6.3. Rules: ripple affects the edited lanes plus lanes of linked partners (D-10); non-ripple moves/inserts into occupied space go to the nearest free lane of the same kind (D-11, via placement.dart); on the main lane with ripple on, inserts and moves snap to the nearest cut; links move/split/delete together; keyframes shift/partition (keyframe_ops); fades clamp to duration/2; transitions are dropped when adjacency breaks; locked tracks reject (TrackLocked); clamp mode returns the nearest valid result in EditPreview.clampedTo; all edges on the grid; images/stills get policy.defaultImageUs.
- **Acceptance criteria and tests:** before/after golden tests for every command including ripple, link, lock, clamp and new-lane cases; split concatenation equals the original time map at every frame (property test); trim respects source range and 1-frame minimum; ripple never moves items on unrelated lanes.

#### CORE-11 · Duplicate, clipboard, replace, extract audio, links, selection

- **Milestone:** M1 · **Area:** Core (pure Dart)
- **Depends on:** CORE-10
- **Owns:**
  - `packages/danaview_editor_core/lib/src/ops/commands/clipboard_commands.dart`
  - `packages/danaview_editor_core/lib/src/ops/clipboard.dart`
  - `packages/danaview_editor_core/lib/src/ops/selection.dart`
  - `packages/danaview_editor_core/test/ops/clipboard/`
- **Spec:** DuplicateItems, PasteItems(payload, at, preferTrack?) (cross-project paste adds pool entries and mints new ids), ReplaceMedia (keeps range/effects/keys; shortens with a notice when the new media is shorter), ExtractAudio (adds a linked audio clip with AudioRole.original sharing the ClipTimeMap and sets detachedAudio on the video clip), LinkItems/UnlinkItems; ops/clipboard.dart: copyItems -> ClipboardPayload (self-contained items + referenced pool assets + relative offsets); Cut = copy + DeleteItems in one CompositeCommand (D-16); ops/selection.dart: SelectionRules.expand (adds link partners, drops locked items), selection hints. Pastes into occupied space follow D-11.
- **Acceptance criteria and tests:** golden tests for each; cross-project paste mints fresh ids and imports pool entries exactly once; replace with shorter media clamps and emits EditNotice; extracted audio stays in sync at every frame (shared map); SelectionRules.expand table test.

#### CORE-12 · Speed, reverse and freeze-frame commands

- **Milestone:** M1 · **Area:** Core (pure Dart)
- **Depends on:** CORE-10
- **Owns:**
  - `packages/danaview_editor_core/lib/src/ops/commands/speed_commands.dart`
  - `packages/danaview_editor_core/test/ops/speed/`
- **Spec:** SetSpeed(item, spec, maintainPitch): presets 0.25/0.5/0.75/1/1.25/1.5/2/3/4 and custom in [0.1, 10] (D-15), ramps of 2-16 points; keeps the source range and recomputes duration = max(1 frame, quantizeNearest(T)); keys scale; following items handled per domain.md §6.2 (ripple setting, D-10/D-11); linked audio gets the same spec. SetReversed(item, on) flips only the flag and references/creates the DerivedSpec.reversed(media, range) pool entry (status pending until the engine job finishes; session updates it). FreezeFrame(item, at, duration, stillMedia): splits at `at` and inserts a still (DerivedSpec.still) of `duration` with ripple on the edited lane (domain.md §6.4).
- **Acceptance criteria and tests:** duration math tests for every preset and ramp preset; keys scale exactly; reverse round-trips (reverse twice == original); freeze inserts at the split with ripple and correct still time; speeds outside [0.1, 10] -> InvalidValue.

#### CORE-13 · Property and keyframe commands

- **Milestone:** M1 · **Area:** Core (pure Dart)
- **Depends on:** CORE-09, CORE-05
- **Owns:**
  - `packages/danaview_editor_core/lib/src/ops/commands/property_commands.dart`
  - `packages/danaview_editor_core/lib/src/ops/commands/keyframe_commands.dart`
  - `packages/danaview_editor_core/test/ops/property/`
- **Spec:** SetProperty<T>(items, key, value, at?) keyframe-aware at a quantized `at` (writes a key when the channel has keys, else the static value), SetVisual, SetAudio, SetLook (BuiltinLook | ImportedLut + intensity), SetChroma, SetMask, SetCrop, ResetTransform (clears transform keys), AddKeyframe/RemoveKeyframe/MoveKeyframe/SetKeyframeValue/ClearKeyframes. Multi-item edits produce one outcome. Value ranges from PropertyKey metadata (InvalidValue otherwise); non-keyframable keys reject keyframe commands (UnsupportedForKind); KeyframeExists on duplicates. Volume keyframes and fades apply to audio and video-with-audio clips.
- **Acceptance criteria and tests:** tests per command incl. multi-item, keyframe-aware writes at quantized times, every rejection, reset transform clearing keys, apply-to-all style batch (one outcome).

#### CORE-14 · Text commands

- **Milestone:** M1 · **Area:** Core (pure Dart)
- **Depends on:** CORE-13, CORE-07
- **Owns:**
  - `packages/danaview_editor_core/lib/src/ops/commands/text_commands.dart`
  - `packages/danaview_editor_core/test/ops/text/`
- **Spec:** AddText (goes to the top free text lane at the playhead, default duration policy.defaultTextUs = 3 s, default style Figtree/48 pt/white/centre), SetText (coalesce key `text:<id>`; EmptyText rejection for whitespace-only), SetTextStyle (font id, size [8,200], bold, italic, align, colour, letterSpacing [-20,100], lineHeight [0.6,3], maxWidth, background box, stroke, shadow), SetTextAnimation (in/out kinds incl. typewriter for in only, durations clamped so in+out <= duration). Text transform edits go through SetProperty (CORE-13).
- **Acceptance criteria and tests:** lane selection tests; style range validation; animation duration clamping; coalescing is verified in CORE-19's session tests (provide the command-level hook here).

#### CORE-15 · Subtitle and generated-caption commands

- **Milestone:** M1 · **Area:** Core (pure Dart)
- **Depends on:** CORE-10
- **Owns:**
  - `packages/danaview_editor_core/lib/src/ops/commands/subtitle_commands.dart`
  - `packages/danaview_editor_core/lib/src/ops/commands/caption_commands.dart`
  - `packages/danaview_editor_core/test/ops/subtitles/`
- **Spec:** Per domain.md §6.7 and ai.md §10.2 (adopted verbatim, schema 1): AddCue (defaultCueUs 2 s, no overlap), SetCueText (sets editedAfterGeneration on generated cues; '\n' line breaks, inline <i>/<b> kept), SetCueRange (start/end timing, no overlap, >= 1 frame), SplitCue(at, textSplit?), MergeCues (adjacent cues, texts joined with a space or newline), DeleteCues, ShiftCues(track, deltaUs, range?) (re-times every cue of a track or of a range as one history entry; deltas quantized to the grid; rejects overlap with cues outside the range, clamps at 0 with a notice), ImportSubtitles(track?, cues, mode newTrack|replace) with overlapping cues spilling to a second track, SetSubtitleStyle/Position/BurnIn/Language, AddGeneratedCaptionTrack(drafts, provenance, language) and ReplaceGeneratedCaptions(track, drafts, provenance, range?) (replaceInRange replaces only overlapping cues). Both AI commands are single commands (one history entry), mint fresh ids, honour TrackLocked, set CueOrigin.generated.
- **Acceptance criteria and tests:** tests for every command incl. overlap rejection, ShiftCues of a whole imported track by ±2.5 s and of a range, split/merge text handling, spill on import, editedAfterGeneration set by any text or timing edit, replace-in-range boundaries, locked-track rejection as data.

#### CORE-16 · Transitions and transition limits

- **Milestone:** M1 · **Area:** Core (pure Dart)
- **Depends on:** CORE-10
- **Owns:**
  - `packages/danaview_editor_core/lib/src/ops/commands/transition_commands.dart`
  - `packages/danaview_editor_core/lib/src/eval/transition_limits.dart`
  - `packages/danaview_editor_core/test/ops/transitions/`
- **Spec:** SetTransition(ref, spec?) (null removes), ApplyTransitionToAll(trackId?, spec) as one command; kinds fade, crossDissolve, dipToBlack, dipToWhite, slide(l|r|u|d), wipe(l|r|u|d), zoom(in|out) (D-16 semantics); duration in frames centred on the cut [cut-floor(n/2), cut+ceil(n/2)). TransitionLimits.of(project, ref) -> maxFrames: all kinds <= 2·min(leftAvail, rightAvail); overlap kinds (crossDissolve, slide, wipe, zoom) also <= 2·min(leftHandle, rightHandle) with handles divided by edge speed, mirrored for reversed clips, infinite for stills/images. Transitions only on video/overlay lanes between touching neighbours.
- **Acceptance criteria and tests:** maxFrames tests for handles, speed, reversed clips and images; TransitionTooLong(maxFrames) rejection; NotAdjacent rejection; apply-to-all clamps per cut and is one command; edits that break adjacency drop the transition (tested with CORE-10 commands).

#### CORE-17 · Track, marker and project-setting commands, requantize

- **Milestone:** M1 · **Area:** Core (pure Dart)
- **Depends on:** CORE-09
- **Owns:**
  - `packages/danaview_editor_core/lib/src/ops/commands/track_commands.dart`
  - `packages/danaview_editor_core/lib/src/ops/commands/marker_commands.dart`
  - `packages/danaview_editor_core/lib/src/ops/commands/project_commands.dart`
  - `packages/danaview_editor_core/lib/src/ops/requantize.dart`
  - `packages/danaview_editor_core/test/ops/tracks/`
- **Spec:** AddTrack/DeleteTrack (CannotDeleteMainTrack)/MoveTrack (within its band only)/RenameTrack/SetTrackFlags (locked, hidden, muted, solo)/SetAudioRole; AddMarker/UpdateMarker/DeleteMarker (on grid; name, colorIndex, note); SetCanvas (aspect + base short side; items untouched because canvas values are normalized), SetFrameRate (runs requantize), SetBackground (Solid | BlurOfMain). requantize(project, newRate): moves every edge, key, marker, transition and fade to the new grid preserving order, minimum durations and adjacency (bounded movement <= 1 new frame).
- **Acceptance criteria and tests:** band ordering enforced; main track protected; requantize properties over all 36 rate pairs on random projects (order preserved, adjacency preserved, movement bounded, result validates); marker commands round-trip.

#### CORE-18 · Snapping index

- **Milestone:** M1 · **Area:** Core (pure Dart)
- **Depends on:** CORE-03
- **Owns:**
  - `packages/danaview_editor_core/lib/src/ops/snapping.dart`
  - `packages/danaview_editor_core/test/ops/snapping/`
- **Spec:** SnapIndex built from a project (item edges per lane, markers, playhead, transition boundaries, optional exclusions for the dragged items): nearest(t, toleranceUs), nearestForRange(range, toleranceUs) returning the best edge pair, and snap target kinds for the UI (clip edge, marker, playhead). Commands never snap; the UI snaps the proposed time before dryRun (ARCH §7.1).
- **Acceptance criteria and tests:** nearest/nearestForRange correct against brute force on random sets; exclusions honoured; build <= 1 ms at 2,000 items, query <= 20 µs (benchmark test).

#### CORE-19 · EditSession: snapshot history, transactions, coalescing

- **Milestone:** M1 · **Area:** Core (pure Dart)
- **Depends on:** CORE-09
- **Owns:**
  - `packages/danaview_editor_core/lib/src/session/`
  - `packages/danaview_editor_core/test/session/`
- **Spec:** ARCH §7.3 / domain.md §7: EditSession {project, history (canUndo, canRedo, undoLabel, redoLabel, position), apply(cmd, {coalesceKey, coalesceWindow 1 s}), dryRun, begin(label) -> SessionTransaction (update applies to the base captured at begin, commit adds exactly one entry or none if unchanged, cancel restores; a second begin cancels the first), undo, redo, jump(n), applyPoolChange (sticky: imports, probe/proxy/status updates), applyPoolEdit (undoable RelinkAssets, RemoveAssets of unused assets only), updateView, retainedMedia()}. Snapshots of the Timeline root (structural sharing), pool outside snapshots, limits 200 entries or ~48 MB approximate bytes (oldest evicted), Timeline.revision and Track.changedAt are session-monotonic stamps never reused after undo, editCount counts committed entries and never decrements. Exceptions from commands become InternalInconsistency.
- **Acceptance criteria and tests:** undo/redo/jump identity tests; coalescing within 1 s by key; transaction update-from-base semantics; pool deltas undoable while imports stay; stamps strictly increase across undo + new edit; eviction by count and bytes; retainedMedia correct.

#### CORE-20 · SRT and WebVTT codec

- **Milestone:** M1 · **Area:** Core (pure Dart)
- **Depends on:** CORE-02
- **Owns:**
  - `packages/danaview_editor_core/lib/src/formats/subtitle_codec.dart`
  - `packages/danaview_editor_core/lib/src/formats/srt.dart`
  - `packages/danaview_editor_core/lib/src/formats/vtt.dart`
  - `packages/danaview_editor_core/lib/src/formats/text_decoding.dart`
  - `packages/danaview_editor_core/test/formats/subtitles/`
  - `packages/danaview_editor_core/test/fixtures/subtitles/`
- **Spec:** ARCH §10.1 exactly: SubtitleCodec.parse(bytes, hint?) -> SubtitleParseResult {format, cues, issues (line, kind), strippedTags, ignoredSettings, detectedEncoding}; serialize(cues, format, offset, bom). Decoding order BOM -> NUL pattern (UTF-16) -> strict UTF-8 -> Windows-1252 -> Latin-1; CRLF/CR/LF. Tolerant SRT (index optional, ',' or '.', 1-3 digit fractions, > 99 h, trailing coordinates ignored); VTT requires WEBVTT, skips NOTE/STYLE/REGION, ignores cue settings, decodes entities; <i>/<b> kept and balanced, other tags and {\an8} stripped; invalid cues become issues. Serialization: half-up ms, SRT numbered from 1 with CRLF, VTT with LF, UTF-8 without BOM, blank lines in a cue collapsed, '-->' -> '->'. Suggested export name `<project>.<bcp47>.srt|vtt`. Callers run parse in Isolate.run (pure function).
- **Acceptance criteria and tests:** corpus in test/fixtures/subtitles (BOMs, UTF-16 LE/BE, CP1252, CJK, RTL, malformed) passes; parse(serialize(x)) == x property test; issues carry line numbers; 10k cues parse <= 100 ms.

#### CORE-21 · .cube parser, .vlut writer/reader, float16

- **Milestone:** M1 · **Area:** Core (pure Dart)
- **Depends on:** CORE-01
- **Owns:**
  - `packages/danaview_editor_core/lib/src/formats/cube_lut.dart`
  - `packages/danaview_editor_core/lib/src/formats/vlut.dart`
  - `packages/danaview_editor_core/lib/src/formats/float16.dart`
  - `packages/danaview_editor_core/test/formats/lut/`
  - `packages/danaview_editor_core/test/fixtures/luts/`
- **Spec:** ARCH §10.2 and D-07: .cube parser (TITLE, LUT_3D_SIZE 2-65, LUT_1D_SIZE converted to 3D 33³ with a notice, DOMAIN_MIN/MAX, Resolve LUT_*_INPUT_RANGE, comments, blank lines; errors with line numbers 'Line 14: expected 3 numbers'; > 65 or > 16 MB -> 'LUTs up to 65×65×65 are supported.'). .vlut v1 little-endian: 'VLUT', u16 version 1, u16 N, N³ RGB float16 red-fastest, domain remapped to [0,1]; no resampling. float16 encode/decode (round-to-nearest-even, subnormals). Pure functions, run by callers in Isolate.run.
- **Acceptance criteria and tests:** corpus (Resolve, Adobe, 1D, domain remap, malformed) passes; identity LUT round-trips within 1/1024; .vlut bytes for a fixture are stable (golden); float16 exhaustive round-trip for all 65,536 patterns; a 65³ parse <= 400 ms on the CI host.

#### API-03 · Render-math vectors, Dart CPU reference renderer, goldens

- **Milestone:** M1 · **Area:** Engine (Dart)
- **Depends on:** API-01, CORE-07, CORE-29
- **Owns:**
  - `packages/danaview_editor_engine_api/lib/src/math/`
  - `packages/danaview_editor_engine_api/lib/src/reference/`
  - `packages/danaview_editor_engine_api/test_fixtures/vectors/`
  - `packages/danaview_editor_engine_api/test_fixtures/images/`
  - `packages/danaview_editor_engine_api/tool/regen_goldens.dart`
  - `packages/danaview_editor_engine_api/test/reference/`
- **Spec:** lib/src/math/: Dart implementation of every ARCH §11.6 stage on straight-alpha gamma-encoded BT.709 values (chroma key + spill, exposure, brightness/contrast, highlights/shadows, saturation, temperature/tint, LUT trilinear over .vlut tables, separable Gaussian blur with σ = blur·0.03·min(W,H) converted by scale, sharpen, vignette, mask SDF (rounded box/ellipse, feather, invert, opacity), placement matrix (must call core geometry), canvas masks, premultiplied source-over, sprite reveal, audio gain interpolation). lib/src/reference/: CPU reference renderer rendering a RenderPlan frame at time t to RGBA (small sizes, used for goldens and parity), and `audio_mix.dart`, the **Dart reference audio mixer** (ARCH §11.6 Audio row: per-sample gain envelopes 0–2, speed maps without pitch processing for analytic cases, downmix, sum, hard clip) used as the oracle by QA-11. test_fixtures/vectors/: JSON vectors for keyframe evaluation, transform M, every render-math row (input pixel -> output pixel), gain envelopes incl. 2.0 (+6.02 dB) and fades/crossfades, mixed audio windows (RMS per 20 ms) for a 3-lane reference project, typewriter reveal, and an 8× scale-keyframed text parity case; test_fixtures/images/: reference PNGs for ~30 plan fixtures × times; tool/regen_goldens.dart regenerates (review required). Joint test: core FrameRate/evaluate/boxAt pass the same vectors.
- **Acceptance criteria and tests:** vectors and goldens committed; reference renderer deterministic across runs; Swift/Kotlin can load vectors (format documented in test_fixtures/README.md); regen tool produces no diff on a clean tree.

#### ENG-06 · [INTEGRATION] Spike outcomes into plugin build config and Pigeon surface

- **Milestone:** M1 · **Area:** Engine (Dart)
- **Depends on:** IOS-01, AND-01, ENG-07, ENG-08
- **Owns:**
  - `packages/danaview_editor_engine/ios/danaview_editor_engine.podspec`
  - `packages/danaview_editor_engine/android/build.gradle.kts`
  - `packages/danaview_editor_engine/android/lint.xml`
  - `packages/danaview_editor_engine/pigeons/engine_api.dart`
  - `packages/danaview_editor_engine/lib/src/pigeon/`
  - `packages/danaview_editor_engine/ios/Classes/Pigeon/`
  - `packages/danaview_editor_engine/ios/Classes/Glue/`
  - `packages/danaview_editor_engine/android/src/main/kotlin/com/vecvel/danaview/editor/engine/pigeon/`
  - `packages/danaview_editor_engine/android/src/main/kotlin/com/vecvel/danaview/editor/engine/glue/`
  - `packages/danaview_editor_engine/lib/src/mobile_editor_engine.dart`
  - `packages/danaview_editor_core/test/fixtures/vectors/frame_grid.json` (the `androidSeekMsRounding` field only)
  - `docs/v1.1/editor/ARCHITECTURE.md`
- **Spec:** [INTEGRATION] Runs only after **both extended spikes have reported** (D-42). Applies the IOS-01 and AND-01 results to files owned by ENG-01/ENG-07/ENG-08, then freezes them: podspec build settings for the precompiled Metal CI kernels (-fcikernel metallib build phase or prebuilt metallib, V-N9), any extra frameworks; build.gradle.kts/lint.xml dependency and opt-in changes; Pigeon message amendments the spikes proved necessary (with regenerated code and glue/placeholder updates); writes AND-01's measured `androidSeekMsRounding` into frame_grid.json; records V-N1..V-N6, V-N9..V-N11, V-N15..V-N25 outcomes, the Android go/no-go (R1), the measured Android `maxVisualSequences` tier values (D-14), the iOS background facts (D-22) and the preview A/V latency (§12.7) in ARCHITECTURE §5/§12.5/§13/§14.2/§24.2. On an AND-01 no-go it also activates AND-16 (ticket status) and blocks M1 exit until the owner signs off its degradations (D-43e). After this ticket the Pigeon surface is frozen; later changes need a new lead-approved [INTEGRATION] ticket.
- **Acceptance criteria and tests:** example app builds on both platforms with the spike regression tests ported into RunnerTests/androidTest where they exercise plugin code; ARCHITECTURE.md updated only in the sections named above; no service behaviour implemented here.

#### IOS-01 · iOS spike (day 1, spike host): Metal CI kernels, compositor, grid timing, exact seek, texture, audio tap, background encoder, reader/writer

- **Milestone:** M1 · **Area:** iOS native
- **Depends on:** — (starts on day 1, D-42; uses self-generated media until ENG-05's fixtures land)
- **Owns:**
  - `spikes/ios_engine/`
  - `docs/v1.1/editor/spikes/IOS-01.md`
- **Spec:** De-risk ARCH §13.2/§14.2 before the iOS engine is built, in a throwaway Xcode host app with XCTest under spikes/ios_engine/ (not shipped, not part of any package; kept for reference). Prove: a precompiled `-fcikernel` metallib builds inside a CocoaPods-style static library target and loads via CIKernel(functionName:fromMetalLibraryData:) on simulator and device (V-N9); AVMutableComposition + custom AVVideoCompositing with a runtime-generated spacer track + AVPlayerItemVideoOutput -> FlutterTexture-style copyPixelBuffer zero-copy; **grid timing (D-35)**: edits inserted at `CMTime(k, 30)` with cuts at frames k ≡ 1 and 2 (mod 3), compositor computing k = round(compositionTime × fps), every frame shows the expected barcode; exact seek ack 200/200 using a `danaview.frame` attachment on the iOS 26 and 18.2 simulators and on the iPhone 7 (iOS 15.8) lab device (V-N10); redraw-from-cache of the last source buffers <= 30 ms; an HLG clip arrives as SDR with supportsHDRSourceFrames = false; AVAssetReader(composition) -> AVAssetWriter export with the same compositor; **MTAudioProcessingTap** on composition audio tracks receives composition-time ranges after scaleTimeRange and gain 2.0 measures +6.02 ± 0.1 dB in AVPlayer and AVAssetReaderAudioMixOutput (V-N21); **background**: on a real iPhone on iOS 18 and on iOS 26, background an export for > 30 s and record what happens (encoder error code, writer status), check that a segmented writer resumes after return, record `BGTaskScheduler.shared.supportedResources.contains(.gpu)` (V-N20, V-N11); whether the Metal CI kernels run on a `.useSoftwareRenderer` CIContext and at what speed (V-N22); preview A/V latency through a Flutter texture measured with frame timings vs audio output timestamps (V-N23). Write docs/v1.1/editor/spikes/IOS-01.md with measurements and the exact podspec/build settings ENG-06 must apply.
- **Acceptance criteria and tests:** all spike tests green on the iOS 26 simulator and one device; grid-cut barcode case 100%; report lists V-N9, V-N10, V-N11, V-N20, V-N21, V-N22, V-N23 outcomes and required build settings.

#### AND-01 · Android spike (day 1, spike host): Media3 1.11.1 multi-sequence CompositionPlayer + Transformer, grid timing, paused edits, rebuild latency, packing

- **Milestone:** M1 · **Area:** Android native
- **Depends on:** — (starts on day 1, D-42; uses self-generated media until ENG-05's fixtures land)
- **Owns:**
  - `spikes/android_engine/`
  - `docs/v1.1/editor/spikes/AND-01.md`
- **Spec:** Go/no-go for ARCH §13.3 (risk R1) in a throwaway Gradle host app with instrumented tests under spikes/android_engine/ (not shipped). Build a Composition with a transparent 2×2 clock band at fps (sequence 0, `trackTypes {VIDEO, AUDIO}`), 3 video sequences with gaps, a background solid and 2 audio-only sequences; custom GlEffects outputting canvas-size straight-alpha textures; LayerGatingCompositorSettings hiding sequences outside their layers using frameIndexNearest(pts). Answer with tests: V-N1 getOverlaySettings input id = sequence index and pts = composition time; V-N2 effect pts sequence-cumulative in CompositionPlayer and Transformer; V-N3 whether experimentalRedrawLastFrame re-runs effects on a **secondary** sequence (change an effect on sequence 2 while paused and assert the pixels change; expected no — the design no longer depends on it); V-N4 straight alpha preserved; V-N5 hdrMode tone-maps HLG; V-N6 upright frames for rotated sources; V-N15 clock band yields export fps above the source rate; V-N16 a mechanism meeting the ε source-frame rule (ARCH §11.5) at clip starts; V-N17 setFrameRate caps fast items; **V-N18 grid timing**: Media3 seek semantics (→ `androidSeekMsRounding`), clock-band pts after seeks and scrubs, secondary-frame selection, and the grid-cut barcode case (cuts at k ≡ 1, 2 mod 3 at 24/30/60 fps with boundaries anchored at P(k)) passing 100% in playback, exact seek and Transformer export; **V-N19**: setComposition → first frame with 2, 4 and 6 sequences on the 4 GB device, a PausedFrameRenderer prototype (FrameExtractor EXACT frames + the same shaders onto the surface with the player surface detached) showing a secondary-sequence effect change, and transient round-trip latency; V-N23 preview A/V latency and whether the audio sink can delay audio; V-N24 the clock band's trackTypes produce a silent AAC track in Transformer output; **V-N25** six overlay lanes of short non-overlapping PiP clips: decoder instances, GPU memory and dropped frames unpacked (6–12 sequences) vs packed (1–2 slots), from which the tier values of `maxVisualSequences` are set. Play at 30 fps at 720p on Pixel 7a and a 4 GB device; exact seek on frame_counter 200/200; Transformer exports the same composition with matching frames (SSIM >= 0.98). Write docs/v1.1/editor/spikes/AND-01.md with the go/no-go, the measured numbers and the build.gradle.kts changes ENG-06 must apply; on no-go, size the AND-16 contingency precisely and list the owner bullets it degrades for sign-off (D-43e).
- **Acceptance criteria and tests:** report committed with every V-N item answered by a test; go/no-go decision recorded; Android structural budgets of ARCH §13.4 confirmed or renegotiated in the report.

#### AI-03 · whisper native C shim and host tests

- **Milestone:** M1 · **Area:** AI (whisper + transcription)
- **Depends on:** AI-02
- **Owns:**
  - `packages/danaview_whisper/src/dv_job.cpp`
  - `packages/danaview_whisper/src/dv_job.h`
  - `packages/danaview_whisper/src/dv_model.cpp`
  - `packages/danaview_whisper/src/dv_model.h`
  - `packages/danaview_whisper/src/dv_whisper.cpp`
  - `packages/danaview_whisper/src/dv_log.cpp`
  - `packages/danaview_whisper/src/dv_log.h`
  - `packages/danaview_whisper/src/CMakeLists.txt`
  - `packages/danaview_whisper/src/tests/`
  - `scripts/ci/editor/whisper_host.sh`
- **Spec:** ai.md §4.6: shim implementing dv_whisper.h — each job on its own std::thread; mutex-guarded status and segment buffer polled by Dart every 250 ms via leaf calls; cancel/pause as atomics read by abort_callback and encoder_begin_callback; strings copied in; model load/unload with refcounts; VAD (Silero) parameters, suppress_nst, token timestamps, language detect mode (DETECT top-3 probabilities), threads; dv_shutdown_all for hot restart; logging without segment text or paths. src/CMakeLists.txt builds the shim + ggml/whisper for host tests (Android/iOS specifics live in AI-04's android.cmake and AI-05's script). Host tests (GoogleTest or Catch2 vendored in tests/) transcribe jfk.wav with ggml-tiny (downloaded by the CI script with sha256 check, cached), cancel/pause/resume, detect, concurrent jobs. whisper_host.sh runs them on ubuntu and the self-hosted Mac, plus TSan and ASan jobs.
- **Acceptance criteria and tests:** all host tests pass on macOS and Linux incl. TSan and ASan (dv_job_free never leaks); grep check proves logs never contain segment text or paths.

#### AI-06 · whisper device profile, thermal/memory events, backup exclusion channel

- **Milestone:** M1 · **Area:** AI (whisper + transcription)
- **Depends on:** AI-02
- **Owns:**
  - `packages/danaview_whisper/lib/src/device/`
  - `packages/danaview_whisper/ios/Classes/DanaviewWhisperPlugin.swift`
  - `packages/danaview_whisper/ios/Classes/DeviceProfiler.swift`
  - `packages/danaview_whisper/android/src/main/kotlin/com/vecvel/danaview/whisper/`
  - `packages/danaview_whisper/android/src/test/`
  - `packages/danaview_whisper/test/device/`
- **Spec:** ai.md §4.8: method + event channel `danaview_whisper/device`: device profile (RAM, available memory via os_proc_available_memory on iOS (V-A2) / ActivityManager.MemoryInfo on Android, perf/efficiency core counts, CPU features incl. dotprod/fp16, Apple GPU family, OS version), thermal state events (nominal/fair/serious/critical mapping, unit-tested in Kotlin), low-power mode, memory warnings, app lifecycle background/foreground events, excludeFromBackup(path) (iOS URLResourceValues), and iOS beginBackgroundTask/endBackgroundTask for downloads with expiry events. Dart side parses defensively.
- **Acceptance criteria and tests:** Dart unit tests with malformed maps; Kotlin thermal mapping tests; manual checklist on one iOS and one Android device (recorded in the PR); excludeFromBackup verified via URLResourceValues read-back.

### M2: Persistence, RenderPlan compiler, native media services, speech core

#### CORE-22 · Project JSON codec, fragment cache, schema version

- **Milestone:** M2 · **Area:** Core (pure Dart)
- **Depends on:** CORE-03, CORE-04, CORE-05
- **Owns:**
  - `packages/danaview_editor_core/lib/src/codec/project_json.dart`
  - `packages/danaview_editor_core/lib/src/codec/fragment_cache.dart`
  - `packages/danaview_editor_core/lib/src/codec/schema_version.dart`
  - `packages/danaview_editor_core/schema/project.v1.schema.json`
  - `packages/danaview_editor_core/test/codec/`
- **Spec:** ARCH §8.2 body conventions: integer µs, '#RRGGBBAA', shortest round-trip doubles, default-valued fields omitted, fixed key order (deterministic bytes), items tagged "t":"clip"|"text"|"cue", enums as lower-camel strings, unknown enum values -> default + ProjectOpenWarning; the header line model (format, schema 1, minReader 1, app, savedAt, docRevision, saveId, bodyBytes, bodySha256) is defined in schema_version.dart, written by CORE-24. FragmentCache: Expando keyed by object identity so re-encoding after a one-item edit only re-serializes changed tracks/items. schema/project.v1.schema.json is the normative body schema. ai.md provenance/origin fields are part of schema 1.
- **Acceptance criteria and tests:** decode(encode(p)) == p on 500 random projects (CORE-08 generator); deterministic bytes; a project using every locator kind under a fake `/var/mobile/Containers/Data/Application/<uuid>/` root encodes with no persisted string containing the container prefix (only BookmarkLocator.lastKnownPath may, as a hint; ARCH §8.2); incremental re-encode after a one-item edit <= 3 ms at 2,000 items; unknown enum -> warning not failure; encoded fixtures validate against the schema.

#### CORE-23 · Migration framework and schema fixtures

- **Milestone:** M2 · **Area:** Core (pure Dart)
- **Depends on:** CORE-22
- **Owns:**
  - `packages/danaview_editor_core/lib/src/codec/migrations/`
  - `packages/danaview_editor_core/test/fixtures/projects/s0/`
  - `packages/danaview_editor_core/test/fixtures/projects/s1/`
  - `packages/danaview_editor_core/test/codec_migrations/`
- **Spec:** ARCH §8.5: Migrations.chain of pure, idempotent functions on raw JSON maps (s<N> -> s<N+1>) run in the decode isolate; a test-only s0 -> s1 migration exercises the framework; header-only classification (needsNewerApp when minReader > supported, readOnlyNewer when schema > supported but minReader <= supported, per D-12); LoadedProject.migratedFrom recorded; the pre-migration backup is written by the repository (CORE-25) on first save, this ticket provides `needsPreMigrationBackup`. Fixtures: every schema keeps test/fixtures/projects/s<N>/ files that must migrate, validate, re-encode and round-trip.
- **Acceptance criteria and tests:** s0 fixtures migrate to valid s1 projects; migrations idempotent; newer-schema detection from the header alone (body never parsed); opening never writes.

#### CORE-24 · Store filesystem, atomic writes, .dnproj format, OwnedFileDeleter

- **Milestone:** M2 · **Area:** Core (pure Dart)
- **Depends on:** CORE-22
- **Owns:**
  - `packages/danaview_editor_core/lib/src/store/store_roots.dart`
  - `packages/danaview_editor_core/lib/src/store/store_fs.dart`
  - `packages/danaview_editor_core/lib/src/store/atomic_file.dart`
  - `packages/danaview_editor_core/lib/src/store/dnproj_format.dart`
  - `packages/danaview_editor_core/lib/src/store/owned_file_deleter.dart`
  - `packages/danaview_editor_core/lib/src/store/documents_export_writer.dart`
  - `packages/danaview_editor_core/test/store/fs/`
- **Spec:** ARCH §8.1-8.3 and §9.6. StoreRoots {support, cache, documents} with editor subpaths (<support>/danaview/editor/..., <support>/danaview/speech/..., <cache>/danaview/editor/...); StoreFs abstraction with LocalStoreFs (dart:io) and FaultInjectingFs (crash after step N, ENOSPC, EACCES); AtomicFile.write: write path.tmp-<rand>, flush (fsync), rename path -> path.bak, rename tmp -> path; read order: valid path, else newest valid of tmp-*/.bak, else corrupt; dnproj_format: two-line header+body with SHA-256 over the body and bodyBytes check; OwnedFileDeleter: the only Dart delete path — canonicalizes, resolves symlinks, requires the target inside editorSupport or editorCache and outside documents, refuses external assets, throws OwnershipViolation (logged, asserted in debug, never performed); also `canConsume(tempPath)` for moving app-owned temp files (allowed only under `<cache>/danaview/editor/work/{picks,drops}/` and the engine's own outputs). DocumentsExportWriter (D-44): the only writer into Documents — target directory Documents/Exports/ only, exclusive create (O_EXCL semantics; never overwrite), `'<name> (2).mp4'` naming re-implementing danaview_data's LibraryStorage._uniqueTarget scheme, refuses symlinked targets or parents, copies from an editor-root source.
- **Acceptance criteria and tests:** FaultInjectingFs crash at every step always leaves a valid main, tmp or bak document; checksums detect truncation and bit flips; deleter fuzz (symlinks, '..', case variants, Unicode NFC/NFD, documents paths, external assets) never deletes outside roots; DocumentsExportWriter with a pre-existing file of the same name leaves it byte-identical (hash, size, mtime) and writes '<name> (2).mp4'; symlinked Exports dir refused; V-D1: document whether RandomAccessFile.flush() fsyncs on iOS/Android (Dart SDK source reference) — device confirmation in QA-10.

#### CORE-25 · ProjectRepository and writer isolate

- **Milestone:** M2 · **Area:** Core (pure Dart)
- **Depends on:** CORE-27, CORE-23
- **Owns:**
  - `packages/danaview_editor_core/lib/src/store/project_repository.dart`
  - `packages/danaview_editor_core/lib/src/store/file_project_repository.dart`
  - `packages/danaview_editor_core/lib/src/store/project_summary.dart`
  - `packages/danaview_editor_core/lib/src/store/storage_report.dart`
  - `packages/danaview_editor_core/lib/src/store/writer_isolate.dart`
  - `packages/danaview_editor_core/test/store/repository/`
  - `packages/danaview_editor_core/lib/testing.dart`
- **Spec:** ARCH §8.4 interface exactly (watchSummaries, create(empty | fromMedia), open, save(EditSession, reason), requestAutosave (delegates to CORE-26 scheduler; placeholder no-op until it lands), flush, close, rename (1-80 chars), duplicate ('<name> copy', '<name> copy 2'; shares managed media), delete (atomic move to trash/ then guarded delete, then GC hook), recoverable/restore/discard (delegating to CORE-26), findUntouchedProjectFor(pathOrUri) (origin.fromPlayer fingerprint match && editCount == 0), storageReport()). FileProjectRepository: bundle layout ARCH §8.1, open = read -> migrate -> decode -> validate -> repair in Isolate.run (ProjectBusy when already open), pre-migration backup on first save, meta.json/refs.json/poster.jpg, Projects list scans projects/*/meta.json and rebuilds bad ones in an isolate; create(fromMedia) imports via MediaPoolService and derives settings (aspect snapped within 1%, fps snapped to supported integer <= 60, base short side 720/1080/2160 by source and capability, view.playhead = quantize(initialPlayhead)). Long-lived writer isolate hashes and writes; one serial queue per project, latest wins. lib/testing.dart exports InMemoryProjectRepository (uses FaultInjectingFs in memory) for UI tests.
- **Acceptance criteria and tests:** every method tested on FaultInjectingFs; meta.json and refs.json written under a fake container root contain no container prefix and reopen under a different `<uuid>` root with zero missing media; duplicate shares managed media; delete never touches documents or external assets; fromMedia settings derivation table test; ProjectHealth (ok|needsNewerApp|readOnlyNewer|corrupt) surfaced; open of 2,000 items <= 150 ms core time (benchmark).

#### CORE-26 · Autosave scheduler, journal and crash recovery

- **Milestone:** M2 · **Area:** Core (pure Dart)
- **Depends on:** CORE-25
- **Owns:**
  - `packages/danaview_editor_core/lib/src/store/autosave_scheduler.dart`
  - `packages/danaview_editor_core/lib/src/store/journal.dart`
  - `packages/danaview_editor_core/lib/src/store/recovery.dart`
  - `packages/danaview_editor_core/test/store/recovery/`
- **Spec:** ARCH §8.3: autosave to the next journal slot (a/b) debounced 2 s idle and forced at 10 s, skipped while a transaction is open; manual save, app hidden/paused and editor close write main + meta + refs (+ poster) and truncate the journal; recovery = newest valid journal slot with docRevision > main.docRevision and baseSaveId == main.saveId; restore promotes atomically, discard deletes, 'Open last saved' keeps the journal as recovered-<ts> until the next successful save; LoadedProject.pendingRecovery; save failures -> SaveStatus.failed(StoreFailure) with retry on the next trigger; incremental encoding on the main isolate (<= 3 ms) and hashing/writing in the writer isolate.
- **Acceptance criteria and tests:** fake-clock tests for debounce/cap/transaction pause; slot alternation; crash at every write step (FaultInjectingFs) leaves a recoverable state; recovery listing only for newer journals with matching baseSaveId; disk full -> failed then retry succeeds; main-isolate block per autosave <= 2 ms at 1,000 items (benchmark).

#### CORE-27 · Media pool service, import policy, managed store, DartIoMediaAccess

- **Milestone:** M2 · **Area:** Core (pure Dart)
- **Depends on:** CORE-24, CORE-19
- **Owns:**
  - `packages/danaview_editor_core/lib/src/store/media_pool_service.dart`
  - `packages/danaview_editor_core/lib/src/store/import_policy.dart`
  - `packages/danaview_editor_core/lib/src/store/managed_store.dart`
  - `packages/danaview_editor_core/lib/src/store/dart_io_media_access.dart`
  - `packages/danaview_editor_core/test/store/media/`
- **Spec:** ARCH §9.1-9.2 and D-13. FileMediaPoolService(access: MediaAccessPort, probe: Future<MediaProbe> Function(ResolvedMedia), roots, fs) implementing import(session, picked, {target}) -> List<ImportOutcome> (probe, fingerprint via access.quickHash, dedupe within a project by quickHash, locator/ownership decided by ImportPolicy per source and platform: iOS Photos pick (already cloned natively into work/picks/, ARCH §9.1) -> managed copy, iOS Files -> bookmark, Android Photo Picker/SAF -> persisted grant or managed copy when not persistable or < 32 grants remain, external drop -> managed copy, player Documents path -> AppRelativeLocator(documents), Android incoming cache copy -> managed copy, LUT -> projectOwned copy + .vlut via CORE-21, recordings/stills -> projectOwned), applied as sticky PoolChanges; ManagedStore: content-addressed media/<hh>/<quickHash>/<sanitized name>, copy (APFS clone where available, V-D8) or move only when OwnedFileDeleter.canConsume allows, excludeFromBackup on media/ and derived/; watchAvailability/checkRelink/relink/findInSameFolder are declared here and implemented by CORE-28 (delegate). DartIoMediaAccess: MediaAccessPort for plain paths (tests, desktop later).
- **Acceptance criteria and tests:** the ARCH §9.1 table is covered by tests against a fake port; re-picking the same file reuses its MediaId; temp copies are moved only when allowed; grant-budget fallback works; originals are never written (fs spy asserts no write/rename/delete outside editor roots).

#### CORE-28 · Availability, relink, garbage collection, backup rules

- **Milestone:** M2 · **Area:** Core (pure Dart)
- **Depends on:** CORE-25, CORE-27
- **Owns:**
  - `packages/danaview_editor_core/lib/src/store/availability.dart`
  - `packages/danaview_editor_core/lib/src/store/relink.dart`
  - `packages/danaview_editor_core/lib/src/store/gc.dart`
  - `packages/danaview_editor_core/test/store/gc/`
  - `android/app/src/main/res/xml/danaview_data_extraction_rules.xml`
  - `android/app/src/main/res/xml/danaview_backup_rules.xml`
  - `android/app/src/main/AndroidManifest.xml`
- **Spec:** ARCH §9.3-9.4, §8.1 backup, D-20. Availability states available | missing | accessLost | changed | derivedMissing, computed on open, resume and after relink (watchAvailability); checkRelink -> match (fingerprint equal, or duration ±100 ms with equal kind and dimensions) | durationMismatch | differentKind | unsupported(reason); relink(session, picks) as ONE undoable PoolEdit ('Relink media'); autoMatch(session, picks) for 'Relink several' (each pick -> best missing asset: fingerprint match first, then duration ±100 ms with equal kind and dimensions; ambiguous picks left unassigned); findInSameFolder for path locators only. GC: mark = union of refs.json of all projects + retainedMedia() of open sessions + in-flight imports/jobs; sweep unreferenced files under media/ and derived/ older than 24 h via OwnedFileDeleter and release unreferenced URI grants/bookmarks; runs 30 s after start, after project delete and from Settings > Storage; never during an export (gate callback). Android backup rules: res/xml/danaview_data_extraction_rules.xml (API 31+, cloud backup and device transfer) and danaview_backup_rules.xml (<= 30) excluding the whole files/danaview/editor and files/danaview/speech trees (ARCH §8.1: Android rules take no wildcards and recordings would exceed the 25 MB quota, failing the whole app backup); the existing player data stays included; AndroidManifest gets only android:dataExtractionRules and android:fullBackupContent attributes ([INTEGRATION] touch of the app manifest, no other edits).
- **Acceptance criteria and tests:** every availability state and relink outcome tested with a fake port; relink is one undo step; autoMatch relinks 10 missing Photos assets from one 10-item pick and leaves ambiguous ones unassigned; GC fuzz never deletes referenced or external files and respects the grace period and export gate; V-A7: `adb shell bmgr` procedure documented in test/store/gc/README.md and run in QA-10; V-D4 checked with IOS-15.

#### CORE-30 · RenderPlan compiler: visual lowering, assets, z-order

- **Milestone:** M2 · **Area:** Core (pure Dart)
- **Depends on:** CORE-29, CORE-07, CORE-08, CORE-36
- **Owns:**
  - `packages/danaview_editor_core/lib/src/plan/compiler.dart`
  - `packages/danaview_editor_core/lib/src/plan/asset_resolver.dart`
  - `packages/danaview_editor_core/lib/src/plan/lowering_visual.dart`
  - `packages/danaview_editor_core/lib/src/plan/z_order.dart`
  - `packages/danaview_editor_core/test/plan/compile_visual/`
- **Spec:** compileRenderPlan(project, target preview|export, resolver, {options}) (pure; callers use Isolate.run above 300 items). asset_resolver: MediaId -> ResolvedMedia/proxy/offline status interface supplied by the caller (INT-02 implements it). lowering_visual covers ARCH §11.7 rows except transitions/text/audio: track hidden/mute/solo, fit + crop -> base via geometry.baseSize, transform/effects/look/chroma/mask, item keyframes -> absolute `anim` channels, speed ramps -> multi-segment `map` (lower(250 µs)), reversed clips -> rendition asset with increasing map, BlurOfMain -> '#bd' backdrop layers, missing media -> dark-grey solid + req.offline, pending reverse -> forward media + req.pendingReverse, pending still -> hold layer (or solid when !capabilities.holdFrame) + req.pendingStill; preview plans carry proxyUri when ready; export plans never do. z_order: z = band·10000 + (laneIndexInBand + 1)·10 + sub (ARCH §11.4); stable layer ids '<itemId>#v', '#bd'; `seq` per media layer from CORE-36's packing; canvas.gridFps = project fps (export plans may have another canvas.fps); every edge and map breakpoint on the grid (§11.3). Plans are exact (no ε bias, D-04). Preview plans contain no text/subtitle layers (D-05).
- **Acceptance criteria and tests:** one compile golden per lowering row (fixtures in test/plan/compile_visual/goldens); compiled plans pass the CORE-29 validator (grid edges, seq slots); packing inputs derived from the model equal the compiled layers' ranges on every golden; shared-code test proves the compiler uses geometry.boxAt's matrix; hidden/muted/solo honoured; full compile of 2,000 items <= 60 ms in an isolate (benchmark).

#### CORE-31 · Lowering: transitions, text and subtitle sprites, audio

- **Milestone:** M2 · **Area:** Core (pure Dart)
- **Depends on:** CORE-30, CORE-16
- **Owns:**
  - `packages/danaview_editor_core/lib/src/plan/lowering_transitions.dart`
  - `packages/danaview_editor_core/lib/src/plan/lowering_text.dart`
  - `packages/danaview_editor_core/lib/src/plan/lowering_audio.dart`
  - `packages/danaview_editor_core/lib/src/plan/sprite_requests.dart`
  - `packages/danaview_editor_core/test/plan/compile_lowering/`
- **Spec:** ARCH §11.7 rows: Fade, Cross dissolve, Dip to black/white ('#tx' solids at z+5), Slide (ease-in-out cubic, 8 segments), Wipe (canvas mask sweep, 2% feather), Zoom in/out, all using handles at the edge speed with right-on-top ordering; transition helper channels merged with user keyframes on a merged breakpoint set (opacity multiplies, translate/scale compose). Text items and burned subtitle cues (export target only, D-05) -> sprite layers referencing SpriteManifest entries (base from sprite size, xf from transform, cue anchoring by SubtitlePosition using sprite height, anim from evaluateTextAnimation breakpoints, typewriter -> `reveal` 0..n). sprite_requests.collectSpriteRequests(project, canvas, exportScale, {maxTextureSize}) -> content-keyed SpriteRequests (sha1 of TextLayoutSpec JSON, scale, canvas, fontsVersion) where each item's raster scale = exportScale × its maximum animated scale (static, keyframed up to 8×, text-animation scale), reduced so no side exceeds min(maxTextureSize, 2 × output long side) (ARCH §10.3). Audio: AudioSeg per clip from the same ClipTimeMap as the video layer, gain envelope = volume keys × fades × mute/solo × transition audio dips (equal-power crossfade sampled linearly), extra samples every 20 ms where products are non-linear (<= 0.1 dB error), pitch flag from maintainPitch; audio muted above capabilities.maxAudioSpeed (D-15).
- **Acceptance criteria and tests:** compile golden per transition kind and direction, per text animation, burn-in on/off; sprite raster scale for an 8× scale keyframe and its clamp at maxTextureSize 4096; gain envelope with volume 200% (2.0); envelope error <= 0.1 dB vs analytic; video layer and audio segment boundaries identical for every clip (A/V property test); export compile without manifest entries returns ExportBlocked.

#### CORE-32 · Plan diff, patches, memoization and transients

- **Milestone:** M2 · **Area:** Core (pure Dart)
- **Depends on:** CORE-31
- **Owns:**
  - `packages/danaview_editor_core/lib/src/plan/plan_diff.dart`
  - `packages/danaview_editor_core/lib/src/plan/plan_memo.dart`
  - `packages/danaview_editor_core/lib/src/plan/transients.dart`
  - `packages/danaview_editor_core/test/plan/diff/`
- **Spec:** ARCH §11.8: diffPlans(a, b) -> RenderPlanPatch (identity-first; upsert/remove by id for assets, layers, audio; canvas/durUs), applyPatch(plan, patch) (pure, used by tests and the fake engine), PlanMemo keyed by item identity + context signature (track flags, neighbours, transitions, settings, asset identity) so a one-item edit recompiles only that item and its transition neighbours; transientFor(workingProject, itemId) -> PlanTransient with param fields only (xf, crop, base, fx, anim, cmasks) for that item's layers; classifyPatch(patch) -> structural | paramOnly exactly as ARCH §11.2 'Patch classification' (vectors exported to test/fixtures/render_plans/classification.json for native tests).
- **Acceptance criteria and tests:** apply(diff(a, b), a) == b property test on random edit sequences; one-item edit at 2,000 items compiles + diffs <= 3 ms; transients contain only the item's layers and no timing fields; classification vectors committed and matched.

#### CORE-33 · Export settings, presets, bitrate table, compileExport

- **Milestone:** M2 · **Area:** Core (pure Dart)
- **Depends on:** CORE-31
- **Owns:**
  - `packages/danaview_editor_core/lib/src/plan/export_settings.dart`
  - `packages/danaview_editor_core/lib/src/plan/export_presets.dart`
  - `packages/danaview_editor_core/lib/src/plan/bitrate.dart`
  - `packages/danaview_editor_core/lib/src/plan/compile_export.dart`
  - `packages/danaview_editor_core/test/plan/export/`
- **Spec:** ARCH §14.1 presets table exactly (YouTube, YouTube 4K, YouTube Shorts, Instagram Reels, Instagram Feed, TikTok, Custom) and auto bitrate table {720: 5/7.5, 1080: 8/12, 1440: 16/24, 2160: 40/60} Mbps (<= 30 / > 30 fps) × 0.6 for HEVC × quality (Smaller 0.6, Balanced 1.0, High 1.5, Maximum 2.0); ExportSettings (user level: preset, resolution, fps Match project (default) or 24/25/30/48/50/60 clamped by maxFpsByHeight, container mp4|mov, codec h264|hevc, quality, custom bitrates 2-100 Mbps video / 96-320 kbps audio, burnInSubtitles per track, sideFiles srt/vtt) -> EncodeSettings with capability clamps (hevc/mov availability, maxExportSize, maxFpsByHeight); size estimate (video+audio bps)·sec/8·1.02; aspect-mismatch detection (notice 'Change project to 9:16', never silent crop; letterbox fit); compileExport(project, settings, spriteManifest) -> RenderPlan | ExportBlocked(requirements) using originals only, output canvas = output size, canvas.fps = export fps, canvas.gridFps = project fps.
- **Acceptance criteria and tests:** preset table tests; Custom fps list incl. 48 and Match project (a 48 fps project exports at 48 by default; clamped where maxFpsByHeight forbids); clamps for each capability flag; estimate within 1% of the formula; aspect mismatch detection; ExportBlocked for offline/pending/missing sprites; V-D9 reviewed (sources noted in a code comment, non-binding).

#### API-02 · PlanSync and plan transport

- **Milestone:** M2 · **Area:** Engine (Dart)
- **Depends on:** API-01, CORE-32
- **Owns:**
  - `packages/danaview_editor_engine_api/lib/src/plan_sync.dart`
  - `packages/danaview_editor_engine_api/lib/src/plan_transport.dart`
  - `packages/danaview_editor_engine_api/test/plan_sync/`
- **Spec:** plan_transport.dart: encode RenderPlan/RenderPlanPatch/PlanTransient to UTF-8 JSON bytes (Isolate.run above a size threshold) and decode acks. plan_sync.dart: PlanSync(PreviewSession session, {required Future<RenderPlan> Function(EditProject) compile}) with schedule(project) — at most one compile in flight, latest wins, compile -> diffPlans against the last acknowledged plan -> applyPatch; on EngineFailure(planOutOfSync) sends setPlan(full) once, a second failure -> PreviewFailed event; dropTransientsFor(item) when a commit lands; sendTransient(item, PlanTransient) coalesced to <= 60 Hz and dropped when the item's last committed change was structural; exposes Stream<PlanSyncStatus> (idle, compiling, applying, failed) and lastAck (rev, structural, applyMs) for the UI and QA timing.
- **Acceptance criteria and tests:** tests with FakeEditorEngine: coalescing (100 schedules -> <= 2 compiles), out-of-sync retry path, double failure surfaces PreviewFailed, transient rate limiting, revision ordering never regresses after undo (session stamps).

#### API-04 · Render prep: text layout engine, sprite rasterizer, .vsprite codec, sprite pre-pass

- **Milestone:** M2 · **Area:** Engine (Dart)
- **Depends on:** API-01, CORE-07, CORE-31
- **Owns:**
  - `packages/danaview_editor_engine_api/lib/src/render_prep/`
  - `packages/danaview_editor_engine_api/test/render_prep/`
  - `packages/danaview_editor_engine_api/test_fixtures/sprites/`
- **Spec:** ARCH §10.3, D-05, D-06. TextLayoutEngine: lays out TextLayoutSpec/cue specs with ui.Paragraph (font resolved through an injected FontResolver(fontId) -> family, unknown -> Figtree), returns glyph boxes and line metrics; the same engine drives the preview overlay (UX-19), manipulation handles and export sprites. TextSpriteRasterizer: renders text with background box, stroke, shadow to premultiplied RGBA at the per-item raster scale from CORE-31 (max animated scale, clamped to maxTextureSize and 2× the output long side) plus the u16 glyph-order map for typewriter (grapheme clusters). VspriteCodec: 'VSPR' v1 encode/decode (zlib in Isolate.run). SpritePrepass: run(List<SpriteRequest>, cacheDir) rasterizes missing sprites in <= 4 ms UI-thread slices, writes <cache>/danaview/editor/sprites/<key>.vsprite, reports progress, returns SpriteManifest; content-addressed reuse.
- **Acceptance criteria and tests:** glyph boxes equal ui.Paragraph boxes; RTL, CJK and emoji fixtures render with system fallback (V-A11: document Figtree coverage and fallback); reveal map correct for grapheme clusters; codec round-trip; per-slice UI time <= 4 ms; V-D7: 1,000 cues prepared <= 8 s on a mid device (measured in QA-04; host benchmark here).

#### ENG-03 · Dart glue: jobs, recorder, platform services, media access

- **Milestone:** M2 · **Area:** Engine (Dart)
- **Depends on:** ENG-06
- **Owns:**
  - `packages/danaview_editor_engine/lib/src/mobile_jobs.dart`
  - `packages/danaview_editor_engine/lib/src/mobile_recorder.dart`
  - `packages/danaview_editor_engine/lib/src/mobile_platform_services.dart`
  - `packages/danaview_editor_engine/lib/src/mobile_media_access.dart`
  - `packages/danaview_editor_engine/test/services/`
- **Spec:** Dart implementations behind MobileEditorEngine: ThumbnailSource (requestId, priority, cancel, <= 8 tiles in flight), WaveformSource and MediaJobs (startJob/cancel/setPriority, progress from events, typed results incl. extractSpeechAudio), VoiceRecorder/RecordingSession (levels, interruptions), MediaPicker, FileHandoff, MediaAccess (core MediaAccessPort: resolve, stat, quickHash, persist, release, excludeFromBackup — refused with OwnershipViolation for paths outside the editor roots, D-44 —, remainingGrantBudget; requestNotificationPermission), BackgroundWorkGuard leases (acquire/update/release, progress forwarding), ExternalDropTarget (drops stream with logical positions), freeBytes, trimCaches, signals (memoryWarning, thermal). All failures through error_mapper.
- **Acceptance criteria and tests:** mocked-channel tests for each service incl. cancel races, job result typing, lease lifecycle, excludeFromBackup refusing a Documents path; FakeEditorEngine contract kit passes against MobileEditorEngine with mocked channels where applicable.

#### IOS-02 · iOS probe, compatibility, device profile, capabilities

- **Milestone:** M2 · **Area:** iOS native
- **Depends on:** ENG-06, ENG-05
- **Owns:**
  - `packages/danaview_editor_engine/ios/Classes/Media/Probe.swift`
  - `packages/danaview_editor_engine/ios/Classes/Media/Compatibility.swift`
  - `packages/danaview_editor_engine/ios/Classes/Core/DeviceProfile.swift`
  - `packages/danaview_editor_engine/ios/Classes/Core/Capabilities.swift`
  - `packages/danaview_editor_engine/example/ios/RunnerTests/Probe/`
- **Spec:** ARCH §15 row 'Probe / compatibility' and §12.5. Probe via AVURLAsset async loads (duration, tracks, isPlayable, isComposable, hasProtectedContent), format descriptions (codec, bit depth, transfer -> ColorTransfer, nominal fps + VFR detection), preferredTransform -> rotation and display size, audio streams/channels/sample rate, size; compatibility(uri) <= 300 ms: Dart-side container sniff happens first (UX), natively MKV/WebM/AVI -> NotEditable('container_unsupported_ios'), protected/non-composable -> NotEditable with codes. DeviceProfile: RAM, chip family, tier table (minimal < 3 GB: A9–A11 iPhone 6s/7/8/SE 1st gen, D-40; low 3 GB: iPhone X/SE 2; mid 4-6 GB; high >= 8 GB or A15+ with 6 GB), thermal state, low-power mode. Capabilities: H.264/HEVC hardware probe — under `#available(iOS 17.4, *)` with kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder / kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder at target sizes; below 17.4 device encoders count as hardware and HEVC is detected with AVOutputSettingsAssistant(preset: .hevc1920x1080) != nil plus a VTCompressionSession create and one-frame test encode at the target size (simulator: software H.264 only) —, movContainer true, maxExportSize/maxFpsByHeight by tier (minimal: 1080p H.264), maxConcurrentVideoLayers 2/3/4/6, maxVisualSequences 16, maxTextureSize 16384, maxPreviewLongSide 640/960/1280/1920, proxiesRecommended forced on minimal, lowMemoryDevice on minimal, backgroundKind honestly per device (`continued` only on iPad iOS 26+ when `BGTaskScheduler.shared.supportedResources.contains(.gpu)` and the entitlement is present; `paused` on every iPhone, D-22), backgroundGpu, voiceRecording, holdFrame, fpsUpconversion, externalDrop, speeds 0.1/10/4, maxLutSize 65, planVersions [1]; supported requires a Metal device.
- **Acceptance criteria and tests:** probe fields correct on every ENG-05 fixture (rotation, HDR, VFR, 5.1, MKV and WebM refusal); compatibility <= 300 ms on the simulator; capability values per tier table unit-tested with injected profiles incl. minimal and an iPhone on iOS 26 (paused) vs an iPad with GPU (continued); the pre-17.4 HEVC path runs on the iPhone 8 (iOS 16.7) lab device; the target compiles without availability warnings at 15.0.

#### IOS-17 · iOS segmented writer, checkpoint, passthrough concat and job interruption

- **Milestone:** M2 · **Area:** iOS native
- **Depends on:** ENG-06, ENG-05
- **Owns:**
  - `packages/danaview_editor_engine/ios/Classes/Media/SegmentedWriter.swift`
  - `packages/danaview_editor_engine/ios/Classes/Media/SegmentConcat.swift`
  - `packages/danaview_editor_engine/ios/Classes/Media/SegmentCheckpoint.swift`
  - `packages/danaview_editor_engine/ios/Classes/Core/JobInterruption.swift`
  - `packages/danaview_editor_engine/example/ios/RunnerTests/Segments/`
- **Spec:** D-22 and ARCH §14.2 (review issue 4): AVAssetWriter loses its encoder in the background and cannot resume, so every long reader/writer job is segment-resumable. SegmentedWriter: closed-GOP video segments of N seconds of output (default 10 s; each its own AVAssetWriter file starting with an IDR, identical encoder settings), an optional whole-duration audio file, atomic SegmentCheckpoint after each finished segment (job kind, input hash, encode settings, completed segments with durations), resume from the next segment start (callers re-create their reader with `timeRange`). SegmentConcat: passthrough (AVAssetReader with nil output settings per segment → one AVAssetWriter input with the first segment's format description as sourceFormatHint; SPS/PPS equality asserted, otherwise the mismatching segment is re-encoded), audio muxed passthrough, each segment deleted after it is appended (peak disk ≈ output + one segment). JobInterruption: observes didEnterBackground/willEnterForeground; on background it stops registered jobs immediately (in-progress segment discarded), keeps checkpoints and reports interruption; on foreground it re-queues them; on a cold start it exposes resumable checkpoints (used by IOS-13's `activeJobs()` → resumable).
- **Acceptance criteria and tests:** a segmented H.264 export of frame_counter interrupted at random points (simulated by failing the writer with AVFoundationErrorDomain −11847) resumes and concatenates to a file whose barcodes, frame count and PTS equal an uninterrupted export; concat output passes the §14.4 container checks; peak disk measured; checkpoint survives process kill; SPS/PPS mismatch path tested.

#### IOS-03 · iOS thumbnails and disk cache

- **Milestone:** M2 · **Area:** iOS native
- **Depends on:** IOS-02
- **Owns:**
  - `packages/danaview_editor_engine/ios/Classes/Media/ThumbnailService.swift`
  - `packages/danaview_editor_engine/ios/Classes/Media/DiskCache.swift`
  - `packages/danaview_editor_engine/example/ios/RunnerTests/Thumbnails/`
- **Spec:** ThumbnailService: JPEG strips of framesPerTile (8) frames at heightPx for (media|proxy, intervalMs, tileIndex) via AVAssetImageGenerator (appliesPreferredTrackTransform, tolerance per interval, dynamicRangePolicy .forceSDR on iOS 18+), ImageIO JPEG q 0.7; priorities (visible > prefetch), cancellation by requestId, <= 8 concurrent. DiskCache: generic LRU-by-access-time cache under <cache>/danaview/editor/{thumbs,waves,...} keyed by quickHash + params, size caps (thumbs 300 MB, waves 64 MB, sprites 400 MB), pinning of files used by an open session, trim(level) and clear (refused while a session/job is active), wipe of work/ at launch except files of active or resumable jobs and outputs of unconsumed completedWhileDetached records (7-day expiry), with work/picks and work/drops older than 24 h removed (ARCH §15).
- **Acceptance criteria and tests:** tile shape and frame times correct on frame_counter (barcodes); cache hit <= 20 ms; cancel stops work; LRU cap enforced; miss <= 400 ms on the low-tier device (recorded in QA-04).

#### IOS-04 · iOS PCM reader, waveforms, speech audio extraction

- **Milestone:** M2 · **Area:** iOS native
- **Depends on:** IOS-02
- **Owns:**
  - `packages/danaview_editor_engine/ios/Classes/Media/PcmReader.swift`
  - `packages/danaview_editor_engine/ios/Classes/Media/WaveformService.swift`
  - `packages/danaview_editor_engine/ios/Classes/Media/SpeechAudioExtractor.swift`
  - `packages/danaview_editor_engine/example/ios/RunnerTests/Audio/`
- **Spec:** PcmReader: AVAssetReader LPCM Float32 with a sample-accurate timeRange (edit lists and AAC priming honoured). WaveformService: `.dvpk` int8 min/max at 200 pairs/s per audio stream, cached in DiskCache waves/. SpeechAudioExtractor (ai.md §7.2, D-28 port implemented natively): 16 kHz s16 mono WAV for a source range, fixed downmix (mono copy; stereo 0.5/0.5; 5.1 -> 0.5·C + 0.25·(L+R) + 0.125·(Ls+Rs), LFE dropped) + AVAudioConverter (.high), written to the Dart-supplied path; cancel deletes partial output; unsupported codecs -> unsupportedMedia.
- **Acceptance criteria and tests:** peaks match reference peaks; waveform >= 20× realtime on the low tier; WAV header valid, exactly 16 kHz mono s16, duration = range ± 1 ms; clap_flash fixture click within ±20 ms (V-A6); 5.1 centre kept; throughput >= 60× realtime mid.

#### IOS-05 · iOS job registry, proxy job and proxy registry

- **Milestone:** M2 · **Area:** iOS native
- **Depends on:** IOS-02, IOS-17
- **Owns:**
  - `packages/danaview_editor_engine/ios/Classes/Core/JobRegistry.swift`
  - `packages/danaview_editor_engine/ios/Classes/Media/ProxyJob.swift`
  - `packages/danaview_editor_engine/ios/Classes/Media/ProxyRegistry.swift`
  - `packages/danaview_editor_engine/example/ios/RunnerTests/Proxy/`
- **Spec:** JobRegistry: job ids, priorities (interactive > export-blocking > background), concurrency (1 on minimal/low tier, 2 otherwise), pre-emption by export and interactive jobs, progress events <= 4 Hz, cancellation cleaning `.part` outputs, waveform/proxy/reverse/freeze/speechAudio kinds, and IOS-17's JobInterruption semantics (backgrounding stops every reader/writer job, keeps completed segments/chunks and re-queues it on foreground, D-22). ProxyJob: 540p short side H.264 3 Mbps, GOP 10 frames, SDR (HDR tone-mapped), AAC 128k, identical PTS to the source (VFR preserved), reader -> IOS-17 SegmentedWriter -> concat into `.part` + rename into <cache>/danaview/editor/proxies/<quickHash>-540.mp4. ProxyRegistry: status by fingerprint, LRU cap min(4 GB, 10% free).
- **Acceptance criteria and tests:** proxy PTS equal to source PTS on the VFR fixture (also across a resumed segment boundary); size/GOP verified with AVAsset inspection; pre-emption and cancel tests; HDR source -> SDR proxy; a simulated background interruption mid-proxy resumes from the last segment.

#### IOS-06 · iOS freeze frame and source-frame cache

- **Milestone:** M2 · **Area:** iOS native
- **Depends on:** IOS-05
- **Owns:**
  - `packages/danaview_editor_engine/ios/Classes/Media/FreezeFrameJob.swift`
  - `packages/danaview_editor_engine/ios/Classes/Preview/SourceFrameCache.swift`
  - `packages/danaview_editor_engine/example/ios/RunnerTests/Freeze/`
- **Spec:** FreezeFrameJob: PNG of the exact source frame at sourceTime (AVAssetImageGenerator, zero tolerance, preferred transform, SDR) written to the Dart path (projects/<id>/assets/stills/). SourceFrameCache: small LRU of decoded source frames used by showSourceFrame (trim-edge preview), sampleColor (pre-key source, 3×3 average at a normalized source point) and look stills.
- **Acceptance criteria and tests:** barcode of the still equals the requested frame on frame_counter; PNG at the output path; sampled colour within ±2/255 of the reference; cache bounded by tier memory budget.

#### IOS-07 · iOS reverse rendition job

- **Milestone:** M2 · **Area:** iOS native
- **Depends on:** IOS-05
- **Owns:**
  - `packages/danaview_editor_engine/ios/Classes/Media/ReverseJob.swift`
  - `packages/danaview_editor_engine/example/ios/RunnerTests/Reverse/`
- **Spec:** ARCH §15 'Reverse' (review issue 14): process the range in GOP-aligned chunks (≈ 2 s of source) **from the end**: each chunk is transcoded to an all-intra H.264 intermediate in <cache>/danaview/editor/work/ and read back with AVAssetReaderTrackOutput (supportsRandomAccess = true, reset(forReadingTimeRanges:), 420v output) in reverse frame order — no second copy of the intermediate, and the intermediate never exceeds one chunk — then encoded with mirrored PTS into the Dart-supplied derived/<specHash>.mp4; audio reversed in 64k-frame blocks -> AAC; preflight refuses ranges > 10 min (LimitExceeded('reverseRange')) and checks freeBytes >= 2 × estimated output + one chunk + 64 MB (diskFull); resumes from the last complete chunk after a background interruption (IOS-17 JobInterruption); progress and cancel via JobRegistry.
- **Acceptance criteria and tests:** barcode strictly decreasing; duration = range ± 1 frame; click positions mirrored ±20 ms; peak work-dir size <= one chunk intermediate + output; peak memory delta <= 90 MB at 4K and <= 40 MB at 1080p (3 decoded 420v frames + codec working sets); preflight refusals tested; cancel removes work files; interruption resume keeps the barcode sequence continuous.

#### IOS-18 · iOS audio gain tap (sample-exact envelopes up to +6 dB) and ramp-seam crossfade

- **Milestone:** M2 · **Area:** iOS native
- **Depends on:** ENG-06, API-03
- **Owns:**
  - `packages/danaview_editor_engine/ios/Classes/Audio/GainTap.swift`
  - `packages/danaview_editor_engine/ios/Classes/Audio/TapEnvelope.swift`
  - `packages/danaview_editor_engine/example/ios/RunnerTests/AudioTap/`
- **Spec:** D-37 (review issues 5, 21): MTAudioProcessingTap (`audioTapProcessor` on AVMutableAudioMixInputParameters) that multiplies every sample by the track's gain envelope (plan `gain`, linear, 0–2) evaluated at the composition time of each sample (from the tap's source time range), with an atomically swappable TapEnvelope so gain-only patches never rebuild the item; works in AVPlayerItem.audioMix and AVAssetReaderAudioMixOutput.audioMix; setVolumeRamp is not used. Ramp-seam option: when QA-11's click test (or this ticket's) shows discontinuities at speed-ramp segment seams, CompositionBuilder (IOS-08) alternates ramp segments across two audio tracks and this tap applies 5 ms equal-power crossfades at each seam (API: `TapEnvelope.withSeamCrossfades(seams)`).
- **Acceptance criteria and tests:** gain vectors from API-03 reproduced sample-exactly on rendered PCM (±0.01 dB); 200% vs 100% on tone_1khz measures +6.02 ± 0.1 dB in both AVPlayer (offline render via AVAudioEngine manual rendering of the player item or reader output) and AVAssetReaderAudioMixOutput (V-N21); envelope swap is glitch-free (no sample discontinuity > −60 dBFS); fades and volume keyframes match the Dart reference mixer within ±0.5 dB per 20 ms window; ramp-seam click test on a 7-point ramp with keep-pitch: no seam transient > −40 dBFS above the tone envelope (or the crossfade option enabled and passing).

#### AND-02 · Android probe, compatibility, device profile, capabilities

- **Milestone:** M2 · **Area:** Android native
- **Depends on:** ENG-06, ENG-05
- **Owns:**
  - `packages/danaview_editor_engine/android/src/main/kotlin/com/vecvel/danaview/editor/engine/media/Probe.kt`
  - `packages/danaview_editor_engine/android/src/main/kotlin/com/vecvel/danaview/editor/engine/media/Compatibility.kt`
  - `packages/danaview_editor_engine/android/src/main/kotlin/com/vecvel/danaview/editor/engine/core/DeviceProfile.kt`
  - `packages/danaview_editor_engine/android/src/main/kotlin/com/vecvel/danaview/editor/engine/core/Capabilities.kt`
  - `packages/danaview_editor_engine/android/src/test/kotlin/com/vecvel/danaview/editor/engine/probe/`
  - `packages/danaview_editor_engine/android/src/androidTest/kotlin/com/vecvel/danaview/editor/engine/probe/`
- **Spec:** ARCH §15 'Probe / compatibility' and §3.2: MetadataRetriever + MediaExtractorCompat probe (duration, tracks, rotation, display size, nominal fps + VFR flag, codecs/profiles, bit depth, transfer HDR, audio streams/channels/rate, size; content:// and file paths, read-only); compatibility <= 300 ms with decoder availability via MediaCodecList per mime/profile/size (MKV/WebM editable when decoders exist; HDR editable with tone mapping and automatic proxy). DeviceProfile: RAM, isLowRamDevice, SoC, codec max instances, thermal listener (PowerManager.OnThermalStatusChangedListener) -> signals. Capabilities: gate API >= 29, GLES 3.0 EGL context (V-N7) and >= 2 GB RAM, else supported=false with 'android_too_old'/'gles3_missing'/'insufficient_memory'; tiers minimal (< 3 GB or isLowRamDevice, D-40) / low / mid / high; H.264/HEVC encode and hardware flags (isHardwareAccelerated), movContainer false, maxExportSize/maxFpsByHeight by tier (minimal: 1080p H.264), maxConcurrentVideoLayers min(2/3/4/6, codec instances - 1), maxVisualSequences min(3/4/6/8 or the AND-01-measured values, codec instances - 1), maxTextureSize = GL_MAX_TEXTURE_SIZE, maxPreviewLongSide 640/960/1280/1920, proxiesRecommended forced and lowMemoryDevice on minimal, backgroundKind foregroundService, voiceRecording, holdFrame, fpsUpconversion (from AND-01), externalDrop, speeds, maxLutSize 65, planVersions [1].
- **Acceptance criteria and tests:** probe fields correct on fixtures incl. the ENG-05 MKV and WebM (instrumented); gate unit tests incl. insufficient_memory; tier table tests with injected profiles incl. minimal; GLES 3 check on API 29 emulator; maxTextureSize read on the emulator.

#### AND-03 · Android thumbnails and disk cache

- **Milestone:** M2 · **Area:** Android native
- **Depends on:** AND-02
- **Owns:**
  - `packages/danaview_editor_engine/android/src/main/kotlin/com/vecvel/danaview/editor/engine/media/ThumbnailService.kt`
  - `packages/danaview_editor_engine/android/src/main/kotlin/com/vecvel/danaview/editor/engine/media/DiskCache.kt`
  - `packages/danaview_editor_engine/android/src/test/kotlin/com/vecvel/danaview/editor/engine/thumbs/`
  - `packages/danaview_editor_engine/android/src/androidTest/kotlin/com/vecvel/danaview/editor/engine/thumbs/`
- **Spec:** Same contract as IOS-03: JPEG strips of 8 frames via FrameExtractor (media3-inspector-frame) with SeekParameters CLOSEST_SYNC and Presentation.createForHeight GPU downscale, Bitmap.compress(JPEG, 70); priorities, cancel, <= 8 concurrent on danaview-jobs. DiskCache: LRU by access time with the same caps, pinning, trim, clear refused while active, work/ wipe at launch with the same exemptions as IOS-03 (active/resumable jobs, unconsumed completedWhileDetached outputs; picks/drops > 24 h removed).
- **Acceptance criteria and tests:** tile frames correct on frame_counter (barcodes, sync-frame tolerance documented); cache hit <= 20 ms; cancel; LRU cap; miss <= 400 ms on low tier (QA-04).

#### AND-04 · Android PCM decoder, waveforms, speech audio extraction

- **Milestone:** M2 · **Area:** Android native
- **Depends on:** AND-02
- **Owns:**
  - `packages/danaview_editor_engine/android/src/main/kotlin/com/vecvel/danaview/editor/engine/media/PcmDecoder.kt`
  - `packages/danaview_editor_engine/android/src/main/kotlin/com/vecvel/danaview/editor/engine/media/WaveformService.kt`
  - `packages/danaview_editor_engine/android/src/main/kotlin/com/vecvel/danaview/editor/engine/media/SpeechAudioExtractor.kt`
  - `packages/danaview_editor_engine/android/src/test/kotlin/com/vecvel/danaview/editor/engine/audio/`
  - `packages/danaview_editor_engine/android/src/androidTest/kotlin/com/vecvel/danaview/editor/engine/audio/`
- **Spec:** PcmDecoder: MediaExtractorCompat + async MediaCodec to float PCM with sample-accurate ranges (MP4 edit lists and AAC priming). WaveformService: `.dvpk` int8 min/max at 200 pairs/s. SpeechAudioExtractor: 16 kHz s16 mono WAV via ChannelMixingAudioProcessor (same coefficients as IOS-04) + SonicAudioProcessor(16 kHz); cancel deletes partial output; unsupported codecs -> unsupportedMedia.
- **Acceptance criteria and tests:** same ACs as IOS-04 (peaks reference, format, ±1 ms duration, clap ±20 ms incl. edit list/priming V-A6, 5.1 centre kept, >= 60× realtime mid).

#### AND-05 · Android job registry, proxy job and registry

- **Milestone:** M2 · **Area:** Android native
- **Depends on:** AND-02
- **Owns:**
  - `packages/danaview_editor_engine/android/src/main/kotlin/com/vecvel/danaview/editor/engine/core/JobRegistry.kt`
  - `packages/danaview_editor_engine/android/src/main/kotlin/com/vecvel/danaview/editor/engine/media/ProxyJob.kt`
  - `packages/danaview_editor_engine/android/src/main/kotlin/com/vecvel/danaview/editor/engine/media/ProxyRegistry.kt`
  - `packages/danaview_editor_engine/android/src/test/kotlin/com/vecvel/danaview/editor/engine/proxy/`
  - `packages/danaview_editor_engine/android/src/androidTest/kotlin/com/vecvel/danaview/editor/engine/proxy/`
- **Spec:** Same contract as IOS-05: priorities, concurrency by tier, pre-emption, progress, cancel. ProxyJob: Transformer + Presentation.createForShortSide(540), H.264 3 Mbps, I-frame interval 0.33 s, SDR (HDR tone-mapped), AAC 128k, same PTS as source, `.part` + rename; paused while exporting.
- **Acceptance criteria and tests:** proxy PTS equal on VFR fixture; HDR -> SDR; paused during export (test with a fake coordinator); cancel cleans up.

#### AND-06 · Android freeze frame and source-frame cache

- **Milestone:** M2 · **Area:** Android native
- **Depends on:** AND-05
- **Owns:**
  - `packages/danaview_editor_engine/android/src/main/kotlin/com/vecvel/danaview/editor/engine/media/FreezeFrameJob.kt`
  - `packages/danaview_editor_engine/android/src/main/kotlin/com/vecvel/danaview/editor/engine/preview/SourceFrameCache.kt`
  - `packages/danaview_editor_engine/android/src/test/kotlin/com/vecvel/danaview/editor/engine/freeze/`
  - `packages/danaview_editor_engine/android/src/androidTest/kotlin/com/vecvel/danaview/editor/engine/freeze/`
- **Spec:** Same contract as IOS-06 using FrameExtractor with SeekParameters.EXACT: PNG still at the Dart path; SourceFrameCache for showSourceFrame, sampleColor (pre-key, 3×3 average) and look stills (with LayerLookEffect overrides once AND-09 lands; until then unprocessed frames).
- **Acceptance criteria and tests:** still barcode equals requested frame; sample within ±2/255; bounded memory.

#### AND-07 · Android reverse rendition job

- **Milestone:** M2 · **Area:** Android native
- **Depends on:** AND-05
- **Owns:**
  - `packages/danaview_editor_engine/android/src/main/kotlin/com/vecvel/danaview/editor/engine/media/ReverseJob.kt`
  - `packages/danaview_editor_engine/android/src/test/kotlin/com/vecvel/danaview/editor/engine/reverse/`
  - `packages/danaview_editor_engine/android/src/androidTest/kotlin/com/vecvel/danaview/editor/engine/reverse/`
- **Spec:** Same chunked algorithm and preflight as IOS-07 (GOP-aligned chunks from the end, intermediate never larger than one chunk, range cap 10 min, freeBytes check): Transformer all-intra intermediate per chunk in work/, MediaExtractorCompat + MediaCodec reverse-order feed to an encoder surface with mirrored PTS, audio via PcmDecoder -> WAV -> AAC -> Mp4Muxer; output at the Dart-supplied derived path; bounded memory; progress/cancel.
- **Acceptance criteria and tests:** barcode strictly decreasing; duration ±1 frame; clicks mirrored ±20 ms; peak work-dir size <= one chunk + output; memory bound as IOS-07; preflight refusals; cancel cleans work/.

#### AI-04 · whisper Android native build

- **Milestone:** M2 · **Area:** AI (whisper + transcription)
- **Depends on:** AI-03
- **Owns:**
  - `packages/danaview_whisper/android/build.gradle.kts`
  - `packages/danaview_whisper/android/src/main/AndroidManifest.xml`
  - `packages/danaview_whisper/src/cmake/android.cmake`
  - `packages/danaview_whisper/src/dv_exports.map`
  - `scripts/ci/editor/check_native_libs.sh`
- **Spec:** ai.md §4.3: externalNativeBuild with src/cmake/android.cmake producing libdanaview_whisper.so (arm64-v8a armv8-a baseline; x86_64) and libdanaview_whisper_v82.so (arm64-v8a armv8.2-a+fp16+dotprod) selected at runtime from getauxval(AT_HWCAP) by the Dart loader (AI-07); c++_static (media_kit ships libc++_shared; no packaging conflict); 16 KB page alignment; only dv_* exported via dv_exports.map; no armeabi-v7a; -O3, no OpenMP. check_native_libs.sh (used by editor CI and later INT-05 release workflows) inspects an AAB/APK: ABIs present, 16 KB LOAD alignment (llvm-readelf), exported symbol list, size <= 3 MB per .so.
- **Acceptance criteria and tests:** example/app AAB contains exactly the expected .so files; alignment and exports checks pass; builds with the SDK CMake 3.22.1 or the pinned version is documented (V-A8); no libc++_shared conflict with media_kit.

#### AI-05 · whisper iOS native build (static xcframework)

- **Milestone:** M2 · **Area:** AI (whisper + transcription)
- **Depends on:** AI-03, INT-01, ENG-09
- **Owns:**
  - `packages/danaview_whisper/ios/danaview_whisper.podspec`
  - `packages/danaview_whisper/ios/Classes/dv_whisper_forwarder.cpp`
  - `packages/danaview_whisper/ios/Resources/`
  - `packages/danaview_whisper/tool/build_ios_xcframework.sh`
  - `packages/danaview_whisper/.gitignore`
- **Spec:** ai.md §4.4 with the D-29 target: tool/build_ios_xcframework.sh (CMake >= 3.28; `--if-missing` flag) builds static WhisperCore.xcframework (device arm64 + simulator arm64/x86_64) with IPHONEOS_DEPLOYMENT_TARGET 15.0, Metal with an embedded library (used at runtime only on iOS >= 16.4 and Apple GPU family >= 6), Accelerate/BLAS OFF, NEON CPU; the framework is gitignored and built by CI/dev setup. Podspec (platform :ios '15.0') vendors it with a clear guard message when missing, links Metal/MetalKit weakly as needed, ships Resources/PrivacyInfo.xcprivacy (DiskSpace E174.1; V-A13 decides whether ggml's sysctlbyname/clock_gettime need declared reasons). dv_whisper_forwarder.cpp keeps symbols alive for dlsym/DynamicLibrary.process().
- **Acceptance criteria and tests:** clean checkout + script + `flutter build ipa` (example or app) succeeds; guard message appears without the framework; `nm -um` shows no NEWLAPACK and check_ios_min_os.sh (ENG-09) finds nothing strongly bound above 15.0 (V-A1); the library builds with `-Werror=unguarded-availability-new`; the app launches and plays a video on the iPhone 7 (iOS 15.8) and iPhone 8 (iOS 16.7) lab devices and on the iOS 18.2 and 26 simulators; Metal used on an A15 device on iOS >= 16.4; IPA growth <= 6 MB thinned arm64.

#### AI-09 · Model store and resumable, verified downloader

- **Milestone:** M2 · **Area:** AI (whisper + transcription)
- **Depends on:** AI-08, AI-06
- **Owns:**
  - `packages/danaview_transcription/lib/src/models_store/`
  - `packages/danaview_transcription/test/models_store/`
- **Spec:** ai.md §5 and ARCH §16.3: ModelStore under <support>/danaview/speech/models/ (atomic manifest.json, .part + sidecar), states (absent, downloading(progress), verifying, ready, corrupt), delete (blocked while a job runs). Downloader: dart:io HttpClient, GET with followRedirects=false and `User-Agent: Danaview/<version>` (no identifiers); expect 302 and verify x-linked-size and x-linked-etag against the catalog BEFORE writing any byte; ranged GET on the signed CDN Location (206 append, 200 restart, 416 verify-or-restart), sidecar every 4 MiB, 15 s connect / 30 s idle timeouts, 3 retries with 2/4/8 s backoff + jitter re-resolving the redirect; free-space preflight (remaining + 64 MiB); SHA-256 in Isolate.run; ggml magic check (V-A5); atomic rename; excludeFromBackup via AI-06; wakelock during download; download requires a UserConsent whose disclosure equals the catalog spec (no consent memory). Test-only `installFromFile(spec, path)` (debug/profile only, asserts sha256) for CI and QA (no network).
- **Acceptance criteria and tests:** unit tests with a fake HTTP server for every status path, resume after kill, hash mismatch -> corrupt + deletion, consent mismatch rejection; real downloads of tiny and VAD verified once on each platform (recorded in PR).

#### AI-10 · Transcript normalizer, cache and checkpoints

- **Milestone:** M2 · **Area:** AI (whisper + transcription)
- **Depends on:** AI-08
- **Owns:**
  - `packages/danaview_transcription/lib/src/transcript/`
  - `packages/danaview_transcription/test/transcript/`
- **Spec:** ai.md §8.3-8.6: transcript file schema 1 (source µs, words with timestamps and probabilities, language, model sha, params version); TranscriptKey = sha256(quickHash | audioStream | modelSha256 | language | paramsVersion | vad); cache under <support>/danaview/speech/transcripts/ with LRU at 64 MiB, atomic writes, corrupt files ignored and regenerated, superset-range reuse; checkpoints `<key>.partial.jsonl` appended per finished chunk with replay; normalizer: annotation removal ([..], (..), music notes), repetition-loop collapse, nsp/logprob silence-hallucination gating, gated per-language phrase list, timing sanity. Job records for resume (7-day expiry) under jobs/.
- **Acceptance criteria and tests:** normalizer fixture tests; LRU and atomicity tests; checkpoint append/replay round trip; superset reuse; corrupt file regenerated.

#### AI-11 · Caption segmentation engine

- **Milestone:** M2 · **Area:** AI (whisper + transcription)
- **Depends on:** AI-08
- **Owns:**
  - `packages/danaview_transcription/lib/src/segmentation/`
  - `packages/danaview_transcription/test/segmentation/`
- **Spec:** ai.md §9: deterministic dynamic-programming segmenter turning timed words into cues: presets Standard (2 lines × 42 graphemes; 32 for 9:16), Single line, Short phrases; script profiles (CJK 16, Korean 18, no-space SE Asian 35, RTL), CPS 17 (CJK 9, Korean 12), min 0.83 s, max 7 s, 2-frame gap, kinsoku rules, cut-crossing penalty (cut list input), edges snapped to the project frame grid; grapheme counting via characters; output SubtitleCueDraft list.
- **Acceptance criteria and tests:** golden fixtures in 9 languages (en, es, de, ja, zh, ko, ar, hi, th) and property tests (no overlap, min/max durations, limits respected); 10k words <= 150 ms; 9:16 defaults applied.

#### AI-12 · Timeline planner, word mapping and merge

- **Milestone:** M2 · **Area:** AI (whisper + transcription)
- **Depends on:** AI-08, CORE-06
- **Owns:**
  - `packages/danaview_transcription/lib/src/timeline/`
  - `packages/danaview_transcription/test/timeline/`
- **Spec:** ARCH §16.4 steps 1 and 7, ai.md §10.1: DomainTimelineView adapter over EditProject; planner -> units {media, audioStream, sourceRange, clips, priority} including audible clips and excluding muted/zero-volume/soloed-out, reversed (reported), stills/images, no-audio media, music tracks (default unchecked); merge clips of the same media within 5 s; pad 0.5 s; scope (whole timeline | selected clips | range). Mapping words through ClipTimeMap.timelineTimeOf on a fresh timeline (edits during a job honoured), dropping words < 50% visible; overlap priority voice > main video > other video > other audio > music; cut list for the segmenter.
- **Acceptance criteria and tests:** planner tests (exclusions, merging, scope); mapping under constant speed, ramps, splits and trims; split clip yields continuous cues across the cut with the penalty applied; priority resolution tests.

### M3: Editor shell, timeline and live preview

#### INT-02 · [INTEGRATION] App wiring v1: EditorBootstrap, default plan compiler, routes, Home and Settings entry points

- **Milestone:** M3 · **Area:** Integration
- **Depends on:** UX-03, UX-04, UX-05, UX-07, UX-08, ENG-06, CORE-26, CORE-28, CORE-33, AI-04, AI-05
- **Owns:**
  - `packages/danaview_editor/lib/src/app/editor_bootstrap.dart`
  - `packages/danaview_editor/lib/src/editor/state/default_plan_compiler.dart`
  - `lib/main.dart`
  - `lib/router/app_router.dart`
  - `pubspec.yaml`
  - `test/editor_routes_test.dart`
- **Spec:** [INTEGRATION] EditorBootstrap.create({engine?, roots from danaview_data AppStorage, prefs}) -> provider overrides (engine, FileProjectRepository + FileMediaPoolService wired with engine.access and engine.probe, autosave, GC start after 30 s idle with an export gate, capabilities, prefs); on desktop/no engine returns overrides that keep the editor unavailable. DefaultPlanCompiler implements UX-08's PlanCompilerPort with core compileRenderPlan/PlanMemo in Isolate.run above 300 items and an AssetResolver over the session pool, proxies and availability. Root pubspec: add danaview_editor and danaview_editor_engine path deps and the integration_test dev dependency. lib/main.dart: on iOS/Android construct MobileEditorEngine and merge EditorBootstrap overrides; desktop unchanged. app_router.dart: routes /projects and /editor/:projectId?t= (redirect to / unless EditorAvailability.platform is supported and DANAVIEW_EDITOR; unknown id handled by the screen), explicit /settings/editor child route (not a SettingsDestination value), Home onOpenEditor and Settings onOpenEditorSettings wired only when available; StorageContributor registry override with EditorStorageContributor.
- **Acceptance criteria and tests:** route tests (gates per platform/flag, redirect on desktop, deep link /editor/x shows the empty state); macOS-targeted widget and route test (D-17): no edit button in _HomeHeader, no 'Video editor' settings row, no editor storage contributor, /projects and /editor/* redirect to /; app boots on iOS simulator and Android emulator with DANAVIEW_EDITOR=true and opens Projects from Home; desktop builds (macOS/Windows/Linux CI) unaffected; all existing tests green.

#### CORE-34 · Model fuzzer (commands, history, codec, plan diff)

- **Milestone:** M3 · **Area:** Core (pure Dart)
- **Depends on:** CORE-11, CORE-12, CORE-14, CORE-15, CORE-16, CORE-17, CORE-19, CORE-22, CORE-32
- **Owns:**
  - `packages/danaview_editor_core/test/fuzz/`
  - `scripts/ci/editor/nightly.d/core_fuzz.sh`
- **Spec:** Random projects (CORE-08 generator) × random command sequences drawn from every command group, through EditSession: validator after every step, undo^n/redo^n identity, stamps never repeat, JSON round trip, compile + diff/patch identity, dryRun placement equals apply placement, no exceptions escape. CI: 200 seeds × 500 steps inside `dart test` (tagged fuzz-lite); nightly: 10,000 seeds via nightly.d/core_fuzz.sh. Failing seeds are minimized and written as regression fixtures.
- **Acceptance criteria and tests:** fuzz-lite green in dart-core; nightly script runs; at least one minimizer test proves shrinking works; command coverage report shows every EditCommand subtype exercised.

#### ENG-02 · Dart glue: mobile preview session

- **Milestone:** M3 · **Area:** Engine (Dart)
- **Depends on:** ENG-06, API-02
- **Owns:**
  - `packages/danaview_editor_engine/lib/src/mobile_preview_session.dart`
  - `packages/danaview_editor_engine/test/preview/`
- **Spec:** MobilePreviewSession implements PreviewSession over PreviewHostApi: textureId and frameSize, setPlan/applyPatch with plan_transport bytes (isolate encode) and PlanAck, setTransient/clearTransient (fire-and-forget, coalesced to one per frame on the Dart side), play/pause/seek (exact|scrub; <= 1 scrub seek in flight, latest wins), setQuality, setUseProxies, setEditingMode, showSourceFrame, sampleColor, renderLookStills, refresh, debugCaptureFrame, clock stream (seq rules of ARCH §12.2), events (firstFrame, stalled, recovered, degraded, surfaceLost, failed), dispose (idempotent; late events dropped).
- **Acceptance criteria and tests:** mocked-channel tests: seq handling, scrub coalescing, planOutOfSync surfaced as EngineFailure for PlanSync, dispose during in-flight calls; contract kit passes against mocked channels; real-device behaviour verified by IOS-11/AND-10 example integration tests.

#### IOS-08 · iOS plan decode, ParamSnapshot, composition builder, instructions, audio mix

- **Milestone:** M3 · **Area:** iOS native
- **Depends on:** ENG-06, CORE-29, CORE-32, API-03, IOS-18
- **Owns:**
  - `packages/danaview_editor_engine/ios/Classes/Plan/`
  - `packages/danaview_editor_engine/ios/Classes/Composition/`
  - `packages/danaview_editor_engine/example/ios/RunnerTests/Composition/`
- **Spec:** Implements ARCH §11 (which overrides native.md §4.2: flat lowered layers, no lanes, no transition code) and §13.2 'Composition' and 'Audio'. Plan/: JSONDecoder models for RenderPlan/Patch/Transient v1 (unknown keys ignored), validator mirroring ARCH §11.3, ParamSnapshot (immutable per-layer params incl. evaluated anim channels), patch classification matching test/fixtures/render_plans/classification.json, keyframe evaluation matching API-03 vectors. Composition/: CompositionBuilder on previewControlQueue (one AVURLAsset per media with precise timing, loadTracks; media layers placed on the composition video track named by their `seq` (CORE-36 packing); per map segment insertTimeRange(srcRange shifted +500 µs per D-04, at: CMTime(k0, gridFps)) + scaleTimeRange to CMTime(k1 − k0, gridFps) — grid times are never converted to µs CMTimes (D-35); a 16×16 one-frame spacer generated at runtime with AVAssetWriter into <cache>/danaview/editor/engine/spacer_16x16_v1.mov when missing, scaled across CMTime(0…K, gridFps)), InstructionBuilder (DVInstruction per layer boundary with CMTime(k, gridFps) ranges, bottom -> top, required source track ids, isValid in debug), AVMutableVideoComposition (customVideoCompositorClass, frameDuration 1/fps, BT.709), audio segments interval-coloured × pitch with AVMutableAudioMixInputParameters (.timeDomain for keep-pitch, not .spectral — ARCH §13.2, IOS-01 V-N21 — or .varispeed) and IOS-18's GainTap carrying the gain envelope (no setVolumeRamp, D-37); gain-only patches swap the tap envelope; when IOS-18's ramp-seam option is enabled, ramp segments alternate across two audio tracks; security-scoped bookmark access refcounted per session.
- **Acceptance criteria and tests:** every contract fixture decodes and re-encodes equal; all fixtures build valid compositions; every grid-aligned edit point, scaled duration and instruction range is an exact CMTime(k, gridFps) and source ranges equal the plan's µs; on grid_cuts_30fps.json the instruction found at CMTime(k, 30) for every frame k matches expected_active.json; frame-grid, packing and keyframe vectors pass; tap envelopes equal the plan gain envelopes; a no-audio plan builds a composition with no audio tracks without exceptions; classification vectors pass; build of a 2,000-item plan <= 150 ms (mid).

#### IOS-09 · iOS render kernels, LUT/sprite/image stores

- **Milestone:** M3 · **Area:** iOS native
- **Depends on:** ENG-06, API-03, API-04, CORE-21
- **Owns:**
  - `packages/danaview_editor_engine/ios/Classes/Render/Shaders/DanaviewKernels.metal`
  - `packages/danaview_editor_engine/ios/Classes/Render/Kernels.swift`
  - `packages/danaview_editor_engine/ios/Classes/Render/LutStore.swift`
  - `packages/danaview_editor_engine/ios/Classes/Render/SpriteStore.swift`
  - `packages/danaview_editor_engine/ios/Classes/Render/ImageLayerCache.swift`
  - `packages/danaview_editor_engine/example/ios/RunnerTests/Kernels/`
- **Spec:** Metal Core Image kernels (compiled per IOS-01/ENG-06 settings) implementing ARCH §11.6 in D-08 order: dv_look (crop sampling, chroma + spill, grade, LUT via tiled 2D texture with trilinear sampling), dv_blur_h/dv_blur_v (separable Gaussian, σ in plan-canvas px scaled to render px), dv_sharpen, dv_vignette_mask (vignette + mask SDF), dv_cmask (canvas masks), dv_reveal (sprite glyph-order threshold), dv_matte (chroma matte preview). Kernels.swift wraps them as CIFilter-like functions with colour management off. LutStore loads .vlut (D-07) into tiled textures (N tiles of N×N in a ceil(sqrt N) grid). SpriteStore decodes .vsprite (zlib premultiplied RGBA + reveal map). ImageLayerCache: decoded images/solids at render scale.
- **Acceptance criteria and tests:** every render-math vector from API-03 passes on 8×8 images through a software CIContext and on the simulator GPU within the ARCH §11.6 tolerance; LUT of size 2, 33, 65 load; sprite fixtures from API-04 decode; per-kernel timing logged.

#### IOS-10 · iOS DVCompositor, layer renderer, redraw cache

- **Milestone:** M3 · **Area:** iOS native
- **Depends on:** IOS-08, IOS-09
- **Owns:**
  - `packages/danaview_editor_engine/ios/Classes/Render/DVCompositor.swift`
  - `packages/danaview_editor_engine/ios/Classes/Render/DVInstruction.swift`
  - `packages/danaview_editor_engine/ios/Classes/Render/LayerRenderer.swift`
  - `packages/danaview_editor_engine/ios/Classes/Render/RedrawCache.swift`
  - `packages/danaview_editor_engine/example/ios/RunnerTests/Compositor/`
- **Spec:** DVCompositor: AVVideoCompositing with BGRA IOSurface/Metal source buffers, supportsHDRSourceFrames = false, one CIContext(mtlDevice:) with working/output colour space NSNull, LayerRenderer applying per-layer stages and placement (CIImage.transformed with the §11.6 matrix), CISourceOverCompositing onto the opaque bg, canvas masks, sprite and solid layers; each request computes k = round(compositionTime × fps), evaluates layers, anim channels and reveal at timeOfFrame(k) and stamps `danaview.frame = k` on output buffers (D-35). ParamSnapshot swapped atomically, never locked during a render; generation counter cancellation. RedrawCache keeps the last request's source buffers so param patches, transients, editing modes (normal, cropSource(item), matte(item)) and look stills render on the same path while paused (<= 30 ms). Export variant parameters (render size = output, frameDuration = 1/export fps) supported.
- **Acceptance criteria and tests:** render parity vs API-03 reference goldens for every golden plan within tolerance (simulator, recorded for device in QA-03), including the 8× scale-keyframed text sprite; grid_cuts_30fps.json renders the expected layers at every frame; compose <= 8 ms mid at 1080p with 2 layers + LUT + sprite; redraw-from-cache <= 30 ms; matte and cropSource modes; typewriter reveal; cancellation works.

#### IOS-11 · iOS preview session: texture, display link, clock, seek, patches, quality, lifecycle

- **Milestone:** M3 · **Area:** iOS native
- **Depends on:** IOS-10, IOS-06, ENG-02
- **Owns:**
  - `packages/danaview_editor_engine/ios/Classes/Preview/PreviewSession.swift`
  - `packages/danaview_editor_engine/ios/Classes/Preview/PreviewSessionManager.swift`
  - `packages/danaview_editor_engine/ios/Classes/Preview/TextureBridge.swift`
  - `packages/danaview_editor_engine/ios/Classes/Preview/DisplayLinkDriver.swift`
  - `packages/danaview_editor_engine/ios/Classes/Preview/SeekController.swift`
  - `packages/danaview_editor_engine/ios/Classes/Preview/QualityGovernor.swift`
  - `packages/danaview_editor_engine/ios/Classes/Preview/AudioSessionCoordinator.swift`
  - `packages/danaview_editor_engine/example/ios/RunnerTests/Preview/`
  - `packages/danaview_editor_engine/example/integration_test/ios_preview_test.dart`
- **Spec:** ARCH §13.2 'Session' and §12.2/§12.7 semantics: AVPlayer (automaticallyWaitsToMinimizeStalling false), seekingWaitsForVideoCompositionRendering, AVPlayerItemVideoOutput -> TextureBridge (FlutterTexture copyPixelBuffer, IOSurface BGRA) driven by DisplayLinkDriver at project fps (paused when idle), item time requested for `displayLink.targetTimestamp` + the measured texture latency (§12.7); SeekAck.displayedFrameTime = timeOfFrame(danaview.frame); clock 10 Hz with seq; exact seek CMTime(k, fps) tolerance zero then wait for the buffer whose danaview.frame == k (500 ms timeout) and ack displayed frame; scrub with tolerance and one seek in flight; setPlan/applyPatch (param-only -> snapshot swap + redraw; structural -> new item, replaceCurrentItem, exact seek to the current frame, restore play state, keep old frame until the first new one); transients merged into the snapshot <= 1 per frame; setQuality/QualityGovernor (render scale 1, 1/2, 1/4 capped by maxPreviewLongSide; step down after > 10% missed frames over 2 s, up after 10 s clean; thermal serious forces <= half); setUseProxies; showSourceFrame; sampleColor; renderLookStills; lifecycle (resign active pause + stop display link; background releases CI intermediates; active -> refresh; memory warning trims caches and emits signals); AudioSessionCoordinator sets .playback/.moviePlayback while playing and restores the previous category on dispose (R13). Owner decision 2026-10-11 (D-43(e), D-45): `PreviewQuality.auto` adapts full → 1/2 → 1/4 and recovers (QualityGovernor), pinned qualities never change; where the device decoder limit is hit, the excess tracks play as paused-exact stills during playback only; a rendered-range hook (no-op by default, implemented by IOS-19) lets a rendered range play from its render-preview file.
- **Acceptance criteria and tests:** example integration test through MobileEditorEngine: seq rules, exact ack 200/200 (incl. every frame around the grid_cuts cuts), scrub coalescing, preview A/V offset <= 1 frame and <= 40 ms on clap_flash (instrumented, device recorded), transient visible <= 2 frames, param patch <= 30 ms and structural <= 250 ms (mid; simulator numbers reported), degraded/recovered events, background/foreground without a black frame after 1 s, dispose releases the texture. **Amended 2026-10-11 (D-43(e)):** a pinned quality is never changed by the governor; paused, scrub and exact seek are exact for every layer even when playback uses stills; the rendered-range hook is called at range boundaries (test double).

#### AND-08 · Android plan reader, ParamSnapshot, composition mapper, gating, speed and gain providers

- **Milestone:** M3 · **Area:** Android native
- **Depends on:** ENG-06, CORE-29, CORE-32, API-03
- **Owns:**
  - `packages/danaview_editor_engine/android/src/main/kotlin/com/vecvel/danaview/editor/engine/plan/`
  - `packages/danaview_editor_engine/android/src/main/kotlin/com/vecvel/danaview/editor/engine/composition/`
  - `packages/danaview_editor_engine/android/src/test/kotlin/com/vecvel/danaview/editor/engine/composition/`
  - `packages/danaview_editor_engine/android/src/androidTest/kotlin/com/vecvel/danaview/editor/engine/composition/`
- **Spec:** ARCH §11 (overrides native.md §4.2) and §13.3 'Sequence stack', 'Items', 'Compositing'. plan/: android.util.JsonReader decoding of RenderPlan/Patch/Transient v1 (unknown keys ignored), validator mirroring §11.3, ParamSnapshot, classification vectors, keyframe evaluation vectors. composition/: CompositionMapper building the multi-sequence Composition (0 = transparent clock band at the output fps built with trackTypes {VIDEO, AUDIO} so a silent audio track always exists, D-38; one video sequence per CORE-36 `seq` slot, ordered top -> bottom, trackTypes {VIDEO}, padded with gaps; background solid; audio-only sequences per interval colour with trackTypes {AUDIO}; no deprecated force-track setters), **every item and gap boundary anchored at P(k) = round(k·1e6/gridFps)** (durations as differences of P; media clipping end adjusted by ≤ 1 µs × rate, D-35), MediaItem ClippingConfiguration from maps with the ε mechanism chosen in AND-01, setRemoveAudio for video, SegmentSpeedProvider(map) with keepPitch, items faster than 1× capped at the project fps with setFrameRate (V-N17), image items with duration and frame rate, GainProcessor(KeyframedGainProvider) sample-exact envelopes (0–2), LayerGatingCompositorSettings (k = frameIndexNearest(pts); alphaScale 0 when no layer of the sequence covers timeOfFrame(k)), Composition.setHdrMode(tone map OpenGL), composition audio Sonic(48 kHz) + ChannelMixing(stereo); every file opts in with @OptIn(UnstableApi::class, ExperimentalApi::class); per-layer effect lists [LayerLookEffect, SeparableBlurEffect?, LayerPlaceEffect] referencing AND-09 classes (placeholders until then); content:// read-only access.
- **Acceptance criteria and tests:** every contract fixture maps; sequence durations equal durUs and every cumulative item/gap boundary equals P(k) exactly (frame_grid vectors at 24/25/30/48/50/60); on grid_cuts_30fps.json gating at P(k) matches expected_active.json for every frame; packing vectors honoured (sequence count = slot count); a no-audio plan still yields an audio track; z-order and gating unit tests; SegmentSpeedProvider integrates to plan durations ±1 µs; gain envelope sample-exact vs vectors; classification vectors pass; 2,000-item mapping <= 150 ms mid.

#### AND-09 · Android GL effects, shaders, LUT and sprite textures

- **Milestone:** M3 · **Area:** Android native
- **Depends on:** ENG-06, API-03, API-04, CORE-21
- **Owns:**
  - `packages/danaview_editor_engine/android/src/main/kotlin/com/vecvel/danaview/editor/engine/effects/`
  - `packages/danaview_editor_engine/android/src/main/assets/danaview_shaders/`
  - `packages/danaview_editor_engine/android/src/test/kotlin/com/vecvel/danaview/editor/engine/effects/`
  - `packages/danaview_editor_engine/android/src/androidTest/kotlin/com/vecvel/danaview/editor/engine/effects/`
- **Spec:** ARCH §13.3 'GL effects' and §11.6 math in GLSL ES 1.00: LayerLookEffect (dv_look.glsl: crop via texcoords, chroma + spill, grade, LUT tiled sampler, matte flag; configure returns min(source, render size ÷ (item scale × max animated scale)) so 4K sources downscale first without softening keyframed zooms), SeparableBlurEffect (only when blur > 0 at any time), LayerPlaceEffect (dv_place.glsl: sharpen, vignette, mask SDF, inverse-mapped placement matrix, opacity, canvas masks, 1 px antialiased edges; outputs canvas-render-size straight-alpha texture), SpriteBandEffect (export: sprite quads with M and reveal map from .vsprite), LUT (.vlut) and sprite texture loaders; params read from AtomicReference<ParamSnapshot> at drawFrame(ptsUs) with k = frameIndexNearest(ptsUs); **early exit**: when timeOfFrame(k) is outside the sequence's layers every effect clears to transparent and skips sampling, LUT and blur (review issue 3); sprite textures respect maxTextureSize; only the danaview-gl thread touches GL (assertion); resources released on effect release. The shader programs are exposed through a small `ShaderPrograms` API so AND-17's PausedFrameRenderer reuses them.
- **Acceptance criteria and tests:** render-math vectors and parity goldens (API-03) pass on the API 35 emulator within tolerance, incl. the 8× scale-keyframed case; a gated frame costs one clear (GL timer query); GL leak test; 1080p compose <= 8 ms mid (GL timer query, recorded in QA-04).

#### AND-17 · Android paused-frame renderer, layer GL compositor and structural debounce

- **Milestone:** M3 · **Area:** Android native
- **Depends on:** AND-08, AND-09, AND-06
- **Owns:**
  - `packages/danaview_editor_engine/android/src/main/kotlin/com/vecvel/danaview/editor/engine/preview/PausedFrameRenderer.kt`
  - `packages/danaview_editor_engine/android/src/main/kotlin/com/vecvel/danaview/editor/engine/preview/LayerCompositorGl.kt`
  - `packages/danaview_editor_engine/android/src/main/kotlin/com/vecvel/danaview/editor/engine/preview/StructuralDebouncer.kt`
  - `packages/danaview_editor_engine/android/src/androidTest/kotlin/com/vecvel/danaview/editor/engine/paused/`
- **Spec:** D-36 (review issue 2): Media3 redraws only input 0 while paused and setComposition rebuilds every player, so paused editing never goes through the player. LayerCompositorGl: renders a list of per-layer source textures through AND-09's shader programs (LayerLook, optional blur, LayerPlace) into canvas-render-size targets and blends them premultiplied source-over onto the background, bottom -> top, on the danaview-gl thread. PausedFrameRenderer: on pause and after each exact seek settles, prefetches EXACT frames (AND-06 SourceFrameCache / FrameExtractor) of the media layers active at timeOfFrame(k) (cancelled by play or seek); while paused, any param patch, transient, editing mode (normal, cropSource, matte) or structural edit renders the current plan + transients at frame k through LayerCompositorGl onto the SurfaceProducer with the player surface detached (the showSourceFrame mechanism); extracting only newly needed layers for structural edits; reattaches the player surface on play or seek. StructuralDebouncer: coalesces structural patches (150 ms trailing, 600 ms max wait) and runs setComposition in the background, swapping to the player surface on its first frame when playing.
- **Acceptance criteria and tests:** pixels of the paused frame match the player's composed frame for the same plan within the ARCH §11.6 parity tolerance; changing an effect on a secondary sequence while paused updates the frame (the case Media3 redraw misses); transient round trip <= 2 frames mid after prefetch; paused structural edit visible <= 250 ms mid / 400 ms low; debounce coalesces 10 structural patches in 1 s into <= 3 rebuilds; GL resources released on dispose.

#### AND-10 · Android preview session: SurfaceProducer, clock, seek/scrub, transients, redraw, quality, lifecycle

- **Milestone:** M3 · **Area:** Android native
- **Depends on:** AND-08, AND-09, AND-06, ENG-02, AND-17
- **Owns:**
  - `packages/danaview_editor_engine/android/src/main/kotlin/com/vecvel/danaview/editor/engine/preview/PreviewSession.kt`
  - `packages/danaview_editor_engine/android/src/main/kotlin/com/vecvel/danaview/editor/engine/preview/PreviewSessionManager.kt`
  - `packages/danaview_editor_engine/android/src/main/kotlin/com/vecvel/danaview/editor/engine/preview/SurfaceBridge.kt`
  - `packages/danaview_editor_engine/android/src/main/kotlin/com/vecvel/danaview/editor/engine/preview/SeekController.kt`
  - `packages/danaview_editor_engine/android/src/main/kotlin/com/vecvel/danaview/editor/engine/preview/QualityGovernor.kt`
  - `packages/danaview_editor_engine/android/src/androidTest/kotlin/com/vecvel/danaview/editor/engine/preview/`
  - `packages/danaview_editor_engine/example/integration_test/android_preview_test.dart`
- **Spec:** ARCH §13.3 'Session' and §12.7: PreviewSession hosts a `PreviewBackend` interface (CompositionPlayer backend here; AND-16's multi-player backend only on an AND-01 no-go). CompositionPlayer built with MultipleInputVideoGraph.Factory (WORKING_COLOR_SPACE_ORIGINAL; no replayable cache, D-36), own GL executor and preview HandlerThread, audio focus; SurfaceBridge over TextureRegistry.createSurfaceProducer(resetInBackground) with onSurfaceCleanup detach (main thread waits <= 500 ms on a latch; preview thread never waits on main) and onSurfaceAvailable reattach + redraw; clock polled at 10 Hz with seq; exact seek to P(k) rounded to ms per frame_grid.json's androidSeekMsRounding, acked on the first onVideoFrameAboutToBeRendered with frameIndexNearest(pts) == k (500 ms timeout -> ack actual; D-35); scrubbing mode while dragging; **paused edits go through AND-17's PausedFrameRenderer** (param patches, transients, editing modes and structural edits while paused; experimentalRedrawLastFrame is not used, D-36); **structural patches go through AND-17's StructuralDebouncer** (150 ms trailing, 600 ms max wait), then setComposition(c, positionMs) while the paused frame (or, during playback, the last frame) stays on screen; quality (resize producer + rebuild), thermal SEVERE forces <= half; look stills, sampleColor and trim-edge frames via FrameExtractor EXACT with LayerLookEffect overrides; PreviewSessionManager suspends the session during export on minimal/low/mid tiers. On an AND-01 no-go this ticket ships the shell and PreviewBackend interface, and its playback acceptance criteria are met through AND-16.
- **Acceptance criteria and tests:** example integration test through MobileEditorEngine with the IOS-11 acceptance list (seq, exact ack 200/200 incl. every frame around the grid_cuts cuts at 24/30/60 fps, scrub coalescing, transient <= 2 frames while paused, param patch <= 30 ms mid) and the renegotiated Android structural budgets of ARCH §13.4 (paused structural edit visible <= 250 ms mid / 400 ms low; playback-ready <= 600 ms mid / 1,000 ms low with <= 4 sequences); preview A/V offset <= 1 frame and <= 40 ms after compensation (V-N23); resetInBackground surface loss recovers, latch never > 500 ms, rebuild keeps the last frame.

#### AND-16 · Android contingency preview engine (conditional: only on an AND-01 no-go)

- **Milestone:** M3 · **Area:** Android native
- **Depends on:** AND-10, AND-17
- **Owns:**
  - `packages/danaview_editor_engine/android/src/main/kotlin/com/vecvel/danaview/editor/engine/preview/fallback/`
  - `packages/danaview_editor_engine/android/src/androidTest/kotlin/com/vecvel/danaview/editor/engine/fallback/`
  - `packages/danaview_editor_engine/android/src/main/cpp/` (the JNI shim: `CMakeLists.txt` and its source; assigned by the lead 2026-10-15, ARCH §13.3 Build)
- **Spec:** Built only if AND-01 records a no-go (ENG-06 activates it); otherwise closed as 'not needed' with AND-01's report attached, like UX-43. ARCH §13.3 'Contingency' (review issue 8): a `MultiPlayerBackend` implementing AND-10's PreviewBackend with one ExoPlayer per packing slot rendering into a SurfaceTexture (OES texture) and one per audio slot (same speed and gain processors), composited by AND-17's LayerCompositorGl on a frame clock at the project fps (Choreographer-driven), which also sets the audio master clock; drift > ½ frame corrects by seeking the late player; gaps and gating follow the plan (no Media3 composition). Export stays on Transformer (AND-11). Sizing: about 1,200–1,500 lines, ~3 weeks of the Android lane (schedule impact recorded by ENG-06). Degradations signed off by the owner on 2026-10-11 (D-43(e)): layers beyond the tier's live decode budget play from paused-exact still frames during playback only (paused, scrub and exact seek are always exact for every layer); exact seek up to +30% against ARCH §13.4, showing the nearest decoded frame at once and then refining to the exact frame; under load a frame is dropped, never shown late or wrong; `maxVisualSequences` limits live preview only (export never refuses, D-45). **JNI shim:** port AND-01's HardwareBuffer → OES import (`spikes/android_engine/app/src/main/cpp/`: `eglCreateImageKHR` + `glEGLImageTargetTexture2DOES`, linking `EGL`, `GLESv2`, `android`, `nativewindow`, `log`) into `src/main/cpp/`; ENG-06's `build.gradle.kts` switches the CMake build on when `src/main/cpp/CMakeLists.txt` exists (ABIs, `android-29`, NDK 28.2.13676358, CMake 3.22.1 and the staging directory are already set there and stay frozen); `System.loadLibrary` only behind the API 29 editor gate. Provides a rendered-range hook (`RenderedRangeHook`, no-op by default) inside `preview/fallback/` that AND-18 implements, so a rendered range plays from its render-preview file (D-45).
- **Acceptance criteria and tests (when built):** AND-10's playback acceptance list passes through this backend; transitions (cross dissolve, slide, wipe, zoom) and video-over-video PiP play in real time at 30 fps on the mid device with <= 2% dropped; A/V offset <= 1 frame over 10 min; frame-grid and grid-cut barcode cases pass. **Amended 2026-10-11 (owner decision, D-43(e)):** with more active layers than the tier's live budget, the excess play as paused-exact stills during playback and every layer is exact when paused, scrubbing or after an exact seek (barcode test); an exact seek while playing shows the nearest decoded frame first and acks only the exact frame, within the +30% budget; under injected load frames are dropped and none is late or wrong; adaptive quality steps full → 1/2 → 1/4 under load and recovers (degraded/recovered events); the rendered-range hook is called at range boundaries (test double).

#### AI-07 · whisper Dart runtime (WhisperRuntime, WhisperModel, WhisperJob)

- **Milestone:** M3 · **Area:** AI (whisper + transcription)
- **Depends on:** AI-03, AI-06, AI-04, AI-05
- **Owns:**
  - `packages/danaview_whisper/lib/src/runtime/`
  - `packages/danaview_whisper/lib/src/ffi/library_loader.dart`
  - `packages/danaview_whisper/test/runtime/`
- **Spec:** ai.md §4.7: library_loader (iOS DynamicLibrary.process(); Android picks libdanaview_whisper_v82.so when HWCAP has asimddp+fphp, else baseline; x86_64 baseline; ABI version check); WhisperRuntime.open() (unsupported on desktop / armeabi-v7a), WhisperModel load/unload with refcounting (released 60 s after the last job, immediately on low memory), WhisperJob (transcribe or detect) polling status and segments every 250 ms with leaf FFI calls, cancel/pause/resume, progress, typed errors; never blocks the UI isolate inside FFI; dv_shutdown_all on hot restart.
- **Acceptance criteria and tests:** runtime tests with fake bindings; on device, transcribing jfk.wav through the Dart API matches the host test text; hot restart during a job leaves no orphan thread; poll cost < 0.5 ms p95 (trace).

#### UX-04 · Storage contributors, Settings row and Editor settings screen

- **Milestone:** M3 · **Area:** UI/UX
- **Depends on:** UX-01, CORE-25
- **Owns:**
  - `packages/danaview_features/lib/src/tools/storage_usage.dart`
  - `packages/danaview_features/lib/src/tools/danaview_storage_screen.dart`
  - `packages/danaview_features/lib/src/more/danaview_settings_screen.dart`
  - `packages/danaview_features/lib/storage.dart`
  - `packages/danaview_editor/lib/src/app/editor_storage_contributor.dart`
  - `packages/danaview_editor/lib/src/settings/editor_settings_screen.dart`
  - `packages/danaview_editor/lib/src/app/strings/settings_strings.dart`
  - `test/editor_entry/storage_contributors_test.dart`
  - `packages/danaview_editor/test/settings/`
- **Spec:** ARCH §17.10, ux.md §4.8: StorageContributor extension point in danaview_features (lib/storage.dart: abstract contributor with title, bytes stream, optional clear action with confirmation copy, optional open action; a registry provider the app root overrides) rendered by DanaviewStorageScreen without danaview_features depending on the editor. DanaviewSettingsScreen gets an optional onOpenEditorSettings callback that shows a 'Video editor' row (null hides it); no SettingsDestination enum change (routes are explicit, INT-02). danaview_editor: EditorStorageContributor ('Video editor projects' bytes from storageReport, opens Projects, no clear; 'Editor cache' clears thumbnails/waveforms/proxies/sprites/looks, disabled while a session or job is active, never touches projects); EditorSettingsScreen (proxy media Auto/Always/Off, default preview quality, centre playhead on touch, snapping haptics, default new-project aspect, and a slot for UX-38's captions section). Owner decision 2026-10-11 (D-43(e), D-45): the proxy row's unset default is Always on the minimal and low tiers and Auto on mid/high (read through an injectable default that UX-44's `EditorTierDefaults` supplies; Auto until it lands); a second settings slot for UX-44's render-preview section; 'Editor cache' also counts and clears render-preview files (`<cache>/danaview/editor/renders/`, D-45).
- **Acceptance criteria and tests:** storage screen shows contributors with correct clear semantics (fake contributors); cache clear never deletes project files (core test double asserts); settings row hidden when callback null; editor settings persisted in prefs; matrix tests no overflow. **Amended 2026-10-11:** 'Editor cache' bytes include `renders/` and its clear empties it (never touching projects); the proxy row shows the tier default when the pref is unset.

#### UX-05 · Projects screen and controller

- **Milestone:** M3 · **Area:** UI/UX
- **Depends on:** UX-01, CORE-25
- **Owns:**
  - `packages/danaview_editor/lib/src/projects/projects_screen.dart`
  - `packages/danaview_editor/lib/src/projects/projects_controller.dart`
  - `packages/danaview_editor/lib/src/projects/project_card.dart`
  - `packages/danaview_editor/lib/src/projects/project_actions.dart`
  - `packages/danaview_editor/lib/src/app/strings/projects_strings.dart`
  - `packages/danaview_editor/test/projects/`
- **Spec:** ux.md §5: ProjectsScreen (grid on wide, list on narrow; cards with poster, name, duration, aspect, updated time, badges: missing media, recovery, newer app, read-only, corrupt), create (opens UX-06's sheet), open, rename (DanaviewNumberField-style text dialog via showDanaviewSheet), duplicate, delete with an undo window (delete happens after the window), sort (recent, name) and search (DanaviewSearchField), empty/error/unsupported-device states (EditorCapabilities.unsupportedReason copy), Recovery entry points (banner from UX-40 placeholder). ProjectsController (StateNotifier over repository.watchSummaries; actions with typed failures -> editor_messages). Navigation via callbacks (onBack, onOpenProject(id, {initialPlayhead})) wired by INT-02.
- **Acceptance criteria and tests:** widget tests with the fake repository for every action and state; delete undo window; search/sort; matrix tests at all sizes; Projects first paint budget instrumented (QA-04).

#### UX-06 · New project sheet and import media sheet

- **Milestone:** M3 · **Area:** UI/UX
- **Depends on:** UX-05, CORE-27
- **Owns:**
  - `packages/danaview_editor/lib/src/projects/new_project_sheet.dart`
  - `packages/danaview_editor/lib/src/editor/flows/import_media_sheet.dart`
  - `packages/danaview_editor/lib/src/app/strings/import_strings.dart`
  - `packages/danaview_editor/test/flows/import/`
- **Spec:** ux.md §5.3: NewProjectSheet (Photos/Gallery picker, Files picker, aspect choice 16:9/9:16/1:1/4:5/4:3/21:9 or 'match first video', 'Start empty'); ImportMediaSheet used by the sheet, the editor's Media tool, external drops (UX-36) and the player's Edit (UX-41): free-space preflight (size + 64 MB) before any managed copy, per-item progress (probe, copy) with Cancel that deletes partial copies, inline errors (unsupported container with platform copy, permission denied, disk full), result summary; the 'copied into Danaview' hint only for iOS Photos picks (D-13). Calls engine.picker.pick then mediaPoolService.import / repository.create(fromMedia).
- **Acceptance criteria and tests:** widget tests with fakes for success, partial failure, cancel mid-copy (partial file deleted), free-space refusal, unsupported files, iOS-only hint; matrix tests.

#### UX-07 · Editor screen shell, scope, lifecycle and layout planner

- **Milestone:** M3 · **Area:** UI/UX
- **Depends on:** UX-01, UI-01
- **Owns:**
  - `packages/danaview_editor/lib/src/editor/editor_screen.dart`
  - `packages/danaview_editor/lib/src/editor/editor_scope.dart`
  - `packages/danaview_editor/lib/src/editor/editor_lifecycle.dart`
  - `packages/danaview_editor/lib/src/editor/layout/`
  - `packages/danaview_editor/test/layout/`
- **Spec:** ARCH §17.2, ux.md §6, §4.7: EditorLayoutSpec.resolve(size, padding, viewInsets, textScaler, touch, splitRatio, inspectorOpen) pure planner (kinds compactLandscape/compactPortrait/medium/expanded; regions top bar, preview, transport, timeline, tool strip/rail, inspector dock or side pane; sizes from text scale; deterministic degradation ladder recorded in spec.degrade); EditorScreen composing region widgets (placeholders from UX-01 until their tickets land: preview region UX-18, transport UX-14, timeline view UX-12, toolbar and inspector UX-16), top bar (close, title button with save status, undo, redo, export), splitter persisted per kind; EditorScope (InheritedWidget with ProjectId); EditorLifecycle (PopScope(canPop: false) back order: cancel gesture -> close panel -> clear selection -> exit fullscreen -> close editor with flush; app hidden/paused triggers save; orientation via ScreenOrientationPolicy.free on phones; V-U3 verify iOS edge back-swipe disabled); unknown project id -> empty state 'This project isn't available' with 'Go to Projects'. EditorScreen(projectId, initialPlayhead, onClose, onOpenProjects) takes navigation callbacks from the router (INT-02).
- **Acceptance criteria and tests:** layout planner unit matrix over all ARCH §17.9 sizes × text scales × keyboard insets (no region below its minimum, ladder deterministic); widget tests for each layout with placeholders; back-order tests; V-U3 recorded: on the iOS simulator the edge back-swipe does not pop the editor (PopScope(canPop: false)), or the documented fallback is applied and tested.

#### UX-08 · EditorController, EditorState, EditTransaction, session wiring, events, messages

- **Milestone:** M3 · **Area:** UI/UX
- **Depends on:** UX-01, CORE-19, CORE-26, API-02
- **Owns:**
  - `packages/danaview_editor/lib/src/editor/state/editor_state.dart`
  - `packages/danaview_editor/lib/src/editor/state/editor_controller.dart`
  - `packages/danaview_editor/lib/src/editor/state/edit_transaction.dart`
  - `packages/danaview_editor/lib/src/editor/state/editor_session.dart`
  - `packages/danaview_editor/lib/src/editor/state/editor_events.dart`
  - `packages/danaview_editor/lib/src/editor/state/plan_compiler_port.dart`
  - `packages/danaview_editor/lib/src/app/editor_messages.dart`
  - `packages/danaview_editor/test/state/`
- **Spec:** ARCH §17.3 and ux.md §16: EditorState exactly as specified (nothing changes per playback frame); EditorController: open({initialPlayhead}) (repository.open, recovery/migration outcomes surfaced, preview session opened via engine with PlanSync and the PlanCompilerPort, exact seek to the initial playhead), close() (flush <= 3 s, dispose preview, repository.close), saveNow({manual}), apply(cmd) -> EditResult (session.apply; rejection -> info toast event; commit -> PlanSync.schedule + requestAutosave + events), beginTransaction(label) -> EditTransaction (update replaces previous, per-frame state coalescing, transients via core transientFor + PlanSync.sendTransient <= 60 Hz, commit = one history entry + one patch + one autosave request, cancel restores), undo/redo/jumpHistory (one plan patch), selection/tool/inspector/modes, lifecycle hooks, poster capture on hide/close (engine thumbnail at the playhead passed to repository.save); editor_session.dart wraps EditSession for providers; plan_compiler_port.dart declares the port INT-02 implements; editor_events (toasts, haptics, announcements); editor_messages maps every EditorFailure subtype and every EditRejection to plain copy with a next step (ARCH §19).
- **Acceptance criteria and tests:** unit tests with fake engine/repository: apply/undo/redo/transactions, coalescing, autosave requested on commit and flushed on hide/close, one history entry per transaction, PlanSync called once per commit; every failure/rejection has copy (exhaustive switch test).

#### UX-09 · Timeline viewport controller, ruler, metrics and style

- **Milestone:** M3 · **Area:** UI/UX
- **Depends on:** UX-01, CORE-02
- **Owns:**
  - `packages/danaview_editor/lib/src/editor/timeline/timeline_viewport.dart`
  - `packages/danaview_editor/lib/src/editor/timeline/ruler.dart`
  - `packages/danaview_editor/lib/src/editor/timeline/timeline_metrics.dart`
  - `packages/danaview_editor/lib/src/editor/timeline/timeline_style.dart`
  - `packages/danaview_editor/test/timeline/viewport/`
- **Spec:** ux.md §8.4-8.5, §6.8: TimelineViewportController (zoom from 'whole project + margin' to 48 px per frame, anchor at focal point or playhead when centre-locked, bounds, fling physics, centre-locked mode default on touch and free mode for pointers, scroll offset persisted to ViewState), timeline_metrics (lane heights by kind and text scale, header widths, x<->time conversions), Ruler painter (tick ladder by zoom, timecode labels via Timecode, marker flags painted from the snapshot), timeline_style (editor colour tokens derived from DanaviewColors with computed foreground contrast).
- **Acceptance criteria and tests:** unit tests for zoom-anchor invariance, bounds, centre-locked/free modes, fling; ladder spacing tests at every zoom; ruler golden (Ahem, DPR 1 and 3).

#### UX-10 · Timeline snapshot, RenderTimelineCanvas painting, hit testing, playhead layer

- **Milestone:** M3 · **Area:** UI/UX
- **Depends on:** UX-08, UX-09
- **Owns:**
  - `packages/danaview_editor/lib/src/editor/timeline/timeline_snapshot.dart`
  - `packages/danaview_editor/lib/src/editor/timeline/render_timeline_canvas.dart`
  - `packages/danaview_editor/lib/src/editor/timeline/timeline_hit.dart`
  - `packages/danaview_editor/lib/src/editor/timeline/playhead_layer.dart`
  - `packages/danaview_editor/lib/src/editor/caches/paragraph_cache.dart`
  - `packages/danaview_editor/test/timeline/canvas/`
- **Spec:** ARCH §17.4, ux.md §8.2, §8.6-8.7: TimelineSnapshotBuilder reusing LaneModel/ItemModel when domain objects are identical; RenderTimelineCanvas (RenderBox, repaint boundary) painting only the visible window via binary search per lane: clips (video/image/audio/text/cue styles, labels, speed/reverse/freeze/offline/pending badges), thumbnail strips and waveforms through cache interfaces (UX-20/UX-21 fill them), selection, keyframe diamonds of the selected item, transition '+'/bowtie markers, fades, volume line, gaps, locked/hidden lane shading; hitTestTimeline returning typed hits (clip body, trim edges, keyframe, transition, marker, fade handle, lane background, playhead knob); PlayheadLayer as a separate repaint layer driven by a ValueListenable; ParagraphCache (512 entries). The canvas paints through `TimelineTiles` from timeline/timeline_tiles.dart (UX-01 placeholder: disabled pass-through) so UX-43 can enable tiling without editing this file.
- **Acceptance criteria and tests:** identity-reuse tests; instrumented paint count proves only visible items paint; golden tests at four zooms with every item kind and state; hit-test unit tests for every hit type; semantics nodes per visible item.

#### UX-11 · Track headers, track menu and lane flags

- **Milestone:** M3 · **Area:** UI/UX
- **Depends on:** UX-10, CORE-17
- **Owns:**
  - `packages/danaview_editor/lib/src/editor/timeline/track_headers.dart`
  - `packages/danaview_editor/lib/src/editor/timeline/track_menu_sheet.dart`
  - `packages/danaview_editor/lib/src/editor/actions/bindings/track_bindings.dart`
  - `packages/danaview_editor/lib/src/app/strings/track_strings.dart`
  - `packages/danaview_editor/test/timeline/tracks/`
- **Spec:** ux.md §8.10: compact and expanded headers per lane kind (video main/extra, overlay, text, subtitle, audio with role) with lock, visibility, mute, solo toggles (toggled: semantics), rename, reorder within band, add track (per kind), delete track with confirm (main protected), audio role; track menu sheet (showDanaviewSheet) with the same plus subtitle-track actions slots used by UX-31/UX-38 (Regenerate) through action ids.
- **Acceptance criteria and tests:** widget tests per kind and flag; commands dispatched match CORE-17 commands; matrix tests; semantics toggles.

#### UX-12 · Timeline view, gesture arbiter, semantics

- **Milestone:** M3 · **Area:** UI/UX
- **Depends on:** UX-10
- **Owns:**
  - `packages/danaview_editor/lib/src/editor/timeline/timeline_view.dart`
  - `packages/danaview_editor/lib/src/editor/timeline/timeline_gestures.dart`
  - `packages/danaview_editor/lib/src/editor/timeline/timeline_semantics.dart`
  - `packages/danaview_editor/test/timeline/gestures/`
- **Spec:** ARCH §17.4, ux.md §8.8: TimelineView composing headers, ruler, canvas, interaction layer slot (UX-13) and playhead layer; TimelineGestureArbiter by hit type: eager handle drags (trim, keyframe, playhead knob, marker), pointer drag of selected items, long-press lift on touch and context menu, tap select (Shift/Cmd toggles, multi-select mode on touch), scale recognizer with axis-locked pan, horizontal pinch zoom anchored at the focal point, fling, marquee on mouse, secondary-click menus, hover cursors, trackpad pan/zoom; centre-locked scrolling scrubs the playhead; timeline_semantics: custom actions on clips (split, delete, move/trim by frame and second), playhead as adjustable slider, markers/transitions/keyframes as nodes; announcements via editorAnnounce throttled to 1/s (V-U4).
- **Acceptance criteria and tests:** arbitration tests for each hit type including scroll-over-clips on touch; pinch anchoring; axis lock; marquee; context menus; semantics actions invoke the right commands; **touch multi-select mode** adds and removes items with taps and exits on Done/Esc; **long-press lifts** a clip and moves it with a ghost equal to the dryRun placement, committing one history entry; **mouse wheel** scrolls lanes vertically, **Shift+wheel** scrolls time, **Ctrl/⌘+wheel** zooms anchored at the cursor; V-U4 recorded: announcements reach VoiceOver/TalkBack through editorAnnounce on 3.44 (test with SemanticsService mock plus a manual check noted in the PR).

#### UX-13 · Move, trim, split, delete, ripple, snapping UI, clipboard

- **Milestone:** M3 · **Area:** UI/UX
- **Depends on:** UX-12, CORE-11, CORE-18
- **Owns:**
  - `packages/danaview_editor/lib/src/editor/timeline/timeline_interaction.dart`
  - `packages/danaview_editor/lib/src/editor/timeline/snapping.dart`
  - `packages/danaview_editor/lib/src/editor/state/editor_clipboard.dart`
  - `packages/danaview_editor/lib/src/editor/actions/bindings/edit_bindings.dart`
  - `packages/danaview_editor/lib/src/app/strings/edit_strings.dart`
  - `packages/danaview_editor/test/timeline/interaction/`
- **Spec:** ux.md §8.9, §14.4: drag ghosts rendered from dryRun placements on every pointer move (<= 2 ms), commit through EditorController.apply; trim handles (touch-sized), split at playhead or tapped position (S / split tool), delete vs ripple delete vs delete gap, move across lanes (new lane per D-11), keyframe diamond drag and marker drag (snapping), cue edge drags, fade handle drags; snapping UI over core SnapIndex (8 px pointer / 12 px touch, guide line, haptic on engage, Alt disables, toggle N); auto-scroll at edges; ripple toggle R; clipboard (copy, cut = copy + delete (D-16), paste at playhead on the nearest compatible lane, duplicate) with in-app payloads; each operation is one history entry. Bindings for split, delete, rippleDelete, deleteGap, copy, cut, paste, duplicate, selectAll, escape, multiSelect, moveToTrack, toggleSnapping, toggleRipple.
- **Acceptance criteria and tests:** widget tests driving gestures for move/trim/split/delete/ripple/paste with fake engine; ghost equals final placement; snapping engage/disengage; one history entry per gesture; auto-scroll.

#### UX-14 · Playhead controller, transport controller and transport bar

- **Milestone:** M3 · **Area:** UI/UX
- **Depends on:** UX-08
- **Owns:**
  - `packages/danaview_editor/lib/src/editor/state/playhead_controller.dart`
  - `packages/danaview_editor/lib/src/editor/state/transport_controller.dart`
  - `packages/danaview_editor/lib/src/editor/transport/`
  - `packages/danaview_editor/lib/src/editor/actions/bindings/playback_bindings.dart`
  - `packages/danaview_editor/test/transport/`
- **Spec:** ARCH §17.3 and ux.md §7.6, §7.8: PlayheadController (ValueListenable<TimeUs> outside Riverpod; extrapolates PreviewClock samples per vsync, notifies only on frame change, drops stale seq, coalesces scrub seeks with <= 1 in flight, sends exact seek on release and adopts SeekAck.displayedFrameTime, quantized to project fps); TransportController (play/pause, loop range, frame step with key repeat, ±1 s, previous/next edit point and marker, start/end); transport bar (play/pause, frame step, current time / duration TimecodeText that is the only per-frame rebuild, timecode entry with Timecode.parse, fullscreen button, quality menu slot). Bindings: playPause (Space/K), prevFrame/nextFrame, back1s/forward1s, prevEdit/nextEdit, goStart/goEnd, fullscreenPreview.
- **Acceptance criteria and tests:** extrapolation and scrub coalescing unit tests with a fake clock; seq rules; rebuild-budget test (120 clock samples -> only TimecodeText rebuilds); timecode entry parse; edit-point jumps include markers.

#### UX-15 · Action registry, keyboard shortcuts, shortcuts sheet

- **Milestone:** M3 · **Area:** UI/UX
- **Depends on:** UX-08
- **Owns:**
  - `packages/danaview_editor/lib/src/editor/actions/editor_action_registry.dart`
  - `packages/danaview_editor/lib/src/editor/actions/editor_shortcuts.dart`
  - `packages/danaview_editor/lib/src/editor/actions/shortcuts_sheet.dart`
  - `packages/danaview_editor/test/actions/`
- **Spec:** ARCH §17.6: EditorActionRegistry (ActionSpec per EditorActionId: label, icon, shortcut, enabled/visible predicates, disabled reason, handler from wiring/action_bindings.dart) feeding tool tiles, context menus, keyboard shortcuts, semantics custom actions and the shortcuts sheet; EditorShortcuts (Shortcuts/Actions with Cmd on Apple and Ctrl elsewhere: Space/K, arrows, Shift+arrows, Up/Down, Home/End, S, Delete/Backspace, Shift+Delete, Cmd+Z, Cmd+Shift+Z and Ctrl+Y off Apple, Cmd+S (works in text fields), Cmd+C/X/V/D, Cmd+A, Esc chain, M, N, R, Cmd+=/Cmd+-/Shift+Z, F, Cmd+/ or ?); focus guard disabling non-text-safe actions while an EditableText has focus; ShortcutsSheet generated from the registry. The editor-level Shortcuts scope overrides Flutter's defaults outside EditableText: Space/Enter -> playPause instead of ActivateIntent, arrow keys -> frame/edit-point navigation instead of DirectionalFocusIntent (ARCH §17.6); V-U5 recorded on the iPad Pro simulator with a hardware keyboard.
- **Acceptance criteria and tests:** every binding tested on iOS-, Android- and macOS-targeted platforms (debugDefaultTargetPlatformOverride); **after tapping a tool tile** (so it holds focus) Space toggles playback and does not press the tile, and ←/→ step one frame instead of moving focus; inside a text field Space/arrows edit text and ⌘S still saves; focus guard tests; sheet lists exactly the registry; disabled actions explain why; V-U5 result recorded (certified on the iPad simulator by QA-00 scenario 12 in QA-01).

#### UX-16 · Tool strip/rail, context tool sets, inspector host and dock

- **Milestone:** M3 · **Area:** UI/UX
- **Depends on:** UX-07, UX-15, CORE-05
- **Owns:**
  - `packages/danaview_editor/lib/src/editor/toolbar/`
  - `packages/danaview_editor/lib/src/editor/inspector/inspector_host.dart`
  - `packages/danaview_editor/lib/src/editor/inspector/inspector_dock.dart`
  - `packages/danaview_editor/lib/src/editor/inspector/inspector_header.dart`
  - `packages/danaview_editor/lib/src/editor/inspector/inspector_rows.dart`
  - `packages/danaview_editor/lib/src/editor/inspector/keyframe_toggle.dart`
  - `packages/danaview_editor/lib/src/editor/inspector/color_field.dart`
  - `packages/danaview_editor/test/toolbar/`
  - `packages/danaview_editor/test/inspector/`
- **Spec:** ux.md §9: bottom tool strip (compact) or side rail with tool tabs; top-level tools when nothing is selected (Media, Audio, Text, Captions, Overlay, Effects, Filters, Transitions, Format) and ToolSets.forSelection(selection, project) context tools (ARCH §17.7) driven by the registry; disabled tiles explain themselves; InspectorHost mapping InspectorRoute -> panel widgets (imports the panel placeholders created by UX-01; panel tickets replace them), DanaviewDockedPanel dock (default/expanded) in compactPortrait and side pane elsewhere, re-targeting on selection change; inspector_rows generated from PropertyKey metadata (slider-like custom rows with DanaviewNumberField, reset, KeyframeToggle states of ux.md §9.4), ColorField over DanaviewColorPicker.
- **Acceptance criteria and tests:** table-driven test of tool sets per selection kind; dock and side pane per layout; re-targeting; rows from metadata; keyframe toggle states; matrix tests.

#### UX-17 · Markers sheet and marker actions

- **Milestone:** M3 · **Area:** UI/UX
- **Depends on:** UX-13, UX-14, CORE-17
- **Owns:**
  - `packages/danaview_editor/lib/src/editor/timeline/marker_sheet.dart`
  - `packages/danaview_editor/lib/src/editor/actions/bindings/marker_bindings.dart`
  - `packages/danaview_editor/test/timeline/markers/`
- **Spec:** Add marker at playhead (M), edit sheet (name, colour index, note), delete, list of markers with jump; markers are snap targets (UX-13 drag) and part of edit-point navigation (UX-14); semantics nodes.
- **Acceptance criteria and tests:** widget tests for add/edit/delete/jump; marker commands dispatched; matrix tests.

#### UX-18 · Preview region, preview surface, status overlays, fullscreen preview, quality

- **Milestone:** M3 · **Area:** UI/UX
- **Depends on:** UX-07, UX-14
- **Owns:**
  - `packages/danaview_editor/lib/src/editor/preview/preview_region.dart`
  - `packages/danaview_editor/lib/src/editor/preview/preview_surface.dart`
  - `packages/danaview_editor/lib/src/editor/preview/fullscreen_preview.dart`
  - `packages/danaview_editor/lib/src/editor/preview/preview_status.dart`
  - `packages/danaview_editor/test/preview/surface/`
- **Spec:** ARCH §17.5, ux.md §7.1, §7.7: PreviewSurface (black -> AspectRatio(canvas) -> Texture(textureId)), status overlays (starting, failed with 'Restart preview', offline media card with 'Relink…', degraded badge, pending jobs), quality menu (auto/full/half/quarter) and proxies toggle, fullscreen preview route reusing the same texture id and overlays (fallback: move the single widget if V-U2 fails), refresh after resume, surface-lost recovery, wakelock while playing; touch preview controls (tap to play/pause, double-tap seek ±1 s when no item is targeted). Owner decision 2026-10-11 (D-43(e) point 2): the quality menu's Auto is the adaptive mode (full → 1/2 → 1/4 and back, current step shown in the degraded badge); Full / 1/2 / 1/4 pin the quality; the proxies toggle shows the tier default (Always on minimal/low, D-43(e) point 1).
- **Acceptance criteria and tests:** widget tests with FakeEditorEngine for every status; **touch preview controls**: tap toggles play/pause and double-tap seeks ±1 s (left/right half) only when no item is under the finger (with an item under the finger the tap selects it); fullscreen enter/exit keeps playback state; V-U2 verified on simulator/emulator (documented in the PR). **Amended 2026-10-11:** Auto shows the current adaptive step on `degraded(q)` and clears it on `recovered`; a pinned quality is sent with `setQuality` and persists for the session.

#### UX-19 · Text and subtitle overlay layer for preview

- **Milestone:** M3 · **Area:** UI/UX
- **Depends on:** UX-18, API-04, CORE-07
- **Owns:**
  - `packages/danaview_editor/lib/src/editor/preview/text_overlay_layer.dart`
  - `packages/danaview_editor/lib/src/editor/preview/text_overlay_painter.dart`
  - `packages/danaview_editor/test/preview/text_overlay/`
- **Spec:** D-05 and ARCH §13.1: TextOverlayLayer paints active text items and subtitle cues above the Texture, letterboxed with CanvasGeometry, using API-04 TextLayoutEngine, textLayoutSpecOf/cueLayoutSpecOf and evaluateTextAnimation at PlayheadController.value (repaint only on frame change); burn-in-off subtitle tracks still preview; hidden tracks skipped; same overlay hosted by fullscreen preview.
- **Acceptance criteria and tests:** golden tests of text styles/animations at key times matching API-04 sprite rasterization within 1 px; per-frame cost <= 1 ms for 10 visible items (profile test); no rebuilds of the editor scaffold during playback.

#### UX-20 · Thumbnail cache and strip painting

- **Milestone:** M3 · **Area:** UI/UX
- **Depends on:** UX-10
- **Owns:**
  - `packages/danaview_editor/lib/src/editor/caches/thumbnail_cache.dart`
  - `packages/danaview_editor/test/caches/thumbnails/`
- **Spec:** ARCH §17.4, ux.md §17.3: ThumbnailCache over engine.thumbnails: priority queue (visible > overscan), cancel when scrolled away, deferral during fast fling, JPEG strip -> ui.Image decode, LRU 48/96 MB by tier, trim to 25% on memory pressure, proxy vs original choice, painting hook used by RenderTimelineCanvas.
- **Acceptance criteria and tests:** unit tests with the fake engine for priority, cancel, fling deferral, budget and trim; golden with fake tiles.

#### UX-21 · Waveform cache and painting

- **Milestone:** M3 · **Area:** UI/UX
- **Depends on:** UX-10
- **Owns:**
  - `packages/danaview_editor/lib/src/editor/caches/waveform_cache.dart`
  - `packages/danaview_editor/test/caches/waveforms/`
- **Spec:** ux.md §17.4: WaveformCache over engine.waveforms: peaks -> mip pyramid built in Isolate.run, level selection by zoom, mapping through speed and reverse, volume-envelope line, LRU 24 MB, painting hook for audio lanes and video clips with audio.
- **Acceptance criteria and tests:** pyramid and level-selection unit tests; speed/reverse mapping tests; golden.

#### UX-22 · Canvas geometry, manipulation overlay (move/scale/rotate), snap guides

- **Milestone:** M3 · **Area:** UI/UX
- **Depends on:** UX-18, CORE-13, CORE-32
- **Owns:**
  - `packages/danaview_editor/lib/src/editor/preview/canvas_geometry.dart`
  - `packages/danaview_editor/lib/src/editor/preview/manipulation_overlay.dart`
  - `packages/danaview_editor/lib/src/editor/preview/manipulation_painter.dart`
  - `packages/danaview_editor/lib/src/editor/preview/snap_guides.dart`
  - `packages/danaview_editor/test/preview/manipulation/`
- **Spec:** ux.md §7.2-7.4: CanvasGeometry (letterbox mapping view <-> canvas, uses core geometry); ManipulationOverlay with one ScaleGestureRecognizer for move/pinch/rotate (incl. trackpad pan-zoom), corner and rotate handles, targets clips, overlays, text items and subtitle tracks (custom Y position), snapping to centre/edges/safe margins with guides, keyframe-aware writes at the playhead via SetProperty, EditTransaction with transients <= 1 per frame and one history entry per gesture, handles kept inside the view, semantics actions for move/scale/rotate.
- **Acceptance criteria and tests:** gesture tests for every row of ux.md §7.3; transient rate; one entry per gesture; keyframe-aware writes; golden of handles.

### M4: Editing features and native export

#### ENG-04 · Dart glue: export service and job reattach

- **Milestone:** M4 · **Area:** Engine (Dart)
- **Depends on:** ENG-06
- **Owns:**
  - `packages/danaview_editor_engine/lib/src/mobile_export.dart`
  - `packages/danaview_editor_engine/test/export/`
- **Spec:** MobileExportService implements ExportService: preflight(plan, encode) (warnings: software encoder, HEVC unavailable, background pauses, layers vs resolution, portrait size refused), start(plan, encode, outputPath, title, whenDetached) -> ExportJob (progress stream <= 4 Hz with phase, frames, backgrounded/pausedInBackground, warnings; result ExportResult; cancel), resume(jobId) for iOS segment-resumable jobs, activeJobs() reattaching running jobs after a hot restart or app relaunch and reporting one-shot `interrupted`, `resumable(jobId, doneFraction)` and `completedWhileDetached(result, savedToGallery)` records (consumed with consumeJobRecord; D-22, D-39).
- **Acceptance criteria and tests:** mocked-channel tests for progress mapping, cancel, failure codes, reattach, interrupted, resumable and completed-while-detached reporting (each reported exactly once); contract kit export section passes.

#### IOS-12 · iOS export pipeline: reader/writer, encoder settings, coordinator

- **Milestone:** M4 · **Area:** iOS native
- **Depends on:** IOS-10, ENG-04, IOS-11, IOS-17, IOS-18
- **Owns:**
  - `packages/danaview_editor_engine/ios/Classes/Export/ExportJob.swift`
  - `packages/danaview_editor_engine/ios/Classes/Export/ReaderWriterPipeline.swift`
  - `packages/danaview_editor_engine/ios/Classes/Export/EncoderSettings.swift`
  - `packages/danaview_editor_engine/ios/Classes/Export/ExportCoordinator.swift`
  - `packages/danaview_editor_engine/example/ios/RunnerTests/Export/`
- **Spec:** ARCH §14.2: AVAssetReader(composition) with AVAssetReaderVideoCompositionOutput (export variant) and — only when plan.audio is non-empty — AVAssetReaderAudioMixOutput (LPCM Float32 48 kHz stereo, .timeDomain for keep-pitch (not .spectral, ARCH §13.2/§14.2, V-N21), IOS-18 gain taps); with no audio segments the audio pump writes silent LPCM across [0, durUs) and never constructs a mix output over zero tracks (D-38); samples clamped to [−1, 1] before the AAC input; video written through IOS-17's SegmentedWriter (10 s closed-GOP segments + checkpoint, concat at the end) feeding AVAssetWriter (.mp4 or .mov, shouldOptimizeForNetworkUse) with H.264 High AutoLevel or HEVC Main AutoLevel (hvc1), AverageBitRate, ExpectedSourceFrameRate, MaxKeyFrameIntervalDuration, BT.709 colour, AAC-LC 48 kHz stereo; no location metadata; serial pump queues with requestMediaDataWhenReady; progress = last video PTS / duration; preflight (software encoder, HEVC availability at size with the pre-17.4 path of IOS-02, layer count vs resolution, free space incl. one segment); on encoderSizeLimit or a refused portrait size, one retry with a landscape-encoded buffer and preferredTransform rotation, then encoderSizeLimit (ARCH §14.1); cancel deletes the partial file and all segments; thermal critical pauses pumps; ExportCoordinator owns jobs (one at a time) and suspends preview on minimal/low/mid tiers through IOS-11's PreviewSessionManager. Preflight never refuses for layer counts (owner decision 2026-10-11, D-43(e) point 7): when a composition track cannot get a decoder (`decoderInitFailed`) or the plan needs more decoders than the device sustains, `ExportCoordinator` hands the job to a multi-pass hook (interface in IOS-12's coordinator, implemented by IOS-20, D-45) instead of failing.
- **Acceptance criteria and tests:** MP4 and MOV, H.264 (simulator) and HEVC (device) outputs pass conformance checks (container, codec tag, size, fps, frame count ±1, AAC 48 kHz stereo, bitrate ±25%); **conformance fixtures with no audio, with every clip muted or soloed out, and with images/text only** each produce a silent AAC 48 kHz stereo track and never crash; an export plan with gridFps 30 and fps 24 passes; A/V offset <= 1 frame and <= 20 ms on clap_flash; 200% volume measures +6.02 ± 0.1 dB in the output; cancel cleans up; encoder failures map to encoderUnavailable/encoderSizeLimit; the portrait retry path is exercised with an injected refusal. **Amended 2026-10-11 (D-45):** an injected `decoderInitFailed` routes the job to the multi-pass hook (test double until IOS-20 lands) and is never reported as an export failure.

#### IOS-14 · iOS voice recorder

- **Milestone:** M4 · **Area:** iOS native
- **Depends on:** ENG-03
- **Owns:**
  - `packages/danaview_editor_engine/ios/Classes/Recording/VoiceRecorder.swift`
  - `packages/danaview_editor_engine/example/ios/RunnerTests/Recording/`
- **Spec:** ARCH §15 'Voice recording', D-25: AVAudioEngine input tap -> WAV PCM s16 48 kHz mono at the Dart path, levels at 20 Hz, start latency reported, session .playAndRecord + .defaultToSpeaker + Bluetooth HFP, interruptions/route changes stop and keep the file, permission via AVAudioApplication.requestRecordPermission (17+) / AVAudioSession (15-16), openSettings; preview playback muted while recording; previous audio session restored.
- **Acceptance criteria and tests:** WAV format verified; levels stream; interruption keeps a valid file; permission flows on the iPhone 8 lab device (iOS 16.7, AVAudioSession path) and on an iOS 18+ simulator (AVAudioApplication path) — no iOS 15/16 simulator runtimes exist for Xcode 26.6 (D-41); latency value plausible (< 100 ms on device).

#### IOS-15 · iOS pickers, media access (bookmarks), permissions, background guard

- **Milestone:** M4 · **Area:** iOS native
- **Depends on:** ENG-03
- **Owns:**
  - `packages/danaview_editor_engine/ios/Classes/Platform/MediaPicker.swift`
  - `packages/danaview_editor_engine/ios/Classes/Platform/MediaAccess.swift`
  - `packages/danaview_editor_engine/ios/Classes/Platform/Permissions.swift`
  - `packages/danaview_editor_engine/ios/Classes/Platform/BackgroundGuard.swift`
  - `packages/danaview_editor_engine/example/ios/RunnerTests/Platform/`
- **Spec:** PHPickerViewController (preferredAssetRepresentationMode .current, multi-select, video/image filters; inside NSItemProvider.loadFileRepresentation's completion handler — before it returns, because the system then deletes the file — the temp file is cloned with clonefile (copy fallback) into <cache>/danaview/editor/work/picks/<uuid>/<name> and that path is returned with isTemporaryCopy = true; Dart hashes and moves it into media/, ARCH §9.1) and UIDocumentPickerViewController (asCopy false; video, audio, image, .cube via public.data + extension check, srt/vtt) returning PickedMedia with bookmarks for Files; MediaAccess: createBookmark/resolveBookmark (stale refresh), refcounted startAccessingSecurityScopedResource, stat, quickHash (same algorithm as core, streamed read), excludeFromBackup (NSURLIsExcludedFromBackupKey), remainingGrantBudget (unbounded on iOS); Permissions (notifications N/A, microphone status); BackgroundGuard: beginBackgroundTask lease with pause semantics. No NSPhotoLibraryUsageDescription needed.
- **Acceptance criteria and tests:** HEVC pick without transcode (.current); the returned work/picks file still exists after the completion handler returned and a 1 s delay; bookmark survives app relaunch (V-D3, re-verified in QA-10); excluded-from-backup flag set on a directory and readable back (V-D4); quickHash equals core fixtures; lease begin/end/expiry events.

#### IOS-16 · iOS external drop target

- **Milestone:** M4 · **Area:** iOS native
- **Depends on:** ENG-03
- **Owns:**
  - `packages/danaview_editor_engine/ios/Classes/Platform/DropTarget.swift`
  - `packages/danaview_editor_engine/example/ios/RunnerTests/Drop/`
- **Spec:** D-18: UIDropInteraction on the Flutter view when enabled by setDropTargetEnabled; accepts movie, audio, image and .cube items; NSItemProvider.loadFileRepresentation -> temp copy in <cache>/danaview/editor/work/drops/ -> ExternalDrop events {items (uri, name, isTemporaryCopy true), logical position}; disabled outside the editor.
- **Acceptance criteria and tests:** unit tests drive the drop delegate with synthesized UIDropSession/NSItemProvider objects (movie, audio, image, .cube, unsupported) and assert items, temp copies and logical positions; disabling removes the interaction; temp copies are cleaned by Dart after import; a cross-app drag from Files/Photos on the iPad simulator is a manual checklist item with recorded evidence (repeated in QA-01).

#### AND-11 · Android export: coordinator, Transformer, encoder settings, hardware selector, active store

- **Milestone:** M4 · **Area:** Android native
- **Depends on:** AND-09, ENG-04, AND-08, AND-10
- **Owns:**
  - `packages/danaview_editor_engine/android/src/main/kotlin/com/vecvel/danaview/editor/engine/export/ExportCoordinator.kt`
  - `packages/danaview_editor_engine/android/src/main/kotlin/com/vecvel/danaview/editor/engine/export/TransformerExport.kt`
  - `packages/danaview_editor_engine/android/src/main/kotlin/com/vecvel/danaview/editor/engine/export/EncoderSettings.kt`
  - `packages/danaview_editor_engine/android/src/main/kotlin/com/vecvel/danaview/editor/engine/export/HardwareEncoderSelector.kt`
  - `packages/danaview_editor_engine/android/src/main/kotlin/com/vecvel/danaview/editor/engine/export/ActiveExportStore.kt`
  - `packages/danaview_editor_engine/android/src/test/kotlin/com/vecvel/danaview/editor/engine/export/`
  - `packages/danaview_editor_engine/android/src/androidTest/kotlin/com/vecvel/danaview/editor/engine/export/`
- **Spec:** ARCH §14.3: process-scoped ExportCoordinator owning one Transformer per job on the danaview-export looper (setVideoMimeType H264|H265, AAC, DefaultEncoderFactory with HardwareEncoderSelector hardware-first, requested bitrate and I-frame interval, setEnableFallback(true) with onFallbackApplied -> warning, InAppMp4Muxer.Factory().setAttemptStreamableOutputEnabled(true), ORIGINAL working colour space, setPortraitEncodingEnabled(true)); export composition from the AND-08 mapper with target export (export size, clock band at export fps with trackTypes {VIDEO, AUDIO} so a silent AAC track always exists, gridFps edges, originals, SpriteBandEffect sequences); on a refused portrait size, one retry with a landscape-encoded buffer and rotation metadata, then encoderSizeLimit (ARCH §14.1); progress via getProgress every 250 ms; ExportException codes mapped to EngineErrorCode; preflight; cancel deletes partial output; ActiveExportStore for reattach, one-shot interrupted after process death and completedWhileDetached records (written by AND-12's service, D-39); preview suspended on minimal/low/mid tiers through AND-10's PreviewSessionManager. Preflight never refuses for sequence or layer counts (owner decision 2026-10-11, D-43(e) point 7): when the packed export plan needs more decoders than the device allows, `ExportCoordinator` hands the job to a multi-pass hook (`MultiPassExport` interface in AND-11's coordinator, implemented by AND-19, D-45) instead of failing.
- **Acceptance criteria and tests:** MP4 H.264/HEVC conformance incl. hvc1 tag (V-N13) on emulator/device; **no-audio, all-muted and images/text-only fixtures produce a silent AAC 48 kHz stereo track (V-N24)**; an export plan with gridFps 30 and fps 24 passes; hardware encoder preferred and software flagged; A/V offset <= 1 frame and <= 20 ms; the portrait retry path is exercised with an injected refusal; error mapping tests; interrupted after process kill. **Amended 2026-10-11 (D-45):** a plan above `maxVisualSequences` is never refused by preflight and is routed to the multi-pass hook (test double until AND-19 lands).

#### AND-13 · Android voice recorder

- **Milestone:** M4 · **Area:** Android native
- **Depends on:** ENG-03
- **Owns:**
  - `packages/danaview_editor_engine/android/src/main/kotlin/com/vecvel/danaview/editor/engine/recording/VoiceRecorder.kt`
  - `packages/danaview_editor_engine/android/src/androidTest/kotlin/com/vecvel/danaview/editor/engine/recording/`
- **Spec:** D-25: AudioRecord(MIC, 48 kHz, mono, 16-bit) on its own thread writing WAV at the Dart path, levels 20 Hz, start latency from AudioRecord.getTimestamp, RECORD_AUDIO runtime permission flow (rationale handled in Dart), device removal or audio-focus loss stops and keeps the file, preview playback muted while recording.
- **Acceptance criteria and tests:** WAV format verified; interruption keeps a valid file; permission denied/permanently denied states; latency reported.

#### AND-14 · Android pickers, URI grants (media access), permissions

- **Milestone:** M4 · **Area:** Android native
- **Depends on:** ENG-03
- **Owns:**
  - `packages/danaview_editor_engine/android/src/main/kotlin/com/vecvel/danaview/editor/engine/platform/MediaPicker.kt`
  - `packages/danaview_editor_engine/android/src/main/kotlin/com/vecvel/danaview/editor/engine/platform/MediaAccess.kt`
  - `packages/danaview_editor_engine/android/src/main/kotlin/com/vecvel/danaview/editor/engine/platform/Permissions.kt`
  - `packages/danaview_editor_engine/android/src/androidTest/kotlin/com/vecvel/danaview/editor/engine/platform/`
- **Spec:** Photo Picker PickMultipleVisualMedia (fallback documented for devices without it) and SAF OpenMultipleDocuments for audio, LUT and subtitles, via the plugin's ActivityResult wiring; MediaAccess: takePersistableUriPermission(READ)/release, remainingGrantBudget (persistedUriPermissions count vs 512 on API 30+ / 128 before), ContentResolver stat and streamed quickHash (core algorithm), excludeFromBackup no-op (rules are in CORE-28), notifications permission request; read-only access to originals.
- **Acceptance criteria and tests:** V-D2: Photo Picker URIs persist across relaunch (or the managed-copy fallback is selected), grant budget computed; quickHash equals core fixtures; permission flows on API 33+.

#### AND-15 · Android external drop target

- **Milestone:** M4 · **Area:** Android native
- **Depends on:** ENG-03
- **Owns:**
  - `packages/danaview_editor_engine/android/src/main/kotlin/com/vecvel/danaview/editor/engine/platform/DropTarget.kt`
  - `packages/danaview_editor_engine/android/src/androidTest/kotlin/com/vecvel/danaview/editor/engine/drop/`
- **Spec:** D-18: View.setOnDragListener on the FlutterView when enabled, Activity.requestDragAndDropPermissions, accepted MIME types video/*, audio/*, image/*, .cube; URIs copied into <cache>/danaview/editor/work/drops/ while permissions are held; ExternalDrop events with logical positions; disabled outside the editor.
- **Acceptance criteria and tests:** instrumented tests dispatch synthesized DragEvents (ACTION_DRAG_STARTED/ENTERED/DROP with ClipData of video, audio, image, .cube and unsupported URIs from a test ContentProvider) and assert items, copies and positions; permissions released after copy; disable works; a cross-app drag from Files on a tablet emulator is a manual checklist item with recorded evidence (repeated in QA-02).

#### AI-13 · Transcription orchestrator (TranscriptionServiceImpl) and resource governor

- **Milestone:** M4 · **Area:** AI (whisper + transcription)
- **Depends on:** AI-07, AI-09, AI-10, AI-11, AI-12, CORE-15
- **Owns:**
  - `packages/danaview_transcription/lib/src/pipeline/`
  - `packages/danaview_transcription/lib/src/governor/`
  - `packages/danaview_transcription/test/pipeline/`
- **Spec:** ARCH §16.4-16.5: TranscriptionServiceImpl implementing every D-21 method: offers (tiers by RAM, availability per platform/ABI), preflight (model present?, free space, memory >= 1.3 × tier peak), start (plan -> cache lookup -> consent/download -> model load -> extract units through the SpeechAudioExtractor port with pipeline depth 1 -> language (explicit, or DETECT on <= 30 s of speech: top-1 p >= 0.6 else needsLanguage with top 3) -> ~180 s chunks cut at the quietest RMS point ±15 s with VAD -> checkpoints -> normalize -> transcript file -> map -> segment), resegment (instant re-split from cached transcripts), activeJob, resumableFor (job records), provideLanguage, cancel; result = AddGeneratedCaptionTrack or ReplaceGeneratedCaptions command + CaptionProvenance (applied by the UI as one history entry). ResourceGovernor: threads = clamp(perf cores, 2, 4), halved at thermal serious (+2 s cooldown), paused at critical, low-power -1; waits while an export runs and pauses at a chunk boundary when one starts; iOS background -> pause (abort current chunk, V-A3), Android -> keep running under a BackgroundLeaseProvider lease; leaving the editor cancels and keeps the checkpoint. Logs never contain transcript text or paths (grep test).
- **Acceptance criteria and tests:** orchestration tests with fakes for every phase, failure kind, cancel point and resume path; deterministic results for a fixture transcript; on-device 60 s English Balanced run recorded (QA-06/QA-07 extend).

#### UX-23 · Transform, crop and mask panels; crop, mask and eyedropper preview modes

- **Milestone:** M4 · **Area:** UI/UX
- **Depends on:** UX-22, UX-16
- **Owns:**
  - `packages/danaview_editor/lib/src/editor/panels/transform_panel.dart`
  - `packages/danaview_editor/lib/src/editor/panels/crop_panel.dart`
  - `packages/danaview_editor/lib/src/editor/panels/mask_panel.dart`
  - `packages/danaview_editor/lib/src/editor/preview/crop_overlay.dart`
  - `packages/danaview_editor/lib/src/editor/preview/mask_overlay.dart`
  - `packages/danaview_editor/lib/src/editor/preview/eyedropper_overlay.dart`
  - `packages/danaview_editor/lib/src/editor/actions/bindings/transform_bindings.dart`
  - `packages/danaview_editor/lib/src/app/strings/transform_strings.dart`
  - `packages/danaview_editor/test/panels/transform/`
- **Spec:** ux.md §10.2, §10.10, §7.5: Transform panel (position X/Y, scale, rotation, flip H/V, opacity, fit mode, reset transform; keyframe toggles), Crop mode (setEditingMode(cropSource(item)), aspect presets free/original/16:9/9:16/1:1/4:5, drag edges, rotate 90°, reset), Mask panel + overlay (none/rectangle/circle(ellipse), centre, size, rotation, corner radius, feather, opacity, invert; on-preview handles), Eyedropper overlay (sampleColor throttled to 15 Hz, magnifier, returns colour to the caller: chroma panel, colour fields). Every commit labelled; continuous edits via EditTransaction.
- **Acceptance criteria and tests:** widget tests for each control dispatching the right core commands; crop presets; mask handles; eyedropper throttling with the fake engine; matrix tests.

#### UX-24 · Adjust and Filters/LUT panels, built-in looks

- **Milestone:** M4 · **Area:** UI/UX
- **Depends on:** UX-16, CORE-13, CORE-21, CORE-27
- **Owns:**
  - `packages/danaview_editor/lib/src/editor/panels/adjust_panel.dart`
  - `packages/danaview_editor/lib/src/editor/panels/filters_panel.dart`
  - `packages/danaview_editor/assets/looks/`
  - `packages/danaview_editor/tool/gen_looks.dart`
  - `packages/danaview_editor/lib/src/editor/actions/bindings/color_bindings.dart`
  - `packages/danaview_editor/lib/src/app/strings/color_strings.dart`
  - `packages/danaview_editor/test/panels/color/`
- **Spec:** ux.md §10.6-10.7, ARCH §6.5 and §10.2: Adjust panel with Light (exposure, brightness, contrast, highlights, shadows), Color (saturation, temperature, tint), Detail (sharpness, blur, vignette) and opacity mirror; keyframe toggles; before/after press-and-hold (transient with neutral params); apply to all clips on the lane/project (one command). Filters panel: 12 built-in looks (Teal & Orange, Warm, Cool, Vivid, Matte, Fade, Mono, Noir, Sepia, Vintage, Cinematic, Pastel) with thumbnails from renderLookStills, intensity, 'My LUTs' (.cube import through picker -> CORE-21 parse in Isolate.run -> projectOwned assets via media pool; error copy with line numbers), remove. tool/gen_looks.dart generates the 12 deterministic .vlut assets into assets/looks/ (committed, declared in pubspec by this ticket's asset folder; UX-01 pre-declares the folder).
- **Acceptance criteria and tests:** widget tests per control; look application and intensity; .cube import success and error copy; gen_looks reproducible (no diff); matrix tests.

#### UX-25 · Speed panel and speed curve editor

- **Milestone:** M4 · **Area:** UI/UX
- **Depends on:** UX-16, CORE-12
- **Owns:**
  - `packages/danaview_editor/lib/src/editor/panels/speed_panel.dart`
  - `packages/danaview_editor/lib/src/editor/panels/speed_curve_editor.dart`
  - `packages/danaview_editor/lib/src/editor/actions/bindings/speed_bindings.dart`
  - `packages/danaview_editor/lib/src/app/strings/speed_strings.dart`
  - `packages/danaview_editor/test/panels/speed/`
- **Spec:** ux.md §10.3, D-15: nine chips 0.25×-4× + custom (DanaviewNumberField 0.1-10, clamped by capabilities), ramp presets (Montage, Hero, Bullet, Jump cut, Flash in/out) and a curve editor (3-7 points, drag with semantics adjustable actions), resulting duration readout, maintain-pitch toggle, capability notes (audio muted above maxAudioSpeed), reverse and freeze entry points delegate to UX-35 actions.
- **Acceptance criteria and tests:** chips and custom dispatch SetSpeed; curve editing produces valid ramps; duration readout matches core; golden of the curve editor; matrix tests.

#### UX-26 · Keyframes panel and keyframe actions

- **Milestone:** M4 · **Area:** UI/UX
- **Depends on:** UX-16, CORE-13
- **Owns:**
  - `packages/danaview_editor/lib/src/editor/panels/keyframes_panel.dart`
  - `packages/danaview_editor/lib/src/editor/actions/bindings/keyframe_bindings.dart`
  - `packages/danaview_editor/lib/src/app/strings/keyframe_strings.dart`
  - `packages/danaview_editor/test/panels/keyframes/`
- **Spec:** ux.md §10.11, §9.4: keyframes list grouped by property for the selected item (position, scale, rotation, opacity, volume, adjust/detail values, mask), add/remove at playhead (keyframeAtPlayhead), jump to previous/next key, nudge by frame, edit value, move by drag in the list (snaps to frames), clear property; timeline diamonds are painted by UX-10 and dragged by UX-13.
- **Acceptance criteria and tests:** widget tests for add/remove/move/edit/jump/clear dispatching CORE-13 commands; toggle states; matrix tests.

#### UX-27 · Transitions panel and loop preview

- **Milestone:** M4 · **Area:** UI/UX
- **Depends on:** UX-16, UX-18, CORE-16
- **Owns:**
  - `packages/danaview_editor/lib/src/editor/panels/transitions_panel.dart`
  - `packages/danaview_editor/lib/src/editor/actions/bindings/transition_bindings.dart`
  - `packages/danaview_editor/lib/src/app/strings/transition_strings.dart`
  - `packages/danaview_editor/test/panels/transitions/`
- **Spec:** ux.md §10.12: None + Fade, Cross dissolve, Dip to black, Dip to white, Slide, Wipe, Zoom with direction controls (l/r/u/d; in/out), duration limited by TransitionLimits with an explanation when capped, loop preview of the transition window (play with loop range, restores playhead/play state afterwards), apply to all cuts (one command).
- **Acceptance criteria and tests:** widget tests for every type and direction; duration clamping copy; loop preview restores state (fake engine); apply-to-all is one history entry; matrix tests.

#### UX-28 · Overlay (picture-in-picture) and chroma key panels

- **Milestone:** M4 · **Area:** UI/UX
- **Depends on:** UX-23
- **Owns:**
  - `packages/danaview_editor/lib/src/editor/panels/overlay_panel.dart`
  - `packages/danaview_editor/lib/src/editor/panels/chroma_panel.dart`
  - `packages/danaview_editor/lib/src/editor/actions/bindings/overlay_bindings.dart`
  - `packages/danaview_editor/lib/src/app/strings/overlay_strings.dart`
  - `packages/danaview_editor/test/panels/overlay/`
- **Spec:** ux.md §10.13, §10.10: add video or image overlay at the playhead on a new overlay lane (multiple overlays), bring forward/send backward (moves between overlay lanes), resize/move/rotate via the manipulation overlay, crop and opacity via UX-23 panels, independent timing on its own lane; Chroma panel: enable, key colour (green/blue presets, eyedropper via UX-23 overlay, colour field), similarity, smoothness, spill reduction, matte preview toggle (setEditingMode(matte(item))).
- **Acceptance criteria and tests:** widget tests for add overlay, z moves, chroma controls, eyedropper flow and matte preview toggling with the fake engine; matrix tests.

#### UX-29 · Canvas/Format panel, project sheet, history sheet

- **Milestone:** M4 · **Area:** UI/UX
- **Depends on:** UX-16, CORE-17, CORE-19
- **Owns:**
  - `packages/danaview_editor/lib/src/editor/panels/canvas_panel.dart`
  - `packages/danaview_editor/lib/src/editor/flows/project_sheet.dart`
  - `packages/danaview_editor/lib/src/editor/flows/history_sheet.dart`
  - `packages/danaview_editor/lib/src/editor/actions/bindings/project_bindings.dart`
  - `packages/danaview_editor/lib/src/app/strings/project_strings.dart`
  - `packages/danaview_editor/test/flows/project/`
- **Spec:** ux.md §10.14, §14.2-14.3: Format panel (aspect ratio 16:9, 9:16, 1:1, 4:5, 4:3, 21:9; background solid colour or blur of main; frame rate 24/25/30/48/50/60 with requantize warning; resolution base 720/1080/2160 gated by capabilities); Project sheet (rename, save now, save status, media in project link, shortcuts, tasks, history); History sheet (last 50 entries with labels; jump N steps = one plan patch). Bindings: save (Cmd+S), undo, redo, projectSheet, history, format.
- **Acceptance criteria and tests:** widget tests per control and sheet; jump produces one PlanSync patch (fake); manual save calls repository.save(manual); matrix tests.

#### UX-30 · Text tool, text panel, font picker, content fonts package

- **Milestone:** M4 · **Area:** UI/UX
- **Depends on:** UX-19, CORE-14, API-04
- **Owns:**
  - `packages/danaview_editor/lib/src/editor/panels/text_panel.dart`
  - `packages/danaview_editor/lib/src/editor/panels/font_picker.dart`
  - `packages/danaview_editor/lib/src/editor/text/font_catalog.dart`
  - `packages/danaview_editor_fonts/`
  - `packages/danaview_editor/lib/src/editor/actions/bindings/text_bindings.dart`
  - `packages/danaview_editor/lib/src/app/strings/text_strings.dart`
  - `packages/danaview_editor/test/panels/text/`
- **Spec:** ux.md §10.8, ARCH §17.8/D-30: Add text at playhead; Text panel tabs: edit (multiline field with typing coalescing via SetText coalesce key; keyboard-up degradation step hides the preview), font (FontPicker with search, each family previewed in itself), style (size, bold, italic, alignment, colour, opacity, letter spacing, line spacing), background box, stroke, shadow, animation in/out (fade, slide with direction, scale, typewriter) with a loop preview, duration. packages/danaview_editor_fonts: Flutter assets-only package bundling the 10 OFL families (Figtree, Inter, Montserrat, Oswald, Bebas Neue, Playfair Display, Lora, Caveat, Pacifico, JetBrains Mono; regular/bold/italic where available; OFL texts included) replacing UX-01's placeholder pubspec; FontCatalog maps stable ids -> family names and provides the FontResolver for API-04. UI chrome stays Figtree.
- **Acceptance criteria and tests:** widget tests for every tab dispatching CORE-14 commands; typing produces one history entry per coalesce window; font picker search; matrix tests with keyboard inset; fonts load in a golden test.

#### UX-31 · Subtitles lane tools and subtitles panel

- **Milestone:** M4 · **Area:** UI/UX
- **Depends on:** UX-16, UX-19, CORE-15
- **Owns:**
  - `packages/danaview_editor/lib/src/editor/panels/subtitles_panel.dart`
  - `packages/danaview_editor/lib/src/editor/actions/bindings/caption_bindings.dart`
  - `packages/danaview_editor/lib/src/app/strings/subtitle_strings.dart`
  - `packages/danaview_editor/test/panels/subtitles/`
- **Spec:** ux.md §10.9: Captions tool: add subtitle track, add cue at playhead, virtualized cue list (3,000 cues) with inline edit, start/end nudges by frame, split at text cursor, merge with next, delete, jump; style (font, size, bold/italic, colour, box, outline, shadow, max lines, max width, alignment), position (bottom/top/custom Y with on-preview drag via UX-22), language tag, burn-in toggle per track; track menu actions 'Shift all captions…' (timecode entry via Timecode.parse, e.g. +2.5s / -10f, dispatching ShiftCues for the whole track or the selected range) and 'Select all on this lane'; no-overlap drags handled by UX-13 with rejections shown.
- **Acceptance criteria and tests:** widget tests for each action dispatching CORE-15 commands (incl. Shift all captions as one history entry and Select all on this lane selecting only that track's cues); list virtualization performance test (3,000 cues, scroll frame <= 8 ms in profile test harness); style/position; matrix tests.

#### UX-32 · SRT/VTT import and export UI

- **Milestone:** M4 · **Area:** UI/UX
- **Depends on:** UX-31, CORE-20
- **Owns:**
  - `packages/danaview_editor/lib/src/editor/panels/subtitle_io.dart`
  - `packages/danaview_editor/lib/src/editor/actions/bindings/subtitle_io_bindings.dart`
  - `packages/danaview_editor/lib/src/app/strings/subtitle_io_strings.dart`
  - `packages/danaview_editor/test/panels/subtitle_io/`
- **Spec:** Import SRT/VTT via picker -> SubtitleCodec.parse in Isolate.run (encoding fallback reported, issues with line numbers shown, stripped tags summarized) -> ImportSubtitles into a new track or replacing a track; Export SRT or VTT of a chosen subtitle track (including generated captions) with the suggested name `<project>.<bcp47>.srt|vtt`, written to <cache>/danaview/editor/work/ then handed to FileHandoff.saveToFiles or share; temp file deleted via OwnedFileDeleter afterwards.
- **Acceptance criteria and tests:** widget tests with corpus fixtures (valid, malformed, UTF-16); new vs replace; export calls FileHandoff with the right content and name; matrix tests.

#### UX-33 · Audio panel: volume, fades, mute, pitch, extract audio, background music

- **Milestone:** M4 · **Area:** UI/UX
- **Depends on:** UX-16, CORE-13, CORE-11
- **Owns:**
  - `packages/danaview_editor/lib/src/editor/panels/audio_panel.dart`
  - `packages/danaview_editor/lib/src/editor/actions/bindings/audio_bindings.dart`
  - `packages/danaview_editor/lib/src/app/strings/audio_strings.dart`
  - `packages/danaview_editor/test/panels/audio/`
- **Spec:** ux.md §10.4: volume 0-200% with keyframe toggle, mute, fade in/out (handles also on the timeline via UX-13), maintain pitch, audio role; Extract audio (ExtractAudio command; non-destructive, linked); Add music flow (picker audio -> import -> InsertMedia on a music-role audio lane at the playhead); audio-only trim/split/move/duplicate/delete reuse UX-13 tools.
- **Acceptance criteria and tests:** widget tests per control; extract audio produces a linked clip; add music lands on an audio lane with AudioRole.music; matrix tests.

#### UX-34 · Voiceover recording UI

- **Milestone:** M4 · **Area:** UI/UX
- **Depends on:** UX-33
- **Owns:**
  - `packages/danaview_editor/lib/src/editor/panels/voiceover_panel.dart`
  - `packages/danaview_editor/lib/src/editor/actions/bindings/voiceover_bindings.dart`
  - `packages/danaview_editor/lib/src/app/strings/voiceover_strings.dart`
  - `packages/danaview_editor/test/panels/voiceover/`
- **Spec:** ux.md §10.5 (shown only when engine.voiceRecorder != null): permission explanation -> OS prompt; denied state with Open Settings; 3-2-1 countdown (reduced-motion aware); level meter from levels stream; record from the playhead with preview playing muted; stop -> WAV in projects/<id>/assets/recordings/ imported as projectOwned media and inserted on a voice-role audio lane (auto-created) aligned using startLatencyUs; interruption keeps the partial recording with a notice; cancel discards.
- **Acceptance criteria and tests:** widget tests with a fake recorder for every state incl. interruption and denied; inserted clip start = record start + latency compensation; matrix tests.

#### UX-35 · Freeze, reverse, replace, clip info, background tasks

- **Milestone:** M4 · **Area:** UI/UX
- **Depends on:** UX-16, CORE-12, CORE-11
- **Owns:**
  - `packages/danaview_editor/lib/src/editor/panels/clip_info_panel.dart`
  - `packages/danaview_editor/lib/src/editor/flows/tasks_sheet.dart`
  - `packages/danaview_editor/lib/src/editor/state/tasks_controller.dart`
  - `packages/danaview_editor/lib/src/editor/actions/bindings/clip_bindings.dart`
  - `packages/danaview_editor/lib/src/app/strings/clip_strings.dart`
  - `packages/danaview_editor/test/flows/tasks/`
- **Spec:** ux.md §10.15: Freeze frame (engine.jobs.freezeFrame to projects/<id>/assets/stills/, inserted as a pending still with placeholder progress), Reverse (SetReversed + engine.jobs.reverse to derived/<specHash>.mp4; badge with progress and cancel; export gated while pending), Replace media (picker -> ReplaceMedia with trim notice), Clip info panel (name, source path display name, duration, source in/out, speed, resolution, fps, codec, audio, size, ownership/location), TasksController (proxies, reverse, freeze, waveforms, captions, model download; pool status updates via applyPoolChange) and Tasks sheet with cancel.
- **Acceptance criteria and tests:** widget tests with fake jobs for each flow incl. cancel and failure; task indicator updates; export gating flag; matrix tests.

#### UX-36 · Media panel (bin), add/replace, in-app and external drag and drop

- **Milestone:** M4 · **Area:** UI/UX
- **Depends on:** UX-06, UX-13
- **Owns:**
  - `packages/danaview_editor/lib/src/editor/panels/media_panel.dart`
  - `packages/danaview_editor/lib/src/editor/timeline/timeline_drop_target.dart`
  - `packages/danaview_editor/lib/src/editor/actions/bindings/media_bindings.dart`
  - `packages/danaview_editor/lib/src/app/strings/media_strings.dart`
  - `packages/danaview_editor/test/panels/media/`
- **Spec:** ux.md §10.1, §15.3, D-18: media bin with filters (video/audio/image/LUT) and search, usage counts, offline badges; add at playhead (ripple insert on the main lane when ripple is on, else new lane), add as overlay, replace selected, remove from project (only when unused; undoable PoolEdit), drag from bin to timeline with drop ghost + snapping (TimelineDropTarget using dryRun), external drops from engine.drops (enabled while the editor is visible) imported as managed copies through UX-06's ImportMediaSheet (free-space preflight, progress, cancel) then placed at the drop position; desktop drag (later) reuses the same target.
- **Acceptance criteria and tests:** widget tests for filters/search, add/insert/overlay/replace/remove, drag ghost equals final placement, external drop flow with the fake engine; matrix tests.

#### CORE-37 · Render-preview cache model: range hashing, invalidation, cache index

- **Milestone:** M4 · **Area:** Core (pure Dart)
- **Depends on:** CORE-32
- **Owns:**
  - `packages/danaview_editor_core/lib/render_cache.dart`
  - `packages/danaview_editor_core/lib/src/plan/render_ranges.dart`
  - `packages/danaview_editor_core/lib/src/store/render_cache_index.dart`
  - `packages/danaview_editor_core/test/plan/render_cache/`
- **Spec:** ARCH D-45(A), §9.5, §17.10 (owner decision 2026-10-11, D-43(e) point 4). New public barrel `lib/render_cache.dart` (the existing barrels stay unchanged, §2). (1) `splitRanges(RenderPlan preview)` -> `List<PlanRange>` cut on the frame grid at every layer and transition edge, adjacent ranges with identical content merged. (2) `rangeHash(plan, range, {previewSize})`: SHA-256 over a canonical JSON of everything that can change the range's pixels: the layers overlapping the range clipped to it with times relative to its start, asset `fp` (never `uri`, bookmarks or paths), params, keyframes, transitions, sprite and LUT ids, canvas, `gridFps` and the preview render size; independent of `rev` and of anything outside the range. (3) `heavyRanges(plan, RenderBudget)` with `RenderBudget {maxLiveDecoders, maxLiveSlots?, effectCostLimit}` built per tier from `EditorCapabilities`; reasons `decoders | chromaKey | effects`. (4) `invalidated(oldPlan, newPlan)` -> the hashes no longer present, so any edit touching a range invalidates its entry and an undo that restores a range finds its old entry again. (5) `RenderCacheIndex` (under `lib/src/store/`, the only `dart:io` part, through `StoreFs`/`AtomicFile`): `<cache>/danaview/editor/renders/index.json` + `<rangeHash>.mp4`; `lookup`, `put`, `touch`, LRU eviction to 1 GB (512 MB on minimal/low), `trim(level)`, `clear()`, `bytes` for the "Editor cache" contributor; deletes only through `OwnedFileDeleter` inside `renders/`; a corrupt index is rebuilt and orphan files removed. (6) `coverage(plan, index, budget)` -> `List<RangeStatus>` (`rendered | heavyUnrendered | notNeeded`) for the timeline marker. (7) `RenderPolicy.shouldAutoRender(tier, setting, idle, charging)`: Auto on minimal/low renders only while idle (no playback, edit or job for 5 s) and charging; Manual never auto-renders; the manual action is allowed on every tier.
- **Acceptance criteria and tests:** hash stable across plan encode/decode and `rev` changes and across a `uri` change with the same `fp`; property test on random edit sequences: an edit changes the hashes of exactly the ranges it overlaps and no other, and undo restores the previous hashes; heavy-range vectors per tier (decoders over budget, chroma key, effect cost) committed under the test dir; index survives `FaultInjectingFs` crashes at every step, respects the LRU bound, and `clear()` never touches anything outside `renders/`; policy truth table; purity test stays green (no `package:flutter`; `dart:io` only under `lib/src/store/`); export plans never reference cache files (compile test).

#### CORE-38 · Allow edits above the live-preview sequence cap

- **Milestone:** M4 · **Area:** Core (pure Dart)
- **Depends on:** CORE-09, CORE-37
- **Owns:**
  - `packages/danaview_editor_core/lib/src/ops/limits.dart` (shared with CORE-09, §7)
  - `packages/danaview_editor_core/test/ops/framework/` (shared with CORE-09, §7)
  - `packages/danaview_editor_core/test/ops/preview_cap/`
- **Spec:** ARCH D-14, D-45(B), §7.1, §13.5 (owner decision 2026-10-11, D-43(e) point 7: `maxVisualSequences` limits live preview only, editing is never blocked and export never refuses). A requirement change, not a defect, and it needs CORE-37, so it is a new M4 ticket rather than a `FIX-CORE-09-n` (§1 item 8); like a FIX ticket it edits only the CORE-09 files that must change. (1) `LayerLimits.check` no longer returns `LimitExceeded(visualSequences)` or `LimitExceeded(concurrentVideoLayers)`: a command is never refused for either layer cap (D-45(B) applies to both). Items (5,000) and duration (24 h) stay hard limits with the existing rule that only an edit making an exceeded count worse is refused. (2) Validation reports an informational state instead: `LimitCounts.previewCap(EditPolicy)` -> `PreviewCapStatus {bool aboveLivePreviewCap; int visualSequences, maxVisualSequences, peakConcurrentVideoLayers, maxConcurrentVideoLayers}`, with `aboveLivePreviewCap` true when either layer count is over its cap; `LimitCounts.exceeded` returns only the hard limits. The state is data for the preview layer (proxies, paused-exact still frames, the render-preview cache through CORE-37's `heavyRanges`) and the export layer (IOS-20 and AND-19 multi-pass precompose); it is never a rejection, an exception or a blocking banner. (3) Packing stays the single CORE-36 implementation, incremental per session. (4) The `LimitExceeded.visualSequences` and `.concurrentVideoLayers` constants stay declared (CORE-09's `rejections.dart` and `edit_context.dart` are not edited), so UX-08's message mapping still compiles; core no longer produces them. Consumers that show or use the new state (UX-08 state, UX-44, UX-39 preflight copy) adopt it in their own tickets or FIX tickets; this ticket edits nothing outside these files.
- **Acceptance criteria and tests:** the CORE-09 fixture that adds a seventh overlapping PiP lane above `maxVisualSequences` now succeeds, and the result reports `aboveLivePreviewCap == true` with the counts; the same for a peak-concurrent-decoder overflow; a reducing edit clears the flag; `dryRun` and `applyCommand` agree on the flag; the item and duration limits reject exactly as before; CORE-09's framework tests that asserted the layer-cap rejections are updated to assert the informational state, and no other test changes meaning; CORE-34's fuzz-lite stays green with the cap-tight policy (a regression file that relied on the old rejection is fixed through a FIX-CORE-34 ticket); benchmark: `dryRun` including limits <= 1 ms at 1,000 items; purity test green.

#### INT-06 · [INTEGRATION] Engine interface additions for render preview

- **Milestone:** M4 · **Area:** Integration
- **Depends on:** ENG-06, CORE-37
- **Owns:** (every path below is shared and edited only for the D-45 additions, §7)
  - `packages/danaview_editor_engine/pigeons/engine_api.dart`
  - `packages/danaview_editor_engine/lib/src/pigeon/`
  - `packages/danaview_editor_engine/ios/Classes/Pigeon/`
  - `packages/danaview_editor_engine/android/src/main/kotlin/com/vecvel/danaview/editor/engine/pigeon/`
  - `packages/danaview_editor_engine/ios/Classes/Glue/`
  - `packages/danaview_editor_engine/android/src/main/kotlin/com/vecvel/danaview/editor/engine/glue/`
  - `packages/danaview_editor_engine/lib/src/mobile_editor_engine.dart`
  - `packages/danaview_editor_engine/lib/src/mobile_preview_session.dart`
  - `packages/danaview_editor_engine/lib/src/mobile_jobs.dart`
  - `packages/danaview_editor_engine/lib/src/mobile_platform_services.dart`
  - `packages/danaview_editor_engine/test/glue/`
  - `packages/danaview_editor_engine_api/lib/src/preview.dart`
  - `packages/danaview_editor_engine_api/lib/src/media_services.dart`
  - `packages/danaview_editor_engine_api/lib/src/platform_services.dart`
  - `packages/danaview_editor_engine_api/lib/src/fake/`
  - `packages/danaview_editor_engine_api/test/contract/`
  - `docs/v1.1/editor/ARCHITECTURE.md` (§12.2, §12.3, §12.4, §12.6 and D-45 'Contract' only)
- **Spec:** [INTEGRATION] ARCH D-45 'Contract', §12.2–§12.4, §12.6 (owner decision 2026-10-11, D-43(e) point 4). The lead-approved amendment of the surface ENG-06 froze (§2, D-42); it lands before UX-44, IOS-19 and AND-18 call the engine. (1) **Render-preview job:** `MediaJobs.renderPreview(RenderPlan rangePlan, {required String outputPath})` (a preview plan cut to the range, times relative to its start; `outputPath` inside `<cache>/danaview/editor/renders/`) started and cancelled through the existing job path (`JobKindMsg.renderPreview` and its request fields in `JobRequestMsg`, `cancelJob`), with progress and done/failed reported through the existing `EngineEventMsg` job events (≤ 4 Hz). (2) **Rendered ranges:** `PreviewSession.setRenderedRanges(List<RenderedRange>)` (`RenderedRange {TimeRange range; String uri; String hash}`) as `PreviewHostApi.setRenderedRanges(session, List<RenderedRangeMsg>)`; the contract states that the engine drops any rendered range an applied patch touches until the next call. (3) **Power/idle signal:** `PlatformServices.powerState()` -> `PowerState {bool charging; bool lowPowerMode}` plus a `powerStateChanged` signal event, which UX-44 combines with its own editor-idle timer (no playback, edit or job for 5 s) for the automatic default on minimal/low. (4) Generated Dart/Swift/Kotlin regenerated and committed; iOS and Android glue route the new calls to service classes that are D-33 placeholders returning `notSupportedOnDevice`, created inside IOS-19's `ios/Classes/RenderPreview/` and AND-18's `.../engine/preview/render/` with headers `// OWNER: IOS-19` / `// OWNER: AND-18` (not in this ticket's owns); `MobileEditorEngine` and the `mobile_*` glue map them; API-01's types, `FakeEditorEngine` (renders instantly to a stub file, honours cancel, records rendered ranges and drops them on a touching patch, scripted power state) and the contract kit gain the matching cases. (5) Records in ARCHITECTURE §12.6 (freeze record) that INT-06 is the approved amendment, and updates §12.2–§12.4 and D-45 'Contract'. No service behaviour is implemented here; the RenderPlan schema does not change.
- **Acceptance criteria and tests:** Pigeon regeneration produces no diff against the committed generated code; Dart glue tests with mocked channels for `renderPreview` start/cancel/progress/done/failed, `setRenderedRanges` and `powerState`/`powerStateChanged`; the contract kit passes on `FakeEditorEngine` with the new cases (a patch touching a rendered range drops it; cancel deletes the output; failures map to `EngineFailure`); `MobileEditorEngine` returns `notSupportedOnDevice` for the new calls until IOS-19 and AND-18 land; the example app builds on iOS and Android and the existing RunnerTests and Android unit tests stay green; the API surface test lists the new names; ARCHITECTURE.md changed only in the sections named above.

#### UX-44 · Render-preview UI: timeline render marker, action, settings, tier defaults

- **Milestone:** M4 · **Area:** UI/UX
- **Depends on:** UX-18, UX-04, CORE-37, INT-06
- **Owns:**
  - `packages/danaview_editor/lib/src/editor/state/render_preview_controller.dart`
  - `packages/danaview_editor/lib/src/editor/timeline/render_marker_strip.dart`
  - `packages/danaview_editor/lib/src/editor/actions/bindings/render_preview_bindings.dart`
  - `packages/danaview_editor/lib/src/settings/render_preview_settings_section.dart`
  - `packages/danaview_editor/lib/src/app/editor_tier_defaults.dart`
  - `packages/danaview_editor/lib/src/app/strings/render_preview_strings.dart`
  - `packages/danaview_editor/test/render_preview/`
- **Spec:** ARCH D-45, §17.4, §17.5, §17.10, §9.5 (owner decision 2026-10-11, D-43(e) points 1, 2 and 4). `EditorTierDefaults`: effective defaults when the user never set the pref (`editor.proxyMedia` Always on minimal/low, Auto on mid/high; `editor.renderPreview` Auto on minimal/low, Manual on mid/high); UX-04's proxy row and this ticket's section read them, so a minimal/low device starts with background proxies on. `RenderPreviewController`: after each plan revision computes `coverage` and `invalidated` with CORE-37, sends `setRenderedRanges` with only valid entries, queues heavy ranges (Auto policy: idle 5 s and charging, through the engine's power signal; one render at a time, `JobPriority.background`, cancelled on playback start, edit inside the range, export start or memory pressure), and runs `engine.jobs.renderPreview` for the manual action (selection, loop range or whole timeline; available on every tier); writes results into the index. `RenderMarkerStrip`: thin strip under the ruler (rendered / heavy-unrendered / not needed, distinguished by fill pattern as well as colour, computed contrast), tapping an amber range offers "Render preview"; mounted through UX-12's timeline decoration slot (a FIX-UX-12 adds the slot if it is missing). Action `renderPreview` and its shortcut in its own bindings file. Settings section (shown in UX-04's second slot): Render preview Auto/Manual with the tier default, "Clear rendered previews" (also covered by "Editor cache"), a one-line description of the trade-off. Copy in its own strings file. The engine calls (`renderPreview`, `setRenderedRanges`, the power signal) come from INT-06; until IOS-19 and AND-18 fill the native side they return `notSupportedOnDevice` on devices, so the controller keeps live preview and its tests run against API-01's fake engine (amended 2026-10-11: INT-06 added).
- **Acceptance criteria and tests:** controller tests with FakeEditorEngine: an edit inside a rendered range removes it from `setRenderedRanges` before the new plan plays; Auto renders only when idle and charging on minimal/low and never on mid/high; the manual action works on every tier; jobs cancel on play, edit and export; tier-default tests (unset pref -> tier default, explicit pref wins); marker strip goldens for the three states and the accessibility label of each range; the "Editor cache" contributor's bytes include render files and its clear removes them (with UX-04's contributor); matrix tests no overflow at 280–1280 and text scale 0.85–1.35.

#### IOS-19 · iOS render-preview renderer and playback swap-in

- **Milestone:** M4 · **Area:** iOS native
- **Depends on:** IOS-11, INT-06
- **Owns:**
  - `packages/danaview_editor_engine/ios/Classes/RenderPreview/`
  - `packages/danaview_editor_engine/example/ios/RunnerTests/RenderPreview/`
- **Spec:** ARCH D-45, §13.2 (owner decision 2026-10-11, D-43(e) point 4). Replaces the INT-06 placeholders in this directory (`// OWNER: IOS-19`: the render-preview job service, the rendered-range handler and the power/idle signal, which reports charging and low-power state from `UIDevice`/`ProcessInfo`). `RenderPreviewJob` (registered with IOS-05's job registry): renders a range plan through the same composition builder and `DVCompositor` with an `AVAssetReader` → `AVAssetWriter` at the preview render size, project fps on the frame grid, H.264 with every frame a sync sample (or `MaxKeyFrameInterval` 1), video only, to the given output path inside `<cache>/danaview/editor/renders/`; progress, cancel (deletes the partial file), thermal `serious` pauses. `RenderedRangeSwap`: implements IOS-11's rendered-range hook; during playback the cached file replaces the range's video tracks in the preview composition as one segment, switching at the range's exact frame boundaries, audio stays live; paused, scrub and exact seek keep the full composition; a patch that touches a range drops it until the next `setRenderedRanges`.
- **Acceptance criteria and tests:** XCTest: a rendered range matches the live composition frame by frame (barcode exact, SSIM ≥ 0.99 at preview size); playback across a range boundary shows the right frame at every boundary (grid-cut barcodes 100%); a param patch inside the range falls back to live rendering on the next frame; cancel cleans up; render files are never referenced by an export plan; simulator numbers for a 4-layer chroma-key range (render time, playback dropped frames) recorded in the PR.

#### IOS-20 · iOS multi-pass export fallback (precompose above the decoder limit)

- **Milestone:** M4 · **Area:** iOS native
- **Depends on:** IOS-12
- **Owns:**
  - `packages/danaview_editor_engine/ios/Classes/Export/Precompose/`
  - `packages/danaview_editor_engine/example/ios/RunnerTests/Precompose/`
- **Spec:** ARCH D-45(B), §14.2 'Multi-pass fallback' (owner decision 2026-10-11, D-43(e) point 7; parity with Android). `PrecomposePlanner` decides from the plan and the device decoder limit (and from a `decoderInitFailed` on a composition track at export start) how many bottom tracks to render per pass; `PrecomposePass` renders the background plus those tracks into an opaque, video-only, full-resolution intermediate at the export size (all-intra or ≥ 4× the export bitrate, export frame grid, same Core Image working space) in `work/export-<jobId>/pre-<n>.mov`; the final pass is IOS-12's normal pipeline with the intermediate as the bottom layer; intermediates join the IOS-17 checkpoint so a resumed job never redoes a finished pass; progress is one fraction over all passes; cancel and failure delete them; disk preflight counts them. Plugs into IOS-12's multi-pass hook; never edits IOS-12's files.
- **Acceptance criteria and tests:** a precomposed export equals a single-pass export of the same plan (SSIM ≥ 0.995 per frame, grid-cut barcodes 100%, identical frame count and audio); a forced decoder limit of 2 exports a 5-track project instead of failing; interrupt during pass 1 and during the final pass resumes correctly; cancel cleans every intermediate; conformance (QA-11 rules) on the output.

#### AND-18 · Android render-preview renderer and playback swap-in

- **Milestone:** M4 · **Area:** Android native
- **Depends on:** AND-16, AND-10, INT-06
- **Owns:**
  - `packages/danaview_editor_engine/android/src/main/kotlin/com/vecvel/danaview/editor/engine/preview/render/`
  - `packages/danaview_editor_engine/android/src/test/kotlin/com/vecvel/danaview/editor/engine/render/`
  - `packages/danaview_editor_engine/android/src/androidTest/kotlin/com/vecvel/danaview/editor/engine/render/`
- **Spec:** ARCH D-45, §13.3 'Over-budget layers and the render-preview cache' (owner decision 2026-10-11, D-43(e) point 4). Replaces the INT-06 placeholders in this directory (`// OWNER: AND-18`: the render-preview job service, the rendered-range handler and the power/idle signal, which reports charging from the battery broadcast and power-save state from `PowerManager`). `RenderPreviewJob` (registered with AND-05's job registry): a `Transformer` export of the range plan through the AND-08 mapper (`target = export` with the preview canvas size and the project fps; same effects, gating and working space) to a temporary intermediate inside `<cache>/danaview/editor/renders/`, H.264 with I-frame interval 0 (all-intra) or ≤ 0.5 s, video only, hardware encoder first; progress, cancel (deletes the partial file), thermal `SEVERE` pauses; never runs while an export runs. `RenderedRangeSwap`: implements AND-16's rendered-range hook; during playback one deck plays the cached file in place of every slot of the range, pre-rolled like a standby deck and switched at the range's exact frame boundaries under the hold/miss rule (drop, never wrong); paused, scrub and exact seek keep the normal decks; a patch touching a range drops it until the next `setRenderedRanges`.
- **Acceptance criteria and tests:** instrumented: a rendered range matches live composition at preview size (barcode exact, SSIM ≥ 0.99); 0 wrong frames across range boundaries at 24/30/60 fps; a 6-layer chroma-key range on the minimal/low tier settings plays with ≤ 2% dropped frames from its cache where live playback shows still frames (emulator numbers recorded; device numbers QA-04's); a param patch inside the range falls back to live on the next frame; cancel and process death leave no partial file in the index; export plans never reference render files.

#### AND-19 · Android multi-pass export precompose

- **Milestone:** M4 · **Area:** Android native
- **Depends on:** AND-11
- **Owns:**
  - `packages/danaview_editor_engine/android/src/main/kotlin/com/vecvel/danaview/editor/engine/export/precompose/`
  - `packages/danaview_editor_engine/android/src/test/kotlin/com/vecvel/danaview/editor/engine/precompose/`
  - `packages/danaview_editor_engine/android/src/androidTest/kotlin/com/vecvel/danaview/editor/engine/precompose/`
- **Spec:** ARCH D-45(B), §14.3 'Multi-pass precompose' (owner decision 2026-10-11, D-43(e) point 7; replaces "export refuses until reduced"). `PrecomposePlanner`: from the packed export plan and `maxVisualSequences` / codec `maxSupportedInstances` − 2, decides how many bottom slots each pass renders; `PrecomposePass`: a video-only `Transformer` export of the background plus those slots through the AND-08 mapper (`target = export`, same frame processor, HDR mode and working colour space) at the export size to `work/export-<jobId>/pre-<n>.mp4`, all-intra (I-frame interval 0) or ≥ 4× the export bitrate; repeats until the rest fits; the final pass maps the intermediate as an ordinary bottom video layer on the export frame grid (rule-frame clipping, ARCH §13.3) and mixes audio once. Progress is one fraction over all passes; cancel, failure and process death delete intermediates; disk preflight counts them; AND-12's foreground service covers every pass. Plugs into AND-11's multi-pass hook; never edits AND-11's files.
- **Acceptance criteria and tests:** instrumented on the emulator: a precomposed export equals a single-pass export of the same plan (SSIM ≥ 0.995 per frame, grid-cut barcodes 100% at 24/30/60 fps, identical frame count, audio PCM within the QA-11 tolerances); with `maxVisualSequences` forced to 2 a 6-slot project exports instead of being refused; HDR/tone-mapped and rotated sources match single pass; cancel during each pass leaves no intermediates; JVM tests for the planner (slot split, disk estimate).

### M5: Export UI, auto captions, media health, player entry, legal, platform declarations

#### INT-03 · [INTEGRATION] iOS app declarations: Info.plist, entitlements, privacy manifest, BG task ids

- **Milestone:** M5 · **Area:** Integration
- **Depends on:** INT-01, IOS-13, IOS-14, IOS-15
- **Owns:**
  - `ios/Runner/Info.plist`
  - `ios/Runner/Runner.entitlements`
  - `ios/Runner/PrivacyInfo.xcprivacy`
  - `ios/Runner.xcodeproj/project.pbxproj`
  - `ios/Runner/AppDelegate.swift`
- **Spec:** [INTEGRATION] ARCH §20.4: NSMicrophoneUsageDescription and NSPhotoLibraryAddUsageDescription strings exactly as written there; BGTaskSchedulerPermittedIdentifiers = [com.vecvel.danaview.export.*] plus any background mode IOS-13 proved necessary (V-N12); NO NSPhotoLibraryUsageDescription; Runner.entitlements with com.apple.developer.background-tasks.continued-processing.gpu behind a build setting (DANAVIEW_BG_GPU_ENTITLEMENT, off until Apple grants it), referenced via CODE_SIGN_ENTITLEMENTS in project.pbxproj (second integration touch after INT-01); Runner PrivacyInfo.xcprivacy (NSPrivacyTracking false, no collected data types, required-reason APIs the app itself uses) added to the Runner target; AppDelegate.swift only if BG task registration must happen at launch (keep the FlutterImplicitEngineDelegate structure).
- **Acceptance criteria and tests:** `flutter build ipa --no-codesign` succeeds; plist/entitlement/privacy-manifest validation (plutil, Xcode privacy report) clean; microphone and add-to-Photos prompts show the new strings on the simulator; on an iPhone the export reports `paused` and resumes (D-22); continued-processing export starts on an iOS 26 iPad with background GPU when entitled (or the fallback is recorded).

#### INT-04 · [INTEGRATION] App wiring v2: auto captions service, adapters, player Edit, licences route

- **Milestone:** M5 · **Area:** Integration
- **Depends on:** INT-02, AI-13, UX-38, UX-41, UX-42, ENG-03, ENG-04
- **Owns:**
  - `packages/danaview_editor/lib/src/app/adapters/`
  - `lib/main.dart`
  - `lib/router/app_router.dart`
  - `pubspec.yaml`
  - `test/editor_wiring_test.dart`
  - `test/privacy_policy_host_test.dart`
- **Spec:** [INTEGRATION] Adapters (D-28): EngineSpeechAudioExtractor (danaview_transcription SpeechAudioExtractor -> engine.jobs.extractSpeechAudio) and EngineBackgroundLeaseProvider (-> engine.background); root pubspec adds danaview_transcription and danaview_whisper; main.dart constructs TranscriptionServiceImpl (model store roots under <support>/danaview/speech, adapters, governor signals from engine.signals and danaview_whisper device events) and registers LicenseRegistry entries for whisper.cpp/ggml, OpenAI Whisper weights, Silero VAD, Media3 and content fonts; app_router: player route passes onEditVideo -> EditorLauncher.openFromPlayer when available, explicit /settings/licenses route to DanaviewLicensesScreen and About onOpenLicenses; storage registry adds SpeechStorageContributor. test/privacy_policy_host_test.dart asserts the privacy policy text contains SpeechModelSpec.host and its CDN host and an `HttpOverrides` spy test proves zero network access before consent (the real TranscriptionServiceImpl driven through the Auto captions flow up to the consent view opens no HttpClient request before UserConsent.accepted; the first request afterwards targets huggingface.co; ARCH §20.3).
- **Acceptance criteria and tests:** wiring test boots the app with fakes and reaches Auto captions, licences and player Edit; privacy host and no-network-before-consent tests green; macOS-targeted widget and route test (D-17): no Edit in the player top bar or more sheet, no 'E' shortcut line, no speech storage contributor; app builds on iOS (with xcframework) and Android; desktop unaffected.

#### IOS-13 · iOS background export, active-export store, Photos and Files handoff

- **Milestone:** M5 · **Area:** iOS native
- **Depends on:** IOS-12
- **Owns:**
  - `packages/danaview_editor_engine/ios/Classes/Export/BackgroundExecution.swift`
  - `packages/danaview_editor_engine/ios/Classes/Export/ActiveExportStore.swift`
  - `packages/danaview_editor_engine/ios/Classes/Platform/PhotosSaver.swift`
  - `packages/danaview_editor_engine/ios/Classes/Platform/FileHandoff.swift`
  - `packages/danaview_editor_engine/example/ios/RunnerTests/Background/`
- **Spec:** D-22, D-39 and ARCH §14.2 'Background' (review issues 4, 7): BackgroundExecution decides `backgroundKind` per device — iPhone: `paused` (on didEnterBackground the export stops, IOS-17 keeps the checkpoint, progress reports pausedInBackground; on return `resume(jobId)` continues from the last complete segment automatically); iPad on iOS 26+ with `BGTaskScheduler.shared.supportedResources.contains(.gpu)` and the GPU entitlement: `continued` (BGContinuedProcessingTaskRequest('com.vecvel.danaview.export.<jobId>', title, subtitle), strategy .fail, requiredResources .gpu, progress reported to the system, expiration → the same checkpoint interruption). No software-CIContext background path unless IOS-01 proved it (V-N22). ActiveExportStore persists running job records, resumable checkpoints and `completedWhileDetached` records (with the output exempt from the work/ wipe for 7 days), so activeJobs() reattaches, reports resumable or a one-shot interrupted after process death, and reports a completion that happened while no Dart listener was attached; when such a completion happens with `whenDetached = saveToGallery` and add-only Photos access is authorized, the PhotosSaver saves natively. PhotosSaver: PHPhotoLibrary add-only PHAssetCreationRequest (NSPhotoLibraryAddUsageDescription; denied -> permissionDenied). FileHandoff: UIDocumentPickerViewController(forExporting:asCopy:true) and UIActivityViewController.
- **Acceptance criteria and tests:** on a **real iPhone on iOS 18 and on iOS 26** (lab), backgrounding an export for > 30 s and returning resumes from the last segment and the result passes conformance with continuous barcodes (V-N20); on the simulator the checkpoint/resume logic is tested with an injected writer failure (−11847) since the simulator does not reproduce encoder loss; iPad continued task with progress on device when entitled (V-N12 with INT-03); resumable after kill; completedWhileDetached reported once; Photos add-only works without full library access; Files and share sheets return results; temp file left for Dart to delete via OwnedFileDeleter.

#### AND-12 · Android export foreground service, notification, background guard, MediaStore, file handoff

- **Milestone:** M5 · **Area:** Android native
- **Depends on:** AND-11
- **Owns:**
  - `packages/danaview_editor_engine/android/src/main/kotlin/com/vecvel/danaview/editor/engine/export/ExportService.kt`
  - `packages/danaview_editor_engine/android/src/main/kotlin/com/vecvel/danaview/editor/engine/export/ExportNotification.kt`
  - `packages/danaview_editor_engine/android/src/main/kotlin/com/vecvel/danaview/editor/engine/platform/BackgroundGuard.kt`
  - `packages/danaview_editor_engine/android/src/main/kotlin/com/vecvel/danaview/editor/engine/platform/MediaStoreSaver.kt`
  - `packages/danaview_editor_engine/android/src/main/kotlin/com/vecvel/danaview/editor/engine/platform/FileHandoff.kt`
  - `packages/danaview_editor_engine/android/src/main/res/drawable/danaview_export_notification.xml`
  - `packages/danaview_editor_engine/android/src/androidTest/kotlin/com/vecvel/danaview/editor/engine/service/`
- **Spec:** D-22: ExportService foreground service (type mediaProcessing on API 35+, dataSync on 29-34) started by the coordinator, notification with determinate progress <= 1 Hz and a Cancel action that works with the activity destroyed, API 35 onTimeout -> interrupted, POST_NOTIFICATIONS requested in context by Dart (no notification -> export still runs visibly); BackgroundGuard leases hosted by the same service (used by auto captions on Android). MediaStoreSaver: MediaStore.Video with RELATIVE_PATH Movies/Danaview and IS_PENDING; FileHandoff: SAF ACTION_CREATE_DOCUMENT and ACTION_SEND via FileProvider ${applicationId}.danaview.editor.files. **Detached completion (D-39):** when a job completes and no Dart listener is attached (activity destroyed, app swiped from recents, engine gone), ExportService applies the job's whenDetached handoff natively (default saveToGallery via MediaStoreSaver), writes a completedWhileDetached record to ActiveExportStore, exempts the output from the work/ wipe, and posts a 'Saved to Gallery' notification that opens the app.
- **Acceptance criteria and tests:** export continues with the activity destroyed; **swiping the app from recents mid-export ends with the video in the Gallery and a completedWhileDetached record offered once on relaunch** (instrumented with UiAutomator plus the QA-02 shell script); notification Cancel cancels; FGS types correct per API (29, 34, 35 emulators); lease lifecycle; gallery insert visible in the Photos app; share intent grants read permission only to the chosen target.

#### UX-37 · Auto captions flow: sheet, controller, language picker, consent, progress

- **Milestone:** M5 · **Area:** UI/UX
- **Depends on:** UX-31, AI-08, CORE-15
- **Owns:**
  - `packages/danaview_editor/lib/src/editor/flows/captions/auto_captions_sheet.dart`
  - `packages/danaview_editor/lib/src/editor/flows/captions/auto_captions_controller.dart`
  - `packages/danaview_editor/lib/src/editor/flows/captions/language_picker.dart`
  - `packages/danaview_editor/lib/src/editor/flows/captions/model_consent_view.dart`
  - `packages/danaview_editor/lib/src/editor/flows/captions/captions_progress_panel.dart`
  - `packages/danaview_editor/lib/src/editor/actions/bindings/auto_captions_bindings.dart`
  - `packages/danaview_editor/lib/src/app/strings/captions_strings.dart`
  - `packages/danaview_editor/test/flows/captions/`
- **Spec:** ai.md §11 states and copy, ux.md §12, D-19/D-20: AutoCaptionsController state machine (scope selection, language picker with the device locale preselected and 'Detect automatically' as a secondary row; low-confidence top-3 choice; tier choice Fast/Balanced/Accurate with sizes and RAM gating; preflight results; ModelConsentView showing ConsentDisclosure (file, size incl. VAD, host huggingface.co / hf.co, sha256) — the ONLY place UserConsent.accepted( is called; resumable download progress; phases extract/transcribe/segment with ETA; cancel at every step leaves no partial track; result applied as ONE history entry via EditorController.apply; failure copy for every TranscriptionFailure). Hidden unless DANAVIEW_AUTO_CAPTIONS is true and offers() is non-empty.
- **Acceptance criteria and tests:** widget tests with FakeTranscriptionService for every state and failure; architecture test for the consent call site passes; cancel leaves the project unchanged; one undo removes all generated cues; no Material chrome; matrix tests.

#### UX-38 · Regenerate captions, interrupted-job notice, captions settings, speech storage contributor

- **Milestone:** M5 · **Area:** UI/UX
- **Depends on:** UX-37, UX-04
- **Owns:**
  - `packages/danaview_editor/lib/src/editor/flows/captions/regenerate_sheet.dart`
  - `packages/danaview_editor/lib/src/editor/flows/captions/interrupted_notice.dart`
  - `packages/danaview_editor/lib/src/settings/captions_settings_section.dart`
  - `packages/danaview_editor/lib/src/app/speech_storage_contributor.dart`
  - `packages/danaview_editor/test/flows/regenerate/`
- **Spec:** ai.md §10.3, §11.5: Regenerate sheet from the subtitle track menu (re-split instantly from cached transcripts with a new preset, or transcribe again; confirm when cues were edited after generation; replace whole track or clip range via ReplaceGeneratedCaptions), interrupted-job notice on editor open (resumableFor -> Resume / Discard), captions settings section in EditorSettingsScreen (model status, size, delete — blocked while a job runs; default preset), SpeechStorageContributor ('Speech model' with delete).
- **Acceptance criteria and tests:** widget tests: instant re-split <= 300 ms for 30 min of speech with the fake; edited-cues confirm; resume notice after a simulated kill; delete blocked during a job; matrix tests.

#### UX-39 · Export sheet, export controller, progress, handoff

- **Milestone:** M5 · **Area:** UI/UX
- **Depends on:** UX-08, CORE-33, API-04
- **Owns:**
  - `packages/danaview_editor/lib/src/editor/flows/export/`
  - `packages/danaview_editor/lib/src/editor/actions/bindings/export_bindings.dart`
  - `packages/danaview_editor/lib/src/app/strings/export_strings.dart`
  - `packages/danaview_editor/test/flows/export/`
- **Spec:** ARCH §14.1, ux.md §11, D-23/D-24: pre-checks (missing media -> relink sheet; pending reverse/freeze -> wait or cancel; empty timeline; free space vs estimate; first-export background notice; Android 13+ notification permission in context), presets (YouTube, YouTube 4K, Shorts, Reels, Instagram Feed, TikTok) and custom settings gated by capabilities (resolution, fps Match project (default) or 24/25/30/48/50/60, container MP4/MOV*, codec H.264/H.265*, quality, video and audio bitrate), aspect-mismatch notice, size estimate, burn-in per subtitle track and SRT/VTT side files, sprite pre-pass ('Preparing') via API-04 SpritePrepass, compileExport, preflight warnings, start; non-dismissible progress with phase/ETA/backgrounded copy per BackgroundExportKind (iPhone `paused`: 'Keep Danaview open while exporting. If you leave, the export pauses and continues from where it stopped when you come back.'; Android: 'You can leave Danaview; you'll get a notification when it's done.'; iPad `continued`: system progress), cancel with confirm (deletes partial), completion (Save to Photos/Gallery default, Files, Share, 'Keep a copy in Danaview' to Documents/Exports **only through core DocumentsExportWriter** (D-44), Play in Danaview), temp file deletion via OwnedFileDeleter, failure fallbacks (Export with H.264, Lower resolution, free space), reattach via activeJobs: running → progress, resumable → 'Resume export', interrupted → one-shot notice, completedWhileDetached → one-shot 'Your export finished' card with Share / Save to Files / Delete ('Saved to Gallery' shown when it was saved natively; D-39). Editing is blocked while exporting.
- **Acceptance criteria and tests:** widget tests with fakes for every pre-check, preset, gating, warning, progress state (incl. pausedInBackground copy), cancel, completion destination, resume, completed-while-detached card and failure; Custom fps list incl. 48 and Match project; 'Keep a copy' with a pre-existing Documents/Exports file of the same name leaves it untouched and creates '<name> (2).mp4'; temp file deleted; matrix tests.

#### UX-40 · Missing media, relink, recovery and migration UX

- **Milestone:** M5 · **Area:** UI/UX
- **Depends on:** UX-05, UX-08, CORE-26, CORE-28
- **Owns:**
  - `packages/danaview_editor/lib/src/editor/flows/relink/`
  - `packages/danaview_editor/lib/src/editor/state/media_health_controller.dart`
  - `packages/danaview_editor/lib/src/projects/recovery_banner.dart`
  - `packages/danaview_editor/lib/src/editor/actions/bindings/relink_bindings.dart`
  - `packages/danaview_editor/lib/src/app/strings/relink_strings.dart`
  - `packages/danaview_editor/test/flows/relink/`
- **Spec:** ux.md §13: MediaHealthController over watchAvailability (open, resume, after relink) driving the editor banner and offline placeholders; Relink sheet (per missing asset: pick replacement -> checkRelink outcome copy match/durationMismatch/differentKind/unsupported; 'Find in same folder' only for path locators; 'Use updated file' for changed; **'Relink several'**: one multi-pick from Photos or Files -> autoMatch proposals -> confirm list (unassigned picks and assets shown) -> one undoable relink; apply as one undoable relink); recovery dialog on open (pendingRecovery: Restore / Open last saved) and RecoveryBanner on the Projects screen (recoverable sessions); migration toast (migratedFrom) and newer-schema read-only banner / blocked state (D-12); corrupt project 'Restore last good version'.
- **Acceptance criteria and tests:** widget tests with fakes for every availability state, relink outcome, recovery choice, migration and newer-schema state; relink is one history entry; 10 missing Photos assets relinked in one pick session via Relink several; matrix tests.

#### UX-41 · Player 'Edit' action, EditorLauncher and player handoff

- **Milestone:** M5 · **Area:** UI/UX
- **Depends on:** UX-02, UX-07, UX-08, CORE-25
- **Owns:**
  - `packages/danaview_features/lib/src/player/danaview_controls_overlay.dart`
  - `packages/danaview_features/lib/src/player/danaview_player_screen.dart`
  - `packages/danaview_features/lib/src/controllers/player_controller.dart`
  - `packages/danaview_features/lib/src/settings/danaview_settings_panel.dart`
  - `packages/danaview_editor/lib/src/app/editor_launcher.dart`
  - `packages/danaview_editor/lib/src/app/strings/launcher_strings.dart`
  - `test/editor_entry/player_edit_action_test.dart`
  - `packages/danaview_editor/test/app/launcher/`
- **Spec:** ARCH §17.1, ux.md §4.4/§4.6: DanaviewPlayerScreen.onEditVideo(PlayerEditRequest{media, position, wasPlaying}) optional callback (null hides); top-bar DanaviewIconButton(Icons.movie_edit) 'Edit video (E)' first in the trailing group, 'Edit video' row in the Playback more sheet, E key, and an 'E – Edit video' line in the player's Keyboard Shortcuts cheat sheet (danaview_settings_panel.dart) shown only when onEditVideo != null; shown only for local media on supported platforms; **hidden while the player controls are locked** (E ignored); unsupported local formats and devices below the editor gate (android_too_old, gles3_missing, insufficient_memory) show the button and explain on tap. PlayerController handoff extension: suspend(pause | release on lowMemoryDevice) and resumeAfterEditor (restore paused at the original position). EditorLauncher.openFromPlayer: pause -> File.exists + engine.compatibility (<= 300 ms; platform copy e.g. iOS MKV) -> repository.findUntouchedProjectFor(path) or create(fromMedia, initialPlayhead: position) ('Preparing editor…' after 300 ms; managed copies such as the Android 'open with' cache go through UX-06's ImportMediaSheet flow with a free-space preflight (size + 64 MB), copy progress and Cancel) -> PlayerHandoff.suspend -> open the editor through a navigation callback supplied by the router (INT-04 pushes /editor/:id?t=<µs>) -> when that route pops, resumeAfterEditor and orientation restore.
- **Acceptance criteria and tests:** widget tests: visibility rules (local vs stream, platform, controls locked → hidden), E shortcut (ignored while locked), cheat-sheet line present only with the callback, unsupported dialog copy per platform and per device reason, untouched-project reuse, exact position passed, managed-copy cancel deletes the partial copy and free-space refusal shows copy, return restores paused + orientation; top bar **and the Playback more sheet's 'Edit video' row** have no overflow at 280 px @1.35; existing player tests pass unchanged.

#### UX-42 · Privacy policy and terms update, custom licences screen, About row

- **Milestone:** M5 · **Area:** UI/UX
- **Depends on:** —
- **Owns:**
  - `packages/danaview_features/lib/src/more/legal_texts.dart`
  - `packages/danaview_features/lib/src/more/danaview_licenses_screen.dart`
  - `packages/danaview_features/lib/src/more/danaview_about_screen.dart`
  - `packages/danaview_features/lib/licenses.dart`
  - `test/editor_entry/legal_texts_test.dart`
- **Spec:** ARCH §20.3 text verbatim (summary 'The only extra download is the optional speech model…', stored-on-device bullets qualified 'On iPhone, iPad and Android' incl. the Android backup sentence, 'Speech model for Auto captions' entry in the existing 'connects to the internet only when you ask it to' section naming huggingface.co and hf.co, files and permissions, choices) and terms changes; legalEffectiveDate bumped to the release date; DanaviewLicensesScreen (custom; no Material LicensePage) listing LicenseRegistry entries plus whisper.cpp/ggml (MIT), OpenAI Whisper weights (MIT), Silero VAD (MIT, V-A12 copyright line verified), AndroidX Media3 (Apache-2.0), content fonts and Figtree (OFL-1.1), mpv/FFmpeg (LGPL) notices; DanaviewAboutScreen gets an optional onOpenLicenses callback row 'Open-source licences'; lib/licenses.dart exports the screen for the router.
- **Acceptance criteria and tests:** unit test asserts policy strings contain 'huggingface.co' and 'hf.co' and the new effective date, that the summary no longer says 'starts on its own', and that every editor/Auto captions bullet carries the platform qualifier; licences screen renders all entries with no overflow at 280 px @1.35; no Material chrome.

### M6: Hardening, QA and release

#### INT-05 · [INTEGRATION] Release 1.1.0: flags, version, release pipelines, store metadata, docs

- **Milestone:** M6 · **Area:** Integration
- **Depends on:** QA-01, QA-02, QA-03, QA-04, QA-05, QA-07, QA-08, QA-09, QA-10, CORE-35, UX-43, INT-03, INT-04, QA-11
- **Owns:**
  - `pubspec.yaml`
  - `.github/workflows/android-release.yml`
  - `.github/workflows/linux-release.yml`
  - `.github/workflows/windows-release.yml`
  - `ios/fastlane/Fastfile`
  - `android/fastlane/Fastfile`
  - `ios/fastlane/metadata/`
  - `android/fastlane/metadata/`
  - `docs/v1.1/editor/release-checklist.md`
  - `docs/v1.1/editor/user-guide.md`
  - `README.md`
  - `docs/v1.1/editor/ARCHITECTURE.md`
- **Spec:** [INTEGRATION] ARCH §23 release checklist: version 1.1.0+3; release builds pass --dart-define=DANAVIEW_EDITOR=true --dart-define=DANAVIEW_AUTO_CAPTIONS=true on iOS and Android (desktop builds keep the editor hidden); Android release workflow runs scripts/ci/editor/check_native_libs.sh on the AAB; iOS fastlane builds the whisper xcframework before `flutter build ipa`; store metadata (descriptions mention video editing and on-device Auto captions with the one-time model download; release notes; screenshots via existing fastlane lanes; privacy labels unchanged; **publish the updated privacy policy and terms generated from legal_texts.dart at every store privacy URL** — iOS/macOS `privacy_url.txt` target https://vecvel.com/ios/danaview/privacy and the Play listing URL — with a diff or screenshot as evidence; iOS release lane runs check_ios_min_os.sh; Play FGS declaration text for dataSync 29-34 / mediaProcessing 35+; App Review note that the model is data, not code, V-A14); docs/v1.1/editor/release-checklist.md (filled ARCH §23 with links to every QA report), docs/v1.1/editor/user-guide.md (features and shortcuts), README architecture section; final ARCHITECTURE.md status updates (§24.2 closures only).
- **Acceptance criteria and tests:** every ARCH §23 item checked with evidence (incl. the hosted-policy diff and the D-43 sign-offs); release workflows dry-run green; App Store Connect validation and Play pre-launch report clean; tag-ready main.

#### CORE-35 · Core benchmarks, large-project fixture, README

- **Milestone:** M6 · **Area:** Core (pure Dart)
- **Depends on:** CORE-26, CORE-32, CORE-34, CORE-33
- **Owns:**
  - `packages/danaview_editor_core/benchmark/`
  - `packages/danaview_editor_core/test/fixtures/projects/large_2000.json`
  - `packages/danaview_editor_core/README.md`
- **Spec:** benchmark/run.dart measures every core row of ARCH §18.2 (apply/dryRun at 1,000 items, incremental compile + diff at 2,000, full compile + encode, open at 2,000, autosave block) in AOT on the CI host with a JSON baseline; `--check` fails on > 25% regression (wired by core.sh). large_2000.json: 2,000 items, 32 lanes, 3 h, 300 media, 3,000 cues. README: package boundaries, command-authoring checklist (purity, rejections as data, validator, fuzz registration), schema/migration procedure, plan versioning rules (ARCH §11.9).
- **Acceptance criteria and tests:** all core budgets met on the CI host (and recorded for one mid-tier Android and one iPhone through QA-04); regression gate active in dart-core; README reviewed.

#### UX-43 · Timeline picture-tile cache (conditional on QA-04 budget miss)

- **Milestone:** M6 · **Area:** UI/UX
- **Depends on:** QA-04
- **Owns:**
  - `packages/danaview_editor/lib/src/editor/timeline/timeline_tiles.dart`
  - `packages/danaview_editor/test/timeline/tiles/`
- **Spec:** Only if QA-04 shows a timeline UI/raster budget miss (ARCH §18.2 remedy order): picture-tile cache for RenderTimelineCanvas (tiles keyed by lane, zoom bucket and content stamps from Track.changedAt; invalidation on edits, zoom, thumbnails/waveform arrival), integrated behind a flag read by the canvas. If QA-04 passes, close as 'not needed' with the QA-04 numbers attached.
- **Acceptance criteria and tests:** when built: scroll/follow UI-thread time within budget on the low-tier device; invalidation tests; visual parity with direct painting (golden diff 0).

#### QA-00 · Shared on-device E2E suite (integration_test/editor)

- **Milestone:** M6 · **Area:** QA
- **Depends on:** INT-04, ENG-05, UX-05, UX-06, UX-11, UX-17, UX-20, UX-21, UX-23, UX-24, UX-25, UX-26, UX-27, UX-28, UX-29, UX-30, UX-32, UX-34, UX-35, UX-36, UX-38, UX-39, UX-40, UX-41, UX-42, IOS-13, IOS-14, IOS-15, IOS-16, AND-12, AND-13, AND-14, AND-15
- **Owns:**
  - `integration_test/editor/`
  - `docs/v1.1/editor/qa/README.md`
- **Spec:** ARCH §21.2 scenarios 1-18 as integration_test files running against the real app wiring with ENG-05 fixtures copied to the app sandbox and the tiny model pre-staged through ModelStore.installFromFile (no network): (1) Home edit button left of the gear opens Projects; (2) player -> Edit on frame_counter_1080p30.mp4 at 0:05:10 opens the editor with the playhead at 5 s + 10 frames and debugCaptureFrame barcode 160; (3) create/rename/duplicate/delete project; (4) split, trim, move with snap, ripple delete, undo/redo, copy/paste, duplicate; (5) text with animation, cue add/split/merge, SRT import and export round trip; (6) speed 2× and a ramp, reverse, freeze frame, cross dissolve, LUT import, chroma key, mask, keyframes; (7) export of a project built through the UI (typewriter text, one burned SRT track, one burn-in-off track, a LUT and a cross dissolve on frame_counter) at 720p H.264 MP4 verified with danaview_data MediaInspector (container, avc1, size, duration ±1 frame, AAC) and HEVC/MOV where capabilities allow, then frames pulled with the engine's freeze job: subtitle safe area differs from a burn-in-off export at each cue midpoint and is identical between cues, the burn-in-off track never appears, the typewriter glyph count increases across the in-animation, blended barcodes only inside [cut − d/2, cut + d/2), SRT/VTT side files parse back to the same cues; (8) auto captions with the tiny model on speech_10s.m4a (>= 1 cue, SRT parses back, one undo removes all); (9) recovery after app kill; (10) missing media + relink on a sandbox copy incl. Relink several; (11) background/foreground during playback (no black frame after 1 s); (12) hardware keyboard and pointer (Space/K, ←/→ barcode-checked frame step, Shift+←/→, S, Delete/Backspace, ⌘/Ctrl+Z, ⌘/Ctrl+Shift+Z, ⌘S inside a text field, ⌘C/⌘V/⌘D, Space after tapping a tool tile, wheel/Shift+wheel/⌘+wheel zoom, right-click menu, marquee); (13) voiceover: grant permission, record 3 s (simulator host mic / emulator virtual mic), WAV clip on a voice lane at playhead + latency, audible in export; (14) PiP video overlay moved, scaled and faded, then exported; (15) extract audio, then music with a fade-in; (16) add a marker and snap a clip to it; (17) ⌘X cut then paste; (18) close and reopen: timeline JSON, playhead and zoom equal. Background, foreground, kill and relaunch steps are driven by the e2e shell scripts (xcrun simctl / adb shell am, input keyevent) synchronized with the in-app test through a file handshake in the app sandbox; cross-app drags from Files/Photos are manual checklist steps with recorded evidence. Platform extras: Android FGS with activity destroyed, notification Cancel, swipe from recents mid-export → video in the Gallery + finished card on relaunch, interrupted record; iOS backgrounding mid-export → pausedInBackground then resume from the last segment with a conformant result; API 28 below-gate checks (QA-02). Helpers for gestures with the memory note: taps of 0.1 s, no parallel tap + screenshot. docs/v1.1/editor/qa/README.md explains how to run.
- **Acceptance criteria and tests:** suite compiles and passes locally on one simulator and one emulator before handing to QA-01/QA-02; flaky steps have explicit waits on engine acks or handshake files, not sleeps.

#### QA-01 · Run and certify the E2E suite on the iOS Simulator

- **Milestone:** M6 · **Area:** QA
- **Depends on:** QA-00, INT-03
- **Owns:**
  - `scripts/ci/editor/e2e_ios.sh`
  - `docs/v1.1/editor/qa/QA-01-ios-simulator.md`
- **Spec:** Run integration_test/editor on the iOS Simulator (iPhone 17 Pro, and iPad Pro with a connected hardware keyboard for scenario 12; iOS 26 runtime, plus scenarios 1-3 on the iOS 18.2 runtime) with --dart-define=DANAVIEW_EDITOR=true --dart-define=DANAVIEW_AUTO_CAPTIONS=true, and a launch + player + scenarios 1-4 smoke on the iPhone 7 (iOS 15.8) and iPhone 8 (iOS 16.7) lab devices (minimal tier, D-40/D-41); e2e_ios.sh boots devices, builds the whisper xcframework, runs `flutter test integration_test/editor -d <udid>`, collects screenshots, logs and exported files. Simulator realities (no hardware HEVC, software H.264, meaningless performance, no BG GPU) are reported, not failed. Defects are filed against the owning ticket's files as FIX tickets; this ticket re-runs until green.
- **Acceptance criteria and tests:** report with every scenario passing on both simulators, the manual iPad-simulator drop step (Files and Photos into the editor) recorded with screenshots, V-U5 certified, and the iOS 15.8 / 16.7 device smoke results recorded.

#### QA-02 · Run and certify the E2E suite on an Android Emulator

- **Milestone:** M6 · **Area:** QA
- **Depends on:** QA-00
- **Owns:**
  - `scripts/ci/editor/e2e_android.sh`
  - `docs/v1.1/editor/qa/QA-02-android-emulator.md`
- **Spec:** Run integration_test/editor on Android Emulators: API 35 x86_64 Pixel profile (full suite), API 29 (editor gate + core flows; GLES 3; also a 2 GB RAM low-RAM configuration for the minimal tier), API 34 (dataSync FGS export with activity destroyed, notification Cancel, swipe from recents mid-export), **API 28** (Home edit button shows, Projects shows the android_too_old copy, the player's Edit explains, the existing player test suite stays green), plus a tablet profile with keyboard and mouse for scenario 12 and the manual cross-app drag-and-drop step; e2e_android.sh creates AVDs, runs with the release dart-defines, collects logcat, screenshots and exports; process-death scenario via `adb shell am kill`. Emulator realities reported, not failed.
- **Acceptance criteria and tests:** report with every scenario passing on API 35, the gate/minimal/FGS checks on API 29/34, the API 28 below-gate checks and the tablet keyboard/mouse and manual drop evidence; artifacts attached.

#### QA-03 · Frame accuracy, grid-cut, A/V sync and render parity suite

- **Milestone:** M6 · **Area:** QA
- **Depends on:** IOS-11, AND-10, IOS-12, AND-11, API-03, ENG-05
- **Owns:**
  - `packages/danaview_editor_engine/example/integration_test/parity_test.dart`
  - `packages/danaview_editor_engine/example/integration_test/accuracy_test.dart`
  - `packages/danaview_editor_engine/example/integration_test/av_sync_test.dart`
  - `docs/v1.1/editor/qa/QA-03-parity.md`
- **Spec:** ARCH §21.1 'Parity, accuracy, A/V sync' on simulator, emulator and the device lab: frame-counter barcode exact seeks 200/200 (also inside speed segments and after structural patches); **grid-cut case (D-35)**: cuts at frames k ≡ 1 and 2 (mod 3) at 24, 30, 48 and 60 fps (frame_counter variants), every frame of a 3 s window around each cut shows the expected barcode in exact-seek preview, in playback capture and in export, on both platforms; clap/flash sync <= 1 frame and <= 20 ms in export and <= 1 frame and <= 40 ms in preview after latency compensation (§12.7, V-N23) at 1×, 2× keep-pitch, 0.5× ramp and across a cross dissolve; render parity of device output (debugCaptureFrame and exported frames) vs the API-03 reference within ARCH §11.6 tolerance, and iOS vs Android, incl. the 8× scale-keyframed text case; reverse barcode strictly decreasing; freeze barcode exact; proxy PTS equal. (Export conformance, presets and audio measurements are QA-11.)
- **Acceptance criteria and tests:** suite green on iOS simulator + Android emulator in CI (where meaningful) and on the device lab list (iPhone 7 iOS 15.8, iPhone 8 iOS 16.7, iPhone SE 2, iPhone 12, iPhone 15 Pro; 2–3 GB Android Go, 4 GB Android, Pixel 7a, Pixel 9/Galaxy S24, API 29 device); grid-cut case 100% on every device; report attached.

#### QA-11 · Export conformance, preset matrix and audio measurement suite

- **Milestone:** M6 · **Area:** QA
- **Depends on:** IOS-13, AND-12, IOS-18, API-03, ENG-05, IOS-20, AND-19, CORE-38
- **Owns:**
  - `packages/danaview_editor_engine/example/integration_test/conformance_test.dart`
  - `packages/danaview_editor_engine/example/integration_test/preset_matrix_test.dart`
  - `packages/danaview_editor_engine/example/integration_test/audio_mix_test.dart`
  - `docs/v1.1/editor/qa/QA-11-export-audio.md`
- **Spec:** ARCH §14.4 and §21.1 'Export conformance and audio' (review issues 6, 24, 26), split from QA-03 to keep both suites reviewable. (1) Conformance: container, avc1/hvc1, size, display orientation and rotation metadata, fps, frame count = duration × fps ± 1, AAC 48 kHz stereo, bitrate ±25%, hardware-encoder flag; fixtures include no audio, everything muted, everything soloed out and images/text only. (2) **Preset matrix**: every preset (YouTube 1080p, YouTube 4K where capabilities allow, YouTube Shorts 1080×1920, Instagram Reels 1080×1920, Instagram Feed 1080×1350, TikTok 1080×1920, Custom 48 fps) exported on the API 35 emulator, the iOS simulator and the low- and mid-tier lab devices; a refused portrait encoder size must take the landscape-plus-rotation retry or fail visibly with encoderSizeLimit — never silently. (3) **Audio**: (a) tone_1khz exported at 2× and 0.5× with keep-pitch on keeps the dominant FFT bin within ±2% of 1 kHz, with keep-pitch off it moves to 2 kHz / 500 Hz; (b) a 3-lane project (music at 40% with fade in and out, voice with volume keyframes, one muted lane, one soloed lane, a cross dissolve with audio) exported and compared per 20 ms window with the API-03 Dart reference mixer (RMS ±0.5 dB; muted and soloed-out lanes < −60 dBFS); (c) 200% vs 100% = +6.02 ± 0.1 dB; (d) speed-ramp seam click test (7-point ramp, keep pitch: no seam transient > −40 dBFS above the tone envelope); (e) preview PCM where capturable (iOS offline render of the AVPlayerItem mix; Android audio sink tap in debug builds) checked with the same reference.
- **Acceptance criteria and tests:** suite green on the iOS simulator and Android emulator in CI and on the low/mid lab devices; every preset row recorded with measured values; report attached.

#### QA-04 · Performance and memory budgets (profile mode, device lab)

- **Milestone:** M6 · **Area:** QA
- **Depends on:** INT-04, CORE-35, UX-44, AND-18, IOS-19
- **Owns:**
  - `packages/danaview_editor_engine/example/integration_test/perf_engine_test.dart`
  - `packages/danaview_editor/integration_test/perf/`
  - `docs/v1.1/editor/qa/QA-04-performance.md`
- **Spec:** Measure every ARCH §18.2 and §13.4/§14.4 budget in profile mode on low/mid/high devices (incl. the renegotiated Android structural budgets of §13.4 at 2/4/6 sequences) and the D-40 minimal-tier promise (no crash/OOM, ≥ 24 fps preview at ≤ 2 layers) on the iPhone 7, iPhone 8 and a 2–3 GB Android Go device: timeline fling/pinch UI and raster times (TimelineSummary), playback rebuild counts (UX-01 debug counters), commit -> preview latencies (PlanAck applyMs + texture frame timing), scrub lag, thumbnail miss latency, Dart heap with 1,000 items, autosave block, editor open -> first frame, Projects first paint, export speed, native compose times (signposts/GL timer queries), sprite pre-pass (V-D7), memory caps. Report includes pass/fail per row and, for misses, the remedy chosen (ARCH §18.2 order) and whether UX-43 is needed.
- **Acceptance criteria and tests:** report with every budget row measured on the named devices; misses either fixed via FIX tickets or renegotiated in writing by the lead.

#### QA-05 · Robustness soak

- **Milestone:** M6 · **Area:** QA
- **Depends on:** QA-00
- **Owns:**
  - `integration_test/editor_soak/`
  - `docs/v1.1/editor/qa/QA-05-soak.md`
- **Spec:** 1 h random-edit soak on one iOS device and one Android device (scripted random commands, gestures, play/scrub, export starts/cancels, auto captions with the tiny model), with interruptions (calls/Siri simulation, audio route change, background/foreground), low storage, media going offline mid-session, and process death during each job type (proxy, reverse, freeze, export, captions, autosave).
- **Acceptance criteria and tests:** no crash, no unhandled exception, memory growth <= 10% over the hour, every interrupted job recovers or reports interrupted once; project always reopens valid.

#### QA-06 · Auto captions benchmarks, accuracy evaluation and tuning

- **Milestone:** M6 · **Area:** QA
- **Depends on:** AI-13, AI-07
- **Owns:**
  - `packages/danaview_transcription/lib/src/catalog/tuning.dart`
  - `packages/danaview_transcription/tool/eval/`
  - `integration_test/editor_ai/ai_benchmark_test.dart`
  - `docs/v1.1/editor/ai-eval.md`
  - `scripts/ci/editor/nightly.d/ai_eval.sh`
- **Spec:** ai.md §14 and §16.5: eval harness (WER/CER, boundary error, hallucination rate on music/silence clips) over a licensed multilingual set; device benchmarks of Fast/Balanced/Accurate on the device matrix replacing ARCH §18.2 estimates; decide and record RAM gating, A12 vs A13 Metal policy and first Metal init time (V-A4), q5_1 vs q8_0 on Android, VAD and threshold defaults, CJK/Korean CPS (V-A10), qualityHint; write the decided constants into catalog/tuning.dart; nightly eval script.
- **Acceptance criteria and tests:** docs/v1.1/editor/ai-eval.md with measured tables and decisions; tuning.dart updated with tests still green; nightly eval job runs.

#### QA-07 · Auto captions on-device E2E and AI device matrix

- **Milestone:** M6 · **Area:** QA
- **Depends on:** QA-06, UX-38, INT-04
- **Owns:**
  - `integration_test/editor_ai/ai_captions_test.dart`
  - `docs/v1.1/editor/qa/QA-07-ai.md`
- **Spec:** ai.md §16.4 scenarios on the device matrix and on simulator/emulator: consent shown before any network access, download with resume after kill (real network on devices, pre-staged model in CI), language explicit and detect paths, 60 s English Balanced run within the measured budget, iOS background pause/resume, Android FGS lease keeps running, thermal and export pausing observed, regenerate (instant re-split and full), SRT/VTT export of generated captions (parsed back to the same cues), burn-in in an exported video verified with QA-00 scenario 7's method (frames pulled at each cue midpoint differ from a burn-in-off export in the subtitle safe area and are identical between cues), undo removes all, offline after download, model deletion asks for consent again.
- **Acceptance criteria and tests:** report with all scenarios green; confirms DANAVIEW_AUTO_CAPTIONS may default on in release builds (INT-05).

#### QA-08 · Accessibility pass (guidelines, VoiceOver, TalkBack)

- **Milestone:** M6 · **Area:** QA
- **Depends on:** UX-05, UX-06, UX-11, UX-17, UX-20, UX-21, UX-23, UX-24, UX-25, UX-26, UX-27, UX-28, UX-29, UX-30, UX-32, UX-34, UX-35, UX-36, UX-38, UX-39, UX-40, UX-41, UX-42, UX-44
- **Owns:**
  - `packages/danaview_editor/test/a11y/`
  - `docs/v1.1/editor/qa/QA-08-a11y.md`
- **Spec:** ARCH §17.9: automated guideline tests (labeled tap targets >= 44×44, text contrast >= 4.5:1, semantics on painted elements, custom actions on clips/keyframes/transitions/markers, adjustable playhead, live announcements throttled, reduced motion, RTL chrome mirroring with LTR time axis) across Projects, editor layouts, every panel and flow; manual VoiceOver and TalkBack scripts executed on one iOS and one Android device with results recorded. Defects go to the owning tickets as FIX tickets.
- **Acceptance criteria and tests:** guideline tests green; manual checklist complete with no blocker.

#### QA-09 · No-overflow matrix suite (full nightly, PR subset)

- **Milestone:** M6 · **Area:** QA
- **Depends on:** UX-05, UX-06, UX-11, UX-17, UX-20, UX-21, UX-23, UX-24, UX-25, UX-26, UX-27, UX-28, UX-29, UX-30, UX-32, UX-34, UX-35, UX-36, UX-38, UX-39, UX-40, UX-41, UX-42, UX-44
- **Owns:**
  - `packages/danaview_editor/test/overflow/`
  - `scripts/ci/editor/nightly.d/overflow_full.sh`
  - `docs/v1.1/editor/qa/QA-09-overflow.md`
- **Spec:** ARCH §1.3 rule 5 and §17.9: every editor surface and state (Projects, new project, editor in 4 layouts with every inspector panel and flow sheet, export, captions, relink, recovery, settings, licences, home header, player top bar, the player's Playback more sheet with the 'Edit video' row, the player shortcuts cheat sheet) rendered with long-content fixtures over widths 280-1280 (the listed sizes incl. 280×500 and 568×320), text scale 0.85/1.0/1.35, keyboard inset none/40%; asserts takeException() == null, expectInside, fitsFully; PR subset of 6 surfaces (incl. 280×500 @1.35 and 568×320 @1.35) tagged for flutter-packages CI; full matrix nightly.
- **Acceptance criteria and tests:** full matrix green nightly; PR subset green; failures reproduce with a single command.

#### QA-10 · Persistence, crash recovery and media-access survival on device

- **Milestone:** M6 · **Area:** QA
- **Depends on:** INT-04, IOS-15, AND-14, CORE-26, CORE-28
- **Owns:**
  - `integration_test/editor_store/`
  - `docs/v1.1/editor/qa/QA-10-persistence.md`
- **Spec:** On simulator/emulator and one physical device per platform: crash recovery after a forced kill restores the last edits (journal), corrupt-file restore path, migration fixture opened read-only/blocked per D-12, iOS Files bookmark and Android persisted URI grant survive an app restart (V-D2, V-D3), **reinstall over the top on device (new iOS container UUID) → the project opens with zero missing media**, excluded directories absent from backup (iOS attribute read-back V-D4; Android bmgr procedure shows the editor and speech trees excluded, V-A7), fsync behaviour evidence (V-D1), and after a full editing session including an export with 'Keep a copy', relink, project delete and GC: for every original and every file under Documents, size, hash, mtime and xattrs are unchanged, and no parent folder of an original gains sidecar or temp files (D-44).
- **Acceptance criteria and tests:** report with each check passing and the evidence attached.

## 7. Shared and integration file register

These are the only paths edited by more than one ticket. The order is mandatory (each later ticket depends on the earlier one).

| Path | Tickets, in order | What each edit does |
|---|---|---|
| `ios/Runner.xcodeproj/project.pbxproj` | INT-01 → INT-03 | deployment target 15.0 → entitlements file and Runner privacy manifest references |
| `lib/main.dart`, `lib/router/app_router.dart` | INT-02 → INT-04 | editor bootstrap, `/projects`, `/editor/:id`, `/settings/editor`, Home/Settings callbacks → transcription service, adapters, player `onEditVideo`, `/settings/licenses`, LicenseRegistry |
| `pubspec.yaml` (root) | INT-02 → INT-04 → INT-05 | add danaview_editor, danaview_editor_engine, integration_test → add danaview_transcription, danaview_whisper → version 1.1.0+3 |
| `packages/danaview_editor_engine/{pigeons/, lib/src/pigeon/, lib/src/mobile_editor_engine.dart, ios/Classes/Pigeon/, android/.../pigeon/}` | ENG-01 → ENG-06 → INT-06 | Pigeon surface and Dart engine → spike outcomes, then frozen → `JobKindMsg.renderPreview` and its request fields, `PreviewHostApi.setRenderedRanges`, `powerState` (ARCH D-45), before UX-44, IOS-19 and AND-18 call them |
| `packages/danaview_editor_engine_api/lib/src/{preview,media_services,platform_services}.dart`, `lib/src/fake/`, `test/contract/`, `packages/danaview_editor_engine/lib/src/{mobile_preview_session,mobile_jobs,mobile_platform_services}.dart`, `ios/Classes/Glue/`, `android/.../glue/` | API-01, ENG-02, ENG-03, ENG-07 / ENG-08 → INT-06 | contract and glue → the D-45 additions only (`renderPreview`, `setRenderedRanges`/`RenderedRange`, `powerState`, fake support, contract-kit cases) |
| `packages/danaview_editor_engine/{ios/danaview_editor_engine.podspec, ios/Classes/DanaviewEditorEnginePlugin.swift, android/build.gradle.kts, android/src/main/AndroidManifest.xml, android/.../DanaviewEditorEnginePlugin.kt}` | ENG-01 (minimal placeholders) → ENG-07 / ENG-08 → ENG-06 (podspec, Gradle) | plugin builds from M0 → real glue, flags and manifest → spike build settings, then frozen |
| `packages/danaview_editor_engine/{ios/Classes/Glue/, android/.../glue/, android/lint.xml}` | ENG-07 / ENG-08 → ENG-06 | glue and lint opt-ins → spike amendments, then frozen |
| `packages/danaview_editor_engine/test/glue/` | ENG-01 → INT-06 | glue tests → tests for the D-45 additions |
| `packages/danaview_editor_core/lib/src/ops/limits.dart`, `packages/danaview_editor_core/test/ops/framework/` | CORE-09 → CORE-38 | layer limits enforced after every command → the two layer caps become the informational `aboveLivePreviewCap` state (D-14, D-45(B)); items and duration stay hard limits |
| `packages/danaview_editor_core/test/fixtures/vectors/frame_grid.json` | CORE-02 → ENG-06 | vectors → the measured `androidSeekMsRounding` field only |
| `docs/v1.1/editor/ARCHITECTURE.md` | INT-01 → ENG-06 → lead (owner decision 2026-10-11) → INT-06 → INT-05 | D-43 owner sign-off status → spike results in §5/§12.5/§13/§14.2/§24.2 → D-43(e) signed off, D-45 render-preview cache and multi-pass export → INT-06 recorded as the approved amendment in §12.6, §12.2–§12.4 and D-45 'Contract' → release status and [VERIFY] closures |
| `android/app/src/main/AndroidManifest.xml` | CORE-28 only | adds `android:dataExtractionRules` and `android:fullBackupContent` (no other edits) |
| `packages/danaview_ui_kit/lib/danaview_ui_kit.dart` | UI-01 only | export lines for the six new components |
| Placeholder files (§2) | skeleton ticket → owner ticket | owner replaces the placeholder |

Feature tickets in `danaview_features` touch disjoint files and add only optional parameters (`onOpenEditor` UX-03, `onOpenEditorSettings` UX-04, `onEditVideo` UX-41, `onOpenLicenses` UX-42), so the app keeps compiling before the integration tickets wire them.

## 8. Feature coverage (owner's list → tickets)

Every bullet of the owner's feature list, plus the entry points and product rules, maps to the tickets that implement it (core model/commands, UI, native engines) and, where relevant, the QA ticket that certifies it. "Desktop UX" bullets ship now on iPad/Android tablets with keyboards, mice and trackpads, and carry over unchanged to the later desktop engine (ARCH §25).

| Section | Feature | Tickets |
|---|---|---|
| Entry points | Edit icon button immediately left of the Home settings button | UX-03, INT-02, QA-00 |
| Entry points | Edit directly while playing a video (player Edit action at the current position) | UX-41, INT-04, QA-00 |
| Entry points | Desktop: entry points hidden or 'coming soon'; architecture ready for a desktop engine | UX-01, INT-02, INT-04, API-01 (hidden; D-17) |
| Project & Timeline | Create, save, rename, duplicate and reopen projects | CORE-25, CORE-26, UX-05, UX-06, UX-29, QA-00 (18) |
| Project & Timeline | Non-destructive editing | CORE-03, CORE-09, CORE-24, CORE-27, QA-10 |
| Project & Timeline | Multi-track timeline | CORE-03, CORE-17, UX-10, UX-11, UX-12 |
| Project & Timeline | Multiple video tracks | CORE-17, CORE-30, UX-11, IOS-08, AND-08 |
| Project & Timeline | Multiple audio tracks | CORE-17, CORE-31, UX-11, IOS-08, AND-08 |
| Project & Timeline | Text track | CORE-14, UX-30, UX-19, CORE-31 |
| Project & Timeline | Subtitle track | CORE-15, UX-31, UX-11 |
| Project & Timeline | Image/overlay tracks | CORE-17, CORE-30, UX-28, IOS-10, AND-08 |
| Project & Timeline | Timeline zoom and horizontal scrolling | UX-09, UX-12 |
| Project & Timeline | Playhead and time ruler | UX-09, UX-10, UX-14 |
| Project & Timeline | Snapping to clips, markers and playhead | CORE-18, UX-13 |
| Project & Timeline | Clip selection and multi-selection | CORE-11, UX-12, UX-13, CORE-15 (select all on lane) |
| Project & Timeline | Track lock/unlock | CORE-17, UX-11 |
| Project & Timeline | Track visibility | CORE-17, CORE-30, UX-11 |
| Project & Timeline | Track mute/solo | CORE-17, CORE-31, UX-11 |
| Project & Timeline | Clip thumbnails | IOS-03, AND-03, UX-20 |
| Project & Timeline | Audio waveforms | IOS-04, AND-04, UX-21 |
| Project & Timeline | Clip duration and metadata | UX-10, UX-35, IOS-02, AND-02 |
| Project & Timeline | Undo/redo history | CORE-19, UX-08, UX-29, UX-15 |
| Basic Editing | Import video, audio and images | CORE-27, UX-06, UX-36, IOS-15, AND-14 |
| Basic Editing | Cut | CORE-11, UX-13, UX-15, QA-00 (17) |
| Basic Editing | Trim | CORE-10, UX-13 |
| Basic Editing | Split | CORE-10, UX-13 |
| Basic Editing | Delete | CORE-10, UX-13 |
| Basic Editing | Duplicate | CORE-11, UX-13 |
| Basic Editing | Copy/paste | CORE-11, UX-13 |
| Basic Editing | Move clips | CORE-10, UX-13 |
| Basic Editing | Ripple delete | CORE-10, UX-13 |
| Basic Editing | Ripple insert | CORE-10, UX-36 |
| Basic Editing | Replace media | CORE-11, UX-35, UX-36 |
| Basic Editing | Freeze frame | CORE-12, IOS-06, AND-06, UX-35 |
| Basic Editing | Reverse video | CORE-12, IOS-07, AND-07, UX-35 |
| Basic Editing | Frame-accurate seeking | CORE-02, CORE-29, IOS-08, IOS-10, IOS-11, AND-08, AND-10, UX-14, QA-03 (grid-cut case) |
| Basic Editing | Markers | CORE-17, UX-17, UX-09, QA-00 (16) |
| Video Transform | Position | CORE-13, CORE-07, UX-22, UX-23, IOS-10, AND-09 |
| Video Transform | Scale | CORE-13, CORE-07, UX-22, UX-23, IOS-10, AND-09 |
| Video Transform | Rotation | CORE-13, CORE-07, UX-22, UX-23, IOS-10, AND-09 |
| Video Transform | Horizontal flip | CORE-13, UX-23, IOS-10, AND-09 |
| Video Transform | Vertical flip | CORE-13, UX-23, IOS-10, AND-09 |
| Video Transform | Crop | CORE-13, UX-23, IOS-09, AND-09 |
| Video Transform | Opacity | CORE-13, UX-23, IOS-10, AND-09 |
| Video Transform | Aspect ratio | CORE-17, UX-29, CORE-33 |
| Video Transform | Direct manipulation in preview | UX-22, CORE-32, IOS-11, AND-10 |
| Video Transform | Reset transform | CORE-13, UX-23 |
| Speed | 0.25x, 0.5x, 0.75x, 1x, 1.25x, 1.5x, 2x, 3x, 4x | CORE-12, UX-25, IOS-08, AND-08 |
| Speed | Custom speed | CORE-12, UX-25 |
| Speed | Speed ramping | CORE-06, CORE-12, CORE-30, UX-25 |
| Speed | Maintain audio pitch | CORE-12, CORE-31, IOS-08, AND-08, QA-11 (FFT) |
| Speed | Proper A/V synchronization | CORE-06, CORE-31, IOS-08, IOS-18, AND-08, QA-03, QA-11 |
| Text | Add text overlays | CORE-14, UX-30, UX-19, API-04 |
| Text | Font selection | UX-30, API-04 |
| Text | Font size | CORE-14, UX-30, API-04, UX-19 |
| Text | Bold/italic | CORE-14, UX-30, API-04, UX-19 |
| Text | Alignment | CORE-14, UX-30, API-04, UX-19 |
| Text | Text color | CORE-14, UX-30, API-04, UX-19 |
| Text | Opacity | CORE-14, UX-30, API-04, UX-19 |
| Text | Letter spacing | CORE-14, UX-30, API-04, UX-19 |
| Text | Line spacing | CORE-14, UX-30, API-04, UX-19 |
| Text | Background | CORE-14, UX-30, API-04, UX-19 |
| Text | Border/stroke | CORE-14, UX-30, API-04, UX-19 |
| Text | Shadow | CORE-14, UX-30, API-04, UX-19 |
| Text | Position | CORE-14, UX-22, UX-30 |
| Text | Rotation | CORE-14, UX-22, UX-30 |
| Text | Scale | CORE-14, UX-22, UX-30 |
| Text | Text duration | CORE-14, UX-13, UX-30 |
| Text | Text animations: Fade | CORE-07, CORE-31, UX-30, UX-19, API-04, IOS-09, AND-09 |
| Text | Text animations: Slide | CORE-07, CORE-31, UX-30, UX-19, API-04, IOS-09, AND-09 |
| Text | Text animations: Scale | CORE-07, CORE-31, UX-30, UX-19, API-04, IOS-09, AND-09 |
| Text | Text animations: Typewriter | CORE-07, CORE-31, UX-30, UX-19, API-04, IOS-09, AND-09 |
| Subtitles | Create subtitles manually | CORE-15, UX-31 |
| Subtitles | Edit subtitle text | CORE-15, UX-31 |
| Subtitles | Adjust start/end timing | CORE-15, UX-31, UX-13 |
| Subtitles | Move subtitles | CORE-15 (incl. ShiftCues), UX-13, UX-31 |
| Subtitles | Split subtitles | CORE-15, UX-31 |
| Subtitles | Merge subtitles | CORE-15, UX-31 |
| Subtitles | Delete subtitles | CORE-15, UX-31 |
| Subtitles | Subtitle styling | CORE-15, UX-31, API-04, UX-19 |
| Subtitles | Subtitle positioning | CORE-15, UX-31, UX-22 |
| Subtitles | Subtitle track | CORE-15, UX-31, UX-11 |
| Subtitles | Import SRT | CORE-20, UX-32 |
| Subtitles | Import VTT | CORE-20, UX-32 |
| Subtitles | Export SRT | CORE-20, UX-32, UX-39 |
| Subtitles | Export VTT | CORE-20, UX-32, UX-39 |
| Subtitles | Burn subtitles into video | CORE-31, CORE-33, API-04, IOS-10, AND-09, UX-39, QA-00 (7) |
| AI Subtitles | Generate subtitles directly from video/audio | AI-13, UX-37, INT-04 |
| AI Subtitles | User selects subtitle language | AI-08, UX-37 |
| AI Subtitles | Extract audio from media | IOS-04, AND-04, INT-04 |
| AI Subtitles | Speech-to-text | AI-01, AI-03, AI-04, AI-05, AI-07 |
| AI Subtitles | Timestamped transcription | AI-03, AI-10, AI-12 |
| AI Subtitles | Automatic subtitle segmentation | AI-11 |
| AI Subtitles | Insert generated subtitles directly into timeline | CORE-15, AI-13, UX-37 |
| AI Subtitles | Fully editable generated subtitles | CORE-15, UX-31 |
| AI Subtitles | Regenerate subtitles | AI-13, UX-38 |
| AI Subtitles | Export generated subtitles as SRT/VTT | CORE-20, UX-32, QA-07 |
| AI Subtitles | Burn generated subtitles into exported video | CORE-33, UX-39, QA-07 (QA-00 scenario 7 method) |
| AI Subtitles | No other AI features in v1 | AI-08, QA-07 |
| AI Subtitles | On-device whisper.cpp; model downloaded on first use with consent; offline afterwards; privacy text names the host | AI-09, UX-37, UX-42, INT-04 |
| Audio | Multiple audio tracks | CORE-17, UX-11, IOS-08, AND-08, QA-11 (3-lane mix) |
| Audio | Import audio | CORE-27, UX-06, UX-33 |
| Audio | Extract audio from video | CORE-11, UX-33, QA-00 (15) |
| Audio | Trim audio | CORE-10, UX-13 |
| Audio | Split audio | CORE-10, UX-13 |
| Audio | Move audio | CORE-10, UX-13 |
| Audio | Duplicate audio | CORE-11, UX-13 |
| Audio | Delete audio | CORE-10, UX-13 |
| Audio | Volume control | CORE-13, CORE-31, UX-33, IOS-18, AND-08, QA-11 (+6 dB, RMS) |
| Audio | Fade in/out | CORE-13, CORE-31, UX-33, UX-13, IOS-18, QA-11 |
| Audio | Mute | CORE-13, CORE-17, UX-33, UX-11, QA-11 (< −60 dBFS) |
| Audio | Audio waveform | IOS-04, AND-04, UX-21 |
| Audio | Background music | CORE-17, UX-33, QA-00 (15), QA-11 |
| Audio | Voice recording where supported | IOS-14, AND-13, UX-34, QA-00 (13) |
| Audio | Audio synchronization | CORE-31, IOS-08, AND-08, QA-03, QA-11 |
| Video Effects | Brightness | CORE-13, UX-24, IOS-09, AND-09, API-03 |
| Video Effects | Contrast | CORE-13, UX-24, IOS-09, AND-09, API-03 |
| Video Effects | Saturation | CORE-13, UX-24, IOS-09, AND-09, API-03 |
| Video Effects | Exposure | CORE-13, UX-24, IOS-09, AND-09, API-03 |
| Video Effects | Highlights | CORE-13, UX-24, IOS-09, AND-09, API-03 |
| Video Effects | Shadows | CORE-13, UX-24, IOS-09, AND-09, API-03 |
| Video Effects | Temperature | CORE-13, UX-24, IOS-09, AND-09, API-03 |
| Video Effects | Tint | CORE-13, UX-24, IOS-09, AND-09, API-03 |
| Video Effects | Sharpness | CORE-13, UX-24, IOS-09, AND-09, API-03 |
| Video Effects | Blur | CORE-13, UX-24, IOS-09, AND-09, API-03 |
| Video Effects | Vignette | CORE-13, UX-24, IOS-09, AND-09, API-03 |
| Video Effects | Opacity | CORE-13, UX-23, UX-24, IOS-10, AND-09 |
| Color & LUT | Brightness | CORE-13, UX-24, IOS-09, AND-09, API-03 |
| Color & LUT | Contrast | CORE-13, UX-24, IOS-09, AND-09, API-03 |
| Color & LUT | Saturation | CORE-13, UX-24, IOS-09, AND-09, API-03 |
| Color & LUT | Exposure | CORE-13, UX-24, IOS-09, AND-09, API-03 |
| Color & LUT | Highlights | CORE-13, UX-24, IOS-09, AND-09, API-03 |
| Color & LUT | Shadows | CORE-13, UX-24, IOS-09, AND-09, API-03 |
| Color & LUT | Temperature | CORE-13, UX-24, IOS-09, AND-09, API-03 |
| Color & LUT | Tint | CORE-13, UX-24, IOS-09, AND-09, API-03 |
| Color & LUT | Color presets | UX-24, CORE-21, IOS-09, AND-09 |
| Color & LUT | LUT support | CORE-21, IOS-09, AND-09, API-03 |
| Color & LUT | .cube LUT import | CORE-21, CORE-27, UX-24 |
| Color & LUT | LUT intensity | CORE-13, UX-24, IOS-09, AND-09 |
| Transitions | Fade | CORE-16, CORE-31, UX-27, QA-03 |
| Transitions | Cross dissolve | CORE-16, CORE-31, UX-27, QA-03 |
| Transitions | Dip to black | CORE-16, CORE-31, UX-27, QA-03 |
| Transitions | Dip to white | CORE-16, CORE-31, UX-27, QA-03 |
| Transitions | Slide | CORE-16, CORE-31, UX-27, QA-03 |
| Transitions | Wipe | CORE-16, CORE-31, UX-27, QA-03 |
| Transitions | Zoom | CORE-16, CORE-31, UX-27, QA-03 |
| Transitions | Transition duration | CORE-16, UX-27 |
| Transitions | Transition direction | CORE-16, CORE-31, UX-27 |
| Transitions | Transition preview | UX-27, IOS-11, AND-10, AND-17 (AND-16 on no-go) |
| Picture-in-Picture | Video over video | CORE-17, CORE-30, CORE-36, UX-28, IOS-10, AND-08, QA-00 (14) |
| Picture-in-Picture | Image over video | CORE-17, CORE-30, UX-28, IOS-09, AND-08 |
| Picture-in-Picture | Multiple overlays | CORE-17, UX-28, CORE-09, CORE-36 (packing) |
| Picture-in-Picture | Resize | UX-22, UX-28 |
| Picture-in-Picture | Move | UX-22, UX-28 |
| Picture-in-Picture | Rotate | UX-22, UX-28 |
| Picture-in-Picture | Crop | UX-23, UX-28 |
| Picture-in-Picture | Opacity | UX-23, UX-28 |
| Picture-in-Picture | Independent timeline control | CORE-10, UX-13, UX-28 |
| Chroma Key | Green screen | CORE-13, UX-28, IOS-09, AND-09 |
| Chroma Key | Custom key color | CORE-13, UX-28, IOS-09, AND-09, UX-23, IOS-06, AND-06 |
| Chroma Key | Similarity | CORE-13, UX-28, IOS-09, AND-09 |
| Chroma Key | Smoothness | CORE-13, UX-28, IOS-09, AND-09 |
| Chroma Key | Spill reduction | CORE-13, UX-28, IOS-09, AND-09 |
| Chroma Key | Preview | UX-28, IOS-10, AND-09, IOS-11, AND-10 |
| Masking | Rectangle mask | CORE-13, UX-23, IOS-09, AND-09 |
| Masking | Circle mask | CORE-13, UX-23, IOS-09, AND-09 |
| Masking | Position | CORE-13, UX-23, IOS-09, AND-09 |
| Masking | Size | CORE-13, UX-23, IOS-09, AND-09 |
| Masking | Feather | CORE-13, UX-23, IOS-09, AND-09 |
| Masking | Opacity | CORE-13, UX-23, IOS-09, AND-09 |
| Keyframes | Position keyframes | CORE-05, CORE-13, UX-26, CORE-30 |
| Keyframes | Scale keyframes | CORE-05, CORE-13, UX-26, CORE-30 |
| Keyframes | Rotation keyframes | CORE-05, CORE-13, UX-26, CORE-30 |
| Keyframes | Opacity keyframes | CORE-05, CORE-13, UX-26, CORE-30 |
| Keyframes | Volume keyframes | CORE-05, CORE-13, UX-26, CORE-30, CORE-31 |
| Keyframes | Basic effect keyframes | CORE-05, CORE-13, UX-26, CORE-30 |
| Keyframes | Add/remove keyframes | CORE-13, UX-26 |
| Keyframes | Move keyframes | CORE-13, UX-26, UX-13 |
| Keyframes | Edit keyframes | CORE-13, UX-26 |
| Keyframes | Linear interpolation | CORE-05, CORE-30, API-03 |
| Preview | Real-time timeline preview | ENG-02, IOS-11, AND-10, AND-17, UX-18, API-02 |
| Preview | Play/pause | UX-14, IOS-11, AND-10 |
| Preview | Frame/time seeking | UX-14, IOS-11, AND-10, QA-03 |
| Preview | Fullscreen preview | UX-18 |
| Preview | Preview quality options | UX-18, IOS-11, AND-10 (Auto adaptive full → 1/2 → 1/4 or pinned; D-43(e)) |
| Preview | Render preview (pre-rendered heavy ranges, timeline render marker, auto on minimal/low while idle and charging) | CORE-37, INT-06, UX-44, IOS-19, AND-18, QA-04 (D-45) |
| Preview | Smooth preview above the live decode budget (proxies, playback-only stills, render cache) | AND-16, IOS-11, UX-04, UX-44, AND-18, IOS-19, CORE-38 (D-43(e)) |
| Preview | Editing never blocked above the device's live-preview cap (`aboveLivePreviewCap` is informational) | CORE-38, CORE-36 (D-14, D-45(B)) |
| Preview | Current time/duration | UX-14 |
| Preview | Timeline-synchronized playback | UX-14, API-02, UX-10 |
| Export & Rendering | Real video rendering | IOS-12, AND-11, ENG-04, UX-39 |
| Export & Rendering | MP4 | IOS-12, AND-11, CORE-33 |
| Export & Rendering | MOV where supported | IOS-12, CORE-33, UX-39 |
| Export & Rendering | H.264 | IOS-12, AND-11 |
| Export & Rendering | H.265 where supported | IOS-02, AND-02, IOS-12, AND-11 |
| Export & Rendering | Resolution selection | CORE-33, UX-39 |
| Export & Rendering | FPS selection | CORE-33, UX-39 (Match project, 24–60 incl. 48) |
| Export & Rendering | Bitrate selection | CORE-33, UX-39 |
| Export & Rendering | Audio bitrate | CORE-33, UX-39 |
| Export & Rendering | Quality presets | CORE-33, UX-39 |
| Export & Rendering | YouTube preset | CORE-33, UX-39, QA-11 (preset matrix) |
| Export & Rendering | YouTube Shorts preset | CORE-33, UX-39, QA-11 (preset matrix) |
| Export & Rendering | Instagram preset | CORE-33, UX-39, QA-11 (preset matrix) |
| Export & Rendering | TikTok preset | CORE-33, UX-39, QA-11 (preset matrix) |
| Export & Rendering | Custom export settings | CORE-33, UX-39 |
| Export & Rendering | Export progress | ENG-04, UX-39 |
| Export & Rendering | Cancel export | IOS-12, AND-11, AND-12, UX-39 |
| Export & Rendering | Background rendering where supported | IOS-13, IOS-17, AND-12, INT-03 |
| Export & Rendering | Hardware-accelerated rendering where supported | IOS-12, AND-11, IOS-10, AND-09 |
| Export & Rendering | Export never refused on a supported device (multi-pass precompose above the decoder limit) | AND-19, IOS-20, AND-11, IOS-12, CORE-38, QA-11 (D-45) |
| Project Management | Autosave | CORE-26, UX-08 |
| Project Management | Manual save | CORE-25, UX-29, UX-15 |
| Project Management | Project recovery | CORE-26, UX-40, QA-10, IOS-17 (resumable export) |
| Project Management | Project duplication | CORE-25, UX-05 |
| Project Management | Project deletion | CORE-25, CORE-28, UX-05 |
| Project Management | Project version/schema migration | CORE-22, CORE-23, UX-40 |
| Project Management | Missing media detection | CORE-28, UX-40 |
| Project Management | Relink missing media | CORE-28, UX-40 (incl. Relink several) |
| Project Management | Project media management | CORE-27, CORE-28, UX-36, UX-04 |
| Project Management | Original media must never be modified, moved, renamed or deleted | CORE-24 (incl. DocumentsExportWriter), CORE-27, CORE-28, ENG-03, QA-10 |
| Performance | Thumbnail caching | IOS-03, AND-03, UX-20 |
| Performance | Waveform caching | IOS-04, AND-04, UX-21 |
| Performance | Proxy media | IOS-05, AND-05, CORE-27, CORE-30, UX-04, UX-44 (auto for > 2× speed; on by default on the minimal and low tiers, D-43(e)) |
| Performance | Render-preview cache for heavy ranges | CORE-37, INT-06, UX-44, IOS-19, AND-18, QA-04 (D-45) |
| Performance | Lazy timeline rendering | UX-10, UX-43 |
| Performance | Background processing | IOS-05, AND-05, UX-35 |
| Performance | Efficient timeline updates | CORE-32, API-02, UX-10 |
| Performance | Large project support | CORE-35, QA-04 |
| Performance | Desktop optimization | Deferred to the desktop engine (owner decision 1, ARCH §25). Ships now: the expanded pointer layout, tested at 1194×834 and 1280×800 (UX-07, QA-09) with keyboard and pointer (UX-12, UX-15, QA-00 scenario 12) |
| Performance | Mobile optimization | UX-07, QA-04 (incl. minimal tier, D-40) |
| Performance | Isolates/background workers where appropriate | CORE-25, CORE-30, API-02, UX-21, AI-07 |
| Desktop UX | Keyboard shortcuts | UX-15, QA-00 (12) on iPad simulator and tablet emulator |
| Desktop UX | Space/K: Play/Pause | UX-15, UX-14, QA-00 (12) |
| Desktop UX | Arrow keys: Frame/time navigation | UX-15, UX-14, QA-00 (12) |
| Desktop UX | S: Split | UX-15, UX-13 |
| Desktop UX | Delete: Delete selected clip | UX-15, UX-13 |
| Desktop UX | Ctrl/Cmd + Z: Undo | UX-15, UX-29 |
| Desktop UX | Ctrl/Cmd + Shift + Z: Redo | UX-15, UX-29 |
| Desktop UX | Ctrl/Cmd + S: Save | UX-15, UX-29 |
| Desktop UX | Ctrl/Cmd + C: Copy | UX-15, UX-13 |
| Desktop UX | Ctrl/Cmd + V: Paste | UX-15, UX-13 |
| Desktop UX | Ctrl/Cmd + D: Duplicate | UX-15, UX-13 |
| Desktop UX | Drag and drop media | UX-36, IOS-16, AND-15, QA-01/QA-02 (manual cross-app drop) |
| Desktop UX | Mouse timeline controls | UX-12, UX-13, QA-00 (12) |
| Mobile UX | Touch timeline | UX-12 |
| Mobile UX | Drag clips | UX-13 |
| Mobile UX | Trim handles | UX-13 |
| Mobile UX | Split controls | UX-13, UX-16 |
| Mobile UX | Pinch-to-zoom timeline | UX-12, UX-09 |
| Mobile UX | Long press | UX-12 (lift-and-move AC) |
| Mobile UX | Touch preview controls | UX-18 (tap / double-tap AC), UX-22 |
| Mobile UX | Bottom editing toolbar | UX-16 |
| Mobile UX | Bottom sheets | UX-29, UX-39, UX-11, UI-01 |
| Mobile UX | Tool tabs | UX-16 |
| Mobile UX | Touch-friendly controls | UX-07, UI-01, QA-08 |
| Mobile UX | Mobile-optimized inspector | UX-16, UI-01 |
| Mobile UX | Gesture-based positioning, scaling and rotation | UX-22 |
| Product rules | Autosave + recovery + schema migration | CORE-23, CORE-26, UX-40, QA-10 |
| Product rules | No overflow at 280-1280 px and text scale up to 1.35; custom components only; Figtree UI | UI-01, UX-01 (expectOwnerUiRules), INT-01 (features scan), QA-09 |
| Product rules | On-device verification on iOS Simulator and Android Emulator | QA-00, QA-01, QA-02 (plus iOS 15.8/16.7 lab devices, D-41) |

## 9. Corrections and decisions made while sequencing

These were contradictions or ordering problems found while writing this plan; ARCHITECTURE.md was corrected in place (row D-34).

1. `MediaAccessPort`, `PickedMedia`, `MediaStat` and `MediaAccessFailure` live in `danaview_editor_core/lib/src/model/pool/` (CORE-04), not `store/`, because the engine API (API-01, M0) implements the port and CORE-27 lands in M2.
2. `ops/limits.dart` (concurrent decoder layers, item count, 24 h) belongs to the command framework (CORE-09) and runs after every command, instead of CORE-17, so structural commands (CORE-10) don't depend on track commands.
3. Keyframe data types (`model/keyframes/keyframe_data.dart`) are CORE-03, since `MediaClip` holds a `KeyframeSet`; the PropertyKey registry and evaluation stay CORE-05. CORE-04 (pool) precedes CORE-03 because `EditProject` holds the pool.
4. CORE-27 (media pool service) precedes CORE-25 (repository), because `create(fromMedia)` and `findUntouchedProjectFor` need import and fingerprinting.
5. `/settings/editor` and `/settings/licenses` are explicit routes reached through optional callbacks; `SettingsDestination` is unchanged, because a new enum value would break the router's exhaustive switch before the integration ticket lands.
6. The privacy-host consistency test lives at the app root (INT-04): only the app depends on both `danaview_features` and `danaview_transcription`.
7. Because `danaview_editor` depends on `danaview_transcription` → `danaview_whisper` (an FFI plugin), the app pulls the whisper plugin as soon as INT-02 adds `danaview_editor`; INT-02 therefore depends on the whisper native builds (AI-04, AI-05), and iOS builds run `tool/build_ios_xcframework.sh --if-missing` (ENG-09's `ios.sh`, INT-05's Fastfile).
8. The example app's `RunnerTests` target uses an Xcode synchronized folder (ENG-09) so native tickets add test files without editing a shared `project.pbxproj`.
9. Release workflows are edited only by INT-05; AI-04 ships `scripts/ci/editor/check_native_libs.sh` instead of editing `android-release.yml`. AI-05's Fastfile step moves to INT-05 for the same reason.
10. `.vlut` writing is pure Dart in core (CORE-21, D-07); native.md's ENG-06 "LUT normalizer" ticket doesn't exist. native.md's plan codec moved to core (CORE-29, D-02). native.md's own ENG-09/10/11/12 (not this plan's ENG-09) became QA-03, QA-04, INT-03 (+ ENG-08 manifests) and QA-05. ux.md UX-44/45/46/47 became QA-04, QA-00, INT-05 and INT-05. ai.md AI-15/16/17/18/19/20 became CORE-15, UX-37, UX-38, UX-42 (+UX-38), QA-06 and QA-07. domain.md DOM-34/35 became QA-10 and CORE-35.
11. **Owner decision 2026-10-11 (D-43(e) signed off; ARCH D-45).** Six tickets were added in M4: CORE-37 (render-preview cache model; after CORE-32), UX-44 (render-preview UI and tier defaults; after UX-18, UX-04, CORE-37), IOS-19 (iOS render-preview renderer; after IOS-11), IOS-20 (iOS multi-pass export fallback; after IOS-12), AND-18 (Android render-preview renderer; after AND-16, AND-10) and AND-19 (Android multi-pass export precompose; after AND-11). QA-04 now also depends on UX-44, AND-18 and IOS-19; QA-11 on IOS-20 and AND-19; QA-08 and QA-09 on UX-44. AND-16, AND-11, IOS-11, IOS-12, UX-18 and UX-04 were amended only where the decision changes them (each amendment is dated in its ticket): AND-11/IOS-12 expose a multi-pass hook and never refuse for layer counts; AND-16/IOS-11 expose a rendered-range hook; UX-04 gains a second settings slot, tier-dependent proxy default and render files in 'Editor cache'. The new tickets plug into those hooks and never edit the amended tickets' files. The render-preview cache also needs a contract addition (`MediaJobs.renderPreview`, `PreviewSession.setRenderedRanges`, a power/idle signal; ARCH D-45 'Contract'): the Pigeon surface and glue are frozen (§2), so it is one lead-approved [INTEGRATION] amendment, listed in §7, that must land before UX-44, IOS-19 and AND-18 call the engine; until then they build against their own interfaces and API-01's fake. This plan's UX-44 is unrelated to ux.md's old UX-44/UX-44b (item 10: those became QA-04 and UX-43).
12. **Follow-ups to the 2026-10-11 decision (owner approved).** Two more M4 tickets: INT-06 ([INTEGRATION] engine interface additions for render preview; after ENG-06, CORE-37) is the lead-approved amendment item 11 describes (Pigeon, generated code, glue on both platforms, `mobile_*` glue, the engine API contract, `FakeEditorEngine` and the contract kit; native sides stay `notSupportedOnDevice` placeholders that IOS-19 and AND-18 fill). UX-44, IOS-19 and AND-18 now also depend on INT-06. CORE-38 (allow edits above the live-preview sequence cap; after CORE-09, CORE-37) removes CORE-09's command-time rejection for the two layer caps and reports an informational `aboveLivePreviewCap` state (ARCH D-14); it is a new ticket rather than a `FIX-CORE-09-n` because it is a requirement change with a new dependency, and it edits only `ops/limits.dart` and CORE-09's framework tests (§7). QA-11 also depends on CORE-38. Total 166 tickets; M4 has 32.

## 10. [VERIFY] closure

Every unverified platform claim is assigned to the ticket whose acceptance criteria close it; the authoritative list with owners is ARCH §24.2. Spike tickets (IOS-01, AND-01) start on day 1 and answer the engine claims (V-N1…V-N25 as assigned) before ENG-06 freezes the Pigeon surface; ENG-06 records the answers in ARCHITECTURE.md.

## 11. Review resolutions (2026-10-08)

The architecture review raised 38 issues (1 blocker, 15 major, 22 minor). All were applied, some in a narrower or different form; the decisions are D-35 to D-44 in ARCHITECTURE.md. Nine tickets were added (ENG-07, ENG-08, ENG-09, CORE-36, IOS-17, IOS-18, AND-16 (conditional), AND-17, QA-11): 149 → 158.

**Contract decisions made explicit**

| Topic | Decision | Where |
|---|---|---|
| Frame grid and platform time (blocker) | Plans keep `timeOfFrame(k) = ceil(k·10⁶/fps)`. Every platform time maps to `k = frameIndexNearest(τ) = round(τ·fps/10⁶)` and is evaluated at `timeOfFrame(k)`. iOS hands AVFoundation `CMTime(k, gridFps)` for every grid time; Android anchors every sequence boundary at `P(k) = round(k·10⁶/fps)`; plans carry `canvas.gridFps`. Shared vectors cover floor, round and rational inputs; grid-cut fixture and barcode case at k ≡ 1, 2 (mod 3). | D-35, ARCH §5, §11.2–11.5; CORE-02, CORE-29, IOS-08/10/11, AND-08/10, QA-03 |
| Android preview | Paused edits never use `experimentalRedrawLastFrame`; `PausedFrameRenderer` (AND-17) draws them with our shaders; structural patches are debounced; Android structural budgets renegotiated (§13.4). Contingency on no-go is AND-16 (N ExoPlayers + our GL compositor), sized, with owner sign-off on its degradations before M1 ends (signed off 2026-10-11, D-43(e); render-preview cache added, D-45). | D-36, ARCH §13.3–13.4 |
| Android sequences | Core packing (CORE-36) assigns `seq`; caps on concurrent decoders and on visual sequences (`maxVisualSequences`), limiting live preview only since 2026-10-11 (export runs a multi-pass precompose above them, AND-19/IOS-20); effects exit early for gated frames. | D-14, D-45, ARCH §13.5 |
| iOS background export | Backgrounding is an interruption: segment-resumable export with checkpoints and passthrough concat (IOS-17); iPhone `paused`, iPad iOS 26 with background GPU `continued`; no software-CI path unless proven. Proxy/reverse jobs share the semantics. | D-22, ARCH §14.2, §15 |
| iOS gain > 0 dB | `MTAudioProcessingTap` applies the whole envelope (0–2) per sample; no `setVolumeRamp`; export clamps to [−1, 1]. | D-37, IOS-18 |
| No-audio export | iOS writes silent LPCM and never builds a mix output over zero tracks; Android clock band declares `trackTypes {VIDEO, AUDIO}`; deprecated force-track setters dropped. | D-38 |
| Export hand-off when detached | `whenDetached = saveToGallery` default, native save, persisted `completedWhileDetached` record, `work/` wipe exemption, one-shot card on next open; mirrored on iOS. | D-39 |
| Spike ordering | IOS-01 and AND-01 start on day 1 in spike hosts with no dependencies; ENG-01 split into ENG-01/07/08/09; ENG-06 freezes Pigeon only after the extended spikes report. | D-42, §4 |
| iOS 15/16 testing | Lab iPhone 7 (iOS 15.8) and iPhone 8 (iOS 16.7); `-Werror=unguarded-availability-new`; `check_ios_min_os.sh` in CI and release; CMake install step; no AC depends on iOS 15/16 simulators. | D-41 |

**Applied (issue → resolution)**

1 frame grid → D-35 (above). 2 Android redraw/rebuild → D-36, AND-17, AND-01 tests (a)–(c), budgets renegotiated. 3 decoder/GPU limits → `maxVisualSequences`, CORE-36 packing in core, early exit (AND-09), 6-lane sparse-PiP case (V-N25). 4 iOS background → D-22, IOS-17, IOS-01/IOS-13 real-iPhone tests on iOS 18 and 26, honest `backgroundKind` and UX-39 copy, R3. 5 iOS gain → D-37, IOS-18, +6.02 dB ACs (IOS-18, IOS-12, QA-11). 6 no-audio export → D-38, IOS-12/AND-11 fixtures. 7 detached completion → D-39, AND-12/IOS-13/ENG-04/UX-39, swipe-from-recents AC. 8 Android fallback → AND-16 sized contingency, degradations listed for owner sign-off (D-43e). 9 sequencing → spikes on day 1, ENG-01 split, freeze after spikes; QA-03 split into QA-03 + QA-11; AND-08 slimmed by CORE-36. 10 iOS 15/16 → D-41. 11 VT 17.4 keys → `#available` + pre-17.4 HEVC detection (IOS-02, ARCH §14.2). 12 missing deps/owners → IOS-12 → IOS-11, AND-11 → AND-08/AND-10, QA-00 → native platform tickets; ENG-09 pre-declares example plist keys; ENG-08 declares the Photo Picker `ModuleDependencies` entry; spacer generated at runtime by IOS-08 (no resource). 13 PHPicker lifetime → native `clonefile` into `work/picks/` (IOS-15, ARCH §9.1). 14 reverse resources → GOP chunks from the end, random-access reader, 420v, preflight and 10-min cap, restated memory AC (IOS-07, AND-07). 15 sprite scale → per-item max animated scale clamped to `min(maxTextureSize, 2× long side)`, `maxTextureSize` capability, LayerLook sizing, 8× parity fixture. 16 Android backup → whole editor and speech trees excluded (see rejected note), documented, `bmgr` check. 17 fixtures → committed CC0 MKV/WebM, semantic-equivalence AC (V-U6). 18 preview A/V latency → `targetTimestamp` compensation on iOS, measured/delayed audio on Android if possible, preview tolerance ≤ 1 frame and ≤ 40 ms (§12.7), V-N23. 19 version drift → `@OptIn(UnstableApi, ExperimentalApi)` + lint, `trackTypes`, whisper v1.9.5 review in AI-01. 20 weak devices → `minimal` tier (D-40). 21 high speed → auto proxies above 2×, Android `setFrameRate` cap, ramp-seam click test with crossfade fallback (IOS-18, QA-11). 22 drag/lifecycle testability → synthesized drop sessions/DragEvents in IOS-16/AND-15, manual cross-app steps, shell-driven background/kill. 23 keyboard/pointer → QA-00 scenario 12, UX-15 Shortcuts-override AC, V-U3/V-U4 in UX-07/UX-12, 'Desktop optimization' row restated. 24 audio measurement → tone fixtures (ENG-05), Dart reference mixer (API-03), QA-11 FFT/RMS/mute checks. 25 export content → QA-00 scenario 7 frame checks; QA-07 uses the same method; side files parse back. 26 presets → QA-11 preset matrix; portrait retry-or-fail-visibly rule (ARCH §14.1). 27 originals/Documents → `DocumentsExportWriter` (D-44, CORE-24), UX-39 AC, QA-10 Documents check, `excludeFromBackup` guard (ENG-03). 28 platform reach → owner sign-off rows (D-43), API 28 emulator run in QA-02, UX-41 unsupported-device AC. 29 desktop teaser → flag deleted, macOS-targeted absence tests (INT-02, INT-04). 30 privacy → reworded summary, platform qualifiers, `HttpOverrides` no-network-before-consent test (INT-04), hosted policy publication (INT-05). 31 UI rules → longer forbidden list, whole-identifier matching, features-file scan (INT-01), `expectOwnerUiRules` (UX-01). 32 player Edit → cheat-sheet line (UX-41 owns `danaview_settings_panel.dart`), more-sheet overflow AC (UX-41, QA-09), hidden while locked, managed-copy preflight + cancellable progress. 33 touch/pointer ACs → UX-18 and UX-12. 34 export fps → Match project + 24/25/30/48/50/60 (CORE-33, UX-39). 35 container paths → persistence rule (ARCH §8.2), CORE-22/CORE-25 tests, QA-10 reinstall check. 36 E2E coverage → QA-00 scenarios 13–18 and the manual iPad drop step in QA-01. 37 restore relink → "Relink several" (`autoMatch`, CORE-28, UX-40). 38 subtitle track shift → `ShiftCues` (CORE-15), "Shift all captions…" and "Select all on this lane" (UX-31).

**Rejected or narrowed (with reasons)**

- Issue 9, splitting UX-01, IOS-11 and AND-08 further: not split. UX-01 is mostly generated placeholders plus small harness code; IOS-11 is one cohesive session object whose parts can't be tested apart; AND-08 lost packing to CORE-36. §1 rule 2 lets owners split inside their own files.
- Issue 28, a pure-Dart MKV/WebM → MP4 remux ticket: not scheduled. It is new scope, so it is offered to the owner as an option in D-43(d); until then the R7 copy stays.
- Issue 5, option 2 (ramps ≤ 1 plus make-up gain): rejected. The tap applies the whole envelope, which is simpler and sample-exact.
- Issue 10, "confirm iOS 15/16 simulator runtimes can be installed": not relied on. Physical lab devices are used because Xcode 26.6 on the dev Mac offers iOS 18.2+ only.
- Issue 12, bundling the spacer as a podspec resource: rejected. It is generated at runtime, so the podspec resource list stays frozen.
- Issue 16, excluding only `projects/*/assets/recordings` and `stills`: not possible, because Android backup rules take no wildcards. The whole editor tree is excluded instead (projects are not in Android backups), with the owner's sign-off D-43(f). iOS keeps project bundles in backups.
- Issue 17, writing WebM with a Media3 muxer: rejected. Media3 has no Matroska/WebM writer for this purpose, so small CC0 samples are committed with their provenance.
- Issue 18, delaying audio on Android: only done if Media3's audio sink supports a presentation delay (V-N23). Otherwise the separate preview tolerance (≤ 40 ms) applies.
- Issue 20, a higher hard device floor: rejected in favour of the `minimal` tier, so the owner's reach is kept (issue 28). The hard floor is only Metal on iOS, and API 29 + GLES 3 + 2 GB RAM on Android.
- Issue 29, building the "coming to desktop" dialog: rejected. "Hidden" already satisfies owner decision 1, so the flag is deleted.
- Issue 30, platform-conditional legal text: rejected in favour of static "On iPhone, iPad and Android" qualifiers, which avoids platform logic in `legal_texts.dart`.
- Issue 4, the iOS 26 software-Core-Image background path: dropped unless IOS-01 proves the Metal CI kernels run on the CPU renderer at ≥ 0.2× real time (V-N22).
