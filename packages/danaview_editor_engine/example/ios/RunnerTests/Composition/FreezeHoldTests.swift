// OWNER: IOS-08
//
// Freeze-frame (`hold`) layers (ARCH §11.5: s = map[0].s0 throughout, the frame shown is the sample
// with the greatest PTS ≤ s + 500 µs) over a long range, read the way a segmented export and a
// precompose pass read them: readers opening inside the freeze. The hold used to be a 100 µs
// source range starting inside the sample, scaled across the whole layer; a reader opening inside
// such an edit may never get a frame (PastSourceEndTests saw it for the past-source-end hold). It
// is now laid like that hold: the whole sample at an integral scale plus an unscaled remainder,
// split by ExportSpacer at each reader's start.
//
// clap_flash_av.mp4 (6 s, 180 frames at 30 fps, frame barcodes), 30 fps grid, 361 frames:
//   A  [0, 1 s)          1× from 0           frames 0…29
//   F1 [1 s, 6 s)        hold s0 = 2.010 s   frame 60 (inside the sample, off its start)
//   F2 [6 s, 11.0333 s)  hold s0 = 4.4996 s  frame 135 (only through ε: 4.4996 s alone is 134)
//   B  [11.0333 s, 12.0333 s) 1× from 3.0 s  frames 90…119 (in sync after the freezes)

import AVFoundation
import XCTest

@testable import danaview_editor_engine

final class FreezeHoldTests: XCTestCase {
    private var export: ExportHarness?
    private var keep: [BuiltComposition] = []

    override func tearDown() async throws {
        export?.remove()
        export = nil
        keep = []
        try await super.tearDown()
    }

    static let asset = "md_clap0000001"
    static let total: Int64 = 361

    /// The freeze plan on a [w]×[h] canvas at [fps] over the 30 fps grid; [pips] adds that many
    /// small picture-in-picture slots (frame_counter) at the bottom, clear of the barcode band.
    static func plan(target: PlanTarget = .export, w: Int = 640, h: Int = 360, fps: Int = 30, pips: Int = 0) -> RenderPlan {
        let grid = FrameGrid(30)
        let t1 = grid.timeOfFrame(30)
        let t2 = grid.timeOfFrame(180)
        let t3 = grid.timeOfFrame(331)
        let end = grid.timeOfFrame(total)
        let base = PlanSize(w: Double(w), h: Double(h))
        var assets = [
            asset: PlanAsset(kind: .video, uri: "file:///fixtures/clap_flash_av.mp4", fp: "fp_clap", w: 1280, h: 720, durUs: 6_000_000, hasAudio: true),
        ]
        var layers = [
            PlanLayer(id: "it_a000000001#v", z: 10, seq: 0, t0: 0, t1: t1, kind: .media, asset: asset, map: [MapSegment(0, t1, 0, t1)], base: base),
            PlanLayer(id: "it_f000000001#v", z: 10, seq: 0, t0: t1, t1: t2, kind: .media, asset: asset,
                      map: [MapSegment(t1, t2, 2_010_000, 2_010_000 + t2 - t1)], hold: true, base: base),
            PlanLayer(id: "it_f000000002#v", z: 10, seq: 0, t0: t2, t1: t3, kind: .media, asset: asset,
                      map: [MapSegment(t2, t3, 4_499_600, 4_499_600 + t3 - t2)], hold: true, base: base),
            PlanLayer(id: "it_b000000001#v", z: 10, seq: 0, t0: t3, t1: end, kind: .media, asset: asset,
                      map: [MapSegment(t3, end, 3_000_000, 3_000_000 + end - t3)], base: base),
        ]
        if pips > 0 {
            assets["md_fc0000000001"] = PlanAsset(
                kind: .video, uri: "file:///fixtures/frame_counter_720p25.mp4", fp: "fp_fc", w: 1280, h: 720, durUs: 8_000_000, hasAudio: false)
            for i in 1...pips {
                var pip = PlanLayer(
                    id: "it_p\(i)00000000#v", z: 20 + i, seq: i, t0: 0, t1: end, kind: .media, asset: "md_fc0000000001",
                    map: [MapSegment(0, end, 0, end)], base: PlanSize(w: Double(w) / 5, h: Double(h) / 5))
                pip.xf.cx = Double(w) * Double(i) / Double(pips + 1)
                pip.xf.cy = Double(h) * 0.85
                layers.append(pip)
            }
        }
        return RenderPlan(
            rev: 1, target: target, canvas: PlanCanvas(w: w, h: h, fps: fps, gridFps: 30), durUs: end, assets: assets, layers: layers,
            audio: [])
    }

    /// The ARCH §11.5 source frame of the slot-0 layer at output frame [k] (30 fps source).
    static func wanted(_ plan: RenderPlan, k: Int64) -> Int? {
        guard let layer = ParamSnapshot(plan: plan).evaluate(atFrame: k).first(where: { $0.seq == 0 }), let s = layer.sourceUs else {
            return nil
        }
        return min(Int(((s + 500) * 30 / 1_000_000 + 1e-9).rounded(.down)), 179)
    }

    func testTheRuleOnTheFreezePlan() {
        let plan = Self.plan()
        XCTAssertEqual(Self.wanted(plan, k: 29), 29)
        XCTAssertEqual((30..<180).map { Self.wanted(plan, k: $0) }, Array(repeating: 60, count: 150))
        XCTAssertEqual((180..<331).map { Self.wanted(plan, k: $0) }, Array(repeating: 135, count: 151))
        XCTAssertEqual(Self.wanted(plan, k: 331), 90)
        XCTAssertEqual(Self.wanted(plan, k: 360), 119)
    }

    // MARK: Composition

    func testAFreezeHoldsTheWholeRuleSampleAtIntegralScales() async throws {
        let plan = Self.plan()
        let built = try await CompositionBuilder.build(plan: plan, options: try PastSourceEndTests.buildOptions(session: nil))
        keep.append(built)
        let track = try XCTUnwrap(built.composition.track(withTrackID: try XCTUnwrap(built.trackIDBySeq[0])))
        let grid = plan.canvas.editGrid
        for (k0, k1, frame) in [(Int64(30), Int64(180), 60), (180, 331, 135)] {
            let start = grid.cmTime(frame: k0)
            let end = grid.cmTime(frame: k1)
            let run = track.segments.filter {
                !$0.isEmpty && CMTimeCompare($0.timeMapping.target.start, start) >= 0 && CMTimeCompare($0.timeMapping.target.end, end) <= 0
            }
            XCTAssertFalse(run.isEmpty, "freeze \(frame) laid")
            XCTAssertEqual(CMTimeCompare(run.first!.timeMapping.target.start, start), 0, "freeze \(frame) starts on its frame")
            XCTAssertEqual(CMTimeCompare(run.last!.timeMapping.target.end, end), 0, "freeze \(frame) ends on its frame (in sync)")
            for s in run {
                // The whole sample of frame [frame] (or a prefix of it), never a range inside it.
                XCTAssertEqual(CMTimeGetSeconds(s.timeMapping.source.start), Double(frame) / 30, accuracy: 1e-4, "freeze \(frame): sample start")
                XCTAssertLessThanOrEqual(CMTimeGetSeconds(s.timeMapping.source.duration), 1.0 / 30 + 1e-4, "freeze \(frame): one sample")
                let scale = CMTimeGetSeconds(s.timeMapping.target.duration) / CMTimeGetSeconds(s.timeMapping.source.duration)
                XCTAssertEqual(scale, scale.rounded(), accuracy: 1e-6, "freeze \(frame): integral scale")
            }
        }
        // B follows on the grid at 1×.
        let b = try XCTUnwrap(track.segment(forTrackTime: grid.cmTime(frame: 331)))
        XCTAssertEqual(CMTimeCompare(b.timeMapping.target.start, grid.cmTime(frame: 331)), 0, "B starts on its frame")
        XCTAssertEqual(CMTimeGetSeconds(b.timeMapping.target.duration), CMTimeGetSeconds(b.timeMapping.source.duration), accuracy: 1e-6)
    }

    func testComposedFramesShowTheFrozenFrame() async throws {
        for fps in [24, 30, 60] {
            let plan = Self.plan(w: 320, h: 180, fps: fps)
            let session = try CompositorTestSupport.session(snapshot: ParamSnapshot(plan: plan))
            let built = try await CompositionBuilder.build(plan: plan, options: try PastSourceEndTests.buildOptions(session: session))
            keep.append(built)
            var stamps: [Int64] = []
            var problems: [String] = []
            try CompositorTestSupport.readFrames(built) { k, _, pb in
                guard let k else { return problems.append("unstamped frame") }
                stamps.append(k)
                let want = Self.wanted(plan, k: k)
                let got = CompositorTestSupport.barcode(pb)
                if got != want { problems.append("\(fps) fps frame \(k): \(String(describing: got)) != \(String(describing: want))") }
            }
            // Output frames before the grid end (361 frames at 30 fps): ceil(361 · fps / 30).
            XCTAssertEqual(stamps, Array(0..<((Self.total * Int64(fps) + 29) / 30)), "\(fps) fps: every frame composed once")
            XCTAssertTrue(problems.isEmpty, problems.prefix(20).joined(separator: "\n"))
        }
    }

    // MARK: Readers opening inside the freeze

    /// Frames of [built] read from [start] for [seconds] the way a segment reader reads them (an
    /// anchored composition copy, `ExportSpacer`); nil when the reader stalls (8 s watchdog).
    private func readSegment(_ built: BuiltComposition, from start: CMTime, seconds: Double) throws -> [Int64: Int?]? {
        let copy = try XCTUnwrap(built.composition.mutableCopy() as? AVMutableComposition)
        try ExportSpacer.anchor(copy, built: built, at: start)
        let reader = try AVAssetReader(asset: copy)
        let end = CMTimeMinimum(CMTimeAdd(start, CMTime(seconds: seconds, preferredTimescale: 600)), ExportTime.gridEnd(built.plan))
        reader.timeRange = CMTimeRange(start: start, end: end)
        let out = AVAssetReaderVideoCompositionOutput(
            videoTracks: copy.tracks(withMediaType: .video), videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        out.videoComposition = built.videoComposition
        reader.add(out)
        XCTAssertTrue(reader.startReading())
        let got = Locked<[Int64: Int?]>([:])
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            while let sample = out.copyNextSampleBuffer() {
                guard let pb = CMSampleBufferGetImageBuffer(sample), let k = DVRenderSession.frameIndex(of: pb) else { continue }
                let code = CompositorTestSupport.barcode(pb)
                got.mutate { $0[k] = code }
            }
            done.signal()
        }
        // A stalled reader is left blocked (cancelling it under a blocked call crashes, FIX-IOS-D7).
        guard done.wait(timeout: .now() + 8) == .success else { return nil }
        reader.cancelReading()
        return got.value
    }

    func testReadersStartingInsideALongFreezeDeliverEveryFrame() async throws {
        let plan = Self.plan(w: 320, h: 180)
        let session = try CompositorTestSupport.session(snapshot: ParamSnapshot(plan: plan))
        let built = try await CompositionBuilder.build(plan: plan, options: try PastSourceEndTests.buildOptions(session: session))
        keep.append(built)
        var problems: [String] = []
        // Around both play ↔ freeze seams, the freeze ↔ freeze seam, and spread over both freezes
        // (the 1 s export segment starts and others).
        for k0: Int64 in [29, 30, 31, 45, 60, 77, 90, 120, 150, 179, 180, 181, 210, 240, 270, 300, 329, 330, 331] {
            guard let frames = try readSegment(built, from: CMTime(value: k0, timescale: 30), seconds: 0.3) else {
                // A stalled reader is left blocked; later readers would not start.
                problems.append("reader from frame \(k0) stalled")
                break
            }
            let want = Set(k0..<min(k0 + 9, Self.total))
            if Set(frames.keys) != want { problems.append("reader from \(k0): frames \(frames.keys.sorted())") }
            for (k, code) in frames where code != Self.wanted(plan, k: k) {
                problems.append("reader from \(k0): frame \(k) shows \(String(describing: code))")
            }
        }
        XCTAssertTrue(problems.isEmpty, problems.joined(separator: "\n"))
    }

    // MARK: Export

    private func checkFrames(_ output: URL, _ plan: RenderPlan, name: String) throws {
        var problems: [String] = []
        var count = 0
        try ExportConformance.frames(output) { pts, pb in
            let k = FrameGrid(30).frameIndexNearest(pts)
            count += 1
            let want = Self.wanted(plan, k: k)
            let got = CompositorTestSupport.barcode(pb)
            if got != want { problems.append("\(name) frame \(k): \(String(describing: got)) != \(String(describing: want))") }
        }
        XCTAssertEqual(count, Int(Self.total), name)
        XCTAssertTrue(problems.isEmpty, problems.prefix(20).joined(separator: "\n"))
    }

    func testSegmentedExportThroughALongFreeze() throws {
        // 1 s segments: the readers of segments 2…10 all open inside the freezes.
        let plan = Self.plan()
        let h = try ExportHarness(ExportHarness.Options(segmentDurationUs: 1_000_000))
        export = h
        let output = h.outputURL("mp4")
        let id = try h.export(self, plan: PlanEncoder.encode(plan), settings: ExportPlans.settings(640, 360, fps: 30), output: output, timeout: 100)
        if let failure = h.recorder.failure(id) { return XCTFail("export failed: \(failure.code) \(failure.message)") }
        XCTAssertNotNil(h.recorder.done(id)?.exportResult, "export finished")
        try checkFrames(output, plan, name: "export")
    }

    func testPrecomposePassesThroughALongFreeze() throws {
        // Three slots over a decoder limit of 2: pass 1 composes the freezes with readers opening
        // inside them at every segment (0.4 s), then the final pass reads the intermediate.
        executionTimeAllowance = 300
        let plan = Self.plan(pips: 2)
        let p = try PrecomposeHarness(decoderLimit: 2, segmentDurationUs: 400_000)
        export = p.h
        let output = p.h.outputURL("mp4")
        let id = try p.h.export(self, plan: PlanEncoder.encode(plan), settings: ExportPlans.settings(640, 360, fps: 30, videoBitrate: 6_000_000),
                                output: output, timeout: 280)
        if let failure = p.h.recorder.failure(id) { return XCTFail("precompose export failed: \(failure.code) \(failure.message)") }
        XCTAssertNotNil(p.h.recorder.done(id)?.exportResult, "export finished")
        XCTAssertFalse(p.exporter.runs.isEmpty, "the decoder limit forces precompose passes")
        try checkFrames(output, plan, name: "precompose")
    }
}
