// OWNER: IOS-06
//
// Small LRU of decoded source frames (ARCH §15) for the preview session (IOS-11):
// - `showSourceFrame` (trim-edge preview): the exact source frame, scaled to the preview size;
// - `sampleColor` (chroma key picker): the pre-key source frame at full size, 3×3 average at a
//   normalized point (display orientation, top-left origin), gamma-encoded R'G'B' components
//   0...1 of the decoded frame without colour conversion (ARCH §13 colour management off);
// - look stills (UX-29 / IOS-11 `renderLookStills`): the unprocessed source frame at a height.
// Frames are decoded with FrameGrab (zero tolerance, preferred transform, SDR) and kept as
// CGImages; the cache is bounded by a byte budget per device tier and evicts least recently used
// frames. A frame larger than the whole budget is returned but not kept. Thread-safe; decoding
// blocks the caller (the preview control queue or a job queue, never main).

import AVFoundation
import CoreGraphics
import Foundation

final class SourceFrameCache {
    struct Key: Hashable {
        /// Media fingerprint (quickHash) or the file path when unknown.
        var media: String
        var sourceTimeUs: Int64
        /// Longest side bound (0 = full size).
        var maxLongSide: Int
    }

    let budgetBytes: Int
    private let lock = NSLock()
    private var frames: [Key: (image: CGImage, bytes: Int, used: UInt64)] = [:]
    private var clock: UInt64 = 0
    private(set) var totalBytes = 0
    /// Decodes performed (tests: hits do not decode).
    private(set) var decodeCount = 0

    init(budgetBytes: Int) {
        self.budgetBytes = max(0, budgetBytes)
    }

    convenience init(tier: DeviceTierMsg) {
        self.init(budgetBytes: SourceFrameCache.budgetBytes(for: tier))
    }

    /// Memory budget per tier: two to four full 1080p RGBA frames on weak devices, about six 4K
    /// frames on the high tier.
    static func budgetBytes(for tier: DeviceTierMsg) -> Int {
        let mb = 1_048_576
        switch tier {
        case .minimal: return 16 * mb
        case .low: return 24 * mb
        case .mid: return 64 * mb
        case .high: return 192 * mb
        }
    }

    static func cost(_ image: CGImage) -> Int { image.bytesPerRow * image.height }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return frames.count
    }

    // MARK: Frames

    /// The frame of [url] displayed at [sourceTimeUs], at most [maxLongSide] px on its long side
    /// (nil = full size).
    func frame(url: URL, media: String? = nil, sourceTimeUs: Int64, maxLongSide: Int? = nil) throws -> CGImage {
        let key = Key(media: media ?? url.standardizedFileURL.path, sourceTimeUs: sourceTimeUs, maxLongSide: maxLongSide ?? 0)
        lock.lock()
        if let hit = frames[key] {
            clock += 1
            frames[key] = (hit.image, hit.bytes, clock)
            lock.unlock()
            return hit.image
        }
        decodeCount += 1
        lock.unlock()
        let size = maxLongSide.map { CGSize(width: $0, height: $0) }
        let image = try FrameGrab.exactFrame(url: url, sourceTimeUs: sourceTimeUs, maximumSize: size, control: nil)
        insert(image, key: key)
        return image
    }

    /// A still for look previews: the unprocessed frame scaled to [heightPx] (aspect kept).
    func lookStill(url: URL, media: String? = nil, sourceTimeUs: Int64, heightPx: Int) throws -> CGImage {
        let full = try frame(url: url, media: media, sourceTimeUs: sourceTimeUs, maxLongSide: nil)
        guard heightPx > 0, heightPx < full.height else { return full }
        let width = max(1, Int((Double(full.width) * Double(heightPx) / Double(full.height)).rounded()))
        let space = full.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.itur_709)!
        guard let context = CGContext(
            data: nil, width: width, height: heightPx, bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else {
            throw EngineError(.internal, "still context failed")
        }
        context.interpolationQuality = .high
        context.draw(full, in: CGRect(x: 0, y: 0, width: width, height: heightPx))
        guard let scaled = context.makeImage() else { throw EngineError(.internal, "still scale failed") }
        return scaled
    }

    /// The 3×3 average colour at normalized ([x], [y]) (0...1, top-left origin, display
    /// orientation) of the full-size frame, as decoded R'G'B' (no colour conversion).
    func sampleColor(url: URL, media: String? = nil, sourceTimeUs: Int64, x: Double, y: Double) throws -> ColorMsg {
        guard x.isFinite, y.isFinite else { throw EngineError.invalidArgument("point", "not finite") }
        let image = try frame(url: url, media: media, sourceTimeUs: sourceTimeUs, maxLongSide: nil)
        return try SourceFrameCache.averageColor(of: image, x: x, y: y)
    }

    /// 3×3 average around the pixel at normalized ([x], [y]) of [image], in the image's own RGB space.
    static func averageColor(of image: CGImage, x: Double, y: Double) throws -> ColorMsg {
        let w = image.width, h = image.height
        guard w > 0, h > 0 else { throw EngineError(.decodeFailed, "empty frame") }
        let cx = min(w - 1, max(0, Int((min(1, max(0, x)) * Double(w)).rounded(.down))))
        let cy = min(h - 1, max(0, Int((min(1, max(0, y)) * Double(h)).rounded(.down))))
        let x0 = min(max(0, cx - 1), max(0, w - 3)), y0 = min(max(0, cy - 1), max(0, h - 3))
        let rw = min(3, w), rh = min(3, h)
        guard let crop = image.cropping(to: CGRect(x: x0, y: y0, width: rw, height: rh)) else {
            throw EngineError(.internal, "crop failed")
        }
        var pixels = [UInt8](repeating: 0, count: rw * rh * 4)
        // Read the values in the frame's own RGB space: no colour conversion (ARCH §13 maths runs
        // on gamma-encoded BT.709 R'G'B' with colour management off).
        let space = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.itur_709)!
        let drawn: Bool = pixels.withUnsafeMutableBytes { raw in
            guard let context = CGContext(
                data: raw.baseAddress, width: rw, height: rh, bitsPerComponent: 8, bytesPerRow: rw * 4, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
            else { return false }
            context.interpolationQuality = .none
            context.draw(crop, in: CGRect(x: 0, y: 0, width: rw, height: rh))
            return true
        }
        guard drawn else { throw EngineError(.internal, "sample context failed") }
        var sum = [Double](repeating: 0, count: 4)
        for i in 0..<(rw * rh) {
            for c in 0..<4 { sum[c] += Double(pixels[i * 4 + c]) }
        }
        let n = Double(rw * rh) * 255
        let alpha = sum[3] / n
        // Un-premultiply (source frames are opaque, alpha is 1).
        let scale = alpha > 0 ? 1 / alpha : 0
        return ColorMsg(red: min(1, sum[0] / n * scale), green: min(1, sum[1] / n * scale),
                        blue: min(1, sum[2] / n * scale), alpha: alpha)
    }

    // MARK: LRU

    private func insert(_ image: CGImage, key: Key) {
        let bytes = SourceFrameCache.cost(image)
        lock.lock()
        defer { lock.unlock() }
        guard bytes <= budgetBytes else { return }
        if let old = frames[key] { totalBytes -= old.bytes }
        clock += 1
        frames[key] = (image, bytes, clock)
        totalBytes += bytes
        while totalBytes > budgetBytes, let victim = frames.min(by: { $0.value.used < $1.value.used }) {
            frames[victim.key] = nil
            totalBytes -= victim.value.bytes
        }
    }

    /// Drops every frame of [media] (relink, media removed).
    func remove(media: String) {
        lock.lock()
        for key in frames.keys where key.media == media {
            totalBytes -= frames[key]?.bytes ?? 0
            frames[key] = nil
        }
        lock.unlock()
    }

    /// Drops everything (memory warning, session dispose).
    func removeAll() {
        lock.lock()
        frames.removeAll()
        totalBytes = 0
        lock.unlock()
    }
}
