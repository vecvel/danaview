@file:OptIn(UnstableApi::class, ExperimentalApi::class)
// OWNER: AND-18
//
// Render-preview jobs (ARCH D-45 (A), §12.3 `MediaJobs.renderPreview`; INT-06 glue →
// RenderPreviewServices.jobs, called on danaview-jobs after the glue checked the request: a plan
// payload and an output inside `<cache>/danaview/editor/renders/`).
//
// [RenderPreviewJobService.start] decodes the range plan (RenderPreviewSpecs.exportPlan: refusals
// are `planInvalid` / `mediaOffline` before a job exists), registers a [RenderPreviewJob] with
// AND-05's JobRegistry and completes with its id before the job can emit (the body waits for the
// reply). The registry runs it like every media job: priority order, concurrency per tier, cancel
// (the partial file is deleted, the job ends `cancelled`), progress ≤ 4 Hz and done/failed events
// keyed by the id. `pausedDuringExport`: an export stops a running render (re-queued, restarted
// from the start; Android jobs have no checkpoints) and none starts while an export runs.
//
// [RenderPreviewJob.run] (a registry worker thread) renders on its own looper thread
// ("danaview-render"): AND-08's CompositionMapper (originals) → video-only spec →
// Media3Composition (AND-09 LayerEffectChainFactory at the output size, the export's HDR mode) →
// AND-11's TransformerExport (hardware encoder first, Transformer fallback, ORIGINAL working colour
// space, InAppMp4Muxer) into `<outputPath>.part`, with the §14.1 portrait retry; the completed file
// is renamed to `outputPath` and reported as a GeneratedAsset (path, size, range duration).
// Thermal: while PowerManager's thermal status is SEVERE or worse the render is stopped (part file
// deleted) and waits; it restarts from the beginning when the status drops below SEVERE.
// The first use of the service in a process deletes stale `.part` files in the renders directory
// (a process killed mid-render, AND-18 "process death leaves no partial file").
// Never logs paths or plan content.

package com.vecvel.danaview.editor.engine.preview.render

import android.annotation.SuppressLint
import android.content.Context
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.PowerManager
import android.util.Log
import androidx.annotation.OptIn
import androidx.annotation.RequiresApi
import androidx.annotation.VisibleForTesting
import androidx.media3.common.util.ExperimentalApi
import androidx.media3.common.util.UnstableApi
import androidx.media3.transformer.AssetLoader
import androidx.media3.transformer.Codec
import androidx.media3.transformer.ExportException
import androidx.media3.transformer.ExportResult
import com.vecvel.danaview.editor.engine.composition.AudioStreamAssetLoaderFactory
import com.vecvel.danaview.editor.engine.composition.GeneratedImageAssetLoaderFactory
import com.vecvel.danaview.editor.engine.composition.CompositionMapper
import com.vecvel.danaview.editor.engine.composition.ExtractorSourceTimeline
import com.vecvel.danaview.editor.engine.composition.Media3Composition
import com.vecvel.danaview.editor.engine.composition.PngCompositionImages
import com.vecvel.danaview.editor.engine.core.Capabilities
import com.vecvel.danaview.editor.engine.core.Completion
import com.vecvel.danaview.editor.engine.core.EngineContext
import com.vecvel.danaview.editor.engine.core.EngineErrorCode
import com.vecvel.danaview.editor.engine.core.EngineErrors
import com.vecvel.danaview.editor.engine.core.EngineException
import com.vecvel.danaview.editor.engine.core.MediaJobBody
import com.vecvel.danaview.editor.engine.core.Paths
import com.vecvel.danaview.editor.engine.core.RegistryJobControl
import com.vecvel.danaview.editor.engine.core.ThermalLevels
import com.vecvel.danaview.editor.engine.core.fail
import com.vecvel.danaview.editor.engine.core.isStopRequested
import com.vecvel.danaview.editor.engine.core.succeed
import com.vecvel.danaview.editor.engine.effects.EffectAssets
import com.vecvel.danaview.editor.engine.effects.LayerEffectChainFactory
import com.vecvel.danaview.editor.engine.export.ContextExportEnvironment
import com.vecvel.danaview.editor.engine.export.EncoderSettings
import com.vecvel.danaview.editor.engine.export.ExportErrors
import com.vecvel.danaview.editor.engine.export.HardwareEncoderSelector
import com.vecvel.danaview.editor.engine.export.TransformerExport
import com.vecvel.danaview.editor.engine.media.SourceFrameStills
import com.vecvel.danaview.editor.engine.pigeon.GeneratedAssetMsg
import com.vecvel.danaview.editor.engine.pigeon.JobKindMsg
import com.vecvel.danaview.editor.engine.pigeon.JobRequestMsg
import com.vecvel.danaview.editor.engine.pigeon.JobResultMsg
import com.vecvel.danaview.editor.engine.plan.ParamSnapshot
import com.vecvel.danaview.editor.engine.plan.PlanDecoding
import com.vecvel.danaview.editor.engine.plan.RenderPlan
import java.io.File
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference

/** Render-preview jobs (file header). */
class RenderPreviewJobService(private val ctx: EngineContext) {
    /** Transformer decoders/extractors (null = Transformer's default; tests pick software decoders). */
    @VisibleForTesting
    @Volatile
    var assetLoaderFactory: ((Context) -> AssetLoader.Factory)? = null

    /** Wraps the encoder factory (tests). */
    @VisibleForTesting
    @Volatile
    var encoderFactoryDecorator: ((Codec.EncoderFactory) -> Codec.EncoderFactory)? = null

    /** LUT and sprite files (null = PreviewSessionManager's, else the app's ContentResolver). */
    @VisibleForTesting
    @Volatile
    var effectAssets: EffectAssets? = null

    /** The output long side (null = the tier's preview long side, ARCH §12.5; tests). */
    @VisibleForTesting
    @Volatile
    var maxLongSideOverride: Int? = null

    /** PowerManager thermal status (THERMAL_STATUS_*; tests inject a source). */
    @VisibleForTesting
    @Volatile
    var thermalStatus: () -> Int = { currentThermalStatus() }

    /** Thermal poll period while rendering or paused (ms). */
    @VisibleForTesting
    @Volatile
    var thermalPollMs: Long = THERMAL_POLL_MS

    /** Observes runs (tests): started, paused by heat, completed. */
    @VisibleForTesting
    @Volatile
    var observer: Observer? = null

    /** Run notifications (tests). */
    interface Observer {
        fun onRunStarted(jobId: String, attempt: Int) {}
        fun onThermalPause(jobId: String) {}
        fun onCompleted(jobId: String, frames: Int) {}
    }

    private val selector by lazy { HardwareEncoderSelector() }

    @Volatile private var swept = false

    /** Starts a render of [plan] (UTF-8 JSON range plan) into [outputPath]; completes with the job id. */
    fun start(request: JobRequestMsg, plan: ByteArray, outputPath: String, done: Completion<String>) {
        val job = try {
            val paths = ctx.requirePaths()
            sweep(paths)
            val output = Paths.normalize(outputPath) ?: throw EngineErrors.invalidArgument("outputPath", "not an absolute path")
            val range = PlanDecoding.plan(plan)
            val exportPlan = RenderPreviewSpecs.exportPlan(range, RenderPreviewSpecs.rendersDir(paths))
            RenderPreviewJob(this, exportPlan, RenderPreviewSpecs.rangeFrames(range), range.durUs, output)
        } catch (t: Throwable) {
            return done.fail(EngineErrors.from(t))
        }
        val id = try {
            ctx.jobs.enqueue(job, request.priority)
        } catch (t: Throwable) {
            return done.fail(EngineErrors.from(t))
        }
        // Reply first: Dart knows the id before the job's first event.
        done.succeed(id)
        job.replied.countDown()
    }

    /** Deletes stale part files once per process (a render killed with its process). */
    fun sweep(paths: Paths) {
        if (swept) return
        synchronized(this) {
            if (swept) return
            swept = true
            val dir = RenderPreviewSpecs.rendersDir(paths)
            val stale = RenderPreviewSpecs.staleParts(dir)
            for (f in stale) f.delete()
            if (stale.isNotEmpty()) Log.i(EngineContext.TAG, "render preview: removed ${stale.size} stale partial file(s)")
        }
    }

    @SuppressLint("VisibleForTests")
    internal fun maxLongSide(): Int = maxLongSideOverride
        ?: ctx.previews.maxPreviewLongSideOverride
        ?: Capabilities.TierLimits.of(ctx.deviceProfile.tier()).maxPreviewLongSide.toInt()

    @SuppressLint("VisibleForTests")
    internal fun assets(): EffectAssets? = effectAssets ?: ctx.previews.effectAssets

    private fun currentThermalStatus(): Int = if (Build.VERSION.SDK_INT >= 29) thermal29() else ThermalLevels.STATUS_NONE

    @RequiresApi(29)
    private fun thermal29(): Int =
        (ctx.appContext.getSystemService(Context.POWER_SERVICE) as? PowerManager)?.currentThermalStatus ?: ThermalLevels.STATUS_NONE

    internal val context: EngineContext get() = ctx

    internal fun encoderSelector(): HardwareEncoderSelector = selector

    companion object {
        /** Thermal poll period (ms). */
        const val THERMAL_POLL_MS = 1_000L

        /** How long a job body waits for the start reply before it may emit. */
        const val REPLY_WAIT_MS = 2_000L
    }
}

/** One render-preview job (file header); its body blocks a registry worker. */
class RenderPreviewJob internal constructor(
    private val service: RenderPreviewJobService,
    /** The export plan (RenderPreviewSpecs.exportPlan). */
    private val plan: RenderPlan,
    /** Frames of the range (the file's frames 0 until [frames] are the range). */
    private val frames: Long,
    /** The range's duration. */
    private val durationUs: Long,
    private val output: File,
) : MediaJobBody {
    override val kind: JobKindMsg = JobKindMsg.RENDER_PREVIEW
    override val pausedDuringExport: Boolean = true

    /** One render per output file at a time. */
    override val exclusiveKey: String = "render-" + output.path

    internal val replied = CountDownLatch(1)

    private val part: File get() = RenderPreviewSpecs.partFile(output)

    override fun run(control: RegistryJobControl): JobResultMsg {
        replied.await(RenderPreviewJobService.REPLY_WAIT_MS, TimeUnit.MILLISECONDS)
        val ctx = service.context
        var attempt = 0
        while (true) {
            control.throwIfCancelled()
            waitWhileHot(control)
            part.delete()
            service.observer?.onRunStarted(control.jobId, attempt)
            when (val outcome = renderOnce(ctx, control)) {
                is Outcome.Done -> {
                    if (output.exists() && !output.delete()) throw EngineException(EngineErrorCode.io, "cannot replace the render file")
                    if (!part.renameTo(output)) throw EngineException(EngineErrorCode.io, "cannot finish the render file")
                    service.observer?.onCompleted(control.jobId, outcome.frames)
                    Log.i(EngineContext.TAG, "render preview ${control.jobId}: done, ${outcome.frames} frames for a $frames-frame range, encoder ${outcome.encoder}")
                    control.reportProgress(1.0)
                    return JobResultMsg(kind, asset = GeneratedAssetMsg(output.absolutePath, output.length(), durationUs))
                }
                Outcome.Hot -> {
                    part.delete()
                    service.observer?.onThermalPause(control.jobId)
                    Log.i(EngineContext.TAG, "render preview ${control.jobId}: paused (thermal)")
                    attempt++
                }
                Outcome.Stopped -> {
                    part.delete()
                    control.throwIfCancelled()
                    // A stop without a reason cannot happen; treat it as an interruption.
                    throw RegistryJobControl.paused()
                }
            }
        }
    }

    override fun cleanUp() {
        part.delete()
    }

    private sealed class Outcome {
        class Done(val frames: Int, val encoder: String?) : Outcome()
        object Hot : Outcome()
        object Stopped : Outcome()
    }

    private fun isHot(): Boolean = service.thermalStatus() >= ThermalLevels.STATUS_SEVERE

    private fun waitWhileHot(control: RegistryJobControl) {
        var announced = false
        while (isHot()) {
            if (!announced) {
                announced = true
                Log.i(EngineContext.TAG, "render preview ${control.jobId}: waiting for the device to cool down")
            }
            control.throwIfCancelled()
            Thread.sleep(service.thermalPollMs)
        }
    }

    /** One Transformer run on a private looper; blocks until it completes, fails, is stopped or heats up. */
    private fun renderOnce(ctx: EngineContext, control: RegistryJobControl): Outcome {
        val thread = HandlerThread("danaview-render").apply { start() }
        val handler = Handler(thread.looper)
        val finished = CountDownLatch(1)
        val result = AtomicReference<Result<Pair<Int, String?>>?>()
        val current = AtomicReference<TransformerExport?>()
        val settings = RenderPreviewSpecs.settings(plan, service.maxLongSide())
        fun finish(r: Result<Pair<Int, String?>>) {
            if (result.compareAndSet(null, r)) finished.countDown()
        }
        val retry = AtomicReference<(Int) -> Unit>()
        fun attempt(n: Int) {
            val built = build(ctx, settings)
            val config = TransformerExport.Config(
                settings = settings,
                selector = service.encoderSelector(),
                portraitEncoding = n == 0,
                assetLoaderFactory = loaderFor(ctx, built),
                encoderFactoryDecorator = service.encoderFactoryDecorator,
            )
            val run = TransformerExport(ctx.appContext, thread.looper, config, object : TransformerExport.Listener {
                override fun onProgress(fraction: Double) = control.reportProgress(fraction)

                override fun onCompleted(result: ExportResult) = finish(Result.success(result.videoFrameCount to result.videoEncoderName))

                override fun onError(error: ExportException) {
                    if (ExportErrors.shouldRetryLandscape(error, settings, n)) {
                        Log.i(EngineContext.TAG, "render preview ${control.jobId}: portrait refused (${error.errorCodeName}); retrying landscape + rotation")
                        part.delete()
                        handler.post { retry.get()(n + 1) }
                        return
                    }
                    finish(Result.failure(ExportErrors.map(error, ExportErrors.isEncoderRefusal(error) && n > 0)))
                }
            })
            current.set(run)
            run.start(built.composition, part)
        }
        fun guardedAttempt(n: Int) {
            if (result.get() != null) return
            try {
                attempt(n)
            } catch (t: Throwable) {
                // Mapping or build failures (unreadable media, invalid plan) end the run.
                finish(Result.failure(EngineErrors.from(t)))
            }
        }
        retry.set(::guardedAttempt)
        handler.post { guardedAttempt(0) }
        try {
            var stoppedBy: Outcome? = null
            while (!finished.await(minOf(service.thermalPollMs, POLL_MS), TimeUnit.MILLISECONDS)) {
                if (control.isStopRequested) {
                    stoppedBy = Outcome.Stopped
                    break
                }
                if (isHot()) {
                    stoppedBy = Outcome.Hot
                    break
                }
            }
            if (stoppedBy != null) {
                // Cancel on the looper and wait, so the muxer never writes after the part file goes.
                val cancelled = CountDownLatch(1)
                handler.post {
                    try {
                        current.get()?.cancel()
                    } finally {
                        result.compareAndSet(null, Result.failure(EngineException(EngineErrorCode.cancelled, "stopped")))
                        cancelled.countDown()
                    }
                }
                cancelled.await(CANCEL_WAIT_MS, TimeUnit.MILLISECONDS)
                return stoppedBy
            }
            val r = result.get()!!
            val (frames, encoder) = r.getOrThrow()
            return Outcome.Done(frames, encoder)
        } finally {
            thread.quitSafely()
        }
    }

    private fun build(ctx: EngineContext, settings: EncoderSettings): Media3Composition.Built {
        val timeline = ExtractorSourceTimeline(ctx.appContext)
        val spec = try {
            CompositionMapper(timeline).map(plan, CompositionMapper.Options(useProxies = false))
        } finally {
            timeline.close()
        }
        val paths = ctx.requirePaths()
        val env = ContextExportEnvironment(ctx)
        return Media3Composition.build(
            RenderPreviewSpecs.videoOnly(spec),
            images(paths),
            LayerEffectChainFactory(settings.width, settings.height, service.assets()),
            AtomicReference(ParamSnapshot.of(plan)),
            Media3Composition.Options(
                hdrMode = env.hdrMode(plan),
                outputWidth = settings.width,
                outputHeight = settings.height,
                // A layer past its source end holds the last frame, as live playback (ARCH §11.5).
                frameStills = SourceFrameStills(ctx.appContext, File(paths.engineAssets, SourceFrameStills.DIR)),
            ),
        )
    }

    private fun images(paths: Paths) = PngCompositionImages(paths.engineAssets)

    private fun loaderFor(ctx: EngineContext, built: Media3Composition.Built): AssetLoader.Factory {
        val base = service.assetLoaderFactory?.invoke(ctx.appContext)
        val inner = when {
            !built.selectsAudioStreams -> base
            base == null -> AudioStreamAssetLoaderFactory(ctx.appContext)
            else -> AudioStreamAssetLoaderFactory(ctx.appContext, base = base)
        }
        // QA-05 D8: generated images purged under the render are written again when opened.
        return GeneratedImageAssetLoaderFactory(ctx.appContext, images(ctx.requirePaths()), inner)
    }

    private companion object {
        const val POLL_MS = 100L
        const val CANCEL_WAIT_MS = 5_000L
    }
}
