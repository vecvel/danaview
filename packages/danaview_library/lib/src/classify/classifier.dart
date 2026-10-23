// OWNER: HOM-16
//
// The classifier (ARCH v1.2 §5.1, HOM plan §8.1, V2-114): `classify(uti?, mime?, fileName)` looks
// the inputs up in the type table in order UTType (Apple) → MIME (Android, desktop) → extension.
// An input that is missing, generic (`public.data`, `dyn.…`, `application/octet-stream`, …) or
// matched by no row defers to the next one; the first input a row matches decides, so a specific
// UTType wins over a conflicting MIME type and a specific MIME type over a conflicting extension.
// Nothing matched → Documents › Other. Pure and allocation-light: the lookup maps are built once.

import 'package:meta/meta.dart';

import '../model/document_item.dart';
import '../model/file_kind.dart';
import 'type_table.dart';

/// Which input decided a [FileClass].
enum ClassifiedBy {
  /// The UTType matched a row.
  uti,

  /// The MIME type matched a row exactly.
  mime,

  /// The MIME type matched a row's `family/*` prefix.
  mimeFamily,

  /// The file extension matched a row.
  extension,

  /// Nothing matched; the fallback row (Documents › Other).
  fallback,
}

/// The result of [classify].
@immutable
final class FileClass {
  /// A result for [row], decided by [decidedBy].
  const FileClass(this.row, this.decidedBy);

  /// The matched type-table row.
  final TypeRow row;

  /// Which input decided.
  final ClassifiedBy decidedBy;

  /// The Home kind.
  FileKind get kind => row.kind;

  /// The Documents sub-filter (null unless [kind] is [FileKind.document]).
  DocumentKind? get docKind => row.docKind;

  /// The `sub_kind` to store (the [docKind] code, or null).
  String? get subKind => row.docKind?.code;

  @override
  bool operator ==(Object other) => other is FileClass && other.row.id == row.id && other.decidedBy == decidedBy;

  @override
  int get hashCode => Object.hash(row.id, decidedBy);

  @override
  String toString() => 'FileClass(${row.id} by ${decidedBy.name})';
}

final Map<String, TypeRow> _byUti = _index((r) => r.utis);
final Map<String, TypeRow> _byMime = _index((r) => r.mimes);
final Map<String, TypeRow> _byMimePrefix = _index((r) => r.mimePrefixes);
final Map<String, TypeRow> _byExtension = _index((r) => r.extensions);

Map<String, TypeRow> _index(Set<String> Function(TypeRow) values) => {
      for (final row in typeTable)
        for (final v in values(row)) v: row,
    };

/// True when [uti] says nothing about the content (missing, empty, [genericUtis] or dynamic).
bool isGenericUti(String? uti) {
  final u = uti?.trim().toLowerCase() ?? '';
  return u.isEmpty || genericUtis.contains(u) || u.startsWith('dyn.');
}

/// True when [mime] says nothing about the content (missing, empty, malformed or [genericMimes]).
bool isGenericMime(String? mime) {
  final m = normalizeMime(mime);
  return m == null || genericMimes.contains(m);
}

/// [mime] lower-cased without parameters (`text/plain; charset=utf-8` → `text/plain`); null when
/// missing or not of the form `type/subtype`.
String? normalizeMime(String? mime) {
  if (mime == null) return null;
  final m = mime.split(';').first.trim().toLowerCase();
  final slash = m.indexOf('/');
  if (slash <= 0 || slash == m.length - 1 || m.indexOf('/', slash + 1) >= 0) return null;
  return m;
}

/// The lower-case extension of [fileName] without the dot, or null when it has none. Directory
/// parts (`/` or `\`) are ignored; a leading-dot name such as `.bashrc` has no extension.
String? extensionOf(String fileName) {
  final name = fileName.split(RegExp(r'[/\\]')).last.trim();
  final dot = name.lastIndexOf('.');
  if (dot <= 0 || dot == name.length - 1) return null;
  return name.substring(dot + 1).toLowerCase();
}

/// Classifies a file by its UTType [uti] (Apple), MIME type [mime] (Android, desktop) and
/// [fileName], in that order (ARCH v1.2 §5.1). Generic or unknown inputs defer to the next one;
/// with nothing matched the file is a document under `Other`.
FileClass classify({String? uti, String? mime, required String fileName}) {
  if (!isGenericUti(uti)) {
    final row = _byUti[uti!.trim().toLowerCase()];
    if (row != null) return FileClass(row, ClassifiedBy.uti);
  }
  if (!isGenericMime(mime)) {
    final m = normalizeMime(mime)!;
    final exact = _byMime[m];
    if (exact != null) return FileClass(exact, ClassifiedBy.mime);
    final family = _byMimePrefix[m.substring(0, m.indexOf('/') + 1)];
    if (family != null) return FileClass(family, ClassifiedBy.mimeFamily);
  }
  final ext = extensionOf(fileName);
  if (ext != null) {
    final row = _byExtension[ext];
    if (row != null) return FileClass(row, ClassifiedBy.extension);
  }
  return FileClass(fallbackRow, ClassifiedBy.fallback);
}

/// The Documents sub-filter an item of [kind] with stored [subKind] appears under, or null when it
/// isn't under Documents (videos, photos, audio). Kinds this build doesn't know ([FileKind.other],
/// e.g. 1.3.0 `savedCode`) show under `Other` so they stay reachable as files.
DocumentKind? documentSubFilterOf(FileKind kind, String? subKind) => switch (kind) {
      FileKind.document => DocumentKind.decode(subKind),
      FileKind.other => DocumentKind.other,
      FileKind.video || FileKind.photo || FileKind.audio => null,
    };
