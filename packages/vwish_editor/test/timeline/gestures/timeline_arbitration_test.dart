// OWNER: UX-12
//
// Gesture arbitration by hit type (ux.md §8.8): eager handle drags (trim, keyframe, marker,
// playhead knob, ruler scrub), pointer drags of selected clips, the mouse marquee, touch scrolling
// over clips, axis-locked pans, pinch zoom anchored at the focal point, flings, centre-locked
// scrubbing, wheel scrolling and zooming, long-press menus and hover cursors.

import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vwish_editor/src/app/editor_providers.dart';
import 'package:vwish_editor/src/editor/timeline/timeline_hit.dart';
import 'package:vwish_editor_core/model.dart';

import 'gesture_support.dart';

void main() {
  const rate = FrameRate.fps30;

  Future<void> select(WidgetTester tester, TimelineRig t, TimeUs at, String lane, {PointerDeviceKind kind = PointerDeviceKind.touch}) async {
    await tester.tapAt(t.at(tester, at, lane), kind: kind);
    await tester.pump();
  }

  group('touch', () {
    testWidgets('a horizontal drag over an unselected clip scrolls time, it never moves the clip', (tester) async {
      final t = await pumpTimeline(tester);
      await tester.dragFrom(t.at(tester, 6 * s, 'tr_main'), const Offset(-150, 0));
      await tester.pumpAndSettle();
      expect(t.viewport.scrollTimeSec, greaterThan(1.5));
      expect(t.item('it_b').start, 4 * s);
      expect(t.historyDepth, 0);
    });

    testWidgets('a drag over the body of a selected clip also scrolls (handles are the only eager parts)', (tester) async {
      final t = await pumpTimeline(tester);
      await select(tester, t, 6 * s, 'tr_main');
      expect(t.state.selection.items, {const ItemId('it_b')});
      await tester.dragFrom(t.at(tester, 6 * s, 'tr_main'), const Offset(-150, 0));
      await tester.pumpAndSettle();
      expect(t.viewport.scrollTimeSec, greaterThan(1.5));
      expect(t.item('it_b').start, 4 * s);
      expect(t.historyDepth, 0);
    });

    testWidgets('pans lock to the dominant axis', (tester) async {
      final t = await pumpTimeline(tester, size: const Size(1000, 170));
      expect(t.viewport.maxScrollY, greaterThan(20));
      final g = await tester.startGesture(t.at(tester, 6 * s, 'tr_ov'));
      await g.moveBy(const Offset(4, -30));
      await g.moveBy(const Offset(10, -20));
      await g.moveBy(const Offset(12, -20));
      expect(t.viewState(tester).arbiter.debugPanAxis, Axis.vertical);
      expect(t.viewport.scrollTimeSec, 0, reason: 'horizontal movement is ignored once locked vertical');
      expect(t.viewport.scrollY, greaterThan(0));
      await g.up();
      await tester.pumpAndSettle();

      t.viewport.jumpTo(scrollTimeSec: 0, scrollY: 0);
      final h = await tester.startGesture(t.at(tester, 6 * s, 'tr_ov', fraction: 0.3));
      await h.moveBy(const Offset(-30, -6));
      await h.moveBy(const Offset(-40, -10));
      expect(t.viewState(tester).arbiter.debugPanAxis, Axis.horizontal);
      expect(t.viewport.scrollY, 0);
      expect(t.viewport.scrollTimeSec, greaterThan(0));
      await h.up();
      await tester.pumpAndSettle();
    });

    testWidgets('a trim handle claims the pointer at once and trims through one history entry', (tester) async {
      final t = await pumpTimeline(tester);
      await select(tester, t, 12 * s, 'tr_main');
      final edge = t.at(tester, 10 * s, 'tr_main', fraction: 0.9) + const Offset(3, 0);
      expect(t.hit(tester, edge), isA<HitTrimHandle>().having((h) => h.edge, 'edge', TrimEdge.start));
      final g = await tester.startGesture(edge);
      await g.moveBy(const Offset(30, 0));
      await g.moveBy(const Offset(30, 0));
      await tester.pump();
      expect(t.basic(tester).liftedItems, {const ItemId('it_c')});
      expect(t.basic(tester).ghosts[const ItemId('it_c')]?.range, const TimeRange(11 * s, 14 * s));
      await g.up();
      await tester.pump();
      expect(t.item('it_c').start, 11 * s);
      expect(t.item('it_c').end, 14 * s);
      expect(t.historyDepth, 1);
      expect(t.undoLabel, 'Trim clip');
      expect(t.viewport.scrollTimeSec, 0, reason: 'the handle drag never scrolled');
    });

    testWidgets('a keyframe diamond drags the key', (tester) async {
      final t = await pumpTimeline(tester);
      await select(tester, t, 2 * s, 'tr_ov');
      final c = t.canvas(tester);
      final g = c.geometry;
      final li = g.snapshot.laneIndexOf(const TrackId('tr_ov'))!;
      final item = g.snapshot.item(const ItemId('it_o'))!;
      final y = g.itemRect(li, item).bottom - 4 - 3.5;
      final key = c.localToGlobal(Offset(t.viewport.xOf(item.start + f(30)), y));
      expect(t.hit(tester, key), isA<HitKeyframe>());
      final gesture = await tester.startGesture(key);
      await gesture.moveBy(const Offset(15, 0));
      await gesture.moveBy(const Offset(15, 0));
      await gesture.up();
      await tester.pump();
      final clip = t.item('it_o') as MediaClip;
      expect(clip.keyframes.byChannel['transform.opacity']!.keys.map((k) => k.t), [0, f(45)]);
      expect(t.undoLabel, 'Move keyframe');
      expect(t.state.selection.keyframe?.t, f(45));
    });

    testWidgets('a marker flag drags the marker', (tester) async {
      final t = await pumpTimeline(tester);
      final g = await tester.startGesture(t.ruler(tester, 6 * s));
      await g.moveBy(const Offset(30, 0));
      await g.moveBy(const Offset(30, 0));
      await g.up();
      await tester.pump();
      expect(t.project.timeline.markers.single.time, 7 * s);
      expect(t.undoLabel, 'Move marker');
    });

    testWidgets('centre-locked: scrolling time scrubs the playhead', (tester) async {
      final t = await pumpTimeline(tester, centreLocked: true);
      final playhead = t.container.read(playheadProvider(t.id));
      expect(playhead.value, 0);
      final g = await tester.startGesture(t.at(tester, 0, 'tr_music'));
      await g.moveBy(const Offset(-20, 0));
      await g.moveBy(const Offset(-60, 0));
      await g.moveBy(const Offset(-60, 0));
      await tester.pump();
      expect(playhead.isScrubbing, isTrue);
      expect(playhead.value, closeTo(140 / 60 * s, rate.frameUs * 2), reason: 'the content followed the finger 140 px');
      await g.up();
      await tester.pumpAndSettle();
      expect(playhead.isScrubbing, isFalse);
      expect(t.historyDepth, 0);
    });

    testWidgets('pinch zooms horizontally anchored at the focal point', (tester) async {
      final t = await pumpTimeline(tester);
      final focal = t.at(tester, 5 * s, 'tr_main');
      final focalX = t.canvas(tester).globalToLocal(focal).dx;
      final a = await tester.startGesture(focal - const Offset(60, 0), pointer: 1);
      final b = await tester.startGesture(focal + const Offset(60, 0), pointer: 2);
      for (var i = 0; i < 6; i++) {
        await a.moveBy(const Offset(-10, 0));
        await b.moveBy(const Offset(10, 0));
        await tester.pump();
      }
      await a.up();
      await b.up();
      await tester.pumpAndSettle();
      expect(t.viewport.pxPerSecond, greaterThan(90));
      expect(t.viewport.timeAt(focalX), closeTo(5 * s, 20000));
    });

    testWidgets('pinch in centre-locked mode keeps the playhead at the centre', (tester) async {
      final t = await pumpTimeline(tester, centreLocked: true);
      final centre = t.viewport.centerTimeSec;
      final mid = t.canvas(tester).localToGlobal(Offset(t.viewport.lanesWidth * 0.7, 60));
      final a = await tester.startGesture(mid - const Offset(40, 0), pointer: 1);
      final b = await tester.startGesture(mid + const Offset(40, 0), pointer: 2);
      for (var i = 0; i < 4; i++) {
        await a.moveBy(const Offset(-12, 0));
        await b.moveBy(const Offset(12, 0));
        await tester.pump();
      }
      await a.up();
      await b.up();
      await tester.pumpAndSettle();
      expect(t.viewport.pxPerSecond, greaterThan(70));
      expect(t.viewport.centerTimeSec, closeTo(centre, 1e-6));
    });

    testWidgets('a fast swipe flings', (tester) async {
      final t = await pumpTimeline(tester);
      await tester.flingFrom(t.at(tester, 8 * s, 'tr_music'), const Offset(-120, 0), 2000);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));
      expect(t.viewport.isFlinging, isTrue);
      final during = t.viewport.scrollTimeSec;
      await tester.pumpAndSettle();
      expect(t.viewport.scrollTimeSec, greaterThan(during));
      expect(t.viewport.scrollTimeSec, greaterThan(2.1), reason: 'went further than the 120 px swipe');
    });

    testWidgets('long press on an empty lane opens the add-here menu; on a locked clip it explains', (tester) async {
      final t = await pumpTimeline(tester);
      await tester.longPressAt(t.at(tester, 12 * s, 'tr_music'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(t.viewState(tester).menuOpen, isTrue);
      expect(find.text('Paste here'), findsOneWidget);
      expect(find.text('Add media here'), findsOneWidget);
      expect(find.text('Add text here'), findsOneWidget);
      await tester.tapAt(const Offset(5, 5));
      await tester.pump(const Duration(milliseconds: 300));

      await tester.longPressAt(t.at(tester, 3 * s, 'tr_lock'));
      await tester.pump();
      expect(find.textContaining('This track is locked'), findsOneWidget);
      expect(t.state.selection.items, isEmpty);
      await tester.pump(const Duration(seconds: 3));
    });
  });

  group('mouse', () {
    // One mouse for the whole test (the mouse tracker wants one add per device).
    Future<TestGesture> mouseAt(WidgetTester tester, Offset at) async {
      final g = await tester.createGesture(kind: PointerDeviceKind.mouse, pointer: 7);
      await g.addPointer(location: at);
      return g;
    }

    Future<void> click(WidgetTester tester, TestGesture g, Offset at) async {
      await g.moveTo(at);
      await g.down(at);
      await g.up();
      await tester.pump();
    }

    testWidgets('dragging a selected clip moves it; an unselected one stays and nothing scrolls', (tester) async {
      final t = await pumpTimeline(tester, platform: TargetPlatform.macOS);
      final g = await mouseAt(tester, t.at(tester, 12 * s, 'tr_main'));
      await g.down(t.at(tester, 12 * s, 'tr_main'));
      await g.moveBy(const Offset(-30, 0));
      await g.moveBy(const Offset(-30, 0));
      await g.up();
      await tester.pump();
      expect(t.item('it_c').start, 10 * s);
      expect(t.viewport.scrollTimeSec, 0);
      expect(t.historyDepth, 0);

      await click(tester, g, t.at(tester, 12 * s, 'tr_main'));
      expect(t.state.selection.items, {const ItemId('it_c')});
      await g.down(t.at(tester, 12 * s, 'tr_main'));
      await g.moveBy(const Offset(-30, 0));
      await g.moveBy(const Offset(-30, 0));
      await tester.pump();
      expect(t.basic(tester).ghosts[const ItemId('it_c')]?.range, const TimeRange(9 * s, 13 * s));
      await g.up();
      await tester.pump();
      expect(t.item('it_c').start, 9 * s);
      expect(t.undoLabel, 'Move clip');
      expect(t.historyDepth, 1);
    });

    testWidgets('dragging on an empty lane draws a marquee that selects what it touches; Shift adds', (tester) async {
      final t = await pumpTimeline(tester, platform: TargetPlatform.macOS);
      final from = t.at(tester, 13 * s, 'tr_music');
      final to = t.at(tester, 9500000, 'tr_main', fraction: 0.2);
      final g = await mouseAt(tester, from);
      await g.down(from);
      await g.moveTo(Offset.lerp(from, to, 0.5)!);
      await g.moveTo(to);
      await tester.pump();
      expect(t.basic(tester).marquee, isNotNull);
      await g.up();
      await tester.pump();
      expect(t.state.selection.items, {const ItemId('it_c'), const ItemId('it_m')});

      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      final from2 = t.at(tester, 9 * s, 'tr_ov');
      await g.moveTo(from2);
      await g.down(from2);
      await g.moveTo(t.at(tester, 5 * s, 'tr_ov', fraction: 0.6));
      await g.moveTo(t.at(tester, 2 * s, 'tr_ov', fraction: 0.8));
      await g.up();
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pump();
      expect(t.state.selection.items, {const ItemId('it_c'), const ItemId('it_m'), const ItemId('it_o')});
    });

    testWidgets('the playhead knob and the ruler scrub in free mode', (tester) async {
      final t = await pumpTimeline(tester, platform: TargetPlatform.macOS);
      final playhead = t.container.read(playheadProvider(t.id));
      final g = await mouseAt(tester, t.ruler(tester, 2 * s));
      await click(tester, g, t.ruler(tester, 2 * s));
      expect(playhead.value, 2 * s);
      final knob = t.ruler(tester, 2 * s);
      expect(t.hit(tester, knob), isA<HitPlayheadKnob>());
      await g.down(knob);
      await g.moveBy(const Offset(60, 0));
      await g.moveBy(const Offset(60, 0));
      await tester.pump();
      expect(playhead.value, 4 * s);
      await g.up();
      await tester.pumpAndSettle();

      final r = t.ruler(tester, 8 * s);
      await g.moveTo(r);
      await g.down(r);
      await tester.pump();
      expect(playhead.value, 8 * s, reason: 'a ruler press seeks at once');
      await g.moveBy(const Offset(-60, 0));
      await tester.pump();
      expect(playhead.value, 7 * s);
      await g.up();
      await tester.pumpAndSettle();
      expect(t.historyDepth, 0);
    });

    testWidgets('wheel scrolls lanes, Shift+wheel scrolls time, Ctrl/⌘+wheel zooms at the cursor', (tester) async {
      final t = await pumpTimeline(tester, platform: TargetPlatform.macOS, size: const Size(1000, 170));
      final pointer = TestPointer(1, PointerDeviceKind.mouse);
      final at = t.at(tester, 5 * s, 'tr_ov');
      await tester.sendEventToBinding(pointer.addPointer(location: at));
      await tester.sendEventToBinding(pointer.hover(at));
      await tester.sendEventToBinding(pointer.scroll(const Offset(0, 30)));
      await tester.pump();
      expect(t.viewport.scrollY, 30);
      expect(t.viewport.scrollTimeSec, 0);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendEventToBinding(pointer.scroll(const Offset(0, 60)));
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pump();
      expect(t.viewport.scrollTimeSec, closeTo(1, 1e-9));
      expect(t.viewport.scrollY, 30);

      final x = t.canvas(tester).globalToLocal(at).dx;
      final before = t.viewport.timeAt(x);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
      await tester.sendEventToBinding(pointer.scroll(const Offset(0, -200)));
      await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
      await tester.pump();
      expect(t.viewport.pxPerSecond, greaterThan(60));
      expect(t.viewport.timeAt(x), closeTo(before, 2));

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendEventToBinding(pointer.scroll(const Offset(0, 200)));
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      expect(t.viewport.pxPerSecond, closeTo(60, 1e-6));
      expect(t.viewport.timeAt(x), closeTo(before, 2));
      await tester.sendEventToBinding(pointer.removePointer());
    });

    testWidgets('trackpad: two-finger pan scrolls both axes, pinch zooms at the focal point', (tester) async {
      final t = await pumpTimeline(tester, platform: TargetPlatform.macOS, size: const Size(1000, 170));
      final at = t.at(tester, 5 * s, 'tr_ov');
      final g = await tester.createGesture(kind: PointerDeviceKind.trackpad);
      await g.panZoomStart(at);
      await g.panZoomUpdate(at, pan: const Offset(-30, -10));
      await g.panZoomUpdate(at, pan: const Offset(-60, -20));
      await g.panZoomUpdate(at, pan: const Offset(-90, -30));
      await g.panZoomEnd();
      await tester.pumpAndSettle();
      // Past the slop the content follows both axes (no axis lock on a trackpad).
      expect(t.viewport.scrollTimeSec, greaterThan(0.9));
      expect(t.viewport.scrollY, greaterThan(15));

      final x = t.canvas(tester).globalToLocal(at).dx;
      final before = t.viewport.timeAt(x);
      await g.panZoomStart(at);
      await g.panZoomUpdate(at, scale: 1.2);
      await g.panZoomUpdate(at, scale: 1.6);
      await g.panZoomEnd();
      await tester.pumpAndSettle();
      expect(t.viewport.pxPerSecond, greaterThan(60 * 1.3));
      expect(t.viewport.timeAt(x), closeTo(before, 20000));
    });

    testWidgets('hover cursors: resize on trim handles, grab on selected clips; the name pill', (tester) async {
      final t = await pumpTimeline(tester, platform: TargetPlatform.macOS);
      final g = await mouseAt(tester, t.at(tester, 12 * s, 'tr_main'));
      await click(tester, g, t.at(tester, 12 * s, 'tr_main'));
      await g.moveTo(t.at(tester, 12 * s + 50000, 'tr_main'));
      await tester.pump();
      expect(RendererBinding.instance.mouseTracker.debugDeviceActiveCursor(1), SystemMouseCursors.grab);
      await g.moveTo(t.at(tester, 10 * s, 'tr_main', fraction: 0.9) + const Offset(3, 0));
      await tester.pump();
      expect(RendererBinding.instance.mouseTracker.debugDeviceActiveCursor(1), SystemMouseCursors.resizeLeftRight);
      await g.moveTo(t.at(tester, 6 * s, 'tr_main'));
      await tester.pump(const Duration(milliseconds: 700));
      expect(find.text('City · 0:04'), findsOneWidget);
      await g.moveTo(t.at(tester, 13 * s, 'tr_music'));
      await tester.pump();
      expect(find.text('City · 0:04'), findsNothing);
      await g.removePointer();
      await tester.pump();
    });
  });
}
