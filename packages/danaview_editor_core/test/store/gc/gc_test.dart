// OWNER: CORE-28
//
// Garbage collection (ARCH §9.4): mark (refs.json of every project, journals, open sessions,
// in-flight imports and jobs), sweep of media/ and derived/ after the 24 h grace period, trash,
// grant/bookmark release, the export gate, the scheduler, and a fuzz run proving referenced and
// external files are never deleted.

import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:danaview_editor_core/codec.dart' show ProjectJsonCodec;
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_editor_core/ops.dart';
import 'package:danaview_editor_core/store.dart';
import 'package:danaview_editor_core/testing.dart';

import '../fs/support/harness.dart' show Container;
import '../repository/support/repo_support.dart';

/// A GC test world over an in-memory store.
final class GcWorld {
  GcWorld({this.seed = 1}) : timers = FakeTimers() {
    repo = InMemoryProjectRepository(ids: SeededIdGenerator(seed), clock: timers.clock, timer: timers.call);
    access = MemoryMediaAccess(roots, repo.memory);
  }

  final int seed;
  final FakeTimers timers;
  late final InMemoryProjectRepository repo;
  late final MemoryMediaAccess access;
  bool exporting = false;
  Set<String> inFlight = {};
  Set<String> jobs = {};

  StoreRoots get roots => repo.inner.roots;
  MemoryStoreFs get mem => repo.memory;

  MediaGarbageCollector collector({bool Function()? export}) => MediaGarbageCollector(
        roots: roots,
        fs: repo.fs,
        deleter: repo.inner.deleter,
        access: access,
        openSessions: () => repo.inner.openSessions,
        openProjects: () => repo.inner.openProjects,
        inFlightQuickHashes: () => inFlight,
        inFlightDerived: () => jobs,
        exportInProgress: export ?? () => exporting,
        clock: timers.clock,
      );

  DateTime ago(Duration d) => timers.now.subtract(d);

  /// A managed copy folder `media/<hh>/<hash>/clip.mp4` last modified [age] ago.
  String managed(String hash, {Duration age = const Duration(days: 3), int size = 100}) {
    final dir = p.join(roots.mediaDir, hash.substring(0, 2), hash);
    final file = p.join(dir, 'clip.mp4');
    mem.putFile(file, List.filled(size, 7));
    mem.touch(file, ago(age));
    mem.touch(dir, ago(age));
    return dir;
  }

  /// A derived rendition `derived/<key>.mp4` last modified [age] ago.
  String derived(String key, {Duration age = const Duration(days: 3)}) {
    final f = p.join(roots.derivedDir, '$key.mp4');
    mem.putFile(f, [1, 2, 3]);
    mem.touch(f, ago(age));
    return f;
  }

  bool exists(String path) => mem.peek(path) != null || mem.directoryPaths.contains(path);
}

MediaAsset managedAsset(String id, String hash) => asset(id, MediaKind.video, duration: sec(10), hash: hash, size: 100).copyWith(
      locator: AppRelativeLocator(AppRoot.support, 'danaview/editor/media/${hash.substring(0, 2)}/$hash/clip.mp4'),
      ownership: MediaOwnership.managedCopy,
    );

MediaAsset reversedAsset(String id, String source, String sourceHash) {
  final spec = ReversedSpec(MediaId(source), const TimeRange(0, 1000000), sourceQuickHash: sourceHash);
  return asset(id, MediaKind.video, duration: sec(1), derived: spec).copyWith(
    locator: AppRelativeLocator(AppRoot.support, 'danaview/editor/derived/${spec.specHash}.mp4'),
    ownership: MediaOwnership.projectOwned,
  );
}

EditProject projectWith(String id, List<MediaAsset> assets) => EditProject(
      id: ProjectId(id),
      meta: ProjectMeta(name: id, createdAt: when, updatedAt: when),
      timeline: Timeline(tracks: [lane('tr_main', TrackKind.video, const [], main: true)]),
      pool: MediaPool({for (final a in assets) a.id: a}),
    );

void main() {
  group('mark and sweep', () {
    test('keeps referenced and young files, deletes old unreferenced ones, empties trash', () async {
      final w = GcWorld();
      final used = w.managed('aa0001');
      final old = w.managed('bb0002');
      final young = w.managed('cc0003', age: const Duration(hours: 23));
      final rev = reversedAsset('md_rev', 'md_u', 'aa0001');
      final usedDerived = w.derived(rev.derived!.specHash);
      final oldDerived = w.derived('deadbeef');
      final youngDerived = w.derived('cafe', age: const Duration(hours: 1));
      await w.repo.seed(projectWith('pr_a', [managedAsset('md_u', 'aa0001'), rev]));
      w.mem.putFile(p.join(w.roots.trashDir, 'pr_gone-1', 'project.dnproj'), [1, 2]);

      final report = await w.collector().collect();
      expect(report.skipped, isNull);
      expect(w.exists(used), isTrue);
      expect(w.exists(usedDerived), isTrue);
      expect(w.exists(young), isTrue);
      expect(w.exists(youngDerived), isTrue);
      expect(w.exists(old), isFalse);
      expect(w.exists(oldDerived), isFalse);
      expect(w.mem.filePaths.where((f) => f.contains('/trash/')), isEmpty);
      expect(report.keptForGrace, 2);
      expect(report.deleted, containsAll(['danaview/editor/media/bb/bb0002', 'danaview/editor/derived/deadbeef.mp4']));
      expect(report.freedBytes, greaterThanOrEqualTo(100 + 3 + 2));
    });

    test('open sessions (history included), open projects, in-flight imports and jobs are marked', () async {
      final w = GcWorld();
      final inHistory = w.managed('dd0004');
      final inOpenProject = w.managed('ee0005');
      final importing = w.managed('ff0006');
      final job = w.derived('job1');
      // Session: the asset was removed from the pool (undo could bring it back).
      await w.repo.seed(projectWith('pr_s', [managedAsset('md_h', 'dd0004')]));
      final loaded = await w.repo.open(const ProjectId('pr_s'));
      final s = EditSession(loaded.project);
      expect(s.applyPoolEdit(RemoveAssets({const MediaId('md_h')})).rejection, isNull);
      await w.repo.save(s, reason: SaveReason.manual); // refs.json no longer lists md_h…
      final refs = ProjectRefs.decode(w.mem.peek(p.join(w.roots.projectDir('pr_s'), 'refs.json'))!);
      expect(refs.managed.keys, contains('danaview/editor/media/dd/dd0004'), reason: '…except through the history delta');
      // A second project opened without a session yet.
      await w.repo.seed(projectWith('pr_o', [managedAsset('md_o', 'ee0005')]));
      w.mem.putFile(p.join(w.roots.projectDir('pr_o'), 'refs.json'), ProjectRefs.empty.encode());
      await w.repo.open(const ProjectId('pr_o'));
      w.inFlight = {'ff0006'};
      w.jobs = {'job1'};

      await w.collector().collect();
      expect(w.exists(inHistory), isTrue);
      expect(w.exists(inOpenProject), isTrue);
      expect(w.exists(importing), isTrue);
      expect(w.exists(job), isTrue);
    });

    test('a project without refs.json is read from its document, and its journals count', () async {
      final w = GcWorld();
      final fromDoc = w.managed('aa1111');
      final fromJournal = w.managed('bb2222');
      final project = projectWith('pr_j', [managedAsset('md_d', 'aa1111')]);
      await w.repo.seed(project);
      await w.repo.fs.delete(p.join(w.roots.projectDir('pr_j'), 'refs.json'));
      final withMore = project.copyWith(pool: MediaPool({...project.pool.assets, const MediaId('md_j'): managedAsset('md_j', 'bb2222')}));
      w.mem.putFile(
        p.join(w.roots.projectDir('pr_j'), 'journal', 'a.dnproj'),
        DnprojFormat.build(ProjectJsonCodec().encodeBytes(withMore), app: 't', savedAt: when, docRevision: 9, saveId: 'sv_j'),
      );
      await w.collector().collect();
      expect(w.exists(fromDoc), isTrue);
      expect(w.exists(fromJournal), isTrue);
    });

    test('an unreadable project stops the sweep (nothing is deleted)', () async {
      final w = GcWorld();
      final old = w.managed('cc3333');
      w.mem.putFile(p.join(w.roots.projectDir('pr_bad'), 'project.dnproj'), [1, 2, 3]);
      final report = await w.collector().collect();
      expect(report.skipped, GcSkipReason.unreadableProject);
      expect(w.exists(old), isTrue);
    });

    test('never during an export: skipped at start, stops when an export begins', () async {
      final w = GcWorld();
      final dirs = [for (var i = 0; i < 5; i++) w.managed('a${i}9999')];
      w.exporting = true;
      final skipped = await w.collector().collect();
      expect(skipped.skipped, GcSkipReason.exportInProgress);
      expect(dirs.every(w.exists), isTrue);
      w.exporting = false;
      var deletes = 0;
      final gate = w.collector(export: () => deletes++ >= 2); // the export starts mid-sweep
      final r = await gate.collect();
      expect(r.skipped, GcSkipReason.exportInProgress);
      expect(dirs.where(w.exists).length, greaterThanOrEqualTo(3));
    });

    test('links in media/ are never followed or deleted', () async {
      final c = Container.create();
      addTearDown(c.dispose);
      final doc = c.put(p.join(c.roots.documents, 'mine.mp4'), [1, 2, 3]);
      final shard = p.join(c.roots.mediaDir, 'ab');
      Directory(shard).createSync(recursive: true);
      Link(p.join(shard, 'abcdef')).createSync(c.roots.documents);
      final stale = p.join(c.roots.mediaDir, 'cd', 'cdef01');
      c.put(p.join(stale, 'x.mp4'), [4]);
      final gc = MediaGarbageCollector(roots: c.roots, clock: () => DateTime.now().add(const Duration(hours: 1)), grace: Duration.zero);
      final r = await gc.collect();
      expect(r.skipped, isNull);
      expect(File(doc).readAsBytesSync(), [1, 2, 3]);
      expect(Link(p.join(shard, 'abcdef')).existsSync(), isTrue);
      expect(Directory(stale).existsSync(), isFalse);
    });
  });

  group('grants and bookmarks', () {
    test('released once no project uses them (via the delete hook)', () async {
      final w = GcWorld();
      final grantA = asset('md_g', MediaKind.video, duration: sec(5)).copyWith(locator: const ContentUriLocator('content://a/1'), ownership: MediaOwnership.external);
      final bmA = asset('md_b', MediaKind.video, duration: sec(5)).copyWith(locator: const BookmarkLocator('Ym0x'), ownership: MediaOwnership.external);
      final grantShared = asset('md_s', MediaKind.video, duration: sec(5)).copyWith(locator: const ContentUriLocator('content://a/2'), ownership: MediaOwnership.external);
      final scheduler = GcScheduler(w.collector(), timer: w.timers.call);
      final repo = FileProjectRepository(
        roots: w.roots,
        fs: w.repo.fs,
        deleter: w.repo.inner.deleter,
        useIsolates: false,
        clock: w.timers.clock,
        onProjectDeleted: (id, refs) async => scheduler.projectDeleted(refs),
      );
      await repo.writeNewProject(projectWith('pr_a', [grantA, bmA, grantShared]));
      await repo.writeNewProject(projectWith('pr_b', [grantShared]));
      await repo.delete(const ProjectId('pr_a'));
      expect(w.access.released, containsAll([const ContentUriLocator('content://a/1'), const BookmarkLocator('Ym0x')]));
      expect(w.access.released, isNot(contains(const ContentUriLocator('content://a/2'))));
      // Nothing left to release on the next run.
      w.access.released.clear();
      await scheduler.runNow();
      expect(w.access.released, isEmpty);
      await repo.delete(const ProjectId('pr_b'));
      expect(w.access.released, [const ContentUriLocator('content://a/2')]);
    });

    test('grants seen by an earlier mark are released when their project vanishes', () async {
      final w = GcWorld();
      final g = asset('md_g', MediaKind.video, duration: sec(5)).copyWith(locator: const ContentUriLocator('content://x/9'), ownership: MediaOwnership.external);
      await w.repo.seed(projectWith('pr_x', [g]));
      final gc = w.collector();
      await gc.collect();
      expect(w.access.released, isEmpty);
      await w.repo.fs.delete(w.roots.projectDir('pr_x'), recursive: true);
      final r = await gc.collect();
      expect(r.released, ['content://x/9']);
    });
  });

  group('GcScheduler', () {
    test('runs 30 s after start, on demand, one run at a time', () async {
      final w = GcWorld();
      final old = w.managed('ab0101');
      final s = GcScheduler(w.collector(), timer: w.timers.call);
      s.start();
      await w.timers.elapse(const Duration(seconds: 29));
      expect(w.exists(old), isTrue);
      await w.timers.elapse(const Duration(seconds: 1));
      await settle();
      expect(w.exists(old), isFalse);
      expect(s.history, hasLength(1));
      final both = await Future.wait([s.runNow(), s.runNow()]);
      expect(both, hasLength(2));
      expect(s.history, hasLength(3));
      s.dispose();
      expect((await s.runNow()).skipped, GcSkipReason.busy);
    });
  });

  test('fuzz: referenced, young and external files survive; old unreferenced ones go', () async {
    for (var seed = 1; seed <= 40; seed++) {
      final rnd = Random(seed);
      final w = GcWorld(seed: seed);
      final hashes = [for (var i = 0; i < 16; i++) '${(i * 17 + seed).toRadixString(16).padLeft(2, '0')}f${i.toString().padLeft(3, '0')}x$seed'];
      final ages = {for (final h in hashes) h: Duration(hours: rnd.nextInt(72))};
      for (final h in hashes) {
        w.managed(h, age: ages[h]!);
      }
      final derivedKeys = [for (var i = 0; i < 6; i++) 'spec$seed$i'];
      final dAges = {for (final k in derivedKeys) k: Duration(hours: rnd.nextInt(72))};
      for (final k in derivedKeys) {
        w.derived(k, age: dAges[k]!);
      }
      // External files: Documents and a sibling folder of the roots.
      final externals = [
        p.join(w.roots.documents, 'film$seed.mp4'),
        p.join(w.roots.documents, 'Exports', 'e$seed.mp4'),
        '/mem/elsewhere/x$seed.mov',
      ];
      for (final e in externals) {
        w.mem.putFile(e, [seed]);
      }
      final referenced = <String>{};
      final referencedDerived = <String>{};
      for (var pi = 0; pi < 1 + rnd.nextInt(4); pi++) {
        final assets = <MediaAsset>[];
        for (final h in hashes) {
          if (rnd.nextInt(4) == 0) {
            referenced.add(h);
            assets.add(managedAsset('md_${h}_$pi', h));
          }
        }
        for (final e in externals.take(2)) {
          assets.add(asset('md_e${assets.length}', MediaKind.video, duration: sec(3))
              .copyWith(locator: w.roots.relativize(e), ownership: MediaOwnership.external));
        }
        for (final k in derivedKeys) {
          if (rnd.nextInt(5) == 0) {
            referencedDerived.add(k);
            assets.add(asset('md_d$k', MediaKind.video, duration: sec(1))
                .copyWith(locator: AppRelativeLocator(AppRoot.support, 'danaview/editor/derived/$k.mp4'), ownership: MediaOwnership.projectOwned));
          }
        }
        await w.repo.seed(projectWith('pr_f${seed}_$pi', assets));
      }
      w.inFlight = {if (rnd.nextBool()) hashes[rnd.nextInt(hashes.length)]};
      w.exporting = rnd.nextInt(6) == 0;
      final before = {for (final h in hashes) h: w.exists(p.join(w.roots.mediaDir, h.substring(0, 2), h))};
      final report = await w.collector().collect();
      for (final h in hashes) {
        final dir = p.join(w.roots.mediaDir, h.substring(0, 2), h);
        final keep = w.exporting || referenced.contains(h) || w.inFlight.contains(h) || ages[h]! < const Duration(hours: 24);
        expect(w.exists(dir), keep ? isTrue : isFalse, reason: 'seed $seed $h (export ${w.exporting})');
        expect(before[h], isTrue);
      }
      for (final k in derivedKeys) {
        final keep = w.exporting || referencedDerived.contains(k) || dAges[k]! < const Duration(hours: 24);
        expect(w.exists(p.join(w.roots.derivedDir, '$k.mp4')), keep ? isTrue : isFalse, reason: 'seed $seed $k');
      }
      for (final e in externals) {
        expect(w.mem.peek(e), [seed], reason: 'external $e');
      }
      expect(w.repo.fs.log.where((op) => op.kind == FsOpKind.delete && !w.roots.isInsideEditorRoots(op.path)), isEmpty);
      if (w.exporting) expect(report.skipped, GcSkipReason.exportInProgress);
      for (final s in await w.repo.summaries()) {
        expect((await w.repo.open(s.id)).project.pool.isEmpty, isFalse);
        await w.repo.close(s.id);
      }
    }
  });
}
