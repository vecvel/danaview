// OWNER: IOS-09
//
// API-03 render-math vectors (packages/danaview_editor_engine_api/test_fixtures/vectors/render_math.json)
// through the IOS-09 Core Image kernels on 8×8 images, on the simulator GPU (Metal CIContext) and on a
// software CIContext, within the ARCH §11.6 parity tolerance (mean |Δ| ≤ 1.5/255 per channel, 99th
// percentile ≤ 6/255; transform fixtures exclude edge pixels).
//
// Comparison is in premultiplied space (what Core Image produces). Rows given in straight alpha are
// premultiplied on the way in and out. Single grade steps that the vectors leave unclamped
// (brightness/contrast, highlights/shadows, saturation) are compared after clamping to [0, 1]: the
// kernel runs the whole grade, which ends with the clamp of the temperature/tint step (§11.6).

import CoreImage
import XCTest

@testable import danaview_editor_engine

final class RenderMathVectorTests: XCTestCase {
    private struct Row {
        let stage: String
        let name: String
        let straight: Bool
        let params: [String: Any]
        let w: Int
        let h: Int
        let input: [[Double]]
        let output: [[Double]]
    }

    private static func nums(_ v: Any?) -> [Double] { (v as? [NSNumber])?.map(\.doubleValue) ?? [] }
    private static func dbl(_ v: Any?, _ d: Double = 0) -> Double { (v as? NSNumber)?.doubleValue ?? d }

    private func loadDoc() throws -> [String: Any] {
        let url = try XCTUnwrap(TestFixtures.url(.engineApi, "vectors/render_math.json"), "render_math.json missing")
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    private func rows(_ doc: [String: Any]) throws -> [Row] {
        let raw = try XCTUnwrap(doc["rows"] as? [[String: Any]])
        return raw.map { r in
            let w = Int(Self.dbl(r["w"], 8))
            let h = Int(Self.dbl(r["h"], 8))
            func texels(_ uniform: String, _ image: String) -> [[Double]] {
                if let img = r[image] as? [[NSNumber]] { return img.map { $0.map(\.doubleValue) } }
                return Array(repeating: Self.nums(r[uniform]), count: w * h)
            }
            return Row(
                stage: r["stage"] as? String ?? "?", name: r["name"] as? String ?? "?",
                straight: (r["space"] as? String) == "straight", params: r["params"] as? [String: Any] ?? [:], w: w, h: h,
                input: texels("in", "inImage"), output: texels("out", "outImage"))
        }
    }

    /// The LUT tables of the vectors file (inline floats or `.vlut` files under vectors/).
    private func luts(_ doc: [String: Any]) throws -> [String: (n: Int, rgb: [Float], texture: LutTexture)] {
        var out: [String: (Int, [Float], LutTexture)] = [:]
        for (name, value) in try XCTUnwrap(doc["luts"] as? [String: [String: Any]]) {
            if let file = value["file"] as? String {
                let url = try XCTUnwrap(TestFixtures.url(.engineApi, "vectors/\(file)"), "\(file) missing")
                let table = try VlutTable.decode(try Data(contentsOf: url))
                out[name] = (table.n, table.floats, try LutStore().texture(for: url))
            } else {
                let n = Int(Self.dbl(value["n"]))
                let rgb = Self.nums(value["rgb"]).map(Float.init)
                out[name] = (n, rgb, try LutTexture.make(n: n, rgb: rgb))
            }
        }
        return out
    }

    private func plmask(_ m: [String: Any]) -> PlanMask {
        PlanMask(
            shape: (m["shape"] as? String) == "ellipse" ? .ellipse : .rect, cx: Self.dbl(m["cx"], 0.5),
            cy: Self.dbl(m["cy"], 0.5), w: Self.dbl(m["w"], 1), h: Self.dbl(m["h"], 1), r: Self.dbl(m["r"]),
            corner: Self.dbl(m["corner"]), feather: Self.dbl(m["feather"]), op: Self.dbl(m["op"], 1),
            inv: (m["inv"] as? Bool) ?? false)
    }

    private static func hex(_ s: String) -> UInt32 { UInt32(s.dropFirst(), radix: 16) ?? 0 }

    /// Runs one row's stage; nil for an unknown stage.
    private func apply(_ row: Row, _ k: Kernels, luts: [String: (n: Int, rgb: [Float], texture: LutTexture)]) -> CIImage? {
        let input = KernelTestSupport.image(row.straight ? row.input.map(KernelTestSupport.premultiply) : row.input, w: row.w, h: row.h)
        let p = row.params
        var adjust = [Double](repeating: 0, count: 8)
        func set(_ name: String, _ v: Any?) { if let i = PlanAdjust.names.firstIndex(of: name) { adjust[i] = Self.dbl(v) } }
        switch row.stage {
        case "chromaKey":
            let chroma = PlanChroma(
                key: Self.hex(p["key"] as? String ?? "#000000"), sim: Self.dbl(p["sim"]), smooth: Self.dbl(p["smooth"]),
                spill: Self.dbl(p["spill"]))
            return k.look(input, .init(chroma: chroma), forceKernel: true)
        case "exposure", "brightnessContrast", "highlightsShadows", "saturation", "temperatureTint":
            for (key, v) in p { set(key, v) }
            return k.look(input, .init(adjust: adjust), forceKernel: true)
        case "grade":
            for (key, v) in (p["adj"] as? [String: Any] ?? [:]) { set(key, v) }
            return k.look(input, .init(adjust: adjust), forceKernel: true)
        case "lut":
            guard let lut = luts[p["lut"] as? String ?? ""] else { return nil }
            return k.look(input, .init(lut: lut.texture, lutIntensity: Self.dbl(p["i"], 1)), forceKernel: true)
        case "gaussianBlur":
            return k.blur(input, sigma: Self.dbl(p["sigma"]))
        case "sharpen":
            return k.sharpen(input, amount: Self.dbl(p["amount"]))
        case "vignette":
            return k.vignetteMask(input, vignette: Self.dbl(p["amount"]), aspect: Self.dbl(p["aspect"], 1), mask: nil, base: PlanSize(w: 8, h: 8))
        case "mask":
            let base = Self.nums(p["base"])
            return k.vignetteMask(
                input, vignette: 0, aspect: 1, mask: plmask(p["mask"] as? [String: Any] ?? [:]), base: PlanSize(w: base[0], h: base[1]))
        case "canvasMask":
            let m = p["cmask"] as? [String: Any] ?? [:]
            let cm = CanvasMask(
                cx: Self.dbl(m["cx"]), cy: Self.dbl(m["cy"]), w: Self.dbl(m["w"]), h: Self.dbl(m["h"]), r: Self.dbl(m["r"]),
                feather: Self.dbl(m["feather"]), inv: (m["inv"] as? Bool) ?? false)
            return k.canvasMask(input, cm, canvasHeight: Double(row.h), renderScale: 1)
        case "place":
            let m = Self.nums(p["M"])
            let base = Self.nums(p["base"])
            let xf = p["xf"] as? [String: Any] ?? [:]
            let placed = k.place(
                input, m: CGAffineTransform(a: m[0], b: m[1], c: m[2], d: m[3], tx: m[4], ty: m[5]), base: PlanSize(w: base[0], h: base[1]),
                opacity: Self.dbl(xf["op"], 1), canvasHeight: Double(row.h), renderScale: 1)
            return Kernels.composite(placed, over: CIImage(color: .clear)).cropped(to: CGRect(x: 0, y: 0, width: row.w, height: row.h))
        case "composite":
            let dst = Self.nums(p["dst"])
            let bottom = KernelTestSupport.image(Array(repeating: dst, count: row.w * row.h), w: row.w, h: row.h)
            return Kernels.composite(input, over: bottom)
        case "spriteReveal":
            let glyphs = (p["glyphs"] as? [NSNumber])?.map(\.intValue) ?? []
            let packed = glyphs.map { g -> [Double] in [Double(g & 0xFF) / 255, Double(g >> 8) / 255, 0, 1] }
            let shown = (p["reveal"] as? NSNumber).map { Int($0.doubleValue.rounded(.down)) }
            return k.reveal(input, glyphs: KernelTestSupport.image(packed, w: row.w, h: row.h), shown: shown)
        default:
            return nil
        }
    }

    /// Expected premultiplied texels.
    private func expected(_ row: Row) -> [[Double]] {
        let clampRgb = ["brightnessContrast", "highlightsShadows", "saturation", "exposure", "lut"].contains(row.stage)
        return row.output.map { t in
            var c = t
            if clampRgb { c = [KernelTestSupport.clamp01(c[0]), KernelTestSupport.clamp01(c[1]), KernelTestSupport.clamp01(c[2]), c[3]] }
            return row.straight ? KernelTestSupport.premultiply(c) : c
        }
    }

    /// Edge texels of a transform fixture: any 3×3 neighbour with a different expected alpha.
    private func interior(_ want: [[Double]], w: Int, h: Int) -> (Int) -> Bool {
        { i in
            let x = i % w, y = i / w
            let a = want[i][3]
            for dy in -1...1 {
                for dx in -1...1 {
                    let xx = x + dx, yy = y + dy
                    guard xx >= 0, yy >= 0, xx < w, yy < h else { continue }
                    if abs(want[yy * w + xx][3] - a) > 1e-6 { return false }
                }
            }
            return true
        }
    }

    private func runAllRows(software: Bool) throws {
        let k = try KernelTestSupport.kernels()
        let doc = try loadDoc()
        let all = try rows(doc)
        let tables = try luts(doc)
        let context = Kernels.makeContext(software: software)
        XCTAssertGreaterThanOrEqual(all.count, 150)
        var failures: [String] = []
        var stages: [String: Int] = [:]
        var worst = (mean: 0.0, p99: 0.0, name: "")
        for row in all {
            guard let out = apply(row, k, luts: tables) else {
                failures.append("\(row.stage)/\(row.name): stage not implemented")
                continue
            }
            let got = KernelTestSupport.render(out, context: context, w: row.w, h: row.h)
            let want = expected(row)
            let include = row.stage == "place" ? interior(want, w: row.w, h: row.h) : { _ in true }
            let e = KernelTestSupport.errors(got, want, include: include)
            stages[row.stage, default: 0] += 1
            if e.mean > worst.mean { worst = (e.mean, max(worst.p99, e.p99), row.name) }
            if e.mean > KernelTestSupport.meanTolerance || e.p99 > KernelTestSupport.p99Tolerance || e.count == 0 {
                let firstBad = (0..<min(got.count, want.count)).first { i in (0..<4).contains { abs(got[i][$0] - want[i][$0]) > KernelTestSupport.p99Tolerance } }
                let detail = firstBad.map { " texel \($0): got \(got[$0].map { ($0 * 1000).rounded() / 1000 }) want \(want[$0].map { ($0 * 1000).rounded() / 1000 })" } ?? ""
                failures.append(
                    "\(row.stage)/\(row.name): mean \(String(format: "%.2f", e.mean * 255))/255 p99 \(String(format: "%.2f", e.p99 * 255))/255 over \(e.count)\(detail)")
            }
        }
        let label = software ? "software" : "gpu"
        print("IOS-09 render_math \(label): \(all.count) rows, stages \(stages.sorted { $0.key < $1.key }), worst mean \(String(format: "%.3f", worst.mean * 255))/255 (\(worst.name))")
        XCTAssertEqual(failures, [], "\(label) context")
        XCTAssertEqual(Set(stages.keys).count, 16, "every render-math stage is exercised: \(stages.keys.sorted())")
    }

    func testRenderMathVectorsOnSimulatorGpu() throws {
        try runAllRows(software: false)
    }

    func testRenderMathVectorsOnSoftwareContext() throws {
        try runAllRows(software: true)
    }

    /// The chroma matte preview (dv_matte) shows the key alpha of every chroma row as opaque grey.
    func testChromaMatteShowsKeyAlpha() throws {
        let k = try KernelTestSupport.kernels()
        let context = Kernels.makeContext()
        for row in try rows(try loadDoc()) where row.stage == "chromaKey" {
            let chroma = PlanChroma(
                key: Self.hex(row.params["key"] as? String ?? ""), sim: Self.dbl(row.params["sim"]), smooth: Self.dbl(row.params["smooth"]),
                spill: Self.dbl(row.params["spill"]))
            let input = KernelTestSupport.image(row.input.map(KernelTestSupport.premultiply), w: row.w, h: row.h)
            let got = KernelTestSupport.render(k.matte(k.look(input, .init(chroma: chroma))), context: context, w: row.w, h: row.h)
            let a = row.output[0][3]
            let e = KernelTestSupport.errors(got, Array(repeating: [a, a, a, 1], count: row.w * row.h))
            XCTAssertLessThanOrEqual(e.p99, KernelTestSupport.p99Tolerance, row.name)
        }
    }

    /// Scalar blur-σ conversions of the vectors (canvas → source px and render px, radii, skip flags).
    func testBlurSigmaScalars() throws {
        let scalars = try XCTUnwrap(try loadDoc()["scalars"] as? [String: Any])
        let cases = try XCTUnwrap(scalars["blurSigma"] as? [[String: Any]])
        XCTAssertFalse(cases.isEmpty)
        for c in cases {
            let canvas = Self.nums(c["canvas"])
            let sc = Kernels.blurSigmaCanvasPx(blur: Self.dbl(c["blur"]), canvasW: Int(canvas[0]), canvasH: Int(canvas[1]))
            XCTAssertEqual(sc, Self.dbl(c["sigmaCanvasPx"]), accuracy: 1e-6)
            let ss = Kernels.blurSigmaSourcePx(sigmaCanvasPx: sc, canvasPxPerSourcePx: Self.dbl(c["canvasPxPerSourcePx"]))
            XCTAssertEqual(ss, Self.dbl(c["sigmaSourcePx"]), accuracy: 1e-6)
            let sr = Kernels.blurSigmaRenderPx(sigmaCanvasPx: sc, renderScale: Self.dbl(c["renderScale"]))
            XCTAssertEqual(sr, Self.dbl(c["sigmaRenderPx"]), accuracy: 1e-6)
            XCTAssertEqual(Kernels.blurRadius(ss), Int(Self.dbl(c["radiusSource"])))
            XCTAssertEqual(Kernels.blurRadius(sr), Int(Self.dbl(c["radiusRender"])))
            XCTAssertEqual(Kernels.blurSkipped(ss), c["skippedSource"] as? Bool)
            XCTAssertEqual(Kernels.blurSkipped(sr), c["skippedRender"] as? Bool)
        }
    }

    /// The placement transform maps base corners exactly like M (canvas px, y down) on a scaled render.
    func testPlacementTransformMatchesM() {
        let m = CGAffineTransform(a: 0.636396103, b: 0.636396103, c: -0.636396103, d: 0.636396103, tx: 5.272792206, ty: 0.181623382)
        let extent = CGRect(x: 10, y: 20, width: 40, height: 80)  // layer image px (4·10 × 8·10)
        let base = PlanSize(w: 4, h: 8)
        let rs = 2.0
        let t = Kernels.placementTransform(m, base: base, imageExtent: extent, canvasHeight: 8, renderScale: rs)
        for (lx, ly) in [(0.0, 0.0), (4.0, 0.0), (0.0, 8.0), (4.0, 8.0), (1.0, 6.0)] {
            // base-local (lx, ly) (y down) is image px (10 + lx·10, 20 + (8 − ly)·10) (y up).
            let ci = CGPoint(x: 10 + lx * 10, y: 20 + (8 - ly) * 10).applying(t)
            let canvas = CGPoint(x: lx, y: ly).applying(m)
            XCTAssertEqual(ci.x, canvas.x * rs, accuracy: 1e-9)
            XCTAssertEqual(ci.y, (8 - canvas.y) * rs, accuracy: 1e-9)
        }
    }
}
