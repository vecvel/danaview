// OWNER: FIX-IOS-EXPORT-STALL
//
// QA-05 soak defects D1 and D2 (docs/v1.1/editor/qa/QA-05-soak.md), reproduced and fixed.
//
// D1, root cause. IOS-08 lays the one-frame spacer as ONE edit scaled across the whole timeline,
// so the spacer track holds a single sample starting at 0. An AVAssetReaderVideoCompositionOutput
// whose timeRange starts where no media track has a sample (after the last media frame, or in a
// stretch of images, text and gaps) never delivers a frame: copyNextSampleBuffer blocks forever.
// The soak project (seed 5150, `soak-stall-165.json`: video lane to 20.03 s, speech to 31.03 s)
// stalled when the export's last segment [30 s, 31.03 s) opened its reader. The fix
// (`ExportSpacer`) re-lays the spacer before each segment reader so a sample starts at the
// reader's start. Tests: the reader probe (with and without the anchor), the soak project, and
// seeded random plans whose video ends before the audio.
//
// D2. The stuck pipeline never returned, the job stayed in the coordinator's table and every later
// export failed with `busy` (Dart: exportFailed.unknown). Now the writer's waits are bounded
// (stall timeout, stop grace, a failed writer), the coordinator has a heartbeat watchdog and a
// cancel grace, and every job runs on its own work queue, so a pipeline left blocked inside
// AVFoundation never blocks the coordinator. Tests: the real hang (anchor disabled) fails with the
// typed stall error and the next exports succeed; a cancelled stalled job ends at once and the
// next exports succeed; a seeded injected stall inside the pump and a blocked composition factory
// (watchdog backstop) both end with the typed error.

import AVFoundation
import XCTest

@testable import danaview_editor_engine

// MARK: - Plans

enum StallPlans {
    static let fc = "md_fc0000000001"
    static let still = "md_still0000001"
    static let speech = "md_speech000001"

    static func assets() -> [String] {
        [
            ExportPlans.video(fc, file: "frame_counter_1080p30.mp4", w: 1920, h: 1080, durUs: 8_000_000, hasAudio: false),
            ExportPlans.image(still, file: "still_4k.jpg", w: 3840, h: 2160),
            ExportPlans.audio(speech, file: "speech_10s.m4a", durUs: 10_000_000),
        ]
    }

    /// A media layer of frame_counter at [rate] (source from [s0]).
    static func media(_ n: Int, seq: Int = 0, t0: Int64, t1: Int64, s0: Int64, rate: Double, w: Double, h: Double, z: Int = 10) -> String {
        let s1 = s0 + Int64((Double(t1 - t0) * rate).rounded())
        return "{\"id\":\"\(String(format: "it_v%011d#v", n))\",\"z\":\(z),\"seq\":\(seq),\"t\":[\(t0),\(t1)],\"kind\":\"media\",\"asset\":\"\(fc)\","
            + "\"map\":[[\(t0),\(t1),\(s0),\(s1)]],\"base\":[\(w),\(h)]}"
    }

    static func image(_ n: Int, t0: Int64, t1: Int64, w: Double, h: Double) -> String {
        ExportPlans.imageLayer(String(format: "it_i%011d", n), asset: still, t0: t0, t1: t1, w: w, h: h)
    }

    static func speechSeg(_ n: Int, t0: Int64, t1: Int64) -> String {
        ExportPlans.audioSeg(String(format: "it_a%011d#a", n), asset: speech, t0: t0, t1: t1, s0: 0)
    }

    /// The soak's stalled project (`soak-stall-165.json`, seed 5150 op 165) as an export plan at
    /// 1280×720 30 fps: the main lane's 1.5×, 0.5× and reversed pieces of frame_counter (the
    /// reversed renditions read as forward pieces of the same frames), the freeze stills and 4K
    /// stills as images, the video lane ending at 20.03 s, and three 10 s copies of the speech clip
    /// on the audio lane to 31.03 s (the text sprites are left out: they do not reach the reader).
    static func soakStall165(w: Double = 1280, h: Double = 720) -> Data {
        var layers: [String] = []
        var n = 0
        func clip(_ t0: Int64, _ dur: Int64, _ s0: Int64, _ rate: Double) {
            n += 1
            layers.append(media(n, t0: t0, t1: t0 + dur, s0: s0, rate: rate, w: w, h: h))
        }
        func picture(_ t0: Int64, _ dur: Int64) {
            n += 1
            layers.append(image(n, t0: t0, t1: t0 + dur, w: w, h: h))
        }
        clip(0, 366_667, 6_849_999, 1.5)
        clip(366_667, 366_667, 7_400_000, 1.5)
        clip(733_334, 733_333, 6_849_999, 1.5)
        picture(1_466_667, 3_000_000)
        picture(4_466_667, 1_533_333)
        picture(6_000_000, 1_133_334)
        picture(7_133_334, 333_333)
        clip(7_466_667, 666_667, 400_000, 1.5)
        clip(8_133_334, 1_100_000, 2_600_000, 1.5)
        clip(9_233_334, 1_733_333, 0, 1.5)
        picture(10_966_667, 166_667)
        picture(11_133_334, 1_300_000)
        picture(12_433_334, 3_000_000)
        clip(15_433_334, 666_666, 400_000, 1.5)
        clip(16_100_000, 633_334, 5_600_000, 0.5)
        picture(16_733_334, 1_300_000)
        clip(18_033_334, 2_000_000, 5_600_000, 0.5)
        let audio = (0..<3).map { k -> String in
            let t0 = Int64(1_033_334 + k * 10_000_000)
            return speechSeg(k, t0: t0, t1: t0 + 10_000_000)
        }
        return ExportPlans.plan(
            w: Int(w), h: Int(h), fps: 30, gridFps: 30, durUs: 31_033_334, assets: assets(), layers: layers, audio: audio)
    }

    /// Plain frame_counter pieces to 20.03 s on a longer plan without audio (the reduced case).
    static func videoEndsEarly(durUs: Int64 = 31_033_334, w: Double = 320, h: Double = 180) -> Data {
        var layers: [String] = []
        var t: Int64 = 0
        var n = 0
        while t < 20_033_334 {
            let t1 = min(20_033_334, t + 4_000_000)
            n += 1
            layers.append(media(n, t0: t, t1: t1, s0: 1_000_000, rate: 1, w: w, h: h))
            t = t1
        }
        return ExportPlans.plan(w: Int(w), h: Int(h), fps: 30, gridFps: 30, durUs: durUs, assets: assets(), layers: layers)
    }

    /// A small deterministic generator (SplitMix64).
    struct Rng {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        mutating func int(_ range: ClosedRange<Int>) -> Int { range.lowerBound + Int(next() % UInt64(range.count)) }
        mutating func pick<T>(_ items: [T]) -> T { items[int(0...(items.count - 1))] }
    }

    /// Frame-aligned time of [k] frames at 30 fps (the plan's ceil grid).
    static func frame(_ k: Int) -> Int64 { FrameGrid(30).timeOfFrame(Int64(k)) }

    /// A seeded random plan in the soak's shape: a main lane of frame_counter pieces (0.5×–2×),
    /// stills and gaps that ends before the plan does, an optional PiP lane that ends early, and
    /// speech clips running past the video (so segment readers open past every media track).
    static func random(seed: UInt64, w: Double = 640, h: Double = 360) -> (plan: Data, durUs: Int64) {
        var rng = Rng(state: seed)
        let videoFrames = rng.int(150...600)
        let totalFrames = videoFrames + rng.int(60...360)
        var layers: [String] = []
        var n = 0
        var k = 0
        while k < videoFrames {
            let len = min(videoFrames - k, rng.int(10...90))
            n += 1
            switch rng.int(0...5) {
            case 0, 1, 2:
                let rate = rng.pick([0.5, 1, 1.5, 2])
                let srcMax = 8_000_000 - Int64((Double(frame(len)) * rate).rounded()) - 40_000
                let s0 = srcMax > 0 ? Int64(rng.int(0...Int(srcMax / 1000))) * 1000 : 0
                layers.append(media(n, t0: frame(k), t1: frame(k + len), s0: s0, rate: rate, w: w, h: h))
            case 3, 4:
                layers.append(image(n, t0: frame(k), t1: frame(k + len), w: w, h: h))
            default:
                break // a gap
            }
            k += len
        }
        if rng.int(0...1) == 1 {
            // A PiP lane on its own decoder track that ends early.
            let a = rng.int(0...max(0, videoFrames / 2))
            let b = min(videoFrames, a + rng.int(30...120))
            n += 1
            layers.append(media(n, seq: 1, t0: frame(a), t1: frame(b), s0: 0, rate: 1, w: w / 3, h: h / 3, z: 20))
        }
        var audio: [String] = []
        var a = rng.int(0...30)
        var m = 0
        while a < totalFrames {
            let len = min(totalFrames - a, 300)
            audio.append(speechSeg(m, t0: frame(a), t1: frame(a + len)))
            m += 1
            a += len
        }
        let durUs = frame(totalFrames)
        return (ExportPlans.plan(w: Int(w), h: Int(h), fps: 30, gridFps: 30, durUs: durUs, assets: assets(), layers: layers, audio: audio), durUs)
    }
}

// MARK: - Tests

final class ExportStallTests: XCTestCase {
    private var harnesses: [ExportHarness] = []

    override func tearDown() {
        ExportSpacer.isEnabled = true
        harnesses.forEach { $0.remove() }
        harnesses = []
    }

    private func make(segmentUs: Int64 = 10_000_000, configure: (inout ExportEnvironment) -> Void = { _ in }) throws -> ExportHarness {
        var options = ExportHarness.Options()
        options.segmentDurationUs = segmentUs
        let h = try ExportHarness(options)
        configure(&h.coordinator.environment)
        harnesses.append(h)
        return h
    }

    private func settings(_ w: Int, _ h: Int) -> EncodeSettingsMsg {
        ExportPlans.settings(w, h, fps: 30, videoBitrate: w >= 1280 ? 5_000_000 : 1_500_000, audioBitrate: 192_000)
    }

    /// Starts [plan] and waits (bounded) for its end; fails the test when it does not end.
    @discardableResult
    private func export(_ h: ExportHarness, _ plan: Data, _ s: EncodeSettingsMsg, timeout: TimeInterval = 150,
                        file: StaticString = #filePath, line: UInt = #line) throws -> (id: String, output: URL, ended: Bool) {
        let out = h.outputURL()
        let id = try h.start(self, plan: plan, settings: s, output: out)
        let ended = JobEventRecorder.spin(timeout: timeout) { h.recorder.ended(id) }
        if !ended {
            let last = h.progress(id).last
            XCTFail("export did not end within \(Int(timeout)) s (stalled at \(last?.framesDone ?? -1)/\(last?.framesTotal ?? -1))", file: file, line: line)
        }
        return (id, out, ended)
    }

    private func assertCompleted(_ h: ExportHarness, _ id: String, _ out: URL, durUs: Int64, s: EncodeSettingsMsg,
                                 file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertNotNil(h.recorder.done(id), "failed: \(h.recorder.failure(id)?.message ?? "-")", file: file, line: line)
        guard h.recorder.done(id) != nil else { return }
        try ExportConformance.check(out, settings: s, durUs: durUs, brand: "mp42", codec: "avc1", checkBitrate: false, file: file, line: line)
    }

    private func assertReleased(_ h: ExportHarness, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(h.onExportQueue { h.coordinator.jobIds }, [], "no job left in the coordinator", file: file, line: line)
        if let suspender = h.coordinator.previewSuspender as? CountingSuspender {
            let (s, r) = suspender.counts
            XCTAssertEqual(s, r, "preview suspension balanced", file: file, line: line)
        }
        XCTAssertEqual(h.interruption.registeredJobIds, [], "JobInterruption registrations released", file: file, line: line)
    }

    /// The live fraction of [id] (the progress events are throttled).
    private func fraction(_ h: ExportHarness, _ id: String) -> Double {
        h.onExportQueue { h.coordinator.job(id)?.fraction ?? 0 }
    }

    // MARK: D1 root cause

    /// Reads [startUs, endUs) of the export composition of [plan] on a private queue; returns the
    /// frames read, or nil when the reader hung: no frame for [stallTimeout] s (the AVFoundation hang
    /// delivers none at all), or still reading after [hardTimeout] s. A slow host that keeps
    /// delivering frames is not a hang (the hosted CI VM reads this 320×180 plan at well under
    /// 93 fps, so a fixed 10 s cap on the 931-frame range timed out while frames were still flowing).
    /// The hung reader is left alone: cancelling it while copyNextSampleBuffer blocks crashes.
    private func readFrames(_ h: ExportHarness, plan data: Data, startUs: Int64, endUs: Int64, anchor: Bool,
                            stallTimeout: TimeInterval = 10, hardTimeout: TimeInterval = 300) throws -> Int? {
        let plan = try RenderPlanDecoder.decodePlan(data)
        let built = try buildComposition(h, plan)
        let range = ExportTime.readerRange(startUs: startUs, endUs: endUs, plan: plan)
        if anchor { try ExportSpacer.anchor(built, at: range.start) }
        let reader = try AVAssetReader(asset: built.composition)
        reader.timeRange = range
        let output = AVAssetReaderVideoCompositionOutput(
            videoTracks: built.composition.tracks(withMediaType: .video), videoSettings: CompositionVideoSource.videoSettings)
        output.videoComposition = built.videoComposition
        reader.add(output)
        XCTAssertTrue(reader.startReading())
        let lock = NSLock()
        var frames = 0
        let done = DispatchSemaphore(value: 0)
        DispatchQueue(label: "com.vecvel.danaview.tests.stallprobe").async {
            while output.copyNextSampleBuffer() != nil {
                lock.lock()
                frames += 1
                lock.unlock()
            }
            done.signal()
        }
        let started = Date()
        var lastFrames = 0
        var lastProgress = started
        while done.wait(timeout: .now() + 0.25) == .timedOut {
            lock.lock()
            let n = frames
            lock.unlock()
            let now = Date()
            if n != lastFrames {
                lastFrames = n
                lastProgress = now
            }
            if now.timeIntervalSince(lastProgress) > stallTimeout || now.timeIntervalSince(started) > hardTimeout {
                lastProbe = "stall probe [\(startUs), \(endUs)) anchor \(anchor): hung after \(n) frames, "
                    + String(format: "%.1f s", now.timeIntervalSince(started))
                SegmentedWriter.keepAbandoned([reader, output, built])
                return nil
            }
        }
        built.releaseMedia()
        lock.lock()
        defer { lock.unlock() }
        lastProbe = "stall probe [\(startUs), \(endUs)) anchor \(anchor): \(frames) frames in "
            + String(format: "%.1f s", Date().timeIntervalSince(started))
        return frames
    }

    /// What the last [readFrames] saw (frames and time), for the assertion messages.
    private var lastProbe = ""

    private func buildComposition(_ h: ExportHarness, _ plan: RenderPlan) throws -> BuiltComposition {
        let session = try DVRenderSession(snapshots: ParamSnapshotStore(ParamSnapshot(plan: plan)), qos: .userInitiated)
        var options = CompositionBuildOptions(spacerDirectory: h.paths.engineAssets)
        options.renderSize = CGSize(width: plan.canvas.w, height: plan.canvas.h)
        options.validate = false
        options.resolveURL = { _, asset in
            let name = URL(string: asset.uri)?.lastPathComponent ?? ""
            guard let url = TestFixtures.url(.engine, "media/\(name)") else { throw EngineError(.mediaOffline, "fixture missing") }
            return url
        }
        session.configure(&options)
        let input = UncheckedSendable((plan, options))
        let built = try MediaBlocking.await { try await CompositionBuilder.build(plan: input.value.0, options: input.value.1) }
        SegmentedWriter.keepAbandoned([session]) // the compositor's session must outlive any reader
        return built
    }

    func testReaderStartingPastEveryMediaTrackNeedsTheSpacerAnchor() throws {
        let h = try make()
        let plan = StallPlans.videoEndsEarly()
        // The AVFoundation hang: a reader opening past the last media frame never delivers a frame.
        XCTAssertNil(try readFrames(h, plan: plan, startUs: 30_000_000, endUs: 31_033_334, anchor: false),
                     "hang reproduced (if this ever reads, the anchor may no longer be needed)")
        // With the anchor every range reads its exact frame count.
        XCTAssertEqual(try readFrames(h, plan: plan, startUs: 30_000_000, endUs: 31_033_334, anchor: true), 31, lastProbe)
        XCTAssertEqual(try readFrames(h, plan: plan, startUs: 21_000_000, endUs: 25_000_000, anchor: true), 120, lastProbe)
        XCTAssertEqual(try readFrames(h, plan: plan, startUs: 10_000_000, endUs: 20_000_000, anchor: true), 300, lastProbe)
        XCTAssertEqual(try readFrames(h, plan: plan, startUs: 0, endUs: 31_033_334, anchor: true), 931, lastProbe)
    }

    func testSpacerAnchorKeepsTheSpacerCoveringTheTimeline() throws {
        let h = try make()
        let plan = try RenderPlanDecoder.decodePlan(StallPlans.videoEndsEarly(durUs: 25_033_334))
        let built = try buildComposition(h, plan)
        defer { built.releaseMedia() }
        let spacer = try XCTUnwrap(built.composition.track(withTrackID: try XCTUnwrap(built.spacerTrackID)))
        let end = spacer.timeRange.end
        for startUs: Int64 in [10_000_000, 20_000_000, 0, 25_100_000, 7_123_456] {
            try ExportSpacer.anchor(built, at: FrameGrid.cmTime(us: startUs))
            XCTAssertEqual(CMTimeCompare(spacer.timeRange.start, .zero), 0)
            XCTAssertEqual(CMTimeCompare(spacer.timeRange.end, end), 0, "the spacer still ends on the grid end")
            let edits = spacer.segments.filter { !$0.isEmpty }
            if startUs > 0 && startUs < FrameGrid.us(end) {
                XCTAssertTrue(edits.contains { CMTimeCompare($0.timeMapping.target.start, FrameGrid.cmTime(us: startUs)) == 0 },
                              "a spacer edit starts at \(startUs)")
            }
            let covered = edits.reduce(CMTime.zero) { CMTimeAdd($0, $1.timeMapping.target.duration) }
            XCTAssertEqual(CMTimeCompare(covered, end), 0, "no gap in the spacer")
        }
    }

    func testSoakStallProjectExportsCompletely() throws {
        let h = try make()
        let s = settings(1280, 720)
        let r = try export(h, StallPlans.soakStall165(), s)
        guard r.ended else { return }
        try assertCompleted(h, r.id, r.output, durUs: 31_033_334, s: s)
        XCTAssertEqual(h.progress(r.id).last?.framesTotal, 931)
        assertReleased(h)
    }

    func testSeededRandomPlansWithVideoEndingEarlyNeverStall() throws {
        let h = try make(segmentUs: 5_000_000)
        let s = settings(640, 360)
        for k in 0..<3 {
            let (plan, durUs) = StallPlans.random(seed: 5150 &+ UInt64(k))
            let r = try export(h, plan, s, timeout: 120)
            guard r.ended else { return }
            try assertCompleted(h, r.id, r.output, durUs: durUs, s: s)
            try? FileManager.default.removeItem(at: r.output)
        }
        assertReleased(h)
    }

    // MARK: D1 watchdog and D2 recovery

    func testRealReaderHangFailsWithTypedStallAndLaterExportsSucceed() throws {
        let h = try make(segmentUs: 10_000_000) { env in
            env.stallTimeout = 4
            env.watchdogSlack = 30
        }
        let s = settings(320, 180)
        let before = SegmentedWriter.abandonedCount
        ExportSpacer.isEnabled = false
        let stuck = try export(h, StallPlans.videoEndsEarly(), s, timeout: 120)
        ExportSpacer.isEnabled = true
        guard stuck.ended else { return }
        let failure = try XCTUnwrap(h.recorder.failure(stuck.id), "the stalled export fails instead of hanging")
        XCTAssertEqual(failure.code, "decodeFailed")
        XCTAssertTrue(failure.message.contains("stalled"), failure.message)
        XCTAssertGreaterThan(SegmentedWriter.abandonedCount, before, "the blocked reader is left alone")
        XCTAssertFalse(FileManager.default.fileExists(atPath: stuck.output.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: ExportJob.directory(for: stuck.id, work: h.paths.work).path))
        assertReleased(h)
        // QA-05 D2: every later export in the process used to fail; now they all succeed.
        for k in 0..<2 {
            let durUs = Int64(22_033_334 + k * 1_000_000)
            let r = try export(h, StallPlans.videoEndsEarly(durUs: durUs), s)
            guard r.ended else { return }
            try assertCompleted(h, r.id, r.output, durUs: durUs, s: s)
        }
        assertReleased(h)
    }

    func testCancellingAStalledExportReleasesEverythingAndLaterExportsSucceed() throws {
        let h = try make(segmentUs: 10_000_000) { env in
            env.stallTimeout = 600
            env.watchdogSlack = 600
            env.stopGrace = 1
        }
        let s = settings(320, 180)
        ExportSpacer.isEnabled = false
        let out = h.outputURL()
        let id = try h.start(self, plan: StallPlans.videoEndsEarly(), settings: s, output: out)
        // Wait for the stall: the reader of the last segment (from 30 s) never delivers a frame.
        XCTAssertTrue(JobEventRecorder.spin(timeout: 120) { self.fraction(h, id) >= 0.96 }, "rendered to the last segment")
        _ = JobEventRecorder.spin(timeout: 3) { false }
        XCTAssertFalse(h.recorder.ended(id), "stalled")
        ExportSpacer.isEnabled = true
        let cancelAt = Date()
        try h.cancel(self, id)
        XCTAssertTrue(JobEventRecorder.spin(timeout: 15) { h.recorder.ended(id) }, "the cancel ends the stalled job")
        XCTAssertLessThan(Date().timeIntervalSince(cancelAt), 10)
        XCTAssertEqual(h.recorder.failure(id)?.code, "cancelled")
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: ExportJob.directory(for: id, work: h.paths.work).path))
        assertReleased(h)
        for k in 0..<3 {
            let durUs = Int64(21_033_334 + k * 2_000_000)
            let r = try export(h, StallPlans.videoEndsEarly(durUs: durUs), s)
            guard r.ended else { return }
            try assertCompleted(h, r.id, r.output, durUs: durUs, s: s)
        }
        assertReleased(h)
    }

    func testSeededInjectedPumpStallFailsTypedAndCancelOfAnInjectedStallEndsAtOnce() throws {
        let h = try make(segmentUs: 1_000_000) { env in
            env.stallTimeout = 2
            env.watchdogSlack = 30
            env.stopGrace = 1
        }
        var rng = StallPlans.Rng(state: 5150)
        let segment = rng.int(0...3)
        let frame = rng.int(0...20)
        h.coordinator.configurePipeline = { p in
            p.configureWriter = { $0.stallInjector = { seg, f in seg == segment && f == frame } }
        }
        let s = settings(320, 180)
        let plan = ExportPlans.noAudioVideo(w: 320, h: 180, fps: 30, durUs: 5_000_000)
        let stalled = try export(h, plan, s, timeout: 60)
        guard stalled.ended else { return }
        let failure = try XCTUnwrap(h.recorder.failure(stalled.id))
        XCTAssertEqual(failure.code, "decodeFailed", "blocked inside the source = reader stall")
        XCTAssertTrue(failure.message.contains("stalled"), failure.message)
        assertReleased(h)

        // A cancel while the pump is blocked ends within the stop grace.
        h.coordinator.environment.stallTimeout = 600
        let out = h.outputURL()
        let id = try h.start(self, plan: plan, settings: s, output: out)
        let blockedAt = Double(segment * 30 + frame) / 150
        XCTAssertTrue(JobEventRecorder.spin(timeout: 60) { self.fraction(h, id) >= blockedAt - 0.001 && h.onExportQueue { h.coordinator.job(id)?.phase == .rendering } })
        _ = JobEventRecorder.spin(timeout: 1) { false }
        XCTAssertFalse(h.recorder.ended(id), "blocked")
        try h.cancel(self, id)
        XCTAssertTrue(JobEventRecorder.spin(timeout: 10) { h.recorder.ended(id) })
        XCTAssertEqual(h.recorder.failure(id)?.code, "cancelled")
        assertReleased(h)

        // And the next export is fine.
        h.coordinator.configurePipeline = nil
        let r = try export(h, plan, s)
        guard r.ended else { return }
        try assertCompleted(h, r.id, r.output, durUs: 5_000_000, s: s)
        assertReleased(h)
    }

    func testWatchdogEndsAJobWithoutHeartbeatOutsideTheWriter() throws {
        let h = try make(segmentUs: 1_000_000) { env in
            env.stallTimeout = 1
            env.watchdogSlack = 1
            env.watchdogInterval = 0.25
        }
        let block = DispatchSemaphore(value: 0)
        h.coordinator.makeComposition = { _ in
            block.wait() // a composition build that does not return
            throw EngineError(.internal, "released")
        }
        let s = settings(320, 180)
        let plan = ExportPlans.noAudioVideo(w: 320, h: 180, fps: 30, durUs: 3_000_000)
        let started = Date()
        let stalled = try export(h, plan, s, timeout: 30)
        guard stalled.ended else { return }
        let failure = try XCTUnwrap(h.recorder.failure(stalled.id))
        XCTAssertEqual(failure.code, "encodingFailed")
        XCTAssertTrue(failure.message.contains("export stalled"), failure.message)
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(started), 2)
        XCTAssertGreaterThan(h.onExportQueue { h.coordinator.abandonedPipelines }, 0)
        assertReleased(h)

        // The next job runs on its own work queue; the blocked pipeline's late end is ignored.
        h.coordinator.makeComposition = nil
        let r = try export(h, plan, s)
        block.signal()
        guard r.ended else { return }
        try assertCompleted(h, r.id, r.output, durUs: 3_000_000, s: s)
        _ = JobEventRecorder.spin(timeout: 0.5) { false }
        assertReleased(h)
        XCTAssertNil(h.recorder.failure(r.id))
        XCTAssertEqual(h.recorder.events.filter { $0.jobId == stalled.id && $0.failure != nil }.count, 1, "one failure only")
    }

    func testThermalPauseIsNotAStall() throws {
        let state = ThermalBox()
        var options = ExportHarness.Options()
        options.segmentDurationUs = 1_000_000
        options.thermal = { state.value }
        let h = try ExportHarness(options)
        harnesses.append(h)
        h.coordinator.environment.stallTimeout = 1
        h.coordinator.environment.watchdogSlack = 0.5
        h.coordinator.environment.watchdogInterval = 0.25
        let s = settings(320, 180)
        let out = h.outputURL()
        state.value = .critical
        let id = try h.start(self, plan: ExportPlans.noAudioVideo(w: 320, h: 180, fps: 30, durUs: 2_000_000), settings: s, output: out)
        XCTAssertFalse(JobEventRecorder.spin(timeout: 4) { h.recorder.ended(id) }, "paused, not failed")
        state.value = .nominal
        XCTAssertTrue(JobEventRecorder.spin(timeout: 60) { h.recorder.ended(id) })
        try assertCompleted(h, id, out, durUs: 2_000_000, s: s)
        assertReleased(h)
    }
}

/// A thread-safe thermal state for the pumps.
final class ThermalBox {
    private let lock = NSLock()
    private var state: ProcessInfo.ThermalState = .nominal

    var value: ProcessInfo.ThermalState {
        get {
            lock.lock()
            defer { lock.unlock() }
            return state
        }
        set {
            lock.lock()
            state = newValue
            lock.unlock()
        }
    }
}
