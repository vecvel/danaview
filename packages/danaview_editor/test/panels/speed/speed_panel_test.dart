// OWNER: UX-25
//
// The speed panel (ux.md §10.3, D-15): the nine chips and the custom field dispatch SetSpeed (one
// "Change speed" entry each), the ramp presets and the curve editor produce valid ramps, the
// duration readout is the core's duration, keep audio pitch, the capability note, the reverse and
// freeze entry points, reset, the locked track, re-targeting and ripple.

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_editor/src/app/strings/speed_strings.dart';
import 'package:danaview_editor/src/editor/contracts/contracts.dart';
import 'package:danaview_editor/src/editor/inspector/inspector_header.dart';
import 'package:danaview_editor/src/editor/inspector/inspector_rows.dart';
import 'package:danaview_editor/src/editor/panels/speed_curve_editor.dart';
import 'package:danaview_editor/src/editor/panels/speed_panel.dart';
import 'package:danaview_editor/src/editor/timeline/timeline_semantics.dart' show EditorAnnouncer;
import 'package:danaview_editor/src/editor/wiring/action_bindings.dart';
import 'package:flutter/semantics.dart' show CustomSemanticsAction, SemanticsAction, SemanticsActionEvent, SemanticsBinding, SemanticsNode;
import 'package:danaview_editor_core/eval.dart' show ClipTimeMap, speedRampIssues;
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_editor_core/ops.dart' show SpeedRampPresets;
import 'package:danaview_editor_engine_api/danaview_editor_engine_api.dart' show EditorCapabilities;
import 'package:danaview_ui_kit/danaview_ui_kit.dart';

import '../../support/support.dart';
import 'speed_rig.dart';

Finder key(String k) => find.byKey(ValueKey<String>(k));

Finder chip(double rate) => key('speed.chip.$rate');

Finder preset(String id) => key('speed.preset.$id');

/// The field of a number field with key [k].
Finder fieldOf(String k) => find.descendant(of: key(k), matching: find.byType(EditableText));

bool selected(WidgetTester tester, Finder chip) => tester.widget<DanaviewChoiceChip>(chip).selected;

SpeedRamp rampOf(SpeedRig rig, [ItemId id = SpeedIds.video]) => rig.clip(id).speed as SpeedRamp;

/// The duration the core gives [clip] at its speed on the rig's grid.
TimeUs coreDuration(MediaClip clip) => ClipTimeMap.durationFor(ClipTimeMap.forClip(clip, rate).sourceRange, clip.speed, rate);

/// The clip's length at normal speed as the core derives it from the clip's time map.
TimeUs coreNormal(MediaClip clip) => ClipTimeMap.durationFor(ClipTimeMap.forClip(clip, rate).sourceRange, SpeedSpec.normal, rate);

/// The pixel position of point [i] of the curve on screen.
Offset pointAt(WidgetTester tester, SpeedRamp ramp, int i) {
  final box = tester.getRect(key('speed.curve'));
  final plot = SpeedPlot(SpeedCurveEditor.plotInset.deflateRect(Offset.zero & box.size));
  return box.topLeft + plot.of(ramp.points[i]);
}

/// The pixel position of normalized position [x] on the 1x line.
Offset lineAt(WidgetTester tester, double x, double speed) {
  final box = tester.getRect(key('speed.curve'));
  final plot = SpeedPlot(SpeedCurveEditor.plotInset.deflateRect(Offset.zero & box.size));
  return box.topLeft + Offset(plot.dx(x), plot.dy(speed));
}

/// Scrolls [finder] into view and taps it.
Future<void> tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pump();
}

double scrollPixels(WidgetTester tester) =>
    tester.state<ScrollableState>(find.descendant(of: key('speed.scroll'), matching: find.byType(Scrollable)).first).position.pixels;

Future<void> switchToCurve(WidgetTester tester) async {
  await tester.ensureVisible(find.text(SpeedStrings.modeCurve));
  await tester.pumpAndSettle();
  await tester.tap(find.text(SpeedStrings.modeCurve));
  await tester.pump();
}

/// A widget test that clears the throttled announcement timer before the framework checks for timers.
void testSpeed(String description, Future<void> Function(WidgetTester tester) body) => testWidgets(description, (tester) async {
      try {
        await body(tester);
        await tester.pump(const Duration(seconds: 1));
      } finally {
        EditorAnnouncer.instance.reset();
      }
    });

void testSpeedSurfaces(String description, Future<void> Function(WidgetTester tester, EditorSurface surface) body) =>
    testSurfaces(description, (tester, surface) async {
      try {
        await body(tester, surface);
        await tester.pump(const Duration(seconds: 1));
      } finally {
        EditorAnnouncer.instance.reset();
      }
    });

void main() {
  late DateTime now;
  setUp(() {
    EditorAnnouncer.instance.reset();
    addTearDown(EditorAnnouncer.instance.reset);
    now = DateTime.utc(2026, 10, 11, 9);
    InspectorRows.clock = () => now;
  });
  tearDown(() => InspectorRows.clock = DateTime.now);

  group('constant speed', () {
    testSpeed('shows the nine chips, 1x selected, and the custom field', (tester) async {
      final rig = await SpeedRig.pump(tester);
      expect(find.byType(SpeedPanel), findsOneWidget);
      for (final r in speedPresets) {
        expect(chip(r), findsOneWidget, reason: '$r');
        expect(selected(tester, chip(r)), r == 1, reason: '$r');
      }
      expect(speedPresets, [0.25, 0.5, 0.75, 1, 1.25, 1.5, 2, 3, 4]);
      expect(find.text('0.25×'), findsOneWidget);
      expect(find.byKey(const ValueKey<String>('speed.custom')), findsOneWidget);
      expect(rig.clip(SpeedIds.video).speed, SpeedSpec.normal);
      expectNoOverflow(tester);
    });

    for (final r in speedPresets) {
      testSpeed('the $r× chip dispatches SetSpeed: one "Change speed" entry, the core duration', (tester) async {
        final rig = await SpeedRig.pump(tester);
        final before = rig.entries;
        if (r == 1) {
          await tester.tap(chip(2));
          await tester.pump();
          now = now.add(const Duration(seconds: 2));
        }
        final entries = rig.entries;
        await tester.tap(chip(r));
        await tester.pump();
        final clip = rig.clip(SpeedIds.video);
        expect(clip.speed, ConstantSpeed(r));
        expect(clip.duration, coreDuration(clip));
        expect(clip.duration, rate.quantizeNearest((12 * s / r).round()));
        expect(rig.entries, r == 1 ? entries + 1 : before + 1);
        expect(rig.state.history.undoLabel, 'Change speed');
        expect(selected(tester, chip(r)), isTrue);
        for (final other in speedPresets) {
          if (other != r) expect(selected(tester, chip(other)), isFalse);
        }
        expectNoOverflow(tester);
      });
    }

    testSpeed('undo restores the speed and the duration', (tester) async {
      final rig = await SpeedRig.pump(tester);
      await tester.tap(chip(2));
      await tester.pump();
      expect(rig.clip(SpeedIds.video).duration, 6 * s);
      rig.editor.undo();
      await tester.pump();
      expect(rig.clip(SpeedIds.video).speed, SpeedSpec.normal);
      expect(rig.clip(SpeedIds.video).duration, 12 * s);
      expect(selected(tester, chip(1)), isTrue);
    });

    testSpeed('the custom field takes a typed value (one entry) and shows the current speed', (tester) async {
      final rig = await SpeedRig.pump(tester);
      final before = rig.entries;
      await tester.enterText(fieldOf('speed.custom'), '1.7');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect(rig.clip(SpeedIds.video).speed, const ConstantSpeed(1.7));
      expect(rig.entries, before + 1);
      expect(rig.state.history.undoLabel, 'Change speed');
      expect(rig.clip(SpeedIds.video).duration, coreDuration(rig.clip(SpeedIds.video)));
      for (final r in speedPresets) {
        expect(selected(tester, chip(r)), isFalse, reason: 'a custom speed selects no chip');
      }
      expect(tester.widget<DanaviewNumberField>(key('speed.custom')).value, 1.7);
    });

    testSpeed('the custom field is limited to 0.1-10x', (tester) async {
      final rig = await SpeedRig.pump(tester);
      final field = tester.widget<DanaviewNumberField>(key('speed.custom'));
      expect(field.min, 0.1);
      expect(field.max, 10);
      await tester.enterText(fieldOf('speed.custom'), '55');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect(rig.clip(SpeedIds.video).speed, const ConstantSpeed(10));
      await tester.enterText(fieldOf('speed.custom'), '0.01');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect(rig.clip(SpeedIds.video).speed, const ConstantSpeed(0.1));
    });

    testSpeed('the custom field and the chips are limited by the engine capabilities', (tester) async {
      final rig = await SpeedRig.pump(tester, caps: const EditorCapabilities(supported: true, minSpeed: 0.5, maxSpeed: 3));
      final field = tester.widget<DanaviewNumberField>(key('speed.custom'));
      expect(field.min, 0.5);
      expect(field.max, 3);
      expect(tester.widget<DanaviewChoiceChip>(chip(0.25)).enabled, isFalse);
      expect(tester.widget<DanaviewChoiceChip>(chip(0.5)).enabled, isTrue);
      expect(tester.widget<DanaviewChoiceChip>(chip(3)).enabled, isTrue);
      expect(tester.widget<DanaviewChoiceChip>(chip(4)).enabled, isFalse);
      await tester.tap(chip(4), warnIfMissed: false);
      await tester.pump();
      expect(rig.clip(SpeedIds.video).speed, SpeedSpec.normal, reason: 'a disabled chip does nothing');
      await tester.enterText(fieldOf('speed.custom'), '8');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect(rig.clip(SpeedIds.video).speed, const ConstantSpeed(3));
    });

    testSpeed('stepper presses less than 500 ms apart share one history entry', (tester) async {
      final rig = await SpeedRig.pump(tester);
      final before = rig.entries;
      await tester.tap(fieldOf('speed.custom'));
      await tester.pump();
      for (var i = 0; i < 3; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
        await tester.pump();
        now = now.add(const Duration(milliseconds: 100));
      }
      expect(rig.clip(SpeedIds.video).speed, const ConstantSpeed(1.3));
      expect(rig.entries, before + 1);
    });
  });

  group('duration readout', () {
    testSpeed('shows the length at normal speed and the core duration now', (tester) async {
      final rig = await SpeedRig.pump(tester);
      expect(find.text('Duration 00:12:00 → 00:12:00'), findsOneWidget);
      await tester.tap(chip(2));
      await tester.pump();
      expect(find.text('Duration 00:12:00 → 00:06:00'), findsOneWidget);
      await tester.tap(chip(0.25));
      await tester.pump();
      expect(find.text('Duration 00:12:00 → 00:48:00'), findsOneWidget);
      expect(rig.clip(SpeedIds.video).duration, 48 * s);
    });

    testSpeed('matches the core for every chip and for custom speeds', (tester) async {
      final rig = await SpeedRig.pump(tester);
      for (final r in [...speedPresets, 1.37, 7.3, 0.13]) {
        if (speedPresets.contains(r)) {
          await tester.tap(chip(r));
        } else {
          await tester.enterText(fieldOf('speed.custom'), '$r');
          await tester.testTextInput.receiveAction(TextInputAction.done);
        }
        await tester.pump();
        final clip = rig.clip(SpeedIds.video);
        final shown = tester.widget<Text>(key('speed.duration')).data!;
        expect(shown, 'Duration ${Timecode.format(coreNormal(clip), rate)} → ${Timecode.format(clip.duration, rate)}', reason: '$r');
        expect(clip.duration, coreDuration(clip), reason: '$r');
      }
    });

    testSpeed('a curve shows its core duration too', (tester) async {
      final rig = await SpeedRig.pump(tester);
      await switchToCurve(tester);
      await tester.tap(preset('bullet'));
      await tester.pump();
      final clip = rig.clip(SpeedIds.video);
      expect(clip.duration, coreDuration(clip));
      expect(tester.widget<Text>(key('speed.duration')).data,
          'Duration ${Timecode.format(coreNormal(clip), rate)} → ${Timecode.format(clip.duration, rate)}');
      expect(clip.duration, isNot(12 * s));
    });
  });

  group('mode', () {
    testSpeed('Curve starts from a flat curve at the current speed; Constant goes to 1x', (tester) async {
      final rig = await SpeedRig.pump(tester);
      await tester.tap(chip(2));
      await tester.pump();
      await switchToCurve(tester);
      final r = rampOf(rig);
      expect(r.points, hasLength(3));
      expect(r.points.every((p) => p.y == 2), isTrue);
      expect(speedRampIssues(r), isEmpty);
      expect(rig.clip(SpeedIds.video).duration, 6 * s, reason: 'a flat curve keeps the duration');
      expect(find.byType(SpeedCurveEditor), findsOneWidget);
      expect(find.byKey(const ValueKey<String>('speed.chips')), findsNothing);
      await tester.tap(find.text(SpeedStrings.modeConstant));
      await tester.pump();
      expect(rig.clip(SpeedIds.video).speed, SpeedSpec.normal);
      expect(rig.clip(SpeedIds.video).duration, 12 * s);
      expect(find.byType(SpeedCurveEditor), findsNothing);
      expect(selected(tester, chip(1)), isTrue);
    });

    testSpeed('a clip with a ramp opens on Curve', (tester) async {
      await SpeedRig.pump(
        tester,
        video: MediaClip(
          id: SpeedIds.video,
          start: 0,
          duration: 12 * s,
          media: const MediaId('m_video'),
          speed: SpeedRampPresets.byId('hero')!,
          visual: const VisualProps(),
        ),
      );
      expect(find.byType(SpeedCurveEditor), findsOneWidget);
      expect(selected(tester, preset('hero')), isTrue);
      expect(find.byKey(const ValueKey<String>('speed.chips')), findsNothing);
    });
  });

  group('ramp presets', () {
    for (final id in SpeedRampPresets.ids) {
      testSpeed('$id applies the core ramp (one entry) and is selected', (tester) async {
        final rig = await SpeedRig.pump(tester);
        await switchToCurve(tester);
        final before = rig.entries;
        await tester.tap(preset(id));
        await tester.pump();
        expect(rampOf(rig), SpeedRampPresets.byId(id));
        expect(rampOf(rig).presetId, id);
        expect(rig.entries, before + 1);
        expect(rig.state.history.undoLabel, 'Change speed');
        expect(selected(tester, preset(id)), isTrue);
        expect(selected(tester, preset('custom')), isFalse);
        expect(find.text(SpeedStrings.presetName(id)!), findsOneWidget);
        expect(speedRampIssues(rampOf(rig)), isEmpty);
        expect(rig.clip(SpeedIds.video).duration, coreDuration(rig.clip(SpeedIds.video)));
      });
    }

    testSpeed('the presets are Montage, Hero, Bullet, Jump cut, Flash in, Flash out, Custom', (tester) async {
      await SpeedRig.pump(tester);
      await switchToCurve(tester);
      for (final label in ['Montage', 'Hero', 'Bullet', 'Jump cut', 'Flash in', 'Flash out', 'Custom']) {
        expect(find.text(label), findsWidgets, reason: label);
      }
    });

    testSpeed('editing a point makes the curve custom: Custom is selected and the preset is not', (tester) async {
      final rig = await SpeedRig.pump(tester);
      await switchToCurve(tester);
      await tester.tap(preset('hero'));
      await tester.pump();
      await tap(tester, key('speed.addPoint'));
      expect(rampOf(rig).presetId, isNull);
      expect(selected(tester, preset('custom')), isTrue);
      expect(selected(tester, preset('hero')), isFalse);
    });

    testSpeed('the Custom chip marks the preset custom without changing the curve', (tester) async {
      final rig = await SpeedRig.pump(tester);
      await switchToCurve(tester);
      await tester.tap(preset('bullet'));
      await tester.pump();
      final points = rampOf(rig).points;
      await tester.tap(preset('custom'));
      await tester.pump();
      expect(rampOf(rig).presetId, isNull);
      expect(rampOf(rig).points, points);
    });

    testSpeed('presets are limited to the device speed range', (tester) async {
      final rig = await SpeedRig.pump(tester, caps: const EditorCapabilities(supported: true, maxSpeed: 4));
      await switchToCurve(tester);
      await tester.tap(preset('flashIn'));
      await tester.pump();
      final r = rampOf(rig);
      expect(r.points.map((p) => p.y).reduce((a, b) => a > b ? a : b), 4, reason: 'flash in starts at 8x');
      expect(r.presetId, isNull, reason: 'a clamped preset is custom');
      expect(speedRampIssues(r), isEmpty);
    });
  });

  group('curve editing', () {
    const surface = EditorSurface(Size(1280, 560));

    Future<SpeedRig> heroRig(WidgetTester tester, {EditorSurface surface = surface}) async {
      final rig = await SpeedRig.pump(tester, surface: surface);
      await switchToCurve(tester);
      await tester.tap(preset('hero'));
      await tester.pump();
      await tester.ensureVisible(key('speed.curve'));
      await tester.pump();
      return rig;
    }

    double scrollOffset(WidgetTester tester) =>
        tester.state<ScrollableState>(find.descendant(of: key('speed.scroll'), matching: find.byType(Scrollable)).first).position.pixels;

    testSpeed('dragging a point is one history entry; the ramp stays valid and becomes custom; the panel does not scroll', (tester) async {
      final rig = await heroRig(tester);
      final before = rig.entries;
      final start = pointAt(tester, rampOf(rig), 2);
      final scrolled = scrollOffset(tester);
      final g = await tester.startGesture(start);
      await tester.pump();
      await g.moveTo(lineAt(tester, 0.5, 1.2));
      await tester.pump();
      await g.moveTo(lineAt(tester, 0.52, 2));
      await tester.pump();
      await g.up();
      await tester.pump();
      final r = rampOf(rig);
      expect(r.points, hasLength(6));
      expect(r.points[2].x, closeTo(0.52, 0.01));
      expect(r.points[2].y, closeTo(2, 0.1));
      expect(r.presetId, isNull);
      expect(speedRampIssues(r), isEmpty);
      expect(rig.entries, before + 1);
      expect(rig.state.history.undoLabel, 'Change speed');
      expect(rig.clip(SpeedIds.video).duration, coreDuration(rig.clip(SpeedIds.video)));
      expect(scrollOffset(tester), scrolled);
      expect(selected(tester, preset('custom')), isTrue);
      expect(tester.widget<DanaviewNumberField>(key('speed.pointSpeed')).value, r.points[2].y, reason: 'the point is selected');
      rig.editor.undo();
      await tester.pump();
      expect(rampOf(rig), SpeedRampPresets.byId('hero'));
    });

    testSpeed('a point stays between its neighbours and the end points keep their x', (tester) async {
      final rig = await heroRig(tester);
      var g = await tester.startGesture(pointAt(tester, rampOf(rig), 2));
      await g.moveTo(lineAt(tester, 0.99, 1));
      await tester.pump();
      await g.moveTo(lineAt(tester, 0.99, 1.1));
      await tester.pump();
      await g.up();
      await tester.pump();
      var r = rampOf(rig);
      expect(r.points[2].x, closeTo(0.65 - SpeedRampEdit.minGap, 1e-6));
      g = await tester.startGesture(pointAt(tester, r, 0));
      await g.moveTo(lineAt(tester, 0.5, 5));
      await tester.pump();
      await g.moveTo(lineAt(tester, 0.5, 6));
      await tester.pump();
      await g.up();
      await tester.pump();
      r = rampOf(rig);
      expect(r.points.first.x, 0);
      expect(r.points.first.y, closeTo(6, 0.5));
      expect(speedRampIssues(r), isEmpty);
    });

    testSpeed('a drag that starts off every point does not edit the curve', (tester) async {
      final rig = await heroRig(tester);
      final before = rig.entries;
      final r = rampOf(rig);
      await tester.dragFrom(lineAt(tester, 0.9, 6), const Offset(-20, 0));
      await tester.pump();
      expect(rampOf(rig), r);
      expect(rig.entries, before);
    });

    testSpeed('a tap on a point selects it without an edit; a tap elsewhere clears the selection', (tester) async {
      final rig = await heroRig(tester);
      final before = rig.entries;
      expect(find.byKey(const ValueKey<String>('speed.pointSpeed')), findsNothing);
      await tester.tapAt(pointAt(tester, rampOf(rig), 1));
      await tester.pump();
      expect(tester.widget<DanaviewNumberField>(key('speed.pointSpeed')).value, 3);
      expect(rig.entries, before);
      await tester.tapAt(lineAt(tester, 0.9, 8));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey<String>('speed.pointSpeed')), findsNothing);
      expect(rig.entries, before);
    });

    testSpeed('double-tap adds a point on the curve (one entry, selected); a double-tap on a point or on a full curve adds none',
        (tester) async {
      final rig = await heroRig(tester);
      final before = rig.entries;
      final original = rampOf(rig);
      final at = lineAt(tester, 0.1, SpeedRampEdit.speedAt(original, 0.1));
      await tester.tapAt(at);
      await tester.pump(const Duration(milliseconds: 60));
      await tester.tapAt(at);
      await tester.pumpAndSettle();
      var r = rampOf(rig);
      expect(r.points, hasLength(7));
      expect(r.points[1].x, closeTo(0.1, 0.01));
      expect(r.points[1].y, closeTo(SpeedRampEdit.speedAt(original, 0.1), 0.05), reason: 'the curve keeps its shape');
      expect(r.presetId, isNull);
      expect(speedRampIssues(r), isEmpty);
      expect(rig.entries, before + 1);
      expect(rig.state.history.undoLabel, 'Change speed');
      expect(tester.widget<DanaviewNumberField>(key('speed.pointSpeed')).value, r.points[1].y);

      // Full now.
      final at2 = lineAt(tester, 0.9, SpeedRampEdit.speedAt(r, 0.9));
      await tester.tapAt(at2);
      await tester.pump(const Duration(milliseconds: 60));
      await tester.tapAt(at2);
      await tester.pumpAndSettle();
      expect(rampOf(rig), r);
      expect(rig.entries, before + 1);
      rig.editor.undo();
      await tester.pump();

      // On a point.
      final onPoint = pointAt(tester, original, 3);
      await tester.tapAt(onPoint);
      await tester.pump(const Duration(milliseconds: 60));
      await tester.tapAt(onPoint);
      await tester.pumpAndSettle();
      r = rampOf(rig);
      expect(r, original);
    });

    testSpeed('long-press deletes an interior point; never below 3 points; the end points stay', (tester) async {
      final rig = await heroRig(tester);
      final before = rig.entries;
      var g = await tester.startGesture(pointAt(tester, rampOf(rig), 2));
      await tester.pump(const Duration(milliseconds: 700));
      await g.up();
      await tester.pump();
      var r = rampOf(rig);
      expect(r.points, hasLength(5));
      expect(r.presetId, isNull);
      expect(speedRampIssues(r), isEmpty);
      expect(rig.entries, before + 1);
      // The end points stay.
      g = await tester.startGesture(pointAt(tester, r, 0));
      await tester.pump(const Duration(milliseconds: 700));
      await g.up();
      await tester.pump();
      expect(rampOf(rig), r);
      // Down to three points.
      for (var i = 0; i < 3; i++) {
        r = rampOf(rig);
        g = await tester.startGesture(pointAt(tester, r, 1));
        await tester.pump(const Duration(milliseconds: 700));
        await g.up();
        await tester.pump();
      }
      expect(rampOf(rig).points, hasLength(3));
      expect(rig.entries, before + 3, reason: 'two more deletions, then nothing');
    });

    testSpeed('moving before the long press time cancels it', (tester) async {
      final rig = await heroRig(tester);
      final g = await tester.startGesture(pointAt(tester, rampOf(rig), 2));
      await g.moveBy(const Offset(0, -30));
      await tester.pump(const Duration(milliseconds: 700));
      await g.up();
      await tester.pump();
      expect(rampOf(rig).points, hasLength(6));
    });

    testSpeed('Add point and Delete point are the button alternatives, with the 3-7 point limits', (tester) async {
      final rig = await heroRig(tester);
      expect(tester.widget<DanaviewButton>(key('speed.deletePoint')).onPressed, isNull, reason: 'nothing selected');
      await tap(tester, key('speed.addPoint'));
      var r = rampOf(rig);
      expect(r.points, hasLength(7));
      expect(r.presetId, isNull);
      expect(speedRampIssues(r), isEmpty);
      expect(tester.widget<DanaviewButton>(key('speed.addPoint')).onPressed, isNull, reason: 'seven is the most');
      expect(find.text(SpeedStrings.curveFull), findsOneWidget);
      expect(tester.widget<DanaviewButton>(key('speed.deletePoint')).onPressed, isNotNull, reason: 'the new point is selected');
      await tap(tester, key('speed.deletePoint'));
      r = rampOf(rig);
      expect(r.points, hasLength(6));
      expect(find.text(SpeedStrings.curveFull), findsNothing);
      expect(find.byKey(const ValueKey<String>('speed.pointSpeed')), findsNothing, reason: 'the selection was deleted');
      // Select an end point: no delete.
      await tester.tapAt(pointAt(tester, r, 0));
      await tester.pump();
      expect(tester.widget<DanaviewButton>(key('speed.deletePoint')).onPressed, isNull);
    });

    testSpeed('the selected point has speed and position fields; the end points cannot change position', (tester) async {
      final rig = await heroRig(tester);
      await tester.tapAt(pointAt(tester, rampOf(rig), 2));
      await tester.pump();
      final before = rig.entries;
      await tester.enterText(fieldOf('speed.pointSpeed'), '2.5');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect(rampOf(rig).points[2].y, 2.5);
      expect(rig.entries, before + 1);
      now = now.add(const Duration(seconds: 1));
      await tester.enterText(fieldOf('speed.pointPosition'), '50');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect(rampOf(rig).points[2].x, 0.5);
      expect(rig.entries, before + 2);
      expect(speedRampIssues(rampOf(rig)), isEmpty);
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      await tester.ensureVisible(key('speed.curve'));
      await tester.pumpAndSettle();
      await tester.tapAt(pointAt(tester, rampOf(rig), 0));
      await tester.pumpAndSettle();
      expect(tester.widget<DanaviewNumberField>(key('speed.pointPosition')).enabled, isFalse);
      expect(tester.widget<DanaviewNumberField>(key('speed.pointSpeed')).enabled, isTrue);
    });

    testSpeed('arrow keys move the selected point, Delete removes it', (tester) async {
      final rig = await heroRig(tester);
      await tester.tapAt(pointAt(tester, rampOf(rig), 2));
      await tester.pump();
      final before = rig.entries;
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pump();
      expect(rampOf(rig).points[2].y, 0.38, reason: '0.3 up one step');
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      expect(rampOf(rig).points[2].x, 0.46);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      expect(rampOf(rig).points[2].x, 0.44);
      expect(rampOf(rig).points[2].y, 0.3);
      expect(rig.entries, before + 1, reason: 'steps within 500 ms share one entry');
      await tester.sendKeyEvent(LogicalKeyboardKey.delete);
      await tester.pump();
      expect(rampOf(rig).points, hasLength(5));
      expect(rig.entries, before + 2);
    });

    group('semantics', () {
      SemanticsNode node(WidgetTester tester, int i, int n) => tester.getSemantics(find.bySemanticsLabel('Point $i of $n'));

      void perform(WidgetTester tester, SemanticsNode n, SemanticsAction action, [Object? arguments]) {
        // ignore: invalid_use_of_protected_member
        SemanticsBinding.instance
            .performSemanticsAction(SemanticsActionEvent(type: action, nodeId: n.id, viewId: tester.view.viewId, arguments: arguments));
      }

      testSpeed('each point is a node with its speed and position, increase/decrease change the speed', (tester) async {
        final handle = tester.ensureSemantics();
        final rig = await heroRig(tester);
        expect(find.bySemanticsLabel('Speed curve, 6 points'), findsOneWidget);
        final n = node(tester, 2, 6);
        expect(n.value, '3×, at 30% of the clip');
        final before = rig.entries;
        perform(tester, n, SemanticsAction.increase);
        await tester.pump();
        expect(rampOf(rig).points[1].y, 3.78);
        perform(tester, node(tester, 2, 6), SemanticsAction.decrease);
        perform(tester, node(tester, 2, 6), SemanticsAction.decrease);
        await tester.pump();
        expect(rampOf(rig).points[1].y, closeTo(2.38, 0.05));
        expect(rig.entries, before + 1, reason: 'steps within 500 ms share one entry');
        expect(rampOf(rig).presetId, isNull);
        handle.dispose();
      });

      testSpeed('move earlier, move later and delete are custom actions; the end points cannot move or go', (tester) async {
        final handle = tester.ensureSemantics();
        final rig = await heroRig(tester);
        const earlier = CustomSemanticsAction(label: SpeedStrings.moveEarlier);
        const later = CustomSemanticsAction(label: SpeedStrings.moveLater);
        const delete = CustomSemanticsAction(label: SpeedStrings.deletePoint);
        final ids = CustomSemanticsAction.getIdentifier;
        var n = node(tester, 3, 6);
        expect(n.getSemanticsData().customSemanticsActionIds, containsAll([ids(earlier), ids(later), ids(delete)]));
        perform(tester, n, SemanticsAction.customAction, ids(earlier));
        await tester.pump();
        expect(rampOf(rig).points[2].x, closeTo(0.40, 1e-9));
        n = node(tester, 3, 6);
        perform(tester, n, SemanticsAction.customAction, ids(later));
        await tester.pump();
        expect(rampOf(rig).points[2].x, closeTo(0.45, 1e-9));
        n = node(tester, 3, 6);
        perform(tester, n, SemanticsAction.customAction, ids(delete));
        await tester.pump();
        expect(rampOf(rig).points, hasLength(5));
        final end = node(tester, 1, 5).getSemanticsData();
        expect(end.customSemanticsActionIds, isNot(contains(ids(delete))));
        expect(end.customSemanticsActionIds, isNot(contains(ids(earlier))));
        handle.dispose();
      });
    });
  });

  group('keep audio pitch', () {
    testSpeed('toggles maintainPitch without changing the speed (one entry)', (tester) async {
      final rig = await SpeedRig.pump(tester);
      await tester.tap(chip(2));
      await tester.pump();
      final before = rig.entries;
      expect(rig.clip(SpeedIds.video).maintainPitch, isTrue);
      await tap(tester, key('speed.keepPitch'));
      expect(rig.clip(SpeedIds.video).maintainPitch, isFalse);
      expect(rig.clip(SpeedIds.video).speed, const ConstantSpeed(2));
      expect(rig.clip(SpeedIds.video).duration, 6 * s);
      expect(rig.entries, before + 1);
      await tap(tester, key('speed.keepPitch'));
      expect(rig.clip(SpeedIds.video).maintainPitch, isTrue);
    });

    testSpeed('is shown for audio clips and hidden for media without audio', (tester) async {
      await SpeedRig.pump(tester, open: SpeedIds.audio);
      expect(find.byKey(const ValueKey<String>('speed.keepPitch')), findsOneWidget);
      await SpeedRig.pump(tester, open: SpeedIds.silent);
      expect(find.byKey(const ValueKey<String>('speed.keepPitch')), findsNothing);
    });
  });

  group('capability note', () {
    const note = 'Audio is muted above 4× on this device';

    testSpeed('shown when a constant speed is above maxAudioSpeed, not at or below it', (tester) async {
      await SpeedRig.pump(tester);
      expect(find.text(note), findsNothing);
      await tester.tap(chip(4));
      await tester.pump();
      expect(find.text(note), findsNothing, reason: '4x is still played');
      await tester.enterText(fieldOf('speed.custom'), '5');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect(find.text(note), findsOneWidget);
      await tester.tap(chip(0.5));
      await tester.pump();
      expect(find.text(note), findsNothing);
    });

    testSpeed('names the device limit', (tester) async {
      await SpeedRig.pump(tester, caps: const EditorCapabilities(supported: true, maxAudioSpeed: 2));
      await tester.tap(chip(3));
      await tester.pump();
      expect(find.text('Audio is muted above 2× on this device'), findsOneWidget);
    });

    testSpeed('is not shown when the engine plays audio at any speed in range', (tester) async {
      await SpeedRig.pump(tester, caps: const EditorCapabilities(supported: true, maxAudioSpeed: 10));
      await tester.enterText(fieldOf('speed.custom'), '9');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect(find.textContaining('Audio is muted'), findsNothing);
    });

    testSpeed('is not shown for media without audio or a muted clip', (tester) async {
      await SpeedRig.pump(tester, open: SpeedIds.silent);
      await tester.enterText(fieldOf('speed.custom'), '8');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect(find.textContaining('Audio is muted'), findsNothing);
      await SpeedRig.pump(
        tester,
        video: MediaClip(
          id: SpeedIds.video,
          start: 0,
          duration: 12 * s,
          media: const MediaId('m_video'),
          speed: const ConstantSpeed(8),
          visual: const VisualProps(),
          audio: const AudioProps(muted: true),
        ),
      );
      expect(find.textContaining('Audio is muted'), findsNothing);
    });

    testSpeed('a curve names the spans: shown when any point is above the limit', (tester) async {
      await SpeedRig.pump(tester);
      await switchToCurve(tester);
      await tester.tap(preset('bullet'));
      await tester.pump();
      expect(find.textContaining('Audio is muted'), findsNothing, reason: 'bullet peaks at 3x');
      await tester.tap(preset('flashIn'));
      await tester.pump();
      expect(find.text('Audio is muted where the speed is above 4× on this device'), findsOneWidget);
    });
  });

  group('reverse and freeze frame (UX-35 actions)', () {
    testSpeed('are disabled while the actions are unbound', (tester) async {
      await SpeedRig.pump(
        tester,
        overrides: [
          editorActionBindingsProvider.overrideWithValue({
            for (final e in mergeEditorActionBindings().entries)
              if (e.key != EditorActionId.reverse && e.key != EditorActionId.freeze) e.key: e.value,
          }),
        ],
      );
      expect(find.text('Reverse'), findsOneWidget);
      expect(find.text('Freeze frame'), findsOneWidget);
      expect(tester.widget<DanaviewButton>(key('speed.reverse')).onPressed, isNull);
      expect(tester.widget<DanaviewButton>(key('speed.freeze')).onPressed, isNull);
    });

    testSpeed('delegate to the bound actions', (tester) async {
      final ran = <EditorActionId>[];
      EditorActionBinding bind(EditorActionId id) => EditorActionBinding(id: id, handler: (ctx) => ran.add(id));
      await SpeedRig.pump(
        tester,
        overrides: [
          editorActionBindingsProvider.overrideWithValue({
            ...mergeEditorActionBindings(),
            EditorActionId.reverse: bind(EditorActionId.reverse),
            EditorActionId.freeze: bind(EditorActionId.freeze),
          }),
        ],
      );
      await tap(tester, key('speed.reverse'));
      expect(ran, [EditorActionId.reverse]);
      await tap(tester, key('speed.freeze'));
      expect(ran, [EditorActionId.reverse, EditorActionId.freeze]);
    });

    testSpeed('a disabled action stays disabled; a reversed clip says so', (tester) async {
      await SpeedRig.pump(
        tester,
        video: MediaClip(
          id: SpeedIds.video,
          start: 0,
          duration: 12 * s,
          media: const MediaId('m_video'),
          reversed: true,
          visual: const VisualProps(),
        ),
        overrides: [
          editorActionBindingsProvider.overrideWithValue({
            ...mergeEditorActionBindings(),
            EditorActionId.freeze: EditorActionBinding(
                id: EditorActionId.freeze,
                handler: (ctx) {},
                isEnabled: (ctx) => false,
                disabledReason: (ctx) => 'Move the playhead over the clip'),
          }),
        ],
      );
      expect(find.text('Reversed'), findsOneWidget);
      expect(tester.widget<DanaviewButton>(key('speed.freeze')).onPressed, isNull);
      expect(tester.widget<DanaviewButton>(key('speed.freeze')).tooltip, 'Move the playhead over the clip');
    });
  });

  group('reset', () {
    testSpeed('the header offers Reset only away from 1x; it returns to 1x as one entry', (tester) async {
      final rig = await SpeedRig.pump(tester);
      expect(find.byTooltip(InspectorStrings.reset), findsNothing);
      await tester.tap(chip(3));
      await tester.pump();
      await tester.pump();
      expect(find.byTooltip(InspectorStrings.reset), findsOneWidget);
      final before = rig.entries;
      await tester.tap(find.byTooltip(InspectorStrings.reset));
      await tester.pumpAndSettle();
      expect(rig.clip(SpeedIds.video).speed, SpeedSpec.normal);
      expect(rig.clip(SpeedIds.video).duration, 12 * s);
      expect(rig.entries, before + 1);
      expect(find.byTooltip(InspectorStrings.reset), findsNothing);
    });

    testSpeed('resets a curve to 1x constant', (tester) async {
      final rig = await SpeedRig.pump(tester);
      await switchToCurve(tester);
      await tester.tap(preset('montage'));
      await tester.pump();
      await tester.pump();
      await tester.tap(find.byTooltip(InspectorStrings.reset));
      await tester.pumpAndSettle();
      expect(rig.clip(SpeedIds.video).speed, SpeedSpec.normal);
      expect(find.byType(SpeedCurveEditor), findsNothing);
    });
  });

  group('other clips and states', () {
    testSpeed('an audio clip: chips work and the duration readout follows', (tester) async {
      final rig = await SpeedRig.pump(tester, open: SpeedIds.audio);
      expect(find.text('Duration 00:10:00 → 00:10:00'), findsOneWidget);
      await tester.tap(chip(2));
      await tester.pump();
      expect(rig.clip(SpeedIds.audio).speed, const ConstantSpeed(2));
      expect(find.text('Duration 00:10:00 → 00:05:00'), findsOneWidget);
    });

    testSpeed('a locked track: everything is disabled and the panel says why', (tester) async {
      final rig = await SpeedRig.pump(tester, open: SpeedIds.locked, selectOpen: false);
      expect(find.text(SpeedStrings.trackLocked), findsOneWidget);
      for (final r in speedPresets) {
        expect(tester.widget<DanaviewChoiceChip>(chip(r)).enabled, isFalse);
      }
      expect(tester.widget<DanaviewNumberField>(key('speed.custom')).enabled, isFalse);
      expect(tester.widget<DanaviewSwitchRow>(key('speed.keepPitch')).onChanged, isNull);
      expect(find.byTooltip(InspectorStrings.reset), findsNothing);
      await tester.tap(chip(2), warnIfMissed: false);
      await tester.pump();
      expect(rig.clip(SpeedIds.locked).speed, SpeedSpec.normal);
    });

    testSpeed('the panel re-targets when the open route points at another clip', (tester) async {
      final rig = await SpeedRig.pump(tester);
      expect(find.text('Duration 00:12:00 → 00:12:00'), findsOneWidget);
      rig.editor.select(SpeedIds.audio);
      await tester.pump();
      await tester.pump();
      expect(rig.state.inspector, const SpeedInspector(SpeedIds.audio));
      expect(find.text('Duration 00:10:00 → 00:10:00'), findsOneWidget);
    });

    testSpeed('closes for an image (no speed)', (tester) async {
      final rig = await SpeedRig.pump(tester);
      rig.editor.select(SpeedIds.image);
      await tester.pump();
      await tester.pump();
      await tester.pump();
      expect(find.byType(SpeedPanel), findsNothing);
    });
  });

  group('ripple', () {
    testSpeed('with ripple on, the following clips move by the duration change', (tester) async {
      final rig = await SpeedRig.pump(tester);
      await tester.tap(chip(2));
      await tester.pump();
      expect(rig.clip(SpeedIds.silent).start, 6 * s);
      expect(rig.clip(SpeedIds.image).start, 8 * s);
    });

    testSpeed('with ripple off, a slow-down stops at the next clip', (tester) async {
      final rig = await SpeedRig.pump(tester, ripple: false);
      await tester.tap(chip(0.5));
      await tester.pump();
      expect(rig.clip(SpeedIds.silent).start, 12 * s);
      expect(rig.clip(SpeedIds.video).duration, 12 * s);
      expect(rig.clip(SpeedIds.video).speed, const ConstantSpeed(0.5));
      expect(rig.clip(SpeedIds.video).duration, lessThan(coreDuration(rig.clip(SpeedIds.video)) + 1));
    });
  });

  group('matrix (no overflow, owner UI rules)', () {
    testSpeedSurfaces('constant speed', (tester, surface) async {
      final rig = await SpeedRig.pump(tester, surface: surface);
      await tester.tap(chip(0.25), warnIfMissed: false);
      await tester.enterText(fieldOf('speed.custom'), '8');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect(rig.clip(SpeedIds.video).speed, const ConstantSpeed(8));
      expect(find.textContaining('Audio is muted'), findsOneWidget);
      expectNoOverflow(tester);
      expectOwnerUiRules(tester);
    });

    testSpeedSurfaces('curve with a selected point', (tester, surface) async {
      final rig = await SpeedRig.pump(tester, surface: surface);
      await switchToCurve(tester);
      await tap(tester, preset('flashIn'));
      await tap(tester, key('speed.addPoint'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey<String>('speed.pointSpeed')), findsOneWidget, reason: 'the added point is selected');
      expectNoOverflow(tester);
      expectOwnerUiRules(tester);
      final curve = tester.getRect(key('speed.curve'));
      expect(curve.left, greaterThanOrEqualTo(0));
      expect(curve.right, lessThanOrEqualTo(surface.size.width));
      expect(curve.width, greaterThan(150), reason: 'the plot has room to draw');
      for (final k in ['speed.addPoint', 'speed.deletePoint', 'speed.pointSpeed', 'speed.pointPosition']) {
        await tester.ensureVisible(key(k));
        await tester.pumpAndSettle();
        final r = tester.getRect(key(k));
        expect(r.left, greaterThanOrEqualTo(0), reason: k);
        expect(r.right, lessThanOrEqualTo(surface.size.width), reason: k);
      }
      expectNoOverflow(tester);
    });

    testSpeedSurfaces('locked track', (tester, surface) async {
      await SpeedRig.pump(tester, surface: surface, open: SpeedIds.locked, selectOpen: false);
      expect(find.text(SpeedStrings.trackLocked), findsOneWidget);
      expectNoOverflow(tester);
      expectOwnerUiRules(tester);
    });
  });
}
