// OWNER: IOS-09
//
// Helpers for the IOS-09 kernel tests: float RGBA images in and out of Core Image (row 0 = top, the
// vectors' row-major order), the ARCH §11.6 parity tolerance, Adler-32 and .vlut writing.

import CoreImage
import XCTest

@testable import danaview_editor_engine

enum KernelTestSupport {
    /// ARCH §11.6 parity tolerance: mean |Δ| ≤ 1.5/255 per channel, 99th percentile ≤ 6/255.
    static let meanTolerance = 1.5 / 255
    static let p99Tolerance = 6.0 / 255

    static func kernels() throws -> Kernels {
        do { return try Kernels.shared() } catch { XCTFail("kernels failed to load: \(error)"); throw error }
    }

    /// A premultiplied `.RGBAf` image of `w × h` texels (row-major, top row first).
    static func image(_ texels: [[Double]], w: Int, h: Int) -> CIImage {
        precondition(texels.count == w * h)
        var px = [Float]()
        px.reserveCapacity(w * h * 4)
        for t in texels { px.append(contentsOf: t.map(Float.init)) }
        let data = px.withUnsafeBufferPointer { Data(buffer: $0) }
        return CIImage(bitmapData: data, bytesPerRow: w * 16, size: CGSize(width: w, height: h), format: .RGBAf, colorSpace: nil)
    }

    /// Renders `(0, 0, w, h)` of [image] to premultiplied floats (row-major, top row first).
    static func render(_ image: CIImage, context: CIContext, w: Int, h: Int) -> [[Double]] {
        var px = [Float](repeating: 0, count: w * h * 4)
        context.render(image, toBitmap: &px, rowBytes: w * 16, bounds: CGRect(x: 0, y: 0, width: w, height: h), format: .RGBAf, colorSpace: nil)
        return (0..<(w * h)).map { i in (0..<4).map { Double(px[i * 4 + $0]) } }
    }

    static func premultiply(_ c: [Double]) -> [Double] { [c[0] * c[3], c[1] * c[3], c[2] * c[3], c[3]] }

    static func clamp01(_ v: Double) -> Double { min(1, max(0, v)) }

    /// Per-channel mean and 99th-percentile absolute error over the texels where [include] is true.
    static func errors(_ got: [[Double]], _ want: [[Double]], include: (Int) -> Bool = { _ in true }) -> (mean: Double, p99: Double, count: Int) {
        var diffs: [Double] = []
        var sums = [Double](repeating: 0, count: 4)
        var n = 0
        for i in 0..<min(got.count, want.count) where include(i) {
            n += 1
            for c in 0..<4 {
                let d = abs(got[i][c] - want[i][c])
                diffs.append(d)
                sums[c] += d
            }
        }
        guard n > 0 else { return (0, 0, 0) }
        diffs.sort()
        let p99 = diffs[min(diffs.count - 1, Int((Double(diffs.count) * 0.99).rounded(.up)) - 1)]
        return (sums.map { $0 / Double(n) }.max() ?? 0, p99, n)
    }

    static func adler32(_ bytes: [UInt8]) -> UInt32 {
        var a: UInt32 = 1
        var b: UInt32 = 0
        for x in bytes {
            a = (a + UInt32(x)) % 65521
            b = (b + a) % 65521
        }
        return b << 16 | a
    }

    /// `.vlut` v1 bytes of [rgb] (`n³ × 3` floats, red fastest).
    static func vlut(n: Int, rgb: [Float]) -> Data {
        var out: [UInt8] = [0x56, 0x4C, 0x55, 0x54, 1, 0, UInt8(n & 0xFF), UInt8(n >> 8)]
        for v in rgb {
            let h = Half.fromFloat(v)
            out.append(UInt8(h & 0xFF))
            out.append(UInt8(h >> 8))
        }
        return Data(out)
    }

    /// `n³ × 3` floats of `f` at the grid points, red fastest.
    static func table(n: Int, _ f: (Double, Double, Double) -> (Double, Double, Double)) -> [Float] {
        var out: [Float] = []
        out.reserveCapacity(n * n * n * 3)
        let d = Double(n - 1)
        for b in 0..<n {
            for g in 0..<n {
                for r in 0..<n {
                    let (x, y, z) = f(Double(r) / d, Double(g) / d, Double(b) / d)
                    out.append(Float(x))
                    out.append(Float(y))
                    out.append(Float(z))
                }
            }
        }
        return out
    }

    /// CPU trilinear lookup (API-03 `RenderLut.lookup`).
    static func trilinear(n: Int, rgb: [Float], _ c: [Double]) -> [Double] {
        let n1 = n - 1
        func cl(_ v: Double) -> Double { min(1, max(0, v)) }
        let x = cl(c[0]) * Double(n1), y = cl(c[1]) * Double(n1), z = cl(c[2]) * Double(n1)
        let x0 = min(Int(x.rounded(.down)), n1 - 1), y0 = min(Int(y.rounded(.down)), n1 - 1), z0 = min(Int(z.rounded(.down)), n1 - 1)
        let fx = x - Double(x0), fy = y - Double(y0), fz = z - Double(z0)
        var out = [0.0, 0.0, 0.0]
        for ch in 0..<3 {
            func at(_ i: Int, _ j: Int, _ k: Int) -> Double { Double(rgb[(((z0 + k) * n + (y0 + j)) * n + (x0 + i)) * 3 + ch]) }
            let c00 = at(0, 0, 0) * (1 - fx) + at(1, 0, 0) * fx
            let c10 = at(0, 1, 0) * (1 - fx) + at(1, 1, 0) * fx
            let c01 = at(0, 0, 1) * (1 - fx) + at(1, 0, 1) * fx
            let c11 = at(0, 1, 1) * (1 - fx) + at(1, 1, 1) * fx
            out[ch] = (c00 * (1 - fy) + c10 * fy) * (1 - fz) + (c01 * (1 - fy) + c11 * fy) * fz
        }
        return out
    }

    static func scratchDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ios09-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
