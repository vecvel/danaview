// OWNER: IOS-11
//
// AudioSessionCoordinator (ARCH §13.2 'Session', §17.3 player handoff, R13): while a preview
// plays, the shared AVAudioSession is `.playback` / `.moviePlayback` (audible with the ring/silent
// switch on, like the app's own player). The category, mode and options found before the first
// play are restored when the session is disposed, so the app's video player (or the recorder)
// gets its own configuration back. Errors are logged, never thrown: preview keeps playing with
// whatever category the system allows.

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
    private let lock = NSLock()
    private var saved: Saved?

    init(port: AudioSessionPort = AVAudioSession.sharedInstance()) {
        self.port = port
    }

    /// The configuration to restore (nil until the first play).
    var savedConfiguration: Saved? {
        lock.lock()
        defer { lock.unlock() }
        return saved
    }

    /// Before playback: remembers the current configuration once, then sets playback.
    func beginPlayback() {
        lock.lock()
        defer { lock.unlock() }
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

    /// Dispose: restores the configuration found before the first play. Idempotent.
    func restore() {
        lock.lock()
        defer { lock.unlock() }
        guard let s = saved else { return }
        saved = nil
        do {
            if port.category != s.category || port.mode != s.mode || port.categoryOptions != s.options {
                try port.setCategory(s.category, mode: s.mode, options: s.options)
            }
        } catch {
            Log.error(.preview, "audio session restore failed: \((error as NSError).code)")
        }
    }
}
