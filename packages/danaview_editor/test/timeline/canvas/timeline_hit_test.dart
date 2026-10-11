// OWNER: UX-10
//
// hitTestTimeline (ux.md §8.8): one test per hit type (item body, trim edges, fade handles,
// keyframes, transition bowtie and "+", marker, ruler, playhead knob, gap, empty lane, outside
// lanes), precedence, locked lanes, touch targets, and the render object's entry point.

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_editor/src/editor/state/editor_state.dart' show EditorSelection;
import 'package:danaview_editor/src/editor/timeline/render_timeline_canvas.dart';
import 'package:danaview_editor/src/editor/timeline/timeline_hit.dart';
import 'package:danaview_editor/src/editor/timeline/timeline_metrics.dart';
import 'package:danaview_editor/src/editor/timeline/timeline_snapshot.dart';
import 'package:danaview_editor/src/editor/timeline/timeline_viewport.dart';
import 'package:danaview_editor_core/model.dart';

import 'canvas_fixtures.dart';

const _width = 1200.0;
const _height = 520.0;
const _ruler = 24.0;

class _Rig {
  _Rig({bool touch = false, double pps = 100, PlayheadFollowMode mode = PlayheadFollowMode.free, double width = _width, double height = _height}) {
    viewport = TimelineViewportController(defaultMode: mode, platform: TargetPlatform.android);
    metrics = TimelineMetrics(touch: touch);
    snapshot = TimelineSnapshotBuilder().build(richProject());
    geometry = TimelineCanvasGeometry(snapshot: snapshot, metrics: metrics, viewport: viewport);
    viewport
      ..setViewport(Size(width, height + _ruler), 0, rulerHeight: _ruler)
      ..setContent(duration: snapshot.duration, frameRate: snapshot.frameRate, contentHeight: geometry.stack.contentHeight)
      ..setPxPerSecond(pps)
      ..jumpTo(scrollTimeSec: 0, scrollY: 0);
  }

  late final TimelineViewportController viewport;
  late final TimelineMetrics metrics;
  late final TimelineSnapshot snapshot;
  late final TimelineCanvasGeometry geometry;

  int lane(String id) => snapshot.laneIndexOf(TrackId(id))!;

  Rect body(String item) {
    final at = snapshot.locate(ItemId(item))!;
    return geometry.itemRect(at.lane, snapshot.lanes[at.lane].items[at.index]);
  }

  TimelineHit hit(Offset p, {Set<String> selected = const {}, bool all = false, TimeUs? playhead}) => TimelineHitTester.hitTest(
        p,
        geometry: geometry,
        rulerHeight: _ruler,
        selected: {for (final s in selected) ItemId(s)},
        showAllKeyframes: all,
        playhead: playhead,
      );

  void dispose() => viewport.dispose();
}

void main() {
  late _Rig rig;
  setUp(() => rig = _Rig());
  tearDown(() => rig.dispose());

  test('item body', () {
    final b = rig.body('it_v2');
    final p = Offset(b.center.dx, b.center.dy);
    expect(rig.hit(p), HitItem(item: const ItemId('it_v2'), lane: const TrackId('tr_main'), time: rig.viewport.timeAt(p.dx), selected: false));
    expect((rig.hit(p, selected: {'it_v2'}) as HitItem).selected, isTrue);
  });

  test('trim edges of a selected item: inside the edge and the outward outset', () {
    final b = rig.body('it_v3');
    // Low on the edge: the top corners hold the fade handles (it_v3 has audio).
    final y = b.bottom - 6;
    const end = HitTrimHandle(item: ItemId('it_v3'), lane: TrackId('tr_main'), edge: TrimEdge.end);
    const start = HitTrimHandle(item: ItemId('it_v3'), lane: TrackId('tr_main'), edge: TrimEdge.start);
    expect(rig.hit(Offset(b.right - 4, y), selected: {'it_v3'}), end);
    expect(rig.hit(Offset(b.right + 10, y), selected: {'it_v3'}), end, reason: '12 px outward on pointer devices');
    expect(rig.hit(Offset(b.left + 4, y), selected: {'it_v3'}), start);
    expect(rig.hit(Offset(b.left - 10, y), selected: {'it_v3'}), start);
    // Unselected: plain body.
    expect(rig.hit(Offset(b.right - 4, y)), isA<HitItem>());
  });

  test('touch trim targets reach 20 px outward', () {
    final touch = _Rig(touch: true);
    addTearDown(touch.dispose);
    final b = touch.body('it_v3');
    expect(touch.hit(Offset(b.left - 18, b.bottom - 4), selected: {'it_v3'}),
        const HitTrimHandle(item: ItemId('it_v3'), lane: TrackId('tr_main'), edge: TrimEdge.start));
    expect(rig.hit(Offset(b.left - 18, b.bottom - 4), selected: {'it_v3'}), isA<HitItem>(), reason: 'pointer outset is 12 px; it_v2 is under');
  });

  test('handles are drawn outside narrow clips', () {
    final narrow = Rect.fromLTWH(100, 0, 30, 50);
    expect(TimelineCanvasGeometry.trimHandleRect(narrow, TrimEdge.start).right, 100);
    expect(TimelineCanvasGeometry.trimHandleRect(narrow, TrimEdge.end).left, 130);
    final wide = Rect.fromLTWH(100, 0, 300, 50);
    expect(TimelineCanvasGeometry.trimHandleRect(wide, TrimEdge.start), Rect.fromLTWH(100, 0, 12, 50));
  });

  test('fade handles of a selected item with audio', () {
    final b = rig.body('it_a1');
    final item = rig.snapshot.item(const ItemId('it_a1'))!;
    final cIn = rig.geometry.fadeHandleCentre(b, item, FadeEdge.fadeIn);
    final cOut = rig.geometry.fadeHandleCentre(b, item, FadeEdge.fadeOut);
    expect(cIn.dx, closeTo(rig.viewport.xOf(2 * s), 0.01));
    expect(rig.hit(cIn, selected: {'it_a1'}), const HitFadeHandle(item: ItemId('it_a1'), lane: TrackId('tr_music'), edge: FadeEdge.fadeIn));
    expect(rig.hit(cOut + const Offset(3, 2), selected: {'it_a1'}),
        const HitFadeHandle(item: ItemId('it_a1'), lane: TrackId('tr_music'), edge: FadeEdge.fadeOut));
    expect(rig.hit(cIn), isA<HitItem>(), reason: 'unselected items have no fade handles');
    // A video without audio has none.
    final photo = rig.body('it_v2');
    expect(rig.hit(Offset(photo.left + 40, photo.top + 8), selected: {'it_v2'}), isA<HitItem>());
  });

  test('keyframe diamonds of the selected item, or every item while the Keyframes tool is open', () {
    final b = rig.body('it_o1');
    final y = TimelineCanvasGeometry.keyframeRowY(b);
    final x = rig.viewport.xOf(1 * s + f(30));
    expect(rig.hit(Offset(x + 3, y), selected: {'it_o1'}),
        HitKeyframe(KeyframeRef(const ItemId('it_o1'), 'transform.scale', f(30)), lane: const TrackId('tr_overlay')));
    expect(rig.hit(Offset(x, y)), isA<HitItem>());
    final g = rig.body('it_v6');
    expect(rig.hit(Offset(rig.viewport.xOf(2 * s + f(30)), TimelineCanvasGeometry.keyframeRowY(g)), all: true),
        HitKeyframe(KeyframeRef(const ItemId('it_v6'), 'transform.opacity', f(30)), lane: const TrackId('tr_video2')));
  });

  test('keyframe diamonds beat trim handles at the item edge', () {
    final b = rig.body('it_o1');
    final y = TimelineCanvasGeometry.keyframeRowY(b);
    expect(rig.hit(Offset(b.left + 2, y), selected: {'it_o1'}), isA<HitKeyframe>());
    expect(rig.hit(Offset(b.left + 2, b.top + 6), selected: {'it_o1'}), isA<HitTrimHandle>());
  });

  test('transition bowtie and the main-lane "+"', () {
    final main = rig.snapshot.lane(const TrackId('tr_main'))!;
    final li = rig.lane('tr_main');
    final bowtie = rig.geometry.cutCentre(li, main.cuts[0]);
    expect(rig.hit(bowtie), const HitTransition(TransitionRef(TrackId('tr_main'), ItemId('it_v1'), ItemId('it_v2')), isAddButton: false));
    final plus = rig.geometry.cutCentre(li, main.cuts[1]);
    expect(rig.hit(plus + const Offset(10, 0)),
        const HitTransition(TransitionRef(TrackId('tr_main'), ItemId('it_v2'), ItemId('it_v3')), isAddButton: true));
    // Transitions beat the trim handles of a selected neighbour at the cut.
    expect(rig.hit(plus, selected: {'it_v2'}), isA<HitTransition>());
  });

  test('no "+" when a neighbour is narrower than 40 px', () {
    // 300 px wide: the zoom can go down to 10 px/s, so the 3 s neighbours are 30 px wide.
    final far = _Rig(pps: 10, width: 300);
    addTearDown(far.dispose);
    final main = far.snapshot.lane(const TrackId('tr_main'))!;
    final c = far.geometry.cutCentre(far.lane('tr_main'), main.cuts[1]);
    expect(far.geometry.showsAddButton(main, main.cuts[1]), isFalse);
    expect(far.hit(c), isA<HitItem>());
    expect(far.hit(far.geometry.cutCentre(far.lane('tr_main'), main.cuts[0])), isA<HitTransition>(), reason: 'existing transitions always show');
  });

  test('marker flag, ruler, playhead knob (free mode only)', () {
    expect(rig.hit(Offset(rig.viewport.xOf(3 * s) + 5, -8)), const HitMarker(MarkerId('mk_1')));
    final t = rig.hit(const Offset(700, -8));
    expect(t, HitRuler(rig.viewport.timeAt(700)));
    expect(rig.hit(Offset(rig.viewport.xOf(7 * s) + 3, -8), playhead: 7 * s), const HitPlayheadKnob());
    expect(rig.hit(Offset(rig.viewport.xOf(7 * s) + 10, -8), playhead: 7 * s), const HitPlayheadKnob(), reason: '24 px pointer target');
    expect(rig.hit(Offset(rig.viewport.xOf(3 * s) + 3, -8), playhead: 3 * s), const HitPlayheadKnob(), reason: 'the knob beats a marker under it');
    final locked = _Rig(mode: PlayheadFollowMode.centreLocked);
    addTearDown(locked.dispose);
    expect(locked.hit(Offset(locked.viewport.xOf(7 * s), -8), playhead: 7 * s), isA<HitRuler>(), reason: 'no knob when centre-locked');
    expect(rig.hit(const Offset(700, -40)), isA<HitEmpty>(), reason: 'above the ruler');
  });

  test('main-lane gap, empty lane, outside lanes', () {
    final li = rig.lane('tr_main');
    final y = rig.geometry.laneTop(li) + 30;
    expect(rig.hit(Offset(rig.viewport.xOf(s ~/ 2), y)), HitGap(lane: const TrackId('tr_main'), gap: TimeRange(0, 1 * s)));
    expect(rig.hit(Offset(rig.viewport.xOf(11 * s + s ~/ 2), y)), HitGap(lane: const TrackId('tr_main'), gap: TimeRange(11 * s, 12 * s)));
    final v2y = rig.geometry.laneTop(rig.lane('tr_video2')) + 30;
    final empty = rig.hit(Offset(rig.viewport.xOf(10 * s), v2y));
    expect(empty, HitEmpty(lane: const TrackId('tr_video2'), time: rig.viewport.timeAt(rig.viewport.xOf(10 * s))));
    expect(rig.hit(Offset(rig.viewport.xOf(20 * s), y)), isA<HitEmpty>(), reason: 'after the last item: no gap');
    final below = rig.hit(Offset(300, rig.geometry.stack.contentHeight + 20));
    expect(below, isA<HitEmpty>());
    expect((below as HitEmpty).lane, isNull);
  });

  test('locked lanes: no handles, items report locked', () {
    final b = rig.body('it_a2');
    final h = rig.hit(Offset(b.right - 3, b.top + 6), selected: {'it_a2'});
    expect(h, isA<HitItem>());
    expect((h as HitItem).locked, isTrue);
  });

  test('vertical scroll moves hits with the lanes', () {
    final short = _Rig(height: 200);
    addTearDown(short.dispose);
    final before = short.body('it_a1');
    short.viewport.jumpTo(scrollY: 40);
    final after = short.body('it_a1');
    expect(after.top, before.top - 40);
    expect(short.hit(after.center), isA<HitItem>());
  });

  testWidgets('RenderTimelineCanvas.hitTestTimeline uses the selection and playhead it paints with', (tester) async {
    final playhead = ValueNotifier<TimeUs>(7 * s);
    addTearDown(playhead.dispose);
    await tester.pumpWidget(Directionality(
      textDirection: TextDirection.ltr,
      child: Align(
        alignment: Alignment.topLeft,
        child: SizedBox(
          width: _width,
          height: _height,
          child: TimelineCanvas(
            snapshot: rig.snapshot,
            viewport: rig.viewport,
            metrics: rig.metrics,
            selection: EditorSelection(items: {const ItemId('it_v3')}, primary: const ItemId('it_v3')),
            playhead: playhead,
          ),
        ),
      ),
    ));
    final canvas = tester.renderObject<RenderTimelineCanvas>(find.byType(TimelineCanvas));
    final b = rig.body('it_v3');
    expect(canvas.hitTestTimeline(Offset(b.right - 3, b.bottom - 6)), isA<HitTrimHandle>());
    expect(canvas.hitTestTimeline(Offset(rig.viewport.xOf(7 * s), -6)), const HitPlayheadKnob());
  });
}
