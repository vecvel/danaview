// OWNER: UX-09
//
// TimelineViewportController (ux.md §8.4, §21.1): x <-> time round trip, zoom range and anchor
// invariance, bounds in both modes, centre-locked scrubbing and following, free-mode paging,
// reveal, resize, ViewState persistence and fling physics on both platforms.

import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart' show Velocity, kMinFlingVelocity;
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vwish_editor/src/editor/timeline/timeline_viewport.dart';
import 'package:vwish_editor_core/model.dart';

const _s = microsPerSecond;
const _header = 44.0;
const _ruler = 24.0;

/// A laid-out viewport: lanes [width] × [height], [duration], [rate], lane stack [content].
TimelineViewportController _vp({
  PlayheadFollowMode mode = PlayheadFollowMode.free,
  TargetPlatform platform = TargetPlatform.android,
  double width = 400,
  double height = 200,
  TimeUs duration = 60 * _s,
  FrameRate rate = FrameRate.fps30,
  double content = 600,
}) {
  final c = TimelineViewportController(defaultMode: mode, platform: platform);
  c.setContent(duration: duration, frameRate: rate, contentHeight: content);
  c.setViewport(Size(width + _header, height + _ruler), _header, rulerHeight: _ruler);
  addTearDown(c.dispose);
  return c;
}

void main() {
  group('layout and conversions', () {
    test('lanes area excludes the header column and the ruler', () {
      final c = _vp();
      expect(c.lanesWidth, 400);
      expect(c.lanesHeight, 200);
      expect(c.headerWidth, _header);
      expect(c.rulerHeight, _ruler);
      expect(c.hasLayout, isTrue);
    });

    test('xOf / timeAt round-trip within 1 µs at every zoom and scroll', () {
      final rnd = math.Random(7);
      final c = _vp(duration: 3600 * _s);
      for (var i = 0; i < 400; i++) {
        c.setPxPerSecond(c.minPxPerSecond + rnd.nextDouble() * (c.maxPxPerSecond - c.minPxPerSecond));
        c.jumpTo(scrollTimeSec: rnd.nextDouble() * 3500);
        final t = (rnd.nextDouble() * 3600 * _s).round();
        expect((c.timeAt(c.xOf(t)) - t).abs(), lessThanOrEqualTo(1), reason: 'pps ${c.pxPerSecond}');
        final x = rnd.nextDouble() * c.lanesWidth;
        expect(c.xOf(c.timeAt(x)), closeTo(x, c.pxPerSecond / _s + 1e-6));
        expect(c.secAt(c.xOfSec(12.345)), closeTo(12.345, 1e-9));
      }
    });

    test('first layout fits the whole project with a 5 % margin', () {
      final c = _vp();
      expect(c.pxPerSecond, closeTo(400 * 0.9 / 60, 1e-9));
      expect(c.xOf(0), closeTo(20, 1e-6));
      expect(c.xOf(60 * _s), closeTo(380, 1e-6));
    });

    test('a fit requested before the first layout applies on layout', () {
      final c = TimelineViewportController(defaultMode: PlayheadFollowMode.free);
      addTearDown(c.dispose);
      c.zoomToFit();
      expect(c.pxPerSecond, 0);
      c.setContent(duration: 30 * _s, frameRate: FrameRate.fps25, contentHeight: 100);
      c.setViewport(const Size(544, 224), 44, rulerHeight: 24);
      expect(c.pxPerSecond, closeTo(500 * 0.9 / 30, 1e-9));
      expect(c.visibleRange.start, lessThanOrEqualTo(0));
      expect(c.visibleRange.end, greaterThanOrEqualTo(30 * _s));
    });

    test('zoomToFit on an empty project uses the smallest zoom (30 s)', () {
      final c = _vp(duration: 0);
      c.zoomToFit();
      expect(c.pxPerSecond, closeTo(400 / 30, 1e-9));
    });
  });

  group('zoom range', () {
    test('smallest zoom is the project plus 10 s (at least 30 s); largest is 48 px per frame', () {
      for (final (rate, duration) in [
        (FrameRate.fps30, 60 * _s),
        (FrameRate.fps24, 5 * _s),
        (FrameRate.fps60, 4 * 3600 * _s),
        (FrameRate.fps25, 0),
      ]) {
        final c = _vp(rate: rate, duration: duration);
        final span = math.max(duration / _s + 10, 30);
        expect(c.minPxPerSecond, closeTo(400 / span, 1e-9));
        expect(c.maxPxPerSecond, rate.fps * 48);
        c.zoomBy(1e9, anchorX: 100);
        expect(c.pxPerSecond, rate.fps * 48);
        expect(c.canZoomIn, isFalse);
        expect(c.xOf(rate.timeOfFrame(101)) - c.xOf(rate.timeOfFrame(100)), closeTo(48, 0.01));
        c.zoomBy(1e-9, anchorX: 100);
        expect(c.pxPerSecond, closeTo(c.minPxPerSecond, 1e-9));
        expect(c.canZoomOut, isFalse);
      }
    });

    test('buttons and keys step ×1.5 / ÷1.5', () {
      final c = _vp(duration: 600 * _s);
      c.setPxPerSecond(20);
      c.zoomIn();
      expect(c.pxPerSecond, closeTo(30, 1e-9));
      c.zoomOut();
      c.zoomOut();
      expect(c.pxPerSecond, closeTo(20 / 1.5, 1e-9));
    });

    test('zoomIn in free mode anchors at the playhead when it is visible', () {
      final c = _vp(duration: 600 * _s);
      final playhead = ValueNotifier<TimeUs>(112 * _s);
      addTearDown(playhead.dispose);
      c.setPxPerSecond(10);
      c.jumpTo(scrollTimeSec: 100);
      c.attachPlayhead(playhead);
      final x = c.xOf(playhead.value);
      expect(x, closeTo(120, 1e-6));
      c.zoomIn();
      expect(c.xOf(playhead.value), closeTo(x, 0.5));
    });

    test('anchor invariance: the time under the focal point stays within 0.5 px (free mode)', () {
      final rnd = math.Random(42);
      final c = _vp(duration: 3600 * _s);
      var checked = 0;
      for (var i = 0; i < 2000; i++) {
        c.setPxPerSecond(c.minPxPerSecond * 2 + rnd.nextDouble() * 400);
        c.jumpTo(scrollTimeSec: 200 + rnd.nextDouble() * 3000);
        final anchorX = rnd.nextDouble() * c.lanesWidth;
        final factor = 0.5 + rnd.nextDouble();
        final t = c.timeAt(anchorX);
        final target = c.pxPerSecond * factor;
        final expectedScroll = c.secAt(anchorX) - anchorX / target;
        final b0 = (min: -24 / target, max: 3600 + 0.3 * 400 / target - 400 / target);
        final clamped = target < c.minPxPerSecond || target > c.maxPxPerSecond || expectedScroll < b0.min || expectedScroll > b0.max;
        c.zoomBy(factor, anchorX: anchorX);
        if (clamped) continue;
        checked++;
        expect(c.xOf(t), closeTo(anchorX, 0.5));
      }
      expect(checked, greaterThan(1500));
    });

    test('anchor invariance holds for continuous pinch steps', () {
      final c = _vp(duration: 1800 * _s);
      c.setPxPerSecond(5);
      c.jumpTo(scrollTimeSec: 600);
      const anchorX = 137.0;
      final t = c.timeAt(anchorX);
      c.beginGesture();
      for (var i = 0; i < 60; i++) {
        c.zoomBy(1.03, anchorX: anchorX);
      }
      for (var i = 0; i < 30; i++) {
        c.zoomBy(1 / 1.04, anchorX: anchorX);
      }
      c.endGesture();
      expect(c.xOf(t), closeTo(anchorX, 0.5));
    });

    test('centre-locked: the playhead is the anchor, whatever the focal point', () {
      final c = _vp(mode: PlayheadFollowMode.centreLocked, duration: 600 * _s);
      final playhead = ValueNotifier<TimeUs>(200 * _s);
      addTearDown(playhead.dispose);
      c.attachPlayhead(playhead);
      expect(c.centerTimeSec, closeTo(200, 1e-9));
      for (final (f, x) in [(2.0, 10.0), (0.5, 390.0), (3.0, 0.0), (1.7, 250.0)]) {
        c.zoomBy(f, anchorX: x);
        expect(c.xOf(playhead.value), closeTo(c.lanesWidth / 2, 0.5));
      }
      c.zoomToFit();
      expect(c.xOf(playhead.value), closeTo(c.lanesWidth / 2, 0.5));
    });
  });

  group('bounds', () {
    test('free mode: [-24 px, duration + 30 % of the viewport]', () {
      final c = _vp(duration: 600 * _s);
      c.setPxPerSecond(10);
      c.scrollByPx(-1e9, 0);
      expect(c.xOf(0), closeTo(24, 1e-6));
      c.scrollByPx(1e9, 0);
      expect(c.xOf(600 * _s), closeTo(0.7 * 400, 1e-6));
      // A project shorter than the view does not scroll past its leading margin.
      final short = _vp(duration: 5 * _s);
      short.zoomBy(1e-9, anchorX: 0);
      short.scrollByPx(1e9, 0);
      expect(short.scrollTimeSec, closeTo(short.scrollBounds.min, 1e-12));
    });

    test('centre-locked: time 0 and the end can reach the centre line', () {
      final c = _vp(mode: PlayheadFollowMode.centreLocked, duration: 600 * _s);
      c.setPxPerSecond(10);
      c.scrollByPx(-1e9, 0);
      expect(c.xOf(0), closeTo(200, 1e-6));
      expect(c.scrollBounds.min, closeTo(-200 / 10, 1e-9));
      c.scrollByPx(1e9, 0);
      expect(c.xOf(600 * _s), closeTo(200, 1e-6));
      expect(c.scrollBounds.max, closeTo(600 - 20, 1e-9));
    });

    test('vertical scroll stays in [0, content - lanes height]', () {
      final c = _vp(content: 600);
      c.scrollByPx(0, 1e9);
      expect(c.scrollY, 400);
      expect(c.maxScrollY, 400);
      c.scrollByPx(0, -1e9);
      expect(c.scrollY, 0);
      final small = _vp(content: 120);
      small.scrollByPx(0, 50);
      expect(small.scrollY, 0);
    });

    test('content changes clamp zoom and scroll', () {
      final c = _vp(duration: 600 * _s, content: 600);
      c.setPxPerSecond(1);
      c.scrollByPx(1e9, 1e9);
      c.setContent(duration: 20 * _s, contentHeight: 250);
      expect(c.pxPerSecond, closeTo(400 / 30, 1e-9), reason: 'smallest zoom of a 20 s project');
      expect(c.scrollTimeSec, lessThanOrEqualTo(c.scrollBounds.max));
      expect(c.scrollY, 50);
      c.setContent(frameRate: FrameRate.fps24);
      c.zoomBy(1e9, anchorX: 0);
      expect(c.pxPerSecond, 24 * 48);
    });

    test('resizing keeps the centre time (centre-locked) or the left edge (free)', () {
      final locked = _vp(mode: PlayheadFollowMode.centreLocked, duration: 600 * _s);
      locked.setPxPerSecond(10);
      locked.scrollByPx(1000, 0);
      final centre = locked.centerTimeSec;
      locked.setViewport(const Size(800 + _header, 200 + _ruler), _header, rulerHeight: _ruler);
      expect(locked.centerTimeSec, closeTo(centre, 1e-9));

      final free = _vp(duration: 600 * _s);
      free.setPxPerSecond(10);
      free.jumpTo(scrollTimeSec: 100);
      free.setViewport(const Size(300 + _header, 200 + _ruler), _header, rulerHeight: _ruler);
      expect(free.scrollTimeSec, closeTo(100, 1e-9));
      expect(free.pxPerSecond, 10);
    });

    test('a wider viewport raises the smallest zoom and clamps to it', () {
      final c = _vp(duration: 60 * _s);
      c.zoomBy(1e-9, anchorX: 0);
      expect(c.pxPerSecond, closeTo(400 / 70, 1e-9));
      c.setViewport(const Size(1000 + _header, 200 + _ruler), _header, rulerHeight: _ruler);
      expect(c.pxPerSecond, closeTo(1000 / 70, 1e-9));
    });
  });

  group('centre-locked mode', () {
    test('scrolling scrubs the time under the centre line; one scrub end per gesture', () {
      final c = _vp(mode: PlayheadFollowMode.centreLocked, duration: 600 * _s);
      final playhead = ValueNotifier<TimeUs>(100 * _s);
      addTearDown(playhead.dispose);
      final scrubs = <TimeUs>[];
      var ends = 0;
      c.attachPlayhead(playhead,
          onScrub: (t) {
            scrubs.add(t);
            playhead.value = FrameRate.fps30.quantize(t);
          },
          onScrubEnd: () => ends++);
      c.setPxPerSecond(10);
      final start = c.centerTimeSec;
      c.beginGesture();
      for (var i = 0; i < 10; i++) {
        c.scrollByPx(5, 0);
        expect(scrubs.last, ((c.centerTimeSec) * _s).round());
      }
      expect(c.centerTimeSec, closeTo(start + 5, 1e-9), reason: 'following is suspended while the user scrolls');
      expect(scrubs, hasLength(10));
      expect(ends, 0);
      c.endGesture();
      expect(ends, 1);
      // After the gesture the view follows the (frame-snapped) playhead again.
      playhead.value = 300 * _s;
      expect(c.centerTimeSec, closeTo(300, 1e-9));
      expect(ends, 1);
    });

    test('a wheel scroll (no gesture) scrubs and ends at once', () {
      final c = _vp(mode: PlayheadFollowMode.centreLocked);
      final scrubs = <TimeUs>[];
      var ends = 0;
      final playhead = ValueNotifier<TimeUs>(10 * _s);
      addTearDown(playhead.dispose);
      c.attachPlayhead(playhead, onScrub: scrubs.add, onScrubEnd: () => ends++);
      c.scrollByPx(30, 0);
      expect(scrubs, hasLength(1));
      expect(ends, 1);
    });

    test('scrub times stay inside the project at the bounds', () {
      final c = _vp(mode: PlayheadFollowMode.centreLocked, duration: 60 * _s);
      final scrubs = <TimeUs>[];
      final playhead = ValueNotifier<TimeUs>(30 * _s);
      addTearDown(playhead.dispose);
      c.attachPlayhead(playhead, onScrub: scrubs.add);
      c.scrollByPx(-1e9, 0);
      expect(scrubs.last, 0);
      c.scrollByPx(1e9, 0);
      expect(scrubs.last, 60 * _s);
    });

    test('the view follows the playhead during playback (centre line fixed)', () {
      final c = _vp(mode: PlayheadFollowMode.centreLocked, duration: 60 * _s);
      final playhead = ValueNotifier<TimeUs>(0);
      final playing = ValueNotifier<bool>(true);
      addTearDown(playhead.dispose);
      addTearDown(playing.dispose);
      var scrubbed = false;
      c.attachPlayhead(playhead, playing: playing, onScrub: (_) => scrubbed = true);
      for (var f = 0; f < 120; f++) {
        playhead.value = FrameRate.fps30.timeOfFrame(f);
        expect(c.xOf(playhead.value), closeTo(200, 1e-6));
      }
      expect(scrubbed, isFalse, reason: 'following never scrubs');
    });

    test('switching to centre-locked brings the playhead to the centre line', () {
      final c = _vp(duration: 600 * _s);
      final playhead = ValueNotifier<TimeUs>(250 * _s);
      addTearDown(playhead.dispose);
      c.attachPlayhead(playhead);
      c.setPxPerSecond(10);
      c.jumpTo(scrollTimeSec: 0);
      c.setMode(PlayheadFollowMode.centreLocked);
      expect(c.centerLocked, isTrue);
      expect(c.centerTimeSec, closeTo(250, 1e-9));
      c.toggleCenterLocked();
      expect(c.mode, PlayheadFollowMode.free);
    });

    test('ensureVisible never leaves the playhead', () {
      final c = _vp(mode: PlayheadFollowMode.centreLocked, duration: 600 * _s);
      c.setPxPerSecond(10);
      final before = c.scrollTimeSec;
      expect(c.ensureVisible(TimeRange(500 * _s, 510 * _s)), isFalse);
      expect(c.scrollTimeSec, before);
    });
  });

  group('free mode', () {
    test('scrolling never scrubs', () {
      final c = _vp(duration: 600 * _s);
      var scrubs = 0;
      final playhead = ValueNotifier<TimeUs>(0);
      addTearDown(playhead.dispose);
      c.attachPlayhead(playhead, onScrub: (_) => scrubs++);
      c.beginGesture();
      c.scrollByPx(100, 0);
      c.endGesture();
      c.scrollByPx(50, 0);
      expect(scrubs, 0);
    });

    test('during playback the view pages at 90 % so the playhead sits at 10 %', () {
      final c = _vp(duration: 600 * _s);
      final playhead = ValueNotifier<TimeUs>(0);
      final playing = ValueNotifier<bool>(true);
      addTearDown(playhead.dispose);
      addTearDown(playing.dispose);
      c.setPxPerSecond(10);
      c.jumpTo(scrollTimeSec: 0);
      c.attachPlayhead(playhead, playing: playing);
      var pages = 0;
      var lastScroll = c.scrollTimeSec;
      for (var f = 0; f < 30 * 120; f += 3) {
        playhead.value = FrameRate.fps30.timeOfFrame(f);
        final x = c.xOf(playhead.value);
        expect(x, inInclusiveRange(0, 400 * 0.9 + 1.0));
        if (c.scrollTimeSec != lastScroll) {
          pages++;
          expect(x, closeTo(40, 1e-6));
          lastScroll = c.scrollTimeSec;
        }
      }
      expect(pages, greaterThan(2));
      // Jumping back (a loop) pages too.
      playhead.value = 50 * _s;
      expect(c.xOf(50 * _s), closeTo(40, 1e-6));
    });

    test('paused: the view moves only to reveal a playhead out of view', () {
      final c = _vp(duration: 600 * _s);
      final playhead = ValueNotifier<TimeUs>(0);
      addTearDown(playhead.dispose);
      c.setPxPerSecond(10);
      c.jumpTo(scrollTimeSec: 0);
      c.attachPlayhead(playhead);
      playhead.value = 38 * _s;
      expect(c.scrollTimeSec, 0, reason: 'visible: no move');
      playhead.value = 300 * _s;
      final x = c.xOf(playhead.value);
      expect(x, inInclusiveRange(0, 400));
    });

    test('ensureVisible scrolls the least, with a 24 px margin', () {
      final c = _vp(duration: 600 * _s);
      c.setPxPerSecond(10);
      c.jumpTo(scrollTimeSec: 0);
      expect(c.ensureVisible(TimeRange(10 * _s, 20 * _s)), isFalse);
      expect(c.ensureVisible(TimeRange(50 * _s, 60 * _s)), isTrue);
      expect(c.xOf(60 * _s), closeTo(400 - 24, 1e-6));
      expect(c.ensureVisible(TimeRange(5 * _s, 8 * _s)), isTrue);
      expect(c.xOf(5 * _s), closeTo(24, 1e-6));
      expect(c.ensureVisible(TimeRange(100 * _s, 200 * _s)), isTrue, reason: 'wider than the view: show its start');
      expect(c.xOf(100 * _s), closeTo(24, 1e-6));
    });

    test('ensureVisibleY reveals a lane band', () {
      final c = _vp(content: 600);
      expect(c.ensureVisibleY(250, 310), isTrue);
      expect(c.scrollY, 110);
      expect(c.ensureVisibleY(20, 60), isTrue);
      expect(c.scrollY, 20);
      expect(c.ensureVisibleY(30, 50), isFalse);
    });
  });

  group('modes and defaults', () {
    test('device default: centre-locked on touch platforms, free on pointer platforms', () {
      for (final p in [TargetPlatform.iOS, TargetPlatform.android, TargetPlatform.fuchsia]) {
        expect(TimelineViewportController.defaultModeFor(p), PlayheadFollowMode.centreLocked);
        expect(TimelineViewportController.defaultModeFor(p, centerPlayheadOnTouch: false), PlayheadFollowMode.free);
      }
      for (final p in [TargetPlatform.macOS, TargetPlatform.windows, TargetPlatform.linux]) {
        expect(TimelineViewportController.defaultModeFor(p), PlayheadFollowMode.free);
      }
    });

    test('the device default applies until a mode is chosen', () {
      final c = _vp(mode: PlayheadFollowMode.centreLocked);
      expect(c.modeIsExplicit, isFalse);
      c.setDefaultMode(PlayheadFollowMode.free);
      expect(c.mode, PlayheadFollowMode.free);
      c.setMode(PlayheadFollowMode.centreLocked);
      expect(c.modeIsExplicit, isTrue);
      c.setDefaultMode(PlayheadFollowMode.free);
      expect(c.mode, PlayheadFollowMode.centreLocked);
      expect(c.defaultMode, PlayheadFollowMode.free);
    });

    test('listeners hear zoom, scroll, size, content and mode changes only when they change', () {
      final c = _vp(duration: 600 * _s);
      var n = 0;
      c.addListener(() => n++);
      c.setViewport(const Size(400 + _header, 200 + _ruler), _header, rulerHeight: _ruler);
      c.setContent(duration: 600 * _s);
      expect(n, 0);
      c.zoomIn();
      c.scrollByPx(10, 0);
      c.setContent(contentHeight: 900);
      c.setMode(PlayheadFollowMode.centreLocked);
      expect(n, 4);
    });
  });

  group('ViewState persistence', () {
    test('restore and writeTo round-trip zoom, scroll and an explicit mode', () {
      final c = _vp(duration: 600 * _s);
      const view = ViewState(
        pixelsPerSecond: 12.5,
        scrollTimeUs: 40 * _s,
        scrollLanePx: 30,
        followMode: PlayheadFollowMode.free,
        playhead: 41 * _s,
      );
      c.restore(view);
      expect(c.restored, isTrue);
      expect(c.pxPerSecond, 12.5);
      expect(c.scrollTimeSec, 40);
      expect(c.scrollY, 30);
      expect(c.modeIsExplicit, isTrue);
      expect(c.writeTo(view), view);
      expect(c.writeTo(ViewState.initial).playhead, 0, reason: 'only zoom, scroll and mode are written');
    });

    test('a device-default mode is not written; zoom 0 means fit on layout', () {
      final c = TimelineViewportController(defaultMode: PlayheadFollowMode.centreLocked);
      addTearDown(c.dispose);
      c.restore(ViewState.initial);
      expect(c.writeTo(ViewState.initial).followMode, isNull);
      c.setContent(duration: 20 * _s);
      c.setViewport(const Size(444, 224), 44, rulerHeight: 24);
      expect(c.pxPerSecond, closeTo(400 * 0.9 / 20, 1e-9));
    });

    test('a restored zoom outside the range is clamped on layout', () {
      final c = _vp(duration: 60 * _s);
      c.restore(const ViewState(pixelsPerSecond: 1e6));
      expect(c.pxPerSecond, c.maxPxPerSecond);
    });

    test('the sink hears settled views only: one write per gesture, none per frame', () {
      final c = _vp(duration: 600 * _s);
      var view = ViewState.initial;
      var writes = 0;
      c.attachViewSink((update) {
        writes++;
        view = update(view);
      });
      c.beginGesture();
      for (var i = 0; i < 30; i++) {
        c.scrollByPx(4, 0);
        c.zoomBy(1.01, anchorX: 200);
      }
      expect(writes, 0);
      c.endGesture();
      expect(writes, 1);
      expect(view.pixelsPerSecond, c.pxPerSecond);
      expect(view.scrollTimeUs, (c.scrollTimeSec * _s).round());
      c.flushView();
      expect(writes, 1, reason: 'unchanged views are not rewritten');
      c.zoomIn();
      expect(writes, 2, reason: 'discrete zoom settles at once');
      c.setMode(PlayheadFollowMode.centreLocked);
      expect(view.followMode, PlayheadFollowMode.centreLocked);
    });

    test('playback following is written when playback stops', () {
      final c = _vp(duration: 600 * _s);
      final playhead = ValueNotifier<TimeUs>(0);
      final playing = ValueNotifier<bool>(true);
      addTearDown(playhead.dispose);
      addTearDown(playing.dispose);
      var writes = 0;
      c.setPxPerSecond(10);
      c.jumpTo(scrollTimeSec: 0);
      c.attachViewSink((_) => writes++);
      c.attachPlayhead(playhead, playing: playing);
      for (var f = 0; f < 3000; f += 10) {
        playhead.value = FrameRate.fps30.timeOfFrame(f);
      }
      expect(writes, 0);
      playing.value = false;
      expect(writes, 1);
    });
  });

  group('fling', () {
    Future<void> settle(WidgetTester tester, TimelineViewportController c, {void Function()? eachFrame}) async {
      for (var i = 0; i < 600 && c.isFlinging; i++) {
        await tester.pump(const Duration(milliseconds: 16));
        eachFrame?.call();
      }
      expect(c.isFlinging, isFalse);
    }

    for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
      testWidgets('${platform.name}: a fling moves against the finger and ends inside the bounds', (tester) async {
        final c = _vp(platform: platform, duration: 600 * _s);
        c.setPxPerSecond(10);
        c.jumpTo(scrollTimeSec: 100);
        c.beginGesture();
        c.endGesture(velocity: const Velocity(pixelsPerSecond: Offset(-1500, 0)));
        expect(c.isFlinging, isTrue);
        expect(c.isUserScrolling, isTrue);
        await tester.pump(const Duration(milliseconds: 16));
        expect(c.flingVelocityX, greaterThan(0));
        await settle(tester, c);
        expect(c.scrollTimeSec, greaterThan(100));
        expect(c.scrollTimeSec, inInclusiveRange(c.scrollBounds.min, c.scrollBounds.max));
        expect(c.flingVelocityX, 0);
      });

      testWidgets('${platform.name}: a fling into a bound comes to rest exactly inside it', (tester) async {
        final c = _vp(platform: platform, duration: 120 * _s, content: 2000);
        c.setPxPerSecond(10);
        c.jumpTo(scrollTimeSec: 60, scrollY: 1700);
        var overshoot = 0.0;
        c.fling(const Velocity(pixelsPerSecond: Offset(-8000, -8000)));
        await settle(tester, c, eachFrame: () => overshoot = math.max(overshoot, c.scrollTimeSec - c.scrollBounds.max));
        expect(c.scrollTimeSec, closeTo(c.scrollBounds.max, 1e-9));
        expect(c.scrollY, inInclusiveRange(0, c.maxScrollY));
        if (platform == TargetPlatform.android) expect(overshoot, lessThanOrEqualTo(1e-9));
        // Back to the start the other way.
        c.fling(const Velocity(pixelsPerSecond: Offset(9000, 9000)));
        await settle(tester, c);
        expect(c.scrollTimeSec, closeTo(c.scrollBounds.min, 1e-9));
        expect(c.scrollY, 0);
      });
    }

    testWidgets('centre-locked fling scrubs every frame and ends the scrub once', (tester) async {
      final c = _vp(mode: PlayheadFollowMode.centreLocked, duration: 600 * _s);
      final playhead = ValueNotifier<TimeUs>(100 * _s);
      addTearDown(playhead.dispose);
      final scrubs = <TimeUs>[];
      var ends = 0;
      c.attachPlayhead(playhead,
          onScrub: (t) {
            scrubs.add(t);
            playhead.value = t;
          },
          onScrubEnd: () => ends++);
      c.setPxPerSecond(10);
      c.beginGesture();
      c.scrollByPx(20, 0);
      c.endGesture(velocity: const Velocity(pixelsPerSecond: Offset(-2000, 0)));
      expect(ends, 0);
      await settle(tester, c);
      expect(scrubs.length, greaterThan(5));
      expect(ends, 1);
      expect(scrubs.last, (c.centerTimeSec * _s).round());
    });

    testWidgets('a slow release does not fling and settles at once', (tester) async {
      final c = _vp(duration: 600 * _s);
      var writes = 0;
      c.attachViewSink((_) => writes++);
      c.beginGesture();
      c.scrollByPx(30, 0);
      c.endGesture(velocity: const Velocity(pixelsPerSecond: Offset(kMinFlingVelocity / 2, 0)));
      expect(c.isFlinging, isFalse);
      expect(writes, 1);
    });

    testWidgets('a new gesture stops the fling; the view is written when the fling ends', (tester) async {
      final c = _vp(duration: 600 * _s);
      var writes = 0;
      c.attachViewSink((_) => writes++);
      c.setPxPerSecond(10);
      writes = 0;
      c.fling(const Velocity(pixelsPerSecond: Offset(-3000, 0)));
      await tester.pump(const Duration(milliseconds: 16));
      await tester.pump(const Duration(milliseconds: 16));
      expect(writes, 0);
      c.beginGesture();
      expect(c.isFlinging, isFalse);
      final at = c.scrollTimeSec;
      await tester.pump(const Duration(milliseconds: 100));
      expect(c.scrollTimeSec, at);
      c.endGesture();
      expect(writes, 1);
      c.fling(const Velocity(pixelsPerSecond: Offset(-3000, 0)));
      await settle(tester, c);
      expect(writes, 2);
    });

    testWidgets('a vsync-provided ticker drives the fling too', (tester) async {
      final c = _vp(duration: 600 * _s);
      c.attachVsync(const TestVSync());
      c.setPxPerSecond(10);
      c.fling(const Velocity(pixelsPerSecond: Offset(-2000, 0)));
      await settle(tester, c);
      expect(c.scrollTimeSec, greaterThan(c.scrollBounds.min));
    });
  });
}
