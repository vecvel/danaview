// OWNER: HOM-19
//
// BUILD_PLAN HOM-19: "sort stable and remembered". Natural name order (the 1.1 rule), every mode
// in both directions, stability under equal keys (also descending), the stored forms, and the sort
// remembered per Danaview folder (library.db, survives a reopen) and per named list (preferences).

import 'dart:math';

import 'package:danaview_library/testing.dart';
import 'package:test/test.dart';

import '../support/sqlite_open.dart';
import 'organise_harness.dart';

FileEntry _e(String id, String name, {int size = 0, int added = 0, int modified = 0, FileKind kind = FileKind.photo, String? subKind}) => FileEntry(
      id: EntryId.parse('fe_$id'),
      folderId: FolderId.parse('fd_f'),
      displayName: name,
      kind: kind,
      subKind: subKind,
      sizeBytes: size,
      addedAt: DateTime.utc(2026, 1, 1).add(Duration(minutes: added)),
      modifiedAt: DateTime.utc(2026, 1, 1).add(Duration(minutes: modified)),
      sourceHint: SourceHint.files,
    );

/// The 1.1 `NaturalSortComparator.compare`, verbatim in logic (danaview_data can't be imported
/// here; test/v12/organise/ checks against the real one).
int _reference11(String a, String b) {
  final re = RegExp(r'(\d+|\D+)');
  final ca = re.allMatches(a).map((m) => m.group(0)!).toList();
  final cb = re.allMatches(b).map((m) => m.group(0)!).toList();
  final n = ca.length < cb.length ? ca.length : cb.length;
  for (var i = 0; i < n; i++) {
    final x = ca[i];
    final y = cb[i];
    if (int.tryParse(x) != null && int.tryParse(y) != null) {
      final c = BigInt.parse(x).compareTo(BigInt.parse(y));
      if (c != 0) return c;
    } else {
      final c = x.toLowerCase().compareTo(y.toLowerCase());
      if (c != 0) return c;
    }
  }
  return ca.length.compareTo(cb.length);
}

List<String> _names(Iterable<FileEntry> es) => [for (final e in es) e.displayName];

void main() {
  setUpAll(useHostSqlite);
  group('natural order', () {
    test('numbers compare by value, text case-insensitively, shorter first', () {
      final names = ['Episode 10', 'episode 2', 'Episode 1', 'Episode', 'Episode 02b', 'a100', 'A20', 'b'];
      names.sort(compareNatural);
      expect(names, ['A20', 'a100', 'b', 'Episode', 'Episode 1', 'episode 2', 'Episode 02b', 'Episode 10']);
    });

    test('matches the 1.1 comparator, also for huge digit runs', () {
      final r = Random(7);
      const alphabet = ['a', 'B', '1', '0', '9', ' ', '-', 'é', '12345678901234567890123'];
      String word() => List.generate(r.nextInt(6), (_) => alphabet[r.nextInt(alphabet.length)]).join();
      for (var i = 0; i < 2000; i++) {
        final a = word();
        final b = word();
        expect(compareNatural(a, b).sign, _reference11(a, b).sign, reason: '"$a" vs "$b"');
        expect(compareNatural(a, b).sign, -compareNatural(b, a).sign);
      }
    });
  });

  group('sortEntries', () {
    final rows = [
      _e('a', 'Clip 10.mov', size: 30, added: 3, modified: 1, kind: FileKind.video),
      _e('b', 'clip 2.mov', size: 10, added: 1, modified: 3, kind: FileKind.video),
      _e('c', 'Report.pdf', size: 20, added: 2, modified: 2, kind: FileKind.document, subKind: 'pdf'),
      _e('d', 'Beach.jpg', size: 10, added: 4, modified: 0),
    ];

    test('every mode, both directions', () {
      expect(_names(sortEntries(rows, const LibrarySort(LibrarySortMode.name))), ['Beach.jpg', 'clip 2.mov', 'Clip 10.mov', 'Report.pdf']);
      expect(_names(sortEntries(rows, const LibrarySort(LibrarySortMode.name, descending: true))), ['Report.pdf', 'Clip 10.mov', 'clip 2.mov', 'Beach.jpg']);
      expect(_names(sortEntries(rows, const LibrarySort(LibrarySortMode.dateAdded))), ['clip 2.mov', 'Report.pdf', 'Clip 10.mov', 'Beach.jpg']);
      expect(_names(sortEntries(rows, LibrarySort.recentFirst)), ['Beach.jpg', 'Clip 10.mov', 'Report.pdf', 'clip 2.mov']);
      expect(_names(sortEntries(rows, const LibrarySort(LibrarySortMode.dateModified))), ['Beach.jpg', 'Clip 10.mov', 'Report.pdf', 'clip 2.mov']);
      // Type: video, photo, document (FileKind order); a type keeps name order inside it.
      expect(_names(sortEntries(rows, const LibrarySort(LibrarySortMode.type))), ['clip 2.mov', 'Clip 10.mov', 'Beach.jpg', 'Report.pdf']);
      expect(_names(sortEntries(rows, const LibrarySort(LibrarySortMode.type, descending: true))), ['Report.pdf', 'Beach.jpg', 'Clip 10.mov', 'clip 2.mov']);
    });

    test('equal keys keep their input order, ascending and descending', () {
      // b and d have size 10; c and an extra row have size 20.
      final more = [...rows, _e('e', 'Another.jpg', size: 20)];
      expect(_names(sortEntries(more, const LibrarySort(LibrarySortMode.size))), ['clip 2.mov', 'Beach.jpg', 'Report.pdf', 'Another.jpg', 'Clip 10.mov']);
      expect(_names(sortEntries(more, const LibrarySort(LibrarySortMode.size, descending: true))), ['Clip 10.mov', 'Report.pdf', 'Another.jpg', 'clip 2.mov', 'Beach.jpg']);
      // Reversed input: ties follow the new input order.
      expect(_names(sortEntries(more.reversed, const LibrarySort(LibrarySortMode.size))), ['Beach.jpg', 'clip 2.mov', 'Another.jpg', 'Report.pdf', 'Clip 10.mov']);
    });

    test('stable over many equal keys (property)', () {
      final r = Random(3);
      final many = [for (var i = 0; i < 500; i++) _e('x$i', 'n${r.nextInt(5)}', size: r.nextInt(4), added: r.nextInt(3))];
      for (final sort in [
        for (final m in LibrarySortMode.values) ...[LibrarySort(m), LibrarySort(m, descending: true)],
      ]) {
        final sorted = sortEntries(many, sort);
        final pos = {for (var i = 0; i < many.length; i++) many[i].id: i};
        for (var i = 1; i < sorted.length; i++) {
          final a = sorted[i - 1];
          final b = sorted[i];
          final sameKey = switch (sort.mode) {
            LibrarySortMode.name => compareNatural(a.displayName, b.displayName) == 0,
            LibrarySortMode.size => a.sizeBytes == b.sizeBytes,
            LibrarySortMode.dateAdded => a.addedAt == b.addedAt,
            LibrarySortMode.dateModified => a.modifiedAt == b.modifiedAt,
            LibrarySortMode.type => compareNatural(a.displayName, b.displayName) == 0,
          };
          if (sameKey) expect(pos[a.id]! < pos[b.id]!, isTrue, reason: '$sort at $i');
        }
        // Sorting the sorted list again changes nothing.
        expect(sortEntries(sorted, sort), sorted);
      }
    });
  });

  group('stored forms', () {
    test('encode / decode round-trip and reject junk', () {
      for (final m in LibrarySortMode.values) {
        for (final d in [false, true]) {
          final s = LibrarySort(m, descending: d);
          expect(LibrarySort.tryDecode(s.encode()), s);
        }
      }
      for (final junk in [null, '', 'name', 'name:up', 'colour:asc', ':asc']) {
        expect(LibrarySort.tryDecode(junk), isNull, reason: '$junk');
      }
    });

    test('withMode picks the usual direction, reversed flips it', () {
      expect(LibrarySort.folderDefault.withMode(LibrarySortMode.size), const LibrarySort(LibrarySortMode.size, descending: true));
      expect(LibrarySort.folderDefault.withMode(LibrarySortMode.name), LibrarySort.folderDefault);
      expect(LibrarySort.folderDefault.reversed, const LibrarySort(LibrarySortMode.name, descending: true));
    });
  });

  group('remembered per folder', () {
    test('a Danaview folder keeps its sort in library.db across a reopen; folders are independent', () async {
      final root = tempRoot();
      var store = await LibraryStore.open(root: root, clock: FakeLibraryClock(t0).call, background: false);
      addTearDown(() => store.close()); // whichever store is open when the test ends (FIX-S1Q-A5)
      final a = await folderNamed(store, 'A');
      final b = await folderNamed(store, 'B');
      var org = LibraryOrganiser(store);
      expect(org.sortOf(SortScope.folder(a)), LibrarySort.folderDefault);
      await org.setSort(SortScope.folder(a), const LibrarySort(LibrarySortMode.size, descending: true));
      expect(org.sortOf(SortScope.folder(a)), const LibrarySort(LibrarySortMode.size, descending: true));
      expect(org.sortOf(SortScope.folder(b)), LibrarySort.folderDefault);
      await store.close();

      store = await LibraryStore.open(root: root, clock: FakeLibraryClock(t0).call, background: false);
      org = LibraryOrganiser(store);
      expect(org.sortOf(SortScope.folder(a)), const LibrarySort(LibrarySortMode.size, descending: true));
      expect(org.sortOf(SortScope.folder(b)), LibrarySort.folderDefault);
      // A rename keeps it.
      await store.write((w, now) => w.renameFolder(a, 'A renamed', now: now));
      expect(org.sortOf(SortScope.folder(a)), const LibrarySort(LibrarySortMode.size, descending: true));
      await store.close();
    });

    test('named lists keep their sort in preferences, with their own fallback', () async {
      final store = await openTestStore(FakeLibraryClock(t0));
      final prefs = InMemorySortPreferenceStore();
      final org = LibraryOrganiser(store, sortPreferences: prefs);
      expect(org.sortOf(NamedSortScope.allTab, fallback: LibrarySort.recentFirst), LibrarySort.recentFirst);
      await org.setSort(NamedSortScope.allTab, const LibrarySort(LibrarySortMode.name));
      await org.setSort(NamedSortScope.linkedFolder('/x/Movies'), const LibrarySort(LibrarySortMode.size));
      expect(prefs.values, {'organise.sort.tab:all': 'name:asc', 'organise.sort.linked:/x/Movies': 'size:asc'});
      // A second organiser over the same preferences (the next launch) reads them back.
      final again = LibraryOrganiser(store, sortPreferences: prefs);
      expect(again.sortOf(NamedSortScope.allTab, fallback: LibrarySort.recentFirst), const LibrarySort(LibrarySortMode.name));
      expect(again.sortOf(NamedSortScope.photosTab, fallback: LibrarySort.recentFirst), LibrarySort.recentFirst);
      // An unreadable value falls back.
      await prefs.write(NamedSortScope.videosTab.preferenceKey, 'garbage');
      expect(again.sortOf(NamedSortScope.videosTab), LibrarySort.folderDefault);
    });

    test('folderContents applies the remembered sort to files and subfolders, folders first', () async {
      final clock = FakeLibraryClock(t0);
      final store = await openTestStore(clock);
      final org = LibraryOrganiser(store);
      final f = await folderNamed(store, 'Trip');
      await folderNamed(store, 'day 10', parent: f);
      await folderNamed(store, 'day 9', parent: f);
      for (final (name, size) in [('IMG 10.jpg', 5), ('img 9.jpg', 50), ('IMG 100.jpg', 5)]) {
        clock.advance(const Duration(minutes: 1));
        await importNamed(store, name, folder: f, size: size);
      }
      var c = org.folderContents(f);
      expect([for (final x in c.folders) x.name], ['day 9', 'day 10']);
      expect(_names(c.entries), ['img 9.jpg', 'IMG 10.jpg', 'IMG 100.jpg']);
      await org.setSort(SortScope.folder(f), const LibrarySort(LibrarySortMode.size));
      c = org.folderContents(f);
      // Equal sizes keep the date-added input order.
      expect(_names(c.entries), ['IMG 10.jpg', 'IMG 100.jpg', 'img 9.jpg']);
    });
  });
}
