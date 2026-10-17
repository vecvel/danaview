@file:OptIn(UnstableApi::class, ExperimentalApi::class)

package com.vecvel.danaview.spike.engine

import android.content.Context
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.net.Uri
import android.os.Handler
import android.os.HandlerThread
import androidx.media3.common.Effect
import androidx.media3.common.MediaItem
import androidx.media3.common.MimeTypes
import androidx.media3.common.util.ExperimentalApi
import androidx.media3.common.util.UnstableApi
import androidx.media3.effect.DefaultVideoFrameProcessor
import androidx.media3.transformer.Composition
import androidx.media3.transformer.EditedMediaItem
import androidx.media3.transformer.EditedMediaItemSequence
import androidx.media3.transformer.Effects
import androidx.media3.transformer.ExportException
import androidx.media3.transformer.ExportResult
import androidx.media3.transformer.Transformer
import java.io.File
import java.nio.ByteOrder
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference
import kotlin.math.abs
import kotlin.math.max

/** Transformer export on its own looper (ARCH §14.3: H.264 + AAC, ORIGINAL working colour space). */
class ExportHarness(private val context: Context) {

    class ExportFailed(val exception: ExportException) : AssertionError("export failed: ${exception.errorCodeName}", exception)

    data class Outcome(val result: ExportResult, val wallMs: Long, val file: File)

    fun export(
        composition: Composition,
        out: File,
        timeoutSec: Long = 180,
        configure: (Transformer.Builder) -> Unit = {},
    ): Outcome {
        out.delete()
        val thread = HandlerThread("spike-export").apply { start() }
        val latch = CountDownLatch(1)
        val result = AtomicReference<ExportResult?>()
        val error = AtomicReference<ExportException?>()
        val started = System.nanoTime()
        try {
            Handler(thread.looper).post {
                val b = Transformer.Builder(context)
                    .setLooper(thread.looper)
                    .setVideoMimeType(MimeTypes.VIDEO_H264)
                    .setAudioMimeType(MimeTypes.AUDIO_AAC)
                    .setVideoFrameProcessorFactory(
                        DefaultVideoFrameProcessor.Factory.Builder()
                            .setSdrWorkingColorSpace(DefaultVideoFrameProcessor.WORKING_COLOR_SPACE_ORIGINAL)
                            .build(),
                    )
                    .addListener(object : Transformer.Listener {
                        override fun onCompleted(composition: Composition, exportResult: ExportResult) {
                            result.set(exportResult)
                            latch.countDown()
                        }

                        override fun onError(composition: Composition, exportResult: ExportResult, exportException: ExportException) {
                            error.set(exportException)
                            latch.countDown()
                        }
                    })
                configure(b)
                b.build().start(composition, out.absolutePath)
            }
            check(latch.await(timeoutSec, TimeUnit.SECONDS)) { "export timed out" }
        } finally {
            thread.quitSafely()
        }
        error.get()?.let { throw ExportFailed(it) }
        return Outcome(result.get()!!, (System.nanoTime() - started) / 1_000_000, out)
    }

    /**
     * Runs [file] through Transformer with a [probe] as the only composition effect, so every
     * decoded frame of an exported file is read back by the same code path as preview.
     */
    fun probeFile(file: File, probe: ProbeEffect): List<ProbeFrame> {
        probe.clear()
        val item = EditedMediaItem.Builder(MediaItem.fromUri(Uri.fromFile(file))).setRemoveAudio(true).build()
        val c = Composition.Builder(EditedMediaItemSequence.Builder(item).build())
            .setEffects(Effects(emptyList(), listOf<Effect>(probe)))
            .build()
        export(c, File(TestMedia.outDir, "probe_${file.nameWithoutExtension}.mp4"))
        return probe.frames.toList().sortedBy { it.ptsUs }
    }
}

/** Track facts of an exported file (MediaExtractor) and decoded audio statistics. */
object OutputInspector {
    data class Track(val mime: String, val format: MediaFormat)

    fun tracks(f: File): List<Track> {
        val ex = MediaExtractor()
        try {
            ex.setDataSource(f.absolutePath)
            return (0 until ex.trackCount).map {
                val fmt = ex.getTrackFormat(it)
                Track(fmt.getString(MediaFormat.KEY_MIME)!!, fmt)
            }
        } finally {
            ex.release()
        }
    }

    fun videoFrameCount(f: File): Int {
        val ex = MediaExtractor()
        try {
            ex.setDataSource(f.absolutePath)
            val t = (0 until ex.trackCount).first { ex.getTrackFormat(it).getString(MediaFormat.KEY_MIME)!!.startsWith("video/") }
            ex.selectTrack(t)
            var n = 0
            while (ex.sampleTime >= 0) {
                n++
                if (!ex.advance()) break
            }
            return n
        } finally {
            ex.release()
        }
    }

    data class AudioStats(val sampleRate: Int, val channels: Int, val frames: Long, val peak: Double, val rms: Double)

    /** Decodes the first audio track to PCM 16 and returns its peak and RMS (full scale = 1). */
    fun decodeAudio(f: File): AudioStats? {
        val ex = MediaExtractor()
        ex.setDataSource(f.absolutePath)
        val t = (0 until ex.trackCount).firstOrNull { ex.getTrackFormat(it).getString(MediaFormat.KEY_MIME)!!.startsWith("audio/") }
            ?: return null.also { ex.release() }
        ex.selectTrack(t)
        val fmt = ex.getTrackFormat(t)
        val codec = MediaCodec.createDecoderByType(fmt.getString(MediaFormat.KEY_MIME)!!)
        codec.configure(fmt, null, null, 0)
        codec.start()
        val info = MediaCodec.BufferInfo()
        var inputDone = false
        var peak = 0.0
        var sumSq = 0.0
        var count = 0L
        var outRate = fmt.getInteger(MediaFormat.KEY_SAMPLE_RATE)
        var outCh = fmt.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
        try {
            while (true) {
                if (!inputDone) {
                    val i = codec.dequeueInputBuffer(10_000)
                    if (i >= 0) {
                        val buf = codec.getInputBuffer(i)!!
                        val n = ex.readSampleData(buf, 0)
                        if (n < 0) {
                            codec.queueInputBuffer(i, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                            inputDone = true
                        } else {
                            codec.queueInputBuffer(i, 0, n, ex.sampleTime, 0)
                            ex.advance()
                        }
                    }
                }
                val o = codec.dequeueOutputBuffer(info, 10_000)
                if (o == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                    outRate = codec.outputFormat.getInteger(MediaFormat.KEY_SAMPLE_RATE)
                    outCh = codec.outputFormat.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
                } else if (o >= 0) {
                    val buf = codec.getOutputBuffer(o)!!.order(ByteOrder.LITTLE_ENDIAN)
                    buf.position(info.offset)
                    val shorts = buf.asShortBuffer()
                    val n = info.size / 2
                    for (k in 0 until n) {
                        val v = shorts.get(k) / 32768.0
                        peak = max(peak, abs(v))
                        sumSq += v * v
                    }
                    count += n
                    codec.releaseOutputBuffer(o, false)
                    if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) break
                }
            }
        } finally {
            codec.stop()
            codec.release()
            ex.release()
        }
        val rms = if (count == 0L) 0.0 else Math.sqrt(sumSq / count)
        return AudioStats(outRate, outCh, count / max(1, outCh), peak, rms)
    }
}

/** Mean SSIM on luma of two RGBA frames (row 0 = top), 8x8 windows on a 4x box-downsampled image. */
object Ssim {
    fun luma(rgba: ByteArray, w: Int, h: Int, f: Int = 4): Triple<DoubleArray, Int, Int> {
        val dw = w / f
        val dh = h / f
        val out = DoubleArray(dw * dh)
        for (y in 0 until dh) for (x in 0 until dw) {
            var s = 0.0
            for (yy in 0 until f) for (xx in 0 until f) {
                val i = ((y * f + yy) * w + (x * f + xx)) * 4
                val r = rgba[i].toInt() and 0xff
                val g = rgba[i + 1].toInt() and 0xff
                val b = rgba[i + 2].toInt() and 0xff
                s += 0.2126 * r + 0.7152 * g + 0.0722 * b
            }
            out[y * dw + x] = s / (f * f)
        }
        return Triple(out, dw, dh)
    }

    fun ssim(a: ByteArray, b: ByteArray, w: Int, h: Int): Double {
        val (la, dw, dh) = luma(a, w, h)
        val (lb, _, _) = luma(b, w, h)
        val c1 = (0.01 * 255) * (0.01 * 255)
        val c2 = (0.03 * 255) * (0.03 * 255)
        var total = 0.0
        var n = 0
        var y = 0
        while (y + 8 <= dh) {
            var x = 0
            while (x + 8 <= dw) {
                var ma = 0.0; var mb = 0.0
                for (yy in 0 until 8) for (xx in 0 until 8) {
                    ma += la[(y + yy) * dw + x + xx]; mb += lb[(y + yy) * dw + x + xx]
                }
                ma /= 64; mb /= 64
                var va = 0.0; var vb = 0.0; var cov = 0.0
                for (yy in 0 until 8) for (xx in 0 until 8) {
                    val da = la[(y + yy) * dw + x + xx] - ma
                    val db = lb[(y + yy) * dw + x + xx] - mb
                    va += da * da; vb += db * db; cov += da * db
                }
                va /= 63; vb /= 63; cov /= 63
                total += ((2 * ma * mb + c1) * (2 * cov + c2)) / ((ma * ma + mb * mb + c1) * (va + vb + c2))
                n++
                x += 8
            }
            y += 8
        }
        return total / n
    }
}
