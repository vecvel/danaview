// OWNER: FIX-A11Y
//
// ExpandedHitArea: a control laid out smaller than 44×44 answers taps and screen readers over
// 44×44 without growing its layout, and its frame is shifted (not cut) inside an ancestor clip.

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_editor/src/editor/a11y/expanded_hit_area.dart';
import 'package:danaview_ui_kit/danaview_ui_kit.dart';

Widget _app(Widget child) => Directionality(
      textDirection: TextDirection.ltr,
      child: MediaQuery(data: const MediaQueryData(size: Size(400, 400)), child: child),
    );

Widget _button(VoidCallback onTap, {String label = 'Lock'}) => DanaviewPressable(
      onTap: onTap,
      semanticLabel: label,
      child: const SizedBox(width: 44, height: 32),
    );

/// The node a screen reader sees for [label]: the node itself or the one it is merged into.
SemanticsNode _node(String label) {
  var node = find.semantics.byLabel(label).evaluate().single;
  while (node.isMergedIntoParent && node.parent != null) {
    node = node.parent!;
  }
  return node;
}

void main() {
  testWidgets('a 32 px tall button keeps its layout and gets a 44×44 hit area and frame', (tester) async {
    final handle = tester.ensureSemantics();
    var taps = 0;
    await tester.pumpWidget(_app(Center(child: ExpandedHitArea(child: _button(() => taps++)))));
    final rect = tester.getRect(find.byType(ExpandedHitArea));
    expect(rect.size, const Size(44, 32), reason: 'layout unchanged');

    final node = _node('Lock');
    expect(node.rect.height, 44);
    expect(node.rect.width, 44);
    expect(node.getSemanticsData().hasAction(SemanticsAction.tap), isTrue);

    await tester.tapAt(rect.topCenter - const Offset(0, 5));
    await tester.tapAt(rect.bottomCenter + const Offset(0, 5));
    await tester.tapAt(rect.center);
    expect(taps, 3);
    await tester.tapAt(rect.topCenter - const Offset(0, 8));
    expect(taps, 3, reason: 'outside the 44 px area');
    handle.dispose();
  });

  testWidgets('next to a clip edge the frame shifts inside instead of being cut', (tester) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(_app(Align(
      alignment: Alignment.topLeft,
      child: SizedBox(
        width: 200,
        height: 100,
        child: ClipRect(
          child: Stack(children: [
            Positioned(left: 10, top: 68, child: ExpandedHitArea(child: _button(() {}))),
          ]),
        ),
      ),
    )));
    final node = _node('Lock');
    expect(node.rect.height, 44);
    expect(node.rect.bottom, lessThanOrEqualTo(100 - 68 + 0.01), reason: 'shifted up inside the clip');
    handle.dispose();
  });

  testWidgets('disabled it passes through', (tester) async {
    final handle = tester.ensureSemantics();
    var taps = 0;
    await tester.pumpWidget(_app(Center(child: ExpandedHitArea(enabled: false, child: _button(() => taps++)))));
    final rect = tester.getRect(find.byType(ExpandedHitArea));
    await tester.tapAt(rect.topCenter - const Offset(0, 5));
    expect(taps, 0);
    expect(_node('Lock').rect.height, 32);
    handle.dispose();
  });
}
