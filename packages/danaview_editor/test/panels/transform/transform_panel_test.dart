// OWNER: UX-23
//
// The Transform panel (ux.md §10.2): rows from the metadata with keyframe toggles, each control
// dispatching the right core command (SetProperty for the rows, flips and fit; ResetTransform), one
// labelled history entry per gesture, keyframe-aware writes, the header's reset and keyframe-all,
// text items, locked lanes and the surface matrix.

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_editor/src/editor/contracts/inspector_routes.dart';
import 'package:danaview_editor/src/editor/inspector/inspector_header.dart';
import 'package:danaview_editor/src/editor/inspector/inspector_rows.dart';
import 'package:danaview_editor/src/editor/inspector/keyframe_toggle.dart';
import 'package:danaview_editor/src/editor/panels/transform_panel.dart';
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_ui_kit/danaview_ui_kit.dart';

import '../../support/support.dart';
import 'transform_rig.dart';

Finder row(String label) => find.widgetWithText(InspectorSliderRow, label);

Finder slider(String label) => find.descendant(of: row(label), matching: find.byType(DanaviewSlider));

Future<TransformRig> pumpTransform(
  WidgetTester tester, {
  EditorSurface surface = wideSurface,
  ItemId item = Ids.a,
  EditProject Function(FakeProjectRepository repo)? project,
}) async {
  final rig = await TransformRig.pump(tester, surface: surface, project: project);
  await rig.open(item, TransformInspector.new);
  return rig;
}

Future<void> drag(WidgetTester tester, String label, double dx) async {
  await tester.ensureVisible(slider(label));
  await tester.pump();
  final g = await tester.startGesture(tester.getCenter(slider(label)));
  for (var i = 0; i < 6; i++) {
    await g.moveBy(Offset(dx / 6, 0));
    await tester.pump();
  }
  await g.up();
  await tester.pump();
  await tester.pump();
}

Future<void> tapKey(WidgetTester tester, String key) async {
  final target = find.byKey(ValueKey<String>(key));
  await tester.ensureVisible(target);
  await tester.pump();
  await tester.tap(target);
  await tester.pump();
  await tester.pump();
}

EditProject Function(FakeProjectRepository) withProject({Map<ItemId, VisualProps> visuals = const {}, Map<ItemId, KeyframeSet> keys = const {}, bool lockMain = false}) =>
    (repo) => transformProject(repo, visuals: visuals, keys: keys, lockMain: lockMain);

void main() {
  group('rows (ux.md §10.2)', () {
    testWidgets('position, scale, rotation and opacity rows come from the metadata with keyframe toggles', (tester) async {
      await pumpTransform(tester);
      final rows = {for (final r in tester.widgetList<InspectorSliderRow>(find.byType(InspectorSliderRow))) r.label: r};
      expect(rows.keys, containsAll(['Position X', 'Position Y', 'Scale', 'Rotation', 'Opacity']));
      expect((rows['Position X']!.min, rows['Position X']!.max, rows['Position X']!.displayScale), (-2, 2, 100));
      expect((rows['Scale']!.min, rows['Scale']!.max, rows['Scale']!.defaultValue), (0.01, 8, 1));
      expect((rows['Rotation']!.min, rows['Rotation']!.max, rows['Rotation']!.unit), (-360, 360, '°'));
      expect((rows['Opacity']!.min, rows['Opacity']!.max, rows['Opacity']!.defaultValue), (0, 1, 1));
      for (final label in ['Scale', 'Rotation', 'Opacity', 'Position X']) {
        expect(find.descendant(of: row(label), matching: find.byType(PropertyKeyframeToggle)), findsOneWidget, reason: label);
      }
      expect(find.byType(FlipRow), findsOneWidget);
      expect(find.widgetWithText(InspectorChoiceRow<Object?>, 'Fit').first, findsOneWidget);
      expect(find.byKey(const ValueKey<String>('transform.crop')), findsOneWidget);
      expect(find.byKey(const ValueKey<String>('transform.reset')), findsOneWidget);
      expect(find.descendant(of: find.byType(InspectorHeader), matching: find.text('Transform')), findsOneWidget);
    });

    testWidgets('a text item shows no flips, fit or crop', (tester) async {
      await pumpTransform(tester, item: Ids.text);
      expect(row('Scale'), findsOneWidget);
      expect(find.byType(FlipRow), findsNothing);
      expect(find.widgetWithText(InspectorChoiceRow<Object?>, 'Fit'), findsNothing);
      expect(find.byKey(const ValueKey<String>('transform.crop')), findsNothing);
    });
  });

  group('commands', () {
    testWidgets('a scale drag is one SetProperty entry; the value follows', (tester) async {
      final rig = await pumpTransform(tester);
      final before = rig.entries;
      await drag(tester, 'Scale', 120);
      expect(rig.entries, before + 1);
      expect(rig.undoLabel, 'Change scale');
      expect(rig.visual(Ids.a).transform.scale, greaterThan(1));
    });

    testWidgets('rotation and opacity drags write their properties', (tester) async {
      final rig = await pumpTransform(tester);
      await drag(tester, 'Rotation', 80);
      expect(rig.visual(Ids.a).transform.rotationDeg, isNot(0));
      expect(rig.undoLabel, 'Change rotation');
      await drag(tester, 'Opacity', -200);
      expect(rig.visual(Ids.a).transform.opacity, lessThan(1));
      expect(rig.undoLabel, 'Change opacity');
    });

    testWidgets('position X drag moves the item horizontally only', (tester) async {
      final rig = await pumpTransform(tester);
      await drag(tester, 'Position X', 60);
      final p = rig.visual(Ids.a).transform.position;
      expect(p.x, isNot(0));
      expect(p.y, 0);
      expect(rig.undoLabel, 'Change position');
    });

    testWidgets('flip buttons toggle flipH and flipV, one labelled entry each', (tester) async {
      final rig = await pumpTransform(tester);
      final before = rig.entries;
      await tapKey(tester, 'transform.flipH');
      expect(rig.visual(Ids.a).transform.flipH, isTrue);
      expect(rig.undoLabel, 'Flip horizontally');
      await tapKey(tester, 'transform.flipV');
      expect(rig.visual(Ids.a).transform.flipV, isTrue);
      expect(rig.undoLabel, 'Flip vertically');
      await tapKey(tester, 'transform.flipH');
      expect(rig.visual(Ids.a).transform.flipH, isFalse);
      expect(rig.entries, before + 3);
    });

    testWidgets('fit segments set the fit mode', (tester) async {
      final rig = await pumpTransform(tester);
      final fill = find.descendant(of: find.widgetWithText(InspectorChoiceRow<Object?>, 'Fit').first, matching: find.text('Fill'));
      await tester.ensureVisible(fill);
      await tester.pump();
      await tester.tap(fill);
      await tester.pump();
      expect(rig.visual(Ids.a).fit, FitMode.fill);
      final stretch = find.descendant(of: find.widgetWithText(InspectorChoiceRow<Object?>, 'Fit').first, matching: find.text('Stretch'));
      await tester.tap(stretch);
      await tester.pump();
      expect(rig.visual(Ids.a).fit, FitMode.stretch);
    });

    testWidgets('Crop opens the crop panel on the item', (tester) async {
      final rig = await pumpTransform(tester);
      await tapKey(tester, 'transform.crop');
      expect(rig.state.inspector, const CropInspector(Ids.a));
    });

    testWidgets('Reset transform runs ResetTransform: identity and keys cleared, one entry', (tester) async {
      final rig = await pumpTransform(
        tester,
        project: withProject(
          visuals: {Ids.a: const VisualProps(transform: Transform2D(position: Vec2(0.2, 0.1), scale: 2, rotationDeg: 30, flipH: true, opacity: 0.5))},
          keys: {
            Ids.a: KeyframeSet({
              'transform.scale': KeyframeTrack([Keyframe(f(0), 1.0), Keyframe(f(30), 2.0)]),
            }),
          },
        ),
      );
      final before = rig.entries;
      await tapKey(tester, 'transform.reset');
      expect(rig.visual(Ids.a).transform, Transform2D.identity);
      expect(KeyframeOps.isAnimated(keyframesOf(rig.item(Ids.a)), PropertyKeys.scale), isFalse);
      expect(rig.entries, before + 1);
      expect(rig.undoLabel, 'Reset transform');
    });

    testWidgets('a keyed property gets a key at the playhead instead of a static change', (tester) async {
      final rig = await pumpTransform(
        tester,
        project: withProject(keys: {
          Ids.a: KeyframeSet({
            'transform.rotation': KeyframeTrack([Keyframe(f(0), 0.0), Keyframe(f(60), 45.0)]),
          }),
        }),
      );
      await rig.seek(f(30));
      await drag(tester, 'Rotation', 60);
      final keys = keyframesOf(rig.item(Ids.a));
      expect(KeyframeOps.hasKeyAt(keys, PropertyKeys.rotation, f(30)), isTrue);
      expect(rig.visual(Ids.a).transform.rotationDeg, 0, reason: 'the static value stays');
    });
  });

  group('header', () {
    testWidgets('keyframe-all keys position, scale, rotation and opacity at the playhead, then removes them', (tester) async {
      final rig = await pumpTransform(tester);
      await rig.seek(f(15));
      final slot = tester.widget<InspectorHeader>(find.byType(InspectorHeader));
      expect(slot, isNotNull);
      final toggle = find.descendant(of: find.byType(InspectorHeader), matching: find.byType(KeyframeToggle));
      expect(toggle, findsOneWidget);
      await tester.tap(toggle);
      await tester.pump();
      await tester.pump();
      final keys = keyframesOf(rig.item(Ids.a));
      for (final k in TransformRows.keyframable) {
        expect(KeyframeOps.hasKeyAt(keys, k, f(15)), isTrue, reason: k.id);
      }
      expect(rig.undoLabel, 'Keyframe all');
      await tester.tap(toggle);
      await tester.pump();
      await tester.pump();
      for (final k in TransformRows.keyframable) {
        expect(KeyframeOps.isAnimated(keyframesOf(rig.item(Ids.a)), k), isFalse, reason: k.id);
      }
      expect(rig.undoLabel, 'Remove keyframes');
    });

    test('keyframeAll and aggregateStatus skip rows that do not apply', () {
      const text = TextItem(id: Ids.text, start: 0, duration: 3 * s, text: 'T');
      final status = TransformCommands.aggregateStatus(text, TransformRows.keyframable, 0);
      expect(status.state, KeyframeToggleState.none);
      expect(status.enabled, isTrue);
    });
  });

  group('locked lanes', () {
    testWidgets('a locked track says so and disables the buttons', (tester) async {
      await pumpTransform(tester, project: withProject(lockMain: true));
      expect(find.text('This track is locked'), findsOneWidget);
      final reset = tester.widget<DanaviewButton>(find.byKey(const ValueKey<String>('transform.reset')));
      expect(reset.onPressed, isNull);
    });
  });

  group('matrix (ARCH §17.9)', () {
    testSurfaces('the panel fits on every surface', (tester, surface) async {
      final rig = await TransformRig.pump(tester, surface: surface);
      await rig.open(Ids.a, TransformInspector.new);
      expectNoOverflow(tester);
      expectOwnerUiRules(tester);
      final reset = find.byKey(const ValueKey<String>('transform.reset'));
      await tester.ensureVisible(reset);
      await tester.pump();
      expectNoOverflow(tester);
      expectInside(tester, reset);
    });
  });
}
