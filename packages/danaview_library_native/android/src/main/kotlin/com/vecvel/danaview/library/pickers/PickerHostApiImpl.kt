// OWNER: HOM-20A
//
// PickerHostApi on Android (ARCH v1.2 §5.6, V2-116; BUILD_PLAN HOM-20A) over AndroidPickers:
//
// * pickPhotos / pickDocuments: one picker at a time through the plugin's Activity (`busy`
//   otherwise or without an Activity); the user cancelling answers an empty list. Items are
//   content:// URIs with needsCopy = true (see AndroidPickers); their metadata is read off the
//   main thread. The request's destinationDirectory is not used on Android: nothing is staged.
// * copyToFile: two background copy threads; progress goes to the library event stream
//   (copyProgress, at most 4 Hz, each report fsynced first); a duplicate requestId is `busy`.
// * cancelCopy: the copy stops with `cancelled` (the part file keeps its bytes for a resume);
//   unknown ids are ignored. release: no-op (no persisted grants are taken).
//
// Keep the class name and the constructor: the glue (DanaviewLibraryNativePlugin.kt) constructs it.
// Nothing is logged (rule 30).

package com.vecvel.danaview.library.pickers

import android.net.Uri
import com.vecvel.danaview.library.glue.LibraryErrorCode
import com.vecvel.danaview.library.glue.LibraryErrors
import com.vecvel.danaview.library.glue.LibraryPluginContext
import com.vecvel.danaview.library.pigeon.CopyProgressMsg
import com.vecvel.danaview.library.pigeon.CopyRequestMsg
import com.vecvel.danaview.library.pigeon.CopyResultMsg
import com.vecvel.danaview.library.pigeon.DocumentPickRequestMsg
import com.vecvel.danaview.library.pigeon.LibraryEventKindMsg
import com.vecvel.danaview.library.pigeon.LibraryEventMsg
import com.vecvel.danaview.library.pigeon.LibraryPigeonError
import com.vecvel.danaview.library.pigeon.PhotoPickRequestMsg
import com.vecvel.danaview.library.pigeon.PickedItemMsg
import com.vecvel.danaview.library.pigeon.PickedSourceMsg
import com.vecvel.danaview.library.pigeon.PickerHostApi
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.RejectedExecutionException

class PickerHostApiImpl(private val context: LibraryPluginContext) : PickerHostApi {
    private val pickers = AndroidPickers(context.appContext)
    private val copies = CopyRegistry()
    private val copyPool: ExecutorService = Executors.newFixedThreadPool(2) { r -> Thread(r, "danaview-library-import-copy") }
    private val metadata: ExecutorService = Executors.newSingleThreadExecutor { r -> Thread(r, "danaview-library-picked") }

    /** The Activity of the plugin as a [ResultLauncher]. */
    private val launcher = ResultLauncher { intent, done ->
        try {
            context.startActivityForResult(REQUEST_PICK, intent, done)
        } catch (e: RuntimeException) {
            false // ActivityNotFoundException: no picker app answers
        }
    }

    /** Stops the copies (plugin detached). */
    fun dispose() {
        copies.cancelAll()
        copyPool.shutdown()
        metadata.shutdown()
    }

    private fun error(f: PickerFailure): LibraryPigeonError = LibraryErrors.error(f.code, f.message ?: f.code.name)

    private fun failure(t: Throwable, what: String): LibraryPigeonError = when (t) {
        is PickerFailure -> error(t)
        else -> LibraryErrors.wrap(t, what)
    }

    /** Describes picked [uris] off the main thread and answers [callback] on it. */
    private fun answer(result: Result<List<Uri>>, source: PickedSourceMsg, callback: (Result<List<PickedItemMsg>>) -> Unit) {
        val uris = result.getOrElse { return callback(Result.failure(failure(it, "picker"))) }
        if (uris.isEmpty()) return callback(Result.success(emptyList()))
        try {
            metadata.execute {
                val items = runCatching { pickers.describeAll(uris, source) }
                context.main.post { callback(items.fold({ Result.success(it) }, { Result.failure(failure(it, "picker")) })) }
            }
        } catch (e: RejectedExecutionException) {
            callback(Result.failure(LibraryErrors.error(LibraryErrorCode.internal, "picker: plugin detached")))
        }
    }

    override fun pickPhotos(request: PhotoPickRequestMsg, callback: (Result<List<PickedItemMsg>>) -> Unit) {
        if (request.selectionLimit < 0) return callback(Result.failure(error(PickerFailure.invalid("negative limit"))))
        pickers.pickPhotos(launcher, PickerRequests.visualKind(request.filter), request.selectionLimit) {
            answer(it, PickedSourceMsg.PHOTO_LIBRARY, callback)
        }
    }

    override fun pickDocuments(request: DocumentPickRequestMsg, callback: (Result<List<PickedItemMsg>>) -> Unit) {
        pickers.pickDocuments(launcher, request.allowMultiple, request.mimeTypes) {
            answer(it, PickedSourceMsg.FILES, callback)
        }
    }

    override fun copyToFile(request: CopyRequestMsg, callback: (Result<CopyResultMsg>) -> Unit) {
        if (request.requestId.isEmpty() || request.resumeFromOffset < 0 || !request.destinationPath.startsWith("/")) {
            return callback(Result.failure(error(PickerFailure.invalid("bad copy request"))))
        }
        val id = request.requestId
        if (!copies.start(id)) return callback(Result.failure(error(PickerFailure.busy("copy id in use"))))
        val events = context.events
        try {
            copyPool.execute {
                val result = try {
                    val (copied, total) = pickers.copy(request.sourceUri, request.destinationPath, request.resumeFromOffset, { copies.isCancelled(id) }) { done, size ->
                        events.emit(LibraryEventMsg(LibraryEventKindMsg.COPY_PROGRESS, copyProgress = CopyProgressMsg(id, done, size)))
                    }
                    Result.success(CopyResultMsg(copied, total))
                } catch (t: Throwable) {
                    Result.failure(failure(t, "copy"))
                } finally {
                    copies.finish(id)
                }
                context.main.post { callback(result) }
            }
        } catch (e: RejectedExecutionException) {
            copies.finish(id)
            callback(Result.failure(LibraryErrors.error(LibraryErrorCode.internal, "copy: plugin detached")))
        }
    }

    override fun cancelCopy(requestId: String) {
        copies.cancel(requestId)
    }

    override fun release(uri: String) {
        // No persisted grant is ever taken on Android (imports copy): nothing to give up.
    }

    private companion object {
        /** Activity request code of the import pickers (distinct from the plugin's other codes). */
        const val REQUEST_PICK = 0x4C20
    }
}
