// OWNER: HOM-16
//
// DocumentItem and DocumentKind (ARCH v1.2 §5.1, HOM plan §8.1). DocumentKind is also the
// Documents sub-filter list (`PDF`, `Word`, `Excel`, `PowerPoint`, `Text/CSV`, `Other`, V2-114) and
// the `sub_kind` stored for documents. DocumentItem fills HOM-01's DocumentMediaItem slot of the
// sealed MediaItem hierarchy.

import 'media_item.dart';

/// The type of a document, and the Documents sub-filter it appears under (V2-114). Append-only;
/// [code] is what `library.db` stores in `entries.sub_kind`.
enum DocumentKind {
  /// PDF.
  pdf('pdf', 'PDF'),

  /// Word processing: `.doc`, `.docx`, `.odt`, `.rtf`, `.pages`.
  word('word', 'Word'),

  /// Spreadsheets: `.xls`, `.xlsx`, `.ods`, `.numbers`.
  excel('excel', 'Excel'),

  /// Presentations: `.ppt`, `.pptx`, `.odp`, `.key`.
  powerpoint('powerpoint', 'PowerPoint'),

  /// Plain text and data: `.txt`, `.md`, `.csv`, `.tsv`, `.json`, `.log`, `text/*`.
  text('text', 'Text/CSV'),

  /// Anything else: archives, e-books, unknown types, and stored codes this build doesn't know.
  other('other', 'Other');

  const DocumentKind(this.code, this.filterLabel);

  /// The stable string stored in `library.db` (`entries.sub_kind`).
  final String code;

  /// The sub-filter chip label of HOM plan §8.1 (UI strings localise from this key).
  final String filterLabel;

  /// The document kind stored as [code], or null when this build doesn't know it.
  static DocumentKind? tryDecode(String code) {
    for (final kind in values) {
      if (kind.code == code) return kind;
    }
    return null;
  }

  /// The document kind stored as [code]; [DocumentKind.other] for an unknown or missing code.
  static DocumentKind decode(String? code) => code == null ? DocumentKind.other : tryDecode(code) ?? DocumentKind.other;
}

/// A document in the library (ARCH v1.2 §5.1): a Danaview folder file or a linked-folder file the
/// classifier put under Documents.
final class DocumentItem extends DocumentMediaItem {
  /// A document item. [pageCount] is null when unknown; [textEncoding] is set for text documents
  /// once detected (`utf-8`, `utf-16le`, …).
  DocumentItem({
    required super.id,
    required super.uri,
    required super.name,
    required super.modifiedAt,
    required super.mimeType,
    super.sizeBytes,
    this.docKind = DocumentKind.other,
    this.pageCount,
    this.textEncoding,
  }) {
    if (pageCount != null && pageCount! < 0) throw ArgumentError.value(pageCount, 'pageCount', 'negative');
  }

  /// The document type and sub-filter.
  final DocumentKind docKind;

  /// Number of pages (PDF, slides, …), when known.
  final int? pageCount;

  /// Detected text encoding of a text document, when known.
  final String? textEncoding;

  /// The `sub_kind` stored for this document.
  String get subKind => docKind.code;

  /// A copy with the given fields replaced (the id stays, so the copy equals this item).
  DocumentItem copyWith({
    String? uri,
    String? name,
    DateTime? modifiedAt,
    String? mimeType,
    int? sizeBytes,
    DocumentKind? docKind,
    int? pageCount,
    String? textEncoding,
  }) =>
      DocumentItem(
        id: id,
        uri: uri ?? this.uri,
        name: name ?? this.name,
        modifiedAt: modifiedAt ?? this.modifiedAt,
        mimeType: mimeType ?? this.mimeType,
        sizeBytes: sizeBytes ?? this.sizeBytes,
        docKind: docKind ?? this.docKind,
        pageCount: pageCount ?? this.pageCount,
        textEncoding: textEncoding ?? this.textEncoding,
      );
}
