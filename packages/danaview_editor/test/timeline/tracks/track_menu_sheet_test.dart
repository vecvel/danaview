// OWNER: UX-11
//
// The track menu sheet over a real EditorController: rows per lane kind, every row dispatching its
// CORE-17 command (checked on the resulting project), rename, delete with confirmation, the main
// lane's protections, locked lanes, subtitle slots through the action registry, the add-track
// choices, and the no-overflow matrix.

import 'package:flutter/material.dart' show Material;
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_editor/src/app/strings/track_strings.dart';
import 'package:danaview_editor/src/editor/contracts/contracts.dart';
import 'package:danaview_editor/src/editor/timeline/timeline_metrics.dart';
import 'package:danaview_editor/src/editor/timeline/track_menu_sheet.dart';
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_ui_kit/danaview_ui_kit.dart';

import '../../actions/action_test_support.dart' show ActionLog, recordingBindings;
import '../../support/support.dart';
import 'track_test_support.dart';

/// Pumps a button that opens the menu of [track].
Future<TrackRig> openMenu(
  WidgetTester tester,
  String track, {
  EditProject? project,
  EditorSurface surface = SurfaceMatrix.phone,
  Map<EditorActionId, EditorActionBinding>? bindings,
}) async {
  final rig = await pumpTrackRig(
    tester,
    (id) => Material(
      child: Builder(
        builder: (context) => Center(
          child: DanaviewButton(label: 'Open', onPressed: () => TrackMenuSheet.show(context, projectId: id, track: TrackId(track))),
        ),
      ),
    ),
    project: project,
    surface: surface,
    bindings: bindings,
  );
  await tester.tap(find.text('Open'));
  await tester.pumpAndSettle();
  return rig;
}

Finder row(String key) => find.byKey(ValueKey(key));

Future<void> tapRow(WidgetTester tester, String key) async {
  await tester.ensureVisible(row(key));
  await tester.tap(row(key));
  await tester.pumpAndSettle();
}

void main() {
  group('rows per lane kind', () {
    testWidgets('main video: name, visible, locked, muted, solo, height, move (disabled), select all, add, delete (disabled)', (tester) async {
      await openMenu(tester, 'tr_main');
      for (final k in ['track-name', 'track-visible', 'track-locked', 'track-muted', 'track-solo', 'track-move-up', 'track-move-down', 'track-select-all', 'track-delete']) {
        expect(row(k), findsOneWidget, reason: k);
      }
      expect(row('track-heights'), findsOneWidget);
      expect(row('track-add'), findsOneWidget);
      expect(row('track-roles'), findsNothing);
      expect(find.text(TrackStrings.mainCantMove), findsNWidgets(2));
      expect(find.text(TrackStrings.mainCantDelete), findsOneWidget);
      expect(find.text('Main'), findsWidgets);
    });

    testWidgets('overlay with an image: no mute or solo', (tester) async {
      await openMenu(tester, 'tr_overlay');
      expect(row('track-visible'), findsOneWidget);
      expect(row('track-muted'), findsNothing);
      expect(row('track-solo'), findsNothing);
    });

    testWidgets('text: visible and locked only', (tester) async {
      await openMenu(tester, 'tr_text');
      expect(row('track-visible'), findsOneWidget);
      expect(row('track-locked'), findsOneWidget);
      expect(row('track-muted'), findsNothing);
      expect(row('track-solo'), findsNothing);
      expect(row('track-roles'), findsNothing);
    });

    testWidgets('audio: role choice, mute, solo, no visibility', (tester) async {
      await openMenu(tester, 'tr_music');
      expect(row('track-roles'), findsOneWidget);
      expect(row('track-muted'), findsOneWidget);
      expect(row('track-solo'), findsOneWidget);
      expect(row('track-visible'), findsNothing);
      for (final role in AudioRole.values) {
        expect(find.text(TrackStrings.roleName(role)), findsOneWidget);
      }
    });

    testWidgets('subtitles: the subtitle section (Regenerate only for generated captions)', (tester) async {
      await openMenu(tester, 'tr_subs');
      expect(find.widgetWithText(DanaviewSectionHeader, TrackStrings.subtitlesSection), findsOneWidget);
      for (final id in ['captions', 'importSubtitles', 'exportSubtitles']) {
        await tester.ensureVisible(row('track-slot-$id'));
        expect(row('track-slot-$id'), findsOneWidget, reason: id);
      }
      expect(row('track-slot-regenerateCaptions'), findsNothing);
      expect(row('track-burn-in'), findsOneWidget);
    });

    testWidgets('generated subtitles offer Regenerate', (tester) async {
      await openMenu(tester, 'tr_subs', project: allKindsProject(generatedSubtitles: true));
      await tester.ensureVisible(row('track-slot-regenerateCaptions'));
      expect(row('track-slot-regenerateCaptions'), findsOneWidget);
    });
  });

  group('rows dispatch CORE-17 commands', () {
    testWidgets('Visible, Locked, Muted and Solo switches flip the lane flags in the project', (tester) async {
      final rig = await openMenu(tester, 'tr_main');
      await tapRow(tester, 'track-visible');
      expect(rig.track('tr_main').hidden, isTrue);
      await tapRow(tester, 'track-muted');
      expect(rig.track('tr_main').muted, isTrue);
      await tapRow(tester, 'track-solo');
      expect(rig.track('tr_main').solo, isTrue);
      await tapRow(tester, 'track-locked');
      expect(rig.track('tr_main').locked, isTrue);
      // The menu stays open and shows the new state; switch back.
      await tapRow(tester, 'track-locked');
      expect(rig.track('tr_main').locked, isFalse);
      await tapRow(tester, 'track-visible');
      expect(rig.track('tr_main').hidden, isFalse);
      expect(rig.state.history.position, 6, reason: 'each switch is one history entry');
    });

    testWidgets('audio role chips set the role', (tester) async {
      final rig = await openMenu(tester, 'tr_music');
      await tester.tap(find.text(TrackStrings.roleName(AudioRole.voice)));
      await tester.pumpAndSettle();
      expect(rig.track('tr_music').audioRole, AudioRole.voice);
      await tester.tap(find.text(TrackStrings.roleName(AudioRole.effects)));
      await tester.pumpAndSettle();
      expect(rig.track('tr_music').audioRole, AudioRole.effects);
    });

    testWidgets('height chips set the timeline lane height (not a history entry)', (tester) async {
      final rig = await openMenu(tester, 'tr_music');
      final before = rig.state.history.position;
      await tester.tap(find.text(TrackStrings.heightLarge));
      await tester.pumpAndSettle();
      expect(rig.state.modes.laneHeight, LaneHeightPreset.large);
      await tester.tap(find.text(TrackStrings.heightCompact));
      await tester.pumpAndSettle();
      expect(rig.state.modes.laneHeight, LaneHeightPreset.compact);
      expect(rig.state.history.position, before);
    });

    testWidgets('Move up and Move down reorder inside the kind group', (tester) async {
      final rig = await openMenu(tester, 'tr_voice');
      expect(rig.order, ['tr_main', 'tr_video2', 'tr_overlay', 'tr_text', 'tr_subs', 'tr_music', 'tr_voice']);
      await tapRow(tester, 'track-move-up');
      expect(rig.order, ['tr_main', 'tr_video2', 'tr_overlay', 'tr_text', 'tr_subs', 'tr_voice', 'tr_music']);
      // Now first of its kind: Move up is disabled with its reason, Move down puts it back.
      expect(find.text(TrackStrings.moveUpTop), findsOneWidget);
      await tapRow(tester, 'track-move-down');
      expect(rig.order.last, 'tr_voice');
    });

    testWidgets('Move up on a lane with nowhere to go is disabled', (tester) async {
      final rig = await openMenu(tester, 'tr_overlay');
      await tester.ensureVisible(row('track-move-up'));
      await tester.tap(row('track-move-up'), warnIfMissed: false);
      await tester.pump();
      expect(rig.state.history.position, 0);
    });

    testWidgets('Select all on track selects the clips and closes the menu', (tester) async {
      final rig = await openMenu(tester, 'tr_main');
      await tapRow(tester, 'track-select-all');
      expect(rig.state.selection.items, {const ItemId('it_v1'), const ItemId('it_v2')});
      expect(find.widgetWithText(DanaviewSectionHeader, TrackStrings.heightSection), findsNothing, reason: 'the sheet closed');
    });

    testWidgets('Select all is disabled on an empty track', (tester) async {
      final rig = await openMenu(tester, 'tr_voice');
      expect(find.text(TrackStrings.selectAllEmpty), findsOneWidget);
      await tester.ensureVisible(row('track-select-all'));
      await tester.tap(row('track-select-all'), warnIfMissed: false);
      await tester.pump();
      expect(rig.state.selection.items, isEmpty);
    });

    testWidgets('Add track chips add a lane of that kind and close the menu', (tester) async {
      final rig = await openMenu(tester, 'tr_music');
      final before = rig.project.tracks.length;
      await tester.ensureVisible(row('track-add'));
      await tester.tap(find.descendant(of: row('track-add'), matching: find.text(TrackStrings.kindName(TrackKind.overlay))));
      await tester.pumpAndSettle();
      expect(rig.project.tracks.length, before + 1);
      expect(rig.project.tracks.where((t) => t.kind == TrackKind.overlay), hasLength(2));
      expect(find.widgetWithText(DanaviewSectionHeader, TrackStrings.addSection), findsNothing, reason: 'the sheet closed');
    });

    testWidgets('burn-in switch sets SetBurnIn on the subtitle lane', (tester) async {
      final rig = await openMenu(tester, 'tr_subs');
      await tapRow(tester, 'track-burn-in');
      expect(rig.track('tr_subs').subtitle!.burnIn, isFalse);
      await tapRow(tester, 'track-burn-in');
      expect(rig.track('tr_subs').subtitle!.burnIn, isTrue);
    });
  });

  group('rename', () {
    testWidgets('the name row asks for a name and renames the track', (tester) async {
      final rig = await openMenu(tester, 'tr_music');
      await tapRow(tester, 'track-name');
      expect(find.text(TrackStrings.renameTitle), findsOneWidget);
      await tester.enterText(find.byType(EditableText).last, '  Soundtrack  ');
      await tester.tap(find.text(TrackStrings.renameConfirm));
      await tester.pumpAndSettle();
      expect(rig.track('tr_music').name, 'Soundtrack');
      expect(find.text('Soundtrack'), findsWidgets);
    });

    testWidgets('an empty name restores the default', (tester) async {
      final p = withTrack(allKindsProject(), 'tr_music', (t) => t.copyWith(name: 'Old'));
      final rig = await openMenu(tester, 'tr_music', project: p);
      await tapRow(tester, 'track-name');
      await tester.enterText(find.byType(EditableText).last, '');
      await tester.tap(find.text(TrackStrings.renameConfirm));
      await tester.pumpAndSettle();
      expect(rig.track('tr_music').name, '');
    });

    testWidgets('a name over 60 characters is refused with a message', (tester) async {
      final rig = await openMenu(tester, 'tr_music');
      await tapRow(tester, 'track-name');
      await tester.enterText(find.byType(EditableText).last, 'x' * 61);
      await tester.tap(find.text(TrackStrings.renameConfirm));
      await tester.pumpAndSettle();
      expect(find.text(TrackStrings.nameTooLong), findsOneWidget);
      expect(rig.track('tr_music').name, '');
    });

    testWidgets('cancel keeps the name', (tester) async {
      final rig = await openMenu(tester, 'tr_music');
      await tapRow(tester, 'track-name');
      await tester.tap(find.text(TrackStrings.cancel));
      await tester.pumpAndSettle();
      expect(rig.track('tr_music').name, '');
      expect(rig.state.history.position, 0);
    });
  });

  group('delete', () {
    testWidgets('a track with clips asks first; confirming deletes it and closes the menu', (tester) async {
      final rig = await openMenu(tester, 'tr_music');
      await tapRow(tester, 'track-delete');
      expect(find.text(TrackStrings.deleteConfirm), findsOneWidget);
      expect(find.text(TrackStrings.deleteMessage(1)), findsOneWidget);
      expect(rig.project.tracks.any((t) => t.id == const TrackId('tr_music')), isTrue, reason: 'not yet');
      await tester.tap(find.text(TrackStrings.deleteConfirm));
      await tester.pumpAndSettle();
      expect(rig.project.tracks.any((t) => t.id == const TrackId('tr_music')), isFalse);
      expect(find.widgetWithText(DanaviewSectionHeader, TrackStrings.heightSection), findsNothing);
    });

    testWidgets('cancelling the confirmation keeps the track', (tester) async {
      final rig = await openMenu(tester, 'tr_music');
      await tapRow(tester, 'track-delete');
      await tester.tap(find.text(TrackStrings.cancel));
      await tester.pumpAndSettle();
      expect(rig.project.tracks.any((t) => t.id == const TrackId('tr_music')), isTrue);
      expect(find.widgetWithText(DanaviewSectionHeader, TrackStrings.heightSection), findsOneWidget, reason: 'the menu stays open');
    });

    testWidgets('an empty track is deleted without asking', (tester) async {
      final rig = await openMenu(tester, 'tr_voice');
      await tapRow(tester, 'track-delete');
      expect(find.text(TrackStrings.deleteConfirm), findsNothing);
      expect(rig.project.tracks.any((t) => t.id == const TrackId('tr_voice')), isFalse);
    });

    testWidgets('the main track can not be deleted', (tester) async {
      final rig = await openMenu(tester, 'tr_main');
      await tester.ensureVisible(row('track-delete'));
      await tester.tap(row('track-delete'), warnIfMissed: false);
      await tester.pump();
      expect(find.text(TrackStrings.deleteConfirm), findsNothing);
      expect(rig.project.tracks.any((t) => t.id == const TrackId('tr_main')), isTrue);
    });
  });

  group('locked tracks', () {
    testWidgets('rename, role, move and delete wait for the unlock; the lock switch still works', (tester) async {
      final p = withTrack(allKindsProject(), 'tr_music', (t) => t.copyWith(locked: true));
      final rig = await openMenu(tester, 'tr_music', project: p);
      expect(find.text(TrackStrings.unlockFirst), findsWidgets);
      await tester.ensureVisible(row('track-delete'));
      await tester.tap(row('track-delete'), warnIfMissed: false);
      await tester.pump();
      expect(rig.project.tracks.any((t) => t.id == const TrackId('tr_music')), isTrue);
      await tapRow(tester, 'track-locked');
      expect(rig.track('tr_music').locked, isFalse);
      expect(find.text(TrackStrings.unlockFirst), findsNothing);
    });
  });

  group('subtitle slots run actions by id', () {
    testWidgets('bound actions run after selecting the lane and closing the menu', (tester) async {
      final log = ActionLog();
      final rig = await openMenu(tester, 'tr_subs', bindings: recordingBindings(log, skip: {EditorActionId.exportSubtitles}));
      await tapRow(tester, 'track-slot-importSubtitles');
      expect(log.ran, [EditorActionId.importSubtitles]);
      expect(rig.state.selection.lane, const TrackId('tr_subs'));
      expect(find.widgetWithText(DanaviewSectionHeader, TrackStrings.subtitlesSection), findsNothing, reason: 'the menu closed first');
    });

    testWidgets('an action nobody binds is disabled with the registry reason', (tester) async {
      final log = ActionLog();
      await openMenu(tester, 'tr_subs', bindings: recordingBindings(log, skip: {EditorActionId.exportSubtitles}));
      await tester.ensureVisible(row('track-slot-exportSubtitles'));
      await tester.tap(row('track-slot-exportSubtitles'), warnIfMissed: false);
      await tester.pump();
      expect(log.ran, isEmpty);
      expect(find.text('Not available yet'), findsOneWidget);
    });

    testWidgets('Style opens the captions panel, Regenerate runs for generated captions', (tester) async {
      final log = ActionLog();
      await openMenu(tester, 'tr_subs', project: allKindsProject(generatedSubtitles: true), bindings: recordingBindings(log));
      await tapRow(tester, 'track-slot-regenerateCaptions');
      expect(log.ran, [EditorActionId.regenerateCaptions]);
    });
  });

  group('add-track sheet', () {
    testWidgets('lists every kind and adds the chosen one', (tester) async {
      final rig = await pumpTrackRig(
        tester,
        (id) => Material(child: Builder(builder: (context) => Center(child: DanaviewButton(label: 'Open', onPressed: () => AddTrackSheet.show(context, projectId: id))))),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      for (final kind in TrackKind.values) {
        expect(find.text(TrackStrings.addTrack(kind)), findsOneWidget);
      }
      final before = rig.project.tracks.length;
      await tester.tap(find.text(TrackStrings.addTrack(TrackKind.text)));
      await tester.pumpAndSettle();
      expect(rig.project.tracks.length, before + 1);
      expect(rig.project.tracks.where((t) => t.kind == TrackKind.text), hasLength(2));
      expect(find.text(TrackStrings.addSheetTitle), findsNothing);
    });
  });

  group('no overflow, owner UI rules', () {
    final surfaces = [...SurfaceMatrix.current, if (!SurfaceMatrix.current.contains(SurfaceMatrix.narrowest.copyWith(size: const Size(320, 568)))) SurfaceMatrix.narrowest.copyWith(size: const Size(320, 568))];
    for (final surface in surfaces) {
      for (final track in ['tr_main', 'tr_music', 'tr_subs']) {
        testWidgets('$track menu on $surface', (tester) async {
          await openMenu(tester, track, surface: surface, project: withTrack(allKindsProject(generatedSubtitles: true), 'tr_music', (t) => t.copyWith(name: 'A very long audio track name ${'x' * 30}')));
          expectNoOverflow(tester);
          expectOwnerUiRules(tester);
          // Scroll to the end: the destructive row is reachable on every size.
          await tester.ensureVisible(row('track-delete'));
          await tester.pump();
          expectNoOverflow(tester);
          expectInside(tester, row('track-delete'), screen: surface.size);
        });
      }
    }
  });
}
