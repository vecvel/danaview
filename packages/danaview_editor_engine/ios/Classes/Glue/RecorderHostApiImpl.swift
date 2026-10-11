// OWNER: ENG-07 (frozen by ENG-06)
//
// Glue of `RecorderHostApi` (ARCH §12.4, §15, D-25): permission calls and openSettings run on main
// (AVAudioSession / UIApplication), start/stop/cancel on the recorder queue; VoiceRecorder (IOS-14)
// emits levels and interruptions keyed by the recording id. The WAV output path must lie inside the
// editor roots (`projects/<id>/assets/recordings/`).

import Foundation

final class RecorderHostApiImpl: RecorderHostApi {
    private let context: EngineContext
    private let services: EngineServices

    init(context: EngineContext, services: EngineServices) {
        self.context = context
        self.services = services
    }

    func permission(completion: @escaping (Result<MicPermissionMsg, Error>) -> Void) {
        GlueDispatch.hop("recorder.permission", on: .main, completion: completion) { [recorder = services.recorder] reply in
            recorder.permission(reply: reply)
        }
    }

    func requestPermission(completion: @escaping (Result<MicPermissionMsg, Error>) -> Void) {
        GlueDispatch.hop("recorder.requestPermission", on: .main, completion: completion) { [recorder = services.recorder] reply in
            recorder.requestPermission(reply: reply)
        }
    }

    func openSettings(completion: @escaping (Result<Void, Error>) -> Void) {
        GlueDispatch.hop("recorder.openSettings", on: .main, completion: completion) { [recorder = services.recorder] reply in
            recorder.openSettings(reply: reply)
        }
    }

    func start(outputPath: String, completion: @escaping (Result<String, Error>) -> Void) {
        GlueDispatch.hop(
            "recorder.start", on: context.queues.recorder, completion: completion,
            validate: { try context.requirePaths().requireWritable(outputPath, name: "outputPath") }
        ) { [recorder = services.recorder] url, reply in
            recorder.start(outputURL: url, reply: reply)
        }
    }

    func stop(recordingId: String, completion: @escaping (Result<RecordedAssetMsg, Error>) -> Void) {
        GlueDispatch.hop(
            "recorder.stop", on: context.queues.recorder, completion: completion,
            validate: { try Validate.id(recordingId, "recordingId") }
        ) { [recorder = services.recorder] _, reply in
            recorder.stop(recordingId: recordingId, reply: reply)
        }
    }

    func cancel(recordingId: String, completion: @escaping (Result<Void, Error>) -> Void) {
        GlueDispatch.hop(
            "recorder.cancel", on: context.queues.recorder, completion: completion,
            validate: { try Validate.id(recordingId, "recordingId") }
        ) { [recorder = services.recorder] _, reply in
            recorder.cancel(recordingId: recordingId, reply: reply)
        }
    }
}
