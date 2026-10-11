@file:OptIn(UnstableApi::class, ExperimentalApi::class)

package com.vecvel.vwish.spike.engine

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Color
import android.net.Uri
import androidx.media3.common.C
import androidx.media3.common.Effect
import androidx.media3.common.MediaItem
import androidx.media3.common.SpeedParameters
import androidx.media3.common.audio.SpeedProvider
import androidx.media3.common.util.ExperimentalApi
import androidx.media3.common.util.UnstableApi
import androidx.media3.effect.FrameDropEffect
import androidx.media3.transformer.Composition
import androidx.media3.transformer.EditedMediaItem
import androidx.media3.transformer.EditedMediaItemSequence
import androidx.media3.transformer.Effects
import java.io.File
import java.util.concurrent.ConcurrentLinkedQueue
import kotlin.math.roundToLong

/** How a clip start meets the ε source-frame rule (ARCH §11.5, V-N16). */
enum class EpsilonMode {
    /** Clip exactly at s0 (Media3 drops samples with pts < s0). */
    NONE,

    /** Clip at s0 − 500 µs: a sample up to 500 µs before s0 is kept and lands ≤ 500 µs after t0. */
    SHIFT_START_500,

    /**
     * Clip at the PTS of the rule frame of s0 (greatest PTS ≤ s0 + 500 µs, read from the sample
     * table with MediaExtractorCompat, edit lists applied). With Media3's nearest secondary-frame
     * selection this makes every frame of a same-rate clip the rule frame (V-N16).
     */
    SNAP_TO_RULE_FRAME,
}

/** What drives the output frame grid (sequence 0). */
enum class ClockBandKind {
    /** ARCH §13.3 as written: one transparent image item with setFrameRate(fps). */
    IMAGE,

    /** A tiny black H.264 clip at the output fps (gated invisible), see AND-01.md "Clock band". */
    VIDEO,
}

/** How a secondary sequence is padded between layers (V-N18). */
enum class GapFill {
    /** `EditedMediaItemSequence.Builder.addGap` (Media3 blank frames). */
    GAP,

    /**
     * A transparent canvas-size image item with `setFrameRate(fps)` and the sequence's place
     * effect, so the gap has a frame on every output-grid time (AND-01 finding at 60 fps).
     */
    TRANSPARENT_IMAGE,
}

/** How items faster than 1× are capped at the project rate (V-N17). */
enum class FastItemCap { NONE, EDITED_ITEM_FRAME_RATE, FRAME_DROP_EFFECT }

data class MapperOptions(
    val epsilon: EpsilonMode = EpsilonMode.SHIFT_START_500,
    val fastCap: FastItemCap = FastItemCap.FRAME_DROP_EFFECT,
    val includeBackground: Boolean = true,
    val includeAudio: Boolean = true,
    val hdrMode: Int = Composition.HDR_MODE_TONE_MAP_HDR_TO_SDR_USING_OPEN_GL,
    val probe: ProbeEffect? = null,
    val recorder: EffectRecorder? = null,
    val overlayRecorder: ConcurrentLinkedQueue<OverlayCall>? = null,
    val clockBandTrackTypes: Set<Int> = setOf(C.TRACK_TYPE_VIDEO, C.TRACK_TYPE_AUDIO),
    val keepPitch: Boolean = true,
    /** Diagnostics only: omit the clock band (sequence 0). */
    val includeClockBand: Boolean = true,
    /** Clock-band image edge in px (ARCH: 2x2); diagnostics try larger ones. */
    val clockBandSize: Int = 2,
    val clockBandKind: ClockBandKind = ClockBandKind.IMAGE,
    /** For [ClockBandKind.VIDEO]: file:// URI of a clip at the output fps, at least as long as the plan. */
    val clockBandVideoUri: String? = null,
    /** Diagnostics only: no per-item effects (no PlaceEffect). */
    val noItemEffects: Boolean = false,
    val gapFill: GapFill = GapFill.GAP,
    /**
     * Diagnostics only: a probe appended after the place effect of every item of these visual
     * sequences, recording what each sequence hands the compositor (pts + barcode per region).
     */
    val sequenceProbes: Map<Int, ProbeEffect> = emptyMap(),
)

/**
 * Spike version of AND-08's CompositionMapper (ARCH §13.3 "Sequence stack"):
 * 0 = transparent 2x2 clock band at the output fps with trackTypes {VIDEO, AUDIO};
 * 1..n = one video sequence per `seq` slot (trackTypes {VIDEO}) padded with gaps, every item and
 * gap boundary on P(k) of the plan grid; n+1 = background solid; then audio-only sequences.
 */
class SpikeCompositionMapper(private val context: Context) {

    fun build(plan: SpikePlan, store: ParamStore, options: MapperOptions = MapperOptions()): Composition {
        val sequences = ArrayList<EditedMediaItemSequence>()
        if (options.includeClockBand) sequences += clockBand(plan, options)
        val n = plan.visualSequenceCount
        for (seq in 1..n) sequences += videoSequence(plan, seq, store, options)
        if (options.includeBackground) sequences += background(plan)
        if (options.includeAudio) {
            for (lane in 0 until plan.audioLaneCount) sequences += audioSequence(plan, lane)
        }
        val builder = Composition.Builder(sequences)
            .setVideoCompositorSettings(
                LayerGatingCompositorSettings(plan.canvasW, plan.canvasH, plan.fps, n, store, options.overlayRecorder),
            )
            .setHdrMode(options.hdrMode)
        options.probe?.let { builder.setEffects(Effects(emptyList(), listOf<Effect>(it))) }
        return builder.build()
    }

    private fun p(k: Long, fps: Int) = GridTime.platformTimeOfFrame(k, fps)

    private fun clockBand(plan: SpikePlan, options: MapperOptions): EditedMediaItemSequence {
        if (options.clockBandKind == ClockBandKind.VIDEO) {
            val uri = requireNotNull(options.clockBandVideoUri) { "clockBandVideoUri" }
            val srcDur = SourceDurations.of(context, uri)
            require(srcDur >= plan.durUs) { "clock clip too short: $srcDur < ${plan.durUs}" }
            val item = MediaItem.Builder()
                .setUri(Uri.parse(uri))
                .setClippingConfiguration(MediaItem.ClippingConfiguration.Builder().setEndPositionUs(plan.durUs).build())
                .build()
            val edited = EditedMediaItem.Builder(item).setDurationUs(srcDur).build()
            return EditedMediaItemSequence.Builder(options.clockBandTrackTypes).addItem(edited).build()
        }
        val sz = options.clockBandSize
        val png = pngFile("clockband_${sz}x$sz.png", sz, sz, Color.TRANSPARENT)
        val durUs = plan.durUs
        val item = MediaItem.Builder()
            .setUri(Uri.fromFile(png))
            .setImageDurationMs(GridTime.ceilDiv(durUs, 1000))
            .build()
        val edited = EditedMediaItem.Builder(item)
            .setDurationUs(durUs)
            .setFrameRate(plan.fps)
            .build()
        return EditedMediaItemSequence.Builder(options.clockBandTrackTypes).addItem(edited).build()
    }

    private fun background(plan: SpikePlan): EditedMediaItemSequence {
        val color = Color.rgb((plan.bg shr 16) and 0xff, (plan.bg shr 8) and 0xff, plan.bg and 0xff)
        val png = pngFile("bg_${Integer.toHexString(plan.bg)}_${plan.canvasW}x${plan.canvasH}.png", plan.canvasW, plan.canvasH, color)
        val durUs = plan.durUs
        val item = MediaItem.Builder()
            .setUri(Uri.fromFile(png))
            .setImageDurationMs(GridTime.ceilDiv(durUs, 1000))
            .build()
        val edited = EditedMediaItem.Builder(item).setDurationUs(durUs).setFrameRate(plan.fps).build()
        return EditedMediaItemSequence.Builder(setOf(C.TRACK_TYPE_VIDEO)).addItem(edited).build()
    }

    private fun videoSequence(plan: SpikePlan, seq: Int, store: ParamStore, options: MapperOptions): EditedMediaItemSequence {
        val g = plan.gridFps
        val place = PlaceEffect(seq, store, plan.canvasW, plan.canvasH, plan.fps, options.recorder)
        val b = EditedMediaItemSequence.Builder(setOf(C.TRACK_TYPE_VIDEO))
        var cursor = 0L
        fun pad(k0: Long, k1: Long) {
            val durUs = p(k1, g) - p(k0, g)
            if (options.gapFill == GapFill.GAP) {
                b.addGap(durUs)
                return
            }
            val png = pngFile("transparent_${plan.canvasW}x${plan.canvasH}.png", plan.canvasW, plan.canvasH, Color.TRANSPARENT)
            val item = MediaItem.Builder().setUri(Uri.fromFile(png)).setImageDurationMs(GridTime.ceilDiv(durUs, 1000)).build()
            val effects = (if (options.noItemEffects) emptyList() else listOf<Effect>(place)) + listOfNotNull<Effect>(options.sequenceProbes[seq])
            b.addItem(EditedMediaItem.Builder(item).setDurationUs(durUs).setFrameRate(plan.fps).setEffects(Effects(emptyList(), effects)).build())
        }
        for (l in plan.layersOf(seq)) {
            require(l.k0 >= cursor) { "layers of seq $seq overlap at ${l.id}" }
            if (l.k0 > cursor) pad(cursor, l.k0)
            b.addItem(videoItem(plan, l, place, options))
            cursor = l.k1
        }
        if (cursor < plan.durFrames) pad(cursor, plan.durFrames)
        return b.build()
    }

    /** Clipping for a layer: [start, end) in source µs such that the item lasts P(k1) − P(k0). */
    fun clipping(plan: SpikePlan, l: SpikeLayer, epsilon: EpsilonMode): Pair<Long, Long> {
        val g = plan.gridFps
        val compDurUs = p(l.k1, g) - p(l.k0, g)
        val start = when (epsilon) {
            EpsilonMode.NONE -> l.srcStartUs
            EpsilonMode.SHIFT_START_500 -> (l.srcStartUs - 500).coerceAtLeast(0)
            EpsilonMode.SNAP_TO_RULE_FRAME -> SourceFrameTimes.ruleFramePts(context, l.uri, l.srcStartUs)
        }
        // The end is adjusted (≤ 1 µs × rate) so the item duration is exactly P(k1) − P(k0).
        val end = start + (compDurUs * l.speed.toDouble()).roundToLong()
        return start to end
    }

    private fun videoItem(plan: SpikePlan, l: SpikeLayer, place: PlaceEffect, options: MapperOptions): EditedMediaItem {
        val (start, end) = clipping(plan, l, options.epsilon)
        val item = MediaItem.Builder()
            .setUri(Uri.parse(l.uri))
            .setClippingConfiguration(
                MediaItem.ClippingConfiguration.Builder().setStartPositionUs(start).setEndPositionUs(end).build(),
            )
            .build()
        val effects = ArrayList<Effect>()
        val fast = l.speed > 1f
        if (fast && options.fastCap == FastItemCap.FRAME_DROP_EFFECT) {
            effects += FrameDropEffect.createDefaultFrameDropEffect(plan.gridFps.toFloat())
        }
        if (!options.noItemEffects) effects += place
        options.sequenceProbes[l.seq]?.let { effects += it }
        // CompositionPlayer needs the full source duration of every item (EditedMediaItem
        // .getPresentationDurationUs checkState); Transformer does not (found in AND-01).
        val eb = EditedMediaItem.Builder(item)
            .setDurationUs(SourceDurations.of(context, l.uri))
            .setRemoveAudio(true)
            .setEffects(Effects(emptyList(), effects))
        if (l.speed != 1f) eb.setSpeed(SpeedParameters(constantSpeed(l.speed), options.keepPitch))
        if (fast && options.fastCap == FastItemCap.EDITED_ITEM_FRAME_RATE) eb.setFrameRate(plan.gridFps)
        return eb.build()
    }

    private fun audioSequence(plan: SpikePlan, lane: Int): EditedMediaItemSequence {
        val g = plan.gridFps
        val b = EditedMediaItemSequence.Builder(setOf(C.TRACK_TYPE_AUDIO))
        var cursor = 0L
        for (a in plan.audio.filter { it.lane == lane }.sortedBy { it.k0 }) {
            if (a.k0 > cursor) b.addGap(p(a.k0, g) - p(cursor, g))
            val dur = p(a.k1, g) - p(a.k0, g)
            val item = MediaItem.Builder()
                .setUri(Uri.parse(a.uri))
                .setClippingConfiguration(
                    MediaItem.ClippingConfiguration.Builder()
                        .setStartPositionUs(a.srcStartUs)
                        .setEndPositionUs(a.srcStartUs + dur)
                        .build(),
                )
                .build()
            b.addItem(EditedMediaItem.Builder(item).setDurationUs(SourceDurations.of(context, a.uri)).setRemoveVideo(true).build())
            cursor = a.k1
        }
        if (cursor < plan.durFrames) b.addGap(p(plan.durFrames, g) - p(cursor, g))
        return b.build()
    }

    private fun pngFile(name: String, w: Int, h: Int, color: Int): File {
        val f = File(context.filesDir, "spike_$name")
        if (!f.exists()) {
            val bmp = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
            bmp.eraseColor(color)
            f.outputStream().use { bmp.compress(Bitmap.CompressFormat.PNG, 100, it) }
            bmp.recycle()
        }
        return f
    }

    companion object {
        /** Rule-frame lookup (ARCH §11.5) over the sample table, seeking to the previous sync sample. */
        object SourceFrameTimes {
            private val cache = java.util.concurrent.ConcurrentHashMap<String, LongArray>()

            /** Presentation times (µs, sorted, edit lists applied) of the first video track. */
            fun of(context: Context, uri: String): LongArray = cache.getOrPut(uri) {
                val ex = androidx.media3.inspector.MediaExtractorCompat(context)
                try {
                    ex.setDataSource(Uri.parse(uri), 0)
                    val track = (0 until ex.trackCount).first {
                        ex.getTrackFormat(it).getString(android.media.MediaFormat.KEY_MIME)!!.startsWith("video/")
                    }
                    ex.selectTrack(track)
                    val out = ArrayList<Long>()
                    while (true) {
                        val t = ex.sampleTime
                        if (t < 0) break
                        out += t
                        if (!ex.advance()) break
                    }
                    out.sorted().toLongArray()
                } finally {
                    ex.release()
                }
            }

            /** Greatest sample PTS ≤ s + 500 µs (the first sample when s is before every sample). */
            fun ruleFramePts(context: Context, uri: String, sUs: Long): Long {
                val times = of(context, uri)
                var lo = 0
                var hi = times.size - 1
                var ans = 0
                while (lo <= hi) {
                    val mid = (lo + hi) ushr 1
                    if (times[mid] <= sUs + 500) { ans = mid; lo = mid + 1 } else hi = mid - 1
                }
                return times[ans]
            }
        }

        /** Full presentation duration of a source in µs (longest track), cached per URI. */
        object SourceDurations {
            private val cache = java.util.concurrent.ConcurrentHashMap<String, Long>()
            fun of(context: Context, uri: String): Long = cache.getOrPut(uri) {
                val ex = android.media.MediaExtractor()
                try {
                    ex.setDataSource(context, Uri.parse(uri), null)
                    (0 until ex.trackCount).maxOf {
                        val f = ex.getTrackFormat(it)
                        if (f.containsKey(android.media.MediaFormat.KEY_DURATION)) f.getLong(android.media.MediaFormat.KEY_DURATION) else 0L
                    }
                } finally {
                    ex.release()
                }
            }
        }

        fun constantSpeed(speed: Float): SpeedProvider = object : SpeedProvider {
            override fun getSpeed(timeUs: Long): Float = speed
            override fun getNextSpeedChangeTimeUs(timeUs: Long): Long = C.TIME_UNSET
        }
    }
}
