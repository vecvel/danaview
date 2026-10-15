// OWNER: AND-19
//
// Instrumented test support for AND-19: AND-11's ExportHarness (engine context with private roots,
// the production ExportCoordinator, which discovers the production PrecomposeExport by reflection)
// with the decoder budget forced through the coordinator's environment seam, a pass recorder on
// the precompose's observer hook, plans over ENG-05's committed fixtures that stack several packed
// slots with effects, an image lane and audio, and frame/audio comparison of two exports: per-frame
// SSIM of the video Y plane (studio-range BT.601 luma of the decoded frames; 8×8 windows, stride 4,
// the usual C1/C2 constants), frame barcodes (whole frame or a
// region) and 20 ms window RMS of the decoded audio (QA-11's ±0.5 dB tolerance).
// Diagnostic instrumentation arguments (am instrument -e …): and19Factor <n>, and19AllIntra
// true|false and and19Color EXPORT|BT601 override PrecomposePlanner.Options for a run.
// The recorder also scans every completed intermediate (MediaExtractor): sync samples against all
// samples and the achieved video bitrate, so the all-intra / 4x-bitrate rule is checked on the
// files the encoder actually wrote, not only on the requested EncoderSettings.
// Every number logged here is an EMULATOR measurement (tag DanaviewPrecomposeTest).

package com.vecvel.danaview.editor.engine.precompose

import android.graphics.Bitmap
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMetadataRetriever
import android.util.Log
import com.vecvel.danaview.editor.engine.export.ContextExportEnvironment
import com.vecvel.danaview.editor.engine.export.DecoderBudget
import com.vecvel.danaview.editor.engine.export.ExportEnvironment
import com.vecvel.danaview.editor.engine.export.ExportHarness
import com.vecvel.danaview.editor.engine.export.ExportPlans
import com.vecvel.danaview.editor.engine.export.ExportedFile
import com.vecvel.danaview.editor.engine.export.precompose.DiskEstimate
import com.vecvel.danaview.editor.engine.export.precompose.PrecomposeExport
import com.vecvel.danaview.editor.engine.export.precompose.PrecomposeObserver
import com.vecvel.danaview.editor.engine.export.precompose.PrecomposePlan
import com.vecvel.danaview.editor.engine.plan.AudioSeg
import com.vecvel.danaview.editor.engine.plan.FrameGrid
import com.vecvel.danaview.editor.engine.plan.Keyframes
import com.vecvel.danaview.editor.engine.plan.MapSegment
import com.vecvel.danaview.editor.engine.plan.PlanAdjust
import com.vecvel.danaview.editor.engine.plan.PlanAsset
import com.vecvel.danaview.editor.engine.plan.PlanAssetKind
import com.vecvel.danaview.editor.engine.plan.PlanCanvas
import com.vecvel.danaview.editor.engine.plan.PlanEffects
import com.vecvel.danaview.editor.engine.plan.PlanLayer
import com.vecvel.danaview.editor.engine.plan.PlanLayerKind
import com.vecvel.danaview.editor.engine.plan.PlanMask
import com.vecvel.danaview.editor.engine.plan.PlanMaskShape
import com.vecvel.danaview.editor.engine.plan.PlanSize
import com.vecvel.danaview.editor.engine.plan.PlanTarget
import com.vecvel.danaview.editor.engine.plan.PlanTransform
import com.vecvel.danaview.editor.engine.plan.PlanValidator
import com.vecvel.danaview.editor.engine.plan.RenderPlan
import com.vecvel.danaview.editor.engine.support.FrameBarcode
import com.vecvel.danaview.editor.engine.support.FrameBarcodeRegion
import com.vecvel.danaview.editor.engine.support.decode
import org.junit.Assert.assertEquals
import java.io.File
import java.util.concurrent.CopyOnWriteArrayList
import kotlin.math.log10

const val PRECOMPOSE_TEST_TAG = "DanaviewPrecomposeTest"

/** Log tag of every SSIM retry of PrecomposeExportTest (one line per retry; CI counts them). */
const val PRECOMPOSE_RETRY_TAG = "DanaviewPrecomposeRetry"

/** The production environment with the decoder budget replaced. */
class ForcedBudgetEnvironment(private val base: ExportEnvironment, @Volatile var budget: DecoderBudget) : ExportEnvironment by base {
    override fun decoderBudget(): DecoderBudget = budget
}

/** Sync samples, all samples, video bytes and duration of one intermediate as written. */
data class IntermediateStats(val number: Int, val syncSamples: Int, val samples: Int, val bytes: Long, val durationUs: Long) {
    val allIntra: Boolean get() = samples > 0 && syncSamples == samples
    val bitrate: Long get() = if (durationUs <= 0) 0 else bytes * 8 * 1_000_000 / durationUs

    companion object {
        fun scan(number: Int, f: File): IntermediateStats {
            val ex = MediaExtractor()
            try {
                ex.setDataSource(f.absolutePath)
                val t = (0 until ex.trackCount).first { ex.getTrackFormat(it).getString(MediaFormat.KEY_MIME)!!.startsWith("video/") }
                val format = ex.getTrackFormat(t)
                ex.selectTrack(t)
                var sync = 0
                var samples = 0
                var bytes = 0L
                var first = Long.MAX_VALUE
                var last = Long.MIN_VALUE
                while (ex.sampleTime >= 0) {
                    samples++
                    if (ex.sampleFlags and MediaExtractor.SAMPLE_FLAG_SYNC != 0) sync++
                    bytes += maxOf(0L, ex.sampleSize)
                    first = minOf(first, ex.sampleTime)
                    last = maxOf(last, ex.sampleTime)
                    if (!ex.advance()) break
                }
                // Duration: the track's, else the sample span plus one mean frame interval.
                val dur = if (format.containsKey(MediaFormat.KEY_DURATION)) {
                    format.getLong(MediaFormat.KEY_DURATION)
                } else if (samples > 1) {
                    (last - first) * samples / (samples - 1)
                } else {
                    0L
                }
                return IntermediateStats(number, sync, samples, bytes, dur)
            } finally {
                ex.release()
            }
        }
    }
}

/**
 * Records the precompose passes of every job (observer hook; called on danaview-export), the
 * colour standard each completed intermediate signals and its sync-sample / bitrate scan (read
 * before the next pass consumes it).
 */
class PassRecorder(private val workDirOf: (String) -> File) : PrecomposeObserver {
    val plans = CopyOnWriteArrayList<Pair<PrecomposePlan, DiskEstimate>>()
    val events = CopyOnWriteArrayList<String>()

    /** MediaFormat KEY_COLOR_STANDARD of each intermediate (−1 when not signalled). */
    val intermediateColorStandards = CopyOnWriteArrayList<Int>()

    /** The scan of each completed intermediate ([IntermediateStats]). */
    val intermediateStats = CopyOnWriteArrayList<IntermediateStats>()

    override fun onPlanned(jobId: String, plan: PrecomposePlan, disk: DiskEstimate) {
        plans += plan to disk
    }

    override fun onPassStarted(jobId: String, number: Int, total: Int) {
        events += "start $number/$total"
    }

    override fun onPassCompleted(jobId: String, number: Int, total: Int) {
        events += "done $number/$total"
        if (number < total) {
            val f = File(workDirOf(jobId), "pre-$number.mp4")
            val video = ExportedFile.video(f).format
            intermediateColorStandards += if (video.containsKey(MediaFormat.KEY_COLOR_STANDARD)) video.getInteger(MediaFormat.KEY_COLOR_STANDARD) else -1
            intermediateStats += IntermediateStats.scan(number, f)
        }
    }

    fun started(number: Int): Boolean = events.any { it.startsWith("start $number/") }
}

/** An [ExportHarness] whose coordinator's budget can be forced (file header). */
class PrecomposeHarness(name: String, fixedRoot: Boolean = false) {
    val h = ExportHarness("and19_$name", fixedRoot)
    val env = ForcedBudgetEnvironment(ContextExportEnvironment(h.ctx), DecoderBudget(16, 0))
    val recorder = PassRecorder { File(h.paths.work, "export-$it") }
    val precompose: PrecomposeExport

    init {
        h.coordinator.environment = env
        precompose = h.coordinator.multiPassExport() as PrecomposeExport
        precompose.observer = recorder
        val args = androidx.test.platform.app.InstrumentationRegistry.getArguments()
        args.getString("and19Factor")?.let { precompose.options = precompose.options.copy(bitrateFactor = it.toInt()) }
        args.getString("and19AllIntra")?.let { precompose.options = precompose.options.copy(allIntra = it.toBoolean()) }
        args.getString("and19Color")?.let { precompose.options = precompose.options.copy(color = com.vecvel.danaview.editor.engine.export.precompose.IntermediateColor.valueOf(it)) }
    }

    /** One pass for up to 16 slots (the emulator decodes them all in software). */
    fun singlePassBudget() {
        env.budget = DecoderBudget(maxVisualSequences = 16, maxDecoderInstances = 0)
    }

    /** `maxVisualSequences` forced to [slots] (no decoder-instance cap). */
    fun forceVisualSequences(slots: Int) {
        env.budget = DecoderBudget(maxVisualSequences = slots, maxDecoderInstances = 0)
    }

    fun workDir(jobId: String) = File(h.paths.work, "export-$jobId")

    fun close() = h.close()
}

/** Plans over the committed fixtures (all validated). */
object PrecomposeFixturePlans {
    class Source(val name: String, val fps: Int, val w: Int = 1280, val h: Int = 720, val durUs: Long = 8_000_000)

    /** The full-canvas counter of each export rate (barcode = source frame). */
    fun counter(fps: Int): Source = when (fps) {
        24 -> Source("frame_counter_720p24.mp4", 24)
        30 -> Source("frame_counter_1080p30.mp4", 30, 1920, 1080)
        60 -> Source("frame_counter_720p60.mp4", 60)
        else -> error("no counter at $fps fps")
    }

    /** First grid frame of the bottom layer's second half (a grid cut). */
    fun cutOf(frames: Long): Long = frames / 2 + 1

    /**
     * [slots] packed slots at [fps] over [frames] grid frames:
     *   slot 0 (bottom, z 10): the full-canvas [bottom] source cut at [cutOf] (source frame 0 → 100;
     *     its barcode band stays uncovered, so it is read from every output frame);
     *   slot 1…: picture-in-picture layers of tone_under_video.mp4 / clap_flash_av.mp4 /
     *     frame_counter_720p25.mp4 in the lower two thirds, with opacity, rotation, an adjustment,
     *     an ellipse mask and partial time ranges (gating);
     *   an image lane (alpha.png) between slot 1 and slot 2;
     *   audio: tone_1khz.wav with a gain ramp, and the clap track from 0.5 s, when [audio].
     */
    fun stack(
        fps: Int,
        frames: Long,
        slots: Int,
        audio: Boolean = true,
        bottom: Source = counter(fps),
        bottomBase: PlanSize = PlanSize(1280.0, 720.0),
        bottomCut: Boolean = true,
        extraAssets: Map<String, PlanAsset> = emptyMap(),
    ): RenderPlan {
        val g = FrameGrid.of(fps)
        val dur = g.timeOfFrame(frames)
        val layers = ArrayList<PlanLayer>()
        val cut = if (bottomCut) cutOf(frames) else frames
        layers += ExportPlans.mediaLayer("it_bottom_a#v", 10, 0, g, 0, cut, 0, bottom.fps, asset = "md_bottom", base = bottomBase)
        if (bottomCut) layers += ExportPlans.mediaLayer("it_bottom_b#v", 10, 0, g, cut, frames, 100, bottom.fps, asset = "md_bottom", base = bottomBase)
        val pips = listOf(
            Triple("md_tuv", 30, PlanTransform(cx = 980.0, cy = 520.0, op = 0.85)),
            Triple("md_clap", 30, PlanTransform(cx = 640.0, cy = 560.0, r = 8.0)),
            Triple("md_c25", 25, PlanTransform(cx = 300.0, cy = 470.0, s = 0.9)),
            Triple("md_tuv", 30, PlanTransform(cx = 1050.0, cy = 300.0, s = 0.6)),
            Triple("md_clap", 30, PlanTransform(cx = 200.0, cy = 300.0, op = 0.7)),
        )
        for (i in 1 until slots) {
            val (asset, srcFps, xf) = pips[(i - 1) % pips.size]
            // Odd slots span the whole plan; even ones start at a quarter and end early (gating).
            val k0 = if (i % 2 == 1) 0L else frames / 4
            val k1 = if (i % 2 == 1) frames else frames - frames / 5
            val l = ExportPlans.mediaLayer("it_pip$i#v", 10 + 10 * i, i, g, k0, k1, (5 * i).toLong(), srcFps, asset = asset, base = PlanSize(400.0, 225.0))
            layers += l.copy(
                xf = xf,
                fx = when (i % 3) {
                    1 -> PlanEffects(adj = PlanAdjust(saturation = -0.4, brightness = 0.1))
                    2 -> PlanEffects(mask = PlanMask(PlanMaskShape.ELLIPSE, w = 0.9, h = 0.9, feather = 0.1))
                    else -> PlanEffects.NONE
                },
            )
        }
        if (slots >= 2) {
            layers += PlanLayer(
                id = "it_logo#v", z = 25, t0 = 0, t1 = dur, kind = PlanLayerKind.IMAGE, asset = "im_alpha",
                base = PlanSize(200.0, 200.0), xf = PlanTransform(cx = 140.0, cy = 600.0),
            )
        }
        val segs = if (!audio) emptyList() else listOf(
            AudioSeg(
                id = "it_tone#a", asset = "md_tone", t0 = 0, t1 = dur, map = listOf(MapSegment(0, dur, 0, dur)),
                gain = Keyframes.of(0L to 0.2, dur / 2 to 1.0),
            ),
            AudioSeg(
                id = "it_clap#a", asset = "md_clap", t0 = g.timeOfFrame(frames / 4), t1 = dur,
                map = listOf(MapSegment(g.timeOfFrame(frames / 4), dur, 500_000, 500_000 + dur - g.timeOfFrame(frames / 4))),
                gain = Keyframes.of(0L to 1.0),
            ),
        )
        val plan = RenderPlan(
            rev = 1, target = PlanTarget.EXPORT, canvas = PlanCanvas(1280, 720, fps), durUs = dur,
            assets = mapOf(
                "md_bottom" to PlanAsset(PlanAssetKind.VIDEO, ExportPlans.media(bottom.name), fp = "bottom", w = bottom.w, h = bottom.h, durUs = bottom.durUs),
                "md_tuv" to PlanAsset(PlanAssetKind.VIDEO, ExportPlans.media("tone_under_video.mp4"), fp = "tuv", w = 1280, h = 720, durUs = 8_000_000, hasAudio = true),
                "md_clap" to PlanAsset(PlanAssetKind.VIDEO, ExportPlans.media("clap_flash_av.mp4"), fp = "clap", w = 1280, h = 720, durUs = 6_000_000, hasAudio = true),
                "md_c25" to PlanAsset(PlanAssetKind.VIDEO, ExportPlans.media("frame_counter_720p25.mp4"), fp = "c25", w = 1280, h = 720, durUs = 8_000_000),
                "md_tone" to PlanAsset(PlanAssetKind.AUDIO, ExportPlans.media("tone_1khz.wav"), fp = "tone", durUs = 10_000_000),
                "im_alpha" to PlanAsset(PlanAssetKind.IMAGE, ExportPlans.media("alpha.png"), fp = "alpha", w = 512, h = 512),
            ) + extraAssets,
            layers = layers.sortedWith(PlanValidator::compareLayers),
            audio = segs,
        )
        assertEquals(emptyList<Any>(), PlanValidator.validate(plan))
        return plan
    }

    /** The source frame the rule (ARCH §11.5) shows for source time [s] of a constant [fps] source. */
    fun ruleFrame(s: Long, fps: Int): Long {
        var i = Math.floorDiv((s + 500) * fps, 1_000_000L)
        while (Math.floorDiv(2 * (i + 1) * 1_000_000L + fps, 2L * fps) <= s + 500) i++
        while (i > 0 && Math.floorDiv(2 * i * 1_000_000L + fps, 2L * fps) > s + 500) i--
        return i
    }

    /** The barcode output frame [k] must show: the rule frame of the bottom layer covering timeOfFrame(k). */
    fun expectedBottom(plan: RenderPlan, k: Long, sourceFps: Int): Long {
        val t = FrameGrid.of(plan.canvas.fps).timeOfFrame(k)
        val layer = plan.layers.filter { it.z == 10 }.first { it.covers(t) }
        return ruleFrame(layer.map.first().s0 + (t - layer.t0), sourceFps)
    }
}

/** Frame and audio comparison of exported files (file header). */
object Compare {
    /**
     * The video Y plane of [b]: BT.601 luma of the decoded RGB, in studio range (16 + 219·Y/255),
     * the plane video SSIM is defined on (ffmpeg's ssim filter, libvmaf). [fullRange] keeps 0..255,
     * where SSIM's luminance term is hypersensitive near black (a 1-level lift of a flat black area
     * scores 0.87): logged for reference only.
     */
    fun luma(b: Bitmap, fullRange: Boolean = false): FloatArray {
        val px = IntArray(b.width * b.height)
        b.getPixels(px, 0, b.width, 0, 0, b.width, b.height)
        val scale = if (fullRange) 1f else 219f / 255f
        val offset = if (fullRange) 0f else 16f
        return FloatArray(px.size) { i ->
            val c = px[i]
            offset + scale * (0.299f * (c shr 16 and 0xFF) + 0.587f * (c shr 8 and 0xFF) + 0.114f * (c and 0xFF))
        }
    }

    /** Mean SSIM of two luma planes over 8×8 windows with stride 4. */
    fun ssim(a: FloatArray, b: FloatArray, w: Int, h: Int): Double {
        val c1 = (0.01 * 255) * (0.01 * 255)
        val c2 = (0.03 * 255) * (0.03 * 255)
        var sum = 0.0
        var n = 0
        var y = 0
        while (y + 8 <= h) {
            var x = 0
            while (x + 8 <= w) {
                var ma = 0.0
                var mb = 0.0
                for (j in 0 until 8) for (i in 0 until 8) {
                    val p = (y + j) * w + x + i
                    ma += a[p]
                    mb += b[p]
                }
                ma /= 64
                mb /= 64
                var va = 0.0
                var vb = 0.0
                var cov = 0.0
                for (j in 0 until 8) for (i in 0 until 8) {
                    val p = (y + j) * w + x + i
                    val da = a[p] - ma
                    val db = b[p] - mb
                    va += da * da
                    vb += db * db
                    cov += da * db
                }
                va /= 63
                vb /= 63
                cov /= 63
                sum += ((2 * ma * mb + c1) * (2 * cov + c2)) / ((ma * ma + mb * mb + c1) * (va + vb + c2))
                n++
                x += 4
            }
            y += 4
        }
        return sum / n
    }

    /** Per-frame Y-plane SSIM of [a] against [b] (and full-range, for reference) and the barcodes of both. */
    class Frames(val ssim: DoubleArray, val ssimFullRange: DoubleArray, val barcodesA: List<Int?>, val barcodesB: List<Int?>)

    fun frames(a: File, b: File, count: Int, region: FrameBarcodeRegion? = null): Frames {
        val ra = MediaMetadataRetriever()
        val rb = MediaMetadataRetriever()
        try {
            ra.setDataSource(a.absolutePath)
            rb.setDataSource(b.absolutePath)
            val ssim = DoubleArray(count)
            val full = DoubleArray(count)
            val ca = ArrayList<Int?>()
            val cb = ArrayList<Int?>()
            var i = 0
            while (i < count) {
                val n = minOf(8, count - i)
                val fa = ra.getFramesAtIndex(i, n)
                val fb = rb.getFramesAtIndex(i, n)
                for (j in 0 until n) {
                    val x = fa[j]
                    val y = fb[j]
                    ssim[i + j] = ssim(luma(x), luma(y), x.width, x.height)
                    full[i + j] = ssim(luma(x, fullRange = true), luma(y, fullRange = true), x.width, x.height)
                    ca += FrameBarcode.decode(x, region)
                    cb += FrameBarcode.decode(y, region)
                    x.recycle()
                    y.recycle()
                }
                i += n
            }
            return Frames(ssim, full, ca, cb)
        } finally {
            ra.release()
            rb.release()
        }
    }

    /** RMS (dBFS) of 20 ms windows of channel-interleaved [pcm]. */
    fun windowsDb(pcm: ExportedFile.Pcm): DoubleArray {
        val win = pcm.sampleRate / 50
        val n = pcm.frames / win
        return DoubleArray(n) { w ->
            var s = 0.0
            for (f in w * win until (w + 1) * win) for (c in 0 until pcm.channels) {
                val v = pcm.samples[f * pcm.channels + c].toDouble()
                s += v * v
            }
            val ms = s / (win * pcm.channels)
            if (ms <= 0) -200.0 else 10 * log10(ms)
        }
    }

    /** Largest |dB| difference over windows audible in [ref] (> −60 dBFS), and the windows compared. */
    fun audioDelta(ref: ExportedFile.Pcm, other: ExportedFile.Pcm): Pair<Double, Int> {
        val a = windowsDb(ref)
        val b = windowsDb(other)
        var worst = 0.0
        var compared = 0
        for (i in 0 until minOf(a.size, b.size)) {
            if (a[i] <= -60 && b[i] <= -60) continue
            worst = maxOf(worst, kotlin.math.abs(a[i] - b[i]))
            compared++
        }
        return worst to compared
    }

    fun log(msg: String) = Log.i(PRECOMPOSE_TEST_TAG, msg)
}
