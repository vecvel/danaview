// OWNER: HOM-23
//
// A text file loaded for the in-app viewer (HOM plan §8.4, ARCH §10.1 "Text viewer"): at most the
// first 50 MB are read (read-only, rule 27) on a background isolate, the encoding is detected, and
// a row index of byte offsets is built so the viewer decodes only the rows on screen (virtualised
// lines). Very long lines are split into display rows at a character boundary so no row ever lays
// out megabytes of text. Nothing here logs a name, a path or content (rule 30).

import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'text_encoding.dart';

/// The size cap of the in-app text and CSV viewers: larger files show their first 50 MB and offer
/// "Open in another app" (HOM plan §8.4).
const int textViewerCapBytes = 50 * 1024 * 1024;

/// The longest display row in bytes; longer lines continue on the next row.
const int textRowMaxBytes = 4096;

/// Why a text file could not be loaded (never holds a name or path, rule 30).
final class TextLoadException implements Exception {
  /// A failure; [missing] when the file does not exist.
  const TextLoadException({this.missing = false});

  /// The file is gone.
  final bool missing;

  @override
  String toString() => 'TextLoadException(${missing ? 'missing' : 'unreadable'})';
}

/// The bytes of a text file (up to the cap), their encoding and the row index.
final class TextDocument {
  /// A document over [bytes]; see [TextDocument.fromBytes] to build the index.
  TextDocument._({
    required this.bytes,
    required this.encoding,
    required this.detected,
    required this.bomLength,
    required Uint32List rowStarts,
    required this.rowCount,
    required this.fileSize,
    required this.maxRowBytes,
  }) : _rowStarts = rowStarts;

  /// Indexes [bytes] (the first bytes of a file of [fileSize] bytes). [encoding] overrides the
  /// detected one (the change-encoding menu).
  factory TextDocument.fromBytes(Uint8List bytes, {int? fileSize, TextEncodingKind? encoding, int rowMaxBytes = textRowMaxBytes}) {
    final size = fileSize ?? bytes.length;
    final guess = detectEncoding(bytes, truncated: size > bytes.length);
    final kind = encoding ?? guess.kind;
    final bom = bomLengthFor(bytes, kind);
    final index = _RowIndexer(bytes, kind, bom, rowMaxBytes).run();
    return TextDocument._(
      bytes: bytes,
      encoding: kind,
      detected: guess.kind,
      bomLength: bom,
      rowStarts: index.$1,
      rowCount: index.$2,
      fileSize: size,
      maxRowBytes: index.$3,
    );
  }

  /// Reads the first [capBytes] of the file at [path] read-only and indexes it on a background
  /// isolate. Throws [TextLoadException].
  static Future<TextDocument> load(String path, {int capBytes = textViewerCapBytes, TextEncodingKind? encoding}) =>
      Isolate.run(() => loadSync(path, capBytes: capBytes, encoding: encoding));

  /// [load] on the calling isolate.
  static TextDocument loadSync(String path, {int capBytes = textViewerCapBytes, TextEncodingKind? encoding}) {
    final file = File(path);
    RandomAccessFile? raf;
    try {
      raf = file.openSync(); // FileMode.read: read-only (rule 27).
      final size = raf.lengthSync();
      final want = size < capBytes ? size : capBytes;
      final bytes = Uint8List(want);
      var got = 0;
      while (got < want) {
        final n = raf.readIntoSync(bytes, got, want);
        if (n <= 0) break;
        got += n;
      }
      return TextDocument.fromBytes(got == want ? bytes : Uint8List.sublistView(bytes, 0, got), fileSize: size, encoding: encoding);
    } on FileSystemException {
      throw TextLoadException(missing: !file.existsSync());
    } finally {
      raf?.closeSync();
    }
  }

  /// This document decoded as [kind] (re-indexed on a background isolate).
  Future<TextDocument> withEncoding(TextEncodingKind kind) {
    if (kind == encoding) return Future.value(this);
    final b = bytes;
    final size = fileSize;
    return Isolate.run(() => TextDocument.fromBytes(b, fileSize: size, encoding: kind));
  }

  /// The bytes read (at most the cap).
  final Uint8List bytes;

  /// The encoding rows are decoded with.
  final TextEncodingKind encoding;

  /// The encoding detection chose.
  final TextEncodingKind detected;

  /// Byte-order mark bytes skipped at the start.
  final int bomLength;

  final Uint32List _rowStarts;

  /// Number of display rows.
  final int rowCount;

  /// Size of the whole file in bytes.
  final int fileSize;

  /// The longest display row in bytes (to size a non-wrapping view).
  final int maxRowBytes;

  /// True when only the first part of the file was read.
  bool get truncated => fileSize > bytes.length;

  /// Byte offset where row [i] starts.
  int rowStart(int i) => _rowStarts[i];

  /// Byte offset where row [i] ends (including its line break, if any).
  int rowEnd(int i) => i + 1 < rowCount ? _rowStarts[i + 1] : bytes.length;

  /// The text of row [i] without its line break.
  String row(int i) {
    final s = decodeRange(bytes, rowStart(i), rowEnd(i), encoding);
    var end = s.length;
    if (end > 0 && s.codeUnitAt(end - 1) == 0x0A) end--;
    if (end > 0 && s.codeUnitAt(end - 1) == 0x0D) end--;
    return end == s.length ? s : s.substring(0, end);
  }

  /// The text of `bytes[start, end)` (after the byte-order mark) decoded as [encoding].
  String decode(int start, int end) => decodeRange(bytes, start, end, encoding);
}

/// Builds the row index in one pass over the bytes, without allocating per row.
final class _RowIndexer {
  _RowIndexer(this.bytes, this.kind, this.bom, this.maxRow);

  final Uint8List bytes;
  final TextEncodingKind kind;
  final int bom;
  final int maxRow;

  Uint32List _starts = Uint32List(1024);
  int _count = 0;

  void _add(int offset) {
    if (_count == _starts.length) {
      final grown = Uint32List(_starts.length * 2)..setRange(0, _count, _starts);
      _starts = grown;
    }
    _starts[_count++] = offset;
  }

  (Uint32List, int, int) run() {
    final n = bytes.length;
    final unit = kind.unitBytes;
    // A trailing odd byte of UTF-16 belongs to no unit.
    final end = unit == 2 ? n - ((n - bom) & 1) : n;
    var start = bom;
    var longest = 0;
    if (start >= end) {
      _add(start);
      return (_starts, 1, 0);
    }
    _add(start);
    final le = kind == TextEncodingKind.utf16le;
    var i = start;
    while (i < end) {
      final isLf = unit == 1 ? bytes[i] == 0x0A : (le ? bytes[i] == 0x0A && bytes[i + 1] == 0 : bytes[i] == 0 && bytes[i + 1] == 0x0A);
      i += unit;
      if (isLf) {
        if (i - start > longest) longest = i - start;
        if (i < end) _add(i);
        start = i;
      } else if (i - start >= maxRow && i < end) {
        final cut = _boundary(i, start);
        if (cut - start > longest) longest = cut - start;
        _add(cut);
        start = cut;
        i = cut;
      }
    }
    if (end - start > longest) longest = end - start;
    return (_starts, _count, longest);
  }

  /// A character boundary at or before [i] (and after [start]) to split a long line.
  int _boundary(int i, int start) {
    var cut = i;
    if (kind == TextEncodingKind.utf8) {
      while (cut > start + 1 && cut < bytes.length && bytes[cut] & 0xC0 == 0x80) {
        cut--;
      }
    } else if (kind.unitBytes == 2) {
      // Don't split a surrogate pair: back off when the unit before the cut is a high surrogate.
      final hi = kind == TextEncodingKind.utf16le ? bytes[cut - 1] : bytes[cut - 2];
      if (hi >= 0xD8 && hi <= 0xDB && cut - 2 > start) cut -= 2;
    }
    return cut;
  }
}
