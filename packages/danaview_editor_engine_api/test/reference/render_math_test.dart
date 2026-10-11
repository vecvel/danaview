// OWNER: API-03
//
// Render math of ARCH §11.6 (lib/src/math/): independent analytic checks of every stage, and a
// replay of test_fixtures/vectors/render_math.json that builds every input from the JSON alone (the
// way the Swift and Kotlin suites read it), proving the file is complete and matches the code.

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_editor_core/eval.dart';
import 'package:danaview_editor_core/formats.dart' show readVlut;
import 'package:danaview_editor_core/plan.dart';
import 'package:danaview_editor_engine_api/testing.dart';
import 'package:danaview_editor_engine_api/danaview_editor_engine_api.dart';

import 'support/fixtures.dart';

Matcher rgbaNear(RenderRgba e, [double eps = 1e-9]) => predicate<RenderRgba>((c) => c.closeTo(e, eps), 'close to $e');

RenderRaster rasterOf(List<Object?> texels, int w, int h) {
  final r = RenderRaster(w, h);
  for (var i = 0; i < w * h; i++) {
    r.setPixel(i % w, i ~/ w, RenderRgba.fromList(doubles(texels[i])));
  }
  return r;
}

void main() {
  group('pointwise stages (analytic)', () {
    test('luma weights are BT.709 and sum to 1', () {
      expect(RenderMath.lumaR + RenderMath.lumaG + RenderMath.lumaB, closeTo(1, 1e-12));
      expect(RenderMath.luma(1, 1, 1), closeTo(1, 1e-12));
    });

    test('chroma key: the key colour is transparent, distant colours opaque, the edge is a smoothstep', () {
      const green = PlanChroma(key: 0x00B140, sim: 0.4, smooth: 0.1, spill: 0.5);
      expect(RenderMath.chromaKey(RenderRgba.fromRgb(0x00B140), green).a, 0);
      expect(RenderMath.chromaKey(const RenderRgba(0.9, 0.3, 0.1), green).a, 1);
      // Exactly at d = s0 + s1/2 the alpha is 0.5.
      final (kb, kr) = RenderMath.chromaOf(0, 0xB1 / 255, 0x40 / 255);
      final (cb, cr) = RenderMath.chromaOf(0.5, 0.5, 0.5); // grey: Cb = Cr = 0
      final d = math.sqrt((cb - kb) * (cb - kb) + (cr - kr) * (cr - kr));
      final mid = PlanChroma(key: 0x00B140, sim: (d - 0.0125) / 0.25, smooth: 0.1, spill: 0);
      expect(RenderMath.chromaKeyAlpha(const RenderRgba(0.5, 0.5, 0.5), mid), closeTo(0.5, 1e-9));
      // smooth = 0 still has a 0.001 wide edge.
      final hard = PlanChroma(key: 0x00B140, sim: d / 0.25, smooth: 0, spill: 0);
      expect(RenderMath.chromaKeyAlpha(const RenderRgba(0.5, 0.5, 0.5), hard), 0);
    });

    test('spill removes the key direction, keeps luma and never adds the key colour', () {
      const green = PlanChroma(key: 0x00B140, sim: 0, smooth: 0, spill: 1);
      const c = RenderRgba(0.6, 0.8, 0.5);
      final o = RenderMath.chromaKey(c, green);
      expect(o.luma, closeTo(c.luma, 1e-9));
      final (kb, kr) = RenderMath.chromaOf(0, 0xB1 / 255, 0x40 / 255);
      final (ob, or) = RenderMath.chromaOf(o.r, o.g, o.b);
      expect(ob * kb + or * kr, lessThanOrEqualTo(1e-9));
      // A colour pointing away from the key is untouched.
      const away = RenderRgba(0.8, 0.3, 0.6);
      final kept = RenderMath.chromaKey(away, green);
      expect(RenderRgba(kept.r, kept.g, kept.b), rgbaNear(away, 1e-9));
    });

    test('exposure doubles linear light per +0.5 and is the identity at 0', () {
      const c = RenderRgba(0.2, 0.5, 0.8);
      final o = RenderMath.exposure(c, 0.5);
      expect(math.pow(o.r, 2.2), closeTo(2 * math.pow(0.2, 2.2), 1e-12));
      expect(RenderMath.exposure(c, 0), same(c));
    });

    test('brightness, contrast, highlights, shadows, saturation, temperature and tint follow ARCH §11.6', () {
      expect(RenderMath.brightnessContrast(const RenderRgba(0.2, 0.5, 0.8), 0.4, 0).r, closeTo(0.3, 1e-12));
      expect(RenderMath.brightnessContrast(const RenderRgba(0.2, 0.5, 0.8), 0, 1).r, closeTo(-0.1, 1e-12));
      expect(RenderMath.highlightsShadows(const RenderRgba(1, 1, 1), 1, 0).r, closeTo(1.25, 1e-12));
      expect(RenderMath.highlightsShadows(const RenderRgba(0, 0, 0), 0, 1).r, closeTo(0.25, 1e-12));
      final grey = RenderMath.saturation(const RenderRgba(0.9, 0.3, 0.1), -1);
      expect(grey.r, closeTo(RenderMath.luma(0.9, 0.3, 0.1), 1e-12));
      expect(grey.g, closeTo(grey.b, 1e-12));
      final warm = RenderMath.temperatureTint(const RenderRgba(0.95, 0.5, 0.5), 1, -1);
      expect(warm.r, 1); // 0.95·1.1 clamped
      expect(warm.b, closeTo(0.45, 1e-12));
      expect(warm.g, closeTo(0.55, 1e-12));
      // A neutral grade is the identity (up to pow round-off).
      expect(RenderMath.grade(const RenderRgba(0.3, 0.6, 0.9, 0.5), const PlanAdjust()),
          rgbaNear(const RenderRgba(0.3, 0.6, 0.9, 0.5), 1e-12));
    });

    test('LUT: identity tables are the identity, grid nodes hit entries exactly, intensity mixes', () {
      final id = RenderLut.identity(5);
      expect(RenderMath.lut(const RenderRgba(0.13, 0.57, 0.91), id, 1), rgbaNear(const RenderRgba(0.13, 0.57, 0.91), 1e-12));
      final lut = RenderLut.fromVlut(readVlut(SyntheticSources.vlutBytes(17)));
      final (er, eg, eb) = lut.entry(4, 8, 12);
      final (lr, lg, lb) = lut.lookup(4 / 16, 8 / 16, 12 / 16);
      expect([lr, lg, lb], [er, eg, eb]);
      final half = RenderMath.lut(const RenderRgba(0.25, 0.5, 0.75), lut, 0.5);
      expect(half.r, closeTo((0.25 + er) / 2, 1e-12));
      // Out-of-range input is clamped before the lookup.
      expect(lut.lookup(-1, 2, 0.5), lut.lookup(0, 1, 0.5));
    });
  });

  group('spatial stages (analytic)', () {
    test('Gaussian kernels are normalized, symmetric and ⌈3σ⌉ wide; σ < 0.5 is skipped', () {
      for (final s in [0.5, 1.0, 2.5, 7.3]) {
        final k = RenderMath.gaussianKernel(s);
        expect(k.length, 2 * (3 * s).ceil() + 1);
        expect(k.reduce((a, b) => a + b), closeTo(1, 1e-12));
        for (var i = 0; i < k.length; i++) {
          expect(k[i], closeTo(k[k.length - 1 - i], 1e-15));
        }
      }
      final r = RenderRaster.filled(4, 4, const RenderRgba(0.2, 0.3, 0.4));
      expect(RenderMath.gaussianBlur(r, 0.49), same(r));
      expect(RenderMath.blurSkipped(0.5), isFalse);
    });

    test('blur keeps uniform images and conserves mass away from the edges', () {
      final flat = RenderRaster.filled(9, 7, const RenderRgba(0.2, 0.3, 0.4, 0.8));
      final b = RenderMath.gaussianBlur(flat, 1.3);
      for (var i = 0; i < b.data.length; i++) {
        expect(b.data[i], closeTo(flat.data[i], 1e-12));
      }
      final impulse = RenderRaster(21, 21)..setPixel(10, 10, const RenderRgba(1, 1, 1));
      final spread = RenderMath.gaussianBlur(impulse, 1.5);
      var sum = 0.0;
      for (var i = 3; i < spread.data.length; i += 4) {
        sum += spread.data[i];
      }
      expect(sum, closeTo(1, 1e-12));
    });

    test('blur σ is plan-canvas px converted by layer scale and render scale', () {
      expect(RenderMath.blurSigmaCanvasPx(0.5, 1080, 1920), closeTo(16.2, 1e-12));
      expect(RenderMath.blurSigmaSourcePx(16.2, 0.5), closeTo(32.4, 1e-12));
      expect(RenderMath.blurSigmaRenderPx(16.2, 0.05), closeTo(0.81, 1e-12));
      expect(RenderMath.blurRadius(0.81), 3);
    });

    test('sharpen leaves flat areas alone and clamps to [0, alpha]', () {
      final flat = RenderRaster.filled(5, 5, const RenderRgba(0.3, 0.3, 0.3, 0.6));
      final s = RenderMath.sharpen(flat, 1);
      for (var i = 0; i < s.data.length; i++) {
        expect(s.data[i], closeTo(flat.data[i], 1e-12));
      }
      final spike = RenderRaster.filled(3, 3, const RenderRgba(0, 0, 0))..setPixel(1, 1, const RenderRgba(0.9, 0.9, 0.9));
      final out = RenderMath.sharpen(spike, 1);
      expect(out.pixel(1, 1).r, 1); // 0.9 + 1.5·(0.9 − 0.1) clamped to alpha 1
      expect(out.pixel(0, 0).r, 0); // negative overshoot clamped
    });

    test('vignette: 1 at the centre, 1 − amount at the corners', () {
      expect(RenderMath.vignetteFactor(0.5, 0.5, 16 / 9, 0.8), 1);
      expect(RenderMath.vignetteFactor(0, 0, 16 / 9, 0.8), closeTo(0.2, 1e-12));
      expect(RenderMath.vignetteFactor(1, 1, 1, 0.3), closeTo(0.7, 1e-12));
    });

    test('item masks: hard rect, inversion, opacity, feather midpoint, aspect-correct rotation', () {
      const rect = PlanMask(shape: PlanMaskShape.rect, w: 0.5, h: 0.5);
      expect(RenderMath.maskAlpha(rect, 0.5, 0.5, 100, 100), 1);
      expect(RenderMath.maskAlpha(rect, 0.8, 0.5, 100, 100), 0);
      expect(RenderMath.maskAlpha(const PlanMask(shape: PlanMaskShape.rect, w: 0.5, h: 0.5, inv: true), 0.8, 0.5, 100, 100), 1);
      expect(RenderMath.maskAlpha(const PlanMask(shape: PlanMaskShape.rect, w: 0.5, h: 0.5, op: 0.25), 0.8, 0.5, 100, 100), 0.75);
      // On the edge of a feathered ellipse the alpha is 0.5.
      expect(RenderMath.maskAlpha(const PlanMask(shape: PlanMaskShape.ellipse, w: 0.5, h: 0.5, feather: 0.4), 0.75, 0.5, 100, 100),
          closeTo(0.5, 1e-12));
      // A 0.4 × 0.2 rect on a 200 × 100 base is 80 × 20 px; rotated 90° it is 20 × 80 px.
      const rot = PlanMask(shape: PlanMaskShape.rect, w: 0.4, h: 0.2, r: 90);
      expect(RenderMath.maskAlpha(rot, 0.5, 0.5 + 35 / 100, 200, 100), 1);
      expect(RenderMath.maskAlpha(rot, 0.5 + 15 / 200, 0.5, 200, 100), 0);
      // Rounded corners cut the box corner.
      expect(RenderMath.roundedBoxSdf(10, 10, 10, 10, 4), closeTo(4 * math.sqrt2 - 4, 1e-12));
      expect(RenderMath.ellipseSdf(0, 0, 0, 5), double.infinity);
    });

    test('canvas masks use px feather and rotate about their centre', () {
      const m = CanvasMask(cx: 100, cy: 100, w: 40, h: 20, feather: 5);
      expect(RenderMath.canvasMaskAlpha(m, 120, 100), closeTo(0.5, 1e-12));
      expect(RenderMath.canvasMaskAlpha(m, 100, 100), 1);
      const r = CanvasMask(cx: 100, cy: 100, w: 40, h: 20, r: 90);
      expect(RenderMath.canvasMaskAlpha(r, 100, 115), 1);
      expect(RenderMath.canvasMaskAlpha(r, 115, 100), 0);
      expect(RenderMath.canvasMaskAlpha(const CanvasMask(cx: 100, cy: 100, w: 40, h: 20, r: 90, inv: true), 115, 100), 1);
    });
  });

  group('place, composite, sprites, quantization', () {
    test('placement is core planPlacementMatrix (the boxAt M)', () {
      const xf = PlanTransform(cx: 300, cy: 200, s: 0.8, r: 33, fx: true);
      const base = PlanSize(400, 225);
      const canvas = PlanCanvas(w: 1280, h: 720, fps: 30);
      expect(RenderMath.placement(xf, base, canvas), planPlacementMatrix(xf, base, const Size2(1280, 720)));
      expect(RenderMath.placement(PlanTransform.identity, const PlanSize(1280, 720), canvas), Affine2.identity);
    });

    test('effective base: own, sprite size / sscale, else the canvas', () {
      const canvas = PlanCanvas(w: 1280, h: 720, fps: 30);
      const sprite = PlanAsset(kind: PlanAssetKind.sprite, uri: 'file:///s.vsprite', sw: 900, sh: 160, sscale: 1.5);
      final l = PlanLayer(id: 'a#v', z: 20010, t0: 0, t1: 1, kind: PlanLayerKind.sprite, asset: 's');
      expect(RenderMath.effectiveBase(l, sprite, canvas), const PlanSize(600, 160 / 1.5));
      final s = PlanLayer(id: 'b#v', z: 10, t0: 0, t1: 1, kind: PlanLayerKind.solid, color: 0xFF000000);
      expect(RenderMath.effectiveBase(s, null, canvas), const PlanSize(1280, 720));
    });

    test('premultiplied source-over', () {
      expect(RenderMath.sourceOver(const RenderRgba(0.5, 0, 0, 0.5), const RenderRgba(0, 0, 1, 1)), const RenderRgba(0.5, 0, 0.5, 1));
      expect(RenderMath.sourceOver(RenderRgba.transparent, const RenderRgba(0.3, 0.3, 0.3, 1)), const RenderRgba(0.3, 0.3, 0.3, 1));
      expect(RenderMath.unpremultiply(RenderMath.premultiply(const RenderRgba(0.2, 0.4, 0.6, 0.5))),
          rgbaNear(const RenderRgba(0.2, 0.4, 0.6, 0.5)));
    });

    test('sprite reveal draws glyph g iff g < floor(reveal); background only when not animated', () {
      expect(RenderMath.spriteTexelDrawn(0, 0.99), isFalse);
      expect(RenderMath.spriteTexelDrawn(0, 1), isTrue);
      expect(RenderMath.spriteTexelDrawn(3, 3.999), isFalse);
      expect(RenderMath.spriteTexelDrawn(RenderMath.spriteBackgroundGlyph, 1000), isFalse);
      expect(RenderMath.spriteTexelDrawn(RenderMath.spriteBackgroundGlyph, null), isTrue);
    });

    test('8-bit quantization rounds half up and clamps', () {
      expect([
        for (final v in [0.0, 0.5 / 255, 127.5 / 255, 1.0, -0.2, 1.3]) RenderMath.toByte(v)
      ], [
        0,
        1,
        128,
        255,
        0,
        255
      ]);
    });
  });

  group('render_math.json replays from the JSON alone', () {
    final doc = vectorFile('render_math.json');
    final luts = <String, RenderLut>{
      for (final e in obj(doc['luts']).entries)
        e.key: () {
          final j = obj(e.value);
          final file = j['file'] as String?;
          if (file != null) {
            final bytes = File('${packageRoot().path}/test_fixtures/vectors/$file').readAsBytesSync();
            return RenderLut.fromVlut(readVlut(Uint8List.fromList(bytes)));
          }
          return RenderLut(j['n']! as int, Float64List.fromList(doubles(j['rgb'])));
        }(),
    };

    test('the file covers every stage of ARCH §11.6', () {
      final stages = {for (final r in list(doc['rows'])) obj(r)['stage']};
      expect(
          stages,
          containsAll(<String>[
            'chromaKey', 'exposure', 'brightnessContrast', 'highlightsShadows', 'saturation', 'temperatureTint', 'grade', 'lut', //
            'gaussianBlur', 'sharpen', 'vignette', 'mask', 'canvasMask', 'place', 'composite', 'spriteReveal',
          ]));
      expect(obj(doc['scalars']).keys,
          containsAll(<String>['blurSigma', 'gaussianKernel', 'vignetteFactor', 'maskAlpha', 'canvasMaskAlpha', 'toByte']));
    });

    for (final raw in list(doc['rows'])) {
      final row = obj(raw);
      test('${row['stage']} ${row['name']}', () {
        final w = row['w']! as int;
        final h = row['h']! as int;
        final p = obj(row['params']);
        final tol = asDouble(row['tol']);
        final input = row['inImage'] != null
            ? rasterOf(list(row['inImage']), w, h)
            : RenderRaster.filled(w, h, RenderRgba.fromList(doubles(row['in'])));
        double d(String k) => asDouble(p[k]);
        PlanChroma chroma(Map<String, Object?> j) => PlanChroma(
              key: int.parse((j['key']! as String).substring(1), radix: 16),
              sim: asDouble(j['sim']),
              smooth: asDouble(j['smooth']),
              spill: asDouble(j['spill']),
            );
        PlanAdjust adj(Map<String, Object?> j) => PlanAdjust(
              exposure: asDouble(j['exposure']),
              brightness: asDouble(j['brightness']),
              contrast: asDouble(j['contrast']),
              highlights: asDouble(j['highlights']),
              shadows: asDouble(j['shadows']),
              saturation: asDouble(j['saturation']),
              temperature: asDouble(j['temperature']),
              tint: asDouble(j['tint']),
            );
        PlanMask mask(Map<String, Object?> j) => PlanMask(
              shape: PlanMaskShape.values.byName(j['shape']! as String),
              cx: asDouble(j['cx']),
              cy: asDouble(j['cy']),
              w: asDouble(j['w']),
              h: asDouble(j['h']),
              r: asDouble(j['r']),
              corner: asDouble(j['corner']),
              feather: asDouble(j['feather']),
              op: asDouble(j['op']),
              inv: j['inv']! as bool,
            );
        final RenderRgba Function(RenderRgba)? pointwise = switch (row['stage']) {
          'chromaKey' => (c) => RenderMath.chromaKey(c, chroma(p)),
          'exposure' => (c) => RenderMath.exposure(c, d('exposure')),
          'brightnessContrast' => (c) => RenderMath.brightnessContrast(c, d('brightness'), d('contrast')),
          'highlightsShadows' => (c) => RenderMath.highlightsShadows(c, d('highlights'), d('shadows')),
          'saturation' => (c) => RenderMath.saturation(c, d('saturation')),
          'temperatureTint' => (c) => RenderMath.temperatureTint(c, d('temperature'), d('tint')),
          'grade' => (c) => RenderMath.grade(c, adj(obj(p['adj']))),
          'lut' => (c) => RenderMath.lut(c, luts[p['lut']]!, d('i')),
          'composite' => (c) => RenderMath.sourceOver(c, RenderRgba.fromList(doubles(p['dst']))),
          _ => null,
        };
        final RenderRaster out;
        if (pointwise != null) {
          out = RenderRaster(w, h);
          for (var y = 0; y < h; y++) {
            for (var x = 0; x < w; x++) {
              out.setPixel(x, y, pointwise(input.pixel(x, y)));
            }
          }
        } else {
          switch (row['stage']) {
            case 'gaussianBlur':
              out = RenderMath.gaussianBlur(input, d('sigma'));
            case 'sharpen':
              out = RenderMath.sharpen(input, d('amount'));
            case 'vignette':
            case 'mask':
            case 'canvasMask':
            case 'spriteReveal':
              out = RenderRaster(w, h);
              for (var y = 0; y < h; y++) {
                for (var x = 0; x < w; x++) {
                  final u = (x + 0.5) / w;
                  final v = (y + 0.5) / h;
                  final c = input.pixel(x, y);
                  out.setPixel(
                    x,
                    y,
                    switch (row['stage']) {
                      'vignette' => () {
                          final k = RenderMath.vignetteFactor(u, v, d('aspect'), d('amount'));
                          return RenderRgba(c.r * k, c.g * k, c.b * k, c.a);
                        }(),
                      'mask' => () {
                          final b = doubles(p['base']);
                          final k = RenderMath.maskAlpha(mask(obj(p['mask'])), u, v, b[0], b[1]);
                          return RenderRgba(c.r * k, c.g * k, c.b * k, c.a * k);
                        }(),
                      'canvasMask' => () {
                          final j = obj(p['cmask']);
                          final m = CanvasMask(
                            cx: asDouble(j['cx']),
                            cy: asDouble(j['cy']),
                            w: asDouble(j['w']),
                            h: asDouble(j['h']),
                            r: asDouble(j['r']),
                            feather: asDouble(j['feather']),
                            inv: j['inv']! as bool,
                          );
                          final k = RenderMath.canvasMaskAlpha(m, x + 0.5, y + 0.5);
                          return RenderRgba(c.r * k, c.g * k, c.b * k, c.a * k);
                        }(),
                      _ => () {
                          final glyph = (list(p['glyphs'])[y * w + x]! as num).toInt();
                          final reveal = p['reveal'] == null ? null : d('reveal');
                          return RenderMath.spriteTexelDrawn(glyph, reveal) ? c : RenderRgba.transparent;
                        }(),
                    },
                  );
                }
              }
            case 'place':
              final b = doubles(p['base']);
              final m = doubles(p['M']);
              final xf = obj(p['xf']);
              out = RenderRaster(w, h);
              ReferenceRenderer.placeOnto(
                  out, input, Affine2(m[0], m[1], m[2], m[3], m[4], m[5]), PlanSize(b[0], b[1]), asDouble(xf['op']), const [], 1, 1);
            default:
              fail('unknown stage ${row['stage']}');
          }
        }
        final expected = row['outImage'] != null
            ? rasterOf(list(row['outImage']), w, h)
            : RenderRaster.filled(w, h, RenderRgba.fromList(doubles(row['out'])));
        for (var i = 0; i < out.data.length; i++) {
          expect(out.data[i], closeTo(expected.data[i], tol), reason: 'texel ${i ~/ 4} channel ${i % 4}');
        }
      });
    }

    test('scalars', () {
      final s = obj(doc['scalars']);
      for (final raw in list(s['blurSigma'])) {
        final j = obj(raw);
        final c = doubles(j['canvas']);
        final sigma = RenderMath.blurSigmaCanvasPx(asDouble(j['blur']), c[0].toInt(), c[1].toInt());
        expect(sigma, closeTo(asDouble(j['sigmaCanvasPx']), 1e-9));
        expect(RenderMath.blurSigmaSourcePx(sigma, asDouble(j['canvasPxPerSourcePx'])), closeTo(asDouble(j['sigmaSourcePx']), 1e-9));
        final render = RenderMath.blurSigmaRenderPx(sigma, asDouble(j['renderScale']));
        expect(render, closeTo(asDouble(j['sigmaRenderPx']), 1e-9));
        expect(RenderMath.blurRadius(render), j['radiusRender']);
        expect(RenderMath.blurSkipped(render), j['skippedRender']);
      }
      for (final raw in list(s['gaussianKernel'])) {
        final j = obj(raw);
        final k = RenderMath.gaussianKernel(asDouble(j['sigma']));
        final e = doubles(j['weights']);
        expect(k.length, e.length);
        for (var i = 0; i < k.length; i++) {
          expect(k[i], closeTo(e[i], 1e-9));
        }
      }
      for (final raw in list(s['vignetteFactor'])) {
        final j = obj(raw);
        expect(RenderMath.vignetteFactor(asDouble(j['u']), asDouble(j['v']), asDouble(j['aspect']), asDouble(j['amount'])),
            closeTo(asDouble(j['factor']), 1e-9));
      }
      for (final raw in list(s['canvasMaskAlpha'])) {
        final j = obj(raw);
        final m = obj(j['cmask']);
        final cm = CanvasMask(
          cx: asDouble(m['cx']),
          cy: asDouble(m['cy']),
          w: asDouble(m['w']),
          h: asDouble(m['h']),
          r: asDouble(m['r']),
          feather: asDouble(m['feather']),
          inv: m['inv']! as bool,
        );
        expect(RenderMath.canvasMaskAlpha(cm, asDouble(j['x']), asDouble(j['y'])), closeTo(asDouble(j['alpha']), 1e-9));
      }
      for (final raw in list(s['toByte'])) {
        final j = obj(raw);
        expect(RenderMath.toByte(asDouble(j['v'])), j['byte']);
      }
      expect(list(s['maskAlpha']), hasLength(greaterThanOrEqualTo(6)));
      for (final raw in list(s['maskAlpha'])) {
        final j = obj(raw);
        final m = obj(j['mask']);
        final b = doubles(j['base']);
        final mask = PlanMask(
          shape: PlanMaskShape.values.byName(m['shape']! as String),
          cx: asDouble(m['cx']),
          cy: asDouble(m['cy']),
          w: asDouble(m['w']),
          h: asDouble(m['h']),
          r: asDouble(m['r']),
          corner: asDouble(m['corner']),
          feather: asDouble(m['feather']),
          op: asDouble(m['op']),
          inv: m['inv']! as bool,
        );
        expect(RenderMath.maskAlpha(mask, asDouble(j['u']), asDouble(j['v']), b[0], b[1]), closeTo(asDouble(j['alpha']), 1e-9));
      }
    });
  });
}
