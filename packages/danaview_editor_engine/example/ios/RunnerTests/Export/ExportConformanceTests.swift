// OWNER: IOS-12
//
// IOS-12 acceptance: MP4 and MOV H.264 (simulator) and HEVC (device; skipped where no HEVC
// encoder exists) outputs pass the §14.4 conformance checks; projects with no audio, with every
// clip muted or soloed out (export plans then carry no audio segment) and with images/text only
// produce a silent AAC 48 kHz stereo track; an export plan with gridFps 30 and fps 24 passes; A/V
// offset ≤ 1 frame and ≤ 20 ms on clap_flash; 200 % volume measures +6.02 ± 0.1 dB.

import AVFoundation
import XCTest

@testable import danaview_editor_engine

final class ExportConformanceTests: XCTestCase {
    private var harness: ExportHarness!

    override func setUpWithError() throws {
        harness = try ExportHarness()
    }

    override func tearDown() {
        harness?.remove()
        harness = nil
    }

    private func assertDone(_ id: String, file: StaticString = #filePath, line: UInt = #line) throws -> ExportResultMsg {
        if let failure = harness.recorder.failure(id) {
            XCTFail("export failed: \(failure.code) \(failure.message)", file: file, line: line)
        }
        return try XCTUnwrap(harness.recorder.done(id)?.exportResult, "no export result", file: file, line: line)
    }

    /// Barcodes of the decoded output frames (nil where unreadable).
    private func barcodes(_ url: URL) throws -> [Int?] {
        var out: [Int?] = []
        try ExportConformance.frames(url) { _, pb in out.append(CompositorTestSupport.barcode(pb)) }
        return out
    }

    // MARK: Containers and codecs

    func testMp4H264Conformance() throws {
        let durUs: Int64 = 3_000_000
        let settings = ExportPlans.settings(640, 360, fps: 30, videoBitrate: 600_000)
        let output = harness.outputURL("mp4")
        let id = try harness.export(self, plan: ExportPlans.toneVideo(w: 640, h: 360, fps: 30, durUs: durUs, withAudio: true),
                                    settings: settings, output: output)
        let result = try assertDone(id)
        XCTAssertEqual(result.path, output.path)
        XCTAssertEqual(result.durationUs, durUs)
        XCTAssertEqual(result.bytes, SegmentedWriter.fileSize(output))
        XCTAssertEqual(result.videoEncoderName, "VideoToolbox H.264")
        let facts = try ExportConformance.check(output, settings: settings, durUs: durUs, brand: "mp42", codec: "avc1")
        XCTAssertTrue(facts.transform.isIdentity)
        // Frame accuracy through 3 segments + concat: the frame_counter barcodes 0…89 in order.
        let codes = try barcodes(output)
        XCTAssertEqual(codes.count, 90)
        let readable = codes.enumerated().filter { $0.element != nil }
        XCTAssertGreaterThan(readable.count, 80, "barcodes readable after encode")
        for (k, code) in readable { XCTAssertEqual(code, k, "frame \(k)") }
        // The job directory and its segments are gone after success.
        XCTAssertFalse(FileManager.default.fileExists(atPath: ExportJob.directory(for: id, work: harness.paths.work).path))
        // Audio is the tone (not silence).
        let pcm = try ExportConformance.pcm(output)
        XCTAssertGreaterThan(ExportConformance.rmsDb(pcm, channel: 0, 24_000, 120_000), -30)
        // Progress events: phases in order, frames on the export grid, ending at 1.
        let progress = harness.progress(id)
        XCTAssertFalse(progress.isEmpty)
        XCTAssertEqual(progress.last?.phase, .finishing)
        XCTAssertEqual(progress.last?.framesTotal, 90)
        XCTAssertEqual(progress.last?.fraction ?? 0, 1, accuracy: 1e-9)
        XCTAssertTrue(progress.contains { $0.phase == .rendering && $0.fraction > 0 && $0.fraction < 1 })
        XCTAssertTrue(progress.allSatisfy { $0.warnings.contains { $0.code == "softwareEncoder" } || !isSimulator })
    }

    private var isSimulator: Bool {
        #if targetEnvironment(simulator)
            return true
        #else
            return false
        #endif
    }

    func testMovH264ExportAt24FromGrid30() throws {
        // gridFps 30 (edit points) and output fps 24: the export plan of a 30 fps project at 24 fps.
        let durUs: Int64 = 2_000_000
        let settings = ExportPlans.settings(640, 360, fps: 24, container: .mov, videoBitrate: 500_000)
        let output = harness.outputURL("mov")
        let plan = ExportPlans.plan(
            w: 640, h: 360, fps: 24, gridFps: 30, durUs: durUs,
            assets: [ExportPlans.video("md_tone00000001", file: "tone_under_video.mp4", w: 1280, h: 720, durUs: 8_000_000, hasAudio: true)],
            layers: [
                ExportPlans.mediaLayer("it_a0000000001#v", asset: "md_tone00000001", seq: 0, t0: 0, t1: 1_033_334, w: 640, h: 360),
                ExportPlans.mediaLayer("it_b0000000001#v", asset: "md_tone00000001", seq: 0, t0: 1_033_334, t1: durUs, s0: 4_000_000,
                                       w: 640, h: 360),
            ],
            audio: [ExportPlans.audioSeg("it_a0000000001#a", asset: "md_tone00000001", t0: 0, t1: durUs)])
        let id = try harness.export(self, plan: plan, settings: settings, output: output)
        _ = try assertDone(id)
        try ExportConformance.check(output, settings: settings, durUs: durUs, brand: "qt  ", codec: "avc1")
        // Output frame k shows the source frame at timeOfFrame(k) on the 24 fps grid; the cut at
        // grid frame 31 (1.033334 s) switches to source 4 s (barcode ≥ 120).
        let codes = try barcodes(output)
        XCTAssertEqual(codes.count, 48)
        let grid24 = FrameGrid(24)
        for (k, code) in codes.enumerated() {
            guard let code = code else { continue }
            let t = grid24.timeOfFrame(Int64(k))
            if t < 1_033_334 {
                XCTAssertEqual(code, Int(FrameGrid(30).frameIndexOf(t)), "frame \(k)")
            } else {
                XCTAssertGreaterThanOrEqual(code, 120, "frame \(k) after the cut")
            }
        }
    }

    func testHevcConformanceWhereAvailable() throws {
        guard Capabilities.testEncode(codec: kCMVideoCodecType_HEVC, width: 640, height: 360),
              harness.coordinator.environment.encoders().hevc
        else {
            throw XCTSkip("HEVC encode: deferred: no device available (the simulator encodes software H.264 only)")
        }
        let durUs: Int64 = 2_000_000
        let settings = ExportPlans.settings(640, 360, fps: 30, codec: .hevc, videoBitrate: 800_000)
        let output = harness.outputURL("mp4")
        let id = try harness.export(self, plan: ExportPlans.toneVideo(w: 640, h: 360, fps: 30, durUs: durUs, withAudio: true),
                                    settings: settings, output: output)
        XCTAssertEqual(try assertDone(id).videoEncoderName, "VideoToolbox HEVC")
        try ExportConformance.check(output, settings: settings, durUs: durUs, brand: "mp42", codec: "hvc1")
    }

    func testHevcFallsBackToH264WhenUnavailable() throws {
        let fallback = try ExportHarness(ExportHarness.Options(encoders: .softwareH264Only))
        defer { fallback.remove() }
        let durUs: Int64 = 1_000_000
        let settings = ExportPlans.settings(320, 180, fps: 30, codec: .hevc, videoBitrate: 600_000)
        let output = fallback.outputURL("mp4")
        let id = try fallback.export(self, plan: ExportPlans.noAudioVideo(w: 320, h: 180, fps: 30, durUs: durUs), settings: settings, output: output)
        XCTAssertNil(fallback.recorder.failure(id))
        XCTAssertEqual(fallback.recorder.done(id)?.exportResult?.videoEncoderName, "VideoToolbox H.264")
        XCTAssertTrue(fallback.progress(id).last?.warnings.contains { $0.code == "hevcUnavailable" } ?? false)
        try ExportConformance.check(output, settings: settings, durUs: durUs, brand: "mp42", codec: "avc1", checkBitrate: false)
    }

    // MARK: Silent audio (D-38)

    private func assertSilentAac(_ output: URL, durUs: Int64, file: StaticString = #filePath, line: UInt = #line) throws {
        let pcm = try ExportConformance.pcm(output)
        XCTAssertGreaterThanOrEqual(pcm.count / 2, Int(Double(durUs) * 0.048) - 2_048, "audio covers the duration", file: file, line: line)
        XCTAssertLessThan(ExportConformance.peak(pcm), 1e-4, "silent", file: file, line: line)
    }

    func testNoAudioProjectWritesSilentAacTrack() throws {
        let durUs: Int64 = 2_000_000
        let settings = ExportPlans.settings(640, 360, fps: 25, videoBitrate: 1_000_000)
        let output = harness.outputURL("mp4")
        let id = try harness.export(self, plan: ExportPlans.noAudioVideo(w: 640, h: 360, fps: 25, durUs: durUs), settings: settings, output: output)
        _ = try assertDone(id)
        try ExportConformance.check(output, settings: settings, durUs: durUs, brand: "mp42", codec: "avc1", checkBitrate: false)
        try assertSilentAac(output, durUs: durUs)
    }

    func testAllMutedOrSoloedOutProjectWritesSilentAacTrack() throws {
        // A muted (or soloed-out) clip has no audio segment in an export plan (CORE-30), even though
        // its media has an audio track.
        let durUs: Int64 = 2_000_000
        let settings = ExportPlans.settings(640, 360, fps: 30, videoBitrate: 1_000_000)
        let output = harness.outputURL("mp4")
        let id = try harness.export(self, plan: ExportPlans.toneVideo(w: 640, h: 360, fps: 30, durUs: durUs, withAudio: false),
                                    settings: settings, output: output)
        _ = try assertDone(id)
        try ExportConformance.check(output, settings: settings, durUs: durUs, brand: "mp42", codec: "avc1", checkBitrate: false)
        try assertSilentAac(output, durUs: durUs)
    }

    func testImagesAndTextOnlyProjectWritesSilentAacTrack() throws {
        let durUs: Int64 = 2_000_000
        let settings = ExportPlans.settings(640, 360, fps: 30, videoBitrate: 800_000)
        let output = harness.outputURL("mp4")
        let plan = ExportPlans.plan(
            w: 640, h: 360, fps: 30, durUs: durUs, bg: "#202020FF",
            assets: [ExportPlans.image("im_alpha0000001", file: "alpha.png", w: 512, h: 512)],
            layers: [
                ExportPlans.imageLayer("it_img00000001#v", asset: "im_alpha0000001", t0: 0, t1: durUs, w: 360, h: 360),
                ExportPlans.solid("it_title000001#v", t0: 500_000, t1: 1_500_000, color: "#FFFFFFFF", w: 400, h: 60, cx: 320, cy: 300, z: 15),
            ])
        let id = try harness.export(self, plan: plan, settings: settings, output: output)
        _ = try assertDone(id)
        try ExportConformance.check(output, settings: settings, durUs: durUs, brand: "mp42", codec: "avc1", checkBitrate: false)
        try assertSilentAac(output, durUs: durUs)
    }

    func testZeroGainSegmentsReadTheMixOnceAndStaySilent() throws {
        // Preview-style zero-gain segments in an export plan: the mix path runs, nothing is audible,
        // so a silent read is not suspicious (no redo) and nothing crashes.
        let durUs: Int64 = 1_000_000
        let settings = ExportPlans.settings(320, 180, fps: 30, videoBitrate: 500_000)
        let output = harness.outputURL("mp4")
        var pipelines: [ReaderWriterPipeline] = []
        harness.coordinator.configurePipeline = { pipelines.append($0) }
        let id = try harness.export(self, plan: ExportPlans.toneVideo(w: 320, h: 180, fps: 30, durUs: durUs, withAudio: true, gain: 0),
                                    settings: settings, output: output)
        _ = try assertDone(id)
        XCTAssertEqual(pipelines.first?.audioAttempts, 1)
        XCTAssertEqual(pipelines.first?.wroteSilentAudio, false)
        try assertSilentAac(output, durUs: durUs)
    }

    // MARK: A/V sync and gain

    func testClapFlashAvOffsetWithinOneFrameAnd20ms() throws {
        let durUs: Int64 = 6_000_000
        let settings = ExportPlans.settings(640, 360, fps: 30, videoBitrate: 1_500_000)
        let output = harness.outputURL("mp4")
        let plan = ExportPlans.plan(
            w: 640, h: 360, fps: 30, durUs: durUs,
            assets: [ExportPlans.video("md_clap00000001", file: "clap_flash_av.mp4", w: 1280, h: 720, durUs: durUs, hasAudio: true)],
            layers: [ExportPlans.mediaLayer("it_clap0000001#v", asset: "md_clap00000001", seq: 0, t0: 0, t1: durUs, w: 640, h: 360)],
            audio: [ExportPlans.audioSeg("it_clap0000001#a", asset: "md_clap00000001", t0: 0, t1: durUs)])
        let id = try harness.export(self, plan: plan, settings: settings, output: output)
        _ = try assertDone(id)

        // Flash frames: the first frame of each run of bright frames.
        var flashes: [Double] = []
        var wasBright = false
        try ExportConformance.frames(output) { pts, pb in
            let bright = ExportConformance.meanLuma(pb) > 170
            if bright && !wasBright { flashes.append(CMTimeGetSeconds(pts)) }
            wasBright = bright
        }
        // Click onsets: the first sample above −30 dBFS after ≥ 100 ms of near-silence.
        let pcm = try ExportConformance.pcm(output)
        var clicks: [Double] = []
        var quiet = 0
        for i in 0..<(pcm.count / 2) {
            let v = max(abs(pcm[2 * i]), abs(pcm[2 * i + 1]))
            if v > 0.03 {
                if quiet >= 4_800 { clicks.append(Double(i) / 48_000) }
                quiet = 0
            } else {
                quiet += 1
            }
        }
        XCTAssertEqual(flashes.count, 3, "flashes \(flashes)")
        XCTAssertEqual(clicks.count, 3, "clicks \(clicks)")
        for (flash, click) in zip(flashes, clicks) {
            let offset = abs(flash - click)
            XCTAssertLessThanOrEqual(offset, 0.020, "A/V offset \(offset) s at \(flash) s")
            XCTAssertLessThanOrEqual(offset, 1.0 / 30, "A/V offset within one frame")
        }
    }

    private func toneExport(gain: Double) throws -> [Float] {
        let durUs: Int64 = 2_000_000
        let settings = ExportPlans.settings(320, 180, fps: 30, videoBitrate: 400_000, audioBitrate: 256_000)
        let output = harness.outputURL("mp4")
        let plan = ExportPlans.plan(
            w: 320, h: 180, fps: 30, durUs: durUs,
            assets: [ExportPlans.audio("md_tone1k000001", file: "tone_1khz.wav", durUs: 10_000_000)],
            layers: [ExportPlans.solid("it_bg000000001#v", t0: 0, t1: durUs, color: "#3050A0FF", w: 320, h: 180, cx: 160, cy: 90)],
            audio: [ExportPlans.audioSeg("it_tone0000001#a", asset: "md_tone1k000001", t0: 0, t1: durUs, gain: [(0, gain)])])
        let id = try harness.export(self, plan: plan, settings: settings, output: output)
        _ = try assertDone(id)
        return try ExportConformance.pcm(output)
    }

    func testGain200PercentMeasuresPlus6dB() throws {
        let unity = try toneExport(gain: 1)
        let double = try toneExport(gain: 2)
        // 0.5 s … 1.5 s, both channels.
        for channel in 0..<2 {
            let a = ExportConformance.rmsDb(unity, channel: channel, 24_000, 72_000)
            let b = ExportConformance.rmsDb(double, channel: channel, 24_000, 72_000)
            XCTAssertEqual(b - a, 6.02, accuracy: 0.1, "channel \(channel): \(a) dB → \(b) dB")
        }
        XCTAssertLessThanOrEqual(ExportConformance.peak(double), 1.05)
    }
}
