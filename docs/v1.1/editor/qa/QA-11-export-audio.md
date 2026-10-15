<!-- OWNER: QA-11 -->

# QA-11 · Export conformance, preset matrix and audio measurements

This report covers BUILD_PLAN QA-11, ARCH §14.4 and the "Export conformance and audio" row of §21.1, with D-37 and D-38.

The suite has three integration tests in `packages/danaview_editor_engine/example/integration_test/`. Each one runs through the real plugin: `MobileEditorEngine` → Pigeon → the native exporter (iOS IOS-12/17/18/20, Android AND-11/12/19). The tests then check the output file from Dart, so the same rules hold on both platforms.

| File | Part | What it checks |
|---|---|---|
| `conformance_test.dart` | (1) | §14.4 conformance on six fixtures. It also holds the shared support code: the MP4/MOV box reader, WAV and PNG writers, DSP and the export runner. |
| `preset_matrix_test.dart` | (2) | Every §14.1 preset, as resolved by core `resolveExportSettings` against the device's capabilities, then exported and checked with the same conformance rules. Also the portrait-refusal rule. |
| `audio_mix_test.dart` | (3) | Keep-pitch FFT, the 3-lane mix against the API-03 reference mixer, 200 % gain and the ramp-seam click test. Preview PCM is noted as deferred. |

Commands, run from `packages/danaview_editor_engine/example`:

```
flutter test integration_test/conformance_test.dart   -d <device>
flutter test integration_test/preset_matrix_test.dart -d <device>
flutter test integration_test/audio_mix_test.dart     -d <device>
```

Every measured value is printed as a `QA11|<kind>|key=value|…` line, so you can rebuild a table from any run with `grep QA11`.

## Method

- **Fixtures are generated on the device**, so the example host needs no bundled media:
  - mono 48 kHz s16 sine WAVs at −12 dBFS, 10 s long, at 440 / 500 / 660 / 1000 / 1500 / 3000 Hz;
  - a 640² RGB noise PNG, drawn full-frame and drifting horizontally, so every frame differs and the encoder must spend its whole budget.

  Per-pixel noise at the output resolution is incompressible. It made the simulator's software H.264 overshoot by 20 % at 30 fps and by 64 % on TikTok at 60 fps. At 640², upscaled about 2× at 1080p, the content still fills the budget but can be encoded at the requested rate. See "Findings".
- **Plans are written as RenderPlan v1 JSON**, in the shapes CORE-30 and CORE-31 lower to:
  - export target, canvas equal to the encode size and fps, audio sorted by (t0, id);
  - mute and solo follow the export lowering: a muted or soloed-out lane has no segment;
  - "everything muted" uses clip volumes of 0 instead, which gives zero-gain segments.
- **Output facts are read by a Dart ISO-BMFF/QuickTime box reader.** It reads:
  - the ftyp brand and the sample entries (`avc1`/`hvc1`/`mp4a`);
  - the coded size and the tkhd matrix (rotation and display size);
  - stts, giving the average fps and the delta spread (48 fps at timescale 600 alternates deltas of 12 and 13 ticks);
  - the stsz frame count and byte total, giving the video bitrate;
  - the esds AudioSpecificConfig (AOT, rate, channels);
  - the elst presentation durations. The AAC media runs 50.7 ms past the edit list because of priming and the last frame, so A/V coverage is measured on the edit list.
- **PCM is read back** through the engine's speech-audio job (IOS-04/AND-04): 16 kHz s16 mono, 0.5/0.5 downmix, sample-accurate.
  - The reference is `ReferenceAudioMixer` (API-03) fed the exact quantized fixture PCM, downmixed the same way.
  - Windows are 20 ms long. A window is compared only when the reference is ≥ −40 dBFS, and windows within ±1 of a hard segment edge are skipped.
  - Lane levels are measured with a Hann-windowed Goertzel at each lane's own frequency.

## Results: iOS simulator

Setup: iPhone 17, iOS 26.5, Xcode 26.6, Flutter 3.44, run 2026-10-15. The Mac has no iOS 26.5 "iPhone 16" runtime, so the iPhone 17 was used.

Capabilities: tier high, `hevcEncode` false, `movContainer` true, max export 3840×2160. The simulator encoders are software (`hardwareEncoder` false, with a visible `softwareEncoder` warning).

### (1) Conformance: 3 s, 1280×720, 30 fps, H.264 at 5 Mbps

| Fixture | Brand | Codec | Display (rot) | fps | Frames (expected) | Audio | A/V start / end gap | Video Mbps (ratio) | Audio RMS |
|---|---|---|---|---|---|---|---|---|---|
| tone (av) MP4 | mp42 | avc1 | 1280×720 (0) | 30.00 | 90 (90.0) | AAC-LC 48 kHz 2 ch | 0.0 / 0.0 ms | 5.71 (1.141) | −15.0 dBFS (tone −12 dBFS peak) |
| no audio | mp42 | avc1 | 1280×720 (0) | 30.00 | 90 (90.0) | AAC-LC 48 kHz 2 ch | 0.0 / 0.0 ms | 5.71 (1.141) | −120 dBFS |
| everything muted | mp42 | avc1 | 1280×720 (0) | 30.00 | 90 (90.0) | AAC-LC 48 kHz 2 ch | 0.0 / 0.0 ms | 5.71 (1.141) | −120 dBFS |
| everything soloed out | mp42 | avc1 | 1280×720 (0) | 30.00 | 90 (90.0) | AAC-LC 48 kHz 2 ch | 0.0 / 0.0 ms | 5.71 (1.141) | −120 dBFS |
| images/solids only | mp42 | avc1 | 1280×720 (0) | 30.00 | 90 (90.0) | AAC-LC 48 kHz 2 ch | 0.0 / 0.0 ms | 5.74 (1.148) | −120 dBFS |
| tone (av) MOV | qt | avc1 | 1280×720 (0) | 30.00 | 90 (90.0) | AAC-LC 48 kHz 2 ch | 0.0 / 0.0 ms | 5.71 (1.141) | −15.0 dBFS |
| HEVC | — | — | — | — | — | — | — | — | skipped: `hevcEncode` false on the simulator (device lab) |

The engine's own `probe()` agrees on every row: h264/aac at 1280×720, rotation 0, 2 channels, 48 kHz.

The "images/text only" fixture uses an image plus solid layers. Text reaches the exporter as sprite image layers, and rendered text in an export is verified by QA-00 scenario 7.

### (2) Preset matrix: 3 s, moving noise and a 1 kHz tone

| Preset | Encode (resolved) | Coded / display / rot | fps | Frames | Video Mbps / target (ratio) | Portrait path | Notices |
|---|---|---|---|---|---|---|---|
| YouTube 1080p | 1920×1080 30 H.264 | 1920×1080 / same / 0 | 30.00 | 90 | 9.06 / 8 (1.132) | n/a | — |
| YouTube 4K | 3840×2160 30 H.264 | 3840×2160 / same / 0 | 30.00 | 90 | 37.60 / 40 (0.940) | n/a | hevcUnavailable |
| YouTube Shorts | 1080×1920 30 H.264 | 1080×1920 / same / 0 | 30.00 | 90 | 9.00 / 8 (1.126) | native portrait | — |
| Instagram Reels | 1080×1920 30 H.264 | 1080×1920 / same / 0 | 30.00 | 90 | 9.00 / 8 (1.126) | native portrait | — |
| Instagram Feed | 1080×1350 30 H.264 | 1080×1350 / same / 0 | 30.00 | 90 | 6.86 / 6 (1.143) | native portrait | — |
| TikTok (30 fps project) | 1080×1920 30 H.264 | 1080×1920 / same / 0 | 30.00 | 90 | 9.00 / 8 (1.126) | native portrait | — |
| TikTok (60 fps project) | 1080×1920 60 H.264 | 1080×1920 / same / 0 | 60.00 | 180 | 9.14 / 8 (1.142) | native portrait | — |
| Custom 48 fps | 1920×1080 48 H.264 | 1920×1080 / same / 0 | 48.00 | 144 | 12.98 / 12 (1.082) | n/a | — |

Every row has AAC-LC 48 kHz stereo, an A/V start and end gap of 0.0 ms, `hardwareEncoder` false with `softwareEncoder` announced, and a result duration of exactly 3,000,000 µs.

No encoder on the simulator refused a portrait size, so the landscape-plus-rotation retry did not trigger. The rule is still enforced on every row:
- a rotated track must be announced with `portraitRetried` and keep the portrait display size;
- the only acceptable failure is a visible `encoderSizeLimit` on a portrait size.

The retry path itself is covered by IOS-12's `ExportCoordinatorTests` with an injected encoder probe.

### (3) Audio

| Check | Measured | Requirement | Result |
|---|---|---|---|
| (a) 2× keep-pitch | dominant 1000.0 Hz (0.00 %) | 1 kHz ± 2 % | pass |
| (a) 2× keep-pitch off | 2000.0 Hz | 2 kHz ± 2 % | pass |
| (a) 0.5× keep-pitch | 1000.0 Hz (0.00 %) | 1 kHz ± 2 % | pass |
| (a) 0.5× keep-pitch off | 500.0 Hz | 500 Hz ± 2 % | pass |
| (b) 3-lane mix vs reference (music 40 % with fades, voice keyframes 100→50→150 %, cross dissolve A→B equal-power, muted lane) | 148/150 windows compared, worst Δ −0.057 dB; muted lane at 3 kHz −120 dBFS | ±0.5 dB per 20 ms; muted < −60 dBFS | pass |
| (b) same with the voice lane soloed | 148/150 compared, worst Δ −0.126 dB; soloed out: music −120, main A −119.5, main B −120, muted −120 dBFS | ±0.5 dB; soloed out < −60 dBFS | pass |
| (c) 200 % vs 100 % | −8.966 vs −14.987 dBFS = **+6.021 dB** (reference −8.990 / −15.011) | +6.02 ± 0.1 dB | pass |
| (d) 7-point ramp seam click (1, 1.25, 1.6, 2, 1.6, 1.25, 1×; 300 ms each; keep pitch) | residual floor 0.00139, seams 0.00492 / 0.00358 / 0.00280 / 0.00290 / 0.00349 / 0.00491, worst excess **−49.0 dBFS** | ≤ −40 dBFS above the tone | pass |
| (e) preview PCM | not capturable from Dart | — | deferred (see below) |

## Deferred

- **Android emulator, API 35: deferred to the Windows lane.** The same three files run unchanged. On the Windows laptop, branch `editor-android`, from `packages/danaview_editor_engine/example`:
  ```
  flutter test integration_test/conformance_test.dart   -d emulator-5554
  flutter test integration_test/preset_matrix_test.dart -d emulator-5554
  flutter test integration_test/audio_mix_test.dart     -d emulator-5554
  ```
  Paste the `QA11|…` lines into a "Results: Android emulator" section of this report.
- **(e) Preview PCM, Android: deferred to the Windows lane.** The debug audio-sink tap is part of AND-xx.
- **(e) Preview PCM, iOS: covered natively, not from Dart.** No engine API exposes the preview mix. `example/ios/RunnerTests/AudioTap/GainTapPlayerTests` (IOS-18) renders the AVPlayerItem mix offline and checks it against the same API-03 vectors.
- **Low and mid lab devices (iPhone 7 / 8 / SE 2 / 12, 2–3 GB Android Go, 4 GB Android): deferred, no device available.** Run the same commands with `-d <device>`. On devices, also check:
  - `hardwareEncoder` is true;
  - the HEVC and 4K rows, where `hevcEncode` is true;
  - whether an encoder refuses a portrait size, which exercises the rotation retry.

## Findings

- **IOS-12 sets `AverageBitRate` only (no `DataRateLimits`).** With per-pixel full-resolution noise, the simulator's software H.264 overshot by 1.20× at 30 fps and 1.64× on TikTok at 60 fps (13.1 Mbps against 8). With encodable high-detail content every preset lands at 0.94–1.15×. This should be re-checked on the device lab with real high-detail footage. If hardware encoders also overshoot, IOS-12 should add a `DataRateLimits` cap (a FIX ticket).
- **Every export's AAC track runs 50.7 ms past its edit list in media time** (priming plus the final frame). The edit list trims it to exactly the video's length. Any reader that ignores edit lists would see a 50 ms A/V length mismatch.
- **CI runs only `engine_smoke_test.dart`.** `scripts/ci/editor/ios.sh` and `android_emulator.sh` (owner ENG-09) do not run the QA-11 suites yet, so "green in CI" needs those scripts to call the three files above.
