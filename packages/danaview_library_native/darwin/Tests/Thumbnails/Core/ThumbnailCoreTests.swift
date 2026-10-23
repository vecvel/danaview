// OWNER: HOM-04
//
// XCTests of the Flutter-free thumbnail core (BUILD_PLAN HOM-04): fill/fit geometry, the encoder
// (JPEG; HEIC on iOS 17+ and JPEG elsewhere; WebP requests written as JPEG because ImageIO has no
// WebP encoder, V2-V3), the atomic write, and the file thumbnailer for photos (JPEG, HEIC, PNG,
// EXIF orientation) and videos through Quick Look and through the ImageIO / AVFoundation
// fallbacks; a missing file is notFound, a corrupt one a typed ioError (no crash), and a cancelled
// request is `cancelled` with no output left behind.

import CoreGraphics
import Foundation
import XCTest

#if canImport(DanaviewThumbnailsCore)
@testable import DanaviewThumbnailsCore
#endif

final class ThumbnailCoreTests: XCTestCase {
  private var dir: URL!

  override func setUpWithError() throws {
    dir = FileManager.default.temporaryDirectory.appendingPathComponent("hom04-core-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: dir)
  }

  private func out(_ name: String) -> String { dir.appendingPathComponent("thumbs/m/\(name)").path }

  // MARK: geometry

  func testFillIsExactlyTheBoxAndCropsTheCentre() {
    let src = CGSize(width: 4000, height: 3000)
    let box = CGSize(width: 300, height: 300)
    XCTAssertEqual(ThumbnailGeometry.outputSize(source: src, box: box, fit: .fill), box)
    XCTAssertEqual(ThumbnailGeometry.cropRect(source: src, box: box, fit: .fill), CGRect(x: 500, y: 0, width: 3000, height: 3000))
    let tall = CGSize(width: 1000, height: 2000)
    XCTAssertEqual(ThumbnailGeometry.cropRect(source: tall, box: CGSize(width: 200, height: 100), fit: .fill), CGRect(x: 0, y: 750, width: 1000, height: 500))
  }

  func testFitKeepsTheAspectAndNeverUpscales() {
    XCTAssertEqual(ThumbnailGeometry.outputSize(source: CGSize(width: 4000, height: 3000), box: CGSize(width: 400, height: 400), fit: .fit), CGSize(width: 400, height: 300))
    XCTAssertEqual(ThumbnailGeometry.outputSize(source: CGSize(width: 100, height: 50), box: CGSize(width: 400, height: 400), fit: .fit), CGSize(width: 100, height: 50))
    XCTAssertEqual(ThumbnailGeometry.outputSize(source: CGSize(width: 10000, height: 1), box: CGSize(width: 100, height: 100), fit: .fit), CGSize(width: 100, height: 1))
    XCTAssertEqual(ThumbnailGeometry.cropRect(source: CGSize(width: 40, height: 30), box: CGSize(width: 10, height: 10), fit: .fit), CGRect(x: 0, y: 0, width: 40, height: 30))
  }

  func testRequestSizeCoversTheBoxForFill() {
    let r = ThumbnailGeometry.requestSize(source: CGSize(width: 4000, height: 3000), box: CGSize(width: 300, height: 300), fit: .fill)
    XCTAssertEqual(r, CGSize(width: 400, height: 300))
    XCTAssertEqual(ThumbnailGeometry.requestSize(source: nil, box: CGSize(width: 90, height: 90), fit: .fill), CGSize(width: 160, height: 160))
    XCTAssertEqual(ThumbnailGeometry.requestSize(source: nil, box: CGSize(width: 90, height: 60), fit: .fit), CGSize(width: 90, height: 60))
  }

  // MARK: encoder

  func testEffectiveFormats() {
    XCTAssertEqual(ThumbnailEncoder.effectiveFormat(.jpeg), .jpeg)
    XCTAssertEqual(ThumbnailEncoder.effectiveFormat(.png), .png)
    XCTAssertEqual(ThumbnailEncoder.effectiveFormat(.webp), .jpeg, "ImageIO has no WebP encoder (V2-V3)")
    #if os(macOS)
    XCTAssertEqual(ThumbnailEncoder.effectiveFormat(.heic), .jpeg, "macOS writes JPEG")
    #else
    if #available(iOS 17.0, *) { XCTAssertEqual(ThumbnailEncoder.effectiveFormat(.heic), .heic) } else { XCTAssertEqual(ThumbnailEncoder.effectiveFormat(.heic), .jpeg) }
    #endif
  }

  func testWriteEncodesAtTheBoxAndReplacesAtomically() throws {
    let img = try ThumbnailTestMedia.image(width: 800, height: 400)
    let path = out("a.jpg")
    let o = try ThumbnailEncoder.write(img, box: CGSize(width: 200, height: 200), fit: .fill, format: .jpeg, quality: 0.8, to: path)
    XCTAssertEqual(o, ThumbnailOutput(path: path, widthPx: 200, heightPx: 200, format: .jpeg))
    let probe = try XCTUnwrap(ThumbnailTestMedia.probe(path))
    XCTAssertEqual(probe.width, 200)
    XCTAssertEqual(probe.height, 200)
    XCTAssertEqual(probe.type, "public.jpeg")
    // The centre crop of an 800×400 image with a white centre square: the middle is white, the
    // corners are the red frame's (the crop is 400×400 starting at x = 200).
    let mid = try XCTUnwrap(ThumbnailTestMedia.pixel(path, x: 100, y: 100))
    XCTAssertGreaterThan(Int(mid.g), 200)
    let corner = try XCTUnwrap(ThumbnailTestMedia.pixel(path, x: 2, y: 2))
    XCTAssertGreaterThan(Int(corner.r), 150)
    XCTAssertLessThan(Int(corner.g), 80)
    // Overwrite with a fit thumbnail; no part file is left.
    let o2 = try ThumbnailEncoder.write(img, box: CGSize(width: 200, height: 200), fit: .fit, format: .png, quality: 1, to: path)
    XCTAssertEqual(o2.widthPx, 200)
    XCTAssertEqual(o2.heightPx, 100)
    XCTAssertEqual(ThumbnailTestMedia.probe(path)?.type, "public.png")
    let left = try FileManager.default.contentsOfDirectory(atPath: (path as NSString).deletingLastPathComponent)
    XCTAssertEqual(left, ["a.jpg"])
  }

  func testWebpRequestIsWrittenAsJpeg() throws {
    let o = try ThumbnailEncoder.write(try ThumbnailTestMedia.image(width: 64, height: 64), box: CGSize(width: 32, height: 32), fit: .fill, format: .webp, quality: 0.7, to: out("w.jpg"))
    XCTAssertEqual(o.format, .jpeg)
    XCTAssertEqual(ThumbnailTestMedia.probe(o.path)?.type, "public.jpeg")
  }

  func testHeicRequest() throws {
    let o = try ThumbnailEncoder.write(try ThumbnailTestMedia.image(width: 640, height: 480), box: CGSize(width: 160, height: 160), fit: .fill, format: .heic, quality: 0.7, to: out("h.heic"))
    XCTAssertEqual(o.format, ThumbnailEncoder.heicAvailable ? .heic : .jpeg)
    XCTAssertEqual(ThumbnailTestMedia.probe(o.path)?.type, ThumbnailEncoder.heicAvailable ? "public.heic" : "public.jpeg")
  }

  func testCancelledWriteLeavesNothing() throws {
    let token = ThumbnailCancelToken()
    token.cancel()
    XCTAssertThrowsError(try ThumbnailEncoder.write(try ThumbnailTestMedia.image(width: 64, height: 64), box: CGSize(width: 32, height: 32), fit: .fill, format: .jpeg, quality: 0.7, to: out("c.jpg"), token: token)) {
      XCTAssertEqual(($0 as? ThumbnailFailure)?.code, "cancelled")
    }
    XCTAssertFalse(FileManager.default.fileExists(atPath: out("c.jpg")))
  }

  func testCancelTokenRunsHandlersOnce() {
    let t = ThumbnailCancelToken()
    var n = 0
    t.onCancel { n += 1 }
    t.cancel()
    t.cancel()
    t.onCancel { n += 10 }
    XCTAssertEqual(n, 11)
    XCTAssertTrue(t.isCancelled)
  }

  // MARK: file thumbnailer

  private func photo(_ name: String, type: String, w: Int = 1600, h: Int = 1200, orientation: Int = 1) throws -> String {
    try ThumbnailTestMedia.write(dir.appendingPathComponent(name), type: type, width: w, height: h, orientation: orientation).path
  }

  private func thumb(_ source: String, box: Int = 256, fit: ThumbnailFit = .fill, format: ThumbnailFileFormat = .jpeg, quickLook: Bool = true, name: String = UUID().uuidString) throws -> ThumbnailOutput {
    let t = FileThumbnailer()
    t.useQuickLook = quickLook
    return try t.generate(source: source, box: CGSize(width: box, height: box), fit: fit, format: format, quality: 0.8, outputPath: out("\(name).jpg"), token: ThumbnailCancelToken())
  }

  func testPhotosThroughQuickLookAndImageIO() throws {
    for (name, type) in [("p.jpg", "public.jpeg"), ("p.heic", "public.heic"), ("p.png", "public.png")] {
      let src = try photo(name, type: type)
      for ql in [true, false] {
        let fill = try thumb(src, quickLook: ql)
        XCTAssertEqual([fill.widthPx, fill.heightPx], [256, 256], "\(name) fill ql=\(ql)")
        let fit = try thumb(src, fit: .fit, quickLook: ql)
        XCTAssertEqual(fit.widthPx, 256, "\(name) fit ql=\(ql)")
        XCTAssertEqual(Double(fit.heightPx), 192, accuracy: 2, "\(name) fit ql=\(ql)")
      }
    }
  }

  func testFileUrlSourceAndExifOrientation() throws {
    // Orientation 6 (rotated 90° clockwise): a 1600×1200 bitmap displays as 1200×1600.
    let src = try photo("rot.jpg", type: "public.jpeg", orientation: 6)
    XCTAssertEqual(FileThumbnailer.imagePixelSize(URL(fileURLWithPath: src)), CGSize(width: 1200, height: 1600))
    let o = try thumb(URL(fileURLWithPath: src).absoluteString, fit: .fit, quickLook: false)
    XCTAssertEqual(Double(o.widthPx), 192, accuracy: 2)
    XCTAssertEqual(o.heightPx, 256)
  }

  func testVideoThroughQuickLookAndAVFoundation() throws {
    let src = try ThumbnailTestMedia.movie(dir.appendingPathComponent("m.mov"), width: 640, height: 360).path
    XCTAssertTrue(FileThumbnailer.isVideo(URL(fileURLWithPath: src)))
    for ql in [true, false] {
      let o = try thumb(src, box: 128, quickLook: ql)
      XCTAssertEqual([o.widthPx, o.heightPx], [128, 128], "ql=\(ql)")
      let fit = try thumb(src, box: 128, fit: .fit, quickLook: ql)
      XCTAssertEqual(fit.widthPx, 128, "ql=\(ql)")
      XCTAssertEqual(Double(fit.heightPx), 72, accuracy: 2, "ql=\(ql)")
    }
  }

  /// The miss budget is ≤ 120 ms for a 12 MP HEIC on the mid-tier device (recorded on the lab
  /// iPhone 12). Here XCTest's `measure` reports this host's miss times in the test log ("measured
  /// … values: […]", the first value is the cold miss) without a log call (ARCH rule 30), and only
  /// a loose per-miss bound is asserted so a busy CI machine does not flake.
  func testTwelveMegapixelHeicMissTimeQuickLook() throws { try measureHeicMiss(quickLook: true) }

  func testTwelveMegapixelHeicMissTimeImageIO() throws { try measureHeicMiss(quickLook: false) }

  private func measureHeicMiss(quickLook ql: Bool) throws {
    let src = try photo("12mp.heic", type: "public.heic", w: 4032, h: 3024)
    var i = 0
    measure {
      i += 1
      let start = Date()
      do {
        let o = try thumb(src, box: 384, format: .heic, quickLook: ql, name: "12mp-\(ql)-\(i)")
        XCTAssertEqual([o.widthPx, o.heightPx], [384, 384])
      } catch {
        XCTFail("12 MP HEIC thumbnail failed: \(error)")
      }
      XCTAssertLessThan(Date().timeIntervalSince(start) * 1000, 2000)
    }
  }

  func testMissingFileIsNotFound() {
    XCTAssertThrowsError(try thumb(dir.appendingPathComponent("nope.jpg").path)) {
      XCTAssertEqual(($0 as? ThumbnailFailure)?.code, "notFound")
    }
    XCTAssertThrowsError(try thumb(dir.path)) { XCTAssertEqual(($0 as? ThumbnailFailure)?.code, "notFound", "a directory is not a media file") }
  }

  func testCorruptFilesAreTypedFailures() throws {
    for name in ["bad.jpg", "bad.heic", "bad.mov"] {
      let src = try ThumbnailTestMedia.corrupt(dir.appendingPathComponent(name)).path
      let t = FileThumbnailer()
      t.timeout = 10
      XCTAssertThrowsError(try t.generate(source: src, box: CGSize(width: 64, height: 64), fit: .fill, format: .jpeg, quality: 0.8, outputPath: out("\(name).jpg"), token: ThumbnailCancelToken()), name) {
        XCTAssertEqual(($0 as? ThumbnailFailure)?.code, "ioError", name)
      }
      XCTAssertFalse(FileManager.default.fileExists(atPath: out("\(name).jpg")), name)
    }
  }

  func testUnknownSourcesAreInvalid() {
    XCTAssertNil(FileThumbnailer.fileURL("relative/path.jpg"))
    XCTAssertNil(FileThumbnailer.fileURL("https://example.invalid/a.jpg"))
    XCTAssertThrowsError(try thumb("relative.jpg")) { XCTAssertEqual(($0 as? ThumbnailFailure)?.code, "invalidArgument") }
  }

  func testCancelledBeforeStartFailsWithCancelled() throws {
    let src = try photo("c.jpg", type: "public.jpeg")
    let token = ThumbnailCancelToken()
    token.cancel()
    XCTAssertThrowsError(try FileThumbnailer().generate(source: src, box: CGSize(width: 64, height: 64), fit: .fill, format: .jpeg, quality: 0.8, outputPath: out("x.jpg"), token: token)) {
      XCTAssertEqual(($0 as? ThumbnailFailure)?.code, "cancelled")
    }
    XCTAssertFalse(FileManager.default.fileExists(atPath: out("x.jpg")))
  }

  func testPhotoAssetSourceParsing() {
    XCTAssertEqual(PhotoAssetThumbnailer.localIdentifier("ph:ABC/L0/001"), "ABC/L0/001")
    XCTAssertNil(PhotoAssetThumbnailer.localIdentifier("ph:"))
    XCTAssertNil(PhotoAssetThumbnailer.localIdentifier("/tmp/a.jpg"))
    XCTAssertNil(PhotoAssetThumbnailer.localIdentifier("ms:12"))
    let o = PhotoAssetThumbnailer.options()
    XCTAssertFalse(o.isNetworkAccessAllowed, "never downloads from iCloud (ARCH §9.1)")
    XCTAssertFalse(o.isSynchronous)
    XCTAssertEqual(o.deliveryMode, .highQualityFormat)
  }
}
