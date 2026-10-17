// OWNER: ENG-06 [INTEGRATION] (written by ENG-01). FROZEN 2026-10-11 after the IOS-01/AND-01 spikes
// (D-42; no change was needed). Later changes need a new lead-approved [INTEGRATION] ticket.
// Amended by INT-06 (D-45): the render-preview job (`jobs.renderPreview`), rendered ranges
// (`PreviewSession.setRenderedRanges`) and the power state (`background.powerState` /
// `powerStateChanged`) reach native through the mobile services below; a `powerStateChanged`
// signal is not an EngineSignal, so [signals] filters it out. Until IOS-19 and AND-18 replace the
// native placeholders, all three fail with `notSupportedOnDevice`.
//
// The iOS + Android editor engine over the Pigeon surface (ARCH §12, §12.6). The engine root
// calls (initialize, capabilities, compatibility, probe, freeBytes, trimCaches, signals) are
// implemented here; preview sessions (ENG-02), jobs / recorder / platform services / media access
// (ENG-03) and export (ENG-04) are the mobile_* services, all sharing one [EngineChannels].
//
// While the native plugin registers no host API (the M0 placeholders of ENG-07/ENG-08), every
// call answers `channel-error`, which maps to `notSupportedOnDevice`: capabilities() reports
// `engine_not_available` and compatibility() `NotEditable('engine_not_available')`, so the editor
// shows its unsupported state instead of crashing.

import 'dart:async';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/services.dart' show BinaryMessenger;
import 'package:danaview_editor_engine_api/danaview_editor_engine_api.dart';

import 'event_router.dart';
import 'mobile_export.dart';
import 'mobile_jobs.dart';
import 'mobile_media_access.dart';
import 'mobile_platform_services.dart';
import 'mobile_preview_session.dart';
import 'mobile_recorder.dart';
import 'pigeon/conversions.dart';
import 'pigeon/engine_api.g.dart';
import 'pigeon/engine_channels.dart';

/// The iOS + Android editor engine. Only the app root constructs it (ARCH §4.1).
///
/// See ARCH §12.1, §12.6, BUILD_PLAN ENG-01.
final class MobileEditorEngine implements EditorEngine {
  /// Creates the engine for [config]. The other parameters are for tests: [binaryMessenger] and
  /// [messageChannelSuffix] reach every Pigeon host API, [events] replaces the native event
  /// stream, [now] the event router clock.
  MobileEditorEngine({
    required EditorEngineConfig config,
    @visibleForTesting BinaryMessenger? binaryMessenger,
    @visibleForTesting String messageChannelSuffix = '',
    @visibleForTesting Stream<EngineEventMsg> Function()? events,
    @visibleForTesting EventRateLimits limits = const EventRateLimits(),
    @visibleForTesting Duration Function()? now,
  }) : this.withChannels(
          EngineChannels(
            config: config,
            binaryMessenger: binaryMessenger,
            messageChannelSuffix: messageChannelSuffix,
            events: events,
            limits: limits,
            now: now,
          ),
        );

  /// Creates the engine over existing [channels] (tests of the mobile services).
  @visibleForTesting
  MobileEditorEngine.withChannels(this.channels);

  /// Host APIs, event router and roots shared with the mobile services.
  @visibleForTesting
  final EngineChannels channels;

  /// Engine directories.
  EditorEngineConfig get config => channels.config;

  EditorCapabilities? _caps;
  Future<EditorCapabilities>? _capsLoading;

  late final ThumbnailSource _thumbnails = MobileThumbnailSource(channels);
  late final WaveformSource _waveforms = MobileWaveformSource(channels);
  late final MediaJobs _jobs = MobileMediaJobs(channels);
  late final ExportService _exporter = MobileExportService(channels);
  late final VoiceRecorder _recorder = MobileVoiceRecorder(channels);
  late final MediaPicker _picker = MobileMediaPicker(channels);
  late final FileHandoff _files = MobileFileHandoff(channels);
  late final MediaAccess _access = MobileMediaAccess(channels);
  late final BackgroundWorkGuard _background = MobileBackgroundWorkGuard(channels);
  late final ExternalDropTarget _drops = MobileExternalDropTarget(channels);
  late final Stream<EngineSignal> _signals = channels.router.signals.map(signalFromMsg).where((s) => s != null).cast<EngineSignal>();

  /// The capabilities once loaded (null before the first [capabilities] call completes).
  EditorCapabilities? get cachedCapabilities => _caps;

  @override
  Future<EditorCapabilities> capabilities() {
    final cached = _caps;
    if (cached != null) return Future<EditorCapabilities>.value(cached);
    return _capsLoading ??= _loadCapabilities().whenComplete(() => _capsLoading = null);
  }

  Future<EditorCapabilities> _loadCapabilities() async {
    try {
      final msg = await channels.invoke(channels.engine.capabilities);
      return _caps = capabilitiesFromMsg(msg);
    } on EngineFailure catch (f) {
      if (f.code != EngineErrorCode.notSupportedOnDevice) rethrow;
      return _caps = EditorCapabilities.unsupported(UnsupportedReasons.engineNotAvailable);
    }
  }

  @override
  Future<EditCompatibility> compatibility(String pathOrUri) async {
    try {
      return compatibilityFromMsg(await channels.invoke(() => channels.engine.compatibility(pathOrUri)));
    } on EngineFailure catch (f) {
      if (f.code != EngineErrorCode.notSupportedOnDevice) rethrow;
      return const NotEditable(UnsupportedReasons.engineNotAvailable, 'the native editor engine is not available');
    }
  }

  @override
  Future<MediaProbe> probe(EngineMedia media) async => probeFromMsg(await channels.invoke(() => channels.engine.probe(mediaToMsg(media))));

  @override
  Future<PreviewSession> openPreview(PreviewConfig config) async {
    final opened = await channels.invoke(() => channels.preview.open(previewConfigToMsg(config)));
    return MobilePreviewSession(channels: channels, config: config, sessionId: opened.sessionId, textureId: opened.textureId);
  }

  @override
  ThumbnailSource get thumbnails => _thumbnails;

  @override
  WaveformSource get waveforms => _waveforms;

  @override
  MediaJobs get jobs => _jobs;

  @override
  ExportService get exporter => _exporter;

  /// Null until [capabilities] reported `voiceRecording` (ARCH §12.1).
  @override
  VoiceRecorder? get voiceRecorder => (_caps?.voiceRecording ?? false) ? _recorder : null;

  @override
  MediaPicker get picker => _picker;

  @override
  FileHandoff get files => _files;

  @override
  MediaAccess get access => _access;

  @override
  BackgroundWorkGuard get background => _background;

  @override
  ExternalDropTarget get drops => _drops;

  @override
  Future<int> freeBytes(String path) => channels.invoke(() => channels.engine.freeBytes(path));

  @override
  Stream<EngineSignal> get signals => _signals;

  /// Drops cached data. Without a native engine there is nothing to trim, so
  /// `notSupportedOnDevice` is ignored; other failures surface as [EngineFailure].
  @override
  Future<void> trimCaches(CacheTrimLevel level) async {
    try {
      await channels.invoke(() => channels.engine.trimCaches(cacheTrimLevelToMsg(level)));
    } on EngineFailure catch (f) {
      if (f.code != EngineErrorCode.notSupportedOnDevice) rethrow;
    }
  }
}
