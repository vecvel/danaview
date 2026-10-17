// OWNER: CORE-04
//
// quickHash must match danaview_data's MediaIdentityService.computeQuickHash byte for byte
// (fixtures in test/fixtures/quickhash/, produced once with that implementation).

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:test/test.dart';
import 'package:danaview_editor_core/model.dart';

int _byteAt(int i) => (i * 31 + (i >> 8) * 7 + 5) & 0xff;

/// What a caller reads from a file of [size] bytes: head and tail exactly like danaview_data.
({Uint8List head, Uint8List tail}) _chunks(Uint8List all) {
  final size = all.length;
  final head = Uint8List.sublistView(all, 0, size < quickHashChunkBytes ? size : quickHashChunkBytes);
  final tail = size > quickHashChunkBytes
      ? Uint8List.sublistView(all, size - quickHashChunkBytes, size)
      : Uint8List(0);
  return (head: head, tail: tail);
}

void main() {
  final doc = jsonDecode(File('test/fixtures/quickhash/quickhash_vectors.json').readAsStringSync()) as Map<String, Object?>;
  final cases = (doc['cases']! as List<Object?>).cast<Map<String, Object?>>();

  test('fixture covers 1 byte, 64 KiB, 64 KiB + 1, 100 KiB, 128 KiB, 3 MiB (+ empty)', () {
    expect(cases.map((c) => c['size']), [1, 65536, 65537, 102400, 131072, 3145728, 0]);
  });

  for (final c in cases) {
    test('matches danaview_data for ${c['name']} (${c['size']} bytes)', () {
      final size = c['size']! as int;
      final all = Uint8List.fromList([for (var i = 0; i < size; i++) _byteAt(i)]);
      final chunks = _chunks(all);
      expect(computeQuickHash(chunks.head, chunks.tail, size), c['quickHash']);
    });
  }

  group('algorithm (ARCH §6.8)', () {
    test('empty file hashes to the empty string', () {
      expect(computeQuickHash(Uint8List(0), Uint8List(0), 0), '');
    });

    test('files up to 64 KiB ignore the tail argument', () {
      final head = Uint8List.fromList([1, 2, 3]);
      final a = computeQuickHash(head, Uint8List(0), 3);
      final b = computeQuickHash(head, Uint8List.fromList([9, 9, 9, 9]), 3);
      expect(a, b);
      final full = Uint8List.fromList([for (var i = 0; i < 65536; i++) _byteAt(i)]);
      expect(computeQuickHash(full, Uint8List.fromList([7]), 65536), computeQuickHash(full, Uint8List(0), 65536));
    });

    test('is sha1(head + tail + ":size") spelled out', () {
      final all = Uint8List.fromList([for (var i = 0; i < 100 * 1024; i++) _byteAt(i)]);
      final chunks = _chunks(all);
      final expected = sha1.convert([...chunks.head, ...chunks.tail, ...utf8.encode(':${all.length}')]).toString();
      expect(computeQuickHash(chunks.head, chunks.tail, all.length), expected);
      expect(chunks.tail.length, 64 * 1024, reason: 'tail overlaps the head for files < 128 KiB');
    });

    test('size is part of the hash', () {
      final head = Uint8List.fromList([5, 5, 5]);
      expect(computeQuickHash(head, Uint8List(0), 3), isNot(computeQuickHash(head, Uint8List(0), 4)));
    });

    test('result is 40 lowercase hex characters', () {
      final h = computeQuickHash(Uint8List.fromList([1]), Uint8List(0), 1);
      expect(h, matches(RegExp(r'^[0-9a-f]{40}$')));
    });
  });
}
