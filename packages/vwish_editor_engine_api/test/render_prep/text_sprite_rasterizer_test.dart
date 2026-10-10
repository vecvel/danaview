// OWNER: API-04
//
// TextSpriteRasterizer (ARCH §10.3, D-06): sprite size and centring, the raster-scale clamp
// (maxTextureSize, 2 × output long side), premultiplied output, parity with the preview paint,
// glyph-order maps over grapheme clusters (typewriter), and RTL / CJK / emoji rendering through
// the font fallback (V-A11).

import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:vwish_editor_core/eval.dart';
import 'package:vwish_editor_engine_api/vwish_editor_engine_api.dart';

import 'support.dart';

/// Renders [layout] like the preview overlay does (block top-left at the sprite's block origin).
Future<Uint8List> paintLikePreview(TextBlockLayout layout, int w, int h, double scale, {int? revealCount}) async {
  final rec = ui.PictureRecorder();
  final c = ui.Canvas(rec);
  c
    ..translate(w / 2, h / 2)
    ..scale(scale);
  layout.paint(c, ui.Offset(-layout.blockSize.width / 2, -layout.blockSize.height / 2), revealCount: revealCount);
  final img = await rec.endRecording().toImage(w, h);
  final data = (await img.toByteData(format: ui.ImageByteFormat.rawRgba))!;
  img.dispose();
  return data.buffer.asUint8List();
}

/// Bounding box of pixels with alpha > 0, or null.
ui.Rect? inkBounds(Uint8List rgba, int w, int h) {
  var x0 = w, y0 = h, x1 = -1, y1 = -1;
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      if (rgba[(y * w + x) * 4 + 3] != 0) {
        x0 = math.min(x0, x);
        y0 = math.min(y0, y);
        x1 = math.max(x1, x);
        y1 = math.max(y1, y);
      }
    }
  }
  return x1 < 0 ? null : ui.Rect.fromLTRB(x0.toDouble(), y0.toDouble(), x1 + 1.0, y1 + 1.0);
}

void main() {
  setUpAll(loadFigtree);

  test('size = raster extent × scale, block centred, everything painted inside', () async {
    final r = TextSpriteRasterizer();
    final s = spec('Centred title',
        fontSizePx: 80,
        box: const TextBoxSpec(color: 0xFF203040, opacity: 0.8, paddingPx: 18, cornerRadiusPx: 10),
        stroke: const TextStrokeSpec(color: 0xFF000000, widthPx: 3),
        shadow: const TextShadowSpec(color: 0xFF000000, opacity: 0.5, blurPx: 6, offset: Offset2(0, 6)));
    final sprite = await r.rasterize(request(s, scale: 1.5));
    final l = r.engine.layoutSpec(s);
    expect(sprite.scale, 1.5);
    expect(sprite.width, (l.rasterSize.width * 1.5).ceil());
    expect(sprite.height, (l.rasterSize.height * 1.5).ceil());
    // The box is the block: its ink is centred in the sprite (symmetric padding).
    final ink = inkBounds(sprite.rgba, sprite.width, sprite.height)!;
    final boxW = l.blockSize.width * 1.5;
    final boxH = l.blockSize.height * 1.5;
    expect(ink.left, greaterThan(0));
    expect(ink.top, greaterThan(0));
    expect(ink.right, lessThan(sprite.width));
    expect(ink.bottom, lessThan(sprite.height));
    final boxRect = ui.Rect.fromCenter(center: ui.Offset(sprite.width / 2, sprite.height / 2), width: boxW, height: boxH);
    // The box's top-left corner region (inside the rounded corner) is opaque box colour.
    final px = (boxRect.left + 12).floor();
    final py = (boxRect.top + 12).floor();
    expect(alphaAt(sprite.rgba, sprite.width, px, py), greaterThan(150));
    expect(alphaAt(sprite.rgba, sprite.width, (boxRect.left - 3).floor(), (boxRect.top + boxH / 2).floor()), 0,
        reason: 'nothing left of the box at mid height (shadow is straight down)');
  });

  test('premultiplied RGBA: colour channels never exceed alpha', () async {
    final sprite = await TextSpriteRasterizer().rasterize(request(spec('Alpha', color: 0x80FF8040, fontSizePx: 90), scale: 1));
    var semi = 0;
    for (var i = 0; i < sprite.rgba.length; i += 4) {
      final a = sprite.rgba[i + 3];
      expect(sprite.rgba[i], lessThanOrEqualTo(a));
      expect(sprite.rgba[i + 1], lessThanOrEqualTo(a));
      expect(sprite.rgba[i + 2], lessThanOrEqualTo(a));
      if (a > 0 && a < 255) semi++;
    }
    expect(semi, greaterThan(0));
  });

  test('scale clamp: maxTextureSize and 2 × output long side; the used scale is reported', () async {
    final r = TextSpriteRasterizer();
    final s = spec('A wide 8x title', fontSizePx: 120, maxWidthPx: 1900);
    final extent = r.engine.layoutSpec(s).rasterSize;
    // 8× on a 1080p output: limited by maxTextureSize 2048 (below 2 × 1920).
    final big = r.prepare(request(s, scale: 8), maxTextureSize: 2048);
    expect(math.max(big.width, big.height), lessThanOrEqualTo(2048));
    expect(big.scale, lessThan(8));
    expect(big.scale, closeTo(2048 / math.max(extent.width, extent.height), 1e-3));
    big.dispose();
    // With 4096 the output bound 2 × 1920 = 3840 binds.
    final out = r.prepare(request(s, scale: 8), maxTextureSize: 4096);
    expect(out.scale, closeTo(3840 / math.max(extent.width, extent.height), 1e-3));
    expect(math.max(out.width, out.height), lessThanOrEqualTo(3840));
    out.dispose();
    // A small output canvas: 2 × long side (2 × 640) wins over 16384.
    final small = r.prepare(request(s, scale: 8, outW: 640, outH: 360), maxTextureSize: 16384);
    expect(math.max(small.width, small.height), lessThanOrEqualTo(1280));
    expect(small.scale, closeTo(1280 / math.max(extent.width, extent.height), 1e-3));
    small.dispose();
    // Unclamped.
    final ok = r.prepare(request(s, scale: 1), maxTextureSize: 4096);
    expect(ok.scale, 1);
    ok.dispose();
    expect(TextSpriteRasterizer.clampScale(2, const ui.Size(100, 50), maxTextureSize: 100, outputLongSide: 1000), 1);
  });

  test('parity: the sprite equals the preview paint of the same layout at the same scale', () async {
    final r = TextSpriteRasterizer();
    final s = spec('Parity check', fontSizePx: 70, stroke: const TextStrokeSpec(color: 0xFF000000, widthPx: 2));
    final sprite = await r.rasterize(request(s, scale: 1.25));
    final preview = await paintLikePreview(r.engine.layoutSpec(s), sprite.width, sprite.height, sprite.scale);
    var maxDiff = 0;
    for (var i = 0; i < preview.length; i++) {
      maxDiff = math.max(maxDiff, (preview[i] - sprite.rgba[i]).abs());
    }
    expect(maxDiff, lessThanOrEqualTo(1));
  });

  group('glyph-order map (typewriter)', () {
    test('only reveal requests carry a map; transparent pixels are 0xFFFF', () async {
      final r = TextSpriteRasterizer();
      final plain = await r.rasterize(request(spec('abc')));
      expect(plain.glyphs, isNull);
      final rev = await r.rasterize(request(spec('abc'), reveal: true));
      final g = rev.glyphs!;
      for (var i = 0; i < g.length; i++) {
        if (rev.rgba[i * 4 + 3] == 0) expect(g[i], 0xFFFF);
        if (rev.rgba[i * 4 + 3] != 0) expect(g[i], lessThan(3));
      }
    });

    test('grapheme clusters: one id per cluster, increasing in reading order', () async {
      final r = TextSpriteRasterizer();
      const text = 'Aé👍🏽B';
      final s = spec(text, fontSizePx: 90);
      final sprite = await r.rasterize(request(s, reveal: true));
      final l = r.engine.layoutSpec(s);
      expect(l.glyphCount, 4);
      final g = sprite.glyphs!;
      final ids = <int>{for (final v in g) if (v != 0xFFFF) v};
      expect(ids.every((v) => v < 4), isTrue, reason: 'ids are cluster indexes, not code units ($ids)');
      // Each cluster's own box centre maps to its index (in sprite px).
      final block = l.blockSize;
      for (final c in l.glyphs) {
        final b = c.boxes.first.toRect();
        final sx = ((b.center.dx - block.width / 2) * sprite.scale + sprite.width / 2).floor();
        final sy = ((b.center.dy - block.height / 2) * sprite.scale + sprite.height / 2).floor();
        final strip = glyphMapOf(Uint8List(sprite.width * sprite.height * 4)..fillRange(0, sprite.width * sprite.height * 4, 255),
            sprite.width, sprite.height, r.prepare(request(s, reveal: true)).strips);
        expect(strip[sy * sprite.width + sx], c.index, reason: 'cluster ${c.index}');
      }
      // Left to right: the mean x of each id increases.
      final sumX = List<double>.filled(4, 0);
      final cnt = List<int>.filled(4, 0);
      for (var i = 0; i < g.length; i++) {
        if (g[i] == 0xFFFF) continue;
        sumX[g[i]] += i % sprite.width;
        cnt[g[i]]++;
      }
      final means = [for (var i = 0; i < 4; i++) if (cnt[i] > 0) sumX[i] / cnt[i]];
      for (var i = 1; i < means.length; i++) {
        expect(means[i], greaterThan(means[i - 1]));
      }
    });

    test('RTL: ids increase right to left', () async {
      final r = TextSpriteRasterizer();
      final sprite = await r.rasterize(request(spec('אבגד', fontSizePx: 90), reveal: true));
      final g = sprite.glyphs!;
      final sumX = List<double>.filled(4, 0);
      final cnt = List<int>.filled(4, 0);
      for (var i = 0; i < g.length; i++) {
        if (g[i] == 0xFFFF) continue;
        sumX[g[i]] += i % sprite.width;
        cnt[g[i]]++;
      }
      expect(cnt.every((c) => c > 0), isTrue);
      for (var i = 1; i < 4; i++) {
        expect(sumX[i] / cnt[i], lessThan(sumX[i - 1] / cnt[i - 1]));
      }
    });

    test('revealing k glyphs with the map equals the preview clip for k (box grows with the text)', () async {
      final r = TextSpriteRasterizer();
      final s = spec('Hi there\nsecond', fontSizePx: 60, box: const TextBoxSpec(color: 0xFF336699, opacity: 1, paddingPx: 14, cornerRadiusPx: 0));
      final sprite = await r.rasterize(request(s, reveal: true));
      final l = r.engine.layoutSpec(s);
      for (final k in [1, 4, 9, l.glyphCount]) {
        final preview = await paintLikePreview(l, sprite.width, sprite.height, sprite.scale, revealCount: k);
        var mismatched = 0;
        var drawn = 0;
        for (var i = 0; i < sprite.glyphs!.length; i++) {
          final shown = sprite.glyphs![i] < k; // RenderMath.spriteTexelDrawn
          final a = shown ? sprite.rgba[i * 4 + 3] : 0;
          if (a > 0) drawn++;
          if ((a - preview[i * 4 + 3]).abs() > 2) mismatched++;
        }
        // Clip anti-aliasing touches at most the strip edges: one pixel column per boundary.
        expect(mismatched, lessThanOrEqualTo(sprite.height * 2 * (l.glyphCount + 2)), reason: 'k $k');
        expect(drawn, greaterThan(0));
      }
      expect(RenderMath.spriteTexelDrawn(sprite.glyphs!.first, 0), isFalse);
    });
  });

  group('scripts and fallback (V-A11)', () {
    // Figtree covers Latin only. On device, CJK, Arabic, Hebrew, Devanagari and emoji come from
    // the system fallback (CoreText / Android font chain) in preview and export alike. Here a host
    // Unicode font plays the system fallback through `fallbackFamilies`.
    Future<(int, int)> inkInsideGlyphs(String text, List<String> fallback) async {
      final r = TextSpriteRasterizer(engine: TextLayoutEngine(fallbackFamilies: fallback));
      final s = spec(text, fontSizePx: 80);
      final sprite = await r.rasterize(request(s));
      final l = r.engine.layoutSpec(s);
      final block = l.blockSize;
      var inked = 0;
      for (final g in l.glyphs) {
        final b = g.bounds;
        if (b == null || text.substring(g.start, g.end).trim().isEmpty) continue;
        final x0 = ((b.left - block.width / 2) * sprite.scale + sprite.width / 2).floor();
        final x1 = ((b.right - block.width / 2) * sprite.scale + sprite.width / 2).ceil();
        final y0 = ((b.top - block.height / 2) * sprite.scale + sprite.height / 2).floor();
        final y1 = ((b.bottom - block.height / 2) * sprite.scale + sprite.height / 2).ceil();
        var any = false;
        for (var y = math.max(0, y0); y < math.min(sprite.height, y1) && !any; y++) {
          for (var x = math.max(0, x0); x < math.min(sprite.width, x1); x++) {
            if (alphaAt(sprite.rgba, sprite.width, x, y) > 64) {
              any = true;
              break;
            }
          }
        }
        if (any) inked++;
      }
      final visible = l.glyphs.where((g) => g.bounds != null && text.substring(g.start, g.end).trim().isNotEmpty).length;
      return (inked, visible);
    }

    /// Width of [text] laid out directly in the host font.
    double hostWidth(String text) {
      final b = ui.ParagraphBuilder(ui.ParagraphStyle(textDirection: ui.TextDirection.ltr))
        ..pushStyle(ui.TextStyle(fontFamily: hostFallbackFamily, fontSize: 80, height: 1.2))
        ..addText(text);
      final p = b.build()..layout(const ui.ParagraphConstraints(width: 1e6));
      return p.longestLine;
    }

    for (final (name, text) in [('CJK', '漢字かな한글'), ('Arabic', 'مرحبابالعالم'), ('Hebrew', 'שלוםעולם'), ('Devanagari', 'नमस्ते')]) {
      test('$name renders with the fallback font', () async {
        final hasHost = await loadHostFallback();
        if (!hasHost) {
          markTestSkipped('no host Unicode font; covered on device by QA (system fallback)');
          return;
        }
        final (inked, visible) = await inkInsideGlyphs(text, [hostFallbackFamily]);
        expect(visible, greaterThan(0));
        expect(inked, visible, reason: 'every visible cluster has ink');
        // The glyphs came from the fallback font (Figtree has none of them): same advances as
        // the fallback font laid out on its own, and different from the tester's placeholder.
        final withFallback = TextLayoutEngine(fallbackFamilies: [hostFallbackFamily]).layoutSpec(spec(text, fontSizePx: 80));
        final without = TextLayoutEngine().layoutSpec(spec(text, fontSizePx: 80));
        expect(withFallback.textSize.width, hostWidth(text).ceilToDouble());
        expect(withFallback.textSize.width, isNot(without.textSize.width));
      });
    }

    test('emoji: one cluster per sequence, laid out and rasterized without errors', () async {
      final r = TextSpriteRasterizer();
      final s = spec('🎬👩‍💻🇯🇵', fontSizePx: 80);
      final sprite = await r.rasterize(request(s, reveal: true));
      expect(r.engine.layoutSpec(s).glyphCount, 3);
      expect(sprite.glyphs!.where((g) => g != 0xFFFF).every((g) => g < 3), isTrue);
      // Colour emoji glyphs come from the device's emoji font (Apple Color Emoji / Noto Color
      // Emoji); flutter_tester has none, so ink is verified on device (QA-03 render goldens).
    });
  });
}
