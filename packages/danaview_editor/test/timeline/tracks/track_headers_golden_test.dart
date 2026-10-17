// OWNER: UX-11
//
// The header column at the four layout widths (44 compact, 132 medium, 168 expanded pointer, 220
// expanded touch) over every lane kind and flag state: locked, hidden, muted and soloed lanes,
// a selected lane, the "S" and lock glyphs when flags do not fit. Ahem font.
//
// Regenerate (after reviewing the change) with:
//   flutter test --update-goldens test/timeline/tracks/track_headers_golden_test.dart

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_editor/src/editor/timeline/timeline_metrics.dart';
import 'package:danaview_editor/src/editor/timeline/timeline_snapshot.dart';
import 'package:danaview_editor/src/editor/timeline/timeline_viewport.dart';
import 'package:danaview_editor/src/editor/timeline/track_headers.dart';
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_ui_kit/danaview_ui_kit.dart';

import '../../support/support.dart';
import 'track_test_support.dart';

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

void main() {
  late GoldenFileComparator previous;

  setUpAll(() {
    previous = goldenFileComparator;
    if (previous is LocalFileComparator) {
      final base = (previous as LocalFileComparator).basedir;
      goldenFileComparator = _TolerantComparator(base.resolve('track_headers_golden_test.dart'), tolerance: 0.005);
    }
  });

  tearDownAll(() => goldenFileComparator = previous);

  for (final scale in [1.0, 1.35]) {
    testWidgets('headers at 44, 132, 168 and 220 px, text ${scale}x', (tester) async {
      var project = allKindsProject();
      project = withTrack(project, 'tr_video2', (t) => t.copyWith(locked: true));
      project = withTrack(project, 'tr_overlay', (t) => t.copyWith(hidden: true));
      project = withTrack(project, 'tr_music', (t) => t.copyWith(muted: true, solo: true));
      project = withTrack(project, 'tr_text', (t) => t.copyWith(name: 'A long text track name'));
      final snapshot = TimelineSnapshotBuilder().build(project);
      const widths = [44.0, 132.0, 168.0, 220.0];
      const gap = 12.0;
      final metrics0 = TimelineMetrics(textScale: scale);
      final stack = TimelineLaneStack.of(snapshot.laneKinds, metrics0, presets: snapshot.laneHeights);
      final totalWidth = widths.fold<double>(0, (a, b) => a + b) + gap * (widths.length + 2);
      final height = stack.contentHeight + 2 * gap;
      final surface = EditorSurface(Size(totalWidth, height), textScale: scale);
      applySurface(tester, surface);
      final viewport = TimelineViewportController(defaultMode: PlayheadFollowMode.free, platform: TargetPlatform.android)
        ..setViewport(Size(800, height), 44)
        ..setContent(duration: snapshot.duration, frameRate: snapshot.frameRate, contentHeight: stack.contentHeight);
      addTearDown(viewport.dispose);
      final sink = RecordingSink();
      await tester.pumpWidget(surfaceApp(
        surface,
        RepaintBoundary(
          key: const ValueKey('shot'),
          child: ColoredBox(
            color: DanaviewColors.background,
            child: Padding(
              padding: const EdgeInsets.all(gap),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final (i, w) in widths.indexed) ...[
                    SizedBox(
                      width: w,
                      height: stack.contentHeight,
                      child: TrackHeaders(
                        snapshot: snapshot,
                        viewport: viewport,
                        metrics: TimelineMetrics(textScale: scale, headerWidth: w, touch: i == 3),
                        actions: sink.actions(),
                        selectedLane: const TrackId('tr_main'),
                      ),
                    ),
                    const SizedBox(width: gap),
                  ],
                ],
              ),
            ),
          ),
        ),
      ));
      await tester.pump();
      await expectLater(find.byKey(const ValueKey('shot')), matchesGoldenFile('goldens/headers_${scale == 1.0 ? '1x' : '1_35x'}.png'));
    });
  }
}
