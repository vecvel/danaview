// OWNER: HOM-30
//
// Placeholder (D-33) created by HOM-24 (ARCH v1.2 V2-25). HOM-30 replaces this file: visual
// signatures burned into the page content of a new file. Until then every method answers
// notSupportedOnDevice.

import Foundation

/// Sign (HOM-30).
final class PdfSigner {
  /// The tools of this class that work here (PdfCapabilitiesMsg.tools); none until the ticket lands.
  static let supported: [PdfToolKindMsg] = []

  func sign(_ request: PdfSignRequestMsg, job: PdfJob, completion: @escaping (Result<PdfToolResultMsg, Error>) -> Void) {
    completion(.failure(PdfErrors.notSupported("HOM-30")))
  }
}
