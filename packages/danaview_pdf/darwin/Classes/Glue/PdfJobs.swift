// OWNER: HOM-24
//
// Tool jobs (pigeons/pdf_api.dart, PdfToolsHostApi): a job is created per request with the
// caller's id, carries a cancel flag the tool polls between pages, and reports progress through the
// event hub. The tool classes (Tools/, Annotate/, Sign/, Compress/; HOM-28…HOM-31) receive a job
// and must write only their `outPath`, deleting it on cancel or failure (no partial file).

import Foundation

/// One running tool job.
final class PdfJob {
  let id: String
  let tool: PdfToolKindMsg
  private let lock = NSLock()
  private var cancelled = false
  private let onProgress: (PdfToolProgressMsg) -> Void

  init(id: String, tool: PdfToolKindMsg, onProgress: @escaping (PdfToolProgressMsg) -> Void) {
    self.id = id
    self.tool = tool
    self.onProgress = onProgress
  }

  /// True after `cancel` (any thread).
  var isCancelled: Bool {
    lock.lock()
    defer { lock.unlock() }
    return cancelled
  }

  func cancel() {
    lock.lock()
    cancelled = true
    lock.unlock()
  }

  /// Reports [done] of [total] pages (any thread).
  func progress(done: Int, total: Int) {
    let fraction = total > 0 ? min(1, max(0, Double(done) / Double(total))) : 0
    onProgress(PdfToolProgressMsg(jobId: id, tool: tool, fraction: fraction, pagesDone: Int64(done), pagesTotal: Int64(total)))
  }

  /// Reports [fraction] (0…1) directly, for a tool whose work is not page by page (compress,
  /// HOM-31); [pagesDone] and [pagesTotal] are 0 while unknown.
  func progress(fraction: Double, pagesDone: Int, pagesTotal: Int) {
    let clamped = min(1, max(0, fraction.isFinite ? fraction : 0))
    onProgress(PdfToolProgressMsg(jobId: id, tool: tool, fraction: clamped, pagesDone: Int64(pagesDone), pagesTotal: Int64(pagesTotal)))
  }
}

/// The running jobs by id.
final class PdfJobRegistry {
  private let lock = NSLock()
  private var jobs: [String: PdfJob] = [:]
  private let events: PdfEventHub?

  init(events: PdfEventHub?) {
    self.events = events
  }

  /// Starts a job; `busy`-style reuse of a running id answers invalidArgument.
  func start(id: String, tool: PdfToolKindMsg) throws -> PdfJob {
    guard !id.isEmpty else { throw PdfFailure(.invalidArgument, "empty job id") }
    lock.lock()
    defer { lock.unlock() }
    guard jobs[id] == nil else { throw PdfFailure(.invalidArgument, "job id in use") }
    let job = PdfJob(id: id, tool: tool) { [weak events] progress in
      events?.emit(PdfEventMsg(kind: .toolProgress, toolProgress: progress))
    }
    jobs[id] = job
    return job
  }

  func finish(_ job: PdfJob) {
    lock.lock()
    if jobs[job.id] === job { jobs[job.id] = nil }
    lock.unlock()
  }

  /// Cancels [id] if it runs.
  func cancel(id: String) {
    lock.lock()
    let job = jobs[id]
    lock.unlock()
    job?.cancel()
  }

  var runningCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return jobs.count
  }
}
