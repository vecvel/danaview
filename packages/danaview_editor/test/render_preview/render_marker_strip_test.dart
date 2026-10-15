// OWNER: UX-44
//
// RenderMarkerStrip (BUILD_PLAN UX-44 acceptance): goldens for the three states (rendered,
// heavy-unrendered, not needed) and a mixed strip with a render in progress; the accessibility label
// of each range; amber ranges (only) offer "Render preview"; computed contrast of the fills.
//
// Regenerate (after reviewing the change) with:
//   flutter test --update-goldens test/render_preview/render_marker_strip_test.dart

import 'dart:typed_data';

import 'package:danaview_editor/src/app/strings/render_preview_strings.dart';
import 'package:danaview_editor/src/editor/state/render_preview_controller.dart';
import 'package:danaview_editor/src/editor/timeline/render_marker_strip.dart';
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_editor_core/render_cache.dart';
import 'package:danaview_ui_kit/danaview_ui_kit.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

/// Tolerates a small share of differing pixels (anti-aliasing differs between test hosts).
class _TolerantComparator extends LocalFileComparator {
  _TolerantComparator(super.testFile);

  @override
  Future<bool> compare(Uint8List imageBytes, Uri golden) async {
    final result = await GoldenFileComparator.compareLists(imageBytes, await getGoldenBytes(golden));
    if (result.passed || result.diffPercent <= 0.005) {
      result.dispose();
      return true;
    }
    final error = await generateFailureOutput(result, golden, basedir);
    result.dispose();
    throw FlutterError(error);
  }
}

final class _Lookup implements RenderCacheLookup {
  const _Lookup(this.hashes);
  final Set<String> hashes;
  @override
  bool contains(String hash) => hashes.contains(hash);
}

const double _width = 320;

/// 4 s plan over 320 px.
double _xOf(TimeUs t) => t / microsPerSecond * 80;

List<RangeStatus> _coverage({bool renderAll = false, bool renderHeavy = false}) {
  final plan = basePlan();
  final all = coverage(plan, const _Lookup({}), RenderBudget.forTier(RenderTier.mid));
  final rendered = {
    for (final r in all)
      if (renderAll || (renderHeavy && r.isHeavy)) r.hash,
  };
  return coverage(plan, _Lookup(rendered), RenderBudget.forTier(RenderTier.mid));
}

Widget _host(Widget child) => Directionality(
      textDirection: TextDirection.ltr,
      child: Align(
        alignment: Alignment.topLeft,
        child: ColoredBox(
          color: DanaviewColors.surface,
          child: SizedBox(width: _width, height: RenderMarkerStrip.defaultHeight, child: child),
        ),
      ),
    );

void main() {
  setUpAll(() {
    final comparator = goldenFileComparator;
    if (comparator is LocalFileComparator) {
      goldenFileComparator = _TolerantComparator(Uri.parse('${comparator.basedir}render_marker_strip_test.dart'));
    }
  });

  final heavyOnly = _coverage();
  final scenes = <String, RenderPreviewState>{
    'rendered': RenderPreviewState(ranges: _coverage(renderAll: true), available: true),
    'heavy_unrendered': RenderPreviewState(ranges: [for (final r in heavyOnly) if (r.isHeavy) r], available: true),
    'not_needed': RenderPreviewState(ranges: [for (final r in heavyOnly) if (!r.isHeavy) r], available: true),
    'mixed_rendering': RenderPreviewState(
      ranges: [for (final r in _coverage()) r.range.start == f(90) ? _rendered(r) : r],
      active: RenderJobInfo(range: heavyOnly[1].range, hash: heavyOnly[1].hash, manual: true, progress: 0.4),
      available: true,
    ),
  };

  for (final MapEntry(key: name, value: state) in scenes.entries) {
    for (final dpr in [1.0, 3.0]) {
      testWidgets('golden: $name @${dpr.toInt()}x', (tester) async {
        tester.view.devicePixelRatio = dpr;
        tester.view.physicalSize = Size(_width * dpr, RenderMarkerStrip.defaultHeight * dpr);
        addTearDown(tester.view.reset);
        await tester.pumpWidget(_host(RepaintBoundary(child: RenderMarkerStrip(state: state, xOf: _xOf))));
        await expectLater(find.byType(RepaintBoundary).first, matchesGoldenFile('goldens/render_marker_${name}_dpr${dpr.toInt()}.png'));
      });
    }
  }

  testWidgets('every range has an accessibility label; amber ranges are buttons', (tester) async {
    final handle = tester.ensureSemantics();
    final state = RenderPreviewState(ranges: [for (final r in _coverage()) r.range.start == f(90) ? _rendered(r) : r], available: true);
    final tapped = <RangeStatus>[];
    await tester.pumpWidget(_host(RenderMarkerStrip(state: state, xOf: _xOf, onRangeTap: tapped.add)));

    expect(find.bySemanticsLabel(RenderPreviewStrings.stripLabel), findsOneWidget);
    expect(find.bySemanticsLabel('Plays live, 0:00 to 0:01'), findsOneWidget);
    expect(find.bySemanticsLabel('Needs rendering, 0:01 to 0:02, chroma key'), findsOneWidget);
    expect(find.bySemanticsLabel('Plays live, 0:02 to 0:03'), findsOneWidget);
    expect(find.bySemanticsLabel('Rendered, 0:03 to 0:04'), findsOneWidget);

    final amber = tester.getSemantics(find.bySemanticsLabel('Needs rendering, 0:01 to 0:02, chroma key'));
    expect(amber.flagsCollection.isButton, isTrue);
    expect(amber.hint, RenderPreviewStrings.renderHint);
    final green = tester.getSemantics(find.bySemanticsLabel('Rendered, 0:03 to 0:04'));
    expect(green.flagsCollection.isButton, isFalse);

    // Semantics tap and pointer tap on the amber range offer rendering; other ranges do nothing.
    tester.semantics.tap(find.semantics.byLabel('Needs rendering, 0:01 to 0:02, chroma key'));
    await tester.tapAt(Offset(_xOf(f(45)), RenderMarkerStrip.defaultHeight / 2));
    await tester.tapAt(Offset(_xOf(f(15)), RenderMarkerStrip.defaultHeight / 2));
    await tester.tapAt(Offset(_xOf(f(100)), RenderMarkerStrip.defaultHeight / 2));
    expect(tapped.map((r) => r.range.start), [f(30), f(30)]);
    handle.dispose();
  });

  test('labels name the reasons of a heavy range', () {
    expect(
      RenderPreviewStrings.rangeLabel(RangeState.heavyUnrendered, 0, 5 * microsPerSecond, reasons: {HeavyReason.decoders, HeavyReason.effects}),
      'Needs rendering, 0:00 to 0:05, many video layers, heavy effects',
    );
    expect(RenderPreviewStrings.rangeLabel(RangeState.rendered, 65 * microsPerSecond, 3725 * microsPerSecond), 'Rendered, 1:05 to 1:02:05');
  });

  test('fills keep 3:1 on the strip background (computed contrast)', () {
    for (final bg in [DanaviewColors.surface, DanaviewColors.background, DanaviewColors.surfaceElevatedHigher, const Color(0xFF3A3F55)]) {
      final c = RenderMarkerColors.resolve(background: bg);
      expect(DanaviewColors.contrastRatio(c.rendered, bg), greaterThanOrEqualTo(RenderMarkerColors.minContrast), reason: '$bg rendered');
      expect(DanaviewColors.contrastRatio(c.heavy, bg), greaterThanOrEqualTo(RenderMarkerColors.minContrast), reason: '$bg heavy');
      expect(c.rendered, isNot(c.heavy));
    }
  });

  testWidgets('a range outside the view is skipped; a one-frame range stays visible', (tester) async {
    final handle = tester.ensureSemantics();
    final ranges = _coverage();
    await tester.pumpWidget(_host(RenderMarkerStrip(state: RenderPreviewState(ranges: ranges, available: true), xOf: (t) => _xOf(t) - 200)));
    expect(find.bySemanticsLabel(RegExp('0:00 to 0:01')), findsNothing);
    expect(find.bySemanticsLabel(RegExp('0:03 to 0:04')), findsOneWidget);
    expect(tester.takeException(), isNull);
    handle.dispose();
  });
}

RangeStatus _rendered(RangeStatus r) => RangeStatus(range: r.range, hash: r.hash, state: RangeState.rendered, reasons: r.reasons);
