// OWNER: INT-07
//
// The preview mutes while a recording captures (INT-07, ARCH §15 'Voice recording'): the recorder
// (IOS-14) posts `VoiceRecorder.activityDidChange` on main when capture starts or ends; this bridge
//  - emits the engine-wide `recordingChanged` event (Dart: `VoiceRecorder.recordingChanged`), once
//    per change, and
//  - mutes or unmutes every preview session's player on the previewControl queue
//    (`PreviewRecordingMuting`, implemented for IOS-11's PreviewSessionManager below with
//    `AVPlayer.isMuted`, which survives player-item rebuilds).
// A session opened while a recording captures is muted by the preview glue after `open`
// (`PreviewHostApiImpl`), which applies the current state to every session.

import AVFoundation
import Foundation

/// Preview sessions whose audio can be muted while a recording captures. Queue: previewControl.
protocol PreviewRecordingMuting: AnyObject {
    func setRecordingMuted(_ muted: Bool)
}

extension PreviewSessionManager: PreviewRecordingMuting {
    func setRecordingMuted(_ muted: Bool) {
        for id in sessionIds {
            session(id)?.player.isMuted = muted
        }
    }
}

final class RecordingMuteBridge {
    private let context: EngineContext
    private let services: EngineServices
    private let isRecording: () -> Bool
    private var observer: NSObjectProtocol?
    private var last: Bool?

    init(context: EngineContext, services: EngineServices, isRecording: @escaping () -> Bool = { VoiceRecorder.isRecording }) {
        self.context = context
        self.services = services
        self.isRecording = isRecording
    }

    /// Starts observing the recorder (main thread).
    func start() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(forName: VoiceRecorder.activityDidChange, object: nil, queue: .main) {
            [weak self] note in
            guard let self = self else { return }
            self.recordingChanged((note.userInfo?["active"] as? Bool) ?? self.isRecording())
        }
    }

    /// Stops observing (main thread).
    func stop() {
        if let observer = observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        last = nil
    }

    deinit {
        if let observer = observer { NotificationCenter.default.removeObserver(observer) }
    }

    /// A capture started (true) or ended (false): event once per change, then (un)mute (main thread).
    func recordingChanged(_ active: Bool) {
        guard active != last else { return }
        last = active
        context.events.emit(EngineEventMsg(kind: .recordingChanged, recording: active))
        RecordingMuteBridge.apply(active, to: services.previews, on: context.queues.previewControl)
    }

    /// Applies [muted] to every session of [previews] on [queue] (no-op for managers that cannot mute).
    static func apply(_ muted: Bool, to previews: PreviewSessionManaging, on queue: DispatchQueue) {
        guard let muting = previews as? PreviewRecordingMuting else { return }
        queue.async { muting.setRecordingMuted(muted) }
    }
}
