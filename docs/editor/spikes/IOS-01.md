# IOS-01 spike report: iOS engine de-risking (AVFoundation + Core Image on Metal)

Ticket: BUILD_PLAN §6 IOS-01 (M1, D-42). Spike host: `spikes/ios_engine/` (throwaway Xcode host
app + XCTest + UI test + a throwaway Flutter app; not shipped, not part of any package).
Consumer: **ENG-06** (applies the build settings in §3 and records the V-N outcomes in ARCHITECTURE
§5/§12.5/§13/§14.2/§24.2), then IOS-02…IOS-18.

Status as of 2026-10-11. Machine: MacBook (arm64, 8 cores, 8 GB), Xcode 26.6 (17F113), iOS 26.5
and iOS 18.2 simulators. The build machine was shared with other engineers' Gradle/Xcode builds
(load average 30–35 during the 18.2 runs), so latency numbers are upper bounds.

**No real device was used.** Owner default 2026-10-08 (D-43): there are no lab devices; iOS 15/16
are covered by `-Werror=unguarded-availability-new` + `check_ios_min_os.sh` only. Every item that
needs a real iPhone is listed as *deferred* below with what to run.

## 1. Outcome summary

| Item | Question | Outcome (simulator) | Device |
|---|---|---|---|
| V-N9 | `-fcikernel` metallib from a CocoaPods static-library target, loaded with `CIKernel(functionName:fromMetalLibraryData:)` | **Yes.** Loads and matches the CPU reference within 1/255 on iOS 26.5 and 18.2 (static-library linkage); `[[stitchable]]` alternative also works. Metallibs are **prebuilt** (Xcode 26 ships no Metal compiler). | Device *build* OK (arm64 iphoneos, unsigned, all 3 linkages, `tools/verify_pod_linkage.sh`); device *load* deferred: no device available |
| V-N10 | Exact-seek ack 200/200 with a `vwish.frame` attachment | **200/200 acked, 0 content errors** on iOS 26.5 (half-res and 1080p) and iOS 18.2 (with the Metal-texture source path, §2.4). Final runs p50 11.6–14.0 ms, p95 17.2–21.6 ms, all ≤ 70 ms (earlier loaded runs up to p95 89 ms). | iPhone 7 / iOS 15.8: deferred (no lab device) |
| V-N11 | iOS background GPU failure mode | **Simulator does not reproduce it** (measured, `VWSpikeBackground` on iOS 26.5): GPU export keeps running in the background with `backgroundTimeRemaining` = `Double.greatestFiniteMagnitude`, no encoder or Metal error, writer `.completed` (§2.6). | Deferred: real iPhone on iOS 18 and 26 (no device available) |
| V-N20 | Export backgrounded > 30 s: encoder error, writer status, segmented resume, `BGTaskScheduler.supportedResources.contains(.gpu)` | Segmented writer interrupt + resume + passthrough concat proven frame-exact (XCTest 90/90, SPS/PPS shared; UI test: interrupted on `didEnterBackground`, resumed on return, 1200/1200 frames). Simulator (iPhone 17 Pro, iOS 26.5): `supportedResources.contains(.gpu)` = **false**; plain and `beginBackgroundTask` exports complete in the background (writer status 2, no error) — not device behaviour. | Deferred: real iPhone on iOS 18 and 26 (no device available) |
| V-N21 | `MTAudioProcessingTap` sees composition-time ranges after `scaleTimeRange`; gain 2.0 = +6.02 ± 0.1 dB in AVPlayer and AVAssetReaderAudioMixOutput | **Yes, with `.timeDomain`**: +6.0206 dB in all three segments (1×, 2×, 0.5×) in the reader and +6.02 dB in AVPlayer; range starts are composition time (error ≤ 0.04 ms). **`.spectral` and `.varispeed` are broken in the reader over scaled ranges** (silence after the first rate change, occasional hangs). | Deferred (level/timing are not device-specific, but confirm once) |
| V-N22 | Metal CI kernels on a `.useSoftwareRenderer` CIContext, ≥ 0.2× real time? | **Runs, output identical** (barcode decodes, mean diff 0). Simulator speed at 1080p: look 11.7× RT, look + blur σ4 2.8× (iOS 26.5 final run, fixed blur DOD; earlier 18.2 run 14.4× / 2.3×). Simulator CPU is the Mac's, so the speed is not representative. | Deferred: device speed decides the D-22 software background path |
| V-N23 | Preview A/V latency through a Flutter texture | Native half: `itemTime(forHostTime: targetTimestamp)` picks the right frame (offset 16.5 ms p50, max 27 ms at 30 fps = inside one frame). Flutter texture adds **exactly one vsync** (16.67 ms at 60 Hz); compensated A/V offset 10–14 ms mean, 148/148 and 146/147 frames within ≤ 1 frame / ≤ 40 ms (§2.8). `FrameTiming` is in `CLOCK_MONOTONIC_RAW`, not `CACurrentMediaTime`. | Deferred: device numbers (60/120 Hz, audio routes) |
| D-35 | Grid timing: edits at `CMTime(k, 30)`, cuts at k ≡ 1, 2 (mod 3), compositor `k = round(t × fps)` | **100%**: export 90/90 composited and encoded frames correct; exact seek 90/90; playback every delivered frame correct incl. cut frames 30–32, 60–62. Control: a µs grid shows frame 32 wrong. | n/a |
| Texture | AVPlayerItemVideoOutput → FlutterTexture-style `copyPixelBuffer` zero-copy | **Zero-copy**: same IOSurface as the compositor's render buffer 4/4, wraps as `MTLTexture` via `CVMetalTextureCache` 4/4. | n/a |
| Redraw | Redraw-from-cache of the last source buffers ≤ 30 ms | **p50 15.4 ms, p95 20.6 ms** (final run; 1080p, 2 layers, look + blur toggling, iOS 26.5, host load 12). One-off 1–3 s outlier on the first blur render (kernel pipeline compile) → pre-warm at session start. | Device numbers deferred |
| HDR | HLG source with `supportsHDRSourceFrames = false` arrives as SDR | **Yes**: compositor receives `BGRA` tagged `ITU_R_709_2`; HLG 0.50 → 97, 0.75 → 154 (neutral). | n/a |
| Export | AVAssetReader(composition) → AVAssetWriter with the same compositor | **Yes**: grid case 90/90 frames in order, all correct after encode + read-back. | n/a |
| Blur DOD | (found by the spike) placed + blurred layer | **Bug found and fixed**: a general Metal CI kernel that samples a `clampedToExtent()` input must declare an **infinite** output extent and then crop; declared at the source extent, Core Image dropped the crop and a scaled/translated blurred PiP covered the whole canvas (§2.5). | n/a |

Test status (XCTest `VWSpikeTests`, 26 tests incl. diagnostics): **26/26 green on the iOS 26.5
simulator** (final run 2026-10-11) and on the iOS 18.2 simulator (§4); `VWSpikeBackground`
UI tests 3/3 green on iOS 26.5 (§2.6). Raw measurements: `spikes/ios_engine/results/*.metrics.jsonl`
(git-ignored; regenerate with `tools/run_spike_tests.sh`).

## 2. Details and findings

### 2.1 V-N9: precompiled Metal Core Image kernels in a CocoaPods target

- Xcode 26 no longer ships the Metal compiler; `xcrun metal` fails with "missing Metal Toolchain"
  unless the optional component is installed (`xcodebuild -downloadComponent MetalToolchain`,
  ~700 MB). The app build must therefore **not** compile `.metal` files. The kernels are compiled
  ahead of time by `tools/build_metallibs.sh` into one metallib per SDK and committed:
  - `-fcikernel` kernels: `metal -c -fcikernel -target air64-apple-ios15.0[-simulator] -isysroot <sdk>`
    then `metallib -cikernel` → `vw_spike_kernels.{iphoneos,iphonesimulator}.metallib` (8,396 bytes each).
  - `[[stitchable]]` kernels: `metal -c` then link with `metal -framework CoreImage` (plain
    `metallib` fails with "Undefined symbol: _ZNK9coreimage7Sampler6sampleEDv2_f").
  - The prebuilt metallibs used here were built with Apple metal 32023.883 from the 26.4 toolchain
    asset already on disk (`/System/Library/AssetsV2/com_apple_MobileAsset_MetalToolchain`), mounted
    read-only; `BUILD_INFO.txt` next to each metallib records source and output SHA-256.
- The simulator needs its own metallib (`air64-apple-ios15.0-simulator`); the loader picks
  `<name>.iphonesimulator` / `<name>.iphoneos` with `#if targetEnvironment(simulator)`.
- A static library cannot carry resources: the metallibs ship in a **resource bundle**
  (`s.resource_bundles`) and are found at `VWSpikeHost.app/VWSpikeKernels.bundle/…` (static lib)
  or inside the framework bundle (`use_frameworks!`). Kernel creation from the data: 1.5–3 ms.
- Both `-fcikernel` (`CIColorKernel` + general `CIKernel` with ROI callbacks) and `[[stitchable]]`
  load and render correctly. **Recommendation: keep `-fcikernel`** (ARCH §13.2) — no runtime
  difference, and it avoids the CoreImage link step.

### 2.2 Composition, spacer and compositor

- **Spacer**: a runtime-generated 16×16 one-frame video. On the simulator there is no JPEG/PhotoJPEG
  encoder (`-11834 Cannot Encode`), H.264 and HEVC both work (`.mov` and `.mp4`). Use **H.264, no
  compression properties**, written to `spacer_16x16_v1.mov` (as ARCH §13.2).
- **Finding (affects IOS-08):** the `AVURLAsset` must be kept alive while its tracks are inserted;
  holding only the `AVAssetTrack` makes every `insertTimeRange` fail with AVFoundation `-11800` /
  Fig `-12780`. `CompositionBuilder` must retain the assets for the lifetime of the composition.
- Instructions validated with `isValid(for:timeRange:validationDelegate:)`; boundaries
  `[0, 31, 32, 61, 62]` all with timescale 30; build 19 ms.

### 2.3 D-35 grid timing (fixture `grid_cuts_30fps.json` from CORE-29)

Edit points `CMTime(k, 30)`, source ranges µs + ε (500 µs), cuts at frames 31/61 (≡ 1 mod 3) and
32/62 (≡ 2 mod 3), PiP on sequence 1 from 32 to 62. Results (iOS 26.5): export 90/90 stamps 0…89
in order, 90/90 composited and 90/90 encoded frames correct, activity matches the expected-active
table; exact seek to every k 90/90 (p50 7.4 ms); playback delivered 91 distinct frames, all
correct, cut frames 30, 31, 32, 60, 61, 62 seen. The same plan built with µs `CMTime`s shows frame
32 wrong (control), confirming D-35 rule 2.

### 2.4 V-N10 exact seek and the iOS 18.2 two-source finding

`seek(to: CMTime(k, 30), toleranceBefore/After: .zero)` with
`seekingWaitsForVideoCompositionRendering = true`, then poll `AVPlayerItemVideoOutput` until the
buffer's `vwish.frame` attachment == k. The attachment set with `.shouldPropagate` survives the
video output (same buffer). 200 seeded random seeks over an 8 s 1080p30 composition with a 720p25
PiP over [2 s, 6 s):

| Destination | Render | Acked | Content errors | p50 / p95 / max (ms) | ≤ 500 ms |
|---|---|---|---|---|---|
| iOS 26.5 sim | 960×540 | 200/200 | 0 | 17.9 / 30.0 / 49 | 200 |
| iOS 26.5 sim | 1920×1080 | 200/200 | 0 | 19.3 / 28.3 / 36 | 200 |
| iOS 18.2 sim | 960×540 | 200/200 | 0 (Metal-texture sources) | 15.5 / 23.4 / 44 | 200 |
| iOS 18.2 sim | 1920×1080 | 200/200 | 0 (Metal-texture sources) | 17.6 / 33.1 / 58 | 200 |

- **Query the video output with the seek target** `CMTime(k, fps)`, not `item.currentTime()`
  (both worked in the grid case, but the target is unambiguous while the compositor is still busy).
- Wait for the **first composited frame** before reporting the session ready (first frame 36–113 ms
  on iOS 26, up to 1.9 s on the loaded 18.2 run); otherwise the first user seek pays decoder start-up.
- **Finding (affects IOS-09 compositor):** on the iOS 18.2 simulator, building source images with
  `CIImage(cvPixelBuffer:)` renders the **lower layer black whenever two decoded sources are
  composited** (101/200 seeks wrong: every frame with the PiP; the base buffer itself is correct —
  its barcode decodes from the CPU side). The same composite offline with synthetic buffers is
  correct, a CPU copy of the sources fixes it, and so does the zero-copy path
  **`CVMetalTextureCacheCreateTextureFromImage` → `CIImage(mtlTexture:)`** (flip y), which is now the
  spike's default and is 200/200 on 18.2 and 26.5. iOS 26.5 is correct with either path.
  Recommendation: VWCompositor builds source images through a `CVMetalTextureCache` (keep the
  `CVMetalTexture` alive until the render task completes). Whether real iOS 18 devices show the
  bug is unknown (deferred), but the Metal path costs nothing.
  `ExactSeekTests.testDirectPixelBufferSourcesDiagnostic` keeps measuring the direct path.

### 2.5 Texture zero-copy, redraw-from-cache, HDR

- Video output attributes identical to the compositor's (`32BGRA`, IOSurface, Metal-compatible):
  the buffer handed out by `copyPixelBuffer` is the compositor's render-context buffer (same
  IOSurface ID 4/4) and wraps as a Metal texture without a copy.
- Redraw-from-cache: the compositor keeps the last request's source buffers and re-renders with
  new params on its render queue into its own pool. iOS 26.5 (final run, after the blur fix
  below): p50 15.4 ms, p95 20.6 ms, max 24.8 ms over 60 redraws (1080p, 2 layers, look changes,
  blur 0 ↔ 4; look only p50 5.1 ms, look + blur σ4 p50 18.2 ms), 59/60 visibly changed. The **first** blur
  render took 1–3 s (CI pipeline compile of the blur kernel on a loaded machine): **pre-warm every
  kernel once at session start** (render a 16×16 image through each kernel) so the first paused
  edit stays ≤ 30 ms.
- **Finding (affects IOS-03 kernels and IOS-09 compositor): kernel extent (DOD) with clamped
  inputs.** `vw_blur_h/v` sample `image.clampedToExtent()`, so their output is non-zero
  everywhere. With the kernel output declared at the source extent (`apply(extent: extent, …)`)
  followed by `cropped(to: extent)`, Core Image treats the crop as a no-op and drops it; once the
  blurred layer was scaled/translated into its placement, it covered the **whole canvas** with its
  clamped edge pixels (a blurred PiP hid the base layer; found by the background-export run, whose
  1080p exports did not decode). An extra crop to the placement rectangle after the transform, an
  intermediate (`insertingIntermediate`) and blurring after placement all failed the same way;
  the built-in `CIGaussianBlur` in the same position was correct. **Fix: declare the honest DOD
  (`extent: .infinite`) for kernels that read clamped inputs and crop afterwards** — then every
  variant is correct (`KernelTests.testTwoLayerCompositeWithBlurKeepsPlacement`: base and PiP
  barcodes decode, canvas corner stays base orange, Metal-texture and CVPixelBuffer sources). The
  rule applies to every production kernel that samples outside the destination pixel
  (`vw_blur_h/v`, `vw_sharpen`, `vw_reveal` if it reads neighbours). Earlier redraw/V-N22
  measurements only checked content on unblurred frames, which is why this was missed.
- HLG (HEVC Main10, BT.2020/HLG, generated with VideoToolbox on the simulator; ffmpeg fallback
  script `tools/make_hlg_fixture.sh`): with `supportsHDRSourceFrames = false` the compositor
  receives `BGRA` tagged `ITU_R_709_2` (tone-mapped to SDR by AVFoundation); HLG 0.50/0.75 render
  as 97/154, neutral.

### 2.6 Export and the segmented writer (IOS-12/IOS-17)

- AVAssetReader(composition) + `AVAssetReaderVideoCompositionOutput` (same compositor) →
  AVAssetWriter H.264 High AutoLevel, `MaxKeyFrameIntervalDuration` 1 s,
  `AllowFrameReordering = false`: the grid case exports 90/90 frames correct (3.2 s on iOS 26).
- Segmented export (30-frame segments): interrupted 10 frames into segment 1 → checkpoint keeps
  `[0]`, the partial segment is deleted; resume renders only frames 30…89; every segment starts with
  a sync sample; passthrough concat (`AVAssetReaderTrackOutput(nil)` → one writer input with the
  first segment's format description as `sourceFormatHint`) gives 90 frames on the grid, all correct,
  duration exactly 3.000 s, SPS/PPS identical across segments.
- **Background export on the simulator (V-N11/V-N20 harness, `VWSpikeBackground` UI tests,
  iPhone 17 Pro simulator, iOS 26.5, `TEST_RUNNER_VW_SECONDS=40` = 1200 frames of 1080p30, base +
  PiP, look + blur σ4, Home pressed during the export, ~30 s in the background):**
  device facts logged `BGTaskScheduler.supportedResources.contains(.gpu)=false`, idiom phone.

  | Mode | In background | Outcome |
  |---|---|---|
  | `plain` (one writer, no task) | `backgroundTimeRemaining` = 1.8e308; frames kept flowing (157 → 256 in 34.5 s on a host at load 30+) | writer status 2 (`.completed`), no error, 1200 frames |
  | `bgtask` (`beginBackgroundTask`) | same; no expiration handler call | `.completed`, no error, 1200 frames |
  | `segmented` (IOS-17 policy: stop on `didEnterBackground`) | open segment 1 discarded, checkpoint `[0]` | resumed on return from segment 1; concat 1200/1200 frames with the correct barcode |

  The simulator never suspends the app or takes the GPU/encoder away, so it **cannot answer
  V-N11/V-N20**; it only proves the harness and the segmented interrupt → resume → concat path
  end to end. The first runs exposed two harness problems, both fixed: the status label never
  reached "done" (the UI test waited 600 s), and the blurred export did not decode (the blur DOD
  bug of §2.5; 0/1200 before the fix, 1200/1200 after).

### 2.7 V-N21 audio tap (D-37) — and a pitch-algorithm finding

Composition: one 1 kHz −12 dBFS tone in three segments: [0,1) ← src [0,1) 1×, [1,2) ← src [3,5)
2×, [2,4) ← src [6,7) 0.5× (`scaleTimeRange`). Tap = `MTAudioProcessingTap` (post-effects) that
multiplies by 2.0.

- **AVAssetReaderAudioMixOutput with `.timeDomain`**: +6.0206 dB in every segment, absolute level
  −8.99 dB RMS as expected, tap format Float32 non-interleaved 48 kHz stereo, maxFrames 4096,
  512-frame calls. Tap range **starts are composition time** (max error vs the output sample
  position 0.04 ms). The range **duration reported inside scaled segments is not composition time**
  (it is scaled by the rate again: 4× at 2×, ¼ at 0.5×); the production `GainTap` must advance by
  `numberFrames / sampleRate` from `range.start`, never use `range.duration`.
- **AVPlayer**: +6.02 dB pre- and post-effects, input arrives at the source level (−15.01 dB),
  ranges monotonic composition time; the first call has an invalid range (handle it: treat as
  "evaluate at the last known time"). The tap runs 150–280 ms ahead of the item clock (buffering);
  live envelope swaps take effect with that delay in preview.
- **Finding (affects IOS-18, IOS-12, ARCH §13.2/§14.2):** in AVAssetReaderAudioMixOutput over scaled
  ranges, **`.spectral` goes silent after the first rate change** (0/12 complete reads on both
  simulators; Fig logs "AppendRateChange: scheduling rate change … but we previously did a
  conversion"), and occasionally **hangs in `copyNextSampleBuffer`**. `.varispeed` is broken the same
  way on iOS 26.5 (fine on 18.2). **`.timeDomain` is complete and deterministic**: 12/12 per source
  format (Float32 WAV, AAC, WAV with gaps) with and without tap on both simulators; reliability run
  30/30 on 18.2; one silent read in ~70 on iOS 26.5 (see below). Recommendation: **use
  `.timeDomain` for keep-pitch** on both the export reader and the preview item (same sound in both).
  The keep-pitch FFT check of QA-11 still applies (time-domain stretching keeps pitch).
- Reader output length with `.timeDomain` is 4.01–4.10 s for a 4.0 s composition (overlap-add tail):
  the export must end the audio at the composition duration (`endSession(atSourceTime:)` / trim).
- Seam alignment (40 ms gap markers): 1× exact, 2× +10 ms, 0.5× −29.5 ms, identical in every read.
  This is time-stretch grain placement inside slowed segments, not drift: within the 1-frame
  preview tolerance, but **above the 20 ms export A/V target of §14.4 inside 0.5× segments** —
  QA-11/IOS-18 should measure A/V offset at segment starts, not inside stretched audio.
- Robustness: one read in ~70 `.timeDomain` + tap reads on iOS 26.5 came back silent/NaN from the
  start (once with NaN samples). The tap must zero-fill its buffers when
  `MTAudioProcessingTapGetSourceAudio` fails (never hand on garbage), and IOS-12 should validate the
  rendered audio (NaN or a fully silent read while the plan has audible audio → redo the read once).
- **D-37 premise check:** `AVMutableAudioMixInputParameters.setVolume(2.0)` **does amplify** (+6.02 dB)
  in AVAssetReaderAudioMixOutput on both simulators. The tap stays the design (sample-exact
  envelopes, same code in preview and export), but the D-37 rationale should say "not relied on"
  rather than "only attenuates".

### 2.8 V-N23 preview A/V latency

- Native: a `CADisplayLink` at 30 fps asking `itemTime(forHostTime: targetTimestamp)` gets the frame
  whose interval contains the target item time: offset p50 16.5 ms, range 16.5–27.2 ms (iOS 26.5;
  18.2 p95 4.4 ms; final runs 3.8 ms on 26.5 and 12.4 ms on 18.2, 0 stalls — the value is the
  phase between the 30 fps frame grid and the display link, always inside one frame). The first ticks after `play()` can deliver one stale frame (up to 750 ms on the
  loaded machine) — hold the paused frame until the first new one arrives.
- Flutter texture (spikes/ios_engine/flutter_texture_latency, run by `tools/run_texture_latency.sh`;
  Flutter 3.44.2, Impeller, debug build on the iOS 26.5 simulator at 60 Hz, 30 fps content):
  AVPlayer + `AVPlayerItemVideoOutput` + `CADisplayLink` → `FlutterTexture.copyPixelBuffer`; Dart
  returns `FrameTiming`s, and for every texture frame the display time is the first display-link
  target after the raster that sampled it. Findings for the production
  `DisplayLinkDriver`/latency measurement (IOS-10/IOS-11):
  - **Clock domain**: `FrameTiming` timestamps are the engine's `fml::TimePoint` =
    `CLOCK_MONOTONIC_RAW` (counts sleep); `CADisplayLink`/`CACurrentMediaTime` are
    `mach_absolute_time` (does not). The difference is the device's accumulated sleep (26,632 s on
    this Mac). Convert with an offset sampled natively (`clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)`
    − `CACurrentMediaTime()`); after conversion Dart `vsyncStart` lands on the native display-link
    timestamp with 0 ms residual (p95 0 ms).
  - **Texture-only frames report no `FrameTiming`**: `textureFrameAvailable` re-rasterizes the last
    layer tree without a Dart frame and produces no timing (0–3 timings in 5 s). The measurement
    must run while something rebuilds per vsync (the playhead painter during playback does).
  - Results (3 runs; 147–151 matched texture frames per phase): **texture latency = exactly one
    vsync** (16.67 ms p50 and p95 in every run). Uncompensated A/V offset at a frame's first
    display: 26.7 / 31.2 / 27.8 ms (p50 / mean / mean). **Compensated with
    `targetTimestamp + 16.67 ms`: 10.0 / 14.2 / 11.9 ms**; within ≤ 1 frame and ≤ 40 ms:
    run 1 p95 |offset| 10.0 ms (max 48.2), run 2 148/148, run 3 146/147 (one stalled frame at
    97.8 ms on the shared host). The residual 10–14 ms is the 30 fps / 60 Hz
    phase (a 30 fps frame is shown for two vsyncs), not a latency error. Recommendation confirmed:
    measure once per session, compensate with `itemTime(forHostTime: targetTimestamp + latency)`.
  - The simulator composites without the device render-server/panel pipeline and has no
    ProMotion; the device number (60 Hz and 120 Hz, wired and Bluetooth audio routes;
    `AVAudioSession.outputLatency` was 0.1 ms on the simulator) is deferred (§5).

## 3. Build settings ENG-06 must apply (vwish_editor_engine podspec)

```ruby
s.platform         = :ios, '15.0'
s.frameworks       = 'AVFoundation', 'CoreImage', 'CoreMedia', 'CoreVideo', 'Metal',
                     'MediaToolbox', 'VideoToolbox', 'BackgroundTasks'
# Prebuilt Core Image kernels (no Metal compiler in the app build; Xcode 26 ships none):
s.resource_bundles = { 'VWEditorKernels' => ['Kernels/Prebuilt/*.metallib'] }
s.preserve_paths   = 'Kernels/*.ci.metal', 'Kernels/Prebuilt/BUILD_INFO.txt'
s.pod_target_xcconfig = {
  'DEFINES_MODULE' => 'YES',
  'OTHER_CFLAGS' => '$(inherited) -Werror=unguarded-availability-new',   # D-41
}
```

- Kernel build (developer step, not Xcode): `metal -c -fcikernel -target air64-apple-ios15.0 …`
  and `-target air64-apple-ios15.0-simulator …`, then `metallib -cikernel`, one metallib per SDK
  (`vw_kernels.iphoneos.metallib`, `vw_kernels.iphonesimulator.metallib`); a script equivalent to
  `spikes/ios_engine/tools/build_metallibs.sh` plus a CI check that `BUILD_INFO.txt`'s source hash
  matches the `.ci.metal` source. Do **not** use `MTL_COMPILER_FLAGS`/`MTLLINKER_FLAGS` build
  settings (they need the Metal Toolchain on every build machine).
- Loader: `Bundle(for:)` → `VWEditorKernels.bundle`, pick `.iphonesimulator`/`.iphoneos` with
  `#if targetEnvironment(simulator)`, `CIKernel(functionName:fromMetalLibraryData:)` /
  `CIColorKernel(functionName:fromMetalLibraryData:)`.
- Works with static libraries and with `use_frameworks!` (static and dynamic): verified by
  `tools/verify_pod_linkage.sh` — 6/6 Release builds OK (library, static and dynamic linkage ×
  iphonesimulator and iphoneos, unsigned); the bundle lands at `VWSpikeHost.app/VWSpikeKernels.bundle/`
  (library, static) or `VWSpikeHost.app/Frameworks/VWSpikeKernels.framework/VWSpikeKernels.bundle/`
  (dynamic), so the loader must use `Bundle(for: <class in the pod>)`, never `Bundle.main`. Both
  per-SDK metallibs ship in every build (8 KB each); acceptable, no per-SDK resource filtering needed.
- Info.plist (app): `UIBackgroundModes` not needed for the iPhone `paused` kind; iPad `continued`
  needs `BGTaskSchedulerPermittedIdentifiers` covering `com.vecvel.vwish.export.*` and Apple's GPU
  continued-processing entitlement (exact key to be taken from the iOS 26 SDK when IOS-13 enables
  it) — enable only after the device run of V-N20; the spike did not exercise it.
- No Pigeon change is required by this spike. Pass to IOS-03/08/09/10/12/18 (not ENG-06): retain
  `AVURLAsset`s (§2.2), Metal-texture source images (§2.4), kernel pre-warm and the **infinite
  DOD + crop rule for kernels that sample clamped inputs** (§2.5), `.timeDomain`, `range.start` +
  frames, zero-fill on tap errors and audio trim (§2.7), `FrameTiming` clock conversion
  (`CLOCK_MONOTONIC_RAW` → `CACurrentMediaTime`) and measuring texture latency only while Dart
  frames are produced (§2.8).

## 4. Final runs

Last complete runs, 2026-10-11, with the final spike code (blur DOD fix included). Host load
averages are recorded per metric because the Mac was shared with other engineers' builds.

| Run | Destination | Result | Log |
|---|---|---|---|
| XCTest `VWSpikeTests` (26 tests) | iOS 26.5 sim (iPhone 17 Pro), load 9–15 | **26/26 passed** | `results/ios26-final.*` |
| XCTest `VWSpikeTests` (26 tests) | iOS 18.2 sim (iPhone 16 Pro), load 17–43 | **26/26 passed** | `results/ios18.2-final.*` |
| UI tests `VWSpikeBackground` (3) | iOS 26.5 sim | **3/3 passed** (plain, bgtask before the blur fix; segmented after it, 1200/1200 frames) | `results/ios26-background*.log` |
| `run_texture_latency.sh` (Flutter, V-N23) | iOS 26.5 sim, 60 Hz | 3 runs, numbers in §2.8 | `results/ios26*.texture_latency.jsonl` |
| `verify_pod_linkage.sh` (V-N9) | library / static / dynamic × iphonesimulator / iphoneos | **6/6 BUILD OK**, metallibs bundled in each | `results/linkage.summary.txt` |

Key numbers (iOS 26.5 / iOS 18.2):

| Measurement | iOS 26.5 | iOS 18.2 |
|---|---|---|
| Grid cuts (D-35): export composited/encoded correct | 90/90, 90/90 | 90/90, 90/90 |
| Grid cuts: exact seek to every k | 90/90 acked, 0 errors | 90/90 acked, 0 errors |
| Grid cuts: playback, cut frames 30–32/60–62 seen | 91 delivered, 0 errors | 88 delivered, 0 errors |
| µs-grid control | frame 32 wrong (expected) | frame 32 wrong (expected) |
| Exact seek 200 (half-res) p50 / p95 / max ms | 12.1 / 17.9 / 25.5, 200/200, 0 errors | 11.6 / 17.2 / 69.3, 200/200, 0 errors |
| Exact seek 200 (1080p) p50 / p95 / max ms | 12.7 / 19.5 / 27.3, 200/200, 0 errors | 14.0 / 21.6 / 55.2, 200/200, 0 errors |
| Direct `CIImage(cvPixelBuffer:)` sources (diagnostic) | 0 content errors | **101/200 content errors** (§2.4) |
| Redraw-from-cache p50 / p95 / max ms | 15.4 / 20.6 / 24.8 | 13.0 / 20.8 / 21.7 |
| Zero-copy texture (same IOSurface, Metal wrap) | 4/4, 4/4 | 4/4, 4/4 |
| HLG → SDR (`ITU_R_709_2`, 0.50/0.75) | 97 / 154 | 97 / 154 |
| Tap gain 2.0 (reader, 1× / 2× / 0.5×) | +6.0206 dB each | +6.0206 dB each |
| Tap gain 2.0 (AVPlayer, post-effects) | +6.02 dB, ranges monotonic | +6.02 dB, ranges monotonic |
| `.timeDomain` + tap reader reliability | 30/30 | 30/30 |
| Software CIContext (V-N22) look / look + blur σ4 × real time | 11.7× / 2.8× | 9.7× / 3.0× |
| Blur placement (base + PiP, σ4) | correct (all variants) | correct (all variants) |
| Display-link mapping offset (native, 30 fps) | 3.8 ms, 0 stalls | 12.4 ms, 0 stalls |
| Segmented export interrupt → resume → concat | 90/90 | 90/90 |

The ACs' "one device" run is **deferred: no device available** (owner default 2026-10-08); §5
lists exactly what to run on it.

## 5. Deferred (needs a real device)

All need a signed build on a physical iPhone; the host app and UI tests are ready
(`VWSpikeHost` scheme for XCTest, `VWSpikeBackground` scheme for the background UI tests —
default 120 s export, `TEST_RUNNER_VW_SECONDS=<n>` to change it; launch arguments
`-vwExperiment plain|bgtask|segmented -vwSeconds 120` for a manual run, log written to
`Documents/background_experiment.log`).

Owner default 2026-10-08 (D-43, revisable): no lab devices, so every item below is **deferred:
no device available**; nothing here was faked or estimated from the simulator.

- **V-N9 device load**: run `KernelTests` on any arm64 iPhone (the iphoneos metallib is built and
  bundled in all three linkages; only the load on hardware is unverified).
- **V-N10 on iPhone 7 / iOS 15.8**: deferred — no lab device (owner default 2026-10-08); iOS 15
  is covered by compile-time availability checks only.
- **V-N11 / V-N20**: real iPhone on iOS 18 and on iOS 26: `testBackgroundPlainExport`,
  `testBackgroundExportWithBackgroundTask`, `testBackgroundSegmentedExportResumes`; record the
  writer status/error code after > 30 s in the background and
  `BGTaskScheduler.supportedResources.contains(.gpu)` (logged in the first line of each run).
  The simulator does not suspend GPU work the way a device does, so it cannot answer this.
- **V-N22 speed on device**: `KernelTests.testKernelsOnSoftwareRenderer` on a device decides the
  software-CIContext background path (needs ≥ 0.2× real time at 1080p).
- **V-N23 on device**: `tools/run_texture_latency.sh` equivalent on a device (ProMotion and 60 Hz),
  with a wired/Bluetooth route to see the audio output latency.
- **iOS 18 device two-source composite** (§2.4): confirm whether `CIImage(cvPixelBuffer:)` shows the
  black-lower-layer bug on hardware (the Metal-texture path is used regardless).

## 6. How to run

```sh
cd spikes/ios_engine
tools/bootstrap.sh                                   # generate project + pod install (local pods)
tools/run_spike_tests.sh <sim-udid> ios26 -only-testing:VWSpikeTests
tools/run_texture_latency.sh <sim-udid> ios26        # V-N23 Flutter half
tools/verify_pod_linkage.sh                          # V-N9 linkage matrix incl. iphoneos build
TEST_RUNNER_VW_SECONDS=40 xcodebuild -workspace VWSpikeHost.xcworkspace -scheme VWSpikeBackground \
  -destination id=<udid> -derivedDataPath build/DerivedData test   # V-N11/V-N20 (device for real answers)
tools/build_metallibs.sh                             # only when kernel sources change (needs a Metal toolchain)
```
