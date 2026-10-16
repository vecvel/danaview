// OWNER: FIX-IOS-AUDIOSESSION
//
// AudioSessionCoordinator while a voice recording runs (FIX-IOS-AUDIOSESSION, ARCH §13.2, §15):
// pressing play during a take keeps `.playAndRecord` (only activates the session) and does not
// save the recorder's configuration as the one to restore; when the take ends the coordinator
// switches to playback, and a dispose during the take restores the pre-play configuration once
// the take is over. The last test runs the real VoiceRecorder over a fake session that posts the
// category-change route notification like iOS does: play during the take keeps capturing.

import AVFoundation
import XCTest

@testable import danaview_editor_engine

/// A session fake that records calls and posts `routeChangeNotification(.categoryChange)` on
/// [center] whenever the category changes, the way AVAudioSession does; it also serves as the
/// recorder's session so recorder and preview share one category.
private final class SharedFakeSession: AudioSessionPort, RecorderAudioSession {
    private let lock = NSLock()
    private var _category: AVAudioSession.Category = .ambient
    private var _mode: AVAudioSession.Mode = .default
    private var _options: AVAudioSession.CategoryOptions = [.mixWithOthers]
    private var _setCalls: [AVAudioSession.Category] = []
    private var _activations: [Bool] = []
    let center: NotificationCenter

    init(center: NotificationCenter = NotificationCenter()) {
        self.center = center
    }

    var category: AVAudioSession.Category { locked { _category } }
    var mode: AVAudioSession.Mode { locked { _mode } }
    var categoryOptions: AVAudioSession.CategoryOptions { locked { _options } }
    var setCalls: [AVAudioSession.Category] { locked { _setCalls } }
    var activations: [Bool] { locked { _activations } }

    func setCategory(_ category: AVAudioSession.Category, mode: AVAudioSession.Mode, options: AVAudioSession.CategoryOptions) throws {
        locked {
            _category = category
            _mode = mode
            _options = options
            _setCalls.append(category)
        }
        center.post(
            name: AVAudioSession.routeChangeNotification, object: AVAudioSession.sharedInstance(),
            userInfo: [AVAudioSessionRouteChangeReasonKey: AVAudioSession.RouteChangeReason.categoryChange.rawValue])
    }

    func setActive(_ active: Bool, options: AVAudioSession.SetActiveOptions) throws {
        locked { _activations.append(active) }
    }

    /// Sets the state without a recorded call (what the recorder's own restore leaves behind).
    func force(_ category: AVAudioSession.Category, _ mode: AVAudioSession.Mode, _ options: AVAudioSession.CategoryOptions = []) {
        locked {
            _category = category
            _mode = mode
            _options = options
        }
    }

    // RecorderAudioSession
    func snapshot() -> AudioSessionCoordinator.Saved {
        locked { AudioSessionCoordinator.Saved(category: _category, mode: _mode, options: _options) }
    }

    func configureForRecording() throws {
        try setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothHFP])
    }

    func restore(_ snapshot: AudioSessionCoordinator.Saved) {
        try? setCategory(snapshot.category, mode: snapshot.mode, options: snapshot.options)
    }

    func allowsRecording() -> Bool { category == .playAndRecord || category == .record }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

/// A sine microphone (48 kHz mono Float32).
private final class SineInput: RecorderInput {
    var onInterruption: ((RecordingInterruptionMsg) -> Void)?
    let inputLatency: TimeInterval = 0.005
    private let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
    private let lock = NSLock()
    private var deliver: ((AVAudioPCMBuffer, AVAudioTime) -> Void)?
    private var phase: Double = 0

    func start(_ onBuffer: @escaping (AVAudioPCMBuffer, AVAudioTime) -> Void) throws -> AVAudioFormat {
        lock.lock()
        deliver = onBuffer
        lock.unlock()
        return format
    }

    func stop() {
        lock.lock()
        deliver = nil
        lock.unlock()
    }

    /// Pushes [seconds] of a 1 kHz sine; returns false when the input was stopped.
    @discardableResult
    func push(seconds: Double) -> Bool {
        var remaining = Int(seconds * format.sampleRate)
        while remaining > 0 {
            lock.lock()
            let deliver = self.deliver
            lock.unlock()
            guard let deliver = deliver else { return false }
            let n = min(1024, remaining)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n))!
            buffer.frameLength = AVAudioFrameCount(n)
            for i in 0..<n {
                buffer.floatChannelData![0][i] = 0.5 * Float(sin(phase))
                phase += 2 * .pi * 1000 / format.sampleRate
            }
            deliver(buffer, AVAudioTime(hostTime: mach_absolute_time()))
            remaining -= n
        }
        return true
    }
}

final class AudioSessionRecordingTests: XCTestCase {
    private var center: NotificationCenter!
    private var port: SharedFakeSession!
    private var recording = false

    override func setUp() {
        center = NotificationCenter()
        port = SharedFakeSession()
        recording = false
    }

    private func makeCoordinator() -> AudioSessionCoordinator {
        AudioSessionCoordinator(port: port, isRecording: { [unowned self] in self.recording }, notifications: center)
    }

    /// The recorder's start: `.playAndRecord`, recording flag on.
    private func recorderStarts() {
        try? port.configureForRecording()
        recording = true
        center.post(name: VoiceRecorder.activityDidChange, object: nil, userInfo: ["active": true])
    }

    /// The recorder's end: its snapshot restored first, then the inactive notification.
    private func recorderEnds(restoring saved: AudioSessionCoordinator.Saved) {
        port.force(saved.category, saved.mode, saved.options)
        recording = false
        center.post(name: VoiceRecorder.activityDidChange, object: nil, userInfo: ["active": false])
    }

    func testPlayDuringRecordingKeepsPlayAndRecordAndOnlyActivates() {
        let original = port.snapshot()
        recorderStarts()
        let calls = port.setCalls.count
        let c = makeCoordinator()
        c.beginPlayback()
        XCTAssertEqual(port.category, .playAndRecord, "the microphone keeps capturing")
        XCTAssertEqual(port.setCalls.count, calls, "no category change while recording")
        XCTAssertEqual(port.activations, [true])
        XCTAssertNil(c.savedConfiguration, "the recorder's configuration is not saved")
        XCTAssertTrue(c.isWaitingForRecordingEnd)
        c.beginPlayback()
        XCTAssertEqual(port.setCalls.count, calls)

        // A notification that a (second) take is active changes nothing.
        center.post(name: VoiceRecorder.activityDidChange, object: nil, userInfo: ["active": true])
        XCTAssertEqual(port.category, .playAndRecord)

        // The take ends: playback now, and the configuration the recorder restored is saved.
        recorderEnds(restoring: original)
        XCTAssertEqual(port.category, .playback)
        XCTAssertEqual(port.mode, .moviePlayback)
        XCTAssertEqual(c.savedConfiguration, original)
        XCTAssertFalse(c.isWaitingForRecordingEnd)

        c.restore()
        XCTAssertEqual(port.snapshot(), original)
    }

    func testPlayBeforeAndDuringRecordingRestoresTheOriginalAfterStop() {
        let original = port.snapshot()
        let c = makeCoordinator()
        c.beginPlayback()
        XCTAssertEqual(port.category, .playback)
        let beforeTake = port.snapshot()  // what the recorder snapshots
        recorderStarts()
        let calls = port.setCalls.count
        c.beginPlayback()
        XCTAssertEqual(port.category, .playAndRecord)
        XCTAssertEqual(port.setCalls.count, calls)
        XCTAssertEqual(c.savedConfiguration, original, "the pre-play configuration is kept")

        recorderEnds(restoring: beforeTake)
        XCTAssertEqual(port.category, .playback)
        XCTAssertEqual(port.setCalls.count, calls, "already in playback")
        XCTAssertEqual(c.savedConfiguration, original)

        c.restore()
        XCTAssertEqual(port.snapshot(), original)
    }

    func testDisposeDuringRecordingRestoresOnceTheRecordingEnds() {
        let original = port.snapshot()
        let c = makeCoordinator()
        c.beginPlayback()
        let beforeTake = port.snapshot()
        recorderStarts()
        let calls = port.setCalls.count
        c.restore()
        XCTAssertEqual(port.category, .playAndRecord, "dispose never stops the microphone")
        XCTAssertEqual(port.setCalls.count, calls)
        XCTAssertNil(c.savedConfiguration)

        recorderEnds(restoring: beforeTake)
        XCTAssertEqual(port.snapshot(), original, "the pre-play configuration comes back")
        XCTAssertFalse(c.isWaitingForRecordingEnd)
        let after = port.setCalls.count
        c.restore()
        recorderEnds(restoring: original)
        XCTAssertEqual(port.setCalls.count, after, "restore stays idempotent")
    }

    func testPlayOnlyDuringRecordingThenDisposeLeavesTheRecorderRestore() {
        let original = port.snapshot()
        recorderStarts()
        let c = makeCoordinator()
        c.beginPlayback()
        c.restore()
        let calls = port.setCalls.count
        recorderEnds(restoring: original)
        XCTAssertEqual(port.setCalls.count, calls, "nothing owed: the recorder's restore stands")
        XCTAssertEqual(port.snapshot(), original)
        XCTAssertFalse(c.isWaitingForRecordingEnd)
    }

    func testRecordingThatEndedBeforeTheObserverIsCaughtUp() {
        // isRecording says true at the check and false right after (the take ended in between).
        var answers = [true]
        let c = AudioSessionCoordinator(
            port: port, isRecording: { answers.isEmpty ? false : answers.removeFirst() }, notifications: center)
        c.beginPlayback()
        XCTAssertEqual(port.category, .playback)
        XCTAssertFalse(c.isWaitingForRecordingEnd)
    }

    /// The real recorder: a preview that starts playing mid-take keeps the take going (no
    /// interruption, every pushed second is in the file), and playback follows after stop.
    func testRealRecorderKeepsCapturingWhenPlayIsPressed() throws {
        let fixture = try RecordingEngineFixture()
        defer { fixture.remove() }
        let shared = SharedFakeSession()
        let original = shared.snapshot()
        let input = SineInput()
        let recorder = VoiceRecorder(
            context: fixture.context, input: { input }, session: shared,
            permission: { .granted }, notifications: shared.center)
        // The production defaults: VoiceRecorder.isRecording and the default center.
        let c = AudioSessionCoordinator(port: shared)
        let output = fixture.roots.support.appendingPathComponent("projects/p1/assets/recordings/take1.wav")

        let id: String = try awaitReply(self) { recorder.start(outputURL: output, reply: $0) }
        XCTAssertEqual(shared.category, .playAndRecord)
        XCTAssertTrue(input.push(seconds: 0.5))
        c.beginPlayback()
        XCTAssertEqual(shared.category, .playAndRecord)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertTrue(input.push(seconds: 0.5), "the input is still running")
        XCTAssertFalse(fixture.events.contains { $0.kind == .interruption && $0.jobId == id })

        let asset: RecordedAssetMsg = try awaitReply(self) { recorder.stop(recordingId: id, reply: $0) }
        XCTAssertEqual(Double(asset.durationUs), 1_000_000, accuracy: 30_000)
        XCTAssertFalse(fixture.events.contains { $0.kind == .interruption && $0.jobId == id })

        // After stop: the recorder restored the original, then the coordinator switches to playback.
        XCTAssertTrue(spin(until: { shared.category == .playback }))
        XCTAssertEqual(shared.mode, .moviePlayback)
        XCTAssertEqual(c.savedConfiguration, original)
        c.restore()
        XCTAssertEqual(shared.snapshot(), original)
    }
}
