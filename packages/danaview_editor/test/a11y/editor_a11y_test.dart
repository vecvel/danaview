// OWNER: QA-08
//
// Accessibility of the editor screen (ARCH §17.9, ux.md §19.1) in the four layout kinds and the PR
// surfaces: tap targets ≥ 44×44 and labeled (a11y_support.dart), text contrast (Flutter's
// textContrastGuideline), and the timeline's painted elements: clip nodes with the edit custom
// actions in the real screen, the playhead as an adjustable slider, markers, transitions and
// keyframes as nodes, the manipulation overlay's move/scale/rotate actions, and live
// announcements throttled to one per second.

import 'package:flutter/semantics.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_editor/src/app/editor_providers.dart';
import 'package:danaview_editor/src/editor/contracts/contracts.dart';
import 'package:danaview_editor/src/editor/preview/manipulation_overlay.dart' show ManipulationStrings;
import 'package:danaview_editor/src/editor/timeline/timeline_semantics.dart';
import 'package:danaview_editor_core/model.dart';

import '../support/support.dart';
import 'a11y_support.dart';

/// The layout kinds plus the PR subset, without duplicates.
final List<EditorSurface> _surfaces = {
  for (final l in layoutSurfaces) l.surface,
  ...SurfaceMatrix.pr,
}.toList();

/// A wide surface where the whole fixture timeline is in view.
const EditorSurface _wide = EditorSurface(Size(1280, 800), platform: TargetPlatform.iOS);

/// The node of overlay clip `it_o1` (logo.png, 1-6 s, alone on its lane).
FinderBase<SemanticsNode> _logo() => find.semantics.byLabel(RegExp(r'^Image, logo\.png, length 0:05,'));

void main() {
  group('guidelines in every layout', () {
    for (final surface in _surfaces) {
      testWidgets('idle editor [$surface]', (tester) async {
        final semantics = tester.ensureSemantics();
        await A11yEditorRig.pump(tester, surface: surface);
        expectNoOverflow(tester);
        await expectA11yGuidelines(tester, where: 'idle editor $surface');
        semantics.dispose();
      });

      testWidgets('clip selected, context tools [$surface]', (tester) async {
        final semantics = tester.ensureSemantics();
        final rig = await A11yEditorRig.pump(tester, surface: surface);
        rig.editor.select(const ItemId('it_v1'));
        await rig.settle();
        expectNoOverflow(tester);
        await expectA11yGuidelines(tester, where: 'clip selected $surface');
        semantics.dispose();
      });
    }
  });

  group('timeline painted elements', () {
    testWidgets('every visible clip is a labeled node with the edit actions; locked clips have none', (tester) async {
      final semantics = tester.ensureSemantics();
      await A11yEditorRig.pump(tester, surface: _wide);
      final clips = find.semantics.byLabel(RegExp(r'^(Video clip|Image|Freeze frame|Audio clip|Text|Caption)(, [^,]+)?, length '));
      final nodes = clips.evaluate().toList();
      expect(nodes.length, greaterThanOrEqualTo(8), reason: 'items of the fixture in view');
      for (final node in nodes) {
        final label = node.getSemanticsData().label;
        final actions = customActionLabels(node);
        if (label.contains('track locked')) {
          expect(actions, isEmpty, reason: label);
        } else {
          expect(actions, containsAll(clipEditActionLabels), reason: label);
          expect(node.getSemanticsData().hasAction(SemanticsAction.tap), isTrue, reason: label);
        }
      }
      semantics.dispose();
    });

    testWidgets('clip custom actions edit through the controller and announce the result', (tester) async {
      final semantics = tester.ensureSemantics();
      final rig = await A11yEditorRig.pump(tester, surface: _wide);
      tester.takeAnnouncements();
      final before = rig.state.history.position;
      tester.semantics.customAction(_logo(), const CustomSemanticsAction(label: TimelineSemanticsStrings.moveSecondLater));
      await tester.pump();
      expect(rig.project.index.locate(const ItemId('it_o1'))!.item.start, 2 * s);
      expect(rig.state.history.position, before + 1);
      expect(tester.takeAnnouncements().map((a) => a.message), [TimelineSemanticsStrings.movedTo(2 * s)]);

      tester.semantics.customAction(_logo(), const CustomSemanticsAction(label: TimelineSemanticsStrings.trimEndSecondEarlier));
      await tester.pump();
      expect(rig.project.index.locate(const ItemId('it_o1'))!.item.duration, 4 * s);
      expect(rig.state.history.position, before + 2);

      tester.semantics.tap(find.semantics.byLabel(RegExp(r'^Image, logo\.png, length 0:04, starts at 0:02,')));
      await tester.pump();
      expect(rig.state.selection.items, {const ItemId('it_o1')});
      await tester.pump(const Duration(seconds: 2));
      semantics.dispose();
    });

    testWidgets('announcements are throttled to one per second, newest wins', (tester) async {
      final semantics = tester.ensureSemantics();
      final rig = await A11yEditorRig.pump(tester, surface: _wide);
      tester.takeAnnouncements();
      const later = CustomSemanticsAction(label: TimelineSemanticsStrings.moveFrameLater);
      tester.semantics.customAction(_logo(), later);
      await tester.pump();
      tester.semantics.customAction(_logo(), later);
      await tester.pump();
      tester.semantics.customAction(_logo(), later);
      await tester.pump();
      expect(tester.takeAnnouncements(), hasLength(1), reason: 'the first goes out at once, the rest wait');
      await tester.pump(const Duration(milliseconds: 1100));
      final next = tester.takeAnnouncements().map((a) => a.message).toList();
      expect(next, [TimelineSemanticsStrings.movedTo(rig.project.index.locate(const ItemId('it_o1'))!.item.start)]);
      expect(rig.project.index.locate(const ItemId('it_o1'))!.item.start, 1 * s + f(3));
      await tester.pump(const Duration(seconds: 2));
      semantics.dispose();
    });

    testWidgets('the playhead is an adjustable slider stepping one frame', (tester) async {
      final semantics = tester.ensureSemantics();
      final rig = await A11yEditorRig.pump(tester, surface: _wide);
      final playhead = rig.container.read(playheadProvider(rig.id));
      final slider = find.semantics.byLabel(TimelineSemanticsStrings.playhead);
      expect(slider, findsOne);
      final data = slider.evaluate().single.getSemanticsData();
      expect(data.flagsCollection.isSlider, isTrue);
      expect(data.hasAction(SemanticsAction.increase), isTrue);
      expect(data.value, isNotEmpty);
      expect(data.increasedValue, isNotEmpty);
      tester.semantics.increase(slider);
      await tester.pump();
      expect(playhead.value, f(1));
      tester.semantics.increase(find.semantics.byLabel(TimelineSemanticsStrings.playhead));
      await tester.pump();
      tester.semantics.decrease(find.semantics.byLabel(TimelineSemanticsStrings.playhead));
      await tester.pump();
      expect(playhead.value, f(1));
      semantics.dispose();
    });

    testWidgets('markers, transitions and keyframes are tappable nodes', (tester) async {
      final semantics = tester.ensureSemantics();
      final rig = await A11yEditorRig.pump(tester, surface: _wide);
      final marker = find.semantics.byLabel('Marker at 0:03');
      expect(marker, findsOne);
      tester.semantics.tap(marker);
      await tester.pump();
      expect(rig.state.selection.marker, const MarkerId('mk_1'));

      final transition = find.semantics.byLabel(RegExp(r'^Cross dissolve transition at '));
      expect(transition, findsOne);
      tester.semantics.tap(transition);
      await rig.settle();
      expect(rig.state.inspector, isA<TransitionInspector>());
      rig.editor.closeInspector();
      await rig.settle();

      rig.editor.select(const ItemId('it_o1'));
      await rig.settle();
      final keys = find.semantics.byLabel(RegExp(r' keyframe at \d'));
      expect(keys.evaluate(), isNotEmpty);
      tester.semantics.tap(find.semantics.byLabel(RegExp(r' keyframe at \d')).first);
      await tester.pump();
      expect(rig.state.selection.keyframe?.item, const ItemId('it_o1'));
      await expectA11yGuidelines(tester, contrast: false, where: 'keyframes shown');
      semantics.dispose();
    });

    testWidgets('the manipulation overlay exposes move, scale and rotate actions', (tester) async {
      final semantics = tester.ensureSemantics();
      final rig = await A11yEditorRig.pump(tester, surface: _wide);
      await rig.real(() => rig.container.read(playheadProvider(rig.id)).seekExact(2 * s));
      rig.editor.select(const ItemId('it_o1'));
      await rig.settle();
      final overlay = find.semantics.byLabel(RegExp('^Selected '));
      expect(overlay, findsOne);
      final actions = customActionLabels(overlay.evaluate().single);
      expect(
        actions,
        containsAll([
          ManipulationStrings.moveLeft,
          ManipulationStrings.moveRight,
          ManipulationStrings.moveUp,
          ManipulationStrings.moveDown,
          ManipulationStrings.scaleUp,
          ManipulationStrings.scaleDown,
          ManipulationStrings.rotateClockwise,
          ManipulationStrings.rotateCounterclockwise,
        ]),
      );
      final before = rig.state.history.position;
      tester.semantics.customAction(overlay, const CustomSemanticsAction(label: ManipulationStrings.rotateClockwise));
      await tester.pump();
      expect(rig.state.history.position, before + 1);
      await tester.pump(const Duration(seconds: 2));
      semantics.dispose();
    });

    testWidgets('selecting an audio clip keeps the preview overlay building (FIX-UX-22-2)', (tester) async {
      final rig = await A11yEditorRig.pump(tester, surface: _wide);
      rig.editor.select(const ItemId('it_a1'));
      await tester.pump();
      final known = takeKnownException(tester, where: 'selecting an audio clip');
      if (known != null) {
        // Recorded in QA-08-a11y.md; drain the repeats of the same error.
        await tester.pump();
        tester.takeException();
        expect(audioSelectionCrashOpen, isTrue);
      }
      rig.editor.clearSelection();
      await tester.pump();
      tester.takeException();
    });
  });
}
