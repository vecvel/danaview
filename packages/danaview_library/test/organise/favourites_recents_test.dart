// OWNER: HOM-19
//
// BUILD_PLAN HOM-19: favourites (files and folders), "recents capped at 50" and "trashed items
// never appear" (V2-08), over a real library.db. Recents never sync: they live only in library.db.

import 'package:danaview_library/testing.dart';
import 'package:test/test.dart';

import '../support/sqlite_open.dart';
import 'organise_harness.dart';

void main() {
  setUpAll(useHostSqlite);
  group('favourites', () {
    test('files and folders star, unstar and toggle; folders list first', () async {
      final clock = FakeLibraryClock(t0);
      final store = await openTestStore(clock);
      final org = LibraryOrganiser(store);
      final trip = await folderNamed(store, 'Trip');
      final a = await importNamed(store, 'b.jpg');
      clock.advance(const Duration(minutes: 1));
      final b = await importNamed(store, 'a.pdf', folder: trip);
      expect(org.favourites(), isEmpty);

      await org.setFavourite(a.id, true);
      await org.setFavourite(trip, true);
      expect(await org.toggleFavourite(b.id), isTrue);
      expect(org.isFavourite(a.id), isTrue);
      expect(org.isFavourite(trip), isTrue);
      final favs = org.favourites();
      expect(favs.first, isA<FavouriteFolder>());
      expect([for (final f in favs) f.name], ['Trip', 'a.pdf', 'b.jpg']);

      expect(await org.toggleFavourite(b.id), isFalse);
      await org.setFavourite(trip, false);
      expect([for (final f in org.favourites()) f.id], [a.id]);
      expect(store.reader.countEntries(const EntryQuery(favouritesOnly: true)), 1);
    });

    test('the Favourites file order follows its remembered sort', () async {
      final clock = FakeLibraryClock(t0);
      final store = await openTestStore(clock);
      final org = LibraryOrganiser(store);
      for (final name in ['File 10.txt', 'File 2.txt', 'File 1.txt']) {
        clock.advance(const Duration(minutes: 1));
        await org.setFavourite((await importNamed(store, name)).id, true);
      }
      expect([for (final f in org.favourites()) f.name], ['File 1.txt', 'File 2.txt', 'File 10.txt']);
      await org.setSort(NamedSortScope.favourites, const LibrarySort(LibrarySortMode.name));
      expect([for (final f in org.favourites()) f.name], ['File 1.txt', 'File 2.txt', 'File 10.txt']);
      await org.setSort(NamedSortScope.favourites, const LibrarySort(LibrarySortMode.dateAdded));
      expect([for (final f in org.favourites()) f.name], ['File 10.txt', 'File 2.txt', 'File 1.txt']);
    });

    test('linked and system items are refused (read-only sources)', () async {
      final store = await openTestStore(FakeLibraryClock(t0));
      final org = LibraryOrganiser(store);
      expect(() => org.setFavourite(PhotoKitId.of('ABC/L0/001'), true), throwsArgumentError);
      expect(() => org.setFavourite(LinkedItemId.of('root1', 'a/b.mp4'), true), throwsArgumentError);
      expect(org.isFavourite(MediaStoreId.of(4)), isFalse);
    });

    test('trashed favourites disappear and come back on restore', () async {
      final store = await openTestStore(FakeLibraryClock(t0));
      final org = LibraryOrganiser(store);
      final trip = await folderNamed(store, 'Trip');
      final inside = await importNamed(store, 'in.jpg', folder: trip);
      final loose = await importNamed(store, 'loose.jpg');
      await org.setFavourite(trip, true);
      await org.setFavourite(inside.id, true);
      await org.setFavourite(loose.id, true);
      expect(org.favourites(), hasLength(3));

      await store.write((w, now) => w.trashFolder(trip, now: now));
      await store.write((w, now) => w.trashEntries([loose.id], now: now));
      expect(org.favourites(), isEmpty);
      expect(org.isFavourite(trip), isFalse);
      expect(org.isFavourite(inside.id), isFalse);

      await store.write((w, now) => w.restore(trip, now: now));
      expect([for (final f in org.favourites()) f.name], ['Trip', 'in.jpg']);
    });
  });

  group('recents', () {
    test('newest first, re-opening moves to the top, capped at 50, Clear empties', () async {
      final clock = FakeLibraryClock(t0);
      final store = await openTestStore(clock);
      final org = LibraryOrganiser(store);
      final entries = <FileEntry>[];
      for (var i = 0; i < 60; i++) {
        entries.add(await importNamed(store, 'f$i.txt'));
      }
      for (final e in entries) {
        clock.advance(const Duration(seconds: 1));
        await org.markOpened(e.id);
      }
      var recents = org.recents();
      expect(recents, hasLength(recentsCap));
      expect(recentsCap, 50);
      expect(recents.first.displayName, 'f59.txt');
      expect(recents.last.displayName, 'f10.txt');
      expect(store.reader.db.select('SELECT COUNT(*) AS n FROM recents').first['n'], 50);

      clock.advance(const Duration(seconds: 1));
      await org.markOpened(entries[20].id);
      recents = org.recents();
      expect(recents.first.displayName, 'f20.txt');
      expect(recents, hasLength(50));
      expect(recents.where((e) => e.displayName == 'f20.txt'), hasLength(1));

      await org.clearRecents();
      expect(org.recents(), isEmpty);
    });

    test('trashed files never appear in recents', () async {
      final clock = FakeLibraryClock(t0);
      final store = await openTestStore(clock);
      final org = LibraryOrganiser(store);
      final trip = await folderNamed(store, 'Trip');
      final a = await importNamed(store, 'a.jpg', folder: trip);
      final b = await importNamed(store, 'b.jpg');
      final c = await importNamed(store, 'c.jpg');
      for (final e in [a, b, c]) {
        clock.advance(const Duration(seconds: 1));
        await org.markOpened(e.id);
      }
      await store.write((w, now) => w.trashEntries([b.id], now: now));
      await store.write((w, now) => w.trashFolder(trip, now: now));
      expect([for (final e in org.recents()) e.displayName], ['c.jpg']);
      // Opening a trashed file is refused by the store (no viewer opens one).
      expect(() => org.markOpened(b.id), throwsA(isA<LibraryWriteException>()));
      // After the purge nothing dangles.
      clock.advance(const Duration(days: 31));
      await store.sweepNow();
      expect([for (final e in org.recents()) e.displayName], ['c.jpg']);
    });
  });
}
