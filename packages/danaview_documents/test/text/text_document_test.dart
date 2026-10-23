// OWNER: HOM-23
//
// BUILD_PLAN HOM-23: the text viewer's loading and row index (HOM plan §8.4): rows split on LF
// and CRLF, long lines split at character boundaries (UTF-8 sequences and UTF-16 surrogate pairs
// never cut), the 50 MB cap (exercised with a small cap) with the file size kept, the change of
// encoding, read-only loading and the missing-file error. Fixtures are generated in a temp dir.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:danaview_documents/danaview_documents.dart';
import 'package:flutter_test/flutter_test.dart';

import '../card/doc_harness.dart';

Uint8List _b(String s) => Uint8List.fromList(utf8.encode(s));

List<String> _rows(TextDocument d) => [for (var i = 0; i < d.rowCount; i++) d.row(i)];

void main() {
  test('rows split on LF and CRLF; a final line break adds no empty row', () {
    final d = TextDocument.fromBytes(_b('one\r\ntwo\nthree\n'));
    expect(_rows(d), ['one', 'two', 'three']);
    expect(TextDocument.fromBytes(_b('a\n\nb')).rowCount, 3);
    expect(_rows(TextDocument.fromBytes(Uint8List(0))), ['']);
  });

  test('the byte-order mark is skipped', () {
    final d = TextDocument.fromBytes(Uint8List.fromList([0xEF, 0xBB, 0xBF, ...utf8.encode('x\ny')]));
    expect(d.bomLength, 3);
    expect(_rows(d), ['x', 'y']);
  });

  test('long UTF-8 lines split at a character boundary and rejoin to the original', () {
    final line = '日本語' * 40; // 3 bytes per character
    final d = TextDocument.fromBytes(_b('$line\nend'), rowMaxBytes: 32);
    expect(d.rowCount, greaterThan(2));
    final rows = _rows(d);
    expect(rows.every((r) => !r.contains('�')), isTrue);
    expect(rows.sublist(0, rows.length - 1).join(), line);
    expect(rows.last, 'end');
    expect(d.maxRowBytes, lessThanOrEqualTo(33));
  });

  test('long UTF-16 lines never split a surrogate pair', () {
    final text = '😀a' * 50;
    final bytes = BytesBuilder()..add([0xFF, 0xFE]);
    for (final u in text.codeUnits) {
      bytes.add([u & 0xFF, u >> 8]);
    }
    for (final max in [8, 10, 12, 14]) {
      final d = TextDocument.fromBytes(bytes.toBytes(), rowMaxBytes: max);
      expect(d.encoding, TextEncodingKind.utf16le);
      final rows = _rows(d);
      expect(rows.join(), text, reason: 'max $max');
      for (final r in rows) {
        expect(r.runes.any((c) => c >= 0xD800 && c <= 0xDFFF), isFalse, reason: 'lone surrogate at max $max');
      }
    }
  });

  test('UTF-16 BE rows split on its own line breaks', () {
    final bytes = BytesBuilder()..add([0xFE, 0xFF]);
    for (final u in 'α\nβ\r\nγ'.codeUnits) {
      bytes.add([u >> 8, u & 0xFF]);
    }
    expect(_rows(TextDocument.fromBytes(bytes.toBytes())), ['α', 'β', 'γ']);
  });

  test('the cap reads the first bytes only and keeps the file size', () {
    final dir = docTempDir();
    final f = File('${dir.path}/big.log')..writeAsStringSync(List.generate(1000, (i) => 'line $i').join('\n'));
    final before = f.readAsBytesSync();
    final d = TextDocument.loadSync(f.path, capBytes: 100);
    expect(d.truncated, isTrue);
    expect(d.bytes.length, 100);
    expect(d.fileSize, before.length);
    expect(d.row(0), 'line 0');
    // Read-only: the file is unchanged.
    expect(f.readAsBytesSync(), before);
    final whole = TextDocument.loadSync(f.path);
    expect(whole.truncated, isFalse);
    expect(whole.rowCount, 1000);
  });

  test('a missing file throws TextLoadException(missing) without the path', () {
    final dir = docTempDir();
    expect(
      () => TextDocument.loadSync('${dir.path}/gone.txt'),
      throwsA(isA<TextLoadException>().having((e) => e.missing, 'missing', isTrue).having((e) => e.toString(), 'text', isNot(contains('gone')))),
    );
  });

  test('load runs on a background isolate', () async {
    final dir = docTempDir();
    final f = File('${dir.path}/a.txt')..writeAsBytesSync(latin1.encode('café\nñ'));
    final d = await TextDocument.load(f.path);
    expect(d.encoding, TextEncodingKind.latin1);
    expect(_rows(d), ['café', 'ñ']);
  });

  test('changing the encoding re-decodes the same bytes', () async {
    final d = TextDocument.fromBytes(_b('café'));
    expect(d.row(0), 'café');
    final asLatin = await d.withEncoding(TextEncodingKind.latin1);
    expect(asLatin.row(0), 'cafÃ©');
    expect(asLatin.detected, TextEncodingKind.utf8);
    expect(identical(await d.withEncoding(TextEncodingKind.utf8), d), isTrue);
  });
}
