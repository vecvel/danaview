// OWNER: API-04
//
// Text sprite rasterizer (ARCH §10.3, D-05, D-06). Renders a `SpriteRequest` (a TextLayoutSpec
// laid out by TextLayoutEngine) to premultiplied, sRGB-encoded RGBA8 at the request's raster
// scale, plus the u16 glyph-order map for typewriter reveals.
//
// Units and geometry (normative with CORE-31 sprite_requests.dart):
// * `request.scale` and the result's [RasterizedSprite.scale] are sprite px per layout px
//   (project-canvas px of the spec);
// * the sprite covers the layout's raster extent (block + symmetric margin) and is centred on the
//   block: sprite centre = block centre, so a layer of `base = (sw, sh) / sscale` placed at the
//   item position matches the preview overlay;
// * the scale is lowered so neither side exceeds `min(maxTextureSize, 2 × output long side)`
//   (the request's canvas is the output canvas); the result reports the scale actually used
//   (f32-rounded, as stored in the `.vsprite` header).
//
// Threading: [TextSpriteRasterizer.prepare] (layout + picture recording) runs on the UI isolate
// and is what the pre-pass slices; [PreparedSprite.render] rasterizes on the raster thread
// (`Picture.toImage`); the glyph map ([glyphMapOf]) is pure Dart and runs in an isolate.

import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:danaview_editor_core/plan.dart';

import 'text_layout_engine.dart';
import 'vsprite_codec.dart';

/// A rasterized sprite (ARCH §10.3, D-06).
final class RasterizedSprite {
  /// Creates a sprite.
  RasterizedSprite({required this.width, required this.height, required this.scale, required this.rgba, this.glyphs});

  /// Width in px.
  final int width;

  /// Height in px.
  final int height;

  /// Sprite px per layout px (f32-rounded).
  final double scale;

  /// Premultiplied RGBA8, sRGB-encoded.
  final Uint8List rgba;

  /// Glyph order per pixel (0xFFFF = background), when the request needs a reveal.
  final Uint16List? glyphs;

  /// As a `.vsprite` image.
  VspriteImage toVsprite() => VspriteImage(width: width, height: height, scale: scale, rgba: rgba, glyphs: glyphs);
}

/// A sprite laid out and recorded on the UI isolate, waiting to be rasterized (ARCH §10.3, §14.1).
final class PreparedSprite {
  PreparedSprite._(this.request, this.layout, this.width, this.height, this.scale, this._picture, this.strips);

  /// The request.
  final SpriteRequest request;

  /// The layout.
  final TextBlockLayout layout;

  /// Sprite width in px.
  final int width;

  /// Sprite height in px.
  final int height;

  /// Sprite px per layout px (f32-rounded).
  final double scale;

  final ui.Picture _picture;

  /// Reveal strips in sprite px, 5 values each: glyph, left, top, right, bottom (may be ±∞);
  /// empty unless `request.reveal`.
  final Float64List strips;

  bool _rendered = false;

  /// Rasterizes the picture to premultiplied RGBA (no glyph map; see [glyphMapOf]).
  Future<Uint8List> renderRgba() async {
    if (_rendered) throw StateError('PreparedSprite.renderRgba called twice');
    _rendered = true;
    try {
      final image = await _picture.toImage(width, height);
      try {
        final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
        if (data == null) throw StateError('toByteData returned null');
        return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
      } finally {
        image.dispose();
      }
    } finally {
      _picture.dispose();
    }
  }

  /// Releases the picture without rendering.
  void dispose() {
    if (_rendered) return;
    _rendered = true;
    _picture.dispose();
  }
}

/// Renders text sprites (file header; ARCH §10.3, API-04).
class TextSpriteRasterizer {
  /// Creates a rasterizer laying out with [engine] (default: a Figtree-only engine).
  TextSpriteRasterizer({TextLayoutEngine? engine}) : engine = engine ?? TextLayoutEngine();

  /// The layout engine (shared with the preview overlay).
  final TextLayoutEngine engine;

  /// The raster scale of a raster extent of [extent] layout px wanted at [wanted]: lowered so the
  /// longer side stays within `min(maxTextureSize, 2 × outputLongSide)`.
  static double clampScale(double wanted, ui.Size extent, {required int maxTextureSize, required int outputLongSide}) {
    final limit = math.min(maxTextureSize, 2 * outputLongSide).toDouble();
    final side = math.max(extent.width, extent.height);
    if (!(side > 0) || side * wanted <= limit) return wanted;
    return limit / side;
  }

  static double _f32(double v) => (Float32List(1)..[0] = v)[0];

  /// Lays out [request] and records its picture (UI isolate; the part the pre-pass slices).
  PreparedSprite prepare(SpriteRequest request, {int maxTextureSize = defaultMaxTextureSize}) {
    if (!(request.scale > 0) || !request.scale.isFinite) throw ArgumentError.value(request.scale, 'request.scale');
    final layout = engine.layout(request.layoutSpec);
    final extent = layout.rasterSize;
    final outputLong = math.max(request.canvasWidth, request.canvasHeight);
    final limit = math.min(maxTextureSize, 2 * outputLong);
    var scale = clampScale(request.scale, extent, maxTextureSize: maxTextureSize, outputLongSide: outputLong);
    scale = _f32(scale);
    // f32 rounding may round up: keep the sides within the limit.
    while (math.max(extent.width, extent.height) * scale > limit && scale > 0) {
      scale = _f32(scale * (1 - 1e-6));
    }
    final w = math.max(1, math.min(limit, (extent.width * scale).ceil()));
    final h = math.max(1, math.min(limit, (extent.height * scale).ceil()));
    final block = layout.blockSize;

    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder, ui.Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()));
    canvas
      ..translate(w / 2, h / 2)
      ..scale(scale);
    layout.paint(canvas, ui.Offset(-block.width / 2, -block.height / 2));
    final picture = recorder.endRecording();

    // Strips only for typewriter sprites (glyph boxes cost one native query per cluster).
    final revealStrips = request.reveal ? layout.revealStrips : const <RevealStrip>[];
    final strips = Float64List(revealStrips.length * 5);
    var i = 0;
    for (final s in revealStrips) {
      strips[i++] = s.glyph.toDouble();
      strips[i++] = (s.rect.left - block.width / 2) * scale + w / 2;
      strips[i++] = (s.rect.top - block.height / 2) * scale + h / 2;
      strips[i++] = (s.rect.right - block.width / 2) * scale + w / 2;
      strips[i++] = (s.rect.bottom - block.height / 2) * scale + h / 2;
    }
    return PreparedSprite._(request, layout, w, h, scale, picture, strips);
  }

  /// Rasterizes [request]: premultiplied RGBA, plus the glyph map (computed in an isolate) when
  /// `request.reveal`.
  Future<RasterizedSprite> rasterize(SpriteRequest request, {int maxTextureSize = defaultMaxTextureSize}) async {
    final p = prepare(request, maxTextureSize: maxTextureSize);
    final rgba = await p.renderRgba();
    Uint16List? glyphs;
    if (request.reveal) {
      final w = p.width;
      final h = p.height;
      final strips = p.strips;
      glyphs = await Isolate.run(() => glyphMapOf(rgba, w, h, strips), debugName: 'danaview.sprite.glyphs');
    }
    return RasterizedSprite(width: p.width, height: p.height, scale: p.scale, rgba: rgba, glyphs: glyphs);
  }
}

/// The glyph-order map of a sprite (ARCH §10.3): 0xFFFF for transparent pixels; otherwise the
/// glyph of the reveal strip containing the pixel centre ([strips]: glyph, l, t, r, b in sprite
/// px). Painted pixels outside every strip (text without visible clusters) get glyph 0.
Uint16List glyphMapOf(Uint8List rgba, int width, int height, Float64List strips) {
  final n = width * height;
  final map = Uint16List(n)..fillRange(0, n, VspriteCodec.backgroundGlyph);
  // Strips first (they partition the plane; overlaps keep the earlier glyph).
  final owner = Uint16List(n)..fillRange(0, n, VspriteCodec.backgroundGlyph);
  for (var s = 0; s + 4 < strips.length; s += 5) {
    // 0xFFFF is the background id; clusters beyond 65,534 share the last id.
    final g = math.min(strips[s].toInt(), VspriteCodec.backgroundGlyph - 1);
    final l = strips[s + 1].clamp(-1.0, width + 1.0);
    final t = strips[s + 2].clamp(-1.0, height + 1.0);
    final r = strips[s + 3].clamp(-1.0, width + 1.0);
    final b = strips[s + 4].clamp(-1.0, height + 1.0);
    // Pixel x has its centre at x + 0.5: inside iff l <= x + 0.5 < r.
    final x0 = math.max(0, (l - 0.5).ceil());
    final x1 = math.min(width, (r - 0.5).ceil());
    final y0 = math.max(0, (t - 0.5).ceil());
    final y1 = math.min(height, (b - 0.5).ceil());
    for (var y = y0; y < y1; y++) {
      final row = y * width;
      for (var x = x0; x < x1; x++) {
        final i = row + x;
        if (owner[i] > g) owner[i] = g;
      }
    }
  }
  for (var i = 0; i < n; i++) {
    if (rgba[i * 4 + 3] == 0) continue;
    final o = owner[i];
    map[i] = o == VspriteCodec.backgroundGlyph ? 0 : o;
  }
  return map;
}
