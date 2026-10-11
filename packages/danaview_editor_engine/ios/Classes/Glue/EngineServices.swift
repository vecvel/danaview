// OWNER: ENG-07 (frozen by ENG-06)
//
// The service instances one Flutter engine's glue delegates to. `make(context:)` builds the ARCH
// §4.4 service classes through `init(context:)`; service tickets replace the placeholder bodies of
// those classes and keep the initializer. RunnerTests/Glue injects fakes through the memberwise
// initializer.

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
            drops: DropTarget(context: context))
    }
}
