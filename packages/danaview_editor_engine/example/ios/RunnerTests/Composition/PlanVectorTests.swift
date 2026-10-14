// OWNER: IOS-08
//
// Shared vectors on iOS: frame grid (CORE-02 frame_grid.json, D-35), keyframes (API-03
// keyframes.json, evaluated through ParamSnapshot at timeOfFrame(k)), transforms (API-03
// transform.json, the §11.6 placement matrix) and patch classification (CORE-32
// classification.json).

import CoreMedia
import XCTest

@testable import danaview_editor_engine

final class PlanVectorTests: XCTestCase {
    private func int(_ v: Any?) -> Int64 { (v as? NSNumber)?.int64Value ?? -999_999 }
    private func dbl(_ v: Any?) -> Double { (v as? NSNumber)?.doubleValue ?? .nan }

    // MARK: Frame grid

    func testFrameGridVectors() throws {
        let doc = try CompositionTestSupport.json(.core, "vectors/frame_grid.json")
        let rates = try XCTUnwrap(doc["rates"] as? [[String: Any]])
        XCTAssertEqual(Set(rates.map { Int(int($0["fps"])) }), FrameGrid.v1Rates)
        var checked = 0
        for rate in rates {
            let fps = int(rate["fps"])
            let g = FrameGrid(fps: fps)
            let half = int(rate["halfFrameMinus1Us"])
            for f in try XCTUnwrap(rate["frames"] as? [[String: Any]]) {
                let k = int(f["k"])
                let t = int(f["timeOfFrame"])
                let floorTime = int(f["floorTime"])
                let p = int(f["platformTime"])
                XCTAssertEqual(g.timeOfFrame(k), t, "fps \(fps) k \(k)")
                XCTAssertEqual(FrameGrid.floorDiv(k * 1_000_000, fps), floorTime)
                XCTAssertEqual(g.platformTimeOfFrame(k), p)
                let rational = try XCTUnwrap(f["rational"] as? [NSNumber])
                let cm = CMTime(value: rational[0].int64Value, timescale: CMTimeScale(rational[1].int32Value))
                XCTAssertEqual(CMTimeCompare(cm, g.cmTime(frame: k)), 0)
                XCTAssertEqual(CMTimeCompare(g.cmTime(gridUs: t), cm), 0, "grid time of timeOfFrame(k) is CMTime(k, fps)")
                let idx = try XCTUnwrap(f["frameIndexOf"] as? [String: Any])
                XCTAssertEqual(g.frameIndexOf(t - 1), int(idx["tMinus1"]))
                XCTAssertEqual(g.frameIndexOf(t), int(idx["t"]))
                XCTAssertEqual(g.frameIndexOf(t + 1), int(idx["tPlus1"]))
                XCTAssertTrue(g.isOnGrid(t))
                let nearest = try XCTUnwrap(f["nearest"] as? [String: Any])
                XCTAssertEqual(g.frameIndexNearest(t), int(nearest["timeOfFrame"]))
                XCTAssertEqual(g.frameIndexNearest(floorTime), int(nearest["floorTime"]))
                XCTAssertEqual(g.frameIndexNearest(p), int(nearest["platformTime"]))
                XCTAssertEqual(g.frameIndexNearest(cm), int(nearest["rational"]))
                XCTAssertEqual(g.frameIndexNearest(p + half), int(f["nearestAtPlatformPlusHalf"]))
                XCTAssertEqual(g.frameIndexNearest(p - half), int(f["nearestAtPlatformMinusHalf"]))
                checked += 1
            }
        }
        XCTAssertGreaterThan(checked, 50)
    }

    // MARK: Keyframes

    /// The EvaluatedLayer field of an animated channel.
    private func field(_ e: EvaluatedLayer, _ channel: String) -> Double? {
        switch channel {
        case "xf.cx": return e.cx
        case "xf.cy": return e.cy
        case "xf.s": return e.scale
        case "xf.r": return e.rotation
        case "xf.op": return e.opacity
        default:
            if channel.hasPrefix("adj."), let i = PlanAdjust.names.firstIndex(of: String(channel.dropFirst(4))) { return e.adjust[i] }
            return nil
        }
    }

    func testKeyframeVectorsThroughParamSnapshot() throws {
        let doc = try CompositionTestSupport.json(.engineApi, "vectors/keyframes.json")
        let cases = try XCTUnwrap(doc["cases"] as? [[String: Any]])
        XCTAssertFalse(cases.isEmpty)
        for c in cases {
            let name = c["name"] as? String ?? "?"
            let fps = int(c["fps"])
            let channel = try XCTUnwrap(c["channel"] as? String)
            let keys = try XCTUnwrap(c["keys"] as? [[NSNumber]]).map { AnimKey($0[0].int64Value, $0[1].doubleValue) }
            let g = FrameGrid(fps: fps)
            let layer = PlanLayer(
                id: "it_vec#v", z: 10, seq: 0, t0: 0, t1: 100_000_000, kind: .media, asset: "md_a",
                map: [MapSegment(0, 100_000_000, 0, 100_000_000)], base: PlanSize(w: 1920, h: 1080), anim: [channel: keys])
            let plan = RenderPlan(
                rev: 1, target: .preview, canvas: PlanCanvas(w: 1920, h: 1080, fps: Int(fps)), durUs: 100_000_000,
                assets: ["md_a": PlanAsset(kind: .video, uri: "file:///a.mp4")], layers: [layer], audio: [])
            let snapshot = ParamSnapshot(plan: plan)
            for s in try XCTUnwrap(c["samples"] as? [[String: Any]]) {
                let k = int(s["k"])
                let tau = int(s["tau"])
                let t = int(s["t"])
                let v = dbl(s["v"])
                XCTAssertEqual(g.frameIndexNearest(tau), k, "\(name): platform time maps to its frame")
                XCTAssertEqual(g.timeOfFrame(k), t, name)
                XCTAssertEqual(Keyframes.evaluate(keys, at: t, fallback: .nan), v, accuracy: 1e-6, "\(name) k \(k)")
                let evaluated = try XCTUnwrap(snapshot.evaluate(atFrame: k).first)
                XCTAssertEqual(try XCTUnwrap(field(evaluated, channel), "\(name): channel \(channel)"), v, accuracy: 1e-6, "\(name) k \(k)")
                // Evaluating at the raw platform time differs when tau is off the plan edge (the D-35 trap).
                if tau != t, keys.count > 1, keys.first!.tUs < t, t < keys.last!.tUs {
                    XCTAssertNotEqual(Keyframes.evaluate(keys, at: tau, fallback: .nan), v, "\(name): tau must not be used")
                }
            }
        }
    }

    // MARK: Transforms

    func testPlacementMatrixMatchesTransformVectors() throws {
        let doc = try CompositionTestSupport.json(.engineApi, "vectors/transform.json")
        let cases = try XCTUnwrap(doc["cases"] as? [[String: Any]])
        for c in cases {
            let name = c["name"] as? String ?? "?"
            let canvas = try XCTUnwrap(c["canvas"] as? [NSNumber])
            let base = try XCTUnwrap(c["base"] as? [NSNumber])
            let xf = try XCTUnwrap(c["xf"] as? [String: Any])
            let m = try XCTUnwrap(c["M"] as? [NSNumber]).map(\.doubleValue)
            let layer = PlanLayer(
                id: "l#v", z: 10010, t0: 0, t1: 1_000_000, kind: .image, asset: "im",
                base: PlanSize(w: base[0].doubleValue, h: base[1].doubleValue),
                xf: PlanTransform(
                    cx: dbl(xf["cx"]), cy: dbl(xf["cy"]), s: dbl(xf["s"]), r: dbl(xf["r"]),
                    fx: xf["fx"] as? Bool ?? false, fy: xf["fy"] as? Bool ?? false))
            let plan = RenderPlan(
                rev: 1, target: .preview, canvas: PlanCanvas(w: canvas[0].intValue, h: canvas[1].intValue, fps: 30),
                durUs: 1_000_000, assets: ["im": PlanAsset(kind: .image, uri: "file:///i.png")], layers: [layer], audio: [])
            let e = ParamSnapshot(plan: plan).evaluate(layer, atUs: 0)
            let p = e.placement
            for (got, want) in zip([p.a, p.b, p.c, p.d, p.tx, p.ty], m) {
                XCTAssertEqual(Double(got), want, accuracy: 1e-6, name)
            }
            for point in try XCTUnwrap(c["points"] as? [[String: Any]]) {
                let local = try XCTUnwrap(point["local"] as? [NSNumber])
                let canvasPt = try XCTUnwrap(point["canvas"] as? [NSNumber])
                let mapped = CGPoint(x: local[0].doubleValue, y: local[1].doubleValue).applying(p)
                XCTAssertEqual(Double(mapped.x), canvasPt[0].doubleValue, accuracy: 1e-6, name)
                XCTAssertEqual(Double(mapped.y), canvasPt[1].doubleValue, accuracy: 1e-6, name)
            }
        }
    }

    // MARK: Classification

    func testClassificationVectors() throws {
        let url = try XCTUnwrap(TestFixtures.url(.core, "render_plans/classification.json"))
        guard case .object(let doc) = try PlanJSONReader.parse(Data(contentsOf: url)),
              case .array(let cases)? = doc["cases"]
        else { return XCTFail("classification.json shape") }
        let from = try RenderPlanDecoder.decodePlan(RenderPlanDecoder.object(doc["from"], "from"))
        XCTAssertEqual(PlanValidator.validate(from), [])
        XCTAssertGreaterThan(cases.count, 20)
        for raw in cases {
            guard case .object(let c) = raw, case .string(let name)? = c["name"], case .bool(let structural)? = c["structural"] else {
                return XCTFail("case shape")
            }
            let patch = try RenderPlanDecoder.decodePatch(RenderPlanDecoder.object(c["patch"], "patch"))
            XCTAssertEqual(PlanPatching.classify(patch, from: from), structural ? .structural : .paramOnly, name)
            // The patch applies (from == rev) and lands at its target revision.
            let applied = try PlanPatching.apply(patch, to: from)
            XCTAssertEqual(applied.rev, patch.to, name)
        }
        let stale = RenderPlanPatch(from: 99, to: 100)
        XCTAssertThrowsError(try PlanPatching.apply(stale, to: from)) { XCTAssertEqual($0 as? PlanOutOfSync, PlanOutOfSync(planRev: 7, patchFrom: 99)) }
    }
}
