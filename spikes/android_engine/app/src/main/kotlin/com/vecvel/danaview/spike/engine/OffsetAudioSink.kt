@file:OptIn(UnstableApi::class, ExperimentalApi::class)

package com.vecvel.danaview.spike.engine

import androidx.media3.common.C
import androidx.media3.common.util.ExperimentalApi
import androidx.media3.common.util.UnstableApi
import androidx.media3.exoplayer.audio.AudioSink
import androidx.media3.exoplayer.audio.ForwardingAudioSink
import java.util.concurrent.ConcurrentLinkedQueue

/** One (wall clock, audio position) sample of the sink's own clock (V-N23). */
data class AudioClockSample(val wallNs: Long, val positionUs: Long)

/**
 * V-N23 probe and compensation mechanism. Media3 renders video against the audio sink's clock
 * (`getCurrentPositionUs`). Reporting the position [leadUs] ahead makes the video renderer
 * release every frame [leadUs] earlier relative to the audible output, which is the same as
 * delaying audio by [leadUs] relative to video: the compensation for the SurfaceProducer →
 * Flutter raster latency (ARCH §12.7). Samples of the real (unshifted) clock are recorded.
 */
class OffsetAudioSink(sink: AudioSink, @Volatile var leadUs: Long = 0) : ForwardingAudioSink(sink) {
    val clock = ConcurrentLinkedQueue<AudioClockSample>()

    /** Presentation time of the first buffer handed to the sink after each flush (time base check). */
    val firstBufferPtsUs = ConcurrentLinkedQueue<Long>()
    @Volatile private var awaitingFirst = true

    override fun handleBuffer(buffer: java.nio.ByteBuffer, presentationTimeUs: Long, encodedAccessUnitCount: Int): Boolean {
        if (awaitingFirst) {
            firstBufferPtsUs.add(presentationTimeUs)
            awaitingFirst = false
        }
        return super.handleBuffer(buffer, presentationTimeUs, encodedAccessUnitCount)
    }

    override fun flush() {
        awaitingFirst = true
        super.flush()
    }

    override fun getCurrentPositionUs(sourceEnded: Boolean): Long {
        val p = super.getCurrentPositionUs(sourceEnded)
        if (p == AudioSink.CURRENT_POSITION_NOT_SET || p == C.TIME_UNSET) return p
        if (clock.size < 20_000) clock.add(AudioClockSample(System.nanoTime(), p))
        return p + leadUs
    }
}
