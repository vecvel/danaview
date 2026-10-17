// OWNER: IOS-15
//
// Permission requests (ARCH §12.4, §15):
// - Notifications: N/A on iOS. Background exports post no notification that needs a prompt
//   (BGContinuedProcessingTask shows its own system UI), so the answer is always true, as the Dart
//   contract says ("true elsewhere").
// - Microphone: status and request used by VoiceRecorder (IOS-14). iOS 17+ goes through
//   AVAudioApplication; iOS 15/16 through AVAudioSession (D-41, guarded by #available). A denial
//   on iOS is final for the app (the system never asks again), so it maps to `permanentlyDenied`
//   and the UI offers Open Settings.

import AVFoundation
import Foundation

final class Permissions: PermissionRequesting {
    private let context: EngineContext

    init(context: EngineContext) {
        self.context = context
    }

    /// Notifications need no prompt on iOS.
    func requestNotificationPermission(reply: @escaping EngineReply<Bool>) {
        reply(.success(true))
    }

    // MARK: Microphone (shared with VoiceRecorder)

    /// Abstract record-permission states of both system APIs.
    enum RecordPermission: Equatable {
        case undetermined, granted, denied
    }

    /// The `MicPermissionMsg` of [state] (iOS denials are permanent).
    static func micPermission(_ state: RecordPermission) -> MicPermissionMsg {
        switch state {
        case .undetermined: return .undetermined
        case .granted: return .granted
        case .denied: return .permanentlyDenied
        }
    }

    /// Current microphone permission.
    static func microphoneStatus() -> RecordPermission {
        if #available(iOS 17.0, *) {
            switch AVAudioApplication.shared.recordPermission {
            case .granted: return .granted
            case .denied: return .denied
            default: return .undetermined
            }
        }
        switch AVAudioSession.sharedInstance().recordPermission {
        case .granted: return .granted
        case .denied: return .denied
        default: return .undetermined
        }
    }

    /// Which API answers on this OS (tests, logs).
    static var microphoneApi: String {
        if #available(iOS 17.0, *) { return "AVAudioApplication" }
        return "AVAudioSession"
    }

    /// Asks for the microphone (shows the system prompt only when undetermined). [completion]
    /// runs on the main thread.
    static func requestMicrophone(_ completion: @escaping (RecordPermission) -> Void) {
        let finish: (Bool) -> Void = { granted in
            DispatchQueue.main.async { completion(granted ? .granted : microphoneStatus() == .undetermined ? .undetermined : .denied) }
        }
        if #available(iOS 17.0, *) {
            AVAudioApplication.requestRecordPermission(completionHandler: finish)
        } else {
            AVAudioSession.sharedInstance().requestRecordPermission(finish)
        }
    }
}
