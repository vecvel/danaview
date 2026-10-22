// OWNER: HOM-02
//
// PhotoLibraryService against the real PhotoKit library of the iOS Simulator (BUILD_PLAN HOM-02):
// run_xctests.sh seeds it with `xcrun simctl addmedia` (locally generated JPEG, HEIC, PNG and a
// short H.264 movie) and grants photo access to the test runner. Covers paging (cheap page
// records, full fetchAssets records), change events on add and delete, stale tokens across
// stop/start and unobserved re-fetches, limited access and denied access. Tests that need the
// real library skip when the process has no access (macOS command-line runs: TCC can't be
// granted there).

import Foundation
import Photos
import XCTest

@testable import DanaviewPhotoLibraryCore

/// An authorization the test controls; `.system` reads the real one.
final class FakeAuthorizing: PhotoAuthorizing {
  var value: PhotoAuthorization
  init(_ value: PhotoAuthorization) { self.value = value }
  func status() -> PhotoAuthorization { value }
  func request(_ completion: @escaping (PhotoAuthorization) -> Void) { completion(value) }
}

final class RecordingSink: PhotoLibraryEventSink {
  var changes: [PhotoChangeRecord] = []
  var authorizations: [PhotoAuthorization] = []
  var onChange: ((PhotoChangeRecord) -> Void)?

  func photoLibraryDidChange(_ change: PhotoChangeRecord) {
    changes.append(change)
    onChange?(change)
  }

  func photoAuthorizationDidChange(_ authorization: PhotoAuthorization) { authorizations.append(authorization) }

  func photoCopyProgress(requestId: String, bytesDone: Int64, bytesTotal: Int64?) {}
}

final class PhotoLibraryServiceTests: XCTestCase {
  private var systemCanRead: Bool { SystemPhotoAuthorizing().status().canRead }

  /// A service over the real library with the real (`.readWrite`) authorization.
  private func liveService() -> PhotoLibraryService { PhotoLibraryService() }

  private func requireLibrary() throws {
    try XCTSkipUnless(systemCanRead, "no photo library access in this process (status \(SystemPhotoAuthorizing().status()); grant it with simctl privacy, see run_xctests.sh)")
  }

  private func page(_ service: PhotoLibraryService, _ key: PhotoFetchKey = .baseline, offset: Int, limit: Int, token: String? = nil) throws -> PhotoPageRecord {
    let done = expectation(description: "page")
    var out: Result<PhotoPageRecord, PhotoLibraryFailure>?
    service.fetchPage(key: key, offset: offset, limit: limit, token: token) { out = $0; done.fulfill() }
    wait(for: [done], timeout: 30)
    return try XCTUnwrap(out).get()
  }

  // MARK: Authorization (no library needed)

  func testDeniedAccessFailsWithPermissionDenied() {
    for status in [PhotoAuthorization.denied, .restricted, .notDetermined] {
      let service = PhotoLibraryService(authorizing: FakeAuthorizing(status))
      let done = expectation(description: "page")
      service.fetchPage(key: .baseline, offset: 0, limit: 10, token: nil) { result in
        if case .failure(let f) = result { XCTAssertEqual(f.code, .permissionDenied) } else { XCTFail("expected a failure") }
        done.fulfill()
      }
      wait(for: [done], timeout: 5)
    }
  }

  func testAuthorizationChangeIsReported() {
    let auth = FakeAuthorizing(.denied)
    let service = PhotoLibraryService(authorizing: auth)
    let sink = RecordingSink()
    service.sink = sink
    let first = expectation(description: "first")
    service.requestAuthorization { XCTAssertEqual($0, .denied); first.fulfill() }
    wait(for: [first], timeout: 5)
    auth.value = .limited
    let second = expectation(description: "second")
    service.requestAuthorization { XCTAssertEqual($0, .limited); second.fulfill() }
    wait(for: [second], timeout: 5)
    XCTAssertEqual(sink.authorizations, [.limited])
    XCTAssertTrue(PhotoAuthorization.limited.canRead)
    XCTAssertEqual(SystemPhotoAuthorizing.map(.limited), .limited)
    XCTAssertEqual(SystemPhotoAuthorizing.map(.authorized), .authorized)
    XCTAssertEqual(SystemPhotoAuthorizing.map(.denied), .denied)
    XCTAssertEqual(SystemPhotoAuthorizing.map(.restricted), .restricted)
    XCTAssertEqual(SystemPhotoAuthorizing.map(.notDetermined), .notDetermined)
  }

  // MARK: Paging (seeded library)

  func testPagingCoversTheSeededLibraryOnce() throws {
    try requireLibrary()
    let service = liveService()
    let expected = PHAsset.fetchAssets(with: PhotoLibraryService.options(for: .baseline)).count
    XCTAssertGreaterThanOrEqual(expected, 4, "run_xctests.sh seeds at least four items")
    var ids: [String] = []
    var offset = 0
    var token: String?
    while true {
      let p = try page(service, offset: offset, limit: 3, token: token)
      XCTAssertEqual(p.totalCount, expected)
      XCTAssertFalse(p.tokenStale)
      if token != nil { XCTAssertEqual(p.changeToken, token) }
      token = p.changeToken
      if p.assets.isEmpty { break }
      ids += p.assets.map(\.localIdentifier)
      offset += p.assets.count
    }
    XCTAssertEqual(ids.count, expected)
    XCTAssertEqual(Set(ids).count, expected, "no asset twice")
    // Newest first.
    let all = try page(service, offset: 0, limit: 500)
    let times = all.assets.compactMap(\.creationTimeMs)
    XCTAssertEqual(times, times.sorted(by: >))
  }

  func testFiltersAndMetadata() throws {
    try requireLibrary()
    let service = liveService()
    let photos = try page(service, PhotoFetchKey(filter: .photos, sort: .creationNewestFirst, albumId: nil), offset: 0, limit: 500)
    let videos = try page(service, PhotoFetchKey(filter: .videos, sort: .creationNewestFirst, albumId: nil), offset: 0, limit: 500)
    XCTAssertTrue(photos.assets.allSatisfy { $0.kind == .photo && $0.durationMs == 0 })
    XCTAssertTrue(videos.assets.allSatisfy { $0.kind == .video })
    XCTAssertFalse(photos.assets.isEmpty)
    XCTAssertFalse(videos.assets.isEmpty, "run_xctests.sh seeds a movie")
    XCTAssertTrue(videos.assets.contains { $0.durationMs > 0 })
    XCTAssertTrue(photos.assets.allSatisfy { $0.widthPx > 0 && $0.heightPx > 0 })
    // Pages carry cheap fields only (no resource lookups); fetchAssets adds the resource facts.
    XCTAssertTrue(photos.assets.allSatisfy { $0.uti == nil && $0.mimeType == nil && $0.originalFilename == nil && !$0.isRaw })
    let full = try resultOf { service.fetchAssets(photos.assets.map(\.localIdentifier), completion: $0) }
    XCTAssertEqual(full.map(\.localIdentifier), photos.assets.map(\.localIdentifier))
    XCTAssertTrue(full.contains { $0.uti == "public.heic" && $0.mimeType == "image/heic" }, "the seeded HEIC")
    XCTAssertTrue(full.contains { $0.uti == "public.jpeg" && $0.mimeType == "image/jpeg" })
    let ids = Array(photos.assets.prefix(2).map(\.localIdentifier)) + ["missing/L0/001"]
    let fetched = try resultOf { service.fetchAssets(ids, completion: $0) }
    XCTAssertEqual(fetched.map(\.localIdentifier), Array(ids.prefix(2)), "unknown ids are left out, order kept")
  }

  func testDetailOfTheSeededJpeg() throws {
    try requireLibrary()
    let service = liveService()
    let seeded = try XCTUnwrap(seededExifJpeg(service), "seeded EXIF JPEG")
    let d = try resultOf { service.assetDetail(seeded.localIdentifier, completion: $0) }
    XCTAssertTrue(d.locallyAvailable)
    XCTAssertEqual(d.cameraModel, "Fixture Cam")
    XCTAssertEqual(d.iso, 400)
    XCTAssertNotNil(d.sizeBytes)
    let missing = expectation(description: "missing")
    service.assetDetail("missing/L0/001") { r in
      if case .failure(let f) = r { XCTAssertEqual(f.code, .notFound) } else { XCTFail() }
      missing.fulfill()
    }
    wait(for: [missing], timeout: 10)
  }

  func testCopyIsCreateNewAndLeavesTheOriginal() throws {
    try requireLibrary()
    let service = liveService()
    let asset = try XCTUnwrap(seededExifJpeg(service))
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dv_copy_\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let a = try resultOf { service.copyAsset(requestId: "a", id: asset.localIdentifier, directory: dir.path, pairedVideo: false, completion: $0) }
    let b = try resultOf { service.copyAsset(requestId: "b", id: asset.localIdentifier, directory: dir.path, pairedVideo: false, completion: $0) }
    XCTAssertNotEqual(a.path, b.path, "the second copy gets a new name")
    XCTAssertTrue(b.path.hasSuffix(" (2).jpg") || b.path.hasSuffix(" (2).JPG"))
    XCTAssertGreaterThan(a.sizeBytes, 0)
    XCTAssertEqual(a.sizeBytes, b.sizeBytes)
    XCTAssertEqual(a.mimeType, "image/jpeg")
    let noLive = expectation(description: "no paired video")
    service.copyAsset(requestId: "c", id: asset.localIdentifier, directory: dir.path, pairedVideo: true) { r in
      if case .failure(let f) = r { XCTAssertEqual(f.code, .notFound) } else { XCTFail() }
      noLive.fulfill()
    }
    wait(for: [noLive], timeout: 10)
  }

  // MARK: Change events

  /// Adding an asset sends an incremental change with its id and moves the token; a page read with
  /// the old token is then stale.
  func testChangeEventOnAdd() throws {
    try requireLibrary()
    let service = liveService()
    let sink = RecordingSink()
    service.sink = sink
    let before = try page(service, offset: 0, limit: 1)
    service.startObserving()
    defer { service.stopObserving() }
    service.queue.sync {}

    let got = expectation(description: "change")
    var newId: String?
    sink.onChange = { change in
      if let id = newId, change.inserted.contains(id) { got.fulfill() }
    }
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("dv_added_\(UUID().uuidString).jpg")
    try TestMedia.jpeg(width: 32, height: 32, red: 0.9).write(to: file)
    defer { try? FileManager.default.removeItem(at: file) }
    let saved = expectation(description: "saved")
    PHPhotoLibrary.shared().performChanges({
      let request = PHAssetCreationRequest.forAsset()
      request.addResource(with: .photo, fileURL: file, options: nil)
      newId = request.placeholderForCreatedAsset?.localIdentifier
    }) { ok, error in
      XCTAssertTrue(ok, "\(String(describing: error))")
      saved.fulfill()
    }
    wait(for: [saved, got], timeout: 30)
    let change = try XCTUnwrap(sink.changes.last { $0.inserted.contains(newId ?? "") })
    XCTAssertTrue(change.incremental)
    XCTAssertNotEqual(change.changeToken, before.changeToken)
    let after = try page(service, offset: 0, limit: 1, token: before.changeToken)
    XCTAssertTrue(after.tokenStale)
    XCTAssertEqual(after.totalCount, before.totalCount + 1)
    XCTAssertEqual(after.changeToken, change.changeToken)

    // PhotoKit asks the user to confirm every deletion (a system alert a unit test can't answer),
    // so removal is covered by testChangeEventOnDelete with PhotoKit-computed change details.
  }

  /// A removal reaches the event with the removed id and a new token (details computed by PhotoKit
  /// between two real snapshots, so no confirmation alert is needed).
  func testChangeEventOnDelete() throws {
    try requireLibrary()
    let service = liveService()
    // Observing: the cached snapshot follows applied changes (unobserved pages re-fetch).
    service.startObserving()
    defer { service.stopObserving() }
    let full = try page(service, offset: 0, limit: 500)
    let victim = try XCTUnwrap(full.assets.first)
    let options = PhotoLibraryService.options(for: .baseline)
    let all = PHAsset.fetchAssets(with: options)
    let without = PHAsset.fetchAssets(with: {
      let o = PhotoLibraryService.options(for: .baseline)
      o.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [options.predicate!, NSPredicate(format: "NOT (localIdentifier == %@)", victim.localIdentifier)])
      return o
    }())
    XCTAssertEqual(without.count, all.count - 1)
    let change = try XCTUnwrap(service.queue.sync {
      service.apply { _ in PHFetchResultChangeDetails(from: all, to: without, changedObjects: []) }
    })
    XCTAssertEqual(change.removed, [victim.localIdentifier])
    XCTAssertTrue(change.inserted.isEmpty)
    XCTAssertTrue(change.incremental)
    XCTAssertNotEqual(change.changeToken, full.changeToken)
    let after = try page(service, offset: 0, limit: 500, token: full.changeToken)
    XCTAssertTrue(after.tokenStale)
    XCTAssertEqual(after.totalCount, full.totalCount - 1)
    XCTAssertFalse(after.assets.contains { $0.localIdentifier == victim.localIdentifier })
  }

  /// An in-place change keeps the token (cells refresh without restarting paging).
  func testInPlaceChangeKeepsTheToken() throws {
    try requireLibrary()
    let service = liveService()
    let full = try page(service, offset: 0, limit: 500)
    let all = PHAsset.fetchAssets(with: PhotoLibraryService.options(for: .baseline))
    let first = try XCTUnwrap(all.firstObject)
    let change = try XCTUnwrap(service.queue.sync {
      service.apply { _ in PHFetchResultChangeDetails(from: all, to: all, changedObjects: [first]) }
    })
    XCTAssertEqual(change.changed, [first.localIdentifier])
    XCTAssertEqual(change.changeToken, full.changeToken)
    XCTAssertNil(service.queue.sync { service.apply { _ in nil } }, "nothing affected, no event")
  }

  /// Limited access lists what PhotoKit returns (the selection) and keeps change events.
  func testLimitedAccessIsReadable() throws {
    try requireLibrary()
    let service = PhotoLibraryService(authorizing: FakeAuthorizing(.limited))
    let p = try page(service, offset: 0, limit: 10)
    XCTAssertEqual(p.totalCount, PHAsset.fetchAssets(with: PhotoLibraryService.options(for: .baseline)).count)
  }

  /// Stopping and restarting the observer drops the snapshots and moves the token, so pages read
  /// before (when changes went unapplied) are stale.
  func testStopAndStartObservingMakeEarlierTokensStale() throws {
    try requireLibrary()
    let service = liveService()
    let before = try page(service, offset: 0, limit: 5)
    service.startObserving()
    let observed = try page(service, offset: 0, limit: 5, token: before.changeToken)
    XCTAssertTrue(observed.tokenStale, "startObserving starts from a fresh snapshot")
    XCTAssertEqual(observed.totalCount, before.totalCount)
    service.stopObserving()
    let after = try page(service, offset: 0, limit: 5, token: observed.changeToken)
    XCTAssertTrue(after.tokenStale, "stopObserving drops the snapshots")
    let again = try page(service, offset: 5, limit: 5, token: after.changeToken)
    XCTAssertFalse(again.tokenStale, "an unchanged library keeps the token while not observing")
  }

  /// Unobserved pages re-fetch and compare: a count change or shifted ids in the page window move
  /// the token; the same snapshot does not.
  func testUnobservedRefetchDetectsShifts() throws {
    try requireLibrary()
    let options = PhotoLibraryService.options(for: .baseline)
    let all = PHAsset.fetchAssets(with: options)
    let first = try XCTUnwrap(all.firstObject)
    let without = PHAsset.fetchAssets(with: {
      let o = PhotoLibraryService.options(for: .baseline)
      o.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [options.predicate!, NSPredicate(format: "NOT (localIdentifier == %@)", first.localIdentifier)])
      return o
    }())
    XCTAssertFalse(PhotoLibraryService.shifted(from: all, to: PHAsset.fetchAssets(with: options), window: (0, 3)))
    XCTAssertTrue(PhotoLibraryService.shifted(from: all, to: without, window: (0, 3)))
    XCTAssertTrue(PhotoLibraryService.shifted(from: all, to: without, window: nil))
  }

  // MARK: Helpers

  /// The full record of the seeded EXIF JPEG (pages have no filenames; fetchAssets does).
  private func seededExifJpeg(_ service: PhotoLibraryService) throws -> PhotoAssetRecord? {
    let photos = try page(service, PhotoFetchKey(filter: .photos, sort: .creationNewestFirst, albumId: nil), offset: 0, limit: 500)
    let full = try resultOf { service.fetchAssets(photos.assets.map(\.localIdentifier), completion: $0) }
    return full.first { $0.originalFilename?.hasPrefix("dv_seed_exif") == true }
  }

  private func resultOf<T>(_ call: (@escaping (Result<T, PhotoLibraryFailure>) -> Void) -> Void) throws -> T {
    let done = expectation(description: "result")
    var out: Result<T, PhotoLibraryFailure>?
    call { out = $0; done.fulfill() }
    wait(for: [done], timeout: 30)
    return try XCTUnwrap(out).get()
  }
}
