// OWNER: IOS-09
//
// Decoded image layers and solids at render scale (ARCH §11.2 `image` / `solid` layers, §11.6 "sample").
//
// Images are decoded once per (file, target long side) with ImageIO (`CGImageSourceCreateThumbnailAtIndex`,
// EXIF orientation applied, so the result is display-oriented like `asset.w/h`), downsampled to the
// size they are drawn at (never upscaled), and wrapped as CIImages WITHOUT a colour space: the render
// math runs on the encoded values (ARCH §11.6, colour management off). Solids are generated images
// (infinite colour cropped to the requested box), premultiplied by Core Image from the plan's
// straight ARGB colour. The cache is an LRU with a byte budget; `trim` serves memory warnings.

import CoreGraphics
import CoreImage
import Foundation
import ImageIO

/// Errors of image decoding.
struct ImageLayerError: Error, CustomStringConvertible, Equatable {
    let message: String
    var description: String { "image layer: \(message)" }
}

final class ImageLayerCache {
    private struct Entry {
        let image: CIImage
        let bytes: Int
    }

    private let lock = NSLock()
    private var cache: [String: Entry] = [:]
    private var order: [String] = []
    private var bytes = 0
    /// Byte budget of decoded images (solids cost nothing).
    let budgetBytes: Int

    init(budgetBytes: Int = 128 << 20) {
        self.budgetBytes = max(1, budgetBytes)
    }

    /// The long side (px) an image layer needs at render scale: `base` long side × max scale × render
    /// scale, rounded up; 0 means "full resolution".
    static func targetLongSide(base: PlanSize, maxScale: Double, renderScale: Double) -> Int {
        let side = max(base.w, base.h) * max(maxScale, 0) * max(renderScale, 0)
        guard side.isFinite, side > 0 else { return 0 }
        return Int(side.rounded(.up))
    }

    /// The decoded image at [url] whose long side is at most [maxLongSide] px (0 = full size), extent
    /// `(0, 0, w, h)`, display-oriented, no colour space.
    func image(for url: URL, maxLongSide: Int) throws -> CIImage {
        let key = "\(url.standardizedFileURL.path)#\(maxLongSide)"
        lock.lock()
        if let hit = cache[key] {
            touch(key)
            lock.unlock()
            return hit.image
        }
        lock.unlock()
        let cg = try Self.decode(url: url, maxLongSide: maxLongSide)
        let image = CIImage(cgImage: cg, options: [.colorSpace: NSNull()])
        let cost = cg.bytesPerRow * cg.height
        lock.lock()
        defer { lock.unlock() }
        if cache[key] == nil {
            cache[key] = Entry(image: image, bytes: cost)
            bytes += cost
        }
        touch(key)
        evict(toBytes: budgetBytes, keep: key)
        return cache[key]?.image ?? image
    }

    /// The decoded image of a plan `image` asset (its `uri`).
    func image(forUri uri: String, maxLongSide: Int) throws -> CIImage {
        guard let url = URL(string: uri), url.isFileURL else { throw ImageLayerError(message: "not a file URL: \(uri)") }
        return try image(for: url, maxLongSide: maxLongSide)
    }

    /// A solid of plan ARGB [argb] (straight alpha) covering `(0, 0, width, height)`.
    static func solid(argb: UInt32, width: Double, height: Double) -> CIImage {
        let a = CGFloat((argb >> 24) & 0xFF) / 255
        let r = CGFloat((argb >> 16) & 0xFF) / 255
        let g = CGFloat((argb >> 8) & 0xFF) / 255
        let b = CGFloat(argb & 0xFF) / 255
        // Pre-multiplied explicitly through an RGBAf pixel: CIColor carries no colour space semantics we
        // want, and the explicit pixel keeps the value exact with colour management off.
        var px: [Float] = [Float(r * a), Float(g * a), Float(b * a), Float(a)]
        let data = px.withUnsafeMutableBufferPointer { Data(buffer: $0) }
        let one = CIImage(bitmapData: data, bytesPerRow: 16, size: CGSize(width: 1, height: 1), format: .RGBAf, colorSpace: nil)
        return one.clampedToExtent().cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
    }

    /// Bytes currently cached.
    var cachedBytes: Int {
        lock.lock()
        defer { lock.unlock() }
        return bytes
    }

    /// Number of cached images.
    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return cache.count
    }

    /// Drops images until at most [fraction] of the budget is held (memory warning: 0.25).
    func trim(to fraction: Double = 0) {
        lock.lock()
        defer { lock.unlock() }
        evict(toBytes: Int(Double(budgetBytes) * fraction), keep: nil)
    }

    private func touch(_ key: String) {
        order.removeAll { $0 == key }
        order.append(key)
    }

    private func evict(toBytes limit: Int, keep: String?) {
        var i = 0
        while bytes > limit, i < order.count {
            let key = order[i]
            if key == keep {
                i += 1
                continue
            }
            order.remove(at: i)
            if let e = cache.removeValue(forKey: key) { bytes -= e.bytes }
        }
    }

    /// ImageIO decode: orientation applied, downsampled to [maxLongSide] (never upscaled), immediate
    /// decode so rendering never pays for it.
    static func decode(url: URL, maxLongSide: Int) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            throw ImageLayerError(message: "cannot open \(url.lastPathComponent)")
        }
        guard CGImageSourceGetCount(source) > 0 else { throw ImageLayerError(message: "no image in \(url.lastPathComponent)") }
        var fullLongSide = 0
        if let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int {
            fullLongSide = max(w, h)
        }
        var limit = fullLongSide
        if maxLongSide > 0, fullLongSide > 0 { limit = min(maxLongSide, fullLongSide) }
        var options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        if limit > 0 { options[kCGImageSourceThumbnailMaxPixelSize] = limit }
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw ImageLayerError(message: "cannot decode \(url.lastPathComponent)")
        }
        return image
    }
}
