// OWNER: UX-07
//
// EditorLifecycle (ux.md §4.7, ARCH §17.6): the back order (cancel gesture -> close panel -> clear
// selection -> exit fullscreen -> close with a flush), the close button, the flush timeout and
// "Leave anyway?", the opening/unknown phases, app lifecycle saves, memory pressure, orientation
// and the release of the session when the route goes away.

import 'dart:async';

import 'package:flutter/material.dart' show MaterialPageRoute;
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_editor/src/editor/editor_screen.dart';
import 'package:danaview_editor/src/editor/layout/editor_shell_strings.dart';
import 'package:danaview_editor/src/editor/layout/editor_top_bar.dart';
import 'package:danaview_features/orientation.dart';

import '../support/support.dart';
import 'fake_editor_shell.dart';

Future<(EditorTestHarness, FakeEditorShell)> _pump(WidgetTester tester,
    {FakeEditorShell? shell, EditorSurface surface = SurfaceMatrix.phone}) async {
  final s = shell ?? FakeEditorShell();
  final h = EditorTestHarness(overrides: [overrideShell(s)]);
  await h.pumpEditor(tester, surface: surface, initialPlayhead: 2000000);
  return (h, s);
}

EditorBackDispatcher _dispatcher(WidgetTester tester) => EditorBackDispatcher.of(tester.element(find.byType(EditorTopBar)));

/// The system back button (Android back, predictive back commit).
Future<void> _systemBack(WidgetTester tester) async {
  await tester.binding.handlePopRoute();
  await tester.pump();
}

Future<void> _tapClose(WidgetTester tester) async {
  await tester.tap(find.bySemanticsLabel(EditorShellStrings.closeEditor));
  await tester.pump();
}

void main() {
  setUp(ScreenOrientationPolicy.resetForTesting);

  group('back order', () {
    testWidgets('system back: cancel gesture -> close panel -> clear selection -> exit fullscreen -> close with flush', (tester) async {
      final (h, shell) = await _pump(tester);
      shell.dismissible.addAll(EditorBackStep.values);
      for (final step in EditorBackStep.values) {
        await _systemBack(tester);
        expect(shell.dismissed.last, step);
        expect(h.closeRequests, 0);
        expect(shell.calls, isNot(contains('flush')));
      }
      expect(shell.dismissed, EditorBackStep.values);
      await _systemBack(tester);
      expect(shell.calls.where((c) => !c.startsWith('dismiss:')), ['open', 'flush', 'close']);
      expect(h.closeRequests, 1);
      expect(find.byType(EditorScreen), findsOneWidget, reason: 'the router pops it through onClose');
    });

    testWidgets('handleBack returns the dismissed step, or null when the editor closes', (tester) async {
      final (h, shell) = await _pump(tester);
      shell.dismissible.addAll({EditorBackStep.clearSelection});
      expect(await _dispatcher(tester).handleBack(), EditorBackStep.clearSelection);
      expect(await _dispatcher(tester).handleBack(), isNull);
      await tester.pump();
      expect(h.closeRequests, 1);
    });

    testWidgets('registered region handlers run before the delegate for their step, newest first', (tester) async {
      final (_, shell) = await _pump(tester);
      final order = <String>[];
      final d = _dispatcher(tester);
      final unregisterA = d.register(EditorBackStep.cancelGesture, () {
        order.add('a');
        return false;
      });
      final unregisterB = d.register(EditorBackStep.cancelGesture, () {
        order.add('b');
        return true;
      });
      expect(await d.handleBack(), EditorBackStep.cancelGesture);
      expect(order, ['b']);
      expect(shell.calls, isNot(contains('dismiss:cancelGesture')));
      unregisterB();
      shell.dismissible.add(EditorBackStep.closePanel);
      expect(await d.handleBack(), EditorBackStep.closePanel);
      expect(order, ['b', 'a']);
      expect(shell.calls, containsAllInOrder(['dismiss:cancelGesture', 'dismiss:closePanel']));
      unregisterA();
      // UX-18 registers "leave fullscreen" the same way.
      var fullscreen = true;
      d.register(EditorBackStep.exitFullscreen, () {
        final was = fullscreen;
        fullscreen = false;
        return was;
      });
      expect(await d.handleBack(), EditorBackStep.exitFullscreen);
      expect(fullscreen, isFalse);
    });

    testWidgets('the close button skips the dismiss steps', (tester) async {
      final (h, shell) = await _pump(tester);
      shell.dismissible.addAll(EditorBackStep.values);
      await _tapClose(tester);
      expect(shell.calls, ['open', 'flush', 'close']);
      expect(h.closeRequests, 1);
    });

    testWidgets('while closing: "Saving…", undo/redo disabled, further back presses ignored', (tester) async {
      final (h, shell) = await _pump(tester,
          shell: FakeEditorShell(
              status: const EditorShellStatus(phase: EditorShellPhase.ready, projectName: 'Goa trip', canUndo: true, canRedo: true)));
      shell.flushResult = null;
      await _tapClose(tester);
      expect(find.text(EditorShellStrings.saving), findsOneWidget);
      expect(_dispatcher(tester).closing.value, isTrue);
      await tester.tap(find.bySemanticsLabel(RegExp('^Undo')));
      await tester.pump();
      expect(shell.calls, isNot(contains('undo')));
      await _systemBack(tester);
      expect(shell.count('flush'), 1);
      shell.flushCompleter.complete(true);
      await tester.pump();
      await tester.pump();
      expect(shell.calls.last, 'close');
      expect(h.closeRequests, 1);
    });

    testWidgets('a failed flush asks "Leave anyway?": Stay keeps the editor, Leave closes it', (tester) async {
      final (h, shell) = await _pump(tester);
      shell.flushResult = false;
      await _tapClose(tester);
      await tester.pumpAndSettle();
      expect(find.text(EditorShellStrings.leaveTitle), findsOneWidget);
      expect(find.text(EditorShellStrings.leaveMessage), findsOneWidget);
      expectNoOverflow(tester);
      expectOwnerUiRules(tester);
      await tester.tap(find.text(EditorShellStrings.stay));
      await tester.pumpAndSettle();
      expect(find.text(EditorShellStrings.leaveTitle), findsNothing);
      expect(shell.calls, isNot(contains('close')));
      expect(h.closeRequests, 0);
      expect(_dispatcher(tester).closing.value, isFalse);
      expect(find.text(EditorShellStrings.saving), findsNothing);

      await _tapClose(tester);
      await tester.pumpAndSettle();
      await tester.tap(find.text(EditorShellStrings.leave));
      await tester.pumpAndSettle();
      expect(shell.calls.where((c) => c == 'flush' || c == 'close'), ['flush', 'flush', 'close']);
      expect(h.closeRequests, 1);
    });

    testWidgets('a flush slower than 3 s counts as failed', (tester) async {
      final (h, shell) = await _pump(tester);
      shell.flushResult = null;
      await _tapClose(tester);
      await tester.pump(const Duration(milliseconds: 2900));
      expect(find.text(EditorShellStrings.leaveTitle), findsNothing);
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pumpAndSettle();
      expect(find.text(EditorShellStrings.leaveTitle), findsOneWidget);
      await tester.tap(find.text(EditorShellStrings.leave));
      await tester.pumpAndSettle();
      expect(h.closeRequests, 1);
      shell.flushCompleter.complete(true);
    });

    testWidgets('while opening, back closes without dismiss steps', (tester) async {
      final (h, shell) = await _pump(tester, shell: FakeEditorShell(status: EditorShellStatus.opening));
      shell.dismissible.addAll(EditorBackStep.values);
      await _systemBack(tester);
      expect(shell.calls, ['open', 'flush', 'close']);
      expect(h.closeRequests, 1);
    });

    testWidgets('an unknown project leaves without a flush', (tester) async {
      final (h, shell) = await _pump(tester, shell: FakeEditorShell(status: const EditorShellStatus(phase: EditorShellPhase.notFound)));
      await _systemBack(tester);
      expect(shell.calls, ['open', 'close']);
      expect(h.closeRequests, 1);
    });

    testWidgets('PopScope blocks the pop until the close flow allows it; onExit may then maybePop', (tester) async {
      final shell = FakeEditorShell();
      final h = EditorTestHarness(overrides: [overrideShell(shell)]);
      final navigator = GlobalKey<NavigatorState>();
      await h.pumpApp(
        tester,
        Navigator(
          key: navigator,
          onGenerateRoute: (_) => MaterialPageRoute<void>(builder: (_) => const Text('Home')),
        ),
      );
      unawaited(navigator.currentState!.push(MaterialPageRoute<void>(
        builder: (context) => EditorScreen(projectId: h.repository.seedEmpty('P').id, onClose: () => Navigator.of(context).maybePop()),
      )));
      await tester.pumpAndSettle();
      expect(tester.widget<PopScope<Object?>>(find.byType(PopScope<Object?>)).canPop, isFalse);
      // maybePop from outside (what the system back does) is vetoed and becomes a back press.
      shell.dismissible.add(EditorBackStep.closePanel);
      expect(await navigator.currentState!.maybePop(), isTrue);
      await tester.pumpAndSettle();
      expect(find.byType(EditorScreen), findsOneWidget);
      expect(shell.dismissed, [EditorBackStep.closePanel]);
      // The close flow lets the route go: onClose's maybePop now pops it.
      await _tapClose(tester);
      await tester.pumpAndSettle();
      expect(find.byType(EditorScreen), findsNothing);
      expect(find.text('Home'), findsOneWidget);
      expect(shell.calls.where((c) => c == 'flush' || c == 'close'), ['flush', 'close']);
    });
  });

  group('app lifecycle', () {
    testWidgets('inactive cancels gestures and requests an autosave; hidden flushes; resumed refreshes', (tester) async {
      final (_, shell) = await _pump(tester);
      var cancelled = 0;
      _dispatcher(tester).register(EditorBackStep.cancelGesture, () {
        cancelled++;
        return true;
      });
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      expect(cancelled, 1);
      expect(shell.calls.last, 'inactive');
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      expect(shell.calls.last, 'hidden');
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      expect(shell.calls.last, 'resumed');
      expect(shell.calls.where((c) => c == 'hidden'), hasLength(1), reason: 'one flush per trip to the background');
      tester.binding.handleMemoryPressure();
      expect(shell.calls.last, 'memory');
      expect(shell.calls, isNot(contains('close')), reason: 'the session survives the background');
    });

    testWidgets('a delegate that throws in a lifecycle hook is reported, not fatal', (tester) async {
      final shell = _ThrowingShell();
      final h = EditorTestHarness(overrides: [overrideShell(shell)]);
      await h.pumpEditor(tester);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      expect(tester.takeException(), isA<StateError>());
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      expect(find.byType(EditorScreen), findsOneWidget);
    });
  });

  group('route lifetime', () {
    testWidgets('opens once with the initial playhead; orientation is free while mounted', (tester) async {
      final (_, shell) = await _pump(tester);
      expect(shell.calls.where((c) => c == 'open'), hasLength(1));
      expect(shell.openedAt, 2000000);
      expect(ScreenOrientationPolicy.depth, 1);
      expect(ScreenOrientationPolicy.topMode, OrientationMode.free);
      await tester.pumpWidget(const SizedBox());
      expect(ScreenOrientationPolicy.depth, 0);
    });

    testWidgets('removing the route without the close flow still releases the session once', (tester) async {
      final (h, shell) = await _pump(tester);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      expect(shell.calls.where((c) => c == 'close'), hasLength(1));
      expect(shell.calls, isNot(contains('flush')), reason: 'close() flushes on its own');
      expect(h.closeRequests, 0);
    });

    testWidgets('after the close flow, disposal does not close the session again', (tester) async {
      final (_, shell) = await _pump(tester);
      await _tapClose(tester);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      expect(shell.calls.where((c) => c == 'close'), hasLength(1));
    });
  });
}

class _ThrowingShell extends FakeEditorShell {
  @override
  void onAppInactive() => throw StateError('boom');
}
