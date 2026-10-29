// OWNER: FIX-IOS-D7
//
// QA-05 re-check defect D7 (docs/v1.1/editor/qa/QA-05-soak.md §2) and QA-01 FIX-IOS-12-1
// (docs/v1.1/editor/qa/QA-01-ios-simulator.md), reproduced and fixed.
//
// D7, the hang. AVAssetReaderAudioMixOutput over the soak project (seed 5150 op #800: 2× reversed
// keep-pitch pieces on one composition audio track) sometimes blocks inside copyNextSampleBuffer
// for good. On the iOS 26.5 simulator 0 to 3 of 8 fresh reads stopped for good per run (after
// 14–39 buffers, at 1.9–6.4 s, inside the 2× pieces) while the rest read all 39 s
// (`testSoakMixReadHangsSometimes` reports the rate; the export tests also met it on their own and
// resumed). That is AVFoundation, not the plan: the same composition reads fine the next time.
//
// D7, the crash. The old watchdog called cancelReading() on the blocked reader, and the source then
// released the reader while copyNextSampleBuffer was still inside it (the read closure held only the
// output, which does not keep its reader alive). `testHungMixReadIsLeftAloneAndTheExportResumes`
// reproduced it before the fix: the late copy raised "cannot copy next sample buffer before adding
// this output to an instance of AVAssetReader" (run b's SIGSEGV is the same use of a released
// reader). The fix (ReaderWriterPipeline.swift): every reader lives on one serial queue of its own,
// its closures hold the reader, output and composition, the watchdog only signals, and the read
// resumes on a fresh reader from the next frame, so the export completes.
//
// FIX-IOS-12-1. Back-to-back exports share nothing: each segment reads its own anchored copy of the
// composition, every audio read gets a fresh composition, and every phase's readers are torn down
// and their compositions released before the next phase or export starts
// (`testBackToBackSoakExportsTearDownEveryComposition`).

import AVFoundation
import XCTest

@testable import danaview_editor_engine

// MARK: - Plans

enum D7Plans {
    static let clap = "md_sG9lwX7dL35x"
    static let reversedTone = "md_mqsv3qMoSwQi"
    static let still = "md_mHOy52hYTUu0"
    static let speech = "md_NCHzmeMY4rLi"
    static let reversedFile = "reversed_tone_under_video.mp4"

    static func assets() -> [String] {
        [
            ExportPlans.video(clap, file: "clap_flash_av.mp4", w: 1280, h: 720, durUs: 6_000_000, hasAudio: true),
            ExportPlans.video(reversedTone, file: reversedFile, w: 1280, h: 720, durUs: 8_000_000, hasAudio: true),
            ExportPlans.image(still, file: "still_4k.jpg", w: 3840, h: 2160),
            ExportPlans.audio(speech, file: "speech_10s.m4a", durUs: 10_000_000),
        ]
    }

    static func layer(_ id: String, _ asset: String, _ t0: Int64, _ t1: Int64, _ s0: Int64, _ s1: Int64, w: Double, h: Double) -> String {
        "{\"id\":\"\(id)#v\",\"z\":10,\"seq\":0,\"t\":[\(t0),\(t1)],\"kind\":\"media\",\"asset\":\"\(asset)\","
            + "\"map\":[[\(t0),\(t1),\(s0),\(s1)]],\"base\":[\(w),\(h)]}"
    }

    static func seg(_ id: String, _ asset: String, _ t0: Int64, _ t1: Int64, _ s0: Int64, _ s1: Int64) -> String {
        "{\"id\":\"\(id)#a\",\"asset\":\"\(asset)\",\"t\":[\(t0),\(t1)],\"map\":[[\(t0),\(t1),\(s0),\(s1)]],\"gain\":[[\(t0),1]]}"
    }

    /// Main-lane clips of the soak project (`build/soak/ios/<udid>/rerun2-soak-a/soak-failed-800.json`,
    /// seed 5150 op #800) as CORE-33 compiles them for export: id, asset, t0, t1, s0, s1. The 2×
    /// reversed pieces read the reversed rendition (ReverseJob over tone_under_video).
    static let clips: [(String, String, Int64, Int64, Int64, Int64)] = [
        ("it_WNdu8PpAxY6d", clap, 0, 300_000, 3_933_333, 4_233_333),
        ("it_YFWb3brph4ES", clap, 300_000, 1_133_334, 4_233_333, 5_066_667),
        ("it_aoeUHJadyBDE", clap, 1_133_334, 2_066_667, 5_066_667, 6_000_000),
        ("it_O77jsQgKhGoG", reversedTone, 2_066_667, 2_866_667, 0, 1_600_000),
        ("it_Pml8t6VCxeW0", reversedTone, 2_866_667, 3_066_667, 1_600_000, 2_000_000),
        ("it_w5rGiGmtPXBl", reversedTone, 3_066_667, 5_033_334, 2_000_000, 5_933_334),
        ("it_YqXVCDXcx2zr", reversedTone, 5_033_334, 6_066_667, 5_933_334, 8_000_000),
        ("it_KdDXwTnTobmb", reversedTone, 6_066_667, 10_066_667, 0, 8_000_000),
        ("it_wtf0FQooybuc", clap, 13_066_667, 17_000_000, 0, 3_933_333),
    ]

    /// The last text ends at 39.03 s.
    static let durUs: Int64 = 39_033_334

    /// The soak project as an export plan at [w]×[h] 30 fps: the main lane (clips and two 4K
    /// stills), the music clip and the clips' audio. The four texts are left out (sprites never
    /// reach the readers); they only set the duration.
    static func soak800(w: Int = 320, h: Int = 180) -> Data {
        let W = Double(w), H = Double(h)
        var layers = clips.map { (t0: $0.2, json: layer($0.0, $0.1, $0.2, $0.3, $0.4, $0.5, w: W, h: H)) }
        layers.append((10_066_667, ExportPlans.imageLayer("it_wtA9BE8zi7pK#v", asset: still, t0: 10_066_667, t1: 11_500_000, w: W, h: H)))
        layers.append((11_500_000, ExportPlans.imageLayer("it_p3RqcVEHtbDf#v", asset: still, t0: 11_500_000, t1: 13_066_667, w: W, h: H)))
        layers.sort { $0.t0 < $1.t0 }
        // Compiled order: by start, then id.
        var audio = [(t0: Int64(0), id: "it_dVNOVTtWDHIE", json: seg("it_dVNOVTtWDHIE", speech, 0, 10_000_000, 0, 10_000_000))]
        audio += clips.map { (t0: $0.2, id: $0.0, json: seg($0.0, $0.1, $0.2, $0.3, $0.4, $0.5)) }
        audio.sort { ($0.t0, $0.id) < ($1.t0, $1.id) }
        return ExportPlans.plan(w: w, h: h, fps: 30, gridFps: 30, durUs: durUs, assets: assets(), layers: layers.map(\.json),
                                audio: audio.map(\.json))
    }
}

// MARK: - Support

/// Thread-safe bookkeeping of the tests' hooks.
final class D7Log {
    private let lock = NSLock()
    private var _teardownAt: [Date] = []
    private var _gateOpenedAt: Date?
    private var _sources: [MixAudioSource] = []
    private var _comps: [Weak] = []

    final class Weak {
        weak var value: ExportComposition?
        init(_ v: ExportComposition) { value = v }
    }

    func teardown() {
        lock.lock()
        _teardownAt.append(Date())
        lock.unlock()
    }

    func gateOpened() {
        lock.lock()
        _gateOpenedAt = Date()
        lock.unlock()
    }

    func add(_ s: MixAudioSource) {
        lock.lock()
        _sources.append(s)
        lock.unlock()
    }

    private var _hung = 0

    func hung() {
        lock.lock()
        _hung += 1
        lock.unlock()
    }

    /// Reads the watchdog gave up on (each one keeps its reader and composition until it returns).
    var hungReads: Int { locked { _hung } }

    func add(_ c: ExportComposition) {
        lock.lock()
        _comps.append(Weak(c))
        lock.unlock()
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    var teardowns: Int { locked { _teardownAt.count } }
    var teardownTimes: [Date] { locked { _teardownAt } }
    var gateOpenedAt: Date? { locked { _gateOpenedAt } }
    var sources: [MixAudioSource] { locked { _sources } }
    var made: Int { locked { _comps.count } }
    var alive: Int { locked { _comps.filter { $0.value != nil }.count } }
}

// MARK: - Tests

final class ExportD7Tests: XCTestCase {
    private static var reversedURL: URL?
    private static var reverseRoots: TempRoots?
    private var harnesses: [ExportHarness] = []

    override func tearDown() {
        harnesses.forEach { $0.remove() }
        harnesses = []
    }

    override class func tearDown() {
        reverseRoots?.remove()
        reverseRoots = nil
        reversedURL = nil
    }

    /// The reversed rendition of tone_under_video (0–8 s) made by IOS-07's ReverseJob, as the
    /// soak's reverse op made it (its AAC starts at 0.0209 s and ends at 7.956 s).
    static func reversedTone() throws -> URL {
        if let url = reversedURL, FileManager.default.fileExists(atPath: url.path) { return url }
        let roots = try TempRoots()
        let paths = try MediaJobTestSupport.paths(roots)
        let out = paths.derived.appendingPathComponent("d7-reversed-tone.mp4")
        let job = ReverseJob(mediaURL: try ProbeFixtures.url("tone_under_video.mp4"), fingerprint: "fp-d7", startUs: 0, endUs: 8_000_000,
                             audioStream: nil, output: out, paths: paths)
        _ = try job.run(JobControl(jobId: "d7-reverse"))
        reverseRoots = roots
        reversedURL = out
        return out
    }

    static func resolve(_ asset: PlanAsset) throws -> URL {
        let name = URL(string: asset.uri)?.lastPathComponent ?? ""
        if name == D7Plans.reversedFile { return try reversedTone() }
        guard let url = TestFixtures.url(.engine, "media/\(name)") else { throw EngineError(.mediaOffline, "fixture missing") }
        return url
    }

    /// The export composition of [plan] (the production factory's options, fixture URLs).
    static func buildComposition(_ paths: Paths, _ plan: RenderPlan) throws -> ExportComposition {
        let session = try DVRenderSession(snapshots: ParamSnapshotStore(ParamSnapshot(plan: plan)), qos: .userInitiated)
        var options = CompositionBuildOptions(spacerDirectory: paths.engineAssets)
        options.renderSize = CGSize(width: plan.canvas.w, height: plan.canvas.h)
        options.useProxies = false
        options.validate = false
        options.resolveURL = { _, asset in try ExportD7Tests.resolve(asset) }
        session.configure(&options)
        let input = UncheckedSendable((plan, options))
        let built = try MediaBlocking.await { try await CompositionBuilder.build(plan: input.value.0, options: input.value.1) }
        return ExportComposition(built: built, session: session)
    }

    private func make(segmentUs: Int64 = 10_000_000) throws -> ExportHarness {
        var options = ExportHarness.Options()
        options.segmentDurationUs = segmentUs
        let h = try ExportHarness(options)
        h.coordinator.environment.resolveURL = { _, asset in try ExportD7Tests.resolve(asset) }
        harnesses.append(h)
        return h
    }

    private func settings(_ w: Int, _ h: Int) -> EncodeSettingsMsg {
        ExportPlans.settings(w, h, fps: 30, videoBitrate: w >= 1280 ? 5_000_000 : 1_000_000, audioBitrate: 192_000)
    }

    private typealias Run = (id: String, output: URL, ended: Bool)

    private func export(_ h: ExportHarness, _ plan: Data, _ s: EncodeSettingsMsg, timeout: TimeInterval = 180,
                        file: StaticString = #filePath, line: UInt = #line) throws -> Run {
        let out = h.outputURL()
        let id = try h.start(self, plan: plan, settings: s, output: out)
        let ended = JobEventRecorder.spin(timeout: timeout) { h.recorder.ended(id) }
        if !ended { XCTFail("export did not end within \(Int(timeout)) s", file: file, line: line) }
        return (id, out, ended)
    }

    private func assertCompleted(_ h: ExportHarness, _ r: Run, durUs: Int64, s: EncodeSettingsMsg,
                                 file: StaticString = #filePath, line: UInt = #line) throws {
        // CI round 6: when AVFoundation's time-pitch unit spoiled every audio read (the soak's
        // keep-pitch pieces under load), the export fails typed instead of shipping the dropout.
        if let failure = h.recorder.failure(r.id), failure.code == EngineErrorCode.decodeFailed.rawValue,
           failure.message.hasPrefix(ReaderWriterPipeline.timePitchFailurePrefix) {
            XCTAssertTrue(failure.retryable, file: file, line: line)
            XCTAssertFalse(FileManager.default.fileExists(atPath: r.output.path), "no file with the dropout", file: file, line: line)
            print("FIX-IOS-D7: export failed typed after time-pitch faults in every read: \(failure.message)")
            return
        }
        XCTAssertNotNil(h.recorder.done(r.id), "failed: \(h.recorder.failure(r.id)?.message ?? "-")", file: file, line: line)
        guard h.recorder.done(r.id) != nil else { return }
        try ExportConformance.check(r.output, settings: s, durUs: durUs, brand: "mp42", codec: "avc1", checkBitrate: false, file: file, line: line)
    }

    private func assertReleased(_ h: ExportHarness, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(h.onExportQueue { h.coordinator.jobIds }, [], "no job left in the coordinator", file: file, line: line)
        if let suspender = h.coordinator.previewSuspender as? CountingSuspender {
            let (s, r) = suspender.counts
            XCTAssertEqual(s, r, "preview suspension balanced", file: file, line: line)
        }
        XCTAssertEqual(h.interruption.registeredJobIds, [], "JobInterruption registrations released", file: file, line: line)
    }

    /// Reads the whole audio mix of a fresh soak composition on a private queue: (buffers, last
    /// PTS s), or nil when the read did not end within [timeout] (the hung reader is left alone).
    private func readSoakMix(_ paths: Paths, timeout: TimeInterval) throws -> (buffers: Int, last: Double)? {
        let plan = try RenderPlanDecoder.decodePlan(D7Plans.soak800())
        let c = try ExportD7Tests.buildComposition(paths, plan)
        let reader = try AVAssetReader(asset: c.built.composition)
        reader.timeRange = ExportTime.readerRange(startUs: 0, endUs: plan.durUs, plan: plan)
        let output = AVAssetReaderAudioMixOutput(audioTracks: c.audioTracks, audioSettings: ExportPCM.readerSettings)
        output.audioMix = c.built.audioMix
        output.audioTimePitchAlgorithm = .timeDomain
        reader.add(output)
        XCTAssertTrue(reader.startReading())
        let lock = NSLock()
        var n = 0
        var last = 0.0
        let done = DispatchSemaphore(value: 0)
        let queue = DispatchQueue(label: "com.vecvel.danaview.tests.d7probe")
        queue.async {
            while let s = output.copyNextSampleBuffer() {
                lock.lock()
                n += 1
                last = CMSampleBufferGetPresentationTimeStamp(s).seconds
                lock.unlock()
            }
            done.signal()
        }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            // Never cancel or release a reader whose call is outstanding.
            SegmentedWriter.keepAbandoned([reader, output, c])
            lock.lock()
            defer { lock.unlock() }
            print("FIX-IOS-D7 probe: hung after \(n) buffers at \(last) s")
            return nil
        }
        queue.sync {}
        c.release()
        lock.lock()
        defer { lock.unlock() }
        return (n, last)
    }

    // MARK: D7 root cause

    /// Measures AVFoundation's hang (a report: it is intermittent; the export tests below show the
    /// pipeline completes either way). Every read that ends reads the whole 39 s.
    func testSoakMixReadHangsSometimes() throws {
        let h = try make()
        var hung = 0
        let reads = 8
        for _ in 0..<reads {
            if let r = try readSoakMix(h.paths, timeout: 10) {
                XCTAssertGreaterThan(r.buffers, 200)
                XCTAssertGreaterThan(r.last, 38.8, "a read that ends reads the whole 39 s")
            } else {
                hung += 1
            }
        }
        print("FIX-IOS-D7 probe: \(hung) of \(reads) soak mix reads hung")
    }

    // MARK: D7 fix

    func testHungMixReadIsLeftAloneAndTheExportResumes() throws {
        let h = try make()
        let log = D7Log()
        h.coordinator.configurePipeline = { p in
            p.audioWatchdog = 1
            p.audioSourceHook = { source, attempt in
                log.add(source)
                guard attempt == 1 else { return }
                source.onTeardown = { log.teardown() }
                // AVFoundation's hang, for 8 s (the old code cancelled and released the reader after
                // 1 + 5 s, then this call ran inside the released reader).
                source.readGate = { n in
                    guard n == 3 else { return }
                    Thread.sleep(forTimeInterval: 8)
                    log.gateOpened()
                }
            }
        }
        let s = settings(320, 180)
        let r = try export(h, D7Plans.soak800(), s)
        guard r.ended else { return }
        try assertCompleted(h, r, durUs: D7Plans.durUs, s: s)
        let first = try XCTUnwrap(log.sources.first)
        // The gated read always hangs (8 s > watchdog). A fresh reader can also stall on its own
        // on a loaded simulator (AVFoundation's hang this fix is about, or a first buffer slower
        // than the watchdog), which is resumed the same way, so the counts are compared with each
        // other rather than with 1.
        XCTAssertGreaterThanOrEqual(first.hungReads, 1, "the gated read counts as hung")
        XCTAssertEqual(first.resumes, first.hungReads, "every hung read resumed on a fresh reader instead of failing the read")
        XCTAssertNotEqual(first.rejection, "hung")
        // The resumed reader is torn down; the hung one is never touched, not even after its call
        // returned (it is left behind with its composition).
        XCTAssertTrue(JobEventRecorder.spin(timeout: 15) { log.gateOpenedAt != nil })
        _ = JobEventRecorder.spin(timeout: 1) { false }
        XCTAssertEqual(log.teardowns, 1 + first.resumes - first.hungReads, "every reader but the hung one is torn down")
        // The speech plays across the resume point (buffer 3 is about 0.25 s in) when the resumed
        // read passed validation (under Thread Sanitizer every read shows tap range
        // discontinuities and the last attempt is accepted as is).
        if first.rejection == nil {
            let pcm = try ExportConformance.pcm(r.output)
            XCTAssertGreaterThan(ExportConformance.rmsDb(pcm, channel: 0, 4_800, 96_000), -45, "audio across the resume")
        }
        assertReleased(h)
    }

    func testHungMixReadPastTheEndOfATrackResumesToTheEnd() throws {
        // CI round 6: a hang at about 12 s resumed on a reader that started there, and such an
        // AVAssetReaderAudioMixOutput stops at the end of the next track's media (17.0 s of the
        // soak's 39 s, or 10.0 s from just before 10 s): the export shipped a 9.95 s audio track.
        // The resume reads the whole range again and drops what was delivered.
        let h = try make()
        let log = D7Log()
        h.coordinator.configurePipeline = { p in
            p.audioWatchdog = 1
            p.audioSourceHook = { source, attempt in
                log.add(source)
                guard attempt == 1 else { return }
                // About 0.17 s per buffer: read 70 is about 12 s in (between the speech's end at
                // 10 s and the clap at 13.07 s).
                source.readGate = { n in if n == 70 { Thread.sleep(forTimeInterval: 3) } }
            }
        }
        let s = settings(320, 180)
        let r = try export(h, D7Plans.soak800(), s)
        guard r.ended else { return }
        try assertCompleted(h, r, durUs: D7Plans.durUs, s: s)
        let first = try XCTUnwrap(log.sources.first)
        XCTAssertGreaterThanOrEqual(first.hungReads, 1, "the gated read counts as hung")
        XCTAssertEqual(first.resumes, first.hungReads)
        XCTAssertFalse(first.shortRead, first.otherDefect ?? "")
        XCTAssertNotEqual(first.rejection, "hung")
        XCTAssertNil(first.rejection, "the resumed read reaches the end: \(first.rejection ?? "")")
        assertReleased(h)
    }

    func testHungMixReadWithoutResumesIsRedoneOnAFreshComposition() throws {
        let h = try make()
        let log = D7Log()
        h.coordinator.configurePipeline = { p in
            p.audioWatchdog = 1
            p.maxAudioResumes = 0
            p.audioSourceHook = { source, attempt in
                log.add(source)
                guard attempt == 1 else { return }
                source.readGate = { n in if n == 2 { Thread.sleep(forTimeInterval: 7) } }
            }
        }
        let s = settings(320, 180)
        let r = try export(h, D7Plans.soak800(), s)
        guard r.ended else { return }
        try assertCompleted(h, r, durUs: D7Plans.durUs, s: s)
        XCTAssertEqual(log.sources.first?.rejection, "hung")
        XCTAssertGreaterThanOrEqual(log.sources.count, 2, "the hung read is redone")
        _ = JobEventRecorder.spin(timeout: 8) { false } // the blocked call returns inside its live reader
        assertReleased(h)
    }

    func testCancelDuringTheAudioReadEndsAtOnceAndTheNextExportSucceeds() throws {
        let h = try make()
        let log = D7Log()
        let gate = DispatchSemaphore(value: 0)
        let entered = DispatchSemaphore(value: 0)
        h.coordinator.configurePipeline = { p in
            p.audioWatchdog = 600 // no resume: the cancel must end the wait
            p.audioSourceHook = { source, _ in
                log.add(source)
                source.onTeardown = { log.teardown() }
                source.readGate = { n in
                    guard n == 3 else { return }
                    entered.signal()
                    gate.wait()
                    log.gateOpened()
                }
            }
        }
        let s = settings(320, 180)
        let out = h.outputURL()
        let id = try h.start(self, plan: D7Plans.soak800(), settings: s, output: out)
        XCTAssertEqual(entered.wait(timeout: .now() + 120), .success, "the audio read reached the blocked call")
        XCTAssertEqual(h.onExportQueue { h.coordinator.job(id)?.phase }, .finishing)
        let cancelAt = Date()
        try h.cancel(self, id)
        XCTAssertTrue(JobEventRecorder.spin(timeout: 10) { h.recorder.ended(id) })
        XCTAssertLessThan(Date().timeIntervalSince(cancelAt), 4, "the cancel does not wait for the blocked read")
        XCTAssertEqual(h.recorder.failure(id)?.code, "cancelled")
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.path))
        XCTAssertEqual(log.teardowns, 0, "the blocked reader is not torn down while its call is outstanding")
        assertReleased(h)

        // The next export runs while the old reader is still blocked.
        h.coordinator.configurePipeline = nil
        let r = try export(h, D7Plans.soak800(), s)
        if r.ended {
            try assertCompleted(h, r, durUs: D7Plans.durUs, s: s)
            assertReleased(h)
        }
        gate.signal()
        XCTAssertTrue(JobEventRecorder.spin(timeout: 10) { log.teardowns >= 1 }, "torn down once its call returned")
        if let first = log.teardownTimes.first, let opened = log.gateOpenedAt {
            XCTAssertGreaterThanOrEqual(first, opened)
        }
    }

    func testSoakProjectExportsCompletely() throws {
        let h = try make()
        let log = D7Log()
        h.coordinator.configurePipeline = { p in p.audioSourceHook = { source, _ in log.add(source) } }
        let s = settings(1280, 720)
        let r = try export(h, D7Plans.soak800(w: 1280, h: 720), s, timeout: 300)
        guard r.ended else { return }
        try assertCompleted(h, r, durUs: D7Plans.durUs, s: s)
        let sources = log.sources
        print("FIX-IOS-D7 soak export: \(sources.count) audio read(s), resumes \(sources.map(\.resumes)), hung \(sources.map(\.hungReads))")
        let pcm = try ExportConformance.pcm(r.output)
        XCTAssertGreaterThan(ExportConformance.rmsDb(pcm, channel: 0, 48_000 * 3, 48_000 * 5), -40, "the 2× reversed tone is there")
        XCTAssertGreaterThan(ExportConformance.rmsDb(pcm, channel: 0, 48_000 * 6, 48_000 * 10), -40)
        assertReleased(h)
    }

    // MARK: FIX-IOS-12-1

    func testBackToBackSoakExportsTearDownEveryComposition() throws {
        let h = try make()
        let log = D7Log()
        let paths = h.paths
        h.coordinator.makeComposition = { plan in
            let c = try ExportD7Tests.buildComposition(paths, plan)
            log.add(c)
            return c
        }
        h.coordinator.configurePipeline = { p in p.audioSourceHook = { source, _ in source.onHung = { log.hung() } } }
        let abandonedBefore = SegmentedWriter.abandonedCount
        let s = settings(320, 180)
        let plans: [(Data, Int64)] = [
            (D7Plans.soak800(), D7Plans.durUs),
            (D7Plans.soak800(), D7Plans.durUs),
            (ExportPlans.toneVideo(w: 320, h: 180, fps: 30, durUs: 8_000_000, withAudio: true), 8_000_000),
            (D7Plans.soak800(), D7Plans.durUs),
        ]
        for (k, (plan, durUs)) in plans.enumerated() {
            let r = try export(h, plan, s)
            guard r.ended else { return }
            try assertCompleted(h, r, durUs: durUs, s: s)
            assertReleased(h)
            // Every composition of this export (video phase, audio reads, resumes) is gone before
            // the next export starts (a reader AVFoundation left blocked would keep its own).
            // AVFoundation's own hang (about 1 read in 20) leaves that one reader and its composition
            // blocked on their queue; nothing else may survive.
            XCTAssertTrue(JobEventRecorder.spin(timeout: 3) { log.alive <= log.hungReads },
                          "export \(k): \(log.alive) of \(log.made) compositions still alive (\(log.hungReads) hung)")
            try? FileManager.default.removeItem(at: r.output)
        }
        XCTAssertGreaterThanOrEqual(log.made, 2 * plans.count, "a video and an audio composition per export")
        XCTAssertLessThanOrEqual(SegmentedWriter.abandonedCount, abandonedBefore + log.hungReads,
                                 "nothing left behind but AVFoundation's own hung readers")
    }
}
