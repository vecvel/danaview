// OWNER: HOM-02
//
// Glue tests (macOS, linked against FlutterMacOS): every placeholder class of a later ticket
// answers `notSupportedOnDevice` (BUILD_PLAN HOM-02), Incoming is Android-only, the backup flag
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
    let item = FileItemMsg(path: "/tmp/x", displayName: "x")
    let pickers = PickerHostApiImpl(context: context)
    assertNotSupported("pickPhotos") { pickers.pickPhotos(request: PhotoPickRequestMsg(selectionLimit: 0, filter: .all, destinationDirectory: "/tmp"), completion: $0) }
    assertNotSupported("pickDocuments") { pickers.pickDocuments(request: DocumentPickRequestMsg(allowMultiple: true, utis: [], mimeTypes: []), completion: $0) }
    assertNotSupported("copyToFile") { pickers.copyToFile(request: CopyRequestMsg(requestId: "r", sourceUri: "file:///tmp/x", destinationPath: "/tmp/y", resumeFromOffset: 0), completion: $0) }
    assertThrowsNotSupported("picker cancelCopy") { try pickers.cancelCopy(requestId: "r") }
    assertThrowsNotSupported("release") { try pickers.release(uri: "file:///tmp/x") }

    let thumbs = ThumbnailHostApiImpl(context: context)
    assertNotSupported("mediaThumbnail") {
      thumbs.mediaThumbnail(request: MediaThumbnailRequestMsg(requestId: "t", source: "ph:x", widthPx: 1, heightPx: 1, mode: .fill, format: .jpeg, quality: 0.8, outputPath: "/tmp/t"), completion: $0)
    }
    assertNotSupported("documentThumbnail") {
      thumbs.documentThumbnail(request: DocumentThumbnailRequestMsg(requestId: "t", path: "/tmp/x", widthPx: 1, heightPx: 1, scale: 2, format: .jpeg, quality: 0.8, outputPath: "/tmp/t"), completion: $0)
    }
    assertThrowsNotSupported("thumb cancel") { try thumbs.cancel(requestId: "t") }
    assertThrowsNotSupported("updateCaching") { try thumbs.updateCaching(window: ThumbnailCachingMsg(startSources: [], stopSources: [], widthPx: 1, heightPx: 1, mode: .fill)) }

    let out = ExportOutHostApiImpl(context: context)
    assertNotSupported("saveOut") { out.saveOut(request: SaveOutRequestMsg(items: [item], destination: .files), completion: $0) }
    let share = ShareHostApiImpl(context: context)
    assertNotSupported("share") { share.share(request: ShareRequestMsg(items: [item]), completion: $0) }
    let openIn = OpenInHostApiImpl(context: context)
    assertNotSupported("openIn") { openIn.openIn(request: OpenInRequestMsg(item: item), completion: $0) }
    let quickLook = QuickLookHostApiImpl(context: context)
    assertNotSupported("canPreview") { quickLook.canPreview(item: item, completion: $0) }
    assertNotSupported("present") { quickLook.present(request: QuickLookRequestMsg(items: [item], initialIndex: 0), completion: $0) }

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
