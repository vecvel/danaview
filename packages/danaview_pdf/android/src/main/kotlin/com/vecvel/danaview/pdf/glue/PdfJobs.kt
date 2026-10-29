// OWNER: HOM-28A
//
// The tool jobs of PdfToolsHostApi on Android (as darwin/Classes/Glue/PdfJobs.swift): a job per
// request id, with a cancel flag any thread may set and progress sent as `toolProgress` events
// (glue/PdfEventHub). Every tool (page tools HOM-28A, annotate HOM-29A, sign HOM-30A, compress
// HOM-31A) and PdfOrganiseHostApi share one registry, so `PdfToolsHostApi.cancel(jobId)` reaches
// any of them.

package com.vecvel.danaview.pdf.glue

import com.vecvel.danaview.pdf.pigeon.PdfToolKindMsg
import com.vecvel.danaview.pdf.pigeon.PdfToolProgressMsg
import com.vecvel.danaview.pdf.tools.PdfToolControl
import java.util.concurrent.atomic.AtomicBoolean

/** One running tool job. */
class PdfJob(val id: String, val tool: PdfToolKindMsg, private val onProgress: (PdfToolProgressMsg) -> Unit) : PdfToolControl {
    private val cancelled = AtomicBoolean(false)

    /** True after [cancel] (any thread). */
    override val isCancelled: Boolean get() = cancelled.get()

    fun cancel() = cancelled.set(true)

    /** Reports [done] of [total] pages (any thread). */
    override fun progress(done: Int, total: Int) {
        val fraction = if (total > 0) (done.toDouble() / total).coerceIn(0.0, 1.0) else 0.0
        onProgress(PdfToolProgressMsg(id, tool, fraction, done.toLong(), total.toLong()))
    }

    /**
     * Reports [fraction] (0…1) directly, for a tool whose work is not page by page (compress);
     * [pagesDone] and [pagesTotal] are 0 while unknown.
     */
    fun progress(fraction: Double, pagesDone: Int, pagesTotal: Int) {
        val clamped = if (fraction.isFinite()) fraction.coerceIn(0.0, 1.0) else 0.0
        onProgress(PdfToolProgressMsg(id, tool, clamped, pagesDone.toLong(), pagesTotal.toLong()))
    }
}

/** The running jobs by id; [emit] sends a progress event (from any thread). */
class PdfJobRegistry(private val emit: (PdfToolProgressMsg) -> Unit) {
    private val jobs = HashMap<String, PdfJob>()

    /** Starts job [id] of [tool]; an empty id or the id of a running job answers `invalidArgument`. */
    fun start(id: String, tool: PdfToolKindMsg): PdfJob {
        if (id.isEmpty()) throw PdfFailure.invalid("empty job id")
        synchronized(jobs) {
            if (jobs.containsKey(id)) throw PdfFailure.invalid("job id in use")
            return PdfJob(id, tool, emit).also { jobs[id] = it }
        }
    }

    fun finish(job: PdfJob) {
        synchronized(jobs) {
            if (jobs[job.id] === job) jobs.remove(job.id)
        }
    }

    /** Cancels [id] if it runs. */
    fun cancel(id: String) {
        synchronized(jobs) { jobs[id] }?.cancel()
    }

    val runningCount: Int get() = synchronized(jobs) { jobs.size }
}
