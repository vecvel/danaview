@file:OptIn(UnstableApi::class, ExperimentalApi::class)
// OWNER: AND-19

// One Transformer run of the precompose (ARCH D-45(B), §14.3; BUILD_PLAN AND-19 `PrecomposePass`).
// It builds the pass's Media3 composition through the export job (AND-08 Media3Composition with
// AND-09's LayerEffectChainFactory at the export size and the job's HDR mode, so every pass uses
// the same effects, tone mapping and compositor as a single pass) and runs it with the job's
// Transformer configuration (AND-11 TransformerExport: same encoder factory and selector, same
// DefaultVideoFrameProcessor with the ORIGINAL working colour space, same muxer), with only the
// encoder settings replaced for intermediates (PrecomposePlanner.intermediateSettings: all-intra,
// 4× bitrate). Portrait sizes follow ARCH §14.1 as the single pass does: portrait encoding first,
// one landscape-plus-rotation retry when the encoder refuses the portrait configuration, then
// `encoderSizeLimit`. Runs on the job's looper (danaview-export); nothing is called after cancel.

package com.vecvel.danaview.editor.engine.export.precompose

import android.util.Log
import androidx.annotation.OptIn
import androidx.media3.common.util.ExperimentalApi
import androidx.media3.common.util.UnstableApi
import androidx.media3.transformer.ExportException
import androidx.media3.transformer.ExportResult
import com.vecvel.danaview.editor.engine.composition.CompositionSpec
import com.vecvel.danaview.editor.engine.core.Cancellable
import com.vecvel.danaview.editor.engine.core.EngineContext
import com.vecvel.danaview.editor.engine.export.EncoderSettings
import com.vecvel.danaview.editor.engine.export.ExportErrors
import com.vecvel.danaview.editor.engine.export.ExportJob
import com.vecvel.danaview.editor.engine.export.TransformerExport
import com.vecvel.danaview.editor.engine.plan.RenderPlan
import java.io.File

/** What one pass renders. */
class PassRequest(
    /** 1-based pass number; the final pass is number `totalPasses`. */
    val number: Int,
    val totalPasses: Int,
    /** The pass composition (PrecomposeSpecs). */
    val spec: CompositionSpec,
    /** The plan its effects read parameters from (PrecomposeSpecs.snapshotPlan). */
    val snapshotPlan: RenderPlan,
    /** `pre-<n>.mp4`, or the export output for the final pass. */
    val output: File,
    /** Intermediate settings, or the export settings for the final pass. */
    val settings: EncoderSettings,
) {
    val isFinal: Boolean get() = number == totalPasses
}

/** Callbacks of one pass, on the job's looper. */
interface PassRunListener {
    /** Transformer progress of this pass, 0..1. */
    fun onProgress(fraction: Double)

    /** Transformer applied an encoder fallback. */
    fun onFallbackApplied()

    /** The portrait configuration was refused; the pass retries landscape with rotation metadata. */
    fun onPortraitRetried()

    /** The output is complete; [videoEncoderName] is the encoder that ran. */
    fun onCompleted(videoEncoderName: String?)

    /** The pass failed (already mapped to an EngineException where possible). */
    fun onFailed(error: Throwable)
}

/** Runs one pass (production: [PrecomposePass]; JVM tests inject doubles). */
fun interface PassRunner {
    /** Starts [request] of [job]; call on the job's looper. May throw (→ the export fails). */
    fun run(job: ExportJob, request: PassRequest, listener: PassRunListener): Cancellable
}

/** The production pass: Transformer through the job's composition build and configuration (file header). */
class PrecomposePass : PassRunner {
    override fun run(job: ExportJob, request: PassRequest, listener: PassRunListener): Cancellable {
        var cancelled = false
        var current: TransformerExport? = null

        fun attempt(n: Int) {
            if (cancelled) return
            val built = job.build(request.spec, request.snapshotPlan)
            val config = job.configFor(built, job.passConfig.copy(settings = request.settings, portraitEncoding = n == 0))
            val run = job.newTransformerExport(config, object : TransformerExport.Listener {
                override fun onProgress(fraction: Double) {
                    if (!cancelled) listener.onProgress(fraction)
                }

                override fun onFallbackApplied() {
                    if (!cancelled) listener.onFallbackApplied()
                }

                override fun onCompleted(result: ExportResult) {
                    if (cancelled) return
                    Log.i(
                        EngineContext.TAG,
                        "export ${job.jobId}: precompose pass ${request.number}/${request.totalPasses} done, ${result.videoFrameCount} frames, " +
                            "${result.averageVideoBitrate / 1000} kb/s video, encoder ${result.videoEncoderName}",
                    )
                    listener.onCompleted(result.videoEncoderName)
                }

                override fun onError(error: ExportException) {
                    if (cancelled) return
                    if (ExportErrors.shouldRetryLandscape(error, request.settings, n)) {
                        Log.i(EngineContext.TAG, "export ${job.jobId}: precompose pass ${request.number}: portrait refused (${error.errorCodeName}); retrying landscape + rotation")
                        request.output.delete()
                        listener.onPortraitRetried()
                        attempt(n + 1)
                        return
                    }
                    val sizeLimit = ExportErrors.isEncoderRefusal(error) && (n > 0 || !job.choice.sizeSupported)
                    listener.onFailed(ExportErrors.map(error, sizeLimit))
                }
            })
            current = run
            run.start(built.composition, request.output)
        }

        attempt(0)
        return Cancellable {
            cancelled = true
            current?.cancel()
        }
    }
}
