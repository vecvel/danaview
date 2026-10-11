// OWNER: IOS-13
//
// D-33 placeholder created by ENG-07: Files export and the share sheet (ARCH §14.1).
// Only IOS-13 edits this file once it lands.
// The glue calls it through `FileHandingOff` (Glue/ServiceProtocols.swift) and builds it with
// `init(context:)` (Glue/EngineServices.swift): keep both. Until then every call fails with
// `notSupportedOnDevice`, which Dart maps to the editor's unsupported state.

import Foundation

final class FileHandoff: FileHandingOff {
    private let context: EngineContext

    init(context: EngineContext) {
        self.context = context
    }

    func saveToFiles(fileURL: URL, suggestedName: String, reply: @escaping EngineReply<FileHandoffResultMsg>) {
        reply(.failure(EngineError.notSupportedOnDevice("Save to Files")))
    }

    func share(fileURL: URL, reply: @escaping EngineReply<FileHandoffResultMsg>) {
        reply(.failure(EngineError.notSupportedOnDevice("Share")))
    }
}
