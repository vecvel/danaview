// OWNER: HOM-30
//
// Sign on Apple (HOM plan §8.5, D-98j): visual signatures (an image, not a certificate) burned into
// the page content of a NEW file. The frozen `PdfToolsHostApi.sign` is the annotate save with the
// request's stamps and `burnIn: true` (Annotate/PdfAnnotateCore.annotate, HOM-29's hook): each
// signed page is redrawn by Quartz into a one-page PDF with the signature images over its own
// content (text stays text), then the page's boxes, rotation and own annotations are carried over
// and the outline and links re-pointed; no Stamp annotation is left. The Dart sign mode saves
// through `PdfAnnotateHostApi.save` with the same arguments. The source is opened read-only, an
// encrypted source gives an output encrypted with its password, and a cancelled or failed job
// leaves no file. Nothing is logged (rule 30).

import Foundation

/// Sign (HOM-30).
final class PdfSigner {
  /// The tools of this class that work here (PdfCapabilitiesMsg.tools): the save below and the
  /// viewer's `place` input (Annotate/PdfAnnotateView.swift).
  static let supported: [PdfToolKindMsg] = [.sign]

  private let annotator: PdfAnnotator

  init(annotator: PdfAnnotator = PdfAnnotator()) {
    self.annotator = annotator
  }

  /// The annotate save that [request] is.
  static func saveRequest(_ request: PdfSignRequestMsg) -> PdfAnnotateSaveRequestMsg {
    PdfAnnotateSaveRequestMsg(
      jobId: request.jobId, input: request.input, annotations: [], stamps: request.stamps, burnIn: true, outPath: request.outPath)
  }

  func sign(_ request: PdfSignRequestMsg, job: PdfJob, completion: @escaping (Result<PdfToolResultMsg, Error>) -> Void) {
    guard !request.stamps.isEmpty else {
      completion(.failure(PdfErrors.error(.invalidArgument, "nothing to sign")))
      return
    }
    annotator.save(PdfSigner.saveRequest(request), job: job, completion: completion)
  }
}
