// OWNER: HOM-04
//
// Thumbnails of PhotoKit assets (`ph:` ids) through one `PHCachingImageManager` (ARCH v1.2 V2-28,
// V2-104): high-quality, network-free requests (an iCloud-only asset answers `unavailableOffline`,
// ARCH §9.1), cancellation through `cancelImageRequest`, and the prefetch window of the Home grid
// (`startCachingImages` / `stopCachingImages` with the same options as the requests). The decoded
// image is scaled and encoded by ThumbnailCore. Flutter-free, so the hosted XCTests on the iOS
// Simulator (Tests/Thumbnails/) run it with a seeded library. Nothing here logs (rule 30).

import CoreGraphics
import Foundation
import Photos

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

final class PhotoAssetThumbnailer {
  private let manager = PHCachingImageManager()
  private let lock = NSLock()

  /// Waiting limit for PhotoKit before a request fails with `ioError`.
  var timeout: TimeInterval = 30

  init() {
    manager.allowsCachingHighQualityImages = false
  }

  /// The PhotoKit `localIdentifier` of a `ph:` source, or nil.
  static func localIdentifier(_ source: String) -> String? {
    guard source.hasPrefix("ph:") else { return nil }
    let id = String(source.dropFirst(3))
    return id.isEmpty ? nil : id
  }

  static func canRead() -> Bool {
    if #available(iOS 14.0, macOS 11.0, *) {
      let s = PHPhotoLibrary.authorizationStatus(for: .readWrite)
      return s == .authorized || s == .limited
    }
    return PHPhotoLibrary.authorizationStatus() == .authorized
  }

  static func options() -> PHImageRequestOptions {
    let o = PHImageRequestOptions()
    o.deliveryMode = .highQualityFormat
    o.resizeMode = .fast
    o.isSynchronous = false
    o.isNetworkAccessAllowed = false
    o.version = .current
    return o
  }

  static func contentMode(_ fit: ThumbnailFit) -> PHImageContentMode { fit == .fill ? .aspectFill : .aspectFit }

  private func assets(_ ids: [String]) -> [PHAsset] {
    guard !ids.isEmpty else { return [] }
    let r = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
    var out: [PHAsset] = []
    r.enumerateObjects { a, _, _ in out.append(a) }
    return out
  }

  /// Writes the thumbnail of the asset [source] (`ph:<localIdentifier>`) to [outputPath]. Blocks the
  /// calling (background) thread; [token] cancels it.
  func generate(source: String, box: CGSize, fit: ThumbnailFit, format: ThumbnailFileFormat, quality: Double, outputPath: String, token: ThumbnailCancelToken) throws -> ThumbnailOutput {
    guard let id = PhotoAssetThumbnailer.localIdentifier(source) else { throw ThumbnailFailure.invalid("not a ph: source") }
    guard PhotoAssetThumbnailer.canRead() else { throw ThumbnailFailure.permission("photo library access not granted") }
    guard let asset = assets([id]).first else { throw ThumbnailFailure.notFound("no such asset") }
    if token.isCancelled { throw ThumbnailFailure.cancelled() }
    // `.aspectFill` covers the box and `.aspectFit` fits it, so the box itself is the target (the
    // same size the prefetch window caches); ThumbnailCore crops and scales to the exact output.
    let target = box
    let done = DispatchSemaphore(value: 0)
    var cg: CGImage?
    var failure: ThumbnailFailure?
    let requestID = manager.requestImage(for: asset, targetSize: target, contentMode: PhotoAssetThumbnailer.contentMode(fit), options: PhotoAssetThumbnailer.options()) { image, info in
      if (info?[PHImageCancelledKey] as? Bool) == true {
        failure = .cancelled()
      } else if let image = image {
        #if os(iOS)
        cg = PhotoAssetThumbnailer.upright(image)
        #elseif os(macOS)
        cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        #endif
      } else if (info?[PHImageResultIsInCloudKey] as? Bool) == true {
        failure = .offline("asset is only in iCloud")
      } else {
        failure = .io("PhotoKit returned no image")
      }
      done.signal()
    }
    token.onCancel { [manager] in manager.cancelImageRequest(requestID) }
    if done.wait(timeout: .now() + timeout) == .timedOut {
      manager.cancelImageRequest(requestID)
      throw ThumbnailFailure.io("PhotoKit timed out")
    }
    if token.isCancelled { throw ThumbnailFailure.cancelled() }
    if let f = failure { throw f }
    guard let image = cg else { throw ThumbnailFailure.io("PhotoKit returned no bitmap") }
    return try ThumbnailEncoder.write(image, box: box, fit: fit, format: format, quality: quality, to: outputPath, token: token)
  }

  #if os(iOS)
  /// The CGImage of [image] with its orientation applied (PhotoKit images may carry one).
  static func upright(_ image: UIImage) -> CGImage? {
    if image.imageOrientation == .up, let cg = image.cgImage { return cg }
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    let size = CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
    return UIGraphicsImageRenderer(size: size, format: format).image { _ in
      image.draw(in: CGRect(origin: .zero, size: size))
    }.cgImage
  }
  #endif

  /// Moves the prefetch window: assets of [start] are cached at [box], [stop] released. Sources that
  /// are not `ph:` ids are ignored; without photo access nothing happens.
  func updateCaching(start: [String], stop: [String], box: CGSize, fit: ThumbnailFit) {
    guard PhotoAssetThumbnailer.canRead() else { return }
    let s = assets(start.compactMap(PhotoAssetThumbnailer.localIdentifier))
    let t = assets(stop.compactMap(PhotoAssetThumbnailer.localIdentifier))
    let mode = PhotoAssetThumbnailer.contentMode(fit)
    let opts = PhotoAssetThumbnailer.options()
    lock.lock(); defer { lock.unlock() }
    if !t.isEmpty { manager.stopCachingImages(for: t, targetSize: box, contentMode: mode, options: opts) }
    if !s.isEmpty { manager.startCachingImages(for: s, targetSize: box, contentMode: mode, options: opts) }
  }
}
