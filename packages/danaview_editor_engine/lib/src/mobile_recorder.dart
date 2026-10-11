// OWNER: ENG-03
//
// Voice recorder over `RecorderHostApi` (ARCH §12.4, §15). A RecordingSession listens to
// `channels.router.job(recordingId)` from the moment `start` answers (the router buffers events
// that race the reply): `recorderLevel` samples (<= 20 Hz, clamped to 0..1) feed [levels];
// `interruption` events feed [interruptions] (native has stopped and kept the file; `stop` still
// returns the RecordedAsset); a `failure` event is delivered as an error on [interruptions].
//
// Rules: `stop` and `cancel` are idempotent and the first one wins. `stop` after `cancel` throws
// `EngineCancelled`; `cancel` after `stop` is a no-op (the finished file belongs to the caller).
// Either one closes both streams and releases the event route.

import 'dart:async';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:danaview_editor_engine_api/danaview_editor_engine_api.dart';

import 'error_mapper.dart';
import 'pigeon/conversions.dart';
import 'pigeon/engine_api.g.dart';
import 'pigeon/engine_channels.dart';

/// Voice recorder over `RecorderHostApi` (ARCH §12.4, ENG-03).
final class MobileVoiceRecorder implements VoiceRecorder {
  /// Creates the recorder.
  MobileVoiceRecorder(this._channels);

  final EngineChannels _channels;

  @override
  Future<MicPermission> permission() async => micPermissionFromMsg(await _channels.invoke(_channels.recorder.permission));

  @override
  Future<MicPermission> requestPermission() async => micPermissionFromMsg(await _channels.invoke(_channels.recorder.requestPermission));

  @override
  Future<void> openSystemSettings() => _channels.invoke(_channels.recorder.openSettings);

  @override
  Future<RecordingSession> start({required String outputPath}) async {
    final id = await _channels.invoke(() => _channels.recorder.start(outputPath));
    return MobileRecordingSession._(_channels, id);
  }
}

/// A recording in progress (ARCH §12.4, ENG-03). See the file header for the rules.
final class MobileRecordingSession implements RecordingSession {
  MobileRecordingSession._(this._channels, this.recordingId) {
    _events = _channels.router.job(recordingId).listen(_onEvent);
  }

  final EngineChannels _channels;

  /// Native recording id.
  final String recordingId;

  late final StreamSubscription<EngineEventMsg> _events;
  final StreamController<double> _levels = StreamController<double>.broadcast();
  final StreamController<RecordingInterruption> _interruptions = StreamController<RecordingInterruption>.broadcast();
  Future<RecordedAsset>? _stop;
  Future<void>? _cancel;
  bool _closed = false;

  /// Whether native reported an interruption (the recording stopped by itself).
  bool get wasInterrupted => _interrupted;
  bool _interrupted = false;

  /// Whether the session's streams are closed.
  @visibleForTesting
  bool get isClosed => _closed;

  void _onEvent(EngineEventMsg e) {
    if (_closed) return;
    switch (e.kind) {
      case EngineEventKindMsg.recorderLevel:
        _levels.add((e.recorderLevel ?? 0).clamp(0.0, 1.0));
      case EngineEventKindMsg.interruption:
        _interrupted = true;
        _interruptions.add(recordingInterruptionFromMsg(e.interruption!));
      case EngineEventKindMsg.failure:
        _interruptions.addError(failureFromMsg(e.failure!));
      default:
        break;
    }
  }

  @override
  Stream<double> get levels => _levels.stream;

  @override
  Stream<RecordingInterruption> get interruptions => _interruptions.stream;

  @override
  Future<RecordedAsset> stop() {
    if (_cancel != null) return Future<RecordedAsset>.error(const EngineCancelled(debugDetail: 'recording was cancelled'));
    return _stop ??= _channels.invoke(() => _channels.recorder.stop(recordingId)).then(recordedAssetFromMsg).whenComplete(_close);
  }

  @override
  Future<void> cancel() {
    final stopping = _stop;
    if (stopping != null) return stopping.then<void>((_) {}, onError: (Object _) {});
    return _cancel ??= _channels.invoke(() => _channels.recorder.cancel(recordingId)).whenComplete(_close);
  }

  Future<void> _close() async {
    if (_closed) return;
    _closed = true;
    _channels.router.release(recordingId);
    await _events.cancel();
    await Future.wait([_levels.close(), _interruptions.close()]);
  }
}
