// OWNER: ENG-08 (frozen by ENG-06, D-42; amended by INT-06 for the D-45 render-preview calls and
// by INT-07: notification texts, isRecording, materializePick)
//
// What the host API glue needs from the engine, one port per host API (ARCH §12.6). The glue
// validates arguments, chooses the thread and maps errors; the ports only do the work. Production
// ports (ContextPorts.kt) delegate to the service classes of ARCH §4.4 held by EngineContext; the
// glue JVM tests use fakes, so the glue tests stay valid whatever the service tickets implement.
//
// Each method is called on the thread the glue chose (documented per host API impl) and completes
// its Completion exactly once, from any thread.
//
// The D-45 render-preview methods (INT-06: startRenderPreview, setRenderedRanges, powerState) have
// default bodies that fail with `notSupportedOnDevice`, so port fakes written before INT-06 keep
// compiling; the Context ports route them to AND-18's `preview/render/` services. The INT-07
// methods (setExportTexts, isRecording, materializePick) have defaults for the same reason.

package com.vecvel.danaview.editor.engine.glue

import com.vecvel.danaview.editor.engine.core.Completion
import com.vecvel.danaview.editor.engine.core.EngineErrors
import com.vecvel.danaview.editor.engine.core.Paths
import com.vecvel.danaview.editor.engine.core.fail
import com.vecvel.danaview.editor.engine.pigeon.CacheTrimLevelMsg
import com.vecvel.danaview.editor.engine.pigeon.CapabilitiesMsg
import com.vecvel.danaview.editor.engine.pigeon.ColorMsg
import com.vecvel.danaview.editor.engine.pigeon.CompatibilityMsg
import com.vecvel.danaview.editor.engine.pigeon.DetachedHandoffMsg
import com.vecvel.danaview.editor.engine.pigeon.EditingModeMsg
import com.vecvel.danaview.editor.engine.pigeon.EncodeSettingsMsg
import com.vecvel.danaview.editor.engine.pigeon.ExportJobRecordMsg
import com.vecvel.danaview.editor.engine.pigeon.ExportNotificationTextsMsg
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
import com.vecvel.danaview.editor.engine.pigeon.PowerStateMsg
import com.vecvel.danaview.editor.engine.pigeon.PreviewConfigMsg
import com.vecvel.danaview.editor.engine.pigeon.PreviewOpenedMsg
import com.vecvel.danaview.editor.engine.pigeon.PreviewQualityMsg
import com.vecvel.danaview.editor.engine.pigeon.ProbeMsg
import com.vecvel.danaview.editor.engine.pigeon.ProxyStatusMsg
import com.vecvel.danaview.editor.engine.pigeon.RecordedAssetMsg
import com.vecvel.danaview.editor.engine.pigeon.RenderedRangeMsg
import com.vecvel.danaview.editor.engine.pigeon.ResolvedMediaMsg
import com.vecvel.danaview.editor.engine.pigeon.SeekAckMsg
import com.vecvel.danaview.editor.engine.pigeon.ThumbPriorityMsg
import com.vecvel.danaview.editor.engine.pigeon.ThumbnailRequestMsg
import com.vecvel.danaview.editor.engine.pigeon.ThumbnailTileMsg
import java.io.File

/** `EngineHostApi` work. */
interface EngineRootPort {
    /** The installed roots, or null before `initialize`. */
    val paths: Paths?

    /** Installs and creates the roots (danaview-io). */
    fun installRoots(paths: Paths, done: Completion<Unit>)

    /** Capabilities (danaview-io). */
    fun capabilities(done: Completion<CapabilitiesMsg>)

    /** Edit compatibility of a path or URI (danaview-io). */
    fun compatibility(uri: String, done: Completion<CompatibilityMsg>)

    /** Probe (danaview-io). */
    fun probe(media: ResolvedMediaMsg, done: Completion<ProbeMsg>)

    /** Free bytes on the volume of an absolute path (danaview-io). */
    fun freeBytes(path: String, done: Completion<Long>)

    /** Drops caches per level (fans out to the cache owners' lanes). */
    fun trimCaches(level: CacheTrimLevelMsg)

    /** The localized export notification texts from `initialize` (INT-07; validated by the glue). */
    fun setExportTexts(texts: ExportNotificationTextsMsg) = Unit
}

/** `PreviewHostApi` work (danaview-preview). Unknown session ids fail with `internal`, except dispose. */
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

    /**
     * Replaces the rendered ranges of a session (D-45; validated by the glue: sorted, non-overlapping,
     * files inside `<cache>/renders/`). The session drops a range when an applied patch touches it
     * and every range on `setPlan`, until the next call (ARCH §12.2).
     */
    fun setRenderedRanges(sessionId: String, ranges: List<RenderedRangeMsg>, done: Completion<Unit>) =
        done.fail(EngineErrors.notSupported("rendered ranges"))
}

/** `JobsHostApi` work (thumbnails and jobs on danaview-jobs, proxy status on danaview-io). */
interface JobsPort {
    fun thumbnailTile(requestId: String, request: ThumbnailRequestMsg, priority: ThumbPriorityMsg, done: Completion<ThumbnailTileMsg>)
    fun cancelThumbnail(requestId: String)
    fun startJob(request: JobRequestMsg, done: Completion<String>)
    fun cancelJob(jobId: String)
    fun setJobPriority(jobId: String, priority: JobPriorityMsg)
    fun proxyStatus(fingerprint: String, done: Completion<ProxyStatusMsg>)

    /**
     * Starts a `renderPreview` job (D-45) and completes with its job id; the job is registered with the
     * job registry, so cancelJob, setJobPriority and the job events work as for every job. [plan] is
     * the range plan's UTF-8 JSON, [outputPath] lies inside `<cache>/renders/` (checked by the glue).
     */
    fun startRenderPreview(request: JobRequestMsg, plan: ByteArray, outputPath: String, done: Completion<String>) =
        done.fail(EngineErrors.notSupported("render preview"))
}

/** `ExportHostApi` work (danaview-export). */
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

    /** Texts an export `start` carried (INT-07): they replace the current ones before the job starts. */
    fun setExportTexts(texts: ExportNotificationTextsMsg) = Unit
}

/** `RecorderHostApi` work (permission/start/stop/cancel on danaview-io; request/settings on main). */
interface RecorderPort {
    fun permission(done: Completion<MicPermissionMsg>)
    fun requestPermission(done: Completion<MicPermissionMsg>)
    fun openSettings(done: Completion<Unit>)
    fun start(outputPath: String, done: Completion<String>)
    fun stop(recordingId: String, done: Completion<RecordedAssetMsg>)
    fun cancel(recordingId: String, done: Completion<Unit>)

    /** Whether a recording captures now (INT-07, danaview-io); changes are `recordingChanged` events. */
    fun isRecording(done: Completion<Boolean>) = done.fail(EngineErrors.notSupported("recording state"))
}

/** `PlatformHostApi` work (UI flows on main; access, stat, hash and gallery on danaview-io). */
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

    /** Charging and battery-saver state (D-45, main); changes are `signal(powerStateChanged)` events. */
    fun powerState(done: Completion<PowerStateMsg>) = done.fail(EngineErrors.notSupported("power state"))

    /**
     * Copies a non-persistable pick into a new directory under [intoDir] (inside `<cache>/work/`,
     * checked by the glue) and completes with the copy's path (INT-07, danaview-io).
     */
    fun materializePick(uri: String, intoDir: File, done: Completion<String>) = done.fail(EngineErrors.notSupported("materializePick"))
}
