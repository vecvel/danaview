// OWNER: IOS-09
//
// `.vlut` loading into tiled LUT textures (ARCH §10.2, §11.6 "LUT", D-07).
//
// `.vlut` v1 (little-endian): 'VLUT', u16 version = 1, u16 N (2…65), then N³ RGB float16 triples, red
// fastest, input domain [0, 1]. The table is uploaded as ONE 2D image of N tiles of N×N (tile z = blue
// slice z; x = red, y = green, both top-down inside a tile) laid out in a ⌈√N⌉-column grid, at most
// 585×520 for N = 65. dv_look samples two adjacent blue slices bilinearly (hardware filtering at texel
// centres, so tiles never bleed) and mixes them linearly: the trilinear lookup of API-03 `RenderLut`.
// Half floats are uploaded as `.RGBAh` without conversion; inline float tables (tests, generated
// looks) as `.RGBAf`. No colour space: LUT values are raw gamma-encoded components.

import CoreImage
import Foundation

/// Errors of `.vlut` decoding.
struct LutFormatError: Error, CustomStringConvertible, Equatable {
    let message: String
    var description: String { "vlut: \(message)" }
}

/// A LUT ready for dv_look: the tiled image plus its geometry.
final class LutTexture {
    /// Edge length N (2…65).
    let n: Int
    /// Tile columns `⌈√N⌉`.
    let columns: Int
    /// Tile rows `⌈N / columns⌉`.
    let rows: Int
    /// The tiled image, extent `(0, 0, columns·N, rows·N)`, alpha 1.
    let image: CIImage
    /// Bytes held by [image]'s backing store.
    let byteCount: Int

    var width: Int { columns * n }
    var height: Int { rows * n }

    static let minSize = 2
    static let maxSize = 65

    /// Tile grid of an N-LUT: `(columns, rows)` = `(⌈√N⌉, ⌈N / ⌈√N⌉⌉)`.
    static func grid(_ n: Int) -> (columns: Int, rows: Int) {
        var c = Int(Double(n).squareRoot())
        if c * c < n { c += 1 }
        return (c, (n + c - 1) / c)
    }

    /// The texel (column, row from the top) holding grid entry (r, g, b).
    static func texel(_ n: Int, r: Int, g: Int, b: Int) -> (x: Int, y: Int) {
        let (cols, _) = grid(n)
        return ((b % cols) * n + r, (b / cols) * n + g)
    }

    private init(n: Int, image: CIImage, byteCount: Int) {
        self.n = n
        (columns, rows) = Self.grid(n)
        self.image = image
        self.byteCount = byteCount
    }

    /// Scatters the `n³` RGB entries (red fastest) into RGBA texels of the tile grid (alpha = [one]).
    private static func fillTiles<T>(
        n: Int, width w: Int, src: UnsafeBufferPointer<T>, dst: UnsafeMutableBufferPointer<T>, one: T
    ) {
        guard let s = src.baseAddress, let d = dst.baseAddress else { return }
        let cols = grid(n).columns
        for b in 0..<n {
            let x0 = (b % cols) * n
            let y0 = (b / cols) * n
            for g in 0..<n {
                var si = (b * n + g) * n * 3
                var o = ((y0 + g) * w + x0) * 4
                for _ in 0..<n {
                    d[o] = s[si]
                    d[o + 1] = s[si + 1]
                    d[o + 2] = s[si + 2]
                    d[o + 3] = one
                    si += 3
                    o += 4
                }
            }
        }
    }

    /// A texture from `n³ × 3` floats, red fastest (`index = ((b·N + g)·N + r)·3`).
    static func make(n: Int, rgb: [Float]) throws -> LutTexture {
        guard (minSize...maxSize).contains(n) else { throw LutFormatError(message: "size \(n) outside 2…65") }
        guard rgb.count == n * n * n * 3 else { throw LutFormatError(message: "expected \(n * n * n * 3) values, got \(rgb.count)") }
        let (cols, rows) = grid(n)
        let w = cols * n
        let h = rows * n
        var data = Data(count: w * h * 16)
        data.withUnsafeMutableBytes { raw in
            let px = raw.bindMemory(to: Float.self)
            rgb.withUnsafeBufferPointer { src in fillTiles(n: n, width: w, src: src, dst: px, one: 1) }
        }
        let image = CIImage(
            bitmapData: data, bytesPerRow: w * 16, size: CGSize(width: w, height: h), format: .RGBAf, colorSpace: nil)
        return LutTexture(n: n, image: image, byteCount: data.count)
    }

    /// A texture from `n³ × 3` float16 bit patterns, red fastest (the `.vlut` payload).
    static func make(n: Int, halfs: [UInt16]) throws -> LutTexture {
        guard (minSize...maxSize).contains(n) else { throw LutFormatError(message: "size \(n) outside 2…65") }
        guard halfs.count == n * n * n * 3 else { throw LutFormatError(message: "expected \(n * n * n * 3) values, got \(halfs.count)") }
        let (cols, rows) = grid(n)
        let w = cols * n
        let h = rows * n
        var data = Data(count: w * h * 8)
        data.withUnsafeMutableBytes { raw in
            let px = raw.bindMemory(to: UInt16.self)
            halfs.withUnsafeBufferPointer { src in fillTiles(n: n, width: w, src: src, dst: px, one: 0x3C00) }
        }
        let image = CIImage(
            bitmapData: data, bytesPerRow: w * 8, size: CGSize(width: w, height: h), format: .RGBAh, colorSpace: nil)
        return LutTexture(n: n, image: image, byteCount: data.count)
    }
}

/// A decoded `.vlut` table.
struct VlutTable: Equatable {
    let n: Int
    /// `n³ × 3` float16 bit patterns, red fastest.
    let halfs: [UInt16]

    static let headerBytes = 8

    /// Parses `.vlut` v1 bytes ([LutFormatError] when malformed; trailing bytes are rejected).
    static func decode(_ data: Data) throws -> VlutTable {
        let bytes = [UInt8](data)
        guard bytes.count >= headerBytes, bytes[0] == 0x56, bytes[1] == 0x4C, bytes[2] == 0x55, bytes[3] == 0x54 else {
            throw LutFormatError(message: "not a .vlut file")
        }
        let version = Int(bytes[4]) | Int(bytes[5]) << 8
        guard version == 1 else { throw LutFormatError(message: "unsupported version \(version)") }
        let n = Int(bytes[6]) | Int(bytes[7]) << 8
        guard (LutTexture.minSize...LutTexture.maxSize).contains(n) else {
            throw LutFormatError(message: "size \(n) outside 2…65")
        }
        let count = n * n * n * 3
        guard bytes.count == headerBytes + count * 2 else {
            throw LutFormatError(message: "expected \(headerBytes + count * 2) bytes, got \(bytes.count)")
        }
        // Little-endian payload; iOS is little-endian, so this is a straight copy.
        let halfs = [UInt16](unsafeUninitializedCapacity: count) { buf, initialized in
            bytes.withUnsafeBytes { raw in
                _ = memcpy(buf.baseAddress!, raw.baseAddress! + headerBytes, count * 2)
            }
            initialized = count
        }
        return VlutTable(n: n, halfs: halfs)
    }

    /// The table as floats (exact widening).
    var floats: [Float] { halfs.map(Half.toFloat) }
}

/// IEEE 754 binary16 conversion without `Float16` (unavailable on x86_64 simulator slices).
enum Half {
    static func toFloat(_ h: UInt16) -> Float {
        let sign: UInt32 = UInt32(h & 0x8000) << 16
        let exp = Int((h >> 10) & 0x1F)
        let mant = UInt32(h & 0x3FF)
        if exp == 0 {
            if mant == 0 { return Float(bitPattern: sign) }
            // Subnormal: mant · 2^-24.
            let v = Float(mant) * Float(sign: .plus, exponent: -24, significand: 1)
            return sign != 0 ? -v : v
        }
        if exp == 31 { return Float(bitPattern: sign | 0x7F80_0000 | (mant << 13)) }
        return Float(bitPattern: sign | UInt32(exp - 15 + 127) << 23 | (mant << 13))
    }

    /// Round-to-nearest-even float → half (finite range clamps to ±65504; tests and generators).
    static func fromFloat(_ f: Float) -> UInt16 {
        let bits = f.bitPattern
        let sign = UInt16((bits >> 16) & 0x8000)
        if f.isNaN { return sign | 0x7E00 }
        let a = abs(f)
        if a >= 65520 { return sign | 0x7BFF }
        if a < Float(sign: .plus, exponent: -25, significand: 1) { return sign }
        if a < Float(sign: .plus, exponent: -14, significand: 1) {
            let m = (a / Float(sign: .plus, exponent: -24, significand: 1)).rounded(.toNearestOrEven)
            return sign | UInt16(m)
        }
        let e = Int((a.bitPattern >> 23) & 0xFF) - 127
        let mant = a.bitPattern & 0x7F_FFFF
        var h = UInt32(e + 15) << 10 | (mant >> 13)
        let rest = mant & 0x1FFF
        if rest > 0x1000 || (rest == 0x1000 && (h & 1) == 1) { h += 1 }
        return sign | UInt16(min(h, 0x7BFF))
    }
}

/// Loads `.vlut` files into [LutTexture]s, cached by path with a small LRU (thread-safe).
final class LutStore {
    private let lock = NSLock()
    private var cache: [String: LutTexture] = [:]
    private var order: [String] = []
    /// Most textures kept (a 65-LUT is ≈ 2.4 MB as RGBAh).
    let capacity: Int

    init(capacity: Int = 8) {
        self.capacity = max(1, capacity)
    }

    /// The texture of the `.vlut` at [url] (`file://` URL), loaded on first use.
    func texture(for url: URL) throws -> LutTexture {
        let key = url.standardizedFileURL.path
        lock.lock()
        if let hit = cache[key] {
            touch(key)
            lock.unlock()
            return hit
        }
        lock.unlock()
        let table = try VlutTable.decode(try Data(contentsOf: url, options: .mappedIfSafe))
        let texture = try LutTexture.make(n: table.n, halfs: table.halfs)
        lock.lock()
        defer { lock.unlock() }
        cache[key] = texture
        touch(key)
        while order.count > capacity {
            cache.removeValue(forKey: order.removeFirst())
        }
        return texture
    }

    /// The texture of a plan `lut` asset (its `uri`), nil when the URI is not a file URL.
    func texture(forUri uri: String) throws -> LutTexture? {
        guard let url = URL(string: uri), url.isFileURL else { return nil }
        return try texture(for: url)
    }

    /// Number of cached textures.
    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return cache.count
    }

    /// Drops cached textures down to [fraction] of the capacity (memory warning: 0.25).
    func trim(to fraction: Double = 0) {
        lock.lock()
        defer { lock.unlock() }
        let keep = Int((Double(capacity) * fraction).rounded(.down))
        while order.count > keep {
            cache.removeValue(forKey: order.removeFirst())
        }
    }

    private func touch(_ key: String) {
        order.removeAll { $0 == key }
        order.append(key)
    }
}
