// OWNER: HOM-21
//
// "Open with Danaview" (ARCH v1.2 §5.6, V2-116, P-7, P-8): what the app does with a file or link
// another app (or Finder, or the command line) hands it. Videos, audio, streams, `danaview://`
// links and anything unrecognised keep the 1.1 path and play at once; photos and documents are
// imported into `Imported` (a copy, `sourceHint = openWith`; the source is never changed, rule 27)
// and opened in their viewer. Opening the same file again opens the entry already in the library
// instead of adding a copy.
//
// Nothing here logs the link, the name or the path (rule 30).

import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;

import '../classify/classifier.dart';
import '../import/import_service.dart';
import '../import/import_source.dart';
import '../model/file_entry.dart';
import '../model/file_kind.dart';
import '../model/source_hint.dart';

/// Where an incoming file or link goes.
enum IncomingRoute {
  /// The player, as in 1.1 (videos, audio, streams, `danaview://`, anything unrecognised).
  play,

  /// Import into `Imported`, then open in the viewer (photos and documents).
  importAndView,
}

/// The local path of an incoming [raw] value (a path or a `file://` URI), or null for a link.
String? incomingLocalPath(String raw) {
  final s = raw.trim();
  if (s.isEmpty) return null;
  if (s.startsWith('file://')) {
    try {
      return Uri.parse(s).toFilePath();
    } on Object {
      return null;
    }
  }
  if (s.startsWith('/') || RegExp(r'^[A-Za-z]:[\\/]').hasMatch(s) || s.startsWith(r'\\')) return s;
  return null;
}

/// The route of an incoming [raw] value (a path, a `file://` URI or a link).
IncomingRoute routeIncoming(String raw) {
  final path = incomingLocalPath(raw);
  if (path == null) return IncomingRoute.play; // streams, danaview:// links, other schemes
  if (path.endsWith('/') || path.endsWith('\\')) return IncomingRoute.play; // a folder (P-8)
  final name = p.basename(path);
  if (name.isEmpty) return IncomingRoute.play;
  // Only a recognised photo or document type imports; an unknown type keeps the 1.1 path.
  final c = classify(fileName: name);
  if (c.decidedBy == ClassifiedBy.fallback) return IncomingRoute.play;
  return c.kind == FileKind.photo || c.kind == FileKind.document ? IncomingRoute.importAndView : IncomingRoute.play;
}

/// The outcome of [IncomingOpenImporter.importForViewing].
@immutable
final class IncomingImport {
  /// An outcome.
  const IncomingImport({required this.item, this.entry});

  /// The import item (done, skipped as a duplicate, or failed).
  final ImportItem item;

  /// The entry to open: the new one, or the one with the same content already in the library;
  /// null when the import failed.
  final FileEntry? entry;

  @override
  String toString() => 'IncomingImport(${item.state.name})';
}

/// Imports incoming photos and documents for viewing.
final class IncomingOpenImporter {
  /// An importer over [imports]. [isAppOwnedCopy] tells whether a path is a copy the system made
  /// for the app (iOS `Documents/Inbox/`, a `*-Inbox` temporary folder): such a copy is deleted
  /// after the import; any other source is only read.
  IncomingOpenImporter({required this.imports, bool Function(String path)? isAppOwnedCopy})
      : _isAppOwnedCopy = isAppOwnedCopy ?? _never;

  /// The import queue.
  final ImportService imports;

  final bool Function(String path) _isAppOwnedCopy;

  static bool _never(String _) => false;

  /// Imports [raw] into `Imported` and returns the entry to open; null when [raw] is not a photo
  /// or a document ([routeIncoming] says play).
  Future<IncomingImport?> importForViewing(String raw) async {
    if (routeIncoming(raw) != IncomingRoute.importAndView) return null;
    final path = incomingLocalPath(raw)!;
    final source = ImportSource.file(path, sourceHint: SourceHint.openWith, stagedCopy: _isAppOwnedCopy(path));
    final item = await imports.result(imports.enqueue(source, duplicates: DuplicatePolicy.skip));
    return IncomingImport(item: item, entry: item.entry ?? item.duplicateOf);
  }
}
