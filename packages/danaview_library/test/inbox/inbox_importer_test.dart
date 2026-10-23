// OWNER: HOM-21
//
// BUILD_PLAN HOM-21 (ARCH v1.2 §5.6): each complete Share Extension batch is imported into the
// folder picked in the extension (`sourceHint = shareExtension`) and deleted; an interrupted share
// (no manifest) leaves no entry and is deleted after 24 h; a kill between the move and the import,
// or mid-copy, imports each file exactly once; concurrent runs never import twice; the folder
// snapshot is refreshed on every run. Generated local files only.

import 'dart:async';
import 'dart:io';

import 'package:danaview_library/testing.dart';
import 'package:test/test.dart';

import '../import/import_harness.dart';
import '../support/sqlite_open.dart';
import 'fake_inbox.dart';

void main() {
  setUpAll(useHostSqlite);
  late FakeInboxPort inbox;
  late String staging;
  late LibraryStore store;
  late ImportService imports;

  setUp(() async {
    inbox = FakeInboxPort(tempDir('hom21_group_'));
    staging = '${tempDir('hom21_staging_').path}/inbox';
    store = await openStore(tempDir('hom21_lib_').path);
    addTearDown(() => store.close());
    imports = ImportService(store: store);
    addTearDown(imports.dispose);
  });

  InboxImporter importer({ImportService? service}) =>
      InboxImporter(port: inbox, imports: service ?? imports, stagingDirectory: staging, clock: () => t0);

  List<FileEntry> live() => store.reader.allEntries();

  List<File> stagedFiles() =>
      Directory(staging).existsSync() ? Directory(staging).listSync(recursive: true).whereType<File>().toList() : const [];

  test('a complete batch is imported into the picked folder and deleted', () async {
    final work = await store.write((w, now) => w.createFolder('Work', now: now));
    final photo = bytesOf(40 * 1024, seed: 2);
    final pdf = bytesOf(90 * 1024, seed: 3);
    final video = bytesOf(700 * 1024, seed: 4);
    inbox.addBatch('b1', {'IMG_0001.HEIC': photo, 'Lease.pdf': pdf, 'Clip.mov': video}, createdAt: t0, folder: work);

    final result = await importer().run();

    expect(result.available, isTrue);
    expect(result.batches, 1);
    expect(result.failed, 0);
    expect(result.imported.map((e) => e.displayName), ['IMG_0001.HEIC', 'Lease.pdf', 'Clip.mov']);
    expect(result.imported.map((e) => e.kind), [FileKind.photo, FileKind.document, FileKind.video]);
    for (final e in result.imported) {
      expect(e.folderId, work);
      expect(e.sourceHint, SourceHint.shareExtension);
    }
    expect(libraryBytes(store, result.imported[1]), pdf);
    expect(libraryBytes(store, result.imported[2]), video);
    expect(inbox.hasBatch('b1'), isFalse, reason: 'the batch is deleted after its imports');
    expect(stagedFiles(), isEmpty, reason: 'staged copies are deleted after the commit');
  });

  test('without a picked folder, or with one deleted meanwhile, files land in Imported', () async {
    final gone = await store.write((w, now) => w.createFolder('Gone', now: now));
    await store.write((w, now) => w.trashFolder(gone, now: now));
    inbox
      ..addBatch('b1', {'a.pdf': bytesOf(1000, seed: 5)}, createdAt: t0)
      ..addBatch('b2', {'b.pdf': bytesOf(1000, seed: 6)}, createdAt: t0.add(const Duration(seconds: 1)), folder: gone);

    final result = await importer().run();

    final imported = store.reader.systemFolder(FolderSystemRole.imported)!.id;
    expect(result.imported.map((e) => e.folderId), [imported, imported]);
    expect(result.imported.map((e) => e.displayName), ['a.pdf', 'b.pdf'], reason: 'batches in creation order');
  });

  test('an interrupted share (no manifest) leaves no entry and is deleted after 24 h', () async {
    inbox.addBatch('partial', {'Big.mov': bytesOf(5000)}, createdAt: inbox.now.subtract(const Duration(hours: 2)), complete: false);

    var result = await importer().run();
    expect(result.imported, isEmpty);
    expect(result.staleDeleted, 0);
    expect(live(), isEmpty, reason: 'no half-imported entry');
    expect(inbox.hasBatch('partial'), isTrue, reason: 'a recent incomplete batch may still be finishing');

    inbox.now = inbox.now.add(const Duration(hours: 23));
    result = await importer().run();
    expect(result.staleDeleted, 1);
    expect(inbox.hasBatch('partial'), isFalse);
    expect(live(), isEmpty);
  });

  test('no inbox on the platform: nothing runs', () async {
    inbox
      ..available = false
      ..addBatch('b1', {'a.pdf': bytesOf(100)}, createdAt: t0);
    final result = await importer().run();
    expect(result.available, isFalse);
    expect(inbox.hasBatch('b1'), isTrue);
    expect(inbox.snapshotWrites, 0);
    expect(live(), isEmpty);
  });

  test('every run refreshes the folder snapshot', () async {
    await store.write((w, now) => w.createFolder('Receipts', now: now));
    await importer().run();
    expect(inbox.snapshotWrites, 1);
    final json = String.fromCharCodes(inbox.snapshot!);
    expect(json, contains('"Receipts"'));
    await importer().refreshFolderSnapshot();
    expect(inbox.snapshotWrites, 2);
  });

  test('killed after moving a file but before its import: the next run imports it once', () async {
    final bytes = bytesOf(20 * 1024, seed: 9);
    inbox.addBatch('b1', {'Scan.pdf': bytes, 'Note.txt': bytesOf(300, seed: 10)}, createdAt: t0);
    // The earlier run moved the first file into staging and died.
    final dest = File('$staging/b1_0000_Scan.pdf')..createSync(recursive: true);
    File('${inbox.root.path}/b1/items/0/Scan.pdf').renameSync(dest.path);

    final result = await importer().run();

    expect(result.imported.map((e) => e.displayName), ['Scan.pdf', 'Note.txt']);
    expect(libraryBytes(store, result.imported.first), bytes);
    expect(live(), hasLength(2));
    expect(inbox.hasBatch('b1'), isFalse);
  });

  test('killed after the import committed but before the batch was deleted: nothing is imported twice', () async {
    inbox.addBatch('b1', {'Scan.pdf': bytesOf(2048, seed: 11)}, createdAt: t0);
    final first = await importer().run();
    expect(first.imported, hasLength(1));
    // Recreate the batch without its (already moved) file, as a kill before deleteBatch leaves it.
    inbox.addBatch('b1', {}, createdAt: t0);
    final again = await importer().run();
    expect(again.imported, isEmpty);
    expect(again.failed, 0);
    expect(live(), hasLength(1));
    expect(inbox.hasBatch('b1'), isFalse);
  });

  test('killed mid-copy: the job resumes after relaunch and the file is imported once', () async {
    final bytes = bytesOf(600 * 1024, seed: 12);
    inbox.addBatch('b1', {'Movie.mov': bytes}, createdAt: t0);
    final halting = HaltingCopier(300 * 1024);
    final dying = ImportService(store: store, copiers: [halting]);
    unawaited(importer(service: dying).run());
    await halting.halted.future;
    await eventually(() => store.reader.importJobs().any((j) => j.bytesDone == 300 * 1024));
    await dying.dispose(); // the process dies

    // Relaunch: the import service resumes the job, the importer finds the batch again.
    final relaunched = ImportService(store: store);
    addTearDown(relaunched.dispose);
    final resumed = await relaunched.resumePending();
    expect(resumed, hasLength(1));
    final result = await importer(service: relaunched).run();
    final done = await relaunched.result(resumed.single);

    expect(done.state, ImportItemState.done);
    expect(result.imported, isEmpty, reason: 'the resumed job, not a second import, brings it in');
    expect(live(), hasLength(1));
    expect(libraryBytes(store, live().single), bytes);
    expect(live().single.sourceHint, SourceHint.shareExtension);
    expect(inbox.hasBatch('b1'), isFalse);
  });

  test('a run requested while one is running runs once more and never imports twice', () async {
    inbox.addBatch('b1', {'a.pdf': bytesOf(1000, seed: 13)}, createdAt: t0);
    final gate = Completer<void>();
    inbox.beforeTake = (_, __) => gate.future;
    final imp = importer();
    final first = imp.run();
    // The extension finishes another share meanwhile.
    inbox.addBatch('b2', {'b.pdf': bytesOf(1000, seed: 14)}, createdAt: t0.add(const Duration(minutes: 1)));
    final second = imp.run();
    gate.complete();
    final results = await Future.wait([first, second]);

    expect(identical(results[0], results[1]), isTrue, reason: 'both callers get the last run');
    expect(live().map((e) => e.displayName).toSet(), {'a.pdf', 'b.pdf'});
    expect(live(), hasLength(2));
    expect(inbox.hasBatch('b1') || inbox.hasBatch('b2'), isFalse);
  });

  test('a file whose content is already in the library is kept by default, skipped when asked', () async {
    final bytes = bytesOf(4096, seed: 15);
    inbox.addBatch('b1', {'Same.pdf': bytes}, createdAt: t0);
    await importer().run();
    inbox.addBatch('b2', {'Same.pdf': bytes}, createdAt: t0);
    final kept = await importer().run();
    expect(kept.imported.single.displayName, 'Same (2).pdf');

    inbox.addBatch('b3', {'Same.pdf': bytes}, createdAt: t0);
    final skipping = InboxImporter(port: inbox, imports: imports, stagingDirectory: staging, duplicates: DuplicatePolicy.skip);
    final skipped = await skipping.run();
    expect(skipped.skipped, 1);
    expect(live(), hasLength(2));
    expect(inbox.hasBatch('b3'), isFalse);
    expect(stagedFiles(), isEmpty);
  });

  test('the result never prints names', () async {
    inbox.addBatch('b1', {'Secret plan.pdf': bytesOf(100)}, createdAt: t0);
    final result = await importer().run();
    expect(result.toString(), isNot(contains('Secret')));
    expect((await inbox.listBatches()).toString(), isNot(contains('Secret')));
  });
}
