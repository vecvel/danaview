// OWNER: CORE-22
//
// Project document versions and the `.dnproj` header line model (ARCH §8.2, §8.5, D-12).
//
// A `.dnproj` document is two UTF-8 lines: this header, then the body written by
// `ProjectJsonCodec` (project_json.dart). The header can be read without touching the body
// (Projects list, newer-schema detection): [ProjectHeader.readFrom] decodes only the bytes before
// the first `\n`. CORE-24 (`dnproj_format.dart`) writes and verifies whole documents; CORE-23
// classifies headers (needsNewerApp / readOnlyNewer) and migrates older bodies.

import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:meta/meta.dart';

/// The `format` value of every project document header.
const String projectFormatName = 'danaview.editor.project';

/// The body schema this build writes and reads natively (`schema/project.v1.schema.json`).
/// Increments on every format change (ARCH §8.5).
const int currentProjectSchema = 1;

/// The oldest reader schema that can still read documents this build writes. Increments only when
/// an older app would misread a newer document (ARCH §8.5, D-12).
const int currentProjectMinReader = 1;

/// A malformed project header or body (wrong JSON shape, missing required field, bad value).
///
/// Unknown keys and unknown enum values are **not** format errors: decoders ignore the former and
/// map the latter to defaults with a `ProjectOpenWarning` (ARCH §8.2).
final class ProjectFormatException implements Exception {
  /// Creates the exception; [path] is a JSON-pointer-like location such as `tracks[2].items[0].dur`.
  const ProjectFormatException(this.message, [this.path = '']);

  /// What is wrong (never contains media paths or user text).
  final String message;

  /// Where in the document.
  final String path;

  @override
  String toString() => 'ProjectFormatException(${path.isEmpty ? '' : '$path: '}$message)';
}

/// The first line of a `.dnproj` document (ARCH §8.2):
///
/// ```json
/// {"format":"danaview.editor.project","schema":1,"minReader":1,"app":"1.1.0+3","savedAt":"…",
///  "docRevision":812,"saveId":"sv_…","bodyBytes":48213,"bodySha256":"…"}
/// ```
///
/// Journal slots (CORE-26) also carry `baseSaveId`, the `saveId` of the main document they were
/// written on top of; it sits after `saveId` and is omitted when null. Keys are written in this
/// fixed order; unknown keys are ignored when reading (a newer app may add some).
@immutable
final class ProjectHeader {
  /// Creates a header. [savedAt] is stored in UTC.
  const ProjectHeader({
    this.format = projectFormatName,
    this.schema = currentProjectSchema,
    this.minReader = currentProjectMinReader,
    required this.app,
    required this.savedAt,
    required this.docRevision,
    required this.saveId,
    this.baseSaveId,
    required this.bodyBytes,
    required this.bodySha256,
  });

  /// A header for [body] (the exact body-line bytes, without the trailing `\n`): computes
  /// [bodyBytes] and [bodySha256]. Hashing belongs in the writer isolate (ARCH §8.3).
  factory ProjectHeader.forBody(
    Uint8List body, {
    required String app,
    required DateTime savedAt,
    required int docRevision,
    required String saveId,
    String? baseSaveId,
    int schema = currentProjectSchema,
    int minReader = currentProjectMinReader,
  }) =>
      ProjectHeader(
        schema: schema,
        minReader: minReader,
        app: app,
        savedAt: savedAt.toUtc(),
        docRevision: docRevision,
        saveId: saveId,
        baseSaveId: baseSaveId,
        bodyBytes: body.length,
        bodySha256: sha256.convert(body).toString(),
      );

  /// Always [projectFormatName].
  final String format;

  /// Body schema of the document.
  final int schema;

  /// Oldest reader schema that can read the document.
  final int minReader;

  /// App version that wrote the document, e.g. `1.1.0+3`.
  final String app;

  /// When the document was written (UTC).
  final DateTime savedAt;

  /// `EditProject.docRevision` of the body.
  final int docRevision;

  /// Id of this save (`sv_…`).
  final String saveId;

  /// For journal slots: the `saveId` of the main document this slot builds on; null otherwise.
  final String? baseSaveId;

  /// Exact UTF-8 length of the body line (without its trailing `\n`).
  final int bodyBytes;

  /// Lower-case hex SHA-256 of the body line bytes.
  final String bodySha256;

  /// Whether [body] has the recorded length and checksum (detects torn and truncated writes and
  /// bit flips).
  bool matchesBody(Uint8List body) => body.length == bodyBytes && sha256.convert(body).toString() == bodySha256;

  /// JSON object in the fixed key order.
  Map<String, Object?> toJson() => {
        'format': format,
        'schema': schema,
        'minReader': minReader,
        'app': app,
        'savedAt': savedAt.toUtc().toIso8601String(),
        'docRevision': docRevision,
        'saveId': saveId,
        if (baseSaveId != null) 'baseSaveId': baseSaveId,
        'bodyBytes': bodyBytes,
        'bodySha256': bodySha256,
      };

  /// The header line without its trailing `\n`.
  String encodeLine() => jsonEncode(toJson());

  /// Parses a decoded header object. Throws [ProjectFormatException].
  static ProjectHeader fromJson(Map<String, Object?> j) {
    final format = _str(j, 'format');
    if (format != projectFormatName) throw ProjectFormatException('not a project document', 'format');
    final sha = _str(j, 'bodySha256');
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(sha)) throw const ProjectFormatException('expected 64 hex digits', 'bodySha256');
    final savedAt = DateTime.tryParse(_str(j, 'savedAt'));
    if (savedAt == null) throw const ProjectFormatException('expected an ISO-8601 time', 'savedAt');
    final baseSaveId = j['baseSaveId'];
    if (baseSaveId != null && baseSaveId is! String) throw const ProjectFormatException('expected a string', 'baseSaveId');
    return ProjectHeader(
      format: format,
      schema: _count(j, 'schema'),
      minReader: _count(j, 'minReader'),
      app: _str(j, 'app'),
      savedAt: savedAt.toUtc(),
      docRevision: _count(j, 'docRevision'),
      saveId: _str(j, 'saveId'),
      baseSaveId: baseSaveId as String?,
      bodyBytes: _count(j, 'bodyBytes'),
      bodySha256: sha,
    );
  }

  /// Parses one header line (with or without a trailing `\n`). Throws [ProjectFormatException].
  static ProjectHeader parseLine(String line) {
    final Object? raw;
    try {
      raw = jsonDecode(line.endsWith('\n') ? line.substring(0, line.length - 1) : line);
    } on FormatException catch (e) {
      throw ProjectFormatException('header is not JSON: ${e.message}');
    }
    if (raw is! Map) throw const ProjectFormatException('header is not an object');
    return fromJson(raw.cast<String, Object?>());
  }

  /// Reads the header of a whole document (or of any prefix that contains the first `\n`) without
  /// decoding the body: only the bytes before the first `\n` are converted. Throws
  /// [ProjectFormatException] when there is no complete header line.
  static ProjectHeader readFrom(Uint8List document) {
    final end = headerLineEnd(document);
    if (end < 0) throw const ProjectFormatException('no header line');
    final String line;
    try {
      line = utf8.decode(Uint8List.sublistView(document, 0, end));
    } on FormatException {
      throw const ProjectFormatException('header is not UTF-8');
    }
    return parseLine(line);
  }

  /// Index of the `\n` that ends the header line in [document], or -1 when there is none.
  static int headerLineEnd(Uint8List document) => document.indexOf(0x0A);

  /// Like [readFrom], but returns null instead of throwing.
  static ProjectHeader? tryReadFrom(Uint8List document) {
    try {
      return readFrom(document);
    } on ProjectFormatException {
      return null;
    }
  }

  /// A copy with the given fields replaced.
  ProjectHeader copyWith({
    int? schema,
    int? minReader,
    String? app,
    DateTime? savedAt,
    int? docRevision,
    String? saveId,
    String? baseSaveId,
    int? bodyBytes,
    String? bodySha256,
  }) =>
      ProjectHeader(
        format: format,
        schema: schema ?? this.schema,
        minReader: minReader ?? this.minReader,
        app: app ?? this.app,
        savedAt: savedAt ?? this.savedAt,
        docRevision: docRevision ?? this.docRevision,
        saveId: saveId ?? this.saveId,
        baseSaveId: baseSaveId ?? this.baseSaveId,
        bodyBytes: bodyBytes ?? this.bodyBytes,
        bodySha256: bodySha256 ?? this.bodySha256,
      );

  @override
  bool operator ==(Object other) =>
      other is ProjectHeader &&
      other.format == format &&
      other.schema == schema &&
      other.minReader == minReader &&
      other.app == app &&
      other.savedAt == savedAt &&
      other.docRevision == docRevision &&
      other.saveId == saveId &&
      other.baseSaveId == baseSaveId &&
      other.bodyBytes == bodyBytes &&
      other.bodySha256 == bodySha256;

  @override
  int get hashCode =>
      Object.hash(format, schema, minReader, app, savedAt, docRevision, saveId, baseSaveId, bodyBytes, bodySha256);

  @override
  String toString() => 'ProjectHeader(schema $schema, minReader $minReader, rev $docRevision, $bodyBytes bytes)';

  static String _str(Map<String, Object?> j, String k) {
    final v = j[k];
    if (v is String) return v;
    throw ProjectFormatException('expected a string', k);
  }

  static int _count(Map<String, Object?> j, String k) {
    final v = j[k];
    if (v is int && v >= 0) return v;
    if (v is double && v >= 0 && v == v.truncateToDouble()) return v.toInt();
    throw ProjectFormatException('expected a non-negative integer', k);
  }
}
