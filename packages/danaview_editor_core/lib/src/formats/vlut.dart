// OWNER: CORE-21
//
// .vlut v1 writer/reader (D-07). Little-endian: 'VLUT', u16 version = 1, u16 N, then N³ RGB
// float16 triples, red fastest; the input domain spans [0,1]. No resampling. Pure functions.

import 'dart:typed_data';

import 'cube_lut.dart';
import 'float16.dart';

/// Current .vlut format version.
const int vlutVersion = 1;

/// Header size in bytes.
const int vlutHeaderBytes = 8;

/// A decoded .vlut: [size]³ RGB half-float triples.
final class VlutTable {
  /// Creates a table; [halfs] holds `size³ × 3` float16 bit patterns.
  const VlutTable(this.size, this.halfs);

  /// Edge length N.
  final int size;

  /// Float16 bit patterns, red fastest.
  final Uint16List halfs;

  /// Decodes every entry to a float.
  Float32List toFloats() {
    final out = Float32List(halfs.length);
    for (var i = 0; i < halfs.length; i++) {
      out[i] = float16Decode(halfs[i]);
    }
    return out;
  }

  /// The serialized file length for this table.
  int get byteLength => vlutHeaderBytes + halfs.length * 2;
}

/// Serializes [rgb] (`size³ × 3` floats, red fastest) as a .vlut v1 file.
///
/// Values are clamped to the finite float16 range. Throws [ArgumentError] on a bad size/length.
Uint8List writeVlut(int size, List<double> rgb) {
  if (size < 2 || size > maxLutSize) throw ArgumentError.value(size, 'size', 'must be 2..$maxLutSize');
  final count = size * size * size * 3;
  if (rgb.length != count) throw ArgumentError.value(rgb.length, 'rgb.length', 'expected $count');
  final out = Uint8List(vlutHeaderBytes + count * 2);
  final bd = ByteData.sublistView(out);
  out[0] = 0x56; // V
  out[1] = 0x4C; // L
  out[2] = 0x55; // U
  out[3] = 0x54; // T
  bd.setUint16(4, vlutVersion, Endian.little);
  bd.setUint16(6, size, Endian.little);
  var o = vlutHeaderBytes;
  for (var i = 0; i < count; i++, o += 2) {
    var v = rgb[i];
    if (v > float16Max) {
      v = float16Max;
    } else if (v < -float16Max) {
      v = -float16Max;
    }
    bd.setUint16(o, float16Encode(v), Endian.little);
  }
  return out;
}

/// Serializes a parsed .cube LUT as .vlut v1.
Uint8List writeVlutFromCube(CubeLut lut) => writeVlut(lut.size, lut.rgb);

/// Parses .vlut [bytes]. Throws [LutFormatException] when malformed.
VlutTable readVlut(Uint8List bytes) {
  if (bytes.length < vlutHeaderBytes || bytes[0] != 0x56 || bytes[1] != 0x4C || bytes[2] != 0x55 || bytes[3] != 0x54) {
    throw const LutFormatException('Not a .vlut file.');
  }
  final bd = ByteData.sublistView(bytes);
  final version = bd.getUint16(4, Endian.little);
  if (version != vlutVersion) throw LutFormatException('Unsupported .vlut version $version.');
  final n = bd.getUint16(6, Endian.little);
  if (n < 2 || n > maxLutSize) throw LutFormatException('Invalid .vlut size $n.');
  final count = n * n * n * 3;
  if (bytes.length != vlutHeaderBytes + count * 2) {
    throw const LutFormatException('The .vlut file is truncated or has trailing data.');
  }
  final halfs = Uint16List(count);
  var o = vlutHeaderBytes;
  for (var i = 0; i < count; i++, o += 2) {
    halfs[i] = bd.getUint16(o, Endian.little);
  }
  return VlutTable(n, halfs);
}
