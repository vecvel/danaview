// OWNER: FIX-M1
//
// FIX-M1 (QA-02 M-1): the close flush is tier-aware (high 4 s, mid 6 s, low 8 s, minimal 10 s),
// shows "Saving…" while it runs, and never abandons the save: a flush still running at the timeout
// asks "Still saving your latest changes", that dialog leaves on its own once the save lands,
// turns into "Couldn't save" when it fails, and "Leave" lets the save finish in the background.
// The controller's flushBeforeClose times out without cancelling the save, and a second call
// joins the running one.

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_editor/src/app/editor_providers.dart';
import 'package:danaview_editor/src/app/editor_tier_defaults.dart';
import 'package:danaview_editor/src/editor/editor_lifecycle.dart';
import 'package:danaview_editor/src/editor/editor_screen.dart';
import 'package:danaview_editor/src/editor/layout/editor_shell_strings.dart';
import 'package:danaview_editor/src/editor/state/editor_controller.dart';
import 'package:danaview_editor/src/editor/state/editor_session.dart';
import 'package:danaview_editor/src/editor/state/editor_state.dart';
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_editor_core/ops.dart' hide MediaUnavailable;
import 'package:danaview_editor_core/store.dart';
import 'package:danaview_editor_engine_api/danaview_editor_engine_api.dart' show DeviceTier;
import 'package:danaview_features/orientation.dart';

import '../state/state_support.dart';
import '../support/support.dart';
import 'fake_editor_shell.dart';

const _saving = EditorShellStatus(phase: EditorShellPhase.ready, projectName: 'Goa trip', save: EditorSaveIndicator.saving);

Future<(EditorTestHarness, FakeEditorShell)> _pump(WidgetTester tester, {DeviceTier? tier, EditorShellStatus status = _saving}) async {
  final shell = FakeEditorShell(status: status)..flushResult = null;
  final h = EditorTestHarness(overrides: [
    overrideShell(shell),
    if (tier != null) editorTierDefaultsProvider.overrideWithValue(EditorTierDefaults(tier)),
  ]);
  await h.pumpEditor(tester, surface: SurfaceMatrix.phone);
  return (h, shell);
}

Future<void> _tapClose(WidgetTester tester) async {
  await tester.tap(find.bySemanticsLabel(EditorShellStrings.closeEditor));
  await tester.pump();
}

/// Waits out [timeout] and lets the dialog come up.
Future<void> _outlive(WidgetTester tester, Duration timeout) async {
  await tester.pump(timeout + const Duration(milliseconds: 100));
  await tester.pumpAndSettle();
}

/// A store whose saves wait for [hold] while it is set.
class _HoldingRepository extends FakeProjectRepository {
  final List<SaveReason> reasons = [];
  Completer<void>? hold;

  @override
  Future<SaveReceipt> save(EditSession session, {required SaveReason reason}) async {
    reasons.add(reason);
    final h = hold;
    if (h != null) await h.future;
    return super.save(session, reason: reason);
  }
}

EditProject _textProject(FakeProjectRepository repo) {
  final empty = repo.seedEmpty('Trip');
  final s = EditSession(empty, ids: SeededIdGenerator(11));
  expect(s.apply(const AddText(0)).changed, isTrue);
  repo.seed(s.committedProject);
  return s.committedProject;
}

void main() {
  setUp(ScreenOrientationPolicy.resetForTesting);

  group('tier-aware timeout', () {
    test('longer on slower tiers', () {
      expect(EditorLifecycle.flushTimeoutFor(DeviceTier.high), const Duration(seconds: 4));
      expect(EditorLifecycle.flushTimeoutFor(DeviceTier.mid), const Duration(seconds: 6));
      expect(EditorLifecycle.flushTimeoutFor(DeviceTier.low), const Duration(seconds: 8));
      expect(EditorLifecycle.flushTimeoutFor(DeviceTier.minimal), const Duration(seconds: 10));
      expect(EditorLifecycle.defaultFlushTimeout, EditorLifecycle.flushTimeoutFor(DeviceTier.mid));
      for (final t in DeviceTier.values) {
        expect(EditorLifecycle.flushTimeoutFor(t), greaterThan(const Duration(seconds: 3)), reason: 'QA-02 M-1: 3 s raced the save');
      }
    });

    for (final tier in DeviceTier.values) {
      testWidgets('the editor screen waits the ${tier.name} timeout with "Saving…" before it asks', (tester) async {
        final (h, shell) = await _pump(tester, tier: tier);
        final timeout = EditorLifecycle.flushTimeoutFor(tier);
        expect(tester.widget<EditorLifecycle>(find.byType(EditorLifecycle)).flushTimeout, timeout);
        await _tapClose(tester);
        await tester.pump(timeout - const Duration(milliseconds: 100));
        expect(find.text(EditorShellStrings.saving), findsOneWidget);
        expect(find.text(EditorShellStrings.stillSavingTitle), findsNothing);
        await _outlive(tester, const Duration(milliseconds: 100));
        expect(find.text(EditorShellStrings.stillSavingTitle), findsOneWidget);
        // Landing closes the dialog and the editor on its own.
        shell.flushCompleter.complete(true);
        shell.status.value = _saving.copyWith(save: EditorSaveIndicator.saved);
        await tester.pumpAndSettle();
        expect(h.closeRequests, 1);
      });
    }

    test('the controller of the provider uses the tier timeout', () {
      for (final tier in [DeviceTier.low, DeviceTier.minimal]) {
        final h = EditorTestHarness(overrides: [editorTierDefaultsProvider.overrideWithValue(EditorTierDefaults(tier))]);
        final c = h.container();
        final id = h.repository.seedEmpty('P').id;
        final sub = c.listen(editorControllerProvider(id).notifier, (_, __) {});
        expect(sub.read().flushTimeout, EditorLifecycle.flushTimeoutFor(tier));
        sub.close();
        c.dispose();
      }
    });
  });

  group('"Still saving"', () {
    testWidgets('shows the still-saving copy, passes the owner UI rules, and leaves once the save lands', (tester) async {
      final (h, shell) = await _pump(tester);
      await _tapClose(tester);
      await _outlive(tester, EditorLifecycle.defaultFlushTimeout);
      expect(find.text(EditorShellStrings.stillSavingTitle), findsOneWidget);
      expect(find.text(EditorShellStrings.stillSavingMessage), findsOneWidget);
      expect(find.text(EditorShellStrings.leaveTitle), findsNothing);
      expectNoOverflow(tester);
      expectOwnerUiRules(tester);
      expect(shell.calls, isNot(contains('close')), reason: 'the session stays while it saves');
      shell.flushCompleter.complete(true);
      await tester.pumpAndSettle();
      expect(find.text(EditorShellStrings.stillSavingTitle), findsNothing);
      expect(shell.calls.where((c) => c == 'flush' || c == 'close'), ['flush', 'close']);
      expect(h.closeRequests, 1);
    });

    testWidgets('the status landing (controller timed out first) also leaves', (tester) async {
      final (h, shell) = await _pump(tester);
      // The controller gave up waiting (false) while its save still runs.
      shell.flushResult = false;
      await _tapClose(tester);
      await tester.pumpAndSettle();
      expect(find.text(EditorShellStrings.stillSavingTitle), findsOneWidget);
      shell.status.value = _saving.copyWith(save: EditorSaveIndicator.saved);
      await tester.pumpAndSettle();
      expect(find.text(EditorShellStrings.stillSavingTitle), findsNothing);
      expect(h.closeRequests, 1);
    });

    testWidgets('a save that fails meanwhile turns the dialog into "Couldn\'t save"', (tester) async {
      final (h, shell) = await _pump(tester);
      await _tapClose(tester);
      await _outlive(tester, EditorLifecycle.defaultFlushTimeout);
      shell.status.value = _saving.copyWith(save: EditorSaveIndicator.failed);
      shell.flushCompleter.complete(false);
      await tester.pumpAndSettle();
      expect(find.text(EditorShellStrings.stillSavingTitle), findsNothing);
      expect(find.text(EditorShellStrings.leaveTitle), findsOneWidget);
      expect(find.text(EditorShellStrings.leaveMessage), findsOneWidget);
      expectNoOverflow(tester);
      expect(h.closeRequests, 0);
      await tester.tap(find.text(EditorShellStrings.stay));
      await tester.pumpAndSettle();
      expect(h.closeRequests, 0);
      expect(shell.calls, isNot(contains('close')));
    });

    testWidgets('Stay keeps the editor and the save running; the indicator keeps "Saving…"', (tester) async {
      final (h, shell) = await _pump(tester);
      await _tapClose(tester);
      await _outlive(tester, EditorLifecycle.defaultFlushTimeout);
      await tester.tap(find.text(EditorShellStrings.stay));
      await tester.pumpAndSettle();
      expect(find.text(EditorShellStrings.stillSavingTitle), findsNothing);
      expect(h.closeRequests, 0);
      expect(shell.calls, isNot(contains('close')));
      // The save landing later does not close the editor (the user chose to stay).
      shell.flushCompleter.complete(true);
      shell.status.value = _saving.copyWith(save: EditorSaveIndicator.saved);
      await tester.pumpAndSettle();
      expect(h.closeRequests, 0);
    });

    testWidgets('Leave exits at once while the save finishes in the background', (tester) async {
      final inner = FakeEditorShell(status: _saving)..flushResult = null;
      var closeDone = false;
      final closeGate = Completer<void>();
      final slow = _SlowCloseShell(inner, closeGate.future, () => closeDone = true);
      final h = EditorTestHarness(overrides: [editorShellProvider.overrideWith((ref, id) => slow)]);
      await h.pumpEditor(tester, surface: SurfaceMatrix.phone);
      await _tapClose(tester);
      await _outlive(tester, EditorLifecycle.defaultFlushTimeout);
      await tester.tap(find.text(EditorShellStrings.leave));
      await tester.pumpAndSettle();
      expect(h.closeRequests, 1, reason: 'the user is not kept waiting for the release');
      expect(slow.closeCalls, 1, reason: 'the session is still released (after the save)');
      expect(closeDone, isFalse);
      closeGate.complete();
      inner.flushCompleter.complete(true);
      await tester.pumpAndSettle();
      expect(closeDone, isTrue);
    });

    testWidgets('a custom confirm gets the request', (tester) async {
      final shell = FakeEditorShell(status: _saving)..flushResult = null;
      EditorLeaveRequest? got;
      final h = EditorTestHarness();
      await h.pumpApp(
        tester,
        EditorLifecycle(
          delegate: shell,
          onExit: () => h.closeRequests++,
          flushTimeout: const Duration(seconds: 1),
          confirmLeave: (context, request) async {
            got = request;
            return false;
          },
          child: Builder(
            builder: (context) => GestureDetector(
              onTap: () => EditorBackDispatcher.of(context).requestClose(),
              child: const Text('close'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('close'));
      await tester.pump(const Duration(milliseconds: 1100));
      expect(got, isNotNull);
      expect(got!.stillSaving, isTrue);
      shell.flushCompleter.complete(true);
      expect(await got!.flush, isTrue);
      await tester.pumpAndSettle();
      expect(h.closeRequests, 0);
    });
  });

  group('controller', () {
    test('flushBeforeClose stops waiting at the timeout but the save keeps going and lands', () async {
      final repo = _HoldingRepository()..hold = Completer<void>();
      final project = _textProject(repo);
      final rig = ControllerRig(repository: repo, id: project.id);
      final c = EditorController(
        id: project.id,
        session: EditorSession(project.id),
        repository: repo,
        engine: rig.engine,
        frames: ManualFrames(),
        flushTimeout: const Duration(milliseconds: 50),
      );
      await c.open();
      c.apply(const AddMarker(0));
      expect(await c.flushBeforeClose(), isFalse);
      expect(c.state.save.phase, SavePhase.saving, reason: 'the shell reads this as "still saving"');
      expect(c.shellStatus.value.save, EditorSaveIndicator.saving);
      // A second call while it runs joins it: no second full save.
      expect(await c.flushBeforeClose(), isFalse);
      expect(repo.reasons, [SaveReason.close]);
      repo.hold!.complete();
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(c.state.save.phase, SavePhase.saved);
      expect(c.shellStatus.value.save, EditorSaveIndicator.saved);
      final out = await c.close();
      expect(out.saved, isTrue);
      expect(repo.reasons, [SaveReason.close], reason: 'nothing left to save on close');
    });

    test('an edit after a running close flush starts a new save', () async {
      final repo = _HoldingRepository()..hold = Completer<void>();
      final project = _textProject(repo);
      final rig = ControllerRig(repository: repo, id: project.id);
      final c = EditorController(
        id: project.id,
        session: EditorSession(project.id),
        repository: repo,
        engine: rig.engine,
        frames: ManualFrames(),
        flushTimeout: const Duration(milliseconds: 50),
      );
      await c.open();
      c.apply(const AddMarker(0));
      expect(await c.flushBeforeClose(), isFalse);
      c.apply(const AddMarker(1000000));
      final second = c.flushBeforeClose();
      repo.hold!.complete();
      expect(await second, isTrue);
      expect(repo.reasons, [SaveReason.close, SaveReason.close]);
      await c.close();
    });
  });
}

/// [inner] with a close() that waits for [gate].
class _SlowCloseShell extends FakeEditorShell {
  _SlowCloseShell(this.inner, this.gate, this.onClosed) : super(status: _saving);

  final FakeEditorShell inner;
  final Future<void> gate;
  final void Function() onClosed;
  int closeCalls = 0;

  @override
  Future<bool> flushBeforeClose() => inner.flushBeforeClose();

  @override
  Future<void> close() async {
    closeCalls++;
    await gate;
    onClosed();
  }
}
