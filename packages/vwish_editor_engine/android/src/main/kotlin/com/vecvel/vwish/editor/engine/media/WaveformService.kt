// OWNER: AND-04
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
import com.vecvel.vwish.editor.engine.pigeon.WaveformPeaksMsg
import com.vecvel.vwish.editor.engine.pigeon.JobRequestMsg

/** Waveform peaks job, .vwpk int8 min/max at 200 pairs/s (ARCH §15; AND-04). */
class WaveformService(private val ctx: EngineContext) {
    /** Computes the peaks of [request].media (kind waveform). Blocking; throws an EngineException on failure. */
    fun peaks(request: JobRequestMsg, control: JobControl): WaveformPeaksMsg {
        throw EngineErrors.notSupported("waveforms")
    }
}
