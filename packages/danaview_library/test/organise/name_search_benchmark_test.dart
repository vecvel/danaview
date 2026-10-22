// OWNER: HOM-19
//
// BUILD_PLAN HOM-19: "first results ≤ 50 ms per keystroke over 50,000 names on the mid tier
// (benchmark)". This runs the same typing sequences on the host (the Mac, JIT) and fails above
// 50 ms per keystroke; the mid-tier device run (iPhone 12) is recorded in the HOM-19 report. The
// index is built from a 50,000-row library.db through the Danaview source, so the read path the app
// uses on every library change is timed too.
//
// The second case times the first keystroke after a library change, rebuild included: the
// Danaview source is re-read and sorted in a background isolate (not timed against the budget: it
// never runs on the UI isolate), and what the UI isolate does — a keystroke while that read is in
// flight, then the O(1) swap plus the first full search over the new snapshot — must stay inside
// 50 ms. A write that changes no searchable row (an import progress checkpoint) builds nothing.

import 'dart:isolate';
import 'dart:math';

import 'package:danaview_library/testing.dart';
import 'package:test/test.dart';

import 'organise_harness.dart';

const _budget = Duration(milliseconds: 50);
const _count = 50000;

/// Fills library.db with [_count] entries spread over 200 folders (direct SQL in one transaction;
/// the files themselves are irrelevant to search).
Future<void> _seed(LibraryStore store) => store.write((w, now) {
      final r = Random(50);
      const words = ['Holiday', 'beach', 'Report', 'invoice', 'IMG', 'Clip', 'family', 'trip', 'Budget', 'notes', 'Scan', 'party'];
      const exts = [('jpg', 'photo', null), ('HEIC', 'photo', null), ('mov', 'video', null), ('mp4', 'video', null), ('pdf', 'document', 'pdf'), ('docx', 'document', 'word'), ('txt', 'document', 'text')];
      w.transaction(() {
        final folders = <String>[];
        for (var f = 0; f < 200; f++) {
          final id = FolderId.random(r).value;
          folders.add(id);
          w.db.execute('INSERT INTO folders(id, parent_id, name, created_at, modified_at) VALUES (?, NULL, ?, 0, 0)',
              [id, '${words[r.nextInt(words.length)]} ${2000 + f}']);
        }
        final stmt = w.db.prepare('INSERT INTO entries(id, folder_id, display_name, kind, sub_kind, size_bytes, added_at, modified_at, source_hint) '
            'VALUES (?, ?, ?, ?, ?, 1, ?, ?, ?)');
        for (var i = 0; i < _count; i++) {
          final (ext, kind, sub) = exts[r.nextInt(exts.length)];
          final name = '${words[r.nextInt(words.length)]} ${words[r.nextInt(words.length)].toLowerCase()} ${r.nextInt(5000)}.$ext';
          stmt.execute([EntryId.random(r).value, folders[r.nextInt(folders.length)], name, kind, sub, i, i, 'files']);
        }
        stmt.dispose();
      });
    });

void main() {
  test('≤ 50 ms per keystroke over 50,000 names', () async {
    final store = await openTestStore(FakeLibraryClock(t0));
    await _seed(store);
    final index = NameIndex();

    final build = Stopwatch()..start();
    refreshDanaviewSearchSource(index, store.reader);
    final first = index.search(const SearchQuery('x'));
    build.stop();
    expect(index.length, greaterThanOrEqualTo(_count));
    expect(first.backend, NameSearchBackend.backendId);

    // Warm the JIT the way a session would (a few searches), then time fresh typing sequences.
    for (final q in ['ho', 'pd', 're']) {
      index.search(SearchQuery(q));
    }
    const sequences = ['holiday beach 12', 'i', 'report 2', 'pdf', 'scan notes', 'zzz', 'trip 2003 mov', 'e'];
    var worst = Duration.zero;
    var keystrokes = 0;
    var total = Duration.zero;
    for (final typed in sequences) {
      // A new sequence starts from an unrelated query, as after clearing the field.
      index.search(const SearchQuery('-'));
      for (var n = 1; n <= typed.length; n++) {
        final sw = Stopwatch()..start();
        final r = index.search(SearchQuery(typed.substring(0, n)));
        sw.stop();
        keystrokes++;
        total += sw.elapsed;
        if (sw.elapsed > worst) worst = sw.elapsed;
        expect(r.hits.length, lessThanOrEqualTo(100));
      }
    }
    // Backspacing through a query rescans in full each time: also inside the budget.
    for (var n = 'holiday beach'.length; n >= 1; n--) {
      final sw = Stopwatch()..start();
      index.search(SearchQuery('holiday beach'.substring(0, n)));
      sw.stop();
      keystrokes++;
      total += sw.elapsed;
      if (sw.elapsed > worst) worst = sw.elapsed;
    }
    // ignore: avoid_print
    print('HOM-19 benchmark: $_count names, index build ${build.elapsedMilliseconds} ms, '
        '$keystrokes keystrokes, mean ${(total.inMicroseconds / keystrokes / 1000).toStringAsFixed(2)} ms, '
        'worst ${(worst.inMicroseconds / 1000).toStringAsFixed(2)} ms');
    expect(worst, lessThanOrEqualTo(_budget));
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('first keystroke after a library change, rebuild included, ≤ 50 ms on the UI isolate', () async {
    final store = await openTestStore(FakeLibraryClock(t0));
    await _seed(store);
    final dbPath = store.paths.databasePath;
    final index = NameIndex()
      // A linked-folder source beside it, so the query merges across sources as in the app.
      ..replaceSource('linked', [
        for (var i = 0; i < 20000; i++)
          SearchItem(id: ItemId.opaque('/linked/$i'), name: 'Linked holiday clip $i.mov', origin: SearchOrigin.linked, kind: FileKind.video, folderName: 'Clips'),
      ]);
    final initial = await loadDanaviewSearchSnapshot(dbPath, run: Isolate.run);
    index.replacePreparedSource(danaviewSearchSourceId, initial.source!);
    for (final q in ['ho', 'pd', 're', 'holiday']) {
      index.search(SearchQuery(q));
    }

    var worst = Duration.zero;
    void time(void Function() keystroke) {
      final sw = Stopwatch()..start();
      keystroke();
      sw.stop();
      if (sw.elapsed > worst) worst = sw.elapsed;
    }

    var fingerprint = initial.fingerprint;
    var rebuildMs = 0;
    for (var round = 0; round < 3; round++) {
      // A rename: a searchable change.
      final entry = store.reader.db.select('SELECT id FROM entries WHERE trashed_at IS NULL ORDER BY id LIMIT 1 OFFSET ?', [round * 7]).first['id'] as String;
      await store.write((w, now) => w.renameEntry(EntryId.parse(entry), 'Renamed holiday $round.pdf', now: now));
      final rebuild = Stopwatch()..start();
      final pending = loadDanaviewSearchSnapshot(dbPath, run: Isolate.run, unlessFingerprint: fingerprint);
      // A keystroke while the read is in flight answers from the index as it is.
      time(() => index.search(const SearchQuery('holiday r')));
      final snapshot = await pending;
      rebuild.stop();
      rebuildMs = rebuild.elapsedMilliseconds;
      expect(snapshot.changed, isTrue);
      fingerprint = snapshot.fingerprint;
      // The swap and the first search over the new snapshot (fresh caches: a full scan).
      late SearchResults r;
      time(() {
        index.replacePreparedSource(danaviewSearchSourceId, snapshot.source!);
        r = index.search(SearchQuery('renamed holiday $round'));
      });
      expect(r.hits.map((h) => h.item.name), contains('Renamed holiday $round.pdf'));
      time(() => index.search(SearchQuery('renamed holiday $round.')));
    }

    // An import progress checkpoint changes no searchable row: the read builds nothing.
    await store.write((w, now) {
      final job = w.beginImport(now: now, bytesTotal: 1 << 20);
      w.recordImportProgress(job.id, 1 << 19);
    });
    final skip = Stopwatch()..start();
    final unchanged = await loadDanaviewSearchSnapshot(dbPath, run: Isolate.run, unlessFingerprint: fingerprint);
    skip.stop();
    expect(unchanged.changed, isFalse);
    expect(unchanged.fingerprint, fingerprint);

    // ignore: avoid_print
    print('HOM-19 benchmark (after a change): background rebuild $rebuildMs ms (off the UI isolate), '
        'unchanged check ${skip.elapsedMilliseconds} ms (off the UI isolate), '
        'worst UI-isolate keystroke ${(worst.inMicroseconds / 1000).toStringAsFixed(2)} ms');
    expect(worst, lessThanOrEqualTo(_budget));
  }, timeout: const Timeout(Duration(minutes: 3)));
}
