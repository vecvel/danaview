// OWNER: HOM-20
//
// BUILD_PLAN HOM-20 (ARCH v1.2 §5.6, V2-116, rule 27): an import copies; the source file's bytes and
// timestamps are unchanged; a kill at 50 % and a relaunch resume from `bytes_done`; same-name files
// are suffixed and same-content files kept or skipped as chosen (or asked); cancel, unreadable and
// changed sources, staged picker copies, the writer on its own isolate, and the stored source.

import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:danaview_library/testing.dart';
import 'package:test/test.dart';

import '../support/sqlite_open.dart';
import 'import_harness.dart';

void main() {
  setUpAll(useHostSqlite);
  late Directory src;
  late String root;
  late LibraryStore store;

  setUp(() async {
    src = tempDir('hom20_src_');
    root = tempDir('hom20_lib_').path;
    store = await openStore(root);
    // Also closes a store the test reopened, before the temp folders go (a group `tearDown` would
    // run after their deletion, which Windows refuses while library.db is open; FIX-S1Q-A5).
    addTearDown(() => store.close());
  });

  test('an import copies into Imported; the source bytes and timestamps are unchanged', () async {
    final bytes = bytesOf(300 * 1024 + 17);
    final file = sourceFile(src, 'Quarterly Report.pdf', bytes);
    final before = file.statSync();
    final service = ImportService(store: store);
    final hooked = <FileEntry>[];
    service.addHook(hooked.add);

    final item = (await service.importAll([ImportSource.file(file.path, mime: 'application/pdf')])).single;

    expect(item.state, ImportItemState.done);
    final entry = item.entry!;
    expect(entry.displayName, 'Quarterly Report.pdf');
    expect(entry.kind, FileKind.document);
    expect(entry.subKind, 'pdf');
    expect(entry.sourceHint, SourceHint.files);
    expect(entry.sizeBytes, bytes.length);
    expect(entry.folderId, store.reader.systemFolder(FolderSystemRole.imported)!.id);
    expect(entry.modifiedAt, DateTime.utc(2020, 1, 2, 3, 4, 5), reason: 'the source modification time is kept');
    expect(entry.quickHash, isNotEmpty);
    expect(libraryBytes(store, entry), bytes);
    expect(hooked.map((e) => e.id), [entry.id], reason: 'thumbnail and index hooks run once');

    final after = file.statSync();
    expect(file.readAsBytesSync(), bytes, reason: 'source bytes unchanged');
    expect(after.modified, before.modified, reason: 'source mtime unchanged');
    expect(after.changed, before.changed, reason: 'source ctime unchanged (never written, renamed or chmodded)');
    expect(after.mode, before.mode);
    expect(after.size, before.size);
    expect(store.reader.importJobs(), isEmpty);
    expect(Directory(store.paths.importsDir).listSync(), isEmpty, reason: 'no part file left');
  });

  test('progress rows go from queued through copying to done with growing bytes', () async {
    final file = sourceFile(src, 'clip.mov', bytesOf(3 * 1024 * 1024));
    final service = ImportService(store: store, copiers: [RecordingCopier()]);
    final seen = <ImportItem>[];
    service.updates.listen((items) => seen.add(items.single));
    final id = service.enqueue(ImportSource.file(file.path, uti: 'com.apple.quicktime-movie', sourceHint: SourceHint.photos));
    final item = await service.result(id);
    expect(item.state, ImportItemState.done);
    expect(item.entry!.kind, FileKind.video);
    expect(item.entry!.sourceHint, SourceHint.photos);
    expect(item.fraction, 1);
    final states = seen.map((i) => i.state).toList();
    expect(states.first, ImportItemState.queued);
    expect(states, containsAllInOrder([ImportItemState.copying, ImportItemState.finishing, ImportItemState.done]));
    final bytes = [for (final i in seen) i.bytesDone];
    for (var k = 1; k < bytes.length; k++) {
      expect(bytes[k], greaterThanOrEqualTo(bytes[k - 1]));
    }
    expect(seen.where((i) => i.state == ImportItemState.copying && i.bytesDone > 0 && i.bytesDone < 3 * 1024 * 1024), isNotEmpty);
  });

  test('a chosen folder is used; a same-name file there is suffixed', () async {
    final folder = await store.write((w, now) => w.createFolder('Work', now: now));
    final a = sourceFile(src, 'Report.pdf', bytesOf(1000, seed: 1));
    final service = ImportService(store: store);
    final first = (await service.importAll([ImportSource.file(a.path)], target: folder)).single;
    final b = sourceFile(src, 'Report.pdf', bytesOf(2000, seed: 2));
    final second = (await service.importAll([ImportSource.file(b.path)], target: folder)).single;
    expect(first.entry!.folderId, folder);
    expect(second.entry!.folderId, folder);
    expect(first.entry!.displayName, 'Report.pdf');
    expect(second.entry!.displayName, 'Report (2).pdf');
  });

  test('a trashed target falls back to Imported', () async {
    final folder = await store.write((w, now) => w.createFolder('Gone', now: now));
    await store.write((w, now) => w.trashFolder(folder, now: now));
    final f = sourceFile(src, 'a.txt', [1, 2, 3]);
    final item = (await ImportService(store: store).importAll([ImportSource.file(f.path)], target: folder)).single;
    expect(item.state, ImportItemState.done);
    expect(item.entry!.folderId, store.reader.systemFolder(FolderSystemRole.imported)!.id);
  });

  group('same content (size + SHA-256)', () {
    late File original;
    late FileEntry existing;

    setUp(() async {
      original = sourceFile(src, 'IMG_0001.HEIC', bytesOf(200 * 1024, seed: 9));
      existing = (await ImportService(store: store).importAll([ImportSource.file(original.path)])).single.entry!;
    });

    test('keep both imports a second entry', () async {
      final copy = sourceFile(src, 'copy.HEIC', original.readAsBytesSync());
      final copier = RecordingCopier();
      final item = (await ImportService(store: store, copiers: [copier]).importAll([ImportSource.file(copy.path)], duplicates: DuplicatePolicy.keepBoth)).single;
      expect(item.state, ImportItemState.done);
      expect(item.entry!.id, isNot(existing.id));
      expect(copier.starts.single.$2, isTrue, reason: 'a same-size file exists, so SHA-256 streams during the copy');
      expect(store.reader.countEntries(const EntryQuery()), 2);
    });

    test('skip leaves the library unchanged and no part behind', () async {
      final copy = sourceFile(src, 'copy.HEIC', original.readAsBytesSync());
      final item = (await ImportService(store: store).importAll([ImportSource.file(copy.path)], duplicates: DuplicatePolicy.skip)).single;
      expect(item.state, ImportItemState.skipped);
      expect(item.duplicateOf!.id, existing.id);
      expect(store.reader.countEntries(const EntryQuery()), 1);
      expect(store.reader.importJobs(), isEmpty);
      expect(Directory(store.paths.importsDir).listSync(), isEmpty);
      expect(copy.existsSync(), isTrue, reason: 'the source is never deleted');
    });

    test('ask waits for the answer: keep both, then skip', () async {
      final service = ImportService(store: store);
      final copy = sourceFile(src, 'copy.HEIC', original.readAsBytesSync());
      final a = service.enqueue(ImportSource.file(copy.path));
      await eventually(() => service.items.single.state == ImportItemState.awaitingDuplicateDecision);
      expect(service.items.single.duplicateOf!.id, existing.id);
      service.resolveDuplicate(a, DuplicateDecision.keepBoth);
      expect((await service.result(a)).state, ImportItemState.done);

      final b = service.enqueue(ImportSource.file(copy.path));
      await eventually(() => service.items.last.state == ImportItemState.awaitingDuplicateDecision);
      service.resolveDuplicate(b, DuplicateDecision.skip);
      expect((await service.result(b)).state, ImportItemState.skipped);
      expect(store.reader.countEntries(const EntryQuery()), 2);
    });

    test('an existing entry without a stored hash is hashed from its library file', () async {
      await store.write((w, _) => w.db.execute('UPDATE entries SET content_sha256 = NULL'));
      final copy = sourceFile(src, 'copy.HEIC', original.readAsBytesSync());
      final item = (await ImportService(store: store).importAll([ImportSource.file(copy.path)], duplicates: DuplicatePolicy.skip)).single;
      expect(item.state, ImportItemState.skipped);
    });

    test('same size but different content is no duplicate', () async {
      final other = sourceFile(src, 'other.HEIC', bytesOf(200 * 1024, seed: 10));
      final item = (await ImportService(store: store).importAll([ImportSource.file(other.path)], duplicates: DuplicatePolicy.skip)).single;
      expect(item.state, ImportItemState.done);
    });
  });

  test('no same-size file in the library: the copy does not hash', () async {
    final f = sourceFile(src, 'unique.bin', bytesOf(12345));
    final copier = RecordingCopier();
    final item = (await ImportService(store: store, copiers: [copier]).importAll([ImportSource.file(f.path)])).single;
    expect(copier.starts.single, (0, false));
    expect(item.entry!.quickHash, isNotEmpty);
  });

  group('kill at 50 % and relaunch', () {
    test('resumes from bytes_done and produces the exact source bytes', () async {
      final bytes = bytesOf(4 * 1024 * 1024 + 123, seed: 4);
      final file = sourceFile(src, 'Holiday.mov', bytes);
      final before = file.statSync();
      final halting = HaltingCopier(bytes.length ~/ 2);
      final killed = ImportService(store: store, copiers: [halting]);
      killed.enqueue(ImportSource.file(file.path, uti: 'com.apple.quicktime-movie'));
      await halting.halted.future;
      await eventually(() => store.reader.importJobs().singleOrNull?.bytesDone == bytes.length ~/ 2);
      // The process dies: no cleanup, no close.
      store.abandon();

      store = await openStore(root);
      final job = store.reader.importJobs().single;
      expect(job.bytesDone, bytes.length ~/ 2);
      expect(job.bytesTotal, bytes.length);
      final copier = RecordingCopier();
      final service = ImportService(store: store, copiers: [copier]);
      final ids = await service.resumePending();
      expect(ids, hasLength(1));
      expect(service.items.single.resumed, isTrue);
      final item = await service.result(ids.single);
      expect(item.state, ImportItemState.done);
      expect(copier.starts.single.$1, bytes.length ~/ 2, reason: 'resumed from bytes_done, not from 0');
      expect(libraryBytes(store, item.entry!), bytes, reason: 'the unsynced tail after the checkpoint was cut off');
      expect(item.entry!.displayName, 'Holiday.mov');
      expect(item.entry!.kind, FileKind.video);
      expect(store.reader.importJobs(), isEmpty);
      expect(file.readAsBytesSync(), bytes);
      expect(file.statSync().modified, before.modified);
    });

    test('a source that is gone is reported and its job and part removed', () async {
      final file = sourceFile(src, 'gone.mp4', bytesOf(1024 * 1024));
      final halting = HaltingCopier(512 * 1024);
      ImportService(store: store, copiers: [halting]).enqueue(ImportSource.file(file.path));
      await halting.halted.future;
      await eventually(() => store.reader.importJobs().singleOrNull?.bytesDone == 512 * 1024);
      store.abandon();
      file.deleteSync();

      store = await openStore(root);
      final service = ImportService(store: store);
      final item = await service.result((await service.resumePending()).single);
      expect(item.state, ImportItemState.failed);
      expect(item.failure, ImportFailure.sourceUnreadable);
      expect(store.reader.importJobs(), isEmpty);
      expect(Directory(store.paths.importsDir).listSync(), isEmpty);
    });

    test('a source that changed since is copied again from the start', () async {
      final file = sourceFile(src, 'doc.txt', bytesOf(1024 * 1024));
      final halting = HaltingCopier(512 * 1024);
      ImportService(store: store, copiers: [halting]).enqueue(ImportSource.file(file.path));
      await halting.halted.future;
      await eventually(() => store.reader.importJobs().singleOrNull?.bytesDone == 512 * 1024);
      store.abandon();
      final changed = bytesOf(1500 * 1024, seed: 77);
      file.writeAsBytesSync(changed);

      store = await openStore(root);
      final copier = RecordingCopier();
      final service = ImportService(store: store, copiers: [copier]);
      final item = await service.result((await service.resumePending()).single);
      expect(item.state, ImportItemState.done);
      expect(copier.starts.single.$1, 0);
      expect(libraryBytes(store, item.entry!), changed);
    });

    test('an undecodable stored source is abandoned', () async {
      await store.write((w, now) => w.beginImport(sourceDescription: 'not json', bytesTotal: 10, now: now));
      final ids = await ImportService(store: store).resumePending();
      expect(ids, isEmpty);
      expect(store.reader.importJobs(), isEmpty);
    });
  });

  test('cancel stops a running copy and deletes its part', () async {
    final file = sourceFile(src, 'big.bin', Uint8List(96 * 1024 * 1024));
    final service = ImportService(store: store);
    final id = service.enqueue(ImportSource.file(file.path));
    await eventually(() => service.items.single.bytesDone > 0);
    await service.cancel(id);
    final item = await service.result(id);
    expect(item.state, ImportItemState.cancelled);
    expect(store.reader.importJobs(), isEmpty);
    expect(Directory(store.paths.importsDir).listSync(), isEmpty);
    expect(store.reader.countEntries(const EntryQuery()), 0);
    expect(file.lengthSync(), 96 * 1024 * 1024);
  });

  test('cancel of a queued item: it never starts', () async {
    final a = sourceFile(src, 'a.bin', bytesOf(1024));
    final b = sourceFile(src, 'b.bin', bytesOf(2048));
    final service = ImportService(store: store);
    final ids = service.enqueueAll([ImportSource.file(a.path), ImportSource.file(b.path)]);
    await service.cancel(ids[1]);
    expect((await service.result(ids[0])).state, ImportItemState.done);
    expect((await service.result(ids[1])).state, ImportItemState.cancelled);
    expect(store.reader.countEntries(const EntryQuery()), 1);
    service.clearFinished();
    expect(service.items, isEmpty);
  });

  test('a staged picker copy is deleted after the commit; the grant is released; originals never', () async {
    final staging = tempDir('hom20_staging_');
    final staged = sourceFile(staging, 'IMG_0002.JPG', bytesOf(5000));
    final original = sourceFile(src, 'kept.JPG', bytesOf(6000));
    final released = <String>[];
    final service = ImportService(store: store, release: (uri) async => released.add(uri));
    final items = await service.importAll([
      ImportSource.file(staged.path, sourceHint: SourceHint.photos, stagedCopy: true),
      ImportSource.file(original.path, releaseUri: 'file:///scoped/kept.JPG'),
    ]);
    expect(items.map((i) => i.state), everyElement(ImportItemState.done));
    expect(staged.existsSync(), isFalse);
    expect(original.existsSync(), isTrue);
    expect(released, ['file:///scoped/kept.JPG']);
  });

  test('sweepStaging deletes staged files no job reads', () async {
    final staging = tempDir('hom20_staging_');
    final orphan = sourceFile(staging, 'orphan.jpg', [1]);
    final pending = sourceFile(staging, 'pending.jpg', bytesOf(1024 * 1024));
    final halting = HaltingCopier(1000);
    final service = ImportService(store: store, copiers: [halting]);
    service.enqueue(ImportSource.file(pending.path, stagedCopy: true));
    await halting.halted.future;
    await eventually(() => store.reader.importJobs().isNotEmpty);
    expect(await service.sweepStaging(staging.path), 1);
    expect(orphan.existsSync(), isFalse);
    expect(pending.existsSync(), isTrue);
  });

  test('a platform URI without a native copier fails as unsupported', () async {
    const s = ImportSource(kind: ImportSourceKind.nativeUri, location: 'content://media/1', displayName: 'a.jpg');
    final item = (await ImportService(store: store).importAll([s])).single;
    expect(item.failure, ImportFailure.unsupportedSource);
  });

  test('an unreadable source fails without a job', () async {
    final item = (await ImportService(store: store).importAll([ImportSource.file('${src.path}/missing.pdf')])).single;
    expect(item.failure, ImportFailure.sourceUnreadable);
    expect(store.reader.importJobs(), isEmpty);
  });

  test('a read-only (newer) library refuses', () async {
    // Mark the schema newer than this build.
    await store.write((w, _) => w.db.execute("UPDATE meta SET value = '999' WHERE key = 'schema_version'"));
    await store.close();
    store = await openStore(root);
    expect(store.readOnly, isTrue);
    final f = sourceFile(src, 'x.txt', [1]);
    final item = (await ImportService(store: store).importAll([ImportSource.file(f.path)])).single;
    expect(item.failure, ImportFailure.refused);
  });

  test('works with the writer on its own isolate (write closures are sendable)', () async {
    await store.close();
    store = await openStore(root, background: true);
    final f = sourceFile(src, 'iso.png', bytesOf(70 * 1024));
    final item = (await ImportService(store: store).importAll([ImportSource.file(f.path, mime: 'image/png')])).single;
    expect(item.state, ImportItemState.done);
    expect(item.entry!.kind, FileKind.photo);
    final dup = sourceFile(src, 'iso2.png', f.readAsBytesSync());
    expect((await ImportService(store: store).importAll([ImportSource.file(dup.path)], duplicates: DuplicatePolicy.skip)).single.state, ImportItemState.skipped);
  });

  test('dispose keeps the running job for the next launch', () async {
    final file = sourceFile(src, 'big.bin', Uint8List(96 * 1024 * 1024));
    final service = ImportService(store: store);
    service.enqueue(ImportSource.file(file.path));
    await eventually(() => service.items.single.bytesDone > 0);
    await service.dispose();
    expect(store.reader.importJobs(), hasLength(1));
    final next = ImportService(store: store);
    final item = await next.result((await next.resumePending()).single);
    expect(item.state, ImportItemState.done);
    expect(item.entry!.sizeBytes, 96 * 1024 * 1024);
  });

  group('ImportSource', () {
    test('round-trips through source_desc', () {
      final s = ImportSource.file(
        '/tmp/staging/IMG 1.HEIC',
        uti: 'public.heic',
        mime: 'image/heic',
        sizeBytes: 12,
        modifiedAt: DateTime.utc(2024, 5, 6, 7, 8, 9),
        sourceHint: SourceHint.photos,
        stagedCopy: true,
        releaseUri: 'file:///x',
      );
      expect(s.displayName, 'IMG 1.HEIC');
      expect(ImportSource.tryDecode(s.encode()), s);
      const u = ImportSource(kind: ImportSourceKind.nativeUri, location: 'content://a/b', displayName: 'b.pdf', sourceHint: SourceHint.openWith);
      expect(ImportSource.tryDecode(u.encode()), u);
    });

    test('garbage decodes to null', () {
      for (final t in [null, '', 'x', '[]', '{"kind":"file"}', '{"kind":"zip","loc":"a","name":"b"}']) {
        expect(ImportSource.tryDecode(t), isNull, reason: '$t');
      }
    });

    test('toString holds no name or path (rule 30)', () {
      final s = ImportSource.file('/secret/dir/Private Name.pdf');
      expect(s.toString(), isNot(contains('Private')));
      expect(s.toString(), isNot(contains('secret')));
    });
  });

  test('importDisplayName makes a valid entry name', () {
    expect(importDisplayName('a/b\\c.pdf'), 'a_b_c.pdf');
    expect(importDisplayName('  '), 'Imported file');
    expect(importDisplayName('..'), 'Imported file');
    final long = '${'é' * 200}.pdf';
    final cut = importDisplayName(long);
    expect(isValidEntryName(cut), isTrue);
    expect(cut, endsWith('.pdf'));
  });

  test('computeQuickHash matches the v1.1 definition', () async {
    final small = bytesOf(1000);
    final f = sourceFile(src, 's.bin', small);
    expect(await quickHashOfFile(f.path), sha1.convert([...small, ...':1000'.codeUnits]).toString());
    final big = bytesOf(200 * 1024);
    final g = sourceFile(src, 'b.bin', big);
    final expected = sha1.convert([...big.sublist(0, 65536), ...big.sublist(big.length - 65536), ...':${big.length}'.codeUnits]).toString();
    expect(await quickHashOfFile(g.path), expected);
    expect(computeQuickHash(Uint8List(0), Uint8List(0), 0), '');
  });

  test('FileImportCopier resumes with a hash over the whole file', () async {
    final bytes = bytesOf(3 * 1024 * 1024 + 5);
    final f = sourceFile(src, 'r.bin', bytes);
    final part = File('${tempDir('hom20_part_').path}/x.part')..writeAsBytesSync([...bytes.sublist(0, 1000000), 9, 9, 9]);
    final checkpoints = <int>[];
    final out = await const FileImportCopier(checkpointBytes: 1024 * 1024)
        .start(source: ImportSource.file(f.path), partPath: part.path, resumeFrom: 1000000, hash: true, onProgress: (_) {}, onCheckpoint: checkpoints.add)
        .done;
    expect(out.bytes, bytes.length);
    expect(out.sha256, sha256.convert(bytes).toString());
    expect(part.readAsBytesSync(), bytes);
    expect(checkpoints.last, bytes.length);
    expect(checkpoints, hasLength(greaterThanOrEqualTo(2)));
  });
}
