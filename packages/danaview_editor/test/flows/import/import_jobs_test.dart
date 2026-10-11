// OWNER: UX-06
//
// The import jobs and the free-space preflight (ux.md §5.3, ARCH §8.4, §9.1, D-13):
// * newProjectImportJob: an empty project with the chosen canvas, items imported one by one,
//   settings derived from the first video (aspect unless fixed, short side, frame rate), visual
//   media on the main lane and audio on a music lane, saved and closed; deleted when cancelled or
//   when nothing could be added.
// * sessionImportJob and createProjectImportJob (Media tool / drops, player's Edit).
// * ImportSpaceCheck: size + 64 MB before any copy, with the real import policy deciding which
//   items are copied.

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_editor/src/editor/flows/import_media_sheet.dart';
import 'package:danaview_editor/src/projects/new_project_sheet.dart';
import 'package:danaview_editor/danaview_editor.dart';
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_editor_core/ops.dart' show EditSession;
import 'package:danaview_editor_core/store.dart';
import 'package:danaview_editor_core/testing.dart';

import '../../support/support.dart';
import 'import_fakes.dart';

const _roots = StoreRoots(support: '/app/support', cache: '/app/cache', documents: '/app/documents');
const _mb = 1024 * 1024;

/// Runs [job] over [picks] and records every report.
Future<(ImportJobResult, List<(int, ImportItemPhase, double?)>)> _run(
  ImportJob job,
  List<PickedMedia> picks, {
  ImportCancellation? cancellation,
  Set<int> copies = const {},
}) async {
  final reports = <(int, ImportItemPhase, double?)>[];
  final result = await job(ImportRun(
    picks: picks,
    copies: copies,
    cancellation: cancellation,
    onReport: (i, phase, fraction) => reports.add((i, phase, fraction)),
  ));
  return (result, reports);
}

class _GatedRepository extends FakeProjectRepository {
  final Completer<void> gate = Completer<void>();

  @override
  Future<ProjectId> create(NewProjectSpec spec) async {
    await gate.future;
    return super.create(spec);
  }
}

void main() {
  group('newProjectImportJob', () {
    test('Auto derives the canvas and frame rate from the first video and places every kind', () async {
      final repo = FakeProjectRepository();
      final pool = ScriptedPool()
        ..steps['portrait.mp4'] = const AddStep(width: 1080, height: 1920, fps: 25)
        ..steps['photo.jpg'] = const AddStep(kind: MediaKind.image, width: 4000, height: 3000)
        ..steps['song.mp3'] = const AddStep(kind: MediaKind.audio);
      final picks = [pickOf('portrait.mp4'), pickOf('photo.jpg'), pickOf('song.mp3')];
      final (result, reports) = await _run(
        newProjectImportJob(repository: repo, pool: pool, name: 'Goa trip', format: NewProjectFormat.auto),
        picks,
        copies: {0},
      );

      expect(result.allAdded, isTrue);
      final id = result.projectId!;
      final project = repo.projects[id]!;
      expect(project.name, 'Goa trip');
      expect(project.settings.canvas.aspect, AspectRatio.portrait9x16);
      expect(project.settings.canvas.baseShortSide, 1080);
      expect(project.settings.frameRate, FrameRate.fps25);
      expect(project.pool.assets, hasLength(3));
      final video = project.timeline.tracks.where((t) => t.kind == TrackKind.video).toList();
      expect(video.single.items, hasLength(2));
      final audio = project.timeline.tracks.where((t) => t.kind == TrackKind.audio).toList();
      expect(audio.single.items, hasLength(1));
      expect(audio.single.audioRole, AudioRole.music);
      // Created empty with no fixed canvas, saved, closed.
      expect(repo.createdSpecs.single, isA<EmptyProjectSpec>().having((s) => s.canvas, 'canvas', isNull));
      expect(repo.calls, containsAllInOrder(['create', 'open:$id', 'save', 'close:$id']));
      expect(repo.openProjects, isEmpty);
      // Per-item progress: copying for the copied item, checking for the others, then done.
      expect(reports.where((r) => r.$1 == 0).map((r) => r.$2), [ImportItemPhase.copying, ImportItemPhase.done]);
      expect(reports.where((r) => r.$1 == 1).map((r) => r.$2), [ImportItemPhase.checking, ImportItemPhase.done]);
    });

    test('a fixed format wins over the first video', () async {
      final repo = FakeProjectRepository();
      final pool = ScriptedPool();
      final (result, _) = await _run(
        newProjectImportJob(repository: repo, pool: pool, name: 'Square', format: NewProjectFormat.square),
        [pickOf('wide.mp4')],
      );
      final project = repo.projects[result.projectId]!;
      expect(project.settings.canvas.aspect, AspectRatio.square);
      expect((repo.createdSpecs.single as EmptyProjectSpec).canvas?.aspect, AspectRatio.square);
      expect(project.settings.frameRate, FrameRate.fps30);
    });

    test('items that fail are reported and the rest make the project', () async {
      final repo = FakeProjectRepository();
      final pool = ScriptedPool()..steps['clip.mkv'] = const RejectStep('containerUnsupportedIos');
      final (result, _) = await _run(
        newProjectImportJob(repository: repo, pool: pool, name: 'Mixed', format: NewProjectFormat.auto),
        [pickOf('a.mp4'), pickOf('clip.mkv'), pickOf('b.mp4')],
      );
      expect(result.projectId, isNotNull);
      expect(result.addedCount, 2);
      expect(result.items[1].phase, ImportItemPhase.failed);
      expect(result.items[1].reason, 'containerUnsupportedIos');
      expect(repo.projects[result.projectId]!.pool.assets, hasLength(2));
    });

    test('nothing added: the project is deleted and no id is returned', () async {
      final repo = FakeProjectRepository();
      final pool = ScriptedPool()
        ..steps['a.avi'] = const RejectStep('unsupported')
        ..steps['b.webm'] = const RejectStep('accessDenied');
      final (result, _) = await _run(
        newProjectImportJob(repository: repo, pool: pool, name: 'None', format: NewProjectFormat.auto),
        [pickOf('a.avi'), pickOf('b.webm')],
      );
      expect(result.projectId, isNull);
      expect(result.failedCount, 2);
      expect(repo.projects, isEmpty);
      expect(repo.calls.where((c) => c.startsWith('delete:')), hasLength(1));
    });

    test('cancel mid-copy: the partial copy is deleted, later items are skipped and the project is deleted', () async {
      final repo = FakeProjectRepository();
      final fs = MemoryStoreFs();
      final copy = CopyStep(fraction: 0.4);
      final pool = ScriptedPool(fs: fs)..steps['big.mov'] = copy;
      final cancellation = ImportCancellation();
      final picks = [pickOf('first.mp4'), pickOf('big.mov', size: 500 * _mb), pickOf('later.mp4')];
      final running = _run(
        newProjectImportJob(repository: repo, pool: pool, name: 'Cancelled', format: NewProjectFormat.auto),
        picks,
        cancellation: cancellation,
        copies: {1},
      );
      await copy.started.future;
      expect(fs.filePaths.where((f) => f.endsWith('.part-1')), hasLength(1));
      cancellation.cancel();
      final (result, reports) = await running;

      expect(fs.filePaths, isEmpty, reason: 'the partial copy is deleted');
      expect(pool.imported, ['first.mp4', 'big.mov'], reason: 'nothing is imported after the cancel');
      expect(result.projectId, isNull);
      expect(result.items.map((i) => i.phase), everyElement(ImportItemPhase.cancelled));
      expect(repo.projects, isEmpty);
      expect(reports, contains((1, ImportItemPhase.copying, 0.4)));
      expect(pool.cancellableCalls, 2);
    });

    test('a failing step deletes the half-made project and rethrows', () async {
      final repo = FakeProjectRepository()..failNext['save'] = const StoreFailure(StoreFailureKind.diskFull);
      final pool = ScriptedPool();
      await expectLater(
        _run(newProjectImportJob(repository: repo, pool: pool, name: 'Fails', format: NewProjectFormat.auto), [pickOf('a.mp4')]),
        throwsA(isA<StoreFailure>()),
      );
      expect(repo.projects, isEmpty);
      expect(repo.openProjects, isEmpty);
    });

    test('a pool without cancellation support is still stopped between items', () async {
      final repo = FakeProjectRepository();
      final pool = PlainScriptedPool();
      final cancellation = ImportCancellation();
      final job = newProjectImportJob(repository: repo, pool: pool, name: 'Plain', format: NewProjectFormat.auto);
      final result = await job(ImportRun(
        picks: [pickOf('a.mp4'), pickOf('b.mp4')],
        cancellation: cancellation,
        onReport: (i, phase, _) {
          if (i == 0 && phase == ImportItemPhase.done) cancellation.cancel();
        },
      ));
      expect(pool.calls.where((c) => c == 'import'), hasLength(1));
      expect(result.cancelled, isTrue);
      expect(repo.projects, isEmpty);
    });

    test('NewProjectFormat maps the editor preference and labels every ratio', () {
      expect(NewProjectFormat.fromPreference(NewProjectAspect.matchFirstClip), NewProjectFormat.auto);
      expect(NewProjectFormat.fromPreference(NewProjectAspect.portrait4x5), NewProjectFormat.portrait4x5);
      expect([for (final f in NewProjectFormat.values) f.label], ['Auto', '16:9', '9:16', '1:1', '4:5', '4:3', '21:9']);
    });
  });

  group('sessionImportJob', () {
    test('imports into the session, keeps what was added before a cancel and hands placement over', () async {
      final session = EditSession(FakeProjectRepository().seedEmpty('Open'));
      final pool = ScriptedPool();
      final cancellation = ImportCancellation();
      List<ImportOutcome>? placed;
      final job = sessionImportJob(pool: pool, session: session, place: (outcomes) => placed = outcomes);
      final result = await job(ImportRun(
        picks: [pickOf('a.mp4'), pickOf('b.mp4'), pickOf('c.mp4')],
        cancellation: cancellation,
        onReport: (i, phase, _) {
          if (i == 1 && phase == ImportItemPhase.done) cancellation.cancel();
        },
      ));
      expect(result.addedCount, 2);
      expect(result.items[2].phase, ImportItemPhase.cancelled);
      expect(session.project.pool.assets, hasLength(2));
      expect(placed, hasLength(2));
      expect(result.projectId, isNull);
    });
  });

  group('createProjectImportJob', () {
    test('creates through create(fromMedia) and reports every item added', () async {
      final repo = FakeProjectRepository();
      final picks = [pickOf('movie.mp4', origin: MediaOrigin.player)];
      final (result, reports) = await _run(
        createProjectImportJob(repository: repo, spec: FromMediaProjectSpec(picks: picks, name: 'movie', initialPlayhead: 2000000)),
        picks,
        copies: {0},
      );
      expect(result.projectId, isNotNull);
      expect(result.allAdded, isTrue);
      expect(reports.map((r) => r.$2), [ImportItemPhase.copying, ImportItemPhase.done]);
      expect(repo.createdSpecs.single, isA<FromMediaProjectSpec>());
    });

    test('maps ProjectCreateFailure to per-item errors', () async {
      final picks = [pickOf('a.mkv'), pickOf('b.avi')];
      final repo = FakeProjectRepository()
        ..failNext['create'] =
            ProjectCreateFailure([ImportRejected(picks[0], 'containerUnsupportedIos'), ImportRejected(picks[1], 'diskFull')]);
      final (result, _) = await _run(createProjectImportJob(repository: repo, spec: FromMediaProjectSpec(picks: picks, name: 'x')), picks);
      expect(result.projectId, isNull);
      expect([for (final i in result.items) i.reason], ['containerUnsupportedIos', 'diskFull']);
    });

    test('a cancel while creating deletes the created project', () async {
      final repo = _GatedRepository();
      final picks = [pickOf('movie.mp4')];
      final cancellation = ImportCancellation();
      final running = _run(
        createProjectImportJob(repository: repo, spec: FromMediaProjectSpec(picks: picks, name: 'x')),
        picks,
        cancellation: cancellation,
      );
      cancellation.cancel();
      repo.gate.complete();
      final (result, _) = await running;
      expect(result.cancelled, isTrue);
      expect(result.projectId, isNull);
      expect(repo.projects, isEmpty);
    });
  });

  group('ImportSpaceCheck', () {
    test('needs the copies plus 64 MB to be free', () async {
      var free = 300 * _mb;
      final check = ImportSpaceCheck(freeBytes: () async => free, needsCopy: (p) async => p.origin == MediaOrigin.drop);
      final picks = [
        pickOf('drop.mov', origin: MediaOrigin.drop, size: 200 * _mb),
        pickOf('files.mp4', size: 900 * _mb),
        pickOf('drop2.mov', origin: MediaOrigin.drop, size: 30 * _mb),
      ];
      var verdict = await check.check(picks);
      expect(verdict.copies, {0, 2});
      expect(verdict.neededBytes, 230 * _mb);
      expect(verdict.fits, isTrue);

      free = 293 * _mb; // 230 + 64 = 294 needed
      verdict = await check.check(picks);
      expect(verdict.fits, isFalse);
      expect(verdict.freeBytes, 293 * _mb);
    });

    test('nothing to copy, unknown sizes or an unknown free space never refuse', () async {
      var probed = 0;
      final check = ImportSpaceCheck(
        freeBytes: () async {
          probed++;
          throw StateError('statfs failed');
        },
        needsCopy: (p) async => true,
      );
      expect((await check.check([pickOf('a.mov')])).fits, isTrue);
      expect(probed, 0, reason: 'no known size: no probe');
      expect((await check.check([pickOf('a.mov', size: 10)])).fits, isTrue);
      expect(probed, 1);
    });

    test('likelyCopied: drops that are not temporary copies', () {
      expect(ImportSpaceCheck.likelyCopied(pickOf('a', origin: MediaOrigin.drop)), isTrue);
      expect(ImportSpaceCheck.likelyCopied(pickOf('a', origin: MediaOrigin.drop, temporary: true)), isFalse);
      expect(ImportSpaceCheck.likelyCopied(pickOf('a', origin: MediaOrigin.photos)), isFalse);
    });

    test('copiedBy follows the real import policy (D-13)', () async {
      FileMediaPoolService pool(ImportPlatform platform, {int grants = 1000}) => FileMediaPoolService(
            access: DartIoMediaAccess(_roots, grantBudget: grants),
            probe: (_) async => MediaProbe(kind: MediaKind.video),
            roots: _roots,
            fs: MemoryStoreFs(),
            platform: platform,
          );
      final ios = pool(ImportPlatform.ios);
      final android = pool(ImportPlatform.android);
      final photosClone =
          PickedMedia(uri: '${_roots.picksDir}/x/clip.mov', displayName: 'clip.mov', origin: MediaOrigin.photos, isTemporaryCopy: true);
      final filesPick = const PickedMedia(uri: 'file:///private/var/mobile/Downloads/clip.mov', displayName: 'clip.mov');
      final playerCache =
          const PickedMedia(uri: '/data/user/0/app/cache/incoming/clip.mp4', displayName: 'clip.mp4', origin: MediaOrigin.player);
      final grant = const PickedMedia(uri: 'content://media/external/video/1', displayName: 'clip.mp4', origin: MediaOrigin.photos);
      final library = PickedMedia(uri: '${_roots.documents}/Imported/clip.mp4', displayName: 'clip.mp4', origin: MediaOrigin.library);

      expect(await ImportSpaceCheck.copiedBy(ios, photosClone), isFalse, reason: 'moved, not copied');
      expect(await ImportSpaceCheck.copiedBy(ios, filesPick), isFalse, reason: 'bookmark');
      expect(await ImportSpaceCheck.copiedBy(ios, library), isFalse, reason: 'Documents reference');
      expect(await ImportSpaceCheck.copiedBy(android, playerCache), isTrue, reason: 'Android incoming cache copy');
      expect(await ImportSpaceCheck.copiedBy(android, grant), isFalse, reason: 'persisted grant');
      expect(await ImportSpaceCheck.copiedBy(pool(ImportPlatform.android, grants: 3), grant), isTrue, reason: 'grant budget exhausted');
    });

    test('the provider uses the engine free space and the pool policy guess for other pools', () async {
      final h = EditorTestHarness();
      h.engine.freeBytesValue = 1234;
      final c = ProviderContainer(overrides: h.overrides);
      addTearDown(c.dispose);
      final check = c.read(importSpaceCheckProvider);
      expect(await check.freeBytes(), 1234);
      expect(await check.needsCopy(pickOf('a', origin: MediaOrigin.drop)), isTrue);
      expect(await check.needsCopy(pickOf('a', origin: MediaOrigin.photos, temporary: true)), isFalse);
    });
  });

  test('ImportItemResult maps pool outcomes', () {
    final p = pickOf('a.mp4');
    final asset = assetFor(p);
    expect(ImportItemResult.of(ImportedMedia(p, asset, reused: true)).asset, asset);
    expect(ImportItemResult.of(ImportedMedia(p, asset)).added, isTrue);
    expect(ImportItemResult.of(ImportRejected(p, 'cancelled')).phase, ImportItemPhase.cancelled);
    expect(ImportItemResult.of(ImportRejected(p, 'diskFull')).reason, 'diskFull');
  });
}
