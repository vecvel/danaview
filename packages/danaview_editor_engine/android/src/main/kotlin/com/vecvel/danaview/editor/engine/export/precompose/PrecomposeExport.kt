// OWNER: AND-19
//
// The multi-pass export precompose (owner decision 2026-10-11, D-43(e) point 7; ARCH D-45(B),
// §14.3 "Multi-pass precompose"; BUILD_PLAN AND-19). AND-11's ExportCoordinator finds this class
// by reflection (ExportCoordinator.MULTI_PASS_CLASS, public (EngineContext) constructor, @Keep) and
// hands it every job whose packed plan needs more simultaneous decoders than the device allows
// (MultiPassRouting.needsMultiPass); export never refuses for sequence or layer counts.
//
// One job, on the danaview-export looper:
//   1. map the PADDED plan for the intermediate passes and the plan itself for the final pass
//      (AND-08 mapper with originals, ExportJob.map) and split the lanes (PrecomposePlanner) under
//      the job's DecoderBudget;
//   2. disk preflight: the work volume must hold the intermediates alive at once plus the output
//      (PrecomposePlanner.diskEstimate), else `diskFull` before anything is written;
//   3. pass n = 1 … N−1: a video-only Transformer export of the background (or `pre-<n−1>.mp4`)
//      plus the next lanes into `work/export-<jobId>/pre-<n>.mp4` at the export size, all-intra
//      at 4× the export bitrate (PrecomposePass); `pre-<n−1>.mp4` is deleted as soon as pass n
//      completes;
//   4. the final pass maps the last intermediate as an ordinary bottom video layer on the export
//      frame grid (rule-frame clip at 0, rate 1, PrecomposeSpecs) under the remaining lanes, with
//      the plan's audio mixed once, into the job's output.
// Progress: one fraction over all passes (PrecomposePlanner.passWeights), never decreasing.
// Warnings: an encoder fallback or a portrait retry of the FINAL pass is reported like a single
// pass (`fallbackApplied`, `portraitRetried`); the same events on an intermediate only affect a
// private file and are logged. The coordinator already reports `layersVsResolution`.
// Cleanup: cancel, failure and completion delete every intermediate (the job's work dir); while
// the job runs the work dir is marked active so a re-initialize's work/ wipe cannot remove it; after
// a process death nothing marks it and the next launch's work/ wipe (AND-03) deletes it.
// AND-12's foreground service covers every pass: the coordinator starts it per job, not per pass.
// Nothing here logs paths, titles or plan content.

package com.vecvel.danaview.editor.engine.export.precompose

import android.os.StatFs
import android.util.Log
import androidx.annotation.Keep
import androidx.annotation.VisibleForTesting
import com.vecvel.danaview.editor.engine.composition.CompositionSpec
import com.vecvel.danaview.editor.engine.core.Cancellable
import com.vecvel.danaview.editor.engine.core.EngineContext
import com.vecvel.danaview.editor.engine.core.EngineErrorCode
import com.vecvel.danaview.editor.engine.core.EngineException
import com.vecvel.danaview.editor.engine.export.ExportJob
import com.vecvel.danaview.editor.engine.export.ExportPassListener
import com.vecvel.danaview.editor.engine.export.ExportWarnings
import com.vecvel.danaview.editor.engine.export.MultiPassExport
import com.vecvel.danaview.editor.engine.media.DiskCache
import com.vecvel.danaview.editor.engine.plan.RenderPlan
import java.io.File

/** Pass life-cycle callbacks for tests and diagnostics (on the export looper). */
interface PrecomposeObserver {
    /** The split of [jobId] was decided. */
    fun onPlanned(jobId: String, plan: PrecomposePlan, disk: DiskEstimate) {}

    /** Pass [number] of [total] started (number == total: the final pass). */
    fun onPassStarted(jobId: String, number: Int, total: Int) {}

    /** Pass [number] of [total] completed. */
    fun onPassCompleted(jobId: String, number: Int, total: Int) {}
}

/** AND-19's [MultiPassExport] (file header). */
@Keep
class PrecomposeExport(@Suppress("unused") private val ctx: EngineContext) : MultiPassExport {
    /** Runs each pass (JVM tests inject a double). */
    @VisibleForTesting
    @Volatile
    var runner: PassRunner = PrecomposePass()

    /** Intermediate encoding (D-45: all-intra and ≥ 4× the export bitrate). */
    @Volatile
    var options: PrecomposePlanner.Options = PrecomposePlanner.Options()

    /**
     * Free bytes on the volume holding [dir]: StatFs.availableBytes of its nearest existing
     * ancestor, as the glue's `freeBytes` answers Dart's own preflight (tests inject a full disk).
     */
    @VisibleForTesting
    @Volatile
    var freeBytes: (File) -> Long = { dir ->
        generateSequence(dir.absoluteFile) { it.parentFile }.firstOrNull { it.exists() }?.let { StatFs(it.path).availableBytes } ?: Long.MAX_VALUE
    }

    /** Diagnostics and test hook. */
    @VisibleForTesting
    @Volatile
    var observer: PrecomposeObserver? = null

    override fun start(job: ExportJob, listener: ExportPassListener): Cancellable {
        val run = Run(job, listener, runner, options, observer)
        run.begin()
        return run
    }

    /** One job (file header). Every method runs on the job's looper. */
    private inner class Run(
        private val job: ExportJob,
        private val out: ExportPassListener,
        private val runner: PassRunner,
        private val options: PrecomposePlanner.Options,
        private val observer: PrecomposeObserver?,
    ) : Cancellable {
        private var ended = false
        private var marked = false
        private var current: Cancellable? = null
        private lateinit var split: PrecomposePlan
        private lateinit var padded: RenderPlan
        private lateinit var passFull: CompositionSpec
        private lateinit var finalFull: CompositionSpec
        private lateinit var weights: DoubleArray
        private var doneWeight = 0.0
        private var reported = 0.0

        fun begin() {
            padded = PrecomposeSpecs.paddedPlan(job.plan)
            passFull = job.map(padded)
            split = PrecomposePlanner.plan(PrecomposePlanner.lanes(passFull), job.budget)
            finalFull = job.map(job.plan)
            weights = PrecomposePlanner.passWeights(split)
            val disk = PrecomposePlanner.diskEstimate(split, job.settings, job.plan, options)
            Log.i(
                EngineContext.TAG,
                "export ${job.jobId}: precompose ${split.totalPasses} pass(es) over ${split.laneCount} lane(s) " +
                    "(slots ${job.load.slots}, peak ${job.load.peakDecoders}; budget ${job.budget.maxVisualSequences} slots, ${job.budget.maxDecoders} decoders; " +
                    "${split.overBudgetPasses} over budget), intermediates ~${disk.intermediateBytes / 1_000_000} MB each, peak ~${disk.peakBytes / 1_000_000} MB",
            )
            observer?.onPlanned(job.jobId, split, disk)
            if (split.intermediateCount > 0) {
                val free = freeBytes(job.workDir)
                if (free < disk.peakBytes) {
                    throw EngineException(EngineErrorCode.diskFull, "not enough free space for the export intermediates")
                }
                job.workDir.mkdirs()
                DiskCache.markActive(job.workDir)
                marked = true
            }
            try {
                if (split.intermediateCount > 0) startIntermediate(0, null) else startFinal(null)
            } catch (t: Throwable) {
                ended = true
                cleanup()
                throw t
            }
        }

        /** Maps [file] (intermediate [number]) as a lane shown over the whole [durUs] composition. */
        private fun intermediateLane(number: Int, file: File, durUs: Long, fileDurationUs: Long) =
            PrecomposeSpecs.intermediate(job.plan, number, file, job.settings.width, job.settings.height, durUs, fileDurationUs).let { layer ->
                layer to PrecomposeSpecs.intermediateLane(job.map(PrecomposeSpecs.intermediatePlan(job.plan, durUs, layer)))
            }

        private fun startIntermediate(index: Int, input: File?) {
            if (ended) return
            val pass = split.passes[index]
            val output = PrecomposeSpecs.intermediateFile(job.workDir, pass.number)
            val lane = input?.let { intermediateLane(pass.number - 1, it, padded.durUs, padded.durUs) }
            val request = PassRequest(
                number = pass.number,
                totalPasses = split.totalPasses,
                spec = PrecomposeSpecs.passSpec(passFull, pass.from, pass.to, lane?.second, lane?.first),
                snapshotPlan = PrecomposeSpecs.snapshotPlan(padded, lane?.first),
                output = output,
                settings = PrecomposePlanner.intermediateSettings(job.settings, options),
                color = options.color,
            )
            Log.i(EngineContext.TAG, "export ${job.jobId}: precompose pass ${pass.number}/${split.totalPasses}: lanes ${pass.from}..${pass.to - 1}, slots ${pass.load.slots}, peak ${pass.load.peakDecoders}${if (pass.overBudget) " (over budget)" else ""}")
            launch(request, index) {
                input?.delete()
                if (index + 1 < split.passes.size) startIntermediate(index + 1, output) else startFinal(output)
            }
        }

        private fun startFinal(input: File?) {
            if (ended) return
            val total = split.totalPasses
            val lane = input?.let { intermediateLane(total - 1, it, job.plan.durUs, padded.durUs) }
            val request = PassRequest(
                number = total,
                totalPasses = total,
                spec = if (lane == null) finalFull else PrecomposeSpecs.finalSpec(finalFull, split.finalFrom, lane.second, lane.first),
                snapshotPlan = PrecomposeSpecs.snapshotPlan(job.plan, lane?.first),
                output = job.output,
                settings = job.settings,
            )
            Log.i(EngineContext.TAG, "export ${job.jobId}: precompose final pass $total/$total: lanes ${split.finalFrom}..${split.laneCount - 1}, slots ${split.finalLoad.slots}, peak ${split.finalLoad.peakDecoders}")
            launch(request, total - 1) { encoder ->
                cleanup()
                ended = true
                out.onCompleted(encoder)
            }
        }

        private fun launch(request: PassRequest, weightIndex: Int, completed: (String?) -> Unit) {
            observer?.onPassStarted(job.jobId, request.number, request.totalPasses)
            val total = weights.sum()
            val w = weights[weightIndex]
            current = runner.run(job, request, object : PassRunListener {
                override fun onProgress(fraction: Double) {
                    if (ended) return
                    report((doneWeight + w * fraction.coerceIn(0.0, 1.0)) / total)
                }

                override fun onFallbackApplied() {
                    if (ended) return
                    if (request.isFinal) out.onWarning(ExportWarnings.fallbackApplied())
                    else Log.i(EngineContext.TAG, "export ${job.jobId}: precompose pass ${request.number}: encoder fallback applied to the intermediate")
                }

                override fun onPortraitRetried() {
                    if (ended) return
                    if (request.isFinal) out.onWarning(ExportWarnings.portraitRetried())
                }

                override fun onCompleted(videoEncoderName: String?) {
                    if (ended) return
                    current = null
                    doneWeight += w
                    if (!request.isFinal) report(doneWeight / total)
                    observer?.onPassCompleted(job.jobId, request.number, request.totalPasses)
                    try {
                        completed(videoEncoderName)
                    } catch (t: Throwable) {
                        fail(t)
                    }
                }

                override fun onFailed(error: Throwable) {
                    if (ended) return
                    Log.i(EngineContext.TAG, "export ${job.jobId}: precompose pass ${request.number}/${request.totalPasses} failed (${error.javaClass.simpleName})")
                    fail(error)
                }
            })
        }

        /** Reports [overall] progress when it moved forward (one fraction over all passes). */
        private fun report(overall: Double) {
            val f = overall.coerceIn(0.0, 1.0)
            if (f > reported) {
                reported = f
                out.onProgress(f)
            }
        }

        private fun fail(error: Throwable) {
            if (ended) return
            ended = true
            current?.let { c -> runCatching { c.cancel() } }
            current = null
            cleanup()
            out.onFailed(error)
        }

        /** Deletes every intermediate and releases the work-dir pin. Idempotent. */
        private fun cleanup() {
            if (job.workDir.exists()) job.workDir.deleteRecursively()
            if (marked) {
                marked = false
                DiskCache.unmarkActive(job.workDir)
            }
        }

        override fun cancel() {
            if (ended) return
            ended = true
            current?.let { c -> runCatching { c.cancel() } }
            current = null
            cleanup()
        }
    }
}
