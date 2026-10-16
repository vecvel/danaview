# Editor build state

Generated 2026-10-15 20:40 IST on the Mac from the code and the build runs (status was rebuilt from the code after the folder move). The code on `editor-wip` is the ground truth.

**Totals:** 151 done, 13 in progress, 2 not started (of 166). The Windows Android lane is complete (ENG-08, AI-04, AND-02…AND-19; merged into editor-wip at 78f5ecc). Six M4 tickets (CORE-37, UX-44, IOS-19, IOS-20 on the Mac; AND-18, AND-19 on Windows) were added on 2026-10-11 by the owner's D-43(e) decision (ARCH D-43, D-45; BUILD_PLAN §9 item 11). D-43(e) is signed off, so M1 exit and AND-16 no longer wait for it. Two more Mac tickets followed the same day (BUILD_PLAN §9 item 12): CORE-38 (edits allowed above the live-preview cap; after CORE-09, CORE-37) and INT-06 ([INTEGRATION] engine interface additions for render preview; after ENG-06, CORE-37). UX-44, IOS-19 and AND-18 now also depend on INT-06, and QA-11 on CORE-38.

"Machine" is who builds the ticket after the split: the Mac does everything except the Android lane; the Windows laptop does the Android lane (see ANDROID_LANE.md). "In progress" means a Mac builder was working on it when this file was generated; its files may be incomplete.


## M0 (21/21 done)

| # | Ticket | Title | Depends on | Status | Machine |
|---|---|---|---|---|---|
| 1 | INT-01 | Repo foundations: iOS 15.0 target, dependency rules, editor CI | — | ✅ done | Mac |
| 2 | CORE-01 | danaview_editor_core package scaffold, barrels, purity test | INT-01 | ✅ done | Mac |
| 3 | CORE-02 | Time, frame grid, timecode and ids | CORE-01 | ✅ done | Mac |
| 4 | CORE-04 | Media pool model, MediaAccessPort and quickHash | CORE-02 | ✅ done | Mac |
| 5 | CORE-03 | Core immutable model types | CORE-02, CORE-04 | ✅ done | Mac |
| 6 | CORE-05 | Property keys, keyframe evaluation | CORE-03 | ✅ done | Mac |
| 7 | CORE-06 | Clip time map and speed math | CORE-03 | ✅ done | Mac |
| 8 | CORE-29 | RenderPlan v1 types, JSON codec, JSON Schema, validator, contract fixtures | CORE-02 | ✅ done | Mac |
| 9 | API-01 | Engine API package: contract, value types, failures, fake engine, contract kit | CORE-03, CORE-04, CORE-29 | ✅ done | Mac |
| 10 | ENG-01 | Engine plugin: Pigeon surface definitions and generated code, MobileEditorEngine, event router, error mapper | API-01, INT-01 | ✅ done | Mac |
| 11 | ENG-05 | Test media fixtures and frame barcode readers | ENG-01 | ✅ done | Mac |
| 12 | ENG-09 | Example host app, native test harness and editor CI scripts | ENG-01, ENG-05 | ✅ done | Mac |
| 13 | ENG-07 | iOS plugin glue, engine core and native service placeholders | ENG-09 | ✅ done | Mac |
| 14 | ENG-08 | Android plugin glue, engine core, Gradle, manifest and native service placeholders | ENG-09 | ✅ done | Windows |
| 15 | AI-01 | Vendor whisper.cpp v1.9.4 (pruned) with re-vendor script | — | ✅ done | Mac |
| 16 | AI-02 | danaview_whisper FFI plugin skeleton and C ABI header | AI-01 | ✅ done | Mac |
| 17 | AI-08 | danaview_transcription package: contracts, catalog, languages, consent types, fake | AI-02, CORE-03 | ✅ done | Mac |
| 18 | UI-01 | danaview_ui_kit additions: progress bar, number field, colour picker, docked panel, search field, step indicator | — | ✅ done | Mac |
| 19 | UX-01 | danaview_editor package scaffold, availability gate, providers, contracts, wiring, placeholders | API-01, AI-08, UI-01, CORE-04 | ✅ done | Mac |
| 20 | UX-02 | Orientation owner stack (ScreenOrientationPolicy) | — | ✅ done | Mac |
| 21 | UX-03 | Home header edit button and features chrome entry point | — | ✅ done | Mac |

## M1 (22/22 done)

| # | Ticket | Title | Depends on | Status | Machine |
|---|---|---|---|---|---|
| 22 | IOS-01 | iOS spike (day 1, spike host): Metal CI kernels, compositor, grid timing, exact seek, texture, audio tap, background encoder, reader/writer | — | ✅ done | Mac |
| 23 | AND-01 | Android spike (day 1, spike host): Media3 1.11.1 multi-sequence CompositionPlayer + Transformer, grid timing, paused edits, rebuild latency, packing | — | ✅ done | Mac |
| 24 | CORE-07 | Geometry, text layout spec and text animation evaluation | CORE-05, CORE-06 | ✅ done | Mac |
| 25 | CORE-08 | Validator and repair | CORE-05, CORE-06 | ✅ done | Mac |
| 26 | CORE-36 | Visual packing and per-platform layer counts | CORE-03 | ✅ done | Mac |
| 27 | CORE-09 | Command framework, dry run, placement and limits | CORE-08, CORE-36 | ✅ done | Mac |
| 28 | CORE-10 | Structural clip commands and ripple | CORE-09, CORE-06 | ✅ done | Mac |
| 29 | CORE-11 | Duplicate, clipboard, replace, extract audio, links, selection | CORE-10 | ✅ done | Mac |
| 30 | CORE-12 | Speed, reverse and freeze-frame commands | CORE-10 | ✅ done | Mac |
| 31 | CORE-13 | Property and keyframe commands | CORE-09, CORE-05 | ✅ done | Mac |
| 32 | CORE-14 | Text commands | CORE-13, CORE-07 | ✅ done | Mac |
| 33 | CORE-15 | Subtitle and generated-caption commands | CORE-10 | ✅ done | Mac |
| 34 | CORE-16 | Transitions and transition limits | CORE-10 | ✅ done | Mac |
| 35 | CORE-17 | Track, marker and project-setting commands, requantize | CORE-09 | ✅ done | Mac |
| 36 | CORE-18 | Snapping index | CORE-03 | ✅ done | Mac |
| 37 | CORE-19 | EditSession: snapshot history, transactions, coalescing | CORE-09 | ✅ done | Mac |
| 38 | CORE-20 | SRT and WebVTT codec | CORE-02 | ✅ done | Mac |
| 39 | CORE-21 | .cube parser, .vlut writer/reader, float16 | CORE-01 | ✅ done | Mac |
| 40 | API-03 | Render-math vectors, Dart CPU reference renderer, goldens | API-01, CORE-07, CORE-29 | ✅ done | Mac |
| 41 | ENG-06 | [INTEGRATION] Spike outcomes into plugin build config and Pigeon surface | IOS-01, AND-01, ENG-07, ENG-08 | ✅ done | Mac |
| 42 | AI-03 | whisper native C shim and host tests | AI-02 | ✅ done | Mac |
| 43 | AI-06 | whisper device profile, thermal/memory events, backup exclusion channel | AI-02 | ✅ done | Mac |

## M2 (34/34 done)

| # | Ticket | Title | Depends on | Status | Machine |
|---|---|---|---|---|---|
| 44 | CORE-22 | Project JSON codec, fragment cache, schema version | CORE-03, CORE-04, CORE-05 | ✅ done | Mac |
| 45 | CORE-23 | Migration framework and schema fixtures | CORE-22 | ✅ done | Mac |
| 46 | CORE-24 | Store filesystem, atomic writes, .dnproj format, OwnedFileDeleter | CORE-22 | ✅ done | Mac |
| 47 | CORE-27 | Media pool service, import policy, managed store, DartIoMediaAccess | CORE-24, CORE-19 | ✅ done | Mac |
| 48 | CORE-25 | ProjectRepository and writer isolate | CORE-27, CORE-23 | ✅ done | Mac |
| 49 | CORE-26 | Autosave scheduler, journal and crash recovery | CORE-25 | ✅ done | Mac |
| 50 | CORE-28 | Availability, relink, garbage collection, backup rules | CORE-25, CORE-27 | ✅ done | Mac |
| 51 | CORE-30 | RenderPlan compiler: visual lowering, assets, z-order | CORE-29, CORE-07, CORE-08, CORE-36 | ✅ done | Mac |
| 52 | CORE-31 | Lowering: transitions, text and subtitle sprites, audio | CORE-30, CORE-16 | ✅ done | Mac |
| 53 | CORE-32 | Plan diff, patches, memoization and transients | CORE-31 | ✅ done | Mac |
| 54 | CORE-33 | Export settings, presets, bitrate table, compileExport | CORE-31 | ✅ done | Mac |
| 55 | API-02 | PlanSync and plan transport | API-01, CORE-32 | ✅ done | Mac |
| 56 | API-04 | Render prep: text layout engine, sprite rasterizer, .vsprite codec, sprite pre-pass | API-01, CORE-07, CORE-31 | ✅ done | Mac |
| 57 | ENG-03 | Dart glue: jobs, recorder, platform services, media access | ENG-06 | ✅ done | Mac |
| 58 | IOS-02 | iOS probe, compatibility, device profile, capabilities | ENG-06, ENG-05 | ✅ done | Mac |
| 59 | IOS-17 | iOS segmented writer, checkpoint, passthrough concat and job interruption | ENG-06, ENG-05 | ✅ done | Mac |
| 60 | IOS-03 | iOS thumbnails and disk cache | IOS-02 | ✅ done | Mac |
| 61 | IOS-04 | iOS PCM reader, waveforms, speech audio extraction | IOS-02 | ✅ done | Mac |
| 62 | IOS-05 | iOS job registry, proxy job and proxy registry | IOS-02, IOS-17 | ✅ done | Mac |
| 63 | IOS-06 | iOS freeze frame and source-frame cache | IOS-05 | ✅ done | Mac |
| 64 | IOS-07 | iOS reverse rendition job | IOS-05 | ✅ done | Mac |
| 65 | IOS-18 | iOS audio gain tap (sample-exact envelopes up to +6 dB) and ramp-seam crossfade | ENG-06, API-03 | ✅ done | Mac |
| 66 | AND-02 | Android probe, compatibility, device profile, capabilities | ENG-06, ENG-05 | ✅ done | Windows |
| 67 | AND-03 | Android thumbnails and disk cache | AND-02 | ✅ done | Windows |
| 68 | AND-04 | Android PCM decoder, waveforms, speech audio extraction | AND-02 | ✅ done | Windows |
| 69 | AND-05 | Android job registry, proxy job and registry | AND-02 | ✅ done | Windows |
| 70 | AND-06 | Android freeze frame and source-frame cache | AND-05 | ✅ done | Windows |
| 71 | AND-07 | Android reverse rendition job | AND-05 | ✅ done | Windows |
| 72 | AI-04 | whisper Android native build | AI-03 | ✅ done | Windows |
| 73 | AI-05 | whisper iOS native build (static xcframework) | AI-03, INT-01, ENG-09 | ✅ done | Mac |
| 74 | AI-09 | Model store and resumable, verified downloader | AI-08, AI-06 | ✅ done | Mac |
| 75 | AI-10 | Transcript normalizer, cache and checkpoints | AI-08 | ✅ done | Mac |
| 76 | AI-11 | Caption segmentation engine | AI-08 | ✅ done | Mac |
| 77 | AI-12 | Timeline planner, word mapping and merge | AI-08, CORE-06 | ✅ done | Mac |

## M3 (32/32 done)

| # | Ticket | Title | Depends on | Status | Machine |
|---|---|---|---|---|---|
| 78 | CORE-34 | Model fuzzer (commands, history, codec, plan diff) | CORE-11, CORE-12, CORE-14, CORE-15, CORE-16, CORE-17, CORE-19, CORE-22, CORE-32 | ✅ done | Mac |
| 79 | ENG-02 | Dart glue: mobile preview session | ENG-06, API-02 | ✅ done | Mac |
| 80 | IOS-08 | iOS plan decode, ParamSnapshot, composition builder, instructions, audio mix | ENG-06, CORE-29, CORE-32, API-03, IOS-18 | ✅ done | Mac |
| 81 | IOS-09 | iOS render kernels, LUT/sprite/image stores | ENG-06, API-03, API-04, CORE-21 | ✅ done | Mac |
| 82 | IOS-10 | iOS DVCompositor, layer renderer, redraw cache | IOS-08, IOS-09 | ✅ done | Mac |
| 83 | IOS-11 | iOS preview session: texture, display link, clock, seek, patches, quality, lifecycle | IOS-10, IOS-06, ENG-02 | ✅ done | Mac |
| 84 | AND-08 | Android plan reader, ParamSnapshot, composition mapper, gating, speed and gain providers | ENG-06, CORE-29, CORE-32, API-03 | ✅ done | Windows |
| 85 | AND-09 | Android GL effects, shaders, LUT and sprite textures | ENG-06, API-03, API-04, CORE-21 | ✅ done | Windows |
| 86 | AND-17 | Android paused-frame renderer, layer GL compositor and structural debounce | AND-08, AND-09, AND-06 | ✅ done | Windows |
| 87 | AND-10 | Android preview session: SurfaceProducer, clock, seek/scrub, transients, redraw, quality, lifecycle | AND-08, AND-09, AND-06, ENG-02, AND-17 | ✅ done | Windows |
| 88 | AND-16 | Android contingency preview engine (conditional: only on an AND-01 no-go) | AND-10, AND-17 | ✅ done | Windows |
| 89 | AI-07 | whisper Dart runtime (WhisperRuntime, WhisperModel, WhisperJob) | AI-03, AI-06, AI-04, AI-05 | ✅ done | Mac |
| 90 | UX-04 | Storage contributors, Settings row and Editor settings screen | UX-01, CORE-25 | ✅ done | Mac |
| 91 | UX-05 | Projects screen and controller | UX-01, CORE-25 | ✅ done | Mac |
| 92 | UX-06 | New project sheet and import media sheet | UX-05, CORE-27 | ✅ done | Mac |
| 93 | UX-07 | Editor screen shell, scope, lifecycle and layout planner | UX-01, UI-01 | ✅ done | Mac |
| 94 | UX-08 | EditorController, EditorState, EditTransaction, session wiring, events, messages | UX-01, CORE-19, CORE-26, API-02 | ✅ done | Mac |
| 95 | INT-02 | [INTEGRATION] App wiring v1: EditorBootstrap, default plan compiler, routes, Home and Settings entry points | UX-03, UX-04, UX-05, UX-07, UX-08, ENG-06, CORE-26, CORE-28, CORE-33, AI-04, AI-05 | ✅ done | Mac |
| 96 | UX-09 | Timeline viewport controller, ruler, metrics and style | UX-01, CORE-02 | ✅ done | Mac |
| 97 | UX-10 | Timeline snapshot, RenderTimelineCanvas painting, hit testing, playhead layer | UX-08, UX-09 | ✅ done | Mac |
| 98 | UX-11 | Track headers, track menu and lane flags | UX-10, CORE-17 | ✅ done | Mac |
| 99 | UX-12 | Timeline view, gesture arbiter, semantics | UX-10 | ✅ done | Mac |
| 100 | UX-13 | Move, trim, split, delete, ripple, snapping UI, clipboard | UX-12, CORE-11, CORE-18 | ✅ done | Mac |
| 101 | UX-14 | Playhead controller, transport controller and transport bar | UX-08 | ✅ done | Mac |
| 102 | UX-15 | Action registry, keyboard shortcuts, shortcuts sheet | UX-08 | ✅ done | Mac |
| 103 | UX-16 | Tool strip/rail, context tool sets, inspector host and dock | UX-07, UX-15, CORE-05 | ✅ done | Mac |
| 104 | UX-17 | Markers sheet and marker actions | UX-13, UX-14, CORE-17 | ✅ done | Mac |
| 105 | UX-18 | Preview region, preview surface, status overlays, fullscreen preview, quality | UX-07, UX-14 | ✅ done | Mac |
| 106 | UX-19 | Text and subtitle overlay layer for preview | UX-18, API-04, CORE-07 | ✅ done | Mac |
| 107 | UX-20 | Thumbnail cache and strip painting | UX-10 | ✅ done | Mac |
| 108 | UX-21 | Waveform cache and painting | UX-10 | ✅ done | Mac |
| 109 | UX-22 | Canvas geometry, manipulation overlay (move/scale/rotate), snap guides | UX-18, CORE-13, CORE-32 | ✅ done | Mac |

## M4 (30/32 done)

| # | Ticket | Title | Depends on | Status | Machine |
|---|---|---|---|---|---|
| 110 | ENG-04 | Dart glue: export service and job reattach | ENG-06 | ✅ done | Mac |
| 111 | IOS-12 | iOS export pipeline: reader/writer, encoder settings, coordinator | IOS-10, ENG-04, IOS-11, IOS-17, IOS-18 | ✅ done | Mac |
| 112 | IOS-14 | iOS voice recorder | ENG-03 | ✅ done | Mac |
| 113 | IOS-15 | iOS pickers, media access (bookmarks), permissions, background guard | ENG-03 | ✅ done | Mac |
| 114 | IOS-16 | iOS external drop target | ENG-03 | ✅ done | Mac |
| 115 | AND-11 | Android export: coordinator, Transformer, encoder settings, hardware selector, active store | AND-09, ENG-04, AND-08, AND-10 | ✅ done | Windows |
| 116 | AND-13 | Android voice recorder | ENG-03 | ✅ done | Windows |
| 117 | AND-14 | Android pickers, URI grants (media access), permissions | ENG-03 | ✅ done | Windows |
| 118 | AND-15 | Android external drop target | ENG-03 | ✅ done | Windows |
| 119 | AI-13 | Transcription orchestrator (TranscriptionServiceImpl) and resource governor | AI-07, AI-09, AI-10, AI-11, AI-12, CORE-15 | ✅ done | Mac |
| 120 | UX-23 | Transform, crop and mask panels; crop, mask and eyedropper preview modes | UX-22, UX-16 | ✅ done | Mac |
| 121 | UX-24 | Adjust and Filters/LUT panels, built-in looks | UX-16, CORE-13, CORE-21, CORE-27 | ✅ done | Mac |
| 122 | UX-25 | Speed panel and speed curve editor | UX-16, CORE-12 | ✅ done | Mac |
| 123 | UX-26 | Keyframes panel and keyframe actions | UX-16, CORE-13 | ✅ done | Mac |
| 124 | UX-27 | Transitions panel and loop preview | UX-16, UX-18, CORE-16 | ✅ done | Mac |
| 125 | UX-28 | Overlay (picture-in-picture) and chroma key panels | UX-23 | ✅ done | Mac |
| 126 | UX-29 | Canvas/Format panel, project sheet, history sheet | UX-16, CORE-17, CORE-19 | ✅ done | Mac |
| 127 | UX-30 | Text tool, text panel, font picker, content fonts package | UX-19, CORE-14, API-04 | ✅ done | Mac |
| 128 | UX-31 | Subtitles lane tools and subtitles panel | UX-16, UX-19, CORE-15 | ✅ done | Mac |
| 129 | UX-32 | SRT/VTT import and export UI | UX-31, CORE-20 | ✅ done | Mac |
| 130 | UX-33 | Audio panel: volume, fades, mute, pitch, extract audio, background music | UX-16, CORE-13, CORE-11 | ✅ done | Mac |
| 131 | UX-34 | Voiceover recording UI | UX-33 | ✅ done | Mac |
| 132 | UX-35 | Freeze, reverse, replace, clip info, background tasks | UX-16, CORE-12, CORE-11 | ✅ done | Mac |
| 133 | UX-36 | Media panel (bin), add/replace, in-app and external drag and drop | UX-06, UX-13 | ✅ done | Mac |
| 134 | CORE-37 | Render-preview cache model: range hashing, invalidation, cache index | CORE-32 | ✅ done | Mac |
| 135 | CORE-38 | Allow edits above the live-preview sequence cap | CORE-09, CORE-37 | ✅ done | Mac |
| 136 | INT-06 | [INTEGRATION] Engine interface additions for render preview | ENG-06, CORE-37 | ✅ done | Mac |
| 137 | UX-44 | Render-preview UI: timeline render marker, action, settings, tier defaults | UX-18, UX-04, CORE-37, INT-06 | 🟡 built; hooks being wired (round 3) | Mac |
| 138 | IOS-19 | iOS render-preview renderer and playback swap-in | IOS-11, INT-06 | 🟡 built; preview wiring in progress (round 3) | Mac |
| 139 | IOS-20 | iOS multi-pass export fallback (precompose above the decoder limit) | IOS-12 | ✅ done | Mac |
| 140 | AND-18 | Android render-preview renderer and playback swap-in | AND-16, AND-10, INT-06 | ✅ done | Windows |
| 141 | AND-19 | Android multi-pass export precompose | AND-11 | ✅ done | Windows |

## M5 (10/10 done)

| # | Ticket | Title | Depends on | Status | Machine |
|---|---|---|---|---|---|
| 142 | IOS-13 | iOS background export, active-export store, Photos and Files handoff | IOS-12 | ✅ done | Mac |
| 143 | INT-03 | [INTEGRATION] iOS app declarations: Info.plist, entitlements, privacy manifest, BG task ids | INT-01, IOS-13, IOS-14, IOS-15 | ✅ done | Mac |
| 144 | AND-12 | Android export foreground service, notification, background guard, MediaStore, file handoff | AND-11 | ✅ done | Windows |
| 145 | UX-37 | Auto captions flow: sheet, controller, language picker, consent, progress | UX-31, AI-08, CORE-15 | ✅ done | Mac |
| 146 | UX-38 | Regenerate captions, interrupted-job notice, captions settings, speech storage contributor | UX-37, UX-04 | ✅ done | Mac |
| 147 | UX-39 | Export sheet, export controller, progress, handoff | UX-08, CORE-33, API-04 | ✅ done | Mac |
| 148 | UX-40 | Missing media, relink, recovery and migration UX | UX-05, UX-08, CORE-26, CORE-28 | ✅ done | Mac |
| 149 | UX-41 | Player 'Edit' action, EditorLauncher and player handoff | UX-02, UX-07, UX-08, CORE-25 | ✅ done | Mac |
| 150 | UX-42 | Privacy policy and terms update, custom licences screen, About row | — | ✅ done | Mac |
| 151 | INT-04 | [INTEGRATION] App wiring v2: auto captions service, adapters, player Edit, licences route | INT-02, AI-13, UX-38, UX-41, UX-42, ENG-03, ENG-04 | ✅ done | Mac |

## M6 (2/15 done)

| # | Ticket | Title | Depends on | Status | Machine |
|---|---|---|---|---|---|
| 152 | CORE-35 | Core benchmarks, large-project fixture, README | CORE-26, CORE-32, CORE-34, CORE-33 | ✅ done | Mac |
| 153 | QA-00 | Shared on-device E2E suite (integration_test/editor) | INT-04, ENG-05, UX-05, UX-06, UX-11, UX-17, UX-20, UX-21, UX-23, UX-24, UX-25, UX-26, UX-27, UX-28, UX-29, UX-30, UX-32, UX-34, UX-35, UX-36, UX-38, UX-39, UX-40, UX-41, UX-42, IOS-13, IOS-14, IOS-15, IOS-16, AND-12, AND-13, AND-14, AND-15 | 🔨 in progress (round 3) | Mac |
| 154 | QA-01 | Run and certify the E2E suite on the iOS Simulator | QA-00, INT-03 | 🟡 automated suite certified on simulator (re-run 3: iPhone 18/18 incl. solo re-runs, iPad s12, iOS 18.2 3/3); manual iPad Files/Photos drops and physical-keyboard step need a person; lab smoke deferred (no device); FIX-IOS-12-1 filed | Mac |
| 155 | QA-02 | Run and certify the E2E suite on an Android Emulator | QA-00 | ⏳ not started | Windows |
| 156 | QA-03 | Frame accuracy, grid-cut, A/V sync and render parity suite | IOS-11, AND-10, IOS-12, AND-11, API-03, ENG-05 | 🔨 in progress (round 3) | Mac |
| 157 | QA-11 | Export conformance, preset matrix and audio measurement suite | IOS-13, AND-12, IOS-18, API-03, ENG-05, IOS-20, AND-19, CORE-38 | 🔨 in progress (round 3) | Mac |
| 158 | QA-04 | Performance and memory budgets (profile mode, device lab) | INT-04, CORE-35, UX-44, AND-18, IOS-19 | 🔨 in progress (round 3) | Mac |
| 159 | UX-43 | Timeline picture-tile cache (conditional on QA-04 budget miss) | QA-04 | 🔨 in progress (round 3) | Mac |
| 160 | QA-05 | Robustness soak | QA-00 | 🔨 in progress (round 3) | Mac |
| 161 | QA-06 | Auto captions benchmarks, accuracy evaluation and tuning | AI-13, AI-07 | ✅ done | Mac |
| 162 | QA-07 | Auto captions on-device E2E and AI device matrix | QA-06, UX-38, INT-04 | 🔨 in progress (round 3) | Mac |
| 163 | QA-08 | Accessibility pass (guidelines, VoiceOver, TalkBack) | UX-05, UX-06, UX-11, UX-17, UX-20, UX-21, UX-23, UX-24, UX-25, UX-26, UX-27, UX-28, UX-29, UX-30, UX-32, UX-34, UX-35, UX-36, UX-38, UX-39, UX-40, UX-41, UX-42, UX-44 | 🔨 in progress (round 3) | Mac |
| 164 | QA-09 | No-overflow matrix suite (full nightly, PR subset) | UX-05, UX-06, UX-11, UX-17, UX-20, UX-21, UX-23, UX-24, UX-25, UX-26, UX-27, UX-28, UX-29, UX-30, UX-32, UX-34, UX-35, UX-36, UX-38, UX-39, UX-40, UX-41, UX-42, UX-44 | 🔨 in progress (round 3) | Mac |
| 165 | QA-10 | Persistence, crash recovery and media-access survival on device | INT-04, IOS-15, AND-14, CORE-26, CORE-28 | 🔨 in progress (round 3) | Mac |
| 166 | INT-05 | [INTEGRATION] Release 1.1.0: flags, version, release pipelines, store metadata, docs | QA-01, QA-02, QA-03, QA-04, QA-05, QA-07, QA-08, QA-09, QA-10, CORE-35, UX-43, INT-03, INT-04, QA-11 | ⏳ not started | Mac |

## Open FIX tickets filed by QA

Filed 2026-10-15/16 by QA-08, QA-09 and QA-00's first simulator run of the E2E suite (BUILD_PLAN §0 item 8). Each one owns exactly the listed files of the original ticket, under that ticket's rules. Each one is also on an allow-list in a QA suite: `knownErrorDefects`/`knownA11yDefects`/`knownTimelineDefects` in `packages/danaview_editor/test/a11y/a11y_support.dart`, or `knownDefects` in `packages/danaview_editor/test/overflow/overflow_rig.dart`. The suites stay green while an entry is listed, so the FIX ticket must also remove its entry, which makes the suite enforce the fix. One id names one defect in both suites. Details: `docs/v1.1/editor/qa/QA-08-a11y.md` §4, `docs/v1.1/editor/qa/QA-09-overflow.md`, and for the E2E findings the Status section of `docs/v1.1/editor/qa/README.md` (logs in `build/e2e/ios/<udid>/logs/`). E2E findings are not allow-listed: the scenario fails until the fix lands.

| FIX ticket | Original | Files | Severity | Defect | Fix |
|---|---|---|---|---|---|
| FIX-INT-02-1 | INT-02 | `packages/danaview_editor/lib/src/app/editor_bootstrap.dart` | **Blocker** | Nothing sets `MobileMediaAccess.documentsRoot`, even though its header says EditorBootstrap sets it. Every media under Documents (all Files imports, ARCH §9.1 `documentsReference`) resolves as `accessLost: documents root not available`. The preview shows offline placeholders (black or grey), and export stops at "Relink N missing files". Found by E2E s02–s18 on the iOS simulator. The suite works around it in `E2eApp._boot` until this lands. | Set `documentsRoot` from `StoreRoots.documents` when the runtime is created (or pass it in `EditorEngineConfig`, with ENG-01/ENG-03 if that file needs it). Verify with `e2e_host.sh -D DV_E2E_NO_WORKAROUNDS=true run s04`. |
| FIX-UX-07-1 | UX-07 | `packages/danaview_editor/lib/src/editor/editor_screen.dart` | Major | UX-15's `EditorShortcuts` is never mounted, so no keyboard shortcut works in the app (Space, S, M, ⌘Z…). Found by E2E s12, s16, s17 and s18. | Wrap the editor body in `EditorShortcuts`, inside `EditorScope`. |
| FIX-UX-07-2 | UX-07 | `packages/danaview_editor/lib/src/editor/editor_screen.dart` | Major | UX-40's `EditorHealthHost` is never mounted. The missing-media banner never shows, and the health subscription that refreshes availability never starts. Found by E2E s10 (files moved, no banner). | Mount `EditorHealthHost` under the top bar. |
| FIX-UX-41-1 | UX-41 | `packages/danaview_editor/lib/src/app/editor_launcher.dart` | Major | The player reports its position in milliseconds (0:05:10 → 5 333 000 µs). The launcher passes it on as is, and the editor floors it to frame 159 instead of 160. Found by E2E s02: view.playhead 5 300 000 µs. | Map the player's position to the nearest frame, as a platform time (D-35: `round(τ·fps)`), before it is handed over. |
| FIX-INT-02-2 | INT-02 | `packages/danaview_editor/lib/src/editor/state/default_plan_compiler.dart` | Major (needs confirming) | A freeze-frame still stays a grey placeholder in the preview after it is `Ready` and its PNG exists. Found by E2E s06 and a probe that resolved the still fine. The likely cause is the per-(id, locator) resolution cache: the still is resolved while pending, the null is cached, and it is retried only on a new availability report, which never comes while FIX-UX-07-2 is open. | Invalidate the cached resolution when the asset's status changes, at least pending to ready. |
| FIX-UX-22-2 | UX-22 | `packages/danaview_editor/lib/src/editor/preview/manipulation_overlay.dart` | **Blocker** (crash) | Confirmed in the real app by E2E s15. Selecting any audio clip (music or voice) throws `ArgumentError: property "transform.scale" does not apply to this item: MediaClip` in `ManipulationOverlay.build`, because `_transformOf` runs for every non-cue selection. The preview becomes an error box, and the clip's Volume and Fades panels break while the preview is shown. | Call `_transformOf` only when `PropertyKeys.scale.appliesToItem(item)` holds, and give audio selections no transform label or actions. Remove FIX-UX-22-2 from `knownErrorDefects` (a11y) and `knownDefects` (overflow). |
| FIX-UX-12-1 | UX-12 | `lib/src/editor/timeline/timeline_semantics.dart` | Major | With ripple on (the default), the a11y nudge actions "Move 1 frame/second earlier/later" do nothing. | Nudge with `ripple: false`. |
| FIX-UX-12-2 | UX-12 | `lib/src/editor/timeline/timeline_semantics.dart` | Major | Marker, transition and keyframe nodes have only a tap action, with no delete or jump custom actions. | Add the custom actions (ARCH §17.9). |
| FIX-UX-12-3 | UX-12 | the multi-select status row in `lib/src/editor/timeline/` | Minor | At 412×915 @1.35, the "1 selected" row has no flexible child and overflows with the test font (`timeline_view_matrix_test.dart`, full matrix). | Make the label flexible and ellipsize it. |
| FIX-UX-22-1 | UX-22 | `lib/src/editor/preview/manipulation_overlay.dart` | Minor | With nothing selected, the preview overlay is an unlabeled tap semantics node. | Label it, or exclude it from semantics. |
| FIX-UX-14-1 | UX-14 | `lib/src/editor/transport/transport_bar.dart`, `timecode_text.dart` | Minor | The time readout button is 35–41 px tall, and its label is read twice. | Give it a height of 44 or more, and drop the inner label. |
| FIX-UX-14-2 | UX-14 | `lib/src/editor/transport/transport_bar.dart` | Minor | Transport buttons are 44×40 when the bar is 40 px tall. | Give them a touch height of 44 or more. |
| FIX-UX-14-3 | UX-14 | `test/transport/transport_bar_test.dart` | Minor (stale test) | The test "priority row actions that no feature binds yet … are not shown" fails on every run because a feature binding now exists. | Update the test. |
| FIX-UX-18-1 | UX-18 | `test/preview/surface/preview_region_test.dart` | Minor (stale test) | The test "statuses offline media at the playhead: Media missing with Relink…" fails on every run, because an icon it expects to be absent is present. | Update the test or the widget, whichever matches ux.md. |
| FIX-UX-11-1 | UX-11 | `lib/src/editor/timeline/track_headers.dart` | Minor (lead decision) | On 32 px text and subtitle lanes, the header buttons are 32 px tall. | Extend the hit areas past the lane. |
| FIX-UX-16-1 | UX-16 | `lib/src/editor/inspector/inspector_rows.dart` | Minor | Slider value chips are 32 px tall, and the value is read twice. | Use `minHeight: 44` and exclude the inner text from semantics. |
| FIX-KIT-1 | lead (app kit) | `packages/danaview_ui_kit/lib/src/components/danaview_chips.dart` | Minor | `DanaviewSegmentedControl` segments are 38 px tall, and their labels are read twice. | Make each segment fill the control height, and exclude the label text from semantics. |
| FIX-INT-02-3 | INT-02 | `packages/danaview_editor/lib/src/app/editor_bootstrap.dart` | Medium | Filed 2026-10-16 by the review of INT-07. The INT-07 surface is never used by the app: `FileMediaPoolService` and `MediaRelinkService` are built without `materialize:`, so the core `PickMaterializer` is null and an Android `content://` pick with no persistable grant still cannot be copied into `media/`; `EditorEngineConfig` is built without `exportNotificationTexts`, so Android export notifications always show the English defaults. Nothing in `packages/danaview_editor/lib` references `materializePick` or the notification texts. | Pass `materialize: engine.access.materializePick` to `FileMediaPoolService` and `MediaRelinkService`; build `EditorEngineConfig` with `ExportNotificationTexts` localized from the app strings. |
| FIX-UX-39-1 | UX-39 | `packages/danaview_editor/lib/src/editor/flows/export/export_controller.dart` | Minor | Filed with FIX-INT-02-3. `ExportController.start` never passes `notificationTexts:`, so a language change after start-up keeps the engine-wide (start-up) notification texts. | Pass localized `ExportNotificationTexts` per job in `start`. |
| FIX-IOS-19-1 | IOS-19 | new `packages/danaview_editor_engine/example/ios/RunnerTests/RenderPreview/RangeTouchVectorTests.swift` | Medium | Filed 2026-10-16 by the review of FIX-RANGE-RULE. Nothing native replays the shared vectors, so Dart/Swift agreement of the rendered-range rule rests on reading the code (layer `!=` is Swift struct equality on one side and Dart model equality on the other). | Load `TestFixtures.url(.core, "vectors/range_touch.json")` (moved to `danaview_editor_core/test/fixtures/vectors/` so it is already in the bundle), decode each case's `before`/`after` plans and assert `RenderedRangeRules.changeTouches(before, after, range) == touched` for every range of every case. |
| FIX-AND-18-1 | AND-18 (Windows lane) | `packages/danaview_editor_engine/android/src/test/kotlin/com/vecvel/danaview/editor/engine/render/RangeTouchTest.kt` | Medium | Same gap as FIX-IOS-19-1 on Android: no test reads `range_touch.json`. | Load `packages/danaview_editor_core/test/fixtures/vectors/range_touch.json` through `harness/JvmFixtures.kt`'s core tree (as the other shared fixtures are) and assert `RangeTouch.changeTouches(before, after, range) == touched` for every case. |

## Notes from finished tickets

What each finished builder reported: acceptance notes, what was deferred and why, and the hand-off facts later tickets need. AI-01 (whisper.cpp v1.9.4 vendored into packages/danaview_whisper/third_party, see VENDORED.md) was done outside the builder runs.


### INT-01

- **INT-01** (done): Every acceptance criterion is met except the ones listed under deferred. (1) iOS target is 15.0 in all 9 iOS build configurations of ios/Runner.xcodeproj/project.pbxproj: project, Runner and RunnerTests for Debug, Release and Profile. No 13.0 is left in the project. In ios/Podfile the IOS_DEPLOYMENT_TARGET = '15.0' constant feeds `platform :ios`, and a post_install hook lifts every pod below 15.0 to 15.0. Podfile.lock changed only in its checksum, from the pod install. `flutter build ios --no-codesign --debug` passes, and the built Runner binary and Info.plist both report a minimum OS of 15.0. (2) test/architecture/dependency_rules_test.dart enforces ARCH §4.2 rules 1-7 and the ARCH §1.3 Material scan on the 17 danaview_features files owned by UX-02, UX-03, UX-04, UX-41 and UX-42 (empty baseline). It also has a drift test that parses the BUILD_PLAN §6 owns lists, so the scanned file list must match every danaview_features Dart file owned there. It is green on main (38 pass; 1 skip because rule 7's danaview_editor package doesn't exist yet). It has 23 fixtures: 21 negative fixtures, each firing exactly its rule (some with exact violation counts), and 2 positive controls that must fire nothing. They live in test/architecture/fixtures/ (files use a .fixture suffix, with a README table). (3) .github/workflows/editor-ci.yml has the jobs dart-core, flutter-packages, whisper-host (linux, linux-tsan, linux-asan, macos), android-unit, android-emulator (KVM, API 35 x86_64), ios (self-hosted macOS, falls back to macos-15 via the dispatch input `runner` or the repo variable EDITOR_MACOS_RUNNER) and nightly (cron 02:30 UTC or dispatch). There is also an extra workflow-lint job running actionlint 1.7.7 with shellcheck. Each job runs its scripts/ci/editor/<job>.sh when present and prints a skip notice otherwise. Path filters are the spec list plus packages/danaview_features/** and docs/v1.1/editor/BUILD_PLAN.md, because the architecture test guards both. The release workflows are untouched. (4) flutter_packages.sh (analyze + test for each editor Flutter package that exists, the example/ host when present, then the root test/architecture; excludes the `nightly` test tag; per-package arguments; summary and exit 1 on any failure), nightly.sh (runs nightly.d/*.sh sorted, continues past failures, prints a one-command repro per failure, supports --list and named runs) and README.md (job/script owner table, script contract, env inputs, toolchain pins, self-hosted runner prerequisites incl. Xcode 26.6 and brew cmake >= 3.28, device lab list with the iPhone 7/8 marked not available per the owner default). Both scripts were tested on macOS bash 3.2, including failure paths in throwaway trees. (5) The ARCHITECTURE.md D-43 status reads "owner defaults 2026-10-08, revisable", with (a)-(d) and (f) answered, (e) left open until AND-16, and the no-lab-devices default noted.

**Deferred:**
- actionlint was not run locally. It isn't installed on the dev Mac, and installing it would mean a download outside pub/CocoaPods/Gradle. Instead, the workflow's workflow-lint job runs rhysd/actionlint:1.7.7 (with shellcheck) on editor-ci.yml in CI. Locally the workflow got a YAML parse, structural checks and `bash -n` on every run block.
- The iPhone 7 (iOS 15.8) and iPhone 8 (iOS 16.7) lab checks are deferred: no device available (owner default 2026-10-08). README.md and ARCH D-43 record this. iOS 15/16 are verified only by -Werror=unguarded-availability-new and check_ios_min_os.sh (ENG-09).
- The editor-ci workflow has not run on GitHub. Pushing or committing was not allowed, and the self-hosted macOS runner is not registered yet. Until it is, set the repo variable EDITOR_MACOS_RUNNER=macos-15 or dispatch with runner=macos-15, so the ios and whisper-host macOS jobs don't queue forever.
- One root test was already failing: settings_account_test 'app version matches pubspec.yaml' (app_info.dart has build 1, pubspec has +2). It is outside INT-01's files. Needs a FIX ticket, or INT-05's version bump to 1.1.0+3 should sync app_info.dart.
- The optional Android debug APK sanity build (`flutter build apk --debug`) failed with ENOSPC: the disk was full (137 MiB free, later 2.7 GiB). INT-01 changes no Android files. I did not retry, to avoid filling the shared disk while other engineers work; the 1.3 GB of partial output in build/app was left in place.
- The scaffolded podspecs packages/danaview_editor_engine/ios/danaview_editor_engine.podspec and packages/danaview_whisper/ios/danaview_whisper.podspec still say `s.platform = :ios, '13.0'`. They are not INT-01 files: ENG-07's spec sets the engine podspec to 15.0, and AI-05 owns the whisper podspec. Once wired into the app, the app Podfile's post_install hook lifts them to 15.0 anyway.

**Hand-off:** CI contract for later tickets (full details in scripts/ci/editor/README.md):
- Each job runs `bash scripts/ci/editor/<script>` from the repo root after checkout, and skips with a notice when the script is absent: dart-core→core.sh, flutter-packages→flutter_packages.sh, whisper-host→whisper_host.sh, android-unit→android_unit.sh, android-emulator→android_emulator.sh (inside reactivecircus/android-emulator-runner@v2, API 35, x86_64, google_apis, pixel_6), ios→ios.sh, nightly→nightly.sh.
- Scripts must run on macOS bash 3.2 with `set -euo pipefail` and a `# OWNER:` header, and must resolve the repo root from their own location.
- Environment the workflow provides:
  - DANAVIEW_SANITIZER = none, thread or address (whisper-host matrix; AI-03's whisper_host.sh must honour it).
  - DANAVIEW_CI_CACHE_DIR = $GITHUB_WORKSPACE/.ci-cache, cached by actions/cache (whisper-host caches .ci-cache/whisper).
  - DEVELOPER_DIR selects Xcode 26.6 when it is installed (ios job).
  - LANG = en_US.UTF-8 (ios job).
- The ios job FAILS if ios.sh doesn't contain the string check_ios_min_os.sh (D-41), so ENG-09's ios.sh must call it.
- flutter_packages.sh runs `flutter test --exclude-tags nightly` (override with DANAVIEW_CI_EXCLUDE_TAGS). QA-09 and others tag their long suites `nightly`, declare the tag in dart_test.yaml, and run them from nightly.d/<name>.sh. Repro command: `scripts/ci/editor/nightly.sh <name>`.
- flutter_packages.sh covers danaview_editor_engine_api, danaview_editor_engine (plus example/ pub get when present), danaview_transcription, danaview_whisper, danaview_editor_fonts and danaview_editor, then root test/architecture. Analyze runs with --fatal-infos --fatal-warnings. danaview_editor_core stays in core.sh (CORE-01).
- Toolchain pins: Flutter 3.44.2 and Java 17 temurin (workflow env FLUTTER_VERSION / JAVA_VERSION). The self-hosted runner needs the labels [self-hosted, macOS].

Architecture test:
- dependency_rules_test.dart is self-contained (flutter_test + dart:io only) and exposes checkAll(RepoTree), dependencyRules, materialRule, editorTouchedFeatureFiles (17 paths) and featureFilesOwnedInPlan(planText).
- If a future ticket's owns list adds a danaview_features Dart file, the drift test fails until editorTouchedFeatureFiles is updated. That edit needs a FIX-INT-01 ticket.
- Rule 8 (UserConsent.accepted) is not here; it belongs to UX-01's own architecture test.
- Fixtures are trees under test/architecture/fixtures/<name>/ that mirror the repo, with a `.fixture` suffix on every file. They are registered in fixtureExpectations and, where the count matters, in fixtureViolationCounts.

iOS:
- ios/Podfile defines the Ruby constant IOS_DEPLOYMENT_TARGET = '15.0' (used by `platform :ios` and the post_install lift).
- INT-03 is next in the §7 order to touch project.pbxproj; INT-01 changed only the IPHONEOS_DEPLOYMENT_TARGET lines.

Environment warning: the disk on the dev Mac is nearly full (about 137 MiB to 2.7 GiB free during this run). Builds fail with ENOSPC, and build/ holds about 6 GB, including 1.3 GB of partial output from the failed APK build in build/app. The lead may want to run `flutter clean` or free space before native builds.

**Verification:** - `flutter test test/architecture`: \"+38 ~1: All tests passed!\" (the skip is rule 7; danaview_editor doesn't exist yet). `flutter analyze --fatal-infos test/architecture`: \"No issues found!\".
- `scripts/ci/editor/flutter_packages.sh`: exit 0. Passed danaview_editor_engine_api, danaview_editor_engine, danaview_transcription, danaview_whisper and architecture; skipped danaview_editor_fonts and danaview_editor; failed none. Failure paths checked in throwaway trees: a failing test and a failing pub get give exit 1 with a summary; an empty DANAVIEW_CI_EXCLUDE_TAGS works; an unknown package gives exit 2.
- `scripts/ci/editor/nightly.sh`: exit 0 ("no scripts in nightly.d yet"). In a throwaway tree, a failing script plus a passing one gives exit 1 with a repro command, and a named run gives exit 0.
- `flutter build ios --no-codesign --debug`: "✓ Built build/ios/iphoneos/Runner.app". `vtool -show-build` reports minos 15.0 and Info.plist MinimumOSVersion is 15.0; media_kit pods are 15.0. Flutter.framework, App.framework and objective_c are Flutter-built at 13.0, which is not project config.
- editor-ci.yml: Ruby YAML parse plus a structural check passed: all 7 required jobs present; push paths equal pull_request paths; runs-on uses only allowed contexts; every step after the script check is gated on it; every action is pinned; expressions are balanced. `bash -n` passes on all 17 run blocks.
- Root `flutter test`: +382 ~1 -1. The one failure already fails at HEAD: settings_account_test "app version matches pubspec.yaml" (danaviewBuildNumber = 1 in packages/danaview_features/lib/src/more/app_info.dart, but pubspec is 1.0.0+2 since commit 388923d). Not an INT-01 file.
- git status: the release workflows (android/linux/windows-release.yml) are unchanged.

### CORE-01, CORE-02, CORE-04, CORE-03, CORE-05, CORE-06, CORE-29

- **CORE-01** (done): Scaffold was already in place (pubspec deps exactly meta/collection/crypto/path/characters, strict analysis, 7 barrels, D-33 placeholders, core.sh). Added to test/purity_test.dart: negative fixtures as files under test/fixtures/purity/ (flutter, flutter_test, danaview_*, dart:io, dart:isolate export, clean positive), and a package-contract group (exact dependencies, strict flags, only the 7 barrels plus testing.dart, every lib/src file reachable from a barrel via export or part, every lib file has an OWNER header). `dart test` also passes with PATH=/usr/bin:/bin and the Dart SDK binary directly (no Flutter on PATH). core.sh runs analyze --fatal-infos, the frame-vector --check, dart test, and the benchmark gate when benchmark/ exists; run end to end, green.
- **CORE-02** (done): time.dart/timecode.dart/ids.dart already matched ARCH §5 and the final D-35 rule (frameIndexNearest, platformTimeOfFrame P(k), frameIndexOfRational). Added ux.md §2.1 aliases FrameRate.numerator/denominator/frameUs. New tests: test/ids/ids_test.dart (prefixes, 12 base62 chars, seeded determinism, 1,000,000 secure draws unique) and test/time/{time_test,timecode_test}.dart (frameIndexOf/timeOfFrame properties over 20k random k per rate plus edges up to 24 h, frameIndexNearest for plan/floor/P(k)/rational forms and for every x within half a frame minus 1 us, P(k) equals Media3's double formula, products < 2^53 and < 2.2e16, quantize/quantizeNearest/TimeRange/MapSegment, Timecode format/parse of 1:23, 1:23:12, 83.5s, +2s, -10f, parse(format(t)) == quantize(t) at all rates incl. beyond 1 h). frame_grid_test.dart extended: committed frame_grid.json covers the required k set (k mod 3 = 0,1,2), every expectation equals k, androidSeekMsRounding placeholder present; regeneration yields no diff (core.sh checks it).
- **CORE-04** (done): Pool types already existed; added value semantics everywhere the AC requires: copyWith on MediaFingerprint/MediaProbe/MediaStat/MediaAccessFailure/ResolvedMedia/PickedMedia/locators/DerivedSpecs/statuses/MediaPool/PoolChange/PoolEdit/PoolDelta, full MediaAsset.copyWith (id, kind, origin, addedAt too), == and hashCode for MediaStat, MediaAccessFailure, PoolChange, PoolEdit, PoolDelta, and bookmark bytes now participate in PickedMedia/ResolvedMedia equality. quickHash fixtures: test/fixtures/quickhash/quickhash_vectors.json (1 B, 64 KiB, 64 KiB+1, 100 KiB, 128 KiB, 3 MiB plus empty -> '') produced with danaview_data's MediaIdentityService.computeQuickHash (procedure and generator script in the fixture README.md); computeQuickHash matches all. Tests in test/model/pool/ (pool_types_test, quick_hash_test): equality/hashCode/copyWith, exhaustive switches over every sealed hierarchy, specHash golden values, MediaPort fake.
- **CORE-03** (done): Model already complete; added copyWith to every remaining value type (Box/Stroke/ShadowStyle, SubtitleCueDraft, CaptionProvenance, SegmentationSettings, CaptionScopeData, CustomSubtitlePosition, TransitionRef, Keyframe/KeyframeTrack/KeyframeSet/KeyframeRef, SpeedPoint/SpeedRamp/ConstantSpeed, AspectRatio, backgrounds, looks (+LookRef.withIntensity), FromPlayerOrigin), EditProject.name (ux.md §2.1), Timeline.mainTrack and the canonical-order/band helpers TrackOrder (isCanonical, insertIndexFor, mainTrack, zOrder, zRankOf, displayOrder per D-09, bandsAscend). Tests in test/model/core/: value_semantics_test (== / hashCode / copyWith with a variant per field for ~60 types, defaults per ARCH §6, even canvas px, unmodifiable lists, structural sharing), project_index_test (getters, index built once per instance), track_order_test.
- **CORE-05** (done): Implemented lib/src/model/keyframes/property_keys.dart (PropertyKey<T> with id, displayName, unit, min/max/step/default, displayScale, keyframable, channel ids, appliesTo, read/write, accepts/clamp; PropertyKeys registry of 58 keys: position, scale, rotation, opacity, flips, fit, crop, 8 adjust, sharpness/blur/vignette, look intensity, chroma enabled/color/similarity/smoothness/spill, mask shape/center/size/rotation/corner/feather/opacity/invert, volume, mute, fades, text style incl. stroke/shadow/background sub-keys), keyframe_ops.dart (KeyframeOps shift, scale, partition with boundary keys, setKey/removeKey/moveKey/clear/isAnimated/hasKeyAt/keyTimes, keyframesOf/withKeyframes, valueAtLocalTime) and eval/evaluate.dart (evaluate<T>, evaluateTrack, isAnimated). Keyframable set is exactly ARCH §6.7. Keys outside [0,duration) are kept and ignored by evaluation. Tests in test/keyframes/: 375-case table test over every property (ranges, defaults, channels, applicability, write/read round trip), evaluate tests (linear, hold, rotation without wrap, Vec2, out-of-range ignored), ops tests including property tests (700 random trials, with and without item start) that both halves of a partition match the original at every frame.
- **CORE-06** (done): Implemented eval/speed_math.dart (accurate log1p/expm1, closed-form ramp segment time/offset, RampProfile with total K, timeAtPosition, positionAtTime, speedAtPosition, speedRampIssues, SpeedRamps.crop/speedAt/timeFactor) and eval/clip_time_map.dart (ClipTimeMap toSource, sourceAt, timelineTimeOf, timelineAt, speedAt, sourceOut/sourceRange, static durationFor/sourceLengthOf, splitAt, lower(maxErrorUs: 250), MediaClip.timeMap/sourceOut/sourceRange extension). Verified: closed forms vs adaptive-Simpson integration < 1 us over 10,000 seeded random ramps (total time and inverse); timelineAt(sourceAt(t)) within 1 us over 10,000 random clips; lower() contract (contiguous, interior breakpoints on project-grid frame starts at every rate and start offset, rate in [0.1,10], error <= 250 us at every frame start and breakpoint) over 10,000 random clips incl. reversed; splits of ramped/reversed clips equal the original at every frame; lower() of a 7-point ramp (300 frames) median 11 us vs 200 us budget. Note: the 'typically 10-40 segments' estimate in the docs is not reachable for steep or short ramps at a 250 us tolerance (up to one segment per frame); gentle ramps give a few dozen.
- **CORE-29** (done): Types, codec, schema, effects_reference.md and validator already existed and were verified against ARCH §11.2-11.7. Added validator rules (asset uri scheme/proxy, rot, lut n 2-65, sprite sw/sh/sscale, anim value ranges per channel, empty channels, sprite/media z bands per §11.4, base positive, finite xf, canvas-mask sizes, audio stream) and skip grid cascades for an invalid gridFps; JsonUtf8Encoder in the codec (encode 2,000 layers: warm median 8-17 ms in Isolate.run under JIT, AOT cold 10-24 ms, gate 40 ms). Corpus now 34 valid hand-written fixtures (plans, patches, transients incl. every animatable channel, every transition as lowered windows, holds, reversed rendition, speed ramp maps, sprites with reveal, LUT/HDR assets, gain up to 2.0, no-audio export, gridFps != fps, empty plan), grid_cuts_30fps.json + expected_active.json for all 90 frames (edges at frames 31, 32, 61, 62), 82 invalid fixtures (one per violation code and many invariants, each isolating exactly one invariant), 19 invalid_format fixtures (decode error paths), 3 tolerant fixtures (unknown keys ignored), README.md. Tests (test/plan/schema, test/plan/types): every valid fixture validates against the JSON Schema and round-trips byte-identically, schema negative tests (~50), coverage test that every schema key and every animatable channel appears in a fixture, codec tests incl. 300 random plan typed round trips, validator edge cases, sprite/encode types, benchmark.

**Deferred:**
- frame_grid.json `androidSeekMsRounding` stays null by design: AND-01 measures it and ENG-06 records it (generator preserves the recorded value).
- Docs claim 'typically 10-40 segments' for ramp lowering at 250 us; measured: steep or short ramps need up to one segment per frame, gentle ramps a few dozen. Contract (<= 250 us at every frame start, breakpoints on frame starts, rates in [0.1,10]) is met; consider relaxing the doc wording or the tolerance in a later review.
- The JIT cold first encode of a 2,000-layer plan is ~55 ms under `dart test`; the 40 ms gate is asserted on the warm median (and AOT cold is 10-24 ms).

**Hand-off:** ClipTimeMap (eval.dart): ClipTimeMap(start, duration, sourceIn, speed, reversed, rate) or clip.timeMap(rate); toSource/sourceAt(t) (absolute timeline time), timelineTimeOf/timelineAt(s) (exact inverse; null if trimmed away; reversed clips valid for s in (sourceIn, sourceOut]), speedAt, sourceOut/sourceRange (rate-free: ClipTimeMap.sourceLengthOf(duration, speed), clip.sourceOut/sourceRange), static ClipTimeMap.durationFor(sourceRange, speed, rate) = max(1 frame, quantizeNearest(T)), splitAt(at) -> (leftSpeed, rightSpeed, leftSourceIn, rightSourceIn, leftDuration, rightDuration) using SpeedRamps.crop (use it for SplitItems, CORE-10/12), lower({maxErrorUs: 250}) -> increasing MapSegments; for reversed clips the map is in REVERSED-RENDITION time (0 at clip start, r = sourceOut - s), for forward clips in source time; sourceOut = sourceIn + round(duration/K) clamped so the average rate stays in [0.1,10]. Speed ramps: SpeedRamp points are speed over normalized SOURCE position (x0=0, xn=1, y in [0.1,10]); validate with speedRampIssues(ramp); RampProfile gives K, positionAtTime, timeAtPosition. Keyframes: PropertyKeys.* singletons (PropertyKeys.all/byId/byChannel/forItem), PropertyKey.read/write (static value only, throws ArgumentError when not applicable), accepts/clamp for InvalidValue checks; KeyframeOps.setKey/removeKey/moveKey/clear/shift/scale/partition; evaluate(item, key, t) with t = item-local time = T - item.start; TIME CONVENTION: key local time = absolute frame time T minus item start (subtraction is exact; shift by -(newStart-oldStart) on start trim; pass itemStart: to KeyframeOps.scale/partition so frames are picked in absolute time); keys outside [0,duration) are kept but ignored by evaluate. Partition adds boundary keys only where needed (left half last frame, right half at 0). Model: EditProject.name, Timeline.mainTrack, TrackOrder helpers (insertIndexFor keeps canonical order, displayOrder per D-09), LookRef.withIntensity, FrameRate.frameUs/numerator/denominator. Pool: all pool types have copyWith/==/hashCode; quickHash fixtures in test/fixtures/quickhash/quickhash_vectors.json. RenderPlan: PlanValidator now also checks asset uri scheme (file:// or content://), lut n 2-65, sprite sw/sh/sscale, anim channel value ranges, sprite layers z >= 20000 and media/image layers z < 20000 (solids anywhere), finite xf, positive base, canvas-mask sizes, stream >= 0; it skips grid checks when gridFps is invalid. Contract corpus layout: contract/*.json valid (canonical single line + trailing newline), invalid/ (_expect {code,id}; each isolates one invariant), invalid_format/ (_expect {path}), tolerant/, README.md; native tests (IOS-08/AND-08) should read the same folders. Fixture asset ids use 15-char ids such as md_clipA0000001; grid_cuts_30fps.expected_active.json lists frames 0..89. Dart plan encode uses JsonUtf8Encoder; PlanJson API unchanged.

**Verification:** cd packages/danaview_editor_core: `dart analyze --fatal-infos` -> No issues found. `dart test` -> 973 tests, All tests passed (about 10 s; also passes with PATH=/usr/bin:/bin and the Dart SDK binary, no Flutter on PATH). `bash scripts/ci/editor/core.sh` (pub get, analyze --fatal-infos, gen_frame_vectors --check, dart test) -> exit 0. Dependents unaffected: `dart analyze` on danaview_editor_engine_api, `flutter analyze` on danaview_transcription and danaview_editor_engine -> No issues; danaview_editor_engine_api `flutter test` -> All tests passed. No native build was required by these tickets. Benchmarks: ClipTimeMap.lower 7-point ramp (300 frames) median 11 us (budget 200 us); encodePlanBytes of 2,000 layers in Isolate.run: warm median 8-17 ms under JIT, AOT (dart compile exe) cold 10-24 ms (budget 40 ms).

### API-01

- **API-01** (done): The contract (ARCH §12.1-12.5), failures, FakeEditorEngine and contract kit are complete. The package analyzes clean with --fatal-infos and its 45 tests pass. The repo's INT-01 dependency_rules_test.dart also passes (38 pass, 1 skipped). Two deviations: the contract kit lives in lib/src/fake/engine_contract.dart, because a lib file can't export from test/, and test/contract/engine_contract.dart re-exports it. The 'iOS 15/16 device' acceptance criteria don't apply to this ticket. What I did on top of the earlier scaffold:
- **Fake engine:**
  - Shared FakeCallLog: calls[] and failNext[name] now cover every service (e.g. 'preview.seek', 'exporter.start', 'jobs.proxy', 'thumbnails.request', 'picker.pick').
  - Deterministic clock: FakePreviewSession.advanceFrames(n) moves it, with loop and end-of-plan stop.
  - Plan checks: plans are validated with PlanValidator and throw planInvalid unless validatePlans: false.
  - Added emitEvent, a scrub offset, and recorded quality / proxies / source frame / mode.
  - Scriptable recorder, thumbnail handles with cancel, and export jobs with cancel.
  - New FakeTexturePlaceholder widget (plain widgets, no Material).
- **Contract kit:** checkEngineContract(engine, {settle, exportOutputPath, checkExportRecords}) now checks:
  - capabilities caching,
  - stale patch -> planOutOfSync and recovery by full resend,
  - transients not touching the revision,
  - clock seq rules and clock time on the grid,
  - exact-seek acks including the 1 µs-before-frame case, and scrub acks,
  - job cancel semantics,
  - export reattach, when exportOutputPath is set,
  - one-shot records.
  Mutant-engine tests show the kit reports engines that break individual rules.
- **Capabilities:** copyWith now covers every field (it can clear unsupportedReason), and equality and hashCode cover all of them.
- **Docs:** every public top-level type's dartdoc links an ARCH section or decision; api_surface_test.dart enforces this.
- **Dependencies:** api_surface_test.dart enforces ARCH §4.2 rule 3 for the package (allowed deps only, no dart:io, no Material).
- **Placeholders (D-33):** declared public names that throw UnimplementedError, with // OWNER headers:
  - API-02: PlanSync / PlanSyncStatus in plan_sync.dart, PlanTransport in plan_transport.dart.
  - API-03: RenderMath in math/render_math.dart; ReferenceRenderer and ReferenceAudioMixer in reference/.
  - API-04: FontResolver / TextLayoutEngine, TextSpriteRasterizer, VspriteCodec and SpritePrepass in render_prep/.

**Deferred:**
- Nothing deferred in API-01. AI-01 and AI-03 stay deferred as instructed, until the owner permits the whisper.cpp download.

**Hand-off:** Facts for later tickets:\n- **Barrel:** import package:danaview_editor_engine_api/danaview_editor_engine_api.dart. It re-exports the core types PickedMedia, MediaProbe, EncodeSettings, ExportContainer, VideoCodec, RenderPlan, RenderPlanPatch, PlanTransient, ResolvedMedia and MediaAccessPort / MediaAccessFailure. It also exports plan_sync, plan_transport, math/, reference/ and render_prep/ (placeholders).\n- **Test support:** import package:danaview_editor_engine_api/testing.dart for FakeEditorEngine, checkEngineContract, contractKitPlan / contractKitPatch / contractKitGrid / contractKitItem, and FakeTexturePlaceholder(textureId, size).\n- **Failures:**\n  - EngineFailure is sealed: EngineError(code, ...) and EngineCancelled.\n  - EngineFailure.of(code, ...) picks the subtype; EngineErrorCode.fromName maps unknown names to internal.\n  - Job and export futures complete with EngineCancelled after cancel().\n- **FakeEditorEngine:**\n  - engine.calls and engine.failNext['<method>'] control the call log and one-shot failure injection. Keys: 'capabilities', 'compatibility', 'probe', 'openPreview', 'freeBytes', 'trimCaches.<level>', 'preview.<method>', 'exporter.preflight/start/resume/activeJobs/consumeJobRecord', 'jobs.proxy/reverse/freezeFrame/extractSpeechAudio', 'waveforms.peaks', 'thumbnails.request', 'recorder.*', 'picker.pick', 'files.saveToPhotos/saveToFiles/share'. Job-creating keys deliver the failure through the job's result future instead of throwing.\n  - Tests drive time and jobs themselves: session.advanceFrames(n), FakeMediaJob.report/complete/fail, FakeExportJob.report/finish/fail, exporter.records for scripted jobs, plus emitEvent and emitSignal.\n  - Sessions validate plans (planInvalid) unless FakeEditorEngine(validatePlans: false). Patch checks (`from`, structural flag) use the fake's own applyFakePatch because core's plan_diff.dart is still the CORE-32 placeholder; once CORE-32 lands, the fake could switch to core's applyPatch.\n- **Contract kit:** checkEngineContract(engine, {settle: Duration.zero, exportOutputPath, checkExportRecords}) returns a list of violations, empty means pass. ENG-01 and ENG-09 should pass settle ~100 ms and, on a real device, an exportOutputPath with a plan that has real media. It is framework-free.\n- **EditorCapabilities:** copyWith covers every field; pass unsupportedReason: null to clear it. EditorCapabilities.unsupported(reason) is the unsupported value; UnsupportedReasons holds the string constants.\n- **Later tickets:** API-02 owns plan_sync.dart and plan_transport.dart (PlanSync(session, compile:), PlanSyncStatus, PlanTransport.encodePlan/encodePatch/encodeTransient). API-03 owns math/ and reference/ (RenderMath, ReferenceRenderer, ReferenceAudioMixer). API-04 owns render_prep/ (FontResolver, TextLayoutEngine, TextSpriteRasterizer, VspriteCodec, SpritePrepass). Each replaces its own placeholder files; the barrels already export them.\n- **Formatting:** the package uses `dart format -l 140`.\n- **Package tests:** api_surface_test.dart in the package enforces ARCH §4.2 rule 3 (allowed deps only, no dart:io, no Material imports) and dartdoc with an ARCH/D-/BUILD_PLAN reference on every public top-level type, so new types added by later tickets must carry such a reference.

**Verification:** In packages/danaview_editor_engine_api, `flutter analyze --fatal-infos` printed 'No issues found!'. `flutter test` printed 'All tests passed!' with 45 tests. From the repo root, `flutter test test/architecture/dependency_rules_test.dart` printed 'All tests passed!' (38 pass, 1 skipped). In packages/danaview_editor_engine, `flutter analyze --fatal-infos` printed 'No issues found!'. Formatting uses `dart format -l 140` (the existing style; do not run plain `dart format` on these files). No native build is required for this ticket.

### ENG-01

- **ENG-01** (done): Resumed from an earlier attempt that had already written the Pigeon surface, generated code, Dart engine, router, mapper, placeholders and tests; nothing was redone. This round: (1) checked every file against BUILD_PLAN ENG-01 and ARCH §4.4/§12.1-12.6. (2) Raised the minimal podspec placeholder from iOS 13.0 to 15.0 because INT-01 landed (D-43(c) owner defaults 2026-10-08) and updated its stale comment. (3) Proved the plugin builds by compiling it inside a throwaway host app in the scratchpad, without touching example/ (owned by ENG-09). The debug APK built (generated Kotlin and DanaviewEditorEnginePlugin.kt compiled), and the iOS simulator app built (generated Swift and the placeholder plugin compiled; the pod's minos is 15.0). The build outputs were then deleted.
Acceptance criteria:
- Every EngineErrorCode maps: error_mapper_test covers PlatformException, FailureMsg, the full Pigeon round trip, unknown code -> internal, channel-error -> notSupportedOnDevice, and paths scrubbed.
- Events demultiplexed and throttled: event_router_test covers clock <= 10 Hz, progress <= 4 Hz and levels <= 20 Hz on fake time; state changes pass at once; unclaimed routes are buffered and replayed; terminal events and release are handled.
- Resumable and completedWhileDetached records decode: job_records_test covers the codec round trip of all four states, plus start(whenDetached)/resume/consumeJobRecord.
- Pigeon regeneration produces no diff: pigeon_regeneration_test regenerates in a temp dir and compares byte for byte.
- Package and placeholders analyze clean: analyze --fatal-infos is clean, and native builds pass on both platforms.

**Deferred:**
- V-N8 (@EventChannelApi working end to end on Swift and Kotlin with a real native stream) can only be confirmed once ENG-07/ENG-08 install EngineEventsStreamHandler. The generated Swift/Kotlin compile, and the Dart side is tested against the mocked event channel.
- The plugin is not wired into the app (not required by ENG-01). INT-03 and later tickets do that.

**Hand-off:** - **Barrel:** `package:danaview_editor_engine/danaview_editor_engine.dart` exports MobileEditorEngine, guardEngineCall and mapEngineError.
  - Construct with `MobileEditorEngine(config: EditorEngineConfig(...))`.
  - Test-only named params: binaryMessenger, messageChannelSuffix, events, limits, now.
  - `MobileEditorEngine.withChannels(EngineChannels)` exists for service tests.
- **Shared plumbing (lib/src/pigeon/engine_channels.dart):**
  - EngineChannels holds the six generated host APIs (engine, preview, jobs, export, recorder, platform), `router` (EngineEventRouter) and `config`.
  - Services must call native through `channels.invoke(() => channels.<api>.<method>(...))`. It sends initialize(roots) once and maps every error to EngineFailure.
  - channel-error (no native handler) maps to notSupportedOnDevice and is remembered.
- **Conversions:** lib/src/pigeon/conversions.dart has Msg<->API converters for every type, e.g. `exportJobStateFromMsg(record, reattach: (id) => ...)` for ENG-04, `previewEventFromMsg` / `frameSizeFromMsg` / `clockFromMsg` for ENG-02, `waveformPeaksFromMsg`, `pickedMediaFromMsg` and `dropFromMsg`.
- **Event router:**
  - Routes: `router.session(sessionId)` (clock/preview/session failure) and `router.job(jobId)`. Job routes cover progress, exportProgress, recorderLevel, interruption, leaseExpiring and the terminal jobDone/failure; the stream closes after the terminal event.
  - Also: `router.release(id)` on dispose/cancel, plus `router.signals`, `router.drops` and `router.failures`.
  - Events that arrive before anyone listens are buffered and replayed to the first listener.
- **Pigeon surface:**
  - Native classes: Swift setup classes are EngineHostApiSetup, PreviewHostApiSetup, JobsHostApiSetup, ExportHostApiSetup, RecorderHostApiSetup and PlatformHostApiSetup, plus EngineEventsStreamHandler. Kotlin uses `XxxHostApi.setUp` and EngineEventsStreamHandler. Error class EnginePigeonError; package com.vecvel.danaview.editor.engine.pigeon.
  - Host methods use `@asyncCallback` (completion handlers / callbacks, no Kotlin coroutines). Methods marked sync are trimCaches, setTransient, clearTransient, cancelThumbnail, cancelJob, setJobPriority and consumeJobRecord.
  - Plans, patches and transients travel as UTF-8 JSON Uint8List. Native errors are `FlutterError(code: EngineErrorCode.name, message without paths, details: {itemId?, mediaFingerprint?, retryable})`.
  - Regenerate with `dart run pigeon --input pigeons/engine_api.dart` from the package root. pigeon_regeneration_test fails on drift.
- **Mock native side for tests:** ENG-02/03/04 can reuse test/glue/support/mock_engine_host.dart via a relative import. It answers channels with the real Pigeon codec through `on` / `fail` / `acceptInitialize` / `installEvents`.
- **Native placeholders:**
  - The podspec is now platform :ios '15.0'.
  - Gradle and the manifest are template placeholders, and both plugin classes register nothing.
  - ENG-07 adds -Werror=unguarded-availability-new and PrivacyInfo; ENG-08 adds Media3, lint.xml and the manifest entries.
- **Build times:** a debug APK build takes about 400 s, and the iOS simulator build took about 1500 s while another engineer's xcodebuild (DVSpikeHost) ran at the same time.

**Verification:** - packages/danaview_editor_engine: `flutter analyze --fatal-infos --fatal-warnings` -> "No issues found!"
- packages/danaview_editor_engine: `flutter test` -> "+43: All tests passed!" This includes pigeon_regeneration_test: "committed Pigeon output equals a fresh regeneration".
- `dart format -l 140 --set-exit-if-changed` on the hand-written files -> "Formatted 20 files (0 changed)".
- Repo root: `flutter test test/architecture/dependency_rules_test.dart` -> "+38 ~1: All tests passed!"
- Native placeholder build, in a throwaway host app in the scratchpad that depends on the plugin by path and calls MobileEditorEngine.capabilities():
  - `flutter build apk --debug --target-platform android-arm64` -> "Built build/app/outputs/flutter-apk/app-debug.apk". The plugin's kotlin-classes include DanaviewEditorEnginePlugin, EngineHostApi and EngineEventsStreamHandler.
  - `flutter build ios --simulator --debug` -> "Built build/ios/iphonesimulator/Runner.app". The plugin framework has 57 EngineHostApiSetup/EngineEventsStreamHandler symbols, and `vtool -show-build` reports minos 15.0.
  - Scratch build outputs were deleted afterwards.

### ENG-05

- **ENG-05** (done): Everything in scope is built and verified. Two items are wired only by ENG-08/ENG-09: the Gradle srcDir line for the Kotlin JVM test and the XCTest/androidTest hookup. Barcode design: 28-cell top band, 2 calibration cells, 16 index bits, CRC-8, 2 guard cells. It is the same in tool/make_fixtures.swift, the Dart, Swift and Kotlin readers, and the README. Readers return ok/noSignal/blended/badGuard/badChecksum, so a cross dissolve reads as blended, never a wrong index. All 19 fixtures are generated into packages/danaview_editor_engine/test_fixtures/media/ (about 12 MB of the 30 MB budget) with manifest.json and a README of per-file semantics, provenance, regeneration command and golden vectors. The fixtures are: frame_counter 1080p30 plus 720p24/25/48/60, clap_flash_av (AAC priming in the elst edit list), vfr_720p, hlg_10bit_720p.mov (HEVC Main10 HLG), rotated_90.mov, speech_10s.m4a, surround_5_1.m4a (centre-only 500 Hz), tone_440hz.wav, tone_1khz.wav, stereo_440l_880r.wav, tone_under_video.mp4, still_4k.jpg, alpha.png, sample_h264_aac.mkv and sample_vp9_opus.webm. Acceptance criteria met. The Dart reader decodes all 240 frames of frame_counter_1080p30 from ffmpeg frames. It also decodes all other counter files, rotated, HLG, VFR and MKV/WebM frames, and finds the flash frames. The Kotlin reader decodes all 240 PNG frames in a JVM JUnit test. Regeneration is semantically equivalent: a fresh run passed in 34 s against the committed manifest. MKV and WebM probe with the expected streams. Deviation recorded in the README: sample_*.mkv/webm are derived locally with the dev-only ffmpeg from our own frame_counter_720p25 plus an ffmpeg sine, not downloaded CC0 files, because of the no-download rule. There is no source URL and they are CC0 by construction. speech_10s.m4a comes from macOS `say` (Samantha); Apple's voice terms are noted as a licence caveat in the README.

**Deferred:**
- Gradle wiring for the Kotlin JVM test: the android/ library's `test` source set must also include src/androidTest/kotlin/com/vecvel/danaview/editor/engine/support so FrameBarcodeTest.kt compiles. The Gradle file belongs to ENG-08/ENG-09, so I only documented the line in the README. Until then the Kotlin test was run with kotlinc and JUnit.
- XCTest and androidTest wiring: loading the fixtures through the example host is verified by ENG-09, as the ticket says. example/ does not exist yet, so FrameBarcode.swift was verified standalone.
- Swift reader on the rotated_90.mov display orientation: native tests must apply the preferredTransform or CMSampleBuffer rotation themselves. No device or simulator test was run for this.
- Whisper-quality check of speech_10s.m4a: only duration and audibility are verified. Transcription accuracy on the macOS `say` voice belongs to the AI tickets.
- The BUILD_PLAN's committed CC0 MKV/WebM with a source URL, replaced by locally derived files (download rule). Owner may swap in third-party CC0 files later; the verifier only checks stream layout and barcodes.

**Hand-off:** ENG-05 handoff
Fixtures and manifest
- Fixtures are in packages/danaview_editor_engine/test_fixtures/media/ with a machine-readable manifest.json. The manifest lists durations, frame counts, tone Hz and dBFS, flash and click times, and the VFR ptsTicks.
- Barcode layout: the top 10% of the frame height (at least 8 px) is split into 28 cells. Cells 0/1 are white/black calibration, cells 2..17 are the 16 index bits MSB first, cells 18..25 are CRC-8 (poly 0x07), and cells 26/27 are an end guard.
- Frame i shows barcode i (also for VFR), and index equals frame number. QA-00 scenario 2 expects barcode 160 at 5 s plus 10 frames on frame_counter_1080p30.
- timescale 2400 is used for CFR fixtures because 600 is not divisible by 48; VFR uses 600.
- The frame_counter_* files have no audio stream. clap_flash_av.mp4 has flashes at frames 30, 75 and 120, with 2 kHz clicks starting at 1.0, 2.5 and 4.0 s.
- tone_under_video.mp4 has a 1 kHz tone at -12 dBFS.
- surround_5_1.m4a has a 500 Hz tone in the centre channel only (AAC order C L R Ls Rs LFE; ffmpeg names the centre FC).
- rotated_90.mov is encoded 1280x720 with a 90 degree preferred transform and displays 720x1280. AVAssetReader and MediaCodec return the raw landscape buffer.
Dart
- Import `package:danaview_editor_engine/testing.dart`: FrameBarcode.read/decode(pixels, width:, height:, bytesPerRow:, order: FramePixelOrder.rgba|bgra, region: FrameBarcodeRegion?).
- Status values: ok, noSignal, blended, badGuard, badChecksum. A blended frame returns a null index.
- For QA, use `FrameBarcode.read(...).status == FrameBarcodeStatus.blended` for "blended barcodes only inside the dissolve window".
- For a letterboxed preview capture, pass `region` for the video area.
- test/fixtures/support/media_tools.dart has forEachRgbaFrame (streams ffmpeg raw RGBA frames), probe, decodeAudioMono, estimateToneHz, peakDbfs, rmsDbfs and videoPts. It is reusable by QA-03 and QA-11 via relative import. Tests skip when the dev-only ffmpeg is missing.
- fixture_verifier.dart verifies a directory against the manifest.
Native readers
- Swift: example/ios/RunnerTests/Support/FrameBarcode.swift. It has read(pixelBuffer:), read(cgImage:), read(pixels:), plus paint for synthetic frames. It has no XCTest import.
- Kotlin: androidTest/.../support/FrameBarcode.kt (pure JVM) plus BitmapFrameBarcode.kt. ENG-08/ENG-09 must add `src/androidTest/kotlin/com/vecvel/danaview/editor/engine/support` to the android library's `test` source set so FrameBarcodeTest.kt compiles. The JVM test uses ../test_fixtures/media found by walking up from user.dir, or the -Ddanaview.fixtures property.
- Fixtures must be exposed to RunnerTests (folder reference ../test_fixtures) and androidTest (assets or srcDir).
Regeneration and licences
- Regeneration: `swiftc -O -swift-version 5 tool/make_fixtures.swift -o /tmp/make_fixtures && /tmp/make_fixtures [--out DIR] [--only a,b] [--skip-containers]`. It is semantically equivalent, not byte identical. DANAVIEW_FIXTURE_REGEN=1 flutter test test/fixtures runs and verifies a fresh regeneration.
- MKV/WebM are derived locally with the dev-only ffmpeg from frame_counter_720p25 (75 frames, 640x360) plus a 440 Hz sine, so there is no third-party source URL. The ffmpeg command lines are in make_fixtures.swift.
- speech_10s.m4a comes from macOS `say` (Samantha). The README records the licence caveat.
Other
- lib/testing.dart is a new small barrel I added; it is not in the BUILD_PLAN ownership list. Remove it if someone prefers src imports.
- README.md in test_fixtures/media is the canonical description of each file.

**Verification:** cd packages/danaview_editor_engine
- flutter analyze: No issues found.
- flutter test test/fixtures test/testing: All tests passed (+48, 1 skipped; the skipped test is the opt-in regeneration test).
- DANAVIEW_FIXTURE_REGEN=1 flutter test test/fixtures/fixtures_semantic_test.dart --plain-name regeneration: All tests passed (+1, 34 s). It compiles the tool, regenerates all 19 files and verifies them against the committed manifest.
- swiftc -O -swift-version 5 tool/make_fixtures.swift: compiles; a full run takes about 15 s.
- Kotlin JUnit run: kotlinc plus JUnitCore on FrameBarcode.kt and FrameBarcodeTest.kt returned OK (7 tests), including all 240 ffmpeg-extracted PNG frames. This was not run through Gradle.
- Swift reader: command-line harness decoded 250 PNG frames and AVAssetReader pixel buffers (BGRA, 420v, x420 HLG). rotated_90.mov reads as noSignal there because AVAssetReader returns the raw landscape buffer, as documented in the README.

### ENG-09

- **ENG-09** (done): Resumed from an earlier attempt that had already written example/lib, integration_test, the Android example and danaview_test_harness.gradle. This round finished the iOS host and the four CI scripts, fixed the JVM test compile, and verified everything.

Acceptance criteria:
(1) `flutter build ios --no-codesign` (release, 13.7 MB) and `flutter build apk` (release, 40.4 MB) of the example both pass with ENG-01's placeholder plugins.
(2) ENG-05 fixtures load in RunnerTests: FixtureHarnessTests 3/3 pass on the iOS 26.5 simulator, including AVAssetImageGenerator frame 160 reading barcode 160. They also load in androidTest: 3/3 pass on the API 35 emulator. JVM tests: 10/10 pass, including ENG-05's all-240-frames Kotlin AC.
(3) CI scripts were run green locally: android_unit.sh fully. ios.sh: device build, D-41 check, self-test and RunnerTests all passed. One run died at `flutter --version` from SIGPIPE, the other hung in `simctl bootstatus`; both were fixed. The smoke test then passed on a manually rebooted simulator. The patched ios.sh (no parallel testing, re-boot before the smoke test) was not re-run end to end. android_emulator.sh: the instrumented tests passed, but its smoke step failed (see deferred).
(4) check_ios_min_os.sh `--self-test` fails all 6 negative fixtures and passes all 4 positive ones. Negatives include a binary strongly binding the iOS 17 symbol CMTaggedBufferGroupGetCount at minimum OS 15.0. It passes on the example: 5 binaries, 808 strongly bound C/ObjC symbols probed, OK.
(5) V-N8 is deferred to ENG-07/ENG-08 per the AC.

Info.plist pre-declares NSMicrophoneUsageDescription, NSPhotoLibraryAddUsageDescription and BGTaskSchedulerPermittedIdentifiers=[com.vecvel.danaview.export.*]. The Podfile uses platform 15.0 with a post_install lift, and the pbxproj targets 15.0 in all configurations.

**Deferred:**
- Android engine_smoke_test on the dev emulator. It is blocked by INSTALL_FAILED_INSUFFICIENT_STORAGE: the shared Pixel_9_Pro_XL_API_35 emulator's /data is 95% full of other apps. I did not uninstall anyone's apps; pm trim-caches freed nothing. It runs in CI's fresh API 35 emulator through android_emulator.sh. The same Dart smoke test passes 4/4 on the iOS simulator, and the plugin's instrumented tests pass on this emulator.
- V-N8 (@EventChannelApi on Swift + Kotlin) is to be confirmed by ENG-07/ENG-08 per the AC.
- WhisperCore.xcframework build and its check_ios_min_os pass: AI-05's build script does not exist yet and CMake >= 3.28 is not installed on this Mac. ios.sh fails early with `brew install cmake` unless DANAVIEW_ALLOW_MISSING_CMAKE=1 is set (local only, and only while the AI-05 script is absent).
- iPhone 7/8 lab checks: deferred, no device available (owner default D-43). iOS 15/16 are covered by check_ios_min_os.sh.
- ios.sh was not re-run end to end after the last fixes (no parallel testing, re-boot before the smoke test). Each step passed individually, and the full run takes over 40 minutes on this 8 GB machine while another engineer's simulator work runs.

**Hand-off:** CI scripts (all in scripts/ci/editor/, bash 3.2 safe):
- `check_ios_min_os.sh [--min 15.0] [--allow-weak NAME]... PATH...` and `--self-test`. It runs three checks:
  - (1) Minimum OS via vtool -show-build, or otool -l for archive members.
  - (2) Linked libraries. A strongly linked framework or Swift dylib from NEWER_LIBRARIES (post-15.0 list in the script) fails. A weak-linked newer framework fails unless it is on WEAK_ALLOWLIST (default BackgroundTasks, extend with DANAVIEW_MIN_OS_WEAK_ALLOW). ld weak-links floor frameworks by itself when every reference is guarded, so those are only listed.
  - (3) Every non-weak undefined C/ObjC symbol (`nm -um`) is probed by compiling `-target arm64-apple-ios15.0 -Werror=unguarded-availability(-new)` against the SDK umbrella headers. Swift and C++ mangled symbols are not probed.
  - Accepted inputs: .app, .framework, .xcframework (ios-* slices only), .a, or any dir.
- `ios.sh [--no-device-build|--no-sim-tests]`: DANAVIEW_IOS_SIMULATOR picks the simulator; xcodebuild test runs with -parallel-testing-enabled NO.
- `android_unit.sh`: DANAVIEW_ANDROID_APK_MODE=release|debug|none.
- `android_emulator.sh`: ANDROID_SERIAL picks the device.

iOS host:
- RunnerTests is a PBXFileSystemSynchronizedRootGroup. Native tickets just add example/ios/RunnerTests/<Topic>/*.swift without touching the pbxproj (ENG-07 uses Glue/).
- Flutter's migration rewrites objectVersion to 54 on every build. Xcode 26.6 still compiles the synchronized folder (verified), so leave it.
- Fixtures sit in the test bundle at Bundle(for:).resourceURL/{engine,core,engine_api}/ (engine/media/...). They come from relative symlinks in example/ios/TestFixtures, which Xcode resolves when copying.
- The TestFixtures helper enum in RunnerTests/Harness/FixtureHarnessTests.swift has root(_:) and url(_:_:). Reuse it.
- On this Mac the simulator test phase can take about 20 minutes. Do not use `simctl bootstatus`; it hangs.

Android harness (example/android/danaview_test_harness.gradle, applied to :danaview_editor_engine):
- Adds the support/ source root to src/test.
- Extracts the JDK's java.awt and javax.imageio classes into a testCompileOnly jar. Android unit tests compile against android.jar, which lacks ImageIO.
- Passes these system properties: danaview.fixtures = engine test_fixtures/media (ENG-05's contract), danaview.fixtures.engine = test_fixtures root, plus danaview.fixtures.core and danaview.fixtures.engine_api.
- androidTest assets: fixtures/engine, fixtures/core, fixtures/engine_api. Use TestFixtures.kt in androidTest/.../harness (list, readText, copyToCache).
- ENG-08 may move these settings into the plugin's build.gradle.kts; the harness skips duplicates.
- The example's gradle.properties heap was lowered to -Xmx3G.

FINDING for AND-xx, QA-00 scenario 2 and QA-02:
- On the API 35 arm64 emulator, MediaMetadataRetriever.getFrameAtTime(160.5/30 s, OPTION_CLOSEST) and getFrameAtIndex(160) both return barcode 162 for frame_counter_1080p30.mp4. The file has standard ctts v0 plus elst media_time 40/600, which is a 2-frame B-frame delay.
- ffmpeg, AVFoundation and the JVM reader all agree that index equals frame number. The platform retriever's timeline therefore runs 2 frames off.
- Android frame-exact paths must apply the edit list themselves (Media3 does) and be verified with these fixtures.
- The harness instrumented test asserts only a readable barcode within 158..162 and logs the offset (tag DanaviewFixtureHarness).

Other notes:
- ENG-05's handoff says CFR fixtures use timescale 2400, but frame_counter_1080p30.mp4 uses 600.
- scripts/ci/editor/README.md (INT-01's file) already documents these scripts' owners. Its "Running locally" section does not list them yet.

**Verification:** - `flutter analyze --fatal-infos --fatal-warnings` (example and danaview_editor_engine): No issues found.
- `bash scripts/ci/editor/check_ios_min_os.sh --self-test`: "check_ios_min_os.sh self-test passed" (10/10 expected exits).
- `bash scripts/ci/editor/android_unit.sh` (release APK + `:danaview_editor_engine:testDebugUnitTest`):
  - "Built build/app/outputs/flutter-apk/app-release.apk (40.4MB)"
  - "BUILD SUCCESSFUL"
  - "android-unit: OK" (10/10 JVM tests)
- `bash scripts/ci/editor/android_emulator.sh`:
  - connectedDebugAndroidTest "BUILD SUCCESSFUL" (3/3 on Pixel_9_Pro_XL_API_35).
  - The smoke step failed with INSTALL_FAILED_INSUFFICIENT_STORAGE (shared emulator).
- `DANAVIEW_ALLOW_MISSING_CMAKE=1 bash scripts/ci/editor/ios.sh`, first run (device half):
  - Self-test passed.
  - "Built build/ios/iphoneos/Runner.app (13.7MB)"
  - "check_ios_min_os: floor iOS 15.0, 5 binaries, 808 strongly bound C/Objective-C symbols probed (73 not declared in the probe headers, not checked) ... OK"
  - This run then hung in `simctl bootstatus` and was stopped.
- `ios.sh --no-device-build`: RunnerTests FixtureHarnessTests passed 3/3 on the iPhone 17 Pro iOS 26.5 simulator. This run had no device-build step; its smoke step found no device because xcodebuild had shut the simulator down (fixed).
- `flutter test integration_test/engine_smoke_test.dart -d <iPhone 17 Pro sim>`: "+4: All tests passed!"

### AI-02, AI-06, AI-08

- **AI-02** (done): Resumed from existing work; verified rather than redone. danaview_whisper is an FFI plugin for ios and android only. src/dv_whisper.h is C ABI v1. ffigen bindings are committed and the regen test shows no diff. WhisperSupport covers platform, abi and osVersion. The runtime API names exist, and WhisperRuntime.open() returns unsupported(platform) on macOS, Windows and Linux, tested. The ABI version const is 1 and is tested. Placeholders exist for runtime/, ffi/library_loader.dart (no DynamicLibrary opened at import), ios podspec (platform 15.0, builds without the native library) and android build.gradle.kts and manifest (no CMake, no armeabi-v7a). Tests: 44 passed, analyze clean.
- **AI-06** (done): Dart side: device_profile, device_events and device_channel on the danaview_whisper/device method and event channel; parsing is defensive. iOS: DeviceProfiler.swift and DanaviewWhisperPlugin.swift, covering the profile (os_proc_available_memory), thermal, low-power and memory-warning events, lifecycle events, excludeFromBackup with URLResourceValues read-back, and begin/endBackgroundTask with expiry events. Android: DeviceMath.kt (thermal mapper, trim levels, cpuinfo and memory math), DeviceProfiler.kt, ThermalMonitor.kt, DanaviewWhisperPlugin.kt and the ACCESS_NETWORK_STATE manifest permission. Tests: Dart unit tests including malformed maps, channel contract, and a Swift macOS host harness that checks backup read-back (all pass). The 18 Kotlin JUnit tests pass when run through kotlinc and JUnitCore. Gradle was not run. The iOS plugin sources typecheck against the iPhoneSimulator SDK and Flutter.framework at ios15.0 with -Werror=unguarded-availability-new. The manual on-device checklist on one iOS and one Android device is deferred: no device available.
- **AI-08** (done): danaview_transcription package with contracts (D-21 TranscriptionService, phases, progress and ETA, TranscriptionFailure and ModelDownloadFailureKind, ConsentDisclosure and UserConsent, ports, TimelineView), a pinned catalog (host huggingface.co, CDN hf.co, sizes and sha256 per ARCH 16.2, Fast/Balanced/Accurate RAM gating, Accurate hidden below 4 GB), the QA-06 tuning placeholder, the 99 languages with BCP-47 tags, native names and script profiles, and D-33 placeholders for models_store, transcript, segmentation, timeline, pipeline and governor. testing.dart has FakeTranscriptionService (scriptable phases, failures, download progress, resumable jobs). Added test/contracts/dependency_rules_test.dart this round (pubspec and imports restricted to core, whisper and data; no Flutter UI imports). Tests: 63 pass, analyze clean.

**Deferred:**
- Manual device checklist for AI-06 on one iOS and one Android device (excludeFromBackup read-back on device, thermal and memory events): deferred, no device available.
- Gradle-driven Android unit tests and the AGP build were not run; the Kotlin tests were run through kotlinc and JUnit instead.
- Native whisper build (CMake, AI-03/04/05) is the next round; the plugin builds without the native library.
- ARCH D-43 already records the owner defaults dated 2026-10-08 (written by INT-01); no change was needed.

**Hand-off:** Earlier attempts had already finished almost everything for AI-02, AI-06 and AI-08, so this round verified it and added one test (packages/danaview_transcription/test/contracts/dependency_rules_test.dart). Facts for later tickets. (1) AI-07 owns lib/src/runtime/runtime.dart and lib/src/ffi/library_loader.dart. Both are placeholders: WhisperRuntime.open() returns unsupported(platform) on desktop and unsupported(libraryUnavailable) on iOS and Android, and loadModel throws WhisperException(libraryUnavailable). The public API names are declared in runtime.dart and whisper_types.dart. (2) dv_whisper.h is C ABI v1 and dvAbiVersion is 1; regenerate the bindings with `dart run ffigen --config ffigen.yaml`, and the test test/abi/ffigen_regen_test.dart guards against a diff. (3) The device channel is danaview_whisper/device, with a method channel and an event channel. WhisperDeviceChannel parses defensively and has a fake-friendly constructor. (4) AI-05 owns the iOS podspec (platform 15.0) and will add the xcframework, dv_whisper_forwarder.cpp and PrivacyInfo.xcprivacy with DiskSpace E174.1. AI-04 owns android/build.gradle.kts (placeholder, no CMake, no armeabi-v7a) and the manifest. (5) Native Kotlin helpers are pure functions in DeviceMath.kt with JUnit tests; Gradle was not run. Without Gradle they can be run with kotlinc plus JUnitCore with kotlin-stdlib on the classpath. (6) danaview_transcription imports danaview_whisper only for WhisperDtwPreset and depends on core, whisper and data; dependency_rules_test enforces this and has no Flutter UI imports. (7) Catalog sizes and hashes are guarded against ARCHITECTURE.md §16.2 by a drift test in catalog_test.dart.

**Verification:** flutter analyze in packages/danaview_whisper: No issues found. flutter test in packages/danaview_whisper: All tests passed (44, including ffigen regen with no diff and the Swift host harness). flutter analyze in packages/danaview_transcription: No issues found. flutter test in packages/danaview_transcription: All tests passed (63, including the new dependency rules test). Kotlin: kotlinc plus JUnitCore ran ThermalMapperTest, TrimLevelsTest, MemoryMathTest and CpuInfoTest, OK (18 tests). Swift: swiftc -typecheck of ios/Classes/*.swift against the iphonesimulator SDK and Flutter.xcframework at arm64-apple-ios15.0-simulator with -Werror=unguarded-availability-new produced no output and no errors. No native whisper build was attempted (CMake is not installed).

### UI-01

- **UI-01** (done): All six components exist, are exported from danaview_ui_kit.dart and tested. Five were already written by an earlier attempt: progress bar, number field, colour picker, search field, step indicator. This attempt fixed the compile errors in the colour picker and the hue-strip gradient crash, which only showed at paint time. It also fixed two number-field bugs and wrote the docked panel and the test file. All acceptance criteria are met, with no deferrals. Overflow and surface checks cover the kit's four shared surfaces plus widths 280/320/360/412/600/900/1280 at text scale 0.85/1.0/1.35, for every component. Keyboard, focus and semantics tests are in place for each component. Contrast is checked through DanaviewColors.foregroundOn and token-pair assertions. A grep test confirms none of the six files reference forbidden Material widgets (list mirrors ARCH 1.3 rule 1) or set a font family, and the barrel exports all six.

**Hand-off:** API for later tickets (all exported from package:danaview_ui_kit/danaview_ui_kit.dart):
- DanaviewProgressBar({double? value, height=6, color, trackColor, semanticLabel, semanticFormatter}). A null value draws an indeterminate bar. It fills the width it is given, or 160 when unbounded.
- DanaviewNumberField({required value, required onChanged, min, max, step=1, fractionDigits, unit, label, semanticLabel, bipolar, showSteppers, enabled, formatter, parser, scrubPerPixel, onChangeStart, onChangeEnd, focusNode, autofocus}).
  - Typed text commits on submit or blur, and Escape reverts. Up/Down step the value, Shift or PageUp/PageDown step by x10, and dragging the label scrubs it.
  - onChangeStart/onChangeEnd bracket each step, scrub or commit, for undo coalescing.
  - Steppers hide when the control is narrower than 150 px.
  - The widget tracks the last reported value, so key repeat that outruns a rebuild still steps correctly.
- DanaviewColorPicker({required color, required onChanged, onChangeStart, onChangeEnd, showOpacity=true, swatches, FutureOr<Color?> Function()? onEyedropper, areaHeight=160, semanticLabel}).
  - It needs a bounded width and its height grows with its content, so put it in a scrolling body.
  - Static helpers: formatHex and parseHex use CSS order (RRGGBB or RRGGBBAA).
  - It keeps the hue while the colour passes through grey or black.
- DanaviewDockedPanel({required child, title, onClose, detent=DanaviewDockDetent.standard, onDetentChanged, standardHeight=240, expandedFraction=0.85, maxWidth, scrollable=true, padding, showDragHandle, semanticLabel}).
  - DanaviewDockDetent has `standard` and `expanded` (not "default", which is a Dart keyword).
  - Place it with Positioned(left:0,right:0,bottom:0) in a Stack, or at the bottom of a Column. It is non-modal.
  - It lifts by MediaQuery.viewInsets.bottom, which is 0 when a Scaffold has already resized for the keyboard.
  - The handle is its own semantics node labelled "Resize panel". Enter/Space toggle, Up expands and Down collapses.
  - Static DanaviewDockedPanel.heightFor(...) lets layouts reserve room for the dock. The widget's own rect includes the keyboard lift, so tests should measure its AnimatedContainer instead.
  - The inspector's default dock height, max(240, timelineHeight + toolStripHeight - 76), is passed in through `standardHeight`.
- DanaviewSearchField({controller, focusNode, hint='Search', debounce=250ms, autofocus, enabled, onChanged, onSubmitted, semanticLabel}). onChanged is debounced. It fires immediately on clear and before onSubmitted, and pending callbacks are dropped on dispose.
- DanaviewStepIndicator({required step (1-based, clamped), required count, label, showLabel, semanticLabel}). The label is the single announcement.
Lessons for tests that use these:
- `find.bySemanticsLabel` needs `tester.ensureSemantics()`. Use `find.semantics.byLabel(...)` with `tester.semantics.performAction`.
- Pump a looping animation (indeterminate progress bar) with `pump(duration)`, not `pumpAndSettle`.
- The kit's package-level test helpers are `pumpKit`, `surfaces`, `expectNoErrors` and `expectInside` in packages/danaview_ui_kit/test/test_utils.dart.
Not done in this ticket: the owner-default D-43 note in ARCHITECTURE.md was not written (no UI-01 acceptance criterion needs it). No git commands were run.

**Verification:** In packages/danaview_ui_kit, `flutter analyze` gives "No issues found!". `flutter test` for the whole package gives "+306: All tests passed!"; the new test/editor_components_test.dart accounts for 203 of those, so the existing kit tests still pass. No native build is required for this ticket.

### UX-01

- **UX-01** (done): Nothing existed for this ticket at the start, so the whole package was built in this round.

**Package**
- Created packages/danaview_editor.
  - pubspec deps: flutter, flutter_riverpod ^2.5.1, danaview_editor_core, danaview_editor_engine_api, danaview_transcription, danaview_editor_fonts, danaview_ui_kit, danaview_data, danaview_platform, danaview_domain, danaview_features, plus shared_preferences, collection, meta, path, characters. Dev deps: flutter_test, integration_test, fake_async, flutter_lints ^6. There is no go_router and no plugin dependency.
  - Strict analysis_options. The barrel lib/danaview_editor.dart exports whole files.

**App layer**
- editor_availability.dart:
  - EditorAvailability.platform / resolve / showsEntryPoints / fromCapabilities.
  - Sealed EditorSupport: EditorSupported, EditorHidden(EditorHiddenReason.platform|flagOff), EditorUnsupported(reason). There is no teaser state (D-17).
  - EditorFlags (DANAVIEW_EDITOR, DANAVIEW_AUTO_CAPTIONS, with debug overrides).
  - editorDeviceSupportProvider never throws.
- editor_providers.dart: the ARCH §17.3 root providers and the 10 per-project autoDispose families.
- editor_prefs.dart: EditorPrefs with typed and generic access to `editor.` keys, backed by SharedPreferences or memory.

**Contracts, wiring, debug**
- contracts/: EditorActionId (all 75 ARCH §17.6 ids, with groups), ToolId, sealed InspectorRoute, EditorActionBinding/EditorActionContext and EditorContentTextRegion.
- wiring/action_bindings.dart merges the 21 per-feature binding files and rejects duplicates. wiring/not_available_yet.dart holds the placeholder surface.
- debug/: EditorRebuildCounters and EditorPerfHooks.

**D-33 skeleton**
- 137 placeholders with OWNER headers: every danaview_editor file in ARCH §4.6 / BUILD_PLAN §6, including the adapters/, layout/, transport/, toolbar/, flows/export/ and flows/relink/ directories, and the 21 bindings files.
- timeline_tiles.dart is a working disabled pass-through, as the spec requires.
- assets/looks/README.md (folder declared in the pubspec), the tool/gen_looks.dart stub, and the packages/danaview_editor_fonts placeholder pubspec and library.

**Test support (test/support/)**
- FakeProjectRepository: a stub until CORE-25.
- FakeMediaPoolService.
- EditorTestHarness.
- SurfaceMatrix: full is 84 surfaces; pr is the 6-surface subset.
- Helpers: testSurfaces, expectNoOverflow, expectInside, fitsFully/expectFitsFully, and expectOwnerUiRules / ownerUiViolations.

**Architecture tests (test/architecture/)**
- No Material chrome in lib/ or tool/, matched as whole identifiers; the forbidden list is checked against ARCH §1.3.
- Rule 8: the UserConsent.accepted call site, checked across every lib/ tree in the repo.
- Rule 7: pubspec and imports.
- Skeleton coverage: every path BUILD_PLAN §6 assigns under packages/danaview_editor exists and its header names the right owner; the bindings files equal the wiring list.
- Contract tests: the EditorActionId list is parsed from ARCH §17.6 and compared.
- Each rule fires on its negative fixture, and its look-alike fixture passes. This includes TextField used directly (fires) versus DanaviewTextField (passes).

**Acceptance criteria**
- Package and placeholders analyze clean.
- Availability matrix tests cover platform × flag × web; desktop is always hidden.
- Architecture tests pass and fail on their negative fixtures.
- expectOwnerUiRules fails on the round text button fixtures (circle, pill, stadium, oval) and on non-Figtree chrome (other family, no family, mixed span). It passes on kit buttons, icon buttons, text fields and content text.
- The harness boots the placeholder EditorScreen on the PR surface matrix with no overflow, and the close callback reaches the router.

No git commands were run.

**Deferred:**
- FakeProjectRepository is the stub BUILD_PLAN allows until CORE-25: an in-memory store with seed/open/busy/notFound/rename/duplicate/delete/recovery, a call log and failNext. It should delegate to core `InMemoryProjectRepository` once CORE-25 lands; core lib/testing.dart is still a placeholder.
- FakeMediaPoolService.relink must be scripted through onRelink, because core `EditOutcome` is still CORE-09's placeholder and can't be constructed.
- EditorStorageContributor and SpeechStorageContributor placeholders don't implement StorageContributor yet: package:danaview_features/storage.dart doesn't exist until UX-04. UX-04 and UX-38 add the `implements`.
- Not created by design: the per-feature copy files app/strings/<feature>_strings.dart (owners create them) and a package README (not in UX-01's owns list).

**Hand-off:** **Imports and API**\n- App root: `import package:danaview_editor/danaview_editor.dart`. It exports EditorAvailability/EditorSupport/EditorFlags/editorDeviceSupportProvider, the root providers and families, EditorPrefs, EditorBootstrap (INT-02), adapters (INT-04), EditorLauncher, the storage contributors, EditorScreen, ProjectsScreen, EditorSettingsScreen, and ProjectId/TimeUs re-exported from core. The barrel exports whole files and must not be edited; add public names inside your own exported file.\n- Inside the package, import `src/...` directly. Contracts barrel: `src/editor/contracts/contracts.dart`. Debug barrel: `src/debug/debug.dart`.\n- Flags: `EditorFlags.editorEnabled` and `EditorFlags.autoCaptionsEnabled`. Tests use `EditorFlags.debugEditorOverride` / `debugAutoCaptionsOverride` together with `debugDefaultTargetPlatformOverride`.\n- `EditorAvailability.platform` is `EditorSupported` only on iOS/Android (not web) with DANAVIEW_EDITOR on; otherwise `EditorHidden(platform|flagOff)`.\n- `editorDeviceSupportProvider` returns EditorUnsupported(reason). With no engine, or if the engine fails, the reason is `engine_not_available`. On hidden platforms it never touches the engine.\n\n**Providers**\n- Root providers throw `EditorNotConfiguredError(name)` until overridden: editorEngineProvider, projectRepositoryProvider, mediaPoolServiceProvider, transcriptionServiceProvider, editorPrefsProvider. editorCapabilitiesProvider reads the engine.\n- Each per-project family delegates to a factory in its owner's file, with signature `X fn(Ref<Object?> ref, ProjectId id)` that currently throws UnimplementedError. Owners implement the factory and call `ref.keepAlive()` until close completes:\n  - UX-08: createEditorSession, createEditorController\n  - UX-14: createPlayheadController, createTransportController\n  - UX-09: createViewportController\n  - UX-13: createInteractionController\n  - UX-10: buildTimelineSnapshot\n  - UX-39: createExportController\n  - UX-37: createAutoCaptionsController\n  - UX-40: createRelinkController\n- Notifier families require `X extends StateNotifier<State>`, with state types ExportUiState, AutoCaptionsState and RelinkState. EditorState's placeholder constructor is `const EditorState.opening()`.\n\n**Contracts**\n- Region widgets get the project id from `EditorScope.idOf(context)`. EditorScope already works; UX-07 owns it.\n- InspectorRoute is sealed:\n  - Project-level (target null, kept on re-target): MediaInspector, VoiceoverInspector, OverlayInspector, CanvasInspector.\n  - Item routes take an ItemId, and `retarget` returns a copy for the new item: Transform, Crop, Mask, Speed, Audio(focus: AudioPanelFocus), Adjust, Filters, Chroma, Keyframes, Text(tab: TextPanelTab), ClipInfo.\n  - `SubtitlesInspector({track, cue, section})` and `TransitionInspector(TransitionRef cut)` return null from `retarget` unless the item is unchanged.\n- Panel constructor contract used by InspectorHost (UX-16): `XPanel({Key? key, required XInspector route})`. Panel tickets must keep it.\n- Region placeholders take no projectId: TransportBar, TimelineView, ToolStrip, ToolRail, InspectorHost, PreviewRegion. Screen constructors: `EditorScreen(projectId, initialPlayhead, onClose, onOpenProjects)`, `ProjectsScreen(onBack, onOpenProject: OpenProjectCallback)` where `OpenProjectCallback = void Function(ProjectId, {TimeUs? initialPlayhead})`, and `EditorSettingsScreen(onBack)`.\n- Action bindings: each feature file exposes `List<EditorActionBinding> get <feature>Bindings` (e.g. editBindings, autoCaptionsBindings, subtitleIoBindings). EditorActionBinding fields: id, handler(EditorActionContext), isEnabled, isVisible, disabledReason, label, icon. EditorActionContext provides projectId, context, source and `read(provider)`.\n- `editorActionBindingsProvider` holds the merged map for UX-15's registry. A duplicate id throws DuplicateActionBindingError.\n- `TimelineTiles.disabled().paint(canvas, window, paintDirect)` is the pass-through UX-10 must paint through.\n- Wrap user-content text (preview text overlay, font previews) in `EditorContentTextRegion` so expectOwnerUiRules exempts it. TextOverlayLayer is also exempt by name.\n\n**EditorPrefs**\n- Typed accessors: proxyMedia, previewQuality, centerPlayheadOnTouch, snappingHaptics, newProjectAspect, projectsSort, `splitRatio(kind)` / `setSplitRatio`, exportBackgroundNoticeShown, exportNotificationPermissionAsked, captionsDefaultPreset.\n- Generic `read*`/`write*` methods accept only keys prefixed `editor.`.\n- `EditorPrefs.memory()` for tests; `EditorPrefs.load()` uses SharedPreferences.\n\n**Debug hooks**\n- `EditorRebuildCounters.count(name)` / `record(body)` and the `EditorRebuildProbe` widget.\n- `EditorPerfHooks.timeSync`/`timeAsync`/`begin`/`record` with an EditorPerfMarks.* name, plus `enabled`, `listener` and `samples`.\n- No-ops in release builds; disabled by default.\n\n**Tests**\n- `import '../support/support.dart'` (adjust the relative path to your test directory) for EditorTestHarness, FakeProjectRepository, FakeMediaPoolService, SurfaceMatrix, testSurfaces, expectNoOverflow, expectInside, fitsFully and expectOwnerUiRules.\n- EditorTestHarness: `EditorTestHarness({engine, repository, mediaPool, transcription, prefs, overrides})` with `.pumpEditor(tester, surface:)`, `.pumpApp(tester, widget, surface:)`, `.container()` and `.containerOf(tester)`.\n- SurfaceMatrix: `pr` runs by default; `full` runs with `--dart-define=DANAVIEW_SURFACE_MATRIX=full`. Shortcuts: `SurfaceMatrix.narrowest` (280x500 @1.35) and `SurfaceMatrix.phone`.\n- test/architecture/skeleton_test.dart enforces that every placeholder keeps its `// OWNER: <ticket>` header and that every bindings file is wired. Owners that replace a placeholder should keep an OWNER header naming their ticket, or drop the header and the D-33 marker together.\n- Formatting: `dart format -l 140`.

**Verification:** - `cd packages/danaview_editor && flutter analyze --fatal-infos --fatal-warnings`: No issues found!\n- `cd packages/danaview_editor && flutter test`: 00:02 +117: All tests passed!\n- `scripts/ci/editor/flutter_packages.sh danaview_editor_fonts danaview_editor`: passed danaview_editor_fonts and danaview_editor; failed none. danaview_editor_fonts is analyzed only because it has no tests yet.\n- Root `flutter test test/architecture` (INT-01's dependency_rules_test): 00:00 +39: All tests passed! Rule 7 now runs against danaview_editor instead of being skipped.\n- Another engineer was mid-edit in core ops (`clipboard.dart` referenced an undefined `DeleteItems`), which briefly broke compilation. I waited until core analyzed clean and re-ran; I did not touch their files.\n- Formatting: `dart format -l 140` over lib, test and tool.

### UX-02, UX-03

- **UX-02** (done): Found an earlier attempt already in the tree and continued from it. ScreenOrientationPolicy (owner stack with enter/release/toggle, OrientationMode appDefault/followDevice/free) is in place, PlayerOrientation is a thin wrapper with the same public API, and lib/orientation.dart exports the policy. 18 orientation tests cover: editor over player restores the player mode; non-top release keeps the top; app default returns when the stack empties; desktop no-op; tablets; and iPhone device-follow. test/player_screen_test.dart passes unchanged. The only edit I made was removing an unnecessary import from the test file, so analyze is clean.
- **UX-03** (done): Done in the earlier attempt and verified now. DanaviewHomeScreen.onOpenEditor is an optional callback (null hides the button) threaded to _HomeHeader. The button is a tonal DanaviewIconButton (Icons.movie_edit, 44px, icon 22, tooltip 'Video editor', semantic label 'Open video editor') placed left of the settings gear with a DanaviewSpacing.sm gap. lib/chrome.dart re-exports the shared library chrome widgets and imports no editor package. 14 tests cover button order [logo, title, edit, gear], hidden when null, tap, no overflow at 280/320/390 px x 0.85/1.0/1.35, and the title slot staying at 96 px at 280 px and 1.35x. The DANAVIEW_EDITOR flag gating is not wired here: the app passes the callback in INT-02.

**Deferred:**
- The D-43 'owner defaults 2026-10-08, revisable' note belongs to INT-01 and was not edited here.
- The DANAVIEW_EDITOR flag gating of the Home edit button is applied by the app in INT-02, which passes onOpenEditor only when the editor is available.

**Hand-off:** Orientation API: import package:danaview_features/orientation.dart for ScreenOrientationPolicy and OrientationMode. enter(owner, mode) puts the owner on top of the stack, release(owner) removes it from anywhere (re-applies only if it was the top), and toggle(owner, Orientation) is the rotate button. Modes are appDefault, followDevice (the player) and free (the editor, which behaves like followDevice on iPhone). PlayerOrientation.enter(owner), toggle(current) and release(owner) keep their API and delegate to the policy; toggle acts on the current top owner. The editor should call ScreenOrientationPolicy.enter(this, OrientationMode.free) on open and release(this) on close, and the player's pinned or followed mode is restored when the editor pops. For tests, ScreenOrientationPolicy.resetForTesting() is available. package:danaview_features/chrome.dart exports DanaviewLibraryFrame, DanaviewLibraryTopBar, DanaviewLibraryGroup, DanaviewLibrarySectionHeader, DanaviewInlineEmpty, DanaviewRefreshOnReturn and danaviewLibraryInsets. DanaviewHomeScreen has a new optional onOpenEditor: VoidCallback?, where null hides the button. Two root tests currently fail outside these tickets: test/architecture/dependency_rules_test.dart (INT-01 in progress) and the 'app version matches pubspec.yaml' check in test/settings_account_test.dart (expected 2, actual 1; not touched by this change).

**Verification:** cd packages/danaview_features && flutter analyze: No issues found. Root `flutter analyze lib test/editor_entry`: No issues found. `flutter test test/editor_entry`: +32 All tests passed. `flutter test test/editor_entry test/player_screen_test.dart`: +75 All tests passed. Full root `flutter test test`: failures only in test/architecture/dependency_rules_test.dart (another engineer's in-progress INT-01 work) and test/settings_account_test.dart 'app version matches pubspec.yaml' (expected 2, actual 1, in the existing settings test, not touched by this change). No native build is needed for these tickets.

### CORE-07, CORE-08, CORE-36

- **CORE-07** (done): An earlier attempt had already written geometry.dart, text_layout_spec.dart and text_animation_eval.dart plus the tests in test/geometry/. I checked them against the ticket and ARCH §6.6 and §11.6 'Place', and nothing further was needed. All acceptance criteria are covered by passing tests: (1) the placement matrix matches T·R·S·T for rotations 0/90/180/270/-90/33 with every fx/fy combination; flips, 90° rotations and crop+fit for fit/fill/stretch are tested. (2) boxAt of keyframed items is exact at keys, linear between keys and held after the last key. (3) Text animation values are exact at textAnimationBreakpoints, and linear interpolation between breakpoints reproduces every time. (4) The typewriter counts grapheme clusters, tested with emoji ZWJ, flags, combining marks and CJK.
- **CORE-08** (done): An earlier attempt had already written validate/, repair, violation codes, test/support/random_project.dart and the tests in test/validate/. This round I fixed a quadratic cost in the per-track transition check. The validator used to call TransitionBounds.maxFrames once per transition, and each call scanned every transition on the track. It now resolves the neighbouring transitions in one pass and calls the new TransitionBounds.maxFramesBetween. The warm one-track validation (380 items) dropped from about 0.51 ms to about 0.17–0.41 ms, depending on machine load. Added test/validate/transition_bounds_test.dart: maxFramesBetween equals maxFrames for every transition and kind on 300 random projects, plus a hand-made case. Acceptance criteria: every ViolationCode has a failing fixture and a repair test whose output validates clean; incremental only: equals full validation on 500 random projects; 500 randomly corrupted projects repair to clean. Benchmarks pass with the 3x CI factor: full validation of 2,000 items ran in 0.77–1.56 ms on the loaded host (budget 5 ms). One-track validation with the index already built ran in 0.17–0.41 ms (budget 0.5 ms). The variant that also rebuilds the whole-project id index ran in 0.43–0.66 ms. That is over the raw 0.5 ms budget but within the 1.5 ms allowed with the CI factor, measured at load average 50–64.
- **CORE-36** (done): An earlier attempt had already written visual_packing.dart, the tests in test/eval/packing/ and test/fixtures/vectors/packing.json; I verified them. Acceptance criteria are met: rule properties hold on 1,000 seeded random layer sets (no time overlap within a slot, z order kept against every overlapping slot, deterministic, peak equals a brute-force count). Six short PiP lanes pack into at most 2 slots. An interleaving case refuses to share a slot. Model-derived inputs equal the compiled media layers' ranges on the contract plan fixtures, and those plans carry the packed seq. A test checks that packing.json is up to date with the generator. The incremental one-lane update at 2,000 items runs in 0.29–0.53 ms (budget 0.5 ms × 3 CI factor). The 0.53 ms figure came from a run alongside the other tests on the loaded host.

**Deferred:**
- The CORE-08 one-track budget (0.5 ms) is met only with the 3x CI factor when the case also rebuilds the whole-project id index (0.43–0.66 ms on this heavily loaded host). The index belongs to CORE-03/04, and making it incremental would bring this case well under 0.5 ms. Validation with the index already built is 0.17–0.41 ms.

**Hand-off:** Public API, all exported from package:danaview_editor_core/eval.dart.

**Geometry (CORE-07)**
- Value types: Size2, Offset2, Rect2, Affine2 (`A * B` applies B first; `rotationDeg` is clockwise on a y-down canvas and exact at multiples of 90°).
- `placementMatrix(center:, base:, scale:, rotationDeg:, flipH:, flipV:)` and `planPlacementMatrix(PlanTransform, PlanSize, canvas)`.
- `baseSize(fit:, crop:, source:, canvas:)` throws ArgumentError when the source, crop or canvas has no positive area. `sourceDisplaySize(probe)`.
- `positionToCanvas` / `canvasToPosition`: positions are canvas fractions with 0 at the centre.
- `pointsToPx` / `pxToPoints` / `pxPerPointOf`, and `CanvasSpec.sizePx` / `pxPerPoint`.
- ItemBox: corners, bounds, toLocal, toLocalNormalized, fromLocalNormalized, contains(slop).
- `itemBoxAt(item, t, settings:, pool:, subtitle:, text:)` and `boxAt(project, id, t, {text})`. Both take absolute t.
- `hitTest` / `hitTestAll(project, p, t)`: topmost first, visible visual lanes only.
- `TextMetricsProvider.measure(TextLayoutSpec) -> Size2`. API-04 implements it with ui.Paragraph.
- `cueCenter(measured, SubtitlePosition, canvas)` with `subtitleSafeMargin = 0.06`.

**Text layout spec**
- `textLayoutSpecOf(TextItem, CanvasSpec)` and `cueLayoutSpecOf(SubtitleCue, SubtitleTrackData, CanvasSpec)`. The cue version takes the track's SubtitleTrackData, not the Track.
- `TextLayoutSpec.toJson()` is the canonical sprite cache key.
- `parseCueMarkup` handles `<b>`/`<i>`. Also `textGraphemeCount`, `graphemePrefix`, `resolveTextDirection`.

**Text animation**
- `evaluateTextAnimation(item, tAbsolute, canvas) -> TextAnimState{opacity, offset (canvas px), scale, reveal (double n·x), revealCount (floor)}`.
- The compiler's breakpoints function is `textAnimationBreakpoints(item)`: absolute µs, values linear between them, not necessarily on the frame grid.
- `textAnimationSpans(item)` scales in/out down proportionally when they exceed the duration. A typewriter out is ignored.

**Validator (CORE-08)**
- `validate(project, {only})` and `validateTimeline(timeline, pool, {only})` return `List<Violation>` (code, invariant, track, subject).
- Incremental contract: `only:` returns exactly the full result's violations whose track is null or in `only`.
- `repair(project)` returns `(EditProject, List<ProjectOpenWarning>)` with `RepairCodes`.
- `outOfRangeProperties(item)`; `lengthGridToleranceUs(rate)` is a quarter frame, used for keys, fades and text animation lengths.
- TransitionBounds: `maxFrames(track:, left:, right:, kind:, rate:, pool:)`, the new `maxFramesBetween(left:, right:, kind:, rate:, pool:, framesBeforeInLeft:, framesAfterInRight:)` for callers that resolve the neighbouring transitions themselves, `handleFramesAfter`/`handleFramesBefore`, `speedValid`, and `unbounded` (images and stills).
- CORE-16's TransitionLimits must agree with or delegate to TransitionBounds.
- `test/support/random_project.dart`: `randomProject(seed, [RandomProjectSpec(items:, …)])`, valid and deterministic, shared with CORE-34 and the benchmarks.

**Packing (CORE-36)**
- `packVisualLayers(List<PackInput(id, z, t0, t1, {decoderBacked})>) -> PackResult` with seqOf, trySeqOf, seqById, slotCount (= visualSequences), peakConcurrentDecoders, decoderSlotCount, and `withinCaps(maxConcurrentVideoLayers:, maxVisualSequences:)`. The algorithm is greedy in draw order: seq = 1 + the highest slot holding a time-overlapping layer.
- `packingInputsOf(project, {laneFilter, holdFrame})` and `laneInputsOf(track, z, settings, pool)`.
- `laneZ(kind, laneIndexInBand)` and `isDecoderBackedVisual(asset, {holdFrame})`. Layer ids come from `PlanIds.visual` / `PlanIds.backdrop`; backdrops sit at z − 5.
- `PackingInputCache({holdFrame}).inputsOf(project)` / `.pack(project)` re-derives only changed lanes (by track identity). CORE-09 LayerLimits should keep one cache per session.
- Vectors live in test/fixtures/vectors/packing.json for the IOS-08 and AND-08 tests.

**Verification:** Commands run in packages/danaview_editor_core:
- `dart analyze` (whole package): "No issues found!"
- `dart test test/geometry test/validate test/eval`: "00:06 +245: All tests passed!"
- `dart test -j 1 test/validate/validate_benchmark_test.dart test/eval/packing/packing_benchmark_test.dart`: "All tests passed!"
  - Medians at load average 50–64: full validation 1.56 ms, one track 0.658 ms with a fresh index and 0.408 ms with the index built, packing one-lane update 0.466 ms.
- Full-package `dart test` (run before this round's changes): 1260 passed, 1 failed. The failure was `test/formats/subtitles/subtitle_codec_test.dart` "performance 10k cues parse in <= 100 ms". That test belongs to another ticket and is sensitive to machine load; it passes when run alone.

### CORE-09, CORE-10, CORE-11

- **CORE-09** (done): An earlier attempt had already built the framework: edit_command.dart (sealed EditCommand, part files, _CommandRunner shared by apply and dryRun, _Draft, normalization, no-op detection, post-step validate(only:), exceptions -> InternalInconsistency), rejections.dart (exactly the 19 rejections of ARCH §7.1), outcome.dart, edit_context.dart (EditContext/EditPolicy), placement.dart (D-11 nearest free lane, clamp shift), dry_run.dart, limits.dart (LayerLimits on PackingInputCache, incremental, never locks users out) and commands/composite.dart. Its framework tests were missing, so this round added them. test/ops/framework/framework_test.dart covers: purity over 40 seeds x 12 random commands (equal outcomes, input unchanged); rejections never throw over 60 seeds x 25 random commands (dry run and apply agree, no InternalInconsistency, every accepted result fully valid); no-op detection; a violation introduced by a command -> InternalInconsistency with the project unchanged; violations that already existed do not block edits; exceptions -> InternalInconsistency; stamp; live pool; dry-run placements and created lanes; composite atomicity (late, early and nested failures, locked lane); limits run once on the final composite result. Limits on fixtures: six sparse PiP lanes pack into 2 sequences and pass maxVisualSequences=2, while a seventh overlapping lane (raw edit and a real InsertMedia) is refused with LimitExceeded(visualSequences,2); the concurrent decoder cap (images do not count); a project already over a cap stays editable; maxItems; 24 h; text-only edits skip packing. test/ops/framework/dry_run_benchmark_test.dart: dryRun with limits and validation at 981 items has a median of 0.39-0.76 ms across 5 gesture commands, under the 1 ms budget without the CI factor (asserted <= 1 ms x 3). Added a test-only `@visibleForTesting RawEditCommand(label, edit)` in commands/composite.dart to exercise the validation and exception paths.
- **CORE-10** (done): Found complete from the earlier attempt and verified: clip_commands.dart (InsertMedia/MoveItems/TrimItem/SplitItems/DeleteItems/DeleteGap) and ripple.dart. test/ops/clip has 5 golden files with about 100 before/after cases covering ripple, link, lock, clamp, new-lane and policy-reject, plus property tests: split concatenation equals the original time map at every frame, trim respects the source range and the 1-frame minimum, ripple never moves unrelated lanes (60 seeds). All pass.
- **CORE-11** (done): Found complete from the earlier attempt and verified: clipboard_commands.dart (DuplicateItems, PasteItems, ReplaceMedia, ExtractAudio, LinkItems, UnlinkItems), clipboard.dart (copyItems -> ClipboardPayload; cutItems = copy + DeleteItems in one CompositeCommand 'Cut', D-16) and selection.dart (SelectionRules.expand plus hints). test/ops/clipboard has goldens for duplicate, paste, replace, extract and link/cut, plus rules tests: cross-project paste mints fresh ids and imports pool entries exactly once; replace with shorter media clamps and emits trimmedToFit; extracted audio stays in sync at every frame; SelectionRules.expand table. All pass.

**Hand-off:** All of these are exported from package:danaview_editor_core/ops.dart.
- Entry points: applyCommand(project, cmd, ctx) -> EditOutcome{project, affected, changedTracks, createdTracks, selection, notices, rejection, noop}, and dryRun(...) -> EditPreview{placements, createsTracks, clampedTo, rejection}. Both run the same code path, limits and post-step validation included.
- Adding commands: group tickets add `final class X extends EditCommand` to their part file and implement `void _apply(_Draft d)`. The _Draft helpers are reject(), locate/find/item, editableTrack (TrackLocked), withPartners/partnersOf, removeItems/addItems/replaceItems/setItems/putTrack, createTrack(kind, role:), placeGroup (D-11 placement plus the WouldOverlap/NoRoom policy), shiftFrames/placeAt/fitSource, transferTransitions, noteLink, notices/selection/clampedTo, and the pool/settings/markers fields. finish() runs automatically: transitions are dropped or re-clamped via TransitionBounds.maxFramesBetween, fades are clamped to half the clip, and singleton links are dissolved.
- CompositeCommand(label, [cmds]) is atomic, and limits run once on the final result. RawEditCommand(label, EditProject Function(EditProject)) is @visibleForTesting and for tests only, e.g. the CORE-34 fuzzer or CORE-19 tests that need an arbitrary edit.
- EditContext(ids, pool (the live pool overrides the snapshot pool), now, policy, limits (a LayerLimits shared through copyWith), stamp (writes Timeline.revision and Track.changedAt of changed lanes)). Keep one EditContext/LayerLimits per session (CORE-19).
- EditPolicy(overlap newLane|reject, defaultImageUs/TextUs 3 s, defaultCueUs 2 s, maxConcurrentVideoLayers 4, maxVisualSequences 6, maxItems 5000).
- LayerLimits: countsOf(project) -> LimitCounts.exceeded(policy) drives the D-14 banner and export preflight. check() refuses a command only when it makes an over-cap count grow. packCount and visualLayersUnchanged support tests.
- In tests, seed SeededIdGenerator far away from randomProject's seed, otherwise minted ids collide with the project's ids.
- Shared test fixtures: test/ops/framework/ops_support.dart (standard(), lane/vclip/aclip/text/cue builders, runCase, GoldenFile with UPDATE_GOLDENS=1). The randomCommand(project, Random) generator in framework_test.dart can be copied for CORE-34.

**Verification:** cd packages/danaview_editor_core && dart analyze --fatal-infos -> "No issues found!" (whole package). dart test test/ops test/purity_test.dart -> "+773: All tests passed!" (benchmark output: "dryRun at 981 items: move overlay clip 1 frame 0.757 ms; move overlay clip 1 frame (clamp) 0.692 ms; trim overlay end -1 frame 0.387 ms; ripple trim main end -1 frame 0.723 ms; split main mid clip 0.512 ms;"). No native build needed (pure Dart tickets).

### CORE-12, CORE-13, CORE-14

- **CORE-12** (done): SetSpeed, SetReversed and FreezeFrame are implemented in speed_commands.dart. All acceptance criteria are met by 105 golden cases, rule tests and a 60-seed fuzz on random projects. The speed fuzz found no invariant violations, and the full package suite (2,974 tests) passes.
- **CORE-13** (done): SetProperty<T>, SetVisual, SetAudio, SetLook, SetChroma, SetMask, SetCrop and ResetTransform are in property_commands.dart. AddKeyframe, RemoveKeyframe, MoveKeyframe, SetKeyframeValue and ClearKeyframes are in keyframe_commands.dart. Tests cover every command and every rejection, plus a 300-edit random run that keeps all invariants. One bug was found and fixed: writing look.intensity on a clip without a look threw ArgumentError, and now returns UnsupportedForKind('noLook').
- **CORE-14** (done): AddText, SetText, SetTextStyle (field patch and .replace) and SetTextAnimation are in text_commands.dart. The command-level coalescing hook is the CoalescingCommand interface, which SetText implements with coalesceKey 'text:<item id>'. CORE-19 owns the session-level coalescing test; only the hook is tested here.

**Deferred:**
- No acceptance criterion is deferred.
- SetSpeed cannot enforce the engine's audio speed cap (D-15, capabilities.maxAudioSpeed); that mute-above-4x behaviour belongs to the engines and the speed panel.
- Session-level coalescing of SetText belongs to CORE-19's tests. CORE-12 and CORE-14 only provide the command-level hook.

**Hand-off:** All of these are exported from package:danaview_editor_core/ops.dart. Details below were designed by me where the spec was silent.

**Speed commands**
- `SetSpeed(item, spec, {bool? maintainPitch, bool? ripple})`. A null `ripple` follows `ViewState.rippleEnabled`.
- With ripple on, following items shift by the duration change and link partners follow.
- With ripple off, growth clamps at the next item: `EditPreview.clampedTo` is set and an `EditNoticeCodes.trimmedToFit` notice is added.
- A video clip and its extracted audio share one time map; both get the same spec or the same reverse flag. Link partners with a different range are left alone.
- If re-timing to the grid would overrun the media, `sourceIn` is pulled back or the clip loses a frame.
- Image and still clips are rejected with `UnsupportedForKind('image'|'still')`.
- `SpeedRampPresets` (ids `montage`, `hero`, `bullet`, `jumpCut`, `flashIn`, `flashOut`; `SpeedRampPresets.byId(id)` returns a `SpeedRamp` with `presetId` set) was defined here because no ramp presets existed. UX-25 can tune the curves.

**Reverse**
- `SetReversed(item, on)` flips the flag. Turning it on adds a pending `ReversedSpec` asset to the pool unless an existing non-failed one covers the clip's source range.
- New renditions cover the source range plus `reverseHandleUs` (2 s) of handles on each side, limited to the media.
- Their status is `PendingStatus(unstartedJobId)`, where `unstartedJobId` is the empty string, and the locator is `AppRelativeLocator(AppRoot.support, 'danaview/editor/derived/<specHash>.mp4')`.
- A `ReverseNoticeCodes.renditionPending` notice tells the session to start the engine job and replace the status with the real job id.
- A failed rendition with exactly the wanted range is reset to pending instead of duplicated.
- Reversing a clip can drop a cross dissolve, because overlap transitions need handles and a reversed clip's handles are mirrored. This is the framework's normal transition re-clamp, and undo restores it.

**Freeze frame**
- `FreezeFrame(item, at, duration, stillMedia)`: the session must add the pending still asset (derived `StillSpec` of the same media, kind `still`) before applying; a missing or failed still returns `MediaUnavailable`.
- `FreezeFrame.sourceTimeAt(clip, at, rate)` is the source time to freeze into `StillSpec.sourceTime`.
- `at` equal to the clip start inserts the still before the clip without splitting; `at` at or after the clip end returns `NothingAtTime`.
- The still copies the clip's visuals with keyframed values baked at the cut and has no audio.

**Property commands**
- `SetProperty<T>(items, key, value, {at})` takes an absolute timeline time; the key's item-local time is `quantizeNearest(at) - start`.
- A keyed property with no `at` returns `InvalidValue('at')`. An `at` outside a keyed item returns `NothingAtTime`.
- Whole-struct setters check ranges with `outOfRangeProperties`, so a rejection names the property id (for example `visual.crop`, `look.intensity`).
- New `UnsupportedForKind` values: 'noAudio' (volume or fades on silent media or images), 'noLook', 'audioClip', 'media', 'text', 'subtitle', 'notKeyframable', 'notLut'.
- `ResetTransform` resets identity (including flips) and clears the position, scale, rotation and opacity keys; it leaves fit, crop and effects alone.

**Keyframe commands**
- Refs use `KeyframeRef(item, propertyId, itemLocalTime)`; a channel id such as `transform.position.x` is also accepted.
- `AddKeyframe` with no value uses the current evaluated value. Removing the last key of a property leaves it static at that key's value.
- `ClearKeyframes(items, {property, at})`: with `at`, cleared properties become static at their value there.
- Missing keys return `NothingAtTime`; duplicates return `KeyframeExists`. A key time outside the item returns `InvalidValue('t')`.

**Text commands**
- `AddText(at, {text = AddText.placeholder ('Text'), duration, style, track})` picks the topmost free unlocked text lane, or creates a text lane at the top of the text group. With `OverlapPolicy.reject` and all lanes busy it returns `NoRoom`.
- `SetTextStyle(items, {fields, background/stroke/shadow with removeX flags})` patches fields; `SetTextStyle.replace(items, style)` replaces the whole style.
- `SetTextAnimation(items, TextAnimation)` fits lengths to the grid and per item so `in + out <= duration`; the in animation keeps its length first, and typewriter as an out kind returns `InvalidValue('outKind')`.
- `CoalescingCommand { String? coalesceKey }` is the hook for CORE-19: apply with `coalesceKey: command.coalesceKey` when the command implements it. Only `SetText` does, with key `text:<item id>`.

**CORE-34**
- Fuzz-ready generators: `randomSpeedCommand` and `withStills` in test/ops/speed/speed_fuzz_test.dart. The SetProperty random run is at the end of property_commands_test.dart.
- Seeded `SeededIdGenerator` ids must stay far from `randomProject`'s seed (I used 900000+).

**Verification:** In /Users/besaoct/Desktop/danaview/packages/danaview_editor_core, `dart analyze lib test/ops/speed test/ops/property test/ops/text` reports "No issues found!". `dart test test/ops/speed test/ops/property test/ops/text` finished "+321: All tests passed!". A full `dart test` of the package finished "+2974: All tests passed!". No native build was required for these tickets.

### CORE-15, CORE-16, CORE-17, CORE-18

- **CORE-15** (done): Subtitle and generated-caption commands, all acceptance criteria met. Commands: AddCue, SetCueText, SetCueRange, SplitCue, MergeCues, DeleteCues, ShiftCues, ImportSubtitles, SetSubtitleStyle, SetSubtitlePosition, SetBurnIn, SetSubtitleLanguage, AddGeneratedCaptionTrack, ReplaceGeneratedCaptions. Tests cover overlap rejection, ShiftCues of an imported lane by +/-2.5 s and of a range, split/merge text handling with markup and ZWJ emoji, spill on import, editedAfterGeneration on every text or timing edit, replace-in-range boundaries, and locked-lane rejection as data. Goldens: subtitles.golden, captions.golden.
- **CORE-16** (done): TransitionLimits.of/ofAll/at/cutsOf/isCut plus SetTransition and ApplyTransitionToAll, all acceptance criteria met. Tests cover handles, speed at the edge (constant and ramp), reversed clips, images, neighbouring transitions, TransitionTooLong(maxFrames), NotAdjacent, per-cut clamping, one-command apply-to-all, and adjacency-breaking CORE-10 commands (move, trim, delete, ripple delete, ripple trim). A random-project test shows max passes and max+1 fails the validator's I5. Goldens: transitions.golden.
- **CORE-17** (done): AddTrack, DeleteTrack, MoveTrack, RenameTrack, SetTrackFlags, SetAudioRole, AddMarker, UpdateMarker, DeleteMarker, SetCanvas, SetFrameRate, SetBackground and requantize(project, newRate), all acceptance criteria met. Band ordering is enforced by an exhaustive lane-by-index move test. The main lane is protected. requantize properties hold on random projects for all 36 rate pairs (6 seeds each, about 9,700 items): order, adjacency, bounded movement, minimum duration, and the result passes validate. Marker commands round-trip. Goldens: tracks.golden, markers_project.golden.
- **CORE-18** (done): SnapIndex.build/nearest/nearestForRange (plus SnapHit, RangeSnap, SnapKind, SnapSide), all acceptance criteria met. Checked against a brute-force oracle on 7 random projects with exclusions, keyframes, cues and markers switched on and off. Benchmark at 1,928 items: build 130-240 us median (budget 1 ms) and query about 0.1 us (budget 20 us). Build merges the already-sorted per-lane edge runs instead of sorting everything.

**Deferred:**
- No acceptance criterion is deferred.
- Not done, outside these tickets: the session must re-quantize ViewState.playhead after SetFrameRate. A command cannot change the view, but requantize(EditProject, rate) already returns the project with the playhead on the new grid. CORE-19 or the UX layer should apply it.
- Not done: no sync-locking across lanes in requantize. When an item shorter than a new frame is stretched, its link partner on another lane can end up one frame apart (domain.md section 6.3 defers sync-locking).
- Not done: no cap on the number of lanes in AddTrack (the spec names none).

**Hand-off:** All names below are exported from package:danaview_editor_core/ops.dart, except TransitionLimits, which is in eval.dart.

CORE-18 snapping:
- SnapIndex.build(project, {exclude, playhead, markers=true, keyframesOf: ItemId?, cues=true, transitions=true}) builds the index; SnapIndex.empty is an empty one.
- idx.nearest(t, toleranceUs) returns SnapHit?{time, kind, distance, item, track, marker, transition, side}.
- idx.nearestForRange(range, toleranceUs) returns RangeSnap?{hit, edge, delta}. Add delta to the range to land the chosen edge on the target.
- SnapKind is playhead, marker, itemEdge, transition or keyframe. SnapSide is start or end.
- Tolerance is inclusive. At equal distance the better kind wins (playhead, marker, item edge, transition, keyframe), then the earlier time.
- Pass SelectionRules.expand(...) as exclude.
- UI note for UX-14: `transition` hits are the boundaries of a transition window.

CORE-16 transitions:
- TransitionSpec(kind, durationFrames, {direction}) is the UX type.
- SetTransition(ref, spec?, {clamp=false}). spec null removes. TransitionTooLong(maxFrames) is the rejection. clamp:true shortens to the limit and gives the notice transitionsShortened; it still refuses when the limit is 0.
- ApplyTransitionToAll(spec?, {track}). The argument order is (spec, track), not (trackId, spec) as in the BUILD_PLAN text. track null means the main lane. spec null removes every transition on the lane. Each cut is clamped to its own limit. A cut with no room is skipped and keeps what it has, with notice itemsSkipped listing the right-hand clips. A lane without cuts is a no-op.
- Directions: slide and wipe take left/right/up/down (default left). zoom takes zoomIn/zoomOut (default zoomIn). A direction on a kind without directions is dropped. A wrong-family direction is InvalidValue('direction').
- TransitionLimits.of(project, ref, {kind}) returns the max frames. When kind is omitted it uses the kind already on the cut, else crossDissolve, the most restrictive. Also TransitionLimits.ofAll (one value per kind), at, cutsOf(track) and isCut. All of it delegates to TransitionBounds, so it agrees with validator rule I5.

CORE-15 subtitles and captions:
- SubtitleNoticeCodes: shiftClampedAtZero, cuesSpilled, cuesSkipped.
- AddCue(at, text, {track?, duration?}). With track null it picks the topmost unlocked subtitle lane that has room, else creates a lane (or NoRoom under OverlapPolicy.reject).
- SetCueText(cue, text) and SetCueText.coalesceKey(id) => 'cue:<id>'. SetCueText keeps the user's text as typed (only line endings change). Add, import and AI drafts trim each line and drop blank lines.
- SetCueRange(cue, start, end, {clamp}) and SplitCue(cue, at, {textSplit}). The left half keeps the id.
- MergeCues(Set<ItemId>). Gaps between cues are absorbed. The space-join limit is 42 visible graphemes.
- DeleteCues(Set<ItemId>) and ShiftCues(track, deltaUs, {range}). range selects the cues whose start lies in [range.start, range.end).
- ImportSubtitles(List<SubtitleCueDraft>, {mode: SubtitleImportMode.newTrack|replace, track, name, language}). It takes SubtitleCueDraft, not the codec's SubtitleCueData, because part files cannot add imports. Map the codec cues with SubtitleCueDraft(TimeRange(startUs, endUs), text); the command rounds to frames. Spill lanes are named '<name> 2' and so on.
- Replace-mode import clears the lane's provenance.
- SetSubtitleStyle(track, style): fontSizePt in [8, 200], maxLines 1..3, maxWidth in (0, 1].
- SetSubtitlePosition(track, pos), SetBurnIn(track, bool), SetSubtitleLanguage(track, bcp47|null).
- AddGeneratedCaptionTrack({trackName, language, provenance, cues}) puts the lane on top and gives selection.lane. ReplaceGeneratedCaptions({track, range?, provenance, cues}) replaces only cues overlapping the range and fits the new cues around the kept ones. Both set CueOrigin.generated and mint fresh ids. Overlapping or blank drafts are trimmed or dropped with notice cuesSkipped.
- Edge case: AddGeneratedCaptionTrack rejects InvalidValue('cues') when no draft survives, so it never creates an empty lane.

CORE-17 tracks, markers, project:
- AddTrack(kind, {name, audioRole (default music), language}).
- DeleteTrack(track). Deleting the main lane is CannotDeleteMainTrack. Link partners left alone lose their link.
- MoveTrack(track, toIndex). toIndex is an index in Timeline.tracks and must stay inside the lane's kind group (IncompatibleTrack otherwise). The main lane cannot move and nothing may go below it (CannotDeleteMainTrack).
- RenameTrack(track, name) with a 60-grapheme maximum.
- SetTrackFlags(track, {locked, hidden, muted, solo}), null meaning unchanged. It works on locked lanes. hidden applies to visual lanes. muted and solo apply to video, overlay and audio lanes, and only their true value is refused elsewhere (UnsupportedForKind).
- Every other track command on a locked lane is TrackLocked.
- SetAudioRole(track, role).
- AddMarker(time, {name, colorIndex, note}) and UpdateMarker(id, {time, name, colorIndex, note}). note omitted keeps it; note: null clears it. DeleteMarker(id).
- markerPaletteSize = 6, maxMarkerNameLength = 60, maxMarkerNoteLength = 1000. Marker times are quantized to the nearest frame and kept sorted by time.
- SetCanvas({aspect, baseShortSide}): aspect must be in 1:4..4:1, short side one of 720/1080/2160. SetBackground(spec): solid alpha is forced opaque, blur radius in [0, 1].
- SetFrameRate(rate) runs requantize. The notice transitionsRemoved counts transitions dropped.
- requantize(EditProject, FrameRate) returns an EditProject. It is pure and also quantizes view.playhead. The same rate returns the identical project.
- requantize map: T(t) = nearest new-grid time. Order and adjacency are preserved. Fades, text animations and keys are re-measured. Transitions keep their length in seconds and are re-clamped. An item shorter than a new frame is stretched and its followers are pushed.
- requantize media rule: a clip that would play past its media gets sourceIn pulled back, or ends one frame earlier. That is the only way touching clips can separate, and that cut's transition is then dropped.

Test support (test/ops/subtitles/subtitle_fixtures.dart, test/ops/tracks/track_fixtures.dart):
- runSubCase and runProjectCase wrap runCase and append cue and lane details. Goldens are under test/ops/{subtitles,tracks,transitions}/goldens.
- Anything needing a valid project must include a main video lane: validate() requires it even for an empty project.

Barrels: no changes were needed. ops.dart already exports snapping.dart and requantize.dart, and eval.dart exports transition_limits.dart. edit_command.dart, outcome.dart and ops_support.dart are untouched.

**Verification:** cd packages/danaview_editor_core. `dart analyze`: No issues found. `dart test test/ops/snapping test/ops/transitions test/ops/subtitles test/ops/tracks`: +530 All tests passed. `dart test test/ops test/purity_test.dart` earlier in the session: +1624 All tests passed. Full `dart test` showed 1 failure, in test/purity_test.dart (every file under lib/src is reachable from a barrel). It lists lib/src/session/media_refs.dart and history.dart, which are CORE-19's half-written files, not mine. All of my files are reachable and have OWNER headers. Goldens were generated with UPDATE_GOLDENS=1, reviewed, then re-run without it. No native builds are needed for these tickets.

### CORE-19

- **CORE-19** (done): Replaced the placeholder with the full EditSession described in ARCH §7.3 and domain.md §7.2, under lib/src/session/. The session.dart sub-barrel, which ops.dart already exports, now re-exports edit_session.dart, history.dart and media_refs.dart.

Acceptance criteria, each covered by tests:
- Undo/redo/jump identity: lanes, markers and settings are restored as identical objects and only the root revision is re-stamped. jump(n) is one combined step that takes one stamp; it is clamped, and 0 returns null.
- Coalescing within 1 s by key: the window counts from the last keyed apply. A different key, an unkeyed command, an undo/redo or a transaction commit breaks the run. A coalesced apply does not increment editCount.
- Transaction update-from-base: update is not cumulative, and a refused or no-op update shows the base. commit records exactly one entry, or none when nothing changed. cancel restores the base. A second begin, or any apply, undo, redo, jump or pool edit, cancels the open transaction. Sticky pool changes and view updates leave it open.
- Pool deltas are undoable while imports stay: AddAssets and UpdateAsset are sticky and bump only docRevision. RelinkAssets and RemoveAssets each record a PoolDelta that is applied to the current pool on undo/redo. RemoveAssets is refused for media used by the current timeline or by a derived asset that stays.
- Stamps strictly increase across undo + new edit: the counter starts at max(revision, max changedAt)+1, and every apply, transaction update, pool edit, undo, redo and jump takes a fresh stamp that is never reused.
- Eviction by count (200) and by approximate bytes (48 MB), oldest first; the newest entry is always kept.
- retainedMedia is correct.
- Exceptions inside a command become InternalInconsistency (apply, update, dryRun).
- editCount never decrements.

Tests: test/session/session_test.dart has 33 cases. test/session/session_property_test.dart runs 30 random seeds × 60 operations mixing commands, undo, redo, jump, transactions and RemoveAssets. At every step it checks snapshot identity against a model, all invariants including I4, editCount and history status, then walks the whole history back and forth.

**Deferred:**
- The domain.md DOM-19 large fuzzer (200×500 in CI) belongs to CORE-34. CORE-19 ships a 30-seed × 60-op session property test that CORE-34 can extend.
- No ARCHITECTURE.md edit was made. D-43 owner defaults were already recorded by another ticket. The extra `adjust` parameter of applyPoolEdit is documented in code and in this handoff only, because §7.3 is not a file CORE-19 owns.

**Hand-off:** All of this is exported from package:danaview_editor_core/ops.dart (via src/session/session.dart).

**Constructor:** `EditSession(EditProject initial, {IdGenerator? ids, HistoryPolicy policy = const HistoryPolicy() /*200 entries, 48 MB*/, EditPolicy editPolicy = const EditPolicy(), DateTime Function()? clock})`. The session holds one EditContext and one LayerLimits.

**Getters:** `project` (the transaction's working copy while one is open, otherwise the committed project), `committedProject`, `history` (HistoryStatus{position, length, undoLabel, redoLabel, canUndo, canRedo, redoable}), `entries` (List<HistoryEntry>, oldest first), `historyBytes`, `recentLabels(max)` (newest first, redoable entries included), `transaction`, `nextStamp`, `editPolicy` (settable, e.g. when capabilities change), `limits` (LayerLimits, for the D-14 banner: `limits.countsOf(project).exceeded(editPolicy)`).

**Methods:**
- `apply(cmd, {String? coalesceKey, Duration coalesceWindow = 1 s}) -> EditOutcome`. Its `project` is the committed project. Coalescing is explicit only; callers pass `SetText(...).coalesceKey` or `SetCueText.coalesceKey(id)`.
- `dryRun(cmd) -> EditPreview`.
- `begin(label) -> SessionTransaction` with `update(cmd) -> EditOutcome`, `preview` (EditPreview?), `lastOutcome`, `commit() -> EditOutcome`, `cancel()`, `isOpen`. Calling update or commit on a closed transaction returns a noop outcome and never throws.
- `undo()`, `redo()`, `jump(n) -> HistoryStep?`. HistoryStep has direction (HistoryDirection.undo/redo), labels, label, steps, project, affected, changedTracks and selection (the affected items that still exist, or null).
- `applyPoolChange(PoolChange)`: sticky, bumps docRevision only.
- `applyPoolEdit(PoolEdit, {EditCommand? adjust}) -> EditOutcome`: one history entry with a PoolDelta. `adjust` runs in the same entry. CORE-28 should use it for relink durationMismatch clamps, e.g. TrimItem commands. Rejections: MediaUnavailable(id) for an unknown id, InvalidValue('replacements') when a replacement changes its id, InvalidValue('mediaInUse') when removing used media or the source of a derived asset that stays, and InternalInconsistency(violations) when a relink breaks kind or source range on the lanes that use the asset.
- `updateView(f)`: bumps docRevision only.
- `retainedMedia() -> Set<MediaId>`: the union of the current timeline (and the working copy), every history snapshot, every PoolDelta id, all current pool ids, and the derived sources of these. CORE-28 GC should use it.

**Helpers:** `mediaReferencedBy(Timeline)` and `MediaRefCollector` (counts clip media and ImportedLut looks). `approxEntryBytes(before, after)` is @visibleForTesting: 64 B per entry and per changed lane, 8 B per slot of each changed list, 300 B per new item, transition or marker, and 300 B for changed settings.

**Semantics:**
- A coalesced apply does not increment editCount.
- History operations set meta.updatedAt to clock().
- Pool assets added by a command (paste) are sticky; assets a command removes or changes get a delta.
- During a transaction, each changing update takes a fresh stamp, and commit keeps the last update's stamp.
- Autosave (CORE-26) can check `session.transaction != null` to skip while a gesture is open.

**Test helpers:** test/session/session_support.dart provides FakeClock (pass `clock.call`), sessionOn(project, {clock, policy, editPolicy, seed=900001}) and sameSnapshot(a, b) for identity checks. CORE-34 can extend test/session/session_property_test.dart, which already uses randomCommand from test/ops/framework/framework_test.dart.

**Verification:** cd packages/danaview_editor_core && dart analyze -> "No issues found!" (whole package, lib and test).
dart test test/session -> "00:00 +63: All tests passed!" (33 unit tests + 30 property seeds).
Existing users of EditSession (store/project_repository.dart, store/media_pool_service.dart, and packages/danaview_editor test fakes, which import `show EditSession`) still compile because the type name and the export path are unchanged.

### CORE-20, CORE-21

- **CORE-20** (done): SubtitleCodec.parse/serialize/suggestedFileName plus srt.dart, vtt.dart and text_decoding.dart implemented per ARCH 10.1. Tests cover the fixture corpus (BOM, UTF-16 LE/BE with and without BOM, CP1252, Latin-1, CJK, RTL, CR-only, tolerant SRT, malformed SRT/VTT with line-numbered issues), exact serialization, a 60-round random parse(serialize(x))==x property in both formats, and a 10k-cue parse under 100 ms. All pass.
- **CORE-21** (done): CubeLut.parse/parseText, writeVlut/writeVlutFromCube/readVlut/VlutTable and float16Encode/Decode implemented per ARCH 10.2 and D-07. Tests cover Resolve, Adobe, 1D (converted to 33^3 with a notice), domain keywords, malformed files with line numbers, the oversize message, identity round-trip within 1/1024, a golden .vlut produced independently with numpy, all 65,536 float16 patterns, and a 65^3 parse under 400 ms. All pass.

**Hand-off:** All names are exported by lib/formats.dart, which already exported these files; no barrel or pubspec edits were needed.

CORE-20 API:
- SubtitleCodec.parse(Uint8List bytes, {SubtitleFormat? hint}) returns SubtitleParseResult {format, cues: List<SubtitleCueData>, issues: List<SubtitleIssue(line, kind)>, strippedTags, ignoredSettings, detectedEncoding: TextEncoding, hadBom}.
- SubtitleCodec.serialize(cues, format, {offset = 0, bom = false}) returns UTF-8 Uint8List.
- SubtitleCodec.suggestedFileName(project, bcp47, format) returns '<project>.<bcp47>.srt|vtt'.
- SubtitleCueData(startUs, endUs, text) uses microseconds and '\n' between lines. Text may contain balanced <i>/<b> markup.
- The codec does not round to frames or enforce a 1-frame minimum duration. UX-32 / CORE insert code must do that, and must map CueOrigin.imported.
- A WEBVTT header always means VTT. A VTT hint without the header gives a missingHeader issue and no cues.
- A zero-length cue (end == start) is accepted. end < start gives an endBeforeStart issue.
- Cues whose text is empty or markup-only are reported as emptyText and skipped, on parse and on serialize.
- Entities (&amp; &lt; &gt; &quot; &apos; &nbsp; numeric) are decoded on parse in both formats.
- Serialize escapes literal '<' as &lt; in both formats. VTT also escapes & and >. SRT escapes & only when it looks like an entity.
- Parse runs in the caller's Isolate.run. Measured well under 100 ms for 10k cues.

CORE-21 API:
- CubeLut.parse(Uint8List) / CubeLut.parseText(String) return CubeLut {size, Float32List rgb (N^3*3, red fastest), title, domainMin/domainMax, notice}. They throw LutFormatException(message, line).
- Messages look like 'Line 14: expected 3 numbers'. Oversize LUTs give 'LUTs up to 65×65×65 are supported.'.
- 1D LUTs are converted to size 33 with notice text mentioning 33×33×33.
- Table entries are never resampled for DOMAIN_MIN/MAX. The domain is only recorded, and the .vlut table is taken to span the whole input domain, mapped to [0,1].
- writeVlut(size, rgb) and writeVlutFromCube(CubeLut) produce .vlut v1 bytes, with values clamped to ±65504.
- readVlut(bytes) returns VlutTable(size, Uint16List halfs) with toFloats(). It throws LutFormatException on bad magic, version, size or length.
- float16Encode/float16Decode are exposed. Encode rounds to nearest-even, and NaN becomes 0x7E00.
- Constants: maxLutSize 65, lut1dConvertedSize 33, maxCubeBytes 16 MiB, lutTooLargeMessage.
- Fixtures are in test/fixtures/luts/ and test/fixtures/subtitles/. golden_3.vlut was generated independently with numpy float16, so it cross-checks the Dart encoder.
- dart format needs -l 120 in this package. The 80-column default breaks one-line `if` statements and trips the curly_braces lint.

**Verification:** In packages/danaview_editor_core, dart test test/formats test/purity_test.dart gave 60 passed. dart test test/formats alone gave 46 passed and was re-run 3 times without a flaky result. dart analyze lib/src/formats test/formats reports no issues. Full-package dart analyze reports 14 infos in my formats files with default 80-column dart format, which are gone after dart format -l 120 (re-run clean). The repo has no page_width setting.

### API-03

- **API-03** (done): Started from the D-33 placeholders; no earlier attempt existed. Every spec item and acceptance criterion is met, except that committing is left to the lead because git is not allowed in this run.

lib/src/math/ implements every ARCH §11.6 stage on straight-alpha BT.709 values: chroma key and spill; exposure; brightness/contrast; highlights/shadows; saturation; temperature/tint; trilinear LUT over .vlut tables; separable Gaussian blur with the canvas, source and render σ conversions; sharpen; vignette; rounded-box and ellipse mask SDF with feather, invert and opacity; placement through core planPlacementMatrix; canvas masks; premultiplied source-over; sprite reveal; and audio gain interpolation. It also adds a per-layer parameter snapshot that mirrors native ParamSnapshot, including the D-35 frame time.

lib/src/reference/ adds the CPU reference renderer, the reference audio mixer, content sources (explicit, recording and deterministic synthetic), and the vector and golden builders under fixtures/.

Fixtures: test_fixtures/vectors/ holds keyframes, transform, render_math, gain, audio_mix, typewriter and text_scale_8x JSON plus luts/synthetic_17.vlut. test_fixtures/images/ holds 33 plans (all 25 valid CORE-29 contract plans plus 8 API-03 plans) rendered at 103 frames, with sources/ and goldens.json. The 8× case is api03_text_scale_8x. Formats are documented in test_fixtures/README.md, vectors/README.md and images/README.md.

tool/regen_goldens.dart supports `--check`. It rewrites only files whose content changed, compares JSON with a 2e-9 tolerance and goldens within 1/255 per channel, so a clean tree gives no diff on other hosts.

test/reference/ has 293 tests:
- analytic checks of each stage;
- JSON-only replays of render_math, gain and audio_mix, read the way the Swift/Kotlin suites read them;
- the joint test: core FrameRate, evaluateAnimKeys, evaluate, boxAt, planPlacementMatrix and evaluateTextAnimation pass the shared vectors;
- renderer behaviour and determinism;
- the regen no-diff check and manifest consistency.

The goldens re-render bit-exactly against the PNGs written in an earlier run (0 differing samples over 103 frames).

**Deferred:**
- Commit of the generated vectors and goldens: not done, because git state changes are not allowed in this run. The lead commits them together with the rest of the working tree.
- API-01's test/contract/fake_engine_behavior_test.dart is stale now that API-03 has landed (not my file). In the test 'placeholders throw UnimplementedError…', the RenderMath.notImplemented, ReferenceRenderer and ReferenceAudioMixer lines must be removed by API-01 or the lead; the PlanTransport, TextLayoutEngine and VspriteCodec lines will go stale the same way when API-02 and API-04 land. To keep that file compiling meanwhile, RenderMath keeps a transitional `notImplemented` getter that always throws; delete it together with those test lines.
- The interpretations listed in the handoff are recorded in code and test_fixtures/vectors/README.md. Folding them into ARCHITECTURE §11.6 (lead/ENG-06) and schema/effects_reference.md (CORE-29) is left to those owners.
- The Swift/Kotlin readers of the vectors and goldens belong to IOS-08/09/11/18, AND-08/09/10 and QA-03/QA-11. API-03 only documents the format and proves it is loadable from the JSON alone in the Dart replay tests.

**Hand-off:** APIs\n- Main barrel `package:danaview_editor_engine_api/danaview_editor_engine_api.dart`:\n  - `RenderMath`: static stages chromaKey/chromaKeyAlpha, exposure, brightnessContrast, highlightsShadows, saturation, temperatureTint, grade, lut, blurSigmaCanvasPx/SourcePx/RenderPx, blurRadius, blurSkipped, gaussianKernel, gaussianBlur, sharpen, vignetteFactor, roundedBoxSdf, ellipseSdf, edgeAlpha, maskAlpha, canvasMaskAlpha, placement (calls core planPlacementMatrix), effectiveBase, premultiply/unpremultiply, sourceOver, spriteTexelDrawn, revealCount, toByte.\n  - `RenderRgba` and `RenderRaster` (premultiplied double raster with bilinear clamp-to-edge sampling).\n  - `RenderLut` (fromVlut / identity / generate, lookup).\n  - `LayerParamSnapshot.at(layer, canvas, t)`, `.frameTime(canvas, tau)`, `.evaluateCanvasMask`.\n  - `AudioMath`: gainAt, sampleTimeUs, sampleCount, sourceTimeAt, gainToDb/dbToGain/levelDb, equalPowerIn/Out, hardClip, downmixMatrix.\n- Test barrel `package:danaview_editor_engine_api/testing.dart`:\n  - `ReferenceRenderer({sources = SyntheticSources(), longSide})` with render, renderFrame, renderOutputFrame, and the statics applyEffects and placeOnto.\n  - `ReferenceAudioMixer({sources}).mix(plan, start, end)` returns interleaved stereo 48 kHz Float32; `ReferenceAudioMixer.windows(pcm)` returns AudioWindow values (20 ms RMS and peak).\n  - Sources: `ReferenceSources`, `MapReferenceSources`, `RecordingReferenceSources`, `SyntheticSources`, `ReferenceVideo` (constantRate/withPts, displayedFrameIndex = greatest PTS ≤ s + 500), `ReferenceSprite`, `ToneAudio`/`Tone`, `PcmAudio`.\n  - Missing content throws StateError; layers are never silently skipped.\n\nInterpretations fixed by API-03 where §11.6 is silent (lead/CORE-29 should fold them into ARCH §11.6 and effects_reference.md; natives must match them)\n- Chroma stage clamps the spill-rebuilt RGB to [0,1].\n- Blur filters all four premultiplied channels.\n- Sharpen applies to premultiplied RGB only, clamped to [0, alpha].\n- Vignette scales RGB; mask, opacity and canvas masks scale all premultiplied channels.\n- Item mask SDF is evaluated in base px (aspect-correct): p = R(−r)·((u−cx)·bw, (v−cy)·bh), radius = corner·min(w·bw, h·bh), f = feather·0.25·min(w·bw, h·bh).\n- Ellipse distance = (‖p/half‖ − 1)·min(half).\n- A zero-width edge is `sd < 0 ? 1 : 0`.\n- Canvas masks are rects without corners; their feather is f in canvas px.\n- Missing `base` = canvas size, or sw/sscale × sh/sscale for sprites.\n- The `bg` alpha is ignored (drawn opaque).\n- toByte = round half up.\n- Downmix: ITU −3 dB for C and surrounds, LFE dropped, 7-ch Cs = 0.5.\n- Sprite glyph 0xFFFF is never drawn while `reveal` is animated. API-04 must give text-box or background pixels a real glyph id if they should appear during typewriter.\n- The mixer is varispeed only: pitch:true at rate ≠ 1 is exact for RMS but not for pitch.\n\nFixtures (all under packages/danaview_editor_engine_api/)\n- test_fixtures/vectors/*.json and luts/synthetic_17.vlut. Format: test_fixtures/vectors/README.md.\n- test_fixtures/images/goldens.json manifest listing per-golden plans/, goldens/<name>_f<kkkk>.png and the sources/ each frame used: video frames as RGB PNG, images, sprites as straight-alpha RGBA PNG plus a gray16 glyph map, and .vlut tables.\n- Goldens render at longSide 96 (128–192 for the API-03 plans). renderScale = longSide / max(canvas side). The 8× parity case is api03_text_scale_8x (sprite 960×192, sscale 8, xf.s 1→8).\n- The 3-lane QA-11 mix is audio_mix.json case three_lane_reference: tones A 1 kHz, B 440 Hz, music 220/330 Hz at 40% with 1 s fades, voice 700 Hz with keys 100→200→50→100%, a 400 ms equal-power dissolve; the muted and soloed-out lanes are listed under `omitted`.\n\nRegeneration\n- `dart run tool/regen_goldens.dart [--check]` from the package directory.\n- Vector inputs live in lib/src/reference/fixtures/reference_vectors.dart; golden plans and frames in golden_cases.dart.\n- test/reference/regen_check_test.dart imports ../../tool/regen_goldens.dart and fails on any stale file.

**Verification:** From packages/danaview_editor_engine_api:\n- `flutter analyze` (whole package) -> \"No issues found!\"\n- `dart format -l 140 --output=none --set-exit-if-changed lib/src/math lib/src/reference tool test/reference` -> exit 0\n- `dart run tool/regen_goldens.dart --check` -> \"195 files checked, 0 changed, 0 stale\"\n- `flutter test test/reference` -> \"+293: All tests passed!\"\n- `flutter test` (whole package) -> +337, -1. The one failure is API-01's stale placeholder test (test/contract/fake_engine_behavior_test.dart, \"placeholders throw UnimplementedError until their owners land (D-33)\"). It expects ReferenceRenderer().renderFrame to throw, which it no longer does now that API-03 has landed. I did not edit it; see deferred.\n- api_surface_test.dart (API-01) passes: dartdoc rule and dependency rule hold for all new public types.\n- Bit-exact re-render of all 103 committed goldens: 0 differing samples.\n- `flutter analyze` in packages/danaview_editor_engine (depends on the new exports) -> \"No issues found!\"\n- No native build is needed for this ticket.

### AI-03

- **AI-03** (done): Resumed from an earlier attempt that had written the whole shim (src/dv_*.cpp/.h, src/CMakeLists.txt, a test harness header and runner) but had no tests, no tests/CMakeLists.txt and no whisper_host.sh. The shim had also never compiled. Work done this round:

(1) Fixed the compile error in dv_model.cpp (`enum ggml_backend_dev_type` needed the enum tag).

(2) Fixed a real data race that TSan found. When two jobs, or a job and a model loader, start at the same time, whisper.cpp's init paths write process-wide ggml state without a lock (whisper_backend_init -> ggml_log_set, ggml_time_init). The fix is a new process-wide `dv::whisper_init_mutex()` in dv_registry.h/.cpp, held only around whisper_init_from_file_with_params_no_state (dv_model.cpp), whisper_init_state (dv_job.cpp Runner::init_state) and whisper_vad_init_from_file_with_params (dv_vad.cpp). It is never held during inference.

(3) Wrote the host test suite in src/tests: 75 tests, plus a harness (dv_test.h; its comparison macro now copies values so a std::min temporary cannot dangle) and runner (dv_test_main.cpp, now with a per-test check that no model or job handle is left alive). Nothing is downloaded. The tests generate two handmade ggml fixtures at run time:
- A deterministic 1-layer, 64-dim multilingual whisper model, plus an English-only variant. Its decoder MLP implements a fixed token permutation, so every window decodes to `<|0.00|> hello world <|1.98|><|2.00|> <|endoftext|>` and DETECT returns "de" with p≈1.
- A Silero-shaped VAD model that fires on a 437.5 Hz tone.

The suites cover:
- WAV validator (wrong rate, stereo, 24-bit, float/A-law, truncated, odd size, no fmt chunk, LIST chunk, range reads).
- JSON escaping fuzz with 20,000 random byte strings, all parsed back by a strict RFC 8259 / UTF-8 parser.
- Word assembly, including CJK tokens that split characters (complete characters only), punctuation, U+FFFD and monotonic clamping.
- Chunk planning, including that re-planning from a resume point gives the same chunks.
- VAD filter, time map, RMS fallback and real whisper_vad detection.
- Log sanitizer and level rules.
- ABI: stale/null/foreign handles, struct_size prefixes, model load failures, all job argument checks.
- Jobs: deterministic transcription, chunk indices and absolute times, segment paging, monotonic progress, cancel latency < 1.5 s (measured 1–300 ms), free while running, pause at a chunk boundary and pause with abort (the chunk is redone and the output is byte-identical to an uninterrupted run), thread changes and clamping, BUSY, concurrent jobs on two models, model release during a job, range start/end, sub-second skip, carry/initial prompt, English-only model, VAD keeping segments inside speech.
- DETECT: top-3 JSON, speechStartMs, NO_SPEECH with and without VAD, VAD search window.
- dv_shutdown_all with running, paused and still-loading handles, and with a concurrent poller.

The log check: every shim/whisper log line is captured at debug level and checked against registered secrets (segment text, prompts, every file path). whisper_host.sh then greps the captured log file for '/', '\\', .wav, .bin and the fixture text.

(4) scripts/ci/editor/whisper_host.sh follows the INT-01 contract (DANAVIEW_SANITIZER none|thread|address, DANAVIEW_CI_CACHE_DIR). It runs a static check that no DV_LOG format string uses %s, then builds with cmake/ninja (it finds the Android SDK cmake when none is on PATH). The plain leg runs every suite and, on macOS, runs the fixture suites again under `leaks --atExit`, because LSan does not exist on macOS (Linux ASan uses detect_leaks=1). The sanitizer legs run the fixture suites. Last comes the log grep. The real-model files (ggml-tiny-q5_1.bin and ggml-silero-v6.2.0.bin, ARCH §16.2 pins: HF revision URL, byte count, sha256) are downloaded only when GITHUB_ACTIONS=true or with --download-models; a local run never downloads.

(5) TSan on macOS needed tests/dv_tsan_vm_shim.cpp, which is compiled only for Apple TSan test builds. ggml allocates through vm_allocate, which TSan cannot see, so reused pages showed up as false races.

All ACs are met on macOS:
- The plain, TSan and ASan legs all pass (69 passed each; the 6 real-model tests skip).
- `leaks` reports 0 leaks for 0 total leaked bytes over the full suite.
- The grep check passes on about 1,400 log lines.

The Linux legs and the real-model assertions are deferred (see deferred).

**Deferred:**
- Real-model assertions of ai.md §16.3 items 1, 4, 5 and 6 with ggml-tiny-q5_1 and jfk.wav, plus Silero VAD: the "ask not what your country can do for you" transcript, 20x concatenation across chunk boundaries, DETECT en with p > 0.8, and real-model cancel/pause. Deferred: needs a model download, which this round forbids. The tests are written (test_real_model.cpp) and run in CI, where whisper_host.sh downloads the pinned files with size and sha256 checks into DANAVIEW_CI_CACHE_DIR/whisper. Locally they SKIP with the reason, or run with `whisper_host.sh --download-models` once downloads are allowed. The same mechanics are covered deterministically by the fixture-model suites.
- Linux legs (ubuntu plain, TSan, ASan with LeakSanitizer): deferred, no Linux host on this machine. They run in the editor-ci whisper-host matrix through the same script. Everything passed on macOS in the plain, TSan and ASan legs, and macOS leaks reported 0 leaks.

**Hand-off:** Shim build and API facts for the next tickets:

**Build (AI-04, AI-05)**
- `src/CMakeLists.txt` exposes `DV_SHIM_SOURCES`, `DV_SHIM_INCLUDE_DIR` and `DV_WHISPER_SOURCE_DIR`.
- On Android (`ANDROID` or `DV_ANDROID`) it includes `src/cmake/android.cmake` and returns. AI-04 must create that file. It reuses the variables above and links `log`.
- The host build is CPU-only: Metal, BLAS, Accelerate and OpenMP are off; `WHISPER_BUILD_IS_DEV` is OFF so `dv_engine_version()` returns "1.9.4".
- The shim is 11 translation units: dv_whisper, dv_log, dv_cpu, dv_wav, dv_chunker, dv_words, dv_json, dv_vad, dv_registry, dv_model, dv_job (.cpp). AI-05's `ios/Classes/dv_whisper_forwarder.cpp` must `#include` all 11, as `src/tests/dv_unity_check.cpp` does; the host build compiles that file as an OBJECT target so name clashes fail CI.
- `dv_cpu.cpp` calls `MTLCreateSystemDefaultDevice` through the objc runtime on iOS devices, so the pod must link Metal.framework.
- `dv_log.cpp` uses os_log on iOS (not `DV_HOST_BUILD`) and `__android_log_print` with tag "DanaviewWhisper" on Android.

**Runtime behaviour (AI-07)**
- Model load is async: poll `dv_model_get_state`. The loader rejects missing files, files < 48 bytes and bad ggml magic (DV_ERR_MODEL_LOAD) before whisper sees them. An unsupported `dtw_preset` gives FAILED / INVALID_ARG.
- One active job per model; a second start returns DV_ERR_BUSY. The model is marked free before the job's terminal state becomes visible, so the next job can start right after polling a terminal state, even before `dv_job_free`.
- `dv_model_release` while a job runs is safe: the job keeps a reference, and the handle becomes stale for the caller immediately.
- `dv_shutdown_all` cancels and joins all jobs, frees all models and waits for loader threads. All old handles then read as stale: status gives FAILED + DV_ERR_INVALID_ARG, and other calls are no-ops.
- `pause(1)` aborts the running chunk and redoes it on resume; the output is identical to an uninterrupted run (tested). `pause(0)` stops at the next chunk boundary.
- `dv_job_set_threads` clamps to 1..8 and applies at the next chunk.
- `dv_job_take_segments_json(from, max)` pages by absolute index and does not consume; `max <= 0` returns "[]".
- Segment schema keys: i, c (chunk), t0, t1, text, nsp, lp, w[{t, t0, t1, p}]. Times are ms relative to the WAV start.
- DETECT: `dv_job_language_probs_json(top_n <= 0 -> 3)` returns {lang: [{code, p}], speechStartMs} and is null until success. DETECT on an English-only model, or TRANSCRIBE with a non-"en" language on one, returns INVALID_ARG.
- Default log level is warn (2). Shim log lines never carry %s text; whisper's info lines have quoted strings and path-like words replaced by `<redacted>`.

**Thread safety**
- `dv::whisper_init_mutex()` (dv_registry.h) serializes whisper context, state and VAD initialisation, because whisper.cpp writes global ggml logger state there.
- Any new native code that calls `whisper_init_*` must take this lock.

**Tests and CI**
- Runner: `packages/danaview_whisper/build/host-<sanitizer>/tests/dv_tests [Group.]...`. Groups: Wav, Json, Words, Chunker, Vad, Log, Abi, Model, Jobs, Detect, Shutdown, Real.
- Env vars: DV_TEST_WHISPER_MODEL, DV_TEST_VAD_MODEL, DV_TEST_LOG_FILE, DV_TEST_VERBOSE, DV_TEST_KEEP_TMP.
- The fixture generators `write_fixture_whisper_model(path, multilingual)` and `write_fixture_vad_model(path)` in `src/tests/dv_test_support.cpp` make tiny, deterministic, download-free models. AI-04/05/07 device or instrumented tests can reuse them, e.g. by generating a file on the host and bundling it as a test asset.
- The whisper-host CI job's cache key hashes whisper_host.sh, so editing the script invalidates the model cache.

**Verification:** All runs on this Mac (Apple clang 21, CMake 3.22.1 + Ninja from the Android SDK, -j4):
- `bash scripts/ci/editor/whisper_host.sh` (DANAVIEW_SANITIZER=none) -> exit 0. Static %s check ok; build clean, 0 warnings; "69 passed, 0 failed, 6 skipped" (6 real-model tests skipped, no model cached); "log capture: 1413 lines checked against 101 secrets, 0 violations"; leaks step "69 passed, 0 failed, 0 skipped" and "Process ...: 0 leaks for 0 total leaked bytes."; "ok: 1413 log lines, none with text or paths". About 1:16 wall time.
- `DANAVIEW_SANITIZER=thread bash scripts/ci/editor/whisper_host.sh` -> exit 0. "69 passed, 0 failed, 0 skipped", 0 log violations, log grep ok (about 5 min). An earlier run failed on a real race in ggml_log_set from concurrent whisper_init_state; the init mutex fixed it.
- `DANAVIEW_SANITIZER=address bash scripts/ci/editor/whisper_host.sh` -> exit 0. "69 passed, 0 failed, 0 skipped", 0 log violations, log grep ok (about 2 min).
- The real-model suite was also run against the fixture models through DV_TEST_WHISPER_MODEL / DV_TEST_VAD_MODEL. Every test ran to completion with no crash or hang; only the text and language assertions failed, as expected (the fixture says "hello world" / "de").
- No Dart files changed, so flutter analyze/test was not re-run for danaview_whisper; dv_whisper.h and the ffigen bindings are untouched.

### CORE-22

- **CORE-22** (done): An earlier attempt had already written the whole ticket (codec, fragment cache, header model, normative schema, tests and fixtures). I checked it against every acceptance criterion and changed one thing: the fragment-cache benchmark now runs on at least 2,000 items (2,059) instead of 'about 2,000' (it was 1,943).

How each acceptance criterion is met:
- decode(encode(p)) == p on 500 random projects from the CORE-08 generator, each in a plain and a decorated form (round_trip_property_test).
- Deterministic bytes: encoding twice, a warm vs cold cache, jsonEncode(toJson), re-encoding the decoded project, and different map insertion orders all give the same bytes. Golden bodies and fixed key order are checked in determinism_test.
- Container paths: every locator kind under a fake /var/mobile/Containers/Data/Application/<uuid>/ root (plus the /private/var alias, simulator and Android app-data roots) encodes with no persisted container prefix. Only BookmarkLocator.lastKnownPath may keep it, as a hint (container_paths_test).
- Incremental re-encode after a one-item edit at 2,059 items: median 0.315 ms, and 0.487 ms when always editing the largest lane, against a 3 ms budget. The cache is an Expando keyed by object identity (fragment_cache_test).
- Unknown enum values decode to the default with a ProjectOpenWarning, not a failure; malformed bodies throw ProjectFormatException with a path (unknown_values_test, fixtures/forward/future_values.body.json).
- Committed fixtures and the encodings of 200 random projects validate against schema/project.v1.schema.json (draft 2020-12), and the schema rejects malformed bodies (schema_test).
- The header-line model (ProjectHeader with format, schema, minReader, app, savedAt, docRevision, saveId, baseSaveId, bodyBytes, bodySha256) is in schema_version.dart.
- ai.md provenance/origin fields are encoded ('prov', cue 'origin', asset 'origin') and are in the schema.

**Hand-off:** The codec API is exported from package:danaview_editor_core/codec.dart:\n- ProjectJsonCodec has encode(p) (single-line String), encodeBytes(p), toJson(p) and decode(text). decode returns a result with .project and .warnings (a list of ProjectOpenWarning). Unknown enum values and unknown item/track/asset kinds become warnings; malformed bodies throw ProjectFormatException(message, path).\n- Keep one ProjectJsonCodec instance per open project so its FragmentCache (an Expando keyed by object identity) stays warm. encode(p) always equals jsonEncode(toJson(p)).\n- ProjectHeader in schema_version.dart is the header-line model for CORE-24 (format, schema 1, minReader 1, app, savedAt, docRevision, saveId, baseSaveId, bodyBytes, bodySha256). CORE-24 writes the header line and owns the .dnproj I/O.\n- Container-path rule: pool locators under app roots are written as AppRelativeLocator. This goes through the repository's relativizer, falling back to iOS/Android container detection via AppContainerPaths. Only BookmarkLocator.lastKnownPath may hold a container path.\n- The normative body schema is packages/danaview_editor_core/schema/project.v1.schema.json (draft 2020-12, validated in tests with the json_schema dev dependency). CORE-23 migrations and fixtures can reuse test/codec/fixtures (kitchen_sink.body.json, minimal.body.json, kitchen_sink.dnproj, forward/future_values.body.json) and test/codec/support/codec_projects.dart (kitchenSinkProject, minimalProject, decorate, decoratedRandomProject).\n- The lib barrel codec.dart already exports src/codec/migrations/migrations.dart, which CORE-23 owns."

**Verification:** Run in packages/danaview_editor_core:\n- `dart analyze` (whole package): No issues found!\n- `dart test test/codec`: +59, All tests passed! Benchmark printed: project encode (2059 items, 628 KiB): cold 11.64 ms; one-item edit median 0.315 ms, largest lane (400 items) median 0.487 ms.\n- `dart test test/purity_test.dart`: +14, All tests passed!

### CORE-23, CORE-24

- **CORE-23** (done): Migrations framework (Migrations, MigrationStep, MigrationResult, SchemaStamp, SchemaCompatibility) in lib/src/codec/migrations/migrations.dart. The test-only s0->s1 step is in s0_to_s1.dart, a part file exported through the codec barrel. s0 fixtures migrate to valid s1 projects, validated against project.v1.schema.json, decoded, re-encoded and round-tripped. Step idempotence is tested on every fixture and by an inverse property over 100 random projects. Newer-schema detection reads only the header line (tested with an invalid-UTF-8 1 MB body). Opening never writes (FaultInjectingFs log is empty and the tree is unchanged). needsPreMigrationBackup, preMigrationBackupName and migratedFrom are provided; the backup itself is written by CORE-25.
- **CORE-24** (done): Implemented StoreFs, LocalStoreFs, FaultInjectingFs, AtomicFile, the .dnproj format and DnprojFiles, OwnedFileDeleter and DocumentsExportWriter. Crashing at every step with every torn-write mode always leaves a valid main, tmp or bak document, and a 300-run random crash storm never loses an acknowledged save. Checksums detect every truncation and every single-bit body flip. The deleter fuzz (2,500 attempts over symlinks, '..', case variants, NFC/NFD, Documents, external assets) never touched a protected file. DocumentsExportWriter leaves a pre-existing file untouched (hash, size, mtime, ctime) and writes '<name> (2).mp4'; a symlinked Exports directory is refused. V-D1 is documented in the store_fs.dart header: the public Dart doc says flush() writes to disk and the VM maps it to fsync; the native file_posix.cc is not in the SDK, so the fsync claim is from memory. Device confirmation is deferred to QA-10. D-43 owner defaults are already in ARCHITECTURE.md (the 2026-10-08 status row), so I did not edit it.

**Deferred:**
- V-D1 on-device confirmation that flush() fsyncs (kill -9 and battery-pull during autosave): QA-10, deferred: needs a real device.
- The native File::Flush fsync claim could not be re-read from SDK source (file_posix.cc is not in the SDK distribution); it rests on the public doc and recollection of the VM source.
- Crash during a DocumentsExportWriter copy can leave a partial file in Documents/Exports, because it exclusive-creates the final name and the writer never deletes; the file stays until the user removes it. This is documented in the file header.
- Production Migrations.standard has an empty chain (schema 1 is the first shipped schema); s0->s1 is test-only, as ARCH 8.5 specifies. When schema 2 lands, add its step to the standard chain and add s2 entries to allFixtures.

**Hand-off:** Public API for CORE-25/26/27/28 (all exported from package:danaview_editor_core/codec.dart or store.dart).

MIGRATIONS (codec.dart)
- Migrations(chain, {target = currentProjectSchema, supportedMinReader}); Migrations.standard is the production instance (empty chain).
- testMigrationsS0ToS1() and testMigrationS0ToS1 are the test-only step, exported from the same barrel.
- classify(schema:, minReader:), classifyHeader(ProjectHeader) and classifyDocument(Uint8List) return a SchemaCompatibility: current, needsMigration, readOnlyNewer, needsNewerApp or unsupportedOld.
  - Map to ProjectHealth: readOnlyNewer -> ProjectHealth.readOnlyNewer; needsNewerApp -> ProjectHealth.needsNewerApp (StoreFailure newerSchema on open); unsupportedOld -> corrupt.
  - classifyDocument reads only the first line, via SchemaStamp.readFrom, which is tolerant of other header fields.
- migrate(bodyMap, from: headerSchema) returns MigrationResult {body, fromSchema, toSchema, applied, migrated, migratedFrom, needsPreMigrationBackup, preMigrationBackupName}.
  - Steps get a private deep copy, so the input is never mutated.
  - If from is already current, the same map comes back.
  - Failures surface as ProjectFormatException.
- Open flow for the repository: DnprojFiles.read -> classify -> jsonDecode body bytes -> migrate -> ProjectJsonCodec.decodeJson(result.body). Do not write anything on open.
- The first save after a migration should copy the original to projectDir/backups/Migrations.preMigrationBackupName(fromSchema).

STORE (store.dart)
- StoreFs methods: readBytes, readPrefix, writeBytesSynced, copyFile, copyExclusive (returns bool), rename (file or directory, replaces a file), delete(recursive), createDirectory, stat (lstat, StoreEntityType file/directory/link/notFound), list, canonicalize.
- StoreFs implementations: LocalStoreFs (const) and FaultInjectingFs(inner) with crashAtStep(n, torn:), failStep, failWhere, restart, reset and log. SimulatedCrash is the crash exception.
- storeFailureOf(error) maps errno values to StoreFailure.
- AtomicFile({fs, deleter, random}):
  - write(path, bytes) does tmp, then main->.bak, then tmp->main, then removes stale tmps through the deleter if one is given.
  - read(path, isValid:) returns AtomicRead{bytes, source main|temp|backup, path}. Fallbacks are chosen newest first by mtime, with tmp winning a tie. It throws StoreFailure notFound or corrupt and never writes.
  - AtomicFile.backupPath(p) and tempPrefix(p) are static helpers.
- DnprojFormat:
  - build(bodyBytes, app:, savedAt:, docRevision:, saveId:, baseSaveId:, schema:, minReader:).
  - encode(header, body), parse (throws DnprojException with a DnprojIssue), tryParse, isValid, and maxHeaderBytes.
- DnprojFiles({fs, atomic}): readHeader(path) reads a bounded prefix and never the body; read(path) returns DnprojRead{document{header, body}, source, path}; write(path, docBytes) refuses invalid documents.
- Hash in the writer isolate: pass the already-encoded body bytes to DnprojFormat.build.
- OwnedFileDeleter(roots, {fs, engineOutputPrefixes: ['export-'], onViolation, assertOnViolation: true}).
  - delete(path, {recursive}): inside editorSupport or editorCache and outside documents, never the roots themselves. A missing path inside the roots is a no-op; a path outside them is refused even if missing.
  - deleteAsset(MediaAsset): refuses external ownership, and any locator that is not AppRelativeLocator or FileLocator.
  - canConsume(tempPath) allows regular files under work/picks/**, work/drops/** and work/export-* (including work/export-*/**); consume(tempPath, destination:) renames into the editor roots.
  - Violations throw OwnershipViolation, after calling onViolation and asserting in debug. Tests that expect OwnershipViolation should pass assertOnViolation: false.
  - Pass the same FaultInjectingFs into the deleter and AtomicFile in crash tests.
- DocumentsExportWriter(roots, {fs}).keepCopy(sourcePath, fileName:) returns the written path.
  - It throws ArgumentError for a bad file name and OwnershipViolation for an unsafe source or Exports directory, and the same OwnershipViolation if a candidate name is a symlink.
  - It throws StoreFailure on I/O errors.
- StoreRoots gained picksDir and dropsDir getters.

CONVENTIONS
- Each save does an extra stat/createDirectory call, so a first write against FaultInjectingFs counts createDirectory as step 1.
- Test helpers: test/store/fs/support/harness.dart (Container, document(rev), revisionOf) and test/codec_migrations/support/fixtures.dart (allFixtures, regenerate).
- REGENERATE_FIXTURES=1 dart test test/codec_migrations/fixtures_test.dart rebuilds the committed .dnproj fixtures from the .body.json files.

**Verification:** In packages/danaview_editor_core: `dart analyze` printed "No issues found!". `dart test` ran the whole package and ended "+3429: All tests passed!", including purity_test, test/codec_migrations (35 tests) and test/store/fs. I did not run `dart format` because the repo's existing files use long lines.

### CORE-27

- **CORE-27** (done): I built this from scratch, because all four files I own were still scaffold placeholders.

- import_policy.dart: `ImportPolicy` has the D-13 routing for every ARCH §9.1 row, per `ImportPlatform` (ios, android, desktop).
- managed_store.dart: `ManagedStore` stores content-addressed copies at media/<hh>/<quickHash>/<sanitized name>. A copy goes to a .part-<rand> file and is then renamed into place. A file is moved only through `OwnedFileDeleter.consume` when `canConsume` allows it. An existing copy is reused, and a duplicate temp clone is deleted through the guard. It also writes project-owned files (luts, recordings, stills) and calls `excludeFromBackup` on media/ and derived/ once.
- dart_io_media_access.dart: `DartIoMediaAccess` is read-only (stat, quickHash, resolve). `persist` turns paths under the app roots into `AppRelativeLocator`s. `excludeFromBackup` refuses anything outside the editor and speech roots.
- media_pool_service.dart: `FileMediaPoolService.import` does stat, then `quickHash`, then dedupe by quickHash within the project (re-picking reuses the `MediaId`), then probe, route and store, then one sticky `AddAssets` per item. Imports into one session run one batch at a time.
- The four relink methods (`watchAvailability`, `checkRelink`, `autoMatch`, `relink`) and `findInSameFolder` are delegated to `MediaRelinkDelegate` (CORE-28).

All acceptance criteria are met by 99 tests in test/store/media/. They cover:
- every §9.1 row against a fake platform port;
- re-pick reuse within a project and within one batch, sharing a copy across projects, and two concurrent imports;
- temp copies moved only when allowed: work/picks and work/drops are moved; an untrusted temp flag, a symlink planted in work/picks, and the Android incoming cache are copied;
- the grant-budget fallback (fewer than 32 grants left, budget running out mid-batch, URI not persistable, no copier available);
- an fs-spy test on all three platforms: every logged write, copy destination and rename source/destination is inside the editor roots, and every file outside them is byte-identical with the same mtime. A separate test checks that the spy itself catches violations.
- crash-at-every-step and torn-write tests on copies, disk-full errors and the free-space preflight.

Nothing in this ticket needs a device. Deferred:
- Byte-level copy progress for the UX-41 dialog. Item-level `onProgress` and `isCancelled` are done.
- On-device confirmation of the native APFS clone path (V-D8) is left to IOS-15. It only affects performance.

**Deferred:**
- Byte-level copy progress for the UX-41 cancellable dialog. StoreFs.copyFile (CORE-24) copies in one call, so it can't report progress. Item-level onProgress and isCancelled are implemented.
- On-device confirmation of the native APFS clonefile path for iOS Photos picks (V-D8), left to IOS-15. It only affects performance; the reasoning is documented in the managed_store.dart header.
- The real Android content:// copier (the PickMaterializer function) is native work for AND-14 and needs wiring in INT-02. Until it is provided, such picks are rejected with 'notPersistable'.

**Hand-off:** CORE-27 API (all exported from package:danaview_editor_core/store.dart):\n\n**FileMediaPoolService** — constructor: `FileMediaPoolService({required MediaAccessPort access, required MediaProber probe, required StoreRoots roots, StoreFs fs, ImportPlatform? platform (defaults to the host), ManagedStore? store, OwnedFileDeleter? deleter, IdGenerator? ids, DateTime Function()? clock, PickMaterializer? materialize, FreeSpaceProbe? freeSpace, MediaRelinkDelegate? relinker})`.\n- `import(session, picks, {target, onProgress, isCancelled})` returns `List<ImportOutcome>`.\n  - `ImportedMedia(asset, reused)` means the item was added or matched an existing asset.\n  - `ImportRejected.reason` is one of: unsupported, a probe issue code in lowerCamel (containerUnsupportedIos), empty, notFound, accessDenied, notPersistable, diskFull, lutInvalid, cancelled, io.\n  - Each item is applied at once with `session.applyPoolChange(AddAssets([asset]))`, which is sticky (never in undo history).\n  - Calls on the same session run one at a time.\n- `place(session, outcomes, target)` adds one `InsertMedia` history entry; LUTs are skipped. With `asOverlay` it uses the first unlocked overlay lane, or first applies `AddTrack(overlay)` as its own entry.\n- `inFlightQuickHashes`: CORE-28 GC should treat these hashes as marked.\n- `hostImportPlatform()` returns the platform of the running process.\n- The relink methods (`watchAvailability`, `checkRelink`, `autoMatch`, `relink`) and `findInSameFolder` delegate to `relinker`, which CORE-28 implements as `MediaRelinkDelegate`. With no delegate they throw `UnsupportedError`.\n\n**Callback typedefs**\n- `MediaProber = Future<MediaProbe> Function(ResolvedMedia)`\n- `FreeSpaceProbe = Future<int?> Function(String dir)`. The preflight requires size + 64 MB free, and runs only before copies, not moves.\n- `PickMaterializer = Future<String> Function(PickedMedia, String intoDir)`. The native side copies a content:// URI into `<cache>/danaview/editor/work/picks/<x>/<name>` and returns that path; the service then moves it into media/. AND-14 and INT-02 must provide it.\n\n**ImportPolicy** — `ImportPolicy({platform, roots}).decide(picked)` returns `ImportDecision{route, sourcePath, contentUri, temporary, ownership}`.\n- Routes: managedCopy, bookmark, persistedGrant, documentsReference, fileReference, projectLut, projectRecording, projectStill.\n- Constants and helpers: `minGrantBudget` = 32, `grantBudgetExhausted(n)`, `freeSpaceMarginBytes` = 64 MB, `isLut`, `pathOf(uri)`.\n- A pick is temporary only if it lives under work/picks or work/drops, or is flagged as a temp copy and lives under work/.\n\n**ManagedStore** — `ManagedStore(roots, {fs, deleter, access, random})`.\n- Path helpers: `mediaRelPath(hash, name)` = 'danaview/editor/media/<hh>/<hash>/<sanitized>'; `projectAssetRelPath(projectId, folder, name)` = 'danaview/editor/projects/<id>/assets/<folder>/<name>'.\n- `vlutOf(cubeLocator)`: the .vlut sits next to the .cube. A LUT asset's locator points at the .cube; INT-02's asset resolver should use `vlutOf`.\n- Name and file helpers: `sanitizeFileName`, `ensureLayout()`, `findManaged(hash)`, `adopt(src, quickHash, displayName, temporary)`, `storeProjectFile`, `writeProjectBytes`, `discardTemporary`. Each store call returns `StoredFile{locator, path, reused, moved}`.\n\n**Asset locators by route**\n- Managed copies: `AppRelativeLocator(support, 'danaview/editor/media/...')`, ownership managedCopy.\n- Project LUTs: `projects/<pid>/assets/luts/<mediaId>.cube` plus `.vlut`. Recordings: `recordings/<mediaId>.wav`. Stills: `stills/<mediaId>.png`. All projectOwned. A recording already inside the project bundle is referenced where it is.\n- Documents files: `AppRelativeLocator(documents, rel)`, external.\n- Grants: `ContentUriLocator`; bookmarks: `BookmarkLocator` (the port's result; a `FileLocator` under the roots is relativized). Both external.\n- Desktop: `FileLocator`.\n\n**DartIoMediaAccess(roots, {grantBudget})** — `pathOf(locator)`; `excludedDirs` records accepted `excludeFromBackup` calls. Content URIs and bookmarks throw `MediaAccessFailure(accessLost)`.\n\n**Test helpers** — test/store/media/support/media_fixtures.dart provides `MediaWorld` (container, FakePlatformPort, FaultInjectingFs spy, service, session), `fakeProbe`, `FakeMaterializer`, `bytesOf`, `u8`, `opsOutsideEditorRoots()` and `originalsSnapshot()`. CORE-25 and CORE-28 can reuse it.\n\n**Not done here**\n- ARCHITECTURE.md is not my file, so I did not add the V-D8 result there. The reasoning is in the managed_store.dart header and should be copied into the ARCH V-table by its owner.\n- The D-43 owner-defaults note is not in my ticket scope, so I did not write it."

**Verification:** Commands run in packages/danaview_editor_core:\n- `dart analyze .` printed \"No issues found!\"\n- `dart test test/store/ test/purity_test.dart` printed \"+243: All tests passed!\"\n- `dart test test/store/media` printed \"+99: All tests passed!\"\n\nNo native build is needed, because the ticket is pure Dart.

### CORE-25, CORE-26, CORE-28

- **CORE-25** (done): Most of this ticket was placeholders, so most of the work is new. FileProjectRepository implements every ProjectRepository method from ARCH §8.4. open reads the main document, falls back to the newest valid tmp or .bak, classifies the schema (D-12), migrates, decodes, repairs and checks for recovery. It runs in Isolate.run and never writes. A second open of the same project fails with StoreFailure(busy). Saves encode incrementally on the calling isolate and then hash and write in a long-lived IsolateProjectWriter. Writes for one project go through one LatestWinsQueue (one at a time, latest pending request wins). A main save writes, in order: the pre-migration backup (first save after a migration), the main document, the poster (on lifecycle and close), refs.json and meta.json, then truncates the journal. create(fromMedia) imports through MediaPoolService and derives settings with deriveProjectSettings; the project stays untouched (editCount 0) and view.playhead is quantized. rename accepts 1-80 characters after trim and also rebases a pending journal. duplicate names copies '<name> copy', '<name> copy 2', shares managed media and copies project-owned files. delete renames the bundle into trash/, deletes it through OwnedFileDeleter and then calls the GC hook. The Projects list scans meta.json and rebuilds missing or stale meta.json/refs.json in an isolate; bundles whose first write never finished are skipped. findUntouchedProjectFor and storageReport are implemented. lib/testing.dart provides MemoryStoreFs and InMemoryProjectRepository (the real repository running inline over FaultInjectingFs(MemoryStoreFs)). Tests in test/store/repository/ (75): every method on FaultInjectingFs; a crash at every step (clean, torn-empty and torn-half writes) for save, create, rename, duplicate and delete, plus a failed promote during restore; the container-path check (no container prefix in any persisted byte, and reopening under a different <uuid> root with zero missing media); duplicate sharing managed media; delete never touching Documents or external files; the fromMedia settings table; all four ProjectHealth values; the migration backup; the isolate writer. Benchmark: opening 2,000 items took 10.2 ms best (13.2 ms median) against the 150 ms budget. The interface files project_repository.dart, project_summary.dart and storage_report.dart already matched ARCH §8.4 and were not changed.
- **CORE-26** (done): AutosaveScheduler: saves after 2 s idle, forced at 10 s, skipped while a transaction is open (retried one idle period later), one save at a time. A failure reports AutosaveStatus(failed, StoreFailure) and is retried on the next trigger. Time comes from an injected StoreTimerFactory and clock. ProjectJournal: slots a/b alternate and are written directly; a main save truncates them; 'Open last saved' keeps the journal as recovered-<ts>.dnproj until the next successful main save. ProjectRecovery: a journal is recoverable only when its docRevision is above main's and its baseSaveId equals main's saveId; when no main copy can be read, the newest valid slot is offered. restore promotes atomically through AtomicFile; discard deletes the slots. The repository wires all of this into requestAutosave, save(autosave), recoverable, restore, discard and LoadedProject.pendingRecovery. Open projects are excluded from recoverable(). Tests in test/store/recovery/ (22): fake-clock debounce, cap, transaction pause, single-flight and failure-then-retry; slot alternation; truncation on main save; the recovery listing rules (newer only, matching baseSaveId, a torn slot falling back to the other slot); restore, discard and recovered-<ts>; disk full then a successful retry; a crash at every write step of autosave and main save (three torn modes) always keeping the newest completed state recoverable. Benchmark: the main-isolate part of an autosave at 1,000 items (the incremental encode) took 0.34 ms best (0.49 ms median) against the 2 ms budget.
- **CORE-28** (done): Every acceptance criterion is met except the device runs listed under deferred (the bmgr procedure for V-A7 and the V-D4 iOS check). availability.dart: MediaAvailabilityChecker covers available (size and mtime equal skip hashing, otherwise quickHash), missing (including repair placeholders FailedStatus('missing')), accessLost, changed and derivedMissing (reversed rendition, pending job, missing .vlut). AvailabilityMonitor reports on first listen, on refresh (resume) and after a relink. relink.dart: MediaRelinkService implements CORE-27's MediaRelinkDelegate. checkRelink returns match (exact fingerprint, or duration within ±100 ms with equal kind and dimensions), durationMismatch, differentKind, or unsupported (reason codes such as dimensionsDiffer and notFound). relink persists picks the same way import does (managed copy, bookmark, grant, Documents reference, or a file in the project bundle) and applies ONE RelinkAssets pool edit labelled 'Relink media'. For a shorter file, the same entry trims forward clips at the tail and reversed clips at the head, and removes clips that start past the new end. autoMatch pairs by exact fingerprint first, then by one-to-one duration and dimension matches; ambiguous picks get unsupported('ambiguous'), unmatched ones 'noMatch'. findInSameFolder works only for Documents paths, or any path on desktop. gc.dart: ProjectRefs is the refs.json format (root-relative paths). MediaGarbageCollector marks refs.json of every project (falling back to the document), journal slots, open sessions (retainedMedia, including history deltas), open projects, in-flight imports and in-flight jobs. It sweeps media/<hh>/<hash> folders and derived files older than 24 h, empties trash/, and never follows or deletes links. It releases grants and bookmarks that are no longer referenced, tracked in a grants.json ledger. Nothing is swept when any project's references cannot be read, and the export gate is checked before the sweep and before every delete. GcScheduler runs 30 s after start, after a project delete and on demand, one run at a time. Android: res/xml/danaview_data_extraction_rules.xml (cloud-backup and device-transfer) and danaview_backup_rules.xml both exclude domain=file danaview/editor and danaview/speech. AndroidManifest.xml got only the android:dataExtractionRules and android:fullBackupContent attributes. Tests in test/store/gc/ (27): every availability state; every relink outcome; relink as one undo step; autoMatch relinking 10 missing Photos assets from one 10-item pick with ambiguous picks left unassigned; findInSameFolder; GC mark and sweep, grants, export gate, unreadable project, scheduler; a 40-seed fuzz; backup rules and manifest. test/store/gc/README.md documents the V-A7 bmgr procedure and the V-D4 hand-off.

**Deferred:**
- V-A7 (CORE-28): running the Android bmgr Auto Backup / device-transfer procedure on an emulator or device. Deferred to QA-10 because it needs an emulator; the procedure is written in packages/danaview_editor_core/test/store/gc/README.md, and the rule files and manifest attributes are asserted by backup_rules_test.dart and validated with aapt2.
- V-D4 (CORE-28): confirming on iOS that NSURLIsExcludedFromBackupKey on a directory excludes its contents. Deferred to IOS-15 (native) and recorded in QA-10 (no device available). The core side (ManagedStore.ensureLayout calling excludeFromBackup on media/ and derived/) is CORE-27's and is in place.
- ARCHITECTURE.md is not a file my tickets own, so I made no edit there. The D-43 'owner defaults 2026-10-08, revisable' note is already present (recorded by INT-01).
- UX-01's packages/danaview_editor/test/support/fake_project_repository.dart (not my file) can now delegate to InMemoryProjectRepository from package:danaview_editor_core/testing.dart.

**Hand-off:** Everything below is exported from package:danaview_editor_core/store.dart unless marked as coming from testing.dart.

**FileProjectRepository** (CORE-25) implements ProjectRepository. Constructor: `FileProjectRepository({required StoreRoots roots, StoreFs fs = const LocalStoreFs(), OwnedFileDeleter? deleter, bool? useIsolates, ProjectWriter? writer, MediaPoolService? media, MediaAccessPort? access, IdGenerator? ids, DateTime Function()? clock, Migrations? migrations, String appVersion = '1.1.0', bool allow2160 = false, PosterProvider? poster, ProjectDeletedHook? onProjectDeleted, AutosavePolicy autosavePolicy, StoreTimerFactory? timer})`.
- `useIsolates` defaults to true when fs is LocalStoreFs: open and scan then run in Isolate.run, and writes go to a lazily spawned IsolateProjectWriter.
- Extra public members:
  - `summaries()`
  - `writeNewProject(EditProject)`: writes a closed bundle (used for seeding)
  - `openSessions` and `openProjects`: the GC's inputs
  - `openIds`
  - `watchAutosave(id)`: `Stream<AutosaveStatus>`, which the UX-08 SaveStatus maps from
  - `noteMissingMedia(id, count)`: stored as meta.json `missing` on the next save
  - `dispose()`
  - `static playerOriginOf(fp, name)`
- Errors:
  - open throws `StoreFailure(busy | notFound | newerSchema | corrupt)`.
  - create(fromMedia) with nothing importable throws `ProjectCreateFailure(outcomes)`.
  - Names outside 1-80 characters throw ArgumentError.
  - rename, duplicate or delete of an open project throws `StoreFailure(busy)`.
- `typedef PosterProvider = Future<Uint8List?> Function(EditSession)` is called on lifecycle and close saves.
- The warning code `restoredFromBackupWarning` is set when open used the .bak or a tmp copy.
- Pure helpers: `deriveProjectSettings(MediaProbe?, {allow2160})`, `snapAspect`, `snapFrameRate`, `baseShortSideFor`.
- `ProjectMetaFile` is the meta.json format: v1, poster as a bundle-relative name, a missing count, bundleBytes, origin. `ProjectSummary.bytesOwned` = bundle bytes + managed folders referenced only by that project.

**Writer and queue**: `ProjectWriter`, `InlineProjectWriter`, `IsolateProjectWriter.spawn(roots)`, `DocumentStamp`, `LatestWinsQueue<T>.enqueue(kind, task, supersedes:)`.

**testing.dart**: `MemoryStoreFs` (putFile, touch, mkdirs, peek, filePaths) and `InMemoryProjectRepository({media, access, ids, clock, roots = /mem/{support,cache,documents}, autosavePolicy, timer, poster, onProjectDeleted, allow2160})`, which exposes `.inner`, `.fs` (FaultInjectingFs), `.memory`, `seed(EditProject)`, `summaries()` and `dispose()`.

**CORE-26**:
- `AutosaveScheduler({save, isPaused, policy, timer, now})` with `request`, `flush`, `cancel`, `dispose`, `status` and `statuses`. `AutosaveStatus.phase` is idle, pending, saving, saved or failed (with `failure`).
- `ProjectJournal` (slots a/b, `recoveredName`, `truncate`, `keepAsRecovered`).
- `ProjectRecovery(dir, fs, deleter)` with `inspect`, `restore`, `discard`, `keepLastSaved`; `isRecoverableOver(journalHeader, mainHeader)`; `RecoveryCandidate.toSession(id)`.
- Autosave runs only after `requestAutosave(session)`. A journal header has baseSaveId = the main saveId. Autosave also rewrites refs.json when the pool identity changed.

**CORE-28**:
- `MediaRelinkService({access, probe, roots, fs, platform, store, deleter, materialize, clock})` implements MediaRelinkDelegate. Pass it as `FileMediaPoolService(relinker: ...)`.
  - `resumed()` re-checks every watched session; call it on app resume.
  - Also: `monitorOf(session)`, `blockingAssets(session)`.
- `compareForRelink(asset, probe)`; `relinkDurationToleranceUs` = 100000.
- `MediaAvailabilityChecker(access)` with `check` and `checkPool`; `AvailabilityMonitor`; `AvailabilityCounts.of(report).blocking`; `missingPlaceholderReason` = 'missing'.
- `ProjectRefs` (ofAssets, ofProject, ofSession, encode, decode, union) is the refs.json format.
- `MediaGarbageCollector({roots, fs, deleter, access, openSessions, openProjects, inFlightQuickHashes, inFlightDerived, exportInProgress, clock, grace = 24h})` with `collect()` returning `GcReport{skipped: exportInProgress | unreadableProject | busy, deleted, freedBytes, released, keptForGrace}` and `noteReleaseCandidates(refs)`. The ledger lives at `<editorSupport>/grants.json`.
- `GcScheduler(collector, {timer, startDelay = 30s})` with `start()`, `runNow()`, `projectDeleted(refs)`, `dispose()`.
- `typedef ProjectDeletedHook = Future<void> Function(ProjectId, ProjectRefs?)`.

**INT-02 wiring**:
1. `pool = FileMediaPoolService(..., relinker: MediaRelinkService(...))`.
2. `repo = FileProjectRepository(roots, media: pool, access: engineMediaAccess, allow2160: caps, poster: engineThumb, onProjectDeleted: (id, refs) => gcScheduler.projectDeleted(refs))`.
3. `gc = MediaGarbageCollector(openSessions: () => repo.openSessions, openProjects: () => repo.openProjects, inFlightQuickHashes: () => pool.inFlightQuickHashes, inFlightDerived: <engine jobs>, exportInProgress: <export service>)`.
4. `gcScheduler.start()` at app start; Settings › Storage calls `runNow()`.

**Android**: res/xml/danaview_data_extraction_rules.xml and danaview_backup_rules.xml exclude file danaview/editor and danaview/speech. The manifest `<application>` gained only the dataExtractionRules and fullBackupContent attributes.

**Verification:** `dart analyze` (packages/danaview_editor_core) -> No issues found!
`dart test` (whole danaview_editor_core suite, run from the package root) -> 00:38 +3802: All tests passed! This includes purity_test.dart (barrel reachability, OWNER headers, no dart:io outside store).
`dart test test/store/repository test/store/recovery test/store/gc` -> 00:01 +120: All tests passed!
Benchmarks printed: 'open 2,000 items: best 10.2 ms, median 13.2 ms' (budget 150 ms); 'autosave encode at 1,000 items: best 0.34 ms, median 0.49 ms' (budget 2 ms).
`flutter analyze` on the danaview_editor files that import the store barrel (lib/src/app/editor_providers.dart, lib/src/projects/project_card.dart, test/support) -> No issues found!
Android resources: `aapt2 compile` of both xml files -> COMPILED; `aapt2 link` of a minimal manifest with the two new attributes against platforms/android-3x android.jar -> LINK_OK; `xmllint --noout AndroidManifest.xml` -> MANIFEST_OK. No Gradle or Xcode build was run (no native code changed, and heavy builds were avoided on the shared 8 GB machine).

### CORE-30

- **CORE-30** (done): An earlier attempt had already written most of the ticket: compiler.dart, asset_resolver.dart, lowering_visual.dart, z_order.dart, 20 goldens and the property, asset/mapping and z-order tests. This round fixed one failing test and added the missing benchmark. The failing test was 'CanvasMapping fit letterboxes a portrait project into a landscape output': the test expected blurScale 1, but the formula scale·min(project)/min(output) gives 0.5625 for 1080x1920 into 1920x1080. The test's own comment and the general blur-scale property test both confirm 0.5625, so the expectation was wrong, not the code. The new test is compile_benchmark_test.dart: a full compile of a 2,013-item project inside Isolate.run, median of warm runs about 4.4 ms preview and 3.6 ms export against the 60 ms budget (×3 CI factor). Acceptance criteria: one golden per lowering row (fit+crop, transform/effects/look/chroma/mask, imported LUT, keyframes→anim, constant speed, speed ramp, reversed rendition, pending reverse, BlurOfMain #bd, missing media, pending still hold / no-hold, proxy preview vs export, hidden/muted/solo, z bands, PiP packing slots, image layers, export letterbox and scaled): met. Every golden and 40 seeded random projects × both targets × 4 outputs × holdFrame on/off pass the CORE-29 PlanValidator: met. Model-derived packing inputs equal the compiled media-layer ranges on every golden and on random seeds: met. Shared-code test that layers are placed by geometry's baseSize/positionToCanvas, the boxAt matrix: met. Hidden/muted/solo honoured: met. Benchmark: met. Nothing deferred.

**Hand-off:** CORE-30 public API is exported from package:danaview_editor_core/plan.dart.

Compiling:
- `compilePlan(project, PlanTarget, PlanAssetResolver, {CompileOptions options})` returns `CompiledPlan{plan, requirements, packing, isComplete, violations()}`.
- `compileRenderPlan(...)` returns the RenderPlan only.
- `shouldCompileInIsolate(project)` is true above `compileIsolateThreshold` = 300 items.

CompileOptions:
- `rev`.
- `output: PlanOutputSpec(width, height, fps)` for export canvases. The project canvas is letterboxed inside via `CanvasMapping.fit`, and every layer gets a content-clip canvas mask. `canvas.gridFps` stays the project rate.
- `holdFrame`.
- `stages: List<PlanLoweringStage>`. This is CORE-31's hook: `lower(PlanCompilation c)` mutates `c.layers`, `c.audio`, `c.assets` and `c.requirements`. It can read `c.clips[itemId]` (a LoweredClip with playbackAsset/playbackMap), `c.laneOfClip`, `c.lanes`, `c.canvas`, `c.mapping` and `c.assetFactory`. Stages need not set `seq` or order layers; the compiler packs with packVisualLayers and sorts by (z, t0, id) afterwards.
- `memo: ClipLoweringMemo` is CORE-32's interface: `lookup(clip, ClipLoweringKey)` / `store(...)`, keyed by clip identity.

Requirements:
- `PlanRequirementsBuilder` collects offline, pendingReverse and pendingStill.
- `req` is set only on preview plans. Export callers (CORE-33) must check `CompiledPlan.requirements` and return ExportBlocked.

Assets:
- `PlanAssetResolver` has `original(id)`, `proxy(id)`, `builtinLook(presetId)` and `importedLut(id)`. INT-02 implements it; tests use `MapPlanAssetResolver`.
- `PlanAssetFactory` builds the asset entries. Asset id = MediaId; bundled looks use `lk_<presetId>`.
- Non-file/content URIs are treated as offline. Proxies appear only in preview plans with ProxyState.ready.

Z order:
- `PlanZ.of(band:, laneIndexInBand:, sub:)`, `PlanZ.backdrop`/`transitionHelper` (z∓5), and `planLanesOf(tracks)`. Hidden lanes are counted in the lane index.

Test helpers: shared builders live in test/plan/compile_visual/support.dart (`asset`, `clip`, `project`, `mainLane`, `resolverFor`). To regenerate goldens, run `DANAVIEW_UPDATE_GOLDENS=1 dart test test/plan/compile_visual/compile_goldens_test.dart`.

**Verification:** cd packages/danaview_editor_core && dart analyze -> 'No issues found!' (whole package). dart test test/plan test/purity_test.dart test/eval/packing -> '00:04 +583: All tests passed!'. Benchmark output: 'compile: 2013 items, 888 layers: median preview 4.39 ms, export 3.63 ms (in isolate); one Isolate.run round trip 4.9 ms'.

### CORE-31, CORE-32, CORE-33

- **CORE-31** (done): The four stub files are now full implementations: lowering_transitions, lowering_text, lowering_audio and sprite_requests.

Transitions:
- Window is [timeOfFrame(c−⌊n/2⌋), timeOfFrame(c+⌈n/2⌉)), the same arithmetic as packingInputsOf; a test checks the two agree.
- Fade: left xf.op ×(1→0) over [w0, c], right ×(0→1) over [c, w1], no extension.
- Cross dissolve: both clips extended over the window with handles via extendMap at the edge speed; the incoming clip sits on top (later t0) with op 0→1.
- Dip to black/white: a `<left>#tx0` solid at lane z+5 covering the content rect, op 0→1→0.
- Slide: ease-in-out cubic sampled as 8 linear segments; off-canvas means the content rect width or height.
- Wipe: an animated cmasks rect with feather = 2% of the swept dimension.
- Zoom in/out: scale 1.25 / 0.8 with an opacity crossfade.
- Helper channels are merged with user keyframes on a merged breakpoint set (opacity and scale multiply, translation adds). Where two multiplied factors both vary, the product is sampled at each frame start in between.
- Helpers are applied to both #v and #bd layers.

Text and subtitle sprites (export target only, D-05):
- Text items become sprite layers: base from the sprite, xf from the transform (flips ignored), anim = keyframes merged with the text animation sampled at textAnimationBreakpoints (exact), and typewriter adds a `reveal` channel 0→n.
- Burned cues become `<cueId>#c` layers anchored by cueCenter using the sprite height.

Audio (one `<itemId>#a` segment per audible clip):
- Asset, range and map are taken from the clip's #v media layer itself, so they match exactly. Clips without a picture layer (audio lanes, hidden lanes) use clipPlayback + clipExtentsOf + extendMap, the same functions the picture uses.
- Gain = volume keys × linear fades × transition factor × speed gate. Fade and dip transitions dip the gain; overlap kinds use an equal-power cos/sin crossfade. The speed gate is 0 on map segments faster than maxAudioSpeed (D-15).
- Sampling: extra samples every 20 ms where the product is non-linear, then adaptive bisection until within 0.1 dB of the analytic gain (absolute below −60 dB). A constant envelope is one key.
- pitch = maintainPitch; stream = audioStream.

sprite_requests:
- Raster scale = exportScale × maxAnimatedScale, clamped to min(maxTextureSize, 2 × output long side), using measured size when a TextMetricsProvider is given, else estimateTextBlockSize.
- Key = sha1 of {spec, scale, canvas, fontsVersion, reveal}.

Acceptance criteria:
- Goldens: 31 in test/plan/compile_lowering/goldens, covering every transition kind and direction, the merged-keyframe case, every text animation, burn-in on, burn-in off, preview without sprites, and the audio rows.
- 8× scale keyframe: raster scale 16 (exportScale 2), clamped to 4096/400 at maxTextureSize 4096.
- Volume 200%: gain 2.0 = +6.02 dB.
- Envelope ≤ 0.1 dB against the analytic gain: checked on 300 random factor products.
- A/V property: 40 random projects × preview and export, plus hidden lanes; video layer and audio segment boundaries are identical.
- Export compile without manifest entries returns ExportBlocked (tested in test/plan/export).
- **CORE-32** (done): Diff and apply (plan_diff.dart):
- diffPlans is identity-first: a positional pointer check first, falling back to id maps only when ids moved.
- applyPatch is pure, throws PlanOutOfSync when patch.from ≠ rev, and re-sorts layers and audio.
- classifyPatch(from, patch) needs the base plan, which the spec omitted, and implements ARCH §11.2 exactly. seq is counted as structural; it only ever changes together with z/t.

Memo (plan_memo.dart):
- PlanMemo implements ClipLoweringMemo per clip object + ClipLoweringKey.
- Stage memos: PlanTransitionMemo is keyed by the input layer object plus the edit; PlanAudioMemo by the clip object plus the segment context.
- PlanMemo.compile() also adopts the packed, seq'd layers, so unchanged layers stay identical across compiles.

Transients (transients.dart): transientFor compiles a reduced project — the item and its transition neighbours on its lane, other lanes kept empty so z stays exact — and returns only #v/#bd param fields.

Acceptance criteria:
- apply(diff(a,b),a) == b (modulo the informational req): 24 seeds × 20 random commands (move, trim, split, delete, SetVisual, SetAudio, track flags, SetTransition), including a JSON wire round trip, memoized compile == fresh compile, and classification agreement; plus random unrelated pairs.
- Transients contain only the item's layers and no timing keys (wire-checked) and equal the full compile's layers on random projects.
- Classification: 32 vectors in test/fixtures/render_plans/classification.json, matched by the test.
- Benchmark: one-item edit at 2,013 items gives 1 visual memo miss, a param-only patch touching only that item, and median compile+diff 3.2–3.6 ms. That run was on a shared machine with load average 13–25 on 8 cores; profiling (also under load) attributes about 1.3–1.5 ms to the CORE-30 compiler core, about 0.45 ms to transitions, about 0.57 ms to audio and about 0.1 ms to diff. The test asserts ≤ 3 ms × CI factor 3, the same convention as CORE-30's benchmark. Under 3 ms on an idle machine is likely but was not measured.
- **CORE-33** (done): bitrate.dart:
- ExportQuality 0.6/1.0/1.5/2.0.
- Auto table {720: 5/7.5, 1080: 8/12, 1440: 16/24, 2160: 40/60} × 0.6 for HEVC × quality.
- Custom video 2–100 Mbps and audio 96–320 kbps, clamped.
- Size estimate (v+a)·sec/8·1.02.
- V-D9 sources noted in a comment: written from existing knowledge of YouTube's, Instagram's and TikTok's public guidance; the pages were not re-fetched.

export_presets.dart: the ARCH §14.1 table exactly.

export_settings.dart:
- ExportSettings: preset, Custom shortSide/fps (null = Match project)/container/codec/bitrates, quality, burnInSubtitles per track, sideFiles.
- ExportCapabilities mirrors EditorCapabilities: h264/hevc/mov, maxExport long and short side, maxFpsByHeight keyed by short side, maxTextureSize, maxAudioSpeed, holdFrame. Core cannot import the engine API.

compile_export.dart:
- resolveExportSettings(project, settings, capabilities) → ResolvedExport{encode, notices, estimatedBytes}:
  - Size is clamped to the largest fallback short side that fits.
  - fps is halved or lowered to fit maxFpsByHeight.
  - HEVC and MOV fall back with notices.
  - Aspect mismatch gives a notice 'Change project to 9:16' with suggestedAspect; the project is letterboxed, never cropped.
- exportSpriteRequests(...) gives the pre-pass input.
- compileExport(project, settings, manifest, {resolver, capabilities, spriteRequests, rev}) returns ExportReady{plan, resolved, sprites} or ExportBlocked{requirements, missingSprites, emptyTimeline}. It uses originals only, output canvas/fps, gridFps = project rate, and the standard stages with burn-in.

Acceptance criteria:
- Preset table tests for 16:9@30, 9:16@60 and 50 fps.
- Custom short sides; Match project (48 fps exports at 48); the full fps list incl. 48; maxFpsByHeight clamps (48→24, 60→30, 50→25).
- One clamp test per capability flag (h264, hevc, mov, maxExportSize, maxFpsByHeight, maxTextureSize, maxAudioSpeed, holdFrame).
- Estimate within 1% of the formula.
- Aspect mismatch detection.
- ExportBlocked for offline media, pending reverse, pending still, missing sprites, reveal-less typewriter sprite and empty timeline.
- V-D9 reviewed and noted (non-binding).

**Deferred:**
- CORE-32 benchmark: the ≤ 3 ms budget is asserted with the 3× CI factor that CORE-30 also uses. The measured 3.2–3.6 ms median ran on a shared machine (load average 13–25 on 8 cores) and was not re-measured idle. About 1.3–1.5 ms of that is CORE-30's compiler core (resolution, packing, sorting), which CORE-32 does not own.

**Hand-off:** All of the API below is exported from package:danaview_editor_core/plan.dart.

Preview compile (for API-02 PlanSync and INT-02):
- Keep one `PlanMemo` per session.
- Compile with `memo.compile(project, PlanTarget.preview, resolver, {base: CompileOptions(rev/holdFrame), maxAudioSpeed})`. This runs `standardLoweringStages` in order: transitions, then text (a no-op in preview), then audio.
- It also keeps unchanged layers identical across compiles, so `diffPlans` stays cheap. A plain `compilePlan` call without stages produces no transitions and no audio.

Patches:
- `diffPlans(a, b)` produces the patch; `applyPatch(plan, patch)` applies it and throws `PlanOutOfSync`.
- `classifyPatch(fromPlan, patch)` returns `PatchClass.structural` or `PatchClass.paramOnly`. It needs the base plan. `patchIsStructural`, `layerTimingChanged` and `audioStructureChanged` are also public.
- `req` is not part of a patch: `applyPatch` keeps the base plan's req.
- Native classification vectors are in test/fixtures/render_plans/classification.json: `{v, from: plan, cases: [{name, patch, structural}]}`.

Transients: `transientFor(workingProject, itemId, resolver, {options, target})` returns a `PlanTransient?`. It covers `#v` and `#bd` with param fields only, and returns null for text in preview, audio clips and unknown ids.

Mute/solo decision:
- Preview plans keep muted, soloed-out and clip-muted segments with gain [[t0, 0]], so toggling mute is a param-only patch.
- Export plans omit those segments.
- Hidden affects visuals only; hidden lanes' audio still plays, extended exactly as the picture would be.
- `detachedAudio` clips have no segment.

Export (UX-39, ENG-04, INT-02):
- Build `ExportCapabilities` from `EditorCapabilities`: maxExportSize maps to long/short side limits, maxFpsByHeight is keyed by output short side.
- `resolveExportSettings(project, ExportSettings, capabilities:)` returns `ResolvedExport{encode: EncodeSettings, notices: [ExportNotice(code, message, suggestedAspect)], estimatedBytes, output}`. Notice codes: aspectMismatch, resolutionClamped, fpsClamped, hevcUnavailable, movUnavailable, bitrateClamped.
- `exportSpriteRequests(project, settings, capabilities:, metrics:)` gives the pre-pass input.
- `compileExport(project, settings, SpriteManifest, resolver:, capabilities:, spriteRequests:, rev:)` returns either `ExportReady{plan, resolved, sprites}` or `ExportBlocked{requirements, missingSprites (keys), emptyTimeline}`.
- Pass `compileExport` the same request list the pre-pass used if the pre-pass measured with a `TextMetricsProvider`.

Sprite units (normative for API-04):
- `SpriteRequest.scale` and `SpriteFile.sscale` are sprite px per layout (project-canvas) px.
- The plan asset's `sscale` = `file.sscale / exportScale`; layer `base` = `sw/sscale, sh/sscale` in plan px.
- Rasterize with the laid-out block centred (symmetric padding).
- The rasterizer may lower the scale further and report it in `SpriteFile.sscale`.
- A typewriter request (`reveal: true`) needs a file with `reveal: true`; otherwise the export is blocked.
- Key = sha1 of canonical JSON {spec, scale, canvas [w, h], fontsVersion, reveal}; `contentFontsVersion = 1`.
- Sprite asset ids are `sp_<key>`.
- Without metrics, the raster clamp uses `estimateTextBlockSize` (0.62 em per grapheme).

Transition lowering details:
- Dip helper id is `<leftItemId>#tx0` at lane z+5. It is a solid covering the project content rect, with base set explicitly.
- Wipe mask: a rect 4 feathers larger than the content, with only `cx` (horizontal) or `cy` (vertical) animated.
- Defaults: slide and wipe `left`, zoom `zoomIn`.
- Shared helpers: `transitionWindowsOf`, `clipExtentsOf`, `composeChannel`, `applyClipEdit`, `wipeMask`, `easeInOutCubic`, `GainModel`/`LinearGain`/`EqualPowerGain`/`speedGate`, `collectSpriteRequests`, `maxAnimatedScale`, `clampRasterScale`, `spriteKeyOf`, `exportScaleOf`.
- `defaultMaxAudioSpeed = 4`.

**Verification:** cd packages/danaview_editor_core && dart analyze → "No issues found!"
dart test test/plan/compile_lowering test/plan/diff test/plan/export → "+194: All tests passed!"
dart test test/plan test/purity_test.dart → "+746: All tests passed!" (CORE-29/30 plan tests unaffected; barrels and OWNER headers ok)
dart test test/plan/diff/incremental_benchmark_test.dart → "median 3.20 ms" / "3.57 ms" at 2013 items, on a shared machine with load average 13–25 on 8 cores; asserted ≤ 3 ms × CI factor 3.
Goldens were regenerated once with DANAVIEW_UPDATE_GOLDENS=1 and are compared byte-for-byte on every normal run.
No native build was needed (pure Dart). No barrel or pubspec edits were needed: plan.dart already exports every file.

### API-02, API-04

- **API-02** (done): Implemented in plan_transport.dart and plan_sync.dart; the previous attempt had left only API-01's placeholders.

PlanTransport encodes plans, patches and transients as UTF-8 JSON through core PlanJson. Plans and patches with more than 256 objects are encoded in Isolate.run; transients are encoded inline. It also has ack helpers: ackOf for the PlanAckMsg fields, decodeAck and decodeAckJson (both throw FormatException), and decode helpers for fakes.

PlanSync(session, compile:, transientInterval = 1/60 s, clock:):
- At most one compile runs at a time and the latest project wins. A compiled plan that was superseded while compiling is discarded, but never twice in a row.
- Each plan is diffed against the last acknowledged plan and sent with applyPatch. Empty diffs are not sent.
- planOutOfSync leads to one setPlan(full). If that fails too, or on any other failure, status becomes failed, `events` emits PreviewFailedEvent and the next schedule() or resync() sends the full plan.
- A plan whose rev is not above every revision already sent is re-stamped maxSentRev+1, so revisions never go back.
- Transients are coalesced to at most one flush per interval, newest per item. They are dropped while that item's structural patch is in flight.
- dropTransientsFor(item) discards the pending transient at once and calls clearTransient after the commit's plan is applied.
- Also exposed: currentStatus, lastAck, appliedPlan, lastFailure, stats, flush() and dispose().

PreviewPlanCompiler runs a cold compile of a project with more than 300 items in Isolate.run, and uses PlanMemo.compile otherwise.

All ACs are tested with FakeEditorEngine in test/plan_sync/ (20 PlanSync tests and 6 transport tests):
- coalescing: 100 schedules cost 1 compile when synchronous and 2 when a compile is in flight;
- the out-of-sync retry path;
- a double failure surfacing PreviewFailed, plus recovery;
- transient rate limiting at 120 Hz input;
- revisions increasing strictly across EditSession apply/undo/redo, and re-stamping of a stale project.
- **API-04** (done): Implemented in lib/src/render_prep/; the previous attempt had left only placeholders.

TextLayoutEngine:
- Lays out a TextLayoutSpec or its JSON with ui.Paragraph, at the tight longest-line width.
- Block = text plus box padding. Raster extent = block plus a symmetric margin for the outline, the shadow (offset + 3 sigma) and 0.1 em of overhang.
- Fonts come from an injected FontResolver (default: everything is Figtree) plus optional fallbackFamilies.
- Glyph boxes per grapheme cluster, line metrics and reveal strips are computed lazily. An LRU cache holds 512 layouts.
- paint(canvas, origin, revealCount:, opacity:) is for the UX-19 overlay, and it also implements TextMetricsProvider.

TextSpriteRasterizer:
- prepare() lays out and records the picture on the UI isolate; renderRgba() returns premultiplied RGBA.
- The scale is clamped to min(maxTextureSize, 2 x output long side) and the f32 value actually used is reported. The sprite is centred on the block.
- glyphMapOf builds the u16 glyph map from the reveal strips.

VspriteCodec: VSPR v1 per ARCH §10.3, encoded and decoded in Isolate.run. The decoder is strict: both Adler-32 trailers are checked and no trailing bytes are allowed.

SpritePrepass.run(requests, cacheDir:, onProgress:, isCancelled:):
- Reuses existing files by content key.
- UI slices stay within 4 ms: a slice stops before the next sprite would exceed the budget, predicted from the costliest of the last 8 sprites.
- Glyph maps and encoding run in one isolate per batch; files are written atomically as tmp + rename through core StoreFs.
- Returns a SpriteManifest.

Fixtures (test_fixtures/sprites, for IOS-09/AND-09): 2 synthetic and 2 text .vsprite files, plus sprites.json (sizes, Adler-32 checksums, sample pixels) and a README.

ACs:
- Glyph boxes equal a hand-built ui.Paragraph: met.
- RTL, CJK, Arabic, Hebrew and Devanagari render through the fallback font, proved by advances equal to the fallback font's own: met.
- Emoji clusters are laid out and get correct reveal ids: met. Colour emoji ink is deferred to device (QA-03), because flutter_tester has no emoji font.
- V-A11 is documented in the text_layout_engine.dart header. Figtree has 391 code points: Latin only, with no Greek, Cyrillic, Vietnamese, RTL scripts, Indic scripts, CJK or emoji.
- Reveal map correct for grapheme clusters: met (ZWJ, flags, combining marks, LTR and RTL order).
- Codec round trip: met.
- Per-slice UI time <= 4 ms: met deterministically with a fake clock. On the loaded host (load average 12-16) the median slice is about 1.3-1.5 ms.
- V-D7 host benchmark: 1,001 sprites in 1.7-3.4 s, under the 8 s budget. The mid-device measurement is QA-04's.

**Deferred:**
- API-04: colour-emoji ink in sprites is verified on device (QA-03 render goldens), because flutter_tester has no emoji font. Emoji layout, clustering and reveal ids are tested here.
- API-04 V-D7: the time on a mid-tier device (1,000 cues in 8 s or less; ARCH's 3,000 cues in 15 s or less) is QA-04's measurement. The host benchmark is done: 1,001 sprites in 1.7-3.4 s.
- API-04: wall-clock per-slice time on devices in release builds is QA-04's measurement. The ≤ 4 ms rule is enforced by construction and tested with a deterministic clock. On the loaded debug-JIT host, single slices occasionally exceed 4 ms when the OS preempts the test process.
- Cross-ticket (API-01, not mine to edit): in test/contract/fake_engine_behavior_test.dart, the test 'placeholders throw UnimplementedError until their owners land (D-33)' must drop its PlanTransport.encodeTransient, TextLayoutEngine(...).layout(const {}) and VspriteCodec.decode(Uint8List(0)) lines. Its README line listing plan_sync/plan_transport/render_prep as placeholders is also stale.

**Hand-off:** API-02, for UX-08, ENG-02 and INT-02. Everything is exported from package:danaview_editor_engine_api.

Setup:
- Create `PlanSync(previewSession, compile: PreviewPlanCompiler(resolver: (project) => resolver).call)`, one per session.
- On every commit call `schedule(project)`. On a gesture commit also call `dropTransientsFor(itemId)`.
- During gestures call `sendTransient(itemId, transientFor(...))`. It is coalesced to 60 Hz and dropped while that item's structural patch is in flight.

Status and events:
- `status` and `currentStatus` take the values idle, compiling, applying and failed.
- `events` emits PreviewFailedEvent(EngineFailure) after the full-plan retry also fails. UX shows "Restart preview", which calls `resync()`.
- Also available: `lastAck` (rev, structural, applyMs) for QA-04 timing, `stats` (compiles, patches, fullPlans, transients…), `flush()` and `dispose()`. dispose() does not dispose the session.

Behaviour:
- Plans whose rev is not above every revision already sent are re-stamped `maxSentRev + 1`.
- Empty diffs are not sent.

PlanTransport (ENG-02):
- `encodePlan` and `encodePatch` return Future<Uint8List>; above 256 objects they run in Isolate.run.
- `encodeTransient` is synchronous.
- `ackOf(rev:, structural:, applyMs:)` maps PlanAckMsg.
- `decodeAck` / `decodeAckJson` throw FormatException on malformed input.

API-04, for UX-19, UX-30, UX-39, ENG-04, IOS-09 and AND-09.

TextLayoutEngine({FontResolver? fontResolver, fallbackFamilies, cacheSize: 512}):
- `layoutSpec(TextLayoutSpec)` or `layout(json)` returns a TextBlockLayout with: paragraph, strokeParagraph, textSize, padding, margin, blockSize, rasterSize, textOffset, glyphs (GlyphBox per grapheme cluster, block coordinates), lines, revealStrips, `glyphAt(point)`, `revealClip(n)` and `paint(canvas, blockTopLeft, {revealCount, opacity})`.
- The block centre is the item position (or the cue's cueCenter).
- It implements TextMetricsProvider (measure() returns blockSize); pass it as `metrics:` to exportSpriteRequests.
- `textLayoutSpecFromJson` decodes SpriteRequest.layoutSpec.
- `figtreeOnlyResolver` is the default; UX-30's FontCatalog should return a family for each id and Figtree for unknown ids.

Typewriter semantics, which the UX-19 preview must mirror with `paint(revealCount: revealCount)`:
- Every pixel belongs to the reveal strip of its nearest cluster on its line, so the box, outline and shadow appear with their nearest glyph and the box grows with the typed text.
- Transparent pixels are 0xFFFF.

TextSpriteRasterizer({engine}):
- `prepare(request, maxTextureSize:)` returns a PreparedSprite (width, height, scale, strips); then `renderRgba()`.
- `rasterize(request)` returns RasterizedSprite (rgba premultiplied, glyphs when request.reveal); `toVsprite()` converts it.
- The scale is clamped to min(maxTextureSize, 2 x max(request.canvasWidth, canvasHeight)). The reported sscale is the f32 value, so the manifest is identical on reuse.

SpritePrepass({rasterizer, maxTextureSize, sliceBudget: 4 ms, maxBatch: 8, yieldToUi, clockMicros, fs: LocalStoreFs()}):
- Call `run(requests, cacheDir: SpritePrepass.spritesDirOf(config.cacheRoot), onProgress:, isCancelled:)`. It returns a SpriteManifest and throws SpritePrepassCancelled when cancelled.
- Pass the same requests to compileExport(spriteRequests:).
- Paths are POSIX ('$dir/$key.vsprite'); URIs are Uri.file.

VspriteCodec:
- `encode` / `decode` run in an isolate; `encodeSync`, `decodeSync` and `readHeader` (20-byte header) are also available.
- Classes: VspriteImage {width, height, scale, rgba, glyphs?}, VspriteHeader.
- Native decoders must inflate the first zlib stream to its end and start the second at the next byte; there are no length fields.
- Fixtures and expected values are in test_fixtures/sprites/sprites.json: Adler-32 of the inflated RGBA and of the little-endian u16 glyph bytes, plus sample pixels.

Policy found:
- API-01's api_surface_test bans dart:io anywhere in engine_api/lib, and requires an ARCH/D-xx reference in the dartdoc of every public type.
- So zlib is a pure-Dart encoder and decoder (zlib_stream.dart exports deflateZlib, inflateZlibStream and adler32): LZ77 with pixel and row predictors plus fixed Huffman, standard zlib output.
- File I/O goes through danaview_editor_core/store.dart StoreFs.

V-A11: Figtree covers Latin only (391 code points; no Greek, Cyrillic or Vietnamese). Other scripts use Flutter's system fallback, identically in the preview and in sprites. UX-30 may prefer Inter for Vietnamese.

**Verification:** Analyze, in packages/danaview_editor_engine_api:
- `flutter analyze --fatal-infos --fatal-warnings`: "No issues found!"
- Downstream `packages/danaview_editor_engine` (`flutter analyze lib`): "No issues found!"
- Root `flutter test test/architecture`: "+39: All tests passed!"

Tests:
- `flutter test test/plan_sync test/render_prep`: "+73 ~1: All tests passed!". The one skip is the fixture regenerator, which runs only with DANAVIEW_REGEN_SPRITE_FIXTURES=1; it was run once to create the fixtures.
- Full package `flutter test`: "+410 ~1 -1: Some tests failed". The single failure is API-01's own `test/contract/fake_engine_behavior_test.dart` test "placeholders throw UnimplementedError until their owners land (D-33)". It expects PlanTransport, TextLayoutEngine and VspriteCodec to still throw UnimplementedError, so it fails by design now that they are implemented. The file is not mine to edit (see handoff).
- `api_surface_test` passes, including its no-dart:io rule and its ARCH-link dartdoc rule.

Benchmark printed: "V-D7 host: 1001 sprites in 1673-3439 ms". Host UI slice medians were about 1.2-1.5 ms under load average 12-16.

### AI-09

- **AI-09** (done): Model store and resumable verified downloader implemented and tested against a loopback fake HTTP server only (no internet, no models downloaded). Real downloads of tiny and VAD on each platform are deferred: needs runtime user consent/device. The iOS excludeFromBackup read-back and a real iOS background-task expiry are deferred: no device available (the channel is AI-06's, here it is faked).

**Deferred:**
- Real downloads of tiny and VAD verified once on each platform (recorded in PR): deferred, needs runtime user consent/device; no real model is downloaded in this lane.
- excludeFromBackup read-back via URLResourceValues and real iOS background-task expiry: deferred, no device available; AI-06 owns the channel and the downloader only calls it (faked in tests).
- Wiring a wakelock_plus adapter (danaview_platform) into DownloadWakelock, passing the app version into ModelDownloaderConfig.appVersion, passing the job guard into FileSpeechModelStore.isModelInUse, and the <support> directory: INT-04 / AI-13 wiring; this package stays pure Dart (ARCH 4.2 rule 6).
- Android manifest backup-rule XML lines for danaview/speech/models/, jobs/ and work/ (ai.md 5.4): app-level files co-owned with Persistence, not owned by AI-09.

**Hand-off:** Public API (exported through lib/danaview_transcription.dart via the models_store sub-barrel). SpeechModelStore (interface): inventory(), watch(), installed(id), filesFor(id) -> SpeechModelFiles{model, modelPath, vadPath}, statusOf(id) -> SpeechModelStatus (Missing, Downloading with the phase incl. verifying, Ready, Corrupt), download(UserConsent) -> ModelDownload, activeDownload, delete(id), deleteAll(), markCorrupt(id) (call when a native load fails), markUsed(id), measure() -> FolderUsage{bytes, files, partialBytes}. FileSpeechModelStore is the implementation: constructor takes supportDirectory (files go under <support>/danaview/speech/models/), platform (ModelStorePlatform; use WhisperDeviceModelStorePlatform([WhisperDeviceChannel]) for the AI-06 channel), wakelock (DownloadWakelock; default NoDownloadWakelock), isModelInUse (delete throws StateError('In use by auto captions') while true), config (ModelDownloaderConfig: appVersion for 'User-Agent: Danaview/<version>', timeouts, retryBackoff, sidecarEveryBytes, and test seams urlFor, httpClientFactory, isAllowedRedirect, delay, random), plus test catalog overrides models and vadSpec. ModelDownload: progress (broadcast, at most 4 Hz plus phase changes), done (Future<InstalledSpeechModel>, throws ModelDownloadFailure with kinds offline, timeout, server, secureConnection, interrupted, diskFull, checksumMismatch, sizeMismatch, cancelled, consentMismatch), cancel({keepPartial = true}). Decisions: the consent is compared field by field against the store's catalog (equals ConsentDisclosure.matchesCatalog with the production catalog); a mismatch returns FailedModelDownload with consentMismatch before any request or directory creation. One download at a time: same model returns the running task, another model throws StateError. 'Ready' requires the model and the VAD file (includesVad: false installs the model only and status stays Missing until the VAD is fetched). Redirect: expects 302 or 307, x-linked-size and x-linked-etag (quotes and W/ stripped) must equal the catalog, missing headers fail closed (sizeMismatch / checksumMismatch), Location must be https on hf.co or *.hf.co (SpeechModelCatalog.cdnHost) unless isAllowedRedirect is overridden. Retry budget (3, backoff 2/4/8 s + up to 25% jitter, re-resolving the redirect each time) resets whenever an attempt made progress; offline, TLS, 4xx and size/etag mismatches are never retried. A partial resumes only if its .part.json sidecar matches url, bytes, sha256 and SpeechModelCatalog.revision and the partial is not shorter than the sidecar says; otherwise it is deleted. A complete partial skips the network and goes to verification. Verification: SHA-256 via Isolate.run (sha256OfFile), ggml magic bytes 6c 6d 67 67 (GGML_FILE_MAGIC 0x67676d6c little-endian, same for whisper and VAD in v1.9.4); failure deletes the partial, flags the id corrupt (status Corrupt until re-downloaded or deleted) and fails with checksumMismatch. After rename: platform.excludeFromBackup(file), atomic manifest.json update (schema 1 {installed:[{id,file,sha256,bytes,installedAt,verifiedAt,lastUsedAt}]}). First use creates the folder (excluded from backup), sweeps partials older than 7 days, and rebuilds a lost manifest by hashing size-matching files (tampered files are deleted). iOS lifecycle: AppStateChanged(background) begins a background task (beginBackgroundTask('danaview.speech.model.download')), foreground ends it, BackgroundTaskExpiring stops the download with the partial kept and fails with interrupted. Wakelock acquired at start and released in every exit path before done completes. installFromFile(spec, path) exists on FileSpeechModelStore only (@visibleForTesting, throws UnsupportedError when dart.vm.product is true, verifies size, sha256 and magic). Test helpers live in packages/danaview_transcription/test/models_store/support/ (FakeModelServer with scriptable Cdn behaviours, Harness, consentFor/specFor/modelBytes); AI-13 can reuse the same pattern. Pubspec was not changed (crypto, path, meta, danaview_data, danaview_whisper were already declared)."

**Verification:** cd packages/danaview_transcription: `flutter analyze lib/src/models_store test/models_store` -> No issues found. `flutter test test/models_store test/contracts` -> 123 tests, All tests passed (models_store suite run 3 times in a row, stable, about 2 s). Full-package `flutter test` -> 229 tests, All tests passed. Full-package `flutter analyze` reports 3 infos in other tickets' files (test/segmentation/scratch_test.dart avoid_print x2, test/transcript/transcript_checkpoints_test.dart prefer_interpolation), none in AI-09 files. The dependency_rules_test still passes: lib imports only danaview_data, danaview_whisper and danaview_editor_core, no flutter UI.

### AI-10, AI-11, AI-12

- **AI-10** (done): Implementation was already complete from an earlier attempt: transcript models and schema 1, TranscriptKey, atomic cache with 64 MiB LRU, superset reuse and corrupt-file regeneration, per-chunk checkpoints with replay, normalizer with hallucination phrases, job records with 7-day expiry. This round verified it and fixed one analyzer info in test/transcript/transcript_checkpoints_test.dart. Every AC is covered by existing tests, which pass.
- **AI-11** (done): Implementation was already complete: the DP segmenter, presets, script profiles, CPS limits, kinsoku, cut-crossing penalty, frame-grid snapping and SubtitleCueDraft output. Goldens exist for en, es, de, ja, zh, ko, ar, hi and th, plus property tests, the 10k-word performance test (150 ms) and 9:16 defaults. This round replaced raw bidi code points in a test regex with \u escapes to clear 4 analyzer warnings in test/segmentation/caption_segmenter_test.dart. All tests pass.
- **AI-12** (done): lib/src/timeline/ (planner, units, WordMapper, DomainTimelineView) was already implemented but had no tests, so this round added test/timeline/. Planner tests (30) cover exclusions (muted, zero volume, muted and soloed-out tracks, reversed and noAudio reported, stills and images, music default unchecked, detached audio), the 5 s inclusive merge gap, 0.5 s padding, scope variants, range cutting through speed and detection-unit choice. Word mapper tests cover constant 2x and 0.5x, ramps (equal to ClipTimeMap.timelineTimeOf and its inverse), trims and the 50% rule, splits (straddling word assigned once, rearranged halves, per-half speeds), edits during a job (trim, move, speed change, deleted, muted, reversed, re-sourced), windows and cut-point filtering. Split-cut tests show a sentence across the cut stays one cue and a long passage breaks at the cut only because of the cut list. Priority tests cover voice > main video > other video > other audio > music, track-rank and id ties, the 0.3 s window edge, abutting clips not shadowing, and input-order independence. DomainTimelineView tests cover volume, solo, cut points, audioInfo, subtitle tracks and resolveMedia.

**Hand-off:** For AI-13: the transcript API lives under lib/src/transcript (TranscriptKey.compute, the cache, checkpoint store, normalizer and job records). The timeline pieces are `TranscriptionPlanner().plan(view, scope)`, which returns a TranscriptionPlan of units plus SkippedClip reasons `muted`, `reversed` and `noAudio`. `UnitWords.fromTranscript(unit, transcript)` and `WordMapper().map(timeline: freshView, transcripts, window)` return MappedWords with the merged words, cutPoints, droppedInvisible, droppedOverlap and missingClips. Always pass a fresh `DomainTimelineView(project)` to the mapper, never the one used for planning. For the segmenter, call `DpCaptionSegmenter().segment(words, SegmentationContext.forProject(languageCode, settings, frameRate, cutPoints: mapped.cutPoints, canvasSize))`. TimedWord.clip is itself a cut signal in the segmenter (a clip change counts like a cut point), so words from different clips avoid straddling even without cutPoints. The overlap merge drops lower-priority words within 0.3 s of a kept word only inside the intersection of the two clips' timeline ranges. A word cut by a split is assigned to the clip that shows most of it, and ties go to the earlier clip. Planner decisions: music-role audio tracks are excluded only for TimelineScope with tracks == null, while ClipScope and ItemsScope include music clips; freeze frames and images are skipped silently. Test fixtures are in packages/danaview_transcription/test/timeline/timeline_fixtures.dart (project, clip, lane, asset, plan).

**Verification:** In packages/danaview_transcription: `flutter analyze` reports "No issues found!". `flutter test` (whole package, including models_store, contracts, transcript, segmentation and timeline) ends with "+392: All tests passed!". `flutter test test/timeline` alone ended with "+66: All tests passed!" before the last test fix, and the final full run includes them. No native build is needed for these tickets.
