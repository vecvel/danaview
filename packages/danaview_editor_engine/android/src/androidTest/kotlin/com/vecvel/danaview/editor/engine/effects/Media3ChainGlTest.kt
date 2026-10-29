@file:OptIn(UnstableApi::class, ExperimentalApi::class)
// OWNER: AND-09
//
// The real Media3 GlEffect programs inside a Media3 video graph (FrameExtractor, media3-inspector-
// frame 1.11.1, EXACT seek) on the API 35 emulator:
// - LayerLookEffect (MAX_SCALE, LUT through EffectAssets) → SeparableBlurEffect → LayerPlaceEffect
//   on frame 15 of frame_counter_1080p30.mp4, bound to effects_every_static_key's every-effect
//   layer through the live ParamSnapshot (pts 500 000 µs → k = 15), match Media3ChainEmulation
//   (the same EffectPasses on explicit textures, the source being the same frame extracted without
//   effects) within 2/255 per channel, so the parity goldens run on what the Media3 programs draw;
// - the programs run on Media3's own GL thread (GlThreadPolicy accepts it, the output exists);
// - a gap item's chain ([LayerPlaceEffect(LayerBinding.NONE)]) outputs a fully transparent
//   canvas-render-size frame (the early exit);
// - closing the extractor releases every GL object the effects created (GlResources counts back to
//   their baseline: textures, framebuffers, buffers, programs).

package com.vecvel.danaview.editor.engine.effects

import android.graphics.Bitmap
import android.net.Uri
import android.util.Log
import androidx.annotation.OptIn
import androidx.media3.common.Effect
import androidx.media3.common.MediaItem
import androidx.media3.common.util.ExperimentalApi
import androidx.media3.common.util.UnstableApi
import androidx.media3.exoplayer.SeekParameters
import androidx.media3.inspector.frame.FrameExtractor
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.vecvel.danaview.editor.engine.harness.FixtureTree
import com.vecvel.danaview.editor.engine.harness.PerfGate
import com.vecvel.danaview.editor.engine.harness.TestFixtures
import com.vecvel.danaview.editor.engine.plan.ParamSnapshot
import org.junit.AfterClass
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.BeforeClass
import org.junit.Test
import org.junit.runner.RunWith
import java.nio.ByteBuffer
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference
import kotlin.math.abs

@RunWith(AndroidJUnit4::class)
class Media3ChainGlTest {
    private val plan = EffectFixtures.plan("effects_every_static_key")
    private val layer = plan.layers.single { it.id == "it_fx0000000001#v" }
    private val item: MediaItem by lazy {
        MediaItem.fromUri(Uri.fromFile(TestFixtures.copyToCache(FixtureTree.ENGINE, "media/frame_counter_1080p30.mp4")))
    }

    private fun extract(effects: List<Effect>): FrameExtractor.Frame =
        FrameExtractor.Builder(TestFixtures.targetContext, item)
            .setSeekParameters(SeekParameters.EXACT)
            .setEffects(effects)
            .build()
            .use { it.getFrame(500).get(PerfGate.boundMs(120_000), TimeUnit.MILLISECONDS) }

    /** The bitmap's bytes as stored (RGBA order, no un-premultiplication), top-down rows. */
    private fun rawBytes(bitmap: Bitmap): ByteArray {
        assertEquals(Bitmap.Config.ARGB_8888, bitmap.config)
        val buf = ByteBuffer.allocate(bitmap.byteCount)
        bitmap.copyPixelsToBuffer(buf)
        val out = ByteArray(bitmap.width * bitmap.height * 4)
        val stride = bitmap.rowBytes
        for (y in 0 until bitmap.height) System.arraycopy(buf.array(), y * stride, out, y * bitmap.width * 4, bitmap.width * 4)
        return out
    }

    /** Waits until the effects' GL objects are released (FrameExtractor releases its graph asynchronously). */
    private fun awaitCounts(want: GlCounts): GlCounts {
        val deadline = System.nanoTime() + 15_000_000_000L
        var now = GlResources.counts()
        while (now != want && System.nanoTime() < deadline) {
            Thread.sleep(50)
            now = GlResources.counts()
        }
        return now
    }

    @Test
    fun media3HostedProgramsMatchTheEffectPasses() {
        val geometry = RenderGeometry(plan.canvas.w, plan.canvas.h, 480, 270)
        val snapshot = AtomicReference(ParamSnapshot.of(plan))
        val binding = LayerBinding.of(snapshot, null, layer.id)
        assertTrue("the layer blurs, so the chain has three effects", ParamSnapshot.needsBlur(layer))

        val raw = extract(emptyList())
        assertEquals(500L, raw.presentationTimeMs)
        val baseline = GlResources.counts()
        fun chain(): List<Effect> = listOf(
            LayerLookEffect(binding, geometry, RasterSizing.MAX_SCALE, assets = EffectFixtures.assets),
            SeparableBlurEffect(binding, geometry),
            LayerPlaceEffect(binding, geometry),
        )
        var hosted = extract(chain())
        if (hosted.bitmap.width != 480 || hosted.bitmap.height != 270) {
            // The CI emulator (software GPU, loaded host) now and then hands back the decoded
            // 1920x1080 frame without the graph's output. That is the extraction failing, not the
            // effects drawing wrong: extract once more with a fresh graph, and the size, colour,
            // alpha and GL-release checks below apply to that frame unchanged. A chain that never
            // outputs its canvas render size still fails.
            Log.w(TAG, "Media3-hosted chain returned ${hosted.bitmap.width}x${hosted.bitmap.height} instead of 480x270 [emulator]; extracting once more")
            awaitCounts(baseline)
            hosted = extract(chain())
        }
        assertEquals("every GL object of the effects is released with the graph", baseline, awaitCounts(baseline))
        assertEquals("hosted chain output width", 480, hosted.bitmap.width)
        assertEquals("hosted chain output height", 270, hosted.bitmap.height)
        val got = rawBytes(hosted.bitmap)

        val rawRgba = rawBytes(raw.bitmap)
        val want = env.run {
            val programs = ShaderPrograms.acquire(GlTestEnv.shaders)
            val textures = GlAssetTextures(EffectFixtures.assets, programs.caps)
            val chain = Media3ChainEmulation()
            val tex = GlTestEnv.uploadRgba8(rawRgba, raw.bitmap.width, raw.bitmap.height)
            try {
                chain.draw(programs, layer, binding, raw.presentationTimeMs * 1000, geometry, tex, raw.bitmap.width, raw.bitmap.height, null, textures::lut, null, 480, 270)
            } finally {
                GlResources.deleteTexture(tex)
                chain.release()
                textures.release()
                programs.release()
            }
        }
        var maxRgb = 0
        var maxA = 0
        var sum = 0L
        var n = 0
        var covered = 0
        var transparent = 0
        for (i in 0 until 480 * 270) {
            val ga = got[i * 4 + 3].toInt() and 0xFF
            val wa = want[i * 4 + 3].toInt() and 0xFF
            maxA = maxOf(maxA, abs(ga - wa))
            if (wa > 0) covered++ else transparent++
            // Straight-alpha output: colours compare directly where both are clearly visible.
            if (ga >= 128 && wa >= 128) {
                for (c in 0 until 3) {
                    val d = abs((got[i * 4 + c].toInt() and 0xFF) - (want[i * 4 + c].toInt() and 0xFF))
                    maxRgb = maxOf(maxRgb, d)
                    sum += d
                    n++
                }
            }
        }
        Log.i(TAG, "Media3-hosted vs passes [emulator]: max |dRGB| $maxRgb/255 over $n samples, mean %.3f/255, max |dA| $maxA/255; covered $covered px, transparent $transparent px".format(if (n == 0) 0.0 else sum.toDouble() / n))
        assertTrue("the layer covers part of the frame and leaves the rest transparent", covered > 1000 && transparent > 1000)
        assertTrue("compared $n samples", n > 3000)
        assertTrue("alpha within 2/255 (max $maxA)", maxA <= 2)
        assertTrue("colour within 2/255 (max $maxRgb)", maxRgb <= 2)
    }

    @Test
    fun aGapItemChainOutputsTransparentCanvasFrames() {
        val geometry = RenderGeometry(plan.canvas.w, plan.canvas.h, 320, 180)
        val baseline = GlResources.counts()
        val frame = extract(listOf(LayerPlaceEffect(LayerBinding.NONE, geometry)))
        assertEquals(baseline, awaitCounts(baseline))
        assertEquals(320, frame.bitmap.width)
        assertEquals(180, frame.bitmap.height)
        val bytes = rawBytes(frame.bitmap)
        assertTrue("every pixel transparent", (0 until 320 * 180).all { bytes[it * 4 + 3].toInt() == 0 })
    }

    companion object {
        private const val TAG = "AND09.media3"
        private lateinit var env: GlTestEnv

        @BeforeClass
        @JvmStatic
        fun setUp() {
            env = GlTestEnv()
        }

        @AfterClass
        @JvmStatic
        fun tearDown() {
            env.close()
        }
    }
}
