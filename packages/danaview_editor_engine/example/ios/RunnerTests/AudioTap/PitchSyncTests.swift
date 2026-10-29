// OWNER: FIX-IOS-PITCH-SYNC
//
// Keep-pitch A/V sync inside scaled audio segments (QA-03 finding 2, ARCH §11.5 A/V-sync contract,
// §13.2 'Audio', §14.2). AVFoundation's `.timeDomain` time-pitch moves the audio of every edit of a
// track that has a scaled edit by a deterministic, rate-dependent amount (≈ −36 ms at 0.5×, +9 ms
// at 2×), in the export reader and in AVPlayer alike. AudioMixLayout compensates per piece by
// shifting the source read (`AudioMixLayout.pitchCompensationUs`). These tests build real plans
// through CompositionBuilder and measure click onsets (20 ms Hann 2 kHz bursts, the ENG-05
// clap_flash_av click) against their plan times:
//   - export read (AVAssetReaderAudioMixOutput, the IOS-12 format): ≤ 10 ms (QA-03 limit 20 ms and
//     one frame) at 0.5×, 0.75×, 1.5×, 2× and around the scaled segment, for 48 and 44.1 kHz
//     sources, and the QA-03 '0.5x ramp' layout on clap_flash_av (ramp-seam pairs);
//   - preview (AVPlayer): the tap output in composition time, ≤ 20 ms (preview limit 40 ms);
//   - the layout itself: which pieces move, by how much, and the clamps at the source edges.

import AVFoundation
import XCTest

@testable import danaview_editor_engine

final class PitchSyncTests: XCTestCase {
    private var dir: URL!
    /// Builds kept alive until the reads are done.
    private var keep: [BuiltComposition] = []

    override func setUpWithError() throws {
        dir = try AudioTapSupport.tempDir()
    }

    override func tearDownWithError() throws {
        keep = []
        if let dir { try? FileManager.default.removeItem(at: dir) }
    }

    // MARK: - Sources and measurement

    static let clickFirstUs = 300_000.0
    static let clickEveryUs = 600_000.0

    /// A mono Float32 WAV at [sampleRate] with a 20 ms Hann-windowed 2 kHz click (peak 0.5) at
    /// 0.3 s + k·0.6 s and digital silence between (the clap_flash_av click shape).
    private func clickSource(sampleRate: Double = 48_000, seconds: Double = 14) throws -> URL {
        let url = dir.appendingPathComponent("clicks_\(Int(sampleRate)).wav")
        let format = try XCTUnwrap(
            AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false))
        let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let total = Int(seconds * sampleRate)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(total)))
        buffer.frameLength = AVAudioFrameCount(total)
        let data = buffer.floatChannelData![0]
        for i in 0..<total { data[i] = 0 }
        let len = Int(0.020 * sampleRate)
        var t = Self.clickFirstUs
        while t < seconds * 1e6 - 50_000 {
            let start = Int((t * sampleRate / 1e6).rounded())
            for i in 0..<len {
                let w = 0.5 - 0.5 * cos(2 * Double.pi * Double(i) / Double(len))
                data[start + i] = Float(0.5 * w * sin(2 * Double.pi * 2_000 * Double(i) / sampleRate))
            }
            t += Self.clickEveryUs
        }
        try file.write(from: buffer)
        return url
    }

    /// Onset (µs; first sample at ≥ 10 % of the click's peak, the QA-03 rule) of the click within
    /// ±120 ms of [tUs] in [x] (sampled at [rate] Hz), nil when no click is there.
    static func onset(_ x: [Float], rate: Double = 48_000, near tUs: Double) -> Double? {
        let a = max(0, Int((tUs - 120_000) * rate / 1e6))
        let b = min(x.count, Int((tUs + 120_000) * rate / 1e6))
        guard a < b else { return nil }
        var peak: Float = 0
        for i in a..<b { peak = max(peak, abs(x[i])) }
        guard peak > 0.02 else { return nil }
        var i = a
        while abs(x[i]) < 0.1 * peak { i += 1 }
        return Double(i) * 1e6 / rate
    }

    /// The onset bias of the click shape itself (≈ +2 ms: the Hann burst reaches 10 % after ~2 ms).
    private func onsetBias(_ source: URL) throws -> Double {
        let file = try AVAudioFile(forReading: source)
        let n = AVAudioFrameCount(file.length)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: n))
        try file.read(into: buffer)
        let x = Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
        let on = try XCTUnwrap(Self.onset(x, rate: file.processingFormat.sampleRate, near: Self.clickFirstUs))
        return on - Self.clickFirstUs
    }

    /// Plan times (µs) of the source clicks inside [seg], at least [margin] µs inside a map piece.
    static func clickTimes(_ seg: AudioSeg, margin: Double = 150_000, clicks: [Double]? = nil) -> [(tUs: Double, rate: Double)] {
        var out: [(Double, Double)] = []
        let sources = clicks ?? Array(stride(from: clickFirstUs, to: 14_000_000, by: clickEveryUs))
        for m in seg.map {
            for s in sources where s >= Double(m.s0) && s < Double(m.s1) {
                let t = Double(m.t0) + (s - Double(m.s0)) / m.rate
                if t >= Double(m.t0) + margin, t <= Double(m.t1) - margin { out.append((t, m.rate)) }
            }
        }
        return out
    }

    // MARK: - Plans

    private func plan(_ seg: AudioSeg, asset: PlanAsset, durUs: Int64) -> RenderPlan {
        RenderPlan(
            rev: 1, target: .export, canvas: PlanCanvas(w: 64, h: 64, fps: 30), durUs: durUs,
            assets: [seg.asset: asset], layers: [], audio: [seg])
    }

    private func options(_ url: URL) throws -> CompositionBuildOptions {
        var o = CompositionBuildOptions(spacerDirectory: try CompositionTestSupport.spacerDirectory())
        o.resolveURL = { _, _ in url }
        o.validate = false
        return o
    }

    /// Reads [plan] built by CompositionBuilder through the export mix output (redoing bad reads,
    /// as IOS-12 does); returns the left channel at 48 kHz. [watchTimePitch]: also redo the reads
    /// the export's `TimePitchWatch` rejects (dropouts, dropped seam crossfades of AVFoundation's
    /// time-pitch unit; only for continuous sources: digitally gated clicks look like dropouts),
    /// and fail when no read came back good.
    private func exportRead(_ plan: RenderPlan, url: URL, watchTimePitch: Bool = false) async throws -> [Float] {
        let frames = Int(Double(plan.durUs) * 0.048)
        let options = try options(url)
        let watch = watchTimePitch ? TimePitchWatch.of(plan) : .none
        let (read, reads) = try await AudioTapSupport.readValidated(expectFrames: frames - 4_800, watch: watch, attempts: watchTimePitch ? 6 : 4) {
            let built = try await CompositionBuilder.build(plan: plan, options: options)
            keep.append(built)
            return (built.composition, try XCTUnwrap(built.audioMix), [], built.gainTaps)
        }
        if watchTimePitch {
            let bad = AudioTapSupport.badReason(read, expectFrames: frames - 4_800, audible: [], watch: watch)
            XCTAssertNil(bad, "no good export read in \(reads)")
        }
        return read.leftChannel
    }

    /// Asserts every click of [seg] is at its plan time + [bias] within [tolerance] µs; returns the
    /// worst absolute error.
    @discardableResult
    private func assertClicks(
        _ x: [Float], seg: AudioSeg, bias: Double, tolerance: Double, label: String, clicks: [Double]? = nil,
        margin: Double = 150_000
    ) -> Double {
        var worst = 0.0
        var line = "PITCHSYNC|\(label)"
        let times = Self.clickTimes(seg, margin: margin, clicks: clicks)
        XCTAssertFalse(times.isEmpty, label)
        for (t, rate) in times {
            guard let on = Self.onset(x, near: t) else {
                XCTFail("\(label): no click near \(t / 1e6) s")
                continue
            }
            let err = on - t - bias
            worst = max(worst, abs(err))
            line += String(format: "|r%.2f@%.3fs=%+.1fms", rate, t / 1e6, err / 1000)
            XCTAssertLessThanOrEqual(abs(err), tolerance, String(format: "%@: click at %.3f s (%.2f×) off by %+.1f ms", label, t / 1e6, rate, err / 1000))
        }
        print(line + String(format: "|worst=%.1fms", worst / 1000))
        return worst
    }

    private static func wavAsset(_ url: URL) -> PlanAsset {
        PlanAsset(kind: .audio, uri: url.absoluteString, durUs: 14_000_000)
    }

    // MARK: - Layout (pure)

    func testCompensationShiftsOnlyKeepPitchTracksWithAScaledPiece() {
        let asset = PlanAsset(kind: .audio, uri: "file:///a.wav", durUs: 20_000_000)
        func seg(_ id: String, _ map: [MapSegment], pitch: Bool = true) -> AudioSeg {
            AudioSeg(id: id, asset: "a", t0: map.first!.t0, t1: map.last!.t1, map: map, gain: [AnimKey(0, 1)], pitch: pitch)
        }
        // 1× | 0.5× | 2× on one keep-pitch segment (no ramp pairs), a varispeed 0.5× segment and a
        // keep-pitch unity-only segment.
        let ramp = seg("k", [MapSegment(0, 1_000_000, 2_000_000, 3_000_000), MapSegment(1_000_000, 3_000_000, 3_000_000, 4_000_000),
                             MapSegment(3_000_000, 4_000_000, 4_000_000, 6_000_000)])
        let vari = seg("v", [MapSegment(0, 2_000_000, 1_000_000, 2_000_000)], pitch: false)
        let unity = seg("u", [MapSegment(0, 2_000_000, 1_000_000, 3_000_000)])
        let p = RenderPlan(
            rev: 1, target: .export, canvas: PlanCanvas(w: 64, h: 64, fps: 30), durUs: 4_000_000,
            assets: ["a": asset], layers: [], audio: [ramp, unity, vari].sorted(by: AudioSeg.order))
        let layout = AudioMixLayout.make(p, rampSeams: false)
        func piece(_ id: String, _ k: Int) -> AudioMixLayout.Piece { layout.pieces.first { $0.segmentId == id && $0.mapIndex == k }! }
        let expected: [(Int, Double)] = [(0, 1), (1, 0.5), (2, 2)]
        for (k, r) in expected {
            let d = AudioMixLayout.pitchCompensationUs(rate: r)
            XCTAssertEqual(piece("k", k).segment.s0, ramp.map[k].s0 + d, "piece \(k)")
            XCTAssertEqual(piece("k", k).segment.s1, ramp.map[k].s1 + d, "piece \(k)")
            XCTAssertEqual(piece("k", k).segment.t0, ramp.map[k].t0)
            XCTAssertEqual(piece("k", k).segment.t1, ramp.map[k].t1)
        }
        // δ(r) = r·(A + B/r): −17.8 ms at 0.5×, −4.9 ms at 1×, +20.9 ms at 2× (source µs).
        XCTAssertEqual(AudioMixLayout.pitchCompensationUs(rate: 0.5), -17_800)
        XCTAssertEqual(AudioMixLayout.pitchCompensationUs(rate: 1), -4_900)
        XCTAssertEqual(AudioMixLayout.pitchCompensationUs(rate: 2), 20_900)
        XCTAssertEqual(piece("v", 0).segment, vari.map[0], "varispeed is not shifted")
        XCTAssertEqual(piece("u", 0).segment, unity.map[0], "a keep-pitch track without a scaled piece is not shifted")

        // Source edges: a 0.5× piece starting at source 0 would read 17.8 ms before it, so it starts
        // 35.6 ms later (trimmed, rate kept); a 2× piece ending at the asset end would read 10.9 ms
        // past it, so it ends 5.45 ms earlier. The builder's first source read is then exactly 0
        // and its last exactly the asset end.
        let edge = seg("e", [MapSegment(0, 1_000_000, 0, 500_000), MapSegment(1_000_000, 1_500_000, 500_000, 1_500_000)])
        var q = p
        q.assets = ["a": PlanAsset(kind: .audio, uri: "file:///a.wav", durUs: 1_510_000)]
        q.audio = [edge]
        for rampSeams in [false, true] {
            let trimmed = AudioMixLayout.make(q, rampSeams: rampSeams)
            let p0 = trimmed.pieces[0]
            let p1 = trimmed.pieces[1]
            XCTAssertEqual(p0.segment.s0, -17_800)
            XCTAssertEqual(p0.preUs, -35_600)
            XCTAssertEqual(p0.segment.s0 - Int64((Double(p0.preUs) * 0.5).rounded()), 0, "first source µs")
            XCTAssertEqual(p0.postUs, rampSeams ? TapEnvelope.seamCrossfadeUs / 2 : 0)
            XCTAssertEqual(p1.segment.s1, 1_520_900)
            XCTAssertEqual(p1.postUs, -5_450)
            XCTAssertEqual(p1.segment.s1 + Int64((Double(p1.postUs) * 2).rounded()), 1_510_000, "last source µs")
            XCTAssertEqual(p1.preUs, rampSeams ? TapEnvelope.seamCrossfadeUs / 2 : 0)
        }
        // A piece too short to trim keeps its plain read.
        q.audio = [seg("s", [MapSegment(0, 40_000, 0, 20_000)])]
        XCTAssertEqual(AudioMixLayout.make(q, rampSeams: false).pieces[0].segment, q.audio[0].map[0])
    }

    // MARK: - Export read

    func testKeepPitchClicksAreInSyncInsideScaledSegmentsInTheExportRead() async throws {
        for sampleRate in [48_000.0, 44_100.0] {
            let source = try clickSource(sampleRate: sampleRate)
            let bias = try onsetBias(source)
            for r in [0.5, 0.75, 1.5, 2.0] {
                // 1× | r | 1×: every piece of the track goes through the time-pitch.
                let s1 = 1_000_000 + Int64(3_000_000 * r)
                let seg = AudioSeg(
                    id: "a", asset: "s", t0: 0, t1: 6_000_000,
                    map: [MapSegment(0, 1_000_000, 0, 1_000_000), MapSegment(1_000_000, 4_000_000, 1_000_000, s1),
                          MapSegment(4_000_000, 6_000_000, s1, s1 + 2_000_000)],
                    gain: [AnimKey(0, 1)], pitch: true)
                let x = try await exportRead(plan(seg, asset: Self.wavAsset(source), durUs: 6_000_000), url: source)
                assertClicks(x, seg: seg, bias: bias, tolerance: 10_000, label: "export \(Int(sampleRate)) Hz 1x|\(r)x|1x")
            }
            // Single pieces at the source edges (trimmed instead of shifted out of the source): 0.5×
            // from source 0, 2× up to the asset end.
            for (r, s0) in [(0.5, Int64(0)), (2.0, Int64(2_000_000))] {
                let seg = AudioSeg(
                    id: "a", asset: "s", t0: 0, t1: 6_000_000, map: [MapSegment(0, 6_000_000, s0, s0 + Int64(6_000_000 * r))],
                    gain: [AnimKey(0, 1)], pitch: true)
                let x = try await exportRead(plan(seg, asset: Self.wavAsset(source), durUs: 6_000_000), url: source)
                assertClicks(x, seg: seg, bias: bias, tolerance: 10_000, label: "export \(Int(sampleRate)) Hz edge \(r)x")
            }
        }
    }

    /// The QA-03 '0.5x ramp' case (1× → 0.75× → 0.5× → 1×, keep pitch, ramp-seam pairs) on the ENG-05
    /// clap_flash_av fixture (AAC with priming in the edit list): clicks at source 1.0 / 2.5 / 4.0 s
    /// land at 1.0667 / 4.000 / 5.600 s.
    func testQa03HalfSpeedRampOnClapFlashIsInSync() async throws {
        let url = try XCTUnwrap(TestFixtures.url(.engine, "media/clap_flash_av.mp4"), "ENG-05 clap_flash_av.mp4 missing")
        let seg = AudioSeg(
            id: "it_a#a", asset: "cf", t0: 0, t1: 5_700_000,
            map: [MapSegment(0, 800_000, 0, 800_000), MapSegment(800_000, 1_200_000, 800_000, 1_100_000),
                  MapSegment(1_200_000, 4_200_000, 1_100_000, 2_600_000), MapSegment(4_200_000, 5_700_000, 2_600_000, 4_100_000)],
            gain: [AnimKey(0, 1)], pitch: true)
        let asset = PlanAsset(kind: .video, uri: url.absoluteString, w: 1280, h: 720, durUs: 6_000_000, hasAudio: true)
        let p = plan(seg, asset: asset, durUs: 5_700_000)
        XCTAssertEqual(AudioMixLayout.make(p, rampSeams: TapEnvelope.rampSeamCrossfadesEnabled).tracks.count, TapEnvelope.rampSeamCrossfadesEnabled ? 2 : 1)
        let x = try await exportRead(p, url: url)
        // The same onset bias as at 1× (QA-03 measured +2.1 ms through the whole chain).
        let clicks = [1_000_000.0, 2_500_000, 4_000_000]
        XCTAssertEqual(Self.clickTimes(seg, margin: 0, clicks: clicks).map { ($0.tUs / 1000).rounded() }, [1_067, 4_000, 5_600])
        let worst = assertClicks(x, seg: seg, bias: 2_100, tolerance: 10_000, label: "export clap_flash 0.5x ramp", clicks: clicks,
            margin: 50_000)
        XCTAssertEqual(Self.clickTimes(seg, margin: 50_000, clicks: clicks).count, 3)
        XCTAssertLessThanOrEqual(worst, 20_000)
    }

    /// A pure tone's coherent level over [a, b) frames of [x] (48 kHz).
    static func toneDb(_ x: [Float], _ a: Int, _ b: Int, freqHz: Double = 1_000) -> Double {
        let n = b - a
        var re = 0.0, im = 0.0, ws = 0.0
        let w0 = 2 * Double.pi * freqHz / 48_000
        for i in 0..<n {
            let w = 0.5 - 0.5 * cos(2 * Double.pi * Double(i) / Double(n - 1))
            let v = Double(x[a + i]) * w
            re += v * cos(w0 * Double(i))
            im -= v * sin(w0 * Double(i))
            ws += w
        }
        return 20 * log10(2 * sqrt(re * re + im * im) / ws)
    }

    /// The QA-11 / IOS-18 ramp-seam click test through CompositionBuilder (compensated offsets, the
    /// default layout): 7 × 300 ms at 1, 1.25, 1.6, 2, 1.6, 1.25, 1× over tone_1khz, keep pitch. The
    /// largest tone-predictor residual within ±40 ms of a seam exceeds the in-segment floor by
    /// ≤ 0.01 (−40 dBFS), and every segment keeps the tone at −12 ± 0.5 dBFS.
    func testRampSeamsStayCleanWithCompensation() async throws {
        let tone = try XCTUnwrap(TestFixtures.url(.engine, "media/tone_1khz.wav"), "ENG-05 tone_1khz.wav missing")
        let speeds = [1.0, 1.25, 1.6, 2.0, 1.6, 1.25, 1.0]
        var map: [MapSegment] = []
        var s0: Int64 = 500_000
        for (k, r) in speeds.enumerated() {
            let s1 = s0 + Int64((r * 300_000).rounded())
            map.append(MapSegment(Int64(k) * 300_000, Int64(k + 1) * 300_000, s0, s1))
            s0 = s1
        }
        let seg = AudioSeg(id: "a", asset: "t", t0: 0, t1: 2_100_000, map: map, gain: [AnimKey(0, 1)], pitch: true)
        let p = plan(seg, asset: PlanAsset(kind: .audio, uri: tone.absoluteString, durUs: 10_000_000), durUs: 2_100_000)
        let x = try await exportRead(p, url: tone, watchTimePitch: true)
        let e = AudioTapSupport.toneResidual(x, freqHz: 1_000)
        var floor: Float = 0
        var levels: [Double] = []
        for k in 0..<speeds.count {
            floor = max(floor, AudioTapSupport.maxAbs(e, k * 14_400 + 2_400, (k + 1) * 14_400 - 2_400))
            levels.append(Self.toneDb(x, k * 14_400 + 1_000, (k + 1) * 14_400 - 1_000))
        }
        let seams = (1..<speeds.count).map { AudioTapSupport.maxAbs(e, $0 * 14_400 - 1_920, $0 * 14_400 + 1_920) }
        let excess = Double(seams.max()! - floor)
        print(String(format: "PITCHSYNC|ramp seams|floor=%.5f|worstSeam=%.5f|excessDbfs=%.1f|levels=%@", floor, seams.max()!,
                     20 * log10(max(excess, 1e-9)), levels.map { String(format: "%.2f", $0) }.joined(separator: ",")))
        XCTAssertLessThanOrEqual(excess, 0.01, "seam transient above −40 dBFS")
        for (k, l) in levels.enumerated() { XCTAssertEqual(l, -12.04, accuracy: 0.5, "segment \(k) tone level") }
    }

    // MARK: - Preview

    /// AVPlayer runs the same `.timeDomain` time-pitch: the tap output (composition time) of a built
    /// 1× | 0.5× | 1× and 1× | 2× | 1× plan has its clicks within 20 ms (preview limit 40 ms, §12.7).
    @MainActor
    func testPreviewPlayerAudioIsInSyncInsideScaledSegments() async throws {
        let source = try clickSource()
        let bias = try onsetBias(source)
        for r in [0.5, 2.0] {
            let s1 = 1_000_000 + Int64(2_000_000 * r)
            let seg = AudioSeg(
                id: "a", asset: "s", t0: 0, t1: 4_000_000,
                map: [MapSegment(0, 1_000_000, 0, 1_000_000), MapSegment(1_000_000, 3_000_000, 1_000_000, s1),
                      MapSegment(3_000_000, 4_000_000, s1, s1 + 1_000_000)],
                gain: [AnimKey(0, 1)], pitch: true)
            var p = plan(seg, asset: Self.wavAsset(source), durUs: 4_000_000)
            p.target = .preview
            let built = try await CompositionBuilder.build(plan: p, options: try options(source))
            // The built composition with a metered tap per track (same algorithm and envelope; a
            // multi-piece keep-pitch segment is laid out as a ramp-seam pair).
            var meters: [GainTapMeter] = []
            var taps: [GainTap] = []
            var parameters: [AVMutableAudioMixInputParameters] = []
            for (i, id) in built.audioTrackIDs.enumerated() {
                let track = try XCTUnwrap(built.composition.track(withTrackID: id))
                let meter = GainTapMeter()
                meter.accumulating = false
                meter.capturing = true
                meters.append(meter)
                let tap = GainTap(envelope: built.gainTaps[i].envelope, meter: meter)
                let q = AVMutableAudioMixInputParameters(track: track)
                q.audioTimePitchAlgorithm = built.audioLayout.tracks[i].pitch ? .timeDomain : .varispeed
                try tap.attach(to: q)
                parameters.append(q)
                taps.append(tap)
            }
            XCTAssertEqual(taps.count, TapEnvelope.rampSeamCrossfadesEnabled ? 2 : 1)
            let mix = AVMutableAudioMix()
            mix.inputParameters = parameters
            let item = AVPlayerItem(asset: built.composition)
            item.audioMix = mix
            item.audioTimePitchAlgorithm = .timeDomain
            let player = AVPlayer(playerItem: item)
            player.automaticallyWaitsToMinimizeStalling = false
            player.volume = 0.05
            let deadline = Date().addingTimeInterval(15)
            while item.status != .readyToPlay, Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
            XCTAssertEqual(item.status, .readyToPlay)
            player.play()
            while item.currentTime().seconds < 3.9, Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
            player.pause()
            withExtendedLifetime((built, item, player, taps)) {}
            // Sum of the tracks' tap outputs placed at their composition times (the player's mix).
            var x = [Float](repeating: 0, count: 4_000_000 * 48 / 1000 + 48_000)
            for meter in meters {
                let sr = meter.format?.mSampleRate ?? 48_000
                var track = [Float](repeating: 0, count: x.count)
                for block in meter.captured {
                    for (k, v) in block.samples.enumerated() {
                        let us: Double = block.startUs + Double(k) * 1e6 / sr
                        let idx = Int((us * 0.048).rounded())
                        if idx >= 0, idx < track.count { track[idx] = v }
                    }
                }
                for i in x.indices { x[i] += track[i] }
                XCTAssertTrue(meter.failures.isEmpty, "GetSourceAudio failed: \(meter.failures)")
            }
            assertClicks(x, seg: seg, bias: bias, tolerance: 20_000, label: "preview 1x|\(r)x|1x")
        }
    }
}
