// OWNER: UX-29
//
// The Format panel (ux.md §10.14): every control dispatches one CORE-17 command and one history
// entry; "Original" and "Match first clip" come from the first main clip; the frame-rate change of
// a project with content asks first (requantize warning); 4K is capability-gated; the panel is
// disabled until the project accepts edits; the `format` action opens it; surface matrix.

import 'package:flutter/widgets.dart' hide AspectRatio;
import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_editor/src/app/strings/project_strings.dart';
import 'package:danaview_editor/src/editor/actions/editor_action_registry.dart' show EditorActionResult;
import 'package:danaview_editor/src/editor/contracts/contracts.dart';
import 'package:danaview_editor/src/editor/inspector/inspector_rows.dart';
import 'package:danaview_editor/src/editor/panels/canvas_panel.dart';
import 'package:danaview_editor/src/editor/state/editor_state.dart' show SavePhase;
import 'package:danaview_editor/src/editor/timeline/timeline_semantics.dart' show EditorAnnouncer;
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_editor_engine_api/testing.dart' show fakeDefaultCapabilities;
import 'package:danaview_ui_kit/danaview_ui_kit.dart';

import '../../support/support.dart';
import 'project_rig.dart';

Finder key(String k) => find.byKey(ValueKey<String>(k));

bool selected(WidgetTester tester, String k) => tester.widget<DanaviewChoiceChip>(key(k)).selected;

bool enabled(WidgetTester tester, String k) {
  final chip = tester.widget<DanaviewChoiceChip>(key(k));
  return chip.enabled && chip.onTap != null;
}

/// Scrolls [finder] into view and taps it.
Future<void> tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

/// Lets toasts expire so no timer outlives the test.
Future<void> drain(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 6));
  await tester.pumpAndSettle();
  EditorAnnouncer.instance.reset();
}

void testFormat(String description, Future<void> Function(WidgetTester tester) body) => testWidgets(description, (tester) async {
      try {
        await body(tester);
        await drain(tester);
      } finally {
        EditorAnnouncer.instance.reset();
      }
    });

void main() {
  late DateTime now;
  setUp(() {
    now = DateTime.utc(2026, 10, 11, 9);
    InspectorRows.clock = () => now;
  });
  tearDown(() => InspectorRows.clock = DateTime.now);

  group('model', () {
    test('Original and Match first clip come from the first main clip, like project creation', () {
      final p = projectRigProject(const ProjectId('p'));
      final o = CanvasPanelModel.originalOf(p)!;
      expect(o.canvas.aspect, const AspectRatio(4, 3));
      expect(o.frameRate, FrameRate.fps25);
      expect(CanvasPanelModel.originalOf(projectRigProject(const ProjectId('p'), empty: true)), isNull);
    });

    test('offers the six aspects, the six project rates and three resolutions', () {
      expect(CanvasPanelModel.aspects.map((a) => '$a'), ['16:9', '9:16', '1:1', '4:5', '4:3', '21:9']);
      expect(CanvasPanelModel.rates.map((r) => r.num), FrameRate.supportedProjectRates);
      expect(CanvasPanelModel.shortSides, [720, 1080, 2160]);
      expect(CanvasPanelModel.allows(2160, const Size(1920, 1080)), isFalse);
      expect(CanvasPanelModel.allows(2160, const Size(3840, 2160)), isTrue);
      expect(CanvasPanelModel.allows(1080, null), isTrue);
    });
  });

  group('aspect', () {
    testFormat('shows Original first and the standard ratios; 16:9 is selected', (tester) async {
      await ProjectRig.pump(tester, openFormat: true);
      expect(find.byType(CanvasPanel), findsOneWidget);
      expect(find.text(ProjectStrings.aspectOriginal(const AspectRatio(4, 3))), findsOneWidget);
      for (final a in CanvasPanelModel.aspects) {
        expect(selected(tester, 'canvas.aspect.${a.w}x${a.h}'), a == AspectRatio.landscape16x9, reason: '$a');
      }
      expect(selected(tester, 'canvas.aspect.original'), isFalse);
      expectNoOverflow(tester);
    });

    for (final a in AspectRatio.standard.where((a) => a != AspectRatio.landscape16x9)) {
      testFormat('the $a chip runs SetCanvas: one "Canvas" entry and the Transform toast', (tester) async {
        final rig = await ProjectRig.pump(tester, openFormat: true);
        final before = rig.entries;
        await tester.ensureVisible(key('canvas.aspect.${a.w}x${a.h}'));
        await tester.pumpAndSettle();
        await tester.tap(key('canvas.aspect.${a.w}x${a.h}'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(rig.settings.canvas.aspect, a);
        expect(rig.settings.canvas.baseShortSide, 1080, reason: 'the resolution base is kept');
        expect(rig.entries, before + 1);
        expect(rig.labels.last, 'Canvas');
        expect(find.text(ProjectStrings.aspectChanged), findsOneWidget);
        expect(rig.project.index.item(const ItemId('it_a')), isNotNull, reason: 'items are untouched');
      });
    }

    testFormat('Original sets the first clip\'s aspect and becomes the selected chip', (tester) async {
      final rig = await ProjectRig.pump(tester, openFormat: true);
      await tap(tester, key('canvas.aspect.original'));
      expect(rig.settings.canvas.aspect, const AspectRatio(4, 3));
      expect(selected(tester, 'canvas.aspect.original'), isTrue);
      expect(selected(tester, 'canvas.aspect.4x3'), isFalse, reason: 'exactly one chip is selected');
      expect(rig.labels, ['Canvas']);
    });

    testFormat('tapping the selected aspect adds nothing to history and shows no toast', (tester) async {
      final rig = await ProjectRig.pump(tester, openFormat: true);
      await tap(tester, key('canvas.aspect.16x9'));
      expect(rig.entries, 0);
      expect(find.text(ProjectStrings.aspectChanged), findsNothing);
    });
  });

  group('background', () {
    testFormat('Blur switches to a blurred copy of the main video (one entry), Colour back to black', (tester) async {
      final rig = await ProjectRig.pump(tester, openFormat: true);
      expect(key('canvas.background.color'), findsOneWidget);
      await tap(tester, find.text(ProjectStrings.backgroundBlur));
      expect(rig.settings.background, const BlurOfMainBackground(CanvasPanelModel.defaultBlur));
      expect(rig.labels, ['Background']);
      expect(key('canvas.background.blur'), findsOneWidget);
      expect(find.text(ProjectStrings.blurHint), findsOneWidget);
      await tap(tester, find.text(ProjectStrings.backgroundColor));
      expect(rig.settings.background, BackgroundSpec.black);
      expect(rig.entries, 2);
    });

    testFormat('a colour gesture is one SetBackground entry', (tester) async {
      final rig = await ProjectRig.pump(tester, openFormat: true);
      final row = tester.widget<InspectorColorRow>(key('canvas.background.color'));
      row.onChangeStart!(const Color(0xFF000000));
      row.onChanged(const Color(0xFF112233));
      row.onChanged(const Color(0xFF445566));
      row.onChangeEnd!(const Color(0xFF445566));
      await tester.pump();
      expect(rig.settings.background, const SolidBackground(0xFF445566));
      expect(rig.labels, ['Background']);
    });

    testFormat('a blur drag is one entry, a typed amount another; the amount survives Colour and back', (tester) async {
      final rig = await ProjectRig.pump(tester, openFormat: true);
      await tap(tester, find.text(ProjectStrings.backgroundBlur));
      var row = tester.widget<InspectorSliderRow>(key('canvas.background.blur'));
      row.onChangeStart!(0.5);
      row.onChanged!(0.6);
      row.onChanged!(0.7);
      row.onChangeEnd!(0.7);
      await tester.pump();
      expect(rig.settings.background, const BlurOfMainBackground(0.7));
      expect(rig.entries, 2);
      row = tester.widget<InspectorSliderRow>(key('canvas.background.blur'));
      row.onSubmitted!(0.25);
      await tester.pump();
      expect(rig.settings.background, const BlurOfMainBackground(0.25));
      expect(rig.entries, 3);
      await tap(tester, find.text(ProjectStrings.backgroundColor));
      await tap(tester, find.text(ProjectStrings.backgroundBlur));
      expect(rig.settings.background, const BlurOfMainBackground(0.25));
    });
  });

  group('frame rate', () {
    testFormat('the rates are 24/25/30/48/50/60 plus Match first clip; 30 is selected', (tester) async {
      await ProjectRig.pump(tester, openFormat: true);
      for (final r in CanvasPanelModel.rates) {
        expect(selected(tester, 'canvas.fps.${r.num}'), r == FrameRate.fps30, reason: '$r');
      }
      expect(find.text(ProjectStrings.fpsMatch(FrameRate.fps25)), findsOneWidget);
    });

    testFormat('with content, a new rate asks first; Cancel changes nothing', (tester) async {
      final rig = await ProjectRig.pump(tester, openFormat: true);
      await tap(tester, key('canvas.fps.24'));
      expect(find.text(ProjectStrings.frameRateConfirmTitle(FrameRate.fps24)), findsOneWidget);
      expect(find.text(ProjectStrings.frameRateConfirmMessage), findsOneWidget);
      await tester.tap(find.text(ProjectStrings.cancel));
      await tester.pumpAndSettle();
      expect(rig.settings.frameRate, FrameRate.fps30);
      expect(rig.entries, 0);
    });

    testFormat('Change runs one SetFrameRate (requantize): one "Frame rate" entry, edits on the new grid', (tester) async {
      final rig = await ProjectRig.pump(tester, openFormat: true);
      await tap(tester, key('canvas.fps.24'));
      await tester.tap(find.text(ProjectStrings.frameRateConfirm));
      await tester.pumpAndSettle();
      expect(rig.settings.frameRate, FrameRate.fps24);
      expect(rig.labels, ['Frame rate']);
      for (final t in rig.project.tracks) {
        for (final i in t.items) {
          expect(FrameRate.fps24.quantize(i.start), i.start, reason: '${i.id} starts on the 24 fps grid');
        }
      }
      expect(selected(tester, 'canvas.fps.24'), isTrue);
    });

    testFormat('Match first clip sets the first clip\'s rate and becomes the selected chip', (tester) async {
      final rig = await ProjectRig.pump(tester, openFormat: true);
      await tap(tester, key('canvas.fps.match'));
      await tester.tap(find.text(ProjectStrings.frameRateConfirm));
      await tester.pumpAndSettle();
      expect(rig.settings.frameRate, FrameRate.fps25);
      expect(selected(tester, 'canvas.fps.match'), isTrue);
      expect(selected(tester, 'canvas.fps.25'), isFalse);
    });

    testFormat('an empty project changes the rate without asking', (tester) async {
      final rig = await ProjectRig.pump(tester, openFormat: true, empty: true);
      expect(key('canvas.fps.match'), findsNothing, reason: 'no first clip');
      expect(key('canvas.aspect.original'), findsNothing);
      await tap(tester, key('canvas.fps.60'));
      expect(find.text(ProjectStrings.frameRateConfirmTitle(FrameRate.fps60)), findsNothing);
      expect(rig.settings.frameRate, FrameRate.fps60);
      expect(rig.labels, ['Frame rate']);
    });
  });

  group('resolution', () {
    testFormat('720p runs SetCanvas(baseShortSide) and the canvas size follows', (tester) async {
      final rig = await ProjectRig.pump(tester, openFormat: true);
      expect(find.text(ProjectStrings.canvasSize(1920, 1080)), findsOneWidget);
      await tap(tester, key('canvas.res.720'));
      expect(rig.settings.canvas.baseShortSide, 720);
      expect(rig.settings.canvas.aspect, AspectRatio.landscape16x9);
      expect(rig.labels, ['Canvas']);
      expect(find.text(ProjectStrings.canvasSize(1280, 720)), findsOneWidget);
      expect(selected(tester, 'canvas.res.720'), isTrue);
    });

    testFormat('4K is disabled with a reason when the device cannot export it', (tester) async {
      final rig = await ProjectRig.pump(tester, openFormat: true);
      expect(enabled(tester, 'canvas.res.2160'), isFalse);
      expect(find.text(ProjectStrings.resolution4kUnavailable), findsOneWidget);
      await tester.ensureVisible(key('canvas.res.2160'));
      await tester.tap(key('canvas.res.2160'), warnIfMissed: false);
      await tester.pump();
      expect(rig.settings.canvas.baseShortSide, 1080);
    });

    testFormat('4K is offered when the device exports 2160p', (tester) async {
      final rig = await ProjectRig.pump(tester, openFormat: true, caps: fakeDefaultCapabilities.copyWith(maxExportSize: const Size(3840, 2160)));
      expect(enabled(tester, 'canvas.res.2160'), isTrue);
      expect(find.text(ProjectStrings.resolution4kUnavailable), findsNothing);
      await tap(tester, key('canvas.res.2160'));
      expect(rig.settings.canvas.baseShortSide, 2160);
      expect(find.text(ProjectStrings.canvasSize(3840, 2160)), findsOneWidget);
    });
  });

  group('state and action', () {
    testFormat('a read-only project shows a notice and disables every control', (tester) async {
      final rig = await ProjectRig.pump(tester, readOnly: true);
      expect(rig.state.save.phase, SavePhase.readOnly);
      rig.editor.openInspector(const CanvasInspector());
      await tester.pump();
      expect(find.byType(CanvasPanel), findsOneWidget);
      expect(find.text(ProjectStrings.notEditable), findsOneWidget);
      for (final k in ['canvas.aspect.original', 'canvas.aspect.9x16', 'canvas.fps.24', 'canvas.res.720']) {
        expect(enabled(tester, k), isFalse, reason: k);
      }
      expect(tester.widget<DanaviewSegmentedControl<bool>>(key('canvas.background.mode')).enabled, isFalse);
      expect(tester.widget<InspectorColorRow>(key('canvas.background.color')).enabled, isFalse);
    });

    testFormat('the format action opens the Format panel; it explains itself before the project opens', (tester) async {
      final closed = await ProjectRig.pump(tester, open: false);
      expect(closed.registry.spec(EditorActionId.format).isEnabled(closed.ctx), isFalse);
      expect(closed.registry.spec(EditorActionId.format).disabledReason(closed.ctx), ProjectStrings.notOpen);
      await closed.real(() => closed.editor.open());
      expect(closed.registry.spec(EditorActionId.format).isEnabled(closed.ctx), isTrue);
      expect(await closed.invoke(EditorActionId.format), EditorActionResult.ran);
      expect(closed.state.inspector, const CanvasInspector());
      expect(find.byType(CanvasPanel), findsOneWidget);
    });
  });

  group('matrix (no overflow, owner UI rules)', () {
    testSurfaces('Format panel, colour background', (tester, surface) async {
      try {
        await ProjectRig.pump(tester, surface: surface, openFormat: true);
        expect(find.byType(CanvasPanel), findsOneWidget);
        expectNoOverflow(tester);
        expectOwnerUiRules(tester);
        for (final k in ['canvas.aspect.original', 'canvas.aspect.21x9', 'canvas.fps.match', 'canvas.res.2160']) {
          await tester.ensureVisible(key(k));
          await tester.pumpAndSettle();
          final r = tester.getRect(key(k));
          expect(r.left, greaterThanOrEqualTo(0), reason: k);
          expect(r.right, lessThanOrEqualTo(surface.size.width), reason: k);
        }
        expectNoOverflow(tester);
        await drain(tester);
      } finally {
        EditorAnnouncer.instance.reset();
      }
    });

    testSurfaces('Format panel, blur background and the frame-rate confirmation', (tester, surface) async {
      try {
        await ProjectRig.pump(tester, surface: surface, openFormat: true);
        await tap(tester, find.text(ProjectStrings.backgroundBlur));
        expect(key('canvas.background.blur'), findsOneWidget);
        expectNoOverflow(tester);
        expectOwnerUiRules(tester);
        await tap(tester, key('canvas.fps.48'));
        expect(find.text(ProjectStrings.frameRateConfirmMessage), findsOneWidget);
        expectNoOverflow(tester);
        expectOwnerUiRules(tester);
        await tester.tap(find.text(ProjectStrings.cancel));
        await drain(tester);
      } finally {
        EditorAnnouncer.instance.reset();
      }
    });
  });
}
