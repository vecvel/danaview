# IOS-01 spike report: iOS engine de-risking (AVFoundation + Core Image on Metal)

Ticket: BUILD_PLAN §6 IOS-01 (M1, D-42). Spike host: `spikes/ios_engine/` (throwaway Xcode host
app + XCTest + UI test + a throwaway Flutter app; not shipped, not part of any package).
Consumer: **ENG-06** (applies the build settings in §3 and records the V-N outcomes in ARCHITECTURE
§5/§12.5/§13/§14.2/§24.2), then IOS-02…IOS-18.

Status as of 2026-10-10. Machine: MacBook (arm64, 8 cores, 8 GB), Xcode 26.6 (17F113), iOS 26.5
and iOS 18.2 simulators. The build machine was shared with other engineers' Gradle/Xcode builds
(load average 30–35 during the 18.2 runs), so latency numbers are upper bounds.

**No real device was used.** Owner default 2026-10-08 (D-43): there are no lab devices; iOS 15/16
are covered by `-Werror=unguarded-availability-new` + `check_ios_min_os.sh` only. Every item that
needs a real iPhone is listed as *deferred* below with what to run.

## 1. Outcome summary

| Item | Question | Outcome (simulator) | Device |
|---|---|---|---|
| V-N9 | `-fcikernel` metallib from a CocoaPods static-library target, loaded with `CIKernel(functionName:fromMetalLibraryData:)` | **Yes.** Loads and matches the CPU reference within 1/255 on iOS 26.5 and 18.2 (static-library linkage); `[[stitchable]]` alternative also works. Metallibs are **prebuilt** (Xcode 26 ships no Metal compiler). | Device *build* (arm64 iphoneos, unsigned) via `tools/verify_pod_linkage.sh`; device *load* deferred |
| V-N10 | Exact-seek ack 200/200 with a `vwish.frame` attachment | **200/200 acked, 0 content errors** on iOS 26.5 (half-res and 1080p) and iOS 18.2 (with the Metal-texture source path, §2.4). p50 18–23 ms, p95 26–89 ms. | iPhone 7 / iOS 15.8: deferred (no lab device) |
| V-N11 | iOS background GPU failure mode | Simulator does not reproduce GPU/encoder loss. Harness ready (`BackgroundExperiment` + `VWSpikeBackground` UI tests). | Deferred: real iPhone on iOS 18 and 26 |
| V-N20 | Export backgrounded > 30 s: encoder error, writer status, segmented resume, `BGTaskScheduler.supportedResources.contains(.gpu)` | Segmented writer interrupt + resume + passthrough concat proven frame-exact (90/90, SPS/PPS shared). `supportedResources` is logged by the harness. | Deferred: real iPhone on iOS 18 and 26 |
| V-N21 | `MTAudioProcessingTap` sees composition-time ranges after `scaleTimeRange`; gain 2.0 = +6.02 ± 0.1 dB in AVPlayer and AVAssetReaderAudioMixOutput | **Yes, with `.timeDomain`**: +6.0206 dB in all three segments (1×, 2×, 0.5×) in the reader and +6.02 dB in AVPlayer; range starts are composition time (error ≤ 0.04 ms). **`.spectral` and `.varispeed` are broken in the reader over scaled ranges** (silence after the first rate change, occasional hangs). | Deferred (level/timing are not device-specific, but confirm once) |
| V-N22 | Metal CI kernels on a `.useSoftwareRenderer` CIContext, ≥ 0.2× real time? | **Runs, output identical** (barcode decodes, mean diff 0). Simulator speed at 1080p: look 12.4× RT (iOS 26) / 14.4× (18.2), look + blur σ4 2.75× / 2.3×. Simulator CPU is the Mac's, so the speed is not representative. | Deferred: device speed decides the D-22 software background path |
| V-N23 | Preview A/V latency through a Flutter texture | Native half: `itemTime(forHostTime: targetTimestamp)` picks the right frame (offset 16.5 ms p50, max 27 ms at 30 fps = inside one frame). Flutter half: see §2.8. | Deferred: device numbers |
| D-35 | Grid timing: edits at `CMTime(k, 30)`, cuts at k ≡ 1, 2 (mod 3), compositor `k = round(t × fps)` | **100%**: export 90/90 composited and encoded frames correct; exact seek 90/90; playback every delivered frame correct incl. cut frames 30–32, 60–62. Control: a µs grid shows frame 32 wrong. | n/a |
| Texture | AVPlayerItemVideoOutput → FlutterTexture-style `copyPixelBuffer` zero-copy | **Zero-copy**: same IOSurface as the compositor's render buffer 4/4, wraps as `MTLTexture` via `CVMetalTextureCache` 4/4. | n/a |
| Redraw | Redraw-from-cache of the last source buffers ≤ 30 ms | **p50 15.2 ms, p95 22.2 ms** (1080p, 2 layers, look + blur toggling, iOS 26). One-off 1–3 s outlier on the first blur render (kernel pipeline compile) → pre-warm at session start. | Device numbers deferred |
| HDR | HLG source with `supportsHDRSourceFrames = false` arrives as SDR | **Yes**: compositor receives `BGRA` tagged `ITU_R_709_2`; HLG 0.50 → 97, 0.75 → 154 (neutral). | n/a |
| Export | AVAssetReader(composition) → AVAssetWriter with the same compositor | **Yes**: grid case 90/90 frames in order, all correct after encode + read-back. | n/a |

Test status (XCTest `VWSpikeTests`, 24 tests incl. diagnostics): **all green on the iOS 26.5
simulator**; iOS 18.2: see §4 (final run). Raw measurements: `spikes/ios_engine/results/*.metrics.jsonl`
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
| iOS 18.2 sim | 960×540 | 200/200 | 0 (Metal-texture sources) | see §4 | |
| iOS 18.2 sim | 1920×1080 | 200/200 | 0 (Metal-texture sources) | see §4 | |

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
  new params on its render queue into its own pool. iOS 26.5: p50 15.2 ms, p95 22.2 ms over 60
  redraws (1080p, 2 layers, look changes, blur 0 ↔ 4), 59/60 visibly changed. The **first** blur
  render took 1–3 s (CI pipeline compile of the blur kernel on a loaded machine): **pre-warm every
  kernel once at session start** (render a 16×16 image through each kernel) so the first paused
  edit stays ≤ 30 ms.
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
  18.2 p95 4.4 ms). The first ticks after `play()` can deliver one stale frame (up to 750 ms on the
  loaded machine) — hold the paused frame until the first new one arrives.
- Flutter texture (spikes/ios_engine/flutter_texture_latency, run by `tools/run_texture_latency.sh`):
  see §4 for the measured texture latency and the compensated A/V offset.

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
  `tools/verify_pod_linkage.sh` (result in §4).
- Info.plist (app): `UIBackgroundModes` not needed for the iPhone `paused` kind; iPad `continued`
  needs `BGTaskSchedulerPermittedIdentifiers` covering `com.vecvel.vwish.export.*` and Apple's GPU
  continued-processing entitlement (exact key to be taken from the iOS 26 SDK when IOS-13 enables
  it) — enable only after the device run of V-N20; the spike did not exercise it.
- No Pigeon change is required by this spike. Pass to IOS-08/09/12/18 (not ENG-06): retain
  `AVURLAsset`s (§2.2), Metal-texture source images (§2.4), kernel pre-warm (§2.5), `.timeDomain`,
  `range.start` + frames, zero-fill on tap errors and audio trim (§2.7).

## 4. Final runs

(Filled from the last complete runs; see the bottom of this file.)

## 5. Deferred (needs a real device)

All need a signed build on a physical iPhone; the host app and UI tests are ready
(`VWSpikeHost` scheme for XCTest, `VWSpikeBackground` scheme for the background UI tests; launch
arguments `-vwExperiment plain|bgtask|segmented -vwSeconds 120` for a manual run, log written to
`Documents/background_experiment.log`).

- **V-N9 device load**: run `KernelTests` on any arm64 iPhone (the iphoneos metallib is built and
  bundled; only the load on hardware is unverified).
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
tools/build_metallibs.sh                             # only when kernel sources change (needs a Metal toolchain)
```
