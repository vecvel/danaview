// OWNER: UX-43
//
// UX-43 is closed as "not needed" on the QA-04 evidence (docs/v1.1/editor/qa/QA-04-performance.md:
// timeline UI p90 2.9–3.3 ms, p99 5.6–12 ms against the low-tier ≤ 8 / ≤ 14 ms budgets). These
// tests pin the disabled pass-through seam so a later tile cache can drop in without a canvas edit.

import 'dart:ui' show Canvas, PictureRecorder, Rect;

import 'package:danaview_editor/src/editor/timeline/timeline_tiles.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('disabled tiles never cache', () {
    const tiles = TimelineTiles.disabled();
    expect(tiles.enabled, isFalse);
  });

  test('paint calls the direct painter exactly once with the same canvas and window', () {
    const tiles = TimelineTiles.disabled();
    final recorder = PictureRecorder();
    final canvas = Canvas(recorder);
    const window = Rect.fromLTWH(120, 0, 640, 300);
    final calls = <(Canvas, Rect)>[];
    tiles.paint(canvas, window, (c, w) => calls.add((c, w)));
    expect(calls, hasLength(1));
    expect(identical(calls.single.$1, canvas), isTrue);
    expect(calls.single.$2, window);
    recorder.endRecording().dispose();
  });

  test('invalidate and dispose are safe no-ops, repeatedly', () {
    const tiles = TimelineTiles.disabled();
    tiles
      ..invalidate()
      ..invalidate()
      ..dispose()
      ..dispose();
    var painted = 0;
    final recorder = PictureRecorder();
    tiles.paint(Canvas(recorder), Rect.zero, (_, __) => painted++);
    expect(painted, 1);
    recorder.endRecording().dispose();
  });
}
