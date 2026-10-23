// OWNER: HOM-17
//
// LibraryFs, the only code that writes under the library root (ARCH v1.2 rule 26, V2-06): entry
// directories `files/<id>/`, renames inside one directory, the purge staging rename
// (`files/.purge-<id>`), part files `imports/<jobId>.part` and the corrupt-database quarantine.
// Every multi-step change is a sequence of single atomic renames, so a crash between steps leaves
// something the store's open-time reconcile can roll forward or back. Calls are synchronous: the
// writer runs on its own isolate. Nothing here logs a path (rule 30).
//
// Part files are renamed and deleted through [retryOnSharingViolation]: on Windows a file another
// handle still holds open (an antivirus scanner or the search indexer reading a fresh part) can't be
// renamed or deleted for a moment (ERROR_SHARING_VIOLATION). Elsewhere the call runs once.

import 'dart:io';

import 'package:path/path.dart' as p;

import '../model/ids.dart';
import 'library_faults.dart';
import 'library_paths.dart';

/// The waits between the attempts of [retryOnSharingViolation] (about 1.5 s in all).
const List<Duration> sharingViolationBackoff = [
  Duration(milliseconds: 20),
  Duration(milliseconds: 50),
  Duration(milliseconds: 100),
  Duration(milliseconds: 200),
  Duration(milliseconds: 400),
  Duration(milliseconds: 800),
];

/// True when [e] is Windows' "the file is in use" (ERROR_SHARING_VIOLATION 32, ERROR_LOCK_VIOLATION
/// 33). [windows] overrides the host check (tests); on other hosts errno 32 is EPIPE and never
/// counts.
bool isSharingViolation(FileSystemException e, {bool? windows}) {
  if (!(windows ?? Platform.isWindows)) return false;
  final code = e.osError?.errorCode;
  return code == 32 || code == 33;
}

/// Runs [op]; when it throws a sharing violation ([isSharingViolation]) it is run again after each
/// wait of [backoff], and the last failure is rethrown. Any other error is rethrown at once, and on
/// a host other than Windows [op] runs exactly once. [windows] and [sleep] are for tests.
T retryOnSharingViolation<T>(
  T Function() op, {
  bool? windows,
  void Function(Duration wait) sleep = sleep,
  List<Duration> backoff = sharingViolationBackoff,
}) {
  for (var attempt = 0;; attempt++) {
    try {
      return op();
    } on FileSystemException catch (e) {
      if (attempt >= backoff.length || !isSharingViolation(e, windows: windows)) rethrow;
      sleep(backoff[attempt]);
    }
  }
}

/// File operations under one library root.
final class LibraryFs {
  /// The file layer of [paths]; [faults] receives the crash-injection steps.
  LibraryFs(this.paths, {this.faults = LibraryFaults.none});

  /// The layout.
  final LibraryPaths paths;

  /// Crash injection (tests).
  final LibraryFaults faults;

  /// Creates the root, `files/` and `imports/` when missing.
  void ensureLayout() {
    for (final dir in [paths.root, paths.filesDir, paths.importsDir]) {
      Directory(dir).createSync(recursive: true);
    }
  }

  /// The names of every directory under `files/` (entry ids and purge-staged ones).
  List<String> listEntryDirs() {
    final dir = Directory(paths.filesDir);
    if (!dir.existsSync()) return const [];
    return [
      for (final e in dir.listSync(followLinks: false))
        if (e is Directory) p.basename(e.path),
    ];
  }

  /// The regular files directly in `files/<id>/` (empty when the directory is missing).
  List<String> filesIn(EntryId id) => _filesIn(paths.entryDir(id));

  List<String> _filesIn(String dir) {
    final d = Directory(dir);
    if (!d.existsSync()) return const [];
    return [
      for (final e in d.listSync(followLinks: false))
        if (e is File) p.basename(e.path),
    ]..sort();
  }

  /// True when `files/<id>/<name>` exists.
  bool entryFileExists(EntryId id, String name) => File(paths.entryFile(id, name)).existsSync();

  /// True when `files/<id>/` exists.
  bool entryDirExists(EntryId id) => Directory(paths.entryDir(id)).existsSync();

  /// The size of `files/<id>/<name>`, or null when missing.
  int? entryFileSize(EntryId id, String name) {
    final f = File(paths.entryFile(id, name));
    return f.existsSync() ? f.lengthSync() : null;
  }

  /// Creates `files/<id>/`.
  void createEntryDir(EntryId id) {
    Directory(paths.entryDir(id)).createSync(recursive: true);
    faults.hit('fs.mkdir');
  }

  /// Renames `files/<id>/<from>` to `files/<id>/<to>` (one atomic rename in one directory).
  void renameEntryFile(EntryId id, String from, String to) {
    if (from == to) return;
    File(paths.entryFile(id, from)).renameSync(paths.entryFile(id, to));
    faults.hit('fs.rename');
  }

  /// Moves the import part file [relativePart] into `files/<id>/<name>` (one atomic rename).
  void movePartIntoEntry(String relativePart, EntryId id, String name) {
    final part = File(paths.resolve(relativePart));
    final target = paths.entryFile(id, name);
    retryOnSharingViolation(() => part.renameSync(target));
    faults.hit('fs.movePart');
  }

  /// True when the part file [relativePart] exists.
  bool partExists(String relativePart) => File(paths.resolve(relativePart)).existsSync();

  /// The size of the part file [relativePart], or 0 when missing.
  int partSize(String relativePart) {
    final f = File(paths.resolve(relativePart));
    return f.existsSync() ? f.lengthSync() : 0;
  }

  /// Opens the part file of [jobId] for writing: appending when [resume] (an import that continues
  /// after the app was killed), otherwise truncated. The caller closes it.
  RandomAccessFile openPart(String jobId, {bool resume = false}) =>
      File(paths.resolve(paths.relativePartPath(jobId))).openSync(mode: resume ? FileMode.append : FileMode.write);

  /// Copies `files/<from>/<name>` into the part file of [jobId] (the source is only read).
  void copyEntryToPart(EntryId from, String name, String jobId) {
    File(paths.entryFile(from, name)).copySync(paths.resolve(paths.relativePartPath(jobId)));
    faults.hit('fs.copy');
  }

  /// Deletes the part file [relativePart] when present.
  void deletePart(String relativePart) {
    final f = File(paths.resolve(relativePart));
    retryOnSharingViolation(() {
      if (f.existsSync()) f.deleteSync();
    });
  }

  /// Every part file name in `imports/`.
  List<String> listParts() => _filesIn(paths.importsDir).where((n) => n.endsWith('.part')).toList();

  /// Renames `files/<id>/` to `files/.purge-<id>/` (step one of a purge). No-op when missing.
  void stagePurge(EntryId id) {
    final dir = Directory(paths.entryDir(id));
    if (!dir.existsSync()) return;
    dir.renameSync(paths.purgeDir(id));
    faults.hit('fs.stagePurge');
  }

  /// Renames `files/.purge-<id>/` back to `files/<id>/` (rolling back an interrupted purge).
  void unstagePurge(EntryId id) {
    final staged = Directory(paths.purgeDir(id));
    if (staged.existsSync() && !Directory(paths.entryDir(id)).existsSync()) staged.renameSync(paths.entryDir(id));
  }

  /// Deletes `files/.purge-<id>/` (the last step of a purge).
  void removeStaged(EntryId id) {
    final staged = Directory(paths.purgeDir(id));
    if (staged.existsSync()) staged.deleteSync(recursive: true);
    faults.hit('fs.removeStaged');
  }

  /// Deletes the empty directory `files/<name>/` (an import interrupted before any byte moved in).
  void removeEmptyEntryDir(String name) {
    final dir = Directory(p.join(paths.filesDir, name));
    if (dir.existsSync() && dir.listSync().isEmpty) dir.deleteSync();
  }

  /// Deletes `files/<name>/` with its contents (a purge-staged directory whose row is gone).
  void removeEntryDirNamed(String name) {
    final dir = Directory(p.join(paths.filesDir, name));
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  }

  /// True when `library.db` exists.
  bool databaseExists() => File(paths.databasePath).existsSync();

  /// Moves `library.db` and its `-wal` / `-shm` aside as `library.db.corrupt-<stamp>…` and returns
  /// the new database path.
  String quarantineDatabase(DateTime now) {
    final t = now.toUtc();
    String two(int v) => v.toString().padLeft(2, '0');
    final stamp = '${t.year}${two(t.month)}${two(t.day)}-${two(t.hour)}${two(t.minute)}${two(t.second)}';
    var target = '${paths.databasePath}.corrupt-$stamp';
    for (var n = 2; File(target).existsSync(); n++) {
      target = '${paths.databasePath}.corrupt-$stamp-$n';
    }
    for (final suffix in ['', '-wal', '-shm']) {
      final f = File('${paths.databasePath}$suffix');
      if (f.existsSync()) f.renameSync('$target$suffix');
    }
    return target;
  }
}
