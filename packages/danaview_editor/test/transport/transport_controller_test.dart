// OWNER: UX-14
//
// TransportController (ux.md §7.6): play/pause (restart at the end, loop range), frame step with
// press-and-hold repeat (once at once, 400 ms delay, 8 Hz), ±1 s, previous/next edit point
// including markers, start/end, the fullscreen flag and the edit-point index.

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_editor/src/editor/state/playhead_controller.dart';
import 'package:danaview_editor/src/editor/state/transport_controller.dart';
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_editor_core/ops.dart';

import '../support/support.dart';
import 'transport_support.dart';

const FrameRate r30 = FrameRate.fps30;
TimeUs f(int k) => r30.timeOfFrame(k);
const int s = microsPerSecond;

/// Text items at 0-3 s and 5-7 s and a marker at 4 s: edit points 0, 3, 4, 5, 7 s.
EditProject sampleProject() {
  final repo = FakeProjectRepository();
  final empty = repo.seedEmpty('Sample');
  final edit = EditSession(empty, ids: SeededIdGenerator(5));
  for (final cmd in <EditCommand>[const AddText(0), const AddText(5 * s, duration: 2 * s), const AddMarker(4 * s)]) {
    final out = edit.apply(cmd);
    if (!out.changed) throw StateError('$cmd -> $out');
  }
  return edit.committedProject;
}

class Rig {
  Rig({EditProject? project}) : project = project ?? sampleProject() {
    playhead = PlayheadController(
      frameRate: r30,
      duration: this.project.duration,
      ticker: ticker,
      clock: clock.call,
      onSettled: settled.add,
    );
    preview.autoComplete = true;
    playhead.attach(preview);
    transport = TransportController(playhead: playhead, project: () => this.project);
  }

  final EditProject project;
  final ManualTicker ticker = ManualTicker();
  final ManualClock clock = ManualClock();
  final ScriptedPreview preview = ScriptedPreview();
  final List<TimeUs> settled = [];
  late final PlayheadController playhead;
  late final TransportController transport;

  void dispose() {
    transport.dispose();
    playhead.dispose();
  }
}

void main() {
  test('the sample project has the expected edit points', () {
    final p = sampleProject();
    expect(p.duration, 7 * s);
    expect(EditPoints.of(p).times, [0, 3 * s, 4 * s, 5 * s, 7 * s]);
  });

  group('EditPoints', () {
    final points = EditPoints.of(sampleProject());

    test('previous is strictly before and next strictly after', () {
      expect(points.previous(0), isNull);
      expect(points.previous(1), 0);
      expect(points.previous(3 * s), 0);
      expect(points.previous(3 * s + 1), 3 * s);
      expect(points.previous(7 * s), 5 * s);
      expect(points.next(7 * s), isNull);
      expect(points.next(0), 3 * s);
      expect(points.next(3 * s), 4 * s);
      expect(points.next(4 * s - 1), 4 * s);
    });

    test('markers are edit points alongside clip edges', () {
      expect(points.times, contains(4 * s));
      expect(points.next(3 * s), 4 * s, reason: 'the marker sits between two clip edges');
    });

    test('an empty project has the start only', () {
      final repo = FakeProjectRepository();
      final p = EditPoints.of(repo.seedEmpty('Empty'));
      expect(p.times, [0]);
      expect(p.previous(0), isNull);
      expect(p.next(0), isNull);
    });
  });

  group('jumps', () {
    test('previous and next edit point walk through clip edges and markers', () async {
      final rig = Rig();
      final t = rig.transport;
      expect(rig.playhead.value, 0);
      final visited = <TimeUs>[];
      for (var i = 0; i < 4; i++) {
        await t.nextEditPoint();
        visited.add(rig.playhead.value);
      }
      expect(visited, [3 * s, 4 * s, 5 * s, 7 * s]);
      await t.nextEditPoint();
      expect(rig.playhead.value, 7 * s, reason: 'stays at the end');
      final back = <TimeUs>[];
      for (var i = 0; i < 5; i++) {
        await t.previousEditPoint();
        back.add(rig.playhead.value);
      }
      expect(back, [5 * s, 4 * s, 3 * s, 0, 0]);
      rig.dispose();
    });

    test('from between two points', () async {
      final rig = Rig();
      await rig.transport.seekTo(f(100)); // 3.33 s
      await rig.transport.previousEditPoint();
      expect(rig.playhead.value, 3 * s);
      await rig.transport.seekTo(f(100));
      await rig.transport.nextEditPoint();
      expect(rig.playhead.value, 4 * s);
      rig.dispose();
    });

    test('start and end', () async {
      final rig = Rig();
      await rig.transport.goEnd();
      expect(rig.playhead.value, 7 * s);
      expect(rig.preview.seeks.last.target, 7 * s);
      await rig.transport.goStart();
      expect(rig.playhead.value, 0);
      rig.dispose();
    });

    test('±1 s clamps at both ends', () async {
      final rig = Rig();
      await rig.transport.stepSeconds(1);
      expect(rig.playhead.value, 1 * s);
      await rig.transport.stepSeconds(-1);
      await rig.transport.stepSeconds(-1);
      expect(rig.playhead.value, 0);
      await rig.transport.seekTo(6 * s + 500000);
      await rig.transport.stepSeconds(1);
      expect(rig.playhead.value, 7 * s);
      rig.dispose();
    });

    test('jumping pauses playback first', () async {
      final rig = Rig();
      rig.preview.emit(at: 0, playing: true, seq: 1);
      expect(rig.transport.playing.value, isTrue);
      await rig.transport.nextEditPoint();
      expect(rig.preview.commands, containsAllInOrder(['pause', 'seek']));
      expect(rig.transport.playing.value, isFalse);
      rig.dispose();
    });
  });

  group('frame stepping', () {
    test('steps one frame, clamps at the start and at the end', () async {
      final rig = Rig();
      await rig.transport.stepFrames(-1);
      expect(rig.playhead.value, 0);
      expect(rig.preview.seeks, isEmpty, reason: 'nothing to do at the start');
      await rig.transport.stepFrames(1);
      expect(rig.playhead.value, f(1));
      await rig.transport.stepFrames(10);
      expect(rig.playhead.value, f(11));
      await rig.transport.seekTo(7 * s);
      await rig.transport.stepFrames(1);
      expect(rig.playhead.value, 7 * s);
      rig.dispose();
    });

    test('every step is an exact seek', () async {
      final rig = Rig();
      await rig.transport.stepFrames(1);
      expect(rig.preview.seeks.single.kind.name, 'exact');
      rig.dispose();
    });

    test('press and hold: one step at once, then 8 Hz after 400 ms', () {
      fakeAsync((async) {
        final rig = Rig();
        rig.transport.startStepRepeat(1);
        async.flushMicrotasks();
        expect(rig.playhead.value, f(1), reason: 'the first step is immediate');
        async.elapse(const Duration(milliseconds: 399));
        expect(rig.playhead.value, f(1), reason: 'nothing before the delay');
        async.elapse(const Duration(milliseconds: 1 + 125 * 8));
        // After the delay: ticks at 400+125, 400+250, ... 8 Hz.
        expect(rig.playhead.value, f(1 + 8));
        rig.transport.stopStepRepeat();
        async.elapse(const Duration(seconds: 2));
        expect(rig.playhead.value, f(1 + 8), reason: 'released');
        expect(rig.transport.isRepeating, isFalse);
        rig.dispose();
      });
    });

    test('a quick tap steps once and cancels the repeat', () {
      fakeAsync((async) {
        final rig = Rig();
        rig.transport.startStepRepeat(-1);
        rig.transport.stopStepRepeat();
        async.elapse(const Duration(seconds: 2));
        expect(rig.playhead.value, 0);
        rig.transport.startStepRepeat(1);
        async.elapse(const Duration(milliseconds: 100));
        rig.transport.stopStepRepeat();
        async.elapse(const Duration(seconds: 2));
        expect(rig.playhead.value, f(1));
        rig.dispose();
      });
    });
  });

  group('play and pause', () {
    test('toggles', () async {
      final rig = Rig();
      expect(rig.transport.canPlay, isTrue);
      await rig.transport.togglePlay();
      expect(rig.transport.playing.value, isTrue);
      expect(rig.preview.commands, contains('play'));
      await rig.transport.togglePlay();
      expect(rig.transport.playing.value, isFalse);
      expect(rig.preview.commands.last, 'pause');
      rig.dispose();
    });

    test('playing from the end restarts at the start', () async {
      final rig = Rig();
      await rig.transport.goEnd();
      await rig.transport.play();
      expect(rig.preview.seeks.last.target, 0);
      expect(rig.preview.commands.sublist(rig.preview.commands.length - 2), ['seek', 'play']);
      rig.dispose();
    });

    test('a loop range plays inside the range', () async {
      final rig = Rig();
      await rig.transport.setLoop(const TimeRange(3 * s, 5 * s));
      expect(rig.transport.loop.value, const TimeRange(3 * s, 5 * s));
      await rig.transport.play();
      expect(rig.preview.seeks.last.target, 3 * s, reason: 'the playhead was outside the loop');
      expect(rig.preview.loops.last, const TimeRange(3 * s, 5 * s));
      // Changing the loop while playing restarts playback inside the new range.
      await rig.transport.setLoop(const TimeRange(0, 1 * s));
      expect(rig.preview.loops.last, const TimeRange(0, 1 * s));
      await rig.transport.setLoop(null);
      expect(rig.preview.loops.last, isNull);
      rig.dispose();
    });

    test('an empty project cannot play', () async {
      final repo = FakeProjectRepository();
      final rig = Rig(project: repo.seedEmpty('Empty'));
      expect(rig.transport.canPlay, isFalse);
      await rig.transport.play();
      expect(rig.preview.commands, isNot(contains('play')));
      rig.dispose();
    });

    test('without a preview play does nothing and seeks only move the playhead', () async {
      final rig = Rig();
      rig.playhead.detach();
      expect(rig.transport.canPlay, isFalse);
      await rig.transport.play();
      expect(rig.transport.playing.value, isFalse);
      await rig.transport.nextEditPoint();
      expect(rig.playhead.value, 3 * s);
      rig.dispose();
    });

    test('an engine failure is swallowed and playback stays off', () async {
      final rig = Rig();
      rig.preview.failCommands = StateError('engine said no');
      await rig.transport.play();
      expect(rig.transport.playing.value, isFalse);
      rig.dispose();
    });
  });

  group('fullscreen', () {
    test('is a request flag the preview region follows', () {
      final rig = Rig();
      final seen = <bool>[];
      rig.transport.fullscreen.addListener(() => seen.add(rig.transport.fullscreen.value));
      expect(rig.transport.fullscreen.value, isFalse);
      rig.transport.toggleFullscreen();
      rig.transport.setFullscreen(true);
      rig.transport.setFullscreen(false);
      expect(seen, [true, false]);
      rig.dispose();
    });
  });

  test('edit points are cached until the timeline changes', () {
    final rig = Rig();
    expect(identical(rig.transport.editPoints, rig.transport.editPoints), isTrue);
    rig.dispose();
  });
}
