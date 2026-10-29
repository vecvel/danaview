// OWNER: HOM-20
//
// The document facts the import pipeline records in `entry_meta` (ARCH v1.2 §5.3, §5.6; HOM-18's
// Documents row "size · date · N pages"; FIX-S3Q-4): a PDF's page count, read after the copy by a
// [DocumentPageCounter] the app supplies (`danaview_pdf`'s probe: PDFKit on iOS and macOS,
// `PdfRenderer` on Android, both on a native background thread, so the file is never opened on
// the UI isolate). Without a counter (Windows, Linux, tests) nothing is read.
//
// [backfillPageCounts] fills the count in lazily for PDFs imported before this landed: a bounded
// number of entries per run, one probe at a time.
//
// Rules: the file is opened for reading only; a counter that throws, hangs past [pageCountTimeout]
// or answers a non-positive count (locked, damaged) leaves the fact unset and never fails the
// import; nothing is logged (rule 30).

import 'dart:async';

import '../classify/classifier.dart' show FileClass;
import '../db/library_folder.dart' show EntryMeta;
import '../model/document_item.dart' show DocumentKind;
import '../model/file_kind.dart' show FileKind;
import '../model/ids.dart' show EntryId;
import '../store/library_store.dart' show LibraryStore;

/// Counts the pages of the document at [path] (read-only, off the UI isolate); null or a value
/// below 1 when it can't tell (locked, damaged, not supported).
typedef DocumentPageCounter = Future<int?> Function(String path);

/// How long one page count may take before the fact is left unset.
const Duration pageCountTimeout = Duration(seconds: 10);

/// The most entries one [backfillPageCounts] run probes.
const int pageCountBackfillLimit = 200;

/// True when [kind] is a document whose page count [DocumentPageCounter] reads (PDF).
bool countsPages(FileClass kind) => kind.kind == FileKind.document && kind.docKind == DocumentKind.pdf;

/// The page count of the document at [path] from [count], or null (never throws).
Future<int?> readPageCount(String path, DocumentPageCounter count, {Duration timeout = pageCountTimeout}) async {
  try {
    final pages = await count(path).timeout(timeout);
    return pages != null && pages > 0 ? pages : null;
  } on Object {
    return null;
  }
}

/// The `entry_meta` row for a document of class [kind] whose bytes are at [path], or null when
/// [count] is null, the class has no page count, or the count can't be read (never throws).
Future<EntryMeta?> documentEntryMeta(String path, FileClass kind, DocumentPageCounter? count, {Duration timeout = pageCountTimeout}) async {
  if (count == null || !countsPages(kind)) return null;
  final pages = await readPageCount(path, count, timeout: timeout);
  return pages == null ? null : EntryMeta(pageCount: pages);
}

/// Records the page count of the PDFs in [store] that have none (imported before FIX-S3Q-4), at
/// most [limit] per run, oldest first; returns how many it recorded. Stops when the store closes;
/// never throws.
Future<int> backfillPageCounts(LibraryStore store, DocumentPageCounter count, {int limit = pageCountBackfillLimit, Duration timeout = pageCountTimeout}) async {
  final List<({EntryId id, String name})> todo;
  try {
    if (store.readOnly) return 0;
    final rows = store.reader.db.select(
      'SELECT e.id, e.display_name FROM entries e LEFT JOIN entry_meta m ON m.entry_id = e.id '
      'WHERE e.trashed_at IS NULL AND e.kind = ? AND e.sub_kind = ? AND m.page_count IS NULL '
      'ORDER BY e.added_at, e.id LIMIT ?',
      [FileKind.document.code, DocumentKind.pdf.code, limit],
    );
    todo = [for (final r in rows) (id: EntryId.parse(r['id'] as String), name: r['display_name'] as String)];
  } on Object {
    return 0;
  }
  var recorded = 0;
  for (final e in todo) {
    final pages = await readPageCount(store.paths.entryFile(e.id, e.name), count, timeout: timeout);
    if (pages == null) continue;
    try {
      final id = e.id;
      await store.write((w, _) => w.setPageCount(id, pages));
      recorded++;
    } on StateError {
      return recorded; // the store closed
    } on Object {
      // Trashed or deleted meanwhile: skip it.
    }
  }
  return recorded;
}
