// OWNER: IOS-14
//
// Voice recorder (ARCH §15 'Voice recording', D-25):
// - AVAudioEngine input tap (hardware format) -> AVAudioConverter (downmix, 48 kHz Float32 mono)
//   -> WAV PCM s16 LE 48 kHz mono at the Dart path (`projects/<id>/assets/recordings/…`, checked by
//   the glue). The WAV header is rewritten about every 0.5 s of audio, so the file on disk is a
//   valid WAV at any moment (a crash or an interruption keeps everything written so far).
// - Levels: RMS of each 50 ms window (2400 samples) mapped from -60…0 dBFS to 0…1 and emitted as
//   `recorderLevel` events (20 Hz; EventHub enforces the same limit).
// - Start latency: from the moment `start` runs on the recorder queue to the capture time of the
//   first written sample (buffer host time minus the session's input latency). Dart aligns the
//   recording on the timeline with it (UX-34).
// - Session: `.playAndRecord` + `.defaultToSpeaker` + Bluetooth HFP, preferred 48 kHz; the previous
//   category/mode/options are restored when the recording ends (stop, cancel or interruption).
// - Interruptions (`AVAudioSession.interruptionNotification` began, media services reset), route
//   changes (new device -> routeChanged, old device gone -> deviceRemoved, a category change that
//   leaves a playback-only session -> routeChanged, FIX-IOS-RECORD) and engine
//   configuration changes stop the recording, finalize and KEEP the file, and emit an
//   `interruption` event keyed by the recording id; `stop(id)` still returns the RecordedAsset.
// - Permission: AVAudioApplication (17+) / AVAudioSession (15–16) through Permissions (IOS-15);
//   `start` without a granted permission fails with `permissionDenied`.
// - Preview playback is muted while recording: `VoiceRecorder.isRecording` and the
//   `VoiceRecorder.activityDidChange` notification (main thread, userInfo["active"]: Bool) are
//   what the preview mute (INT-07 RecordingMuteBridge) observes. The recorder turns active before
//   it reconfigures the session, so a project that Dart started playing just before the recorder
//   (UX-34, FIX-IOS-RECORD) is muted before the first captured sample.
//
// One recording at a time (`busy` otherwise). start/stop/cancel run on the recorder queue; buffers
// are converted and written on the recorder's own write queue.

import AVFoundation
import Foundation
import UIKit

// MARK: - Seams (injectable for tests)

/// The microphone input: delivers buffers in its own format until stopped.
protocol RecorderInput: AnyObject {
    /// Called when the input stopped by itself (engine configuration change).
    var onInterruption: ((RecordingInterruptionMsg) -> Void)? { get set }
    /// Starts delivering buffers; returns their format.
    func start(_ onBuffer: @escaping (AVAudioPCMBuffer, AVAudioTime) -> Void) throws -> AVAudioFormat
    /// Stops delivery (idempotent). No buffer is delivered after it returns.
    func stop()
    /// Input latency of the route, in seconds.
    var inputLatency: TimeInterval { get }
}

/// The audio session operations the recorder needs.
protocol RecorderAudioSession: AnyObject {
    associatedtype Snapshot
    func snapshot() -> Snapshot
    func configureForRecording() throws
    func restore(_ snapshot: Snapshot)
    /// Whether the session still captures from the microphone (false once something switched it
    /// to a playback-only category while recording).
    func allowsRecording() -> Bool
}

extension RecorderAudioSession {
    func allowsRecording() -> Bool { true }
}

/// AVAudioEngine's input node as a RecorderInput.
final class AudioEngineInput: RecorderInput {
    var onInterruption: ((RecordingInterruptionMsg) -> Void)?
    private let engine = AVAudioEngine()
    private var observer: NSObjectProtocol?
    private var running = false

    func start(_ onBuffer: @escaping (AVAudioPCMBuffer, AVAudioTime) -> Void) throws -> AVAudioFormat {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw EngineError(.notSupportedOnDevice, "no microphone input available")
        }
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, time in
            onBuffer(buffer, time)
        }
        observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in
            self?.onInterruption?(.routeChanged)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            removeObserver()
            throw EngineError.from(error)
        }
        running = true
        return format
    }

    func stop() {
        removeObserver()
        guard running else { return }
        running = false
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    var inputLatency: TimeInterval { AVAudioSession.sharedInstance().inputLatency }

    private func removeObserver() {
        if let observer = observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
    }
}

/// The shared AVAudioSession as a RecorderAudioSession.
final class SharedRecorderAudioSession: RecorderAudioSession {
    struct Snapshot: Equatable {
        let category: AVAudioSession.Category
        let mode: AVAudioSession.Mode
        let options: AVAudioSession.CategoryOptions
    }

    private var session: AVAudioSession { AVAudioSession.sharedInstance() }

    func snapshot() -> Snapshot {
        Snapshot(category: session.category, mode: session.mode, options: session.categoryOptions)
    }

    func configureForRecording() throws {
        do {
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothHFP])
            try? session.setPreferredSampleRate(RecordingWavWriter.sampleRate)
            try session.setActive(true)
        } catch {
            throw EngineError.from(error)
        }
    }

    func allowsRecording() -> Bool {
        session.category == .playAndRecord || session.category == .record
    }

    func restore(_ snapshot: Snapshot) {
        do {
            try session.setCategory(snapshot.category, mode: snapshot.mode, options: snapshot.options)
        } catch {
            Log.error(.recorder, "restoring the audio session failed: \(EngineError.from(error).code.rawValue)")
        }
    }
}

// MARK: - WAV writer

/// WAV PCM s16 LE 48 kHz mono writer whose header is kept valid on disk.
final class RecordingWavWriter {
    static let sampleRate: Double = 48_000
    static let headerBytes = 44
    /// Header rewrite interval in frames (0.5 s).
    static let headerInterval: Int64 = 24_000

    private let handle: FileHandle
    private(set) var frames: Int64 = 0
    private var framesAtHeader: Int64 = 0
    private(set) var finished = false

    init(url: URL) throws {
        let manager = FileManager.default
        do {
            try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if manager.fileExists(atPath: url.path) { try manager.removeItem(at: url) }
            guard manager.createFile(atPath: url.path, contents: RecordingWavWriter.header(frames: 0)) else {
                throw EngineError(.io, "cannot create the recording file", retryable: true)
            }
            handle = try FileHandle(forWritingTo: url)
            try handle.seekToEnd()
        } catch let error as EngineError {
            throw error
        } catch {
            throw EngineError.from(error)
        }
    }

    /// The 44-byte RIFF/WAVE header for [frames] mono s16 frames at 48 kHz.
    static func header(frames: Int64) -> Data {
        let dataBytes = UInt32(clamping: frames * 2)
        var data = Data(capacity: headerBytes)
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8))
        u32(36 &+ dataBytes)
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        u32(16)
        u16(1)  // PCM
        u16(1)  // mono
        u32(UInt32(sampleRate))
        u32(UInt32(sampleRate) * 2)  // byte rate
        u16(2)  // block align
        u16(16)  // bits per sample
        data.append(contentsOf: Array("data".utf8))
        u32(dataBytes)
        return data
    }

    /// Appends samples (ignored after `finish`).
    func append(_ samples: [Int16]) throws {
        guard !finished, !samples.isEmpty else { return }
        let bytes = samples.withUnsafeBufferPointer { buffer -> Data in
            var out = Data(count: buffer.count * 2)
            out.withUnsafeMutableBytes { raw in
                let dst = raw.bindMemory(to: Int16.self)
                for i in 0..<buffer.count { dst[i] = buffer[i].littleEndian }
            }
            return out
        }
        do {
            try handle.write(contentsOf: bytes)
        } catch {
            throw EngineError.from(error)
        }
        frames += Int64(samples.count)
        if frames - framesAtHeader >= RecordingWavWriter.headerInterval { try writeHeader() }
    }

    /// Rewrites the header with the current sizes.
    func writeHeader() throws {
        do {
            let end = try handle.offset()
            try handle.seek(toOffset: 0)
            try handle.write(contentsOf: RecordingWavWriter.header(frames: frames))
            try handle.seek(toOffset: end)
            framesAtHeader = frames
        } catch {
            throw EngineError.from(error)
        }
    }

    /// Final header, sync and close (idempotent).
    func finish() throws {
        guard !finished else { return }
        finished = true
        defer { try? handle.close() }
        try writeHeader()
        try? handle.synchronize()
    }
}

// MARK: - Recorder

final class VoiceRecorder: VoiceRecording {
    /// Posted on main when a recording starts or ends; userInfo["active"] is a Bool.
    static let activityDidChange = Notification.Name("com.vecvel.danaview.editor.voiceRecorderActivity")

    private static let activeLock = NSLock()
    private static var activeCount = 0

    /// Whether a recording is in progress (any thread). The preview mutes its audio while true.
    static var isRecording: Bool {
        activeLock.lock()
        defer { activeLock.unlock() }
        return activeCount > 0
    }

    /// Level window: 50 ms at 48 kHz (20 Hz).
    static let levelWindowFrames = 2_400

    /// Maps an RMS value to 0…1 over -60…0 dBFS.
    static func level(rms: Float) -> Double {
        guard rms > 0, rms.isFinite else { return 0 }
        let db = 20 * log10(Double(rms))
        return min(1, max(0, (db + 60) / 60))
    }

    private let context: EngineContext
    private let makeInput: () -> RecorderInput
    private let snapshotSession: () -> Any
    private let configureSession: () throws -> Void
    private let restoreSession: (Any) -> Void
    private let sessionRecords: () -> Bool
    private let permissionStatus: () -> Permissions.RecordPermission
    private let notifications: NotificationCenter
    private let now: () -> UInt64

    /// Recorder-queue state.
    private var current: Recording?
    private var finished: [String: RecordedAssetMsg] = [:]
    private var cancelled: Set<String> = []

    convenience init(context: EngineContext) {
        self.init(
            context: context, input: { AudioEngineInput() }, session: SharedRecorderAudioSession(),
            permission: Permissions.microphoneStatus, notifications: .default)
    }

    /// Tests inject the input, the session, the permission and the notification center.
    init<Session: RecorderAudioSession>(
        context: EngineContext, input: @escaping () -> RecorderInput, session: Session,
        permission: @escaping () -> Permissions.RecordPermission, notifications: NotificationCenter,
        now: @escaping () -> UInt64 = { mach_absolute_time() }
    ) {
        self.context = context
        self.makeInput = input
        self.snapshotSession = { session.snapshot() }
        self.configureSession = { try session.configureForRecording() }
        self.restoreSession = { snapshot in
            if let snapshot = snapshot as? Session.Snapshot { session.restore(snapshot) }
        }
        self.sessionRecords = { session.allowsRecording() }
        self.permissionStatus = permission
        self.notifications = notifications
        self.now = now
    }

    private var queue: DispatchQueue { context.queues.recorder }

    // MARK: Permission (main)

    func permission(reply: @escaping EngineReply<MicPermissionMsg>) {
        reply(.success(Permissions.micPermission(permissionStatus())))
    }

    func requestPermission(reply: @escaping EngineReply<MicPermissionMsg>) {
        let status = permissionStatus()
        guard status == .undetermined else {
            reply(.success(Permissions.micPermission(status)))
            return
        }
        Permissions.requestMicrophone { reply(.success(Permissions.micPermission($0))) }
    }

    func openSettings(reply: @escaping EngineReply<Void>) {
        guard let url = URL(string: UIApplication.openSettingsURLString) else {
            reply(.failure(EngineError(.internal, "no settings URL")))
            return
        }
        UIApplication.shared.open(url, options: [:]) { opened in
            reply(opened ? .success(()) : .failure(EngineError(.internal, "settings did not open")))
        }
    }

    // MARK: Recording (recorder queue)

    func start(outputURL: URL, reply: @escaping EngineReply<String>) {
        onQueue { [self] in
            if current != nil {
                reply(.failure(EngineError(.busy, "a recording is already running")))
                return
            }
            guard permissionStatus() == .granted else {
                reply(.failure(EngineError(.permissionDenied, "microphone permission not granted")))
                return
            }
            let startHost = now()
            let snapshot = snapshotSession()
            // Mute the preview before the session is reconfigured (FIX-IOS-RECORD): Dart starts the
            // project playing just before the recorder, so the project sound must stop before the
            // first captured sample.
            VoiceRecorder.setActive(true)
            do {
                try configureSession()
                let writer = try RecordingWavWriter(url: outputURL)
                let input = makeInput()
                let recording = Recording(
                    id: "rec-" + UUID().uuidString.lowercased(), url: outputURL, writer: writer, input: input,
                    startHost: startHost, sessionSnapshot: snapshot, events: context.events)
                input.onInterruption = { [weak self, weak recording] reason in
                    guard let recording = recording else { return }
                    self?.interrupt(recording, reason)
                }
                current = recording
                observe(recording)
                do {
                    try recording.begin()
                } catch {
                    unobserve(recording)
                    current = nil
                    recording.abort()
                    try? FileManager.default.removeItem(at: outputURL)
                    throw error
                }
                Log.info(.recorder, "recording \(recording.id) started")
                reply(.success(recording.id))
            } catch {
                restoreSession(snapshot)
                VoiceRecorder.setActive(false)
                reply(.failure(EngineError.from(error)))
            }
        }
    }

    func stop(recordingId: String, reply: @escaping EngineReply<RecordedAssetMsg>) {
        onQueue { [self] in
            if let recording = current, recording.id == recordingId {
                reply(Result { try finish(recording) })
                return
            }
            if let asset = finished.removeValue(forKey: recordingId) {
                reply(.success(asset))
                return
            }
            if cancelled.contains(recordingId) {
                reply(.failure(EngineError.cancelled))
                return
            }
            reply(.failure(EngineError(.internal, "unknown recording")))
        }
    }

    func cancel(recordingId: String, reply: @escaping EngineReply<Void>) {
        onQueue { [self] in
            if let recording = current, recording.id == recordingId {
                _ = try? finish(recording, keep: false)
            } else if let asset = finished.removeValue(forKey: recordingId) {
                // Interrupted earlier: the kept file is discarded by the cancel.
                try? FileManager.default.removeItem(atPath: asset.path)
            }
            cancelled.insert(recordingId)
            reply(.success(()))
        }
    }

    // MARK: Ending

    /// Stops [recording], restores the session and returns its asset (deleted when ![keep]).
    @discardableResult
    private func finish(_ recording: Recording, keep: Bool = true) throws -> RecordedAssetMsg {
        unobserve(recording)
        if current === recording { current = nil }
        defer {
            restoreSession(recording.sessionSnapshot)
            VoiceRecorder.setActive(false)
        }
        let asset = try recording.end()
        if !keep {
            try? FileManager.default.removeItem(at: recording.url)
            Log.info(.recorder, "recording \(recording.id) cancelled")
        } else {
            Log.info(.recorder, "recording \(recording.id) stopped: \(asset.durationUs) us")
        }
        return asset
    }

    /// Stops [recording] by itself, keeps the file and tells Dart.
    private func interrupt(_ recording: Recording, _ reason: RecordingInterruptionMsg) {
        onQueue(async: true) { [self] in
            guard current === recording else { return }
            Log.info(.recorder, "recording \(recording.id) interrupted: \(reason)")
            do {
                finished[recording.id] = try finish(recording)
            } catch {
                Log.error(.recorder, "finalizing an interrupted recording failed: \(EngineError.from(error).code.rawValue)")
            }
            context.events.emitInterruption(recordingId: recording.id, reason)
        }
    }

    // MARK: Notifications

    private func observe(_ recording: Recording) {
        let session = AVAudioSession.sharedInstance()
        recording.observers = [
            notifications.addObserver(forName: AVAudioSession.interruptionNotification, object: session, queue: nil) {
                [weak self, weak recording] note in
                guard let self = self, let recording = recording else { return }
                let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
                if raw.flatMap(AVAudioSession.InterruptionType.init) == .began {
                    self.interrupt(recording, .interrupted)
                }
            },
            notifications.addObserver(forName: AVAudioSession.routeChangeNotification, object: session, queue: nil) {
                [weak self, weak recording] note in
                guard let self = self, let recording = recording else { return }
                let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
                switch raw.flatMap(AVAudioSession.RouteChangeReason.init) {
                case .oldDeviceUnavailable: self.interrupt(recording, .deviceRemoved)
                case .newDeviceAvailable: self.interrupt(recording, .routeChanged)
                case .categoryChange:
                    // Our own change keeps .playAndRecord. Anything that switched the session to a
                    // playback-only category (a preview starting to play, IOS-11) has silently
                    // stopped the microphone: stop and keep what was captured instead of writing
                    // nothing (FIX-IOS-RECORD).
                    if !self.sessionRecords() { self.interrupt(recording, .routeChanged) }
                default: break  // overrides, wake from sleep
                }
            },
            notifications.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: session, queue: nil) {
                [weak self, weak recording] _ in
                guard let self = self, let recording = recording else { return }
                self.interrupt(recording, .interrupted)
            },
        ]
    }

    private func unobserve(_ recording: Recording) {
        recording.observers.forEach(notifications.removeObserver)
        recording.observers = []
    }

    // MARK: Helpers

    private static func setActive(_ active: Bool) {
        activeLock.lock()
        activeCount = max(0, activeCount + (active ? 1 : -1))
        let now = activeCount > 0
        activeLock.unlock()
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: activityDidChange, object: nil, userInfo: ["active": now])
        }
    }

    /// Runs [work] on the recorder queue (inline when already there).
    private func onQueue(async: Bool = false, _ work: @escaping () -> Void) {
        if !async && EngineQueues.currentName == "recorder" {
            work()
        } else {
            queue.async(execute: work)
        }
    }
}

// MARK: - One recording

private final class Recording {
    let id: String
    let url: URL
    let startHost: UInt64
    let sessionSnapshot: Any
    var observers: [NSObjectProtocol] = []

    private let writer: RecordingWavWriter
    private let input: RecorderInput
    private let events: EventHub
    private let writeQueue: DispatchQueue

    // Write-queue state.
    private var converter: AVAudioConverter?
    private var outputFormat: AVAudioFormat
    private var firstSampleHost: UInt64?
    private var levelSumSquares: Double = 0
    private var levelFrames = 0
    private var writeError: Error?
    private var ended = false

    init(id: String, url: URL, writer: RecordingWavWriter, input: RecorderInput, startHost: UInt64, sessionSnapshot: Any, events: EventHub) {
        self.id = id
        self.url = url
        self.writer = writer
        self.input = input
        self.startHost = startHost
        self.sessionSnapshot = sessionSnapshot
        self.events = events
        self.writeQueue = DispatchQueue(label: "com.vecvel.danaview.editor.recorder.write", qos: .userInitiated)
        self.outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: RecordingWavWriter.sampleRate, channels: 1, interleaved: false)!
    }

    func begin() throws {
        let format = try input.start { [weak self] buffer, time in
            self?.writeQueue.sync { self?.process(buffer, time) }
        }
        try writeQueue.sync {
            guard let converter = AVAudioConverter(from: format, to: outputFormat) else {
                throw EngineError(.notSupportedOnDevice, "unsupported microphone format")
            }
            converter.downmix = true
            converter.sampleRateConverterQuality = AVAudioQuality.high.rawValue
            self.converter = converter
        }
    }

    /// Stops the input after a failed start.
    func abort() {
        input.stop()
        writeQueue.sync {
            ended = true
            try? writer.finish()
        }
    }

    /// Stops the input and finalizes the WAV.
    func end() throws -> RecordedAssetMsg {
        input.stop()
        return try writeQueue.sync {
            ended = true
            try writer.finish()
            if let error = writeError { throw error }
            let durationUs = Int64((Double(writer.frames) * 1_000_000 / RecordingWavWriter.sampleRate).rounded())
            var latencyUs: Int64 = 0
            if let first = firstSampleHost, first > startHost {
                latencyUs = Int64((AVAudioTime.seconds(forHostTime: first - startHost) * 1_000_000).rounded())
            }
            return RecordedAssetMsg(path: url.path, durationUs: durationUs, startLatencyUs: latencyUs)
        }
    }

    // Write queue.
    private func process(_ buffer: AVAudioPCMBuffer, _ time: AVAudioTime) {
        guard !ended, writeError == nil, let converter = converter, buffer.frameLength > 0 else { return }
        if firstSampleHost == nil {
            let host = time.isHostTimeValid ? time.hostTime : mach_absolute_time()
            let latency = AVAudioTime.hostTime(forSeconds: max(0, input.inputLatency))
            firstSampleHost = host > latency ? host - latency : host
        }
        let ratio = RecordingWavWriter.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return }
        var supplied = false
        var conversionError: NSError?
        let status = converter.convert(to: out, error: &conversionError) { _, inputStatus in
            if supplied {
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return buffer
        }
        if status == .error {
            writeError = conversionError.map(EngineError.from) ?? EngineError(.internal, "conversion failed")
            return
        }
        let count = Int(out.frameLength)
        guard count > 0, let channel = out.floatChannelData?[0] else { return }
        var samples = [Int16](repeating: 0, count: count)
        for i in 0..<count {
            let v = max(-1, min(1, channel[i]))
            samples[i] = Int16((v * 32767).rounded())
            levelSumSquares += Double(v * v)
            levelFrames += 1
            if levelFrames >= VoiceRecorder.levelWindowFrames {
                let rms = Float(sqrt(levelSumSquares / Double(levelFrames)))
                events.emitRecorderLevel(recordingId: id, VoiceRecorder.level(rms: rms))
                levelSumSquares = 0
                levelFrames = 0
            }
        }
        do {
            try writer.append(samples)
        } catch {
            writeError = error
        }
    }
}
