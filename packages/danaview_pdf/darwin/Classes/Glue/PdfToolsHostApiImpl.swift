// OWNER: HOM-24
//
// PdfToolsHostApi on Apple: starts a job per request (progress events, cancel) and routes it to
// the tool class of its ticket: Tools/PdfPageTools (HOM-28), Annotate/PdfAnnotator (HOM-29),
// Sign/PdfSigner (HOM-30), Compress/PdfCompressor (HOM-31). The job ends when the tool completes.

import Foundation

#if os(iOS)
import Flutter
#elseif os(macOS)
import FlutterMacOS
#endif

final class PdfToolsHostApiImpl: PdfToolsHostApi {
  let jobs: PdfJobRegistry
  let pageTools = PdfPageTools()
  let annotator = PdfAnnotator()
  let signer = PdfSigner()
  let compressor = PdfCompressor()

  init(events: PdfEventHub?) {
    jobs = PdfJobRegistry(events: events)
  }

  /// Starts job [id] of [tool] and runs [body] with it; also used by PdfOrganiseHostApi (HOM-28).
  func run(
    _ id: String, _ tool: PdfToolKindMsg, _ completion: @escaping (Result<PdfToolResultMsg, Error>) -> Void,
    _ body: (PdfJob, @escaping (Result<PdfToolResultMsg, Error>) -> Void) -> Void
  ) {
    let job: PdfJob
    do {
      job = try jobs.start(id: id, tool: tool)
    } catch {
      completion(.failure(PdfErrors.from(error)))
      return
    }
    body(job) { [jobs] result in
      jobs.finish(job)
      switch result {
      case .success(let value): completion(.success(value))
      case .failure(let error): completion(.failure(PdfErrors.from(error)))
      }
    }
  }

  func merge(request: PdfMergeRequestMsg, completion: @escaping (Result<PdfToolResultMsg, Error>) -> Void) {
    run(request.jobId, .merge, completion) { pageTools.merge(request, job: $0, completion: $1) }
  }

  func split(request: PdfSplitRequestMsg, completion: @escaping (Result<PdfToolResultMsg, Error>) -> Void) {
    run(request.jobId, .split, completion) { pageTools.split(request, job: $0, completion: $1) }
  }

  func reorder(request: PdfReorderRequestMsg, completion: @escaping (Result<PdfToolResultMsg, Error>) -> Void) {
    run(request.jobId, .reorder, completion) { pageTools.reorder(request, job: $0, completion: $1) }
  }

  func rotate(request: PdfRotateRequestMsg, completion: @escaping (Result<PdfToolResultMsg, Error>) -> Void) {
    run(request.jobId, .rotate, completion) { pageTools.rotate(request, job: $0, completion: $1) }
  }

  func deletePages(request: PdfDeletePagesRequestMsg, completion: @escaping (Result<PdfToolResultMsg, Error>) -> Void) {
    run(request.jobId, .deletePages, completion) { pageTools.deletePages(request, job: $0, completion: $1) }
  }

  func annotate(request: PdfAnnotateRequestMsg, completion: @escaping (Result<PdfToolResultMsg, Error>) -> Void) {
    run(request.jobId, .annotate, completion) { annotator.annotate(request, job: $0, completion: $1) }
  }

  func sign(request: PdfSignRequestMsg, completion: @escaping (Result<PdfToolResultMsg, Error>) -> Void) {
    run(request.jobId, .sign, completion) { signer.sign(request, job: $0, completion: $1) }
  }

  func compress(request: PdfCompressRequestMsg, completion: @escaping (Result<PdfToolResultMsg, Error>) -> Void) {
    run(request.jobId, .compress, completion) { compressor.compress(request, job: $0, completion: $1) }
  }

  func cancel(jobId: String) throws {
    jobs.cancel(id: jobId)
  }
}
