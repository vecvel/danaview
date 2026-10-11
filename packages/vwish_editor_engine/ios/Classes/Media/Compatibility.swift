// OWNER: IOS-02
//
// D-33 placeholder created by ENG-07: edit compatibility of a file (ARCH §15, <= 300 ms).
// Only IOS-02 edits this file once it lands.
// The glue calls it through `CompatibilityChecking` (Glue/ServiceProtocols.swift) and builds it with
// `init(context:)` (Glue/EngineServices.swift): keep both. Until then every call fails with
// `notSupportedOnDevice`, which Dart maps to the editor's unsupported state.

import Foundation

final class Compatibility: CompatibilityChecking {
    private let context: EngineContext

    init(context: EngineContext) {
        self.context = context
    }

    func compatibility(of url: URL, reply: @escaping EngineReply<CompatibilityMsg>) {
        reply(.failure(EngineError.notSupportedOnDevice("Compatibility")))
    }
}
