// OWNER: UX-09
//
// Ruler goldens (ux.md §21.3): the ruler at frame scale (48 px per frame, frame timecodes across a
// second boundary) and at minute scale (a 20 min project fitted, text scale 1.35), each with marker
// flags (one selected, one in a palette colour), rendered with the Ahem test font at device pixel
// ratio 1 and 3. Goldens guard visual regressions only; overflow and spacing are checked in
// ruler_widget_test.dart.
//
// Regenerate (after reviewing the change) with:
//   flutter test --update-goldens test/timeline/viewport/ruler_golden_test.dart

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_editor/src/editor/timeline/ruler.dart';
import 'package:danaview_editor/src/editor/timeline/timeline_metrics.dart';
import 'package:danaview_editor/src/editor/timeline/timeline_style.dart';
import 'package:danaview_editor/src/editor/timeline/timeline_viewport.dart';
import 'package:danaview_editor_core/model.dart';

const _s = microsPerSecond;
const _width = 480.0;

/// A golden comparator that tolerates a small share of differing pixels, so anti-aliasing
/// differences between the macOS and Linux test hosts do not fail the run.
class _TolerantComparator extends LocalFileComparator {
  _TolerantComparator(super.testFile, {required this.tolerance});

  /// Largest accepted share of differing pixels (0..1).
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
  const _Scene(this.name, {required this.textScale, required this.setUp, this.markers = const [], this.selected});

  final String name;
  final double textScale;
  final void Function(TimelineViewportController viewport) setUp;
  final List<Marker> markers;
  final MarkerId? selected;
}

final _scenes = [
  _Scene(
    'frames',
    textScale: 1,
    // 30 fps at 48 px per frame from 60.8 s: frame labels 1:00:25 and 1:01:00 (the 5f step restarts
    // at the second), one minor tick per frame.
    setUp: (v) => v
      ..setContent(duration: 90 * _s, frameRate: FrameRate.fps30)
      ..setPxPerSecond(FrameRate.fps30.fps * TimelineViewportController.maxPxPerFrame)
      ..jumpTo(scrollTimeSec: 60.8),
    markers: [
      Marker(id: const MarkerId('mk_000000000001'), time: FrameRate.fps30.timeOfFrame(30 * 60 + 27)),
      Marker(id: const MarkerId('mk_000000000002'), time: FrameRate.fps30.timeOfFrame(30 * 61 + 3), colorIndex: 3),
    ],
    selected: const MarkerId('mk_000000000002'),
  ),
  _Scene(
    'minutes',
    textScale: 1.35,
    // A 20 min project fitted: 5 min majors, one minor per minute.
    setUp: (v) => v
      ..setContent(duration: 20 * 60 * _s, frameRate: FrameRate.fps30)
      ..zoomToFit(),
    markers: const [
      Marker(id: MarkerId('mk_000000000003'), time: 90 * _s),
      Marker(id: MarkerId('mk_000000000004'), time: 7 * 60 * _s, colorIndex: 1),
      Marker(id: MarkerId('mk_000000000005'), time: 13 * 60 * _s, colorIndex: 5),
    ],
    selected: const MarkerId('mk_000000000004'),
  ),
];

void main() {
  late GoldenFileComparator previous;

  setUpAll(() {
    previous = goldenFileComparator;
    if (previous is LocalFileComparator) {
      final base = (previous as LocalFileComparator).basedir;
      goldenFileComparator = _TolerantComparator(base.resolve('ruler_golden_test.dart'), tolerance: 0.005);
    }
  });

  tearDownAll(() => goldenFileComparator = previous);

  for (final scene in _scenes) {
    for (final dpr in [1.0, 3.0]) {
      testWidgets('ruler at ${scene.name} scale, DPR ${dpr.toInt()}', (tester) async {
        final height = TimelineMetrics(textScale: scene.textScale).rulerHeight;
        tester.view
          ..devicePixelRatio = dpr
          ..physicalSize = const Size(_width, 64) * dpr;
        addTearDown(tester.view.reset);

        final viewport = TimelineViewportController(defaultMode: PlayheadFollowMode.free, platform: TargetPlatform.android);
        addTearDown(viewport.dispose);
        viewport.setViewport(const Size(_width, 200), 0, rulerHeight: height);
        scene.setUp(viewport);

        await tester.pumpWidget(Directionality(
          textDirection: TextDirection.ltr,
          child: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: _width,
              child: TimelineRuler(
                viewport: viewport,
                markers: scene.markers,
                selectedMarker: scene.selected,
                style: TimelineStyle.standard.withFontFamily('Ahem'),
                metrics: TimelineMetrics(textScale: scene.textScale),
              ),
            ),
          ),
        ));

        final ruler = tester.renderObject<RenderTimelineRuler>(find.byType(TimelineRuler));
        expect(ruler.size, Size(_width, height));
        expect(ruler.devicePixelRatio, dpr);
        // The ruler is a repaint boundary: render its layer at the device pixel ratio.
        final layer = ruler.debugLayer! as OffsetLayer;
        final image = (await tester.runAsync<ui.Image>(() => layer.toImage(Offset.zero & ruler.size, pixelRatio: dpr)))!;
        addTearDown(image.dispose);
        expect(image.width, (_width * dpr).round());
        await expectLater(image, matchesGoldenFile('goldens/ruler_${scene.name}_dpr${dpr.toInt()}.png'));
      });
    }
  }
}
