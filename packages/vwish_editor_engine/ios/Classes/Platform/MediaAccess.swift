// OWNER: IOS-15
//
// D-33 placeholder created by ENG-07: bookmarks, stat, quickHash, backup exclusion (ARCH §9, D-44).
// Only IOS-15 edits this file once it lands.
// The glue calls it through `MediaAccessing` (Glue/ServiceProtocols.swift) and builds it with
// `init(context:)` (Glue/EngineServices.swift): keep both. Until then every call fails with
// `notSupportedOnDevice`, which Dart maps to the editor's unsupported state.

import Foundation

final class MediaAccess: MediaAccessing {
    private let context: EngineContext

    init(context: EngineContext) {
        self.context = context
    }

    func createBookmark(fileURL: URL, reply: @escaping EngineReply<Data>) {
        reply(.failure(EngineError.notSupportedOnDevice("Media access")))
    }

    func resolveBookmark(_ bookmark: Data, reply: @escaping EngineReply<ResolvedBookmarkMsg>) {
        reply(.failure(EngineError.notSupportedOnDevice("Media access")))
    }

    /// Android-only URI grants: nothing to do on iOS.
    func persistUriGrant(uri: String, reply: @escaping EngineReply<Void>) {
        reply(.success(()))
    }

    /// Android-only URI grants: nothing to do on iOS.
    func releaseUriGrant(uri: String, reply: @escaping EngineReply<Void>) {
        reply(.success(()))
    }

    func remainingGrantBudget(reply: @escaping EngineReply<Int64>) {
        reply(.failure(EngineError.notSupportedOnDevice("Media access")))
    }

    func stat(_ media: MediaRefMsg, fileURL: URL, reply: @escaping EngineReply<MediaStatMsg?>) {
        reply(.failure(EngineError.notSupportedOnDevice("Media access")))
    }

    func quickHash(_ media: MediaRefMsg, fileURL: URL, reply: @escaping EngineReply<String>) {
        reply(.failure(EngineError.notSupportedOnDevice("Media access")))
    }

    func excludeFromBackup(directoryURL: URL, reply: @escaping EngineReply<Void>) {
        reply(.failure(EngineError.notSupportedOnDevice("Media access")))
    }
}
