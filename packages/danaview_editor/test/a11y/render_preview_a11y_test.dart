// OWNER: QA-08
//
// Accessibility of the render-preview UI (UX-44; ARCH D-45(A), §17.4, §17.5, §17.9) in the real
// editor: the render marker strip under the timeline ruler is a painted element, so it must carry
// semantics. The strip has a name. Every visible range is a node whose label names its state and
// time span, so state is never told by colour alone. Only the heavy, unrendered ("Needs rendering")
// ranges are buttons, with a tap action and a hint, and activating one through semantics opens the
// "Render preview" range sheet, which itself meets the guidelines. The painted strip also tells the
// states apart without colour: a heavy range is hatched (its luminance alternates along the bar)
// and a rendered range is a solid fill.
//
// The flows suite (flows_a11y_test.dart) also checks the range sheet on its own, and
// projects_settings_a11y_test.dart checks the Render preview settings section.

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_editor/src/app/strings/render_preview_strings.dart';
import 'package:danaview_editor/src/editor/state/render_preview_controller.dart';
import 'package:danaview_editor/src/editor/timeline/render_marker_strip.dart';
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_editor_core/render_cache.dart';
import 'package:danaview_ui_kit/danaview_ui_kit.dart';

import '../render_preview/support.dart' show basePlan;
import '../support/support.dart';
import 'a11y_support.dart';

const List<EditorSurface> _surfaces = [
  EditorSurface(Size(280, 500), textScale: 1.35),
  EditorSurface(Size(390, 844), platform: TargetPlatform.iOS),
  EditorSurface(Size(1194, 834), textScale: 1.35, platform: TargetPlatform.iOS),
];

String _labelOf(RangeStatus r) => RenderPreviewStrings.rangeLabel(r.state, r.range.start, r.range.end, reasons: r.reasons);

final class _Lookup implements RenderCacheLookup {
  const _Lookup(this.hashes);
  final Set<String> hashes;
  @override
  bool contains(String hash) => hashes.contains(hash);
}

/// Relative luminance of the pixel at ([x], [y]) in RGBA bytes of an image [width] wide.
double _luminance(ByteData bytes, int width, int x, int y) {
  final i = (y * width + x) * 4;
  double lin(int c) {
    final v = c / 255;
    return v <= 0.03928 ? v / 12.92 : ((v + 0.055) / 1.055) * ((v + 0.055) / 1.055);
  }

  return 0.2126 * lin(bytes.getUint8(i)) + 0.7152 * lin(bytes.getUint8(i + 1)) + 0.0722 * lin(bytes.getUint8(i + 2));
}

void main() {
  for (final surface in _surfaces) {
    group('[$surface]', () {
      testWidgets('render marker strip: named, every range labelled by state, amber ranges are buttons', (tester) async {
        final semantics = tester.ensureSemantics();
        final rig = await A11yEditorRig.pump(tester, surface: surface, renderPreview: true);
        final controller = await rig.showHeavyRanges();
        expect(find.byType(RenderMarkerStrip), findsOneWidget, reason: 'the strip is mounted under the ruler');
        expect(find.bySemanticsLabel(RenderPreviewStrings.stripLabel), findsOneWidget, reason: 'the strip has a name');

        final shown = <RangeStatus>[
          for (final r in controller.value.ranges)
            if (find.bySemanticsLabel(_labelOf(r)).evaluate().isNotEmpty) r,
        ];
        expect(shown.where((r) => r.state == RangeState.heavyUnrendered), isNotEmpty, reason: 'an amber range is on screen');
        expect(shown.where((r) => r.state != RangeState.heavyUnrendered), isNotEmpty, reason: 'a live range is on screen');
        for (final r in shown) {
          final node = tester.getSemantics(find.bySemanticsLabel(_labelOf(r)));
          final data = node.getSemanticsData();
          // The state is spoken, not only painted.
          expect(data.label, startsWith(RenderPreviewStrings.stateName(r.state)));
          final amber = r.state == RangeState.heavyUnrendered;
          expect(data.flagsCollection.isButton, amber, reason: '${data.label}: only amber ranges are buttons');
          expect(data.hasAction(SemanticsAction.tap), amber, reason: '${data.label}: tap action');
          expect(data.hint, amber ? RenderPreviewStrings.renderHint : isEmpty, reason: '${data.label}: hint');
        }
        expect(takeKnownException(tester, where: 'render marker strip'), isNull);
        expectNoOverflow(tester);
        await expectA11yGuidelines(tester, where: 'editor with the render marker strip on $surface');

        // Activating an amber range through semantics offers "Render preview".
        final amber = shown.firstWhere((r) => r.state == RangeState.heavyUnrendered);
        tester.semantics.tap(find.semantics.byLabel(_labelOf(amber)));
        await rig.settle();
        expect(find.byKey(const ValueKey('render-range-this')), findsOneWidget, reason: 'the range sheet opened');
        expect(find.text(RenderPreviewStrings.rangeTitle(amber.range.start, amber.range.end)), findsOneWidget);
        expectNoOverflow(tester);
        await expectA11yGuidelines(tester, where: 'render preview range sheet on $surface');
        semantics.dispose();
      });
    });
  }

  testWidgets('render marker strip: states differ by pattern, not only colour', (tester) async {
    const width = 320.0;
    const height = RenderMarkerStrip.defaultHeight;
    final plan = basePlan();
    final budget = RenderBudget.forTier(RenderTier.mid);
    final heavy = coverage(plan, const _Lookup({}), budget).where((r) => r.isHeavy).toList();
    expect(heavy, hasLength(2));
    // [1, 2) s stays heavy and unrendered; [3, 4) s is rendered.
    final ranges = coverage(plan, _Lookup({heavy.last.hash}), budget);
    double xOf(TimeUs t) => t / microsPerSecond * 80; // 4 s over 320 px
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(width, height);
    addTearDown(tester.view.reset);
    final key = GlobalKey();
    await tester.pumpWidget(Directionality(
      textDirection: TextDirection.ltr,
      child: Align(
        alignment: Alignment.topLeft,
        child: RepaintBoundary(
          key: key,
          child: ColoredBox(
            color: DanaviewColors.surface,
            child: SizedBox(
              width: width,
              height: height,
              child: RenderMarkerStrip(state: RenderPreviewState(ranges: ranges, available: true), xOf: xOf),
            ),
          ),
        ),
      ),
    ));
    final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final bytes = (await tester.runAsync(() async {
      final image = await boundary.toImage();
      final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      image.dispose();
      return data;
    }))!;
    const y = height ~/ 2;
    List<double> row(TimeUs from, TimeUs to) => [
          // Inset by the bar's rounded ends.
          for (var x = xOf(from).ceil() + 4; x < xOf(to).floor() - 4; x++) _luminance(bytes, width.toInt(), x, y),
        ];
    final hatched = row(heavy.first.range.start, heavy.first.range.end);
    final solid = row(heavy.last.range.start, heavy.last.range.end);
    double spread(List<double> v) => v.reduce((a, b) => a > b ? a : b) - v.reduce((a, b) => a < b ? a : b);
    expect(spread(hatched), greaterThan(0.05), reason: 'a heavy range is hatched: its luminance alternates (visible without colour)');
    expect(spread(solid), lessThan(0.01), reason: 'a rendered range is a solid fill');
  });
}
