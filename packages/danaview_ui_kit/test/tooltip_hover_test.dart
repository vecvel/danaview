// QA-01 step 4: a pointer hover over a kit button shows its tooltip after the theme's wait (mouse,
// trackpad, iPad pointer, Android mouse, desktop); a touch tap does not, and the button gets no
// hover highlight.

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_ui_kit/danaview_ui_kit.dart';

import 'test_utils.dart';

void main() {
  const tip = 'Undo Split clip';

  /// Whether the tooltip is in the tree and faded in.
  bool shown(WidgetTester tester) {
    final text = find.text(tip);
    if (text.evaluate().isEmpty) return false;
    final fades = find.ancestor(of: text, matching: find.byType(FadeTransition)).evaluate();
    return fades.every((e) => (e.widget as FadeTransition).opacity.value == 1.0);
  }

  Future<int Function()> pumpButton(WidgetTester tester, TargetPlatform platform) async {
    var taps = 0;
    await pumpKit(
      tester,
      Surface('$platform', const Size(1194, 834), 1.0, platform),
      Center(child: DanaviewIconButton(icon: Icons.undo_rounded, tooltip: tip, onPressed: () => taps++)),
    );
    return () => taps;
  }

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  for (final platform in [TargetPlatform.iOS, TargetPlatform.android, TargetPlatform.macOS, TargetPlatform.windows]) {
    testWidgets('mouse hover shows the tooltip after the wait and hides it on leave ($platform)', (tester) async {
      await pumpButton(tester, platform);
      final center = tester.getCenter(find.byIcon(Icons.undo_rounded));
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      addTearDown(mouse.removePointer);
      await tester.pump();
      await mouse.moveTo(center);
      await tester.pump(const Duration(milliseconds: 100));
      expect(shown(tester), isFalse, reason: 'not before the wait');
      await settle(tester);
      await settle(tester);
      expect(shown(tester), isTrue);

      await mouse.moveTo(Offset.zero);
      await settle(tester);
      await settle(tester);
      expect(find.text(tip), findsNothing);
    });

    testWidgets('a touch tap presses the button and shows no tooltip ($platform)', (tester) async {
      final taps = await pumpButton(tester, platform);
      await tester.tap(find.byIcon(Icons.undo_rounded));
      await settle(tester);
      await settle(tester);
      expect(taps(), 1);
      expect(find.text(tip), findsNothing);
    });
  }

  testWidgets('hover events the mouse tracker does not see still show the tooltip (iPad pointer path)', (tester) async {
    // The mouse tracker (and so Material's Tooltip) reacts only to mouse and stylus kinds with
    // enter/exit; hit-tested hover events reach the button whatever the tracker does.
    await pumpButton(tester, TargetPlatform.iOS);
    final center = tester.getCenter(find.byIcon(Icons.undo_rounded));
    tester.binding.handlePointerEvent(PointerHoverEvent(kind: PointerDeviceKind.trackpad, device: 7, position: center));
    await settle(tester);
    await settle(tester);
    expect(shown(tester), isTrue);
    tester.binding.handlePointerEvent(const PointerHoverEvent(kind: PointerDeviceKind.trackpad, device: 7, position: Offset(2, 2)));
    await settle(tester);
    await settle(tester);
    expect(find.text(tip), findsNothing);
  });

  testWidgets('a press while hovering hides the tooltip until the pointer comes back', (tester) async {
    await pumpButton(tester, TargetPlatform.iOS);
    final center = tester.getCenter(find.byIcon(Icons.undo_rounded));
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: center);
    addTearDown(mouse.removePointer);
    await mouse.moveTo(center + const Offset(1, 0));
    await settle(tester);
    await settle(tester);
    expect(shown(tester), isTrue);
    await mouse.down(center);
    await mouse.up();
    await settle(tester);
    await settle(tester);
    expect(find.text(tip), findsNothing);
  });

  testWidgets('hovering adds no highlight to the button', (tester) async {
    await pumpButton(tester, TargetPlatform.macOS);
    Color? fill() {
      final box = find.descendant(of: find.byType(DanaviewIconButton), matching: find.byType(AnimatedContainer)).first;
      return (tester.widget<AnimatedContainer>(box).decoration as ShapeDecoration?)?.color;
    }

    final before = fill();
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await mouse.moveTo(tester.getCenter(find.byIcon(Icons.undo_rounded)));
    await settle(tester);
    expect(fill(), before);
  });
}
