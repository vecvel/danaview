// OWNER: UX-27
//
// The transitions panel (ux.md §10.12): every tile and direction dispatches one CORE-16 command
// (one history entry each), the duration slider is limited by TransitionLimits with the "Longer
// transitions need more video…" copy when capped, kinds that cannot fit are disabled, the loop
// preview plays `cut ± (d/2 + 0.75 s)` and restores the play state, playhead and loop afterwards
// (fake engine), "Apply to all cuts" is one history entry, and the matrix (no overflow, owner UI
// rules).

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_editor/src/app/strings/transition_strings.dart';
import 'package:danaview_editor/src/editor/inspector/inspector_rows.dart';
import 'package:danaview_editor/src/editor/panels/transitions_panel.dart';
import 'package:danaview_editor/src/editor/timeline/timeline_semantics.dart' show EditorAnnouncer;
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_editor_core/ops.dart' show TransitionSpec;
import 'package:danaview_ui_kit/danaview_ui_kit.dart';

import '../../support/support.dart';
import 'transitions_rig.dart';

/// The loop of the bare A|B cut (4 s ± 0.75 s, widened to whole frames).
final TimeRange bareAb = TimeRange(frames(97), frames(143));

Finder key(String k) => find.byKey(ValueKey<String>(k));

Finder tile(TransitionKind? kind) => key(TransitionPanelModel.tileKey(kind));

bool selected(WidgetTester tester, TransitionKind? kind) => tester.widget<DanaviewChoiceChip>(tile(kind)).selected;

bool enabled(WidgetTester tester, TransitionKind? kind) => tester.widget<DanaviewChoiceChip>(tile(kind)).enabled;

InspectorSliderRow durationRow(WidgetTester tester) => tester.widget<InspectorSliderRow>(key('transitions.duration'));

/// Scrolls [finder] into view and taps it.
Future<void> tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pump();
  await tester.tap(finder);
  await tester.pump();
}

/// Taps the direction segment labelled [d].
Future<void> tapDirection(WidgetTester tester, TransitionDirection d) async {
  final f = find.descendant(of: key('transitions.direction'), matching: find.text(TransitionStrings.directionLabel(d)));
  await tap(tester, f);
}

void testTransitions(String description, Future<void> Function(WidgetTester tester) body) => testWidgets(description, (tester) async {
      try {
        await body(tester);
        await tester.pump(const Duration(seconds: 5));
      } finally {
        EditorAnnouncer.instance.reset();
      }
    });

void testTransitionSurfaces(String description, Future<void> Function(WidgetTester tester, EditorSurface surface) body) =>
    testSurfaces(description, (tester, surface) async {
      try {
        await body(tester, surface);
        await tester.pump(const Duration(seconds: 5));
      } finally {
        EditorAnnouncer.instance.reset();
      }
    });

void main() {
  late DateTime now;
  setUp(() {
    EditorAnnouncer.instance.reset();
    now = DateTime.utc(2026, 10, 14, 9);
    InspectorRows.clock = () => now;
  });
  tearDown(() => InspectorRows.clock = DateTime.now);

  group('model', () {
    test('frames, seconds and the slider range', () {
      expect(TransitionPanelModel.framesOf(TransitionPanelModel.minDuration, rate), 3);
      expect(TransitionPanelModel.framesOf(TransitionPanelModel.maxDuration, rate), 60);
      expect(TransitionPanelModel.framesOf(TransitionPanelModel.defaultDuration, rate), 15);
      expect(TransitionPanelModel.secondsOf(15, rate), 0.5);
      expect(TransitionPanelModel.sliderMaxFrames(1000, rate), 60);
      expect(TransitionPanelModel.sliderMaxFrames(18, rate), 18);
      expect(TransitionPanelModel.sliderMinFrames(18, rate), 3);
      expect(TransitionPanelModel.sliderMinFrames(2, rate), 2);
      expect(TransitionPanelModel.isLimited(18, rate), isTrue);
      expect(TransitionPanelModel.isLimited(60, rate), isFalse);
      expect(TransitionPanelModel.defaultFrames(10, rate), 10);
    });

    test('directions keep their family', () {
      expect(TransitionPanelModel.directionFor(TransitionKind.wipe, TransitionDirection.right), TransitionDirection.right);
      expect(TransitionPanelModel.directionFor(TransitionKind.zoom, TransitionDirection.right), TransitionDirection.zoomIn);
      expect(TransitionPanelModel.directionFor(TransitionKind.slide, TransitionDirection.zoomOut), TransitionDirection.left);
      expect(TransitionPanelModel.directionFor(TransitionKind.fade, TransitionDirection.left), isNull);
    });

    test('the loop window is cut ± (d/2 + 0.75 s) inside the project', () {
      // 1 s transition at 4 s (frame 120): ±37.5 frames, widened to frames 82..158.
      expect(TransitionPanelModel.loopRange(cut: 4 * s, frames: 30, rate: rate, projectDuration: 14 * s), TimeRange(frames(82), frames(158)));
      // The bare cut: ±22.5 frames → 97..143.
      expect(TransitionPanelModel.loopRange(cut: 4 * s, frames: 0, rate: rate, projectDuration: 14 * s), TimeRange(frames(97), frames(143)));
      expect(TransitionPanelModel.loopRange(cut: frames(15), frames: 30, rate: rate, projectDuration: 14 * s), TimeRange(0, frames(53)));
      expect(TransitionPanelModel.loopRange(cut: 13 * s, frames: 30, rate: rate, projectDuration: 14 * s), TimeRange(frames(352), 14 * s));
    });
  });

  group('tiles', () {
    testTransitions('eight labelled tiles with their glyphs; None is selected without a transition', (tester) async {
      await TransitionsRig.pump(tester);
      for (final kind in TransitionPanelModel.tiles) {
        final chip = tester.widget<DanaviewChoiceChip>(tile(kind));
        expect(chip.label, kind == null ? 'None' : TransitionStrings.kindName(kind));
        expect(chip.icon, TransitionPanelModel.iconOf(kind));
        expect(chip.enabled, isTrue, reason: '$kind fits at A|B');
      }
      expect(selected(tester, null), isTrue);
      expect(find.text('Cross dissolve'), findsOneWidget);
      expect(find.text('Dip to white'), findsOneWidget);
      expect(key('transitions.duration'), findsNothing, reason: 'no duration without a transition');
      expect(key('transitions.direction'), findsNothing);
    });

    for (final kind in TransitionKind.values) {
      testTransitions('${kind.name}: one SetTransition, one history entry, default 0.5 s and direction', (tester) async {
        final rig = await TransitionsRig.pump(tester);
        final before = rig.entries;
        await tap(tester, tile(kind));
        final t = rig.at(Cuts.ab)!;
        expect(t.kind, kind);
        expect(t.durationFrames, 15);
        expect(t.direction, TransitionSpec.defaultDirection(kind));
        expect(rig.entries, before + 1);
        expect(rig.state.history.undoLabel, 'Set transition');
        expect(selected(tester, kind), isTrue);
        expect(selected(tester, null), isFalse);
        expect(key('transitions.duration'), findsOneWidget);
        expect(key('transitions.direction'), TransitionSpec.directionsOf(kind).isEmpty ? findsNothing : findsOneWidget);
        await tap(tester, tile(kind));
        expect(rig.entries, before + 1, reason: 'tapping the selected tile again changes nothing');
      });
    }

    testTransitions('None removes the transition (one entry); undo brings it back', (tester) async {
      final rig = await TransitionsRig.pump(tester);
      await tap(tester, tile(TransitionKind.dipToBlack));
      final before = rig.entries;
      await tap(tester, tile(null));
      expect(rig.at(Cuts.ab), isNull);
      expect(rig.entries, before + 1);
      expect(rig.state.history.undoLabel, 'Remove transition');
      expect(selected(tester, null), isTrue);
      rig.editor.undo();
      await tester.pump();
      expect(rig.at(Cuts.ab)!.kind, TransitionKind.dipToBlack);
      expect(selected(tester, TransitionKind.dipToBlack), isTrue);
    });

    testTransitions('switching kinds keeps the duration and a direction of the same family', (tester) async {
      final rig = await TransitionsRig.pump(tester);
      await tap(tester, tile(TransitionKind.slide));
      await tapDirection(tester, TransitionDirection.down);
      durationRow(tester).onSubmitted!(1.0);
      await tester.pump();
      expect(rig.at(Cuts.ab)!.durationFrames, 30);
      await tap(tester, tile(TransitionKind.wipe));
      expect(rig.at(Cuts.ab)!.direction, TransitionDirection.down);
      expect(rig.at(Cuts.ab)!.durationFrames, 30);
      await tap(tester, tile(TransitionKind.zoom));
      expect(rig.at(Cuts.ab)!.direction, TransitionDirection.zoomIn);
      await tap(tester, tile(TransitionKind.crossDissolve));
      expect(rig.at(Cuts.ab)!.direction, isNull);
      expect(rig.at(Cuts.ab)!.durationFrames, 30);
    });
  });

  group('direction', () {
    for (final kind in [TransitionKind.slide, TransitionKind.wipe, TransitionKind.zoom]) {
      testTransitions('${kind.name}: every direction is one entry', (tester) async {
        final rig = await TransitionsRig.pump(tester);
        await tap(tester, tile(kind));
        final directions = TransitionSpec.directionsOf(kind);
        expect(tester.widget<InspectorChoiceRow<TransitionDirection>>(key('transitions.direction')).options.map((o) => o.value), directions);
        for (final d in [...directions.skip(1), directions.first]) {
          final before = rig.entries;
          await tapDirection(tester, d);
          expect(rig.at(Cuts.ab)!.direction, d);
          expect(rig.at(Cuts.ab)!.kind, kind);
          expect(rig.entries, before + 1, reason: '$d');
        }
      });
    }

    testTransitions('fade, cross dissolve and dips have no direction control', (tester) async {
      await TransitionsRig.pump(tester);
      for (final kind in [TransitionKind.fade, TransitionKind.crossDissolve, TransitionKind.dipToBlack, TransitionKind.dipToWhite]) {
        await tap(tester, tile(kind));
        expect(key('transitions.direction'), findsNothing, reason: kind.name);
      }
    });
  });

  group('duration', () {
    testTransitions('0.1 s to 2 s at a cut with long handles, no limit copy', (tester) async {
      await TransitionsRig.pump(tester);
      await tap(tester, tile(TransitionKind.crossDissolve));
      final row = durationRow(tester);
      expect(row.min, closeTo(0.1, 1e-9));
      expect(row.max, closeTo(2.0, 1e-9));
      expect(row.value, closeTo(0.5, 1e-9));
      expect(row.step, closeTo(1 / 30, 1e-9));
      expect(row.valueText, '0.50 s');
      expect(key('transitions.limited'), findsNothing);
    });

    testTransitions('a slider drag is one history entry in whole frames', (tester) async {
      final rig = await TransitionsRig.pump(tester);
      await tap(tester, tile(TransitionKind.fade));
      final before = rig.entries;
      final slider = find.descendant(of: key('transitions.duration'), matching: find.byType(DanaviewSlider));
      await tester.ensureVisible(slider);
      await tester.pump();
      final box = tester.getRect(slider);
      final gesture = await tester.startGesture(box.centerLeft + const Offset(10, 0));
      await tester.pump();
      for (var i = 1; i <= 6; i++) {
        await gesture.moveBy(Offset(box.width / 8, 0));
        await tester.pump();
      }
      await gesture.up();
      await tester.pump();
      expect(rig.entries, before + 1);
      expect(rig.state.history.undoLabel, TransitionStrings.historyDuration);
      final t = rig.at(Cuts.ab)!;
      expect(t.durationFrames, greaterThan(15));
      expect(t.durationFrames, lessThanOrEqualTo(60));
    });

    testTransitions('a typed value is one entry; above 2 s it stops at 2 s', (tester) async {
      final rig = await TransitionsRig.pump(tester);
      await tap(tester, tile(TransitionKind.fade));
      final before = rig.entries;
      durationRow(tester).onSubmitted!(1.2);
      await tester.pump();
      expect(rig.at(Cuts.ab)!.durationFrames, 36);
      durationRow(tester).onSubmitted!(5);
      await tester.pump();
      expect(rig.at(Cuts.ab)!.durationFrames, 60);
      expect(rig.entries, before + 2);
    });

    testTransitions('limited by TransitionLimits: the slider stops at the limit and the panel explains why', (tester) async {
      final rig = await TransitionsRig.pump(tester, open: Cuts.bc);
      await tap(tester, tile(TransitionKind.crossDissolve));
      expect(rig.at(Cuts.bc)!.durationFrames, 15);
      final row = durationRow(tester);
      expect(row.max, closeTo(0.6, 1e-9), reason: '2 × 9 frames of handle');
      expect(find.text(TransitionStrings.limited), findsOneWidget);
      durationRow(tester).onSubmitted!(2);
      await tester.pump();
      expect(rig.at(Cuts.bc)!.durationFrames, 18, reason: 'clamped to the limit');
      await tap(tester, tile(TransitionKind.fade));
      expect(durationRow(tester).max, closeTo(2.0, 1e-9), reason: 'a fade needs no handles');
      expect(find.text(TransitionStrings.limited), findsNothing);
    });

    testTransitions('a long fade switched to a cross dissolve is shortened to the limit', (tester) async {
      final rig = await TransitionsRig.pump(tester, open: Cuts.bc);
      await tap(tester, tile(TransitionKind.fade));
      durationRow(tester).onSubmitted!(1.5);
      await tester.pump();
      expect(rig.at(Cuts.bc)!.durationFrames, 45);
      await tap(tester, tile(TransitionKind.crossDissolve));
      expect(rig.at(Cuts.bc)!.kind, TransitionKind.crossDissolve);
      expect(rig.at(Cuts.bc)!.durationFrames, 18);
    });

    testTransitions('without handles the overlap kinds are disabled with an explanation', (tester) async {
      final rig = await TransitionsRig.pump(tester, open: Cuts.overlayCut);
      for (final kind in TransitionKind.values) {
        expect(enabled(tester, kind), !kind.needsHandles, reason: kind.name);
      }
      expect(find.text(TransitionStrings.needsHandles), findsOneWidget);
      await tap(tester, tile(TransitionKind.crossDissolve));
      expect(rig.at(Cuts.overlayCut), isNull);
      await tap(tester, tile(TransitionKind.dipToWhite));
      expect(rig.at(Cuts.overlayCut)!.kind, TransitionKind.dipToWhite);
    });
  });

  group('loop preview', () {
    testTransitions('opening plays cut ± (d/2 + 0.75 s) in a loop; leaving restores a paused playhead', (tester) async {
      final rig = await TransitionsRig.pump(tester, playheadAt: s);
      expect(rig.preview.playing, isTrue);
      expect(rig.preview.loop, bareAb, reason: 'no transition yet: the bare cut');
      expect(rig.transport.loop.value, rig.preview.loop);
      expect(find.text(TransitionStrings.stopPreview), findsOneWidget);
      await tap(tester, tile(TransitionKind.crossDissolve));
      await rig.settle();
      expect(rig.preview.loop, TimeRange(frames(90), frames(150)), reason: 'the loop follows the duration');
      await rig.closePanel();
      expect(find.byType(TransitionsPanel), findsNothing);
      expect(rig.preview.playing, isFalse);
      expect(rig.transport.playing.value, isFalse);
      expect(rig.transport.loop.value, isNull);
      expect(rig.playhead.value, s);
    });

    testTransitions('a playing transport with a loop range is restored playing with that range', (tester) async {
      final loop = TimeRange(10 * s, 12 * s);
      final rig = await TransitionsRig.pump(tester, open: null, playheadAt: 10 * s);
      await rig.real(() => rig.transport.setLoop(loop));
      await rig.real(() => rig.transport.play());
      expect(rig.preview.playing, isTrue);
      await rig.openPanel(Cuts.ab);
      expect(rig.preview.loop, bareAb);
      await rig.closePanel();
      expect(rig.preview.playing, isTrue);
      expect(rig.transport.loop.value, loop);
      expect(rig.preview.loop, loop);
      expect(rig.playhead.value, 10 * s);
    });

    testTransitions('Stop preview pauses and Play preview resumes the loop; leaving still restores', (tester) async {
      final rig = await TransitionsRig.pump(tester, playheadAt: 2 * s);
      await tap(tester, key('transitions.preview'));
      await rig.settle();
      expect(rig.preview.playing, isFalse);
      expect(rig.transport.loop.value, isNull);
      expect(find.text(TransitionStrings.playPreview), findsOneWidget);
      await tap(tester, key('transitions.preview'));
      await rig.settle();
      expect(rig.preview.playing, isTrue);
      expect(rig.preview.loop, bareAb);
      expect(find.text(TransitionStrings.stopPreview), findsOneWidget);
      await rig.closePanel();
      expect(rig.preview.playing, isFalse);
      expect(rig.playhead.value, 2 * s);
    });

    testTransitions('moving to another cut keeps the saved state and loops the new cut', (tester) async {
      final rig = await TransitionsRig.pump(tester, playheadAt: s);
      await rig.openPanel(Cuts.cd);
      expect(rig.preview.loop, TimeRange(frames(337), frames(383)));
      await rig.closePanel();
      expect(rig.preview.playing, isFalse);
      expect(rig.transport.loop.value, isNull);
      expect(rig.playhead.value, s);
    });
  });

  group('apply to all cuts', () {
    testTransitions('one history entry; each cut clamped to its own limit; undo restores', (tester) async {
      final rig = await TransitionsRig.pump(tester);
      await tap(tester, tile(TransitionKind.crossDissolve));
      durationRow(tester).onSubmitted!(1.0);
      await tester.pump();
      final before = rig.entries;
      await tap(tester, key('transitions.applyAll'));
      expect(rig.entries, before + 1);
      expect(rig.state.history.undoLabel, 'Apply transition to all cuts');
      expect(rig.at(Cuts.ab)!.durationFrames, 30);
      expect(rig.at(Cuts.bc)!.kind, TransitionKind.crossDissolve);
      expect(rig.at(Cuts.bc)!.durationFrames, 18);
      expect(rig.at(Cuts.cd)!.kind, TransitionKind.crossDissolve);
      expect(rig.at(Cuts.overlayCut), isNull, reason: 'only the lane of the cut');
      rig.editor.undo();
      await tester.pump();
      expect(rig.at(Cuts.bc), isNull);
      expect(rig.at(Cuts.cd), isNull);
      expect(rig.at(Cuts.ab)!.durationFrames, 30);
    });

    testTransitions('with None it removes every transition of the lane in one entry', (tester) async {
      final rig = await TransitionsRig.pump(tester);
      await tap(tester, tile(TransitionKind.fade));
      await tap(tester, key('transitions.applyAll'));
      expect(rig.at(Cuts.cd), isNotNull);
      await tap(tester, tile(null));
      expect(find.text(TransitionStrings.removeAll), findsOneWidget);
      final before = rig.entries;
      await tap(tester, key('transitions.applyAll'));
      expect(rig.entries, before + 1);
      expect(rig.at(Cuts.bc), isNull);
      expect(rig.at(Cuts.cd), isNull);
    });
  });

  group('states', () {
    testTransitions('a locked lane: notice and disabled controls', (tester) async {
      final rig = await TransitionsRig.pump(tester, open: Cuts.lockedCut);
      expect(find.text(TransitionStrings.trackLocked), findsOneWidget);
      for (final kind in TransitionPanelModel.tiles) {
        expect(enabled(tester, kind), isFalse);
      }
      expect(tester.widget<DanaviewButton>(key('transitions.applyAll')).onPressed, isNull);
      await tap(tester, tile(TransitionKind.fade));
      expect(rig.at(Cuts.lockedCut), isNull);
    });

    testTransitions('a ref that is no longer a cut: notice, nothing enabled, no preview', (tester) async {
      final rig = await TransitionsRig.pump(tester, open: Cuts.notACut);
      expect(find.text(TransitionStrings.noCut), findsOneWidget);
      expect(enabled(tester, TransitionKind.fade), isFalse);
      expect(rig.preview.playing, isFalse);
    });
  });

  group('matrix (no overflow, owner UI rules)', () {
    testTransitionSurfaces('slide with direction and the limit copy', (tester, surface) async {
      final rig = await TransitionsRig.pump(tester, surface: surface, open: Cuts.bc);
      await tap(tester, tile(TransitionKind.slide));
      expect(rig.at(Cuts.bc)!.kind, TransitionKind.slide);
      expect(find.text(TransitionStrings.limited), findsOneWidget);
      expectNoOverflow(tester);
      expectOwnerUiRules(tester);
      for (final k in ['transitions.duration', 'transitions.direction', 'transitions.preview', 'transitions.applyAll']) {
        await tester.ensureVisible(key(k));
        await tester.pump();
        final r = tester.getRect(key(k));
        expect(r.left, greaterThanOrEqualTo(0), reason: k);
        expect(r.right, lessThanOrEqualTo(surface.size.width), reason: k);
      }
      expectNoOverflow(tester);
    });

    testTransitionSurfaces('zoom without handles explanation', (tester, surface) async {
      await TransitionsRig.pump(tester, surface: surface, open: Cuts.overlayCut);
      await tap(tester, tile(TransitionKind.fade));
      expect(find.text(TransitionStrings.needsHandles), findsOneWidget);
      expectNoOverflow(tester);
      expectOwnerUiRules(tester);
    });

    testTransitionSurfaces('locked lane', (tester, surface) async {
      await TransitionsRig.pump(tester, surface: surface, open: Cuts.lockedCut);
      expect(find.text(TransitionStrings.trackLocked), findsOneWidget);
      expectNoOverflow(tester);
      expectOwnerUiRules(tester);
    });
  });
}
