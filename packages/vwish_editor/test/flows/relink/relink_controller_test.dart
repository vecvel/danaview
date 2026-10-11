// OWNER: UX-40
//
// RelinkController (ux.md §13.2) with the scripted pool: rows per availability state, every
// checkRelink outcome (match, durationMismatch, differentKind, unsupported), use updated file, find
// in same folder, Relink several (10 missing Photos assets in one pick session), and applying: ONE
// undoable "Relink media" history entry through the editor controller, with the clamps of a shorter
// file, plus remove clips and replace.

import 'dart:convert' show base64;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vwish_editor/src/app/editor_providers.dart';
import 'package:vwish_editor/src/editor/flows/relink/relink_controller.dart';
import 'package:vwish_editor/src/editor/state/editor_state.dart';
import 'package:vwish_editor/src/editor/state/media_health_controller.dart';
import 'package:vwish_editor_core/model.dart';
import 'package:vwish_editor_core/ops.dart' show CompositeCommand, DeleteItems, TrimItem;
import 'package:vwish_editor_core/store.dart';
import 'package:vwish_editor_engine_api/vwish_editor_engine_api.dart' show MediaPickKind, MediaPickSource;

import 'relink_support.dart';

PickedMedia pickOf(String name, {bool photo = false, Uint8List? bookmark, String dir = '/picked'}) => PickedMedia(
      uri: photo ? 'file:///work/picks/$name' : 'file://$dir/$name',
      displayName: name,
      origin: photo ? MediaOrigin.photos : MediaOrigin.files,
      isTemporaryCopy: photo,
      bookmark: bookmark,
    );

void main() {
  late RelinkRig rig;

  RelinkController controller() => rig.container.read(relinkControllerProvider(rig.id).notifier);
  RelinkState state() => rig.container.read(relinkControllerProvider(rig.id));
  RelinkRow row(String id) => state().rowOf(MediaId(id))!;

  Future<void> start(List<MediaAsset> assets, Map<String, MediaAvailability> offline, {Map<String, int> extraUses = const {}}) async {
    rig = RelinkRig(assets, extraUses: extraUses);
    rig.useContainer(rig.harness.container());
    await rig.open();
    rig.container.listen(mediaHealthControllerProvider(rig.id), (_, __) {});
    rig.container.listen(relinkControllerProvider(rig.id), (_, __) {});
    await rig.report(offline);
  }

  Future<void> settle() async {
    for (var i = 0; i < 6; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  List<MediaAsset> three() => [videoAsset('md_1', name: 'IMG_0001.MOV'), videoAsset('md_2', name: 'beach.mp4'), videoAsset('md_3', name: 'drone.mp4')];

  Map<String, MediaAvailability> allMissing() => {for (final i in ['md_1', 'md_2', 'md_3']) i: MediaAvailability.missing};

  group('rows', () {
    test('one row per offline asset, the used ones first, with usage and the reason', () async {
      final assets = [
        videoAsset('md_1', name: 'zebra.mov'),
        videoAsset('md_2', name: 'alpha.mov', locator: BookmarkLocator(base64.encode([1, 2, 3]), lastKnownPath: '/Users/me/Movies/Trip/alpha.mov')),
        videoAsset('md_3', name: 'mid.mov', locator: const FileLocator('/Users/me/Documents/mid.mov')),
        videoAsset('md_4', name: 'fine.mov'),
      ];
      await start(assets, {
        'md_1': MediaAvailability.missing,
        'md_2': MediaAvailability.accessLost,
        'md_3': MediaAvailability.changed,
        'md_4': MediaAvailability.derivedMissing,
      }, extraUses: {'md_3': 2});
      expect(state().checked, isTrue);
      expect(state().rows.map((r) => r.asset.id.value), ['md_2', 'md_3', 'md_1'], reason: 'alphabetical among the used; derivedMissing is not a row');
      expect(row('md_3').usedClips, 3);
      expect(row('md_1').usedClips, 1);
      expect(row('md_2').availability, MediaAvailability.accessLost);
      expect(row('md_3').availability, MediaAvailability.changed);
      expect(row('md_1').phase, RelinkRowPhase.needsFile);
      expect(lastKnownFolderOf(row('md_2').asset), 'Trip');
      expect(lastKnownFolderOf(row('md_3').asset), 'Documents');
      expect(lastKnownFolderOf(row('md_1').asset), isNull);
    });

    test('rows leave when the file comes back and staged files of the others stay', () async {
      await start(three(), allMissing());
      rig.harness.engine.picker.nextPicks = [pickOf('a.mov')];
      await controller().locate(const MediaId('md_1'), MediaPickSource.files);
      await settle();
      expect(row('md_1').pick, isNotNull);
      await rig.report({'md_1': MediaAvailability.missing, 'md_2': MediaAvailability.missing});
      expect(state().rows.map((r) => r.asset.id.value), ['md_2', 'md_1'], reason: 'alphabetical: beach, IMG');
      expect(row('md_1').phase, RelinkRowPhase.ready, reason: 'the staged file is kept');
    });
  });

  group('locate and checkRelink outcomes', () {
    setUp(() async {
      await start(three(), allMissing());
    });

    Future<void> locate(String id, PickedMedia pick, {MediaPickSource source = MediaPickSource.files}) async {
      rig.harness.engine.picker.nextPicks = [pick];
      await controller().locate(MediaId(id), source);
      await settle();
    }

    test('match: ready to relink', () async {
      await locate('md_1', pickOf('IMG_0001.MOV'));
      expect(row('md_1').phase, RelinkRowPhase.ready);
      expect(row('md_1').willRelink, isTrue);
      expect(state().readyCount, 1);
      expect(rig.pool.calls, contains('checkRelink'));
      final request = rig.harness.engine.picker.requests.single;
      expect(request.source, MediaPickSource.files);
      expect(request.kinds, {MediaPickKind.video});
      expect(request.multiple, isFalse);
    });

    test('durationMismatch: shorter and longer need the user to accept', () async {
      rig.pool.checks['short.mov'] = const RelinkDurationMismatch(expectedUs: 5000000, actualUs: 3000000);
      rig.pool.checks['long.mov'] = const RelinkDurationMismatch(expectedUs: 5000000, actualUs: 7000000);
      await locate('md_1', pickOf('short.mov'));
      await locate('md_2', pickOf('long.mov'));
      for (final id in ['md_1', 'md_2']) {
        expect(row(id).phase, RelinkRowPhase.confirm);
        expect(row(id).willRelink, isFalse, reason: 'not before the user says so');
      }
      expect(state().readyCount, 0);
      controller().acceptMismatch(const MediaId('md_1'));
      expect(row('md_1').willRelink, isTrue);
      expect(row('md_2').willRelink, isFalse);
      controller().acceptMismatch(const MediaId('md_3'));
      expect(row('md_3').accepted, isFalse, reason: 'only a row waiting for confirmation can accept');
    });

    test('differentKind and unsupported say why and never relink', () async {
      rig.pool.checks['song.mp3'] = const RelinkDifferentKind();
      rig.pool.checks['big.mov'] = const RelinkUnsupported('dimensionsDiffer');
      rig.pool.checks['holiday.mkv'] = const RelinkUnsupported('containerUnsupportedIos');
      await locate('md_1', pickOf('song.mp3'));
      expect(row('md_1').phase, RelinkRowPhase.rejected);
      expect(row('md_1').message, 'Pick a video file to replace a video.');
      await locate('md_2', pickOf('big.mov'));
      expect(row('md_2').message, contains('different picture size'));
      await locate('md_3', pickOf('holiday.mkv'));
      expect(row('md_3').message, "MKV, WebM and AVI videos can't be edited on iPhone and iPad. Convert it to MP4 or MOV first.");
      expect(state().readyCount, 0);
    });

    test('a check that throws reads as unreadable, not as a crash', () async {
      rig.pool.checks['gone.mov'] = const RelinkUnsupported('notFound');
      await locate('md_1', pickOf('gone.mov'));
      expect(row('md_1').message, 'This file is no longer available. Pick it again.');
      rig.pool.throwingChecks.add('boom.mov');
      await locate('md_2', pickOf('boom.mov'));
      expect(row('md_2').phase, RelinkRowPhase.rejected);
      expect(row('md_2').message, "Couldn't read this file. Pick it again.");
    });

    test('cancelling the picker changes nothing; a failing picker shows a message', () async {
      rig.harness.engine.picker.nextPicks = const [];
      await controller().locate(const MediaId('md_1'), MediaPickSource.photos);
      expect(row('md_1').pick, isNull);
      expect(state().busy, isFalse);
      expect(state().failure, isNull);
    });

    test('picking another file replaces the staged one; clear drops it', () async {
      await locate('md_1', pickOf('first.mov'));
      await locate('md_1', pickOf('second.mov'));
      expect(row('md_1').pick!.displayName, 'second.mov');
      controller().clear(const MediaId('md_1'));
      expect(row('md_1').pick, isNull);
      expect(row('md_1').phase, RelinkRowPhase.needsFile);
    });

    test('Photos can be picked from; an audio asset only from Files', () async {
      await locate('md_1', pickOf('p.mov', photo: true), source: MediaPickSource.photos);
      expect(rig.harness.engine.picker.requests.last.source, MediaPickSource.photos);
      expect(relinkPickKinds(MediaKind.audio), {MediaPickKind.audio});
      expect(relinkPickKinds(MediaKind.still), {MediaPickKind.image});
      expect(relinkPickKinds(MediaKind.lut), {MediaPickKind.lut});
      expect(relinkPickKinds(MediaKind.recording), {MediaPickKind.audio});
    });
  });

  group('use updated file', () {
    test('stages the file a changed asset points at; managed copies cannot', () async {
      final assets = [
        videoAsset('md_1', name: 'edited.mov', locator: const FileLocator('/Users/me/Movies/edited.mov')),
        videoAsset('md_2', name: 'managed.mov'),
        videoAsset('md_3', name: 'marked.mov', locator: BookmarkLocator(base64.encode([9, 8]), lastKnownPath: '/Users/me/Movies/marked.mov')),
      ];
      await start(assets, {for (final a in assets) a.id.value: MediaAvailability.changed});
      expect(controller().canUseUpdated(row('md_1')), isTrue);
      expect(controller().canUseUpdated(row('md_2')), isFalse);
      await controller().useUpdatedFile(const MediaId('md_1'));
      await settle();
      expect(row('md_1').pick!.uri, 'file:///Users/me/Movies/edited.mov');
      expect(row('md_1').phase, RelinkRowPhase.ready);
      await controller().useUpdatedFile(const MediaId('md_3'));
      await settle();
      expect(row('md_3').pick!.bookmark, [9, 8]);
      await controller().useUpdatedFile(const MediaId('md_2'));
      expect(row('md_2').pick, isNull);
      final plain = videoAsset('md_9', name: 'plain.mov', locator: const FileLocator('/Users/me/Movies/plain.mov'));
      expect(controller().canUseUpdated(RelinkRow(asset: plain, availability: MediaAvailability.missing, usedClips: 1)), isFalse, reason: 'only changed files');
    });
  });

  group('find in same folder', () {
    setUp(() async {
      await start(three(), allMissing());
    });

    test('stages the matching files next to a path pick and reports how many were found', () async {
      rig.pool.onFindInSameFolder = (anchor) => [
            RelinkCandidate(media: const MediaId('md_2'), pick: pickOf('beach.mp4', dir: '/Movies/Trip'), check: const RelinkMatch(exactFingerprint: true)),
            RelinkCandidate(media: const MediaId('md_3'), pick: pickOf('drone.mp4', dir: '/Movies/Trip'), check: const RelinkDurationMismatch(expectedUs: 5000000, actualUs: 6000000)),
          ];
      rig.harness.engine.picker.nextPicks = [pickOf('IMG_0001.MOV', dir: '/Movies/Trip')];
      await controller().locate(const MediaId('md_1'), MediaPickSource.files);
      await settle();
      expect(row('md_1').hasPathPick, isTrue);
      await controller().findInSameFolder(const MediaId('md_1'));
      expect(rig.pool.calls, contains('findInSameFolder'));
      expect(state().note, 'Found 2 of 2 in the same folder');
      expect(row('md_2').phase, RelinkRowPhase.ready);
      expect(row('md_3').phase, RelinkRowPhase.confirm, reason: 'its length differs');
    });

    test('nothing next to it is said plainly', () async {
      rig.harness.engine.picker.nextPicks = [pickOf('IMG_0001.MOV')];
      await controller().locate(const MediaId('md_1'), MediaPickSource.files);
      await settle();
      await controller().findInSameFolder(const MediaId('md_1'));
      expect(state().note, 'No other missing files are in that folder.');
    });

    test('is not offered for Photos copies, bookmarks or content URIs', () async {
      Future<void> stagedPick(PickedMedia p) async {
        rig.harness.engine.picker.nextPicks = [p];
        await controller().locate(const MediaId('md_1'), MediaPickSource.files);
        await settle();
      }

      await stagedPick(pickOf('p.mov', photo: true));
      expect(row('md_1').hasPathPick, isFalse);
      await stagedPick(pickOf('b.mov', bookmark: Uint8List.fromList([1])));
      expect(row('md_1').hasPathPick, isFalse);
      await stagedPick(const PickedMedia(uri: 'content://media/external/video/42', displayName: 'c.mov'));
      expect(row('md_1').hasPathPick, isFalse);
    });
  });

  group('apply: one undoable history entry', () {
    setUp(() async {
      await start(three(), allMissing());
    });

    Future<void> stageAll({Map<String, RelinkCheck> checks = const {}}) async {
      rig.pool.checks.addAll(checks);
      for (final (i, a) in three().indexed) {
        rig.harness.engine.picker.nextPicks = [pickOf('${a.id.value}_new.mov')];
        await controller().locate(a.id, MediaPickSource.files);
        await settle();
        expect(row(a.id.value).pick, isNotNull, reason: 'picked $i');
      }
    }

    test('three files relinked together are one history entry through the editor controller', () async {
      await stageAll();
      expect(rig.editor.state.history.canUndo, isFalse);
      expect(await controller().apply(), isTrue);
      expect(rig.pool.lastRelink!.keys.map((k) => k.value).toSet(), {'md_1', 'md_2', 'md_3'});
      expect(rig.pool.relinkSessions, hasLength(1), reason: 'one relink call');
      expect(identical(rig.pool.relinkSessions.single, rig.editor.session.edit), isFalse, reason: 'the pool ran on a scratch session');
      final history = rig.editor.state.history;
      expect(history.canUndo, isTrue);
      expect(history.undoLabel, 'Relink media');
      expect(rig.editor.session.historyEntries, hasLength(1));
      final pool = rig.editor.state.project!.pool;
      for (final id in ['md_1', 'md_2', 'md_3']) {
        expect(pool[MediaId(id)]!.locator, FileLocator('/restored/${id}_new.mov'));
      }
      expect(rig.editor.state.save.phase, SavePhase.edited);
      expect(state().applies, 1);
      expect(state().lastRelinked, 3);

      // Undo restores every asset in one step, redo relinks them again.
      expect(rig.editor.undo(), isTrue);
      expect(rig.editor.state.project!.pool[const MediaId('md_1')]!.locator, isA<AppRelativeLocator>());
      expect(rig.editor.state.project!.pool[const MediaId('md_3')]!.locator, isA<AppRelativeLocator>());
      expect(rig.editor.undo(), isFalse, reason: 'it was the only entry');
      expect(rig.editor.redo(), isTrue);
      expect(rig.editor.state.project!.pool[const MediaId('md_2')]!.locator, const FileLocator('/restored/md_2_new.mov'));
    });

    test('a shorter file clamps the clips in the same entry, exactly as the pool service decided', () async {
      await stageAll(checks: {'md_1_new.mov': const RelinkDurationMismatch(expectedUs: 5000000, actualUs: 3000000)});
      controller().acceptMismatch(const MediaId('md_1'));
      rig.pool.newSeconds['md_1_new.mov'] = 3;
      final before = rig.editor.state.project!;
      expect(await controller().apply(), isTrue);
      final scratch = rig.pool.relinkSessions.single.committedProject;
      final after = rig.editor.state.project!;
      MediaClip clipOf(EditProject p, String media) => p.tracks.expand((t) => t.items).whereType<MediaClip>().firstWhere((c) => c.media.value == media);
      expect(clipOf(before, 'md_1').duration, 5000000);
      expect(clipOf(after, 'md_1').duration, 3000000);
      expect(clipOf(after, 'md_1').duration, clipOf(scratch, 'md_1').duration);
      expect(after.timeline.tracks.map((t) => t.items).toList(), scratch.timeline.tracks.map((t) => t.items).toList(), reason: 'the replay equals the pool outcome');
      expect(rig.editor.session.historyEntries, hasLength(1), reason: 'the clamp is part of the relink entry');
      expect(rig.editor.undo(), isTrue);
      expect(clipOf(rig.editor.state.project!, 'md_1').duration, 5000000);
    });

    test('files not accepted, rejected or unstaged are left out', () async {
      rig.pool.checks['md_2_new.mov'] = const RelinkDifferentKind();
      for (final id in ['md_1', 'md_2']) {
        rig.harness.engine.picker.nextPicks = [pickOf('${id}_new.mov')];
        await controller().locate(MediaId(id), MediaPickSource.files);
        await settle();
      }
      expect(await controller().apply(), isTrue);
      expect(rig.pool.lastRelink!.keys.map((k) => k.value), ['md_1']);
      expect(state().lastRelinked, 1);
    });

    test('nothing staged: no call, no history', () async {
      expect(await controller().apply(), isFalse);
      expect(rig.pool.calls, isNot(contains('relink')));
      expect(rig.editor.state.history.canUndo, isFalse);
    });

    test('the pool refusing the relink changes nothing and says so', () async {
      await stageAll();
      rig.pool.rejectRelink = true;
      expect(await controller().apply(), isFalse);
      expect(state().failure!.title, "Couldn't relink these files");
      expect(state().failure!.detail, contains('Nothing was changed'));
      expect(rig.editor.state.history.canUndo, isFalse);
      expect(rig.editor.state.project!.pool[const MediaId('md_1')]!.locator, isA<AppRelativeLocator>());
      expect(state().stage, RelinkStage.list);
      expect(state().busy, isFalse);
      controller().dismissFailure();
      expect(state().failure, isNull);
    });

    test('the availability report after a relink removes the rows', () async {
      await stageAll();
      await controller().apply();
      await rig.report({});
      expect(state().rows, isEmpty);
      expect(rig.editor.state.media, MediaHealth.ok);
    });
  });

  group('relink several', () {
    List<MediaAsset> ten() => [for (var i = 1; i <= 10; i++) videoAsset('md_$i', name: 'IMG_${i.toString().padLeft(4, '0')}.MOV', seconds: 3 + i)];

    List<PickedMedia> photos(int n) => [for (var i = 1; i <= n; i++) pickOf('copy_$i.MOV', photo: true)];

    test('10 missing Photos assets are relinked in one pick session and one history entry', () async {
      final assets = ten();
      await start(assets, {for (final a in assets) a.id.value: MediaAvailability.missing});
      final picks = photos(10);
      rig.harness.engine.picker.nextPicks = picks;
      rig.pool.onAutoMatch = (p) => [
            for (var i = 0; i < p.length; i++) RelinkProposal(pick: p[i], media: assets[9 - i].id, check: const RelinkMatch(exactFingerprint: true)),
          ];
      await controller().relinkSeveral(MediaPickSource.photos);
      expect(rig.harness.engine.picker.requests, hasLength(1), reason: 'one pick session');
      expect(rig.harness.engine.picker.requests.single.source, MediaPickSource.photos);
      expect(rig.harness.engine.picker.requests.single.multiple, isTrue);
      expect(rig.pool.calls.where((c) => c == 'autoMatch'), hasLength(1));
      expect(state().stage, RelinkStage.confirm);
      final plan = state().several!;
      expect(plan.matches, hasLength(10));
      expect(plan.unmatchedPicks, isEmpty);
      expect(plan.stillMissing, isEmpty);
      expect(plan.picked, 10);
      expect(plan.includedCount, 10);

      expect(await controller().confirmSeveral(), isTrue);
      expect(rig.pool.calls.where((c) => c == 'relink'), hasLength(1));
      expect(rig.pool.lastRelink!.keys, hasLength(10));
      expect(rig.editor.session.historyEntries, hasLength(1));
      expect(rig.editor.state.history.undoLabel, 'Relink media');
      final pool = rig.editor.state.project!.pool;
      expect([for (final a in assets) pool[a.id]!.locator is FileLocator], everyElement(isTrue));
      expect(state().stage, RelinkStage.list);
      expect(state().several, isNull);
      expect(state().lastRelinked, 10);
    });

    test('unassigned picks and assets are shown; a pair can be switched off', () async {
      final assets = ten();
      await start(assets, {for (final a in assets) a.id.value: MediaAvailability.missing});
      final picks = photos(11);
      rig.harness.engine.picker.nextPicks = picks;
      rig.pool.onAutoMatch = (p) => [
            for (var i = 0; i < 8; i++) RelinkProposal(pick: p[i], media: assets[i].id, check: const RelinkMatch(exactFingerprint: false)),
            RelinkProposal(pick: p[8], media: null, check: const RelinkUnsupported('ambiguous')),
            RelinkProposal(pick: p[9], media: null, check: const RelinkUnsupported('noMatch')),
            RelinkProposal(pick: p[10], media: null, check: const RelinkDifferentKind()),
          ];
      await controller().relinkSeveral(MediaPickSource.photos);
      final plan = state().several!;
      expect(plan.matches, hasLength(8));
      expect(plan.unmatchedPicks.map((p) => p.pick.displayName), ['copy_9.MOV', 'copy_10.MOV', 'copy_11.MOV']);
      expect(plan.stillMissing.map((a) => a.id.value), ['md_9', 'md_10']);
      expect(plan.picked, 11);
      controller().setMatchIncluded(0, false);
      controller().setMatchIncluded(99, false);
      expect(state().several!.includedCount, 7);
      expect(await controller().confirmSeveral(), isTrue);
      expect(rig.pool.lastRelink!.keys.map((k) => k.value).toSet(), {for (var i = 2; i <= 8; i++) 'md_$i'});
      expect(rig.editor.session.historyEntries, hasLength(1));
      expect(rig.editor.state.project!.pool[const MediaId('md_1')]!.locator, isA<AppRelativeLocator>(), reason: 'the switched-off pair stays missing');
    });

    test('nothing matched: the confirm list says so and relinks nothing; back returns', () async {
      await start(three(), allMissing());
      rig.harness.engine.picker.nextPicks = photos(2);
      await controller().relinkSeveral(MediaPickSource.files);
      expect(state().stage, RelinkStage.confirm);
      expect(state().several!.matches, isEmpty);
      expect(state().several!.unmatchedPicks, hasLength(2));
      expect(await controller().confirmSeveral(), isFalse);
      expect(rig.pool.calls, isNot(contains('relink')));
      controller().cancelSeveral();
      expect(state().stage, RelinkStage.list);
      expect(state().several, isNull);
    });

    test('cancelling the picker leaves the list as it was', () async {
      await start(three(), allMissing());
      rig.harness.engine.picker.nextPicks = const [];
      await controller().relinkSeveral(MediaPickSource.photos);
      expect(state().stage, RelinkStage.list);
      expect(rig.pool.calls, isNot(contains('autoMatch')));
    });
  });

  group('remove and replace', () {
    test('Remove clips deletes every clip that uses the file, as one history entry', () async {
      await start(three(), allMissing(), extraUses: {'md_2': 1});
      expect(controller().clipsUsing(const MediaId('md_2')), hasLength(2));
      expect(controller().removeClips(const MediaId('md_2')), 2);
      expect(controller().clipsUsing(const MediaId('md_2')), isEmpty);
      expect(rig.editor.session.historyEntries, hasLength(1));
      expect(rig.editor.undo(), isTrue);
      expect(controller().clipsUsing(const MediaId('md_2')), hasLength(2));
      expect(controller().removeClips(const MediaId('md_9')), 0);
    });

    test('Replace with other media imports the pick and swaps the clips in one entry', () async {
      await start(three(), allMissing(), extraUses: {'md_1': 1});
      final replacement = videoAsset('md_new', name: 'replacement.mov', seconds: 10);
      rig.pool.importAssets['replacement.mov'] = replacement;
      rig.harness.engine.picker.nextPicks = [pickOf('replacement.mov')];
      expect(await controller().replaceWith(const MediaId('md_1'), MediaPickSource.files), 2);
      expect(rig.pool.calls, contains('import'));
      final clips = rig.editor.state.project!.tracks.expand((t) => t.items).whereType<MediaClip>().where((c) => c.media.value == 'md_new');
      expect(clips, hasLength(2));
      expect(rig.editor.state.history.undoLabel, 'Replace media');
      expect(rig.editor.session.historyEntries, hasLength(1), reason: 'the import itself is not a history entry');
    });

    test('a replacement that cannot be imported changes nothing', () async {
      await start(three(), allMissing());
      rig.pool.importRejections['bad.mov'] = 'unsupported';
      rig.harness.engine.picker.nextPicks = [pickOf('bad.mov')];
      expect(await controller().replaceWith(const MediaId('md_1'), MediaPickSource.files), 0);
      expect(state().failure!.title, 'This format is not supported for editing.');
      expect(rig.editor.state.history.canUndo, isFalse);
    });
  });

  group('helpers', () {
    test('relinkAdjustment turns the difference between two projects into clamp commands', () async {
      final repo = FakeProjectRepositoryHolder.make();
      final base = projectWithMedia(repo, [videoAsset('md_1', seconds: 5), videoAsset('md_2', seconds: 5)]);
      expect(relinkAdjustment(base, base, {const MediaId('md_1')}), isNull);
      final clips = base.tracks.expand((t) => t.items).whereType<MediaClip>().toList();
      // md_1's clip loses its tail; md_2's clip vanishes.
      final changed = base.copyWith(
        timeline: base.timeline.copyWith(tracks: [
          for (final t in base.tracks) t.copyWith(items: [for (final i in t.items) if (i.id != clips[1].id) if (i.id == clips[0].id) (i as MediaClip).copyWith(duration: 1000000) else i]),
        ]),
      );
      final cmd = relinkAdjustment(base, changed, {const MediaId('md_1'), const MediaId('md_2')})! as CompositeCommand;
      expect(cmd.label, 'Relink media');
      expect(cmd.commands.first, isA<DeleteItems>());
      expect((cmd.commands.first as DeleteItems).ids, {clips[1].id});
      expect(cmd.commands.last, isA<TrimItem>());
      expect((cmd.commands.last as TrimItem).newTime, clips[0].start + 1000000);
      expect(relinkAdjustment(base, changed, {const MediaId('md_9')}), isNull, reason: 'other media is not ours to adjust');
    });

    test('pickedFromLocator and lastKnownFolderOf', () {
      final file = videoAsset('md_1', name: 'a.mov', locator: const FileLocator('/Users/me/Movies/a.mov'));
      expect(pickedFromLocator(file)!.uri, 'file:///Users/me/Movies/a.mov');
      expect(pickedFromLocator(file)!.displayName, 'a.mov');
      final content = videoAsset('md_2', locator: const ContentUriLocator('content://media/42'));
      expect(pickedFromLocator(content)!.uri, 'content://media/42');
      expect(pickedFromLocator(videoAsset('md_3')), isNull);
      expect(lastKnownFolderOf(content), isNull);
      final docs = videoAsset('md_4', locator: const AppRelativeLocator(AppRoot.documents, 'Trips/goa.mov'));
      expect(lastKnownFolderOf(docs), 'Trips');
      expect(lastKnownFolderOf(videoAsset('md_5', locator: const FileLocator('/a.mov'))), isNull);
    });

    test('row equality and copyWith clear the staged file', () {
      final a = RelinkRow(asset: videoAsset('md_1'), availability: MediaAvailability.missing, usedClips: 1, pick: pickOf('x.mov'), phase: RelinkRowPhase.ready);
      final b = a.copyWith();
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a.copyWith(pick: null).pick, isNull);
      expect(a.copyWith(usedClips: 2), isNot(a));
    });
  });
}
