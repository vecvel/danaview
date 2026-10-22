// OWNER: HOM-17
//
// FIX-S2Q-2: the app runs the writer on its own isolate (`background: true`), so every op the store
// sends there must capture only sendable values. `checkInvariants` used to capture the store (and its
// ReceivePort) and threw "object is unsendable"; these tests run it through the isolate writer.

import 'dart:io';

import 'package:danaview_library/testing.dart';
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
}
