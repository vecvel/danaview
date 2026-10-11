// OWNER: ENG-01 (then ENG-06)
//
// The Pigeon host APIs, the event router and the engine config, shared by MobileEditorEngine and
// every mobile service (ENG-02 preview, ENG-03 jobs/recorder/platform/access, ENG-04 export).
// Services call native through [EngineChannels.invoke], which initializes the engine once and
// maps every error to an `EngineFailure` (ARCH §12.5, §12.6, §19).

import 'package:flutter/services.dart';
import 'package:meta/meta.dart';
import 'package:danaview_editor_engine_api/danaview_editor_engine_api.dart';

import '../error_mapper.dart';
import '../event_router.dart';
import 'engine_api.g.dart';

/// Host APIs, the event router and the engine roots of one MobileEditorEngine.
///
/// See ARCH §12.6, §20.1, BUILD_PLAN ENG-01.
final class EngineChannels {
  /// Creates the channels. [binaryMessenger] and [messageChannelSuffix] go to every generated host
  /// API (tests pass a mock messenger); [events] replaces the generated `engineEvents()` stream
  /// and [now] the router clock (tests).
  EngineChannels({
    required this.config,
    BinaryMessenger? binaryMessenger,
    String messageChannelSuffix = '',
    Stream<EngineEventMsg> Function()? events,
    EventRateLimits limits = const EventRateLimits(),
    Duration Function()? now,
  })  : engine = EngineHostApi(binaryMessenger: binaryMessenger, messageChannelSuffix: messageChannelSuffix),
        preview = PreviewHostApi(binaryMessenger: binaryMessenger, messageChannelSuffix: messageChannelSuffix),
        jobs = JobsHostApi(binaryMessenger: binaryMessenger, messageChannelSuffix: messageChannelSuffix),
        export = ExportHostApi(binaryMessenger: binaryMessenger, messageChannelSuffix: messageChannelSuffix),
        recorder = RecorderHostApi(binaryMessenger: binaryMessenger, messageChannelSuffix: messageChannelSuffix),
        platform = PlatformHostApi(binaryMessenger: binaryMessenger, messageChannelSuffix: messageChannelSuffix),
        router = EngineEventRouter(events ?? (() => engineEvents(instanceName: messageChannelSuffix)), limits: limits, now: now);

  /// Engine roots handed to native by `EngineHostApi.initialize`.
  final EditorEngineConfig config;

  /// Engine root API (initialize, capabilities, compatibility, probe, freeBytes, trimCaches).
  final EngineHostApi engine;

  /// Preview sessions.
  final PreviewHostApi preview;

  /// Thumbnails and media jobs.
  final JobsHostApi jobs;

  /// Export.
  final ExportHostApi export;

  /// Voice recording.
  final RecorderHostApi recorder;

  /// Pickers, handoff, media access, leases, drops.
  final PlatformHostApi platform;

  /// Demultiplexed events.
  final EngineEventRouter router;

  Future<void>? _initializing;
  EngineFailure? _unavailable;

  /// Whether `initialize` succeeded.
  bool get isInitialized => _initialized;
  bool _initialized = false;

  /// The failure that made the engine unavailable (`notSupportedOnDevice`: no native host API),
  /// once known. Every later [invoke] fails fast with it.
  EngineFailure? get unavailable => _unavailable;

  /// Sends the roots to native once (concurrent callers share the call) and starts the event
  /// router. `notSupportedOnDevice` is remembered (the plugin registration cannot change at
  /// runtime); any other failure is retried by the next call.
  Future<void> ensureInitialized() {
    if (_initialized) return Future<void>.value();
    final known = _unavailable;
    if (known != null) return Future<void>.error(known);
    return _initializing ??= _initialize();
  }

  Future<void> _initialize() async {
    try {
      await guardEngineCall(() => engine.initialize(EngineConfigMsg(cacheRoot: config.cacheRoot, supportRoot: config.supportRoot)));
      _initialized = true;
      router.start();
    } on EngineFailure catch (f) {
      if (f.code == EngineErrorCode.notSupportedOnDevice) _unavailable = f;
      rethrow;
    } finally {
      _initializing = null;
    }
  }

  /// Initializes the engine if needed, then runs [call]; every error becomes an [EngineFailure].
  Future<T> invoke<T>(Future<T> Function() call) async {
    await ensureInitialized();
    return guardEngineCall(call);
  }

  /// Releases the router (tests).
  @visibleForTesting
  Future<void> dispose() => router.dispose();
}
