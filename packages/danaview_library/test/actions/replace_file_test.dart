// OWNER: HOM-28
//
// The PDF tools' "Replace" in the library (ARCH v1.2 §9.3, HOM plan §8.5): the entry keeps its id,
// name, folder, favourite and references while its file takes the new bytes (one rename over the
// old file), the row gets the new size, quick hash, date and page count, the change stream fires,
// the source file is only read, no part file is left, and trashed or missing entries are refused.
// Crashes at every step are covered in test/store/crash_test.dart. Generated files only.

import 'dart:io';
import 'dart:math';

import 'package:danaview_library/testing.dart';
import 'package:test/test.dart';

import '../support/sqlite_open.dart';

final DateTime t0 = DateTime.utc(2026, 10, 30, 9);

Directory _temp() {
  final dir = Directory.systemTemp.createTempSync('hom28_');
  addTearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });
  return dir;
}

Future<FileEntry> _import(LibraryStore store, String name, List<int> bytes, {FolderId? folder}) => store.write((w, now) {
      final c = classify(fileName: name);
      final job = w.beginImport(target: folder, bytesTotal: bytes.length, now: now);
      final part = w.fs.openPart(job.id);
      part.writeFromSync(bytes);
      part.closeSync();
      w.recordImportProgress(job.id, bytes.length);
      return w.commitImport(
        job.id,
        ImportedFileInfo(displayName: name, kind: c.kind, subKind: c.subKind, mime: 'application/pdf', sourceHint: SourceHint.files, meta: const EntryMeta(pageCount: 2)),
        now: now,
      );
    });

void main() {
  setUpAll(useHostSqlite);
  late FakeLibraryClock clock;
  late LibraryStore store;
  late LibraryFileActions actions;
  late Directory temp;

  setUp(() async {
    temp = _temp();
    clock = FakeLibraryClock(t0);
    store = await LibraryStore.open(root: _temp().path, clock: clock.call, background: false, random: Random(28));
    addTearDown(store.close);
    actions = LibraryFileActions(store);
  });

  test('the entry keeps its identity and takes the new bytes', () async {
    final folder = await store.write((w, now) => w.createFolder('Contracts', now: now));
    final e = await _import(store, 'Report.pdf', '%PDF-old'.codeUnits, folder: folder);
    await store.write((w, _) => w.setEntryFavourite(e.id, true));
    await store.write((w, _) => w.addRef(e.id, RefHolder.project('p1')));
    final source = File('${temp.path}/edited.pdf')..writeAsBytesSync('%PDF-new and longer'.codeUnits);
    final sourceStamp = source.lastModifiedSync();
    var changes = 0;
    final sub = store.changes.listen((_) => changes++);
    addTearDown(sub.cancel);
    clock.advance(const Duration(minutes: 5));

    final replaced = await actions.replaceFile(e.id, source.path, pageCount: 7);

    expect(replaced.id, e.id);
    expect(replaced.displayName, 'Report.pdf');
    expect(replaced.folderId, folder);
    expect(replaced.isFavourite, isTrue);
    expect(replaced.sizeBytes, '%PDF-new and longer'.length);
    expect(replaced.modifiedAt, t0.add(const Duration(minutes: 5)));
    expect(replaced.quickHash, await quickHashOfFile(source.path));
    expect(File(actions.pathOf(replaced)).readAsStringSync(), '%PDF-new and longer');
    expect(store.reader.meta(e.id)?.pageCount, 7);
    expect(store.reader.refUsage(entries: [e.id]).isEmpty, isFalse, reason: 'references stay');
    expect(changes, greaterThan(0), reason: 'the UI re-queries');
    expect(source.readAsStringSync(), '%PDF-new and longer', reason: 'the source is only read');
    expect(source.lastModifiedSync(), sourceStamp);
    expect(Directory(store.paths.importsDir).listSync().where((f) => f.path.endsWith('.part')), isEmpty);
    expect(store.reader.allEntries(), hasLength(1), reason: 'no new entry');
    expect(await store.checkInvariants(), isEmpty);
  });

  test('trashed, unknown and missing sources are refused and change nothing', () async {
    final e = await _import(store, 'A.pdf', '%PDF-a'.codeUnits);
    final source = File('${temp.path}/x.pdf')..writeAsStringSync('%PDF-x');
    await expectLater(actions.replaceFile(e.id, '${temp.path}/none.pdf'), throwsA(isA<LibraryWriteException>()));
    await actions.delete([e.id]);
    await expectLater(actions.replaceFile(e.id, source.path), throwsA(isA<LibraryWriteException>()));
    expect(File(store.paths.entryFile(e.id, 'A.pdf')).readAsStringSync(), '%PDF-a');
    expect(Directory(store.paths.importsDir).listSync().where((f) => f.path.endsWith('.part')), isEmpty);
  });
}
