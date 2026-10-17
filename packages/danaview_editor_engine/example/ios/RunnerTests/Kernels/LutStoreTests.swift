// OWNER: IOS-09
//
// LutStore / LutTexture (ARCH §10.2, D-07): `.vlut` of size 2, 33 and 65 load into tiled textures
// (N tiles of N×N in a ⌈√N⌉ grid, ≤ 585×520 for N = 65) and dv_look's trilinear lookup matches the
// CPU reference (API-03 RenderLut) within the ARCH §11.6 tolerance; malformed files are rejected.

import CoreImage
import XCTest

@testable import danaview_editor_engine

final class LutStoreTests: XCTestCase {
    /// A non-trivial grade so a wrong tile/axis order shows (warm/teal-ish, smooth).
    private static func grade(_ r: Double, _ g: Double, _ b: Double) -> (Double, Double, Double) {
        (min(1, 0.9 * r + 0.1 * g * g + 0.05), 0.8 * g + 0.15 * b, max(0, b * b * 0.9 + 0.05 * r))
    }

    func testTileGrid() {
        XCTAssertTrue(LutTexture.grid(2) == (2, 1))
        XCTAssertTrue(LutTexture.grid(17) == (5, 4))
        XCTAssertTrue(LutTexture.grid(33) == (6, 6))
        XCTAssertTrue(LutTexture.grid(65) == (9, 8))
        XCTAssertTrue(LutTexture.texel(65, r: 3, g: 4, b: 10) == (1 * 65 + 3, 1 * 65 + 4))
    }

    func testVlutSizes2_33_65LoadAndLookUpTrilinearly() throws {
        let k = try KernelTestSupport.kernels()
        let dir = try KernelTestSupport.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = LutStore()
        let gpu = Kernels.makeContext()
        let sw = Kernels.makeContext(software: true)
        // 8×8 inputs spread over the cube, incl. 0 and 1 on every axis.
        let inputs: [[Double]] = (0..<64).map { i -> [Double] in
            let x = Double(i % 8) / 7
            let y = Double(i / 8) / 7
            return [x, y, (x + y) / 2, 1]
        }
        for n in [2, 33, 65] {
            let rgb = KernelTestSupport.table(n: n, Self.grade)
            let url = dir.appendingPathComponent("grade_\(n).vlut")
            try KernelTestSupport.vlut(n: n, rgb: rgb).write(to: url)
            let t0 = CFAbsoluteTimeGetCurrent()
            let texture = try store.texture(for: url)
            let loadMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000
            XCTAssertEqual(texture.n, n)
            XCTAssertEqual(texture.image.extent, CGRect(x: 0, y: 0, width: texture.width, height: texture.height))
            if n == 65 {
                XCTAssertEqual(texture.width, 585)
                XCTAssertEqual(texture.height, 520)
            }
            XCTAssertTrue(try store.texture(for: url) === texture, "cached")
            // The table as stored (float16) is the reference.
            let stored = try VlutTable.decode(try Data(contentsOf: url)).floats
            for i in [0.0, 0.6, 1.0] {
                let want = inputs.map { c -> [Double] in
                    let l: [Double] = KernelTestSupport.trilinear(n: n, rgb: stored, c)
                    var o: [Double] = [1, 1, 1, 1]
                    for ch in 0..<3 { o[ch] = c[ch] + (l[ch] - c[ch]) * i }
                    return o
                }
                let image = KernelTestSupport.image(inputs, w: 8, h: 8)
                let out = k.look(image, .init(lut: texture, lutIntensity: i), forceKernel: true)
                for (label, ctx) in [("gpu", gpu), ("software", sw)] {
                    let e = KernelTestSupport.errors(KernelTestSupport.render(out, context: ctx, w: 8, h: 8), want)
                    XCTAssertLessThanOrEqual(e.mean, KernelTestSupport.meanTolerance, "n \(n) i \(i) \(label)")
                    XCTAssertLessThanOrEqual(e.p99, KernelTestSupport.p99Tolerance, "n \(n) i \(i) \(label)")
                }
            }
            print("IOS-09 LUT n=\(n): \(texture.width)x\(texture.height), load \(String(format: "%.2f", loadMs)) ms")
        }
        XCTAssertEqual(store.count, 3)
        store.trim(to: 0)
        XCTAssertEqual(store.count, 0)
    }

    func testIdentityLutIsIdentity() throws {
        let k = try KernelTestSupport.kernels()
        let n = 33
        let lut = try LutTexture.make(n: n, rgb: KernelTestSupport.table(n: n) { ($0, $1, $2) })
        let inputs: [[Double]] = (0..<64).map { i -> [Double] in
            let x = Double(i) / 63
            let z = Double(i % 7) / 6
            return [x, 1 - x, z, 1]
        }
        let got = KernelTestSupport.render(
            k.look(KernelTestSupport.image(inputs, w: 8, h: 8), .init(lut: lut)), context: Kernels.makeContext(), w: 8, h: 8)
        let e = KernelTestSupport.errors(got, inputs)
        XCTAssertLessThanOrEqual(e.mean, KernelTestSupport.meanTolerance)
        XCTAssertLessThanOrEqual(e.p99, KernelTestSupport.p99Tolerance)
    }

    func testBuiltInFixtureLutDecodes() throws {
        let url = try XCTUnwrap(TestFixtures.url(.engineApi, "vectors/luts/synthetic_17.vlut"))
        let table = try VlutTable.decode(try Data(contentsOf: url))
        XCTAssertEqual(table.n, 17)
        XCTAssertEqual(table.halfs.count, 17 * 17 * 17 * 3)
        XCTAssertTrue(table.floats.allSatisfy { $0.isFinite })
    }

    func testMalformedVlutIsRejected() {
        let good = KernelTestSupport.vlut(n: 2, rgb: KernelTestSupport.table(n: 2) { ($0, $1, $2) })
        XCTAssertNoThrow(try VlutTable.decode(good))
        var badMagic = good
        badMagic[0] = 0x58
        XCTAssertThrowsError(try VlutTable.decode(badMagic))
        var badVersion = good
        badVersion[4] = 2
        XCTAssertThrowsError(try VlutTable.decode(badVersion))
        XCTAssertThrowsError(try VlutTable.decode(good.dropLast(2)))
        XCTAssertThrowsError(try VlutTable.decode(good + Data([0, 0])))
        XCTAssertThrowsError(try VlutTable.decode(Data([0x56, 0x4C, 0x55, 0x54, 1, 0, 66, 0])), "N = 66")
        XCTAssertThrowsError(try VlutTable.decode(Data([0x56, 0x4C, 0x55, 0x54, 1, 0, 1, 0])), "N = 1")
        XCTAssertThrowsError(try LutTexture.make(n: 3, rgb: [0, 0, 0]))
    }

    func testHalfConversionRoundTrips() {
        for v: Float in [0, 1, -1, 0.5, 0.25, 0.1, 0.333, 65504, 6.1e-5, 1e-7, 2.5] {
            let back = Half.toFloat(Half.fromFloat(v))
            XCTAssertEqual(back, v, accuracy: max(abs(v) / 1024, 6e-8), "\(v)")
        }
        XCTAssertEqual(Half.toFloat(0x3C00), 1)
        XCTAssertEqual(Half.toFloat(0xC000), -2)
        XCTAssertEqual(Half.toFloat(0x0001), Float(sign: .plus, exponent: -24, significand: 1))
        XCTAssertEqual(Half.fromFloat(1), 0x3C00)
    }
}
