// OWNER: AND-06
//
// D-33 placeholder created by ENG-08 (BUILD_PLAN ENG-08, ARCH §4.4). It holds only the names the
// glue calls; every call fails with `notSupportedOnDevice` (the Dart side maps that to the editor's
// unsupported state). The owner ticket replaces this file and keeps the signatures the glue uses.
// Run by JobRegistry (AND-05) on danaview-jobs; checks control.throwIfCancelled() between steps and
// reports progress through control.reportProgress.

package com.vecvel.danaview.editor.engine.media

import com.vecvel.danaview.editor.engine.core.EngineContext
import com.vecvel.danaview.editor.engine.core.EngineErrors
import com.vecvel.danaview.editor.engine.core.JobControl
import com.vecvel.danaview.editor.engine.pigeon.GeneratedAssetMsg
import com.vecvel.danaview.editor.engine.pigeon.JobRequestMsg

/** Freeze-frame still via FrameExtractor EXACT (ARCH §15; AND-06). */
class FreezeFrameJob(private val ctx: EngineContext) {
    /** Writes the PNG still of [request] (kind freeze) to its outputPath. Blocking; throws an EngineException on failure. */
    fun run(request: JobRequestMsg, control: JobControl): GeneratedAssetMsg {
        throw EngineErrors.notSupported("freeze frames")
    }
}
