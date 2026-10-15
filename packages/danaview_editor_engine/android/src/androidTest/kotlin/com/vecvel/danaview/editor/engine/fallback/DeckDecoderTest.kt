@file:OptIn(UnstableApi::class, ExperimentalApi::class)
// OWNER: AND-16
//
// The deck seek contract the engine relies on (V-N18: an EXACT seek to floor((rule − clipStart) /
// 1000) ms shows the rule frame), checked with a bare deck player (ExoPlayer + PRIVATE ImageReader,
// clipping inside the media period, as VideoDeck builds it) on the B-frame positions of ENG-05's
// 1080p30 counter (every fixture has B-frames, has_b_frames = 2), with software decoders: every
// seek shows exactly its rule frame. The same seeks through the emulator's hardware decoder are
// recorded, not asserted: the goldfish H.264 decoder drops the leading B-frames after a flush (a
// seek to frame 31 shows frame 32), which is why the barcode tests list software decoders first
// and why the engine falls back to the exact still of a layer whose deck skipped its rule frame
// while paused (ContingencyFeaturesTest.hardwareDecodersNeverShowAWrongFrameAndExactSeeksStayExact).
// QA-04 re-checks hardware decoders on devices.

package com.vecvel.danaview.editor.engine.fallback

import android.graphics.ImageFormat
import android.hardware.HardwareBuffer
import android.media.ImageReader
import android.os.Handler
import android.os.HandlerThread
import android.util.Log
import androidx.annotation.OptIn
import androidx.core.net.toUri
import androidx.media3.common.MediaItem
import androidx.media3.common.util.ExperimentalApi
import androidx.media3.common.util.UnstableApi
import androidx.media3.exoplayer.DefaultRenderersFactory
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.SeekParameters
import androidx.media3.exoplayer.mediacodec.MediaCodecSelector
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory
import com.vecvel.danaview.editor.engine.harness.TestFixtures
import com.vecvel.danaview.editor.engine.media.ExactFrames
import com.vecvel.danaview.editor.engine.preview.fallback.RuleFrameMath
import com.vecvel.danaview.editor.engine.preview.fallback.SourceFrameIndex
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import org.junit.Assert.assertEquals
import org.junit.Test

class DeckDecoderTest {
    /** Seeks a deck player to each window ms and returns the first frame pts shown after each. */
    private fun seeks(selector: MediaCodecSelector?, uri: String, clipStart: Long, ms: List<Long>): List<Long?> {
        val ctx = TestFixtures.targetContext
        val thread = HandlerThread("and16-deck-probe").apply { start() }
        val h = Handler(thread.looper)
        val frames = CopyOnWriteArrayList<Long>()
        fun onThread(block: () -> Unit) {
            val l = CountDownLatch(1)
            h.post {
                block()
                l.countDown()
            }
            l.await(10, TimeUnit.SECONDS)
        }
        lateinit var player: ExoPlayer
        lateinit var reader: ImageReader
        onThread {
            reader = ImageReader.newInstance(640, 360, ImageFormat.PRIVATE, 8, HardwareBuffer.USAGE_GPU_SAMPLED_IMAGE)
            reader.setOnImageAvailableListener({ r -> r.acquireNextImage()?.close() }, h)
            val renderers = DefaultRenderersFactory(ctx).also { f -> selector?.let { f.setMediaCodecSelector(it) } }
            player = ExoPlayer.Builder(ctx, renderers).setLooper(thread.looper)
                .setMediaSourceFactory(DefaultMediaSourceFactory(ctx).setEnableClippingInMediaPeriod(true)).build()
            player.setSeekParameters(SeekParameters.EXACT)
            player.pauseAtEndOfMediaItems = true
            player.setVideoSurface(reader.surface)
            player.setVideoFrameMetadataListener { pts, _, _, _ -> frames += pts }
            val clip = MediaItem.ClippingConfiguration.Builder().setStartPositionUs(clipStart).setEndPositionUs(clipStart + 2_000_000).build()
            player.setMediaItem(MediaItem.Builder().setUri(uri.toUri()).setClippingConfiguration(clip).build())
            player.prepare()
        }
        val out = ArrayList<Long?>()
        try {
            for (m in ms) {
                frames.clear()
                onThread { player.seekTo(0, m) }
                val deadline = System.currentTimeMillis() + 5_000
                while (System.currentTimeMillis() < deadline && frames.isEmpty()) Thread.sleep(5)
                Thread.sleep(150)
                out += frames.firstOrNull()
            }
        } finally {
            onThread {
                player.release()
                reader.close()
            }
            thread.quitSafely()
        }
        return out
    }

    @Test
    fun exactDeckSeeksShowTheRuleFrameIncludingBFrames() {
        val uri = FallbackPlans.counterAsset(30).uri
        val pts = SourceFrameIndex(TestFixtures.targetContext).frameTimes(uri)
        val clipStart = RuleFrameMath.rule(pts, 800_000)
        // Output frames 24..40 of a layer starting at source frame 24: B-frames among them (31, 34, 37, 40).
        val targets = (24L..40L).map { n -> RuleFrameMath.rule(pts, Math.floorDiv(n * 1_000_000L, 30L)) }
        val ms = targets.map { Math.floorDiv(it - clipStart, 1000L) }
        val software = seeks(ExactFrames.softwareFirst, uri, clipStart, ms)
        val hardware = seeks(null, uri, clipStart, ms)
        val hwMisses = targets.indices.count { hardware[it] != targets[it] }
        Log.i(AND16_TAG, "deck EXACT seeks on the 1080p30 counter (emulator): software ${targets.indices.count { software[it] == targets[it] }}/${targets.size} exact; hardware ${targets.size - hwMisses}/${targets.size} exact (misses at ${targets.indices.filter { hardware[it] != targets[it] }.map { 24 + it }})")
        assertEquals(targets, software)
    }
}
