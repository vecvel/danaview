// OWNER: AND-05
//
// D-33 placeholder created by ENG-08 (BUILD_PLAN ENG-08, ARCH §4.4). It holds only the names the
// glue calls; every call fails with `notSupportedOnDevice` (the Dart side maps that to the editor's
// unsupported state). The owner ticket replaces this file and keeps the signatures the glue uses.
// Run by JobRegistry (AND-05) on vwish-jobs; checks control.throwIfCancelled() between steps and
// reports progress through control.reportProgress.

package com.vecvel.vwish.editor.engine.media

import com.vecvel.vwish.editor.engine.core.EngineContext
import com.vecvel.vwish.editor.engine.core.EngineErrors
import com.vecvel.vwish.editor.engine.core.JobControl
import com.vecvel.vwish.editor.engine.pigeon.GeneratedAssetMsg
import com.vecvel.vwish.editor.engine.pigeon.JobRequestMsg

/** 540p proxy job with the source PTS (ARCH §9.5, §15; AND-05). */
class ProxyJob(private val ctx: EngineContext) {
    /** Builds the proxy of [request].media (kind proxy). Blocking; throws an EngineException on failure. */
    fun run(request: JobRequestMsg, control: JobControl): GeneratedAssetMsg {
        throw EngineErrors.notSupported("proxies")
    }
}
