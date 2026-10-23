// OWNER: HOM-19
//
// Helpers of the HOM-19 organise tests: an in-process store on a fake clock in a temp root, and an
// import helper through the real part-file path.

import 'dart:io';
import 'dart:math';

import 'package:danaview_library/testing.dart';
import 'package:test/test.dart';

/// The fixed start of every fake clock.
final DateTime t0 = DateTime.utc(2026, 10, 1, 12);

/// A new temp library root, deleted after the test.
String tempRoot() {
  final dir = Directory.systemTemp.createTempSync('hom19_');
  addTearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });
  return dir.path;
}

/// Opens an in-process store at [root] (a new temp root when null) and closes it after the test.
Future<LibraryStore> openTestStore(FakeLibraryClock clock, {String? root}) async {
  final store = await LibraryStore.open(root: root ?? tempRoot(), clock: clock.call, background: false, random: Random(19));
  addTearDown(store.close);
  return store;
}

/// Imports [name] (contents [bytes] or `size` filler bytes) into [folder] (Imported when null).
Future<FileEntry> importNamed(LibraryStore store, String name, {FolderId? folder, int size = 4}) => store.write((w, now) {
      final c = classify(fileName: name);
      final job = w.beginImport(target: folder, bytesTotal: size, now: now);
      final part = w.fs.openPart(job.id);
      part.writeFromSync(List.filled(size, 7));
      part.closeSync();
      w.recordImportProgress(job.id, size);
      return w.commitImport(job.id, ImportedFileInfo(displayName: name, kind: c.kind, subKind: c.subKind), now: now);
    });

/// Creates folder [name] under [parent].
Future<FolderId> folderNamed(LibraryStore store, String name, {FolderId? parent}) =>
    store.write((w, now) => w.createFolder(name, parent: parent, now: now));
