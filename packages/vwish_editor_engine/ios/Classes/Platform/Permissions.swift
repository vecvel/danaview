// OWNER: IOS-15
//
// D-33 placeholder created by ENG-07: permission requests (notifications N/A on iOS, microphone status).
// Only IOS-15 edits this file once it lands.
// The glue calls it through `PermissionRequesting` (Glue/ServiceProtocols.swift) and builds it with
// `init(context:)` (Glue/EngineServices.swift): keep both. Until then every call fails with
// `notSupportedOnDevice`, which Dart maps to the editor's unsupported state.

import Foundation

final class Permissions: PermissionRequesting {
    private let context: EngineContext

    init(context: EngineContext) {
        self.context = context
    }

    func requestNotificationPermission(reply: @escaping EngineReply<Bool>) {
        reply(.failure(EngineError.notSupportedOnDevice("Notification permission")))
    }
}
