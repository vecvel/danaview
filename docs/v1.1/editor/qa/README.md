<!-- OWNER: QA-00 -->

# On-device E2E suite (integration_test/editor)

This is the app-level suite from ARCH §21.2. It runs against the real app wiring and the production native engine. There is one copy, and it runs on both platforms:

- **QA-01** certifies it on the iOS Simulator.
- **QA-02** certifies it on the Android Emulator (Windows lane).

Nothing in it downloads anything. The media comes from the ENG-05 fixtures, and the speech model is staged ahead of time and installed through `ModelStore.installFromFile`.

## Layout

| Path | What it is |
|---|---|
| `integration_test/editor/support/e2e_app.dart` | Boots the app with the same wiring as `lib/main.dart` (`EditorBootstrap.createRuntime`, `editorAppOverrides`, Auto captions), once per test process. It also provides the waits, 0.1 s taps, host screenshots and model staging. |
| `support/e2e_engine.dart` | Wraps `MobileEditorEngine` with two seams. The **system pickers** answer with sandbox files queued by the scenario, using the Files origin. The **export handoff** keeps a copy of every delivered file, and can also call the real Photos/Gallery add. Everything else is the production engine. |
| `support/e2e_editor.dart` | The editor driver. It creates projects through Projects › New project › Files and attaches to `EditorScreen`. Actions run through `EditorActionRegistry`, the same path tool tiles, menus and shortcuts take. It also covers keyboard and mouse events, timeline drags through the canvas' drag delegate (with snapping), exact seeks on engine acks, and frame barcodes read from `debugCaptureFrame` with the ENG-05 reader. |
| `support/e2e_export.dart` | Runs an export through the export sheet and checks the result with `MediaInspector` (conformance). It also pulls frames of the exported file with the engine's freeze job (PNG), and reads its audio through the speech-audio job (WAV). |
| `support/e2e_media.dart` | Copies the fixtures into `<Documents>/e2e_media` in the app sandbox. Because they live there, imports are `documentsReference`s and can go missing. It also writes the `.cube` and `.srt` files the suite generates. |
| `support/e2e_handshake.dart` | The app side of the file handshake with the host. |
| `support/e2e_config.dart` | The `--dart-define`s. |
| `tool/e2e_host.sh` | The host driver. It stages files, runs files and their phases, serves the handshake and collects evidence. |
| `sNN_*_test.dart` | The 18 scenarios. |
| `x_*_test.dart` | The platform extras. |

## Scenarios

| # | File | What it drives and checks |
|---|---|---|
| 1 | `s01_home_to_projects_test.dart` | Home edit button sits left of the gear (same row) and opens Projects |
| 2 | `s02_player_to_editor_test.dart` | Player › exact seek to 0:05:10 › Edit opens the editor with the playhead on frame 160 and barcode 160 |
| 3 | `s03_project_lifecycle_test.dart` | Create (New project sheet), rename, duplicate and delete (menu, confirm, undo-bar commit) |
| 4 | `s04_basic_edits_test.dart` | Split (S), trim-handle drag, move with snap onto a cut, ripple delete, undo/redo, copy/paste, duplicate; barcodes after the edits |
| 5 | `s05_text_and_subtitles_test.dart` | Text with a typewriter animation; caption add/split/merge; SRT import (picker) and export (Save to Files) round trip |
| 6 | `s06_speed_effects_test.dart` | 2× (barcode 60 at frame 30), freeze (sheet, still rendered, barcode), ramp, reverse (rendition, barcode ≥ 236), cross dissolve, LUT import (Filters › Import .cube), chroma, mask, keyframes |
| 7 | `s07_export_verified_test.dart` | UI-built project exported at 720p H.264 MP4 (conformance, AAC). Burned vs not-burned subtitle areas, typewriter glyphs growing, blending only inside `[cut − d/2, cut + d/2)`, SRT/VTT side files parsing back. HEVC/MOV when the capabilities allow it. |
| 8 | `s08_auto_captions_test.dart` | Auto captions with the tiny model on `speech_10s.m4a`: at least 1 cue, generated origin and model id, the SRT parses back, one undo removes all |
| 9 | `s09_recovery_after_kill_test.dart` | Phase `edit`: edit, autosave journal, host kills the app. Phase `recover`: the Projects recovery banner restores the edit. |
| 10 | `s10_missing_media_relink_test.dart` | Three referenced files moved. Banner › Missing media › Locate one › Relink several › Relink, then a barcode check. |
| 11 | `s11_background_foreground_test.dart` | During playback the host backgrounds the app for 3 s. One second after the return: not black, barcode readable. |
| 12 | `s12_keyboard_pointer_test.dart` | Space/K, ←/→ (barcode), Shift+←/→, S, Delete/Backspace, ⌘Z/⌘⇧Z, ⌘S in a text field (saves, types nothing), ⌘C/⌘V/⌘D, Space after a tool tile, ⌘+wheel zoom / Shift+wheel scroll / plain wheel, right-click menu, marquee |
| 13 | `s13_voiceover_test.dart` | Host grants the mic. The panel records 3 s; the WAV lands on a voice lane at playhead + latency and is audible in the export (RMS > −60 dBFS). |
| 14 | `s14_pip_overlay_test.dart` | Overlay panel › Add video, moved/scaled/faded, then exported. The main and overlay barcodes read in place; the faded start is not a clean barcode. |
| 15 | `s15_extract_audio_music_test.dart` | Extract audio (linked "original" lane), Add music (music lane), 1 s fade-in. The export's first 100 ms is quieter. |
| 16 | `s16_marker_snap_test.dart` | M adds a marker; a dragged item snaps to it |
| 17 | `s17_cut_paste_test.dart` | ⌘X ripples the cut, ⌘V pastes the same source range (barcodes) |
| 18 | `s18_close_reopen_test.dart` | Close and reopen: timeline JSON (codec body without meta/view), playhead and zoom are equal, and the barcode is at the playhead |
| iOS | `x_ios_background_export_test.dart` | Backgrounding mid-export pauses, then resumes and conforms. On a simulator a run that never pauses is reported, not failed. |
| Android | `x_android_export_background_test.dart` | Phases `fgs`/`fgs-check` (FGS with the activity destroyed, finished card, Gallery), `cancel` (notification Cancel), `swipe`/`swipe-check` (swiped from recents), `death`/`death-check` (one `interrupted` record) |
| API 28 | `x_android_api28_test.dart` | Home button shows, Projects shows `android_too_old`, player Edit explains (the stock `main()`, since the editor can't be wired there) |

### How the UI is driven

- **System UI.** The OS pickers, the share and Files sheets, and the Photos add prompt can't be driven from Flutter, so the picker and the handoff are seams in the engine wrapper. Everything above them is real: the sheets, import jobs, pool policy and files.
- **Tool actions** run through the action registry, exactly as their tiles and shortcuts do. The sheets and panels those actions open are answered by tapping their keyed buttons.
- **Property panels** (speed values, chroma, mask, keyframe values, transform) are exercised as the same core command the panel issues, through `EditorController.apply`. Their widgets are covered by the UX tickets' widget tests and by QA-08/QA-09.
- **Timeline drags** go through `TimelineInteractionController`, the canvas' drag delegate. That way snapping, transactions and history are the real ones; only gesture recognition is skipped.
- **Keyboard and pointer events** come from `WidgetTester` (`sendKeyEvent`, mouse pointer events). They pass through the app's real `Shortcuts`, focus and listeners. A physical hardware keyboard on the iPad simulator and the tablet emulator is a manual step in QA-01/QA-02 (see the checklist).

### Waiting rules

- Every wait polls a condition with a deadline: an engine ack, a controller state, a file, a handshake ack. No step sleeps for a fixed time to "let things settle".
- The only timed waits are the scenario's own measurements: 3 s of recording, and "1 s after foreground".
- Taps are pointer down, 100 ms, pointer up. The iOS Simulator ignores instant taps.
- Screenshots are taken by the host after the UI settled, and never while a tap is in flight.

## Running

Prerequisites:

- A booted iOS 26 simulator (QA-01: iPhone 17 Pro, and iPad Pro with a hardware keyboard for scenario 12) or an Android emulator (QA-02: API 35 x86_64; API 29, 34 and 28 for the gates).
- The whisper xcframework built for iOS (QA-01's `e2e_ios.sh`).
- For scenario 8, `ggml-tiny-q5_1.bin` and `ggml-silero-v6.2.0.bin`. These are the catalog's exact files; `installFromFile` verifies size and SHA-256.

```sh
# iOS Simulator (fixtures and models are read in place from the Mac's disk)
integration_test/editor/tool/e2e_host.sh -p ios -d <udid> -m ~/danaview-models run all
integration_test/editor/tool/e2e_host.sh -p ios -d <udid> run s07          # one scenario

# Android Emulator (fixtures and models are pushed to the app's external files folder)
integration_test/editor/tool/e2e_host.sh -p android -d emulator-5554 stage
integration_test/editor/tool/e2e_host.sh -p android -d emulator-5554 stage-models ~/danaview-models
integration_test/editor/tool/e2e_host.sh -p android -d emulator-5554 run all
```

`run` passes these dart-defines:

- `DANAVIEW_EDITOR=true`
- `DANAVIEW_AUTO_CAPTIONS=true`
- `DV_E2E_HOST=true`
- `DV_E2E_PHASE=<phase>`
- On iOS, also `DV_E2E_FIXTURES` and `DV_E2E_MODELS`

It runs the phases of `s09` and the Android extras in order. A phase that ends the app (kill, swipe, destroy) counts as passed when the host carried the action out.

You can also call `flutter test integration_test/editor/<file> -d <device> --dart-define=…` directly. Without `DV_E2E_HOST` the host-dependent steps are skipped with a reason: scenarios 9, 11 and 13, the platform extras, and screenshots.

Evidence lands in `build/e2e/<platform>/<device>/`:

- `logs/`: one log per file/phase, plus the host's action log.
- `screens/`: host screenshots named after the step.
- `files/`: exported videos, subtitle side files and phase state, copied from `<app>/e2e_out`.
- `DV_E2E_*` lines in the logs: measured values (levels, encoder, cue texts, HEVC availability).

### The handshake

Both sides write files into `<app shared dir>/e2e_handshake/`. The shared dir is iOS `Documents` and Android `Android/data/com.vecvel.danaview/files`, which the host reaches without root. Every file is written as `.tmp`, then renamed.

The app writes `req-<seq>-<action>.json`. The host carries the action out, writes `ack-<seq>-<action>.json`, and renames the request to `done-…`.

| Action | Effect |
|---|---|
| `background {seconds}` | Background, wait, foreground, then ack |
| `kill` | Kill the process; no ack |
| `grantMic` | Grant the microphone permission |
| `screenshot {name}` | Host screenshot |
| `swipeFromRecents` | Android: remove the app from recents; no ack |
| `destroyActivity` | Android: destroy the activity, process kept; no ack |
| `tapNotificationCancel` | Android: press Cancel in the export notification |
| `foreground`, `relaunch` | Bring the app back |

## Manual checklist (recorded with screenshots in the QA-01 / QA-02 reports)

1. **Drop from Files into the editor** (iPad simulator: Split View with Files; tablet emulator: drag from the Files app). The clip lands at the drop point on the lane under the pointer, and the import progress shows.
2. **Drop from Photos** (iPad simulator: Photos in Split View). Same result, and the copy shows under `work/drops/`.
3. **Physical hardware keyboard** (iPad simulator with "Connect Hardware Keyboard"; tablet emulator with the host keyboard): repeat scenario 12's keys by hand. Also check the shortcuts sheet (⌘/), which shows every row with its key.
4. **Mouse/trackpad on iPad** (pointer support) and on the tablet emulator: the hover pill, the right-click menu, and marquee with the real pointer.

## Simulator and emulator realities (reported, not failed)

- There is no hardware HEVC encoder on simulators, and H.264 encoding is software. The HEVC/MOV branch of scenario 7 prints `DV_E2E_REPORT … reported, not failed` when the capabilities don't offer it.
- Performance numbers are meaningless here. QA-04 measures on devices.
- The simulator keeps the encoder in the background, so the iOS background extra may finish without ever pausing. That outcome is reported; IOS-01/IOS-13 verify the pause on real iPhones.
- Scenario 13 records the Mac's input device on the simulator and the virtual microphone on the emulator. A host with no microphone input records silence, which fails the audibility check. QA-01/QA-02 record the input device they used.

## Status (QA-00)

- The suite compiles against the real app: `flutter analyze integration_test/editor` is clean, and every test file builds in one Flutter test build.
- The required first passes on one simulator and one emulator are QA-01's and QA-02's runs. Defects they find are filed as FIX tickets against the owning ticket's files.
