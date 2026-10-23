// OWNER: HOM-23
//
// What the viewer router opens (HOM plan §8.4, ARCH §3): a readable local file with the facts the
// router, the viewers and the file card need. Built from a Danaview folder entry (with its path in
// the store) or from a MediaItem (linked-folder files, incoming files). `toString` never prints the
// name or the path (rule 30).

import 'package:danaview_library/danaview_library.dart';
import 'package:flutter/foundation.dart';

/// The platforms of ARCH §3's matrix.
enum ViewerPlatform {
  /// iPhone and iPad.
  iOS,

  /// Android phones and tablets.
  android,

  /// macOS.
  macOS,

  /// Windows.
  windows,

  /// Linux.
  linux;

  /// The viewer platform of a Flutter [TargetPlatform] (Fuchsia counts as Linux).
  static ViewerPlatform of(TargetPlatform platform) => switch (platform) {
        TargetPlatform.iOS => ViewerPlatform.iOS,
        TargetPlatform.android => ViewerPlatform.android,
        TargetPlatform.macOS => ViewerPlatform.macOS,
        TargetPlatform.windows => ViewerPlatform.windows,
        TargetPlatform.linux || TargetPlatform.fuchsia => ViewerPlatform.linux,
      };

  /// True on iOS and macOS (PDFKit and Quick Look).
  bool get isApple => this == ViewerPlatform.iOS || this == ViewerPlatform.macOS;
}

/// A file to open in a viewer.
@immutable
final class ViewerFile {
  /// A file at the absolute local [path].
  const ViewerFile({
    required this.path,
    required this.displayName,
    required this.kind,
    this.docKind,
    this.id,
    this.sizeBytes,
    this.addedAt,
    this.modifiedAt,
    this.mime,
    this.uti,
    this.pageCount,
    this.textEncoding,
  });

  /// A Danaview folder [entry] whose file is at [path] (`LibraryPaths.entryFile`).
  factory ViewerFile.fromEntry(FileEntry entry, String path, {String? mime, String? uti, int? pageCount}) => ViewerFile(
        path: path,
        displayName: entry.displayName,
        kind: entry.kind,
        docKind: entry.docKind,
        id: entry.id,
        sizeBytes: entry.sizeBytes,
        addedAt: entry.addedAt,
        modifiedAt: entry.modifiedAt,
        mime: mime,
        uti: uti,
        pageCount: pageCount,
      );

  /// A library [item] whose `uri` is a local path (or a `file://` URI).
  factory ViewerFile.fromItem(MediaItem item) {
    final uri = item.uri;
    final path = uri.startsWith('file://') ? Uri.parse(uri).toFilePath() : uri;
    final mime = item.mimeType == 'application/octet-stream' ? null : item.mimeType;
    return switch (item) {
      final DocumentItem d => ViewerFile(
          path: path,
          displayName: item.name,
          kind: FileKind.document,
          docKind: d.docKind,
          id: item.id,
          sizeBytes: item.sizeBytes,
          modifiedAt: item.modifiedAt,
          mime: mime,
          pageCount: d.pageCount,
          textEncoding: d.textEncoding,
        ),
      _ => ViewerFile(
          path: path,
          displayName: item.name,
          kind: item.kind,
          id: item.id,
          sizeBytes: item.sizeBytes,
          modifiedAt: item.modifiedAt,
          mime: mime,
        ),
    };
  }

  /// Absolute local path of the readable file.
  final String path;

  /// The name shown.
  final String displayName;

  /// The Home kind.
  final FileKind kind;

  /// The Documents sub-filter, for documents.
  final DocumentKind? docKind;

  /// The library id (`fe_` for Danaview folder files, `lk:` for linked files), when known.
  final ItemId? id;

  /// Size in bytes, when known.
  final int? sizeBytes;

  /// When it was added to Danaview.
  final DateTime? addedAt;

  /// Last modification time.
  final DateTime? modifiedAt;

  /// MIME type, when known.
  final String? mime;

  /// Apple UTType, when known.
  final String? uti;

  /// Page count, when known.
  final int? pageCount;

  /// Stored text encoding (`utf-8`, …), when known.
  final String? textEncoding;

  /// The Danaview folder entry id (null for linked and incoming files): what Recents records.
  EntryId? get entryId => id?.asEntry;

  /// The lower-case extension without the dot, or null.
  String? get extension => extensionOf(displayName) ?? extensionOf(path);

  /// The [docKind], or the classifier's answer for a document without one.
  DocumentKind? get effectiveDocKind =>
      docKind ??
      (kind == FileKind.document || kind == FileKind.other ? classify(uti: uti, mime: mime, fileName: displayName).docKind : null);

  /// True for comma-, semicolon- or tab-separated values (by extension or MIME type).
  bool get isDelimited {
    final ext = extension;
    final m = normalizeMime(mime);
    return ext == 'csv' || ext == 'tsv' || ext == 'tab' || m == 'text/csv' || m == 'text/tab-separated-values';
  }

  /// True for tab-separated values.
  bool get isTabSeparated => extension == 'tsv' || extension == 'tab' || normalizeMime(mime) == 'text/tab-separated-values';

  /// The [OutFile] handed to share and "Open in another app".
  OutFile get outFile => OutFile(path: path, displayName: displayName, mime: mime, uti: uti);

  @override
  bool operator ==(Object other) =>
      other is ViewerFile &&
      other.path == path &&
      other.displayName == displayName &&
      other.kind == kind &&
      other.docKind == docKind &&
      other.id == id;

  @override
  int get hashCode => Object.hash(path, displayName, kind, docKind, id);

  // Never prints the name or the path (rule 30).
  @override
  String toString() => 'ViewerFile(${kind.name}${docKind == null ? '' : '/${docKind!.name}'})';
}
