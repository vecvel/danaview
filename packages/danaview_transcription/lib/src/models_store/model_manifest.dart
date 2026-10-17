// OWNER: AI-09
//
// On-disk records of the model store (ai.md §5.2): the atomic `manifest.json` and the `.part.json`
// sidecar next to a partial download. Parsing is defensive: anything malformed reads as "absent",
// never as an exception, so a damaged file costs a re-download at worst.

library;

import 'dart:convert';
import 'dart:io';

import 'package:meta/meta.dart';

/// One installed file in `manifest.json`.
@immutable
final class ManifestEntry {
  /// Creates an entry.
  const ManifestEntry({
    required this.id,
    required this.file,
    required this.sha256,
    required this.bytes,
    required this.installedAt,
    required this.verifiedAt,
    this.lastUsedAt,
  });

  /// Catalog id.
  final String id;

  /// File name inside the models folder.
  final String file;

  /// SHA-256 the file was verified against.
  final String sha256;

  /// Size in bytes.
  final int bytes;

  /// Install time (UTC).
  final DateTime installedAt;

  /// When the hash was last verified (UTC).
  final DateTime verifiedAt;

  /// Last use (UTC).
  final DateTime? lastUsedAt;

  /// A copy with [lastUsedAt] replaced.
  ManifestEntry usedAt(DateTime at) =>
      ManifestEntry(id: id, file: file, sha256: sha256, bytes: bytes, installedAt: installedAt, verifiedAt: verifiedAt, lastUsedAt: at);

  /// JSON form.
  Map<String, Object?> toJson() => {
        'id': id,
        'file': file,
        'sha256': sha256,
        'bytes': bytes,
        'installedAt': installedAt.toUtc().toIso8601String(),
        'verifiedAt': verifiedAt.toUtc().toIso8601String(),
        if (lastUsedAt != null) 'lastUsedAt': lastUsedAt!.toUtc().toIso8601String(),
      };

  /// Parses one entry; null when malformed.
  static ManifestEntry? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id'];
    final file = raw['file'];
    final sha = raw['sha256'];
    final bytes = raw['bytes'];
    final installedAt = _date(raw['installedAt']);
    final verifiedAt = _date(raw['verifiedAt']);
    if (id is! String || file is! String || sha is! String || bytes is! int || bytes <= 0) return null;
    if (installedAt == null || verifiedAt == null) return null;
    // A file name never leaves the models folder.
    if (file.isEmpty || file.contains('/') || file.contains(r'\') || file == '..' || file == '.') return null;
    return ManifestEntry(
      id: id,
      file: file,
      sha256: sha.toLowerCase(),
      bytes: bytes,
      installedAt: installedAt,
      verifiedAt: verifiedAt,
      lastUsedAt: _date(raw['lastUsedAt']),
    );
  }
}

/// `manifest.json`: `{schema: 1, installed: [...]}`.
@immutable
final class SpeechModelManifest {
  /// Creates a manifest.
  const SpeechModelManifest(this.installed);

  /// The manifest of a store with nothing installed.
  static const SpeechModelManifest empty = SpeechModelManifest([]);

  /// Schema version written and understood.
  static const int schema = 1;

  /// Installed files.
  final List<ManifestEntry> installed;

  /// The entry of [id], or null.
  ManifestEntry? entryOf(String id) {
    for (final e in installed) {
      if (e.id == id) return e;
    }
    return null;
  }

  /// A copy with [entry] added or replaced.
  SpeechModelManifest upsert(ManifestEntry entry) =>
      SpeechModelManifest([for (final e in installed) if (e.id != entry.id) e, entry]);

  /// A copy without [id].
  SpeechModelManifest without(String id) => SpeechModelManifest([for (final e in installed) if (e.id != id) e]);

  /// JSON text.
  String encode() => const JsonEncoder.withIndent('  ').convert({
        'schema': schema,
        'installed': [for (final e in installed) e.toJson()],
      });

  /// Parses [text]; null when it is not a schema-1 manifest.
  static SpeechModelManifest? tryDecode(String text) {
    try {
      final raw = jsonDecode(text);
      if (raw is! Map || raw['schema'] != schema) return null;
      final list = raw['installed'];
      if (list is! List) return null;
      final entries = <ManifestEntry>[];
      for (final item in list) {
        final e = ManifestEntry.tryParse(item);
        if (e != null && !entries.any((x) => x.id == e.id)) entries.add(e);
      }
      return SpeechModelManifest(entries);
    } on FormatException {
      return null;
    }
  }
}

/// The `.part.json` sidecar: `{url, bytes, sha256, written, updatedAt, catalogRevision}`.
@immutable
final class PartialSidecar {
  /// Creates a sidecar.
  const PartialSidecar({
    required this.url,
    required this.bytes,
    required this.sha256,
    required this.written,
    required this.updatedAt,
    required this.catalogRevision,
  });

  /// The catalog URL the partial belongs to (the signed CDN URL is never stored).
  final String url;

  /// Expected final size.
  final int bytes;

  /// Expected SHA-256.
  final String sha256;

  /// Bytes written when the sidecar was last updated (the part file may hold more).
  final int written;

  /// Last update (UTC).
  final DateTime updatedAt;

  /// Catalog revision the download started under.
  final int catalogRevision;

  /// JSON text.
  String encode() => jsonEncode({
        'url': url,
        'bytes': bytes,
        'sha256': sha256,
        'written': written,
        'updatedAt': updatedAt.toUtc().toIso8601String(),
        'catalogRevision': catalogRevision,
      });

  /// Parses [text]; null when malformed.
  static PartialSidecar? tryDecode(String text) {
    try {
      final raw = jsonDecode(text);
      if (raw is! Map) return null;
      final url = raw['url'];
      final bytes = raw['bytes'];
      final sha = raw['sha256'];
      final written = raw['written'];
      final updatedAt = _date(raw['updatedAt']);
      final rev = raw['catalogRevision'];
      if (url is! String || bytes is! int || sha is! String || written is! int || written < 0 || updatedAt == null || rev is! int) {
        return null;
      }
      return PartialSidecar(url: url, bytes: bytes, sha256: sha.toLowerCase(), written: written, updatedAt: updatedAt, catalogRevision: rev);
    } on FormatException {
      return null;
    }
  }

  /// Reads the sidecar at [path]; null when missing or malformed.
  static Future<PartialSidecar?> read(String path) async {
    try {
      return tryDecode(await File(path).readAsString());
    } on FileSystemException {
      return null;
    }
  }
}

/// Writes [text] to [path] through a temp file and an atomic rename.
Future<void> writeStringAtomic(String path, String text) async {
  final tmp = File('$path.tmp');
  await tmp.writeAsString(text, flush: true);
  await tmp.rename(path);
}

DateTime? _date(Object? raw) => raw is String ? DateTime.tryParse(raw)?.toUtc() : null;
