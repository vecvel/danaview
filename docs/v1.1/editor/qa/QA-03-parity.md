<!-- OWNER: QA-03 -->

# QA-03 · Frame accuracy, grid cuts, A/V sync and render parity

This report covers BUILD_PLAN QA-03 and the "Parity, accuracy, A/V sync" row of ARCH §21.1, with D-35 (platform-time rule), §11.5 (time semantics and the A/V-sync contract), §11.6 (render math and parity tolerance) and §12.7 (preview latency). Export conformance, presets and audio measurements are in QA-11.

There are three integration tests in `packages/danaview_editor_engine/example/integration_test/`. Each one runs through the real plugin: `MobileEditorEngine` → Pigeon → the native preview, exporter and media jobs (iOS IOS-06/07/11/12/17/18, Android AND-06/07/10/11). The tests check the results from Dart, so the same rules hold on both platforms.

| File | What it checks |
|---|---|
| `accuracy_test.dart` | Exact seeks 200/200 through speed segments and again after a structural patch. The grid-cut case at 24/30/48/60 fps, in exact-seek preview, playback capture and export. Off-grid export durations, reverse renditions, freeze stills and proxy PTS. It also holds the QA-03 support code: fixture lookup, plan builders, PNG codec, MP4 timestamp reader, frame reader, and export/preview helpers. |
| `av_sync_test.dart` | Clap/flash A/V sync at 1×, 2× keep-pitch, a 0.5× ramp and across a cross dissolve. Export is measured on both audio and video. Preview is measured on the video side. |
| `parity_test.dart` | Render parity against the API-03 reference renderer for the whole golden corpus: preview texture captures plus exported frames. It also checks freeze-still colours, writes the iOS-vs-Android renders, and holds the comparison tool. |

## How to run

The ENG-05 media is not bundled in the example host (ENG-09 owns its pubspec), so the tests read it from a directory passed as `QA03_MEDIA`. An iOS simulator can read host paths directly. From `packages/danaview_editor_engine/example`:

```
M=$PWD/../test_fixtures/media
flutter test integration_test/accuracy_test.dart -d <device> --dart-define=QA03_MEDIA=$M
flutter test integration_test/av_sync_test.dart  -d <device> --dart-define=QA03_MEDIA=$M
flutter test integration_test/parity_test.dart   -d <device> --dart-define=QA03_MEDIA=$M \
  [--dart-define=QA03_OUT=<render dir>] [--dart-define=QA03_PEER=<other platform's renders>] \
  [--dart-define=QA03_GOLDENS=<engine_api/test_fixtures/images>] [--dart-define=QA03_DEBUG=<dir for got/want PNGs of failures>]
```

- If `QA03_MEDIA` is missing, the media tests are reported as **skipped**; they never pass silently. The support self-checks still run.
- Every measured value is printed as a `QA03|<kind>|key=value|…` line, so you can rebuild these tables with `grep QA03`.
- `parity_test.dart` reads the contract-corpus plans from `QA03_GOLDENS`. The default is the API-03 tree next to the media.

**Simulator isolation.** Use a simulator that no other `flutter test` run is using at the same time. If another app is launched on the same simulator, the example app goes to the background. The iOS exporter then pauses by design (D-22), and every later export times out. The first parity attempt here failed that way while another builder ran its `integration_test/editor` suite on the shared iPhone 17.

## Method

### Frame identity

- Every captured frame carries two independent identities:
  - the **source barcode**: the ENG-05 top band, read by `FrameBarcode`;
  - a **timeline marker**: a yellow square whose slot (x position) is the timeline frame index mod 8.
- The marker is keyframed with held steps, so it changes exactly at each frame start.
- A frame that is one frame off at a cut therefore has the right barcode for the wrong marker slot. This works in playback capture, where the timeline frame is not known in advance.

### Expected source frame

- The expected frame follows ARCH §11.5 exactly: the greatest **real** PTS of the file ≤ s + 500 µs.
- Real PTS come from the file's stts/ctts/elst, read by `readTrackTimes`.
- The tests also count how often this differs from the nominal `i·10⁶/fps` (`nominalPtsDeviations`).

### Grid-cut timeline

- Layout: A | B | C on `frame_counter_720p<fps>`. At 30 fps, `frame_counter_1080p30` is used, because there is no 720p30 file.
- Cuts are at k1 ≡ 1 and k2 ≡ 2 (mod 3), with at least 1.5 s on both sides of each cut, so every frame of each 3 s window is checked.
- The three source ranges are disjoint, so every barcode is unique.
- The timeline is rounded up to whole seconds, so the grid-cut check does not depend on the off-grid export defect (finding 1).

### Exported files

- Exported files are read back frame by frame with exact seeks of a preview session on the file. The canvas is the file's size, with a 1:1 map and a 1 ms read lead.
- Exact seek itself is verified 200/200 first.
- Which file frame each read lands on is checked against the file's real PTS.
- Native freeze stills are taken at the cuts as an independent second reader.

### A/V sync

- Fixture: `clap_flash_av` (flash frames 30/75/120; a 20 ms 2 kHz click starting exactly at each flash; AAC with priming in the edit list).
- **Video:** the first flash frame in the export, read back as above.
- **Audio:** the click onset in the export's PCM, taken from the engine's speech-audio job (16 kHz, sample-accurate). The onset is the first sample at ≥ 10 % of the click's peak.
  - The Hann burst reaches 10 % about 2 ms after it starts, so the onset has a bias of about +2 ms.
  - The fixture itself measures +2.1/+2.4/+2.1 ms through the same chain, which also confirms the priming edit list is honoured.
- **Pass rule:**
  - every click is within 1 frame and 20 ms of its plan time;
  - the first flash frame is exactly the expected timeline frame;
  - where the flash lands on a frame start, the A/V offset is ≤ 20 ms.

### Render parity

- The corpus is all of API-03's `GoldenCases`: 31 plans with 100 golden frames. The 0-length `empty_plan` and `offline_placeholder` (which needs a missing file) are skipped.
- **Sources:**
  - Images, sprites (`.vsprite`), LUTs (`.vlut`) and tones are API-03's synthetic sources, written to disk unchanged.
  - Each video asset is first encoded on the device: the synthetic frames the goldens use become image layers at the source rate, exported as H.264.
  - Every used frame is then decoded back 1:1 through preview and handed to the reference renderer, so the engine and the reference see the same decoded pixels.
  - Rotation and HDR transfer are dropped from the device assets, because the written content is already display-oriented SDR.
- **Preview:** canvas ≤ 640 px renders at full quality, ≤ 1280 px at half, otherwise at quarter. The reference renders at the capture size.
- **Export:** the transform fixtures, text, typewriter and image cases are exported at canvas size with H.264 at 12 bits per pixel per second, then read back 1:1.
- **Metric:** the same as IOS-10's. Pass requires:
  - mean |Δ| ≤ 1.5/255, taking the worst channel;
  - p99 ≤ 6/255;
  - SSIM ≥ 0.98 on the transform fixtures.
- **Edge exclusion:**
  - Pixels within 1.5 px of a placed layer or canvas-mask edge are excluded everywhere.
  - Exported frames also exclude **content edges**: pixels whose 3×3 neighbourhood in the reference spans more than 48/255, dilated by one pixel. This is the interpretation in finding 6, and it needs the lead's sign-off.

## Results: iOS simulator

Setup:
- iOS 26.5 (23F77), Xcode 26.6, Flutter 3.44, run 2026-10-15. Capabilities: tier high; software H.264 (`hardwareEncoder` false).
- The final runs used the iPhone 17 Pro, with the iPhone 17 for development runs. This Mac has no iOS 26.5 "iPhone 16" runtime; its iPhone 16 devices are on iOS 18.2.

### Exact seeks (frame_counter_1080p30, 30 fps plan, 640×360 canvas)

| Phase | Result | Seek + capture p50 / p95 |
|---|---|---|
| Map 1× \| 2× \| 0.5× \| 1× (breakpoints at 1 s, 2 s, 4 s): all 150 frames + 50 random (half mid-frame) | **200/200**, ack `displayedFrame` = k, seq increasing | 36 / 74 ms |
| After a structural patch (re-cut at frame 77 ≡ 2 mod 3, a 2× clip, a new overlay layer; ack structural, applyMs 291) | **200/200** | 60 / 90 ms |

The times include the Pigeon round trip and a full RGBA capture, so they are simulator numbers, not budgets.

### Grid-cut case (D-35)

| fps | Source | k1 / k2 | Frames | Exact-seek preview | Playback capture | Export (every frame) | Freeze stills at the cuts |
|---|---|---|---|---|---|---|---|
| 24 | 720p24 | 37 / 110 | 168 | 168/168 | 0 wrong; 168/168 frames seen; all 4 cut frames | 168/168; file PTS exact | 8/8 |
| 30 | 1080p30 | 46 / 137 | 210 | 210/210 | 0 wrong; 210/210 seen; 4/4 | 210/210; file PTS exact | 8/8 |
| 48 | 720p48 | 73 / 218 | 336 | 336/336 | 0 wrong; 318/336 seen; 4/4 | 336/336; file PTS ≤ 833 µs off nominal (finding 4) | 8/8 |
| 60 | 720p60 | 91 / 272 | 420 | 420/420 | 0 wrong; 397/420 seen; 4/4 | 420/420; file PTS exact | 8/8 |

- **Playback capture** polls `debugCaptureFrame` while playing, for up to four passes. It cannot guarantee that every frame is captured. The test requires 0 wrong frames and at least half the frames seen. Coverage was 95–100 %, and every frame next to a cut was seen in every case.
- **Grid-cut result: 100 % at all four rates.** This holds in exact-seek preview, in playback capture (for every frame captured) and in export.

### Other accuracy checks

| Check | Result |
|---|---|
| Reverse rendition of frames 60..119 (1080p30) | 60 frames, barcodes 119 → 60, **strictly decreasing by 1** at every frame |
| Freeze stills at frame starts and mid-frame (1080p30 ×8, 720p24/48/60 ×4 each, 40 stills) | **40/40 exact** against the file's real PTS. The 48 fps fixture's frames 73 and 383 sit 833 µs after their nominal start (finding 4). |
| Proxy of frame_counter_1080p30 (CFR) | 240/240 frames, **max PTS Δ 0.00 µs**; exact seeks on the proxy (`useProxies`) show the same barcode (35/35) |
| Proxy of vfr_720p (VFR, irregular durations, one held frame) | 143/143 frames, **max PTS Δ 0.00 µs** |
| Export duration off the whole-µs grid (`durUs = timeOfFrame(K)` not an integer number of µs) | **fails** at 24, 30, 48 and 60 fps with `AVFoundationErrorDomain -11841`; works at 25 fps (finding 1) |

### A/V sync (clap_flash_av, 30 fps, 640×360)

Click times are measured from the export's PCM; "A/V" means the click onset minus the first flash frame.

| Case | Flash (source frame → timeline) | Video: first flash frame (expected) | Click error | A/V | Result |
|---|---|---|---|---|---|
| 1× | 30 → 1.000 s | 30 (30) | +2.1 ms | +2.1 ms | pass |
| 1× | 75 → 2.500 s | 75 (75) | +2.4 ms | +2.4 ms | pass |
| 1× | 120 → 4.000 s | 120 (120) | +2.1 ms | +2.1 ms | pass |
| 2× keep pitch | 30 → 0.500 s | 15 (15) | +12.9 ms | +12.9 ms | pass |
| 2× keep pitch | 75 → 1.250 s | not shown at 2× (skipped source frame) | +9.9 ms | — | pass |
| 2× keep pitch | 120 → 2.000 s | 60 (60) | +12.8 ms | +12.8 ms | pass |
| 0.5× ramp (1 → 0.75 → 0.5 → 1×) | 30 @ 0.75× → 1.0667 s | 32 (32) | −15.3 ms | −15.3 ms | pass |
| 0.5× ramp | 75 @ **0.5×** → 4.000 s | 120 (120) | **−38.8 ms** | **−38.8 ms** | **fail** (finding 2) |
| 0.5× ramp | 120 @ 1× after the ramp → 5.600 s | 168 (168) | −3.9 ms | −3.9 ms | pass |
| Cross dissolve (1 s at 2.0 s, equal-power audio) | A 30 → 1.000 s | 30 (30) | +2.1 ms | +2.1 ms | pass |
| Cross dissolve | B 75 → 2.000 s (inside the dissolve) | blended, not checked | +2.1 ms (peak 0.37 ≈ 0.707 × 0.5) | — | pass |
| Cross dissolve | B 120 → 3.500 s | 105 (105) | +2.1 ms | +2.1 ms | pass |

In preview, every checked flash frame is shown exactly at its timeline frame, at exact seeks, in all four cases.

The click energy centroid shows how the keep-pitch stretch shifts audio:

| Rate | Centroid measured | Centroid expected |
|---|---|---|
| 1× | +10.0 ms | +10 ms |
| 2× | +16.8 ms | +5 ms |
| 0.75× | −5.1 ms | +13.3 ms |
| 0.5× | −23.2 ms | +20 ms |

The timing offset therefore grows as the rate falls below 1×.

### Render parity

All rows pass. Preview: 100 frames on 31 plans. Export: 32 frames on 8 plans. Each row shows the worst frame of that case.

| Case | Mode | Size | Frames | Worst mean /255 | Worst p99 /255 | Worst SSIM |
|---|---|---|---|---|---|---|
| minimal_preview | preview | 480×270 | 3 | 0.04 | 1 | 0.9998 |
| no_audio_export | preview | 270×480 | 3 | 0.02 | 1 | 0.9999 |
| export_24_from_30 | preview | 640×360 | 4 | 0.08 | 1 | 0.9996 |
| export_48_from_24 | preview | 480×270 | 4 | 0.04 | 1 | 0.9998 |
| grid_cuts_30fps | preview | 480×270 | 5 | 0.04 | 1 | 0.9998 |
| speed_ramp_multi_segment | preview | 480×270 | 3 | 0.04 | 1 | 0.9998 |
| reversed_rendition | preview | 480×270 | 2 | 0.04 | 1 | 0.9998 |
| hold_pending_still | preview | 480×270 | 3 | 0.04 | 1 | 0.9998 |
| transition_cross_dissolve | preview | 480×270 | 4 | 0.06 | 1 | 0.9997 |
| transition_fade | preview | 480×270 | 4 | 0.13 | 1 | 0.9990 |
| transition_dip_to_white | preview | 480×270 | 4 | 0.06 | 1 | 0.9996 |
| transition_slide | preview | 480×270 | 3 | 0.04 | 1 | 0.9998 |
| transition_slide | export | 1920×1080 | 3 | 0.58 | 4 | 0.9984 |
| transition_wipe | preview | 480×270 | 3 | 0.05 | 1 | 0.9998 |
| transition_wipe_down_inverted | preview | 480×270 | 3 | 0.05 | 1 | 0.9998 |
| transition_zoom | preview | 480×270 | 3 | 0.16 | 1 | 0.9986 |
| transition_zoom | export | 1920×1080 | 3 | 0.75 | 4 | 0.9970 |
| effects_every_static_key | preview | 480×270 | 4 | 0.03 | 1 | 0.9998 |
| anim_every_channel | preview | 480×270 | 4 | 0.11 | 1 | 0.9993 |
| anim_every_channel | export | 1920×1080 | 4 | 0.64 | 2 | 0.9974 |
| sprites_export_reveal | preview | 640×360 | 5 | 0.07 | 1 | 0.9994 |
| sprites_export_reveal | export | 1280×720 | 5 | 0.59 | 3 | 0.9981 |
| audio_gain_envelopes | preview | 640×360 | 1 | 0.06 | 1 | 0.9994 |
| backdrop_blur_portrait | preview | 270×480 | 2 | 0.09 | 1 | 0.9997 |
| image_solid_layers | preview | 480×270 | 3 | 0.03 | 1 | 0.9999 |
| image_solid_layers | export | 1920×1080 | 3 | 1.00 | 6 | 0.9991 |
| overlay_pip_chroma_mask | preview | 480×270 | 3 | 0.04 | 1 | 0.9998 |
| uhd_60fps | preview | 480×270 | 2 | 0.04 | 1 | 0.9998 |
| **api03_text_scale_8x** (8× scale-keyframed text) | preview | 640×360 | 5 | 0.06 | 1 | 0.9994 |
| **api03_text_scale_8x** | export | 1280×720 | 5 | 0.95 | 6 | 0.9970 |
| api03_typewriter | preview | 640×360 | 6 | 0.00 | 0 | 1.0000 |
| api03_typewriter | export | 1280×720 | 6 | 1.00 | 1 | 1.0000 |
| api03_grade_lut | preview | 640×360 | 2 | 0.03 | 1 | 0.9999 |
| api03_detail | preview | 640×360 | 1 | 0.04 | 1 | 0.9999 |
| api03_masks | preview | 640×360 | 3 | 0.04 | 1 | 0.9998 |
| api03_chroma_spill | preview | 640×360 | 2 | 0.07 | 1 | 0.9995 |
| api03_place | preview | 640×360 | 3 | 0.02 | 1 | 1.0000 |
| api03_place | export | 1280×720 | 3 | 1.10 | 3 | 0.9992 |
| api03_canvas_masks | preview | 640×360 | 3 | 0.06 | 1 | 0.9994 |

**Freeze-still colours:** the freeze job does **not** keep the decoded colours.

| Colour | Preview decode | Freeze still |
|---|---|---|
| #808080 | 128,128,128 | 139,139,139 |
| #C08040 | 193,128,63 | 200,139,72 |
| #202020 | 33,33,33 | 37,37,37 |
| All six colours, worst Δ | 1 | 11 |

An independent ffmpeg decode of the same file on the Mac gives 126/190,126,61/31: the encode is correct, and the freeze path is not (finding 3).

### iOS vs Android renders

`parity_test.dart` writes every device render to `QA03_OUT/<golden>_f<kkkk>_<preview|export>.png`, box-downscaled to the golden's own size.

The iOS set is committed in [`QA-03-parity/ios/`](QA-03-parity/ios/): 132 PNGs, 1.5 MB.

With `QA03_PEER=<dir>`, the same test compares each of its renders with the peer's at the golden size, with the §11.6 tolerance. Exported frames use the codec edge exclusion of both images.

Self-check: two separate iOS runs compared through the peer path gave 132/132 within tolerance. The run is deterministic.

## Deferred

- **Android emulator (API 35): deferred to the Windows lane** (branch `editor-android`). All three files run unchanged. Only the media has to be on the device. From `packages/danaview_editor_engine/example`:
  ```
  P=/sdcard/Android/data/com.vecvel.danaview.editor.engine.example/files
  flutter test integration_test/engine_smoke_test.dart -d emulator-5554     # installs the app and creates $P
  adb push ../test_fixtures/media $P/qa03_media
  adb push ../../danaview_editor_engine_api/test_fixtures/images $P/qa03_goldens
  adb push ../../../docs/v1.1/editor/qa/QA-03-parity/ios $P/qa03_peer_ios
  flutter test integration_test/accuracy_test.dart -d emulator-5554 --dart-define=QA03_MEDIA=$P/qa03_media
  flutter test integration_test/av_sync_test.dart  -d emulator-5554 --dart-define=QA03_MEDIA=$P/qa03_media
  flutter test integration_test/parity_test.dart   -d emulator-5554 --dart-define=QA03_MEDIA=$P/qa03_media \
    --dart-define=QA03_GOLDENS=$P/qa03_goldens --dart-define=QA03_OUT=$P/qa03_android --dart-define=QA03_PEER=$P/qa03_peer_ios
  adb pull $P/qa03_android ../../../docs/v1.1/editor/qa/QA-03-parity/android
  ```
  - If the app cannot read files that adb pushed into its external files directory, copy them into its internal files directory instead. Use `adb push … /data/local/tmp/…` then `adb shell run-as com.vecvel.danaview.editor.engine.example cp -r /data/local/tmp/qa03_media files/`, and pass `/data/data/com.vecvel.danaview.editor.engine.example/files/qa03_media`.
  - Paste the `QA03|…` lines into a "Results: Android emulator" section of this report.
  - The iOS vs Android parity verdict is the `QA03|peer|…` output of that run.
- **Preview A/V offset after latency compensation (≤ 1 frame and ≤ 40 ms, §12.7, V-N23): deferred, no device available.**
  - It needs the audible output and the displayed texture captured together.
  - No engine API exposes the preview audio from Dart. The video side of preview is checked here: the flash frame is exact at every exact seek.
  - The iOS simulator numbers are IOS-01 §2.8: compensated offset 10–14 ms.
  - The Android end-to-end number, including Flutter's raster delay, belongs to the Windows lane and the device lab.
- **Device lab: deferred, no device available.** Run the same three commands with `-d <device>` (iOS: the simulator flags work unchanged after `QA03_MEDIA` points at an on-device copy) on: iPhone 7 (iOS 15.8), iPhone 8 (iOS 16.7), iPhone SE 2, iPhone 12, iPhone 15 Pro, a 2–3 GB Android Go device, a 4 GB Android device, Pixel 7a, Pixel 9 or Galaxy S24, and an API 29 device. The grid-cut case must be 100 % on every device.
- **CI.** `scripts/ci/editor/ios.sh` and `android_emulator.sh` (owner ENG-09) run only `engine_smoke_test.dart`. They also do not pass `QA03_MEDIA`, so in CI these suites would show as skipped. See the defects section.

## Findings and defects

1. **iOS export fails whenever `durUs` is not a whole number of µs. Owners: IOS-12 / IOS-17. Severity: blocker.**
   - Symptom: `durUs = timeOfFrame(K) = ceil(K·10⁶/fps)` fails at 24, 30, 48 and 60 fps whenever K·10⁶/fps is fractional. That is two thirds of all project lengths at 30 fps. The failure is `EngineFailure(internal: AVFoundationErrorDomain -11841)` (invalid video composition).
   - Reproduced lengths: 1 frame, 25, 31, 49, 73, 91, 146, 179, 182 and 362 frames.
   - Works: whole-second lengths, and every 25 fps length.
   - Likely cause: the pipeline gives the reader and writer a µs time range ending at `durUs` (`CMTime(value: durUs, timescale: 1_000_000)`, for example in `SegmentedWriter` and `ReaderWriterPipeline`). That end lies up to 1 µs past the composition's `CMTime(K, gridFps)` end and its last instruction.
   - Proposed fix (D-35): clamp the end to `CMTime(K, gridFps)`, or build the time range from frame indices.
   - The test that tracks it is `accuracy_test.dart` "export duration off the whole-µs grid", which currently fails. QA-11's 3 s fixtures never hit this case.
2. **Keep-pitch audio is not time-aligned inside scaled segments. Owners: IOS-18 / IOS-12. Export A/V sync fails at 0.5×.**
   - Inside a 0.5× keep-pitch segment, the click arrives **38.8 ms before** its flash. That is more than 20 ms and more than one frame.
   - At 0.75× it is −15.3 ms, at 2× it is +12.9 ms, and 1× segments are exact.
   - The energy centroid moves with the rate (2×: +12 ms; 0.75×: −18 ms; 0.5×: −43 ms against a correctly stretched click). This looks like the `.timeDomain` pitch algorithm's latency, which is never compensated per segment.
   - The ramp-seam click test (QA-11) does not see this, because it measures transients rather than timing.
   - Tracked by `av_sync_test.dart` "0.5x ramp", which fails.
3. **The freeze-still job applies colour management. Owner: IOS-06.**
   - Encoded mid-grey 128 comes back as 139. In general, darks and mids are lifted by about +5 to +11.
   - The preview and the exporter decode the same file to within ±1, and so does an independent ffmpeg decode.
   - A freeze frame therefore visibly brightens against the clip it freezes, and pending-still holds will jump in brightness. This violates ARCH §11.6 ("colour management off").
   - Likely cause: `AVAssetImageGenerator` or CGImage output is converted to a colour-managed space. It should use the compositor's `NSNull` colour spaces, or copy from a reader output.
   - Tracked by `parity_test.dart` "freeze stills keep the decoded colours", which fails. Freeze **frame indices** are exact (40/40).
4. **Timescale 600 cannot hold 48 fps. Owners: ENG-05 (fixture tool) and IOS-12 (export writer).**
   - `frame_counter_720p48.mp4` (from `make_fixtures.swift`) and every 48 fps export use timescale 600. Frame k is stored at round(12.5·k) ticks, so odd frames sit up to 833 µs off `k·10⁶/48`.
   - With the §11.5 rule (PTS ≤ s + 500 µs), 133 of the 336 grid-cut frames show the neighbouring source frame compared with the nominal design. The engine follows the rule exactly; the file is what is off.
   - Proposed fix: write 48 fps at timescale 48000, or any multiple of 48. Then regenerate the fixture.
   - The tests use the files' real PTS, so they stay correct either way.
5. **Playback reaching the end of the timeline shows a black frame instead of holding the last frame. Owner: IOS-11. Minor.** After `durUs` the captured texture is black (`passesEndingBlack`). Users see a black flash at the end of every played-through timeline.
6. **Parity tolerance for exported frames needs the lead's sign-off.**
   - 8-bit 4:2:0 H.264 cannot keep a sharp chroma edge at any bitrate. For example, the checkerboard of `api03_place` reaches p99 14/255 at 12 bits per pixel per second, while the encode is otherwise correct (signed mean 0.0/0.8/0.8).
   - The suite therefore excludes content edges for exported frames (see Method), in addition to layer edges.
   - Without that exclusion, `api03_place`, `api03_text_scale_8x` and `sprites_export_reveal` miss p99 in export, with mean 0.7–1.7. Preview passes without it.
   - The alternative is to compare exported frames against a 4:2:0-subsampled reference. That reduces but does not remove the gap (p99 13 in the worst region).
7. **CI does not run QA-03 yet. Owner: ENG-09.** `scripts/ci/editor/ios.sh` and `android_emulator.sh` need to run the three files with `--dart-define=QA03_MEDIA=<packages/danaview_editor_engine/test_fixtures/media>`; on Android, push the media first. Otherwise the suites are reported as skipped.
