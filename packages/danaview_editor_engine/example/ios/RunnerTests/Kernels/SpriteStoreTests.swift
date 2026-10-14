// OWNER: IOS-09
//
// SpriteStore / VspriteDecoder (ARCH §10.3, D-06): every API-04 fixture
// (packages/danaview_editor_engine_api/test_fixtures/sprites/) decodes with the size, scale, reveal flag,
// Adler-32 checksums and sample pixels of sprites.json; the CIImage form keeps the premultiplied bytes;
// dv_reveal hides glyphs ≥ shown; malformed files are rejected.

import CoreImage
import XCTest

@testable import danaview_editor_engine

final class SpriteStoreTests: XCTestCase {
    private func manifest() throws -> [[String: Any]] {
        let url = try XCTUnwrap(TestFixtures.url(.engineApi, "sprites/sprites.json"))
        let doc = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        return try XCTUnwrap(doc["sprites"] as? [[String: Any]])
    }

    private func fixtureURL(_ name: String) throws -> URL {
        try XCTUnwrap(TestFixtures.url(.engineApi, "sprites/\(name)"), "\(name) missing")
    }

    func testApi04FixturesDecode() throws {
        let entries = try manifest()
        XCTAssertGreaterThanOrEqual(entries.count, 4)
        let store = SpriteStore()
        let context = Kernels.makeContext()
        for e in entries {
            let file = try XCTUnwrap(e["file"] as? String)
            let t0 = CFAbsoluteTimeGetCurrent()
            let sprite = try store.sprite(for: try fixtureURL(file))
            let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000
            XCTAssertEqual(sprite.width, (e["width"] as? NSNumber)?.intValue, file)
            XCTAssertEqual(sprite.height, (e["height"] as? NSNumber)?.intValue, file)
            XCTAssertEqual(Double(sprite.scale), (e["scale"] as? NSNumber)?.doubleValue ?? -1, accuracy: 1e-6, file)
            XCTAssertEqual(sprite.hasReveal, e["reveal"] as? Bool, file)
            XCTAssertEqual(KernelTestSupport.adler32([UInt8](sprite.rgba)), (e["rgbaAdler32"] as? NSNumber)?.uint32Value, file)
            if let glyphs = sprite.glyphs {
                let le = glyphs.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] }
                XCTAssertEqual(KernelTestSupport.adler32(le), (e["glyphsAdler32"] as? NSNumber)?.uint32Value, file)
            }
            // Sample pixels, from the decoded bytes and through Core Image (premultiplied, unchanged).
            let rendered = renderBytes(sprite.image, context: context, w: sprite.width, h: sprite.height)
            for s in try XCTUnwrap(e["samples"] as? [[String: Any]]) {
                let x = (s["x"] as? NSNumber)?.intValue ?? -1
                let y = (s["y"] as? NSNumber)?.intValue ?? -1
                let want = ((s["rgba"] as? [NSNumber]) ?? []).map(\.uint8Value)
                XCTAssertEqual(sprite.pixel(x: x, y: y), want, "\(file) (\(x), \(y))")
                let o = (y * sprite.width + x) * 4
                XCTAssertEqual(Array(rendered[o..<(o + 4)]), want, "\(file) (\(x), \(y)) through Core Image")
                if let g = s["glyph"] as? NSNumber {
                    XCTAssertEqual(sprite.glyphs?[y * sprite.width + x], g.uint16Value, "\(file) glyph (\(x), \(y))")
                }
            }
            print("IOS-09 sprite \(file): \(sprite.width)x\(sprite.height) decoded in \(String(format: "%.2f", ms)) ms")
        }
        XCTAssertGreaterThan(store.cachedBytes, 0)
        store.trim(to: 0)
        XCTAssertEqual(store.cachedBytes, 0)
    }

    /// dv_reveal on the glyph-map fixture: with `shown` glyphs, texels of glyph ≥ shown (and the
    /// background) are transparent and the rest keep their bytes.
    func testRevealFixtureThroughKernel() throws {
        let k = try KernelTestSupport.kernels()
        let sprite = try VspriteDecoder.decode(try Data(contentsOf: try fixtureURL("synthetic_reveal_16x8.vsprite")))
        let glyphs = try XCTUnwrap(sprite.glyphs)
        let context = Kernels.makeContext()
        for shown in [0, 1, 2, 4] {
            let out = renderBytes(k.reveal(sprite.image, glyphs: sprite.glyphImage, shown: shown), context: context, w: sprite.width, h: sprite.height)
            var mismatches = 0
            for i in 0..<(sprite.width * sprite.height) {
                let drawn = Int(glyphs[i]) < shown
                let want: [UInt8] = drawn ? sprite.pixel(x: i % sprite.width, y: i / sprite.width) : [0, 0, 0, 0]
                if Array(out[(i * 4)..<(i * 4 + 4)]) != want { mismatches += 1 }
            }
            XCTAssertEqual(mismatches, 0, "shown \(shown)")
        }
        // Not animated: everything drawn (no kernel).
        XCTAssertTrue(k.reveal(sprite.image, glyphs: sprite.glyphImage, shown: nil) === sprite.image)
    }

    func testMalformedSpritesAreRejected() throws {
        let good = try Data(contentsOf: try fixtureURL("synthetic_reveal_16x8.vsprite"))
        XCTAssertNoThrow(try VspriteDecoder.decode(good))
        XCTAssertThrowsError(try VspriteDecoder.decode(good.prefix(10)), "truncated header")
        var magic = good
        magic[0] = 0x58
        XCTAssertThrowsError(try VspriteDecoder.decode(magic), "magic")
        var version = good
        version[4] = 2
        XCTAssertThrowsError(try VspriteDecoder.decode(version), "version")
        var flags = good
        flags[6] = 3
        XCTAssertThrowsError(try VspriteDecoder.decode(flags), "unknown flag")
        XCTAssertThrowsError(try VspriteDecoder.decode(good + Data([0])), "trailing byte")
        XCTAssertThrowsError(try VspriteDecoder.decode(good.dropLast(3)), "truncated second stream")
        var corrupt = good
        corrupt[VspriteDecoder.headerBytes + 4] ^= 0xFF
        XCTAssertThrowsError(try VspriteDecoder.decode(corrupt), "corrupt stream")
        // A header claiming a side above maxTextureSize.
        let plain = try Data(contentsOf: try fixtureURL("synthetic_plain_8x4.vsprite"))
        XCTAssertThrowsError(try VspriteDecoder.decode(plain, maxSide: 4), "side > maxTextureSize")
        var big = plain
        big[8] = 0x01
        big[9] = 0x40  // w = 16385
        XCTAssertThrowsError(try VspriteDecoder.decode(big))
    }

    private func renderBytes(_ image: CIImage, context: CIContext, w: Int, h: Int) -> [UInt8] {
        var px = [UInt8](repeating: 0, count: w * h * 4)
        context.render(image, toBitmap: &px, rowBytes: w * 4, bounds: CGRect(x: 0, y: 0, width: w, height: h), format: .RGBA8, colorSpace: nil)
        return px
    }
}
