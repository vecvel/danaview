// OWNER: UX-07
//
// EditorTopBar (ux.md §6.4) inside the editor: close, the title button with the save status,
// undo/redo with their labels and shortcuts, long-press history, Export (label at ≥ 360 px, a
// round icon below) and the project sheet, wired to the shell and the action bindings.

import 'package:flutter/material.dart' show Icons;
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_editor/src/editor/contracts/contracts.dart';
import 'package:danaview_editor/src/editor/editor_screen.dart';
import 'package:danaview_editor/src/editor/layout/editor_shell_strings.dart';
import 'package:danaview_editor/src/editor/layout/editor_top_bar.dart';
import 'package:danaview_editor/src/editor/wiring/action_bindings.dart';
import 'package:danaview_ui_kit/danaview_ui_kit.dart';

import '../support/support.dart';
import 'fake_editor_shell.dart';

const _ready = EditorShellStatus(phase: EditorShellPhase.ready, projectName: 'Goa trip');

Future<(EditorTestHarness, FakeEditorShell)> _pump(
  WidgetTester tester, {
  EditorShellStatus status = _ready,
  EditorSurface surface = SurfaceMatrix.phone,
  Map<EditorActionId, EditorActionBinding>? bindings,
}) async {
  final shell = FakeEditorShell(status: status);
  final h = EditorTestHarness(overrides: [
    overrideShell(shell),
    if (bindings != null) editorActionBindingsProvider.overrideWithValue(bindings),
  ]);
  await h.pumpEditor(tester, surface: surface);
  return (h, shell);
}

Finder _inTopBar(Finder f) => find.descendant(of: find.byType(EditorTopBar), matching: f);

/// The title button (the pressable around the project name).
Finder _title(String name) => find.ancestor(of: _inTopBar(find.text(name)), matching: find.byType(DanaviewPressable)).first;

void main() {
  group('title and save status', () {
    testWidgets('name over the status; each save state has its line', (tester) async {
      final (_, shell) = await _pump(tester);
      expect(_inTopBar(find.text('Goa trip')), findsOneWidget);
      expect(_inTopBar(find.text(EditorShellStrings.saved)), findsOneWidget);
      for (final (save, text) in [
        (EditorSaveIndicator.edited, EditorShellStrings.edited),
        (EditorSaveIndicator.saving, EditorShellStrings.saving),
        (EditorSaveIndicator.failed, EditorShellStrings.saveFailed),
      ]) {
        shell.status.value = _ready.copyWith(save: save);
        await tester.pump();
        expect(_inTopBar(find.text(text)), findsOneWidget, reason: save.name);
      }
      final failedStyle = tester.widget<Text>(_inTopBar(find.text(EditorShellStrings.saveFailed))).style!;
      expect(failedStyle.color, DanaviewColors.errorLight);
    });

    testWidgets('"Couldn\'t save · Retry" saves now (manual)', (tester) async {
      final (_, shell) = await _pump(tester, status: _ready.copyWith(save: EditorSaveIndicator.failed));
      final semantics = tester.ensureSemantics();
      expect(
        tester.getSemantics(_title('Goa trip')),
        matchesSemantics(
            label: 'Goa trip, ${EditorShellStrings.saveFailed}', hint: EditorShellStrings.retryHint, isButton: true, hasTapAction: true),
      );
      await tester.tap(_inTopBar(find.text(EditorShellStrings.saveFailed)));
      await tester.pump();
      expect(shell.calls, contains('save:true'));
      semantics.dispose();
    });

    testWidgets('compactLandscape: one line "Name · Saved"', (tester) async {
      await _pump(tester, surface: const EditorSurface(Size(844, 390)));
      expect(_inTopBar(find.text('Goa trip')), findsOneWidget);
      expect(_inTopBar(find.text(' · ${EditorShellStrings.saved}')), findsOneWidget);
      final name = tester.getRect(_inTopBar(find.text('Goa trip')));
      final status = tester.getRect(_inTopBar(find.text(' · ${EditorShellStrings.saved}')));
      expect(status.left, greaterThanOrEqualTo(name.right - 0.01));
    });

    testWidgets('the title button opens the project sheet binding; without it the title is plain', (tester) async {
      var opened = 0;
      await _pump(tester, bindings: {
        EditorActionId.projectSheet: EditorActionBinding(
            id: EditorActionId.projectSheet,
            handler: (ctx) {
              expect(ctx.source, EditorActionSource.button);
              expect(ctx.projectId, isNotNull);
              opened++;
            }),
      });
      expect(_inTopBar(find.byIcon(Icons.expand_more_rounded)), findsOneWidget);
      await tester.tap(_inTopBar(find.text('Goa trip')));
      await tester.pump();
      expect(opened, 1);

      await _pump(tester, bindings: const {});
      expect(_inTopBar(find.byIcon(Icons.expand_more_rounded)), findsNothing);
    });

    testWidgets('a long name ellipsizes; every control stays on screen at 280 @1.35', (tester) async {
      await _pump(tester,
          status: _ready.copyWith(projectName: 'A very long project name that never fits in the title button'),
          surface: SurfaceMatrix.narrowest);
      expectNoOverflow(tester);
      for (final label in [EditorShellStrings.closeEditor, EditorShellStrings.export]) {
        expectInside(tester, find.bySemanticsLabel(label));
      }
      expectInside(tester, find.bySemanticsLabel(RegExp('^Undo')));
      expectInside(tester, find.bySemanticsLabel(RegExp('^Redo')));
      // ux.md §6.4: at 280 the title keeps at least 84 px.
      final title = tester.getRect(_title('A very long project name that never fits in the title button'));
      expect(title.width, greaterThanOrEqualTo(84));
      expectOwnerUiRules(tester);
    });
  });

  group('undo, redo and history', () {
    testWidgets('disabled without history; enabled ones call the shell; tooltips carry label and shortcut', (tester) async {
      final (_, shell) = await _pump(tester);
      await tester.tap(find.bySemanticsLabel(RegExp('^Undo')));
      await tester.tap(find.bySemanticsLabel(RegExp('^Redo')));
      await tester.pump();
      expect(shell.calls, ['open']);
      shell.status.value = _ready.copyWith(canUndo: true, canRedo: true, undoLabel: 'Split clip', redoLabel: 'Delete clip');
      await tester.pump();
      expect(find.bySemanticsLabel('Undo Split clip (Ctrl+Z)'), findsOneWidget);
      expect(find.bySemanticsLabel('Redo Delete clip (Ctrl+Y)'), findsOneWidget);
      await tester.tap(find.bySemanticsLabel('Undo Split clip (Ctrl+Z)'));
      await tester.tap(find.bySemanticsLabel('Redo Delete clip (Ctrl+Y)'));
      await tester.pump();
      expect(shell.calls, ['open', 'undo', 'redo']);
    });

    testWidgets('Apple platforms show ⌘ shortcuts', (tester) async {
      await _pump(
        tester,
        status: _ready.copyWith(canUndo: true, canRedo: true, undoLabel: 'Trim', redoLabel: 'Trim'),
        surface: const EditorSurface(Size(390, 844), platform: TargetPlatform.iOS),
      );
      expect(find.bySemanticsLabel('Undo Trim (⌘Z)'), findsOneWidget);
      expect(find.bySemanticsLabel('Redo Trim (⇧⌘Z)'), findsOneWidget);
    });

    testWidgets('long-press on undo opens the history binding', (tester) async {
      var history = 0;
      await _pump(
        tester,
        status: _ready.copyWith(canUndo: true),
        bindings: {EditorActionId.history: EditorActionBinding(id: EditorActionId.history, handler: (_) => history++)},
      );
      await tester.longPress(find.bySemanticsLabel(RegExp('^Undo')));
      await tester.pump();
      expect(history, 1);
    });
  });

  group('close and export', () {
    testWidgets('close icon: ✕ on compact kinds, ‹ on medium and expanded', (tester) async {
      await _pump(tester);
      expect(_inTopBar(find.byIcon(Icons.close_rounded)), findsOneWidget);
      await _pump(tester, surface: const EditorSurface(Size(834, 1194), platform: TargetPlatform.iOS));
      expect(_inTopBar(find.byIcon(Icons.arrow_back_ios_new_rounded)), findsOneWidget);
    });

    testWidgets('Export: a labelled primary button at ≥ 360 px, a round icon below; runs the export binding', (tester) async {
      var exports = 0;
      final bindings = {EditorActionId.export: EditorActionBinding(id: EditorActionId.export, handler: (_) => exports++)};
      await _pump(tester, bindings: bindings);
      expect(_inTopBar(find.widgetWithText(DanaviewButton, EditorShellStrings.export)), findsOneWidget);
      await tester.tap(_inTopBar(find.text(EditorShellStrings.export)));
      await tester.pump();
      expect(exports, 1);

      await _pump(tester, bindings: bindings, surface: SurfaceMatrix.narrowest);
      expect(_inTopBar(find.widgetWithText(DanaviewButton, EditorShellStrings.export)), findsNothing);
      final icon = tester.widget<DanaviewIconButton>(_inTopBar(find.widgetWithIcon(DanaviewIconButton, Icons.upload_rounded)));
      expect(icon.variant, DanaviewIconButtonVariant.primary);
      expect(icon.tooltip, EditorShellStrings.export);
      await tester.tap(find.bySemanticsLabel(EditorShellStrings.export));
      await tester.pump();
      expect(exports, 2);
    });

    testWidgets('Export is disabled while unbound or while its binding is disabled', (tester) async {
      await _pump(tester, bindings: const {});
      expect(tester.widget<DanaviewButton>(_inTopBar(find.byType(DanaviewButton))).onPressed, isNull);
      await _pump(tester, bindings: {
        EditorActionId.export: EditorActionBinding(id: EditorActionId.export, handler: (_) => fail('disabled'), isEnabled: (_) => false),
      });
      expect(tester.widget<DanaviewButton>(_inTopBar(find.byType(DanaviewButton))).onPressed, isNull);
    });

    testWidgets('a throwing binding is reported, not fatal', (tester) async {
      await _pump(tester, bindings: {
        EditorActionId.export: EditorActionBinding(id: EditorActionId.export, handler: (_) => throw StateError('export failed')),
      });
      await tester.tap(_inTopBar(find.text(EditorShellStrings.export)));
      await tester.pump();
      expect(tester.takeException(), isA<StateError>());
      expect(find.byType(EditorScreen), findsOneWidget);
    });
  });
}
