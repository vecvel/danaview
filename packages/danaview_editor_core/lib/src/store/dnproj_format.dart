// OWNER: CORE-24
//
// The `.dnproj` container (ARCH §8.2): two UTF-8 lines,
//
//   {header JSON}\n{body JSON}\n
//
// The header (`ProjectHeader`, schema_version.dart, CORE-22) records the body's exact byte length
// (`bodyBytes`) and its SHA-256 (`bodySha256`); a document is valid only when the body that follows
// the first `\n` has exactly that length and hash. That detects truncated writes, torn sectors and
// bit flips. The body is opaque here (`ProjectJsonCodec` encodes and decodes it); nothing in this
// file parses it, so migrations and newer-schema detection can decide from the header alone.
//
// A document is accepted with or without the final `\n` (the body bytes are what is protected) and
// rejected with any other trailing data.

import 'dart:convert';
import 'dart:typed_data';

import 'package:meta/meta.dart';

import '../codec/schema_version.dart';
import 'atomic_file.dart';
import 'store_fs.dart';

/// Why a `.dnproj` byte sequence is not a valid document.
enum DnprojIssue {
  /// No `\n` ends a header line.
  noHeader,

  /// The first line is not a valid header.
  badHeader,

  /// Fewer body bytes than `bodyBytes`.
  truncated,

  /// The body has the right length but the wrong SHA-256 (bit flip, torn write).
  checksumMismatch,

  /// Bytes follow the body other than one final `\n`.
  trailingData,
}

/// A byte sequence that is not a valid `.dnproj` document.
@immutable
final class DnprojException implements Exception {
  /// Creates the exception.
  const DnprojException(this.issue, this.message);

  /// What is wrong.
  final DnprojIssue issue;

  /// Human-readable detail (no paths, no user content).
  final String message;

  @override
  String toString() => 'DnprojException(${issue.name}: $message)';
}

/// A parsed, verified document.
@immutable
final class DnprojDocument {
  /// Creates a document value (use [DnprojFormat.parse] or [DnprojFormat.build] to get verified
  /// ones).
  const DnprojDocument(this.header, this.body);

  /// The header line.
  final ProjectHeader header;

  /// The body line bytes (UTF-8 JSON, no trailing `\n`).
  final Uint8List body;
}

/// Pure functions over `.dnproj` bytes.
abstract final class DnprojFormat {
  /// The longest header line accepted (a real header is about 300 bytes).
  static const int maxHeaderBytes = 8192;

  /// Builds the document for [body] (the exact body-line bytes without `\n`): computes the header's
  /// `bodyBytes` and `bodySha256` and returns the full bytes. Hash large bodies in the writer
  /// isolate (ARCH §8.3).
  static Uint8List build(
    Uint8List body, {
    required String app,
    required DateTime savedAt,
    required int docRevision,
    required String saveId,
    String? baseSaveId,
    int schema = currentProjectSchema,
    int minReader = currentProjectMinReader,
  }) =>
      encode(ProjectHeader.forBody(
        body,
        app: app,
        savedAt: savedAt,
        docRevision: docRevision,
        saveId: saveId,
        baseSaveId: baseSaveId,
        schema: schema,
        minReader: minReader,
      ), body);

  /// Concatenates `header line`, `\n`, [body], `\n`. Throws [ArgumentError] when [header] does not
  /// describe [body] (wrong length or hash): such a document could never be read back.
  static Uint8List encode(ProjectHeader header, Uint8List body) {
    if (!header.matchesBody(body)) throw ArgumentError('header does not match the body (length or checksum)');
    final line = header.encodeLine();
    final headerBytes = utf8.encode(line);
    final out = Uint8List(headerBytes.length + 1 + body.length + 1);
    out.setRange(0, headerBytes.length, headerBytes);
    out[headerBytes.length] = 0x0A;
    out.setRange(headerBytes.length + 1, headerBytes.length + 1 + body.length, body);
    out[out.length - 1] = 0x0A;
    return out;
  }

  /// Parses and verifies [document]. Throws [DnprojException].
  static DnprojDocument parse(Uint8List document) {
    final end = ProjectHeader.headerLineEnd(document);
    if (end < 0 || end > maxHeaderBytes) throw const DnprojException(DnprojIssue.noHeader, 'no header line');
    final ProjectHeader header;
    try {
      header = ProjectHeader.readFrom(document);
    } on ProjectFormatException catch (e) {
      throw DnprojException(DnprojIssue.badHeader, e.message);
    }
    final start = end + 1;
    final available = document.length - start;
    if (available < header.bodyBytes) {
      throw DnprojException(DnprojIssue.truncated, 'body has $available of ${header.bodyBytes} bytes');
    }
    final bodyEnd = start + header.bodyBytes;
    final rest = document.length - bodyEnd;
    if (rest > 1 || (rest == 1 && document[bodyEnd] != 0x0A)) {
      throw const DnprojException(DnprojIssue.trailingData, 'bytes after the body');
    }
    final body = Uint8List.sublistView(document, start, bodyEnd);
    if (!header.matchesBody(body)) throw const DnprojException(DnprojIssue.checksumMismatch, 'body checksum differs');
    return DnprojDocument(header, body);
  }

  /// [parse], or null.
  static DnprojDocument? tryParse(Uint8List document) {
    try {
      return parse(document);
    } on DnprojException {
      return null;
    }
  }

  /// Whether [document] is a complete, intact document (the validity test for [AtomicFile.read]).
  static bool isValid(Uint8List document) => tryParse(document) != null;
}

/// Which copy of a document a read returned, with its verified contents.
@immutable
final class DnprojRead {
  /// Creates a read result.
  const DnprojRead(this.document, this.source, this.path);

  /// The verified document.
  final DnprojDocument document;

  /// `main`, or a fallback copy when the main file is missing or invalid.
  final AtomicSource source;

  /// The file the document came from.
  final String path;
}

/// `.dnproj` files on a [StoreFs]: header-only reads, verified reads with the tmp/.bak fallback,
/// and atomic writes.
final class DnprojFiles {
  /// Creates the accessor.
  DnprojFiles({StoreFs fs = const LocalStoreFs(), AtomicFile? atomic})
      : _fs = fs,
        _atomic = atomic ?? AtomicFile(fs: fs);

  final StoreFs _fs;
  final AtomicFile _atomic;

  /// Reads only the header of the file at [path] (the first [DnprojFormat.maxHeaderBytes] bytes at
  /// most), without reading or verifying the body: for the Projects list and for newer-schema
  /// detection. Throws [StoreFailure] (`notFound`, …) or [DnprojException] when the first line is
  /// not a header.
  Future<ProjectHeader> readHeader(String path) async {
    final prefix = await _fs.readPrefix(path, DnprojFormat.maxHeaderBytes + 1);
    final end = ProjectHeader.headerLineEnd(prefix);
    if (end < 0 || end > DnprojFormat.maxHeaderBytes) throw const DnprojException(DnprojIssue.noHeader, 'no header line');
    try {
      return ProjectHeader.readFrom(prefix);
    } on ProjectFormatException catch (e) {
      throw DnprojException(DnprojIssue.badHeader, e.message);
    }
  }

  /// Reads the best valid copy of the document at [path] (main, else the newest valid `tmp-*` or
  /// `.bak`). Throws [StoreFailure] `notFound` or `corrupt`. Never writes.
  Future<DnprojRead> read(String path) async {
    final r = await _atomic.read(path, isValid: DnprojFormat.isValid);
    return DnprojRead(DnprojFormat.parse(r.bytes), r.source, r.path);
  }

  /// Atomically writes [document] (bytes from [DnprojFormat.build] or [DnprojFormat.encode]) to
  /// [path]. Throws [ArgumentError] when it is not a valid document (never persist one).
  Future<void> write(String path, Uint8List document) {
    if (!DnprojFormat.isValid(document)) throw ArgumentError('not a valid .dnproj document');
    return _atomic.write(path, document);
  }
}
