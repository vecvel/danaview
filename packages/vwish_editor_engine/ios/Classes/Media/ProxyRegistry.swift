// OWNER: IOS-05
//
// D-33 placeholder created by ENG-07: proxy status by fingerprint (ARCH §9.5).
// Only IOS-05 edits this file once it lands.
// The glue calls it through `ProxyStatusProviding` (Glue/ServiceProtocols.swift) and builds it with
// `init(context:)` (Glue/EngineServices.swift): keep both. Until then every call fails with
// `notSupportedOnDevice`, which Dart maps to the editor's unsupported state.

import Foundation

final class ProxyRegistry: ProxyStatusProviding {
    private let context: EngineContext

    init(context: EngineContext) {
        self.context = context
    }

    func status(fingerprint: String, reply: @escaping EngineReply<ProxyStatusMsg>) {
        reply(.failure(EngineError.notSupportedOnDevice("Proxies")))
    }
}
