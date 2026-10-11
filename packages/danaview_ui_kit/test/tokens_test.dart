import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_ui_kit/src/foundation/danaview_internal.dart';
import 'package:danaview_ui_kit/danaview_ui_kit.dart';

void main() {
  test('foregroundOn picks the higher-contrast text color', () {
    expect(DanaviewColors.foregroundOn(DanaviewColors.primary), DanaviewColors.textPrimary);
    expect(DanaviewColors.foregroundOn(DanaviewColors.surfaceElevated), DanaviewColors.textPrimary);
    expect(DanaviewColors.foregroundOn(Colors.white), DanaviewColors.textOnLight);
    expect(DanaviewColors.foregroundOn(DanaviewColors.boostBand), DanaviewColors.textOnLight);
  });

  test('text tokens meet contrast targets on surfaces', () {
    for (final bg in [DanaviewColors.surface, DanaviewColors.surfaceElevated, DanaviewColors.surfaceElevatedHigher]) {
      expect(DanaviewColors.contrastRatio(DanaviewColors.textMuted, bg), greaterThanOrEqualTo(4.5));
      expect(DanaviewColors.contrastRatio(DanaviewColors.textSecondary, bg), greaterThanOrEqualTo(4.5));
    }
    expect(
      DanaviewColors.contrastRatio(DanaviewColors.primaryLight, Color.alphaBlend(DanaviewColors.primaryTonal, DanaviewColors.surface)),
      greaterThanOrEqualTo(4.5),
    );
    expect(DanaviewColors.contrastRatio(Colors.white, Colors.black), closeTo(21, 0.01));
  });

  test('every foreground/background pair the components draw meets its contrast target', () {
    double ratio(Color fg, Color bg) => DanaviewColors.contrastRatio(fg, bg);
    const destructiveFill = Color(0x29EF4444);

    // Filled, text-bearing controls: primary button, selected chip and segment, secondary button.
    expect(ratio(DanaviewColors.foregroundOn(DanaviewColors.primary), DanaviewColors.primary), greaterThanOrEqualTo(4.5));
    expect(
      ratio(DanaviewColors.foregroundOn(DanaviewColors.surfaceElevatedHigher), DanaviewColors.surfaceElevatedHigher),
      greaterThanOrEqualTo(4.5),
    );
    for (final page in [DanaviewColors.background, DanaviewColors.surface, DanaviewColors.surfaceElevated]) {
      expect(ratio(DanaviewColors.primaryLight, Color.alphaBlend(DanaviewColors.primaryTonal, page)), greaterThanOrEqualTo(4.5));
      expect(ratio(DanaviewColors.errorLight, Color.alphaBlend(destructiveFill, page)), greaterThanOrEqualTo(4.5));
      expect(ratio(DanaviewColors.textPrimary, Color.alphaBlend(DanaviewColors.primarySoft, page)), greaterThanOrEqualTo(4.5));
      expect(ratio(DanaviewColors.errorLight, page), greaterThanOrEqualTo(4.5));
      expect(ratio(DanaviewColors.textSecondary, page), greaterThanOrEqualTo(4.5));
    }
    // Text fields and dropdown triggers, resting and focused/open.
    for (final fill in [DanaviewColors.surfaceElevatedHigher, DanaviewColors.fieldActive]) {
      for (final fg in [DanaviewColors.textPrimary, DanaviewColors.textSecondary, DanaviewColors.textMuted]) {
        expect(ratio(fg, fill), greaterThanOrEqualTo(4.5), reason: '$fg on $fill');
      }
      expect(ratio(DanaviewColors.primaryLight, fill), greaterThanOrEqualTo(3));
    }
  });

  test('focus outlines stay soft', () {
    expect(DanaviewBorders.focus.color.a, lessThanOrEqualTo(0.3));
    expect(DanaviewBorders.focus.width, lessThanOrEqualTo(1));
  });

  test('shadows stay soft and borders stay hairline', () {
    for (final shadow in [...DanaviewShadows.subtle, ...DanaviewShadows.soft]) {
      expect(shadow.blurRadius, greaterThanOrEqualTo(16));
      expect(shadow.spreadRadius, lessThanOrEqualTo(0));
      expect(shadow.color.a, lessThanOrEqualTo(0.35));
    }
    expect(DanaviewColors.border.a, lessThanOrEqualTo(0.12));
    expect(DanaviewColors.borderBright.a, lessThanOrEqualTo(0.12));
    expect(DanaviewBorders.width, inInclusiveRange(0.5, 1.0));
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

  test('hover, focus and press tints keep labels on filled controls at 4.5:1', () {
    const states = [
      DanaviewPressState(pressed: false, hovered: true, focused: false, enabled: true),
      DanaviewPressState(pressed: false, hovered: false, focused: true, enabled: true),
      DanaviewPressState(pressed: true, hovered: false, focused: false, enabled: true),
    ];
    for (final fill in [DanaviewColors.primary, DanaviewColors.surfaceElevatedHigher, DanaviewColors.fieldActive]) {
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
