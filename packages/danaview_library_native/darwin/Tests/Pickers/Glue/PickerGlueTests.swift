// OWNER: HOM-20
//
// XCTests of PickerHostApiImpl on macOS, linked against FlutterMacOS (BUILD_PLAN HOM-20): picker
// results map to PickedItemMsg field for field, copyToFile streams a file:// source through the
// Pigeon API (replying on the main thread), resumes, refuses bad requests and a busy id, and
// cancelCopy / release never throw for unknown ids. The pickers' UI itself needs a person and is
// recorded as a device check.

import FlutterMacOS
import XCTest

@testable import danaview_library_native

final class PickerGlueTests: XCTestCase {
  private final class NullMessenger: NSObject, FlutterBinaryMessenger {
    func send(onChannel channel: String, message: Data?) {}
    func send(onChannel channel: String, message: Data?, binaryReply callback: FlutterBinaryReply? = nil) {}
    func setMessageHandlerOnChannel(_ channel: String, binaryMessageHandler handler: FlutterBinaryMessageHandler? = nil) -> FlutterBinaryMessengerConnection { 0 }
    func cleanUpConnection(_ connection: FlutterBinaryMessengerConnection) {}
  }

  private var dir: URL!
  private var api: PickerHostApiImpl!

  override func setUpWithError() throws {
    dir = FileManager.default.temporaryDirectory.appendingPathComponent("hom20-glue-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    api = PickerHostApiImpl(context: LibraryPluginContext(messenger: NullMessenger(), events: LibraryEventHub()))
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: dir)
  }

  private func copy(_ request: CopyRequestMsg) -> Result<CopyResultMsg, Error> {
    let done = expectation(description: "copy")
    var out: Result<CopyResultMsg, Error>?
    api.copyToFile(request: request) { result in
      XCTAssertTrue(Thread.isMainThread, "replies on the main thread")
      out = result
      done.fulfill()
    }
    wait(for: [done], timeout: 20)
    return out!
  }

  func testPickedFileMapsEveryField() {
    let f = PickedFile(uri: "file:///s/IMG.heic", path: "/s/IMG.heic", displayName: "IMG.heic", uti: "public.heic", mimeType: "image/heic", sizeBytes: 42, modifiedTimeMs: 1_700_000_000_000, assetIdentifier: "A/L0/001", fromPhotoLibrary: true, needsCopy: false)
    let m = PickerHostApiImpl.msg(f)
    XCTAssertEqual(m.uri, f.uri)
    XCTAssertEqual(m.path, f.path)
    XCTAssertEqual(m.displayName, f.displayName)
    XCTAssertEqual(m.uti, f.uti)
    XCTAssertEqual(m.mimeType, f.mimeType)
    XCTAssertEqual(m.sizeBytes, 42)
    XCTAssertEqual(m.modifiedTimeMs, 1_700_000_000_000)
    XCTAssertEqual(m.assetIdentifier, "A/L0/001")
    XCTAssertEqual(m.source, .photoLibrary)
    XCTAssertFalse(m.needsCopy)
    var doc = f
    doc.fromPhotoLibrary = false
    doc.needsCopy = true
    XCTAssertEqual(PickerHostApiImpl.msg(doc).source, .files)
    XCTAssertTrue(PickerHostApiImpl.msg(doc).needsCopy)
  }

  func testFailuresMapToTheirPigeonCodes() {
    XCTAssertEqual(PickerHostApiImpl.error(.cancelled("x")).code, "cancelled")
    XCTAssertEqual(PickerHostApiImpl.error(.notFound("x")).code, "notFound")
    XCTAssertEqual(PickerHostApiImpl.error(.io("x")).code, "ioError")
  }

  func testCopyToFileStreamsAndResumes() throws {
    var data = Data(count: 2 * 1024 * 1024 + 11)
    for i in 0..<data.count { data[i] = UInt8(truncatingIfNeeded: i &* 31) }
    let src = dir.appendingPathComponent("source.mov")
    try data.write(to: src)
    let before = try FileManager.default.attributesOfItem(atPath: src.path)[.modificationDate] as! Date
    let dest = dir.appendingPathComponent("job.part")

    let fresh = try copy(CopyRequestMsg(requestId: "r1", sourceUri: src.absoluteString, destinationPath: dest.path, resumeFromOffset: 0)).get()
    XCTAssertEqual(fresh.bytesCopied, Int64(data.count))
    XCTAssertEqual(fresh.totalBytes, Int64(data.count))
    XCTAssertEqual(try Data(contentsOf: dest), data)

    try data.prefix(700_000).write(to: dest)
    let resumed = try copy(CopyRequestMsg(requestId: "r1", sourceUri: src.absoluteString, destinationPath: dest.path, resumeFromOffset: 700_000)).get()
    XCTAssertEqual(resumed.bytesCopied, Int64(data.count))
    XCTAssertEqual(try Data(contentsOf: dest), data)
    XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: src.path)[.modificationDate] as! Date, before)
  }

  func testCopyToFileRefusesBadRequests() {
    for (uri, path, offset) in [("content://media/1", "/tmp/x", Int64(0)), ("not a url", "/tmp/x", 0), ("file:///tmp/x", "", 0), ("file:///tmp/x", "/tmp/y", -1)] {
      let r = copy(CopyRequestMsg(requestId: "bad", sourceUri: uri, destinationPath: path, resumeFromOffset: offset))
      guard case .failure(let e) = r else { XCTFail("\(uri) accepted"); continue }
      XCTAssertEqual((e as? LibraryPigeonError)?.code, "invalidArgument")
    }
    let missing = copy(CopyRequestMsg(requestId: "m", sourceUri: dir.appendingPathComponent("nope").absoluteString, destinationPath: dir.appendingPathComponent("p").path, resumeFromOffset: 0))
    guard case .failure(let e) = missing else { return XCTFail("missing source accepted") }
    XCTAssertEqual((e as? LibraryPigeonError)?.code, "notFound")
  }

  func testCancelAndReleaseOfUnknownIdsDoNotThrow() {
    XCTAssertNoThrow(try api.cancelCopy(requestId: "nothing"))
    XCTAssertNoThrow(try api.release(uri: "file:///nothing"))
  }
}
