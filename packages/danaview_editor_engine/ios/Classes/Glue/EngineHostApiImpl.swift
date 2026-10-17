// OWNER: ENG-07 (frozen by ENG-06)
//
// Glue of `EngineHostApi` (ARCH §12.1, §12.6): validate on main, hop to the engine queue,
// delegate, reply asynchronously. `initialize` and `freeBytes` are engine core and implemented
// here; the rest delegates to the IOS-02/IOS-03 services. The localized export notification texts
// of `initialize` (INT-07) are validated and ignored: iOS shows no export notification.

import Foundation

final class EngineHostApiImpl: EngineHostApi {
    private let context: EngineContext
    private let services: EngineServices

    init(context: EngineContext, services: EngineServices) {
        self.context = context
        self.services = services
    }

    private var queue: DispatchQueue { context.queues.engine }

    func initialize(config: EngineConfigMsg, completion: @escaping (Result<Void, Error>) -> Void) {
        GlueDispatch.hop(
            "initialize", on: queue, completion: completion,
            validate: { () -> Paths in
                if let texts = config.exportTexts { try Validate.notificationTexts(texts) }
                return try Paths(cacheRoot: config.cacheRoot, supportRoot: config.supportRoot)
            }
        ) { [context = self.context, services = self.services] _, reply in
            let changed = try context.configure(cacheRoot: config.cacheRoot, supportRoot: config.supportRoot)
            let paths = try context.requirePaths()
            try paths.ensureDirectory(paths.cacheRoot)
            try paths.ensureDirectory(paths.supportRoot)
            if changed {
                Log.info(.engine, "initialized")
                services.caches.engineDidInitialize(paths: paths)
            }
            reply(.success(()))
        }
    }

    func capabilities(completion: @escaping (Result<CapabilitiesMsg, Error>) -> Void) {
        GlueDispatch.hop("capabilities", on: queue, completion: completion) { [services = self.services] reply in
            services.capabilities.capabilities(reply: reply)
        }
    }

    func compatibility(uri: String, completion: @escaping (Result<CompatibilityMsg, Error>) -> Void) {
        GlueDispatch.hop(
            "compatibility", on: queue, completion: completion,
            validate: { try Paths.fileURL(fromPathOrUri: uri, name: "uri") }
        ) { [services = self.services] url, reply in
            services.compatibility.compatibility(of: url, reply: reply)
        }
    }

    func probe(media: ResolvedMediaMsg, completion: @escaping (Result<ProbeMsg, Error>) -> Void) {
        GlueDispatch.hop(
            "probe", on: queue, completion: completion,
            validate: { try Validate.media(media) }
        ) { [services = self.services] url, reply in
            services.probe.probe(media, url: url, reply: reply)
        }
    }

    func freeBytes(path: String, completion: @escaping (Result<Int64, Error>) -> Void) {
        GlueDispatch.hop(
            "freeBytes", on: queue, completion: completion,
            validate: { try Paths.absoluteURL(path, name: "path") }
        ) { url, reply in
            reply(.success(try Paths.freeBytes(at: url.path)))
        }
    }

    func trimCaches(level: CacheTrimLevelMsg) throws {
        try GlueDispatch.post("trimCaches", on: queue, validate: { level }) { [services = self.services] level in
            services.caches.trim(level)
        }
    }
}
