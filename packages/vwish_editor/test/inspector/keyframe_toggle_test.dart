// OWNER: UX-16
//
// KeyframeToggle (ux.md §9.4): the three states, notification only on change, the ‹ › jumps, and
// the connected toggle adding and removing keys at the playhead through the editor.

import 'package:flutter/material.dart' show Icons;
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vwish_editor/src/editor/inspector/keyframe_toggle.dart';
import 'package:vwish_editor_core/model.dart';
import 'package:vwish_editor_core/ops.dart' show AddKeyframe;
import 'package:vwish_ui_kit/vwish_ui_kit.dart';

import '../support/support.dart';
import 'inspector_rig.dart';

/// Frame-grid times on 30 fps.
TimeUs f(int frames) => FrameRate.fps30.timeOfFrame(frames);

TextItem _text({Map<String, List<int>> keys = const {}}) => TextItem(
      id: const ItemId('it_t'),
      start: f(30),
      duration: f(90),
      text: 'Hi',
      keyframes: KeyframeSet({
        for (final e in keys.entries) e.key: KeyframeTrack([for (final fr in e.value) Keyframe(f(fr), 0.5)]),
      }),
    );

void main() {
  group('KeyframeStatus.of', () {
    final opacity = PropertyKeys.opacity;
    test('static property: none, enabled inside the item only', () {
      expect(KeyframeStatus.of(_text(), opacity, f(40)), const KeyframeStatus(KeyframeToggleState.none));
      expect(KeyframeStatus.of(_text(), opacity, f(10)).enabled, isFalse);
      expect(KeyframeStatus.of(_text(), opacity, f(120)).enabled, isFalse, reason: 'the item ends at frame 120 (exclusive)');
    });

    test('keys elsewhere: animated with the previous and next key in absolute time', () {
      final item = _text(keys: {
        'transform.opacity': [0, 30, 60]
      });
      expect(
        KeyframeStatus.of(item, opacity, f(30 + 45)),
        KeyframeStatus(KeyframeToggleState.animated, previous: f(30 + 30), next: f(30 + 60)),
      );
      expect(KeyframeStatus.of(item, opacity, f(30)).state, KeyframeToggleState.atPlayhead);
      expect(KeyframeStatus.of(item, opacity, f(30)).next, f(60));
      expect(KeyframeStatus.of(item, opacity, f(30)).previous, isNull);
    });

    test('Vec2 properties merge both channels; keys outside the item are ignored', () {
      final item = _text(keys: {
        'transform.position.x': [10],
        'transform.position.y': [20],
        'transform.scale': [200]
      });
      expect(KeyframeStatus.of(item, PropertyKeys.position, f(40)).state, KeyframeToggleState.atPlayhead);
      expect(KeyframeStatus.of(item, PropertyKeys.position, f(50)).state, KeyframeToggleState.atPlayhead);
      expect(KeyframeStatus.of(item, PropertyKeys.scale, f(40)).state, KeyframeToggleState.none);
    });

    test('a non-keyframable property is never enabled', () {
      expect(KeyframeStatus.of(_text(), PropertyKeys.bold, f(40)).enabled, isFalse);
    });
  });

  test('KeyframeStateListenable notifies only when the status changes', () {
    final playhead = ValueNotifier<TimeUs>(f(35));
    final status = KeyframeStateListenable(
        item: _text(keys: {
          'transform.opacity': [30]
        }),
        key: PropertyKeys.opacity,
        playhead: playhead);
    var notified = 0;
    status.addListener(() => notified++);
    for (var fr = 36; fr < 60; fr++) {
      playhead.value = f(fr);
    }
    expect(notified, 0, reason: 'no key crossed');
    playhead.value = f(60);
    expect(notified, 1);
    expect(status.value.state, KeyframeToggleState.atPlayhead);
    playhead.value = f(61);
    expect(notified, 2);
    status.item = _text(keys: {
      'transform.opacity': [30]
    });
    expect(notified, 2, reason: 'an equal status after an item change is not a change');
    status.item = _text();
    expect(notified, 3);
    status.dispose();
    playhead.dispose();
  });

  group('KeyframeToggle', () {
    final cases = <KeyframeToggleState, (IconData, Color, String)>{
      KeyframeToggleState.none: (Icons.diamond_outlined, VwishColors.textMuted, 'Add keyframe'),
      KeyframeToggleState.animated: (Icons.diamond_outlined, VwishColors.primaryLight, 'Add keyframe'),
      KeyframeToggleState.atPlayhead: (Icons.diamond_rounded, VwishColors.primaryLight, 'Remove keyframe'),
    };
    for (final MapEntry(key: state, value: (icon, color, tooltip)) in cases.entries) {
      testWidgets('${state.name}: icon, colour and tooltip of ux.md §9.4', (tester) async {
        var taps = 0;
        await tester.pumpWidget(surfaceApp(
          SurfaceMatrix.phone,
          Center(child: KeyframeToggle(status: KeyframeStatus(state, previous: 0, next: 10), property: 'Opacity', onToggle: () => taps++)),
        ));
        final diamond = tester.widget<Icon>(find.byIcon(icon));
        expect(diamond.color, color);
        expect(find.byTooltip(tooltip), findsOneWidget);
        await tester.tap(find.byIcon(icon));
        expect(taps, 1);
        // ‹ › only when the property has keys.
        expect(find.byIcon(Icons.chevron_left_rounded), state == KeyframeToggleState.none ? findsNothing : findsOneWidget);
      });
    }

    testWidgets('disabled outside the item', (tester) async {
      var taps = 0;
      await tester.pumpWidget(surfaceApp(
        SurfaceMatrix.phone,
        Center(child: KeyframeToggle(status: const KeyframeStatus(KeyframeToggleState.none, enabled: false), onToggle: () => taps++)),
      ));
      await tester.tap(find.byIcon(Icons.diamond_outlined));
      expect(taps, 0);
      expect(find.byTooltip(KeyframeToggleStrings.outside), findsOneWidget);
    });
  });

  group('PropertyKeyframeToggle', () {
    testWidgets('adds and removes a key at the playhead; ‹ › jump between keys', (tester) async {
      final rig = await InspectorRig.pumpWith(
        tester,
        (items) => Center(child: PropertyKeyframeToggle(item: items.textA, property: PropertyKeys.opacity, label: 'Opacity')),
      );
      final item = rig.items.textA;
      await tester.pump();
      await rig.seek(f(15));
      expect(find.byIcon(Icons.diamond_outlined), findsOneWidget);
      expect(find.byIcon(Icons.chevron_left_rounded), findsNothing);

      await tester.tap(find.byIcon(Icons.diamond_outlined));
      await tester.pump();
      expect(rig.state.history.undoLabel, 'Add keyframe');
      expect(find.byIcon(Icons.diamond_rounded), findsOneWidget);

      // A second key at frame 45, then the playhead between them shows "animated".
      rig.editor.apply(AddKeyframe(KeyframeRef(item, 'transform.opacity', f(45))));
      await rig.seek(f(30));
      expect(find.byIcon(Icons.diamond_outlined), findsOneWidget);
      final toggle = tester.widget<KeyframeToggle>(find.byType(KeyframeToggle));
      expect(toggle.status.state, KeyframeToggleState.animated);
      expect(toggle.status.previous, f(15));
      expect(toggle.status.next, f(45));

      await tester.tap(find.byIcon(Icons.chevron_left_rounded));
      await rig.real(() async {});
      expect(rig.playhead.value, f(15));
      expect(find.byIcon(Icons.diamond_rounded), findsOneWidget);

      await tester.tap(find.byIcon(Icons.diamond_rounded));
      await tester.pump();
      expect(rig.state.history.undoLabel, 'Remove keyframe');
      expect(tester.widget<KeyframeToggle>(find.byType(KeyframeToggle)).status.state, KeyframeToggleState.animated);
      expectNoOverflow(tester);
    });
  });
}
