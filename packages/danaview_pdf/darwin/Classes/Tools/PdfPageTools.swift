// OWNER: HOM-28
//
// The page tools behind PdfToolsHostApi (merge, split, reorder, rotate, deletePages) and the
// HOM-28 amendment's PdfOrganiseHostApi (pigeons/pdf_api.dart) on iOS and macOS. Each request runs
// on a background queue with its own PDFDocument instances (PdfPageToolsCore: PDFKit `insert`,
// `exchangePage`, `removePage`, `PDFPage.rotation`, `write(to:)`), polls its job's cancel flag
// between pages, reports progress through the job, and replies on the main thread (Flutter's
// channel threading rule). Sources are opened read-only; a cancelled or failed job leaves no file.

import Foundation

#if os(iOS)
import Flutter
#elseif os(macOS)
import FlutterMacOS
#endif

extension PdfJob: PdfToolControl {}

/// The page tools (HOM-28).
final class PdfPageTools {
  /// The tools of this class that work here (PdfCapabilitiesMsg.tools). reorder + rotate +
  /// deletePages together also advertise PdfOrganiseHostApi.
  static let supported: [PdfToolKindMsg] = [.merge, .split, .reorder, .rotate, .deletePages]

  private let queue = DispatchQueue(label: "com.vecvel.danaview.pdf.tools", qos: .userInitiated, attributes: .concurrent)

  private func background(_ completion: @escaping (Result<PdfToolResultMsg, Error>) -> Void, _ body: @escaping () throws -> [PdfWrittenFile]) {
    queue.async {
      let result: Result<PdfToolResultMsg, Error>
      do {
        let files = try autoreleasepool { try body() }
        result = .success(PdfToolResultMsg(
          outPaths: files.map(\.path),
          pageCounts: files.map { Int64($0.pageCount) },
          sizesBytes: files.map { Int64($0.sizeBytes) }))
      } catch {
        result = .failure(PdfErrors.from(error))
      }
      DispatchQueue.main.async { completion(result) }
    }
  }

  static func source(_ m: PdfToolInputMsg) -> PdfToolSource {
    PdfToolSource(path: m.path, password: m.password, isImage: m.isImage)
  }

  static func int(_ value: Int64) throws -> Int {
    guard let v = Int(exactly: value) else { throw PdfFailure(.invalidArgument, "number out of range") }
    return v
  }

  func merge(_ request: PdfMergeRequestMsg, job: PdfJob, completion: @escaping (Result<PdfToolResultMsg, Error>) -> Void) {
    background(completion) {
      [try PdfPageToolsCore.merge(request.inputs.map(PdfPageTools.source), outPath: request.outPath, control: job)]
    }
  }

  func split(_ request: PdfSplitRequestMsg, job: PdfJob, completion: @escaping (Result<PdfToolResultMsg, Error>) -> Void) {
    background(completion) {
      let ranges: [Range<Int>] = try request.ranges.map {
        let start = try PdfPageTools.int($0.start)
        let end = try PdfPageTools.int($0.end)
        guard start < end else { throw PdfFailure(.invalidArgument, "empty range") }
        return start..<end
      }
      return try PdfPageToolsCore.split(PdfPageTools.source(request.input), ranges: ranges, outPaths: request.outPaths, control: job)
    }
  }

  func reorder(_ request: PdfReorderRequestMsg, job: PdfJob, completion: @escaping (Result<PdfToolResultMsg, Error>) -> Void) {
    background(completion) {
      let input = PdfPageTools.source(request.input)
      let plan = try PdfPageToolsCore.reorderPlan(try request.order.map(PdfPageTools.int), pageCount: try PdfPageToolsCore.pageCount(input))
      return [try PdfPageToolsCore.organise(input, plan: plan, outPath: request.outPath, control: job)]
    }
  }

  func rotate(_ request: PdfRotateRequestMsg, job: PdfJob, completion: @escaping (Result<PdfToolResultMsg, Error>) -> Void) {
    background(completion) {
      let input = PdfPageTools.source(request.input)
      let plan = try PdfPageToolsCore.rotatePlan(
        try request.pages.map(PdfPageTools.int), degrees: try PdfPageTools.int(request.degrees),
        pageCount: try PdfPageToolsCore.pageCount(input))
      return [try PdfPageToolsCore.organise(input, plan: plan, outPath: request.outPath, control: job)]
    }
  }

  func deletePages(_ request: PdfDeletePagesRequestMsg, job: PdfJob, completion: @escaping (Result<PdfToolResultMsg, Error>) -> Void) {
    background(completion) {
      let input = PdfPageTools.source(request.input)
      let plan = try PdfPageToolsCore.deletePlan(try request.pages.map(PdfPageTools.int), pageCount: try PdfPageToolsCore.pageCount(input))
      return [try PdfPageToolsCore.organise(input, plan: plan, outPath: request.outPath, control: job)]
    }
  }

  func organise(_ request: PdfOrganiseRequestMsg, job: PdfJob, completion: @escaping (Result<PdfToolResultMsg, Error>) -> Void) {
    background(completion) {
      let plan = try request.pages.map { PdfPagePlanItem(try PdfPageTools.int($0.sourcePage), rotation: try PdfPageTools.int($0.rotation)) }
      return [try PdfPageToolsCore.organise(PdfPageTools.source(request.input), plan: plan, outPath: request.outPath, control: job)]
    }
  }
}

/// PdfOrganiseHostApi (HOM-28 amendment) on the tools host: its jobs share the registry, so
/// `PdfToolsHostApi.cancel` cancels them too. Progress events carry `tool: reorder`.
extension PdfToolsHostApiImpl: PdfOrganiseHostApi {
  func organise(request: PdfOrganiseRequestMsg, completion: @escaping (Result<PdfToolResultMsg, Error>) -> Void) {
    run(request.jobId, .reorder, completion) { pageTools.organise(request, job: $0, completion: $1) }
  }
}
