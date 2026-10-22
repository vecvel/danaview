// OWNER: HOM-20
//
// Shared helpers of the HOM-20 import tests: temp directories, generated source files (local test
// media only), an in-process store on a fake clock, and copiers that halt half-way (the app being
// killed) or record how they were started.

import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:danaview_library/testing.dart';
import 'package:test/test.dart';

/// The fixed start of every fake clock.
final DateTime t0 = DateTime.utc(2026, 10, 22, 9);

/// A new temp directory, deleted after the test.
Directory tempDir(String prefix) {
  final dir = Directory.systemTemp.createTempSync(prefix);
  addTearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });
  return dir;
}

/// Deterministic pseudo-random bytes.
Uint8List bytesOf(int length, {int seed = 1}) {
  final r = Random(seed);
  final out = Uint8List(length);
  for (var i = 0; i < length; i++) {
    out[i] = r.nextInt(256);
  }
  return out;
}

/// Writes [bytes] to [dir]/[name] and sets an old modification time, so a changed timestamp shows.
File sourceFile(Directory dir, String name, List<int> bytes) {
  final f = File('${dir.path}/$name')..writeAsBytesSync(bytes, flush: true);
  f.setLastModifiedSync(DateTime.utc(2020, 1, 2, 3, 4, 5));
  return f;
}

/// Opens a store at [root] (in-process unless [background]) and closes it after the test. The
/// close is registered after the temp folder's deletion, so it runs first: Windows refuses to
/// delete a folder while library.db in it is open (FIX-S1Q-A5). Closing twice, or after
/// `abandon`, does nothing.
Future<LibraryStore> openStore(String root, {FakeLibraryClock? clock, bool background = false}) async {
  final store = await LibraryStore.open(root: root, clock: (clock ?? FakeLibraryClock(t0)).call, background: background);
  addTearDown(store.close);
  return store;
}

/// Waits until [condition] holds (polling), failing after [timeout].
Future<void> eventually(bool Function() condition, {Duration timeout = const Duration(seconds: 20)}) async {
  final end = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(end)) fail('condition not met within $timeout');
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

/// A copier that writes the first [haltAt] bytes of a local source into the part, checkpoints
/// them, and then never finishes: the process is killed mid-copy.
final class HaltingCopier implements ImportCopier {
  /// Halts after [haltAt] bytes.
  HaltingCopier(this.haltAt);

  /// Bytes copied before the halt.
  final int haltAt;

  /// Completes once the halt point was reached and checkpointed.
  final Completer<void> halted = Completer<void>();

  @override
  bool handles(ImportSource source) => source.kind == ImportSourceKind.file;

  @override
  Future<SourceStat> stat(ImportSource source) => const FileImportCopier().stat(source);

  @override
  ImportCopyRun start({
    required ImportSource source,
    required String partPath,
    required int resumeFrom,
    required bool hash,
    required void Function(int bytesDone) onProgress,
    required void Function(int bytesDone) onCheckpoint,
  }) {
    final src = File(source.location).openSync();
    final head = src.readSync(haltAt);
    src.closeSync();
    File(partPath).writeAsBytesSync(head, flush: true);
    onProgress(haltAt);
    onCheckpoint(haltAt);
    // A few more bytes land after the checkpoint (not yet fsynced when the process dies).
    File(partPath).writeAsBytesSync(const [0xde, 0xad], mode: FileMode.append);
    halted.complete();
    return _NeverRun();
  }
}

final class _NeverRun implements ImportCopyRun {
  @override
  Future<CopyOutcome> get done => Completer<CopyOutcome>().future;

  @override
  Future<void> cancel() async {}
}

/// Wraps [inner] and records every start's `resumeFrom` and `hash`.
final class RecordingCopier implements ImportCopier {
  /// Records starts of [inner].
  RecordingCopier([this.inner = const FileImportCopier(checkpointBytes: 256 * 1024)]);

  /// The copier doing the work.
  final ImportCopier inner;

  /// `(resumeFrom, hash)` of every start.
  final List<(int, bool)> starts = [];

  @override
  bool handles(ImportSource source) => inner.handles(source);

  @override
  Future<SourceStat> stat(ImportSource source) => inner.stat(source);

  @override
  ImportCopyRun start({
    required ImportSource source,
    required String partPath,
    required int resumeFrom,
    required bool hash,
    required void Function(int bytesDone) onProgress,
    required void Function(int bytesDone) onCheckpoint,
  }) {
    starts.add((resumeFrom, hash));
    return inner.start(source: source, partPath: partPath, resumeFrom: resumeFrom, hash: hash, onProgress: onProgress, onCheckpoint: onCheckpoint);
  }
}

/// The bytes of [entry] in the library.
Uint8List libraryBytes(LibraryStore store, FileEntry entry) => File(store.paths.entryFile(entry.id, entry.displayName)).readAsBytesSync();
