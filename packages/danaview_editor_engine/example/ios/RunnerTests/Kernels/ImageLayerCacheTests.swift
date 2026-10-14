// OWNER: IOS-09
//
// ImageLayerCache: images decode at render scale (never upscaled), display-oriented, with their encoded
// values (no colour management); solids are premultiplied from the plan's straight ARGB; LRU and trim.

import CoreImage
import ImageIO
import UniformTypeIdentifiers
import XCTest

@testable import danaview_editor_engine

final class ImageLayerCacheTests: XCTestCase {
    /// Writes a w×h PNG: left half (200, 100, 50), right half (20, 40, 220), sRGB-tagged.
    private func writePng(_ url: URL, w: Int, h: Int, orientation: Int = 1, type: UTType = .png) throws {
        var px = [UInt8](repeating: 255, count: w * h * 4)
        for y in 0..<h {
            for x in 0..<w {
                let o = (y * w + x) * 4
                let c: [UInt8] = x < w / 2 ? [200, 100, 50] : [20, 40, 220]
                px[o] = c[0]
                px[o + 1] = c[1]
                px[o + 2] = c[2]
            }
        }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(px) as CFData))
        let cg = try XCTUnwrap(
            CGImage(
                width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, cg, [kCGImagePropertyOrientation: orientation] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
    }

    private func pixel(_ image: CIImage, _ x: Int, _ yTop: Int, context: CIContext) -> [UInt8] {
        var px = [UInt8](repeating: 0, count: 4)
        let e = image.extent
        context.render(
            image, toBitmap: &px, rowBytes: 4, bounds: CGRect(x: e.minX + CGFloat(x), y: e.maxY - CGFloat(yTop) - 1, width: 1, height: 1),
            format: .RGBA8, colorSpace: nil)
        return px
    }

    func testImagesDecodeAtRenderScaleWithEncodedValues() throws {
        let dir = try KernelTestSupport.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("a.png")
        try writePng(url, w: 64, h: 32)
        let cache = ImageLayerCache()
        let context = Kernels.makeContext()

        let full = try cache.image(for: url, maxLongSide: 0)
        XCTAssertEqual(full.extent, CGRect(x: 0, y: 0, width: 64, height: 32))
        XCTAssertEqual(pixel(full, 4, 4, context: context), [200, 100, 50, 255], "encoded values, no colour conversion")
        XCTAssertEqual(pixel(full, 60, 28, context: context), [20, 40, 220, 255])

        let half = try cache.image(for: url, maxLongSide: 32)
        XCTAssertEqual(half.extent, CGRect(x: 0, y: 0, width: 32, height: 16))
        XCTAssertEqual(pixel(half, 2, 2, context: context), [200, 100, 50, 255])
        let upscaled = try cache.image(for: url, maxLongSide: 4096)
        XCTAssertEqual(upscaled.extent.size, CGSize(width: 64, height: 32), "never upscaled")

        XCTAssertTrue(try cache.image(for: url, maxLongSide: 32) === half, "cached")
        XCTAssertEqual(cache.count, 3)
        XCTAssertGreaterThan(cache.cachedBytes, 0)
        cache.trim(to: 0)
        XCTAssertEqual(cache.count, 0)
        XCTAssertEqual(cache.cachedBytes, 0)
        XCTAssertThrowsError(try cache.image(for: dir.appendingPathComponent("missing.png"), maxLongSide: 0))
    }

    func testExifOrientationIsApplied() throws {
        let dir = try KernelTestSupport.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("rot.tiff")
        try writePng(url, w: 64, h: 32, orientation: 6, type: .tiff)  // 90° cw display
        let image = try ImageLayerCache().image(for: url, maxLongSide: 0)
        XCTAssertEqual(image.extent.size, CGSize(width: 32, height: 64), "display-oriented size")
    }

    func testLruBudgetEvictsOldest() throws {
        let dir = try KernelTestSupport.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = ImageLayerCache(budgetBytes: 64 * 32 * 4 + 1)
        for i in 0..<3 {
            let url = dir.appendingPathComponent("\(i).png")
            try writePng(url, w: 64, h: 32)
            _ = try cache.image(for: url, maxLongSide: 0)
        }
        XCTAssertEqual(cache.count, 1, "only the newest fits the budget")
    }

    func testSolidIsPremultipliedPlanColour() throws {
        let context = Kernels.makeContext()
        let solid = ImageLayerCache.solid(argb: 0x80FF_4020, width: 10, height: 6)
        XCTAssertEqual(solid.extent, CGRect(x: 0, y: 0, width: 10, height: 6))
        let got = KernelTestSupport.render(solid, context: context, w: 10, h: 6)
        let a = 128.0 / 255
        let want = [1 * a, 64.0 / 255 * a, 32.0 / 255 * a, a]
        let e = KernelTestSupport.errors(got, Array(repeating: want, count: 60))
        XCTAssertLessThanOrEqual(e.p99, 1.0 / 255)
    }
}
