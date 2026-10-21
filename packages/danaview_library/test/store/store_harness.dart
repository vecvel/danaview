// OWNER: HOM-17
//
// Shared helpers of the HOM-17 store tests: temp roots, an in-process store on a fake clock, and an
// import helper that goes through the real part-file path.

import 'dart:io';
import 'dart:math';

import 'package:danaview_library/testing.dart';
import 'package:test/test.dart';

/// The fixed start of every fake clock.
final DateTime t0 = DateTime.utc(2026, 10, 1, 12);

/// A new temp library root, deleted after the test.
String tempRoot() {
  final dir = Directory.systemTemp.createTempSync('hom17_');
  addTearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });
  return dir.path;
}

/// Opens an in-process store.
Future<LibraryStore> openStore(String root, FakeLibraryClock clock, {LibraryFaults faults = LibraryFaults.none, int? seed}) =>
    LibraryStore.open(root: root, clock: clock.call, background: false, faults: faults, random: seed == null ? null : Random(seed));

/// Imports [bytes] as [name] into [folder] (Imported when null) through a part file.
FileEntry importBytes(LibraryWriter w, DateTime now, String name, List<int> bytes, {FolderId? folder}) {
  final job = w.beginImport(target: folder, bytesTotal: bytes.length, now: now);
  final part = w.fs.openPart(job.id);
  part.writeFromSync(bytes);
  part.closeSync();
  w.recordImportProgress(job.id, bytes.length);
  return w.commitImport(job.id, ImportedFileInfo(displayName: name, kind: classify(fileName: name).kind, subKind: classify(fileName: name).subKind), now: now);
}

/// Imports through [store].
Future<FileEntry> importInto(LibraryStore store, String name, {FolderId? folder, List<int>? bytes}) =>
    store.write((w, now) => importBytes(w, now, name, bytes ?? name.codeUnits, folder: folder));
