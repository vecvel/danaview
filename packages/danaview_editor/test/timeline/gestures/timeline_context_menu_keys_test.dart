// OWNER: UX-12
//
// FIX-QA02-M2-2: Esc closes the clip context menu (right-click with a mouse, long press on touch)
// and only the menu; the next Esc does what it did before (the editor's `escape` action clears
// the selection). It holds when the menu's focus scope does not hold focus, as on the Android
// tablet where four Esc presses left the menu open.

import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_editor/src/editor/actions/editor_shortcuts.dart';
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_ui_kit/danaview_ui_kit.dart' show DanaviewMenuAnchor;

import 'gesture_support.dart';

void main() {
  FocusNode editorRoot() =>
      (find.byWidgetPredicate((w) => w is Focus && w.debugLabel == 'EditorShortcuts').evaluate().single.widget as Focus).focusNode!;

  Future<TimelineRig> rightClickClip(WidgetTester tester, TargetPlatform platform) async {
    final t = await pumpTimeline(tester, platform: platform, wrap: (timeline) => EditorShortcuts(child: timeline));
    await tester.tapAt(t.at(tester, 2 * s, 'tr_main'), buttons: kSecondaryButton, kind: PointerDeviceKind.mouse);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(t.viewState(tester).menuOpen, isTrue);
    expect(find.text('Split'), findsOneWidget);
    expect(t.state.selection.items, {const ItemId('it_a')});
    return t;
  }

  Future<void> escClosesOnlyTheMenu(WidgetTester tester, TimelineRig t) async {
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump(const Duration(milliseconds: 300));
    expect(t.viewState(tester).menuOpen, isFalse);
    expect(find.text('Split'), findsNothing);
    expect(DanaviewMenuAnchor.anyOpen, isFalse);
    expect(t.state.selection.items, {const ItemId('it_a')}, reason: 'the first Esc closes only the menu');
    expect(FocusManager.instance.primaryFocus, editorRoot(), reason: 'keyboard focus is back on the editor/timeline');

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(t.state.selection.isEmpty, isTrue, reason: 'the second Esc clears the selection, as before');
    await tester.pump(const Duration(seconds: 2));
  }

  for (final platform in [TargetPlatform.macOS, TargetPlatform.android, TargetPlatform.iOS, TargetPlatform.windows]) {
    testWidgets('right-click menu: Esc closes it, the next Esc clears the selection ($platform)', (tester) async {
      final t = await rightClickClip(tester, platform);
      await escClosesOnlyTheMenu(tester, t);
    });
  }

  testWidgets('right-click menu: Esc closes it when focus is not in the menu (the tablet case)', (tester) async {
    final t = await rightClickClip(tester, TargetPlatform.android);
    editorRoot().requestFocus();
    await tester.pump();
    expect(FocusManager.instance.primaryFocus, editorRoot());
    await escClosesOnlyTheMenu(tester, t);
  });

  testWidgets('long-press menu on touch: Esc on a hardware keyboard closes it', (tester) async {
    final t = await pumpTimeline(tester, wrap: (timeline) => EditorShortcuts(child: timeline));
    await tester.longPressAt(t.at(tester, 2 * s, 'tr_main'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(t.viewState(tester).menuOpen, isTrue);
    expect(t.state.selection.items, {const ItemId('it_a')});
    await escClosesOnlyTheMenu(tester, t);
  });
}
