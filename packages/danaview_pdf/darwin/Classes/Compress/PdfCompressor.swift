// OWNER: HOM-31
//
// Placeholder (D-33) created by HOM-24 (ARCH v1.2 V2-25). HOM-31 replaces this file: PDFKit
// `write(to:withOptions:)` compression presets into a new file. Until then every method answers
// notSupportedOnDevice.

import Foundation

/// Compress (HOM-31).
final class PdfCompressor {
  /// The tools of this class that work here (PdfCapabilitiesMsg.tools); none until the ticket lands.
  static let supported: [PdfToolKindMsg] = []

  func compress(_ request: PdfCompressRequestMsg, job: PdfJob, completion: @escaping (Result<PdfToolResultMsg, Error>) -> Void) {
    completion(.failure(PdfErrors.notSupported("HOM-31")))
  }
}
