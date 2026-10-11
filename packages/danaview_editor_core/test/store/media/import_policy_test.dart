// OWNER: CORE-27
//
// ImportPolicy (ARCH §9.1, D-13): every row of the import table, per platform.

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_editor_core/store.dart';

const roots = StoreRoots(support: '/c/support', cache: '/c/cache', documents: '/c/documents');

ImportDecision decide(ImportPlatform platform, PickedMedia picked) => ImportPolicy(platform: platform, roots: roots).decide(picked);

PickedMedia pick(String uri, {MediaOrigin origin = MediaOrigin.files, bool temp = false, String name = 'clip.mov'}) =>
    PickedMedia(uri: uri, displayName: name, origin: origin, isTemporaryCopy: temp);

void main() {
  final picks = p.join(roots.picksDir, 'u1', 'IMG_0001.MOV');
  final drops = p.join(roots.dropsDir, 'u2', 'drop.mp4');

  group('ARCH §9.1 table', () {
    test('iOS Photos (native clone in work/picks) → managed copy, temporary', () {
      final d = decide(ImportPlatform.ios, pick(Uri.file(picks).toString(), origin: MediaOrigin.photos, temp: true));
      expect(d.route, ImportRoute.managedCopy);
      expect(d.temporary, isTrue);
      expect(d.sourcePath, picks);
      expect(d.ownership, MediaOwnership.managedCopy);
    });

    test('iOS Files (open in place) → bookmark, external', () {
      final d = decide(ImportPlatform.ios, pick('file:///private/var/mobile/Library/Mobile%20Documents/x/clip.mov'));
      expect(d.route, ImportRoute.bookmark);
      expect(d.ownership, MediaOwnership.external);
      expect(d.temporary, isFalse);
    });

    test('iOS player in-place URL → bookmark', () {
      expect(decide(ImportPlatform.ios, pick('/private/var/mobile/Inbox/x.mp4', origin: MediaOrigin.player)).route, ImportRoute.bookmark);
    });

    test('Android Photo Picker / SAF content URI → persisted grant', () {
      for (final origin in [MediaOrigin.photos, MediaOrigin.files, MediaOrigin.player]) {
        final d = decide(ImportPlatform.android, pick('content://media/picker/0/1', origin: origin));
        expect(d.route, ImportRoute.persistedGrant, reason: origin.name);
        expect(d.contentUri, 'content://media/picker/0/1');
        expect(d.ownership, MediaOwnership.external);
      }
    });

    test('player Documents path → documents reference on every platform', () {
      for (final platform in ImportPlatform.values) {
        final d = decide(platform, pick(p.join(roots.documents, 'Movies', 'a.mp4'), origin: MediaOrigin.player));
        expect(d.route, ImportRoute.documentsReference, reason: platform.name);
        expect(d.ownership, MediaOwnership.external);
      }
      expect(decide(ImportPlatform.ios, pick(Uri.file(p.join(roots.documents, 'a b.mp4')).toString(), origin: MediaOrigin.library)).route,
          ImportRoute.documentsReference);
    });

    test('Android incoming cache copy → managed copy (copied, not temporary)', () {
      final d = decide(ImportPlatform.android, pick(p.join(roots.cache, 'incoming', 'shared.mp4'), origin: MediaOrigin.player, temp: true));
      expect(d.route, ImportRoute.managedCopy);
      expect(d.temporary, isFalse, reason: 'outside work/: not app-owned editor temp, copy only');
    });

    test('external drop → managed copy (moved from work/drops; dropped URI copied)', () {
      final d = decide(ImportPlatform.ios, pick(drops, origin: MediaOrigin.drop, temp: true));
      expect(d.route, ImportRoute.managedCopy);
      expect(d.temporary, isTrue);
      final u = decide(ImportPlatform.android, pick('content://com.other/drop/1', origin: MediaOrigin.drop));
      expect(u.route, ImportRoute.managedCopy);
      expect(u.contentUri, isNotNull);
    });

    test('LUT → project-owned copy + .vlut', () {
      expect(decide(ImportPlatform.ios, pick('/x/Look.CUBE', name: 'Look.CUBE')).route, ImportRoute.projectLut);
      expect(decide(ImportPlatform.android, pick('content://x/1', origin: MediaOrigin.imported, name: 'look.cube')).route, ImportRoute.projectLut);
      expect(decide(ImportPlatform.ios, pick('/x/a.cube', name: 'a.cube')).ownership, MediaOwnership.projectOwned);
    });

    test('recordings and stills → project-owned', () {
      final rec = decide(ImportPlatform.ios, pick(p.join(roots.workDir, 'rec-1.wav'), origin: MediaOrigin.recorded, temp: true));
      expect(rec.route, ImportRoute.projectRecording);
      expect(rec.temporary, isTrue);
      expect(rec.ownership, MediaOwnership.projectOwned);
      expect(decide(ImportPlatform.android, pick(p.join(roots.workDir, 's.png'), origin: MediaOrigin.derived)).route, ImportRoute.projectStill);
    });

    test('desktop path → file reference', () {
      final d = decide(ImportPlatform.desktop, pick('/Users/me/Movies/a.mov'));
      expect(d.route, ImportRoute.fileReference);
      expect(d.ownership, MediaOwnership.external);
    });
  });

  group('temporary copies', () {
    test('a temp flag outside work/ is not trusted', () {
      final d = decide(ImportPlatform.ios, pick('/c/documents/a.mp4', temp: true, origin: MediaOrigin.drop));
      expect(d.route, ImportRoute.managedCopy);
      expect(d.temporary, isFalse);
    });

    test('anything under work/picks or work/drops is temporary even unflagged', () {
      expect(decide(ImportPlatform.ios, pick(picks, origin: MediaOrigin.photos)).temporary, isTrue);
      expect(decide(ImportPlatform.android, pick(drops, origin: MediaOrigin.files)).temporary, isTrue);
    });

    test('dot-dot escapes from work/picks are normalised away', () {
      final d = decide(ImportPlatform.ios, pick('${roots.picksDir}/../../../../../documents/a.mp4', origin: MediaOrigin.photos, temp: true));
      expect(d.temporary, isFalse);
      expect(d.route, ImportRoute.documentsReference);
    });
  });

  test('grant budget threshold', () {
    expect(ImportPolicy.grantBudgetExhausted(31), isTrue);
    expect(ImportPolicy.grantBudgetExhausted(32), isFalse);
  });

  test('pathOf', () {
    expect(ImportPolicy.pathOf('file:///a/b%20c.mp4'), '/a/b c.mp4');
    expect(ImportPolicy.pathOf('/a/./b/../c.mp4'), '/a/c.mp4');
    expect(ImportPolicy.pathOf('content://x/1'), isNull);
    expect(ImportPolicy.pathOf('https://x/1'), isNull);
  });
}
