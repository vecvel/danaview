// OWNER: HOM-04
//
// XCTests of ThumbnailHostApiImpl on macOS, linked against FlutterMacOS (BUILD_PLAN HOM-04): a
// media file's thumbnail through the Pigeon API (reply on the main thread, result fields, format
// actually written), validation (box, quality, relative output path, unknown and Android sources),
// a busy request id, cancel of a running request and of unknown ids, updateCaching without photo
// access, a corrupt file as a typed ioError, and documentThumbnail still HOM-26's.

import FlutterMacOS
import XCTest

@testable import danaview_library_native

final class ThumbnailGlueTests: XCTestCase {
  private final class NullMessenger: NSObject, FlutterBinaryMessenger {
    func send(onChannel channel: String, message: Data?) {}
    func send(onChannel channel: String, message: Data?, binaryReply callback: FlutterBinaryReply? = nil) {}
    func setMessageHandlerOnChannel(_ channel: String, binaryMessageHandler handler: FlutterBinaryMessageHandler? = nil) -> FlutterBinaryMessengerConnection { 0 }
    func cleanUpConnection(_ connection: FlutterBinaryMessengerConnection) {}
  }

  private var dir: URL!
  private var api: ThumbnailHostApiImpl!

  override func setUpWithError() throws {
    dir = FileManager.default.temporaryDirectory.appendingPathComponent("hom04-glue-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    api = ThumbnailHostApiImpl(context: LibraryPluginContext(messenger: NullMessenger(), events: LibraryEventHub()))
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: dir)
  }

  private func request(_ source: String, id: String = UUID().uuidString, w: Int64 = 240, h: Int64 = 240, mode: ThumbnailModeMsg = .fill, format: ThumbnailFormatMsg = .jpeg, quality: Double = 0.8, output: String? = nil) -> MediaThumbnailRequestMsg {
    MediaThumbnailRequestMsg(requestId: id, source: source, widthPx: w, heightPx: h, mode: mode, format: format, quality: quality,
                             outputPath: output ?? dir.appendingPathComponent("thumbs/m/\(id).jpg").path)
  }

  private func run(_ r: MediaThumbnailRequestMsg, then: (() -> Void)? = nil) -> Result<ThumbnailResultMsg, Error> {
    let done = expectation(description: "thumb")
    var out: Result<ThumbnailResultMsg, Error>?
    api.mediaThumbnail(request: r) { result in
      XCTAssertTrue(Thread.isMainThread, "replies on the main thread")
      out = result
      done.fulfill()
    }
    then?()
    wait(for: [done], timeout: 30)
    return out!
  }

  private func code(_ r: Result<ThumbnailResultMsg, Error>) -> String? {
    if case .failure(let e) = r { return (e as? LibraryPigeonError)?.code }
    return nil
  }

  private func jpeg(_ name: String, w: Int = 1200, h: Int = 900) throws -> String {
    try ThumbnailTestMedia.write(dir.appendingPathComponent(name), type: "public.jpeg", width: w, height: h).path
  }

  func testFileThumbnailThroughThePigeonApi() throws {
    let src = try jpeg("a.jpg")
    let r = request(src, format: .heic)
    let m = try run(r).get()
    XCTAssertEqual(m.path, r.outputPath)
    XCTAssertEqual([m.widthPx, m.heightPx], [240, 240])
    XCTAssertEqual(m.format, .jpeg, "macOS writes JPEG for a HEIC request")
    XCTAssertTrue(FileManager.default.fileExists(atPath: r.outputPath))
    let fit = try run(request(URL(fileURLWithPath: src).absoluteString, mode: .fit, format: .png)).get()
    XCTAssertEqual(fit.widthPx, 240)
    XCTAssertEqual(fit.heightPx, 180)
    XCTAssertEqual(fit.format, .png)
    let webp = try run(request(src, format: .webp)).get()
    XCTAssertEqual(webp.format, .jpeg, "ImageIO has no WebP encoder")
  }

  func testValidation() throws {
    let src = try jpeg("v.jpg")
    XCTAssertEqual(code(run(request(src, w: 0))), "invalidArgument")
    XCTAssertEqual(code(run(request(src, h: 5000))), "invalidArgument")
    XCTAssertEqual(code(run(request(src, quality: 1.5))), "invalidArgument")
    XCTAssertEqual(code(run(request(src, id: ""))), "invalidArgument")
    XCTAssertEqual(code(run(request(src, output: "relative/out.jpg"))), "invalidArgument")
    XCTAssertEqual(code(run(request("relative.jpg"))), "invalidArgument")
    XCTAssertEqual(code(run(request("ms:42"))), "notSupportedOnDevice")
    XCTAssertEqual(code(run(request("content://media/external/images/media/42"))), "notSupportedOnDevice")
  }

  func testMissingAndCorruptFiles() throws {
    XCTAssertEqual(code(run(request(dir.appendingPathComponent("gone.jpg").path))), "notFound")
    let bad = try ThumbnailTestMedia.corrupt(dir.appendingPathComponent("bad.jpg")).path
    XCTAssertEqual(code(run(request(bad))), "ioError")
  }

  func testWithoutPhotoAccessAnAssetIsPermissionDenied() throws {
    try XCTSkipIf(PhotoAssetThumbnailer.canRead(), "this process has photo access")
    XCTAssertEqual(code(run(request("ph:ANY/L0/001"))), "permissionDenied")
    XCTAssertNoThrow(try api.updateCaching(window: ThumbnailCachingMsg(startSources: ["ph:ANY/L0/001"], stopSources: [], widthPx: 64, heightPx: 64, mode: .fill)))
  }

  func testBusyIdAndCancel() throws {
    let src = try ThumbnailTestMedia.movie(dir.appendingPathComponent("m.mov"), width: 1280, height: 720).path
    let first = request(src, id: "same")
    let done = expectation(description: "first")
    var firstResult: Result<ThumbnailResultMsg, Error>?
    api.mediaThumbnail(request: first) { firstResult = $0; done.fulfill() }
    // A second request with the running id is busy (unless the first already finished).
    let second = run(request(src, id: "same"))
    if firstResult == nil { XCTAssertEqual(code(second), "busy") }
    try api.cancel(requestId: "same")
    wait(for: [done], timeout: 30)
    if case .failure(let e) = firstResult! {
      XCTAssertEqual((e as? LibraryPigeonError)?.code, "cancelled")
      XCTAssertFalse(FileManager.default.fileExists(atPath: first.outputPath), "a cancelled request leaves no file")
    }
    XCTAssertNoThrow(try api.cancel(requestId: "unknown"))
    // The id is free again.
    XCTAssertNotNil(try? run(request(try jpeg("after.jpg"), id: "same")).get())
  }

  func testCancelBeforeTheQueueStartsIt() throws {
    let src = try jpeg("q.jpg")
    // Fill the queue so later requests wait, then cancel one that has not started.
    let busy = (0..<ThumbnailHostApiImpl.maxConcurrent * 2).map { _ in expectation(description: "fill") }
    for (i, e) in busy.enumerated() {
      api.mediaThumbnail(request: request(src, id: "fill-\(i)", w: 2048, h: 2048)) { _ in e.fulfill() }
    }
    let last = expectation(description: "last")
    var result: Result<ThumbnailResultMsg, Error>?
    api.mediaThumbnail(request: request(src, id: "late")) { result = $0; last.fulfill() }
    try api.cancel(requestId: "late")
    wait(for: busy + [last], timeout: 60)
    XCTAssertEqual(code(result!), "cancelled")
  }

  func testUpdateCachingValidatesTheBox() {
    XCTAssertThrowsError(try api.updateCaching(window: ThumbnailCachingMsg(startSources: [], stopSources: [], widthPx: 0, heightPx: 64, mode: .fill))) {
      XCTAssertEqual(($0 as? LibraryPigeonError)?.code, "invalidArgument")
    }
    XCTAssertNoThrow(try api.updateCaching(window: ThumbnailCachingMsg(startSources: [], stopSources: [], widthPx: 64, heightPx: 64, mode: .fit)))
  }

  func testDocumentThumbnailIsStillHom26s() {
    var got: Result<ThumbnailResultMsg?, Error>?
    api.documentThumbnail(request: DocumentThumbnailRequestMsg(requestId: "d", path: "/tmp/x.pdf", widthPx: 64, heightPx: 64, scale: 2, format: .jpeg, quality: 0.8, outputPath: "/tmp/d.jpg")) { got = $0 }
    guard case .failure(let e)? = got else { return XCTFail("documentThumbnail did not fail") }
    XCTAssertEqual((e as? LibraryPigeonError)?.code, "notSupportedOnDevice")
  }

  func testFormatAndModeMappingsRoundTrip() {
    for f in ThumbnailFormatMsg.allCases {
      XCTAssertEqual(ThumbnailHostApiImpl.formatMsg(ThumbnailHostApiImpl.format(f)), f)
    }
    XCTAssertEqual(ThumbnailHostApiImpl.fit(.fill), .fill)
    XCTAssertEqual(ThumbnailHostApiImpl.fit(.fit), .fit)
  }
}
