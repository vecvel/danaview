@file:OptIn(UnstableApi::class, ExperimentalApi::class)
// OWNER: AND-11

// The process-scoped export coordinator (ARCH §12.4, §14.1, §14.3, D-38, D-39, D-45; BUILD_PLAN
// AND-11). The glue calls it on danaview-export; every job runs on that lane's looper.
//
// preflight(plan, settings): decodes and checks the plan (target export, nothing pending or offline,
//   settings fps = canvas fps), asks HardwareEncoderSelector what the device will use and answers
//   ok (an encoder takes the size in some orientation), maxHeightForPlan (largest standard short side
//   the device encodes) and warnings: softwareEncoder, hevcUnavailable, portraitRetried (predicted)
//   and layersVsResolution when the plan needs the multi-pass precompose. It NEVER refuses for
//   sequence or layer counts (owner decision 2026-10-11, D-43(e) point 7, D-45).
// start(...): validates synchronously, records the job in ActiveExportStore (running), suspends
//   preview sessions on minimal/low/mid tiers (AND-10's PreviewSessionManager), pauses background
//   jobs (AND-05's JobRegistry.setExportActive), protects the output from the work/ wipe, starts
//   AND-12's ExportService, answers the job id, then runs the job:
//   - the export composition comes from AND-08's mapper (target export: originals, export size =
//     settings size, clock band at the export fps with trackTypes {VIDEO, AUDIO} so a silent AAC
//     48 kHz stereo track always exists, D-38) and AND-09's LayerEffectChainFactory (sprite bands
//     included), built by Media3Composition at the settings size;
//   - routing (D-45): when the plan's packed media slots exceed maxVisualSequences, or its peak
//     simultaneous decoders exceed codec maxSupportedInstances − 2, the job goes to the
//     [MultiPassExport] hook (AND-19) instead of failing; otherwise (or while no hook is
//     installed) to the single pass;
//   - single pass: one TransformerExport with portrait encoding on; on a refused portrait
//     configuration one retry landscape with rotation metadata (`portraitRetried`), then
//     `encoderSizeLimit` (ARCH §14.1);
//   - audio to the video's end (owner decision 2026-10-15, ARCH §14.3): every composition with an
//     audio track mixes [AUDIO_TAIL_US] of silence past the video's end (Media3Composition
//     `audioThroughUs`) and the muxer drops AAC units presented at or after the video's end
//     (TransformerExport `audioEndUs`), so the AAC track ends at the last video frame within one AAC
//     frame on every route (single pass, the precompose final pass; video-only passes have no
//     audio track to pad);
//   - progress: Transformer.getProgress every 250 ms → EventHub.exportProgress (phase preparing →
//     rendering → finishing, frames on the export grid, warnings incl. fallbackApplied);
//   - completion: jobDone with ExportResult (path, bytes, durUs, the encoder that actually ran and
//     whether it is hardware). With no Dart listener attached (D-39) the job's [detachedHandler]
//     records a completedWhileDetached record (default: keep the file and exempt it from the
//     work/ wipe; AND-12's ExportService replaces it with its MediaStore handoff);
//   - failure: ExportErrors.map (ARCH §14.3), the partial output is deleted, jobFailed. A failure
//     because engine files below the cache root went missing (the system purged them under low
//     storage, QA-05 D8), or an output the purge removed before completion, is a storage failure
//     (StorageLoss: diskFull when the volume is low, else io), never internal or mediaOffline;
//     purged generated images are written again when opened (GeneratedImageAssetLoaderFactory).
// cancel(jobId): stops the job, deletes the partial output and work/export-<jobId>/, jobFailed
//   (cancelled). Idempotent.
// activeJobs(): ActiveExportStore records (running jobs of this process; one-shot interrupted
//   records of jobs whose process died; completedWhileDetached), until consumeJobRecord.
// Android exports are not resumable (the glue answers `resume` with notSupportedOnDevice).
//
// Hooks for later tickets (they never edit this file):
// - AND-12: `addJobListener` (started / progress / ended), `job(jobId)`, `cancel`, `interrupt`
//   (API 35 onTimeout), `detachedHandler`, `store()`, and the service start intent
//   (ACTION_EXPORT_STARTED with EXTRA_JOB_ID, sent with startService when a job starts).
// - AND-19: implement [MultiPassExport] in a class named [MULTI_PASS_CLASS] with a public
//   `(EngineContext)` constructor, annotated @androidx.annotation.Keep (R8 keeps it; it is found by
//   reflection because nothing else references it). It gets an [ExportJob] (plan, settings, output,
//   work dir, decoder budget, the same mapper / composition build / Transformer configuration) and
//   reports through [ExportPassListener] on the job's looper.
// Nothing here logs paths, titles or plan content.

package com.vecvel.danaview.editor.engine.export

import android.app.ActivityManager
import android.content.Context
import android.content.Intent
import android.os.Looper
import android.os.StatFs
import android.util.Log
import androidx.annotation.OptIn
import androidx.annotation.VisibleForTesting
import androidx.media3.common.util.ExperimentalApi
import androidx.media3.common.util.UnstableApi
import androidx.media3.transformer.AssetLoader
import androidx.media3.transformer.Codec
import androidx.media3.transformer.Composition
import androidx.media3.transformer.ExportException
import androidx.media3.transformer.ExportResult
import com.vecvel.danaview.editor.engine.composition.AudioStreamAssetLoaderFactory
import com.vecvel.danaview.editor.engine.composition.CompositionMapper
import com.vecvel.danaview.editor.engine.composition.CompositionSpec
import com.vecvel.danaview.editor.engine.composition.ExtractorSourceTimeline
import com.vecvel.danaview.editor.engine.composition.GeneratedImageAssetLoaderFactory
import com.vecvel.danaview.editor.engine.composition.Media3Composition
import com.vecvel.danaview.editor.engine.composition.PngCompositionImages
import com.vecvel.danaview.editor.engine.composition.SourceTimeline
import com.vecvel.danaview.editor.engine.core.Cancellable
import com.vecvel.danaview.editor.engine.core.Capabilities
import com.vecvel.danaview.editor.engine.core.Completion
import com.vecvel.danaview.editor.engine.core.EngineContext
import com.vecvel.danaview.editor.engine.core.EngineErrorCode
import com.vecvel.danaview.editor.engine.core.EngineErrors
import com.vecvel.danaview.editor.engine.core.EngineException
import com.vecvel.danaview.editor.engine.core.Paths
import com.vecvel.danaview.editor.engine.core.fail
import com.vecvel.danaview.editor.engine.core.succeed
import com.vecvel.danaview.editor.engine.effects.EffectAssets
import com.vecvel.danaview.editor.engine.effects.LayerEffectChainFactory
import com.vecvel.danaview.editor.engine.media.DiskCache
import com.vecvel.danaview.editor.engine.media.WorkExemptions
import com.vecvel.danaview.editor.engine.pigeon.DetachedHandoffMsg
import com.vecvel.danaview.editor.engine.pigeon.EncodeSettingsMsg
import com.vecvel.danaview.editor.engine.pigeon.ExportJobRecordMsg
import com.vecvel.danaview.editor.engine.pigeon.ExportPhaseMsg
import com.vecvel.danaview.editor.engine.pigeon.ExportPreflightMsg
import com.vecvel.danaview.editor.engine.pigeon.ExportProgressMsg
import com.vecvel.danaview.editor.engine.pigeon.ExportResultMsg
import com.vecvel.danaview.editor.engine.pigeon.ExportWarningMsg
import com.vecvel.danaview.editor.engine.pigeon.JobKindMsg
import com.vecvel.danaview.editor.engine.pigeon.JobResultMsg
import com.vecvel.danaview.editor.engine.plan.FrameGrid
import com.vecvel.danaview.editor.engine.plan.ParamSnapshot
import com.vecvel.danaview.editor.engine.plan.PlanDecoding
import com.vecvel.danaview.editor.engine.plan.PlanLayerKind
import com.vecvel.danaview.editor.engine.plan.PlanAssetKind
import com.vecvel.danaview.editor.engine.plan.PlanTarget
import com.vecvel.danaview.editor.engine.plan.PlanTransfer
import com.vecvel.danaview.editor.engine.plan.RenderPlan
import com.vecvel.danaview.editor.engine.preview.render.RenderPreviewSpecs
import java.io.Closeable
import java.io.File
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.atomic.AtomicReference

// ---- multi-pass hook (D-45; AND-19 implements it) ----------------------------------------------

/** A running pass (single or multi-pass): [Cancellable.cancel] stops it; no callback follows. */
fun interface ExportPass {
    /** Starts [job] and reports through [listener] on the job's looper. May throw (→ job failure). */
    fun start(job: ExportJob, listener: ExportPassListener): Cancellable
}

/**
 * The multi-pass precompose of D-45 (AND-19): renders the bottom slots into opaque full-size
 * intermediates under [ExportJob.workDir], then the final pass with audio to [ExportJob.output].
 * Progress is one fraction over all passes. See the file header for how it is installed.
 */
interface MultiPassExport : ExportPass

/** What a pass reports. Call on the job's looper (the coordinator re-posts other threads). */
interface ExportPassListener {
    /** Overall progress 0..1. */
    fun onProgress(fraction: Double)

    /** A progress warning (ExportWarnings codes). */
    fun onWarning(warning: ExportWarningMsg)

    /** The output file is complete; [videoEncoderName] is ExportResult.videoEncoderName of the final pass. */
    fun onCompleted(videoEncoderName: String?)

    /** The pass failed ([EngineException] or an ExportException / Throwable the coordinator maps). */
    fun onFailed(error: Throwable)
}

/** Decoder limits of the device for the routing rule (D-45, AND-01 V-N25). */
data class DecoderBudget(
    /** Capabilities.maxVisualSequences (tier table capped by (instances − 2) / 2). */
    val maxVisualSequences: Int,
    /** H.264 decoder maxSupportedInstances (0 = unknown, no cap). */
    val maxDecoderInstances: Int,
) {
    /** Simultaneous decoders an export may use: instances − 2 (two stay free), or unlimited. */
    val maxDecoders: Int get() = if (maxDecoderInstances > 0) maxOf(1, maxDecoderInstances - 2) else Int.MAX_VALUE
}

/** The multi-pass routing rule (D-45; JVM-tested). */
object MultiPassRouting {
    /** The plan's decoder load: packed media slots and peak simultaneous media layers. */
    data class Load(val slots: Int, val peakDecoders: Int)

    /** [Load] of [plan]: distinct `seq` of media layers, and the peak overlap of their [t0, t1). */
    fun load(plan: RenderPlan): Load {
        val media = plan.layers.filter { it.kind == PlanLayerKind.MEDIA }
        val slots = media.map { it.seq }.toSet().size
        val edges = ArrayList<Pair<Long, Int>>(media.size * 2)
        for (l in media) {
            edges += l.t0 to 1
            edges += l.t1 to -1
        }
        edges.sortWith(compareBy<Pair<Long, Int>> { it.first }.thenBy { it.second })
        var current = 0
        var peak = 0
        for ((_, d) in edges) {
            current += d
            peak = maxOf(peak, current)
        }
        return Load(slots, peak)
    }

    /** Whether [load] needs the precompose on a device with [budget]. */
    fun needsMultiPass(load: Load, budget: DecoderBudget): Boolean =
        load.slots > budget.maxVisualSequences || load.peakDecoders > budget.maxDecoders
}

// ---- job description handed to passes ------------------------------------------------------------

/**
 * One export as the passes see it. [map] and [build] are the export mapping and composition build
 * (AND-08 mapper with originals, AND-09 effects at the settings size, the job's HDR mode);
 * [newTransformerExport] runs a Transformer with the job's configuration ([passConfig]; a pass may
 * copy it with other settings, e.g. intra-only intermediates).
 */
class ExportJob(
    val jobId: String,
    val plan: RenderPlan,
    /** Settings with the codec that will be written. */
    val settings: EncoderSettings,
    val choice: EncoderChoice,
    val output: File,
    /** `work/export-<jobId>/` for intermediates (created by the pass; deleted when the job ends). */
    val workDir: File,
    val budget: DecoderBudget,
    val load: MultiPassRouting.Load,
    /** Composition.setHdrMode value. */
    val hdrMode: Int,
    val context: Context,
    /** The danaview-export looper (null only in JVM tests). */
    val looper: Looper?,
    val passConfig: TransformerExport.Config,
    private val timelines: () -> SourceTimeline,
    private val compositions: (CompositionSpec, RenderPlan) -> Media3Composition.Built,
    private val assetLoaders: (Media3Composition.Built) -> AssetLoader.Factory?,
) {
    /** Output frames on the export grid. */
    val framesTotal: Long get() = settings.frameCount(plan.durUs)

    /** Maps [p] for export (originals; throws EngineException). */
    fun map(p: RenderPlan = plan): CompositionSpec {
        val timeline = timelines()
        try {
            return CompositionMapper(timeline).map(p, CompositionMapper.Options(useProxies = false))
        } finally {
            (timeline as? Closeable)?.close()
        }
    }

    /** Builds the Media3 composition of [spec] (mapped from [p]). */
    fun build(spec: CompositionSpec, p: RenderPlan = plan): Media3Composition.Built = compositions(spec, p)

    /** The Transformer configuration for [built] (asset loader resolved for audio streams). */
    fun configFor(built: Media3Composition.Built, base: TransformerExport.Config = passConfig): TransformerExport.Config =
        base.copy(assetLoaderFactory = assetLoaders(built))

    /** A Transformer run on the job's looper. */
    fun newTransformerExport(config: TransformerExport.Config, listener: TransformerExport.Listener): TransformerExport =
        TransformerExport(context, checkNotNull(looper) { "no export looper" }, config, listener)
}

/** The single-pass export with the §14.1 portrait retry. */
class SinglePassExport : ExportPass {
    override fun start(job: ExportJob, listener: ExportPassListener): Cancellable {
        val spec = job.map()
        val current = AtomicReference<TransformerExport?>()
        var cancelled = false

        fun attempt(n: Int) {
            if (cancelled) return
            val built = job.build(spec)
            val config = job.configFor(built, job.passConfig.copy(portraitEncoding = n == 0))
            val run = job.newTransformerExport(config, object : TransformerExport.Listener {
                override fun onProgress(fraction: Double) = listener.onProgress(fraction)

                override fun onFallbackApplied() = listener.onWarning(ExportWarnings.fallbackApplied())

                override fun onCompleted(result: ExportResult) = listener.onCompleted(result.videoEncoderName)

                override fun onError(error: ExportException) {
                    if (cancelled) return
                    if (ExportErrors.shouldRetryLandscape(error, job.settings, n)) {
                        Log.i(EngineContext.TAG, "export ${job.jobId}: portrait refused (${error.errorCodeName}); retrying landscape + rotation")
                        job.output.delete()
                        listener.onWarning(ExportWarnings.portraitRetried())
                        attempt(n + 1)
                        return
                    }
                    val sizeLimit = ExportErrors.isEncoderRefusal(error) && (n > 0 || !job.choice.sizeSupported)
                    listener.onFailed(ExportErrors.map(error, sizeLimit))
                }
            })
            current.set(run)
            run.start(built.composition, job.output)
        }

        attempt(0)
        return Cancellable {
            cancelled = true
            current.get()?.cancel()
        }
    }
}

// ---- hooks for AND-12 ------------------------------------------------------------------------------

/** A job as AND-12's service and notification see it. */
data class ExportJobInfo(
    val jobId: String,
    /** The notification title from Dart (user content: never log it). */
    val title: String,
    val outputPath: String,
    val settings: EncodeSettingsMsg,
    val whenDetached: DetachedHandoffMsg,
)

/** How a job ended. */
enum class ExportOutcome { COMPLETED, COMPLETED_WHILE_DETACHED, FAILED, CANCELLED, INTERRUPTED }

/** Job life-cycle callbacks (AND-12). Called on danaview-export. */
interface ExportJobListener {
    fun onJobStarted(job: ExportJobInfo) {}

    fun onJobProgress(jobId: String, progress: ExportProgressMsg) {}

    fun onJobEnded(jobId: String, outcome: ExportOutcome) {}
}

/** A job that completed with no Dart listener attached (D-39). */
class DetachedCompletion(
    val job: ExportJobInfo,
    val result: ExportResultMsg,
    val output: File,
    val store: ActiveExportStore,
    val paths: Paths,
) {
    /**
     * Records the completion and keeps the file: a completedWhileDetached record with [result],
     * and the output exempt from the work/ wipe for 7 days (DiskCache.WorkExemptions).
     */
    fun keepFile() {
        store.recordCompletedWhileDetached(job.jobId, result, savedToGallery = false, savedUri = null)
        WorkExemptions.add(output, paths)
    }

    /** Records a completion whose file went to the gallery as [savedUri] (AND-12; the file may be gone). */
    fun savedToGallery(savedUri: String?, keptFile: Boolean) {
        store.recordCompletedWhileDetached(job.jobId, if (keptFile) result else null, savedToGallery = true, savedUri = savedUri)
        if (keptFile) WorkExemptions.add(output, paths)
    }
}

/** Handles a detached completion (D-39). Called on danaview-export; must record it in the store. */
fun interface DetachedCompletionHandler {
    fun onCompletedWhileDetached(completion: DetachedCompletion)
}

// ---- device and side-effect environment -------------------------------------------------------------

/** What the coordinator needs from the device and the other services (replaced in JVM tests). */
interface ExportEnvironment {
    fun decoderBudget(): DecoderBudget

    fun hdrMode(plan: RenderPlan): Int

    /** The app is not in the foreground (ExportProgress.backgrounded). */
    fun isBackgrounded(): Boolean

    /** A Dart listener is attached to the event stream. */
    fun hasDartListener(): Boolean

    /** The job started: pause background jobs, suspend previews, protect the output, start the service. */
    fun exportStarted(jobId: String, output: File)

    /** The job ended (any outcome): undo [exportStarted]. */
    fun exportEnded(jobId: String, output: File)

    /**
     * Calls [ready] once the codecs that [exportStarted] asked others to release (preview decks,
     * pre-empted jobs) are released, or after [CodecHandover.BOUND_MS] (QA-05 D9). At once by default.
     */
    fun whenCodecsReleased(jobId: String, ready: () -> Unit) = ready()

    /** Whether the volume holding [dir] is low on space right now (StorageLoss.isLow; QA-05 D8). */
    fun isStorageLow(dir: File): Boolean = false
}

/** Production [ExportEnvironment] over the engine context. */
class ContextExportEnvironment(private val ctx: EngineContext) : ExportEnvironment {
    override fun decoderBudget(): DecoderBudget {
        val profile = ctx.deviceProfile
        val instances = profile.codecs().maxDecoderInstances
        val table = Capabilities.TierLimits.of(profile.tier()).maxVisualSequences.toInt()
        val visual = if (instances > 0) minOf(table, (instances - 2) / 2) else table
        return DecoderBudget(maxOf(1, visual), instances)
    }

    override fun hdrMode(plan: RenderPlan): Int {
        val hdr = plan.assets.values.any { it.kind == PlanAssetKind.VIDEO && it.transfer != PlanTransfer.SDR }
        if (!hdr) return Composition.HDR_MODE_TONE_MAP_HDR_TO_SDR_USING_OPEN_GL
        val tm = ctx.deviceProfile.toneMapping()
        return when {
            tm.glYuvTarget -> Composition.HDR_MODE_TONE_MAP_HDR_TO_SDR_USING_OPEN_GL
            tm.mediaCodecToneMap -> Composition.HDR_MODE_TONE_MAP_HDR_TO_SDR_USING_MEDIACODEC
            else -> Composition.HDR_MODE_TONE_MAP_HDR_TO_SDR_USING_OPEN_GL
        }
    }

    override fun isBackgrounded(): Boolean = try {
        val info = ActivityManager.RunningAppProcessInfo()
        ActivityManager.getMyMemoryState(info)
        info.importance > ActivityManager.RunningAppProcessInfo.IMPORTANCE_FOREGROUND
    } catch (e: RuntimeException) {
        false
    }

    override fun hasDartListener(): Boolean = ctx.events.hasListener

    private val handovers = java.util.concurrent.ConcurrentHashMap<String, CodecHandover>()

    override fun exportStarted(jobId: String, output: File) {
        val handover = CodecHandover(2)
        handovers[jobId] = handover
        val jobsStopped = handover.part()
        val previewsReleased = handover.part()
        guarded("job registry") {
            ctx.jobs.setExportActive(jobId, true)
            ctx.jobs.whenHeldJobsStopped(jobsStopped)
        }
        guarded("preview suspension") { ctx.previews.suspendForExport(jobId, previewsReleased) }
        guarded("work pin") { DiskCache.markActive(output) }
        guarded("export service") {
            val intent = Intent(ctx.appContext, ExportService::class.java)
                .setAction(ExportCoordinator.ACTION_EXPORT_STARTED)
                .putExtra(ExportCoordinator.EXTRA_JOB_ID, jobId)
            ctx.appContext.startService(intent)
        }
    }

    override fun whenCodecsReleased(jobId: String, ready: () -> Unit) {
        if (System.getProperty("d9.temp.off") == null) return ready() //D9TEMP
        val handover = handovers[jobId] ?: return ready()
        val started = android.os.SystemClock.uptimeMillis()
        val handler = ctx.threads.export.handler ?: android.os.Handler(Looper.getMainLooper())
        val timeout = Runnable { handover.timeout() }
        handover.whenOpen {
            handler.removeCallbacks(timeout)
            val waited = android.os.SystemClock.uptimeMillis() - started
            if (handover.allReported) {
                Log.i(EngineContext.TAG, "export $jobId: previews and paused jobs released their codecs in $waited ms")
            } else {
                Log.w(EngineContext.TAG, "export $jobId: codec handover timed out after $waited ms; starting anyway")
            }
            ready()
        }
        if (!handover.isOpen) handler.postDelayed(timeout, CodecHandover.BOUND_MS)
    }

    override fun exportEnded(jobId: String, output: File) {
        handovers.remove(jobId)?.timeout()
        guarded("work pin") { DiskCache.unmarkActive(output) }
        guarded("preview resume") { ctx.previews.resumeAfterExport(jobId) }
        guarded("job registry") { ctx.jobs.setExportActive(jobId, false) }
    }

    /** StatFs of [dir]'s nearest existing ancestor (the purge may have removed [dir] itself). */
    override fun isStorageLow(dir: File): Boolean = try {
        generateSequence(dir.absoluteFile) { it.parentFile }.firstOrNull { it.exists() }
            ?.let { StatFs(it.path) }
            ?.let { StorageLoss.isLow(it.availableBytes, it.totalBytes) } ?: false
    } catch (e: IllegalArgumentException) {
        false
    }

    private inline fun guarded(what: String, block: () -> Unit) {
        try {
            block()
        } catch (e: RuntimeException) {
            Log.w(EngineContext.TAG, "export: $what failed (${e.javaClass.simpleName})")
        }
    }
}

// ---- the coordinator ---------------------------------------------------------------------------------

/** Export coordinator (file header). Glue calls arrive on danaview-export. */
class ExportCoordinator(private val ctx: EngineContext) {
    /** Device facts and side effects. */
    @VisibleForTesting
    @Volatile
    var environment: ExportEnvironment = ContextExportEnvironment(ctx)

    /** Plan bytes → plan (android.util.JsonReader; JVM tests use org.json). */
    @VisibleForTesting
    @Volatile
    var planDecoder: (ByteArray) -> RenderPlan = PlanDecoding::plan

    /** Source timing for the mapper (closed after each mapping when Closeable). */
    @VisibleForTesting
    @Volatile
    var timelineFactory: () -> SourceTimeline = { ExtractorSourceTimeline(ctx.appContext) }

    /** Encoder ranking and prediction (JVM tests inject codec lists). */
    @VisibleForTesting
    @Volatile
    var selector: HardwareEncoderSelector = HardwareEncoderSelector()

    /** Base asset loader (null: Transformer's default; emulator frame checks pass software-first decoders). */
    @VisibleForTesting
    @Volatile
    var assetLoaderFactory: ((Context) -> AssetLoader.Factory)? = null

    /** Wraps the video encoder factory (tests inject a refused portrait configuration). */
    @VisibleForTesting
    @Volatile
    var encoderFactoryDecorator: ((Codec.EncoderFactory) -> Codec.EncoderFactory)? = null

    /** LUT and sprite access of the effects (null: the app's ContentResolver). */
    @VisibleForTesting
    @Volatile
    var effectAssets: EffectAssets? = null

    /** The single pass (tests replace it with a double). */
    @VisibleForTesting
    @Volatile
    var singlePass: ExportPass = SinglePassExport()

    /** An explicit multi-pass hook (tests); otherwise [MULTI_PASS_CLASS] when present. */
    @Volatile
    var multiPass: MultiPassExport? = null

    /** False turns off the reflective [MULTI_PASS_CLASS] lookup (tests of the no-hook path). */
    @VisibleForTesting
    @Volatile
    var discoverMultiPass: Boolean = true

    /** Handles completions without a Dart listener (D-39); AND-12 installs its MediaStore handoff. */
    @Volatile
    var detachedHandler: DetachedCompletionHandler = DetachedCompletionHandler { it.keepFile() }

    private val discoveredMultiPass: MultiPassExport? by lazy {
        try {
            Class.forName(MULTI_PASS_CLASS).getConstructor(EngineContext::class.java).newInstance(ctx) as? MultiPassExport
        } catch (e: ReflectiveOperationException) {
            null
        } catch (e: LinkageError) {
            null
        } catch (e: ClassCastException) {
            null
        }
    }

    private val jobs = ConcurrentHashMap<String, Running>()
    private val listeners = CopyOnWriteArrayList<ExportJobListener>()

    // ---- glue API ----

    /** Checks [plan] (UTF-8 JSON) against [settings] (file header). Never refuses for layer counts. */
    fun preflight(plan: ByteArray, settings: EncodeSettingsMsg, done: Completion<ExportPreflightMsg>) {
        try {
            val s = try {
                EncoderSettings.from(settings)
            } catch (e: EngineException) {
                if (e.code != EngineErrorCode.notSupportedOnDevice) throw e
                return done.succeed(ExportPreflightMsg(ok = false, maxHeightForPlan = null, warnings = listOf(ExportWarningMsg(CONTAINER_UNAVAILABLE, "MOV is not written on Android"))))
            }
            val p = planDecoder(plan)
            checkPlan(p, s)
            val choice = selector.choose(s)
            var warnings = choice.warnings()
            if (MultiPassRouting.needsMultiPass(MultiPassRouting.load(p), environment.decoderBudget())) {
                warnings = ExportWarnings.plus(warnings, ExportWarnings.layersVsResolution())
            }
            val maxShort = selector.maxShortSide(s, choice.codec)
            done.succeed(
                ExportPreflightMsg(
                    ok = choice.available && choice.sizeSupported,
                    maxHeightForPlan = maxShort?.toLong(),
                    warnings = warnings,
                ),
            )
        } catch (t: Throwable) {
            done.fail(EngineErrors.from(t))
        }
    }

    /** Starts an export to [outputPath] (inside the engine roots); completes with the job id. */
    fun start(
        plan: ByteArray,
        settings: EncodeSettingsMsg,
        outputPath: String,
        title: String,
        whenDetached: DetachedHandoffMsg,
        done: Completion<String>,
    ) {
        val running = try {
            prepare(plan, settings, outputPath, title, whenDetached)
        } catch (t: Throwable) {
            return done.fail(EngineErrors.from(t))
        }
        Log.i(
            EngineContext.TAG,
            "export ${running.info.jobId}: ${running.job.settings.codec} ${running.job.settings.width}x${running.job.settings.height}@${running.job.settings.fps} " +
                "slots=${running.job.load.slots} peak=${running.job.load.peakDecoders} multiPass=${running.multiPassRoute}",
        )
        done.succeed(running.info.jobId)
        // QA-05 D9: the export's codecs start after the previews and paused jobs released theirs.
        environment.whenCodecsReleased(running.info.jobId) { onLane { launch(running) } }
    }

    /** Cancels [jobId] and deletes its partial output. Idempotent; callable from any thread. */
    fun cancel(jobId: String, done: Completion<Unit>) = onLane {
        jobs[jobId]?.let { end(it, ExportOutcome.CANCELLED, EngineException(EngineErrorCode.cancelled, "cancelled")) }
        done.succeed(Unit)
    }

    /** Stops [jobId] as interrupted (AND-12: API 35 onTimeout); one-shot interrupted record. Any thread. */
    fun interrupt(jobId: String) = onLane {
        jobs[jobId]?.let { end(it, ExportOutcome.INTERRUPTED, EngineException(EngineErrorCode.interrupted, "export interrupted", retryable = true)) }
    }

    /** Running jobs plus one-shot records until consumed (D-22, D-39). */
    fun activeJobs(done: Completion<List<ExportJobRecordMsg>>) {
        try {
            val paths = ctx.pathsOrNull ?: return done.succeed(emptyList())
            done.succeed(ActiveExportStore.of(paths).recordMsgs())
        } catch (t: Throwable) {
            done.fail(EngineErrors.from(t))
        }
    }

    /** Marks the one-shot record of [jobId] as seen (its kept output loses the wipe exemption). */
    fun consumeJobRecord(jobId: String) {
        val paths = ctx.pathsOrNull ?: return
        val record = ActiveExportStore.of(paths).consume(jobId) ?: return
        record.result?.let { WorkExemptions.remove(File(it.path), paths) }
    }

    // ---- AND-12 API ----

    /** Adds a job listener (AND-12). */
    fun addJobListener(listener: ExportJobListener) {
        listeners.addIfAbsent(listener)
    }

    fun removeJobListener(listener: ExportJobListener) {
        listeners.remove(listener)
    }

    /** The running job [jobId], or null. */
    fun job(jobId: String): ExportJobInfo? = jobs[jobId]?.info

    /** Running jobs of this process. */
    fun runningJobs(): List<ExportJobInfo> = jobs.values.map { it.info }

    /** The record store of the installed roots (AND-12 writes detached completions through DetachedCompletion). */
    fun store(): ActiveExportStore = ActiveExportStore.of(ctx.requirePaths())

    /** The multi-pass hook in use (explicit, discovered, or null). */
    fun multiPassExport(): MultiPassExport? = multiPass ?: if (discoverMultiPass) discoveredMultiPass else null

    // ---- internals ----

    private class Running(val info: ExportJobInfo, val job: ExportJob, val store: ActiveExportStore, val paths: Paths, val multiPassRoute: Boolean) {
        var handle: Cancellable? = null
        var warnings: List<ExportWarningMsg> = emptyList()
        var phase: ExportPhaseMsg = ExportPhaseMsg.PREPARING
        var fraction: Double = 0.0
        var ended = false
    }

    private fun checkPlan(plan: RenderPlan, s: EncoderSettings) {
        if (plan.target != PlanTarget.EXPORT) throw EngineErrors.invalidPlan("export needs a plan compiled for export")
        if (plan.durUs <= 0) throw EngineErrors.invalidPlan("an empty plan has nothing to export")
        plan.req?.let { req ->
            req.offline.firstOrNull()?.let { throw EngineException(EngineErrorCode.mediaOffline, "media offline", itemId = it) }
            (req.pendingReverse + req.pendingStill).firstOrNull()?.let { throw EngineException(EngineErrorCode.planInvalid, "a reverse or freeze job is pending", itemId = it) }
        }
        if (s.fps != plan.canvas.fps) throw EngineErrors.invalidArgument("settings.fps", "differs from the plan's output fps")
        // D-45: render-preview files are preview-quality and never exported (like proxies, §9.5).
        ctx.pathsOrNull?.let { paths ->
            RenderPreviewSpecs.renderFileAsset(plan, RenderPreviewSpecs.rendersDir(paths))?.let {
                throw EngineException(EngineErrorCode.planInvalid, "a render-preview file cannot be exported", itemId = it)
            }
        }
    }

    private fun prepare(planBytes: ByteArray, msg: EncodeSettingsMsg, outputPath: String, title: String, whenDetached: DetachedHandoffMsg): Running {
        val paths = ctx.requirePaths()
        val output = paths.requireWritable(outputPath, "outputPath")
        val requested = EncoderSettings.from(msg)
        val plan = planDecoder(planBytes)
        checkPlan(plan, requested)
        val choice = selector.choose(requested)
        if (!choice.available) throw EngineException(EngineErrorCode.encoderUnavailable, "no ${requested.codec} encoder")
        val settings = requested.withCodec(choice.codec)
        val jobId = "ex_" + UUID.randomUUID().toString().replace("-", "").take(16)
        val budget = environment.decoderBudget()
        val load = MultiPassRouting.load(plan)
        val hdrMode = environment.hdrMode(plan)
        val videoEnd = videoEndUs(plan.durUs, settings)
        val passConfig = TransformerExport.Config(settings = settings, selector = selector, encoderFactoryDecorator = encoderFactoryDecorator, audioEndUs = videoEnd)
        val images = PngCompositionImages(paths.engineAssets)
        val assets = effectAssets
        val baseLoader = assetLoaderFactory
        val job = ExportJob(
            jobId = jobId,
            plan = plan,
            settings = settings,
            choice = choice,
            output = output,
            workDir = File(paths.work, "export-$jobId"),
            budget = budget,
            load = load,
            hdrMode = hdrMode,
            context = ctx.appContext,
            looper = ctx.threads.export.looper,
            passConfig = passConfig,
            timelines = timelineFactory,
            compositions = { spec, p ->
                Media3Composition.build(
                    spec,
                    images,
                    LayerEffectChainFactory(settings.width, settings.height, assets),
                    AtomicReference(ParamSnapshot.of(p)),
                    Media3Composition.Options(
                        hdrMode = hdrMode,
                        outputWidth = settings.width,
                        outputHeight = settings.height,
                        audioThroughUs = videoEnd + AUDIO_TAIL_US,
                    ),
                )
            },
            assetLoaders = { built ->
                val base = baseLoader?.invoke(ctx.appContext)
                val inner = when {
                    !built.selectsAudioStreams -> base
                    base == null -> AudioStreamAssetLoaderFactory(ctx.appContext)
                    else -> AudioStreamAssetLoaderFactory(ctx.appContext, base = base)
                }
                // QA-05 D8: generated images purged under the job are written again when opened.
                GeneratedImageAssetLoaderFactory(ctx.appContext, images, inner)
            },
        )
        val info = ExportJobInfo(jobId, title, output.absolutePath, msg, whenDetached)
        val store = ActiveExportStore.of(paths)
        output.delete()
        store.begin(jobId, output, msg, whenDetached)
        val running = Running(info, job, store, paths, MultiPassRouting.needsMultiPass(load, budget))
        running.warnings = choice.warnings().let { if (running.multiPassRoute) ExportWarnings.plus(it, ExportWarnings.layersVsResolution()) else it }
        jobs[jobId] = running
        environment.exportStarted(jobId, output)
        for (l in listeners) guardedListener { l.onJobStarted(info) }
        return running
    }

    private fun launch(r: Running) {
        if (r.ended) return
        emitProgress(r)
        val pass: ExportPass = if (r.multiPassRoute) {
            multiPassExport() ?: singlePass.also {
                Log.w(EngineContext.TAG, "export ${r.info.jobId}: needs multi-pass but no MultiPassExport is installed; trying one pass")
            }
        } else {
            singlePass
        }
        try {
            r.handle = pass.start(r.job, laneListener(r))
        } catch (t: Throwable) {
            end(r, ExportOutcome.FAILED, t)
        }
    }

    private fun laneListener(r: Running): ExportPassListener = object : ExportPassListener {
        override fun onProgress(fraction: Double) = onLane {
            if (r.ended) return@onLane
            r.phase = ExportPhaseMsg.RENDERING
            r.fraction = fraction.coerceIn(0.0, 1.0)
            emitProgress(r)
        }

        override fun onWarning(warning: ExportWarningMsg) = onLane {
            if (r.ended) return@onLane
            r.warnings = ExportWarnings.plus(r.warnings, warning)
            emitProgress(r)
        }

        override fun onCompleted(videoEncoderName: String?) = onLane { complete(r, videoEncoderName) }

        override fun onFailed(error: Throwable) = onLane {
            if (!r.ended) end(r, ExportOutcome.FAILED, error)
        }
    }

    private fun progressMsg(r: Running): ExportProgressMsg {
        val total = r.job.framesTotal
        return ExportProgressMsg(
            phase = r.phase,
            fraction = r.fraction,
            framesDone = Math.round(r.fraction * total),
            framesTotal = total,
            backgrounded = environment.isBackgrounded(),
            pausedInBackground = false,
            warnings = r.warnings,
        )
    }

    private fun emitProgress(r: Running) {
        val msg = progressMsg(r)
        ctx.events.exportProgress(r.info.jobId, msg)
        for (l in listeners) guardedListener { l.onJobProgress(r.info.jobId, msg) }
    }

    private fun complete(r: Running, encoderName: String?) {
        if (r.ended) return
        val output = r.job.output
        if (!output.isFile && Paths.isInside(output, r.paths.cacheRoot)) {
            // QA-05 D8: the muxer wrote to a file the system purged from the cache root under it.
            end(r, ExportOutcome.FAILED, StorageLoss.failure(environment.isStorageLow(r.paths.cacheRoot)))
            return
        }
        if (!output.isFile || output.length() <= 0L) {
            end(r, ExportOutcome.FAILED, EngineException(EngineErrorCode.encodingFailed, "export finished without an output file"))
            return
        }
        val name = encoderName ?: r.job.choice.encoder?.name.orEmpty()
        val hardware = selector.isHardware(name)
        if (!hardware && name.isNotEmpty()) r.warnings = ExportWarnings.plus(r.warnings, ExportWarnings.softwareEncoder(name))
        val result = ExportResultMsg(
            path = output.absolutePath,
            bytes = output.length(),
            durationUs = r.job.plan.durUs,
            videoEncoderName = name,
            hardwareEncoder = hardware,
        )
        r.phase = ExportPhaseMsg.FINISHING
        r.fraction = 1.0
        emitProgress(r)
        r.ended = true
        jobs.remove(r.info.jobId)
        r.job.workDir.deleteRecursively()
        val detached = !environment.hasDartListener()
        Log.i(EngineContext.TAG, "export ${r.info.jobId}: done, encoder $name (hardware=$hardware), ${result.bytes} bytes, detached=$detached")
        if (detached) {
            try {
                detachedHandler.onCompletedWhileDetached(DetachedCompletion(r.info, result, output, r.store, r.paths))
            } catch (t: Throwable) {
                Log.w(EngineContext.TAG, "export ${r.info.jobId}: detached handoff failed (${t.javaClass.simpleName}); keeping the file")
                DetachedCompletion(r.info, result, output, r.store, r.paths).keepFile()
            }
        } else {
            r.store.finish(r.info.jobId)
        }
        ctx.events.jobDone(r.info.jobId, JobResultMsg(kind = JobKindMsg.EXPORT, exportResult = result))
        environment.exportEnded(r.info.jobId, output)
        val outcome = if (detached) ExportOutcome.COMPLETED_WHILE_DETACHED else ExportOutcome.COMPLETED
        for (l in listeners) guardedListener { l.onJobEnded(r.info.jobId, outcome) }
    }

    /** Ends [r] without a result: stops the pass, deletes partial output and intermediates. */
    private fun end(r: Running, outcome: ExportOutcome, error: Throwable) {
        if (r.ended) return
        r.ended = true
        jobs.remove(r.info.jobId)
        try {
            r.handle?.cancel()
        } catch (t: RuntimeException) {
            Log.w(EngineContext.TAG, "export ${r.info.jobId}: cancel threw ${t.javaClass.simpleName}")
        }
        r.job.output.delete()
        r.job.workDir.deleteRecursively()
        if (outcome == ExportOutcome.INTERRUPTED) r.store.markInterrupted(r.info.jobId) else r.store.finish(r.info.jobId)
        val lost = if (outcome == ExportOutcome.FAILED) StorageLoss.classify(error, r.paths.cacheRoot) { environment.isStorageLow(r.paths.cacheRoot) } else null
        val mapped = lost ?: ExportErrors.map(error)
        Log.i(EngineContext.TAG, "export ${r.info.jobId}: ended $outcome (${mapped.code})")
        if (outcome == ExportOutcome.FAILED) Log.w(EngineContext.TAG, "export ${r.info.jobId}: failure ${describeFailure(error)}")
        ctx.events.jobFailed(r.info.jobId, mapped)
        environment.exportEnded(r.info.jobId, r.job.output)
        for (l in listeners) guardedListener { l.onJobEnded(r.info.jobId, outcome) }
    }

    private fun onLane(block: () -> Unit) {
        val lane = ctx.threads.export
        if (lane.isCurrentThread()) block() else lane.execute(block)
    }

    private inline fun guardedListener(block: () -> Unit) {
        try {
            block()
        } catch (t: RuntimeException) {
            Log.w(EngineContext.TAG, "export listener threw ${t.javaClass.simpleName}")
        }
    }

    companion object {
        /** AND-19's multi-pass class (file header). */
        const val MULTI_PASS_CLASS = "com.vecvel.danaview.editor.engine.export.precompose.PrecomposeExport"

        /** Intent action sent to ExportService when a job starts (AND-12). */
        const val ACTION_EXPORT_STARTED = "com.vecvel.danaview.editor.engine.export.EXPORT_STARTED"

        /** The job id extra of [ACTION_EXPORT_STARTED]. */
        const val EXTRA_JOB_ID = "jobId"

        /** Preflight warning: the container cannot be written on Android. */
        const val CONTAINER_UNAVAILABLE = "containerUnavailable"

        /**
         * Silence mixed past the video's end so the AAC encoder emits every sample up to it (the
         * API 35 emulator's encoder held back up to 49 ms at end of stream; 250 ms leaves room for
         * encoders that hold back more); the excess is trimmed by the muxer.
         */
        const val AUDIO_TAIL_US = 250_000L

        /** End of the last exported video frame: the export-grid time of frame `frameCount(durUs)`. */
        fun videoEndUs(durUs: Long, settings: EncoderSettings): Long =
            FrameGrid.of(settings.fps).platformTimeOfFrame(settings.frameCount(durUs))
    }
}

/**
 * A failed export's cause chain for the log (QA-02): Media3 releases the Transformer before it
 * reports the error, so nothing else names the first failure. Class names, Media3 error code names,
 * the top frame of each cause, and the messages of causes that are not I/O errors (an I/O message
 * may carry a path), cut at 160 characters.
 */
internal fun describeFailure(error: Throwable): String =
    generateSequence(error) { it.cause }.take(8).joinToString(" <- ") { t ->
        val code = (t as? ExportException)?.errorCodeName?.let { "[$it]" } ?: ""
        val top = t.stackTrace.firstOrNull()?.let { " at ${it.className.substringAfterLast('.')}.${it.methodName}:${it.lineNumber}" } ?: ""
        val msg = if (t is java.io.IOException) "" else t.message?.take(160)?.let { " \"$it\"" } ?: ""
        "${t.javaClass.simpleName}$code$msg$top"
    }
