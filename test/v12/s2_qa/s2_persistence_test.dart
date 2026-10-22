// OWNER: S2-Q
//
// Slice S2 QA (BUILD_PLAN v1.2 §1A, S2-Q; the S2 share of QA-106): what S2 stores survives an app
// restart when opened the way the app opens it (`filesHomeOverrides` → HOM-17 `LibraryStore.open`
// with the writer on its own isolate, under `libraryRootIn(<support>)`):
//
// * nested Danaview folders, a folder's sort, imported files (bytes), favourites, Recents and
//   Recently deleted (days left) across a close and reopen;
// * Recently deleted expiry with a fake clock across restarts: 29 days later the item is still
//   there, 31 days later the launch sweep purges it (row and files);
// * a corrupt `library.db` is quarantined at the next start and the library is rebuilt from the
//   files, so the Home keeps its Danaview files;
// * backup classes: `library.db` and `files/` included, `imports/` excluded;
// * originals are never changed by an import (bytes and timestamp).

// The root package reaches the library through danaview_features.
// ignore_for_file: depend_on_referenced_packages, implementation_imports

import 'dart:io';

import 'package:danaview/wiring/files_home_wiring.dart';
import 'package:danaview_features/src/flags.dart';
import 'package:danaview_library/danaview_library.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Write ops are built in top-level functions so their closures capture only sendable values: the
// app's store runs the writer on another isolate.
LibraryWrite<FolderId> _createFolder(String name, FolderId? parent) => (w, now) => w.createFolder(name, parent: parent, now: now);
LibraryWrite<void> _folderSort(FolderId id) => (w, _) => w.setFolderSort(id, 'name', descending: true);
LibraryWrite<void> _favourite(EntryId id) => (w, _) => w.setEntryFavourite(id, true);
LibraryWrite<void> _opened(EntryId id) => (w, now) => w.markOpened(id, now: now);
LibraryWrite<void> _trash(EntryId id) => (w, now) => w.trashEntries([id], now: now);
LibraryWrite<FolderId?> _restore(EntryId id) => (w, now) => w.restore(id, now: now);

final class _Clock {
  _Clock(this.now);
  DateTime now;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory support;
  late Directory originals;
  late SharedPreferences prefs;
  late _Clock clock;

  setUp(() async {
    FeatureFlags.debugFilesHomeOverride = true;
    support = Directory.systemTemp.createTempSync('s2q_support_');
    originals = Directory.systemTemp.createTempSync('s2q_originals_');
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    clock = _Clock(DateTime.utc(2026, 10, 1, 12));
  });

  tearDown(() {
    FeatureFlags.debugReset();
    support.deleteSync(recursive: true);
    originals.deleteSync(recursive: true);
  });

  /// One app start: the S2 wiring with the app's store opener (isolate writer) and a fake clock.
  Future<FilesHomeRuntime> start() => filesHomeOverrides(
        prefs: prefs,
        platform: TargetPlatform.linux,
        directories: FilesHomeDirectories(support: support.path, cache: '${support.path}/cache'),
        openStore: (root, backup) => LibraryStore.open(root: root, backup: backup, clock: () => clock.now),
        openThumbnails: (_) async => throw const FileSystemException('no thumbnails in tests'),
        observeLifecycle: false,
      );

  File original(String name, List<int> bytes) => File('${originals.path}/$name')..writeAsBytesSync(bytes);

  Future<FileEntry> import(LibraryStore store, File file, {FolderId? folder}) async {
    final service = ImportService(store: store);
    final item = (await service.importAll([ImportSource.file(file.path)], target: folder)).single;
    await service.dispose();
    expect(item.state, ImportItemState.done, reason: '${item.state}');
    return store.reader.allEntries().singleWhere((e) => e.displayName == file.uri.pathSegments.last);
  }

  test('folders, files, favourites, Recents and Recently deleted survive a restart', () async {
    final photoBytes = List<int>.generate(4096, (i) => i % 251);
    final photo = original('Beach.jpg', photoBytes);
    final video = original('Clip.mp4', List<int>.filled(2048, 9));
    final photoStamp = photo.lastModifiedSync();

    var app = await start();
    var store = app.store!;
    expect(store.paths.root, libraryRootIn(support.path, LibraryRootStyle.appSupport));
    final trips = await store.write(_createFolder('Trips', null));
    final japan = await store.write(_createFolder('Japan', trips));
    await store.write(_folderSort(japan));
    final p = await import(store, photo, folder: japan);
    final v = await import(store, video, folder: trips);
    await store.write(_favourite(p.id));
    await store.write(_opened(p.id));
    await store.write(_trash(v.id));
    await app.dispose();

    clock.now = clock.now.add(const Duration(days: 3));
    app = await start();
    store = app.store!;
    final r = store.reader;
    expect(r.pathOf(japan).map((f) => f.name), ['Trips', 'Japan']);
    expect(r.folder(japan)!.sortMode, 'name');
    expect(r.entry(p.id)!.folderId, japan);
    expect(r.entry(p.id)!.isFavourite, isTrue);
    expect(r.recents().map((e) => e.id), [p.id]);
    expect(File(store.paths.entryFile(p.id, 'Beach.jpg')).readAsBytesSync(), photoBytes);
    final trashed = r.recentlyDeleted().single;
    expect(trashed.name, 'Clip.mp4');
    expect(trashed.daysLeft(clock.now), 27);
    // checkInvariants() is not callable with the isolate writer (FIX-S2Q-2), so the rows are checked here.
    expect(r.allEntries().every((x) => File(store.paths.entryFile(x.id, x.displayName)).existsSync()), isTrue);
    // Restore after the restart goes back to Trips.
    expect(await store.write(_restore(v.id)), trips);
    expect(r.entry(v.id)!.isTrashed, isFalse);
    await app.dispose();

    expect(photo.readAsBytesSync(), photoBytes, reason: 'originals unchanged');
    expect(photo.lastModifiedSync(), photoStamp);
  });

  test('Recently deleted expires after 30 days across restarts (fake clock)', () async {
    var app = await start();
    var store = app.store!;
    final e = await import(store, original('Old.jpg', List<int>.filled(100, 1)));
    await store.write(_trash(e.id));
    final dir = store.paths.entryDir(e.id);
    await app.dispose();

    clock.now = clock.now.add(const Duration(days: 29));
    app = await start();
    store = app.store!;
    expect(store.openReport.sweep.entries, 0);
    expect(store.reader.recentlyDeleted().single.daysLeft(clock.now), 1);
    await app.dispose();

    clock.now = clock.now.add(const Duration(days: 2));
    app = await start();
    store = app.store!;
    expect(store.openReport.sweep.entries, 1, reason: 'the launch sweep purges the expired item');
    expect(store.reader.entry(e.id), isNull);
    expect(store.reader.recentlyDeleted(), isEmpty);
    expect(Directory(dir).existsSync(), isFalse, reason: 'its files are gone');
    await app.dispose();
  });

  test('a corrupt library.db is quarantined and rebuilt from the files at the next start', () async {
    var app = await start();
    var store = app.store!;
    final e = await import(store, original('Keep.jpg', List<int>.filled(300, 3)));
    final root = store.paths.root;
    await app.dispose();
    for (final suffix in ['', '-wal', '-shm']) {
      final f = File('$root/library.db$suffix');
      if (f.existsSync()) f.deleteSync();
    }
    File('$root/library.db').writeAsStringSync('not a database ' * 200);

    app = await start();
    store = app.store!;
    expect(store, isNotNull, reason: 'the Home keeps a library');
    expect(store.openReport.rebuilt, isTrue);
    expect(store.reader.allEntries().map((x) => x.displayName), contains('Keep.jpg'));
    expect(store.reader.allEntries().singleWhere((x) => x.displayName == 'Keep.jpg').id, e.id);
    expect(File(store.paths.entryFile(e.id, 'Keep.jpg')).lengthSync(), 300);
    await app.dispose();
  });

  test('backup classes: library.db and files/ included, imports/ excluded', () async {
    final app = await start();
    final store = app.store!;
    expect(store.backupClassOf(store.paths.databasePath), LibraryBackupClass.included);
    expect(store.backupClassOf(store.paths.filesDir), LibraryBackupClass.included);
    expect(store.backupClassOf(store.paths.importsDir), LibraryBackupClass.excluded);
    await app.dispose();
  });
}
