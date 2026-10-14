// OWNER: IOS-08
//
// ParamSnapshot: layer activity at timeOfFrame(k) (grid_cuts_30fps expected-active table), source
// time per §11.5, transients (merge, clear, dropped by a patch touching the layer), the atomic
// store, and the canvas-mask / mask / reveal evaluation.

import XCTest

@testable import danaview_editor_engine

final class ParamSnapshotTests: XCTestCase {
    func testActiveLayersMatchTheGridCutsTable() throws {
        let plan = try CompositionTestSupport.plan("grid_cuts_30fps.json")
        let expected = try CompositionTestSupport.json(.core, "render_plans/contract/grid_cuts_30fps.expected_active.json")
        let frames = try XCTUnwrap(expected["frames"] as? [[String: Any]])
        XCTAssertEqual(frames.count, 90)
        let snapshot = ParamSnapshot(plan: plan)
        for f in frames {
            let k = (f["k"] as! NSNumber).int64Value
            XCTAssertEqual(snapshot.timeOfFrame(k), (f["timeOfFrame"] as! NSNumber).int64Value)
            XCTAssertEqual(snapshot.activeLayers(atFrame: k).map(\.id), f["active"] as! [String], "frame \(k)")
        }
    }

    func testSourceTimeFollowsTheContainingSegmentAndHold() throws {
        let ramp = try CompositionTestSupport.plan("speed_ramp_multi_segment.json").layers[0]
        for seg in ramp.map {
            XCTAssertEqual(ParamSnapshot.sourceTime(ramp, at: seg.t0), Double(seg.s0))
            let mid = (seg.t0 + seg.t1) / 2
            XCTAssertEqual(try XCTUnwrap(ParamSnapshot.sourceTime(ramp, at: mid)), seg.source(at: mid), accuracy: 1e-9)
        }
        let hold = try CompositionTestSupport.plan("hold_pending_still.json").layers.first { $0.hold }!
        XCTAssertEqual(ParamSnapshot.sourceTime(hold, at: hold.t1 - 1), Double(hold.map[0].s0))
    }

    func testTransientsMergeClearAndAreDroppedByPatches() throws {
        let plan = try CompositionTestSupport.plan("minimal_preview.json")
        let id = plan.layers[0].id
        var t = PlanTransient(item: "it_clip00000001", layers: [TransientLayer(id: id, xf: PlanTransform(cx: 100, cy: 200, s: 2))])
        let base = ParamSnapshot(plan: plan)
        let moved = base.applying(t)
        XCTAssertEqual(moved.layer(id)?.xf.s, 2)
        XCTAssertEqual(moved.evaluate(atFrame: 0).first?.cx, 100)
        XCTAssertEqual(base.layer(id)?.xf.s, 1, "snapshots are immutable")
        // Last write wins; an empty fx clears.
        t.layers[0].xf = PlanTransform(s: 3)
        t.layers[0].fx = PlanEffects()
        let again = moved.applying(t)
        XCTAssertEqual(again.layer(id)?.xf.s, 3)
        XCTAssertEqual(again.transients.count, 1)
        XCTAssertEqual(again.clearingTransient(item: "it_clip00000001").layer(id)?.xf.s, 1)
        // Transient timing never changes activity (transients have no timing fields).
        XCTAssertEqual(again.activeLayers(atFrame: 0).map(\.id), [id])
        // A param patch touching the layer drops its transient; others stay.
        var patched = plan
        patched.rev = 2
        patched.layers[0].xf.op = 0.5
        let afterPatch = again.replacingPlan(patched, touchedLayerIds: [id])
        XCTAssertTrue(afterPatch.transients.isEmpty)
        XCTAssertEqual(afterPatch.layer(id)?.xf.op, 0.5)
        XCTAssertEqual(again.replacingPlan(patched, touchedLayerIds: ["other#v"]).layer(id)?.xf.s, 3)
        XCTAssertTrue(again.replacingPlan(patched, touchedLayerIds: nil).transients.isEmpty)
    }

    func testStoreSwapsAtomically() throws {
        let plan = try CompositionTestSupport.plan("minimal_preview.json")
        let store = ParamSnapshotStore(ParamSnapshot(plan: plan))
        XCTAssertEqual(store.generation, 0)
        let first = store.current
        var next = plan
        next.rev = 9
        XCTAssertEqual(store.swap(ParamSnapshot(plan: next)), 1)
        XCTAssertEqual(store.current.plan.rev, 9)
        XCTAssertEqual(first.plan.rev, 1, "a reader's reference is unaffected by the swap")
        let t = PlanTransient(item: "x", layers: [TransientLayer(id: plan.layers[0].id, xf: PlanTransform(op: 0.25))])
        store.update { $0.applying(t) }
        XCTAssertEqual(store.generation, 2)
        XCTAssertEqual(store.current.evaluate(atFrame: 3).first?.opacity, 0.25)
        DispatchQueue.concurrentPerform(iterations: 200) { i in
            if i % 2 == 0 { store.swap(ParamSnapshot(plan: plan)) } else { _ = store.current.evaluate(atFrame: Int64(i % 90)) }
        }
        XCTAssertEqual(store.generation, 102)
    }

    func testMasksCanvasMasksAndRevealEvaluate() throws {
        let wipe = try CompositionTestSupport.plan("transition_wipe.json")
        let withMask = try XCTUnwrap(wipe.layers.first { !$0.cmasks.isEmpty })
        let snap = ParamSnapshot(plan: wipe)
        let mid = (withMask.t0 + withMask.t1) / 2
        let e = snap.evaluate(withMask, atUs: snap.plan.canvas.outputGrid.quantize(mid))
        let m = withMask.cmasks[0]
        for (name, value) in [("cx", e.cmasks[0].cx), ("cy", e.cmasks[0].cy), ("w", e.cmasks[0].w), ("h", e.cmasks[0].h)] {
            if let keys = m.anim[name] {
                XCTAssertEqual(value, Keyframes.evaluate(keys, at: snap.plan.canvas.outputGrid.quantize(mid), fallback: .nan), accuracy: 1e-9)
            }
        }
        XCTAssertTrue(e.cmasks[0].anim.isEmpty)

        let sprites = try CompositionTestSupport.plan("sprites_export_reveal.json")
        let revealLayer = try XCTUnwrap(sprites.layers.first { $0.anim["reveal"] != nil })
        let keys = revealLayer.anim["reveal"]!
        let s = ParamSnapshot(plan: sprites)
        for t in stride(from: revealLayer.t0, to: revealLayer.t1, by: 100_000) {
            let r = s.evaluate(revealLayer, atUs: t).reveal
            XCTAssertEqual(r, Int(Keyframes.evaluate(keys, at: t, fallback: 0).rounded(.down)))
        }

        let all = try CompositionTestSupport.plan("anim_every_channel.json")
        let layer = all.layers[0]
        let a = ParamSnapshot(plan: all).evaluate(layer, atUs: all.canvas.outputGrid.quantize(layer.t1 / 2))
        let t = all.canvas.outputGrid.quantize(layer.t1 / 2)
        if let k = layer.anim["mask.w"] { XCTAssertEqual(a.mask?.w ?? .nan, Keyframes.evaluate(k, at: t, fallback: .nan), accuracy: 1e-9) }
        if let k = layer.anim["detail.blur"] { XCTAssertEqual(a.detail.blur, Keyframes.evaluate(k, at: t, fallback: .nan), accuracy: 1e-9) }
    }
}
