// DanaviewNumberField unit layout (verify pass on the iPad): the unit sat in an equal-flex
// Flexible next to the Expanded value, so the unit took half the box and the value was clipped
// ("3.( s"). The unit now takes its own width (at most a third of the box) and the value gets
// the rest.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_ui_kit/danaview_ui_kit.dart';

import 'test_utils.dart';

Widget _field(double width, String unit) => Align(
      alignment: Alignment.topLeft,
      child: SizedBox(
        width: width,
        child: DanaviewNumberField(value: 3, fractionDigits: 2, unit: unit, showSteppers: false, onChanged: (_) {}),
      ),
    );

double _w(WidgetTester tester, Finder f) => tester.getSize(f).width;

void main() {
  for (final surface in surfaces) {
    group('$surface', () {
      testWidgets('a short unit takes only its own width; the value gets the rest', (tester) async {
        await pumpKit(tester, surface, _field(120, 's'));
        final value = _w(tester, find.byType(EditableText));
        final unit = _w(tester, find.text('s'));
        // 120 - 2 x 10 padding - 4 gap.
        expect(value + unit, moreOrLessEquals(96, epsilon: 0.5));
        expect(value, greaterThan(unit * 2), reason: 'value $value px vs unit $unit px');
        expectNoErrors(tester);
      });

      testWidgets('a long unit is capped at a third of the box and does not overflow', (tester) async {
        await pumpKit(tester, surface, _field(120, 'characters per second'));
        final unit = _w(tester, find.text('characters per second'));
        expect(unit, lessThanOrEqualTo(100 / 3 + 0.5));
        expect(_w(tester, find.byType(EditableText)), greaterThanOrEqualTo(96 - 100 / 3 - 0.5));
        expectNoErrors(tester);
      });
    });
  }
}
