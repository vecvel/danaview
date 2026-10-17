// OWNER: ENG-05
//
// Unit tests of the Dart frame barcode reader on synthetic frames, and the fixture-frame tests
// (all 240 frames of frame_counter_1080p30 and the other counter fixtures through ffmpeg).

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_editor_engine/testing.dart';

import '../fixtures/support/media_tools.dart';

Uint8List _frame(int w, int h, {int r = 70, int g = 40, int b = 90}) {
  final px = Uint8List(w * h * 4);
  for (var i = 0; i < px.length; i += 4) {
    px[i] = r;
    px[i + 1] = g;
    px[i + 2] = b;
    px[i + 3] = 255;
  }
  return px;
}

String _bits(int index) => FrameBarcode.cellsFor(index).map((v) => v ? '1' : '0').join();

void main() {
  group('layout', () {
    test('golden vectors match tool/make_fixtures.swift, FrameBarcode.swift and FrameBarcode.kt',
        () {
      expect(_bits(0), '1000000000000000000000000010');
      expect(_bits(1), '1000000000000000010000011110');
      expect(_bits(160), '1000000000101000000110100110');
      expect(_bits(239), '1000000000111011111000001110');
      expect(_bits(0x1234), '1000010010001101001111000110');
      expect(_bits(0xFFFF), '1011111111111111110010010010');
      expect(FrameBarcode.crc8(160), 105);
      expect(FrameBarcode.crc8(0x1234), 241);
    });

    test('index range is enforced', () {
      expect(() => FrameBarcode.cellsFor(-1), throwsRangeError);
      expect(() => FrameBarcode.cellsFor(0x10000), throwsRangeError);
    });

    test('band height is 10 percent with an 8 px floor', () {
      expect(FrameBarcode.bandHeight(1080), 108);
      expect(FrameBarcode.bandHeight(720), 72);
      expect(FrameBarcode.bandHeight(40), 8);
      expect(FrameBarcode.bandHeight(5), 5);
    });
  });

  group('synthetic frames', () {
    test('every index 0..65535 round trips at 280x160', () {
      const w = 280, h = 160;
      final px = _frame(w, h);
      for (var i = 0; i <= FrameBarcode.maxIndex; i++) {
        FrameBarcode.paint(px, width: w, height: h, index: i);
        final got = FrameBarcode.decode(px, width: w, height: h);
        if (got != i) fail('index $i decoded as $got');
      }
    });

    test('resolution independent: 280 to 3840 wide', () {
      for (final (w, h) in <(int, int)>[
        (280, 158),
        (360, 640),
        (1280, 720),
        (1920, 1080),
        (3840, 2160)
      ]) {
        final px = _frame(w, h);
        for (final i in <int>[0, 1, 159, 160, 239, 479, 4660, 65535]) {
          FrameBarcode.paint(px, width: w, height: h, index: i);
          expect(FrameBarcode.decode(px, width: w, height: h), i, reason: '${w}x$h index $i');
        }
      }
    });

    test('tolerates compression-like noise and reduced contrast', () {
      const w = 640, h = 360;
      final rnd = math.Random(7);
      final px = _frame(w, h);
      for (var n = 0; n < 200; n++) {
        final idx = rnd.nextInt(65536);
        FrameBarcode.paint(px, width: w, height: h, index: idx, white: 200, black: 45);
        for (var p = 0; p < px.length; p += 4) {
          final noise = rnd.nextInt(41) - 20;
          for (var c = 0; c < 3; c++) {
            px[p + c] = (px[p + c] + noise).clamp(0, 255);
          }
        }
        expect(FrameBarcode.decode(px, width: w, height: h), idx);
      }
    });

    test('BGRA order and row stride padding', () {
      const w = 320, h = 180, stride = w * 4 + 64;
      final px = Uint8List(stride * h);
      for (var i = 0; i < px.length; i++) {
        px[i] = 90;
      }
      FrameBarcode.paint(px, width: w, height: h, index: 777, bytesPerRow: stride);
      expect(FrameBarcode.decode(px, width: w, height: h, bytesPerRow: stride), 777);
      expect(
        FrameBarcode.decode(px,
            width: w, height: h, bytesPerRow: stride, order: FramePixelOrder.bgra),
        777,
      );
    });

    test('region: barcode inside a letterboxed capture', () {
      const w = 600, h = 600;
      final px = _frame(w, h, r: 0, g: 0, b: 0);
      const region = FrameBarcodeRegion(0, 210, 600, 180);
      FrameBarcode.paint(px, width: w, height: h, index: 4242, region: region);
      expect(FrameBarcode.decode(px, width: w, height: h), isNull);
      expect(FrameBarcode.decode(px, width: w, height: h, region: region), 4242);
      expect(
          () => FrameBarcode.decode(px,
              width: w, height: h, region: const FrameBarcodeRegion(0, 500, 600, 180)),
          throwsArgumentError);
    });

    test('flat, black and white frames are noSignal', () {
      const w = 320, h = 180;
      for (final v in <int>[0, 128, 255]) {
        final px = _frame(w, h, r: v, g: v, b: v);
        expect(FrameBarcode.read(px, width: w, height: h).status, FrameBarcodeStatus.noSignal);
      }
    });

    test('a 50 percent dissolve of two different indices is blended, never a wrong index', () {
      const w = 640, h = 360;
      final a = _frame(w, h);
      final b = _frame(w, h);
      final mix = _frame(w, h);
      var blended = 0;
      for (var k = 0; k < 400; k++) {
        final ia = k, ib = k + 1 + (k % 7);
        FrameBarcode.paint(a, width: w, height: h, index: ia);
        FrameBarcode.paint(b, width: w, height: h, index: ib);
        for (var p = 0; p < mix.length; p++) {
          mix[p] = ((a[p] + b[p]) / 2).round();
        }
        final r = FrameBarcode.read(mix, width: w, height: h);
        expect(r.isReadable, isFalse, reason: 'dissolve of $ia and $ib decoded as ${r.index}');
        if (r.status == FrameBarcodeStatus.blended) blended++;
      }
      expect(blended, 400);
    });

    test('a dissolve at 10 percent reads the dominant frame; 40 to 60 percent never decodes', () {
      const w = 640, h = 360;
      final a = _frame(w, h)..fillRange(0, 0, 0);
      final b = _frame(w, h);
      final mix = _frame(w, h);
      FrameBarcode.paint(a, width: w, height: h, index: 100);
      FrameBarcode.paint(b, width: w, height: h, index: 101);
      for (final alpha in <double>[0.0, 0.1]) {
        for (var p = 0; p < mix.length; p++) {
          mix[p] = (a[p] * (1 - alpha) + b[p] * alpha).round();
        }
        expect(FrameBarcode.decode(mix, width: w, height: h), 100, reason: 'alpha $alpha');
      }
      for (final alpha in <double>[0.4, 0.5, 0.6]) {
        for (var p = 0; p < mix.length; p++) {
          mix[p] = (a[p] * (1 - alpha) + b[p] * alpha).round();
        }
        expect(FrameBarcode.decode(mix, width: w, height: h), isNull, reason: 'alpha $alpha');
      }
    });

    test('inverted, mirrored and cropped bands are rejected by the guards', () {
      const w = 640, h = 360;
      final px = _frame(w, h);
      FrameBarcode.paint(px, width: w, height: h, index: 321);
      final inv = Uint8List.fromList(px);
      for (var y = 0; y < 36; y++) {
        for (var x = 0; x < w; x++) {
          final p = (y * w + x) * 4;
          for (var c = 0; c < 3; c++) {
            inv[p + c] = 255 - inv[p + c];
          }
        }
      }
      expect(FrameBarcode.read(inv, width: w, height: h).status, FrameBarcodeStatus.badGuard);
      final mirror = Uint8List.fromList(px);
      for (var y = 0; y < 36; y++) {
        for (var x = 0; x < w; x++) {
          final s = (y * w + x) * 4;
          final d = (y * w + (w - 1 - x)) * 4;
          mirror.setRange(d, d + 4, px, s);
        }
      }
      expect(FrameBarcode.read(mirror, width: w, height: h).isReadable, isFalse);
      // Cropped to the right 90 percent: cells shift, guards no longer line up.
      final cropped = Uint8List(576 * h * 4);
      for (var y = 0; y < h; y++) {
        cropped.setRange(y * 576 * 4, (y + 1) * 576 * 4, px, (y * w + 64) * 4);
      }
      expect(FrameBarcode.read(cropped, width: 576, height: h).isReadable, isFalse);
    });

    test('a corrupted data cell fails the checksum', () {
      const w = 640, h = 360;
      final px = _frame(w, h);
      FrameBarcode.paint(px, width: w, height: h, index: 1000);
      // Flip data cell 9 (index bit 7).
      final x0 = 9 * w ~/ 28, x1 = 10 * w ~/ 28;
      for (var y = 0; y < 36; y++) {
        for (var x = x0; x < x1; x++) {
          final p = (y * w + x) * 4;
          final v = 255 - px[p];
          px[p] = v;
          px[p + 1] = v;
          px[p + 2] = v;
        }
      }
      expect(FrameBarcode.read(px, width: w, height: h).status, FrameBarcodeStatus.badChecksum);
    });

    test('rejects a buffer that is too small', () {
      expect(
          () => FrameBarcode.decode(Uint8List(10), width: 320, height: 180), throwsArgumentError);
    });
  });

  group('fixture frames through ffmpeg', () {
    final skip = skipWithoutFfmpeg;

    Future<List<int?>> readAll(String name, int w, int h, {double? seconds}) async {
      final out = <int?>[];
      final n = await forEachRgbaFrame(
        fixtureFile(name).path,
        width: w,
        height: h,
        seconds: seconds,
        onFrame: (i, rgba) => out.add(FrameBarcode.decode(rgba, width: w, height: h)),
      );
      expect(n, out.length);
      return out;
    }

    test('frame_counter_1080p30.mp4: all 240 frames decode to their frame number', () async {
      final got = await readAll('frame_counter_1080p30.mp4', 1920, 1080);
      expect(got.length, 240);
      expect(got, List<int>.generate(240, (i) => i));
    }, skip: skip, timeout: const Timeout(Duration(minutes: 3)));

    for (final (name, frames) in <(String, int)>[
      ('frame_counter_720p24.mp4', 192),
      ('frame_counter_720p25.mp4', 200),
      ('frame_counter_720p48.mp4', 384),
      ('frame_counter_720p60.mp4', 480),
      ('tone_under_video.mp4', 240),
      ('clap_flash_av.mp4', 180),
    ]) {
      test('$name: $frames frames, barcode == frame number', () async {
        final got = await readAll(name, 1280, 720);
        expect(got, List<int>.generate(frames, (i) => i));
      }, skip: skip, timeout: const Timeout(Duration(minutes: 3)));
    }

    test('rotated_90.mov decodes upright after the display rotation (720x1280)', () async {
      final got = await readAll('rotated_90.mov', 720, 1280);
      expect(got, List<int>.generate(90, (i) => i));
    }, skip: skip);

    test('hlg_10bit_720p.mov decodes through ffmpeg RGB conversion', () async {
      final got = await readAll('hlg_10bit_720p.mov', 1280, 720);
      expect(got, List<int>.generate(90, (i) => i));
    }, skip: skip);

    test('vfr_720p.mp4 decodes in presentation order without frame dropping', () async {
      final frames =
          (loadManifest()['vfr_720p.mp4']!['video'] as Map<String, dynamic>)['frameCount'] as int;
      final got = await readAll('vfr_720p.mp4', 1280, 720);
      expect(got, List<int>.generate(frames, (i) => i));
    }, skip: skip);

    for (final name in <String>['sample_h264_aac.mkv', 'sample_vp9_opus.webm']) {
      test('$name decodes 75 barcode frames', () async {
        final got = await readAll(name, 640, 360);
        expect(got, List<int>.generate(75, (i) => i));
      }, skip: skip);
    }

    test('flash frames in clap_flash_av.mp4 are all-white and keep a readable barcode', () async {
      final flashes = <int>[];
      await forEachRgbaFrame(
        fixtureFile('clap_flash_av.mp4').path,
        width: 1280,
        height: 720,
        onFrame: (i, rgba) {
          // Centre-left sample, away from the digits: bright only on flash frames.
          final p = (400 * 1280 + 100) * 4;
          if (rgba[p] > 240 && rgba[p + 1] > 240 && rgba[p + 2] > 240) flashes.add(i);
        },
      );
      expect(flashes, <int>[30, 75, 120]);
    }, skip: skip);
  });
}
