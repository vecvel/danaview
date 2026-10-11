// OWNER: IOS-03
//
// D-33 placeholder created by ENG-07: JPEG thumbnail strips (ARCH §12.3, §15).
// Only IOS-03 edits this file once it lands.
// The glue calls it through `ThumbnailProviding` (Glue/ServiceProtocols.swift) and builds it with
// `init(context:)` (Glue/EngineServices.swift): keep both. Until then every call fails with
// `notSupportedOnDevice`, which Dart maps to the editor's unsupported state.

import Foundation

final class ThumbnailService: ThumbnailProviding {
    private let context: EngineContext

    init(context: EngineContext) {
        self.context = context
    }

    func tile(
        requestId: String, request: ThumbnailRequestMsg, mediaURL: URL, priority: ThumbPriorityMsg,
        reply: @escaping EngineReply<ThumbnailTileMsg>
    ) {
        reply(.failure(EngineError.notSupportedOnDevice("Thumbnails")))
    }

    /// No pending requests exist yet.
    func cancel(requestId: String) {}
}
