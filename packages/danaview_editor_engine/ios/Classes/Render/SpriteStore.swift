// OWNER: IOS-09
//
// `.vsprite` decoding (ARCH §10.3, D-06; codec of API-04 `vsprite_codec.dart`).
//
// Layout, little-endian: 'VSPR', u16 version = 1, u16 flags (bit0 = hasReveal, other bits 0), u32 w,
// u32 h, f32 scale (sprite px per canvas px); then a zlib stream of w·h·4 bytes of premultiplied RGBA8
// (sRGB-encoded, rows top to bottom); if hasReveal, a second zlib stream of w·h·2 bytes = u16 LE glyph
// order per pixel (0xFFFF = background). The streams are concatenated without length fields: the
// first is inflated to its end (zlib verifies its Adler-32) and the second starts at the next byte;
// nothing may follow the last stream.
//
// The decoded sprite becomes two aligned CIImages: the RGBA (premultiplied, no colour space: values are
// used as encoded, ARCH §11.6) and, with a reveal map, the glyph map packed for dv_reveal as RGBA8
// (R = low byte, G = high byte, B = 0, A = 255, so premultiplication never touches it).

import CoreImage
import Foundation
import zlib

/// Errors of `.vsprite` decoding.
struct SpriteFormatError: Error, CustomStringConvertible, Equatable {
    let message: String
    var description: String { "vsprite: \(message)" }
}

/// A decoded `.vsprite`.
final class SpriteImage {
    let width: Int
    let height: Int
    /// Sprite px per canvas px (`sscale`).
    let scale: Float
    /// Premultiplied RGBA8, row-major, top row first (`width·height·4` bytes).
    let rgba: Data
    /// Glyph order per pixel (0xFFFF = background), nil without a reveal map.
    let glyphs: [UInt16]?

    var hasReveal: Bool { glyphs != nil }
    /// Bytes held (RGBA + packed glyph map).
    var byteCount: Int { rgba.count + (glyphs == nil ? 0 : width * height * 4) }

    init(width: Int, height: Int, scale: Float, rgba: Data, glyphs: [UInt16]?) {
        self.width = width
        self.height = height
        self.scale = scale
        self.rgba = rgba
        self.glyphs = glyphs
    }

    /// The sprite as a premultiplied CIImage, extent `(0, 0, width, height)`.
    lazy var image: CIImage = CIImage(
        bitmapData: rgba, bytesPerRow: width * 4, size: CGSize(width: width, height: height), format: .RGBA8,
        colorSpace: nil)

    /// The glyph map packed for dv_reveal (aligned with [image]), nil without a reveal map.
    lazy var glyphImage: CIImage? = {
        guard let glyphs else { return nil }
        var px = [UInt8](repeating: 0, count: width * height * 4)
        for i in 0..<glyphs.count {
            px[i * 4] = UInt8(glyphs[i] & 0xFF)
            px[i * 4 + 1] = UInt8(glyphs[i] >> 8)
            px[i * 4 + 3] = 255
        }
        return CIImage(
            bitmapData: Data(px), bytesPerRow: width * 4, size: CGSize(width: width, height: height), format: .RGBA8,
            colorSpace: nil)
    }()

    /// The pixel at (x, y) (top-left origin) as RGBA bytes.
    func pixel(x: Int, y: Int) -> [UInt8] {
        let o = (y * width + x) * 4
        return [rgba[o], rgba[o + 1], rgba[o + 2], rgba[o + 3]]
    }
}

/// `.vsprite` v1 codec (decode only; the Dart side writes).
enum VspriteDecoder {
    static let headerBytes = 20
    static let flagReveal: UInt16 = 1
    static let backgroundGlyph: UInt16 = 0xFFFF
    /// Largest side accepted (Metal's texture limit on iOS).
    static let maxSide = 16384

    static func decode(_ data: Data, maxSide: Int = VspriteDecoder.maxSide) throws -> SpriteImage {
        let bytes = [UInt8](data)
        guard bytes.count >= headerBytes else { throw SpriteFormatError(message: "truncated header") }
        guard bytes[0] == 0x56, bytes[1] == 0x53, bytes[2] == 0x50, bytes[3] == 0x52 else {
            throw SpriteFormatError(message: "missing 'VSPR' magic")
        }
        func u16(_ o: Int) -> UInt16 { UInt16(bytes[o]) | UInt16(bytes[o + 1]) << 8 }
        func u32(_ o: Int) -> UInt32 {
            UInt32(bytes[o]) | UInt32(bytes[o + 1]) << 8 | UInt32(bytes[o + 2]) << 16 | UInt32(bytes[o + 3]) << 24
        }
        let version = u16(4)
        guard version == 1 else { throw SpriteFormatError(message: "unsupported version \(version)") }
        let flags = u16(6)
        guard flags & ~flagReveal == 0 else { throw SpriteFormatError(message: "unknown flags \(flags)") }
        let w = Int(u32(8))
        let h = Int(u32(12))
        let scale = Float(bitPattern: u32(16))
        guard w >= 1, h >= 1, w <= maxSide, h <= maxSide else {
            throw SpriteFormatError(message: "bad size \(w)x\(h) (max side \(maxSide))")
        }
        guard scale.isFinite, scale > 0 else { throw SpriteFormatError(message: "bad scale \(scale)") }
        let n = w * h
        let (rgba, end) = try inflate(bytes, from: headerBytes, expected: n * 4)
        var tail = end
        var glyphs: [UInt16]?
        if flags & flagReveal != 0 {
            let (raw, end2) = try inflate(bytes, from: end, expected: n * 2)
            tail = end2
            var g = [UInt16](repeating: 0, count: n)
            for i in 0..<n {
                g[i] = UInt16(raw[i * 2]) | UInt16(raw[i * 2 + 1]) << 8
            }
            glyphs = g
        }
        guard tail == bytes.count else { throw SpriteFormatError(message: "\(bytes.count - tail) trailing bytes") }
        return SpriteImage(width: w, height: h, scale: scale, rgba: Data(rgba), glyphs: glyphs)
    }

    /// Inflates one zlib stream (RFC 1950, Adler-32 verified by zlib) starting at [from]; returns the
    /// [expected] bytes and the offset just past the stream.
    static func inflate(_ bytes: [UInt8], from: Int, expected: Int) throws -> ([UInt8], Int) {
        guard from < bytes.count else { throw SpriteFormatError(message: "missing zlib stream") }
        var out = [UInt8](repeating: 0, count: expected)
        var stream = z_stream()
        guard inflateInit_(&stream, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw SpriteFormatError(message: "inflateInit failed")
        }
        defer { inflateEnd(&stream) }
        let available = bytes.count - from
        let status: Int32 = bytes.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                stream.next_in = UnsafeMutablePointer(mutating: src.baseAddress! + from)
                stream.avail_in = uInt(available)
                stream.next_out = dst.baseAddress
                stream.avail_out = uInt(expected)
                var rc: Int32 = Z_OK
                while rc == Z_OK {
                    rc = zlib.inflate(&stream, Z_FINISH)
                    if rc == Z_BUF_ERROR, stream.avail_out == 0 {
                        // More output than expected: the stream is longer than the header says.
                        return Z_DATA_ERROR
                    }
                }
                return rc
            }
        }
        guard status == Z_STREAM_END else { throw SpriteFormatError(message: "corrupt zlib stream (\(status))") }
        guard Int(stream.total_out) == expected else {
            throw SpriteFormatError(message: "zlib stream holds \(stream.total_out) bytes, expected \(expected)")
        }
        return (out, from + Int(stream.total_in))
    }
}

/// Decoded sprites cached by path with an LRU byte budget (thread-safe).
final class SpriteStore {
    private let lock = NSLock()
    private var cache: [String: SpriteImage] = [:]
    private var order: [String] = []
    private var bytes = 0
    /// Byte budget (RGBA + glyph maps).
    let budgetBytes: Int
    /// Largest sprite side accepted (`EditorCapabilities.maxTextureSize`, 16384 on iOS Metal).
    let maxTextureSize: Int

    init(budgetBytes: Int = 96 << 20, maxTextureSize: Int = VspriteDecoder.maxSide) {
        self.budgetBytes = max(1, budgetBytes)
        self.maxTextureSize = maxTextureSize
    }

    /// The sprite at [url], decoded on first use.
    func sprite(for url: URL) throws -> SpriteImage {
        let key = url.standardizedFileURL.path
        lock.lock()
        if let hit = cache[key] {
            touch(key)
            lock.unlock()
            return hit
        }
        lock.unlock()
        let sprite = try VspriteDecoder.decode(try Data(contentsOf: url, options: .mappedIfSafe), maxSide: maxTextureSize)
        lock.lock()
        defer { lock.unlock() }
        if cache[key] == nil {
            cache[key] = sprite
            bytes += sprite.byteCount
        }
        touch(key)
        evict(toBytes: budgetBytes, keep: key)
        return cache[key] ?? sprite
    }

    /// The sprite of a plan `sprite` asset (its `uri`), nil when the URI is not a file URL.
    func sprite(forUri uri: String) throws -> SpriteImage? {
        guard let url = URL(string: uri), url.isFileURL else { return nil }
        return try sprite(for: url)
    }

    /// Bytes currently cached.
    var cachedBytes: Int {
        lock.lock()
        defer { lock.unlock() }
        return bytes
    }

    /// Drops sprites until at most [fraction] of the budget is held (memory warning: 0.25).
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
            if let s = cache.removeValue(forKey: key) { bytes -= s.byteCount }
        }
    }
}
