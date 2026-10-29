// OWNER: HOM-28
//
// XCTests of the page tools behind the Pigeon host APIs on macOS (run_xctests.sh macos):
// PdfToolsHostApi merge / split / reorder / rotate / deletePages and the HOM-28 amendment's
// PdfOrganiseHostApi answer PdfToolResultMsg on the main thread, end their jobs, map failures to
// typed codes and cancel through `PdfToolsHostApi.cancel` without leaving a file.

import Foundation
import PDFKit
import XCTest

@testable import danaview_pdf

final class PdfPageToolsGlueTests: XCTestCase {
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

  private func pageCount(_ path: String) -> Int { PDFDocument(url: URL(fileURLWithPath: path))?.pageCount ?? -1 }

  func testCapabilitiesListThePageTools() throws {
    let caps = try PdfDocumentHostApiImpl(store: PdfDocumentStore()).capabilities()
    for tool in [PdfToolKindMsg.merge, .split, .reorder, .rotate, .deletePages] {
      XCTAssertTrue(caps.tools.contains(tool), "\(tool)")
    }
  }

  func testEveryPageToolAnswersThroughPigeon() throws {
    let dir = TestPdfs.tempDir(self)
    let a = TestPdfs.writeTextPdf(to: dir.appendingPathComponent("a.pdf"), pages: 4, prefix: "GLA").path
    let b = TestPdfs.writeTextPdf(to: dir.appendingPathComponent("b.pdf"), pages: 2, prefix: "GLB").path
    let tools = PdfToolsHostApiImpl(events: nil)
    let input = PdfToolInputMsg(path: a, isImage: false)
    func out(_ n: String) -> String { dir.appendingPathComponent(n).path }

    let merged = try wait {
      tools.merge(request: PdfMergeRequestMsg(jobId: "m", inputs: [input, PdfToolInputMsg(path: b, isImage: false)], outPath: out("m.pdf")), completion: $0)
    }.get()
    XCTAssertEqual(merged.outPaths, [out("m.pdf")])
    XCTAssertEqual(merged.pageCounts, [6])
    XCTAssertGreaterThan(merged.sizesBytes[0], 0)

    let split = try wait {
      tools.split(request: PdfSplitRequestMsg(
        jobId: "s", input: input, ranges: [PdfPageRangeMsg(start: 0, end: 1), PdfPageRangeMsg(start: 1, end: 4)],
        outPaths: [out("s1.pdf"), out("s2.pdf")]), completion: $0)
    }.get()
    XCTAssertEqual(split.pageCounts, [1, 3])

    let reordered = try wait { tools.reorder(request: PdfReorderRequestMsg(jobId: "r", input: input, order: [3, 2, 1, 0], outPath: out("r.pdf")), completion: $0) }.get()
    XCTAssertEqual(reordered.pageCounts, [4])
    XCTAssertTrue(PDFDocument(url: URL(fileURLWithPath: out("r.pdf")))?.page(at: 0)?.string?.hasPrefix("GLA-P0004") ?? false)

    _ = try wait { tools.rotate(request: PdfRotateRequestMsg(jobId: "t", input: input, pages: [1], degrees: 90, outPath: out("t.pdf")), completion: $0) }.get()
    XCTAssertEqual(PDFDocument(url: URL(fileURLWithPath: out("t.pdf")))?.page(at: 1)?.rotation, 90)

    let deleted = try wait { tools.deletePages(request: PdfDeletePagesRequestMsg(jobId: "d", input: input, pages: [0, 1], outPath: out("d.pdf")), completion: $0) }.get()
    XCTAssertEqual(deleted.pageCounts, [2])

    let organised = try wait {
      tools.organise(request: PdfOrganiseRequestMsg(
        jobId: "o", input: input, pages: [PdfPagePlanMsg(sourcePage: 2, rotation: 270), PdfPagePlanMsg(sourcePage: 0, rotation: 0)],
        outPath: out("o.pdf")), completion: $0)
    }.get()
    XCTAssertEqual(organised.pageCounts, [2])
    XCTAssertEqual(PDFDocument(url: URL(fileURLWithPath: out("o.pdf")))?.page(at: 0)?.rotation, 270)

    XCTAssertEqual(tools.jobs.runningCount, 0)
  }

  func testFailuresAreTypedAndLeaveNoFile() throws {
    let dir = TestPdfs.tempDir(self)
    let a = TestPdfs.writeTextPdf(to: dir.appendingPathComponent("a.pdf"), pages: 2, prefix: "GLA").path
    let locked = TestPdfs.writeTextPdf(to: dir.appendingPathComponent("l.pdf"), pages: 2, userPassword: "pw").path
    let tools = PdfToolsHostApiImpl(events: nil)
    let out = dir.appendingPathComponent("x.pdf").path
    let input = PdfToolInputMsg(path: a, isImage: false)
    XCTAssertEqual(code(wait { tools.deletePages(request: PdfDeletePagesRequestMsg(jobId: "1", input: input, pages: [0, 1], outPath: out), completion: $0) }), "invalidArgument")
    XCTAssertEqual(code(wait { tools.reorder(request: PdfReorderRequestMsg(jobId: "2", input: input, order: [0], outPath: out), completion: $0) }), "invalidArgument")
    XCTAssertEqual(code(wait { tools.rotate(request: PdfRotateRequestMsg(jobId: "3", input: PdfToolInputMsg(path: locked, isImage: false), pages: [0], degrees: 90, outPath: out), completion: $0) }), "passwordRequired")
    XCTAssertEqual(code(wait { tools.split(request: PdfSplitRequestMsg(jobId: "4", input: input, ranges: [PdfPageRangeMsg(start: 1, end: 1)], outPaths: [out]), completion: $0) }), "invalidArgument")
    XCTAssertEqual(code(wait { tools.organise(request: PdfOrganiseRequestMsg(jobId: "5", input: input, pages: [], outPath: out), completion: $0) }), "invalidArgument")
    XCTAssertEqual(code(wait { tools.merge(request: PdfMergeRequestMsg(jobId: "6", inputs: [input, PdfToolInputMsg(path: dir.appendingPathComponent("none.pdf").path, isImage: false)], outPath: out), completion: $0) }), "notFound")
    XCTAssertFalse(FileManager.default.fileExists(atPath: out))
    XCTAssertEqual(tools.jobs.runningCount, 0)
  }

  func testCancelThroughTheToolsApiLeavesNoFile() throws {
    let dir = TestPdfs.tempDir(self)
    let a = TestPdfs.writeTextPdf(to: dir.appendingPathComponent("a.pdf"), pages: 400, prefix: "CAN").path
    let tools = PdfToolsHostApiImpl(events: nil)
    let out = dir.appendingPathComponent("o.pdf").path
    let done = expectation(description: "reply")
    var result: Result<PdfToolResultMsg, Error>?
    tools.organise(request: PdfOrganiseRequestMsg(
      jobId: "big", input: PdfToolInputMsg(path: a, isImage: false),
      pages: (0..<400).reversed().map { PdfPagePlanMsg(sourcePage: Int64($0), rotation: 90) }, outPath: out)) {
      result = $0
      done.fulfill()
    }
    XCTAssertNoThrow(try tools.cancel(jobId: "big"))
    wait(for: [done], timeout: 60)
    XCTAssertEqual(code(result!), "cancelled")
    XCTAssertFalse(FileManager.default.fileExists(atPath: out))
    XCTAssertEqual(tools.jobs.runningCount, 0)
    XCTAssertEqual(pageCount(a), 400, "the source is untouched")
  }
}
