// OWNER: HOM-02
//
// Glue tests (macOS, linked against FlutterMacOS): every placeholder class of a later ticket that
// has not landed yet answers `notSupportedOnDevice` (BUILD_PLAN HOM-02), Incoming is Android-only, the backup flag
// round-trips on a temporary file, and the Pigeon conversions keep every field.

import FlutterMacOS
import XCTest

@testable import danaview_library_native

final class LibraryGlueTests: XCTestCase {
  private final class NullMessenger: NSObject, FlutterBinaryMessenger {
    func send(onChannel channel: String, message: Data?) {}
    func send(onChannel channel: String, message: Data?, binaryReply callback: FlutterBinaryReply? = nil) {}
    func setMessageHandlerOnChannel(_ channel: String, binaryMessageHandler handler: FlutterBinaryMessageHandler? = nil) -> FlutterBinaryMessengerConnection { 0 }
    func cleanUpConnection(_ connection: FlutterBinaryMessengerConnection) {}
  }

  private let context = LibraryPluginContext(messenger: NullMessenger(), events: LibraryEventHub())

  private func assertNotSupported<T>(_ name: String, file: StaticString = #filePath, line: UInt = #line, _ call: (@escaping (Result<T, Error>) -> Void) -> Void) {
    var got: Result<T, Error>?
    call { got = $0 }
    guard case .failure(let error)? = got else { return XCTFail("\(name) did not fail synchronously", file: file, line: line) }
    XCTAssertEqual((error as? LibraryPigeonError)?.code, "notSupportedOnDevice", name, file: file, line: line)
  }

  private func assertThrowsNotSupported(_ name: String, file: StaticString = #filePath, line: UInt = #line, _ call: () throws -> Void) {
    XCTAssertThrowsError(try call(), name, file: file, line: line) { error in
      XCTAssertEqual((error as? LibraryPigeonError)?.code, "notSupportedOnDevice", name, file: file, line: line)
    }
  }

  func testEveryPlaceholderAnswersNotSupportedOnDevice() {
    // Pickers (HOM-20), Thumbnails (HOM-04), ExportOut / Share / OpenIn (HOM-22) and Quick Look with
    // document thumbnails (HOM-26) are implemented; only placeholder answers are checked.
    let inbox = InboxHostApiImpl(context: context)
    assertThrowsNotSupported("isAvailable") { _ = try inbox.isAvailable() }
    assertNotSupported("listBatches") { inbox.listBatches(completion: $0) }
    assertNotSupported("takeFile") { inbox.takeFile(batchId: "b", relativePath: "a", destinationPath: "/tmp/a", completion: $0) }
    assertNotSupported("deleteBatch") { inbox.deleteBatch(batchId: "b", completion: $0) }
    assertNotSupported("deleteStaleBatches") { inbox.deleteStaleBatches(olderThanMs: 1, completion: $0) }
    assertNotSupported("writeFolderSnapshot") { inbox.writeFolderSnapshot(json: FlutterStandardTypedData(bytes: Data()), completion: $0) }

    let incoming = IncomingHostApiImpl(context: context)
    assertThrowsNotSupported("takePending") { _ = try incoming.takePending() }
    assertThrowsNotSupported("acknowledge") { try incoming.acknowledge(batchId: "b") }
  }

  func testLimitedPickerIsNotSupportedOnMacOS() {
    let api = PhotoLibraryHostApiImpl(context: context)
    assertNotSupported("presentLimitedLibraryPicker") { api.presentLimitedLibraryPicker(completion: $0) }
  }

  func testBackupFlagRoundTrips() throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("dv_backup_\(UUID().uuidString)")
    try Data([1, 2, 3]).write(to: file)
    defer { try? FileManager.default.removeItem(at: file) }
    let api = BackupFlagHostApiImpl(context: context)
    func set(_ v: Bool) {
      let done = expectation(description: "set")
      api.setExcludedFromBackup(path: file.path, excluded: v) { r in
        if case .failure(let e) = r { XCTFail("\(e)") }
        done.fulfill()
      }
      wait(for: [done], timeout: 5)
    }
    func get() -> Bool? {
      let done = expectation(description: "get")
      var out: Bool?
      api.isExcludedFromBackup(path: file.path) { out = try? $0.get(); done.fulfill() }
      wait(for: [done], timeout: 5)
      return out
    }
    XCTAssertEqual(get(), false)
    set(true)
    XCTAssertEqual(get(), true)
    set(false)
    XCTAssertEqual(get(), false)
    XCTAssertEqual(try Data(contentsOf: file), Data([1, 2, 3]), "bytes untouched")

    let missing = expectation(description: "missing")
    api.setExcludedFromBackup(path: "/nonexistent/dv_\(UUID().uuidString)", excluded: true) { r in
      if case .failure(let e) = r { XCTAssertEqual((e as? LibraryPigeonError)?.code, "notFound") } else { XCTFail() }
      missing.fulfill()
    }
    let relative = expectation(description: "relative")
    api.isExcludedFromBackup(path: "relative/path") { r in
      if case .failure(let e) = r { XCTAssertEqual((e as? LibraryPigeonError)?.code, "invalidArgument") } else { XCTFail() }
      relative.fulfill()
    }
    wait(for: [missing, relative], timeout: 5)
  }

  func testConversionsKeepEveryField() {
    let record = PhotoAssetRecord(
      localIdentifier: "A/L0/001", kind: .video, widthPx: 1920, heightPx: 1080, creationTimeMs: 1, modificationTimeMs: 2,
      durationMs: 3_500, isFavorite: true, isRaw: false, isHdr: true, isLivePhoto: false, isScreenshot: false,
      originalFilename: "clip.mov", uti: "com.apple.quicktime-movie", mimeType: "video/quicktime")
    let m = PhotoLibraryHostApiImpl.msg(record)
    XCTAssertEqual(m.localIdentifier, "A/L0/001")
    XCTAssertEqual(m.kind, .video)
    XCTAssertEqual(m.widthPx, 1920)
    XCTAssertEqual(m.heightPx, 1080)
    XCTAssertEqual(m.creationTimeMs, 1)
    XCTAssertEqual(m.modificationTimeMs, 2)
    XCTAssertEqual(m.durationMs, 3_500)
    XCTAssertTrue(m.isFavorite)
    XCTAssertTrue(m.isHdr)
    XCTAssertEqual(m.originalFilename, "clip.mov")
    XCTAssertEqual(m.mimeType, "video/quicktime")
    let key = PhotoLibraryHostApiImpl.key(PhotoFetchRequestMsg(filter: .videos, sort: .modificationNewestFirst, albumId: "alb", offset: 0, limit: 1))
    XCTAssertEqual(key, PhotoFetchKey(filter: .videos, sort: .modificationNewestFirst, albumId: "alb"))
    XCTAssertEqual(PhotoLibraryHostApiImpl.msg(.limited), .limited)
    let c = PhotoLibraryHostApiImpl.msg(PhotoChangeRecord(changeToken: "g2", incremental: true, inserted: ["a"], removed: ["b"], changed: ["c"]))
    XCTAssertEqual([c.changeToken] + c.inserted + c.removed + c.changed, ["g2", "a", "b", "c"])
  }

  func testErrorsCarryCodesWithoutDetails() {
    let e = LibraryErrors.from(PhotoLibraryFailure(.unavailableOffline, "x"))
    XCTAssertEqual(e.code, "unavailableOffline")
    XCTAssertNil(e.details)
    XCTAssertEqual(PhotoLibraryService.copyFailure(NSError(domain: "PHPhotosErrorDomain", code: 3164)).code, .unavailableOffline)
    XCTAssertEqual(PhotoLibraryService.copyFailure(NSError(domain: "PHPhotosErrorDomain", code: 3311)).code, .permissionDenied)
    XCTAssertEqual(PhotoLibraryService.copyFailure(NSError(domain: NSCocoaErrorDomain, code: NSFileWriteFileExistsError)).code, .ioError)
  }
}
