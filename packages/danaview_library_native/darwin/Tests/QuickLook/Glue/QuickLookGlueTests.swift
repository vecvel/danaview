// OWNER: HOM-26
//
// XCTests of QuickLookHostApiImpl and ThumbnailHostApiImpl.documentThumbnail on macOS, linked
// against FlutterMacOS (BUILD_PLAN HOM-26), with a fake presenter instead of system UI:
//
// * canPreview: docx, xlsx, pptx, txt and csv are previewed, an unknown type is carded, a missing
//   file is a typed notFound.
// * present: Quick Look only ever sees read-only copies in a temporary batch, never the library
//   file; a Markup attempt (writing the previewed file in place, saving an edited copy over it)
//   can't change the stored file (bytes and modification date compared); the reply comes on the
//   main thread when the preview is dismissed and the batch is gone then; one preview at a time;
//   bad requests and a failed presentation are typed errors that leave nothing behind.
// * documentThumbnail through the Pigeon API: a PDF at the request's scale, nil for a password
//   PDF, validation, busy ids, cancel.

import FlutterMacOS
import XCTest

@testable import danaview_library_native

final class QuickLookGlueTests: XCTestCase {
  private final class NullMessenger: NSObject, FlutterBinaryMessenger {
    func send(onChannel channel: String, message: Data?) {}
    func send(onChannel channel: String, message: Data?, binaryReply callback: FlutterBinaryReply? = nil) {}
    func setMessageHandlerOnChannel(_ channel: String, binaryMessageHandler handler: FlutterBinaryMessageHandler? = nil) -> FlutterBinaryMessengerConnection { 0 }
    func cleanUpConnection(_ connection: FlutterBinaryMessengerConnection) {}
  }

  /// Records what it was asked to show and, like a Markup session, tries to change it.
  private final class FakePresenter: QuickLookPresenter {
    var systemAnswer = true
    var failShow: OutFailure?
    var presented: [(urls: [URL], titles: [String], index: Int)] = []
    var markupWriteErrors = 0
    var dismiss: (() -> Void)?

    func systemCanPreview(_ url: URL) -> Bool { systemAnswer }

    func present(urls: [URL], titles: [String], initialIndex: Int, shown: @escaping (Result<Void, OutFailure>) -> Void, dismissed: @escaping () -> Void) {
      presented.append((urls, titles, initialIndex))
      if let f = failShow { return shown(.failure(f)) }
      for u in urls {
        // In place (no atomic replace), as `.updateContents` would.
        do {
          try Data("MARKUP".utf8).write(to: u)
        } catch {
          markupWriteErrors += 1
        }
      }
      shown(.success(()))
      dismiss = dismissed
    }
  }

  private var dir: URL!
  private var tempRoot: URL!
  private var presenter: FakePresenter!
  private var api: QuickLookHostApiImpl!

  override func setUpWithError() throws {
    dir = FileManager.default.temporaryDirectory.appendingPathComponent("hom26-glue-\(UUID().uuidString)", isDirectory: true)
    tempRoot = dir.appendingPathComponent("out", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    presenter = FakePresenter()
    api = QuickLookHostApiImpl(presenter: presenter, temp: TempCopyStore(root: tempRoot))
  }

  override func tearDownWithError() throws {
    if let tempRoot = tempRoot, let items = try? FileManager.default.subpathsOfDirectory(atPath: tempRoot.path) {
      for p in items { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tempRoot.appendingPathComponent(p).path) }
    }
    try? FileManager.default.removeItem(at: dir)
  }

  private func item(_ url: URL, _ name: String? = nil, uti: String? = nil) -> FileItemMsg {
    FileItemMsg(path: url.path, displayName: name ?? url.lastPathComponent, mimeType: nil, uti: uti)
  }

  private func canPreview(_ m: FileItemMsg) -> Result<Bool, Error>? {
    var got: Result<Bool, Error>?
    api.canPreview(item: m) { got = $0 }
    return got
  }

  private func waitMain(_ condition: @escaping () -> Bool, file: StaticString = #filePath, line: UInt = #line) {
    let e = expectation(description: "condition")
    func poll() { if condition() { e.fulfill() } else { DispatchQueue.main.asyncAfter(deadline: .now() + 0.01, execute: poll) } }
    poll()
    wait(for: [e], timeout: 5)
  }

  func testCanPreviewOfficeTextCsvAndCardsTheRest() throws {
    for kind in ["docx", "xlsx", "pptx"] {
      let u = dir.appendingPathComponent("f.\(kind)")
      try QuickLookTestDocs.office(at: u, kind: kind)
      guard case .success(true)? = canPreview(item(u)) else { return XCTFail("\(kind) not previewed") }
    }
    let txt = dir.appendingPathComponent("a.txt")
    try QuickLookTestDocs.text(at: txt)
    let csv = dir.appendingPathComponent("t.csv")
    try QuickLookTestDocs.text(at: csv, "a;b\n1;2\n")
    guard case .success(true)? = canPreview(item(txt)), case .success(true)? = canPreview(item(csv)) else { return XCTFail("text not previewed") }
    let unknown = dir.appendingPathComponent("x.qqzz")
    try QuickLookTestDocs.unknown(at: unknown)
    guard case .success(false)? = canPreview(item(unknown)) else { return XCTFail("unknown type previewed") }
    presenter.systemAnswer = false
    guard case .success(false)? = canPreview(item(txt)) else { return XCTFail("the system's no was ignored") }
    guard case .failure(let e)? = canPreview(item(dir.appendingPathComponent("missing.docx"))) else { return XCTFail("missing file answered") }
    XCTAssertEqual((e as? LibraryPigeonError)?.code, "notFound")
  }

  func testAMarkupAttemptCannotChangeTheStoredFile() throws {
    let docx = dir.appendingPathComponent("stored-blob")
    try QuickLookTestDocs.office(at: docx, kind: "docx")
    let txt = dir.appendingPathComponent("notes.txt")
    try QuickLookTestDocs.text(at: txt)
    let sources = [docx, txt]
    let before = try sources.map { try Data(contentsOf: $0) }
    let dates = try sources.map { try FileManager.default.attributesOfItem(atPath: $0.path)[.modificationDate] as? Date }

    var got: Result<Void, Error>?
    api.present(request: QuickLookRequestMsg(items: [item(docx, "Report.docx"), item(txt)], initialIndex: 1)) { got = $0 }
    let shown = try XCTUnwrap(presenter.presented.first)
    XCTAssertEqual(shown.index, 1)
    XCTAssertEqual(shown.titles, ["Report.docx", "notes.txt"])
    XCTAssertEqual(shown.urls.map { $0.lastPathComponent }, ["Report.docx", "notes.txt"], "copies carry the names the user knows")
    for (u, src) in zip(shown.urls, sources) {
      XCTAssertNotEqual(u.standardizedFileURL.path, src.standardizedFileURL.path, "Quick Look sees a copy")
      XCTAssertTrue(u.standardizedFileURL.path.hasPrefix(tempRoot.standardizedFileURL.path))
      let perms = try FileManager.default.attributesOfItem(atPath: u.path)[.posixPermissions] as? Int
      XCTAssertEqual(perms, 0o444, "read-only copy")
    }
    XCTAssertEqual(presenter.markupWriteErrors, 2, "in-place writes to the previewed copies fail")

    // An edited copy saved over the previewed file (atomic replace) still never reaches the library.
    try Data("EDITED".utf8).write(to: shown.urls[0], options: .atomic)
    XCTAssertNil(got, "no reply before the preview closes")

    presenter.dismiss?()
    waitMain { got != nil }
    guard case .success? = got else { return XCTFail("present did not succeed") }
    XCTAssertTrue(Thread.isMainThread)
    XCTAssertEqual(try sources.map { try Data(contentsOf: $0) }, before, "stored bytes unchanged")
    XCTAssertEqual(try sources.map { try FileManager.default.attributesOfItem(atPath: $0.path)[.modificationDate] as? Date }, dates)
    XCTAssertFalse(FileManager.default.fileExists(atPath: shown.urls[0].deletingLastPathComponent().path), "batch removed on dismiss")
    XCTAssertFalse(QuickLookPolicy.editingAllowed)
  }

  func testOnePreviewAtATimeAndBadRequests() throws {
    let txt = dir.appendingPathComponent("a.txt")
    try QuickLookTestDocs.text(at: txt)
    var first: Result<Void, Error>?
    api.present(request: QuickLookRequestMsg(items: [item(txt)], initialIndex: 0)) { first = $0 }
    var second: Result<Void, Error>?
    api.present(request: QuickLookRequestMsg(items: [item(txt)], initialIndex: 0)) { second = $0 }
    guard case .failure(let busy)? = second else { return XCTFail("second preview allowed") }
    XCTAssertEqual((busy as? LibraryPigeonError)?.code, "busy")
    presenter.dismiss?()
    waitMain { first != nil }

    for (request, code) in [
      (QuickLookRequestMsg(items: [], initialIndex: 0), "invalidArgument"),
      (QuickLookRequestMsg(items: [item(txt)], initialIndex: 1), "invalidArgument"),
      (QuickLookRequestMsg(items: [item(txt)], initialIndex: -1), "invalidArgument"),
      (QuickLookRequestMsg(items: [item(dir.appendingPathComponent("missing.txt"))], initialIndex: 0), "notFound"),
    ] {
      var got: Result<Void, Error>?
      api.present(request: request) { got = $0 }
      waitMain { got != nil }
      guard case .failure(let e)? = got else { return XCTFail("\(code) not raised") }
      XCTAssertEqual((e as? LibraryPigeonError)?.code, code)
    }
    XCTAssertEqual(presenter.presented.count, 1)
  }

  func testAFailedPresentationIsTypedAndLeavesNothing() throws {
    let txt = dir.appendingPathComponent("a.txt")
    try QuickLookTestDocs.text(at: txt)
    presenter.failShow = .io("no window to present from")
    var got: Result<Void, Error>?
    api.present(request: QuickLookRequestMsg(items: [item(txt)], initialIndex: 0)) { got = $0 }
    waitMain { got != nil }
    guard case .failure(let e)? = got else { return XCTFail("failure not reported") }
    XCTAssertEqual((e as? LibraryPigeonError)?.code, "ioError")
    XCTAssertEqual(api.temp.batches(), [], "batch removed")
    presenter.failShow = nil
    var again: Result<Void, Error>?
    api.present(request: QuickLookRequestMsg(items: [item(txt)], initialIndex: 0)) { again = $0 }
    XCTAssertEqual(presenter.presented.count, 2, "not left busy")
    presenter.dismiss?()
    waitMain { again != nil }
  }

  // MARK: documentThumbnail

  private func thumbs() -> ThumbnailHostApiImpl {
    ThumbnailHostApiImpl(context: LibraryPluginContext(messenger: NullMessenger(), events: LibraryEventHub()))
  }

  private func document(_ api: ThumbnailHostApiImpl, id: String = UUID().uuidString, path: String, box: Int64 = 512, scale: Double = 2) -> Result<ThumbnailResultMsg?, Error>? {
    var got: Result<ThumbnailResultMsg?, Error>?
    api.documentThumbnail(request: DocumentThumbnailRequestMsg(requestId: id, path: path, widthPx: box, heightPx: box, scale: scale, format: .jpeg,
                                                                quality: 0.8, outputPath: dir.appendingPathComponent("cache/\(id).jpg").path)) { got = $0 }
    waitMain { got != nil }
    return got
  }

  func testDocumentThumbnailOfAPdfAtTheRequestScale() throws {
    let pdf = dir.appendingPathComponent("a.pdf")
    try QuickLookTestDocs.pdf(at: pdf, size: CGSize(width: 200, height: 100))
    let api = thumbs()
    guard case .success(let r?)? = document(api, path: pdf.path, scale: 3) else { return XCTFail("no thumbnail") }
    XCTAssertEqual(r.widthPx, 512)
    XCTAssertEqual(r.heightPx, 256)
    XCTAssertEqual(r.format, .jpeg)
    XCTAssertTrue(FileManager.default.fileExists(atPath: r.path))
    guard case .success(let one?)? = document(api, path: pdf.path, scale: 1) else { return XCTFail("no 1x thumbnail") }
    XCTAssertEqual(one.widthPx, 200)
  }

  func testDocumentThumbnailOfAPasswordPdfIsNil() throws {
    let locked = dir.appendingPathComponent("locked.pdf")
    try QuickLookTestDocs.encryptedPdf(at: locked, userPassword: "open-sesame")
    guard case .success(nil)? = document(thumbs(), path: locked.path) else { return XCTFail("password PDF got a thumbnail") }
    let open = dir.appendingPathComponent("open.pdf")
    try QuickLookTestDocs.encryptedPdf(at: open, userPassword: "")
    guard case .success(.some)? = document(thumbs(), path: open.path) else { return XCTFail("empty-password PDF had none") }
  }

  func testDocumentThumbnailValidationBusyAndCancel() throws {
    let api = thumbs()
    for (path, scale, code) in [("/x.pdf", 0.0, "invalidArgument"), ("x.pdf", 2.0, "invalidArgument"), (dir.appendingPathComponent("missing.pdf").path, 2.0, "notFound")] {
      guard case .failure(let e)? = document(api, path: path, scale: scale) else { return XCTFail("\(code) not raised") }
      XCTAssertEqual((e as? LibraryPigeonError)?.code, code)
    }
    let pdf = dir.appendingPathComponent("big.pdf")
    try QuickLookTestDocs.pdf(at: pdf, size: CGSize(width: 2000, height: 2000))
    // Fill the queue so the next request waits, then cancel it before it starts.
    var results: [String: Result<ThumbnailResultMsg?, Error>] = [:]
    for i in 0..<(ThumbnailHostApiImpl.maxConcurrent + 2) {
      let id = "q\(i)"
      api.documentThumbnail(request: DocumentThumbnailRequestMsg(requestId: id, path: pdf.path, widthPx: 4096, heightPx: 4096, scale: 2, format: .jpeg,
                                                                  quality: 0.8, outputPath: dir.appendingPathComponent("cache/\(id).jpg").path)) { results[id] = $0 }
    }
    var dup: Result<ThumbnailResultMsg?, Error>?
    api.documentThumbnail(request: DocumentThumbnailRequestMsg(requestId: "q0", path: pdf.path, widthPx: 64, heightPx: 64, scale: 2, format: .jpeg,
                                                                quality: 0.8, outputPath: dir.appendingPathComponent("cache/dup.jpg").path)) { dup = $0 }
    let last = "q\(ThumbnailHostApiImpl.maxConcurrent + 1)"
    try api.cancel(requestId: last)
    waitMain { results.count == ThumbnailHostApiImpl.maxConcurrent + 2 && dup != nil }
    guard case .failure(let d)? = dup else { return XCTFail("duplicate id accepted") }
    XCTAssertEqual((d as? LibraryPigeonError)?.code, "busy")
    guard case .failure(let c)? = results[last] else { return XCTFail("cancelled request succeeded") }
    XCTAssertEqual((c as? LibraryPigeonError)?.code, "cancelled")
    guard case .success(.some)? = results["q0"] else { return XCTFail("first request failed") }
  }
}
