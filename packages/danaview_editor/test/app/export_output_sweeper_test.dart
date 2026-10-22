// OWNER: FIX-QA05-D8-2
//
// ExportOutputSweeper: orphaned files under `<support>/danaview/editor/exports` older than 24 h go;
// files of running, resumable, kept or detached jobs (engine `activeJobs()`, the Android and iOS
// native records, the export flow's leases), caption side files of a referenced video, recent
// files and the iOS record file stay. An unreadable record skips the whole sweep. Settings ›
// Storage ("Export files") shows the folder's size and clears it under the same reference rule
// without the age limit.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_editor/danaview_editor.dart';
import 'package:danaview_editor_core/store.dart';
import 'package:danaview_editor_core/testing.dart';
import 'package:danaview_editor_engine_api/testing.dart';
import 'package:danaview_editor_engine_api/danaview_editor_engine_api.dart';
import 'package:danaview_features/storage.dart';

import '../support/fake_project_repository.dart';

const _roots = StoreRoots(support: '/app/support', cache: '/app/cache', documents: '/app/documents');
final _now = DateTime.utc(2026, 10, 22, 12);
final _old = _now.subtract(const Duration(hours: 25));
final _recent = _now.subtract(const Duration(hours: 23));

String _x(String name) => '${_roots.exportsDir}/$name';

final class _ThrowingExporter implements ExportService {
  @override
  Future<List<ExportJobState>> activeJobs() async => throw StateError('engine gone');

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _RecordsOnly implements ExportService {
  _RecordsOnly(this.jobs);

  final List<ExportJobState> jobs;

  @override
  Future<List<ExportJobState>> activeJobs() async => jobs;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// A file system whose listing throws a non-store error (a bug), for the quiet sweep.
final class _BrokenFs implements StoreFs {
  _BrokenFs(this.inner);

  final StoreFs inner;

  @override
  Future<StoreStat> stat(String path) => throw StateError('broken');

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

ExportResult _result(String path) => ExportResult(path: path, bytes: 1, duration: 1, videoEncoderName: 'x', hardwareEncoder: true);

void main() {
  late MemoryStoreFs fs;

  setUp(() {
    fs = MemoryStoreFs();
    fs.mkdirs(_roots.exportsDir);
    fs.mkdirs(_roots.workDir);
  });

  void put(String path, {DateTime? at, int bytes = 100}) => fs.putFile(path, List<int>.filled(bytes, 1), modified: at ?? _old);
  void putJson(String path, Object json) => fs.putFile(path, utf8.encode(jsonEncode(json)), modified: _old);

  ExportOutputSweeper sweeper({ExportService? exporter, ExportOutputLeases? leases, StoreFs? over}) => ExportOutputSweeper(
        roots: _roots,
        exporter: exporter,
        leases: leases,
        fs: over ?? fs,
        now: () => _now,
      );

  bool exists(String path) => fs.peek(path) != null;

  group('background sweep', () {
    test('unreferenced files older than 24 h go with their side files and empty folders; recent ones stay', () async {
      put(_x('export-dead.mp4'), bytes: 1000);
      put(_x('export-dead-captions-0.srt'));
      put(_x('nested/export-old.mov'));
      fs.touch(_x('nested'), _old);
      put(_x('export-new.mp4'), at: _recent);
      final report = await sweeper(exporter: _RecordsOnly(const [])).sweep();
      expect(exists(_x('export-dead.mp4')), isFalse);
      expect(exists(_x('export-dead-captions-0.srt')), isFalse);
      expect(exists(_x('nested/export-old.mov')), isFalse);
      expect((await fs.stat(_x('nested'))).exists, isFalse, reason: 'the empty folder goes too');
      expect(exists(_x('export-new.mp4')), isTrue, reason: 'younger than 24 h');
      expect(report.deletedFiles, 3);
      expect(report.freedBytes, 1200);
      expect(report.skipped, isFalse);
      expect((await fs.stat(_roots.exportsDir)).type, StoreEntityType.directory, reason: 'the folder itself stays');
    });

    test('the output of a terminal job (its record gone) is an orphan like any other', () async {
      final exporter = FakeExportService(FakeCallLog());
      exporter.records.add(const ExportInterrupted('ex_1'));
      put(_x('export-cancelled.mp4'));
      final report = await sweeper(exporter: exporter).sweep();
      expect(exists(_x('export-cancelled.mp4')), isFalse);
      expect(report.deletedFiles, 1);
    });

    test('running (Android record), detached, kept (iOS record), iOS job dir and leased files stay, however old', () async {
      // Android: a running job and a kept one-shot record.
      putJson('${_roots.editorCache}/export-jobs.json', {
        'v': 1,
        'jobs': [
          {'id': 'ex_run', 'state': 'running', 'output': _x('export-run.mp4')},
          {'id': 'ex_keep', 'state': 'completedWhileDetached', 'output': _x('export-keep.mp4'), 'result': {'path': _x('export-keep.mp4')}},
          {'id': 'ex_int', 'state': 'interrupted', 'output': _x('export-int.mp4')},
        ],
      });
      // iOS: a kept detached record next to the outputs, and a running job's directory.
      putJson(_x('active-exports.json'), {
        'version': 1,
        'entries': [
          {'jobId': 'ex_ios_keep', 'state': 'completedDetached', 'result': {'path': '/private${_x('export-ioskeep.mp4')}'}},
          {'jobId': 'ex_ios_run', 'state': 'running'},
        ],
      });
      putJson('${_roots.workDir}/export-ex_ios_run/job.json', {'jobId': 'ex_ios_run', 'outputPath': _x('export-iosrun.mp4')});
      final exporter = _RecordsOnly([
        const ExportResumable('ex_run', doneFraction: 0.5),
        const ExportResumable('ex_ios_run', doneFraction: 0.1),
        const ExportResumable('ex_moved', doneFraction: 0.3),
        ExportCompletedWhileDetached('ex_away', result: _result(_x('export-away.mp4'))),
      ]);
      // Android after the record moves off the cache (a later engine): read from the support root.
      putJson('${_roots.editorSupport}/export-jobs.json', {
        'v': 1,
        'jobs': [
          {'id': 'ex_moved', 'state': 'running', 'output': _x('export-moved.mp4')},
        ],
      });
      put(_x('export-jobs.json.bak'));
      final leases = ExportOutputLeases()..hold(Object(), [_x('export-card.mp4'), _x('export-card-captions-0.vtt')]);
      final names = [
        'export-run.mp4',
        'export-keep.mp4',
        'export-int.mp4',
        'export-ioskeep.mp4',
        'export-iosrun.mp4',
        'export-away.mp4',
        'export-away-captions-0.srt',
        'export-card.mp4',
        'export-card-captions-0.vtt',
        'export-moved.mp4',
        '.active-exports.json.tmp',
      ];
      for (final n in names) {
        put(_x(n));
      }
      put(_x('export-orphan.mp4'));
      final report = await sweeper(exporter: exporter, leases: leases).sweep();
      for (final n in [...names, 'active-exports.json', 'export-jobs.json.bak']) {
        expect(exists(_x(n)), isTrue, reason: n);
      }
      expect(exists(_x('export-orphan.mp4')), isFalse);
      expect(report.deletedFiles, 1);
    });

    group('fails safe: nothing is swept', () {
      setUp(() => put(_x('export-dead.mp4')));

      Future<void> expectSkipped(ExportOutputSweeper s) async {
        final report = await s.sweep();
        expect(report.skipped, isTrue);
        expect(report.deletedFiles, 0);
        expect(exists(_x('export-dead.mp4')), isTrue);
      }

      test('a corrupt Android record', () async {
        fs.putFile('${_roots.editorCache}/export-jobs.json', utf8.encode('{"v": 1, "jobs": ['));
        await expectSkipped(sweeper(exporter: _RecordsOnly(const [])));
      });

      test('a corrupt Android record moved next to the outputs (a later engine)', () async {
        fs.putFile(_x('export-jobs.json'), utf8.encode('{'));
        await expectSkipped(sweeper(exporter: _RecordsOnly(const [])));
        expect(exists(_x('export-jobs.json')), isTrue);
      });

      test('an Android record of an unknown version', () async {
        putJson('${_roots.editorCache}/export-jobs.json', {'v': 2, 'jobs': <Object>[]});
        await expectSkipped(sweeper(exporter: _RecordsOnly(const [])));
      });

      test('a corrupt iOS record', () async {
        fs.putFile(_x('active-exports.json'), utf8.encode('not json'));
        await expectSkipped(sweeper(exporter: _RecordsOnly(const [])));
      });

      test('a corrupt iOS job record', () async {
        fs.putFile('${_roots.workDir}/export-ex_1/job.json', utf8.encode('{'));
        await expectSkipped(sweeper(exporter: _RecordsOnly(const [])));
      });

      test('activeJobs fails', () async {
        await expectSkipped(sweeper(exporter: _ThrowingExporter()));
      });

      test('a running job whose output is in no record', () async {
        final job = FakeExportJob('ex_lost', _x('export-lost.mp4'), 0);
        await expectSkipped(sweeper(exporter: _RecordsOnly([ExportRunning(job)])));
      });
    });

    test('sweepQuietly swallows and counts errors', () async {
      final s = sweeper(over: _BrokenFs(fs));
      await s.sweepQuietly();
      expect(s.quietFailures, 1);
    });

    test('no exports folder is a no-op', () async {
      final empty = MemoryStoreFs();
      final report = await sweeper(over: empty).sweep();
      expect(report.deletedFiles, 0);
      expect(report.skipped, isFalse);
    });
  });

  group('Settings › Storage "Export files"', () {
    Future<EditorExportsStorageContributor> contributor({EditorCacheUse use = EditorCacheUse.none, ExportService? exporter}) async =>
        EditorExportsStorageContributor(
          sweeper: sweeper(exporter: exporter ?? _RecordsOnly(const [])),
          cacheUse: () async => use,
        );

    test('is listed after the cache with the folder size, without the record file', () async {
      put(_x('export-a.mp4'), bytes: 1000);
      put(_x('export-a-captions-0.srt'), bytes: 20);
      putJson(_x('active-exports.json'), {'version': 1, 'entries': <Object>[]});
      final row = await contributor();
      expect(row.id, 'editor.exports');
      expect(row.title, 'Export files');
      final usage = await row.watchUsage().first;
      expect(usage.bytes, 1020);
      expect(usage.detail, '2 files');
      expect(usage.clearBlockedReason, isNull);
      expect(row.clearAction, isNotNull);
    });

    test('clear deletes unreferenced files of any age and keeps referenced ones', () async {
      put(_x('export-recent.mp4'), at: _recent, bytes: 300);
      put(_x('export-old.mp4'), bytes: 200);
      put(_x('export-keep.mp4'), at: _recent);
      final row = await contributor(
        exporter: _RecordsOnly([ExportCompletedWhileDetached('ex_k', result: _result(_x('export-keep.mp4')))]),
      );
      final outcome = await row.clear();
      expect(outcome.done, isTrue);
      expect(outcome.freedBytes, 500);
      expect(exists(_x('export-recent.mp4')), isFalse);
      expect(exists(_x('export-old.mp4')), isFalse);
      expect(exists(_x('export-keep.mp4')), isTrue);
      expect((await row.watchUsage().first).bytes, 100);
    });

    test('clear is blocked while a project is open or an export runs', () async {
      put(_x('export-a.mp4'));
      for (final use in [EditorCacheUse.projectOpen, EditorCacheUse.exportRunning]) {
        final row = await contributor(use: use);
        final outcome = await row.clear();
        expect(outcome.done, isFalse);
        expect(outcome.blockedReason, isNotEmpty);
        expect((await row.watchUsage().first).clearBlockedReason, isNotNull);
      }
      expect(exists(_x('export-a.mp4')), isTrue);
    });

    test('an unreadable record blocks the clear and deletes nothing', () async {
      put(_x('export-a.mp4'));
      fs.putFile('${_roots.editorCache}/export-jobs.json', utf8.encode('garbage'));
      final outcome = await (await contributor()).clear();
      expect(outcome.done, isFalse);
      expect(exists(_x('export-a.mp4')), isTrue);
    });

    test('EditorStorageContributor.all lists it only with a sweeper', () {
      final repo = FakeProjectRepository();
      final cache = EditorCacheCleaner(roots: _roots, fs: fs);
      Future<EditorCacheUse> use() async => EditorCacheUse.none;
      final without = EditorStorageContributor.all(repository: repo, cache: cache, cacheUse: use, onOpenProjects: (_) {});
      final withExports = EditorStorageContributor.all(repository: repo, cache: cache, cacheUse: use, onOpenProjects: (_) {}, exports: sweeper());
      expect(without.map((c) => c.id), ['editor.projects', 'editor.cache']);
      expect(withExports.map((c) => c.id), ['editor.projects', 'editor.cache', 'editor.exports']);
      expect(withExports.last, isA<StorageContributor>());
    });
  });
}
