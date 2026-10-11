// OWNER: CORE-25
//
// create(fromMedia): the settings derivation table (aspect snapped within 1%, frame rate snapped
// to a supported integer rate ≤ 60, base short side 720/1080/2160 by source and capability) and
// the end-to-end create on the real file system with the isolate writer and the media pool
// service (CORE-27), including the player handoff (`findUntouchedProjectFor`).

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_editor_core/ops.dart';
import 'package:danaview_editor_core/store.dart';

import '../media/support/media_fixtures.dart';

MediaProbe _video(int w, int h, double? fps, {int rotation = 0}) => MediaProbe(
      kind: MediaKind.video,
      duration: 4000000,
      hasVideo: true,
      hasAudio: true,
      width: w,
      height: h,
      rotation: rotation,
      nominalFps: fps,
      audioStreams: 1,
    );

void main() {
  group('deriveProjectSettings table', () {
    final rows = <(String, MediaProbe?, bool, AspectRatio, int, int)>[
      ('1080p 29.97', _video(1920, 1080, 29.97), false, AspectRatio.landscape16x9, 1080, 30),
      ('portrait 1080p 30', _video(1080, 1920, 30), false, AspectRatio.portrait9x16, 1080, 30),
      ('4K 59.94 capable', _video(3840, 2160, 59.94), true, AspectRatio.landscape16x9, 2160, 60),
      ('4K 59.94 not capable', _video(3840, 2160, 59.94), false, AspectRatio.landscape16x9, 1080, 60),
      ('720p 25', _video(1280, 720, 25), false, AspectRatio.landscape16x9, 720, 25),
      ('VGA 23.976', _video(640, 480, 23.976), false, AspectRatio.classic4x3, 720, 24),
      ('square 120', _video(1080, 1080, 120), false, AspectRatio.square, 1080, 60),
      ('1088 rows (within 1%)', _video(1920, 1088, 30), false, AspectRatio.landscape16x9, 1080, 30),
      ('ultrawide (not within 1%)', _video(2560, 1080, 24), false, const AspectRatio(64, 27), 1080, 24),
      ('rotated 90', _video(1920, 1080, 30, rotation: 90), false, AspectRatio.portrait9x16, 1080, 30),
      ('1440x1080 50', _video(1440, 1080, 50), false, AspectRatio.classic4x3, 1080, 50),
      ('48 fps', _video(1920, 1080, 48), false, AspectRatio.landscape16x9, 1080, 48),
      ('15 fps → 24', _video(1920, 1080, 15), false, AspectRatio.landscape16x9, 1080, 24),
      ('unknown fps → 30', _video(1920, 1080, null), false, AspectRatio.landscape16x9, 1080, 30),
      ('portrait 720', _video(720, 1280, 30), false, AspectRatio.portrait9x16, 720, 30),
      ('4:5 feed', _video(1080, 1350, 30), false, AspectRatio.portrait4x5, 1080, 30),
      ('extreme panorama clamps', _video(5000, 500, 30), false, const AspectRatio(4, 1), 720, 30),
      ('no video → defaults', null, false, AspectRatio.landscape16x9, 1080, 30),
    ];
    for (final (name, probe, allow, aspect, side, fps) in rows) {
      test(name, () {
        final s = deriveProjectSettings(probe, allow2160: allow);
        expect(s.canvas.aspect, aspect);
        expect(s.canvas.baseShortSide, side);
        expect(s.frameRate, FrameRate(fps, 1));
      });
    }

    test('helpers', () {
      expect(snapFrameRate(59.94), FrameRate.fps60);
      expect(snapFrameRate(240), FrameRate.fps60);
      expect(snapFrameRate(double.nan), FrameRate.fps30);
      expect(snapFrameRate(24.5), FrameRate.fps24);
      expect(baseShortSideFor(720), 720);
      expect(baseShortSideFor(721), 1080);
      expect(baseShortSideFor(2160), 1080);
      expect(baseShortSideFor(2160, allow2160: true), 2160);
      expect(snapAspect(0, 10), AspectRatio.landscape16x9);
    });
  });

  group('create(fromMedia) on disk (isolate writer)', () {
    late MediaWorld w;
    late FileProjectRepository repo;

    Future<MediaProbe> probe(ResolvedMedia m) async {
      final name = p.basename(Uri.parse(m.uri).path);
      if (name.endsWith('.png')) return MediaProbe(kind: MediaKind.image, hasVideo: true, width: 1080, height: 1920);
      if (name.startsWith('uhd')) return _video(3840, 2160, 59.94);
      if (name.endsWith('.mkv')) return MediaProbe(kind: MediaKind.video, editable: false, issues: const ['container_unsupported_ios']);
      return _video(1920, 1080, 25);
    }

    setUp(() {
      w = MediaWorld();
      final service = FileMediaPoolService(access: w.port, probe: probe, roots: w.roots, platform: ImportPlatform.ios, ids: SeededIdGenerator(31), clock: () => when);
      repo = FileProjectRepository(roots: w.roots, media: service, access: w.port, allow2160: true, ids: SeededIdGenerator(32), clock: () => when);
      expect(repo.useIsolates, isTrue);
    });
    tearDown(() async {
      await repo.dispose();
      w.dispose();
    });

    test('derives settings, places media, stays untouched, and is found again for the player', () async {
      final film = w.c.put(p.join(w.roots.documents, 'uhd_film.mp4'), bytesOf(5, 300000));
      final still = w.c.put(p.join(w.roots.documents, 'poster.png'), bytesOf(6, 1000));
      final hash = await w.port.quickHash(FileLocator(film));
      final originals = w.originalsSnapshot();
      final id = await repo.create(FromMediaProjectSpec(
        picks: [
          PickedMedia(uri: Uri.file(film).toString(), displayName: 'uhd_film.mp4', origin: MediaOrigin.library),
          PickedMedia(uri: Uri.file(still).toString(), displayName: 'poster.png', origin: MediaOrigin.library),
        ],
        name: 'From player',
        initialPlayhead: 1234567,
        origin: FromPlayerOrigin(quickHash: hash, sizeBytes: 300000, displayName: 'uhd_film.mp4'),
      ));
      expect(w.originalsSnapshot(), originals, reason: 'originals untouched');
      final loaded = await repo.open(id);
      final pr = loaded.project;
      expect(pr.settings.canvas, const CanvasSpec(aspect: AspectRatio.landscape16x9, baseShortSide: 2160));
      expect(pr.settings.frameRate, FrameRate.fps60);
      expect(pr.view.playhead, FrameRate.fps60.quantize(1234567));
      expect(pr.meta.editCount, 0);
      expect(pr.tracks.firstWhere((t) => t.isMain).items, hasLength(2));
      expect(pr.pool.assets.values.map((a) => a.ownership).toSet(), {MediaOwnership.external});
      expect(pr.pool.assets.values.map((a) => a.locator).whereType<AppRelativeLocator>().map((l) => l.root).toSet(), {AppRoot.documents});
      expect(File(p.join(w.roots.projectDir(id), 'project.dnproj')).existsSync(), isTrue);
      await repo.close(id);
      expect(await repo.findUntouchedProjectFor(film), id);
      expect(await repo.findUntouchedProjectFor(Uri.file(film).toString()), id);

      // An edit makes it "touched".
      final again = await repo.open(id);
      final s = EditSession(again.project, clock: () => when);
      s.apply(const AddMarker(0));
      await repo.save(s, reason: SaveReason.close);
      await repo.close(id);
      expect(await repo.findUntouchedProjectFor(film), isNull);
    });

    test('nothing importable → ProjectCreateFailure and no project', () async {
      final bad = w.c.put(p.join(w.roots.documents, 'movie.mkv'), bytesOf(7, 5000));
      await expectLater(
        repo.create(FromMediaProjectSpec(picks: [PickedMedia(uri: Uri.file(bad).toString(), displayName: 'movie.mkv', origin: MediaOrigin.library)], name: 'X')),
        throwsA(isA<ProjectCreateFailure>().having((f) => (f.outcomes.single as ImportRejected).reason, 'reason', 'containerUnsupportedIos')),
      );
      expect(await repo.summaries(), isEmpty);
    });

    test('the isolate writer and isolate open round-trip a project and survive concurrent saves', () async {
      final id = await repo.create(const EmptyProjectSpec(name: 'Iso'));
      final loaded = await repo.open(id);
      final s = EditSession(loaded.project, clock: () => when);
      final saves = <Future<SaveReceipt>>[];
      for (var k = 0; k < 6; k++) {
        s.apply(AddMarker(FrameRate.fps30.timeOfFrame(k)));
        saves.add(repo.save(s, reason: SaveReason.manual));
        repo.requestAutosave(s);
      }
      final receipts = await Future.wait(saves);
      expect(receipts.last.docRevision, s.project.docRevision);
      await repo.close(id);
      expect((await repo.open(id)).project, s.project);
      expect((await repo.summaries()).single.name, 'Iso');
      final report = await repo.storageReport();
      expect(report.projectCount, 1);
    });
  });
}
