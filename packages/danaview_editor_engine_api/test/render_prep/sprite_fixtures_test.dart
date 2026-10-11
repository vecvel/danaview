// OWNER: API-04
//
// Generator of the shared `.vsprite` fixtures (test_fixtures/sprites/), decoded by this
// package's codec test and by the native suites (IOS-09, AND-09). Runs only with
//   DANAVIEW_REGEN_SPRITE_FIXTURES=1 flutter test test/render_prep/sprite_fixtures_test.dart
// Synthetic fixtures are deterministic; the text fixtures are Figtree rasterized by this
// package (their pixels may differ by a few levels across Skia versions, which is why the
// manifest pins the files, not the renderer).

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_editor_core/eval.dart';
import 'package:danaview_editor_engine_api/danaview_editor_engine_api.dart';

import 'support.dart';

/// Deterministic premultiplied pattern (no Random: reproducible in any language).
Uint8List syntheticRgba(int w, int h) {
  final out = Uint8List(w * h * 4);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final i = (y * w + x) * 4;
      final a = (x * 37 + y * 91) % 256;
      out[i] = (a * x) ~/ (w > 1 ? w - 1 : 1);
      out[i + 1] = (a * y) ~/ (h > 1 ? h - 1 : 1);
      out[i + 2] = a ~/ 2;
      out[i + 3] = a;
    }
  }
  return out;
}

Uint16List syntheticGlyphs(int w, int h, Uint8List rgba) =>
    Uint16List.fromList([for (var i = 0; i < w * h; i++) rgba[i * 4 + 3] == 0 ? 0xFFFF : (i % w) ~/ 4]);

Map<String, Object?> describe(String file, VspriteImage img, String note) {
  final samples = <Map<String, Object?>>[];
  void sample(int x, int y) {
    final i = (y * img.width + x) * 4;
    samples.add({
      'x': x,
      'y': y,
      'rgba': img.rgba.sublist(i, i + 4),
      if (img.glyphs != null) 'glyph': img.glyphs![y * img.width + x],
    });
  }

  sample(0, 0);
  sample(img.width ~/ 2, img.height ~/ 2);
  sample(img.width - 1, img.height - 1);
  // The first opaque-ish pixel in reading order.
  for (var i = 0; i < img.width * img.height; i++) {
    if (img.rgba[i * 4 + 3] > 200) {
      sample(i % img.width, i ~/ img.width);
      break;
    }
  }
  int? glyphAdler;
  final g = img.glyphs;
  if (g != null) {
    final le = ByteData(g.length * 2);
    for (var i = 0; i < g.length; i++) {
      le.setUint16(i * 2, g[i], Endian.little);
    }
    glyphAdler = adler32(le.buffer.asUint8List());
  }
  return {
    'file': file,
    'note': note,
    'width': img.width,
    'height': img.height,
    'scale': img.scale,
    'reveal': img.hasReveal,
    'rgbaAdler32': adler32(img.rgba),
    if (glyphAdler != null) 'glyphsAdler32': glyphAdler,
    'samples': samples,
  };
}

void main() {
  final regen = Platform.environment['DANAVIEW_REGEN_SPRITE_FIXTURES'] == '1';

  test('regenerate test_fixtures/sprites', () async {
    await loadFigtree();
    final dir = Directory('test_fixtures/sprites')..createSync(recursive: true);
    final entries = <Map<String, Object?>>[];
    void write(String name, VspriteImage img, String note) {
      File('${dir.path}/$name').writeAsBytesSync(VspriteCodec.encodeSync(img));
      entries.add(describe(name, img, note));
    }

    final p1 = syntheticRgba(8, 4);
    write('synthetic_plain_8x4.vsprite', VspriteImage(width: 8, height: 4, scale: 1, rgba: p1),
        'rgba[x,y] = (a·x/(w-1), a·y/(h-1), a/2, a) with a = (37x + 91y) mod 256');
    final p2 = syntheticRgba(16, 8);
    write('synthetic_reveal_16x8.vsprite',
        VspriteImage(width: 16, height: 8, scale: 0.5, rgba: p2, glyphs: syntheticGlyphs(16, 8, p2)),
        'same pattern; glyph = x div 4, 0xFFFF where alpha = 0');

    final r = TextSpriteRasterizer();
    final plain = await r.rasterize(request(
        spec('Danaview',
            fontSizePx: 72,
            box: const TextBoxSpec(color: 0xFF1E2A44, opacity: 0.85, paddingPx: 16, cornerRadiusPx: 12),
            stroke: const TextStrokeSpec(color: 0xFF000000, widthPx: 3),
            shadow: const TextShadowSpec(color: 0xFF000000, opacity: 0.5, blurPx: 6, offset: Offset2(0, 6))),
        scale: 1));
    write('text_box_stroke_shadow.vsprite', plain.toVsprite(), 'Figtree 72 px "Danaview", box, outline, shadow; scale 1');
    final typed = await r.rasterize(request(spec('Type it 👍', fontSizePx: 56), scale: 1.5, reveal: true));
    write('text_typewriter_reveal.vsprite', typed.toVsprite(), 'Figtree 56 px "Type it 👍" at scale 1.5 with a glyph map (9 clusters; the emoji is the flutter_tester placeholder glyph)');

    File('${dir.path}/sprites.json').writeAsStringSync('${const JsonEncoder.withIndent('  ').convert({
          'format': 'vsprite',
          'version': 1,
          'spec': 'ARCH §10.3; header LE: VSPR, u16 version, u16 flags (bit0 hasReveal), u32 w, u32 h, f32 scale; '
              'zlib(RGBA8 premultiplied) [+ zlib(u16 LE glyph order)]. Checksums are Adler-32 of the inflated data.',
          'sprites': entries,
        })}\n');
  }, skip: regen ? false : 'set DANAVIEW_REGEN_SPRITE_FIXTURES=1 to regenerate the shared fixtures');
}
