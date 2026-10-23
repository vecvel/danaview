import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_ui_kit/danaview_ui_kit.dart';

/// Asserts that some leaf content ([Text], [DanaviewSurface] or [DanaviewButton]) inside the
/// first scrollable spans the full page width minus [DanaviewSpacing.pageGutter] on each side:
/// no max-width cap narrows the page (owner decision, 2026-10-23).
/// [leaves] replaces the default leaf finder (e.g. rows wrapped in [MergeSemantics]).
void expectSpansPageWidth(WidgetTester tester, {Finder? within, Finder? leaves}) {
  final width = tester.view.physicalSize.width / tester.view.devicePixelRatio;
  final gutter = DanaviewSpacing.pageGutter(width);
  final scope = within ?? find.byType(Scrollable).first;
  final candidates = leaves ??
      find.descendant(
        of: scope,
        matching: find.byWidgetPredicate((w) => w is Text || w is RichText || w is DanaviewSurface || w is DanaviewButton),
      );
  final rects = <Rect>[
    for (final e in candidates.evaluate())
      if (e.renderObject case final RenderBox box when box.hasSize && box.attached)
        box.localToGlobal(Offset.zero) & box.size,
  ];
  expect(
    rects.any((r) => (r.left - gutter).abs() < 0.5 && (r.width - (width - 2 * gutter)).abs() < 0.5),
    isTrue,
    reason: 'some content should span $width px minus a $gutter px gutter on each side; '
        'widest seen: ${rects.isEmpty ? 0 : rects.map((r) => r.width).reduce((a, b) => a > b ? a : b)}',
  );
}

/// Asserts that leaf content inside the first scrollable reaches both page gutters (for pages
/// laid out in columns, where no single leaf spans the whole width).
void expectReachesPageGutters(WidgetTester tester) {
  final width = tester.view.physicalSize.width / tester.view.devicePixelRatio;
  final gutter = DanaviewSpacing.pageGutter(width);
  final leaves = find.descendant(
    of: find.byType(Scrollable).first,
    matching: find.byWidgetPredicate((w) => w is Text || w is RichText || w is DanaviewSurface || w is DanaviewButton),
  );
  final rects = <Rect>[
    for (final e in leaves.evaluate())
      if (e.renderObject case final RenderBox box when box.hasSize && box.attached)
        box.localToGlobal(Offset.zero) & box.size,
  ];
  expect(rects.any((r) => (r.left - gutter).abs() < 0.5), isTrue, reason: 'content starts at the $gutter px gutter');
  expect(rects.any((r) => (r.right - (width - gutter)).abs() < 0.5), isTrue, reason: 'content ends at the $gutter px gutter');
}
