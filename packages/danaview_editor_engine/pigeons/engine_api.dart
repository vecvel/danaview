// OWNER: ENG-06 [INTEGRATION] (defined by ENG-01). FROZEN 2026-10-11 after the IOS-01 and AND-01
// spikes (D-42): neither spike needed a message change (IOS-01.md §3, AND-01.md §6.5); ENG-06 only
// amended the capability docs below. Later changes need a new lead-approved [INTEGRATION] ticket.
// Approved amendment INT-06 (2026-10-11, ARCH D-45 'Contract', §12.6): `JobKindMsg.renderPreview`
// with `JobRequestMsg.plan`, `RenderedRangeMsg` and `PreviewHostApi.setRenderedRanges`,
// `PowerStateMsg`, `PlatformHostApi.powerState` and the `powerStateChanged` signal. Frozen again
// after INT-06.
// Approved amendment INT-07 (2026-10-15, from the Android-lane report; ARCH §12.4, §12.6):
// `PlatformHostApi.materializePick` (copy of a non-persistable pick into an engine directory),
// `ExportNotificationTextsMsg` (localized export notification texts from Dart, carried by
// `EngineConfigMsg.exportTexts` and `ExportHostApi.start`), `RecorderHostApi.isRecording` and the
// `recordingChanged` event (the preview mutes its audio while a recording captures). Frozen again
// after INT-07.
//
// Pigeon surface of the editor engine plugin (ARCH §12.6). Regenerate from the package root with
//
//   dart run pigeon --input pigeons/engine_api.dart
//
// and commit the generated Dart, Swift and Kotlin files (test/glue/pigeon_regeneration_test.dart
// fails when they drift). Conventions:
//
// - Every host method replies asynchronously (`@asyncCallback`: completion-handler / callback
//   style). Pigeon 28 turned `@async` into Swift `async` / Kotlin `suspend` functions, which would
//   pull kotlinx-coroutines into the plugin; `@asyncCallback` is the pre-28 `@async` that ARCH
//   §12.6 describes. Methods without it are synchronous on the native side (still a `Future` in
//   Dart) and are fire-and-forget from the Dart callers.
// - Host handlers run on the platform main thread, validate, post to an engine queue and reply
//   asynchronously; they never block on media work.
// - Errors are `FlutterError(code: EngineErrorCode.name, message: debug text without paths,
//   details: {itemId?, mediaFingerprint?, retryable})`; `error_mapper.dart` turns them into
//   `EngineFailure`. A host API that is not registered yet answers `channel-error`, which maps to
//   `notSupportedOnDevice`.
// - Plans, patches and transients travel as UTF-8 JSON bytes (`PlanTransport`, API-02), never as
//   Pigeon object graphs. Times are integer µs (`...Us`). Media is a `ResolvedMediaMsg`.
// - Events: one multiplexed `EngineEventsApi.engineEvents` stream, emitted on the main thread with
//   native rate limits (clock <= 10 Hz while playing, job and export progress <= 4 Hz, recorder
//   levels 20 Hz); `event_router.dart` demultiplexes it by sessionId / jobId and enforces the same
//   limits again.

import 'package:pigeon/pigeon.dart';

@ConfigurePigeon(
  PigeonOptions(
    dartOut: 'lib/src/pigeon/engine_api.g.dart',
    dartOptions: DartOptions(),
    dartPackageName: 'danaview_editor_engine',
    swiftOut: 'ios/Classes/Pigeon/EngineApi.g.swift',
    swiftOptions: SwiftOptions(errorClassName: 'EnginePigeonError'),
    kotlinOut: 'android/src/main/kotlin/com/vecvel/danaview/editor/engine/pigeon/EngineApi.g.kt',
    kotlinOptions: KotlinOptions(package: 'com.vecvel.danaview.editor.engine.pigeon', errorClassName: 'EnginePigeonError'),
    copyrightHeader: 'pigeons/header.txt',
  ),
)
// ---------------------------------------------------------------------------------------------
// Enums
// ---------------------------------------------------------------------------------------------

/// Device tier (ARCH §12.5, D-40).
enum DeviceTierMsg { minimal, low, mid, high }

/// What an export does in the background (ARCH §12.5, D-22). `noBackground` is the API's `none`.
enum BackgroundExportKindMsg { noBackground, paused, continued, foregroundService }

/// `CacheTrimLevel` (ARCH §12.1, §18.3).
enum CacheTrimLevelMsg { memoryPressure, background, clearAll }

/// Kind of a probed file. The engine only probes videos, audio files and images.
enum MediaKindMsg { video, audio, image }

/// Transfer function of a probed video.
enum ColorTransferMsg { sdr, hlg, pq }

/// `PreviewQuality` (ARCH §12.2).
enum PreviewQualityMsg { auto, full, half, quarter }

/// `PreviewEditingMode` kinds (ARCH §12.2).
enum EditingModeKindMsg { normal, cropSource, matte }

/// Preview lifecycle events (ARCH §12.2). `frameSize` reports a new rendered frame size.
enum PreviewEventKindMsg { firstFrame, frameSize, stalled, recovered, degraded, surfaceLost, failed }

/// `ThumbPriority` (ARCH §12.3).
enum ThumbPriorityMsg { visible, prefetch, background }

/// Engine job kinds (ARCH §12.3, §12.4). `export` jobs are started by `ExportHostApi`;
/// `renderPreview` (D-45, INT-06) renders a range plan into the render-preview cache.
enum JobKindMsg { waveform, proxy, reverse, freeze, speechAudio, export, renderPreview }

/// `JobPriority` (ARCH §12.3).
enum JobPriorityMsg { interactive, normal, background }

/// `ProxyStatus` (ARCH §12.3). `noProxy` is the API's `none`.
enum ProxyStatusMsg { noProxy, queued, running, ready, failed }

/// `ExportContainer` (core).
enum ExportContainerMsg { mp4, mov }

/// `VideoCodec` (core).
enum VideoCodecMsg { h264, hevc }

/// `ExportDetachedHandoff` (ARCH §12.4, D-39).
enum DetachedHandoffMsg { saveToGallery, keepForLater }

/// `ExportPhase` (ARCH §12.4).
enum ExportPhaseMsg { preparing, rendering, finishing }

/// Kinds of `ExportJobState` (ARCH §12.4, D-22, D-39).
enum ExportJobStateKindMsg { running, resumable, interrupted, completedWhileDetached }

/// `MicPermission` (ARCH §12.4).
enum MicPermissionMsg { undetermined, granted, denied, permanentlyDenied }

/// `RecordingInterruption` (ARCH §12.4).
enum RecordingInterruptionMsg { interrupted, routeChanged, deviceRemoved }

/// `MediaPickSource` (ARCH §12.4).
enum MediaPickSourceMsg { photos, files }

/// `MediaPickKind` (ARCH §12.4).
enum MediaPickKindMsg { video, audio, image, lut, subtitle }

/// Where a picked or dropped item came from (core `MediaOrigin` subset).
enum PickOriginMsg { photos, files, drop }

/// `FileHandoffOutcome` (ARCH §12.4).
enum FileHandoffOutcomeMsg { done, cancelled, denied, failed }

/// Engine-wide signals (ARCH §12.1). `powerStateChanged` (D-45, INT-06) carries
/// [SignalMsg.powerState].
enum SignalKindMsg { memoryWarning, thermal, powerStateChanged }

/// `ThermalLevel` (ARCH §12.1).
enum ThermalLevelMsg { nominal, fair, serious, critical }

/// Which payload field of an [EngineEventMsg] is set.
enum EngineEventKindMsg {
  /// `clock` for `sessionId`.
  clock,

  /// `previewEvent` for `sessionId`.
  preview,

  /// `progress` (0..1) for job `jobId`.
  progress,

  /// `jobDone` for job `jobId` (terminal).
  jobDone,

  /// `failure` for job `jobId` (terminal) or, without a jobId, for `sessionId`.
  failure,

  /// `exportProgress` for export job `jobId`.
  exportProgress,

  /// `recorderLevel` (0..1) for recording `jobId`.
  recorderLevel,

  /// `interruption` for recording `jobId` (the recording stopped and kept its file).
  interruption,

  /// `signal` (engine-wide).
  signal,

  /// `drop` (engine-wide, D-18).
  drop,

  /// The background lease `jobId` is about to expire (iOS).
  leaseExpiring,

  /// `recording` (engine-wide, INT-07): a voice recording started (true) or ended (false) capturing;
  /// preview sessions mute their audio while it is true.
  recordingChanged,
}

// ---------------------------------------------------------------------------------------------
// Messages
// ---------------------------------------------------------------------------------------------

/// Dart-supplied engine roots (ARCH §20.1). Native writes only below these.
class EngineConfigMsg {
  EngineConfigMsg({required this.cacheRoot, required this.supportRoot, this.exportTexts});

  /// `<cache>/danaview/editor`.
  String cacheRoot;

  /// `<support>/danaview/editor`.
  String supportRoot;

  /// Localized export notification texts (INT-07); null keeps the engine's English defaults.
  ExportNotificationTextsMsg? exportTexts;
}

/// Localized texts of the export and background-work notifications (INT-07, ARCH §12.4). Android
/// shows them in the foreground-service and completion notifications and names its channels with
/// them; iOS shows no export notification and ignores them. `{percent}` in [exportingProgress] and
/// [workingProgress] and `{count}` in [more] are replaced natively.
class ExportNotificationTextsMsg {
  ExportNotificationTextsMsg({
    required this.exportTitle,
    required this.workTitle,
    required this.exporting,
    required this.exportingProgress,
    required this.working,
    required this.workingProgress,
    required this.cancel,
    required this.savedToGallery,
    required this.exportFinished,
    required this.more,
    required this.progressChannelName,
    required this.progressChannelDescription,
    required this.doneChannelName,
    required this.doneChannelDescription,
  });

  /// Title when the job has none ("Exporting video").
  String exportTitle;

  /// Title of a background-work lease without one ("Working in the background").
  String workTitle;

  /// Text without a known progress ("Exporting").
  String exporting;

  /// Text with progress ("Exporting · {percent}%").
  String exportingProgress;

  /// Lease text without progress ("Working").
  String working;

  /// Lease text with progress ("Working · {percent}%").
  String workingProgress;

  /// The Cancel action.
  String cancel;

  /// Completion title after a detached save to the gallery ("Saved to Gallery").
  String savedToGallery;

  /// Completion title otherwise ("Export finished").
  String exportFinished;

  /// Further jobs not shown ("+{count} more").
  String more;

  String progressChannelName;
  String progressChannelDescription;
  String doneChannelName;
  String doneChannelDescription;
}

/// `EditorCapabilities` (ARCH §12.5, D-14, D-22, D-40).
class CapabilitiesMsg {
  CapabilitiesMsg({
    required this.supported,
    this.unsupportedReason,
    required this.tier,
    required this.lowMemoryDevice,
    required this.h264Encode,
    required this.hevcEncode,
    required this.hardwareH264,
    required this.hardwareHevc,
    required this.movContainer,
    required this.maxExportWidth,
    required this.maxExportHeight,
    required this.maxFpsByHeight,
    required this.maxConcurrentVideoLayers,
    required this.maxVisualSequences,
    required this.maxTextureSize,
    required this.maxPreviewLongSide,
    required this.backgroundKind,
    required this.backgroundGpu,
    required this.voiceRecording,
    required this.proxiesRecommended,
    required this.holdFrame,
    required this.fpsUpconversion,
    required this.externalDrop,
    required this.minSpeed,
    required this.maxSpeed,
    required this.maxAudioSpeed,
    required this.maxLutSize,
    required this.planVersions,
  });

  bool supported;

  /// `UnsupportedReasons` value when not supported.
  String? unsupportedReason;
  DeviceTierMsg tier;
  bool lowMemoryDevice;
  bool h264Encode;
  bool hevcEncode;
  bool hardwareH264;
  bool hardwareHevc;
  bool movContainer;
  int maxExportWidth;
  int maxExportHeight;

  /// Highest export fps by output short side.
  Map<int, int> maxFpsByHeight;

  /// D-14 cap 1: 2 | 3 | 4 | 6.
  int maxConcurrentVideoLayers;

  /// D-14 cap 2: Android 2 | 3 | 4 | 6 by tier (AND-01 V-N25; the AND-16 preview engine needs two
  /// decoders per slot, so each value is further capped at (codec maxSupportedInstances - 2) / 2);
  /// iOS 16.
  int maxVisualSequences;

  /// `GL_MAX_TEXTURE_SIZE` on Android, 16384 on iOS.
  int maxTextureSize;

  /// 640 | 960 | 1280 | 1920.
  int maxPreviewLongSide;
  BackgroundExportKindMsg backgroundKind;
  bool backgroundGpu;
  bool voiceRecording;
  bool proxiesRecommended;
  bool holdFrame;
  /// Export rates above the source rate are honoured (true on both platforms; Android: AND-01
  /// V-N15, the clock band repeats an adjacent source frame).
  bool fpsUpconversion;
  bool externalDrop;
  double minSpeed;
  double maxSpeed;
  double maxAudioSpeed;
  int maxLutSize;

  /// RenderPlan versions the engine decodes.
  List<int> planVersions;
}

/// `EditCompatibility`: `editable`, or `NotEditable(code, message)`.
class CompatibilityMsg {
  CompatibilityMsg({required this.editable, this.code, this.message});

  bool editable;

  /// `container_unsupported_ios`, `codec_unsupported`, `protected_content`, `not_found`, ...
  String? code;

  /// Diagnostic text without paths.
  String? message;
}

/// `ResolvedMedia` / `EngineMedia` (core, D-27).
class ResolvedMediaMsg {
  ResolvedMediaMsg({required this.uri, required this.fingerprint, this.bookmark, required this.isProxy});

  /// `file://` or `content://` URI.
  String uri;

  /// quickHash of the original (cache key).
  String fingerprint;

  /// iOS security-scoped bookmark; access is refcounted natively.
  Uint8List? bookmark;
  bool isProxy;
}

/// A file to stat or hash: a URI plus the iOS bookmark that grants access to it, if any.
class MediaRefMsg {
  MediaRefMsg({required this.uri, this.bookmark});

  String uri;
  Uint8List? bookmark;
}

/// `MediaProbe` (core, D-27).
class ProbeMsg {
  ProbeMsg({
    required this.kind,
    required this.durationUs,
    required this.hasVideo,
    required this.hasAudio,
    this.width,
    this.height,
    required this.rotation,
    this.nominalFrameRate,
    this.nominalFps,
    required this.variableFrameRate,
    this.container,
    this.videoCodec,
    this.audioCodec,
    required this.audioStreams,
    this.channels,
    this.sampleRate,
    this.bitDepth,
    required this.transfer,
    required this.sizeBytes,
    required this.editable,
    required this.issues,
  });

  MediaKindMsg kind;
  int durationUs;
  bool hasVideo;
  bool hasAudio;

  /// Display size (rotation applied).
  int? width;
  int? height;

  /// 0 | 90 | 180 | 270.
  int rotation;

  /// Integer project rate nearest to the source rate (29.97 -> 30).
  int? nominalFrameRate;

  /// Measured average fps (display only).
  double? nominalFps;
  bool variableFrameRate;
  String? container;
  String? videoCodec;
  String? audioCodec;
  int audioStreams;
  int? channels;
  int? sampleRate;
  int? bitDepth;
  ColorTransferMsg transfer;
  int sizeBytes;
  bool editable;

  /// Machine-readable issue codes.
  List<String> issues;
}

/// `PreviewConfig` (ARCH §12.2).
class PreviewConfigMsg {
  PreviewConfigMsg({
    required this.canvasWidth,
    required this.canvasHeight,
    required this.fps,
    required this.quality,
    required this.useProxies,
  });

  int canvasWidth;
  int canvasHeight;
  int fps;
  PreviewQualityMsg quality;
  bool useProxies;
}

/// Reply of `PreviewHostApi.open`.
class PreviewOpenedMsg {
  PreviewOpenedMsg({required this.sessionId, required this.textureId});

  String sessionId;
  int textureId;
}

/// `PlanAck` (ARCH §12.2).
class PlanAckMsg {
  PlanAckMsg({required this.rev, required this.structural, required this.applyMs});

  int rev;
  bool structural;
  int applyMs;
}

/// Loop range of `play` (plan µs, half-open).
class LoopMsg {
  LoopMsg({required this.startUs, required this.endUs});

  int startUs;
  int endUs;
}

/// `SeekAck` (ARCH §12.2, D-35).
class SeekAckMsg {
  SeekAckMsg({required this.requestedUs, required this.displayedFrameTimeUs, required this.displayedFrame, required this.seq});

  int requestedUs;

  /// `timeOfFrame(displayedFrame)`.
  int displayedFrameTimeUs;
  int displayedFrame;
  int seq;
}

/// `PreviewEditingMode` (ARCH §12.2); [itemId] is set for `cropSource` and `matte`.
class EditingModeMsg {
  EditingModeMsg({required this.kind, this.itemId});

  EditingModeKindMsg kind;
  String? itemId;
}

/// A colour with components in 0..1 (`sampleColor`).
class ColorMsg {
  ColorMsg({required this.red, required this.green, required this.blue, required this.alpha});

  double red;
  double green;
  double blue;
  double alpha;
}

/// `LookSpec` (ARCH §12.2).
class LookSpecMsg {
  LookSpecMsg({required this.id, required this.lutUri, required this.lutSize, required this.intensity});

  String id;

  /// `file://` URI of the `.vlut`.
  String lutUri;
  int lutSize;
  double intensity;
}

/// `ThumbnailRequest` (ARCH §12.3).
class ThumbnailRequestMsg {
  ThumbnailRequestMsg({
    required this.media,
    required this.intervalMs,
    required this.tileIndex,
    required this.heightPx,
    required this.framesPerTile,
    required this.proxy,
  });

  ResolvedMediaMsg media;
  int intervalMs;
  int tileIndex;
  int heightPx;
  int framesPerTile;
  bool proxy;
}

/// `ThumbnailTile` (ARCH §12.3): one JPEG strip.
class ThumbnailTileMsg {
  ThumbnailTileMsg({required this.encoded, required this.frames, required this.frameWidthPx});

  Uint8List encoded;
  int frames;
  int frameWidthPx;
}

/// `JobsHostApi.startJob` request. Fields by kind: waveform (media, audioStream), proxy (media),
/// reverse (media, sourceStartUs, sourceEndUs, outputPath), freeze (media, sourceTimeUs,
/// outputPath), speechAudio (media, sourceStartUs, sourceEndUs, outputPath, audioStream),
/// renderPreview (plan, outputPath inside `<cache>/danaview/editor/renders/`; [media] is unused
/// and carries the output file, D-45).
class JobRequestMsg {
  JobRequestMsg({
    required this.kind,
    required this.media,
    required this.priority,
    this.audioStream,
    this.sourceStartUs,
    this.sourceEndUs,
    this.sourceTimeUs,
    this.outputPath,
    this.plan,
  });

  JobKindMsg kind;
  ResolvedMediaMsg media;
  JobPriorityMsg priority;
  int? audioStream;
  int? sourceStartUs;
  int? sourceEndUs;
  int? sourceTimeUs;
  String? outputPath;

  /// renderPreview: the range plan as UTF-8 JSON (`PlanTransport.encodePlan`; a preview plan cut
  /// to the range, times relative to its start).
  Uint8List? plan;
}

/// `RenderedRange` (ARCH §12.2, D-45): a render-preview file covering `[startUs, endUs)` of the
/// session's plan.
class RenderedRangeMsg {
  RenderedRangeMsg({required this.startUs, required this.endUs, required this.uri, required this.hash});

  int startUs;
  int endUs;

  /// `file://` URI of a file in `<cache>/danaview/editor/renders/`.
  String uri;

  /// CORE-37 range hash the file was rendered for.
  String hash;
}

/// `PowerState` (ARCH §12.4, D-45).
class PowerStateMsg {
  PowerStateMsg({required this.charging, required this.lowPowerMode});

  bool charging;
  bool lowPowerMode;
}

/// `GeneratedAsset` (proxy, reverse, freeze).
class GeneratedAssetMsg {
  GeneratedAssetMsg({required this.path, required this.sizeBytes, this.durationUs});

  String path;
  int sizeBytes;
  int? durationUs;
}

/// `WaveformPeaks`: interleaved int8 (min, max) pairs, sent as bytes.
class WaveformPeaksMsg {
  WaveformPeaksMsg({required this.minMax, required this.durationUs, required this.pairsPerSecond});

  /// Int8 values reinterpreted as bytes.
  Uint8List minMax;
  int durationUs;
  int pairsPerSecond;
}

/// `ExtractedSpeechAudio` (16 kHz s16 mono WAV).
class ExtractedSpeechAudioMsg {
  ExtractedSpeechAudioMsg({
    required this.path,
    required this.frames,
    required this.durationUs,
    required this.sourceChannels,
    required this.sourceSampleRate,
    required this.codec,
  });

  String path;
  int frames;
  int durationUs;
  int sourceChannels;
  int sourceSampleRate;
  String codec;
}

/// `EncodeSettings` (core, D-27).
class EncodeSettingsMsg {
  EncodeSettingsMsg({
    required this.container,
    required this.codec,
    required this.width,
    required this.height,
    required this.fps,
    required this.videoBitrate,
    required this.audioBitrate,
    required this.audioSampleRate,
    required this.audioChannels,
    required this.keyframeIntervalMs,
    required this.stripLocation,
  });

  ExportContainerMsg container;
  VideoCodecMsg codec;
  int width;
  int height;
  int fps;
  int videoBitrate;
  int audioBitrate;
  int audioSampleRate;
  int audioChannels;
  int keyframeIntervalMs;
  bool stripLocation;
}

/// `ExportWarning` (ARCH §12.4).
class ExportWarningMsg {
  ExportWarningMsg({required this.code, required this.message});

  String code;
  String message;
}

/// `ExportPreflight` (ARCH §12.4).
class ExportPreflightMsg {
  ExportPreflightMsg({required this.ok, this.maxHeightForPlan, required this.warnings});

  bool ok;
  int? maxHeightForPlan;
  List<ExportWarningMsg> warnings;
}

/// `ExportProgress` (ARCH §12.4).
class ExportProgressMsg {
  ExportProgressMsg({
    required this.phase,
    required this.fraction,
    required this.framesDone,
    required this.framesTotal,
    required this.backgrounded,
    required this.pausedInBackground,
    required this.warnings,
  });

  ExportPhaseMsg phase;
  double fraction;
  int framesDone;
  int framesTotal;
  bool backgrounded;
  bool pausedInBackground;
  List<ExportWarningMsg> warnings;
}

/// `ExportResult` (ARCH §12.4).
class ExportResultMsg {
  ExportResultMsg({
    required this.path,
    required this.bytes,
    required this.durationUs,
    required this.videoEncoderName,
    required this.hardwareEncoder,
  });

  String path;
  int bytes;
  int durationUs;
  String videoEncoderName;
  bool hardwareEncoder;
}

/// One entry of `ExportHostApi.activeJobs` (ARCH §12.4, D-22, D-39). Fields by state: running
/// (none), resumable (doneFraction), interrupted (none), completedWhileDetached (result when the
/// file was kept, savedToGallery, savedUri, settings).
class ExportJobRecordMsg {
  ExportJobRecordMsg({
    required this.jobId,
    required this.state,
    this.doneFraction,
    this.result,
    required this.savedToGallery,
    this.savedUri,
    this.settings,
  });

  String jobId;
  ExportJobStateKindMsg state;
  double? doneFraction;
  ExportResultMsg? result;
  bool savedToGallery;
  String? savedUri;
  EncodeSettingsMsg? settings;
}

/// Result of a finished job (`jobDone` event): the field matching [kind] is set.
class JobResultMsg {
  JobResultMsg({required this.kind, this.asset, this.peaks, this.speech, this.exportResult});

  JobKindMsg kind;

  /// proxy, reverse, freeze.
  GeneratedAssetMsg? asset;

  /// waveform.
  WaveformPeaksMsg? peaks;

  /// speechAudio.
  ExtractedSpeechAudioMsg? speech;

  /// export.
  ExportResultMsg? exportResult;
}

/// `RecordedAsset` (ARCH §12.4).
class RecordedAssetMsg {
  RecordedAssetMsg({required this.path, required this.durationUs, required this.startLatencyUs});

  String path;
  int durationUs;
  int startLatencyUs;
}

/// `MediaPickRequest` (ARCH §12.4).
class MediaPickRequestMsg {
  MediaPickRequestMsg({required this.source, required this.kinds, required this.multiple});

  MediaPickSourceMsg source;
  List<MediaPickKindMsg> kinds;
  bool multiple;
}

/// `PickedMedia` (core, ARCH §9.1).
class PickedMediaMsg {
  PickedMediaMsg({
    required this.uri,
    required this.displayName,
    required this.origin,
    required this.isTemporaryCopy,
    this.bookmark,
    this.sizeBytes,
  });

  String uri;
  String displayName;
  PickOriginMsg origin;

  /// App-owned copy under `work/picks/` or `work/drops/`.
  bool isTemporaryCopy;
  Uint8List? bookmark;
  int? sizeBytes;
}

/// `FileHandoffResult` (ARCH §12.4).
class FileHandoffResultMsg {
  FileHandoffResultMsg({required this.outcome, this.savedUri});

  FileHandoffOutcomeMsg outcome;
  String? savedUri;
}

/// Result of resolving an iOS security-scoped bookmark.
class ResolvedBookmarkMsg {
  ResolvedBookmarkMsg({required this.uri, required this.stale, this.refreshedBookmark});

  String uri;

  /// The bookmark was stale; [refreshedBookmark] replaces it when it could be recreated.
  bool stale;
  Uint8List? refreshedBookmark;
}

/// `MediaStat` (core).
class MediaStatMsg {
  MediaStatMsg({required this.sizeBytes, this.modifiedMs});

  int sizeBytes;
  int? modifiedMs;
}

/// `PreviewClock` sample (ARCH §12.2).
class ClockMsg {
  ClockMsg({required this.timeUs, required this.playing, required this.rate, required this.seq});

  /// `timeOfFrame(k)` of the displayed frame (D-35).
  int timeUs;
  bool playing;
  double rate;

  /// seq of the last command this sample reflects.
  int seq;
}

/// A typed engine failure (`EngineFailure`) carried by events.
class FailureMsg {
  FailureMsg({required this.code, required this.message, this.itemId, this.mediaFingerprint, required this.retryable});

  /// `EngineErrorCode.name`; unknown names map to `internal`.
  String code;

  /// Debug text without paths.
  String message;
  String? itemId;
  String? mediaFingerprint;
  bool retryable;
}

/// `PreviewEvent` (ARCH §12.2): [quality] for `degraded`, [width]/[height] for `frameSize` and
/// `firstFrame`, [failure] for `failed`.
class PreviewEventMsg {
  PreviewEventMsg({required this.kind, this.quality, this.width, this.height, this.failure});

  PreviewEventKindMsg kind;
  PreviewQualityMsg? quality;
  int? width;
  int? height;
  FailureMsg? failure;
}

/// `EngineSignal` (ARCH §12.1): [thermalLevel] for `thermal`, [powerState] for
/// `powerStateChanged`.
class SignalMsg {
  SignalMsg({required this.kind, this.thermalLevel, this.powerState});

  SignalKindMsg kind;
  ThermalLevelMsg? thermalLevel;
  PowerStateMsg? powerState;
}

/// `ExternalDrop` (ARCH §12.4, D-18): position in logical px relative to the Flutter view.
class DropMsg {
  DropMsg({required this.items, required this.x, required this.y});

  List<PickedMediaMsg> items;
  double x;
  double y;
}

/// One multiplexed engine event; [kind] says which payload field is set.
class EngineEventMsg {
  EngineEventMsg({
    required this.kind,
    this.sessionId,
    this.jobId,
    this.clock,
    this.previewEvent,
    this.progress,
    this.jobDone,
    this.failure,
    this.exportProgress,
    this.recorderLevel,
    this.interruption,
    this.signal,
    this.drop,
    this.recording,
  });

  EngineEventKindMsg kind;

  /// Preview session (clock, preview, session failures).
  String? sessionId;

  /// Job, export, recording or background lease id.
  String? jobId;
  ClockMsg? clock;
  PreviewEventMsg? previewEvent;
  double? progress;
  JobResultMsg? jobDone;
  FailureMsg? failure;
  ExportProgressMsg? exportProgress;
  double? recorderLevel;
  RecordingInterruptionMsg? interruption;
  SignalMsg? signal;
  DropMsg? drop;

  /// `recordingChanged` (INT-07): whether a voice recording is capturing now.
  bool? recording;
}

// ---------------------------------------------------------------------------------------------
// Host APIs
// ---------------------------------------------------------------------------------------------

/// Engine root (ARCH §12.1).
@HostApi()
abstract class EngineHostApi {
  /// Hands the Dart-supplied roots to the engine. Idempotent (a Dart hot restart calls it again).
  @asyncCallback
  void initialize(EngineConfigMsg config);

  @asyncCallback
  CapabilitiesMsg capabilities();

  /// <= 300 ms.
  @asyncCallback
  CompatibilityMsg compatibility(String uri);

  @asyncCallback
  ProbeMsg probe(ResolvedMediaMsg media);

  /// Free bytes on the volume of [path].
  @asyncCallback
  int freeBytes(String path);

  /// Synchronous on the native side; drops caches per [level].
  void trimCaches(CacheTrimLevelMsg level);
}

/// Live preview sessions (ARCH §12.2, §13).
@HostApi()
abstract class PreviewHostApi {
  @asyncCallback
  PreviewOpenedMsg open(PreviewConfigMsg config);

  /// [plan] is UTF-8 JSON (`PlanTransport.encodePlan`).
  @asyncCallback
  PlanAckMsg setPlan(String sessionId, Uint8List plan);

  /// [patch] is UTF-8 JSON; fails with `planOutOfSync` when `patch.from` != the engine revision.
  @asyncCallback
  PlanAckMsg applyPatch(String sessionId, Uint8List patch);

  /// Fire-and-forget; coalesced natively to one per frame. [params] is UTF-8 JSON.
  void setTransient(String sessionId, String itemId, Uint8List params);

  /// Fire-and-forget.
  void clearTransient(String sessionId, String itemId);

  /// Returns the command seq.
  @asyncCallback
  int play(String sessionId, LoopMsg? loop);

  /// Returns the command seq.
  @asyncCallback
  int pause(String sessionId);

  /// Exact seeks reply after the frame is in the texture (D-35).
  @asyncCallback
  SeekAckMsg seek(String sessionId, int timeUs, bool exact);

  @asyncCallback
  void setQuality(String sessionId, PreviewQualityMsg quality);

  @asyncCallback
  void setUseProxies(String sessionId, bool on);

  /// Replaces the session's rendered ranges (D-45; sorted, non-overlapping). Fails with
  /// `planInvalid` for an invalid list. The engine drops a range when an applied patch touches it
  /// and every range on `setPlan`, until the next call.
  @asyncCallback
  void setRenderedRanges(String sessionId, List<RenderedRangeMsg> ranges);

  @asyncCallback
  void setEditingMode(String sessionId, EditingModeMsg mode);

  @asyncCallback
  void showSourceFrame(String sessionId, ResolvedMediaMsg media, int sourceTimeUs);

  /// 3x3 average of the pre-key source at the normalized point, or null.
  @asyncCallback
  ColorMsg? sampleColor(String sessionId, String itemId, double x, double y);

  /// JPEG stills, one per look.
  @asyncCallback
  List<Uint8List> renderLookStills(String sessionId, String itemId, List<LookSpecMsg> looks, int heightPx);

  @asyncCallback
  void refresh(String sessionId);

  /// RGBA of the displayed frame (debug/profile builds).
  @asyncCallback
  Uint8List debugCaptureFrame(String sessionId);

  /// Releases the session and its texture. Idempotent.
  @asyncCallback
  void dispose(String sessionId);
}

/// Thumbnails, waveforms and media jobs (ARCH §12.3, §15). Job progress, results and failures
/// arrive as events keyed by the returned job id.
@HostApi()
abstract class JobsHostApi {
  @asyncCallback
  ThumbnailTileMsg thumbnailTile(String requestId, ThumbnailRequestMsg request, ThumbPriorityMsg priority);

  /// Fire-and-forget; the pending `thumbnailTile` call fails with `cancelled`.
  void cancelThumbnail(String requestId);

  /// Returns the job id.
  @asyncCallback
  String startJob(JobRequestMsg request);

  /// Fire-and-forget; the job ends with a `cancelled` failure event and deletes partial output.
  void cancelJob(String jobId);

  /// Fire-and-forget.
  void setJobPriority(String jobId, JobPriorityMsg priority);

  @asyncCallback
  ProxyStatusMsg proxyStatus(String fingerprint);
}

/// Export (ARCH §12.4, §14, D-22, D-39). Progress, results and failures arrive as events keyed by
/// the job id.
@HostApi()
abstract class ExportHostApi {
  @asyncCallback
  ExportPreflightMsg preflight(Uint8List plan, EncodeSettingsMsg settings);

  /// Returns the job id (stable across process death). [texts] (INT-07) replaces the notification
  /// texts from `initialize` from this job on; null keeps them.
  @asyncCallback
  String start(
    Uint8List plan,
    EncodeSettingsMsg settings,
    String outputPath,
    String title,
    DetachedHandoffMsg whenDetached,
    ExportNotificationTextsMsg? texts,
  );

  /// Resumes an iOS segment-resumable job; `notSupportedOnDevice` elsewhere. Returns the job id.
  @asyncCallback
  String resume(String jobId);

  @asyncCallback
  void cancel(String jobId);

  /// Running jobs plus one-shot records until consumed.
  @asyncCallback
  List<ExportJobRecordMsg> activeJobs();

  /// Fire-and-forget; marks a one-shot record as seen.
  void consumeJobRecord(String jobId);
}

/// Voice recording (ARCH §12.4, §15). Levels and interruptions arrive as events keyed by the
/// recording id.
@HostApi()
abstract class RecorderHostApi {
  @asyncCallback
  MicPermissionMsg permission();

  @asyncCallback
  MicPermissionMsg requestPermission();

  @asyncCallback
  void openSettings();

  /// Returns the recording id.
  @asyncCallback
  String start(String outputPath);

  @asyncCallback
  RecordedAssetMsg stop(String recordingId);

  @asyncCallback
  void cancel(String recordingId);

  /// Whether a recording is capturing now (INT-07); changes arrive as `recordingChanged` events.
  @asyncCallback
  bool isRecording();
}

/// Pickers, file handoff, media access, background leases and drops (ARCH §12.4, §9, §15).
@HostApi()
abstract class PlatformHostApi {
  /// An empty list means cancelled.
  @asyncCallback
  List<PickedMediaMsg> pick(MediaPickRequestMsg request);

  @asyncCallback
  FileHandoffResultMsg saveToPhotos(String path);

  @asyncCallback
  FileHandoffResultMsg saveToFiles(String path, String suggestedName);

  @asyncCallback
  FileHandoffResultMsg share(String path);

  /// iOS security-scoped bookmark of [uri].
  @asyncCallback
  Uint8List createBookmark(String uri);

  @asyncCallback
  ResolvedBookmarkMsg resolveBookmark(Uint8List bookmark);

  /// Android `takePersistableUriPermission(READ)`.
  @asyncCallback
  void persistUriGrant(String uri);

  @asyncCallback
  void releaseUriGrant(String uri);

  @asyncCallback
  int remainingGrantBudget();

  /// Null when the file is missing; `permissionDenied` when access was lost.
  @asyncCallback
  MediaStatMsg? stat(MediaRefMsg media);

  @asyncCallback
  String quickHash(MediaRefMsg media);

  /// Dart only passes directories under the editor or speech roots (D-44).
  @asyncCallback
  void excludeFromBackup(String path);

  @asyncCallback
  bool requestNotificationPermission();

  /// Returns the lease id, or null when no lease is available.
  @asyncCallback
  String? acquireBackground(String title);

  @asyncCallback
  void updateBackground(String leaseId, double progress);

  @asyncCallback
  void releaseBackground(String leaseId);

  @asyncCallback
  void setDropTargetEnabled(bool enabled);

  /// Charging and low-power state (D-45); changes arrive as `powerStateChanged` signals.
  @asyncCallback
  PowerStateMsg powerState();

  /// Copies a picked item that cannot be kept by reference (INT-07: an Android `content://` URI
  /// without a persistable grant; on iOS a `file://` pick) into a new file inside [intoDir] (a
  /// directory under `<cache>/danaview/editor/work/`, created when missing) and returns its
  /// absolute path. An item that already is an app-owned temporary copy under `work/` is returned
  /// as is. Fails with `permissionDenied` when [intoDir] is outside `work/` or the source cannot be
  /// read, `mediaOffline` when it is gone, `diskFull`, `io`, or `notSupportedOnDevice` for a URI
  /// scheme the platform cannot copy.
  @asyncCallback
  String materializePick(String uri, String intoDir);
}

/// The single multiplexed event stream (ARCH §12.6).
@EventChannelApi()
abstract class EngineEventsApi {
  EngineEventMsg engineEvents();
}
