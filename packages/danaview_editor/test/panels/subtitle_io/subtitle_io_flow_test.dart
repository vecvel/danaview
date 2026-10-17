// OWNER: UX-32
//
// The SRT/VTT import and export flows through the registry actions (ux.md §10.9): picker -> parse
// -> result sheet (encoding fallback, skipped parts with line numbers, stripped tags) -> one
// ImportSubtitles into a new track or replacing a track -> the captions panel on the imported
// track; Export: the sheet (track, SRT/VTT) -> FileHandoff.saveToFiles / share with the right
// content and `<project>.<bcp47>.srt|vtt` name -> the temporary file deleted. Plus enablement and
// the no-overflow matrix of both sheets.

import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_editor/src/app/strings/subtitle_io_strings.dart';
import 'package:danaview_editor/src/editor/actions/editor_action_registry.dart';
import 'package:danaview_editor/src/editor/contracts/contracts.dart';
import 'package:danaview_editor/src/editor/timeline/timeline_semantics.dart' show EditorAnnouncer;
import 'package:danaview_editor_core/formats.dart';
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_editor_engine_api/danaview_editor_engine_api.dart' show FileHandoffOutcome, MediaPickKind, PickedMedia;

import '../../support/support.dart';
import 'subtitle_io_rig.dart';

final Finder _importSheet = find.byKey(const ValueKey<String>('subtitleIo.import'));
final Finder _exportSheet = find.byKey(const ValueKey<String>('subtitleIo.export'));
final Finder _importButton = find.byKey(const ValueKey<String>('subtitleIo.importButton'));

Future<void> _openImport(SubtitleIoRig rig, String name, String fixtureName) async {
  rig.offer(name, fixture(fixtureName));
  await rig.invoke(EditorActionId.importSubtitles);
  expect(_importSheet, findsOneWidget);
}

void main() {
  group('import', () {
    testWidgets('valid SRT -> new track named after the file, language from the name, one history entry', (tester) async {
      final announced = <String>[];
      final original = EditorAnnouncer.instance;
      EditorAnnouncer.instance = EditorAnnouncer(send: (_, m, __) => announced.add(m));
      addTearDown(() => EditorAnnouncer.instance = original);
      final rig = await SubtitleIoRig.pump(tester);
      final before = rig.subtitleTracks.length;
      final entries = rig.entries;
      await _openImport(rig, 'movie.en.srt', 'basic.srt');
      expect(rig.engine.picker.requests.single.kinds, {MediaPickKind.subtitle});
      expect(find.text(SubtitleIoStrings.found(2, 'movie.en.srt')), findsOneWidget);
      expect(find.text(SubtitleIoStrings.formatSrt), findsOneWidget);
      expect(find.text(SubtitleIoStrings.newTrackNote('movie', 'en')), findsOneWidget, reason: 'New track is the default');
      expect(find.byKey(const ValueKey<String>('subtitleIo.encoding')), findsNothing, reason: 'UTF-8 is not worth a note');
      expect(find.byKey(const ValueKey<String>('subtitleIo.issues')), findsNothing);
      await rig.tap(_importButton);
      expect(_importSheet, findsNothing);
      expect(rig.subtitleTracks, hasLength(before + 1));
      final lane = rig.subtitleTracks.last;
      expect(lane.name, 'movie');
      expect(lane.subtitle!.language, 'en');
      expect([for (final c in rig.cues(lane.id)) (c.start, c.end, c.text, c.origin)], [
        (1 * s, 2500000, 'Hello, world', CueOrigin.imported),
        (3 * s, FrameRate.fps30.timeOfFrame(128), 'Second line\nwraps here', CueOrigin.imported),
      ], reason: 'times round to the nearest frame (4.25 s -> frame 128 at 30 fps)');
      expect(rig.entries, entries + 1);
      expect(rig.state.inspector, SubtitlesInspector(track: lane.id), reason: 'the captions panel opens on the new track');
      expect(find.text(SubtitleIoStrings.imported(2, 'movie.en.srt')), findsOneWidget);
      expect(announced, contains(SubtitleIoStrings.imported(2, 'movie.en.srt')));
      rig.editor.undo();
      await tester.pump();
      expect(rig.subtitleTracks, hasLength(before), reason: 'undo removes the whole import');
      await rig.drainToasts();
    });

    testWidgets('replace: the selected track is the default target; its style and language stay', (tester) async {
      final rig = await SubtitleIoRig.pump(tester, selectLane: Io.english);
      final count = rig.subtitleTracks.length;
      await _openImport(rig, 'movie.srt', 'basic.srt');
      await rig.tap(find.text(SubtitleIoStrings.replaceTrack));
      expect(find.text(SubtitleIoStrings.replaceNote(2, 'English')), findsOneWidget);
      final lockedRow = find.byKey(const ValueKey<String>('subtitleIo.track.tr_locked'));
      expect(lockedRow, findsOneWidget);
      await rig.tap(lockedRow);
      expect(find.text(SubtitleIoStrings.replaceNote(2, 'English')), findsOneWidget, reason: 'a locked track cannot be chosen');
      await rig.tap(_importButton);
      expect(rig.subtitleTracks, hasLength(count));
      expect([for (final c in rig.cues(Io.english)) c.text], ['Hello, world', 'Second line\nwraps here']);
      expect(rig.track(Io.english).subtitle!.language, 'en');
      expect(rig.track(Io.english).name, 'English');
      expect(rig.state.inspector, const SubtitlesInspector(track: Io.english));
      await rig.drainToasts();
    });

    testWidgets('replace: another track can be chosen', (tester) async {
      final rig = await SubtitleIoRig.pump(tester, selectLane: Io.english);
      await _openImport(rig, 'movie.srt', 'basic.srt');
      await rig.tap(find.text(SubtitleIoStrings.replaceTrack));
      await rig.tap(find.byKey(const ValueKey<String>('subtitleIo.track.tr_auto')));
      expect(find.text(SubtitleIoStrings.replaceNote(2, 'Auto')), findsOneWidget);
      await rig.tap(_importButton);
      expect([for (final c in rig.cues(Io.auto)) c.text], ['Hello, world', 'Second line\nwraps here']);
      expect([for (final c in rig.cues(Io.english)) c.text], ['Bee one', 'Bee two'], reason: 'the selected track is untouched');
      await rig.drainToasts();
    });

    testWidgets('malformed: the skipped parts are listed with line numbers; the good cues import', (tester) async {
      final rig = await SubtitleIoRig.pump(tester);
      await _openImport(rig, 'malformed.srt', 'malformed.srt');
      expect(find.text(SubtitleIoStrings.found(2, 'malformed.srt')), findsOneWidget);
      expect(find.byKey(const ValueKey<String>('subtitleIo.issues')), findsOneWidget);
      expect(find.text("Line 6: the timing isn't valid"), findsOneWidget);
      expect(find.text('Line 10: the caption ends before it starts'), findsOneWidget);
      await rig.tap(_importButton);
      expect([for (final c in rig.cues(rig.subtitleTracks.last.id)) c.text], ['Good one', 'Good two']);
      await rig.drainToasts();
    });

    testWidgets('UTF-16 is read and said; Windows-1252 is reported as a fallback', (tester) async {
      final rig = await SubtitleIoRig.pump(tester);
      await _openImport(rig, 'utf16.srt', 'utf16le_bom.srt');
      expect(find.text(SubtitleIoStrings.encodingNote(TextEncoding.utf16le)!), findsOneWidget);
      await rig.tap(_importButton);
      expect(rig.cues(rig.subtitleTracks.last.id).first.text, 'Héllo, world');
      await rig.drainToasts();
      await _openImport(rig, 'cafe.srt', 'cp1252.srt');
      expect(find.text(SubtitleIoStrings.encodingNote(TextEncoding.windows1252)!), findsOneWidget);
      await rig.tap(find.text(SubtitleIoStrings.cancel));
      await rig.drainToasts();
    });

    testWidgets('stripped tags and ignored settings of a VTT are summarized', (tester) async {
      final rig = await SubtitleIoRig.pump(tester);
      await _openImport(rig, 'full.vtt', 'vtt_full.vtt');
      expect(find.text(SubtitleIoStrings.formatVtt), findsOneWidget);
      expect(find.byKey(const ValueKey<String>('subtitleIo.stripped')), findsOneWidget);
      expect(find.byKey(const ValueKey<String>('subtitleIo.ignored')), findsOneWidget);
      await rig.tap(find.text(SubtitleIoStrings.cancel));
      await rig.drainToasts();
    });

    testWidgets('nothing readable: the first bad line and Close only; the project is unchanged', (tester) async {
      final rig = await SubtitleIoRig.pump(tester);
      final entries = rig.entries;
      await _openImport(rig, 'no_header.vtt', 'vtt_no_header.vtt');
      expect(find.text(SubtitleIoStrings.nothingFound('no_header.vtt')), findsOneWidget);
      expect(find.text(SubtitleIoStrings.issue(1, SubtitleIssueKind.missingHeader)), findsOneWidget);
      expect(_importButton, findsNothing);
      await rig.tap(find.byKey(const ValueKey<String>('subtitleIo.closeButton')));
      expect(_importSheet, findsNothing);
      expect(rig.entries, entries);
      await rig.drainToasts();
    });

    testWidgets('cancel in the sheet or the picker changes nothing; an unreadable pick says so', (tester) async {
      final rig = await SubtitleIoRig.pump(tester);
      final entries = rig.entries;
      await _openImport(rig, 'movie.srt', 'basic.srt');
      await rig.tap(find.text(SubtitleIoStrings.cancel));
      expect(rig.entries, entries);
      await rig.invoke(EditorActionId.importSubtitles); // the picker returns nothing
      expect(_importSheet, findsNothing);
      rig.engine.picker.nextPicks = [const PickedMedia(uri: 'content://docs/7', displayName: 'cloud.srt')];
      await rig.invoke(EditorActionId.importSubtitles);
      expect(_importSheet, findsNothing);
      expect(find.text(SubtitleIoStrings.cannotOpen), findsOneWidget);
      expect(rig.entries, entries);
      await rig.drainToasts();
    });

    testWidgets('overlapping cues spill to extra tracks and the toast says so', (tester) async {
      final rig = await SubtitleIoRig.pump(tester);
      const srt = '1\n00:00:01,000 --> 00:00:04,000\nOne\n\n2\n00:00:02,000 --> 00:00:03,000\nTwo\n';
      rig.offer('overlap.srt', utf8.encode(srt));
      await rig.invoke(EditorActionId.importSubtitles);
      final before = rig.subtitleTracks.length;
      await rig.tap(_importButton);
      expect(rig.subtitleTracks, hasLength(before + 2));
      expect(find.text('${SubtitleIoStrings.imported(2, 'overlap.srt')} ${SubtitleIoStrings.spilled(1)}'), findsOneWidget);
      await rig.drainToasts();
    });
  });

  group('export', () {
    testWidgets('Save to Files: the selected track as SRT, named <project>.<bcp47>.srt, then deleted', (tester) async {
      final rig = await SubtitleIoRig.pump(tester, selectLane: Io.english);
      await rig.invoke(EditorActionId.exportSubtitles);
      expect(_exportSheet, findsOneWidget);
      expect(find.byKey(const ValueKey<String>('subtitleIo.exportTrack.tr_en')), findsOneWidget);
      expect(find.byKey(const ValueKey<String>('subtitleIo.exportTrack.tr_auto')), findsOneWidget);
      expect(find.text('My Film.en.srt'), findsOneWidget);
      await rig.tap(find.byKey(const ValueKey<String>('subtitleIo.saveToFiles')));
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await rig.settle();
      final call = rig.handoff.calls.single;
      expect(call.kind, 'files');
      expect(call.name, 'My Film.en.srt');
      expect(call.path, startsWith('${memRoots.workDir}/subtitles-'));
      expect(call.bytes, SubtitleCodec.serialize([SubtitleCueData(0, 2 * s, 'Bee one'), SubtitleCueData(3 * s, 5 * s, 'Bee two')], SubtitleFormat.srt));
      expect(rig.fs.filePaths.where((f) => f.startsWith(memRoots.workDir)), isEmpty, reason: 'OwnedFileDeleter removed it');
      expect(find.text(SubtitleIoStrings.saved('My Film.en.srt')), findsOneWidget);
      await rig.drainToasts();
    });

    testWidgets('Share: generated captions as VTT', (tester) async {
      final rig = await SubtitleIoRig.pump(tester, selectLane: Io.english);
      await rig.invoke(EditorActionId.exportSubtitles);
      expect(find.text('2 captions · ${SubtitleIoStrings.generated}'), findsOneWidget);
      await rig.tap(find.byKey(const ValueKey<String>('subtitleIo.exportTrack.tr_auto')));
      await rig.tap(find.text(SubtitleIoStrings.vtt));
      expect(find.text('My Film.fr.vtt'), findsOneWidget);
      expect(find.text(SubtitleIoStrings.vttHint), findsOneWidget);
      await rig.tap(find.byKey(const ValueKey<String>('subtitleIo.share')));
      final call = rig.handoff.calls.single;
      expect(call.kind, 'share');
      expect(call.path, endsWith('/My Film.fr.vtt'));
      expect(SubtitleCodec.parse(call.bytes).cues, [SubtitleCueData(1 * s, 3 * s, 'Bonjour'), SubtitleCueData(4 * s, 6 * s, 'Salut')]);
      expect(rig.fs.filePaths.where((f) => f.startsWith(memRoots.workDir)), isEmpty);
      await rig.drainToasts();
    });

    testWidgets('a cancelled save is quiet; a denied one explains; dismissing the sheet exports nothing', (tester) async {
      final rig = await SubtitleIoRig.pump(tester, selectLane: Io.english);
      rig.handoff.next = FileHandoffOutcome.cancelled;
      await rig.invoke(EditorActionId.exportSubtitles);
      await rig.tap(find.byKey(const ValueKey<String>('subtitleIo.saveToFiles')));
      expect(rig.handoff.calls, hasLength(1));
      expect(find.text(SubtitleIoStrings.saved('My Film.en.srt')), findsNothing);
      rig.handoff.next = FileHandoffOutcome.denied;
      await rig.invoke(EditorActionId.exportSubtitles);
      await rig.tap(find.byKey(const ValueKey<String>('subtitleIo.saveToFiles')));
      expect(find.text(SubtitleIoStrings.handoffDenied), findsOneWidget);
      await rig.drainToasts();
      await rig.invoke(EditorActionId.exportSubtitles);
      Navigator.of(tester.element(_exportSheet)).pop();
      await rig.settle();
      expect(rig.handoff.calls, hasLength(2));
      expect(rig.fs.filePaths.where((f) => f.startsWith(memRoots.workDir)), isEmpty);
    });
  });

  group('enablement', () {
    testWidgets('import is enabled once open; export needs a subtitle track with captions', (tester) async {
      final rig = await SubtitleIoRig.pump(tester, subtitles: false);
      final ctx = rig.actionContext();
      final import = rig.spec(EditorActionId.importSubtitles);
      final export = rig.spec(EditorActionId.exportSubtitles);
      expect(import.isBound, isTrue);
      expect(export.isBound, isTrue);
      expect(import.isEnabled(ctx), isTrue);
      expect(export.isEnabled(ctx), isFalse);
      expect(export.disabledReason(ctx), SubtitleIoStrings.nothingToExport);
      expect(await rig.invoke(EditorActionId.exportSubtitles), EditorActionResult.disabled);
      rig.offer('movie.en.srt', fixture('basic.srt'));
      await rig.invoke(EditorActionId.importSubtitles);
      expect(find.text(SubtitleIoStrings.noReplaceTarget), findsOneWidget, reason: 'nothing to replace yet');
      await rig.tap(_importButton);
      expect(export.isEnabled(ctx), isTrue);
      await rig.drainToasts();
      await rig.invoke(EditorActionId.exportSubtitles);
      expect(find.byKey(ValueKey<String>('subtitleIo.exportTrack.${rig.subtitleTracks.single.id.value}')), findsNothing,
          reason: 'one track: no track list');
      expect(find.text('My Film.en.srt'), findsOneWidget);
      Navigator.of(tester.element(_exportSheet)).pop();
      await rig.settle();
    });
  });

  group('matrix', () {
    testSurfaces('the import sheet fits: issues, notes and the replace list', (tester, surface) async {
      final rig = await SubtitleIoRig.pump(tester, surface: surface, selectLane: Io.english);
      rig.offer('a.very.long.file.name.of.subtitles.from.somewhere.en.srt', fixture('malformed.srt'));
      await rig.invoke(EditorActionId.importSubtitles);
      expectNoOverflow(tester);
      expectOwnerUiRules(tester);
      await rig.tap(find.text(SubtitleIoStrings.replaceTrack));
      expectNoOverflow(tester);
      expectOwnerUiRules(tester);
      await tester.ensureVisible(_importButton);
      await tester.pump();
      expectInside(tester, _importButton);
      Navigator.of(tester.element(_importSheet)).pop();
      await rig.settle();
      rig.offer('full.vtt', fixture('vtt_full.vtt'));
      await rig.invoke(EditorActionId.importSubtitles);
      expectNoOverflow(tester);
      Navigator.of(tester.element(_importSheet)).pop();
      await rig.settle();
    });

    testSurfaces('the export sheet fits with the track list and both formats', (tester, surface) async {
      final rig = await SubtitleIoRig.pump(tester, surface: surface, selectLane: Io.english);
      await rig.invoke(EditorActionId.exportSubtitles);
      expectNoOverflow(tester);
      expectOwnerUiRules(tester);
      await rig.tap(find.text(SubtitleIoStrings.vtt));
      expectNoOverflow(tester);
      final save = find.byKey(const ValueKey<String>('subtitleIo.saveToFiles'));
      await tester.ensureVisible(save);
      await tester.pump();
      expectInside(tester, save);
      Navigator.of(tester.element(_exportSheet)).pop();
      await rig.settle();
    });
  });
}
