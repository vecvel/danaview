// OWNER: QA-09
//
// The overflow rig catches what it must (BUILD_PLAN QA-09): a RenderFlex overflow, a widget outside
// the screen, a truncated button label and a known defect; the surface filter; and the real fonts
// are loaded (Figtree measures narrower than the test font's 1 em squares).

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_ui_kit/danaview_ui_kit.dart';

import '../support/support.dart';
import 'overflow_rig.dart';

void main() {
  setUpAll(loadRealFonts);

  Future<void> pump(WidgetTester tester, Widget child, {Size size = const Size(280, 500)}) async {
    applySurface(tester, EditorSurface(size, textScale: 1.35));
    await tester.pumpWidget(surfaceApp(EditorSurface(size, textScale: 1.35), Center(child: child)));
    await tester.pump();
  }

  testWidgets('a RenderFlex overflow is reported with its message', (tester) async {
    final previous = FlutterError.onError;
    takeErrors();
    FlutterError.onError = collectError;
    try {
      await pump(tester, const SizedBox(width: 100, child: Row(children: [SizedBox(width: 300, height: 10)])));
      final problems = problemsOf(tester, state: 'row');
      expect(problems.single, contains('A RenderFlex overflowed'));
      expect(problems.single, startsWith('[row] exception: '));
    } finally {
      FlutterError.onError = previous;
    }
  });

  testWidgets('a widget outside the screen and a truncated button label are reported', (tester) async {
    const key = ValueKey('wide');
    await pump(
      tester,
      Stack(clipBehavior: Clip.none, children: [
        const Positioned(left: 250, top: 0, child: SizedBox(key: key, width: 100, height: 20)),
        Positioned(
          left: 0,
          top: 40,
          width: 120,
          child: DanaviewButton(label: 'A button label that cannot fit in 120 px', onPressed: () {}),
        ),
      ]),
    );
    final problems = problemsOf(tester, inside: [find.byKey(key)], state: 's');
    expect(problems, hasLength(2), reason: problems.join('\n'));
    expect(problems[0], contains('outside'));
    expect(problems[1], contains('DanaviewButton label "A button label'));
    expect(truncatedChrome(tester), hasLength(1));
  });

  testWidgets('a short label fits fully with the real font', (tester) async {
    await pump(tester, SizedBox(width: 200, child: DanaviewButton(label: 'Reset transform', onPressed: () {})));
    expect(problemsOf(tester), isEmpty);
    final paragraph = tester.renderObject<RenderParagraph>(find.text('Reset transform'));
    // 15 glyphs at 14 px in the 1 em test font would be 210 px wide; Figtree is far narrower.
    expect(paragraph.size.width, lessThan(150));
  });

  test('known defects match their pattern only', () {
    for (final d in knownDefects) {
      expect(knownDefectOf('[x] exception: ${d.pattern}'), d.id);
    }
    expect(knownDefectOf('[x] exception: A RenderFlex overflowed by 3 pixels'), isNull);
  });

  test('the run covers the PR subset, or the full matrix under DANAVIEW_SURFACE_MATRIX=full', () {
    final surfaces = overflowSurfaces();
    if (overflowSurfaceFilter.isNotEmpty) {
      expect(surfaces.single.name, overflowSurfaceFilter);
    } else {
      expect(surfaces, SurfaceMatrix.current);
    }
  });
}
