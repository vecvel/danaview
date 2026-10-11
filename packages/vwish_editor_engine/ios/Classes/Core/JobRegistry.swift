// OWNER: IOS-05
//
// D-33 placeholder created by ENG-07: media job registry, priorities and concurrency (ARCH §15, D-22).
// Only IOS-05 edits this file once it lands.
// The glue calls it through `JobScheduling` (Glue/ServiceProtocols.swift) and builds it with
// `init(context:)` (Glue/EngineServices.swift): keep both. Until then every call fails with
// `notSupportedOnDevice`, which Dart maps to the editor's unsupported state.

import Foundation

final class JobRegistry: JobScheduling {
    private let context: EngineContext

    init(context: EngineContext) {
        self.context = context
    }

    func start(_ request: JobRequestMsg, mediaURL: URL, outputURL: URL?, reply: @escaping EngineReply<String>) {
        reply(.failure(EngineError.notSupportedOnDevice("Media jobs")))
    }

    /// No jobs exist yet.
    func cancel(jobId: String) {}

    /// No jobs exist yet.
    func setPriority(jobId: String, priority: JobPriorityMsg) {}
}
