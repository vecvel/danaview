// OWNER: HOM-30
//
// XCTests of sign behind the Pigeon host APIs on macOS (Tests/Viewer/run_xctests.sh macos): the
// capabilities list sign; the frozen `PdfToolsHostApi.sign` writes a NEW file with the signatures
// burned in (no Stamp annotation), answers on the main thread, ends its job, rejects an empty
// request and cancels through `PdfToolsHostApi.cancel` without a file; the viewer's `place` input
// on a real PDFKit view shows the selected stamp's neutral handle, moves the stamp with a drag that
// starts on it, resizes it from the handle with its aspect kept, leaves other drags to the view, and
// reports each finished drag once through `PdfAnnotateEventsApi.itemMoved`; the file is untouched.

import AppKit
import Foundation
import ImageIO
import PDFKit
import XCTest

@testable import danaview_pdf

/// A [width] × [height] PNG: opaque dark ink in the lower half, transparent above.
private func signaturePng(to url: URL, width: Int, height: Int) -> URL {
  let context = CGContext(
    data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
  context.clear(CGRect(x: 0, y: 0, width: width, height: height))
  context.setFillColor(CGColor(red: 0.1, green: 0.15, blue: 0.5, alpha: 1))
  context.fill(CGRect(x: 0, y: 0, width: width, height: height / 2))
  let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
  CGImageDestinationAddImage(dest, context.makeImage()!, nil)
  XCTAssertTrue(CGImageDestinationFinalize(dest))
  return url
}

final class PdfSignGlueTests: XCTestCase {
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

  private func stamp(_ page: Int64, _ x: Double, _ y: Double, _ w: Double, _ h: Double, _ image: String) -> PdfSignatureStampMsg {
    PdfSignatureStampMsg(pageIndex: page, rect: PdfRectMsg(x: x, y: y, width: w, height: h), imagePath: image, rotationDegrees: 0)
  }

  func testCapabilitiesListSign() throws {
    let caps = try PdfDocumentHostApiImpl(store: PdfDocumentStore()).capabilities()
    XCTAssertTrue(caps.tools.contains(.sign))
    XCTAssertTrue(caps.tools.contains(.annotate), "the sign mode is the annotate mode's place input")
  }

  func testTheFrozenSignBurnsInToANewFileAndCancelLeavesNone() throws {
    let dir = TestPdfs.tempDir(self)
    let source = TestPdfs.writeTextPdf(to: dir.appendingPathComponent("a.pdf"), pages: 2, prefix: "GSG")
    let before = TestPdfs.fingerprint(source)
    let image = signaturePng(to: dir.appendingPathComponent("sig.png"), width: 200, height: 60).path
    let tools = PdfToolsHostApiImpl(events: nil)
    let input = PdfToolInputMsg(path: source.path, isImage: false)
    let out = dir.appendingPathComponent("a (signed).pdf").path
    let signed = try wait {
      tools.sign(request: PdfSignRequestMsg(jobId: "s", input: input, stamps: [stamp(0, 300, 100, 200, 60, image), stamp(1, 72, 72, 100, 30, image)], outPath: out), completion: $0)
    }.get()
    XCTAssertEqual(signed.outPaths, [out])
    XCTAssertEqual(signed.pageCounts, [2])
    let document = try XCTUnwrap(PDFDocument(url: URL(fileURLWithPath: out)))
    XCTAssertEqual(document.page(at: 0)?.annotations.count, 0, "burned in, no Stamp annotation")
    XCTAssertEqual(document.page(at: 1)?.annotations.count, 0)
    XCTAssertEqual(document.findString("GSG-P0002", withOptions: []).count, 1)
    XCTAssertEqual(TestPdfs.fingerprint(source).0, before.0)

    XCTAssertEqual(code(wait { tools.sign(request: PdfSignRequestMsg(jobId: "e", input: input, stamps: [], outPath: dir.appendingPathComponent("e.pdf").path), completion: $0) }), "invalidArgument")
    XCTAssertEqual(code(wait { tools.sign(request: PdfSignRequestMsg(jobId: "o", input: input, stamps: [stamp(0, 1, 1, 10, 10, image)], outPath: out), completion: $0) }), "invalidArgument", "never overwrites")
    XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("e.pdf").path))
    XCTAssertEqual(tools.jobs.runningCount, 0)

    // Cancel through PdfToolsHostApi.cancel: a long file, cancelled at once.
    let long = TestPdfs.fixture("text_200p.pdf")?.path ?? TestPdfs.writeTextPdf(to: dir.appendingPathComponent("long.pdf"), pages: 200, prefix: "LNG").path
    let many = (0..<200).map { stamp(Int64($0), 72, 72, 100, 30, image) }
    let cancelled = dir.appendingPathComponent("c.pdf").path
    let done = expectation(description: "cancelled")
    var cancelCode: String?
    tools.sign(request: PdfSignRequestMsg(jobId: "c", input: PdfToolInputMsg(path: long, isImage: false), stamps: many, outPath: cancelled)) {
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
  func testPlaceModeMovesAndResizesTheSelectedStampAndReportsItOnce() throws {
    let dir = TestPdfs.tempDir(self)
    let url = TestPdfs.writeTextPdf(to: dir.appendingPathComponent("v.pdf"), pages: 2, prefix: "PLC")
    let before = TestPdfs.fingerprint(url)
    let image = signaturePng(to: dir.appendingPathComponent("sig.png"), width: 200, height: 50).path
    let store = PdfDocumentStore()
    let registry = PdfViewRegistry()
    let summary = try store.open(path: url.path, password: nil)
    let factory = PdfViewFactory(store: store, registry: registry, events: nil)
    let controller = factory.makeController(viewId: 21, args: ["handle": NSNumber(value: summary.handle), "page": NSNumber(value: 0), "displayMode": "continuous"])
    controller.nativeView?.frame = CGRect(x: 0, y: 0, width: 600, height: 800)
    controller.nativeView?.layoutSubtreeIfNeeded()
    let events = FakeAnnotateEvents()
    let api = PdfAnnotateHostApiImpl(registry: registry, tools: PdfToolsHostApiImpl(events: nil), events: events)
    let page0 = try XCTUnwrap(controller.document?.page(at: 0))
    let pdfView = controller.pdfView

    try api.setAnnotateMode(viewId: 21, mode: PdfAnnotateModeMsg(input: .place, inkColorArgb: 0, inkWidth: 1))
    let session = try XCTUnwrap(controller.annotate)
    XCTAssertEqual(session.input, .place)
    let item = PdfAnnotateItemMsg(id: "s1", stamp: stamp(0, 200, 300, 200, 50, image))

    // Not selected: no handle, and a drag on it is left to the view.
    try api.showAnnotations(viewId: 21, items: [item], selectedId: nil)
    XCTAssertEqual(page0.annotations.map(\.type), ["Stamp"])
    XCTAssertNil(session.handle)
    func view(_ p: CGPoint) -> CGPoint { pdfView.convert(p, from: page0) }
    XCTAssertFalse(session.beginDrag(at: view(CGPoint(x: 300, y: 325))))

    // Selected: the dashed mark and the neutral handle disc at the lower trailing corner.
    try api.showAnnotations(viewId: 21, items: [item], selectedId: "s1")
    XCTAssertEqual(page0.annotations.map(\.type), ["Stamp", "Square", "Circle"])
    let handle = try XCTUnwrap(session.handle?.annotation)
    XCTAssertTrue(handle is PdfHandleAnnotation)
    XCTAssertEqual(handle.bounds.midX, 400, accuracy: 0.5)
    XCTAssertEqual(handle.bounds.midY, 300, accuracy: 0.5)
    XCTAssertEqual(handle.bounds.width * pdfView.scaleFactor, PdfSignGeometry.handleDiameter, accuracy: 0.5)

    // A drag elsewhere on the page scrolls instead.
    XCTAssertFalse(session.beginDrag(at: view(CGPoint(x: 100, y: 600))))

    // Move: the stamp follows live, the final rect goes to Dart once.
    var moved = expectation(description: "moved")
    events.onEvent = { moved.fulfill() }
    XCTAssertTrue(session.beginDrag(at: view(CGPoint(x: 300, y: 325))))
    session.continueDrag(at: view(CGPoint(x: 320, y: 345)))
    let live = try XCTUnwrap(page0.annotations.first { $0.type == "Stamp" })
    XCTAssertEqual(live.bounds.minX, 220, accuracy: 0.5, "shown live")
    session.continueDrag(at: view(CGPoint(x: 350, y: 375)))
    session.endDrag(cancelled: false)
    wait(for: [moved], timeout: 10)
    XCTAssertEqual(events.moves.count, 1)
    var m = try XCTUnwrap(events.moves.last)
    XCTAssertEqual(m.viewId, 21)
    XCTAssertEqual(m.item, "s1")
    XCTAssertEqual(m.page, 0)
    XCTAssertEqual(m.rect.x, 250, accuracy: 0.5)
    XCTAssertEqual(m.rect.y, 350, accuracy: 0.5)
    XCTAssertEqual(m.rect.width, 200, accuracy: 0.01)
    XCTAssertEqual(m.rect.height, 50, accuracy: 0.01)

    // Dart replaces the item; resize from the handle keeps the upper left corner and the aspect.
    let movedItem = PdfAnnotateItemMsg(id: "s1", stamp: stamp(0, m.rect.x, m.rect.y, m.rect.width, m.rect.height, image))
    try api.showAnnotations(viewId: 21, items: [movedItem], selectedId: "s1")
    moved = expectation(description: "resized")
    events.onEvent = { moved.fulfill() }
    XCTAssertTrue(session.beginDrag(at: view(CGPoint(x: 450, y: 350))), "the handle at (maxX, minY)")
    session.continueDrag(at: view(CGPoint(x: 550, y: 330)))
    session.endDrag(cancelled: false)
    wait(for: [moved], timeout: 10)
    m = try XCTUnwrap(events.moves.last)
    XCTAssertEqual(m.rect.x, 250, accuracy: 0.5)
    XCTAssertEqual(m.rect.y + m.rect.height, 400, accuracy: 0.5, "the top edge stays")
    XCTAssertEqual(m.rect.width, 300, accuracy: 0.5)
    XCTAssertEqual(m.rect.width / m.rect.height, 4, accuracy: 0.01, "aspect kept")

    // A cancelled drag puts the stamp back and reports nothing.
    XCTAssertTrue(session.beginDrag(at: view(CGPoint(x: 300, y: 375))))
    session.continueDrag(at: view(CGPoint(x: 100, y: 100)))
    session.endDrag(cancelled: true)
    XCTAssertEqual(events.moves.count, 2)
    XCTAssertFalse(session.isDragging)

    // Another input has no handle; leaving the mode removes everything; the file is untouched.
    try api.setAnnotateMode(viewId: 21, mode: PdfAnnotateModeMsg(input: .select, inkColorArgb: 0, inkWidth: 1))
    try api.showAnnotations(viewId: 21, items: [movedItem], selectedId: "s1")
    XCTAssertNil(session.handle)
    XCTAssertFalse(session.beginDrag(at: view(CGPoint(x: 300, y: 375))))
    try api.setAnnotateMode(viewId: 21, mode: nil)
    XCTAssertEqual(page0.annotations.count, 0)
    XCTAssertEqual(TestPdfs.fingerprint(url).0, before.0)
    XCTAssertEqual(TestPdfs.fingerprint(url).1, before.1)
  }
}
