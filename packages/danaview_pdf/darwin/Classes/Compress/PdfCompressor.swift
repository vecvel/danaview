// OWNER: HOM-31
//
// Compress on Apple (HOM plan §8.5, D-98j): the Pigeon side of Compress/PdfCompressCore.swift.
// `PdfToolsHostApi.compress` runs here as a tool job (progress events, cancel through
// `PdfToolsHostApi.cancel`); `PdfCompressHostApi.estimate` gives the sheet each preset's size.
// Work runs on a background queue and replies on the main thread; a cancelled or failed job
// leaves no file at `outPath` (the core writes it once, at the end).

import Foundation

#if os(iOS)
import Flutter
#elseif os(macOS)
import FlutterMacOS
#endif

/// Compress (HOM-31).
final class PdfCompressor {
  /// The tools of this class that work here (PdfCapabilitiesMsg.tools).
  static let supported: [PdfToolKindMsg] = [.compress]

  private let queue = DispatchQueue(label: "com.vecvel.danaview.pdf.compress", qos: .userInitiated, attributes: .concurrent)

  func compress(_ request: PdfCompressRequestMsg, job: PdfJob, completion: @escaping (Result<PdfToolResultMsg, Error>) -> Void) {
    let preset = PdfCompressPreset(rawValue: request.preset.rawValue) ?? .medium
    queue.async {
      let result: Result<PdfToolResultMsg, Error>
      do {
        guard !request.input.isImage else { throw PdfFailure(.invalidArgument, "compress takes a PDF") }
        job.progress(fraction: 0, pagesDone: 0, pagesTotal: 0)
        let outcome = try PdfCompressCore.compress(
          path: request.input.path, password: request.input.password, preset: preset, outPath: request.outPath,
          isCancelled: { job.isCancelled },
          progress: { job.progress(fraction: $0, pagesDone: 0, pagesTotal: 0) })
        job.progress(fraction: 1, pagesDone: outcome.pageCount, pagesTotal: outcome.pageCount)
        result = .success(PdfToolResultMsg(outPaths: [request.outPath], pageCounts: [Int64(outcome.pageCount)], sizesBytes: [outcome.sizeBytes]))
      } catch {
        result = .failure(error)
      }
      DispatchQueue.main.async { completion(result) }
    }
  }

  func estimate(_ input: PdfToolInputMsg, completion: @escaping (Result<PdfCompressEstimateMsg, Error>) -> Void) {
    queue.async {
      let result: Result<PdfCompressEstimateMsg, Error>
      do {
        guard !input.isImage else { throw PdfFailure(.invalidArgument, "compress takes a PDF") }
        let e = try PdfCompressCore.estimate(path: input.path, password: input.password)
        result = .success(PdfCompressEstimateMsg(
          sourceBytes: e.sourceBytes, highBytes: e.presetBytes[0], mediumBytes: e.presetBytes[1], smallBytes: e.presetBytes[2],
          sampled: e.sampled))
      } catch {
        result = .failure(PdfErrors.from(error))
      }
      DispatchQueue.main.async { completion(result) }
    }
  }
}

/// `PdfCompressHostApi` on Apple.
final class PdfCompressHostApiImpl: PdfCompressHostApi {
  let compressor: PdfCompressor

  init(compressor: PdfCompressor) {
    self.compressor = compressor
  }

  func estimate(input: PdfToolInputMsg, completion: @escaping (Result<PdfCompressEstimateMsg, Error>) -> Void) {
    compressor.estimate(input, completion: completion)
  }
}
