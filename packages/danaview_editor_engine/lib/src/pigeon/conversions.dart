// OWNER: ENG-01 (then ENG-06)
//
// Conversions between the Pigeon messages (pigeons/engine_api.dart) and the engine API types
// (danaview_editor_engine_api, ARCH §12). Every enum mapping is an exhaustive switch, so a Pigeon or
// API change fails to compile here instead of mis-mapping at runtime. Used by MobileEditorEngine
// and the mobile services (ENG-02/03/04).

import 'dart:typed_data';
import 'dart:ui' show Color, Offset, Size;

import 'package:danaview_editor_core/model.dart'
    show ColorTransfer, FrameRate, MediaKind, MediaOrigin, MediaProbe, MediaStat, PickedMedia, ResolvedMedia, TimeRange;
import 'package:danaview_editor_engine_api/danaview_editor_engine_api.dart';

import '../error_mapper.dart' show failureFromMsg;
import 'engine_api.g.dart';

// ---------------------------------------------------------------------------------------------
// Engine root (ARCH §12.1, §12.5)
// ---------------------------------------------------------------------------------------------

/// [EditorCapabilities] from the native capabilities message.
EditorCapabilities capabilitiesFromMsg(CapabilitiesMsg m) => EditorCapabilities(
      supported: m.supported,
      unsupportedReason: m.supported ? null : (m.unsupportedReason ?? UnsupportedReasons.engineNotAvailable),
      tier: deviceTierFromMsg(m.tier),
      lowMemoryDevice: m.lowMemoryDevice,
      h264Encode: m.h264Encode,
      hevcEncode: m.hevcEncode,
      hardwareH264: m.hardwareH264,
      hardwareHevc: m.hardwareHevc,
      movContainer: m.movContainer,
      maxExportSize: Size(m.maxExportWidth.toDouble(), m.maxExportHeight.toDouble()),
      maxFpsByHeight: Map<int, int>.unmodifiable(m.maxFpsByHeight),
      maxConcurrentVideoLayers: m.maxConcurrentVideoLayers,
      maxVisualSequences: m.maxVisualSequences,
      maxTextureSize: m.maxTextureSize,
      maxPreviewLongSide: m.maxPreviewLongSide,
      backgroundKind: backgroundKindFromMsg(m.backgroundKind),
      backgroundGpu: m.backgroundGpu,
      voiceRecording: m.voiceRecording,
      proxiesRecommended: m.proxiesRecommended,
      holdFrame: m.holdFrame,
      fpsUpconversion: m.fpsUpconversion,
      externalDrop: m.externalDrop,
      minSpeed: m.minSpeed,
      maxSpeed: m.maxSpeed,
      maxAudioSpeed: m.maxAudioSpeed,
      maxLutSize: m.maxLutSize,
      planVersions: List<int>.unmodifiable(m.planVersions),
    );

/// The native capabilities message for [c] (fakes and tests of the glue).
CapabilitiesMsg capabilitiesToMsg(EditorCapabilities c) => CapabilitiesMsg(
      supported: c.supported,
      unsupportedReason: c.unsupportedReason,
      tier: deviceTierToMsg(c.tier),
      lowMemoryDevice: c.lowMemoryDevice,
      h264Encode: c.h264Encode,
      hevcEncode: c.hevcEncode,
      hardwareH264: c.hardwareH264,
      hardwareHevc: c.hardwareHevc,
      movContainer: c.movContainer,
      maxExportWidth: c.maxExportSize.width.round(),
      maxExportHeight: c.maxExportSize.height.round(),
      maxFpsByHeight: Map<int, int>.of(c.maxFpsByHeight),
      maxConcurrentVideoLayers: c.maxConcurrentVideoLayers,
      maxVisualSequences: c.maxVisualSequences,
      maxTextureSize: c.maxTextureSize,
      maxPreviewLongSide: c.maxPreviewLongSide,
      backgroundKind: backgroundKindToMsg(c.backgroundKind),
      backgroundGpu: c.backgroundGpu,
      voiceRecording: c.voiceRecording,
      proxiesRecommended: c.proxiesRecommended,
      holdFrame: c.holdFrame,
      fpsUpconversion: c.fpsUpconversion,
      externalDrop: c.externalDrop,
      minSpeed: c.minSpeed,
      maxSpeed: c.maxSpeed,
      maxAudioSpeed: c.maxAudioSpeed,
      maxLutSize: c.maxLutSize,
      planVersions: List<int>.of(c.planVersions),
    );

/// [DeviceTier] from its message.
DeviceTier deviceTierFromMsg(DeviceTierMsg m) => switch (m) {
      DeviceTierMsg.minimal => DeviceTier.minimal,
      DeviceTierMsg.low => DeviceTier.low,
      DeviceTierMsg.mid => DeviceTier.mid,
      DeviceTierMsg.high => DeviceTier.high,
    };

/// [DeviceTierMsg] for [t].
DeviceTierMsg deviceTierToMsg(DeviceTier t) => switch (t) {
      DeviceTier.minimal => DeviceTierMsg.minimal,
      DeviceTier.low => DeviceTierMsg.low,
      DeviceTier.mid => DeviceTierMsg.mid,
      DeviceTier.high => DeviceTierMsg.high,
    };

/// [BackgroundExportKind] from its message.
BackgroundExportKind backgroundKindFromMsg(BackgroundExportKindMsg m) => switch (m) {
      BackgroundExportKindMsg.noBackground => BackgroundExportKind.none,
      BackgroundExportKindMsg.paused => BackgroundExportKind.paused,
      BackgroundExportKindMsg.continued => BackgroundExportKind.continued,
      BackgroundExportKindMsg.foregroundService => BackgroundExportKind.foregroundService,
    };

/// [BackgroundExportKindMsg] for [k].
BackgroundExportKindMsg backgroundKindToMsg(BackgroundExportKind k) => switch (k) {
      BackgroundExportKind.none => BackgroundExportKindMsg.noBackground,
      BackgroundExportKind.paused => BackgroundExportKindMsg.paused,
      BackgroundExportKind.continued => BackgroundExportKindMsg.continued,
      BackgroundExportKind.foregroundService => BackgroundExportKindMsg.foregroundService,
    };

/// [EditCompatibility] from its message (`NotEditable` without a code gets `unsupported`).
EditCompatibility compatibilityFromMsg(CompatibilityMsg m) =>
    m.editable ? const Editable() : NotEditable(m.code ?? 'unsupported', m.message ?? '');

/// The message for [media].
ResolvedMediaMsg mediaToMsg(ResolvedMedia media) =>
    ResolvedMediaMsg(uri: media.uri, fingerprint: media.fingerprint, bookmark: media.bookmark, isProxy: media.isProxy);

/// [ResolvedMedia] from its message.
ResolvedMedia mediaFromMsg(ResolvedMediaMsg m) =>
    ResolvedMedia(uri: m.uri, fingerprint: m.fingerprint, bookmark: m.bookmark, isProxy: m.isProxy);

/// [MediaProbe] from its message.
MediaProbe probeFromMsg(ProbeMsg m) => MediaProbe(
      kind: switch (m.kind) {
        MediaKindMsg.video => MediaKind.video,
        MediaKindMsg.audio => MediaKind.audio,
        MediaKindMsg.image => MediaKind.image,
      },
      duration: m.durationUs,
      hasVideo: m.hasVideo,
      hasAudio: m.hasAudio,
      width: m.width,
      height: m.height,
      rotation: m.rotation,
      nominalFrameRate: switch (m.nominalFrameRate) {
        final int fps? when fps > 0 => FrameRate.fps(fps),
        _ => null,
      },
      nominalFps: m.nominalFps,
      variableFrameRate: m.variableFrameRate,
      container: m.container,
      videoCodec: m.videoCodec,
      audioCodec: m.audioCodec,
      audioStreams: m.audioStreams,
      channels: m.channels,
      sampleRate: m.sampleRate,
      bitDepth: m.bitDepth,
      transfer: switch (m.transfer) {
        ColorTransferMsg.sdr => ColorTransfer.sdr,
        ColorTransferMsg.hlg => ColorTransfer.hlg,
        ColorTransferMsg.pq => ColorTransfer.pq,
      },
      sizeBytes: m.sizeBytes,
      editable: m.editable,
      issues: m.issues,
    );

/// [CacheTrimLevelMsg] for [level].
CacheTrimLevelMsg cacheTrimLevelToMsg(CacheTrimLevel level) => switch (level) {
      CacheTrimLevel.memoryPressure => CacheTrimLevelMsg.memoryPressure,
      CacheTrimLevel.background => CacheTrimLevelMsg.background,
      CacheTrimLevel.clearAll => CacheTrimLevelMsg.clearAll,
    };

/// [EngineSignal] from its message, or null when a thermal signal carries no level.
EngineSignal? signalFromMsg(SignalMsg m) => switch (m.kind) {
      SignalKindMsg.memoryWarning => const MemoryWarningSignal(),
      SignalKindMsg.thermal => switch (m.thermalLevel) {
          null => null,
          ThermalLevelMsg.nominal => const ThermalSignal(ThermalLevel.nominal),
          ThermalLevelMsg.fair => const ThermalSignal(ThermalLevel.fair),
          ThermalLevelMsg.serious => const ThermalSignal(ThermalLevel.serious),
          ThermalLevelMsg.critical => const ThermalSignal(ThermalLevel.critical),
        },
    };

// ---------------------------------------------------------------------------------------------
// Preview (ARCH §12.2)
// ---------------------------------------------------------------------------------------------

/// The message for [config].
PreviewConfigMsg previewConfigToMsg(PreviewConfig config) => PreviewConfigMsg(
      canvasWidth: config.canvasWidth,
      canvasHeight: config.canvasHeight,
      fps: config.fps,
      quality: previewQualityToMsg(config.quality),
      useProxies: config.useProxies,
    );

/// [PreviewQualityMsg] for [q].
PreviewQualityMsg previewQualityToMsg(PreviewQuality q) => switch (q) {
      PreviewQuality.auto => PreviewQualityMsg.auto,
      PreviewQuality.full => PreviewQualityMsg.full,
      PreviewQuality.half => PreviewQualityMsg.half,
      PreviewQuality.quarter => PreviewQualityMsg.quarter,
    };

/// [PreviewQuality] from its message.
PreviewQuality previewQualityFromMsg(PreviewQualityMsg q) => switch (q) {
      PreviewQualityMsg.auto => PreviewQuality.auto,
      PreviewQualityMsg.full => PreviewQuality.full,
      PreviewQualityMsg.half => PreviewQuality.half,
      PreviewQualityMsg.quarter => PreviewQuality.quarter,
    };

/// [PlanAck] from its message.
PlanAck planAckFromMsg(PlanAckMsg m) => PlanAck(rev: m.rev, structural: m.structural, applyMs: m.applyMs);

/// [SeekAck] from its message.
SeekAck seekAckFromMsg(SeekAckMsg m) =>
    SeekAck(requested: m.requestedUs, displayedFrameTime: m.displayedFrameTimeUs, displayedFrame: m.displayedFrame, seq: m.seq);

/// The loop message for [range].
LoopMsg loopToMsg(TimeRange range) => LoopMsg(startUs: range.start, endUs: range.end);

/// The message for [mode].
EditingModeMsg editingModeToMsg(PreviewEditingMode mode) => switch (mode) {
      NormalPreviewMode() => EditingModeMsg(kind: EditingModeKindMsg.normal),
      CropSourceMode(:final item) => EditingModeMsg(kind: EditingModeKindMsg.cropSource, itemId: item),
      MatteMode(:final item) => EditingModeMsg(kind: EditingModeKindMsg.matte, itemId: item),
    };

/// [Color] from its message (components clamped to 0..1).
Color colorFromMsg(ColorMsg m) => Color.from(
      alpha: m.alpha.clamp(0.0, 1.0),
      red: m.red.clamp(0.0, 1.0),
      green: m.green.clamp(0.0, 1.0),
      blue: m.blue.clamp(0.0, 1.0),
    );

/// The message for [look].
LookSpecMsg lookSpecToMsg(LookSpec look) => LookSpecMsg(id: look.id, lutUri: look.lutUri, lutSize: look.lutSize, intensity: look.intensity);

/// [PreviewClock] from its message.
PreviewClock clockFromMsg(ClockMsg m) => PreviewClock(time: m.timeUs, playing: m.playing, rate: m.rate, seq: m.seq);

/// [PreviewEvent] from its message; null for `frameSize` (see [frameSizeFromMsg]) and for
/// malformed messages.
PreviewEvent? previewEventFromMsg(PreviewEventMsg m) => switch (m.kind) {
      PreviewEventKindMsg.firstFrame => const PreviewFirstFrame(),
      PreviewEventKindMsg.frameSize => null,
      PreviewEventKindMsg.stalled => const PreviewStalled(),
      PreviewEventKindMsg.recovered => const PreviewRecovered(),
      PreviewEventKindMsg.degraded => switch (m.quality) {
          final q? => PreviewDegraded(previewQualityFromMsg(q)),
          null => null,
        },
      PreviewEventKindMsg.surfaceLost => const PreviewSurfaceLost(),
      PreviewEventKindMsg.failed => switch (m.failure) {
          final f? => PreviewFailedEvent(failureFromMsg(f)),
          null => PreviewFailedEvent(EngineFailure.of(EngineErrorCode.internal, debugDetail: 'preview failed without a failure')),
        },
    };

/// The rendered frame size carried by a `frameSize` or `firstFrame` event, if any.
Size? frameSizeFromMsg(PreviewEventMsg m) => switch ((m.width, m.height)) {
      (final int w?, final int h?) when w > 0 && h > 0 => Size(w.toDouble(), h.toDouble()),
      _ => null,
    };

// ---------------------------------------------------------------------------------------------
// Thumbnails, waveforms and jobs (ARCH §12.3)
// ---------------------------------------------------------------------------------------------

/// The message for [request].
ThumbnailRequestMsg thumbnailRequestToMsg(ThumbnailRequest request) => ThumbnailRequestMsg(
      media: mediaToMsg(request.media),
      intervalMs: request.intervalMs,
      tileIndex: request.tileIndex,
      heightPx: request.heightPx,
      framesPerTile: request.framesPerTile,
      proxy: request.proxy,
    );

/// [ThumbPriorityMsg] for [p].
ThumbPriorityMsg thumbPriorityToMsg(ThumbPriority p) => switch (p) {
      ThumbPriority.visible => ThumbPriorityMsg.visible,
      ThumbPriority.prefetch => ThumbPriorityMsg.prefetch,
      ThumbPriority.background => ThumbPriorityMsg.background,
    };

/// [ThumbnailTile] from its message.
ThumbnailTile thumbnailTileFromMsg(ThumbnailTileMsg m) => ThumbnailTile(encoded: m.encoded, frames: m.frames, frameWidthPx: m.frameWidthPx);

/// [JobPriorityMsg] for [p].
JobPriorityMsg jobPriorityToMsg(JobPriority p) => switch (p) {
      JobPriority.interactive => JobPriorityMsg.interactive,
      JobPriority.normal => JobPriorityMsg.normal,
      JobPriority.background => JobPriorityMsg.background,
    };

/// [ProxyStatus] from its message.
ProxyStatus proxyStatusFromMsg(ProxyStatusMsg m) => switch (m) {
      ProxyStatusMsg.noProxy => ProxyStatus.none,
      ProxyStatusMsg.queued => ProxyStatus.queued,
      ProxyStatusMsg.running => ProxyStatus.running,
      ProxyStatusMsg.ready => ProxyStatus.ready,
      ProxyStatusMsg.failed => ProxyStatus.failed,
    };

/// [GeneratedAsset] from its message.
GeneratedAsset generatedAssetFromMsg(GeneratedAssetMsg m) => GeneratedAsset(path: m.path, sizeBytes: m.sizeBytes, duration: m.durationUs);

/// [WaveformPeaks] from its message (the bytes are reinterpreted as int8 without copying).
WaveformPeaks waveformPeaksFromMsg(WaveformPeaksMsg m) => WaveformPeaks(
      minMax: Int8List.view(m.minMax.buffer, m.minMax.offsetInBytes, m.minMax.lengthInBytes),
      duration: m.durationUs,
      pairsPerSecond: m.pairsPerSecond,
    );

/// [ExtractedSpeechAudio] from its message.
ExtractedSpeechAudio extractedSpeechAudioFromMsg(ExtractedSpeechAudioMsg m) => ExtractedSpeechAudio(
      path: m.path,
      frames: m.frames,
      duration: m.durationUs,
      sourceChannels: m.sourceChannels,
      sourceSampleRate: m.sourceSampleRate,
      codec: m.codec,
    );

// ---------------------------------------------------------------------------------------------
// Export (ARCH §12.4, D-22, D-39)
// ---------------------------------------------------------------------------------------------

/// The message for [s].
EncodeSettingsMsg encodeSettingsToMsg(EncodeSettings s) => EncodeSettingsMsg(
      container: switch (s.container) {
        ExportContainer.mp4 => ExportContainerMsg.mp4,
        ExportContainer.mov => ExportContainerMsg.mov,
      },
      codec: switch (s.codec) {
        VideoCodec.h264 => VideoCodecMsg.h264,
        VideoCodec.hevc => VideoCodecMsg.hevc,
      },
      width: s.width,
      height: s.height,
      fps: s.fps,
      videoBitrate: s.videoBitrate,
      audioBitrate: s.audioBitrate,
      audioSampleRate: s.audioSampleRate,
      audioChannels: s.audioChannels,
      keyframeIntervalMs: s.keyframeIntervalMs,
      stripLocation: s.stripLocation,
    );

/// [EncodeSettings] from its message.
EncodeSettings encodeSettingsFromMsg(EncodeSettingsMsg m) => EncodeSettings(
      container: switch (m.container) {
        ExportContainerMsg.mp4 => ExportContainer.mp4,
        ExportContainerMsg.mov => ExportContainer.mov,
      },
      codec: switch (m.codec) {
        VideoCodecMsg.h264 => VideoCodec.h264,
        VideoCodecMsg.hevc => VideoCodec.hevc,
      },
      width: m.width,
      height: m.height,
      fps: m.fps,
      videoBitrate: m.videoBitrate,
      audioBitrate: m.audioBitrate,
      audioSampleRate: m.audioSampleRate,
      audioChannels: m.audioChannels,
      keyframeIntervalMs: m.keyframeIntervalMs,
      stripLocation: m.stripLocation,
    );

/// [DetachedHandoffMsg] for [h].
DetachedHandoffMsg detachedHandoffToMsg(ExportDetachedHandoff h) => switch (h) {
      ExportDetachedHandoff.saveToGallery => DetachedHandoffMsg.saveToGallery,
      ExportDetachedHandoff.keepForLater => DetachedHandoffMsg.keepForLater,
    };

/// [ExportWarning] from its message.
ExportWarning exportWarningFromMsg(ExportWarningMsg m) => ExportWarning(m.code, m.message);

/// [ExportPreflight] from its message.
ExportPreflight exportPreflightFromMsg(ExportPreflightMsg m) => ExportPreflight(
      ok: m.ok,
      maxHeightForPlan: m.maxHeightForPlan,
      warnings: List<ExportWarning>.unmodifiable(m.warnings.map(exportWarningFromMsg)),
    );

/// [ExportPhase] from its message.
ExportPhase exportPhaseFromMsg(ExportPhaseMsg m) => switch (m) {
      ExportPhaseMsg.preparing => ExportPhase.preparing,
      ExportPhaseMsg.rendering => ExportPhase.rendering,
      ExportPhaseMsg.finishing => ExportPhase.finishing,
    };

/// [ExportProgress] from its message.
ExportProgress exportProgressFromMsg(ExportProgressMsg m) => ExportProgress(
      phase: exportPhaseFromMsg(m.phase),
      fraction: m.fraction.clamp(0.0, 1.0),
      framesDone: m.framesDone,
      framesTotal: m.framesTotal,
      backgrounded: m.backgrounded,
      pausedInBackground: m.pausedInBackground,
      warnings: List<ExportWarning>.unmodifiable(m.warnings.map(exportWarningFromMsg)),
    );

/// [ExportResult] from its message.
ExportResult exportResultFromMsg(ExportResultMsg m) => ExportResult(
      path: m.path,
      bytes: m.bytes,
      duration: m.durationUs,
      videoEncoderName: m.videoEncoderName,
      hardwareEncoder: m.hardwareEncoder,
    );

/// [ExportJobState] of one `activeJobs()` record. Running jobs are reattached with [reattach]
/// (ENG-04 builds the live job over the router); one-shot records map to their states (D-22,
/// D-39).
ExportJobState exportJobStateFromMsg(ExportJobRecordMsg m, {required ExportJob Function(String jobId) reattach}) => switch (m.state) {
      ExportJobStateKindMsg.running => ExportRunning(reattach(m.jobId)),
      ExportJobStateKindMsg.resumable => ExportResumable(m.jobId, doneFraction: (m.doneFraction ?? 0).clamp(0.0, 1.0)),
      ExportJobStateKindMsg.interrupted => ExportInterrupted(m.jobId),
      ExportJobStateKindMsg.completedWhileDetached => ExportCompletedWhileDetached(
          m.jobId,
          result: switch (m.result) {
            final r? => exportResultFromMsg(r),
            null => null,
          },
          savedToGallery: m.savedToGallery,
          savedUri: m.savedUri,
          settings: switch (m.settings) {
            final s? => encodeSettingsFromMsg(s),
            null => null,
          },
        ),
    };

// ---------------------------------------------------------------------------------------------
// Recording (ARCH §12.4)
// ---------------------------------------------------------------------------------------------

/// [MicPermission] from its message.
MicPermission micPermissionFromMsg(MicPermissionMsg m) => switch (m) {
      MicPermissionMsg.undetermined => MicPermission.undetermined,
      MicPermissionMsg.granted => MicPermission.granted,
      MicPermissionMsg.denied => MicPermission.denied,
      MicPermissionMsg.permanentlyDenied => MicPermission.permanentlyDenied,
    };

/// [RecordedAsset] from its message.
RecordedAsset recordedAssetFromMsg(RecordedAssetMsg m) =>
    RecordedAsset(path: m.path, durationUs: m.durationUs, startLatencyUs: m.startLatencyUs);

/// [RecordingInterruption] from its message.
RecordingInterruption recordingInterruptionFromMsg(RecordingInterruptionMsg m) => switch (m) {
      RecordingInterruptionMsg.interrupted => RecordingInterruption.interrupted,
      RecordingInterruptionMsg.routeChanged => RecordingInterruption.routeChanged,
      RecordingInterruptionMsg.deviceRemoved => RecordingInterruption.deviceRemoved,
    };

// ---------------------------------------------------------------------------------------------
// Platform services and media access (ARCH §12.4, §9)
// ---------------------------------------------------------------------------------------------

/// The message for [request].
MediaPickRequestMsg mediaPickRequestToMsg(MediaPickRequest request) => MediaPickRequestMsg(
      source: switch (request.source) {
        MediaPickSource.photos => MediaPickSourceMsg.photos,
        MediaPickSource.files => MediaPickSourceMsg.files,
      },
      kinds: [
        for (final k in MediaPickKind.values)
          if (request.kinds.contains(k))
            switch (k) {
              MediaPickKind.video => MediaPickKindMsg.video,
              MediaPickKind.audio => MediaPickKindMsg.audio,
              MediaPickKind.image => MediaPickKindMsg.image,
              MediaPickKind.lut => MediaPickKindMsg.lut,
              MediaPickKind.subtitle => MediaPickKindMsg.subtitle,
            },
      ],
      multiple: request.multiple,
    );

/// [PickedMedia] from its message.
PickedMedia pickedMediaFromMsg(PickedMediaMsg m) => PickedMedia(
      uri: m.uri,
      displayName: m.displayName,
      origin: switch (m.origin) {
        PickOriginMsg.photos => MediaOrigin.photos,
        PickOriginMsg.files => MediaOrigin.files,
        PickOriginMsg.drop => MediaOrigin.drop,
      },
      isTemporaryCopy: m.isTemporaryCopy,
      bookmark: m.bookmark,
      sizeBytes: m.sizeBytes,
    );

/// [FileHandoffResult] from its message.
FileHandoffResult fileHandoffResultFromMsg(FileHandoffResultMsg m) => FileHandoffResult(
      switch (m.outcome) {
        FileHandoffOutcomeMsg.done => FileHandoffOutcome.done,
        FileHandoffOutcomeMsg.cancelled => FileHandoffOutcome.cancelled,
        FileHandoffOutcomeMsg.denied => FileHandoffOutcome.denied,
        FileHandoffOutcomeMsg.failed => FileHandoffOutcome.failed,
      },
      savedUri: m.savedUri,
    );

/// [MediaStat] from its message.
MediaStat mediaStatFromMsg(MediaStatMsg m) => MediaStat(sizeBytes: m.sizeBytes, modifiedMs: m.modifiedMs);

/// [ExternalDrop] from its message (position in logical px).
ExternalDrop dropFromMsg(DropMsg m) =>
    ExternalDrop(items: List<PickedMedia>.unmodifiable(m.items.map(pickedMediaFromMsg)), position: Offset(m.x, m.y));
