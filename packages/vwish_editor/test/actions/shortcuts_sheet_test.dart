// OWNER: UX-15
//
// The shortcuts sheet (ux.md §15.2): generated from the registry, so it lists exactly the actions
// that have a shortcut on the platform, grouped, with ⌘ or Ctrl glyphs; disabled actions stay
// listed and explain why; it fits every surface and follows the owner UI rules.

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vwish_editor/src/editor/actions/editor_action_registry.dart';
import 'package:vwish_editor/src/editor/actions/shortcuts_sheet.dart';
import 'package:vwish_editor/src/editor/contracts/contracts.dart';
import 'package:vwish_editor/src/editor/editor_scope.dart';
import 'package:vwish_editor/src/editor/wiring/action_bindings.dart';
import 'package:vwish_editor_core/model.dart';
import 'package:vwish_ui_kit/vwish_ui_kit.dart';

import '../support/support.dart';
import 'action_test_support.dart';

const ProjectId _id = ProjectId('pj_sheet');

/// Pumps the sheet content on its own (no route) for [surface].
Future<void> pumpSheet(
  WidgetTester tester, {
  required Map<EditorActionId, EditorActionBinding> bindings,
  EditorSurface surface = SurfaceMatrix.phone,
  ProjectId? projectId = _id,
}) async {
  final harness = EditorTestHarness(overrides: [editorActionBindingsProvider.overrideWithValue(bindings)]);
  await harness.pumpApp(
    tester,
    Material2(child: SingleChildScrollView(padding: const EdgeInsets.all(16), child: ShortcutsSheet(projectId: projectId))),
    surface: surface,
  );
  await tester.pump();
}

/// A plain surface for the sheet content (the real sheet route provides its own).
class Material2 extends StatelessWidget {
  const Material2({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => ColoredBox(color: VwishColors.surfaceElevated, child: SafeArea(child: child));
}

Iterable<ShortcutRow> rows(WidgetTester tester) => tester.widgetList<ShortcutRow>(find.byType(ShortcutRow));

void main() {
  final log = ActionLog();
  setUp(log.clear);

  for (final platform in [TargetPlatform.iOS, TargetPlatform.android, TargetPlatform.macOS]) {
    group(platform.name, () {
      testWidgets('lists exactly the actions with a shortcut, in registry order, with platform glyphs', (tester) async {
        await pumpSheet(tester, bindings: recordingBindings(log), surface: EditorSurface(const Size(600, 3000), platform: platform));
        final registry = EditorActionRegistry(bindings: recordingBindings(log), apple: isApple(platform));
        final expected = registry.shortcutSpecs.map((s) => s.id).toList();
        // The sheet orders by group; the ids of each group keep the registry's order.
        final byGroup = [
          for (final g in EditorActionGroup.values) ...expected.where((id) => id.group == g),
        ];
        expect(rows(tester).map((r) => r.spec.id).toList(), byGroup);
        expect(rows(tester).map((r) => r.spec.id).toSet(), expected.toSet(), reason: 'no action with a shortcut is missing, none without one is listed');
        final undo = rows(tester).firstWhere((r) => r.spec.id == EditorActionId.undo);
        expect(undo.spec.shortcutLabels, [isApple(platform) ? '⌘Z' : 'Ctrl+Z']);
        expect(find.text(isApple(platform) ? '⌘Z' : 'Ctrl+Z'), findsOneWidget);
        expect(find.text(isApple(platform) ? 'Ctrl+Z' : '⌘Z'), findsNothing);
        for (final group in {for (final id in expected) id.group}) {
          expect(find.text(EditorActionStrings.group(group)), findsOneWidget, reason: group.name);
        }
        expect(find.text(EditorActionStrings.sheetNote), findsOneWidget);
      });
    });
  }

  testWidgets('every shown label and key cap comes from the registry', (tester) async {
    await pumpSheet(tester, bindings: recordingBindings(log), surface: const EditorSurface(Size(600, 3000)));
    final registry = EditorActionRegistry(bindings: recordingBindings(log));
    for (final spec in registry.shortcutSpecs) {
      expect(find.text(spec.label), findsWidgets, reason: spec.label);
      for (final key in spec.shortcutLabels) {
        expect(find.text(key), findsWidgets, reason: '${spec.label}: $key');
      }
    }
  });

  testWidgets('disabled actions stay listed, dimmed, with the reason', (tester) async {
    await pumpSheet(
      tester,
      bindings: recordingBindings(log, disabled: {EditorActionId.split, EditorActionId.undo}),
      surface: const EditorSurface(Size(600, 3000)),
    );
    expect(find.text('Not now: split'), findsOneWidget);
    expect(find.text('Not now: undo'), findsOneWidget);
    expect(find.text('Not now: delete'), findsNothing);
    final split = rows(tester).firstWhere((r) => r.spec.id == EditorActionId.split);
    expect(split.disabledReason, 'Not now: split');
    expect(find.text('Split'), findsOneWidget, reason: 'still listed');
  });

  testWidgets('an action no feature binds yet reads "Not available yet"', (tester) async {
    await pumpSheet(tester, bindings: recordingBindings(log, skip: {EditorActionId.split}), surface: const EditorSurface(Size(600, 3000)));
    final split = rows(tester).firstWhere((r) => r.spec.id == EditorActionId.split);
    expect(split.disabledReason, EditorActionStrings.notAvailableYet);
    expect(find.text(EditorActionStrings.notAvailableYet), findsOneWidget);
  });

  testWidgets('semantics: one node per row with label, shortcut and the reason', (tester) async {
    final handle = tester.ensureSemantics();
    await pumpSheet(tester, bindings: recordingBindings(log, disabled: {EditorActionId.split}), surface: const EditorSurface(Size(600, 3000), platform: TargetPlatform.macOS));
    expect(find.bySemanticsLabel('Undo, ⌘Z'), findsOneWidget);
    expect(find.bySemanticsLabel('Split, S, unavailable: Not now: split'), findsOneWidget);
    expect(find.bySemanticsLabel('Play / Pause, Space or K'), findsOneWidget);
    handle.dispose();
  });

  testWidgets('without a project every bound action reads as available', (tester) async {
    await pumpSheet(tester, bindings: recordingBindings(log, disabled: {EditorActionId.split}), projectId: null, surface: const EditorSurface(Size(600, 3000)));
    expect(find.text('Not now: split'), findsNothing);
  });

  testWidgets('show() opens the sheet route with the title, and the close button dismisses it', (tester) async {
    final harness = EditorTestHarness(overrides: [editorActionBindingsProvider.overrideWithValue(recordingBindings(log))]);
    late BuildContext context;
    await harness.pumpApp(
      tester,
      EditorScope(
        projectId: _id,
        child: Builder(builder: (c) {
          context = c;
          return const SizedBox.shrink();
        }),
      ),
    );
    unawaited(ShortcutsSheet.show(context));
    await tester.pumpAndSettle();
    expect(find.byType(ShortcutsSheet), findsOneWidget);
    expect(find.text(EditorActionStrings.sheetTitle), findsWidgets);
    expect(rows(tester), isNotEmpty);
    await tester.tap(find.byTooltip('Close'));
    await tester.pumpAndSettle();
    expect(find.byType(ShortcutsSheet), findsNothing);
  });

  group('no-overflow matrix', () {
    testSurfaces('the sheet fits and follows the owner UI rules', (tester, surface) async {
      final harness = EditorTestHarness(overrides: [editorActionBindingsProvider.overrideWithValue(recordingBindings(log, disabled: {EditorActionId.split}))]);
      late BuildContext context;
      await harness.pumpApp(
        tester,
        EditorScope(
          projectId: _id,
          child: Builder(builder: (c) {
            context = c;
            return const SizedBox.shrink();
          }),
        ),
        surface: surface,
      );
      unawaited(ShortcutsSheet.show(context));
      await tester.pumpAndSettle();
      expectNoOverflow(tester);
      expectOwnerUiRules(tester);
      // The list scrolls inside the sheet: scroll to the end and check again.
      await tester.drag(find.ancestor(of: find.byType(ShortcutsSheet), matching: find.byType(SingleChildScrollView)), const Offset(0, -4000));
      await tester.pumpAndSettle();
      expectNoOverflow(tester);
      expectOwnerUiRules(tester);
    });

    for (final width in [280.0, 340.0, 360.0, 600.0]) {
      testWidgets('rows at width $width and text scale 1.35', (tester) async {
        await pumpSheet(tester, bindings: recordingBindings(log, disabled: {EditorActionId.rippleDelete}), surface: EditorSurface(Size(width, 6000), textScale: 1.35));
        expectNoOverflow(tester);
        for (final row in find.byType(ShortcutRow).evaluate()) {
          final box = row.renderObject! as RenderBox;
          final right = box.localToGlobal(Offset(box.size.width, 0)).dx;
          expect(right, lessThanOrEqualTo(width + 0.5));
        }
      });
    }
  });
}
