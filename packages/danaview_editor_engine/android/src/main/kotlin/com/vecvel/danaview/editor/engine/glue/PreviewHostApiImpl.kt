// OWNER: ENG-08 (frozen by ENG-06, D-42)
//
// `PreviewHostApi` glue (ARCH §12.2, §12.6, §13). Every call runs on danaview-preview, so a session
// sees its commands in Dart's order; setTransient/clearTransient are fire-and-forget and coalesced
// by the session (AND-10).

package com.vecvel.danaview.editor.engine.glue

import com.vecvel.danaview.editor.engine.core.EngineThreads
import com.vecvel.danaview.editor.engine.pigeon.ColorMsg
import com.vecvel.danaview.editor.engine.pigeon.EditingModeMsg
import com.vecvel.danaview.editor.engine.pigeon.LookSpecMsg
import com.vecvel.danaview.editor.engine.pigeon.LoopMsg
import com.vecvel.danaview.editor.engine.pigeon.PlanAckMsg
import com.vecvel.danaview.editor.engine.pigeon.PreviewConfigMsg
import com.vecvel.danaview.editor.engine.pigeon.PreviewHostApi
import com.vecvel.danaview.editor.engine.pigeon.PreviewOpenedMsg
import com.vecvel.danaview.editor.engine.pigeon.PreviewQualityMsg
import com.vecvel.danaview.editor.engine.pigeon.ResolvedMediaMsg
import com.vecvel.danaview.editor.engine.pigeon.SeekAckMsg

/** `PreviewHostApi` handlers. */
class PreviewHostApiImpl(
    private val threads: EngineThreads,
    private val port: PreviewPort,
    private val dispatch: GlueDispatcher = GlueDispatcher(threads.main),
) : PreviewHostApi {
    private val lane get() = threads.preview

    override fun open(config: PreviewConfigMsg, callback: (Result<PreviewOpenedMsg>) -> Unit) =
        dispatch.async(lane, callback, check = { Check.previewConfig(config) }) { done -> port.open(config, done) }

    override fun setPlan(sessionId: String, plan: ByteArray, callback: (Result<PlanAckMsg>) -> Unit) =
        dispatch.async(lane, callback, check = {
            Check.id("sessionId", sessionId)
            Check.planBytes("plan", plan)
        }) { done -> port.setPlan(sessionId, plan, done) }

    override fun applyPatch(sessionId: String, patch: ByteArray, callback: (Result<PlanAckMsg>) -> Unit) =
        dispatch.async(lane, callback, check = {
            Check.id("sessionId", sessionId)
            Check.planBytes("patch", patch)
        }) { done -> port.applyPatch(sessionId, patch, done) }

    override fun setTransient(sessionId: String, itemId: String, params: ByteArray) =
        dispatch.fireAndForget(lane, "setTransient", check = {
            Check.id("sessionId", sessionId)
            Check.id("itemId", itemId)
            Check.bytes("params", params)
        }) { port.setTransient(sessionId, itemId, params) }

    override fun clearTransient(sessionId: String, itemId: String) =
        dispatch.fireAndForget(lane, "clearTransient", check = {
            Check.id("sessionId", sessionId)
            Check.id("itemId", itemId)
        }) { port.clearTransient(sessionId, itemId) }

    override fun play(sessionId: String, loop: LoopMsg?, callback: (Result<Long>) -> Unit) =
        dispatch.async(lane, callback, check = {
            Check.id("sessionId", sessionId)
            Check.loop(loop)
        }) { done -> port.play(sessionId, loop, done) }

    override fun pause(sessionId: String, callback: (Result<Long>) -> Unit) =
        dispatch.async(lane, callback, check = { Check.id("sessionId", sessionId) }) { done -> port.pause(sessionId, done) }

    override fun seek(sessionId: String, timeUs: Long, exact: Boolean, callback: (Result<SeekAckMsg>) -> Unit) =
        dispatch.async(lane, callback, check = {
            Check.id("sessionId", sessionId)
            Check.range("timeUs", timeUs, 0, Long.MAX_VALUE)
        }) { done -> port.seek(sessionId, timeUs, exact, done) }

    override fun setQuality(sessionId: String, quality: PreviewQualityMsg, callback: (Result<Unit>) -> Unit) =
        dispatch.async(lane, callback, check = { Check.id("sessionId", sessionId) }) { done -> port.setQuality(sessionId, quality, done) }

    override fun setUseProxies(sessionId: String, on: Boolean, callback: (Result<Unit>) -> Unit) =
        dispatch.async(lane, callback, check = { Check.id("sessionId", sessionId) }) { done -> port.setUseProxies(sessionId, on, done) }

    override fun setEditingMode(sessionId: String, mode: EditingModeMsg, callback: (Result<Unit>) -> Unit) =
        dispatch.async(lane, callback, check = {
            Check.id("sessionId", sessionId)
            Check.editingMode(mode)
        }) { done -> port.setEditingMode(sessionId, mode, done) }

    override fun showSourceFrame(sessionId: String, media: ResolvedMediaMsg, sourceTimeUs: Long, callback: (Result<Unit>) -> Unit) =
        dispatch.async(lane, callback, check = {
            Check.id("sessionId", sessionId)
            Check.media(media)
            Check.range("sourceTimeUs", sourceTimeUs, 0, Long.MAX_VALUE)
        }) { done -> port.showSourceFrame(sessionId, media, sourceTimeUs, done) }

    override fun sampleColor(sessionId: String, itemId: String, x: Double, y: Double, callback: (Result<ColorMsg?>) -> Unit) =
        dispatch.async(lane, callback, check = {
            Check.id("sessionId", sessionId)
            Check.id("itemId", itemId)
            Check.unit("x", x)
            Check.unit("y", y)
        }) { done -> port.sampleColor(sessionId, itemId, x, y, done) }

    override fun renderLookStills(
        sessionId: String,
        itemId: String,
        looks: List<LookSpecMsg>,
        heightPx: Long,
        callback: (Result<List<ByteArray>>) -> Unit,
    ) = dispatch.async(lane, callback, check = {
        Check.id("sessionId", sessionId)
        Check.id("itemId", itemId)
        Check.looks(looks, heightPx)
    }) { done -> port.renderLookStills(sessionId, itemId, looks, heightPx, done) }

    override fun refresh(sessionId: String, callback: (Result<Unit>) -> Unit) =
        dispatch.async(lane, callback, check = { Check.id("sessionId", sessionId) }) { done -> port.refresh(sessionId, done) }

    override fun debugCaptureFrame(sessionId: String, callback: (Result<ByteArray>) -> Unit) =
        dispatch.async(lane, callback, check = { Check.id("sessionId", sessionId) }) { done -> port.debugCaptureFrame(sessionId, done) }

    override fun dispose(sessionId: String, callback: (Result<Unit>) -> Unit) =
        dispatch.async(lane, callback, check = { Check.id("sessionId", sessionId) }) { done -> port.dispose(sessionId, done) }
}
