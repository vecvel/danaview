// OWNER: API-03
//
// A small float RGBA image for the reference pipeline (ARCH §11.6): premultiplied doubles,
// row-major, texel (x, y) covering [x, x + 1) × [y, y + 1) with its centre at (x + 0.5, y + 0.5),
// bilinear sampling with clamp-to-edge (the GPU convention).

import 'dart:typed_data';

import 'render_math.dart';

/// A premultiplied RGBA raster of doubles used by the render math and the Dart reference renderer
/// (ARCH §11.6, API-03). 8-bit conversions use `round(v·255)` without colour management.
final class RenderRaster {
  /// A transparent raster of [width] × [height] (both ≥ 1).
  RenderRaster(this.width, this.height)
      : assert(width > 0 && height > 0),
        data = Float64List(width * height * 4);

  /// A raster filled with the premultiplied colour [premultiplied].
  factory RenderRaster.filled(int width, int height, RenderRgba premultiplied) {
    final r = RenderRaster(width, height);
    final d = r.data;
    for (var i = 0; i < d.length; i += 4) {
      d[i] = premultiplied.r;
      d[i + 1] = premultiplied.g;
      d[i + 2] = premultiplied.b;
      d[i + 3] = premultiplied.a;
    }
    return r;
  }

  /// A raster of straight-alpha RGBA8 bytes (PNG convention), premultiplied on load.
  factory RenderRaster.fromStraightRgba8(Uint8List rgba, int width, int height) {
    final r = RenderRaster(width, height);
    final d = r.data;
    for (var i = 0; i < width * height * 4; i += 4) {
      final a = rgba[i + 3] / 255;
      d[i] = rgba[i] / 255 * a;
      d[i + 1] = rgba[i + 1] / 255 * a;
      d[i + 2] = rgba[i + 2] / 255 * a;
      d[i + 3] = a;
    }
    return r;
  }

  /// A raster of premultiplied RGBA8 bytes (`.vsprite` convention).
  factory RenderRaster.fromPremultipliedRgba8(Uint8List rgba, int width, int height) {
    final r = RenderRaster(width, height);
    final d = r.data;
    for (var i = 0; i < width * height * 4; i++) {
      d[i] = rgba[i] / 255;
    }
    return r;
  }

  /// Width in px.
  final int width;

  /// Height in px.
  final int height;

  /// Premultiplied RGBA, 4 doubles per texel, row-major.
  final Float64List data;

  /// The premultiplied texel at ([x], [y]).
  RenderRgba pixel(int x, int y) {
    final o = (y * width + x) * 4;
    return RenderRgba(data[o], data[o + 1], data[o + 2], data[o + 3]);
  }

  /// Sets the premultiplied texel at ([x], [y]).
  void setPixel(int x, int y, RenderRgba premultiplied) {
    final o = (y * width + x) * 4;
    data[o] = premultiplied.r;
    data[o + 1] = premultiplied.g;
    data[o + 2] = premultiplied.b;
    data[o + 3] = premultiplied.a;
  }

  /// Bilinear sample at continuous texel coordinates ([x], [y]) (texel centres at `i + 0.5`),
  /// clamp-to-edge; writes the premultiplied result into [out] (length ≥ 4).
  void sampleInto(double x, double y, Float64List out) {
    final fx = x - 0.5;
    final fy = y - 0.5;
    var x0 = fx.floor();
    var y0 = fy.floor();
    final tx = fx - x0;
    final ty = fy - y0;
    var x1 = x0 + 1;
    var y1 = y0 + 1;
    final mw = width - 1;
    final mh = height - 1;
    if (x0 < 0) x0 = 0;
    if (x0 > mw) x0 = mw;
    if (x1 < 0) x1 = 0;
    if (x1 > mw) x1 = mw;
    if (y0 < 0) y0 = 0;
    if (y0 > mh) y0 = mh;
    if (y1 < 0) y1 = 0;
    if (y1 > mh) y1 = mh;
    final o00 = (y0 * width + x0) * 4;
    final o10 = (y0 * width + x1) * 4;
    final o01 = (y1 * width + x0) * 4;
    final o11 = (y1 * width + x1) * 4;
    final w00 = (1 - tx) * (1 - ty);
    final w10 = tx * (1 - ty);
    final w01 = (1 - tx) * ty;
    final w11 = tx * ty;
    for (var c = 0; c < 4; c++) {
      out[c] = data[o00 + c] * w00 + data[o10 + c] * w10 + data[o01 + c] * w01 + data[o11 + c] * w11;
    }
  }

  /// [sampleInto] as a colour.
  RenderRgba sample(double x, double y) {
    final o = Float64List(4);
    sampleInto(x, y, o);
    return RenderRgba(o[0], o[1], o[2], o[3]);
  }

  /// A deep copy.
  RenderRaster copy() {
    final r = RenderRaster(width, height);
    r.data.setAll(0, data);
    return r;
  }

  /// Straight-alpha RGBA8 (un-premultiplied, `round(v·255)`).
  Uint8List toStraightRgba8() {
    final out = Uint8List(width * height * 4);
    for (var i = 0; i < out.length; i += 4) {
      final a = data[i + 3];
      if (a > 0) {
        out[i] = RenderMath.toByte(data[i] / a);
        out[i + 1] = RenderMath.toByte(data[i + 1] / a);
        out[i + 2] = RenderMath.toByte(data[i + 2] / a);
      }
      out[i + 3] = RenderMath.toByte(a);
    }
    return out;
  }

  /// Premultiplied RGBA8 (`round(v·255)` per channel).
  Uint8List toPremultipliedRgba8() {
    final out = Uint8List(width * height * 4);
    for (var i = 0; i < out.length; i++) {
      out[i] = RenderMath.toByte(data[i]);
    }
    return out;
  }
}
