import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:danaview_editor_core/formats.dart';

Uint8List fx(String name) => File('test/fixtures/luts/$name').readAsBytesSync();

LutFormatException parseError(String name) {
  try {
    CubeLut.parse(fx(name));
  } on LutFormatException catch (e) {
    return e;
  }
  fail('expected LutFormatException for $name');
}

void main() {
  group('float16', () {
    test('exhaustive: every non-NaN pattern round-trips', () {
      for (var p = 0; p < 0x10000; p++) {
        final v = float16Decode(p);
        if (v.isNaN) {
          expect((p & 0x7C00) == 0x7C00 && (p & 0x3FF) != 0, isTrue, reason: '$p');
          expect(float16Decode(float16Encode(v)).isNaN, isTrue);
        } else {
          expect(float16Encode(v), p, reason: 'pattern $p value $v');
        }
      }
    });

    test('known values', () {
      expect(float16Encode(0), 0);
      expect(float16Encode(-0.0), 0x8000);
      expect(float16Encode(1), 0x3C00);
      expect(float16Encode(-2), 0xC000);
      expect(float16Encode(65504), 0x7BFF);
      expect(float16Encode(65520), 0x7C00); // ties-to-even rounds up to infinity
      expect(float16Encode(1e9), 0x7C00);
      expect(float16Encode(double.negativeInfinity), 0xFC00);
      expect(float16Encode(5.960464477539063e-8), 1); // smallest subnormal
      expect(float16Encode(1e-9), 0);
      expect(float16Decode(0x3555), closeTo(1 / 3, 1e-3));
    });

    test('round to nearest even on ties', () {
      // 1 + 2^-11 is exactly between 1.0 (even mantissa) and 1 + 2^-10.
      expect(float16Encode(1 + math.pow(2, -11).toDouble()), 0x3C00);
      // 1 + 3*2^-11 is between 1+2^-10 (odd) and 1+2^-9 (even).
      expect(float16Encode(1 + 3 * math.pow(2, -11).toDouble()), 0x3C02);
      // Half of the smallest subnormal ties to zero (even); 1.5x ties to 2.
      expect(float16Encode(math.pow(2, -25).toDouble()), 0);
      expect(float16Encode(1.5 * math.pow(2, -24).toDouble()), 2);
    });

    test('rounding error is within half an ulp for random values', () {
      final r = math.Random(7);
      for (var i = 0; i < 20000; i++) {
        final v = (r.nextDouble() * 2 - 1) * math.pow(10, r.nextInt(8) - 5);
        final back = float16Decode(float16Encode(v));
        final a = v.abs();
        if (a >= 6.1035e-5 && a < 65504) {
          expect((back - v).abs(), lessThanOrEqualTo(a * math.pow(2, -11) * 1.0001));
        } else if (a < 6.1035e-5) {
          expect((back - v).abs(), lessThanOrEqualTo(math.pow(2, -25) * 1.0001));
        }
      }
    });
  });

  group('cube parser', () {
    test('Resolve identity with comments and blank lines', () {
      final lut = CubeLut.parse(fx('resolve_identity_5.cube'));
      expect(lut.size, 5);
      expect(lut.title, 'Identity 5');
      expect(lut.rgb.length, 5 * 5 * 5 * 3);
      expect(lut.notice, isNull);
      // red fastest: second entry is r=0.25.
      expect(lut.rgb[3], closeTo(0.25, 1e-6));
      expect(lut.rgb[4], 0);
      expect(lut.rgb[5 * 3 + 1], closeTo(0.25, 1e-6)); // next green
      expect(lut.rgb[(25) * 3 + 2], closeTo(0.25, 1e-6)); // next blue
    });

    test('Adobe style with CRLF and explicit domain', () {
      final lut = CubeLut.parse(fx('adobe_identity_4.cube'));
      expect(lut.size, 4);
      expect(lut.domainMin, [0, 0, 0]);
      expect(lut.domainMax, [1, 1, 1]);
      expect(lut.rgb.last, 1);
    });

    test('BOM is tolerated', () {
      final bytes = Uint8List.fromList([0xEF, 0xBB, 0xBF, ...fx('resolve_range_2.cube')]);
      expect(CubeLut.parse(bytes).size, 2);
    });

    test('1D LUT converts to 33^3 with a notice', () {
      final lut = CubeLut.parse(fx('curve_1d_8.cube'));
      expect(lut.size, 33);
      expect(lut.rgb.length, 33 * 33 * 33 * 3);
      expect(lut.notice, contains('33×33×33'));
      // r index 16 of 32 -> x = 3.5/7 -> halfway between entries 3 and 4 of the red curve.
      final red = ((3 / 7) * (3 / 7) + (4 / 7) * (4 / 7)) / 2;
      // Entry at r=16,g=0,b=0 sits at index 16*3.
      expect(lut.rgb[16 * 3], closeTo(red, 1e-5));
      // Blue curve is the identity.
      expect(lut.rgb[(33 * 33 * 32) * 3 + 2], closeTo(1, 1e-6));
      expect(lut.rgb[(33 * 33 * 8) * 3 + 2], closeTo(0.25, 1e-6));
    });

    test('domain keywords are recorded; entries are not resampled', () {
      final lut = CubeLut.parse(fx('domain_hdr_2.cube'));
      expect(lut.domainMin, [-0.5, -0.5, -0.5]);
      expect(lut.domainMax, [1.5, 2.5, 3.5]);
      expect(lut.rgb.toList(), [0, 0, 0, 1, 0, 0, 0, 1, 0, 1, 1, 0, 0, 0, 1, 1, 0, 1, 0, 1, 1, 1, 1, 1]);
      final r = CubeLut.parse(fx('resolve_range_2.cube'));
      expect(r.domainMin, [-1, -1, -1]);
      expect(r.domainMax, [2, 2, 2]);
    });

    test('errors carry line numbers', () {
      expect(parseError('bad_row.cube').message, 'Line 7: expected 3 numbers');
      expect(parseError('bad_row.cube').line, 7);
      expect(parseError('bad_number.cube').message, "Line 3: 'x' is not a number");
      expect(parseError('truncated.cube').message, 'Line 4: expected 8 table entries, found 3');
      expect(parseError('extra_rows.cube').message, 'Line 10: too many table entries (expected 8)');
      expect(parseError('no_size.cube').message, 'Line 2: data found before LUT_3D_SIZE or LUT_1D_SIZE');
      expect(parseError('missing_size.cube').message, contains('Missing LUT_3D_SIZE'));
      expect(parseError('both_sizes.cube').message, startsWith('Line 2:'));
      expect(parseError('bad_domain.cube').message, contains('DOMAIN_MAX'));
    });

    test('oversize LUTs use the product message', () {
      expect(parseError('too_large.cube').message, 'Line 1: LUTs up to 65×65×65 are supported.');
      expect(
        () => CubeLut.parse(Uint8List(maxCubeBytes + 1)),
        throwsA(isA<LutFormatException>().having((e) => e.message, 'message', 'LUTs up to 65×65×65 are supported.')),
      );
    });

    test('too many numbers on a row and malformed keyword values', () {
      expect(() => CubeLut.parseText('LUT_3D_SIZE 2\n1 2 3 4\n'),
          throwsA(isA<LutFormatException>().having((e) => e.message, 'm', 'Line 2: expected 3 numbers')));
      expect(() => CubeLut.parseText('LUT_3D_SIZE two\n'),
          throwsA(isA<LutFormatException>().having((e) => e.line, 'line', 1)));
      expect(() => CubeLut.parseText('LUT_3D_SIZE 1\n'), throwsA(isA<LutFormatException>()));
      expect(() => CubeLut.parseText('LUT_3D_SIZE 2\nhello world\n'), throwsA(isA<LutFormatException>()));
    });

    test('65^3 parse is fast and correct', () {
      const n = 65;
      final sb = StringBuffer('LUT_3D_SIZE $n\n');
      for (var b = 0; b < n; b++) {
        for (var g = 0; g < n; g++) {
          for (var r = 0; r < n; r++) {
            sb.writeln('${(r / 64).toStringAsFixed(6)} ${(g / 64).toStringAsFixed(6)} ${(b / 64).toStringAsFixed(6)}');
          }
        }
      }
      final bytes = Uint8List.fromList(sb.toString().codeUnits);
      final sw = Stopwatch()..start();
      final lut = CubeLut.parse(bytes);
      sw.stop();
      expect(lut.size, 65);
      expect(lut.rgb.last, 1);
      expect(sw.elapsedMilliseconds, lessThanOrEqualTo(400), reason: '${sw.elapsedMilliseconds} ms');
    });
  });

  group('vlut', () {
    test('identity round-trips within 1/1024', () {
      for (final n in [2, 17, 33]) {
        final rgb = Float32List(n * n * n * 3);
        var o = 0;
        for (var b = 0; b < n; b++) {
          for (var g = 0; g < n; g++) {
            for (var r = 0; r < n; r++) {
              rgb[o++] = r / (n - 1);
              rgb[o++] = g / (n - 1);
              rgb[o++] = b / (n - 1);
            }
          }
        }
        final t = readVlut(writeVlut(n, rgb));
        expect(t.size, n);
        final back = t.toFloats();
        for (var i = 0; i < rgb.length; i++) {
          expect((back[i] - rgb[i]).abs(), lessThanOrEqualTo(1 / 1024));
        }
      }
    });

    test('header layout is little endian', () {
      final bytes = writeVlut(2, Float32List(24));
      expect(bytes.sublist(0, 8), [0x56, 0x4C, 0x55, 0x54, 1, 0, 2, 0]);
      expect(bytes.length, 8 + 24 * 2);
    });

    test('golden bytes are stable', () {
      final bytes = writeVlutFromCube(CubeLut.parse(fx('golden_3.cube')));
      final golden = fx('golden_3.vlut');
      expect(bytes, golden);
    });

    test('values clamp to the half range; negatives and HDR survive', () {
      final rgb = List<double>.filled(24, 0)
        ..[0] = 1e9
        ..[1] = -1e9
        ..[2] = 2.5
        ..[3] = -0.25;
      final f = readVlut(writeVlut(2, rgb)).toFloats();
      expect(f[0], 65504);
      expect(f[1], -65504);
      expect(f[2], 2.5);
      expect(f[3], -0.25);
    });

    test('reader rejects malformed files', () {
      final ok = writeVlut(2, Float32List(24));
      expect(() => readVlut(Uint8List(4)), throwsA(isA<LutFormatException>()));
      expect(() => readVlut(Uint8List.fromList([...ok]..[0] = 0x58)), throwsA(isA<LutFormatException>()));
      expect(() => readVlut(Uint8List.fromList([...ok]..[4] = 2)), throwsA(isA<LutFormatException>()));
      expect(() => readVlut(Uint8List.fromList([...ok]..[6] = 1)), throwsA(isA<LutFormatException>()));
      expect(() => readVlut(Uint8List.fromList([...ok]..[6] = 66)), throwsA(isA<LutFormatException>()));
      expect(() => readVlut(ok.sublist(0, ok.length - 1)), throwsA(isA<LutFormatException>()));
      expect(() => readVlut(Uint8List.fromList([...ok, 0])), throwsA(isA<LutFormatException>()));
      expect(() => writeVlut(1, Float32List(3)), throwsArgumentError);
      expect(() => writeVlut(2, Float32List(3)), throwsArgumentError);
    });

    test('65^3 write+read is within budget', () {
      final rgb = Float32List(65 * 65 * 65 * 3)..fillRange(0, 65 * 65 * 65 * 3, 0.5);
      final bytes = writeVlut(65, rgb);
      expect(bytes.length, 8 + 65 * 65 * 65 * 6);
      expect(readVlut(bytes).halfs.first, 0x3800);
    });
  });
}
