@file:OptIn(UnstableApi::class, ExperimentalApi::class)
// OWNER: AND-16
//
// The contingency engine's decks (ARCH §13.3 "Decks" and "Audio", AND-01.md §2, §7). Everything
// here runs on danaview-gl (the engine thread: EGL/GL, the players' application looper, the
// ImageReader listeners and the Choreographer frame clock), with the backend's EGL context current
// whenever a texture is touched.
//
// - [VideoDeck]: an ExoPlayer (SeekParameters.EXACT, pauseAtEndOfMediaItems, audio disabled) playing
//   its slot's layers as one clipped playlist into a PRIVATE ImageReader (8 images,
//   USAGE_GPU_SAMPLED_IMAGE). Each released frame is tagged with the deck's epoch (bumped on every
//   reposition) through the frame-metadata listener, keyed by its release time (= the image
//   timestamp), so frames of an old position are never shown. The frame of a given pts is imported
//   as an OES texture through the JNI shim ([HwbImport]). A deck that sits in BUFFERING without its
//   frame is re-seeked by the engine's watchdog, alternating ms − 1 and ms ([reseek]).
// - [AudioDeck]: an audio-only ExoPlayer of one audio lane with AND-08's envelope semantics (gain
//   0–2 over plan time, [EnvelopeGainProcessor], applied before the speed change of the sink's Sonic
//   stage), the plan speed as playback parameters (pitch kept unless the segment says otherwise), the
//   lane's source stream (AND-08's AudioStreamTrackSelector) and a signed sink position offset for
//   the preview A/V compensation (V-N23, [OffsetAudioSink]).
// Never logs media paths.

package com.vecvel.danaview.editor.engine.preview.fallback

import android.content.Context
import android.graphics.Rect
import android.hardware.HardwareBuffer
import android.media.Image
import android.media.ImageReader
import android.opengl.GLES11Ext
import android.opengl.GLES20
import android.os.Handler
import android.os.Looper
import android.view.Surface
import androidx.annotation.OptIn
import androidx.annotation.RequiresApi
import androidx.core.net.toUri
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.PlaybackException
import androidx.media3.common.PlaybackParameters
import androidx.media3.common.Player
import androidx.media3.common.audio.AudioProcessor
import androidx.media3.common.audio.BaseAudioProcessor
import androidx.media3.common.util.ExperimentalApi
import androidx.media3.common.util.UnstableApi
import androidx.media3.exoplayer.DefaultLoadControl
import androidx.media3.exoplayer.DefaultRenderersFactory
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.SeekParameters
import androidx.media3.exoplayer.audio.AudioSink
import androidx.media3.exoplayer.audio.DefaultAudioSink
import androidx.media3.exoplayer.audio.ForwardingAudioSink
import androidx.media3.exoplayer.mediacodec.MediaCodecSelector
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory
import com.vecvel.danaview.editor.engine.composition.AudioStreamTrackSelector
import com.vecvel.danaview.editor.engine.effects.SourceTexture
import com.vecvel.danaview.editor.engine.plan.Keyframes
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.ConcurrentHashMap

/** What decks need from their engine (danaview-gl). */
internal interface DeckEnv {
    val context: Context
    val looper: Looper
    val handler: Handler

    /** Decoder choice (null = Media3's default; tests may prefer software decoders). */
    val codecSelector: MediaCodecSelector?

    /** A deck failed for good (after its recoveries). */
    fun deckFailed(error: PlaybackException)
}

/** Per-deck counters (diagnostics and tests). */
class DeckStats {
    var seeks = 0
    var prerolls = 0
    var driftCorrections = 0
    var latched = 0
    var staleImages = 0
    var reseeks = 0
    var recoveries = 0
}

/**
 * Clipping inside the media period: a ClippingMediaSource clips in decode order and loses the
 * B-frames before a clip end (AND-11's measurement), so a deck positioned on the last frames of a
 * layer would never render them.
 */
private fun deckMediaSources(context: Context) = DefaultMediaSourceFactory(context).setEnableClippingInMediaPeriod(true)

/** Small LoadControl: decks hold about 2 s of media (several players run at once). */
private fun deckLoadControl() = DefaultLoadControl.Builder()
    .setBufferDurationsMs(1_000, 2_500, 100, 250)
    .build()

/** A video deck (file header). */
@RequiresApi(29)
internal class VideoDeck(
    private val env: DeckEnv,
    /** Which deck of its slot (0 or 1). */
    val index: Int,
    items: List<DeckItem>,
    width: Int,
    height: Int,
) {
    /** Source pts of a released frame, tagged with the epoch it was rendered in. */
    private class Tag(val epoch: Int, val pts: Long)

    val stats = DeckStats()

    /** The external OES texture the latched frame is bound to. */
    val tex: Int

    private var reader: ImageReader
    private var surface: Surface

    /** The player. */
    val player: ExoPlayer

    private val tags = ConcurrentHashMap<Long, Tag>()

    /** Bumped on every reposition; frames released before it are stale. */
    @Volatile var epoch = 0
        private set

    /** The first source pts the current position can show (exact seeks; Long.MIN_VALUE for sync seeks). */
    @Volatile private var epochMinPts = Long.MIN_VALUE

    /** Acquired images not shown yet (pts order). */
    private val queue = ArrayDeque<Image>()
    private var bound: Image? = null
    private var boundEgl = 0L
    private var boundTexture: SourceTexture? = null

    /** The pts of the latched frame (Long.MIN_VALUE: none). */
    var latchedPts = Long.MIN_VALUE
        private set

    /** The epoch the latched frame was rendered in. */
    var latchedEpoch = -1
        private set

    /** The item this deck is positioned on, or -1. */
    var assigned = -1
        private set

    /** The items of the playlist. */
    var items: List<DeckItem> = items
        private set

    /** The last reposition (uptime ms) for drift-correction cooldowns. */
    var lastCorrectionMs = 0L

    /** When the current position was requested (uptime ms; watchdog). */
    var positionedAtMs = 0L
        private set

    private var positionedMs = 0L
    private var nudge = false

    /** Last player error (diagnostics; never shown or logged with content). */
    var lastError: String? = null
        private set

    /** Reader size. */
    var readerW = width
        private set
    var readerH = height
        private set

    private var prepared = false

    init {
        val ids = IntArray(1)
        GLES20.glGenTextures(1, ids, 0)
        tex = ids[0]
        GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, tex)
        GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_MIN_FILTER, GLES20.GL_LINEAR)
        GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_MAG_FILTER, GLES20.GL_LINEAR)
        GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_WRAP_S, GLES20.GL_CLAMP_TO_EDGE)
        GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_WRAP_T, GLES20.GL_CLAMP_TO_EDGE)
        GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, 0)
        reader = newReader(width, height)
        surface = reader.surface
        val renderers = DefaultRenderersFactory(env.context).also { f -> env.codecSelector?.let { f.setMediaCodecSelector(it) } }
        player = ExoPlayer.Builder(env.context, renderers)
            .setLooper(env.looper)
            .setLoadControl(deckLoadControl())
            .setMediaSourceFactory(deckMediaSources(env.context))
            .build()
        player.setSeekParameters(SeekParameters.EXACT)
        // Never roll into the next playlist item: the other deck owns it.
        player.pauseAtEndOfMediaItems = true
        player.volume = 0f
        player.trackSelectionParameters = player.trackSelectionParameters.buildUpon()
            .setTrackTypeDisabled(C.TRACK_TYPE_AUDIO, true)
            .setTrackTypeDisabled(C.TRACK_TYPE_TEXT, true)
            .build()
        player.setVideoSurface(surface)
        player.setVideoFrameMetadataListener { pts, releaseNs, _, _ ->
            tags[releaseNs] = Tag(epoch, pts)
            if (DEBUG) android.util.Log.d("AND16DBG", "deck$index e=$epoch frame pts=$pts")
            if (tags.size > MAX_TAGS) tags.keys.sorted().take(MAX_TAGS / 2).forEach { tags.remove(it) }
        }
        player.addListener(object : Player.Listener {
            override fun onPlayerError(error: PlaybackException) {
                lastError = error.errorCodeName
                // Codec errors and reclaimed decoders happen on devices too: re-prepare at the same
                // position; frames of the old epoch are dropped and the frame clock re-aligns the deck.
                if (stats.recoveries < MAX_RECOVERIES) {
                    stats.recoveries++
                    bumpEpoch()
                    player.prepare()
                } else {
                    env.deckFailed(error)
                }
            }
        })
        setItemsInternal(items)
    }

    private fun newReader(w: Int, h: Int): ImageReader =
        ImageReader.newInstance(w.coerceAtLeast(2), h.coerceAtLeast(2), android.graphics.ImageFormat.PRIVATE, MAX_IMAGES, HardwareBuffer.USAGE_GPU_SAMPLED_IMAGE)
            .also { r -> r.setOnImageAvailableListener({ pull() }, env.handler) }

    private fun mediaItem(item: DeckItem): MediaItem = MediaItem.Builder()
        .setUri(item.uri.toUri())
        .setClippingConfiguration(
            MediaItem.ClippingConfiguration.Builder()
                .setStartPositionUs(item.clipStartUs)
                .setEndPositionUs(item.clipEndUs)
                .build(),
        )
        .build()

    private fun setItemsInternal(next: List<DeckItem>) {
        items = next
        assigned = -1
        bumpEpoch()
        if (next.isEmpty()) {
            player.clearMediaItems()
        } else {
            player.setMediaItems(next.map(::mediaItem), true)
        }
    }

    /** Replaces the playlist (structural re-plan of this slot); the deck is unpositioned. */
    fun setItems(next: List<DeckItem>) {
        player.playWhenReady = false
        setItemsInternal(next)
    }

    private fun bumpEpoch() {
        epoch++
        queue.forEach { it.close() }
        queue.clear()
    }

    /** Whether the deck sits at item [i] at window position [ms], paused (a seek there would render nothing new). */
    private fun alreadyAt(i: Int, ms: Long): Boolean =
        assigned == i && !player.playWhenReady && player.currentMediaItemIndex == i && player.currentPosition == ms &&
            player.playbackState == Player.STATE_READY

    /**
     * Seeks to item [i] at window position [ms] with [params] (EXACT for every frame shown;
     * CLOSEST_SYNC only for the nearest-first preview of an exact seek while playing). Drops the
     * queued frames of the old position. [force] re-issues the seek (watchdog).
     */
    fun position(i: Int, ms: Long, params: SeekParameters = SeekParameters.EXACT, force: Boolean = false) {
        require(i in items.indices) { "no item $i" }
        // Already there with its frame latched or queued (e.g. warmed while paused): keep it.
        if (!force && params == SeekParameters.EXACT && alreadyAt(i, ms) && (latchedEpoch == epoch || hasQueuedFrame())) return
        bumpEpoch()
        if (!prepared || player.playbackState == Player.STATE_IDLE) {
            player.prepare()
            prepared = true
        }
        player.setSeekParameters(params)
        val item = items[i]
        epochMinPts = if (params == SeekParameters.EXACT) item.clipStartUs + (ms - 1).coerceAtLeast(0L) * 1000L else Long.MIN_VALUE
        if (player.currentMediaItemIndex == i && player.currentPosition == ms) {
            // ExoPlayer ignores a seek to the position it reports (no new frame would come):
            // go through a neighbouring ms. ms − 1 lands on the same frame (frames are > 1 ms apart,
            // V-N18); from 0 step away first.
            if (ms > 0) {
                player.seekTo(i, ms - 1)
            } else {
                player.seekTo(i, 1)
                player.seekTo(i, 0)
            }
        } else {
            player.seekTo(i, ms)
        }
        if (DEBUG) android.util.Log.d("AND16DBG", "deck$index e=$epoch seek i=$i ms=$ms cur=${player.currentMediaItemIndex}/${player.currentPosition}")
        assigned = i
        positionedMs = ms
        approachRule = -1L
        approachFailures = 0
        positionedAtMs = android.os.SystemClock.uptimeMillis()
        nudge = false
        stats.seeks++
    }

    /** The rule frame this deck is approaching by playing (-1: none). */
    var approachRule = -1L
        private set

    /** Approaches that overshot since the last positioning by the engine. */
    var approachFailures = 0
        private set

    /**
     * Plays item [i] from window position [ms] (before [rule]) until the rule frame arrives; the
     * engine latches it and calls [endApproach]. For decoders that skip the leading B-frames after a
     * flush: frames decoded in playback are complete.
     */
    fun approach(i: Int, ms: Long, rule: Long) {
        val failures = approachFailures
        position(i, ms, SeekParameters.EXACT, force = true)
        approachFailures = failures
        approachRule = rule
        player.playWhenReady = true
    }

    /** Ends an approach: pauses on the latched frame; a failed one counts. */
    fun endApproach(succeeded: Boolean) {
        player.playWhenReady = false
        approachRule = -1L
        if (!succeeded) approachFailures++
    }

    /** Watchdog: re-issues the current exact seek, alternating ms − 1 and ms (ExoPlayer ignores a seek to the ms it reports). */
    fun reseek() {
        if (assigned < 0) return
        nudge = !nudge
        val ms = if (nudge && positionedMs > 0) positionedMs - 1 else positionedMs
        bumpEpoch()
        epochMinPts = (items.getOrNull(assigned)?.clipStartUs ?: 0L) + (positionedMs - 1).coerceAtLeast(0L) * 1000L
        player.setSeekParameters(SeekParameters.EXACT)
        player.seekTo(assigned, ms)
        positionedAtMs = android.os.SystemClock.uptimeMillis()
        stats.reseeks++
    }

    /**
     * Whether the deck is stuck without a frame of its epoch: BUFFERING for at least [ms] since its
     * last positioning (AND-01's cold-start case), or paused and READY for [readyMs] (a seek ExoPlayer
     * dropped: nothing will be rendered).
     */
    fun stuck(nowMs: Long, ms: Long, readyMs: Long = READY_WITHOUT_FRAME_MS): Boolean {
        if (assigned < 0 || latchedEpoch == epoch || queue.isNotEmpty()) return false
        val waited = nowMs - positionedAtMs
        return when (player.playbackState) {
            Player.STATE_BUFFERING -> waited >= ms
            Player.STATE_READY -> !player.playWhenReady && waited >= readyMs
            else -> false
        }
    }

    /** Deck state for diagnostics (no content). */
    fun debugState(): String =
        "[on $assigned st=${player.playbackState} pwr=${player.playWhenReady} idx=${player.currentMediaItemIndex} pos=${player.currentPosition} " +
            "q=${queue.size} l=$latchedPts le=$latchedEpoch e=$epoch err=$lastError]"

    /**
     * A frame belongs to the current position when it was tagged in the current epoch AND is not
     * before the position's first possible frame: a render of the previous position still in flight
     * when the epoch was bumped is tagged with the new epoch, but its pts gives it away (an exact
     * seek shows the first frame ≥ the position, V-N18; playback only moves forward).
     */
    private fun tagOf(releaseNs: Long): Tag? = tags[releaseNs]?.takeIf { it.epoch == epoch && it.pts >= epochMinPts }

    private fun ptsOf(img: Image): Long? = tagOf(img.timestamp)?.pts

    /** Acquires queued images (stale ones are closed) while one slot stays free for the bound image. */
    fun pull() {
        val r = reader
        while (queue.size + (if (bound != null) 1 else 0) < MAX_IMAGES - 1) {
            val img = try {
                r.acquireNextImage()
            } catch (e: IllegalStateException) {
                null
            } ?: return
            if (tagOf(img.timestamp) == null) {
                // A frame of an old epoch, or one whose metadata has not arrived yet: the metadata
                // listener runs before the release, so an untagged image is stale.
                img.close()
                stats.staleImages++
                continue
            }
            queue.addLast(img)
        }
    }

    private fun bind(img: Image): Boolean {
        val hb = img.hardwareBuffer ?: run {
            img.close()
            return false
        }
        val egl = try {
            HwbImport.nativeCreateImage(hb)
        } finally {
            hb.close()
        }
        if (egl == 0L || !HwbImport.nativeBindOes(tex, egl)) {
            if (egl != 0L) HwbImport.nativeDestroyImage(egl)
            img.close()
            return false
        }
        if (boundEgl != 0L) HwbImport.nativeDestroyImage(boundEgl)
        bound?.close()
        bound = img
        boundEgl = egl
        latchedPts = ptsOf(img) ?: latchedPts
        latchedEpoch = epoch
        boundTexture = textureOf(img)
        stats.latched++
        return true
    }

    private fun textureOf(img: Image): SourceTexture {
        val item = items.getOrNull(assigned)
        val crop: Rect = try {
            img.cropRect
        } catch (e: IllegalStateException) {
            Rect(0, 0, img.width, img.height)
        }
        return DeckTextures.texture(tex, img.width, img.height, crop.left, crop.top, crop.width(), crop.height(), item?.rotation ?: 0)
    }

    /** Shows the newest frame of the current epoch (paused, seeking or idle deck). */
    fun latchNewest() {
        pull()
        while (queue.size > 1) queue.removeFirst().close()
        queue.removeFirstOrNull()?.let { bind(it) }
        pull()
    }

    /** Latches the frame with pts [rule] when it is (or becomes) the head of the queue; older frames are dropped. */
    fun latchFor(rule: Long) {
        pull()
        if (latchedEpoch == epoch && latchedPts == rule) return
        // Drop frames before the rule frame.
        while (queue.isNotEmpty() && (ptsOf(queue.first()) ?: Long.MIN_VALUE) < rule) queue.removeFirst().close()
        val head = queue.firstOrNull()
        if (head != null && ptsOf(head) == rule) {
            queue.removeFirst()
            bind(head)
        }
        pull()
    }

    private fun hasQueuedFrame(): Boolean {
        pull()
        return queue.isNotEmpty()
    }

    /** Whether the frame with pts [rule] of the current position is latched or queued. */
    fun holds(rule: Long): Boolean {
        pull()
        if (latchedEpoch == epoch && latchedPts == rule) return true
        return queue.any { ptsOf(it) == rule }
    }

    /** Whether the latched frame is [rule] of the current epoch. */
    fun hasLatched(rule: Long): Boolean = latchedEpoch == epoch && latchedPts == rule

    /** Whether any frame of the current epoch is latched. */
    val hasEpochFrame: Boolean get() = latchedEpoch == epoch && latchedPts != Long.MIN_VALUE

    /** Whether the deck's frames are already past [rule] (its rule frame will not come any more). */
    fun passed(rule: Long): Boolean {
        if (latchedEpoch == epoch && latchedPts != Long.MIN_VALUE && latchedPts > rule) return true
        val headPts = queue.firstOrNull()?.let { ptsOf(it) } ?: return false
        return headPts > rule
    }

    /** The texture of the latched frame (null when nothing is latched). */
    val texture: SourceTexture? get() = if (latchedPts == Long.MIN_VALUE) null else boundTexture

    /** Plays or pauses (no-op when unchanged). */
    fun setPlaying(on: Boolean) {
        if (player.playWhenReady != on) player.playWhenReady = on
    }

    /** Sets the plan speed of the current item (no-op when unchanged). */
    fun setSpeed(speed: Double) {
        val s = speed.toFloat().coerceIn(MIN_SPEED, MAX_SPEED)
        if (player.playbackParameters.speed != s) player.setPlaybackSpeed(s)
    }

    /** Replaces the ImageReader by one of [w] × [h] (only while paused; the deck is unpositioned). */
    fun resize(w: Int, h: Int) {
        if (w == readerW && h == readerH) return
        val old = reader
        val oldSurface = surface
        reader = newReader(w, h)
        surface = reader.surface
        player.setVideoSurface(surface)
        unbind()
        bumpEpoch()
        assigned = -1
        oldSurface.release()
        old.close()
        readerW = w
        readerH = h
    }

    private fun unbind() {
        if (boundEgl != 0L) HwbImport.nativeDestroyImage(boundEgl)
        boundEgl = 0L
        bound?.close()
        bound = null
        boundTexture = null
        latchedPts = Long.MIN_VALUE
        latchedEpoch = -1
    }

    /** Releases the player, the reader and the texture (GL context current). */
    fun release() {
        player.release()
        queue.forEach { it.close() }
        queue.clear()
        unbind()
        surface.release()
        reader.close()
        GLES20.glDeleteTextures(1, intArrayOf(tex), 0)
    }

    companion object {
        /** Images per deck (one bound + up to MAX_IMAGES − 2 queued). */
        const val MAX_IMAGES = 8
        /** Verbose deck and frame-clock logs under the tag AND16DBG (pts and positions only; off in production). */
        @Volatile
        @JvmStatic
        var DEBUG = false
        const val MAX_TAGS = 512
        const val MAX_RECOVERIES = 5
        const val READY_WITHOUT_FRAME_MS = 600L
        const val MIN_SPEED = 0.1f
        const val MAX_SPEED = 10f
    }
}

/** Texture-coordinate transforms of deck frames (pure; HardwareBuffer row 0 = top). */
object DeckTextures {
    /**
     * The SourceTexture of a deck frame: buffer [bufW]×[bufH], visible crop rect, shown upright
     * after the source's display [rotation] (MediaCodec renders rotated sources unrotated into the
     * buffer and signals the rotation as a buffer transform, which an ImageReader consumer does not
     * apply). Width and height are the upright display size.
     */
    fun texture(id: Int, bufW: Int, bufH: Int, cropL: Int, cropT: Int, cropW: Int, cropH: Int, rotation: Int): SourceTexture {
        val m = transform(bufW, bufH, cropL, cropT, cropW, cropH, rotation)
        val (w, h) = if (rotation % 180 != 0) cropH to cropW else cropW to cropH
        return SourceTexture(id, w.coerceAtLeast(1), h.coerceAtLeast(1), SourceTexture.EXTERNAL_OES, m)
    }

    /**
     * Column-major 3×3 matrix mapping display texture coordinates (u, v) (row 0 = top) to buffer
     * coordinates: rotation first (display → crop space), then the crop inside the buffer.
     */
    fun transform(bufW: Int, bufH: Int, cropL: Int, cropT: Int, cropW: Int, cropH: Int, rotation: Int): FloatArray {
        // Rotation: display (u, v) → crop-space (x, y), both row 0 = top.
        val rot = when (Math.floorMod(rotation, 360)) {
            90 -> floatArrayOf(0f, -1f, 0f, 1f, 0f, 0f, 0f, 1f, 1f) // (x, y) = (v, 1 − u)
            180 -> floatArrayOf(-1f, 0f, 0f, 0f, -1f, 0f, 1f, 1f, 1f) // (1 − u, 1 − v)
            270 -> floatArrayOf(0f, 1f, 0f, -1f, 0f, 0f, 1f, 0f, 1f) // (1 − v, u)
            else -> floatArrayOf(1f, 0f, 0f, 0f, 1f, 0f, 0f, 0f, 1f)
        }
        val bw = bufW.coerceAtLeast(1).toFloat()
        val bh = bufH.coerceAtLeast(1).toFloat()
        val sx = cropW / bw
        val sy = cropH / bh
        val tx = cropL / bw
        val ty = cropT / bh
        val crop = floatArrayOf(sx, 0f, 0f, 0f, sy, 0f, tx, ty, 1f)
        return mul(crop, rot)
    }

    /** a · b (column-major 3×3). */
    fun mul(a: FloatArray, b: FloatArray): FloatArray {
        val out = FloatArray(9)
        for (c in 0 until 3) for (r in 0 until 3) {
            var s = 0f
            for (k in 0 until 3) s += a[k * 3 + r] * b[c * 3 + k]
            out[c * 3 + r] = s
        }
        return out
    }

    /** Applies [m] to (u, v, 1). */
    fun apply(m: FloatArray, u: Float, v: Float): Pair<Float, Float> =
        (m[0] * u + m[3] * v + m[6]) to (m[1] * u + m[4] * v + m[7])
}

/**
 * Gain envelope of an audio deck (AND-08's semantics: linear between the plan's [t, g] keys, 0–2,
 * held outside, evaluated at the plan time of each sample). Runs before the sink's speed stage, so
 * it sees source-rate samples: sample n after a flush is source time `origin + n·1e6/R`, mapped to
 * plan time through the segment's map. The deck sets the origin before each seek ([setSchedule]);
 * the flush that follows the seek adopts it.
 */
class EnvelopeGainProcessor : BaseAudioProcessor() {
    /** The envelope and time mapping of one positioning. */
    class Schedule(val originSourceUs: Long, val planTimeOf: (Long) -> Long, val gain: Keyframes)

    @Volatile private var pending: Schedule? = null
    private var active: Schedule? = null
    private var frames = 0L

    /** The schedule the next flush adopts. */
    fun setSchedule(schedule: Schedule) {
        pending = schedule
    }

    override fun onConfigure(inputAudioFormat: AudioProcessor.AudioFormat): AudioProcessor.AudioFormat {
        if (inputAudioFormat.encoding != C.ENCODING_PCM_16BIT && inputAudioFormat.encoding != C.ENCODING_PCM_FLOAT) {
            throw AudioProcessor.UnhandledAudioFormatException(inputAudioFormat)
        }
        return inputAudioFormat
    }

    override fun onFlush(streamMetadata: AudioProcessor.StreamMetadata) {
        active = pending
        frames = 0L
    }

    override fun onReset() {
        active = null
        frames = 0L
    }

    override fun queueInput(inputBuffer: ByteBuffer) {
        val remaining = inputBuffer.remaining()
        if (remaining == 0) return
        val fmt = inputAudioFormat
        val channels = fmt.channelCount.coerceAtLeast(1)
        val float = fmt.encoding == C.ENCODING_PCM_FLOAT
        val bytesPerSample = if (float) 4 else 2
        val frameBytes = bytesPerSample * channels
        val count = remaining / frameBytes
        val out = replaceOutputBuffer(count * frameBytes)
        val schedule = active ?: pending.also { active = it }
        val rate = fmt.sampleRate.coerceAtLeast(1)
        val inBuf = inputBuffer.order(ByteOrder.nativeOrder())
        var g = 1.0
        for (n in 0 until count) {
            if (schedule != null && (n % GAIN_BLOCK == 0)) {
                val source = schedule.originSourceUs + (frames + n) * 1_000_000L / rate
                g = schedule.gain.valueAt(schedule.planTimeOf(source)).coerceIn(0.0, 2.0)
            }
            for (c in 0 until channels) {
                if (float) {
                    out.putFloat(inBuf.float * g.toFloat())
                } else {
                    val v = (inBuf.short * g).toInt().coerceIn(Short.MIN_VALUE.toInt(), Short.MAX_VALUE.toInt())
                    out.putShort(v.toShort())
                }
            }
        }
        frames += count
        // Any partial frame left in the input is consumed (never happens with whole frames).
        inputBuffer.position(inputBuffer.limit())
        out.flip()
    }

    private companion object {
        /** Samples per gain evaluation (≈ 0.7 ms at 48 kHz; the envelope is linear between keys). */
        const val GAIN_BLOCK = 32
    }
}

/** The audio sink of an audio deck: reports its position [leadUs] ahead (V-N23 signed offset). */
class OffsetAudioSink(sink: AudioSink, @Volatile var leadUs: Long) : ForwardingAudioSink(sink) {
    override fun getCurrentPositionUs(sourceEnded: Boolean): Long {
        val p = super.getCurrentPositionUs(sourceEnded)
        if (p == AudioSink.CURRENT_POSITION_NOT_SET || p == C.TIME_UNSET) return p
        return p + leadUs
    }
}

/** An audio deck of one lane (file header). */
@RequiresApi(29)
internal class AudioDeck(
    env: DeckEnv,
    val index: Int,
    items: List<AudioItem>,
    stream: Int,
    leadUs: Long,
) {
    val stats = DeckStats()
    private val gain = EnvelopeGainProcessor()
    private lateinit var sink: OffsetAudioSink

    /** The player. */
    val player: ExoPlayer

    /** The item this deck is positioned on, or -1. */
    var assigned = -1
        private set

    var items: List<AudioItem> = items
        private set

    var lastCorrectionMs = 0L
    private var prepared = false

    /** Uptime when playback (re)started, for the audio-master warm-up. */
    var playingSinceMs = 0L
        private set

    init {
        val ctx = env.context
        val renderers = object : DefaultRenderersFactory(ctx) {
            override fun buildAudioSink(context: Context, enableFloatOutput: Boolean, enableAudioTrackPlaybackParams: Boolean): AudioSink {
                val base = DefaultAudioSink.Builder(context)
                    .setAudioProcessors(arrayOf<AudioProcessor>(gain))
                    .build()
                return OffsetAudioSink(base, leadUs).also { sink = it }
            }
        }
        env.codecSelector?.let { renderers.setMediaCodecSelector(it) }
        val builder = ExoPlayer.Builder(ctx, renderers)
            .setLooper(env.looper)
            .setLoadControl(deckLoadControl())
            .setMediaSourceFactory(deckMediaSources(ctx))
        if (stream > 0) builder.setTrackSelector(AudioStreamTrackSelector(ctx, stream))
        player = builder.build()
        player.setSeekParameters(SeekParameters.EXACT)
        player.pauseAtEndOfMediaItems = true
        player.trackSelectionParameters = player.trackSelectionParameters.buildUpon()
            .setTrackTypeDisabled(C.TRACK_TYPE_VIDEO, true)
            .setTrackTypeDisabled(C.TRACK_TYPE_TEXT, true)
            .setTrackTypeDisabled(C.TRACK_TYPE_IMAGE, true)
            .build()
        player.addListener(object : Player.Listener {
            override fun onPlayerError(error: PlaybackException) {
                if (stats.recoveries < VideoDeck.MAX_RECOVERIES) {
                    stats.recoveries++
                    player.prepare()
                } else {
                    env.deckFailed(error)
                }
            }
        })
        setItemsInternal(items)
    }

    private fun setItemsInternal(next: List<AudioItem>) {
        items = next
        assigned = -1
        if (next.isEmpty()) {
            player.clearMediaItems()
        } else {
            player.setMediaItems(
                next.map { item ->
                    MediaItem.Builder().setUri(item.uri.toUri())
                        .setClippingConfiguration(
                            MediaItem.ClippingConfiguration.Builder()
                                .setStartPositionUs(item.clipStartUs)
                                .setEndPositionUs(item.clipEndUs)
                                .build(),
                        )
                        .build()
                },
                true,
            )
        }
    }

    /** Replaces the playlist; the deck is unpositioned. */
    fun setItems(next: List<AudioItem>) {
        player.playWhenReady = false
        setItemsInternal(next)
    }

    /** The A/V offset (V-N23), applied from the next position report. */
    fun setLeadUs(us: Long) {
        if (this::sink.isInitialized) sink.leadUs = us
    }

    /** Seeks to item [i] at plan time [t]. */
    fun position(i: Int, t: Long) {
        val item = items[i]
        val source = item.sourceAt(t)
        val ms = item.positionMs(source)
        gain.setSchedule(EnvelopeGainProcessor.Schedule(item.clipStartUs + ms * 1000L, item::planTimeOf, item.gain))
        if (!prepared || player.playbackState == Player.STATE_IDLE) {
            player.prepare()
            prepared = true
        }
        val s = item.speedAt(t)
        applySpeed(item, s)
        player.seekTo(i, ms)
        assigned = i
        stats.seeks++
    }

    private fun applySpeed(item: AudioItem, speed: Double) {
        val sp = speed.toFloat().coerceIn(VideoDeck.MIN_SPEED, VideoDeck.MAX_SPEED)
        val pitch = if (item.seg.pitch) 1f else sp
        val p = player.playbackParameters
        if (p.speed != sp || p.pitch != pitch) player.playbackParameters = PlaybackParameters(sp, pitch)
    }

    /** Sets the plan speed at plan time [t] for the assigned item. */
    fun setSpeedAt(t: Long) {
        val item = items.getOrNull(assigned) ?: return
        applySpeed(item, item.speedAt(t))
    }

    /** Plays or pauses. */
    fun setPlaying(on: Boolean) {
        if (player.playWhenReady != on) {
            player.playWhenReady = on
            if (on) playingSinceMs = android.os.SystemClock.uptimeMillis()
        }
    }

    /** The plan time the deck plays now (null when not positioned or not ready). */
    fun planTimeNow(): Long? {
        val item = items.getOrNull(assigned) ?: return null
        if (player.playbackState != Player.STATE_READY || player.currentMediaItemIndex != assigned) return null
        return item.planTimeOf(item.clipStartUs + player.currentPosition * 1000L)
    }

    fun release() {
        player.release()
    }
}
