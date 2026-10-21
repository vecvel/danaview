// OWNER: HOM-01
//
// V2-09 id namespaces: parsing, validation and accessors (BUILD_PLAN HOM-01).

import 'dart:math';

import 'package:danaview_library/danaview_library.dart';
import 'package:test/test.dart';

void main() {
  group('valid ids parse into their namespace', () {
    final cases = <String, IdNamespace>{
      'fe_abc123': IdNamespace.entry,
      'fe_A-b_9': IdNamespace.entry,
      'fd_root': IdNamespace.folder,
      'lk:root1/Movies/clip.mp4': IdNamespace.linked,
      'lk:r/a b/ü.mov': IdNamespace.linked,
      'ph:9F983DBA-EC35-42B8-8773-B597CF782EDD/L0/001': IdNamespace.photoKit,
      'ms:0': IdNamespace.mediaStore,
      'ms:9223372036854775807': IdNamespace.mediaStore,
    };
    cases.forEach((raw, ns) {
      test(raw, () {
        final id = ItemId.parse(raw);
        expect(id.value, raw);
        expect(id.namespace, ns);
        expect(id.isNamespaced, isTrue);
        expect(ItemId.tryParse(raw), id);
      });
    });
  });

  group('malformed ids are rejected', () {
    const malformed = [
      '',
      'fe_',
      'fd_',
      'fe_has space',
      'fe_dot.dot',
      'fe_slash/x',
      'lk:',
      'lk:root',
      'lk:/rel.mp4',
      'lk:root/',
      'lk:root//a.mp4',
      'lk:root/a/../b.mp4',
      'lk:root/./b.mp4',
      'lk:root/a/',
      r'lk:root/a\b.mp4',
      'lk:ro ot/a.mp4',
      'lk:root/a\u0000b',
      'ph:',
      'ph:has space',
      'ph:tab\there',
      'ms:',
      'ms:-1',
      'ms:01',
      'ms:12a',
      'ms:9223372036854775808',
      'ms:99999999999999999999',
      'FE_upper',
      'xx:unknown',
      '/Users/me/movie.mp4',
      'https://example.com/a.mp4',
    ];
    for (final raw in malformed) {
      test(raw.isEmpty ? '(empty)' : raw, () {
        expect(() => ItemId.parse(raw), throwsA(isA<MalformedIdException>()));
        expect(ItemId.tryParse(raw), isNull);
      });
    }

    test('over-long tokens and ids', () {
      expect(EntryId.tryParse('fe_${'a' * 64}'), isNotNull);
      expect(EntryId.tryParse('fe_${'a' * 65}'), isNull);
      expect(LinkedItemId.tryParse('lk:${'r' * 65}/a'), isNull);
      expect(PhotoKitId.tryParse('ph:${'p' * 256}'), isNotNull);
      expect(PhotoKitId.tryParse('ph:${'p' * 257}'), isNull);
      expect(LinkedItemId.tryParse('lk:r/${'a' * (maxItemIdLength - 5)}'), isNotNull);
      expect(LinkedItemId.tryParse('lk:r/${'a' * (maxItemIdLength - 4)}'), isNull);
    });
  });

  test('typed parsers accept only their namespace', () {
    expect(EntryId.tryParse('fd_x'), isNull);
    expect(FolderId.tryParse('fe_x'), isNull);
    expect(LinkedItemId.tryParse('ph:x'), isNull);
    expect(PhotoKitId.tryParse('ms:1'), isNull);
    expect(MediaStoreId.tryParse('lk:r/a'), isNull);
    expect(() => EntryId.parse('fd_x'), throwsA(isA<MalformedIdException>()));
    expect(() => FolderId.parse('fd_'), throwsA(isA<MalformedIdException>()));
    expect(() => MediaStoreId.parse('ms:x'), throwsA(isA<MalformedIdException>()));
    expect(() => PhotoKitId.parse('ph: '), throwsA(isA<MalformedIdException>()));
    expect(() => LinkedItemId.parse('lk:r'), throwsA(isA<MalformedIdException>()));
  });

  test('accessors split the parts', () {
    expect(EntryId.parse('fe_abc').token, 'abc');
    expect(FolderId.parse('fd_xyz').token, 'xyz');
    final linked = LinkedItemId.of('root7', 'Shows/S01/e1.mkv');
    expect(linked.value, 'lk:root7/Shows/S01/e1.mkv');
    expect(linked.rootId, 'root7');
    expect(linked.relativePath, 'Shows/S01/e1.mkv');
    expect(PhotoKitId.of('ABC/L0/001').localIdentifier, 'ABC/L0/001');
    expect(MediaStoreId.of(42).value, 'ms:42');
    expect(MediaStoreId.of(42).mediaStoreId, 42);
    expect(() => MediaStoreId.of(-3), throwsA(isA<MalformedIdException>()));
    expect(() => LinkedItemId.of('root', '../x'), throwsA(isA<MalformedIdException>()));
  });

  test('ItemId narrows to the typed ids', () {
    final ItemId e = ItemId.parse('fe_a');
    expect(e.asEntry, isNotNull);
    expect(e.asFolder, isNull);
    expect(ItemId.parse('fd_a').asFolder, isNotNull);
    expect(ItemId.parse('lk:r/a').asLinked?.relativePath, 'a');
    expect(ItemId.parse('ph:a').asPhotoKit?.localIdentifier, 'a');
    expect(ItemId.parse('ms:5').asMediaStore?.mediaStoreId, 5);
    expect(ItemId.parse('fe_a').isInLibraryDb, isTrue);
    expect(ItemId.parse('fd_a').isInLibraryDb, isTrue);
    for (final raw in ['lk:r/a', 'ph:a', 'ms:1']) {
      expect(ItemId.parse(raw).isInLibraryDb, isFalse, reason: raw);
    }
  });

  test('opaque ids carry v1.1 MediaRef ids unchanged and never throw', () {
    for (final raw in ['/Users/me/movie.mp4', r'C:\Videos\a.mkv', 'https://x.test/a.m3u8', '', 'fe_', 'ms:-1']) {
      final id = ItemId.opaque(raw);
      expect(id.value, raw);
      expect(id.namespace, IdNamespace.legacy);
      expect(id.isNamespaced, isFalse);
      expect(id.isInLibraryDb, isFalse);
    }
    expect(ItemId.opaque('fe_abc').namespace, IdNamespace.entry);
  });

  test('ids compare and hash as their string', () {
    expect(ItemId.parse('fe_a'), ItemId.opaque('fe_a'));
    expect({ItemId.parse('fe_a'), EntryId.parse('fe_a')}, hasLength(1));
    expect(ItemId.parse('fe_a') == ItemId.parse('fe_b'), isFalse);
  });

  test('random ids are valid and distinct', () {
    final random = Random(7);
    final ids = {for (var i = 0; i < 1000; i++) EntryId.random(random)};
    expect(ids, hasLength(1000));
    for (final id in ids) {
      expect(EntryId.tryParse(id.value), isNotNull);
    }
    expect(FolderId.tryParse(FolderId.random().value), isNotNull);
    expect(EntryId.random().value, startsWith('fe_'));
  });

  test('MalformedIdException reports the source', () {
    try {
      ItemId.parse('lk:root');
      fail('expected a throw');
    } on MalformedIdException catch (e) {
      expect(e.source, 'lk:root');
      expect(e.message, contains('/'));
    }
  });
}
