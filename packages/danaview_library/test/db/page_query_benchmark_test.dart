// OWNER: HOM-17
//
// BUILD_PLAN HOM-17: "200-row page query ≤ 2 ms on the mid tier (benchmark recorded)". Seeds a
// 50,000-entry library (ARCH V2-06's sizing) with folders, favourites and trashed rows, then times
// the paged queries the Home tabs and folder screens run, on the read-only connection the UI
// isolate uses. The host run is recorded here and in the HOM-17 report; the mid-tier device run is
// QA-106's (device-only), and only there is 2 ms the budget.
//
// FIX-S1Q-A5: a host is not the mid tier (a Windows laptop measured a 3.8 ms median on a tree
// whose Mac run stays under 1 ms), and a flat host factor would not do: with every `entries` index
// dropped the Mac still answers in 3–5 ms. So a query passes on a host when it meets the 2 ms
// budget, or when it is at least 3× faster than the same query over the same rows with the
// indexes dropped, measured on the same host in the same run (the Mac's ratio is 5–7×). A lost or
// unused index fails on every host; a slow host alone does not. DV_BENCH_STRICT=1 asserts the 2 ms
// budget only (a run on the tier).

import 'dart:io';
import 'dart:math';

import 'package:danaview_library/danaview_library.dart';
import 'package:test/test.dart';

import '../support/sqlite_open.dart';

/// ARCH v1.2 §10: one 200-row page on the mid tier.
const double _budgetMs = 2.0;

/// Off the tier, how much faster than the index-free scan a query over budget must still be.
const double _indexGain = 3;

void main() {
  setUpAll(useHostSqlite);
  final strict = Platform.environment['DV_BENCH_STRICT'] == '1';
  test('200-row page queries over 50,000 entries take ≤ 2 ms (median), or on a host use their indexes', () {
    final dir = Directory.systemTemp.createTempSync('hom17_bench_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final path = '${dir.path}/library.db';
    final db = openLibraryWriteConnection(path);
    // Registered after the deletion, so it runs first, also when the test fails: Windows refuses to
    // delete the folder while library.db is open.
    addTearDown(db.dispose);
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
    addTearDown(read.dispose);
    final reader = LibraryReader(read);
    final queries = <String, EntryQuery>{
      'All, newest first': const EntryQuery(),
      'Photos, newest first': const EntryQuery(kinds: {FileKind.photo}),
      'one folder by name': EntryQuery(folderId: folders.first, sort: EntrySortKey.name, descending: false),
      'Favourites, newest first': const EntryQuery(favouritesOnly: true),
      'Documents › PDF, newest first': const EntryQuery(kinds: {FileKind.document}, subKind: 'pdf'),
    };
    Map<String, double> medians() => {
          for (final MapEntry(:key, :value) in queries.entries)
            key: () {
              final times = <int>[];
              for (var run = 0; run < 41; run++) {
                final sw = Stopwatch()..start();
                final page = reader.entriesPage(value, offset: run % 3 == 0 ? 0 : 200, limit: 200);
                sw.stop();
                expect(page, isNotEmpty);
                times.add(sw.elapsedMicroseconds);
              }
              times.sort();
              return times[times.length ~/ 2] / 1000;
            }(),
        };
    final results = medians();
    // Recorded result (stdout of this test).
    stdout.writeln('HOM-17 page query median ms (host): $results');
    if (strict || results.values.every((ms) => ms <= _budgetMs)) {
      for (final MapEntry(:key, :value) in results.entries) {
        expect(value, lessThanOrEqualTo(_budgetMs), reason: key);
      }
      return;
    }

    // Over budget on this host: the same queries with every index of `entries` dropped are the
    // yardstick (the read connection re-prepares after the schema change).
    final indexes = [
      for (final row in db.select("SELECT name FROM sqlite_master WHERE type = 'index' AND tbl_name = 'entries' AND sql IS NOT NULL"))
        row['name'] as String,
    ];
    expect(indexes, isNotEmpty);
    for (final name in indexes) {
      db.execute('DROP INDEX "$name"');
    }
    db.execute('ANALYZE');
    final scans = medians();
    stdout.writeln('HOM-17 page query median ms without indexes (host): $scans');
    for (final MapEntry(:key, :value) in results.entries) {
      expect(value <= _budgetMs || value * _indexGain <= scans[key]!, isTrue,
          reason: '$key: $value ms, over the $_budgetMs ms budget and not $_indexGain× faster than the '
              'index-free ${scans[key]} ms');
    }
  });
}
