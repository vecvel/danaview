// OWNER: IOS-08
//
// A layer whose map runs past its source end (ARCH §11.5): the displayed frame is the sample with
// the greatest PTS ≤ s + 500 µs, so past the end it is the LAST source frame, held to the layer's
// end, and audio past the source end is silent. Nothing stretches the clip (CompositionBuilder used
// to clamp the range and scale it over the segment, and to drop segments starting past the end).
//
// clap_flash_av.mp4 (6 s, 180 frames at 30 fps, clicks at 1.0 / 2.5 / 4.0 s, frame barcodes):
//   A [0, 4 s)  1× from 3.0 s             plays frames 90…179, holds 179 from 3.0 s;
//   B [4, 6 s)  2× 3.6→4.8 | 2× 4.8→6.4 | 1× 6.4→7.0
//               plays 108…179, holds 179 from 5.2 s; the third segment starts past the end.
// Audio: A (keep pitch, 1×) and B (varispeed) on the same maps: the 4.0 s click lands at 1.0 s and
// 4.2 s. tone_under_video.mp4 (8 s 1 kHz) checks that the tone stops at the source end.
// Checked: the composition has media at every output frame; composed frames (AVAssetReader + DVCompositor,
// the preview item's composition) at 24/30/60 fps over the 30 fps grid; exact preview seeks
// (AVPlayer); the export file (frames and audio); the mix read (clicks in sync, silent tail, a
// keep-pitch piece running far past its source keeps its latency compensation).

import AVFoundation
import XCTest

@testable import danaview_editor_engine

final class PastSourceEndTests: XCTestCase {
    private var preview: PreviewHarness?
    private var export: ExportHarness?
    private var keep: [BuiltComposition] = []

    override func tearDown() async throws {
        if let h = preview { await h.dispose() }
        preview = nil
        export?.remove()
        export = nil
        keep = []
        try await super.tearDown()
    }

    // MARK: Plans

    static let clapLast = 179
    static let toneLast = 239

    static let mapA = [MapSegment(0, 4_000_000, 3_000_000, 7_000_000)]
    static let mapB = [
        MapSegment(4_000_000, 4_600_000, 3_600_000, 4_800_000),
        MapSegment(4_600_000, 5_400_000, 4_800_000, 6_400_000),
        MapSegment(5_400_000, 6_000_000, 6_400_000, 7_000_000),
    ]

    /// The clap_flash plan (layers A and B, their audio) on a [w]×[h] canvas at [fps] over the 30 fps grid.
    static func clapPlan(target: PlanTarget = .preview, w: Int = 1920, h: Int = 1080, fps: Int = 30) -> RenderPlan {
        let asset = PlanAsset(
            kind: .video, uri: "file:///fixtures/clap_flash_av.mp4", fp: "fp_clap", w: 1280, h: 720, durUs: 6_000_000, hasAudio: true)
        let base = PlanSize(w: Double(w), h: Double(h))
        return RenderPlan(
            rev: 1, target: target, canvas: PlanCanvas(w: w, h: h, fps: fps, gridFps: 30), durUs: 6_000_000,
            assets: ["md_clap0000001": asset],
            layers: [
                PlanLayer(id: "it_a000000001#v", z: 10, seq: 0, t0: 0, t1: 4_000_000, kind: .media, asset: "md_clap0000001", map: mapA, base: base),
                PlanLayer(id: "it_b000000001#v", z: 10, seq: 0, t0: 4_000_000, t1: 6_000_000, kind: .media, asset: "md_clap0000001", map: mapB,
                          base: base),
            ],
            audio: [
                AudioSeg(id: "it_a000000001#a", asset: "md_clap0000001", t0: 0, t1: 4_000_000, map: mapA, gain: [AnimKey(0, 1)], pitch: true),
                AudioSeg(id: "it_b000000001#a", asset: "md_clap0000001", t0: 4_000_000, t1: 6_000_000, map: mapB, gain: [AnimKey(0, 1)],
                         pitch: false),
            ])
    }

    /// tone_under_video (8 s): 1× from 6.0 s over [0, 3 s) (the source ends at 2.0 s), then 2× varispeed
    /// from 5.0 s over [3, 5 s) (the source ends at 4.5 s).
    static func tonePlan(target: PlanTarget = .preview, w: Int = 640, h: Int = 360) -> RenderPlan {
        let asset = PlanAsset(
            kind: .video, uri: "file:///fixtures/tone_under_video.mp4", fp: "fp_tone", w: 1280, h: 720, durUs: 8_000_000, hasAudio: true)
        let base = PlanSize(w: Double(w), h: Double(h))
        let one = [MapSegment(0, 3_000_000, 6_000_000, 9_000_000)]
        let two = [MapSegment(3_000_000, 5_000_000, 5_000_000, 9_000_000)]
        return RenderPlan(
            rev: 1, target: target, canvas: PlanCanvas(w: w, h: h, fps: 30), durUs: 5_000_000,
            assets: ["md_tone0000001": asset],
            layers: [
                PlanLayer(id: "it_t000000001#v", z: 10, seq: 0, t0: 0, t1: 3_000_000, kind: .media, asset: "md_tone0000001", map: one, base: base),
                PlanLayer(id: "it_t000000002#v", z: 10, seq: 0, t0: 3_000_000, t1: 5_000_000, kind: .media, asset: "md_tone0000001", map: two,
                          base: base),
            ],
            audio: [
                AudioSeg(id: "it_t000000001#a", asset: "md_tone0000001", t0: 0, t1: 3_000_000, map: one, gain: [AnimKey(0, 1)], pitch: true),
                AudioSeg(id: "it_t000000002#a", asset: "md_tone0000001", t0: 3_000_000, t1: 5_000_000, map: two, gain: [AnimKey(0, 1)],
                         pitch: false),
            ])
    }

    /// The ARCH §11.5 source frame of [plan]'s slot-0 layer at output frame [k] of a 30 fps source
    /// whose last frame is [last]: greatest PTS ≤ s + 500 µs, i.e. the last frame past the end.
    static func wanted(_ plan: RenderPlan, k: Int64, last: Int) -> Int? {
        guard let layer = ParamSnapshot(plan: plan).evaluate(atFrame: k).first(where: { $0.seq == 0 }), let s = layer.sourceUs else {
            return nil
        }
        return min(Int(((s + 500) * 30 / 1_000_000 + 1e-9).rounded(.down)), last)
    }

    static func buildOptions(session: DVRenderSession?, renderSize: CGSize? = nil) throws -> CompositionBuildOptions {
        var o = CompositionBuildOptions(spacerDirectory: try CompositionTestSupport.spacerDirectory())
        o.renderSize = renderSize
        o.validate = false
        o.resolveURL = { _, asset in
            let name = URL(string: asset.uri)?.lastPathComponent ?? ""
            guard let url = TestFixtures.url(.engine, "media/\(name)") else { throw EngineError(.mediaOffline, "fixture missing") }
            return url
        }
        session?.configure(&o)
        return o
    }

    // MARK: Composition

    func testTheRuleHoldsTheLastFrameOnTheTestPlans() {
        // The tables the other tests check against: A plays 90…179 and holds 179; B plays 108…179,
        // holds 179 from 5.2 s, and its third segment (past the end) shows 179.
        let plan = Self.clapPlan()
        XCTAssertEqual(Self.wanted(plan, k: 0, last: Self.clapLast), 90)
        XCTAssertEqual(Self.wanted(plan, k: 88, last: Self.clapLast), 178)
        XCTAssertEqual((89..<120).map { Self.wanted(plan, k: $0, last: Self.clapLast) }, Array(repeating: 179, count: 31))
        XCTAssertEqual(Self.wanted(plan, k: 120, last: Self.clapLast), 108)
        XCTAssertEqual(Self.wanted(plan, k: 155, last: Self.clapLast), 178)
        XCTAssertEqual((156..<180).map { Self.wanted(plan, k: $0, last: Self.clapLast) }, Array(repeating: 179, count: 24))
    }

    func testEveryOutputFrameOfALayerPastItsSourceHasMedia() async throws {
        for fps in [24, 30, 60] {
            let plan = Self.clapPlan(target: .export, w: 640, h: 360, fps: fps)
            let built = try await CompositionBuilder.build(plan: plan, options: try Self.buildOptions(session: nil))
            keep.append(built)
            let track = try XCTUnwrap(built.composition.track(withTrackID: try XCTUnwrap(built.trackIDBySeq[0])))
            let out = plan.canvas.outputGrid
            let frames = out.frameIndexOf(plan.durUs)
            var empty: [Int64] = []
            for k in 0..<frames {
                let t = out.cmTime(frame: k)
                if track.segment(forTrackTime: t)?.isEmpty ?? true { empty.append(k) }
            }
            XCTAssertEqual(empty, [], "\(fps) fps: output frames without media on slot 0")
            // A frozen-frame edit of the whole last sample (frame 179 at 5.9667 s) holds each layer to
            // its end, at 1× until then.
            let frozen = try XCTUnwrap(built.sources.media["md_clap0000001"]?.lastVideoSample, "\(fps) fps: last sample read")
            XCTAssertEqual(CMTimeGetSeconds(frozen.start), 179.0 / 30, accuracy: 1e-4)
            XCTAssertEqual(CMTimeGetSeconds(frozen.end), 6.0, accuracy: 1e-4)
            // Laid like the spacer: one edit of the sample at an integral scale, then an unscaled
            // remainder (a prefix of the sample), ending exactly at each layer's end (4 s, 6 s).
            let holds = track.segments.filter { !$0.isEmpty && CMTimeCompare($0.timeMapping.source.start, frozen.start) == 0 }
            XCTAssertEqual(
                Set(holds.map { CMTimeGetSeconds($0.timeMapping.target.end) }).isSuperset(of: [4.0, 6.0]), true,
                "\(fps) fps: holds end at the layer ends: \(holds.map { CMTimeGetSeconds($0.timeMapping.target.end) })")
            for h in holds {
                let scale = CMTimeGetSeconds(h.timeMapping.target.duration) / CMTimeGetSeconds(h.timeMapping.source.duration)
                XCTAssertEqual(scale, scale.rounded(), accuracy: 1e-6, "\(fps) fps: integral scale")
                XCTAssertLessThanOrEqual(CMTimeCompare(h.timeMapping.source.duration, frozen.duration), 0)
            }
            let playedA = try XCTUnwrap(track.segments.first { !$0.isEmpty })
            XCTAssertEqual(
                CMTimeGetSeconds(playedA.timeMapping.target.duration), CMTimeGetSeconds(playedA.timeMapping.source.duration), accuracy: 1e-6,
                "\(fps) fps: A plays at 1×, not stretched")
        }
    }

    func testComposedFramesHoldTheLastSourceFrameAt24_30And60() async throws {
        for fps in [24, 30, 60] {
            let plan = Self.clapPlan(target: .export, w: 640, h: 360, fps: fps)
            let snapshot = ParamSnapshot(plan: plan)
            let session = try CompositorTestSupport.session(snapshot: snapshot)
            let built = try await CompositionBuilder.build(plan: plan, options: try Self.buildOptions(session: session))
            keep.append(built)
            var stamps: [Int64] = []
            var problems: [String] = []
            var held = 0
            try CompositorTestSupport.readFrames(built) { k, _, pb in
                guard let k else { return problems.append("unstamped frame") }
                stamps.append(k)
                let want = Self.wanted(plan, k: k, last: Self.clapLast)
                if want == Self.clapLast { held += 1 }
                let got = CompositorTestSupport.barcode(pb)
                if got != want { problems.append("\(fps) fps frame \(k): \(String(describing: got)) != \(String(describing: want))") }
            }
            let total = plan.canvas.outputGrid.frameIndexOf(plan.durUs)
            XCTAssertEqual(stamps, Array(0..<total), "\(fps) fps: every frame composed once")
            XCTAssertGreaterThan(held, fps, "\(fps) fps: over a second of held frames")
            XCTAssertTrue(problems.isEmpty, problems.prefix(20).joined(separator: "\n"))
        }
    }

    /// Frames of [built] read from [start] for [seconds] the way a segmented export reads them (an
    /// anchored composition copy, `ExportSpacer`); nil when the reader stalls (8 s watchdog).
    private func readSegment(_ built: BuiltComposition, from start: CMTime, seconds: Double) throws -> [Int64: Int?]? {
        let copy = try XCTUnwrap(built.composition.mutableCopy() as? AVMutableComposition)
        try ExportSpacer.anchor(copy, built: built, at: start)
        let reader = try AVAssetReader(asset: copy)
        reader.timeRange = CMTimeRange(start: start, duration: CMTime(seconds: seconds, preferredTimescale: 600))
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

    func testReadersStartingInsideTheHoldDeliverEveryFrame() async throws {
        // Segmented export opens readers at arbitrary times; one opening inside the frozen-frame
        // edit must get frames. A hold whose source started inside the last sample stalled the
        // export at its first segment inside the hold, and readers opening at some frames inside a
        // one-sample edit never got a frame until ExportSpacer split the hold at the reader start.
        let plan = Self.clapPlan(target: .export, w: 640, h: 360, fps: 30)
        let session = try CompositorTestSupport.session(snapshot: ParamSnapshot(plan: plan))
        let built = try await CompositionBuilder.build(plan: plan, options: try Self.buildOptions(session: session))
        keep.append(built)
        var problems: [String] = []
        // Around both play → hold seams and spread over both holds (each reader holds decoders for a
        // while after it ends, so not every frame).
        for k0: Int64 in [88, 89, 90, 91, 92, 95, 100, 105, 110, 115, 119, 154, 155, 156, 157, 160, 165, 170, 175] {
            guard let frames = try readSegment(built, from: CMTime(value: k0, timescale: 30), seconds: 0.3) else {
                // A stalled reader is left blocked; later readers would not start.
                problems.append("reader from frame \(k0) stalled")
                break
            }
            let want = Set((k0..<min(k0 + 9, 180)))
            if Set(frames.keys) != want { problems.append("reader from \(k0): frames \(frames.keys.sorted())") }
            for (k, code) in frames where code != Self.wanted(plan, k: k, last: Self.clapLast) {
                problems.append("reader from \(k0): frame \(k) shows \(String(describing: code))")
            }
        }
        XCTAssertTrue(problems.isEmpty, problems.joined(separator: "\n"))
    }

    // MARK: Preview

    func testPreviewSeeksShowTheHeldLastFrame() async throws {
        let h = try PreviewHarness()
        preview = h
        await h.start()
        let plan = Self.clapPlan()
        _ = try await h.setPlan(plan)
        var frames: [Int64] = Array(84...96) + Array(110...125) + Array(150...179)
        frames += [0, 60, 119, 179, 140, 165, 90, 156]
        var problems: [String] = []
        for k in frames {
            let ack = try await h.seek(frame: k)
            if ack.displayedFrame != k { problems.append("seek \(k): acked \(ack.displayedFrame)") }
            let pb = try XCTUnwrap(h.session.bridge.current?.buffer)
            if DVRenderSession.frameIndex(of: pb) != k { problems.append("seek \(k): stamp \(String(describing: DVRenderSession.frameIndex(of: pb)))") }
            let want = Self.wanted(plan, k: k, last: Self.clapLast)
            let got = CompositorTestSupport.barcode(pb, region: PreviewHarness.baseRegion)
            if got != want { problems.append("seek \(k): \(String(describing: got)) != \(String(describing: want))") }
        }
        XCTAssertTrue(problems.isEmpty, problems.prefix(20).joined(separator: "\n"))
    }

    // MARK: Audio

    /// The composition's mix read the IOS-12 way (redone when AVFoundation hands back a bad read).
    private func mixRead(_ plan: RenderPlan) async throws -> [Float] {
        let options = try Self.buildOptions(session: nil)
        let frames = Int(Double(plan.durUs) * 0.048)
        let (read, _) = try await AudioTapSupport.readValidated(expectFrames: frames - 4_800) {
            let built = try await CompositionBuilder.build(plan: plan, options: options)
            keep.append(built)
            return (built.composition, try XCTUnwrap(built.audioMix), [], built.gainTaps)
        }
        // Without a time range the mix output ends with the last audio media; the rest is silence
        // (the export reads [0, end) and fills it, see the export tests).
        var x = read.leftChannel
        if x.count < frames { x += [Float](repeating: 0, count: frames - x.count) }
        return x
    }

    /// Index (48 kHz) of the last sample above [threshold] in [a, b) s, nil when none.
    private static func lastAbove(_ x: [Float], _ threshold: Float, from a: Double, to b: Double) -> Int? {
        let lo = max(0, Int(a * 48_000))
        let hi = min(x.count, Int(b * 48_000))
        guard lo < hi else { return nil }
        return (lo..<hi).last { abs(x[$0]) > threshold }
    }

    func testAudioIsSilentPastTheSourceEndAndStopsThere() async throws {
        let x = try await mixRead(Self.tonePlan())
        func db(_ a: Double, _ b: Double) -> Double { AudioTapSupport.rmsDb(x, Int(a * 48_000), Int(b * 48_000)) }
        // 1× part: tone until the source end at 2.0 s, silence to 3.0 s.
        XCTAssertGreaterThan(db(0.1, 1.9), -20, "1× tone")
        XCTAssertLessThan(db(2.02, 2.98), -70, "1× tail silent")
        let end1 = Double(try XCTUnwrap(Self.lastAbove(x, 0.03, from: 1.8, to: 2.9))) / 48_000
        XCTAssertEqual(end1, 2.0, accuracy: 0.005, "1× audio stops at the source end")
        // 2× varispeed part: tone until 4.5 s, silence to 5.0 s.
        XCTAssertGreaterThan(db(3.1, 4.4), -20, "2× tone")
        XCTAssertLessThan(db(4.52, 4.95), -70, "2× tail silent")
        let end2 = Double(try XCTUnwrap(Self.lastAbove(x, 0.03, from: 4.3, to: 4.95))) / 48_000
        XCTAssertEqual(end2, 4.5, accuracy: 0.005, "2× audio stops at the source end")
    }

    func testClicksStayInSyncOnLayersPastTheirSource() async throws {
        let x = try await mixRead(Self.clapPlan())
        // Source click 4.0 s: A 1× from 3.0 → 1.0 s; B 2× from 3.6 at 4.0 → 4.2 s. Onset bias +2.1 ms
        // (QA-03, the Hann click's 10 % point).
        for t in [1_000_000.0, 4_200_000] {
            let on = try XCTUnwrap(PitchSyncTests.onset(x, near: t), "click near \(t / 1e6) s")
            XCTAssertEqual(on - t - 2_100, 0, accuracy: 5_000, "click at \(t / 1e6) s")
        }
        XCTAssertNil(PitchSyncTests.onset(x, near: 1_333_333), "no stretched click")
    }

    func testKeepPitchPieceFarPastItsSourceKeepsItsCompensation() async throws {
        // 0.5× keep pitch from 3.7 s over 10 s: the source (6 s) ends at 4.6 s, so most of the piece
        // is past it. Its audible part keeps the time-pitch compensation (the old guard dropped it:
        // the trim at the source end counted as trimming the piece away).
        let url = try XCTUnwrap(TestFixtures.url(.engine, "media/clap_flash_av.mp4"))
        let seg = AudioSeg(
            id: "it_k000000001#a", asset: "md_clap0000001", t0: 0, t1: 10_000_000, map: [MapSegment(0, 10_000_000, 3_700_000, 8_700_000)],
            gain: [AnimKey(0, 1)], pitch: true)
        let plan = RenderPlan(
            rev: 1, target: .export, canvas: PlanCanvas(w: 64, h: 64, fps: 30), durUs: 10_000_000,
            assets: ["md_clap0000001": PlanAsset(kind: .video, uri: url.absoluteString, w: 1280, h: 720, durUs: 6_000_000, hasAudio: true)],
            layers: [], audio: [seg])
        let layout = AudioMixLayout.make(plan, rampSeams: false)
        let delta = AudioMixLayout.pitchCompensationUs(rate: 0.5)
        let piece = try XCTUnwrap(layout.pieces.first)
        XCTAssertEqual(piece.segment.s0, 3_700_000 + delta, "shifted")
        XCTAssertEqual(piece.segment.s1 + Int64((Double(piece.postUs) * 0.5).rounded()), 6_000_000, accuracy: 1, "trimmed to the source end")

        let x = try await mixRead(plan)
        // Click 4.0 s → 0.6 s.
        let on = try XCTUnwrap(PitchSyncTests.onset(x, near: 600_000))
        XCTAssertEqual(on - 600_000 - 2_100, 0, accuracy: 10_000, "0.5× keep-pitch click in sync")
        XCTAssertLessThan(AudioTapSupport.rmsDb(x, Int(4.7 * 48_000), Int(9.9 * 48_000)), -70, "silent past the source end")
    }

    // MARK: Export

    private func runExport(_ plan: RenderPlan, w: Int, h: Int) throws -> URL {
        let h0 = try ExportHarness()
        export = h0
        let output = h0.outputURL("mp4")
        let id = try h0.export(self, plan: PlanEncoder.encode(plan), settings: ExportPlans.settings(w, h, fps: plan.canvas.fps), output: output)
        if let failure = h0.recorder.failure(id) { XCTFail("export failed: \(failure.code) \(failure.message)") }
        XCTAssertNotNil(h0.recorder.done(id)?.exportResult)
        return output
    }

    func testExportHoldsTheLastFrameAndKeepsTheClicksInSync() throws {
        let plan = Self.clapPlan(target: .export, w: 640, h: 360, fps: 30)
        let output = try runExport(plan, w: 640, h: 360)
        var problems: [String] = []
        var count = 0
        try ExportConformance.frames(output) { pts, pb in
            let k = FrameGrid(30).frameIndexNearest(pts)
            count += 1
            let want = Self.wanted(plan, k: k, last: Self.clapLast)
            let got = CompositorTestSupport.barcode(pb)
            if got != want { problems.append("export frame \(k): \(String(describing: got)) != \(String(describing: want))") }
        }
        XCTAssertEqual(count, 180)
        XCTAssertTrue(problems.isEmpty, problems.prefix(20).joined(separator: "\n"))
        // Clicks (left channel of the AAC track): 1.0 s and 4.2 s, within one frame and 20 ms.
        let pcm = try ExportConformance.pcm(output)
        let left = stride(from: 0, to: pcm.count, by: 2).map { pcm[$0] }
        for t in [1_000_000.0, 4_200_000] {
            let on = try XCTUnwrap(PitchSyncTests.onset(left, near: t), "export click near \(t / 1e6) s")
            XCTAssertEqual(on - t, 0, accuracy: 20_000, "export click at \(t / 1e6) s")
        }
    }

    func testExportedToneStopsAtTheSourceEndOverTheHeldFrame() throws {
        let plan = Self.tonePlan(target: .export)
        let output = try runExport(plan, w: 640, h: 360)
        var problems: [String] = []
        try ExportConformance.frames(output) { pts, pb in
            let k = FrameGrid(30).frameIndexNearest(pts)
            let want = Self.wanted(plan, k: k, last: Self.toneLast)
            let got = CompositorTestSupport.barcode(pb)
            if got != want { problems.append("export frame \(k): \(String(describing: got)) != \(String(describing: want))") }
        }
        XCTAssertTrue(problems.isEmpty, problems.prefix(20).joined(separator: "\n"))
        let pcm = try ExportConformance.pcm(output)
        func db(_ a: Double, _ b: Double) -> Double { ExportConformance.rmsDb(pcm, channel: 0, Int(a * 48_000), Int(b * 48_000)) }
        XCTAssertGreaterThan(db(0.2, 1.9), -20, "1× tone")
        XCTAssertLessThan(db(2.05, 2.95), -60, "1× tail silent")
        XCTAssertGreaterThan(db(3.1, 4.4), -20, "2× tone")
        XCTAssertLessThan(db(4.55, 4.9), -60, "2× tail silent")
    }
}
