// OWNER: API-03
//
// The committed vectors and goldens are exactly what `tool/regen_goldens.dart` produces (BUILD_PLAN
// API-03: "regen tool produces no diff on a clean tree"; the goldens are re-rendered and compared
// with the committed PNGs, so this is also the cross-run determinism check), the manifest is
// complete and self-consistent for the Swift/Kotlin parity suites, and the tool's PNG codec and
// JSON printer round-trip.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_editor_core/formats.dart' show readVlut;
import 'package:danaview_editor_core/plan.dart';

import '../../tool/regen_goldens.dart';
import 'support/fixtures.dart';

void main() {
  test('regenerating on a clean tree changes nothing', () {
    final result = regenerate(packageRoot().path, write: false);
    expect(result.files, greaterThan(150));
    expect(result.changes, isEmpty, reason: 'stale: ${result.changes} — run dart run tool/regen_goldens.dart and review');
    expect(result.deleted, isEmpty, reason: 'unexpected files: ${result.deleted}');
  });

  group('goldens.json', () {
    final manifest = jsonDecode(imageFixture('goldens.json').readAsStringSync()) as Map<String, Object?>;
    final goldens = list(manifest['goldens']).map(obj).toList();

    test('about 30 plans, every CORE-29 valid contract plan included, each with frames', () {
      expect(goldens.length, greaterThanOrEqualTo(30));
      final contract = Directory('${packageRoot().path}/../danaview_editor_core/test/fixtures/render_plans/contract')
          .listSync()
          .whereType<File>()
          .map((f) => f.uri.pathSegments.last)
          .where((n) => n.endsWith('.json') && !n.startsWith('patch_') && !n.startsWith('transient_') && !n.contains('expected_active'))
          .toSet();
      final origins = goldens.map((g) => (g['origin']! as String).split('/').last).toSet();
      expect(origins, containsAll(contract));
      expect(goldens.map((g) => g['name']), contains('api03_text_scale_8x'));
      final frames = goldens.fold<int>(0, (n, g) => n + list(g['frames']).length);
      expect(frames, greaterThanOrEqualTo(80));
    });

    for (final g in goldens) {
      test('${g['name']}: plan valid, PNGs and sources present and well-formed', () {
        final plan =
            PlanJson.decodePlanBytes(Uint8List.fromList(utf8.encode(imageFixture(g['plan']! as String).readAsStringSync().trimRight())));
        expect(PlanValidator.validate(plan), isEmpty);
        final size = list(g['size']);
        for (final raw in list(g['frames'])) {
          final f = obj(raw);
          expect(f['tUs'], plan.canvas.frameRate.timeOfFrame(f['k']! as int));
          final png = decodePng(imageFixture(f['png']! as String).readAsBytesSync());
          expect([png.width, png.height], size);
          expect(png.color, PngColor.rgb8);
        }
        if (plan.layers.isNotEmpty) {
          expect(list(g['frames']).any((f) => list(obj(f)['layers']).isNotEmpty), isTrue, reason: 'no frame draws a layer');
        }
        for (final e in obj(g['sources']).entries) {
          final s = obj(e.value);
          final asset = plan.assets[e.key]!;
          switch (s['kind']) {
            case 'video':
              expect(asset.kind, PlanAssetKind.video);
              for (final p in obj(s['frames']).values) {
                final img = decodePng(imageFixture(p! as String).readAsBytesSync());
                expect([img.width, img.height], list(s['size']));
              }
            case 'image':
              expect(decodePng(imageFixture(s['png']! as String).readAsBytesSync()).color, PngColor.rgb8);
            case 'sprite':
              final rgba = decodePng(imageFixture(s['png']! as String).readAsBytesSync());
              expect([rgba.width, rgba.height], [asset.sw, asset.sh]);
              expect(rgba.color, PngColor.rgba8);
              if (s['glyphs'] != null) {
                final glyphs = decodePng(imageFixture(s['glyphs']! as String).readAsBytesSync());
                expect(glyphs.color, PngColor.gray16);
                expect(glyphs.samples.toSet(), contains(0xFFFF));
              }
            case 'lut':
              expect(readVlut(imageFixture(s['vlut']! as String).readAsBytesSync()).size, asset.n);
            default:
              fail('unknown source kind ${s['kind']}');
          }
        }
      });
    }
  });

  group('tool codecs', () {
    test('PNG encode/decode round-trips every supported format', () {
      for (final color in PngColor.values) {
        const w = 7;
        const h = 5;
        final data = Uint8List(w * h * color.bytesPerPixel);
        for (var i = 0; i < data.length; i++) {
          data[i] = (i * 37 + (i ~/ 3) * 11) & 0xFF;
        }
        final png = decodePng(encodePng(w, h, data, color));
        expect([png.width, png.height, png.color], [w, h, color]);
        if (color.bitDepth == 8) {
          expect(png.samples, data);
        } else {
          expect(png.samples, [for (var i = 0; i < data.length; i += 2) (data[i] << 8) | data[i + 1]]);
        }
      }
      expect(() => decodePng(Uint8List.fromList([1, 2, 3])), throwsFormatException);
    });

    test('prettyJson is valid JSON and keeps number arrays on one line', () {
      final value = {
        'a': [1, 2.5, -0.0001],
        'b': [
          [1, 2],
          [3, 4],
        ],
        'c': {'d': null, 'e': 'x', 'f': <Object?>[]},
      };
      final text = prettyJson(value);
      expect(jsonDecode(text), value);
      expect(text, contains('"a": [1, 2.5, -0.0001]'));
      expect(jsonClose(jsonDecode('{"x": 0.1234567891}'), jsonDecode('{"x": 0.1234567899}')), isTrue);
      expect(jsonClose(jsonDecode('{"x": 0.12345679}'), jsonDecode('{"x": 0.12345689}')), isFalse);
      expect(jsonClose(jsonDecode('{"x": 3}'), jsonDecode('{"x": 4}')), isFalse);
    });
  });
}
