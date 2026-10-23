// Owner rule (clean-cross-platform-ui): no hover, press or outline effect on controls. A mouse
// hover and a held press paint exactly what the idle control paints: same pixels, same
// decorations, same opacity, same geometry (no press scale). Selected states still differ, and
// hardware-keyboard focus still draws its ring.


import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_ui_kit/danaview_ui_kit.dart';

import 'test_utils.dart';

/// Everything a control paints that hover or press could change: each decoration, opacity, text
/// colour and on-screen rect (the rect catches a press scale) in its render subtree.
List<String> visualSignature(RenderObject root) {
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

Future<Uint8List> pixels(WidgetTester tester, GlobalKey boundary) async {
  final ro = boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  final bytes = await tester.runAsync(() async {
    final image = await ro.toImage();
    final data = await image.toByteData();
    image.dispose();
    return data!.buffer.asUint8List();
  });
  return bytes!;
}

Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

class _Look {
  const _Look(this.signature, this.pixels);
  final List<String> signature;
  final Uint8List? pixels;
}

/// Captures idle, mouse-hovered, mouse-held and touch-held looks of the control at [target].
Future<List<_Look>> captureStates(WidgetTester tester, Finder target, {GlobalKey? boundary}) async {
  final pressable = find.ancestor(of: target, matching: find.byType(DanaviewPressable), matchRoot: true).first;
  Future<_Look> look() async => _Look(
        visualSignature(tester.renderObject(pressable)),
        boundary == null ? null : await pixels(tester, boundary),
      );

  await settle(tester);
  final idle = await look();
  final center = tester.getCenter(target);

  final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
  await mouse.addPointer(location: const Offset(1, 1));
  await tester.pump();
  await mouse.moveTo(center);
  await settle(tester);
  final hovered = await look();

  await mouse.down(center);
  await tester.pump(const Duration(milliseconds: 50));
  await tester.pump(const Duration(milliseconds: 200));
  final mousePressed = await look();
  await mouse.cancel();
  await mouse.removePointer();
  await settle(tester);

  final touch = await tester.startGesture(center);
  await tester.pump(const Duration(milliseconds: 50));
  await tester.pump(const Duration(milliseconds: 200));
  final touchPressed = await look();
  await touch.cancel();
  await settle(tester);
  return [idle, hovered, mousePressed, touchPressed];
}

void expectNoEffect(List<_Look> looks, String what) {
  const names = ['hover', 'mouse press', 'touch press'];
  final idle = looks.first;
  for (var i = 1; i < looks.length; i++) {
    expect(looks[i].signature, orderedEquals(idle.signature), reason: '$what: ${names[i - 1]} changed the paint');
    if (idle.pixels != null) {
      expect(looks[i].pixels, orderedEquals(idle.pixels!), reason: '$what: ${names[i - 1]} changed the pixels');
    }
  }
}

Future<void> pumpControl(WidgetTester tester, GlobalKey boundary, Widget control) async {
  await pumpKit(
    tester,
    surfaces[2],
    Center(child: RepaintBoundary(key: boundary, child: Padding(padding: const EdgeInsets.all(8), child: control))),
  );
}

void main() {
  final controls = <String, Widget Function(bool selected)>{
    'DanaviewButton.primary': (_) => DanaviewButton.primary(label: 'Export', onPressed: () {}),
    'DanaviewButton.secondary': (_) => DanaviewButton.secondary(label: 'Cancel', onPressed: () {}),
    'DanaviewButton.ghost': (_) => DanaviewButton.ghost(label: 'Skip', onPressed: () {}),
    'DanaviewIconButton': (selected) =>
        DanaviewIconButton(icon: Icons.undo_rounded, tooltip: 'Undo', selected: selected, onPressed: () {}),
    'DanaviewIconButton.filled': (selected) => DanaviewIconButton(
          icon: Icons.undo_rounded,
          variant: DanaviewIconButtonVariant.filled,
          selected: selected,
          onPressed: () {},
        ),
    'DanaviewListTile': (selected) => SizedBox(
          width: 320,
          child: DanaviewListTile(title: 'Library', subtitle: '12 items', selected: selected, onTap: () {}),
        ),
    'DanaviewChoiceChip': (selected) => DanaviewChoiceChip(label: '4K', selected: selected, onTap: () {}),
    'DanaviewSwitch': (selected) => DanaviewSwitch(value: selected, onChanged: (_) {}),
  };

  for (final entry in controls.entries) {
    testWidgets('${entry.key}: hover and press paint the same pixels as idle', (tester) async {
      final boundary = GlobalKey();
      await pumpControl(tester, boundary, entry.value(false));
      final target = find.descendant(of: find.byKey(boundary), matching: find.byType(DanaviewPressable)).first;
      final looks = await captureStates(tester, target, boundary: boundary);
      expectNoEffect(looks, entry.key);
      expect(tester.takeException(), isNull);
    });
  }

  for (final name in ['DanaviewIconButton', 'DanaviewListTile', 'DanaviewChoiceChip']) {
    testWidgets('$name: selected still paints differently from unselected', (tester) async {
      final boundary = GlobalKey();
      await pumpControl(tester, boundary, controls[name]!(false));
      await settle(tester);
      final pressable = find.descendant(of: find.byKey(boundary), matching: find.byType(DanaviewPressable)).first;
      final idle = visualSignature(tester.renderObject(pressable));
      await pumpControl(tester, boundary, controls[name]!(true));
      await settle(tester);
      final selected = visualSignature(tester.renderObject(pressable));
      expect(selected, isNot(orderedEquals(idle)));
    });
  }

  testWidgets('DanaviewSegmentedControl: hovering and pressing an unselected segment paints like idle', (tester) async {
    final boundary = GlobalKey();
    await pumpControl(
      tester,
      boundary,
      SizedBox(
        width: 320,
        child: DanaviewSegmentedControl<int>(
          value: 0,
          onChanged: (_) {},
          options: const [DanaviewOption(value: 0, label: 'Fit'), DanaviewOption(value: 1, label: 'Fill')],
        ),
      ),
    );
    final looks = await captureStates(tester, find.text('Fill'), boundary: boundary);
    expectNoEffect(looks, 'segment');
  });

  testWidgets('DanaviewMenuItem: hover and press paint like idle; selected keeps its check', (tester) async {
    await pumpKit(
      tester,
      surfaces[2],
      Center(
        child: DanaviewMenuIconTrigger(
          icon: Icons.more_horiz,
          entries: [
            DanaviewMenuItem(label: '1.0x', selected: true, onTap: () {}),
            DanaviewMenuItem(label: '1.5x', onTap: () {}),
          ],
        ),
      ),
    );
    await tester.tap(find.byIcon(Icons.more_horiz));
    await tester.pumpAndSettle();
    final looks = await captureStates(tester, find.text('1.5x'));
    expectNoEffect(looks, 'menu item');
    final selected = visualSignature(tester.renderObject(find.ancestor(of: find.text('1.0x'), matching: find.byType(DanaviewPressable)).first));
    expect(selected.where((s) => s.startsWith('text ')).length,
        greaterThan(looks.first.signature.where((s) => s.startsWith('text ')).length),
        reason: 'the selected item draws its check');
  });

  testWidgets('hardware-keyboard focus still draws the ring (the one kept interaction state)', (tester) async {
    final boundary = GlobalKey();
    final node = FocusNode();
    addTearDown(node.dispose);
    await pumpControl(
      tester,
      boundary,
      Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          DanaviewButton.secondary(label: 'First', onPressed: () {}),
          DanaviewButton.secondary(label: 'Second', onPressed: () {}),
        ],
      ),
    );
    final second = find.ancestor(of: find.text('Second'), matching: find.byType(DanaviewPressable)).first;
    await settle(tester);
    final idle = visualSignature(tester.renderObject(second));
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await settle(tester);
    final focused = visualSignature(tester.renderObject(second));
    expect(focused, isNot(orderedEquals(idle)));
    expect(focused.join('\n'), contains('${DanaviewColors.focusRing}'));
  });
}
