// OWNER: HOM-22
//
// BUILD_PLAN HOM-22, library half: every file action updates library.db and fires the store's
// change stream (the UI's re-query); rename keeps the extension and dedupes; Copy to… makes new
// entries with the same bytes and leaves the original; Move to… is one transaction; favourites
// toggle as a group; the delete warning counts projects and photo edits ("Used in N projects");
// delete goes to Recently deleted; out files are the library files (the platform only reads them)
// and never trashed or missing ones; File info from the database and from plain items; folder
// choices in path order. Generated files only, in a temp root.

import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:danaview_library/testing.dart';
import 'package:test/test.dart';

import '../support/sqlite_open.dart';

final DateTime t0 = DateTime.utc(2026, 10, 1, 12);

String _tempRoot() {
  final dir = Directory.systemTemp.createTempSync('hom22_');
  addTearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });
  return dir.path;
}

Future<LibraryStore> _open(FakeLibraryClock clock) async {
  final store = await LibraryStore.open(root: _tempRoot(), clock: clock.call, background: false, random: Random(22));
  addTearDown(store.close);
  return store;
}

Future<FileEntry> _import(LibraryStore store, String name, {FolderId? folder, List<int>? bytes, String? mime, String? uti}) =>
    store.write((w, now) {
      final c = classify(fileName: name);
      final data = bytes ?? name.codeUnits;
      final job = w.beginImport(target: folder, bytesTotal: data.length, now: now);
      final part = w.fs.openPart(job.id);
      part.writeFromSync(data);
      part.closeSync();
      w.recordImportProgress(job.id, data.length);
      return w.commitImport(
        job.id,
        ImportedFileInfo(displayName: name, kind: c.kind, subKind: c.subKind, mime: mime, uti: uti, sourceHint: SourceHint.files),
        now: now,
      );
    });

MediaItem _itemOf(FileEntry e) => PhotoMediaItem(
      id: e.id,
      uri: '/unused/${e.displayName}',
      name: e.displayName,
      modifiedAt: e.modifiedAt,
      mimeType: 'image/jpeg',
      width: 1,
      height: 1,
    );

void main() {
  setUpAll(useHostSqlite);
  late FakeLibraryClock clock;
  late LibraryStore store;
  late LibraryFileActions actions;
  late int changes;

  setUp(() async {
    clock = FakeLibraryClock(t0);
    store = await _open(clock);
    actions = LibraryFileActions(store);
    changes = 0;
    final sub = store.changes.listen((_) => changes++);
    addTearDown(sub.cancel);
  });

  test('rename updates the row and the file, keeps the extension and dedupes in the folder', () async {
    final a = await _import(store, 'Trip.jpg');
    await _import(store, 'Beach.jpg');
    final before = changes;
    expect(await actions.rename(a.id, 'Beach'), 'Beach (2).jpg');
    expect(changes, greaterThan(before), reason: 'the UI re-queries');
    final e = store.reader.entry(a.id)!;
    expect(e.displayName, 'Beach (2).jpg');
    expect(File(actions.pathOf(e)).existsSync(), isTrue);
    expect(File(store.paths.entryFile(a.id, 'Trip.jpg')).existsSync(), isFalse);
    expect(await actions.rename(a.id, '  Sunset.png '), 'Sunset.png', reason: 'a typed extension wins');
    await expectLater(actions.rename(a.id, 'a/b'), throwsA(isA<LibraryWriteException>()));
  });

  test('rename helpers', () {
    expect(resolvedRename('Photo.HEIC', 'Holiday'), 'Holiday.HEIC');
    expect(resolvedRename('README', 'Notes'), 'Notes');
    expect(resolvedRename('a.pdf', ' b.txt '), 'b.txt');
    expect(renameProblem('a.pdf', '   '), 'Enter a name');
    expect(renameProblem('a.pdf', 'x/y'), isNotNull);
    expect(renameProblem('a.pdf', 'Good name'), isNull);
  });

  test('Copy to… makes new entries with the same bytes and leaves the originals', () async {
    final trips = await store.write((w, now) => w.createFolder('Trips', now: now));
    final a = await _import(store, 'A.pdf', bytes: [1, 2, 3], mime: 'application/pdf');
    final before = changes;
    final copies = await actions.copyTo([a.id], trips);
    expect(changes, greaterThan(before));
    expect(copies, hasLength(1));
    final copy = copies.single;
    expect(copy.id, isNot(a.id));
    expect(copy.folderId, trips);
    expect(copy.displayName, 'A.pdf');
    expect(File(actions.pathOf(copy)).readAsBytesSync(), [1, 2, 3]);
    final original = store.reader.entry(a.id)!;
    expect(original.folderId, a.folderId);
    expect(File(actions.pathOf(original)).readAsBytesSync(), [1, 2, 3]);
  });

  test('Move to… moves every entry in one write and dedupes names there', () async {
    final trips = await store.write((w, now) => w.createFolder('Trips', now: now));
    final inTrips = await _import(store, 'A.jpg', folder: trips);
    final a = await _import(store, 'A.jpg');
    final b = await _import(store, 'B.jpg');
    final before = changes;
    await actions.moveTo([a.id, b.id], trips);
    expect(changes, before + 1, reason: 'one write');
    expect(store.reader.entry(a.id)!.folderId, trips);
    expect(store.reader.entry(a.id)!.displayName, 'A (2).jpg');
    expect(store.reader.entry(b.id)!.folderId, trips);
    expect(store.reader.entry(inTrips.id)!.displayName, 'A.jpg');
    expect(File(actions.pathOf(store.reader.entry(a.id)!)).existsSync(), isTrue);
  });

  test('favourites toggle as a group', () async {
    final a = await _import(store, 'A.jpg');
    final b = await _import(store, 'B.jpg');
    await actions.setFavourites([a.id], true);
    expect(actions.allFavourite([a.id, b.id]), isFalse);
    expect(await actions.toggleFavourites([a.id, b.id]), isTrue, reason: 'stars all when some are not');
    expect(store.reader.entry(a.id)!.isFavourite && store.reader.entry(b.id)!.isFavourite, isTrue);
    expect(await actions.toggleFavourites([a.id, b.id]), isFalse, reason: 'unstars all when all are');
    expect(store.reader.entry(b.id)!.isFavourite, isFalse);
  });

  test('the delete warning counts holders; delete goes to Recently deleted', () async {
    final a = await _import(store, 'A.mp4');
    final b = await _import(store, 'B.jpg');
    final c = await _import(store, 'C.pdf');
    expect(deleteWarningText(actions.deleteUsage([c.id])), isNull);
    await store.write((w, _) {
      w.addRef(a.id, RefHolder.project('p1'));
      w.addRef(a.id, RefHolder.project('p2'));
      w.addRef(b.id, RefHolder.project('p2'));
      w.addRef(b.id, RefHolder.photo('ph1'));
    });
    final usage = actions.deleteUsage([a.id, b.id]);
    expect((usage.projects, usage.photos), (2, 1));
    expect(deleteWarningText(usage), 'Used in 2 projects and 1 photo edit');
    expect(deleteWarningText(actions.deleteUsage([b.id])), 'Used in 1 project and 1 photo edit');
    expect(deleteWarningText(const RefUsage(projects: 1, photos: 0)), 'Used in 1 project');
    expect(deleteWarningText(const RefUsage(projects: 0, photos: 3)), 'Used in 3 photo edits');

    final before = changes;
    await actions.delete([a.id, c.id]);
    expect(changes, greaterThan(before));
    final trashed = store.reader.entry(a.id)!;
    expect(trashed.isTrashed, isTrue);
    expect(trashed.expiresAt, t0.add(recentlyDeletedRetention));
    expect(File(actions.pathOf(trashed)).existsSync(), isTrue, reason: 'files stay until the purge (V2-08)');
    expect(actions.liveEntry(a.id), isNull);
    expect(store.reader.recentlyDeleted().map((t) => t.id), containsAll([a.id, c.id]));
  });

  test('out files are the library files, with stored types; trashed, missing and pathless items are skipped', () async {
    final a = await _import(store, 'Report.pdf', mime: 'application/pdf', uti: 'com.adobe.pdf');
    final b = await _import(store, 'Gone.jpg');
    final c = await _import(store, 'Bin.jpg');
    File(actions.pathOf(b)).deleteSync();
    await actions.delete([c.id]);
    final linked = File('${_tempRoot()}/linked.txt')..writeAsStringSync('x');
    final targets = [
      FileActionTarget.of(_itemOf(a)),
      FileActionTarget.of(_itemOf(b)),
      FileActionTarget.of(_itemOf(c)),
      FileActionTarget.of(DocumentItem(
        id: ItemId.parse('lk:root1/linked.txt'),
        uri: linked.uri.toString(),
        name: 'linked.txt',
        modifiedAt: t0,
        mimeType: 'text/plain',
        docKind: DocumentKind.text,
      )),
      FileActionTarget.of(PhotoMediaItem(id: ItemId.parse('ph:ABC/L0/001'), uri: 'ph:ABC/L0/001', name: 'IMG.HEIC', modifiedAt: t0, mimeType: 'image/heic', width: 1, height: 1)),
    ];
    final out = actions.outFiles(targets);
    expect(out, [
      OutFile(path: actions.pathOf(a), displayName: 'Report.pdf', mime: 'application/pdf', uti: 'com.adobe.pdf'),
      OutFile(path: linked.path, displayName: 'linked.txt', mime: 'text/plain'),
    ]);
    expect(out.first.path.startsWith(store.paths.filesDir), isTrue);
    expect(out.first.toString(), isNot(contains('Report')), reason: 'rule 30');
  });

  test('File info from library.db and from plain items', () async {
    final trips = await store.write((w, now) => w.createFolder('Trips', now: now));
    final y2026 = await store.write((w, now) => w.createFolder('2026', parent: trips, now: now));
    clock.advance(const Duration(hours: 1));
    final a = await _import(store, 'Beach.heic', folder: y2026, bytes: List.filled(1234, 1));
    await store.write((w, _) => w.setMeta(a.id, EntryMeta(width: 4032, height: 3024, camera: 'iPhone 16', takenAt: t0)));
    await actions.setFavourites([a.id], true);
    final info = actions.info(_itemOf(a));
    expect(info.name, 'Beach.heic');
    expect(info.typeLabel, 'HEIC photo');
    expect(info.sizeBytes, 1234);
    expect(info.folderPath, ['Trips', '2026']);
    expect((info.width, info.height, info.camera), (4032, 3024, 'iPhone 16'));
    expect(info.source, SourceHint.files);
    expect(sourceLabel(info.source!), 'Files');
    expect(info.isFavourite, isTrue);
    expect(info.readOnly, isFalse);
    expect(info.addedAt, t0.add(const Duration(hours: 1)));

    final video = VideoMediaItem(
      id: ItemId.opaque('legacy-video'),
      uri: '/movies/clip.mp4',
      name: 'clip.mp4',
      modifiedAt: t0,
      mimeType: 'video/mp4',
      duration: const Duration(seconds: 42),
      frameRate: 59.94,
      sizeBytes: 99,
    );
    final vi = actions.info(video);
    expect(vi.readOnly, isTrue);
    expect(vi.typeLabel, 'MP4 video');
    expect(vi.duration, const Duration(seconds: 42));
    expect(vi.frameRate, 59.94);
    expect(typeLabelOf('README', FileKind.document), 'Document');
  });

  test('folder choices are the live folders in natural path order', () async {
    final b = await store.write((w, now) => w.createFolder('Trips', now: now));
    await store.write((w, now) => w.createFolder('2026', parent: b, now: now));
    await store.write((w, now) => w.createFolder('Album 10', now: now));
    await store.write((w, now) => w.createFolder('Album 9', now: now));
    final gone = await store.write((w, now) => w.createFolder('Gone', now: now));
    await store.write((w, now) => w.trashFolder(gone, now: now));
    final labels = [for (final c in actions.folderChoices()) c.label];
    expect(labels, containsAllInOrder(['Album 9', 'Album 10', 'Imported', 'Trips', 'Trips › 2026']));
    expect(labels, isNot(contains('Gone')));
    expect(actions.folderChoices().firstWhere((c) => c.name == '2026').depth, 1);
  });
}
