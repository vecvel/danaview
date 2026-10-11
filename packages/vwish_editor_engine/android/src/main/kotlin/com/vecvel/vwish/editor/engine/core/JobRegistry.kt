// OWNER: AND-05
//
// D-33 placeholder created by ENG-08 (BUILD_PLAN ENG-08, ARCH §4.4). It holds only the names the
// glue calls; every call fails with `notSupportedOnDevice` (the Dart side maps that to the editor's
// unsupported state). The owner ticket replaces this file and keeps the signatures the glue uses.
// AND-05: job ids, priorities, concurrency by tier, pre-emption by export and interactive jobs,
// progress (ctx.events.progress), cancellation cleaning `.part` outputs, and dispatch by kind to
// WaveformService / SpeechAudioExtractor (AND-04), ProxyJob (AND-05), FreezeFrameJob (AND-06) and
// ReverseJob (AND-07), finishing with ctx.events.jobDone / jobFailed.

package com.vecvel.vwish.editor.engine.core

import com.vecvel.vwish.editor.engine.pigeon.JobPriorityMsg
import com.vecvel.vwish.editor.engine.pigeon.JobRequestMsg

/** Media job registry (ARCH §12.3, §15; AND-05). Called on vwish-jobs. */
class JobRegistry(private val ctx: EngineContext) {
    /** Starts a job of [request]'s kind (never `export`) and completes with its id. */
    fun start(request: JobRequestMsg, done: Completion<String>) {
        done.fail(EngineErrors.notSupported("media jobs"))
    }

    /** Cancels [jobId]; the job ends with a `cancelled` failure event. Unknown ids are ignored. */
    fun cancel(jobId: String) = Unit

    /** Changes the priority of [jobId]. Unknown ids are ignored. */
    fun setPriority(jobId: String, priority: JobPriorityMsg) = Unit
}
