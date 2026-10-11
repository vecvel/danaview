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
import com.vecvel.vwish.editor.engine.pigeon.ExtractedSpeechAudioMsg
import com.vecvel.vwish.editor.engine.pigeon.JobRequestMsg

/** 16 kHz s16 mono WAV for a source range (ARCH §15; AND-04). */
class SpeechAudioExtractor(private val ctx: EngineContext) {
    /** Writes the WAV of [request] (kind speechAudio) to its outputPath. Blocking; throws an EngineException on failure. */
    fun extract(request: JobRequestMsg, control: JobControl): ExtractedSpeechAudioMsg {
        throw EngineErrors.notSupported("speech audio")
    }
}
