// OWNER: ENG-01
//
// EngineEventRouter (ARCH §12.6): demultiplexing by sessionId / jobId, the Dart-side rate limits
// (clock <= 10 Hz, progress <= 4 Hz, recorder levels <= 20 Hz) with state changes passing at once,
// buffering of unclaimed routes, terminal events, release, and source errors.

import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_editor_engine/src/event_router.dart';
import 'package:danaview_editor_engine/src/pigeon/engine_api.g.dart';
import 'package:danaview_editor_engine_api/danaview_editor_engine_api.dart';

EngineEventMsg clock(String session, int timeUs, {int seq = 1, bool playing = true}) => EngineEventMsg(
      kind: EngineEventKindMsg.clock,
      sessionId: session,
      clock: ClockMsg(timeUs: timeUs, playing: playing, rate: playing ? 1 : 0, seq: seq),
    );

EngineEventMsg preview(String session, PreviewEventKindMsg kind) =>
    EngineEventMsg(kind: EngineEventKindMsg.preview, sessionId: session, previewEvent: PreviewEventMsg(kind: kind));

EngineEventMsg progress(String job, double p) => EngineEventMsg(kind: EngineEventKindMsg.progress, jobId: job, progress: p);

EngineEventMsg exportProgress(String job, double f, {ExportPhaseMsg phase = ExportPhaseMsg.rendering, bool paused = false}) =>
    EngineEventMsg(
      kind: EngineEventKindMsg.exportProgress,
      jobId: job,
      exportProgress: ExportProgressMsg(
        phase: phase,
        fraction: f,
        framesDone: 0,
        framesTotal: 0,
        backgrounded: paused,
        pausedInBackground: paused,
        warnings: [],
      ),
    );

EngineEventMsg level(String rec, double v) => EngineEventMsg(kind: EngineEventKindMsg.recorderLevel, jobId: rec, recorderLevel: v);

EngineEventMsg done(String job) => EngineEventMsg(
      kind: EngineEventKindMsg.jobDone,
      jobId: job,
      jobDone: JobResultMsg(kind: JobKindMsg.proxy, asset: GeneratedAssetMsg(path: '/c/p.mp4', sizeBytes: 1)),
    );

EngineEventMsg failure({String? job, String? session, String code = 'decodeFailed'}) => EngineEventMsg(
      kind: EngineEventKindMsg.failure,
      jobId: job,
      sessionId: session,
      failure: FailureMsg(code: code, message: 'x', retryable: false),
    );

/// A router over a controllable source running on fake time.
final class Harness {
  Harness(this.async,
      {EventRateLimits limits = const EventRateLimits(), Duration ttl = const Duration(seconds: 60), int maxUnclaimed = 64}) {
    router = EngineEventRouter(
      () {
        sourceListens++;
        return source.stream;
      },
      limits: limits,
      now: () => async.elapsed,
      unclaimedTtl: ttl,
      maxUnclaimedRoutes: maxUnclaimed,
    )..start();
  }

  final FakeAsync async;
  final StreamController<EngineEventMsg> source = StreamController<EngineEventMsg>();
  late final EngineEventRouter router;
  int sourceListens = 0;

  void emit(EngineEventMsg e) {
    source.add(e);
    async.flushMicrotasks();
  }

  /// Emits [count] events built by [make] every [every].
  void emitEvery(Duration every, int count, EngineEventMsg Function(int i) make) {
    for (var i = 0; i < count; i++) {
      emit(make(i));
      async.elapse(every);
    }
  }
}

/// Records delivered events with the fake time they arrived.
final class Recorder<T> {
  Recorder(FakeAsync async, Stream<T> stream) {
    stream.listen((e) => items.add((async.elapsed, e)), onDone: () => closed = true);
  }

  final List<(Duration, T)> items = [];
  bool closed = false;

  List<T> get values => [for (final i in items) i.$2];
}

void main() {
  test('routes events by sessionId and jobId, and engine-wide ones to signals / drops / failures', () {
    fakeAsync((async) {
      final h = Harness(async);
      final s1 = Recorder(async, h.router.session('s1'));
      final s2 = Recorder(async, h.router.session('s2'));
      final j1 = Recorder(async, h.router.job('j1'));
      final signals = Recorder(async, h.router.signals);
      final drops = Recorder(async, h.router.drops);
      final failures = Recorder(async, h.router.failures);

      h.emit(clock('s1', 0, seq: 1));
      h.emit(clock('s2', 0, seq: 7));
      h.emit(preview('s2', PreviewEventKindMsg.firstFrame));
      h.emit(progress('j1', 0.5));
      h.emit(failure(session: 's1', code: 'surfaceLost'));
      h.emit(EngineEventMsg(kind: EngineEventKindMsg.signal, signal: SignalMsg(kind: SignalKindMsg.memoryWarning)));
      h.emit(EngineEventMsg(kind: EngineEventKindMsg.drop, drop: DropMsg(items: [], x: 1, y: 2)));
      h.emit(failure(code: 'gpuUnavailable'));
      // Malformed events (no id or no payload) are dropped.
      h.emit(EngineEventMsg(kind: EngineEventKindMsg.clock, clock: ClockMsg(timeUs: 0, playing: false, rate: 0, seq: 1)));
      h.emit(EngineEventMsg(kind: EngineEventKindMsg.progress, jobId: 'j1'));
      async.flushMicrotasks();

      expect(s1.values.map((e) => e.kind), [EngineEventKindMsg.clock, EngineEventKindMsg.failure]);
      expect(s2.values.map((e) => e.kind), [EngineEventKindMsg.clock, EngineEventKindMsg.preview]);
      expect(s2.values.first.clock!.seq, 7);
      expect(j1.values.single.progress, 0.5);
      expect(signals.values.single.kind, SignalKindMsg.memoryWarning);
      expect(drops.values.single.x, 1);
      expect(failures.values.single.code, EngineErrorCode.gpuUnavailable);
    });
  });

  test('clock samples are limited to 10 Hz while playing; the last sample is delivered', () {
    fakeAsync((async) {
      final h = Harness(async);
      final s = Recorder(async, h.router.session('s'));
      // 100 Hz for 2 s, same seq.
      h.emitEvery(const Duration(milliseconds: 10), 200, (i) => clock('s', i * 10000));
      async.elapse(const Duration(seconds: 1));

      final times = [for (final i in s.items) i.$1];
      expect(s.items.length, inInclusiveRange(20, 22));
      for (var i = 1; i < times.length; i++) {
        expect(times[i] - times[i - 1], greaterThanOrEqualTo(const Duration(milliseconds: 100)));
      }
      expect(s.values.last.clock!.timeUs, 199 * 10000, reason: 'the trailing sample is never lost');
      final delivered = [for (final e in s.values) e.clock!.timeUs];
      expect(delivered, orderedEquals([...delivered]..sort()));
    });
  });

  test('clock state changes (seq, playing) pass at once and supersede pending samples', () {
    fakeAsync((async) {
      final h = Harness(async);
      final s = Recorder(async, h.router.session('s'));
      h.emit(clock('s', 0, seq: 1));
      async.elapse(const Duration(milliseconds: 10));
      h.emit(clock('s', 10000, seq: 1)); // pending (within 100 ms)
      async.elapse(const Duration(milliseconds: 10));
      h.emit(clock('s', 500000, seq: 2)); // a seek: new seq, delivered now
      async.elapse(const Duration(milliseconds: 10));
      h.emit(clock('s', 510000, seq: 2, playing: false)); // pause: delivered now
      async.elapse(const Duration(seconds: 1));

      expect([
        for (final e in s.values) (e.clock!.timeUs, e.clock!.seq, e.clock!.playing)
      ], [
        (0, 1, true),
        (500000, 2, true),
        (510000, 2, false),
      ]);
      expect([for (final i in s.items) i.$1.inMilliseconds], [0, 20, 30]);
    });
  });

  test('job progress is limited to 4 Hz; 1.0 and jobDone pass at once; the stream closes after jobDone', () {
    fakeAsync((async) {
      final h = Harness(async);
      final j = Recorder(async, h.router.job('j'));
      h.emitEvery(const Duration(milliseconds: 10), 200, (i) => progress('j', i / 400));
      h.emit(progress('j', 1));
      h.emit(done('j'));
      async.flushMicrotasks();

      final progressItems = [
        for (final i in j.items)
          if (i.$2.kind == EngineEventKindMsg.progress) i
      ];
      // 2 s at <= 4 Hz plus the first sample and the final 1.0.
      expect(progressItems.length, inInclusiveRange(8, 10));
      for (var i = 1; i < progressItems.length - 1; i++) {
        expect(progressItems[i].$1 - progressItems[i - 1].$1, greaterThanOrEqualTo(const Duration(milliseconds: 250)));
      }
      expect(progressItems.last.$2.progress, 1);
      expect(j.values.last.kind, EngineEventKindMsg.jobDone);
      expect(j.closed, isTrue);

      // Late events for the finished job are dropped; asking again gives an empty stream.
      h.emit(progress('j', 0.3));
      final again = Recorder(async, h.router.job('j'));
      async.flushMicrotasks();
      expect(again.values, isEmpty);
      expect(again.closed, isTrue);
    });
  });

  test('a pending progress sample is flushed before a terminal failure (order kept)', () {
    fakeAsync((async) {
      final h = Harness(async);
      final j = Recorder(async, h.router.job('j'));
      h.emit(progress('j', 0.1));
      async.elapse(const Duration(milliseconds: 50));
      h.emit(progress('j', 0.2)); // pending
      h.emit(failure(job: 'j', code: 'cancelled'));
      async.elapse(const Duration(seconds: 1));
      expect(j.values.map((e) => e.kind), [EngineEventKindMsg.progress, EngineEventKindMsg.progress, EngineEventKindMsg.failure]);
      expect(j.values[1].progress, 0.2);
      expect(j.closed, isTrue);
    });
  });

  test('export progress is limited to 4 Hz but phase and background changes pass at once', () {
    fakeAsync((async) {
      final h = Harness(async);
      final j = Recorder(async, h.router.job('e'));
      h.emit(exportProgress('e', 0, phase: ExportPhaseMsg.preparing));
      async.elapse(const Duration(milliseconds: 10));
      h.emit(exportProgress('e', 0.01)); // phase change → now
      async.elapse(const Duration(milliseconds: 10));
      h.emit(exportProgress('e', 0.02)); // pending
      async.elapse(const Duration(milliseconds: 10));
      h.emit(exportProgress('e', 0.02, paused: true)); // pausedInBackground → now
      async.elapse(const Duration(seconds: 1));
      expect([for (final i in j.items) i.$1.inMilliseconds], [0, 10, 30]);
      expect(j.values.last.exportProgress!.pausedInBackground, isTrue);
    });
  });

  test('recorder levels are limited to 20 Hz', () {
    fakeAsync((async) {
      final h = Harness(async);
      final r = Recorder(async, h.router.job('rec'));
      h.emitEvery(const Duration(milliseconds: 5), 200, (i) => level('rec', (i % 10) / 10));
      async.elapse(const Duration(milliseconds: 100));
      expect(r.items.length, inInclusiveRange(20, 22));
      for (var i = 1; i < r.items.length; i++) {
        expect(r.items[i].$1 - r.items[i - 1].$1, greaterThanOrEqualTo(const Duration(milliseconds: 50)));
      }
    });
  });

  test('events that arrive before anyone listens are buffered, coalesced and replayed', () {
    fakeAsync((async) {
      final h = Harness(async);
      h.emit(preview('s', PreviewEventKindMsg.firstFrame));
      for (var i = 0; i < 50; i++) {
        h.emit(progress('j', i / 100));
      }
      h.emit(done('j'));
      expect(h.router.unclaimedRouteCount, 2);

      final s = Recorder(async, h.router.session('s'));
      final j = Recorder(async, h.router.job('j'));
      async.elapse(const Duration(seconds: 1));
      expect(s.values.single.previewEvent!.kind, PreviewEventKindMsg.firstFrame);
      expect(j.values.map((e) => e.kind), [EngineEventKindMsg.progress, EngineEventKindMsg.jobDone]);
      expect(j.values.first.progress, 0.49);
      expect(j.closed, isTrue);
      expect(h.router.unclaimedRouteCount, 0);
    });
  });

  test('unclaimed routes expire after the TTL and above the cap', () {
    fakeAsync((async) {
      final h = Harness(async, ttl: const Duration(seconds: 5), maxUnclaimed: 3);
      h.emit(progress('old', 0.1));
      async.elapse(const Duration(seconds: 6));
      h.emit(progress('a', 0.1));
      expect(h.router.unclaimedRouteCount, 1, reason: 'old expired');
      h.emit(progress('b', 0.1));
      h.emit(progress('c', 0.1));
      h.emit(progress('d', 0.1));
      h.emit(progress('e', 0.1));
      expect(h.router.unclaimedRouteCount, lessThanOrEqualTo(4));
      final old = Recorder(async, h.router.job('old'));
      async.flushMicrotasks();
      expect(old.values, isEmpty);
    });
  });

  test('release closes a session stream and drops its late events', () {
    fakeAsync((async) {
      final h = Harness(async);
      final s = Recorder(async, h.router.session('s'));
      h.emit(preview('s', PreviewEventKindMsg.firstFrame));
      h.router.release('s');
      async.flushMicrotasks();
      expect(s.closed, isTrue);
      h.emit(preview('s', PreviewEventKindMsg.stalled));
      expect(h.router.unclaimedRouteCount, 0, reason: 'late events are not buffered');
      expect(s.values.length, 1);
    });
  });

  test('errors on the event channel itself surface as typed failures; start is idempotent', () {
    fakeAsync((async) {
      final h = Harness(async);
      final failures = Recorder(async, h.router.failures);
      h.router.start();
      expect(h.sourceListens, 1);
      h.source.addError(PlatformException(code: 'io', message: 'sink failed at /var/x/y'));
      async.flushMicrotasks();
      expect(failures.values.single.code, EngineErrorCode.io);
      expect(failures.values.single.debugDetail, isNot(contains('/var/x')));
    });
  });

  test('the source is not subscribed before start()', () {
    var listened = false;
    final router = EngineEventRouter(() {
      listened = true;
      return const Stream.empty();
    });
    router.session('s');
    expect(listened, isFalse);
    expect(router.isStarted, isFalse);
    router.start();
    expect(listened, isTrue);
  });
}
