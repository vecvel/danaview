// OWNER: AND-16 (QA-05 D10)
//
// D10 regression tests: an exact seek through the contingency backend acks only the frame that is
// on screen, and that frame is the target. QA-05 run b acked exact seeks with the frame shown
// before the seek (#121: 58 for 664, #155/#162: 249 for 72/335). The tests drive a PreviewSession
// on AND-16's backend over the fake SurfaceProducer (ENG-05's 720p24 counter, main shows source
// frame offset + k at output frame k) with seek storms where something else reaches the session
// while the seek is in flight, in the same order the editor sends it: a param patch, a structural
// patch (a new map: the decks re-plan and the expected barcode changes), a refresh, a quality step
// (the Surface is replaced) and nothing. The second test runs the storm again after cancelled
// reverse and freeze jobs and an export suspension (what a cancelled export does to the preview).
// For every seek: the ack is the exact target, debugCaptureFrame shows its barcode, and the last
// frame the producer received shows it too, also a while after the ack. Emulator numbers (AND16).

package com.vecvel.danaview.editor.engine.fallback

import android.util.Log
import com.vecvel.danaview.editor.engine.effects.EffectFixtures
import com.vecvel.danaview.editor.engine.harness.FixtureTree
import com.vecvel.danaview.editor.engine.harness.TestFixtures
import com.vecvel.danaview.editor.engine.media.ExactFrames
import com.vecvel.danaview.editor.engine.paused.PausedPlans
import com.vecvel.danaview.editor.engine.paused.await
import com.vecvel.danaview.editor.engine.pigeon.DeviceTierMsg
import com.vecvel.danaview.editor.engine.pigeon.JobKindMsg
import com.vecvel.danaview.editor.engine.pigeon.JobPriorityMsg
import com.vecvel.danaview.editor.engine.pigeon.JobRequestMsg
import com.vecvel.danaview.editor.engine.pigeon.PreviewQualityMsg
import com.vecvel.danaview.editor.engine.pigeon.ResolvedMediaMsg
import com.vecvel.danaview.editor.engine.pigeon.SeekAckMsg
import com.vecvel.danaview.editor.engine.plan.PlanLayer
import com.vecvel.danaview.editor.engine.plan.PlanWriter
import com.vecvel.danaview.editor.engine.preview.PreviewHarness
import com.vecvel.danaview.editor.engine.preview.PreviewPlans
import com.vecvel.danaview.editor.engine.preview.fallback.ContingencyPreviewBackend
import com.vecvel.danaview.editor.engine.support.FrameBarcode
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import kotlin.random.Random

class SeekAckOnScreenTest {
    private enum class During { NOTHING, PARAM_PATCH, STRUCTURAL_PATCH, REFRESH, QUALITY_STEP }

    private fun harness(name: String): PreviewHarness {
        val config = ContingencyPreviewBackend.Config(liveBudget = 6, effectAssets = EffectFixtures.assets, codecSelector = ExactFrames.softwareFirst)
        return PreviewHarness(name, backend = { ContingencyPreviewBackend(config) }).apply { open(PreviewQualityMsg.FULL) }
    }

    /** The session state the storm keeps in step with the engine. */
    private class Storm(val h: PreviewHarness) {
        var rev = 1L
        var offset = PreviewPlans.SOURCE_OFFSET
        var boxX = 120.0
        var quality = PreviewQualityMsg.FULL
        val problems = ArrayList<String>()
        val latencies = ArrayList<Double>()
        var seeks = 0

        fun main(offset: Long): PlanLayer = PausedPlans.media("main#v", 10, 0, 0, PreviewPlans.FRAMES, offset)

        fun start() {
            h.setPlan(PreviewPlans.plan(listOf(main(offset), PreviewPlans.box(cx = boxX)), rev = rev))
            h.producer.awaitFrame(0)
        }

        /** Posts the seek and then [during] on danaview-preview, in this order, and waits for the ack. */
        fun seek(k: Long, during: During): SeekAckMsg {
            val before = h.producer.frameCount
            val t0 = System.nanoTime()
            var expectOffset = offset
            val ack = await<SeekAckMsg>(60) { cb ->
                h.onPreview {
                    val s = h.session
                    s.seek(PreviewPlans.grid.timeOfFrame(k), true, cb)
                    when (during) {
                        During.NOTHING -> Unit
                        During.PARAM_PATCH -> {
                            boxX = if (boxX < 300) 500.0 else 120.0
                            s.applyPatch(PlanWriter.patchJson(PreviewPlans.upsert(rev, PreviewPlans.box(cx = boxX))).toByteArray()) { }
                            rev++
                        }
                        During.STRUCTURAL_PATCH -> {
                            offset = if (offset == PreviewPlans.SOURCE_OFFSET) 40L else PreviewPlans.SOURCE_OFFSET
                            expectOffset = offset
                            s.applyPatch(PlanWriter.patchJson(PreviewPlans.upsert(rev, main(offset))).toByteArray()) { }
                            rev++
                        }
                        During.REFRESH -> s.refresh { }
                        During.QUALITY_STEP -> {
                            quality = if (quality == PreviewQualityMsg.FULL) PreviewQualityMsg.HALF else PreviewQualityMsg.FULL
                            s.setQuality(quality) { }
                        }
                    }
                }
            }
            latencies += (System.nanoTime() - t0) / 1e6
            seeks++
            val want = (expectOffset + k).toInt()
            val what = "seek $seeks to $k with $during"
            if (ack.displayedFrame != k) problems += "$what: acked frame ${ack.displayedFrame}"
            val captured = decode16x9(h.capture())
            if (captured != want) problems += "$what: debugCaptureFrame shows ${captured} (want $want)"
            // The producer: a frame newer than the seek shows the target, and nothing stale follows.
            val deadline = System.currentTimeMillis() + 3_000
            var shown: Int? = null
            while (System.currentTimeMillis() < deadline) {
                val f = h.producer.last()
                if (f != null && f.index > before) {
                    shown = FrameBarcode.decode(f.rgba, f.width, f.height)
                    if (shown == want) break
                }
                Thread.sleep(5)
            }
            if (shown != want) problems += "$what: the producer shows $shown (want $want)"
            Thread.sleep(150)
            val after = h.producer.last()?.let { FrameBarcode.decode(it.rgba, it.width, it.height) }
            if (after != want) problems += "$what: 150 ms later the producer shows $after (want $want)"
            return ack
        }

        fun run(rounds: Int, rnd: Random) {
            val kinds = During.entries
            repeat(rounds) { i ->
                val k = rnd.nextLong(0, PreviewPlans.FRAMES)
                seek(k, kinds[i % kinds.size])
            }
        }
    }

    private companion object {
        /** The barcode of a 16:9 RGBA capture (its size follows the quality level the frame was composed at). */
        fun decode16x9(rgba: ByteArray): Int? {
            val pixels = rgba.size / 4
            val w = Math.round(Math.sqrt(pixels * 16.0 / 9.0)).toInt()
            val h = if (w > 0) pixels / w else 0
            if (w <= 0 || w * h * 4 != rgba.size) return null
            return FrameBarcode.decode(rgba, w, h)
        }
    }

    private fun media(name: String) = TestFixtures.copyToCache(FixtureTree.ENGINE, "media/$name")

    private fun startAndCancel(h: PreviewHarness, request: JobRequestMsg, afterMs: Long) {
        val id = h.engine.start(request)
        Thread.sleep(afterMs)
        h.ctx.jobs.cancel(id)
        h.engine.awaitTerminal(id)
    }

    @Test
    fun exactSeeksAckTheFrameOnScreenWhileEditsAndQualityStepsArrive() {
        harness("d10_storm").use { h ->
            val storm = Storm(h)
            storm.start()
            storm.run(40, Random(5150))
            Log.i(AND16_TAG, "D10 storm (emulator): ${storm.seeks} seeks, ${Timings(storm.latencies)}; problems ${storm.problems.size}")
            assertEquals("seeks that acked or showed another frame:\n" + storm.problems.joinToString("\n"), emptyList<String>(), storm.problems)
        }
    }

    @Test
    fun exactSeeksAckTheFrameOnScreenAfterCancelledJobs() {
        harness("d10_jobs").use { h ->
            h.manager.suspendTiers = DeviceTierMsg.entries.toSet()
            val storm = Storm(h)
            storm.start()
            storm.run(10, Random(121))
            repeat(2) { cycle ->
                startAndCancel(
                    h,
                    JobRequestMsg(
                        kind = JobKindMsg.REVERSE,
                        media = ResolvedMediaMsg(uri = media("frame_counter_1080p30.mp4").absolutePath, fingerprint = "fp-d10-rev", isProxy = false),
                        priority = JobPriorityMsg.INTERACTIVE,
                        sourceStartUs = 0,
                        sourceEndUs = 6_000_000,
                        outputPath = File(h.engine.paths.derived, "d10_rev_$cycle.mp4").absolutePath,
                    ),
                    afterMs = 400L + 300L * cycle,
                )
                startAndCancel(
                    h,
                    JobRequestMsg(
                        kind = JobKindMsg.FREEZE,
                        media = ResolvedMediaMsg(uri = media("frame_counter_1080p30.mp4").absolutePath, fingerprint = "fp-d10-freeze", isProxy = false),
                        priority = JobPriorityMsg.INTERACTIVE,
                        sourceTimeUs = 1_000_000L + cycle * 100_000L,
                        outputPath = h.engine.still("d10_$cycle").absolutePath,
                    ),
                    afterMs = 20L,
                )
                // A cancelled export: the preview is suspended (decoders released) and resumed.
                h.manager.suspendForExport("d10_export_$cycle")
                h.waitUntil("suspended") { h.sync { h.session.isSuspended } }
                h.manager.resumeAfterExport("d10_export_$cycle")
                h.waitUntil("resumed") { h.sync { !h.session.isSuspended } }
                storm.run(15, Random(155L + cycle))
            }
            Log.i(AND16_TAG, "D10 after cancelled jobs (emulator): ${storm.seeks} seeks, ${Timings(storm.latencies)}; problems ${storm.problems.size}")
            assertTrue("seeks: ${storm.seeks}", storm.seeks >= 40)
            assertEquals("seeks that acked or showed another frame:\n" + storm.problems.joinToString("\n"), emptyList<String>(), storm.problems)
        }
    }
}
