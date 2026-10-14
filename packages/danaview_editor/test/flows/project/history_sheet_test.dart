// OWNER: UX-29
//
// The History sheet (ux.md §14.2): the last 50 labels newest first with the current position
// marked; a tap jumps N steps as ONE controller call that patches the plan once (a counting
// PlanSync over FakeEditorEngine); undone entries redo; the `history` action; surface matrix.

import 'package:flutter/widgets.dart' hide AspectRatio;
import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_editor/src/app/strings/project_strings.dart';
import 'package:danaview_editor/src/editor/actions/editor_action_registry.dart' show EditorActionResult;
import 'package:danaview_editor/src/editor/contracts/contracts.dart';
import 'package:danaview_editor/src/editor/flows/history_sheet.dart';
import 'package:danaview_editor/src/editor/timeline/timeline_semantics.dart' show EditorAnnouncer;
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_editor_core/ops.dart' show AddMarker, SetBackground, SetCanvas;
import 'package:danaview_ui_kit/danaview_ui_kit.dart';

import '../../support/support.dart';
import 'project_rig.dart';

Finder key(String k) => find.byKey(ValueKey<String>(k));

/// Applies [n] distinct edits ("Add marker" each).
void edits(ProjectRig rig, int n) {
  for (var i = 0; i < n; i++) {
    rig.editor.apply(AddMarker((10 + i) * s ~/ 10));
  }
}

/// Lets toasts and announcements expire.
Future<void> drain(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 6));
  await tester.pumpAndSettle();
  EditorAnnouncer.instance.reset();
}

void testHistory(String description, Future<void> Function(WidgetTester tester) body) => testWidgets(description, (tester) async {
      try {
        await body(tester);
        await drain(tester);
      } finally {
        EditorAnnouncer.instance.reset();
      }
    });

/// The row titles shown, top to bottom.
List<String> titles(WidgetTester tester) => [
      for (final t in tester.widgetList<DanaviewListTile>(find.descendant(of: key('history.list'), matching: find.byType(DanaviewListTile))))
        t.title,
    ];

void main() {
  group('historyRows', () {
    test('newest first, the entry before the cursor is current, later entries are undone, Start last', () {
      final rows = historyRows(['A', 'B', 'C', 'D'], 2);
      expect(rows.map((r) => r.label), ['D', 'C', 'B', 'A', ProjectStrings.historyStart]);
      expect(rows.map((r) => r.steps), [2, 1, 0, -1, -2]);
      expect(rows.map((r) => r.current), [false, false, true, false, false]);
      expect(rows.map((r) => r.undone), [true, true, false, false, false]);
      expect(rows.last.isStart, isTrue);
    });

    test('at position 0 the Start row is current; empty history has no rows', () {
      final rows = historyRows(['A'], 0);
      expect(rows.map((r) => (r.label, r.steps, r.current)), [('A', 1, false), (ProjectStrings.historyStart, 0, true)]);
      expect(historyRows(const [], 0), isEmpty);
    });

    test('lists at most 50 entries and no Start row when older entries are hidden', () {
      final labels = [for (var i = 0; i < 60; i++) 'E$i'];
      final rows = historyRows(labels, 60);
      expect(rows, hasLength(50));
      expect(rows.first.label, 'E59');
      expect(rows.first.current, isTrue);
      expect(rows.last.label, 'E10');
      expect(rows.last.steps, -49);
      expect(rows.any((r) => r.isStart), isFalse);
      expect(historyRows(labels.take(50).toList(), 50).last.isStart, isTrue);
    });
  });

  group('sheet', () {
    testHistory('the history action opens "Edit history" with the labels newest first and the current one marked', (tester) async {
      final rig = await ProjectRig.pump(tester, withPanel: false);
      rig.editor.apply(const SetCanvas(aspect: AspectRatio.square));
      edits(rig, 1);
      rig.editor.apply(const SetBackground(BlurOfMainBackground(0.4)));
      rig.editor.undo();
      await tester.pump();
      expect(await rig.invoke(EditorActionId.history), EditorActionResult.ran);
      expect(find.text(ProjectStrings.historyTitle), findsOneWidget);
      expect(titles(tester), ['Background', 'Add marker', 'Canvas', ProjectStrings.historyStart]);
      final current = tester.widget<DanaviewListTile>(key('history.row.1'));
      expect(current.selected, isTrue);
      expect(current.subtitle, ProjectStrings.historyCurrent);
      expect(tester.widget<DanaviewListTile>(key('history.row.2')).subtitle, ProjectStrings.historyUndone);
      expect(tester.widget<DanaviewListTile>(key('history.row.1')).onTap, isNull, reason: 'the current row does nothing');
    });

    testHistory('tapping an older row is one jump: N steps, one plan patch, the sheet follows', (tester) async {
      final rig = await ProjectRig.pump(tester, withPanel: false);
      edits(rig, 5);
      await tester.pump();
      await rig.invoke(EditorActionId.history);
      final patches = rig.sync.schedules;
      final markers = rig.project.markers.length;
      await tester.tap(key('history.row.1'));
      await tester.pump();
      expect(rig.entries, 2);
      expect(rig.sync.schedules, patches + 1, reason: 'jumping 3 steps patches the plan once');
      expect(rig.project.markers.length, markers - 3);
      expect(tester.widget<DanaviewListTile>(key('history.row.1')).selected, isTrue);
      expect(tester.widget<DanaviewListTile>(key('history.row.4')).subtitle, ProjectStrings.historyUndone);
      // Redo forward to the newest entry: one more patch.
      await tester.tap(key('history.row.4'));
      await tester.pump();
      expect(rig.entries, 5);
      expect(rig.sync.schedules, patches + 2);
      expect(rig.project.markers.length, markers);
    });

    testHistory('the Start row undoes everything in one jump', (tester) async {
      final rig = await ProjectRig.pump(tester, withPanel: false);
      final original = rig.project.markers.length;
      edits(rig, 4);
      await tester.pump();
      await rig.invoke(EditorActionId.history);
      final patches = rig.sync.schedules;
      await tester.ensureVisible(key('history.start'));
      await tester.pumpAndSettle();
      await tester.tap(key('history.start'));
      await tester.pump();
      expect(rig.entries, 0);
      expect(rig.project.markers.length, original);
      expect(rig.sync.schedules, patches + 1);
      expect(rig.state.history.canRedo, isTrue);
      expect(tester.widget<DanaviewListTile>(key('history.start')).selected, isTrue);
    });

    testHistory('with more than 50 entries the newest 50 are listed and the rest is counted', (tester) async {
      final rig = await ProjectRig.pump(tester, withPanel: false);
      edits(rig, 55);
      await tester.pump();
      expect(rig.labels, hasLength(55));
      await rig.invoke(EditorActionId.history);
      expect(titles(tester), hasLength(50));
      expect(key('history.row.54'), findsOneWidget);
      expect(key('history.row.4'), findsNothing);
      expect(key('history.start'), findsNothing);
      expect(find.text(ProjectStrings.historyOlder(5)), findsOneWidget);
    });

    testHistory('an empty history says so', (tester) async {
      final rig = await ProjectRig.pump(tester, withPanel: false);
      await rig.invoke(EditorActionId.history);
      expect(key('history.empty'), findsOneWidget);
      expect(find.text(ProjectStrings.historyEmpty), findsOneWidget);
    });

    testHistory('the history action is disabled until the project is open', (tester) async {
      final rig = await ProjectRig.pump(tester, withPanel: false, open: false);
      expect(rig.registry.spec(EditorActionId.history).isEnabled(rig.ctx), isFalse);
      expect(rig.registry.spec(EditorActionId.history).disabledReason(rig.ctx), ProjectStrings.notOpen);
    });
  });

  group('matrix (no overflow, owner UI rules)', () {
    testSurfaces('History sheet with current, undone and Start rows', (tester, surface) async {
      try {
        final rig = await ProjectRig.pump(tester, surface: surface, withPanel: false, name: 'A rather long project name for the sheet');
        edits(rig, 6);
        rig.editor.undo();
        rig.editor.undo();
        await tester.pump();
        await rig.invoke(EditorActionId.history);
        expect(key('history.list'), findsOneWidget);
        expectNoOverflow(tester);
        expectOwnerUiRules(tester);
        await tester.ensureVisible(key('history.start'));
        await tester.pumpAndSettle();
        expectInside(tester, key('history.start'));
        await drain(tester);
      } finally {
        EditorAnnouncer.instance.reset();
      }
    });

    testSurfaces('History sheet, empty', (tester, surface) async {
      try {
        final rig = await ProjectRig.pump(tester, surface: surface, withPanel: false);
        await rig.invoke(EditorActionId.history);
        expect(key('history.empty'), findsOneWidget);
        expectNoOverflow(tester);
        expectOwnerUiRules(tester);
        await drain(tester);
      } finally {
        EditorAnnouncer.instance.reset();
      }
    });
  });
}
