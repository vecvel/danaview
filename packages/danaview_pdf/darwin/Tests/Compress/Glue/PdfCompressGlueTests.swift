// OWNER: HOM-31
//
// XCTests of the compress glue (BUILD_PLAN HOM-31), linked against FlutterMacOS by
// Tests/Viewer/run_xctests.sh: Apple reports the compress tool, `PdfToolsHostApi.compress` writes
// the new file and answers its pages and size on the main thread, `cancel` ends a job with
// `cancelled` and no file, the job ends either way, and `PdfCompressHostApi.estimate` answers
// falling sizes for an image-heavy file and typed errors for a missing or locked one.

import Foundation
import PDFKit
import XCTest
@testable import danaview_pdf

final class PdfCompressGlueTests: XCTestCase {
  private func wait<T>(_ body: (@escaping (Result<T, Error>) -> Void) -> Void) -> Result<T, Error> {
    let done = expectation(description: "reply")
    var out: Result<T, Error>?
    body { result in
      XCTAssertTrue(Thread.isMainThread, "host replies go out on the platform main thread")
      out = result
      done.fulfill()
    }
    wait(for: [done], timeout: 60)
    return out!
  }

  private func code<T>(_ result: Result<T, Error>) -> String? {
    if case .failure(let e) = result { return (e as? PdfPigeonError)?.code }
    return nil
  }

  func testCapabilitiesListCompress() throws {
    let caps = try PdfDocumentHostApiImpl(store: PdfDocumentStore()).capabilities()
    XCTAssertTrue(caps.tools.contains(.compress))
  }

  func testCompressWritesTheNewFileAndCancelLeavesNone() throws {
    let dir = TestPdfs.tempDir(self)
    let source = CompressFixtures.writeImagePdf(to: dir.appendingPathComponent("s.pdf"), pages: 2, jpeg: true, pixelsPerInch: 200)
    let tools = PdfToolsHostApiImpl(events: nil)
    let out = dir.appendingPathComponent("s (compressed).pdf").path
    let result = try wait {
      tools.compress(request: PdfCompressRequestMsg(jobId: "c1", input: PdfToolInputMsg(path: source.path, isImage: false), preset: .small, outPath: out), completion: $0)
    }.get()
    XCTAssertEqual(result.outPaths, [out])
    XCTAssertEqual(result.pageCounts, [2])
    XCTAssertEqual(result.sizesBytes.first, CompressFixtures.size(URL(fileURLWithPath: out)))
    XCTAssertLessThan(result.sizesBytes[0], CompressFixtures.size(source))
    XCTAssertEqual(tools.jobs.runningCount, 0)

    let cancelled = dir.appendingPathComponent("c.pdf").path
    let reply = wait { (completion: @escaping (Result<PdfToolResultMsg, Error>) -> Void) in
      tools.compress(request: PdfCompressRequestMsg(jobId: "c2", input: PdfToolInputMsg(path: source.path, isImage: false), preset: .medium, outPath: cancelled), completion: completion)
      try? tools.cancel(jobId: "c2")
    }
    XCTAssertEqual(code(reply), "cancelled")
    XCTAssertFalse(FileManager.default.fileExists(atPath: cancelled))
    XCTAssertEqual(tools.jobs.runningCount, 0)

    XCTAssertEqual(code(wait {
      tools.compress(request: PdfCompressRequestMsg(jobId: "c3", input: PdfToolInputMsg(path: source.path, isImage: false), preset: .high, outPath: out), completion: $0)
    }), "invalidArgument", "an existing output is never overwritten")
  }

  func testEstimateAnswersFallingSizesAndTypedErrors() throws {
    let dir = TestPdfs.tempDir(self)
    let source = CompressFixtures.writeImagePdf(to: dir.appendingPathComponent("e.pdf"), pages: 1, jpeg: true, pixelsPerInch: 200)
    let api = PdfCompressHostApiImpl(compressor: PdfCompressor())
    let estimate = try wait { api.estimate(input: PdfToolInputMsg(path: source.path, isImage: false), completion: $0) }.get()
    XCTAssertEqual(estimate.sourceBytes, CompressFixtures.size(source))
    XCTAssertFalse(estimate.sampled)
    XCTAssertGreaterThan(estimate.highBytes, estimate.mediumBytes)
    XCTAssertGreaterThan(estimate.mediumBytes, estimate.smallBytes)
    XCTAssertEqual(code(wait { api.estimate(input: PdfToolInputMsg(path: dir.appendingPathComponent("none.pdf").path, isImage: false), completion: $0) }), "notFound")
    let locked = TestPdfs.writeTextPdf(to: dir.appendingPathComponent("l.pdf"), pages: 1, userPassword: "pw")
    XCTAssertEqual(code(wait { api.estimate(input: PdfToolInputMsg(path: locked.path, isImage: false), completion: $0) }), "passwordRequired")
  }
}
