// OWNER: IOS-14
//
// Voice recorder (BUILD_PLAN IOS-14). An injected input delivers synthesized microphone buffers
// (44.1 kHz stereo Float32, the shape AVAudioEngine hands over on many routes), so the tests
// assert: the WAV is PCM s16 LE 48 kHz mono with consistent sizes and the expected amplitude;
// levels stream at 20 Hz with the expected value; an interruption (or a removed device) stops the
// recording, keeps a valid file, emits the event, and `stop` still returns the asset; the header is
// valid mid-recording; the previous audio session is restored; cancel deletes; start latency is
// measured from the start request to the first captured sample. The real AVAudioEngine path runs
// when the simulator has microphone access (granted with `xcrun simctl privacy … grant microphone`).
//
// Deferred (no device available, D-43): the iPhone 8 / iOS 16.7 AVAudioSession permission flow and
// the < 100 ms device start latency (QA-00 scenario 13 records them).

import AVFoundation
import XCTest

@testable import danaview_editor_engine

/// Synthesized microphone input.
private final class FakeRecorderInput: RecorderInput {
    var onInterruption: ((RecordingInterruptionMsg) -> Void)?
    let format: AVAudioFormat
    var inputLatency: TimeInterval = 0.005
    private(set) var started = false
    private(set) var stopped = false
    private var deliver: ((AVAudioPCMBuffer, AVAudioTime) -> Void)?
    private var phase: Double = 0

    init(sampleRate: Double = 44_100, channels: AVAudioChannelCount = 2) {
        format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channels)!
    }

    func start(_ onBuffer: @escaping (AVAudioPCMBuffer, AVAudioTime) -> Void) throws -> AVAudioFormat {
        started = true
        deliver = onBuffer
        return format
    }

    func stop() {
        stopped = true
        deliver = nil
    }

    /// Pushes [seconds] of a [frequency] Hz sine of [amplitude] in 1024-frame buffers.
    func push(seconds: Double, frequency: Double = 1000, amplitude: Float = 0.5, hostTime: UInt64? = nil) {
        var remaining = Int(seconds * format.sampleRate)
        var first = true
        while remaining > 0, let deliver = deliver {
            let n = min(1024, remaining)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n))!
            buffer.frameLength = AVAudioFrameCount(n)
            for i in 0..<n {
                let v = amplitude * Float(sin(phase))
                for c in 0..<Int(format.channelCount) { buffer.floatChannelData![c][i] = v }
                phase += 2 * .pi * frequency / format.sampleRate
            }
            let time = first && hostTime != nil
                ? AVAudioTime(hostTime: hostTime!) : AVAudioTime(hostTime: mach_absolute_time())
            first = false
            deliver(buffer, time)
            remaining -= n
        }
    }
}

/// Session fake recording configure/restore.
private final class FakeRecorderSession: RecorderAudioSession {
    var configured = 0
    var restored: [String] = []
    var current = "ambient"
    var failConfigure = false

    func snapshot() -> String { current }

    func configureForRecording() throws {
        if failConfigure { throw EngineError(.interrupted, "session refused") }
        configured += 1
        current = "playAndRecord"
    }

    func restore(_ snapshot: String) {
        restored.append(snapshot)
        current = snapshot
    }
}

/// Parsed 44-byte WAV header.
private struct WavInfo {
    let format: UInt16, channels: UInt16, sampleRate: UInt32, byteRate: UInt32, blockAlign: UInt16, bits: UInt16
    let riffSize: UInt32, dataSize: UInt32, fileSize: Int
    let samples: [Int16]

    init(_ url: URL) throws {
        let data = try Data(contentsOf: url)
        XCTAssertGreaterThanOrEqual(data.count, 44)
        func u32(_ o: Int) -> UInt32 { data.subdata(in: o..<o + 4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian }
        func u16(_ o: Int) -> UInt16 { data.subdata(in: o..<o + 2).withUnsafeBytes { $0.loadUnaligned(as: UInt16.self) }.littleEndian }
        XCTAssertEqual(String(data: data.subdata(in: 0..<4), encoding: .ascii), "RIFF")
        XCTAssertEqual(String(data: data.subdata(in: 8..<12), encoding: .ascii), "WAVE")
        XCTAssertEqual(String(data: data.subdata(in: 12..<16), encoding: .ascii), "fmt ")
        XCTAssertEqual(String(data: data.subdata(in: 36..<40), encoding: .ascii), "data")
        riffSize = u32(4)
        format = u16(20)
        channels = u16(22)
        sampleRate = u32(24)
        byteRate = u32(28)
        blockAlign = u16(32)
        bits = u16(34)
        dataSize = u32(40)
        fileSize = data.count
        samples = data.subdata(in: 44..<data.count).withUnsafeBytes { raw in
            Array(raw.bindMemory(to: Int16.self)).map { Int16(littleEndian: $0) }
        }
    }

    /// A valid PCM s16 48 kHz mono file whose header sizes match its length.
    func assertValid(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(format, 1, file: file, line: line)
        XCTAssertEqual(channels, 1, file: file, line: line)
        XCTAssertEqual(sampleRate, 48_000, file: file, line: line)
        XCTAssertEqual(byteRate, 96_000, file: file, line: line)
        XCTAssertEqual(blockAlign, 2, file: file, line: line)
        XCTAssertEqual(bits, 16, file: file, line: line)
        XCTAssertEqual(Int(dataSize), fileSize - 44, file: file, line: line)
        XCTAssertEqual(riffSize, dataSize + 36, file: file, line: line)
    }
}

final class VoiceRecorderTests: XCTestCase {
    private var fixture: RecordingEngineFixture!
    private var input: FakeRecorderInput!
    private var session: FakeRecorderSession!
    private var center: NotificationCenter!
    private var permission: Permissions.RecordPermission = .granted
    private var recorder: VoiceRecorder!

    override func setUpWithError() throws {
        fixture = try RecordingEngineFixture()
        input = FakeRecorderInput()
        session = FakeRecorderSession()
        center = NotificationCenter()
        permission = .granted
        recorder = makeRecorder()
    }

    override func tearDown() {
        fixture.remove()
    }

    private func makeRecorder(now: @escaping () -> UInt64 = { mach_absolute_time() }) -> VoiceRecorder {
        VoiceRecorder(
            context: fixture.context, input: { [unowned self] in self.input }, session: session,
            permission: { [unowned self] in self.permission }, notifications: center, now: now)
    }

    private var output: URL {
        fixture.roots.support.appendingPathComponent("projects/p1/assets/recordings/take1.wav")
    }

    private func start() throws -> String {
        try awaitReply(self) { recorder.start(outputURL: output, reply: $0) }
    }

    private func stop(_ id: String) throws -> RecordedAssetMsg {
        try awaitReply(self) { recorder.stop(recordingId: id, reply: $0) }
    }

    // MARK: Format and levels

    func testWavIsPcm16Mono48kWithTheInputSignal() throws {
        let id = try start()
        XCTAssertTrue(id.hasPrefix("rec-"))
        XCTAssertTrue(input.started)
        XCTAssertEqual(session.configured, 1)
        XCTAssertTrue(VoiceRecorder.isRecording)
        input.push(seconds: 1.0, amplitude: 0.5)
        let asset = try stop(id)
        XCTAssertTrue(input.stopped)
        XCTAssertFalse(VoiceRecorder.isRecording)
        XCTAssertEqual(asset.path, output.path)

        let wav = try WavInfo(output)
        wav.assertValid()
        // 1 s at 44.1 kHz resampled to 48 kHz (the converter may hold back its filter tail).
        XCTAssertEqual(Double(wav.samples.count), 48_000, accuracy: 200)
        XCTAssertEqual(Double(asset.durationUs), Double(wav.samples.count) * 1e6 / 48_000, accuracy: 25)
        // Stereo downmix of identical channels keeps the amplitude: peak ≈ 0.5 · 32767.
        let peak = wav.samples.dropFirst(1000).map { abs(Int($0)) }.max() ?? 0
        XCTAssertEqual(Double(peak), 16_383, accuracy: 900)
        XCTAssertEqual(session.restored, ["ambient"], "previous session restored")
    }

    func testLevelsStreamAtTwentyHertz() throws {
        let id = try start()
        input.push(seconds: 1.0, amplitude: 0.5)
        _ = try stop(id)
        XCTAssertTrue(spin(until: { self.fixture.events.filter { $0.kind == .recorderLevel }.count >= 2 }))
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))  // let the hub flush its coalesced sample
        let levels = fixture.events.filter { $0.kind == .recorderLevel && $0.jobId == id }.compactMap(\.recorderLevel)
        // 48 000 samples / 2 400 per window = 20 windows (the hub passes all of them: they are
        // computed on audio time, not wall time, so a few may be coalesced by the 20 Hz limit).
        XCTAssertGreaterThanOrEqual(levels.count, 2)
        XCTAssertLessThanOrEqual(levels.count, 20)
        // Sine of amplitude 0.5: RMS 0.354 = -9.03 dBFS -> (60 - 9.03) / 60 = 0.85.
        XCTAssertEqual(levels.last ?? 0, 0.85, accuracy: 0.02)
        XCTAssertEqual(VoiceRecorder.level(rms: 0), 0)
        XCTAssertEqual(VoiceRecorder.level(rms: 1), 1)
        XCTAssertEqual(VoiceRecorder.level(rms: 0.0001), 0)
    }

    func testHeaderIsValidWhileRecording() throws {
        let id = try start()
        input.push(seconds: 0.8)
        // Mid-recording (as after a crash): the header already covers at least 0.5 s.
        let mid = try WavInfo(output)
        XCTAssertEqual(mid.format, 1)
        XCTAssertGreaterThanOrEqual(mid.dataSize, 48_000)
        XCTAssertLessThanOrEqual(Int(mid.dataSize), mid.fileSize - 44)
        _ = try stop(id)
        try WavInfo(output).assertValid()
    }

    // MARK: Interruptions

    func testInterruptionKeepsAValidFileAndStopStillReturnsTheAsset() throws {
        let id = try start()
        input.push(seconds: 0.6)
        center.post(
            name: AVAudioSession.interruptionNotification, object: AVAudioSession.sharedInstance(),
            userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue])
        XCTAssertTrue(spin(until: { self.fixture.events.contains { $0.kind == .interruption } }))
        let event = try XCTUnwrap(fixture.events.first { $0.kind == .interruption })
        XCTAssertEqual(event.jobId, id)
        XCTAssertEqual(event.interruption, .interrupted)
        XCTAssertTrue(input.stopped)
        XCTAssertEqual(session.restored, ["ambient"])
        XCTAssertFalse(VoiceRecorder.isRecording)

        // Buffers after the interruption are not written.
        input.push(seconds: 0.5)
        let asset = try stop(id)
        let wav = try WavInfo(output)
        wav.assertValid()
        XCTAssertEqual(Double(wav.samples.count), 0.6 * 48_000, accuracy: 200)
        XCTAssertEqual(Double(asset.durationUs), 600_000, accuracy: 5_000)
        // The asset is handed out once; a later stop of the same id is unknown.
        XCTAssertNotNil(awaitFailure(self) { recorder.stop(recordingId: id, reply: $0) })
    }

    func testRouteChangesStopAndKeepTheFile() throws {
        for (reason, expected) in [
            (AVAudioSession.RouteChangeReason.oldDeviceUnavailable, RecordingInterruptionMsg.deviceRemoved),
            (.newDeviceAvailable, .routeChanged),
        ] {
            let id = try start()
            input.push(seconds: 0.2)
            // Our own category change does not stop the recording.
            center.post(
                name: AVAudioSession.routeChangeNotification, object: AVAudioSession.sharedInstance(),
                userInfo: [AVAudioSessionRouteChangeReasonKey: AVAudioSession.RouteChangeReason.categoryChange.rawValue])
            center.post(
                name: AVAudioSession.routeChangeNotification, object: AVAudioSession.sharedInstance(),
                userInfo: [AVAudioSessionRouteChangeReasonKey: reason.rawValue])
            XCTAssertTrue(spin(until: { self.fixture.events.contains { $0.kind == .interruption && $0.jobId == id } }))
            XCTAssertEqual(fixture.events.first { $0.kind == .interruption && $0.jobId == id }?.interruption, expected)
            _ = try stop(id)
            try WavInfo(output).assertValid()
            input = FakeRecorderInput()
        }
    }

    func testEngineConfigurationChangeStopsAndKeepsTheFile() throws {
        let id = try start()
        input.push(seconds: 0.3)
        input.onInterruption?(.routeChanged)
        XCTAssertTrue(spin(until: { self.fixture.events.contains { $0.kind == .interruption } }))
        let asset = try stop(id)
        XCTAssertGreaterThan(asset.durationUs, 250_000)
        try WavInfo(output).assertValid()
    }

    // MARK: Lifecycle

    func testCancelDeletesTheFileAndStopAfterCancelIsCancelled() throws {
        let id = try start()
        input.push(seconds: 0.2)
        try awaitReply(self) { recorder.cancel(recordingId: id, reply: $0) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        XCTAssertEqual(session.restored, ["ambient"])
        XCTAssertEqual(awaitFailure(self) { recorder.stop(recordingId: id, reply: $0) }?.code, .cancelled)
        // Cancelling again is fine.
        try awaitReply(self) { recorder.cancel(recordingId: id, reply: $0) }
    }

    func testOneRecordingAtATimeAndPermissionRequired() throws {
        let id = try start()
        XCTAssertEqual(awaitFailure(self) { recorder.start(outputURL: output, reply: $0) }?.code, .busy)
        _ = try stop(id)

        permission = .denied
        XCTAssertEqual(awaitFailure(self) { recorder.start(outputURL: output, reply: $0) }?.code, .permissionDenied)
        XCTAssertEqual(try awaitReply(self) { recorder.permission(reply: $0) }, .permanentlyDenied)
        // Determined permissions answer without prompting.
        XCTAssertEqual(try awaitReply(self) { recorder.requestPermission(reply: $0) }, .permanentlyDenied)
        permission = .granted
        XCTAssertEqual(try awaitReply(self) { recorder.requestPermission(reply: $0) }, .granted)
    }

    func testFailedSessionConfigurationRestoresAndLeavesNoFile() throws {
        session.failConfigure = true
        XCTAssertEqual(awaitFailure(self) { recorder.start(outputURL: output, reply: $0) }?.code, .interrupted)
        XCTAssertEqual(session.restored, ["ambient"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        XCTAssertFalse(VoiceRecorder.isRecording)
    }

    func testStartLatencyIsMeasuredToTheFirstCapturedSample() throws {
        let t0 = mach_absolute_time()
        recorder = makeRecorder(now: { t0 })
        let id = try start()
        // First sample captured 30 ms after the start request; the route adds 5 ms input latency.
        input.inputLatency = 0.005
        input.push(seconds: 0.1, hostTime: t0 + AVAudioTime.hostTime(forSeconds: 0.030))
        let asset = try stop(id)
        XCTAssertEqual(Double(asset.startLatencyUs), 25_000, accuracy: 500)
    }

    func testActivityNotificationForThePreview() throws {
        var states: [Bool] = []
        let token = NotificationCenter.default.addObserver(forName: VoiceRecorder.activityDidChange, object: nil, queue: nil) {
            states.append($0.userInfo?["active"] as? Bool ?? false)
        }
        defer { NotificationCenter.default.removeObserver(token) }
        let id = try start()
        _ = try stop(id)
        XCTAssertTrue(spin(until: { states.count == 2 }))
        XCTAssertEqual(states, [true, false])
    }

    // MARK: Real system pieces

    func testSharedSessionIsRestoredAfterRecordingConfiguration() throws {
        let shared = SharedRecorderAudioSession()
        try AVAudioSession.sharedInstance().setCategory(.ambient, mode: .moviePlayback, options: [.mixWithOthers])
        let before = shared.snapshot()
        do {
            try shared.configureForRecording()
        } catch {
            throw XCTSkip("the simulator refused .playAndRecord: \(error)")
        }
        XCTAssertEqual(AVAudioSession.sharedInstance().category, .playAndRecord)
        XCTAssertTrue(AVAudioSession.sharedInstance().categoryOptions.contains(.defaultToSpeaker))
        XCTAssertTrue(AVAudioSession.sharedInstance().categoryOptions.contains(.allowBluetoothHFP))
        shared.restore(before)
        XCTAssertEqual(shared.snapshot(), before)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    func testRealAudioEngineRecordingWhenTheMicrophoneIsGranted() throws {
        guard Permissions.microphoneStatus() == .granted else {
            throw XCTSkip("microphone not granted to the test host (xcrun simctl privacy <device> grant microphone <bundle>)")
        }
        let real = VoiceRecorder(context: fixture.context)
        let id: String
        do {
            id = try awaitReply(self) { real.start(outputURL: output, reply: $0) }
        } catch {
            throw XCTSkip("no microphone input on this simulator host: \(error)")
        }
        RunLoop.main.run(until: Date().addingTimeInterval(1.2))
        let asset = try awaitReply(self) { real.stop(recordingId: id, reply: $0) }
        try WavInfo(output).assertValid()
        XCTAssertGreaterThan(asset.durationUs, 500_000)
        XCTAssertLessThan(asset.startLatencyUs, 1_000_000, "simulator; the device budget is < 100 ms (deferred)")
        print("IOS-14 simulator recording: \(asset.durationUs) us, start latency \(asset.startLatencyUs) us")
    }
}
