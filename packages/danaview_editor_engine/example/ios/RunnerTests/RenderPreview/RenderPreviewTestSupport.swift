// OWNER: IOS-19
//
// Helpers of the IOS-19 render-preview tests: the barcode PiP project of IOS-20 (frame_counter as
// the full-canvas base reading k, PiP slot i reading k + 25·i) as a PREVIEW plan, the range cut
// CORE-37 makes in Dart (a preview plan cut to the range, times relative to its start), a fixture
// resolver that also accepts render files, synchronous job runs, compositions of a plan read
// through AVAssetReader with the drawn layer ids of every frame, luma planes and per-frame SSIM.

import AVFoundation
import XCTest

@testable import danaview_editor_engine

enum RenderPreviewFixtures {
    static let fps = PrecomposeFixtures.fps
    /// The range used by most tests: frames [10, 30) on the 25 fps grid.
    static let rangeStartUs: Int64 = 400_000
    static let rangeEndUs: Int64 = 1_200_000

    /// The PiP project as a preview plan (rev [rev]).
    static func plan(durUs: Int64 = 2_000_000, pips: Int = 4, rev: Int64 = 1) throws -> RenderPlan {
        var plan = try RenderPlanDecoder.decodePlan(PrecomposeFixtures.plan(durUs: durUs, pips: pips, withAudio: true))
        plan.target = .preview
        plan.rev = rev
        return plan
    }

    /// [plan] with a green chroma key on every PiP layer (the heavy-range case of D-45).
    static func chromaKeyed(_ plan: RenderPlan) -> RenderPlan {
        var out = plan
        for i in out.layers.indices where out.layers[i].id.hasPrefix("it_pip") {
            out.layers[i].fx.chroma = PlanChroma(key: 0x00FF00, sim: 0.3, smooth: 0.1, spill: 0.2)
        }
        return out
    }

    /// The range plan of `[a, b)` (CORE-37's cut): overlapping layers clipped to the range, times
    /// relative to its start, maps cut and shifted, keyframes shifted, no audio.
    static func cut(_ plan: RenderPlan, _ a: Int64, _ b: Int64) -> RenderPlan {
        var layers: [PlanLayer] = []
        var used = Set<String>()
        for var l in plan.layers where l.t0 < b && a < l.t1 {
            let t0 = max(l.t0, a)
            let t1 = min(l.t1, b)
            var map: [MapSegment] = []
            for s in l.map where s.t0 < t1 && t0 < s.t1 {
                let st0 = max(s.t0, t0)
                let st1 = min(s.t1, t1)
                map.append(MapSegment(st0 - a, st1 - a, Int64(s.source(at: st0).rounded()), Int64(s.source(at: st1).rounded())))
            }
            l.t0 = t0 - a
            l.t1 = t1 - a
            l.map = map
            l.anim = l.anim.mapValues { keys in keys.map { AnimKey($0.tUs - a, $0.v) } }
            if let id = l.asset { used.insert(id) }
            if let lut = l.fx.lut { used.insert(lut.asset) }
            layers.append(l)
        }
        var out = plan
        out.durUs = b - a
        out.layers = layers
        out.audio = []
        out.assets = plan.assets.filter { used.contains($0.key) }
        return out
    }

    /// Fixture media by file name; any existing file URL (render files) as is.
    static let resolve: (String, PlanAsset) throws -> URL = { _, asset in
        if let url = URL(string: asset.uri), url.isFileURL, FileManager.default.fileExists(atPath: url.path) { return url }
        let name = URL(string: asset.uri)?.lastPathComponent ?? ""
        guard let url = TestFixtures.url(.engine, "media/\(name)") else { throw EngineError(.mediaOffline, "fixture \(name) missing") }
        return url
    }

    static func options(_ paths: Paths, maxLongSide: Int = 1280) -> RenderPreviewOptions {
        var o = RenderPreviewOptions(spacerDirectory: paths.engineAssets, maxPreviewLongSide: maxLongSide)
        o.resolveURL = resolve
        return o
    }

    /// `<cache>/renders/<name>.mp4`.
    static func renderURL(_ paths: Paths, _ name: String = UUID().uuidString) -> URL {
        Validate.rendersDirectory(paths).appendingPathComponent("\(name).mp4")
    }
}

/// One composed frame of a composition read: its index, drawn layers and luma plane.
struct ComposedRead {
    var k: Int64
    /// Layers the compositor drew (composition reads only).
    var drawn: [String]
    /// Layers of the frame's instruction whose composition track has media at that time, i.e.
    /// the layers that decode (composition reads only).
    var decoding: [String] = []
    var barcodes: [Int?]
    var luma: [UInt8]
}

enum RenderPreviewCheck {
    /// Base and PiP barcodes of a 640×360-proportioned frame (nil where unreadable).
    static func barcodes(_ pb: CVPixelBuffer, pips: Int) -> [Int?] {
        let w = CVPixelBufferGetWidth(pb)
        let h = CVPixelBufferGetHeight(pb)
        let sx = Double(w) / 640
        let sy = Double(h) / 360
        var out: [Int?] = [CompositorTestSupport.barcode(pb, region: FrameBarcodeRegion(x: 0, y: 0, width: w, height: h))]
        for i in 1...4 where i <= pips {
            let (cx, cy) = PrecomposeFixtures.pipCentres[i - 1]
            let pw = Int((PrecomposeFixtures.pipW * sx).rounded())
            let ph = Int((PrecomposeFixtures.pipH * sy).rounded())
            let x0 = Int((cx * sx).rounded()) - pw / 2
            let y0 = Int((cy * sy).rounded()) - ph / 2
            out.append(CompositorTestSupport.barcode(pb, region: FrameBarcodeRegion(x: x0, y: y0, width: pw, height: ph)))
        }
        return out
    }

    /// What the barcodes of output frame [k] must read.
    static func expected(_ k: Int64, pips: Int) -> [Int?] {
        [Int(k)] + (1...4).filter { $0 <= pips }.map { Int(k) + PrecomposeFixtures.fps * $0 }
    }

    /// BT.709-weighted luma of a BGRA buffer.
    static func luma(_ pb: CVPixelBuffer) -> [UInt8] {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let w = CVPixelBufferGetWidth(pb)
        let h = CVPixelBufferGetHeight(pb)
        let row = CVPixelBufferGetBytesPerRow(pb)
        let base = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self)
        var out = [UInt8](repeating: 0, count: w * h)
        for y in 0..<h {
            let p = base + y * row
            for x in 0..<w {
                let b = Int(p[4 * x]), g = Int(p[4 * x + 1]), r = Int(p[4 * x + 2])
                out[y * w + x] = UInt8(min(255, (54 * r + 183 * g + 19 * b) >> 8))
            }
        }
        return out
    }

    /// Every frame of a render file: barcodes and luma.
    static func fileFrames(_ url: URL, pips: Int) throws -> (w: Int, h: Int, frames: [ComposedRead], pts: [CMTime]) {
        var w = 0, h = 0
        var frames: [ComposedRead] = []
        var pts: [CMTime] = []
        try ExportConformance.frames(url) { t, pb in
            w = CVPixelBufferGetWidth(pb)
            h = CVPixelBufferGetHeight(pb)
            frames.append(ComposedRead(k: Int64(frames.count), drawn: [], barcodes: barcodes(pb, pips: pips), luma: luma(pb)))
            pts.append(t)
        }
        return (w, h, frames, pts)
    }

    /// Builds [plan] the way the preview does (DVCompositor, render size [size], the plan's own
    /// snapshot) and reads every composed frame with the layers it drew.
    static func compose(_ plan: RenderPlan, size: CGSize, paths: Paths, pips: Int,
                        range: Range<Int64>? = nil) throws -> (frames: [ComposedRead], built: BuiltComposition) {
        let session = try DVRenderSession(snapshots: ParamSnapshotStore(ParamSnapshot(plan: plan)))
        var options = CompositionBuildOptions(spacerDirectory: paths.engineAssets)
        options.renderSize = size
        options.validate = false
        options.resolveURL = RenderPreviewFixtures.resolve
        session.configure(&options)
        let input = UncheckedSendable((plan, options))
        let built = try MediaBlocking.await { try await CompositionBuilder.build(plan: input.value.0, options: input.value.1) }
        let lock = NSLock()
        var drawn: [Int64: [String]] = [:]
        session.onComposed = { f in
            lock.lock()
            drawn[f.k] = f.drawn
            lock.unlock()
        }
        var frames: [ComposedRead] = []
        let tracks = Dictionary(uniqueKeysWithValues: built.composition.tracks(withMediaType: .video).map { ($0.trackID, $0) })
        try CompositorTestSupport.readFrames(built) { k, time, pb in
            guard let k else { return }
            if let range, !range.contains(k) { return }
            var decoding: [String] = []
            if let spec = built.instruction(at: time) {
                for id in spec.layerIds {
                    guard let tid = spec.trackIDByLayer[id], let track = tracks[tid],
                          let segment = track.segment(forTrackTime: time), !segment.isEmpty else { continue }
                    decoding.append(id)
                }
            }
            frames.append(ComposedRead(k: k, drawn: [], decoding: decoding, barcodes: barcodes(pb, pips: pips), luma: luma(pb)))
        }
        // The observer runs right after each request finishes; let the last ones land.
        Thread.sleep(forTimeInterval: 0.2)
        lock.lock()
        for i in frames.indices { frames[i].drawn = drawn[frames[i].k] ?? [] }
        lock.unlock()
        session.onComposed = nil
        return (frames, built)
    }

    static func ssim(_ a: [UInt8], _ b: [UInt8], w: Int, h: Int) -> Double { PrecomposeCheck.ssim(a, b, w: w, h: h) }
}

/// Engine roots, a context with a recorder and a job registry for render-preview tests.
final class RenderPreviewHarness {
    let roots: TempRoots
    let recorder = JobEventRecorder()
    let context: EngineContext
    let interruption = JobInterruption(center: NotificationCenter())
    let registry: JobRegistry
    let paths: Paths

    init() throws {
        roots = try TempRoots()
        context = try MediaJobTestSupport.context(roots, events: recorder.hub)
        registry = JobRegistry(context: context, concurrency: 1, interruption: interruption, startInterruption: false)
        interruption.start()
        paths = try context.requirePaths()
        try FileManager.default.createDirectory(at: Validate.rendersDirectory(paths), withIntermediateDirectories: true)
    }

    /// Runs [job] synchronously on the calling thread.
    func run(_ job: RenderPreviewJob) throws -> JobResultMsg {
        try job.run(JobControl(jobId: "test"))
    }

    /// Files left in the renders directory.
    func renderFiles() -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: Validate.rendersDirectory(paths).path))?.sorted() ?? []
    }

    func remove() { roots.remove() }
}
