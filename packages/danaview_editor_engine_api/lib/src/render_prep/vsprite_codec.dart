// OWNER: API-04
//
// `.vsprite` v1 codec (ARCH §10.3, D-06). Layout, little-endian:
//
//   offset  size  field
//   0       4     magic 'VSPR'
//   4       2     u16 version = 1
//   6       2     u16 flags (bit0 = hasReveal; other bits must be 0)
//   8       4     u32 width  (sprite px, ≥ 1)
//   12      4     u32 height (sprite px, ≥ 1)
//   16      4     f32 scale  (sprite px per layout px = project-canvas px, `SpriteFile.sscale`)
//   20      …     zlib stream (RFC 1950) of width·height·4 bytes: premultiplied RGBA8, sRGB-encoded,
//                 rows top to bottom
//   …       …     if hasReveal: a second zlib stream of width·height·2 bytes: u16 LE glyph order
//                 per pixel (grapheme cluster index; 0xFFFF = background)
//
// The streams are concatenated without length fields: decoders inflate the first stream to its
// end (zlib `avail_in`, `Inflater.getRemaining()`) and start the second right after it. The Dart
// decoder is strict: both Adler-32 trailers are verified and nothing may follow the last stream.
// Encoding and decoding run in `Isolate.run` ([VspriteCodec.encode], [VspriteCodec.decode]);
// the `*Sync` variants are for code already off the UI isolate. Compression is the package's
// pure-Dart zlib (zlib_stream.dart; the contract package has no `dart:io`).

import 'dart:isolate';
import 'dart:typed_data';

import 'package:meta/meta.dart';

import 'zlib_stream.dart';

/// A decoded `.vsprite`: premultiplied RGBA8 and an optional glyph-order map (ARCH §10.3, D-06).
@immutable
final class VspriteImage {
  /// Creates an image; [rgba] has `width·height·4` bytes and [glyphs] `width·height` entries.
  VspriteImage({required this.width, required this.height, required this.scale, required this.rgba, this.glyphs}) {
    VspriteCodec._check(width, height, scale);
    if (rgba.length != width * height * 4) {
      throw ArgumentError.value(rgba.length, 'rgba', 'expected ${width * height * 4} bytes');
    }
    final g = glyphs;
    if (g != null && g.length != width * height) {
      throw ArgumentError.value(g.length, 'glyphs', 'expected ${width * height} entries');
    }
  }

  /// Sprite width in px.
  final int width;

  /// Sprite height in px.
  final int height;

  /// Sprite px per layout px.
  final double scale;

  /// Premultiplied RGBA8, row-major, top row first.
  final Uint8List rgba;

  /// Glyph order per pixel (0xFFFF = background), or null.
  final Uint16List? glyphs;

  /// Whether the file carries a glyph-order map.
  bool get hasReveal => glyphs != null;
}

/// The fixed-size header of a `.vsprite` (ARCH §10.3).
@immutable
final class VspriteHeader {
  /// Creates a header.
  const VspriteHeader({required this.width, required this.height, required this.scale, required this.hasReveal});

  /// Sprite width in px.
  final int width;

  /// Sprite height in px.
  final int height;

  /// Sprite px per layout px (f32 precision).
  final double scale;

  /// Whether a glyph-order map follows the RGBA stream.
  final bool hasReveal;
}

/// Encodes and decodes `.vsprite` v1 files (file header; ARCH §10.3, API-04).
abstract final class VspriteCodec {
  /// `'VSPR'`.
  static const List<int> magic = [0x56, 0x53, 0x50, 0x52];

  /// Format version.
  static const int version = 1;

  /// Header size in bytes.
  static const int headerBytes = 20;

  /// Flag bit: a glyph-order map follows.
  static const int flagReveal = 1;

  /// Glyph id of background pixels.
  static const int backgroundGlyph = 0xFFFF;

  /// Largest side accepted (Metal's texture limit).
  static const int maxSide = 16384;

  static void _check(int w, int h, double scale) {
    if (w < 1 || h < 1 || w > maxSide || h > maxSide) throw ArgumentError('vsprite: bad size ${w}x$h');
    if (!scale.isFinite || scale <= 0) throw ArgumentError.value(scale, 'scale', 'must be finite and > 0');
  }

  /// Encodes [image] in an isolate.
  static Future<Uint8List> encode(VspriteImage image) => Isolate.run(() => encodeSync(image), debugName: 'danaview.vsprite.encode');

  /// Encodes [image] on the calling isolate.
  static Uint8List encodeSync(VspriteImage image) {
    final header = ByteData(headerBytes);
    for (var i = 0; i < 4; i++) {
      header.setUint8(i, magic[i]);
    }
    header
      ..setUint16(4, version, Endian.little)
      ..setUint16(6, image.hasReveal ? flagReveal : 0, Endian.little)
      ..setUint32(8, image.width, Endian.little)
      ..setUint32(12, image.height, Endian.little)
      ..setFloat32(16, image.scale, Endian.little);
    final rgbaZ = deflateZlib(image.rgba, stride: image.width * 4, pixelBytes: 4);
    final g = image.glyphs;
    Uint8List? glyphZ;
    if (g != null) {
      final le = ByteData(g.length * 2);
      for (var i = 0; i < g.length; i++) {
        le.setUint16(i * 2, g[i], Endian.little);
      }
      glyphZ = deflateZlib(le.buffer.asUint8List(), stride: image.width * 2, pixelBytes: 2);
    }
    final out = BytesBuilder(copy: false)
      ..add(header.buffer.asUint8List())
      ..add(rgbaZ);
    if (glyphZ != null) out.add(glyphZ);
    return out.toBytes();
  }

  /// Reads the header of [bytes] ([FormatException] when it is not a valid v1 header).
  static VspriteHeader readHeader(Uint8List bytes) {
    if (bytes.length < headerBytes) throw const FormatException('vsprite: truncated header');
    for (var i = 0; i < 4; i++) {
      if (bytes[i] != magic[i]) throw const FormatException("vsprite: missing 'VSPR' magic");
    }
    final d = ByteData.sublistView(bytes, 0, headerBytes);
    final v = d.getUint16(4, Endian.little);
    if (v != version) throw FormatException('vsprite: unsupported version $v');
    final flags = d.getUint16(6, Endian.little);
    if (flags & ~flagReveal != 0) throw FormatException('vsprite: unknown flags $flags');
    final w = d.getUint32(8, Endian.little);
    final h = d.getUint32(12, Endian.little);
    final scale = d.getFloat32(16, Endian.little);
    try {
      _check(w, h, scale);
    } on ArgumentError catch (e) {
      throw FormatException('vsprite: ${e.message}');
    }
    return VspriteHeader(width: w, height: h, scale: scale, hasReveal: flags & flagReveal != 0);
  }

  /// Decodes [bytes] in an isolate.
  static Future<VspriteImage> decode(Uint8List bytes) => Isolate.run(() => decodeSync(bytes), debugName: 'danaview.vsprite.decode');

  /// Decodes [bytes] on the calling isolate ([FormatException] when malformed).
  static VspriteImage decodeSync(Uint8List bytes) {
    final h = readHeader(bytes);
    final n = h.width * h.height;
    final (rgba, end) = inflateZlibStream(bytes, headerBytes, n * 4);
    var tail = end;
    Uint16List? glyphs;
    if (h.hasReveal) {
      final (raw, end2) = inflateZlibStream(bytes, end, n * 2);
      tail = end2;
      final bd = ByteData.sublistView(raw);
      glyphs = Uint16List(n);
      for (var i = 0; i < n; i++) {
        glyphs[i] = bd.getUint16(i * 2, Endian.little);
      }
    }
    if (tail != bytes.length) throw FormatException('vsprite: ${bytes.length - tail} trailing bytes');
    return VspriteImage(width: h.width, height: h.height, scale: h.scale, rgba: rgba, glyphs: glyphs);
  }
}
