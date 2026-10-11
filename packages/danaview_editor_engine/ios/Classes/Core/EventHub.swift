// OWNER: ENG-07 (frozen with the glue by ENG-06)
//
// The single multiplexed engine event stream (ARCH §12.6, Pigeon `@EventChannelApi`
// `EngineEventsApi.engineEvents`; V-N8: the generated Swift `EngineEventsStreamHandler` registers
// and delivers on iOS, proven by RunnerTests/Glue/EventChannelGlueTests).
//
// Services call the typed `emit…` helpers from any thread. Everything else happens on the main
// thread: events are delivered on main with the native rate limits of ARCH §12.6, the same rules
// event_router.dart enforces again in Dart:
//
// - Sample kinds are rate limited per route (sessionId or jobId) and kind: clock <= 10 Hz,
//   job and export progress <= 4 Hz, recorder levels <= 20 Hz. A sample that changes state passes
//   at once (clock: seq, playing or rate; export: phase, backgrounded, pausedInBackground or
//   warnings; progress: reaching 1). Other samples inside the interval are coalesced: the latest is
//   kept and delivered when the interval ends, so the last sample is never lost.
// - Every other kind passes at once, after any pending sample of the same route (order is kept).
// - A job route ends with its first terminal event (`jobDone`, or `failure` with a jobId); later
//   events for that job id are dropped.
// - Events emitted before Dart listens (or between a hot restart's cancel and listen) are kept in a
//   bounded backlog and replayed to the next listener.

import Flutter
import Foundation
import QuartzCore

/// Engine event hub: the native end of `EngineEventsApi.engineEvents`.
final class EventHub: EngineEventsStreamHandler {
    /// Minimum intervals between delivered samples of one route (ARCH §12.6).
    struct RateLimits {
        var clock: TimeInterval = 0.1
        var progress: TimeInterval = 0.25
        var recorderLevel: TimeInterval = 0.05
    }

    /// Runs `work` on the main thread after `delay` seconds.
    typealias Scheduler = (_ delay: TimeInterval, _ work: @escaping () -> Void) -> Void

    /// Events kept while nobody listens.
    static let maxBacklog = 512
    /// Ended job ids remembered to drop late events.
    static let maxEndedJobs = 256

    let limits: RateLimits
    private let now: () -> TimeInterval
    private let schedule: Scheduler

    // Main-thread state.
    private var sink: PigeonEventSink<EngineEventMsg>?
    private var backlog: [EngineEventMsg] = []
    private var samples: [SampleKey: SampleState] = [:]
    private var endedJobs: [String] = []
    private var endedJobSet: Set<String> = []

    init(
        limits: RateLimits = RateLimits(),
        now: @escaping () -> TimeInterval = { CACurrentMediaTime() },
        schedule: @escaping Scheduler = { delay, work in
            DispatchQueue.main.asyncAfter(deadline: .now() + max(0, delay), execute: work)
        }
    ) {
        self.limits = limits
        self.now = now
        self.schedule = schedule
        super.init()
    }

    /// Whether Dart listens to the stream (main thread).
    var isListening: Bool { sink != nil }

    /// Events waiting for a listener (main thread; tests).
    var backlogCount: Int { backlog.count }

    // MARK: Stream handler (main thread)

    override func onListen(withArguments arguments: Any?, sink: PigeonEventSink<EngineEventMsg>) {
        self.sink = sink
        let replay = backlog
        backlog.removeAll()
        Log.debug(.events, "listen: replaying \(replay.count) events")
        for event in replay {
            sink.success(event)
        }
    }

    override func onCancel(withArguments arguments: Any?) {
        sink = nil
        Log.debug(.events, "cancel")
    }

    // MARK: Typed emitters (any thread)

    func emitClock(sessionId: String, _ clock: ClockMsg) {
        emit(EngineEventMsg(kind: .clock, sessionId: sessionId, clock: clock))
    }

    func emitPreviewEvent(sessionId: String, _ event: PreviewEventMsg) {
        emit(EngineEventMsg(kind: .preview, sessionId: sessionId, previewEvent: event))
    }

    /// A failure of preview session [sessionId] (not terminal for the session).
    func emitSessionFailure(sessionId: String, _ error: EngineError) {
        emit(EngineEventMsg(kind: .failure, sessionId: sessionId, failure: error.failureMsg))
    }

    /// Job progress in 0...1.
    func emitProgress(jobId: String, _ fraction: Double) {
        let value = fraction.isFinite ? min(1, max(0, fraction)) : 0
        emit(EngineEventMsg(kind: .progress, jobId: jobId, progress: value))
    }

    /// Terminal success of job [jobId].
    func emitJobDone(jobId: String, _ result: JobResultMsg) {
        emit(EngineEventMsg(kind: .jobDone, jobId: jobId, jobDone: result))
    }

    /// Terminal failure of job, export, recording or lease [jobId].
    func emitJobFailure(jobId: String, _ error: EngineError) {
        emit(EngineEventMsg(kind: .failure, jobId: jobId, failure: error.failureMsg))
    }

    func emitExportProgress(jobId: String, _ progress: ExportProgressMsg) {
        emit(EngineEventMsg(kind: .exportProgress, jobId: jobId, exportProgress: progress))
    }

    /// Recorder input level in 0...1.
    func emitRecorderLevel(recordingId: String, _ level: Double) {
        let value = level.isFinite ? min(1, max(0, level)) : 0
        emit(EngineEventMsg(kind: .recorderLevel, jobId: recordingId, recorderLevel: value))
    }

    func emitInterruption(recordingId: String, _ interruption: RecordingInterruptionMsg) {
        emit(EngineEventMsg(kind: .interruption, jobId: recordingId, interruption: interruption))
    }

    func emitSignal(_ signal: SignalMsg) {
        emit(EngineEventMsg(kind: .signal, signal: signal))
    }

    func emitDrop(_ drop: DropMsg) {
        emit(EngineEventMsg(kind: .drop, drop: drop))
    }

    func emitLeaseExpiring(leaseId: String) {
        emit(EngineEventMsg(kind: .leaseExpiring, jobId: leaseId))
    }

    /// Emits [event] (any thread). Delivery happens on the main thread.
    func emit(_ event: EngineEventMsg) {
        if Thread.isMainThread {
            route(event)
        } else {
            DispatchQueue.main.async { [weak self] in self?.route(event) }
        }
    }

    // MARK: Routing (main thread)

    private struct SampleKey: Hashable {
        let isJob: Bool
        let id: String
        let kind: EngineEventKindMsg
    }

    private struct SampleState {
        var lastSent: TimeInterval?
        var lastDelivered: EngineEventMsg?
        var pending: EngineEventMsg?
        var flushScheduled = false
    }

    private func route(_ event: EngineEventMsg) {
        if let jobId = event.jobId, endedJobSet.contains(jobId) {
            Log.debug(.events, "dropped \(event.kind) for an ended job")
            return
        }
        if let key = sampleKey(event), let interval = interval(for: event.kind) {
            routeSample(event, key: key, interval: interval)
            return
        }
        flushPending(isJob: event.jobId != nil, id: event.jobId ?? event.sessionId)
        deliver(event)
        if let jobId = event.jobId, isTerminal(event) {
            endJob(jobId)
        }
    }

    private func routeSample(_ event: EngineEventMsg, key: SampleKey, interval: TimeInterval) {
        var state = samples[key] ?? SampleState()
        let t = now()
        let due = state.lastSent.map { t - $0 >= interval - 1e-9 } ?? true
        if due || changesState(event, since: state.lastDelivered) {
            state.pending = nil
            state.lastSent = t
            state.lastDelivered = event
            samples[key] = state
            deliver(event)
            return
        }
        state.pending = event
        if !state.flushScheduled, let last = state.lastSent {
            state.flushScheduled = true
            let delay = max(0, last + interval - t)
            schedule(delay) { [weak self] in self?.flushScheduled(key) }
        }
        samples[key] = state
    }

    private func flushScheduled(_ key: SampleKey) {
        guard var state = samples[key] else { return }
        state.flushScheduled = false
        if let pending = state.pending {
            state.pending = nil
            state.lastSent = now()
            state.lastDelivered = pending
            samples[key] = state
            deliver(pending)
        } else {
            samples[key] = state
        }
    }

    /// Delivers pending samples of route (isJob, id) before a non-sample event of that route.
    private func flushPending(isJob: Bool, id: String?) {
        guard let id = id else { return }
        for (key, var state) in samples where key.isJob == isJob && key.id == id {
            if let pending = state.pending {
                state.pending = nil
                state.lastSent = now()
                state.lastDelivered = pending
                samples[key] = state
                deliver(pending)
            }
        }
    }

    private func endJob(_ jobId: String) {
        samples = samples.filter { !($0.key.isJob && $0.key.id == jobId) }
        endedJobs.append(jobId)
        endedJobSet.insert(jobId)
        if endedJobs.count > EventHub.maxEndedJobs {
            endedJobSet.remove(endedJobs.removeFirst())
        }
    }

    /// Forgets the session samples of [sessionId] (preview dispose).
    func releaseSession(_ sessionId: String) {
        let release = { [weak self] in
            guard let self = self else { return }
            self.flushPending(isJob: false, id: sessionId)
            self.samples = self.samples.filter { $0.key.isJob || $0.key.id != sessionId }
        }
        if Thread.isMainThread { release() } else { DispatchQueue.main.async(execute: release) }
    }

    private func deliver(_ event: EngineEventMsg) {
        if let sink = sink {
            sink.success(event)
            return
        }
        backlog.append(event)
        if backlog.count > EventHub.maxBacklog {
            backlog.removeFirst(backlog.count - EventHub.maxBacklog)
        }
    }

    private func sampleKey(_ event: EngineEventMsg) -> SampleKey? {
        switch event.kind {
        case .clock:
            guard let id = event.sessionId else { return nil }
            return SampleKey(isJob: false, id: id, kind: event.kind)
        case .progress, .exportProgress, .recorderLevel:
            guard let id = event.jobId else { return nil }
            return SampleKey(isJob: true, id: id, kind: event.kind)
        default:
            return nil
        }
    }

    private func interval(for kind: EngineEventKindMsg) -> TimeInterval? {
        switch kind {
        case .clock: return limits.clock
        case .progress, .exportProgress: return limits.progress
        case .recorderLevel: return limits.recorderLevel
        default: return nil
        }
    }

    private func changesState(_ event: EngineEventMsg, since last: EngineEventMsg?) -> Bool {
        switch event.kind {
        case .clock:
            guard let c = event.clock else { return false }
            guard let p = last?.clock else { return true }
            return c.seq != p.seq || c.playing != p.playing || c.rate != p.rate
        case .exportProgress:
            guard let e = event.exportProgress else { return false }
            guard let p = last?.exportProgress else { return true }
            return e.phase != p.phase || e.backgrounded != p.backgrounded
                || e.pausedInBackground != p.pausedInBackground || e.warnings != p.warnings
        case .progress:
            return (event.progress ?? 0) >= 1
        default:
            return false
        }
    }

    private func isTerminal(_ event: EngineEventMsg) -> Bool {
        event.kind == .jobDone || (event.kind == .failure && event.jobId != nil)
    }
}
