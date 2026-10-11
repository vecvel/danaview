// OWNER: ENG-08 (frozen by ENG-06, D-42)
//
// Production ports: delegate each host API call to the service classes of ARCH §4.4 held by the
// process EngineContext (D-33 placeholders until AND-02..AND-17 land). Glue-local behaviour that no
// service ticket owns lives here too: freeBytes (StatFs), cache-trim fan-out, and preview session
// lookup.

package com.vecvel.vwish.editor.engine.glue

import android.os.StatFs
import com.vecvel.vwish.editor.engine.core.Completion
import com.vecvel.vwish.editor.engine.core.EngineContext
import com.vecvel.vwish.editor.engine.core.EngineErrorCode
import com.vecvel.vwish.editor.engine.core.EngineException
import com.vecvel.vwish.editor.engine.core.Paths
import com.vecvel.vwish.editor.engine.core.fail
import com.vecvel.vwish.editor.engine.core.succeed
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
import com.vecvel.vwish.editor.engine.preview.PreviewSession
import io.flutter.view.TextureRegistry
import java.io.File

/** [EngineRootPort] over the engine context. */
class ContextEngineRootPort(private val ctx: EngineContext) : EngineRootPort {
    override val paths: Paths? get() = ctx.pathsOrNull

    override fun installRoots(paths: Paths, done: Completion<Unit>) {
        ctx.installRoots(paths)
        done.succeed(Unit)
    }

    override fun capabilities(done: Completion<CapabilitiesMsg>) = ctx.capabilities.load(done)

    override fun compatibility(uri: String, done: Completion<CompatibilityMsg>) = ctx.compatibility.check(uri, done)

    override fun probe(media: ResolvedMediaMsg, done: Completion<ProbeMsg>) = ctx.probe.probe(media, done)

    override fun freeBytes(path: String, done: Completion<Long>) {
        var dir: File? = File(path)
        while (dir != null && !dir.exists()) dir = dir.parentFile
        if (dir == null) throw EngineException(EngineErrorCode.io, "no existing directory for the volume")
        done.succeed(StatFs(dir.path).availableBytes)
    }

    override fun trimCaches(level: CacheTrimLevelMsg) {
        val threads = ctx.threads
        threads.jobs.execute { guarded { ctx.thumbnails.trim(level) } }
        threads.preview.execute {
            guarded { ctx.previews.trim(level) }
            guarded { ctx.sourceFrames.trim(level) }
        }
        threads.io.execute { guarded { ctx.diskCache.trim(level) } }
    }

    private inline fun guarded(block: () -> Unit) {
        try {
            block()
        } catch (t: Throwable) {
            GlueLog.warn("trimCaches", t)
        }
    }
}

/** [PreviewPort] over the session manager, for the Flutter engine that owns [textures]. */
class ContextPreviewPort(private val ctx: EngineContext, private val textures: TextureRegistry) : PreviewPort {
    private fun <T> withSession(sessionId: String, done: Completion<T>, block: (PreviewSession) -> Unit) {
        val session = ctx.previews.get(sessionId)
        if (session == null) done.fail(unknownSession()) else block(session)
    }

    override fun open(config: PreviewConfigMsg, done: Completion<PreviewOpenedMsg>) = ctx.previews.open(config, textures, done)

    override fun setPlan(sessionId: String, plan: ByteArray, done: Completion<PlanAckMsg>) =
        withSession(sessionId, done) { it.setPlan(plan, done) }

    override fun applyPatch(sessionId: String, patch: ByteArray, done: Completion<PlanAckMsg>) =
        withSession(sessionId, done) { it.applyPatch(patch, done) }

    override fun setTransient(sessionId: String, itemId: String, params: ByteArray) {
        ctx.previews.get(sessionId)?.setTransient(itemId, params)
    }

    override fun clearTransient(sessionId: String, itemId: String) {
        ctx.previews.get(sessionId)?.clearTransient(itemId)
    }

    override fun play(sessionId: String, loop: LoopMsg?, done: Completion<Long>) = withSession(sessionId, done) { it.play(loop, done) }

    override fun pause(sessionId: String, done: Completion<Long>) = withSession(sessionId, done) { it.pause(done) }

    override fun seek(sessionId: String, timeUs: Long, exact: Boolean, done: Completion<SeekAckMsg>) =
        withSession(sessionId, done) { it.seek(timeUs, exact, done) }

    override fun setQuality(sessionId: String, quality: PreviewQualityMsg, done: Completion<Unit>) =
        withSession(sessionId, done) { it.setQuality(quality, done) }

    override fun setUseProxies(sessionId: String, on: Boolean, done: Completion<Unit>) =
        withSession(sessionId, done) { it.setUseProxies(on, done) }

    override fun setEditingMode(sessionId: String, mode: EditingModeMsg, done: Completion<Unit>) =
        withSession(sessionId, done) { it.setEditingMode(mode, done) }

    override fun showSourceFrame(sessionId: String, media: ResolvedMediaMsg, sourceTimeUs: Long, done: Completion<Unit>) =
        withSession(sessionId, done) { it.showSourceFrame(media, sourceTimeUs, done) }

    override fun sampleColor(sessionId: String, itemId: String, x: Double, y: Double, done: Completion<ColorMsg?>) =
        withSession(sessionId, done) { it.sampleColor(itemId, x, y, done) }

    override fun renderLookStills(
        sessionId: String,
        itemId: String,
        looks: List<LookSpecMsg>,
        heightPx: Long,
        done: Completion<List<ByteArray>>,
    ) = withSession(sessionId, done) { it.renderLookStills(itemId, looks, heightPx, done) }

    override fun refresh(sessionId: String, done: Completion<Unit>) = withSession(sessionId, done) { it.refresh(done) }

    override fun debugCaptureFrame(sessionId: String, done: Completion<ByteArray>) =
        withSession(sessionId, done) { it.debugCaptureFrame(done) }

    override fun dispose(sessionId: String, done: Completion<Unit>) {
        val session = ctx.previews.get(sessionId)
        if (session == null) done.succeed(Unit) else session.dispose(done)
    }

    override fun releaseAll() = ctx.previews.releaseAll(textures)

    private fun unknownSession() = EngineException(EngineErrorCode.internal, "unknown preview session")
}

/** [JobsPort] over thumbnails, the job registry and the proxy registry. */
class ContextJobsPort(private val ctx: EngineContext) : JobsPort {
    override fun thumbnailTile(requestId: String, request: ThumbnailRequestMsg, priority: ThumbPriorityMsg, done: Completion<ThumbnailTileMsg>) =
        ctx.thumbnails.requestTile(requestId, request, priority, done)

    override fun cancelThumbnail(requestId: String) = ctx.thumbnails.cancel(requestId)

    override fun startJob(request: JobRequestMsg, done: Completion<String>) = ctx.jobs.start(request, done)

    override fun cancelJob(jobId: String) = ctx.jobs.cancel(jobId)

    override fun setJobPriority(jobId: String, priority: JobPriorityMsg) = ctx.jobs.setPriority(jobId, priority)

    override fun proxyStatus(fingerprint: String, done: Completion<ProxyStatusMsg>) = ctx.proxies.status(fingerprint, done)
}

/** [ExportPort] over the export coordinator. */
class ContextExportPort(private val ctx: EngineContext) : ExportPort {
    override fun preflight(plan: ByteArray, settings: EncodeSettingsMsg, done: Completion<ExportPreflightMsg>) =
        ctx.exports.preflight(plan, settings, done)

    override fun start(
        plan: ByteArray,
        settings: EncodeSettingsMsg,
        outputPath: String,
        title: String,
        whenDetached: DetachedHandoffMsg,
        done: Completion<String>,
    ) = ctx.exports.start(plan, settings, outputPath, title, whenDetached, done)

    override fun cancel(jobId: String, done: Completion<Unit>) = ctx.exports.cancel(jobId, done)

    override fun activeJobs(done: Completion<List<ExportJobRecordMsg>>) = ctx.exports.activeJobs(done)

    override fun consumeJobRecord(jobId: String) = ctx.exports.consumeJobRecord(jobId)
}

/** [RecorderPort] over the voice recorder. */
class ContextRecorderPort(private val ctx: EngineContext) : RecorderPort {
    override fun permission(done: Completion<MicPermissionMsg>) = ctx.recorder.permission(done)

    override fun requestPermission(done: Completion<MicPermissionMsg>) = ctx.recorder.requestPermission(done)

    override fun openSettings(done: Completion<Unit>) = ctx.recorder.openSettings(done)

    override fun start(outputPath: String, done: Completion<String>) = ctx.recorder.start(outputPath, done)

    override fun stop(recordingId: String, done: Completion<RecordedAssetMsg>) = ctx.recorder.stop(recordingId, done)

    override fun cancel(recordingId: String, done: Completion<Unit>) = ctx.recorder.cancel(recordingId, done)
}

/** [PlatformPort] over pickers, handoff, media access, permissions, leases and the drop target. */
class ContextPlatformPort(private val ctx: EngineContext) : PlatformPort {
    override fun pick(request: MediaPickRequestMsg, done: Completion<List<PickedMediaMsg>>) = ctx.picker.pick(request, done)

    override fun saveToPhotos(path: String, done: Completion<FileHandoffResultMsg>) = ctx.mediaStore.saveToPhotos(path, done)

    override fun saveToFiles(path: String, suggestedName: String, done: Completion<FileHandoffResultMsg>) =
        ctx.fileHandoff.saveToFiles(path, suggestedName, done)

    override fun share(path: String, done: Completion<FileHandoffResultMsg>) = ctx.fileHandoff.share(path, done)

    override fun persistUriGrant(uri: String, done: Completion<Unit>) = ctx.mediaAccess.persistUriGrant(uri, done)

    override fun releaseUriGrant(uri: String, done: Completion<Unit>) = ctx.mediaAccess.releaseUriGrant(uri, done)

    override fun remainingGrantBudget(done: Completion<Long>) = ctx.mediaAccess.remainingGrantBudget(done)

    override fun stat(media: MediaRefMsg, done: Completion<MediaStatMsg?>) = ctx.mediaAccess.stat(media, done)

    override fun quickHash(media: MediaRefMsg, done: Completion<String>) = ctx.mediaAccess.quickHash(media, done)

    override fun requestNotificationPermission(done: Completion<Boolean>) = ctx.permissions.requestNotificationPermission(done)

    override fun acquireBackground(title: String, done: Completion<String?>) = ctx.backgroundGuard.acquire(title, done)

    override fun updateBackground(leaseId: String, progress: Double, done: Completion<Unit>) =
        ctx.backgroundGuard.update(leaseId, progress, done)

    override fun releaseBackground(leaseId: String, done: Completion<Unit>) = ctx.backgroundGuard.release(leaseId, done)

    override fun setDropTargetEnabled(enabled: Boolean, done: Completion<Unit>) = ctx.dropTarget.setEnabled(enabled, done)
}
