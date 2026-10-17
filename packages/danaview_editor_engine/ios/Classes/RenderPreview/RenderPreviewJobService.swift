// OWNER: IOS-19
//
// The render-preview job service (ARCH D-45, §12.3; the D-33 placeholder of INT-06). The glue
// (JobsHostApiImpl, `startJob` with `JobKindMsg.renderPreview`) has already checked the payload and
// that `outputURL` lies inside `<cache>/danaview/editor/renders/`; this service decodes the range
// plan (`planInvalid` for an invalid or non-preview plan), builds a RenderPreviewJob and queues it
// on IOS-05's JobRegistry with the request's priority (the Dart side defaults to `background`), so
// `cancelJob` / `setJobPriority`, export pre-emption and the job events work as for every job. The
// reply is the job id.

import Foundation
import Metal

final class RenderPreviewJobService: RenderPreviewStarting {
    private let context: EngineContext
    /// The registry jobs are queued on (default: the context's JobRegistry; tests inject one).
    var registry: (() -> JobRegistry?)?
    /// Adjusts the options of each new job (tests: fixture resolvers, thermal states).
    var configure: ((inout RenderPreviewOptions) -> Void)?
    /// The last job queued (tests and diagnostics).
    private(set) var lastJob: RenderPreviewJob?

    init(context: EngineContext) {
        self.context = context
    }

    /// The tier's preview long side (ARCH §12.5 tier table).
    static func defaultMaxPreviewLongSide() -> Int {
        let profile = DeviceProfile.current(hasMetal: MTLCreateSystemDefaultDevice() != nil)
        return Int(Capabilities.TierLimits.of(profile.tier).maxPreviewLongSide)
    }

    func start(_ request: JobRequestMsg, plan: Data, outputURL: URL, reply: @escaping EngineReply<String>) {
        do {
            let paths = try context.requirePaths()
            let range = try RenderPreviewJob.decode(plan)
            guard let registry = registry?() ?? JobRegistry.registry(for: context) else {
                throw EngineError.notSupportedOnDevice("render preview (no job registry)")
            }
            var options = RenderPreviewOptions(
                spacerDirectory: paths.engineAssets, maxPreviewLongSide: RenderPreviewJobService.defaultMaxPreviewLongSide())
            configure?(&options)
            let job = RenderPreviewJob(plan: range, outputURL: outputURL, options: options)
            lastJob = job
            reply(.success(registry.enqueue(job, priority: request.priority)))
        } catch {
            reply(.failure(EngineError.from(error)))
        }
    }
}
