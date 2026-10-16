// OWNER: FIX-IOS-D7
//
// QA-05 re-check defect D7 and QA-01 FIX-IOS-12-1 (exploration; see the final header below).

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
        "{\"id\":\"\(id)#v\",\"z\":10,\"seq\":0,\"t\":[\(t0),\(t1)],\"kind\":\"media\",\"asset\":\"\(asset)\",\"map\":[[\(t0),\(t1),\(s0),\(s1)]],\"base\":[\(w),\(h)]}"
    }

    static func seg(_ id: String, _ asset: String, _ t0: Int64, _ t1: Int64, _ s0: Int64, _ s1: Int64) -> String {
        "{\"id\":\"\(id)#a\",\"asset\":\"\(asset)\",\"t\":[\(t0),\(t1)],\"map\":[[\(t0),\(t1),\(s0),\(s1)]],\"gain\":[[\(t0),1]]}"
    }

    /// Main-lane clips of the soak project (`soak-failed-800.json`, seed 5150 op #800): id, asset,
    /// t0, t1, s0, s1 as compiled by CORE-33 (`compileExport`), reversed pieces read from the
    /// reversed rendition.
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

    static let durUs: Int64 = 39_033_334

    /// The soak project as an export plan at [w]×[h] 30 fps (texts left out: sprites never reach
    /// the reader).
    static func soak800(w: Int = 640, h: Int = 360, durUs: Int64 = durUs, audio include: (String) -> Bool = { _ in true }) -> Data {
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
                                audio: audio.map(\.json).filter(include))
    }
    static func unused() {
    }
}

// MARK: - Tests

final class Atomic {
    private let lock = NSLock()
    private var v = false
    var value: Bool {
        get { lock.lock(); defer { lock.unlock() }; return v }
        set { lock.lock(); v = newValue; lock.unlock() }
    }
}

final class ExportD7Tests: XCTestCase {
    private static var reversedURL: URL?
    private static var reverseRoots: TempRoots?

    /// The reversed rendition of tone_under_video (0–8 s) made by IOS-04's ReverseJob, as the
    /// soak's reverse op made it.
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

    private func buildComposition(_ roots: Paths, _ plan: RenderPlan) throws -> ExportComposition {
        let session = try DVRenderSession(snapshots: ParamSnapshotStore(ParamSnapshot(plan: plan)), qos: .userInitiated)
        var options = CompositionBuildOptions(spacerDirectory: roots.engineAssets)
        options.renderSize = CGSize(width: plan.canvas.w, height: plan.canvas.h)
        options.validate = false
        options.resolveURL = { _, asset in try ExportD7Tests.resolve(asset) }
        session.configure(&options)
        let input = UncheckedSendable((plan, options))
        let built = try MediaBlocking.await { try await CompositionBuilder.build(plan: input.value.0, options: input.value.1) }
        return ExportComposition(built: built, session: session)
    }

    /// Reads the whole audio mix; returns (buffers, last pts s) or nil when hung.
    private func readMix(_ c: ExportComposition, timeout: TimeInterval = 15) throws -> (Int, Double)? {
        let reader = try AVAssetReader(asset: c.built.composition)
        reader.timeRange = ExportTime.readerRange(startUs: 0, endUs: c.built.plan.durUs, plan: c.built.plan)
        let output = AVAssetReaderAudioMixOutput(audioTracks: c.audioTracks, audioSettings: ExportPCM.readerSettings)
        output.audioMix = c.built.audioMix
        output.audioTimePitchAlgorithm = .timeDomain
        reader.add(output)
        XCTAssertTrue(reader.startReading())
        let lock = NSLock()
        var n = 0
        var last = 0.0
        let done = DispatchSemaphore(value: 0)
        DispatchQueue(label: "d7.probe").async {
            while let s = output.copyNextSampleBuffer() {
                lock.lock()
                n += 1
                last = CMSampleBufferGetPresentationTimeStamp(s).seconds
                lock.unlock()
            }
            done.signal()
        }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            SegmentedWriter.keepAbandoned([reader, output, c])
            lock.lock(); defer { lock.unlock() }
            print("D7 probe: HUNG after \(n) buffers, last \(last) s, tracks \(c.audioTracks.map(\.trackID))")
            return nil
        }
        lock.lock(); defer { lock.unlock() }
        print("D7 probe: read \(n) buffers, last \(last) s, status \(reader.status.rawValue) \(String(describing: reader.error))")
        return (n, last)
    }

    func testProbeSoakMixUnderLoad() throws {
        let h = try ExportHarness()
        defer { h.remove() }
        let plan = try RenderPlanDecoder.decodePlan(D7Plans.soak800())
        let stop = Atomic()
        for i in 0..<6 {
            Thread.detachNewThread {
                Thread.current.qualityOfService = i % 2 == 0 ? .userInitiated : .utility
                var x = 0.0
                while !stop.value { for k in 0..<10_000 { x += sin(Double(k)) } }
                _ = x
            }
        }
        defer { stop.value = true }
        var hung = 0
        for round in 0..<4 {
            let comps = try (0..<4).map { _ in try buildComposition(h.paths, plan) }
            let group = DispatchGroup()
            let lock = NSLock()
            for (k, c) in comps.enumerated() {
                group.enter()
                DispatchQueue.global(qos: .userInitiated).async {
                    let r = try? self.readMix(c, timeout: 40)
                    lock.lock()
                    if r == nil { hung += 1 }
                    lock.unlock()
                    print("D7 load round \(round) reader \(k): \(String(describing: r))")
                    group.leave()
                }
            }
            group.wait()
        }
        print("D7 load: hung \(hung) of 16")
    }

    func testReproHungReadUseAfterFree() throws {
        var options = ExportHarness.Options()
        options.segmentDurationUs = 10_000_000
        print("D7 repro: making harness")
        let h = try ExportHarness(options)
        print("D7 repro: harness made")
        defer { h.remove() }
        h.coordinator.environment.resolveURL = { _, asset in try ExportD7Tests.resolve(asset) }
        h.coordinator.configurePipeline = { p in
            p.audioWatchdog = 1
            p.audioSourceHook = { source, attempt in
                guard attempt == 1 else { return }
                source.readGate = { n in if n == 3 { Thread.sleep(forTimeInterval: 8) } }
            }
        }
        let s = ExportPlans.settings(320, 180, fps: 30)
        let out = h.outputURL()
        let id: String
        do { id = try h.start(self, plan: D7Plans.soak800(w: 320, h: 180), settings: s, output: out) } catch { print("D7 repro: start failed \(error)"); throw error }
        XCTAssertTrue(JobEventRecorder.spin(timeout: 120) { h.recorder.ended(id) })
        print("D7 repro: done \(h.recorder.done(id) != nil) failure \(h.recorder.failure(id)?.message ?? "-")")
        _ = JobEventRecorder.spin(timeout: 10) { false }
    }

    func testProbeSoakMix() throws {
        let h = try ExportHarness()
        defer { h.remove() }
        let plan = try RenderPlanDecoder.decodePlan(D7Plans.soak800())
        for k in 0..<3 {
            let c = try buildComposition(h.paths, plan)
            for t in c.audioTracks {
                let segs = t.segments.map { "[\($0.timeMapping.target.start.seconds)-\($0.timeMapping.target.end.seconds) src \($0.timeMapping.source.start.seconds)-\($0.timeMapping.source.end.seconds) \($0.isEmpty ? "E" : "")]" }
                print("D7 track \(t.trackID): \(segs.joined(separator: " "))")
            }
            let r = try readMix(c)
            print("D7 attempt \(k): \(String(describing: r))")
        }
    }
}
