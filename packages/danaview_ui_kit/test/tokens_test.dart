import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_ui_kit/src/foundation/danaview_internal.dart';
import 'package:danaview_ui_kit/danaview_ui_kit.dart';

void main() {
  test('pageGutter is 16 below 600, 24 below 1024, 32 from 1024; pageInsets is symmetric', () {
    expect(DanaviewSpacing.pageGutter(280), 16);
    expect(DanaviewSpacing.pageGutter(599.9), 16);
    expect(DanaviewSpacing.pageGutter(600), 24);
    expect(DanaviewSpacing.pageGutter(1023.9), 24);
    expect(DanaviewSpacing.pageGutter(1024), 32);
    expect(DanaviewSpacing.pageGutter(2560), 32);
    expect(DanaviewSpacing.pageInsets(1280), const EdgeInsets.symmetric(horizontal: 32));
  });

  test('foregroundOn picks the higher-contrast text color', () {
    expect(DanaviewColors.foregroundOn(DanaviewColors.primary), DanaviewColors.textPrimary);
    expect(DanaviewColors.foregroundOn(DanaviewColors.surfaceElevated), DanaviewColors.textPrimary);
    expect(DanaviewColors.foregroundOn(Colors.white), DanaviewColors.textOnLight);
    expect(DanaviewColors.foregroundOn(DanaviewColors.boostBand), DanaviewColors.textOnLight);
  });

  test('Cinema B values match DESIGN_SYSTEM.md §2 and §13', () {
    expect(DanaviewColors.background, const Color(0xFF000000));
    expect(DanaviewColors.surface, const Color(0xFF141414));
    expect(DanaviewColors.surfaceElevated, const Color(0xFF222222));
    expect(DanaviewColors.surfaceElevatedHigher, const Color(0xFF2A2A2C));
    expect(DanaviewColors.primary, const Color(0xFFB20710));
    expect(DanaviewColors.primaryLight, const Color(0xFFFF5A62));
    expect(DanaviewColors.success, const Color(0xFF30D158));
    expect(DanaviewColors.warning, const Color(0xFFFFD60A));
    expect(DanaviewColors.error, const Color(0xFFFF9F0A), reason: 'errors are orange: red is the accent');
    expect(DanaviewColors.destructive, const Color(0xFFF2444D));
    expect(DanaviewColors.textSecondary, const Color(0xFF9A9A9A));
    expect(DanaviewColors.textMuted, const Color(0xFF8A8A8A));
    expect(DanaviewColors.focusRing.withValues(alpha: 1), const Color(0xFFFF5A62));
    expect(DanaviewColors.focusRing.a, closeTo(0.55, 0.01));
    expect(
      [DanaviewRadius.xs, DanaviewRadius.tile, DanaviewRadius.thumb, DanaviewRadius.control, DanaviewRadius.media,
        DanaviewRadius.card, DanaviewRadius.toast, DanaviewRadius.sheet],
      [6, 8, 10, 12, 14, 16, 20, 24],
    );
    expect(DanaviewRadius.sheetTop, const BorderRadius.vertical(top: Radius.circular(24)));
  });

  test('text tokens meet contrast targets on surfaces', () {
    for (final bg in [DanaviewColors.background, DanaviewColors.surface, DanaviewColors.surfaceElevated, DanaviewColors.surfaceElevatedHigher]) {
      expect(DanaviewColors.contrastRatio(DanaviewColors.textSecondary, bg), greaterThanOrEqualTo(4.5));
      expect(DanaviewColors.contrastRatio(DanaviewColors.textPrimary, bg), greaterThanOrEqualTo(4.5));
      // Placeholders and disabled labels (#8A8A8A): 4.5:1 up to the field fill, 4:1 on icon tiles.
      expect(DanaviewColors.contrastRatio(DanaviewColors.textMuted, bg),
          greaterThanOrEqualTo(bg == DanaviewColors.surfaceElevatedHigher ? 4.0 : 4.5));
    }
    expect(DanaviewColors.contrastRatio(Colors.white, Colors.black), closeTo(21, 0.01));
  });

  test('every foreground/background pair the components draw meets its contrast target', () {
    double ratio(Color fg, Color bg) => DanaviewColors.contrastRatio(fg, bg);

    // Filled, text-bearing controls: primary button, selected chip and segment, secondary button.
    expect(ratio(DanaviewColors.foregroundOn(DanaviewColors.primary), DanaviewColors.primary), greaterThanOrEqualTo(7));
    for (final fill in [DanaviewColors.surfaceElevated, DanaviewColors.surfaceElevatedHigher]) {
      expect(ratio(DanaviewColors.foregroundOn(fill), fill), greaterThanOrEqualTo(4.5));
    }
    // Red text on dark is primaryLight: 4.5:1 on the background, cards and raised items.
    for (final page in [DanaviewColors.background, DanaviewColors.surface, DanaviewColors.surfaceElevated]) {
      expect(ratio(DanaviewColors.primaryLight, page), greaterThanOrEqualTo(4.5));
    }
    for (final page in [DanaviewColors.background, DanaviewColors.surface]) {
      expect(ratio(DanaviewColors.destructive, Color.alphaBlend(DanaviewColors.destructiveSoft, page)), greaterThanOrEqualTo(4.5));
    }
    for (final page in [DanaviewColors.background, DanaviewColors.surface, DanaviewColors.surfaceElevated]) {
      expect(ratio(DanaviewColors.primaryLight, page), greaterThanOrEqualTo(3));
      expect(ratio(DanaviewColors.primaryLight, Color.alphaBlend(DanaviewColors.primaryTonal, page)), greaterThanOrEqualTo(3));
      expect(ratio(DanaviewColors.textPrimary, Color.alphaBlend(DanaviewColors.primarySoft, page)), greaterThanOrEqualTo(4.5));
      expect(ratio(DanaviewColors.errorLight, page), greaterThanOrEqualTo(4.5));
      expect(ratio(DanaviewColors.error, page), greaterThanOrEqualTo(4.5));
      expect(ratio(DanaviewColors.textSecondary, page), greaterThanOrEqualTo(4.5));
    }
    // Text fields and dropdown triggers, resting and focused/open.
    for (final fill in [DanaviewColors.surfaceElevated, DanaviewColors.fieldActive]) {
      for (final fg in [DanaviewColors.textPrimary, DanaviewColors.textSecondary]) {
        expect(ratio(fg, fill), greaterThanOrEqualTo(4.5), reason: '$fg on $fill');
      }
      // Placeholders: 4.5:1 on the resting fill, 4:1 on the focused fill.
      expect(ratio(DanaviewColors.textMuted, fill),
          greaterThanOrEqualTo(fill == DanaviewColors.surfaceElevated ? 4.5 : 4.0));
    }
  });

  test('the focus ring is the one coloured edge: primaryLight at 55 %, 2 pt', () {
    expect(DanaviewBorders.focus.color, DanaviewColors.focusRing);
    expect(DanaviewBorders.focus.color.a, closeTo(0.55, 0.01));
    expect(DanaviewBorders.focus.width, 2);
  });

  test('shadows stay soft and borders stay hairline', () {
    for (final shadow in [...DanaviewShadows.subtle, ...DanaviewShadows.soft]) {
      expect(shadow.blurRadius, greaterThanOrEqualTo(16));
      expect(shadow.spreadRadius, lessThanOrEqualTo(0));
      expect(shadow.color.a, lessThanOrEqualTo(0.35));
    }
    expect(DanaviewShadows.card, hasLength(2));
    expect(DanaviewShadows.raised, hasLength(1));
    // No bright outlines (owner rule): every hairline is white at 12 % or less.
    for (final c in [
      DanaviewColors.hairline,
      DanaviewColors.hairlineSubtle,
      DanaviewColors.divider,
      DanaviewColors.border,
      DanaviewColors.borderBright,
    ]) {
      expect(c.a, lessThanOrEqualTo(0.125));
    }
    expect(DanaviewColors.hairline.a, closeTo(0.07, 0.005));
    expect(DanaviewBorders.width, 0.5);
  });

  test('DanaviewDepth recipes carry the hairline, top highlight and shadows of §3', () {
    final card = DanaviewDepth.card();
    expect(card.color, DanaviewColors.surface);
    expect(card.shadows, DanaviewShadows.card);
    final border = card.shape as DanaviewDepthBorder;
    expect(border.side, DanaviewBorders.hairline);
    expect(border.highlight, DanaviewColors.highlight);
    expect(border.borderRadius, DanaviewRadius.cardAll);
    expect(border, isA<RoundedSuperellipseBorder>(), reason: 'continuous corners');

    final primary = DanaviewDepth.primary();
    expect(primary.color, DanaviewColors.primary);
    expect((primary.shape as DanaviewDepthBorder).highlight.a, closeTo(0.18, 0.01));
    expect(primary.shadows, DanaviewShadows.raised);

    final tile = DanaviewDepth.iconTile();
    expect(tile.color, DanaviewColors.surfaceElevatedHigher);
    expect((tile.shape as DanaviewDepthBorder).side.color.a, closeTo(0.10, 0.01));
    expect((tile.shape as DanaviewDepthBorder).highlight.a, closeTo(0.12, 0.01));
    expect((tile.shape as DanaviewDepthBorder).borderRadius, DanaviewRadius.tileAll);
  });

  testWidgets('DanaviewDepthBorder paints its top highlight inside the shape', (tester) async {
    final key = GlobalKey();
    await tester.pumpWidget(Center(
      child: RepaintBoundary(
        key: key,
        child: Container(
          width: 80,
          height: 40,
          color: Colors.black,
          child: const DecoratedBox(
            decoration: ShapeDecoration(
              color: Colors.black,
              shape: DanaviewDepthBorder(borderRadius: DanaviewRadius.controlAll, highlight: Colors.white),
            ),
          ),
        ),
      ),
    ));
    final ro = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final bytes = (await tester.runAsync(() async {
      final image = await ro.toImage();
      final data = await image.toByteData();
      image.dispose();
      return data!;
    }))!;
    int red(int x, int y) => bytes.getUint8((y * 80 + x) * 4);
    expect(red(40, 0), greaterThan(200), reason: 'top edge highlighted');
    expect(red(40, 20), 0, reason: 'interior untouched');
    expect(red(40, 39), 0, reason: 'no highlight at the bottom');
  });

  testWidgets('breakpoint extension follows window width', (tester) async {
    tester.view.physicalSize = const Size(500, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    late BuildContext ctx;
    await tester.pumpWidget(MaterialApp(home: Builder(builder: (context) {
      ctx = context;
      return const SizedBox();
    })));
    expect(ctx.isCompact, isTrue);
    expect(ctx.isMedium, isFalse);

    tester.view.physicalSize = const Size(700, 800);
    await tester.pump();
    expect(ctx.isMedium, isTrue);

    tester.view.physicalSize = const Size(1000, 800);
    await tester.pump();
    expect(ctx.isExpanded, isTrue);
  });

  test('hover and press leave a fill untouched (owner rule); only keyboard focus tints it', () {
    const hover = DanaviewPressState(pressed: false, hovered: true, focused: false, enabled: true);
    const press = DanaviewPressState(pressed: true, hovered: true, focused: false, enabled: true);
    const focus = DanaviewPressState(pressed: false, hovered: false, focused: true, enabled: true);
    for (final fill in [DanaviewColors.primary, DanaviewColors.surfaceElevated, DanaviewColors.fieldActive]) {
      expect(danaviewInteractiveFill(fill, hover), fill);
      expect(danaviewInteractiveFill(fill, press), fill);
      expect(danaviewInteractiveFill(fill, focus), isNot(fill));
    }
  });

  test('hover, focus and press fills keep labels on filled controls at 4.5:1', () {
    const states = [
      DanaviewPressState(pressed: false, hovered: true, focused: false, enabled: true),
      DanaviewPressState(pressed: false, hovered: false, focused: true, enabled: true),
      DanaviewPressState(pressed: true, hovered: false, focused: false, enabled: true),
    ];
    for (final fill in [DanaviewColors.primary, DanaviewColors.surfaceElevated, DanaviewColors.fieldActive]) {
      final label = DanaviewColors.foregroundOn(fill);
      for (final state in states) {
        final tinted = danaviewInteractiveFill(fill, state);
        expect(DanaviewColors.contrastRatio(label, tinted), greaterThanOrEqualTo(4.5), reason: '$fill $state');
      }
    }
    for (final state in states) {
      final trigger = danaviewInteractiveFill(DanaviewColors.fieldActive, state);
      expect(DanaviewColors.contrastRatio(DanaviewColors.textSecondary, trigger), greaterThanOrEqualTo(4.5));
    }
  });

  test('Figtree is the one typeface, applied to every text style through the theme', () {
    final theme = DanaviewTheme.darkTheme;
    for (final style in [
      theme.textTheme.bodyLarge,
      theme.textTheme.bodyMedium,
      theme.textTheme.bodySmall,
      theme.textTheme.titleLarge,
      theme.textTheme.titleMedium,
      theme.textTheme.labelLarge,
      theme.textTheme.headlineMedium,
      theme.primaryTextTheme.bodyMedium,
    ]) {
      expect(style?.fontFamily, DanaviewFonts.family);
    }
    expect(DanaviewFonts.files, everyElement(startsWith('packages/danaview_ui_kit/fonts/Figtree-')));
  });
}
