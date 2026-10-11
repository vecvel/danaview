// OWNER: IOS-14
//
// D-33 placeholder created by ENG-07: voice recorder (ARCH §15, D-25).
// Only IOS-14 edits this file once it lands.
// The glue calls it through `VoiceRecording` (Glue/ServiceProtocols.swift) and builds it with
// `init(context:)` (Glue/EngineServices.swift): keep both. Until then every call fails with
// `notSupportedOnDevice`, which Dart maps to the editor's unsupported state.

import Foundation

final class VoiceRecorder: VoiceRecording {
    private let context: EngineContext

    init(context: EngineContext) {
        self.context = context
    }

    func permission(reply: @escaping EngineReply<MicPermissionMsg>) {
        reply(.failure(EngineError.notSupportedOnDevice("Voice recording")))
    }

    func requestPermission(reply: @escaping EngineReply<MicPermissionMsg>) {
        reply(.failure(EngineError.notSupportedOnDevice("Voice recording")))
    }

    func openSettings(reply: @escaping EngineReply<Void>) {
        reply(.failure(EngineError.notSupportedOnDevice("Voice recording")))
    }

    func start(outputURL: URL, reply: @escaping EngineReply<String>) {
        reply(.failure(EngineError.notSupportedOnDevice("Voice recording")))
    }

    func stop(recordingId: String, reply: @escaping EngineReply<RecordedAssetMsg>) {
        reply(.failure(EngineError.notSupportedOnDevice("Voice recording")))
    }

    /// No recording runs yet, so cancelling succeeds.
    func cancel(recordingId: String, reply: @escaping EngineReply<Void>) {
        reply(.success(()))
    }
}
