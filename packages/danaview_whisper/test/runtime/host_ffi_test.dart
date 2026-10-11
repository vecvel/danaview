// OWNER: AI-07
//
// The Dart runtime over the REAL C ABI on the host: the shim linked as a shared library
// (test/runtime/host_ffi/link_host_shim.sh) and the deterministic, download-free fixture model of
// the native tests. Skipped unless DV_TEST_HOST_LIB and DV_TEST_FIXTURE_MODEL are set.
//
// Checks: library opening and the ABI check through FfiDvBindings; jfk.wav transcribed through
// WhisperRuntime/WhisperModel/WhisperJob matches the host test text (Jobs.fixture_transcribes_jfk_
// deterministically: 6 x "hello world" at 2 s steps, words hello/world); poll cost p95 < 0.5 ms;
// cancel, pause-abort/resume equivalence, busy, DETECT; a failing load is typed; and the
// hot-restart path (a second open() after the latch reset) cancels and joins the orphan job.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_whisper/src/ffi/library_loader.dart';
import 'package:danaview_whisper/src/runtime/native_job.dart';
import 'package:danaview_whisper/danaview_whisper.dart';

final String? _lib = Platform.environment['DV_TEST_HOST_LIB'];
final String? _model = Platform.environment['DV_TEST_FIXTURE_MODEL'];
final String _jfk = Platform.environment['DV_TEST_JFK_WAV'] ?? 'third_party/whisper.cpp/samples/jfk.wav';
final Object _skip = _lib == null || _model == null
    ? 'set DV_TEST_HOST_LIB and DV_TEST_FIXTURE_MODEL (test/runtime/host_ffi/link_host_shim.sh)'
    : false;

/// 16 kHz mono s16 samples of a canonical-or-not RIFF/WAVE file.
Int16List _readPcm(String path) {
  final b = File(path).readAsBytesSync();
  final d = ByteData.sublistView(b);
  var o = 12;
  while (o + 8 <= b.length) {
    final id = String.fromCharCodes(b.sublist(o, o + 4));
    final size = d.getUint32(o + 4, Endian.little);
    if (id == 'data') return Int16List.fromList(Int16List.sublistView(Uint8List.fromList(b.sublist(o + 8, o + 8 + size))));
    o += 8 + size + (size & 1);
  }
  throw StateError('no data chunk');
}

void _writeWav(String path, Int16List pcm) {
  final h = ByteData(44);
  void tag(int o, String s) {
    for (var k = 0; k < 4; k++) {
      h.setUint8(o + k, s.codeUnitAt(k));
    }
  }

  final bytes = pcm.lengthInBytes;
  tag(0, 'RIFF');
  h.setUint32(4, 36 + bytes, Endian.little);
  tag(8, 'WAVE');
  tag(12, 'fmt ');
  h
    ..setUint32(16, 16, Endian.little)
    ..setUint16(20, 1, Endian.little)
    ..setUint16(22, 1, Endian.little)
    ..setUint32(24, 16000, Endian.little)
    ..setUint32(28, 32000, Endian.little)
    ..setUint16(32, 2, Endian.little)
    ..setUint16(34, 16, Endian.little);
  tag(36, 'data');
  h.setUint32(40, bytes, Endian.little);
  File(path).writeAsBytesSync([...h.buffer.asUint8List(), ...pcm.buffer.asUint8List(pcm.offsetInBytes, bytes)]);
}

/// [times] x jfk.wav back to back.
String _longWav(Directory dir, int times) {
  final jfk = _readPcm(_jfk);
  final out = Int16List(jfk.length * times);
  for (var k = 0; k < times; k++) {
    out.setAll(k * jfk.length, jfk);
  }
  final path = '${dir.path}/jfk-x$times.wav';
  _writeWav(path, out);
  return path;
}

Future<WhisperRuntime> _open() =>
    WhisperRuntime.open(channel: WhisperDeviceChannel(enabled: false), bindings: () => loadWhisperBindings(libraryPath: _lib));

/// Process CPU time (user + system) from `ps`, in seconds.
double _cpuSeconds() {
  final r = Process.runSync('ps', ['-o', 'time=', '-p', '$pid']);
  final parts = (r.stdout as String).trim().split(RegExp('[:.-]')).map(int.parse).toList();
  // [[dd-]hh:]mm:ss.cc
  final cc = parts.removeLast();
  var secs = 0.0;
  for (final p in parts) {
    secs = secs * 60 + p;
  }
  return secs + cc / 100;
}

void main() {
  late Directory tmp;
  setUpAll(() => tmp = Directory.systemTemp.createTempSync('dv_host_ffi'));
  tearDownAll(() => tmp.deleteSync(recursive: true));

  test('opens the shim through FfiDvBindings and checks the ABI', () async {
    WhisperRuntime.debugResetShutdownLatch();
    final rt = await _open();
    expect(rt.support, const WhisperSupported());
    expect(rt.engineVersion, '1.9.4');
    final b = loadWhisperBindings(libraryPath: _lib);
    expect(b.abiVersion(), dvAbiVersion);
    expect(identical(b, loadWhisperBindings(libraryPath: _lib)), isTrue, reason: 'one instance per library');
  }, skip: _skip);

  test('jfk.wav through the Dart API matches the host test text', () async {
    final rt = await _open();
    final model = await rt.loadModel(_model!, options: const WhisperModelOptions(preferGpu: false));
    expect(model.info.multilingual, isTrue);
    expect(model.info.usesGpu, isFalse);
    final job = model.transcribe(WhisperTranscribeRequest(wavPath: _jfk, language: 'en', threads: 4, carryPromptWords: 0));
    final updates = <WhisperJobUpdate>[];
    var closed = false;
    job.updates.listen(updates.add, onDone: () => closed = true);
    expect(model.isBusy, isTrue);
    final r = await job.result;
    expect(closed, isTrue, reason: 'result completes after every update was delivered');
    expect(model.isBusy, isFalse);

    expect(r.segments, hasLength(6));
    for (var k = 0; k < 6; k++) {
      final s = r.segments[k];
      expect(s.text, 'hello world');
      expect(s.index, k);
      expect(s.chunk, 0);
      expect(s.start, Duration(milliseconds: k * 2000));
      expect(s.end, Duration(milliseconds: (k * 2000 + 1980).clamp(0, 11000)));
      expect(s.words.map((w) => w.text), ['hello', 'world']);
      expect(s.words.first.probability, greaterThan(0.9));
    }
    expect(r.language, 'en');
    expect(r.processed, const Duration(seconds: 11));
    final added = updates.whereType<WhisperSegmentsAdded>().toList();
    expect(added.expand((a) => a.segments).map((s) => s.text), List.filled(6, 'hello world'));
    expect(added.last.chunkFinal, isTrue);
    final last = updates.whereType<WhisperJobStatus>().last;
    expect(last.state, WhisperJobState.succeeded);
    expect(last.fraction, 1.0);
    expect(last.chunkCount, 1);
    await model.release();
    await rt.releaseIdleModels();
  }, skip: _skip);

  test('poll cost (status + take <= 8 segments) p95 < 0.5 ms on the calling isolate', () async {
    final rt = await _open();
    final model = await rt.loadModel(_model!, options: const WhisperModelOptions(preferGpu: false));
    final wav = _longWav(tmp, 60); // 11 min
    final job = model.transcribe(WhisperTranscribeRequest(wavPath: wav, language: 'en', threads: 4, chunkTarget: const Duration(seconds: 20)));
    final b = loadWhisperBindings(libraryPath: _lib);
    // Wait for the native handle, then time real polls while the job computes.
    while ((job as NativeWhisperJob).debugHandle == 0) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    final h = job.debugHandle;
    final ffiCost = <int>[];
    final pollCost = <int>[];
    final sw = Stopwatch();
    for (var k = 0; k < 450; k++) {
      sw
        ..reset()
        ..start();
      final s = b.jobStatus(h);
      if (s.segmentsReady > 0) b.jobTakeSegmentsJson(h, s.segmentsReady > 8 ? s.segmentsReady - 8 : 0, 8);
      sw.stop();
      final ffi = sw.elapsedMicroseconds;
      sw
        ..reset()
        ..start();
      job.poll();
      sw.stop();
      if (k >= 50) {
        // The first 50 rounds warm up the JIT (flutter test runs unoptimized code).
        ffiCost.add(ffi);
        pollCost.add(sw.elapsedMicroseconds);
      }
      await Future<void>.delayed(const Duration(milliseconds: 2));
    }
    int p(List<int> v, double q) => (v.toList()..sort())[(v.length * q).floor()];
    // ignore: avoid_print
    print('FFI status+take<=8: p50=${p(ffiCost, .5)} us p95=${p(ffiCost, .95)} us; '
        'WhisperJob.poll: p50=${p(pollCost, .5)} us p95=${p(pollCost, .95)} us max=${p(pollCost, .999)} us');
    expect(p(ffiCost, .95), lessThan(500));
    job.cancel();
    await expectLater(job.result, throwsA(isA<WhisperException>().having((e) => e.kind, 'kind', WhisperErrorKind.cancelled)));
    await model.release();
    await rt.releaseIdleModels();
  }, skip: _skip);

  test('cancel ends a running job within 1.5 s; busy while running; pause-abort/resume output is identical', () async {
    final rt = await _open();
    final model = await rt.loadModel(_model!, options: const WhisperModelOptions(preferGpu: false));
    final wav = _longWav(tmp, 6); // 66 s
    const target = Duration(seconds: 20);

    final reference = await model
        .transcribe(WhisperTranscribeRequest(wavPath: wav, language: 'en', threads: 2, chunkTarget: target, carryPromptWords: 0))
        .result;
    expect(reference.segments.length, greaterThan(6));

    final paused = model.transcribe(WhisperTranscribeRequest(wavPath: wav, language: 'en', threads: 2, chunkTarget: target, carryPromptWords: 0));
    final busy = model.transcribe(WhisperTranscribeRequest(wavPath: wav, language: 'en', threads: 2));
    await expectLater(busy.result, throwsA(isA<WhisperException>().having((e) => e.kind, 'kind', WhisperErrorKind.busy)));
    final sawPaused = Completer<void>();
    paused.updates.listen((u) {
      if (u is WhisperJobStatus && u.state == WhisperJobState.paused && !sawPaused.isCompleted) sawPaused.complete();
    });
    paused.pause(abortCurrentChunk: true);
    await sawPaused.future.timeout(const Duration(seconds: 5));
    paused.threads = 4;
    paused.resume();
    final again = await paused.result;
    expect(again.segments.map((s) => (s.text, s.start, s.end)), reference.segments.map((s) => (s.text, s.start, s.end)));

    final long = model.transcribe(WhisperTranscribeRequest(wavPath: _longWav(tmp, 60), language: 'en', threads: 4));
    final running = Completer<void>();
    long.updates.listen((u) {
      if (u is WhisperJobStatus && u.fraction > 0 && !running.isCompleted) running.complete();
    });
    await running.future.timeout(const Duration(seconds: 30));
    final sw = Stopwatch()..start();
    long.cancel();
    await expectLater(long.result, throwsA(isA<WhisperException>().having((e) => e.kind, 'kind', WhisperErrorKind.cancelled)));
    // ignore: avoid_print
    print('cancel -> result: ${sw.elapsedMilliseconds} ms (includes up to one 250 ms poll)');
    expect(sw.elapsedMilliseconds, lessThan(1500 + 250));
    await model.release();
    await rt.releaseIdleModels();
  }, skip: _skip);

  test('DETECT runs through the Dart API; an English request on a bad file is typed', () async {
    final rt = await _open();
    final model = await rt.loadModel(_model!, options: const WhisperModelOptions(preferGpu: false));
    final r = await model.detectLanguage(WhisperDetectRequest(wavPath: _jfk, threads: 2)).result;
    expect(r.languages, isNotEmpty);
    expect(r.language, r.languages.first.code);

    final notWav = File('${tmp.path}/not.wav')..writeAsStringSync('nope');
    await expectLater(model.transcribe(WhisperTranscribeRequest(wavPath: notWav.path, language: 'en', threads: 1)).result,
        throwsA(isA<WhisperException>().having((e) => e.kind, 'kind', WhisperErrorKind.invalidAudio)));
    await model.release();

    final bad = File('${tmp.path}/bad.bin')..writeAsBytesSync(List<int>.filled(4096, 7));
    await expectLater(rt.loadModel(bad.path),
        throwsA(isA<WhisperException>().having((e) => e.kind, 'kind', WhisperErrorKind.modelLoadFailed)));
    await rt.releaseIdleModels();
  }, skip: _skip);

  test('hot restart: the next open() cancels and joins the orphan job; no compute thread survives', () async {
    final rt = await _open();
    final model = await rt.loadModel(_model!, options: const WhisperModelOptions(preferGpu: false));
    final orphan = model.transcribe(WhisperTranscribeRequest(wavPath: _longWav(tmp, 120), language: 'en', threads: 4));
    final running = Completer<void>();
    orphan.updates.listen((u) {
      if (u is WhisperJobStatus && u.fraction > 0 && !running.isCompleted) running.complete();
    });
    await running.future.timeout(const Duration(seconds: 30));
    final c0 = _cpuSeconds();
    await Future<void>.delayed(const Duration(seconds: 1));
    final busyCpu = _cpuSeconds() - c0;

    // What a hot restart does: statics reset, the app opens the runtime again.
    WhisperRuntime.debugResetShutdownLatch();
    final sw = Stopwatch()..start();
    final rt2 = await _open();
    final shutdownMs = sw.elapsedMilliseconds;
    expect(rt2.support, const WhisperSupported());

    // The old job's handle is stale now: its poll ends it (FAILED + INVALID_ARG -> internal).
    await expectLater(orphan.result, throwsA(isA<WhisperException>()));
    await Future<void>.delayed(const Duration(milliseconds: 300));
    final c1 = _cpuSeconds();
    await Future<void>.delayed(const Duration(seconds: 1));
    final idleCpu = _cpuSeconds() - c1;
    // ignore: avoid_print
    print('dv_shutdown_all via open(): $shutdownMs ms; process CPU/s while running $busyCpu, after $idleCpu');
    expect(busyCpu, greaterThan(1.0), reason: 'the job used several cores');
    expect(idleCpu, lessThan(0.5), reason: 'no orphan compute thread');

    // The new runtime works: a fresh model and job succeed.
    final m2 = await rt2.loadModel(_model!, options: const WhisperModelOptions(preferGpu: false));
    final r = await m2.transcribe(WhisperTranscribeRequest(wavPath: _jfk, language: 'en', threads: 2)).result;
    expect(r.segments, hasLength(6));
    await m2.release();
    await rt2.releaseIdleModels();
    await model.release();
  }, skip: _skip, timeout: const Timeout(Duration(minutes: 2)));
}
