// OWNER: HOM-17
//
// Invariants check on open and rebuild-from-files recovery (ARCH v1.2 §5.3): a corrupt database is
// moved aside as `library.db.corrupt-<stamp>` and the files come back under `Recovered` with their
// ids; a newer schema opens read-only; repairs for cycles, lost folders, missing files and orphan
// directories; the writer on its background isolate.

import 'dart:io';

import 'package:danaview_library/testing.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

import '../support/sqlite_open.dart';
import 'store_harness.dart';

void main() {
  setUpAll(useHostSqlite);
  late String root;
  late FakeLibraryClock clock;

  setUp(() {
    root = tempRoot();
    clock = FakeLibraryClock(t0);
  });

  test('a corrupt library.db is quarantined and the library is rebuilt from files', () async {
    var store = await openStore(root, clock);
    final folder = await store.write((w, now) => w.createFolder('Trips', now: now));
    final a = await importInto(store, 'beach.jpg', folder: folder);
    final b = await importInto(store, 'notes.pdf');
    await store.close();
    for (final suffix in ['-wal', '-shm']) {
      final f = File('$root/library.db$suffix');
      if (f.existsSync()) f.deleteSync();
    }
    File('$root/library.db').writeAsStringSync('this is not a database' * 100);

    store = await openStore(root, clock);
    expect(store.openReport.rebuilt, isTrue);
    expect(store.openReport.quarantinedAs, endsWith('library.db.corrupt-20261001-120000'));
    expect(File(store.openReport.quarantinedAs!).existsSync(), isTrue);
    expect(store.openReport.violations, isEmpty);
    final recovered = store.reader.systemFolder(FolderSystemRole.recovered)!;
    final entries = store.reader.entriesPage(EntryQuery(folderId: recovered.id, sort: EntrySortKey.name, descending: false));
    expect(entries.map((e) => (e.id, e.displayName)), [(a.id, 'beach.jpg'), (b.id, 'notes.pdf')], reason: 'ids survive for editor refs');
    expect(entries.first.kind, FileKind.photo);
    expect(entries.last.subKind, 'pdf');
    expect(store.reader.systemFolder(FolderSystemRole.imported), isNotNull);
    expect(await store.checkInvariants(), isEmpty);
    await store.close();
  });

  test('a library newer than this build opens read-only and refuses writes', () async {
    var store = await openStore(root, clock);
    await importInto(store, 'a.txt');
    await store.close();
    final db = sqlite3.open('$root/library.db');
    db.execute("UPDATE meta SET value = '9' WHERE key = 'schema_version'");
    db.dispose();
    store = await openStore(root, clock);
    expect(store.readOnly, isTrue);
    expect(store.reader.allEntries().length, 1);
    await expectLater(store.write((w, now) => w.createFolder('X', now: now)),
        throwsA(isA<LibraryWriteException>().having((e) => e.error, 'error', LibraryWriteError.readOnly)));
    await store.close();
  });

  test('repairs on open: cycles, live rows without a live parent, orphans and missing files', () async {
    var store = await openStore(root, clock);
    final a = await store.write((w, now) => w.createFolder('A', now: now));
    final b = await store.write((w, now) => w.createFolder('B', parent: a, now: now));
    final lost = await store.write((w, now) => w.createFolder('Lost', now: now));
    final inLost = await importInto(store, 'x.txt', folder: lost);
    await importInto(store, 'x.txt');
    final gone = await importInto(store, 'gone.txt');
    await store.close();

    final db = sqlite3.open('$root/library.db');
    db.execute('UPDATE folders SET parent_id = ? WHERE id = ?', [b.value, a.value]); // A ↔ B cycle
    db.execute('DELETE FROM folders WHERE id = ?', [lost.value]);
    db.dispose();
    File(store.paths.entryFile(gone.id, 'gone.txt')).deleteSync();
    final orphan = EntryId.random();
    Directory(store.paths.entryDir(orphan)).createSync();
    File(store.paths.entryFile(orphan, 'found.mov')).writeAsStringSync('v');
    Directory(store.paths.entryDir(EntryId.random())).createSync(); // empty orphan
    File('${store.paths.importsDir}/stray.part').writeAsStringSync('p');

    store = await openStore(root, clock);
    final report = store.openReport.reconcile!;
    expect(store.openReport.violations, isEmpty);
    expect(report.unavailable, {gone.id}, reason: 'a missing file is marked unavailable, never dropped');
    expect(store.reader.entry(gone.id), isNotNull);
    expect(report.recovered, 1);
    expect(store.reader.entry(orphan)!.displayName, 'found.mov');
    final moved = store.reader.entry(inLost.id)!;
    expect(moved.folderId, store.reader.systemFolder(FolderSystemRole.imported)!.id);
    expect(moved.displayName, 'x (2).txt');
    expect(store.reader.folder(a)!.parentId == null || store.reader.folder(b)!.parentId == null, isTrue);
    expect(File('${store.paths.importsDir}/stray.part').existsSync(), isFalse);
    expect(await store.checkInvariants(), isEmpty);
    await store.close();
  });

  test('the writer runs on a background isolate', () async {
    final store = await LibraryStore.open(root: root, clock: clock.call);
    final folder = await store.write((w, now) => w.createFolder('Iso', now: now));
    final e = await store.write((w, now) => importBytes(w, now, 'a.txt', 'abc'.codeUnits, folder: folder));
    expect(store.reader.entry(e.id)!.folderId, folder, reason: 'the UI-isolate reader sees committed writes');
    await expectLater(store.write((w, now) => w.moveFolder(folder, folder, now: now)),
        throwsA(isA<LibraryWriteException>().having((x) => x.error, 'error', LibraryWriteError.cycle)));
    await store.write((w, now) => w.trashFolder(folder, now: now));
    expect(store.reader.recentlyDeleted().single.id, folder);
    await store.close();
  });
}
