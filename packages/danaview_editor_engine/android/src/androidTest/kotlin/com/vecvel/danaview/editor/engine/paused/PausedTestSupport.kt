@file:OptIn(UnstableApi::class, ExperimentalApi::class)
// OWNER: AND-17
//
// Support for the AND-17 instrumented tests (package paused):
// - [PausedHarness]: a PausedFrameRenderer on a real danaview-gl lane, fed by an engine
//   SourceFrameCache (software decoders first: the emulator's goldfish H.264 decoder drops
//   B-pyramid frames, AND-08 hand-off fact 1) and Media3's image loader, plus blocking helpers.
// - [PausedReference]: the parity reference. AND-01 reported a NO-GO for CompositionPlayer preview,
//   so the reference frame is the Transformer export of the same plan: AND-08's mapper +
//   Media3Composition with AND-09's LayerEffectChainFactory, and a composition-level GlEffect
//   ([CompositedFrameCapture]) that reads back the composited RGBA8 frame BEFORE the encoder
//   (so H.264 and YUV 4:2:0 losses do not enter the comparison) for the requested output frames.
// - [PausedPlans]: 640×360 plans over ENG-05's committed fixtures (frame_counter_720p24.mp4,
//   barcode = frame number; alpha.png) at 24 fps.
// - [Stats]: percentiles of measured times (emulator numbers, logged under "AND17").

package com.vecvel.danaview.editor.engine.paused

import android.content.Context
import android.opengl.GLES20
import android.util.Log
import androidx.annotation.OptIn
import androidx.media3.common.util.ExperimentalApi
import androidx.media3.common.util.GlProgram
import androidx.media3.common.util.GlUtil
import androidx.media3.common.util.Size
import androidx.media3.common.util.UnstableApi
import androidx.media3.effect.BaseGlShaderProgram
import androidx.media3.effect.GlEffect
import androidx.media3.effect.GlShaderProgram
import androidx.media3.transformer.Composition
import androidx.media3.transformer.Effects
import com.vecvel.danaview.editor.engine.composition.CompositionMapper
import com.vecvel.danaview.editor.engine.composition.ExportRunner
import com.vecvel.danaview.editor.engine.composition.ExtractorSourceTimeline
import com.vecvel.danaview.editor.engine.composition.Media3Composition
import com.vecvel.danaview.editor.engine.composition.PngCompositionImages
import com.vecvel.danaview.editor.engine.core.Completion
import com.vecvel.danaview.editor.engine.core.EngineContext
import com.vecvel.danaview.editor.engine.core.HandlerLane
import com.vecvel.danaview.editor.engine.core.LaneSpec
import com.vecvel.danaview.editor.engine.effects.EffectFixtures
import com.vecvel.danaview.editor.engine.effects.LayerEffectChainFactory
import com.vecvel.danaview.editor.engine.effects.ParityMetrics
import com.vecvel.danaview.editor.engine.effects.ParityStats
import com.vecvel.danaview.editor.engine.freeze.FreezeEngine
import com.vecvel.danaview.editor.engine.harness.FixtureTree
import com.vecvel.danaview.editor.engine.harness.TestFixtures
import com.vecvel.danaview.editor.engine.media.ExactFrames
import com.vecvel.danaview.editor.engine.plan.FrameGrid
import com.vecvel.danaview.editor.engine.plan.MapSegment
import com.vecvel.danaview.editor.engine.plan.ParamSnapshot
import com.vecvel.danaview.editor.engine.plan.PlanAsset
import com.vecvel.danaview.editor.engine.plan.PlanAssetKind
import com.vecvel.danaview.editor.engine.plan.PlanCanvas
import com.vecvel.danaview.editor.engine.plan.PlanEffects
import com.vecvel.danaview.editor.engine.plan.PlanLayer
import com.vecvel.danaview.editor.engine.plan.PlanLayerKind
import com.vecvel.danaview.editor.engine.plan.PlanSize
import com.vecvel.danaview.editor.engine.plan.PlanTarget
import com.vecvel.danaview.editor.engine.plan.PlanTransform
import com.vecvel.danaview.editor.engine.plan.PlanValidator
import com.vecvel.danaview.editor.engine.plan.RenderPlan
import com.vecvel.danaview.editor.engine.preview.EngineFrameSource
import com.vecvel.danaview.editor.engine.preview.PausedFrameRenderer
import com.vecvel.danaview.editor.engine.preview.PausedFrameSource
import com.vecvel.danaview.editor.engine.preview.SourceFrameCache
import org.junit.Assert.assertEquals
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference

const val AND17_TAG = "AND17"

/** Blocks for an asynchronous call's [Completion] and returns its value (rethrows its failure). */
fun <T> await(timeoutS: Long = 120, call: (Completion<T>) -> Unit): T {
    val latch = CountDownLatch(1)
    val result = AtomicReference<Result<T>>()
    call {
        result.set(it)
        latch.countDown()
    }
    check(latch.await(timeoutS, TimeUnit.SECONDS)) { "timed out" }
    return result.get().getOrThrow()
}

/** The 640×360 / 24 fps test plans (file header). */
object PausedPlans {
    const val W = 640
    const val H = 360
    const val FPS = 24
    const val FRAMES = 12L
    val grid: FrameGrid = FrameGrid.of(FPS)

    fun uri(name: String): String = "file://" + TestFixtures.copyToCache(FixtureTree.ENGINE, "media/$name").absolutePath

    /** Assets: the 720p24 frame counter, alpha.png and a LUT (EffectFixtures serves every `.vlut`). */
    fun assets(): Map<String, PlanAsset> = mapOf(
        "counter" to PlanAsset(PlanAssetKind.VIDEO, uri("frame_counter_720p24.mp4"), fp = "fp-counter24", w = 1280, h = 720),
        "alpha" to PlanAsset(PlanAssetKind.IMAGE, uri("alpha.png"), fp = "fp-alpha", w = 512, h = 512),
        "lut" to PlanAsset(PlanAssetKind.LUT, "file:///and17/look.vlut", fp = "fp-lut"),
    )

    /** A media layer of the counter showing source frame [sourceFrame] at frame [k0]. */
    fun media(
        id: String,
        z: Int,
        seq: Int,
        k0: Long,
        k1: Long,
        sourceFrame: Long,
        xf: PlanTransform = PlanTransform.IDENTITY,
        fx: PlanEffects = PlanEffects.NONE,
        base: PlanSize? = null,
    ): PlanLayer {
        val t0 = grid.timeOfFrame(k0)
        val t1 = grid.timeOfFrame(k1)
        val s0 = Math.floorDiv(sourceFrame * 1_000_000L, FPS.toLong())
        return PlanLayer(
            id = id, z = z, seq = seq, t0 = t0, t1 = t1, kind = PlanLayerKind.MEDIA, asset = "counter",
            map = listOf(MapSegment(t0, t1, s0, s0 + (t1 - t0))), xf = xf, fx = fx, base = base,
        )
    }

    fun plan(layers: List<PlanLayer>, rev: Long = 1, bg: Int = 0xFF203040.toInt()): RenderPlan {
        val p = RenderPlan(
            rev = rev, target = PlanTarget.PREVIEW, canvas = PlanCanvas(W, H, FPS, bg = bg), durUs = grid.timeOfFrame(FRAMES),
            assets = assets(), layers = layers.sortedWith(PlanValidator::compareLayers), audio = emptyList(),
        )
        assertEquals("plan valid", emptyList<Any>(), PlanValidator.validate(p))
        return p
    }
}

/** A PausedFrameRenderer on a danaview-gl lane over the engine's frame cache (file header). */
class PausedHarness(name: String, plan: RenderPlan) : AutoCloseable {
    val engine = FreezeEngine(name)
    val ctx: EngineContext get() = engine.ctx
    val lane = HandlerLane(LaneSpec.GL)
    val cache = SourceFrameCache(engine.ctx, 128L * 1024 * 1024).apply { codecSelector = ExactFrames.softwareFirst }
    private val images = EngineFrameSource(engine.ctx)
    val source = PausedFrameSource { request, control ->
        if (request.kind == PlanAssetKind.VIDEO) {
            cache.frame(request.uri, request.fingerprint, request.sourceTimeUs, request.maxLongSide, control)
        } else {
            images.frame(request, control)
        }
    }
    val snapshot = AtomicReference(ParamSnapshot.of(plan))
    val renderer = PausedFrameRenderer(engine.ctx.appContext, lane, source, snapshot, assets = EffectFixtures.assets)

    fun prefetch(k: Long): PausedFrameRenderer.PrefetchResult = await { renderer.prefetch(k, it) }

    fun render(): PausedFrameRenderer.RenderResult = await { renderer.render(it) }

    fun capture(): PausedFrameRenderer.Captured = await { renderer.capture(it) }

    /** Swaps the snapshot to [next] (a param-only or structural patch; transients on touched layers drop). */
    fun setPlan(next: RenderPlan, touched: Set<String> = emptySet()) {
        snapshot.set(snapshot.get().withPlan(next, touched))
    }

    override fun close() {
        try {
            await<Unit> { renderer.dispose(it) }
        } finally {
            lane.quit()
            cache.removeAll()
            engine.close()
        }
    }
}

/**
 * Composition-level effect that passes the composited frame through and keeps a top-down RGBA copy
 * of the output frames [wanted] selects by their pts (file header).
 */
class CompositedFrameCapture(private val wanted: (Long) -> Boolean) : GlEffect {
    /** Captured frames by pts: (width, height, rgba top-down). */
    val frames = ConcurrentHashMap<Long, Triple<Int, Int, ByteArray>>()

    override fun toGlShaderProgram(context: Context, useHdr: Boolean): GlShaderProgram = Program(this)

    private class Program(private val e: CompositedFrameCapture) : BaseGlShaderProgram(false, 1) {
        private val program = GlProgram(VERTEX, FRAGMENT).also {
            it.setBufferAttribute("aFramePosition", GlUtil.getNormalizedCoordinateBounds(), GlUtil.HOMOGENEOUS_COORDINATE_VECTOR_SIZE)
        }
        private var w = 0
        private var h = 0

        override fun configure(inputWidth: Int, inputHeight: Int): Size {
            w = inputWidth
            h = inputHeight
            return Size(inputWidth, inputHeight)
        }

        override fun drawFrame(inputTexId: Int, presentationTimeUs: Long) {
            program.use()
            program.setSamplerTexIdUniform("uTex", inputTexId, 0)
            program.bindAttributesAndUniforms()
            GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4)
            if (!e.wanted(presentationTimeUs)) return
            val buf = ByteBuffer.allocateDirect(w * h * 4).order(ByteOrder.nativeOrder())
            GLES20.glReadPixels(0, 0, w, h, GLES20.GL_RGBA, GLES20.GL_UNSIGNED_BYTE, buf)
            val out = ByteArray(w * h * 4)
            val stride = w * 4
            for (y in 0 until h) {
                buf.position((h - 1 - y) * stride)
                buf.get(out, y * stride, stride)
            }
            e.frames[presentationTimeUs] = Triple(w, h, out)
        }

        override fun release() {
            super.release()
            program.delete()
        }
    }

    private companion object {
        const val VERTEX = """
attribute vec4 aFramePosition;
varying vec2 vTex;
void main() {
  gl_Position = aFramePosition;
  vTex = (aFramePosition.xy + 1.0) * 0.5;
}
"""
        const val FRAGMENT = """
precision highp float;
uniform sampler2D uTex;
varying vec2 vTex;
void main() { gl_FragColor = texture2D(uTex, vTex); }
"""
    }
}

/** The Transformer reference of a plan's composed frames (file header). */
object PausedReference {
    /** The composited RGBA (top-down) of output frames [ks] of [plan] exported by Transformer. */
    fun composedFrames(plan: RenderPlan, ks: Set<Long>, name: String): Map<Long, ByteArray> {
        val ctx = TestFixtures.targetContext
        val export = plan.copy(target = PlanTarget.EXPORT)
        val spec = ExtractorSourceTimeline(ctx).use { CompositionMapper(it).map(export) }
        val images = PngCompositionImages(File(ctx.cacheDir, "and17_images"))
        val built = Media3Composition.build(spec, images, LayerEffectChainFactory(assets = EffectFixtures.assets), AtomicReference(ParamSnapshot.of(export)))
        val grid = FrameGrid.of(plan.canvas.fps)
        val capture = CompositedFrameCapture { pts -> grid.frameIndexNearest(pts) in ks }
        val c = built.composition
        val composition = Composition.Builder(c.sequences)
            .setVideoCompositorSettings(c.videoCompositorSettings)
            .setHdrMode(c.hdrMode)
            .setEffects(Effects(Media3Composition.compositionAudioProcessors(), listOf(capture)))
            .build()
        val out = File(ctx.cacheDir, "and17_exports/$name.mp4")
        try {
            val (_, ms) = ExportRunner.export(composition, out)
            Log.i(AND17_TAG, "reference export $name: $ms ms (emulator)")
        } finally {
            out.delete()
        }
        val byK = HashMap<Long, ByteArray>()
        for ((pts, frame) in capture.frames) {
            assertEquals("composited width", plan.canvas.w, frame.first)
            assertEquals("composited height", plan.canvas.h, frame.second)
            byK[grid.frameIndexNearest(pts)] = frame.third
        }
        assertEquals("captured frames", ks, byK.keys)
        return byK
    }

    /** Parity of [got] against [want] (both RGBA top-down, [w] × [h]); no pixel excluded. */
    fun parity(got: ByteArray, want: ByteArray, w: Int, h: Int): ParityStats =
        ParityMetrics.compare(ParityMetrics.unit(got), ParityMetrics.unit(want), 4, w, h, BooleanArray(w * h))

    /** Mean absolute RGB difference (0..255 units) inside the canvas rectangle [x0, x1) × [y0, y1). */
    fun meanDiff(a: ByteArray, b: ByteArray, w: Int, x0: Int, y0: Int, x1: Int, y1: Int): Double {
        var sum = 0L
        var n = 0
        for (y in y0 until y1) for (x in x0 until x1) for (c in 0 until 3) {
            val i = (y * w + x) * 4 + c
            sum += kotlin.math.abs((a[i].toInt() and 0xFF) - (b[i].toInt() and 0xFF))
            n++
        }
        return if (n == 0) 0.0 else sum.toDouble() / n
    }
}

/** Percentiles of measured values. */
class Stats(values: List<Double>) {
    private val sorted = values.sorted()
    fun p(q: Double): Double = if (sorted.isEmpty()) Double.NaN else sorted[((sorted.size - 1) * q).toInt()]
    val p50: Double get() = p(0.5)
    val p90: Double get() = p(0.9)
    val max: Double get() = sorted.lastOrNull() ?: Double.NaN
    override fun toString(): String = "n=%d p50=%.1f p90=%.1f max=%.1f ms".format(sorted.size, p50, p90, max)
}
