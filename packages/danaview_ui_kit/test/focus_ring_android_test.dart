// Keyboard-only focus rings on Android (owner decision A; S2 tail, answering b8a72cc's "no in-app
// focus ring with adb-injected Tab"). With the platform set to Android and the focus manager on
// its automatic strategy, a touch leaves the highlight mode at touch and paints no ring; a hardware
// Tab switches it to traditional, moves focus and the kit's DanaviewButton and DanaviewIconButton
// paint the ring; the next touch turns it off again. A mouse hover never paints one.

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_ui_kit/danaview_ui_kit.dart';

import 'test_utils.dart';

/// True when a decoration in the subtree of [root] carries the kit's focus-ring colour.
bool _paintsRing(RenderObject root) {
  var found = false;
  void visit(RenderObject ro) {
    if (ro is RenderDecoratedBox && '${ro.decoration}'.contains('${DanaviewColors.focusRing}')) found = true;
    ro.visitChildren(visit);
  }

  visit(root);
  return found;
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  testWidgets('Android: a hardware Tab shows the ring on DanaviewButton and DanaviewIconButton; touch and hover do not',
      (tester) async {
    expect(defaultTargetPlatform, TargetPlatform.android);
    expect(FocusManager.instance.highlightStrategy, FocusHighlightStrategy.automatic, reason: 'the app keeps the default');

    await pumpKit(
      tester,
      surfaces[0], // narrow touch, Android
      Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          DanaviewButton.secondary(label: 'First', onPressed: () {}),
          DanaviewIconButton(icon: Icons.undo_rounded, tooltip: 'Undo', onPressed: () {}),
        ],
      ),
    );
    final button = find.ancestor(of: find.text('First'), matching: find.byType(DanaviewPressable)).first;
    final icon = find.descendant(of: find.byType(DanaviewIconButton), matching: find.byType(DanaviewPressable)).first;

    // A touch: touch mode, no ring anywhere.
    await tester.tap(find.text('First'), kind: PointerDeviceKind.touch);
    await _settle(tester);
    expect(FocusManager.instance.highlightMode, FocusHighlightMode.touch);
    expect(_paintsRing(tester.renderObject(button)), isFalse);
    expect(_paintsRing(tester.renderObject(icon)), isFalse);

    // A mouse hover: still no ring.
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: tester.getCenter(icon));
    await mouse.moveTo(tester.getCenter(icon));
    await _settle(tester);
    expect(_paintsRing(tester.renderObject(icon)), isFalse, reason: 'no hover effect');
    await mouse.moveTo(Offset.zero);

    // A hardware Tab (a key event from a keyboard device): traditional mode, the first control rings.
    await tester.sendKeyEvent(LogicalKeyboardKey.tab, platform: 'android');
    await _settle(tester);
    expect(FocusManager.instance.highlightMode, FocusHighlightMode.traditional);
    expect(_paintsRing(tester.renderObject(button)), isTrue, reason: 'DanaviewButton focused by Tab');
    expect(_paintsRing(tester.renderObject(icon)), isFalse);

    // The next Tab moves the ring to the icon button.
    await tester.sendKeyEvent(LogicalKeyboardKey.tab, platform: 'android');
    await _settle(tester);
    expect(_paintsRing(tester.renderObject(button)), isFalse);
    expect(_paintsRing(tester.renderObject(icon)), isTrue, reason: 'DanaviewIconButton focused by Tab');

    // A touch again: back to touch mode, the ring goes although focus stays.
    await tester.tap(find.text('First'), kind: PointerDeviceKind.touch);
    await _settle(tester);
    expect(FocusManager.instance.highlightMode, FocusHighlightMode.touch);
    expect(_paintsRing(tester.renderObject(icon)), isFalse);
    expect(_paintsRing(tester.renderObject(button)), isFalse);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));
}
