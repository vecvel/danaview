<!-- OWNER: QA-01 -->

# QA-01: E2E suite on the iOS Simulator

This report covers QA-00's app-level suite (`integration_test/editor`, ARCH §21.2) run on the iOS Simulator with the release dart-defines `DANAVIEW_EDITOR=true` and `DANAVIEW_AUTO_CAPTIONS=true` (BUILD_PLAN QA-01).

**Status: the automated suite is certified on the simulator (re-run 4, 2026-10-21 15:45 to 17:07); QA-01 stays open (in progress) until the manual steps below are recorded with screenshots.** In one full batch on the iPhone 16 (iOS 26.5), every scenario s01 to s18 passes, and so do both iOS-relevant extras. That includes s07, whose two back-to-back exports both complete inside the batch, so FIX-IOS-12-1 is confirmed fixed. s13 also passes inside the batch. s12 passes on the iPad Pro 13-inch (M5), and the iOS 18.2 lane passes 3 of 3. The run is on the code after D7 (QA-05 §2 green) and the round 7 Dart fixes (c336899), with the repo at its new path `/Users/besaoct/Desktop/vecvel/vecvel-cross-platform/danaview`.

Still open, none of them automated (these are simulator steps, so they are not covered by "deferred: no device available"):

- The manual iPad drops from Files and Photos (checklist steps 1 and 2) need a person at the Simulator and must be recorded with screenshots (BUILD_PLAN QA-01). The panel's injected touches do not start the system dock drag, so the harness cannot open Split View. See the manual checklist below.
- V-U5 with a physical keyboard (step 3) needs a person. V-U5 is certified at simulator level (s12 on the iPad).
- The pointer hover pill (step 4) is pending and needs a person; the right-click menu and marquee pass in s12.
- The lab smoke on the iPhone 7 and iPhone 8: deferred, no device available.

## How to run

```sh
scripts/ci/editor/e2e_ios.sh                          # lanes iphone, ipad, legacy, lab
DV_E2E_IPHONE="iPhone 16" scripts/ci/editor/e2e_ios.sh iphone legacy
scripts/ci/editor/e2e_ios.sh --target s08 iphone      # one scenario
scripts/ci/editor/e2e_ios.sh --dry-run                # devices and commands only
```

The script runs these steps:

1. Builds `WhisperCore.xcframework` when it is missing or stale (AI-05 script, `--if-missing`). It falls back to the Android SDK's CMake 3.22 with `DV_ALLOW_OLD_CMAKE=1` when no newer CMake is on the PATH.
2. Runs `pod install`, so Swift files newly added to a plugin pod are in `Pods.xcodeproj`.
3. For each lane, finds the simulator by name and runtime and boots it.
4. Stages the fixtures and the models. Both are read in place from the Mac's disk and never copied into the repo. Models come from `DV_E2E_MODELS`, default `~/danaview-models`.
5. Runs the lane's files through `integration_test/editor/tool/e2e_host.sh`.
6. Runs once more any file whose `flutter test` never attached to the app.
7. Writes `build/e2e/ios/<udid>/summary.txt` and shuts down every simulator it booted.

Evidence goes to `build/e2e/ios/<udid>/`: `logs/`, `screens/`, `files/` (exported MP4/SRT/VTT) and `summary.txt`.

| Lane | Device | Target |
|---|---|---|
| iphone | iPhone 17 Pro by default. This run used the **iPhone 16 on iOS 26.5** (`6663101E-…`), the builder machine's assigned simulator | all files |
| ipad | iPad Pro 13-inch (M5), iOS 26.5 (`2C9213E9-…`) | s12 |
| legacy | iPhone 16, **iOS 18.2** (`7DF46AEE-…`) | s01, s02, s03 |
| lab | iPhone 7 (iOS 15.8), iPhone 8 (iOS 16.7), set with `DV_E2E_LAB_UDIDS` | s01–s04 smoke |

> **ID note (2026-10-21):** the playhead-restore defect is renamed **FIX-UX-14-4** in this report, because FIX-UX-14-1 already names the transport time-readout a11y defect (QA-08) and FIX-UX-14-3 names the stale `transport_bar_test.dart` test (BUILD_STATE, QA-09). Code and test headers (`playhead_reopen_test.dart`) still say FIX-UX-14-1 for this fix.

## Run of 2026-10-21 (re-run 4, after FIX-IOS-12-1, D7 and the round 7 Dart fixes)

Environment: Xcode 26.6 (17F113) and Flutter 3.44.2, debug builds. The Flutter and CocoaPods configs already point at the new repo path (`ios/Flutter/Generated.xcconfig`, no reference to the old `/Users/besaoct/Desktop/danaview` left in `ios/Pods`), so no extra `pub get` or `pod install` was needed beyond the script's own. `WhisperCore.xcframework` was `up-to-date`. The script staged `ggml-tiny-q5_1.bin` and `ggml-silero-v6.2.0.bin` in place from `/Users/besaoct/danaview-models` (owner-approved, SHA-256 verified); nothing was downloaded or copied into the repo. About 26% of system memory was free, and another builder ran `flutter test` on the host at the same time.

Commands:

```sh
DV_E2E_IPHONE="iPhone 16" DV_E2E_MODELS=/Users/besaoct/danaview-models scripts/ci/editor/e2e_ios.sh iphone        # full suite in one batch, 15:45 to 16:57
DV_E2E_IPHONE="iPhone 16" DV_E2E_MODELS=/Users/besaoct/danaview-models scripts/ci/editor/e2e_ios.sh ipad legacy   # 16:57 to 17:07
```

Both runs ended with `done: every lane passed`. No solo re-runs were needed.

### iPhone 16, iOS 26.5 (`6663101E-…`), full batch

| # | Result | Notes |
|---|---|---|
| s01 | pass | |
| s02 | pass (harness retry) | The first attempt never attached (see below). The script's automatic retry inside the same batch passed: `Handoff: at 5333333 us -> frame 160`. |
| s03 | pass (harness retry) | Same attach hiccup as s02; the retry passed. |
| s04, s05 | pass | |
| s06 | pass | speed, ramp, reverse, freeze, cross dissolve, LUT, chroma, mask, keyframes in 36 s |
| s07 | **pass** | **FIX-IOS-12-1 confirmed in the batch.** Both exports completed back to back: `88532.mp4` 1 516 445 B and 1 480 169 B, 8 000 000 µs each, VideoToolbox H.264. Burned cues 341 and 324 changed samples (needs > 180). HEVC/MOV not offered (`hevcEncode false`), reported. |
| s08 | pass | 3 cues from the tiny model ("Welcome to the video editor test, …") |
| s09 | pass | Phase `edit` ended by the host kill as expected; phase `recover` shows the recovery offer and restores the edit. |
| s10, s11 | pass | |
| s12 | pass | marquee `Offset(306.1, 549.0) -> Offset(78.6, 553.0)`, visible 6.49 to 22.78 s, end 14.67 s; wheel zoom 39.3 to 65.4 px/s |
| s13 | pass | Inside the batch this time. Seek 2.0 s, playhead at recording 2.37 s, clip 2.67 s + 3.27 s, window 3.01 s; start latency 300 ms (simulator budget 750 ms, device budget 100 ms, reported); length outside the window 0 µs; voiceover in the export -40.3 dBFS. |
| s14 | pass | |
| s15 | pass | `head -14.6 dBFS, body -9.0 dBFS` |
| s16, s17, s18 | pass | |
| x_ios_background_export | pass | `pausedInBackground observed: false` (simulator reality) |
| x_android_api28 | pass (trivial on iOS) | |
| x_android_export_background | skipped on iOS | |

**Harness hiccup (s02, s03), not a scenario result.** `flutter test` built and launched the app, and the app logged `The Dart VM service is listening on http://127.0.0.1:…` (seen in the simulator's unified log, and the URL answered HTTP 200). But the Flutter tool never connected, so the app stayed paused on a white screen until e2e_host's 900 s watchdog stopped the phase (`No tests ran.`). From s04 on, every file attached normally. e2e_ios.sh's built-in retry for files that never attached re-ran both inside the batch, and both passed. The cost is about 15 min per hiccup. See the follow-up in the defects table.

### iPad Pro 13-inch (M5), iOS 26.5: s12 (`2C9213E9-…`)

**pass.** marquee `Offset(829.8, 933.0) -> Offset(300.5, 937.0)`, wheel zoom 91.4 to 152.3 px/s. V-U5 stays certified at simulator level.

### iPhone 16, iOS 18.2: s01–s03 (`7DF46AEE-…`)

s01, s02 and s03 all pass, all on the first attempt.

### Lab devices

Deferred: no device available (owner default 2026-10-08, ARCH D-43).

### Simulators

The script shut down every simulator it booted. No simulator was left booted.

## Earlier run: 2026-10-16/17 (re-run 3, after FIX-UX-40-1, FIX-UX-14-4, FIX-QA-00-2 and FIX-QA-00-3)

Environment: Xcode 26.6 (17F113) and Flutter 3.44.2, debug builds. `WhisperCore.xcframework` was already `up-to-date`. The models `ggml-tiny-q5_1.bin` and `ggml-silero-v6.2.0.bin` were staged in place from `/Users/besaoct/danaview-models` (owner-approved, SHA-256 verified); nothing was downloaded or copied into the repo. About 40 to 53% of system memory was free.

Commands:

```sh
DV_E2E_IPHONE="iPhone 16" DV_E2E_MODELS=/Users/besaoct/danaview-models scripts/ci/editor/e2e_ios.sh iphone              # full suite, 23:25 to 00:09
DV_E2E_IPHONE="iPhone 16" DV_E2E_MODELS=/Users/besaoct/danaview-models scripts/ci/editor/e2e_ios.sh --target s07 iphone
DV_E2E_IPHONE="iPhone 16" DV_E2E_MODELS=/Users/besaoct/danaview-models scripts/ci/editor/e2e_ios.sh --target s13 iphone
DV_E2E_IPHONE="iPhone 16" DV_E2E_MODELS=/Users/besaoct/danaview-models scripts/ci/editor/e2e_ios.sh ipad legacy lab     # "done: every lane passed"
```

### iPhone 16, iOS 26.5 (`6663101E-…`)

| # | Full run | Solo | Notes |
|---|---|---|---|
| s01–s06 | pass | | s02 now passes in the full run too |
| s07 | **fail (load)** | **pass** | Export A passed. Export B stalled in phase `rendering` (AVFoundation `remakerFamily_renderPipelineRanDry`), and after 565 s with no progress the engine's watchdog failed it with `encodingFailed: export stalled` (`exportFailed.unknown` in Dart). Passes on its solo re-run. Filed as FIX-IOS-12-1. HEVC/MOV not offered (`hevcEncode false`), reported. |
| s08 | pass | | 3 cues from the tiny model |
| s09 | pass | | edit phase killed by the host, recover phase restores the edit |
| s10 | pass | | FIX-UX-40-1 confirmed: the relinked file renders |
| s11 | pass | | |
| s12 | pass | | FIX-QA-00-2 confirmed: marquee `Offset(306.1, 549.0) -> Offset(78.6, 553.0)`, visible 6.49 to 22.78 s, end 14.67 s |
| s13 | **fail (simulator)** | **pass** | Full run: the clip started 1 433 333 µs after the playhead when recording appeared (simulator budget 750 ms). Solo: seek 2.0 s, playhead at recording 2.2 s, clip 2.80 s + 3.67 s, window 3.08 s. This is the virtual mic's start latency under load; the device budget is 100 ms (`DV_E2E_DEVICE=true`). |
| s14–s17 | pass | | s15 `head -14.6 dBFS, body -9.0 dBFS` |
| s18 | pass | | FIX-UX-14-4 confirmed: the playhead is restored on reopen |
| x_ios_background_export | pass | | `pausedInBackground observed: false` (simulator reality) |
| x_android_api28 | pass (trivial on iOS) | | |
| x_android_export_background | skipped on iOS | | |

### iPad Pro 13-inch (M5), iOS 26.5: s12 (`2C9213E9-…`)

**pass.** Every keyboard and pointer step passes, and so does the marquee (`Offset(829.8, 933.0) -> Offset(300.5, 937.0)`). The wheel zoom goes from 91.4 to 152.3 px/s.

**V-U5: certified on the simulator.** Every ⌘ combo in s12 reaches the editor's shortcuts as Flutter key events on the iPad simulator: ⌘Z, ⌘⇧Z, ⌘S in a text field, ⌘C/⌘V/⌘D and ⌘+wheel. The physical-keyboard pass (checklist step 3) is still a person's step.

### iPhone 16, iOS 18.2: s01–s03 (`7DF46AEE-…`)

s01, s02 and s03 all pass.

### Lab devices

Deferred: no device available (owner default 2026-10-08, ARCH D-43).

### Manual iPad steps tried on the simulator (2026-10-17 00:39)

Setup:

- Installed a debug build of `Runner.app` with `DANAVIEW_EDITOR=true` and `DANAVIEW_AUTO_CAPTIONS=true` on the iPad simulator.
- Added `frame_counter_720p25.mp4` and `still_4k.jpg` to Photos with `simctl addmedia`.
- Put `frame_counter_720p24.mp4` and `tone_1khz.wav` in Files › On My iPad. They were copied into the simulator's `group.com.apple.FileProvider.LocalStorage` container and removed afterwards.

What happened:

- Projects › New project › Start empty opens the editor, and the Media panel shows "or drop files here" (`build/e2e/ios/2C9213E9-…/manual/01_editor_empty.png`).
- Swiping up from the bottom edge shows the dock with Photos and Files.
- Long-pressing Photos in the dock and dragging it to the right edge, to open it in Split View, did nothing on two tries (`02_dock_drag_not_taken.png`). The panel's synthetic touches do not start SpringBoard's dock drag, so the harness cannot reach Split View or a cross-app drop.

Steps 1 and 2 therefore stay with a person. Drive the Simulator with the Mac's pointer: drag Photos or Files from the dock into Split View, then drag the asset onto the Media panel and onto the timeline. Check that it imports (Photos: a PHPicker-style item provider; Files: a security-scoped URL that is copied, ARCH §16) and lands at the drop time.

## Earlier run: re-run 2 of 2026-10-16 (after the first FIX round)

Environment:

- Xcode 26.6 (17F113), Flutter 3.44.2, debug builds.
- `WhisperCore.xcframework` rebuilt by the script with CMake 3.22.1, because the AI-05 build script changed (FIX-AI-05-1 landed, so the stamp no longer matched). `--status` reports `up-to-date` afterwards.
- Models `ggml-tiny-q5_1.bin` and `ggml-silero-v6.2.0.bin` staged from `/Users/besaoct/danaview-models` (owner-approved, SHA-256 verified). Nothing was downloaded, and nothing was copied into the repo.
- `FIX-INT-02-1` workaround still active: `E2eApp._boot` sets the documents root.
- Load: another builder's `xcodebuild` ran at the same time. Swap stood at about 9 of 10 GB on the 8 GB Mac.

Commands:

```sh
DV_E2E_IPHONE="iPhone 16" scripts/ci/editor/e2e_ios.sh iphone                       # full suite
DV_E2E_IPHONE="iPhone 16" scripts/ci/editor/e2e_ios.sh --target sNN iphone           # solo re-runs: s02, s18, s13
DV_E2E_IPHONE="iPhone 16" scripts/ci/editor/e2e_ios.sh ipad legacy lab
```

### iPhone 16, iOS 26.5 (full suite, `6663101E-…`)

| # | Result | Cause / evidence |
|---|---|---|
| s01 | pass | |
| s02 | pass (solo re-run) | Failed in the full run with `Timed out after 60 s waiting for the editor to be ready` (preview start under swap pressure). It passes on its own re-run and on iOS 18.2: the editor opens on frame 160, barcode 160. FIX-UX-41-1 is confirmed fixed. Load flake, not a defect. |
| s03 | pass | |
| s04 | pass | |
| s05 | pass | |
| s06 | pass | FIX-INT-02-2 is confirmed fixed: the freeze frame renders. |
| s07 | pass | H.264/MP4 720p conforms. Reported, not failed: `HEVC/MOV not offered here (hevcEncode false, mov true)`. |
| s08 | pass | FIX-QA-00-1 is confirmed fixed. Captioning "This clip" with the tiny model gives 3 cues ("Welcome to the video editor test, …"); the SRT round trips, and one undo removes them all. |
| s09 | pass | Phase `edit` ends with the host kill; phase `recover` restores the edit. |
| s10 | **fail** | **FIX-UX-40-1.** FIX-UX-07-2 is confirmed fixed: the banner, Locate, Relink several and "Relink 3 files" all work, and every asset is relinked. But the preview shows no frame of the relinked file afterwards: `barcode().index` is `null` (expected 10) after `waitReady` and a seek to clip start + 10 frames. |
| s11 | pass | No black frame 1 s after foreground. |
| s12 | **fail** | **FIX-QA-00-2 (suite).** FIX-UX-07-1 is confirmed fixed. Space/K, ←/→ barcode frame step, Shift+←/→, S, Delete/Backspace, ⌘Z/⌘⇧Z, ⌘S in a text field, ⌘C/⌘V/⌘D, wheel/Shift+wheel/⌘+wheel and the right-click menu all pass. The last step (marquee) fails with `got {}`. The marquee starts at `project.duration + 0.5 s` on the main lane. On iOS the timeline is centre-locked by default, so zoom-to-fit keeps the playhead centred, and the end of the 14 s project lies past the right edge (screenshot `191028-s12_context_menu.png`: playhead 3:18, clips run off-screen). The drag starts outside the canvas. |
| s13 | **fail (simulator)** | The earlier "no clip lands" is gone, and FIX-INT-07-1 is resolved: a WAV recording lands on a voice lane. Only the timing bounds miss on the simulator's virtual mic, differently on each run. Full run: duration 4 966 667 µs (bound 2.5–4 s). Solo re-run: start latency 533 334 µs (bound < 500 ms). Deferred: no device available (simulator audio latency). |
| s14 | pass | |
| s15 | pass | `head -14.6 dBFS, body -9.0 dBFS` (fade-in quieter). |
| s16 | pass | |
| s17 | pass | |
| s18 | **fail** | **FIX-UX-14-4.** Reproduced 2 of 2. After close and reopen, the timeline JSON is equal, but `playhead.value` is `0` (expected 2 566 667 µs, frame 77). Zoom is not reached. |
| x_ios_background_export | pass | Simulator reality: `pausedInBackground observed: false`, reported. |
| x_android_api28 | pass (trivial on iOS) | |
| x_android_export_background | skipped on iOS | |

### iPad Pro 13-inch (M5), iOS 26.5: scenario 12 (`2C9213E9-…`)

| # | Result | Cause |
|---|---|---|
| s12 | **fail** | FIX-QA-00-2, the same as on the iPhone. Every keyboard and pointer step up to the marquee passes (`wheel: zoom 91.4 -> 152.3 px/s`); the marquee selects nothing. |

**V-U5 (iPad hardware-keyboard ⌘ combos reach Flutter): partly certified.** Every ⌘ combo in s12 (⌘Z, ⌘⇧Z, ⌘S in a text field, ⌘C/⌘V/⌘D, ⌘+wheel) reaches the editor's shortcuts on the iPad simulator through Flutter key events. Two things are still pending: the physical-keyboard check (manual checklist step 3, I/O › Keyboard › Connect Hardware Keyboard), and the green s12 that FIX-QA-00-2 needs.

### iPhone 16, iOS 18.2: scenarios 1–3 (`7DF46AEE-…`)

| # | Result | Cause |
|---|---|---|
| s01 | pass | |
| s02 | pass | FIX-UX-41-1 is confirmed fixed on iOS 18.2. |
| s03 | pass | |

### Lab devices (iPhone 7 iOS 15.8, iPhone 8 iOS 16.7)

Deferred: no device available. Under the owner default of 2026-10-08 (ARCH D-43), neither device exists in the lab. `e2e_ios.sh lab` runs s01–s04 on them when `DV_E2E_LAB_UDIDS` is set. On a device, s02–s04 need the fixtures in the app's `Documents/e2e_fixtures`.

## Manual checklist (iPad simulator)

1. Drop from Files into the editor (Split View): pending, needs a person. Tried on 2026-10-17; see re-run 3.
2. Drop from Photos (Split View): pending, needs a person. Same as step 1.
3. Physical hardware keyboard and the ⌘/ sheet (V-U5): pending, needs a person. The simulator-level V-U5 check passes (s12 on the iPad).
4. Pointer (hover pill, right-click menu, marquee): the right-click menu and the marquee are covered automatically and pass in s12. The hover pill is pending.

## Earlier run: first run of 2026-10-16

Results: 11 of 18 on the iPhone; s12 failed on the iPad; the iOS 18.2 lane passed s01 and s03 and failed s02. The causes were FIX-UX-41-1, FIX-INT-02-2, FIX-QA-00-1, FIX-UX-07-1 and FIX-UX-07-2 (all since fixed) and FIX-INT-07-1 (resolved; see s13 above).

## Simulator realities (reported, not failed)

- No hardware HEVC encoder: s07 reports `hevcEncode false`.
- H.264 encoding is software.
- Performance numbers are meaningless; QA-04 measures on devices.
- The encoder keeps running in the background, so the background-export extra never pauses.
- The Mac's virtual audio input has unpredictable start latency: 0.2 to 1.4 s across runs, more under load. s13 uses a 750 ms simulator budget; the 100 ms budget is for devices.
- Under memory pressure (8 GB Mac, parallel builders), the first editor open after a cold build can take more than 60 s (s02 in the full run).
- Under memory pressure, a back-to-back export stalled in AVFoundation once (s07 export B in re-run 3). FIX-IOS-12-1 fixed it, and both exports complete in the re-run 4 batch.
- Under load, `flutter test` sometimes never attaches to an app that has started its VM service (s02 and s03 in re-run 4). The script retries such files once.

## Defects filed

Re-run 4 adds this row:

| Id | Owner | File | What | Fix |
|---|---|---|---|---|
| FIX-QA-00-4 (optional, harness speed) | QA-00 | `integration_test/editor/tool/e2e_host.sh` | When `flutter test` never attaches to the app (VM service listening, tool not connected), the phase waits for the full 900 s watchdog before e2e_ios.sh retries it. Seen on s02 and s03 in re-run 4; both pass on the retry. | Add a shorter attach watchdog: if the phase log shows no test line (`00:00 +0: <test name>`) within about 180 s of `Xcode build done.`, stop it early so the retry starts sooner. |

Re-run 3 added this row (FIX-IOS-12-1 is now **fixed**: the stall window is 45 s plus 10 s slack, every segment reader is torn down between exports, RunnerTest `ExportD7Tests.testBackToBackSoakExportsTearDownEveryComposition`, and s07 passes in the re-run 4 batch):

| Id | Owner | File | What | Fix |
|---|---|---|---|---|
| FIX-IOS-12-1 (fixed) | IOS-12 | `packages/danaview_editor_engine/ios/Classes/Export/ExportCoordinator.swift` (and the writer behind it) | In the s07 full run, the second export of the session (export B) stalled in phase `rendering`. CoreMedia logged `remakerFamily_renderPipelineRanDry`, and nothing progressed for 565 s until the watchdog failed the job (`encodingFailed: export stalled`). It passes on its solo re-run and passed in re-runs 1 and 2, so it is load-sensitive, not deterministic. | Find out why the reader/writer pipeline runs dry on a back-to-back export under memory pressure (a pending `requestMediaDataWhenReady` that never fires, or a reader that is not restarted). At least shorten the stall window, so a stalled export fails within about 60 s instead of 9 to 10 minutes. |

Rows from the earlier runs (all fixed or resolved now):

| Id | Owner | File | What | Fix |
|---|---|---|---|---|
| FIX-UX-40-1 (needs triage, maybe INT-02) | UX-40 | `packages/danaview_editor/lib/src/editor/flows/relink/` (relink apply → preview) | After "Relink 3 files", every asset is relinked and the banner is gone. But after `waitReady` and a seek, the preview frame has no barcode (`null`, expected 10): the preview does not render the relinked media. | On relink apply, re-resolve the media paths in the compiled plan and push a new plan, or restart the preview, so it reads the new files. |
| FIX-UX-14-4 (needs triage, maybe UX-08) | UX-14 | `packages/danaview_editor/lib/src/editor/state/playhead_controller.dart` / `editor_controller.dart` | Close and reopen restores the timeline but not the playhead: it is 0 instead of the saved view playhead (2 566 667 µs). Reproduced 2 of 2 on the iOS 26.5 simulator. Either the settled seek's `updateView` does not reach disk before close, or the reopened playhead does not `reset` to `view.playhead`. | Make sure close flushes the last settled view state, and that the reopened `PlayheadController` starts at `committed.view.playhead`. Add a unit test: seek, close, reopen, playhead equal. |
| FIX-QA-00-2 | QA-00 | `integration_test/editor/s12_keyboard_pointer_test.dart` (marquee step) | The marquee starts at `project.duration + 0.5 s`. With the iOS default centre-locked timeline, zoom-to-fit keeps the playhead centred, so that point is past the right edge and the drag starts outside the canvas. The selection stays empty on the iPhone and the iPad. | Start the marquee at a visible point: clamp `from.dx` to the canvas's right edge minus a few px, over empty lane space, or switch the viewport to free mode / seek near the end before fitting. |
| FIX-QA-00-3 (optional) | QA-00 | `integration_test/editor/s13_voiceover_test.dart` | The latency (< 500 ms) and duration (2.5–4 s) bounds miss on the simulator's virtual mic: 533 ms and 4.97 s on two runs. | Keep the bounds for devices, and on the simulator report the numbers (DV_E2E_REPORT) instead of failing, or measure the duration against the wall time up to the stop tap. |

FIX-AI-05-1 is fixed: the digest now uses `git ls-files`. FIX-INT-07-1 is resolved: the recording commits a clip.
