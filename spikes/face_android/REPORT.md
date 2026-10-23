# VED-33A spike report: face mesh, pose and segmentation runtime on Android

- **Ticket:** VED-33A (BUILD_PLAN §4.3, ARCH V2-13, V2-14, V2-31; feeds VED-33, V2-V10, V2-V11, V2-V18)
- **Lane / date:** Windows / Android lane, 2026-10-23, base `origin/v1.2-android` d3fde363, branch
  `spike-ved33a-android`
- **Fixtures:** the 17 face fixtures from `docs/v1.2/spikes/WINDOWS_DOWNLOADS.md` §2, downloaded and verified by
  the lead in `C:/dev/models/faces/` (`SHA256SUMS` in §9). Row 10: the backlit face is visible (kept as
  backlit). Row 13: all four are adults (kept).

## 1. Verdict

| Candidate | Runs the 3 tasks | AAB download, arm64-v8a | Face / pose / seg, 1080p still (API 37 emulator) | Verdict |
|---|---|---|---|---|
| **A. MediaPipe Tasks Vision 0.10.35** (CPU) | yes, as shipped (`.task` bundles, every segmenter incl. the custom-op ones) | **+5.0 MB** | 23 / 45 / 263 ms (selfie_segmenter 35, hair_segmenter 93) | **GO (recommended)** |
| A'. MediaPipe Tasks Vision 1.1.1 | size only (not run) | +6.9 MB | not measured | not now (bigger, 9 days old, pulls `litertlm-android`) |
| **B. LiteRT 2.3.0 Interpreter** + our own pipeline | yes, through our port of MediaPipe's graphs; **cannot** run `selfie_segmenter` / `hair_segmenter` (MediaPipe custom ops) | **+2.6 MB** | 14 / 42 / 174 ms | GO as the fallback |
| **C. ONNX Runtime 1.31.0** + converted models + our own pipeline | yes, same pipeline; 2 of 8 models cannot be converted (custom ops) | **+13.0 MB** | 30 / 52 / 91 ms | no-go (size), unless shared with AIS-44 |

**Recommendation for VED-33:** MediaPipe Tasks Vision (pin 0.10.35 on Android) with `face_landmarker.task`
(478 points), `pose_landmarker_full.task` (or `_lite`), and for segmentation either `selfie_multiclass_256x256`
(person + hair in one model) or the small `selfie_segmenter` + `hair_segmenter` pair. Reasons: it is the only
candidate that runs every model as published; it is one pipeline (ROI, tracking, crops) that also exists as
MediaPipe Tasks on iOS, so cross-platform landmark parity depends on one library rather than on two
hand-written ports; and it adds only 5 MB. LiteRT with our own pipeline is the fallback if the iOS half breaks
Q-N2 (MediaPipe iOS > 8 MB): smaller and faster, but we would own the detector/ROI/tracking code on both
platforms, and our port lands 2-3.6 px from MediaPipe at 1080p (§5).

**Acceptance deviation (needs a lead decision):** the brief asks for landmark dumps committed under the spike
for iOS parity. The licence rules for these fixtures (210d06a: "never store landmarks or embeddings tied to
these files outside a test run") forbid that, so **no dumps are committed**. Every comparison was made on the
device inside one test run and only aggregates left it. §6 proposes how VED-33 can still measure iOS vs Android.

## 2. Runtime and model sizes

### 2.1 AAB download size per ABI (bundletool 1.18.3 `get-size total --dimensions=ABI`, R8 release build)

Each candidate is a product flavour of the same harness; the `none` flavour (harness only, 31 KB) is the
baseline. Models are **not** in the AAB (ARCH V2-14: the Beauty pack downloads them). MAX minus baseline
(MIN/MAX differ by < 4 KB).

| Candidate | arm64-v8a | armeabi-v7a | x86_64 | Native libs, arm64 (uncompressed = install size; stored page-aligned) | dex |
|---|---|---|---|---|---|
| MediaPipe 0.10.35 | **+5,005,711** | +4,310,975 | +5,739,660 | `libmediapipe_tasks_jni.so` 10.5 MB | 718 KB |
| MediaPipe 1.1.1 | +6,926,636 | +5,929,996 | +7,768,402 | `libmediapipe_tasks_jni.so` 14.4 MB | 748 KB |
| LiteRT 2.3.0 (Play AI-delivery deps excluded) | **+2,596,182** | +2,129,511 | +3,384,247 | `libLiteRt.so` 5.6 MB + `liblitert_jni.so` 0.5 MB | 96 KB |
| LiteRT 2.3.0, stock dependencies | +2,780,142 | +2,313,469 | +3,568,196 | same | 465 KB |
| ONNX Runtime 1.31.0 | **+12,987,575** | +11,733,942 | +15,091,554 | `libonnxruntime.so` 34.2 MB + `libonnxruntime4j_jni.so` 0.1 MB | 177 KB |

Integration notes the product will need (all found on the device; all in `app/proguard-rules.pro`):
- **MediaPipe** ships no consumer R8 rules. Without `-keep class * extends com.google.protobuf.GeneratedMessageLite { <fields>; }`,
  `-keep class com.google.mediapipe.framework.** { *; }` and `-keep class com.google.common.flogger.** { *; }`
  the release build crashes at graph creation (protobuf-lite reflection, JNI callbacks, Flogger stack walk);
  `-dontwarn com.google.mediapipe.proto.**` is needed for R8 to finish. `createFromOptions` needs a real
  `Context`. The sizes above include these rules.
- **LiteRT 2.x** pulls `com.google.android.play:ai-delivery` (asset-delivery, WorkManager, Room,
  play-services) for its optional model-download path; WorkManager's start-up initializer crashed the R8 build.
  The Interpreter needs none of it: `exclude(group = "com.google.android.play")` (measured above).
- **ONNX Runtime**'s JNI looks classes up by name: `-keep class ai.onnxruntime.** { *; }`.
- **Shared runtime with AIS-44 (V2-V18):** the stock ORT AAR is 34.2 MB arm64 uncompressed (13 MB download),
  more than sherpa-onnx's own `libonnxruntime.so` (22.2 MB, AIS-44 §6.3). Sharing pays only if AIS-44 Android
  ships ORT at all (AIS-44 recommends against the stock package) and both use one ORT build, which also means
  our own JNI to the C API instead of `onnxruntime4j`. Face tracking does not need ORT: MediaPipe and LiteRT
  both bundle TFLite/XNNPACK, and every face model is a `.tflite`.

### 2.2 Models (Beauty pack candidates; downloaded for the spike, kept outside the repo)

Source `https://storage.googleapis.com/mediapipe-models/<path>/latest/<file>` (MediaPipe model zoo); licence
Apache-2.0 per the MediaPipe model cards **[VERIFY: VED-33 records the card of each pinned file]**.

| Model (path under mediapipe-models) | Task | Bytes | SHA-256 |
|---|---|---|---|
| `face_landmarker/face_landmarker/float16/face_landmarker.task` | BlazeFace short range + 478-point mesh + blendshapes | 3,758,596 | `64184e229b263107bc2b804c6625db1341ff2bb731874b0bcc2fe6544e0bc9ff` |
| `pose_landmarker/pose_landmarker_full/float16/pose_landmarker_full.task` | pose detector + 33 (39) landmarks | 9,398,198 | `4eaa5eb7a98365221087693fcc286334cf0858e2eb6e15b506aa4a7ecdcec4ad` |
| `pose_landmarker/pose_landmarker_lite/float16/pose_landmarker_lite.task` | same, lite | 5,777,746 | `59929e1d1ee95287735ddd833b19cf4ac46d29bc7afddbbf6753c459690d574a` |
| `image_segmenter/selfie_multiclass_256x256/float32/selfie_multiclass_256x256.tflite` | background, **hair**, body skin, face skin, clothes, other | 16,371,837 | `c6748b1253a99067ef71f7e26ca71096cd449baefa8f101900ea23016507e0e0` |
| `image_segmenter/selfie_segmenter/float16/selfie_segmenter.tflite` | person (custom op `Convolution2DTransposeBias`) | 249,537 | `191ac9529ae506ee0beefa6b2c945a172dab9d07d1e802a290a4e4038226658b` |
| `image_segmenter/hair_segmenter/float32/hair_segmenter.tflite` | hair (custom ops `MaxPoolingWithArgmax2D`, `MaxUnpooling2D`, `Convolution2DTransposeBias`; RGBA 512 input) | 781,618 | `2628cf3ce5f695f604cbea2841e00befcaa3624bf80caf3664bef2656d59bf84` |
| `face_detector/blaze_face_short_range/float16/blaze_face_short_range.tflite` | = the detector inside `face_landmarker.task` | 229,746 | `b4578f35940bf5a1a655214a1cce5cab13eba73c1297cd78e1a04c2380b0152f` |
| `mediapipe-assets/face_detection_full_range.tflite` (other bucket; host check only, §5.1) | BlazeFace full range | 1,083,786 | `3698b18f063835bc609069ef052228fbe86d9c9a6dc8dcb7c7c2d69aed2b181b` |

Pack size: face 3.8 MB + pose full 9.4 MB (lite 5.8) + multiclass 16.4 MB = **29.5 MB** (25.9 with lite); with
the two small MediaPipe-only segmenters instead of multiclass: **14.2 MB** (10.6 with lite).

**ONNX conversions (candidate C only):** tf2onnx 1.17.0 (opset 17) on TensorFlow-cpu 2.21.0; host check against
the TFLite interpreter on 3 inputs, max |diff|: face detector 9e-5, face mesh 2.4e-4, pose detector 1.2e-3,
pose landmarks 1.5e-3 (full) / 3.7e-3 (lite), multiclass 3.6e-5. `pose_detector.tflite` uses `DENSIFY`
(sparse weights) that tf2onnx cannot read; `tool/densify_tflite.py` turns them into constants first.
`selfie_segmenter` and `hair_segmenter` convert but keep `TFL_*` custom nodes no stock ORT can load. The ONNX
files are fp32 and up to 4x larger (pose detector 3.0 -> 11.9 MB, face mesh 2.6 -> 4.9 MB).

## 3. How it was measured

- **Host app:** `spikes/face_android/` (Gradle, AGP 9.0.1, Kotlin 2.3.20, minSdk 24, ABIs arm64-v8a /
  armeabi-v7a / x86_64), an instrumentation-only APK (`FaceBench`, run with `am instrument`), never part of the
  app. Flavours `none`, `mp`, `mp11`, `litert`, `ort` measure size; `all` (MediaPipe 0.10.35 + LiteRT + ORT in one
  APK, R8 release build) runs latency and parity, so every comparison happens on the device.
- **Candidate A** (`MediaPipeCandidate.kt`): `FaceLandmarker` (numFaces 4 on stills), `PoseLandmarker`
  (numPoses 2), `ImageSegmenter` with confidence masks; CPU delegate; IMAGE mode for stills, VIDEO mode for
  clips; models passed as memory-mapped buffers.
- **Candidates B and C** (`RawPipeline.kt` over `LiteRtModel.kt` / `OrtModel.kt`, 4 threads each): our port of
  the MediaPipe graphs: SSD anchors, weighted NMS (IoU 0.3), rotated square ROIs (face: detection box x1.5, eye
  keypoints at 0 deg; pose: hip centre and scale point, x1.25 at 90 deg), 256 x 256 crops, landmark projection,
  tracking from the previous landmarks in video mode (detector only while fewer than the budget are tracked),
  and for pose the two details MediaPipe adds: **edge-replicated crops** and **7 x 7 heatmap refinement** (they
  cut the pose gap to MediaPipe from 43-228 px to 4-58 px). Segmentation: `selfie_multiclass` on the whole frame
  stretched to 256 x 256, softmax, person = 1 - background, hair = class 1.
- **Frames:** stills scaled so the long side is 1280 ("720p") or 1920 ("1080p"); clips decoded with
  `MediaMetadataRetriever` at 1080p and scaled to 720p, first 250 frames, segmentation on every 5th frame.
  Stills: 1 warm-up + 5 timed runs, median. Times include pre/post-processing (bitmap to tensor, MPImage wrap,
  mask extraction).
- **Parity (aggregates only):** faces matched by landmark centroid (within one inter-ocular distance); mean
  2D distance over the 478 points in frame px; NME = that / outer-eye-corner distance (33-263). Pose: mean over
  the first runtime's landmarks with visibility > 0.5. Segmentation: IoU at 0.5 on a 256 x 256 grid.
- **Devices:** emulator only; no physical device was attached. `Medium_Phone` (API 37, x86_64, 4 vCPU, 2 GB)
  for everything, `Pixel_API_29` (API 29, the editor's floor, 3 GB) for stills; emulator-5556 under the
  `emulator2` lock, `-no-snapshot-load`. One or two other agents' emulators ran at the same time: read the
  numbers as relative, not as phone timings.
- **Licence handling:** fixtures and models were pushed to the app's external files dir for each run and
  deleted with the app (`tool/run_bench.sh`); results hold counts, latencies and parity aggregates only. A
  host-side check (§5.1, §5.2) ran the models in memory on the laptop and wrote nothing.

Commands: `tool/convert_models.sh` (model pack + ONNX), `tool/measure_size.sh` (AABs), `tool/run_bench.sh <serial>
<label> [-e sections stills|clips -e res 720,1080 ...]`, `python3 -I tool/summarize.py build/results/<label>.jsonl`.
Evidence (not committed): `build/results/{api37_full,api37_clips,api37_clip03_remux,api29_stills}.jsonl`,
`build/size/*.csv`.

## 4. Results: latency (ms)

### 4.1 Stills, API 37 (median over the 14 fixtures of each fixture's median)

| Runtime | Frame | Face (478) | Pose (33) | Person + hair (multiclass) | MP selfie_segmenter | MP hair_segmenter |
|---|---|---|---|---|---|---|
| MediaPipe | 720p | 22.1 | 42.5 | 219.2 | 20.9 | 68.6 |
| LiteRT | 720p | 14.7 | 51.6 | 172.4 | - | - |
| ORT | 720p | 31.1 | 57.1 | 97.0 | - | - |
| MediaPipe | 1080p | 23.4 | 44.9 | 262.8 | 35.4 | 93.1 |
| LiteRT | 1080p | 14.4 | 42.4 | 173.9 | - | - |
| ORT | 1080p | 29.6 | 52.3 | 90.5 | - | - |

API 29, 1080p: MediaPipe 23.7 / 45.8 / 240.5 (selfie 25.1, hair 72.0); LiteRT 16.2 / 34.5 / 179.3; ORT 47.7 /
76.7 / 129.3. Init (load every model): MediaPipe 1.06 s (API 29: 3.26 s), LiteRT 0.30 s (0.39), ORT 0.36 s
(0.95). PSS with all three loaded: 185-211 MB.

The multiclass model is the slowest piece everywhere (16 MB fp32, 256 x 256 x 6), and MediaPipe adds the cost
of upsampling six confidence masks to frame size. For live preview the small `selfie_segmenter` (35 ms) or a
lower mask resolution is the practical choice. ORT runs multiclass fastest of the three.

### 4.2 Clips, API 37, tracking mode (per frame, median / p90)

| Clip | Frame | Runtime | Frames with a face | Face | Pose | Seg (every 5th) |
|---|---|---|---|---|---|---|
| 01 head turn | 720p | MediaPipe | 250 / 250 | 17.7 / 23.8 | 30.3 / 43.2 | 219.5 / 243.7 |
| | | LiteRT | 250 | 10.3 / 14.3 | 30.1 / 38.2 | 179.1 / 210.3 |
| | | ORT | 250 | 14.2 / 20.0 | 36.0 / 45.5 | 121.2 / 138.1 |
| 01 head turn | 1080p | MediaPipe | 250 | 38.9 / 51.4 | 51.1 / 67.4 | 352.4 / 452.1 |
| | | LiteRT | 250 | 16.4 / 22.1 | 47.9 / 60.6 | 225.6 / 277.7 |
| | | ORT | 250 | 20.9 / 29.5 | 52.5 / 70.5 | 163.0 / 204.5 |
| 02 two people | 720p | MediaPipe | 4 / 250 | 21.5 / 41.0 | 54.4 / 82.8 | 215.6 / 328.9 |
| | | LiteRT | 10 | 14.5 / 33.3 | 56.2 / 91.3 | 174.8 / 238.8 |
| | | ORT | 10 | 30.2 / 51.2 | 75.7 / 105.7 | 137.2 / 178.7 |
| 02 two people | 1080p | MediaPipe | 1 | 29.6 / 42.7 | 59.8 / 79.4 | 284.5 / 331.4 |
| | | LiteRT | 5 | 18.2 / 31.3 | 71.7 / 83.2 | 188.7 / 214.8 |
| | | ORT | 5 | 29.0 / 46.4 | 66.6 / 101.4 | 107.0 / 144.4 |
| 03 low light* | 720p | MediaPipe | 0 / 250 | 8.7 / 9.9 | 26.0 / 28.4 | 229.4 / 240.5 |
| | | LiteRT | 0 | 3.3 / 4.2 | 22.2 / 25.7 | 178.8 / 188.9 |
| | | ORT | 0 | 4.4 / 9.2 | 24.9 / 36.2 | 102.0 / 118.3 |
| 03 low light* | 1080p | MediaPipe | 0 | 14.3 / 20.0 | 31.6 / 37.3 | 278.3 / 300.4 |
| | | LiteRT | 0 | 3.2 / 6.1 | 21.3 / 26.2 | 177.3 / 196.6 |
| | | ORT | 0 | 4.8 / 9.7 | 25.4 / 39.1 | 103.5 / 135.8 |

\* `clips/03_low_light.mp4` is a fragmented MP4 (`iso5`, no sample count): `MediaMetadataRetriever` returns no
frames from it on the emulator. It was run from a stream-copied remux (`ffmpeg -c copy -movflags +faststart`,
same frames) in a temp folder deleted after the run. **For VED-17A:** sample frames with `MediaExtractor` +
`MediaCodec`, not `getFramesAtIndex`, or fragmented files from phones and editors will fail.

## 5. Results: detection and parity

### 5.1 Faces / poses found (1080p; 720p and API 29 give the same counts)

| Fixture | MediaPipe | LiteRT | ORT | Note |
|---|---|---|---|---|
| 01 frontal | 1 / 1 | 1 / 1 | 1 / 1 | |
| 02 full-body | 0 / 1 | 0 / 1 | 0 / 1 | face too small for the short-range detector |
| 03 three-quarter | 1 / 0 | 1 / 1 | 1 / 1 | |
| 04 profile | 0 / 0 | 0 / 0 | 0 / 0 | detected, rejected by the mesh's presence score |
| 05 glasses + beard | 1 / 0 | 1 / 0 | 1 / 0 | |
| 06 frontal older | 1 / 1 | 1 / 1 | 1 / 1 | |
| 07 mask | 0 / 1 | 0 / 1 | 0 / 1 | detected, rejected by presence |
| 08 hand | 0 / 1 | 0 / 0 | 0 / 0 | detected, rejected by presence |
| 09 low light | 0 / 1 | 0 / 0 | 0 / 0 | detected, rejected by presence |
| 10 backlit (face visible) | 0 / 1 | 0 / 1 | 0 / 1 | detected, rejected by presence |
| 11 silhouette | 0 / 0 | 0 / 0 | 0 / 0 | expected |
| 12 two people | 2 / 1 | 2 / 1 | 2 / 1 | |
| 13 four people | 2 / 0 | 1 / 0 | 1 / 0 | short range finds 3 of 4 faces |
| 14 empty room | 0 / 0 | 0 / 0 | 0 / 0 | no false positives |

Host check of the detector alone (in memory): BlazeFace **short range** fires on 11 of the 13 stills with a
face (misses 02 full-body and 11 silhouette; 3 of 4 on row 13); **full range** also fires on 11 (finds 02, 11
and all 4 on row 13; misses 08 hand and 09 low light). So most gaps above come from the 478-point model's
presence score (threshold 0.5) on occluded, profile and dark faces, not from the runtime. **For VED-16/17:**
the landmarker drops masked, hand-covered, profile and backlit faces (which suits ARCH's occlusion fade), and
the two-people clip yields a face in only 1-10 of 250 frames (small faces at office distance). Group photos
need the full-range detector or tiling; that is a model choice for VED-33, not a runtime one.

### 5.2 Parity between candidates (mean per-landmark distance)

| Pair | Stills 720p: face px (worst) / NME | Stills 1080p: face px (worst) / NME | Head-turn clip 1080p: face px mean / p90 | Pose px, stills 1080p | Person / hair IoU, stills 1080p |
|---|---|---|---|---|---|
| MediaPipe ~ LiteRT (our pipeline) | 2.16 (4.19) / 1.2 % | 2.87 (6.22) / 1.1 % | 3.62 / 5.85 | 24.1 | 0.912 / 0.813 |
| MediaPipe ~ ORT (our pipeline) | 2.16 (4.19) / 1.2 % | 2.87 (6.23) / 1.1 % | 3.61 / 5.80 | 24.1 | 0.912 / 0.813 |
| **LiteRT ~ ORT** (same crops) | **0.00** | **0.00 (0.01)** | **0.31 / 0.64** | 0.01 | 1.000 / 1.000 |
| Same build, API 29 vs API 37 | <= 0.02 px on every fixture | | | | |

- The **runtimes themselves agree to 0.01 px** given the same crop, which also shows the ONNX conversion holds
  on the device; tracking lets 0.3 px build up over 250 frames.
- The 2-3.6 px gap to MediaPipe is **our pipeline**, not LiteRT: our detector ROI differs from MediaPipe's in
  detail (one extra ROI-from-landmarks pass brings it to 1.5-1.8 px on the host; scale 1.4 instead of 1.5 helps
  some faces and hurts others). Getting under 1.5 px would mean porting MediaPipe's calculators exactly; using
  MediaPipe on both platforms avoids that work.
- Pose residual 4-58 px (worst on half-body portraits, where the ROI is 4-5x the frame and one crop pixel is
  about 20 px). Segmentation: person IoU 0.91 on stills and 0.97-0.99 on clips; hair IoU 0.78-0.95, and 0 on the
  masked fixture (07), where the two disagree whether the head covering is hair.

## 6. Parity with iOS (input for VED-33)

- Android-side reference: one build is deterministic to <= 0.02 px across API 29 / 37 on x86_64, so a gap
  between iOS and Android with MediaPipe on both will come from the iOS build, not from Android variance.
- **No dumps exist to compare with** (licence rule). Options for the lead:
  1. a synthetic or rendered head set (V2-31 allows synthetic) whose landmark dumps may be committed; this bench
     takes any `faces/` folder, so a `dump` switch of a few lines produces the Android dumps in one run;
  2. a one-run cross-device comparison: both platforms write dumps of the licensed fixtures into one test-run
     folder, a script compares and deletes them, and only the aggregate is kept. That is still "within a test
     run" but crosses machines, so it needs the owner's OK first.

## 7. Spike code (reference only, never built into the product)

`app/src/main/kotlin/.../{FaceBench,Candidate,RawPipeline}.kt`, `app/src/impl_{mp,litert,ort}/`, per-flavour
`Registry.kt`, `app/proguard-rules.pro`, `tool/{convert_models.sh,densify_tflite.py,verify_onnx.py,model_io.py,
measure_size.sh,run_bench.sh,summarize.py}`. `RawPipeline.kt` is the reference for fallback B if VED-33 needs it.

## 8. Downloads made for this spike (owner's standing approval, 2026-10-23), all outside the repo

| What | Where | Bytes | SHA-256 |
|---|---|---|---|
| 7 MediaPipe models + `face_detection_full_range.tflite` (§2.2) | `C:/dev/models/face_runtime/mediapipe/` (`SHA256SUMS` beside it) | see §2.2 | see §2.2 |
| bundletool 1.18.3 (`https://github.com/google/bundletool/releases/download/1.18.3/bundletool-all-1.18.3.jar`) | `C:/dev/models/tools/` | 32,520,401 | `a099cfa1543f55593bc2ed16a70a7c67fe54b1747bb7301f37fdfd6d91028e29` |
| Python 3.12.10 runtime (`py install -t`, signed python.org index; not registered system-wide) | `C:/dev/models/face_runtime/tools/py312/` | ~126 MB extracted | n/a |
| PyPI into a venv there: tensorflow-cpu 2.21.0, tf2onnx 1.17.0, onnx 1.23.2, onnxruntime 1.31.0, mediapipe 1.1.1, numpy 2.5.4, pillow 13.0.0 (+ deps) | `C:/dev/models/face_runtime/tools/venv/` | | pip |
| Maven via Gradle: `com.google.mediapipe:tasks-vision` 0.10.35 and 1.1.1, `com.google.ai.edge.litert:litert` 2.3.0, `com.microsoft.onnxruntime:onnxruntime-android` 1.31.0, and their dependencies | `~/.gradle` cache | | Gradle |

Laptop quirk: Application Control blocks numpy's `_bounded_integers` DLL, so `numpy.random` cannot be used on
this machine (`verify_onnx.py` uses a deterministic pattern instead).

## 9. Face fixtures: `C:/dev/models/faces/SHA256SUMS` (for the Mac to compare)

```
831990a4d179cadaed9bba1721ee805396e021452e21cb350edafb4dc78d10f8 *clips/01_head_turn.mp4
408fac10579678887c83659f958d7209a4fdcaa0e98cec5655267887abdc2d16 *clips/02_two_people_talking.mp4
42add52c89e0969e2e8eaa55a65af623e3fde7fb3efb4cb115ace27329ddd92b *clips/03_low_light.mp4
a6f11efaa834706db23f275b6115058fa87fc7f14362681e6abe14e82749de3e *stills/01_frontal_mediapipe.jpg
c8a830ed683c0276d713dd5aeda28f415f10cd6291972084a40d0d8b934ed62b *stills/02_pose_fullbody_mediapipe.jpg
e3819ec9a1f8678d6ba0f120b94181198a604293a02f5b92e84efb47569c51e8 *stills/03_three_quarter_older.jpg
726d49bfde4c040c112788bb503b84d08ecf0e265a01eead5d54b90a182ff5ae *stills/04_profile_dark_bg.jpg
1dd2b8ff4204903f274586b0bbbdc382c66de84714df100df7794427b90e87a1 *stills/05_glasses_beard.jpg
6b22fb638ca03c7d361554e4225b4a696509d3cd83372fc650925918838aa00b *stills/06_frontal_older_studio.jpg
cc34a289625931db181bb1eb6450063db161eb71a906f3146c5b3ee321b34aae *stills/07_mask_occlusion.jpg
bf9fae5bf52a7846791b3ca233f9864ad3fc1204af908f6f310103833c367c05 *stills/08_hand_occlusion.jpg
f47499ae1b586080607498237ca4df45a2cbc67ff0eef0786d68bd4ff283dbc4 *stills/09_low_light.jpg
42a979dffa1e5bc63c20ec552d21d347e528f2ea14381a551a31dbaf99bbceb2 *stills/10_backlit_sunset.jpg
5735a73db30d5b9b7a22aaf1f79226954b145c27cd3cb2bf2518c41607e8b518 *stills/11_backlit_silhouette.jpg
8604816ac723359a141bb55b5bfb736f97769de06c8f1c213380877afbbf4527 *stills/12_two_people.jpg
daa8d0b676326e1169f7004decd4d7ee55ce918871ddee85a8c539ae30460c62 *stills/13_four_people.jpg
2e6e79d1a45caa5fa175fc13d26307c0603649c3e0568635908fde1244470e56 *stills/14_no_face_room.jpg
```

All 17 files are present with the sizes in WINDOWS_DOWNLOADS.md; no URL was missing.
