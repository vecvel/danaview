// OWNER: HOM-19
//
// BUILD_PLAN HOM-19: as-you-type name search over names, folder names and types across Danaview
// folders, linked folders and the system library; ranks; the kind and folder filters; refining
// while typing equals a full scan (property); "trashed items never appear" (V2-08); the
// SearchBackend hook.

import 'dart:isolate';
import 'dart:math';

import 'package:danaview_library/testing.dart';
import 'package:test/test.dart';

import '../support/sqlite_open.dart';
import 'organise_harness.dart';

SearchItem _file(String id, String name, {FileKind kind = FileKind.photo, String? subKind, String? folder, SearchOrigin origin = SearchOrigin.danaview}) =>
    SearchItem(id: ItemId.opaque('/x/$id'), name: name, origin: origin, kind: kind, subKind: subKind, folderName: folder);

List<String> _names(SearchResults r) => [for (final h in r.hits) h.item.name];

void main() {
  setUpAll(useHostSqlite);
  group('matching and ranks', () {
    late NameIndex index;
    setUp(() {
      index = NameIndex()
        ..replaceSource('a', [
          _file('1', 'Holiday 2023.jpg', folder: 'Trips'),
          _file('2', 'My holiday.mov', kind: FileKind.video, folder: 'Videos'),
          _file('3', 'Budget.pdf', kind: FileKind.document, subKind: 'pdf', folder: 'Holiday plans'),
          _file('4', 'bholidayx.txt', kind: FileKind.document, subKind: 'text'),
          _file('5', 'Notes.docx', kind: FileKind.document, subKind: 'word', folder: 'Work'),
          const SearchItem(id: ItemId.opaque('/x/f'), name: 'Holiday plans', origin: SearchOrigin.danaview),
        ]);
    });

    test('name prefix, then word start, then substring, then folder, then type', () {
      final r = index.search(const SearchQuery('holiday'));
      expect(_names(r), ['Holiday 2023.jpg', 'Holiday plans', 'My holiday.mov', 'bholidayx.txt', 'Budget.pdf']);
      expect([for (final h in r.hits) h.match], [
        SearchMatch.namePrefix,
        SearchMatch.namePrefix,
        SearchMatch.nameWord,
        SearchMatch.name,
        SearchMatch.folder,
      ]);
      expect(r.total, 5);
      expect(r.backend, NameSearchBackend.backendId);
    });

    test('types match by kind, plural, sub-kind, label and extension', () {
      expect(_names(index.search(const SearchQuery('pdf'))), ['Budget.pdf']);
      expect(_names(index.search(const SearchQuery('word'))), ['Notes.docx']);
      expect(_names(index.search(const SearchQuery('docx'))), ['Notes.docx']);
      expect(_names(index.search(const SearchQuery('videos'))), ['My holiday.mov']);
      expect(_names(index.search(const SearchQuery('csv'))), ['bholidayx.txt']);
      expect(_names(index.search(const SearchQuery('folder'))), ['Holiday plans']);
      expect({for (final h in index.search(const SearchQuery('documents')).hits) h.match}, {SearchMatch.type});
    });

    test('every word must match somewhere; case and spacing do not matter', () {
      expect(_names(index.search(const SearchQuery('  HOLIDAY   video '))), ['My holiday.mov']);
      expect(_names(index.search(const SearchQuery('budget holiday'))), ['Budget.pdf']);
      expect(index.search(const SearchQuery('holiday zebra')).hits, isEmpty);
      expect(index.search(const SearchQuery('   ')).hits, isEmpty);
    });

    test('kind filter, folders toggle and limit', () {
      expect(_names(index.search(const SearchQuery('holiday', kinds: {FileKind.video}, includeFolders: false))), ['My holiday.mov']);
      expect(_names(index.search(const SearchQuery('holiday', includeFolders: false))), isNot(contains('Holiday plans')));
      final limited = index.search(const SearchQuery('holiday', limit: 2));
      expect(_names(limited), ['Holiday 2023.jpg', 'Holiday plans']);
      expect(limited.total, 5);
      expect(limited.truncated, isTrue);
    });

    test('ties inside a rank are in natural name order', () {
      index.replaceSource('b', [for (final n in ['Clip 10', 'clip 9', 'Clip 1']) _file(n, n)]);
      expect(_names(index.search(const SearchQuery('clip'))), ['Clip 1', 'clip 9', 'Clip 10']);
    });

    test('sources replace and drop independently', () {
      index.replaceSource('linked', [_file('l', 'Holiday linked.mp4', kind: FileKind.video, origin: SearchOrigin.linked)]);
      index.replaceSource('system', [_file('s', 'IMG_holiday.HEIC', origin: SearchOrigin.system)]);
      final origins = {for (final h in index.search(const SearchQuery('holiday')).hits) h.item.origin};
      expect(origins, {SearchOrigin.danaview, SearchOrigin.linked, SearchOrigin.system});
      index.removeSource('system');
      expect(index.search(const SearchQuery('img_')).hits, isEmpty);
      expect(index.sourceIds.toSet(), {'a', 'linked'});
    });
  });

  test('refining while typing returns exactly what a fresh scan returns (property)', () {
    final r = Random(11);
    const syllables = ['ho', 'li', 'day', 'pdf', 'cl', 'ip', ' ', '1', '2', 'é', 'Do', 'c'];
    String name() => List.generate(1 + r.nextInt(5), (_) => syllables[r.nextInt(syllables.length)]).join();
    final items = [
      for (var i = 0; i < 400; i++)
        _file('$i', name(), kind: FileKind.values[r.nextInt(4)], subKind: r.nextBool() ? 'pdf' : null, folder: r.nextBool() ? name() : null),
    ];
    final typing = NameIndex()..replaceSource('s', items);
    for (var round = 0; round < 60; round++) {
      final target = '${name()} ${r.nextBool() ? name() : ''}';
      for (var n = 1; n <= target.length; n++) {
        final q = SearchQuery(target.substring(0, n), limit: 1000);
        final fresh = (NameIndex()..replaceSource('s', items)).search(q);
        final typed = typing.search(q);
        expect(typed.total, fresh.total, reason: '"${q.text}"');
        expect(typed.hits, fresh.hits, reason: '"${q.text}"');
      }
      // Deleting characters (backspace) also matches a fresh scan.
      for (var n = target.length; n >= 1; n--) {
        final q = SearchQuery(target.substring(0, n), limit: 1000);
        expect(typing.search(q).hits, (NameIndex()..replaceSource('s', items)).search(q).hits);
      }
    }
  });

  group('over the library', () {
    test('Danaview files and folders with their folder names; trashed items never appear', () async {
      final store = await openTestStore(FakeLibraryClock(t0));
      final trip = await folderNamed(store, 'Summer trip');
      final day = await folderNamed(store, 'Day one', parent: trip);
      final beach = await importNamed(store, 'beach.jpg', folder: day);
      final plan = await importNamed(store, 'plan.pdf', folder: trip);
      final gone = await importNamed(store, 'summer gone.jpg');
      final oldFolder = await folderNamed(store, 'Summer old');
      final inOld = await importNamed(store, 'inside old.jpg', folder: oldFolder);
      await store.write((w, now) => w.trashEntries([gone.id], now: now));
      await store.write((w, now) => w.trashFolder(oldFolder, now: now));

      final index = NameIndex();
      refreshDanaviewSearchSource(index, store.reader);
      final items = danaviewSearchItems(store.reader);
      final ids = {for (final i in items) i.id};
      expect(ids, containsAll(<ItemId>[trip, day, beach.id, plan.id]));
      expect(ids, isNot(contains(gone.id)));
      expect(ids, isNot(contains(oldFolder)));
      expect(ids, isNot(contains(inOld.id)));
      expect(items.firstWhere((i) => i.id == beach.id).folderName, 'Day one');
      expect(items.firstWhere((i) => i.id == day).folderName, 'Summer trip');
      expect(items.firstWhere((i) => i.id == plan.id).subKind, 'pdf');

      final r = index.search(const SearchQuery('summer'));
      expect(_names(r), ['Summer trip', 'Day one', 'plan.pdf']);
      expect(index.search(const SearchQuery('old')).hits, isEmpty);
      expect(index.search(const SearchQuery('gone')).hits, isEmpty);

      // Restore brings it back on the next refresh.
      await store.write((w, now) => w.restore(gone.id, now: now));
      refreshDanaviewSearchSource(index, store.reader);
      expect(_names(index.search(const SearchQuery('gone'))), ['summer gone.jpg']);
    });

    test('the Danaview snapshot fingerprints searchable rows only; the isolate load matches the inline read', () async {
      final store = await openTestStore(FakeLibraryClock(t0));
      final trip = await folderNamed(store, 'Summer trip');
      final beach = await importNamed(store, 'beach.jpg', folder: trip);
      final first = readDanaviewSearchSnapshot(store.reader.db);
      expect(first.changed, isTrue);
      expect([for (final i in first.source!.items) i.name], containsAllInOrder(['beach.jpg', 'Summer trip']));

      // Writes that change no searchable column: same fingerprint, nothing built.
      await store.write((w, now) {
        final job = w.beginImport(now: now, bytesTotal: 8);
        w.recordImportProgress(job.id, 4);
      });
      await store.write((w, now) => w.setEntryFavourite(beach.id, true));
      final same = readDanaviewSearchSnapshot(store.reader.db, unlessFingerprint: first.fingerprint);
      expect(same.changed, isFalse);
      expect(same.fingerprint, first.fingerprint);

      // Rename, move and trash each change it.
      var fp = first.fingerprint;
      Future<void> expectChanged(LibraryWrite<Object?> op) async {
        await store.write(op);
        final s = readDanaviewSearchSnapshot(store.reader.db, unlessFingerprint: fp);
        expect(s.changed, isTrue);
        fp = s.fingerprint;
      }

      await expectChanged((w, now) => w.renameEntry(beach.id, 'shore.jpg', now: now));
      final other = await folderNamed(store, 'Other');
      fp = readDanaviewSearchSnapshot(store.reader.db).fingerprint;
      await expectChanged((w, now) => w.moveEntries([beach.id], other, now: now));
      await expectChanged((w, now) => w.trashEntries([beach.id], now: now));

      final loaded = await loadDanaviewSearchSnapshot(store.paths.databasePath, run: Isolate.run);
      expect(loaded.fingerprint, fp);
      final index = NameIndex()..replacePreparedSource(danaviewSearchSourceId, loaded.source!);
      expect(_names(index.search(const SearchQuery('summer'))), ['Summer trip']);
      expect(index.search(const SearchQuery('shore')).hits, isEmpty);
      final unchanged = await loadDanaviewSearchSnapshot(store.paths.databasePath, run: Isolate.run, unlessFingerprint: fp);
      expect(unchanged.changed, isFalse);
    });

    test('NameSearchBackend answers through the SearchBackend hook', () async {
      final SearchBackend backend = NameSearchBackend()..index.replaceSource('x', [_file('1', 'Report.pdf', kind: FileKind.document, subKind: 'pdf')]);
      expect(backend.id, 'names');
      final r = await backend.search(const SearchQuery('rep'));
      expect(_names(r), ['Report.pdf']);
      expect(const SearchResults.empty(SearchQuery('x')).hits, isEmpty);
    });
  });
}
