// OWNER: AND-06 (held source frames: android-r9, Windows verification)

// An export whose layer runs past its source end holds the last source frame (CompositionMapper
// split + SourceFrameStills, ARCH §11.5), through the production ExportCoordinator. Two exports of
// clap_flash_av (180 frames, 6 s) from source frame 60 at 30 fps: "held" runs 180 output frames
// (the source ends at k = 120, k 120..179 hold frame 179), "exact" is the control that ends at the
// source end (120 frames, no held part). Checked:
// - no hang: both exports finish (the still is extracted on the export looper);
// - frames: the held part shows frame 179 at every k, and the played part of "held" shows exactly
//   what the control shows (the split leaves it untouched; before android-r9 SpeedFit stretched it,
//   176/180 frames off);
// - colour: the held frames (an image item of the extracted still) match the last decoded frame
//   (the same source frame through the video decoder) in mean R, G and B within 3 levels;
// - audio: the click offsets of "held" equal the control's (within 1 ms), the tail past the source
//   end is silent, and the AAC track ends with the video.
// Open, not asserted here (the control shows them too, so they predate android-r9; Windows emulator
// 2026-10-30): from source frame 60 the export shows k=1 -> 60 and k=9 -> 70 (want 61, 69), and
// the clicks land 55.5-55.7 ms after their flash frames (avOffsetWithinOneFrameAnd20ms, which starts
// at source 0, stays within 20 ms). Both are logged under DanaviewExportTest.
// Numbers logged (tag DanaviewExportTest) are EMULATOR numbers.

package com.vecvel.danaview.editor.engine.export

import android.graphics.Bitmap
import android.media.MediaMetadataRetriever
import android.util.Log
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.vecvel.danaview.editor.engine.plan.AudioSeg
import com.vecvel.danaview.editor.engine.plan.FrameGrid
import com.vecvel.danaview.editor.engine.plan.Keyframes
import com.vecvel.danaview.editor.engine.plan.MapSegment
import com.vecvel.danaview.editor.engine.plan.PlanAsset
import com.vecvel.danaview.editor.engine.plan.PlanAssetKind
import com.vecvel.danaview.editor.engine.plan.PlanCanvas
import com.vecvel.danaview.editor.engine.plan.PlanTarget
import com.vecvel.danaview.editor.engine.plan.PlanValidator
import com.vecvel.danaview.editor.engine.plan.RenderPlan
import com.vecvel.danaview.editor.engine.support.FrameBarcode
import com.vecvel.danaview.editor.engine.support.decode
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import kotlin.math.abs

@RunWith(AndroidJUnit4::class)
class ExportHeldSourceFrameTest {
    private val harnesses = ArrayList<ExportHarness>()

    @After
    fun tearDown() {
        harnesses.forEach { it.close() }
    }

    private val g = FrameGrid.of(30)

    /** The output frame where the source ends (source frame 60 + k = 180). */
    private val sourceEndK = 120

    /** What one export shows: barcode per k, mean RGB per k, click offsets, the tail onset. */
    private class Seen(val barcodes: List<Int?>, val rgb: List<DoubleArray>, val offsets: List<Long>, val tailOnsetUs: Long?)

    /** Mean R, G, B of [b] below the barcode band. */
    private fun meanRgb(b: Bitmap): DoubleArray {
        val top = FrameBarcode.bandHeight(b.height)
        val px = IntArray(b.width * (b.height - top))
        b.getPixels(px, 0, b.width, 0, top, b.width, b.height - top)
        val s = DoubleArray(3)
        for (c in px) {
            s[0] += (c shr 16 and 0xFF).toDouble()
            s[1] += (c shr 8 and 0xFF).toDouble()
            s[2] += (c and 0xFF).toDouble()
        }
        return DoubleArray(3) { s[it] / px.size }
    }

    /** Exports clap_flash_av from source frame 60 for [frames] output frames, video and audio. */
    private fun export(frames: Long, name: String): Seen {
        val h = ExportHarness("held_export_$name").also { harnesses += it }
        val dur = g.timeOfFrame(frames)
        val s0 = 2_000_000L // source frame 60
        val plan = RenderPlan(
            rev = 1, target = PlanTarget.EXPORT, canvas = PlanCanvas(1280, 720, 30), durUs = dur,
            assets = mapOf("md_clap" to PlanAsset(PlanAssetKind.VIDEO, ExportPlans.media("clap_flash_av.mp4"), fp = "clap", w = 1280, h = 720, durUs = 6_000_000, hasAudio = true)),
            layers = listOf(ExportPlans.mediaLayer("it_clap#v", 10, 0, g, 0, frames, 60, 30, asset = "md_clap")),
            audio = listOf(AudioSeg(id = "it_clap#a", asset = "md_clap", t0 = 0, t1 = dur, map = listOf(MapSegment(0, dur, s0, s0 + dur)), gain = Keyframes.of(0L to 1.0))),
        )
        assertEquals(emptyList<Any>(), PlanValidator.validate(plan))
        val o = h.export(plan, settings(), name)
        val out = File(o.requireResult().path)
        h.app.getExternalFilesDir(null)?.let { dir -> out.copyTo(File(dir, "and06_held_export_$name.mp4"), overwrite = true) }

        val pts = ExportedFile.videoPts(out)
        assertEquals("$name frame count", frames.toInt(), pts.size)
        val barcodes = ArrayList<Int?>()
        val rgb = ArrayList<DoubleArray>()
        val r = MediaMetadataRetriever()
        try {
            r.setDataSource(out.absolutePath)
            var i = 0
            while (i < frames) {
                val n = minOf(10, frames.toInt() - i)
                for (b in r.getFramesAtIndex(i, n)) {
                    barcodes += FrameBarcode.decode(b)
                    rgb += meanRgb(b)
                    b.recycle()
                }
                i += n
            }
        } finally {
            r.release()
        }

        // Clicks at source 2.5 s and 4 s land on plan 0.5 s and 2.0 s (flash frames 15, 60).
        val luma = ExportedFile.meanLuma(out, pts.size)
        val flashes = luma.indices.filter { luma[it] > 180 }
        assertEquals("$name flash frames", listOf(15, 60), flashes)
        val pcm = ExportedFile.decodeAudio(h.ctx, out)
        val offsets = flashes.map { k ->
            val audio = pcm.onsetUs(pts[k] - 200_000)
            assertNotNull("$name click near frame $k", audio)
            audio!! - pts[k]
        }
        val tail = if (frames > sourceEndK) pcm.onsetUs(g.timeOfFrame(sourceEndK.toLong()) - 20_000, threshold = 0.01f) else null
        ExportedFile.assertAudioSpansVideo(out, 30, name)
        val off = barcodes.withIndex().filter { (k, v) -> v != minOf(60 + k, 179) }.map { (k, v) -> "k=$k want=${minOf(60 + k, 179)} got=$v" }
        Log.i(EXPORT_TEST_TAG, "$name: export ${o.wallMs} ms; frames off the rule ${off.size}/$frames ${off.take(8)}; A/V offsets $offsets us; decoded ${pcm.durationUs} us of audio for $dur us; onset past the source end: $tail (emulator)")
        return Seen(barcodes, rgb, offsets, tail)
    }

    @Test
    fun aLayerPastItsSourceEndHoldsTheLastFrameWithSilentAudioInSync() {
        val exact = export(sourceEndK.toLong(), "exact")
        val held = export(180L, "held")

        // Frames: the played part as the control, then the last frame held.
        assertEquals("the played part shows what the exact-end control shows", exact.barcodes, held.barcodes.take(sourceEndK))
        val notHeld = (sourceEndK until 180).filter { held.barcodes[it] != 179 }
        assertEquals("every frame past the source end holds frame 179", emptyList<Int>(), notHeld)

        // Colour: the still against the decoded last frame.
        val last = held.rgb[sourceEndK - 1]
        val maxDiff = (sourceEndK until 180).maxOf { k -> (0 until 3).maxOf { abs(held.rgb[k][it] - last[it]) } }
        Log.i(EXPORT_TEST_TAG, "held: last decoded frame mean RGB ${last.joinToString { "%.2f".format(it) }}; held frames max mean-channel difference %.2f (emulator)".format(maxDiff))
        assertTrue("held frames match the last decoded frame's colour (max mean-channel difference $maxDiff)", maxDiff <= 3.0)

        // Audio: the same sync as the control, silence past the source end.
        assertEquals("click count", exact.offsets.size, held.offsets.size)
        for ((a, b) in exact.offsets.zip(held.offsets)) assertTrue("click offset $b us vs the control's $a us", abs(a - b) <= 1_000)
        assertNull("the audio tail past the source end is silent", held.tailOnsetUs)
    }
}
