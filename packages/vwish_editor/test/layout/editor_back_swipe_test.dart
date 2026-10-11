// OWNER: UX-07
//
// V-U3 (ARCH §24.2): `PopScope(canPop: false)` disables the iOS edge back-swipe on Flutter 3.44.
// The app's routes are MaterialPage routes with CupertinoPageTransitionsBuilder on every platform
// (VwishTheme), whose back gesture is enabled only while `ModalRoute.popGestureEnabled`, and that
// is false while a PopScope vetoes the pop. Here a real edge drag is sent at the editor route (no
// pop, no back step, no flush) and, as a control, at a plain route (it pops).
//
// V-U3 record (2026-10-11, Flutter 3.44.2, iPhone 17 Pro simulator, iOS 26.5): a scratch app with
// VwishTheme.darkTheme and MaterialPageRoutes. Plain route: a left-edge drag (touch path from
// x = 8 pt) started the user gesture and popped it ("userGestureStarted plain", "didPop plain").
// Route wrapped like EditorLifecycle in PopScope<Object?>(canPop: false): popGestureEnabled = false;
// the same touch-path drag and a simulator OS edge swipe from x = 1 pt left it on screen, with no
// user gesture, no pop and no onPopInvokedWithResult call. Result: no fallback needed.

import 'dart:async';

import 'package:flutter/material.dart' show MaterialPageRoute;
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vwish_editor/src/editor/editor_screen.dart';
import 'package:vwish_editor/src/editor/layout/editor_shell_strings.dart';
import 'package:vwish_editor/src/editor/layout/editor_top_bar.dart';

import '../support/support.dart';
import 'fake_editor_shell.dart';

const _iPhone = EditorSurface(Size(390, 844), platform: TargetPlatform.iOS);
const _iPad = EditorSurface(Size(1194, 834), platform: TargetPlatform.iOS);

/// A left-edge back swipe across most of the screen, the way a thumb does it.
Future<void> _edgeSwipe(WidgetTester tester, double width) async {
  final g = await tester.startGesture(const Offset(4, 420));
  for (var i = 0; i < 12; i++) {
    await g.moveBy(Offset(width * 0.06, 0));
    await tester.pump(const Duration(milliseconds: 16));
  }
  await g.up();
  await tester.pumpAndSettle();
}

Future<(EditorTestHarness, FakeEditorShell, NavigatorState)> _pumpHome(WidgetTester tester, EditorSurface surface) async {
  final shell = FakeEditorShell();
  final h = EditorTestHarness(overrides: [overrideShell(shell)]);
  await h.pumpApp(tester, const Center(child: Text('Home')), surface: surface);
  return (h, shell, tester.state<NavigatorState>(find.byType(Navigator).first));
}

void main() {
  for (final surface in const [_iPhone, _iPad]) {
    testWidgets('the iOS edge back-swipe does not pop the editor [$surface]', (tester) async {
      final (h, shell, navigator) = await _pumpHome(tester, surface);
      final id = h.repository.seedEmpty('Swipe').id;
      unawaited(navigator.push(MaterialPageRoute<void>(builder: (_) => EditorScreen(projectId: id, onClose: () => h.closeRequests++))));
      await tester.pumpAndSettle();
      final route = ModalRoute.of(tester.element(find.byType(EditorTopBar)))! as PageRoute<void>;
      expect(route.popGestureEnabled, isFalse, reason: 'PopScope(canPop: false) disables the Cupertino back gesture');

      await _edgeSwipe(tester, surface.size.width);

      expect(find.byType(EditorScreen), findsOneWidget);
      expect(route.isCurrent, isTrue);
      expect(find.text('Home'), findsNothing);
      expect(shell.calls, ['open'], reason: 'no back step, no flush, no close');
      expect(h.closeRequests, 0);
    });
  }

  testWidgets('control: the same swipe pops a plain route (the gesture is live)', (tester) async {
    final (_, _, navigator) = await _pumpHome(tester, _iPhone);
    unawaited(navigator
        .push(MaterialPageRoute<void>(builder: (_) => const ColoredBox(color: Color(0xFF101010), child: Center(child: Text('Plain'))))));
    await tester.pumpAndSettle();
    expect(find.text('Plain'), findsOneWidget);
    await _edgeSwipe(tester, _iPhone.size.width);
    expect(find.text('Plain'), findsNothing);
    expect(find.text('Home'), findsOneWidget);
  });

  testWidgets('the close button still leaves: the route pops after the flush', (tester) async {
    final (h, shell, navigator) = await _pumpHome(tester, _iPhone);
    final id = h.repository.seedEmpty('Swipe').id;
    unawaited(navigator
        .push(MaterialPageRoute<void>(builder: (context) => EditorScreen(projectId: id, onClose: () => Navigator.of(context).pop()))));
    await tester.pumpAndSettle();
    await tester.tap(find.bySemanticsLabel(EditorShellStrings.closeEditor));
    await tester.pumpAndSettle();
    expect(find.byType(EditorScreen), findsNothing);
    expect(find.text('Home'), findsOneWidget);
    expect(shell.calls, ['open', 'flush', 'close']);
  });
}
