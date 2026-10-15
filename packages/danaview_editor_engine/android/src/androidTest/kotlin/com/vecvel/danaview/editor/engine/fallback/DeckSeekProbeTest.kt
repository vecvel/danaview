@file:OptIn(UnstableApi::class)

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
import androidx.media3.common.util.UnstableApi
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.SeekParameters
import com.vecvel.danaview.editor.engine.harness.TestFixtures
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import org.junit.Test

class DeckSeekProbeTest {
    @Test
    fun probe() {
        val ctx = TestFixtures.targetContext
        val thread = HandlerThread("probe").apply { start() }
        val h = Handler(thread.looper)
        val frames = CopyOnWriteArrayList<Long>()
        lateinit var player: ExoPlayer
        lateinit var reader: ImageReader
        fun run(block: () -> Unit) {
            val l = CountDownLatch(1)
            h.post { block(); l.countDown() }
            l.await(10, TimeUnit.SECONDS)
        }
        for (variant in listOf("plain", "noclip", "clipInPeriod", "software", "clipInPeriod+software")) {
            val name = 30
            val uri = FallbackPlans.counterAsset(name).uri
            run {
                reader = ImageReader.newInstance(640, 360, ImageFormat.PRIVATE, 8, HardwareBuffer.USAGE_GPU_SAMPLED_IMAGE)
                reader.setOnImageAvailableListener({ r -> r.acquireNextImage()?.close() }, h)
                val b = ExoPlayer.Builder(ctx).setLooper(thread.looper)
                if (variant.contains("clipInPeriod")) b.setMediaSourceFactory(androidx.media3.exoplayer.source.DefaultMediaSourceFactory(ctx).setEnableClippingInMediaPeriod(true))
                if (variant.contains("software")) b.setRenderersFactory(androidx.media3.exoplayer.DefaultRenderersFactory(ctx).setMediaCodecSelector(com.vecvel.danaview.editor.engine.media.ExactFrames.softwareFirst))
                player = b.build()
                player.setSeekParameters(SeekParameters.EXACT)
                player.pauseAtEndOfMediaItems = true
                player.setVideoSurface(reader.surface)
                player.setVideoFrameMetadataListener { pts, _, _, _ -> frames += pts }
                val start = if (name == 30) 800_000L else 800_000L
                val mb = MediaItem.Builder().setUri(uri.toUri())
                if (variant != "noclip") mb.setClippingConfiguration(MediaItem.ClippingConfiguration.Builder().setStartPositionUs(start).setEndPositionUs(start + 1_200_000).build())
                player.setMediaItems(listOf(mb.build()))
                player.prepare()
            }
            val off = if (variant == "noclip") 800L else 0L
            for (ms0 in listOf(232L, 233L, 300L, 301L, 1000L, 233L)) {
                val ms = ms0 + off
                frames.clear()
                run { player.seekTo(0, ms) }
                Thread.sleep(800)
                Log.i("AND16PROBE", "$variant seek $ms -> ${frames.toList()}")
            }
            run {
                player.release()
                reader.close()
            }
        }
        thread.quitSafely()
    }
}
