// OWNER: CORE-20
//
// Subtitle byte decoding (ARCH §10.1): BOM -> NUL pattern (UTF-16) -> strict UTF-8 ->
// Windows-1252 -> Latin-1. Pure functions; callers run them in Isolate.run.

import 'dart:convert';
import 'dart:typed_data';

/// Which text encoding a subtitle file was decoded with.
enum TextEncoding {
  /// UTF-8 (with or without BOM).
  utf8,

  /// UTF-16 little endian (BOM or detected by the NUL pattern).
  utf16le,

  /// UTF-16 big endian (BOM or detected by the NUL pattern).
  utf16be,

  /// Windows-1252 (strict UTF-8 failed, no undefined bytes).
  windows1252,

  /// ISO-8859-1 (last resort; every byte maps to U+0000..U+00FF).
  latin1,
}

/// Result of [decodeText].
final class DecodedText {
  /// Creates a decoded text.
  const DecodedText(this.text, this.encoding, this.hadBom);

  /// Decoded text without any BOM.
  final String text;

  /// The encoding that was used.
  final TextEncoding encoding;

  /// Whether the input started with a byte order mark.
  final bool hadBom;
}

/// Windows-1252 code points for bytes 0x80..0x9F; 0 marks an undefined byte.
const List<int> _cp1252High = <int>[
  0x20AC, 0, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021, //
  0x02C6, 0x2030, 0x0160, 0x2039, 0x0152, 0, 0x017D, 0,
  0, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014,
  0x02DC, 0x2122, 0x0161, 0x203A, 0x0153, 0, 0x017E, 0x0178,
];

/// Decodes subtitle [bytes] following the ARCH §10.1 order. Never throws.
DecodedText decodeText(Uint8List bytes) {
  final n = bytes.length;
  if (n >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF) {
    return DecodedText(_utf8(bytes, 3) ?? _latin1(bytes, 3), TextEncoding.utf8, true);
  }
  if (n >= 2 && bytes[0] == 0xFF && bytes[1] == 0xFE) {
    return DecodedText(_utf16(bytes, 2, true), TextEncoding.utf16le, true);
  }
  if (n >= 2 && bytes[0] == 0xFE && bytes[1] == 0xFF) {
    return DecodedText(_utf16(bytes, 2, false), TextEncoding.utf16be, true);
  }
  final guess = _nulPattern(bytes);
  if (guess != null) {
    return DecodedText(_utf16(bytes, 0, guess), guess ? TextEncoding.utf16le : TextEncoding.utf16be, false);
  }
  final u = _utf8(bytes, 0);
  if (u != null) return DecodedText(u, TextEncoding.utf8, false);
  final w = _windows1252(bytes);
  if (w != null) return DecodedText(w, TextEncoding.windows1252, false);
  return DecodedText(_latin1(bytes, 0), TextEncoding.latin1, false);
}

/// true = LE, false = BE, null = not UTF-16.
bool? _nulPattern(Uint8List b) {
  final n = b.length < 4096 ? b.length : 4096;
  if (n < 2) return null;
  var even = 0, odd = 0;
  for (var i = 0; i < n; i++) {
    if (b[i] == 0) {
      if (i.isEven) {
        even++;
      } else {
        odd++;
      }
    }
  }
  if (odd == 0 && even == 0) return null;
  if (odd > even * 3 && odd * 16 >= n) return true;
  if (even > odd * 3 && even * 16 >= n) return false;
  return null;
}

String? _utf8(Uint8List b, int from) {
  try {
    return const Utf8Decoder(allowMalformed: false).convert(b, from);
  } on FormatException {
    return null;
  }
}

String _utf16(Uint8List b, int from, bool le) {
  final count = (b.length - from) >> 1;
  final units = Uint16List(count);
  var p = from;
  for (var i = 0; i < count; i++, p += 2) {
    units[i] = le ? (b[p] | (b[p + 1] << 8)) : ((b[p] << 8) | b[p + 1]);
  }
  return String.fromCharCodes(units);
}

String? _windows1252(Uint8List b) {
  final out = Uint16List(b.length);
  for (var i = 0; i < b.length; i++) {
    final v = b[i];
    if (v >= 0x80 && v < 0xA0) {
      final c = _cp1252High[v - 0x80];
      if (c == 0) return null;
      out[i] = c;
    } else {
      out[i] = v;
    }
  }
  return String.fromCharCodes(out);
}

String _latin1(Uint8List b, int from) => String.fromCharCodes(b, from);
