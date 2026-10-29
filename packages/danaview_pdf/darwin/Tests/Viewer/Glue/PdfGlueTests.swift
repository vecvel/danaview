// OWNER: HOM-24
//
// XCTests of the Apple glue (BUILD_PLAN HOM-24) linked against FlutterMacOS: the document, view,
// text and tools host APIs answer through Pigeon types and typed errors, the platform view factory
// builds a PDFKit viewer that navigates, zooms, finds and highlights fixture strings and copies a
// selection, thumbnails render from an independent open while a view draws the same handle, every
// async reply arrives on the main thread, the texture calls are Android-only, and every tool stub
// not landed yet (annotate, sign) answers notSupportedOnDevice and ends its job (the page tools landed
// with HOM-28: Tests/Tools/Glue/; compress with HOM-31: Tests/Compress/Glue/).

import Foundation
import PDFKit
import XCTest
@testable import danaview_pdf

#if os(macOS)
import AppKit
import FlutterMacOS
#endif

final class PdfGlueTests: XCTestCase {
  private func wait<T>(_ body: (@escaping (Result<T, Error>) -> Void) -> Void) -> Result<T, Error> {
    let done = expectation(description: "reply")
    var out: Result<T, Error>?
    body { result in
      XCTAssertTrue(Thread.isMainThread, "host replies go out on the platform main thread")
      out = result
      done.fulfill()
    }
    wait(for: [done], timeout: 10)
    return out!
  }

  private func code<T>(_ result: Result<T, Error>) -> String? {
    if case .failure(let e) = result { return (e as? PdfPigeonError)?.code }
    return nil
  }

  func testDocumentApiOpenUnlockOutlineClose() throws {
    let dir = TestPdfs.tempDir(self)
    let locked = TestPdfs.writeTextPdf(to: dir.appendingPathComponent("l.pdf"), pages: 2, userPassword: "pw")
    let outlined = TestPdfs.writeOutlinedPdf(in: dir)
    let api = PdfDocumentHostApiImpl(store: PdfDocumentStore())

    let caps = try api.capabilities()
    XCTAssertTrue(caps.platformView && caps.search && caps.selection && caps.passwords && caps.outline && caps.textExtraction)
    XCTAssertFalse(caps.textureView)
    XCTAssertEqual(Set(caps.tools), [.merge, .split, .reorder, .rotate, .deletePages, .compress], "the page tools (HOM-28) and compress (HOM-31) have landed")

    let info = try wait { api.open(request: PdfOpenRequestMsg(path: locked.path, password: nil), completion: $0) }.get()
    XCTAssertTrue(info.locked)
    XCTAssertNil(try wait { api.unlock(handle: info.handle, password: "bad", completion: $0) }.get())
    let unlocked = try XCTUnwrap(try wait { api.unlock(handle: info.handle, password: "pw", completion: $0) }.get())
    XCTAssertEqual(unlocked.pageCount, 2)
    XCTAssertEqual(unlocked.pageSizes.first, PdfPageSizeMsg(width: 612, height: 792, rotation: 0))

    let o = try wait { api.open(request: PdfOpenRequestMsg(path: outlined.path), completion: $0) }.get()
    let outline = try wait { api.outline(handle: o.handle, completion: $0) }.get()
    XCTAssertEqual(outline.map(\.title), ["Chapter 1", "Section 1.1", "Chapter 2"])
    XCTAssertEqual(outline.map(\.depth), [0, 1, 0])
    try api.close(handle: o.handle)
    XCTAssertEqual(code(wait { api.outline(handle: o.handle, completion: $0) }), "notFound")

    let probe = try wait { api.probe(path: TestPdfs.writeDamagedPdf(in: dir).path, completion: $0) }.get()
    XCTAssertFalse(probe.canOpen)
    XCTAssertEqual(code(wait { api.open(request: PdfOpenRequestMsg(path: dir.appendingPathComponent("none.pdf").path), completion: $0) }), "notFound")
  }

  func testTextApi() throws {
    let dir = TestPdfs.tempDir(self)
    let url = TestPdfs.writeTextPdf(to: dir.appendingPathComponent("t.pdf"), pages: 3, prefix: "GLUE")
    let api = PdfTextHostApiImpl()
    let result = try wait {
      api.extractText(request: PdfTextRequestMsg(path: url.path, firstPage: 1, pageCount: -1, maxChars: -1), completion: $0)
    }.get()
    XCTAssertEqual(result.documentPageCount, 3)
    XCTAssertEqual(result.pages.map(\.pageIndex), [1, 2])
    XCTAssertTrue(result.pages[0].text.contains("GLUE-P0002"))
    XCTAssertEqual(
      code(wait { api.extractText(request: PdfTextRequestMsg(path: TestPdfs.writeDamagedPdf(in: dir).path, firstPage: 0, pageCount: 1, maxChars: -1), completion: $0) }),
      "damaged")
  }

  // The page tools (merge, split, reorder, rotate, delete) landed with HOM-28: Tools/PdfPageToolsGlueTests.
  func testToolStubsAnswerNotSupportedAndEndTheirJobs() {
    let tools = PdfToolsHostApiImpl(events: nil)
    let input = PdfToolInputMsg(path: "/nonexistent.pdf", isImage: false)
    let out = "/nonexistent-out.pdf"
    let calls: [(String, (@escaping (Result<PdfToolResultMsg, Error>) -> Void) -> Void)] = [
      ("annotate", { tools.annotate(request: PdfAnnotateRequestMsg(jobId: "j6", input: input, annotations: [], outPath: out), completion: $0) }),
      ("sign", { tools.sign(request: PdfSignRequestMsg(jobId: "j7", input: input, stamps: [], outPath: out), completion: $0) }),
    ]
    for (name, call) in calls {
      XCTAssertEqual(code(wait(call)), "notSupportedOnDevice", name)
    }
    XCTAssertEqual(tools.jobs.runningCount, 0)
    XCTAssertEqual(code(wait { tools.merge(request: PdfMergeRequestMsg(jobId: "", inputs: [], outPath: out), completion: $0) }), "invalidArgument")
    XCTAssertEqual(code(wait { tools.merge(request: PdfMergeRequestMsg(jobId: "j1", inputs: [input], outPath: out), completion: $0) }), "invalidArgument")
    XCTAssertNoThrow(try tools.cancel(jobId: "unknown"))
  }

  func testJobsReportProgressAndCancel() throws {
    let jobs = PdfJobRegistry(events: nil)
    let job = try jobs.start(id: "a", tool: .merge)
    XCTAssertThrowsError(try jobs.start(id: "a", tool: .split))
    XCTAssertFalse(job.isCancelled)
    jobs.cancel(id: "a")
    XCTAssertTrue(job.isCancelled)
    jobs.finish(job)
    XCTAssertEqual(jobs.runningCount, 0)
    XCTAssertNoThrow(try jobs.start(id: "a", tool: .split))
  }

  func testErrorsMapToTypedCodes() {
    XCTAssertEqual(PdfErrors.from(PdfFailure(.damaged, "x")).code, "damaged")
    XCTAssertEqual(PdfErrors.from(NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError)).code, "noSpace")
    XCTAssertEqual(PdfErrors.from(NSError(domain: "other", code: 1)).code, "internal")
    XCTAssertEqual(PdfErrors.notSupported("HOM-28").code, "notSupportedOnDevice")
  }

  func testPlatformViewNavigatesSearchesHighlightsAndCopies() throws {
    let dir = TestPdfs.tempDir(self)
    let url = TestPdfs.fixture("text_200p.pdf")
      ?? TestPdfs.writeTextPdf(to: dir.appendingPathComponent("text_200p.pdf"), pages: 200, prefix: "HOM27T")
    let store = PdfDocumentStore()
    let registry = PdfViewRegistry()
    let views = PdfViewHostApiImpl(store: store, registry: registry)
    let summary = try store.open(path: url.path, password: nil)
    let factory = PdfViewFactory(store: store, registry: registry, events: nil)

    let controller = factory.makeController(viewId: 7, args: ["handle": NSNumber(value: summary.handle), "page": NSNumber(value: 3), "displayMode": "singlePage"])
    controller.nativeView?.frame = CGRect(x: 0, y: 0, width: 400, height: 600)
    controller.nativeView?.layoutSubtreeIfNeeded()
    XCTAssertEqual(registry.count, 1)

    var state = try views.state(viewId: 7)
    XCTAssertEqual(state.pageCount, 200)
    XCTAssertEqual(state.pageIndex, 3)
    XCTAssertEqual(state.displayMode, .singlePage)

    try views.goToPage(viewId: 7, pageIndex: 120)
    XCTAssertEqual(try views.state(viewId: 7).pageIndex, 120)
    XCTAssertThrowsError(try views.goToPage(viewId: 7, pageIndex: 999)) { XCTAssertEqual(($0 as? PdfPigeonError)?.code, "invalidArgument") }

    try views.setScale(viewId: 7, scale: 2)
    state = try views.state(viewId: 7)
    XCTAssertEqual(state.scale, 2, accuracy: 0.001)
    try views.setScale(viewId: 7, scale: 1000)
    XCTAssertEqual(try views.state(viewId: 7).scale, try views.state(viewId: 7).maxScale, accuracy: 0.001)
    try views.zoomToFit(viewId: 7)
    try views.setDisplayMode(viewId: 7, mode: .continuous)
    XCTAssertEqual(try views.state(viewId: 7).displayMode, .continuous)

    // Search finds the fixture string on its page; showing the hit moves there and highlights it.
    let result = try wait { views.search(viewId: 7, options: PdfSearchOptionsMsg(query: "HOM27T-P0150", caseSensitive: false, maxHits: 50), completion: $0) }.get()
    XCTAssertEqual(result.hits.map(\.pageIndex), [149])
    try views.showSearchHit(viewId: 7, hit: result.hits[0])
    XCTAssertEqual(controller.pdfView.highlightedSelections?.count, 1)
    XCTAssertEqual(try views.state(viewId: 7).pageIndex, 149)
    try views.clearSearch(viewId: 7)
    XCTAssertNil(controller.pdfView.highlightedSelections)

    // A newer search cancels the older one.
    let first = expectation(description: "first")
    var firstCode: String?
    views.search(viewId: 7, options: PdfSearchOptionsMsg(query: "e", caseSensitive: false, maxHits: 100000)) {
      XCTAssertTrue(Thread.isMainThread)
      if case .failure(let e) = $0 { firstCode = (e as? PdfPigeonError)?.code }
      first.fulfill()
    }
    try views.cancelSearch(viewId: 7)
    wait(for: [first], timeout: 30)
    XCTAssertTrue(firstCode == nil || firstCode == "cancelled")

    // Selection and copy (the user's pasteboard is restored).
    XCTAssertNil(try views.selectedText(viewId: 7))
    XCTAssertFalse(try views.copySelection(viewId: 7))
    let page = try XCTUnwrap(controller.document?.page(at: 149))
    let hitRange = NSRange(location: Int(result.hits[0].rangeStart), length: Int(result.hits[0].rangeLength))
    controller.pdfView.setCurrentSelection(page.selection(for: hitRange), animate: false)
    XCTAssertEqual(try views.selectedText(viewId: 7), "HOM27T-P0150")
    XCTAssertTrue(try views.state(viewId: 7).hasSelection)
    let saved = NSPasteboard.general.string(forType: .string)
    defer {
      NSPasteboard.general.clearContents()
      if let saved { NSPasteboard.general.setString(saved, forType: .string) }
    }
    XCTAssertTrue(try views.copySelection(viewId: 7))
    XCTAssertEqual(NSPasteboard.general.string(forType: .string), "HOM27T-P0150")
    try views.clearSelection(viewId: 7)
    XCTAssertNil(try views.selectedText(viewId: 7))

    // Thumbnails.
    let thumb = try wait { views.pageThumbnail(request: PdfThumbnailRequestMsg(handle: summary.handle, pageIndex: 0, maxWidthPx: 120, maxHeightPx: 160), completion: $0) }.get()
    XCTAssertEqual(thumb.heightPx, 160)
    XCTAssertEqual(Array(thumb.png.data.prefix(4)), [0x89, 0x50, 0x4E, 0x47])

    // The view keeps its document after the handle is closed.
    store.close(summary.handle)
    XCTAssertEqual(try views.state(viewId: 7).pageCount, 200)

    // Android-only calls.
    XCTAssertEqual(code(wait { views.createTextureView(request: PdfTextureViewRequestMsg(handle: 1, widthPx: 1, heightPx: 1, initialPage: 0, displayMode: .continuous), completion: $0) }), "notSupportedOnDevice")
    XCTAssertThrowsError(try views.disposeTextureView(viewId: 7))

    XCTAssertThrowsError(try views.state(viewId: 99)) { XCTAssertEqual(($0 as? PdfPigeonError)?.code, "notFound") }
  }

  func testThumbnailsRenderFromATwinWhileAViewDrawsTheDocument() throws {
    let dir = TestPdfs.tempDir(self)
    let url = TestPdfs.writeTextPdf(to: dir.appendingPathComponent("v.pdf"), pages: 12, prefix: "TWIN")
    let store = PdfDocumentStore()
    let registry = PdfViewRegistry()
    let views = PdfViewHostApiImpl(store: store, registry: registry)
    let documents = PdfDocumentHostApiImpl(store: store)
    let summary = try store.open(path: url.path, password: nil)
    let viewDocument = try store.document(summary.handle)
    let factory = PdfViewFactory(store: store, registry: registry, events: nil)
    let controller = factory.makeController(viewId: 11, args: ["handle": NSNumber(value: summary.handle), "displayMode": "continuous"])
    controller.nativeView?.frame = CGRect(x: 0, y: 0, width: 400, height: 600)
    controller.nativeView?.layoutSubtreeIfNeeded()
    XCTAssertTrue(controller.document === viewDocument)

    // Request every page's thumbnail while the main thread keeps moving and zooming the view.
    var replies = 0
    let all = expectation(description: "thumbnails")
    all.expectedFulfillmentCount = 12
    for page in 0..<12 {
      views.pageThumbnail(request: PdfThumbnailRequestMsg(handle: summary.handle, pageIndex: Int64(page), maxWidthPx: 90, maxHeightPx: 120)) {
        XCTAssertTrue(Thread.isMainThread)
        if case .success(let image) = $0, Array(image.png.data.prefix(4)) == [0x89, 0x50, 0x4E, 0x47] { replies += 1 }
        all.fulfill()
      }
    }
    for step in 0..<12 {
      try views.goToPage(viewId: 11, pageIndex: Int64(step))
      try views.setScale(viewId: 11, scale: step.isMultiple(of: 2) ? 1.5 : 1)
      controller.nativeView?.display()
    }
    wait(for: [all], timeout: 30)
    XCTAssertEqual(replies, 12)
    XCTAssertEqual(views.renderTwinCount, 1, "one twin per handle, reused")

    // The outline reads a twin too and replies on main; close drops the thumbnail twin.
    XCTAssertEqual(try wait { documents.outline(handle: summary.handle, completion: $0) }.get().count, 0)
    try documents.close(handle: summary.handle)
    XCTAssertEqual(views.renderTwinCount, 0)
    XCTAssertEqual(code(wait { views.pageThumbnail(request: PdfThumbnailRequestMsg(handle: summary.handle, pageIndex: 0, maxWidthPx: 90, maxHeightPx: 120), completion: $0) }), "notFound")
    XCTAssertEqual(try views.state(viewId: 11).pageCount, 12, "the view keeps its document")
  }

  func testUnknownHandleGivesAnEmptyViewNotACrash() throws {
    let registry = PdfViewRegistry()
    let factory = PdfViewFactory(store: PdfDocumentStore(), registry: registry, events: nil)
    let view = factory.create(withViewIdentifier: 3, arguments: ["handle": NSNumber(value: 999)])
    XCTAssertTrue(view is PdfContainerView)
    XCTAssertEqual(try registry.controller(3).state().pageCount, 0)
  }
}
