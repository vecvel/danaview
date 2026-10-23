// OWNER: HOM-23
//
// BUILD_PLAN HOM-23 "encoding fixtures decode": UTF-8 with and without a byte-order mark, UTF-16
// LE and BE by byte-order mark, the Latin-1 fallback for bytes that aren't UTF-8, a UTF-8
// sequence cut by the 50 MB cap, and malformed input that never throws. Fixtures are generated
// here (no downloads).

import 'dart:convert';
import 'dart:typed_data';

import 'package:danaview_documents/danaview_documents.dart';
import 'package:flutter_test/flutter_test.dart';

const String _sample = 'Grüße, café — naïve 日本語 😀\nline two';

Uint8List _utf16(String s, {required bool le, bool bom = true}) {
  final out = BytesBuilder();
  if (bom) out.add(le ? [0xFF, 0xFE] : [0xFE, 0xFF]);
  for (final u in s.codeUnits) {
    out.add(le ? [u & 0xFF, u >> 8] : [u >> 8, u & 0xFF]);
  }
  return out.toBytes();
}

String _decodeAll(Uint8List bytes) {
  final g = detectEncoding(bytes);
  return decodeRange(bytes, g.bomLength, bytes.length, g.kind);
}

void main() {
  group('detectEncoding', () {
    test('plain UTF-8 without a byte-order mark', () {
      final bytes = Uint8List.fromList(utf8.encode(_sample));
      expect(detectEncoding(bytes), const EncodingGuess(TextEncodingKind.utf8, 0));
      expect(_decodeAll(bytes), _sample);
    });

    test('UTF-8 with a byte-order mark', () {
      final bytes = Uint8List.fromList([0xEF, 0xBB, 0xBF, ...utf8.encode(_sample)]);
      expect(detectEncoding(bytes), const EncodingGuess(TextEncodingKind.utf8, 3));
      expect(_decodeAll(bytes), _sample);
    });

    test('UTF-16 LE and BE by byte-order mark, surrogate pairs kept', () {
      final le = _utf16(_sample, le: true);
      final be = _utf16(_sample, le: false);
      expect(detectEncoding(le), const EncodingGuess(TextEncodingKind.utf16le, 2));
      expect(detectEncoding(be), const EncodingGuess(TextEncodingKind.utf16be, 2));
      expect(_decodeAll(le), _sample);
      expect(_decodeAll(be), _sample);
    });

    test('bytes that are not UTF-8 fall back to Latin-1', () {
      final bytes = Uint8List.fromList(latin1.encode('Grüße, café, señor, ½'));
      expect(detectEncoding(bytes).kind, TextEncodingKind.latin1);
      expect(_decodeAll(bytes), 'Grüße, café, señor, ½');
    });

    test('ASCII is UTF-8', () {
      expect(detectEncoding(Uint8List.fromList(ascii.encode('plain text'))).kind, TextEncodingKind.utf8);
      expect(detectEncoding(Uint8List(0)).kind, TextEncodingKind.utf8);
    });

    test('a UTF-8 sequence cut at the cap still counts as UTF-8 when truncated', () {
      final full = utf8.encode('abc 日');
      final cut = Uint8List.fromList(full.sublist(0, full.length - 1));
      expect(detectEncoding(cut).kind, TextEncodingKind.latin1);
      expect(detectEncoding(cut, truncated: true).kind, TextEncodingKind.utf8);
    });
  });

  group('isValidUtf8', () {
    test('rejects overlongs, surrogates, stray continuation bytes and code points past U+10FFFF', () {
      for (final bad in [
        [0xC0, 0xAF], // overlong '/'
        [0xE0, 0x80, 0xAF], // overlong
        [0xED, 0xA0, 0x80], // U+D800
        [0x80], // stray continuation
        [0xF4, 0x90, 0x80, 0x80], // U+110000
        [0xF5, 0x80, 0x80, 0x80],
        [0xE2, 0x28, 0xA1], // bad continuation
      ]) {
        expect(isValidUtf8(Uint8List.fromList(bad)), isFalse, reason: '$bad');
      }
    });

    test('accepts every plane', () {
      expect(isValidUtf8(Uint8List.fromList(utf8.encode('a é € 😀 \u{10FFFF}'))), isTrue);
    });
  });

  group('decodeRange', () {
    test('malformed UTF-8 decodes with replacement characters', () {
      final s = decodeRange(Uint8List.fromList([0x61, 0xFF, 0x62]), 0, 3, TextEncodingKind.utf8);
      expect(s, 'a�b');
    });

    test('an odd trailing UTF-16 byte is dropped', () {
      final bytes = Uint8List.fromList([0x61, 0x00, 0x62]);
      expect(decodeRange(bytes, 0, 3, TextEncodingKind.utf16le), 'a');
    });

    test('every encoding round-trips its own label and code', () {
      for (final k in TextEncodingKind.values) {
        expect(TextEncodingKind.tryDecode(k.code), k);
      }
      expect(TextEncodingKind.tryDecode('koi8-r'), isNull);
    });
  });
}
