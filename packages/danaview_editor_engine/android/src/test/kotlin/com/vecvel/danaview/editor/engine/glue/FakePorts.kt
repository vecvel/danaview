// OWNER: ENG-08
//
// Fake ports for the host API glue tests: every call is logged with the thread it ran on, and the
// test decides each answer.

package com.vecvel.danaview.editor.engine.glue

import com.vecvel.danaview.editor.engine.core.Completion
import com.vecvel.danaview.editor.engine.core.Paths
import com.vecvel.danaview.editor.engine.pigeon.CacheTrimLevelMsg
import com.vecvel.danaview.editor.engine.pigeon.CapabilitiesMsg
import com.vecvel.danaview.editor.engine.pigeon.ColorMsg
import com.vecvel.danaview.editor.engine.pigeon.CompatibilityMsg
import com.vecvel.danaview.editor.engine.pigeon.DetachedHandoffMsg
import com.vecvel.danaview.editor.engine.pigeon.EditingModeMsg
import com.vecvel.danaview.editor.engine.pigeon.EncodeSettingsMsg
import com.vecvel.danaview.editor.engine.pigeon.ExportJobRecordMsg
import com.vecvel.danaview.editor.engine.pigeon.ExportPreflightMsg
import com.vecvel.danaview.editor.engine.pigeon.FileHandoffResultMsg
import com.vecvel.danaview.editor.engine.pigeon.JobPriorityMsg
import com.vecvel.danaview.editor.engine.pigeon.JobRequestMsg
import com.vecvel.danaview.editor.engine.pigeon.LookSpecMsg
import com.vecvel.danaview.editor.engine.pigeon.LoopMsg
import com.vecvel.danaview.editor.engine.pigeon.MediaPickRequestMsg
import com.vecvel.danaview.editor.engine.pigeon.MediaRefMsg
import com.vecvel.danaview.editor.engine.pigeon.MediaStatMsg
import com.vecvel.danaview.editor.engine.pigeon.MicPermissionMsg
import com.vecvel.danaview.editor.engine.pigeon.PickedMediaMsg
import com.vecvel.danaview.editor.engine.pigeon.PlanAckMsg
import com.vecvel.danaview.editor.engine.pigeon.PreviewConfigMsg
import com.vecvel.danaview.editor.engine.pigeon.PreviewOpenedMsg
import com.vecvel.danaview.editor.engine.pigeon.PreviewQualityMsg
import com.vecvel.danaview.editor.engine.pigeon.ProbeMsg
import com.vecvel.danaview.editor.engine.pigeon.ProxyStatusMsg
import com.vecvel.danaview.editor.engine.pigeon.RecordedAssetMsg
import com.vecvel.danaview.editor.engine.pigeon.ResolvedMediaMsg
import com.vecvel.danaview.editor.engine.pigeon.SeekAckMsg
import com.vecvel.danaview.editor.engine.pigeon.ThumbPriorityMsg
import com.vecvel.danaview.editor.engine.pigeon.ThumbnailRequestMsg
import com.vecvel.danaview.editor.engine.pigeon.ThumbnailTileMsg

/** One logged port call. */
data class PortCall(val name: String, val args: List<Any?>, val where: Where?)

/** Call log and answers shared by the fake ports. */
class PortCalls(private val trace: Trace) {
    val log = mutableListOf<PortCall>()

    /** The answer for a call; default: success with null (Unit-like). */
    var answer: (name: String, args: List<Any?>) -> Result<Any?> = { _, _ -> Result.success(Unit) }

    /** When false, completions are held in [held] instead of being answered. */
    var answerImmediately = true
    val held = mutableListOf<Pair<String, Completion<Any?>>>()

    fun names(): List<String> = log.map { it.name }

    @Suppress("UNCHECKED_CAST")
    fun <T> call(name: String, vararg args: Any?, done: Completion<T>) {
        log.add(PortCall(name, args.toList(), trace.current))
        val any = done as Completion<Any?>
        if (answerImmediately) any(answer(name, args.toList())) else held.add(name to any)
    }

    fun fire(name: String, vararg args: Any?) {
        log.add(PortCall(name, args.toList(), trace.current))
    }
}

class FakeRootPort(private val calls: PortCalls, override var paths: Paths? = TestRoots.paths) : EngineRootPort {
    override fun installRoots(paths: Paths, done: Completion<Unit>) = calls.call("installRoots", paths, done = done)
    override fun capabilities(done: Completion<CapabilitiesMsg>) = calls.call("capabilities", done = done)
    override fun compatibility(uri: String, done: Completion<CompatibilityMsg>) = calls.call("compatibility", uri, done = done)
    override fun probe(media: ResolvedMediaMsg, done: Completion<ProbeMsg>) = calls.call("probe", media, done = done)
    override fun freeBytes(path: String, done: Completion<Long>) = calls.call("freeBytes", path, done = done)
    override fun trimCaches(level: CacheTrimLevelMsg) = calls.fire("trimCaches", level)
}

class FakePreviewPort(private val calls: PortCalls) : PreviewPort {
    override fun open(config: PreviewConfigMsg, done: Completion<PreviewOpenedMsg>) = calls.call("open", config, done = done)
    override fun setPlan(sessionId: String, plan: ByteArray, done: Completion<PlanAckMsg>) = calls.call("setPlan", sessionId, done = done)
    override fun applyPatch(sessionId: String, patch: ByteArray, done: Completion<PlanAckMsg>) = calls.call("applyPatch", sessionId, done = done)
    override fun setTransient(sessionId: String, itemId: String, params: ByteArray) = calls.fire("setTransient", sessionId, itemId)
    override fun clearTransient(sessionId: String, itemId: String) = calls.fire("clearTransient", sessionId, itemId)
    override fun play(sessionId: String, loop: LoopMsg?, done: Completion<Long>) = calls.call("play", sessionId, loop, done = done)
    override fun pause(sessionId: String, done: Completion<Long>) = calls.call("pause", sessionId, done = done)
    override fun seek(sessionId: String, timeUs: Long, exact: Boolean, done: Completion<SeekAckMsg>) =
        calls.call("seek", sessionId, timeUs, exact, done = done)
    override fun setQuality(sessionId: String, quality: PreviewQualityMsg, done: Completion<Unit>) = calls.call("setQuality", sessionId, done = done)
    override fun setUseProxies(sessionId: String, on: Boolean, done: Completion<Unit>) = calls.call("setUseProxies", sessionId, done = done)
    override fun setEditingMode(sessionId: String, mode: EditingModeMsg, done: Completion<Unit>) = calls.call("setEditingMode", sessionId, done = done)
    override fun showSourceFrame(sessionId: String, media: ResolvedMediaMsg, sourceTimeUs: Long, done: Completion<Unit>) =
        calls.call("showSourceFrame", sessionId, done = done)
    override fun sampleColor(sessionId: String, itemId: String, x: Double, y: Double, done: Completion<ColorMsg?>) =
        calls.call("sampleColor", sessionId, done = done)
    override fun renderLookStills(sessionId: String, itemId: String, looks: List<LookSpecMsg>, heightPx: Long, done: Completion<List<ByteArray>>) =
        calls.call("renderLookStills", sessionId, done = done)
    override fun refresh(sessionId: String, done: Completion<Unit>) = calls.call("refresh", sessionId, done = done)
    override fun debugCaptureFrame(sessionId: String, done: Completion<ByteArray>) = calls.call("debugCaptureFrame", sessionId, done = done)
    override fun dispose(sessionId: String, done: Completion<Unit>) = calls.call("dispose", sessionId, done = done)
    override fun releaseAll() = calls.fire("releaseAll")
}

class FakeJobsPort(private val calls: PortCalls) : JobsPort {
    override fun thumbnailTile(requestId: String, request: ThumbnailRequestMsg, priority: ThumbPriorityMsg, done: Completion<ThumbnailTileMsg>) =
        calls.call("thumbnailTile", requestId, done = done)
    override fun cancelThumbnail(requestId: String) = calls.fire("cancelThumbnail", requestId)
    override fun startJob(request: JobRequestMsg, done: Completion<String>) = calls.call("startJob", request, done = done)
    override fun cancelJob(jobId: String) = calls.fire("cancelJob", jobId)
    override fun setJobPriority(jobId: String, priority: JobPriorityMsg) = calls.fire("setJobPriority", jobId, priority)
    override fun proxyStatus(fingerprint: String, done: Completion<ProxyStatusMsg>) = calls.call("proxyStatus", fingerprint, done = done)
}

class FakeExportPort(private val calls: PortCalls) : ExportPort {
    override fun preflight(plan: ByteArray, settings: EncodeSettingsMsg, done: Completion<ExportPreflightMsg>) = calls.call("preflight", done = done)
    override fun start(
        plan: ByteArray,
        settings: EncodeSettingsMsg,
        outputPath: String,
        title: String,
        whenDetached: DetachedHandoffMsg,
        done: Completion<String>,
    ) = calls.call("start", outputPath, title, whenDetached, done = done)
    override fun cancel(jobId: String, done: Completion<Unit>) = calls.call("cancel", jobId, done = done)
    override fun activeJobs(done: Completion<List<ExportJobRecordMsg>>) = calls.call("activeJobs", done = done)
    override fun consumeJobRecord(jobId: String) = calls.fire("consumeJobRecord", jobId)
}

class FakeRecorderPort(private val calls: PortCalls) : RecorderPort {
    override fun permission(done: Completion<MicPermissionMsg>) = calls.call("permission", done = done)
    override fun requestPermission(done: Completion<MicPermissionMsg>) = calls.call("requestPermission", done = done)
    override fun openSettings(done: Completion<Unit>) = calls.call("openSettings", done = done)
    override fun start(outputPath: String, done: Completion<String>) = calls.call("start", outputPath, done = done)
    override fun stop(recordingId: String, done: Completion<RecordedAssetMsg>) = calls.call("stop", recordingId, done = done)
    override fun cancel(recordingId: String, done: Completion<Unit>) = calls.call("cancel", recordingId, done = done)
}

class FakePlatformPort(private val calls: PortCalls) : PlatformPort {
    override fun pick(request: MediaPickRequestMsg, done: Completion<List<PickedMediaMsg>>) = calls.call("pick", done = done)
    override fun saveToPhotos(path: String, done: Completion<FileHandoffResultMsg>) = calls.call("saveToPhotos", path, done = done)
    override fun saveToFiles(path: String, suggestedName: String, done: Completion<FileHandoffResultMsg>) =
        calls.call("saveToFiles", path, suggestedName, done = done)
    override fun share(path: String, done: Completion<FileHandoffResultMsg>) = calls.call("share", path, done = done)
    override fun persistUriGrant(uri: String, done: Completion<Unit>) = calls.call("persistUriGrant", uri, done = done)
    override fun releaseUriGrant(uri: String, done: Completion<Unit>) = calls.call("releaseUriGrant", uri, done = done)
    override fun remainingGrantBudget(done: Completion<Long>) = calls.call("remainingGrantBudget", done = done)
    override fun stat(media: MediaRefMsg, done: Completion<MediaStatMsg?>) = calls.call("stat", media, done = done)
    override fun quickHash(media: MediaRefMsg, done: Completion<String>) = calls.call("quickHash", media, done = done)
    override fun requestNotificationPermission(done: Completion<Boolean>) = calls.call("requestNotificationPermission", done = done)
    override fun acquireBackground(title: String, done: Completion<String?>) = calls.call("acquireBackground", title, done = done)
    override fun updateBackground(leaseId: String, progress: Double, done: Completion<Unit>) =
        calls.call("updateBackground", leaseId, progress, done = done)
    override fun releaseBackground(leaseId: String, done: Completion<Unit>) = calls.call("releaseBackground", leaseId, done = done)
    override fun setDropTargetEnabled(enabled: Boolean, done: Completion<Unit>) = calls.call("setDropTargetEnabled", enabled, done = done)
}
