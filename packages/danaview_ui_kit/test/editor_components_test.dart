import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_ui_kit/danaview_ui_kit.dart';

import 'test_utils.dart';

const Surface _phone = Surface('phone', Size(390, 800), 1.0, TargetPlatform.iOS);
const Surface _desktop = Surface('desktop', Size(1000, 800), 1.0, TargetPlatform.macOS);

/// Every width of the product matrix (280-1280) at every text scale (0.85-1.35), on touch and pointer
/// platforms, on top of the kit's four shared [surfaces].
final List<Surface> _matrix = <Surface>[
  ...surfaces,
  for (final width in const [280.0, 320.0, 360.0, 412.0, 600.0, 900.0, 1280.0])
    for (final scale in const [0.85, 1.0, 1.35])
      Surface(
        '${width.toInt()}px ${scale}x',
        Size(width, width < 600 ? 640 : 800),
        scale,
        width < 600 ? TargetPlatform.android : TargetPlatform.windows,
      ),
];

const String _longLabel =
    'A very long inspector label that has to ellipsize instead of overflowing its row';

/// Builds each component in the situations an editor puts it in: tight rows, scrolling bodies,
/// long labels, disabled state.
Widget _progressBars() => const Padding(
      padding: EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          DanaviewProgressBar(value: 0),
          SizedBox(height: 8),
          DanaviewProgressBar(value: 0.45, semanticLabel: _longLabel),
          SizedBox(height: 8),
          DanaviewProgressBar(value: 1, height: 10),
          SizedBox(height: 8),
          DanaviewProgressBar(),
          SizedBox(height: 8),
          Row(children: [Expanded(child: DanaviewProgressBar(value: 0.6)), SizedBox(width: 8), Text('60%')]),
          SizedBox(height: 8),
          SingleChildScrollView(scrollDirection: Axis.horizontal, child: DanaviewProgressBar(value: 0.3)),
        ],
      ),
    );

Widget _numberFields() => SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          DanaviewNumberField(value: 100, unit: '%', min: 0, max: 400, onChanged: (_) {}),
          const SizedBox(height: 8),
          DanaviewNumberField(value: -12.5, unit: 'px', label: _longLabel, bipolar: true, step: 0.5, onChanged: (_) {}),
          const SizedBox(height: 8),
          DanaviewNumberField(value: 3, label: 'Count', showSteppers: false, onChanged: (_) {}),
          const SizedBox(height: 8),
          const DanaviewNumberField(value: 7, unit: 's', label: 'Disabled', onChanged: null),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(child: DanaviewNumberField(value: 1920, unit: 'px', label: 'W', onChanged: (_) {})),
              const SizedBox(width: 8),
              Expanded(child: DanaviewNumberField(value: 1080, unit: 'px', label: 'H', onChanged: (_) {})),
            ],
          ),
          const SizedBox(height: 8),
          DanaviewNumberField(
            value: 61.5,
            unit: 'a very long unit name',
            formatter: (v) => '${v ~/ 60}:${(v % 60).toStringAsFixed(1).padLeft(4, '0')}',
            parser: (t) => double.tryParse(t),
            onChanged: (_) {},
          ),
          const SizedBox(height: 8),
          Wrap(
            children: [SizedBox(width: 120, child: DanaviewNumberField(value: 42, unit: '%', onChanged: (_) {}))],
          ),
        ],
      ),
    );

Widget _colorPickers() => SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          DanaviewColorPicker(color: const Color(0xFF5E60EE), onChanged: (_) {}, onEyedropper: () => null),
          const SizedBox(height: 16),
          DanaviewColorPicker(color: const Color(0x80FF8800), showOpacity: false, onChanged: (_) {}, areaHeight: 96),
          const SizedBox(height: 16),
          DanaviewColorPicker(color: const Color(0xFF000000), swatches: const [], onChanged: (_) {}),
        ],
      ),
    );

Widget _searchFields() => Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          DanaviewSearchField(onChanged: (_) {}),
          const SizedBox(height: 8),
          DanaviewSearchField(controller: TextEditingController(text: _longLabel), onChanged: (_) {}),
          const SizedBox(height: 8),
          const DanaviewSearchField(enabled: false, hint: 'Search 99 languages in the model catalog'),
        ],
      ),
    );

Widget _stepIndicators() => const Padding(
      padding: EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          DanaviewStepIndicator(step: 1, count: 3),
          SizedBox(height: 8),
          DanaviewStepIndicator(step: 2, count: 3, label: _longLabel),
          SizedBox(height: 8),
          DanaviewStepIndicator(step: 9, count: 40),
          SizedBox(height: 8),
          DanaviewStepIndicator(step: 3, count: 3, showLabel: false),
          SizedBox(height: 8),
          Row(children: [Expanded(child: DanaviewStepIndicator(step: 1, count: 12, label: _longLabel))]),
        ],
      ),
    );

Widget _dock({
  DanaviewDockDetent detent = DanaviewDockDetent.standard,
  ValueChanged<DanaviewDockDetent>? onDetentChanged,
  String? title = 'Transform',
  VoidCallback? onClose,
  bool scrollable = true,
  double? maxWidth,
  Widget? child,
}) {
  return Stack(
    children: [
      const Positioned.fill(child: ColoredBox(color: DanaviewColors.background)),
      Positioned(
        left: 0,
        right: 0,
        bottom: 0,
        child: DanaviewDockedPanel(
          title: title,
          onClose: onClose,
          detent: detent,
          onDetentChanged: onDetentChanged,
          scrollable: scrollable,
          maxWidth: maxWidth,
          child: child ??
              Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (var i = 0; i < 10; i++)
                    DanaviewNumberField(value: i * 10.0, unit: '%', label: _longLabel, onChanged: (_) {}),
                ],
              ),
        ),
      ),
    ],
  );
}

/// The visible dock (the widget itself also spans the keyboard lift below it).
Rect _dockRect(WidgetTester tester) => tester.getRect(
      find.descendant(of: find.byType(DanaviewDockedPanel), matching: find.byType(AnimatedContainer)).first,
    );

/// The drag handle, reachable without semantics.
Finder get _handle => find.byWidgetPredicate(
      (widget) => widget is MouseRegion && widget.cursor == SystemMouseCursors.resizeUpDown,
    );

void _expectInsidePanelBounds(WidgetTester tester, Surface surface) {
  final rect = _dockRect(tester);
  expect(rect.left >= -0.01 && rect.right <= surface.size.width + 0.01, isTrue, reason: '$rect');
  expect(rect.bottom <= surface.size.height + 0.01 && rect.top >= -0.01, isTrue, reason: '$rect');
}

void main() {
  group('overflow matrix (280-1280 px, text scale 0.85-1.35)', () {
    for (final surface in _matrix) {
      group('$surface', () {
        testWidgets('DanaviewProgressBar', (tester) async {
          await pumpKit(tester, surface, _progressBars());
          await tester.pump(const Duration(milliseconds: 400));
          expectNoErrors(tester);
          expectInside(tester, find.byType(DanaviewProgressBar).first, surface.size);
        });

        testWidgets('DanaviewNumberField', (tester) async {
          await pumpKit(tester, surface, _numberFields());
          expectNoErrors(tester);
          for (var i = 0; i < tester.widgetList(find.byType(DanaviewNumberField)).length; i++) {
            final rect = tester.getRect(find.byType(DanaviewNumberField).at(i));
            expect(rect.width <= surface.size.width + 0.01, isTrue, reason: '$rect');
            expect(rect.height, greaterThanOrEqualTo(40));
          }
        });

        testWidgets('DanaviewColorPicker', (tester) async {
          await pumpKit(tester, surface, _colorPickers());
          expectNoErrors(tester);
          final rect = tester.getRect(find.byType(DanaviewColorPicker).first);
          expect(rect.width <= surface.size.width + 0.01, isTrue, reason: '$rect');
          // The picker is reachable by scrolling even on the shortest surface.
          await tester.drag(find.byType(SingleChildScrollView).first, const Offset(0, -2000));
          await tester.pump();
          expectNoErrors(tester);
        });

        testWidgets('DanaviewDockedPanel (standard, expanded, titled, closable)', (tester) async {
          await pumpKit(tester, surface, _dock(onClose: () {}));
          await tester.pumpAndSettle();
          expectNoErrors(tester);
          _expectInsidePanelBounds(tester, surface);
          await pumpKit(tester, surface, _dock(detent: DanaviewDockDetent.expanded, onClose: () {}, title: _longLabel));
          await tester.pumpAndSettle();
          expectNoErrors(tester);
          _expectInsidePanelBounds(tester, surface);
          await pumpKit(tester, surface, _dock(scrollable: false, child: const Text('Fixed body')));
          await tester.pumpAndSettle();
          expectNoErrors(tester);
        });

        testWidgets('DanaviewSearchField', (tester) async {
          await pumpKit(tester, surface, _searchFields());
          expectNoErrors(tester);
          expectInside(tester, find.byType(DanaviewSearchField).first, surface.size);
        });

        testWidgets('DanaviewStepIndicator', (tester) async {
          await pumpKit(tester, surface, _stepIndicators());
          await tester.pumpAndSettle();
          expectNoErrors(tester);
          for (var i = 0; i < tester.widgetList(find.byType(DanaviewStepIndicator)).length; i++) {
            final rect = tester.getRect(find.byType(DanaviewStepIndicator).at(i));
            expect(rect.width <= surface.size.width + 0.01, isTrue, reason: '$rect');
          }
        });
      });
    }
  });

  group('DanaviewProgressBar', () {
    testWidgets('announces a clamped percentage and a custom label', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpKit(tester, _phone, const DanaviewProgressBar(value: 0.456, semanticLabel: 'Exporting'));
      await tester.pumpAndSettle();
      var node = tester.getSemantics(find.bySemanticsLabel('Exporting'));
      expect(node.value, '46 percent');

      await pumpKit(tester, _phone, const DanaviewProgressBar(value: 3, semanticLabel: 'Exporting'));
      await tester.pumpAndSettle();
      node = tester.getSemantics(find.bySemanticsLabel('Exporting'));
      expect(node.value, '100 percent');

      await pumpKit(tester, _phone, const DanaviewProgressBar(value: -1, semanticLabel: 'Exporting'));
      await tester.pumpAndSettle();
      expect(tester.getSemantics(find.bySemanticsLabel('Exporting')).value, '0 percent');

      await pumpKit(
        tester,
        _phone,
        DanaviewProgressBar(value: 0.5, semanticLabel: 'Frames', semanticFormatter: (f) => '${(f * 10).round()} of 10'),
      );
      await tester.pumpAndSettle();
      expect(tester.getSemantics(find.bySemanticsLabel('Frames')).value, '5 of 10');
      handle.dispose();
    });

    testWidgets('indeterminate has no value and loops until disposed', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpKit(tester, _phone, const DanaviewProgressBar());
      await tester.pump(const Duration(milliseconds: 700));
      final node = tester.getSemantics(find.bySemanticsLabel('Loading'));
      expect(node.value, isEmpty);
      expect(tester.hasRunningAnimations, isTrue);
      await pumpKit(tester, _phone, const SizedBox());
      await tester.pumpAndSettle();
      expect(tester.hasRunningAnimations, isFalse);
      handle.dispose();
    });

    testWidgets('indeterminate stands still when the platform reduces motion', (tester) async {
      tester.view.physicalSize = _phone.size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          theme: DanaviewTheme.darkTheme,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(disableAnimations: true),
            child: child!,
          ),
          home: const Scaffold(body: Center(child: DanaviewProgressBar())),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.hasRunningAnimations, isFalse);
      expectNoErrors(tester);
    });

    testWidgets('determinate bar grows with the value and fills its parent', (tester) async {
      await pumpKit(tester, _phone, const Center(child: SizedBox(width: 200, child: DanaviewProgressBar(value: 0.5))));
      await tester.pumpAndSettle();
      expect(tester.getSize(find.byType(DanaviewProgressBar)), const Size(200, 6));
      await pumpKit(tester, _phone, const Center(child: UnconstrainedBox(child: DanaviewProgressBar(value: double.nan))));
      await tester.pumpAndSettle();
      expect(tester.getSize(find.byType(DanaviewProgressBar)).width, DanaviewProgressBar.defaultWidth);
      expectNoErrors(tester);
    });
  });

  group('DanaviewNumberField', () {
    Future<List<double>> pumpField(
      WidgetTester tester, {
      double value = 10,
      double min = 0,
      double max = 100,
      double step = 1,
      String? unit,
      String? label,
      bool bipolar = false,
      Surface surface = _phone,
      List<String>? events,
    }) async {
      final changes = <double>[];
      var current = value;
      await pumpKit(
        tester,
        surface,
        StatefulBuilder(
          builder: (context, setState) => Center(
            child: SizedBox(
              width: 320,
              child: DanaviewNumberField(
                value: current,
                min: min,
                max: max,
                step: step,
                unit: unit,
                label: label,
                bipolar: bipolar,
                onChangeStart: events == null ? null : (v) => events.add('start $v'),
                onChangeEnd: events == null ? null : (v) => events.add('end $v'),
                onChanged: (v) {
                  changes.add(v);
                  setState(() => current = v);
                },
              ),
            ),
          ),
        ),
      );
      return changes;
    }

    testWidgets('steppers change by step, clamp, and disable at the bounds', (tester) async {
      final events = <String>[];
      final changes = await pumpField(tester, value: 99, max: 100, events: events);
      await tester.tap(find.bySemanticsLabel('Increase'));
      await tester.pump();
      expect(changes, [100]);
      expect(events, ['start 99.0', 'end 100.0']);
      // At the max the increase stepper is disabled.
      await tester.tap(find.bySemanticsLabel('Increase'), warnIfMissed: false);
      await tester.pump();
      expect(changes, [100]);
      await tester.tap(find.bySemanticsLabel('Decrease'));
      await tester.pump();
      expect(changes, [100, 99]);
      expectNoErrors(tester);
    });

    testWidgets('typed entry commits on submit, clamps, honors the unit and reverts garbage', (tester) async {
      final changes = await pumpField(tester, value: 50, unit: '%', max: 100);
      await tester.tap(find.byType(EditableText));
      await tester.pump();
      await tester.enterText(find.byType(EditableText), '250');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect(changes, [100]);
      expect(tester.widget<EditableText>(find.byType(EditableText)).controller.text, '100');

      await tester.tap(find.byType(EditableText));
      await tester.pump();
      await tester.enterText(find.byType(EditableText), '40 %');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect(changes, [100, 40]);

      await tester.tap(find.byType(EditableText));
      await tester.pump();
      await tester.enterText(find.byType(EditableText), '-');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect(changes, [100, 40], reason: 'unparsable text must not commit');
      expect(tester.widget<EditableText>(find.byType(EditableText)).controller.text, '40');
      expectNoErrors(tester);
    });

    testWidgets('typed entry commits on blur', (tester) async {
      final changes = await pumpField(tester, value: 5);
      await tester.tap(find.byType(EditableText));
      await tester.pump();
      await tester.enterText(find.byType(EditableText), '12');
      FocusManager.instance.primaryFocus!.unfocus();
      await tester.pump();
      expect(changes, [12]);
    });

    testWidgets('Up/Down, PageUp/PageDown and Shift adjust from the focused field; Escape reverts', (tester) async {
      final changes = await pumpField(tester, value: 50, step: 2);
      await tester.tap(find.byType(EditableText));
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      expect(changes, [52, 50, 48]);
      await tester.sendKeyEvent(LogicalKeyboardKey.pageUp);
      expect(changes.last, 68);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      expect(changes.last, 48);

      await tester.enterText(find.byType(EditableText), '99');
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(tester.widget<EditableText>(find.byType(EditableText)).controller.text, '48');
      expectNoErrors(tester);
    });

    testWidgets('rounds to the step decimals and formats bipolar values with a sign', (tester) async {
      final changes = await pumpField(tester, value: 0.9, min: -2, max: 2, step: 0.1, bipolar: true);
      expect(tester.widget<EditableText>(find.byType(EditableText)).controller.text, '+0.9');
      await tester.tap(find.bySemanticsLabel('Increase'));
      await tester.pump();
      expect(changes, [1.0]);
      expect(tester.widget<EditableText>(find.byType(EditableText)).controller.text, '+1.0');
      await tester.tap(find.byType(EditableText));
      await tester.pump();
      await tester.enterText(find.byType(EditableText), '-0.04');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect(changes.last, 0, reason: 'rounded to one decimal and no negative zero');
      expect(changes.last.isNegative, isFalse);
    });

    testWidgets('dragging the label scrubs the value and brackets the gesture', (tester) async {
      final events = <String>[];
      final changes = await pumpField(tester, value: 50, step: 4, label: 'Opacity', events: events);
      await tester.drag(find.text('Opacity'), const Offset(40, 0));
      await tester.pump();
      expect(changes, isNotEmpty);
      expect(changes.last, greaterThan(50));
      expect(events.first, 'start 50.0');
      expect(events.last, startsWith('end '));
      expectNoErrors(tester);
    });

    testWidgets('exposes an adjustable semantics node with increase/decrease actions', (tester) async {
      final handle = tester.ensureSemantics();
      final changes = await pumpField(tester, value: 20, unit: '%', label: 'Opacity', step: 5);
      final node = tester.getSemantics(find.bySemanticsLabel(RegExp('Opacity')).first);
      expect(node.getSemanticsData().hasAction(SemanticsAction.increase), isTrue);
      expect(node.getSemanticsData().hasAction(SemanticsAction.decrease), isTrue);
      expect(node.getSemanticsData().value, contains('20'));
      tester.semantics.performAction(find.semantics.byLabel(RegExp('Opacity')).first, SemanticsAction.increase);
      await tester.pump();
      expect(changes, [25]);
      handle.dispose();
    });

    testWidgets('hides the steppers below the minimum width but stays editable', (tester) async {
      final changes = await pumpField(tester, value: 3, surface: const Surface('n', Size(140, 400), 1, TargetPlatform.android));
      // The 320 box is clamped by the 140 surface.
      expect(find.byType(DanaviewIconButton), findsNothing);
      await tester.tap(find.byType(EditableText));
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      expect(changes, [4]);
      expectNoErrors(tester);
    });

    testWidgets('disabled fields ignore input and keys', (tester) async {
      await pumpKit(tester, _phone, const Center(child: SizedBox(width: 300, child: DanaviewNumberField(value: 1, onChanged: null))));
      await tester.tap(find.byType(EditableText), warnIfMissed: false);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      expect(tester.widget<EditableText>(find.byType(EditableText)).controller.text, '1');
      expectNoErrors(tester);
    });

    testWidgets('timecode notation through formatter and parser', (tester) async {
      final changes = <double>[];
      await pumpKit(
        tester,
        _phone,
        Center(
          child: SizedBox(
            width: 300,
            child: DanaviewNumberField(
              value: 65,
              min: 0,
              max: 3600,
              formatter: (v) => '${v ~/ 60}:${(v % 60).round().toString().padLeft(2, '0')}',
              parser: (t) {
                final parts = t.split(':');
                if (parts.length != 2) return null;
                final m = int.tryParse(parts[0]);
                final s = int.tryParse(parts[1]);
                return m == null || s == null ? null : (m * 60 + s).toDouble();
              },
              onChanged: changes.add,
            ),
          ),
        ),
      );
      expect(tester.widget<EditableText>(find.byType(EditableText)).controller.text, '1:05');
      await tester.tap(find.byType(EditableText));
      await tester.pump();
      await tester.enterText(find.byType(EditableText), '2:30');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect(changes, [150]);
    });
  });

  group('DanaviewColorPicker', () {
    Future<List<Color>> pumpPicker(
      WidgetTester tester, {
      Color color = const Color(0xFF3366CC),
      bool showOpacity = true,
      List<String>? events,
      FutureOr<Color?> Function()? eyedropper,
    }) async {
      final changes = <Color>[];
      var current = color;
      await pumpKit(
        tester,
        _phone,
        StatefulBuilder(
          builder: (context, setState) => SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: DanaviewColorPicker(
              color: current,
              showOpacity: showOpacity,
              onEyedropper: eyedropper,
              onChangeStart: events == null ? null : (_) => events.add('start'),
              onChangeEnd: events == null ? null : (_) => events.add('end'),
              onChanged: (c) {
                changes.add(c);
                setState(() => current = c);
              },
            ),
          ),
        ),
      );
      return changes;
    }

    test('hex parsing and formatting follow the CSS order', () {
      expect(DanaviewColorPicker.parseHex('#FF8800'), const Color(0xFFFF8800));
      expect(DanaviewColorPicker.parseHex('f80'), const Color(0xFFFF8800));
      expect(DanaviewColorPicker.parseHex('f808'), const Color(0x88FF8800));
      expect(DanaviewColorPicker.parseHex('FF880080'), const Color(0x80FF8800));
      expect(DanaviewColorPicker.parseHex('FF880080', allowAlpha: false), const Color(0xFFFF8800));
      expect(DanaviewColorPicker.parseHex('FF880'), isNull);
      expect(DanaviewColorPicker.parseHex('XYZ123'), isNull);
      expect(DanaviewColorPicker.parseHex(''), isNull);
      expect(DanaviewColorPicker.formatHex(const Color(0xFFFF8800)), 'FF8800');
      expect(DanaviewColorPicker.formatHex(const Color(0x80FF8800)), 'FF880080');
      expect(DanaviewColorPicker.formatHex(const Color(0x80FF8800), includeAlpha: false), 'FF8800');
      for (final swatch in DanaviewColorPicker.defaultSwatches) {
        expect(DanaviewColorPicker.parseHex(DanaviewColorPicker.formatHex(swatch)), swatch);
      }
    });

    testWidgets('typing a full hex value reports the color once, bracketed for undo', (tester) async {
      final events = <String>[];
      final changes = await pumpPicker(tester, events: events);
      final hex = find.byType(EditableText);
      await tester.tap(hex);
      await tester.pump();
      await tester.enterText(hex, 'FF0000');
      await tester.pump();
      expect(changes.last.toARGB32(), 0xFFFF0000);
      expect(events, ['start', 'end']);
      // Partial input does nothing.
      final count = changes.length;
      await tester.enterText(hex, 'FF00');
      await tester.pump();
      expect(changes.length, count);
      expectNoErrors(tester);
    });

    testWidgets('hex with alpha is accepted only when opacity is shown', (tester) async {
      var changes = await pumpPicker(tester);
      await tester.tap(find.byType(EditableText));
      await tester.pump();
      await tester.enterText(find.byType(EditableText), '00FF0080');
      await tester.pump();
      expect(changes.last.toARGB32(), 0x8000FF00);

      changes = await pumpPicker(tester, showOpacity: false, color: const Color(0x8000FF00));
      expect(changes, isEmpty);
      expect(find.bySemanticsLabel('Opacity'), findsNothing);
      await tester.tap(find.byType(EditableText));
      await tester.pump();
      await tester.enterText(find.byType(EditableText), '0000FF');
      await tester.pump();
      expect(changes.last.a, 1.0);
      expect(changes.last.toARGB32(), 0xFF0000FF);
    });

    testWidgets('tapping a swatch applies it', (tester) async {
      final events = <String>[];
      final changes = await pumpPicker(tester, events: events);
      await tester.tap(find.bySemanticsLabel('Color #EF4444'));
      await tester.pump();
      expect(changes.last.toARGB32(), 0xFFEF4444);
      expect(events, ['start', 'end']);
    });

    testWidgets('dragging the square changes saturation and brightness; one start/end per drag', (tester) async {
      final events = <String>[];
      final changes = await pumpPicker(tester, color: const Color(0xFFFF0000), events: events);
      final area = find.bySemanticsLabel('Saturation and brightness');
      final rect = tester.getRect(area);
      final gesture = await tester.startGesture(rect.bottomLeft + const Offset(1, -1));
      await tester.pump();
      await gesture.moveTo(rect.center);
      await tester.pump();
      await gesture.up();
      await tester.pump();
      expect(changes, isNotEmpty);
      final hsv = HSVColor.fromColor(changes.last);
      expect(hsv.saturation, closeTo(0.5, 0.15));
      expect(hsv.value, closeTo(0.5, 0.15));
      expect(events, ['start', 'end']);
      expectNoErrors(tester);
    });

    testWidgets('keeps the hue while the color passes through black', (tester) async {
      final changes = await pumpPicker(tester, color: const Color(0xFF0000FF));
      final area = find.bySemanticsLabel('Saturation and brightness');
      final rect = tester.getRect(area);
      final gesture = await tester.startGesture(rect.center);
      await gesture.moveTo(rect.bottomRight);
      await gesture.up();
      await tester.pump();
      expect(HSVColor.fromColor(changes.last).value, closeTo(0, 0.05));
      final gesture2 = await tester.startGesture(rect.bottomRight - const Offset(2, 2));
      await gesture2.moveTo(rect.topRight + const Offset(-2, 2));
      await gesture2.up();
      await tester.pump();
      expect(HSVColor.fromColor(changes.last).hue, closeTo(240, 3));
    });

    testWidgets('keyboard and semantic actions drive the hue strip, square and opacity strip', (tester) async {
      final handle = tester.ensureSemantics();
      final changes = await pumpPicker(tester, color: const Color(0xFFFF0000));
      // Tab reaches the square, then the hue strip, then the opacity strip.
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pump();
      expect(HSVColor.fromColor(changes.last).saturation, lessThan(1.0), reason: 'square: arrow left/right is saturation');
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      expect(HSVColor.fromColor(changes.last).value, lessThan(1.0), reason: 'square: arrow up/down is brightness');
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      final before = changes.length;
      await tester.sendKeyEvent(LogicalKeyboardKey.end);
      await tester.pump();
      expect(changes.length, greaterThan(before));
      expect(HSVColor.fromColor(changes.last).hue, anyOf(closeTo(360, 1.0), closeTo(0, 1.0)));

      final hue = find.bySemanticsLabel('Hue');
      expect(tester.getSemantics(hue).getSemanticsData().hasAction(SemanticsAction.increase), isTrue);
      expect(tester.getSemantics(hue).getSemanticsData().value, endsWith('degrees'));
      tester.semantics.performAction(find.semantics.byLabel('Opacity'), SemanticsAction.decrease);
      await tester.pump();
      expect(changes.last.a, lessThan(1.0));
      expect(tester.getSemantics(find.bySemanticsLabel('Opacity')).getSemanticsData().value, endsWith('percent'));
      handle.dispose();
    });

    testWidgets('eyedropper callback result is applied, cancel is ignored', (tester) async {
      Color? answer = const Color(0xFF00FF00);
      final changes = await pumpPicker(tester, eyedropper: () => answer);
      await tester.tap(find.byTooltip('Pick color from screen'));
      await tester.pump();
      await tester.pump();
      expect(changes.last.toARGB32(), 0xFF00FF00);
      final count = changes.length;
      answer = null;
      await tester.tap(find.byTooltip('Pick color from screen'));
      await tester.pump();
      await tester.pump();
      expect(changes.length, count);
    });

    testWidgets('no eyedropper button without a callback', (tester) async {
      await pumpPicker(tester);
      expect(find.byTooltip('Pick color from screen'), findsNothing);
    });

    testWidgets('an external color change updates the hex field and the preview', (tester) async {
      Color color = const Color(0xFF112233);
      late StateSetter set;
      await pumpKit(
        tester,
        _phone,
        StatefulBuilder(
          builder: (context, setState) {
            set = setState;
            return SingleChildScrollView(child: DanaviewColorPicker(color: color, onChanged: (_) {}));
          },
        ),
      );
      expect(tester.widget<EditableText>(find.byType(EditableText)).controller.text, '112233');
      set(() => color = const Color(0xFFABCDEF));
      await tester.pump();
      expect(tester.widget<EditableText>(find.byType(EditableText)).controller.text, 'ABCDEF');
    });

    test('swatch check marks and selected rings keep contrast through foregroundOn', () {
      for (final swatch in DanaviewColorPicker.defaultSwatches) {
        final fg = DanaviewColors.foregroundOn(swatch);
        expect(DanaviewColors.contrastRatio(fg, swatch), greaterThanOrEqualTo(3.0), reason: '$swatch');
      }
    });
  });

  group('DanaviewDockedPanel', () {
    testWidgets('is non-modal: content behind it stays interactive', (tester) async {
      var taps = 0;
      await pumpKit(
        tester,
        _phone,
        Stack(
          children: [
            Positioned(
              left: 0,
              top: 0,
              child: GestureDetector(
                onTap: () => taps++,
                child: const SizedBox(width: 100, height: 100, child: ColoredBox(color: Colors.red)),
              ),
            ),
            const Positioned(left: 0, right: 0, bottom: 0, child: DanaviewDockedPanel(child: Text('Body'))),
          ],
        ),
      );
      await tester.pumpAndSettle();
      await tester.tapAt(const Offset(40, 40));
      expect(taps, 1);
      expectNoErrors(tester);
    });

    testWidgets('rests at the standard height and expands to the screen share, then back', (tester) async {
      final detents = <DanaviewDockDetent>[];
      await pumpKit(tester, _phone, _dock(onDetentChanged: detents.add));
      await tester.pumpAndSettle();
      expect(_dockRect(tester).height, 240);
      expect(_dockRect(tester).bottom, closeTo(800, 0.5));

      await tester.tap(_handle);
      await tester.pumpAndSettle();
      expect(detents, [DanaviewDockDetent.expanded]);
      expect(_dockRect(tester).height, closeTo(800 * 0.85, 0.5));

      await tester.tap(_handle);
      await tester.pumpAndSettle();
      expect(detents, [DanaviewDockDetent.expanded, DanaviewDockDetent.standard]);
      expect(_dockRect(tester).height, 240);
    });

    testWidgets('dragging the handle past the midpoint or flinging up settles expanded; dragging down returns', (tester) async {
      final detents = <DanaviewDockDetent>[];
      await pumpKit(tester, _phone, _dock(onDetentChanged: detents.add));
      await tester.pumpAndSettle();
      final handle = _handle;

      // Slow drag a little: stays standard.
      await tester.drag(handle, const Offset(0, -20), warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(_dockRect(tester).height, 240);
      expect(detents, isEmpty);

      // Drag beyond the midpoint of the two detents.
      final gesture = await tester.startGesture(tester.getTopLeft(_handle).translate(100, 10));
      await gesture.moveBy(const Offset(0, -30)); // crosses the touch slop
      await gesture.moveBy(const Offset(0, -150));
      await tester.pump();
      expect(_dockRect(tester).height, greaterThan(240), reason: 'follows the finger');
      expect(detents, isEmpty, reason: 'nothing is reported until the drag settles');
      await gesture.moveBy(const Offset(0, -200));
      await tester.pump(const Duration(milliseconds: 600));
      await gesture.up();
      await tester.pumpAndSettle();
      expect(detents.last, DanaviewDockDetent.expanded);
      expect(_dockRect(tester).height, closeTo(680, 0.5));

      // Fling down.
      await tester.fling(find.text('Transform'), const Offset(0, 300), 2000);
      await tester.pumpAndSettle();
      expect(detents.last, DanaviewDockDetent.standard);
      expect(_dockRect(tester).height, 240);
      expectNoErrors(tester);
    });

    testWidgets('keyboard: handle takes focus; Enter/Space toggle, Up expands, Down collapses', (tester) async {
      final detents = <DanaviewDockDetent>[];
      await pumpKit(tester, _phone, _dock(onDetentChanged: detents.add));
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pumpAndSettle();
      expect(detents, [DanaviewDockDetent.expanded]);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      expect(detents.length, 1, reason: 'already expanded');
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      expect(detents.last, DanaviewDockDetent.standard);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(detents.last, DanaviewDockDetent.expanded);
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pumpAndSettle();
      expect(detents.last, DanaviewDockDetent.standard);
      expectNoErrors(tester);
    });

    testWidgets('semantics: handle is an adjustable button with a state value; title is a header', (tester) async {
      final handle = tester.ensureSemantics();
      final detents = <DanaviewDockDetent>[];
      await pumpKit(tester, _phone, _dock(onDetentChanged: detents.add));
      await tester.pumpAndSettle();
      var node = tester.getSemantics(find.bySemanticsLabel('Resize panel'));
      var data = node.getSemanticsData();
      expect(data.value, 'Default height');
      expect(data.hasAction(SemanticsAction.increase), isTrue);
      expect(data.hasAction(SemanticsAction.decrease), isFalse);
      expect(data.hasAction(SemanticsAction.tap), isTrue);
      expect(data.flagsCollection.isButton, isTrue);
      expect(find.semantics.byLabel('Transform').evaluate().single.getSemanticsData().flagsCollection.isHeader, isTrue);

      tester.semantics.performAction(find.semantics.byLabel('Resize panel'), SemanticsAction.increase);
      await tester.pumpAndSettle();
      expect(detents, [DanaviewDockDetent.expanded]);
      node = tester.getSemantics(find.bySemanticsLabel('Resize panel'));
      data = node.getSemanticsData();
      expect(data.value, 'Expanded');
      expect(data.hasAction(SemanticsAction.decrease), isTrue);
      handle.dispose();
    });

    testWidgets('an external detent change moves the panel', (tester) async {
      await pumpKit(tester, _phone, _dock());
      await tester.pumpAndSettle();
      expect(_dockRect(tester).height, 240);
      await pumpKit(tester, _phone, _dock(detent: DanaviewDockDetent.expanded));
      await tester.pumpAndSettle();
      expect(_dockRect(tester).height, closeTo(680, 0.5));
    });

    testWidgets('lifts above the on-screen keyboard and never exceeds the room above it', (tester) async {
      tester.view.physicalSize = const Size(390, 800);
      tester.view.devicePixelRatio = 1;
      tester.view.viewInsets = const FakeViewPadding(bottom: 300);
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          theme: DanaviewTheme.darkTheme,
          home: Scaffold(resizeToAvoidBottomInset: false, body: _dock(detent: DanaviewDockDetent.expanded)),
        ),
      );
      await tester.pumpAndSettle();
      final rect = _dockRect(tester);
      expect(rect.bottom, closeTo(500, 0.5));
      expect(rect.height, lessThanOrEqualTo(500 - 8));
      expectNoErrors(tester);
    });

    testWidgets('a Scaffold that already resizes for the keyboard is not compensated twice', (tester) async {
      tester.view.physicalSize = const Size(390, 800);
      tester.view.devicePixelRatio = 1;
      tester.view.viewInsets = const FakeViewPadding(bottom: 300);
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(theme: DanaviewTheme.darkTheme, home: Scaffold(body: _dock())));
      await tester.pumpAndSettle();
      expect(_dockRect(tester).bottom, closeTo(500, 0.5));
      expectNoErrors(tester);
    });

    testWidgets('maxWidth centers the panel on wide screens; the body scrolls', (tester) async {
      await pumpKit(tester, _desktop, _dock(maxWidth: 480));
      await tester.pumpAndSettle();
      final rect = _dockRect(tester);
      expect(rect.width, 480);
      expect(rect.center.dx, closeTo(500, 0.5));
      await tester.drag(find.byType(SingleChildScrollView).last, const Offset(0, -300));
      await tester.pump();
      expect(find.byType(Scrollable), findsWidgets);
      expectNoErrors(tester);
    });

    testWidgets('close button calls back; sheet-like look uses kit tokens', (tester) async {
      var closed = 0;
      await pumpKit(tester, _phone, _dock(onClose: () => closed++));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Close'));
      expect(closed, 1);
      final decorated = tester
          .widgetList<DecoratedBox>(find.descendant(of: find.byType(DanaviewDockedPanel), matching: find.byType(DecoratedBox)))
          .map((box) => box.decoration)
          .whereType<BoxDecoration>()
          .toList();
      expect(decorated.any((d) => d.color == DanaviewColors.surfaceElevated && d.borderRadius == DanaviewRadius.sheetTop), isTrue);
      expect(decorated.any((d) => d.border == DanaviewBorders.all), isTrue);
    });
  });

  group('DanaviewSearchField', () {
    testWidgets('debounces typing, flushes on clear and submit, and reports the final text', (tester) async {
      final changes = <String>[];
      final submits = <String>[];
      await pumpKit(
        tester,
        _phone,
        Padding(
          padding: const EdgeInsets.all(16),
          child: DanaviewSearchField(onChanged: changes.add, onSubmitted: submits.add),
        ),
      );
      await tester.tap(find.byType(EditableText));
      await tester.pump();
      await tester.enterText(find.byType(EditableText), 'e');
      await tester.pump(const Duration(milliseconds: 100));
      await tester.enterText(find.byType(EditableText), 'en');
      await tester.pump(const Duration(milliseconds: 200));
      expect(changes, isEmpty, reason: 'still inside the debounce window');
      await tester.pump(const Duration(milliseconds: 100));
      expect(changes, ['en']);

      // Submit flushes the pending text first, in order.
      await tester.enterText(find.byType(EditableText), 'eng');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pump();
      expect(changes, ['en', 'eng']);
      expect(submits, ['eng']);
      await tester.pump(const Duration(seconds: 1));
      expect(changes, ['en', 'eng'], reason: 'the debounce timer was consumed');

      // Clearing reports immediately.
      await tester.enterText(find.byType(EditableText), '');
      await tester.pump();
      expect(changes.last, '');
      expectNoErrors(tester);
    });

    testWidgets('Duration.zero debounce reports every change; pending work is dropped on dispose', (tester) async {
      final changes = <String>[];
      await pumpKit(tester, _phone, DanaviewSearchField(debounce: Duration.zero, onChanged: changes.add));
      await tester.enterText(find.byType(EditableText), 'a');
      await tester.pump();
      expect(changes, ['a']);

      final late = <String>[];
      await pumpKit(tester, _phone, DanaviewSearchField(onChanged: late.add));
      await tester.enterText(find.byType(EditableText), 'abc');
      await pumpKit(tester, _phone, const SizedBox());
      await tester.pump(const Duration(seconds: 1));
      expect(late, isEmpty);
      expectNoErrors(tester);
    });

    testWidgets('has a search icon, a search keyboard action and a semantic label', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpKit(tester, _phone, const DanaviewSearchField(hint: 'Find a font', semanticLabel: 'Search fonts'));
      expect(find.byIcon(Icons.search_rounded), findsOneWidget);
      expect(tester.widget<EditableText>(find.byType(EditableText)).textInputAction, TextInputAction.search);
      expect(find.bySemanticsLabel(RegExp('Search fonts')), findsWidgets);
      handle.dispose();
    });

    testWidgets('clear button empties the field and reports immediately', (tester) async {
      final changes = <String>[];
      final controller = TextEditingController(text: 'hello');
      addTearDown(controller.dispose);
      await pumpKit(tester, _phone, DanaviewSearchField(controller: controller, onChanged: changes.add));
      await tester.tap(find.byType(EditableText));
      await tester.pump();
      await tester.enterText(find.byType(EditableText), 'hello!');
      await tester.pump();
      final clear = find.byIcon(Icons.cancel_rounded);
      expect(clear, findsWidgets);
      await tester.tap(clear.first);
      await tester.pump();
      expect(controller.text, isEmpty);
      expect(changes.last, '');
    });

    testWidgets('disabled field takes no focus', (tester) async {
      final focus = FocusNode();
      addTearDown(focus.dispose);
      await pumpKit(tester, _phone, DanaviewSearchField(focusNode: focus, enabled: false));
      await tester.tap(find.byType(DanaviewSearchField), warnIfMissed: false);
      await tester.pump();
      expect(focus.hasFocus, isFalse);
    });
  });

  group('DanaviewStepIndicator', () {
    testWidgets('announces one label, clamps the step and dims later steps', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpKit(tester, _phone, const Center(child: DanaviewStepIndicator(step: 2, count: 3)));
      await tester.pumpAndSettle();
      expect(find.bySemanticsLabel('Step 2 of 3'), findsOneWidget);
      expect(find.text('Step 2 of 3'), findsOneWidget);

      await pumpKit(tester, _phone, const Center(child: DanaviewStepIndicator(step: 9, count: 3)));
      await tester.pumpAndSettle();
      expect(find.text('Step 3 of 3'), findsOneWidget);
      await pumpKit(tester, _phone, const Center(child: DanaviewStepIndicator(step: -4, count: 3)));
      await tester.pumpAndSettle();
      expect(find.text('Step 1 of 3'), findsOneWidget);

      await pumpKit(tester, _phone, const Center(child: DanaviewStepIndicator(step: 1, count: 2, semanticLabel: 'Choose language')));
      await tester.pumpAndSettle();
      expect(find.bySemanticsLabel('Choose language'), findsOneWidget);
      handle.dispose();
    });

    testWidgets('draws one dot per step, a wider active dot, reached and upcoming colors', (tester) async {
      await pumpKit(tester, _phone, const Center(child: DanaviewStepIndicator(step: 2, count: 4)));
      await tester.pumpAndSettle();
      final dots = tester
          .widgetList<AnimatedContainer>(find.descendant(of: find.byType(DanaviewStepIndicator), matching: find.byType(AnimatedContainer)))
          .toList();
      expect(dots.length, 4);
      final widths = dots.map((d) => d.constraints!.maxWidth).toList();
      expect(widths, [DanaviewStepIndicator.dotSize, DanaviewStepIndicator.activeWidth, DanaviewStepIndicator.dotSize, DanaviewStepIndicator.dotSize]);
      final colors = dots.map((d) => (d.decoration! as BoxDecoration).color).toList();
      expect(colors, [
        DanaviewStepIndicator.reachedColor,
        DanaviewStepIndicator.reachedColor,
        DanaviewStepIndicator.upcomingColor,
        DanaviewStepIndicator.upcomingColor,
      ]);
    });

    testWidgets('showLabel false hides the text but keeps the announcement', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpKit(tester, _phone, const Center(child: DanaviewStepIndicator(step: 1, count: 3, showLabel: false)));
      expect(find.text('Step 1 of 3'), findsNothing);
      expect(find.bySemanticsLabel('Step 1 of 3'), findsOneWidget);
      handle.dispose();
    });
  });

  group('contrast (DanaviewColors.foregroundOn and token pairs)', () {
    test('text drawn by the new components stays readable on its surface', () {
      // Number field and search field text/units on their resting and focused fills.
      for (final fill in [DanaviewColors.surfaceElevatedHigher, DanaviewColors.fieldActive]) {
        expect(DanaviewColors.contrastRatio(DanaviewColors.textPrimary, fill), greaterThanOrEqualTo(4.5));
        expect(DanaviewColors.contrastRatio(DanaviewColors.textSecondary, fill), greaterThanOrEqualTo(4.5));
      }
      // Dock title, step label and number-field labels on the sheet/dock surface.
      expect(DanaviewColors.contrastRatio(DanaviewColors.textPrimary, DanaviewColors.surfaceElevated), greaterThanOrEqualTo(4.5));
      expect(DanaviewColors.contrastRatio(DanaviewColors.textSecondary, DanaviewColors.surfaceElevated), greaterThanOrEqualTo(4.5));
      expect(DanaviewColors.contrastRatio(DanaviewColors.textSecondary, DanaviewColors.background), greaterThanOrEqualTo(4.5));
    });

    test('graphical marks keep 3:1 against the surfaces they sit on', () {
      for (final surface in [DanaviewColors.surfaceElevated, DanaviewColors.surface, DanaviewColors.background]) {
        expect(DanaviewColors.contrastRatio(DanaviewStepIndicator.reachedColor, surface), greaterThanOrEqualTo(3.0));
      }
      // Progress fill against its track.
      expect(DanaviewColors.contrastRatio(DanaviewColors.primaryLight, DanaviewColors.trackBackground), greaterThanOrEqualTo(3.0));
    });

    test('foreground on filled steppers and tonal fills is picked for contrast', () {
      for (final fill in [DanaviewColors.surfaceElevatedHigher, DanaviewColors.primary, DanaviewColors.primaryDark]) {
        expect(DanaviewColors.contrastRatio(DanaviewColors.foregroundOn(fill), fill), greaterThanOrEqualTo(4.5));
      }
    });
  });

  group('forbidden Material visuals', () {
    // Mirrors the architecture test's list (ARCH 1.3 rule 1): whole identifiers only.
    const forbidden = <String>[
      'AlertDialog', 'Slider', 'RangeSlider', 'ListTile', 'ExpansionTile', 'showDatePicker', //
      'LinearProgressIndicator', 'CircularProgressIndicator', 'Switch', 'Checkbox', 'PopupMenuButton',
      'showMenu', 'MenuAnchor', 'DropdownButton', 'DropdownMenu', 'showModalBottomSheet', 'showDialog',
      'Dialog', 'SimpleDialog', 'SnackBar', 'LicensePage', 'TextField', 'TextFormField',
      'ElevatedButton', 'TextButton', 'OutlinedButton', 'FilledButton', 'IconButton',
      'FloatingActionButton', 'Chip', 'ChoiceChip', 'FilterChip', 'TabBar', 'ReorderableListView',
      'Card', 'InkWell', 'InkResponse', 'ColorPicker', 'CupertinoSlider', 'CupertinoTextField',
      'Scrollbar', 'BottomSheet', 'DraggableScrollableSheet',
    ];
    const files = <String>[
      'danaview_progress_bar',
      'danaview_number_field',
      'danaview_color_picker',
      'danaview_docked_panel',
      'danaview_search_field',
      'danaview_step_indicator',
    ];

    String strip(String source) {
      // Comments may legitimately name Material widgets; code and string literals may not.
      return source
          .split('\n')
          .map((line) {
            final index = line.indexOf('//');
            return index < 0 ? line : line.substring(0, index);
          })
          .join('\n');
    }

    for (final name in files) {
      test('$name uses only kit visuals and Figtree', () {
        final file = File('lib/src/components/$name.dart');
        expect(file.existsSync(), isTrue, reason: 'run flutter test from packages/danaview_ui_kit');
        final code = strip(file.readAsStringSync());
        final pattern = RegExp('(?<![A-Za-z0-9_\$])(${forbidden.join('|')})(?![A-Za-z0-9_\$])');
        final hits = pattern.allMatches(code).map((m) => m.group(0)).toSet();
        expect(hits, isEmpty, reason: '$name.dart references forbidden Material chrome: $hits');
        expect(code.contains('fontFamily'), isFalse, reason: 'Figtree comes from the theme; do not set a family');
        expect(code.contains('GoogleFonts'), isFalse);
        expect(code.contains('Theme.of(context).colorScheme'), isFalse, reason: 'use DanaviewColors, not the Material scheme');
      });
    }

    test('the barrel exports every new component', () {
      final barrel = File('lib/danaview_ui_kit.dart').readAsStringSync();
      for (final name in files) {
        expect(barrel, contains("export 'src/components/$name.dart';"));
      }
    });
  });
}
