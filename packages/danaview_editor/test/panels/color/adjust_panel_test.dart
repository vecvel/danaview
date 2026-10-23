// OWNER: UX-24
//
// The Adjust panel (ux.md §10.6): sections and rows from the CORE-05 metadata, history contract of
// the rows, keyframe toggles, the before/after hold (a transaction that neutralizes adjust, detail and
// look and never reaches history), apply to all clips and reset all (one history entry each), the
// header's reset and keyframe-all, locked lanes, re-targeting and the surface matrix.

import 'dart:ui' show Tristate;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_editor/src/app/editor_providers.dart';
import 'package:danaview_editor/src/app/strings/color_strings.dart';
import 'package:danaview_editor/src/editor/contracts/inspector_routes.dart';
import 'package:danaview_editor/src/editor/inspector/inspector_header.dart';
import 'package:danaview_editor/src/editor/inspector/inspector_rows.dart';
import 'package:danaview_editor/src/editor/inspector/keyframe_toggle.dart';
import 'package:danaview_editor/src/editor/panels/adjust_panel.dart';
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_editor_core/ops.dart' show AddKeyframe, SetProperty;
import 'package:danaview_ui_kit/danaview_ui_kit.dart';

import '../../support/support.dart';
import 'color_rig.dart';

Finder row(String label) => find.widgetWithText(InspectorSliderRow, label);

Finder slider(String label) => find.descendant(of: row(label), matching: find.byType(DanaviewSlider));

Finder valueText(String label, String text) => find.descendant(of: row(label), matching: find.text(text));

Finder get compare => find.byKey(const ValueKey<String>('adjust.compare'));

Finder get applyAll => find.byKey(const ValueKey<String>('adjust.applyAll'));

Finder get resetAll => find.byKey(const ValueKey<String>('adjust.resetAll'));

Future<ColorRig> pumpAdjust(
  WidgetTester tester, {
  EditorSurface surface = wideSurface,
  ItemId item = ColorIds.a,
  EditProject Function(FakeProjectRepository repo)? project,
}) async {
  final rig = await ColorRig.pump(tester, inspectorFrame, surface: surface, project: project);
  await rig.select(item);
  rig.editor.openInspector(AdjustInspector(item));
  await tester.pump();
  await tester.pump();
  return rig;
}

/// Scrolls the panel until [target] is built and on screen (the list builds lazily).
Future<void> reveal(WidgetTester tester, Finder target) async {
  await tester.scrollUntilVisible(target, 200, scrollable: find.descendant(of: find.byType(CustomScrollView), matching: find.byType(Scrollable)).first);
  await tester.pump();
}

Future<void> section(WidgetTester tester, String label) async {
  final target = find.descendant(of: find.byType(DanaviewSegmentedControl<AdjustSection>), matching: find.text(label));
  await tester.ensureVisible(target);
  await tester.pump();
  await tester.tap(target);
  await tester.pump();
}

/// Drags the slider of [label] by [dx] with several moves.
Future<void> drag(WidgetTester tester, String label, double dx) async {
  final g = await tester.startGesture(tester.getCenter(slider(label)));
  for (var i = 0; i < 6; i++) {
    await g.moveBy(Offset(dx / 6, 0));
    await tester.pump();
  }
  await g.up();
  await tester.pump();
  await tester.pump();
}

EditProject Function(FakeProjectRepository) withVisuals(Map<ItemId, VisualProps> visuals, {KeyframeSet? keysOfA}) =>
    (repo) => colorProject(repo, visuals: visuals, keysOfA: keysOfA);

void main() {
  group('sections and rows (ux.md §10.6)', () {
    testWidgets('Light, Color and Detail list the rows of the spec with the metadata ranges', (tester) async {
      await pumpAdjust(tester);
      List<String> labels() => tester.widgetList<InspectorSliderRow>(find.byType(InspectorSliderRow)).map((r) => r.label).toList();
      expect(labels(), ['Exposure', 'Brightness', 'Contrast', 'Highlights', 'Shadows']);
      for (final r in tester.widgetList<InspectorSliderRow>(find.byType(InspectorSliderRow))) {
        expect((r.min, r.max, r.defaultValue, r.displayScale), (-1, 1, 0, 100), reason: r.label);
        expect(find.descendant(of: find.widgetWithText(InspectorSliderRow, r.label), matching: find.byType(PropertyKeyframeToggle)), findsOneWidget);
      }
      await section(tester, 'Color');
      expect(labels(), ['Saturation', 'Temperature', 'Tint']);
      for (final r in tester.widgetList<InspectorSliderRow>(find.byType(InspectorSliderRow))) {
        expect((r.min, r.max, r.defaultValue), (-1, 1, 0), reason: r.label);
      }
      await section(tester, 'Detail');
      expect(labels(), ['Sharpness', 'Blur', 'Vignette', 'Opacity']);
      final byLabel = {for (final r in tester.widgetList<InspectorSliderRow>(find.byType(InspectorSliderRow))) r.label: r};
      expect((byLabel['Sharpness']!.min, byLabel['Sharpness']!.max, byLabel['Sharpness']!.defaultValue), (0, 1, 0));
      expect((byLabel['Opacity']!.min, byLabel['Opacity']!.max, byLabel['Opacity']!.defaultValue), (0, 1, 1));
      expect(valueText('Opacity', '100%'), findsOneWidget);
    });

    testWidgets('the rows show the clip\'s values and the title is Adjust', (tester) async {
      await pumpAdjust(
        tester,
        project: withVisuals({
          ColorIds.a: const VisualProps(adjust: ColorAdjust(exposure: 0.25, contrast: -0.4), detail: DetailFx(vignette: 0.6)),
        }),
      );
      expect(find.descendant(of: find.byType(InspectorHeader), matching: find.text('Adjust')), findsOneWidget);
      expect(valueText('Exposure', '25%'), findsOneWidget);
      expect(valueText('Contrast', '-40%'), findsOneWidget);
      expect(valueText('Brightness', '0%'), findsOneWidget);
      await section(tester, 'Detail');
      expect(valueText('Vignette', '60%'), findsOneWidget);
    });
  });

  group('rows write through SetProperty', () {
    testWidgets('a drag is one history entry labelled Change exposure; undo restores', (tester) async {
      final rig = await pumpAdjust(tester);
      await drag(tester, 'Exposure', 60);
      expect(rig.visual(ColorIds.a).adjust.exposure, greaterThan(0));
      expect(rig.entries, 1);
      expect(rig.undoLabel, 'Change exposure');
      rig.editor.undo();
      await tester.pump();
      expect(rig.visual(ColorIds.a).adjust.exposure, 0);
    });

    testWidgets('a typed value and a double-tap reset are one command each', (tester) async {
      final rig = await pumpAdjust(tester);
      await tester.tap(valueText('Contrast', '0%'));
      await tester.pump();
      final field = find.descendant(of: row('Contrast'), matching: find.byType(EditableText));
      await tester.enterText(field, '40');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect(rig.visual(ColorIds.a).adjust.contrast, closeTo(0.4, 1e-9));
      expect(rig.entries, 1);
      final label = find.descendant(of: row('Contrast'), matching: find.text('Contrast'));
      await tester.tap(label);
      await tester.pump(const Duration(milliseconds: 60));
      await tester.tap(label);
      await tester.pumpAndSettle();
      expect(rig.visual(ColorIds.a).adjust.contrast, 0);
      expect(rig.entries, 2);
    });

    testWidgets('each section edits its own struct: color, detail and the opacity mirror', (tester) async {
      final rig = await pumpAdjust(tester);
      await section(tester, 'Color');
      await drag(tester, 'Saturation', -50);
      expect(rig.visual(ColorIds.a).adjust.saturation, lessThan(0));
      await section(tester, 'Detail');
      await drag(tester, 'Blur', 40);
      expect(rig.visual(ColorIds.a).detail.blur, greaterThan(0));
      // The mirror edits Transform's own opacity property.
      await drag(tester, 'Opacity', -40);
      expect(rig.visual(ColorIds.a).transform.opacity, lessThan(1));
      expect(rig.entries, 3);
    });

    testWidgets('a keyframe toggle adds a key at the playhead; the row then follows the playhead', (tester) async {
      final rig = await pumpAdjust(tester);
      await rig.seek(f(30));
      await tester.tap(find.descendant(of: row('Exposure'), matching: find.byType(KeyframeToggle)));
      await tester.pump();
      final clip = rig.item(ColorIds.a) as MediaClip;
      expect(KeyframeOps.hasKeyAt(clip.keyframes, PropertyKeys.exposure, f(30)), isTrue);
      expect(rig.entries, 1);
      // With a key, a drag writes a key at the playhead instead of the static value.
      await drag(tester, 'Exposure', 60);
      final after = rig.item(ColorIds.a) as MediaClip;
      expect(after.visual!.adjust.exposure, 0);
      expect(KeyframeOps.keyTimes(after.keyframes, PropertyKeys.exposure), [f(30)]);
      expect(rig.entries, 2);
    });
  });

  group('before / after', () {
    final graded = VisualProps(
      adjust: const ColorAdjust(exposure: 0.3, saturation: -0.2),
      detail: const DetailFx(blur: 0.4),
      look: const BuiltinLook('warm', intensity: 0.8),
      transform: const Transform2D(opacity: 0.9),
    );

    testWidgets('holding the button shows the original in a transaction; releasing cancels it', (tester) async {
      final rig = await pumpAdjust(
        tester,
        project: withVisuals({ColorIds.a: graded}, keysOfA: keysAt({'adjust.contrast': [0, 60]}, v: 0.5)),
      );
      final before = rig.project;
      final transients = rig.engine.log.calls.where((c) => c == 'preview.setTransient').length;
      final g = await tester.startGesture(tester.getCenter(compare));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 40));
      expect(rig.state.inTransaction, isTrue);
      final working = rig.container.read(editorSessionProvider(rig.id)).project!;
      final clip = working.index.item(ColorIds.a)! as MediaClip;
      expect(clip.visual!.adjust, ColorAdjust.neutral);
      expect(clip.visual!.detail, DetailFx.none);
      expect(clip.visual!.look, isNull);
      expect(clip.visual!.transform.opacity, 0.9, reason: 'opacity is placement, not an adjustment');
      expect(KeyframeOps.isAnimated(clip.keyframes, PropertyKeys.contrast), isFalse, reason: 'keyed adjustments are neutral too');
      expect(rig.engine.log.calls.where((c) => c == 'preview.setTransient').length, greaterThan(transients),
          reason: 'the preview shows it through a transient');
      expect(tester.widget<CompareButton>(find.byType(CompareButton)).active, isTrue);
      await g.up();
      await tester.pump();
      await tester.pump();
      expect(rig.state.inTransaction, isFalse);
      expect(rig.project, before);
      expect(rig.visual(ColorIds.a), graded);
      expect(rig.entries, 0, reason: 'the comparison never reaches history');
      expect(tester.widget<CompareButton>(find.byType(CompareButton)).active, isFalse);
    });

    testWidgets('the active compare button keeps the neutral hairline; only its icon turns primary', (tester) async {
      await pumpAdjust(tester, project: withVisuals({ColorIds.a: graded}));
      BoxDecoration deco() => tester.widget<Container>(compare).decoration! as BoxDecoration;
      expect(deco().border, const Border.fromBorderSide(DanaviewBorders.hairline));
      final g = await tester.startGesture(tester.getCenter(compare));
      await tester.pump();
      expect(tester.widget<CompareButton>(find.byType(CompareButton)).active, isTrue);
      expect(deco().border, const Border.fromBorderSide(DanaviewBorders.hairline), reason: 'no primary outline when active');
      expect(tester.widget<Icon>(find.descendant(of: compare, matching: find.byType(Icon))).color, DanaviewColors.primaryLight);
      expectNeutralBorders(tester, of: compare);
      await g.up();
      await tester.pump();
    });

    testWidgets('a cancelled press also restores', (tester) async {
      final rig = await pumpAdjust(tester, project: withVisuals({ColorIds.a: graded}));
      final g = await tester.startGesture(tester.getCenter(compare));
      await tester.pump();
      expect(rig.state.inTransaction, isTrue);
      await g.cancel();
      await tester.pump();
      expect(rig.state.inTransaction, isFalse);
      expect(rig.visual(ColorIds.a), graded);
    });

    testWidgets('assistive technology toggles the original on and off', (tester) async {
      final rig = await pumpAdjust(tester, project: withVisuals({ColorIds.a: graded}));
      final handle = tester.ensureSemantics();
      final node = find.semantics.byLabel(ColorStrings.compare);
      expect(node, findsOneWidget);
      tester.semantics.tap(node);
      await tester.pump();
      expect(rig.state.inTransaction, isTrue);
      expect(node.evaluate().single.getSemanticsData().flagsCollection.isToggled, Tristate.isTrue);
      tester.semantics.tap(node);
      await tester.pump();
      expect(rig.state.inTransaction, isFalse);
      expect(rig.visual(ColorIds.a), graded);
      handle.dispose();
    });

    testWidgets('editing while the original shows ends the comparison', (tester) async {
      final rig = await pumpAdjust(tester, project: withVisuals({ColorIds.a: graded}));
      final g = await tester.startGesture(tester.getCenter(compare));
      await tester.pump();
      rig.editor.apply(SetProperty<double>([ColorIds.a], PropertyKeys.blur, 0.1));
      await tester.pump();
      await g.up();
      await tester.pump();
      expect(rig.state.inTransaction, isFalse);
      expect(rig.visual(ColorIds.a).detail.blur, 0.1);
      expect(rig.visual(ColorIds.a).adjust.exposure, 0.3);
    });
  });

  group('footer: apply to all clips and reset all', () {
    testWidgets('apply to all copies the values to the lane peers in one history entry', (tester) async {
      final rig = await pumpAdjust(
        tester,
        project: withVisuals({
          ColorIds.a: const VisualProps(
            adjust: ColorAdjust(exposure: 0.4, tint: -0.2),
            detail: DetailFx(vignette: 0.5),
            transform: Transform2D(opacity: 0.7),
            look: BuiltinLook('cool'),
          ),
          ColorIds.b: const VisualProps(adjust: ColorAdjust(contrast: 0.9), look: BuiltinLook('warm')),
          ColorIds.overlay: const VisualProps(adjust: ColorAdjust(shadows: 0.5)),
        }),
      );
      await reveal(tester, applyAll);
      await tester.tap(applyAll);
      await tester.pump();
      expect(rig.entries, 1);
      expect(rig.undoLabel, ColorStrings.historyApplyToAll);
      final source = rig.visual(ColorIds.a);
      for (final id in [ColorIds.b, ColorIds.c]) {
        final v = rig.visual(id);
        expect(v.adjust, source.adjust, reason: '$id');
        expect(v.detail, source.detail, reason: '$id');
        expect(v.transform.opacity, 0.7, reason: '$id');
      }
      expect(rig.visual(ColorIds.b).look, const BuiltinLook('warm'), reason: 'looks belong to the Filters panel');
      expect(rig.visual(ColorIds.overlay).adjust, const ColorAdjust(shadows: 0.5), reason: 'other lanes are untouched');
      expect(find.text(ColorStrings.appliedToClips(2)), findsOneWidget);
      rig.editor.undo();
      await tester.pump();
      expect(rig.visual(ColorIds.b).adjust, const ColorAdjust(contrast: 0.9));
      expect(rig.visual(ColorIds.c).adjust, ColorAdjust.neutral);
      expect(rig.entries, 0);
    });

    testWidgets('apply to all clears the keys of the rows on the peers and uses the value at the playhead', (tester) async {
      final rig = await pumpAdjust(
        tester,
        project: (repo) {
          final p = colorProject(repo);
          return p;
        },
      );
      // Key A's exposure: 0 at frame 0, 1.0 at frame 60; peers have a key on saturation.
      rig.editor
        ..apply(AddKeyframe(KeyframeRef(ColorIds.a, 'adjust.exposure', 0), value: 0.0))
        ..apply(AddKeyframe(KeyframeRef(ColorIds.a, 'adjust.exposure', f(60)), value: 1.0))
        ..apply(AddKeyframe(KeyframeRef(ColorIds.c, 'adjust.saturation', 0), value: 0.8))
        ..apply(AddKeyframe(KeyframeRef(ColorIds.c, 'adjust.saturation', f(30)), value: 0.2));
      await rig.seek(f(30));
      final entries = rig.entries;
      await reveal(tester, applyAll);
      await tester.tap(applyAll);
      await tester.pump();
      expect(rig.entries, entries + 1);
      final b = rig.visual(ColorIds.b);
      expect(b.adjust.exposure, closeTo(0.5, 1e-9), reason: 'the value of A at the playhead');
      final c = rig.item(ColorIds.c) as MediaClip;
      expect(KeyframeOps.isAnimated(c.keyframes, PropertyKeys.saturation), isFalse);
      expect(c.visual!.adjust.saturation, 0);
    });

    testWidgets('apply to all is disabled with a single clip on the lane and says why', (tester) async {
      await pumpAdjust(tester, item: ColorIds.overlay);
      await reveal(tester, applyAll);
      expect(tester.widget<DanaviewButton>(applyAll).onPressed, isNull);
      expect(find.text(ColorStrings.applyToAllSingle), findsOneWidget);
    });

    testWidgets('reset all returns the rows to neutral, clears their keys, keeps the look; one entry', (tester) async {
      final rig = await pumpAdjust(
        tester,
        project: withVisuals(
          {
            ColorIds.a: const VisualProps(
              adjust: ColorAdjust(exposure: 0.3, tint: 0.4),
              detail: DetailFx(sharpness: 0.2),
              transform: Transform2D(opacity: 0.5, rotationDeg: 10),
              look: BuiltinLook('mono'),
            ),
          },
          keysOfA: keysAt({'adjust.exposure': [0, 30], 'transform.rotation': [0, 30]}, v: 0.1),
        ),
      );
      await reveal(tester, resetAll);
      await tester.tap(resetAll);
      await tester.pump();
      expect(rig.entries, 1);
      expect(rig.undoLabel, ColorStrings.historyResetAll);
      final v = rig.visual(ColorIds.a);
      expect(v.adjust, ColorAdjust.neutral);
      expect(v.detail, DetailFx.none);
      expect(v.transform.opacity, 1);
      expect(v.transform.rotationDeg, 10, reason: 'placement is Transform\'s');
      expect(v.look, const BuiltinLook('mono'));
      final clip = rig.item(ColorIds.a) as MediaClip;
      expect(KeyframeOps.isAnimated(clip.keyframes, PropertyKeys.exposure), isFalse);
      expect(KeyframeOps.isAnimated(clip.keyframes, PropertyKeys.rotation), isTrue, reason: 'rotation is not a row here');
    });
  });

  group('header: reset and keyframe-all', () {
    testWidgets('reset asks first only when keyframes would go', (tester) async {
      final rig = await pumpAdjust(tester, project: withVisuals({ColorIds.a: const VisualProps(adjust: ColorAdjust(exposure: 0.3))}));
      await tester.tap(find.byTooltip(InspectorStrings.reset));
      await tester.pump();
      expect(find.text(InspectorStrings.resetTitle('Adjust')), findsNothing);
      expect(rig.visual(ColorIds.a).adjust, ColorAdjust.neutral);
    });

    testWidgets('with keyframes the reset confirms; cancel keeps everything, confirm resets', (tester) async {
      final rig = await pumpAdjust(
        tester,
        project: withVisuals({ColorIds.a: const VisualProps(adjust: ColorAdjust(exposure: 0.3))}, keysOfA: keysAt({'adjust.exposure': [0, 30]}, v: 0.3)),
      );
      await tester.tap(find.byTooltip(InspectorStrings.reset));
      await tester.pumpAndSettle();
      expect(find.text(InspectorStrings.resetTitle('Adjust')), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(rig.entries, 0);
      await tester.tap(find.byTooltip(InspectorStrings.reset));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(DanaviewButton, InspectorStrings.reset));
      await tester.pumpAndSettle();
      expect(rig.entries, 1);
      expect(KeyframeOps.isAnimated((rig.item(ColorIds.a) as MediaClip).keyframes, PropertyKeys.exposure), isFalse);
    });

    testWidgets('keyframe-all keys every row of the open section at the playhead, and again removes them', (tester) async {
      final rig = await pumpAdjust(tester);
      await rig.seek(f(30));
      final header = find.descendant(of: find.byType(InspectorHeader), matching: find.byType(KeyframeToggle));
      expect(header, findsOneWidget);
      expect(tester.widget<KeyframeToggle>(header).status.state, KeyframeToggleState.none);
      await tester.tap(header);
      await tester.pump();
      await tester.pump();
      expect(rig.entries, 1);
      final clip = rig.item(ColorIds.a) as MediaClip;
      for (final k in AdjustRows.light) {
        expect(KeyframeOps.hasKeyAt(clip.keyframes, k, f(30)), isTrue, reason: k.id);
      }
      for (final k in AdjustRows.color) {
        expect(KeyframeOps.isAnimated(clip.keyframes, k), isFalse, reason: k.id);
      }
      expect(tester.widget<KeyframeToggle>(header).status.state, KeyframeToggleState.atPlayhead);
      await tester.tap(header);
      await tester.pump();
      await tester.pump();
      expect(rig.entries, 2);
      for (final k in AdjustRows.light) {
        expect(KeyframeOps.isAnimated((rig.item(ColorIds.a) as MediaClip).keyframes, k), isFalse, reason: k.id);
      }
    });
  });

  group('context', () {
    testWidgets('a locked lane shows the reason and disables the footer and the compare button', (tester) async {
      await pumpAdjust(tester, project: (repo) => colorProject(repo, lockMain: true));
      expect(find.text(ColorStrings.trackLocked), findsOneWidget);
      await reveal(tester, resetAll);
      expect(tester.widget<DanaviewButton>(resetAll).onPressed, isNull);
      expect(tester.widget<DanaviewButton>(applyAll).onPressed, isNull);
      expect(tester.widget<CompareButton>(find.byType(CompareButton)).enabled, isFalse);
    });

    testWidgets('selecting another clip re-targets the panel and keeps the section', (tester) async {
      final rig = await pumpAdjust(
        tester,
        project: withVisuals({ColorIds.b: const VisualProps(adjust: ColorAdjust(saturation: 0.6))}),
      );
      await section(tester, 'Color');
      expect(valueText('Saturation', '0%'), findsOneWidget);
      await rig.select(ColorIds.b);
      expect(rig.state.inspector, AdjustInspector(ColorIds.b));
      expect(valueText('Saturation', '60%'), findsOneWidget);
    });

    testWidgets('the panel closes with the clip: nothing to adjust on a text item', (tester) async {
      final rig = await pumpAdjust(tester);
      await rig.select(ColorIds.text);
      await tester.pump();
      expect(rig.state.inspector, isNull);
    });
  });

  group('matrix (ARCH §17.9)', () {
    testSurfaces('every section fits, the compare button and the footer are reachable', (tester, surface) async {
      final rig = await ColorRig.pump(tester, inspectorFrame, surface: surface);
      await rig.select(ColorIds.a);
      rig.editor.openInspector(AdjustInspector(ColorIds.a));
      await tester.pump();
      await tester.pump();
      for (final label in ['Light', 'Color', 'Detail']) {
        await section(tester, label);
        expectNoOverflow(tester);
        expectOwnerUiRules(tester);
      }
      expect(find.byType(CompareButton), findsOneWidget);
      expectInside(tester, find.byType(CompareButton));
      expect(tester.getSize(find.byType(CompareButton)).shortestSide, greaterThanOrEqualTo(44));
      await reveal(tester, applyAll);
      await tester.pump();
      expectNoOverflow(tester);
      expectInside(tester, applyAll);
    });
  });
}
