// OWNER: IOS-16
//
// D-33 placeholder created by ENG-07: external drop target on the Flutter view (D-18).
// Only IOS-16 edits this file once it lands.
// The glue calls it through `DropTargeting` (Glue/ServiceProtocols.swift) and builds it with
// `init(context:)` (Glue/EngineServices.swift): keep both. Until then every call fails with
// `notSupportedOnDevice`, which Dart maps to the editor's unsupported state.

import Foundation

final class DropTarget: DropTargeting {
    private let context: EngineContext

    init(context: EngineContext) {
        self.context = context
    }

    /// Disabling always succeeds; enabling is not available yet.
    func setEnabled(_ enabled: Bool, reply: @escaping EngineReply<Void>) {
        if enabled {
            reply(.failure(EngineError.notSupportedOnDevice("Drop target")))
        } else {
            reply(.success(()))
        }
    }
}
