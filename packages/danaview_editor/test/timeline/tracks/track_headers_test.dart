// OWNER: UX-11
//
// TrackHeaders widget tests: the toggles of every lane kind and flag, the commands they dispatch
// (CORE-17 `SetTrackFlags`), toggled semantics named after the track, compact and expanded
// headers, opening the menu, selection, read-only, vertical scrolling with virtualization, and the
// no-overflow matrix at the four header widths, three text scales and both inputs.

import 'dart:ui' show Tristate;

import 'package:flutter/material.dart' show Icons;
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_editor/src/app/strings/track_strings.dart';
import 'package:danaview_editor/src/editor/timeline/timeline_metrics.dart';
import 'package:danaview_editor/src/editor/timeline/timeline_snapshot.dart';
import 'package:danaview_editor/src/editor/timeline/timeline_viewport.dart';
import 'package:danaview_editor/src/editor/timeline/track_headers.dart';
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_editor_core/ops.dart' show SetTrackFlags;

import '../../support/support.dart';
import 'track_test_support.dart';

/// Pumps [TrackHeaders] over [project] in a [width] x [height] box.
Future<({RecordingSink sink, TimelineViewportController viewport, List<LaneModel> opened, TimelineSnapshot snapshot})> pumpHeaders(
  WidgetTester tester,
  EditProject project, {
  double width = 168,
  double height = 600,
  bool touch = false,
  double textScale = 1.0,
  TrackId? selected,
  bool enabled = true,
  LaneHeightPreset laneHeight = LaneHeightPreset.normal,
  EditorSurface? surface,
}) async {
  final sink = RecordingSink();
  final opened = <LaneModel>[];
  final snapshot = TimelineSnapshotBuilder().build(project, laneHeight: laneHeight);
  final metrics = TimelineMetrics(textScale: textScale, headerWidth: width, touch: touch, laneHeight: laneHeight);
  final stack = TimelineLaneStack.of(snapshot.laneKinds, metrics, presets: snapshot.laneHeights);
  final viewport = TimelineViewportController(defaultMode: PlayheadFollowMode.free, platform: TargetPlatform.android)
    ..setViewport(Size(800, height), width)
    ..setContent(duration: snapshot.duration, frameRate: snapshot.frameRate, contentHeight: stack.contentHeight);
  addTearDown(viewport.dispose);
  final s = surface ?? EditorSurface(const Size(500, 700), textScale: textScale, platform: touch ? TargetPlatform.android : TargetPlatform.macOS);
  applySurface(tester, s);
  await tester.pumpWidget(surfaceApp(
    s,
    Align(
      alignment: Alignment.topLeft,
      child: SizedBox(
        width: width,
        height: height,
        child: TrackHeaders(
          snapshot: snapshot,
          viewport: viewport,
          metrics: metrics,
          actions: sink.actions(),
          onOpenMenu: opened.add,
          selectedLane: selected,
          enabled: enabled,
        ),
      ),
    ),
  ));
  await tester.pump();
  return (sink: sink, viewport: viewport, opened: opened, snapshot: snapshot);
}

bool? toggledOf(WidgetTester tester, Finder f) => switch (tester.getSemantics(f).getSemanticsData().flagsCollection.isToggled) {
      Tristate.isTrue => true,
      Tristate.isFalse => false,
      Tristate.none => null,
    };

void main() {
  final project = allKindsProject();
  final snap = snapshotOfProject(project);
  LaneModel lane(String id) => snap.lane(TrackId(id))!;
  String name(String id) => lane(id).displayName;

  group('toggles per lane kind (168 px, pointer: three inline)', () {
    // Priority inline at 168: video lanes lock + visibility + mute; audio lanes lock + mute + solo;
    // text and subtitle lanes lock + visibility.
    final expected = <String, List<String Function(String)>>{
      'tr_main': [TrackStrings.lockToggle, TrackStrings.visibleToggle, TrackStrings.muteToggle],
      'tr_video2': [TrackStrings.lockToggle, TrackStrings.visibleToggle, TrackStrings.muteToggle],
      'tr_overlay': [TrackStrings.lockToggle, TrackStrings.visibleToggle],
      'tr_text': [TrackStrings.lockToggle, TrackStrings.visibleToggle],
      'tr_subs': [TrackStrings.lockToggle, TrackStrings.visibleToggle],
      'tr_music': [TrackStrings.lockToggle, TrackStrings.muteToggle, TrackStrings.soloToggle],
      'tr_voice': [TrackStrings.lockToggle, TrackStrings.muteToggle, TrackStrings.soloToggle],
    };
    final all = [TrackStrings.lockToggle, TrackStrings.visibleToggle, TrackStrings.muteToggle, TrackStrings.soloToggle];
    for (final e in expected.entries) {
      testWidgets('${e.key}: shows its toggles and no others', (tester) async {
        await pumpHeaders(tester, project);
        final n = name(e.key);
        for (final label in e.value) {
          expect(find.bySemanticsLabel(label(n)), findsOneWidget, reason: '${label(n)} on ${e.key}');
        }
        for (final label in all.where((l) => !e.value.contains(l))) {
          expect(find.bySemanticsLabel(label(n)), findsNothing, reason: '${label(n)} must not be on ${e.key}');
        }
      });
    }
  });

  group('commands match CORE-17', () {
    void dispatches(String id, String Function(String) label, {bool? locked, bool? hidden, bool? muted, bool? solo, EditProject? p}) {
      testWidgets('${label('X')} on $id', (tester) async {
        final proj = p ?? project;
        final r = await pumpHeaders(tester, proj, width: 220);
        final n = snapshotOfProject(proj).lane(TrackId(id))!.displayName;
        await tester.tap(find.bySemanticsLabel(label(n)));
        await tester.pump();
        expect(r.sink.commands, hasLength(1));
        final c = r.sink.commands.single as SetTrackFlags;
        expect(c.track, TrackId(id));
        expect((c.locked, c.hidden, c.muted, c.solo), (locked, hidden, muted, solo));
      });
    }

    dispatches('tr_main', TrackStrings.lockToggle, locked: true);
    dispatches('tr_video2', TrackStrings.lockToggle, locked: true);
    dispatches('tr_text', TrackStrings.lockToggle, locked: true);
    dispatches('tr_subs', TrackStrings.lockToggle, locked: true);
    dispatches('tr_music', TrackStrings.lockToggle, locked: true);
    dispatches('tr_main', TrackStrings.visibleToggle, hidden: true);
    dispatches('tr_overlay', TrackStrings.visibleToggle, hidden: true);
    dispatches('tr_text', TrackStrings.visibleToggle, hidden: true);
    dispatches('tr_subs', TrackStrings.visibleToggle, hidden: true);
    dispatches('tr_main', TrackStrings.muteToggle, muted: true);
    dispatches('tr_music', TrackStrings.muteToggle, muted: true);
    dispatches('tr_music', TrackStrings.soloToggle, solo: true);
    dispatches('tr_voice', TrackStrings.soloToggle, solo: true);
    dispatches('tr_main', TrackStrings.soloToggle, solo: true);

    testWidgets('flags that are on dispatch the opposite', (tester) async {
      final p = withTrack(withTrack(project, 'tr_music', (t) => t.copyWith(locked: true, muted: true)), 'tr_text', (t) => t.copyWith(hidden: true));
      final r = await pumpHeaders(tester, p, width: 220, touch: true);
      await tester.tap(find.bySemanticsLabel(TrackStrings.lockToggle(snapshotOfProject(p).lane(const TrackId('tr_music'))!.displayName)));
      await tester.tap(find.bySemanticsLabel(TrackStrings.muteToggle(snapshotOfProject(p).lane(const TrackId('tr_music'))!.displayName)));
      await tester.tap(find.bySemanticsLabel(TrackStrings.visibleToggle(snapshotOfProject(p).lane(const TrackId('tr_text'))!.displayName)));
      await tester.pump();
      final c = r.sink.commands.cast<SetTrackFlags>();
      expect((c[0].locked, c[0].muted), (false, null));
      expect((c[1].muted, c[1].locked), (false, null));
      expect((c[2].hidden, c[2].locked), (false, null));
    });

    testWidgets('a toggle changes one flag at a time (never a combined command)', (tester) async {
      final r = await pumpHeaders(tester, project, width: 220, touch: true);
      await tester.tap(find.bySemanticsLabel(TrackStrings.muteToggle(name('tr_music'))));
      await tester.pump();
      final c = r.sink.commands.single as SetTrackFlags;
      expect([c.locked, c.hidden, c.muted, c.solo].where((v) => v != null), hasLength(1));
    });
  });

  group('toggled semantics', () {
    testWidgets('every toggle is a toggled node named after the track', (tester) async {
      await pumpHeaders(tester, project, width: 220, touch: true);
      for (final f in [
        find.bySemanticsLabel(TrackStrings.lockToggle(name('tr_music'))),
        find.bySemanticsLabel(TrackStrings.muteToggle(name('tr_music'))),
        find.bySemanticsLabel(TrackStrings.visibleToggle(name('tr_text'))),
      ]) {
        expect(toggledOf(tester, f), isNotNull, reason: 'has toggled state');
      }
    });

    testWidgets('toggled follows the flag: locked/muted/solo when on; visibility when shown', (tester) async {
      final p = withTrack(project, 'tr_music', (t) => t.copyWith(locked: true, solo: true));
      final ph = withTrack(p, 'tr_text', (t) => t.copyWith(hidden: true));
      await pumpHeaders(tester, ph, width: 220, touch: true);
      final sp = snapshotOfProject(ph);
      final music = sp.lane(const TrackId('tr_music'))!.displayName;
      final text = sp.lane(const TrackId('tr_text'))!.displayName;
      expect(toggledOf(tester, find.bySemanticsLabel(TrackStrings.lockToggle(music))), isTrue);
      expect(toggledOf(tester, find.bySemanticsLabel(TrackStrings.soloToggle(music))), isTrue);
      expect(toggledOf(tester, find.bySemanticsLabel(TrackStrings.muteToggle(music))), isFalse);
      expect(toggledOf(tester, find.bySemanticsLabel(TrackStrings.visibleToggle(text))), isFalse, reason: 'hidden = not shown');
      expect(toggledOf(tester, find.bySemanticsLabel(TrackStrings.lockToggle(text))), isFalse);
    });

    testWidgets('toggles are tooltips of their current state', (tester) async {
      await pumpHeaders(tester, withTrack(project, 'tr_music', (t) => t.copyWith(muted: true)), width: 220, touch: true);
      // The tooltip text is the action the next tap performs.
      expect(find.byTooltip(TrackStrings.muteTooltip(true)), findsOneWidget);
      expect(find.byTooltip(TrackStrings.lockTooltip(false)), findsWidgets);
    });

    testWidgets('a header is one labelled button naming the track, its kind and its flags', (tester) async {
      final p = withTrack(project, 'tr_music', (t) => t.copyWith(locked: true, muted: true));
      await pumpHeaders(tester, p, width: 44);
      final music = snapshotOfProject(p).lane(const TrackId('tr_music'))!.displayName;
      expect(find.bySemanticsLabel('$music, audio track, locked, muted'), findsOneWidget);
      expect(find.bySemanticsLabel('Main, main video track'), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp('^Text 1, text track\$')), findsOneWidget);
    });
  });

  group('compact header (44 px)', () {
    testWidgets('one icon per lane, no inline toggles; the kind icons of ux.md §8.10', (tester) async {
      await pumpHeaders(tester, project, width: 44);
      expect(find.byIcon(Icons.movie_rounded), findsNWidgets(2));
      expect(find.byIcon(Icons.picture_in_picture_alt_rounded), findsOneWidget);
      expect(find.byIcon(Icons.text_fields_rounded), findsOneWidget);
      expect(find.byIcon(Icons.subtitles_rounded), findsOneWidget);
      expect(find.byIcon(Icons.music_note_rounded), findsNWidgets(2));
      expect(find.bySemanticsLabel(RegExp('^(Lock|Mute|Solo|Show) ')), findsNothing);
    });

    testWidgets('status glyphs show lock, eye-off, muted and solo', (tester) async {
      var p = withTrack(project, 'tr_music', (t) => t.copyWith(locked: true, muted: true, solo: true));
      p = withTrack(p, 'tr_text', (t) => t.copyWith(hidden: true));
      await pumpHeaders(tester, p, width: 44);
      expect(find.byIcon(Icons.lock_rounded), findsOneWidget);
      expect(find.byIcon(Icons.volume_off_rounded), findsOneWidget);
      expect(find.byIcon(Icons.visibility_off_rounded), findsOneWidget);
      expect(find.text('S'), findsOneWidget);
    });

    testWidgets('tapping a header selects the lane and opens its menu', (tester) async {
      final r = await pumpHeaders(tester, project, width: 44);
      await tester.tap(find.bySemanticsLabel('${name('tr_music')}, audio track'));
      await tester.pump();
      expect(r.opened.single.id, const TrackId('tr_music'));
      expect(r.sink.focused, [const TrackId('tr_music')]);
      expect(r.sink.commands, isEmpty, reason: 'opening the menu changes nothing');
    });
  });

  group('expanded header', () {
    testWidgets('shows the name and opens the menu from the icon or name', (tester) async {
      final r = await pumpHeaders(tester, project, width: 168);
      expect(find.text('Main'), findsOneWidget);
      expect(find.text(name('tr_music')), findsOneWidget);
      await tester.tap(find.text(name('tr_music')));
      await tester.pump();
      expect(r.opened.map((l) => l.id), [const TrackId('tr_music')]);
      await tester.tap(find.byIcon(Icons.subtitles_rounded));
      await tester.pump();
      expect(r.opened.last.id, const TrackId('tr_subs'));
    });

    testWidgets('flags that do not fit show as glyphs and are still reachable through the menu', (tester) async {
      final p = withTrack(project, 'tr_main', (t) => t.copyWith(locked: true, muted: true, solo: true));
      final r = await pumpHeaders(tester, p, width: 132, touch: true);
      // 132 px with touch: only visibility is inline; lock shows as a glyph.
      expect(find.bySemanticsLabel(RegExp('^Lock ')), findsNothing);
      expect(find.byIcon(Icons.lock_rounded), findsOneWidget);
      await tester.tap(find.text('Main'));
      expect(r.opened.single.id, const TrackId('tr_main'));
    });

    testWidgets('a long name is cut with an ellipsis, not overflowed', (tester) async {
      final long = 'A very long track name that would never fit in a header '.padRight(60, 'x');
      final p = withTrack(project, 'tr_music', (t) => t.copyWith(name: long.substring(0, 60)));
      await pumpHeaders(tester, p, width: 132);
      expectNoOverflow(tester);
    });

    testWidgets('selected lane is a selected node', (tester) async {
      await pumpHeaders(tester, project, width: 168, selected: const TrackId('tr_music'));
      final node = tester.getSemantics(find.bySemanticsLabel('${name('tr_music')}, audio track'));
      expect(node.getSemanticsData().flagsCollection.isSelected, Tristate.isTrue);
      final other = tester.getSemantics(find.bySemanticsLabel('${name('tr_voice')}, audio track'));
      expect(other.getSemanticsData().flagsCollection.isSelected, isNot(Tristate.isTrue));
    });
  });

  group('read-only', () {
    testWidgets('toggles are disabled and dispatch nothing; the menu still opens', (tester) async {
      final r = await pumpHeaders(tester, project, width: 220, touch: true, enabled: false);
      await tester.tap(find.bySemanticsLabel(TrackStrings.lockToggle(name('tr_music'))), warnIfMissed: false);
      await tester.pump();
      expect(r.sink.commands, isEmpty);
      await tester.tap(find.text(name('tr_music')));
      expect(r.opened, hasLength(1));
    });
  });

  group('scrolling', () {
    EditProject manyLanes(int n) => allKindsProject(extra: [
          for (var i = 0; i < n; i++) Track(id: TrackId('tr_extra$i'), kind: TrackKind.audio, audioRole: AudioRole.effects, items: const []),
        ]);

    testWidgets('headers sit where their canvas lanes are and move with the vertical scroll', (tester) async {
      final p = manyLanes(30);
      final r = await pumpHeaders(tester, p, height: 300);
      final metrics = TimelineMetrics(headerWidth: 168, touch: false);
      final stack = TimelineLaneStack.of(r.snapshot.laneKinds, metrics, presets: r.snapshot.laneHeights);
      Finder cell(int i) => find.byKey(ValueKey(r.snapshot.lanes[i].id));
      expect(tester.getTopLeft(cell(1)).dy, closeTo(stack.tops[1], 0.01));
      expect(tester.getSize(cell(1)).height, stack.heights[1]);

      r.viewport.jumpTo(scrollTimeSec: 0, scrollY: 100);
      await tester.pump();
      expect(tester.getTopLeft(cell(3)).dy, closeTo(stack.tops[3] - 100, 0.01));
    });

    testWidgets('only the visible lanes are built', (tester) async {
      final p = manyLanes(40);
      final r = await pumpHeaders(tester, p, height: 300);
      expect(find.byType(TrackHeaderCell).evaluate().length, lessThan(12));
      r.viewport.jumpTo(scrollTimeSec: 0, scrollY: 1200);
      await tester.pump();
      final built = find.byType(TrackHeaderCell).evaluate().map((e) => (e.widget as TrackHeaderCell).lane.id.value).toList();
      expect(built, isNotEmpty);
      expect(built, isNot(contains('tr_main')));
      expect(built.length, lessThan(12));
    });

    testWidgets('lane heights follow the lane height mode', (tester) async {
      final r = await pumpHeaders(tester, project, laneHeight: LaneHeightPreset.large);
      expect(tester.getSize(find.byKey(ValueKey(r.snapshot.lanes.first.id))).height, TimelineMetrics().laneHeightOf(r.snapshot.lanes.first.kind, preset: LaneHeightPreset.large));
      expect(tester.getSize(find.byKey(const ValueKey(TrackId('tr_main')))).height, 76);
    });
  });

  group('no overflow, owner UI rules', () {
    final longNamed = withTrack(
      withTrack(withTrack(project, 'tr_main', (t) => t.copyWith(locked: true, hidden: true, muted: true, solo: true)), 'tr_music', (t) => t.copyWith(name: 'M' * 60, locked: true, muted: true, solo: true)),
      'tr_subs',
      (t) => t.copyWith(name: 'Subtitles ${'long ' * 12}', locked: true, hidden: true),
    );

    for (final width in [44.0, 132.0, 168.0, 220.0]) {
      for (final scale in [0.85, 1.0, 1.35]) {
        for (final touch in [false, true]) {
          testWidgets('width $width, text ${scale}x, ${touch ? 'touch' : 'pointer'}', (tester) async {
            await pumpHeaders(tester, longNamed, width: width, textScale: scale, touch: touch, height: 700);
            expectNoOverflow(tester);
            expectOwnerUiRules(tester);
            expectInside(tester, find.byType(TrackHeaderCell), screen: const Size(500, 700));
            // Every header stays inside its column.
            for (final e in find.byType(TrackHeaderCell).evaluate()) {
              final box = e.renderObject! as RenderBox;
              expect(box.size.width, width);
            }
          });
        }
      }
    }

    testWidgets('the surface matrix: 280x500 at text 1.35 with the compact column and the narrow pointer column', (tester) async {
      await pumpHeaders(tester, longNamed, width: 44, textScale: 1.35, touch: true, surface: SurfaceMatrix.narrowest);
      expectNoOverflow(tester);
      expectOwnerUiRules(tester);
    });
  });
}
