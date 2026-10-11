// OWNER: AI-07
//
// WhisperModel loading and Dart-side refcounting with FakeVwBindings under fake time: async load
// polling, shared leases, release 60 s after the last job or lease, immediate release on a memory
// warning, cancel tokens and typed load failures.

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vwish_whisper/src/runtime/native_runtime.dart';
import 'package:vwish_whisper/src/runtime/vw_bindings.dart';
import 'package:vwish_whisper/vwish_whisper.dart';

import 'fake_vw_bindings.dart';

const _req = WhisperTranscribeRequest(wavPath: 'a.wav', language: 'en', threads: 2);

final class _Load {
  _Load(Future<WhisperModel> f) {
    f.then<void>((m) {
      model = m;
    }, onError: (Object e) {
      error = e;
    });
  }

  WhisperModel? model;
  Object? error;
}

void main() {
  late FakeVwBindings fake;
  late NativeWhisperRuntime rt;

  setUp(() {
    fake = FakeVwBindings();
    rt = NativeWhisperRuntime(bindings: fake, device: WhisperDeviceChannel(enabled: false));
  });

  Future<void> finish(WidgetTester tester) async {
    await rt.dispose();
    await tester.pump(const Duration(seconds: 61));
  }

  testWidgets('loadModel polls the native state until ready and reports the model info', (tester) async {
    final l = _Load(rt.loadModel('/models/base.bin', options: const WhisperModelOptions(preferGpu: false)));
    final m = fake.lastModel;
    expect(m.path, '/models/base.bin');
    expect(m.params, const VwModelParams(useGpu: false));
    await tester.pump(const Duration(milliseconds: 200));
    expect(l.model, isNull, reason: 'still loading');
    m
      ..state = VwModelState.ready
      ..info = const VwModelInfoData(multilingual: true, nVocab: 51865, gpuUsed: false, gpuFallback: true);
    await tester.pump(const Duration(milliseconds: 50));
    expect(l.model, isNotNull);
    expect(l.model!.info.multilingual, isTrue);
    expect(l.model!.info.vocabSize, 51865);
    expect(l.model!.info.usesGpu, isFalse);
    expect(l.model!.info.gpuFallback, isTrue);
    expect(l.model!.isBusy, isFalse);
    await finish(tester);
  });

  testWidgets('load failures are typed and free the native handle', (tester) async {
    for (final (status, kind) in [
      (VwStatus.modelLoad, WhisperErrorKind.modelLoadFailed),
      (VwStatus.invalidArg, WhisperErrorKind.modelLoadFailed),
      (VwStatus.oom, WhisperErrorKind.outOfMemory),
      (VwStatus.io, WhisperErrorKind.io),
    ]) {
      final l = _Load(rt.loadModel('/models/x$status.bin'));
      fake.lastModel
        ..state = VwModelState.failed
        ..error = VwModelErrorData(status, 'bad ggml magic');
      await tester.pump(const Duration(milliseconds: 50));
      expect(l.error, isA<WhisperException>().having((e) => e.kind, 'kind', kind), reason: '$status');
      expect((l.error! as WhisperException).detail, contains('bad ggml magic'));
      expect(fake.lastModel.released, isTrue);
      expect(rt.debugModelCount, 0);
    }
    // vw_model_load rejecting the arguments outright.
    final l = _Load(rt.loadModel(''));
    await tester.pump();
    expect(l.error, isA<WhisperException>().having((e) => e.kind, 'kind', WhisperErrorKind.modelLoadFailed));
    await finish(tester);
  });

  testWidgets('the same path and options share one native model; different options do not', (tester) async {
    final a = _Load(rt.loadModel('/m.bin'));
    final b = _Load(rt.loadModel('/m.bin'));
    final c = _Load(rt.loadModel('/m.bin', options: const WhisperModelOptions(flashAttention: false)));
    expect(fake.models, hasLength(2));
    for (final m in fake.models.values) {
      m.state = VwModelState.ready;
    }
    await tester.pump(const Duration(milliseconds: 50));
    expect(a.model, isNotNull);
    expect(b.model, isNotNull);
    expect(c.model, isNotNull);
    expect(identical(a.model, b.model), isFalse, reason: 'separate leases');

    // A busy model is busy for every lease.
    a.model!.transcribe(_req);
    await tester.pump();
    expect(b.model!.isBusy, isTrue);
    expect(c.model!.isBusy, isFalse);

    // A load after the model is ready returns at once without a new native load.
    final d = _Load(rt.loadModel('/m.bin'));
    await tester.pump();
    expect(d.model, isNotNull);
    expect(fake.models, hasLength(2));
    await finish(tester);
  });

  testWidgets('the model is released 60 s after the last lease and job, and reused before that', (tester) async {
    final l = _Load(rt.loadModel('/m.bin'));
    fake.lastModel.state = VwModelState.ready;
    await tester.pump(const Duration(milliseconds: 50));
    final model = l.model!;
    final native = fake.lastModel;

    // A job keeps it alive after the lease is dropped.
    model.transcribe(_req);
    await tester.pump();
    await model.release();
    await model.release(); // idempotent
    await tester.pump(const Duration(seconds: 120));
    expect(native.released, isFalse, reason: 'job still running');

    fake.lastJob.state = VwJobState.succeeded;
    await tester.pump(const Duration(milliseconds: 250));
    await tester.pump(const Duration(seconds: 59));
    expect(native.released, isFalse);

    // Reloaded within the grace period: same native model, timer cancelled.
    final again = _Load(rt.loadModel('/m.bin'));
    await tester.pump();
    expect(again.model, isNotNull);
    expect(fake.models, hasLength(1));
    await tester.pump(const Duration(seconds: 120));
    expect(native.released, isFalse, reason: 'held by the new lease');

    await again.model!.release();
    await tester.pump(const Duration(seconds: 59));
    expect(native.released, isFalse);
    await tester.pump(const Duration(seconds: 1));
    expect(native.released, isTrue);
    expect(rt.debugModelCount, 0);

    // A released lease cannot start jobs.
    final stale = model.transcribe(_req);
    Object? err;
    unawaited(stale.result.then<void>((_) {}, onError: (Object e) {
      err = e;
    }));
    await tester.pump();
    expect(err, isA<WhisperException>());
    await finish(tester);
  });

  testWidgets('a memory warning releases idle models immediately, never held ones', (tester) async {
    final events = StreamController<Object?>.broadcast();
    const eventChannel = EventChannel('test/whisper/events');
    tester.binding.defaultBinaryMessenger.setMockStreamHandler(
      eventChannel,
      MockStreamHandler.inline(onListen: (args, sink) {
        events.stream.listen(sink.success);
      }),
    );
    rt = NativeWhisperRuntime(
      bindings: fake,
      device: WhisperDeviceChannel(method: const MethodChannel('test/whisper'), events: eventChannel),
    );
    final idle = _Load(rt.loadModel('/idle.bin'));
    final held = _Load(rt.loadModel('/held.bin'));
    for (final m in fake.models.values) {
      m.state = VwModelState.ready;
    }
    await tester.pump(const Duration(milliseconds: 50));
    await idle.model!.release();
    await tester.pump(const Duration(seconds: 5));
    expect(fake.models.values.first.released, isFalse, reason: 'within the grace period');

    events.add({'type': 'memoryWarning'});
    await tester.pump();
    expect(fake.models.values.first.released, isTrue);
    expect(fake.models.values.last.released, isFalse);
    expect(held.model!.isBusy, isFalse);

    // releaseIdleModels() does the same on demand.
    await held.model!.release();
    await rt.releaseIdleModels();
    expect(fake.models.values.last.released, isTrue);
    await finish(tester);
    await events.close();
    tester.binding.defaultBinaryMessenger.setMockStreamHandler(eventChannel, null);
  });

  testWidgets('a cancel token abandons the load; the native model is released once nobody waits', (tester) async {
    final token = WhisperCancelToken();
    final a = _Load(rt.loadModel('/m.bin', cancel: token));
    final b = _Load(rt.loadModel('/m.bin'));
    token.cancel();
    await tester.pump(const Duration(milliseconds: 50));
    expect(a.error, isA<WhisperException>().having((e) => e.kind, 'kind', WhisperErrorKind.cancelled));
    expect(fake.lastModel.released, isFalse, reason: 'another caller still waits');

    fake.lastModel.state = VwModelState.ready;
    await tester.pump(const Duration(milliseconds: 50));
    expect(b.model, isNotNull);

    // Sole waiter cancelled while loading: released right away (the loader frees it natively).
    final t2 = WhisperCancelToken();
    final c = _Load(rt.loadModel('/other.bin', cancel: t2));
    t2.cancel();
    await tester.pump(const Duration(milliseconds: 50));
    expect(c.error, isA<WhisperException>().having((e) => e.kind, 'kind', WhisperErrorKind.cancelled));
    expect(fake.lastModel.released, isTrue);

    // Already-cancelled token: no native load at all.
    final count = fake.models.length;
    final d = _Load(rt.loadModel('/x.bin', cancel: WhisperCancelToken()..cancel()));
    await tester.pump();
    expect(d.error, isA<WhisperException>());
    expect(fake.models, hasLength(count));
    await finish(tester);
  });
}
