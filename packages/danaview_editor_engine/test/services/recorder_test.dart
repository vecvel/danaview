// OWNER: ENG-03
//
// MobileVoiceRecorder / MobileRecordingSession over mocked channels (ARCH §12.4, §15):
// permissions, start, levels and interruptions from events (incl. events racing the start
// reply), stop / cancel idempotence and their races, failures.

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_editor_engine/src/mobile_recorder.dart';
import 'package:danaview_editor_engine/src/pigeon/engine_api.g.dart';
import 'package:danaview_editor_engine_api/danaview_editor_engine_api.dart';

import 'support/services_harness.dart';

const _out = '/s/danaview/editor/projects/p1/assets/recordings/r1.wav';

EngineEventMsg _level(String id, double v) => EngineEventMsg(kind: EngineEventKindMsg.recorderLevel, jobId: id, recorderLevel: v);

EngineEventMsg _interruption(String id, RecordingInterruptionMsg why) =>
    EngineEventMsg(kind: EngineEventKindMsg.interruption, jobId: id, interruption: why);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ServicesHarness h;
  late MobileVoiceRecorder recorder;
  Completer<String>? startGate;

  setUp(() {
    h = ServicesHarness();
    recorder = MobileVoiceRecorder(h.channels);
    startGate = null;
    h.host
      ..on('RecorderHostApi', 'start', (_) => startGate?.future ?? 'rec1')
      ..on('RecorderHostApi', 'stop', (args) => RecordedAssetMsg(path: _out, durationUs: 3000000, startLatencyUs: 21000))
      ..on('RecorderHostApi', 'cancel', (_) => null);
  });
  tearDown(() => h.dispose());

  test('permission, requestPermission and openSystemSettings map to the host API', () async {
    for (final (msg, value) in [
      (MicPermissionMsg.undetermined, MicPermission.undetermined),
      (MicPermissionMsg.granted, MicPermission.granted),
      (MicPermissionMsg.denied, MicPermission.denied),
      (MicPermissionMsg.permanentlyDenied, MicPermission.permanentlyDenied),
    ]) {
      h.host
        ..on('RecorderHostApi', 'permission', (_) => msg)
        ..on('RecorderHostApi', 'requestPermission', (_) => msg);
      expect(await recorder.permission(), value);
      expect(await recorder.requestPermission(), value);
    }
    h.host.on('RecorderHostApi', 'openSettings', (_) => null);
    await recorder.openSystemSettings();
    expect(h.host.count('RecorderHostApi', 'openSettings'), 1);
  });

  test('start sends the output path; levels (clamped) arrive; stop returns the RecordedAsset and closes the streams', () async {
    final session = await recorder.start(outputPath: _out) as MobileRecordingSession;
    expect(h.argsOf('RecorderHostApi', 'start').single, [_out]);
    expect(session.recordingId, 'rec1');
    final levels = <double>[];
    var levelsDone = false;
    var interruptionsDone = false;
    session.levels.listen(levels.add, onDone: () => levelsDone = true);
    session.interruptions.listen((_) {}, onDone: () => interruptionsDone = true);
    await h.emit(_level('rec1', 0.2));
    await h.emit(_level('rec1', 1.4));
    await h.emit(_level('other', 0.9));
    final asset = await session.stop();
    expect((asset.path, asset.durationUs, asset.startLatencyUs), (_out, 3000000, 21000));
    expect(levels, [0.2, 1.0]);
    await pumpEventQueue();
    expect((levelsDone, interruptionsDone, session.isClosed), (true, true, true));
    await h.emit(_level('rec1', 0.5)); // late: dropped
    expect(levels, [0.2, 1.0]);
  });

  test('levels sent before the start reply reached Dart are not lost', () async {
    startGate = Completer<String>();
    final starting = recorder.start(outputPath: _out);
    await pumpEventQueue();
    await h.emit(_level('rec9', 0.3));
    startGate!.complete('rec9');
    final session = await starting;
    final levels = <double>[];
    session.levels.listen(levels.add);
    await pumpEventQueue();
    expect(levels, [0.3]);
  });

  test('an interruption is reported, the file is kept and stop still returns it', () async {
    final session = await recorder.start(outputPath: _out) as MobileRecordingSession;
    final got = <RecordingInterruption>[];
    session.interruptions.listen(got.add);
    await h.emit(_interruption('rec1', RecordingInterruptionMsg.routeChanged));
    await h.emit(_interruption('rec1', RecordingInterruptionMsg.interrupted));
    await h.emit(_interruption('rec1', RecordingInterruptionMsg.deviceRemoved));
    expect(got, [RecordingInterruption.routeChanged, RecordingInterruption.interrupted, RecordingInterruption.deviceRemoved]);
    expect(session.wasInterrupted, isTrue);
    expect((await session.stop()).path, _out);
    expect(h.host.count('RecorderHostApi', 'cancel'), 0);
  });

  test('a failure event is delivered typed as an error on interruptions', () async {
    final session = await recorder.start(outputPath: _out);
    final errors = <Object>[];
    session.interruptions.listen((_) {}, onError: errors.add);
    await h.emit(failureEvent('rec1', 'diskFull'));
    expect(errors.single, isA<EngineError>().having((e) => e.code, 'code', EngineErrorCode.diskFull));
  });

  test('stop is idempotent (one native call); cancel after stop is a no-op', () async {
    final session = await recorder.start(outputPath: _out);
    final a = session.stop();
    final b = session.stop();
    expect(identical(a, b), isTrue);
    await a;
    await session.cancel();
    expect(h.host.count('RecorderHostApi', 'stop'), 1);
    expect(h.host.count('RecorderHostApi', 'cancel'), 0);
  });

  test('cancel is idempotent; stop after cancel throws EngineCancelled', () async {
    final session = await recorder.start(outputPath: _out) as MobileRecordingSession;
    await Future.wait([session.cancel(), session.cancel()]);
    expect(h.argsOf('RecorderHostApi', 'cancel'), [
      ['rec1']
    ]);
    await expectLater(session.stop(), throwsEngineCancelled);
    expect(h.host.count('RecorderHostApi', 'stop'), 0);
    expect(session.isClosed, isTrue);
  });

  test('cancel while stop is in flight waits for the stop and does not delete', () async {
    final stopGate = Completer<RecordedAssetMsg>();
    h.host.on('RecorderHostApi', 'stop', (_) => stopGate.future);
    final session = await recorder.start(outputPath: _out);
    final stopping = session.stop();
    var cancelled = false;
    final cancelling = session.cancel().then((_) => cancelled = true);
    await pumpEventQueue();
    expect(cancelled, isFalse);
    stopGate.complete(RecordedAssetMsg(path: _out, durationUs: 1, startLatencyUs: 0));
    await cancelling;
    expect((await stopping).path, _out);
    expect(h.host.count('RecorderHostApi', 'cancel'), 0);
  });

  test('start and stop failures are typed', () async {
    h.host.fail('RecorderHostApi', 'start', 'permissionDenied');
    await expectLater(recorder.start(outputPath: _out), throwsEngineError(EngineErrorCode.permissionDenied));

    h.host
      ..on('RecorderHostApi', 'start', (_) => 'rec2')
      ..on('RecorderHostApi', 'stop', (_) => throw PlatformException(code: 'io', message: 'finalize failed'));
    final session = await recorder.start(outputPath: _out) as MobileRecordingSession;
    await expectLater(session.stop(), throwsEngineError(EngineErrorCode.io));
    expect(session.isClosed, isTrue);
  });
}
