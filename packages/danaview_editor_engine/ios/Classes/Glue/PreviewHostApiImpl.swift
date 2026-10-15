// OWNER: ENG-07 (frozen by ENG-06; amended by INT-06)
//
// Glue of `PreviewHostApi` (ARCH §12.2, §12.6, §13.2): validate on main, hop to
// `previewControlQueue`, delegate to PreviewSessionManager (IOS-11), reply asynchronously.
// `setRenderedRanges` (D-45, INT-06) goes to the rendered-range handler (IOS-19).
// `setTransient`/`clearTransient` are fire-and-forget; the manager coalesces them to one per frame.

import Flutter
import Foundation

final class PreviewHostApiImpl: PreviewHostApi {
    private let context: EngineContext
    private let services: EngineServices

    init(context: EngineContext, services: EngineServices) {
        self.context = context
        self.services = services
    }

    private var queue: DispatchQueue { context.queues.previewControl }
    private var manager: PreviewSessionManaging { services.previews }

    func open(config: PreviewConfigMsg, completion: @escaping (Result<PreviewOpenedMsg, Error>) -> Void) {
        GlueDispatch.hop(
            "preview.open", on: queue, completion: completion,
            validate: {
                _ = try context.requirePaths()
                try Validate.previewConfig(config)
            }
        ) { [manager = self.manager] _, reply in
            manager.open(config, reply: reply)
        }
    }

    func setPlan(sessionId: String, plan: FlutterStandardTypedData, completion: @escaping (Result<PlanAckMsg, Error>) -> Void) {
        GlueDispatch.hop(
            "preview.setPlan", on: queue, completion: completion,
            validate: { () -> Data in
                try Validate.id(sessionId, "sessionId")
                return try Validate.plan(plan, "plan")
            }
        ) { [manager = self.manager] bytes, reply in
            manager.setPlan(sessionId: sessionId, plan: bytes, reply: reply)
        }
    }

    func applyPatch(sessionId: String, patch: FlutterStandardTypedData, completion: @escaping (Result<PlanAckMsg, Error>) -> Void) {
        GlueDispatch.hop(
            "preview.applyPatch", on: queue, completion: completion,
            validate: { () -> Data in
                try Validate.id(sessionId, "sessionId")
                return try Validate.plan(patch, "patch")
            }
        ) { [manager = self.manager] bytes, reply in
            manager.applyPatch(sessionId: sessionId, patch: bytes, reply: reply)
        }
    }

    func setTransient(sessionId: String, itemId: String, params: FlutterStandardTypedData) throws {
        try GlueDispatch.post(
            "preview.setTransient", on: queue,
            validate: { () -> Data in
                try Validate.id(sessionId, "sessionId")
                try Validate.id(itemId, "itemId")
                return try Validate.transient(params)
            }
        ) { [manager = self.manager] bytes in
            manager.setTransient(sessionId: sessionId, itemId: itemId, params: bytes)
        }
    }

    func clearTransient(sessionId: String, itemId: String) throws {
        try GlueDispatch.post(
            "preview.clearTransient", on: queue,
            validate: {
                try Validate.id(sessionId, "sessionId")
                try Validate.id(itemId, "itemId")
            }
        ) { [manager = self.manager] _ in
            manager.clearTransient(sessionId: sessionId, itemId: itemId)
        }
    }

    func play(sessionId: String, loop: LoopMsg?, completion: @escaping (Result<Int64, Error>) -> Void) {
        GlueDispatch.hop(
            "preview.play", on: queue, completion: completion,
            validate: {
                try Validate.id(sessionId, "sessionId")
                try Validate.loop(loop)
            }
        ) { [manager = self.manager] _, reply in
            manager.play(sessionId: sessionId, loop: loop, reply: reply)
        }
    }

    func pause(sessionId: String, completion: @escaping (Result<Int64, Error>) -> Void) {
        GlueDispatch.hop(
            "preview.pause", on: queue, completion: completion,
            validate: { try Validate.id(sessionId, "sessionId") }
        ) { [manager = self.manager] _, reply in
            manager.pause(sessionId: sessionId, reply: reply)
        }
    }

    func seek(sessionId: String, timeUs: Int64, exact: Bool, completion: @escaping (Result<SeekAckMsg, Error>) -> Void) {
        GlueDispatch.hop(
            "preview.seek", on: queue, completion: completion,
            validate: {
                try Validate.id(sessionId, "sessionId")
                try Validate.timeUs(timeUs, "timeUs")
            }
        ) { [manager = self.manager] _, reply in
            manager.seek(sessionId: sessionId, timeUs: timeUs, exact: exact, reply: reply)
        }
    }

    func setQuality(sessionId: String, quality: PreviewQualityMsg, completion: @escaping (Result<Void, Error>) -> Void) {
        GlueDispatch.hop(
            "preview.setQuality", on: queue, completion: completion,
            validate: { try Validate.id(sessionId, "sessionId") }
        ) { [manager = self.manager] _, reply in
            manager.setQuality(sessionId: sessionId, quality: quality, reply: reply)
        }
    }

    func setUseProxies(sessionId: String, on: Bool, completion: @escaping (Result<Void, Error>) -> Void) {
        GlueDispatch.hop(
            "preview.setUseProxies", on: queue, completion: completion,
            validate: { try Validate.id(sessionId, "sessionId") }
        ) { [manager = self.manager] _, reply in
            manager.setUseProxies(sessionId: sessionId, on: on, reply: reply)
        }
    }

    func setRenderedRanges(sessionId: String, ranges: [RenderedRangeMsg], completion: @escaping (Result<Void, Error>) -> Void) {
        GlueDispatch.hop(
            "preview.setRenderedRanges", on: queue, completion: completion,
            validate: { () -> [URL] in
                try Validate.id(sessionId, "sessionId")
                return try Validate.renderedRanges(ranges, paths: context.requirePaths())
            }
        ) { [handler = services.renderedRanges] urls, reply in
            handler.setRenderedRanges(sessionId: sessionId, ranges: ranges, fileURLs: urls, reply: reply)
        }
    }

    func setEditingMode(sessionId: String, mode: EditingModeMsg, completion: @escaping (Result<Void, Error>) -> Void) {
        GlueDispatch.hop(
            "preview.setEditingMode", on: queue, completion: completion,
            validate: {
                try Validate.id(sessionId, "sessionId")
                try Validate.editingMode(mode)
            }
        ) { [manager = self.manager] _, reply in
            manager.setEditingMode(sessionId: sessionId, mode: mode, reply: reply)
        }
    }

    func showSourceFrame(
        sessionId: String, media: ResolvedMediaMsg, sourceTimeUs: Int64, completion: @escaping (Result<Void, Error>) -> Void
    ) {
        GlueDispatch.hop(
            "preview.showSourceFrame", on: queue, completion: completion,
            validate: { () -> URL in
                try Validate.id(sessionId, "sessionId")
                try Validate.timeUs(sourceTimeUs, "sourceTimeUs")
                return try Validate.media(media)
            }
        ) { [manager = self.manager] url, reply in
            manager.showSourceFrame(sessionId: sessionId, media: media, mediaURL: url, sourceTimeUs: sourceTimeUs, reply: reply)
        }
    }

    func sampleColor(
        sessionId: String, itemId: String, x: Double, y: Double, completion: @escaping (Result<ColorMsg?, Error>) -> Void
    ) {
        GlueDispatch.hop(
            "preview.sampleColor", on: queue, completion: completion,
            validate: {
                try Validate.id(sessionId, "sessionId")
                try Validate.id(itemId, "itemId")
                try Validate.unit(x, "x")
                try Validate.unit(y, "y")
            }
        ) { [manager = self.manager] _, reply in
            manager.sampleColor(sessionId: sessionId, itemId: itemId, x: x, y: y, reply: reply)
        }
    }

    func renderLookStills(
        sessionId: String, itemId: String, looks: [LookSpecMsg], heightPx: Int64,
        completion: @escaping (Result<[FlutterStandardTypedData], Error>) -> Void
    ) {
        GlueDispatch.hop(
            "preview.renderLookStills", on: queue, completion: completion,
            validate: { () -> [URL] in
                try Validate.id(sessionId, "sessionId")
                try Validate.id(itemId, "itemId")
                try Validate.int(heightPx, "heightPx", 16...2048)
                return try Validate.looks(looks, paths: context.requirePaths())
            }
        ) { [manager = self.manager] urls, reply in
            manager.renderLookStills(sessionId: sessionId, itemId: itemId, looks: looks, lutURLs: urls, heightPx: heightPx) {
                reply($0.map { stills in stills.map { FlutterStandardTypedData(bytes: $0) } })
            }
        }
    }

    func refresh(sessionId: String, completion: @escaping (Result<Void, Error>) -> Void) {
        GlueDispatch.hop(
            "preview.refresh", on: queue, completion: completion,
            validate: { try Validate.id(sessionId, "sessionId") }
        ) { [manager = self.manager] _, reply in
            manager.refresh(sessionId: sessionId, reply: reply)
        }
    }

    func debugCaptureFrame(sessionId: String, completion: @escaping (Result<FlutterStandardTypedData, Error>) -> Void) {
        GlueDispatch.hop(
            "preview.debugCaptureFrame", on: queue, completion: completion,
            validate: { try Validate.id(sessionId, "sessionId") }
        ) { [manager = self.manager] _, reply in
            manager.debugCaptureFrame(sessionId: sessionId) { reply($0.map { FlutterStandardTypedData(bytes: $0) }) }
        }
    }

    func dispose(sessionId: String, completion: @escaping (Result<Void, Error>) -> Void) {
        GlueDispatch.hop(
            "preview.dispose", on: queue, completion: completion,
            validate: { try Validate.id(sessionId, "sessionId") }
        ) { [manager = self.manager, context = self.context] _, reply in
            manager.dispose(sessionId: sessionId) { result in
                context.events.releaseSession(sessionId)
                reply(result)
            }
        }
    }
}
