// OWNER: IOS-10
//
// DVCompositor (ARCH §13.2 'Compositor', native.md §5.3): the AVVideoCompositing custom compositor of
// every preview and export composition, plus DVRenderSession, the render state one composition (or one
// preview session) shares with it.
//
// - Sources arrive as BGRA IOSurface/Metal-compatible buffers (VideoToolbox does YUV → RGB);
//   `supportsHDRSourceFrames = false` and `supportsWideColorSourceFrames = false` so HDR/wide sources
//   arrive tone-mapped to BT.709 SDR (IOS-01: HLG arrives as BGRA tagged ITU_R_709_2).
// - Source images are built zero-copy through a CVMetalTextureCache → `CIImage(mtlTexture:)` with a y
//   flip, never `CIImage(cvPixelBuffer:)` (IOS-01: that path composited the lower of two decoded
//   layers black on the iOS 18.2 simulator); the CVMetalTextures stay alive until the render task has
//   completed. Each source is rotated to display orientation by its asset's `rot`.
// - One CIContext(mtlDevice:) per session with colour management off (working/output colour space
//   NSNull, ARCH §11.6); LayerRenderer builds the graph (layer stages, §11.6 placement,
//   CISourceOverCompositing onto the opaque bg, canvas masks, sprites with reveal, solids).
// - Each request computes `k = round(compositionTime × fps)` (exact on the rational CMTime) with the
//   OUTPUT rate (`canvas.fps`: the preview rate, or the export rate of an export plan), renders the
//   plan at `timeOfFrame(k)` and stamps `danaview.frame = k` on the output buffer with
//   `.shouldPropagate` (D-35), which the preview's video output and the export reader read back.
// - The ParamSnapshot is read once per request from the session's atomically swapped store; nothing is
//   locked while rendering.
// - `cancelAllPendingVideoCompositionRequests` bumps a generation counter: every request queued under
//   an older generation finishes with `finishCancelledRequest()` instead of rendering.
// - After each request the session's RedrawCache keeps the request's source buffers, so paused
//   param patches, transients, editing modes and stills re-render on this same code path.
// - Export variant: the export plan's canvas is the output (size and fps) and the export video
//   composition has renderSize = output and frameDuration = 1/export fps; the compositor renders at
//   the render context's size, so preview quality steps (½, ¼) and exports use the same code.

import AVFoundation
import CoreImage
import CoreVideo
import Foundation
import Metal

/// Render state shared by a composition's compositor instances and its paused redraws.
final class DVRenderSession {
    /// Output buffer attachment carrying the rendered frame index k (D-35).
    static let frameAttachmentKey = "danaview.frame" as CFString

    /// BGRA, IOSurface-backed, Metal-compatible (sources, render context, redraw pool).
    static let pixelBufferAttributes: [String: any Sendable] = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferIOSurfacePropertiesKey as String: [String: Int](),
        kCVPixelBufferMetalCompatibilityKey as String: true,
    ]

    /// The atomically swapped parameters (IOS-08); param patches and transients swap it.
    let snapshots: ParamSnapshotStore
    let kernels: Kernels
    let assets: LayerAssetSource
    let renderer: LayerRenderer
    /// The one CIContext of the session (Metal, colour management off).
    let context: CIContext
    let device: MTLDevice?
    /// The last request's sources, for paused redraws and stills.
    let redraw: RedrawCache
    /// Export sessions render at `.userInitiated`, preview at `.userInteractive`.
    let qos: DispatchQoS

    private let lock = NSLock()
    private var textureCache: CVMetalTextureCache?
    private var _mode: DVEditingMode = .normal
    private var _observer: ((ComposedFrame) -> Void)?
    private var _composedCount = 0

    /// One composed request (observer payload).
    struct ComposedFrame {
        let k: Int64
        let compositionTime: CMTime
        let drawn: [String]
        let missing: [String]
        let renderMs: Double
        let buffer: CVPixelBuffer
    }

    /// Source buffers of one request and the media layers they belong to.
    struct Sources {
        var buffers: [CMPersistentTrackID: CVPixelBuffer]
        var trackIDByLayer: [String: CMPersistentTrackID]

        static let none = Sources(buffers: [:], trackIDByLayer: [:])
    }

    init(snapshots: ParamSnapshotStore, assets: LayerAssetSource = StoreAssetSource(), kernels: Kernels? = nil,
         device: MTLDevice? = MTLCreateSystemDefaultDevice(), qos: DispatchQoS = .userInteractive) throws {
        self.snapshots = snapshots
        self.kernels = try kernels ?? Kernels.shared()
        self.assets = assets
        self.renderer = LayerRenderer(kernels: self.kernels, assets: assets)
        self.device = device
        self.qos = qos
        var options: [CIContextOption: Any] = [
            .workingColorSpace: NSNull(),
            .outputColorSpace: NSNull(),
            .workingFormat: CIFormat.RGBAh,
            .cacheIntermediates: false,
            .name: "danaview.compose",
        ]
        if let device {
            context = CIContext(mtlDevice: device, options: options)
            var cache: CVMetalTextureCache?
            CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
            textureCache = cache
        } else {
            options[.useSoftwareRenderer] = true
            context = CIContext(options: options)
        }
        redraw = RedrawCache()
        redraw.session = self
    }

    /// Sets the compositor class and the instruction factory of a composition build.
    func configure(_ options: inout CompositionBuildOptions) {
        options.compositorClass = DVCompositor.self
        options.makeInstruction = DVInstruction.factory(self)
    }

    /// Renders a 16×16 image through every kernel once (session start; the first blur compile took
    /// 1–3 s in IOS-01) and returns the ms per kernel.
    @discardableResult
    func prewarm() -> [String: Double] { kernels.prewarm(context: context) }

    /// The current editing mode (applies to every following request and redraw).
    var mode: DVEditingMode {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _mode
        }
        set {
            lock.lock()
            _mode = newValue
            lock.unlock()
        }
    }

    /// Called on the render queue after every composed request (IOS-11: first composited frame,
    /// missed-frame accounting). Must return quickly.
    var onComposed: ((ComposedFrame) -> Void)? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _observer
        }
        set {
            lock.lock()
            _observer = newValue
            lock.unlock()
        }
    }

    /// Requests composed so far.
    var composedCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _composedCount
    }

    // MARK: Rendering

    /// Renders output frame [k] of [snapshot] from [sources] into [destination] (its size is the render
    /// size) and stamps `danaview.frame = k`. The single render path of requests, redraws and stills.
    @discardableResult
    func render(snapshot: ParamSnapshot, frame k: Int64, sources: Sources, mode: DVEditingMode,
                into destination: CVPixelBuffer) throws -> LayerRenderer.Output {
        let size = CGSize(width: CVPixelBufferGetWidth(destination), height: CVPixelBufferGetHeight(destination))
        var textures: [CVMetalTexture] = []
        var images: [CMPersistentTrackID: CIImage] = [:]
        let plan = snapshot.plan
        let output = renderer.compose(snapshot: snapshot, frame: k, renderSize: size, mode: mode) { layer in
            guard let track = sources.trackIDByLayer[layer.id], let buffer = sources.buffers[track] else { return nil }
            let rot = layer.asset.flatMap { plan.assets[$0]?.rot } ?? 0
            if let hit = images[track] { return hit }
            let image = self.sourceImage(buffer, rotation: rot, keep: &textures)
            images[track] = image
            return image
        }
        let dest = CIRenderDestination(pixelBuffer: destination)
        dest.colorSpace = nil
        let task = try context.startTask(toRender: output.image, from: CGRect(origin: .zero, size: size), to: dest, at: .zero)
        _ = try task.waitUntilCompleted()
        withExtendedLifetime(textures) {}
        Self.stamp(destination, frame: k)
        return output
    }

    /// A display-oriented CIImage of a BGRA source buffer (extent at the origin). Metal path when a
    /// texture cache exists; [keep] receives the texture to retain until the render completes.
    func sourceImage(_ buffer: CVPixelBuffer, rotation: Int, keep: inout [CVMetalTexture]) -> CIImage? {
        let w = CVPixelBufferGetWidth(buffer)
        let h = CVPixelBufferGetHeight(buffer)
        var image: CIImage?
        if let cache = lockedTextureCache() {
            var texture: CVMetalTexture?
            let rc = CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, cache, buffer, nil, .bgra8Unorm, w, h, 0, &texture)
            if rc == kCVReturnSuccess, let texture, let mtl = CVMetalTextureGetTexture(texture),
               let ci = CIImage(mtlTexture: mtl, options: [.colorSpace: NSNull()]) {
                keep.append(texture)
                // Metal textures are top-row-first; Core Image is y up.
                image = ci.transformed(by: CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: CGFloat(h)))
            }
        }
        if image == nil {
            image = CIImage(cvPixelBuffer: buffer, options: [.colorSpace: NSNull()])
        }
        guard var out = image else { return nil }
        switch ((rotation % 360) + 360) % 360 {
        case 90: out = out.oriented(.right)
        case 180: out = out.oriented(.down)
        case 270: out = out.oriented(.left)
        default: break
        }
        let e = out.extent
        if e.minX != 0 || e.minY != 0 { out = out.transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY)) }
        return out
    }

    private func lockedTextureCache() -> CVMetalTextureCache? {
        lock.lock()
        defer { lock.unlock() }
        return textureCache
    }

    fileprivate func didCompose(_ frame: ComposedFrame, sources: Sources, renderSize: CGSize) {
        redraw.store(RedrawCache.Entry(k: frame.k, compositionTime: frame.compositionTime, sources: sources, renderSize: renderSize))
        lock.lock()
        _composedCount += 1
        let observer = _observer
        lock.unlock()
        observer?(frame)
    }

    // MARK: Memory

    /// Releases Core Image intermediates and cached Metal textures (app in background).
    func releaseIntermediates() {
        context.clearCaches()
        if let cache = lockedTextureCache() { CVMetalTextureCacheFlush(cache, 0) }
    }

    /// Memory warning: release intermediates and trim the asset stores to [fraction] of their budgets.
    func trimCaches(to fraction: Double = 0.25) {
        releaseIntermediates()
        (assets as? StoreAssetSource)?.trim(to: fraction)
    }

    // MARK: Frame stamp

    /// Stamps `danaview.frame = k` (propagated to the video output / reader buffers).
    static func stamp(_ buffer: CVPixelBuffer, frame k: Int64) {
        CVBufferSetAttachment(buffer, frameAttachmentKey, NSNumber(value: k), .shouldPropagate)
    }

    /// The `danaview.frame` stamp of a buffer.
    static func frameIndex(of buffer: CVBuffer) -> Int64? {
        guard let value = CVBufferCopyAttachment(buffer, frameAttachmentKey, nil) else { return nil }
        return (value as? NSNumber)?.int64Value
    }
}

/// The custom video compositor (`customVideoCompositorClass`); AVFoundation creates the instances.
final class DVCompositor: NSObject, AVVideoCompositing, @unchecked Sendable {
    let sourcePixelBufferAttributes: [String: any Sendable]? = DVRenderSession.pixelBufferAttributes
    let requiredPixelBufferAttributesForRenderContext: [String: any Sendable] = DVRenderSession.pixelBufferAttributes
    let supportsHDRSourceFrames = false
    let supportsWideColorSourceFrames = false

    private let lock = NSLock()
    private var generation: UInt64 = 0
    private var queue: DispatchQueue?

    override init() {
        super.init()
    }

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        let session = (request.videoCompositionInstruction as? DVInstruction)?.session
        let box = UncheckedSendable(request)
        enqueue(qos: session?.qos ?? .userInitiated) { [weak self] cancelled in
            let request = box.value
            if cancelled {
                request.finishCancelledRequest()
                return
            }
            guard let self else {
                request.finishCancelledRequest()
                return
            }
            self.compose(request)
        }
    }

    func cancelAllPendingVideoCompositionRequests() {
        lock.lock()
        generation &+= 1
        lock.unlock()
    }

    /// The current cancellation generation.
    var currentGeneration: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return generation
    }

    /// Runs [work] on the serial render queue; it receives `true` when the request was cancelled
    /// (generation bumped) between enqueueing and running.
    func enqueue(qos: DispatchQoS, _ work: @escaping (Bool) -> Void) {
        lock.lock()
        let gen = generation
        if queue == nil { queue = DispatchQueue(label: "danaview.compositor", qos: qos) }
        let q = queue!
        lock.unlock()
        q.async { [weak self] in
            let current = self?.currentGeneration ?? gen &+ 1
            work(current != gen)
        }
    }

    private func compose(_ request: AVAsynchronousVideoCompositionRequest) {
        guard let instruction = request.videoCompositionInstruction as? DVInstruction, let session = instruction.session else {
            request.finish(with: Self.error("instruction without a render session"))
            return
        }
        guard let output = request.renderContext.newPixelBuffer() else {
            request.finish(with: Self.error("render context returned no pixel buffer"))
            return
        }
        let start = CFAbsoluteTimeGetCurrent()
        var buffers: [CMPersistentTrackID: CVPixelBuffer] = [:]
        for id in instruction.spec.requiredTrackIDs {
            if let pb = request.sourceFrame(byTrackID: id) { buffers[id] = pb }
        }
        let sources = DVRenderSession.Sources(buffers: buffers, trackIDByLayer: instruction.spec.trackIDByLayer)
        let snapshot = session.snapshots.current
        let time = request.compositionTime
        let k = time.isNumeric ? snapshot.plan.canvas.outputGrid.frameIndexNearest(time) : 0
        do {
            let out = try session.render(snapshot: snapshot, frame: k, sources: sources, mode: session.mode, into: output)
            let ms = (CFAbsoluteTimeGetCurrent() - start) * 1000
            let size = CGSize(width: CVPixelBufferGetWidth(output), height: CVPixelBufferGetHeight(output))
            request.finish(withComposedVideoFrame: output)
            session.didCompose(
                DVRenderSession.ComposedFrame(k: k, compositionTime: time, drawn: out.drawn, missing: out.missing, renderMs: ms, buffer: output),
                sources: sources, renderSize: size)
        } catch {
            Log.error(.preview, "compose frame \(k) failed: \((error as NSError).code)")
            request.finish(with: error)
        }
    }

    static func error(_ message: String) -> NSError {
        NSError(domain: "danaview.compositor", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
