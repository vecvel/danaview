// OWNER: ENG-08 (frozen by ENG-06, D-42)
//
// What the host API glue needs from the engine, one port per host API (ARCH §12.6). The glue
// validates arguments, chooses the thread and maps errors; the ports only do the work. Production
// ports (ContextPorts.kt) delegate to the service classes of ARCH §4.4 held by EngineContext; the
// glue JVM tests use fakes, so the glue tests stay valid whatever the service tickets implement.
//
// Each method is called on the thread the glue chose (documented per host API impl) and completes
// its Completion exactly once, from any thread.

package com.vecvel.vwish.editor.engine.glue

import com.vecvel.vwish.editor.engine.core.Completion
import com.vecvel.vwish.editor.engine.core.Paths
import com.vecvel.vwish.editor.engine.pigeon.CacheTrimLevelMsg
import com.vecvel.vwish.editor.engine.pigeon.CapabilitiesMsg
import com.vecvel.vwish.editor.engine.pigeon.ColorMsg
import com.vecvel.vwish.editor.engine.pigeon.CompatibilityMsg
import com.vecvel.vwish.editor.engine.pigeon.DetachedHandoffMsg
import com.vecvel.vwish.editor.engine.pigeon.EditingModeMsg
import com.vecvel.vwish.editor.engine.pigeon.EncodeSettingsMsg
import com.vecvel.vwish.editor.engine.pigeon.ExportJobRecordMsg
import com.vecvel.vwish.editor.engine.pigeon.ExportPreflightMsg
import com.vecvel.vwish.editor.engine.pigeon.FileHandoffResultMsg
import com.vecvel.vwish.editor.engine.pigeon.JobPriorityMsg
import com.vecvel.vwish.editor.engine.pigeon.JobRequestMsg
import com.vecvel.vwish.editor.engine.pigeon.LookSpecMsg
import com.vecvel.vwish.editor.engine.pigeon.LoopMsg
import com.vecvel.vwish.editor.engine.pigeon.MediaPickRequestMsg
import com.vecvel.vwish.editor.engine.pigeon.MediaRefMsg
import com.vecvel.vwish.editor.engine.pigeon.MediaStatMsg
import com.vecvel.vwish.editor.engine.pigeon.MicPermissionMsg
import com.vecvel.vwish.editor.engine.pigeon.PickedMediaMsg
import com.vecvel.vwish.editor.engine.pigeon.PlanAckMsg
import com.vecvel.vwish.editor.engine.pigeon.PreviewConfigMsg
import com.vecvel.vwish.editor.engine.pigeon.PreviewOpenedMsg
import com.vecvel.vwish.editor.engine.pigeon.PreviewQualityMsg
import com.vecvel.vwish.editor.engine.pigeon.ProbeMsg
import com.vecvel.vwish.editor.engine.pigeon.ProxyStatusMsg
import com.vecvel.vwish.editor.engine.pigeon.RecordedAssetMsg
import com.vecvel.vwish.editor.engine.pigeon.ResolvedMediaMsg
import com.vecvel.vwish.editor.engine.pigeon.SeekAckMsg
import com.vecvel.vwish.editor.engine.pigeon.ThumbPriorityMsg
import com.vecvel.vwish.editor.engine.pigeon.ThumbnailRequestMsg
import com.vecvel.vwish.editor.engine.pigeon.ThumbnailTileMsg

/** `EngineHostApi` work. */
interface EngineRootPort {
    /** The installed roots, or null before `initialize`. */
    val paths: Paths?

    /** Installs and creates the roots (vwish-io). */
    fun installRoots(paths: Paths, done: Completion<Unit>)

    /** Capabilities (vwish-io). */
    fun capabilities(done: Completion<CapabilitiesMsg>)

    /** Edit compatibility of a path or URI (vwish-io). */
    fun compatibility(uri: String, done: Completion<CompatibilityMsg>)

    /** Probe (vwish-io). */
    fun probe(media: ResolvedMediaMsg, done: Completion<ProbeMsg>)

    /** Free bytes on the volume of an absolute path (vwish-io). */
    fun freeBytes(path: String, done: Completion<Long>)

    /** Drops caches per level (fans out to the cache owners' lanes). */
    fun trimCaches(level: CacheTrimLevelMsg)
}

/** `PreviewHostApi` work (vwish-preview). Unknown session ids fail with `internal`, except dispose. */
interface PreviewPort {
    fun open(config: PreviewConfigMsg, done: Completion<PreviewOpenedMsg>)
    fun setPlan(sessionId: String, plan: ByteArray, done: Completion<PlanAckMsg>)
    fun applyPatch(sessionId: String, patch: ByteArray, done: Completion<PlanAckMsg>)
    fun setTransient(sessionId: String, itemId: String, params: ByteArray)
    fun clearTransient(sessionId: String, itemId: String)
    fun play(sessionId: String, loop: LoopMsg?, done: Completion<Long>)
    fun pause(sessionId: String, done: Completion<Long>)
    fun seek(sessionId: String, timeUs: Long, exact: Boolean, done: Completion<SeekAckMsg>)
    fun setQuality(sessionId: String, quality: PreviewQualityMsg, done: Completion<Unit>)
    fun setUseProxies(sessionId: String, on: Boolean, done: Completion<Unit>)
    fun setEditingMode(sessionId: String, mode: EditingModeMsg, done: Completion<Unit>)
    fun showSourceFrame(sessionId: String, media: ResolvedMediaMsg, sourceTimeUs: Long, done: Completion<Unit>)
    fun sampleColor(sessionId: String, itemId: String, x: Double, y: Double, done: Completion<ColorMsg?>)
    fun renderLookStills(sessionId: String, itemId: String, looks: List<LookSpecMsg>, heightPx: Long, done: Completion<List<ByteArray>>)
    fun refresh(sessionId: String, done: Completion<Unit>)
    fun debugCaptureFrame(sessionId: String, done: Completion<ByteArray>)
    fun dispose(sessionId: String, done: Completion<Unit>)

    /** The Flutter engine that owns this port detached: release its sessions. */
    fun releaseAll()
}

/** `JobsHostApi` work (thumbnails and jobs on vwish-jobs, proxy status on vwish-io). */
interface JobsPort {
    fun thumbnailTile(requestId: String, request: ThumbnailRequestMsg, priority: ThumbPriorityMsg, done: Completion<ThumbnailTileMsg>)
    fun cancelThumbnail(requestId: String)
    fun startJob(request: JobRequestMsg, done: Completion<String>)
    fun cancelJob(jobId: String)
    fun setJobPriority(jobId: String, priority: JobPriorityMsg)
    fun proxyStatus(fingerprint: String, done: Completion<ProxyStatusMsg>)
}

/** `ExportHostApi` work (vwish-export). */
interface ExportPort {
    fun preflight(plan: ByteArray, settings: EncodeSettingsMsg, done: Completion<ExportPreflightMsg>)
    fun start(
        plan: ByteArray,
        settings: EncodeSettingsMsg,
        outputPath: String,
        title: String,
        whenDetached: DetachedHandoffMsg,
        done: Completion<String>,
    )
    fun cancel(jobId: String, done: Completion<Unit>)
    fun activeJobs(done: Completion<List<ExportJobRecordMsg>>)
    fun consumeJobRecord(jobId: String)
}

/** `RecorderHostApi` work (permission/start/stop/cancel on vwish-io; request/settings on main). */
interface RecorderPort {
    fun permission(done: Completion<MicPermissionMsg>)
    fun requestPermission(done: Completion<MicPermissionMsg>)
    fun openSettings(done: Completion<Unit>)
    fun start(outputPath: String, done: Completion<String>)
    fun stop(recordingId: String, done: Completion<RecordedAssetMsg>)
    fun cancel(recordingId: String, done: Completion<Unit>)
}

/** `PlatformHostApi` work (UI flows on main; access, stat, hash and gallery on vwish-io). */
interface PlatformPort {
    fun pick(request: MediaPickRequestMsg, done: Completion<List<PickedMediaMsg>>)
    fun saveToPhotos(path: String, done: Completion<FileHandoffResultMsg>)
    fun saveToFiles(path: String, suggestedName: String, done: Completion<FileHandoffResultMsg>)
    fun share(path: String, done: Completion<FileHandoffResultMsg>)
    fun persistUriGrant(uri: String, done: Completion<Unit>)
    fun releaseUriGrant(uri: String, done: Completion<Unit>)
    fun remainingGrantBudget(done: Completion<Long>)
    fun stat(media: MediaRefMsg, done: Completion<MediaStatMsg?>)
    fun quickHash(media: MediaRefMsg, done: Completion<String>)
    fun requestNotificationPermission(done: Completion<Boolean>)
    fun acquireBackground(title: String, done: Completion<String?>)
    fun updateBackground(leaseId: String, progress: Double, done: Completion<Unit>)
    fun releaseBackground(leaseId: String, done: Completion<Unit>)
    fun setDropTargetEnabled(enabled: Boolean, done: Completion<Unit>)
}
