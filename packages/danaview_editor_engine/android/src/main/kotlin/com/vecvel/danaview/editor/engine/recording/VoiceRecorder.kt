// OWNER: AND-13
//
// D-33 placeholder created by ENG-08 (BUILD_PLAN ENG-08, ARCH §4.4). It holds only the names the
// glue calls; every call fails with `notSupportedOnDevice` (the Dart side maps that to the editor's
// unsupported state). The owner ticket replaces this file and keeps the signatures the glue uses.
// AND-13: AudioRecord(MIC, 48 kHz, mono, s16) on its own thread, WAV at the Dart path, levels at
// 20 Hz (ctx.events.recorderLevel), interruptions keep the file (ctx.events.interruption),
// RECORD_AUDIO runtime request through ctx.activityHost.

package com.vecvel.danaview.editor.engine.recording

import com.vecvel.danaview.editor.engine.core.Completion
import com.vecvel.danaview.editor.engine.core.EngineContext
import com.vecvel.danaview.editor.engine.core.EngineErrors
import com.vecvel.danaview.editor.engine.core.fail
import com.vecvel.danaview.editor.engine.pigeon.MicPermissionMsg
import com.vecvel.danaview.editor.engine.pigeon.RecordedAssetMsg

/**
 * Voice recorder (ARCH §12.4, §15; AND-13). `permission`, `start`, `stop` and `cancel` are called on
 * danaview-io; `requestPermission` and `openSettings` on main (they need the activity).
 */
class VoiceRecorder(private val ctx: EngineContext) {
    private fun <T> unavailable(done: Completion<T>) = done.fail(EngineErrors.notSupported("voice recording"))

    /** The microphone permission state. */
    fun permission(done: Completion<MicPermissionMsg>) = unavailable(done)

    /** Requests the microphone permission in context. */
    fun requestPermission(done: Completion<MicPermissionMsg>) = unavailable(done)

    /** Opens the app's system settings (permanently denied). */
    fun openSettings(done: Completion<Unit>) = unavailable(done)

    /** Starts recording to [outputPath] (inside the engine roots); completes with the recording id. */
    fun start(outputPath: String, done: Completion<String>) = unavailable(done)

    /** Stops [recordingId] and completes with the recorded asset. */
    fun stop(recordingId: String, done: Completion<RecordedAssetMsg>) = unavailable(done)

    /** Cancels [recordingId] and deletes its file. */
    fun cancel(recordingId: String, done: Completion<Unit>) = unavailable(done)
}
