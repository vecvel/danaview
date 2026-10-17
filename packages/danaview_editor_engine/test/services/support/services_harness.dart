// OWNER: ENG-03
//
// Shared set-up of the ENG-03 service tests: a mocked native engine (MockEngineHost, ENG-01) that
// accepts `initialize`, its event sink, and EngineChannels without Dart-side rate limits (rate
// limiting is covered by test/glue/event_router_test.dart).

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_editor_engine/src/event_router.dart' show EventRateLimits;
import 'package:danaview_editor_engine/src/pigeon/engine_api.g.dart';
import 'package:danaview_editor_engine/src/pigeon/engine_channels.dart';
import 'package:danaview_editor_engine_api/danaview_editor_engine_api.dart';

import '../../glue/support/mock_engine_host.dart';

export '../../glue/support/mock_engine_host.dart';

/// Engine roots used by every service test.
const EditorEngineConfig servicesConfig = EditorEngineConfig(cacheRoot: '/c/danaview/editor', supportRoot: '/s/danaview/editor');

/// A media reference used by the tests.
const EngineMedia servicesMedia = EngineMedia(uri: 'file:///d/clip.mov', fingerprint: 'qh_1');

/// No rate limiting (samples are delivered as they arrive).
const EventRateLimits noRateLimits = EventRateLimits(clock: Duration.zero, progress: Duration.zero, recorderLevel: Duration.zero);

/// A mocked native engine plus the channels under test.
final class ServicesHarness {
  ServicesHarness._(this.host, this.events, this.channels);

  /// Installs the mock (accepting `initialize`) and creates channels over it.
  factory ServicesHarness({EditorEngineConfig config = servicesConfig}) {
    final host = MockEngineHost()..acceptInitialize();
    final events = host.installEvents();
    return ServicesHarness._(host, events, EngineChannels(config: config, limits: noRateLimits));
  }

  /// The mocked native side.
  final MockEngineHost host;

  /// Sink of native events.
  final StreamController<Object?> events;

  /// Channels the services use.
  final EngineChannels channels;

  /// Pushes [event] through the real event channel and lets it be delivered.
  Future<void> emit(EngineEventMsg event) async {
    events.add(event);
    await pumpEventQueue();
  }

  /// Arguments of every `api.method` call received.
  List<List<Object?>> argsOf(String api, String method) => host.args['$api.$method'] ?? const [];

  /// Releases the channels and the mock.
  Future<void> dispose() async {
    await channels.dispose();
    host.dispose();
  }
}

/// A `progress` event for job [jobId].
EngineEventMsg progressEvent(String jobId, double progress) =>
    EngineEventMsg(kind: EngineEventKindMsg.progress, jobId: jobId, progress: progress);

/// A `jobDone` event for job [jobId].
EngineEventMsg doneEvent(String jobId, JobResultMsg result) =>
    EngineEventMsg(kind: EngineEventKindMsg.jobDone, jobId: jobId, jobDone: result);

/// A `failure` event for job [jobId].
EngineEventMsg failureEvent(String jobId, String code, {bool retryable = false, String message = ''}) => EngineEventMsg(
      kind: EngineEventKindMsg.failure,
      jobId: jobId,
      failure: FailureMsg(code: code, message: message, retryable: retryable),
    );

/// Matches an [EngineError] with [code].
Matcher throwsEngineError(EngineErrorCode code) => throwsA(isA<EngineError>().having((e) => e.code, 'code', code));

/// Matches [EngineCancelled].
final Matcher throwsEngineCancelled = throwsA(isA<EngineCancelled>());
