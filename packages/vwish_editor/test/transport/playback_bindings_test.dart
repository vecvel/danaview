// OWNER: UX-14 / UX-15
//
// The playback actions end to end: a real EditorController on FakeEditorEngine, the real merged
// action bindings (wiring/action_bindings.dart), `EditorShortcuts` and the transport bar. Space/K,
// arrows, Shift+arrows, Up/Down, Home/End and F reach the preview, the playhead and the
// transport; the registry's built-ins (undo, redo, save) work on the real editor; focus on the
// transport's own buttons does not stop the editor keys.

import 'package:flutter/material.dart' show Icons;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vwish_editor/src/editor/actions/editor_action_registry.dart';
import 'package:vwish_editor/src/editor/actions/editor_shortcuts.dart';
import 'package:vwish_editor/src/editor/contracts/contracts.dart';
import 'package:vwish_editor/src/editor/state/editor_state.dart';
import 'package:vwish_editor/src/editor/transport/transport_bar.dart';
import 'package:vwish_editor/src/editor/wiring/action_bindings.dart';
import 'package:vwish_editor_core/model.dart';
import 'package:vwish_editor_core/ops.dart' show AddText;

import '../actions/action_test_support.dart';
import '../support/support.dart';
import 'transport_rig.dart';

/// The bar inside the editor's shortcut scope.
Widget scoped(ProjectId id) => const EditorShortcuts(child: Align(alignment: Alignment.topLeft, child: SizedBox(height: 44, child: TransportBar())));

const EditorSurface ios = EditorSurface(Size(900, 400), platform: TargetPlatform.iOS);
const EditorSurface android = EditorSurface(Size(900, 400));

void main() {
  test('the playback binding file binds exactly the ten playback actions, and the merge accepts it', () {
    final merged = mergeEditorActionBindings();
    final playback = EditorActionId.inGroup(EditorActionGroup.playback);
    expect(playback, hasLength(10));
    for (final id in playback) {
      expect(merged.containsKey(id), isTrue, reason: '${id.name} is bound');
    }
  });

  group('keys reach the transport', () {
    testWidgets('Space and K play and pause', (tester) async {
      final rig = await TransportRig.pump(tester, scoped, surface: android);
      final keys = Keys(tester, TargetPlatform.android);
      await keys.press(LogicalKeyboardKey.space);
      await rig.real(() async {});
      expect(rig.engine.calls, contains('preview.play'));
      expect(rig.transport.playing.value, isTrue);
      await keys.press(LogicalKeyboardKey.keyK);
      await rig.real(() async {});
      expect(rig.engine.calls.last, 'preview.pause');
      expect(rig.transport.playing.value, isFalse);
    });

    testWidgets('after tapping a transport button, Space still plays and does not press the button', (tester) async {
      final rig = await TransportRig.pump(tester, scoped, surface: android);
      final keys = Keys(tester, TargetPlatform.android);
      // Keyboard-focus the next-frame button, as Tab or a focusing tap would.
      final button = find.ancestor(of: find.byIcon(Icons.keyboard_arrow_right_rounded), matching: find.byType(Focus)).first;
      Focus.of(tester.element(button)).requestFocus();
      await tester.pump();
      await keys.press(LogicalKeyboardKey.space);
      await rig.real(() async {});
      expect(rig.engine.calls, contains('preview.play'));
      expect(rig.playhead.value, 0, reason: 'the focused next-frame button was not pressed by Space');
    });

    testWidgets('arrows step a frame, Shift+arrows a second, Up/Down jump edit points, Home/End go to the ends', (tester) async {
      final rig = await TransportRig.pump(tester, scoped, surface: android);
      final keys = Keys(tester, TargetPlatform.android);
      final rate = rig.playhead.frameRate;
      Future<void> press(LogicalKeyboardKey key, {bool shift = false}) async {
        await keys.press(key, shift: shift);
        await rig.real(() async {});
      }

      await press(LogicalKeyboardKey.arrowRight);
      expect(rig.playhead.value, rate.timeOfFrame(1));
      await press(LogicalKeyboardKey.arrowRight);
      expect(rig.playhead.value, rate.timeOfFrame(2));
      await press(LogicalKeyboardKey.arrowLeft);
      expect(rig.playhead.value, rate.timeOfFrame(1));
      await press(LogicalKeyboardKey.arrowRight, shift: true);
      expect(rig.playhead.value, rate.quantize(1 * s + rate.timeOfFrame(1)));
      await press(LogicalKeyboardKey.arrowLeft, shift: true);
      expect(rig.playhead.value, rate.timeOfFrame(1));
      await press(LogicalKeyboardKey.arrowDown);
      expect(rig.playhead.value, 3 * s);
      await press(LogicalKeyboardKey.arrowDown);
      expect(rig.playhead.value, 4 * s, reason: 'the marker is an edit point');
      await press(LogicalKeyboardKey.arrowUp);
      expect(rig.playhead.value, 3 * s);
      await press(LogicalKeyboardKey.end);
      expect(rig.playhead.value, 7 * s);
      await press(LogicalKeyboardKey.home);
      expect(rig.playhead.value, 0);
      expect(rig.preview.time, 0);
    });

    testWidgets('F toggles the fullscreen request', (tester) async {
      final rig = await TransportRig.pump(tester, scoped, surface: android);
      final keys = Keys(tester, TargetPlatform.android);
      await keys.press(LogicalKeyboardKey.keyF);
      expect(rig.transport.fullscreen.value, isTrue);
      await keys.press(LogicalKeyboardKey.keyF);
      expect(rig.transport.fullscreen.value, isFalse);
    });

    testWidgets('playing and pausing keep the readout and the preview in step', (tester) async {
      final rig = await TransportRig.pump(tester, scoped, surface: android);
      final keys = Keys(tester, TargetPlatform.android);
      await keys.press(LogicalKeyboardKey.space);
      await rig.real(() async {});
      rig.time.advance(const Duration(milliseconds: 500));
      rig.preview.advanceFrames(15);
      await rig.real(() async {});
      rig.frames.tick();
      await tester.pump();
      expect(rig.playhead.value, rig.playhead.frameRate.timeOfFrame(15));
      await keys.press(LogicalKeyboardKey.space);
      await rig.real(() async {});
      expect(rig.playhead.value, rig.playhead.frameRate.timeOfFrame(15));
      // The settled position is written to the project's view state (not per frame).
      expect(rig.editor.session.committedProject!.view.playhead, rig.playhead.value);
    });

    testWidgets('an empty project: Space does nothing and frame steps stay at the start', (tester) async {
      final rig = await TransportRig.pump(tester, scoped, surface: android, project: false);
      final keys = Keys(tester, TargetPlatform.android);
      await keys.press(LogicalKeyboardKey.space);
      await keys.press(LogicalKeyboardKey.arrowRight);
      await rig.real(() async {});
      expect(rig.engine.calls, isNot(contains('preview.play')));
      expect(rig.playhead.value, 0);
    });

    testWidgets('keys do nothing before the editor is open', (tester) async {
      final rig = await TransportRig.pump(tester, scoped, surface: android, open: false);
      final keys = Keys(tester, TargetPlatform.android);
      await keys.press(LogicalKeyboardKey.space);
      await keys.press(LogicalKeyboardKey.arrowRight);
      expect(rig.engine.calls, isEmpty);
    });
  });

  group('registry built-ins on the real editor', () {
    testWidgets('⌘Z, ⌘⇧Z and ⌘S undo, redo and save the project', (tester) async {
      final rig = await TransportRig.pump(tester, scoped, surface: ios);
      final keys = Keys(tester, TargetPlatform.iOS);
      rig.editor.apply(const AddText(8 * s));
      await tester.pump();
      expect(rig.editor.state.history.canUndo, isTrue);
      await keys.press(LogicalKeyboardKey.keyZ, command: true);
      expect(rig.editor.state.history.canUndo, isFalse);
      expect(rig.editor.state.history.canRedo, isTrue);
      await keys.press(LogicalKeyboardKey.keyZ, command: true, shift: true);
      expect(rig.editor.state.history.canRedo, isFalse);
      await keys.press(LogicalKeyboardKey.keyS, command: true);
      await rig.real(() async {});
      expect(rig.harness.repository.calls, contains('save'));
      expect(rig.editor.state.save.phase, SavePhase.saved);
    });

    testWidgets('Ctrl+Y redoes off Apple platforms', (tester) async {
      final rig = await TransportRig.pump(tester, scoped, surface: android);
      final keys = Keys(tester, TargetPlatform.android);
      rig.editor.apply(const AddText(8 * s));
      rig.editor.undo();
      await tester.pump();
      await keys.press(LogicalKeyboardKey.keyY, command: true);
      expect(rig.editor.state.history.canRedo, isFalse);
      expect(rig.editor.state.history.canUndo, isTrue);
    });

    testWidgets('undo with nothing to undo is disabled with a reason', (tester) async {
      final rig = await TransportRig.pump(tester, scoped, surface: android);
      final ctx = WidgetActionContext.container(projectId: rig.id, context: tester.element(find.byType(TransportBar)), container: rig.container);
      final registry = rig.container.read(editorActionRegistryProvider);
      expect(registry.spec(EditorActionId.undo).isEnabled(ctx), isFalse);
      expect(registry.spec(EditorActionId.undo).disabledReason(ctx), EditorActionStrings.nothingToUndo);
      expect(registry.spec(EditorActionId.playPause).isEnabled(ctx), isTrue);
      expect(registry.spec(EditorActionId.playPause).disabledReason(ctx), isNull);
    });
  });
}
