// OWNER: FIX-IOS-SPACER
//
// The spacer layout of IOS-08's CompositionBuilder (ARCH §13.2, D-35). The one-frame spacer (1/30 s)
// covers CMTime(0…K, gridFps) as n whole spacer durations in one integrally scaled edit plus an
// unscaled remainder edit (< 1/30 s), never as one fractionally scaled edit: a reader starting
// inside a fractionally scaled spacer edit blocks in `copyNextSampleBuffer` forever (iOS 26.5
// simulator; 60 fps × 179 frames at 2.0 s, 48 fps × 49 frames at 0.5 s — FIX-IOS-DURATION).
// - the layout arithmetic (n, whole, remainder) is exact for 24/25/30/48/50/60 fps;
// - built compositions carry that layout (segment count, scale of each edit, end = K/gridFps);
// - readers over the export composition (DVCompositor) starting at every grid frame and at µs
//   offsets (segment starts, inside the remainder) deliver a sample or complete, within a timeout;
// - preview playback over such a plan plays through to the last frame and stops there;
// - a multi-pass precompose (IOS-20) of a 60 fps × 179-frame project with 1 s segments (segment
//   readers start inside the spacer) completes with K frames ending on the grid end.

import AVFoundation
import XCTest

@testable import danaview_editor_engine

final class SpacerLayoutTests: XCTestCase {
    /// (fps, K) cases whose span K/fps is not a whole number of spacer durations, plus whole ones.
    private static let fractional: [(Int, Int64)] = [(60, 179), (48, 49), (24, 73), (30, 91), (25, 51), (50, 101), (60, 1), (48, 1)]
    private static let whole: [(Int, Int64)] = [(60, 180), (30, 90), (24, 72)]

    // MARK: Layout arithmetic

    func testSpacerLayoutArithmetic() throws {
        let unit = CMTime(value: 1, timescale: 30)
        for (fps, k) in Self.fractional + Self.whole {
            let end = CMTime(value: k, timescale: CMTimeScale(fps))
            let l = try XCTUnwrap(CompositionBuilder.spacerLayout(end: end, unit: unit), "\(fps)×\(k)")
            XCTAssertEqual(l.n, k * 30 / Int64(fps), "\(fps)×\(k): n = floor(K·30/fps)")
            XCTAssertEqual(CMTimeCompare(CMTimeAdd(l.whole, l.remainder), end), 0, "\(fps)×\(k): whole + remainder = end")
            XCTAssertTrue(CMTimeCompare(l.remainder, unit) < 0 && CMTimeCompare(l.remainder, .zero) >= 0, "\(fps)×\(k): remainder < unit")
            XCTAssertEqual(l.remainder == .zero, (k * 30) % Int64(fps) == 0, "\(fps)×\(k): remainder only when fractional")
        }
        // A spacer track of another timescale (600) gives the same split.
        let l = try XCTUnwrap(CompositionBuilder.spacerLayout(end: CMTime(value: 179, timescale: 60), unit: CMTime(value: 20, timescale: 600)))
        XCTAssertEqual(l.n, 89)
        XCTAssertEqual(CMTimeCompare(l.remainder, CMTime(value: 1, timescale: 60)), 0)
        XCTAssertNil(CompositionBuilder.spacerLayout(end: .zero, unit: CMTime(value: 1, timescale: 30)))
        XCTAssertNil(CompositionBuilder.spacerLayout(end: .invalid, unit: CMTime(value: 1, timescale: 30)))
    }

    // MARK: Built compositions

    private static func plan(fps: Int, k: Int64, target: String = "export", w: Int = 320, h: Int = 180) throws -> RenderPlan {
        let durUs = FrameGrid(fps).timeOfFrame(k)
        var data = ExportPlans.plan(
            w: w, h: h, fps: fps, durUs: durUs, assets: [],
            layers: [ExportPlans.solid("it_s0000000001#v", t0: 0, t1: durUs, color: "#FF0000FF",
                                       w: Double(w) / 3, h: Double(h) / 3, cx: Double(w) / 2, cy: Double(h) / 2)])
        if target != "export" {
            data = Data(String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\"target\":\"export\"", with: "\"target\":\"\(target)\"").utf8)
        }
        return try RenderPlanDecoder.decodePlan(data)
    }

    /// The export composition of [plan] (DVCompositor with its render session, as ExportCoordinator builds it).
    private static func exportComposition(_ plan: RenderPlan) throws -> (BuiltComposition, DVRenderSession) {
        let session = try DVRenderSession(snapshots: ParamSnapshotStore(ParamSnapshot(plan: plan)), qos: .userInitiated)
        var options = CompositionBuildOptions(spacerDirectory: try CompositionTestSupport.spacerDirectory())
        options.renderSize = CGSize(width: plan.canvas.w, height: plan.canvas.h)
        options.useProxies = false
        options.validate = false
        session.configure(&options)
        let input = UncheckedSendable((plan, options))
        let built = try MediaBlocking.await { try await CompositionBuilder.build(plan: input.value.0, options: input.value.1) }
        return (built, session)
    }

    func testBuiltSpacerHasNoFractionallyScaledEdit() throws {
        for (fps, k) in Self.fractional + Self.whole {
            let plan = try Self.plan(fps: fps, k: k)
            let (built, _) = try Self.exportComposition(plan)
            defer { built.releaseMedia() }
            let track = try XCTUnwrap(built.composition.track(withTrackID: try XCTUnwrap(built.spacerTrackID)))
            let end = CMTime(value: k, timescale: CMTimeScale(fps))
            XCTAssertEqual(CMTimeCompare(track.timeRange.end, end), 0, "\(fps)×\(k): spacer ends on the grid end")
            let segments = track.segments.filter { !$0.isEmpty }
            let n = k * 30 / Int64(fps)
            let hasRemainder = (k * 30) % Int64(fps) != 0
            XCTAssertEqual(segments.count, (n > 0 ? 1 : 0) + (hasRemainder ? 1 : 0), "\(fps)×\(k): edits")
            for seg in segments {
                let source = seg.timeMapping.source.duration.seconds
                let target = seg.timeMapping.target.duration.seconds
                let ratio = target / source
                XCTAssertEqual(ratio, ratio.rounded(), accuracy: 1e-9, "\(fps)×\(k): edit scale \(ratio) is integral")
            }
        }
    }

    // MARK: Readers at many offsets

    private enum ReadResult: Equatable {
        case sample(CMTime)
        case completed
        case failed(String)
        case hung
    }

    /// Opens a reader over [start, end) of [built] and returns its first sample, or that it
    /// completed, failed or hung (no answer within [timeout] s).
    private static func firstSample(_ built: BuiltComposition, start: CMTime, end: CMTime, timeout: TimeInterval = 15) -> ReadResult {
        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: built.composition)
        } catch {
            return .failed("\(error)")
        }
        reader.timeRange = CMTimeRange(start: start, end: end)
        let output = AVAssetReaderVideoCompositionOutput(
            videoTracks: built.composition.tracks(withMediaType: .video), videoSettings: CompositionVideoSource.videoSettings)
        output.videoComposition = built.videoComposition
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return .failed("output refused") }
        reader.add(output)
        guard reader.startReading() else { return .failed("startReading: \(String(describing: reader.error))") }
        let result = Locked<ReadResult?>(nil)
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            let r: ReadResult
            if let sb = output.copyNextSampleBuffer() {
                r = .sample(CMSampleBufferGetPresentationTimeStamp(sb))
            } else if reader.status == .completed {
                r = .completed
            } else {
                r = .failed("status \(reader.status.rawValue): \(String(describing: reader.error))")
            }
            result.mutate { $0 = r }
            done.signal()
        }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            // Never cancel or release a reader under a blocked copyNextSampleBuffer (FIX-IOS-D7).
            SegmentedWriter.keepAbandoned([reader, output, built])
            return .hung
        }
        reader.cancelReading()
        return result.value ?? .hung
    }

    func testReadersStartingAnywhereNeverHang() throws {
        // The two compositions that hung, the other off-grid rates, and a whole ratio for reference.
        let cases: [(Int, Int64)] = [(60, 179), (48, 49), (24, 73), (50, 101), (60, 1), (60, 180)]
        for (fps, k) in cases {
            let plan = try Self.plan(fps: fps, k: k)
            let (built, session) = try Self.exportComposition(plan)
            defer { built.releaseMedia() }
            _ = session
            let ts = CMTimeScale(fps)
            let end = CMTime(value: k, timescale: ts)
            var starts: [CMTime] = []
            // Every grid frame for short spans, every third otherwise (always the last few).
            let step: Int64 = k > 60 ? 3 : 1
            for f in stride(from: Int64(0), to: k, by: Int(step)) { starts.append(CMTime(value: f, timescale: ts)) }
            for f in max(0, k - 4)..<k { starts.append(CMTime(value: f, timescale: ts)) }
            // µs starts (segment starts of the export pipeline, the ones that hung) and off-grid ones.
            for us: Int64 in [500_000, 1_000_000, 2_000_000, 333_333, 1_234_567] {
                let t = CMTime(value: us, timescale: 1_000_000)
                if CMTimeCompare(t, end) < 0 { starts.append(t) }
            }
            // Inside the remainder edit (the last, unscaled spacer edit) and inside the last frame.
            if let l = CompositionBuilder.spacerLayout(end: end, unit: CMTime(value: 1, timescale: 30)), l.remainder > .zero {
                starts.append(CMTimeAdd(l.whole, CMTimeMultiplyByRatio(l.remainder, multiplier: 1, divisor: 3)))
                starts.append(l.whole)
            }
            starts.append(CMTimeSubtract(end, CMTime(value: 1, timescale: ts * 4)))
            for start in starts {
                let r = Self.firstSample(built, start: start, end: end)
                switch r {
                case .sample(let pts):
                    // The first frame is the one on or right before the start (never past the end).
                    XCTAssertTrue(CMTimeCompare(pts, end) < 0, "\(fps)×\(k) from \(start.seconds): pts \(pts.seconds) past the end")
                    XCTAssertLessThanOrEqual(abs(pts.seconds - start.seconds), 1.0 / Double(fps) + 1e-6,
                                             "\(fps)×\(k) from \(start.seconds): first pts \(pts.seconds)")
                case .completed:
                    // Only a start inside the last frame may legitimately find nothing to compose.
                    XCTAssertGreaterThan(start.seconds, Double(k - 1) / Double(fps) - 1e-9,
                                         "\(fps)×\(k) from \(start.seconds): no sample")
                case .failed(let why):
                    XCTFail("\(fps)×\(k) from \(start.seconds): \(why)")
                case .hung:
                    XCTFail("\(fps)×\(k) from \(start.seconds): copyNextSampleBuffer hung")
                }
            }
        }
    }

    func testFullReadDeliversEveryFrame() throws {
        for (fps, k) in [(60, Int64(179)), (48, 49), (24, 73)] {
            let plan = try Self.plan(fps: fps, k: k)
            let (built, session) = try Self.exportComposition(plan)
            defer { built.releaseMedia() }
            _ = session
            let end = CMTime(value: k, timescale: CMTimeScale(fps))
            let reader = try AVAssetReader(asset: built.composition)
            reader.timeRange = CMTimeRange(start: .zero, end: end)
            let output = AVAssetReaderVideoCompositionOutput(
                videoTracks: built.composition.tracks(withMediaType: .video), videoSettings: CompositionVideoSource.videoSettings)
            output.videoComposition = built.videoComposition
            output.alwaysCopiesSampleData = false
            reader.add(output)
            XCTAssertTrue(reader.startReading())
            let frames = Locked<[Int64]>([])
            let done = DispatchSemaphore(value: 0)
            DispatchQueue.global(qos: .userInitiated).async {
                while let sb = output.copyNextSampleBuffer() {
                    let pts = CMSampleBufferGetPresentationTimeStamp(sb)
                    frames.mutate { $0.append(FrameGrid(fps: Int64(fps)).frameIndexNearest(pts)) }
                }
                done.signal()
            }
            if done.wait(timeout: .now() + 60) == .timedOut {
                // Never cancel or release a reader under a blocked copyNextSampleBuffer (FIX-IOS-D7).
                SegmentedWriter.keepAbandoned([reader, output, built, session])
                XCTFail("\(fps)×\(k): full read hung after \(frames.value.count) frames")
                continue
            }
            XCTAssertEqual(reader.status, .completed, "\(fps)×\(k)")
            XCTAssertEqual(frames.value, Array(0..<k), "\(fps)×\(k): every grid frame once")
        }
    }

    // MARK: Preview

    /// A preview session at [fps] (solid-only plans need no media).
    private final class Preview: @unchecked Sendable {
        let hub = EventHub(limits: EventHub.RateLimits(clock: 0, progress: 0, recorderLevel: 0))
        let registry = RecordingTextureRegistry()
        let queue = DispatchQueue(label: "test.spacerPreview", qos: .userInteractive)
        let session: PreviewSession

        init(fps: Int64) throws {
            var deps = PreviewSession.Dependencies(
                registry: registry, events: hub, spacerDirectory: try CompositionTestSupport.spacerDirectory())
            deps.maxPreviewLongSide = 640
            deps.audioSession = FakeAudioSession()
            deps.observeLifecycle = false
            let config = PreviewConfigMsg(canvasWidth: 640, canvasHeight: 360, fps: fps, quality: .full, useProxies: false)
            session = try PreviewSession(id: "pv_spacer_\(fps)", config: config, queue: queue, dependencies: deps)
        }

        func call<T>(timeout: TimeInterval = 20, _ body: @escaping (PreviewSession, @escaping EngineReply<T>) -> Void) async throws -> T {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<T, Error>) in
                let once = Locked(false)
                let finish: (Result<T, Error>) -> Void = { r in
                    var first = false
                    once.mutate { first = !$0; $0 = true }
                    if first { c.resume(with: r) }
                }
                queue.async { body(self.session) { finish($0) } }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                    finish(.failure(PreviewHarness.Timeout(what: "spacer preview call")))
                }
            }
        }

        func onQueue<T>(_ body: @escaping (PreviewSession) -> T) -> T { queue.sync { body(session) } }

        func dispose() async {
            _ = try? await call(timeout: 10) { (s: PreviewSession, r: @escaping EngineReply<Void>) in s.dispose { r(.success(())) } }
        }
    }

    func testPreviewPlaysToTheEnd() async throws {
        for (fps, k, from) in [(60, Int64(179), Int64(120)), (48, 49, 24)] {
            let p = try Preview(fps: Int64(fps))
            _ = try await p.call(timeout: 10) { (s: PreviewSession, r: @escaping EngineReply<Int64>) in s.registerTexture { r(.success($0)) } }
            let plan = try Self.plan(fps: fps, k: k, target: "preview", w: 640, h: 360)
            let data = PlanEncoder.encode(plan)
            _ = try await p.call { (s: PreviewSession, r: @escaping EngineReply<PlanAckMsg>) in s.setPlan(data, reply: r) }
            XCTAssertEqual(p.onQueue { $0.frameCount }, k, "\(fps)×\(k)")
            // Seek into the spacer edit (0.5 s at 48 fps, 2.0 s at 60 fps: the starts that hung).
            let t = FrameGrid(fps).timeOfFrame(from)
            let ack = try await p.call { (s: PreviewSession, r: @escaping EngineReply<SeekAckMsg>) in s.seek(timeUs: t, exact: true, reply: r) }
            XCTAssertEqual(ack.displayedFrame, from, "\(fps)×\(k): seek ack")
            _ = try await p.call { (s: PreviewSession, r: @escaping EngineReply<Int64>) in s.play(loop: nil, reply: r) }
            let started = await PreviewHarness.wait(3) { p.onQueue { $0.playing } }
            XCTAssertTrue(started, "\(fps)×\(k): playing")
            let ended = await PreviewHarness.wait(10) { !p.onQueue { $0.playing } }
            XCTAssertTrue(ended, "\(fps)×\(k): playback reaches the end and stops")
            XCTAssertEqual(p.onQueue { $0.currentFrame }, k - 1, "\(fps)×\(k): stops on the last frame")
            XCTAssertEqual(p.session.bridge.current?.k, k - 1, "\(fps)×\(k): the last frame is on the texture")
            await p.dispose()
        }
    }

    // MARK: Precompose (IOS-20)

    func testPrecomposeOffTheWholeMicrosecondGridCompletes() throws {
        let fps = 60
        let k: Int64 = 179
        let durUs = FrameGrid(fps).timeOfFrame(k)
        let (w, h) = (320, 180)
        var layers: [String] = []
        for seq in 0..<3 {
            layers.append(ExportPlans.mediaLayer(
                "it_fc\(seq)00000000#v", asset: "md_fc0000000001", seq: seq, t0: 0, t1: durUs, s0: Int64(seq) * 1_000_000,
                w: Double(w) / Double(seq + 1), h: Double(h) / Double(seq + 1), z: 10 + seq))
        }
        let plan = ExportPlans.plan(
            w: w, h: h, fps: fps, durUs: durUs,
            assets: [ExportPlans.video("md_fc0000000001", file: "frame_counter_720p25.mp4", w: 1280, h: 720, durUs: 8_000_000, hasAudio: false)],
            layers: layers)
        let settings = ExportPlans.settings(w, h, fps: fps, videoBitrate: 600_000)
        let p = try PrecomposeHarness(decoderLimit: 2, segmentDurationUs: 1_000_000)
        defer { p.h.remove() }
        let output = p.h.outputURL("mp4")
        let id = try p.h.export(self, plan: plan, settings: settings, output: output, timeout: 300)
        if let failure = p.h.recorder.failure(id) {
            XCTFail("precompose 60 fps × 179: \(failure.code) \(failure.message)")
            return
        }
        XCTAssertFalse(p.exporter.runs.isEmpty, "the decoder limit forces precompose passes")
        let facts = try ExportConformance.check(output, settings: settings, durUs: durUs, brand: "mp42", codec: "avc1", checkBitrate: false)
        XCTAssertEqual(facts.frames, Int(k))
        XCTAssertLessThanOrEqual(abs(Double(facts.videoDurationUs) - Double(k) * 1_000_000 / Double(fps)), 1_000, "video ends on the grid end")
    }
}
