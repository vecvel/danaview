// OWNER: UX-16
//
// InspectorNumberRow field width (verify pass on the iPad side pane): with steppers shown the
// field used to stop at 150 px, leaving the value box ~54 px wide, so the Text panel's Duration
// read "3.( s". On wide panels the field now grows (to half the row, at most
// InspectorNumberRow.maxFieldWidth) so the whole value fits; narrow rows keep the old threshold.

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_editor/src/editor/inspector/inspector_rows.dart';
import 'package:danaview_ui_kit/danaview_ui_kit.dart';

import '../overflow/overflow_rig.dart' show loadRealFonts;
import '../support/support.dart';

Widget _row(double width, {double value = 3.0}) => Align(
      alignment: Alignment.topLeft,
      child: SizedBox(
        width: width,
        child: InspectorNumberRow(
          label: 'Duration',
          value: value,
          min: 0.04,
          max: 3600,
          step: 0.1,
          fractionDigits: 2,
          unit: 's',
          onChanged: (_) {},
        ),
      ),
    );

Future<void> _pump(WidgetTester tester, double width, {EditorSurface surface = const EditorSurface(Size(1376, 1032)), double value = 3.0}) async {
  applySurface(tester, surface);
  await tester.pumpWidget(surfaceApp(surface, ColoredBox(color: DanaviewColors.surfaceElevated, child: _row(width, value: value))));
  await tester.pump();
}

/// Width the value text needs vs the width the field gives it.
(double need, double have) _valueFit(WidgetTester tester) {
  final editable = tester.widget<EditableText>(find.byType(EditableText));
  final scaler = MediaQuery.of(tester.element(find.byType(EditableText))).textScaler;
  final painter = TextPainter(
    text: TextSpan(text: editable.controller.text, style: editable.style),
    textDirection: TextDirection.ltr,
    textScaler: scaler,
  )..layout();
  final have = tester.getSize(find.byType(EditableText)).width;
  return (painter.width, have);
}

void main() {
  setUpAll(loadRealFonts);

  group('InspectorNumberRow field width', () {
    for (final width in [347.0, 360.0, 400.0, 480.0]) {
      testWidgets('a 2-decimal value with a unit fits between the steppers at $width px', (tester) async {
        await _pump(tester, width);
        expect(find.bySemanticsLabel('Increase'), findsOneWidget);
        final (need, have) = _valueFit(tester);
        expect(have, greaterThanOrEqualTo(need), reason: 'value needs $need px, field gives $have px');
        expectNoOverflow(tester);
      });
    }

    testWidgets('the field stops at maxFieldWidth on very wide rows', (tester) async {
      await _pump(tester, 900);
      final field = find.ancestor(of: find.byType(DanaviewNumberField), matching: find.byType(SizedBox)).first;
      expect(tester.getSize(field).width, InspectorNumberRow.maxFieldWidth);
    });

    testWidgets('below 300 px the row still hides the steppers (unchanged threshold)', (tester) async {
      await _pump(tester, 299);
      expect(find.bySemanticsLabel('Increase'), findsNothing);
      await _pump(tester, 300);
      expect(find.bySemanticsLabel('Increase'), findsOneWidget);
    });

    testSurfaces('no overflow across the surface matrix', (tester, surface) async {
      final width = (surface.size.width - 32).clamp(0, 480).toDouble();
      await _pump(tester, width, surface: surface, value: 125.5);
      expectNoOverflow(tester);
    });
  });
}
