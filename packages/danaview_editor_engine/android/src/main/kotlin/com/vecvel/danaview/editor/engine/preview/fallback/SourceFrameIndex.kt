@file:OptIn(UnstableApi::class, ExperimentalApi::class)
// OWNER: AND-16
//
// The PTS table of every video sample of a source (presentation timeline, edit lists applied, read
// with MediaExtractorCompat like AND-08's ExtractorSourceTimeline), so the frame clock can name the
// rule frame of any output frame (ARCH §11.5: greatest PTS ≤ s + 500 µs) without I/O on danaview-gl.
// Built off danaview-gl (the backend's worker) when a plan is (re)built, cached per URI (LRU) for
// the process. Reading the sample table touches only the container index and sample headers.
// Never logs URIs.

package com.vecvel.danaview.editor.engine.preview.fallback

import android.content.Context
import android.media.MediaFormat
import androidx.annotation.OptIn
import androidx.core.net.toUri
import androidx.media3.common.util.ExperimentalApi
import androidx.media3.common.util.UnstableApi
import androidx.media3.inspector.MediaExtractorCompat
import com.vecvel.danaview.editor.engine.core.EngineErrorCode
import com.vecvel.danaview.editor.engine.core.EngineException
import java.io.IOException

/** Rule frames from per-source PTS tables (file header). */
class SourceFrameIndex(private val context: Context) : RuleFrames {
    private class Entry(val pts: LongArray, val durationUs: Long?)

    override fun rule(uri: String, sourceUs: Long): Long = RuleFrameMath.rule(entry(uri).pts, sourceUs)

    override fun frameTimes(uri: String): LongArray = entry(uri).pts

    override fun durationUs(uri: String): Long? = entry(uri).durationUs

    private fun entry(uri: String): Entry {
        synchronized(cache) { cache[uri]?.let { return it } }
        val built = build(uri)
        synchronized(cache) { cache[uri] = built }
        return built
    }

    private fun build(uri: String): Entry {
        val ex = MediaExtractorCompat(context)
        try {
            ex.setDataSource(uri.toUri(), 0)
            var video = -1
            var duration: Long? = null
            for (i in 0 until ex.trackCount) {
                val f = ex.getTrackFormat(i)
                if (f.containsKey(MediaFormat.KEY_DURATION)) duration = maxOf(duration ?: 0L, f.getLong(MediaFormat.KEY_DURATION))
                if (video < 0 && f.getString(MediaFormat.KEY_MIME)?.startsWith("video/") == true) video = i
            }
            if (video < 0) throw EngineException(EngineErrorCode.unsupportedMedia, "source has no video track")
            ex.selectTrack(video)
            ex.seekTo(0, MediaExtractorCompat.SEEK_TO_PREVIOUS_SYNC)
            var times = LongArray(1024)
            var n = 0
            var guard = 0
            while (guard++ < MAX_SAMPLES) {
                val t = ex.sampleTime
                if (t < 0) break
                if (n == times.size) times = times.copyOf(n * 2)
                times[n++] = t
                if (!ex.advance()) break
            }
            if (n == 0) throw EngineException(EngineErrorCode.decodeFailed, "source has no video samples")
            val sorted = times.copyOf(n)
            sorted.sort()
            return Entry(sorted, duration)
        } catch (e: IOException) {
            throw EngineException(EngineErrorCode.mediaOffline, "source unreadable", cause = e)
        } finally {
            ex.release()
        }
    }

    companion object {
        /** Samples read per source at most (≈ 2.3 h at 60 fps). */
        const val MAX_SAMPLES = 500_000

        /** Sources whose tables are kept. */
        const val CAPACITY = 32

        private val cache = object : LinkedHashMap<String, Entry>(16, 0.75f, true) {
            override fun removeEldestEntry(eldest: MutableMap.MutableEntry<String, Entry>?): Boolean = size > CAPACITY
        }

        /** Drops every cached table (memory pressure). */
        fun clear() = synchronized(cache) { cache.clear() }
    }
}
