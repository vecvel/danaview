// Owner rule (clean-cross-platform-ui): no hover or press effect on controls.
// `expectNoHoverOrPressEffect(tester, target)` hovers the [DanaviewPressable] at `target` with a
// mouse, holds it with the mouse and then with a finger, and fails when any of those paints a
// different decoration, opacity, text colour or on-screen rect (a press scale) from idle.

import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_ui_kit/danaview_ui_kit.dart';

/// Everything a control paints that hover or press could change, in its render subtree.
List<String> pressableVisualSignature(RenderObject root) {
  final out = <String>[];
  void visit(RenderObject ro) {
    if (ro is RenderBox && ro.hasSize) {
      final rect = MatrixUtils.transformRect(ro.getTransformTo(null), Offset.zero & ro.size);
      out.add('${ro.runtimeType} ${rect.left.toStringAsFixed(2)},${rect.top.toStringAsFixed(2)} '
          '${rect.width.toStringAsFixed(2)}x${rect.height.toStringAsFixed(2)}');
    }
    if (ro is RenderDecoratedBox) out.add('decoration(${ro.position.name}) ${ro.decoration}');
    if (ro is RenderOpacity) out.add('opacity ${ro.opacity}');
    if (ro is RenderAnimatedOpacity) out.add('opacity ${ro.opacity.value}');
    if (ro is RenderParagraph) out.add('text ${ro.text.toPlainText()} ${ro.text.style?.color}');
    ro.visitChildren(visit);
  }

  visit(root);
  return out;
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

/// Fails when hovering or pressing the control at [target] changes what it paints.
Future<void> expectNoHoverOrPressEffect(WidgetTester tester, Finder target, {String? what}) async {
  // The pressable at or inside [target] (a widget wrapping one), else the one around it (a label).
  final inside = find.descendant(of: target, matching: find.byType(DanaviewPressable), matchRoot: true);
  final pressable = inside.evaluate().isNotEmpty
      ? inside.first
      : find.ancestor(of: target, matching: find.byType(DanaviewPressable)).first;
  List<String> look() => pressableVisualSignature(tester.renderObject(pressable));

  await _settle(tester);
  final idle = look();
  final center = tester.getCenter(target);

  final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
  await mouse.addPointer(location: const Offset(1, 1));
  await tester.pump();
  await mouse.moveTo(center);
  await _settle(tester);
  expect(look(), orderedEquals(idle), reason: '${what ?? target}: hover changed the paint');

  await mouse.down(center);
  await tester.pump(const Duration(milliseconds: 50));
  await tester.pump(const Duration(milliseconds: 200));
  expect(look(), orderedEquals(idle), reason: '${what ?? target}: a mouse press changed the paint');
  await mouse.cancel();
  await mouse.removePointer();
  await _settle(tester);

  final touch = await tester.startGesture(center);
  await tester.pump(const Duration(milliseconds: 50));
  await tester.pump(const Duration(milliseconds: 200));
  expect(look(), orderedEquals(idle), reason: '${what ?? target}: a touch press changed the paint');
  await touch.cancel();
  await _settle(tester);
}
