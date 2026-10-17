// OWNER: FIX-A11Y
//
// FIX-KIT-1 (QA-08): DanaviewSegmentedControl segments are full-height tap targets (44 px on
// touch) and read their label once, while the control looks the same (3 px inset indicator).

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_ui_kit/danaview_ui_kit.dart';

import 'test_utils.dart';

void main() {
  for (final surface in surfaces) {
    testWidgets('segments fill the control height and read their label once [$surface]', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpKit(
        tester,
        surface,
        Center(
          child: SizedBox(
            // Wide enough for segments (not the chip fallback) at text scale 1.35.
            width: 270,
            child: DanaviewSegmentedControl<int>(
              value: 0,
              onChanged: (_) {},
              options: const [
                DanaviewOption(value: 0, label: 'Fixed'),
                DanaviewOption(value: 1, label: 'Curve'),
              ],
            ),
          ),
        ),
      );
      expect(find.byType(DanaviewChoiceChip), findsNothing, reason: 'a segmented control, not chips');
      final control = tester.getRect(find.byType(DanaviewSegmentedControl<int>));
      final touch = surface.platform == TargetPlatform.android || surface.platform == TargetPlatform.iOS;
      expect(control.height, touch ? DanaviewSpacing.minTapTarget : 36.0);
      for (final label in ['Fixed', 'Curve']) {
        final node = find.semantics.byLabel(label).evaluate().single;
        final data = node.getSemanticsData();
        expect(data.label, label, reason: 'read once');
        expect(data.hasAction(SemanticsAction.tap), isTrue);
        final rect = node.rect;
        expect(rect.height, control.height, reason: '$label spans the control height');
      }
      // The selected indicator keeps its 3 px inset.
      final indicator = tester.getRect(find.descendant(of: find.byType(DanaviewSegmentedControl<int>), matching: find.byType(AnimatedPositioned)));
      expect(indicator.top - control.top, 3);
      expect(control.bottom - indicator.bottom, 3);
      expectNoErrors(tester);
      handle.dispose();
    });
  }

  testWidgets('a tap on the inset edge of a segment selects it', (tester) async {
    var value = 0;
    await pumpKit(
      tester,
      surfaces.first,
      Center(
        child: SizedBox(
          width: 260,
          child: StatefulBuilder(
            builder: (context, setState) => DanaviewSegmentedControl<int>(
              value: value,
              onChanged: (v) => setState(() => value = v),
              options: const [
                DanaviewOption(value: 0, label: 'Constant'),
                DanaviewOption(value: 1, label: 'Curve'),
              ],
            ),
          ),
        ),
      ),
    );
    final control = tester.getRect(find.byType(DanaviewSegmentedControl<int>));
    await tester.tapAt(Offset(control.right - 40, control.top + 1));
    await tester.pumpAndSettle();
    expect(value, 1);
  });
}
