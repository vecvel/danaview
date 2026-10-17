// OWNER: ENG-07
//
// Native rate limits and ordering of the multiplexed event stream (ARCH §12.6): clock <= 10 Hz,
// progress <= 4 Hz, recorder levels <= 20 Hz, state changes pass at once, coalesced samples are
// delivered when the interval ends, terminal events flush pending samples and end the job, events
// before `listen` are replayed. Uses a fake clock and scheduler.

import Flutter
import XCTest

@testable import danaview_editor_engine

final class EventHubTests: XCTestCase {
    private var time: TimeInterval = 0
    private var timers: [(due: TimeInterval, work: () -> Void)] = []
    private var delivered: [EngineEventMsg] = []
    private var hub: EventHub!

    override func setUp() {
        time = 0
        timers = []
        delivered = []
        hub = EventHub(now: { [unowned self] in self.time }, schedule: { [unowned self] delay, work in
            self.timers.append((self.time + delay, work))
        })
    }

    private func listen() {
        hub.onListen(withArguments: nil, sink: PigeonEventSink<EngineEventMsg> { [unowned self] value in
            if let event = value as? EngineEventMsg { self.delivered.append(event) }
        })
    }

    /// Advances the fake clock to [t] and runs due timers.
    private func advance(to t: TimeInterval) {
        time = t
        let due = timers.filter { $0.due <= t + 1e-9 }
        timers.removeAll { $0.due <= t + 1e-9 }
        due.forEach { $0.work() }
    }

    private func clock(_ us: Int64, seq: Int64 = 1, playing: Bool = true) -> ClockMsg {
        ClockMsg(timeUs: us, playing: playing, rate: 1, seq: seq)
    }

    func testClockIsLimitedToTenHertzAndKeepsTheLatestSample() {
        listen()
        for (i, t) in [0.0, 0.02, 0.04, 0.06].enumerated() {
            advance(to: t)
            hub.emitClock(sessionId: "s1", clock(Int64(i) * 1000))
        }
        XCTAssertEqual(delivered.compactMap(\.clock?.timeUs), [0])
        advance(to: 0.1)
        XCTAssertEqual(delivered.compactMap(\.clock?.timeUs), [0, 3000])
        // Nothing pending: the next sample after the interval passes at once.
        advance(to: 0.25)
        hub.emitClock(sessionId: "s1", clock(9000))
        XCTAssertEqual(delivered.compactMap(\.clock?.timeUs), [0, 3000, 9000])
    }

    func testClockStateChangesPassAtOnce() {
        listen()
        hub.emitClock(sessionId: "s1", clock(0, seq: 1))
        advance(to: 0.01)
        hub.emitClock(sessionId: "s1", clock(100, seq: 2))
        advance(to: 0.02)
        hub.emitClock(sessionId: "s1", clock(200, seq: 2, playing: false))
        XCTAssertEqual(delivered.compactMap(\.clock?.timeUs), [0, 100, 200])
    }

    func testRoutesAreLimitedIndependently() {
        listen()
        hub.emitClock(sessionId: "s1", clock(0))
        hub.emitClock(sessionId: "s2", clock(0))
        hub.emitProgress(jobId: "j1", 0.1)
        hub.emitProgress(jobId: "j2", 0.1)
        XCTAssertEqual(delivered.count, 4)
    }

    func testProgressIsLimitedToFourHertzAndCompletionPassesAtOnce() {
        listen()
        hub.emitProgress(jobId: "j1", 0.1)
        advance(to: 0.1)
        hub.emitProgress(jobId: "j1", 0.2)
        advance(to: 0.2)
        hub.emitProgress(jobId: "j1", 0.3)
        XCTAssertEqual(delivered.compactMap(\.progress), [0.1])
        advance(to: 0.25)
        XCTAssertEqual(delivered.compactMap(\.progress), [0.1, 0.3])
        advance(to: 0.3)
        hub.emitProgress(jobId: "j1", 1.0)
        XCTAssertEqual(delivered.compactMap(\.progress), [0.1, 0.3, 1.0])
        hub.emitProgress(jobId: "j1", 7)
        XCTAssertEqual(delivered.last?.progress, 1.0, "progress is clamped to 0...1")
    }

    func testExportPhaseChangesPassAtOnce() {
        listen()
        func progress(_ phase: ExportPhaseMsg, _ fraction: Double, paused: Bool = false) -> ExportProgressMsg {
            ExportProgressMsg(
                phase: phase, fraction: fraction, framesDone: 0, framesTotal: 100, backgrounded: paused,
                pausedInBackground: paused, warnings: [])
        }
        hub.emitExportProgress(jobId: "e1", progress(.preparing, 0))
        advance(to: 0.05)
        hub.emitExportProgress(jobId: "e1", progress(.rendering, 0.01))
        advance(to: 0.06)
        hub.emitExportProgress(jobId: "e1", progress(.rendering, 0.02))
        advance(to: 0.07)
        hub.emitExportProgress(jobId: "e1", progress(.rendering, 0.03, paused: true))
        XCTAssertEqual(delivered.compactMap(\.exportProgress?.fraction), [0, 0.01, 0.03])
    }

    func testRecorderLevelsAreLimitedToTwentyHertz() {
        listen()
        for i in 0..<10 {
            advance(to: Double(i) * 0.01)
            hub.emitRecorderLevel(recordingId: "r1", Double(i) / 10)
        }
        advance(to: 0.2)
        // 0.0 at t=0; 0.1...0.4 coalesced and 0.4 flushed at t=0.05; 0.5...0.9 coalesced and 0.9
        // flushed at t=0.10.
        XCTAssertEqual(delivered.compactMap(\.recorderLevel), [0.0, 0.4, 0.9])
    }

    func testTerminalEventsFlushPendingSamplesFirstAndEndTheJob() {
        listen()
        hub.emitProgress(jobId: "j1", 0.1)
        advance(to: 0.05)
        hub.emitProgress(jobId: "j1", 0.5)
        hub.emitJobDone(jobId: "j1", JobResultMsg(kind: .waveform))
        XCTAssertEqual(delivered.map(\.kind), [.progress, .progress, .jobDone])
        XCTAssertEqual(delivered[1].progress, 0.5)
        // Late events of the ended job are dropped, and the scheduled flush has nothing to send.
        hub.emitProgress(jobId: "j1", 0.9)
        hub.emitJobFailure(jobId: "j1", EngineError.cancelled)
        advance(to: 1)
        XCTAssertEqual(delivered.count, 3)
    }

    func testSessionFailuresAreNotTerminal() {
        listen()
        hub.emitSessionFailure(sessionId: "s1", EngineError(.decodeFailed, "x", retryable: true))
        hub.emitClock(sessionId: "s1", clock(0))
        XCTAssertEqual(delivered.map(\.kind), [.failure, .clock])
        XCTAssertEqual(delivered[0].failure?.code, "decodeFailed")
        XCTAssertNil(delivered[0].jobId)
    }

    func testEventsBeforeListenAreReplayedInOrder() {
        hub.emitSignal(SignalMsg(kind: .memoryWarning))
        hub.emitJobDone(jobId: "j1", JobResultMsg(kind: .freeze))
        hub.emitLeaseExpiring(leaseId: "lease-1")
        XCTAssertEqual(hub.backlogCount, 3)
        listen()
        XCTAssertEqual(delivered.map(\.kind), [.signal, .jobDone, .leaseExpiring])
        XCTAssertEqual(hub.backlogCount, 0)
        hub.onCancel(withArguments: nil)
        hub.emitDrop(DropMsg(items: [], x: 1, y: 2))
        XCTAssertEqual(hub.backlogCount, 1)
    }

    func testBacklogIsBounded() {
        for i in 0..<(EventHub.maxBacklog + 10) {
            hub.emitLeaseExpiring(leaseId: "lease-\(i)")
        }
        XCTAssertEqual(hub.backlogCount, EventHub.maxBacklog)
        listen()
        XCTAssertEqual(delivered.first?.jobId, "lease-10")
    }

    func testEmitFromAnyThreadDeliversOnMain() {
        let real = EventHub()
        let done = expectation(description: "event")
        var onMain = false
        real.onListen(withArguments: nil, sink: PigeonEventSink<EngineEventMsg> { _ in
            onMain = Thread.isMainThread
            done.fulfill()
        })
        DispatchQueue.global().async { real.emitSignal(SignalMsg(kind: .thermal, thermalLevel: .serious)) }
        wait(for: [done], timeout: 5)
        XCTAssertTrue(onMain)
    }
}
