// OWNER: IOS-03
//
// JPEG thumbnail strips (ARCH §12.3, §15): tile t of a request holds framesPerTile (8) frames at
// times (t · framesPerTile + k) · intervalMs (k = 0 ..< framesPerTile, frames at or past the media
// duration are left out), each heightPx high and aspect-correct (display orientation), side by
// side in one JPEG (ImageIO, quality 0.7). Frames come from AVAssetImageGenerator
// (appliesPreferredTrackTransform, tolerance ± intervalMs / 2, dynamicRangePolicy .forceSDR on
// iOS 18+), one generator per (file, interval, height) kept in a small LRU; still images use an
// ImageIO thumbnail. Strips are cached in DiskCache thumbs/ (key: fingerprint, interval, height,
// tile, frames per tile, proxy) as `.vwth` = "VWTH" + frames (u32 LE) + frame width (u32 LE) + JPEG.
//
// Scheduling: at most 8 tiles render at once; pending requests are served visible > prefetch >
// background, FIFO within a priority. `cancel(requestId)` answers the pending call with
// `cancelled` at once and stops a running render before its next frame.

import AVFoundation
import CoreGraphics
import Flutter
import Foundation
import ImageIO
import UniformTypeIdentifiers

final class ThumbnailService: ThumbnailProviding {
    private let context: EngineContext

    init(context: EngineContext) {
        self.context = context
    }

    static let maxConcurrent = 8
    static let jpegQuality: CGFloat = 0.7
    static let cacheExtension = "vwth"

    private final class Request {
        let id: String
        let message: ThumbnailRequestMsg
        let url: URL
        let priority: ThumbPriorityMsg
        let sequence: Int
        let reply: ReplyOnce<ThumbnailTileMsg>
        private let lock = NSLock()
        private var cancelledFlag = false

        init(id: String, message: ThumbnailRequestMsg, url: URL, priority: ThumbPriorityMsg, sequence: Int,
             reply: @escaping EngineReply<ThumbnailTileMsg>) {
            self.id = id
            self.message = message
            self.url = url
            self.priority = priority
            self.sequence = sequence
            self.reply = ReplyOnce(reply)
        }

        var cancelled: Bool {
            lock.lock()
            defer { lock.unlock() }
            return cancelledFlag
        }

        func cancel() {
            lock.lock()
            cancelledFlag = true
            lock.unlock()
            reply.send(.failure(EngineError.cancelled))
        }
    }

    private let lock = NSLock()
    private var pending: [Request] = []
    private var running: [String: Request] = [:]
    private var sequence = 0
    private let workers = DispatchQueue(
        label: "com.vecvel.vwish.editor.thumbnails", qos: .userInitiated, attributes: .concurrent)

    /// Number of tiles rendering now (tests).
    var runningCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return running.count
    }

    // MARK: ThumbnailProviding

    func tile(
        requestId: String, request: ThumbnailRequestMsg, mediaURL: URL, priority: ThumbPriorityMsg,
        reply: @escaping EngineReply<ThumbnailTileMsg>
    ) {
        let store: CacheStore?
        if let paths = context.paths {
            store = DiskCache.stores(for: paths).thumbs
        } else {
            store = nil
        }
        // Cache hits answer at once (<= 20 ms), without a worker slot.
        if let store = store, let data = store.read(key: ThumbnailService.cacheKey(request), ext: ThumbnailService.cacheExtension),
           let tile = ThumbnailService.decodeCached(data) {
            reply(.success(tile))
            return
        }
        lock.lock()
        sequence += 1
        let entry = Request(id: requestId, message: request, url: mediaURL, priority: priority, sequence: sequence, reply: reply)
        if let duplicate = pending.first(where: { $0.id == requestId }) ?? running[requestId] {
            lock.unlock()
            duplicate.cancel()
            lock.lock()
            pending.removeAll { $0.id == requestId }
        }
        pending.append(entry)
        lock.unlock()
        schedule(store: store)
    }

    func cancel(requestId: String) {
        lock.lock()
        let waiting = pending.first { $0.id == requestId }
        pending.removeAll { $0.id == requestId }
        let active = running[requestId]
        lock.unlock()
        waiting?.cancel()
        active?.cancel()
    }

    private func schedule(store: CacheStore?) {
        lock.lock()
        var started: [Request] = []
        while running.count < ThumbnailService.maxConcurrent, !pending.isEmpty {
            let index = pending.indices.min { a, b in
                let pa = pending[a], pb = pending[b]
                return pa.priority.rawValue != pb.priority.rawValue
                    ? pa.priority.rawValue < pb.priority.rawValue : pa.sequence < pb.sequence
            }!
            let next = pending.remove(at: index)
            if next.cancelled { continue }
            running[next.id] = next
            started.append(next)
        }
        lock.unlock()
        for request in started {
            workers.async { [weak self] in
                self?.run(request, store: store)
            }
        }
    }

    private func run(_ request: Request, store: CacheStore?) {
        defer {
            lock.lock()
            if running[request.id] === request { running[request.id] = nil }
            lock.unlock()
            schedule(store: store)
        }
        guard !request.cancelled else { return }
        do {
            let tile = try ThumbnailService.render(url: request.url, request: request.message, isCancelled: { request.cancelled })
            if let store = store {
                _ = try? store.write(
                    ThumbnailService.encodeCached(tile), key: ThumbnailService.cacheKey(request.message),
                    ext: ThumbnailService.cacheExtension)
            }
            request.reply.send(.success(tile))
        } catch {
            request.reply.send(.failure(EngineError.from(error)))
        }
    }

    // MARK: Cache format

    static func cacheKey(_ request: ThumbnailRequestMsg) -> String {
        CacheStore.stableHash(
            "\(request.media.fingerprint)|\(request.intervalMs)|\(request.heightPx)|\(request.tileIndex)|\(request.framesPerTile)|\(request.proxy ? 1 : 0)")
    }

    static func encodeCached(_ tile: ThumbnailTileMsg) -> Data {
        var data = Data("VWTH".utf8)
        var frames = UInt32(tile.frames).littleEndian
        var width = UInt32(tile.frameWidthPx).littleEndian
        data.append(Data(bytes: &frames, count: 4))
        data.append(Data(bytes: &width, count: 4))
        data.append(tile.encoded.data)
        return data
    }

    static func decodeCached(_ data: Data) -> ThumbnailTileMsg? {
        guard data.count > 12, data.prefix(4) == Data("VWTH".utf8) else { return nil }
        let bytes = [UInt8](data.prefix(12))
        let frames = UInt32(bytes[4]) | UInt32(bytes[5]) << 8 | UInt32(bytes[6]) << 16 | UInt32(bytes[7]) << 24
        let width = UInt32(bytes[8]) | UInt32(bytes[9]) << 8 | UInt32(bytes[10]) << 16 | UInt32(bytes[11]) << 24
        guard frames > 0, width > 0 else { return nil }
        return ThumbnailTileMsg(
            encoded: FlutterStandardTypedData(bytes: data.subdata(in: 12..<data.count)),
            frames: Int64(frames), frameWidthPx: Int64(width))
    }

    // MARK: Generators

    private final class GeneratorEntry {
        let generator: AVAssetImageGenerator
        let durationMs: Double
        /// Display width / height.
        let aspect: Double
        var lastUse = Date()

        init(generator: AVAssetImageGenerator, durationMs: Double, aspect: Double) {
            self.generator = generator
            self.durationMs = durationMs
            self.aspect = aspect
        }
    }

    private static let generatorLock = NSLock()
    private static var generators: [String: GeneratorEntry] = [:]
    static let maxGenerators = 6

    /// Releases every cached generator (memory pressure).
    static func dropGenerators() {
        generatorLock.lock()
        generators.removeAll()
        generatorLock.unlock()
    }

    private static func generator(url: URL, intervalMs: Int64, heightPx: Int64) throws -> GeneratorEntry {
        let key = "\(url.path)|\(intervalMs)|\(heightPx)"
        generatorLock.lock()
        if let entry = generators[key] {
            entry.lastUse = Date()
            generatorLock.unlock()
            return entry
        }
        generatorLock.unlock()

        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let facts = try MediaBlocking.await { () -> (CMTime, CGSize, CGAffineTransform)? in
            let duration = try await asset.load(.duration)
            guard let track = try await asset.loadTracks(withMediaType: .video).first else { return nil }
            let (size, transform) = try await track.load(.naturalSize, .preferredTransform)
            return (duration, size, transform)
        }
        guard let (duration, natural, transform) = facts else {
            throw EngineError(.unsupportedMedia, "no video track for thumbnails")
        }
        let display = natural.applying(transform)
        let aspect = abs(display.height) > 0 ? Double(abs(display.width) / abs(display.height)) : 16.0 / 9.0
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        let half = CMTime(value: max(1, intervalMs) * 500, timescale: 1_000_000)
        generator.requestedTimeToleranceBefore = half
        generator.requestedTimeToleranceAfter = half
        let height = CGFloat(heightPx)
        generator.maximumSize = CGSize(width: (height * CGFloat(aspect)).rounded(.up), height: height)
        if #available(iOS 18.0, *) {
            generator.dynamicRangePolicy = .forceSDR
        }
        let entry = GeneratorEntry(generator: generator, durationMs: duration.seconds * 1000, aspect: aspect)

        generatorLock.lock()
        generators[key] = entry
        if generators.count > maxGenerators,
           let oldest = generators.min(by: { $0.value.lastUse < $1.value.lastUse })?.key {
            generators[oldest] = nil
        }
        generatorLock.unlock()
        return entry
    }

    // MARK: Rendering

    /// The request times (ms) of tile [request] that lie before [durationMs].
    static func frameTimesMs(_ request: ThumbnailRequestMsg, durationMs: Double) -> [Int64] {
        let first = request.tileIndex * request.framesPerTile
        return (0..<request.framesPerTile).map { (first + $0) * request.intervalMs }.filter { Double($0) < durationMs }
    }

    /// Frame width of a strip for [aspect] (display width / height) at [heightPx]; even, >= 2.
    static func frameWidth(aspect: Double, heightPx: Int64) -> Int {
        let raw = Int((Double(heightPx) * aspect).rounded())
        return max(2, raw + (raw % 2))
    }

    /// Renders one strip (blocking; checks [isCancelled] before every frame).
    static func render(url: URL, request: ThumbnailRequestMsg, isCancelled: () -> Bool) throws -> ThumbnailTileMsg {
        if SniffedContainer.sniff(url).isImage {
            return try renderStill(url: url, request: request)
        }
        let entry = try generator(url: url, intervalMs: request.intervalMs, heightPx: request.heightPx)
        let times = frameTimesMs(request, durationMs: entry.durationMs)
        guard !times.isEmpty else {
            throw EngineError.invalidArgument("request.tileIndex", "tile starts after the media end")
        }
        var images: [CGImage] = []
        for ms in times {
            if isCancelled() { throw EngineError.cancelled }
            images.append(try image(entry.generator, at: CMTime(value: ms * 1000, timescale: 1_000_000)))
        }
        if isCancelled() { throw EngineError.cancelled }
        return try strip(images, frameWidth: frameWidth(aspect: entry.aspect, heightPx: request.heightPx),
                         heightPx: Int(request.heightPx))
    }

    private static func image(_ generator: AVAssetImageGenerator, at time: CMTime) throws -> CGImage {
        let done = DispatchSemaphore(value: 0)
        var result: Result<CGImage, Error> = .failure(EngineError(.decodeFailed, "no thumbnail"))
        generator.generateCGImagesAsynchronously(forTimes: [NSValue(time: time)]) { _, image, _, status, error in
            switch status {
            case .succeeded:
                if let image = image { result = .success(image) }
            case .cancelled:
                result = .failure(EngineError.cancelled)
            default:
                result = .failure(error.map(EngineError.from) ?? EngineError(.decodeFailed, "thumbnail failed"))
            }
            done.signal()
        }
        done.wait()
        return try result.get()
    }

    private static func renderStill(url: URL, request: ThumbnailRequestMsg) throws -> ThumbnailTileMsg {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(request.heightPx) * 4,
        ]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw EngineError(.unsupportedMedia, "image not decodable")
        }
        let aspect = Double(image.width) / Double(max(1, image.height))
        return try strip([image], frameWidth: frameWidth(aspect: aspect, heightPx: request.heightPx),
                         heightPx: Int(request.heightPx))
    }

    /// Draws [images] aspect-fit into cells of frameWidth × heightPx and encodes the JPEG.
    static func strip(_ images: [CGImage], frameWidth: Int, heightPx: Int) throws -> ThumbnailTileMsg {
        let width = frameWidth * images.count
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil, width: width, height: heightPx, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { throw EngineError(.internal, "strip context") }
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: heightPx))
        context.interpolationQuality = .medium
        for (index, image) in images.enumerated() {
            let cell = CGRect(x: index * frameWidth, y: 0, width: frameWidth, height: heightPx)
            let scale = min(cell.width / CGFloat(image.width), cell.height / CGFloat(image.height))
            let size = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
            context.draw(image, in: CGRect(
                x: cell.minX + (cell.width - size.width) / 2, y: cell.minY + (cell.height - size.height) / 2,
                width: size.width, height: size.height))
        }
        guard let strip = context.makeImage() else { throw EngineError(.internal, "strip image") }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw EngineError(.internal, "jpeg destination")
        }
        CGImageDestinationAddImage(destination, strip, [kCGImageDestinationLossyCompressionQuality: jpegQuality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw EngineError(.internal, "jpeg encode") }
        return ThumbnailTileMsg(
            encoded: FlutterStandardTypedData(bytes: data as Data), frames: Int64(images.count),
            frameWidthPx: Int64(frameWidth))
    }
}
