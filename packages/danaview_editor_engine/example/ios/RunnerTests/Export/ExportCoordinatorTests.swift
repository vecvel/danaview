// OWNER: IOS-12
//
// IOS-12 acceptance (coordinator and failure paths): cancel cleans up the partial file and every
// segment; encoder failures map to encoderUnavailable / encoderSizeLimit; the portrait retry path
// with an injected refusal (probe and writer); an injected decoderInitFailed (and a decoder limit)
// routes the job to the multi-pass hook (test double until IOS-20) and is never reported as a
// failure; thermal critical pauses the pumps; background pause and resume from the last segment;
// resumable / interrupted / completedWhileDetached records; one job at a time; preview suspended
// on minimal/low/mid tiers; preflight warnings; the audio read is validated and redone.

import AVFoundation
import XCTest

@testable import danaview_editor_engine

/// Multi-pass test double: records the call and runs the final pass over the unchanged plan.
final class MultiPassDouble: NSObject, MultiPassExporting {
    private(set) var reasons: [MultiPassReason] = []
    private(set) var limits: [Int] = []
    var runFinalPass = true

    required init(context: EngineContext) {}

    override init() {}

    func export(_ job: MultiPassContext) throws -> ReaderWriterPipeline.Outcome {
        reasons.append(job.reason)
        limits.append(job.decoderLimit)
        guard runFinalPass else { throw EngineError(.internal, "double does not export") }
        job.setProgressWindow(0.5, 0.5)
        return try job.runFinalPass(job.plan, job.directory.appendingPathComponent("final", isDirectory: true))
    }
}

final class ExportCoordinatorTests: XCTestCase {
    private var harnesses: [ExportHarness] = []

    override func tearDown() {
        harnesses.forEach { $0.remove() }
        harnesses = []
    }

    private func make(_ options: ExportHarness.Options = ExportHarness.Options(), roots: TempRoots? = nil) throws -> ExportHarness {
        let h = try ExportHarness(options, roots: roots)
        harnesses.append(h)
        return h
    }

    private func jobDirectory(_ h: ExportHarness, _ id: String) -> URL { ExportJob.directory(for: id, work: h.paths.work) }

    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    // MARK: Encoder settings

    func testEncoderSettingsFromMessage() throws {
        var msg = ExportPlans.settings(1080, 1920, fps: 30, container: .mov, codec: .hevc, videoBitrate: 8_000_000, audioBitrate: 900_000)
        msg.audioSampleRate = 44_100
        msg.audioChannels = 1
        msg.keyframeIntervalMs = 2_000
        let s = try EncoderSettings(msg: msg)
        XCTAssertEqual(s.container, .mov)
        XCTAssertEqual(s.codec, .hevc)
        XCTAssertTrue(s.isPortrait)
        XCTAssertEqual(s.audioBitrate, 320_000, "AAC bitrate clamped")
        XCTAssertEqual(s.msg.audioSampleRate, 48_000, "always 48 kHz")
        XCTAssertEqual(s.msg.audioChannels, 2, "always stereo")
        XCTAssertEqual(s.fileType, .mov)
        XCTAssertEqual(s.encoderName, "VideoToolbox HEVC")

        let native = s.segmentSettings(layout: .native)
        XCTAssertEqual(native.width, 1080)
        XCTAssertEqual(native.height, 1920)
        XCTAssertEqual(native.maxKeyFrameIntervalSeconds, 2)
        XCTAssertFalse(native.allowFrameReordering)
        XCTAssertEqual(native.audio, SegmentEncodeSettings.Audio(sampleRate: 48_000, channels: 2, bitRate: 320_000))
        let video = native.videoOutputSettings
        XCTAssertEqual(video[AVVideoCodecKey] as? AVVideoCodecType, .hevc)
        let color = try XCTUnwrap(video[AVVideoColorPropertiesKey] as? [String: String])
        XCTAssertEqual(color[AVVideoColorPrimariesKey], AVVideoColorPrimaries_ITU_R_709_2)
        let compression = try XCTUnwrap(video[AVVideoCompressionPropertiesKey] as? [String: Any])
        XCTAssertEqual(compression[AVVideoAverageBitRateKey] as? Int, 8_000_000)
        XCTAssertEqual(compression[AVVideoExpectedSourceFrameRateKey] as? Int, 30)
        XCTAssertEqual(compression[AVVideoMaxKeyFrameIntervalDurationKey] as? Double, 2)

        let rotated = s.segmentSettings(layout: .rotated)
        XCTAssertEqual(rotated.width, 1920)
        XCTAssertEqual(rotated.height, 1080)
        XCTAssertEqual(s.with(codec: .h264).segmentSettings(layout: .native).videoOutputSettings[AVVideoProfileLevelKey as String] as? String,
                       nil, "profile lives in the compression properties")
        let h264 = s.with(codec: .h264).segmentSettings(layout: .native).videoOutputSettings
        let h264Compression = try XCTUnwrap(h264[AVVideoCompressionPropertiesKey] as? [String: Any])
        XCTAssertEqual(h264Compression[AVVideoProfileLevelKey] as? String, AVVideoProfileLevelH264HighAutoLevel)

        // Disk estimate: (video + audio)·sec/8·1.02 + one 10 s segment.
        let bytes = s.requiredBytes(durationUs: 60_000_000)
        XCTAssertEqual(Double(bytes), (8_320_000.0 * 60 / 8 * 1.02) + 8_000_000.0 * 10 / 8, accuracy: 2)
    }

    func testEncoderRefusalsMapToSizeLimitAndUnavailable() throws {
        let landscape = EncoderSettings(width: 3840, height: 2160, fps: 30, videoBitrate: 40_000_000)
        let portrait = EncoderSettings(width: 1080, height: 1920, fps: 30, videoBitrate: 8_000_000)
        let refuseBig = EncoderProbe { _, w, h in w * h <= 1920 * 1088 && w >= h }
        XCTAssertThrowsError(try EncodeLayout.choose(landscape, probe: refuseBig)) {
            XCTAssertEqual(EngineError.from($0).code, .encoderSizeLimit)
        }
        XCTAssertEqual(try EncodeLayout.choose(portrait, probe: refuseBig), .rotated)
        let none = EncoderProbe { _, _, _ in false }
        XCTAssertThrowsError(try EncodeLayout.choose(portrait, probe: none)) {
            XCTAssertEqual(EngineError.from($0).code, .encoderUnavailable)
        }
        let all = EncoderProbe { _, _, _ in true }
        XCTAssertEqual(try EncodeLayout.choose(portrait, probe: all), .native)
        // Writer failures.
        let refusal = NSError(domain: AVFoundationErrorDomain, code: -11861)
        XCTAssertEqual(EncoderErrors.map(refusal, settings: landscape, probe: refuseBig).code, .encoderSizeLimit)
        XCTAssertEqual(EncoderErrors.map(refusal, settings: landscape, probe: none).code, .encoderUnavailable)
        XCTAssertEqual(EncoderErrors.map(NSError(domain: AVFoundationErrorDomain, code: -11834), settings: landscape, probe: none).code,
                       .encoderUnavailable)
        XCTAssertEqual(EncoderErrors.map(NSError(domain: AVFoundationErrorDomain, code: -11833), settings: landscape, probe: all).code,
                       .decoderInitFailed, "decoder errors keep their code")

        // Through the coordinator: start fails with the mapped code, nothing is left behind.
        let h = try make(ExportHarness.Options(probe: EncoderProbe.refusing { _, w, _ in w > 640 }))
        let big = ExportPlans.noAudioVideo(w: 960, h: 540, fps: 25, durUs: 1_000_000)
        XCTAssertThrowsError(try h.start(self, plan: big, settings: ExportPlans.settings(960, 540, fps: 25), output: h.outputURL())) {
            XCTAssertEqual(EngineError.from($0).code, .encoderSizeLimit)
        }
        let plan = ExportPlans.noAudioVideo(w: 640, h: 360, fps: 25, durUs: 1_000_000)
        let dead = try make(ExportHarness.Options(probe: EncoderProbe { _, _, _ in false }))
        XCTAssertThrowsError(try dead.start(self, plan: plan, settings: ExportPlans.settings(640, 360, fps: 25), output: dead.outputURL())) {
            XCTAssertEqual(EngineError.from($0).code, .encoderUnavailable)
        }
        let preflight = try dead.preflight(self, plan: plan, settings: ExportPlans.settings(640, 360, fps: 25))
        XCTAssertFalse(preflight.ok)
        let left = (try? FileManager.default.contentsOfDirectory(atPath: h.paths.work.path)) ?? []
        XCTAssertEqual(left.filter { $0.hasPrefix("export-ex_") }, [])
    }

    // MARK: Portrait retry (ARCH §14.1)

    /// A 360×640 plan: blue background, red top half.
    private func portraitPlan(durUs: Int64) -> Data {
        ExportPlans.plan(
            w: 360, h: 640, fps: 30, durUs: durUs, bg: "#0000FFFF", assets: [],
            layers: [ExportPlans.solid("it_top00000001#v", t0: 0, t1: durUs, color: "#FF0000FF", w: 360, h: 320, cx: 180, cy: 160)])
    }

    private func assertUprightPortrait(_ output: URL, file: StaticString = #filePath, line: UInt = #line) throws {
        let facts = try ExportConformance.inspect(output)
        XCTAssertEqual(facts.width, 640, "landscape-encoded buffer", file: file, line: line)
        XCTAssertEqual(facts.height, 360, file: file, line: line)
        let display = CGRect(x: 0, y: 0, width: facts.width, height: facts.height).applying(facts.transform)
        XCTAssertEqual(abs(display.width), 360, file: file, line: line)
        XCTAssertEqual(abs(display.height), 640, file: file, line: line)
        // The display frame (transform applied) is upright: red on top, blue at the bottom.
        let asset = AVURLAsset(url: output)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let image = try generator.copyCGImage(at: CMTime(value: 1, timescale: 2), actualTime: nil)
        XCTAssertEqual(image.width, 360, file: file, line: line)
        XCTAssertEqual(image.height, 640, file: file, line: line)
        let top = ExportConformance.meanColor(image, x0: 40, y0: 40, x1: 320, y1: 280)
        let bottom = ExportConformance.meanColor(image, x0: 40, y0: 360, x1: 320, y1: 600)
        XCTAssertGreaterThan(top.r, 180, "top is red: \(top)", file: file, line: line)
        XCTAssertLessThan(top.b, 80, "top is red: \(top)", file: file, line: line)
        XCTAssertGreaterThan(bottom.b, 180, "bottom is blue: \(bottom)", file: file, line: line)
        XCTAssertLessThan(bottom.r, 80, "bottom is blue: \(bottom)", file: file, line: line)
    }

    func testPortraitRefusedByProbeEncodesLandscapeWithRotation() throws {
        let h = try make(ExportHarness.Options(probe: EncoderProbe.refusing { _, w, hh in hh > w }))
        let durUs: Int64 = 1_000_000
        let settings = ExportPlans.settings(360, 640, fps: 30, videoBitrate: 600_000)
        let preflight = try h.preflight(self, plan: portraitPlan(durUs: durUs), settings: settings)
        XCTAssertTrue(preflight.ok)
        XCTAssertTrue(preflight.warnings.contains { $0.code == "portraitRetried" })
        let output = h.outputURL()
        let id = try h.export(self, plan: portraitPlan(durUs: durUs), settings: settings, output: output)
        XCTAssertNil(h.recorder.failure(id))
        XCTAssertNotNil(h.recorder.done(id))
        XCTAssertTrue(h.progress(id).last?.warnings.contains { $0.code == "portraitRetried" } ?? false)
        try assertUprightPortrait(output)
    }

    func testPortraitRefusedByWriterRetriesOnceRotated() throws {
        let h = try make()
        var layouts: [EncodeLayout] = []
        h.coordinator.configurePipeline = { p in
            layouts.append(p.input.layout)
            if p.input.layout == .native {
                p.configureWriter = { writer in
                    writer.faultInjector = { _, _ in NSError(domain: AVFoundationErrorDomain, code: -11861) }
                }
            }
        }
        let output = h.outputURL()
        let id = try h.export(self, plan: portraitPlan(durUs: 1_000_000), settings: ExportPlans.settings(360, 640, fps: 30), output: output)
        XCTAssertNil(h.recorder.failure(id))
        XCTAssertEqual(layouts, [.native, .rotated])
        XCTAssertTrue(h.progress(id).last?.warnings.contains { $0.code == "portraitRetried" } ?? false)
        try assertUprightPortrait(output)
    }

    func testPortraitRefusedInBothOrientationsFailsWithSizeLimit() throws {
        let h = try make()
        h.coordinator.configurePipeline = { p in
            p.configureWriter = { $0.faultInjector = { _, _ in NSError(domain: AVFoundationErrorDomain, code: -11861) } }
        }
        let output = h.outputURL()
        let id = try h.export(self, plan: portraitPlan(durUs: 1_000_000), settings: ExportPlans.settings(360, 640, fps: 30), output: output)
        XCTAssertEqual(h.recorder.failure(id)?.code, "encoderSizeLimit")
        XCTAssertFalse(exists(output))
        XCTAssertFalse(exists(jobDirectory(h, id)))
    }

    // MARK: Cancel

    func testCancelDeletesPartialOutputAndSegments() throws {
        let h = try make(ExportHarness.Options(segmentDurationUs: 500_000))
        let durUs: Int64 = 6_000_000
        let output = h.outputURL()
        let id = try h.start(self, plan: ExportPlans.toneVideo(w: 640, h: 360, fps: 30, durUs: durUs, withAudio: true),
                             settings: ExportPlans.settings(640, 360, fps: 30), output: output)
        let directory = jobDirectory(h, id)
        XCTAssertTrue(JobEventRecorder.spin(timeout: 60) {
            (SegmentCheckpoint.load(from: directory)?.completed.count ?? 0) >= 2
        }, "segments written before the cancel")
        try h.cancel(self, id)
        h.recorder.waitForEnd(id, test: self, timeout: 60)
        XCTAssertEqual(h.recorder.failure(id)?.code, "cancelled")
        XCTAssertNil(h.recorder.done(id))
        XCTAssertTrue(JobEventRecorder.spin(timeout: 10) { !self.exists(directory) }, "segments deleted")
        XCTAssertFalse(exists(output))
        XCTAssertEqual(try h.activeJobs(self).count, 0)
        // Idempotent.
        try h.cancel(self, id)
        try h.cancel(self, "ex_unknown")
    }

    // MARK: Multi-pass routing (D-45)

    func testDecoderInitFailedRoutesToMultiPassHook() throws {
        let h = try make()
        let double = MultiPassDouble()
        h.coordinator.multiPass = double
        var faulted = false
        h.coordinator.configurePipeline = { p in
            if !faulted {
                faulted = true
                p.videoOpenFault = { _ in EngineError(.decoderInitFailed, "injected: no decoder for track 1") }
            }
        }
        let output = h.outputURL()
        let durUs: Int64 = 1_000_000
        let settings = ExportPlans.settings(320, 180, fps: 30, videoBitrate: 500_000)
        let id = try h.export(self, plan: ExportPlans.toneVideo(w: 320, h: 180, fps: 30, durUs: durUs, withAudio: true),
                              settings: settings, output: output)
        XCTAssertNil(h.recorder.failure(id), "decoderInitFailed is never reported as a failure")
        XCTAssertNotNil(h.recorder.done(id))
        XCTAssertEqual(double.reasons, [.decoderInitFailed])
        try ExportConformance.check(output, settings: settings, durUs: durUs, brand: "mp42", codec: "avc1", checkBitrate: false)
        // The pass window maps the final pass into the second half.
        XCTAssertTrue(h.progress(id).contains { $0.phase == .rendering && $0.fraction >= 0.5 && $0.fraction < 1 })
    }

    func testDecoderInitFailedWithoutHookIsReported() throws {
        let h = try make()
        h.coordinator.configurePipeline = { p in
            p.videoOpenFault = { _ in EngineError(.decoderInitFailed, "injected") }
        }
        let output = h.outputURL()
        let id = try h.export(self, plan: ExportPlans.noAudioVideo(w: 320, h: 180, fps: 25, durUs: 1_000_000),
                              settings: ExportPlans.settings(320, 180, fps: 25), output: output)
        XCTAssertEqual(h.recorder.failure(id)?.code, "decoderInitFailed")
        XCTAssertFalse(exists(output))
    }

    /// Two composition tracks (a PiP on seq 1).
    private func twoTrackPlan(durUs: Int64) -> Data {
        ExportPlans.plan(
            w: 320, h: 180, fps: 30, durUs: durUs,
            assets: [
                ExportPlans.video("md_a00000000001", file: "frame_counter_1080p30.mp4", w: 1920, h: 1080, durUs: 8_000_000, hasAudio: false),
                ExportPlans.video("md_b00000000001", file: "frame_counter_720p25.mp4", w: 1280, h: 720, durUs: 8_000_000, hasAudio: false),
            ],
            layers: [
                ExportPlans.mediaLayer("it_a0000000001#v", asset: "md_a00000000001", seq: 0, t0: 0, t1: durUs, w: 320, h: 180),
                ExportPlans.mediaLayer("it_b0000000001#v", asset: "md_b00000000001", seq: 1, t0: 0, t1: durUs, w: 160, h: 90, z: 10010,
                                       cx: 240, cy: 45),
            ])
    }

    func testDecoderLimitRoutesToMultiPassAndPreflightNeverRefuses() throws {
        let h = try make(ExportHarness.Options(decoderLimit: 1))
        let double = MultiPassDouble()
        h.coordinator.multiPass = double
        let durUs: Int64 = 1_000_000
        let settings = ExportPlans.settings(320, 180, fps: 30, videoBitrate: 500_000)
        let preflight = try h.preflight(self, plan: twoTrackPlan(durUs: durUs), settings: settings)
        XCTAssertTrue(preflight.ok, "preflight never refuses for layer counts")
        XCTAssertTrue(preflight.warnings.contains { $0.code == "layersVsResolution" })
        let output = h.outputURL()
        let id = try h.export(self, plan: twoTrackPlan(durUs: durUs), settings: settings, output: output)
        XCTAssertNil(h.recorder.failure(id))
        XCTAssertEqual(double.reasons, [.decoderLimit(needed: 2, limit: 1)])
        XCTAssertEqual(double.limits, [1])
        try ExportConformance.check(output, settings: settings, durUs: durUs, brand: "mp42", codec: "avc1", checkBitrate: false)
    }

    func testMultiPassHookDiscoveryFindsNothingUntilIOS20() throws {
        let h = try make()
        // No `PrecomposeExporter` is linked yet: the lookup answers nil (the coordinator then runs
        // the single pass).
        XCTAssertNil(ExportCoordinator.discoverMultiPass(context: h.context))
        XCTAssertNil(ExportCoordinator.discoverLifecycle(context: h.context))
    }

    // MARK: Thermal

    func testThermalCriticalPausesPumps() throws {
        let lock = NSLock()
        var calls = 0
        let h = try make(ExportHarness.Options(thermal: {
            lock.lock()
            defer { lock.unlock() }
            calls += 1
            return calls <= 3 ? .critical : .nominal
        }))
        let started = Date()
        let id = try h.export(self, plan: ExportPlans.noAudioVideo(w: 320, h: 180, fps: 25, durUs: 1_000_000),
                              settings: ExportPlans.settings(320, 180, fps: 25), output: h.outputURL())
        XCTAssertNotNil(h.recorder.done(id))
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(started), 1.0, "pumps waited while critical")
        lock.lock()
        XCTAssertGreaterThan(calls, 3)
        lock.unlock()
    }

    // MARK: Background (D-22)

    func testBackgroundPausesAndResumesFromTheLastSegment() throws {
        let h = try make(ExportHarness.Options(segmentDurationUs: 500_000))
        let durUs: Int64 = 4_000_000
        let settings = ExportPlans.settings(640, 360, fps: 30)
        let output = h.outputURL()
        let id = try h.start(self, plan: ExportPlans.toneVideo(w: 640, h: 360, fps: 30, durUs: durUs, withAudio: true),
                             settings: settings, output: output)
        let directory = jobDirectory(h, id)
        XCTAssertTrue(JobEventRecorder.spin(timeout: 60) { (SegmentCheckpoint.load(from: directory)?.completed.count ?? 0) >= 2 })
        h.interruption.didEnterBackground()
        XCTAssertTrue(JobEventRecorder.spin(timeout: 30) { h.progress(id).last?.pausedInBackground == true }, "pausedInBackground reported")
        let kept = SegmentCheckpoint.load(from: directory)?.completed.count ?? 0
        XCTAssertGreaterThanOrEqual(kept, 2)
        XCTAssertFalse(h.recorder.ended(id))
        // While paused, activeJobs reports it running.
        let records = try h.activeJobs(self)
        XCTAssertEqual(records.map(\.jobId), [id])
        XCTAssertEqual(records.first?.state, .running)
        h.interruption.willEnterForeground()
        h.recorder.waitForEnd(id, test: self, timeout: 120)
        XCTAssertNil(h.recorder.failure(id))
        XCTAssertEqual(h.progress(id).last?.pausedInBackground, false)
        let facts = try ExportConformance.check(output, settings: settings, durUs: durUs, brand: "mp42", codec: "avc1", checkBitrate: false)
        XCTAssertEqual(facts.frames, 120)
        var codes: [Int?] = []
        try ExportConformance.frames(output) { _, pb in codes.append(CompositorTestSupport.barcode(pb)) }
        for (k, code) in codes.enumerated() where code != nil { XCTAssertEqual(code, k, "continuous barcodes after resume") }
    }

    func testResumableAfterProcessKillThenResumes() throws {
        let roots = try TempRoots()
        let first = try make(ExportHarness.Options(segmentDurationUs: 500_000), roots: roots)
        let durUs: Int64 = 3_000_000
        let settings = ExportPlans.settings(640, 360, fps: 30)
        let output = first.outputURL()
        let id = try first.start(self, plan: ExportPlans.toneVideo(w: 640, h: 360, fps: 30, durUs: durUs, withAudio: true),
                                 settings: settings, output: output)
        let directory = jobDirectory(first, id)
        XCTAssertTrue(JobEventRecorder.spin(timeout: 60) { (SegmentCheckpoint.load(from: directory)?.completed.count ?? 0) >= 1 })
        // "Kill": the app goes to the background (segment discarded, checkpoint kept) and the
        // process never comes back.
        first.interruption.didEnterBackground()
        XCTAssertTrue(JobEventRecorder.spin(timeout: 30) { first.progress(id).last?.pausedInBackground == true })

        // A new process on the same roots.
        let second = try make(ExportHarness.Options(segmentDurationUs: 500_000), roots: roots)
        XCTAssertTrue(exists(directory), "the launch wipe keeps a resumable job")
        let records = try second.activeJobs(self)
        let record = try XCTUnwrap(records.first { $0.jobId == id })
        XCTAssertEqual(record.state, .resumable)
        XCTAssertGreaterThan(record.doneFraction ?? 0, 0)
        XCTAssertEqual(record.settings?.width, 640)
        let resumed: String = try second.call(self) { second.coordinator.resume(jobId: id, reply: $0) }
        XCTAssertEqual(resumed, id)
        second.recorder.waitForEnd(id, test: self, timeout: 120)
        XCTAssertNil(second.recorder.failure(id))
        let facts = try ExportConformance.check(output, settings: settings, durUs: durUs, brand: "mp42", codec: "avc1", checkBitrate: false)
        XCTAssertEqual(facts.frames, 90)
        XCTAssertFalse(exists(directory))
    }

    func testInterruptedRecordIsOneShotAndConsumed() throws {
        let h = try make()
        // A job directory left by a kill before its first segment finished.
        let id = "ex_killed000001"
        let directory = jobDirectory(h, id)
        let planData = ExportPlans.noAudioVideo(w: 320, h: 180, fps: 25, durUs: 1_000_000)
        let settings = try EncoderSettings(msg: ExportPlans.settings(320, 180, fps: 25))
        let job = ExportJob(
            id: id, directory: directory, plan: try RenderPlanDecoder.decodePlan(planData), planData: planData,
            record: ExportJob.Record(
                jobId: id, settings: settings, outputPath: h.outputURL().path, title: "t", whenDetached: "saveToGallery",
                layout: .native, planHash: ExportJob.hash(planData), state: .running, result: nil, createdAt: Date()))
        try job.save()
        _ = try SegmentedWriter(directory: directory, jobKind: ExportJob.jobKind, inputHash: ExportJob.hash(planData),
                                settings: settings.segmentSettings(layout: .native), startUs: 0, endUs: 1_000_000)
        let records = try h.activeJobs(self)
        XCTAssertEqual(records.first { $0.jobId == id }?.state, .interrupted)
        h.coordinator.consumeJobRecord(jobId: id)
        XCTAssertFalse(try h.activeJobs(self).contains { $0.jobId == id })
        XCTAssertFalse(exists(directory))
    }

    func testCompletedWhileDetachedReportedUntilConsumed() throws {
        let h = try make(ExportHarness.Options(listenerAttached: false))
        let output = h.outputURL()
        let id = try h.export(self, plan: ExportPlans.noAudioVideo(w: 320, h: 180, fps: 25, durUs: 1_000_000),
                              settings: ExportPlans.settings(320, 180, fps: 25), output: output, timeout: 120)
        XCTAssertNotNil(h.recorder.done(id))
        let record = try XCTUnwrap(try h.activeJobs(self).first { $0.jobId == id })
        XCTAssertEqual(record.state, .completedWhileDetached)
        XCTAssertEqual(record.result?.path, output.path)
        XCTAssertEqual(record.result?.bytes, SegmentedWriter.fileSize(output))
        XCTAssertFalse(record.savedToGallery)
        // Exempt from the launch wipe until consumed.
        DiskCache.wipeWork(paths: h.paths)
        XCTAssertTrue(exists(output))
        h.coordinator.consumeJobRecord(jobId: id)
        XCTAssertFalse(try h.activeJobs(self).contains { $0.jobId == id })
        XCTAssertTrue(exists(output), "the output stays for Dart's handoff")
    }

    // MARK: Jobs and preview

    func testOneJobAtATime() throws {
        let h = try make()
        let first = try h.start(self, plan: ExportPlans.noAudioVideo(w: 320, h: 180, fps: 25, durUs: 2_000_000),
                                settings: ExportPlans.settings(320, 180, fps: 25), output: h.outputURL())
        XCTAssertThrowsError(try h.start(self, plan: ExportPlans.noAudioVideo(w: 320, h: 180, fps: 25, durUs: 1_000_000),
                                         settings: ExportPlans.settings(320, 180, fps: 25), output: h.outputURL())) {
            XCTAssertEqual(EngineError.from($0).code, .busy)
        }
        h.recorder.waitForEnd(first, test: self)
        XCTAssertNotNil(h.recorder.done(first))
        let second = try h.export(self, plan: ExportPlans.noAudioVideo(w: 320, h: 180, fps: 25, durUs: 1_000_000),
                                  settings: ExportPlans.settings(320, 180, fps: 25), output: h.outputURL())
        XCTAssertNotNil(h.recorder.done(second))
    }

    func testPreviewSuspendedOnMinimalLowMidTiersOnly() throws {
        for (tier, expected) in [(DeviceTierMsg.minimal, 1), (.low, 1), (.mid, 1), (.high, 0)] {
            let h = try make(ExportHarness.Options(tier: tier))
            let suspender = CountingSuspender()
            h.coordinator.previewSuspender = suspender
            let id = try h.export(self, plan: ExportPlans.noAudioVideo(w: 320, h: 180, fps: 25, durUs: 1_000_000),
                                  settings: ExportPlans.settings(320, 180, fps: 25), output: h.outputURL())
            XCTAssertNotNil(h.recorder.done(id))
            XCTAssertTrue(JobEventRecorder.spin(timeout: 5) { suspender.counts.1 == expected })
            XCTAssertEqual(suspender.counts.0, expected, "suspend on \(tier)")
            XCTAssertEqual(suspender.counts.1, expected, "resume on \(tier)")
        }
    }

    // MARK: Preflight

    func testPreflightWarningsAndPlanChecks() throws {
        let h = try make(ExportHarness.Options(tier: .low, encoders: .softwareH264Only))
        let plan = ExportPlans.toneVideo(w: 640, h: 360, fps: 30, durUs: 2_000_000, withAudio: true)
        let ok = try h.preflight(self, plan: plan, settings: ExportPlans.settings(640, 360, fps: 30, codec: .hevc))
        XCTAssertTrue(ok.ok)
        let codes = Set(ok.warnings.map(\.code))
        XCTAssertTrue(codes.isSuperset(of: ["softwareEncoder", "hevcUnavailable", "backgroundPauses"]), "\(codes)")
        XCTAssertFalse(codes.contains("portraitRetried"))
        XCTAssertEqual(ok.maxHeightForPlan, 1080, "low tier: 1080p")
        // The plan must match the output.
        XCTAssertThrowsError(try h.preflight(self, plan: plan, settings: ExportPlans.settings(1280, 720, fps: 30))) {
            XCTAssertEqual(EngineError.from($0).code, .planInvalid)
        }
        XCTAssertThrowsError(try h.preflight(self, plan: plan, settings: ExportPlans.settings(640, 360, fps: 25))) {
            XCTAssertEqual(EngineError.from($0).code, .planInvalid)
        }
        var preview = String(decoding: plan, as: UTF8.self)
        preview = preview.replacingOccurrences(of: "\"target\":\"export\"", with: "\"target\":\"preview\"")
        XCTAssertThrowsError(try h.preflight(self, plan: Data(preview.utf8), settings: ExportPlans.settings(640, 360, fps: 30))) {
            XCTAssertEqual(EngineError.from($0).code, .planInvalid)
        }
        // Mid tier: 4K only with ≤ 2 video layers.
        let mid = try make(ExportHarness.Options(probe: EncoderProbe { _, _, _ in true }, tier: .mid))
        XCTAssertEqual(try mid.preflight(self, plan: plan, settings: ExportPlans.settings(640, 360, fps: 30)).maxHeightForPlan, 2160)
    }

    // MARK: Audio validation

    func testBadAudioReadIsRedoneWithAFreshComposition() throws {
        let h = try make()
        var pipeline: ReaderWriterPipeline?
        var corrupted = 0
        h.coordinator.configurePipeline = { p in
            pipeline = p
            p.audioSourceHook = { source, attempt in
                guard attempt == 1 else { return }
                source.corrupt = { index, samples in
                    if index == 0 {
                        corrupted += 1
                        samples[0] = .nan
                        samples[1] = 4
                    }
                }
            }
        }
        let output = h.outputURL()
        let id = try h.export(self, plan: ExportPlans.toneVideo(w: 320, h: 180, fps: 30, durUs: 1_000_000, withAudio: true),
                              settings: ExportPlans.settings(320, 180, fps: 30), output: output)
        XCTAssertNotNil(h.recorder.done(id))
        XCTAssertEqual(corrupted, 1)
        XCTAssertEqual(pipeline?.audioAttempts, 2, "a NaN read is redone once")
        let pcm = try ExportConformance.pcm(output)
        XCTAssertFalse(pcm.contains { $0.isNaN })
        XCTAssertGreaterThan(ExportConformance.rmsDb(pcm, channel: 0, 12_000, 36_000), -30, "the tone is there")
    }

    func testSamplesAreClampedBeforeTheAacInput() throws {
        // The last attempt accepts a read; its samples are still clamped to [−1, 1] and NaN → 0.
        let h = try make()
        var sources: [MixAudioSource] = []
        h.coordinator.configurePipeline = { p in
            p.maxAudioAttempts = 1
            p.audioSourceHook = { source, _ in
                sources.append(source)
                source.corrupt = { _, samples in
                    for i in stride(from: 0, to: samples.count, by: 3) { samples[i] = 5 }
                    samples[1] = .nan
                }
            }
        }
        let output = h.outputURL()
        let id = try h.export(self, plan: ExportPlans.toneVideo(w: 320, h: 180, fps: 30, durUs: 1_000_000, withAudio: true),
                              settings: ExportPlans.settings(320, 180, fps: 30), output: output)
        XCTAssertNotNil(h.recorder.done(id))
        XCTAssertGreaterThan(sources.first?.clippedSamples ?? 0, 0)
        XCTAssertGreaterThan(sources.first?.nanSamples ?? 0, 0)
        XCTAssertLessThanOrEqual(sources.first?.peak ?? 2, 1)
        let pcm = try ExportConformance.pcm(output)
        XCTAssertFalse(pcm.contains { $0.isNaN })
    }

    func testSilentAudioSourceCoversTheRangeExactly() throws {
        let source = SilentAudioSource(control: nil)
        try source.openAudio(startUs: 0, endUs: 1_000_000)
        var frames = 0
        var lastEnd = CMTime.zero
        while let buffer = try source.nextAudio() {
            XCTAssertEqual(CMSampleBufferGetPresentationTimeStamp(buffer), lastEnd)
            let n = CMSampleBufferGetNumSamples(buffer)
            frames += n
            lastEnd = CMTimeAdd(lastEnd, CMTime(value: CMTimeValue(n), timescale: 48_000))
        }
        XCTAssertEqual(frames, 48_000)
    }
}
