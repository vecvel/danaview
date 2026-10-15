// OWNER: IOS-20
//
// Helpers of the IOS-20 multi-pass precompose tests: a five-track barcode project (the
// frame_counter clip as the full-canvas base plus four picture-in-picture slots, each on its own
// composition track with its own source offset, and the tone clip's audio), a coordinator harness
// with the precompose exporter installed and intermediates resolved as real files, per-frame
// luma SSIM, and the grid-cut barcode check of every slot.

import AVFoundation
import XCTest

@testable import danaview_editor_engine

enum PrecomposeFixtures {
    static let fps = 25
    /// Short segments on the 25 fps grid (10 frames) so interruptions land inside a pass.
    static let segmentDurationUs: Int64 = 400_000
    /// PiP size and centres (canvas px) of slots 1…4 on a 640×360 canvas.
    static let pipW = 192.0
    static let pipH = 108.0
    static let pipCentres: [(Double, Double)] = [(112, 110), (528, 110), (112, 290), (528, 290)]

    /// Source offset of PiP slot [i] (1…4): its barcode reads k + 25·i at output frame k.
    static func pipOffsetUs(_ i: Int) -> Int64 { Int64(i) * 1_000_000 }

    /// The base plus [pips] picture-in-picture slots (1…4), with audio.
    static func plan(w: Int = 640, h: Int = 360, durUs: Int64, pips: Int = 4, withAudio: Bool = true, baseZ: Int = 10) -> Data {
        var layers = [ExportPlans.mediaLayer("it_base00000001#v", asset: "md_fc0000000001", seq: 0, t0: 0, t1: durUs,
                                             w: Double(w), h: Double(h), z: baseZ)]
        let sx = Double(w) / 640
        let sy = Double(h) / 360
        for i in 1...max(1, pips) where i <= pips {
            let (cx, cy) = pipCentres[i - 1]
            layers.append(ExportPlans.mediaLayer(
                "it_pip\(i)0000000#v", asset: "md_fc0000000001", seq: i, t0: 0, t1: durUs, s0: pipOffsetUs(i),
                w: pipW * sx, h: pipH * sy, z: 10010 + i, cx: cx * sx, cy: cy * sy))
        }
        return ExportPlans.plan(
            w: w, h: h, fps: fps, durUs: durUs,
            assets: [
                ExportPlans.video("md_fc0000000001", file: "frame_counter_720p25.mp4", w: 1280, h: 720, durUs: 8_000_000, hasAudio: false),
                ExportPlans.video("md_tone00000001", file: "tone_under_video.mp4", w: 1280, h: 720, durUs: 8_000_000, hasAudio: true),
            ],
            layers: layers,
            audio: withAudio ? [ExportPlans.audioSeg("it_tone0000001#a", asset: "md_tone00000001", t0: 0, t1: durUs, gain: [(0, 0.5)])] : [])
    }

    static func settings(w: Int = 640, h: Int = 360) -> EncodeSettingsMsg {
        ExportPlans.settings(w, h, fps: fps, videoBitrate: 6_000_000)
    }
}

/// An export harness with IOS-20's exporter installed (intermediates resolve to their files).
final class PrecomposeHarness {
    let h: ExportHarness
    let exporter: PrecomposeExporter

    init(decoderLimit: Int, segmentDurationUs: Int64 = PrecomposeFixtures.segmentDurationUs, probe: EncoderProbe = .system, roots: TempRoots? = nil) throws {
        h = try ExportHarness(
            ExportHarness.Options(probe: probe, decoderLimit: decoderLimit, segmentDurationUs: segmentDurationUs), roots: roots)
        exporter = PrecomposeExporter(context: h.context)
        exporter.segmentDurationUs = segmentDurationUs
        h.coordinator.multiPass = exporter
        let fixtures = h.coordinator.environment.resolveURL
        h.coordinator.environment.resolveURL = { id, asset in
            if asset.fp.hasPrefix("precompose:") {
                guard let url = URL(string: asset.uri), url.isFileURL else { throw EngineError(.mediaOffline, "bad intermediate uri") }
                return url
            }
            guard let fixtures = fixtures else { throw EngineError(.mediaOffline, "no fixture resolver") }
            return try fixtures(id, asset)
        }
    }

    var paths: Paths { h.paths }

    func jobDirectory(_ id: String) -> URL { ExportJob.directory(for: id, work: h.paths.work) }

    /// Names of every precompose file left anywhere under work/.
    func leftovers() -> [String] {
        guard let e = FileManager.default.enumerator(atPath: h.paths.work.path) else { return [] }
        return e.compactMap { $0 as? String }.filter { ($0 as NSString).lastPathComponent.hasPrefix("pre-") }
    }
}

enum PrecomposeCheck {
    /// Luma planes (BT.709 weights, 0–255) of every decoded frame of [url].
    static func lumaFrames(_ url: URL) throws -> (w: Int, h: Int, frames: [[UInt8]]) {
        var w = 0, h = 0
        var frames: [[UInt8]] = []
        try ExportConformance.frames(url) { _, pb in
            CVPixelBufferLockBaseAddress(pb, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
            w = CVPixelBufferGetWidth(pb)
            h = CVPixelBufferGetHeight(pb)
            let row = CVPixelBufferGetBytesPerRow(pb)
            let base = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self)
            var luma = [UInt8](repeating: 0, count: w * h)
            for y in 0..<h {
                let p = base + y * row
                for x in 0..<w {
                    let b = Int(p[4 * x]), g = Int(p[4 * x + 1]), r = Int(p[4 * x + 2])
                    luma[y * w + x] = UInt8(min(255, (54 * r + 183 * g + 19 * b) >> 8))
                }
            }
            frames.append(luma)
        }
        return (w, h, frames)
    }

    /// Mean SSIM of two luma planes over 8×8 windows (stride 4), standard constants.
    static func ssim(_ a: [UInt8], _ b: [UInt8], w: Int, h: Int) -> Double {
        let c1 = pow(0.01 * 255, 2.0)
        let c2 = pow(0.03 * 255, 2.0)
        var total = 0.0
        var n = 0
        var y = 0
        while y + 8 <= h {
            var x = 0
            while x + 8 <= w {
                var sa = 0.0, sb = 0.0, saa = 0.0, sbb = 0.0, sab = 0.0
                for yy in y..<(y + 8) {
                    let o = yy * w
                    for xx in x..<(x + 8) {
                        let va = Double(a[o + xx]), vb = Double(b[o + xx])
                        sa += va
                        sb += vb
                        saa += va * va
                        sbb += vb * vb
                        sab += va * vb
                    }
                }
                let m = 64.0
                let ma = sa / m, mb = sb / m
                let va = saa / m - ma * ma, vb = sbb / m - mb * mb, cov = sab / m - ma * mb
                total += ((2 * ma * mb + c1) * (2 * cov + c2)) / ((ma * ma + mb * mb + c1) * (va + vb + c2))
                n += 1
                x += 4
            }
            y += 4
        }
        return n == 0 ? 1 : total / Double(n)
    }

    /// Per-frame SSIM of two exports (same frame count asserted).
    static func ssimPerFrame(_ a: URL, _ b: URL, file: StaticString = #filePath, line: UInt = #line) throws -> [Double] {
        let fa = try lumaFrames(a)
        let fb = try lumaFrames(b)
        XCTAssertEqual(fa.w, fb.w, file: file, line: line)
        XCTAssertEqual(fa.h, fb.h, file: file, line: line)
        XCTAssertEqual(fa.frames.count, fb.frames.count, "frame count", file: file, line: line)
        return zip(fa.frames, fb.frames).map { ssim($0, $1, w: fa.w, h: fa.h) }
    }

    /// Grid-cut barcode problems of a 640×360-proportioned [url]: the base reads k and PiP i reads
    /// k + 25·i at every output frame k (empty = 100%).
    static func barcodeProblems(_ url: URL, pips: Int) throws -> [String] {
        var problems: [String] = []
        var k = 0
        try ExportConformance.frames(url) { _, pb in
            let w = CVPixelBufferGetWidth(pb)
            let h = CVPixelBufferGetHeight(pb)
            let sx = Double(w) / 640
            let sy = Double(h) / 360
            let base = CompositorTestSupport.barcode(pb, region: FrameBarcodeRegion(x: 0, y: 0, width: w, height: h))
            if base != k { problems.append("frame \(k): base \(String(describing: base))") }
            for i in 1...4 where i <= pips {
                let (cx, cy) = PrecomposeFixtures.pipCentres[i - 1]
                let pw = Int((PrecomposeFixtures.pipW * sx).rounded())
                let ph = Int((PrecomposeFixtures.pipH * sy).rounded())
                let x0 = Int((cx * sx).rounded()) - pw / 2
                let y0 = Int((cy * sy).rounded()) - ph / 2
                let got = CompositorTestSupport.barcode(pb, region: FrameBarcodeRegion(x: x0, y: y0, width: pw, height: ph))
                let want = k + PrecomposeFixtures.fps * i
                if got != want { problems.append("frame \(k): PiP \(i) \(String(describing: got)) != \(want)") }
            }
            k += 1
        }
        return problems
    }

    /// RMS (dB) per 20 ms window of channel 0.
    static func rmsWindows(_ pcm: [Float]) -> [Double] {
        let window = 960
        let frames = pcm.count / 2
        return stride(from: 0, to: frames - window, by: window).map { ExportConformance.rmsDb(pcm, channel: 0, $0, $0 + window) }
    }
}
