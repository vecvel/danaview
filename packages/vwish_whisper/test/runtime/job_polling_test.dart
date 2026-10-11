// OWNER: AI-07
//
// WhisperJob polling with FakeVwBindings under fake time (testWidgets' FakeAsync drives the
// 250 ms Timer.periodic): progress throttling, segment batching across polls, terminal states,
// DETECT results, forwarded controls, the Finalizer path, stall diagnostics and malformed JSON.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:vwish_whisper/src/runtime/native_job.dart';
import 'package:vwish_whisper/src/runtime/native_runtime.dart';
import 'package:vwish_whisper/src/runtime/vw_bindings.dart';
import 'package:vwish_whisper/vwish_whisper.dart';

import 'fake_vw_bindings.dart';

const _tick = Duration(milliseconds: 250);
const _req = WhisperTranscribeRequest(wavPath: '/tmp/a.wav', language: 'en', threads: 4);

final class _Harness {
  _Harness(this.tester) : fake = FakeVwBindings() {
    runtime = NativeWhisperRuntime(bindings: fake, device: WhisperDeviceChannel(enabled: false));
  }

  final WidgetTester tester;
  final FakeVwBindings fake;
  late final NativeWhisperRuntime runtime;

  Future<WhisperModel> model({bool multilingual = true}) async {
    WhisperModel? m;
    unawaited(runtime.loadModel('/m.bin').then((v) => m = v));
    fake.lastModel
      ..state = VwModelState.ready
      ..info = VwModelInfoData(multilingual: multilingual);
    await tester.pump(const Duration(milliseconds: 50));
    return m!;
  }

  /// Starts [job]'s collection and lets the native start complete.
  Future<_Recorder> record(WhisperJob job) async {
    final r = _Recorder(job);
    await tester.pump();
    return r;
  }

  Future<void> tick([int n = 1]) async {
    for (var k = 0; k < n; k++) {
      await tester.pump(_tick);
    }
  }

  Future<void> dispose() async {
    await runtime.dispose();
    await tester.pump(const Duration(seconds: 61));
  }
}

final class _Recorder {
  _Recorder(WhisperJob job) {
    job.updates.listen(updates.add, onDone: () => closed = true);
    job.result.then<void>((r) {
      result = r;
    }, onError: (Object e) {
      error = e;
    });
  }

  final List<WhisperJobUpdate> updates = [];
  WhisperJobResult? result;
  Object? error;
  bool closed = false;

  List<WhisperJobStatus> get statuses => updates.whereType<WhisperJobStatus>().toList();
  List<WhisperSegmentsAdded> get added => updates.whereType<WhisperSegmentsAdded>().toList();
}

void main() {
  testWidgets('status is polled every 250 ms and emitted at most once per poll, only on change', (tester) async {
    final h = _Harness(tester);
    final model = await h.model();
    final r = await h.record(model.transcribe(_req));
    final job = h.fake.lastJob;
    expect(job.params.language, 'en');
    expect(job.statusReads, 0, reason: 'first poll after 250 ms');

    await tester.pump(const Duration(milliseconds: 249));
    expect(job.statusReads, 0);
    await tester.pump(const Duration(milliseconds: 1));
    expect(job.statusReads, 1);
    expect(r.statuses, hasLength(1));

    // Unchanged samples are not re-emitted.
    await h.tick(3);
    expect(job.statusReads, 4);
    expect(r.statuses, hasLength(1));

    // Progress changes many times between polls: one sample per poll, the latest value.
    job.permille = 100;
    job.permille = 200;
    job.computeMs = 500;
    await h.tick();
    expect(r.statuses, hasLength(2));
    expect(r.statuses.last.fraction, 0.2);
    expect(r.statuses.last.computeTime, const Duration(milliseconds: 500));

    // Over 10 s of constant change: <= 4 Hz.
    for (var k = 0; k < 40; k++) {
      job.computeMs += 10;
      await tester.pump(const Duration(milliseconds: 125));
    }
    expect(r.statuses.length - 2, lessThanOrEqualTo(20));
    await h.dispose();
  });

  testWidgets('segments are batched across polls by chunk, 256 per take', (tester) async {
    final h = _Harness(tester);
    final r = await h.record((await h.model()).transcribe(_req));
    final job = h.fake.lastJob;

    job.addChunk(0, 3);
    await h.tick();
    expect(job.takes, [(0, 3)]);
    expect(r.added, hasLength(1));
    expect(r.added.single.chunk, 0);
    expect(r.added.single.chunkFinal, isTrue);
    expect(r.added.single.segments.map((s) => s.text), ['s0', 's1', 's2']);

    // Nothing new: no take.
    await h.tick();
    expect(job.takes, hasLength(1));

    // Two chunks complete between polls: one update per chunk.
    job.addChunk(1, 2);
    job.addChunk(2, 1);
    await h.tick();
    expect(job.takes.last, (3, 3));
    expect(r.added.skip(1).map((a) => (a.chunk, a.segments.length, a.chunkFinal)), [(1, 2, true), (2, 1, true)]);

    // A very large chunk is taken one page per poll; only the last page completes the chunk.
    job.addChunk(3, 300);
    await h.tick();
    expect(job.takes.last, (6, 256));
    expect(r.added.last.chunkFinal, isFalse);
    await h.tick();
    expect(job.takes.last, (262, 44));
    expect(r.added.last.chunkFinal, isTrue);
    expect(r.added.expand((a) => a.segments).map((s) => s.index), List<int>.generate(306, (i) => i));
    await h.dispose();
  });

  testWidgets('success drains the remaining segments, completes the result, closes and frees', (tester) async {
    final h = _Harness(tester);
    final model = await h.model();
    final r = await h.record(model.transcribe(_req));
    final job = h.fake.lastJob;
    expect(model.isBusy, isTrue);

    job.addChunk(0, 2);
    job.addChunk(1, 600);
    job
      ..state = VwJobState.succeeded
      ..permille = 1000
      ..processedMs = 11000
      ..computeMs = 900
      ..language = 'en'
      ..languageP = 1;
    await h.tick();
    expect(job.takes.map((t) => t.$1), [0, 256, 512], reason: 'terminal poll drains every page');
    expect(r.result, isNotNull);
    expect(r.result!.segments, hasLength(602));
    expect(r.result!.language, 'en');
    expect(r.result!.processed, const Duration(seconds: 11));
    expect(r.result!.computeTime, const Duration(milliseconds: 900));
    expect(r.statuses.last.state, WhisperJobState.succeeded);
    expect(r.closed, isTrue);
    expect(job.frees, 1);
    expect(model.isBusy, isFalse);

    // No further polls after the end.
    final reads = job.statusReads;
    await h.tick(4);
    expect(job.statusReads, reads);
    await h.dispose();
  });

  testWidgets('failed and cancelled terminal states throw typed exceptions', (tester) async {
    final h = _Harness(tester);
    final model = await h.model();
    for (final (code, kind) in [
      (VwStatus.oom, WhisperErrorKind.outOfMemory),
      (VwStatus.inference, WhisperErrorKind.inference),
      (VwStatus.wavFormat, WhisperErrorKind.invalidAudio),
      (VwStatus.noSpeech, WhisperErrorKind.noSpeech),
      (VwStatus.vadModel, WhisperErrorKind.vadModelMissing),
      (VwStatus.io, WhisperErrorKind.io),
      (VwStatus.ok, WhisperErrorKind.internal),
    ]) {
      final r = await h.record(model.transcribe(_req));
      h.fake.lastJob
        ..state = VwJobState.failed
        ..error = code;
      await h.tick();
      expect(r.error, isA<WhisperException>().having((e) => e.kind, 'kind', kind), reason: '$code');
      expect((r.error! as WhisperException).detail, isNot(contains('/tmp')), reason: 'no paths in details');
      expect(r.closed, isTrue);
      expect(h.fake.lastJob.frees, 1);
    }

    final r = await h.record(model.transcribe(_req));
    r.updates.clear();
    final job = h.fake.lastJob;
    job.addChunk(0, 1);
    job.state = VwJobState.cancelled;
    await h.tick();
    expect(r.error, isA<WhisperException>().having((e) => e.kind, 'kind', WhisperErrorKind.cancelled));
    expect(r.added.single.segments.single.text, 's0', reason: 'segments are still delivered');
    await h.dispose();
  });

  testWidgets('cancel, pause, resume and threads are forwarded; requests before the start are queued', (tester) async {
    final h = _Harness(tester);
    final model = await h.model();

    // Before the native job exists.
    final early = model.transcribe(_req);
    early.threads = 20;
    early.pause(abortCurrentChunk: true);
    final r = await h.record(early);
    final job = h.fake.lastJob;
    expect(job.threadCalls, [8]);
    expect(job.pauses, [true]);

    early.resume();
    early.pause();
    early.threads = 2;
    expect(job.resumes, 1);
    expect(job.pauses, [true, false]);
    expect(job.threadCalls, [8, 2]);

    early.cancel();
    expect(job.cancels, 1);
    job.state = VwJobState.cancelled;
    await h.tick();
    expect(r.error, isA<WhisperException>().having((e) => e.kind, 'kind', WhisperErrorKind.cancelled));

    // Controls after the end are no-ops.
    early.cancel();
    early.pause();
    early.resume();
    early.threads = 3;
    expect(job.cancels, 1);
    expect(job.resumes, 1);

    // Cancel before the start: the native job is cancelled as soon as it exists.
    final pre = model.transcribe(_req);
    pre.cancel();
    final r2 = await h.record(pre);
    expect(h.fake.lastJob.cancels, 1);
    expect(h.fake.lastJob.threadCalls, isEmpty);
    h.fake.lastJob.state = VwJobState.cancelled;
    await h.tick();
    expect(r2.error, isA<WhisperException>().having((e) => e.kind, 'kind', WhisperErrorKind.cancelled));
    await h.dispose();
  });

  testWidgets('one job per model: a second start fails busy; after the end the model is free', (tester) async {
    final h = _Harness(tester);
    final model = await h.model();
    final r1 = await h.record(model.transcribe(_req));
    final r2 = await h.record(model.detectLanguage(const WhisperDetectRequest(wavPath: 'w', threads: 2)));
    expect(r2.error, isA<WhisperException>().having((e) => e.kind, 'kind', WhisperErrorKind.busy));
    expect(r2.closed, isTrue);
    expect(h.fake.jobs, hasLength(1));

    h.fake.lastJob.state = VwJobState.succeeded;
    await h.tick();
    expect(r1.result, isNotNull);
    final r3 = await h.record(model.transcribe(_req));
    expect(h.fake.jobs, hasLength(2));
    h.fake.lastJob.state = VwJobState.succeeded;
    await h.tick();
    expect(r3.result, isNotNull);
    await h.dispose();
  });

  testWidgets('a failed native start completes the result with the mapped status', (tester) async {
    final h = _Harness(tester);
    final model = await h.model();
    h.fake.startStatus = VwStatus.wavFormat;
    final r = await h.record(model.transcribe(_req));
    expect(r.error, isA<WhisperException>().having((e) => e.kind, 'kind', WhisperErrorKind.invalidAudio));
    expect(model.isBusy, isFalse);
    h.fake
      ..startStatus = VwStatus.ok
      ..throwOnStart = true;
    final r2 = await h.record(model.transcribe(_req));
    expect(r2.error, isA<WhisperException>().having((e) => e.kind, 'kind', WhisperErrorKind.internal));
    expect(model.isBusy, isFalse);
    await h.dispose();
  });

  testWidgets('language detection emits the result and fills WhisperJobResult.languages', (tester) async {
    final h = _Harness(tester);
    final model = await h.model();
    final r = await h.record(model.detectLanguage(const WhisperDetectRequest(wavPath: 'w', threads: 2)));
    final job = h.fake.lastJob;
    expect(job.params.mode, VwJobMode.detectLanguage);
    expect(job.params.language, 'auto');
    job
      ..languageJson = '{"lang":[{"code":"es","p":0.91},{"code":"pt","p":0.05}],"speechStartMs":2300}'
      ..state = VwJobState.succeeded;
    await h.tick();
    final lang = r.updates.whereType<WhisperLanguageResult>().single;
    expect(lang.top.first.code, 'es');
    expect(lang.speechStart, const Duration(milliseconds: 2300));
    expect(r.result!.languages.map((l) => l.code), ['es', 'pt']);
    expect(r.result!.language, 'es');
    expect(r.result!.languageP, 0.91);
    await h.dispose();
  });

  testWidgets('malformed or unknown-key segment JSON is tolerated', (tester) async {
    final h = _Harness(tester);
    final r = await h.record((await h.model()).transcribe(_req));
    final job = h.fake.lastJob;

    // Unknown keys and one bad element inside a valid array.
    job.segments
      ..add('{"i":0,"c":0,"t0":0,"t1":500,"text":"a","x-new":{"deep":[1,2]}}')
      ..add('{"i":1,"c":0,"t0":"oops"}')
      ..add('{"i":2,"c":0,"t0":600,"t1":900,"text":"b"}');
    job.chunksCompleted = 1;
    await h.tick();
    expect(r.added.expand((a) => a.segments).map((s) => s.text), ['a', 'b']);
    expect(job.takes.last, (0, 3));

    // A broken document: retried element by element; the bad one is skipped, the cursor advances.
    job.segments.addAll([
      '{"i":3,"c":1,"t0":1000,"t1":1500,"text":"c"}',
      '{"i":4,"c":1,"t0":',
    ]);
    h.fake.takeOverride = (j, from, max) =>
        max == 1 ? (from == 4 ? '[{"i":4,"c":1,"t0":' : '[${j.segments[from]}]') : '[${j.segments.sublist(from).join(',')}';
    await h.tick();
    expect(r.added.expand((a) => a.segments).map((s) => s.text), ['a', 'b', 'c']);
    h.fake.takeOverride = null;

    job.addChunk(2, 1);
    await h.tick();
    expect(job.takes.last.$1, 5, reason: 'cursor moved past the malformed element');
    expect(r.error, isNull);
    await h.dispose();
  });

  testWidgets('a RUNNING job without compute progress for 120 s emits one stall diagnostic', (tester) async {
    final h = _Harness(tester);
    final r = await h.record((await h.model()).transcribe(_req));
    final job = h.fake.lastJob..computeMs = 10;
    await h.tick(400); // 100 s
    expect(r.updates.whereType<WhisperJobStalled>(), isEmpty);
    await h.tick(100); // 125 s
    final stall = r.updates.whereType<WhisperJobStalled>().single;
    expect(stall.unchangedFor, greaterThanOrEqualTo(const Duration(seconds: 120)));
    expect(stall.computeTime, const Duration(milliseconds: 10));
    await h.tick(100);
    expect(r.updates.whereType<WhisperJobStalled>(), hasLength(1), reason: 'once per stall');
    expect(job.cancels, 0, reason: 'nothing is killed automatically');

    // Paused time never counts.
    job
      ..computeMs = 20
      ..state = VwJobState.paused;
    await h.tick(600);
    expect(r.updates.whereType<WhisperJobStalled>(), hasLength(1));
    await h.dispose();
  });

  testWidgets('the Finalizer callback cancels and frees a job once; a normal end detaches it', (tester) async {
    final h = _Harness(tester);
    final model = await h.model();
    final job = model.transcribe(_req) as NativeWhisperJob;
    final r = await h.record(job);
    final native = h.fake.lastJob;
    expect(job.debugHandle, isNot(0));

    NativeWhisperJob.debugReap(job);
    expect(native.cancels, 1);
    expect(native.frees, 1);
    NativeWhisperJob.debugReap(job);
    expect(native.frees, 1, reason: 'idempotent');

    // The poll then sees a stale handle (FAILED + INVALID_ARG) and ends without a second free.
    await h.tick();
    expect(r.error, isA<WhisperException>());
    expect(native.frees, 1);

    // After a normal end the reaper has nothing to do.
    final job2 = model.transcribe(_req) as NativeWhisperJob;
    await h.record(job2);
    h.fake.lastJob.state = VwJobState.succeeded;
    await h.tick();
    expect(h.fake.lastJob.frees, 1);
    NativeWhisperJob.debugReap(job2);
    expect(h.fake.lastJob.frees, 1);
    expect(h.fake.lastJob.cancels, 0);
    await h.dispose();
  });

  testWidgets('disposing the runtime abandons running jobs', (tester) async {
    final h = _Harness(tester);
    final r = await h.record((await h.model()).transcribe(_req));
    await h.runtime.dispose();
    await tester.pump();
    expect(r.error, isA<WhisperException>().having((e) => e.kind, 'kind', WhisperErrorKind.cancelled));
    expect(h.fake.lastJob.cancels, 1);
    expect(h.fake.lastJob.frees, 1);
    expect(h.fake.liveModels, 0);
    await tester.pump(const Duration(seconds: 61));
  });
}
