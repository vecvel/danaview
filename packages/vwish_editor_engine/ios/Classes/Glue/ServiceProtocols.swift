// OWNER: ENG-07 (frozen by ENG-06)
//
// The service protocols the glue delegates to (ARCH §4.4, §12.6). Each protocol is implemented by
// one service class of ARCH §4.4, created by `EngineServices.make` with `init(context:)`; until its
// ticket lands the class is a D-33 placeholder that fails with `notSupportedOnDevice`.
//
// Contract for every method:
// - The glue already validated the arguments (ArgumentValidation.swift) and converted paths and
//   URIs to standardized file URLs; Dart-supplied output paths lie inside the editor roots.
// - The glue calls the method on the queue named in its comment (EngineContext.swift) and never
//   waits for it. Long media work must move to the service's own queue.
// - `reply` must be called exactly once, from any thread; the glue maps the error with
//   `EngineError.from` and answers Dart on the main thread. Never put paths in error messages.
// - Methods without `reply` are fire-and-forget (synchronous Pigeon methods); they must not throw
//   and must return quickly.

import Foundation

/// A service reply: a value or an error (`EngineError` preferred).
typealias EngineReply<T> = (Result<T, Error>) -> Void

// MARK: Engine root (EngineHostApi)

/// Core/Capabilities.swift (IOS-02). Queue: engine.
protocol CapabilitiesProviding: AnyObject {
    func capabilities(reply: @escaping EngineReply<CapabilitiesMsg>)
}

/// Media/Compatibility.swift (IOS-02). Queue: engine. Must answer within 300 ms.
protocol CompatibilityChecking: AnyObject {
    func compatibility(of url: URL, reply: @escaping EngineReply<CompatibilityMsg>)
}

/// Media/Probe.swift (IOS-02). Queue: engine.
protocol MediaProbing: AnyObject {
    func probe(_ media: ResolvedMediaMsg, url: URL, reply: @escaping EngineReply<ProbeMsg>)
}

/// Media/DiskCache.swift (IOS-03). Queue: engine.
protocol CacheMaintaining: AnyObject {
    /// Called once per new set of roots after `initialize` (launch wipe of work/, ARCH §15).
    func engineDidInitialize(paths: Paths)
    /// Drops caches per [level] (fire-and-forget; also on memory warnings).
    func trim(_ level: CacheTrimLevelMsg)
}

// MARK: Jobs (JobsHostApi)

/// Media/ThumbnailService.swift (IOS-03). Queue: jobs.
protocol ThumbnailProviding: AnyObject {
    func tile(
        requestId: String, request: ThumbnailRequestMsg, mediaURL: URL, priority: ThumbPriorityMsg,
        reply: @escaping EngineReply<ThumbnailTileMsg>)
    /// The pending `tile` call for [requestId] fails with `cancelled`.
    func cancel(requestId: String)
}

/// Core/JobRegistry.swift (IOS-05). Queue: jobs. Progress, results and failures are events keyed
/// by the returned job id (`EventHub.emitProgress/emitJobDone/emitJobFailure`).
protocol JobScheduling: AnyObject {
    /// [outputURL] is the validated `outputPath` (reverse, freeze, speechAudio) or nil.
    func start(_ request: JobRequestMsg, mediaURL: URL, outputURL: URL?, reply: @escaping EngineReply<String>)
    /// The job ends with a `cancelled` failure event and deletes partial output.
    func cancel(jobId: String)
    func setPriority(jobId: String, priority: JobPriorityMsg)
}

/// Media/ProxyRegistry.swift (IOS-05). Queue: jobs.
protocol ProxyStatusProviding: AnyObject {
    func status(fingerprint: String, reply: @escaping EngineReply<ProxyStatusMsg>)
}

// MARK: Preview (PreviewHostApi)

/// Preview/PreviewSessionManager.swift (IOS-11). Queue: previewControl for every method. Texture
/// registration hops to the main thread inside the manager (ARCH §12.7).
protocol PreviewSessionManaging: AnyObject {
    func open(_ config: PreviewConfigMsg, reply: @escaping EngineReply<PreviewOpenedMsg>)
    func setPlan(sessionId: String, plan: Data, reply: @escaping EngineReply<PlanAckMsg>)
    func applyPatch(sessionId: String, patch: Data, reply: @escaping EngineReply<PlanAckMsg>)
    func setTransient(sessionId: String, itemId: String, params: Data)
    func clearTransient(sessionId: String, itemId: String)
    func play(sessionId: String, loop: LoopMsg?, reply: @escaping EngineReply<Int64>)
    func pause(sessionId: String, reply: @escaping EngineReply<Int64>)
    func seek(sessionId: String, timeUs: Int64, exact: Bool, reply: @escaping EngineReply<SeekAckMsg>)
    func setQuality(sessionId: String, quality: PreviewQualityMsg, reply: @escaping EngineReply<Void>)
    func setUseProxies(sessionId: String, on: Bool, reply: @escaping EngineReply<Void>)
    func setEditingMode(sessionId: String, mode: EditingModeMsg, reply: @escaping EngineReply<Void>)
    func showSourceFrame(
        sessionId: String, media: ResolvedMediaMsg, mediaURL: URL, sourceTimeUs: Int64,
        reply: @escaping EngineReply<Void>)
    func sampleColor(sessionId: String, itemId: String, x: Double, y: Double, reply: @escaping EngineReply<ColorMsg?>)
    func renderLookStills(
        sessionId: String, itemId: String, looks: [LookSpecMsg], lutURLs: [URL], heightPx: Int64,
        reply: @escaping EngineReply<[Data]>)
    func refresh(sessionId: String, reply: @escaping EngineReply<Void>)
    func debugCaptureFrame(sessionId: String, reply: @escaping EngineReply<Data>)
    /// Idempotent: unknown or disposed sessions succeed.
    func dispose(sessionId: String, reply: @escaping EngineReply<Void>)
}

// MARK: Export (ExportHostApi)

/// Export/ExportCoordinator.swift (IOS-12). Queue: export.
protocol ExportCoordinating: AnyObject {
    func preflight(plan: Data, settings: EncodeSettingsMsg, reply: @escaping EngineReply<ExportPreflightMsg>)
    func start(
        plan: Data, settings: EncodeSettingsMsg, outputURL: URL, title: String, whenDetached: DetachedHandoffMsg,
        reply: @escaping EngineReply<String>)
    func resume(jobId: String, reply: @escaping EngineReply<String>)
    func cancel(jobId: String, reply: @escaping EngineReply<Void>)
    func activeJobs(reply: @escaping EngineReply<[ExportJobRecordMsg]>)
    func consumeJobRecord(jobId: String)
}

// MARK: Recording (RecorderHostApi)

/// Recording/VoiceRecorder.swift (IOS-14). Queues: main for permission/requestPermission/
/// openSettings, recorder for start/stop/cancel.
protocol VoiceRecording: AnyObject {
    func permission(reply: @escaping EngineReply<MicPermissionMsg>)
    func requestPermission(reply: @escaping EngineReply<MicPermissionMsg>)
    func openSettings(reply: @escaping EngineReply<Void>)
    func start(outputURL: URL, reply: @escaping EngineReply<String>)
    func stop(recordingId: String, reply: @escaping EngineReply<RecordedAssetMsg>)
    func cancel(recordingId: String, reply: @escaping EngineReply<Void>)
}

// MARK: Platform (PlatformHostApi)

/// Platform/MediaPicker.swift (IOS-15). Queue: main.
protocol MediaPicking: AnyObject {
    /// An empty list means cancelled.
    func pick(_ request: MediaPickRequestMsg, reply: @escaping EngineReply<[PickedMediaMsg]>)
}

/// Platform/PhotosSaver.swift (IOS-13). Queue: io.
protocol PhotosSaving: AnyObject {
    func saveToPhotos(fileURL: URL, reply: @escaping EngineReply<FileHandoffResultMsg>)
}

/// Platform/FileHandoff.swift (IOS-13). Queue: main.
protocol FileHandingOff: AnyObject {
    func saveToFiles(fileURL: URL, suggestedName: String, reply: @escaping EngineReply<FileHandoffResultMsg>)
    func share(fileURL: URL, reply: @escaping EngineReply<FileHandoffResultMsg>)
}

/// Platform/MediaAccess.swift (IOS-15). Queue: io.
protocol MediaAccessing: AnyObject {
    func createBookmark(fileURL: URL, reply: @escaping EngineReply<Data>)
    func resolveBookmark(_ bookmark: Data, reply: @escaping EngineReply<ResolvedBookmarkMsg>)
    /// Android-only grants: iOS answers without doing anything.
    func persistUriGrant(uri: String, reply: @escaping EngineReply<Void>)
    func releaseUriGrant(uri: String, reply: @escaping EngineReply<Void>)
    func remainingGrantBudget(reply: @escaping EngineReply<Int64>)
    /// Null when the file is missing; `permissionDenied` when access was lost.
    func stat(_ media: MediaRefMsg, fileURL: URL, reply: @escaping EngineReply<MediaStatMsg?>)
    func quickHash(_ media: MediaRefMsg, fileURL: URL, reply: @escaping EngineReply<String>)
    /// [directoryURL] is inside the editor or speech roots (checked by the glue, D-44).
    func excludeFromBackup(directoryURL: URL, reply: @escaping EngineReply<Void>)
}

/// Platform/Permissions.swift (IOS-15). Queue: main.
protocol PermissionRequesting: AnyObject {
    func requestNotificationPermission(reply: @escaping EngineReply<Bool>)
}

/// Platform/BackgroundGuard.swift (IOS-15). Queue: main. `leaseExpiring` events are keyed by the
/// lease id.
protocol BackgroundLeasing: AnyObject {
    /// The lease id, or nil when no lease is available.
    func acquire(title: String, reply: @escaping EngineReply<String?>)
    func update(leaseId: String, progress: Double, reply: @escaping EngineReply<Void>)
    func release(leaseId: String, reply: @escaping EngineReply<Void>)
}

/// Platform/DropTarget.swift (IOS-16). Queue: main. Drops are `drop` events.
protocol DropTargeting: AnyObject {
    func setEnabled(_ enabled: Bool, reply: @escaping EngineReply<Void>)
}
