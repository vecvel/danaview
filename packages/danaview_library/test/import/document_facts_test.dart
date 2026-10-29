// OWNER: HOM-20
//
// FIX-S3Q-4: imported PDFs get `entry_meta.pageCount` from the app's page counter (the
// `danaview_pdf` probe), read from the copy before the commit, in the commit's transaction; other
// documents are never probed; a counter that fails, answers nothing or hangs leaves the fact unset
// and never fails the import; `backfillPageCounts` fills in PDFs imported before, keeping their
// other facts, skipping trashed entries, bounded per run, with the writer in-process or on its
// own isolate.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:danaview_library/testing.dart';
import 'package:test/test.dart';

import '../support/sqlite_open.dart';
import 'import_harness.dart';

/// Stand-in PDF bytes: the counter below reads the page count from the content, so a counter
/// handed the wrong file (or the source instead of the copy) answers wrong.
List<int> fakePdf(int pages) => utf8.encode('%PDF-1.7 pages=$pages\n%%EOF\n');

/// A counter over [fakePdf] files that records the paths it was asked for.
final class FakeCounter {
  final List<String> paths = [];

  Future<int?> call(String path) async {
    paths.add(path);
    final m = RegExp(r'pages=(\d+)').firstMatch(await File(path).readAsString());
    return m == null ? null : int.parse(m.group(1)!);
  }
}

void main() {
  setUpAll(useHostSqlite);

  group('import records the page count', () {
    test('a PDF gets its page count in the commit; a Word file and a photo are never probed', () async {
      final src = tempDir('s3q4_src_');
      final store = await openStore(tempDir('s3q4_lib_').path);
      final pdf = sourceFile(src, 'Report.pdf', fakePdf(12));
      final docx = sourceFile(src, 'Notes.docx', fakePdf(3));
      final counter = FakeCounter();
      final service = ImportService(store: store, countPages: counter.call);
      final metaInHook = <EntryMeta?>[];
      service.addHook((e) => metaInHook.add(store.reader.meta(e.id)));

      final items = await service.importAll([
        ImportSource.file(pdf.path, mime: 'application/pdf'),
        ImportSource.file(docx.path, mime: 'application/vnd.openxmlformats-officedocument.wordprocessingml.document'),
      ]);
      expect(items.map((i) => i.state), everyElement(ImportItemState.done));

      final pm = store.reader.meta(items[0].entry!.id)!;
      expect(pm.pageCount, 12);
      expect(metaInHook[0], pm, reason: 'written in the commit, not after it');
      expect(store.reader.meta(items[1].entry!.id), isNull);
      expect(counter.paths, hasLength(1), reason: 'only the PDF is probed');
      expect(counter.paths.single, isNot(pdf.path), reason: 'the copy is probed, never the source');
    });

    test('without a counter a PDF imports with no facts', () async {
      final src = tempDir('s3q4_none_src_');
      final store = await openStore(tempDir('s3q4_none_lib_').path);
      final pdf = sourceFile(src, 'a.pdf', fakePdf(4));
      final item = (await ImportService(store: store).importAll([ImportSource.file(pdf.path, mime: 'application/pdf')])).single;
      expect(item.state, ImportItemState.done);
      expect(store.reader.meta(item.entry!.id), isNull);
    });

    for (final (what, counter) in <(String, DocumentPageCounter)>[
      ('throws', (_) async => throw StateError('plugin missing')),
      ('answers null (locked)', (_) async => null),
      ('answers 0 (damaged)', (_) async => 0),
    ]) {
      test('a counter that $what leaves the fact unset and the import done', () async {
        final src = tempDir('s3q4_fail_src_');
        final store = await openStore(tempDir('s3q4_fail_lib_').path);
        final pdf = sourceFile(src, 'b.pdf', fakePdf(2));
        final item = (await ImportService(store: store, countPages: counter).importAll([ImportSource.file(pdf.path, mime: 'application/pdf')])).single;
        expect(item.state, ImportItemState.done);
        expect(store.reader.meta(item.entry!.id), isNull);
      });
    }

    test('a counter that hangs is given up after the timeout', () async {
      final hang = Completer<int?>();
      final kind = classify(fileName: 'c.pdf');
      final meta = await documentEntryMeta('/nowhere/c.pdf', kind, (_) => hang.future, timeout: const Duration(milliseconds: 50));
      expect(meta, isNull);
      expect(await documentEntryMeta('/nowhere/c.pdf', kind, (_) async => 7), const EntryMeta(pageCount: 7));
      expect(countsPages(classify(fileName: 'c.txt')), isFalse);
    });
  });

  group('backfillPageCounts', () {
    for (final background in [false, true]) {
      test('fills in PDFs without a count, keeps other facts, skips trashed ones (writer ${background ? 'on its own isolate' : 'in-process'})', () async {
        final src = tempDir('s3q4_bf_src_');
        final store = await openStore(tempDir('s3q4_bf_lib_').path, background: background);
        final items = await ImportService(store: store).importAll([
          ImportSource.file(sourceFile(src, 'one.pdf', fakePdf(1)).path, mime: 'application/pdf'),
          ImportSource.file(sourceFile(src, 'two.pdf', fakePdf(2)).path, mime: 'application/pdf'),
          ImportSource.file(sourceFile(src, 'gone.pdf', fakePdf(9)).path, mime: 'application/pdf'),
          ImportSource.file(sourceFile(src, 'memo.txt', fakePdf(5)).path, mime: 'text/plain'),
        ]);
        final [one, two, gone, memo] = [for (final i in items) i.entry!.id];
        await store.write((w, _) => w.setMeta(two, const EntryMeta(width: 10, height: 20, flags: 1)));
        await store.write((w, now) => w.trashEntries([gone], now: now));

        final counter = FakeCounter();
        expect(await backfillPageCounts(store, counter.call), 2);
        expect(store.reader.meta(one)!.pageCount, 1);
        final m2 = store.reader.meta(two)!;
        expect((m2.pageCount, m2.width, m2.height, m2.flags), (2, 10, 20, 1), reason: 'the other facts stay');
        expect(store.reader.meta(gone), isNull, reason: 'a trashed PDF is not probed');
        expect(store.reader.meta(memo), isNull, reason: 'only PDFs are probed');
        expect(counter.paths, hasLength(2));

        // Done once: the next run probes nothing.
        final again = FakeCounter();
        expect(await backfillPageCounts(store, again.call), 0);
        expect(again.paths, isEmpty);
      });
    }

    test('probes at most the limit per run, oldest first', () async {
      final src = tempDir('s3q4_lim_src_');
      final clock = FakeLibraryClock(t0);
      final store = await openStore(tempDir('s3q4_lim_lib_').path, clock: clock);
      final ids = <EntryId>[];
      for (var i = 1; i <= 3; i++) {
        final item = (await ImportService(store: store).importAll([
          ImportSource.file(sourceFile(src, 'p$i.pdf', fakePdf(i)).path, mime: 'application/pdf'),
        ])).single;
        ids.add(item.entry!.id);
        clock.advance(const Duration(minutes: 1));
      }
      expect(await backfillPageCounts(store, FakeCounter().call, limit: 2), 2);
      expect([for (final id in ids) store.reader.meta(id)?.pageCount], [1, 2, null]);
      expect(await backfillPageCounts(store, FakeCounter().call, limit: 2), 1);
      expect(store.reader.meta(ids[2])!.pageCount, 3);
    });

    test('a counter that fails leaves the entry for a later run', () async {
      final src = tempDir('s3q4_bff_src_');
      final store = await openStore(tempDir('s3q4_bff_lib_').path);
      final item = (await ImportService(store: store).importAll([
        ImportSource.file(sourceFile(src, 'x.pdf', fakePdf(6)).path, mime: 'application/pdf'),
      ])).single;
      expect(await backfillPageCounts(store, (_) async => throw StateError('no plugin')), 0);
      expect(store.reader.meta(item.entry!.id), isNull);
      expect(await backfillPageCounts(store, FakeCounter().call), 1);
      expect(store.reader.meta(item.entry!.id)!.pageCount, 6);
    });
  });
}
