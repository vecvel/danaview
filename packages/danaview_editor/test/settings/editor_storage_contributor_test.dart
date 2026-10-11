// OWNER: UX-04
//
// The editor's Settings › Storage contributors (ARCH §17.10, ux.md §4.8):
// * "Video editor projects": bytes and count from `storageReport`, re-measured when the project
//   list changes; no clear action; opens Projects.
// * "Editor cache": "Clear editor cache" empties only thumbs/waves/proxies/sprites/looks under
//   `<cache>/danaview/editor`. The core test double (`FaultInjectingFs` over `MemoryStoreFs`) records
//   every mutating step, so the tests assert that no delete ever touches project bundles, managed
//   media, `work/`, the speech tree or Documents. Clearing is blocked while a project is open or a
//   job runs.

import 'package:flutter/material.dart' show Icons;
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_editor/src/app/strings/settings_strings.dart';
import 'package:danaview_editor/danaview_editor.dart';
import 'package:danaview_editor_core/store.dart';
import 'package:danaview_editor_core/testing.dart';
import 'package:danaview_editor_engine_api/testing.dart';
import 'package:danaview_editor_engine_api/danaview_editor_engine_api.dart';
import 'package:danaview_features/storage.dart';
import 'package:danaview_transcription/danaview_transcription.dart';

import '../support/support.dart';

const _roots = StoreRoots(support: '/app/support', cache: '/app/cache', documents: '/app/documents');

/// Files outside the clearable cache folders: none of them may ever be deleted.
const _kept = <String, int>{
  '/app/support/danaview/editor/projects/p1/main.dnproj': 900,
  '/app/support/danaview/editor/projects/p1/assets/recordings/r.wav': 400,
  '/app/support/danaview/editor/media/ab/abcd/clip.mp4': 5000,
  '/app/support/danaview/editor/derived/rev/rev.mp4': 700,
  '/app/support/danaview/speech/models/base.bin': 3000,
  '/app/cache/danaview/editor/work/picks/x/picked.mov': 800,
  '/app/cache/danaview/editor/work/export-1/out.mp4': 600,
  '/app/cache/danaview/editor/engine/state.bin': 30,
  '/app/cache/other/app.tmp': 20,
  '/app/documents/Imported/holiday.mp4': 8000,
};

/// The regenerable cache files (1165 bytes).
const _cache = <String, int>{
  '/app/cache/danaview/editor/thumbs/m1/strip-0.jpg': 100,
  '/app/cache/danaview/editor/waves/m1/peaks.bin': 50,
  '/app/cache/danaview/editor/proxies/m1/proxy.mp4': 1000,
  '/app/cache/danaview/editor/sprites/t1.vsprite': 10,
  '/app/cache/danaview/editor/looks/warm.png': 5,
};

({FaultInjectingFs fs, MemoryStoreFs memory}) _world() {
  final memory = MemoryStoreFs();
  for (final entry in {..._kept, ..._cache}.entries) {
    memory.putFile(entry.key, List<int>.filled(entry.value, 7));
  }
  return (fs: FaultInjectingFs(memory), memory: memory);
}

/// A transcription service whose only answer is that a job is running.
final class _BusyTranscription implements TranscriptionService {
  @override
  TranscriptionJob? get activeJob => _RunningJob();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _RunningJob implements TranscriptionJob {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _IdleTranscription implements TranscriptionService {
  @override
  TranscriptionJob? get activeJob => null;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  group('EditorCacheCleaner', () {
    test('measures only the regenerable cache folders', () async {
      final w = _world();
      final cleaner = EditorCacheCleaner(roots: _roots, fs: w.fs);
      expect(cleaner.paths, [
        for (final f in ['thumbs', 'waves', 'proxies', 'sprites', 'looks']) '/app/cache/danaview/editor/$f',
      ]);
      expect(await cleaner.measure(), 1165);
    });

    test('clearing deletes only cache entries: projects, media, work, speech and Documents stay', () async {
      final w = _world();
      final order = <String>[];
      final cleaner = EditorCacheCleaner(roots: _roots, fs: w.fs, trimEngine: () async => order.add('trim'));
      w.fs.reset();

      final freed = await cleaner.clear();

      expect(freed, 1165);
      final deletes = [
        for (final op in w.fs.log)
          if (op.kind == FsOpKind.delete) op.path
      ];
      expect(deletes, isNotEmpty);
      for (final path in deletes) {
        expect(cleaner.paths.any((folder) => path.startsWith('$folder/')), isTrue, reason: 'deleted $path');
      }
      // No other mutating step (write, copy, rename) happened.
      expect(w.fs.log.where((op) => op.kind != FsOpKind.delete), isEmpty);
      for (final path in _kept.keys) {
        expect(w.memory.filePaths, contains(path), reason: '$path must survive Clear editor cache');
      }
      for (final path in _cache.keys) {
        expect(w.memory.filePaths, isNot(contains(path)));
      }
      // The folders themselves stay so the engine can keep writing into them.
      for (final folder in cleaner.paths) {
        expect((await w.fs.stat(folder)).type, StoreEntityType.directory);
      }
      expect(order, ['trim']);
      expect(await cleaner.measure(), 0);
    });

    test('the engine is asked to drop its caches before files go, and a failing trim does not stop the clean-up', () async {
      final w = _world();
      var deletesWhenTrimmed = -1;
      final cleaner = EditorCacheCleaner(
        roots: _roots,
        fs: w.fs,
        trimEngine: () async {
          deletesWhenTrimmed = w.fs.log.where((op) => op.kind == FsOpKind.delete).length;
          throw StateError('engine gone');
        },
      );
      w.fs.reset();
      expect(await cleaner.clear(), 1165);
      expect(deletesWhenTrimmed, 0);
    });

    test('an entry that cannot be deleted is left in place and the rest is cleared', () async {
      final w = _world();
      final cleaner = EditorCacheCleaner(roots: _roots, fs: w.fs);
      w.fs.failWhere((op) => op.kind == FsOpKind.delete && op.path.contains('/proxies/'), StoreFailureKind.permissionDenied);
      final freed = await cleaner.clear();
      expect(freed, 165);
      expect(w.memory.filePaths, contains('/app/cache/danaview/editor/proxies/m1/proxy.mp4'));
      expect(w.memory.filePaths, isNot(contains('/app/cache/danaview/editor/thumbs/m1/strip-0.jpg')));
    });

    test('missing cache folders measure as empty and clear without errors', () async {
      final fs = FaultInjectingFs(MemoryStoreFs());
      final cleaner = EditorCacheCleaner(roots: _roots, fs: fs);
      expect(await cleaner.measure(), 0);
      expect(await cleaner.clear(), 0);
      expect(fs.log, isEmpty);
    });
  });

  group('EditorCacheStorageContributor', () {
    test('is the "Editor cache" row of the Video editor section and owns the whole editor cache folder', () {
      final contributor = EditorCacheStorageContributor(
        cleaner: EditorCacheCleaner(roots: _roots, fs: _world().fs),
        cacheUse: () async => EditorCacheUse.none,
      );
      expect(contributor.id, 'editor.cache');
      expect(contributor.section, 'Video editor');
      expect(contributor.title, 'Editor cache');
      expect(contributor.ownedPaths, {'/app/cache/danaview/editor'});
      expect(contributor.openAction, isNull);
      final action = contributor.clearAction;
      expect(action.label, 'Clear editor cache');
      expect(action.confirmMessage, contains('Your projects and media stay'));
      expect(action.destructive, isFalse);
    });

    test('clearing frees the cache and the usage is measured again', () async {
      final w = _world();
      final contributor = EditorCacheStorageContributor(
        cleaner: EditorCacheCleaner(roots: _roots, fs: w.fs),
        cacheUse: () async => EditorCacheUse.none,
      );
      final seen = <StorageContributorUsage>[];
      final sub = contributor.watchUsage().listen(seen.add);
      await pumpEventQueue();
      expect(seen, [const StorageContributorUsage(bytes: 1165)]);

      final outcome = await contributor.clearAction.run();
      expect(outcome.done, isTrue);
      expect(outcome.freedBytes, 1165);
      await pumpEventQueue();
      expect(seen.last, const StorageContributorUsage(bytes: 0));

      final again = await contributor.clear();
      expect(again.freedBytes, 0);
      expect(again.message, 'The editor cache is already empty');
      await sub.cancel();
      for (final path in _kept.keys) {
        expect(w.memory.filePaths, contains(path));
      }
    });

    for (final use in EditorCacheUse.values.where((u) => u != EditorCacheUse.none)) {
      test('is blocked while ${use.name}: nothing is deleted and the reason is shown', () async {
        final w = _world();
        final contributor = EditorCacheStorageContributor(
          cleaner: EditorCacheCleaner(roots: _roots, fs: w.fs, trimEngine: () async => fail('must not trim')),
          cacheUse: () async => use,
        );
        final usage = await contributor.watchUsage().first;
        expect(usage.bytes, 1165);
        expect(usage.clearBlockedReason, isNotEmpty);

        w.fs.reset();
        final outcome = await contributor.clearAction.run();
        expect(outcome.done, isFalse);
        expect(outcome.blockedReason, usage.clearBlockedReason);
        expect(w.fs.log, isEmpty);
      });
    }

    test('blocked copy names what to wait for', () {
      expect(StorageStrings.cacheBlocked(EditorCacheUse.projectOpen), 'Close the video editor to clear its cache.');
      expect(StorageStrings.cacheBlocked(EditorCacheUse.exportRunning), contains('export'));
      expect(StorageStrings.cacheBlocked(EditorCacheUse.captionsRunning), contains('Auto captions'));
    });
  });

  group('editorCacheUseOf', () {
    test('reports an open project first', () async {
      final check = editorCacheUseOf(openProjects: () => ['p1'], otherJobs: () => true);
      expect(await check(), EditorCacheUse.projectOpen);
    });

    test('reports a running or resumable export', () async {
      final engine = FakeEditorEngine();
      final check = editorCacheUseOf(openProjects: () => const [], exporter: engine.exporter);
      expect(await check(), EditorCacheUse.none);
      engine.exporter.records.add(const ExportResumable('job-1', doneFraction: 0.4));
      expect(await check(), EditorCacheUse.exportRunning);
    });

    test('reports an Auto captions job, then other editor jobs', () async {
      expect(await editorCacheUseOf(openProjects: () => const [], transcription: _BusyTranscription())(), EditorCacheUse.captionsRunning);
      expect(
        await editorCacheUseOf(openProjects: () => const [], transcription: _IdleTranscription(), otherJobs: () => true)(),
        EditorCacheUse.jobRunning,
      );
      expect(await editorCacheUseOf(openProjects: () => const [], transcription: _IdleTranscription())(), EditorCacheUse.none);
    });

    test('a failing probe counts as in use, so a broken check never clears under a live session', () async {
      final check = editorCacheUseOf(openProjects: () => throw StateError('repository gone'));
      expect(await check(), EditorCacheUse.jobRunning);
    });
  });

  group('EditorProjectsStorageContributor', () {
    test('reports what only deleting projects frees, with the project count', () async {
      final repo = FakeProjectRepository()
        ..report = const ProjectStorageReport(
          projectCount: 3,
          projectBundlesBytes: 1000,
          managedMediaBytes: 20000,
          derivedBytes: 300,
          cacheBytes: 999999,
        );
      final contributor = EditorProjectsStorageContributor(repository: repo, onOpenProjects: (_) {});
      final usage = await contributor.watchUsage().first;
      expect(usage, const StorageContributorUsage(bytes: 21300, detail: '3 projects'));
      expect(contributor.title, 'Video editor projects');
      expect(contributor.section, 'Video editor');
      expect(contributor.icon, Icons.movie_edit);
    });

    test('has no clear action and opens Projects', () {
      final opened = <BuildContext>[];
      final contributor = EditorProjectsStorageContributor(repository: FakeProjectRepository(), onOpenProjects: opened.add);
      expect(contributor.clearAction, isNull);
      expect(contributor.ownedPaths, isEmpty);
      final open = contributor.openAction;
      expect(open.label, 'Opens Projects');
      final context = _FakeContext();
      open.onOpen(context);
      expect(opened, [same(context)]);
    });

    test('is measured again whenever the project list changes', () async {
      final repo = FakeProjectRepository()..report = const ProjectStorageReport(projectCount: 1, projectBundlesBytes: 10);
      final project = repo.seedEmpty('Trip');
      final contributor = EditorProjectsStorageContributor(repository: repo, onOpenProjects: (_) {});
      final seen = <StorageContributorUsage>[];
      final sub = contributor.watchUsage().listen(seen.add);
      await pumpEventQueue();
      expect(seen.single.detail, '1 project');

      repo.report = const ProjectStorageReport(projectCount: 2, projectBundlesBytes: 30);
      await repo.duplicate(project.id);
      await pumpEventQueue();
      expect(seen.last, const StorageContributorUsage(bytes: 30, detail: '2 projects'));

      // An unchanged figure is not reported twice.
      await repo.rename(project.id, 'Trip 2');
      await pumpEventQueue();
      expect(seen, hasLength(2));
      await sub.cancel();
    });
  });

  test('EditorStorageContributor.all lists projects, then cache, in the Video editor section', () {
    final all = EditorStorageContributor.all(
      repository: FakeProjectRepository(),
      cache: EditorCacheCleaner(roots: _roots, fs: _world().fs),
      cacheUse: () async => EditorCacheUse.none,
      onOpenProjects: (_) {},
    );
    expect([for (final c in all) c.id], ['editor.projects', 'editor.cache']);
    expect({for (final c in all) c.section}, {'Video editor'});
    expect(all.expand((c) => c.ownedPaths), ['/app/cache/danaview/editor']);
  });
}

class _FakeContext extends Fake implements BuildContext {}
