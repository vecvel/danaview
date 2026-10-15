// OWNER: IOS-19
//
// D-33 placeholder created by INT-06 (ARCH D-45, §12.3): the render-preview job service. IOS-19
// replaces the body: a `RenderPreviewJob` registered with IOS-05's JobRegistry that renders the
// range plan through the composition builder and DVCompositor (AVAssetReader → AVAssetWriter,
// preview render size, project fps on the frame grid, H.264 with every frame a sync sample, video
// only) to `outputURL`, reports progress, deletes the partial file on cancel and pauses at thermal
// `serious`. Keep `init(context:)` and the `RenderPreviewStarting` conformance.

import Foundation

final class RenderPreviewJobService: RenderPreviewStarting {
    private let context: EngineContext

    init(context: EngineContext) {
        self.context = context
    }

    func start(_ request: JobRequestMsg, plan: Data, outputURL: URL, reply: @escaping EngineReply<String>) {
        reply(.failure(EngineError.notSupportedOnDevice("render preview")))
    }
}
