// OWNER: HOM-21
//
// Open with Danaview (ARCH v1.2 §5.6, P-7, P-8): photos and documents are imported into Imported
// (`sourceHint = openWith`) and opened; videos, audio, streams and `danaview://` links keep the 1.1
// play path; the source is only read unless it is a copy the system made for the app; opening the
// same file twice opens the entry already there.

import 'dart:io';

import 'package:danaview_library/testing.dart';
import 'package:test/test.dart';

import '../import/import_harness.dart';
import '../support/sqlite_open.dart';

void main() {
  setUpAll(useHostSqlite);

  group('routeIncoming', () {
    test('photos and documents import; media, streams and links play', () {
      for (final raw in ['/var/a/Report.pdf', 'file:///var/a/Scan%20one.pdf', '/x/IMG_1.HEIC', '/x/photo.jpg', '/x/Notes.txt', '/x/Sheet.xlsx', r'C:\Users\a\b.docx']) {
        expect(routeIncoming(raw), IncomingRoute.importAndView, reason: raw);
      }
      for (final raw in ['/x/Movie.mkv', 'file:///x/clip.mp4', '/x/song.mp3', 'https://example.com/a.pdf', 'danaview://open?url=https://e.com/v.m3u8', 'danaview:///x/Report.pdf', 'rtsp://cam/stream', '/x/folder/', '/x/unknown.bin', '']) {
        expect(routeIncoming(raw), IncomingRoute.play, reason: raw);
      }
    });

    test('file URIs decode to paths', () {
      expect(incomingLocalPath('file:///var/a/Scan%20one.pdf'), '/var/a/Scan one.pdf');
      expect(incomingLocalPath('https://e.com/a.pdf'), isNull);
    });
  });

  group('IncomingOpenImporter', () {
    late Directory src;
    late LibraryStore store;
    late ImportService imports;

    setUp(() async {
      src = tempDir('hom21_open_src_');
      store = await openStore(tempDir('hom21_open_lib_').path);
      addTearDown(() => store.close());
      imports = ImportService(store: store);
      addTearDown(imports.dispose);
    });

    test('a PDF opened with Danaview lands in Imported, untouched at its source', () async {
      final bytes = bytesOf(50 * 1024);
      final file = sourceFile(src, 'Lease.pdf', bytes);
      final before = file.statSync();
      final result = await IncomingOpenImporter(imports: imports).importForViewing(file.uri.toString());

      expect(result!.item.state, ImportItemState.done);
      final entry = result.entry!;
      expect(entry.displayName, 'Lease.pdf');
      expect(entry.kind, FileKind.document);
      expect(entry.sourceHint, SourceHint.openWith);
      expect(entry.folderId, store.reader.systemFolder(FolderSystemRole.imported)!.id);
      expect(file.readAsBytesSync(), bytes);
      expect(file.statSync().modified, before.modified);
    });

    test('a copy the system made for the app is deleted after the import; the same file again opens the existing entry', () async {
      final bytes = bytesOf(8 * 1024, seed: 3);
      final inboxCopy = Directory('${src.path}/Documents/Inbox')..createSync(recursive: true);
      final first = sourceFile(inboxCopy, 'IMG_7.jpg', bytes);
      final opener = IncomingOpenImporter(imports: imports, isAppOwnedCopy: (p) => p.contains('/Documents/Inbox/'));

      final a = await opener.importForViewing(first.path);
      expect(a!.entry!.kind, FileKind.photo);
      expect(first.existsSync(), isFalse, reason: 'the app-owned Inbox copy is removed');

      final second = sourceFile(inboxCopy, 'IMG_7.jpg', bytes);
      final b = await opener.importForViewing(second.path);
      expect(b!.item.state, ImportItemState.skipped);
      expect(b.entry!.id, a.entry!.id, reason: 'opens the entry already in the library');
      expect(store.reader.allEntries(), hasLength(1));
      expect(second.existsSync(), isFalse);
    });

    test('videos return null (they play at once as in 1.1) and nothing is imported', () async {
      final file = sourceFile(src, 'Movie.mp4', bytesOf(1000));
      expect(await IncomingOpenImporter(imports: imports).importForViewing(file.path), isNull);
      expect(store.reader.allEntries(), isEmpty);
    });

    test('an unreadable file fails without an entry', () async {
      final result = await IncomingOpenImporter(imports: imports).importForViewing('${src.path}/missing.pdf');
      expect(result!.item.state, ImportItemState.failed);
      expect(result.entry, isNull);
      expect(store.reader.allEntries(), isEmpty);
    });
  });
}
