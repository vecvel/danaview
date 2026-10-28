import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_ui_kit/danaview_ui_kit.dart';

import 'test_utils.dart';

const Surface _phone = Surface('phone', Size(390, 800), 1.0, TargetPlatform.iOS);

AnimatedContainer _frame(WidgetTester tester, Type owner) => tester.widget<AnimatedContainer>(
      find.descendant(of: find.byType(owner), matching: find.byType(AnimatedContainer)).first,
    );

Color _borderColor(AnimatedContainer frame) =>
    ((frame.foregroundDecoration! as ShapeDecoration).shape as OutlinedBorder).side.color;

Color _fill(AnimatedContainer frame) => (frame.decoration! as ShapeDecoration).color!;

void main() {
  testWidgets('text field keeps its hint readable and its outline soft in every state', (tester) async {
    final focus = FocusNode();
    addTearDown(focus.dispose);
    await pumpKit(tester, _phone, DanaviewTextField(focusNode: focus, hint: 'Search'));
    // §2.1: placeholders are textMuted (#8A8A8A): 4.5:1 on the resting fill, 4:1 on the focused
    // fill. Typed text is white.
    const hint = DanaviewColors.textMuted;

    var frame = _frame(tester, DanaviewTextField);
    expect(_fill(frame), DanaviewColors.surfaceElevated);
    expect(DanaviewColors.contrastRatio(hint, _fill(frame)), greaterThanOrEqualTo(4.5));

    focus.requestFocus();
    await tester.pumpAndSettle();
    frame = _frame(tester, DanaviewTextField);
    expect(_fill(frame), DanaviewColors.fieldActive);
    expect(DanaviewColors.contrastRatio(hint, _fill(frame)), greaterThanOrEqualTo(4.0));
    expect(_borderColor(frame).a, lessThanOrEqualTo(0.3));
    expect(_borderColor(frame), DanaviewColors.hairline, reason: 'focus shows as the fill, not a primary outline');

    await pumpKit(tester, _phone, DanaviewTextField(focusNode: focus, hint: 'Search', errorText: 'Required'));
    await tester.pumpAndSettle();
    expect(_borderColor(_frame(tester, DanaviewTextField)).a, lessThanOrEqualTo(0.4));
    expect(_borderColor(_frame(tester, DanaviewTextField)), DanaviewColors.hairline, reason: 'no red outline; the message says it');
    expect(tester.widget<Text>(find.text('Required')).style!.color, DanaviewColors.errorLight);
    expectNoErrors(tester);
  });

  testWidgets('open dropdown trigger uses a soft outline and a tinted fill', (tester) async {
    await pumpKit(
      tester,
      _phone,
      Center(
        child: DanaviewDropdown<int>(
          value: 1,
          options: const [DanaviewOption(value: 1, label: 'One'), DanaviewOption(value: 2, label: 'Two')],
          onChanged: (_) {},
        ),
      ),
    );
    await tester.tap(find.text('One'));
    await tester.pumpAndSettle();
    final frame = tester.widget<AnimatedContainer>(
      find.ancestor(of: find.text('One').first, matching: find.byType(AnimatedContainer)).first,
    );
    expect(_borderColor(frame).a, lessThanOrEqualTo(0.3));
    expect(_borderColor(frame), DanaviewColors.hairline, reason: 'open shows as the tinted fill, not a primary outline');
    expect(_fill(frame), DanaviewColors.fieldActive);
    expectNoErrors(tester);
  });

  testWidgets('number field keeps the hairline when focused', (tester) async {
    await pumpKit(tester, _phone, Center(child: SizedBox(width: 200, child: DanaviewNumberField(value: 1, min: 0, max: 10, onChanged: (_) {}))));
    AnimatedContainer frame() => tester.widget<AnimatedContainer>(find.descendant(
          of: find.byType(DanaviewNumberField),
          matching: find.byWidgetPredicate((w) => w is AnimatedContainer && w.constraints?.minHeight == 40),
        ));
    BorderSide border() => ((frame().foregroundDecoration! as ShapeDecoration).shape as OutlinedBorder).side;
    expect(border(), DanaviewBorders.hairline);
    await tester.tap(find.byType(EditableText));
    await tester.pumpAndSettle();
    expect(_fill(frame()), DanaviewColors.fieldActive, reason: 'the field is focused');
    expect(border(), DanaviewBorders.hairline, reason: 'focus shows as the fill, not a primary outline');
    expectNoErrors(tester);
  });

  testWidgets('the theme\'s input outlines stay the hairline when focused or in error', (tester) async {
    final theme = DanaviewTheme.darkTheme.inputDecorationTheme;
    for (final border in [theme.border, theme.enabledBorder, theme.focusedBorder, theme.errorBorder, theme.focusedErrorBorder]) {
      expect((border! as OutlineInputBorder).borderSide, DanaviewBorders.hairline);
    }
  });

  testWidgets('toast bottomOffset lifts it above a bottom control bar', (tester) async {
    late BuildContext ctx;
    await pumpKit(tester, _phone, Builder(builder: (context) {
      ctx = context;
      return const SizedBox.expand();
    }));
    DanaviewToast.show(ctx, 'Lifted', bottomOffset: 118);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    final surface = find.ancestor(of: find.text('Lifted'), matching: find.byType(DanaviewSurface));
    expect(tester.getRect(surface).bottom, moreOrLessEquals(_phone.size.height - 118, epsilon: 0.5));
    DanaviewToast.dismiss();
    await tester.pumpAndSettle();
  });
}
