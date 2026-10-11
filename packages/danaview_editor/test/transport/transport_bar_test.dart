// OWNER: UX-14
//
// The transport bar (ux.md §7.6) on the editor harness: play/pause, the time readout, time entry
// (Timecode.parse), frame step and press-and-hold repeat, edit-point jumps, the rebuild budget
// (120 clock samples rebuild only the readout), the priority row with its "more" menu, and the
// no-overflow matrix with the owner UI rules.

import 'package:flutter/material.dart' show Icons;
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_editor/src/debug/rebuild_counters.dart';
import 'package:danaview_editor/src/editor/layout/editor_layout.dart';
import 'package:danaview_editor/src/editor/layout/editor_layout_scope.dart';
import 'package:danaview_editor/src/editor/transport/timecode_text.dart';
import 'package:danaview_editor/src/editor/transport/transport_bar.dart';
import 'package:danaview_editor/src/editor/transport/transport_strings.dart';
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_ui_kit/danaview_ui_kit.dart';

import '../support/support.dart';
import 'transport_rig.dart';

/// A surface wide enough for the full readout and every optional control, even in the Ahem test
/// font (every glyph is as wide as its font size).
const EditorSurface wide = EditorSurface(Size(900, 400));

/// The bar in a row as tall as the layout gives it.
Widget bar(ProjectId id) => const Align(alignment: Alignment.topLeft, child: SizedBox(height: 44, child: TransportBar()));

Finder icon(IconData data) => find.byIcon(data);

Finder button(IconData data) => find.ancestor(of: icon(data), matching: find.byType(DanaviewIconButton));

String timecodeText(WidgetTester tester) {
  final t = tester.widget<Text>(find.descendant(of: find.byType(TimecodeText), matching: find.byType(Text)));
  return t.textSpan!.toPlainText();
}

void main() {
  tearDown(() {
    EditorRebuildCounters.enabled = false;
    EditorRebuildCounters.reset();
  });

  group('play and time readout', () {
    testWidgets('shows play and the time over the duration; disabled until the editor is open', (tester) async {
      final rig = await TransportRig.pump(tester, bar, open: false, surface: wide);
      expect(icon(Icons.play_arrow_rounded), findsOneWidget);
      expect(tester.widget<DanaviewIconButton>(button(Icons.play_arrow_rounded)).onPressed, isNull);
      await rig.openEditor();
      expect(tester.widget<DanaviewIconButton>(button(Icons.play_arrow_rounded)).onPressed, isNotNull);
      expect(timecodeText(tester), '00:00:00 / 00:07:00');
      expectNoOverflow(tester);
    });

    testWidgets('an empty project cannot play', (tester) async {
      await TransportRig.pump(tester, bar, project: false, surface: wide);
      expect(tester.widget<DanaviewIconButton>(button(Icons.play_arrow_rounded)).onPressed, isNull);
      expect(timecodeText(tester), '00:00:00 / 00:00:00');
    });

    testWidgets('play and pause go to the preview and the icon follows', (tester) async {
      final rig = await TransportRig.pump(tester, bar, surface: wide);
      await tester.tap(icon(Icons.play_arrow_rounded));
      await rig.real(() async {});
      expect(rig.engine.calls, contains('preview.play'));
      expect(icon(Icons.pause_rounded), findsOneWidget);
      expect(rig.transport.playing.value, isTrue);
      await tester.tap(icon(Icons.pause_rounded));
      await rig.real(() async {});
      expect(rig.engine.calls.last, 'preview.pause');
      expect(icon(Icons.play_arrow_rounded), findsOneWidget);
    });

    testWidgets('the readout follows the playhead and the tooltip carries the shortcut', (tester) async {
      final rig = await TransportRig.pump(tester, bar, surface: wide);
      await rig.real(() => rig.transport.seekTo(rig.preview.config.fps * 0 + 2 * s + 15 * 33333));
      expect(timecodeText(tester), startsWith('00:02:'));
      final play = tester.widget<DanaviewIconButton>(button(Icons.play_arrow_rounded));
      expect(play.tooltip, 'Play (Space)');
      expect(play.semanticLabel, 'Play');
    });

    testWidgets('the readout exposes position and duration to screen readers', (tester) async {
      final rig = await TransportRig.pump(tester, bar, surface: wide);
      await rig.real(() => rig.transport.seekTo(1 * s));
      final handle = tester.ensureSemantics();
      await tester.pump();
      expect(tester.getSemantics(find.byType(TimecodeText)).value, '00:01:00 of 00:07:00');
      handle.dispose();
    });
  });

  group('rebuild budget', () {
    testWidgets('120 clock samples rebuild only the readout', (tester) async {
      final rig = await TransportRig.pump(tester, bar, surface: wide);
      await tester.tap(icon(Icons.play_arrow_rounded));
      await rig.real(() async {});
      final counts = await EditorRebuildCounters.record(() async {
        for (var i = 0; i < 120; i++) {
          rig.time.advance(const Duration(microseconds: 33333));
          rig.preview.advanceFrames(1);
          await tester.runAsync(() => Future<void>.delayed(Duration.zero));
          rig.frames.tick();
          await tester.pump();
        }
      });
      expect(counts['TransportBar'], isNull, reason: 'the bar itself never rebuilds per frame: $counts');
      expect(counts['TimecodeText'], greaterThanOrEqualTo(100), reason: 'the readout follows the frames: $counts');
      expect(counts.keys.toSet(), {'TimecodeText'});
    });
  });

  group('time entry', () {
    Future<void> enter(WidgetTester tester, TransportRig rig, String text) async {
      await tester.tap(find.byType(TimecodeText));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.enterText(find.byType(EditableText), text);
      await tester.tap(find.text(TransportStrings.entryConfirm));
      await tester.pump(const Duration(milliseconds: 300));
      await rig.real(() async {});
    }

    testWidgets('opens a prompt and seeks to a parsed time', (tester) async {
      final rig = await TransportRig.pump(tester, bar, surface: wide);
      await enter(tester, rig, '0:03');
      expect(rig.playhead.value, 3 * s);
      expect(rig.preview.time, 3 * s);
      expect(timecodeText(tester), startsWith('00:03:00'));
    });

    testWidgets('relative times move from the playhead', (tester) async {
      final rig = await TransportRig.pump(tester, bar, surface: wide);
      await enter(tester, rig, '0:01');
      expect(rig.playhead.value, 1 * s);
      await enter(tester, rig, '+2s');
      expect(rig.playhead.value, 3 * s);
      await enter(tester, rig, '-30f');
      expect(rig.playhead.value, 2 * s);
    });

    testWidgets('a time past the end goes to the end', (tester) async {
      final rig = await TransportRig.pump(tester, bar, surface: wide);
      await enter(tester, rig, '1:30');
      expect(rig.playhead.value, 7 * s);
    });

    testWidgets('invalid input shows the validator message and does not seek', (tester) async {
      final rig = await TransportRig.pump(tester, bar, surface: wide);
      await tester.tap(find.byType(TimecodeText));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.enterText(find.byType(EditableText), 'abc');
      await tester.tap(find.text(TransportStrings.entryConfirm));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text(TransportStrings.entryInvalid), findsOneWidget);
      expect(rig.playhead.value, 0);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(find.text(TransportStrings.entryInvalid), findsNothing);
    });
  });

  group('frame step and jumps', () {
    testWidgets('tapping next frame steps one frame', (tester) async {
      final rig = await TransportRig.pump(tester, bar, surface: wide);
      await tester.tap(icon(Icons.keyboard_arrow_right_rounded));
      await rig.real(() async {});
      expect(rig.playhead.value, rig.playhead.frameRate.timeOfFrame(1));
      expect(rig.engine.calls.where((c) => c == 'preview.seek').length, greaterThanOrEqualTo(2), reason: 'open + step');
    });

    testWidgets('a tap steps exactly once, not twice', (tester) async {
      final rig = await TransportRig.pump(tester, bar, surface: wide);
      await tester.tap(icon(Icons.keyboard_arrow_right_rounded));
      await tester.pump(const Duration(milliseconds: 600));
      await rig.real(() async {});
      expect(rig.playhead.value, rig.playhead.frameRate.timeOfFrame(1));
    });

    testWidgets('holding repeats after 400 ms at 8 Hz and releasing stops', (tester) async {
      final rig = await TransportRig.pump(tester, bar, surface: wide);
      final gesture = await tester.startGesture(tester.getCenter(icon(Icons.keyboard_arrow_right_rounded)));
      await rig.real(() async {});
      final first = rig.playhead.value;
      expect(first, rig.playhead.frameRate.timeOfFrame(1));
      await tester.pump(const Duration(milliseconds: 350));
      await rig.real(() async {});
      expect(rig.playhead.value, first, reason: 'nothing before the 400 ms delay');
      await tester.pump(const Duration(milliseconds: 50 + 125 * 4));
      await rig.real(() async {});
      expect(rig.playhead.value, rig.playhead.frameRate.timeOfFrame(1 + 4));
      await gesture.up();
      await rig.real(() async {});
      final at = rig.playhead.value;
      await tester.pump(const Duration(seconds: 1));
      await rig.real(() async {});
      expect(rig.playhead.value, at);
    });

    testWidgets('previous and next edit point include the marker', (tester) async {
      final rig = await TransportRig.pump(tester, bar, surface: wide);
      final visited = <TimeUs>[];
      for (var i = 0; i < 3; i++) {
        await tester.tap(icon(Icons.last_page_rounded));
        await rig.real(() async {});
        visited.add(rig.playhead.value);
      }
      expect(visited, [3 * s, 4 * s, 5 * s]);
      await tester.tap(icon(Icons.first_page_rounded));
      await rig.real(() async {});
      expect(rig.playhead.value, 4 * s);
    });
  });

  group('priority row', () {
    testWidgets('a wide bar shows everything that exists and no more menu', (tester) async {
      await TransportRig.pump(tester, bar, surface: const EditorSurface(Size(1280, 800), platform: TargetPlatform.macOS));
      for (final i in [Icons.keyboard_arrow_left_rounded, Icons.keyboard_arrow_right_rounded, Icons.first_page_rounded, Icons.last_page_rounded, Icons.zoom_out_rounded, Icons.zoom_in_rounded, Icons.hd_rounded]) {
        expect(icon(i), findsOneWidget, reason: '$i');
      }
      expect(icon(Icons.more_horiz_rounded), findsNothing);
      expectNoOverflow(tester);
    });

    testWidgets('actions that no feature binds yet (marker, snapping, ripple) are not shown', (tester) async {
      await TransportRig.pump(tester, bar, surface: const EditorSurface(Size(1280, 800), platform: TargetPlatform.macOS));
      expect(icon(Icons.bookmark_add_rounded), findsNothing);
      expect(icon(Icons.vertical_align_center_rounded), findsNothing);
      expect(icon(Icons.swap_horiz_rounded), findsNothing);
    });

    testWidgets('a narrow bar moves the lowest priorities into the more menu and loses nothing', (tester) async {
      final rig = await TransportRig.pump(tester, bar, surface: const EditorSurface(Size(320, 568)));
      expect(icon(Icons.more_horiz_rounded), findsOneWidget);
      expect(icon(Icons.hd_rounded), findsNothing, reason: 'quality has the lowest priority');
      // Priority order: whatever is not on the bar is in the menu.
      final onBar = {
        TransportItem.frames: icon(Icons.keyboard_arrow_right_rounded).evaluate().isNotEmpty,
        TransportItem.edits: icon(Icons.last_page_rounded).evaluate().isNotEmpty,
        TransportItem.zoom: icon(Icons.zoom_in_rounded).evaluate().isNotEmpty,
      };
      if (onBar[TransportItem.zoom]!) expect(onBar[TransportItem.edits], isTrue, reason: 'a lower priority never shows without a higher one');
      if (onBar[TransportItem.edits]!) expect(onBar[TransportItem.frames], isTrue);
      await tester.tap(icon(Icons.more_horiz_rounded));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text(TransportStrings.qualityHalf), findsOneWidget);
      expect(find.text(TransportStrings.useProxies), findsOneWidget);
      expect(find.text(TransportStrings.nextFrame), onBar[TransportItem.frames]! ? findsNothing : findsOneWidget);
      expect(find.text(TransportStrings.nextEdit), onBar[TransportItem.edits]! ? findsNothing : findsOneWidget);
      await tester.ensureVisible(find.text(TransportStrings.qualityHalf));
      await tester.pump();
      await tester.tap(find.text(TransportStrings.qualityHalf));
      await tester.pump(const Duration(milliseconds: 300));
      await rig.real(() async {});
      expect(rig.engine.calls, contains('preview.setQuality'));
      expect(rig.editor.state.preview.quality.name, 'half');
      expectNoOverflow(tester);
    });

    testWidgets('a hidden frame step still steps from the more menu', (tester) async {
      final rig = await TransportRig.pump(tester, bar, surface: const EditorSurface(Size(280, 500), textScale: 1.35));
      expect(icon(Icons.keyboard_arrow_right_rounded), findsNothing);
      await tester.tap(icon(Icons.more_horiz_rounded));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.text(TransportStrings.nextFrame));
      await tester.pump(const Duration(milliseconds: 300));
      await rig.real(() async {});
      expect(rig.playhead.value, rig.playhead.frameRate.timeOfFrame(1));
    });

    testWidgets('the quality menu sets proxies', (tester) async {
      final rig = await TransportRig.pump(tester, bar, surface: const EditorSurface(Size(1280, 800), platform: TargetPlatform.macOS));
      await tester.tap(icon(Icons.hd_rounded));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text(TransportStrings.qualityNote), findsOneWidget);
      final before = rig.editor.state.preview.useProxies;
      await tester.tap(find.text(TransportStrings.useProxies));
      await tester.pump(const Duration(milliseconds: 300));
      await rig.real(() async {});
      expect(rig.editor.state.preview.useProxies, !before);
    });

    testWidgets('merged into the top bar it shows play and the compact time only', (tester) async {
      final spec = EditorLayoutSpec.resolve(
        size: const Size(280, 500),
        padding: EdgeInsets.zero,
        viewInsets: const EdgeInsets.only(bottom: 200),
        textScaler: const TextScaler.linear(1.35),
        touch: true,
      );
      expect(spec.transportInTopBar, isTrue);
      final rig = await TransportRig.pump(
        tester,
        (id) => EditorLayoutScope(spec: spec, child: const Align(alignment: Alignment.topLeft, child: SizedBox(width: 200, height: 44, child: TransportBar()))),
        surface: SurfaceMatrix.narrowest,
      );
      await rig.real(() => rig.transport.seekTo(1 * s));
      expect(icon(Icons.play_arrow_rounded), findsOneWidget);
      expect(icon(Icons.keyboard_arrow_right_rounded), findsNothing);
      expect(icon(Icons.more_horiz_rounded), findsNothing);
      expect(timecodeText(tester), '0:01 / 0:07');
      expectNoOverflow(tester);
    });
  });

  group('no-overflow matrix', () {
    testSurfaces('the bar fits and follows the owner UI rules', (tester, surface) async {
      await TransportRig.pump(tester, bar, surface: surface);
      expectNoOverflow(tester);
      expectInside(tester, find.byType(TransportBar), screen: surface.size);
      expectOwnerUiRules(tester);
    });

    for (final width in [280.0, 300.0, 320.0, 360.0, 412.0, 568.0, 744.0, 1280.0]) {
      for (final scale in [1.0, 1.35]) {
        testWidgets('width $width at text scale $scale', (tester) async {
          final rig = await TransportRig.pump(tester, bar, surface: EditorSurface(Size(width, 400), textScale: scale));
          await rig.real(() => rig.transport.seekTo(6 * s));
          expectNoOverflow(tester);
          // Every control stays inside the bar's width.
          for (final e in find.byType(DanaviewIconButton).evaluate()) {
            final box = e.renderObject! as RenderBox;
            final right = box.localToGlobal(Offset(box.size.width, 0)).dx;
            expect(right, lessThanOrEqualTo(width + 0.5), reason: 'button beyond the bar at $width');
          }
          expectOwnerUiRules(tester);
        });
      }
    }
  });
}
