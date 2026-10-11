// OWNER: IOS-15
//
// D-33 placeholder created by ENG-07: beginBackgroundTask leases with pause semantics (ARCH §15).
// Only IOS-15 edits this file once it lands.
// The glue calls it through `BackgroundLeasing` (Glue/ServiceProtocols.swift) and builds it with
// `init(context:)` (Glue/EngineServices.swift): keep both. Until then every call fails with
// `notSupportedOnDevice`, which Dart maps to the editor's unsupported state.

import Foundation

final class BackgroundGuard: BackgroundLeasing {
    private let context: EngineContext

    init(context: EngineContext) {
        self.context = context
    }

    func acquire(title: String, reply: @escaping EngineReply<String?>) {
        reply(.failure(EngineError.notSupportedOnDevice("Background leases")))
    }

    func update(leaseId: String, progress: Double, reply: @escaping EngineReply<Void>) {
        reply(.failure(EngineError.notSupportedOnDevice("Background leases")))
    }

    /// No lease exists yet, so releasing succeeds.
    func release(leaseId: String, reply: @escaping EngineReply<Void>) {
        reply(.success(()))
    }
}
