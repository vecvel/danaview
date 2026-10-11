// OWNER: ENG-07 (frozen by ENG-06)
//
// Glue of `JobsHostApi` (ARCH §12.3, §12.6, §15): thumbnails (IOS-03), media jobs (IOS-05
// JobRegistry, which runs IOS-04/05/06/07 jobs) and proxy status (IOS-05). Job progress, results
// and failures are events keyed by the returned job id.

import Foundation

final class JobsHostApiImpl: JobsHostApi {
    private let context: EngineContext
    private let services: EngineServices

    init(context: EngineContext, services: EngineServices) {
        self.context = context
        self.services = services
    }

    private var queue: DispatchQueue { context.queues.jobs }

    func thumbnailTile(
        requestId: String, request: ThumbnailRequestMsg, priority: ThumbPriorityMsg,
        completion: @escaping (Result<ThumbnailTileMsg, Error>) -> Void
    ) {
        GlueDispatch.hop(
            "jobs.thumbnailTile", on: queue, completion: completion,
            validate: { () -> URL in
                _ = try context.requirePaths()
                try Validate.id(requestId, "requestId")
                return try Validate.thumbnailRequest(request)
            }
        ) { [thumbnails = services.thumbnails] url, reply in
            thumbnails.tile(requestId: requestId, request: request, mediaURL: url, priority: priority, reply: reply)
        }
    }

    func cancelThumbnail(requestId: String) throws {
        try GlueDispatch.post(
            "jobs.cancelThumbnail", on: queue,
            validate: { try Validate.id(requestId, "requestId") }
        ) { [thumbnails = services.thumbnails] _ in
            thumbnails.cancel(requestId: requestId)
        }
    }

    func startJob(request: JobRequestMsg, completion: @escaping (Result<String, Error>) -> Void) {
        GlueDispatch.hop(
            "jobs.startJob", on: queue, completion: completion,
            validate: { try Validate.jobRequest(request, paths: context.requirePaths()) }
        ) { [jobs = services.jobs] urls, reply in
            jobs.start(request, mediaURL: urls.media, outputURL: urls.output, reply: reply)
        }
    }

    func cancelJob(jobId: String) throws {
        try GlueDispatch.post(
            "jobs.cancelJob", on: queue,
            validate: { try Validate.id(jobId, "jobId") }
        ) { [jobs = services.jobs] _ in
            jobs.cancel(jobId: jobId)
        }
    }

    func setJobPriority(jobId: String, priority: JobPriorityMsg) throws {
        try GlueDispatch.post(
            "jobs.setJobPriority", on: queue,
            validate: { try Validate.id(jobId, "jobId") }
        ) { [jobs = services.jobs] _ in
            jobs.setPriority(jobId: jobId, priority: priority)
        }
    }

    func proxyStatus(fingerprint: String, completion: @escaping (Result<ProxyStatusMsg, Error>) -> Void) {
        GlueDispatch.hop(
            "jobs.proxyStatus", on: queue, completion: completion,
            validate: { try Validate.id(fingerprint, "fingerprint") }
        ) { [proxies = services.proxies] _, reply in
            proxies.status(fingerprint: fingerprint, reply: reply)
        }
    }
}
