// OWNER: IOS-11
//
// D-33 placeholder created by ENG-07: preview sessions by id (ARCH §12.2, §13.2).
// Only IOS-11 edits this file once it lands.
// The glue calls it through `PreviewSessionManaging` (Glue/ServiceProtocols.swift) and builds it with
// `init(context:)` (Glue/EngineServices.swift): keep both. Until then every call fails with
// `notSupportedOnDevice`, which Dart maps to the editor's unsupported state.

import Foundation

final class PreviewSessionManager: PreviewSessionManaging {
    private let context: EngineContext

    init(context: EngineContext) {
        self.context = context
    }

    func open(_ config: PreviewConfigMsg, reply: @escaping EngineReply<PreviewOpenedMsg>) {
        reply(.failure(EngineError.notSupportedOnDevice("Preview")))
    }

    func setPlan(sessionId: String, plan: Data, reply: @escaping EngineReply<PlanAckMsg>) {
        reply(.failure(EngineError.notSupportedOnDevice("Preview")))
    }

    func applyPatch(sessionId: String, patch: Data, reply: @escaping EngineReply<PlanAckMsg>) {
        reply(.failure(EngineError.notSupportedOnDevice("Preview")))
    }

    func setTransient(sessionId: String, itemId: String, params: Data) {}

    func clearTransient(sessionId: String, itemId: String) {}

    func play(sessionId: String, loop: LoopMsg?, reply: @escaping EngineReply<Int64>) {
        reply(.failure(EngineError.notSupportedOnDevice("Preview")))
    }

    func pause(sessionId: String, reply: @escaping EngineReply<Int64>) {
        reply(.failure(EngineError.notSupportedOnDevice("Preview")))
    }

    func seek(sessionId: String, timeUs: Int64, exact: Bool, reply: @escaping EngineReply<SeekAckMsg>) {
        reply(.failure(EngineError.notSupportedOnDevice("Preview")))
    }

    func setQuality(sessionId: String, quality: PreviewQualityMsg, reply: @escaping EngineReply<Void>) {
        reply(.failure(EngineError.notSupportedOnDevice("Preview")))
    }

    func setUseProxies(sessionId: String, on: Bool, reply: @escaping EngineReply<Void>) {
        reply(.failure(EngineError.notSupportedOnDevice("Preview")))
    }

    func setEditingMode(sessionId: String, mode: EditingModeMsg, reply: @escaping EngineReply<Void>) {
        reply(.failure(EngineError.notSupportedOnDevice("Preview")))
    }

    func showSourceFrame(
        sessionId: String, media: ResolvedMediaMsg, mediaURL: URL, sourceTimeUs: Int64,
        reply: @escaping EngineReply<Void>
    ) {
        reply(.failure(EngineError.notSupportedOnDevice("Preview")))
    }

    func sampleColor(sessionId: String, itemId: String, x: Double, y: Double, reply: @escaping EngineReply<ColorMsg?>) {
        reply(.failure(EngineError.notSupportedOnDevice("Preview")))
    }

    func renderLookStills(
        sessionId: String, itemId: String, looks: [LookSpecMsg], lutURLs: [URL], heightPx: Int64,
        reply: @escaping EngineReply<[Data]>
    ) {
        reply(.failure(EngineError.notSupportedOnDevice("Preview")))
    }

    func refresh(sessionId: String, reply: @escaping EngineReply<Void>) {
        reply(.failure(EngineError.notSupportedOnDevice("Preview")))
    }

    func debugCaptureFrame(sessionId: String, reply: @escaping EngineReply<Data>) {
        reply(.failure(EngineError.notSupportedOnDevice("Preview")))
    }

    /// Idempotent: no session exists yet, so disposing succeeds.
    func dispose(sessionId: String, reply: @escaping EngineReply<Void>) {
        reply(.success(()))
    }
}
