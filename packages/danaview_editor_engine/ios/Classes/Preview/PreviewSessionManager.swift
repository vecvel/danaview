// OWNER: IOS-11
//
// PreviewSessionManager (ARCH §12.2, §12.6, §13.2): the preview sessions of one Flutter engine by
// id. The glue (Glue/PreviewHostApiImpl.swift, ENG-07) calls every method on
// `previewControlQueue` through `PreviewSessionManaging` and builds the manager with
// `init(context:)`; the manager keeps the session table on that queue. Texture registration hops
// to the main thread inside TextureBridge (ARCH §12.7).
//
// Device facts: the tier, `maxPreviewLongSide` and the live decode budget
// (`maxConcurrentVideoLayers`) come from IOS-02's tier table (Capabilities.TierLimits) for this
// device. A session id that is unknown (never opened or disposed) fails with `cancelled`;
// dispose is idempotent.

import Foundation

final class PreviewSessionManager: PreviewSessionManaging {
    private let context: EngineContext
    private var sessions: [String: PreviewSession] = [:]
    /// Builds a session's dependencies (tests inject fixtures, probes and registries).
    var makeDependencies: ((EngineContext, Paths) -> PreviewSession.Dependencies)?

    init(context: EngineContext) {
        self.context = context
    }

    /// The live sessions (tests).
    var sessionIds: [String] { Array(sessions.keys) }

    /// The session [sessionId] (tests).
    func session(_ sessionId: String) -> PreviewSession? { sessions[sessionId] }

    static func defaultDependencies(context: EngineContext, paths: Paths) -> PreviewSession.Dependencies {
        let profile = DeviceProfile.current(hasMetal: true)
        let limits = Capabilities.TierLimits.of(profile.tier)
        var d = PreviewSession.Dependencies(
            registry: context.textures.map { FlutterTextureRegistryAdapter($0) }, events: context.events,
            spacerDirectory: paths.engineAssets)
        d.tier = profile.tier
        d.maxPreviewLongSide = Int(limits.maxPreviewLongSide)
        d.liveDecodeBudget = Int(limits.maxConcurrentVideoLayers)
        return d
    }

    private func with(_ sessionId: String, _ fail: (Error) -> Void, _ body: (PreviewSession) -> Void) {
        guard let s = sessions[sessionId] else {
            fail(EngineError(.cancelled, "preview session is not open"))
            return
        }
        body(s)
    }

    func open(_ config: PreviewConfigMsg, reply: @escaping EngineReply<PreviewOpenedMsg>) {
        let paths: Paths
        do { paths = try context.requirePaths() } catch { return reply(.failure(error)) }
        let deps = makeDependencies?(context, paths) ?? PreviewSessionManager.defaultDependencies(context: context, paths: paths)
        let id = "pv_" + UUID().uuidString.lowercased()
        let session: PreviewSession
        do {
            session = try PreviewSession(id: id, config: config, queue: context.queues.previewControl, dependencies: deps)
        } catch {
            return reply(.failure(EngineError(.gpuUnavailable, "preview renderer unavailable: \(EngineError.from(error).message)")))
        }
        sessions[id] = session
        let queue = context.queues.previewControl
        session.registerTexture { textureId in
            queue.async { reply(.success(PreviewOpenedMsg(sessionId: id, textureId: textureId))) }
        }
    }

    func setPlan(sessionId: String, plan: Data, reply: @escaping EngineReply<PlanAckMsg>) {
        with(sessionId, { reply(.failure($0)) }) { $0.setPlan(plan, reply: reply) }
    }

    func applyPatch(sessionId: String, patch: Data, reply: @escaping EngineReply<PlanAckMsg>) {
        with(sessionId, { reply(.failure($0)) }) { $0.applyPatch(patch, reply: reply) }
    }

    func setTransient(sessionId: String, itemId: String, params: Data) {
        sessions[sessionId]?.setTransient(itemId: itemId, params: params)
    }

    func clearTransient(sessionId: String, itemId: String) {
        sessions[sessionId]?.clearTransient(itemId: itemId)
    }

    func play(sessionId: String, loop: LoopMsg?, reply: @escaping EngineReply<Int64>) {
        with(sessionId, { reply(.failure($0)) }) { $0.play(loop: loop, reply: reply) }
    }

    func pause(sessionId: String, reply: @escaping EngineReply<Int64>) {
        with(sessionId, { reply(.failure($0)) }) { $0.pause(reply: reply) }
    }

    func seek(sessionId: String, timeUs: Int64, exact: Bool, reply: @escaping EngineReply<SeekAckMsg>) {
        with(sessionId, { reply(.failure($0)) }) { $0.seek(timeUs: timeUs, exact: exact, reply: reply) }
    }

    func setQuality(sessionId: String, quality: PreviewQualityMsg, reply: @escaping EngineReply<Void>) {
        with(sessionId, { reply(.failure($0)) }) { $0.setQuality(quality, reply: reply) }
    }

    func setUseProxies(sessionId: String, on: Bool, reply: @escaping EngineReply<Void>) {
        with(sessionId, { reply(.failure($0)) }) { $0.setUseProxies(on, reply: reply) }
    }

    func setEditingMode(sessionId: String, mode: EditingModeMsg, reply: @escaping EngineReply<Void>) {
        with(sessionId, { reply(.failure($0)) }) { $0.setEditingMode(mode, reply: reply) }
    }

    func showSourceFrame(
        sessionId: String, media: ResolvedMediaMsg, mediaURL: URL, sourceTimeUs: Int64,
        reply: @escaping EngineReply<Void>
    ) {
        with(sessionId, { reply(.failure($0)) }) {
            $0.showSourceFrame(media: media, mediaURL: mediaURL, sourceTimeUs: sourceTimeUs, reply: reply)
        }
    }

    func sampleColor(sessionId: String, itemId: String, x: Double, y: Double, reply: @escaping EngineReply<ColorMsg?>) {
        with(sessionId, { reply(.failure($0)) }) { $0.sampleColor(itemId: itemId, x: x, y: y, reply: reply) }
    }

    func renderLookStills(
        sessionId: String, itemId: String, looks: [LookSpecMsg], lutURLs: [URL], heightPx: Int64,
        reply: @escaping EngineReply<[Data]>
    ) {
        with(sessionId, { reply(.failure($0)) }) {
            $0.renderLookStills(itemId: itemId, looks: looks, lutURLs: lutURLs, heightPx: heightPx, reply: reply)
        }
    }

    func refresh(sessionId: String, reply: @escaping EngineReply<Void>) {
        with(sessionId, { reply(.failure($0)) }) { $0.refresh(reply: reply) }
    }

    func debugCaptureFrame(sessionId: String, reply: @escaping EngineReply<Data>) {
        with(sessionId, { reply(.failure($0)) }) { $0.debugCaptureFrame(reply: reply) }
    }

    /// Idempotent: unknown or disposed sessions succeed.
    func dispose(sessionId: String, reply: @escaping EngineReply<Void>) {
        guard let s = sessions.removeValue(forKey: sessionId) else { return reply(.success(())) }
        s.dispose { reply(.success(())) }
    }
}
