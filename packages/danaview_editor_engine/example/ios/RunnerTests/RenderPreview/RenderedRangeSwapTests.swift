// OWNER: IOS-19
//
// IOS-19 acceptance, playback side (ARCH D-45(A), §12.2 'Rendered ranges', §13.2):
// - playback across a range boundary shows the right frame at every boundary: the playback
//   composition (the live plan with the rendered file swapped in as one segment) reads the
//   grid-cut barcodes 100% on every frame, the render layer is the only layer drawn and decoded
//   inside the range and never outside it, and audio is unchanged;
// - a param patch inside the range drops the range (falls back to the live composition for the
//   next frame); patches outside it, audio-only patches keep it; canvas, duration, asset and
//   `setPlan` changes follow `patchTouchesRange` (the API-01 reference vectors);
// - render files are never referenced by an export plan (export plans are never rewritten, the
//   session's own plan is never changed);
// - the handler binds ranges to the session's plan through the registry; the hook reports frame
//   ranges only for the bound revision; off-grid ranges never play.

import AVFoundation
import XCTest

@testable import danaview_editor_engine

final class RenderedRangeSwapTests: XCTestCase {
    private var harness: RenderPreviewHarness!

    override func setUpWithError() throws {
        harness = try RenderPreviewHarness()
    }

    override func tearDown() {
        harness?.remove()
        harness = nil
    }

    private var a: Int64 { RenderPreviewFixtures.rangeStartUs }
    private var b: Int64 { RenderPreviewFixtures.rangeEndUs }

    private func range(_ a: Int64, _ b: Int64, url: URL = URL(fileURLWithPath: "/tmp/r.mp4"), hash: String = "h") -> RenderedRange {
        RenderedRange(startUs: a, endUs: b, fileURL: url, hash: hash)
    }

    /// Renders `[a, b)` of [plan] and returns its range.
    private func render(_ plan: RenderPlan, _ a: Int64, _ b: Int64) throws -> RenderedRange {
        let url = RenderPreviewFixtures.renderURL(harness.paths, "r\(a)-\(b)")
        let job = RenderPreviewJob(plan: RenderPreviewFixtures.cut(plan, a, b), outputURL: url,
                                   options: RenderPreviewFixtures.options(harness.paths))
        _ = try harness.run(job)
        return RenderedRange(startUs: a, endUs: b, fileURL: url, hash: "hash\(a)")
    }

    private func patch(_ plan: RenderPlan, _ edit: (inout RenderPlanPatch) -> Void) throws -> (RenderPlanPatch, RenderPlan) {
        var p = RenderPlanPatch(from: plan.rev, to: plan.rev + 1)
        edit(&p)
        return (p, try PlanPatching.apply(p, to: plan))
    }

    private func layer(_ plan: RenderPlan, _ id: String) -> PlanLayer { plan.layers.first { $0.id == id }! }

    // MARK: Playback across boundaries

    func testPlaybackAcrossRangeBoundariesShowsTheRightFrameEverywhere() throws {
        let plan = try RenderPreviewFixtures.plan()
        let r1 = try render(plan, a, b)
        let r2 = try render(plan, 1_600_000, 2_000_000)
        let swap = RenderedRangeSwap()
        swap.setRanges([r1, r2], plan: plan)
        let playback = try XCTUnwrap(swap.playbackPlan(for: plan))
        XCTAssertEqual(playback.audio, plan.audio, "audio stays live")
        let size = CGSize(width: 640, height: 360)
        let read = try RenderPreviewCheck.compose(playback, size: size, paths: harness.paths, pips: 4)
        defer { read.built.releaseMedia() }
        let total = plan.canvas.outputGrid.frameIndexOf(plan.durUs)
        XCTAssertEqual(read.frames.map(\.k), Array(0..<total))
        var problems: [String] = []
        for f in read.frames {
            if f.barcodes != RenderPreviewCheck.expected(f.k, pips: 4) { problems.append("frame \(f.k): \(f.barcodes)") }
            let inside1 = (10..<30).contains(f.k)
            let inside2 = (40..<50).contains(f.k)
            if inside1 || inside2 {
                let render = inside1 ? "!render-0" : "!render-1"
                if f.decoding != [render] { problems.append("frame \(f.k) decodes \(f.decoding)") }
                if f.drawn != [render] { problems.append("frame \(f.k) draws \(f.drawn)") }
            } else {
                if f.drawn.contains(where: { $0.hasPrefix("!render-") }) { problems.append("frame \(f.k) draws a render outside its range") }
                if f.decoding.count != 5 { problems.append("frame \(f.k) decodes \(f.decoding)") }
            }
        }
        XCTAssertEqual(problems, [], "grid-cut barcodes must be 100%")
        // The live composition of the same plan reads the same everywhere (reference).
        let live = try RenderPreviewCheck.compose(plan, size: size, paths: harness.paths, pips: 4)
        defer { live.built.releaseMedia() }
        for (x, y) in zip(read.frames, live.frames) {
            XCTAssertGreaterThanOrEqual(RenderPreviewCheck.ssim(x.luma, y.luma, w: 640, h: 360), 0.99, "frame \(x.k)")
        }
    }

    func testPlaybackPlanStructure() throws {
        let plan = try RenderPreviewFixtures.plan()
        let url = URL(fileURLWithPath: "/tmp/renders/x.mp4")
        let playback = try XCTUnwrap(RenderedRangeRules.playbackPlan(plan, ranges: [range(a, b, url: url, hash: "abc")]))
        let render = try XCTUnwrap(playback.layers.last)
        XCTAssertEqual(render.id, "!render-0")
        XCTAssertEqual(render.kind, .media)
        XCTAssertEqual(render.t0, a)
        XCTAssertEqual(render.t1, b)
        XCTAssertEqual(render.map, [MapSegment(a, b, 0, b - a)], "one segment")
        XCTAssertEqual(render.base, PlanSize(w: 640, h: 360))
        XCTAssertGreaterThan(render.z, plan.layers.map(\.z).max()!)
        XCTAssertEqual(render.seq, 5, "a fresh composition track")
        let asset = try XCTUnwrap(playback.assets[render.asset!])
        XCTAssertEqual(asset.uri, url.absoluteString)
        XCTAssertEqual(asset.fp, "render:abc")
        XCTAssertEqual(asset.hasAudio, false)
        // Every spanning media layer keeps its id, its edges and the map outside the range.
        let base = layer(playback, "it_base00000001#v")
        XCTAssertEqual(base.t0, 0)
        XCTAssertEqual(base.t1, plan.durUs)
        XCTAssertEqual(base.map, [MapSegment(0, a, 0, a), MapSegment(b, plan.durUs, b, plan.durUs)])
        let pip1 = layer(playback, "it_pip10000000#v")
        XCTAssertEqual(pip1.map, [MapSegment(0, a, 1_000_000, 1_000_000 + a), MapSegment(b, plan.durUs, 1_000_000 + b, 1_000_000 + plan.durUs)])
        XCTAssertEqual(playback.audio, plan.audio)
        XCTAssertEqual(playback.canvas, plan.canvas)
        XCTAssertEqual(playback.durUs, plan.durUs)
    }

    func testLayersInsideOrEndingInsideTheRangeAreRemovedOrShortened() throws {
        var plan = try RenderPreviewFixtures.plan()
        // pip1 lies wholly inside, pip2 ends inside, pip3 starts inside; a solid lies inside.
        plan.layers = plan.layers.map { l in
            var l = l
            switch l.id {
            case "it_pip10000000#v": l.t0 = 600_000; l.t1 = 1_000_000; l.map = [MapSegment(600_000, 1_000_000, 0, 400_000)]
            case "it_pip20000000#v": l.t1 = 800_000; l.map = [MapSegment(0, 800_000, 0, 800_000)]
            case "it_pip30000000#v": l.t0 = 800_000; l.map = [MapSegment(800_000, 2_000_000, 0, 1_200_000)]
            default: break
            }
            return l
        }
        plan.layers.append(PlanLayer(id: "it_solid000001#s", z: 20000, seq: nil, t0: 400_000, t1: 1_200_000, kind: .solid, color: 0xFFFF_0000))
        plan.layers.sort(by: PlanLayer.drawOrder)
        let playback = try XCTUnwrap(RenderedRangeRules.playbackPlan(plan, ranges: [range(a, b)]))
        let ids = Set(playback.layers.map(\.id))
        XCTAssertFalse(ids.contains("it_pip10000000#v"))
        XCTAssertFalse(ids.contains("it_solid000001#s"))
        let pip2 = layer(playback, "it_pip20000000#v")
        XCTAssertEqual(pip2.t1, a)
        XCTAssertEqual(pip2.map, [MapSegment(0, a, 0, a)])
        let pip3 = layer(playback, "it_pip30000000#v")
        XCTAssertEqual(pip3.t0, b)
        XCTAssertEqual(pip3.map, [MapSegment(b, 2_000_000, 400_000, 1_200_000)])
    }

    func testOffGridOrOutOfRangeRangesNeverPlay() throws {
        let plan = try RenderPreviewFixtures.plan()
        XCTAssertFalse(RenderedRangeRules.playable(range(410_000, b), in: plan), "not on the 25 fps grid")
        XCTAssertFalse(RenderedRangeRules.playable(range(a, 2_400_000), in: plan), "beyond the duration")
        XCTAssertTrue(RenderedRangeRules.playable(range(a, b), in: plan))
        var export = plan
        export.target = .export
        XCTAssertFalse(RenderedRangeRules.playable(range(a, b), in: export))
        XCTAssertNil(RenderedRangeRules.playbackPlan(plan, ranges: [range(410_000, b)]))
    }

    // MARK: Patches

    func testParamPatchInsideTheRangeFallsBackToLiveRendering() throws {
        let plan = try RenderPreviewFixtures.plan()
        let r = try render(plan, a, b)
        let swap = RenderedRangeSwap()
        swap.setRanges([r], plan: plan)
        XCTAssertEqual(swap.renderedRanges(planRev: plan.rev), [10..<30])
        XCTAssertNotNil(swap.playbackPlan(for: plan))
        // Opacity of PiP 2 changes (a param-only patch that touches the range).
        var pip2 = layer(plan, "it_pip20000000#v")
        pip2.xf.op = 0.5
        let (p, next) = try patch(plan) { $0.layers.upsert = [pip2] }
        XCTAssertEqual(PlanPatching.classify(p, from: plan), .paramOnly)
        swap.planDidChange(from: plan, to: next, patch: p)
        XCTAssertEqual(swap.allRanges, [], "the range is dropped until the next setRenderedRanges")
        XCTAssertEqual(swap.renderedRanges(planRev: next.rev), [])
        XCTAssertNil(swap.playbackPlan(for: next), "the next frame comes from the live composition")
        // The live composition shows the patch inside the former range.
        let live = try RenderPreviewCheck.compose(next, size: CGSize(width: 640, height: 360), paths: harness.paths, pips: 4, range: 10..<12)
        defer { live.built.releaseMedia() }
        XCTAssertEqual(live.frames.map(\.k), [10, 11])
        XCTAssertFalse(live.frames.contains { $0.drawn.contains { $0.hasPrefix("!render-") } })
        XCTAssertTrue(live.frames.allSatisfy { $0.drawn.contains("it_pip20000000#v") })
    }

    func testPatchRuleMirrorsTheReferenceVectors() throws {
        let plan = try RenderPreviewFixtures.plan()
        let r = range(a, b)
        let late = range(1_600_000, 2_000_000)
        func touches(_ edit: (inout RenderPlanPatch) -> Void, _ rr: RenderedRange = r) throws -> Bool {
            let (p, _) = try patch(plan, edit)
            return RenderedRangeRules.patchTouches(before: plan, patch: p, range: rr)
        }
        var pip2 = layer(plan, "it_pip20000000#v")
        pip2.xf.op = 0.5
        XCTAssertTrue(try touches { $0.layers.upsert = [pip2] }, "upserted layer overlapping")
        XCTAssertTrue(try touches { $0.layers.remove = ["it_pip30000000#v"] }, "removed layer overlapping")
        // A layer added after the range does not touch it; one moved out of it does (old span).
        var added = PlanLayer(id: "it_new00000001#s", z: 30000, seq: nil, t0: 1_600_000, t1: 2_000_000, kind: .solid, color: 0xFF00_FF00)
        added.base = PlanSize(w: 100, h: 100)
        XCTAssertFalse(try touches { $0.layers.upsert = [added] }, "new layer outside")
        XCTAssertTrue(try touches({ $0.layers.upsert = [added] }, late), "new layer inside the late range")
        var moved = layer(plan, "it_pip40000000#v")
        moved.t0 = 1_600_000
        moved.map = [MapSegment(1_600_000, 2_000_000, 5_600_000, 6_000_000)]
        XCTAssertTrue(try touches { $0.layers.upsert = [moved] }, "old span overlaps")
        // Audio changes never touch a range.
        var seg = plan.audio[0]
        seg.gain = [AnimKey(0, 0.1)]
        XCTAssertFalse(try touches { $0.audio.upsert = [seg] }, "audio only")
        // Canvas: every range.
        var canvas = plan.canvas
        canvas.bg = 0xFF11_2233
        XCTAssertTrue(try touches { $0.canvas = canvas })
        // Duration: ranges ending after the shorter duration.
        XCTAssertFalse(try touches { $0.durUs = 1_800_000; $0.layers.upsert = [] }, "range ends before the new end")
        XCTAssertTrue(RenderedRangeRules.patchTouches(
            before: plan, patch: RenderPlanPatch(from: 1, to: 2, durUs: 1_800_000), range: late), "range ends after it")
        // Assets: a changed or removed asset the plan had; a new asset does not.
        var asset = plan.assets["md_fc0000000001"]!
        asset.fp = "changed"
        XCTAssertTrue(RenderedRangeRules.patchTouches(
            before: plan, patch: RenderPlanPatch(from: 1, to: 2, assetUpserts: ["md_fc0000000001": asset]), range: r))
        XCTAssertTrue(RenderedRangeRules.patchTouches(
            before: plan, patch: RenderPlanPatch(from: 1, to: 2, assetRemovals: ["md_tone00000001"]), range: r))
        XCTAssertFalse(RenderedRangeRules.patchTouches(
            before: plan, patch: RenderPlanPatch(from: 1, to: 2, assetUpserts: ["md_new000000001": asset]), range: r))
    }

    func testSwapKeepsUntouchedRangesAndDropsAllOnSetPlan() throws {
        let plan = try RenderPreviewFixtures.plan()
        let swap = RenderedRangeSwap()
        swap.setRanges([range(a, b), range(1_600_000, 2_000_000)], plan: plan)
        var added = PlanLayer(id: "it_new00000001#s", z: 30000, seq: nil, t0: 1_600_000, t1: 2_000_000, kind: .solid, color: 0xFF00_FF00)
        added.base = PlanSize(w: 100, h: 100)
        let (p, next) = try patch(plan) { $0.layers.upsert = [added] }
        swap.planDidChange(from: plan, to: next, patch: p)
        XCTAssertEqual(swap.allRanges.map(\.startUs), [a], "only the touched range is dropped")
        XCTAssertEqual(swap.renderedRanges(planRev: next.rev), [10..<30])
        XCTAssertEqual(swap.renderedRanges(planRev: plan.rev), [], "a revision the swap has no plan for serves nothing")
        // setPlan: every range.
        var replaced = next
        replaced.rev = 9
        swap.planDidChange(from: next, to: replaced, patch: nil)
        XCTAssertEqual(swap.allRanges, [])
    }

    func testUnreportedPlanChangesAreReconciledByComparison() throws {
        let plan = try RenderPreviewFixtures.plan()
        let swap = RenderedRangeSwap()
        swap.setRanges([range(a, b), range(1_600_000, 2_000_000)], plan: plan)
        var pip2 = layer(plan, "it_pip20000000#v")
        pip2.xf.op = 0.5
        let (_, edited) = try patch(plan) { $0.layers.upsert = [pip2] }
        var seg = edited.audio[0]
        seg.gain = [AnimKey(0, 0.2)]
        let (_, audioOnly) = try patch(edited) { $0.audio.upsert = [seg] }
        // The session never told the swap; the provider reports the latest plan.
        swap.planProvider = { audioOnly }
        XCTAssertEqual(swap.renderedRanges(planRev: audioOnly.rev), [], "pip2 spans every range")
        XCTAssertEqual(swap.allRanges, [])

        let swap2 = RenderedRangeSwap()
        swap2.setRanges([range(a, b)], plan: edited)
        let playback = swap2.playbackPlan(for: audioOnly)
        XCTAssertNotNil(playback, "an audio-only change keeps the range")
    }

    // MARK: Export plans

    func testRenderFilesAreNeverReferencedByAnExportPlan() throws {
        let plan = try RenderPreviewFixtures.plan()
        let swap = RenderedRangeSwap()
        swap.setRanges([range(a, b)], plan: plan)
        var export = plan
        export.target = .export
        XCTAssertNil(swap.playbackPlan(for: export), "export plans are never rewritten")
        let original = plan
        let playback = try XCTUnwrap(swap.playbackPlan(for: plan))
        XCTAssertEqual(plan, original, "the session's plan is not changed")
        XCTAssertFalse(plan.assets.contains { RenderedRangeRules.isRenderAsset(id: $0.key, $0.value) })
        XCTAssertTrue(playback.assets.contains { RenderedRangeRules.isRenderAsset(id: $0.key, $0.value) })
        XCTAssertThrowsError(try RenderPreviewJob.decode(PlanEncoder.encode(export))) {
            XCTAssertEqual(($0 as? EngineError)?.code, .planInvalid)
        }
    }

    // MARK: Handler, registry, hook

    func testHandlerBindsRangesToTheSessionThroughTheRegistry() throws {
        let plan = try RenderPreviewFixtures.plan(rev: 7)
        let registry = RenderedRangeRegistry.of(harness.context)
        XCTAssertTrue(registry === RenderedRangeRegistry.of(harness.context))
        let swap = registry.swap(for: "pv_1")
        swap.planProvider = { plan }
        let handler = RenderedRangeHandler(context: harness.context)
        let url = RenderPreviewFixtures.renderURL(harness.paths, "hh")
        let msg = RenderedRangeMsg(startUs: a, endUs: b, uri: url.absoluteString, hash: "hh")
        var reply: Result<Void, Error>?
        handler.setRenderedRanges(sessionId: "pv_1", ranges: [msg], fileURLs: [url]) { reply = $0 }
        XCTAssertNoThrow(try reply?.get())
        XCTAssertEqual(swap.allRanges, [RenderedRange(startUs: a, endUs: b, fileURL: url, hash: "hh")])
        XCTAssertEqual(swap.renderedRanges(planRev: 7), [10..<30])
        XCTAssertEqual(swap.renderedRanges(planRev: 6), [])
        // Replaces the whole set.
        handler.setRenderedRanges(sessionId: "pv_1", ranges: [], fileURLs: []) { reply = $0 }
        XCTAssertNoThrow(try reply?.get())
        XCTAssertEqual(swap.allRanges, [])
        // Mismatched URLs are refused.
        handler.setRenderedRanges(sessionId: "pv_1", ranges: [msg], fileURLs: []) { reply = $0 }
        XCTAssertThrowsError(try reply?.get())
        registry.remove(sessionId: "pv_1")
        XCTAssertNil(registry.existingSwap(for: "pv_1"))
    }

    func testHookRecordsBoundaryCrossings() throws {
        let swap = RenderedRangeSwap()
        swap.playbackCrossed(range: 10..<30, entered: true, atFrame: 10)
        XCTAssertEqual(swap.activeRanges, [10..<30])
        swap.playbackCrossed(range: 10..<30, entered: false, atFrame: 30)
        XCTAssertEqual(swap.activeRanges, [])
        XCTAssertEqual(swap.crossings, [
            RenderedRangeSwap.Crossing(range: 10..<30, entered: true, frame: 10),
            RenderedRangeSwap.Crossing(range: 10..<30, entered: false, frame: 30),
        ])
    }
}
