<!-- OWNER: QA-01 -->

# QA-01: E2E suite on the iOS Simulator

This report covers QA-00's app-level suite (`integration_test/editor`, ARCH §21.2) run on the iOS Simulator with the release dart-defines `DANAVIEW_EDITOR=true` and `DANAVIEW_AUTO_CAPTIONS=true` (BUILD_PLAN QA-01).

**Status: not certified yet (re-run 2 of 2026-10-16, 18:10–19:41).** On the iPhone, 14 of 18 scenarios pass, along with both iOS-relevant extras; the iOS 18.2 lane passes 3 of 3. That is up from 11 of 18 in the first run: FIX-UX-41-1, FIX-INT-02-2, FIX-UX-07-1, FIX-UX-07-2 and FIX-QA-00-1 have landed, and their scenarios now pass or get further. Four scenarios still fail:

- s10 and s18 are app defects (FIX-UX-40-1, FIX-UX-14-1).
- s12 is a suite defect (FIX-QA-00-2), on the iPhone and the iPad alike. Every keyboard step passes; only the closing marquee step fails.
- s13 is a simulator timing reality. The clip now lands; only its latency and duration bounds miss. Deferred to a device.

QA-01 re-runs `scripts/ci/editor/e2e_ios.sh` once those land, and updates this report.

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

## Run of 2026-10-16 (re-run 2, after the FIX round)

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
| s18 | **fail** | **FIX-UX-14-1.** Reproduced 2 of 2. After close and reopen, the timeline JSON is equal, but `playhead.value` is `0` (expected 2 566 667 µs, frame 77). Zoom is not reached. |
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

### Manual checklist (iPad simulator)

These steps are not recorded yet. They need a person driving Split View with Files and Photos; the harness cannot do that.

1. Drop from Files into the editor (Split View): pending.
2. Drop from Photos (Split View): pending.
3. Physical hardware keyboard and the ⌘/ sheet (V-U5): pending. It is no longer blocked, because FIX-UX-07-1 has landed.
4. Pointer: hover pill, right-click menu, marquee: pending. The right-click menu is covered automatically in s12.

### Earlier run (2026-10-16, first)

Results: 11 of 18 on the iPhone; s12 failed on the iPad; the iOS 18.2 lane passed s01 and s03 and failed s02. The causes were FIX-UX-41-1, FIX-INT-02-2, FIX-QA-00-1, FIX-UX-07-1 and FIX-UX-07-2 (all since fixed) and FIX-INT-07-1 (resolved; see s13 above).

## Simulator realities (reported, not failed)

- No hardware HEVC encoder: s07 reports `hevcEncode false`.
- H.264 encoding is software.
- Performance numbers are meaningless; QA-04 measures on devices.
- The encoder keeps running in the background, so the background-export extra never pauses.
- The Mac's virtual audio input has unpredictable latency, which affects the s13 timing bounds.
- Under memory pressure (8 GB Mac, parallel builders), the first editor open after a cold build can take more than 60 s (s02 in the full run).

## Defects filed

| Id | Owner | File | What | Fix |
|---|---|---|---|---|
| FIX-UX-40-1 (needs triage, maybe INT-02) | UX-40 | `packages/danaview_editor/lib/src/editor/flows/relink/` (relink apply → preview) | After "Relink 3 files", every asset is relinked and the banner is gone. But after `waitReady` and a seek, the preview frame has no barcode (`null`, expected 10): the preview does not render the relinked media. | On relink apply, re-resolve the media paths in the compiled plan and push a new plan, or restart the preview, so it reads the new files. |
| FIX-UX-14-1 (needs triage, maybe UX-08) | UX-14 | `packages/danaview_editor/lib/src/editor/state/playhead_controller.dart` / `editor_controller.dart` | Close and reopen restores the timeline but not the playhead: it is 0 instead of the saved view playhead (2 566 667 µs). Reproduced 2 of 2 on the iOS 26.5 simulator. Either the settled seek's `updateView` does not reach disk before close, or the reopened playhead does not `reset` to `view.playhead`. | Make sure close flushes the last settled view state, and that the reopened `PlayheadController` starts at `committed.view.playhead`. Add a unit test: seek, close, reopen, playhead equal. |
| FIX-QA-00-2 | QA-00 | `integration_test/editor/s12_keyboard_pointer_test.dart` (marquee step) | The marquee starts at `project.duration + 0.5 s`. With the iOS default centre-locked timeline, zoom-to-fit keeps the playhead centred, so that point is past the right edge and the drag starts outside the canvas. The selection stays empty on the iPhone and the iPad. | Start the marquee at a visible point: clamp `from.dx` to the canvas's right edge minus a few px, over empty lane space, or switch the viewport to free mode / seek near the end before fitting. |
| FIX-QA-00-3 (optional) | QA-00 | `integration_test/editor/s13_voiceover_test.dart` | The latency (< 500 ms) and duration (2.5–4 s) bounds miss on the simulator's virtual mic: 533 ms and 4.97 s on two runs. | Keep the bounds for devices, and on the simulator report the numbers (DV_E2E_REPORT) instead of failing, or measure the duration against the wall time up to the stop tap. |

FIX-AI-05-1 is fixed: the digest now uses `git ls-files`. FIX-INT-07-1 is resolved: the recording commits a clip.
