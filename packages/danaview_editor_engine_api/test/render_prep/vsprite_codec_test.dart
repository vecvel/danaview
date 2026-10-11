// OWNER: API-04
//
// `.vsprite` v1 codec (ARCH §10.3): round trips with and without a glyph map, header layout,
// malformed input, the stream-boundary inflater against dart:io, and the shared fixtures
// (test_fixtures/sprites, decoded by IOS-09 / AND-09) still decoding to their manifest.

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_editor_engine_api/danaview_editor_engine_api.dart';

/// A deterministic premultiplied pattern: alpha ramps, colour ≤ alpha.
Uint8List pattern(int w, int h, int seed) {
  final out = Uint8List(w * h * 4);
  final r = Random(seed);
  for (var i = 0; i < w * h; i++) {
    final a = (i % 7 == 0) ? 0 : r.nextInt(256);
    out[i * 4] = a == 0 ? 0 : r.nextInt(a + 1);
    out[i * 4 + 1] = a == 0 ? 0 : r.nextInt(a + 1);
    out[i * 4 + 2] = a == 0 ? 0 : r.nextInt(a + 1);
    out[i * 4 + 3] = a;
  }
  return out;
}

Uint16List glyphPattern(int w, int h) =>
    Uint16List.fromList([for (var i = 0; i < w * h; i++) (i % 7 == 0) ? 0xFFFF : (i % w) ~/ 4]);

void main() {
  test('round trip without a glyph map; header fields are little-endian at fixed offsets', () async {
    final img = VspriteImage(width: 13, height: 5, scale: 1.75, rgba: pattern(13, 5, 1));
    final bytes = await VspriteCodec.encode(img);
    expect(ascii.decode(bytes.sublist(0, 4)), 'VSPR');
    final d = ByteData.sublistView(bytes);
    expect(d.getUint16(4, Endian.little), 1);
    expect(d.getUint16(6, Endian.little), 0);
    expect(d.getUint32(8, Endian.little), 13);
    expect(d.getUint32(12, Endian.little), 5);
    expect(d.getFloat32(16, Endian.little), 1.75);
    expect(bytes[20], 0x78, reason: 'a zlib stream starts right after the header');
    final back = await VspriteCodec.decode(bytes);
    expect((back.width, back.height, back.scale, back.hasReveal), (13, 5, 1.75, false));
    expect(back.rgba, img.rgba);
  });

  test('round trip with a glyph map (two concatenated zlib streams)', () {
    for (final (w, h) in [(1, 1), (17, 9), (300, 41)]) {
      final img = VspriteImage(width: w, height: h, scale: 0.5, rgba: pattern(w, h, w), glyphs: glyphPattern(w, h));
      final bytes = VspriteCodec.encodeSync(img);
      expect(ByteData.sublistView(bytes).getUint16(6, Endian.little), VspriteCodec.flagReveal);
      final back = VspriteCodec.decodeSync(bytes);
      expect(back.hasReveal, isTrue);
      expect(back.rgba, img.rgba);
      expect(back.glyphs, img.glyphs);
      final h0 = VspriteCodec.readHeader(bytes);
      expect((h0.width, h0.height, h0.scale, h0.hasReveal), (w, h, 0.5, true));
    }
  });

  test('scale is stored as f32', () {
    final img = VspriteImage(width: 2, height: 2, scale: 1 / 3, rgba: Uint8List(16));
    final back = VspriteCodec.decodeSync(VspriteCodec.encodeSync(img));
    expect(back.scale, closeTo(1 / 3, 1e-7));
    expect(back.scale, (Float32List(1)..[0] = 1 / 3)[0]);
  });

  test('malformed files are FormatExceptions', () {
    final good = VspriteCodec.encodeSync(VspriteImage(width: 4, height: 4, scale: 1, rgba: pattern(4, 4, 3), glyphs: glyphPattern(4, 4)));
    Uint8List mutate(void Function(Uint8List b) f) => Uint8List.fromList(good)..apply(f);
    expect(() => VspriteCodec.decodeSync(Uint8List(10)), throwsFormatException);
    expect(() => VspriteCodec.decodeSync(mutate((b) => b[0] = 0x41)), throwsFormatException);
    expect(() => VspriteCodec.decodeSync(mutate((b) => b[4] = 2)), throwsFormatException);
    expect(() => VspriteCodec.decodeSync(mutate((b) => b[6] = 0x82)), throwsFormatException);
    expect(() => VspriteCodec.decodeSync(mutate((b) => b[8] = 0)), throwsFormatException, reason: 'zero width');
    expect(() => VspriteCodec.decodeSync(mutate((b) => b[9] = 0x7F)), throwsFormatException, reason: 'width > 16384');
    expect(() => VspriteCodec.decodeSync(good.sublist(0, good.length - 3)), throwsFormatException, reason: 'truncated');
    expect(() => VspriteCodec.decodeSync(good.sublist(0, 30)), throwsFormatException);
    // Corrupt the RGBA stream's Adler-32 (end of the first stream).
    final noReveal = VspriteCodec.encodeSync(VspriteImage(width: 4, height: 4, scale: 1, rgba: pattern(4, 4, 3)));
    final bad = Uint8List.fromList(noReveal)..[noReveal.length - 1] ^= 0xFF;
    expect(() => VspriteCodec.decodeSync(bad), throwsFormatException);
    expect(() => VspriteImage(width: 2, height: 2, scale: 1, rgba: Uint8List(15)), throwsArgumentError);
    expect(() => VspriteImage(width: 2, height: 2, scale: 0, rgba: Uint8List(16)), throwsArgumentError);
    expect(() => VspriteImage(width: 2, height: 2, scale: 1, rgba: Uint8List(16), glyphs: Uint16List(3)), throwsArgumentError);
  });

  group('deflateZlib', () {
    test('standard zlib: dart:io inflates it; round trips through the strict inflater', () {
      final r = Random(7);
      final inputs = <Uint8List>[
        Uint8List(0),
        Uint8List.fromList([1, 2, 3]),
        Uint8List.fromList(List.generate(100000, (i) => r.nextInt(256))),
        Uint8List(300000), // transparent
        pattern(321, 77, 9),
        Uint8List.fromList(List.generate(70000, (i) => (i ~/ 1000) % 3 == 0 ? 0 : (i * 7) % 256)),
      ];
      for (final input in inputs) {
        for (final (stride, px) in [(0, 0), (64, 4), (1284, 4), (40000, 2)]) {
          final z = deflateZlib(input, stride: stride, pixelBytes: px);
          expect(ZLibDecoder().convert(z), input, reason: '${input.length} bytes, stride $stride');
          final (out, end) = inflateZlibStream(z, 0, input.length);
          expect(out, input);
          expect(end, z.length);
        }
      }
    });

    test('compresses sprite-like RGBA (transparent margins, solid box, glyph rows)', () {
      const w = 600, h = 120;
      final rgba = Uint8List(w * h * 4);
      for (var y = 20; y < 100; y++) {
        for (var x = 20; x < 580; x++) {
          final i = (y * w + x) * 4;
          final glyph = (y > 40 && y < 80) && ((x ~/ 9) % 3 == 0);
          rgba[i] = glyph ? 255 : 16;
          rgba[i + 1] = glyph ? 255 : 24;
          rgba[i + 2] = glyph ? 255 : 40;
          rgba[i + 3] = glyph ? 255 : 200;
        }
      }
      final z = deflateZlib(rgba, stride: w * 4);
      expect(z.length, lessThan(rgba.length ~/ 20), reason: '${z.length} of ${rgba.length}');
      expect(ZLibDecoder().convert(z), rgba);
    });
  });

  group('inflateZlibStream', () {
    test('matches dart:io on stored, fixed and dynamic blocks and reports the stream end', () {
      final r = Random(42);
      final inputs = <Uint8List>[
        Uint8List(0),
        Uint8List.fromList(List.generate(70000, (i) => r.nextInt(256))), // incompressible: stored
        Uint8List.fromList(List.generate(50, (i) => i % 5)), // short: fixed Huffman
        Uint8List.fromList(List.generate(200000, (i) => (i ~/ 37) % 11 * 20)), // long runs: dynamic
      ];
      for (final level in [0, 1, 6, 9]) {
        for (final input in inputs) {
          final z = Uint8List.fromList(ZLibEncoder(level: level).convert(input));
          final tail = [1, 2, 3, 4, 5];
          final data = Uint8List.fromList([9, 9, ...z, ...tail]);
          final (out, end) = inflateZlibStream(data, 2, input.length);
          expect(out, input);
          expect(end, 2 + z.length, reason: 'level $level, ${input.length} bytes');
        }
      }
    });

    test('rejects wrong lengths, bad checksums and bad headers', () {
      final input = Uint8List.fromList(List.generate(1000, (i) => i % 13));
      final z = Uint8List.fromList(ZLibEncoder().convert(input));
      expect(() => inflateZlibStream(z, 0, 999), throwsFormatException);
      expect(() => inflateZlibStream(z, 0, 1001), throwsFormatException);
      expect(() => inflateZlibStream(Uint8List.fromList(z)..[z.length - 2] ^= 1, 0, 1000), throwsFormatException);
      expect(() => inflateZlibStream(Uint8List.fromList(z)..[0] = 0x79, 0, 1000), throwsFormatException);
      expect(() => inflateZlibStream(z.sublist(0, z.length ~/ 2), 0, 1000), throwsFormatException);
      expect(adler32(Uint8List.fromList(ascii.encode('Wikipedia'))), 0x11E60398);
    });
  });

  test('shared fixtures (test_fixtures/sprites) decode to their manifest', () {
    final dir = Directory('test_fixtures/sprites');
    final manifest = jsonDecode(File('${dir.path}/sprites.json').readAsStringSync()) as Map<String, Object?>;
    expect(manifest['format'], 'vsprite');
    expect(manifest['version'], 1);
    final cases = (manifest['sprites']! as List).cast<Map<String, Object?>>();
    expect(cases.length, greaterThanOrEqualTo(4));
    expect(cases.where((c) => c['reveal'] == true), isNotEmpty);
    for (final c in cases) {
      final bytes = File('${dir.path}/${c['file']}').readAsBytesSync();
      final img = VspriteCodec.decodeSync(bytes);
      expect(img.width, c['width'], reason: '${c['file']}');
      expect(img.height, c['height']);
      expect(img.scale, (c['scale']! as num).toDouble());
      expect(img.hasReveal, c['reveal']);
      expect(adler32(img.rgba), c['rgbaAdler32'], reason: '${c['file']} rgba');
      final g = img.glyphs;
      if (g != null) {
        final le = ByteData(g.length * 2);
        for (var i = 0; i < g.length; i++) {
          le.setUint16(i * 2, g[i], Endian.little);
        }
        expect(adler32(le.buffer.asUint8List()), c['glyphsAdler32'], reason: '${c['file']} glyphs');
      }
      for (final raw in (c['samples']! as List).cast<Map<String, Object?>>()) {
        final x = raw['x']! as int;
        final y = raw['y']! as int;
        final i = (y * img.width + x) * 4;
        expect(img.rgba.sublist(i, i + 4), raw['rgba'], reason: '${c['file']} ($x, $y)');
        if (g != null) expect(g[y * img.width + x], raw['glyph']);
      }
    }
  });
}

extension on Uint8List {
  void apply(void Function(Uint8List b) f) => f(this);
}
