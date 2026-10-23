// OWNER: HOM-24
//
// PdfTextHostApi on Apple: `PDFPage.string` of a page range for the search index, read on a
// background queue from a read-only open of the file (rule 27). Document text is returned to Dart
// and never logged (rule 30).

import Foundation

#if os(iOS)
import Flutter
#elseif os(macOS)
import FlutterMacOS
#endif

final class PdfTextHostApiImpl: PdfTextHostApi {
  private let queue = DispatchQueue(label: "com.vecvel.danaview.pdf.text", qos: .utility)

  func extractText(request: PdfTextRequestMsg, completion: @escaping (Result<PdfTextResultMsg, Error>) -> Void) {
    queue.async {
      do {
        let result = try PdfTextExtractor.extract(
          path: request.path, password: request.password, firstPage: Int(request.firstPage),
          pageCount: Int(request.pageCount), maxChars: Int(request.maxChars))
        completion(.success(PdfTextResultMsg(
          documentPageCount: Int64(result.documentPageCount),
          pages: result.pages.map { PdfPageTextMsg(pageIndex: Int64($0.index), text: $0.text) },
          truncated: result.truncated)))
      } catch {
        completion(.failure(PdfErrors.from(error)))
      }
    }
  }
}
