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
        for (name in listOf(30, 60)) {
            val uri = FallbackPlans.counterAsset(name).uri
            run {
                reader = ImageReader.newInstance(640, 360, ImageFormat.PRIVATE, 8, HardwareBuffer.USAGE_GPU_SAMPLED_IMAGE)
                reader.setOnImageAvailableListener({ r -> r.acquireNextImage()?.close() }, h)
                player = ExoPlayer.Builder(ctx).setLooper(thread.looper).build()
                player.setSeekParameters(SeekParameters.EXACT)
                player.pauseAtEndOfMediaItems = true
                player.setVideoSurface(reader.surface)
                player.setVideoFrameMetadataListener { pts, _, _, _ -> frames += pts }
                val start = if (name == 30) 800_000L else 800_000L
                player.setMediaItems(listOf(MediaItem.Builder().setUri(uri.toUri()).setClippingConfiguration(MediaItem.ClippingConfiguration.Builder().setStartPositionUs(start).setEndPositionUs(start + 1_200_000).build()).build()))
                player.prepare()
            }
            for (ms in listOf(0L, 232L, 233L, 234L, 265L, 266L, 267L, 299L, 300L, 301L, 1000L, 233L)) {
                frames.clear()
                run { player.seekTo(0, ms) }
                Thread.sleep(800)
                Log.i("AND16PROBE", "fps=$name seek $ms -> ${frames.toList()}")
            }
            run {
                player.release()
                reader.close()
            }
        }
        thread.quitSafely()
    }
}
