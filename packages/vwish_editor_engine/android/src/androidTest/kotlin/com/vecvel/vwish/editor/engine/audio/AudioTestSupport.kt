// OWNER: AND-04
//
// Shared helpers of the AND-04 instrumented tests: an engine context with test roots, a fake
// JobControl, WAV parsing and signal measurements.

package com.vecvel.vwish.editor.engine.audio

import com.vecvel.vwish.editor.engine.core.EngineContext
import com.vecvel.vwish.editor.engine.core.EngineThreads
import com.vecvel.vwish.editor.engine.core.JobControl
import com.vecvel.vwish.editor.engine.core.Paths
import com.vecvel.vwish.editor.engine.harness.TestFixtures
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.math.abs
import kotlin.math.sqrt

/** A JobControl whose cancellation the test drives. */
class TestJobControl(override val jobId: String = "test-job") : JobControl {
    val cancelled = AtomicBoolean(false)
    val reports = java.util.Collections.synchronizedList(ArrayList<Double>())

    override val isCancelled: Boolean get() = cancelled.get()

    override fun reportProgress(fraction: Double) {
        reports.add(fraction)
    }
}

/** A parsed PCM WAV. */
class Wav(val sampleRate: Int, val channels: Int, val bitsPerSample: Int, val format: Int, val samples: ShortArray, val chunkIds: List<String>) {
    val frames: Int get() = samples.size / channels
    val durationUs: Long get() = Math.round(frames * 1_000_000.0 / sampleRate)

    companion object {
        fun parse(file: File): Wav {
            val bytes = file.readBytes()
            val b = ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN)
            require(String(bytes, 0, 4, Charsets.US_ASCII) == "RIFF" && String(bytes, 8, 4, Charsets.US_ASCII) == "WAVE")
            require(b.getInt(4) == bytes.size - 8) { "RIFF size" }
            var pos = 12
            var rate = 0
            var channels = 0
            var bits = 0
            var format = 0
            val ids = ArrayList<String>()
            while (pos + 8 <= bytes.size) {
                val id = String(bytes, pos, 4, Charsets.US_ASCII)
                val size = b.getInt(pos + 4)
                ids.add(id)
                if (id == "fmt ") {
                    format = b.getShort(pos + 8).toInt()
                    channels = b.getShort(pos + 10).toInt()
                    rate = b.getInt(pos + 12)
                    bits = b.getShort(pos + 22).toInt()
                }
                if (id == "data") {
                    require(pos + 8 + size == bytes.size) { "data chunk size" }
                    val samples = ShortArray(size / 2) { b.getShort(pos + 8 + it * 2) }
                    return Wav(rate, channels, bits, format, samples, ids)
                }
                pos += 8 + size + (size and 1)
            }
            error("no data chunk")
        }
    }
}

object AudioSignals {
    /** First index >= [from] whose |sample| exceeds [threshold]. */
    fun onset(samples: ShortArray, from: Int = 0, threshold: Int = 1000): Int =
        (from until samples.size).firstOrNull { abs(samples[it].toInt()) > threshold } ?: -1

    /** RMS (0..1) of [samples]. */
    fun rms(samples: ShortArray): Double = sqrt(samples.sumOf { (it / 32768.0) * (it / 32768.0) } / samples.size.coerceAtLeast(1))

    /** RMS of float samples. */
    fun rms(samples: FloatArray): Double = sqrt(samples.sumOf { it.toDouble() * it } / samples.size.coerceAtLeast(1))

    /** Frequency estimate from positive-going zero crossings. */
    fun zeroCrossingHz(samples: ShortArray, rate: Int): Double {
        var crossings = 0
        for (i in 1 until samples.size) if (samples[i - 1] < 0 && samples[i] >= 0) crossings++
        return crossings * rate.toDouble() / samples.size
    }
}

/** An engine context with roots under the app's cache/files dirs (one per test class). */
object AudioTestEngine {
    fun create(name: String): EngineContext {
        val app = TestFixtures.targetContext.applicationContext
        val ctx = EngineContext(app, EngineThreads.android())
        val cache = File(app.cacheDir, "$name/vwish/editor")
        val support = File(app.filesDir, "$name/vwish/editor")
        cache.deleteRecursively()
        support.parentFile?.deleteRecursively()
        ctx.installRoots(Paths.fromDart(cache.absolutePath, support.absolutePath))
        return ctx
    }
}
