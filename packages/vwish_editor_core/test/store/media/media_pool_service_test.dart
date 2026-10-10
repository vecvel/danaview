// OWNER: CORE-27
//
// FileMediaPoolService.import against a fake platform port: every row of the ARCH §9.1 table,
// dedupe (re-picking reuses the MediaId), temp copies moved only when allowed, the grant-budget
// fallback, LUT/recording/still project files, rejections, sticky pool changes, timeline placement,
// and an fs spy proving originals are never written, renamed or deleted.

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:vwish_editor_core/formats.dart';
import 'package:vwish_editor_core/model.dart';
import 'package:vwish_editor_core/store.dart';

import 'support/media_fixtures.dart';

const _cube = 'TITLE "t"\nLUT_3D_SIZE 2\n0 0 0\n1 0 0\n0 1 0\n1 1 0\n0 0 1\n1 0 1\n0 1 1\n1 1 1\n';

MediaAsset assetOf(ImportOutcome o) {
  expect(o, isA<ImportedMedia>(), reason: '$o');
  return (o as ImportedMedia).asset;
}

String reasonOf(ImportOutcome o) {
  expect(o, isA<ImportRejected>(), reason: '$o');
  return (o as ImportRejected).reason;
}

void main() {
  late MediaWorld w;
  tearDown(() => w.dispose());

  group('ARCH §9.1 table', () {
    test('iOS Photos: the native clone is moved into media/ (managed copy)', () async {
      w = MediaWorld();
      final bytes = bytesOf(1, 200000);
      final clone = w.photosClone('u1', 'IMG_0001.MOV', bytes);
      final out = await w.service.import(w.session, [PickedMedia(uri: Uri.file(clone).toString(), displayName: 'IMG_0001.MOV', origin: MediaOrigin.photos, isTemporaryCopy: true)]);
      final a = assetOf(out.single);
      expect(a.ownership, MediaOwnership.managedCopy);
      expect(a.origin, MediaOrigin.photos);
      expect(a.kind, MediaKind.video);
      final loc = a.locator as AppRelativeLocator;
      expect(loc.root, AppRoot.support);
      expect(loc.relPath, 'vwish/editor/media/${a.fingerprint.quickHash.substring(0, 2)}/${a.fingerprint.quickHash}/IMG_0001.mov');
      expect(File(clone).existsSync(), isFalse, reason: 'moved');
      expect(File(w.pathOf(loc)).readAsBytesSync(), bytes);
      expect(w.fs.log.where((o) => o.kind == FsOpKind.copy), isEmpty, reason: 'a move, not a copy');
      expect(a.fingerprint.sizeBytes, 200000);
      expect(a.fingerprint.duration, 2000000);
      expect(w.port.excluded, containsAll([p.normalize(w.roots.mediaDir), p.normalize(w.roots.derivedDir)]));
    });

    test('iOS Files: a security-scoped bookmark (external, original untouched)', () async {
      w = MediaWorld();
      final file = w.externalFile('Trip.mov', bytesOf(2, 1000));
      final snap = w.originalsSnapshot();
      final out = await w.service.import(w.session, [
        PickedMedia(uri: Uri.file(file).toString(), displayName: 'Trip.mov', bookmark: u8([1, 2, 3, 4])),
      ]);
      final a = assetOf(out.single);
      expect(a.ownership, MediaOwnership.external);
      expect(a.locator, isA<BookmarkLocator>());
      expect((a.locator as BookmarkLocator).lastKnownPath, isNot(contains(w.c.dir.path)), reason: 'no container path persisted');
      expect(w.port.persisted, [Uri.file(file).toString()]);
      expect(w.originalsSnapshot(), snap);
      final media = Directory(w.roots.mediaDir);
      expect(media.existsSync() ? media.listSync() : const <FileSystemEntity>[], isEmpty, reason: 'no copy');
    });

    test('Android Photo Picker / SAF: a persisted grant (external)', () async {
      w = MediaWorld(platform: ImportPlatform.android);
      final uri = w.contentUri('v.mp4', bytesOf(3, 5000));
      final out = await w.service.import(w.session, [PickedMedia(uri: uri, displayName: 'v.mp4', origin: MediaOrigin.photos)]);
      final a = assetOf(out.single);
      expect(a.locator, ContentUriLocator(uri));
      expect(a.ownership, MediaOwnership.external);
      expect(w.port.grantBudget, 499);
      expect(w.materializer.calls, isEmpty);
    });

    test('Android grant-budget fallback: < 32 grants left → managed copy, no grant taken', () async {
      w = MediaWorld(platform: ImportPlatform.android, grantBudget: 31);
      final bytes = bytesOf(4, 5000);
      final uri = w.contentUri('v.mp4', bytes);
      final out = await w.service.import(w.session, [PickedMedia(uri: uri, displayName: 'v.mp4', origin: MediaOrigin.files)]);
      final a = assetOf(out.single);
      expect(a.ownership, MediaOwnership.managedCopy);
      expect(w.port.persisted, isEmpty);
      expect(w.port.grantBudget, 31);
      expect(w.materializer.calls, [uri]);
      expect(File(w.pathOf(a.locator)).readAsBytesSync(), bytes);
      expect(Directory(w.roots.picksDir).listSync(recursive: true).whereType<File>(), isEmpty, reason: 'native copy consumed');
    });

    test('Android budget runs out mid-batch: grants until 32 remain, then copies', () async {
      w = MediaWorld(platform: ImportPlatform.android, grantBudget: 33);
      final uris = [for (var i = 0; i < 3; i++) w.contentUri('v$i.mp4', bytesOf(10 + i, 3000))];
      final out = await w.service.import(w.session, [for (final u in uris) PickedMedia(uri: u, displayName: p.basename(u))]);
      expect([for (final o in out) assetOf(o).ownership],
          [MediaOwnership.external, MediaOwnership.external, MediaOwnership.managedCopy]);
      expect(w.port.grantBudget, 31);
    });

    test('Android URI that is not persistable → managed copy', () async {
      w = MediaWorld(platform: ImportPlatform.android);
      final uri = w.contentUri('n.mp4', bytesOf(5, 3000));
      w.port.notPersistable.add(uri);
      final a = assetOf((await w.service.import(w.session, [PickedMedia(uri: uri, displayName: 'n.mp4')])).single);
      expect(a.ownership, MediaOwnership.managedCopy);
      expect(w.materializer.calls, [uri]);
    });

    test('no platform copier: a URI that needs a copy is rejected (notPersistable)', () async {
      w = MediaWorld(platform: ImportPlatform.android, grantBudget: 0, withMaterializer: false);
      final uri = w.contentUri('n.mp4', bytesOf(5, 3000));
      expect(reasonOf((await w.service.import(w.session, [PickedMedia(uri: uri, displayName: 'n.mp4')])).single), 'notPersistable');
      expect(w.session.project.pool.isEmpty, isTrue);
    });

    for (final platform in ImportPlatform.values) {
      test('player Documents path → AppRelativeLocator(documents) on ${platform.name}', () async {
        w = MediaWorld(platform: platform);
        final file = w.c.put(p.join(w.roots.documents, 'Movies', 'My clip.mp4'), bytesOf(6, 4000));
        final snap = w.originalsSnapshot();
        final a = assetOf((await w.service.import(w.session, [PickedMedia(uri: Uri.file(file).toString(), displayName: 'My clip.mp4', origin: MediaOrigin.player)])).single);
        expect(a.locator, const AppRelativeLocator(AppRoot.documents, 'Movies/My clip.mp4'));
        expect(a.ownership, MediaOwnership.external);
        expect(w.port.persisted, isEmpty);
        expect(w.originalsSnapshot(), snap);
      });
    }

    test('Android incoming cache copy → managed copy (copied; the cache file is not touched)', () async {
      w = MediaWorld(platform: ImportPlatform.android);
      final bytes = bytesOf(7, 150000);
      final incoming = w.c.put(p.join(w.roots.cache, 'incoming', 'shared.mp4'), bytes);
      final snap = w.originalsSnapshot();
      final a = assetOf((await w.service.import(w.session, [PickedMedia(uri: incoming, displayName: 'shared.mp4', origin: MediaOrigin.player, isTemporaryCopy: true)])).single);
      expect(a.ownership, MediaOwnership.managedCopy);
      expect(File(incoming).existsSync(), isTrue, reason: 'outside work/: never moved');
      expect(w.originalsSnapshot(), snap);
      expect(File(w.pathOf(a.locator)).readAsBytesSync(), bytes);
    });

    test('free-space preflight (size + 64 MB) refuses a copy that would not fit', () async {
      w = MediaWorld(platform: ImportPlatform.android, freeSpace: (_) async => ImportPolicy.freeSpaceMarginBytes + 100);
      final incoming = w.c.put(p.join(w.roots.cache, 'incoming', 'big.mp4'), bytesOf(8, 101));
      expect(reasonOf((await w.service.import(w.session, [PickedMedia(uri: incoming, displayName: 'big.mp4', origin: MediaOrigin.player)])).single), 'diskFull');
      final fits = w.c.put(p.join(w.roots.cache, 'incoming', 'ok.mp4'), bytesOf(9, 100));
      expect((await w.service.import(w.session, [PickedMedia(uri: fits, displayName: 'ok.mp4', origin: MediaOrigin.player)])).single, isA<ImportedMedia>());
    });

    test('external drop → managed copy moved out of work/drops', () async {
      w = MediaWorld();
      final drop = w.dropCopy('d1', 'dropped.mp4', bytesOf(10, 2000));
      final a = assetOf((await w.service.import(w.session, [PickedMedia(uri: drop, displayName: 'dropped.mp4', origin: MediaOrigin.drop, isTemporaryCopy: true)])).single);
      expect(a.ownership, MediaOwnership.managedCopy);
      expect(File(drop).existsSync(), isFalse);
    });

    test('Android drop with a temporary URI grant → platform copy, managed', () async {
      w = MediaWorld(platform: ImportPlatform.android);
      final uri = w.contentUri('dropped.mp4', bytesOf(11, 2000));
      final a = assetOf((await w.service.import(w.session, [PickedMedia(uri: uri, displayName: 'dropped.mp4', origin: MediaOrigin.drop)])).single);
      expect(a.ownership, MediaOwnership.managedCopy);
      expect(w.port.persisted, isEmpty, reason: 'a temporary drop grant is never persisted');
    });

    test('LUT → project-owned .cube + .vlut in the bundle (no probe)', () async {
      w = MediaWorld();
      final file = w.externalFile('Teal.cube', u8(_cube.codeUnits));
      probedUris.clear();
      final a = assetOf((await w.service.import(w.session, [PickedMedia(uri: Uri.file(file).toString(), displayName: 'Teal.cube')])).single);
      expect(a.kind, MediaKind.lut);
      expect(a.ownership, MediaOwnership.projectOwned);
      final loc = a.locator as AppRelativeLocator;
      expect(loc.relPath, 'vwish/editor/projects/pr_media00001/assets/luts/${a.id}.cube');
      expect(File(w.pathOf(loc)).readAsStringSync(), _cube);
      final vlut = readVlut(File(w.pathOf(ManagedStore.vlutOf(loc))).readAsBytesSync());
      expect(vlut.size, 2);
      expect(probedUris, isEmpty);
      expect(File(file).existsSync(), isTrue);
    });

    test('an invalid LUT is rejected and leaves nothing behind', () async {
      w = MediaWorld();
      final file = w.externalFile('Bad.cube', u8('LUT_3D_SIZE 2\n0 0 0\n'.codeUnits));
      expect(reasonOf((await w.service.import(w.session, [PickedMedia(uri: file, displayName: 'Bad.cube')])).single), 'lutInvalid');
      expect(Directory(w.roots.projectsDir).existsSync(), isFalse);
    });

    test('voice recording → project-owned recordings/<id>.wav (moved from work/)', () async {
      w = MediaWorld();
      final rec = w.c.put(p.join(w.roots.workDir, 'export-rec1', 'take.wav'), bytesOf(12, 4000));
      final a = assetOf((await w.service.import(w.session, [PickedMedia(uri: rec, displayName: 'Voice 1.wav', origin: MediaOrigin.recorded, isTemporaryCopy: true)])).single);
      expect(a.kind, MediaKind.recording);
      expect(a.probe.kind, MediaKind.recording);
      expect(a.ownership, MediaOwnership.projectOwned);
      expect((a.locator as AppRelativeLocator).relPath, 'vwish/editor/projects/pr_media00001/assets/recordings/${a.id}.wav');
      expect(File(rec).existsSync(), isFalse);
    });

    test('a recording the engine already wrote into the bundle is referenced in place', () async {
      w = MediaWorld();
      final rel = ManagedStore.projectAssetRelPath('pr_media00001', 'recordings', 'rec-x.wav');
      final path = w.c.put(w.roots.resolve(AppRelativeLocator(AppRoot.support, rel)), bytesOf(13, 4000));
      final a = assetOf((await w.service.import(w.session, [PickedMedia(uri: path, displayName: 'Voice 2.wav', origin: MediaOrigin.recorded)])).single);
      expect(a.locator, AppRelativeLocator(AppRoot.support, rel));
      expect(File(path).existsSync(), isTrue);
    });

    test('freeze still → project-owned stills/<id>.png', () async {
      w = MediaWorld();
      final still = w.c.put(p.join(w.roots.workDir, 'export-still', 'f.png'), bytesOf(14, 900));
      final a = assetOf((await w.service.import(w.session, [PickedMedia(uri: still, displayName: 'f.png', origin: MediaOrigin.derived, isTemporaryCopy: true)])).single);
      expect(a.kind, MediaKind.still);
      expect((a.locator as AppRelativeLocator).relPath, endsWith('/assets/stills/${a.id}.png'));
    });

    test('desktop path → FileLocator (external)', () async {
      w = MediaWorld(platform: ImportPlatform.desktop);
      final file = w.externalFile('desk.mov', bytesOf(15, 900));
      final a = assetOf((await w.service.import(w.session, [PickedMedia(uri: file, displayName: 'desk.mov')])).single);
      expect(a.locator, FileLocator(file));
      expect(a.ownership, MediaOwnership.external);
    });
  });

  group('dedupe', () {
    test('re-picking the same Photos item reuses its MediaId and drops the new clone', () async {
      w = MediaWorld();
      final bytes = bytesOf(20, 100000);
      final c1 = w.photosClone('u1', 'IMG.MOV', bytes);
      final first = assetOf((await w.service.import(w.session, [PickedMedia(uri: c1, displayName: 'IMG.MOV', origin: MediaOrigin.photos, isTemporaryCopy: true)])).single);
      final c2 = w.photosClone('u2', 'IMG.MOV', bytes);
      final again = (await w.service.import(w.session, [PickedMedia(uri: c2, displayName: 'IMG.MOV', origin: MediaOrigin.photos, isTemporaryCopy: true)])).single as ImportedMedia;
      expect(again.reused, isTrue);
      expect(again.asset.id, first.id);
      expect(File(c2).existsSync(), isFalse);
      expect(w.session.project.pool.length, 1);
    });

    test('the same Files item picked twice in one batch → one asset', () async {
      w = MediaWorld();
      final file = w.externalFile('a.mov', bytesOf(21, 3000));
      final pick = PickedMedia(uri: file, displayName: 'a.mov');
      final out = await w.service.import(w.session, [pick, pick]);
      expect(assetOf(out[0]).id, assetOf(out[1]).id);
      expect((out[1] as ImportedMedia).reused, isTrue);
      expect(w.port.persisted, hasLength(1));
    });

    test('same content in another project shares the managed copy (new MediaId, no new file)', () async {
      w = MediaWorld();
      final bytes = bytesOf(22, 70000);
      final a1 = assetOf((await w.service.import(w.session, [PickedMedia(uri: w.photosClone('u1', 'a.mov', bytes), displayName: 'a.mov', origin: MediaOrigin.photos)])).single);
      final other = w.newSession(id: 'pr_media00002');
      w.fs.reset();
      final a2 = assetOf((await w.service.import(other, [PickedMedia(uri: w.photosClone('u2', 'b.mov', bytes), displayName: 'b.mov', origin: MediaOrigin.photos)])).single);
      expect(a2.id, isNot(a1.id));
      expect(a2.locator, a1.locator);
      expect(w.fs.log.where((o) => o.kind == FsOpKind.copy || o.kind == FsOpKind.rename), isEmpty);
    });

    test('concurrent imports into one session are serialized (no duplicate asset)', () async {
      w = MediaWorld();
      final file = w.externalFile('a.mov', bytesOf(23, 3000));
      final results = await Future.wait([
        w.service.import(w.session, [PickedMedia(uri: file, displayName: 'a.mov')]),
        w.service.import(w.session, [PickedMedia(uri: file, displayName: 'a.mov')]),
      ]);
      expect(assetOf(results[0].single).id, assetOf(results[1].single).id);
      expect(w.session.project.pool.length, 1);
    });
  });

  group('rejections', () {
    test('probe says not editable (iOS MKV) → issue code', () async {
      w = MediaWorld();
      final f = w.externalFile('a.mkv', bytesOf(30, 100));
      expect(reasonOf((await w.service.import(w.session, [PickedMedia(uri: f, displayName: 'a.mkv')])).single), 'containerUnsupportedIos');
      final g = w.externalFile('b.drm', bytesOf(31, 100));
      expect(reasonOf((await w.service.import(w.session, [PickedMedia(uri: g, displayName: 'b.drm')])).single), 'unsupported');
    });

    test('probe fails → unsupported; nothing copied', () async {
      w = MediaWorld();
      final clone = w.photosClone('u', 'x.xyz', bytesOf(32, 100));
      expect(reasonOf((await w.service.import(w.session, [PickedMedia(uri: clone, displayName: 'x.xyz', origin: MediaOrigin.photos)])).single), 'unsupported');
      expect(Directory(w.roots.mediaDir).existsSync() ? Directory(w.roots.mediaDir).listSync() : const <FileSystemEntity>[], isEmpty);
    });

    test('missing and empty files', () async {
      w = MediaWorld();
      final empty = w.externalFile('e.mov', u8(const []));
      final out = await w.service.import(w.session, [
        PickedMedia(uri: p.join(w.external, 'gone.mov'), displayName: 'gone.mov'),
        PickedMedia(uri: empty, displayName: 'e.mov'),
      ]);
      expect(out.map(reasonOf), ['notFound', 'empty']);
    });

    test('disk full while copying → diskFull; the next import succeeds', () async {
      w = MediaWorld(platform: ImportPlatform.android);
      final incoming = w.c.put(p.join(w.roots.cache, 'incoming', 'a.mp4'), bytesOf(33, 3000));
      w.fs.failWhere((op) => op.kind == FsOpKind.copy, StoreFailureKind.diskFull, times: 1);
      final pick = PickedMedia(uri: incoming, displayName: 'a.mp4', origin: MediaOrigin.player);
      expect(reasonOf((await w.service.import(w.session, [pick])).single), 'diskFull');
      expect(w.service.inFlightQuickHashes, isEmpty);
      expect((await w.service.import(w.session, [pick])).single, isA<ImportedMedia>());
    });

    test('cancellation rejects the remaining items; progress is reported per item', () async {
      w = MediaWorld();
      final files = [for (var i = 0; i < 3; i++) w.externalFile('c$i.mov', bytesOf(40 + i, 500))];
      final progress = <int>[];
      final out = await w.service.import(
        w.session,
        [for (final f in files) PickedMedia(uri: f, displayName: p.basename(f))],
        onProgress: (done, total) => progress.add(done * 10 + total),
        isCancelled: () => progress.isNotEmpty,
      );
      expect(out[0], isA<ImportedMedia>());
      expect(out.skip(1).map(reasonOf), ['cancelled', 'cancelled']);
      expect(progress, [13, 23, 33]);
    });
  });

  group('pool and timeline', () {
    test('imports are sticky pool changes: no history entry, docRevision bumps', () async {
      w = MediaWorld();
      final rev = w.session.project.docRevision;
      await w.service.import(w.session, [PickedMedia(uri: w.externalFile('a.mov', bytesOf(50, 500)), displayName: 'a.mov')]);
      expect(w.session.history.canUndo, isFalse);
      expect(w.session.project.docRevision, rev + 1);
      expect(w.session.project.pool.length, 1);
      expect(w.session.project.pool.assets.values.single.addedAt, when);
    });

    test('with a target the media are placed as one undoable "Add clips"', () async {
      w = MediaWorld();
      final out = await w.service.import(
        w.session,
        [
          PickedMedia(uri: w.externalFile('a.mov', bytesOf(51, 500)), displayName: 'a.mov'),
          PickedMedia(uri: w.externalFile('b.mov', bytesOf(52, 500)), displayName: 'b.mov'),
          PickedMedia(uri: w.externalFile('l.cube', u8(_cube.codeUnits)), displayName: 'l.cube'),
        ],
        target: const ImportTarget(atUs: 0),
      );
      expect(out, everyElement(isA<ImportedMedia>()));
      final main = w.session.project.timeline.tracks.firstWhere((t) => t.isMain);
      expect(main.items, hasLength(2));
      expect(w.session.history.undoLabel, 'Add clips');
      w.session.undo();
      expect(w.session.project.pool.length, 3, reason: 'undo never empties the bin');
    });

    test('asOverlay creates an overlay lane when there is none', () async {
      w = MediaWorld();
      await w.service.import(w.session, [PickedMedia(uri: w.externalFile('p.png', bytesOf(53, 500)), displayName: 'p.png')],
          target: const ImportTarget(atUs: 0, asOverlay: true));
      final overlay = w.session.project.timeline.tracks.where((t) => t.kind == TrackKind.overlay).toList();
      expect(overlay, hasLength(1));
      expect(overlay.single.items, hasLength(1));
    });
  });

  group('originals are never written (fs spy)', () {
    for (final platform in ImportPlatform.values) {
      test('mixed batch on ${platform.name}', () async {
        w = MediaWorld(platform: platform, grantBudget: 33);
        final picks = <PickedMedia>[
          PickedMedia(uri: w.photosClone('u1', 'IMG.MOV', bytesOf(60, 140000)), displayName: 'IMG.MOV', origin: MediaOrigin.photos, isTemporaryCopy: true),
          PickedMedia(uri: w.externalFile('files.mov', bytesOf(61, 90000)), displayName: 'files.mov', bookmark: u8([9, 9])),
          PickedMedia(uri: w.c.put(p.join(w.roots.documents, 'doc.mp4'), bytesOf(62, 3000)), displayName: 'doc.mp4', origin: MediaOrigin.player),
          PickedMedia(uri: w.c.put(p.join(w.roots.cache, 'incoming', 'in.mp4'), bytesOf(63, 3000)), displayName: 'in.mp4', origin: MediaOrigin.player, isTemporaryCopy: true),
          PickedMedia(uri: w.dropCopy('d', 'drop.mp4', bytesOf(64, 3000)), displayName: 'drop.mp4', origin: MediaOrigin.drop, isTemporaryCopy: true),
          PickedMedia(uri: w.externalFile('look.cube', u8(_cube.codeUnits)), displayName: 'look.cube'),
          for (var i = 0; i < 3; i++) PickedMedia(uri: w.contentUri('c$i.mp4', bytesOf(70 + i, 2000)), displayName: 'c$i.mp4'),
          // A "temporary" flag on a user's file must not make it movable.
          PickedMedia(uri: w.externalFile('liar.mov', bytesOf(65, 3000)), displayName: 'liar.mov', origin: MediaOrigin.drop, isTemporaryCopy: true),
        ];
        // A symlink planted in work/picks pointing at a user file.
        final victim = w.externalFile('victim.mov', bytesOf(66, 3000));
        final link = p.join(w.roots.picksDir, 'evil', 'victim.mov');
        Directory(p.dirname(link)).createSync(recursive: true);
        Link(link).createSync(victim);
        picks.add(PickedMedia(uri: link, displayName: 'victim.mov', origin: MediaOrigin.photos, isTemporaryCopy: true));

        final snap = w.originalsSnapshot();
        final out = await w.service.import(w.session, picks);
        expect(out.whereType<ImportedMedia>(), hasLength(picks.length), reason: '$out');
        expect(w.opsOutsideEditorRoots(), isEmpty, reason: '${w.opsOutsideEditorRoots()}');
        expect(w.originalsSnapshot(), snap, reason: 'every file outside the editor roots is byte-identical, same mtime');
        expect(File(victim).existsSync(), isTrue);
        for (final o in out.cast<ImportedMedia>()) {
          if (o.asset.ownership != MediaOwnership.external) {
            final loc = o.asset.locator as AppRelativeLocator;
            expect(w.roots.isInsideEditorRoots(w.pathOf(loc)), isTrue);
          }
        }
      });
    }
  });

  test('the spy itself flags writes and renames outside the editor roots', () async {
    w = MediaWorld();
    final outside = w.externalFile('x.bin', u8([1]));
    await w.fs.writeBytesSynced(p.join(w.external, 'y.bin'), u8([2]));
    await w.fs.rename(outside, p.join(w.external, 'z.bin'));
    expect(w.opsOutsideEditorRoots(), hasLength(2));
  });

  test('iOS player in-place URL → bookmark through the port', () async {
    w = MediaWorld();
    final file = w.externalFile('Inbox clip.mp4', bytesOf(80, 900));
    final a = assetOf((await w.service.import(w.session, [PickedMedia(uri: Uri.file(file).toString(), displayName: 'Inbox clip.mp4', origin: MediaOrigin.player, bookmark: u8([7]))])).single);
    expect(a.locator, isA<BookmarkLocator>());
    expect(a.ownership, MediaOwnership.external);
    expect(a.origin, MediaOrigin.player);
  });

  test('relink APIs delegate to CORE-28 (unsupported until supplied)', () {
    w = MediaWorld();
    expect(() => w.service.watchAvailability(w.session), throwsUnsupportedError);
  });
}
