// OWNER: HOM-04
//
// XCTests of the PhotoKit thumbnail path (BUILD_PLAN HOM-04). With photo access (the hosted bundle
// on the iOS Simulator, run_xctests.sh ios <udid>, which grants it): a locally generated photo is
// added to the library and thumbnailed through PHCachingImageManager in fill and fit, as JPEG and
// HEIC, with the prefetch window moved around it; an unknown id is notFound; a cancelled request
// is `cancelled`. Without access (the macOS command-line runner, where TCC can't be granted) a
// request answers permissionDenied and the access-dependent tests skip.

import CoreGraphics
import Foundation
import Photos
import XCTest

#if canImport(DanaviewThumbnailsCore)
@testable import DanaviewThumbnailsCore
#endif

final class PhotoAssetThumbnailerTests: XCTestCase {
  private var dir: URL!
  private static var seededId: String?

  override func setUpWithError() throws {
    dir = FileManager.default.temporaryDirectory.appendingPathComponent("hom04-ph-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: dir)
  }

  private func requireAccess() throws {
    try XCTSkipUnless(PhotoAssetThumbnailer.canRead(), "no photo library access in this process (grant it with simctl privacy, see run_xctests.sh)")
  }

  /// A 2400×1600 photo added to the library once per run.
  private func seeded() throws -> String {
    if let id = PhotoAssetThumbnailerTests.seededId { return id }
    let url = try ThumbnailTestMedia.write(dir.appendingPathComponent("dv_hom04_seed.jpg"), type: "public.jpeg", width: 2400, height: 1600)
    var id: String?
    try PHPhotoLibrary.shared().performChangesAndWait {
      id = PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: url)?.placeholderForCreatedAsset?.localIdentifier
    }
    let got = try XCTUnwrap(id, "created asset")
    PhotoAssetThumbnailerTests.seededId = got
    return got
  }

  private func generate(_ source: String, box: Int, fit: ThumbnailFit, format: ThumbnailFileFormat = .jpeg, token: ThumbnailCancelToken = ThumbnailCancelToken()) throws -> ThumbnailOutput {
    // PhotoKit replies on the main thread, so the blocking call runs on a background queue.
    let done = expectation(description: "thumb")
    var result: Result<ThumbnailOutput, Error>!
    let path = dir.appendingPathComponent("thumbs/\(UUID().uuidString)").path
    DispatchQueue.global().async {
      result = Result { try PhotoAssetThumbnailer().generate(source: source, box: CGSize(width: box, height: box), fit: fit, format: format, quality: 0.8, outputPath: path, token: token) }
      done.fulfill()
    }
    wait(for: [done], timeout: 60)
    return try result.get()
  }

  func testWithoutAccessARequestIsPermissionDenied() throws {
    try XCTSkipIf(PhotoAssetThumbnailer.canRead(), "this process has photo access")
    XCTAssertThrowsError(try generate("ph:ANY/L0/001", box: 64, fit: .fill)) {
      XCTAssertEqual(($0 as? ThumbnailFailure)?.code, "permissionDenied")
    }
    // The prefetch window is a no-op without access.
    PhotoAssetThumbnailer().updateCaching(start: ["ph:ANY/L0/001"], stop: [], box: CGSize(width: 64, height: 64), fit: .fill)
  }

  func testFillAndFitThumbnailsOfAnAsset() throws {
    try requireAccess()
    let id = try seeded()
    let fill = try generate("ph:\(id)", box: 300, fit: .fill)
    XCTAssertEqual([fill.widthPx, fill.heightPx], [300, 300])
    XCTAssertEqual(ThumbnailTestMedia.probe(fill.path)?.type, "public.jpeg")
    let fit = try generate("ph:\(id)", box: 300, fit: .fit)
    XCTAssertEqual(fit.widthPx, 300)
    XCTAssertEqual(Double(fit.heightPx), 200, accuracy: 2)
  }

  func testHeicOnIos17() throws {
    try requireAccess()
    let id = try seeded()
    let o = try generate("ph:\(id)", box: 200, fit: .fill, format: .heic)
    XCTAssertEqual(o.format, ThumbnailEncoder.heicAvailable ? .heic : .jpeg)
    XCTAssertEqual(ThumbnailTestMedia.probe(o.path)?.type, ThumbnailEncoder.heicAvailable ? "public.heic" : "public.jpeg")
  }

  func testPrefetchWindowThenRequest() throws {
    try requireAccess()
    let id = try seeded()
    let t = PhotoAssetThumbnailer()
    t.updateCaching(start: ["ph:\(id)", "/not/a/ph/source"], stop: [], box: CGSize(width: 256, height: 256), fit: .fill)
    let o = try generate("ph:\(id)", box: 256, fit: .fill)
    XCTAssertEqual([o.widthPx, o.heightPx], [256, 256])
    t.updateCaching(start: [], stop: ["ph:\(id)"], box: CGSize(width: 256, height: 256), fit: .fill)
  }

  func testUnknownAssetIsNotFound() throws {
    try requireAccess()
    XCTAssertThrowsError(try generate("ph:00000000-0000-0000-0000-000000000000/L0/001", box: 64, fit: .fill)) {
      XCTAssertEqual(($0 as? ThumbnailFailure)?.code, "notFound")
    }
  }

  func testCancelledRequestIsCancelled() throws {
    try requireAccess()
    let id = try seeded()
    let token = ThumbnailCancelToken()
    token.cancel()
    XCTAssertThrowsError(try generate("ph:\(id)", box: 64, fit: .fill, token: token)) {
      XCTAssertEqual(($0 as? ThumbnailFailure)?.code, "cancelled")
    }
  }
}
