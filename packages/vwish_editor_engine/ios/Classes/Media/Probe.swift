// OWNER: IOS-02
//
// D-33 placeholder created by ENG-07: media probe (ARCH §15, D-27).
// Only IOS-02 edits this file once it lands.
// The glue calls it through `MediaProbing` (Glue/ServiceProtocols.swift) and builds it with
// `init(context:)` (Glue/EngineServices.swift): keep both. Until then every call fails with
// `notSupportedOnDevice`, which Dart maps to the editor's unsupported state.

import Foundation

final class Probe: MediaProbing {
    private let context: EngineContext

    init(context: EngineContext) {
        self.context = context
    }

    func probe(_ media: ResolvedMediaMsg, url: URL, reply: @escaping EngineReply<ProbeMsg>) {
        reply(.failure(EngineError.notSupportedOnDevice("Probe")))
    }
}
