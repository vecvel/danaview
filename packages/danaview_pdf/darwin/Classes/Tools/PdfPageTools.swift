// OWNER: HOM-28
//
// Placeholder (D-33) created by HOM-24 (ARCH v1.2 V2-25). HOM-28 replaces this file: PDFKit merge,
// split, reorder, rotate and delete (`insert`, `exchangePage`, `removePage`, `rotation`,
// `write(to:)`) off the main thread, polling `job.isCancelled` between pages, reporting
// `job.progress`, writing only the request's new file(s) and deleting them on cancel or failure.
// Until then every method answers notSupportedOnDevice.

import Foundation

/// The page tools (HOM-28).
final class PdfPageTools {
  /// The tools of this class that work here (PdfCapabilitiesMsg.tools); none until the ticket lands.
  static let supported: [PdfToolKindMsg] = []

  func merge(_ request: PdfMergeRequestMsg, job: PdfJob, completion: @escaping (Result<PdfToolResultMsg, Error>) -> Void) {
    completion(.failure(PdfErrors.notSupported("HOM-28")))
  }

  func split(_ request: PdfSplitRequestMsg, job: PdfJob, completion: @escaping (Result<PdfToolResultMsg, Error>) -> Void) {
    completion(.failure(PdfErrors.notSupported("HOM-28")))
  }

  func reorder(_ request: PdfReorderRequestMsg, job: PdfJob, completion: @escaping (Result<PdfToolResultMsg, Error>) -> Void) {
    completion(.failure(PdfErrors.notSupported("HOM-28")))
  }

  func rotate(_ request: PdfRotateRequestMsg, job: PdfJob, completion: @escaping (Result<PdfToolResultMsg, Error>) -> Void) {
    completion(.failure(PdfErrors.notSupported("HOM-28")))
  }

  func deletePages(_ request: PdfDeletePagesRequestMsg, job: PdfJob, completion: @escaping (Result<PdfToolResultMsg, Error>) -> Void) {
    completion(.failure(PdfErrors.notSupported("HOM-28")))
  }
}
