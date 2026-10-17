@file:OptIn(UnstableApi::class, ExperimentalApi::class)
// OWNER: AND-08

// Instrumented test support for AND-08: contract fixtures from the test APK (ENG-09 harness), a
// constant-rate fake SourceTimeline, a Transformer export runner on its own looper (H.264 + AAC,
// ORIGINAL working colour space as ARCH §11.6 / §14.3 ask) and readers of exported files (frame
// barcodes via MediaMetadataRetriever, decoded PCM windows). Media is ENG-05's committed
// fixtures; outputs go to the target app's cache and are deleted.
// Decoders: the exports prefer SOFTWARE decoders. Measured on Pixel_9_Pro_XL_API_35 (2026-10-11):
// the emulator's default (hardware-backed) H.264 decoder loses the first B-frame of the fixtures'
// B-pyramid GOPs (source frames 1, 61, 69 of clap_flash_av.mp4; frame 1 of frame_counter_720p24/25)
// even in a plain one-item transcode with no composition (barcodes 0, 2, 3, …), while the software
// decoder returns every frame (CompositionExportTest.plainTranscodeControl). That is an emulator
// decoder defect, not a mapping one; device decoders are checked on hardware (QA-04).

package com.vecvel.danaview.editor.engine.composition

import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMetadataRetriever
import android.os.Handler
import android.os.HandlerThread
import androidx.annotation.OptIn
import androidx.media3.common.MimeTypes
import androidx.media3.common.util.Clock
import androidx.media3.common.util.ExperimentalApi
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.DataSourceBitmapLoader
import androidx.media3.effect.DefaultVideoFrameProcessor
import androidx.media3.exoplayer.mediacodec.MediaCodecUtil
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory
import androidx.media3.extractor.DefaultExtractorsFactory
import androidx.media3.extractor.amr.AmrExtractor
import androidx.media3.extractor.ts.AdtsExtractor
import androidx.media3.transformer.AssetLoader
import androidx.media3.transformer.Composition
import androidx.media3.transformer.DefaultAssetLoaderFactory
import androidx.media3.transformer.DefaultDecoderFactory
import androidx.media3.transformer.ExportException
import androidx.media3.transformer.ExportResult
import androidx.media3.transformer.Transformer
import com.vecvel.danaview.editor.engine.harness.FixtureTree
import com.vecvel.danaview.editor.engine.harness.TestFixtures
import com.vecvel.danaview.editor.engine.support.FrameBarcode
import com.vecvel.danaview.editor.engine.support.decode
import java.io.File
import java.nio.ByteOrder
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference

/** Contract fixture access from the test APK. */
object ContractAssets {
    const val DIR = "render_plans/contract"

    /** `*.json` names of a contract sub-directory ("" = valid corpus), sorted. */
    fun names(sub: String = ""): List<String> =
        TestFixtures.list(FixtureTree.CORE, if (sub.isEmpty()) DIR else "$DIR/$sub")
            .filter { it.endsWith(".json") && !it.endsWith(".expected_active.json") }
            .sorted()

    fun bytes(sub: String, name: String): ByteArray =
        TestFixtures.open(FixtureTree.CORE, if (sub.isEmpty()) "$DIR/$name" else "$DIR/$sub/$name").use { it.readBytes() }

    fun text(sub: String, name: String): String = bytes(sub, name).toString(Charsets.UTF_8)
}

/** Constant-rate sample tables: frame i at `round(i·1e6/fps)`; every source lasts [durationUs]. */
class ConstantRateTimeline(private val fps: Int = 30, private val durationUs: Long = 3_600_000_000L) : SourceTimeline {
    private fun pts(i: Long) = Math.floorDiv(2 * i * 1_000_000L + fps, 2L * fps)

    override fun ruleFramePtsUs(uri: String, sourceUs: Long): Long {
        val target = sourceUs + SourceTimeline.EPSILON_US
        if (target < 0) return 0
        var i = Math.floorDiv(target * fps, 1_000_000L)
        while (pts(i + 1) <= target) i++
        while (i > 0 && pts(i) > target) i--
        return pts(i)
    }

    override fun durationUs(uri: String): Long = durationUs
}

/** Runs Transformer exports on a dedicated looper. */
object ExportRunner {
    class Failed(val exception: ExportException) : AssertionError("export failed: ${exception.errorCodeName}", exception)

    /**
     * Exports [composition] to [out] (H.264 + AAC) with software decoders first ([softwareDecoders],
     * see the file header) or the platform default; returns the result and the wall time.
     */
    fun export(composition: Composition, out: File, softwareDecoders: Boolean = true, timeoutSec: Long = 300): Pair<ExportResult, Long> =
        exportWith(composition, out, timeoutSec) { if (softwareDecoders) it.setAssetLoaderFactory(softwareFirstAssetLoader()) }

    /**
     * An asset loader whose decoder factory lists software decoders before hardware ones. Its media
     * source factory is Transformer's own default (ExoPlayerAssetLoader 1.11.1: ADTS/AMR constant
     * bitrate seeking and clipping inside the media period); a plain DefaultMediaSourceFactory
     * clips in decode order and loses the B-frames before a clip end (measured: source frames
     * 167–169 of clap_flash_av.mp4 when an item ends at frame 170).
     */
    fun softwareFirstAssetLoader(): AssetLoader.Factory {
        val ctx = TestFixtures.targetContext
        return DefaultAssetLoaderFactory(
            ctx,
            DefaultDecoderFactory.Builder(ctx)
                .setMediaCodecSelector { mime, secure, tunneling ->
                    MediaCodecUtil.getDecoderInfos(mime, secure, tunneling).sortedBy { if (it.softwareOnly) 0 else 1 }
                }
                .build(),
            Clock.DEFAULT,
            DefaultMediaSourceFactory(
                ctx,
                DefaultExtractorsFactory()
                    .setAdtsExtractorFlags(AdtsExtractor.FLAG_ENABLE_CONSTANT_BITRATE_SEEKING)
                    .setAmrExtractorFlags(AmrExtractor.FLAG_ENABLE_CONSTANT_BITRATE_SEEKING),
            ).setEnableClippingInMediaPeriod(true),
            DataSourceBitmapLoader.Builder(ctx).build(),
        )
    }

    /** [export] with extra [configure] of the Transformer builder (decoder or encoder choices). */
    fun exportWith(
        composition: Composition,
        out: File,
        timeoutSec: Long = 300,
        configure: (Transformer.Builder) -> Unit,
    ): Pair<ExportResult, Long> {
        out.delete()
        out.parentFile?.mkdirs()
        val thread = HandlerThread("and08-export").apply { start() }
        val latch = CountDownLatch(1)
        val result = AtomicReference<ExportResult?>()
        val error = AtomicReference<ExportException?>()
        val started = System.nanoTime()
        try {
            Handler(thread.looper).post {
                Transformer.Builder(TestFixtures.targetContext)
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
                    .also(configure)
                    .build()
                    .start(composition, out.absolutePath)
            }
            check(latch.await(timeoutSec, TimeUnit.SECONDS)) { "export timed out" }
        } finally {
            thread.quitSafely()
        }
        error.get()?.let { throw Failed(it) }
        return result.get()!! to (System.nanoTime() - started) / 1_000_000
    }
}

/** Reads exported files. */
object OutputReader {
    /** MIME types of the tracks of [f]. */
    fun trackMimes(f: File): List<String> {
        val ex = MediaExtractor()
        try {
            ex.setDataSource(f.absolutePath)
            return (0 until ex.trackCount).map { ex.getTrackFormat(it).getString(MediaFormat.KEY_MIME)!! }
        } finally {
            ex.release()
        }
    }

    /** Video sample presentation times of [f] in decode order, sorted. */
    fun videoPts(f: File): List<Long> {
        val ex = MediaExtractor()
        try {
            ex.setDataSource(f.absolutePath)
            val t = (0 until ex.trackCount).first { ex.getTrackFormat(it).getString(MediaFormat.KEY_MIME)!!.startsWith("video/") }
            ex.selectTrack(t)
            val out = ArrayList<Long>()
            while (ex.sampleTime >= 0) {
                out += ex.sampleTime
                if (!ex.advance()) break
            }
            return out.sorted()
        } finally {
            ex.release()
        }
    }

    /** The barcode index of every video frame of [f] in presentation order (null = unreadable). */
    fun barcodes(f: File, frameCount: Int): List<Int?> {
        val r = MediaMetadataRetriever()
        try {
            r.setDataSource(f.absolutePath)
            val out = ArrayList<Int?>()
            var i = 0
            while (i < frameCount) {
                val n = minOf(10, frameCount - i)
                val frames = r.getFramesAtIndex(i, n)
                for (b in frames) {
                    out += FrameBarcode.decode(b)
                    b.recycle()
                }
                i += n
            }
            return out
        } finally {
            r.release()
        }
    }

    /** Decoded PCM of the first audio track: sample rate, channels and interleaved samples in [-1, 1]. */
    class Pcm(val sampleRate: Int, val channels: Int, val samples: FloatArray, val firstPtsUs: Long) {
        /** RMS of channel 0 over [fromUs, toUs) of presentation time. */
        fun rms(fromUs: Long, toUs: Long): Double {
            val a = ((fromUs - firstPtsUs) * sampleRate / 1_000_000L).toInt().coerceAtLeast(0)
            val b = ((toUs - firstPtsUs) * sampleRate / 1_000_000L).toInt().coerceAtMost(samples.size / channels)
            var sum = 0.0
            for (i in a until b) {
                val v = samples[i * channels].toDouble()
                sum += v * v
            }
            return if (b > a) Math.sqrt(sum / (b - a)) else 0.0
        }
    }

    fun decodeAudio(f: File): Pcm? {
        val ex = MediaExtractor()
        ex.setDataSource(f.absolutePath)
        val t = (0 until ex.trackCount).firstOrNull { ex.getTrackFormat(it).getString(MediaFormat.KEY_MIME)!!.startsWith("audio/") }
        if (t == null) {
            ex.release()
            return null
        }
        ex.selectTrack(t)
        val fmt = ex.getTrackFormat(t)
        val codec = MediaCodec.createDecoderByType(fmt.getString(MediaFormat.KEY_MIME)!!)
        codec.configure(fmt, null, null, 0)
        codec.start()
        val info = MediaCodec.BufferInfo()
        var inputDone = false
        var rate = fmt.getInteger(MediaFormat.KEY_SAMPLE_RATE)
        var channels = fmt.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
        val out = ArrayList<Short>()
        var firstPts = Long.MIN_VALUE
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
                    rate = codec.outputFormat.getInteger(MediaFormat.KEY_SAMPLE_RATE)
                    channels = codec.outputFormat.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
                } else if (o >= 0) {
                    if (firstPts == Long.MIN_VALUE && info.size > 0) firstPts = info.presentationTimeUs
                    val buf = codec.getOutputBuffer(o)!!.order(ByteOrder.LITTLE_ENDIAN)
                    buf.position(info.offset)
                    val shorts = buf.asShortBuffer()
                    for (k in 0 until info.size / 2) out += shorts.get(k)
                    codec.releaseOutputBuffer(o, false)
                    if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) break
                }
            }
        } finally {
            codec.stop()
            codec.release()
            ex.release()
        }
        val samples = FloatArray(out.size) { out[it] / 32768f }
        return Pcm(rate, channels, samples, if (firstPts == Long.MIN_VALUE) 0L else firstPts)
    }
}
