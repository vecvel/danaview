// OWNER: HOM-04
// EXTENDED: HOM-26 (documentThumbnail, the hand-off this header named)
//
// The Apple thumbnailers behind `ThumbnailHostApi` (ARCH v1.2 V2-28, V2-104; BUILD_PLAN HOM-04):
//
// * mediaThumbnail: `ph:` sources through PhotoAssetThumbnailer (`PHCachingImageManager`), file
//   paths and `file://` URLs through FileThumbnailer (`QLThumbnailGenerator`, ImageIO / AVFoundation
//   fallbacks); `ms:` and `content://` sources are Android's and answer `notSupportedOnDevice`.
//   The work runs on a bounded background queue and the reply arrives on the main thread. The
//   output is JPEG, or HEIC on iOS 17+ when asked; the result reports the format written.
// * documentThumbnail: HOM-26's DocumentThumbnailer (QuickLook/QuickLookCore.swift) on the same
//   queue, with the same request ids and cancel; nil when a document has no thumbnail.
// * cancel: cancels a pending request (it fails with `cancelled`); unknown ids are ignored.
// * updateCaching: moves the PhotoKit prefetch window.
//
// Keep the class name and `init(context:)`: the Glue (DanaviewLibraryNativePlugin.swift)
// constructs it. Nothing is logged (rule 30); no network (rule 21, ARCH §9.1).

import CoreGraphics
import Foundation

final class ThumbnailHostApiImpl: ThumbnailHostApi {
  /// At most this many thumbnails are produced at once (the Dart cache queues the rest).
  static let maxConcurrent = 4

  private let files: FileThumbnailer
  private let photos: PhotoAssetThumbnailer
  private let documents = DocumentThumbnailer()
  private let queue: OperationQueue
  private let lock = NSLock()
  private var pending: [String: ThumbnailCancelToken] = [:]

  init(context: LibraryPluginContext) {
    files = FileThumbnailer()
    photos = PhotoAssetThumbnailer()
    queue = OperationQueue()
    queue.name = "danaview.library.thumbnails"
    queue.maxConcurrentOperationCount = ThumbnailHostApiImpl.maxConcurrent
    queue.qualityOfService = .userInitiated
  }

  /// The Pigeon error of a core failure.
  static func error(_ f: ThumbnailFailure) -> LibraryPigeonError {
    LibraryPigeonError(code: f.code, message: f.message, details: nil)
  }

  static func format(_ m: ThumbnailFormatMsg) -> ThumbnailFileFormat {
    switch m {
    case .jpeg: return .jpeg
    case .heic: return .heic
    case .webp: return .webp
    case .png: return .png
    }
  }

  static func formatMsg(_ f: ThumbnailFileFormat) -> ThumbnailFormatMsg {
    switch f {
    case .jpeg: return .jpeg
    case .heic: return .heic
    case .webp: return .webp
    case .png: return .png
    }
  }

  static func fit(_ m: ThumbnailModeMsg) -> ThumbnailFit { m == .fill ? .fill : .fit }

  static func msg(_ o: ThumbnailOutput) -> ThumbnailResultMsg {
    ThumbnailResultMsg(path: o.path, widthPx: Int64(o.widthPx), heightPx: Int64(o.heightPx), format: formatMsg(o.format))
  }

  /// The validation failure of [request], or nil when it is well-formed.
  static func validate(_ r: MediaThumbnailRequestMsg) -> ThumbnailFailure? {
    let side = Int64(ThumbnailGeometry.maxSide)
    if r.requestId.isEmpty { return .invalid("empty request id") }
    if r.widthPx < 1 || r.heightPx < 1 || r.widthPx > side || r.heightPx > side { return .invalid("box out of range") }
    if !(0...1).contains(r.quality) { return .invalid("quality out of range") }
    if !r.outputPath.hasPrefix("/") { return .invalid("output path is not absolute") }
    if r.source.hasPrefix("ms:") || r.source.hasPrefix("content://") { return .notSupported("Android source") }
    if PhotoAssetThumbnailer.localIdentifier(r.source) == nil && FileThumbnailer.fileURL(r.source) == nil {
      return .invalid("unknown source")
    }
    return nil
  }

  func mediaThumbnail(request: MediaThumbnailRequestMsg, completion: @escaping (Result<ThumbnailResultMsg, Error>) -> Void) {
    if let f = ThumbnailHostApiImpl.validate(request) {
      completion(.failure(ThumbnailHostApiImpl.error(f)))
      return
    }
    let token = ThumbnailCancelToken()
    lock.lock()
    if pending[request.requestId] != nil {
      lock.unlock()
      completion(.failure(ThumbnailHostApiImpl.error(.busy("a request with this id is running"))))
      return
    }
    pending[request.requestId] = token
    lock.unlock()
    let box = CGSize(width: Int(request.widthPx), height: Int(request.heightPx))
    let fit = ThumbnailHostApiImpl.fit(request.mode)
    let format = ThumbnailHostApiImpl.format(request.format)
    queue.addOperation { [files, photos, weak self] in
      let result: Result<ThumbnailResultMsg, Error>
      do {
        if token.isCancelled { throw ThumbnailFailure.cancelled() }
        let out: ThumbnailOutput
        if PhotoAssetThumbnailer.localIdentifier(request.source) != nil {
          out = try photos.generate(source: request.source, box: box, fit: fit, format: format, quality: request.quality, outputPath: request.outputPath, token: token)
        } else {
          out = try files.generate(source: request.source, box: box, fit: fit, format: format, quality: request.quality, outputPath: request.outputPath, token: token)
        }
        result = .success(ThumbnailHostApiImpl.msg(out))
      } catch let f as ThumbnailFailure {
        result = .failure(ThumbnailHostApiImpl.error(f))
      } catch {
        result = .failure(ThumbnailHostApiImpl.error(.io("thumbnail failed")))
      }
      self?.finish(request.requestId)
      DispatchQueue.main.async { completion(result) }
    }
  }

  private func finish(_ id: String) {
    lock.lock()
    pending[id] = nil
    lock.unlock()
  }

  // HOM-26: documents through QuickLook/QuickLookCore.swift DocumentThumbnailer (PDF first page at
  // the request's scale, Quick Look thumbnails otherwise; nil when there is none).
  func documentThumbnail(request: DocumentThumbnailRequestMsg, completion: @escaping (Result<ThumbnailResultMsg?, Error>) -> Void) {
    if let f = DocumentThumbnailer.validate(requestId: request.requestId, path: request.path, widthPx: request.widthPx, heightPx: request.heightPx,
                                            scale: request.scale, quality: request.quality, outputPath: request.outputPath) {
      completion(.failure(ThumbnailHostApiImpl.error(f)))
      return
    }
    let token = ThumbnailCancelToken()
    lock.lock()
    if pending[request.requestId] != nil {
      lock.unlock()
      completion(.failure(ThumbnailHostApiImpl.error(.busy("a request with this id is running"))))
      return
    }
    pending[request.requestId] = token
    lock.unlock()
    let box = CGSize(width: Int(request.widthPx), height: Int(request.heightPx))
    let format = ThumbnailHostApiImpl.format(request.format)
    queue.addOperation { [documents, weak self] in
      let result: Result<ThumbnailResultMsg?, Error>
      do {
        if token.isCancelled { throw ThumbnailFailure.cancelled() }
        let out = try documents.generate(path: request.path, box: box, scale: CGFloat(request.scale), format: format, quality: request.quality,
                                         outputPath: request.outputPath, token: token)
        result = .success(out.map(ThumbnailHostApiImpl.msg))
      } catch let f as ThumbnailFailure {
        result = .failure(ThumbnailHostApiImpl.error(f))
      } catch {
        result = .failure(ThumbnailHostApiImpl.error(.io("thumbnail failed")))
      }
      self?.finish(request.requestId)
      DispatchQueue.main.async { completion(result) }
    }
  }

  func cancel(requestId: String) throws {
    lock.lock()
    let token = pending[requestId]
    lock.unlock()
    token?.cancel()
  }

  func updateCaching(window: ThumbnailCachingMsg) throws {
    let side = Int64(ThumbnailGeometry.maxSide)
    guard window.widthPx >= 1, window.heightPx >= 1, window.widthPx <= side, window.heightPx <= side else {
      throw ThumbnailHostApiImpl.error(.invalid("box out of range"))
    }
    let box = CGSize(width: Int(window.widthPx), height: Int(window.heightPx))
    let fit = ThumbnailHostApiImpl.fit(window.mode)
    let start = window.startSources, stop = window.stopSources
    guard !start.isEmpty || !stop.isEmpty else { return }
    DispatchQueue.global(qos: .utility).async { [photos] in
      photos.updateCaching(start: start, stop: stop, box: box, fit: fit)
    }
  }
}
