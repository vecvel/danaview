// OWNER: IOS-11
//
// Helpers of the IOS-11 preview session tests: a session over the grid_cuts fixture plan with
// fixture media, a recording texture registry, a fake audio session, an event listener on the
// session's EventHub, a rendered-range recorder, and async wrappers that run session calls on its
// control queue (as the glue does).

import AVFoundation
import Flutter
import XCTest

@testable import danaview_editor_engine

/// Records registrations, frame-available calls and unregistrations.
final class RecordingTextureRegistry: PreviewTextureRegistry {
    private let lock = NSLock()
    private var next: Int64 = 41
    private(set) var registered: [Int64: FlutterTexture] = [:]
    private(set) var unregistered: [Int64] = []
    private var available = 0

    func register(_ texture: FlutterTexture) -> Int64 {
        lock.lock()
        defer { lock.unlock() }
        next += 1
        registered[next] = texture
        return next
    }

    func textureFrameAvailable(_ textureId: Int64) {
        lock.lock()
        available += 1
        lock.unlock()
    }

    func unregisterTexture(_ textureId: Int64) {
        lock.lock()
        unregistered.append(textureId)
        registered[textureId] = nil
        lock.unlock()
    }

    var frameAvailableCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return available
    }

    var unregisteredIds: [Int64] {
        lock.lock()
        defer { lock.unlock() }
        return unregistered
    }
}

/// An `AVAudioSession` stand-in.
final class FakeAudioSession: AudioSessionPort {
    var category: AVAudioSession.Category = .ambient
    var mode: AVAudioSession.Mode = .default
    var categoryOptions: AVAudioSession.CategoryOptions = [.mixWithOthers]
    private(set) var activations: [Bool] = []
    private(set) var setCalls = 0

    func setCategory(_ category: AVAudioSession.Category, mode: AVAudioSession.Mode, options: AVAudioSession.CategoryOptions) throws {
        self.category = category
        self.mode = mode
        self.categoryOptions = options
        setCalls += 1
    }

    func setActive(_ active: Bool, options: AVAudioSession.SetActiveOptions) throws {
        activations.append(active)
    }
}

/// Records rendered-range boundary calls.
final class RecordingRangeHook: RenderedRangeHook {
    let ranges: [Range<Int64>]
    private let lock = NSLock()
    private var _calls: [(range: Range<Int64>, entered: Bool, k: Int64)] = []

    init(_ ranges: [Range<Int64>]) {
        self.ranges = ranges
    }

    func renderedRanges(planRev: Int64) -> [Range<Int64>] { ranges }

    func playbackCrossed(range: Range<Int64>, entered: Bool, atFrame k: Int64) {
        lock.lock()
        _calls.append((range, entered, k))
        lock.unlock()
    }

    var calls: [(range: Range<Int64>, entered: Bool, k: Int64)] {
        lock.lock()
        defer { lock.unlock() }
        return _calls
    }
}

/// Thread-safe list.
final class Locked<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T

    init(_ value: T) {
        _value = value
    }

    var value: T {
        lock.lock()
        defer { lock.unlock() }
        return _value
    }

    func mutate(_ body: (inout T) -> Void) {
        lock.lock()
        body(&_value)
        lock.unlock()
    }
}

/// One preview session over a fixture plan.
final class PreviewHarness: @unchecked Sendable {
    let hub: EventHub
    let registry = RecordingTextureRegistry()
    let audio = FakeAudioSession()
    let session: PreviewSession
    let queue = DispatchQueue(label: "test.previewControl", qos: .userInteractive)
    let events = Locked<[EngineEventMsg]>([])
    private(set) var textureId: Int64 = -1

    /// grid_cuts_30fps.json at 960×540 (maxPreviewLongSide 960).
    static func gridCutsPlan() throws -> RenderPlan { try CompositionTestSupport.plan("grid_cuts_30fps.json") }

    init(quality: PreviewQualityMsg = .full, maxLongSide: Int = 960, budget: Int = 4,
         hook: RenderedRangeHook = NoRenderedRanges(), canvas: (w: Int64, h: Int64) = (1920, 1080)) throws {
        hub = EventHub(limits: EventHub.RateLimits(clock: 0, progress: 0, recorderLevel: 0))
        var deps = PreviewSession.Dependencies(
            registry: registry, events: hub, spacerDirectory: try CompositionTestSupport.spacerDirectory())
        deps.resolveURL = { _, asset in
            let name = URL(string: asset.uri)?.lastPathComponent ?? ""
            guard let url = TestFixtures.url(.engine, "media/\(name)") else { throw EngineError(.mediaOffline, "fixture missing") }
            return url
        }
        deps.maxPreviewLongSide = maxLongSide
        deps.liveDecodeBudget = budget
        deps.renderedRanges = hook
        deps.audioSession = audio
        deps.observeLifecycle = false
        let config = PreviewConfigMsg(canvasWidth: canvas.w, canvasHeight: canvas.h, fps: 30, quality: quality, useProxies: false)
        session = try PreviewSession(id: "pv_test", config: config, queue: queue, dependencies: deps)
    }

    /// Listens to the hub (main thread) and registers the texture.
    func start() async {
        let events = self.events
        await MainActor.run {
            hub.onListen(withArguments: nil, sink: PigeonEventSink<EngineEventMsg> { value in
                if let e = value as? EngineEventMsg { events.mutate { $0.append(e) } }
            })
        }
        textureId = (try? await call(timeout: 10) { (s: PreviewSession, r: @escaping EngineReply<Int64>) in
            s.registerTexture { r(.success($0)) }
        }) ?? -2
    }

    /// Runs a session call with a reply on the control queue.
    struct Timeout: Error, CustomStringConvertible {
        let what: String
        var description: String { "timed out: \(what)" }
    }

    /// Runs a session call with a reply on the control queue; fails after [timeout] s instead of
    /// hanging when the reply never comes.
    func call<T>(_ what: String = #function, line: Int = #line, timeout: TimeInterval = 20,
                 _ body: @escaping (PreviewSession, @escaping EngineReply<T>) -> Void) async throws -> T {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<T, Error>) in
            let once = Locked(false)
            let finish: (Result<T, Error>) -> Void = { r in
                var first = false
                once.mutate { done in
                    first = !done
                    done = true
                }
                if first { c.resume(with: r) }
            }
            queue.async { body(self.session) { finish($0) } }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                finish(.failure(Timeout(what: "\(what) line \(line)")))
            }
        }
    }

    /// Reads session state on the control queue.
    func onQueue<T>(_ body: @escaping (PreviewSession) -> T) -> T { queue.sync { body(session) } }

    func setPlan(_ plan: RenderPlan) async throws -> PlanAckMsg {
        let data = PlanEncoder.encode(plan)
        return try await call { s, r in s.setPlan(data, reply: r) }
    }

    func patch(_ patch: RenderPlanPatch) async throws -> PlanAckMsg {
        let data = PlanEncoder.encode(patch)
        return try await call { s, r in s.applyPatch(data, reply: r) }
    }

    func seek(frame k: Int64, offsetUs: Int64 = 0, exact: Bool = true) async throws -> SeekAckMsg {
        let t = FrameGrid(30).timeOfFrame(k) + offsetUs
        return try await call { s, r in s.seek(timeUs: t, exact: exact, reply: r) }
    }

    func play(loop: LoopMsg? = nil) async throws -> Int64 { try await call { s, r in s.play(loop: loop, reply: r) } }
    func pause() async throws -> Int64 { try await call { s, r in s.pause(reply: r) } }

    func dispose() async {
        _ = try? await call(timeout: 10) { (s: PreviewSession, r: @escaping EngineReply<Void>) in s.dispose { r(.success(())) } }
    }

    var previewEvents: [PreviewEventMsg] { events.value.compactMap { $0.kind == .preview ? $0.previewEvent : nil } }
    var clocks: [ClockMsg] { events.value.compactMap { $0.kind == .clock ? $0.clock : nil } }

    /// Waits until [condition] holds (polling every 5 ms) or [timeout] passes; returns whether it held.
    @discardableResult
    static func wait(_ timeout: TimeInterval, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return condition()
    }

    // MARK: Frame checks

    /// Source frame shown by [layer] (constant-rate source at [fps]; ARCH §11.5).
    static func displayedSourceFrame(_ layer: EvaluatedLayer, fps: Int) -> Int {
        Int(((layer.sourceUs! + 500) * Double(fps) / 1_000_000 + 1e-9).rounded(.down))
    }

    static let baseRegion = FrameBarcodeRegion(x: 0, y: 0, width: 960, height: 540)
    static let pipRegion = FrameBarcodeRegion(x: 560, y: 45, width: 320, height: 180)

    /// Problems of a 960×540 grid_cuts frame claimed to be output frame [k] (empty: correct).
    static func check(_ pb: CVPixelBuffer, k: Int64, plan: RenderPlan, checkPip: Bool = true) -> [String] {
        var problems: [String] = []
        let layers = ParamSnapshot(plan: plan).evaluate(atFrame: k)
        if DVRenderSession.frameIndex(of: pb) != k { problems.append("frame \(k): stamp \(String(describing: DVRenderSession.frameIndex(of: pb)))") }
        if let base = layers.first(where: { $0.seq == 0 }) {
            let want = displayedSourceFrame(base, fps: 30)
            let got = CompositorTestSupport.barcode(pb, region: baseRegion)
            if got != want { problems.append("frame \(k): base \(String(describing: got)) != \(want)") }
        }
        if checkPip, let pip = layers.first(where: { $0.seq == 1 }) {
            let want = displayedSourceFrame(pip, fps: 25)
            let got = CompositorTestSupport.barcode(pb, region: pipRegion)
            if got != want { problems.append("frame \(k): PiP \(String(describing: got)) != \(want)") }
        }
        return problems
    }
}
