import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_ui_kit/danaview_ui_kit.dart';

import 'test_utils.dart';

const Surface _phone = Surface('phone', Size(390, 800), 1.0, TargetPlatform.iOS);

AnimatedContainer _frame(WidgetTester tester, Type owner) => tester.widget<AnimatedContainer>(
      find.descendant(of: find.byType(owner), matching: find.byType(AnimatedContainer)).first,
    );

Color _borderColor(AnimatedContainer frame) =>
    ((frame.foregroundDecoration! as BoxDecoration).border! as Border).top.color;

Color _fill(AnimatedContainer frame) => (frame.decoration! as BoxDecoration).color!;

void main() {
  testWidgets('text field keeps its hint readable and its outline soft in every state', (tester) async {
    final focus = FocusNode();
    addTearDown(focus.dispose);
    await pumpKit(tester, _phone, DanaviewTextField(focusNode: focus, hint: 'Search'));
    const hint = DanaviewColors.textMuted;

    var frame = _frame(tester, DanaviewTextField);
    expect(DanaviewColors.contrastRatio(hint, _fill(frame)), greaterThanOrEqualTo(4.5));

    focus.requestFocus();
    await tester.pumpAndSettle();
    frame = _frame(tester, DanaviewTextField);
    expect(_fill(frame), DanaviewColors.fieldActive);
    expect(DanaviewColors.contrastRatio(hint, _fill(frame)), greaterThanOrEqualTo(4.5));
    expect(_borderColor(frame).a, lessThanOrEqualTo(0.3));

    await pumpKit(tester, _phone, DanaviewTextField(focusNode: focus, hint: 'Search', errorText: 'Required'));
    await tester.pumpAndSettle();
    expect(_borderColor(_frame(tester, DanaviewTextField)).a, lessThanOrEqualTo(0.4));
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
    expect(_fill(frame), DanaviewColors.fieldActive);
    expectNoErrors(tester);
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
