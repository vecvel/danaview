// OWNER: HOM-25
//
// The threads of the Android plugin (pigeons/pdf_api.dart conventions: host handlers never block
// the main thread on PDF work):
//
// - documents: probe, open, unlock, outline, thumbnails and the final close of a document;
// - text: extraction and search (PdfBox; one at a time, so a newer search waits for an older one to
//   see its cancel flag);
// - render: the texture views' render passes (one thread, shared, so PdfRenderer work stays
//   serialised and the views never compete with each other).
//
// Replies always hop back to the main thread.

package com.vecvel.danaview.pdf.glue

import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import android.os.Process
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.RejectedExecutionException

class PdfThreads {
    val main = Handler(Looper.getMainLooper())

    val documents: ExecutorService = Executors.newFixedThreadPool(2) { r ->
        Thread(r, "danaview-pdf-documents")
    }

    val text: ExecutorService = Executors.newSingleThreadExecutor { r ->
        Thread(r, "danaview-pdf-text").apply { priority = Thread.NORM_PRIORITY - 1 }
    }

    private val renderThread = HandlerThread("danaview-pdf-render", Process.THREAD_PRIORITY_DISPLAY).apply { start() }

    val render = Handler(renderThread.looper)

    /** Runs [work] on [executor] and answers [callback] on the main thread; failures become Pigeon errors. */
    fun <T> submit(executor: ExecutorService, what: String, callback: (Result<T>) -> Unit, work: () -> T) {
        try {
            executor.execute {
                val result: Result<T> = try {
                    Result.success(work())
                } catch (t: Throwable) {
                    Result.failure(PdfErrors.from(t, what))
                }
                main.post { callback(result) }
            }
        } catch (e: RejectedExecutionException) {
            callback(Result.failure(PdfErrors.error(PdfErrorCode.internal, "$what: plugin detached")))
        }
    }

    /** Stops every thread (plugin detached); queued work is dropped. */
    fun shutdown() {
        documents.shutdown()
        text.shutdown()
        renderThread.quitSafely()
    }
}
