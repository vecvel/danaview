// OWNER: UX-16
//
// Inspector rows generated from PropertyKey metadata (ux.md §9.3): which row each value kind
// gets, labels, ranges and units from the metadata, and the history contract: a slider drag is one
// entry, keyboard steps < 500 ms apart are one entry, typed values, resets, switches, choices and
// colour gestures are one entry each; keyframed properties show their value at the playhead.

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vwish_editor/src/editor/inspector/color_field.dart';
import 'package:vwish_editor/src/editor/inspector/inspector_rows.dart';
import 'package:vwish_editor/src/editor/inspector/keyframe_toggle.dart';
import 'package:vwish_editor/src/editor/layout/editor_layout.dart';
import 'package:vwish_editor_core/model.dart';
import 'package:vwish_editor_core/ops.dart' show AddKeyframe;
import 'package:vwish_ui_kit/vwish_ui_kit.dart';

import '../support/support.dart';
import 'inspector_rig.dart';

TimeUs f(int frames) => FrameRate.fps30.timeOfFrame(frames);

final List<PropertyKey<Object?>> textKeys = [
  PropertyKeys.position,
  PropertyKeys.scale,
  PropertyKeys.rotation,
  PropertyKeys.opacity,
  PropertyKeys.bold,
  PropertyKeys.textAlign,
  PropertyKeys.textColor,
  PropertyKeys.fontFamily, // free text: the panel's own editor
  PropertyKeys.fit, // does not apply to text
  PropertyKeys.volume, // does not apply to text
];

final Map<String, List<VwishOption<Object?>>> alignOptions = {
  PropertyKeys.textAlign.id: const [
    VwishOption<Object?>(value: TextAlignH.left, label: 'Left'),
    VwishOption<Object?>(value: TextAlignH.center, label: 'Center'),
    VwishOption<Object?>(value: TextAlignH.right, label: 'Right'),
  ],
};

/// The rows of [textKeys] for the first text item in a scrolling sheet.
Widget rowsSheet(RigItems items) => ColoredBox(
      color: VwishColors.surfaceElevated,
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: InspectorRows.forItem(items.textA, textKeys, options: alignOptions),
        ),
      ),
    );

Future<InspectorRig> pumpRows(WidgetTester tester, {EditorSurface surface = SurfaceMatrix.phone}) =>
    InspectorRig.pumpWith(tester, (items) => rowsSheet(items), surface: surface);

Finder row(String label) => find.widgetWithText(InspectorSliderRow, label);

Finder slider(String label) => find.descendant(of: row(label), matching: find.byType(VwishSlider));

TextItem textA(InspectorRig rig) => rig.item(rig.items.textA) as TextItem;

void main() {
  late DateTime now;
  setUp(() {
    now = DateTime.utc(2026, 10, 11, 9);
    InspectorRows.clock = () => now;
  });
  tearDown(() => InspectorRows.clock = DateTime.now);

  group('generated from PropertyKey metadata', () {
    testWidgets('each value kind gets its row; keys that do not apply or have their own editor are left out', (tester) async {
      await pumpRows(tester);
      expect(tester.widgetList<InspectorSliderRow>(find.byType(InspectorSliderRow)).map((r) => r.label),
          ['Position X', 'Position Y', 'Scale', 'Rotation', 'Opacity']);
      expect(find.widgetWithText(InspectorToggleRow, 'Bold'), findsOneWidget);
      expect(find.byType(InspectorChoiceRow<Object?>), findsOneWidget);
      expect(find.widgetWithText(InspectorColorRow, 'Colour'), findsOneWidget);
      expect(find.text('Fit'), findsNothing);
      expect(find.text('Volume'), findsNothing);
      expect(find.text('Font'), findsNothing);
      expectNoOverflow(tester);
    });

    testWidgets('range, default, unit and display scale come from the metadata', (tester) async {
      await pumpRows(tester);
      final opacity = tester.widget<InspectorSliderRow>(row('Opacity'));
      expect((opacity.min, opacity.max, opacity.defaultValue, opacity.unit, opacity.displayScale), (0, 1, 1, '%', 100));
      expect(find.descendant(of: row('Opacity'), matching: find.text('100%')), findsOneWidget);
      final rotation = tester.widget<InspectorSliderRow>(row('Rotation'));
      expect((rotation.min, rotation.max, rotation.unit), (-360, 360, '°'));
      expect(find.descendant(of: row('Rotation'), matching: find.text('0°')), findsOneWidget);
      // Bipolar ranges fill from 0.
      expect(tester.widget<VwishSlider>(slider('Rotation')).origin, 0);
      expect(tester.widget<VwishSlider>(slider('Opacity')).origin, isNull);
      // Keyframable rows carry a toggle; switches and colours do not.
      expect(find.descendant(of: row('Opacity'), matching: find.byType(PropertyKeyframeToggle)), findsOneWidget);
      expect(find.descendant(of: find.byType(InspectorToggleRow), matching: find.byType(PropertyKeyframeToggle)), findsNothing);
    });

    test('formatting', () {
      expect(InspectorRows.digitsFor(1), 0);
      expect(InspectorRows.digitsFor(0.1), 1);
      expect(InspectorRows.digitsFor(0.25), 2);
      expect(InspectorRows.format(0.456, displayScale: 100, unit: '%'), '46%');
      expect(InspectorRows.format(-12, unit: '°'), '-12°');
      expect(InspectorRows.format(1500000, displayScale: 1e-6, fractionDigits: 1, unit: 's'), '1.5 s');
      expect(InspectorRows.format(-0.0001, displayScale: 100, unit: '%'), '0%');
    });
  });

  group('history (ux.md §9.3 transactions)', () {
    testWidgets('a slider drag is one history entry', (tester) async {
      final rig = await pumpRows(tester);
      final before = rig.state.history.position;
      final gesture = await tester.startGesture(tester.getCenter(slider('Opacity')));
      for (var i = 0; i < 6; i++) {
        await gesture.moveBy(const Offset(-12, 0));
        await tester.pump();
      }
      // The working copy follows the drag before the commit.
      expect(rig.state.inTransaction, isTrue);
      await gesture.up();
      await tester.pump();
      await tester.pump();
      expect(rig.state.inTransaction, isFalse);
      expect(rig.state.history.position, before + 1);
      expect(rig.state.history.undoLabel, 'Change opacity');
      expect(textA(rig).transform.opacity, lessThan(1));
      rig.editor.undo();
      await tester.pump();
      expect(textA(rig).transform.opacity, 1);
    });

    testWidgets('keyboard steps within 500 ms join one entry; a later step starts another', (tester) async {
      final rig = await pumpRows(tester);
      final before = rig.state.history.position;
      Focus.of(tester.element(find.descendant(of: slider('Opacity'), matching: find.byType(GestureDetector)).first)).requestFocus();
      await tester.pump();
      for (var i = 0; i < 3; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
        await tester.pump();
        now = now.add(const Duration(milliseconds: 200));
      }
      expect(textA(rig).transform.opacity, closeTo(0.97, 1e-9));
      expect(rig.state.history.position, before + 1);
      now = now.add(const Duration(milliseconds: 600));
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pump();
      expect(textA(rig).transform.opacity, closeTo(0.96, 1e-9));
      expect(rig.state.history.position, before + 2);
    });

    testWidgets('a typed value is one command; double-tap resets to the default', (tester) async {
      final rig = await pumpRows(tester);
      final before = rig.state.history.position;
      await tester.tap(find.descendant(of: row('Opacity'), matching: find.text('100%')));
      await tester.pump();
      final field = find.descendant(of: row('Opacity'), matching: find.byType(EditableText));
      expect(field, findsOneWidget);
      await tester.enterText(field, '40');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect(textA(rig).transform.opacity, closeTo(0.4, 1e-9));
      expect(rig.state.history.position, before + 1);
      expect(find.descendant(of: row('Opacity'), matching: find.text('40%')), findsOneWidget);

      final label = find.descendant(of: row('Opacity'), matching: find.text('Opacity'));
      await tester.tap(label);
      await tester.pump(const Duration(milliseconds: 60));
      await tester.tap(label);
      await tester.pumpAndSettle();
      expect(textA(rig).transform.opacity, 1);
      expect(rig.state.history.position, before + 2);
    });

    testWidgets('Position X edits x only', (tester) async {
      final rig = await pumpRows(tester);
      final gesture = await tester.startGesture(tester.getCenter(slider('Position X')));
      await gesture.moveBy(const Offset(30, 0));
      await tester.pump();
      await gesture.moveBy(const Offset(10, 0));
      await tester.pump();
      await gesture.up();
      await tester.pump();
      final p = textA(rig).transform.position;
      expect(p.x, greaterThan(0));
      expect(p.y, 0);
    });

    testWidgets('switches and choices apply one command each', (tester) async {
      final rig = await pumpRows(tester);
      final before = rig.state.history.position;
      await tester.ensureVisible(find.widgetWithText(InspectorToggleRow, 'Bold'));
      await tester.tap(find.widgetWithText(InspectorToggleRow, 'Bold'));
      await tester.pump();
      expect(textA(rig).style.bold, isTrue);
      await tester.ensureVisible(find.text('Right'));
      await tester.tap(find.text('Right'));
      await tester.pump();
      expect(textA(rig).style.align, TextAlignH.right);
      expect(rig.state.history.position, before + 2);
    });

    testWidgets('a colour gesture in the picker sheet is one entry', (tester) async {
      final rig = await pumpRows(tester);
      final before = rig.state.history.position;
      await tester.ensureVisible(find.byType(ColorField));
      await tester.tap(find.byType(ColorField));
      await tester.pumpAndSettle();
      expect(find.byType(VwishColorPicker), findsOneWidget);
      final picker = tester.widget<VwishColorPicker>(find.byType(VwishColorPicker));
      picker.onChangeStart!(picker.color);
      picker.onChanged(const Color(0xFFFF0000));
      await tester.pump();
      picker.onChanged(const Color(0xFF00FF00));
      await tester.pump();
      picker.onChangeEnd!(const Color(0xFF00FF00));
      await tester.pump();
      expect(textA(rig).style.color, 0xFF00FF00);
      expect(rig.state.history.position, before + 1);
      // The open sheet follows the edits.
      expect(tester.widget<VwishColorPicker>(find.byType(VwishColorPicker)).color, const Color(0xFF00FF00));
    });
  });

  testWidgets('a keyframed property shows its value at the playhead', (tester) async {
    final rig = await pumpRows(tester);
    final item = rig.items.textA;
    rig.editor.apply(AddKeyframe(KeyframeRef(item, 'transform.opacity', 0), value: 1.0));
    rig.editor.apply(AddKeyframe(KeyframeRef(item, 'transform.opacity', f(60)), value: 0.0));
    await rig.seek(f(30));
    expect(find.descendant(of: row('Opacity'), matching: find.text('50%')), findsOneWidget);
    await rig.seek(f(45));
    expect(find.descendant(of: row('Opacity'), matching: find.text('25%')), findsOneWidget);
    final toggle = tester.widget<KeyframeToggle>(find.descendant(of: row('Opacity'), matching: find.byType(KeyframeToggle)));
    expect(toggle.status.state, KeyframeToggleState.animated);
  });

  group('matrix (ARCH §17.9)', () {
    testSurfaces('rows fit the dock and the side pane', (tester, surface) async {
      await InspectorRig.pumpWith(
        tester,
        (items) => RegionFrame(
          inspectorOpen: true,
          regions: {EditorRegion.pane: rowsSheet(items)},
          dock: SizedBox(height: 320, child: rowsSheet(items)),
        ),
        surface: surface,
      );
      expectNoOverflow(tester);
      expectOwnerUiRules(tester);
    });
  });
}
