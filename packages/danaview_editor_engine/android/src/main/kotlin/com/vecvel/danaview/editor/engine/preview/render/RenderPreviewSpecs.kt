// OWNER: AND-18
//
// What a render-preview job renders (ARCH D-45 (A), §13.3; BUILD_PLAN AND-18), pure and JVM-tested:
// - The range plan arrives as a PREVIEW plan cut to the range (times relative to its start). It is
//   rendered as an export plan ([exportPlan]): target EXPORT (originals, never proxies, AND-08),
//   the same layers, effects, gating and canvas geometry; no audio (audio always plays live); one
//   grid frame longer than the range ([paddedDurationUs], as AND-19's intermediates) so the muxer
//   never cuts the last frame. Pending reverse/freeze items, held layers and offline media are
//   refused (`planInvalid` / `mediaOffline`), and so is a plan that reads a render file (render
//   files are never inputs: export plans never reference them, D-45).
// - Output ([settings]): H.264, the preview canvas size = the plan canvas fitted into the tier's
//   preview long side (never upscaled, even sides), the project fps on the frame grid, I-frame
//   interval 0 (all-intra) at [BITS_PER_PIXEL] bits per pixel per frame within
//   [MIN_BITRATE]..[MAX_BITRATE]; hardware encoder first with Transformer's fallback (AND-11).
// - The composition is the export mapping without audio sequences and with a video-only clock
//   band ([videoOnly]), so the file has one video track.
// - The job writes `<outputPath>.part` ([partFile]) and renames it to `outputPath` when complete;
//   cancel, pre-emption, failure and a thermal pause delete the part file, and the first use of the
//   service in a process deletes stale part files a dead process left ([staleParts]).

package com.vecvel.danaview.editor.engine.preview.render

import com.vecvel.danaview.editor.engine.composition.CompositionSpec
import com.vecvel.danaview.editor.engine.composition.SequenceKind
import com.vecvel.danaview.editor.engine.composition.TrackTypes
import com.vecvel.danaview.editor.engine.core.EngineErrorCode
import com.vecvel.danaview.editor.engine.core.EngineErrors
import com.vecvel.danaview.editor.engine.core.EngineException
import com.vecvel.danaview.editor.engine.core.Paths
import com.vecvel.danaview.editor.engine.export.EncoderSettings
import com.vecvel.danaview.editor.engine.export.ExportVideoCodec
import com.vecvel.danaview.editor.engine.plan.FrameGrid
import com.vecvel.danaview.editor.engine.plan.PlanTarget
import com.vecvel.danaview.editor.engine.plan.RenderPlan
import java.io.File

/** Render-preview job inputs and outputs (file header). */
object RenderPreviewSpecs {
    /** Suffix of the file being written. */
    const val PART_SUFFIX = ".part"

    /** Encoder bits per pixel per frame of the all-intra preview files. */
    const val BITS_PER_PIXEL = 0.8

    /** Bitrate bounds (bps). */
    const val MIN_BITRATE = 2_000_000
    const val MAX_BITRATE = 40_000_000

    /** All-intra (I-frame interval 0). */
    const val KEYFRAME_INTERVAL_MS = 0

    /** Unused audio bitrate (the files are video only; EncoderSettings needs one). */
    const val AUDIO_BITRATE = 128_000

    /** `<outputPath>.part`. */
    fun partFile(output: File): File = File(output.path + PART_SUFFIX)

    /** The renders directory of [paths] (`<cache>/danaview/editor/renders`, like the glue's check). */
    fun rendersDir(paths: Paths): File = File(paths.cacheRoot, "renders")

    /** Part files in [dir] (left by a process that died while rendering). */
    fun staleParts(dir: File): List<File> = dir.listFiles { f -> f.isFile && f.name.endsWith(PART_SUFFIX) }?.toList().orEmpty()

    /** The canvas [w]×[h] fitted into [maxLongSide] (never upscaled), both sides even and ≥ 2. */
    fun outputSize(w: Int, h: Int, maxLongSide: Int): Pair<Int, Int> {
        require(w > 0 && h > 0) { "canvas" }
        val long = maxOf(w, h)
        val scale = if (maxLongSide in 1 until long) maxLongSide.toDouble() / long else 1.0
        fun even(v: Double): Int = maxOf(2, (Math.round(v / 2.0) * 2).toInt())
        var ow = even(w * scale)
        var oh = even(h * scale)
        // Rounding up to even must not exceed the cap.
        if (maxLongSide > 0) {
            while (maxOf(ow, oh) > maxOf(maxLongSide, 2)) if (ow >= oh) ow -= 2 else oh -= 2
        }
        return ow to oh
    }

    /** Video bitrate of a [w]×[h] all-intra file at [fps]. */
    fun videoBitrate(w: Int, h: Int, fps: Int): Int =
        (w.toLong() * h * fps * BITS_PER_PIXEL).toLong().coerceIn(MIN_BITRATE.toLong(), MAX_BITRATE.toLong()).toInt()

    /** Encoder settings of [plan] (an [exportPlan]) for a tier preview long side of [maxLongSide]. */
    fun settings(plan: RenderPlan, maxLongSide: Int): EncoderSettings {
        val (w, h) = outputSize(plan.canvas.w, plan.canvas.h, maxLongSide)
        val fps = plan.canvas.fps
        return EncoderSettings(
            codec = ExportVideoCodec.H264,
            width = w,
            height = h,
            fps = fps,
            videoBitrate = videoBitrate(w, h, fps),
            audioBitrate = AUDIO_BITRATE,
            keyframeIntervalMs = KEYFRAME_INTERVAL_MS,
        )
    }

    /** [durUs] plus one grid frame of [plan]'s grid. */
    fun paddedDurationUs(plan: RenderPlan): Long {
        val grid = FrameGrid.of(plan.canvas.gridFps)
        return grid.timeOfFrame(grid.frameIndexOf(plan.durUs) + 1)
    }

    /**
     * Output frames of the range: the k with timeOfFrame(k) < durUs on the output grid, i.e.
     * floor((durUs − 1)·fps / 1e6) + 1 (timeOfFrame is a ceiling, so durUs = timeOfFrame(n) gives n).
     */
    fun rangeFrames(plan: RenderPlan): Long = if (plan.durUs <= 0) 0 else Math.floorDiv((plan.durUs - 1) * plan.canvas.fps, FrameGrid.MICROS) + 1

    /**
     * The export plan that renders the PREVIEW range plan [range] (file header). Throws `planInvalid`
     * (not a preview plan, empty, held layers, pending items, a render file as input) or
     * `mediaOffline`. [rendersDir] null skips the render-file check (JVM tests without paths).
     */
    fun exportPlan(range: RenderPlan, rendersDir: File?): RenderPlan {
        if (range.target != PlanTarget.PREVIEW) throw EngineErrors.invalidPlan("render previews take a preview plan")
        if (range.durUs <= 0) throw EngineErrors.invalidPlan("an empty range has nothing to render")
        range.req?.let { req ->
            req.offline.firstOrNull()?.let { throw EngineException(EngineErrorCode.mediaOffline, "media offline", itemId = it) }
            (req.pendingReverse + req.pendingStill).firstOrNull()?.let {
                throw EngineException(EngineErrorCode.planInvalid, "a reverse or freeze job is pending", itemId = it)
            }
        }
        range.layers.firstOrNull { it.hold }?.let { throw EngineException(EngineErrorCode.planInvalid, "a held layer cannot be rendered", itemId = it.id) }
        if (rendersDir != null) {
            renderFileAsset(range, rendersDir)?.let { throw EngineException(EngineErrorCode.planInvalid, "a render file cannot be an input", itemId = it) }
        }
        return range.copy(target = PlanTarget.EXPORT, durUs = paddedDurationUs(range), audio = emptyList(), req = null)
    }

    /**
     * The id of the first asset of [plan] whose file or proxy is inside [rendersDir], or null. Render
     * files are never inputs: not of a render (above) and not of an export (AND-11's
     * ExportCoordinator refuses such a plan, D-45 "export plans never reference render files").
     */
    fun renderFileAsset(plan: RenderPlan, rendersDir: File): String? =
        plan.assets.entries.firstOrNull { (_, a) -> isInside(a.uri, rendersDir) || a.proxyUri?.let { isInside(it, rendersDir) } == true }?.key

    private fun isInside(uri: String, dir: File): Boolean {
        val path = when {
            uri.startsWith("file://") -> uri.removePrefix("file://")
            uri.startsWith("/") -> uri
            else -> return false
        }
        val f = Paths.normalize(path) ?: return false
        return Paths.isInside(f, dir)
    }

    /**
     * [spec] without audio sequences and with a video-only clock band (a single video track; AND-19's
     * intermediates use the same cut). Sequence indices stay their list positions.
     */
    fun videoOnly(spec: CompositionSpec): CompositionSpec {
        val kept = spec.sequences
            .filter { it.kind != SequenceKind.AUDIO }
            .map { if (it.kind == SequenceKind.CLOCK_BAND) it.copy(trackTypes = TrackTypes.VIDEO) else it }
        return spec.copy(sequences = kept.mapIndexed { i, s -> if (s.index == i) s else s.copy(index = i) })
    }
}
