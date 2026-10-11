import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_ui_kit/danaview_ui_kit.dart';

import 'test_utils.dart';

/// Opens the picker from a button and records what it resolves to.
class _Harness {
  DateTime? result;
  bool resolved = false;

  Widget button({
    required DateTime initialDate,
    DateTime? firstDate,
    DateTime? lastDate,
    String? title,
  }) {
    return Builder(
      builder: (context) => Center(
        child: DanaviewButton(
          label: 'Open picker',
          onPressed: () async {
            resolved = false;
            result = await showDanaviewDatePicker(
              context,
              initialDate: initialDate,
              firstDate: firstDate,
              lastDate: lastDate,
              title: title,
            );
            resolved = true;
          },
        ),
      ),
    );
  }
}

Future<void> _open(WidgetTester tester) async {
  await tester.tap(find.text('Open picker'));
  await tester.pumpAndSettle();
}

Finder _wheel(String name) => find.byKey(ValueKey('danaview-date-wheel-$name'));

/// Taps a visible item of one wheel and lets the wheels settle.
Future<void> _pick(WidgetTester tester, String wheel, String label) async {
  await tester.tap(find.descendant(of: _wheel(wheel), matching: find.text(label)));
  await tester.pumpAndSettle();
}

const List<Surface> _extraSurfaces = [
  Surface('phone 320x568 1.35x', Size(320, 568), 1.35, TargetPlatform.iOS),
  Surface('phone 375x667 1.0x', Size(375, 667), 1.0, TargetPlatform.iOS),
  Surface('phone 402x874 1.35x', Size(402, 874), 1.35, TargetPlatform.iOS),
  Surface('landscape 874x402 1.0x', Size(874, 402), 1.0, TargetPlatform.android),
  Surface('landscape 874x402 1.35x', Size(874, 402), 1.35, TargetPlatform.iOS),
];

void main() {
  final desktop = surfaces[2];

  test('danaviewFormatDate', () {
    expect(danaviewFormatDate(DateTime(2024, 2, 29)), '29 February 2024');
    expect(danaviewFormatDate(DateTime(2026, 10, 3), weekday: true), 'Saturday, 3 October 2026');
  });

  testWidgets('a leap day clamps to Feb 28 when the year changes', (tester) async {
    final harness = _Harness();
    await pumpKit(
      tester,
      desktop,
      harness.button(initialDate: DateTime(2024, 2, 29), firstDate: DateTime(2000), lastDate: DateTime(2030, 12, 31)),
    );
    await _open(tester);
    expect(find.text('Choose a date'), findsOneWidget);
    expect(find.text('Thursday, 29 February 2024'), findsOneWidget);

    await _pick(tester, 'year', '2023');
    expect(find.text('Tuesday, 28 February 2023'), findsOneWidget);
    expect(find.descendant(of: _wheel('day'), matching: find.text('29')), findsNothing, reason: 'Feb 2023 has 28 days');

    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    expect(harness.resolved, isTrue);
    expect(harness.result, DateTime(2023, 2, 28));
    expectNoErrors(tester);
  });

  testWidgets('the day follows the month length', (tester) async {
    final harness = _Harness();
    await pumpKit(
      tester,
      desktop,
      harness.button(initialDate: DateTime(2024, 3, 31), firstDate: DateTime(2000), lastDate: DateTime(2030, 12, 31)),
    );
    await _open(tester);

    await _pick(tester, 'month', 'February');
    expect(find.text('Thursday, 29 February 2024'), findsOneWidget);
    await _pick(tester, 'year', '2025');
    expect(find.text('Friday, 28 February 2025'), findsOneWidget);
    await _pick(tester, 'month', 'March');
    expect(find.text('Friday, 28 March 2025'), findsOneWidget, reason: 'the clamped day stays put');

    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    expect(harness.result, DateTime(2025, 3, 28));
    expectNoErrors(tester);
  });

  testWidgets('dates after lastDate settle back into range', (tester) async {
    final harness = _Harness();
    await pumpKit(
      tester,
      desktop,
      harness.button(
        initialDate: DateTime(2026, 9, 15),
        firstDate: DateTime(1906),
        lastDate: DateTime(2026, 10, 3, 18, 30),
        title: 'Date of birth',
      ),
    );
    await _open(tester);
    expect(find.text('Date of birth'), findsOneWidget);

    await _pick(tester, 'month', 'November');
    expect(find.text('Saturday, 3 October 2026'), findsOneWidget);

    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    expect(harness.result, DateTime(2026, 10, 3), reason: 'the time of day is dropped');
    expectNoErrors(tester);
  });

  testWidgets('initial dates outside the range start at the nearest end', (tester) async {
    final harness = _Harness();
    await pumpKit(
      tester,
      desktop,
      harness.button(initialDate: DateTime(1990, 6, 1), firstDate: DateTime(2000, 1, 15), lastDate: DateTime(2001)),
    );
    await _open(tester);
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    expect(harness.result, DateTime(2000, 1, 15));
  });

  testWidgets('Cancel and Close resolve to null', (tester) async {
    final harness = _Harness();
    await pumpKit(tester, desktop, harness.button(initialDate: DateTime(2024, 5, 5)));

    await _open(tester);
    await _pick(tester, 'day', '6');
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(harness.resolved, isTrue);
    expect(harness.result, isNull);
    expect(find.text('Choose a date'), findsNothing);

    await _open(tester);
    await tester.tap(find.byTooltip('Close'));
    await tester.pumpAndSettle();
    expect(harness.resolved, isTrue);
    expect(harness.result, isNull);
    expectNoErrors(tester);
  });

  testWidgets('arrow keys turn the focused wheel', (tester) async {
    final harness = _Harness();
    await pumpKit(tester, desktop, harness.button(initialDate: DateTime(2024, 5, 5)));
    await _open(tester);

    Focus.of(tester.element(_wheel('day'))).requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(find.text('Tuesday, 7 May 2024'), findsOneWidget);

    Focus.of(tester.element(_wheel('month'))).requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pumpAndSettle();
    expect(find.text('Sunday, 7 April 2024'), findsOneWidget);
    expectNoErrors(tester);
  });

  testWidgets('each wheel is an adjustable control for screen readers', (tester) async {
    final semantics = tester.ensureSemantics();
    final harness = _Harness();
    await pumpKit(tester, desktop, harness.button(initialDate: DateTime(2024, 5, 5)));
    await _open(tester);

    expect(
      tester.getSemantics(find.descendant(of: find.byType(DanaviewDateWheels), matching: find.bySemanticsLabel('Year'))),
      isSemantics(
        label: 'Year',
        value: '2024',
        increasedValue: '2025',
        decreasedValue: '2023',
        hasIncreaseAction: true,
        hasDecreaseAction: true,
      ),
    );
    tester.semantics.increase(find.semantics.byLabel('Month'));
    await tester.pumpAndSettle();
    expect(find.text('Wednesday, 5 June 2024'), findsOneWidget);
    semantics.dispose();
  });

  for (final surface in [...surfaces, ..._extraSurfaces]) {
    testWidgets('fits on screen at $surface', (tester) async {
      final harness = _Harness();
      await pumpKit(tester, surface, harness.button(initialDate: DateTime(2023, 9, 30), title: longText));
      await _open(tester);
      expectNoErrors(tester);
      expect(find.byType(DanaviewDateWheels), findsOneWidget);

      // Narrow sheets switch to short month names.
      final fullNames = find.descendant(of: _wheel('month'), matching: find.text('September')).evaluate().isNotEmpty;
      await _pick(tester, 'month', fullNames ? 'August' : 'Aug');
      expectNoErrors(tester);
      await tester.ensureVisible(find.text('Done'));
      await tester.pumpAndSettle();
      expectInside(tester, find.text('Done'), surface.size);
      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();
      expect(harness.result, DateTime(2023, 8, 30));
      expectNoErrors(tester);
    });
  }
}
