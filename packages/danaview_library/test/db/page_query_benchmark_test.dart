// OWNER: HOM-17
//
// BUILD_PLAN HOM-17: "200-row page query ≤ 2 ms on the mid tier (benchmark recorded)". Seeds a
// 50,000-entry library (ARCH V2-06's sizing) with folders, favourites and trashed rows, then times
// the paged queries the Home tabs and folder screens run, on the read-only connection the UI
// isolate uses. The host run is recorded here and in the HOM-17 report; the mid-tier device run is
// QA-106's (device-only). The host assertion is the same 2 ms median.

import 'dart:io';
import 'dart:math';

import 'package:danaview_library/danaview_library.dart';
import 'package:test/test.dart';

import '../support/sqlite_open.dart';

void main() {
  setUpAll(useHostSqlite);
  test('200-row page queries over 50,000 entries take ≤ 2 ms (median)', () {
    final dir = Directory.systemTemp.createTempSync('hom17_bench_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final path = '${dir.path}/library.db';
    final db = openLibraryWriteConnection(path);
    migrateLibrary(db);
    final rnd = Random(1);
    final folders = [for (var i = 0; i < 200; i++) FolderId.random(rnd)];
    db.execute('BEGIN');
    for (final f in folders) {
      db.execute('INSERT INTO folders(id, name, created_at, modified_at) VALUES (?, ?, 0, 0)', [f.value, 'Folder ${f.token}']);
    }
    const kinds = ['photo', 'video', 'document', 'audio', 'other'];
    // i % 5 picks the kind, so documents are i % 5 == 2 and half of them PDFs.
    final insert = db.prepare(
      'INSERT INTO entries(id, folder_id, display_name, kind, sub_kind, size_bytes, added_at, modified_at, is_favourite, source_hint, trashed_at, expires_at) '
      'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
    );
    for (var i = 0; i < 50000; i++) {
      final trashed = rnd.nextInt(20) == 0;
      insert.execute([
        EntryId.random(rnd).value, folders[rnd.nextInt(folders.length)].value, 'File ${rnd.nextInt(1 << 30)}.jpg',
        kinds[i % kinds.length], i % kinds.length == 2 && i.isEven ? 'pdf' : null, rnd.nextInt(1 << 24), 1700000000000 + rnd.nextInt(1 << 30), 1700000000000 + rnd.nextInt(1 << 30),
        rnd.nextInt(10) == 0 ? 1 : 0, 'photos', trashed ? 1 : null, trashed ? 2 : null,
      ]);
    }
    insert.dispose();
    db.execute('COMMIT');
    db.execute('ANALYZE');

    final read = openLibraryReadConnection(path);
    addTearDown(() {
      read.dispose();
      db.dispose();
    });
    final reader = LibraryReader(read);
    final queries = <String, EntryQuery>{
      'All, newest first': const EntryQuery(),
      'Photos, newest first': const EntryQuery(kinds: {FileKind.photo}),
      'one folder by name': EntryQuery(folderId: folders.first, sort: EntrySortKey.name, descending: false),
      'Favourites, newest first': const EntryQuery(favouritesOnly: true),
      'Documents › PDF, newest first': const EntryQuery(kinds: {FileKind.document}, subKind: 'pdf'),
    };
    final results = <String, double>{};
    for (final MapEntry(:key, :value) in queries.entries) {
      final times = <int>[];
      for (var run = 0; run < 41; run++) {
        final sw = Stopwatch()..start();
        final page = reader.entriesPage(value, offset: run % 3 == 0 ? 0 : 200, limit: 200);
        sw.stop();
        expect(page, isNotEmpty);
        times.add(sw.elapsedMicroseconds);
      }
      times.sort();
      results[key] = times[times.length ~/ 2] / 1000;
    }
    // Recorded result (stdout of this test).
    stdout.writeln('HOM-17 page query median ms (host): $results');
    for (final MapEntry(:key, :value) in results.entries) {
      expect(value, lessThanOrEqualTo(2.0), reason: key);
    }
  });
}
