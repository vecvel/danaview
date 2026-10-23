// OWNER: HOM-24
//
// PDF text extraction for the on-device search index (ARCH v1.2 §7.6, §8 "PDF text (search)"):
// `PDFPage.string` on Apple (HOM-24), PdfRenderer text where Android has it (HOM-25). AIS-50's
// `DocumentTextPort` is implemented at the app root over [PdfTextExtractor] (rule 24). Files are
// opened read-only (rule 27); the text is returned, never logged (rule 30).

import 'package:flutter/foundation.dart';

import 'pigeon/pdf_api.g.dart';
import 'pigeon/pdf_channels.dart';

/// The text of one page.
@immutable
final class PdfPageText {
  /// Text of page [pageIndex].
  const PdfPageText(this.pageIndex, this.text);

  /// The page.
  final int pageIndex;

  /// Its text; empty for a page without a text layer.
  final String text;

  // Never prints the text (rule 30).
  @override
  String toString() => 'PdfPageText($pageIndex, ${text.length} chars)';
}

/// The text of a page range.
@immutable
final class PdfTextResult {
  /// A result.
  const PdfTextResult({required this.documentPageCount, required this.pages, this.truncated = false});

  /// Pages in the document.
  final int documentPageCount;

  /// The pages read, in order.
  final List<PdfPageText> pages;

  /// The character limit was reached.
  final bool truncated;
}

/// Extracts text. Implementations: [PlatformPdfTextExtractor]; tests fake it.
abstract interface class PdfTextExtractor {
  /// The text of [pageCount] pages (null: to the end) from [firstPage] of the file at [path];
  /// stops after [maxChars] UTF-16 units in total when given.
  Future<PdfTextResult> extractText(String path, {String? password, int firstPage = 0, int? pageCount, int? maxChars});
}

/// [PdfTextExtractor] over the plugin.
final class PlatformPdfTextExtractor implements PdfTextExtractor {
  /// An extractor over the default engine, or [api] (tests).
  PlatformPdfTextExtractor({PdfTextHostApi? api}) : _api = api ?? PdfTextHostApi();

  final PdfTextHostApi _api;

  @override
  Future<PdfTextResult> extractText(String path, {String? password, int firstPage = 0, int? pageCount, int? maxChars}) async {
    final r = await guardPdf(
      () => _api.extractText(
        PdfTextRequestMsg(path: path, password: password, firstPage: firstPage, pageCount: pageCount ?? -1, maxChars: maxChars ?? -1),
      ),
    );
    return PdfTextResult(
      documentPageCount: r.documentPageCount,
      pages: [for (final p in r.pages) PdfPageText(p.pageIndex, p.text)],
      truncated: r.truncated,
    );
  }
}
