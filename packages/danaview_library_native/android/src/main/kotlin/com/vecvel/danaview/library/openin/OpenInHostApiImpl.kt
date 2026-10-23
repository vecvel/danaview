// OWNER: HOM-22A
//
// OpenInHostApi on Android (ARCH v1.2 §8, V2-117; BUILD_PLAN HOM-22A; a5c4c4d answer 11): a thin
// wrapper over OpenInFlow (exportout/FileOutFlows.kt): one temporary read-only copy, ACTION_VIEW
// with the plugin FileProvider's read grant only. true when an app (or the system's app chooser)
// opened it, false when no installed app takes the type. Keep the class name and the constructor:
// the glue constructs it. Nothing is logged (rule 30).

package com.vecvel.danaview.library.openin

import com.vecvel.danaview.library.exportout.AndroidFileOut
import com.vecvel.danaview.library.exportout.OpenInFlow
import com.vecvel.danaview.library.exportout.OutFile
import com.vecvel.danaview.library.exportout.mapFailure
import com.vecvel.danaview.library.glue.LibraryPluginContext
import com.vecvel.danaview.library.pigeon.OpenInHostApi
import com.vecvel.danaview.library.pigeon.OpenInRequestMsg
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

class OpenInHostApiImpl(private val context: LibraryPluginContext) : OpenInHostApi {
    private val worker: ExecutorService = Executors.newSingleThreadExecutor { r -> Thread(r, "danaview-library-open-in") }
    private val flow = OpenInFlow(AndroidFileOut(context.appContext), worker) { block -> context.main.post(block) }

    fun dispose() {
        worker.shutdown()
    }

    override fun openIn(request: OpenInRequestMsg, callback: (Result<Boolean>) -> Unit) {
        val item = request.item
        flow.openIn(OutFile(item.path, item.displayName, item.mimeType), { context.activity }) { r -> callback(r.mapFailure()) }
    }
}
