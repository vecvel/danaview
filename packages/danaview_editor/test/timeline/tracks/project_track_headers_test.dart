// OWNER: UX-11
//
// ProjectTrackHeaders over a real controller: toggles edit the project through CORE-17 commands
// (one history entry each, undo restores), the header column follows the snapshot, tapping a header
// selects the lane and opens its menu, and the lane height mode resizes the headers.

import 'package:flutter/material.dart' show Material;
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_editor/src/app/strings/track_strings.dart';
import 'package:danaview_editor/src/editor/timeline/timeline_metrics.dart';
import 'package:danaview_editor/src/editor/timeline/track_headers.dart';
import 'package:danaview_editor/src/editor/timeline/track_menu_sheet.dart';
import 'package:danaview_editor_core/model.dart';

import '../../support/support.dart';
import 'track_test_support.dart';

Future<TrackRig> pumpProjectHeaders(WidgetTester tester, {double width = 168, double height = 640, EditorSurface surface = const EditorSurface(Size(500, 700), platform: TargetPlatform.macOS)}) {
  return pumpTrackRig(
    tester,
    (id) => Material(
      child: Align(alignment: Alignment.topLeft, child: SizedBox(width: width, height: height, child: ProjectTrackHeaders(projectId: id))),
    ),
    surface: surface,
  );
}

void main() {
  testWidgets('every lane of the project has a header, in display order', (tester) async {
    await pumpProjectHeaders(tester);
    final lanes = find.byType(TrackHeaderCell).evaluate().map((e) => (e.widget as TrackHeaderCell).lane.id.value).toList();
    // Display order (D-09): subtitles, text, overlay, extra video, main, then the audio lanes.
    expect(lanes, ['tr_subs', 'tr_text', 'tr_overlay', 'tr_video2', 'tr_main', 'tr_music', 'tr_voice']);
  });

  testWidgets('a toggle edits the project: one history entry, undo restores, the toggle follows', (tester) async {
    final rig = await pumpProjectHeaders(tester);
    final music = find.bySemanticsLabel(RegExp('^Mute Music'));
    await tester.tap(music);
    await rig.settle();
    expect(rig.track('tr_music').muted, isTrue);
    expect(rig.state.history.position, 1);
    expect(find.byTooltip(TrackStrings.muteTooltip(true)), findsOneWidget, reason: 'the header shows the new state');
    rig.rig.controller.undo();
    await rig.settle();
    expect(rig.track('tr_music').muted, isFalse);
    expect(find.byTooltip(TrackStrings.muteTooltip(false)), findsWidgets);
  });

  testWidgets('locking from the header: the lock toggle and the lane flag agree', (tester) async {
    final rig = await pumpProjectHeaders(tester);
    await tester.tap(find.bySemanticsLabel(RegExp('^Lock Text')));
    await rig.settle();
    expect(rig.track('tr_text').locked, isTrue);
    await tester.tap(find.bySemanticsLabel(RegExp('^Lock Text')));
    await rig.settle();
    expect(rig.track('tr_text').locked, isFalse);
  });

  testWidgets('tapping a header selects the lane and opens its track menu', (tester) async {
    final rig = await pumpProjectHeaders(tester);
    await tester.tap(find.text('Main'));
    await tester.pumpAndSettle();
    expect(rig.state.selection.lane, const TrackId('tr_main'));
    expect(find.byType(TrackMenuSheet), findsOneWidget);
    expect(find.byKey(const ValueKey('track-name')), findsOneWidget);
  });

  testWidgets('hiding a lane from its menu updates the header behind the sheet', (tester) async {
    final rig = await pumpProjectHeaders(tester);
    await tester.tap(find.text('Main'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('track-visible')));
    await tester.pumpAndSettle();
    expect(rig.track('tr_main').hidden, isTrue);
  });

  testWidgets('the lane height mode resizes the headers with the canvas lanes', (tester) async {
    final rig = await pumpProjectHeaders(tester);
    final main = find.byKey(const ValueKey(TrackId('tr_main')));
    expect(tester.getSize(main).height, 60);
    rig.rig.controller.setModes((m) => m.copyWith(laneHeight: LaneHeightPreset.large));
    await rig.settle();
    expect(tester.getSize(main).height, 76);
    rig.rig.controller.setModes((m) => m.copyWith(laneHeight: LaneHeightPreset.compact));
    await rig.settle();
    expect(tester.getSize(main).height, 52);
  });

  testWidgets('compact width (44) shows icons only and still opens the menu', (tester) async {
    await pumpProjectHeaders(tester, width: 44);
    expect(find.text('Main'), findsNothing);
    await tester.tap(find.bySemanticsLabel('Main, main video track'));
    await tester.pumpAndSettle();
    expect(find.byType(TrackMenuSheet), findsOneWidget);
  });

  testWidgets('adding a track from the menu adds a header', (tester) async {
    final rig = await pumpProjectHeaders(tester);
    final before = find.byType(TrackHeaderCell).evaluate().length;
    await tester.tap(find.text('Main'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const ValueKey('track-add')));
    await tester.tap(find.descendant(of: find.byKey(const ValueKey('track-add')), matching: find.text('Audio')));
    await tester.pumpAndSettle();
    expect(rig.project.tracks.where((t) => t.kind == TrackKind.audio), hasLength(3));
    expect(find.byType(TrackHeaderCell).evaluate().length, before + 1);
  });

  testWidgets('no overflow at 280x500 with text 1.35 in the compact column', (tester) async {
    await pumpProjectHeaders(tester, width: 44, height: 460, surface: SurfaceMatrix.narrowest);
    expectNoOverflow(tester);
    expectOwnerUiRules(tester);
  });
}
