// OWNER: CORE-21
//
// IEEE 754 binary16 conversion (D-07), round-to-nearest-even with subnormals. Pure functions.

import 'dart:typed_data';

final ByteData _scratch = ByteData(4);

/// Encodes [value] as a half-precision bit pattern (round to nearest, ties to even).
///
/// Values beyond 65504 (after rounding) become infinity; NaN becomes 0x7E00.
int float16Encode(double value) {
  if (value.isNaN) return 0x7E00;
  _scratch.setFloat32(0, value);
  final f = _scratch.getUint32(0);
  final sign = (f >>> 16) & 0x8000;
  final exp = (f >>> 23) & 0xFF;
  final man = f & 0x7FFFFF;
  if (exp == 0xFF) return sign | 0x7C00; // infinity (NaN handled above)
  final e = exp - 127 + 15;
  if (e >= 0x1F) return sign | 0x7C00;
  if (e <= 0) {
    if (e < -10) return sign; // rounds to zero
    // Subnormal result: shift the implicit-one mantissa right.
    final m = man | 0x800000;
    final shift = 14 - e;
    var h = m >>> shift;
    final rem = m & ((1 << shift) - 1);
    final half = 1 << (shift - 1);
    if (rem > half || (rem == half && (h & 1) == 1)) h++;
    return sign | h; // a carry into the exponent field is the correct next value
  }
  var h = (e << 10) | (man >>> 13);
  final rem = man & 0x1FFF;
  if (rem > 0x1000 || (rem == 0x1000 && (h & 1) == 1)) h++;
  return sign | h; // carry may reach 0x7C00 (infinity), which is correct
}

/// Decodes a half-precision bit pattern (low 16 bits of [bits]).
double float16Decode(int bits) {
  final sign = (bits & 0x8000) != 0 ? -1.0 : 1.0;
  final exp = (bits >> 10) & 0x1F;
  final man = bits & 0x3FF;
  if (exp == 0) return sign * man * 5.960464477539063e-8; // 2^-24
  if (exp == 0x1F) return man == 0 ? sign * double.infinity : double.nan;
  return sign * (1 + man / 1024) * _pow2(exp - 15);
}

final Float64List _pow2Table = Float64List.fromList(<double>[
  for (var e = -15; e <= 15; e++) e >= 0 ? (1 << e).toDouble() : 1 / (1 << -e),
]);

double _pow2(int e) => _pow2Table[e + 15];

/// Largest finite half-precision value.
const double float16Max = 65504;
