// OWNER: CORE-28
//
// Relink (ARCH §9.3) with a fake platform port: every checkRelink outcome, relink as ONE undoable
// "Relink media" entry (with clamps for a shorter file), "Relink several" (autoMatch: 10 missing
// Photos assets from one 10-item pick, ambiguous picks left unassigned) and findInSameFolder.

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:vwish_editor_core/model.dart';
import 'package:vwish_editor_core/ops.dart';
import 'package:vwish_editor_core/store.dart';

import '../../ops/framework/ops_support.dart' show f, lane, sec, vclip;
import '../media/support/media_fixtures.dart';
import 'availability_test.dart' show hashOfBytes;

/// Probe keyed by file name: `v<ms>[_<w>x<h>].<ext>` video, `a<ms>.wav` audio, `.png` image,
/// `.mkv` not editable, anything else a 2 s 1920×1080 video.
Future<MediaProbe> nameProbe(ResolvedMedia m) async {
  final name = p.basename(Uri.parse(m.uri).path);
  final v = RegExp(r'^v(\d+)(?:_(\d+)x(\d+))?\.').firstMatch(name);
  if (v != null) {
    return MediaProbe(
      kind: MediaKind.video,
      duration: int.parse(v[1]!) * 1000,
      hasVideo: true,
      width: v[2] == null ? 1920 : int.parse(v[2]!),
      height: v[3] == null ? 1080 : int.parse(v[3]!),
    );
  }
  final a = RegExp(r'^a(\d+)\.wav$').firstMatch(name);
  if (a != null) return MediaProbe(kind: MediaKind.audio, duration: int.parse(a[1]!) * 1000, hasAudio: true, audioStreams: 1);
  if (name.endsWith('.png')) return MediaProbe(kind: MediaKind.image, hasVideo: true, width: 1080, height: 1920);
  if (name.endsWith('.mkv')) return MediaProbe(kind: MediaKind.video, editable: false, issues: const ['container_unsupported_ios']);
  return MediaProbe(kind: MediaKind.video, duration: 2000000, hasVideo: true, width: 1920, height: 1080);
}

/// A missing managed-copy asset whose content was [bytes] (or just [hash]).
MediaAsset missingAsset(String id, {List<int>? bytes, String? hash, int durationMs = 5000, String? name}) {
  final h = bytes != null ? hashOfBytes(bytes) : (hash ?? 'f0${id.hashCode.toRadixString(16)}');
  return MediaAsset(
    id: MediaId(id),
    kind: MediaKind.video,
    displayName: name ?? '$id.mov',
    locator: AppRelativeLocator(AppRoot.support, 'vwish/editor/media/${h.substring(0, 2)}/$h/$id.mov'),
    ownership: MediaOwnership.managedCopy,
    fingerprint: MediaFingerprint(sizeBytes: bytes?.length ?? 1000, quickHash: h, duration: durationMs * 1000),
    probe: MediaProbe(kind: MediaKind.video, duration: durationMs * 1000, hasVideo: true, width: 1920, height: 1080),
    origin: MediaOrigin.photos,
    addedAt: when,
  );
}

void main() {
  late MediaWorld w;
  late MediaRelinkService service;

  MediaRelinkService serviceFor(ImportPlatform platform) => MediaRelinkService(
        access: w.port,
        probe: nameProbe,
        roots: w.roots,
        fs: w.fs,
        platform: platform,
        deleter: w.deleter,
        materialize: w.materializer.call,
        clock: () => when,
      );

  setUp(() {
    w = MediaWorld();
    service = serviceFor(ImportPlatform.ios);
  });
  tearDown(() => w.dispose());

  EditSession sessionWith(List<MediaAsset> assets, {List<TimelineItem> items = const []}) => EditSession(
        EditProject(
          id: const ProjectId('pr_media00001'),
          meta: ProjectMeta(name: 'Relink', createdAt: when, updatedAt: when),
          timeline: Timeline(tracks: [lane('tr_main', TrackKind.video, items, main: true)]),
          pool: MediaPool({for (final a in assets) a.id: a}),
        ),
        ids: SeededIdGenerator(5),
        clock: () => when,
      );

  PickedMedia photo(String uuid, String name, List<int> bytes) =>
      PickedMedia(uri: Uri.file(w.photosClone(uuid, name, u8(bytes))).toString(), displayName: name, origin: MediaOrigin.photos, isTemporaryCopy: true);

  PickedMedia file(String name, List<int> bytes) =>
      PickedMedia(uri: Uri.file(w.externalFile(name, u8(bytes))).toString(), displayName: name, origin: MediaOrigin.files);

  group('checkRelink', () {
    test('every outcome', () async {
      final original = bytesOf(1, 3000);
      final s = sessionWith([missingAsset('md_a', bytes: original)]);
      Future<RelinkCheck> check(PickedMedia pick) => service.checkRelink(s, const MediaId('md_a'), pick);

      final exact = await check(file('copy_of_a.mov', original));
      expect(exact, isA<RelinkMatch>().having((m) => m.exactFingerprint, 'exact', isTrue));
      expect(await check(file('v5080.mov', bytesOf(2, 100))), isA<RelinkMatch>().having((m) => m.exactFingerprint, 'exact', isFalse));
      expect(await check(file('v4920.mov', bytesOf(3, 100))), isA<RelinkMatch>());
      expect(
        await check(file('v5200.mov', bytesOf(4, 100))),
        isA<RelinkDurationMismatch>().having((m) => (m.expectedUs, m.actualUs), 'durations', (5000000, 5200000)),
      );
      expect(await check(file('v5000_1280x720.mov', bytesOf(5, 100))), isA<RelinkUnsupported>().having((m) => m.reason, 'reason', 'dimensionsDiffer'));
      expect(await check(file('a5000.wav', bytesOf(6, 100))), isA<RelinkDifferentKind>());
      expect(await check(file('i.png', bytesOf(7, 100))), isA<RelinkDifferentKind>());
      expect(await check(file('x.mkv', bytesOf(8, 100))), isA<RelinkUnsupported>().having((m) => m.reason, 'reason', 'containerUnsupportedIos'));
      expect(
        await check(PickedMedia(uri: Uri.file(p.join(w.external, 'nope.mov')).toString(), displayName: 'nope.mov')),
        isA<RelinkUnsupported>().having((m) => m.reason, 'reason', 'notFound'),
      );
      expect(await service.checkRelink(s, const MediaId('md_zz'), file('v1.mov', [1])), isA<RelinkUnsupported>());
    });
  });

  group('relink', () {
    test('one undoable "Relink media" entry; Photos picks become managed copies, Files picks bookmarks', () async {
      final b1 = bytesOf(11, 4000), b2 = bytesOf(12, 4000);
      final a1 = missingAsset('md_1', bytes: b1), a2 = missingAsset('md_2', bytes: b2);
      final s = sessionWith([a1, a2], items: [vclip('it_1', 0, 30, media: 'md_1'), vclip('it_2', 30, 30, media: 'md_2')]);
      final originals = w.originalsSnapshot();
      final filesPick = file('two.mov', b2).copyWith(bookmark: u8([1, 2, 3]));
      final out = await service.relink(s, {a1.id: photo('u1', 'IMG_1.MOV', b1), a2.id: filesPick});
      expect(out.rejection, isNull);
      expect(s.history.length, 1);
      expect(s.history.undoLabel, 'Relink media');
      final r1 = s.project.pool[a1.id]!, r2 = s.project.pool[a2.id]!;
      expect(r1.ownership, MediaOwnership.managedCopy);
      expect(File(w.pathOf(r1.locator)).readAsBytesSync(), b1);
      expect(r2.locator, isA<BookmarkLocator>());
      expect(r2.ownership, MediaOwnership.external);
      expect(r1.fingerprint.quickHash, a1.fingerprint.quickHash);
      expect(w.opsOutsideEditorRoots(), isEmpty);
      expect(w.originalsSnapshot(), isNot(originals), reason: 'the Photos clone was consumed (moved) from work/picks');
      expect(File(Uri.parse(filesPick.uri).toFilePath()).readAsBytesSync(), b2, reason: 'the Files original is untouched');
      // Undo restores both assets, redo re-applies, in one step each.
      s.undo();
      expect(s.project.pool[a1.id], a1);
      expect(s.project.pool[a2.id], a2);
      s.redo();
      expect(s.project.pool[a1.id], r1);
    });

    test('a shorter file clamps (or removes) clips in the same entry', () async {
      final a = missingAsset('md_s', durationMs: 5000);
      final s = sessionWith([a], items: [
        vclip('it_long', 0, 120, media: 'md_s'), // source 0–4 s
        vclip('it_tail', 120, 15, media: 'md_s', sourceIn: sec(4.5)), // source 4.5–5 s
        vclip('it_fits', 200, 60, media: 'md_s', sourceIn: sec(1), reversed: true), // source 1–3 s
        vclip('it_rev', 300, 90, media: 'md_s', sourceIn: sec(2), reversed: true), // source 2–5 s
      ]);
      final out = await service.relink(s, {a.id: file('v3000.mov', bytesOf(20, 500))});
      expect(out.rejection, isNull);
      expect(s.history.length, 1);
      final items = {for (final i in s.project.tracks.single.items) i.id: i};
      expect(items.keys, unorderedEquals([const ItemId('it_long'), const ItemId('it_fits'), const ItemId('it_rev')]));
      expect(items[const ItemId('it_long')]!.duration, f(90));
      expect(items[const ItemId('it_fits')]!.duration, f(60), reason: 'already inside the new file');
      final rev = items[const ItemId('it_rev')]! as MediaClip;
      expect(rev.duration, f(30), reason: 'a reversed clip loses its head');
      expect(rev.end, f(390));
      expect(rev.sourceIn, sec(2));
      expect(s.project.pool[a.id]!.probe.duration, 3000000);
      s.undo();
      expect(s.project.tracks.single.items, hasLength(4));
      expect(s.project.pool[a.id], a);
    });

    test('a different kind or unusable pick refuses the whole relink', () async {
      final a = missingAsset('md_k');
      final s = sessionWith([a]);
      final before = s.project;
      final out = await service.relink(s, {a.id: file('a5000.wav', bytesOf(21, 100))});
      expect(out.rejection, isA<InvalidValue>());
      expect(s.project, before);
      expect(s.history.length, 0);
      expect((await service.relink(s, {const MediaId('md_none'): file('v1.mov', [1])})).rejection, isA<MediaUnavailable>());
    });
  });

  group('autoMatch ("Relink several")', () {
    test('10 missing Photos assets from one 10-item pick; ambiguous picks stay unassigned', () async {
      final contents = [for (var i = 0; i < 10; i++) bytesOf(100 + i, 2000 + i)];
      final missing = [for (var i = 0; i < 10; i++) missingAsset('md_p$i', bytes: contents[i], durationMs: 1000 + 500 * i)];
      final twinA = missingAsset('md_q1', hash: 'aa00twin1', durationMs: 8000);
      final twinB = missingAsset('md_q2', hash: 'bb00twin2', durationMs: 8000);
      final unique = missingAsset('md_r', hash: 'cc00uniq', durationMs: 9000);
      final s = sessionWith([...missing, twinA, twinB, unique]);
      final picks = [for (var i = 9; i >= 0; i--) photo('pk$i', 'IMG_00$i.MOV', contents[i])];
      final proposals = await service.autoMatch(s, picks);
      expect(proposals, hasLength(10));
      for (final pr in proposals) {
        final i = int.parse(pr.pick.displayName.substring(6, 7));
        expect(pr.media, MediaId('md_p$i'));
        expect(pr.check, isA<RelinkMatch>().having((m) => m.exactFingerprint, 'exact', isTrue));
      }
      // Duration-only matches: two candidates each → unassigned; a unique one → assigned.
      final more = await service.autoMatch(s, [
        file('v8000.mov', bytesOf(200, 100)),
        file('v8010.mov', bytesOf(201, 100)),
        file('v9050.mov', bytesOf(202, 100)),
        file('v12345.mov', bytesOf(203, 100)),
      ]);
      expect(more[0].media, isNull);
      expect(more[0].check, isA<RelinkUnsupported>().having((c) => c.reason, 'reason', 'ambiguous'));
      expect(more[1].media, isNull);
      expect(more[2].media, const MediaId('md_r'));
      expect(more[2].check, isA<RelinkMatch>().having((m) => m.exactFingerprint, 'exact', isFalse));
      expect(more[3].media, isNull);
      expect(more[3].check, isA<RelinkUnsupported>().having((c) => c.reason, 'reason', 'noMatch'));

      // The confirmed list relinks as one undo step.
      final out = await service.relink(s, {for (final pr in proposals) pr.media!: pr.pick});
      expect(out.rejection, isNull);
      expect(s.history.length, 1);
      final report = await service.monitorOf(s).refresh();
      for (final a in missing) {
        expect(report.byMedia[a.id], MediaAvailability.available);
      }
    });
  });

  group('findInSameFolder', () {
    test('finds other missing files next to the anchor in Documents only', () async {
      final bBytes = bytesOf(300, 900);
      final b = missingAsset('md_b', bytes: bBytes, name: 'b.mp4', durationMs: 2000)
          .copyWith(locator: const AppRelativeLocator(AppRoot.documents, 'Old/b.mp4'), ownership: MediaOwnership.external);
      final c = missingAsset('md_c', hash: 'dd00c', name: 'c.mp4', durationMs: 2000)
          .copyWith(locator: const AppRelativeLocator(AppRoot.documents, 'Old/c.mp4'), ownership: MediaOwnership.external);
      final d = missingAsset('md_d', hash: 'ee00d', name: 'd.mp4', durationMs: 2000);
      final s = sessionWith([b, c, d]);
      final dir = p.join(w.roots.documents, 'New');
      final anchor = w.c.put(p.join(dir, 'a.mp4'), bytesOf(301, 50));
      w.c.put(p.join(dir, 'b.mp4'), bBytes);
      w.c.put(p.join(dir, 'c.mp4'), bytesOf(302, 50));
      final found = await service.findInSameFolder(s, PickedMedia(uri: anchor, displayName: 'a.mp4', origin: MediaOrigin.library));
      expect({for (final x in found) x.media: x.check.runtimeType}, {
        const MediaId('md_b'): RelinkMatch,
        const MediaId('md_c'): RelinkMatch,
      });
      // Content URIs, bookmarks and unreadable folders: nothing.
      expect(await service.findInSameFolder(s, const PickedMedia(uri: 'content://x/1', displayName: 'a.mp4')), isEmpty);
      expect(await service.findInSameFolder(s, PickedMedia(uri: anchor, displayName: 'a.mp4', bookmark: u8([1]))), isEmpty);
      final outside = w.externalFile('a.mp4', u8([1]));
      expect(await service.findInSameFolder(s, PickedMedia(uri: outside, displayName: 'a.mp4')), isEmpty);
      // Desktop paths are readable anywhere.
      w.externalFile('d.mp4', bytesOf(303, 40));
      final desktop = serviceFor(ImportPlatform.desktop);
      final onDesktop = await desktop.findInSameFolder(s, PickedMedia(uri: outside, displayName: 'a.mp4'));
      expect(onDesktop.map((x) => x.media), [const MediaId('md_d')]);
    });
  });

  test('FileMediaPoolService forwards to the relink delegate', () async {
    final pool = FileMediaPoolService(access: w.port, probe: nameProbe, roots: w.roots, fs: w.fs, relinker: service);
    final a = missingAsset('md_f');
    final s = sessionWith([a]);
    expect(await pool.checkRelink(s, a.id, file('v5000.mov', bytesOf(400, 10))), isA<RelinkMatch>());
    expect((await pool.watchAvailability(s).first).byMedia[a.id], MediaAvailability.missing);
  });
}
