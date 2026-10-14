// OWNER: IOS-11
//
// PreviewSession (ARCH §12.2, §12.7, §13.2 'Session', §13.4; D-35, D-43(e), D-45, R13): one
// AVPlayer-backed preview on a Flutter texture. Every method runs on `previewControlQueue`
// (PreviewSessionManager hops there); the display link ticks on main and only touches the
// thread-safe TextureBridge and a locked tick state.
//
// Player: `AVPlayer` (`automaticallyWaitsToMinimizeStalling = false`) over IOS-08's composition
// with IOS-10's DVCompositor (`seekingWaitsForVideoCompositionRendering = true`) and an
// `AVPlayerItemVideoOutput` feeding TextureBridge.
//
// Plans:
// - `setPlan` decodes, validates and rebuilds (structural). `applyPatch` applies at `from == rev`
//   (`planOutOfSync` otherwise) and classifies (IOS-08): param-only patches swap the ParamSnapshot
//   (+ gain-tap envelopes) and, while paused, redraw the cached frame through the compositor's
//   RedrawCache (IOS-10); structural patches build a new item, `replaceCurrentItem`, exact-seek to
//   the current frame and restore the play state, keeping the old frame on screen until the first
//   new one. A param patch that arrives while a rebuild is in flight is applied when it lands.
// - Transients are merged into the snapshot as they arrive and redrawn at most once per output
//   frame while paused (a newer one supersedes a queued redraw); playback picks them up on the
//   next composed frame.
// Clock and seq (§12.2): `seq` increases with every seek, play and pause; clock samples carry the
//   seq of the last command (10 Hz while playing, plus every state change).
// Seeks: SeekController (exact ack of the displayed `danaview.frame`, 500 ms timeout; scrub with
//   one seek in flight). `displayedFrameTime = timeOfFrame(displayedFrame)`.
// Quality: QualityGovernor (render scale 1, ½, ¼ capped by `maxPreviewLongSide`); a step changes
//   the item's video composition render size, emits `frameSize` and `degraded(q)` (`recovered`
//   when auto is back at full) and, while paused, re-composes the current frame.
// Decoder budget (D-43(e)): when more media layers overlap than the tier's live decode budget
//   (`maxConcurrentVideoLayers`), playback runs a composition whose excess slots are `hold`
//   stills of their exact frame at the play position (PlaybackStills); paused, scrub and exact
//   seek always run the full composition, so they are exact for every layer.
// Rendered ranges (D-45): `RenderedRangeHook` (no-op here, IOS-19 implements it) is asked for the
//   plan's rendered ranges and called whenever playback enters or leaves one.
// Lifecycle: resign active → pause + stop the display link; background → release Core Image
//   intermediates; active → refresh (re-compose the current frame; the old frame stays on the
//   texture meanwhile, never black); memory warning → trim render caches to 25% and drop source
//   frames (the engine-wide `signal(memoryWarning)` is SystemSignals'); thermal → governor.
// Audio session: `.playback/.moviePlayback` from the first play, previous category restored on
//   dispose (AudioSessionCoordinator).

import AVFoundation
import CoreImage
import Foundation
import ImageIO
import QuartzCore
import UIKit

// MARK: - Rendered ranges (D-45)

/// The render-preview cache hook. IOS-19 implements it; the default does nothing.
protocol RenderedRangeHook: AnyObject {
    /// Output frame ranges `[lowerBound, upperBound)` of plan revision [planRev] that have a
    /// render-preview file (empty: none).
    func renderedRanges(planRev: Int64) -> [Range<Int64>]
    /// Playback entered ([entered] true) or left [range] at output frame [k] (control queue).
    func playbackCrossed(range: Range<Int64>, entered: Bool, atFrame k: Int64)
}

/// No rendered ranges (until IOS-19).
final class NoRenderedRanges: RenderedRangeHook {
    func renderedRanges(planRev: Int64) -> [Range<Int64>] { [] }
    func playbackCrossed(range: Range<Int64>, entered: Bool, atFrame k: Int64) {}
}

// MARK: - Playback stills (D-43(e))

/// Turns the layers of slots beyond the live decode budget into exact stills for playback.
enum PlaybackStills {
    /// The most media layers decoding at once (hold layers excluded).
    static func peakLiveLayers(_ layers: [PlanLayer]) -> Int {
        var events: [(t: Int64, d: Int)] = []
        for l in layers where l.kind == .media && !l.hold && l.t1 > l.t0 {
            events.append((l.t0, 1))
            events.append((l.t1, -1))
        }
        events.sort { $0.t != $1.t ? $0.t < $1.t : $0.d < $1.d }
        var cur = 0
        var peak = 0
        for e in events {
            cur += e.d
            peak = max(peak, cur)
        }
        return peak
    }

    /// [plan] for playback within [budget] live layers, anchored at output frame [k]: the layers
    /// of the highest slots become `hold` layers showing their exact frame at `timeOfFrame(k)` (or
    /// their first frame when inactive there). Nil when the plan fits the budget. The lowest slot
    /// (the main track) always stays live.
    static func plan(_ plan: RenderPlan, budget: Int, anchorFrame k: Int64) -> (plan: RenderPlan, stillSlots: [Int])? {
        let limit = max(1, budget)
        guard peakLiveLayers(plan.layers) > limit else { return nil }
        let seqs = Set(plan.layers.compactMap { $0.kind == .media ? $0.seq : nil }).sorted()
        guard seqs.count > 1 else { return nil }
        let t = plan.canvas.outputGrid.timeOfFrame(k)
        var layers = plan.layers
        var stills: [Int] = []
        for seq in seqs.dropFirst().reversed() {
            for i in layers.indices where layers[i].kind == .media && layers[i].seq == seq && !layers[i].hold {
                layers[i] = still(layers[i], at: t)
            }
            stills.append(seq)
            if peakLiveLayers(layers) <= limit { break }
        }
        var out = plan
        out.layers = layers
        return (out, stills.sorted())
    }

    /// [layer] as a still of its frame at plan time [t] (first frame when it does not cover t).
    static func still(_ layer: PlanLayer, at t: Int64) -> PlanLayer {
        guard let first = layer.map.first else { return layer }
        let s = layer.covers(t) ? (ParamSnapshot.sourceTime(layer, at: t) ?? Double(first.s0)) : Double(first.s0)
        let s0 = Int64(s.rounded(.down))
        var l = layer
        l.hold = true
        l.map = [MapSegment(layer.t0, layer.t1, s0, s0 + (layer.t1 - layer.t0))]
        return l
    }
}

// MARK: - Session

final class PreviewSession {
    /// What a session needs from the engine (tests inject fixtures and probes).
    struct Dependencies {
        var registry: PreviewTextureRegistry?
        var events: EventHub
        /// Directory of the runtime spacer video (`Paths.engineAssets`).
        var spacerDirectory: URL
        /// Asset → URL (default: MediaURLResolver with the session's scoped access).
        var resolveURL: ((String, PlanAsset) throws -> URL)?
        var tier: DeviceTierMsg = .mid
        var maxPreviewLongSide: Int = 1280
        /// Media layers decoded live during playback (`maxConcurrentVideoLayers`).
        var liveDecodeBudget: Int = 4
        var renderedRanges: RenderedRangeHook = NoRenderedRanges()
        var audioSession: AudioSessionPort? = AVAudioSession.sharedInstance()
        var observeLifecycle = true
        var textureLatency: CFTimeInterval?
        var now: () -> TimeInterval = { CACurrentMediaTime() }

        init(registry: PreviewTextureRegistry?, events: EventHub, spacerDirectory: URL) {
            self.registry = registry
            self.events = events
            self.spacerDirectory = spacerDirectory
        }
    }

    /// Locked state the display link reads on main.
    private final class TickState {
        private let lock = NSLock()
        private var _playing = false
        private var _minFrame: Int64 = 0
        private var _lastK: Int64?

        func set(playing: Bool, minFrame: Int64) {
            lock.lock()
            _playing = playing
            _minFrame = minFrame
            _lastK = nil
            lock.unlock()
        }

        func setMinFrame(_ k: Int64) {
            lock.lock()
            _minFrame = k
            _lastK = nil
            lock.unlock()
        }

        var playing: Bool {
            lock.lock()
            defer { lock.unlock() }
            return _playing
        }

        var minFrame: Int64 {
            lock.lock()
            defer { lock.unlock() }
            return _minFrame
        }

        /// Records displayed frame [k]; returns the frames skipped since the previous one.
        func displayed(_ k: Int64) -> Int {
            lock.lock()
            defer { lock.unlock() }
            let missed = _lastK.map { k > $0 ? Int(k - $0 - 1) : 0 } ?? 0
            _lastK = k
            return missed
        }
    }

    let id: String
    let config: PreviewConfigMsg
    let queue: DispatchQueue
    private let deps: Dependencies
    let bridge: TextureBridge
    let displayLink: DisplayLinkDriver
    let render: DVRenderSession
    let snapshots: ParamSnapshotStore
    let seeks: SeekController
    let governor: QualityGovernor
    let audio: AudioSessionCoordinator?
    let sourceFrames: SourceFrameCache
    private let access = SessionMediaAccess()
    private let workQueue = DispatchQueue(label: "com.vecvel.danaview.editor.preview.work", qos: .userInitiated)
    private let tick = TickState()
    let player: AVPlayer

    // Control-queue state.
    private(set) var plan: RenderPlan?
    private var transients: [PlanTransient] = []
    private(set) var built: BuiltComposition?
    private var item: AVPlayerItem?
    private var statusObservation: NSKeyValueObservation?
    private(set) var seq: Int64 = 0
    private(set) var playing = false
    private var wantsPlaying = false
    private var loop: LoopMsg?
    /// The output frame on screen (paused) or last displayed (playing).
    private(set) var currentFrame: Int64 = 0
    private(set) var renderSize: CGSize
    private var useProxies: Bool
    private(set) var playingStills = false
    private var rebuildGeneration: UInt64 = 0
    private(set) var rebuilding = false
    private var afterRebuild: [() -> Void] = []
    private var redrawInFlight = false
    private var redrawDirty = false
    private var redrawWaiters: [(Result<Double, Error>) -> Void] = []
    private var lastRedrawStart: TimeInterval = 0
    private var sourceFrameActive = false
    private var sourceFrameToken: UInt64 = 0
    private var firstFrameSent = false
    private var reportedSize: CGSize?
    private(set) var disposed = false
    private var clockTimer: DispatchSourceTimer?
    private var boundaryObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var lifecycleObservers: [NSObjectProtocol] = []
    private var insideRanges: Set<Range<Int64>> = []
    private var resignedWhilePlaying = false
    /// Structural rebuilds completed (tests).
    private(set) var rebuildCount = 0
    /// Redraws pushed to the texture (tests).
    private(set) var redrawCount = 0

    init(id: String, config: PreviewConfigMsg, queue: DispatchQueue, dependencies: Dependencies) throws {
        self.id = id
        self.config = config
        self.queue = queue
        self.deps = dependencies
        let fps = Int(config.fps)
        let empty = RenderPlan(
            rev: 0, target: .preview, canvas: PlanCanvas(w: Int(config.canvasWidth), h: Int(config.canvasHeight), fps: fps),
            durUs: 0, assets: [:], layers: [], audio: [])
        let store = ParamSnapshotStore(ParamSnapshot(plan: empty))
        let renderSession = try DVRenderSession(snapshots: store)
        let textureBridge = TextureBridge()
        let qualityGovernor = QualityGovernor(requested: config.quality)
        let avPlayer = AVPlayer()
        avPlayer.automaticallyWaitsToMinimizeStalling = false
        avPlayer.actionAtItemEnd = .pause
        let seekController = SeekController(queue: queue, bridge: textureBridge, fps: Int64(fps))
        seekController.player = avPlayer
        seekController.lastComposedFrame = { [weak renderSession] in renderSession?.redraw.last?.k }
        snapshots = store
        render = renderSession
        bridge = textureBridge
        governor = qualityGovernor
        player = avPlayer
        seeks = seekController
        displayLink = DisplayLinkDriver(fps: fps, textureLatency: dependencies.textureLatency)
        audio = dependencies.audioSession.map { AudioSessionCoordinator(port: $0) }
        sourceFrames = SourceFrameCache(tier: dependencies.tier)
        useProxies = config.useProxies
        renderSize = QualityGovernor.renderSize(
            canvasWidth: Int(config.canvasWidth), canvasHeight: Int(config.canvasHeight), level: qualityGovernor.level,
            maxLongSide: dependencies.maxPreviewLongSide)
        displayLink.onTick = { [weak self] t in self?.onDisplayTick(t) }
        if dependencies.observeLifecycle { observeLifecycle() }
        // Kernel pre-warm (IOS-01: the first blur compile took 1–3 s) off the control queue.
        let r = render
        workQueue.async { r.prewarm() }
    }

    deinit {
        lifecycleObservers.forEach(NotificationCenter.default.removeObserver)
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
    }

    /// Registers the texture (main thread hop); [completion] gets the texture id.
    func registerTexture(completion: @escaping (Int64) -> Void) {
        bridge.register(with: deps.registry, completion: completion)
    }

    private var grid: FrameGrid { FrameGrid(fps: Int64(config.fps)) }

    /// Output frames of the current plan.
    var frameCount: Int64 {
        guard let plan else { return 0 }
        return max(0, plan.canvas.outputGrid.frameIndexOf(plan.durUs))
    }

    private func clampFrame(_ k: Int64) -> Int64 { max(0, min(k, max(0, frameCount - 1))) }

    private func ms(since t: TimeInterval) -> Int64 { Int64(((deps.now() - t) * 1000).rounded()) }

    // MARK: Plans

    func setPlan(_ data: Data, reply: @escaping EngineReply<PlanAckMsg>) {
        guard !disposed else { return reply(.failure(EngineError.cancelled)) }
        let start = deps.now()
        let next: RenderPlan
        do {
            next = try RenderPlanDecoder.decodePlan(data)
            try PreviewSession.validate(next)
        } catch {
            return reply(.failure(PreviewSession.planError(error)))
        }
        plan = next
        transients.removeAll()
        rebuild(frame: currentFrame) { [weak self] result in
            guard let self else { return }
            reply(result.map { PlanAckMsg(rev: next.rev, structural: true, applyMs: self.ms(since: start)) })
        }
    }

    func applyPatch(_ data: Data, reply: @escaping EngineReply<PlanAckMsg>) {
        guard !disposed else { return reply(.failure(EngineError.cancelled)) }
        let start = deps.now()
        guard let current = plan else {
            return reply(.failure(EngineError(.planOutOfSync, "no plan yet")))
        }
        let patch: RenderPlanPatch
        let next: RenderPlan
        do {
            patch = try RenderPlanDecoder.decodePatch(data)
            next = try PlanPatching.apply(patch, to: current)
            try PreviewSession.validate(next)
        } catch {
            return reply(.failure(PreviewSession.planError(error)))
        }
        let touched = PlanPatching.touchedLayerIds(patch)
        transients.removeAll { t in t.layers.contains { touched.contains($0.id) } }
        plan = next
        var structural = PlanPatching.classify(patch, from: current) == .structural
        if !structural, !rebuilding, let built, !built.updateGains(next) {
            structural = true
        }
        if structural {
            rebuild(frame: currentFrame) { [weak self] result in
                guard let self else { return }
                reply(result.map { PlanAckMsg(rev: next.rev, structural: true, applyMs: self.ms(since: start)) })
            }
            return
        }
        if rebuilding {
            // The landing rebuild swaps in a snapshot of the latest plan.
            return reply(.success(PlanAckMsg(rev: next.rev, structural: false, applyMs: ms(since: start))))
        }
        snapshots.swap(makeSnapshot())
        guard !playing, built != nil else {
            return reply(.success(PlanAckMsg(rev: next.rev, structural: false, applyMs: ms(since: start))))
        }
        scheduleRedraw { [weak self] _ in
            guard let self else { return }
            reply(.success(PlanAckMsg(rev: next.rev, structural: false, applyMs: self.ms(since: start))))
        }
    }

    func setTransient(itemId: String, params: Data) {
        guard !disposed, plan != nil, let t = try? RenderPlanDecoder.decodeTransient(params) else { return }
        let transient = PlanTransient(v: t.v, item: itemId, layers: t.layers)
        transients.removeAll { $0.item == itemId }
        transients.append(transient)
        guard !rebuilding else { return }
        snapshots.swap(makeSnapshot())
        if !playing { scheduleRedraw(nil) }
    }

    func clearTransient(itemId: String) {
        guard !disposed, transients.contains(where: { $0.item == itemId }) else { return }
        transients.removeAll { $0.item == itemId }
        guard !rebuilding else { return }
        snapshots.swap(makeSnapshot())
        if !playing { scheduleRedraw(nil) }
    }

    private func makeSnapshot() -> ParamSnapshot {
        guard let plan else { return snapshots.current }
        return transients.reduce(ParamSnapshot(plan: plan)) { $0.applying($1) }
    }

    static func validate(_ plan: RenderPlan) throws {
        let violations = PlanValidator.validate(plan)
        if let first = violations.first {
            throw EngineError(.planInvalid, first.description, itemId: first.id)
        }
    }

    static func planError(_ error: Error) -> EngineError {
        switch error {
        case let e as EngineError: return e
        case let e as PlanOutOfSync: return EngineError(.planOutOfSync, "patch from \(e.patchFrom), engine at \(e.planRev)")
        case let e as PlanFormatError: return EngineError(.planInvalid, "\(e)")
        default: return EngineError(.planInvalid, "\(error)")
        }
    }

    // MARK: Rebuild

    /// The plan the player item is built from: the plan, or its stills variant while playing over
    /// the live decode budget.
    private func compositionPlan(playing: Bool, anchor k: Int64) -> (plan: RenderPlan, stills: Bool)? {
        guard let plan else { return nil }
        if playing, let s = PlaybackStills.plan(plan, budget: deps.liveDecodeBudget, anchorFrame: k) {
            return (s.plan, true)
        }
        return (plan, false)
    }

    /// Builds a new item for the current plan, swaps it in at output frame [frame] and restores
    /// the play state ([resume] defaults to the current one).
    private func rebuild(frame: Int64, resume: Bool? = nil, completion: @escaping (Result<Void, Error>) -> Void) {
        let resumePlaying = resume ?? (playing || wantsPlaying)
        guard let target = compositionPlan(playing: resumePlaying, anchor: frame) else {
            return completion(.failure(EngineError(.planOutOfSync, "no plan")))
        }
        rebuildGeneration &+= 1
        let gen = rebuildGeneration
        rebuilding = true
        wantsPlaying = resumePlaying
        let compositionPlan = target.plan
        if CompositionBuilder.frameTotal(compositionPlan) == 0 {
            // Nothing to play: an empty timeline shows its background only.
            stopPlayback()
            player.replaceCurrentItem(with: nil)
            item = nil
            built?.releaseMedia()
            built = nil
            seeks.player = player
            snapshots.swap(makeSnapshot())
            currentFrame = 0
            finishRebuild(gen, .success(()), completion)
            return
        }
        var options = CompositionBuildOptions(spacerDirectory: deps.spacerDirectory)
        options.renderSize = renderSize
        options.useProxies = useProxies
        options.resolveURL = deps.resolveURL
        options.access = access
        options.validate = false
        render.configure(&options)
        CompositionBuilder.build(plan: compositionPlan, options: options, queue: queue) { [weak self] result in
            guard let self else { return }
            guard !self.disposed else {
                if case .success(let b) = result { b.releaseMedia() }
                return completion(.failure(EngineError.cancelled))
            }
            guard gen == self.rebuildGeneration else {
                // Superseded by a newer rebuild, which covers this change.
                if case .success(let b) = result { b.releaseMedia() }
                return completion(.success(()))
            }
            switch result {
            case .failure(let error):
                self.finishRebuild(gen, .failure(EngineError.from(error)), completion)
            case .success(let b):
                self.install(b, stills: target.stills, frame: frame, gen: gen, completion: completion)
            }
        }
    }

    private func install(_ b: BuiltComposition, stills: Bool, frame: Int64, gen: UInt64,
                         completion: @escaping (Result<Void, Error>) -> Void) {
        let newItem = AVPlayerItem(asset: b.composition)
        newItem.videoComposition = b.videoComposition
        newItem.audioMix = b.audioMix
        newItem.seekingWaitsForVideoCompositionRendering = true
        let output = TextureBridge.makeOutput()
        newItem.add(output)
        let wasPlaying = playing
        if wasPlaying { stopPlayback(keepWanted: true) }
        player.pause()
        snapshots.swap(makeSnapshot())
        render.redraw.cancelPending()
        let old = built
        statusObservation = nil
        player.replaceCurrentItem(with: newItem)
        item = newItem
        built = b
        playingStills = stills
        bridge.output = output
        seeks.player = player
        observeEnd(of: newItem)
        let k = clampFrame(frame)
        var started = false
        statusObservation = newItem.observe(\.status, options: [.initial, .new]) { [weak self] observed, _ in
            let status = observed.status
            let error = observed.error
            self?.queue.async {
                guard let self, !started, gen == self.rebuildGeneration, self.item === newItem else { return }
                switch status {
                case .readyToPlay:
                    started = true
                    self.statusObservation = nil
                    self.seeks.exact(k, requireNew: true) { [weak self] outcome in
                        guard let self else { return }
                        old?.releaseMedia()
                        guard gen == self.rebuildGeneration else { return completion(.success(())) }
                        self.currentFrame = outcome.frame
                        self.rebuildCount += 1
                        self.frameShown()
                        self.finishRebuild(gen, .success(()), completion)
                    }
                case .failed:
                    started = true
                    self.statusObservation = nil
                    old?.releaseMedia()
                    let failure = error.map(EngineError.from) ?? EngineError(.decodeFailed, "player item failed")
                    self.finishRebuild(gen, .failure(failure), completion)
                default:
                    break
                }
            }
        }
    }

    private func finishRebuild(_ gen: UInt64, _ result: Result<Void, Error>, _ completion: @escaping (Result<Void, Error>) -> Void) {
        guard gen == rebuildGeneration else { return completion(.success(())) }
        rebuilding = false
        if case .failure(let error) = result {
            wantsPlaying = false
            deps.events.emitPreviewEvent(sessionId: id, PreviewEventMsg(kind: .failed, failure: EngineError.from(error).failureMsg))
        } else {
            // Params patched while the rebuild was in flight.
            snapshots.swap(makeSnapshot())
            if wantsPlaying && !playing { startPlayback() }
        }
        // Paused on a stills composition: back to the full one (exact for every layer).
        var succeeded = false
        if case .success = result { succeeded = true }
        let leaveStills = succeeded && !wantsPlaying && playingStills && built != nil
        if leaveStills {
            rebuild(frame: currentFrame, resume: false) { result in completion(result) }
            return
        }
        completion(result)
        let pending = afterRebuild
        afterRebuild.removeAll()
        pending.forEach { $0() }
        emitClock()
    }

    /// Runs [work] now, or after the rebuild in flight.
    private func whenSettled(_ work: @escaping () -> Void) {
        if rebuilding { afterRebuild.append(work) } else { work() }
    }

    /// First-frame and frame-size events after a frame reached the texture.
    private func frameShown() {
        guard let frame = bridge.current else { return }
        let size = CGSize(width: CVPixelBufferGetWidth(frame.buffer), height: CVPixelBufferGetHeight(frame.buffer))
        if !firstFrameSent {
            firstFrameSent = true
            reportedSize = size
            deps.events.emitPreviewEvent(
                sessionId: id, PreviewEventMsg(kind: .firstFrame, width: Int64(size.width), height: Int64(size.height)))
        } else if reportedSize != size {
            reportedSize = size
            deps.events.emitPreviewEvent(
                sessionId: id, PreviewEventMsg(kind: .frameSize, width: Int64(size.width), height: Int64(size.height)))
        }
    }

    // MARK: Redraw (paused)

    /// Re-composes the cached frame with the current snapshot and mode, at most once per output
    /// frame; requests made meanwhile coalesce into one more redraw.
    private func scheduleRedraw(_ completion: ((Result<Double, Error>) -> Void)?) {
        if let completion { redrawWaiters.append(completion) }
        if redrawInFlight {
            redrawDirty = true
            return
        }
        let interval = 1.0 / Double(max(1, config.fps))
        let wait = lastRedrawStart + interval - deps.now()
        if wait > 0.0005 {
            redrawInFlight = true
            queue.asyncAfter(deadline: .now() + wait) { [weak self] in
                guard let self else { return }
                self.redrawInFlight = false
                self.scheduleRedraw(nil)
            }
            return
        }
        redrawInFlight = true
        redrawDirty = false
        lastRedrawStart = deps.now()
        let waiters = redrawWaiters
        redrawWaiters.removeAll()
        let token = sourceFrameToken
        render.redraw.requestRedraw { [weak self] result in
            guard let self else { return }
            if case .success(let r)? = result {
                self.queue.async {
                    if !self.disposed, !self.playing {
                        if self.sourceFrameActive && token == self.sourceFrameToken { self.sourceFrameActive = false }
                        self.bridge.push(r.buffer)
                        self.redrawCount += 1
                    }
                }
            }
            self.queue.async {
                self.redrawInFlight = false
                let outcome: Result<Double, Error>
                switch result {
                case .success(let r)?: outcome = .success(r.renderMs)
                case .failure(let e)?: outcome = .failure(e)
                case nil: outcome = .success(0)
                }
                waiters.forEach { $0(outcome) }
                if self.redrawDirty || !self.redrawWaiters.isEmpty {
                    self.redrawDirty = false
                    self.scheduleRedraw(nil)
                }
            }
        }
    }

    // MARK: Transport

    func play(loop: LoopMsg?, reply: @escaping EngineReply<Int64>) {
        guard !disposed else { return reply(.failure(EngineError.cancelled)) }
        seq += 1
        let mySeq = seq
        self.loop = loop
        clearSourceFrame()
        seeks.dropPendingScrub()
        guard plan != nil else {
            reply(.success(mySeq))
            return emitClock()
        }
        audio?.beginPlayback()
        wantsPlaying = true
        reply(.success(mySeq))
        whenSettled { [weak self] in
            guard let self, !self.disposed, self.wantsPlaying, !self.playing, self.built != nil else { return }
            var start = self.currentFrame
            if let loop {
                let k0 = self.clampFrame(self.grid.frameIndexOf(loop.startUs))
                let k1 = self.clampFrame(self.grid.frameIndexOf(loop.endUs))
                if start < k0 || start >= k1 { start = k0 }
            } else if start >= self.frameCount - 1 {
                start = 0
            }
            let needsStills = PlaybackStills.plan(
                self.plan!, budget: self.deps.liveDecodeBudget, anchorFrame: start) != nil
            if needsStills != self.playingStills {
                self.rebuild(frame: start, resume: true) { _ in }
            } else if start != self.currentFrame {
                self.seeks.exact(start) { [weak self] o in
                    guard let self, self.wantsPlaying, !self.playing else { return }
                    self.currentFrame = o.frame
                    self.startPlayback()
                }
            } else {
                self.startPlayback()
            }
        }
        emitClock()
    }

    func pause(reply: @escaping EngineReply<Int64>) {
        guard !disposed else { return reply(.failure(EngineError.cancelled)) }
        seq += 1
        let mySeq = seq
        let wasPlaying = playing
        seeks.dropPendingScrub()
        wantsPlaying = false
        if wasPlaying {
            stopPlayback()
            if let k = bridge.lastComposed?.k { currentFrame = clampFrame(k) }
        }
        reply(.success(mySeq))
        emitClock()
        guard wasPlaying else { return }
        // Settle on an exact frame: the compositor may have composed ahead, and paused edits
        // redraw the compositor's last request. Stills playback goes back to the full composition.
        if playingStills {
            rebuild(frame: currentFrame, resume: false) { _ in }
        } else {
            let k = currentFrame
            seeks.exact(k) { [weak self] o in
                guard let self, !self.playing else { return }
                self.currentFrame = o.frame
            }
        }
    }

    func seek(timeUs: Int64, exact: Bool, reply: @escaping EngineReply<SeekAckMsg>) {
        guard !disposed else { return reply(.failure(EngineError.cancelled)) }
        seq += 1
        let mySeq = seq
        clearSourceFrame()
        let run = { [weak self] in
            guard let self else { return }
            guard !self.disposed else { return reply(.failure(EngineError.cancelled)) }
            let k = self.clampFrame(self.grid.frameIndexOf(timeUs))
            let done: SeekController.Completion = { [weak self] o in
                guard let self else { return }
                self.currentFrame = o.frame
                if self.playing { self.tick.setMinFrame(o.frame) }
                reply(.success(SeekAckMsg(
                    requestedUs: timeUs, displayedFrameTimeUs: self.grid.timeOfFrame(o.frame), displayedFrame: o.frame,
                    seq: mySeq)))
                self.emitClock()
            }
            if self.built == nil {
                self.currentFrame = k
                return done(SeekController.Outcome(frame: k, reached: true, ms: 0))
            }
            if self.playing { self.tick.setMinFrame(min(k, self.currentFrame)) }
            if self.playingStills {
                // Stills are anchored at the play position: re-anchor them at k (exact for every layer).
                self.currentFrame = k
                self.rebuild(frame: k, resume: true) { [weak self] _ in
                    guard let self else { return }
                    done(SeekController.Outcome(frame: self.currentFrame, reached: true, ms: 0))
                }
                return
            }
            self.currentFrame = k
            if exact { self.seeks.exact(k, completion: done) } else { self.seeks.scrub(k, completion: done) }
        }
        whenSettled(run)
    }

    private func startPlayback() {
        guard !disposed, built != nil, !playing else { return }
        playing = true
        wantsPlaying = true
        governor.playbackStarted(at: deps.now())
        tick.set(playing: true, minFrame: currentFrame)
        player.playImmediately(atRate: 1)
        displayLink.start()
        startClockTimer()
        installBoundaryObserver()
        emitClock()
    }

    private func stopPlayback(keepWanted: Bool = false) {
        guard playing else { return }
        playing = false
        if !keepWanted { wantsPlaying = false }
        player.pause()
        tick.set(playing: false, minFrame: currentFrame)
        displayLink.stop()
        clockTimer?.cancel()
        clockTimer = nil
        removeBoundaryObserver()
        governor.playbackStopped()
    }

    private func clearSourceFrame() {
        guard sourceFrameActive else {
            sourceFrameToken &+= 1
            return
        }
        sourceFrameActive = false
        sourceFrameToken &+= 1
        bridge.restoreComposed()
    }

    // MARK: Display link (main thread)

    private func onDisplayTick(_ t: DisplayLinkDriver.Tick) {
        guard tick.playing, let output = bridge.output else { return }
        let host = t.targetTimestamp + displayLink.textureLatency
        let itemTime = output.itemTime(forHostTime: host)
        let minFrame = tick.minFrame
        guard let frame = bridge.pull(itemTime: itemTime, accept: { k in (k ?? Int64.max) >= minFrame }), let k = frame.k else {
            return
        }
        let missed = tick.displayed(k)
        queue.async { [weak self] in self?.playbackFrame(k, missed: missed) }
    }

    /// One frame displayed during playback (control queue).
    private func playbackFrame(_ k: Int64, missed: Int) {
        guard playing else { return }
        currentFrame = k
        let now = deps.now()
        var step: QualityGovernor.Level?
        for _ in 0..<min(missed, 120) { step = governor.record(missed: true, at: now) ?? step }
        step = governor.record(missed: false, at: now) ?? step
        if let step { governorStepped(to: step) }
    }

    /// Feeds one playback frame sample to the governor (tests drive the auto quality with it).
    func governorSample(missed: Bool, at t: TimeInterval) {
        if let step = governor.record(missed: missed, at: t) { governorStepped(to: step) }
    }

    private func governorStepped(to level: QualityGovernor.Level) {
        deps.events.emitPreviewEvent(sessionId: id, PreviewEventMsg(kind: .degraded, quality: level.msg))
        if level == .full { deps.events.emitPreviewEvent(sessionId: id, PreviewEventMsg(kind: .recovered)) }
        applyRenderSize(nil)
    }

    // MARK: Clock

    private func emitClock() {
        guard !disposed else { return }
        deps.events.emitClock(
            sessionId: id, ClockMsg(timeUs: clockTimeUs(), playing: playing, rate: playing ? Double(player.rate) : 0, seq: seq))
    }

    private func clockTimeUs() -> Int64 {
        if playing, let item, item.currentTime().isNumeric {
            return grid.timeOfFrame(clampFrame(grid.frameIndexNearest(item.currentTime())))
        }
        return grid.timeOfFrame(currentFrame)
    }

    private func startClockTimer() {
        clockTimer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + .milliseconds(100), repeating: .milliseconds(100), leeway: .milliseconds(5))
        t.setEventHandler { [weak self] in
            guard let self, self.playing else { return }
            self.emitClock()
        }
        clockTimer = t
        t.resume()
    }

    // MARK: Loop, end, rendered ranges

    private func installBoundaryObserver() {
        removeBoundaryObserver()
        var frames = Set<Int64>()
        if let loop {
            frames.insert(clampFrame(grid.frameIndexOf(loop.endUs)))
        }
        let ranges = plan.map { deps.renderedRanges.renderedRanges(planRev: $0.rev) } ?? []
        for r in ranges {
            frames.insert(r.lowerBound)
            frames.insert(r.upperBound)
        }
        insideRanges = Set(ranges.filter { $0.contains(currentFrame) })
        for r in insideRanges { deps.renderedRanges.playbackCrossed(range: r, entered: true, atFrame: currentFrame) }
        guard !frames.isEmpty else { return }
        let times = frames.sorted().map { NSValue(time: CMTime(value: $0, timescale: CMTimeScale(config.fps))) }
        boundaryObserver = player.addBoundaryTimeObserver(forTimes: times, queue: queue) { [weak self] in
            self?.boundaryReached()
        }
    }

    private func removeBoundaryObserver() {
        if let o = boundaryObserver { player.removeTimeObserver(o) }
        boundaryObserver = nil
    }

    private func boundaryReached() {
        guard playing, let item else { return }
        let k = grid.frameIndexNearest(item.currentTime())
        if let loop, k >= clampFrame(grid.frameIndexOf(loop.endUs)) {
            restartLoop()
            return
        }
        updateRanges(at: k)
    }

    private func updateRanges(at k: Int64) {
        guard let plan else { return }
        let ranges = deps.renderedRanges.renderedRanges(planRev: plan.rev)
        let now = Set(ranges.filter { $0.contains(k) })
        for r in insideRanges.subtracting(now).sorted(by: { $0.lowerBound < $1.lowerBound }) {
            deps.renderedRanges.playbackCrossed(range: r, entered: false, atFrame: k)
        }
        for r in now.subtracting(insideRanges).sorted(by: { $0.lowerBound < $1.lowerBound }) {
            deps.renderedRanges.playbackCrossed(range: r, entered: true, atFrame: k)
        }
        insideRanges = now
    }

    private func restartLoop() {
        guard let loop else { return }
        let k0 = clampFrame(grid.frameIndexOf(loop.startUs))
        tick.setMinFrame(k0)
        updateRanges(at: k0)
        seeks.exact(k0) { [weak self] o in self?.currentFrame = o.frame }
    }

    private func observeEnd(of item: AVPlayerItem) {
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: nil
        ) { [weak self] _ in
            self?.queue.async { self?.reachedEnd() }
        }
    }

    private func reachedEnd() {
        guard playing else { return }
        if loop != nil {
            restartLoop()
            return
        }
        updateRanges(at: frameCount)
        stopPlayback()
        if let k = bridge.lastComposed?.k { currentFrame = clampFrame(k) }
        emitClock()
    }

    // MARK: Quality and proxies

    func setQuality(_ quality: PreviewQualityMsg, reply: @escaping EngineReply<Void>) {
        guard !disposed else { return reply(.failure(EngineError.cancelled)) }
        if governor.setRequested(quality, at: deps.now()) != nil || currentLevelSize() != renderSize {
            applyRenderSize { reply(.success(())) }
        } else {
            reply(.success(()))
        }
    }

    private func currentLevelSize() -> CGSize {
        QualityGovernor.renderSize(
            canvasWidth: plan?.canvas.w ?? Int(config.canvasWidth), canvasHeight: plan?.canvas.h ?? Int(config.canvasHeight),
            level: governor.level, maxLongSide: deps.maxPreviewLongSide)
    }

    /// Applies the governor's level to the item's render size; re-composes the frame when paused.
    private func applyRenderSize(_ completion: (() -> Void)?) {
        let size = currentLevelSize()
        guard size != renderSize else {
            completion?()
            return
        }
        renderSize = size
        let apply = { [weak self] in
            guard let self else { return }
            guard let built = self.built, let item = self.item,
                  let vc = built.videoComposition.mutableCopy() as? AVMutableVideoComposition else {
                completion?()
                return
            }
            vc.renderSize = size
            item.videoComposition = vc
            if self.playing {
                completion?()
                return
            }
            self.seeks.exact(self.currentFrame, requireNew: true) { [weak self] o in
                guard let self else { return }
                self.currentFrame = o.frame
                self.frameShown()
                completion?()
            }
        }
        whenSettled(apply)
    }

    func setUseProxies(_ on: Bool, reply: @escaping EngineReply<Void>) {
        guard !disposed else { return reply(.failure(EngineError.cancelled)) }
        guard on != useProxies else { return reply(.success(())) }
        useProxies = on
        guard plan != nil else { return reply(.success(())) }
        rebuild(frame: currentFrame) { reply($0) }
    }

    // MARK: Editing modes, source frames, colours, stills

    func setEditingMode(_ mode: EditingModeMsg, reply: @escaping EngineReply<Void>) {
        guard !disposed else { return reply(.failure(EngineError.cancelled)) }
        switch mode.kind {
        case .normal: render.mode = .normal
        case .cropSource: render.mode = .cropSource(item: mode.itemId ?? "")
        case .matte: render.mode = .matte(item: mode.itemId ?? "")
        }
        guard !playing, built != nil, !rebuilding else { return reply(.success(())) }
        scheduleRedraw { _ in reply(.success(())) }
    }

    func showSourceFrame(media: ResolvedMediaMsg, mediaURL: URL, sourceTimeUs: Int64, reply: @escaping EngineReply<Void>) {
        guard !disposed else { return reply(.failure(EngineError.cancelled)) }
        sourceFrameToken &+= 1
        let token = sourceFrameToken
        let size = renderSize
        let cache = sourceFrames
        let context = render.context
        let fp = media.fingerprint.isEmpty ? nil : media.fingerprint
        workQueue.async { [weak self] in
            do {
                let image = try cache.frame(
                    url: mediaURL, media: fp, sourceTimeUs: sourceTimeUs, maxLongSide: Int(max(size.width, size.height)))
                let buffer = try PreviewSession.fitted(image, into: size, context: context)
                self?.queue.async {
                    guard let self else { return }
                    guard !self.disposed, token == self.sourceFrameToken, !self.playing else { return reply(.success(())) }
                    self.bridge.pushOverlay(buffer)
                    self.sourceFrameActive = true
                    reply(.success(()))
                }
            } catch {
                reply(.failure(EngineError.from(error)))
            }
        }
    }

    /// The media layer of [itemId] (its `#v` layer first) and the output frame to sample it at.
    private func mediaLayer(item itemId: String) -> (layer: PlanLayer, k: Int64)? {
        guard let plan else { return nil }
        let candidates = plan.layers.filter { DVEditingMode.itemId(ofLayer: $0.id) == itemId }
        guard let layer = candidates.first(where: { $0.id == itemId + "#v" }) ?? candidates.first else { return nil }
        let og = plan.canvas.outputGrid
        var k = currentFrame
        if !layer.covers(og.timeOfFrame(k)) {
            k = og.frameIndexOf(layer.t0)
            if og.timeOfFrame(k) < layer.t0 { k += 1 }
        }
        return (layer, k)
    }

    private func url(of assetId: String, _ asset: PlanAsset) throws -> URL {
        if let resolve = deps.resolveURL { return try resolve(assetId, asset) }
        return try MediaURLResolver.resolve(asset, useProxies: false).url
    }

    /// The source time (µs, ε applied for FrameGrab's +1 µs request) displayed by [layer] at [k].
    private func sourceRequestUs(_ layer: PlanLayer, k: Int64) -> Int64? {
        guard let plan, let s = ParamSnapshot.sourceTime(layer, at: plan.canvas.outputGrid.timeOfFrame(k)) else { return nil }
        return Int64(s.rounded(.down)) + CompositionBuilder.epsilonUs - 1
    }

    func sampleColor(itemId: String, x: Double, y: Double, reply: @escaping EngineReply<ColorMsg?>) {
        guard !disposed else { return reply(.failure(EngineError.cancelled)) }
        guard let (layer, k) = mediaLayer(item: itemId), layer.kind == .media, let assetId = layer.asset,
              let asset = plan?.assets[assetId], let us = sourceRequestUs(layer, k: k) else {
            return reply(.success(nil))
        }
        let url: URL
        do { url = try self.url(of: assetId, asset) } catch { return reply(.failure(EngineError.from(error))) }
        let cache = sourceFrames
        let fp = asset.fp.isEmpty ? nil : asset.fp
        workQueue.async {
            do {
                reply(.success(try cache.sampleColor(url: url, media: fp, sourceTimeUs: us, x: x, y: y)))
            } catch {
                reply(.failure(EngineError.from(error)))
            }
        }
    }

    func renderLookStills(itemId: String, looks: [LookSpecMsg], lutURLs: [URL], heightPx: Int64,
                          reply: @escaping EngineReply<[Data]>) {
        guard !disposed else { return reply(.failure(EngineError.cancelled)) }
        guard let plan, let (layer, k) = mediaLayer(item: itemId) else {
            return reply(.failure(EngineError(.internal, "no layer for the item", itemId: itemId)))
        }
        let h = max(1, Int(heightPx))
        let w = max(1, Int((Double(h) * Double(plan.canvas.w) / Double(plan.canvas.h)).rounded()))
        var sourceURL: URL?
        var request: Int64?
        if layer.kind == .media, let assetId = layer.asset, let asset = plan.assets[assetId] {
            do { sourceURL = try url(of: assetId, asset) } catch { return reply(.failure(EngineError.from(error))) }
            request = sourceRequestUs(layer, k: k)
        }
        let snapshot = snapshots.current
        let render = self.render
        let cache = sourceFrames
        workQueue.async {
            do {
                var sources = DVRenderSession.Sources.none
                var base = snapshot.plan
                if let sourceURL, let request, let assetId = layer.asset {
                    // FrameGrab frames are display-oriented already: render them with rot 0.
                    let image = try cache.frame(url: sourceURL, media: base.assets[assetId]?.fp, sourceTimeUs: request,
                                                maxLongSide: max(w, h) * 2)
                    let pb = try PreviewSession.pixelBuffer(image, context: render.context)
                    sources = DVRenderSession.Sources(buffers: [1: pb], trackIDByLayer: [layer.id: 1])
                    base.assets[assetId]?.rot = 0
                }
                var stills: [Data] = []
                for (i, look) in looks.enumerated() {
                    var p = base
                    let lutId = "__look_\(i)"
                    p.assets[lutId] = PlanAsset(kind: .lut, uri: lutURLs[i].absoluteString, fp: lutId)
                    if let idx = p.layers.firstIndex(where: { $0.id == layer.id }) {
                        p.layers[idx].fx.lut = PlanLut(asset: lutId, i: look.intensity)
                    }
                    let out = try PreviewSession.makeBuffer(CGSize(width: w, height: h))
                    try render.render(snapshot: ParamSnapshot(plan: p), frame: k, sources: sources,
                                      mode: .cropSource(item: itemId), into: out)
                    stills.append(try PreviewSession.jpeg(out, context: render.context))
                }
                reply(.success(stills))
            } catch {
                reply(.failure(EngineError.from(error)))
            }
        }
    }

    // MARK: Refresh, capture

    func refresh(reply: @escaping EngineReply<Void>) {
        guard !disposed else { return reply(.failure(EngineError.cancelled)) }
        whenSettled { [weak self] in
            guard let self else { return }
            guard self.built != nil, !self.playing else {
                self.bridge.restoreComposed()
                return reply(.success(()))
            }
            self.seeks.exact(self.currentFrame, requireNew: true) { [weak self] o in
                self?.currentFrame = o.frame
                reply(.success(()))
            }
        }
    }

    func debugCaptureFrame(reply: @escaping EngineReply<Data>) {
        guard !disposed else { return reply(.failure(EngineError.cancelled)) }
        guard let frame = bridge.captureRGBA() else {
            return reply(.failure(EngineError(.busy, "no frame on screen yet", retryable: true)))
        }
        reply(.success(frame.bytes))
    }

    // MARK: Lifecycle

    private func observeLifecycle() {
        let center = NotificationCenter.default
        let on: (Notification.Name, @escaping (PreviewSession) -> Void) -> Void = { name, handler in
            self.lifecycleObservers.append(center.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                guard let self else { return }
                self.queue.async { [weak self] in
                    guard let self, !self.disposed else { return }
                    handler(self)
                }
            })
        }
        on(UIApplication.willResignActiveNotification) { $0.handleResignActive() }
        on(UIApplication.didEnterBackgroundNotification) { $0.handleBackground() }
        on(UIApplication.didBecomeActiveNotification) { $0.handleBecomeActive() }
        on(UIApplication.didReceiveMemoryWarningNotification) { $0.handleMemoryWarning() }
        on(ProcessInfo.thermalStateDidChangeNotification) { $0.handleThermal(ProcessInfo.processInfo.thermalState) }
    }

    /// App resigns active: pause (a real pause: seq and clock) and stop the display link.
    func handleResignActive() {
        resignedWhilePlaying = playing
        if playing || wantsPlaying { pause { _ in } }
        displayLink.stop()
    }

    /// App in background: release Core Image intermediates (the frame stays on the texture).
    func handleBackground() {
        render.releaseIntermediates()
    }

    /// App active again: re-compose the current frame.
    func handleBecomeActive() {
        resignedWhilePlaying = false
        refresh { _ in }
    }

    /// Memory warning: trim the render caches to 25% and drop decoded source frames.
    func handleMemoryWarning() {
        render.trimCaches(to: 0.25)
        sourceFrames.removeAll()
    }

    func handleThermal(_ state: ProcessInfo.ThermalState) {
        if let step = governor.setThermal(state, at: deps.now()) { governorStepped(to: step) }
    }

    // MARK: Dispose

    func dispose(completion: @escaping () -> Void) {
        guard !disposed else { return completion() }
        stopPlayback()
        wantsPlaying = false
        disposed = true
        rebuildGeneration &+= 1
        seeks.cancelAll()
        seeks.player = nil
        lifecycleObservers.forEach(NotificationCenter.default.removeObserver)
        lifecycleObservers.removeAll()
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        statusObservation = nil
        player.replaceCurrentItem(with: nil)
        item = nil
        displayLink.stop()
        displayLink.onTick = nil
        render.redraw.cancelPending()
        render.redraw.clear()
        render.releaseIntermediates()
        sourceFrames.removeAll()
        built?.releaseMedia()
        built = nil
        access.releaseAll()
        audio?.restore()
        let pending = afterRebuild
        afterRebuild.removeAll()
        pending.forEach { $0() }
        bridge.unregister(completion: completion)
    }

    // MARK: Pixel helpers

    static func makeBuffer(_ size: CGSize) throws -> CVPixelBuffer {
        var attrs = DVRenderSession.pixelBufferAttributes as [String: Any]
        let w = max(1, Int(size.width.rounded()))
        let h = max(1, Int(size.height.rounded()))
        attrs[kCVPixelBufferWidthKey as String] = w
        attrs[kCVPixelBufferHeightKey as String] = h
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, w, h, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pb)
        guard let pb else { throw EngineError(.internal, "pixel buffer allocation failed") }
        return pb
    }

    /// [image] as a BGRA buffer of its own size (no colour conversion).
    static func pixelBuffer(_ image: CGImage, context: CIContext) throws -> CVPixelBuffer {
        let pb = try makeBuffer(CGSize(width: image.width, height: image.height))
        let ci = CIImage(cgImage: image, options: [.colorSpace: NSNull()])
        context.render(ci, to: pb, bounds: CGRect(x: 0, y: 0, width: image.width, height: image.height), colorSpace: nil)
        return pb
    }

    /// [image] fitted (letterboxed on black) into a BGRA buffer of [size].
    static func fitted(_ image: CGImage, into size: CGSize, context: CIContext) throws -> CVPixelBuffer {
        let pb = try makeBuffer(size)
        let w = CGFloat(CVPixelBufferGetWidth(pb))
        let h = CGFloat(CVPixelBufferGetHeight(pb))
        let k = min(w / CGFloat(image.width), h / CGFloat(image.height))
        let dw = CGFloat(image.width) * k
        let dh = CGFloat(image.height) * k
        let ci = CIImage(cgImage: image, options: [.colorSpace: NSNull()])
            .transformed(by: CGAffineTransform(scaleX: k, y: k))
            .transformed(by: CGAffineTransform(translationX: (w - dw) / 2, y: (h - dh) / 2))
        let black = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 1)).cropped(to: CGRect(x: 0, y: 0, width: w, height: h))
        context.render(ci.composited(over: black), to: pb, bounds: CGRect(x: 0, y: 0, width: w, height: h), colorSpace: nil)
        return pb
    }

    /// JPEG bytes of a BGRA buffer.
    static func jpeg(_ pb: CVPixelBuffer, context: CIContext, quality: Double = 0.85) throws -> Data {
        let w = CVPixelBufferGetWidth(pb)
        let h = CVPixelBufferGetHeight(pb)
        let image = CIImage(cvPixelBuffer: pb, options: [.colorSpace: NSNull()])
        guard let cg = context.createCGImage(
            image, from: CGRect(x: 0, y: 0, width: w, height: h), format: .RGBA8,
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB)) else { throw EngineError(.internal, "still image failed") }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data as CFMutableData, "public.jpeg" as CFString, 1, nil) else {
            throw EngineError(.internal, "jpeg encoder unavailable")
        }
        CGImageDestinationAddImage(dest, cg, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw EngineError(.internal, "jpeg encoding failed") }
        return data as Data
    }
}

extension CompositionBuilder {
    /// Output frames a composition of [plan] spans (the spacer length; 0 = nothing to play).
    static func frameTotal(_ plan: RenderPlan) -> Int64 { max(0, plan.canvas.editGrid.frameIndexOf(plan.durUs)) }
}
