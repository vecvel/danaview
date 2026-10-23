// OWNER: HOM-04A
//
// ThumbnailHostApi on Android (ARCH v1.2 V2-28, V2-104; BUILD_PLAN HOM-04A) over the Flutter-free
// AndroidThumbnailer:
//
// * mediaThumbnail: `ms:<id>` MediaStore rows, absolute paths, `file://` URLs and `content://` URIs
//   (`ph:` is Apple's: notSupportedOnDevice). Work runs on a pool of [MAX_CONCURRENT] background
//   threads; the reply arrives on the main thread. Output is lossy WebP as the Home cache asks on
//   Android (V2-28), JPEG/PNG when asked, HEIC requests are written as JPEG; the result says which.
// * documentThumbnail: PdfRenderer's first page for PDFs; null (type icon) for other documents.
// * cancel: cancels a pending request (it fails with `cancelled`); unknown ids are ignored.
// * updateCaching: validated, otherwise a no-op (no native prefetch cache on Android; the Dart
//   side only sends `ph:` sources).
//
// Keep the class name and the constructor: the glue (DanaviewLibraryNativePlugin.kt) constructs it.
// Nothing is logged (rule 30); no network (rule 21).

package com.vecvel.danaview.library.thumbnails

import com.vecvel.danaview.library.glue.LibraryErrorCode
import com.vecvel.danaview.library.glue.LibraryErrors
import com.vecvel.danaview.library.glue.LibraryPluginContext
import com.vecvel.danaview.library.pigeon.DocumentThumbnailRequestMsg
import com.vecvel.danaview.library.pigeon.LibraryPigeonError
import com.vecvel.danaview.library.pigeon.MediaThumbnailRequestMsg
import com.vecvel.danaview.library.pigeon.ThumbnailCachingMsg
import com.vecvel.danaview.library.pigeon.ThumbnailHostApi
import com.vecvel.danaview.library.pigeon.ThumbnailResultMsg
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.RejectedExecutionException

class ThumbnailHostApiImpl(private val context: LibraryPluginContext) : ThumbnailHostApi {
    private val thumbnailer = AndroidThumbnailer(context.appContext)
    private val pool: ExecutorService = Executors.newFixedThreadPool(MAX_CONCURRENT) { r ->
        Thread(r, "danaview-library-thumbs").apply { priority = Thread.NORM_PRIORITY - 1 }
    }
    private val pending = ConcurrentHashMap<String, ThumbnailCancelToken>()

    /** Stops the pool (plugin detached); running requests are cancelled. */
    fun dispose() {
        pending.values.forEach { it.cancel() }
        pool.shutdown()
    }

    private fun <T> submit(requestId: String, callback: (Result<T>) -> Unit, work: (ThumbnailCancelToken) -> T) {
        val token = ThumbnailCancelToken()
        if (pending.putIfAbsent(requestId, token) != null) {
            return callback(Result.failure(error(ThumbnailFailure.busy("a request with this id is running"))))
        }
        try {
            pool.execute {
                val result: Result<T> = try {
                    token.check()
                    Result.success(work(token))
                } catch (f: ThumbnailFailure) {
                    Result.failure(error(f))
                } catch (t: Throwable) {
                    Result.failure(LibraryErrors.wrap(t, "thumbnail"))
                } finally {
                    pending.remove(requestId, token)
                }
                context.main.post { callback(result) }
            }
        } catch (e: RejectedExecutionException) {
            pending.remove(requestId, token)
            callback(Result.failure(LibraryErrors.error(LibraryErrorCode.internal, "thumbnail: plugin detached")))
        }
    }

    override fun mediaThumbnail(request: MediaThumbnailRequestMsg, callback: (Result<ThumbnailResultMsg>) -> Unit) {
        ThumbnailRequests.validate(request.requestId, request.widthPx, request.heightPx, request.quality, request.outputPath)?.let {
            return callback(Result.failure(error(it)))
        }
        val source = try {
            ThumbnailSource.parse(request.source)
        } catch (f: ThumbnailFailure) {
            return callback(Result.failure(error(f)))
        }
        val box = PxSize(request.widthPx.toInt(), request.heightPx.toInt())
        submit(request.requestId, callback) { token ->
            msg(thumbnailer.media(source, box, request.mode, request.format, request.quality, request.outputPath, token))
        }
    }

    override fun documentThumbnail(request: DocumentThumbnailRequestMsg, callback: (Result<ThumbnailResultMsg?>) -> Unit) {
        ThumbnailRequests.validate(request.requestId, request.widthPx, request.heightPx, request.quality, request.outputPath)?.let {
            return callback(Result.failure(error(it)))
        }
        ThumbnailRequests.validateScale(request.scale)?.let { return callback(Result.failure(error(it))) }
        if (!request.path.startsWith("/")) return callback(Result.failure(error(ThumbnailFailure.invalid("document path is not absolute"))))
        val box = PxSize(request.widthPx.toInt(), request.heightPx.toInt())
        submit(request.requestId, callback) { token ->
            thumbnailer.document(request.path, box, request.scale, request.format, request.quality, request.outputPath, token)?.let(::msg)
        }
    }

    override fun cancel(requestId: String) {
        pending[requestId]?.cancel()
    }

    override fun updateCaching(window: ThumbnailCachingMsg) {
        val side = ThumbnailGeometry.MAX_SIDE.toLong()
        if (window.widthPx < 1 || window.heightPx < 1 || window.widthPx > side || window.heightPx > side) {
            throw error(ThumbnailFailure.invalid("box out of range"))
        }
        // No native prefetch cache on Android: MediaStore keeps its own thumbnails.
    }

    private companion object {
        /** At most this many thumbnails are produced at once (the Dart cache queues the rest). */
        const val MAX_CONCURRENT = 4

        fun error(f: ThumbnailFailure): LibraryPigeonError = LibraryErrors.error(f.code, f.message ?: f.code.name)

        fun msg(o: ThumbnailOutput) = ThumbnailResultMsg(o.path, o.widthPx.toLong(), o.heightPx.toLong(), o.format)
    }
}
