// OWNER: ENG-07 (frozen by ENG-06)
//
// Glue of `ExportHostApi` (ARCH §12.4, §12.6, §14.2, D-22, D-39): validate on main, hop to the
// export control queue, delegate to ExportCoordinator (IOS-12; background and records IOS-13).
// The output path must lie inside the editor roots (`<cache>/danaview/editor/work/export-<id>.<ext>`).
// INT-07: `start` carries optional localized notification texts; iOS shows no export notification,
// so they are only validated (bounded text) and otherwise ignored.

import Flutter
import Foundation

final class ExportHostApiImpl: ExportHostApi {
    private let context: EngineContext
    private let services: EngineServices

    init(context: EngineContext, services: EngineServices) {
        self.context = context
        self.services = services
    }

    private var queue: DispatchQueue { context.queues.export }

    func preflight(
        plan: FlutterStandardTypedData, settings: EncodeSettingsMsg,
        completion: @escaping (Result<ExportPreflightMsg, Error>) -> Void
    ) {
        GlueDispatch.hop(
            "export.preflight", on: queue, completion: completion,
            validate: { () -> Data in
                try Validate.encodeSettings(settings)
                return try Validate.plan(plan, "plan")
            }
        ) { [exports = services.exports] bytes, reply in
            exports.preflight(plan: bytes, settings: settings, reply: reply)
        }
    }

    func start(
        plan: FlutterStandardTypedData, settings: EncodeSettingsMsg, outputPath: String, title: String,
        whenDetached: DetachedHandoffMsg, texts: ExportNotificationTextsMsg?,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        GlueDispatch.hop(
            "export.start", on: queue, completion: completion,
            validate: { () -> (Data, URL) in
                try Validate.encodeSettings(settings)
                try Validate.text(title, "title")
                if let texts = texts { try Validate.notificationTexts(texts) }
                let bytes = try Validate.plan(plan, "plan")
                let output = try context.requirePaths().requireWritable(outputPath, name: "outputPath")
                return (bytes, output)
            }
        ) { [exports = services.exports] value, reply in
            exports.start(
                plan: value.0, settings: settings, outputURL: value.1, title: title, whenDetached: whenDetached,
                reply: reply)
        }
    }

    func resume(jobId: String, completion: @escaping (Result<String, Error>) -> Void) {
        GlueDispatch.hop(
            "export.resume", on: queue, completion: completion,
            validate: { try Validate.id(jobId, "jobId") }
        ) { [exports = services.exports] _, reply in
            exports.resume(jobId: jobId, reply: reply)
        }
    }

    func cancel(jobId: String, completion: @escaping (Result<Void, Error>) -> Void) {
        GlueDispatch.hop(
            "export.cancel", on: queue, completion: completion,
            validate: { try Validate.id(jobId, "jobId") }
        ) { [exports = services.exports] _, reply in
            exports.cancel(jobId: jobId, reply: reply)
        }
    }

    func activeJobs(completion: @escaping (Result<[ExportJobRecordMsg], Error>) -> Void) {
        GlueDispatch.hop("export.activeJobs", on: queue, completion: completion) { [exports = services.exports] reply in
            exports.activeJobs(reply: reply)
        }
    }

    func consumeJobRecord(jobId: String) throws {
        try GlueDispatch.post(
            "export.consumeJobRecord", on: queue,
            validate: { try Validate.id(jobId, "jobId") }
        ) { [exports = services.exports] _ in
            exports.consumeJobRecord(jobId: jobId)
        }
    }
}
