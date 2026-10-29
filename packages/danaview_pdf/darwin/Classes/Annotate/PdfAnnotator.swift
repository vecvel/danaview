// OWNER: HOM-29
//
// Annotate and highlight on Apple (HOM plan §8.5, D-98j): the Pigeon side of
// Annotate/PdfAnnotateCore.swift. `PdfToolsHostApi.annotate` (frozen) and the HOM-29 amendment's
// `PdfAnnotateHostApi.save` (with image stamps and burn-in, HOM-30's hooks) run here as tool jobs
// of kind annotate (progress events, cancel through `PdfToolsHostApi.cancel`). Work runs on a
// background queue with its own PDFDocument and replies on the main thread; a cancelled or failed
// job leaves no file at `outPath`.

import CoreGraphics
import Foundation

#if os(iOS)
import Flutter
#elseif os(macOS)
import FlutterMacOS
#endif

/// Annotate and highlight (HOM-29).
final class PdfAnnotator {
  /// The tools of this class that work here (PdfCapabilitiesMsg.tools).
  static let supported: [PdfToolKindMsg] = [.annotate]

  private let queue = DispatchQueue(label: "com.vecvel.danaview.pdf.annotate", qos: .userInitiated, attributes: .concurrent)

  /// The core spec of [m].
  static func spec(_ m: PdfAnnotationMsg) throws -> PdfAnnotationSpec {
    guard let kind = PdfAnnotationKind(rawValue: m.kind.rawValue) else { throw PdfFailure(.invalidArgument, "unknown kind") }
    guard let page = Int(exactly: m.pageIndex) else { throw PdfFailure(.invalidArgument, "page out of range") }
    let strokes: [[CGPoint]] = try m.strokes.map { stroke in
      guard stroke.points.count % 2 == 0 else { throw PdfFailure(.invalidArgument, "odd stroke coordinates") }
      return stride(from: 0, to: stroke.points.count, by: 2).map { CGPoint(x: stroke.points[$0], y: stroke.points[$0 + 1]) }
    }
    return PdfAnnotationSpec(
      kind: kind, pageIndex: page, rects: m.rects.map(rect), strokes: strokes,
      colorArgb: UInt32(truncatingIfNeeded: m.colorArgb), lineWidth: CGFloat(m.lineWidth), text: m.text)
  }

  /// The core spec of [m].
  static func stamp(_ m: PdfSignatureStampMsg) throws -> PdfStampSpec {
    guard let page = Int(exactly: m.pageIndex) else { throw PdfFailure(.invalidArgument, "page out of range") }
    return PdfStampSpec(pageIndex: page, rect: rect(m.rect), imagePath: m.imagePath, rotationDegrees: CGFloat(m.rotationDegrees))
  }

  static func rect(_ m: PdfRectMsg) -> CGRect { CGRect(x: m.x, y: m.y, width: m.width, height: m.height) }

  func annotate(_ request: PdfAnnotateRequestMsg, job: PdfJob, completion: @escaping (Result<PdfToolResultMsg, Error>) -> Void) {
    save(PdfAnnotateSaveRequestMsg(
      jobId: request.jobId, input: request.input, annotations: request.annotations, stamps: [], burnIn: false, outPath: request.outPath),
      job: job, completion: completion)
  }

  func save(_ request: PdfAnnotateSaveRequestMsg, job: PdfJob, completion: @escaping (Result<PdfToolResultMsg, Error>) -> Void) {
    queue.async {
      let result: Result<PdfToolResultMsg, Error>
      do {
        let file = try autoreleasepool {
          try PdfAnnotateCore.annotate(
            PdfPageTools.source(request.input),
            annotations: try request.annotations.map(PdfAnnotator.spec),
            stamps: try request.stamps.map(PdfAnnotator.stamp),
            burnIn: request.burnIn, outPath: request.outPath, control: job)
        }
        result = .success(PdfToolResultMsg(outPaths: [file.path], pageCounts: [Int64(file.pageCount)], sizesBytes: [Int64(file.sizeBytes)]))
      } catch {
        result = .failure(PdfErrors.from(error))
      }
      DispatchQueue.main.async { completion(result) }
    }
  }
}
