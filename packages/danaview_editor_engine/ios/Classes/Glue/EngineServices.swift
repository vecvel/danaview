// OWNER: ENG-07 (frozen by ENG-06; amended by INT-06)
//
// The service instances one Flutter engine's glue delegates to. `make(context:)` builds the ARCH
// §4.4 service classes through `init(context:)`; service tickets replace the placeholder bodies of
// those classes and keep the initializer. RunnerTests/Glue injects fakes through the memberwise
// initializer. The D-45 render-preview services (INT-06) default to `NotSupportedRenderPreview`,
// so memberwise initializers written before INT-06 keep compiling; `make` uses IOS-19's classes.

import Foundation

/// Services behind the host APIs (ServiceProtocols.swift).
struct EngineServices {
    var capabilities: CapabilitiesProviding
    var compatibility: CompatibilityChecking
    var probe: MediaProbing
    var caches: CacheMaintaining
    var thumbnails: ThumbnailProviding
    var jobs: JobScheduling
    var proxies: ProxyStatusProviding
    var previews: PreviewSessionManaging
    var exports: ExportCoordinating
    var recorder: VoiceRecording
    var picker: MediaPicking
    var photos: PhotosSaving
    var files: FileHandingOff
    var access: MediaAccessing
    var permissions: PermissionRequesting
    var background: BackgroundLeasing
    var drops: DropTargeting
    var renderPreviews: RenderPreviewStarting = NotSupportedRenderPreview()
    var renderedRanges: RenderedRangeSetting = NotSupportedRenderPreview()
    var power: PowerStateProviding = NotSupportedRenderPreview()

    /// The production services of [context].
    static func make(context: EngineContext) -> EngineServices {
        EngineServices(
            capabilities: Capabilities(context: context),
            compatibility: Compatibility(context: context),
            probe: Probe(context: context),
            caches: DiskCache(context: context),
            thumbnails: ThumbnailService(context: context),
            jobs: JobRegistry(context: context),
            proxies: ProxyRegistry(context: context),
            previews: PreviewSessionManager(context: context),
            exports: ExportCoordinator(context: context),
            recorder: VoiceRecorder(context: context),
            picker: MediaPicker(context: context),
            photos: PhotosSaver(context: context),
            files: FileHandoff(context: context),
            access: MediaAccess(context: context),
            permissions: Permissions(context: context),
            background: BackgroundGuard(context: context),
            drops: DropTarget(context: context),
            renderPreviews: RenderPreviewJobService(context: context),
            renderedRanges: RenderedRangeHandler(context: context),
            power: PowerStateMonitor(context: context))
    }
}

/// The D-45 render-preview services of an `EngineServices` built without them (glue tests):
/// every call fails with `notSupportedOnDevice` (INT-06).
final class NotSupportedRenderPreview: RenderPreviewStarting, RenderedRangeSetting, PowerStateProviding {
    func start(_ request: JobRequestMsg, plan: Data, outputURL: URL, reply: @escaping EngineReply<String>) {
        reply(.failure(EngineError.notSupportedOnDevice("render preview")))
    }

    func setRenderedRanges(sessionId: String, ranges: [RenderedRangeMsg], fileURLs: [URL], reply: @escaping EngineReply<Void>) {
        reply(.failure(EngineError.notSupportedOnDevice("rendered ranges")))
    }

    func powerState(reply: @escaping EngineReply<PowerStateMsg>) {
        reply(.failure(EngineError.notSupportedOnDevice("power state")))
    }
}
