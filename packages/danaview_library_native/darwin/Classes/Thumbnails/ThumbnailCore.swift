// OWNER: HOM-04
//
// The Flutter-free core of the Apple thumbnailers (ARCH v1.2 V2-28, V2-V3; BUILD_PLAN HOM-04):
// box geometry (fill = cover and centre-crop, fit = inside keeping the aspect ratio), the encoder
// (JPEG everywhere, HEIC on iOS 17+, PNG; ImageIO has no WebP encoder, so a WebP request is written
// as JPEG and the result says so), the atomic write of the output file, and the file thumbnailer:
// `QLThumbnailGenerator` first, then ImageIO (`CGImageSourceCreateThumbnailAtIndex`) for images and
// `AVAssetImageGenerator` for videos when Quick Look has nothing. Sources are opened read-only
// (rule 27); only the output file in the thumbnail cache is written. ThumbnailHostApiImpl maps
// these to the Pigeon messages; XCTests (Tests/Thumbnails/) run this file without an app host.
// Nothing here logs (rule 30) or opens a socket (rule 21).

import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import QuickLookThumbnailing

#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
#endif

/// A failure of a thumbnail operation; `code` is a `LibraryErrorCode` raw value, `message` debug
/// text without names or paths.
struct ThumbnailFailure: Error, Equatable {
  let code: String
  let message: String

  static func notFound(_ m: String) -> ThumbnailFailure { ThumbnailFailure(code: "notFound", message: m) }
  static func cancelled(_ m: String = "thumbnail cancelled") -> ThumbnailFailure { ThumbnailFailure(code: "cancelled", message: m) }
  static func io(_ m: String) -> ThumbnailFailure { ThumbnailFailure(code: "ioError", message: m) }
  static func invalid(_ m: String) -> ThumbnailFailure { ThumbnailFailure(code: "invalidArgument", message: m) }
  static func busy(_ m: String) -> ThumbnailFailure { ThumbnailFailure(code: "busy", message: m) }
  static func notSupported(_ m: String) -> ThumbnailFailure { ThumbnailFailure(code: "notSupportedOnDevice", message: m) }
  static func permission(_ m: String) -> ThumbnailFailure { ThumbnailFailure(code: "permissionDenied", message: m) }
  static func offline(_ m: String) -> ThumbnailFailure { ThumbnailFailure(code: "unavailableOffline", message: m) }
}

/// Encoded format of a thumbnail file (mirrors `ThumbnailFormatMsg`).
enum ThumbnailFileFormat: Equatable {
  case jpeg, heic, webp, png
}

/// How a thumbnail fits its box (mirrors `ThumbnailModeMsg`).
enum ThumbnailFit: Equatable {
  case fill, fit
}

/// What was written.
struct ThumbnailOutput: Equatable {
  var path: String
  var widthPx: Int
  var heightPx: Int
  var format: ThumbnailFileFormat
}

/// A cancellation flag shared by a request and its cancel call. Thread-safe.
final class ThumbnailCancelToken {
  private let lock = NSLock()
  private var cancelled = false
  private var handlers: [() -> Void] = []

  var isCancelled: Bool {
    lock.lock(); defer { lock.unlock() }
    return cancelled
  }

  /// Runs [handler] on cancel (immediately when already cancelled).
  func onCancel(_ handler: @escaping () -> Void) {
    lock.lock()
    if cancelled { lock.unlock(); handler(); return }
    handlers.append(handler)
    lock.unlock()
  }

  func cancel() {
    lock.lock()
    if cancelled { lock.unlock(); return }
    cancelled = true
    let hs = handlers
    handlers = []
    lock.unlock()
    hs.forEach { $0() }
  }
}

enum ThumbnailGeometry {
  /// Largest box side accepted.
  static let maxSide = 4096

  /// The pixel size of the thumbnail of a [source]-sized image in a [box]: exactly the box for
  /// `fill`, the aspect-fitted size (at least 1 px per side) for `fit`. Never upscales a `fit`
  /// source smaller than the box.
  static func outputSize(source: CGSize, box: CGSize, fit: ThumbnailFit) -> CGSize {
    guard source.width > 0, source.height > 0 else { return box }
    if fit == .fill { return box }
    let s = min(box.width / source.width, box.height / source.height, 1)
    return CGSize(width: max(1, (source.width * s).rounded()), height: max(1, (source.height * s).rounded()))
  }

  /// The rectangle of a [source]-sized image to draw into the output (in source pixels): the
  /// centred crop with the box's aspect for `fill`, the whole image for `fit`.
  static func cropRect(source: CGSize, box: CGSize, fit: ThumbnailFit) -> CGRect {
    guard fit == .fill, source.width > 0, source.height > 0, box.width > 0, box.height > 0 else {
      return CGRect(origin: .zero, size: source)
    }
    let boxAspect = box.width / box.height
    let srcAspect = source.width / source.height
    if srcAspect > boxAspect {
      let w = source.height * boxAspect
      return CGRect(x: ((source.width - w) / 2).rounded(.down), y: 0, width: w.rounded(), height: source.height)
    }
    let h = source.width / boxAspect
    return CGRect(x: 0, y: ((source.height - h) / 2).rounded(.down), width: source.width, height: h.rounded())
  }

  /// The size to ask a fitting thumbnailer for so that its result covers [box] (`fill`) or fits it
  /// (`fit`), given the source's pixel size when known.
  static func requestSize(source: CGSize?, box: CGSize, fit: ThumbnailFit) -> CGSize {
    guard fit == .fill else { return box }
    guard let s = source, s.width > 0, s.height > 0 else {
      let side = min(CGFloat(maxSide), max(box.width, box.height) * 16 / 9)
      return CGSize(width: side, height: side)
    }
    // Scale that makes the short side cover the box, applied to the source's long side.
    let scale = max(box.width / s.width, box.height / s.height)
    return CGSize(width: min(CGFloat(maxSide), (s.width * scale).rounded(.up)),
                  height: min(CGFloat(maxSide), (s.height * scale).rounded(.up)))
  }
}

enum ThumbnailEncoder {
  /// True when HEIC can be encoded here: iOS 17+ (V2-28); macOS writes JPEG.
  static var heicAvailable: Bool {
    #if os(iOS)
    if #available(iOS 17.0, *) { return true }
    #endif
    return false
  }

  /// The format actually written for a requested one.
  static func effectiveFormat(_ requested: ThumbnailFileFormat) -> ThumbnailFileFormat {
    switch requested {
    case .jpeg, .png: return requested
    case .heic: return heicAvailable ? .heic : .jpeg
    case .webp: return .jpeg  // ImageIO has no WebP encoder (V2-V3).
    }
  }

  static func typeIdentifier(_ f: ThumbnailFileFormat) -> CFString {
    switch f {
    case .jpeg, .webp: return "public.jpeg" as CFString
    case .heic: return "public.heic" as CFString
    case .png: return "public.png" as CFString
    }
  }

  /// Draws the [crop] of [image] into an sRGB bitmap of [size] (high-quality interpolation; JPEG
  /// and HEIC outputs are opaque, on black).
  static func render(_ image: CGImage, crop: CGRect, size: CGSize, opaque: Bool) throws -> CGImage {
    let w = Int(size.width), h = Int(size.height)
    guard w > 0, h > 0 else { throw ThumbnailFailure.invalid("empty output size") }
    let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    let info = opaque ? CGImageAlphaInfo.noneSkipLast.rawValue : CGImageAlphaInfo.premultipliedLast.rawValue
    guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: info) else {
      throw ThumbnailFailure.io("no bitmap context")
    }
    ctx.interpolationQuality = .high
    if opaque {
      ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
      ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    }
    let src = CGSize(width: image.width, height: image.height)
    let c = crop.isEmpty ? CGRect(origin: .zero, size: src) : crop
    // Map the crop to the output: draw the whole image scaled so that the crop fills the bitmap.
    let sx = CGFloat(w) / c.width, sy = CGFloat(h) / c.height
    // CG's origin is bottom-left; the crop's y is measured from the top.
    let drawRect = CGRect(x: -c.minX * sx, y: -(src.height - c.maxY) * sy, width: src.width * sx, height: src.height * sy)
    ctx.draw(image, in: drawRect)
    guard let out = ctx.makeImage() else { throw ThumbnailFailure.io("could not render") }
    return out
  }

  /// Scales [image] into [box] with [fit] and writes it to [path] atomically (a part file renamed
  /// over the destination; the parent directory is created). Returns what was written.
  static func write(_ image: CGImage, box: CGSize, fit: ThumbnailFit, format requested: ThumbnailFileFormat, quality: Double, to path: String, token: ThumbnailCancelToken? = nil) throws -> ThumbnailOutput {
    let src = CGSize(width: image.width, height: image.height)
    let size = ThumbnailGeometry.outputSize(source: src, box: box, fit: fit)
    let crop = ThumbnailGeometry.cropRect(source: src, box: box, fit: fit)
    let format = effectiveFormat(requested)
    let scaled = (Int(size.width) == image.width && Int(size.height) == image.height && crop.size == src && format == .png)
      ? image
      : try render(image, crop: crop, size: size, opaque: format != .png)
    if token?.isCancelled == true { throw ThumbnailFailure.cancelled() }
    let url = URL(fileURLWithPath: path)
    let dir = url.deletingLastPathComponent()
    do {
      try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    } catch {
      throw ThumbnailFailure.io("could not create the cache directory")
    }
    let part = dir.appendingPathComponent(".\(UUID().uuidString).part")
    guard let dest = CGImageDestinationCreateWithURL(part as CFURL, typeIdentifier(format), 1, nil) else {
      throw ThumbnailFailure.io("no image destination")
    }
    var props: [CFString: Any] = [:]
    if format != .png { props[kCGImageDestinationLossyCompressionQuality] = max(0, min(1, quality)) }
    CGImageDestinationAddImage(dest, scaled, props as CFDictionary)
    guard CGImageDestinationFinalize(dest) else {
      try? FileManager.default.removeItem(at: part)
      throw ThumbnailFailure.io("could not encode")
    }
    do {
      if token?.isCancelled == true { throw ThumbnailFailure.cancelled() }
      _ = try? FileManager.default.removeItem(at: url)
      try FileManager.default.moveItem(at: part, to: url)
    } catch let f as ThumbnailFailure {
      try? FileManager.default.removeItem(at: part)
      throw f
    } catch {
      try? FileManager.default.removeItem(at: part)
      throw ThumbnailFailure.io("could not move the thumbnail into place")
    }
    return ThumbnailOutput(path: path, widthPx: scaled.width, heightPx: scaled.height, format: format)
  }
}

/// Thumbnails of media files (photos and videos) on iOS and macOS. Documents are HOM-26's.
final class FileThumbnailer {
  /// Waiting limit for Quick Look and AVFoundation before a request fails with `ioError`.
  var timeout: TimeInterval = 20

  /// When false, skips Quick Look (tests of the fallbacks).
  var useQuickLook = true

  init() {}

  /// The file URL of a [source] (absolute path or `file://` URL), or nil.
  static func fileURL(_ source: String) -> URL? {
    if source.hasPrefix("file://") { return URL(string: source).flatMap { $0.isFileURL ? $0 : nil } }
    if source.hasPrefix("/") { return URL(fileURLWithPath: source) }
    return nil
  }

  /// True when [url] looks like a video by its type (extension), false otherwise.
  static func isVideo(_ url: URL) -> Bool {
    #if canImport(UniformTypeIdentifiers)
    if #available(iOS 14.0, macOS 11.0, *), let t = UTType(filenameExtension: url.pathExtension.lowercased()) {
      return t.conforms(to: .movie) || t.conforms(to: .video)
    }
    #endif
    return ["mov", "mp4", "m4v", "3gp", "avi", "mkv", "webm", "mts", "m2ts"].contains(url.pathExtension.lowercased())
  }

  /// Pixel size of an image file from its header (no decode), honouring the EXIF orientation.
  static func imagePixelSize(_ url: URL) -> CGSize? {
    guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
          let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
          let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
    let o = props[kCGImagePropertyOrientation] as? Int ?? 1
    return o >= 5 ? CGSize(width: h, height: w) : CGSize(width: w, height: h)
  }

  /// Writes the thumbnail of the file [source] to [outputPath]. Blocks the calling (background)
  /// thread; [token] cancels it.
  func generate(source: String, box: CGSize, fit: ThumbnailFit, format: ThumbnailFileFormat, quality: Double, outputPath: String, token: ThumbnailCancelToken) throws -> ThumbnailOutput {
    guard let url = FileThumbnailer.fileURL(source) else { throw ThumbnailFailure.invalid("not a file source") }
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else {
      throw ThumbnailFailure.notFound("no such file")
    }
    guard FileManager.default.isReadableFile(atPath: url.path) else { throw ThumbnailFailure.permission("file not readable") }
    let video = FileThumbnailer.isVideo(url)
    let pixelSize = video ? nil : FileThumbnailer.imagePixelSize(url)
    let want = ThumbnailGeometry.requestSize(source: pixelSize, box: box, fit: fit)
    var image: CGImage?
    if useQuickLook { image = try quickLook(url, size: want, token: token) }
    if image == nil { image = video ? try videoFrame(url, size: want, token: token) : imageIO(url, size: want) }
    if token.isCancelled { throw ThumbnailFailure.cancelled() }
    guard let cg = image else { throw ThumbnailFailure.io("unreadable or corrupt media") }
    return try ThumbnailEncoder.write(cg, box: box, fit: fit, format: format, quality: quality, to: outputPath, token: token)
  }

  /// `QLThumbnailGenerator`'s thumbnail (nil when it has none for this file).
  func quickLook(_ url: URL, size: CGSize, token: ThumbnailCancelToken) throws -> CGImage? {
    let request = QLThumbnailGenerator.Request(fileAt: url, size: size, scale: 1, representationTypes: .thumbnail)
    let done = DispatchSemaphore(value: 0)
    var out: CGImage?
    let generator = QLThumbnailGenerator.shared
    token.onCancel { generator.cancel(request) }
    generator.generateBestRepresentation(for: request) { rep, _ in
      out = rep?.cgImage
      done.signal()
    }
    if done.wait(timeout: .now() + timeout) == .timedOut {
      generator.cancel(request)
      return nil
    }
    if token.isCancelled { throw ThumbnailFailure.cancelled() }
    return out
  }

  /// ImageIO's thumbnail of an image file (EXIF orientation applied), or nil.
  func imageIO(_ url: URL, size: CGSize) -> CGImage? {
    guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
          CGImageSourceGetCount(src) > 0 else { return nil }
    let opts: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceShouldCacheImmediately: true,
      kCGImageSourceThumbnailMaxPixelSize: Int(max(size.width, size.height).rounded(.up)),
    ]
    return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
  }

  /// A frame of a video file near its start (preferred track transform applied), or nil.
  func videoFrame(_ url: URL, size: CGSize, token: ThumbnailCancelToken) throws -> CGImage? {
    let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: false])
    let gen = AVAssetImageGenerator(asset: asset)
    gen.appliesPreferredTrackTransform = true
    gen.maximumSize = size
    gen.requestedTimeToleranceBefore = .positiveInfinity
    gen.requestedTimeToleranceAfter = CMTime(seconds: 1, preferredTimescale: 600)
    token.onCancel { gen.cancelAllCGImageGeneration() }
    let done = DispatchSemaphore(value: 0)
    var out: CGImage?
    let time = CMTime(seconds: 0.1, preferredTimescale: 600)
    gen.generateCGImagesAsynchronously(forTimes: [NSValue(time: time)]) { _, image, _, result, _ in
      if result == .succeeded { out = image }
      done.signal()
    }
    if done.wait(timeout: .now() + timeout) == .timedOut {
      gen.cancelAllCGImageGeneration()
      return nil
    }
    if token.isCancelled { throw ThumbnailFailure.cancelled() }
    return out
  }
}
