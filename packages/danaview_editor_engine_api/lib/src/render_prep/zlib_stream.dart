// OWNER: API-04
//
// Pure-Dart zlib (RFC 1950/1951) for `.vsprite` files. The contract package has no `dart:io`
// (API-01 rule, README), so `ZLibCodec` is not available:
//
// * [deflateZlib] — a fast single-pass encoder for premultiplied RGBA and glyph maps: LZ77 with
//   a 4-byte hash table plus the two image predictors that dominate sprites (the previous pixel,
//   distance 4 / 2, and the previous row, distance `stride`), emitted as one fixed-Huffman block.
//   Transparent and solid areas collapse into 258-byte matches; any standard inflater (zlib,
//   `java.util.zip.Inflater`, `dart:io`) decodes the output.
// * [inflateZlibStream] — a strict inflater that reports where a stream ends: `.vsprite` files
//   carry two concatenated zlib streams without length fields (ARCH §10.3). Native decoders find
//   the boundary with zlib's `avail_in` / `Inflater.getRemaining()`; `dart:io`'s `ZLibDecoder`
//   would ignore everything after the first stream and accept a truncated Adler-32 trailer.

import 'dart:typed_data';

/// Inflates the zlib stream starting at [offset] of [data] into exactly [expectedLength] bytes.
/// Returns the bytes and the offset just past the stream's Adler-32 trailer. Throws
/// [FormatException] on a malformed stream, a checksum mismatch or a different length.
(Uint8List, int) inflateZlibStream(Uint8List data, int offset, int expectedLength) {
  if (offset + 2 > data.length) throw const FormatException('zlib: truncated header');
  final cmf = data[offset];
  final flg = data[offset + 1];
  if ((cmf & 0x0F) != 8 || (cmf >> 4) > 7 || ((cmf << 8) | flg) % 31 != 0) {
    throw const FormatException('zlib: bad header');
  }
  if (flg & 0x20 != 0) throw const FormatException('zlib: preset dictionaries are not supported');
  final r = _Bits(data, offset + 2);
  final out = Uint8List(expectedLength);
  var n = 0;

  void put(int b) {
    if (n >= expectedLength) throw const FormatException('zlib: more data than expected');
    out[n++] = b;
  }

  var last = false;
  while (!last) {
    last = r.bits(1) == 1;
    final type = r.bits(2);
    if (type == 0) {
      r.alignToByte();
      final len = r.byte() | (r.byte() << 8);
      final nlen = r.byte() | (r.byte() << 8);
      if (len != (~nlen & 0xFFFF)) throw const FormatException('zlib: bad stored block length');
      if (n + len > expectedLength) throw const FormatException('zlib: more data than expected');
      for (var i = 0; i < len; i++) {
        out[n++] = r.byte();
      }
      continue;
    }
    _Huffman lit;
    _Huffman dist;
    if (type == 1) {
      lit = _fixedLit;
      dist = _fixedDist;
    } else if (type == 2) {
      (lit, dist) = _dynamicTables(r);
    } else {
      throw const FormatException('zlib: bad block type');
    }
    while (true) {
      final sym = lit.decode(r);
      if (sym < 256) {
        put(sym);
      } else if (sym == 256) {
        break;
      } else {
        final li = sym - 257;
        if (li >= 29) throw const FormatException('zlib: bad length symbol');
        final len = _lenBase[li] + r.bits(_lenExtra[li]);
        final di = dist.decode(r);
        if (di >= 30) throw const FormatException('zlib: bad distance symbol');
        final d = _distBase[di] + r.bits(_distExtra[di]);
        if (d > n) throw const FormatException('zlib: distance too far back');
        if (n + len > expectedLength) throw const FormatException('zlib: more data than expected');
        for (var i = 0; i < len; i++) {
          out[n] = out[n - d];
          n++;
        }
      }
    }
  }
  r.alignToByte();
  final adler = (r.byte() << 24) | (r.byte() << 16) | (r.byte() << 8) | r.byte();
  if (n != expectedLength) throw FormatException('zlib: $n bytes, expected $expectedLength');
  if (adler != adler32(out)) throw const FormatException('zlib: Adler-32 mismatch');
  return (out, r.pos);
}

/// zlib stream of [data] (file header). [stride] is the row length in bytes of image data (0 when
/// [data] is not an image); [pixelBytes] the bytes per pixel (4 for RGBA, 2 for u16 maps).
Uint8List deflateZlib(Uint8List data, {int stride = 0, int pixelBytes = 4}) {
  final n = data.length;
  final w = _BitWriter(n + (n >> 3) + 64)
    ..byte(0x78) // CMF: deflate, 32 KiB window
    ..byte(0x01); // FLG: fastest; (0x7801 % 31 == 0)
  w.bits(1, 1); // BFINAL
  w.bits(1, 2); // BTYPE = 01 (fixed Huffman)
  final table = Int32List(1 << _hashBits); // position + 1 of the last 4-byte sequence, 0 = none
  final up = stride > 0 && stride <= _window ? stride : 0;
  final px = pixelBytes > 0 && pixelBytes <= 8 ? pixelBytes : 0;
  var i = 0;
  while (i < n) {
    var bestLen = 0;
    var bestDist = 0;
    if (i + 4 <= n) {
      final h = (((data[i] | (data[i + 1] << 8) | (data[i + 2] << 16) | (data[i + 3] << 24)) * 0x9E3779B1) & 0xFFFFFFFF) >>
          (32 - _hashBits);
      final cand = table[h] - 1;
      table[h] = i + 1;
      final maxLen = n - i < 258 ? n - i : 258;
      // Candidates: previous pixel, previous row, hash chain head.
      for (var k = 0; k < 3; k++) {
        final c = k == 0 ? (px > 0 ? i - px : -1) : (k == 1 ? (up > 0 ? i - up : -1) : cand);
        if (c < 0 || i - c > _window || i - c <= 0) continue;
        // Cheap rejections: first byte, and the byte that would make this candidate the best.
        if (data[c] != data[i]) continue;
        if (bestLen > 0 && bestLen < maxLen && data[c + bestLen] != data[i + bestLen]) continue;
        var len = 0;
        while (len < maxLen && data[c + len] == data[i + len]) {
          len++;
        }
        if (len > bestLen) {
          bestLen = len;
          bestDist = i - c;
          if (len == maxLen) break;
        }
      }
    }
    if (bestLen >= 4) {
      _writeLength(w, bestLen);
      _writeDistance(w, bestDist);
      i += bestLen;
    } else {
      final b = data[i];
      w.bits(_litCode[b], _litLen[b]);
      i++;
    }
  }
  w.bits(_litCode[256], _litLen[256]); // end of block
  w.flushByte();
  final a = adler32(data);
  w
    ..byte((a >> 24) & 0xFF)
    ..byte((a >> 16) & 0xFF)
    ..byte((a >> 8) & 0xFF)
    ..byte(a & 0xFF);
  return w.takeBytes();
}

const int _hashBits = 15;
const int _window = 32768;

void _writeLength(_BitWriter w, int len) {
  var li = 28;
  while (_lenBase[li] > len) {
    li--;
  }
  final sym = 257 + li;
  w.bits(_litCode[sym], _litLen[sym]);
  final extra = _lenExtra[li];
  if (extra > 0) w.bits(len - _lenBase[li], extra);
}

void _writeDistance(_BitWriter w, int d) {
  var di = 29;
  while (_distBase[di] > d) {
    di--;
  }
  w.bits(_distCode[di], 5);
  final extra = _distExtra[di];
  if (extra > 0) w.bits(d - _distBase[di], extra);
}

int _reverse(int code, int len) {
  var r = 0;
  for (var k = 0; k < len; k++) {
    r = (r << 1) | ((code >> k) & 1);
  }
  return r;
}

/// Fixed literal/length codes (RFC 1951 §3.2.6), bit-reversed for LSB-first packing.
final Int32List _litLen = Int32List.fromList([for (var v = 0; v < 288; v++) v < 144 ? 8 : (v < 256 ? 9 : (v < 280 ? 7 : 8))]);
final Int32List _litCode = Int32List.fromList([
  for (var v = 0; v < 288; v++)
    _reverse(v < 144 ? 0x30 + v : (v < 256 ? 0x190 + v - 144 : (v < 280 ? v - 256 : 0xC0 + v - 280)), _litLen[v]),
]);
final Int32List _distCode = Int32List.fromList([for (var d = 0; d < 30; d++) _reverse(d, 5)]);

final class _BitWriter {
  _BitWriter(int capacity) : _out = Uint8List(capacity < 64 ? 64 : capacity);
  Uint8List _out;
  int _n = 0;
  int _buf = 0;
  int _cnt = 0;

  void _ensure(int extra) {
    if (_n + extra <= _out.length) return;
    final bigger = Uint8List((_out.length * 3 ~/ 2) + extra);
    bigger.setRange(0, _n, _out);
    _out = bigger;
  }

  void bits(int value, int count) {
    _buf |= value << _cnt;
    _cnt += count;
    if (_cnt >= 32) {
      _ensure(4);
      while (_cnt >= 8) {
        _out[_n++] = _buf & 0xFF;
        _buf >>= 8;
        _cnt -= 8;
      }
    }
  }

  void flushByte() {
    _ensure(8);
    while (_cnt > 0) {
      _out[_n++] = _buf & 0xFF;
      _buf >>= 8;
      _cnt = _cnt > 8 ? _cnt - 8 : 0;
    }
    _buf = 0;
  }

  void byte(int b) {
    flushByte();
    _ensure(1);
    _out[_n++] = b;
  }

  Uint8List takeBytes() => Uint8List.sublistView(_out, 0, _n);
}

/// Adler-32 of [bytes].
int adler32(Uint8List bytes) {
  var a = 1;
  var b = 0;
  var i = 0;
  while (i < bytes.length) {
    final end = (i + 5552 < bytes.length) ? i + 5552 : bytes.length;
    for (; i < end; i++) {
      a += bytes[i];
      b += a;
    }
    a %= 65521;
    b %= 65521;
  }
  return (b << 16) | a;
}

final class _Bits {
  _Bits(this.d, this.pos);
  final Uint8List d;
  int pos;
  int _buf = 0;
  int _cnt = 0;

  int bits(int n) {
    while (_cnt < n) {
      if (pos >= d.length) throw const FormatException('zlib: truncated stream');
      _buf |= d[pos++] << _cnt;
      _cnt += 8;
    }
    final v = _buf & ((1 << n) - 1);
    _buf >>= n;
    _cnt -= n;
    return v;
  }

  void alignToByte() {
    // Fewer than 8 buffered bits are left after any read; they belong to the current byte.
    _buf = 0;
    _cnt = 0;
  }

  int byte() {
    if (pos >= d.length) throw const FormatException('zlib: truncated stream');
    return d[pos++];
  }
}

/// Canonical Huffman decoder (counts per length, symbols in code order).
final class _Huffman {
  _Huffman(List<int> lengths) {
    for (final l in lengths) {
      counts[l]++;
    }
    counts[0] = 0;
    final offs = Int32List(16);
    for (var i = 1; i < 16; i++) {
      offs[i] = offs[i - 1] + counts[i - 1];
    }
    // offs[i] is the index of the first symbol of length i (counts[0] is 0).
    for (var s = 0; s < lengths.length; s++) {
      if (lengths[s] != 0) symbols[offs[lengths[s]]++] = s;
    }
  }

  final Int32List counts = Int32List(16);
  final Int32List symbols = Int32List(320);

  int decode(_Bits r) {
    var code = 0;
    var first = 0;
    var index = 0;
    for (var len = 1; len < 16; len++) {
      code |= r.bits(1);
      final count = counts[len];
      if (code - first < count) return symbols[index + code - first];
      index += count;
      first = (first + count) << 1;
      code <<= 1;
    }
    throw const FormatException('zlib: bad Huffman code');
  }
}

const List<int> _clOrder = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15];

(_Huffman, _Huffman) _dynamicTables(_Bits r) {
  final hlit = r.bits(5) + 257;
  final hdist = r.bits(5) + 1;
  final hclen = r.bits(4) + 4;
  final cl = List<int>.filled(19, 0);
  for (var i = 0; i < hclen; i++) {
    cl[_clOrder[i]] = r.bits(3);
  }
  final clh = _Huffman(cl);
  final lengths = List<int>.filled(hlit + hdist, 0);
  var i = 0;
  while (i < hlit + hdist) {
    final sym = clh.decode(r);
    if (sym < 16) {
      lengths[i++] = sym;
      continue;
    }
    int rep;
    var val = 0;
    if (sym == 16) {
      if (i == 0) throw const FormatException('zlib: repeat without a previous length');
      val = lengths[i - 1];
      rep = 3 + r.bits(2);
    } else if (sym == 17) {
      rep = 3 + r.bits(3);
    } else {
      rep = 11 + r.bits(7);
    }
    if (i + rep > hlit + hdist) throw const FormatException('zlib: too many code lengths');
    for (var k = 0; k < rep; k++) {
      lengths[i++] = val;
    }
  }
  return (_Huffman(lengths.sublist(0, hlit)), _Huffman(lengths.sublist(hlit)));
}

final _Huffman _fixedLit = _Huffman([
  for (var i = 0; i < 288; i++) i < 144 ? 8 : (i < 256 ? 9 : (i < 280 ? 7 : 8)),
]);
final _Huffman _fixedDist = _Huffman(List<int>.filled(30, 5));

const List<int> _lenBase = [3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258];
const List<int> _lenExtra = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0];
const List<int> _distBase = [
  1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, //
  8193, 12289, 16385, 24577,
];
const List<int> _distExtra = [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13];
