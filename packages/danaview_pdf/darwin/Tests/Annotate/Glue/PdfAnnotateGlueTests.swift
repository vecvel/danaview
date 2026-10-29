// OWNER: HOM-29
// EXTENDED: HOM-30 (the fake events record `itemMoved`; the capabilities now list sign too.)
//
// XCTests of annotate behind the Pigeon host APIs on macOS (run_xctests.sh macos): the
// capabilities list annotate; `PdfAnnotateHostApi.save` and the frozen `PdfToolsHostApi.annotate`
// answer on the main thread, end their jobs and cancel through `PdfToolsHostApi.cancel` without a
// file; annotate mode on a real PDFKit viewer previews the session's items on the in-memory
// document (removed again when the mode ends, the file untouched), marks the selected one, hit
// tests taps, reports the text selection line by line and sends finished ink strokes in page
// space through `PdfAnnotateEventsApi`.

import AppKit
import Foundation
import PDFKit
import XCTest

@testable import danaview_pdf

/// Records what the session sends to Dart.
@MainActor
final class FakeAnnotateEvents: PdfAnnotateEventsApiProtocol {
  var strokes: [(viewId: Int64, page: Int64, points: [Double])] = []
  var taps: [(page: Int64, x: Double, y: Double, item: String?)] = []
  var moves: [(viewId: Int64, item: String, page: Int64, rect: PdfRectMsg)] = []
  var onEvent: (() -> Void)?

  nonisolated init() {}

  func inkStroke(viewId viewIdArg: Int64, pageIndex pageIndexArg: Int64, points pointsArg: [Double]) async throws {
    strokes.append((viewIdArg, pageIndexArg, pointsArg))
    onEvent?()
  }

  func tapped(viewId viewIdArg: Int64, pageIndex pageIndexArg: Int64, x xArg: Double, y yArg: Double, itemId itemIdArg: String?) async throws {
    taps.append((pageIndexArg, xArg, yArg, itemIdArg))
    onEvent?()
  }

  func itemMoved(viewId viewIdArg: Int64, itemId itemIdArg: String, pageIndex pageIndexArg: Int64, rect rectArg: PdfRectMsg) async throws {
    moves.append((viewIdArg, itemIdArg, pageIndexArg, rectArg))
    onEvent?()
  }
}

final class PdfAnnotateGlueTests: XCTestCase {
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

  private func ink(_ page: Int64, _ points: [Double]) -> PdfAnnotationMsg {
    PdfAnnotationMsg(kind: .ink, pageIndex: page, rects: [], strokes: [PdfInkStrokeMsg(points: points)], colorArgb: 0xFF00_0000, lineWidth: 3)
  }

  func testCapabilitiesListAnnotate() throws {
    let caps = try PdfDocumentHostApiImpl(store: PdfDocumentStore()).capabilities()
    XCTAssertTrue(caps.tools.contains(.annotate))
    XCTAssertTrue(caps.tools.contains(.sign), "HOM-30 landed: sign is the annotate save with burn-in")
  }

  func testSaveAndTheFrozenAnnotateWriteNewFilesAndCancelLeavesNone() throws {
    let dir = TestPdfs.tempDir(self)
    let source = TestPdfs.writeTextPdf(to: dir.appendingPathComponent("a.pdf"), pages: 3, prefix: "GLN").path
    let tools = PdfToolsHostApiImpl(events: nil)
    let api = PdfAnnotateHostApiImpl(registry: PdfViewRegistry(), tools: tools, events: nil)
    let input = PdfToolInputMsg(path: source, isImage: false)
    let text = PdfAnnotationMsg(kind: .freeText, pageIndex: 2, rects: [PdfRectMsg(x: 72, y: 300, width: 200, height: 0)], strokes: [],
                                colorArgb: 0xFF1E_88E5, lineWidth: 0, text: "Hello")
    let out = dir.appendingPathComponent("o.pdf").path
    let saved = try wait {
      api.save(request: PdfAnnotateSaveRequestMsg(jobId: "s", input: input, annotations: [ink(0, [10, 10, 80, 80]), text], stamps: [], burnIn: false, outPath: out), completion: $0)
    }.get()
    XCTAssertEqual(saved.outPaths, [out])
    XCTAssertEqual(saved.pageCounts, [3])
    let document = try XCTUnwrap(PDFDocument(url: URL(fileURLWithPath: out)))
    XCTAssertEqual(document.page(at: 0)?.annotations.map(\.type), ["Ink"])
    XCTAssertEqual(document.page(at: 2)?.annotations.first?.contents, "Hello")

    let frozen = dir.appendingPathComponent("f.pdf").path
    let r = try wait { tools.annotate(request: PdfAnnotateRequestMsg(jobId: "f", input: input, annotations: [ink(1, [1, 1, 2, 2])], outPath: frozen), completion: $0) }.get()
    XCTAssertEqual(r.outPaths, [frozen])
    XCTAssertEqual(PDFDocument(url: URL(fileURLWithPath: frozen))?.page(at: 1)?.annotations.map(\.type), ["Ink"])

    // Typed failures, and every job ends.
    XCTAssertEqual(code(wait { api.save(request: PdfAnnotateSaveRequestMsg(jobId: "x", input: input, annotations: [ink(9, [1, 1])], stamps: [], burnIn: false, outPath: dir.appendingPathComponent("x.pdf").path), completion: $0) }), "invalidArgument")
    XCTAssertEqual(code(wait { api.save(request: PdfAnnotateSaveRequestMsg(jobId: "y", input: input, annotations: [ink(0, [1])], stamps: [], burnIn: false, outPath: dir.appendingPathComponent("y.pdf").path), completion: $0) }), "invalidArgument")
    XCTAssertEqual(tools.jobs.runningCount, 0)

    // Cancel through PdfToolsHostApi.cancel: a long file, cancelled at once.
    let long = TestPdfs.fixture("text_200p.pdf")?.path ?? TestPdfs.writeTextPdf(to: dir.appendingPathComponent("long.pdf"), pages: 200, prefix: "LNG").path
    let many = (0..<200).map { ink(Int64($0), [10, 10, 60, 60]) }
    let cancelled = dir.appendingPathComponent("c.pdf").path
    let done = expectation(description: "cancelled")
    var cancelCode: String?
    api.save(request: PdfAnnotateSaveRequestMsg(jobId: "c", input: PdfToolInputMsg(path: long, isImage: false), annotations: many, stamps: [], burnIn: false, outPath: cancelled)) {
      if case .failure(let e) = $0 { cancelCode = (e as? PdfPigeonError)?.code }
      done.fulfill()
    }
    try tools.cancel(jobId: "c")
    wait(for: [done], timeout: 60)
    XCTAssertEqual(cancelCode, "cancelled")
    XCTAssertFalse(FileManager.default.fileExists(atPath: cancelled))
    XCTAssertEqual(tools.jobs.runningCount, 0)
  }

  @MainActor
  func testAnnotateModePreviewsHitTestsReportsSelectionAndInkAndEndsClean() throws {
    let dir = TestPdfs.tempDir(self)
    let url = TestPdfs.writeTextPdf(to: dir.appendingPathComponent("v.pdf"), pages: 2, prefix: "VIEW")
    let before = TestPdfs.fingerprint(url)
    let store = PdfDocumentStore()
    let registry = PdfViewRegistry()
    let summary = try store.open(path: url.path, password: nil)
    let factory = PdfViewFactory(store: store, registry: registry, events: nil)
    let controller = factory.makeController(viewId: 11, args: ["handle": NSNumber(value: summary.handle), "page": NSNumber(value: 0), "displayMode": "continuous"])
    controller.nativeView?.frame = CGRect(x: 0, y: 0, width: 600, height: 800)
    controller.nativeView?.layoutSubtreeIfNeeded()
    let events = FakeAnnotateEvents()
    let api = PdfAnnotateHostApiImpl(registry: registry, tools: PdfToolsHostApiImpl(events: nil), events: events)
    let page0 = try XCTUnwrap(controller.document?.page(at: 0))

    XCTAssertThrowsError(try api.showAnnotations(viewId: 11, items: [], selectedId: nil)) { XCTAssertEqual(($0 as? PdfPigeonError)?.code, "invalidArgument") }
    XCTAssertThrowsError(try api.setAnnotateMode(viewId: 99, mode: nil)) { XCTAssertEqual(($0 as? PdfPigeonError)?.code, "notFound") }

    try api.setAnnotateMode(viewId: 11, mode: PdfAnnotateModeMsg(input: .select, inkColorArgb: 0xFFE5_3935, inkWidth: 2))
    XCTAssertNotNil(controller.annotate)

    // The text selection, line by line.
    XCTAssertEqual(try api.selectionLines(viewId: 11).count, 0)
    let range = (page0.string! as NSString).range(of: "VIEW-P0001")
    controller.pdfView.setCurrentSelection(page0.selection(for: range), animate: false)
    let lines = try api.selectionLines(viewId: 11)
    XCTAssertEqual(lines.map(\.pageIndex), [0])
    XCTAssertEqual(lines[0].rects.count, 1)
    let line = lines[0].rects[0]

    // The preview: two items on the in-memory document, the selected one marked.
    let highlight = PdfAnnotationMsg(kind: .highlight, pageIndex: 0, rects: [line], strokes: [], colorArgb: 0xFFFF_D60A, lineWidth: 0)
    try api.showAnnotations(viewId: 11, items: [
      PdfAnnotateItemMsg(id: "h1", annotation: highlight),
      PdfAnnotateItemMsg(id: "i1", annotation: ink(1, [100, 100, 300, 100])),
      PdfAnnotateItemMsg(id: "bad", annotation: ink(7, [1, 1])),
    ], selectedId: "h1")
    XCTAssertEqual(page0.annotations.map(\.type), ["Highlight", "Square"], "the item and its selection mark")
    XCTAssertTrue(page0.annotations.allSatisfy(\.isReadOnly))
    XCTAssertEqual(controller.document?.page(at: 1)?.annotations.map(\.type), ["Ink"])
    let session = try XCTUnwrap(controller.annotate)
    XCTAssertEqual(session.shown.map(\.id), ["h1", "i1"], "an item that can't be built is skipped")
    XCTAssertEqual(session.hit(pageIndex: 0, point: CGPoint(x: line.x + line.width / 2, y: line.y + line.height / 2)), "h1")
    XCTAssertEqual(session.hit(pageIndex: 1, point: CGPoint(x: 200, y: 101)), "i1")
    XCTAssertNil(session.hit(pageIndex: 1, point: CGPoint(x: 200, y: 400)))

    // Replacing the preview removes the old items.
    try api.showAnnotations(viewId: 11, items: [PdfAnnotateItemMsg(id: "i1", annotation: ink(1, [100, 100, 300, 100]))], selectedId: nil)
    XCTAssertEqual(page0.annotations.count, 0)

    // Ink mode: an overlay draws; a finished stroke reaches Dart in page space.
    try api.setAnnotateMode(viewId: 11, mode: PdfAnnotateModeMsg(input: .ink, inkColorArgb: 0xFF00_00FF, inkWidth: 4))
    let container = try XCTUnwrap(controller.nativeView)
    let overlay = try XCTUnwrap(container.subviews.compactMap { $0 as? PdfMouseInkView }.first)
    let pdfView = controller.pdfView
    let start = pdfView.convert(CGPoint(x: 150, y: 600), from: page0)
    let end = pdfView.convert(CGPoint(x: 250, y: 650), from: page0)
    let got = expectation(description: "stroke")
    events.onEvent = { got.fulfill() }
    overlay.onStroke?([start, end])
    wait(for: [got], timeout: 10)
    let stroke = try XCTUnwrap(events.strokes.first)
    XCTAssertEqual(stroke.viewId, 11)
    XCTAssertEqual(stroke.page, 0)
    XCTAssertEqual(stroke.points.count, 4)
    XCTAssertEqual(stroke.points[0], 150, accuracy: 1)
    XCTAssertEqual(stroke.points[1], 600, accuracy: 1)
    XCTAssertEqual(stroke.points[2], 250, accuracy: 1)
    XCTAssertEqual(stroke.points[3], 650, accuracy: 1)

    // Leaving annotate mode removes the preview and the overlay; the file is untouched.
    try api.setAnnotateMode(viewId: 11, mode: nil)
    XCTAssertNil(controller.annotate)
    XCTAssertEqual(controller.document?.page(at: 1)?.annotations.count, 0)
    XCTAssertTrue(container.subviews.allSatisfy { !($0 is PdfMouseInkView) })
    XCTAssertEqual(TestPdfs.fingerprint(url).0, before.0)
    XCTAssertEqual(TestPdfs.fingerprint(url).1, before.1)
  }
}
