// OWNER: AND-07
//
// JVM tests of AND-07's pure parts (ARCH §15 'Reverse', 'Reverse preflight'):
// - the mirrored timeline: output PTS = rangeEnd - frameEnd, every frame keeps its duration (CFR,
//   VFR, partial ranges that cut a frame), the last source frame comes first at 0;
// - the chunk plan: chunks from the END of the range, covering every frame exactly once, GOP-aligned
//   (a chunk starts at a sync frame whenever one keeps it under 2 x target), and the intermediate's
//   clip end pushed past samples that precede a needed frame in decode order (B-frames);
// - the preflight: 10 min cap (message token `reverseRange`) and free space >= 2 x output + one
//   chunk + 64 MB (`diskFull`);
// - audio: contiguous per-chunk frame spans that mirror the source, frame reversal, resampling,
//   AAC-LC AudioSpecificConfig vectors, the encoder-priming offset of the muxed AAC times;
// - which intermediate sample stands for which chunk frame (relative or absolute times, the clip
//   extension's extra frames, a lost frame).

package com.vecvel.danaview.editor.engine.reverse

import com.vecvel.danaview.editor.engine.core.EngineErrorCode
import com.vecvel.danaview.editor.engine.core.EngineException
import com.vecvel.danaview.editor.engine.media.AudioPlan
import com.vecvel.danaview.editor.engine.media.IntermediateMapping
import com.vecvel.danaview.editor.engine.media.ReverseMath
import com.vecvel.danaview.editor.engine.media.ReverseTimeline
import com.vecvel.danaview.editor.engine.media.ReverseWav
import com.vecvel.danaview.editor.engine.media.YuvCopy
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.nio.ByteBuffer
import java.nio.ByteOrder

class ReversePlanTest {
    /** P(k) = round(k * 1e6 / fps). */
    private fun p(k: Int, fps: Int): Long = Math.floorDiv(2L * k * 1_000_000L + fps, 2L * fps)

    /** A CFR source without B-frames: decode order = presentation order, a sync every [gop] frames. */
    private fun cfr(frames: Int, fps: Int, gop: Int, start: Long, end: Long): ReverseTimeline =
        ReverseTimeline(
            LongArray(frames) { p(it, fps) },
            BooleanArray(frames) { it % gop == 0 },
            p(frames, fps),
            start,
            end,
        )

    /**
     * A CFR source with B-frames: each GOP of [gop] frames (closed) is coded I0 P3 B1 B2 P6 B4 B5 ...
     * (a P every third frame, two B-frames before it in presentation order).
     */
    private fun bFrames(frames: Int, fps: Int, gop: Int, start: Long, end: Long): ReverseTimeline {
        val order = ArrayList<Int>()
        var g = 0
        while (g < frames) {
            val last = minOf(frames, g + gop) - 1
            order += g
            var anchor = g
            while (anchor < last) {
                val next = minOf(anchor + 3, last)
                order += next
                for (b in anchor + 1 until next) order += b
                anchor = next
            }
            g += gop
        }
        return ReverseTimeline(
            LongArray(order.size) { p(order[it], fps) },
            BooleanArray(order.size) { order[it] % gop == 0 },
            p(frames, fps),
            start,
            end,
        )
    }

    @Test
    fun mirroredTimelinePutsTheLastFrameFirstAndKeepsEveryDuration() {
        val t = cfr(240, 30, 30, 0, 8_000_000)
        assertEquals(240, t.frames.size)
        assertEquals(8_000_000, t.durationUs)
        assertEquals("the last source frame is output frame 0", 0L, t.frames[239].outPtsUs)
        assertEquals(8_000_000 - p(1, 30), t.frames[0].outPtsUs)
        for (i in t.frames.indices) {
            val f = t.frames[i]
            assertEquals(8_000_000 - f.endUs, f.outPtsUs)
            if (i + 1 < t.frames.size) {
                // Output order: frame i+1 is shown right before frame i, for exactly its own duration.
                assertEquals(t.frames[i + 1].endUs - t.frames[i + 1].ptsUs, f.outPtsUs - t.frames[i + 1].outPtsUs)
            }
        }
    }

    @Test
    fun partialRangesCutTheStraddlingFramesAtTheRange() {
        // 24 fps, [1.51 s, 4.25 s): frame 36 (1.5 s) straddles the start, frame 101 ends at P(102) = 4.25 s.
        val t = cfr(192, 24, 24, 1_510_000, 4_250_000)
        assertEquals(36, (t.frames.first().ptsUs * 24 / 1_000_000).toInt())
        assertEquals(p(36, 24), t.frames.first().ptsUs)
        assertEquals(p(101, 24), t.frames.last().ptsUs)
        assertEquals(0L, t.frames.last().outPtsUs)
        assertEquals(66, t.frames.size)
        // The straddling first frame is shown for the part inside the range, up to the output end.
        assertEquals(t.durationUs - t.frames.first().outPtsUs, t.frames.first().endUs - 1_510_000)
        // A range ending inside a frame: that frame's output duration is the covered part.
        val u = cfr(192, 24, 24, 0, 1_010_000)
        assertEquals(p(24, 24), u.frames.last().ptsUs)
        assertEquals(1_010_000, u.frames.last().endUs)
        assertEquals(0L, u.frames.last().outPtsUs)
    }

    @Test
    fun vfrDurationsAreMirrored() {
        // ENG-05's vfr_720p cycle (600 ticks/s): 20, 20, 40, 25, 10, 30, 20, 20 ticks.
        val cycle = intArrayOf(20, 20, 40, 25, 10, 30, 20, 20)
        val ticks = LongArray(41)
        for (i in 1 until ticks.size) ticks[i] = ticks[i - 1] + cycle[(i - 1) % cycle.size]
        val pts = LongArray(40) { ticks[it] * 1_000_000 / 600 }
        val end = ticks[40] * 1_000_000 / 600
        val t = ReverseTimeline(pts, BooleanArray(40) { it % 10 == 0 }, end, 0, end)
        assertEquals(40, t.frames.size)
        for (i in 0 until 39) {
            val sourceDuration = t.frames[i].endUs - t.frames[i].ptsUs
            val outputDuration = (if (i == 0) t.durationUs else t.frames[i - 1].outPtsUs) - t.frames[i].outPtsUs
            assertEquals("frame $i keeps its duration", sourceDuration, outputDuration)
        }
    }

    @Test
    fun chunksComeFromTheEndAlignedToSyncFramesAndCoverEveryFrameOnce() {
        val t = cfr(240, 30, 30, 0, 8_000_000)
        val chunks = t.chunks(2_000_000)
        assertEquals(4, chunks.size)
        assertEquals("first chunk = the end of the range", 239, chunks.first().last)
        assertEquals(180, chunks.first().first)
        assertEquals(0, chunks.last().first)
        var expectedLast = 239
        var outStart = 0L
        for (c in chunks) {
            assertEquals(expectedLast, c.last)
            assertTrue("GOP-aligned start", t.frames[c.first].sync)
            assertEquals(t.frames[c.first].ptsUs, c.clipStartUs)
            assertEquals(outStart, c.outStartUs)
            assertTrue(c.outEndUs > c.outStartUs)
            outStart = c.outEndUs
            expectedLast = c.first - 1
        }
        assertEquals(-1, expectedLast)
        assertEquals(t.durationUs, chunks.last().outEndUs)
        // Without B-frames the clip ends right at the next chunk's first frame.
        assertEquals(t.frames[180].ptsUs, chunks[1].clipEndUs)
        assertEquals(t.frames[239].ptsUs + 1, chunks[0].clipEndUs)
    }

    @Test
    fun chunksWithoutNearbySyncFramesStayNearTheTarget() {
        // One sync frame only (a 10 s GOP): chunks are ~2 s, decoded from the previous sync.
        val t = cfr(300, 30, 10_000, 0, 10_000_000)
        val chunks = t.chunks(2_000_000)
        assertEquals(4, chunks.size)
        for (c in chunks.dropLast(1)) assertEquals(60, c.frameCount)
        // The sync frame 0 is within 2 x target of the last chunk's end: that chunk snaps to it.
        assertEquals(0, chunks.last().first)
        assertEquals(120, chunks.last().frameCount)
    }

    @Test
    fun syncAlignmentNeverMakesAChunkLongerThanTwiceTheTarget() {
        val t = cfr(600, 30, 45, 0, 20_000_000) // a sync every 1.5 s
        for (target in longArrayOf(500_000, 1_000_000, 2_000_000, 3_000_000)) {
            val chunks = t.chunks(target)
            var covered = 0
            for (c in chunks) {
                covered += c.frameCount
                val span = t.frames[c.last].endUs - t.frames[c.first].ptsUs
                assertTrue("chunk of $span µs for target $target", span <= 2 * target + 34_000)
            }
            assertEquals(600, covered)
        }
    }

    @Test
    fun bFrameClipEndsCoverEveryNeededFrameInDecodeOrder() {
        val t = bFrames(120, 30, 12, 0, 4_000_000)
        assertEquals(120, t.frames.size)
        val chunks = t.chunks(100_000) // 3 frames: chunks end inside the 12-frame GOPs
        var covered = 0
        var extended = 0
        for (c in chunks) {
            covered += c.frameCount
            val endExclusive = if (c.last + 1 < t.frames.size) t.frames[c.last + 1].ptsUs else t.frames[c.last].ptsUs + 1
            assertTrue(c.clipEndUs >= endExclusive)
            // Every sample decoded before the chunk's last needed frame is inside the clip.
            var decodeStart = t.frames[c.first].decodeIndex
            while (decodeStart > 0 && !(t.decodeSync[decodeStart] && t.decodePts[decodeStart] <= c.clipStartUs)) decodeStart--
            val lastNeeded = (c.first..c.last).maxOf { t.frames[it].decodeIndex }
            for (d in decodeStart..lastNeeded) assertTrue(t.decodePts[d] < c.clipEndUs)
            if (c.clipEndUs > endExclusive) extended++
        }
        assertEquals(120, covered)
        assertTrue("some chunk end needed the decode-order extension", extended > 0)
        // GOP-aligned 0.4 s chunks of closed GOPs need no extension.
        for (c in t.chunks(400_000)) {
            val endExclusive = if (c.last + 1 < t.frames.size) t.frames[c.last + 1].ptsUs else t.frames[c.last].ptsUs + 1
            if (c.last + 1 < t.frames.size && t.frames[c.last + 1].sync) assertEquals(endExclusive, c.clipEndUs)
        }
    }

    @Test
    fun preflightRefusesLongRangesAndLowSpace() {
        ReverseMath.checkRange(ReverseMath.MAX_RANGE_US)
        try {
            ReverseMath.checkRange(ReverseMath.MAX_RANGE_US + 1)
            fail("a range over 10 min is refused")
        } catch (e: EngineException) {
            assertEquals(EngineErrorCode.unsupportedMedia, e.code)
            assertTrue(ReverseMath.isRangeLimit(e))
            assertTrue(e.message!!.contains("reverseRange"))
        }
        val needed = 2 * 100L + 50L + ReverseMath.SLACK_BYTES
        ReverseMath.preflight(1_000_000, 100, 50, needed)
        try {
            ReverseMath.preflight(1_000_000, 100, 50, needed - 1)
            fail("low space is refused")
        } catch (e: EngineException) {
            assertEquals(EngineErrorCode.diskFull, e.code)
            assertFalse(ReverseMath.isRangeLimit(e))
        }
        try {
            ReverseMath.preflight(ReverseMath.MAX_RANGE_US + 1, 0, 0, Long.MAX_VALUE)
            fail("the range cap comes first")
        } catch (e: EngineException) {
            assertTrue(ReverseMath.isRangeLimit(e))
        }
    }

    @Test
    fun bitRatesAndEstimatesFollowTheIosFormulas() {
        assertEquals(6_220_800, ReverseMath.outputBitRate(1920, 1080, 30.0))
        assertEquals(2_000_000, ReverseMath.outputBitRate(320, 240, 30.0))
        assertEquals(40_000_000, ReverseMath.outputBitRate(3840, 2160, 60.0))
        assertEquals(18_662_400, ReverseMath.intermediateBitRate(1920, 1080, 30.0))
        assertEquals(8_000_000, ReverseMath.intermediateBitRate(640, 360, 25.0))
        assertEquals(1_000_000, ReverseMath.bytes(8_000_000, 1_000_000))
        assertEquals(1920, ReverseMath.even(1921))
        assertEquals(2, ReverseMath.even(1))
    }

    @Test
    fun audioSpansAreContiguousAndMirrorTheSource() {
        val plan = AudioPlan.of(48_000, 1, 6_000_000)
        assertEquals(288_000, plan.totalFrames)
        val a = plan.span(0, 2_000_000, 6_000_000)
        val b = plan.span(2_000_000, 4_000_033, 6_000_000)
        val c = plan.span(4_000_033, 6_000_000, 6_000_000)
        assertEquals(0L, a.from)
        assertEquals(a.to, b.from)
        assertEquals(b.to, c.from)
        assertEquals(plan.totalFrames, c.to)
        // Output frames [0, 96000) are the LAST 2 s of the source range.
        assertEquals(Pair(1_000_000L + 4_000_000L, 1_000_000L + 6_000_000L), plan.sourceSpanUs(a, 1_000_000))
        assertEquals(Pair(1_000_000L, 1_000_000L + 1_999_958L), plan.sourceSpanUs(c, 1_000_000))
        // 44.1 kHz: µs times floor onto the exact frame times.
        val q = AudioPlan.of(44_100, 2, 1_000_000)
        assertEquals(44_100, q.totalFrames)
        assertEquals(2, q.outChannels)
        val s = q.span(0, 500_000, 1_000_000)
        assertEquals(22_050, s.frames)
        assertEquals(Pair(500_000L, 1_000_000L), q.sourceSpanUs(s, 0))
        // Unusual rates are resampled to 48 kHz; layouts other than stereo become mono.
        assertEquals(48_000, AudioPlan.of(96_000, 2, 1_000_000).outRate)
        assertEquals(1, AudioPlan.of(48_000, 6, 1_000_000).outChannels)
        assertEquals(1, AudioPlan.of(48_000, 1, 1_000_000).outChannels)
    }

    @Test
    fun framesReverseInPlace() {
        val stereo = shortArrayOf(1, 2, 3, 4, 5, 6)
        ReverseMath.reverseFrames(stereo, 2)
        assertArrayEquals(shortArrayOf(5, 6, 3, 4, 1, 2), stereo)
        val mono = shortArrayOf(1, 2, 3, 4)
        ReverseMath.reverseFrames(mono, 1)
        assertArrayEquals(shortArrayOf(4, 3, 2, 1), mono)
        val one = shortArrayOf(7)
        ReverseMath.reverseFrames(one, 1)
        assertArrayEquals(shortArrayOf(7), one)
    }

    @Test
    fun linearResamplingHitsTheFrameCountExactly() {
        val same = floatArrayOf(0f, 1f, 2f)
        assertArrayEquals(same, ReverseMath.resampleLinear(same, 1, 3), 0f)
        val up = ReverseMath.resampleLinear(floatArrayOf(0f, 1f), 1, 4)
        assertArrayEquals(floatArrayOf(0f, 0.5f, 1f, 1f), up, 1e-6f)
        val stereo = ReverseMath.resampleLinear(floatArrayOf(0f, 10f, 1f, 11f, 2f, 12f, 3f, 13f), 2, 2)
        assertArrayEquals(floatArrayOf(0f, 10f, 2f, 12f), stereo, 1e-6f)
        assertEquals(0, ReverseMath.resampleLinear(FloatArray(0), 2, 0).size)
        assertArrayEquals(FloatArray(6), ReverseMath.resampleLinear(FloatArray(0), 2, 3), 0f)
        assertArrayEquals(floatArrayOf(1f, 2f, 3f), ReverseMath.concat(listOf(floatArrayOf(1f), floatArrayOf(2f, 3f))), 0f)
    }

    @Test
    fun aacConfigAndPrimingOffsets() {
        assertArrayEquals(byteArrayOf(0x11, 0x90.toByte()), ReverseMath.aacLcConfig(48_000, 2))
        assertArrayEquals(byteArrayOf(0x12, 0x08), ReverseMath.aacLcConfig(44_100, 1))
        assertArrayEquals(byteArrayOf(0x14, 0x08), ReverseMath.aacLcConfig(16_000, 1))
        assertEquals(-1, ReverseMath.aacFrequencyIndex(50_000))
        for (rate in ReverseMath.ENCODER_RATES) assertTrue(ReverseMath.aacFrequencyIndex(rate) >= 0)
        // The platform FDK encoders' priming, measured (2048; Media3 assumes 1600).
        assertEquals(2048, ReverseMath.aacEncoderDelayFrames("c2.android.aac.encoder"))
        assertEquals(2048, ReverseMath.aacEncoderDelayFrames("OMX.google.aac.encoder"))
        assertEquals(0, ReverseMath.aacEncoderDelayFrames("c2.vendor.aac.encoder"))
        assertEquals(-33_333, ReverseMath.aacUnitPtsUs(0, 48_000, 1600))
        assertEquals(21_333 - 33_333, ReverseMath.aacUnitPtsUs(1, 48_000, 1600))
        assertEquals(21_333, ReverseMath.aacUnitPtsUs(1, 48_000, 0))
    }

    @Test
    fun intermediateSamplesMapToChunkFrames() {
        val chunk = longArrayOf(6_000_000, 6_033_333, 6_066_667)
        val relative = IntermediateMapping.of(longArrayOf(0, 33_300, 66_667, 100_000), chunk, 6_000_000)
        assertEquals(listOf<Long?>(0, 33_300, 66_667), relative.intermediatePts)
        val absolute = IntermediateMapping.of(longArrayOf(6_000_000, 6_033_333, 6_066_667), chunk, 6_000_000)
        assertEquals(listOf<Long?>(6_000_000, 6_033_333, 6_066_667), absolute.intermediatePts)
        val lost = IntermediateMapping.of(longArrayOf(0, 66_667), chunk, 6_000_000)
        assertNull(lost.intermediatePts[1])
        assertEquals(66_667L, lost.intermediatePts[2])
        assertEquals(listOf<Long?>(null, null, null), IntermediateMapping.of(LongArray(0), chunk, 6_000_000).intermediatePts)
    }

    @Test
    fun wavHeaderDescribesInterleavedS16() {
        val h = ByteBuffer.wrap(ReverseWav.header(44_100, 2, 1_000)).order(ByteOrder.LITTLE_ENDIAN)
        assertEquals(ReverseWav.HEADER_BYTES, h.capacity())
        assertEquals("RIFF", String(ByteArray(4) { h.get(it) }, Charsets.US_ASCII))
        assertEquals(1036, h.getInt(4))
        assertEquals(1, h.getShort(20).toInt())
        assertEquals(2, h.getShort(22).toInt())
        assertEquals(44_100, h.getInt(24))
        assertEquals(44_100 * 4, h.getInt(28))
        assertEquals(4, h.getShort(32).toInt())
        assertEquals(16, h.getShort(34).toInt())
        assertEquals(1_000, h.getInt(40))
    }
    @Test
    fun planeCopyHandlesStridesAndCropOffsets() {
        // Source: 4x3 plane with row stride 6, cropped at (1, 1); destination packed 2x2.
        val src = ByteArray(18) { it.toByte() }
        val dst = ByteArray(4)
        YuvCopy.copyPlane(ByteBuffer.wrap(src), 1, 6, 1, 1, ByteBuffer.wrap(dst), 1, 2, 2, 2)
        assertArrayEquals(byteArrayOf(7, 8, 13, 14), dst)
        // Interleaved chroma (pixel stride 2, as NV12 exposes U and V) into a packed plane and back.
        val nv = ByteArray(8) { (10 + it).toByte() } // U V U V / U V U V, row stride 4
        val u = ByteArray(4)
        YuvCopy.copyPlane(ByteBuffer.wrap(nv), 2, 4, 0, 0, ByteBuffer.wrap(u), 1, 2, 2, 2)
        assertArrayEquals(byteArrayOf(10, 12, 14, 16), u)
        val back = ByteArray(8)
        YuvCopy.copyPlane(ByteBuffer.wrap(u), 1, 2, 0, 0, ByteBuffer.wrap(back), 2, 4, 2, 2)
        assertArrayEquals(byteArrayOf(10, 0, 12, 0, 14, 0, 16, 0), back)
    }
}
