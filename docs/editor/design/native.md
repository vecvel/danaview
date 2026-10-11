# Danaview Editor: Native Engines Design (iOS AVFoundation, Android Media3)

> **Area:** the editor engine. It covers preview, export, media services (probe, thumbnails, waveforms, proxies, reverse, freeze frame, speech-audio extraction), voice recording, and the platform services the editor needs (pickers, saving, background work). It is built as a Flutter plugin with iOS and Android code behind one Dart contract.
> **Status:** design draft for the Editor release. This document contains no production code. Dart, Swift, Kotlin, GLSL and Metal snippets are interface sketches.
> **Date:** 2026-10-07. **Baseline:** `main` @ `19cae59`. Flutter 3.44.2 / Dart 3.12.2, Xcode 26.6 (iOS SDK 26.5) on the dev Mac.
> **Sibling docs** in `docs/editor/design/`: `ux.md` (screens, controllers, and the minimum `EditorEngine` contract in its §2.3), `ai.md` (whisper.cpp; it defines `SpeechAudioExtractor` in §7 and `BackgroundWorkGuard` in §6.3), plus Domain & project model and Persistence & media docs. Those two were not yet written when this doc was drafted. **When a type belongs to another area, that area's name wins.** §12 lists every interface where this area meets another.
>
> **Markers.** **[VERIFIED]** means I checked it on 2026-10-07 against a primary source: SDK headers in Xcode 26.6, Media3 1.11.1 AAR bytecode (`javap`), Google Maven or pub.dev metadata, the Flutter 3.44.2 engine sources, or this repo. **[VERIFY]** means I believe it but did not check it. Every [VERIFY] item has a ticket acceptance criterion that settles it. **[ASSUMPTION]** marks a guess about a sibling area.

---

## 0. Decisions at a glance

1. **Two packages.**
   - `packages/danaview_editor_engine_api` is a Flutter package with **no native code**. It holds the platform-neutral `EditorEngine` contract, value types, failures, the RenderPlan **wire codec**, render-prep services (text sprites, LUT normalization), the shared math reference, `FakeEditorEngine`, and a contract test kit.
   - `packages/danaview_editor_engine` is a Flutter **plugin** for iOS and Android. It contains `MobileEditorEngine` (Pigeon-based) and the native engines.
   - A later desktop engine implements the same API package. `danaview_editor` (UX) depends only on the API package.
2. **Domain compiles; native renders.** The Domain area compiles the project into a **RenderPlan**: an immutable, fully resolved description with item render ranges (transition handles applied), speed segments, keyframe arrays, and resolved mute and solo. Native code makes no editing decisions. It maps the plan onto AVFoundation or Media3 and evaluates keyframes per frame with the shared linear formula. **This doc owns the wire schema v1 and the render-math semantics (§4).** Domain owns the Dart types and the compiler.
3. **Transport.** Control calls and events use **Pigeon 29.x**: `@HostApi` with `@async`, plus one multiplexed `@EventChannelApi` stream. Plans and patches travel as **UTF-8 JSON bytes**, encoded in an isolate. Native decodes them off the main thread with `JSONDecoder` or `android.util.JsonReader`. Transient gesture overrides are tiny fire-and-forget messages, coalesced natively to one per frame.
4. **Text is rasterized by Flutter, not by native.** This resolves `ux.md` Q3. Text items and subtitle cues are laid out with `ui.Paragraph`, using bundled user-content fonts plus system fallback for RTL and CJK. They are rasterized to `.vsprite` files: premultiplied RGBA compressed with zlib, plus an optional glyph-order reveal map for the typewriter animation. Native code only places sprites. This gives identical metrics for the preview handles, the preview and the export on both platforms, and no CoreText or StaticLayout parity work.
5. **iOS engine.** It is built from:
   - `AVMutableComposition` (lane → composition tracks by interval coloring, `scaleTimeRange` for speed segments, plus a spacer track that guarantees one compositor call per frame),
   - a custom `AVVideoCompositing` compositor with **Core Image on Metal** and precompiled Metal CI kernels,
   - `AVMutableAudioMix` (volume ramps, per-track `audioTimePitchAlgorithm`),
   - `AVPlayer` with `AVPlayerItemVideoOutput` → `FlutterTexture` for preview,
   - `AVAssetReader` (composition outputs) → `AVAssetWriter` (VideoToolbox H.264/HEVC) for export.
6. **Android engine.** It is built from:
   - Media3 **1.11.1** [VERIFIED latest stable]: a multi-sequence `Composition` played by `CompositionPlayer` with `MultipleInputVideoGraph`, and exported by `Transformer` with `InAppMp4Muxer`.
   - Every visual layer is drawn into canvas space by our own `GlEffect` shaders (`LayerLook`, `LayerPlace`, `SpriteBand`).
   - The stock `DefaultVideoCompositor` only alpha-blends canvas-sized layers. Our `VideoCompositorSettings` hides layers during their gaps.
   - Sequence 0 is the top layer and also the frame clock [VERIFIED in bytecode]. It is a full-length transparent sprite band at the project fps.
7. **One render-math spec, three implementations.** Every effect, transition, text animation and gain formula is written once (§4.8). It is implemented in a Metal CI kernel, a GLSL ES 1.00 shader, and a Dart CPU reference renderer that produces golden images. Parity tests compare device output to the reference. Both GPUs work on **gamma-encoded BT.709 values**: iOS uses a `CIContext` with color management off; Android uses `WORKING_COLOR_SPACE_ORIGINAL`.
8. **Minimum OS for the editor (runtime gate).** The app's deployment targets stay at iOS 13.0 and Android minSdk 24.
   - The editor needs **iOS 15.0+**. Reasons: the async `AVAsset` loading APIs (`loadTracks(withMediaType:)` is iOS 15 [VERIFIED]; the synchronous `tracks` is deprecated in iOS 18), `PHPicker` and `UTType`, and a smaller test matrix.
   - The editor needs **Android 10 (API 29)+**. Reasons: OpenGL HDR→SDR tone mapping, `MediaCodecInfo.isHardwareAccelerated`, the thermal API, `MediaStore` pending inserts without storage permission, and `SurfaceProducer` backed by HardwareBuffer.
   - Below these versions, `capabilities().supported == false` with a reason, and the UX shows its device-unsupported state (`ux.md` §4.1). **Owner/lead to confirm (§13 D1).**
9. **Frame grid and seeking.**
   - Project frame rates are **integers** (24, 25, 30, 48, 50, 60). Media3 image items only take an `int` frame rate [VERIFIED]. NTSC sources conform to the nearest integer rate.
   - Frame `k` starts at `ceil(k·10⁶/fps)` µs.
   - Exact seeks always target a frame. iOS seeks to the rational time `k/fps`; Android seeks to the ms ceiling of that time. Each seek ack returns the frame that was actually displayed.
10. **Containers and codecs.**
    - MP4 on both platforms. **MOV on iOS only**: Media3 has no MOV muxer [VERIFIED].
    - H.264 everywhere. H.265 only where a hardware encoder is found by a runtime probe.
    - SDR BT.709 8-bit output only. HDR sources are tone-mapped to SDR.
    - No FFmpeg anywhere in the editor.
11. **Background export.**
    - **Android:** a process-scoped `ExportCoordinator` plus a foreground service: type `mediaProcessing` on API 35+, `dataSync` on API 29–34.
    - **iOS:** GPU work is not allowed in the background. On iOS 26+ we submit a `BGContinuedProcessingTask`, with the GPU resource when it is supported and entitled [VERIFIED API]. Otherwise the export **pauses** in the background and resumes in the foreground.
12. **Heavy media work runs natively in a priority job queue** with cancel and typed results: thumbnails, waveforms, proxies, reverse, freeze frame, and 16 kHz speech audio. The disk caches are keyed by the Persistence `mediaFingerprint`. **Original media is only ever opened for reading.** Every output goes to project-owned or cache paths that Dart supplies.

---

## 1. Ground truth and verified versions

| Item | Value | Source |
|---|---|---|
| Repo app ids | iOS bundle `com.vecvel.danaview`; Android `applicationId`/namespace `com.vecvel.danaview` (the brief said `danaviewplayer` / `danaview_player`) | `project.pbxproj`, `app/build.gradle.kts` [VERIFIED] |
| Android toolchain | AGP 9.0.1, Kotlin 2.3.20, Gradle 9.1, Java 17, compileSdk/targetSdk 36, `minSdk = flutter.minSdkVersion` = **24** (`FlutterExtension.kt`) | repo + Flutter SDK [VERIFIED] |
| iOS toolchain | deployment 13.0, Swift 5.0, CocoaPods 1.16.2 (media_kit pods) **plus** SPM (`FlutterGeneratedPluginSwiftPackage` present), `UIBackgroundModes=[audio]` | repo [VERIFIED] |
| Manifest today | `FOREGROUND_SERVICE` (no type-specific permission), no `RECORD_AUDIO`, no `POST_NOTIFICATIONS`, no services | `AndroidManifest.xml` [VERIFIED] |
| CI today | release workflows only (android/linux/windows); no test workflow | `.github/workflows` [VERIFIED] |
| Flutter textures | Android `TextureRegistry.createSurfaceProducer(SurfaceLifecycle.{manual,resetInBackground})`, `SurfaceProducer.{setSize,getSurface,setCallback(onSurfaceAvailable/onSurfaceCleanup),scheduleFrame}`. iOS `FlutterTexture.copyPixelBuffer` with BGRA/420v/420f buffers; register and `textureFrameAvailable` on the platform thread | engine sources in the 3.44.2 SDK [VERIFIED] |
| Media3 | **1.11.1** latest stable (Maven `lastUpdated` 2026-09-11). AAR `minSdkVersion=23`, `minCompileSdk=36`, guava `33.3.1-android` | Google Maven [VERIFIED] |
| Media3 APIs relied on | `CompositionPlayer.{setComposition(c, startMs), setScrubbingModeEnabled, experimentalRedrawLastFrame, setVideoSurface(Surface, Size), setVideoFrameMetadataListener}`; Builder `{setVideoGraphFactory (default **SingleInputVideoGraph**), experimentalSetEnableReplayableCache, setGlThreadExecutorService, setLooper, setAudioAttributes}`; `MultipleInputVideoGraph.Factory(VideoFrameProcessor.Factory)`; `EditedMediaItem.Builder.{setSpeed(SpeedParameters(provider, shouldMaintainPitch)), setDurationUs, setFrameRate(int), setEffects, setRemoveAudio/Video}` (speed params honored by **both** player and Transformer); `EditedMediaItemSequence.Builder(Set<trackType>).addGap(us)`; `Composition.Builder.{setVideoCompositorSettings, setEffects, setHdrMode}`; `VideoCompositorSettings.{getOutputSize, getOverlaySettings(inputId, ptsUs)}`; `BaseGlShaderProgram.{configure, drawFrame}`; `GaussianBlur(sigma)`; `Transformer.{start(Composition, path), getProgress(ProgressHolder), cancel}`; `VideoEncoderSettings.Builder.{setBitrate, setBitrateMode, setEncodingProfileLevel, setiFrameIntervalSeconds}`; `DefaultEncoderFactory.Builder.{setVideoEncoderSelector, setRequestedVideo/AudioEncoderSettings, setEnableFallback}`; `InAppMp4Muxer.Factory.setAttemptStreamableOutputEnabled`; `media3-inspector-frame` `FrameExtractor` (`getFrame`, `setSeekParameters`, `setEffects`); `GainProcessor` + `DefaultGainProvider` (linear and equal-power fades); `ExportException.ERROR_CODE_*`; `ExportResult.videoEncoderName` | `javap` on the 1.11.1 AARs [VERIFIED] |
| Media3 internals relied on | (a) `DefaultVideoCompositor`: the **first registered input is primary**. Frames are drawn from the last index to index 0, so **index 0 is on top**. Blend is `glBlendFuncSeparate(SRC_ALPHA, ONE_MINUS_SRC_ALPHA, ONE, ONE_MINUS_SRC_ALPHA)`. Each secondary frame is chosen by **min \|Δt\|** (nearest). HDR input and mixed `ColorInfo`s are rejected. (b) Video gaps render **opaque black** bitmaps at 30 fps. (c) `CompositionPlayer` logs a warning for a multi-sequence composition on the single-input graph. | bytecode of `DefaultCompositorGlProgram`, `DefaultVideoCompositor`, `SequenceAssetLoader`, `CompositionPlayer` [VERIFIED] |
| Muxers | Media3 has Mp4, FragmentedMp4, WebM, Ogg, Aac, Wav. **No MOV** | `media3-muxer` class list [VERIFIED] |
| iOS APIs relied on | `AVVideoCompositing.supportsHDRSourceFrames` (iOS 14): when NO, HDR sources are converted to the composition color space before they reach the compositor. `AVAudioMixInputParameters.audioTimePitchAlgorithm` and `AVAssetReaderAudioMixOutput.audioTimePitchAlgorithm` (iOS 7). `AVPlayerItem.seekingWaitsForVideoCompositionRendering` (iOS 6). `AVAssetImageGenerator.generateCGImagesAsynchronously(forTimes:)` (not deprecated) and `dynamicRangePolicy` (iOS 18). `AVAsset.loadTracks(withMediaType:)` (iOS 15). `CIKernel(functionName:fromMetalLibraryData:)`; `CIKernel.kernels(withMetalString:)` is iOS 15 **and needs `supportsDynamicLibraries`**, so we don't use it. `BGContinuedProcessingTask`/`Request` (iOS 26) with `requiredResources = .gpu`, which needs entitlement `com.apple.developer.background-tasks.continued-processing.gpu`, plus `BGTaskScheduler.supportedResources`. `AVAudioApplication.requestRecordPermission` (iOS 17); the `AVAudioSession` variant is deprecated in iOS 17 | iOS 26.5 SDK headers [VERIFIED] |
| Pigeon | 29.0.7 (2026-10-07); 29.0.0 shipped 2026-09-12; requires Dart `^3.11` | pub.dev API [VERIFIED] |
| AndroidX | `activity` 1.13.0 (Photo Picker contracts), `concurrent-futures-ktx` 1.3.0, `kotlinx-coroutines-android` 1.11.0 | Maven metadata [VERIFIED listing; compatibility with Kotlin 2.3.20: VERIFY] |

---

## 2. Packages and file layout

### 2.1 `packages/danaview_editor_engine_api` (Flutter package, no native code)

```
pubspec.yaml            # flutter, meta, collection, <domain pkg> (RenderPlan types), path
lib/danaview_editor_engine_api.dart       # public contract
lib/testing.dart                        # FakeEditorEngine, contract kit, reference renderer
lib/src/
  engine.dart            EditorEngine, EngineMedia, EditCompatibility, MediaProbe
  preview.dart           PreviewSession, PreviewConfig, PreviewClock, SeekAck, PreviewEvent, EditingMode
  media_services.dart    ThumbnailSource, WaveformSource, MediaJobs, MediaJob, GeneratedAsset
  export.dart            ExportService, ExportSettings, ExportJob, ExportProgress, ExportPreflight
  recorder.dart          VoiceRecorder, RecordingSession, RecordedAsset
  platform_services.dart MediaPicker, FileHandoff, MediaAccess (bookmarks), BackgroundWorkGuard
  capabilities.dart      EditorCapabilities, DeviceTier, BackgroundExportKind
  failures.dart          EngineFailure (sealed) + EngineErrorCode
  plan/   plan_wire_codec.dart  plan_patch_codec.dart  plan_validator.dart  render_plan_v1.schema.json
  render_prep/ text_layout_engine.dart  text_sprite_rasterizer.dart  vsprite_codec.dart
               sprite_scheduler.dart  lut_normalizer.dart  vlut_codec.dart
  math/   frame_grid.dart  keyframes.dart  transform2d.dart  grade_math.dart  chroma_math.dart
          mask_math.dart  transitions_math.dart  text_anim_math.dart  gain_math.dart
  reference/ reference_renderer.dart          # CPU implementation of §4.8 for goldens
  fake/   fake_editor_engine.dart  fake_preview_session.dart  fake_jobs.dart
test/  test_fixtures/{plans,patches,vectors,images,sprites,luts,media}/
```

### 2.2 `packages/danaview_editor_engine` (Flutter plugin: ios, android)

```
pubspec.yaml   # plugin: ios {pluginClass: DanaviewEditorEnginePlugin}; android {package: com.vecvel.danaview.editor.engine,
               #   pluginClass: DanaviewEditorEnginePlugin}; deps: danaview_editor_engine_api; dev: pigeon ^29.0.0
pigeons/engine_api.dart
lib/danaview_editor_engine.dart            # MobileEditorEngine.create()
lib/src/ mobile_editor_engine.dart  mobile_preview_session.dart  mobile_jobs.dart  mobile_export.dart
         mobile_recorder.dart  mobile_platform_services.dart  event_router.dart  error_mapper.dart
         plan_sync.dart (revision tracking, patch vs full, out-of-sync retry)  pigeon/engine_api.g.dart
ios/danaview_editor_engine.podspec        # s.platform :ios '13.0'; frameworks AVFoundation CoreImage Metal CoreVideo
                                        # VideoToolbox ImageIO Photos PhotosUI UniformTypeIdentifiers BackgroundTasks(weak)
                                        # pod_target_xcconfig MTL_COMPILER_FLAGS=-fcikernel, MTLLINKER_FLAGS=-cikernel
ios/Classes/
  DanaviewEditorEnginePlugin.swift   Pigeon/EngineApi.g.swift
  Core/        EngineContext  ErrorCodes  DeviceProfile  Capabilities  JobRegistry  EventHub  Log  Paths
  Plan/        RenderPlan (Codable)  PlanStore  PlanDiff  Keyframes  FrameGrid  ParamSnapshot
  Composition/ CompositionBuilder  TrackAllocator  InstructionBuilder  AudioMixBuilder  AssetCache  SpacerTrack
  Render/      DVCompositor  DVInstruction  LayerRenderer  Kernels  SpriteStore  ImageLayerCache  LutStore
               Shaders/DanaviewKernels.metal
  Preview/     PreviewSession  TextureBridge  DisplayLinkDriver  SeekController  QualityGovernor  SourceFrameCache
  Export/      ExportJob  ReaderWriterPipeline  EncoderSettings  BackgroundExecution  ActiveExportStore
  Media/       Probe  Compatibility  ThumbnailService  WaveformService  PcmReader  SpeechAudioExtractor
               ProxyJob  ReverseJob  FreezeFrameJob  ProxyRegistry  DiskCache
  Recording/   VoiceRecorder
  Platform/    MediaPicker  FileHandoff  PhotosSaver  MediaAccess  Permissions  BackgroundGuard
  Resources/   spacer_16x16.mov  PrivacyInfo.xcprivacy
android/build.gradle.kts               # com.android.library + kotlin-android; minSdk 24 (runtime gate 29)
android/src/main/AndroidManifest.xml   # ExportService (FGS), permissions, FileProvider
android/src/main/assets/danaview_shaders/*.glsl
android/src/main/kotlin/com/vecvel/danaview/editor/engine/
  DanaviewEditorEnginePlugin.kt  pigeon/EngineApi.g.kt
  core/        EngineContext  ErrorCodes  DeviceProfile  Capabilities  JobRegistry  EventHub  EngineThreads  Paths
  plan/        RenderPlan  PlanJsonReader  PlanStore  PlanDiff  Keyframes  FrameGrid  ParamSnapshot
  composition/ CompositionMapper  TrackAllocator  SequenceBuilders  LayerGatingCompositorSettings
               SegmentSpeedProvider  KeyframedGainProvider
  effects/     LayerLookEffect  LayerPlaceEffect  SpriteBandEffect  SeparableBlurEffect  GlPrograms
               LutTextures  SpriteTextures
  preview/     PreviewSession  SurfaceBridge  SeekController  QualityGovernor  SourceFrameCache
  export/      ExportCoordinator  ExportService  ExportNotification  EncoderSettings  HardwareEncoderSelector
               ActiveExportStore
  media/       Probe  Compatibility  ThumbnailService  WaveformService  PcmDecoder  SpeechAudioExtractor
               ProxyJob  ReverseJob  FreezeFrameJob  ProxyRegistry  DiskCache
  recording/   VoiceRecorder
  platform/    MediaPicker  FileHandoff  MediaStoreSaver  Permissions  BackgroundGuard
android/src/test/kotlin/...  android/src/androidTest/kotlin/...
example/       # test host app: integration_test/, ios/RunnerTests (XCTest), android androidTest runner
```

**Gradle dependencies (plugin):** `androidx.media3:media3-{transformer,effect,exoplayer,common,muxer,inspector,inspector-frame}:1.11.1`, `androidx.activity:activity:1.13.0`, `androidx.concurrent:concurrent-futures-ktx:1.3.0`. The plugin uses its own executors, not coroutines, to keep the dependency surface small. Media3 is `@UnstableApi`: the module enables `@OptIn(UnstableApi::class)` per file, and lint `UnsafeOptInUsageError` stays an error everywhere else.

**iOS packaging:** **CocoaPods only in v1**, the same choice as `danaview_whisper`. Reason: the Metal CI kernels need `-fcikernel` / `-cikernel`, which the podspec can set and SPM manifests cannot. Shipping `Package.swift` with a prebuilt metallib is a deferred ticket (ENG-D1).

### 2.3 Dependency rules (enforced by the pubspec-parsing test from `ux.md` §3.3)

- `danaview_editor` → `danaview_editor_engine_api` only. `lib/main.dart` overrides the engine provider with `MobileEditorEngine` on iOS and Android, and leaves the editor gated on desktop.
- `danaview_editor_engine` → `danaview_editor_engine_api` (+ domain pkg through it). It never imports `danaview_editor`, `danaview_features` or `danaview_transcription`.
- `danaview_transcription` gets audio extraction only through its `SpeechAudioExtractor` port (`ai.md` §7). `editor_providers.dart` binds that port to `engine.jobs.extractSpeechAudio`.
- Desktop later: a `danaview_editor_engine_desktop` plugin implements the API. macOS can reuse about 90% of the iOS Swift, because AVFoundation and Core Image are the same; the plugin then sets `sharedDarwinSource: true`. Nothing in the API package mentions a platform.

---

## 3. Dart-facing contract

This is the final shape of `ux.md` §2.3. **Additions** are marked `// +`. Names the UX uses are unchanged. MediaId-keyed calls in the UX map onto `EngineMedia` through a resolver in `danaview_editor`.

### 3.1 Engine root, media identity, probe

```dart
/// What native needs to open one media file. Built by Persistence's media pool.
final class EngineMedia {
  const EngineMedia({required this.uri, required this.fingerprint, this.bookmark});
  final String uri;              // file:///… or content://…  (never http)
  final String fingerprint;      // Persistence's stable media fingerprint (cache key)
  final Uint8List? bookmark;     // iOS security-scoped bookmark for opened-in-place files
}

abstract interface class EditorEngine {
  Future<EditorCapabilities> capabilities();                       // cached after first call
  Future<EditCompatibility> compatibility(String pathOrUri);       // ≤ 300 ms, container + codec checks
  Future<MediaProbe> probe(EngineMedia media);                     // +  import, relink validation
  Future<PreviewSession> openPreview(PreviewConfig config);
  ThumbnailSource get thumbnails;
  WaveformSource get waveforms;
  ExportService get exporter;
  MediaJobs get jobs;
  VoiceRecorder? get voiceRecorder;                                // null when !capabilities.voiceRecording
  MediaPicker get picker;                                          // +  (ux: pickMedia)
  FileHandoff get files;                                           // +  (ux: exportFile)
  MediaAccess get access;                                          // +  bookmarks / persisted URI grants
  BackgroundWorkGuard get background;                              // +  ai.md §6.3
  Future<int> freeBytes();
  Stream<EngineSignal> get signals;                                // +  memoryWarning, thermal(level)
  Future<void> trimCaches(CacheTrimLevel level);                   // +  memory pressure → native caches
}

final class MediaProbe {
  MediaKind kind;                    // video | audio | image
  int durationUs; int? width, height; int rotationDegrees;          // display size has rotation applied
  double? nominalFps; bool variableFrameRate; String? videoCodec; int? bitDepth; bool hdr;
  bool hasAudio; int audioStreams; String? audioCodec; int? sampleRate; int? channels;
  int sizeBytes; bool editable; List<String> issues;                // e.g. 'hdr_needs_proxy', 'vfr'
}
sealed class EditCompatibility { }                                  // Editable | NotEditable(reasonCode, message)
```

### 3.2 Preview

```dart
final class PreviewConfig {
  final int canvasWidth, canvasHeight, fps;      // integer fps (§4.3)
  final PreviewQuality quality;                  // auto | full | half | quarter
  final bool useProxies;
}

abstract interface class PreviewSession {
  int get textureId;
  ValueListenable<Size?> get frameSize;
  Future<void> setPlan(RenderPlan plan);                        // full replace; encodes in an isolate
  Future<void> applyPatch(RenderPlanPatch patch);               // falls back to setPlan on out-of-sync
  void setTransient(ItemId item, PropertyPatch patch);          // ≤ 1 per frame natively; never structural
  void clearTransient(ItemId item);
  void updateSprites(List<SpriteRef> ready);                    // +  sprite files became ready (§4.7)
  Future<void> play({TimeRange? loop});
  Future<void> pause();
  Future<SeekAck> seek(TimeUs t, {SeekKind kind = SeekKind.exact});
  Future<void> setQuality(PreviewQuality q);
  Future<void> setUseProxies(bool on);
  Future<void> setEditingMode(PreviewEditingMode mode);        // normal | cropSource(item) | matte(item)
  Future<void> showSourceFrame(EngineMedia m, TimeUs sourceTime);  // +  trim-edge preview; cleared by seek/play
  Future<Color?> sampleColor(ItemId item, Offset normalizedSourcePoint);
  Future<List<Uint8List>> renderLookStills(ItemId item, List<LookSpec> looks, {required int heightPx}); // +
  Future<void> refresh();
  Stream<PreviewClock> get clock;   // state changes + 10 Hz while playing
  Stream<PreviewEvent> get events;  // firstFrame | stalled | degraded(q) | recovered | surfaceLost | failed(f)
  Future<void> dispose();
}
final class PreviewClock { final TimeUs time; final bool playing; final double rate; final int seq; }
final class SeekAck { final TimeUs requested; final TimeUs displayedFrameTime; final int displayedFrame; final int seq; }
```

**Semantics (normative):**
- `seq` increases with every seek, play and pause. A clock sample carries the `seq` of the last command it reflects.
- `seek(kind: exact)` resolves only after the composed frame for `frameIndexOf(t)` is in the texture.
- `seek(kind: scrub)` may show any frame within ±1 GOP, or proxy GOP when proxies are on. Its ack still reports the displayed frame.
- `setTransient` writes only to an in-memory override map. It never touches the plan revision, disk or history. A transient on a timing field (start, end, source, speed, lane) is ignored natively and counted in debug stats, because timing changes are structural (§4.5).

### 3.3 Media services and jobs

```dart
abstract interface class ThumbnailSource { ThumbnailHandle request(ThumbnailRequest r, {required ThumbPriority priority}); }
final class ThumbnailRequest { EngineMedia media; int intervalMs; int tileIndex; int heightPx; int framesPerTile /* 8 */; bool proxy; }
final class ThumbnailTile { Uint8List encoded /* JPEG strip */; int frames; int frameWidthPx; }

abstract interface class WaveformSource {
  /// int8 min/max pairs at 200 pairs/s for one audio stream, cached on disk. Completes once fully computed.
  MediaJob<WaveformPeaks> peaks(EngineMedia media, {int audioStream = 0});
}

abstract interface class MediaJobs {
  MediaJob<GeneratedAsset> proxy(EngineMedia media);                                   // cache-owned
  MediaJob<GeneratedAsset> reverse(EngineMedia media, TimeRange source, {required String outputPath});
  MediaJob<GeneratedAsset> freezeFrame(EngineMedia media, TimeUs sourceTime, {required String outputPath});
  MediaJob<ExtractedSpeechAudio> extractSpeechAudio(SpeechAudioRequest r);              // ai.md §7.1, verbatim
  ProxyStatus proxyStatus(EngineMedia media);                                          // + none|queued|running(p)|ready
}
abstract interface class MediaJob<T> {
  String get id; Stream<double> get progress; Future<T> get result;   // throws EngineFailure / JobCancelled
  void cancel();                                                      // idempotent; deletes partial output
  void setPriority(JobPriority p);                                    // interactive | normal | background
}
final class GeneratedAsset { final String path; final MediaProbe probe; }
```

### 3.4 Export

```dart
abstract interface class ExportService {
  Future<ExportPreflight> preflight(RenderPlan plan, ExportSettings s);   // + complexity / size / codec check
  Future<ExportJob> start(RenderPlan plan, ExportSettings s, String outputPath);  // temp path; Dart hands off
  Future<List<ExportJobState>> activeJobs();                              // + reattach after engine restart;
                                                                          //   includes one-shot 'interrupted'
}
final class ExportSettings {
  final ExportContainer container;      // mp4 | mov
  final VideoCodec codec;               // h264 | hevc
  final int width, height, fps, videoBitrate, audioBitrate;   // bps; audio is AAC-LC 48 kHz stereo
  final int keyframeIntervalSec;        // default 2
}
final class ExportPreflight { final bool ok; final int? maxHeightForPlan; final List<ExportWarning> warnings; }
                                        // warnings: softwareEncoder, hevcUnavailable, backgroundPauses, ...
abstract interface class ExportJob {
  String get id; Stream<ExportProgress> get progress; Future<ExportResult> get result; Future<void> cancel();
}
final class ExportProgress { ExportPhase phase /* preparing|rendering|finishing */; double fraction;
  int framesDone, framesTotal; bool backgrounded; bool pausedInBackground; }
final class ExportResult { String path; int bytes; int durationUs; String videoEncoderName; bool hardwareEncoder; }
```

The pre-pass that rasterizes sprites (Dart, §4.7) runs **before** `start`. The UX shows it as the `Preparing` phase.

### 3.5 Recorder, platform services, background guard

```dart
abstract interface class VoiceRecorder {      // ux.md §2.3 + startOffset
  Future<MicPermission> permission(); Future<MicPermission> requestPermission(); Future<void> openSystemSettings();
  Future<RecordingSession> start({required String outputPath});   // WAV PCM s16 48 kHz mono
}
abstract interface class RecordingSession { Stream<double> get levels; Stream<RecordingInterruption> get interruptions;
  Future<RecordedAsset> stop(); Future<void> cancel(); }
final class RecordedAsset { String path; int durationUs; int startLatencyUs; } // place clip at tStart + latency

abstract interface class MediaPicker {
  Future<List<PickedMedia>> pick(MediaPickRequest r);   // photos (PHPicker / Photo Picker) or files (UIDocumentPicker / SAF)
}                                                      // kinds: video, audio, image, lut, subtitle
final class PickedMedia { String uri; String displayName; bool isTemporaryCopy; Uint8List? bookmark; int? sizeBytes; }
abstract interface class FileHandoff {
  Future<FileHandoffResult> saveToPhotos(String path);  // PHPhotoLibrary add-only / MediaStore Movies/Danaview
  Future<FileHandoffResult> saveToFiles(String path, String suggestedName); // UIDocumentPicker export / SAF create
  Future<FileHandoffResult> share(String path);         // UIActivityViewController / ACTION_SEND + FileProvider
}
abstract interface class MediaAccess {                  // used by Persistence (§12)
  Future<Uint8List?> createBookmark(String uri); Future<BookmarkResolution> resolve(Uint8List bookmark);
  Future<bool> persistUriGrant(String contentUri); Future<bool> canRead(String uri);
}
abstract interface class BackgroundWorkGuard {          // ai.md §6.3, verbatim
  Future<BackgroundLease?> acquire({required String title, required Stream<double> progress});
}
```

### 3.6 Capabilities

```dart
final class EditorCapabilities {
  final bool supported; final String? unsupportedReason;             // 'ios_too_old', 'gles3_missing', …
  final DeviceTier tier; final bool lowMemoryDevice;                 // low | mid | high (§8.2)
  final bool h264Encode, hevcEncode, hardwareH264, hardwareHevc, movContainer;
  final Size maxExportSize; final Map<int, int> maxFpsByHeight;      // per codec actually: keyed by codec in v1.1
  final int maxConcurrentVideoLayers;                                // simultaneous decoding video layers
  final int maxPreviewLongSide;                                      // 960 / 1280 / 1920 by tier
  final BackgroundExportKind backgroundKind;                         // none|timeLimited|continued|foregroundService
  final bool backgroundGpu;                                          // iOS 26 GPU resource available
  final bool voiceRecording, proxiesRecommended;
  final double minSpeed, maxSpeed;                                   // 0.1, 10.0
  final int maxLutSize;                                              // 65
}
```

### 3.7 Failures

```dart
enum EngineErrorCode { mediaOffline, permissionDenied, unsupportedMedia, decoderInitFailed, decodeFailed,
  encoderUnavailable, encoderSizeLimit, encodingFailed, diskFull, io, planInvalid, planOutOfSync,
  gpuUnavailable, surfaceLost, interrupted, cancelled, busy, notSupportedOnDevice, internal }
sealed class EngineFailure implements Exception { EngineErrorCode get code; String get debugDetail; /* no paths */ }
```

`error_mapper.dart` turns every `PlatformException(code: <EngineErrorCode.name>, details: {…})` into an `EngineFailure`. The UX maps those to `EditorFailure` (§9). An unknown code becomes `internal`. No raw `PlatformException` ever leaves the plugin.

### 3.8 Pigeon surface

```dart
// pigeons/engine_api.dart  (pigeon ^29.0.0)
@ConfigurePigeon(PigeonOptions(dartOut: 'lib/src/pigeon/engine_api.g.dart',
  swiftOut: 'ios/Classes/Pigeon/EngineApi.g.swift',
  kotlinOut: 'android/src/main/kotlin/com/vecvel/danaview/editor/engine/pigeon/EngineApi.g.kt',
  kotlinOptions: KotlinOptions(package: 'com.vecvel.danaview.editor.engine.pigeon')))

@HostApi() abstract class EngineHostApi {
  @async CapabilitiesMsg capabilities();       @async CompatibilityMsg compatibility(String uri);
  @async ProbeMsg probe(EngineMediaMsg m);     @async int freeBytes();   void trimCaches(int level);
}
@HostApi() abstract class PreviewHostApi {
  @async PreviewOpenedMsg open(PreviewConfigMsg c);               // returns sessionId + textureId
  @async PlanAckMsg setPlan(int session, Uint8List planJson);      // ack: revision, structural, applyMs
  @async PlanAckMsg applyPatch(int session, Uint8List patchJson);  // error code planOutOfSync → resend full
  void setTransient(int session, String itemId, Uint8List paramsJson);   // no reply
  void clearTransient(int session, String itemId);
  @async void updateSprites(int session, List<SpriteRefMsg> sprites);
  @async void play(int session, LoopMsg? loop);   @async void pause(int session);
  @async SeekAckMsg seek(int session, int timeUs, bool exact);
  @async void setQuality(int session, int q);     @async void setUseProxies(int session, bool on);
  @async void setEditingMode(int session, EditingModeMsg m);
  @async void showSourceFrame(int session, EngineMediaMsg m, int sourceTimeUs);
  @async ColorMsg? sampleColor(int session, String itemId, double x, double y);
  @async List<Uint8List> renderLookStills(int session, String itemId, Uint8List looksJson, int heightPx);
  @async void refresh(int session);               @async void dispose(int session);
}
@HostApi() abstract class JobsHostApi {
  @async Uint8List thumbnailTile(String jobId, ThumbnailRequestMsg r, int priority);  // bytes reply
  @async String startJob(JobRequestMsg r);   // waveform|proxy|reverse|freeze|speechAudio → jobId; events follow
  void cancelJob(String jobId);  void setJobPriority(String jobId, int p);  int proxyStatus(String fingerprint);
}
@HostApi() abstract class ExportHostApi {
  @async ExportPreflightMsg preflight(Uint8List planJson, ExportSettingsMsg s);
  @async String start(Uint8List planJson, ExportSettingsMsg s, String outputPath);
  @async void cancel(String jobId);   @async List<ExportJobStateMsg> activeJobs();
}
@HostApi() abstract class RecorderHostApi { /* permission, request, openSettings, start(path)→id, stop(id), cancel(id) */ }
@HostApi() abstract class PlatformHostApi { /* pick, saveToPhotos, saveToFiles, share, bookmarks, grants,
                                                acquireBackground(title)→leaseId, updateBackground(id, p), release(id) */ }
@EventChannelApi() abstract class EngineEventsApi { EngineEventMsg events(); }
// EngineEventMsg: kind enum + nullable payload fields (clock, previewState, jobProgress, jobDone, jobFailed,
// exportProgress, recorderLevel, recorderInterruption, memoryWarning, thermal, background).
// Sealed-class event payloads are used if pigeon 29 supports them for Swift+Kotlin [VERIFY in ENG-04].
```

**Rules:**
- Host handlers run on the platform main thread. They validate their arguments, post to an engine queue, and reply asynchronously. They never block on media work.
- Events are emitted on the main thread, which `FlutterEventSink` and `EventChannel` require.
- Rate limits are applied natively: clock ≤ 10 Hz while playing, job progress ≤ 4 Hz, export progress ≤ 4 Hz, recorder levels 20 Hz.
- Binary payloads are `Uint8List`. Android copies them once; iOS wraps them in `FlutterStandardTypedData`.
- Plans and patches are never sent as Pigeon object graphs. 2,000 items × ~60 fields would cost tens of ms of codec work on the UI isolate.

---

## 4. RenderPlan wire contract (Domain ↔ native)

### 4.1 Principles

1. The plan is **self-contained and resolved**:
   - All timings are integer µs.
   - Transition handles are already applied, so items in a lane may overlap only inside a transition window.
   - Speed ramps are already split into constant-speed segments.
   - Mute, solo, hidden lanes and locked state are resolved. Hidden lanes and silent items are omitted. Track gain stays a parameter.
2. Native validates invariants (`plan_validator` mirrors them). A violation is a `planInvalid` error with the item id. It is a bug, not a user error.
3. **Lanes are ordered top → bottom** (index 0 = topmost), which matches Media3. iOS reverses the list when it builds its CI stack.
4. Revisions are monotonic. A patch applies only when `fromRevision == current`. Otherwise native replies `planOutOfSync` and `plan_sync.dart` sends the full plan.

### 4.2 Schema v1 (sketch; `render_plan_v1.schema.json` is normative)

```jsonc
{ "schema": 1, "revision": 42, "target": "preview",              // or "export"
  "canvas": { "w": 1920, "h": 1080, "fps": 30, "background": "#000000FF" },
  "durationUs": 61000000,
  "media": [ { "id": "m1", "kind": "video", "uri": "file:///…", "bookmark": "base64|null", "fingerprint": "…",
               "durationUs": 120000000, "rotation": 90, "hasAudio": true, "hdr": false } ],
  "luts":    [ { "id": "l1", "path": "…/l1.vlut" } ],
  "sprites": [ { "id": "s9", "path": "…/s9.vsprite", "w": 812, "h": 160, "scale": 1.0, "hasReveal": true } ],
  "lanes": [                                                       // visual, top → bottom
    { "id": "T3", "kind": "sprite", "items": [ { "id": "c7", "sprite": "s9", "start": 1000000, "end": 3000000,
        "place": { "x": 0, "y": 0.38, "scale": 1, "rotation": 0, "opacity": 1 },
        "textAnim": { "in": "typewriter", "inUs": 800000, "out": "fade", "outUs": 300000, "dir": null } } ] },
    { "id": "T2", "kind": "video", "items": [ {
        "id": "v5", "media": "m2", "start": 2000000, "end": 8000000,
        "speed": [ { "srcStart": 0, "srcEnd": 3000000, "rate": 1.0 }, { "srcStart": 3000000, "srcEnd": 9000000, "rate": 2.0 } ],
        "fit": "fit", "crop": { "l": 0, "t": 0, "r": 1, "b": 1 },
        "place": { "x": 0.25, "y": -0.2, "scale": { "kf": [[0, 0.4], [2000000, 0.6]] }, "rotation": 0,
                   "flipX": false, "flipY": false, "opacity": 1 },
        "grade": { "exposure": 0, "brightness": 10, "contrast": 0, "highlights": 0, "shadows": 0,
                   "saturation": { "kf": [[0, 0], [1000000, -50]] }, "temperature": 0, "tint": 0 },
        "lut": { "id": "l1", "intensity": 0.8 },
        "chroma": { "key": "#00FF00", "similarity": 40, "smoothness": 10, "spill": 30 },
        "detail": { "blur": 0, "sharpen": 0, "vignette": 0 },
        "mask": { "shape": "circle", "cx": 0.5, "cy": 0.5, "w": 0.6, "h": 0.6, "rotation": 0, "radius": 0,
                  "feather": 20, "opacity": 100, "invert": false } } ] },
    { "id": "T1", "kind": "video", "items": [ /* main lane; overlapping only in transition windows */ ],
      "transitions": [ { "id": "x1", "kind": "crossDissolve", "from": "v1", "to": "v2",
                         "start": 9500000, "end": 10500000, "dir": null } ] } ],
  "audio": [ { "id": "A1", "gain": 1.0, "items": [ {
        "id": "a1", "media": "m1", "start": 0, "end": 10500000, "speed": [ … ], "keepPitch": true,
        "volume": { "kf": [[0, 1.0], [4000000, 0.3]] }, "fadeInUs": 500000, "fadeOutUs": 0 } ] } ] }
```

Field rules:
- An item's `source` is implicit: it is the union of the speed segments, or `{srcStart, srcEnd}` when the speed is 1×.
- Video items may instead carry `"image": "m7"` (a still) or `"solid": "#RRGGBBAA"`.
- **Reversed and freeze clips are ordinary video and image items** that point at generated assets.
- Audio of a video clip appears as a separate audio item, compiled by Domain from the clip with the same timing.
- Keyframe times are **item-local** µs from `start`.

### 4.3 Time and frame grid (shared vectors in `test_fixtures/vectors/frame_grid.json`)

```
frameIndexOf(tUs)  = floor(tUs * fps / 1_000_000)
timeOfFrame(k)     = ceil(k * 1_000_000 / fps)          // frameIndexOf(timeOfFrame(k)) == k for all k
iOS composition time of frame k  = CMTime(value: k, timescale: fps)               (exact rational)
Android seek of frame k          = ceil(timeOfFrame(k) / 1000) ms                 (inside frame k's interval)
speed segment timeline length    = round((srcEnd - srcStart) / rate); the last segment absorbs rounding so
                                   that Σ = end - start exactly.
```

- **Domain's `FrameRate.timeOfFrame`/`frameIndexOf` must produce the same values** [ASSUMPTION: Domain adopts these formulas; otherwise it supplies its own vectors, and natives mirror them].
- Export at a different fps than the project (for example 30 → 60) re-quantizes only the output frame times. Keyframes are evaluated at the true frame times.

### 4.4 Animatable values

- A value is a number or `{ "kf": [[tUs, v], …] }`, sorted with unique times.
- Evaluation at item-local `t`: before the first keyframe → first value; after the last → last value; otherwise linear: `v0 + (v1 - v0) * (t - t0) / (t1 - t0)` in double precision.
- Colors are not animatable in v1.
- `ParamSnapshot` precomputes per item a flat `FloatArray`/`[Float]` of static params plus small keyframe tables. Evaluation per frame is O(log k) per animated param.

### 4.5 Patches and classification

```jsonc
{ "fromRevision": 42, "toRevision": 43,
  "canvas": null, "durationUs": null,
  "upsertLanes": [ { "id": "T2", "kind": "video", "index": 1 } ], "removeLanes": [],
  "upsertItems": [ { "lane": "T2", "item": { … full item … } } ], "removeItems": [ "v9" ],
  "upsertAudio": [ … ], "removeAudio": [ … ], "media": [ … new entries … ], "sprites": [ … ], "luts": [ … ] }
```

Native classifies each patch:
- **Structural** if any of these change: lane set, lane order or kind; an item's `start`, `end`, `speed`, `media`, `image` or `keepPitch`; an item's lane; transitions; canvas size or fps; `durationUs`.
- **Param-only** otherwise: place, grade, lut, chroma, detail, mask, textAnim, volume, fades, track gain, sprite id swap, LUT id.

What each class costs:
- Param-only patches swap the `ParamSnapshot` atomically and redraw when paused.
- Structural patches rebuild the platform composition (§5.2, §6.2) and restore the playhead and play state.
- The ack reports `structural` and `applyMs`. These feed the debug overlay and the perf tests against the `ux.md` §22 budgets.

### 4.6 Transients

- `setTransient(item, paramsJson)` carries a partial item using the same keys as §4.2, restricted to the param-only set. Natives merge it over the snapshot (last write wins). Each patch is applied on the next composed frame. When paused, a redraw is coalesced to the next vsync.
- `clearTransient` drops the override.
- A committed plan or patch clears the overrides for every item it touches.

### 4.7 Sprites, LUTs, and the text rasterization contract

**`.vsprite` v1:**
- Header (little-endian): `'VSPR'`, u16 version=1, u16 flags (bit0 hasReveal), u32 w, u32 h, f32 scale.
- Then a zlib stream of `w·h·4` bytes of **premultiplied RGBA8, sRGB-encoded**.
- If `hasReveal`, a second zlib stream of `w·h·2` bytes holds the **glyph order** as u16 (0xFFFF = background).
- **Why not PNG:** no color-management differences between ImageIO and BitmapFactory, no PNG encode cost in Dart, and the native decoders are trivial (iOS libz `uncompress`, Android `Inflater`).

**Rasterizer (Dart, `text_sprite_rasterizer.dart`, UI isolate):**
- Input: the Domain `TextItem` or the subtitle track style plus cue text, and a target `scale` = (render canvas px ÷ canvas px) × max item scale reached by keyframes or animation, clamped to ≤ 2.
- Steps: `ParagraphBuilder` (bundled content fonts per `ux.md` Q4 plus system fallback) → background box, stroke (a second paragraph with `Paint..style=stroke`), shadow → `PictureRecorder` → `toImage` → `toByteData(rawRgba)` (premultiplied).
- The reveal map paints each glyph's box (`getBoxesForRange` per grapheme, logical order) with its index.
- zlib compression runs in `Isolate.run`.
- **The same `TextLayoutEngine` gives the UX its `TextMetricsProvider`**, so the handles match the pixels exactly.

**Scheduling (`sprite_scheduler.dart`):**
- **Preview:** rasterize the sprites for items intersecting `[playhead − 5 s, playhead + 30 s]`, nearest first, in ≤ 4 ms UI-thread slices using `SchedulerBinding.scheduleTask`. Push batches through `updateSprites`. A missing sprite simply isn't drawn (debug counter).
- **Export:** every sprite at export scale, before `start`.
- Sprite files are content-addressed `sha1(text, style, scale, fontsVersion)` under `cache/editor/sprites/`.
- On a quality change, sprites are re-rasterized lazily at the new scale.

**`.vlut` v1:** `'VLUT'`, u16 version, u16 N (2…65), then N³ RGB **float16**, red fastest. Written by `lut_normalizer.dart` from the Domain/Persistence `.cube` parser, with DOMAIN_MIN/MAX applied. Both natives upload it as a **2D tiled texture**: N tiles of N×N laid out in a ⌈√N⌉ grid, at most 585×520 for N = 65. This stays under every `GL_MAX_TEXTURE_SIZE` and needs no ES 3.0 3D textures.

### 4.8 Render math (normative; implemented in Metal CI, GLSL ES 1.00 and Dart reference)

**Per visual item, in order:**
1. sample source (video frame | image | sprite | solid)
2. crop
3. grade
4. LUT
5. chroma key + spill
6. blur → sharpen
7. vignette
8. mask
9. place (fit, transform, flip, opacity, transition, text animation)
10. composite **over**, bottom → top, onto the opaque canvas background

Sprites skip steps 2–8.

All math is on **straight-alpha, gamma-encoded RGB in [0,1]**. CI kernels unpremultiply on entry and premultiply on exit. `Y(c) = dot(c, (0.2126, 0.7152, 0.0722))`.

| Stage | Formula (UI units −100…100 unless noted) |
|---|---|
| Exposure | `c = pow(pow(c, 2.2) * exp2(exposure/50), 1/2.2)` (±2 EV) |
| Brightness, Contrast | `c += brightness/400`; `c = (c − 0.5)·(1 + contrast/100) + 0.5` |
| Highlights, Shadows | `c += highlights/400 · smoothstep(0.5, 1, Y)`; `c += shadows/400 · (1 − smoothstep(0, 0.5, Y))` |
| Saturation | `c = mix(vec3(Y), c, 1 + saturation/100)` |
| Temperature, Tint | `c.r *= 1 + temperature/1000; c.b *= 1 − temperature/1000; c.g *= 1 − tint/1000`; then `clamp(c, 0, 1)` |
| LUT | trilinear lookup in N³ (tiled), `c = mix(c, lut(c), intensity)` |
| Chroma key | `Cb = (B−Y)/1.8556, Cr = (R−Y)/1.5748`; `d = ‖(Cb,Cr) − key‖`; `a = smoothstep(s0, s0+s1, d)`, `s0 = similarity/100·0.25`, `s1 = max(0.001, smoothness/100·0.25)`. Spill: `k = normalize(key)`, `(Cb,Cr) −= k·max(0, dot((Cb,Cr),k))·spill/100`; rebuild RGB with Y kept. `alpha *= a` |
| Blur | Gaussian, `σ_canvas = blur/100 · 0.03 · min(W,H)` px; `σ_src = σ_canvas / scaleToCanvas`; radius `ceil(3σ)`, separable, clamp-to-edge; `σ < 0.5` → skip |
| Sharpen | `c += sharpen/100 · 1.5 · (c − box3x3(c))`, clamp |
| Vignette | `d = ‖(uv − .5)·(aspect,1)‖ / ‖(aspect,1)·.5‖`; `c *= 1 − vignette/100 · smoothstep(0.35, 1, d)` |
| Mask | SDF in item-normalized space (rotated rounded box or ellipse). `f = feather/100 · 0.25 · min(w,h)`; `a = 1 − smoothstep(−f, f, sd)` (step when f = 0); invert → `1 − a`; `alpha *= mix(1, a, opacity/100)` |
| Place | `s0` = fit (min) / fill (max) / stretch (per axis) of the crop size `(cw,ch)` into `(W,H)`. `M = T(W/2 + x·W, H/2 + y·H) · R(rotation° clockwise, y-down) · S(scale·s0x·fx, scale·s0y·fy) · T(−cw/2, −ch/2)` with `fx = flipX ? −1 : 1`. `alpha *= opacity`. **Domain `boxAt` uses the same M.** |
| Transitions | `p = clamp((t − start)/(end − start))`; B (incoming) is drawn above A. **crossDissolve:** `αB *= p`. **fade:** `αA *= 1 − min(1, 2p)`, `αB *= max(0, 2p − 1)`. **dipBlack/White:** p < .5: A `c = mix(c, K, 2p)`, B hidden; p ≥ .5: B `c = mix(c, K, 2 − 2p)`, A hidden. **slide (push) dir u:** `offB = (1−p)·(−u)⊙(W,H)`, `offA = p·u⊙(W,H)`. **wipe dir u:** `g` = canvas coordinate along u in [0,1]; `p' = p·1.02 − 0.01`; `αB *= 1 − smoothstep(p'−0.01, p'+0.01, g)`. **zoom in:** A `scale *= 1 + 0.5p`, `αA *= 1 − p`; B `scale *= 1.5 − 0.5p`, `αB *= p` (zoom out mirrors the scales) |
| Text animations | `pin = clamp((t − start)/inUs)`, `pout = clamp((end − t)/outUs)`, `e(x) = 1 − (1−x)³`. **fade:** `α *= e`. **slide dir u:** `off = (1 − e)·0.1·min(W,H)·(−u)`. **scale:** `scale *= 0.6 + 0.4e`. **typewriter (in):** draw a pixel iff `glyph < floor(pin·count)` (reveal map). In and out multiply |
| Audio gain | `g = volume(t) [0…2] · clamp((t−start)/fadeIn) · clamp((end−t)/fadeOut) · laneGain`. Mix = Σ, hard-clipped to [−1, 1] at output (no limiter in v1). keepPitch: time-stretch; else resample |

**Editing modes:**
- `cropSource(item)`: renders only that item's uncropped, untransformed source, fitted to the canvas, with all looks applied.
- `matte(item)`: renders that item's alpha after step 8 as gray. Other items are hidden.

**Parity tolerance against the Dart reference:**
- Mean absolute error ≤ 1.5/255 per channel.
- 99th percentile ≤ 6/255.
- SSIM ≥ 0.98 on transform fixtures, with edge pixels excluded (antialiasing differs).

---

## 5. iOS engine (AVFoundation + Core Image/Metal)

### 5.1 Availability

- The runtime gate is iOS ≥ 15.0 with a Metal device. Every editor type is `@available(iOS 15.0, *)`. On older versions the plugin answers `capabilities()` with `supported=false, unsupportedReason='ios_too_old'`.
- iOS 26-only paths (`BGContinuedProcessingTask`) are behind `#available(iOS 26, *)`. BackgroundTasks is weak-linked.

### 5.2 Composition mapping (`CompositionBuilder`, on `previewControlQueue`)

1. **Assets.**
   - `AssetCache` keeps one `AVURLAsset(url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])` per media.
   - Tracks are preloaded with `loadTracks(withMediaType:)`. `preferredTransform`, `naturalSize` and `nominalFrameRate` are loaded once.
   - Bookmarked media are resolved and `startAccessingSecurityScopedResource()` is refcounted per session.
   - When a session uses proxies, video tracks come from `ProxyRegistry[fingerprint]`. Proxies keep the source timestamps 1:1 (§5.6).
2. **Video lanes → composition tracks.**
   - `TrackAllocator` interval-colors each lane's items, so overlapping transition windows get A/B tracks. Composition tracks are reused across lanes by z-order slot.
   - For each item and each speed segment: `insertTimeRange(segSrc, of: srcTrack, at: cursor)`, then `scaleTimeRange(CMTimeRange(cursor, segSrc.duration), toDuration: segTimelineDur)`.
   - Images, sprites and solids are **not** composition tracks. They are compositor layers.
3. **Spacer track.** A bundled 16×16 one-second black video (`spacer_16x16.mov`) is inserted and scaled across `[0, durationUs)`. It guarantees a compositor request for every output frame, including gaps and stills-only regions. It is never drawn.
4. **Instructions.** `InstructionBuilder` splits the timeline at every item, transition and sprite boundary. Each segment gets a `DVInstruction: NSObject, AVVideoCompositionInstructionProtocol` with:
   - `timeRange`, `enablePostProcessing=false`, `containsTweening=true`,
   - `requiredSourceTrackIDs` = the active video tracks,
   - `layers: [LayerRef]` bottom → top: `(itemId, kind, trackID?, transitionRole?)`.
   It is checked with `AVVideoComposition.isValid(for:timeRange:validationDelegate:)` in debug builds.
5. **Video composition.** `AVMutableVideoComposition()` with:
   - `customVideoCompositorClass = DVCompositor.self`,
   - `frameDuration = CMTime(1, fps)`, `renderSize` = preview or export size,
   - `colorPrimaries/transferFunction/yCbCrMatrix = ITU_R_709_2` (SDR; HDR sources are converted before compositing [VERIFIED header semantics]),
   - `sourceTrackIDForFrameTiming = kCMPersistentTrackID_Invalid`.
6. **Audio.**
   - Per audio lane, interval coloring × `keepPitch` yields composition audio tracks, with the same insert/scale procedure as video.
   - `AudioMixBuilder` produces `AVMutableAudioMixInputParameters` per track with `audioTimePitchAlgorithm = .spectral` (keep pitch) or `.varispeed`.
   - Volume is set through `setVolumeRamp(fromStartVolume:toEndVolume:timeRange:)`. The §4.8 gain (keyframes × fades × lane gain) is sampled into linear ramps at every keyframe and every 20 ms inside fades. Fade × keyframe products are not linear, so the error is ≤ 0.1 dB.
   - Param-only gain changes rebuild only the `AVAudioMix` and assign it to `playerItem.audioMix` (no item swap).
7. **Reverse and freeze** clips reference generated assets (§5.6), so the builder treats them as ordinary media.

Cost target: ≤ 150 ms to build a 2,000-item composition on mid tier with a warm `AssetCache` (measured in IOS-08).

### 5.3 Compositor (`DVCompositor: NSObject, AVVideoCompositing`)

- **Pixel formats:**
  - `sourcePixelBufferAttributes = [PixelFormat: [32BGRA], IOSurface: [:], MetalCompatibility: true]`. VideoToolbox does the YUV→RGB conversion with the right matrix, so CI sees plain BGRA.
  - `requiredPixelBufferAttributesForRenderContext` = BGRA.
  - `supportsHDRSourceFrames = false` and `supportsWideColorSourceFrames = false`, so sources arrive as BT.709 SDR.
- **Context.** One `CIContext(mtlDevice:, options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull(), .cacheIntermediates: false, .name: "danaview.compose"])` per compositor instance. With color management off, the kernels see gamma-encoded values, which is the parity rule (§0.7).
- **Kernels.**
  - `DanaviewKernels.metal` is compiled by Xcode with `-fcikernel` into the pod's `default.metallib` and loaded with `CIKernel(functionName:fromMetalLibraryData:)` once per process.
  - Kernels: `dv_look` (color kernel: grade + LUT tiled sampler + chroma + spill), `dv_blur_h/dv_blur_v` (sampler kernels), `dv_sharpen`, `dv_vignette_mask` (vignette + mask SDF + alpha), `dv_transition` (dip, wipe alpha), `dv_reveal` (typewriter), `dv_matte`.
  - Transforms use `CIImage.transformed(by:)` with the §4.8 matrix, converted to CI's y-up space by a fixed flip.
  - Compositing uses `CISourceOverCompositing`, which is premultiplied and mathematically equal to the GL straight-alpha "over" on an opaque base.
- **`startRequest`** dispatches to `renderQueue` (serial; `.userInteractive` for preview, `.userInitiated` for export):
  - Read `ParamSnapshot` (an atomic pointer swap, never locked during a render).
  - Map `request.compositionTime` to the frame index and µs.
  - Build the CI graph for `instruction.layers`.
  - Render into a buffer from `request.renderContext.newPixelBuffer()`.
  - Attach `danaview.frame` = frame index (`CVBufferSetAttachment`).
  - Call `finish(withComposedVideoFrame:)`.
  - Errors call `finish(with:)`, and the preview reports `failed`.
- **Redraw-from-cache.**
  - The compositor retains the last request's source buffers (≤ `maxConcurrentVideoLayers`) and its composition time.
  - `redraw()` re-renders those sources with the current snapshot into its own `CVPixelBufferPool` and hands the buffer to `TextureBridge` directly.
  - This is the paused path for param patches, transients, editing modes and look stills. It has the same code path as playback rendering, so results are identical.
- **Cancellation.** `cancelAllPendingVideoCompositionRequests` bumps a generation counter. Queued requests with an old generation finish with `finishCancelledRequest()`.
- **Image and sprite layers.**
  - `ImageLayerCache` decodes with ImageIO `CGImageSourceCreateThumbnailAtIndex` at ≤ the needed size (canvas px × scale × render quality). It uses an LRU by bytes.
  - `SpriteStore` inflates `.vsprite` into a `CIImage(bitmapData:…, format: .RGBA8, colorSpace: nil)` (premultiplied, no color management).
  - `LutStore` turns a `.vlut` into a tiled `CIImage` in `RGBAh` format.

### 5.4 Preview session

- **Player.**
  - One `AVPlayer` with `automaticallyWaitsToMinimizeStalling = false` and `actionAtItemEnd = .pause`.
  - The `AVPlayerItem` uses `seekingWaitsForVideoCompositionRendering = true` and `preferredForwardBufferDuration = 2 s` (1 s on low tier).
  - A structural rebuild creates a new item, `replaceCurrentItem`, then seeks exactly to the current frame and restores the play state. The old texture frame stays on screen until the first new frame arrives, so there is no black flash.
- **TextureBridge.**
  - `AVPlayerItemVideoOutput(pixelBufferAttributes: BGRA + IOSurface + Metal)`.
  - A `DisplayLinkDriver` on the main run loop uses `preferredFrameRateRange` matched to the project fps. On each tick it checks `hasNewPixelBuffer(forItemTime: output.itemTime(forHostTime: CACurrentMediaTime()))`, copies the buffer, stores it as `latest`, and calls `textureFrameAvailable`.
  - `copyPixelBuffer()` returns `latest`, retained (zero-copy into Impeller via the Flutter engine's `CVMetalTextureCache`).
  - The display link is paused when the player is paused and no redraw is pending.
- **Clock.**
  - `addPeriodicTimeObserver(1/10 s)` plus KVO on `timeControlStatus` emit `PreviewClock(time, playing, rate, seq)`.
  - On a stall: `events.stalled`, then `recovered`.
- **Seek (`SeekController`).**
  - **exact:** `seek(to: CMTime(k, fps), toleranceBefore: .zero, toleranceAfter: .zero)`. On completion, wait for the output buffer whose `danaview.frame == k`, with a 500 ms timeout, then send the ack with `displayedFrame`.
  - **scrub:** tolerance `±0.5 s` while the drag velocity is high, otherwise zero. A newer scrub supersedes a pending one: the controller keeps one seek in flight, the same chase pattern as the UX.
- **Quality.**
  - Render size = canvas × {1, ½, ¼}, with the long side capped at `maxPreviewLongSide`. Changing it rebuilds only the video composition (`renderSize`), assigned to the item without a reload.
  - `QualityGovernor` (auto) counts missed display-link frames while playing. It steps down after > 10% over 2 s, steps up after 10 s clean, and emits `degraded(q)` or `recovered`.
  - Thermal `.serious` forces ≤ half.
- **Look stills, color sampling, source frames.**
  - `renderLookStills` and `sampleColor` use `SourceFrameCache`: an exact `AVAssetImageGenerator` frame of the item's media at its current source time, cached per (media, time) for the session.
  - Stills render through `LayerRenderer` with an override `ParamSnapshot`.
  - `sampleColor` reads a 3×3 average from the **pre-key** source.
  - `showSourceFrame` draws a generator frame fitted to the canvas into the bridge until the next seek or play.
- **Lifecycle.**
  - `willResignActive`: pause and stop the display link.
  - Background: release `CIContext` intermediates and keep the item.
  - `didBecomeActive`: `refresh()` re-renders the current frame.
  - `didReceiveMemoryWarning`: trim the image, sprite and source-frame caches to 25% and emit `signals.memoryWarning`.
- **Audio session.**
  - On play: `.playback`, mode `.moviePlayback`.
  - The recorder switches to `.playAndRecord` (§5.7).
  - The previous category is restored on dispose. The player's media_kit session is paused by the UX handoff (`ux.md` §4.6) [VERIFY media_kit doesn't reassert its category while paused].

### 5.5 Export

- **Pipeline (`ReaderWriterPipeline`).**
  - `AVAssetReader(asset: composition)` with:
    - `AVAssetReaderVideoCompositionOutput(videoTracks: all, videoSettings: BGRA)`, with `.videoComposition` = an export variant (renderSize = output size, frameDuration = 1/exportFps), and
    - `AVAssetReaderAudioMixOutput(audioTracks: all, audioSettings: LPCM Float32 48 kHz stereo)`, with `.audioMix` and `audioTimePitchAlgorithm = .spectral`; per-track overrides come from the mix.
  - `AVAssetWriter(url:, fileType: .mp4 | .mov)` with `shouldOptimizeForNetworkUse = true`.
  - Video input:
    - `AVVideoCodecKey: .h264 | .hevc`, width and height,
    - `AVVideoCompressionPropertiesKey: [AverageBitRate, ProfileLevel (H264HighAutoLevel | HEVC Main AutoLevel), ExpectedSourceFrameRate, MaxKeyFrameIntervalDuration, AllowFrameReordering: true]`,
    - `AVVideoColorPropertiesKey` BT.709.
    - HEVC is written as `hvc1` (AVFoundation default).
  - Audio input: AAC-LC 48 kHz stereo, `AVEncoderBitRateKey`.
  - Each output has a pump on its own serial queue, driven by `requestMediaDataWhenReady`. Progress = last appended video PTS ÷ duration, sent at 4 Hz.
- **Cancel:** `reader.cancelReading()`, `writer.cancelWriting()`, delete the file, resolve as `cancelled`.
- **Hardware.**
  - VideoToolbox picks the hardware encoder. `Capabilities` probes HEVC and H.264 by creating a `VTCompressionSession` with `kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder` at the target size.
  - If HEVC hardware is missing, the HEVC option is hidden. If H.264 hardware is missing (simulator), the export uses software and `ExportResult.hardwareEncoder = false`.
- **Background (`BackgroundExecution`).**
  - On iOS 26+, at `start` we submit `BGContinuedProcessingTaskRequest(identifier: "com.vecvel.danaview.export.<jobId>", title: "Exporting video", subtitle: <project>)` with `strategy = .fail`.
    - Add `requiredResources = .gpu` when `BGTaskScheduler.supportedResources.contains(.gpu)` and the app has the GPU entitlement.
    - The launch handler adopts the running job, mirrors progress into `task.progress`, and calls `setTaskCompleted`.
    - The expiration handler cancels with `interrupted`.
    - The identifier pattern is registered at launch in the plugin's `register(with:)`, which requires `BGTaskSchedulerPermittedIdentifiers = ["com.vecvel.danaview.export.*"]` in Info.plist [VERIFIED API; wildcard registration ordering is VERIFY].
  - With no GPU resource on iOS 26, the compositor switches to a software `CIContext` (`.useSoftwareRenderer: true`) while backgrounded. It is slower but keeps going.
  - On iOS 15–25, or when submission fails: on `didEnterBackground` the pipeline **pauses**. The compositor's `startRequest` waits on a foreground gate, and the pumps stop pulling. A `beginBackgroundTask` lets the in-flight frame finish cleanly. Progress events report `pausedInBackground = true`. The pipeline resumes on `didBecomeActive`. If the system kills the app, the next launch reports `interrupted` once from `ActiveExportStore`.
- **Thermal:** `.critical` pauses the pumps until the state is ≤ `.serious` (event `thermal`).
- **Destinations (`FileHandoff`):**
  - Photos: `PHPhotoLibrary.requestAuthorization(for: .addOnly)`, then `PHAssetCreationRequest.addResource(with: .video, fileURL:, options: shouldMoveFile=true)`.
  - Files: `UIDocumentPickerViewController(forExporting: [url], asCopy: true)`.
  - Share: `UIActivityViewController`.

### 5.6 Media services

| Service | Implementation |
|---|---|
| Probe / compatibility | `AVURLAsset` + `load(.duration, .isPlayable, .isComposable, .hasProtectedContent)`, track `formatDescriptions` (codec, bit depth, transfer function → `hdr`), `preferredTransform` → rotation. Compatibility first runs the Dart `MediaInspector` container sniff (MKV/WebM/AVI → `NotEditable('container_unsupported_ios')`). It then answers within the 300 ms budget, with a 250 ms timeout on loading |
| Thumbnails | `ThumbnailService`: one `AVAssetImageGenerator` per (media, proxy). `appliesPreferredTrackTransform = true`, `maximumSize = (h·aspect, h)`, tolerance ±interval/2, `dynamicRangePolicy = .forceSDR` on iOS 18+. `generateCGImagesAsynchronously(forTimes:)` produces the N frames of one tile; frames are drawn into a strip `CGContext` and encoded with ImageIO JPEG at q 0.7. Disk cache key `sha1(fingerprint, intervalMs, heightPx, tile, proxy)`. Concurrency is 1 generator (low tier) or 2. `cancel` calls `cancelAllCGImageGeneration` on that generator after its batch |
| PCM reader (shared) | `PcmReader`: `AVAssetReader` + `AVAssetReaderTrackOutput` (LPCM Float32 interleaved, native rate and layout), `timeRange` set. Used by waveforms, speech audio and reverse audio |
| Waveforms | Bins of `sampleRate/200` frames → per-bin min/max of the channel-mixed signal → int8. File `cache/editor/waves/<fp>-<stream>.dvpk` (header + pairs). Results are progressive inside the job, but the Future resolves at the end. Speed is ≥ 20× realtime on low tier |
| Speech audio | Exactly `ai.md` §7.2: downmix matrix, `AVAudioConverter` → 16 kHz s16 mono, streamed WAV with patched header, sample-accurate trim against `range.start` |
| Proxies | `ProxyJob`: reader → writer at **short side 540** (long side ≤ 960), H.264 High, 3 Mbps, `MaxKeyFrameInterval = 10` frames, SDR, AAC 128 kbps. **Same PTS for every frame** (VFR is preserved). Written to `cache/editor/proxies/<fp>.mp4.part` and renamed on success. Policy comes from the UX setting: Auto proxies media with long side > 1920, fps > 60, HDR, 10-bit, or bitrate > 40 Mbps |
| Freeze frame | `AVAssetImageGenerator` with tolerances zero at the source time, full natural size, transform applied → PNG (ImageIO) at `outputPath` |
| Reverse | (1) Transcode the source range to an **all-intra** H.264 intermediate (`MaxKeyFrameInterval = 1`, `AllowFrameReordering = false`, about 0.25 bpp, source size ≤ 4K) in `work/`, with audio decoded to a WAV. (2) Read the intermediate's compressed samples in passthrough into an indexed temp file. (3) Feed them **in reverse order** to a `VTDecompressionSession`; each output frame goes to an `AVAssetWriterInputPixelBufferAdaptor` with mirrored PTS (`rangeEnd − pts − frameDur`). (4) Read the WAV backward in 64k-frame blocks, reverse the samples, and encode AAC. Memory stays at about 2 frames regardless of resolution. Progress is weighted 45/45/10 |
| Color sampling / look stills | See §5.4 |

### 5.7 Recording

- **Engine:** `AVAudioEngine`. An input-node tap writes to an `AVAudioFile` (WAV, PCM s16, 48 kHz mono at `outputPath`) and computes RMS → `levels` at 20 Hz.
- **Session:** `.playAndRecord`, `.defaultToSpeaker`, plus Bluetooth HFP allowed.
- **Latency:** `startLatencyUs = inputLatency + ioBufferDuration` at start.
- **Interruptions:** `interruptionNotification` and route changes, including headphones unplugged, stop the recording and keep the file → `interruptions` event.
- **Playback while recording:** the preview plays with `player.isMuted = true` when "Play project while recording" is on.
- **Permission:** `AVAudioApplication.requestRecordPermission` on iOS 17+, the `AVAudioSession` API on 15–16.

### 5.8 Threading and memory (iOS)

| Thread / queue | Work |
|---|---|
| Main | Pigeon handlers, texture register/unregister, `CADisplayLink`, AVPlayer control and KVO, event emission, pickers |
| `previewControlQueue` (serial, userInitiated) | Plan decode and diff, composition build, `ParamSnapshot` build |
| `renderQueue` (serial, userInteractive) per compositor | CI graph build and render |
| `jobQueue` (OperationQueue; max 1 low / 2 mid-high; utility) | Thumbnails, waveforms, proxies, reverse, freeze, speech audio. Export and interactive jobs pre-empt background jobs |
| `export.{control,video,audio}` (serial, userInitiated) | Reader/writer pumps |
| AVAudioEngine render thread | Recorder tap (no allocation; ring buffer → file writer queue) |

Memory budgets are in §8.2. Pools are sized by tier: output `CVPixelBufferPool` minimum 3 (preview) or 6 (export).

---

## 6. Android engine (Media3 1.11.1)

### 6.1 Availability and build

- **Runtime gate:** API ≥ 29 and an EGL context with GLES 3.0. Our shaders are GLSL ES 1.00, but Media3's HDR tone-mapping path needs ES 3 [VERIFY on API-29 low-tier hardware]. Otherwise `supported=false`.
- The plugin's `minSdk = 24` matches the app. All engine entry points check `Build.VERSION.SDK_INT >= 29` and fail cleanly.
- **ABI:** pure Kotlin/JVM plus GLSL, with no native libs. 16 KB page alignment is not an issue.

### 6.2 Composition mapping (`CompositionMapper`, on the preview thread)

**Sequence stack (index 0 = top = primary clock):**

| Index | Sequence | Contents |
|---|---|---|
| 0 | **Top sprite band + clock** | One transparent 2×2 PNG placeholder image item, `setDurationUs(durationUs)`, `setFrameRate(fps)`. Effects: `[SpriteBandEffect(band 0)]`. It always exists, so the output frames are exactly the project-fps grid |
| 1…n | Visual lanes, top → bottom | Video/image lanes become 1–2 sequences each (A/B by interval coloring, B above A). A **contiguous run of sprite lanes** between video lanes becomes one band sequence (placeholder + `SpriteBandEffect`) |
| n+1 | Background | One solid image item (canvas color), full duration |
| n+2… | Audio | Audio-only sequences: one per audio lane color, `EditedMediaItemSequence.Builder(setOf(TRACK_TYPE_AUDIO))` |

**Video items:**

```kotlin
EditedMediaItem.Builder(MediaItem.Builder().setUri(uriOrProxy)
      .setClippingConfiguration(ClippingConfiguration.Builder()
          .setStartPositionUs(srcStart).setEndPositionUs(srcEnd).build()).build())
  .setRemoveAudio(true)                                   // audio lives in audio sequences
  .setSpeed(SpeedParameters(SegmentSpeedProvider(item.speed), /*maintainPitch*/ true))  // video: pitch n/a
  .setEffects(Effects(emptyList(), listOf(LayerLookEffect(id), /*blur?*/ SeparableBlurEffect(id),
                                          LayerPlaceEffect(id))))
  .build()
```

- **Gaps:** each lane is padded with `addGap(us)` so that every sequence lasts exactly `durationUs`. A sequence whose first item is a gap sets `experimentalSetForceVideoTrack(true)`.
- **Gap gating:** gaps render opaque black [VERIFIED], so `LayerGatingCompositorSettings.getOverlaySettings(inputId, ptsUs)` returns `alphaScale = 0` when `ptsUs` is outside every item of sequence `inputId`. Otherwise it returns identity settings.
- `getOutputSize` returns the render size.
- **Images:** `MediaItem` from file URI with `setDurationUs` + `setFrameRate(fps)` (image decoder path).
- **Audio items:** the same clipping. `setRemoveVideo(true)`. `setSpeed(SpeedParameters(provider, keepPitch))`. Effects: `Effects(listOf(GainProcessor(KeyframedGainProvider(id))), emptyList())`.
  - `KeyframedGainProvider` computes the exact §4.8 envelope per sample from the `ParamSnapshot`, so it is live for param-only changes.
  - `isUnityUntil` returns spans of unity gain so Media3 can skip work.
- **Composition-level:**
  - `Composition.Builder(sequences).setVideoCompositorSettings(gating).setHdrMode(HDR_MODE_TONE_MAP_HDR_TO_SDR_USING_OPEN_GL)`.
  - `setEffects(Effects(listOf(SonicAudioProcessor(48 kHz), ChannelMixingAudioProcessor(→ stereo)), emptyList()))` so the output audio format is fixed.
  - `experimentalSetForceAudioTrack(true)`, so a project with no audio still gets a silent track.
- **Placement in canvas space.**
  - Every visual sequence's last effect, `LayerPlaceEffect` or `SpriteBandEffect`, outputs a **canvas-render-size RGBA texture** with straight alpha.
  - `DefaultVideoCompositor` then only blends layers with its verified straight-alpha function, top index last. Our layers are drawn over the opaque background sequence, so the result equals the §4.8 "over".
- **Rate conform.** The compositor picks secondary frames by **nearest** timestamp; iOS uses floor (§13 R6). This only affects sources whose fps differs from the project's. It is deterministic per platform and identical between preview and export.

**Live updates:**
- Param-only patches and transients swap `ParamSnapshot` (an `AtomicReference`) that every effect reads in `drawFrame(…, ptsUs)`. When paused we call `player.experimentalRedrawLastFrame()`, which needs `experimentalSetEnableReplayableCache(true)` [VERIFY redraw re-invokes custom `GlEffect.drawFrame` with the same pts].
- Structural patches rebuild the `Composition` and call `setComposition(c, currentPositionMs)`, then restore the play state. Item ids are stable, so effect instances fetch the new params by id.

### 6.3 GL effects (`effects/`, run on the Media3 GL thread)

| Effect | Program | Notes |
|---|---|---|
| `LayerLookEffect(itemId)` | `BaseGlShaderProgram`. `configure(w,h)` returns `min(source, needed)`, where needed = render size ÷ item scale, so 4K sources are downscaled first | Fragment `dv_look.glsl`: crop via texcoords, grade, LUT (tiled `sampler2D`), chroma + spill. Uniforms come from `ParamSnapshot` at `ptsUs`. Editing mode `matte` sets a flag |
| `SeparableBlurEffect(itemId)` | Two passes: H then V | Inserted only when the item has blur > 0 at any time. The radius is updated per frame. The `isNoOp` path is not usable for keyframed blur |
| `LayerPlaceEffect(itemId, lane)` | `configure` returns the **canvas render size** | `dv_place.glsl`: sharpen (3×3), vignette, mask SDF, full §4.8 M as a 3×3 matrix (inverse-mapped per fragment), opacity, transition role (A/B: alpha, dip color, wipe, offsets/scales), straight-alpha output. Edges are antialiased with 1 px coverage |
| `SpriteBandEffect(bandIndex)` | Draws N sprite quads onto a transparent canvas-size target | For each sprite item active at pts (sorted bottom → top): textured quad with M, text animation, reveal map (two 8-bit channels → u16). Textures come from `SpriteTextures` (LRU by bytes; inflated on a background executor, uploaded lazily on the GL thread) |

**Timestamps.** Effect pts are composition time [VERIFY that per-item effects in a multi-item sequence see sequence-cumulative pts in both CompositionPlayer and Transformer]. If they turn out to be item-relative, `ParamSnapshot` lookup uses `(sequence, pts)` → item through the item's known sequence start instead. Spike AND-01 decides this.

**Rotation.** Media3 upright-rotates decoded frames before the effects [VERIFY]. If it doesn't, `LayerLook` applies `probe.rotation`.

### 6.4 Preview session

- **Player:**

```kotlin
CompositionPlayer.Builder(ctx).setLooper(previewThread.looper)
  .setVideoGraphFactory(MultipleInputVideoGraph.Factory(
      DefaultVideoFrameProcessor.Factory.Builder()
        .setSdrWorkingColorSpace(DefaultVideoFrameProcessor.WORKING_COLOR_SPACE_ORIGINAL)
        .setEnableReplayableCache(true).build()))
  .experimentalSetEnableReplayableCache(true)
  .setGlThreadExecutorService(glExecutor)
  .setAudioAttributes(AudioAttributes.DEFAULT /* movie */, /* handleAudioFocus */ true)
  .build()
```

- **Surface:** `TextureRegistry.createSurfaceProducer(SurfaceLifecycle.resetInBackground)`, then `setSize(renderW, renderH)` and `player.setVideoSurface(producer.surface, Size(renderW, renderH))`.
  - `onSurfaceCleanup` (main thread): post `clearVideoSurface` to the preview thread and **block ≤ 500 ms** on a latch so the surface is released before returning. The preview thread never waits on main, so this cannot deadlock.
  - `onSurfaceAvailable`: set the new surface, `experimentalRedrawLastFrame()`, then emit `recovered`.
- **Clock:** the preview thread polls `currentPosition` at 10 Hz while playing. `onIsPlayingChanged`, seeks and errors emit immediately.
- **Seek:**
  - **exact:** `seekTo(ceilMs(timeOfFrame(k)))`. `VideoFrameMetadataListener.onVideoFrameAboutToBeRendered(ptsUs, …)` gives the displayed frame. The ack is sent on the first frame whose `frameIndexOf(pts) == k`, or on a 500 ms timeout with the actual frame.
  - **scrub:** `setScrubbingModeEnabled(true)` during the drag and `false` before the final exact seek. One seek is in flight at a time.
- **Quality:** a change calls `producer.setSize` and `setVideoSurface` with the new `Size`, then rebuilds the composition (the output size changes). The governor uses `AnalyticsListener.onDroppedVideoFrames`, with thresholds as on iOS. The thermal listener (`PowerManager.addThermalStatusListener`) at `THERMAL_STATUS_SEVERE` forces ≤ half.
- **Look stills, sampling, source frames:**
  - `SourceFrameCache` uses `FrameExtractor` (`media3-inspector-frame`) with `SeekParameters.EXACT` at the item's source time.
  - Stills run `FrameExtractor.Builder(...).setEffects(listOf(LayerLookEffect(override)))`.
  - Sampling averages 3×3 pixels from the cached bitmap.
  - `showSourceFrame` draws the bitmap through a tiny GL blit into the same surface, using an `EGLSurface` on the producer surface while the player's surface is detached [VERIFY]. The fallback is a Dart overlay image.
- **Lifecycle:**
  - `onTrimMemory` (`TRIM_MEMORY_UI_HIDDEN` and above) trims the sprite, LUT and source-frame caches.
  - `ActivityAware.onDetachedFromActivity` keeps the session. It is released in `dispose`.

### 6.5 Export

- **`ExportCoordinator`** is a process singleton that owns one `Transformer` per job on the `danaview-export` HandlerThread looper. It survives activity recreation and engine detach.
- **Transformer:**

```kotlin
Transformer.Builder(appCtx).setLooper(exportThread.looper)
  .setVideoMimeType(if (hevc) MimeTypes.VIDEO_H265 else MimeTypes.VIDEO_H264)
  .setAudioMimeType(MimeTypes.AUDIO_AAC)
  .setEncoderFactory(DefaultEncoderFactory.Builder(appCtx)
      .setVideoEncoderSelector(HardwareEncoderSelector)                 // HW first (isHardwareAccelerated, API 29)
      .setRequestedVideoEncoderSettings(VideoEncoderSettings.Builder().setBitrate(vbr)
          .setiFrameIntervalSeconds(keyframeSec.toFloat()).build())
      .setRequestedAudioEncoderSettings(AudioEncoderSettings.Builder().setBitrate(abr).build())
      .setEnableFallback(true).build())
  .setMuxerFactory(InAppMp4Muxer.Factory().setAttemptStreamableOutputEnabled(true))
  .setVideoFrameProcessorFactory(/* same ORIGINAL working space factory */)
  .setPortraitEncodingEnabled(true).addListener(listener).build()
  .start(exportComposition, outputPath)
```

- **The export composition** is built by the same `CompositionMapper` with `target=export`: the export render size, the clock at the export fps, original media, and sprites at export scale.
- **Progress:** `getProgress(holder)` every 250 ms → `ExportProgress`. `ExportResult.videoEncoderName` is checked against `MediaCodecInfo.isHardwareAccelerated` to set `hardwareEncoder`.
- **Cancel:** `transformer.cancel()`, delete the partial file, resolve as cancelled.
- **Errors:** `ExportException.errorCode` maps to `EngineErrorCode`:

  | Media3 code(s) | Engine code |
  |---|---|
  | `ENCODER_INIT_FAILED`, `ENCODING_FORMAT_UNSUPPORTED` | `encoderUnavailable`, or `encoderSizeLimit` when the size exceeds `VideoCapabilities` |
  | `IO_FILE_NOT_FOUND` | `mediaOffline` |
  | `IO_NO_PERMISSION` | `permissionDenied` |
  | `DECODING_*` | `decodeFailed` |
  | `MUXING_*` with ENOSPC | `diskFull` |

- **Fallback:** `onFallbackApplied` (for example, the resolution was lowered by the encoder) becomes an `ExportProgress` warning.
- **Background (`ExportService`, foreground service):**
  - Started in `start()` while the app is in the foreground.
  - `startForeground(id, notification, type)` with type `FOREGROUND_SERVICE_TYPE_MEDIA_PROCESSING` on API 35+ and `FOREGROUND_SERVICE_TYPE_DATA_SYNC` on API 29–34.
  - The manifest declares `android:foregroundServiceType="mediaProcessing|dataSync"` and the permissions `FOREGROUND_SERVICE_MEDIA_PROCESSING` and `FOREGROUND_SERVICE_DATA_SYNC`.
  - The notification shows determinate progress (≤ 1 Hz) and a **Cancel** action (`PendingIntent` → service → coordinator).
  - API 35 `onTimeout(startId, type)` cancels with `interrupted`.
  - The same service hosts `BackgroundWorkGuard` leases for captions (`ai.md` §6.3). It stays up while any lease or export is active.
  - `POST_NOTIFICATIONS` is requested in context by the UX flow through `PlatformHostApi`. Without it the export still runs; the notification just isn't shown in the shade.
- **Reattach:** `activeJobs()` returns live jobs. If the process died during an export, `ActiveExportStore` (a JSON file written at start) yields one `interrupted` record on the next launch, and the partial output is deleted.
- **Destinations:**
  - Gallery: `MediaStore.Video.Media` insert with `RELATIVE_PATH = Movies/Danaview` and `IS_PENDING = 1`, stream copy, then clear pending.
  - Files: SAF `ACTION_CREATE_DOCUMENT`.
  - Share: `ACTION_SEND` with a `FileProvider` URI (authority `${applicationId}.danaview.editor.files`).

### 6.6 Media services

| Service | Implementation |
|---|---|
| Probe / compatibility | `MetadataRetriever` (`media3-inspector`: track groups, duration) + `MediaExtractorCompat` formats → codec, profile, size, color info (HDR). Decoder availability via `MediaCodecList` for mime/profile/size; `isHardwareAccelerated` decides `proxiesRecommended`. MKV/WebM are editable when decoders exist. HDR sources are editable via tone mapping, and an automatic proxy is used for preview [VERIFY CompositionPlayer honours `Composition.hdrMode`; if not, HDR preview uses the SDR proxy always] |
| Thumbnails | `FrameExtractor` per (media, proxy) with `SeekParameters.CLOSEST_SYNC` and `setEffects(listOf(Presentation.createForHeight(h)))`, so the GPU downscales. Frames are drawn into a strip `Bitmap` → `compress(JPEG, 70)`. Same disk cache keys as iOS. Concurrency 1–2. Extractors close after 10 s idle |
| PCM decoder (shared) | `PcmDecoder`: `MediaExtractorCompat` + async `MediaCodec` on a `HandlerThread`, `KEY_PCM_ENCODING = ENCODING_PCM_FLOAT`, sample-accurate trim by pts + sample index (`ai.md` §7.3). Used by waveforms, speech audio and reverse audio |
| Waveforms | Same binning and `.dvpk` format as iOS |
| Speech audio | `ai.md` §7.3: `ChannelMixingAudioProcessor` + `SonicAudioProcessor(16 kHz)` + WAV writer |
| Proxies | `Transformer` with `Presentation.createForShortSide(540)`, H.264 3 Mbps, `setiFrameIntervalSeconds(0.33f)`, `HDR_MODE_TONE_MAP_HDR_TO_SDR_USING_OPEN_GL`, AAC 128k, same timestamps. Runs at background priority on the job executor; paused (cancelled and requeued) while an export runs |
| Freeze frame | `FrameExtractor` with `SeekParameters.EXACT` → `Bitmap.compress(PNG)` at `outputPath` |
| Reverse | The same 3-stage algorithm as iOS: (1) `Transformer` to an all-intra intermediate (`setiFrameIntervalSeconds(0f)`, `setMaxBFrames(0)`, high bitrate). (2) `MediaExtractorCompat.seekTo(t_k, SEEK_TO_CLOSEST_SYNC)` frame by frame from the end, feeding a `MediaCodec` decoder whose output `Surface` is the encoder's input surface (through a GL blit for size and format safety), with mirrored pts. (3) Audio reversed through `PcmDecoder` → WAV → AAC `MediaCodec` → `Mp4Muxer` (`media3-muxer`) |

### 6.7 Recording

- **Capture:** `AudioRecord(MIC, 48 kHz, mono, PCM_16BIT)` on a dedicated thread writes the WAV. `levels` are RMS at 20 Hz.
- **Latency:** `startLatencyUs` comes from `AudioRecord.getTimestamp` (first frame time vs. start call), or 0 if unavailable.
- **Interruptions:** read errors, an `AudioDeviceCallback` reporting device removal, or audio-focus loss from a call stop the recording and keep the file.
- **Permission:** `RECORD_AUDIO` through `ActivityPluginBinding.addRequestPermissionsResultListener`.
- **Playback while recording:** the preview plays with `player.volume = 0f`.

### 6.8 Threading and memory (Android)

| Thread | Work |
|---|---|
| Main | Pigeon handlers, SurfaceProducer callbacks, `EventChannel` sink, activity-result pickers, permission results |
| `danaview-preview` HandlerThread | `CompositionPlayer` application looper, plan decode (`JsonReader`), `CompositionMapper`, `ParamSnapshot` build |
| `danaview-gl` single-thread executor | Media3 video graph and our effects. **The only thread that touches GL objects.** Texture uploads are queued here |
| Media3 internal | Playback thread, codec callbacks, audio graph |
| `danaview-export` HandlerThread | Transformer looper, progress polling |
| `danaview-jobs` executor (1 low / 2 mid-high) + `danaview-io` (2) | Thumbnails, waveforms, proxies, reverse, freeze, speech audio; sprite and LUT inflation |
| Recorder thread | `AudioRecord.read` loop |

- **GPU memory model:** each visual sequence keeps about 3 textures at ≤ render size (LayerLook output, an optional blur pair, the LayerPlace canvas output).
  - At 1080p, 8 layers × 3 × 8.3 MB ≈ **200 MB**. This drives the tier caps in §8.2.
  - Export at 4K is allowed only when `preflight` finds ≤ 3 visual sequences besides the clock and background.
- **Before an export starts on low or mid tier**, the preview session is **suspended**: `player.stop()`, the surface is kept, and `ParamSnapshot` is retained. It is restored after the export.

---

## 7. Feature → platform technology map

| Feature (owner list) | iOS | Android |
|---|---|---|
| Multiple video tracks, PiP (video/image over video), multiple overlays, independent timing | Composition tracks by interval coloring + compositor layer stack | One sequence per lane color; compositor blend; gating |
| Position / scale / rotation / flip / opacity / aspect / fit / reset / direct manipulation | `dv_place` math via `CIImage.transformed` + opacity kernel; transients | `LayerPlaceEffect` matrix |
| Crop (incl. PiP crop) and crop mode | `CIImage.cropped` before the look; `cropSource` mode | Texcoord crop in `dv_look`; mode flag |
| Keyframes (position, scale, rotation, opacity, volume, effects) | `ParamSnapshot` linear eval per frame; volume as `AVAudioMix` ramps | `ParamSnapshot` per pts; `KeyframedGainProvider` per sample |
| Speed presets, custom speed, ramps (segments) | `scaleTimeRange` per segment, audio and video | `SegmentSpeedProvider` via `setSpeed(SpeedParameters)` |
| Maintain pitch | Per-track `audioTimePitchAlgorithm` `.spectral` / `.varispeed` | `SpeedParameters.shouldMaintainPitch` (Sonic) |
| A/V sync | Video and audio share composition timing; `seekingWaits…`; export from one reader | Media3 shared clock; the same provider for audio and video |
| Reverse video | Reversed rendition job (all-intra + reverse decode) | Same |
| Freeze frame | Exact generator still → image item | `FrameExtractor` EXACT → image item |
| Frame-accurate seeking | Rational `CMTime(k, fps)`, zero tolerance, frame attachment ack | ms ceiling + `VideoFrameMetadataListener` ack |
| Text overlays, fonts, styles, background, stroke, shadow | Flutter sprite → `SpriteStore` layer | Flutter sprite → `SpriteBandEffect` |
| Text animations (fade, slide, scale, typewriter) | `dv_place` / `dv_reveal` | `SpriteBandEffect` uniforms + reveal map |
| Subtitle track, styling, positioning, burn-in | Sprites per cue on a sprite lane | Same |
| SRT/VTT import/export | n/a (Dart, Subtitles area) | n/a |
| AI subtitles: extract audio | `PcmReader` → 16 kHz WAV | `PcmDecoder` → 16 kHz WAV |
| Effects: brightness … tint | `dv_look` kernel | `dv_look.glsl` |
| Sharpness, blur, vignette | `dv_sharpen`, `dv_blur_h/v`, `dv_vignette_mask` | `dv_place` sharpen/vignette, `SeparableBlurEffect` |
| Color presets / look stills | Grade params (+ optional LUT) rendered via redraw path | `FrameExtractor` + `LayerLookEffect` |
| LUT `.cube` import, intensity | `.vlut` tiled CIImage, kernel trilinear | `.vlut` tiled texture, shader trilinear |
| Transitions (all 7 + duration, direction, preview) | `dv_place`/`dv_transition` on A/B layers; loop play | Same math in `LayerPlaceEffect` on A/B sequences |
| Chroma key, similarity, smoothness, spill, matte preview | `dv_look` chroma + `matte` mode | Same in GLSL |
| Masks (rect, circle, position, size, feather, opacity) | `dv_vignette_mask` SDF | `dv_place` SDF |
| Multiple audio tracks, background music, extracted audio | Composition audio tracks per lane color | Audio-only sequences; `DefaultAudioMixer` |
| Volume, fades, mute/solo | Ramps; mute/solo resolved by Domain; lane gain param | `GainProcessor`; lane gain param |
| Voice recording | `AVAudioEngine` WAV | `AudioRecord` WAV |
| Waveforms, thumbnails, caching | `.dvpk` + JPEG strips on disk, LRU | Same |
| Proxy media | Reader/writer 540p GOP 10 | Transformer 540p GOP 0.33 s |
| Real-time preview, play/pause, quality, fullscreen | `AVPlayer` + compositor → `FlutterTexture` | `CompositionPlayer` → `SurfaceProducer` |
| MP4 / MOV / H.264 / H.265 / res / fps / bitrates | `AVAssetWriter` (MOV ✓, HEVC on HW probe) | Transformer + `InAppMp4Muxer` (MOV ✗, HEVC on HW probe) |
| Progress, cancel, background, hardware | Pumps; BG continued task (26+) or pause; VideoToolbox | Progress holder; FGS; `MediaCodec` HW selector |
| Import video/audio/images | PHPicker (`preferredAssetRepresentationMode = .current`, no transcode) + UIDocumentPicker | Photo Picker (`PickMultipleVisualMedia`) + SAF `OpenMultipleDocuments` |
| Missing media detection, relink | `canRead` / bookmark resolve; probe compare | Persisted grant check; probe compare |
| Originals never modified | Read-only opens; outputs only to Dart-given paths; PHPicker temp copies handed to Persistence | Read-only `ContentResolver` opens; same |

---

## 8. Caches, budgets and device tiers

### 8.1 Disk caches (`cache/editor/…`; iOS `Library/Caches`, Android `cacheDir`)

| Cache | Key | Cap (LRU by access time) | Notes |
|---|---|---|---|
| `thumbs/` | `sha1(fp, interval, height, tile, proxy)` | 300 MB | JPEG strips |
| `waves/` | `fp-stream` | 64 MB | `.dvpk` |
| `proxies/` | `fp` | 4 GB or 10% of free space, whichever is smaller | `.part` + rename; never used by export |
| `sprites/` | content hash | 400 MB | Preview and export scales |
| `work/` | job id | none; wiped at launch except active jobs | Reverse intermediates, export temp files |

Rules:
- Eviction runs at engine start and after each job.
- Files belonging to an open session are pinned.
- "Clear editor cache" (`ux.md` §4.8) is disabled while a session or job is active.
- **Project-owned** outputs (reverse, freeze, recordings) go to Persistence paths, never to the cache.

### 8.2 Tiers and memory

Tiers:
- **Low:** ≤ 3 GB RAM (iOS: iPhone 8, X, SE 2; Android: `isLowRamDevice` or ≤ 4 GB).
- **Mid:** 4–6 GB.
- **High:** ≥ 8 GB, or iOS A15+ with 6 GB.

| Budget | Low | Mid | High |
|---|---|---|---|
| `maxConcurrentVideoLayers` (decoding at once) | 3 | 4 | 6 |
| `maxPreviewLongSide` (auto quality start) | 960 | 1280 | 1920 |
| Native preview working set (excl. decoder buffers) | ≤ 160 MB | ≤ 250 MB | ≤ 350 MB |
| Image + sprite + source-frame caches | 48 MB | 96 MB | 160 MB |
| Export working set (1080p) | ≤ 220 MB | ≤ 300 MB | ≤ 400 MB |
| Max export size | 1080p | 1440p (4K if ≤ 2 layers) | 4K (≤ 3 layers on Android) |
| Concurrent background jobs | 1 | 2 | 2 |

- On Android, `maxConcurrentVideoLayers = min(table, codecMaxInstances − 1)`. One instance is kept for thumbnails and stills.
- The UX/Domain reject edits beyond the layer limit with `LimitExceeded` (`ux.md` §2.1).

---

## 9. Error model

Error flow:
1. Native throws.
2. A Pigeon `FlutterError(code = EngineErrorCode.name, message = debug text without paths, details = {itemId?, mediaFingerprint?, retryable})`.
3. `error_mapper.dart` turns it into an `EngineFailure`.
4. `danaview_editor` turns that into an `EditorFailure` (`ux.md` §18):

| EngineErrorCode | UX failure |
|---|---|
| `mediaOffline` | `MediaUnavailable(media)` |
| `permissionDenied` | `PermissionDenied(kind)` |
| `unsupportedMedia`, `notSupportedOnDevice` | `MediaUnsupported(reason)` |
| `decoderInitFailed`, `decodeFailed`, `gpuUnavailable` | `PreviewFailed(recoverable: true)` in preview; `ExportFailed(unknown)` in export |
| `encoderUnavailable` | `ExportFailed(encoderUnavailable)`, which drives "Export with H.264" |
| `encoderSizeLimit` | `ExportFailed(encoderSizeLimit)` |
| `diskFull` | `ExportFailed(diskFull)` / `SaveFailed(diskFull)` |
| `interrupted` | `ExportFailed(interrupted)` |
| `planInvalid`, `internal` | `UnknownFailure`, plus a debug assert |
| `planOutOfSync` | Handled in `plan_sync.dart` (one full resend; a second failure → `PreviewFailed`) |
| `surfaceLost` | Preview event; auto-recovered |
| `cancelled` | Not a failure: `JobCancelled` |

Preview failures are recoverable by recreating the session. The UX shows a "Restart preview" button. Native logs use `os_log` (subsystem `com.vecvel.danaview.editor`) and `Log` (tag `DanaviewEngine`). There is no telemetry, and paths never appear in user-copyable details.

---

## 10. Performance budgets (native side; p90 unless stated otherwise)

| Metric | Low | Mid | Measured in |
|---|---|---|---|
| Open session → first frame (200 items) | ≤ 1.8 s | ≤ 1.0 s | ENG-10 |
| Compose 1 frame, 2 video layers + LUT + text (preview size) | ≤ 14 ms | ≤ 8 ms | signposts / GL timer queries |
| Playback at preview size, 2 layers | 30 fps, ≤ 2% dropped | 30/60 fps, ≤ 1% dropped | ENG-10 |
| Param patch or transient → texture updated (paused) | ≤ 50 ms | ≤ 30 ms | ack + frame callback |
| Structural patch → frame at playhead | ≤ 400 ms | ≤ 250 ms | ack |
| Exact seek, original H.264 1080p (GOP ≤ 2 s) | ≤ 300 ms | ≤ 200 ms | `SeekAck` |
| Exact seek with proxies | ≤ 150 ms | ≤ 100 ms | `SeekAck` |
| Thumbnail tile (8 frames, miss) | ≤ 400 ms | ≤ 250 ms | job timer |
| Waveform | ≥ 20× realtime | ≥ 40× | job timer |
| Proxy generation (1080p30 source) | ≥ 1× realtime | ≥ 3× | job timer |
| Export 1080p30 H.264, 2 layers + text | ≥ 0.7× realtime | ≥ 1.5× | export timer |
| Export 4K30 H.265 single layer (high tier) | n/a | ≥ 0.6× (high) | export timer |
| Plan encode (isolate) + decode, 2,000 items | ≤ 120 ms total | ≤ 60 ms | ENG-10 |
| Engine native memory | §8.2 | §8.2 | Instruments / `dumpsys meminfo` |

---

## 11. Testing strategy

### 11.1 Dart (CI on every PR)

- **API package:**
  - Codec round-trip on all `test_fixtures/plans/*.json`. The fixtures cover every §4.2 field and every feature.
  - Validator rejection cases.
  - Patch classification table (same vectors as native).
  - Frame-grid, keyframe, transform, gain and text-animation vectors.
  - The reference renderer reproduces the committed golden PNGs. Goldens regenerate only through `tool/regen_goldens.dart` with review.
  - `.vsprite`/`.vlut` codecs.
  - Sprite scheduler windowing and time slicing (fake clock).
  - `FakeEditorEngine` passes the contract kit.
- **Plugin Dart:** `MobileEditorEngine` with mocked Pigeon channels (`TestDefaultBinaryMessenger`):
  - error mapping for every code,
  - out-of-sync retry,
  - event routing and throttling assumptions,
  - job cancellation,
  - export reattach.

### 11.2 Native unit tests (CI)

- **iOS (XCTest in `example/ios/RunnerTests`, simulator):**
  - plan decode of the shared fixtures,
  - `ParamSnapshot`/keyframe/frame-grid vectors,
  - `TrackAllocator` coloring,
  - `CompositionBuilder` segment layout (composition track segments and scaled durations equal the plan within 1 µs),
  - `InstructionBuilder` coverage validity,
  - `AudioMixBuilder` ramps,
  - kernels on 8×8 test images through a **software** `CIContext` against Dart reference values,
  - `.vsprite`/`.vlut` loaders,
  - `PcmReader` trim accuracy on fixture audio.
- **Android (JVM, `android/src/test`, JUnit 5):**
  - plan decode,
  - vectors,
  - `CompositionMapper` structure (sequence order, gaps, durations equal `durationUs`, speed providers' integrated durations),
  - `LayerGatingCompositorSettings`,
  - `KeyframedGainProvider` sample-exact envelope,
  - patch classification,
  - error-code mapping.

### 11.3 Instrumented and parity tests (CI emulator/simulator + device lab)

- **Fixture media** (`test_fixtures/media/`, generated by `tool/make_fixtures.dart` + platform encoders, committed):
  - `frame_counter_1080p30.mp4`: each frame shows its index as a 16-bit barcode plus digits.
  - `frame_counter_24.mp4`, `rotated_90.mov`, `hdr_hlg.mov` (device lab only).
  - `color_chart.png`, `tone_ramp.png`, `green_screen.mp4`.
  - `clicks_flash.mp4`: a white flash frame and a 1 kHz click at the same time every second.
  - `speech_10s.m4a`, `stereo_51.m4a`.
- **Parity:** render each golden plan's frames via `renderLookStills`/redraw or export decode, then compare to the Dart reference with the §4.8 tolerance. Run on both platforms.
- **Frame accuracy:** 200 random exact seeks on the frame-counter clip (and through speed segments) → the decoded barcode equals the expected source frame and `SeekAck.displayedFrame == k`.
- **A/V sync:** export `clicks_flash` through 1×, 2× (keep pitch), a 0.5× ramp and a cross-dissolve. Decode the output and detect the flash frame and the click onset: |Δ| ≤ 1 frame and ≤ 20 ms.
- **Export conformance:** decoded output via `MediaInspector` (`danaview_data`) plus platform extractors: container, `avc1`/`hvc1`, size, fps, frame count = duration × fps ± 1, AAC 48 kHz stereo, bitrate within ±25% of the request (VBR).
- **Jobs:**
  - Reverse: barcode order strictly decreasing.
  - Freeze: barcode equals the requested frame.
  - Proxy: timestamps equal the source's.
  - Speech WAV: `ai.md` AI-10 ACs.
  - Waveform peaks match a reference on fixture audio.
- **Lifecycle:**
  - Background/foreground during playback (no black frame after 1 s).
  - Android surface reset (`resetInBackground`).
  - iOS export paused and resumed.
  - Android export continuing in the FGS with the activity destroyed.
  - Process kill during export → one `interrupted` record.
  - Interruption during recording keeps the file.

### 11.4 Simulator and emulator realities

| Environment | Works | Doesn't, or differs | Consequence |
|---|---|---|---|
| iOS Simulator (Apple-silicon Mac, iOS 26 runtime) | AVFoundation composition, custom compositor, Metal CI (host GPU), H.264 encode, Photos picker, mic (host) | **No hardware HEVC encode**; H.264 may be software; `BGContinuedProcessingTask` UI/behaviour not representative; performance numbers meaningless; no thermal | Capability probe reports it. CI runs H.264-only export tests on the simulator. HEVC, background, perf and thermal run only in the device lab |
| Android Emulator (API 35 x86_64; CI uses `swiftshader_indirect` or host GPU) | Media3 decode/encode via `c2.android.*` **software** codecs, GL effects (slow under SwiftShader), FGS, Photo Picker, `AudioRecord` (virtual mic) | No hardware codecs (`hardwareEncoder=false`, HEVC encoder may exist in software), HDR absent, GPU memory model differs, timing jitter | Parity and accuracy tests run at 540p on the emulator with relaxed perf. HEVC is asserted only if the probe finds an encoder. Perf runs only in the device lab |
| Device lab (nightly + pre-release) | Everything | n/a | iPhone SE 2 (low), iPhone 12 (mid), iPhone 15 Pro (high, iOS 26 BG GPU); Android 4 GB Helio/SD6xx (low), Pixel 7a (mid), Pixel 9 or Galaxy S24 (high); one API 29 device |

### 11.5 CI wiring

A new `.github/workflows/editor-ci.yml` runs on PRs touching `packages/danaview_editor*`, with these jobs:
- `dart-test` (ubuntu),
- `android-unit` (ubuntu, Gradle through `example/android`),
- `android-instrumented` (ubuntu with KVM, `reactivecircus/android-emulator-runner`, API 35),
- `ios-unit+integration` (macos-15 runner, Xcode 26, iOS 26 simulator).

The device lab runs from fastlane lanes (`ios/fastlane`, `android/fastlane`) locally or on a self-hosted runner. **macOS runner minutes are an owner cost decision (§13 D7).**

---

## 12. Cross-area interfaces

| Interface | Counterpart | Direction | Needs / provides | Section |
|---|---|---|---|---|
| `RenderPlan` Dart types + `compileRenderPlan` / `diffPlans` | Domain | Domain → engine | Resolved plan per §4.1: render ranges with handles, speed segments, item-local keyframes, mute/solo resolved, lanes top → bottom, integer µs; `RenderPlanPatch` with item upserts | §4 |
| Wire schema v1, patch classification, render-math spec, vectors | This area | Engine → Domain/UX | Domain's `evaluate`, `boxAt`, `FrameRate` pass the shared vectors (joint test) | §4.3–4.8 |
| Frame rates integer only | Domain + UX | Decision | Project and export fps ∈ {24, 25, 30, 48, 50, 60}; "Match first clip" rounds | §0.9, §13 D2 |
| Transition handles, max duration | Domain | Domain → engine | Overlap windows; reversed renditions requested with handle margins | §4.1 |
| Text style model → sprites; `TextMetricsProvider` | Domain + UX | Engine API provides `TextLayoutEngine` | Same layout for handles and pixels; resolves `ux.md` Q3; font set per Q4 | §4.7 |
| `.cube` parse → `.vlut` | Domain/Persistence parser | Engine normalizes | Parse errors with line numbers stay with the parser; LUT size ≤ 65 | §4.7 |
| `EngineMedia` (uri, fingerprint, bookmark), `MediaAccess` | Persistence | Persistence builds; engine resolves | Stable fingerprint; bookmarks created and resolved through `MediaAccess` | §3.1, §3.5 |
| `probe`, `compatibility` | Persistence import, UX player "Edit" | Engine provides | ≤ 300 ms compatibility; probe fields | §3.1 |
| Generated asset paths (reverse, freeze, recordings) | Persistence | Persistence supplies `outputPath` in the project bundle | Engine writes only there; Persistence registers the asset | §3.3 |
| Cache dirs, sizes, clear | UX `StorageContributor` | Engine API exposes `EditorCacheDirectories` | Clear disabled while a session is active | §8.1 |
| `EditorEngine` contract | UX (`ux.md` §2.3) | Engine provides | §3, with the marked additions; `FakeEditorEngine` first | §3 |
| Preview clock / seek ack / events | UX `PlayheadController` | Engine provides | `seq`, `displayedFrame`, 10 Hz clock, exact vs scrub semantics | §3.2 |
| Export settings, presets, preflight, background kinds | UX export sheet | Engine provides | Presets map to `ExportSettings`; `preflight` warnings | §3.4 |
| `SpeechAudioExtractor` | AI (`ai.md` §7) | Engine implements | `jobs.extractSpeechAudio` exactly as §7.1; ACs from AI-10 | §5.6, §6.6 |
| `BackgroundWorkGuard`, export-active signal | AI (`ai.md` §6.3), UX tasks | Engine implements | Android FGS lease; iOS `beginBackgroundTask` lease (pause semantics); `activeJobs()` for the export-active flag | §3.5, §6.5 |
| Subtitle burn-in, RTL, font fallback | AI §10.4 + Subtitles | Engine via Flutter sprites | Explicit `\n`, system fallback, RTL from first strong char: guaranteed by `ui.Paragraph` | §4.7 |
| Platform declarations | UX §20.3 (UX-41) | Joint | See ENG-11 | §14 |

---

## 13. Risks, uncertainties and decisions needed

### 13.1 Decisions (owner / lead)

| # | Decision | Recommendation |
|---|---|---|
| D1 | Editor runtime minimums | iOS 15.0, Android 10 (API 29). App targets unchanged |
| D2 | Integer project and export frame rates | Yes (24/25/30/48/50/60) |
| D3 | Text and subtitles rasterized by Flutter (`ux.md` Q3) | Yes; plus the bundled user-content font set (Q4) |
| D4 | MOV only on iOS; SDR-only export; HDR tone-mapped | Yes |
| D5 | iOS background export: iOS 26 continued processing (request the GPU entitlement from Apple) else pause | Yes; file the entitlement request early |
| D6 | Android FGS types `mediaProcessing` (35+) / `dataSync` (29–34) + Play Console declaration video | Yes |
| D7 | CI macOS runner minutes vs self-hosted Mac | Self-hosted runner on the dev Mac for iOS jobs |
| D8 | Rate-conform rule mismatch (iOS floor vs Android nearest) | Accept in v1; optional ENG-D2 unifies via timestamp offset on Android |
| D9 | Concurrent video layer caps per tier (3/4/6) | Accept; Domain enforces `LimitExceeded` |

### 13.2 Risks

| # | Risk | Impact | Mitigation |
|---|---|---|---|
| R1 | Media3 `CompositionPlayer` multi-sequence preview is `@UnstableApi` and young (redraw, scrubbing, gating, sequence count) | Android preview quality | **AND-01 spike first** with go/no-go criteria. Fallback B: preview via `ExoPlayer` of the main lane with overlays restricted to sprite bands (degraded PiP preview, full export). Pin 1.11.1; upgrade only with the parity suite |
| R2 | GPU memory with canvas-sized layer textures (Android) | OOM / jank on low tier | Tier caps, preview size caps, suspend preview during export, `preflight` complexity limits |
| R3 | iOS background GPU restrictions | Export pauses when the user leaves | Honest UX copy (`ux.md` §11.5), BG continued task on 26+, software CI fallback |
| R4 | Structural rebuild latency on large projects | Edits feel slow | Param-only classification for most edits; composition build ≤ 150 ms target; keep the last frame visible |
| R5 | Parity drift between three implementations of §4.8 | Preview ≠ export, iOS ≠ Android | Single spec, CPU reference goldens, parity suite gating releases |
| R6 | Rate conform differs per platform | Different source frame in mixed-fps projects | Documented; tests use equal fps or ±1 source-frame tolerance; ENG-D2 |
| R7 | Hardware decoder instance limits (Android) or decoder thrash on many short clips | Stalls | `codecMaxInstances` cap, proxies (GOP 10), interval coloring minimizes tracks |
| R8 | Play policy for FGS `dataSync` on API 34 | Store rejection | Declaration with justification; fallback: on API 29–34 the export continues only while visible (`backgroundKind=none`) |
| R9 | Sprite pre-pass time for very long subtitle tracks | Slow export start | Content-addressed sprite cache (re-exports are instant); progress shown; ≤ 8 s for 1,000 cues mid |
| R10 | The player's audio session (media_kit) and the editor session conflict on iOS | Wrong routing / no audio | Explicit category set and restore; integration test with player → editor → player |

### 13.3 [VERIFY] items (each owned by a ticket AC)

| # | Claim | Ticket |
|---|---|---|
| V1 | `getOverlaySettings(inputId, …)`: `inputId` = sequence index and pts = composition time | AND-01 |
| V2 | Per-item effect pts are sequence-cumulative in both CompositionPlayer and Transformer | AND-01 |
| V3 | `experimentalRedrawLastFrame` re-runs custom effects and picks up new params | AND-01 |
| V4 | Straight-alpha output of custom effects is preserved into the compositor (transparent placeholder images stay transparent) | AND-01 |
| V5 | CompositionPlayer honours `Composition.hdrMode`; HDR + SDR mix works with tone mapping | AND-01 / AND-02 |
| V6 | Media3 delivers upright (rotation-applied) frames to effects | AND-01 |
| V7 | GLES 3 context availability on API-29 low-tier devices | AND-02 |
| V8 | Pigeon 29 `@EventChannelApi` with sealed payloads for Swift + Kotlin; `@TaskQueue` unnecessary | ENG-04 |
| V9 | `-fcikernel` metallib builds inside a CocoaPods framework target and loads on simulator and device | IOS-01 |
| V10 | `seekingWaitsForVideoCompositionRendering` + frame attachment gives a deterministic ack on iOS 15–26 | IOS-01 |
| V11 | Background GPU failure mode on iOS 15–25 (compositor wait-gate prevents errors) | IOS-01 |
| V12 | `BGContinuedProcessingTask` wildcard registration timing (launch vs submission) | IOS-11 |
| V13 | `InAppMp4Muxer` writes `hvc1` for HEVC | AND-11 |
| V14 | `kotlinx`/`activity` versions compatible with AGP 9.0.1 + Kotlin 2.3.20 | ENG-04 |

---

## 14. Implementation tickets (ordered)

Sizes: S ≤ 2 days, M ≤ 1 week, L ≤ 2 weeks. Prefixes:
- `ENG`: Dart and cross-platform work.
- `IOS`: iOS native.
- `AND`: Android native.
- Dependencies on other areas: `DOM:`, `PER:`, `UX-xx`, `AI-xx`.

Mapping from the UX tags:

| UX tag | Tickets |
|---|---|
| `ENG:api+fake` | ENG-01 |
| `ENG:preview` | ENG-07, IOS-10, AND-10 |
| `ENG:thumbs` | IOS-03, AND-03 |
| `ENG:waveforms` | IOS-04, AND-04 |
| `ENG:jobs` | IOS-05–07, AND-05–07 |
| `ENG:editingMode` / `ENG:sampleColor` / `ENG:lookStills` | IOS-09/10, AND-09/10 |
| `ENG:picker` / `ENG:exportFile` | IOS-13, AND-13 |
| `ENG:recorder` | IOS-12, AND-12 |
| `ENG:compatibility` | IOS-02, AND-02 |
| `IOS:export` / `AND:export` | IOS-11 / AND-11 |

### Milestone E0: contracts and scaffolding

| ID | Title | Files owned | Depends on | Acceptance criteria |
|---|---|---|---|---|
| ENG-01 | Engine API package, value types, failures, fake, contract kit | `packages/danaview_editor_engine_api/{pubspec.yaml, lib/danaview_editor_engine_api.dart, lib/testing.dart, lib/src/{engine,preview,media_services,export,recorder,platform_services,capabilities,failures}.dart, lib/src/fake/*}`, `test/contract/*` | DOM: RenderPlan placeholder types | Analyzes clean. `FakeEditorEngine` passes the contract kit (clock seq rules, exact-seek ack, cancel semantics, transient non-persistence). UX-01 compiles against it. Dependency-rule test updated |
| ENG-02 | RenderPlan wire schema v1, codec, patch codec, validator, fixtures | `lib/src/plan/*`, `render_plan_v1.schema.json`, `test_fixtures/{plans,patches}/*` | ENG-01, DOM: RenderPlan types | ≥ 15 fixtures covering every §4.2 field. Encode of 2,000 items in `Isolate.run` ≤ 40 ms (mid). Validator rejects each §4.1 invariant with item id. Classification vectors committed |
| ENG-03 | Shared math, vectors, Dart reference renderer, goldens | `lib/src/math/*`, `lib/src/reference/*`, `test_fixtures/{vectors,images}/*`, `tool/regen_goldens.dart` | ENG-02 | Vectors for frame grid, keyframes, transform M, every §4.8 row, gain. Goldens generated. Joint test: Domain `FrameRate`/`evaluate`/`boxAt` pass the same vectors (with DOM) |
| ENG-04 | Plugin scaffold, Pigeon, event router, error mapper, example host, CI | `packages/danaview_editor_engine/{pubspec.yaml, pigeons/*, lib/**}`, `ios/{danaview_editor_engine.podspec, Classes/{DanaviewEditorEnginePlugin.swift, Pigeon/*, Core/*}}`, `android/{build.gradle.kts, src/main/AndroidManifest.xml, src/main/kotlin/**/{DanaviewEditorEnginePlugin.kt, pigeon/*, core/*}}`, `example/**`, `.github/workflows/editor-ci.yml` | ENG-01 | `capabilities()` round-trips on the iOS simulator and the Android emulator. Every `EngineErrorCode` maps (test). Events delivered and throttled. Pigeon pinned `^29.0.0` with generated files committed. V8 and V14 answered. CI green. App builds still pass (`flutter build ios/apk`) |
| ENG-05 | Text layout engine, sprite rasterizer, `.vsprite`, sprite scheduler | `lib/src/render_prep/{text_layout_engine, text_sprite_rasterizer, vsprite_codec, sprite_scheduler}.dart` | ENG-02, DOM: text style, UX Q3/Q4 decisions | Glyph boxes equal `ui.Paragraph` boxes. RTL + CJK + emoji fixtures render with fallback. Reveal map correct for grapheme clusters. Slices ≤ 4 ms UI time. 1,000-cue export prep ≤ 8 s (mid). Content-hash reuse test |
| ENG-06 | LUT normalizer + `.vlut` | `lib/src/render_prep/{lut_normalizer, vlut_codec}.dart` | ENG-02, DOM/PER: `.cube` parser | Sizes 2–65; DOMAIN_MIN/MAX; identity LUT round-trips within 1/1024; > 65 rejected with a typed error |

### Milestone E1: de-risking spikes (results update §6/§5 and close [VERIFY] items)

| ID | Title | Files owned | Depends on | Acceptance criteria |
|---|---|---|---|---|
| AND-01 | Media3 multi-sequence spike | `android/src/androidTest/.../spike/*` (kept as regression tests) | ENG-04 | On Pixel 7a and a 4 GB low-tier device: clock band + 3 video sequences + sprite band + background + 2 audio sequences play at 30 fps at 720p. V1–V6 answered with tests. Seek accuracy on the frame-counter clip 200/200. Transformer exports the same composition with matching frames (SSIM ≥ 0.98). **Go/no-go recorded**; on no-go, switch to fallback R1-B |
| IOS-01 | AVFoundation compositor spike | `example/ios/RunnerTests/Spike*` (kept) | ENG-04 | Metallib CI kernel loads on device and simulator (V9). Texture zero-copy shown. Exact seek ack 200/200 (V10). Redraw-from-cache ≤ 30 ms. HLG clip arrives as SDR. Reader/writer export with the compositor works. Background behaviour documented (V11) |

### Milestone E2: media services

| ID | Title | Files owned | Depends on | Acceptance criteria |
|---|---|---|---|---|
| IOS-02 | Probe, compatibility, device profile, capabilities | `ios/Classes/{Media/Probe, Media/Compatibility, Core/DeviceProfile, Core/Capabilities}.swift` | IOS-01 | Probe fields correct on fixtures (rotation, HDR, VFR). Compatibility ≤ 300 ms. Unsupported reasons for MKV/WebM/AVI/protected. HEVC/H.264 hardware probe. Tier table |
| AND-02 | Probe, compatibility, device profile, capabilities | `android/.../{media/Probe, media/Compatibility, core/DeviceProfile, core/Capabilities}.kt` | AND-01 | Same fields. Decoder availability per mime/profile/size. `codecMaxInstances` cap. API/GLES gate (V7). Thermal listener |
| IOS-03 | Thumbnails + disk cache | `ios/Classes/Media/{ThumbnailService, DiskCache}.swift` | IOS-02 | Tile = N frames at the requested height, JPEG. Cache hit ≤ 20 ms. Cancel stops work. LRU cap enforced. ≤ 400 ms miss (low) |
| AND-03 | Thumbnails + disk cache | `android/.../media/{ThumbnailService, DiskCache}.kt` | AND-02 | Same ACs, using `FrameExtractor` CLOSEST_SYNC with GPU downscale |
| IOS-04 | PCM reader, waveforms, speech audio extraction | `ios/Classes/Media/{PcmReader, WaveformService, SpeechAudioExtractor}.swift` | IOS-02, AI-10 contract | `.dvpk` matches reference peaks. ≥ 20× realtime (low). AI-10 ACs (16 kHz s16 mono, ±1 ms, clap ±20 ms, 5.1 centre kept, cancel deletes) |
| AND-04 | PCM decoder, waveforms, speech audio extraction | `android/.../media/{PcmDecoder, WaveformService, SpeechAudioExtractor}.kt` | AND-02, AI-10 contract | Same ACs, including MP4 edit list and AAC priming |
| IOS-05 | Proxy job, proxy registry, job registry priorities | `ios/Classes/{Media/ProxyJob, Media/ProxyRegistry, Core/JobRegistry}.swift` | IOS-02 | Proxy PTS equal to the source (VFR fixture). 540p, GOP 10. `.part` rename. Pre-emption by interactive jobs. Policy from the UX setting |
| AND-05 | Proxy job, registry, job priorities | `android/.../{media/ProxyJob, media/ProxyRegistry, core/JobRegistry}.kt` | AND-02 | Same ACs. HDR source → SDR proxy. Paused during export |
| IOS-06 | Freeze frame + source-frame cache + color sampling | `ios/Classes/{Media/FreezeFrameJob, Preview/SourceFrameCache}.swift` | IOS-02 | Barcode of the still equals the requested frame. PNG at the output path. Sample within ±2/255 of the reference |
| AND-06 | Freeze frame + source-frame cache + sampling | `android/.../{media/FreezeFrameJob, preview/SourceFrameCache}.kt` | AND-02 | Same ACs, using `FrameExtractor` EXACT |
| IOS-07 | Reverse rendition | `ios/Classes/Media/ReverseJob.swift` | IOS-05 | Barcode strictly decreasing; duration = range ± 1 frame; audio reversed (click positions mirrored ± 20 ms); memory ≤ 60 MB at 4K; cancel cleans `work/` |
| AND-07 | Reverse rendition | `android/.../media/ReverseJob.kt` | AND-05 | Same ACs |

### Milestone E3: preview

| ID | Title | Files owned | Depends on | Acceptance criteria |
|---|---|---|---|---|
| IOS-08 | Plan decode, `ParamSnapshot`, composition builder, allocator, instructions, audio mix | `ios/Classes/{Plan/*, Composition/*}` | IOS-01, ENG-02, ENG-03 | All plan fixtures build valid compositions (`isValid`). Segment durations equal the plan within 1 µs. Pitch-mode track split. Volume ramps within 0.1 dB of the reference envelope. 2,000 items ≤ 150 ms (mid). Patch classification equals the vectors |
| IOS-09 | `DVCompositor`, kernels (all §4.8 stages), sprite/image/LUT stores, editing modes | `ios/Classes/Render/*` | IOS-08, ENG-05, ENG-06 | Parity suite green for every golden plan. Matte and cropSource modes. Typewriter reveal. Compose ≤ 8 ms mid at 1080p (2 layers + LUT + text). Cancellation generation works |
| IOS-10 | Preview session: texture bridge, display link, clock, seek, transients, patches, quality governor, look stills, source frame, lifecycle, audio session | `ios/Classes/Preview/*` | IOS-09, IOS-06 | `ux.md` §2.3 semantics: seq, exact ack 200/200, scrub coalescing, transient ≤ 2 frames, param patch ≤ 30 ms, structural ≤ 250 ms (mid), degraded/recovered events, background/foreground refresh without a black frame, player→editor→player audio-session test |
| AND-08 | Plan reader, `ParamSnapshot`, composition mapper, gating settings, speed and gain providers | `android/.../{plan/*, composition/*}` | AND-01, ENG-02, ENG-03 | Every fixture maps. Sequence durations equal `durationUs`. Z-order and gating unit tests. `SegmentSpeedProvider` integrates to the plan durations ± 1 µs. Gain envelope sample-exact vs the vectors |
| AND-09 | GL effects (`LayerLook`, `SeparableBlur`, `LayerPlace`, `SpriteBand`), LUT and sprite textures | `android/.../effects/*`, `android/src/main/assets/danaview_shaders/*` | AND-08, ENG-05, ENG-06 | Parity suite green. GL resources released on effect release (leak test). 1080p compose ≤ 8 ms mid (GL timer query). Only `danaview-gl` touches GL (assertion) |
| AND-10 | Preview session: SurfaceProducer bridge, clock, seek and scrub, transients, redraw, patches, quality, look stills, source frame, lifecycle | `android/.../preview/*` | AND-09, AND-06 | Same ACs as IOS-10. `resetInBackground` surface loss recovers. Main-thread latch never exceeds 500 ms. Rebuild keeps the last frame |
| ENG-07 | `MobileEditorEngine` preview glue, plan sync, sprite pushes, resolver adapter for UX MediaId APIs | `lib/src/{mobile_editor_engine, mobile_preview_session, plan_sync, mobile_jobs}.dart` | ENG-04, IOS-10, AND-10 | Out-of-sync retry. Transients dropped when not param-only. Sprite window follows the playhead. UX-19 integrates without platform-specific code |

### Milestone E4: export

| ID | Title | Files owned | Depends on | Acceptance criteria |
|---|---|---|---|---|
| IOS-11 | Export pipeline, encoder settings, background execution, active-export store, destinations | `ios/Classes/{Export/*, Platform/{PhotosSaver, FileHandoff}}.swift` | IOS-09 | MP4 and MOV, H.264 and HEVC (device), size, fps and bitrate per the conformance test. A/V sync test. Cancel deletes. iOS 26 BG continued task with progress (device; V12). Pause/resume on iOS 15–25. `interrupted` after kill. Save to Photos (add-only), Files, share |
| AND-11 | Export coordinator, FGS, notification, encoder selector, active-export store, destinations | `android/.../{export/*, platform/{MediaStoreSaver, FileHandoff}}.kt`, plugin manifest | AND-09 | MP4 H.264/HEVC conformance (`hvc1`, V13). HW encoder preferred, software flagged. FGS types per API. Notification Cancel works with the activity destroyed. API 35 timeout handled. `interrupted` after process kill. MediaStore pending insert |
| ENG-08 | Export glue: preflight, settings mapping, reattach, sprite pre-pass | `lib/src/mobile_export.dart`, `render_prep/sprite_scheduler.dart` (export mode) | ENG-07, IOS-11, AND-11 | `preflight` warnings (software encoder, HEVC missing, layers vs resolution). Pre-pass progress. `activeJobs` reattach after a hot restart. UX-38 passes on both platforms |

### Milestone E5: recording and platform services

| ID | Title | Files owned | Depends on | Acceptance criteria |
|---|---|---|---|---|
| IOS-12 | Voice recorder | `ios/Classes/Recording/VoiceRecorder.swift` | ENG-04 | WAV 48 kHz mono. Levels at 20 Hz. Latency reported. Interruption keeps the file. Permission flows on iOS 15–16 and 17+. Muted preview playback while recording |
| AND-12 | Voice recorder | `android/.../recording/VoiceRecorder.kt` | ENG-04 | Same ACs. `RECORD_AUDIO` flow. Device-removal interruption |
| IOS-13 | Pickers, media access (bookmarks), permissions, background guard | `ios/Classes/Platform/{MediaPicker, MediaAccess, Permissions, BackgroundGuard}.swift` | ENG-04 | PHPicker with `.current` (no transcode, verified on HEVC), multi-select, temp copies flagged. Document picker for video/audio/image/lut/subtitle UTTypes. Bookmark create/resolve/stale. Guard lease = `beginBackgroundTask` |
| AND-13 | Pickers, URI grants, permissions, background guard | `android/.../platform/{MediaPicker, Permissions, BackgroundGuard}.kt` | ENG-04, AND-11 | Photo Picker (`PickMultipleVisualMedia`, fallback documented). SAF for audio/LUT/subtitles. `takePersistableUriPermission`. Notifications permission request. Guard lease hosted by `ExportService` |

### Milestone E6: hardening

| ID | Title | Files owned | Depends on | Acceptance criteria |
|---|---|---|---|---|
| ENG-09 | Device parity and accuracy suite | `example/integration_test/{parity,accuracy,av_sync,conformance}_test.dart`, `tool/make_fixtures.dart`, `test_fixtures/media/*` | E3, E4 | §11.3 suites green on the device lab (both platforms). Reports attached to release |
| ENG-10 | Performance and memory budgets, thermal governor tuning | `example/integration_test/perf_*`, native signposts | E3, E4 | §10 table measured on low/mid/high. §8.2 memory caps hold under a 1,000-item project. Fixes or budget renegotiation recorded |
| ENG-11 | Store, privacy and declarations | `ios/Classes/Resources/PrivacyInfo.xcprivacy` (FileTimestamp C617.1, DiskSpace E174.1, SystemBootTime 35F9.1), app `Info.plist` (`NSMicrophoneUsageDescription`, `NSPhotoLibraryAddUsageDescription`, `BGTaskSchedulerPermittedIdentifiers`), entitlements (continued-processing GPU), plugin `AndroidManifest.xml` (FGS service and types, `FOREGROUND_SERVICE_MEDIA_PROCESSING`, `FOREGROUND_SERVICE_DATA_SYNC`, `RECORD_AUDIO`, `POST_NOTIFICATIONS`, FileProvider) | UX-41 | `ux.md` §20.3 items present. Privacy manifest report clean. Play FGS declaration text drafted. App Review notes |
| ENG-12 | Robustness soak | `example/integration_test/soak_*` | E3–E5 | 1 h random-edit soak with no crash or leak (> 10% growth fails). Interruptions (calls, Siri, route change), low storage, offline media mid-session, process death during each job type |

### Deferred (designed for, not in v1 unless pulled in)

- **ENG-D1:** `Package.swift` for the plugin with a prebuilt CI metallib.
- **ENG-D2:** unify the Android rate-conform rule with iOS floor via a timestamp offset.
- **ENG-D3:** desktop engines (macOS shared Darwin source first).
- **ENG-D4:** HDR export (HEVC Main10 HLG).
- **ENG-D5:** Android `Transformer.resume` for interrupted exports.
- **ENG-D6:** audio master limiter.
