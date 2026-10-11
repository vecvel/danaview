// OWNER: UX-10
//
// RenderTimelineCanvas (ux.md §8.6): instrumented paint reports prove that only the visible window
// is painted (binary search per lane, lane culling by scrollY), the thumbnail/waveform hooks are
// driven per visible clip (overscan only prefetches), repaints come from the viewport, the hooks,
// the interaction controller and the playhead only when a diamond's fill changes, labels and
// badges follow the width rules, and there is one semantics node per visible item.

import 'package:flutter/foundation.dart';
import 'dart:ui' show Tristate;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vwish_editor/src/editor/caches/paragraph_cache.dart';
import 'package:vwish_editor/src/editor/state/editor_state.dart' show EditorSelection, MediaHealth;
import 'package:vwish_editor/src/editor/timeline/render_timeline_canvas.dart';
import 'package:vwish_editor/src/editor/timeline/timeline_metrics.dart';
import 'package:vwish_editor/src/editor/timeline/timeline_snapshot.dart';
import 'package:vwish_editor/src/editor/timeline/timeline_style.dart';
import 'package:vwish_editor/src/editor/timeline/timeline_viewport.dart';
import 'package:vwish_editor_core/model.dart';

import 'canvas_fixtures.dart';

final _style = TimelineStyle.standard.withFontFamily('Ahem');
const _metrics = TimelineMetrics(touch: false);

class _Thumbs with TimelineThumbnailHook {
  final ValueNotifier<int> notifier = ValueNotifier(0);
  final List<ItemId> painted = [];
  final List<ItemId> prefetched = [];
  int begins = 0, ends = 0;
  bool hit = true;

  @override
  Listenable get changes => notifier;

  @override
  void beginPaint(TimeRange window) {
    begins++;
    painted.clear();
    prefetched.clear();
  }

  @override
  bool paintThumbnails(Canvas canvas, TimelineClipPaint clip) {
    painted.add(clip.item.id);
    expect(clip.overscan, isFalse);
    expect(clip.visible.isEmpty, isFalse);
    return hit;
  }

  @override
  void prefetchThumbnails(TimelineClipPaint clip) {
    expect(clip.overscan, isTrue);
    prefetched.add(clip.item.id);
  }

  @override
  void endPaint() => ends++;
}

class _Waves with TimelineWaveformHook {
  final ValueNotifier<int> notifier = ValueNotifier(0);
  final List<ItemId> painted = [];

  @override
  Listenable get changes => notifier;

  @override
  bool paintWaveform(Canvas canvas, TimelineClipPaint clip, Rect area, Color color) {
    painted.add(clip.item.id);
    expect(area.height, greaterThan(0));
    return true;
  }
}

class _Lifted extends ChangeNotifier implements TimelineCanvasInteraction {
  Set<ItemId> items = {};

  @override
  Set<ItemId> get liftedItems => items;

  void lift(Set<ItemId> ids) {
    items = ids;
    notifyListeners();
  }
}

TimelineViewportController _viewport(TimelineSnapshot snap, {double width = 800, double height = 400, double pps = 100}) {
  final stack = TimelineLaneStack.of(snap.laneKinds, _metrics, presets: snap.laneHeights);
  return TimelineViewportController(defaultMode: PlayheadFollowMode.free, platform: TargetPlatform.android)
    ..setViewport(Size(width, height), 0)
    ..setContent(duration: snap.duration, frameRate: snap.frameRate, contentHeight: stack.contentHeight)
    ..setPxPerSecond(pps)
    ..jumpTo(scrollTimeSec: 0, scrollY: 0);
}

Future<RenderTimelineCanvas> _pump(
  WidgetTester tester, {
  required TimelineSnapshot snapshot,
  required TimelineViewportController viewport,
  double width = 800,
  double height = 400,
  EditorSelection selection = EditorSelection.empty,
  TimelineThumbnailHook? thumbnails,
  TimelineWaveformHook? waveforms,
  TimelineCanvasInteraction? interaction,
  ValueListenable<TimeUs>? playhead,
  bool showAllKeyframes = false,
  TimelineSemanticsDecorator? decorator,
  ParagraphCache? paragraphs,
}) async {
  tester.view
    ..devicePixelRatio = 1
    ..physicalSize = Size(width < 800 ? 800 : width, height < 600 ? 600 : height);
  addTearDown(tester.view.reset);
  await tester.pumpWidget(Directionality(
    textDirection: TextDirection.ltr,
    child: Align(
      alignment: Alignment.topLeft,
      child: SizedBox(
        width: width,
        height: height,
        child: TimelineCanvas(
          snapshot: snapshot,
          viewport: viewport,
          selection: selection,
          thumbnails: thumbnails,
          waveforms: waveforms,
          interaction: interaction,
          playhead: playhead,
          showAllKeyframes: showAllKeyframes,
          semanticsDecorator: decorator,
          paragraphs: paragraphs,
          style: _style,
          metrics: _metrics,
        ),
      ),
    ),
  ));
  return tester.renderObject<RenderTimelineCanvas>(find.byType(TimelineCanvas));
}

void main() {
  group('visible window', () {
    testWidgets('2,000 items x 4 lanes: only on-screen items paint; overscan is half a viewport each side', (tester) async {
      final snap = TimelineSnapshotBuilder().build(largeProject());
      final viewport = _viewport(snap, height: 400);
      addTearDown(viewport.dispose);
      final thumbs = _Thumbs();
      final canvas = await _pump(tester, snapshot: snap, viewport: viewport, height: 400, thumbnails: thumbs);
      var report = canvas.debugLastPaint!;
      // 800 px at 100 px/s = 8 s: items 0..7 on each of the 4 lanes.
      expect(report.lanes, [0, 1, 2, 3]);
      expect(report.items.length, 4 * 8);
      expect(report.overscanItems.length, 4 * 4, reason: 'only after 8 s: [8 s, 12 s) on each lane');
      expect(thumbs.painted.length, 8, reason: 'video lane only');
      expect(thumbs.prefetched.length, 4);
      expect((thumbs.begins, thumbs.ends), (1, 1));

      viewport.jumpTo(scrollTimeSec: 1000);
      await tester.pump();
      report = canvas.debugLastPaint!;
      expect(report.items.length, 4 * 8);
      expect(report.overscanItems.length, 4 * 8);
      expect(report.items, everyElement(predicate<ItemId>((id) {
        final m = snap.item(id)!;
        return m.end > 1000 * s && m.start < 1008 * s;
      }, 'on screen')));
      expect(report.overscanItems, everyElement(predicate<ItemId>((id) {
        final m = snap.item(id)!;
        return m.end > 996 * s && m.start < 1012 * s;
      }, 'in the overscan')));
    });

    testWidgets('lanes outside scrollY are not visited', (tester) async {
      final snap = TimelineSnapshotBuilder().build(largeProject(count: 50, lanes: 8));
      final viewport = _viewport(snap, height: 100);
      addTearDown(viewport.dispose);
      final canvas = await _pump(tester, snapshot: snap, viewport: viewport, height: 100);
      // Video 60 + gap + audio 48 ... : the first 100 px show lanes 0 and 1.
      expect(canvas.debugLastPaint!.lanes, [0, 1]);
      viewport.jumpTo(scrollY: 200);
      await tester.pump();
      final lanes = canvas.debugLastPaint!.lanes;
      expect(lanes.first, greaterThan(1));
      expect(lanes.length, lessThanOrEqualTo(3));
      expect(canvas.debugLastPaint!.items.map((id) => snap.locate(id)!.lane).toSet(), lanes.toSet());
    });

    testWidgets('painting stays bounded at 2,000 items (O(log n + visible))', (tester) async {
      final snap = TimelineSnapshotBuilder().build(largeProject());
      final viewport = _viewport(snap);
      addTearDown(viewport.dispose);
      final canvas = await _pump(tester, snapshot: snap, viewport: viewport);
      for (final t in [0.0, 500.0, 1500.0, 1990.0]) {
        viewport.jumpTo(scrollTimeSec: t);
        await tester.pump();
        final r = canvas.debugLastPaint!;
        expect(r.items.length + r.overscanItems.length, lessThanOrEqualTo(4 * 17), reason: 'at $t s');
      }
    });
  });

  group('content', () {
    testWidgets('labels, durations, badges, excerpts, placeholders, offline and cuts', (tester) async {
      final snap = TimelineSnapshotBuilder().build(richProject(), health: MediaHealth(missing: {const MediaId('m_lost')}));
      final viewport = _viewport(snap, width: 1800, height: 420);
      addTearDown(viewport.dispose);
      final canvas = await _pump(tester, snapshot: snap, viewport: viewport, width: 1800, height: 420);
      final r = canvas.debugLastPaint!;
      expect(r.labels, contains('beach.mp4 · 0:04'), reason: '400 px: name and duration');
      expect(r.labels, contains('Hello world'), reason: 'text excerpt');
      expect(r.labels, contains('First caption'));
      expect(r.labels, contains(TimelineCanvasStrings.missing));
      expect(r.badges[const ItemId('it_v3')], 1, reason: 'speed');
      expect(r.badges[const ItemId('it_v6')], greaterThan(3));
      expect(r.cuts, [
        (const TransitionRef(TrackId('tr_main'), ItemId('it_v1'), ItemId('it_v2')), false),
        (const TransitionRef(TrackId('tr_main'), ItemId('it_v2'), ItemId('it_v3')), true),
        (const TransitionRef(TrackId('tr_main'), ItemId('it_v4'), ItemId('it_v5')), true),
      ]);
      expect(r.gaps, [TimeRange(0, 1 * s), TimeRange(11 * s, 12 * s)]);
      expect(r.thumbnailPlaceholders, greaterThan(0), reason: 'no thumbnail hook');
      expect(r.waveformFallbacks, greaterThan(0), reason: 'no waveform hook');
    });

    testWidgets('narrow clips: no label under 72 px, no duration under 120 px, badges collapse', (tester) async {
      final snap = TimelineSnapshotBuilder().build(richProject());
      final viewport = _viewport(snap, width: 600, pps: 20);
      addTearDown(viewport.dispose);
      final canvas = await _pump(tester, snapshot: snap, viewport: viewport, width: 600);
      final r = canvas.debugLastPaint!;
      // 20 px/s: it_v6 is 120 px (label + duration), it_v1 80 px (label only), it_v2 60 px (none).
      expect(r.labels, contains('Graded · 0:06'));
      expect(r.labels, contains('beach.mp4'));
      expect(r.labels.where((l) => l.startsWith('beach.mp4 ·')), isEmpty);
      expect(r.labels.where((l) => l.startsWith('photo.jpg')), isEmpty);
      // it_v6 has 9 badges in 120 px: they collapse into a count chip.
      expect(r.badges[const ItemId('it_v6')], lessThan(9));
      expect(r.badges[const ItemId('it_v6')], greaterThan(0));
    });

    testWidgets('hooks: thumbnails for visual clips, waveforms for audio; arrivals repaint', (tester) async {
      final snap = TimelineSnapshotBuilder().build(richProject());
      final viewport = _viewport(snap, width: 1800, height: 420);
      addTearDown(viewport.dispose);
      final thumbs = _Thumbs(), waves = _Waves();
      final canvas = await _pump(tester, snapshot: snap, viewport: viewport, width: 1800, height: 420, thumbnails: thumbs, waveforms: waves);
      expect(thumbs.painted, containsAll(const [ItemId('it_v1'), ItemId('it_v2'), ItemId('it_o1'), ItemId('it_v6')]));
      expect(thumbs.painted, isNot(contains(const ItemId('it_a1'))));
      expect(waves.painted, containsAll(const [ItemId('it_a1'), ItemId('it_a2')]));
      expect(canvas.debugLastPaint!.thumbnailPlaceholders, 0);
      final before = canvas.debugPaintCount;
      thumbs.notifier.value++;
      await tester.pump();
      waves.notifier.value++;
      await tester.pump();
      expect(canvas.debugPaintCount, before + 2);
    });
  });

  group('repaints', () {
    testWidgets('viewport changes repaint; unrelated rebuilds do not', (tester) async {
      final snap = TimelineSnapshotBuilder().build(richProject());
      final viewport = _viewport(snap);
      addTearDown(viewport.dispose);
      final canvas = await _pump(tester, snapshot: snap, viewport: viewport);
      final n = canvas.debugPaintCount;
      await _pump(tester, snapshot: snap, viewport: viewport);
      expect(canvas.debugPaintCount, n, reason: 'same inputs');
      viewport.scrollByPx(50, 0);
      await tester.pump();
      expect(canvas.debugPaintCount, n + 1);
    });

    testWidgets('the playhead repaints only when a painted diamond changes its fill', (tester) async {
      final snap = TimelineSnapshotBuilder().build(richProject());
      final viewport = _viewport(snap, height: 420);
      addTearDown(viewport.dispose);
      final playhead = ValueNotifier<TimeUs>(0);
      addTearDown(playhead.dispose);
      final canvas = await _pump(tester, snapshot: snap, viewport: viewport, height: 420, playhead: playhead);
      var n = canvas.debugPaintCount;
      playhead.value = 1 * s + f(30); // o1's key, but o1 is not selected
      await tester.pump();
      expect(canvas.debugPaintCount, n, reason: 'no diamonds painted');

      await _pump(tester,
          snapshot: snap,
          viewport: viewport,
          height: 420,
          playhead: playhead,
          selection: EditorSelection(items: {const ItemId('it_o1')}, primary: const ItemId('it_o1')));
      expect(canvas.debugLastPaint!.diamonds, 3);
      expect(canvas.debugLastPaint!.filledDiamonds, 1);
      n = canvas.debugPaintCount;
      playhead.value = 1 * s + f(31);
      await tester.pump();
      expect(canvas.debugPaintCount, n + 1, reason: 'the filled diamond empties');
      expect(canvas.debugLastPaint!.filledDiamonds, 0);
      playhead.value = 1 * s + f(40);
      await tester.pump();
      expect(canvas.debugPaintCount, n + 1, reason: 'between keys: nothing changes');
      playhead.value = 1 * s + f(60);
      await tester.pump();
      expect(canvas.debugPaintCount, n + 2);
      expect(canvas.debugLastPaint!.filledDiamonds, 1);
    });

    testWidgets('Keyframes tool: diamonds of every visible item', (tester) async {
      final snap = TimelineSnapshotBuilder().build(richProject());
      final viewport = _viewport(snap, width: 1800, height: 420);
      addTearDown(viewport.dispose);
      final canvas = await _pump(tester, snapshot: snap, viewport: viewport, width: 1800, height: 420, showAllKeyframes: true);
      // o1: 3, v6: 2, t1: 1, a1: 2.
      expect(canvas.debugLastPaint!.diamonds, 8);
    });

    testWidgets('lifted items repaint from the interaction controller', (tester) async {
      final snap = TimelineSnapshotBuilder().build(richProject());
      final viewport = _viewport(snap);
      addTearDown(viewport.dispose);
      final lifted = _Lifted();
      addTearDown(lifted.dispose);
      final canvas = await _pump(tester, snapshot: snap, viewport: viewport, interaction: lifted);
      final n = canvas.debugPaintCount;
      lifted.lift({const ItemId('it_v1')});
      await tester.pump();
      expect(canvas.debugPaintCount, n + 1);
    });

    testWidgets('a shared paragraph cache is reused across paints', (tester) async {
      final snap = TimelineSnapshotBuilder().build(richProject());
      final viewport = _viewport(snap);
      addTearDown(viewport.dispose);
      final cache = ParagraphCache();
      final lifted = _Lifted();
      addTearDown(lifted.dispose);
      final canvas = await _pump(tester, snapshot: snap, viewport: viewport, paragraphs: cache, interaction: lifted);
      final misses = cache.misses;
      final paints = canvas.debugPaintCount;
      lifted.lift({});
      await tester.pump();
      expect(canvas.debugPaintCount, paints + 1);
      expect(cache.misses, misses, reason: 'a repaint lays out no paragraph again');
      expect(cache.hits, greaterThan(0));
    });
  });

  group('semantics', () {
    testWidgets('one node per visible item, with label, selected flag and decorator actions', (tester) async {
      final handle = tester.ensureSemantics();
      final snap = TimelineSnapshotBuilder().build(richProject());
      final viewport = _viewport(snap, width: 600, height: 420);
      addTearDown(viewport.dispose);
      final decorated = <ItemId>[];
      final canvas = await _pump(
        tester,
        snapshot: snap,
        viewport: viewport,
        width: 600,
        height: 420,
        selection: EditorSelection(items: {const ItemId('it_v1')}, primary: const ItemId('it_v1')),
        decorator: (target, config) {
          decorated.add(target.item.id);
          config.onTap = () {};
        },
      );
      final visible = canvas.visibleSemanticsTargets();
      // 600 px at 100 px/s = 0..6 s.
      expect(visible.map((t) => t.$1.item.id).toSet(), {
        'it_c1', 'it_c2', 'it_t1', 'it_o1', 'it_v6', 'it_v1', 'it_v2', 'it_a1', 'it_a2', //
      });
      final node = tester.getSemantics(find.byType(TimelineCanvas));
      final children = <SemanticsNode>[];
      node.visitChildren((c) {
        children.add(c);
        return true;
      });
      expect(children.length, visible.length);
      expect(decorated.toSet(), visible.map((t) => t.$1.item.id).toSet());
      final v1 = children.firstWhere((c) => c.label.startsWith('Video clip, beach.mp4'));
      expect(v1.getSemanticsData().flagsCollection.isSelected, Tristate.isTrue);
      expect(v1.getSemanticsData().hasAction(SemanticsAction.tap), isTrue);
      expect(v1.label, contains('length 0:04'));
      final locked = children.firstWhere((c) => c.label.contains('Audio clip') && c.label.contains('track locked'));
      expect(locked.getSemanticsData().flagsCollection.isSelected, isNot(Tristate.isTrue));

      // Scrolling changes the visible set.
      viewport.jumpTo(scrollTimeSec: 10);
      await tester.pump();
      final after = <String>[];
      tester.getSemantics(find.byType(TimelineCanvas)).visitChildren((c) {
        after.add(c.label);
        return true;
      });
      expect(after.length, canvas.visibleSemanticsTargets().length);
      expect(after.any((l) => l.contains('lost.mp4')), isTrue);
      expect(after.any((l) => l.contains('beach.mp4')), isFalse);
      handle.dispose();
    });
  });
}
