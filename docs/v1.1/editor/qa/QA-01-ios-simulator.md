<!-- OWNER: QA-01 -->

# QA-01: E2E suite on the iOS Simulator

This report covers QA-00's app-level suite (`integration_test/editor`, ARCH §21.2) run on the iOS Simulator with the release dart-defines `DANAVIEW_EDITOR=true` and `DANAVIEW_AUTO_CAPTIONS=true` (BUILD_PLAN QA-01).

**Status: not certified yet.** 11 of 18 scenarios pass, along with both iOS-relevant extras. Seven scenarios fail. Six of them trace to open FIX tickets in the app and one to a suite defect (FIX-QA-00-1). Scenario 13 also needs a device. QA-01 re-runs `scripts/ci/editor/e2e_ios.sh` once those tickets land, and updates this report.

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

## Run of 2026-10-16

Environment:

- Xcode 26.6 (17F113), Flutter 3.44.2, debug builds.
- `WhisperCore.xcframework` rebuilt with CMake 3.22.1 and Ninja; `check_ios_min_os` OK at iOS 15.0.
- Models `ggml-tiny-q5_1.bin` and `ggml-silero-v6.2.0.bin` from `/Users/besaoct/danaview-models`. The owner approved them on 2026-10-15, and their SHA-256 is verified.
- Nothing was downloaded.
- `FIX-INT-02-1` workaround active: `E2eApp._boot` sets the documents root.

### iPhone 16, iOS 26.5 (full suite)

| # | Result | Cause / evidence |
|---|---|---|
| s01 | pass | |
| s02 | **fail** | FIX-UX-41-1. The player now reports 5 333 333 µs, but the editor still opens on frame 159 (`view.playhead 5 300 000`): it floors instead of rounding to the nearest frame. |
| s03 | pass | |
| s04 | pass | |
| s05 | pass | |
| s06 | **fail** | FIX-INT-02-2. The freeze-frame still never renders (`the still shows source frame 60`: barcode null). |
| s07 | pass | H.264/MP4 720p conforms. Burned and not-burned cues, typewriter, dissolve window and SRT/VTT round trip all pass. Reported, not failed: `HEVC/MOV not offered here (hevcEncode false, mov true)`. |
| s08 | **fail** | **FIX-QA-00-1 (suite).** The models are staged and the pipeline runs. The sheet ends on "No audio to caption" (screenshot captured mid-run). The scenario imports `speech_10s.m4a` through New project › Files, and the import places audio on a **music** lane (domain.md: audio import → `AudioRole.music`). The "Whole video" scope leaves music unchecked by design (AI-12 planner, ai.md §8.2). `frame_counter_1080p30.mp4` has no audible speech stream, so the plan is empty. The app behaves as specified; the scenario has to caption the speech clip. |
| s09 | pass | Phase `edit` ends with the host kill; phase `recover` restores the edit. |
| s10 | **fail** | FIX-UX-07-2. `missing-media-banner` never shows (`EditorHealthHost` is not mounted). |
| s11 | pass | No black frame 1 s after foreground. |
| s12 | **fail** | FIX-UX-07-1. `EditorShortcuts` is not mounted, so Space does not start playback. |
| s13 | **fail (simulator)** | The app no longer aborts. The recorder starts (`AVAudioEngine start`, `voiceover.recording`), records for 3 s and stops, but no clip lands on a voice lane within 30 s. This simulator has no real audio input, so it can't tell an empty capture from a commit defect. Deferred: no device available. Filed to check on a device as FIX-INT-07-1 (needs confirming). |
| s14 | pass | |
| s15 | pass | Now passes, so FIX-UX-22-2 has landed. `head -14.6 dBFS, body -9.0 dBFS` (fade-in quieter). |
| s16 | **fail** | FIX-UX-07-1 (M adds no marker). |
| s17 | **fail** | FIX-UX-07-1 (S does not split). |
| s18 | **fail** | FIX-UX-07-1 (S does not split). |
| x_ios_background_export | pass | Simulator reality: `pausedInBackground observed: false`, reported. IOS-01/IOS-13 verify the pause on iPhones. |
| x_android_api28 | pass (trivial on iOS) | |
| x_android_export_background | skipped on iOS | |

### iPad Pro 13-inch (M5), iOS 26.5: scenario 12

| # | Result | Cause |
|---|---|---|
| s12 | **fail** | FIX-UX-07-1, same as on the iPhone: `waiting for playback to start` after Space. |

**V-U5 (iPad hardware-keyboard ⌘ combos reach Flutter): not certified.** The app has no keyboard shortcuts while FIX-UX-07-1 is open. Re-run the ipad lane after the fix, then do manual checklist step 3 with I/O › Keyboard › Connect Hardware Keyboard.

### iPhone 16, iOS 18.2: scenarios 1–3

| # | Result | Cause |
|---|---|---|
| s01 | pass | |
| s02 | **fail** | FIX-UX-41-1. On iOS 18.2 the player reports 5 333 000 µs and the editor opens on frame 159. The first attempt hung with `No tests ran.`, a harness hiccup under memory pressure; the script now retries such files once. The second attempt reached the assertion. |
| s03 | pass | |

### Lab devices (iPhone 7 iOS 15.8, iPhone 8 iOS 16.7)

Deferred: no device available. Under the owner default of 2026-10-08 (ARCH D-43), neither device exists in the lab. `e2e_ios.sh lab` runs s01–s04 on them when `DV_E2E_LAB_UDIDS` is set. On a device, s02–s04 need the fixtures in the app's `Documents/e2e_fixtures`.

### Manual checklist (iPad simulator)

These steps have not been recorded yet. They need the editor wiring fixed first: FIX-UX-07-1 for the hardware-keyboard step and FIX-UX-07-2 for health. Each is recorded with screenshots on the re-run.

1. Drop from Files into the editor (Split View): pending.
2. Drop from Photos (Split View): pending.
3. Physical hardware keyboard and the ⌘/ sheet (V-U5): pending, blocked by FIX-UX-07-1.
4. Pointer: hover pill, right-click menu, marquee: pending.

## Simulator realities (reported, not failed)

- No hardware HEVC encoder: s07 reports `hevcEncode false`.
- H.264 encoding is software.
- Performance numbers are meaningless; QA-04 measures on devices.
- The encoder keeps running in the background, so the background-export extra never pauses.
- The Mac has no usable audio input, which affects s13.

## Defects filed

| Id | Owner | File | What | Fix |
|---|---|---|---|---|
| FIX-QA-00-1 | QA-00 | `integration_test/editor/s08_auto_captions_test.dart` | Captions use the whole-video scope, but the speech clip sits on a music lane (the import default), which that scope excludes by design. The result is "No audio to caption". | Select the `speech_10s.m4a` clip and open Auto captions with the "This clip" scope (or check its track in the sheet). Alternatively, place the speech on a voice/original lane before the run. |
| FIX-AI-05-1 | AI-05 | `packages/danaview_whisper/tool/build_ios_xcframework.sh` | `tree_digest` hashes every file under `third_party/whisper.cpp`, including the git-ignored `bindings/javascript/package.json` that whisper.cpp's CMake configure writes into the source tree. Once it exists, the build stops with "vendored sources differ" and `--status` reports `stale`. | Exclude git-ignored files from the digest (for example `git ls-files` or a `-not -path` for that file), or configure so nothing is written into the source tree. |
| FIX-INT-07-1 (needs confirming) | INT-07 | voice recording commit path | On the iOS 26.5 simulator the recorder starts and stops cleanly, but no WAV clip lands on a voice lane. | Check on a device. If the capture is non-empty there and still nothing lands, trace the stop → commit path. |

The app defects already filed by QA-00 still reproduce: FIX-UX-41-1, FIX-INT-02-1 (workaround still needed), FIX-INT-02-2, FIX-UX-07-1 and FIX-UX-07-2. FIX-UX-22-2 is fixed (s15 passes).
