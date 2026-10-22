// OWNER: UX-12
//
// QA-02 observation 2: the hover pill does not go stale. When the clip under a still mouse is split,
// trimmed or deleted, the pill goes away; the next mouse move shows a fresh one.

import 'package:flutter/foundation.dart' show TargetPlatform;
import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_editor_core/ops.dart' show DeleteItems, SplitItems;

import 'gesture_support.dart';

void main() {
  Future<(TimelineRig, TestGesture)> hoverCity(WidgetTester tester) async {
    final t = await pumpTimeline(tester, basicOnly: true, platform: TargetPlatform.macOS);
    final g = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await g.addPointer(location: t.at(tester, 5 * s, 'tr_main'));
    addTearDown(g.removePointer);
    await g.moveTo(t.at(tester, 6 * s, 'tr_main'));
    await tester.pump(const Duration(milliseconds: 700));
    expect(find.text('City · 0:04'), findsOneWidget);
    return (t, g);
  }

  testWidgets('a split of the hovered clip hides the pill; moving shows the new length', (tester) async {
    final (t, g) = await hoverCity(tester);
    t.rig.controller.apply(SplitItems({const ItemId('it_b')}, 7 * s));
    await tester.pump();
    await tester.pump();
    expect(find.text('City · 0:04'), findsNothing);
    expect(t.viewState(tester).hoverPillText, isNull);

    await g.moveTo(t.at(tester, 6 * s + 100000, 'tr_main'));
    await tester.pump(const Duration(milliseconds: 700));
    expect(find.text('City · 0:03'), findsOneWidget);
  });

  testWidgets('deleting the hovered clip hides the pill', (tester) async {
    final (t, _) = await hoverCity(tester);
    t.rig.controller.apply(DeleteItems({const ItemId('it_b')}));
    await tester.pump();
    await tester.pump();
    expect(t.viewState(tester).hoverPillText, isNull);
    expect(find.textContaining('City'), findsNothing);
  });

  testWidgets('an edit elsewhere keeps the pill', (tester) async {
    final (t, _) = await hoverCity(tester);
    t.rig.controller.apply(DeleteItems({const ItemId('it_c')}));
    await tester.pump();
    await tester.pump();
    expect(find.text('City · 0:04'), findsOneWidget);
  });
}
