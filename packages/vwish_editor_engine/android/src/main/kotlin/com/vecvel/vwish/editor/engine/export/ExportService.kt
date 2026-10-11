// OWNER: AND-12
//
// D-33 placeholder created by ENG-08 (BUILD_PLAN ENG-08, ARCH §4.4). It holds only the names the
// glue calls; every call fails with `notSupportedOnDevice` (the Dart side maps that to the editor's
// unsupported state). The owner ticket replaces this file and keeps the signatures the glue uses.
// The plugin manifest (ENG-08) declares this service with foregroundServiceType
// mediaProcessing|dataSync. AND-12: foreground export with a progress notification and Cancel,
// background-guard leases, detached completion handoff (D-39), API 35 onTimeout -> interrupted.

package com.vecvel.vwish.editor.engine.export

import android.app.Service
import android.content.Intent
import android.os.IBinder

/** Export foreground service (ARCH §14.3; AND-12). Until AND-12 it stops at once. */
class ExportService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        stopSelf(startId)
        return START_NOT_STICKY
    }
}
