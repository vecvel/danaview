// OWNER: API-03
//
// The N³ colour table of a `.vlut` (ARCH §10.2, D-07) with the trilinear lookup of ARCH §11.6
// "LUT". Engines upload the same table as a tiled 2D texture (N tiles of N×N in a ⌈√N⌉ grid) and
// interpolate bilinearly inside a tile and linearly between the two blue slices, which is the same
// trilinear interpolation.

import 'dart:typed_data';

import 'package:danaview_editor_core/formats.dart' show VlutTable;

/// A decoded LUT: [size]³ RGB entries, red fastest, input domain [0, 1] (ARCH §10.2, §11.6, D-07).
final class RenderLut {
  /// Creates a table from `size³ × 3` floats, red fastest.
  RenderLut(this.size, Float64List rgb)
      : assert(size >= 2),
        assert(rgb.length == size * size * size * 3),
        rgb = rgb;

  /// The table of a decoded `.vlut` (float16 values widened exactly).
  factory RenderLut.fromVlut(VlutTable table) {
    final f = table.toFloats();
    return RenderLut(table.size, Float64List.fromList([for (final v in f) v.toDouble()]));
  }

  /// The identity table of edge [size].
  factory RenderLut.identity(int size) => RenderLut.generate(size, (r, g, b) => (r, g, b));

  /// The table whose entry at grid point `(i, j, k)/(size − 1)` is `f(r, g, b)`.
  factory RenderLut.generate(int size, (double, double, double) Function(double r, double g, double b) f) {
    final out = Float64List(size * size * size * 3);
    var o = 0;
    for (var b = 0; b < size; b++) {
      for (var g = 0; g < size; g++) {
        for (var r = 0; r < size; r++) {
          final (x, y, z) = f(r / (size - 1), g / (size - 1), b / (size - 1));
          out[o++] = x;
          out[o++] = y;
          out[o++] = z;
        }
      }
    }
    return RenderLut(size, out);
  }

  /// Edge length N.
  final int size;

  /// `size³ × 3` values, red fastest (`index = ((b·N + g)·N + r)·3`).
  final Float64List rgb;

  /// The entry at grid indices ([r], [g], [b]).
  (double, double, double) entry(int r, int g, int b) {
    final o = ((b * size + g) * size + r) * 3;
    return (rgb[o], rgb[o + 1], rgb[o + 2]);
  }

  /// Trilinear lookup of `(r, g, b)` (each clamped to [0, 1]).
  (double, double, double) lookup(double r, double g, double b) {
    final n1 = size - 1;
    double c(double v) => v < 0 ? 0.0 : (v > 1 ? 1.0 : v);
    final x = c(r) * n1;
    final y = c(g) * n1;
    final z = c(b) * n1;
    var x0 = x.floor();
    var y0 = y.floor();
    var z0 = z.floor();
    if (x0 > n1 - 1) x0 = n1 - 1;
    if (y0 > n1 - 1) y0 = n1 - 1;
    if (z0 > n1 - 1) z0 = n1 - 1;
    final fx = x - x0;
    final fy = y - y0;
    final fz = z - z0;
    final out = <double>[0, 0, 0];
    for (var ch = 0; ch < 3; ch++) {
      double at(int i, int j, int k) => rgb[(((z0 + k) * size + (y0 + j)) * size + (x0 + i)) * 3 + ch];
      final c00 = at(0, 0, 0) * (1 - fx) + at(1, 0, 0) * fx;
      final c10 = at(0, 1, 0) * (1 - fx) + at(1, 1, 0) * fx;
      final c01 = at(0, 0, 1) * (1 - fx) + at(1, 0, 1) * fx;
      final c11 = at(0, 1, 1) * (1 - fx) + at(1, 1, 1) * fx;
      final c0 = c00 * (1 - fy) + c10 * fy;
      final c1 = c01 * (1 - fy) + c11 * fy;
      out[ch] = c0 * (1 - fz) + c1 * fz;
    }
    return (out[0], out[1], out[2]);
  }
}
