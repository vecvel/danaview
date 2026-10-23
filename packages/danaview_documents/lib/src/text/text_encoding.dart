// OWNER: HOM-23
//
// Text encodings of the in-app text viewer (HOM plan §8.4, V2-120/V2-121): UTF-8, UTF-16 by
// byte-order mark, and a Latin-1 fallback the user can change from the viewer's menu. Detection
// reads bytes only; decoding works on byte ranges so the viewer decodes just the rows it shows.
// Nothing here logs content (rule 30).

import 'dart:convert';
import 'dart:typed_data';

/// An encoding the text viewer can decode.
enum TextEncodingKind {
  /// UTF-8 (with or without a byte-order mark).
  utf8('UTF-8', 'utf-8', 1),

  /// UTF-16, little-endian.
  utf16le('UTF-16 LE', 'utf-16le', 2),

  /// UTF-16, big-endian.
  utf16be('UTF-16 BE', 'utf-16be', 2),

  /// ISO 8859-1, the fallback for bytes that are not valid UTF-8.
  latin1('Latin-1', 'iso-8859-1', 1);

  const TextEncodingKind(this.label, this.code, this.unitBytes);

  /// The name shown in the change-encoding menu.
  final String label;

  /// The IANA-style name (stored as `DocumentItem.textEncoding`).
  final String code;

  /// Bytes per code unit (1 or 2).
  final int unitBytes;

  /// The encoding stored as [code], or null.
  static TextEncodingKind? tryDecode(String? code) {
    for (final k in values) {
      if (k.code == code) return k;
    }
    return null;
  }
}

/// The result of [detectEncoding].
final class EncodingGuess {
  /// A guess.
  const EncodingGuess(this.kind, this.bomLength);

  /// The detected encoding.
  final TextEncodingKind kind;

  /// Bytes of byte-order mark at the start (0, 2 or 3).
  final int bomLength;

  @override
  bool operator ==(Object other) => other is EncodingGuess && other.kind == kind && other.bomLength == bomLength;

  @override
  int get hashCode => Object.hash(kind, bomLength);

  @override
  String toString() => 'EncodingGuess(${kind.name}, bom: $bomLength)';
}

/// The byte-order mark length of [kind] at the start of [bytes] (0 when there is none).
int bomLengthFor(Uint8List bytes, TextEncodingKind kind) => switch (kind) {
      TextEncodingKind.utf8 => bytes.length >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF ? 3 : 0,
      TextEncodingKind.utf16le => bytes.length >= 2 && bytes[0] == 0xFF && bytes[1] == 0xFE ? 2 : 0,
      TextEncodingKind.utf16be => bytes.length >= 2 && bytes[0] == 0xFE && bytes[1] == 0xFF ? 2 : 0,
      TextEncodingKind.latin1 => 0,
    };

/// Detects the encoding of [bytes]: a UTF-8 or UTF-16 byte-order mark decides; otherwise valid
/// UTF-8 is UTF-8 and anything else is Latin-1. With [truncated], an incomplete UTF-8 sequence in
/// the last three bytes (a cut at the size cap) still counts as valid.
EncodingGuess detectEncoding(Uint8List bytes, {bool truncated = false}) {
  for (final kind in const [TextEncodingKind.utf8, TextEncodingKind.utf16le, TextEncodingKind.utf16be]) {
    final bom = bomLengthFor(bytes, kind);
    if (bom > 0) return EncodingGuess(kind, bom);
  }
  return EncodingGuess(isValidUtf8(bytes, allowTruncatedEnd: truncated) ? TextEncodingKind.utf8 : TextEncodingKind.latin1, 0);
}

/// True when [bytes] is well-formed UTF-8 (no overlongs, surrogates or code points past
/// U+10FFFF). With [allowTruncatedEnd], a sequence cut off by the end of [bytes] is accepted.
bool isValidUtf8(Uint8List bytes, {bool allowTruncatedEnd = false}) {
  final n = bytes.length;
  var i = 0;
  while (i < n) {
    final b = bytes[i];
    if (b < 0x80) {
      i++;
      continue;
    }
    int need;
    int min;
    if (b >= 0xC2 && b <= 0xDF) {
      need = 1;
      min = 0x80;
    } else if (b >= 0xE0 && b <= 0xEF) {
      need = 2;
      min = 0x800;
    } else if (b >= 0xF0 && b <= 0xF4) {
      need = 3;
      min = 0x10000;
    } else {
      return false;
    }
    if (i + need >= n) {
      // Fewer continuation bytes left than the lead byte needs.
      if (!allowTruncatedEnd) return false;
      for (var j = i + 1; j < n; j++) {
        if (bytes[j] & 0xC0 != 0x80) return false;
      }
      return true;
    }
    var cp = b & (0x3F >> need);
    for (var j = 1; j <= need; j++) {
      final c = bytes[i + j];
      if (c & 0xC0 != 0x80) return false;
      cp = (cp << 6) | (c & 0x3F);
    }
    if (cp < min || cp > 0x10FFFF || (cp >= 0xD800 && cp <= 0xDFFF)) return false;
    i += need + 1;
  }
  return true;
}

const Utf8Decoder _utf8 = Utf8Decoder(allowMalformed: true);

/// Decodes `bytes[start, end)` as [kind]. Malformed input never throws: UTF-8 errors become
/// U+FFFD, and an odd trailing byte of UTF-16 is dropped.
String decodeRange(Uint8List bytes, int start, int end, TextEncodingKind kind) {
  if (end <= start) return '';
  switch (kind) {
    case TextEncodingKind.utf8:
      return _utf8.convert(bytes, start, end);
    case TextEncodingKind.latin1:
      return String.fromCharCodes(bytes, start, end);
    case TextEncodingKind.utf16le:
    case TextEncodingKind.utf16be:
      final units = Uint16List((end - start) >> 1);
      final le = kind == TextEncodingKind.utf16le;
      for (var u = 0, i = start; u < units.length; u++, i += 2) {
        units[u] = le ? bytes[i] | (bytes[i + 1] << 8) : (bytes[i] << 8) | bytes[i + 1];
      }
      return String.fromCharCodes(units);
  }
}
