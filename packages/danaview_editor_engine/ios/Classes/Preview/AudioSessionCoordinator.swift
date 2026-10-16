// OWNER: IOS-11
//
// AudioSessionCoordinator (ARCH §13.2 'Session', §17.3 player handoff, R13): while a preview
// plays, the shared AVAudioSession is `.playback` / `.moviePlayback` (audible with the ring/silent
// switch on, like the app's own player). The category, mode and options found before the first
// play are restored when the session is disposed, so the app's video player (or the recorder)
// gets its own configuration back. Errors are logged, never thrown: preview keeps playing with
// whatever category the system allows.
//
// While a voice recording runs (FIX-IOS-AUDIOSESSION, ARCH §15): the category is never changed,
// since leaving `.playAndRecord` stops a capturing microphone. Play only activates the session;
// the configuration found before the first play is not overwritten with the recorder's. When the
// recording ends (`VoiceRecorder.activityDidChange`, posted after the recorder restored its own
// snapshot) the coordinator catches up: a preview that played during the take switches to
// playback (saving the restored configuration as the one to return to), and a dispose that came
// during the take restores its saved configuration then.

import AVFoundation
import Foundation

/// The parts of `AVAudioSession` the coordinator uses (tests inject a recorder).
protocol AudioSessionPort: AnyObject {
    var category: AVAudioSession.Category { get }
    var mode: AVAudioSession.Mode { get }
    var categoryOptions: AVAudioSession.CategoryOptions { get }
    func setCategory(_ category: AVAudioSession.Category, mode: AVAudioSession.Mode, options: AVAudioSession.CategoryOptions) throws
    func setActive(_ active: Bool, options: AVAudioSession.SetActiveOptions) throws
}

extension AVAudioSession: AudioSessionPort {}

final class AudioSessionCoordinator {
    struct Saved: Equatable {
        let category: AVAudioSession.Category
        let mode: AVAudioSession.Mode
        let options: AVAudioSession.CategoryOptions
    }

    private let port: AudioSessionPort
    private let isRecording: () -> Bool
    private let notifications: NotificationCenter
    private let lock = NSLock()
    private var saved: Saved?
    /// Play ran while recording and the category switch is still owed (until restore).
    private var playbackOwed = false
    /// Dispose ran while recording: the configuration to restore when the recording ends.
    private var restoreOwed: Saved?
    /// Observer of the recorder's activity while something is owed. It holds the coordinator
    /// (the preview session may be gone by then) and is removed when it fires.
    private var recordingObserver: NSObjectProtocol?

    init(
        port: AudioSessionPort = AVAudioSession.sharedInstance(),
        isRecording: @escaping () -> Bool = { VoiceRecorder.isRecording },
        notifications: NotificationCenter = .default
    ) {
        self.port = port
        self.isRecording = isRecording
        self.notifications = notifications
    }

    /// The configuration to restore (nil until the first play outside a recording).
    var savedConfiguration: Saved? {
        lock.lock()
        defer { lock.unlock() }
        return saved
    }

    /// Whether a category change waits for the end of a recording.
    var isWaitingForRecordingEnd: Bool {
        lock.lock()
        defer { lock.unlock() }
        return recordingObserver != nil
    }

    /// Before playback: remembers the current configuration once, then sets playback. While
    /// recording, only activates the session and switches once the recording ends.
    func beginPlayback() {
        lock.lock()
        defer { lock.unlock() }
        restoreOwed = nil
        if isRecording() {
            playbackOwed = true
            activate()
            waitForRecordingEnd()
            return
        }
        playbackOwed = false
        applyPlayback()
    }

    /// Dispose: restores the configuration found before the first play. Idempotent. While
    /// recording, the restore waits for the recording to end.
    func restore() {
        lock.lock()
        defer { lock.unlock() }
        playbackOwed = false
        guard let s = saved else { return }
        saved = nil
        if isRecording() {
            restoreOwed = s
            waitForRecordingEnd()
            return
        }
        apply(s)
    }

    // MARK: Private (lock held)

    private func activate() {
        do {
            try port.setActive(true, options: [])
        } catch {
            Log.error(.preview, "audio session activation failed: \((error as NSError).code)")
        }
    }

    private func applyPlayback() {
        if saved == nil {
            saved = Saved(category: port.category, mode: port.mode, options: port.categoryOptions)
        }
        do {
            if port.category != .playback || port.mode != .moviePlayback {
                try port.setCategory(.playback, mode: .moviePlayback, options: [])
            }
            try port.setActive(true, options: [])
        } catch {
            Log.error(.preview, "audio session playback failed: \((error as NSError).code)")
        }
    }

    private func apply(_ s: Saved) {
        do {
            if port.category != s.category || port.mode != s.mode || port.categoryOptions != s.options {
                try port.setCategory(s.category, mode: s.mode, options: s.options)
            }
        } catch {
            Log.error(.preview, "audio session restore failed: \((error as NSError).code)")
        }
    }

    private func waitForRecordingEnd() {
        guard recordingObserver == nil else { return }
        recordingObserver = notifications.addObserver(
            forName: VoiceRecorder.activityDidChange, object: nil, queue: nil
        ) { [self] note in
            if (note.userInfo?["active"] as? Bool) == true { return }
            recordingEnded()
        }
        // The take may have ended between the check and the registration.
        if !isRecording() { catchUp() }
    }

    /// The recorder went idle (its own session snapshot is already back).
    private func recordingEnded() {
        lock.lock()
        defer { lock.unlock() }
        catchUp()
    }

    private func catchUp() {
        guard !isRecording() else { return }  // another take started meanwhile
        if let token = recordingObserver {
            notifications.removeObserver(token)
            recordingObserver = nil
        }
        if playbackOwed {
            playbackOwed = false
            applyPlayback()
        } else if let s = restoreOwed {
            restoreOwed = nil
            apply(s)
        }
    }
}
