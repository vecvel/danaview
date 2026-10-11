// OWNER: IOS-15
//
// D-33 placeholder created by ENG-07: PHPicker and document picker (ARCH §9.1, §15).
// Only IOS-15 edits this file once it lands.
// The glue calls it through `MediaPicking` (Glue/ServiceProtocols.swift) and builds it with
// `init(context:)` (Glue/EngineServices.swift): keep both. Until then every call fails with
// `notSupportedOnDevice`, which Dart maps to the editor's unsupported state.

import Foundation

final class MediaPicker: MediaPicking {
    private let context: EngineContext

    init(context: EngineContext) {
        self.context = context
    }

    func pick(_ request: MediaPickRequestMsg, reply: @escaping EngineReply<[PickedMediaMsg]>) {
        reply(.failure(EngineError.notSupportedOnDevice("Media picker")))
    }
}
