// OWNER: HOM-20
//
// ImportSource, one thing to copy into a Danaview folder (ARCH v1.2 §5.6, V2-116): a local file the
// import reads itself (a desktop pick, a macOS open-panel URL, a picker copy staged in an app
// directory, a linked-folder file) or a platform URI only the native side can read (an Android
// content URI, a security-scoped URL). The source is stored JSON-encoded in `import_jobs.source_desc`
// so an import killed half-way resumes after relaunch while the source is still readable. It is
// never logged (rule 30).

import 'dart:convert';

import 'package:meta/meta.dart';

import '../model/source_hint.dart';

/// How the bytes of an [ImportSource] are read.
enum ImportSourceKind {
  /// A local path, read here with a read-only open (rule 27).
  file('file'),

  /// A platform URI (`content://`, security-scoped `file://`) copied by the native side.
  nativeUri('nativeUri');

  const ImportSourceKind(this.code);

  /// The stored string.
  final String code;

  /// The kind stored as [code], or null.
  static ImportSourceKind? tryDecode(Object? code) {
    for (final k in values) {
      if (k.code == code) return k;
    }
    return null;
  }
}

/// One source of an import.
@immutable
final class ImportSource {
  /// A source. [location] is a path for [ImportSourceKind.file] and a URI for
  /// [ImportSourceKind.nativeUri].
  const ImportSource({
    required this.kind,
    required this.location,
    required this.displayName,
    this.uti,
    this.mime,
    this.sizeBytes,
    this.modifiedAt,
    this.sourceHint = SourceHint.files,
    this.stagedCopy = false,
    this.releaseUri,
  });

  /// A local file at [path] named [displayName] (the file's own name when null).
  factory ImportSource.file(
    String path, {
    String? displayName,
    String? uti,
    String? mime,
    int? sizeBytes,
    DateTime? modifiedAt,
    SourceHint sourceHint = SourceHint.files,
    bool stagedCopy = false,
    String? releaseUri,
  }) =>
      ImportSource(
        kind: ImportSourceKind.file,
        location: path,
        displayName: displayName ?? _baseName(path),
        uti: uti,
        mime: mime,
        sizeBytes: sizeBytes,
        modifiedAt: modifiedAt,
        sourceHint: sourceHint,
        stagedCopy: stagedCopy,
        releaseUri: releaseUri,
      );

  /// How the bytes are read.
  final ImportSourceKind kind;

  /// The path or URI.
  final String location;

  /// The name the entry gets (deduplicated in the target folder).
  final String displayName;

  /// Apple UTType, when the platform reported one.
  final String? uti;

  /// MIME type, when the platform reported one.
  final String? mime;

  /// Size reported by the platform (the import stats the source itself too).
  final int? sizeBytes;

  /// Modification time reported by the platform.
  final DateTime? modifiedAt;

  /// Where it came from (stored on the entry).
  final SourceHint sourceHint;

  /// True when [location] is an app-owned copy a picker staged (the PHPicker and document-picker
  /// copies): the import deletes it after the commit. The user's original is never deleted.
  final bool stagedCopy;

  /// A URI whose platform grant is given up after the import (security-scoped URL), or null.
  final String? releaseUri;

  /// The JSON stored in `import_jobs.source_desc`.
  String encode() => jsonEncode({
        'v': 1,
        'kind': kind.code,
        'loc': location,
        'name': displayName,
        if (uti != null) 'uti': uti,
        if (mime != null) 'mime': mime,
        if (sizeBytes != null) 'size': sizeBytes,
        if (modifiedAt != null) 'mtime': modifiedAt!.toUtc().millisecondsSinceEpoch,
        'hint': sourceHint.code,
        if (stagedCopy) 'staged': true,
        if (releaseUri != null) 'release': releaseUri,
      });

  /// The source stored as [text], or null when it is missing or unreadable.
  static ImportSource? tryDecode(String? text) {
    if (text == null || text.isEmpty) return null;
    final Object? json;
    try {
      json = jsonDecode(text);
    } on FormatException {
      return null;
    }
    if (json is! Map<String, Object?>) return null;
    final kind = ImportSourceKind.tryDecode(json['kind']);
    final loc = json['loc'];
    final name = json['name'];
    if (kind == null || loc is! String || loc.isEmpty || name is! String || name.isEmpty) return null;
    final size = json['size'];
    final mtime = json['mtime'];
    final hint = json['hint'];
    return ImportSource(
      kind: kind,
      location: loc,
      displayName: name,
      uti: json['uti'] is String ? json['uti'] as String : null,
      mime: json['mime'] is String ? json['mime'] as String : null,
      sizeBytes: size is int ? size : null,
      modifiedAt: mtime is int ? DateTime.fromMillisecondsSinceEpoch(mtime, isUtc: true) : null,
      sourceHint: hint is String ? SourceHint.decode(hint) : SourceHint.unknown,
      stagedCopy: json['staged'] == true,
      releaseUri: json['release'] is String ? json['release'] as String : null,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is ImportSource &&
      other.kind == kind &&
      other.location == location &&
      other.displayName == displayName &&
      other.uti == uti &&
      other.mime == mime &&
      other.sizeBytes == sizeBytes &&
      other.modifiedAt == modifiedAt &&
      other.sourceHint == sourceHint &&
      other.stagedCopy == stagedCopy &&
      other.releaseUri == releaseUri;

  @override
  int get hashCode => Object.hash(kind, location, displayName, uti, mime, sizeBytes, modifiedAt, sourceHint, stagedCopy, releaseUri);

  // Never prints the location or the name (rule 30).
  @override
  String toString() => 'ImportSource(${kind.code}, ${sourceHint.code})';
}

String _baseName(String path) {
  final parts = path.split(RegExp(r'[/\\]'));
  for (var i = parts.length - 1; i >= 0; i--) {
    if (parts[i].isNotEmpty) return parts[i];
  }
  return path;
}
