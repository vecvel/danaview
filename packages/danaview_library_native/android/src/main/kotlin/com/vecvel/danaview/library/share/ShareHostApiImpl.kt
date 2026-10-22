// OWNER: HOM-22A
//
// ShareHostApi on Android (ARCH v1.2 §8, V2-117, V2-118; BUILD_PLAN HOM-22A; a5c4c4d answer 11): a
// thin wrapper over ShareFlow (exportout/FileOutFlows.kt): temporary read-only copies in
// `<cacheDir>/danaview-out/<UUID>/`, ACTION_SEND / ACTION_SEND_MULTIPLE through the system chooser
// with the plugin FileProvider's read grants only (ClipData of every URI). completed = the user
// chose a target (activityType = its package). One share sheet at a time (`busy`). Keep the class
// name and the constructor: the glue constructs it. Nothing is logged (rule 30).

package com.vecvel.danaview.library.share

import com.vecvel.danaview.library.exportout.AndroidFileOut
import com.vecvel.danaview.library.exportout.OutFile
import com.vecvel.danaview.library.exportout.OutLauncher
import com.vecvel.danaview.library.exportout.ShareFlow
import com.vecvel.danaview.library.exportout.mapFailure
import com.vecvel.danaview.library.glue.LibraryPluginContext
import com.vecvel.danaview.library.pigeon.ShareHostApi
import com.vecvel.danaview.library.pigeon.ShareRequestMsg
import com.vecvel.danaview.library.pigeon.ShareResultMsg
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

class ShareHostApiImpl(private val context: LibraryPluginContext) : ShareHostApi {
    private val worker: ExecutorService = Executors.newSingleThreadExecutor { r -> Thread(r, "danaview-library-share") }
    private val flow = ShareFlow(context.appContext, AndroidFileOut(context.appContext), worker) { block -> context.main.post(block) }
    private val launcher = OutLauncher { intent, done -> context.startActivityForResult(REQUEST_SHARE, intent, done) }

    fun dispose() {
        worker.shutdown()
    }

    override fun share(request: ShareRequestMsg, callback: (Result<ShareResultMsg>) -> Unit) {
        val files = request.items.map { OutFile(it.path, it.displayName, it.mimeType) }
        flow.share(files, request.subject, launcher, { ms, block -> context.main.postDelayed(block, ms) }) { r ->
            callback(r.map { ShareResultMsg(it.completed, it.activityType) }.mapFailure())
        }
    }

    private companion object {
        /** Activity request code of the share chooser (distinct from the plugin's other codes). */
        const val REQUEST_SHARE = 0x4C23
    }
}
