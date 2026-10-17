@file:OptIn(UnstableApi::class, ExperimentalApi::class)
// OWNER: AND-08

// Source facts the mapper needs (ARCH §11.5, §13.3 "Items"; AND-01 V-N16, §6.7):
// - the rule frame of a source time s: the video sample with the greatest PTS ≤ s + 500 µs (PTS on
//   the presentation timeline, edit lists applied), the first sample when s precedes every sample.
//   Clip starts snap to it (SNAP_TO_RULE_FRAME: 0 mismatches over 7 offsets on plain and B-frame
//   sources where clipping at s0 gave 15);
// - the full source duration (`EditedMediaItem.setDurationUs`, CompositionPlayer needed it,
//   Transformer accepts it).
// [ExtractorSourceTimeline] reads both with MediaExtractorCompat, opened read-only through Media3's
// DataSource (file:// and content://). It never logs URIs.

package com.vecvel.danaview.editor.engine.composition

import android.content.Context
import android.media.MediaFormat
import androidx.annotation.OptIn
import androidx.core.net.toUri
import androidx.media3.common.util.ExperimentalApi
import androidx.media3.common.util.UnstableApi
import androidx.media3.inspector.MediaExtractorCompat
import java.io.Closeable
import java.io.IOException

/** Source timing facts (file header). */
interface SourceTimeline {
    /** PTS (µs) of the rule frame of source time [sourceUs] in the first video track of [uri]. */
    fun ruleFramePtsUs(uri: String, sourceUs: Long): Long

    /** The full presentation duration of [uri] (longest track, µs), or null when unknown. */
    fun durationUs(uri: String): Long?

    companion object {
        /** Rule-frame tolerance ε (ARCH §11.5, D-04). */
        const val EPSILON_US: Long = 500L
    }
}

/**
 * [SourceTimeline] over MediaExtractorCompat. One instance serves one mapping (it keeps an
 * extractor per source open and caches answers); [close] releases them.
 */
class ExtractorSourceTimeline(private val context: Context) : SourceTimeline, Closeable {
    private class Source(val extractor: MediaExtractorCompat, val videoTrack: Int, val durationUs: Long?, val firstPtsUs: Long?)

    private val sources = HashMap<String, Source?>()
    private val ruleCache = HashMap<Pair<String, Long>, Long>()

    @Synchronized
    override fun ruleFramePtsUs(uri: String, sourceUs: Long): Long = ruleCache.getOrPut(uri to sourceUs) {
        val src = open(uri) ?: throw IOException("source has no readable video track")
        val target = sourceUs + SourceTimeline.EPSILON_US
        val ex = src.extractor
        ex.seekTo(maxOf(0L, target), MediaExtractorCompat.SEEK_TO_PREVIOUS_SYNC)
        var best = Long.MIN_VALUE
        var syncsAfter = 0
        var guard = 0
        while (guard++ < MAX_SCANNED_SAMPLES) {
            val t = ex.sampleTime
            if (t < 0) break
            if (t <= target && t > best) best = t
            if (t > target && (ex.sampleFlags and android.media.MediaExtractor.SAMPLE_FLAG_SYNC) != 0) {
                // Leading B-frames of the next GOP may still precede the target: read one more GOP.
                if (++syncsAfter >= 2) break
            }
            if (!ex.advance()) break
        }
        if (best == Long.MIN_VALUE) src.firstPtsUs ?: throw IOException("source has no video samples") else best
    }

    @Synchronized
    override fun durationUs(uri: String): Long? = open(uri)?.durationUs

    private fun open(uri: String): Source? = sources.getOrPut(uri) {
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
            var first: Long? = null
            if (video >= 0) {
                ex.selectTrack(video)
                ex.seekTo(0, MediaExtractorCompat.SEEK_TO_PREVIOUS_SYNC)
                // The smallest PTS of the first GOP (B-frame sources start with a reordered GOP).
                var guard = 0
                var syncs = 0
                while (guard++ < MAX_SCANNED_SAMPLES) {
                    val t = ex.sampleTime
                    if (t < 0) break
                    if ((ex.sampleFlags and android.media.MediaExtractor.SAMPLE_FLAG_SYNC) != 0 && ++syncs >= 2) break
                    first = minOf(first ?: t, t)
                    if (!ex.advance()) break
                }
            }
            Source(ex, video, duration, first)
        } catch (e: IOException) {
            ex.release()
            null
        }
    }

    @Synchronized
    override fun close() {
        for (s in sources.values) s?.extractor?.release()
        sources.clear()
        ruleCache.clear()
    }

    private companion object {
        /** Upper bound of samples scanned per lookup (two long GOPs). */
        const val MAX_SCANNED_SAMPLES = 2048
    }
}
