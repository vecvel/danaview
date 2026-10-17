// OWNER: CORE-27
//
// ManagedStore: content-addressed layout, sanitized names, copy vs. move (only when the guard's
// canConsume allows), reuse, backup exclusion, and crash safety of copies (FaultInjectingFs).

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_editor_core/store.dart';

import 'support/media_fixtures.dart';

const hash = '0123456789abcdef0123456789abcdef01234567';

void main() {
  group('names and paths', () {
    test('content-addressed relative path', () {
      expect(ManagedStore.mediaRelPath(hash, 'IMG_0001.MOV'), 'danaview/editor/media/01/$hash/IMG_0001.mov');
      expect(ManagedStore.projectAssetRelPath('pr_a', 'luts', 'md_x.cube'), 'danaview/editor/projects/pr_a/assets/luts/md_x.cube');
      expect(ManagedStore.vlutOf(const AppRelativeLocator(AppRoot.support, 'a/b/md_x.cube')), const AppRelativeLocator(AppRoot.support, 'a/b/md_x.vlut'));
    });

    test('rejects non-hash keys and unsafe segments', () {
      expect(() => ManagedStore.mediaRelPath('../x', 'a.mp4'), throwsArgumentError);
      expect(() => ManagedStore.mediaRelPath('', 'a.mp4'), throwsArgumentError);
      expect(() => ManagedStore.projectAssetRelPath('..', 'luts', 'a'), throwsArgumentError);
      expect(() => ManagedStore.projectAssetRelPath('pr_a', 'luts', 'x/y'), throwsArgumentError);
    });

    final cases = <String, String>{
      'clip.mp4': 'clip.mp4',
      '../../etc/passwd': 'passwd',
      r'C:\Users\me\video.MOV': 'video.mov',
      '.hidden.mp4': 'hidden.mp4',
      '...': 'media',
      '': 'media',
      'a:b*c?.mp4': 'a_b_c_.mp4',
      'tab\there.mp4': 'tab_here.mp4',
      'name.part-123.mp4': 'name_part-123.mp4',
      'Café.mp4': 'Café.mp4',
      'no extension': 'no extension',
      'weird.ext with space': 'weird.ext with space',
      'trailing dots...': 'trailing dots',
    };
    for (final e in cases.entries) {
      test('sanitize "${e.key}"', () => expect(ManagedStore.sanitizeFileName(e.key), e.value));
    }

    test('long names keep the extension within the limit', () {
      final s = ManagedStore.sanitizeFileName('${'é' * 300}.mp4');
      expect(s.length, lessThanOrEqualTo(ManagedStore.maxNameLength));
      expect(s, endsWith('.mp4'));
      final emoji = ManagedStore.sanitizeFileName('${'👍🏽' * 80}.mov');
      expect(emoji.length, lessThanOrEqualTo(ManagedStore.maxNameLength));
      expect(emoji.replaceAll('.mov', '').runes.length % 2, 0, reason: 'grapheme clusters are not split');
    });
  });

  group('adopt', () {
    late Container c;
    late FaultInjectingFs fs;
    late ManagedStore store;
    late DartIoMediaAccess access;

    setUp(() {
      c = Container.create();
      fs = FaultInjectingFs(const LocalStoreFs());
      access = DartIoMediaAccess(c.roots);
      store = ManagedStore(c.roots, fs: fs, deleter: OwnedFileDeleter(c.roots, fs: fs), access: access);
    });
    tearDown(() => c.dispose());

    test('layout: media/ and derived/ exist and are backup-excluded, once', () async {
      await store.ensureLayout();
      await store.ensureLayout();
      expect(Directory(c.roots.mediaDir).existsSync(), isTrue);
      expect(Directory(c.roots.derivedDir).existsSync(), isTrue);
      expect(access.excludedDirs, [p.normalize(c.roots.mediaDir), p.normalize(c.roots.derivedDir)]);
    });

    test('an original is copied, never moved', () async {
      final src = c.put(c.at('external/a.mp4'), bytesOf(1, 5000));
      final before = File(src).statSync();
      final s = await store.adopt(src, quickHash: hash, displayName: 'a.mp4', temporary: true /* claimed, but not app-owned */);
      expect(s.moved, isFalse);
      expect(File(src).existsSync(), isTrue);
      expect(File(src).statSync().modified, before.modified);
      expect(File(s.path).readAsBytesSync(), File(src).readAsBytesSync());
      expect(s.locator, const AppRelativeLocator(AppRoot.support, 'danaview/editor/media/01/$hash/a.mp4'));
    });

    test('a work/picks clone is moved', () async {
      final src = c.put(p.join(c.roots.picksDir, 'u1', 'IMG.MOV'), bytesOf(2, 5000));
      final s = await store.adopt(src, quickHash: hash, displayName: 'IMG.MOV', temporary: true);
      expect(s.moved, isTrue);
      expect(File(src).existsSync(), isFalse);
      expect(File(s.path).lengthSync(), 5000);
      expect(fs.log.where((o) => o.kind == FsOpKind.copy), isEmpty);
    });

    test('a symlink in work/picks pointing at an original is copied, never moved', () async {
      final original = c.put(c.at('external/orig.mp4'), bytesOf(3, 4000));
      final link = p.join(c.roots.picksDir, 'u2', 'orig.mp4');
      Directory(p.dirname(link)).createSync(recursive: true);
      Link(link).createSync(original);
      final s = await store.adopt(link, quickHash: hash, displayName: 'orig.mp4', temporary: true);
      expect(s.moved, isFalse);
      expect(File(original).existsSync(), isTrue);
      expect(File(s.path).readAsBytesSync(), File(original).readAsBytesSync());
    });

    test('existing content is reused and the duplicate temp clone removed', () async {
      final a = c.put(c.at('external/a.mp4'), bytesOf(4, 100));
      final first = await store.adopt(a, quickHash: hash, displayName: 'a.mp4');
      final clone = c.put(p.join(c.roots.picksDir, 'u3', 'other name.mp4'), bytesOf(4, 100));
      final second = await store.adopt(clone, quickHash: hash, displayName: 'other name.mp4', temporary: true);
      expect(second.reused, isTrue);
      expect(second.locator, first.locator);
      expect(File(clone).existsSync(), isFalse);
      expect(Directory(p.dirname(first.path)).listSync(), hasLength(1));
    });

    test('a leftover .part file is not mistaken for a copy', () async {
      c.put(p.join(c.roots.mediaDir, '01', hash, 'a.mp4.part-xyz'), [1, 2]);
      expect(await store.findManaged(hash), isNull);
    });

    test('disk full during the copy: no final file, no part file, original intact', () async {
      final src = c.put(c.at('external/a.mp4'), bytesOf(5, 3000));
      fs.failWhere((op) => op.kind == FsOpKind.copy, StoreFailureKind.diskFull);
      await expectLater(
        store.adopt(src, quickHash: hash, displayName: 'a.mp4'),
        throwsA(isA<StoreFailure>().having((e) => e.kind, 'kind', StoreFailureKind.diskFull)),
      );
      final dir = Directory(p.join(c.roots.mediaDir, '01', hash));
      expect(dir.existsSync() ? dir.listSync() : const <FileSystemEntity>[], isEmpty);
      expect(File(src).lengthSync(), 3000);
    });

    test('a crash at every step never leaves a torn file under its final name', () async {
      final src = c.put(c.at('external/a.mp4'), bytesOf(6, 7000));
      // Count the steps of a clean run.
      final probeStore = ManagedStore(c.roots, fs: fs, deleter: OwnedFileDeleter(c.roots, fs: fs));
      await probeStore.adopt(src, quickHash: hash, displayName: 'a.mp4');
      final steps = fs.steps;
      expect(steps, greaterThanOrEqualTo(3));
      for (var n = 1; n <= steps; n++) {
        for (final torn in TornWrite.values) {
          Directory(c.roots.mediaDir).deleteSync(recursive: true);
          fs
            ..reset()
            ..crashAtStep(n, torn: torn);
          final s = ManagedStore(c.roots, fs: fs, deleter: OwnedFileDeleter(c.roots, fs: fs));
          try {
            await s.adopt(src, quickHash: hash, displayName: 'a.mp4');
          } on SimulatedCrash {
            // expected for every step
          }
          fs.restart();
          final found = await ManagedStore(c.roots, fs: fs, deleter: OwnedFileDeleter(c.roots, fs: fs)).findManaged(hash);
          if (found != null) {
            expect(File(found.path).readAsBytesSync(), File(src).readAsBytesSync(), reason: 'step $n ${torn.name}');
          }
          // After the "restart" the import completes.
          final again = await ManagedStore(c.roots, fs: fs, deleter: OwnedFileDeleter(c.roots, fs: fs)).adopt(src, quickHash: hash, displayName: 'a.mp4');
          expect(File(again.path).readAsBytesSync(), File(src).readAsBytesSync(), reason: 'step $n ${torn.name}');
          expect(File(src).lengthSync(), 7000);
        }
      }
    });
  });

  group('project files', () {
    late Container c;
    late ManagedStore store;
    setUp(() {
      c = Container.create();
      store = ManagedStore(c.roots);
    });
    tearDown(() => c.dispose());

    test('writeProjectBytes replaces atomically', () async {
      final rel = ManagedStore.projectAssetRelPath('pr_a', 'luts', 'md_1.vlut');
      await store.writeProjectBytes(rel, bytesOf(1, 10));
      final s = await store.writeProjectBytes(rel, bytesOf(2, 20));
      expect(File(s.path).lengthSync(), 20);
      expect(Directory(p.dirname(s.path)).listSync(), hasLength(1));
    });

    test('storeProjectFile keeps a file already in place', () async {
      final rel = ManagedStore.projectAssetRelPath('pr_a', 'recordings', 'md_1.wav');
      final path = c.put(c.roots.resolve(AppRelativeLocator(AppRoot.support, rel)), [1, 2, 3]);
      final s = await store.storeProjectFile(path, rel);
      expect(s.reused, isTrue);
      expect(File(path).readAsBytesSync(), [1, 2, 3]);
    });

    test('discardTemporary leaves originals alone', () async {
      final original = c.put(c.at('external/x.mp4'), [1]);
      final doc = c.put(p.join(c.roots.documents, 'x.mp4'), [2]);
      await store.discardTemporary(original);
      await store.discardTemporary(doc);
      expect(File(original).existsSync(), isTrue);
      expect(File(doc).existsSync(), isTrue);
      final temp = c.put(p.join(c.roots.picksDir, 'u', 'x.mp4'), [3]);
      await store.discardTemporary(temp);
      expect(File(temp).existsSync(), isFalse);
    });
  });
}
