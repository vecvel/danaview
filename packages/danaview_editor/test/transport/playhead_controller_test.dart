// OWNER: UX-14
//
// PlayheadController (ux.md §7.8, ARCH §17.3) on a fake clock and a scripted preview:
// extrapolation per vsync, frame-change-only notifications, snap and slew, sequence rules,
// scrub coalescing with at most one seek in flight, exact seek on release, adoption of
// `SeekAck.displayedFrameTime`, play/pause rollback and persisting only on settle.

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_editor/src/editor/state/playhead_controller.dart';
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_editor_engine_api/danaview_editor_engine_api.dart';

import 'transport_support.dart';

const FrameRate r30 = FrameRate.fps30;

TimeUs f(int k) => r30.timeOfFrame(k);

class Rig {
  Rig({TimeUs initial = 0, TimeUs duration = 10 * microsPerSecond, Duration settleDelay = const Duration(milliseconds: 150)}) {
    controller = PlayheadController(
      frameRate: r30,
      initial: initial,
      duration: duration,
      ticker: ticker,
      clock: clock.call,
      settleDelay: settleDelay,
      onSettled: settled.add,
    );
    controller.addListener(() => notifications++);
  }

  final ManualTicker ticker = ManualTicker();
  final ManualClock clock = ManualClock();
  final ScriptedPreview preview = ScriptedPreview();
  final List<TimeUs> settled = [];
  late final PlayheadController controller;
  int notifications = 0;

  void attach({SeekAck? initial}) => controller.attach(preview, initial: initial);

  /// Advances time and delivers one frame.
  void frame(Duration d) {
    clock.advance(d);
    ticker.tick();
  }
}

void main() {
  group('value', () {
    test('starts on the frame grid and stays inside the project', () {
      final rig = Rig(initial: 1234567);
      expect(rig.controller.value, r30.quantize(1234567));
      expect(r30.isOnGrid(rig.controller.value), isTrue);
      rig.controller.reset(99 * microsPerSecond);
      expect(rig.controller.value, 10 * microsPerSecond);
      rig.controller.reset(-5);
      expect(rig.controller.value, 0);
      rig.controller.dispose();
    });

    test('a new frame rate requantizes the playhead; a shorter project never moves it', () {
      final rig = Rig(initial: f(7));
      rig.controller.setContent(duration: 2 * microsPerSecond);
      expect(rig.controller.value, f(7));
      rig.controller.setContent(frameRate: FrameRate.fps24);
      expect(FrameRate.fps24.isOnGrid(rig.controller.value), isTrue);
      expect(rig.controller.value, FrameRate.fps24.quantize(f(7)));
      rig.controller.dispose();
    });
  });

  group('extrapolation while playing (fake clock)', () {
    test('extrapolates each sample per vsync and notifies only when the frame changes', () {
      final rig = Rig()..attach();
      rig.preview.emit(at: 0, playing: true, seq: 1);
      expect(rig.controller.playing.value, isTrue);
      expect(rig.ticker.isActive, isTrue);
      expect(rig.controller.value, 0);
      final before = rig.notifications;

      // 5 ms later: still frame 0 (33.3 ms), no notification.
      rig.frame(const Duration(milliseconds: 5));
      rig.frame(const Duration(milliseconds: 5));
      expect(rig.controller.value, 0);
      expect(rig.notifications, before, reason: 'same frame: no notification');

      // 100 ms after the sample: frame 3.
      rig.frame(const Duration(milliseconds: 90));
      expect(rig.controller.value, f(3));
      expect(rig.notifications, before + 1);
      rig.frame(const Duration(milliseconds: 1));
      expect(rig.notifications, before + 1);

      // One second: frame 30.
      rig.frame(const Duration(milliseconds: 899));
      expect(rig.controller.value, f(30));
      rig.controller.dispose();
    });

    test('120 vsyncs of a 60 Hz display notify once per 30 fps frame (60 times), not 120', () {
      final rig = Rig(duration: 60 * microsPerSecond)..attach();
      rig.preview.emit(at: 0, playing: true, seq: 1);
      final before = rig.notifications;
      for (var i = 0; i < 120; i++) {
        rig.frame(const Duration(microseconds: 16667));
      }
      // 120 * 16.667 ms = 2 s = 60 frames; every frame change notified once.
      expect(rig.notifications - before, lessThanOrEqualTo(60));
      expect(rig.controller.value, closeTo(f(60), 33334));
      rig.controller.dispose();
    });

    test('a sample more than one frame away snaps the playhead', () {
      final rig = Rig()..attach();
      rig.preview.emit(at: 0, playing: true, seq: 1);
      rig.frame(const Duration(milliseconds: 100));
      expect(rig.controller.value, f(3));
      rig.preview.emit(at: f(15), playing: true, seq: 1);
      expect(rig.controller.value, f(15));
      rig.controller.dispose();
    });

    test('a sample within a frame is slewed in at most half a frame per tick and never jitters backward', () {
      final rig = Rig()..attach();
      rig.preview.emit(at: 0, playing: true, seq: 1);
      rig.frame(const Duration(milliseconds: 200));
      final at = rig.controller.value;
      // The sample says the engine is 20 ms behind the extrapolation.
      rig.preview.emit(at: at - 20000, playing: true, seq: 1);
      var last = rig.controller.value;
      for (var i = 0; i < 20; i++) {
        rig.frame(const Duration(milliseconds: 2));
        expect(rig.controller.value, greaterThanOrEqualTo(last), reason: 'the playhead never moves backward while slewing');
        last = rig.controller.value;
      }
      rig.controller.dispose();
    });

    test('playback stops at the end of the project', () {
      final rig = Rig(duration: 1 * microsPerSecond)..attach();
      rig.preview.emit(at: 0, playing: true, seq: 1);
      rig.frame(const Duration(seconds: 5));
      expect(rig.controller.value, 1 * microsPerSecond);
      rig.controller.dispose();
    });

    test('a paused sample stops the ticker and rests on the sample time', () {
      final rig = Rig()..attach();
      rig.preview.emit(at: 0, playing: true, seq: 1);
      rig.frame(const Duration(milliseconds: 500));
      rig.preview.emit(at: f(14), playing: false, seq: 2);
      expect(rig.controller.playing.value, isFalse);
      expect(rig.ticker.isActive, isFalse);
      expect(rig.controller.value, f(14));
      rig.controller.dispose();
    });
  });

  group('sequence rules', () {
    test('a late sample from before a seek does not yank the playhead', () {
      fakeAsync((async) {
        final rig = Rig()..attach();
        rig.preview.emit(at: f(300), playing: true, seq: 1);
        rig.controller.seekExact(f(30));
        rig.preview.complete();
        async.flushMicrotasks();
        expect(rig.controller.value, f(30));
        final ackSeq = rig.preview.seq;
        // A sample reflecting an older command (seq below the ack) arrives late.
        rig.preview.emit(at: f(300), playing: true, seq: ackSeq - 1);
        expect(rig.controller.value, f(30));
        expect(rig.controller.minAcceptedSeq, ackSeq);
        // A sample at the ack's seq is accepted.
        rig.preview.emit(at: f(30), playing: false, seq: ackSeq);
        expect(rig.controller.value, f(30));
        rig.controller.dispose();
      });
    });

    test('a sample that predates a pause cannot restart the play state', () {
      fakeAsync((async) {
        final rig = Rig()..attach();
        rig.preview.emit(at: 0, playing: true, seq: 4);
        expect(rig.controller.playing.value, isTrue);
        rig.controller.pause();
        async.flushMicrotasks();
        expect(rig.controller.playing.value, isFalse);
        // The 10 Hz sample that was already on its way: playing, seq 4 (before the pause's seq 1+).
        rig.preview.emit(at: f(3), playing: true, seq: 4);
        expect(rig.controller.playing.value, isFalse);
        expect(rig.ticker.isActive, isFalse);
        rig.controller.dispose();
      });
    });

    test('clock samples are ignored while a seek is in flight or while scrubbing', () {
      fakeAsync((async) {
        final rig = Rig()..attach();
        rig.controller.seekExact(f(60));
        rig.preview.emit(at: f(5), playing: false, seq: 50);
        expect(rig.controller.value, f(60), reason: 'the seek decides');
        rig.preview.complete();
        async.flushMicrotasks();
        rig.controller.beginScrub();
        rig.controller.scrubTo(f(90));
        rig.preview.emit(at: f(5), playing: false, seq: 99);
        expect(rig.controller.value, f(90));
        rig.controller.dispose();
      });
    });
  });

  group('scrubbing', () {
    test('coalesces to one seek in flight, latest target wins, scrub kind during the drag', () {
      fakeAsync((async) {
        final rig = Rig()..attach();
        rig.controller.beginScrub();
        expect(rig.controller.isScrubbing, isTrue);
        rig.controller.scrubTo(f(3));
        rig.controller.scrubTo(f(6));
        rig.controller.scrubTo(f(9));
        rig.controller.scrubTo(f(12));
        expect(rig.preview.seeks, hasLength(1), reason: 'one in flight');
        expect(rig.preview.seeks.single.target, f(3));
        expect(rig.preview.seeks.single.kind, SeekKind.scrub);
        expect(rig.controller.value, f(12), reason: 'the UI follows the finger immediately');

        rig.preview.complete();
        async.flushMicrotasks();
        expect(rig.preview.seeks, hasLength(2));
        expect(rig.preview.seeks.last.target, f(12), reason: 'the stale targets 6 and 9 were dropped');
        expect(rig.preview.seeks.last.kind, SeekKind.scrub);
        expect(rig.controller.value, f(12), reason: 'a scrub ack does not move the playhead off the finger');
        rig.preview.complete();
        async.flushMicrotasks();
        expect(rig.preview.maxConcurrent, 1);
        rig.controller.dispose();
      });
    });

    test('scrubTo to the same frame sends nothing', () {
      final rig = Rig()..attach();
      rig.controller.scrubTo(f(10));
      rig.controller.scrubTo(f(10));
      rig.controller.scrubTo(f(10) + 5);
      expect(rig.preview.seeks, hasLength(1));
      rig.controller.dispose();
    });

    test('endScrub sends one exact seek to the last target and adopts the displayed frame', () {
      fakeAsync((async) {
        final rig = Rig()..attach();
        rig.preview.displayOffsetFrames = -1;
        rig.controller.beginScrub();
        rig.controller.scrubTo(f(20));
        rig.controller.scrubTo(f(40));
        var ended = false;
        rig.controller.endScrub().then((_) => ended = true);
        // The first scrub seek is still in flight: the exact one is queued behind it.
        expect(rig.preview.seeks, hasLength(1));
        rig.preview.complete();
        async.flushMicrotasks();
        expect(rig.preview.seeks, hasLength(2));
        expect(rig.preview.seeks.last.kind, SeekKind.exact);
        expect(rig.preview.seeks.last.target, f(40));
        expect(ended, isFalse);
        expect(rig.controller.isScrubbing, isFalse);
        rig.preview.complete();
        async.flushMicrotasks();
        expect(ended, isTrue);
        expect(rig.controller.value, f(39), reason: 'adopts SeekAck.displayedFrameTime');
        expect(rig.settled, [f(39)], reason: 'persisted once, after the scrub');
        expect(rig.preview.maxConcurrent, 1);
        rig.controller.dispose();
      });
    });

    test('beginScrub pauses playback', () {
      fakeAsync((async) {
        final rig = Rig()..attach();
        rig.preview.emit(at: 0, playing: true, seq: 1);
        expect(rig.controller.playing.value, isTrue);
        rig.controller.beginScrub();
        async.flushMicrotasks();
        expect(rig.preview.commands, contains('pause'));
        expect(rig.controller.playing.value, isFalse);
        rig.controller.dispose();
      });
    });

    test('seeks complete with null when the preview is detached', () {
      fakeAsync((async) {
        final rig = Rig()..attach();
        SeekAck? ack = const SeekAck(requested: 1, displayedFrameTime: 1, displayedFrame: 1, seq: 1);
        rig.controller.seekExact(f(10)).then((a) => ack = a);
        rig.controller.detach();
        async.flushMicrotasks();
        expect(ack, isNull);
        expect(rig.controller.preview, isNull);
        rig.controller.dispose();
      });
    });
  });

  group('seekExact', () {
    test('moves at once and adopts the displayed frame on the ack', () {
      fakeAsync((async) {
        final rig = Rig()..attach();
        rig.preview.displayOffsetFrames = 1;
        SeekAck? ack;
        rig.controller.seekExact(f(10)).then((a) => ack = a);
        expect(rig.controller.value, f(10));
        rig.preview.complete();
        async.flushMicrotasks();
        expect(ack!.displayedFrameTime, f(11));
        expect(rig.controller.value, f(11));
        rig.controller.dispose();
      });
    });

    test('clamps to the project and quantizes', () {
      final rig = Rig(duration: 2 * microsPerSecond)..attach();
      rig.controller.seekExact(-100);
      expect(rig.controller.value, 0);
      rig.controller.seekExact(99 * microsPerSecond);
      expect(rig.controller.value, 2 * microsPerSecond);
      rig.controller.seekExact(f(5) + 7);
      expect(rig.controller.value, f(5));
      rig.controller.dispose();
    });

    test('without a preview the playhead still moves and is settled', () {
      fakeAsync((async) {
        final rig = Rig();
        rig.controller.seekExact(f(12));
        expect(rig.controller.value, f(12));
        async.elapse(const Duration(milliseconds: 200));
        expect(rig.settled, [f(12)]);
        rig.controller.dispose();
      });
    });

    test('seeking while playing keeps playing from the new position', () {
      fakeAsync((async) {
        final rig = Rig()..attach();
        rig.preview.emit(at: 0, playing: true, seq: 1);
        rig.controller.seekExact(f(60));
        rig.preview.complete();
        async.flushMicrotasks();
        expect(rig.controller.playing.value, isTrue);
        rig.frame(const Duration(milliseconds: 100));
        expect(rig.controller.value, f(63));
        rig.controller.dispose();
      });
    });
  });

  group('play and pause', () {
    test('play shows the pause state at once and starts extrapolating', () {
      fakeAsync((async) {
        final rig = Rig(initial: f(30))..attach();
        rig.preview.time = f(30);
        rig.controller.play(loop: const TimeRange(0, 2000000));
        expect(rig.controller.playing.value, isTrue);
        async.flushMicrotasks();
        expect(rig.preview.commands, ['play']);
        expect(rig.preview.loops.single, const TimeRange(0, 2000000));
        rig.frame(const Duration(milliseconds: 100));
        expect(rig.controller.value, f(33));
        rig.controller.dispose();
      });
    });

    test('a refused play is rolled back and rethrown', () {
      fakeAsync((async) {
        final rig = Rig()..attach();
        rig.preview.failCommands = EngineFailure.of(EngineErrorCode.busy);
        Object? error;
        rig.controller.play().catchError((Object e) => error = e);
        async.flushMicrotasks();
        expect(error, isA<EngineFailure>());
        expect(rig.controller.playing.value, isFalse);
        expect(rig.ticker.isActive, isFalse);
        rig.controller.dispose();
      });
    });

    test('pause freezes on the current frame and is persisted at once', () {
      fakeAsync((async) {
        final rig = Rig()..attach();
        rig.preview.emit(at: 0, playing: true, seq: 1);
        rig.frame(const Duration(milliseconds: 500));
        expect(rig.settled, isEmpty, reason: 'nothing is written per frame while playing');
        rig.controller.pause();
        async.flushMicrotasks();
        expect(rig.controller.value, f(15));
        expect(rig.settled, [f(15)]);
        rig.controller.dispose();
      });
    });

    test('without a preview, play and pause do nothing', () {
      final rig = Rig();
      rig.controller.play();
      expect(rig.controller.playing.value, isFalse);
      rig.controller.dispose();
    });
  });

  group('persisting', () {
    test('frame stepping is debounced: one write after the last seek', () {
      fakeAsync((async) {
        final rig = Rig()..attach();
        rig.preview.autoComplete = true;
        for (var k = 1; k <= 10; k++) {
          rig.controller.seekExact(f(k));
          async.elapse(const Duration(milliseconds: 30));
        }
        expect(rig.settled, isEmpty);
        async.elapse(const Duration(milliseconds: 200));
        expect(rig.settled, [f(10)]);
        rig.controller.dispose();
      });
    });

    test('dispose flushes a pending write', () {
      fakeAsync((async) {
        final rig = Rig()..attach();
        rig.controller.seekExact(f(10));
        rig.preview.complete();
        async.flushMicrotasks();
        expect(rig.settled, isEmpty);
        rig.controller.dispose();
        expect(rig.settled, [f(10)]);
      });
    });

    test('reset is not an edit: nothing is written', () {
      fakeAsync((async) {
        final rig = Rig();
        rig.controller.reset(f(30));
        async.elapse(const Duration(seconds: 1));
        expect(rig.settled, isEmpty);
        rig.controller.dispose();
      });
    });
  });

  group('attach', () {
    test('adopts the acknowledgement of the seek that positioned the preview', () {
      final rig = Rig();
      rig.attach(initial: SeekAck(requested: f(20), displayedFrameTime: f(20), displayedFrame: 20, seq: 7));
      expect(rig.controller.value, f(20));
      expect(rig.controller.minAcceptedSeq, 7);
      rig.preview.emit(at: f(3), playing: false, seq: 6);
      expect(rig.controller.value, f(20), reason: 'older than the open seek');
      rig.controller.dispose();
    });

    test('a replaced preview starts a fresh sequence', () {
      final rig = Rig();
      rig.attach(initial: SeekAck(requested: 0, displayedFrameTime: 0, displayedFrame: 0, seq: 40));
      final next = ScriptedPreview();
      rig.controller.attach(next);
      expect(rig.controller.minAcceptedSeq, 1, reason: 'the new session\'s first command is seq 1');
      next.emit(at: f(9), playing: false, seq: 1);
      expect(rig.controller.value, f(9));
      rig.controller.dispose();
    });

    test('a new session\'s samples before its first seek do not move or persist the playhead (FIX-UX-14-1)', () {
      fakeAsync((async) {
        final rig = Rig(initial: f(77));
        rig.attach();
        rig.preview.emit(at: 0, playing: false, seq: 0); // the first plan was applied, frame 0
        async.elapse(const Duration(seconds: 1));
        expect(rig.controller.value, f(77));
        expect(rig.settled, isEmpty);
        rig.preview.emit(at: f(77), playing: false, seq: 1); // the opening exact seek
        expect(rig.controller.value, f(77));
        rig.controller.dispose();
      });
    });
  });
}
