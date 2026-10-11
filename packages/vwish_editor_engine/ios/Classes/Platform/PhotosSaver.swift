// OWNER: IOS-13
//
// D-33 placeholder created by ENG-07: add-only Photos saves (ARCH §14.1, D-39).
// Only IOS-13 edits this file once it lands.
// The glue calls it through `PhotosSaving` (Glue/ServiceProtocols.swift) and builds it with
// `init(context:)` (Glue/EngineServices.swift): keep both. Until then every call fails with
// `notSupportedOnDevice`, which Dart maps to the editor's unsupported state.

import Foundation

final class PhotosSaver: PhotosSaving {
    private let context: EngineContext

    init(context: EngineContext) {
        self.context = context
    }

    func saveToPhotos(fileURL: URL, reply: @escaping EngineReply<FileHandoffResultMsg>) {
        reply(.failure(EngineError.notSupportedOnDevice("Save to Photos")))
    }
}
