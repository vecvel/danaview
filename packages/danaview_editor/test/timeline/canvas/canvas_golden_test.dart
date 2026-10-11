// OWNER: UX-10
//
// Timeline canvas goldens (ux.md §8.6, §21.3) at four zooms (whole project, seconds, detail and
// one frame = 48 px) over the rich project: every item kind (video, image, freeze, audio, text,
// cue) and state (selected with fade handles, volume line and diamonds, a filled diamond at the
// playhead, offline, pending, locked and hidden lanes, badges, a transition bowtie (selected in
// one scene), the main-lane "+", hatched gaps (one selected), overlay stripes, fades). Ahem font;
// DPR 1, plus DPR 3 at one zoom. The frame-scale scene uses text scale 1.35.
//
// Regenerate (after reviewing the change) with:
//   flutter test --update-goldens test/timeline/canvas/canvas_golden_test.dart

import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_editor/src/editor/state/editor_state.dart' show EditorSelection, MediaHealth;
import 'package:danaview_editor/src/editor/timeline/render_timeline_canvas.dart';
import 'package:danaview_editor/src/editor/timeline/timeline_metrics.dart';
import 'package:danaview_editor/src/editor/timeline/timeline_snapshot.dart';
import 'package:danaview_editor/src/editor/timeline/timeline_style.dart';
import 'package:danaview_editor/src/editor/timeline/timeline_viewport.dart';
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_editor_core/ops.dart' show GapRef;

import 'canvas_fixtures.dart';

const _width = 900.0;

/// A golden comparator that tolerates a small share of differing pixels (anti-aliasing differences
/// between the macOS and Linux test hosts).
class _TolerantComparator extends LocalFileComparator {
  _TolerantComparator(super.testFile, {required this.tolerance});

  final double tolerance;

  @override
  Future<bool> compare(Uint8List imageBytes, Uri golden) async {
    final result = await GoldenFileComparator.compareLists(imageBytes, await getGoldenBytes(golden));
    if (result.passed || result.diffPercent <= tolerance) {
      result.dispose();
      return true;
    }
    final error = await generateFailureOutput(result, golden, basedir);
    result.dispose();
    throw FlutterError(error);
  }
}

class _Scene {
  const _Scene(this.name, {required this.setUp, this.textScale = 1, this.selection, this.dprs = const [1.0]});

  final String name;
  final void Function(TimelineViewportController v) setUp;
  final double textScale;
  final EditorSelection? selection;
  final List<double> dprs;
}

final _selected = {const ItemId('it_v1'), const ItemId('it_a1'), const ItemId('it_o1')};

final _scenes = [
  _Scene(
    'fit',
    setUp: (v) => v.zoomToFit(),
    selection: EditorSelection(items: _selected, primary: const ItemId('it_v1'), gap: GapRef(const TrackId('tr_main'), TimeRange(11 * s, 12 * s))),
  ),
  _Scene('seconds', setUp: (v) => v
    ..setPxPerSecond(80)
    ..jumpTo(scrollTimeSec: 0), dprs: const [1.0, 3.0]),
  _Scene(
    'detail',
    setUp: (v) => v
      ..setPxPerSecond(240)
      ..jumpTo(scrollTimeSec: 3),
    selection: EditorSelection(
      items: _selected,
      primary: const ItemId('it_v1'),
      transition: const TransitionRef(TrackId('tr_main'), ItemId('it_v1'), ItemId('it_v2')),
    ),
  ),
  _Scene(
    'frames',
    textScale: 1.35,
    setUp: (v) => v
      ..setPxPerSecond(FrameRate.fps30.fps * TimelineViewportController.maxPxPerFrame)
      ..jumpTo(scrollTimeSec: 4.8),
  ),
];

void main() {
  late GoldenFileComparator previous;

  setUpAll(() {
    previous = goldenFileComparator;
    if (previous is LocalFileComparator) {
      final base = (previous as LocalFileComparator).basedir;
      goldenFileComparator = _TolerantComparator(base.resolve('canvas_golden_test.dart'), tolerance: 0.005);
    }
  });

  tearDownAll(() => goldenFileComparator = previous);

  for (final scene in _scenes) {
    for (final dpr in scene.dprs) {
      testWidgets('canvas at ${scene.name} zoom, DPR ${dpr.toInt()}', (tester) async {
        final metrics = TimelineMetrics(textScale: scene.textScale, touch: false);
        final snap = TimelineSnapshotBuilder().build(richProject(), health: MediaHealth(missing: {const MediaId('m_lost')}));
        final stack = TimelineLaneStack.of(snap.laneKinds, metrics, presets: snap.laneHeights);
        final height = stack.contentHeight + 4;
        tester.view
          ..devicePixelRatio = dpr
          ..physicalSize = Size(_width, height) * dpr;
        addTearDown(tester.view.reset);

        final viewport = TimelineViewportController(defaultMode: PlayheadFollowMode.free, platform: TargetPlatform.android)
          ..setViewport(Size(_width, height), 0)
          ..setContent(duration: snap.duration, frameRate: snap.frameRate, contentHeight: stack.contentHeight);
        addTearDown(viewport.dispose);
        scene.setUp(viewport);
        final playhead = ValueNotifier<TimeUs>(1 * s + f(30));
        addTearDown(playhead.dispose);

        await tester.pumpWidget(Directionality(
          textDirection: TextDirection.ltr,
          child: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: _width,
              height: height,
              child: TimelineCanvas(
                snapshot: snap,
                viewport: viewport,
                selection: scene.selection ?? EditorSelection(items: _selected, primary: const ItemId('it_v1')),
                playhead: playhead,
                style: TimelineStyle.standard.withFontFamily('Ahem'),
                metrics: metrics,
              ),
            ),
          ),
        ));

        final canvas = tester.renderObject<RenderTimelineCanvas>(find.byType(TimelineCanvas));
        expect(canvas.size, Size(_width, height));
        expect(canvas.debugLastPaint!.items, isNotEmpty);
        final layer = canvas.debugLayer! as OffsetLayer;
        final image = (await tester.runAsync<ui.Image>(() => layer.toImage(Offset.zero & canvas.size, pixelRatio: dpr)))!;
        addTearDown(image.dispose);
        await expectLater(image, matchesGoldenFile('goldens/canvas_${scene.name}_dpr${dpr.toInt()}.png'));
      });
    }
  }
}
