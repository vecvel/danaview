// OWNER: CORE-27
//
// DartIoMediaAccess: the plain-path MediaAccessPort (read-only on media files; backup exclusion
// guarded to the editor roots, D-44).

import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:vwish_editor_core/model.dart';
import 'package:vwish_editor_core/store.dart';

import 'support/media_fixtures.dart';

void main() {
  late Container c;
  late DartIoMediaAccess access;

  setUp(() {
    c = Container.create();
    access = DartIoMediaAccess(c.roots);
  });
  tearDown(() => c.dispose());

  group('quickHash', () {
    for (final size in [1, 1000, 65536, 65537, 100000, 131072, 300000]) {
      test('matches computeQuickHash at $size bytes', () async {
        final bytes = bytesOf(size, size);
        final path = c.put(c.at('ext/f.bin'), bytes);
        const chunk = quickHashChunkBytes;
        final head = Uint8List.sublistView(bytes, 0, size < chunk ? size : chunk);
        final tail = size > chunk ? Uint8List.sublistView(bytes, size - chunk) : Uint8List(0);
        expect(await access.quickHash(FileLocator(path)), computeQuickHash(head, tail, size));
      });
    }

    test('empty file hashes to empty string', () async {
      final path = c.put(c.at('ext/empty'), const []);
      expect(await access.quickHash(FileLocator(path)), '');
    });

    test('missing file → notFound', () async {
      await expectLater(
        access.quickHash(FileLocator(c.at('nope.mp4'))),
        throwsA(isA<MediaAccessFailure>().having((e) => e.kind, 'kind', MediaAccessFailureKind.notFound)),
      );
    });

    test('reading never changes the file', () async {
      final path = c.put(c.at('ext/keep.mp4'), bytesOf(3, 200000));
      final before = File(path).statSync();
      await access.quickHash(FileLocator(path));
      await access.resolve(FileLocator(path));
      await access.stat(FileLocator(path));
      final after = File(path).statSync();
      expect(after.modified, before.modified);
      expect(after.size, before.size);
    });
  });

  test('stat: size and mtime, null when missing or a directory', () async {
    final path = c.put(c.at('ext/a.mp4'), bytesOf(1, 1234));
    final s = await access.stat(FileLocator(path));
    expect(s!.sizeBytes, 1234);
    expect(s.modifiedMs, isNotNull);
    expect(await access.stat(FileLocator(c.at('ext/missing.mp4'))), isNull);
    expect(await access.stat(FileLocator(c.at('ext'))), isNull);
  });

  test('app-relative locators resolve under their root', () async {
    final path = c.put(p.join(c.roots.documents, 'Movies', 'a.mp4'), bytesOf(2, 10));
    final r = await access.resolve(const AppRelativeLocator(AppRoot.documents, 'Movies/a.mp4'));
    expect(r.uri, Uri.file(path).toString());
    expect(r.fingerprint, await access.quickHash(FileLocator(path)));
  });

  test('content URIs and bookmarks need the engine', () async {
    final lost = throwsA(isA<MediaAccessFailure>().having((e) => e.kind, 'kind', MediaAccessFailureKind.accessLost));
    await expectLater(access.stat(const ContentUriLocator('content://x/1')), lost);
    await expectLater(access.quickHash(const BookmarkLocator('AAAA')), lost);
  });

  group('persist', () {
    test('Documents files become documents-relative (no container path persisted)', () async {
      final l = await access.persist(PickedMedia(uri: Uri.file(p.join(c.roots.documents, 'x y.mp4')).toString(), displayName: 'x y.mp4'));
      expect(l, const AppRelativeLocator(AppRoot.documents, 'x y.mp4'));
    });

    test('other paths stay file locators (desktop)', () async {
      expect(await access.persist(const PickedMedia(uri: '/Users/me/a.mov', displayName: 'a.mov')), const FileLocator('/Users/me/a.mov'));
    });

    test('content URIs are not persistable here', () async {
      await expectLater(access.persist(const PickedMedia(uri: 'content://x/1', displayName: 'x')), throwsA(isA<MediaAccessFailure>()));
    });
  });

  group('excludeFromBackup (D-44)', () {
    test('accepts the editor and speech roots and their subfolders', () async {
      for (final d in [c.roots.mediaDir, c.roots.derivedDir, c.roots.speechSupport, p.join(c.roots.editorCache, 'proxies'), c.roots.editorSupport]) {
        await access.excludeFromBackup(d);
      }
      expect(access.excludedDirs, hasLength(5));
    });

    test('refuses Documents, the bare roots, relative and escaping paths', () async {
      for (final d in [
        c.roots.documents,
        p.join(c.roots.documents, 'Exports'),
        c.roots.support,
        c.roots.cache,
        'vwish/editor/media',
        '${c.roots.mediaDir}/../../../../documents',
        p.join(c.roots.support, 'vwish'),
        '/',
      ]) {
        await expectLater(
          access.excludeFromBackup(d),
          throwsA(isA<MediaAccessFailure>().having((e) => e.kind, 'kind', MediaAccessFailureKind.outsideEditorRoots)),
          reason: d,
        );
      }
      expect(access.excludedDirs, isEmpty);
    });
  });

  test('grant budget is effectively unlimited for plain paths', () async {
    expect(await access.remainingGrantBudget(), greaterThan(1000));
  });
}
