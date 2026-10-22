@file:OptIn(UnstableApi::class)
// OWNER: AND-08 (QA-05 D8, Android half)
//
// Purged generated images on the emulator (QA-05 D8: installd deleted `engine/dv_*.png` under a
// running export and the image asset loader failed with ENOENT):
// - GeneratedImageBitmapLoader writes a missing image again and decodes it (same size and pixels);
//   when it cannot be written (the directory cannot be created), it answers the pixels from memory.
// - A mapped composition (clock band, a top slot with transparent gaps before and after its layer)
//   whose generated images are deleted after the build, and deleted again every 20 ms while the
//   export runs, fails through Transformer's default image loading with the D8 chain (the control;
//   StorageLoss classifies that real chain as io, or diskFull on a low volume) and exports every
//   frame exactly through GeneratedImageAssetLoaderFactory.

package com.vecvel.danaview.editor.engine.composition

import android.graphics.Bitmap
import android.net.Uri
import android.util.Log
import androidx.annotation.OptIn
import androidx.media3.common.util.UnstableApi
import androidx.media3.transformer.ExportException
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.vecvel.danaview.editor.engine.core.EngineErrorCode
import com.vecvel.danaview.editor.engine.export.StorageLoss
import com.vecvel.danaview.editor.engine.harness.FixtureTree
import com.vecvel.danaview.editor.engine.harness.TestFixtures
import com.vecvel.danaview.editor.engine.plan.FrameGrid
import com.vecvel.danaview.editor.engine.plan.MapSegment
import com.vecvel.danaview.editor.engine.plan.ParamSnapshot
import com.vecvel.danaview.editor.engine.plan.PlanAsset
import com.vecvel.danaview.editor.engine.plan.PlanAssetKind
import com.vecvel.danaview.editor.engine.plan.PlanCanvas
import com.vecvel.danaview.editor.engine.plan.PlanLayer
import com.vecvel.danaview.editor.engine.plan.PlanLayerKind
import com.vecvel.danaview.editor.engine.plan.PlanSize
import com.vecvel.danaview.editor.engine.plan.PlanTarget
import com.vecvel.danaview.editor.engine.plan.PlanValidator
import com.vecvel.danaview.editor.engine.plan.RenderPlan
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference

@RunWith(AndroidJUnit4::class)
class GeneratedImagesInstrumentedTest {
    private val ctx = TestFixtures.targetContext
    private val root = File(ctx.cacheDir, "d8_generated")
    private val dir = File(root, "engine")
    private val outDir = File(root, "exports")

    @After
    fun cleanUp() {
        root.deleteRecursively()
    }

    private fun load(images: PngCompositionImages, uri: String): Bitmap =
        GeneratedImageBitmapLoader(images, GeneratedImageAssetLoaderFactory.defaultBitmapLoader(ctx)).loadBitmap(Uri.parse(uri)).get(30, TimeUnit.SECONDS)

    @Test
    fun aMissingImageIsWrittenAgainAndDecoded() {
        val images = PngCompositionImages(dir)
        val teal = 0xFF00897B.toInt()
        val uri = images.opaque(teal, 64, 36)
        val file = File(Uri.parse(uri).path!!)
        assertTrue(file.isFile)
        val before = load(images, uri)
        assertTrue(dir.deleteRecursively())
        val after = load(images, uri)
        assertTrue("written again", file.isFile)
        for (b in listOf(before, after)) {
            assertEquals(64, b.width)
            assertEquals(36, b.height)
            assertEquals(teal, b.getPixel(0, 0))
            assertEquals(teal, b.getPixel(63, 35))
        }
        val clear = images.transparent(2, 2)
        assertTrue(dir.deleteRecursively())
        assertEquals(0, load(images, clear).getPixel(1, 1))
    }

    @Test
    fun anImageThatCannotBeWrittenComesFromMemory() {
        val images = PngCompositionImages(dir)
        val uri = images.opaque(0xFFFFFFFF.toInt(), 16, 16)
        assertTrue(dir.deleteRecursively())
        // A regular file where the directory should be: mkdirs fails, as on a full or vanished volume.
        assertTrue(dir.createNewFile())
        val b = load(images, uri)
        assertEquals(16, b.width)
        assertEquals(0xFFFFFFFF.toInt(), b.getPixel(8, 8))
        assertFalse(File(Uri.parse(uri).path!!).exists())
    }

    /** A 2 s 30 fps plan: main slot [0, n) from source frame 0; top slot [c1, c2) from frame 140. */
    private fun plan(): RenderPlan {
        val g = FrameGrid.of(FPS)
        fun layer(id: String, z: Int, seq: Int, k0: Long, k1: Long, sourceFrame: Long): PlanLayer {
            val t0 = g.timeOfFrame(k0)
            val t1 = g.timeOfFrame(k1)
            val s0 = Math.floorDiv(sourceFrame * 1_000_000L, FPS.toLong())
            return PlanLayer(
                id = id, z = z, seq = seq, t0 = t0, t1 = t1, kind = PlanLayerKind.MEDIA, asset = "md_src",
                map = listOf(MapSegment(t0, t1, s0, s0 + (t1 - t0))), base = PlanSize(1280.0, 720.0),
            )
        }
        val layers = listOf(layer("it_a#v", 10, 0, 0, N, 0), layer("it_d#v", 10010, 1, C1, C2, 140)).sortedWith(PlanValidator::compareLayers)
        val src = "file://" + TestFixtures.copyToCache(FixtureTree.ENGINE, "media/clap_flash_av.mp4").absolutePath
        val p = RenderPlan(
            rev = 1, target = PlanTarget.EXPORT, canvas = PlanCanvas(1280, 720, FPS), durUs = g.timeOfFrame(N),
            assets = mapOf("md_src" to PlanAsset(PlanAssetKind.VIDEO, src, fp = "src", w = 1280, h = 720)),
            layers = layers, audio = emptyList(),
        )
        assertEquals(emptyList<Any>(), PlanValidator.validate(p))
        return p
    }

    private fun build(images: PngCompositionImages): Media3Composition.Built {
        val p = plan()
        val spec = ExtractorSourceTimeline(ctx).use { CompositionMapper(it).map(p) }
        return Media3Composition.build(spec, images, EffectChainFactory.NONE, AtomicReference(ParamSnapshot.of(p)))
    }

    /** Runs [block] while a thread deletes [dir] every 20 ms (installd purging the cache). */
    private fun <T> whilePurging(block: () -> T): Pair<T, Int> {
        val stop = AtomicBoolean(false)
        var purges = 0
        val purger = Thread {
            while (!stop.get()) {
                if (dir.exists() && dir.deleteRecursively()) purges++
                Thread.sleep(20)
            }
        }.apply { start() }
        try {
            return block() to purges
        } finally {
            stop.set(true)
            purger.join()
        }
    }

    @Test
    fun purgedGeneratedImagesFailTheDefaultLoaderAndNotOurs() {
        val images = PngCompositionImages(dir)
        val generated = { dir.listFiles().orEmpty().filter { Generated.parse(it.name) != null }.map { it.name }.sorted() }

        // Control: Transformer's own image loading after the purge (the D8 failure).
        val control = build(images)
        val names = generated()
        assertTrue("the composition references generated images: $names", names.any { it.startsWith("dv_transparent_") })
        assertTrue(dir.deleteRecursively())
        val failure = try {
            ExportRunner.export(control.composition, File(outDir, "control.mp4"))
            null
        } catch (e: ExportRunner.Failed) {
            e.exception
        }
        assertNotNull("the default loader cannot open a purged image", failure)
        assertEquals(ExportException.ERROR_CODE_IO_UNSPECIFIED, failure!!.errorCode)
        // The real chain names the purged file below the cache root: a storage failure, never unknown.
        assertTrue(StorageLoss.lostBelow(failure, ctx.cacheDir))
        assertEquals(EngineErrorCode.io, StorageLoss.classify(failure, ctx.cacheDir) { false }!!.code)
        assertEquals(EngineErrorCode.diskFull, StorageLoss.classify(failure, ctx.cacheDir) { true }!!.code)

        // Fixed: the same images purged after the build and again every 20 ms during the export.
        val built = build(images)
        assertTrue(dir.deleteRecursively())
        val out = File(outDir, "fixed.mp4")
        val (_, purges) = whilePurging {
            ExportRunner.exportWith(built.composition, out) {
                it.setAssetLoaderFactory(GeneratedImageAssetLoaderFactory(ctx, images, ExportRunner.softwareFirstAssetLoader()))
            }
        }
        val pts = OutputReader.videoPts(out)
        assertEquals("frame count", N.toInt(), pts.size)
        val codes = OutputReader.barcodes(out, N.toInt())
        val expected = (0 until N.toInt()).map { k -> if (k >= C1 && k < C2) 140 + (k - C1).toInt() else k }
        val wrong = (0 until N.toInt()).filter { codes[it] != expected[it] }
        assertEquals("frames whose barcode is not the plan's (transparent gaps must show the main slot)", emptyList<Int>(), wrong)
        Log.i(TAG, "purged generated images: control ${failure.errorCodeName}; fixed export exact over $N frames with $purges purges during the run (emulator)")
        if (purges == 0) fail("the purger never ran during the export")
    }

    private companion object {
        const val TAG = "D8Generated"
        const val FPS = 30
        const val N = 60L
        const val C1 = 21L
        const val C2 = 41L
    }
}
