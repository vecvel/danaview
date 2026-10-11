// OWNER: UX-12
//
// Taps by hit type (ux.md §8.8): items select (Shift/⌘ toggles), empty lanes clear, gaps select
// the gap, transitions open the transition panel, markers and keyframes select and seek, the ruler
// seeks, locked clips explain themselves.

import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vwish_editor/src/app/editor_providers.dart';
import 'package:vwish_editor/src/editor/contracts/contracts.dart';
import 'package:vwish_editor/src/editor/timeline/timeline_hit.dart';
import 'package:vwish_editor_core/model.dart';
import 'package:vwish_editor_core/ops.dart' show GapRef;

import 'gesture_support.dart';

void main() {
  testWidgets('hit types under the rig positions', (tester) async {
    final t = await pumpTimeline(tester);
    expect(t.hit(tester, t.at(tester, 2 * s, 'tr_main')), isA<HitItem>().having((h) => h.item, 'item', const ItemId('it_a')));
    expect(t.hit(tester, t.at(tester, 9 * s, 'tr_main')), isA<HitGap>());
    expect(t.hit(tester, t.at(tester, 12 * s, 'tr_music')), isA<HitEmpty>());
    expect(t.hit(tester, t.at(tester, 4 * s, 'tr_main')), isA<HitTransition>());
    expect(t.hit(tester, t.ruler(tester, 6 * s)), isA<HitMarker>());
    expect(t.hit(tester, t.ruler(tester, 9 * s)), isA<HitRuler>());
    expect(t.hit(tester, t.at(tester, 3 * s, 'tr_lock')), isA<HitItem>().having((h) => h.locked, 'locked', isTrue));
  });

  testWidgets('tap selects an item, a second tap elsewhere replaces it, Shift toggles', (tester) async {
    final t = await pumpTimeline(tester);
    await tester.tapAt(t.at(tester, 2 * s, 'tr_main'));
    await tester.pump();
    expect(t.state.selection.items, {const ItemId('it_a')});

    await tester.tapAt(t.at(tester, 6 * s, 'tr_main'));
    await tester.pump();
    expect(t.state.selection.items, {const ItemId('it_b')});

    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.tapAt(t.at(tester, 11 * s, 'tr_main'));
    await tester.pump();
    expect(t.state.selection.items, {const ItemId('it_b'), const ItemId('it_c')});
    await tester.tapAt(t.at(tester, 6 * s, 'tr_main'));
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump();
    expect(t.state.selection.items, {const ItemId('it_c')});
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('tap on an empty lane clears; on a gap selects the gap', (tester) async {
    final t = await pumpTimeline(tester);
    await tester.tapAt(t.at(tester, 2 * s, 'tr_main'));
    await tester.pump();
    await tester.tapAt(t.at(tester, 12 * s, 'tr_music'));
    await tester.pump();
    expect(t.state.selection.isEmpty, isTrue);

    await tester.tapAt(t.at(tester, 9 * s, 'tr_main'));
    await tester.pump();
    expect(t.state.selection.gap, const GapRef(TrackId('tr_main'), TimeRange(8 * s, 10 * s)));
  });

  testWidgets('tap on a transition selects the cut and opens the transition panel', (tester) async {
    final t = await pumpTimeline(tester);
    await tester.tapAt(t.at(tester, 4 * s, 'tr_main'));
    await tester.pump();
    const cut = TransitionRef(TrackId('tr_main'), ItemId('it_a'), ItemId('it_b'));
    expect(t.state.selection.transition, cut);
    expect(t.state.inspector, const TransitionInspector(cut));
  });

  testWidgets('tap on a marker selects it and seeks; tap on the ruler seeks (free mode)', (tester) async {
    final t = await pumpTimeline(tester);
    final playhead = t.container.read(playheadProvider(t.id));
    await tester.tapAt(t.ruler(tester, 6 * s));
    await tester.pump();
    expect(t.state.selection.marker, const MarkerId('mk_beat'));
    expect(playhead.value, 6 * s);

    await tester.tapAt(t.ruler(tester, 9 * s + 10000));
    await tester.pump();
    expect(playhead.value, FrameRate.fps30.quantize(9 * s + 10000));
  });

  testWidgets('tap on a keyframe of a selected clip selects the key and seeks to it', (tester) async {
    final t = await pumpTimeline(tester);
    await tester.tapAt(t.at(tester, 2 * s, 'tr_ov'));
    await tester.pump();
    expect(t.state.selection.items, {const ItemId('it_o')});
    final c = t.canvas(tester);
    final g = c.geometry;
    final li = g.snapshot.laneIndexOf(const TrackId('tr_ov'))!;
    final item = g.snapshot.item(const ItemId('it_o'))!;
    final y = g.itemRect(li, item).bottom - 4 - 3.5;
    final key = c.localToGlobal(Offset(t.viewport.xOf(item.start + f(30)), y));
    expect(t.hit(tester, key), isA<HitKeyframe>());
    await tester.tapAt(key);
    await tester.pump();
    expect(t.state.selection.keyframe?.t, f(30));
    expect(t.container.read(playheadProvider(t.id)).value, 1 * s + f(30));
  });

  testWidgets('tap on a locked clip does not select it and says the track is locked', (tester) async {
    final t = await pumpTimeline(tester);
    await tester.tapAt(t.at(tester, 3 * s, 'tr_lock'));
    await tester.pump();
    expect(t.state.selection.items, isEmpty);
    expect(find.textContaining('This track is locked'), findsOneWidget);
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('secondary click opens the item context menu built from the action registry', (tester) async {
    final t = await pumpTimeline(tester, platform: TargetPlatform.macOS);
    await tester.tapAt(t.at(tester, 2 * s, 'tr_main'), buttons: kSecondaryButton, kind: PointerDeviceKind.mouse);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(t.viewState(tester).menuOpen, isTrue);
    expect(t.state.selection.items, {const ItemId('it_a')});
    expect(find.text('Split'), findsOneWidget);
    expect(find.text('Ripple delete'), findsOneWidget);
    expect(find.text('Select multiple'), findsNothing, reason: 'multi-select mode is a touch affordance');
  });
}
