// OWNER: QA-08
//
// Reduced motion and right-to-left chrome (ARCH §17.9, ux.md §19.1):
// * with the platform's reduce-motion flag the inspector dock changes height without animating,
//   and the editor with its inspector and flow sheets settles (no endless animation: progress bars
//   stand still); the countdown and the progress bar themselves are covered by
//   test/panels/voiceover and danaview_ui_kit's editor_components_test;
// * in RTL the chrome mirrors (close button and track headers on the start side, the right) while
//   the time axis stays left → right: later clips sit further right, the timeline's semantics
//   nodes are LTR, and the guidelines still hold.

import 'dart:async';

import 'package:flutter/semantics.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_editor/src/editor/contracts/contracts.dart';
import 'package:danaview_editor/src/editor/flows/export/export_sheet.dart';
import 'package:danaview_editor/src/editor/flows/tasks_sheet.dart';
import 'package:danaview_editor/src/editor/inspector/inspector_dock.dart';
import 'package:danaview_editor/src/editor/layout/editor_shell_strings.dart';
import 'package:danaview_editor/src/editor/layout/editor_top_bar.dart';
import 'package:danaview_editor/src/editor/timeline/render_timeline_canvas.dart';
import 'package:danaview_editor/src/editor/timeline/timeline_semantics.dart';
import 'package:danaview_editor/src/editor/timeline/track_headers.dart';
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_ui_kit/danaview_ui_kit.dart';

import '../support/support.dart';
import 'a11y_support.dart';

const EditorSurface _phone = EditorSurface(Size(390, 844), textScale: 1.35);
const EditorSurface _wide = EditorSurface(Size(1280, 800), platform: TargetPlatform.iOS);

/// The dock's height animation.
AnimatedContainer _dockAnimation(WidgetTester tester) => tester.widget<AnimatedContainer>(
      find.descendant(of: find.byType(DanaviewDockedPanel), matching: find.byType(AnimatedContainer)).first,
    );

/// Left edges of the main lane's clip nodes, in start-time order.
List<double> _mainLaneLefts() {
  final nodes = find.semantics.byLabel(RegExp(r', track Main\b')).evaluate().toList();
  final byStart = <(int, double)>[];
  for (final node in nodes) {
    final m = RegExp(r'starts at (\d+):(\d+)').firstMatch(node.getSemanticsData().label)!;
    final rect = globalRectOf(node, 1)!;
    byStart.add((int.parse(m[1]!) * 60 + int.parse(m[2]!), rect.left));
  }
  byStart.sort((a, b) => a.$1.compareTo(b.$1));
  return [for (final (_, left) in byStart) left];
}

void main() {
  group('reduced motion', () {
    for (final reduce in [false, true]) {
      testWidgets('the inspector dock ${reduce ? 'does not' : 'does'} animate its height', (tester) async {
        final rig = await A11yEditorRig.pump(tester, surface: _phone, reduceMotion: reduce);
        await rig.openInspector(const TransformInspector(ItemId('it_v1')));
        expect(find.byType(InspectorDock), findsOneWidget);
        expect(_dockAnimation(tester).duration, reduce ? Duration.zero : DanaviewMotion.normal);
      });
    }

    testWidgets('with reduce motion the editor, a panel and the flow sheets settle', (tester) async {
      final rig = await A11yEditorRig.pump(tester, surface: _phone, reduceMotion: true);
      await rig.openInspector(const AdjustInspector(ItemId('it_v1')));
      await tester.pumpAndSettle(const Duration(milliseconds: 100), EnginePhase.sendSemanticsUpdate, const Duration(seconds: 5));
      final context = tester.element(find.byType(EditorTopBar));
      unawaited(TasksSheet.show(context, projectId: rig.id));
      await tester.pumpAndSettle(const Duration(milliseconds: 100), EnginePhase.sendSemanticsUpdate, const Duration(seconds: 5));
      await rig.popRoute();
      unawaited(ExportSheet.show(context, projectId: rig.id));
      await rig.real(() async {});
      await tester.pumpAndSettle(const Duration(milliseconds: 100), EnginePhase.sendSemanticsUpdate, const Duration(seconds: 5));
      expect(Navigator.of(context).canPop(), isTrue);
      expectNoOverflow(tester);
    });
  });

  group('right to left', () {
    for (final surface in [_wide, _phone]) {
      testWidgets('chrome mirrors, the time axis stays left to right [$surface]', (tester) async {
        final semantics = tester.ensureSemantics();
        final lefts = <TextDirection, List<double>>{};
        for (final dir in TextDirection.values) {
          await A11yEditorRig.pump(tester, surface: surface, textDirection: dir);
          final width = surface.size.width;
          final close = tester.getRect(find.byTooltip(EditorShellStrings.closeEditor).first);
          final headers = tester.getRect(find.byType(TrackHeaders).first);
          final canvas = tester.getRect(find.byType(TimelineCanvas));
          if (dir == TextDirection.rtl) {
            expect(close.center.dx, greaterThan(width / 2), reason: 'close sits on the start side (right)');
            expect(headers.left, greaterThanOrEqualTo(canvas.right - 0.5), reason: 'headers on the start side (right)');
          } else {
            expect(close.center.dx, lessThan(width / 2));
            expect(headers.right, lessThanOrEqualTo(canvas.left + 0.5));
          }
          final l = _mainLaneLefts();
          expect(l, isNotEmpty);
          for (var i = 1; i < l.length; i++) {
            expect(l[i], greaterThan(l[i - 1]), reason: 'later clips sit further right in $dir');
          }
          lefts[dir] = l;
          final slider = find.semantics.byLabel(TimelineSemanticsStrings.playhead).evaluate().single;
          expect(slider.getSemanticsData().textDirection, TextDirection.ltr);
          expectNoOverflow(tester);
          await expectA11yGuidelines(tester, where: '$dir $surface');
        }
        expect(lefts[TextDirection.rtl]!.length, lefts[TextDirection.ltr]!.length);
        semantics.dispose();
      });
    }

    testWidgets('RTL with a panel open and a clip selected', (tester) async {
      final semantics = tester.ensureSemantics();
      final rig = await A11yEditorRig.pump(tester, surface: _wide, textDirection: TextDirection.rtl);
      await rig.openInspector(const TextInspector(ItemId('it_t1'), tab: TextPanelTab.style));
      expectNoOverflow(tester);
      await expectA11yGuidelines(tester, where: 'RTL text panel');
      final clip = find.semantics.byLabel(RegExp(r'^Text, Hello world')).evaluate().single;
      expect(clip.getSemanticsData().textDirection, TextDirection.ltr);
      expect(clip.getSemanticsData().hasAction(SemanticsAction.customAction), isTrue);
      semantics.dispose();
    });
  });
}
