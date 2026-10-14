// OWNER: UX-28
//
// The Chroma key panel (ux.md §10.10, §7.5) with the fake engine: the enable switch, the Green / Blue
// chips and the numeric rows dispatching `SetChroma` / `SetProperty` as one labelled entry each, the
// eyedropper flow (UX-23's overlay samples the clip, the key previews live, release commits one
// entry, cancel restores, the playhead moves into the clip first), the matte preview
// (`setEditingMode(MatteMode(item))` on and off, paused during a pick, off with keying and on close),
// the header's reset, and the matrix.

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_editor/src/editor/contracts/inspector_routes.dart';
import 'package:danaview_editor/src/editor/inspector/inspector_header.dart';
import 'package:danaview_editor/src/editor/inspector/inspector_rows.dart';
import 'package:danaview_editor/src/editor/panels/chroma_panel.dart';
import 'package:danaview_editor/src/editor/preview/crop_overlay.dart';
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_editor_engine_api/danaview_editor_engine_api.dart' show MatteMode, NormalPreviewMode;
import 'package:danaview_ui_kit/danaview_ui_kit.dart';

import 'overlay_rig.dart';

Future<OverlayRig> _pumpChroma(
  WidgetTester tester, {
  ChromaKey? chroma,
  ItemId item = Ov.p1,
  EditorSurface? surface,
}) async {
  final rig = await (surface == null
      ? OverlayRig.pump(tester, project: (repo) => overlayProject(repo, chroma: chroma))
      : OverlayRig.pump(tester, surface: surface, project: (repo) => overlayProject(repo, chroma: chroma)));
  await rig.media.seek(2 * s);
  await rig.open(ChromaInspector(item), select: item);
  return rig;
}

ChromaPanelState _panel(WidgetTester tester) => tester.state<ChromaPanelState>(find.byType(ChromaPanel));

Finder _slider(String label) =>
    find.descendant(of: find.widgetWithText(InspectorSliderRow, label), matching: find.byType(DanaviewSlider));

DanaviewSwitchRow _switch(WidgetTester tester, String key) =>
    tester.widget<DanaviewSwitchRow>(find.descendant(of: find.byKey(ValueKey<String>(key)), matching: find.byType(DanaviewSwitchRow)));

Future<void> _drag(WidgetTester tester, Finder target, double dx) async {
  await tester.ensureVisible(target);
  await tester.pump();
  final g = await tester.startGesture(tester.getCenter(target));
  for (var i = 0; i < 6; i++) {
    await g.moveBy(Offset(dx / 6, 0));
    await tester.pump();
  }
  await g.up();
  await tester.pump();
  await tester.pump();
}

void main() {
  group('controls', () {
    testWidgets('defaults: off, green, 40 / 10 / 30 %; the matte switch waits for keying', (tester) async {
      final rig = await _pumpChroma(tester);
      expect(_switch(tester, 'chroma.enabled').value, isFalse);
      expect(find.text('#00B140'), findsOneWidget);
      for (final (label, value) in [('Similarity', '40%'), ('Smoothness', '10%'), ('Spill reduction', '30%')]) {
        expect(find.descendant(of: find.widgetWithText(InspectorSliderRow, label), matching: find.text(value)), findsOneWidget, reason: label);
      }
      expect(_switch(tester, 'chroma.matte').onChanged, isNull);
      expect(find.text('Turn on chroma key to see the matte'), findsOneWidget);
      expect(rig.entries, 0);
    });

    testWidgets('the switch turns keying on as one labelled SetChroma entry', (tester) async {
      final rig = await _pumpChroma(tester);
      await rig.tapKey('chroma.enabled');
      expect(rig.chroma(Ov.p1).enabled, isTrue);
      expect(rig.undoLabel, 'Turn on chroma key');
      expect(rig.entries, 1);
      await rig.tapKey('chroma.enabled');
      expect(rig.chroma(Ov.p1).enabled, isFalse);
      expect(rig.undoLabel, 'Turn off chroma key');
    });

    testWidgets('the Blue and Green chips set the key colour and turn keying on', (tester) async {
      final rig = await _pumpChroma(tester);
      await rig.tapKey('chroma.preset.blue');
      expect(rig.chroma(Ov.p1), const ChromaKey(enabled: true, color: ChromaCommands.blue));
      expect(rig.undoLabel, 'Key colour blue');
      expect(find.text('#0047BB'), findsOneWidget);
      await rig.tapKey('chroma.preset.green');
      expect(rig.chroma(Ov.p1).color, ChromaCommands.green);
      expect(rig.undoLabel, 'Key colour green');
      expect(rig.entries, 2);
    });

    testWidgets('a similarity drag is one entry; smoothness and spill write their properties', (tester) async {
      final rig = await _pumpChroma(tester, chroma: const ChromaKey(enabled: true));
      await _drag(tester, _slider('Similarity'), 120);
      expect(rig.chroma(Ov.p1).similarity, greaterThan(0.4));
      expect(rig.undoLabel, 'Change similarity');
      expect(rig.entries, 1);
      await _drag(tester, _slider('Smoothness'), 80);
      expect(rig.chroma(Ov.p1).smoothness, greaterThan(0.1));
      await _drag(tester, _slider('Spill reduction'), -80);
      expect(rig.chroma(Ov.p1).spill, lessThan(0.3));
      expect(rig.entries, 3);
      expect(rig.chroma(Ov.p1).enabled, isTrue);
    });

    testWidgets('the header reset restores the defaults as one entry', (tester) async {
      final rig = await _pumpChroma(tester, chroma: const ChromaKey(enabled: true, color: ChromaCommands.blue, similarity: 0.7));
      await tester.tap(find.descendant(of: find.byType(InspectorHeader), matching: find.byTooltip('Reset')));
      await tester.pump();
      await tester.pump();
      expect(rig.chroma(Ov.p1), ChromaKey.off);
      expect(rig.undoLabel, 'Reset chroma key');
      expect(find.descendant(of: find.byType(InspectorHeader), matching: find.byTooltip('Reset')), findsNothing);
    });
  });

  group('eyedropper', () {
    testWidgets('a drag previews the sampled key live; release commits one entry "Pick key colour"', (tester) async {
      final rig = await _pumpChroma(tester);
      rig.preview.sampledColor = const Color(0xFF13AB37);
      await rig.tapKey('chroma.eyedropper');
      expect(rig.tools.value, isA<EyedropperPreviewTool>());
      expect(_panel(tester).picking, isTrue);
      final centre = rig.geometry.viewRect.center;
      final g = await tester.startGesture(rig.global(centre));
      for (var i = 0; i < 10; i++) {
        await g.moveBy(const Offset(1, 0.5));
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(rig.calls('preview.sampleColor'), greaterThan(0));
      final working = (rig.media.state.project!.index.item(Ov.p1) as MediaClip).visual!.chroma;
      expect(working.enabled, isTrue, reason: 'the key previews while dragging');
      expect(working.color, 0x13AB37);
      expect(find.text('#13AB37'), findsOneWidget);
      await g.up();
      await tester.pump();
      await tester.pump();
      await tester.pump();
      expect(rig.tools.value, isNull);
      expect(_panel(tester).picking, isFalse);
      expect(rig.chroma(Ov.p1), const ChromaKey(enabled: true, color: 0x13AB37));
      expect(rig.undoLabel, 'Pick key colour');
      expect(rig.entries, 1);
    });

    testWidgets('a tap without dragging samples once and commits; Cancel changes nothing', (tester) async {
      final rig = await _pumpChroma(tester);
      rig.preview.sampledColor = const Color(0xFF0000FF);
      await rig.tapKey('chroma.eyedropper');
      await tester.tap(find.byKey(const ValueKey<String>('eyedropper.cancel')));
      await tester.pump();
      await tester.pump();
      expect(rig.chroma(Ov.p1), ChromaKey.off);
      expect(rig.entries, 0);
      expect(rig.tools.value, isNull);
      await rig.tapKey('chroma.eyedropper');
      await tester.tapAt(rig.global(rig.geometry.viewRect.center));
      await tester.pump();
      await tester.pump();
      await tester.pump();
      expect(rig.chroma(Ov.p1).color, 0x0000FF);
      expect(rig.entries, 1);
    });

    testWidgets('with the playhead outside the clip the pick first moves it to the clip', (tester) async {
      final rig = await _pumpChroma(tester);
      await rig.media.seek(8 * s);
      await rig.tapKey('chroma.eyedropper');
      expect(rig.media.playhead.value, 1 * s);
      expect(find.text('Moved to the clip so you can pick its colour'), findsOneWidget);
      rig.tools.cancelPick();
      await tester.pump(const Duration(seconds: 5));
    });
  });

  group('matte preview', () {
    testWidgets('Show matte sends MatteMode(item); off, keying off and closing send normal', (tester) async {
      final rig = await _pumpChroma(tester, chroma: const ChromaKey(enabled: true));
      expect(rig.preview.mode, isA<NormalPreviewMode>());
      await rig.tapKey('chroma.matte');
      expect(_panel(tester).matte, isTrue);
      expect(rig.preview.mode, isA<MatteMode>().having((m) => m.item, 'item', Ov.p1));
      await rig.tapKey('chroma.matte');
      expect(rig.preview.mode, isA<NormalPreviewMode>());
      // Keying off turns the matte off.
      await rig.tapKey('chroma.matte');
      expect(rig.preview.mode, isA<MatteMode>());
      await rig.tapKey('chroma.enabled');
      await tester.pump();
      expect(_panel(tester).matte, isFalse);
      expect(rig.preview.mode, isA<NormalPreviewMode>());
      // Closing the panel turns it off.
      await rig.tapKey('chroma.enabled');
      await rig.tapKey('chroma.matte');
      expect(rig.preview.mode, isA<MatteMode>());
      rig.media.editor.closeInspector();
      await tester.pump();
      await tester.pump();
      expect(rig.preview.mode, isA<NormalPreviewMode>());
    });

    testWidgets('the matte pauses while the eyedropper picks and comes back after', (tester) async {
      final rig = await _pumpChroma(tester, chroma: const ChromaKey(enabled: true));
      await rig.tapKey('chroma.matte');
      expect(rig.preview.mode, isA<MatteMode>());
      await rig.tapKey('chroma.eyedropper');
      expect(rig.preview.mode, isA<NormalPreviewMode>());
      expect(_switch(tester, 'chroma.matte').onChanged, isNull, reason: 'locked during the pick');
      rig.tools.cancelPick();
      await tester.pump();
      await tester.pump();
      expect(rig.preview.mode, isA<MatteMode>());
      expect(_panel(tester).matte, isTrue);
    });

    testWidgets('re-targeting to an unkeyed clip turns the matte off', (tester) async {
      final rig = await _pumpChroma(tester, chroma: const ChromaKey(enabled: true));
      await rig.tapKey('chroma.matte');
      rig.media.editor.select(Ov.p2);
      await tester.pump();
      await tester.pump();
      await tester.pump();
      expect(rig.media.state.inspector, const ChromaInspector(Ov.p2));
      expect(_panel(tester).matte, isFalse);
      expect(rig.preview.mode, isA<NormalPreviewMode>());
    });
  });

  group('matrix (ARCH §17.9)', () {
    testSurfaces('the chroma panel fits, off and keyed with the matte on', (tester, surface) async {
      final rig = await _pumpChroma(tester, surface: surface);
      expectNoOverflow(tester);
      expectOwnerUiRules(tester);
      await rig.tapKey('chroma.enabled');
      await rig.tapKey('chroma.matte');
      expectNoOverflow(tester);
      expectOwnerUiRules(tester);
      rig.media.editor.closeInspector();
      await tester.pump();
    });
  });
}
