// OWNER: ENG-08 (frozen by ENG-06, D-42)
//
// `JobsHostApi` glue (ARCH §12.3, §12.6, §15). Thumbnails and jobs run on danaview-jobs (the services
// keep their own worker pools behind it); proxy status on danaview-io. Job progress, results and
// failures travel as events keyed by the returned job id (EventHub).

package com.vecvel.danaview.editor.engine.glue

import com.vecvel.danaview.editor.engine.core.EngineThreads
import com.vecvel.danaview.editor.engine.core.Paths
import com.vecvel.danaview.editor.engine.pigeon.JobPriorityMsg
import com.vecvel.danaview.editor.engine.pigeon.JobRequestMsg
import com.vecvel.danaview.editor.engine.pigeon.JobsHostApi
import com.vecvel.danaview.editor.engine.pigeon.ProxyStatusMsg
import com.vecvel.danaview.editor.engine.pigeon.ThumbPriorityMsg
import com.vecvel.danaview.editor.engine.pigeon.ThumbnailRequestMsg
import com.vecvel.danaview.editor.engine.pigeon.ThumbnailTileMsg

/** `JobsHostApi` handlers. [paths] gives the installed roots (output path checks). */
class JobsHostApiImpl(
    private val threads: EngineThreads,
    private val port: JobsPort,
    private val paths: () -> Paths?,
    private val dispatch: GlueDispatcher = GlueDispatcher(threads.main),
) : JobsHostApi {
    override fun thumbnailTile(
        requestId: String,
        request: ThumbnailRequestMsg,
        priority: ThumbPriorityMsg,
        callback: (Result<ThumbnailTileMsg>) -> Unit,
    ) = dispatch.async(threads.jobs, callback, check = {
        Check.id("requestId", requestId)
        Check.thumbnail(request)
    }) { done -> port.thumbnailTile(requestId, request, priority, done) }

    override fun cancelThumbnail(requestId: String) =
        dispatch.fireAndForget(threads.jobs, "cancelThumbnail", check = { Check.id("requestId", requestId) }) {
            port.cancelThumbnail(requestId)
        }

    override fun startJob(request: JobRequestMsg, callback: (Result<String>) -> Unit) =
        dispatch.async(threads.jobs, callback, check = { Check.job(request, paths()) }) { done -> port.startJob(request, done) }

    override fun cancelJob(jobId: String) =
        dispatch.fireAndForget(threads.jobs, "cancelJob", check = { Check.id("jobId", jobId) }) { port.cancelJob(jobId) }

    override fun setJobPriority(jobId: String, priority: JobPriorityMsg) =
        dispatch.fireAndForget(threads.jobs, "setJobPriority", check = { Check.id("jobId", jobId) }) {
            port.setJobPriority(jobId, priority)
        }

    override fun proxyStatus(fingerprint: String, callback: (Result<ProxyStatusMsg>) -> Unit) =
        dispatch.async(threads.io, callback, check = { Check.id("fingerprint", fingerprint) }) { done ->
            port.proxyStatus(fingerprint, done)
        }
}
