// OWNER: UX-12
//
// Touch multi-select mode (ux.md §8.9): "Select multiple" from the long-press menu starts it, taps
// add and remove clips, the banner counts them and selects all on the lane, and Done or Esc ends
// it. The banner fits narrow screens at large text.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vwish_editor/src/editor/editor_lifecycle.dart';
import 'package:vwish_editor/src/editor/timeline/timeline_view.dart';
import 'package:vwish_editor_core/model.dart';

import '../../layout/fake_editor_shell.dart';
import '../../support/support.dart';
import 'gesture_support.dart';

void main() {
  Future<void> enterMode(WidgetTester tester, TimelineRig t) async {
    await tester.longPressAt(t.at(tester, 2 * s, 'tr_main'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text(TimelineViewStrings.selectMultiple));
    await tester.pump(const Duration(milliseconds: 300));
    expect(t.state.modes.multiSelect, isTrue);
  }

  testWidgets('taps add and remove clips; Done ends the mode', (tester) async {
    final t = await pumpTimeline(tester);
    await enterMode(tester, t);
    expect(t.state.selection.items, {const ItemId('it_a')});
    expect(find.text('1 selected'), findsOneWidget);

    await tester.tapAt(t.at(tester, 6 * s, 'tr_main'));
    await tester.pump();
    await tester.tapAt(t.at(tester, 2 * s, 'tr_ov'));
    await tester.pump();
    expect(t.state.selection.items, {const ItemId('it_a'), const ItemId('it_b'), const ItemId('it_o')});
    expect(find.text('3 selected'), findsOneWidget);

    await tester.tapAt(t.at(tester, 2 * s, 'tr_main'));
    await tester.pump();
    expect(t.state.selection.items, {const ItemId('it_b'), const ItemId('it_o')});
    expect(find.text('2 selected'), findsOneWidget);

    // An empty lane keeps the selection in this mode.
    await tester.tapAt(t.at(tester, 13 * s, 'tr_music'));
    await tester.pump();
    expect(t.state.selection.items, hasLength(2));

    await tester.tap(find.text(TimelineViewStrings.done));
    await tester.pump();
    expect(t.state.modes.multiSelect, isFalse);
    expect(find.text('2 selected'), findsNothing);
    expect(t.state.selection.items, hasLength(2), reason: 'Done keeps what was selected');

    // Back to single selection: a tap replaces.
    await tester.tapAt(t.at(tester, 12 * s, 'tr_main'));
    await tester.pump();
    expect(t.state.selection.items, {const ItemId('it_c')});
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('Select all on track selects the lane of the last tapped clip', (tester) async {
    final t = await pumpTimeline(tester);
    await enterMode(tester, t);
    await tester.tap(find.text(TimelineViewStrings.selectAllOnTrack));
    await tester.pump();
    expect(t.state.selection.items, {const ItemId('it_a'), const ItemId('it_b'), const ItemId('it_c')});
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('Esc ends the mode', (tester) async {
    final t = await pumpTimeline(tester);
    await enterMode(tester, t);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(t.state.modes.multiSelect, isFalse);
    expect(t.state.selection.items, {const ItemId('it_a')});
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('back: cancels a drag first, then leaves the mode before the selection is cleared', (tester) async {
    final shell = FakeEditorShell();
    final t = await pumpTimeline(tester, wrap: (timeline) => EditorLifecycle(delegate: shell, onExit: () {}, child: timeline));
    final dispatcher = EditorBackDispatcher.of(tester.element(find.byType(TimelineView)));
    await enterMode(tester, t);

    final g = await tester.startGesture(t.at(tester, 12 * s, 'tr_main'));
    await tester.pump(const Duration(milliseconds: 400));
    await g.moveBy(const Offset(-40, 0));
    await tester.pump();
    expect(await dispatcher.handleBack(), EditorBackStep.cancelGesture);
    await g.up();
    await tester.pump();
    expect(t.item('it_c').start, 10 * s);
    expect(t.state.modes.multiSelect, isTrue);

    expect(await dispatcher.handleBack(), EditorBackStep.clearSelection);
    await tester.pump();
    expect(t.state.modes.multiSelect, isFalse);
    expect(t.state.selection.items, isNotEmpty, reason: 'leaving the mode keeps the selection');
    await tester.pump(const Duration(seconds: 2));
  });

  for (final surface in const [
    EditorSurface(Size(280, 500), textScale: 1.35),
    EditorSurface(Size(568, 320), textScale: 1.35),
    EditorSurface(Size(1280, 800), textScale: 0.85),
  ]) {
    testWidgets('the banner fits [$surface]', (tester) async {
      final t = await pumpTimeline(tester, size: surface.size, textScale: surface.textScale);
      t.rig.controller.setModes((m) => m.copyWith(multiSelect: true));
      t.rig.controller.select(const ItemId('it_a'));
      await tester.pump();
      expect(find.text('1 selected'), findsOneWidget);
      expectNoOverflow(tester);
      expectInside(tester, find.text(TimelineViewStrings.done));
      expectOwnerUiRules(tester);
    });
  }
}
