// OWNER: FIX-QA05-D8-2
//
// Sweeps orphaned export outputs from `StoreRoots.exportsDir` (`<support>/danaview/editor/exports`).
// QA-05 D8 moved export outputs and caption side files out of the purgeable cache, so the system no
// longer deletes what a cancelled or failed export, or an app killed before the handoff, left
// behind. This sweeper does.
//
// A file is kept when anything references it:
// * the engine's `ExportService.activeJobs()`: a completed-while-detached result path; a running or
//   resumable job must have its output path in a native record below, or the sweep is skipped;
// * the native job records the Dart side can read:
//   - Android `export-jobs.json` (`jobs[].output`, `jobs[].result.path`) at `<cache>/danaview/editor`
//     today, and at `<support>/danaview/editor` or the exports folder once the Android lane moves it
//     off the purgeable cache (QA-05 D8 engine half); every location that exists is read;
//   - iOS `<support>/danaview/editor/exports/active-exports.json` (`entries[].result.path`) and
//     each `<cache>/danaview/editor/work/export-<jobId>/job.json` (`outputPath`, `result.path`);
// * [ExportOutputLeases]: the paths the export flow holds in this process (the running output,
//   the completion card's video and caption side files, a finished-while-away card).
// A caption side file (`<stem>-captions-<n>.<srt|vtt>`) is referenced with its video (`<stem>.<ext>`).
// References compare by base name as well as by path (the names carry a unique token), so a
// differently spelled absolute path (`/private/var` vs `/var` on iOS) still protects the file.
//
// Fail safe: when `activeJobs()` fails, a record file exists but cannot be read or parsed, or a
// running/resumable job's output is in no readable record, nothing is swept that run.
//
// The background sweep ([ExportOutputSweeper.sweep]) deletes unreferenced files older than
// [ExportOutputSweeper.maxAge] (24 h) and then empty sub-folders; Settings › Storage
// ([ExportOutputSweeper.clear]) applies the same reference rule without the age limit. JSON files
// (the record files) and hidden files (atomic-write temporaries) are never touched. Deletes
// go through `OwnedFileDeleter` (D-44). Nothing here logs file names or paths: only counts and
// error types.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:danaview_editor_core/store.dart';
import 'package:danaview_editor_engine_api/danaview_editor_engine_api.dart';

/// Paths the export flow uses right now in this process (see the file header). Every owner (an
/// export controller) replaces its own set; the sweeper keeps the union.
final class ExportOutputLeases {
  final Map<Object, Set<String>> _byOwner = {};

  /// Replaces [owner]'s paths (an empty set releases them).
  void hold(Object owner, Iterable<String> paths) {
    final set = {for (final path in paths) if (path.isNotEmpty) path};
    if (set.isEmpty) {
      _byOwner.remove(owner);
    } else {
      _byOwner[owner] = set;
    }
  }

  /// Releases everything [owner] holds.
  void release(Object owner) => _byOwner.remove(owner);

  /// Every held path.
  Set<String> get paths => {for (final set in _byOwner.values) ...set};
}

/// A native job record exists but could not be read: the sweep is skipped.
final class ExportRecordsUnreadable implements Exception {
  /// Creates the failure; [reason] is a short phrase without paths.
  const ExportRecordsUnreadable(this.reason);

  /// Why (no paths).
  final String reason;

  @override
  String toString() => 'ExportRecordsUnreadable($reason)';
}

/// What a sweep did.
@immutable
final class ExportSweepReport {
  /// Creates a report.
  const ExportSweepReport({this.deletedFiles = 0, this.freedBytes = 0, this.keptFiles = 0, this.failures = 0, this.skipped = false});

  /// A sweep that did nothing because a record could not be read (fail safe).
  const ExportSweepReport.skipped() : this(skipped: true);

  /// Files deleted.
  final int deletedFiles;

  /// Bytes those files took.
  final int freedBytes;

  /// Files left in place (referenced, too recent, or protected).
  final int keptFiles;

  /// Deletes that failed.
  final int failures;

  /// Whether the sweep was skipped.
  final bool skipped;

  @override
  String toString() => 'ExportSweepReport(deleted $deletedFiles, freed $freedBytes, kept $keptFiles, failures $failures${skipped ? ', skipped' : ''})';
}

/// Deletes orphaned export outputs (see the file header).
final class ExportOutputSweeper {
  /// Creates the sweeper over [roots]. [exporter] answers `activeJobs()` (null: no engine jobs);
  /// [leases] are the in-process references; [now] is the clock of the age rule.
  ExportOutputSweeper({
    required this.roots,
    this.exporter,
    ExportOutputLeases? leases,
    StoreFs fs = const LocalStoreFs(),
    OwnedFileDeleter? deleter,
    this.now = DateTime.now,
    this.activeJobsTimeout = const Duration(seconds: 5),
  })  : leases = leases ?? ExportOutputLeases(),
        _fs = fs,
        _deleter = deleter ?? OwnedFileDeleter(roots, fs: fs);

  /// Unreferenced files younger than this stay in the background sweep.
  static const Duration maxAge = Duration(hours: 24);

  /// Android's record file (under `<cache>/danaview/editor`; see [androidRecordPaths]).
  static const String androidRecordsFile = 'export-jobs.json';

  /// iOS's record file under the exports folder.
  static const String iosRecordsFile = 'active-exports.json';

  /// iOS job directories under `work/` (`export-<jobId>/job.json`).
  static const String iosJobDirPrefix = 'export-';

  /// iOS job record file name.
  static const String iosJobRecordFile = 'job.json';

  /// App roots.
  final StoreRoots roots;

  /// The engine's export service.
  final ExportService? exporter;

  /// In-process references.
  final ExportOutputLeases leases;

  /// The clock.
  final DateTime Function() now;

  /// How long [ExportService.activeJobs] may take.
  final Duration activeJobsTimeout;

  final StoreFs _fs;
  final OwnedFileDeleter _deleter;

  Future<ExportSweepReport>? _running;
  int _quietFailures = 0;

  /// Sweeps that failed with an error inside [sweepQuietly] (swallowed, counted).
  int get quietFailures => _quietFailures;

  /// The exports folder.
  String get exportsDir => roots.exportsDir;

  /// Where Android's record file is (the cache today) or may be after the engine moves it off the
  /// purgeable cache: each one that exists is read.
  List<String> get androidRecordPaths => [
        p.join(roots.editorCache, androidRecordsFile),
        p.join(roots.editorSupport, androidRecordsFile),
        p.join(exportsDir, androidRecordsFile),
      ];

  /// The background sweep: unreferenced files older than [maxAge], then empty sub-folders.
  Future<ExportSweepReport> sweep() => _exclusive(() => _sweep(ignoreAge: false));

  /// Settings › Storage: every unreferenced file, whatever its age, then empty sub-folders.
  Future<ExportSweepReport> clear() => _exclusive(() => _sweep(ignoreAge: true));

  /// [sweep] without awaiting or throwing (bootstrap, job end): errors are swallowed and counted in
  /// [quietFailures]; only counts are logged.
  Future<void> sweepQuietly() async {
    try {
      final report = await sweep();
      if (report.deletedFiles > 0 || report.failures > 0 || report.skipped) {
        debugPrint('[ExportSweep] deleted ${report.deletedFiles}, failures ${report.failures}${report.skipped ? ', skipped' : ''}');
      }
    } on Object catch (e) {
      _quietFailures++;
      debugPrint('[ExportSweep] Sweep failed: ${e.runtimeType}');
    }
  }

  /// Starts [sweepQuietly] without waiting for it.
  void sweepSoon() => unawaited(sweepQuietly());

  /// Bytes of the files in the exports folder (the record file and hidden files excluded).
  Future<({int bytes, int files})> measure() async {
    var bytes = 0;
    var files = 0;
    for (final file in await _files(exportsDir)) {
      if (_protected(file.path)) continue;
      bytes += file.size;
      files++;
    }
    return (bytes: bytes, files: files);
  }

  Future<ExportSweepReport> _exclusive(Future<ExportSweepReport> Function() body) async {
    while (_running != null) {
      try {
        await _running;
      } on Object {
        // The other run reports its own failure.
      }
    }
    final run = body();
    _running = run;
    try {
      return await run;
    } finally {
      if (identical(_running, run)) _running = null;
    }
  }

  Future<ExportSweepReport> _sweep({required bool ignoreAge}) async {
    if ((await _fs.stat(exportsDir)).type != StoreEntityType.directory) return const ExportSweepReport();
    final _References refs;
    try {
      refs = await _references();
    } on ExportRecordsUnreadable catch (e) {
      debugPrint('[ExportSweep] Skipped: ${e.reason}');
      return const ExportSweepReport.skipped();
    }
    final cutoff = now().subtract(maxAge);
    var deleted = 0, freed = 0, kept = 0, failures = 0;
    for (final file in await _files(exportsDir)) {
      if (_protected(file.path) || refs.covers(file.path)) {
        kept++;
        continue;
      }
      if (!ignoreAge) {
        final modified = file.modified;
        if (modified == null || modified.isAfter(cutoff)) {
          kept++;
          continue;
        }
      }
      try {
        await _deleter.delete(file.path);
        deleted++;
        freed += file.size;
      } on Object catch (e) {
        failures++;
        debugPrint('[ExportSweep] Could not delete an export file: ${e.runtimeType}');
      }
    }
    failures += await _removeEmptyDirs(exportsDir, cutoff: ignoreAge ? null : cutoff);
    return ExportSweepReport(deletedFiles: deleted, freedBytes: freed, keptFiles: kept, failures: failures);
  }

  /// Deletes empty sub-folders of [dir] (deepest first; [dir] itself stays). With [cutoff], only
  /// folders last modified before it. Returns the failures.
  Future<int> _removeEmptyDirs(String dir, {DateTime? cutoff}) async {
    var failures = 0;
    final List<StoreEntry> entries;
    try {
      entries = await _fs.list(dir);
    } on StoreFailure {
      return 0;
    }
    for (final entry in entries) {
      if (entry.type != StoreEntityType.directory) continue;
      failures += await _removeEmptyDirs(entry.path, cutoff: cutoff);
      try {
        if ((await _fs.list(entry.path)).isNotEmpty) continue;
        if (cutoff != null) {
          final modified = (await _fs.stat(entry.path)).modified;
          if (modified == null || modified.isAfter(cutoff)) continue;
        }
        await _deleter.delete(entry.path, recursive: false);
      } on Object catch (e) {
        failures++;
        debugPrint('[ExportSweep] Could not delete an empty folder: ${e.runtimeType}');
      }
    }
    return failures;
  }

  /// Record files (any JSON) and hidden files (atomic-write temporaries) are never swept or counted.
  static bool _protected(String path) {
    final name = p.basename(path);
    return name.startsWith('.') || name.toLowerCase().contains('.json');
  }

  /// Regular files under [dir], recursively (links are not followed).
  Future<List<_File>> _files(String dir) async {
    final out = <_File>[];
    final List<StoreEntry> entries;
    try {
      entries = await _fs.list(dir);
    } on StoreFailure {
      return out;
    }
    for (final entry in entries) {
      switch (entry.type) {
        case StoreEntityType.directory:
          out.addAll(await _files(entry.path));
        case StoreEntityType.file:
          try {
            final stat = await _fs.stat(entry.path);
            if (stat.type == StoreEntityType.file) out.add(_File(entry.path, stat.size, stat.modified));
          } on StoreFailure {
            // Vanished or unreadable: left alone.
          }
        default:
          break;
      }
    }
    return out;
  }

  // ---------------------------------------------------------------------------------------------
  // References
  // ---------------------------------------------------------------------------------------------

  Future<_References> _references() async {
    final refs = _References();
    refs.addAll(leases.paths);
    final needPath = <String>{};
    final service = exporter;
    if (service != null) {
      final List<ExportJobState> jobs;
      try {
        jobs = await service.activeJobs().timeout(activeJobsTimeout);
      } on Object catch (e) {
        throw ExportRecordsUnreadable('activeJobs failed (${e.runtimeType})');
      }
      for (final job in jobs) {
        switch (job) {
          case ExportCompletedWhileDetached(:final result):
            if (result != null) refs.add(result.path);
          case ExportRunning() || ExportResumable():
            needPath.add(job.jobId);
          case ExportInterrupted():
            // Terminal: its output is referenced only through a native record, read below.
            break;
        }
      }
    }
    final known = <String>{};
    for (final path in androidRecordPaths) {
      await _readAndroidRecords(path, refs, known);
    }
    await _readIosRecords(refs, known);
    await _readIosJobDirs(refs, known);
    if (!known.containsAll(needPath)) {
      throw const ExportRecordsUnreadable('a running export has no readable record');
    }
    return refs;
  }

  /// `export-jobs.json` at [path]: `{"v": 1, "jobs": [{id, output, result: {path}}]}`.
  Future<void> _readAndroidRecords(String path, _References refs, Set<String> known) async {
    final json = await _readJson(path);
    if (json == null) return;
    if (json is! Map || json['v'] != 1) throw const ExportRecordsUnreadable('unknown Android record format');
    final jobs = json['jobs'];
    if (jobs == null) return;
    if (jobs is! List) throw const ExportRecordsUnreadable('unknown Android record format');
    for (final job in jobs) {
      if (job is! Map) throw const ExportRecordsUnreadable('unknown Android record format');
      final output = job['output'];
      if (output is String && output.isNotEmpty) {
        refs.add(output);
        final id = job['id'];
        if (id is String) known.add(id);
      }
      refs.addResult(job['result']);
    }
  }

  /// `<support>/danaview/editor/exports/active-exports.json`: `{"version": 1, "entries": [{jobId,
  /// state, result: {path}}]}`. Running entries carry no path; their job directory does.
  Future<void> _readIosRecords(_References refs, Set<String> known) async {
    final json = await _readJson(p.join(exportsDir, iosRecordsFile));
    if (json == null) return;
    if (json is! Map) throw const ExportRecordsUnreadable('unknown iOS record format');
    final entries = json['entries'];
    if (entries == null) return;
    if (entries is! List) throw const ExportRecordsUnreadable('unknown iOS record format');
    for (final entry in entries) {
      if (entry is! Map) throw const ExportRecordsUnreadable('unknown iOS record format');
      final result = entry['result'];
      if (refs.addResult(result)) {
        final id = entry['jobId'];
        if (id is String) known.add(id);
      }
    }
  }

  /// `<cache>/danaview/editor/work/export-<jobId>/job.json`: `{jobId, outputPath, result: {path}}`.
  Future<void> _readIosJobDirs(_References refs, Set<String> known) async {
    final List<StoreEntry> entries;
    try {
      if ((await _fs.stat(roots.workDir)).type != StoreEntityType.directory) return;
      entries = await _fs.list(roots.workDir);
    } on StoreFailure catch (e) {
      throw ExportRecordsUnreadable('work folder unreadable (${e.kind.name})');
    }
    for (final entry in entries) {
      if (entry.type != StoreEntityType.directory || !p.basename(entry.path).startsWith(iosJobDirPrefix)) continue;
      final json = await _readJson(p.join(entry.path, iosJobRecordFile));
      if (json == null) continue;
      if (json is! Map) throw const ExportRecordsUnreadable('unknown iOS job record format');
      final output = json['outputPath'];
      if (output is String && output.isNotEmpty) {
        refs.add(output);
        final id = json['jobId'];
        if (id is String) known.add(id);
      }
      refs.addResult(json['result']);
    }
  }

  /// The decoded JSON at [path]; null when there is no file. Anything else unreadable throws.
  Future<Object?> _readJson(String path) async {
    final StoreStat stat;
    try {
      stat = await _fs.stat(path);
    } on StoreFailure catch (e) {
      throw ExportRecordsUnreadable('record unreadable (${e.kind.name})');
    }
    if (!stat.exists) return null;
    if (stat.type != StoreEntityType.file) throw const ExportRecordsUnreadable('record is not a file');
    try {
      return jsonDecode(utf8.decode(await _fs.readBytes(path)));
    } on Object catch (e) {
      throw ExportRecordsUnreadable('record unreadable (${e.runtimeType})');
    }
  }
}

final class _File {
  const _File(this.path, this.size, this.modified);

  final String path;
  final int size;
  final DateTime? modified;
}

/// Referenced paths and base names (see the file header).
final class _References {
  final Set<String> _paths = {};
  final Set<String> _names = {};

  static final RegExp _sideFile = RegExp(r'^(.+)-captions-\d+\.(srt|vtt)$');

  void add(String path) {
    if (path.isEmpty) return;
    _paths.add(p.normalize(path));
    _names.add(p.basename(path));
  }

  void addAll(Iterable<String> paths) => paths.forEach(add);

  /// Adds `result.path` of a record; returns whether there was one.
  bool addResult(Object? result) {
    if (result == null) return false;
    if (result is! Map) throw const ExportRecordsUnreadable('unknown record result format');
    final path = result['path'];
    if (path is! String || path.isEmpty) return false;
    add(path);
    return true;
  }

  bool covers(String path) {
    if (_paths.contains(p.normalize(path))) return true;
    final name = p.basename(path);
    if (_names.contains(name)) return true;
    final side = _sideFile.firstMatch(name);
    if (side == null) return false;
    final stem = side.group(1)!;
    return _names.any((n) => p.basenameWithoutExtension(n) == stem);
  }
}
