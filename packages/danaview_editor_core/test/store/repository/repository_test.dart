// OWNER: CORE-25
//
// FileProjectRepository (through InMemoryProjectRepository = the real repository inline over
// FaultInjectingFs(MemoryStoreFs)): every ProjectRepository method, bundle layout, summaries,
// health, rename/duplicate/delete rules and fault handling.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:danaview_editor_core/codec.dart';
import 'package:danaview_editor_core/eval.dart' show validate;
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_editor_core/ops.dart';
import 'package:danaview_editor_core/store.dart';
import 'package:danaview_editor_core/testing.dart';

import 'support/repo_support.dart';

void main() {
  late FakeTimers timers;
  late InMemoryProjectRepository repo;
  StoreRoots roots() => repo.inner.roots;

  setUp(() {
    timers = FakeTimers();
    repo = memRepo(timers);
  });

  group('create / open / save / close', () {
    test('create(empty) writes a bundle that opens with defaults', () async {
      final id = await repo.create(const EmptyProjectSpec(name: '  My film  '));
      final dir = roots().projectDir(id);
      expect(repo.memory.peek(p.join(dir, 'project.dnproj')), isNotNull);
      expect(repo.memory.peek(p.join(dir, 'meta.json')), isNotNull);
      expect(repo.memory.peek(p.join(dir, 'refs.json')), isNotNull);
      final loaded = await repo.open(id);
      expect(loaded.project.name, 'My film');
      expect(loaded.project.settings, const ProjectSettings());
      expect(loaded.project.tracks.single.isMain, isTrue);
      expect(loaded.health, ProjectHealth.ok);
      expect(loaded.readOnly, isFalse);
      expect(loaded.pendingRecovery, isNull);
      expect(loaded.warnings, isEmpty);
    });

    test('names are 1-80 characters after trim', () async {
      expect(() => repo.create(const EmptyProjectSpec(name: '   ')), throwsArgumentError);
      expect(() => repo.create(EmptyProjectSpec(name: 'x' * 81)), throwsArgumentError);
      expect(await repo.create(EmptyProjectSpec(name: 'é' * 80)), isNotNull);
    });

    test('a second open is busy; close releases it', () async {
      final id = await repo.create(const EmptyProjectSpec(name: 'A'));
      await repo.open(id);
      await expectLater(repo.open(id), throwsA(isA<StoreFailure>().having((f) => f.kind, 'kind', StoreFailureKind.busy)));
      await repo.close(id);
      expect((await repo.open(id)).project.id, id);
    });

    test('open of an unknown project is notFound', () async {
      await expectLater(repo.open(const ProjectId('pr_nope00000000')),
          throwsA(isA<StoreFailure>().having((f) => f.kind, 'kind', StoreFailureKind.notFound)));
    });

    test('manual save writes main + meta + refs and reopens identically', () async {
      final id = await repo.seed(smallProject());
      final (_, s) = await openSession(repo, id, timers);
      edit(s);
      final receipt = await repo.save(s, reason: SaveReason.manual);
      expect(receipt.docRevision, s.project.docRevision);
      expect(receipt.saveId, startsWith('sv_'));
      await repo.close(id);
      final again = await repo.open(id);
      expect(again.project, s.project);
      final header = await DnprojFiles(fs: repo.fs).readHeader(mainOf(roots(), id));
      expect(header.saveId, receipt.saveId);
      final meta = ProjectMetaFile.tryDecode(repo.memory.peek(p.join(roots().projectDir(id), 'meta.json'))!)!;
      expect(meta.saveId, receipt.saveId);
      expect(meta.docRevision, s.project.docRevision);
    });

    test('save of a project that is not open fails; flush/close of unknown ids are no-ops', () async {
      final s = EditSession(smallProject());
      await expectLater(repo.save(s, reason: SaveReason.manual), throwsA(isA<StoreFailure>()));
      await repo.flush(const ProjectId('pr_none'));
      await repo.close(const ProjectId('pr_none'));
    });

    test('lifecycle/close saves write the poster; summaries resolve it at runtime', () async {
      final posterRepo = InMemoryProjectRepository(
        ids: SeededIdGenerator(3),
        clock: timers.clock,
        timer: timers.call,
        poster: (_) async => Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xD9]),
      );
      final id = await posterRepo.seed(smallProject());
      final (_, s) = await openSession(posterRepo, id, timers);
      await posterRepo.save(s, reason: SaveReason.manual);
      expect(posterRepo.memory.peek(p.join(posterRepo.inner.roots.projectDir(id), 'poster.jpg')), isNull);
      await posterRepo.save(s, reason: SaveReason.lifecycle);
      expect(posterRepo.memory.peek(p.join(posterRepo.inner.roots.projectDir(id), 'poster.jpg')), isNotNull);
      await posterRepo.close(id);
      final sum = (await posterRepo.summaries()).single;
      expect(sum.thumbnailPath, p.join(posterRepo.inner.roots.projectDir(id), 'poster.jpg'));
      final meta = utf8.decode(posterRepo.memory.peek(p.join(posterRepo.inner.roots.projectDir(id), 'meta.json'))!);
      expect(meta, contains('"poster":"poster.jpg"'));
      expect(meta, isNot(contains('/mem/')));
    });

    test('a failed save surfaces StoreFailure, keeps edits, and the next save retries', () async {
      final id = await repo.seed(smallProject());
      final (_, s) = await openSession(repo, id, timers);
      edit(s);
      repo.fs.failWhere((op) => op.kind == FsOpKind.write, StoreFailureKind.diskFull, times: 1);
      await expectLater(
          repo.save(s, reason: SaveReason.manual), throwsA(isA<StoreFailure>().having((f) => f.kind, 'kind', StoreFailureKind.diskFull)));
      final r = await repo.save(s, reason: SaveReason.manual);
      expect(r.docRevision, s.project.docRevision);
      await repo.close(id);
      expect((await repo.open(id)).project, s.project);
    });

    test('saves of one project are serialized; the latest pending request wins', () async {
      final id = await repo.seed(smallProject());
      final (_, s) = await openSession(repo, id, timers);
      edit(s, 1);
      final a = repo.save(s, reason: SaveReason.manual);
      edit(s, 2);
      final b = repo.save(s, reason: SaveReason.manual);
      edit(s, 3);
      final c = repo.save(s, reason: SaveReason.manual);
      final rs = await Future.wait([a, b, c]);
      // b was superseded by c before it started: it completes with c's receipt.
      expect(rs[1].saveId, rs[2].saveId);
      expect(rs[2].docRevision, s.project.docRevision);
      final writes = repo.fs.log.where((op) => op.kind == FsOpKind.write && op.path.contains('project.dnproj.tmp-')).length;
      expect(writes, 2 + 1); // seed + a + c
    });
  });

  group('summaries', () {
    test('watchSummaries emits the list and every change, newest first', () async {
      final events = <List<ProjectSummary>>[];
      final sub = repo.watchSummaries().listen(events.add);
      await settle();
      expect(events.single, isEmpty);
      final a = await repo.create(const EmptyProjectSpec(name: 'A'));
      timers.now = timers.now.add(const Duration(minutes: 1));
      final b = await repo.create(const EmptyProjectSpec(name: 'B'));
      await settle();
      expect(events.last.map((s) => s.id), [b, a]);
      await repo.rename(a, 'Renamed');
      await settle();
      expect(events.last.firstWhere((s) => s.id == a).name, 'Renamed');
      expect(events.last.first.id, a); // renamed later → newest
      await repo.delete(b);
      await settle();
      expect(events.last.map((s) => s.id), [a]);
      await sub.cancel();
    });

    test('a missing or stale meta.json is rebuilt from the document', () async {
      final id = await repo.seed(smallProject(name: 'Rebuilt'));
      final metaPath = p.join(roots().projectDir(id), 'meta.json');
      await repo.fs.delete(metaPath);
      final fresh = memRepoOver(repo, timers);
      final sum = (await fresh.summaries()).single;
      expect(sum.name, 'Rebuilt');
      expect(sum.health, ProjectHealth.ok);
      expect(fresh.memory.peek(metaPath), isNotNull, reason: 'rebuilt and written back');
      // Stale (saveId differs from the main document): rebuilt too.
      repo.memory.putFile(
          metaPath,
          ProjectMetaFile.of(smallProject(name: 'Old name'), saveId: 'sv_stale').encode());
      final again = memRepoOver(repo, timers);
      expect((await again.summaries()).single.name, 'Rebuilt');
    });

    test('bytesOwned counts the bundle plus managed copies used by that project only', () async {
      final shared = _managedAsset('md_shared', 'aa11', 1000);
      final own = _managedAsset('md_own', 'bb22', 500);
      final p1 = smallProject(id: 'pr_p1', pool: MediaPool({shared.id: shared, own.id: own}), media: 'md_shared');
      final p2 = smallProject(id: 'pr_p2', pool: MediaPool({shared.id: shared}), media: 'md_shared');
      await repo.seed(p1);
      await repo.seed(p2);
      final sums = {for (final s in await repo.summaries()) s.id: s};
      final bundle1 = await _tree(repo, roots().projectDir('pr_p1'));
      final bundle2 = await _tree(repo, roots().projectDir('pr_p2'));
      expect(sums[const ProjectId('pr_p1')]!.bytesOwned, closeTo(bundle1 + 500, 400));
      expect(sums[const ProjectId('pr_p2')]!.bytesOwned, closeTo(bundle2, 400));
    });
  });

  group('rename / duplicate / delete', () {
    test('rename changes the name, refuses open projects and bad names', () async {
      final id = await repo.seed(smallProject());
      await repo.rename(id, '  New  ');
      expect((await repo.open(id)).project.name, 'New');
      await expectLater(repo.rename(id, 'X'), throwsA(isA<StoreFailure>().having((f) => f.kind, 'kind', StoreFailureKind.busy)));
      await repo.close(id);
      expect(() => repo.rename(id, ''), throwsArgumentError);
    });

    test('duplicate names "<name> copy", "<name> copy 2" and shares managed media', () async {
      final managed = _managedAsset('md_m', 'cc33', 2000);
      final id = await repo.seed(smallProject(name: 'Trip', pool: MediaPool({managed.id: managed}), media: 'md_m'));
      final c1 = await repo.duplicate(id);
      final c2 = await repo.duplicate(id);
      final c3 = await repo.duplicate(id, name: 'Custom');
      final names = {for (final s in await repo.summaries()) s.id: s.name};
      expect(names[c1], 'Trip copy');
      expect(names[c2], 'Trip copy 2');
      expect(names[c3], 'Custom');
      final copy = (await repo.open(c1)).project;
      expect(copy.pool[const MediaId('md_m')]!.locator, managed.locator, reason: 'shared, not copied');
      expect(copy.meta.origin, ProjectOrigin.projects);
      expect(repo.memory.filePaths.where((f) => f.contains('/danaview/editor/media/')), isEmpty, reason: 'no new managed files');
    });

    test('duplicate copies project-owned files into the new bundle', () async {
      const pid = 'pr_owner000001';
      final rel = 'danaview/editor/projects/$pid/assets/recordings/md_rec.wav';
      repo.memory.putFile(p.join(roots().support, rel), [1, 2, 3]);
      final rec = asset('md_rec', MediaKind.recording, duration: sec(30), hasAudio: true)
          .copyWith(locator: AppRelativeLocator(AppRoot.support, rel), ownership: MediaOwnership.projectOwned);
      final id = await repo.seed(smallProject(id: pid, pool: MediaPool({...basePool.assets, rec.id: rec})));
      final dup = await repo.duplicate(id);
      final copy = (await repo.open(dup)).project.pool[const MediaId('md_rec')]!;
      final l = copy.locator as AppRelativeLocator;
      expect(l.relPath, 'danaview/editor/projects/$dup/assets/recordings/md_rec.wav');
      expect(repo.memory.peek(p.join(roots().support, l.relPath)), [1, 2, 3]);
    });

    test('delete moves to trash, deletes the bundle only, calls the GC hook', () async {
      final calls = <(ProjectId, ProjectRefs?)>[];
      final r = InMemoryProjectRepository(
        ids: SeededIdGenerator(4),
        clock: timers.clock,
        onProjectDeleted: (id, refs) async => calls.add((id, refs)),
      );
      final docs = p.join(r.inner.roots.documents, 'film.mp4');
      r.memory.putFile(docs, [9, 9, 9]);
      final external = AppRelativeLocator(AppRoot.documents, 'film.mp4');
      final a = asset('md_doc', MediaKind.video, duration: sec(10)).copyWith(locator: external, ownership: MediaOwnership.external);
      final id = await r.seed(smallProject(pool: MediaPool({a.id: a}), media: 'md_doc'));
      await r.open(id);
      await expectLater(r.delete(id), throwsA(isA<StoreFailure>().having((f) => f.kind, 'kind', StoreFailureKind.busy)));
      await r.close(id);
      await r.delete(id);
      expect(r.memory.filePaths.where((f) => f.contains(id)), isEmpty);
      expect(r.memory.peek(docs), [9, 9, 9]);
      expect(r.fs.log.where((op) => op.kind == FsOpKind.delete && op.path.startsWith(r.inner.roots.documents)), isEmpty);
      expect(calls.single.$1, id);
      expect(await r.summaries(), isEmpty);
      await expectLater(r.delete(id), throwsA(isA<StoreFailure>().having((f) => f.kind, 'kind', StoreFailureKind.notFound)));
    });
  });

  group('health', () {
    Future<ProjectId> putDoc(String id, Uint8List document) async {
      repo.memory.putFile(mainOf(roots(), id), document);
      return ProjectId(id);
    }

    Uint8List docWith(EditProject project, {int schema = currentProjectSchema, int minReader = currentProjectMinReader}) =>
        DnprojFormat.build(ProjectJsonCodec().encodeBytes(project),
            app: '9.0.0', savedAt: when, docRevision: project.docRevision, saveId: 'sv_x', schema: schema, minReader: minReader);

    test('readOnlyNewer: opens read-only, saving is refused, summary says so', () async {
      final id = await putDoc('pr_newer', docWith(smallProject(id: 'pr_newer'), schema: 2));
      final loaded = await repo.open(id);
      expect(loaded.health, ProjectHealth.readOnlyNewer);
      expect(loaded.readOnly, isTrue);
      final s = EditSession(loaded.project);
      await expectLater(repo.save(s, reason: SaveReason.manual),
          throwsA(isA<StoreFailure>().having((f) => f.kind, 'kind', StoreFailureKind.newerSchema)));
      repo.requestAutosave(s); // ignored
      await repo.close(id);
      expect((await repo.summaries()).single.health, ProjectHealth.readOnlyNewer);
    });

    test('needsNewerApp: blocked with newerSchema; summary says so', () async {
      final id = await putDoc('pr_block', docWith(smallProject(id: 'pr_block'), schema: 3, minReader: 2));
      await expectLater(repo.open(id), throwsA(isA<StoreFailure>().having((f) => f.kind, 'kind', StoreFailureKind.newerSchema)));
      expect((await repo.summaries()).single.health, ProjectHealth.needsNewerApp);
    });

    test('corrupt: no valid copy → corrupt summary and StoreFailure(corrupt)', () async {
      final id = await putDoc('pr_bad', Uint8List.fromList(utf8.encode('garbage\nmore garbage')));
      await expectLater(repo.open(id), throwsA(isA<StoreFailure>().having((f) => f.kind, 'kind', StoreFailureKind.corrupt)));
      expect((await repo.summaries()).single.health, ProjectHealth.corrupt);
    });

    test('a damaged main falls back to the .bak with a warning', () async {
      final id = await repo.seed(smallProject());
      final (_, s) = await openSession(repo, id, timers);
      edit(s);
      await repo.save(s, reason: SaveReason.manual);
      await repo.close(id);
      final main = mainOf(roots(), id);
      final bytes = repo.memory.peek(main)!;
      bytes[bytes.length - 3] ^= 0x01; // bit flip in the body
      repo.memory.putFile(main, bytes);
      final loaded = await repo.open(id);
      expect(loaded.warnings.map((w) => w.code), contains(restoredFromBackupWarning));
      expect(loaded.project.markers, isEmpty, reason: 'the .bak is the version before the edit');
    });

    test('decode and repair warnings are surfaced', () async {
      // Two overlapping clips on the main lane: repair moves one and warns.
      final broken = EditProject(
        id: const ProjectId('pr_repair'),
        meta: ProjectMeta(name: 'R', createdAt: when, updatedAt: when),
        timeline: Timeline(tracks: [
          lane('tr_main', TrackKind.video, [vclip('it_a', 0, 30), vclip('it_b', 10, 30)], main: true),
        ]),
        pool: basePool,
      );
      final id = await putDoc('pr_repair', docWith(broken));
      final loaded = await repo.open(id);
      expect(loaded.warnings, isNotEmpty);
      expect(validate(loaded.project), isEmpty);
    });
  });

  group('migration', () {
    test('a migrated project opens with migratedFrom, opening never writes, first save backs up the original', () async {
      final fixture = File('test/fixtures/projects/s0/rich.dnproj').readAsBytesSync();
      final id = jsonDecode(utf8.decode(DnprojFormat.parse(fixture).body))['id'] as String;
      final r = InMemoryProjectRepository(ids: SeededIdGenerator(8), clock: timers.clock, timer: timers.call);
      final migrating = FileProjectRepository(
        roots: r.inner.roots,
        fs: r.fs,
        deleter: r.inner.deleter,
        useIsolates: false,
        migrations: testMigrationsS0ToS1(),
        ids: SeededIdGenerator(9),
        clock: timers.clock,
        timer: timers.call,
      );
      r.memory.putFile(mainOf(r.inner.roots, id), fixture);
      final before = r.fs.log.length;
      final loaded = await migrating.open(ProjectId(id));
      expect(loaded.migratedFrom, 0);
      expect(r.fs.log.skip(before), isEmpty, reason: 'opening never writes');
      final s = EditSession(loaded.project, clock: timers.clock);
      edit(s);
      await migrating.save(s, reason: SaveReason.manual);
      final backup = r.memory.peek(p.join(r.inner.roots.projectDir(id), 'backups', 'pre-migration-s0.dnproj'));
      expect(backup, fixture);
      final header = await DnprojFiles(fs: r.fs).readHeader(mainOf(r.inner.roots, id));
      expect(header.schema, currentProjectSchema);
      // A second save does not touch the backup.
      edit(s, 9);
      await migrating.save(s, reason: SaveReason.manual);
      expect(r.memory.peek(p.join(r.inner.roots.projectDir(id), 'backups', 'pre-migration-s0.dnproj')), fixture);
    });
  });

  group('findUntouchedProjectFor / storageReport', () {
    test('player projects match by fingerprint while editCount == 0', () async {
      final access = MemoryMediaAccess(InMemoryProjectRepository.defaultRoots, MemoryStoreFs());
      final r = InMemoryProjectRepository(ids: SeededIdGenerator(2), clock: timers.clock, timer: timers.call, access: access);
      final memAccess = MemoryMediaAccess(r.inner.roots, r.memory);
      final r2 = FileProjectRepository(
          roots: r.inner.roots, fs: r.fs, deleter: r.inner.deleter, useIsolates: false, access: memAccess, ids: SeededIdGenerator(3), clock: timers.clock);
      final film = p.join(r.inner.roots.documents, 'film.mp4');
      final bytes = List<int>.generate(5000, (i) => i % 251);
      r.memory.putFile(film, bytes);
      final origin = FromPlayerOrigin(quickHash: hashOf(bytes), sizeBytes: bytes.length, displayName: 'film.mp4');
      final pr = smallProject(id: 'pr_player');
      final project = pr.copyWith(meta: pr.meta.copyWith(origin: origin));
      await r2.writeNewProject(project);
      expect(await r2.findUntouchedProjectFor(film), const ProjectId('pr_player'));
      expect(await r2.findUntouchedProjectFor('file://$film'), const ProjectId('pr_player'));
      r.memory.putFile(p.join(r.inner.roots.documents, 'other.mp4'), [1, 2, 3]);
      expect(await r2.findUntouchedProjectFor(p.join(r.inner.roots.documents, 'other.mp4')), isNull);
      expect(await r2.findUntouchedProjectFor('/nowhere.mp4'), isNull);
      // Touched → no longer offered.
      final loaded = await r2.open(const ProjectId('pr_player'));
      final s = EditSession(loaded.project, clock: timers.clock);
      edit(s);
      await r2.save(s, reason: SaveReason.manual);
      await r2.close(const ProjectId('pr_player'));
      expect(await r2.findUntouchedProjectFor(film), isNull);
    });

    test('storageReport splits bundles, managed media, derived and cache', () async {
      await repo.seed(smallProject());
      repo.memory.putFile(p.join(roots().mediaDir, 'ab', 'abcd', 'x.mp4'), List.filled(100, 1));
      repo.memory.putFile(p.join(roots().derivedDir, 'spec.mp4'), List.filled(30, 1));
      repo.memory.putFile(p.join(roots().editorCache, 'thumbs', 't.bin'), List.filled(7, 1));
      final report = await repo.storageReport();
      expect(report.projectCount, 1);
      expect(report.managedMediaBytes, 100);
      expect(report.derivedBytes, 30);
      expect(report.cacheBytes, 7);
      expect(report.projectBundlesBytes, greaterThan(0));
    });
  });
}

/// A second repository over the same in-memory files (a fresh app start).
InMemoryProjectRepository memRepoOver(InMemoryProjectRepository r, FakeTimers timers) {
  final next = InMemoryProjectRepository(ids: SeededIdGenerator(99), clock: timers.clock, timer: timers.call);
  for (final f in r.memory.filePaths) {
    next.memory.putFile(f, r.memory.peek(f)!);
  }
  return next;
}

MediaAsset _managedAsset(String id, String hash, int size) => asset(id, MediaKind.video, duration: sec(10), size: size, hash: hash).copyWith(
      locator: AppRelativeLocator(AppRoot.support, 'danaview/editor/media/${hash.substring(0, 2)}/$hash/$id.mp4'),
      ownership: MediaOwnership.managedCopy,
    );

Future<int> _tree(InMemoryProjectRepository r, String dir) async {
  var n = 0;
  for (final f in r.memory.filePaths) {
    if (f.startsWith('$dir/')) n += r.memory.peek(f)!.length;
  }
  return n;
}
