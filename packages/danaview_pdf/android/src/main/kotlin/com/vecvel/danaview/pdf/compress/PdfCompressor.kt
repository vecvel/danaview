// OWNER: HOM-31A
//
// The Android compress tool (HOM-31A, on the HOM-27 route, PdfBox-Android): `PdfToolsHostApi.compress`
// runs here as a tool job (routed by glue/PdfToolsHostApiImpl.kt, cancelled through
// `PdfToolsHostApi.cancel`, `toolProgress` events after every page) and this class is the
// `PdfCompressHostApi` (estimate). The work is compress/PdfCompressCore.kt, one job at a time on a
// background thread that exits when idle; replies hop back to the main thread. Each job gets its
// own scratch directory under the app's cache, removed when the job ends.

package com.vecvel.danaview.pdf.compress

import android.os.Handler
import android.os.Process
import com.vecvel.danaview.pdf.glue.PdfErrorCode
import com.vecvel.danaview.pdf.glue.PdfErrors
import com.vecvel.danaview.pdf.glue.PdfEventHub
import com.vecvel.danaview.pdf.glue.PdfFailure
import com.vecvel.danaview.pdf.pigeon.PdfCompressEstimateMsg
import com.vecvel.danaview.pdf.pigeon.PdfCompressHostApi
import com.vecvel.danaview.pdf.pigeon.PdfCompressPresetMsg
import com.vecvel.danaview.pdf.pigeon.PdfCompressRequestMsg
import com.vecvel.danaview.pdf.pigeon.PdfEventKindMsg
import com.vecvel.danaview.pdf.pigeon.PdfEventMsg
import com.vecvel.danaview.pdf.pigeon.PdfToolInputMsg
import com.vecvel.danaview.pdf.pigeon.PdfToolKindMsg
import com.vecvel.danaview.pdf.pigeon.PdfToolProgressMsg
import com.vecvel.danaview.pdf.pigeon.PdfToolResultMsg
import java.io.File
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.ThreadPoolExecutor
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

class PdfCompressor(
    private val main: Handler,
    private val events: PdfEventHub?,
    /** Parent of the per-job scratch directories (the app's cache directory). */
    private val scratchRoot: File,
) : PdfCompressHostApi {
    private val jobs = ConcurrentHashMap<String, AtomicBoolean>()

    private val executor = ThreadPoolExecutor(1, 1, IDLE_SECONDS, TimeUnit.SECONDS, LinkedBlockingQueue()) { r ->
        Thread({
            Process.setThreadPriority(Process.THREAD_PRIORITY_BACKGROUND + Process.THREAD_PRIORITY_MORE_FAVORABLE)
            r.run()
        }, "danaview-pdf-compress")
    }.apply { allowCoreThreadTimeOut(true) }

    /** `PdfToolsHostApi.compress`: writes `request.outPath`; `cancelled` after [cancel]. */
    fun compress(request: PdfCompressRequestMsg, callback: (Result<PdfToolResultMsg>) -> Unit) {
        val flag = AtomicBoolean(false)
        if (jobs.putIfAbsent(request.jobId, flag) != null) {
            callback(Result.failure(PdfErrors.error(PdfErrorCode.invalidArgument, "job id in use")))
            return
        }
        submit(callback, { jobs.remove(request.jobId) }) {
            if (request.input.isImage) throw PdfFailure.invalid("compress takes a PDF")
            val jobId = request.jobId
            emit(jobId, 0.0, 0, 0)
            val outcome = withScratch { scratch ->
                PdfCompressCore.compress(
                    source = File(request.input.path),
                    password = request.input.password,
                    preset = presetOf(request.preset),
                    out = File(request.outPath),
                    scratchDir = scratch,
                    isCancelled = { flag.get() },
                    progress = { fraction, done, total -> emit(jobId, fraction, done, total) },
                )
            }
            PdfToolResultMsg(
                outPaths = listOf(request.outPath),
                pageCounts = listOf(outcome.pageCount.toLong()),
                sizesBytes = listOf(outcome.sizeBytes),
            )
        }
    }

    /** `PdfToolsHostApi.cancel`: true when [jobId] is a compress job of this plugin. */
    fun cancel(jobId: String): Boolean {
        val flag = jobs[jobId] ?: return false
        flag.set(true)
        return true
    }

    override fun estimate(input: PdfToolInputMsg, callback: (Result<PdfCompressEstimateMsg>) -> Unit) {
        submit(callback, {}) {
            if (input.isImage) throw PdfFailure.invalid("compress takes a PDF")
            val e = withScratch { scratch -> PdfCompressCore.estimate(File(input.path), input.password, scratch) }
            PdfCompressEstimateMsg(
                sourceBytes = e.sourceBytes,
                highBytes = e.presetBytes[0],
                mediumBytes = e.presetBytes[1],
                smallBytes = e.presetBytes[2],
                sampled = e.sampled,
            )
        }
    }

    /** Cancels every job (plugin detached); queued work is dropped. */
    fun shutdown() {
        jobs.values.forEach { it.set(true) }
        executor.shutdown()
    }

    private fun <T> withScratch(work: (File) -> T): T {
        val dir = File(scratchRoot, "dv_pdf_compress_" + UUID.randomUUID())
        try {
            return work(dir)
        } finally {
            dir.deleteRecursively()
        }
    }

    private fun emit(jobId: String, fraction: Double, done: Int, total: Int) {
        events?.emit(
            PdfEventMsg(
                kind = PdfEventKindMsg.TOOL_PROGRESS,
                toolProgress = PdfToolProgressMsg(jobId, PdfToolKindMsg.COMPRESS, fraction.coerceIn(0.0, 1.0), done.toLong(), total.toLong()),
            ),
        )
    }

    private fun <T> submit(callback: (Result<T>) -> Unit, after: () -> Unit, work: () -> T) {
        try {
            executor.execute {
                val result: Result<T> = try {
                    Result.success(work())
                } catch (t: Throwable) {
                    Result.failure(PdfErrors.from(t, "compress"))
                } finally {
                    after()
                }
                main.post { callback(result) }
            }
        } catch (e: RejectedExecutionException) {
            after()
            callback(Result.failure(PdfErrors.error(PdfErrorCode.internal, "compress: plugin detached")))
        }
    }

    companion object {
        /** The ticket that implements it. */
        const val OWNER = "HOM-31A"

        /** The tools of this class that have landed on Android. */
        val supported: List<PdfToolKindMsg> = listOf(PdfToolKindMsg.COMPRESS)

        private const val IDLE_SECONDS = 30L

        fun presetOf(msg: PdfCompressPresetMsg): PdfCompressPreset = when (msg) {
            PdfCompressPresetMsg.HIGH -> PdfCompressPreset.HIGH
            PdfCompressPresetMsg.MEDIUM -> PdfCompressPreset.MEDIUM
            PdfCompressPresetMsg.SMALL -> PdfCompressPreset.SMALL
        }
    }
}
