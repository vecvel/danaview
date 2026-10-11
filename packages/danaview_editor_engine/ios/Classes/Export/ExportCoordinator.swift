// OWNER: IOS-12
//
// D-33 placeholder created by ENG-07: export jobs (ARCH §12.4, §14.2, D-22, D-39).
// Only IOS-12 edits this file once it lands.
// The glue calls it through `ExportCoordinating` (Glue/ServiceProtocols.swift) and builds it with
// `init(context:)` (Glue/EngineServices.swift): keep both. Until then every call fails with
// `notSupportedOnDevice`, which Dart maps to the editor's unsupported state.

import Foundation

final class ExportCoordinator: ExportCoordinating {
    private let context: EngineContext

    init(context: EngineContext) {
        self.context = context
    }

    func preflight(plan: Data, settings: EncodeSettingsMsg, reply: @escaping EngineReply<ExportPreflightMsg>) {
        reply(.failure(EngineError.notSupportedOnDevice("Export")))
    }

    func start(
        plan: Data, settings: EncodeSettingsMsg, outputURL: URL, title: String, whenDetached: DetachedHandoffMsg,
        reply: @escaping EngineReply<String>
    ) {
        reply(.failure(EngineError.notSupportedOnDevice("Export")))
    }

    func resume(jobId: String, reply: @escaping EngineReply<String>) {
        reply(.failure(EngineError.notSupportedOnDevice("Export")))
    }

    /// No export runs yet, so cancelling succeeds.
    func cancel(jobId: String, reply: @escaping EngineReply<Void>) {
        reply(.success(()))
    }

    func activeJobs(reply: @escaping EngineReply<[ExportJobRecordMsg]>) {
        reply(.failure(EngineError.notSupportedOnDevice("Export")))
    }

    /// No records exist yet.
    func consumeJobRecord(jobId: String) {}
}
