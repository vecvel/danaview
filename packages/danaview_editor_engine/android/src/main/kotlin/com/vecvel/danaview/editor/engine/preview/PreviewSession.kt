// OWNER: AND-10
//
// D-33 placeholder created by ENG-08 (BUILD_PLAN ENG-08, ARCH §4.4). It holds only the names the
// glue calls; every call fails with `notSupportedOnDevice` (the Dart side maps that to the editor's
// unsupported state). The owner ticket replaces this file and keeps the signatures the glue uses.
// AND-10 may give the class any constructor (only PreviewSessionManager creates sessions); the glue
// uses `sessionId` and the methods below, always on danaview-preview. Times follow D-35: acks and clock
// samples carry timeOfFrame(k) with k = frameIndexNearest(platform pts).

package com.vecvel.danaview.editor.engine.preview

import com.vecvel.danaview.editor.engine.core.Completion
import com.vecvel.danaview.editor.engine.core.EngineErrors
import com.vecvel.danaview.editor.engine.core.fail
import com.vecvel.danaview.editor.engine.pigeon.ColorMsg
import com.vecvel.danaview.editor.engine.pigeon.EditingModeMsg
import com.vecvel.danaview.editor.engine.pigeon.LookSpecMsg
import com.vecvel.danaview.editor.engine.pigeon.LoopMsg
import com.vecvel.danaview.editor.engine.pigeon.PlanAckMsg
import com.vecvel.danaview.editor.engine.pigeon.PreviewQualityMsg
import com.vecvel.danaview.editor.engine.pigeon.ResolvedMediaMsg
import com.vecvel.danaview.editor.engine.pigeon.SeekAckMsg

/** One live preview session (ARCH §12.2, §13; AND-10). */
class PreviewSession(val sessionId: String) {
    private fun <T> unavailable(done: Completion<T>) = done.fail(EngineErrors.notSupported("preview"))

    /** Replaces the plan ([plan] is UTF-8 JSON, `PlanTransport.encodePlan`). */
    fun setPlan(plan: ByteArray, done: Completion<PlanAckMsg>) = unavailable(done)

    /** Applies a patch; `planOutOfSync` when `patch.from` != the engine revision. */
    fun applyPatch(patch: ByteArray, done: Completion<PlanAckMsg>) = unavailable(done)

    /** Sets a transient parameter override (coalesced to one per frame; UTF-8 JSON). */
    fun setTransient(itemId: String, params: ByteArray) = Unit

    /** Clears a transient override. */
    fun clearTransient(itemId: String) = Unit

    /** Starts playback, optionally looping [loop]; completes with the command seq. */
    fun play(loop: LoopMsg?, done: Completion<Long>) = unavailable(done)

    /** Pauses; completes with the command seq. */
    fun pause(done: Completion<Long>) = unavailable(done)

    /** Seeks; exact seeks complete after the frame is in the texture (D-35). */
    fun seek(timeUs: Long, exact: Boolean, done: Completion<SeekAckMsg>) = unavailable(done)

    /** Sets the preview quality. */
    fun setQuality(quality: PreviewQualityMsg, done: Completion<Unit>) = unavailable(done)

    /** Switches proxies on or off. */
    fun setUseProxies(on: Boolean, done: Completion<Unit>) = unavailable(done)

    /** Sets the editing mode (normal, crop source, matte). */
    fun setEditingMode(mode: EditingModeMsg, done: Completion<Unit>) = unavailable(done)

    /** Shows a source frame of [media] at [sourceTimeUs] instead of the timeline. */
    fun showSourceFrame(media: ResolvedMediaMsg, sourceTimeUs: Long, done: Completion<Unit>) = unavailable(done)

    /** 3x3 average of the pre-key source of [itemId] at the normalized point, or null. */
    fun sampleColor(itemId: String, x: Double, y: Double, done: Completion<ColorMsg?>) = unavailable(done)

    /** JPEG stills of [itemId], one per look. */
    fun renderLookStills(itemId: String, looks: List<LookSpecMsg>, heightPx: Long, done: Completion<List<ByteArray>>) = unavailable(done)

    /** Redraws the current frame. */
    fun refresh(done: Completion<Unit>) = unavailable(done)

    /** RGBA of the displayed frame (debug/profile builds). */
    fun debugCaptureFrame(done: Completion<ByteArray>) = unavailable(done)

    /** Releases the session and its texture (idempotent). */
    fun dispose(done: Completion<Unit>) = done(Result.success(Unit))
}
