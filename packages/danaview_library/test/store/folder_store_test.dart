// OWNER: HOM-17
//
// The folder store and Recently deleted (BUILD_PLAN HOM-17 acceptance; ARCH v1.2 V2-06, V2-08,
// §5.2–§5.4): folder tree with cycle check, atomic import, rename, move, copy, favourites, recents,
// refs, restore to the original folder / nearest live ancestor / Imported, the 30-day sweep with a
// fake clock (also moved backwards), Empty now, days left, storage use and backup classes.

import 'dart:io';

import 'package:danaview_library/testing.dart';
import 'package:test/test.dart';

import '../support/sqlite_open.dart';
import 'store_harness.dart';

void main() {
  setUpAll(useHostSqlite);
  late String root;
  late FakeLibraryClock clock;
  late LibraryStore store;

  setUp(() async {
    root = tempRoot();
    clock = FakeLibraryClock(t0);
    store = await openStore(root, clock);
    // The store a test reopened (by hand) is closed too, and before the temp root goes: a group
    // `tearDown` would run after `tempRoot`'s deletion, which Windows refuses while library.db is
    // open (FIX-S1Q-A5).
    addTearDown(() => store.close());
  });

  FolderId imported() => store.reader.systemFolder(FolderSystemRole.imported)!.id;

  group('layout and open', () {
    test('creates library.db, files/, imports/ and the Imported folder', () async {
      expect(File('$root/library.db').existsSync(), isTrue);
      expect(Directory('$root/files').existsSync(), isTrue);
      expect(Directory('$root/imports').existsSync(), isTrue);
      expect(store.openReport.outcome, MigrationOutcome.created);
      expect(store.openReport.violations, isEmpty);
      expect(store.reader.childFolders(null).map((f) => f.name), ['Imported']);
      expect(await store.checkInvariants(), isEmpty);
    });

    test('a second open is up to date and keeps the same Imported folder', () async {
      final id = imported();
      await store.close();
      store = await openStore(root, clock);
      expect(store.openReport.outcome, MigrationOutcome.upToDate);
      expect(imported(), id);
    });

    test('the root follows ARCH §5.2 per platform', () {
      expect(libraryRootIn('/support', LibraryRootStyle.appSupport), '/support/DanaviewLibrary');
      expect(libraryRootIn('/data/files', LibraryRootStyle.android), '/data/files/library');
    });

    test('only imports/ is excluded from backups', () async {
      final port = RecordingBackupFlagPort();
      await store.close();
      store = await LibraryStore.open(root: root, clock: clock.call, background: false, backup: port);
      expect(port.calls, [(store.paths.importsDir, true)]);
      expect(store.backupClassOf(store.paths.importsDir), LibraryBackupClass.excluded);
      expect(store.backupClassOf('${store.paths.importsDir}/x.part'), LibraryBackupClass.excluded);
      expect(store.backupClassOf(store.paths.databasePath), LibraryBackupClass.included);
      expect(store.backupClassOf(store.paths.filesDir), LibraryBackupClass.included);
    });
  });

  group('folders', () {
    test('create, nest to any depth, rename with dedupe, move and favourite', () async {
      var parent = await store.write((w, now) => w.createFolder('Trips', now: now));
      final top = parent;
      for (var i = 0; i < 20; i++) {
        parent = await store.write((w, now) => w.createFolder('Level $i', parent: parent, now: now));
      }
      expect(store.reader.pathOf(parent).length, 21);
      final other = await store.write((w, now) => w.createFolder('trips', now: now));
      expect(store.reader.folder(other)!.name, 'trips (2)');
      expect(await store.write((w, now) => w.renameFolder(other, 'Work', now: now)), 'Work');
      await store.write((w, now) => w.moveFolder(other, top, now: now));
      expect(store.reader.folder(other)!.parentId, top);
      await store.write((w, now) => w.setFolderFavourite(other, true));
      expect(store.reader.folder(other)!.isFavourite, isTrue);
      await store.write((w, now) => w.setFolderSort(other, 'size', descending: true));
      expect(store.reader.folder(other)!.sortMode, 'size');
      expect(await store.checkInvariants(), isEmpty);
    });

    test('a folder can not move into itself or a descendant', () async {
      final a = await store.write((w, now) => w.createFolder('A', now: now));
      final b = await store.write((w, now) => w.createFolder('B', parent: a, now: now));
      final c = await store.write((w, now) => w.createFolder('C', parent: b, now: now));
      for (final target in [a, b, c]) {
        await expectLater(
          store.write((w, now) => w.moveFolder(a, target, now: now)),
          throwsA(isA<LibraryWriteException>().having((e) => e.error, 'error', LibraryWriteError.cycle)),
        );
      }
      await store.write((w, now) => w.moveFolder(c, null, now: now));
      expect(store.reader.folder(c)!.parentId, isNull);
    });

    test('system folders refuse rename, move and delete', () async {
      final id = imported();
      for (final op in <LibraryWrite<Object?>>[
        (w, now) => w.renameFolder(id, 'X', now: now),
        (w, now) => w.moveFolder(id, null, now: now),
        (w, now) => w.trashFolder(id, now: now),
      ]) {
        await expectLater(store.write(op), throwsA(isA<LibraryWriteException>()));
      }
    });

    test('names with separators or control characters are refused', () async {
      final e = await importInto(store, 'a.txt');
      for (final bad in ['', '  ', 'a/b', r'a\b', '.', '..', 'x\u0000y', 'é' * 200]) {
        await expectLater(store.write((w, now) => w.renameEntry(e.id, bad, now: now)), throwsA(isA<LibraryWriteException>()), reason: bad);
      }
      await expectLater(store.write((w, now) => w.createFolder('', now: now)), throwsA(isA<LibraryWriteException>()));
    });
  });

  group('entries', () {
    test('import copies into files/<id>/<name>, dedupes names and leaves no part file', () async {
      final a = await importInto(store, 'Report.pdf');
      final b = await importInto(store, 'report.pdf');
      expect(a.folderId, imported());
      expect(a.kind, FileKind.document);
      expect(a.subKind, 'pdf');
      expect(b.displayName, 'report (2).pdf');
      expect(File(store.paths.entryFile(a.id, 'Report.pdf')).readAsStringSync(), 'Report.pdf');
      expect(Directory(store.paths.importsDir).listSync(), isEmpty);
      expect(store.reader.importJobs(), isEmpty);
      expect(store.reader.storageUsage().liveCount, 2);
    });

    test('rename renames the one file in its directory; move is database-only', () async {
      final folder = await store.write((w, now) => w.createFolder('Docs', now: now));
      final e = await importInto(store, 'a.txt');
      await store.write((w, now) => w.renameEntry(e.id, 'b.txt', now: now));
      expect(store.fsNames(e.id), ['b.txt']);
      await store.write((w, now) => w.moveEntries([e.id], folder, now: now));
      expect(store.reader.entry(e.id)!.folderId, folder);
      expect(File(store.paths.entryFile(e.id, 'b.txt')).existsSync(), isTrue);
      final copy = await store.write((w, now) => w.copyEntry(e.id, folder, now: now));
      expect(copy.displayName, 'b (2).txt');
      expect(File(store.paths.entryFile(copy.id, 'b (2).txt')).readAsStringSync(), 'a.txt');
      expect(await store.checkInvariants(), isEmpty);
    });

    test('a move refused partway through leaves every row and file as it was', () async {
      final x = await store.write((w, now) => w.createFolder('X', now: now));
      await importInto(store, 'a.txt', folder: x);
      final a2 = await importInto(store, 'a.txt');
      final b = await importInto(store, 'b.txt');
      await store.write((w, now) => w.trashEntries([b.id], now: now));
      await expectLater(
        store.write((w, now) => w.moveEntries([a2.id, b.id], x, now: now)),
        throwsA(isA<LibraryWriteException>().having((e) => e.error, 'error', LibraryWriteError.trashed)),
      );
      final row = store.reader.entry(a2.id)!;
      expect(row.folderId, imported());
      expect(row.displayName, 'a.txt');
      expect(store.fsNames(a2.id), ['a.txt']);
      expect(File(store.paths.entryFile(a2.id, row.displayName)).existsSync(), isTrue);
      expect(await store.checkInvariants(), isEmpty);
    });

    test('favourites, page queries by kind and folder', () async {
      final photo = await importInto(store, 'beach.jpg');
      await importInto(store, 'clip.mp4');
      await importInto(store, 'notes.txt');
      await store.write((w, now) => w.setEntryFavourite(photo.id, true));
      expect(store.reader.entriesPage(const EntryQuery(kinds: {FileKind.photo})).map((e) => e.id), [photo.id]);
      expect(store.reader.entriesPage(const EntryQuery(favouritesOnly: true)).single.id, photo.id);
      expect(store.reader.countEntries(EntryQuery(folderId: imported())), 3);
      expect(store.reader.entriesPage(const EntryQuery(sort: EntrySortKey.name, descending: false)).map((e) => e.displayName),
          ['beach.jpg', 'clip.mp4', 'notes.txt']);
    });

    test('recents keep the last 50 opened, newest first, and skip trashed entries', () async {
      final ids = <EntryId>[];
      for (var i = 0; i < 55; i++) {
        ids.add((await importInto(store, 'f$i.txt')).id);
        clock.advance(const Duration(seconds: 1));
        await store.write((w, now) => w.markOpened(ids.last, now: now));
      }
      final recents = store.reader.recents();
      expect(recents.length, 50);
      expect(recents.first.id, ids.last);
      expect(recents.last.id, ids[5]);
      await store.write((w, now) => w.trashEntries([ids.last], now: now));
      expect(store.reader.recents().first.id, ids[53]);
      await store.write((w, _) => w.clearRecents());
      expect(store.reader.recents(), isEmpty);
    });

    test('refs count distinct projects and photo recipes, also under a folder', () async {
      final folder = await store.write((w, now) => w.createFolder('Shoot', now: now));
      final a = await importInto(store, 'a.mov', folder: folder);
      final b = await importInto(store, 'b.jpg', folder: folder);
      await store.write((w, _) {
        w.addRef(a.id, RefHolder.project('p1'));
        w.addRef(b.id, RefHolder.project('p1'));
        w.addRef(b.id, RefHolder.project('p2'));
        w.addRef(b.id, RefHolder.photo('ph1'));
      });
      final usage = store.reader.refUsage(folders: [folder]);
      expect((usage.projects, usage.photos), (2, 1));
      expect(store.reader.holdersOf(b.id).length, 3);
      await store.write((w, _) => w.removeHolder(RefHolder.project('p1')));
      expect(store.reader.refUsage(entries: [a.id]).isEmpty, isTrue);
    });
  });

  group('Recently deleted', () {
    test('a deleted file restores to its folder', () async {
      final folder = await store.write((w, now) => w.createFolder('Docs', now: now));
      final e = await importInto(store, 'a.pdf', folder: folder);
      await store.write((w, now) => w.trashEntries([e.id], now: now));
      final trashed = store.reader.entry(e.id)!;
      expect(trashed.trashedAt, t0);
      expect(trashed.expiresAt, t0.add(const Duration(days: 30)));
      expect(store.reader.countEntries(const EntryQuery()), 0);
      expect(store.reader.recentlyDeleted().single.id, e.id);
      expect(File(store.paths.entryFile(e.id, 'a.pdf')).existsSync(), isTrue, reason: 'files stay until purge');
      final dest = await store.write((w, now) => w.restore(e.id, now: now));
      expect(dest, folder);
      expect(store.reader.entry(e.id)!.isTrashed, isFalse);
      expect(store.reader.recentlyDeleted(), isEmpty);
    });

    test('a deleted folder restores its subtree, and only what was deleted with it', () async {
      final a = await store.write((w, now) => w.createFolder('A', now: now));
      final b = await store.write((w, now) => w.createFolder('B', parent: a, now: now));
      final early = await importInto(store, 'early.txt', folder: b);
      final x = await importInto(store, 'x.txt', folder: a);
      final y = await importInto(store, 'y.txt', folder: b);
      await store.write((w, now) => w.trashEntries([early.id], now: now));
      clock.advance(const Duration(days: 2));
      await store.write((w, now) => w.trashFolder(a, now: now));
      expect(store.reader.folder(b)!.expiresAt, store.reader.folder(a)!.expiresAt);
      expect(store.reader.entry(y.id)!.expiresAt, store.reader.folder(a)!.expiresAt);
      final rows = store.reader.recentlyDeleted();
      expect(rows.map((r) => r.id), [a, early.id]);
      expect(rows.first.itemCount, 2);
      expect(store.reader.childFolders(null).map((f) => f.name), ['Imported']);

      await store.write((w, now) => w.restore(a, now: now));
      expect(store.reader.folder(a)!.isTrashed, isFalse);
      expect(store.reader.folder(b)!.isTrashed, isFalse);
      expect(store.reader.entry(x.id)!.isTrashed, isFalse);
      expect(store.reader.entry(y.id)!.isTrashed, isFalse);
      expect(store.reader.entry(early.id)!.isTrashed, isTrue, reason: 'deleted earlier on its own');
      expect(await store.checkInvariants(), isEmpty);
    });

    test('restore into a vanished folder lands in Imported', () async {
      final a = await store.write((w, now) => w.createFolder('A', now: now));
      final e = await importInto(store, 'e.txt', folder: a);
      await store.write((w, now) => w.trashFolder(a, now: now));
      // The folder is still trashed: its entry restores to Imported (no live ancestor).
      expect(await store.write((w, now) => w.restore(e.id, now: now)), imported());
      // And when the folder row is gone entirely.
      final b = await store.write((w, now) => w.createFolder('B', now: now));
      final f = await importInto(store, 'e.txt', folder: b);
      await store.write((w, now) => w.trashEntries([f.id], now: now));
      await store.write((w, _) => w.db.execute('DELETE FROM folders WHERE id = ?', [b.value]));
      expect(await store.write((w, now) => w.restore(f.id, now: now)), imported());
      expect(store.reader.entry(f.id)!.displayName, 'e (2).txt');
      expect(File(store.paths.entryFile(f.id, 'e (2).txt')).existsSync(), isTrue);
    });

    test('a child of a trashed folder restores into the nearest live ancestor', () async {
      final a = await store.write((w, now) => w.createFolder('A', now: now));
      final b = await store.write((w, now) => w.createFolder('B', parent: a, now: now));
      final c = await store.write((w, now) => w.createFolder('C', parent: b, now: now));
      final e = await importInto(store, 'e.txt', folder: c);
      await store.write((w, now) => w.trashFolder(b, now: now));
      expect(await store.write((w, now) => w.restore(e.id, now: now)), a);
      expect(await store.write((w, now) => w.restore(c, now: now)), a);
    });

    test('with a fake clock an item older than 30 days is purged; days left counts down', () async {
      final e = await importInto(store, 'old.txt');
      final keep = await importInto(store, 'new.txt');
      await store.write((w, now) => w.trashEntries([e.id], now: now));
      expect(store.reader.recentlyDeleted().single.daysLeft(clock()), 30);
      clock.advance(const Duration(days: 10, hours: 1));
      expect(store.reader.recentlyDeleted().single.daysLeft(clock()), 20);
      await store.write((w, now) => w.trashEntries([keep.id], now: now));
      clock.advance(const Duration(days: 19, hours: 22));
      expect((await store.sweepNow()).isEmpty, isTrue, reason: 'one hour short of 30 days');
      clock.advance(const Duration(hours: 1));
      final result = await store.sweepNow();
      expect(result.entries, 1);
      expect(store.reader.entry(e.id), isNull);
      expect(Directory(store.paths.entryDir(e.id)).existsSync(), isFalse);
      expect(store.reader.entry(keep.id)!.isTrashed, isTrue);
      expect(await store.checkInvariants(), isEmpty);
    });

    test('the launch sweep purges expired items', () async {
      final e = await importInto(store, 'old.txt');
      await store.write((w, now) => w.trashEntries([e.id], now: now));
      await store.close();
      clock.advance(const Duration(days: 31));
      store = await openStore(root, clock);
      expect(store.openReport.sweep.entries, 1);
      expect(store.reader.entry(e.id), isNull);
    });

    test('a clock set backwards does not change expires_at and purges nothing early', () async {
      final e = await importInto(store, 'a.txt');
      await store.write((w, now) => w.trashEntries([e.id], now: now));
      final expires = store.reader.entry(e.id)!.expiresAt!;
      clock.advance(const Duration(days: -400));
      expect((await store.sweepNow()).isEmpty, isTrue);
      expect(store.reader.entry(e.id)!.expiresAt, expires);
      clock.set(expires.subtract(const Duration(seconds: 1)));
      expect((await store.sweepNow()).isEmpty, isTrue);
      clock.set(expires);
      expect((await store.sweepNow()).entries, 1);
    });

    test('Empty now removes everything in Recently deleted', () async {
      final a = await store.write((w, now) => w.createFolder('A', now: now));
      final inA = await importInto(store, 'x.txt', folder: a);
      final loose = await importInto(store, 'y.txt');
      final live = await importInto(store, 'z.txt');
      await store.write((w, now) => w.addRef(loose.id, RefHolder.project('p')));
      await store.write((w, now) => w.trashEntries([loose.id], now: now));
      await store.write((w, now) => w.trashFolder(a, now: now));
      final result = await store.write((w, _) => w.emptyTrash());
      expect((result.entries, result.folders), (2, 1));
      expect(store.reader.recentlyDeleted(), isEmpty);
      expect(store.reader.entry(inA.id), isNull);
      expect(store.reader.folder(a), isNull);
      expect(store.reader.holdersOf(loose.id), isEmpty);
      expect(store.reader.entry(live.id), isNotNull);
      expect(store.reader.storageUsage().trashedBytes, 0);
      expect(store.fsDirs(), [live.id.value]);
      expect(await store.checkInvariants(), isEmpty);
    });

    test('trashed files still count toward storage', () async {
      final e = await importInto(store, 'a.bin', bytes: List.filled(1000, 1));
      await importInto(store, 'b.bin', bytes: List.filled(500, 1));
      await store.write((w, now) => w.trashEntries([e.id], now: now));
      final usage = store.reader.storageUsage();
      expect((usage.liveBytes, usage.trashedBytes, usage.totalBytes), (500, 1000, 1500));
    });

    test('the daily sweep runs on a timer while started', () async {
      store.startDailySweep(interval: const Duration(milliseconds: 20));
      expect(store.dailySweepRunning, isTrue);
      final e = await importInto(store, 'a.txt');
      await store.write((w, now) => w.trashEntries([e.id], now: now));
      clock.advance(const Duration(days: 30));
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(store.reader.entry(e.id), isNull);
      store.stopDailySweep();
      expect(store.dailySweepRunning, isFalse);
    });

    test('changes fire after every write', () async {
      var n = 0;
      final sub = store.changes.listen((_) => n++);
      await store.write((w, now) => w.createFolder('A', now: now));
      await importInto(store, 'a.txt');
      expect(n, 2);
      await sub.cancel();
    });
  });
}

extension on LibraryStore {
  List<String> fsNames(EntryId id) =>
      Directory(paths.entryDir(id)).listSync().map((e) => e.path.split(Platform.pathSeparator).last).toList();

  List<String> fsDirs() => Directory(paths.filesDir).listSync().map((e) => e.path.split(Platform.pathSeparator).last).toList()..sort();
}
