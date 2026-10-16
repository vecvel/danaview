// OWNER: UX-07
//
// FIX-UX-07 (QA-01 blockers FIX-UX-07-1 and FIX-UX-07-2): the editor screen mounts the editor's
// keyboard shortcuts (UX-15's EditorShortcuts, ARCH §17.6) and the project health banners (UX-40's
// EditorHealthHost, ux.md §13). Driven through the real EditorScreen, the real EditorController
// and the real merged action bindings.

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_editor/src/editor/actions/editor_shortcuts.dart';
import 'package:danaview_editor/src/editor/actions/shortcuts_sheet.dart';
import 'package:danaview_editor/src/editor/editor_screen.dart';
import 'package:danaview_editor/src/editor/flows/relink/editor_health_host.dart';
import 'package:danaview_editor/src/editor/preview/preview_region.dart';
import 'package:danaview_editor/src/editor/state/editor_state.dart' show EditorPhase;
import 'package:danaview_editor_core/store.dart' show MediaAvailability;

import '../actions/action_test_support.dart' show Keys;
import '../flows/relink/relink_support.dart';
import '../support/support.dart';

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

/// Pumps the real editor screen for a project with two clips and waits until it is open.
Future<RelinkRig> _pumpOpenEditor(WidgetTester tester, {EditorSurface surface = SurfaceMatrix.phone}) async {
  final rig = RelinkRig([videoAsset('md_1'), videoAsset('md_2')]);
  await rig.harness.pumpEditor(tester, projectId: rig.id, surface: surface);
  rig.useContainer(rig.harness.containerOf(tester));
  for (var i = 0; i < 4; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
    await tester.pump();
  }
  await _settle(tester);
  expect(rig.editor.state.phase, EditorPhase.ready, reason: 'the screen opened the project');
  return rig;
}

void main() {
  group('keyboard shortcuts (FIX-UX-07-1)', () {
    testWidgets('the screen mounts EditorShortcuts around the editor, below its scope', (tester) async {
      await _pumpOpenEditor(tester);
      expect(find.byType(EditorShortcuts), findsOneWidget);
      expect(find.descendant(of: find.byType(EditorShortcuts), matching: find.byType(PreviewRegion)), findsWidgets);
    });

    testWidgets('Space plays and pauses the preview from the screen', (tester) async {
      final rig = await _pumpOpenEditor(tester);
      final keys = Keys(tester, TargetPlatform.android);
      await keys.press(LogicalKeyboardKey.space);
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump();
      expect(rig.harness.engine.calls, contains('preview.play'));
      await keys.press(LogicalKeyboardKey.space);
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump();
      expect(rig.harness.engine.calls.last, 'preview.pause');
    });

    testWidgets('⌘/ (Command on iOS) opens the shortcuts sheet from the screen', (tester) async {
      await _pumpOpenEditor(tester, surface: const EditorSurface(Size(1194, 834), platform: TargetPlatform.iOS));
      expect(find.byType(ShortcutsSheet), findsNothing);
      await Keys(tester, TargetPlatform.iOS).press(LogicalKeyboardKey.slash, command: true);
      await _settle(tester);
      expect(find.byType(ShortcutsSheet), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('S splits the clip under the playhead (one history entry) from the screen', (tester) async {
      final rig = await _pumpOpenEditor(tester);
      final keys = Keys(tester, TargetPlatform.android);
      // Two frames in, inside the first clip.
      await keys.press(LogicalKeyboardKey.arrowRight);
      await keys.press(LogicalKeyboardKey.arrowRight);
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump();
      final before = rig.editor.state.project!.tracks.expand((t) => t.items).length;
      await keys.press(LogicalKeyboardKey.keyS);
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      await _settle(tester);
      final after = rig.editor.state.project!.tracks.expand((t) => t.items).length;
      expect(after, before + 1);
      expect(rig.editor.state.history.canUndo, isTrue);
    });
  });

  group('health banner (FIX-UX-07-2)', () {
    testWidgets('the screen mounts EditorHealthHost; the banner appears for offline media', (tester) async {
      final rig = await _pumpOpenEditor(tester);
      expect(find.byType(EditorHealthHost), findsOneWidget);
      expect(find.byKey(const ValueKey('missing-media-banner')), findsNothing);
      await tester.runAsync(() => rig.report({'md_2': MediaAvailability.missing}));
      await _settle(tester);
      final banner = find.byKey(const ValueKey('missing-media-banner'));
      expect(banner, findsOneWidget);
      expect(find.byKey(const ValueKey('missing-media-relink')), findsOneWidget);
      // Under the top bar, inside the screen.
      final screen = tester.getRect(find.byType(EditorScreen));
      final rect = tester.getRect(banner);
      expect(screen.contains(rect.topLeft) && screen.contains(rect.bottomRight - const Offset(1, 1)), isTrue);
      expect(tester.takeException(), isNull);
      // Back online: the banner goes.
      await tester.runAsync(() => rig.report({}));
      await _settle(tester);
      expect(banner, findsNothing);
    });

    for (final surface in [SurfaceMatrix.narrowest, const EditorSurface(Size(568, 320), textScale: 1.35)]) {
      testWidgets('the banner does not overflow at ${surface.size.width.toInt()}x${surface.size.height.toInt()} @${surface.textScale}', (tester) async {
        final rig = await _pumpOpenEditor(tester, surface: surface);
        await tester.runAsync(() => rig.report({'md_1': MediaAvailability.missing, 'md_2': MediaAvailability.missing}));
        await _settle(tester);
        expect(find.byKey(const ValueKey('missing-media-banner')), findsOneWidget);
        expectNoOverflow(tester);
      });
    }
  });
}
