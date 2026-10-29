// OWNER: HOM-25
// EXTENDED: HOM-28A (jobs with cancel and progress events, glue/PdfJobs.kt; the page tools and
// PdfOrganiseHostApi on the tools thread).
//
// PdfToolsHostApi on Android: routes each tool to the class of its ticket - tools/PdfPageTools
// (HOM-28A: merge, split, reorder, rotate, delete, and PdfOrganiseHostApi.organise; jobs here, in
// [jobs] on the tools pool), annotate/PdfAnnotator (HOM-29A), sign/PdfSigner (HOM-30A),
// compress/PdfCompressor (HOM-31A, landed: [compressor], which still runs its own jobs and thread).
// cancel(jobId) reaches both. A tool that hasn't landed answers notSupportedOnDevice. The write
// engine is PdfBox-Android (HOM-27). Replies hop back to the main thread.

package com.vecvel.danaview.pdf.glue

import com.vecvel.danaview.pdf.annotate.PdfAnnotator
import com.vecvel.danaview.pdf.compress.PdfCompressor
import com.vecvel.danaview.pdf.pigeon.PdfAnnotateRequestMsg
import com.vecvel.danaview.pdf.pigeon.PdfCompressRequestMsg
import com.vecvel.danaview.pdf.pigeon.PdfDeletePagesRequestMsg
import com.vecvel.danaview.pdf.pigeon.PdfEventKindMsg
import com.vecvel.danaview.pdf.pigeon.PdfEventMsg
import com.vecvel.danaview.pdf.pigeon.PdfMergeRequestMsg
import com.vecvel.danaview.pdf.pigeon.PdfOrganiseHostApi
import com.vecvel.danaview.pdf.pigeon.PdfOrganiseRequestMsg
import com.vecvel.danaview.pdf.pigeon.PdfReorderRequestMsg
import com.vecvel.danaview.pdf.pigeon.PdfRotateRequestMsg
import com.vecvel.danaview.pdf.pigeon.PdfSignRequestMsg
import com.vecvel.danaview.pdf.pigeon.PdfSplitRequestMsg
import com.vecvel.danaview.pdf.pigeon.PdfToolKindMsg
import com.vecvel.danaview.pdf.pigeon.PdfToolResultMsg
import com.vecvel.danaview.pdf.pigeon.PdfToolsHostApi
import com.vecvel.danaview.pdf.sign.PdfSigner
import com.vecvel.danaview.pdf.tools.PdfPageTools
import com.vecvel.danaview.pdf.tools.PdfWrittenFile

/** [emit] sends one event to Dart from any thread (glue/PdfEventHub.emit). */
class PdfToolsHostApiImpl(
    private val threads: PdfThreads,
    emit: (PdfEventMsg) -> Unit,
    private val compressor: PdfCompressor? = null,
) : PdfToolsHostApi, PdfOrganiseHostApi {
    val jobs = PdfJobRegistry { progress -> emit(PdfEventMsg(PdfEventKindMsg.TOOL_PROGRESS, toolProgress = progress)) }

    private fun unsupported(owner: String, callback: (Result<PdfToolResultMsg>) -> Unit) =
        callback(Result.failure(PdfErrors.notSupported(owner)))

    /** Starts job [id] of [tool] and runs [work] with it on the tools thread; also used by organise. */
    fun run(id: String, tool: PdfToolKindMsg, what: String, callback: (Result<PdfToolResultMsg>) -> Unit, work: (PdfJob) -> List<PdfWrittenFile>) {
        val job = try {
            jobs.start(id, tool)
        } catch (t: Throwable) {
            callback(Result.failure(PdfErrors.from(t, what)))
            return
        }
        threads.submit(threads.tools, what, { result: Result<PdfToolResultMsg> ->
            jobs.finish(job)
            callback(result)
        }) {
            val files = work(job)
            PdfToolResultMsg(files.map { it.path }, files.map { it.pageCount.toLong() }, files.map { it.sizeBytes })
        }
    }

    override fun merge(request: PdfMergeRequestMsg, callback: (Result<PdfToolResultMsg>) -> Unit) =
        run(request.jobId, PdfToolKindMsg.MERGE, "merge", callback) { PdfPageTools.merge(request, it) }

    override fun split(request: PdfSplitRequestMsg, callback: (Result<PdfToolResultMsg>) -> Unit) =
        run(request.jobId, PdfToolKindMsg.SPLIT, "split", callback) { PdfPageTools.split(request, it) }

    override fun reorder(request: PdfReorderRequestMsg, callback: (Result<PdfToolResultMsg>) -> Unit) =
        run(request.jobId, PdfToolKindMsg.REORDER, "reorder", callback) { PdfPageTools.reorder(request, it) }

    override fun rotate(request: PdfRotateRequestMsg, callback: (Result<PdfToolResultMsg>) -> Unit) =
        run(request.jobId, PdfToolKindMsg.ROTATE, "rotate", callback) { PdfPageTools.rotate(request, it) }

    override fun deletePages(request: PdfDeletePagesRequestMsg, callback: (Result<PdfToolResultMsg>) -> Unit) =
        run(request.jobId, PdfToolKindMsg.DELETE_PAGES, "delete pages", callback) { PdfPageTools.deletePages(request, it) }

    /** PdfOrganiseHostApi (HOM-28 amendment): progress events carry `tool: reorder`. */
    override fun organise(request: PdfOrganiseRequestMsg, callback: (Result<PdfToolResultMsg>) -> Unit) =
        run(request.jobId, PdfToolKindMsg.REORDER, "organise", callback) { PdfPageTools.organise(request, it) }

    override fun annotate(request: PdfAnnotateRequestMsg, callback: (Result<PdfToolResultMsg>) -> Unit) =
        unsupported(PdfAnnotator.OWNER, callback)

    override fun sign(request: PdfSignRequestMsg, callback: (Result<PdfToolResultMsg>) -> Unit) = unsupported(PdfSigner.OWNER, callback)

    override fun compress(request: PdfCompressRequestMsg, callback: (Result<PdfToolResultMsg>) -> Unit) =
        compressor?.compress(request, callback) ?: unsupported(PdfCompressor.OWNER, callback)

    /** Reaches whichever owns [jobId]: the page-tools jobs or the compressor (unknown ids are ignored). */
    override fun cancel(jobId: String) {
        jobs.cancel(jobId)
        compressor?.cancel(jobId)
    }
}
