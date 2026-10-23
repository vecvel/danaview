import 'package:danaview_ui_kit/danaview_ui_kit.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'test_utils.dart';

void main() {
  test('controlHeight is the fields\' minimum and the tap target', () {
    expect(DanaviewSpacing.controlHeight, 44);
    expect(DanaviewSpacing.controlHeight, DanaviewSpacing.minTapTarget);
  });

  for (final surface in const [
    Surface('touch 1.0x', Size(800, 500), 1.0, TargetPlatform.android),
    Surface('desktop 1.0x', Size(1200, 800), 1.0, TargetPlatform.macOS),
  ]) {
    testWidgets('field + field button + dropdown + icon button line up ($surface)', (tester) async {
      await pumpKit(
        tester,
        surface,
        Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              const Expanded(key: ValueKey('text'), child: DanaviewTextField(hint: 'Name')),
              const SizedBox(width: DanaviewSpacing.md),
              Expanded(key: const ValueKey('search'), child: DanaviewSearchField(onChanged: (_) {})),
              const SizedBox(width: DanaviewSpacing.md),
              DanaviewButton.primary(
                key: const ValueKey('button'),
                label: 'Import',
                size: DanaviewButtonSize.field,
                onPressed: () {},
              ),
              const SizedBox(width: DanaviewSpacing.md),
              DanaviewDropdown<int>(
                key: const ValueKey('dropdown'),
                value: 0,
                field: true,
                options: const [DanaviewOption(value: 0, label: 'A')],
                onChanged: (_) {},
              ),
              const SizedBox(width: DanaviewSpacing.md),
              DanaviewIconButton(
                key: const ValueKey('icon'),
                icon: Icons.add_rounded,
                size: DanaviewSpacing.controlHeight,
                variant: DanaviewIconButtonVariant.filled,
                onPressed: () {},
              ),
            ],
          ),
        ),
      );
      final keys = ['text', 'search', 'button', 'dropdown', 'icon'];
      expectEqualRowHeights(tester, [for (final k in keys) find.byKey(ValueKey(k))], height: DanaviewSpacing.controlHeight);

      BoxDecoration deco(String k) => controlFrameWidget(tester, find.byKey(ValueKey(k))).decoration! as BoxDecoration;
      for (final k in ['search', 'button', 'dropdown']) {
        expect(deco(k).borderRadius, deco('text').borderRadius, reason: '$k radius');
      }
      expect(deco('text').borderRadius, DanaviewRadius.mdAll);
      expect(deco('icon').shape, BoxShape.circle);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('the existing sm, md and lg button sizes are unchanged', (tester) async {
    await pumpKit(
      tester,
      surfaces[2],
      Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final s in DanaviewButtonSize.values)
            DanaviewButton(key: ValueKey(s), label: s.name, size: s, onPressed: () {}),
        ],
      ),
    );
    double h(DanaviewButtonSize s) => tester.getRect(find.descendant(
          of: find.byKey(ValueKey(s)),
          matching: find.byWidgetPredicate((w) => w is AnimatedContainer && w.decoration != null),
        )).height;
    expect(h(DanaviewButtonSize.sm), 32);
    expect(h(DanaviewButtonSize.md), 40);
    expect(h(DanaviewButtonSize.lg), 48);
    expect(h(DanaviewButtonSize.field), DanaviewSpacing.controlHeight);
  });
}
