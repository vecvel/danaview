// OWNER: HOM-17
//
// FIX-S2Q-2: the app runs the writer on its own isolate (`background: true`), so every op the store
// sends there must capture only sendable values. `checkInvariants` used to capture the store (and its
// ReceivePort) and threw "object is unsendable"; these tests run it through the isolate writer.
//
// FIX-S1Q-A5: `close` returns only once no connection holds library.db any more, on either writer.
// Windows refuses to delete or move an open file, so a close that returned while the writer isolate
// still held the database left the library root undeletable there. Checked portably: a connection
// can take SQLite's exclusive lock only when it is the last one on the file.

import 'dart:io';

import 'package:danaview_library/testing.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

import '../support/sqlite_open.dart';
import 'store_harness.dart';

void main() {
  setUpAll(useHostSqlite);
  test('checkInvariants runs through the isolate writer', () async {
    final root = tempRoot();
    final store = await LibraryStore.open(root: root, clock: FakeLibraryClock(t0).call);
    addTearDown(store.close);
    expect(await store.checkInvariants(), isEmpty);
    await importInto(store, 'a.pdf');
    await store.sweepNow();
    expect(await store.checkInvariants(), isEmpty);
  });

  test('checkInvariants through the isolate writer skips entries known unavailable', () async {
    final root = tempRoot();
    final clock = FakeLibraryClock(t0);
    final first = await openStore(root, clock);
    final gone = await importInto(first, 'gone.png');
    await first.close();
    File(LibraryPaths(root).entryFile(gone.id, gone.displayName)).deleteSync();

    final store = await LibraryStore.open(root: root, clock: clock.call);
    addTearDown(store.close);
    expect(store.unavailable, {gone.id});
    expect(await store.checkInvariants(), isEmpty);
  });

  for (final background in [false, true]) {
    test('close releases library.db before it returns (${background ? 'isolate' : 'in-process'} writer)', () async {
      final root = tempRoot();
      final store = await LibraryStore.open(root: root, clock: FakeLibraryClock(t0).call, background: background);
      await importInto(store, 'a.pdf');
      final path = LibraryPaths(root).databasePath;
      expect(_lastConnection(path), isFalse, reason: 'the store holds library.db while open');
      await store.close();
      expect(_lastConnection(path), isTrue, reason: 'a connection still held library.db after close');
    });
  }
}

/// True when a new connection can take SQLite's exclusive lock on [path], i.e. no other
/// connection has the (WAL-mode) database open.
bool _lastConnection(String path) {
  final db = sqlite3.open(path);
  try {
    db.execute('PRAGMA locking_mode = EXCLUSIVE');
    db.execute('BEGIN EXCLUSIVE');
    db.execute('COMMIT');
    return true;
  } on SqliteException {
    return false;
  } finally {
    db.dispose();
  }
}
