// OWNER: HOM-29
//
// Placeholder (D-33) created by HOM-24 (ARCH v1.2 V2-25). HOM-29 replaces this file: PDFKit
// highlight, underline, strike-out, ink, free text and notes written into a new file. Until then
// every method answers notSupportedOnDevice.

import Foundation

/// Annotate and highlight (HOM-29).
final class PdfAnnotator {
  /// The tools of this class that work here (PdfCapabilitiesMsg.tools); none until the ticket lands.
  static let supported: [PdfToolKindMsg] = []

  func annotate(_ request: PdfAnnotateRequestMsg, job: PdfJob, completion: @escaping (Result<PdfToolResultMsg, Error>) -> Void) {
    completion(.failure(PdfErrors.notSupported("HOM-29")))
  }
}
