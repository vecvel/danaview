// OWNER: HOM-22A
//
// ExportOutHostApi on Android (ARCH v1.2 §8, rule 26, V2-117; BUILD_PLAN HOM-22A): a thin wrapper
// over SaveOutFlow (FileOutFlows.kt: MediaStore Downloads / Pictures / Movies on API 29+, the
// system "save as" for Save to Files and on API 24-28; no storage permission). The save dialogs
// run through the plugin's Activity; replies arrive on the main thread. Creating this class (the
// plugin's start) sweeps temporary share / open-in batches older than a day, off the main thread.
// Keep the class name and the constructor: the glue constructs it. Nothing is logged (rule 30).

package com.vecvel.danaview.library.exportout

import com.vecvel.danaview.library.glue.LibraryErrors
import com.vecvel.danaview.library.glue.LibraryPluginContext
import com.vecvel.danaview.library.pigeon.ExportOutHostApi
import com.vecvel.danaview.library.pigeon.LibraryPigeonError
import com.vecvel.danaview.library.pigeon.SaveOutRequestMsg
import com.vecvel.danaview.library.pigeon.SaveOutResultMsg
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

class ExportOutHostApiImpl(private val context: LibraryPluginContext) : ExportOutHostApi {
    private val worker: ExecutorService = Executors.newSingleThreadExecutor { r -> Thread(r, "danaview-library-save-out") }
    private val out = AndroidFileOut(context.appContext)
    private val flow = SaveOutFlow(out, worker) { block -> context.main.post(block) }
    private val launcher = OutLauncher { intent, done -> context.startActivityForResult(REQUEST_SAVE_AS, intent, done) }

    init {
        // Batches a crash or a long-lived receiver left behind (a5c4c4d answer 11).
        runCatching { worker.execute { runCatching { out.store.sweepStale() } } }
    }

    fun dispose() {
        worker.shutdown()
    }

    override fun saveOut(request: SaveOutRequestMsg, callback: (Result<SaveOutResultMsg>) -> Unit) {
        val files = request.items.map { OutFile(it.path, it.displayName, it.mimeType) }
        flow.save(files, request.destination, request.subdirectory, launcher) { r -> callback(r.mapFailure()) }
    }

    private companion object {
        /** Activity request code of the save dialogs (distinct from the plugin's other codes). */
        const val REQUEST_SAVE_AS = 0x4C22
    }
}

/** A flow result with OutFailure mapped to the Pigeon error. */
fun <T> Result<T>.mapFailure(): Result<T> = fold({ Result.success(it) }, { Result.failure(pigeonError(it, "file out")) })

fun pigeonError(t: Throwable, what: String): LibraryPigeonError =
    if (t is OutFailure) LibraryErrors.error(t.code, t.message ?: t.code.name) else LibraryErrors.wrap(t, what)
