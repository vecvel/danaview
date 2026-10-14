// OWNER: AND-11
//
// JVM test support for AND-11: injected encoder catalogs (codec lists as a device would report
// them), plan builders, a recording ExportEnvironment and pass doubles.

package com.vecvel.danaview.editor.engine.export

import com.vecvel.danaview.editor.engine.core.Cancellable
import com.vecvel.danaview.editor.engine.pigeon.EncodeSettingsMsg
import com.vecvel.danaview.editor.engine.pigeon.ExportContainerMsg
import com.vecvel.danaview.editor.engine.pigeon.ExportWarningMsg
import com.vecvel.danaview.editor.engine.pigeon.VideoCodecMsg
import com.vecvel.danaview.editor.engine.plan.FrameGrid
import com.vecvel.danaview.editor.engine.plan.MapSegment
import com.vecvel.danaview.editor.engine.plan.PlanAsset
import com.vecvel.danaview.editor.engine.plan.PlanAssetKind
import com.vecvel.danaview.editor.engine.plan.PlanCanvas
import com.vecvel.danaview.editor.engine.plan.PlanLayer
import com.vecvel.danaview.editor.engine.plan.PlanLayerKind
import com.vecvel.danaview.editor.engine.plan.PlanRequirements
import com.vecvel.danaview.editor.engine.plan.PlanSize
import com.vecvel.danaview.editor.engine.plan.PlanTarget
import com.vecvel.danaview.editor.engine.plan.PlanValidator
import com.vecvel.danaview.editor.engine.plan.RenderPlan
import java.io.File

/** Codec lists as devices report them. */
object Codecs {
    /** An encoder taking sizes up to [maxW] x [maxH] (landscape only when [landscapeOnly]). */
    fun encoder(name: String, mime: String, hardware: Boolean, maxW: Int = 4096, maxH: Int = 2304, landscapeOnly: Boolean = false) =
        EncoderCandidate(
            name = name,
            mimeType = mime,
            hardware = hardware,
            softwareOnly = !hardware,
            supportsSize = { w, h -> w <= maxW && h <= maxH && (!landscapeOnly || w >= h) },
        )

    const val AVC = "video/avc"
    const val HEVC = "video/hevc"

    /** A catalog from MIME → encoders (platform order). */
    fun catalog(vararg encoders: EncoderCandidate): EncoderCatalog = EncoderCatalog { mime -> encoders.filter { it.mimeType == mime } }

    /** A typical phone: hardware AVC and HEVC listed after the platform software encoders. */
    val phone = catalog(
        encoder("c2.android.avc.encoder", AVC, hardware = false, maxW = 2048, maxH = 2048),
        encoder("c2.qti.avc.encoder", AVC, hardware = true),
        encoder("c2.android.hevc.encoder", HEVC, hardware = false, maxW = 1920, maxH = 1920),
        encoder("c2.qti.hevc.encoder", HEVC, hardware = true),
    )

    /** The x86_64 emulator: software encoders only (and a goldfish AVC listed as hardware on some images). */
    val softwareOnly = catalog(
        encoder("c2.android.avc.encoder", AVC, hardware = false, maxW = 2048, maxH = 2048),
        encoder("c2.android.hevc.encoder", HEVC, hardware = false, maxW = 1920, maxH = 1920),
    )
}

/** Settings messages. */
object Settings {
    fun msg(
        w: Long = 1280,
        h: Long = 720,
        fps: Long = 30,
        codec: VideoCodecMsg = VideoCodecMsg.H264,
        container: ExportContainerMsg = ExportContainerMsg.MP4,
        videoBitrate: Long = 5_000_000,
    ) = EncodeSettingsMsg(
        container = container,
        codec = codec,
        width = w,
        height = h,
        fps = fps,
        videoBitrate = videoBitrate,
        audioBitrate = 192_000,
        audioSampleRate = 48_000,
        audioChannels = 2,
        keyframeIntervalMs = 2000,
        stripLocation = true,
    )

    fun of(w: Int = 1280, h: Int = 720, fps: Int = 30, codec: ExportVideoCodec = ExportVideoCodec.H264) =
        EncoderSettings(codec, w, h, fps, 5_000_000, 192_000, 2000)
}

/** Export plans built in code. */
object Plans {
    /** A plan with [slots] media slots over the whole duration (one layer per slot, all overlapping). */
    fun media(
        slots: Int = 1,
        seconds: Int = 2,
        fps: Int = 30,
        gridFps: Int = fps,
        w: Int = 1280,
        h: Int = 720,
        target: PlanTarget = PlanTarget.EXPORT,
        req: PlanRequirements? = null,
    ): RenderPlan {
        val g = FrameGrid.of(gridFps)
        val dur = g.timeOfFrame(seconds.toLong() * gridFps)
        val layers = (0 until slots).map { s ->
            PlanLayer(
                id = "it_l$s#v", z = 10 + s * 10, seq = s, t0 = 0, t1 = dur, kind = PlanLayerKind.MEDIA, asset = "md_src",
                map = listOf(MapSegment(0, dur, 0, dur)), base = PlanSize(w.toDouble(), h.toDouble()),
            )
        }.sortedWith(PlanValidator::compareLayers)
        return RenderPlan(
            rev = 1, target = target, canvas = PlanCanvas(w, h, fps, gridFps), durUs = dur,
            assets = mapOf("md_src" to PlanAsset(PlanAssetKind.VIDEO, "file:///fixtures/src.mp4", fp = "src", w = w, h = h, durUs = 60_000_000)),
            layers = layers, audio = emptyList(), req = req,
        )
    }
}

/** A recording [ExportEnvironment]. */
class FakeEnvironment(
    var budget: DecoderBudget = DecoderBudget(maxVisualSequences = 3, maxDecoderInstances = 16),
    var listener: Boolean = true,
) : ExportEnvironment {
    val calls = mutableListOf<String>()

    override fun decoderBudget(): DecoderBudget = budget

    override fun hdrMode(plan: RenderPlan): Int = 0

    override fun isBackgrounded(): Boolean = false

    override fun hasDartListener(): Boolean = listener

    override fun exportStarted(jobId: String, output: File) {
        calls += "started:$jobId"
    }

    override fun exportEnded(jobId: String, output: File) {
        calls += "ended:$jobId"
    }
}

/** A pass double: records the job and lets the test drive the listener. */
open class PassDouble : ExportPass {
    var job: ExportJob? = null
    var listener: ExportPassListener? = null
    var cancelled = 0
    var starts = 0

    override fun start(job: ExportJob, listener: ExportPassListener): Cancellable {
        starts++
        this.job = job
        this.listener = listener
        return Cancellable { cancelled++ }
    }

    /** Writes [bytes] bytes to the output and reports completion with [encoder]. */
    fun complete(encoder: String?, bytes: Int = 1024) {
        val j = checkNotNull(job)
        j.output.parentFile?.mkdirs()
        j.output.writeBytes(ByteArray(bytes))
        listener!!.onCompleted(encoder)
    }

    fun progress(f: Double) = listener!!.onProgress(f)

    fun warn(w: ExportWarningMsg) = listener!!.onWarning(w)
}

/** A [MultiPassExport] double (AND-19 stands in). */
class MultiPassDouble : PassDouble(), MultiPassExport
