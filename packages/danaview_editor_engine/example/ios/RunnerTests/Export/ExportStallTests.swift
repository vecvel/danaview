// OWNER: FIX-IOS-EXPORT-STALL
//
// Exploratory reproduction of QA-05 D1 (work in progress).

import AVFoundation
import XCTest

@testable import danaview_editor_engine

final class ExportStallTests: XCTestCase {
    private var harnesses: [ExportHarness] = []

    override func tearDown() {
        harnesses.forEach { $0.remove() }
        harnesses = []
    }

    static func layer(_ id: String, asset: String, seq: Int, t0: Int64, t1: Int64, s0: Int64, rate: Double, w: Double, h: Double) -> String {
        let s1 = s0 + Int64((Double(t1 - t0) * rate).rounded())
        return "{\"id\":\"\(id)\",\"z\":10,\"seq\":\(seq),\"t\":[\(t0),\(t1)],\"kind\":\"media\",\"asset\":\"\(asset)\",\"map\":[[\(t0),\(t1),\(s0),\(s1)]],\"base\":[\(w),\(h)]}"
    }

    /// The soak-stall-165 project, approximated.
    static func soakPlan(images: Bool = true, audioOn: Bool = true, speeds: Bool = true, durUs: Int64 = 31_033_334) -> Data {
        let w = 1280.0, h = 720.0
        var layers: [String] = []
        var n = 0
        func media(_ t0: Int64, _ dur: Int64, _ s0: Int64, _ rate0: Double) {
            n += 1
            let rate = speeds ? rate0 : 1
            let s0 = speeds ? s0 : min(s0, 5_000_000)
            layers.append(layer(String(format: "it_v%011d#v", n), asset: "md_fc0000000001", seq: 0, t0: t0, t1: t0 + dur, s0: s0, rate: rate, w: w, h: h))
        }
        func image(_ t0: Int64, _ dur: Int64) {
            n += 1
            guard images else { return media(t0, dur, 1_000_000, 1) }
            layers.append(ExportPlans.imageLayer(String(format: "it_i%011d", n), asset: "md_still0000001", t0: t0, t1: t0 + dur, w: w, h: h))
        }
        media(0, 366_667, 6_849_999, 1.5)
        media(366_667, 366_667, 7_400_000, 1.5)
        media(733_334, 733_333, 6_849_999, 1.5)
        image(1_466_667, 3_000_000)
        image(4_466_667, 1_533_333)
        image(6_000_000, 1_133_334)
        image(7_133_334, 333_333)
        media(7_466_667, 666_667, 400_000, 1.5)
        media(8_133_334, 1_100_000, 2_600_000, 1.5)
        media(9_233_334, 1_733_333, 0, 1.5)
        image(10_966_667, 166_667)
        image(11_133_334, 1_300_000)
        image(12_433_334, 3_000_000)
        media(15_433_334, 666_666, 400_000, 1.5)
        media(16_100_000, 633_334, 5_600_000, 0.5)
        image(16_733_334, 1_300_000)
        media(18_033_334, 2_000_000, 5_600_000, 0.5)
        let audio = !audioOn ? [] : (0..<3).map { k -> String in
            let t0 = Int64(1_033_334 + k * 10_000_000)
            return ExportPlans.audioSeg(String(format: "it_a%011d#a", k), asset: "md_speech000001", t0: t0, t1: t0 + 10_000_000, s0: 0)
        }
        return ExportPlans.plan(
            w: 1280, h: 720, fps: 30, gridFps: 30, durUs: durUs,
            assets: [
                ExportPlans.video("md_fc0000000001", file: "frame_counter_1080p30.mp4", w: 1920, h: 1080, durUs: 8_000_000, hasAudio: false),
                ExportPlans.image("md_still0000001", file: "still_4k.jpg", w: 3840, h: 2160),
                ExportPlans.audio("md_speech000001", file: "speech_10s.m4a", durUs: 10_000_000),
            ],
            layers: layers, audio: audio)
    }

    private func run(_ name: String, _ plan: Data, rounds: Int = 1) throws {
        var options = ExportHarness.Options()
        options.segmentDurationUs = 10_000_000
        let h = try ExportHarness(options)
        harnesses.append(h)
        let settings = ExportPlans.settings(1280, 720, fps: 30, videoBitrate: 5_000_000, audioBitrate: 192_000)
        for round in 0..<rounds {
            let out = h.outputURL()
            let id = try h.start(self, plan: plan, settings: settings, output: out)
            let ended = JobEventRecorder.spin(timeout: 70) { h.recorder.ended(id) }
            let last = h.progress(id).last
            print("STALLTEST \(name) round \(round) ended=\(ended) last=\(String(describing: last?.framesDone))/\(String(describing: last?.framesTotal)) failure=\(String(describing: h.recorder.failure(id)?.message))")
            if !ended { try? h.cancel(self, id); return }
        }
    }

    func testV1NoAudio() throws { try run("noAudio", ExportStallTests.soakPlan(audioOn: false)) }
    func testV2NoImages() throws { try run("noImages", ExportStallTests.soakPlan(images: false)) }
    func testV3NoSpeeds() throws { try run("noSpeeds", ExportStallTests.soakPlan(speeds: false)) }
    func testV4Plain() throws { try run("plain", ExportStallTests.soakPlan(images: false, speeds: false)) }
    func testV5PlainNoAudio() throws { try run("plainNoAudio", ExportStallTests.soakPlan(images: false, audioOn: false, speeds: false)) }

    func skip_testSoakPlanExports() throws {
        var options = ExportHarness.Options()
        options.segmentDurationUs = 10_000_000
        let h = try ExportHarness(options)
        harnesses.append(h)
        let settings = ExportPlans.settings(1280, 720, fps: 30, videoBitrate: 5_000_000, audioBitrate: 192_000)
        for round in 0..<3 {
            let out = h.outputURL()
            let id = try h.start(self, plan: ExportStallTests.soakPlan(), settings: settings, output: out)
            let ended = JobEventRecorder.spin(timeout: 150) { h.recorder.ended(id) }
            let last = h.progress(id).last
            print("STALLTEST round \(round) ended=\(ended) last=\(String(describing: last?.framesDone))/\(String(describing: last?.framesTotal)) phase=\(String(describing: last?.phase))")
            XCTAssertTrue(ended, "round \(round) stalled at \(String(describing: last?.framesDone))")
            if !ended { return }
            XCTAssertNotNil(h.recorder.done(id), "round \(round) failed: \(String(describing: h.recorder.failure(id)?.message))")
        }
    }
}

final class ExportStallReaderProbe: XCTestCase {
    static var planVariant: (Bool, Bool, Bool) = (false, false, false)

    func probe(_ a: Int64, _ b: Int64, durUs: Int64 = 31_033_334, cancel: Bool = false, mode: Int = 0) throws {
        let h = try ExportHarness()
        defer { h.remove() }
        let plan = try RenderPlanDecoder.decodePlan(ExportStallTests.soakPlan(images: false, audioOn: false, speeds: false, durUs: durUs))
        let paths = h.paths
        let session = try DVRenderSession(snapshots: ParamSnapshotStore(ParamSnapshot(plan: plan)), qos: .userInitiated)
        var options = CompositionBuildOptions(spacerDirectory: paths.engineAssets)
        options.renderSize = CGSize(width: plan.canvas.w, height: plan.canvas.h)
        options.validate = false
        options.resolveURL = { _, asset in
            let name = URL(string: asset.uri)?.lastPathComponent ?? ""
            return TestFixtures.url(.engine, "media/\(name)")!
        }
        session.configure(&options)
        let input = UncheckedSendable((plan, options))
        let built = try MediaBlocking.await { try await CompositionBuilder.build(plan: input.value.0, options: input.value.1) }
        let comp = ExportComposition(built: built, session: session)
        var c: AVComposition = comp.built.composition
        if mode == 3 { try ExportSpacer.anchor(comp.built, at: ExportTime.readerRange(startUs: a, endUs: b, plan: plan).start) }
        if mode == 2 {
            let m = comp.built.composition.mutableCopy() as! AVMutableComposition
            for t in m.tracks(withMediaType: .video) where CMTimeCompare(t.timeRange.end, m.duration) < 0 {
                let end = t.timeRange.end
                t.insertEmptyTimeRange(CMTimeRange(start: end, end: m.duration))
            }
            c = m
        }
        print("PROBE composition duration \(c.duration.seconds) tracks:")
        for t in c.tracks {
            print("PROBE   track \(t.trackID) \(t.mediaType.rawValue) range \(t.timeRange.start.seconds)-\(t.timeRange.end.seconds) segs \(t.segments.count) last \(t.segments.last.map { "\($0.timeMapping.target.start.seconds)+\($0.timeMapping.target.duration.seconds) empty=\($0.isEmpty)" } ?? "-")")
        }
        let reader = try AVAssetReader(asset: c)
        reader.timeRange = ExportTime.readerRange(startUs: a, endUs: b, plan: plan)
        var tracks = c.tracks(withMediaType: .video)
        if mode == 1 {
            let range = reader.timeRange
            tracks = tracks.filter { CMTimeCompare($0.timeRange.end, range.start) > 0 }
        }
        let output = AVAssetReaderVideoCompositionOutput(videoTracks: tracks, videoSettings: CompositionVideoSource.videoSettings)
        output.videoComposition = comp.built.videoComposition
        reader.add(output)
        let started = reader.startReading()
        print("PROBE mode \(mode) tracks \(tracks.map(\.trackID)) started=\(started) error=\(String(describing: reader.error))")
        let q = DispatchQueue(label: "probe")
        let lock = NSLock()
        var frames = 0
        var last = CMTime.invalid
        let done = DispatchSemaphore(value: 0)
        q.async {
            while let s = output.copyNextSampleBuffer() {
                lock.lock(); frames += 1; last = CMSampleBufferGetPresentationTimeStamp(s); lock.unlock()
            }
            done.signal()
        }
        let hung = done.wait(timeout: .now() + 15) == .timedOut
        lock.lock(); let f = frames; let l = last; lock.unlock()
        print("PROBE [\(a),\(b)) dur \(durUs) hung=\(hung) frames=\(f) last=\(l.seconds) status=\(reader.status.rawValue)")
        XCTAssertFalse(hung, "[\(a),\(b)) hung after \(f) frames")
        if hung && cancel {
            let cs = DispatchSemaphore(value: 0)
            DispatchQueue.global().async { reader.cancelReading(); cs.signal() }
            let returned = cs.wait(timeout: .now() + 10) == .success
            let ended = done.wait(timeout: .now() + 5) == .success
            print("PROBE cancel returned=\(returned) copy ended=\(ended)")
        }
        if hung { Thread.sleep(forTimeInterval: 1); exit(0) }
        comp.release()
    }

    func testC1_anchor_30_end() throws { try probe(30_000_000, 31_033_334, mode: 3) }
    func testC2_anchor_21_25() throws { try probe(21_000_000, 25_000_000, mode: 3) }
    func testC3_anchor_10_20() throws { try probe(10_000_000, 20_000_000, mode: 3) }
    func testC4_anchor_0_end() throws { try probe(0, 31_033_334, mode: 3) }
}
