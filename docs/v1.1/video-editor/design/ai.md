# Danaview Editor: On-Device AI Subtitles (whisper.cpp) Design

> **Area:** AI subtitles ("Auto captions" in the UI): model management, on-device speech-to-text, cue segmentation, timeline insertion, regenerate, and how they connect to SRT/VTT export and burn-in.
> **Status:** Design draft for the Editor release. There is no production code in this document. Dart, C, Swift and Kotlin snippets are interface sketches.
> **Date:** 2026-10-07. **Baseline:** `main` @ `19cae59`, Flutter 3.44.2 / Dart 3.12.2.
> **Sibling docs** in `docs/v1.1/video-editor/design/`: `ux.md` (exists; owns the screens, the `TranscriptionService` minimum contract in its §2.4, and the caption flow files), plus Domain & project model, Persistence & media management, iOS engine, and Android engine (file names not final when this was written). **Where a type belongs to another area, that area's final name wins.** Section 17 lists every interface where this area meets another.
>
> **Markers used below.** **[VERIFIED]** means I checked it against a primary source on 2026-10-07: the GitHub API, the pinned source tree, the Hugging Face API and headers, Google Maven artifacts, or this repo. **[VERIFY]** means I believe it but did not check it. Each [VERIFY] item has a ticket acceptance criterion that confirms or refutes it. **[ASSUMPTION]** marks a guess about a sibling area's design.

---

## 0. Decisions at a glance

1. **Two new packages.**
   - `packages/danaview_whisper` is a Flutter FFI plugin for iOS and Android only. It has a small C ABI shim over whisper.cpp, a device-profile channel, and a Dart runtime that polls native jobs. It knows nothing about projects.
   - `packages/danaview_transcription` is Dart-only logic. It holds the model catalog and store, the resumable downloader, the transcription pipeline, segmentation, timeline mapping and caches. It implements the `TranscriptionService` that `ux.md` §2.4 consumes.
   - The UI lives in `danaview_editor` (`flows/captions/`, owned by the UX area). This doc specifies its behavior, states and copy.
2. **whisper.cpp is pinned to `v1.9.4`**: tag object `7d75b149…`, commit `927cfce34f31707e17f2bff35c349632fb9e2c3a`, released 2026-09-11, bundling ggml 0.23.0 [VERIFIED]. `v1.9.5` came out on 2026-10-06 and is too new to ship. We bump only after a soak and a re-run of the eval suite (§16). The source is **vendored and pruned** (about 7.8 MB, 192 files) instead of added as a submodule, so CI checkouts and offline builds stay simple.
3. **Native execution model.** The shim owns a **native worker thread** for each job. Dart never blocks inside FFI. The UI isolate polls a mutex-protected status and segment buffer every 250 ms. Cancellation is an atomic flag that whisper's `abort_callback` and `encoder_begin_callback` read. No Dart callbacks cross threads.
4. **Acceleration.**
   - iOS uses Metal (ggml-metal with an embedded library) when the device has iOS ≥ 16.4 and Apple GPU family ≥ 6 (A13+). Otherwise it uses the NEON CPU path. ggml-blas and Accelerate's *new LAPACK* interface are **disabled** on iOS because they require iOS 16.4 and the app targets 13.0 (§4.4).
   - Android is CPU-only (NEON). We ship two arm64 builds, a baseline `armv8-a` and an `armv8.2-a+fp16+dotprod`, and choose between them at runtime with `getauxval(AT_HWCAP)`. We also ship one x86_64 build for emulators and Chromebooks. armeabi-v7a is not supported.
   - Core ML encoders and Android GPU backends are designed for but deferred (§18 deferred tickets).
5. **Models.** Three multilingual tiers, all quantized `q5_1`, all from the official `ggerganov/whisper.cpp` Hugging Face repo, **pinned to revision `5359861c…`**:
   - **Fast:** tiny, 30.7 MiB
   - **Balanced:** base, 56.9 MiB (default)
   - **Accurate:** small, 181.3 MiB

   We also fetch the Silero VAD v6.2.0 file (0.84 MiB) from `ggml-org/whisper-vad`. SHA-256 values and sizes were checked against the HF API and the `x-linked-etag`/`x-linked-size` headers [VERIFIED]. Downloads resume with HTTP `Range` (the CDN answers `206`) [VERIFIED]. Nothing downloads without an explicit consent that is bound to the exact file shown to the user.
6. **Source-time transcription.** We transcribe each clip's **source media range at 1×** and map word timestamps through the clip's time map into timeline time. We do **not** transcribe a rendered timeline mixdown. This choice:
   - stays accurate under speed changes and ramps,
   - lets one transcript serve several split clips,
   - keeps working when the user trims or moves clips during or after generation,
   - makes "Regenerate → re-split" instant from cached word timings.
7. **Chunked, resumable inference.** Audio runs in about 180 s chunks cut at the quietest point within ±15 s. Each chunk is one `whisper_full_with_state` call with built-in Silero VAD. Finished chunks are checkpointed to disk. This bounds memory (a 1 h file never sits in RAM), lets iOS suspend at a chunk boundary when the app is backgrounded, and lets a killed app resume.
8. **Readable cues from a deterministic segmenter.** A pure Dart dynamic-programming segmenter places cues using:
   - punctuation, pauses and cut points,
   - CPS, duration and gap limits,
   - script profiles: space-delimited, CJK, no-space Southeast Asian, RTL.

   Presets are Standard (2 × 42), Single line, and Short phrases (social), with 9:16 projects defaulting narrower. Cue edges are quantized to the project frame grid.
9. **One undo step.** Generated captions arrive as `SubtitleCueDraft`s. The editor controller applies them as a single `EditCommand`, either `AddGeneratedCaptionTrack` or `ReplaceGeneratedCaptions`. The track carries `CaptionProvenance` (model, language, settings, transcript keys), which makes Regenerate possible. Generated cues are ordinary subtitle cues: fully editable, exportable as SRT/VTT, and burnable.
10. **Privacy.** Audio, video and text never leave the device. The only network traffic is the model download from `huggingface.co`, which redirects to Hugging Face's CDN on `*.hf.co`. The privacy policy gains one bullet in "When Danaview uses the internet", plus storage and choices bullets (§13). The app shows MIT notices for whisper.cpp, the OpenAI Whisper weights and Silero VAD.

---

## 1. Scope

**In v1 (the owner's "AI Subtitles" list):**
- Generate subtitles from video or audio.
- The user picks the spoken language, or chooses automatic detection with confirmation when confidence is low.
- Audio extraction to 16 kHz mono PCM WAV through the native engines.
- On-device speech-to-text with segment- and word-level timestamps.
- Automatic segmentation into readable cues.
- Insertion into a timeline subtitle track; generated subtitles stay fully editable.
- Regenerate, either re-split only or transcribe again.
- Export of generated subtitles as SRT/VTT, and burn-in on export. Both reuse the Subtitles feature with no AI-specific path.

**Explicit non-goals in v1** (the owner said "no other AI features"):
- No translation (whisper's `translate` is forced off).
- No speaker diarization (`tdrz_enable` off).
- No summarization, chapters, keyword extraction, auto-edit or silence removal.
- No cloud fallback.
- No custom-vocabulary prompt in the UI. The API supports `initialPrompt`, but it stays unused in v1.
- No desktop. The editor is gated off there (`ux.md` §4.1), and `danaview_whisper` declares no desktop platforms.

### 1.1 Corrections to the brief, found while reading the repo [VERIFIED]

| Brief said | Repo says | Impact |
|---|---|---|
| iOS bundle id `com.vecvel.danaviewplayer` | `com.vecvel.danaview` (`project.pbxproj`) | Plugin bundle IDs and log subsystems use `com.vecvel.danaview.whisper`. |
| Android applicationId `com.vecvel.danaview`, minSdk 21 | `com.vecvel.danaview`; `minSdk = flutter.minSdkVersion` = **24** in Flutter 3.44.2 (`FlutterExtension.kt`); NDK `28.2.13676358` | NDK r28 links with 16 KB page alignment by default. minSdk ≥ 23 means native libs are not extracted by default, which rules out ggml's directory-scanning `GGML_BACKEND_DL`. |
| (n/a) | AGP 9.0.1, Kotlin 2.3.20, `android.builtInKotlin=false`, `android.newDsl=false` | The plugin's Gradle file applies `kotlin-android` explicitly. |
| (n/a) | Flutter 3.44 enables **Swift Package Manager by default**; the app runs **hybrid** (SPM plus CocoaPods for media_kit) | The `plugin_ffi` template is CocoaPods-only. v1 ships a podspec; `Package.swift` is a deferred ticket (AI-D2). |
| (n/a) | No `cmake` on the dev Mac; the Android SDK has CMake 3.22.1 | The iOS xcframework build needs `brew install cmake` (≥ 3.28, matching upstream's check). Android uses the SDK's CMake. |
| (n/a) | The app has no open-source licences screen | The MIT notices need one (AI-18). The existing mpv/FFmpeg (LGPL) notices probably need it too. That is outside this area and is flagged to UX/legal. |

---

## 2. Verified versions and artifacts

| Item | Value | Source |
|---|---|---|
| whisper.cpp release | `v1.9.4`, tag `7d75b14994ae7f59623e2471445e2355fe506ed2` → commit `927cfce34f31707e17f2bff35c349632fb9e2c3a` (2026-09-11) | GitHub API [VERIFIED] |
| Newer release (not used) | `v1.9.5` (2026-10-06): ggml 0.26.0 sync, Metal and CUDA changes | GitHub API [VERIFIED] |
| whisper.cpp licence | MIT, "Copyright (c) 2023-2026 The ggml authors" | `LICENSE` at the pinned commit [VERIFIED] |
| Upstream iOS xcframework (not used) | `whisper-b5130-xcframework.zip`, sha256 `033a43b0…231a`, **`IOS_MIN_OS_VERSION=16.4`** | release asset + `build-xcframework.sh` [VERIFIED] |
| Relevant C API at pin | `whisper_init_from_file_with_params_no_state`, `whisper_init_state`, `whisper_full_with_state`, `whisper_full_get_segment_*_from_state`, `whisper_full_get_token_data_from_state`, `whisper_full_get_segment_no_speech_prob_from_state`, `whisper_lang_auto_detect_with_state`, `whisper_pcm_to_mel_with_state`, `whisper_vad_*`, `whisper_log_set`, `whisper_full_params.{abort_callback, encoder_begin_callback, progress_callback, vad, vad_model_path, vad_params, token_timestamps, carry_initial_prompt, suppress_nst}` | `include/whisper.h` [VERIFIED] |
| Context defaults | `use_gpu=true`, `flash_attn=true`; **DTW token timestamps are disabled when `flash_attn` is on** (warning logged) | `src/whisper.cpp` L3687–3703, L3791 [VERIFIED] |
| Full-params defaults | `temperature 0`, `temperature_inc 0.2`, `entropy_thold 2.4`, `logprob_thold -1.0`, `no_speech_thold 0.6`, `greedy.best_of 5`, `n_threads = min(4, hw)` | `src/whisper.cpp` ~L6038–6130 [VERIFIED] |
| VAD defaults | `threshold 0.5`, `min_speech 250 ms`, `min_silence 100 ms`, `max_speech FLT_MAX`, `speech_pad 30 ms`, `samples_overlap 0.1 s`; VAD ctx `n_threads 4`, `use_gpu false` | `src/whisper.cpp` L4542–4561 [VERIFIED] |
| Language table | 99 languages (ids 0–98) plus `yue` (id 99, large-v3 only) | `g_lang` in `src/whisper.cpp` [VERIFIED] |
| Android CPU variants upstream | `android_armv8.0_1`, `android_armv8.2_1 (DOTPROD)`, `android_armv8.2_2 (+FP16)`, … only with `GGML_BACKEND_DL` + shared libs | `ggml/src/CMakeLists.txt` [VERIFIED] |
| Accelerate on Apple | `ggml-cpu` and `ggml-blas` define `ACCELERATE_NEW_LAPACK` and `ACCELERATE_LAPACK_ILP64` | `ggml/src/ggml-cpu/CMakeLists.txt` L62–71, `ggml-blas/CMakeLists.txt` L19–21 [VERIFIED] |
| Metal availability guards | `@available(iOS 16.0)` for `recommendedMaxWorkingSetSize`; residency sets only on iOS 18; `supportsFamily:` used without guards | `ggml-metal-device.m` [VERIFIED] |
| Model repo | `huggingface.co/ggerganov/whisper.cpp`, revision `5359861c739e955e79d9a303bcbc70fb988958b1`, licence tag `mit` | HF API [VERIFIED] |
| VAD repo | `huggingface.co/ggml-org/whisper-vad`, revision `9ffd54a1e1ee413ddf265af9913beaf518d1639b`, licence tag `mit` | HF API [VERIFIED] |
| Download behaviour | `GET /resolve/<rev>/<file>` → `302` to `https://us.aws.cdn.hf.co/xet-bridge-us/…` (signed, expiring); headers `x-linked-size`, `x-linked-etag` (= SHA-256), `x-repo-commit`; `accept-ranges: bytes`; ranged GET → `206` | curl [VERIFIED] |
| AndroidX Media3 | latest stable `1.11.1`; `androidx.media3.inspector.MediaExtractorCompat` (artifact `media3-inspector`); `androidx.media3.common.audio.{SonicAudioProcessor (setOutputSampleRateHz), ChannelMixingAudioProcessor, ChannelMixingMatrix(int,int,float[])}` | Google Maven + `javap` [VERIFIED] |
| Dart packages | `ffigen 23.0.0` (Dart ≥ 3.10), `ffi 2.2.0`, `crypto ^3.0.3` (already in `danaview_data`), `hooks 2.2.0` / `native_toolchain_cmake 0.3.2` (considered, not used) | pub.dev API [VERIFIED] |
| `background_downloader` | 9.6.x requires Flutter ≥ 3.47 (incompatible); 9.5.9 is compatible | pub.dev API [VERIFIED]. Not used (§5.5). |

---

## 3. Architecture

### 3.1 Package graph

```
lib/ (app root: providers overrides, routes)
 └─ danaview_editor (UX area: screens, controllers, flows/captions/*)
     ├─ danaview_transcription (THIS AREA, Dart)        implements TranscriptionService (ux.md §2.4)
     │   ├─ danaview_whisper (THIS AREA, FFI plugin: iOS + Android)
     │   ├─ <editor domain pkg> (Domain area)         TimeUs, TimeRange, FrameRate, MediaClip, SubtitleCue, EditCommand
     │   ├─ danaview_data                                NetworkCancelToken, AppStorage dirs
     │   └─ crypto, path, characters, meta, collection
     └─ <editor engine pkg> (iOS/Android engine areas)  implements SpeechAudioExtractor (§7) via EditorEngine.jobs
```

Rules:
- `danaview_transcription` never imports the engine package or Flutter widgets. It gets audio extraction through the `SpeechAudioExtractor` port, which `editor_providers.dart` binds.
- `danaview_whisper` never imports any `danaview_*` package.
- `danaview_features` never imports either package. The Storage screen is reached through `ux.md` §4.8 `StorageContributor`.
- A pubspec-parsing test enforces these rules, as `ux.md` §3.3 does.

### 3.2 Runtime data flow

```
AutoCaptionsSheet ──► AutoCaptionsController (danaview_editor, UI isolate, StateNotifier)
                             │ preflight / start / cancel / provideLanguage
                             ▼
                 TranscriptionServiceImpl (danaview_transcription, UI isolate, async only)
   ┌──────────────┬───────────────┬──────────────────┬────────────────┬───────────────┬───────────────┐
   ▼              ▼               ▼                  ▼                ▼               ▼
SpeechModelStore  TranscriptionPlanner  SpeechAudioExtractor  WhisperRuntime   TranscriptCache   CaptionSegmenter
(HttpClient,      (TimelineView →       (port → EditorEngine  (FFI, polls     (JSON files,     (Isolate.run when
 Isolate.run       units; pure)          native decoder)       native jobs)    checkpoints)     > 4k words)
 SHA-256)                                    │                     │
                                     AVAssetReader /         native worker thread ─► whisper_full_with_state
                                     MediaExtractorCompat     (per job)                 ├─ ggml-metal (iOS GPU)
                                     → 16 kHz mono WAV                                  └─ ggml-cpu NEON threads
```

### 3.3 Threads and isolates

| Work | Where | Why |
|---|---|---|
| Controllers, service orchestration, polling FFI (`dv_job_status_get` is an FFI *leaf* call), JSON parse of a few segments per poll | UI isolate | Each call is < 0.5 ms. Nothing blocks. |
| Model load (`whisper_init_from_file_with_params_no_state`), whole transcription job | Native `std::thread` created by the shim | whisper calls block for seconds to minutes. A native thread keeps Dart free and makes cancel an atomic store. |
| ggml compute | ggml thread pool (`n_threads`, OpenMP **off**) | Predictable thread counts, and abort checks reach every graph compute. |
| Metal command buffers | ggml-metal queues | n/a |
| SHA-256 of a downloaded model (up to 190 MB) | `Isolate.run` streaming `sha256.startChunkedConversion` | Keeps the UI at 60 fps. |
| Segmentation of > 4,000 words, transcript JSON (de)serialization > 256 KB | `Isolate.run` | Bounded at about 150 ms for 1 h of speech. |
| Audio decode and resample | Engine-owned native queue (iOS `DispatchQueue`, Android `HandlerThread`/IO dispatcher) | Platform DSP. |
| Download network I/O | UI isolate async (`dart:io` `HttpClient`) | Pure async I/O, same as `SpeedTestService`/`StreamProbe` today. |

**Why not a Dart isolate blocked in FFI, or `NativeCallable.listener`?** whisper's `abort_callback` can run on ggml worker threads, so a `Pointer.fromFunction` callback would crash. A listener owned by a blocked isolate would never deliver. A Dart-isolate design also makes cancellation latency depend on message delivery. Polling an atomic and mutex-guarded C state is simple, deterministic, and testable with a fake bindings class.

**Hot restart hygiene.** Native threads survive a Dart hot restart. `WhisperRuntime.open()` calls `dv_shutdown_all()` once per VM. In debug this cancels and joins orphan jobs and frees models. In release it is a no-op.

---

## 4. Native integration: `packages/danaview_whisper`

### 4.1 Layout

```
packages/danaview_whisper/
  pubspec.yaml               # flutter: plugin: platforms:
                             #   android: {ffiPlugin: true, package: com.vecvel.danaview.whisper, pluginClass: DanaviewWhisperPlugin}
                             #   ios:     {ffiPlugin: true, pluginClass: DanaviewWhisperPlugin}
                             # deps: ffi ^2.2.0; dev: ffigen ^23.0.0, flutter_test
  ffigen.yaml                # entry-point src/dv_whisper.h only → lib/src/ffi/dv_whisper_bindings.g.dart (DynamicLibrary class bindings)
  lib/
    danaview_whisper.dart                         # exports runtime/device/support APIs only
    src/ffi/dv_whisper_bindings.g.dart         # generated, committed
    src/ffi/library_loader.dart                # variant choice, ABI check, unsupported fallbacks
    src/runtime/whisper_runtime.dart           # WhisperRuntime, WhisperModel
    src/runtime/whisper_job.dart               # polling WhisperJob implementation
    src/runtime/whisper_types.dart             # requests, options, RawSegment/RawWord, updates, WhisperException
    src/runtime/segment_json.dart              # schema v1 decoder (tolerant)
    src/device/device_profile.dart             # WhisperDeviceProfile, ThermalLevel, CpuFeature, GpuTier
    src/device/device_channel.dart             # MethodChannel 'danaview/whisper', EventChannel 'danaview/whisper/events'
    src/support.dart                           # WhisperSupport evaluation (pure, testable)
  src/                                         # shared native code (C++17, C ABI)
    dv_whisper.h  dv_whisper.cpp               # ABI surface, try/catch wrappers
    dv_model.h/.cpp  dv_job.h/.cpp             # async load, refcount, job thread, state machine
    dv_wav.h/.cpp                              # strict 16k/mono/s16 WAV reader (chunked)
    dv_chunker.h/.cpp                          # RMS silence search
    dv_words.h/.cpp                            # token → word assembly, UTF-8 safety
    dv_json.h/.cpp                             # segment JSON writer (escaping)
    dv_log.h/.cpp                              # whisper_log_set → os_log / logcat (no user content)
    dv_cpu.cpp                                 # getauxval HWCAP probe (Android), sysctl perf cores (iOS)
    dv_exports.map                             # Android: export dv_* only
    CMakeLists.txt                             # Android variants + host test build
    tests/ dv_tests.cpp  fixtures/(jfk.wav, sil_concat.wav, cjk_sample.wav, bad_headers/*.wav)
  third_party/
    whisper.cpp/                               # vendored, pruned (see 4.2)
    VENDORED.md                                # upstream URL, tag, commit, date, prune list, sha256 of source tarball
  tool/
    vendor_whisper.sh                          # re-vendor from a tag/commit; verifies tarball sha256; prunes
    build_ios_xcframework.sh                   # builds ios/Frameworks/WhisperCore.xcframework (static)
  android/
    build.gradle.kts                           # library; externalNativeBuild → ../src/CMakeLists.txt
    src/main/AndroidManifest.xml
    src/main/kotlin/com/vecvel/danaview/whisper/{DanaviewWhisperPlugin.kt, DeviceProfiler.kt, ThermalMonitor.kt}
    src/test/kotlin/...                        # cpuinfo/thermal mapping unit tests
  ios/
    danaview_whisper.podspec
    Classes/DanaviewWhisperPlugin.swift  Classes/DeviceProfiler.swift  Classes/dv_whisper_forwarder.cpp
    Resources/PrivacyInfo.xcprivacy
    Frameworks/WhisperCore.xcframework         # BUILD OUTPUT, git-ignored, stamped
  test/                                        # Dart unit tests with FakeDvBindings + mocked channels
  LICENSE-THIRD-PARTY.md                       # whisper.cpp MIT, ggml MIT
```

### 4.2 Vendoring

`tool/vendor_whisper.sh v1.9.4 927cfce34f31707e17f2bff35c349632fb9e2c3a` does the following:
1. Downloads the GitHub source tarball for the commit and checks its sha256 (recorded in `VENDORED.md`).
2. Copies only: `CMakeLists.txt`, `LICENSE`, `cmake/`, `include/`, `src/` (including `coreml/` for later), `ggml/CMakeLists.txt`, `ggml/cmake/`, `ggml/include/`, `ggml/src/*.{c,cpp,h}`, `ggml/src/ggml-cpu/`, `ggml/src/ggml-metal/`, `ggml/src/ggml-blas/`, and `samples/jfk.wav` (a US-government public-domain speech, used only in tests).
3. Writes `VENDORED.md`.

The pruned tree measured from the pinned commit is about **7.8 MB / 192 files** [VERIFIED]. Acceptance (AI-01): the pruned tree configures and builds with the exact CMake options in §4.3/§4.4 on macOS and Linux hosts. This catches any CMake reference to a pruned directory [VERIFY].

### 4.3 Android build

- **Gradle:** `externalNativeBuild { cmake { path = file("../src/CMakeLists.txt"); version = "3.22.1" } }` and `defaultConfig.externalNativeBuild.cmake { abiFilters += listOf("arm64-v8a", "x86_64"); arguments += listOf("-DANDROID_STL=c++_static", "-DDV_ANDROID=ON") }`.
  - We use `c++_static` because media_kit already ships `libc++_shared.so`. A second shared STL could collide in packaging.
- **`src/CMakeLists.txt`** uses `ExternalProject_Add` **twice on arm64** (once on x86_64). Each one configures the vendored whisper.cpp as a static build:

  ```
  -DBUILD_SHARED_LIBS=OFF -DWHISPER_BUILD_EXAMPLES=OFF -DWHISPER_BUILD_TESTS=OFF -DWHISPER_BUILD_SERVER=OFF
  -DGGML_NATIVE=OFF -DGGML_OPENMP=OFF -DGGML_CPU_KLEIDIAI=OFF -DGGML_BACKEND_DL=OFF
  -DCMAKE_C_FLAGS="-fvisibility=hidden -ffunction-sections -fdata-sections" (same for CXX)
  variant v80:  -DGGML_CPU_ARM_ARCH=armv8-a
  variant v82:  -DGGML_CPU_ARM_ARCH=armv8.2-a+fp16+dotprod
  x86_64:       (defaults, GGML_NATIVE=OFF)
  + forwarded CMAKE_TOOLCHAIN_FILE, ANDROID_ABI, ANDROID_PLATFORM, ANDROID_STL=c++_static, CMAKE_BUILD_TYPE
  ```

  We then build `add_library(danaview_whisper SHARED <shim sources>)`, linked against the v80 static set, and `add_library(danaview_whisper_v82 SHARED <shim sources>)`, linked against the v82 static set (arm64 only). Link options: `-Wl,--version-script=dv_exports.map -Wl,--gc-sections -Wl,-z,max-page-size=16384`.
  - The 16 KB flag is redundant on NDK r28 but explicit. KleidiAI is off because it fetches sources at build time.
- **Why not upstream `GGML_CPU_ALL_VARIANTS`?** It requires `GGML_BACKEND_DL` and shared libraries, and loads variants by **scanning a directory**. With minSdk 24, AGP keeps `.so` files uncompressed inside the APK, so no such directory exists. Two self-contained shims avoid that and are what the upstream Android example does in spirit [VERIFIED: the example builds `whisper_v8fp16_va` and picks it via `/proc/cpuinfo`].
- **Runtime choice (Dart `library_loader.dart`):**
  1. Open `libdanaview_whisper.so` (baseline, always safe).
  2. Call `dv_cpu_features()`, which returns a bitmask from `getauxval(AT_HWCAP)`: `HWCAP_ASIMDDP`, `HWCAP_FPHP`, `HWCAP_ASIMDHP`.
  3. If DOTPROD, FPHP and ASIMDHP are all present, open `libdanaview_whisper_v82.so` and bind all calls to it. The baseline library stays mapped (about 3 MB of virtual memory) and is unused.
  4. If opening fails (an armeabi-v7a device, or a missing `.so`), report `WhisperSupport.unsupported(libraryMissing)`.
- **Size budget:** ≤ 3 MB per variant `.so` after stripping, so the arm64 download grows by about 6 MB or less (AAB ABI split) [VERIFY in AI-04].
- **CI:** `.github/workflows/android-release.yml` needs no checkout change, because the source is vendored. The NDK CMake 3.22.1 must satisfy ggml's `cmake_minimum_required(3.14…3.28)` [VERIFIED]. If any ggml feature needs newer CMake, AI-04 pins `version = "3.31.x"` [VERIFY].

### 4.4 iOS build

- **Script:** `tool/build_ios_xcframework.sh` (needs Xcode and CMake ≥ 3.28) builds static libraries for two slices: `ios-arm64` (`iphoneos`) and `ios-arm64_x86_64-simulator`. It uses:

  ```
  -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_DEPLOYMENT_TARGET=${DV_IOS_MIN:-13.0}
  -DBUILD_SHARED_LIBS=OFF -DWHISPER_BUILD_EXAMPLES=OFF -DWHISPER_BUILD_TESTS=OFF -DWHISPER_BUILD_SERVER=OFF
  -DGGML_NATIVE=OFF -DGGML_OPENMP=OFF
  -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON -DGGML_METAL_USE_BF16=OFF
  -DGGML_BLAS=OFF -DGGML_ACCELERATE=OFF          # see below
  -DWHISPER_COREML=OFF
  -DCMAKE_C_FLAGS/-DCMAKE_CXX_FLAGS="-fvisibility=hidden -fembed-bitcode-marker=0"
  ```

  It then merges `libwhisper.a libggml.a libggml-base.a libggml-cpu.a libggml-metal.a` with `libtool -static` per slice, `lipo`s the simulator slices, and runs `xcodebuild -create-xcframework -library … -headers include/` into `ios/Frameworks/WhisperCore.xcframework`. A `.stamp` file records the commit SHA, the script hash and `xcodebuild -version`, so the script is idempotent.
- **Why Accelerate and BLAS are off:** ggml defines `ACCELERATE_NEW_LAPACK`/`ILP64` [VERIFIED]. Apple's new BLAS/LAPACK interface is iOS 16.4+ [VERIFY]. With a 13.0 deployment target, strongly bound `$NEWLAPACK` symbols would stop the **whole app** from launching on iOS < 16.4, because our framework loads at launch. Metal does the heavy lifting on supported devices, and NEON covers the rest. Acceptance (AI-05):
  - `nm -um` on the built framework shows no `NEWLAPACK` symbols, and no symbol introduced after 13.0 is strongly bound,
  - the app launches on an iOS 15 simulator runtime.
- **Podspec (`danaview_whisper.podspec`):**
  - `s.platform = :ios, '13.0'`
  - `s.source_files = 'Classes/**/*.{swift,cpp,h}'`. The forwarder `dv_whisper_forwarder.cpp` `#include`s `../../src/*.cpp`, as the Flutter FFI template does.
  - `s.vendored_frameworks = 'Frameworks/WhisperCore.xcframework'`
  - `s.frameworks = 'Metal', 'MetalKit', 'Foundation'`, `s.libraries = 'c++'`
  - `s.resource_bundles = {'danaview_whisper_privacy' => ['Resources/PrivacyInfo.xcprivacy']}`
  - `pod_target_xcconfig`: `CLANG_CXX_LANGUAGE_STANDARD=c++17`, `HEADER_SEARCH_PATHS` to the xcframework headers, `GCC_PREPROCESSOR_DEFINITIONS='DV_IOS=1'`
  - A Ruby guard **raises a clear error when the xcframework is missing**: "Run packages/danaview_whisper/tool/build_ios_xcframework.sh".
  - Under the existing `use_frameworks!`, the pod becomes a dynamic framework that exports `dv_*`. Dart opens `danaview_whisper.framework/danaview_whisper`, falling back to `DynamicLibrary.process()`.
- **Privacy manifest:** the plugin uses the disk-space API (`volumeAvailableCapacityForImportantUsageKey`). It declares `NSPrivacyAccessedAPICategoryDiskSpace` with reason `E174.1`. ggml uses `clock_gettime(CLOCK_MONOTONIC)` and `sysctlbyname("machdep.cpu.brand_string")` [VERIFIED]; neither is a required-reason API to my knowledge [VERIFY]. No tracking, no collected data.
- **Build integration:**
  - `ios/fastlane/Fastfile` `flutter_ipa` runs the script before `flutter build ipa` (fast no-op when the stamp matches).
  - The README developer setup adds `brew install cmake`.
  - Any future iOS CI job caches `ios/Frameworks` keyed by the stamp.
- **GPU policy (decided in the shim at load):** `use_gpu = !TARGET_OS_SIMULATOR && iOS ≥ 16.4 && [MTLCreateSystemDefaultDevice() supportsFamily:MTLGPUFamilyApple6]`.
  - If `whisper_init…` returns NULL with GPU on, the shim retries once with `use_gpu=false` and records `gpuFallback=true`.
  - The 16.4 floor matches upstream's tested floor. A12-class devices (Apple5) run on CPU unless the AI-19 benchmark shows Metal wins there [VERIFY].
- **Supported OS floor for the feature:** the editor's floor (iOS area) or **iOS 15.0**, whichever is higher. iOS 13–14 cannot be tested on current Xcode simulators. `WhisperSupport` returns `osTooOld` below that.

### 4.5 C ABI (`src/dv_whisper.h`)

All entry points are `extern "C"`, `__attribute__((visibility("default"), used))`, wrapped in `try/catch` (C++ exceptions map to `DV_ERR_OOM`/`DV_ERR_INTERNAL`), and thread-safe. Every struct starts with `struct_size` for forward compatibility. **All strings passed in are copied**, so Dart frees its allocations right after the call.

```c
#define DV_ABI_VERSION 1

typedef enum { DV_OK = 0, DV_ERR_INVALID_ARG = 1, DV_ERR_MODEL_LOAD = 2, DV_ERR_WAV_FORMAT = 3,
               DV_ERR_IO = 4, DV_ERR_OOM = 5, DV_ERR_CANCELLED = 6, DV_ERR_INFERENCE = 7,
               DV_ERR_BUSY = 8, DV_ERR_VAD_MODEL = 9, DV_ERR_NO_SPEECH = 10, DV_ERR_INTERNAL = 99 } dv_status;
typedef enum { DV_MODEL_LOADING = 0, DV_MODEL_READY = 1, DV_MODEL_FAILED = 2 } dv_model_state;
typedef enum { DV_JOB_RUNNING = 1, DV_JOB_PAUSED = 2, DV_JOB_SUCCEEDED = 3,
               DV_JOB_FAILED = 4, DV_JOB_CANCELLED = 5 } dv_job_state;
typedef enum { DV_MODE_TRANSCRIBE = 0, DV_MODE_DETECT_LANGUAGE = 1 } dv_job_mode;
typedef enum { DV_PHASE_PREPARING = 0, DV_PHASE_VAD = 1, DV_PHASE_ENCODING = 2, DV_PHASE_DECODING = 3 } dv_phase;

typedef struct dv_model dv_model;
typedef struct dv_job dv_job;

typedef struct {
  int32_t struct_size;
  int32_t use_gpu;            /* request; shim applies the GPU policy on iOS and may downgrade */
  int32_t flash_attn;         /* 1 (default) */
  int32_t dtw_preset;         /* 0 = off (default); else whisper_alignment_heads_preset; forces flash_attn = 0 */
} dv_model_params;

typedef struct {
  int32_t struct_size;
  int32_t multilingual, n_vocab, model_type, ftype;
  int32_t gpu_used, gpu_fallback;
} dv_model_info;

typedef struct {
  int32_t struct_size;
  int32_t mode;                     /* dv_job_mode */
  const char *wav_path;             /* 16 kHz, mono, PCM s16le, canonical RIFF/WAVE; validated */
  int64_t range_start_ms;           /* inclusive, relative to WAV start; resume point */
  int64_t range_end_ms;             /* exclusive; -1 = end of file */
  const char *language;             /* whisper code ("en", "ja", …); "auto" only allowed in DETECT mode */
  int32_t n_threads;                /* 1..8; may change later via dv_job_set_threads */
  int32_t chunk_target_ms;          /* 180000 */
  int32_t chunk_search_ms;          /* 15000: search ±this around the target for the quietest 400 ms */
  int32_t chunk_min_ms;             /* 10000: tail shorter than this merges into the previous chunk */
  int32_t vad_enabled;
  const char *vad_model_path;       /* ggml-silero-v6.2.0.bin */
  float vad_threshold;              /* 0.5 */
  int32_t vad_min_speech_ms;        /* 250 */
  int32_t vad_min_silence_ms;       /* 300 */
  int32_t vad_speech_pad_ms;        /* 100 */
  float vad_samples_overlap_s;      /* 0.1 */
  int32_t token_timestamps;         /* 1 */
  float no_speech_thold, entropy_thold, logprob_thold, temperature_inc;  /* 0.6, 2.4, -1.0, 0.2 */
  int32_t beam_size;                /* <= 1 → greedy */
  int32_t best_of;                  /* 5 (only used on temperature fallback) */
  int32_t suppress_nst;             /* 1 unless the user wants sound descriptions */
  int32_t carry_prompt_words;       /* 0..40: tail of previous chunk used as initial_prompt for the next */
  const char *initial_prompt;       /* nullable; unused by the v1 UI */
  int32_t detect_max_speech_ms;     /* DETECT mode: up to 30000 ms of speech after the first VAD speech start */
  int32_t detect_search_ms;         /* DETECT mode: search window for first speech (600000) */
} dv_job_params;

typedef struct {
  int32_t struct_size;
  int32_t state;                    /* dv_job_state */
  int32_t error;                    /* dv_status (valid when FAILED/CANCELLED) */
  int32_t phase;                    /* dv_phase */
  int32_t progress_permille;        /* 0..1000 over [range_start, range_end) */
  int32_t chunk_index, chunk_count; /* 0-based current chunk; count known after planning */
  int32_t chunks_completed;         /* chunks whose segments are final and fully available */
  int32_t segments_ready;           /* total segments available to take */
  int64_t processed_ms;             /* audio covered by completed work */
  int64_t compute_ms;               /* wall time spent in whisper calls (excludes pauses) */
  int32_t threads;                  /* current n_threads */
  char    language[8];              /* language used/detected */
  float   language_p;
} dv_job_status;

/* library */
int32_t     dv_abi_version(void);
const char *dv_engine_version(void);            /* whisper_version(), e.g. "1.9.4" */
const char *dv_system_info(void);               /* whisper_print_system_info(); diagnostics only */
uint64_t    dv_cpu_features(void);              /* bitmask, Android: HWCAP-derived; iOS: 0 */
int32_t     dv_perf_core_count(void);           /* iOS: hw.perflevel0.physicalcpu (fallback ncpu/2); Android: 0 (Kotlin decides) */
void        dv_set_log_level(int32_t level);    /* 0 off … 4 debug; never logs transcript text or paths */
int32_t     dv_lang_max_id(void);
const char *dv_lang_code(int32_t id);           /* whisper_lang_str */
void        dv_shutdown_all(void);              /* cancel+join all jobs, free all models (hot restart) */
void        dv_free(void *p);

/* model */
dv_model   *dv_model_load(const char *model_path, const dv_model_params *params);  /* returns at once; loads on a native thread */
int32_t     dv_model_state(const dv_model *m);
int32_t     dv_model_error(const dv_model *m, char *buf, int32_t buf_len);
int32_t     dv_model_info_get(const dv_model *m, dv_model_info *out);
void        dv_model_release(dv_model *m);      /* refcounted; freed after the last job using it is freed */

/* job: at most one active job per model (DV_ERR_BUSY otherwise) */
dv_job     *dv_job_start(dv_model *m, const dv_job_params *params, int32_t *out_status);
void        dv_job_status_get(const dv_job *j, dv_job_status *out);       /* leaf, O(1), takes a mutex briefly */
char       *dv_job_take_segments_json(dv_job *j, int32_t from_index, int32_t max_count); /* free with dv_free */
char       *dv_job_language_probs_json(dv_job *j, int32_t top_n);          /* DETECT mode result */
void        dv_job_cancel(dv_job *j);
void        dv_job_pause(dv_job *j, int32_t abort_current_chunk);         /* 0: pause at next chunk boundary;
                                                                             1: abort the running chunk now and
                                                                                redo it on resume (iOS background) */
void        dv_job_resume(dv_job *j);
void        dv_job_set_threads(dv_job *j, int32_t n_threads);             /* applied at next chunk */
void        dv_job_free(dv_job *j);              /* cancels if running, joins the thread, frees */
```

**Segment JSON (schema 1)** comes from `dv_job_take_segments_json`. It is a JSON array. Times are **milliseconds relative to the WAV start**:

```json
[{"i":12,"c":3,"t0":123450,"t1":127890,"text":"And that's why we left.",
  "nsp":0.02,"lp":-0.21,
  "w":[{"t":"And","t0":123450,"t1":123700,"p":0.98},{"t":"that's","t0":123700,"t1":124010,"p":0.95}]}]
```

Field meanings:
- `nsp` = `whisper_full_get_segment_no_speech_prob`.
- `lp` = mean token `plog` over text tokens.
- `w` = assembled words (§4.6).

Text is guaranteed valid UTF-8, and JSON escaping covers `"`, `\`, and control characters < 0x20. The Dart decoder ignores unknown keys, so later schemas add keys only.

**Language JSON** (DETECT): `{"lang":[{"code":"hi","p":0.62},{"code":"ur","p":0.21},{"code":"en","p":0.05}],"speechStartMs":4120}`.

### 4.6 Shim internals

**Job thread state machine:**

```
PLANNING ─► (VAD-free chunk plan from RMS) ─► for chunk k:
   wait while paused ─► if cancel → CANCELLED
   read samples [k.start,k.end) (s16 → f32) ─► whisper_full_with_state(ctx, state, p, pcm, n)
       p.language = job language (fixed), p.n_threads = current, p.vad = …, p.token_timestamps = 1,
       p.max_len = 0, p.no_context = false, p.initial_prompt = carry (if any),
       p.abort_callback = reads job->cancel || job->abort_chunk,
       p.encoder_begin_callback = !(cancel || abort_chunk),
       p.progress_callback = stores chunk-local % (atomic)
   rc != 0 && abort_chunk → mark chunk for redo, state = PAUSED (wait for resume)
   rc != 0 && cancel      → CANCELLED
   rc != 0 otherwise      → FAILED(DV_ERR_INFERENCE)
   collect segments → assemble words → offset by k.start → append under mutex; chunks_completed++
 ─► SUCCEEDED
```

- **Model and state:** one `whisper_context` per model, created with `_no_state`, plus one `whisper_state` per job (`whisper_init_state`), freed in `dv_job_free`. The context is shared between sequential jobs, never concurrently (whisper's thread-safety rule [VERIFIED in header comment]).
- **Chunk planning:** chunk boundaries come from 20 ms RMS frames. For target `T`, search `[T − 15 s, T + 5 s]` for the minimum-energy 400 ms window and cut at its center. This is deterministic, so a resumed job re-plans identical chunks from `range_start_ms`.
  - We do not use VAD to plan chunks: it would mean a second pass over the whole file in windows. whisper's own VAD runs inside each chunk.
  - RAM for one 180 s chunk is about 11.5 MB f32 PCM plus about 5.8 MB mel. A 1 h file never needs more than one chunk in memory.
- **Language:** TRANSCRIBE always receives an explicit language, chosen by the user or by a prior DETECT job. Passing one language to every chunk prevents mid-video flip-flopping.
- **DETECT mode:**
  1. Run whisper VAD (`whisper_vad_segments_from_samples` on windows of the first `detect_search_ms`) to find the first speech start.
  2. Take up to 30 s of samples from there.
  3. Run `whisper_pcm_to_mel_with_state` and `whisper_lang_auto_detect_with_state`, which costs one encoder pass.
  4. Return the top-N languages. With no speech in the window, return `DV_ERR_NO_SPEECH`.
- **Word assembly** (`dv_words.cpp`):
  - Iterate tokens with `whisper_full_get_token_data_from_state`. Skip ids ≥ `whisper_token_eot(ctx)` (special and timestamp tokens).
  - Concatenate raw token **bytes**. Start a new word when a token begins with `' '` (space-delimited scripts) or, for no-space scripts (zh, ja, yue, th, lo, km, my, bo), at each token whose accumulated bytes form complete UTF-8.
  - Emit a word only when its byte buffer is valid UTF-8. Multi-byte characters often split across BPE tokens. A trailing invalid sequence at segment end becomes U+FFFD.
  - Pure-punctuation tokens attach to the previous word.
  - `t0`/`t1` are the min/max of member token `t0`/`t1` (centiseconds → ms), clamped to the segment and forced monotonic. `p` is the minimum member token probability.
- **Hallucination guard in native:** whisper already skips segments when `no_speech_prob > no_speech_thold && avg_logprob < logprob_thold`, and falls back on temperature when entropy/logprob are bad. The shim adds nothing more. All text-level filtering is in Dart (§8.3), where it is unit-testable.
- **Threads:** `dv_job_set_threads` takes effect at the next chunk. Dart computes threads from the device profile and thermal state (§6).
- **Logging:** `whisper_log_set` forwards to `os_log(subsystem "com.vecvel.danaview.whisper")` or `__android_log_print("DanaviewWhisper")` at the configured level. **Transcript text, prompts and file paths are never logged**, by policy and by test (§16).
- **Crash surface:** `GGML_ASSERT` aborts the process. We reduce exposure by:
  - loading only SHA-256-verified models,
  - checking the `ggml` magic and size before `whisper_init`,
  - validating WAV headers strictly (PCM, 1 channel, 16 kHz, 16-bit, data chunk sized),
  - rejecting chunks shorter than 1 s (they skip, and are not sent to whisper),
  - never calling into a context that is still loading.

### 4.7 Dart runtime API (`danaview_whisper`)

```dart
/// Opens the native library for this CPU and checks the ABI. Never throws; see [support].
abstract interface class WhisperRuntime {
  static Future<WhisperRuntime> open({WhisperDeviceChannel? channel, DvBindingsFactory? bindings});

  WhisperSupport get support;            // supported(tiers) | unsupported(reason)
  String get engineVersion;              // "1.9.4"
  WhisperDeviceChannel get device;       // profile + events (§6)

  /// Starts loading; completes when ready. [cancel] abandons the result (the native load finishes, then frees).
  Future<WhisperModel> loadModel(String modelPath, {WhisperModelOptions options = const WhisperModelOptions(),
      WhisperCancelToken? cancel});
}

final class WhisperModelOptions { const WhisperModelOptions({this.preferGpu = true, this.flashAttention = true,
    this.dtwPreset}); final bool preferGpu; final bool flashAttention; final WhisperDtwPreset? dtwPreset; }

abstract interface class WhisperModel {
  WhisperModelInfo get info;             // multilingual, usesGpu, gpuFallback
  bool get isBusy;
  WhisperJob detectLanguage(WhisperDetectRequest request);
  WhisperJob transcribe(WhisperTranscribeRequest request);
  Future<void> release();
}

final class WhisperTranscribeRequest {
  const WhisperTranscribeRequest({required this.wavPath, required this.language, required this.threads,
      this.rangeStart = Duration.zero, this.rangeEnd, this.vad, this.decode = const WhisperDecodeOptions(),
      this.chunkTarget = const Duration(seconds: 180), this.chunkSearch = const Duration(seconds: 15),
      this.carryPromptWords = 24, this.initialPrompt});
  final String wavPath; final String language; final int threads;
  final Duration rangeStart; final Duration? rangeEnd;
  final WhisperVadOptions? vad;          // null = off (only for tests)
  final WhisperDecodeOptions decode;     // thresholds, beam/greedy, suppressNonSpeech, tokenTimestamps
  final Duration chunkTarget, chunkSearch; final int carryPromptWords; final String? initialPrompt;
}

abstract interface class WhisperJob {
  Stream<WhisperJobUpdate> get updates;  // broadcast; throttled to ≤ 4 Hz for status
  Future<WhisperJobResult> get result;   // throws WhisperException (kind: cancelled, inference, oom, …)
  void cancel();
  void pause({bool abortCurrentChunk = false});
  void resume();
  set threads(int value);
}

sealed class WhisperJobUpdate { const WhisperJobUpdate(); }
final class WhisperJobStatus extends WhisperJobUpdate { /* state, phase, fraction, chunkIndex, chunkCount,
  chunksCompleted, processed, computeTime, threads, language, languageP */ }
final class WhisperSegmentsAdded extends WhisperJobUpdate { final List<RawSegment> segments; final int chunk;
  final bool chunkFinal; }
final class WhisperLanguageResult extends WhisperJobUpdate { final List<LanguageProbability> top;
  final Duration? speechStart; }

final class RawSegment { final int index, chunk; final Duration start, end; final String text;
  final double noSpeechProb, avgLogProb; final List<RawWord> words; }
final class RawWord { final String text; final Duration start, end; final double probability; }

enum WhisperErrorKind { libraryUnavailable, abiMismatch, modelLoadFailed, outOfMemory, invalidAudio, io,
  inference, cancelled, busy, vadModelMissing, noSpeech, internal }
final class WhisperException implements Exception { const WhisperException(this.kind, [this.detail]);
  final WhisperErrorKind kind; final String? detail; }
```

**Polling implementation** (`whisper_job.dart`):
- A `Timer.periodic(250 ms)` reads `dv_job_status_get`.
- When `segments_ready > taken`, it calls `take_segments_json(taken, 256)`, decodes, and emits.
- When the state is terminal, it does a final take, completes `result`, and calls `dv_job_free`.
- A `Finalizer` frees the job if Dart drops it.
- A job that has not changed `compute_ms` while RUNNING for 120 s emits a `stalled` diagnostic. Nothing kills it automatically.

### 4.8 Platform channel (`DanaviewWhisperPlugin`)

| Method / event | Returns / payload | iOS API | Android API |
|---|---|---|---|
| `deviceProfile` | `{os, osVersion, model, physicalRam, isLowRam, perfCores, totalCores, is64Bit, cpuFeatures[], gpuFamily, isSimulator, lowPowerMode, thermal}` | `ProcessInfo.physicalMemory/thermalState/isLowPowerModeEnabled`, `MTLDevice.supportsFamily`, sysctl `hw.perflevel0.physicalcpu` | `ActivityManager.MemoryInfo.totalMem`, `isLowRamDevice`, `/sys/devices/system/cpu/cpu*/cpufreq/cpuinfo_max_freq` clustering (as upstream's `WhisperCpuConfig`) |
| `availableMemory` | bytes | `os_proc_available_memory()` (iOS 13+) [VERIFY header `os/proc.h`] | `MemoryInfo.availMem − threshold` |
| `freeDiskBytes(path)` | bytes | `volumeAvailableCapacityForImportantUsageKey` | `StatFs(path).availableBytes` |
| `isNetworkMetered` | bool | `NWPathMonitor` `isExpensive \|\| isConstrained` | `ConnectivityManager.isActiveNetworkMetered` |
| `excludeFromBackup(path)` | bool | `URLResourceValues.isExcludedFromBackup = true` | no-op (manifest rules, §5.4) |
| `beginBackgroundTask(name)` / `endBackgroundTask(id)` | int / void | `UIApplication.beginBackgroundTask(withName:expirationHandler:)`; expiry emits an event | n/a. Android uses the engine's foreground service via `BackgroundWorkGuard` (§6.3) |
| event `thermal` | `nominal\|fair\|serious\|critical` | `thermalStateDidChangeNotification` | `PowerManager.addThermalStatusListener` (API 29+): NONE/LIGHT→nominal, MODERATE→fair, SEVERE→serious, CRITICAL+→critical; API < 29: never emits |
| event `memoryWarning` | n/a | `didReceiveMemoryWarningNotification` | `onTrimMemory(level ≥ TRIM_MEMORY_RUNNING_LOW)` |
| event `lowPower` | bool | `NSProcessInfoPowerStateDidChange` | `ACTION_POWER_SAVE_MODE_CHANGED` |
| event `backgroundTaskExpiring` | id | expiration handler | n/a |

Swift sketch:

```swift
public final class DanaviewWhisperPlugin: NSObject, FlutterPlugin, FlutterStreamHandler {
  public static func register(with registrar: FlutterPluginRegistrar)   // channel "danaview/whisper", events "danaview/whisper/events"
  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult)
  public func onListen(withArguments: Any?, eventSink: @escaping FlutterEventSink) -> FlutterError?
  public func onCancel(withArguments: Any?) -> FlutterError?
}
```

Registration needs no Runner change. `GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)` in the existing `AppDelegate.didInitializeImplicitFlutterEngine` already registers it [VERIFIED: the AppDelegate calls it].

Kotlin sketch:

```kotlin
class DanaviewWhisperPlugin : FlutterPlugin, MethodChannel.MethodCallHandler, EventChannel.StreamHandler, ComponentCallbacks2 {
  override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding)
  override fun onMethodCall(call: MethodCall, result: MethodChannel.Result)
  override fun onListen(arguments: Any?, events: EventChannel.EventSink)
  override fun onCancel(arguments: Any?)
  override fun onTrimMemory(level: Int)
}
```

---

## 5. Models: catalog, download, verification, storage, consent, deletion

### 5.1 Catalog (`danaview_transcription/lib/src/catalog/speech_model_catalog.dart`)

All files are multilingual (no `.en` variants, because the user picks the language). Base URL: `https://huggingface.co/ggerganov/whisper.cpp/resolve/5359861c739e955e79d9a303bcbc70fb988958b1/`.

| id | Tier (UI) | File | Bytes [VERIFIED] | SHA-256 [VERIFIED] | Min device RAM | Est. peak RSS added [VERIFY AI-19] | DTW preset |
|---|---|---|---|---|---|---|---|
| `whisper-tiny-q5_1` | Fast | `ggml-tiny-q5_1.bin` | 32,152,673 (30.7 MiB) | `818710568da3ca15689e31a743197b520007872ff9576237bda97bd1b469c3d7` | 2 GB | ≤ 200 MB | `TINY` |
| `whisper-base-q5_1` | **Balanced (default)** | `ggml-base-q5_1.bin` | 59,707,625 (56.9 MiB) | `422f1ae452ade6f30a004d7e5c6a43195e4433bc370bf23fac9cc591f01a8898` | 3 GB | ≤ 300 MB | `BASE` |
| `whisper-small-q5_1` | Accurate | `ggml-small-q5_1.bin` | 190,085,487 (181.3 MiB) | `ae85e4a935d7a567bd102fe55afc16bb595bdb618e11b2fc7591bc08120411bb` | 4 GB | ≤ 650 MB | `SMALL` |
| `silero-v6.2.0` (aux, always with any tier) | n/a | `ggml-silero-v6.2.0.bin` from `https://huggingface.co/ggml-org/whisper-vad/resolve/9ffd54a1e1ee413ddf265af9913beaf518d1639b/` | 885,098 | `2aa269b785eeb53a82983a20501ddf7c1d9c48e33ab63a41391ac6c9f7fb6987` | n/a | ~5 MB | n/a |

These are the upstream README's unquantized figures for reference: tiny 75 MiB / ~273 MB, base 142 MiB / ~388 MB, small 466 MiB / ~852 MB [VERIFIED]. The q5_1 weights are about 2.5× smaller, and flash attention shrinks the encoder buffers. Peak figures are budgets that AI-19 must confirm on devices.

**Rejected for v1:**
- `medium` (514 MiB q5_0) and `large-v3-turbo` (547 MiB q5_0): too large and slow for phones.
- `q8_0` variants: 30–40% bigger downloads for marginal accuracy.
- The catalog supports per-platform overrides. If AI-19 shows q8_0 decoding much faster on Android dotprod CPUs, base can switch to `ggml-base-q8_0.bin` (81,768,585 B, `c577b9a8…dcb7d9`) on Android only.

```dart
enum SpeechModelTier { fast, balanced, accurate }

final class SpeechModelSpec {
  const SpeechModelSpec({required this.id, required this.tier, required this.fileName, required this.url,
      required this.bytes, required this.sha256, required this.minDeviceRamBytes,
      required this.peakMemoryBudgetBytes, required this.dtwPreset, this.platforms = const {}});
  final String id; final SpeechModelTier tier; final String fileName; final Uri url;
  final int bytes; final String sha256; final int minDeviceRamBytes; final int peakMemoryBudgetBytes;
  final WhisperDtwPreset dtwPreset; final Set<String> platforms; // empty = all
  String get host => url.host;           // 'huggingface.co', shown in the consent view
}
abstract final class SpeechModelCatalog {
  static const int revision = 1;                       // bump when entries change
  static const List<SpeechModelSpec> models = [...];
  static const SpeechModelSpec vad = ...;
  static const Set<String> acceptedLegacySha256 = {};  // installed files from older catalogs still valid
}
```

**Tier gating (`SpeechModelPolicy.availableTiers(profile)`):**
- A tier is offered only if `physicalRam ≥ minDeviceRamBytes` and the device is 64-bit.
- `isLowRamDevice` (Android) allows Fast only.
- The recommended tier is Balanced, or Fast when RAM < 3 GB.
- The UI shows non-qualifying tiers disabled with "Needs a device with more memory".
- For languages in the low-accuracy list (§9.4), the sheet hints "For Hindi, Accurate gives noticeably better results" when that tier is available.

### 5.2 Storage layout

| Path (under `getApplicationSupportDirectory()`) | Content | Backup | Cleared by |
|---|---|---|---|
| `danaview/speech/models/<file>` | verified model files | **excluded** (iOS resource key; Android rules) | user delete only |
| `danaview/speech/models/<file>.part` + `.part.json` | partial download + sidecar `{url, bytes, sha256, written, updatedAt, catalogRevision}` | excluded | completion, cancel-with-discard, 7-day stale sweep |
| `danaview/speech/models/manifest.json` | `{schema:1, installed:[{id, file, sha256, bytes, installedAt, verifiedAt, lastUsedAt}]}` written atomically (temp + rename) | excluded | n/a |
| `danaview/speech/transcripts/<key>.json` | transcript cache (§8.4), LRU budget 64 MiB | included (small, user-derived) [ASSUMPTION; Persistence may prefer excluded] | LRU eviction; never by "Clear cache" |
| `danaview/speech/transcripts/<key>.partial.jsonl` | per-chunk checkpoints | included | on completion; 30-day sweep |
| `danaview/speech/jobs/<jobId>.json` | resumable job record (§8.6) | excluded | on completion/discard |
| `danaview/speech/work/<jobId>/<unit>.wav` | extracted 16 kHz WAV (about 1.92 MB/min) | excluded | right after that unit is transcribed; startup sweep of anything older than 24 h |

On iOS this is `Library/Application Support`; on Android it is `files/` [VERIFIED: `AppStorage` uses `getApplicationSupportDirectory`]. WAVs deliberately do **not** live in the cache folder, because Settings › Storage "Clear cache" (`ux.md` §4.8) could delete them in the middle of a job. **Original media is only ever read** by the engine extractor, never written.

### 5.3 Downloader (`model_downloader.dart`)

```dart
abstract interface class SpeechModelStore {
  Future<SpeechModelInventory> inventory();             // installed specs, partials, bytes
  Stream<SpeechModelInventory> watch();
  Future<InstalledSpeechModel?> installed(String modelId); // verified + VAD present
  ModelDownload download(UserConsent consent);          // spec + VAD; one at a time (dedupes)
  Future<void> delete(String modelId);                  // refuses while a job uses it
  Future<void> deleteAll();                             // models + VAD + partials
  Future<FolderUsage> measure();                        // for StorageContributor
}
abstract interface class ModelDownload {
  Stream<ModelDownloadProgress> get progress;           // ≤ 4 Hz: received, total, bytesPerSecond, phase
  Future<InstalledSpeechModel> get done;                // throws ModelDownloadFailure
  void cancel({bool keepPartial = true});
}
enum ModelDownloadPhase { preparing, downloading, verifying, finishing }
enum ModelDownloadFailureKind { offline, timeout, server, secureConnection, interrupted, diskFull,
  checksumMismatch, sizeMismatch, cancelled, consentMismatch }
```

**Algorithm:**
1. **Preflight.**
   - `consent.disclosure` must equal the spec (id, file, bytes, sha256, host); otherwise fail with `consentMismatch`.
   - `freeDiskBytes ≥ remaining + 64 MiB`, else `diskFull`.
   - Acquire the wakelock (`ux.md` §4.7) and, on iOS, a background task.
2. **Resolve the redirect.** `GET <huggingface URL>` with `followRedirects = false` and `User-Agent: Danaview/<version>` (no identifiers).
   - Expect `302`.
   - Check `x-linked-size == spec.bytes` and `x-linked-etag == spec.sha256`. A mismatch fails **before** any download, with `sizeMismatch`/`checksumMismatch`.
   - Read `Location`. It is a signed CDN URL with `Expires`, so it is never persisted and resumes always re-resolve.
3. **Ranged GET.** Request `Location` with `Range: bytes=<partLen>-`.
   - `206` appends.
   - `200` (range ignored) truncates and restarts.
   - `416` with `partLen == bytes` goes to verification; otherwise delete and restart.
   - Write with `RandomAccessFile` in append mode. Rewrite the sidecar every 4 MiB.
   - Connection timeout 15 s, idle-read timeout 30 s.
4. **Retries.**
   - Transient errors (reset, timeout, 5xx, 429) retry up to 3 times with 2/4/8 s backoff plus jitter, re-resolving the redirect each time.
   - `HandshakeException` maps to `secureConnection`, with the same copy as `SpeedTestException`.
   - Offline detection uses the existing `SocketException` classification pattern (`speed_test.dart`).
5. **Verify.**
   - Run `Isolate.run` streaming SHA-256 over the `.part` file. A mismatch deletes the part and fails with `checksumMismatch`.
   - Check the `ggml` magic (first 4 bytes `0x67676d6c`, little-endian `lmgg` as written by the converter) [VERIFY exact byte order in AI-09].
6. **Finish.** Rename atomically to the final name, call `excludeFromBackup`, update `manifest.json`, emit `done`. The VAD file follows the same path and is skipped if already installed.
7. **App lifecycle.** On iOS background, keep downloading until the background task expires, then `cancel(keepPartial: true)` and record `interrupted`. On `resumed` the controller offers "Resume download", which is automatic if the sheet is still open.

We use the existing `NetworkCancelToken` (`danaview_data`) for cancellation. The fake-client pattern from `StreamProbe` (`clientFactory`) makes every branch unit-testable.

**Why not a native background downloader?** The files are 31–181 MB and the download is user-initiated and watched in a sheet. Foreground plus `Range` resume covers it. `background_downloader` 9.6 needs Flutter 3.47 [VERIFIED]. An iOS background `URLSession` needs AppDelegate plumbing. Revisit only if field data shows abandoned downloads (deferred ticket AI-D4).

**Load-time integrity.** Before `dv_model_load`:
- check file size equals the manifest,
- check the magic,
- check the manifest `verifiedAt` is set.

A full re-hash runs only if the size differs or the manifest is missing. A `DV_MODEL_FAILED` on a verified file deletes it and asks the user to download again ("The speech model is damaged").

### 5.4 Backup exclusion

- **iOS:** `isExcludedFromBackup` on `danaview/speech/models/` and on each file.
- **Android:** the app manifest gains `android:fullBackupContent="@xml/danaview_backup_rules"` (API ≤ 30) and `android:dataExtractionRules="@xml/danaview_data_extraction_rules"` (API 31+), each with `<exclude domain="file" path="danaview/speech/models/"/>`, `.../jobs/` and `.../work/`.

These XML files are app-level, so they are **co-owned with Persistence**, which also decides project backup policy. AI contributes the exclusion lines (AI-09). Without them, Android Auto Backup's 25 MB quota would be exceeded [VERIFY quota], and backups could silently stop.

### 5.5 Consent

`ux.md` §2.4 asks that no download path can skip consent. Dart cannot share a library-private constructor across packages, so the guarantee is a **binding plus a test**:

```dart
/// Exactly what the consent view displayed. Built from the spec; compared again at download time.
final class ConsentDisclosure {
  ConsentDisclosure.of(SpeechModelSpec spec, {required bool includesVad});
  final String modelId, fileName, host, sha256; final int totalBytes; // model + VAD when needed
}
final class UserConsent {
  /// Only `model_consent_view.dart` calls this (enforced by test/architecture/consent_call_sites_test.dart,
  /// which scans the repo for `UserConsent.accepted(`).
  UserConsent.accepted(this.disclosure, {required this.acceptedAt});
  final ConsentDisclosure disclosure; final DateTime acceptedAt;
}
```

Consent is **per download**. Each download needs a fresh tap, and nothing is remembered that would allow a silent download later. Consent is never inferred from a previous install: after "Delete speech model", the next use asks again.

### 5.6 Deletion

From Settings › Video editor › Auto captions, or from Storage › "Speech model" (`ux.md` §4.8):
- `showDanaviewConfirm(destructive: true, title: 'Delete speech model?', message: 'Auto captions won't work until you download it again (57 MB). Captions already in your projects stay.')`.
- While a job is running, the action is disabled with "In use by auto captions".
- Deleting the last tier also deletes the VAD file. Transcripts are kept (they are project-derived text) and age out by LRU.

---

## 6. Device resources: memory, thermal, battery, background

### 6.1 Preflight (`ResourceGovernor.preflight`)

| Check | Rule | Outcome |
|---|---|---|
| Platform / ABI / OS | `WhisperSupport` | `unsupported(reason)`: the sheet shows `DanaviewEmptyState` with an explanation |
| RAM tier | §5.1 | Tier disabled |
| Available memory | iOS `os_proc_available_memory() ≥ 1.3 × peakBudget`; Android `availMem − threshold ≥ 1.3 × peakBudget` and not `lowMemory` | Otherwise the sheet suggests a smaller tier ("Close other apps or choose Fast") |
| Disk | `freeDisk ≥ Σ unit WAV bytes (1.92 MB/min) + 64 MiB` | `diskFull` |
| Low power / Battery Saver | warn only | Inline note: "Low Power Mode is on, so this may take longer." |
| Thermal ≥ serious at start | warn | "Your device is warm. Captions will be created more slowly." |
| Export running | queue | Starts after export ("Waiting for export to finish"); see §6.3 |

### 6.2 Thread and thermal policy

```
perf = device.perfCores (iOS sysctl; Android max-freq clustering, as upstream WhisperCpuConfig)
base threads = clamp(perf, 2, 4)            // more threads than big cores stalls on LITTLE cores
thermal nominal/fair  → base
thermal serious       → max(2, base ~/ 2), plus a 2 s cooldown between chunks
thermal critical      → pause at the next chunk boundary; resume when ≤ serious for 10 s
lowPower              → max(2, base − 1)
```

The progress panel shows "Paused while your device cools down". Thermal events come from the plugin's EventChannel. Android below API 29 has no thermal signal, so it runs at base threads.

**Memory pressure during a job:** a `memoryWarning` event triggers `EditorLifecycle` cache trims (`ux.md` §4.7) and, on iOS, pauses preview playback. The job continues. The model is released right after a job when memory is low; normally it stays loaded for 60 s for a quick Regenerate.

### 6.3 Background and app lifecycle

| Platform | `AppLifecycleState.hidden/paused` | `resumed` |
|---|---|---|
| iOS (GPU or CPU) | `job.pause(abortCurrentChunk: true)` at once. Background GPU work is not allowed on iOS [VERIFY exact failure mode], and CPU time is limited to about 30 s. The finished chunks are already checkpointed. | `job.resume()`. The aborted chunk is redone. Lost work is at most one chunk (≤ 180 s of audio, ≤ ~20 s compute on mid devices). |
| Android | Keep running. Ask `BackgroundWorkGuard.acquire('Creating captions', progress)`, which the Android engine maps to its foreground service. Type is `mediaProcessing` on API 35+ and `dataSync` below [ASSUMPTION; Android engine owns the service, its type and the `POST_NOTIFICATIONS` flow]. Without a lease the job still runs. If the process dies, the checkpoint resumes it next time. | n/a |

```dart
abstract interface class BackgroundWorkGuard {          // implemented by the engine areas (ux.md EditorCapabilities.backgroundKind)
  Future<BackgroundLease?> acquire({required String title, required Stream<double> progress});
}
abstract interface class BackgroundLease { Future<void> release(); }
```

**Export contention:** both export (hardware encoder plus GPU) and inference are heavy. Generation **waits** while an export is active and **pauses at the next chunk boundary** if an export starts. The `ux.md` `tasks_controller` exposes `exportActive`. Both show up in the editor's Background tasks sheet (§11.5).

**Leaving the editor while generating:** the controller asks "Captions are still being created. Leave and stop?" with the buttons "Keep editing" and "Leave". Leaving cancels the job. The checkpoint is kept, so running the same request again resumes it (§8.6). We do not insert into a closed project.

---

## 7. Audio extraction (AI ↔ native engines)

### 7.1 Contract (Dart port, defined here; implemented by the engine package)

```dart
/// Decodes [range] of one audio stream of [source] to a canonical RIFF/WAVE file:
/// PCM signed 16-bit little-endian, 1 channel, 16,000 Hz, data chunk only after "fmt ".
/// Sample 0 corresponds exactly to source time [range.start] on the same clock the editor uses for
/// that media (edit lists and encoder priming applied).
abstract interface class SpeechAudioExtractor {
  SpeechAudioExtraction extract(SpeechAudioRequest request);
}
final class SpeechAudioRequest {
  const SpeechAudioRequest({required this.media, required this.range, required this.outputPath, this.audioStream});
  final MediaRef media;          // resolved by Persistence: path, content:// URI, or security-scoped bookmark
  final TimeRange range;         // source time, µs
  final int? audioStream;        // null = default/first audio track
  final String outputPath;       // under danaview/speech/work/
}
abstract interface class SpeechAudioExtraction {
  Stream<double> get progress;                 // 0..1, ≤ 10 Hz
  Future<ExtractedSpeechAudio> get result;     // throws SpeechAudioFailure
  void cancel();                               // deletes partial output
}
final class ExtractedSpeechAudio { final String path; final int frames; final TimeUs duration;
  final int sourceChannels; final int sourceSampleRate; final String codec; }
enum SpeechAudioFailureKind { mediaOffline, permissionDenied, noAudioTrack, unsupportedCodec, decodeFailed,
  diskFull, cancelled }
```

**Proposed engine binding** [ASSUMPTION; the engine docs decide]: add `extractSpeechAudio(SpeechAudioRequest) → MediaJob<ExtractedSpeechAudio>` to `EditorEngine.jobs` (`ux.md` §2.3 `MediaJobs`), next to proxies, reverse and freeze frame. Channel errors map to `SpeechAudioFailureKind`, never a raw `PlatformException`.

**Source choice:** always the **original** media. If the original is offline but a proxy exists, use the proxy's audio (proxies keep audio and timing [ASSUMPTION, Persistence/engine]) and note "using preview copy" in diagnostics.

### 7.2 iOS implementation guidance (iOS engine area)

1. `AVURLAsset(url:, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])` and `loadTracks(withMediaType: .audio)`. Fall back to the sync API below iOS 15.
2. `AVAssetReader` with `timeRange = CMTimeRange(start: µs→CMTime(timescale 1_000_000), end:)`. Output: `AVAssetReaderTrackOutput(track:, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false])`. This decodes at the **native rate and layout**, with no conversion in the reader.
3. **Downmix** to mono with a fixed matrix:
   - mono → copy; stereo → 0.5·L + 0.5·R;
   - 5.1/7.1 (from `AudioChannelLayout`) → 0.5·C + 0.25·(L+R) + 0.125·(Ls+Rs), LFE dropped, renormalized. The centre channel carries dialogue.
4. `AVAudioConverter`, mono Float32 at the source rate → 16 kHz mono Int16, `sampleRateConverterQuality = .high`.
5. Stream the WAV to the file: write the header placeholder, then patch the sizes at the end.
6. Report progress as decoded PTS over the range, and check cancellation every buffer.

Supported formats are whatever AVFoundation decodes (AAC, ALAC, MP3, AC-3/E-AC-3, LPCM). MKV, WebM, Opus-in-MKV and AVI are not supported (`ux.md` §0.8). These map to `unsupportedCodec`. [VERIFY that `AVAssetReader.timeRange` trims decoded LPCM sample-accurately; the AI-10 clap test enforces ±20 ms.]

### 7.3 Android implementation guidance (Android engine area)

1. Use `androidx.media3.inspector.MediaExtractorCompat` (Media3's extractors, matching ExoPlayer timing including MP4 edit lists and gapless metadata), with `setDataSource(context, uri, null)`. Then `selectTrack(audioStream)` and `seekTo(range.start, SEEK_TO_PREVIOUS_SYNC)`.
2. Decode with framework `MediaCodec` (async callback mode on a `HandlerThread`). Request `KEY_PCM_ENCODING = ENCODING_PCM_FLOAT` on API 24+, falling back to 16-bit.
3. Drop samples before `range.start` and after `range.end` using `presentationTimeUs` plus the sample index, which gives sample-accurate trim.
4. Downmix with `ChannelMixingAudioProcessor` using `ChannelMixingMatrix(inputChannels, 1, coefficients)`, the same coefficients as iOS. Resample with `SonicAudioProcessor.setOutputSampleRateHz(16000)`. Both are in `media3-common` 1.11.1 [VERIFIED].
5. Write the WAV as on iOS.

Codecs depend on device decoders. AC-3/E-AC-3/DTS/TrueHD are usually absent and map to `unsupportedCodec`. The Media3 version is pinned by the Android engine doc. The current stable is 1.11.1 [VERIFIED].

### 7.4 Not used: timeline mixdown

We could render the timeline's audio through the export graph instead. Per-clip source extraction wins for these reasons:
1. Sped-up audio (up to 4×) hurts recognition. Source-time words mapped through the time map give exact timeline times at any speed or ramp.
2. Background music on other tracks hurts recognition. Per-clip extraction includes only the tracks the user chose.
3. Trims, moves and splits after generation do not invalidate transcripts.
4. Both engines need only a single-file decoder, not a composition render.

Reversed clips are excluded (reversed speech is meaningless). Freeze frames have no audio.

---

## 8. Transcription pipeline (`danaview_transcription`)

### 8.1 Service (implements `ux.md` §2.4, extended)

```dart
abstract interface class TranscriptionService {
  // ux.md §2.4 minimum
  List<TranscriptionLanguage> get languages;                  // §9.4 (99 entries + "auto" handled by UI)
  Future<SpeechModelStatus> modelStatus();                    // of defaultModel
  SpeechModelSpec get defaultModel;                           // device-recommended tier
  Stream<ModelDownloadProgress> downloadModel({required UserConsent consent});
  Future<void> cancelDownload();
  Future<void> deleteModel();                                 // = deleteAll()
  TranscriptionJob transcribe(TranscriptionRequest r);
  // AI extensions (UX adopts these when merging)
  Future<TranscriptionSupport> support();
  List<SpeechModelOffer> get offers;                          // all tiers with availability on this device
  Future<SpeechModelStatus> modelStatusOf(String modelId);
  Future<void> deleteModelById(String modelId);
  Future<TranscriptionPreflight> preflight(TranscriptionRequest r);
  Future<List<SubtitleCueDraft>> resegment(CaptionProvenance provenance, SegmentationSettings settings,
      TimelineView timeline);                                 // instant "Regenerate → re-split"
  TranscriptionJob? get activeJob;                            // tasks sheet, leave-editor guard
  Future<ResumableTranscription?> resumableFor(ProjectId project);
  StorageContributorData storage();                           // for the 'Speech model' contributor
}

sealed class SpeechModelStatus { }   // missing | downloading(progress) | ready(InstalledSpeechModel) | corrupt

final class TranscriptionRequest {
  const TranscriptionRequest({required this.project, required this.scope, required this.language,
      required this.modelId, required this.segmentation, this.includeSoundDescriptions = false,
      required this.target, required this.timeline});
  final ProjectId project;
  final TranscriptionScope scope;                // clip(ItemId) | items(Set<ItemId>) | timeline(tracks: Set<TrackId>?, range: TimeRange?)
  final SpokenLanguage language;                 // auto | fixed(code)
  final String modelId;
  final SegmentationSettings segmentation;
  final bool includeSoundDescriptions;
  final CaptionTarget target;                    // newTrack | replaceTrack(TrackId) | replaceInRange(TrackId, TimeRange)
  final TimelineView Function() timeline;        // read at start (plan) and again at the end (mapping)
}

abstract interface class TranscriptionJob {
  String get id;
  Stream<TranscriptionProgress> get progress;    // ≤ 4 Hz
  Future<TranscriptionResult> get result;        // drafts + provenance + summary; throws TranscriptionFailure
  void cancel();
  void provideLanguage(String code);             // answers TranscriptionPhase.needsLanguage
}

final class TranscriptionProgress { final TranscriptionPhase phase; final double fraction;
  final Duration? eta; final int unitIndex, unitCount; final TimeUs processed, total;
  final String? partialText;                     // last ≤ 80 chars, shown in the panel, never logged
  final PauseReason? paused;                     // background | thermal | exportRunning | waitingForExport
  final List<LanguageProbability>? languageCandidates; }
enum TranscriptionPhase { preparing, downloadingModel, extractingAudio, loadingModel, detectingLanguage,
  needsLanguage, transcribing, segmenting, done }

final class TranscriptionResult { final List<SubtitleCueDraft> drafts; final CaptionProvenance provenance;
  final CaptionTarget target; final TranscriptionSummary summary; } // cues, words, language, skipped clips + reasons
final class SubtitleCueDraft { final TimeRange range; final String text; }  // timeline time, frame-quantized, '\n' between lines
```

The controller applies `result` through the domain command (§10). The service never mutates the project. This keeps `danaview_transcription` pure and lets the job finish even if the timeline changed meanwhile, because mapping uses `timeline()` at the end.

### 8.2 Steps

1. **Plan** (`TranscriptionPlanner`, pure). Turn `scope` plus `timeline()` into `TranscriptionUnit`s.
   - Each unit is `{MediaRef media, int? audioStream, TimeRange sourceRange, Set<ItemId> clips, int priority}`.
   - Include clips that are audible. Exclude:
     - muted clips, clips with volume 0, and clips on muted tracks (when any track is soloed, only soloed tracks count),
     - clips with `reversed == true`, reported as skipped "reversed clip",
     - freeze frames and images,
     - media with no audio stream (from the media pool's probe),
     - tracks the user unchecked (by default tracks with role `music` [ASSUMPTION: Domain adds `AudioRole {voice, music, effects}`, or the import flow marks music clips]).
   - Merge clips of the same `media/audioStream` whose source ranges overlap or are within 5 s, into one unit covering the union. This turns a split clip into one transcription.
   - Pad each unit by 0.5 s on both sides, clamped to the media duration, so edge words are complete.
2. **Cache lookup.** `TranscriptKey = sha256(mediaFingerprint | audioStream | modelSha256 | language | paramsVersion | vad)`. The cache stores the covered source ranges. A unit is a hit if a cached transcript covers its range; we reuse it filtered to the range. Partial coverage is a miss in v1 (gap-filling is deferred). The `mediaFingerprint` comes from Persistence's media pool (size, duration, partial hash) [ASSUMPTION]. As a fallback we compute `sha256(size, duration, first 1 MiB, last 1 MiB)`.
3. **Ensure the model.** Not installed → phase `downloadingModel`, which requires the consent flow before the job starts (the controller handles it, §11.2). Then `loadModel` (phase `loadingModel`), reusing a loaded handle when possible.
4. **Extract** each missing unit's audio to `work/<job>/<unit>.wav` (phase `extractingAudio`). Units are processed sequentially: extract unit k+1 while unit k is transcribing (bounded pipeline depth 1).
5. **Detect the language** when it is `auto` and not cached. Use a DETECT job on the unit with the highest priority, then the longest.
   - If top-1 p ≥ 0.6, use it.
   - Otherwise emit `needsLanguage` with the top 3 and wait for `provideLanguage`. The sheet shows a picker with those preselected.
   - `DV_ERR_NO_SPEECH` on every unit fails with `noSpeech`.
6. **Transcribe** each unit (phase `transcribing`):
   - `WhisperModel.transcribe(range = resume point …)`.
   - On each `WhisperSegmentsAdded` with `chunkFinal`, append the chunk to `<key>.partial.jsonl`. This is the checkpoint.
   - On success, normalize (§8.3), write `<key>.json`, delete the partial file and the WAV.
7. **Map and merge** (§10.1) using a **fresh** `timeline()`.
8. **Segment** (§9) into `SubtitleCueDraft`s, with frame quantization from `timeline().frameRate`.
9. **Result.** Return drafts, provenance and summary. The controller applies one command. The job record is deleted and the model release timer starts (60 s).

### 8.3 Normalization and filtering (Dart, `transcript_normalizer.dart`)

Applied to raw segments before caching. Each rule is unit-tested and can be toggled.
- Trim and collapse whitespace. Strip a leading `"- "` that whisper sometimes emits for dialogue.
- **Non-speech annotations** (`includeSoundDescriptions == false`): drop segments that are only `[...]`, `(...)`, `♪…♪`, or `*…*`, and remove such spans inside text. Also pass `suppress_nst = 1` to the shim.
- **Repetition loops:** collapse three or more consecutive segments with identical normalized text into the first one. Drop words repeated four or more times consecutively inside a segment.
- **Silence hallucinations:** drop a segment if `nsp > 0.5 && lp < −0.8`. Also drop segments matching the per-language phrase list (e.g. "Thank you for watching", "Subtitles by the Amara.org community", "ご視聴ありがとうございました"), but only when `nsp > 0.3` or the segment is shorter than 1.2 s at the end of a unit. This is a heuristic list kept in `hallucination_phrases.dart` [tuned in AI-19].
- **Timing sanity:** force words monotonic and inside segment bounds. Words with zero duration get 60 ms, borrowed from neighbouring gaps. Segments shorter than 100 ms with ≤ 1 character are dropped.

### 8.4 Transcript file (schema 1)

```json
{
  "schema": 1, "key": "9f1c…",
  "engine": {"name": "whisper.cpp", "version": "1.9.4", "shimAbi": 1},
  "model": {"id": "whisper-base-q5_1", "sha256": "422f1ae4…8898"},
  "source": {"mediaFingerprint": "…", "audioStream": 0, "covered": [{"startUs": 0, "endUs": 61234000}]},
  "language": {"code": "en", "detected": true, "p": 0.97},
  "params": {"version": 1, "vad": true, "tokenTimestamps": true, "suppressNst": true},
  "segments": [{"startUs": 123450000, "endUs": 127890000, "text": "And that's why we left.", "nsp": 0.02, "lp": -0.21,
                "words": [{"t": "And", "s": 123450000, "e": 123700000, "p": 0.98}]}],
  "createdAt": "2026-10-07T12:00:00Z"
}
```

Times are absolute **source** µs. Unknown `schema` values are discarded and regenerated, since this is a cache, not project data. `paramsVersion` bumps whenever shim decoding parameters change, which invalidates old keys.

### 8.5 Progress and ETA

- **Weights:** extraction 0.10, model load 0.05, language detection 0.05, transcription 0.75, segmentation and finishing 0.05. Within extraction and transcription, weight is by unit duration.
- **ETA:**
  - Before 10% of the transcription phase: prior real-time factor from the catalog by tier × device class (§14 table midpoints).
  - After that: measured `compute_ms / processed_ms`, exponentially smoothed (α = 0.3) and multiplied by remaining audio.
  - Shown as "about N min left", rounded up to whole minutes, or "less than a minute". Hidden while paused.

### 8.6 Resume after interruption

`jobs/<jobId>.json` holds `{project, request (serializable), units with state, detected language, startedAt}`. It is written at start and on each unit transition.

When the editor opens a project with a pending record, the Captions tool shows a `DanaviewSurface` notice: "Auto captions were interrupted. Resume?" with the buttons Resume and Discard. Resume re-runs the request. Completed units are cache hits, and the unit in progress resumes at its last checkpointed chunk end (`range_start_ms`). Records older than 7 days are dropped silently.

### 8.7 Failure taxonomy (Dart)

```dart
sealed class TranscriptionFailure implements Exception { String get message; bool get retryable; }
// unsupportedDevice(reason) · modelMissing · modelDownload(ModelDownloadFailureKind) · modelCorrupt
// insufficientMemory(suggestedTier) · diskFull · mediaOffline(MediaId) · noAudio · unsupportedAudio(codec)
// audioDecode · noSpeech · inference(detail) · cancelled · interrupted (resumable)
```

User copy is in §15.

---

## 9. Segmentation into readable cues (`segmentation/`)

### 9.1 Inputs and outputs

```dart
final class TimedWord { final String text; final TimeUs start, end; final double p;
  final bool endsSentence;        // ., ?, !, …, 。, ？, ！ (computed)
  final bool endsClause;          // ,, ;, :, —, 、, ， (computed)
  final ItemId clip; }            // for cut-point penalties
final class SegmentationContext { final ScriptProfile script; final SegmentationSettings settings;
  final FrameRate frameRate; final List<TimeUs> cutPoints; final TextDirection direction; }
abstract interface class CaptionSegmenter {
  List<SubtitleCueDraft> segment(List<TimedWord> words, SegmentationContext context); // pure, deterministic
}
```

### 9.2 Presets and defaults

Character counts are **grapheme clusters** (`characters` package). CJK full-width characters count 1, as in common broadcast guides.

| Setting | Standard | Single line | Short phrases (social) |
|---|---|---|---|
| Max lines | 2 | 1 | 1 |
| Max chars/line: space-delimited (Latin, Cyrillic, Greek, Arabic, Hebrew, Indic…) | 42 (9:16 projects: 32) | 42 (9:16: 32) | 20 |
| Max chars/line: CJK (zh, ja, yue) | 16 | 16 | 8 |
| Max chars/line: Korean | 18 | 18 | 10 |
| Max chars/line: no-space SE Asian (th, lo, km, my, bo) | 35 | 35 | 16 |
| Min duration | 0.83 s | 0.83 s | 0.4 s |
| Max duration | 7.0 s | 5.0 s | 2.5 s |
| Max reading speed (soft) | 17 cps (CJK 9, ko 12) | 17 (CJK 9, ko 12) | 20 (CJK 10) |
| Min gap | 2 frames | 2 frames | 0 (back-to-back allowed) |
| Linger after last word | 0.2 s | 0.2 s | 0.1 s |
| Chain gaps shorter than | 0.5 s | 0.5 s | 0.3 s |

The 42/17 cps/0.83 s/7 s values follow widely used streaming subtitle guidelines. CJK/Korean CPS values are conservative starting points [VERIFY against a published guide; AI-19 tunes them with readers]. The default preset is Standard for 16:9/4:3/21:9 projects, and Single line with 32 characters for 9:16, 4:5 and 1:1. All values are editable in the "Layout" section of the sheet (Advanced).

### 9.3 Algorithm

1. **Cue boundaries by dynamic programming** over words `w0…wn−1`. A candidate cue is `wi…wj` (j − i < 48). The DP minimizes `Σ cost(i, j)`. `cost(i, j)` is the sum of:
   - ∞ if the cue text cannot fit `maxLines × maxChars`. The exception is a single word longer than a line, which hard-wraps at a grapheme boundary.
   - ∞ if any internal word gap is ≥ 1.2 s, or if the cue span exceeds `maxDuration + 0.5 s`.
   - `8 × max(0, minDuration − availableDuration)`, where available duration includes extendable linger up to the next word.
   - `4 × max(0, cps − maxCps)`, using the extendable duration.
   - Break quality at `wj`: 0 for sentence end or a gap ≥ 0.5 s; 1 for a clause end; 2 when `wj+1` is a conjunction or preposition (per-language list: English, Spanish, French, German, Portuguese, Italian; empty otherwise); 5 otherwise.
   - 3 if the cue crosses a cut point (clip boundary on the timeline). Cues should not straddle shot changes.
   - +1 per cue, which prefers fewer, fuller cues.
2. **Line breaking within a cue** (when `maxLines == 2` and the text exceeds one line):
   - Try every break between words (or between graphemes for CJK and no-space scripts).
   - Cost = `|len1 − len2|`, minus a bonus after punctuation, plus a penalty when line 1 ends with an article, preposition or conjunction. Prefer a bottom line that is equal or longer (a pyramid shape).
   - CJK kinsoku rules: a line never starts with `、。，．）」』】ー！？` and never ends with `（「『【`.
3. **Timing.**
   - `start = quantize(w_i.start)` and `end = quantize(max(w_j.end + linger, start + minDuration))`.
   - Clamp to `next.start − minGap`. If the gap to the next cue is less than the chain threshold, set `end = next.start − minGap`.
   - Use `FrameRate.quantize` (`ux.md` §2.1). Never produce a cue shorter than one frame. If clamping would make it too short, merge with the neighbour.
4. **RTL and bidi.** Text keeps logical order. The renderer decides direction from the first strong character (Subtitles/engine areas). The segmenter only needs `script.spacing`.
5. **Determinism.** Same input gives the same output (no hash-map iteration order, stable tie-breaks). This is required for golden tests.

Complexity is O(n × 48). One hour of dense speech (about 10k words) takes ≤ 150 ms in `Isolate.run` [budget, §14].

### 9.4 Languages (`speech_languages.dart`)

There are 99 entries, generated from whisper's `g_lang` (ids 0–98) [VERIFIED list]. `yue` is excluded because only large-v3 knows it. Each entry is `{whisperCode, bcp47, englishName, nativeName, script, rtl, qualityHint}`.
- BCP-47 mapping is identity except `jw → jv`. `haw` stays (valid 3-letter subtag). `no` stays (macrolanguage).
- `script` drives §9.2 profiles.
- `rtl` covers ar, fa, ur, he, yi, ps, sd.
- `qualityHint` marks languages where Fast and Balanced are weak, so the sheet recommends Accurate. We fill it from OpenAI's published per-language WER (Whisper paper, FLEURS table) during AI-19 [VERIFY numbers]. Until then, mark everything outside the top 30 by FLEURS WER.

The picker (`ux.md` `language_picker.dart` with `DanaviewSearchField`) lists "Detect automatically" first, then the last 3 languages used, then all languages sorted by English name with the native name as a subtitle. Search matches the English name, the native name and the code.

---

## 10. Timeline integration

### 10.1 Mapping source words to timeline time (`timeline/`)

The minimal view of the project that this area reads is the following [ASSUMPTION about domain names; the Domain doc wins]:

```dart
abstract interface class TimelineView {
  ProjectId get project; FrameRate get frameRate; Size get canvasSize; TimeUs get duration;
  Iterable<TrackView> get tracks;                      // with kind, muted, solo, hidden, locked, role?
  Iterable<AudibleClipView> audibleClips();            // MediaClip with audio, resolved effective volume
  Iterable<SubtitleTrackView> get subtitleTracks;      // id, name, language, provenance, cues (id, range, text, origin)
  List<TimeUs> get cutPoints;                          // clip boundaries on audible tracks
}
abstract interface class AudibleClipView {
  ItemId get id; TrackId get track; MediaId get media; MediaRef get mediaRef; int? get audioStream;
  TimeRange get timelineRange; TimeRange get sourceRange; bool get reversed; bool get isFreeze;
  double get effectiveVolume;                          // 0 when muted / track muted / not soloed
  /// Timeline time at which source time [s] is shown, or null when [s] is trimmed away.
  /// Must invert constant speed and speed ramps exactly (monotonic, non-reversed clips).
  TimeUs? timelineTimeOf(TimeUs s);
}
```

`DomainTimelineView` adapts the real domain types (AI-13). Mapping rules:
- For each clip of a unit, map each word's `start`/`end` through `timelineTimeOf`.
- Drop words whose visible part is less than 50% of their duration. Clamp partly visible words to the clip's `timelineRange`.
- Words from different clips stay separate even when they are the same media (a split clip yields two streams).

**Merging overlapping speech** (two audible clips overlapping on the timeline, such as a voice-over on a talking-head video):
- Priority order: tracks with role `voice` > the main video track > other video tracks > other audio tracks > music. Ties go to the higher track.
- Inside an overlap, keep words from the higher-priority stream and drop lower-priority words that fall within ±0.3 s of a kept word.
- The result is one time-sorted word stream, plus `cutPoints` for the segmenter.

**Speed:** at speeds > 2×, mapped words get very short. The segmenter's CPS penalties then produce fewer, longer cues. The summary warns "Captions may be hard to read on sped-up clips" when more than 20% of cues exceed max CPS.

### 10.2 Commands and provenance (Domain area owns the types; AI proposes)

```dart
final class CaptionProvenance {                 // stored on the subtitle track (schema-additive, nullable)
  final String generator;                       // 'whisper.cpp'
  final String engineVersion;                   // '1.9.4'
  final String modelId; final String modelSha256;
  final String language;                        // BCP-47
  final bool languageDetected; final double? languageConfidence;
  final SegmentationSettings segmentation;
  final TranscriptionScopeData scope;           // what was transcribed (clip ids / track ids / range)
  final List<String> transcriptKeys;            // cache keys for instant re-split
  final DateTime generatedAt; final int schema; // 1
}
enum CueOrigin { manual, imported, generated }  // on SubtitleCue; plus bool editedAfterGeneration

final class AddGeneratedCaptionTrack extends EditCommand {   // label: 'Auto captions'
  final String trackName;                       // 'Captions (English)' / 'Captions (日本語)'
  final String language; final CaptionProvenance provenance; final List<SubtitleCueDraft> cues;
}
final class ReplaceGeneratedCaptions extends EditCommand {   // label: 'Regenerate captions'
  final TrackId track; final TimeRange? range;  // null = whole track
  final CaptionProvenance provenance; final List<SubtitleCueDraft> cues;
}
```

Requirements on Domain:
1. Each command is **one history entry**, validated as a whole. A locked target track returns the `TrackLocked` rejection, which the sheet shows as "Unlock the track to replace its captions".
2. Any command that changes a `generated` cue's text or timing sets `editedAfterGeneration = true`.
3. Cue ids are fresh.
4. Adding nullable `provenance` and `origin` with defaults is schema-additive. Persistence bumps the project schema minor version and migration defaults them to `null`/`manual`.
5. The new track is inserted at the top of the subtitle tracks and becomes the selected track. The view then scrolls to the first cue (`ux.md` behaviour).

### 10.3 Regenerate

Available from the subtitle track menu (`ux.md` `track_menu_sheet.dart`) when `provenance != null`. It is also offered by the sheet when the scope already has a generated track.

| Mode | When offered | What happens |
|---|---|---|
| **Re-split** (instant) | Always | `resegment(provenance, newSettings, timeline)`: load cached transcripts by `transcriptKeys`, then map, merge and segment with new settings → `ReplaceGeneratedCaptions`. If any key is evicted from the cache, fall back to Transcribe again for those units only. |
| **Transcribe again** | Always | New request prefilled from provenance (language, tier, scope). The user may change language or tier. The cache is bypassed when language or model changed. |

**Edited cues:** if any target cue has `editedAfterGeneration`, show a confirm: "12 captions were edited. Replace them?" with the buttons "Add as new track" and "Replace". Undo restores everything in one step.

**Scope "this clip" on a project that already has a generated track:** the target is `replaceInRange(track, clip.timelineRange)`. Only cues overlapping the clip's range are replaced, and cues elsewhere stay.

### 10.4 Export and burn-in (Subtitles and engine areas)

Generated tracks are ordinary subtitle tracks:
- **SRT/VTT export** uses the Subtitles area codec. The suggested file name is `<project>.<bcp47>.srt|vtt`, so players pick up the language. VTT gets `WEBVTT` with no extra header. Cue text keeps the `\n` line breaks.
- **Burn-in** uses the export setting "Burn in captions: <track>", carried in the RenderPlan subtitle layer (Domain ↔ engines).

Two requirements from this area:
1. The renderer (CoreText on iOS, Android text overlay) must honor explicit `\n` breaks and use **system font fallback** for scripts that Figtree lacks: CJK, Arabic, Devanagari and others. AI generates 99 languages, and Figtree covers Latin only [VERIFY Figtree coverage]. The Figtree-only rule applies to app chrome, not user content.
2. The renderer must apply RTL paragraph direction from the first strong character. Preview (Flutter) and export (native) must agree. This is a test in AI-20.

---

## 11. UX (files owned by `ux.md`; behavior and copy specified here)

### 11.1 Entry points
- **Captions tool** (`ux.md` §6.3 tool strip, "Captions"): the panel has an **Auto captions** tile (icon+text, rounded rectangle; `Icons.subtitles_rounded` [VERIFY exists]) that opens `AutoCaptionsSheet` (modal `showDanaviewSheet`, a flow per `ux.md` §0.2).
- **Clip context menu / long-press:** "Auto captions for this clip" opens the sheet with scope = clip.
- **Subtitle track menu:** "Regenerate captions…" (§10.3).
- **Interrupted job notice** (§8.6).
- **Desktop:** unreachable, because the editor is gated.

### 11.2 `AutoCaptionsSheet` states (`auto_captions_controller.dart`)

```dart
final autoCaptionsControllerProvider = StateNotifierProvider.autoDispose
    .family<AutoCaptionsController, AutoCaptionsState, ProjectId>((ref, id) => /* … */);

final class AutoCaptionsState {
  final AutoCaptionsStage stage;   // checking | unsupported | configure | consent | downloading |
                                   // waitingForExport | running | needsLanguage | done | failed
  final TranscriptionSupport? support; final List<SpeechModelOffer> offers;
  final AutoCaptionsDraft draft;   // scope, language, tier, segmentation, includeSoundDescriptions, target
  final ModelDownloadProgress? download; final TranscriptionProgress? progress;
  final TranscriptionFailure? failure; final TranscriptionSummary? summary;
}
class AutoCaptionsController extends StateNotifier<AutoCaptionsState> {
  Future<void> open({TranscriptionScope? scope, CaptionProvenance? regenerateFrom});
  void update(AutoCaptionsDraft Function(AutoCaptionsDraft) edit);
  Future<void> start();                    // → consent if the model is missing, else run
  Future<void> acceptConsent(UserConsent consent);   // → downloading → running
  void cancelDownload();
  void provideLanguage(String code);
  void cancel();                           // confirm only if > 30 s of work is done
  Future<void> applyResult();              // EditorController.apply(command); one undo step
}
```

The controller keeps itself alive (`ref.keepAlive()`) while a job runs, so closing the sheet does not cancel. A docked progress strip in the editor (`ux.md` tasks) shows the job. Wakelock is on during download and job (`ux.md` §4.7).

### 11.3 Copy (centralized in `editor_strings.dart`)

**Configure step** (`DanaviewStepIndicator` "Step 1 of 2"):
- Title: **Auto captions**
- "Spoken language": dropdown → language picker. Default: last used, else "Detect automatically".
- "Quality": `DanaviewSegmentedControl` (wraps to `DanaviewChipGroup` under 360 px):
  - Fast · 31 MB
  - Balanced · 57 MB
  - Accurate · 181 MB

  Installed tiers show "Ready" instead of a size. Unavailable tiers are disabled with the reason as their semantics hint.
- "Captions from": This clip | Whole video. The Advanced section lists audio tracks with switches; music tracks are off by default.
- "Layout": Standard (2 lines) | Single line | Short phrases. Advanced shows max characters per line, reading speed, and "Include sound descriptions" (`DanaviewSwitchRow`).
- Footer note (caption style): "Captions are created on this device. Your video and audio are never uploaded."
- Primary button: **Create captions**. Secondary button: Cancel.

**Consent view** (`model_consent_view.dart`, "Step 2 of 2"):
- Title: **Download the speech model?**
- Body: "Auto captions use a speech-recognition model that runs on this device. It's a one-time download of 57 MB from Hugging Face (huggingface.co). Your video, audio and captions stay on this device."
- Metered network: "You're on mobile data."
- Link: "Privacy Policy" (pushes `/settings/privacy`).
- Buttons: **Not now** (secondary), **Download 57 MB** (primary).

**Downloading:**
- "Downloading speech model… 23 of 57 MB" with `DanaviewProgressBar` and a Cancel button.
- Errors reuse the downloader kinds:
  - offline: "You're offline. Connect to the internet to download the speech model."
  - checksumMismatch: "The download was damaged. Try again."
  - diskFull: "Not enough free space. The speech model needs 57 MB."
  - secureConnection: "Couldn't open a secure connection. On public Wi-Fi, sign in to the network first."
  - server: "The download server isn't responding. Try again later."

**Running:** the progress panel, in the sheet or as the docked strip.
- Phase lines:
  - "Preparing audio (1 of 3)"
  - "Loading speech model"
  - "Detecting language"
  - "Creating captions · 42% · about 2 min left"
  - "Finishing up"
- Partial text preview: one line, ellipsized, live region off.
- Paused lines:
  - "Paused while Danaview is in the background"
  - "Paused while your device cools down"
  - "Waiting for the export to finish"
- Buttons: **Cancel** (secondary), **Hide** (ghost; keeps running).

**Needs language:** "Which language is spoken?" with the top 3 as `DanaviewChoiceChip`s ("Hindi 62%", …), "Other language…", and Continue.

**Done:** sheet closes. Toast: "Added 128 captions (English)". If clips were skipped, the toast becomes "Added 128 captions. 2 clips were skipped", and the detail is in the track's info.

**No speech:** `DanaviewDialog` "No speech found", message "We couldn't hear anyone speaking in the selected clips."

### 11.4 Layout rules (standing UI rules)
- Custom components only: no `AlertDialog`, `ListTile`, `Slider` or `LinearProgressIndicator`. Solid surfaces, soft shadows, hairline borders. Figtree.
- Every row must fit at **280–1280 px widths at text scale 0.85–1.35**: `Wrap`/`Flexible`, one-line ellipsis for names, `DanaviewSegmentedControl` falling back to chips.
- The sheet is scrollable. Its max height is 0.85 of the screen and it is keyboard-aware.
- Widget tests use the `ux.md` §21 surface matrix (AI-16).

### 11.5 Settings, storage, tasks
- **Settings › Video editor › Auto captions** section (`editor_settings_screen.dart`, `ux.md` §4.8). One `DanaviewListTile` per tier: "Balanced · 57 MB · Ready", trailing "Delete"; or "Fast · 31 MB", trailing "Download", which goes through the consent view. Below that: "Default quality", "Default language", "Include sound descriptions", and the privacy paragraph with a Privacy Policy link.
- **Storage contributor "Speech model"** (`ux.md` §4.8). `measure()` sums `danaview/speech/models` plus partials. The clear action is "Delete speech models" (§5.6).
- **Background tasks sheet:** the active `TranscriptionJob` appears with title "Auto captions", progress and Cancel.

---

## 12. Licensing

| Component | Licence | Obligation | Where satisfied |
|---|---|---|---|
| whisper.cpp + ggml (vendored, compiled in) | MIT, © 2023-2026 The ggml authors [VERIFIED] | Include the copyright and permission notice in copies | `LICENSE-THIRD-PARTY.md` in the plugin; `LicenseRegistry.addLicense` at startup; shown in a **custom** "Open-source licences" screen (AI-18; no Material `showLicensePage`) |
| OpenAI Whisper model weights (ggml conversions) | MIT, © 2022 OpenAI [VERIFIED: openai/whisper LICENSE, HF tag `mit`] | Notice | Same screen; also linked from the consent view ("Model: OpenAI Whisper, MIT licence") |
| Silero VAD v6.2.0 (ggml conversion) | MIT (HF tag `mit`) [VERIFIED tag]; upstream snakers4/silero-vad MIT [VERIFY copyright line] | Notice | Same screen |
| `jfk.wav` test fixture | US-government work, public domain | n/a | Test-only, not shipped |

All of these are compatible with the app's proprietary licence. Downloading model weights after install is data, not executable code. This is consistent with App Store guideline 2.5.2 and Play policy [VERIFY with App Review notes in AI-20].

---

## 13. Privacy policy and store disclosures

`ux.md` §20 merges these into `packages/danaview_features/lib/src/more/legal_texts.dart`. The exact AI blocks follow.

In **"When Danaview uses the internet"**, add after "Stream check":

```dart
LegalBullet(
  lead: 'Speech model for auto captions',
  'Only if you choose to create captions automatically, Danaview downloads a speech-recognition model '
  '(about 31 to 181 MB, depending on the quality you pick) from Hugging Face (huggingface.co), which '
  "delivers it through its download network on hf.co. The request contains only the model's file name. "
  'No video, audio, captions or personal data are sent. Hugging Face sees the usual details of the '
  'connection, such as your IP address, and handles them under its own policies. After the download, '
  'captions are created entirely on your device, even when you are offline.',
),
```

In **"What Danaview stores on your device"**, add:

```dart
LegalBullet(
  'If you use auto captions, the downloaded speech model and the text transcribed from your videos, so '
  'captions can be adjusted later without transcribing again. They are never uploaded.',
),
```

In **"Your choices"**, add:

```dart
LegalBullet('Delete downloaded speech models at any time in Settings › Video editor › Auto captions.'),
```

Also:
- Bump `legalEffectiveDate`.
- Update the hosted policy at `https://vecvel.com/ios/danaview/privacy` (owner action).
- **App Store privacy label / Play Data safety:** unchanged. No data is collected or shared, because downloading a public file is not collection.
- **Store descriptions:** "All your data stays strictly on your device" (iOS) and "100% on-device" (Android) remain true. Release notes should say "Auto captions run on your device; a one-time model download is needed."

---

## 14. Performance budgets and speed estimates

### 14.1 Estimated processing time per **1 minute of continuous speech**

These figures are **estimates** for steady state with the model loaded: greedy decoding, flash attention on, VAD on, no temperature fallback. They come from encoder FLOPs (about 35/84/337 GFLOP per 30 s window for tiny/base/small), about 200 tokens per minute of speech, and typical effective throughput. AI-19 replaces them with measurements before release [VERIFY].

| Tier (model) | iPhone 13 / A15, Metal | iPhone 11 / A13, Metal | iPhone XR / A12, CPU | Android mid-range (Snapdragon 7s Gen 2 / Dimensity 7050 class, 4 threads, v82) | Android low-end (Cortex-A55/A53, v80) |
|---|---|---|---|---|---|
| Fast (tiny-q5_1) | 1–2 s | 2–3 s | 3–6 s | **3–6 s** (≈ 10–20× real time) | 10–20 s |
| Balanced (base-q5_1) | 2–4 s | 3–6 s | 7–14 s | **7–15 s** (≈ 4–8×) | 25–50 s (offered only with ≥ 3 GB RAM) |
| Accurate (small-q5_1) | 6–12 s | 10–20 s | 25–50 s | **25–60 s** (≈ 1–2.4×) | not offered |

Fixed costs per session:
- Model load: 0.3–2.5 s.
- First Metal init: the embedded kernel library compiles on the device, 1–5 s the first time [VERIFY; it may be cached by the OS later].
- Language detection: one encoder pass.
- Audio extraction: about 0.2–0.5 s per minute of AAC.

Sparse speech gets faster (VAD skips silence). Sustained runs over 5 minutes may slow by 20–40% from thermal throttling. **Example:** a 10-minute talking-head video with Balanced on a mid-range Android phone takes about 1.5–2.5 minutes in total.

### 14.2 Budgets (CI or device-asserted where noted)

| Metric | Budget | Enforced by |
|---|---|---|
| FFI poll (status + take ≤ 8 segments) on the UI isolate | < 0.5 ms p95 | Device integration test (timeline trace) |
| UI jank during transcription (Balanced, mid Android) | no frame > 16 ms caused by AI code; UI isolate CPU share < 5% | Integration test with `FrameTiming` |
| Cancel → native compute stopped | ≤ 1.5 s p95 (Metal ≤ 2 s) | Native host test plus device test |
| Pause (abort chunk) → state PAUSED | ≤ 1.5 s p95 | Same |
| Segmentation of 10k words | ≤ 150 ms (`Isolate.run`, mid device) | Benchmark test |
| Applying 1,000 cue drafts via command | ≤ 50 ms domain apply | Domain benchmark (shared) |
| Peak extra footprint | tiny ≤ 200 MB, base ≤ 300 MB, small ≤ 650 MB | Device test (`phys_footprint` on iOS, `dumpsys meminfo` on Android) |
| Temp disk | ≤ 1.92 MB per audio minute per unit in flight (≤ 2 units) | Unit test of planner math, plus a device check |
| Download progress UI | ≤ 4 Hz; hashing 190 MB ≤ 2 s off the UI isolate | Unit plus device |
| Native size | Android ≤ 3 MB per `.so`; iOS ≤ 6 MB added to the IPA (arm64 thinned) | CI size check (AI-04/05) |
| Accuracy (eval set, §16.5) | WER regression ≤ +1.0 pt absolute vs baseline per tier/language; median cue boundary error ≤ 200 ms | Nightly eval |

---

## 15. Error handling matrix

| Failure | Detected at | User sees | Recovery |
|---|---|---|---|
| Unsupported device or OS, library missing (armeabi-v7a) | `support()` | `DanaviewEmptyState`: "Auto captions aren't available on this device." plus the reason ("Needs iOS 15 or later" / "Needs a 64-bit device") | None |
| Tier needs more RAM | offers | Disabled segment with hint | Pick a lower tier |
| Low available memory at start | preflight | "There isn't enough free memory right now. Close other apps or choose Fast." | Retry |
| Download errors | downloader | §11.3 copy | Retry (resumes) |
| Model corrupt (load failed on verified file) | `loadModel` | "The speech model is damaged. Download it again?" | Delete, then consent and download |
| Media offline / permission lost | extractor | "Some media is missing. Relink it to create captions." with a **Relink** button (`ux.md` relink flow) | Relink, retry |
| No audio / all clips excluded | planner | "There's no audio to caption in the selected clips." | Change scope |
| Unsupported audio codec | extractor | "This clip's audio format can't be read for captions (DTS)." The job continues with the other units. Summary: "1 clip skipped." | n/a |
| No speech | detect/transcribe | "No speech found" dialog | n/a |
| Inference error (non-OOM) | job | "Something went wrong while creating captions. Try again." | Retry once automatically with `use_gpu=false` if the GPU was on; then report |
| iOS jetsam / Android OOM kill | next launch (job record) | Interrupted-job notice (§8.6) | Resume (offers a lower tier if the previous run was killed twice) |
| Cancelled | user | Sheet returns to configure; toast "Captions cancelled" | n/a |
| Target track locked | command rejection | "Unlock the captions track to replace its captions." | Unlock |

All failures are typed. Raw `PlatformException`s and `WhisperException`s are mapped in `transcription_failure.dart` and never reach widgets.

---

## 16. Testing strategy

### 16.1 Dart unit tests (`danaview_whisper/test`, `danaview_transcription/test`)

- **Loader:** variant selection from HWCAP masks (fake bindings); ABI mismatch → `abiMismatch`; desktop → `unsupported(platform)`.
- **WhisperJob polling with `FakeDvBindings`:**
  - progress throttling,
  - segment batching across polls,
  - terminal-state handling (succeeded/failed/cancelled),
  - `Finalizer` frees,
  - pause/resume/threads calls forwarded,
  - malformed or unknown-key JSON tolerated.
- **Segment JSON decoder:** escaping, invalid UTF-8 never reaching Dart (the shim guarantees it; the decoder asserts).
- **Catalog integrity:** every URL contains the pinned revision; sha256 values are 64 lowercase hex; byte sizes are positive; ids are unique; tiers cover all three; the VAD entry is present.
- **Language table:** 99 entries; codes equal whisper's table (golden list); BCP-47 mapping; RTL flags.
- **Downloader** (fake `HttpClient`, fake clock and filesystem):
  - 302 handling plus header checks,
  - 206 resume, 200 restart, 416 complete and 416 mismatch,
  - retries with backoff, cancel mid-stream (partial kept or discarded),
  - checksum mismatch, disk full, consent mismatch,
  - sidecar recovery after a crash at every write point.
- **Normalizer:** each rule with fixtures (annotations, loops, phrase list gating, zero-duration words).
- **Segmenter:**
  - **golden fixtures** for English, Spanish, German, Japanese, Chinese, Korean, Thai, Arabic and Hindi word streams,
  - **property tests** (random word streams, seeded): cues sorted and non-overlapping; `gap ≥ minGap` or chained; every surviving word appears once in order; lines ≤ maxLines; line length ≤ max unless a single long word; durations ≥ 1 frame; determinism (same input → identical output),
  - frame quantization at 23.976, 25, 29.97 and 60 fps.
- **Planner and mapping:** split clip → one unit; mute, solo and role filters; reversed and freeze excluded; speed 0.25×–4× and ramps (`timelineTimeOf` fake with a piecewise-linear map); partially visible words; overlap priority; cut points.
- **Service orchestration** (fake runtime, extractor, store, cache, clock): phase order and weights; ETA; language auto (confident vs `needsLanguage`); cache hit, miss and superset reuse; checkpoint write and resume; cancel at each phase cleans up WAVs; export-active waiting and pausing; iOS lifecycle pause/resume; failure mapping for every kind in §15.
- **Architecture tests:** the pubspec dependency rules (§3.1); `UserConsent.accepted(` call sites limited to `model_consent_view.dart`; no `print`/`debugPrint` of transcript text in `danaview_transcription` (a grep test for `partialText`/`text` passed into logging calls).

### 16.2 Widget tests (`danaview_editor/test/flows/captions/`, UX-owned harness)

- Every sheet state (configure, consent, downloading, error, running, paused, needsLanguage, done, unsupported) across the `ux.md` surface matrix: **280×500 @ 1.35 … 1280×800 @ 0.85**. Assert no `RenderFlex` overflow and every element inside the sheet bounds (`expectInside`).
- No Material chrome: the tree contains no `AlertDialog`, `ListTile`, `Slider`, `LinearProgressIndicator` or `CircularProgressIndicator`.
- Semantics: progress announces "Creating captions, 42 percent"; disabled tiers expose their reason; buttons have labels.
- The language picker filters by English name, native name and code.
- Consent view: the primary button label shows the exact size from the disclosure.

### 16.3 Native tests

- **C++ host tests** (`src/tests`, CTest, macOS and Linux CI, CPU-only build of the vendored tree), using `ggml-tiny-q5_1.bin` (31 MB, cached in CI by sha256) and `jfk.wav`:
  1. Transcript contains "ask not what your country can do for you" (case- and punctuation-insensitive).
  2. Words are monotonic, inside segments, valid UTF-8.
  3. Cancel latency < 1.5 s.
  4. Pause with abort, then resume, gives the same text as an uninterrupted run.
  5. A 20× concatenation of `jfk.wav` with 1–4 s silences, forcing chunk boundaries, gives 20 detections with no duplicate or dropped words at boundaries.
  6. DETECT finds `en` with p > 0.8, and returns `NO_SPEECH` on a silence file.
  7. WAV validator rejects wrong rate, stereo, 24-bit and truncated files.
  8. JSON escaping fuzz (random bytes in token text → valid JSON).
  9. A CJK fixture yields complete characters only.
  10. `dv_shutdown_all` with active jobs joins cleanly under ThreadSanitizer (one CI job with `WHISPER_SANITIZE_THREAD`).
- **Android:** Kotlin unit tests for HWCAP and cpufreq clustering parsing and thermal mapping. An instrumented test on the x86_64 emulator loads the library and runs `jfk.wav` with tiny. An extraction test with fixtures (AAC stereo 48k MP4, 5.1 AC-3 MOV where the decoder exists, mono AMR 3GP): a clap test where the transient at a known source time is detected in the WAV within ±20 ms, including an MP4 with an edit list.
- **iOS:** XCTest (RunnerTests) for the device-profile channel and extraction with the same fixtures plus the clap test. Simulator CPU path test with tiny.

### 16.4 On-device integration tests (`integration_test/ai_captions_test.dart`)

- **Device matrix** (release-candidate gate):
  - iPhone XR (A12, 3 GB), iPhone 11 (A13), iPhone 13 (A15), iPhone 15 (A16), iPhone SE 3;
  - Galaxy A15 (Helio G99), Pixel 6a (Tensor G1), Galaxy A55 (Exynos 1480), Redmi Note 13 Pro (SD 7s Gen 2), Pixel 8;
  - one armeabi-v7a-only device, to check the unsupported path.
- Model is pre-staged with `adb push` / `xcrun devicectl` to skip the network in CI, plus one real download test per platform on Wi-Fi.
- Scenarios:
  1. 60 s English clip, Balanced: cue count in range, WER ≤ 15% vs reference, cue edges within ±300 ms.
  2. 30-minute clip, Accurate: thermal and memory soak, no jetsam, ETA error < 30% after 25%.
  3. Background mid-job on iOS → resume → identical result.
  4. Process kill mid-job on Android → resume from checkpoint.
  5. Split clip plus 2× speed clip mapping check.
  6. Undo removes all generated cues in one step.
  7. SRT export round-trip.
  8. Burn-in export of Arabic and Japanese captions: visual check plus golden frame compare between preview and export (shared with Subtitles/engines).

### 16.5 Accuracy evaluation harness (`danaview_transcription/tool/eval/`)

- A host CLI runs the same shim (CPU) over an eval set of about 40 clips in 10 languages. Sources and licences:
  - Common Voice (CC0),
  - FLEURS (CC BY 4.0, attribution in the eval README),
  - LibriVox (PD),
  - 5 in-house screen recordings.
- It reports WER/CER per tier and language, cue boundary error vs human-timed references, CPS distribution, and hallucination rate on silence/music clips.
- It runs nightly and on any change to shim parameters, normalizer, segmenter or catalog. Results are committed to `docs/v1.1/video-editor/ai-eval.md`. This tunes VAD and threshold defaults, CJK CPS values and `qualityHint`.

---

## 17. Cross-area interfaces

| Interface | Counterpart | Direction | What AI needs / provides | Where specified |
|---|---|---|---|---|
| `TranscriptionService`, `TranscriptionJob`, `SubtitleCueDraft`, `UserConsent` | UX (`ux.md` §2.4) | AI provides | §8.1 extends the minimum (`offers`, `preflight`, `resegment`, `activeJob`, `resumableFor`, `provideLanguage`). UX adopts the extensions or keeps them behind its controller. | §8.1 |
| Auto captions sheet, consent view, language picker, settings section, storage contributor, tasks entry | UX | UX owns the files; AI specifies behaviour and copy | §11 | §11 |
| `DanaviewProgressBar`, `DanaviewSearchField`, `DanaviewStepIndicator` | UX / UI kit (`ux.md` §3.2) | AI consumes | Must exist before AI-16 | n/a |
| `TimelineView` adapter over `EditProject`, `MediaClip`, `FrameRate`, `TimeRange`; `timelineTimeOf(source)` inverse speed map; track role | Domain | AI consumes | Exact inverse time map for constant speed and ramps; `AudioRole` or an equivalent music flag | §10.1 |
| `AddGeneratedCaptionTrack`, `ReplaceGeneratedCaptions`, `CaptionProvenance`, `CueOrigin`, `editedAfterGeneration` | Domain | AI proposes, Domain owns | One history entry; rejections as data | §10.2 |
| Project schema bump (additive fields) | Persistence | Persistence owns | Migration defaults | §10.2 |
| `MediaRef` resolution (paths, `content://`, security-scoped bookmarks), availability, `mediaFingerprint` | Persistence / media pool | AI consumes | Stable fingerprint string per media | §8.2 |
| Backup rules XML (Android), app-support dir policy | Persistence | Co-owned | Exclusion lines for `danaview/speech/{models,jobs,work}` | §5.4 |
| `SpeechAudioExtractor` (`EditorEngine.jobs.extractSpeechAudio`) | iOS and Android engines | AI defines, engines implement | 16 kHz mono s16 WAV, sample-accurate range, progress, cancel, typed errors | §7 |
| `BackgroundWorkGuard` (foreground service / iOS background task), `exportActive` signal | Engines / UX tasks | AI consumes | Lease API; export activity stream | §6.3 |
| Subtitle rendering (explicit `\n`, font fallback, RTL) in preview and burn-in; SRT/VTT codec | Subtitles feature (Domain + engines + UX) | AI consumes | §10.4 requirements | §10.4 |
| Privacy text, licences screen, store notes | UX §20 / owner | AI provides text | §12, §13 | §12–13 |

---

## 18. Implementation tickets (ordered)

Size: S ≤ 2 days, M ≤ 1 week, L ≤ 2 weeks. All tickets land behind the compile-time flag `--dart-define=DANAVIEW_AUTO_CAPTIONS=true` until AI-20 passes. There is no remote config, for privacy.

### Milestone M1: native foundation

**AI-01 · Vendor whisper.cpp v1.9.4 (pruned)** · S
- Files: `packages/danaview_whisper/third_party/whisper.cpp/**`, `third_party/VENDORED.md`, `tool/vendor_whisper.sh`, `LICENSE-THIRD-PARTY.md`.
- Depends on: n/a.
- Acceptance:
  - The script reproduces the tree byte-for-byte from commit `927cfce3…`, after checking the tarball sha256.
  - A host CMake configure and build with the §4.3 option set and the §4.4 option set (macOS host, iOS SDK) succeeds with the pruned tree.
  - The licence file is present.

**AI-02 · `danaview_whisper` plugin skeleton and C ABI** · M
- Files: `packages/danaview_whisper/{pubspec.yaml, ffigen.yaml, lib/danaview_whisper.dart, lib/src/ffi/*, lib/src/support.dart}`, `src/dv_whisper.h`.
- Depends on: AI-01.
- Acceptance:
  - The header matches §4.5. ffigen output is committed and regenerates without a diff in CI.
  - On macOS, Windows and Linux the package compiles, `WhisperRuntime.open()` returns `unsupported(platform)`, and no `DynamicLibrary` is opened at import time. Desktop CI workflows stay green.
  - The ABI check works.

**AI-03 · Native shim implementation and host tests** · L
- Files: `src/dv_*.{h,cpp}`, `src/CMakeLists.txt` (host test target), `src/tests/**`.
- Depends on: AI-01, AI-02.
- Acceptance: all §16.3 C++ host tests pass on macOS and Linux CI, including a TSan job. A grep check confirms logs never contain segment text or paths. `dv_job_free` never leaks (ASan job).

**AI-04 · Android native build** · M
- Files: `packages/danaview_whisper/android/**`, `src/CMakeLists.txt` (Android part), `src/dv_exports.map`, `.github/workflows/android-release.yml` (size check step).
- Depends on: AI-03.
- Acceptance:
  - The AAB contains `libdanaview_whisper.so` (arm64-v8a, x86_64) and `libdanaview_whisper_v82.so` (arm64-v8a), and no armeabi-v7a copies.
  - ELF `LOAD` alignment is 16 KB (checked with the Android `check_elf_alignment.sh` or `llvm-readelf`).
  - Only `dv_*` symbols are exported. Each `.so` is ≤ 3 MB.
  - Variant selection is logged correctly on an A55-class device and a dotprod device.
  - It builds with the SDK's CMake 3.22.1, or the pinned version is documented.
  - There is no duplicate `libc++_shared.so` packaging conflict with media_kit.

**AI-05 · iOS native build** · M
- Files: `packages/danaview_whisper/ios/**`, `tool/build_ios_xcframework.sh`, `.gitignore`, `ios/fastlane/Fastfile` (pre-build step), `README.md` (setup).
- Depends on: AI-03.
- Acceptance:
  - A clean checkout plus the script plus `flutter build ipa` succeeds.
  - The podspec guard message appears when the framework is missing.
  - There are no `NEWLAPACK` symbols, and nothing newer than the deployment target is strongly bound (`nm -um` review).
  - The app launches on an iOS 15 simulator runtime and on iOS 26.
  - Metal is used on an A15 device on iOS ≥ 16.4 (from `dv_model_info.gpu_used`). The simulator uses CPU.
  - App Store Connect validation passes (no ITMS-90208). The privacy manifest is included. The IPA grows by ≤ 6 MB (thinned arm64).

**AI-06 · Device profile and events channel** · M
- Files: `lib/src/device/*`, `ios/Classes/{DanaviewWhisperPlugin.swift, DeviceProfiler.swift}`, `android/src/main/kotlin/com/vecvel/danaview/whisper/*`, `android/src/test/**`.
- Depends on: AI-02.
- Acceptance:
  - Every §4.8 method and event works on one iOS and one Android device (manual checklist). Dart parsing is defensive (unit tests with malformed maps).
  - Thermal mapping is unit-tested in Kotlin.
  - `excludeFromBackup` is verified with `URLResourceValues` on iOS.
  - The background task begins and ends, and its expiry emits an event.

**AI-07 · Dart runtime (`WhisperRuntime`, `WhisperModel`, `WhisperJob`)** · M
- Files: `lib/src/runtime/*`, `lib/src/ffi/library_loader.dart`, `test/**`.
- Depends on: AI-02, AI-03, AI-06.
- Acceptance:
  - All §16.1 runtime tests pass with fake bindings.
  - On device, transcribing `jfk.wav` through the Dart API matches the host test.
  - Hot restart during a running job leaves no orphan thread (debug check via `dv_shutdown_all`).
  - Poll cost is < 0.5 ms p95 (trace).

### Milestone M2: transcription core

**AI-08 · `danaview_transcription` package, catalog, languages, core types** · S
- Files: `packages/danaview_transcription/{pubspec.yaml, lib/danaview_transcription.dart, lib/src/catalog/*, lib/src/models/*}`.
- Depends on: AI-07 and the Domain types (`TimeUs`, `TimeRange`, `FrameRate`, ids).
- Acceptance: catalog and language tests (§16.1) pass, and the dependency-rule test is added.

**AI-09 · Model store and resumable downloader** · M
- Files: `lib/src/models_store/*`, `android/app/src/main/res/xml/danaview_{backup_rules,data_extraction_rules}.xml` plus manifest attributes (co-owned with Persistence).
- Depends on: AI-06, AI-08.
- Acceptance:
  - All downloader unit tests pass.
  - Real downloads of tiny and VAD on both platforms are verified. Kill-and-resume mid-download completes with a correct hash.
  - Models are excluded from backup (iOS attribute check; Android `adb shell bmgr` dry run shows the path excluded) [VERIFY tooling].
  - `UserConsent` call-site test passes.

**AI-10 · Speech audio extraction (contract, iOS, Android)** · M per platform
- Files: `lib/src/audio/speech_audio_extractor.dart` (AI) and the engine package's native files (engine areas: `SpeechAudioExtractor.swift`, `SpeechAudioExtractor.kt`, channel wiring).
- Depends on: the engine package skeleton and `MediaJobs`.
- Acceptance:
  - Output WAV is exactly 16 kHz, mono, s16, with a valid header.
  - Duration equals the range ±1 ms.
  - The clap test is within ±20 ms, including MP4 with an edit list and AAC priming.
  - The 5.1 downmix keeps the centre channel.
  - Cancel deletes partial output.
  - Unsupported codecs map to `unsupportedCodec`.
  - Throughput is ≥ 60× real time on mid devices.

**AI-11 · Normalizer, transcript cache, checkpoints** · M
- Files: `lib/src/transcript/*`.
- Depends on: AI-08.
- Acceptance: normalizer fixtures pass; cache LRU at 64 MiB; atomic writes; corrupt files are ignored and regenerated; a checkpoint append/replay round-trip; superset reuse.

**AI-12 · Segmentation engine** · L
- Files: `lib/src/segmentation/*`.
- Depends on: AI-08.
- Acceptance: golden fixtures in 9 languages and the property tests pass; 10k words in ≤ 150 ms; kinsoku rules; 9:16 defaults.

**AI-13 · Timeline planner, mapping and merge** · M
- Files: `lib/src/timeline/*` (including `domain_timeline_view.dart`).
- Depends on: AI-08 and the Domain time map (`timelineTimeOf`).
- Acceptance: the §16.1 planner and mapping tests pass, including ramps and overlap priority. Mapping a split clip yields continuous cues across the cut, with a penalty applied.

**AI-14 · Orchestrator (`TranscriptionServiceImpl`) and resource governor** · L
- Files: `lib/src/pipeline/*`, `lib/src/governor/*`.
- Depends on: AI-07, AI-09, AI-10, AI-11, AI-12, AI-13.
- Acceptance: the orchestration tests pass. An on-device run of 60 s English (Balanced) meets §16.4 scenario 1. The iOS background pause/resume and Android kill/resume scenarios pass. Thermal and export pausing are observed on device.

**AI-15 · Domain commands and provenance** (paired with the Domain area) · M
- Files: in the editor domain package, `commands/generated_captions.dart` and model fields, plus a migration test in Persistence.
- Depends on: Domain command infrastructure.
- Acceptance: one history entry each; undo/redo restores exactly; the `editedAfterGeneration` flag is set by any text or timing edit; schema migration of an older project defaults the new fields; a locked track is rejected as data.

### Milestone M3: UX

**AI-16 · Auto captions flow** (paired with UX) · L
- Files: `packages/danaview_editor/lib/src/editor/flows/captions/*` (`auto_captions_sheet.dart`, `auto_captions_controller.dart`, `language_picker.dart`, `model_consent_view.dart`, `captions_progress_panel.dart`), `editor_strings.dart` additions.
- Depends on: AI-14, AI-15, UI kit additions.
- Acceptance: all §11 states implemented with the §11.3 copy; §16.2 widget tests pass across the full surface matrix; no Material chrome; semantics checked with TalkBack and VoiceOver on one device each.

**AI-17 · Regenerate and track/task integration** · M
- Files: `track_menu_sheet.dart` (actions), the tasks sheet entry, the interrupted-job notice.
- Depends on: AI-16.
- Acceptance: instant re-split ≤ 300 ms for 30 min of speech; the edited-cues confirm; replace-in-range for clip scope; the resume notice appears after a kill.

**AI-18 · Settings, storage, privacy and licences** · M
- Files: `packages/danaview_editor/lib/src/settings/editor_settings_screen.dart` (section), `editor_storage_contributor.dart` (speech model), `packages/danaview_features/lib/src/more/legal_texts.dart`, a new custom `danaview_licences_screen.dart` plus route (if UX doesn't already own one), and `lib/main.dart` (`LicenseRegistry.addLicense`).
- Depends on: AI-09.
- Acceptance: deleting a model from Settings and from Storage works and is blocked during a job; the privacy text matches §13 exactly; the effective date is bumped; the licences screen lists the whisper.cpp, OpenAI Whisper and Silero notices verbatim; widget overflow tests pass.

### Milestone M4: hardening

**AI-19 · Benchmarks, accuracy eval, tuning** · L
- Files: `packages/danaview_transcription/tool/eval/**`, `integration_test/ai_benchmark_test.dart`, `docs/v1.1/video-editor/ai-eval.md`, catalog constants.
- Depends on: AI-14.
- Acceptance:
  - The §14.1 table is replaced by measured values on the §16.4 matrix.
  - RAM gating, GPU family policy (A12/A13), q5_1 vs q8_0 on Android, VAD and threshold defaults, CJK CPS and `qualityHint` are decided and documented.
  - The nightly eval job is green.

**AI-20 · On-device E2E and release checklist** · M
- Files: `integration_test/ai_captions_test.dart`, `docs/v1.1/video-editor/release-checklist.md` (AI section).
- Depends on: AI-16 through AI-19.
- Acceptance:
  - All §16.4 scenarios pass on the device matrix.
  - App Store and Play pre-launch reports are clean.
  - The privacy policy is live on the website.
  - The feature flag defaults to on.

### Deferred (designed for, not in v1 unless the owner pulls them in)

- **AI-D1 · Core ML encoder (iOS):** `WHISPER_COREML=ON` with `ALLOW_FALLBACK`. Download `ggml-<tier>-encoder.mlmodelc.zip` (tiny 15.0 MB, base 37.9 MB, small 163.1 MB, sha256 in the HF tree [VERIFIED sizes]), then unzip with a pure-Dart `archive` in an isolate. First-run ANE compile latency must be shown in the UI.
- **AI-D2 · SwiftPM `Package.swift`** for `danaview_whisper` (binaryTarget plus C target), once Flutter requires it.
- **AI-D3 · Android GPU backends** (OpenCL Adreno / Vulkan), behind a device allow-list and benchmark gating.
- **AI-D4 · Native background downloads** (iOS background `URLSession` / Android WorkManager) if field data shows abandoned downloads.
- **AI-D5 · iOS 26 `BGContinuedProcessingTask`** for long jobs in the background [VERIFY API and GPU entitlement].
- **AI-D6 · Gap-filling transcript cache** (partial-range reuse) and DTW word timing (`flash_attn` off), if AI-19 shows a timing benefit worth the speed cost.

---

## 19. Risks, open questions, uncertainties

### 19.1 Risks

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| ggml at iOS deployment target 13.0 has an unguarded API that breaks launch on older iOS | Medium | Critical (the app fails to launch) | Accelerate/BLAS off; `nm -um` review; iOS 15 simulator launch test (AI-05). Fallback: an owner decision to raise the app minimum to 16.4 (§19.2 Q1). |
| Upstream regressions on bump | Medium | Medium | Pin plus vendoring; eval suite gates every bump; never ship a release younger than 3 weeks. |
| Jetsam or OOM kill on 3–4 GB devices while the editor preview is also running | Medium | High | RAM gating, preflight available memory, cache trims, chunking, checkpoints and resume, tier downgrade suggestion. |
| Thermal throttling makes long jobs slow | High | Medium | Thread policy, cooldown, honest ETA, VAD. |
| Hallucinations on music or silence | Medium | Medium | VAD, `suppress_nst`, normalizer, eval set with music/silence clips. |
| HF CDN unavailable, URL changes, or a regional block | Low–Medium | High (feature unusable for new users) | Pinned revision plus sha; clear error. Owner may approve a mirror (Q2). |
| Platform decoders can't read some sources (MKV/Opus/DTS) | Medium (iOS MKV is common in this player's user base) | Medium | Clear per-clip skip messages; editor import gating (`ux.md` §0.8). Q3 offers an mpv-based fallback. |
| Word timestamps (non-DTW) drift by ±200–300 ms | Medium | Low–Medium | Linger and chaining in the segmenter hide small errors; AI-19 measures; DTW is deferred as an option. |
| Two variant `.so`s confuse crash symbolication | Low | Low | Upload symbols for both; log the chosen variant. |
| Build tooling: CMake missing on dev machines and future iOS CI | High (today) | Low | Podspec guard message, README, fastlane step. |

### 19.2 Open questions for the owner

1. **iOS minimum.** Keep the app at iOS 13.0 with AI available on iOS 15+ (this design), or raise the app minimum to 16.4, which matches upstream's tested floor and lets us use Accelerate and the upstream xcframework? Recommendation: keep 13.0 if AI-05 passes. The iOS engine area may raise it anyway.
2. **Model mirror.** Self-host the three model files (for example as GitHub release assets on vecvel's repo) as a fallback when HF fails? This changes the privacy text to name a second host. Recommendation: not in v1.
3. **libmpv audio-decode fallback.** For codecs the platform can't decode (MKV/Opus/DTS/TrueHD), use the already-bundled media_kit/libmpv with `ao=pcm` [VERIFY availability] to make the 16 kHz WAV? It would be decode-only for transcription and never used for rendering or export, but it is in tension with the "no FFmpeg" decision. Recommendation: owner decides. The default is to skip such clips with a message.
4. **Accurate tier on 3 GB iPhones** (XR, SE 2/3 class): allow it with a memory preflight, or hide it? Recommendation: hide until AI-19 measures.
5. **Leaving the editor during generation:** v1 stops (with a checkpoint for resume). Should it continue and insert later? That needs headless project mutation (Persistence). Recommendation: keep v1 behaviour.
6. **Transcript backups:** should cached transcripts be included in device backups? Currently included and small. Persistence may prefer excluded for consistency with project caches.

### 19.3 Items marked [VERIFY] (all have ticket ACs)

- Apple new-LAPACK iOS 16.4 floor and the absence of strongly bound newer symbols (AI-05).
- `os_proc_available_memory` availability and header (AI-06).
- Exact failure mode of Metal in the background on iOS (AI-14 scenario 3).
- A12 vs A13 GPU policy; first-Metal-init compile time (AI-19).
- `ggml` magic byte order (AI-09).
- `AVAssetReader.timeRange` sample accuracy; `MediaExtractorCompat` edit-list handling (AI-10 clap test).
- Android Auto Backup quota and `bmgr` verification tooling (AI-09).
- NDK CMake 3.22.1 sufficiency (AI-04).
- Pruned vendor tree builds (AI-01).
- CJK/Korean CPS defaults; per-language `qualityHint` source numbers (AI-19).
- Speed and memory table (§14.1) (AI-19).
- `Icons.subtitles_rounded` exists (AI-16; `ux.md` already checks icon names against the SDK).
- Figtree script coverage, which drives the font-fallback requirement (§10.4).
- Silero VAD upstream copyright line (AI-18).
- iOS 26 `BGContinuedProcessingTask` GPU entitlement (AI-D5).
- Required-reason API status of `sysctlbyname("machdep.cpu.brand_string")` and `clock_gettime` (AI-05).
- App Review stance on post-install model downloads (AI-20).
