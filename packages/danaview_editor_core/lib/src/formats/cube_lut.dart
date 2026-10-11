// OWNER: CORE-21
//
// .cube LUT parser (ARCH §10.2, D-07). Pure function; callers run it in Isolate.run.
//
// Accepted: TITLE, LUT_3D_SIZE 2..65, LUT_1D_SIZE (converted to a 33^3 table with a notice),
// DOMAIN_MIN/DOMAIN_MAX, Resolve's LUT_1D_INPUT_RANGE / LUT_3D_INPUT_RANGE, '#' comments, blank
// lines, CR/LF/CRLF. Table entries are red-fastest, exactly as in the file. The domain is
// recorded but the entries are not resampled: a table always spans its input domain, and the
// .vlut maps that whole span to [0,1] (D-07).

import 'dart:convert';
import 'dart:typed_data';

/// Largest supported 3D LUT edge.
const int maxLutSize = 65;

/// Edge of the table produced from a 1D LUT.
const int lut1dConvertedSize = 33;

/// Largest accepted .cube file in bytes.
const int maxCubeBytes = 16 * 1024 * 1024;

/// Largest accepted 1D LUT length.
const int maxLut1dSize = 65536;

/// User-facing message for oversize LUTs.
const String lutTooLargeMessage = 'LUTs up to 65×65×65 are supported.';

/// A malformed or unsupported LUT file; [message] is ready to show ("Line 14: expected 3 numbers").
final class LutFormatException implements Exception {
  /// Creates an exception; [line] is 1-based, or null when not tied to a line.
  const LutFormatException(this.message, {this.line});

  /// Human-readable message, including the "Line n: " prefix when [line] is known.
  final String message;

  /// 1-based source line, if any.
  final int? line;

  @override
  String toString() => message;
}

/// A parsed 3D look-up table.
final class CubeLut {
  /// Creates a LUT; [rgb] holds `size³ × 3` values, red index fastest.
  const CubeLut({
    required this.size,
    required this.rgb,
    this.title,
    this.domainMin = const [0, 0, 0],
    this.domainMax = const [1, 1, 1],
    this.notice,
  });

  /// Edge length N (2..65).
  final int size;

  /// `N³` RGB triples, red fastest then green then blue.
  final Float32List rgb;

  /// TITLE, when present.
  final String? title;

  /// Per-channel input domain minimum.
  final List<double> domainMin;

  /// Per-channel input domain maximum.
  final List<double> domainMax;

  /// Informational note (for example "1D LUT converted to 33×33×33"), or null.
  final String? notice;

  /// Parses .cube [bytes] (UTF-8, BOM tolerated). Throws [LutFormatException].
  static CubeLut parse(Uint8List bytes) {
    if (bytes.length > maxCubeBytes) throw const LutFormatException(lutTooLargeMessage);
    var from = 0;
    if (bytes.length >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF) from = 3;
    return parseText(const Utf8Decoder(allowMalformed: true).convert(bytes, from));
  }

  /// Parses .cube [text]. Throws [LutFormatException].
  static CubeLut parseText(String text) => _CubeParser(text).run();
}

final class _CubeParser {
  _CubeParser(this.s);

  final String s;
  String? title;
  int size3 = 0;
  int size1 = 0;
  int lineOfSize = 0;
  var dMin = <double>[0, 0, 0];
  var dMax = <double>[1, 1, 1];
  Float32List? data;
  int filled = 0; // number of floats written
  int expectedFloats = 0;
  int lastLine = 1;

  Never fail(int line, String msg) => throw LutFormatException('Line $line: $msg', line: line);

  CubeLut run() {
    final n = s.length;
    var pos = 0;
    var line = 0;
    final nums = List<double>.filled(3, 0);
    while (pos < n) {
      line++;
      var end = pos;
      while (end < n) {
        final c = s.codeUnitAt(end);
        if (c == 10 || c == 13) break;
        end++;
      }
      final lineStart = pos;
      pos = end;
      if (pos < n) {
        if (s.codeUnitAt(pos) == 13 && pos + 1 < n && s.codeUnitAt(pos + 1) == 10) pos++;
        pos++;
      }
      lastLine = line;
      // Trim leading whitespace.
      var a = lineStart;
      while (a < end && _isSpace(s.codeUnitAt(a))) {
        a++;
      }
      if (a == end) continue;
      final c0 = s.codeUnitAt(a);
      if (c0 == 0x23) continue; // '#'
      if (_isNumStart(c0)) {
        _dataLine(a, end, line, nums);
        continue;
      }
      _keyword(a, end, line);
    }
    return _finish();
  }

  static bool _isSpace(int c) => c == 32 || c == 9 || c == 0xA0 || c == 0xFEFF;
  static bool _isNumStart(int c) => (c >= 0x30 && c <= 0x39) || c == 0x2D || c == 0x2B || c == 0x2E;

  void _dataLine(int a, int end, int line, List<double> nums) {
    if (data == null) fail(line, 'data found before LUT_3D_SIZE or LUT_1D_SIZE');
    var count = 0;
    var p = a;
    while (p < end) {
      while (p < end && _isSpace(s.codeUnitAt(p))) {
        p++;
      }
      if (p >= end) break;
      if (s.codeUnitAt(p) == 0x23) break; // trailing comment
      final t0 = p;
      while (p < end) {
        final c = s.codeUnitAt(p);
        if (_isSpace(c) || c == 0x23) break;
        p++;
      }
      if (count >= 3) fail(line, 'expected 3 numbers');
      final v = double.tryParse(s.substring(t0, p));
      if (v == null || !v.isFinite) fail(line, "'${s.substring(t0, p)}' is not a number");
      nums[count++] = v;
    }
    if (count != 3) fail(line, 'expected 3 numbers');
    if (filled >= expectedFloats) {
      fail(line, 'too many table entries (expected ${expectedFloats ~/ 3})');
    }
    final d = data!;
    d[filled] = nums[0];
    d[filled + 1] = nums[1];
    d[filled + 2] = nums[2];
    filled += 3;
  }

  void _keyword(int a, int end, int line) {
    var p = a;
    while (p < end && !_isSpace(s.codeUnitAt(p))) {
      p++;
    }
    final kw = s.substring(a, p);
    var rest = s.substring(p, end).trim();
    switch (kw) {
      case 'TITLE':
        if (rest.length >= 2 && rest.startsWith('"') && rest.endsWith('"')) {
          rest = rest.substring(1, rest.length - 1);
        }
        title = rest.isEmpty ? null : rest;
      case 'LUT_3D_SIZE':
      case 'LUT_1D_SIZE':
        final is3 = kw == 'LUT_3D_SIZE';
        if (size3 != 0 || size1 != 0) fail(line, 'a .cube file can declare only one LUT size');
        final v = int.tryParse(_stripComment(rest));
        if (v == null) fail(line, '$kw expects a whole number');
        if (is3) {
          if (v > maxLutSize) throw LutFormatException('Line $line: $lutTooLargeMessage', line: line);
          if (v < 2) fail(line, '$kw must be at least 2');
          size3 = v;
          expectedFloats = v * v * v * 3;
        } else {
          if (v > maxLut1dSize) throw LutFormatException('Line $line: $lutTooLargeMessage', line: line);
          if (v < 2) fail(line, '$kw must be at least 2');
          size1 = v;
          expectedFloats = v * 3;
        }
        lineOfSize = line;
        data = Float32List(expectedFloats);
      case 'DOMAIN_MIN':
        dMin = _triple(rest, line, kw);
      case 'DOMAIN_MAX':
        dMax = _triple(rest, line, kw);
      case 'LUT_1D_INPUT_RANGE':
      case 'LUT_3D_INPUT_RANGE':
        final parts = _numbers(rest, line, kw, 2);
        dMin = [parts[0], parts[0], parts[0]];
        dMax = [parts[1], parts[1], parts[1]];
      default:
        // Unknown keywords (LUT_IN_VIDEO_RANGE etc.) are ignored; stray words are an error.
        if (!RegExp(r'^[A-Z][A-Z0-9_]*$').hasMatch(kw)) fail(line, "unexpected text '$kw'");
    }
  }

  String _stripComment(String r) {
    final i = r.indexOf('#');
    return (i < 0 ? r : r.substring(0, i)).trim();
  }

  List<double> _numbers(String rest, int line, String kw, int want) {
    final parts = _stripComment(rest).split(RegExp(r'\s+')).where((e) => e.isNotEmpty).toList();
    if (parts.length != want) fail(line, '$kw expects $want numbers');
    final out = <double>[];
    for (final p in parts) {
      final v = double.tryParse(p);
      if (v == null || !v.isFinite) fail(line, "'$p' is not a number");
      out.add(v);
    }
    return out;
  }

  List<double> _triple(String rest, int line, String kw) => _numbers(rest, line, kw, 3);

  CubeLut _finish() {
    if (data == null) {
      throw const LutFormatException('Missing LUT_3D_SIZE (or LUT_1D_SIZE).');
    }
    for (var c = 0; c < 3; c++) {
      if (!(dMax[c] > dMin[c])) {
        throw LutFormatException(
            'Line ${lineOfSize == 0 ? 1 : lineOfSize}: DOMAIN_MAX must be greater than DOMAIN_MIN');
      }
    }
    if (filled != expectedFloats) {
      throw LutFormatException(
        'Line $lastLine: expected ${expectedFloats ~/ 3} table entries, found ${filled ~/ 3}',
        line: lastLine,
      );
    }
    if (size3 != 0) {
      return CubeLut(size: size3, rgb: data!, title: title, domainMin: dMin, domainMax: dMax);
    }
    return CubeLut(
      size: lut1dConvertedSize,
      rgb: _convert1d(data!, size1, lut1dConvertedSize),
      title: title,
      domainMin: dMin,
      domainMax: dMax,
      notice: 'The 1D LUT ($size1 entries) was converted to a '
          '$lut1dConvertedSize×$lut1dConvertedSize×$lut1dConvertedSize table.',
    );
  }
}

/// Expands per-channel 1D curves (red, green, blue columns) into an [n]³ table.
Float32List _convert1d(Float32List curve, int len, int n) {
  // Resample each channel at the n grid positions once, then replicate.
  final per = List<Float64List>.generate(3, (c) {
    final out = Float64List(n);
    for (var i = 0; i < n; i++) {
      final x = i / (n - 1) * (len - 1);
      final i0 = x.floor().clamp(0, len - 2);
      final f = x - i0;
      out[i] = curve[i0 * 3 + c] * (1 - f) + curve[(i0 + 1) * 3 + c] * f;
    }
    return out;
  });
  final out = Float32List(n * n * n * 3);
  var o = 0;
  for (var b = 0; b < n; b++) {
    for (var g = 0; g < n; g++) {
      for (var r = 0; r < n; r++) {
        out[o++] = per[0][r];
        out[o++] = per[1][g];
        out[o++] = per[2][b];
      }
    }
  }
  return out;
}
