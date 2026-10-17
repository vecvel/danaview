@file:OptIn(UnstableApi::class, ExperimentalApi::class)

package com.vecvel.danaview.spike.engine

import android.content.Context
import android.graphics.ImageFormat
import android.graphics.SurfaceTexture
import android.hardware.HardwareBuffer
import android.media.Image
import android.media.ImageReader
import android.net.Uri
import android.opengl.EGL14
import android.opengl.EGLConfig
import android.opengl.EGLContext
import android.opengl.EGLDisplay
import android.opengl.EGLExt
import android.opengl.EGLSurface
import android.opengl.GLES11Ext
import android.opengl.GLES20
import android.opengl.GLES30
import android.os.Handler
import android.os.HandlerThread
import android.os.SystemClock
import android.view.Choreographer
import android.view.Surface
import androidx.media3.common.MediaItem
import androidx.media3.common.Player
import androidx.media3.common.util.ExperimentalApi
import androidx.media3.common.util.GlProgram
import androidx.media3.common.util.GlUtil
import androidx.media3.common.util.UnstableApi
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.SeekParameters
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.ConcurrentLinkedQueue
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference
import kotlin.math.abs

/**
 * AND-01 prototype of the AND-16 contingency engine (ARCH §13.3 "Contingency", D-36), built
 * because CompositionPlayer 1.11.1 stalls at secondary-sequence boundaries (R1 no-go).
 * Per packing slot, two decks (an [ExoPlayer] rendering into its own PRIVATE [ImageReader] whose
 * HardwareBuffers are imported as OES textures): one plays the current layer, the other pre-rolls
 * the next layer paused at its first frame. A frame clock at the project fps (Choreographer on the
 * preview thread) decides the output frame k; the players run [leadFrames] ahead of it, so each
 * deck's queue already holds the rule frame of k when k is composited. Gaps and gating follow the
 * plan, not Media3. Each slot's rule frame is latched and composited bottom → top with the place
 * shader and the straight-alpha blend onto the output surface (the SurfaceProducer stand-in).
 * Drift > 1 frame is corrected by seeking the late player (at most once per
 * [correctionCooldownMs]). Audio slots are not prototyped.
 *
 * Everything (EGL, GL, players' application looper, Choreographer) runs on one preview thread.
 */
class ContingencyEngineProto(
    private val context: Context,
    private val plan: SpikePlan,
    private val store: ParamStore,
    private val regions: List<ProbeRegion>,
    private val frameSource: FrameSource = FrameSource.IMAGE_READER,
    private val correctionCooldownMs: Long = 1000,
    /**
     * Slot players run this many output frames ahead of the compositor clock; their frames wait in
     * the slot's ImageReader queue (IMAGE_READER only). 0 = players and compositor on one clock.
     */
    private val leadFrames: Int = 2,
    /**
     * Two decks (player + ImageReader + OES texture) per slot: while one plays item i, the other
     * pre-rolls item i + 1 paused at its first frame, so a cut never waits for a seek.
     * false = one player per slot that seeks at every item change.
     */
    private val standby: Boolean = true,
    /**
     * Never show a slot frame other than its rule frame: an output frame whose slot frames are
     * late is not drawn (it becomes a dropped frame). false = draw the latest frame available.
     */
    private val holdLateFrames: Boolean = true,
    /**
     * The frame clock stops while a playing deck rebuffers (ExoPlayer STATE_BUFFERING: its own
     * clock has stopped too), for at most [MAX_STALL_MS] at a time, like a player's rebuffer.
     * false = the clock runs on and the late deck is dropped, then drift-corrected by a seek
     * (which makes it rebuffer again on a starved decoder).
     */
    private val stallOnRebuffer: Boolean = true,
) : AutoCloseable {
    /** Where a slot player's decoded frames land. */
    enum class FrameSource {
        /** One [SurfaceTexture] per deck: only the newest frame can be latched. */
        SURFACE_TEXTURE,

        /**
         * One [ImageReader] (PRIVATE, GPU-sampled) per deck: several decoded frames are held and the
         * one whose pts is the output frame's rule frame is imported (HardwareBuffer → EGLImage → OES).
         */
        IMAGE_READER,
    }

    data class SlotStats(
        val seq: Int,
        var seeks: Int = 0,
        var prerolls: Int = 0,
        var driftCorrections: Int = 0,
        var latched: Int = 0,
        var behind: Int = 0,
        var ahead: Int = 0,
        var staleImages: Int = 0,
        var metadataCallbacks: Int = 0,
        var imagesAcquired: Int = 0,
        /** Decks re-prepared after a player error (e.g. a decoder failure on a starved host). */
        var recoveries: Int = 0,
        /** Exact seeks re-issued to a deck stuck in BUFFERING without its target frame ([STUCK_RESEEK_MS]). */
        var reseeks: Int = 0,
    )

    data class Result(
        val ended: Boolean,
        val wallMs: Double,
        val composedFrames: Int,
        val skippedFrames: Int,
        /** Composite attempts deferred because a slot's rule frame was late ([holdLateFrames]). */
        val heldAttempts: Int,
        /** Output frames dropped because a slot's rule frame had already passed (or never came). */
        val missedFrames: Int,
        val compositeMs: List<Double>,
        val slots: List<SlotStats>,
        /** Times the frame clock stopped for a rebuffering deck ([stallOnRebuffer]) and the total stop time. */
        val rebuffers: Int = 0,
        val rebufferMs: Double = 0.0,
    )

    private val thread = HandlerThread("danaview-preview-contingency").apply { start() }
    private val handler = Handler(thread.looper)

    /** Composited output frames as probe readings (pts = P(k)). */
    val frames = ConcurrentLinkedQueue<ProbeFrame>()

    /** Source pts of a released frame, tagged with the deck epoch it was rendered in. */
    private data class Tag(val epoch: Int, val pts: Long)

    /** One player with its own frame queue and texture; positioned on one layer at a time. */
    private inner class Deck(val slot: Slot, index: Int) {
        val tex: Int
        val st: SurfaceTexture?
        val reader: ImageReader?
        val surface: Surface
        /** IMAGE_READER: acquired images not yet shown (pts order), the bound image and its EGLImage. */
        val queue = ArrayDeque<Image>()
        var bound: Image? = null
        var boundEglImage = 0L
        val player: ExoPlayer
        val ptsByRelease = ConcurrentHashMap<Long, Tag>()
        @Volatile var pending = 0
        /** Bumped on every reposition; frames released before it are stale. */
        @Volatile var epoch = 0
        var latchedPts = Long.MIN_VALUE
        var lastCorrectionMs = 0L
        /** Layer index this deck is positioned on, or -1 (after prepare, deck 0 sits on layer 0's first frame). */
        var assigned = if (index == 0) 0 else -1
        val texMatrix = FloatArray(16)

        init {
            val ids = IntArray(1)
            GLES20.glGenTextures(1, ids, 0)
            tex = ids[0]
            GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, tex)
            GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_MIN_FILTER, GLES20.GL_LINEAR)
            GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_MAG_FILTER, GLES20.GL_LINEAR)
            if (frameSource == FrameSource.SURFACE_TEXTURE) {
                st = SurfaceTexture(tex).also { it.setOnFrameAvailableListener({ pending++ }, handler) }
                reader = null
                surface = Surface(st)
            } else {
                st = null
                reader = ImageReader.newInstance(plan.canvasW, plan.canvasH, ImageFormat.PRIVATE, MAX_IMAGES, HardwareBuffer.USAGE_GPU_SAMPLED_IMAGE)
                    .also { r -> r.setOnImageAvailableListener({ pull() }, handler) }
                surface = reader.surface
            }
            player = ExoPlayer.Builder(context).setLooper(thread.looper).build()
            player.setSeekParameters(SeekParameters.EXACT)
            // Never roll into the next playlist item: the other deck owns it.
            player.pauseAtEndOfMediaItems = true
            player.setVideoSurface(surface)
            player.setVideoFrameMetadataListener { pts, releaseNs, _, _ ->
                slot.stats.metadataCallbacks++
                ptsByRelease[releaseNs] = Tag(epoch, pts)
                if (ptsByRelease.size > 512) ptsByRelease.keys.sorted().take(256).forEach { ptsByRelease.remove(it) }
            }
            player.addListener(object : Player.Listener {
                override fun onPlayerError(error: androidx.media3.common.PlaybackException) {
                    lastError = "${error.errorCodeName}: ${generateSequence<Throwable>(error) { it.cause }.last().let { "${it.javaClass.simpleName} ${it.message}" }}"
                    // Recover like the engine must (codec errors and reclaimed decoders happen on
                    // devices too): re-prepare at the same item and position; frames of the old
                    // epoch are dropped; the frame clock's drift correction re-aligns the deck.
                    if (slot.stats.recoveries < MAX_RECOVERIES) {
                        slot.stats.recoveries++
                        epoch++
                        queue.forEach { it.close() }
                        queue.clear()
                        player.prepare()
                    }
                }
            })
            player.setMediaItems(slot.items)
            // The standby deck prepares (and takes a decoder) only when it first pre-rolls.
            if (index == 0) player.prepare()
        }

        /** Last player error (diagnostics). */
        var lastError: String? = null

        /**
         * Seeks to layer [i] at item position [ms] (exact); drops queued frames of the old position.
         * [force] re-issues the seek even when the player already reports that position (watchdog).
         */
        fun position(i: Int, ms: Long, force: Boolean = false) {
            // ExoPlayer ignores a seek to the position it is paused at (no new frame would come):
            // keep the frame it already rendered there.
            if (!force && assigned == i && !player.playWhenReady && player.currentMediaItemIndex == i && player.currentPosition == ms) {
                return
            }
            epoch++
            if (player.playbackState == Player.STATE_IDLE) player.prepare()
            player.seekTo(i, ms)
            assigned = i
            queue.forEach { it.close() }
            queue.clear()
        }

        private fun tagOf(releaseNs: Long): Tag? = ptsByRelease[releaseNs]?.takeIf { it.epoch == epoch }

        /** IMAGE_READER: acquires queued images (stale ones are closed) while one slot stays free for the bound image. */
        fun pull() {
            val r = reader ?: return
            while (queue.size + (if (bound != null) 1 else 0) < MAX_IMAGES - 1) {
                val img = try {
                    r.acquireNextImage()
                } catch (e: IllegalStateException) {
                    null
                } ?: return
                slot.stats.imagesAcquired++
                if (tagOf(img.timestamp) == null) {
                    img.close()
                    slot.stats.staleImages++
                    continue
                }
                queue.addLast(img)
            }
        }

        private fun ptsOf(img: Image): Long? = tagOf(img.timestamp)?.pts

        private fun bind(img: Image) {
            val hb = img.hardwareBuffer ?: return
            val egl = HwbImport.nativeCreateImage(hb)
            hb.close()
            check(egl != 0L) { "eglCreateImageKHR failed" }
            check(HwbImport.nativeBindOes(tex, egl)) { "glEGLImageTargetTexture2DOES failed" }
            if (boundEglImage != 0L) HwbImport.nativeDestroyImage(boundEglImage)
            bound?.close()
            bound = img
            boundEglImage = egl
            latchedPts = ptsOf(img) ?: latchedPts
            slot.stats.latched++
        }

        /** Shows the newest available frame (paused / seeking / idle deck). */
        fun latchNewest() {
            if (st != null) {
                while (pending > 0) {
                    st.updateTexImage()
                    pending--
                    slot.stats.latched++
                    latchedPts = tagOf(st.timestamp)?.pts ?: latchedPts
                }
                return
            }
            pull()
            while (queue.size > 1) queue.removeFirst().close()
            queue.removeFirstOrNull()?.let { bind(it) }
            pull()
        }

        /** Latches the frame for rule-frame pts [expectedPts] (± ½ frame) as well as the frame source allows. */
        fun latchFor(expectedPts: Long, halfFrameUs: Long) {
            if (st != null) {
                while (pending > 0 && (latchedPts == Long.MIN_VALUE || latchedPts < expectedPts - halfFrameUs)) {
                    st.updateTexImage()
                    pending--
                    slot.stats.latched++
                    latchedPts = tagOf(st.timestamp)?.pts ?: latchedPts
                }
            } else {
                pull()
                // Drop frames older than the newest one that is not in the future.
                while (queue.size >= 2 && (ptsOf(queue.elementAt(1)) ?: Long.MAX_VALUE) <= expectedPts + halfFrameUs) queue.removeFirst().close()
                val head = queue.firstOrNull()
                val headPts = head?.let { ptsOf(it) }
                if (head != null && headPts != null && headPts <= expectedPts + halfFrameUs) {
                    queue.removeFirst()
                    bind(head)
                }
                pull()
            }
            if (latchedPts < expectedPts - halfFrameUs) slot.stats.behind++ else if (latchedPts > expectedPts + halfFrameUs) slot.stats.ahead++
        }

        /** True when the deck's frames are already past [expectedPts]: its rule frame will not come any more. */
        fun passed(expectedPts: Long, halfFrameUs: Long): Boolean {
            if (latchedPts != Long.MIN_VALUE && latchedPts > expectedPts + halfFrameUs) return true
            val headPts = queue.firstOrNull()?.let { ptsOf(it) } ?: return false
            return headPts > expectedPts + halfFrameUs
        }

        /** Texture coordinate matrix: SurfaceTexture's own, or a y flip for HardwareBuffer images (row 0 = top). */
        fun matrix(): FloatArray {
            if (st != null) st.getTransformMatrix(texMatrix) else FLIP_Y.copyInto(texMatrix)
            return texMatrix
        }

        fun release() {
            player.release()
            queue.forEach { it.close() }
            queue.clear()
            if (boundEglImage != 0L) HwbImport.nativeDestroyImage(boundEglImage)
            bound?.close()
            reader?.close()
            surface.release()
            st?.release()
            GLES20.glDeleteTextures(1, intArrayOf(tex), 0)
        }
    }

    /** One packing slot (visual sequence): its layers as one clipped playlist, played by 1 or 2 decks. */
    private inner class Slot(val seq: Int) {
        val layers = plan.layersOf(seq)
        val clipStart = LongArray(layers.size)
        val stats = SlotStats(seq)
        val items: List<MediaItem>
        val decks: List<Deck>

        init {
            val mapper = SpikeCompositionMapper(context)
            items = layers.mapIndexed { i, l ->
                val (start, end) = mapper.clipping(plan, l, EpsilonMode.SNAP_TO_RULE_FRAME)
                clipStart[i] = start
                MediaItem.Builder().setUri(Uri.parse(l.uri))
                    .setClippingConfiguration(MediaItem.ClippingConfiguration.Builder().setStartPositionUs(start).setEndPositionUs(end).build())
                    .build()
            }
            decks = List(if (standby) 2 else 1) { Deck(this, it) }
        }

        fun deckFor(i: Int): Deck = decks[i % decks.size]

        /** Layer index active at plan time [t], or -1. */
        fun activeAt(t: Long): Int = layers.indexOfFirst {
            t >= GridTime.timeOfFrame(it.k0, plan.gridFps) && t < GridTime.timeOfFrame(it.k1, plan.gridFps)
        }

        fun nextAfter(t: Long): Int = layers.indexOfFirst { GridTime.timeOfFrame(it.k0, plan.gridFps) > t }

        fun startsAfter(i: Int, t: Long): Boolean = GridTime.timeOfFrame(layers[i].k0, plan.gridFps) > t

        /** Source time of layer [i] at plan time [t]. */
        fun sourceAt(i: Int, t: Long): Long {
            val l = layers[i]
            return l.srcStartUs + ((t - GridTime.timeOfFrame(l.k0, plan.gridFps)) * l.speed.toDouble()).toLong()
        }

        /** Rule frame (ARCH §11.5) of layer [i] at plan time [t]. */
        fun ruleAt(i: Int, t: Long): Long =
            SpikeCompositionMapper.Companion.SourceFrameTimes.ruleFramePts(context, layers[i].uri, sourceAt(i, t))

        /** Item position (ms) of layer [i] at plan time [t]. */
        fun positionMs(i: Int, t: Long): Long = ((sourceAt(i, t) - clipStart[i]) / 1000).coerceAtLeast(0)

        fun release() = decks.forEach { it.release() }
    }

    private var display: EGLDisplay = EGL14.EGL_NO_DISPLAY
    private var eglContext: EGLContext = EGL14.EGL_NO_CONTEXT
    private var eglSurface: EGLSurface = EGL14.EGL_NO_SURFACE
    private lateinit var program: GlProgram
    private val slots = ArrayList<Slot>()
    private lateinit var row: ByteBuffer

    private var playing = false
    /** Frame clock and deck speed of the current [play] (1 = real time). */
    private var clockRate = 1.0
    private var lastTickNs = 0L
    private var stallStartNs = 0L
    private var rebuffers = 0
    private var rebufferNs = 0L
    /** Decks paused while the clock is stopped for a rebuffering deck. */
    private val stallPaused = ArrayList<Deck>()
    private var startT = 0L
    private var wall0Ns = 0L
    private var lastK = -1L
    private var skipped = 0
    private var held = 0
    private var missed = 0
    /** First reasons a frame was held (diagnostics). */
    val holdReasons = ArrayList<String>()
    private val framePeriodNs get() = 1_000_000_000L / plan.fps
    private var composed = 0
    private val compositeMs = ArrayList<Double>()
    private var ended = false
    private var endLatch: CountDownLatch? = null

    private fun <T> onThread(block: () -> T): T {
        val r = AtomicReference<Any?>()
        val f = AtomicReference<Throwable?>()
        val latch = CountDownLatch(1)
        handler.post {
            try {
                r.set(block())
            } catch (t: Throwable) {
                f.set(t)
            } finally {
                latch.countDown()
            }
        }
        check(latch.await(60, TimeUnit.SECONDS)) { "preview thread blocked" }
        f.get()?.let { throw it }
        @Suppress("UNCHECKED_CAST")
        return r.get() as T
    }

    /** Creates EGL on [output] and one player + SurfaceTexture per visual slot. */
    fun attach(output: Surface) = onThread {
        display = EGL14.eglGetDisplay(EGL14.EGL_DEFAULT_DISPLAY)
        val v = IntArray(2)
        check(EGL14.eglInitialize(display, v, 0, v, 1))
        val attribs = intArrayOf(
            EGL14.EGL_RED_SIZE, 8, EGL14.EGL_GREEN_SIZE, 8, EGL14.EGL_BLUE_SIZE, 8, EGL14.EGL_ALPHA_SIZE, 8,
            EGL14.EGL_RENDERABLE_TYPE, EGLExt.EGL_OPENGL_ES3_BIT_KHR, EGL14.EGL_SURFACE_TYPE, EGL14.EGL_WINDOW_BIT, EGL14.EGL_NONE,
        )
        val configs = arrayOfNulls<EGLConfig>(1)
        val n = IntArray(1)
        check(EGL14.eglChooseConfig(display, attribs, 0, configs, 0, 1, n, 0) && n[0] > 0)
        eglContext = EGL14.eglCreateContext(display, configs[0], EGL14.EGL_NO_CONTEXT, intArrayOf(EGL14.EGL_CONTEXT_CLIENT_VERSION, 3, EGL14.EGL_NONE), 0)
        eglSurface = EGL14.eglCreateWindowSurface(display, configs[0], output, intArrayOf(EGL14.EGL_NONE), 0)
        check(EGL14.eglMakeCurrent(display, eglSurface, eglSurface, eglContext))
        program = GlProgram(PlaceShaders.VERTEX, OES_FRAGMENT).also {
            it.setBufferAttribute("aFramePosition", GlUtil.getNormalizedCoordinateBounds(), GlUtil.HOMOGENEOUS_COORDINATE_VECTOR_SIZE)
        }
        row = ByteBuffer.allocateDirect(plan.canvasW * 4).order(ByteOrder.nativeOrder())
        for (seq in 1..plan.visualSequenceCount) slots += Slot(seq)
    }

    private val halfFrameUs get() = 500_000L / plan.fps

    /** How far the slot players run ahead of the compositor clock (µs). */
    private val leadUs get() = if (frameSource == FrameSource.IMAGE_READER) leadFrames * 1_000_000L / plan.fps else 0L

    /** Next layer of [s] after the one at player time (or the next one after a gap), or -1. */
    private fun nextLayer(s: Slot, ip: Int, tp: Long): Int =
        if (ip >= 0) (ip + 1).takeIf { it < s.layers.size } ?: -1 else s.nextAfter(tp)

    /** Pre-rolls every slot for plan time [t] (paused) and waits until all positioned decks are READY. */
    private fun preroll(t: Long, timeoutMs: Long) {
        onThread {
            for (s in slots) {
                s.decks.forEach { it.player.playWhenReady = false }
                val ip = s.activeAt(t)
                if (ip >= 0) {
                    s.deckFor(ip).position(ip, s.positionMs(ip, t))
                    s.stats.seeks++
                }
                // Standby decks pre-roll later, inside the window (schedule), so the start is not a
                // burst of 2 × slots seeks.
            }
        }
        val end = SystemClock.elapsedRealtime() + timeoutMs
        while (SystemClock.elapsedRealtime() < end) {
            // Only the decks that show t0 must be ready; standby decks finish pre-rolling while playing.
            val ready = onThread {
                slots.all { s ->
                    val ip = s.activeAt(t)
                    ip < 0 || s.deckFor(ip).player.playbackState.let { it == Player.STATE_READY || it == Player.STATE_ENDED }
                }
            }
            if (ready) return
            Thread.sleep(10)
        }
        val states = onThread {
            slots.joinToString { s -> "seq${s.seq}:" + s.decks.joinToString("/") { d -> "${d.assigned}@${d.player.playbackState}${d.lastError?.let { " ($it)" } ?: ""}" } }
        }
        error("slots not ready after $timeoutMs ms ($states)")
    }

    /** Per-deck state for diagnostics. */
    fun debugState(): String = onThread {
        slots.joinToString(" | ") { s ->
            "seq${s.seq} md=${s.stats.metadataCallbacks} acq=${s.stats.imagesAcquired} stale=${s.stats.staleImages} " +
                s.decks.joinToString("/") { d -> "[on ${d.assigned} st=${d.player.playbackState} pos=${d.player.currentPosition} q=${d.queue.size} b=${d.bound != null} l=${d.latchedPts} e=${d.epoch} err=${d.lastError}]" }
        }
    }

    /**
     * Plays from output frame [fromK] to the end on the frame clock; returns when ended or after
     * [timeoutMs]. [rate] < 1 runs the frame clock and every deck at that speed (a slow-clock
     * correctness pass on an overloaded host: the same decks, pre-roll, lead and hold logic with
     * 1/[rate] times the wall time per output frame).
     */
    fun play(fromK: Long, timeoutMs: Long, rate: Double = 1.0): Result {
        require(rate > 0 && rate <= 1.0) { "rate must be in (0, 1]" }
        val t0 = GridTime.timeOfFrame(fromK, plan.fps)
        onThread {
            clockRate = rate
            slots.forEach { s -> s.decks.forEach { it.player.setPlaybackSpeed(rate.toFloat()) } }
        }
        preroll(t0, 60_000)
        Thread.sleep(300)
        holdReasons += "after preroll: " + debugState()
        val latch = CountDownLatch(1)
        val started = System.nanoTime()
        onThread {
            endLatch = latch
            frames.clear()
            compositeMs.clear()
            composed = 0
            skipped = 0
            held = 0
            missed = 0
            ended = false
            lastK = fromK - 1
            startT = t0
            // The players start now at t0; the compositor clock reaches t0 one lead later.
            wall0Ns = System.nanoTime() + (leadUs * 1000 / clockRate).toLong()
            lastTickNs = System.nanoTime()
            stallStartNs = 0L
            rebuffers = 0
            rebufferNs = 0L
            stallPaused.clear()
            playing = true
            schedule(t0 - leadUs, t0)
            Choreographer.getInstance().postFrameCallback(tick)
        }
        latch.await(timeoutMs, TimeUnit.MILLISECONDS)
        return onThread {
            playing = false
            slots.forEach { s -> s.decks.forEach { it.player.pause() } }
            Result(ended, (System.nanoTime() - started) / 1e6, composed, skipped, held, missed, compositeMs.toList(), slots.map { it.stats.copy() }, rebuffers, rebufferNs / 1e6)
        }
    }

    private val tick = object : Choreographer.FrameCallback {
        override fun doFrame(frameTimeNanos: Long) {
            if (!playing) return
            val now = System.nanoTime()
            val buffering = stallOnRebuffer && rebuffering(startT + ((now - wall0Ns) / 1000 * clockRate).toLong() + leadUs)
            if (buffering && (stallStartNs == 0L || (now - stallStartNs) / 1_000_000 < MAX_STALL_MS)) {
                if (stallStartNs == 0L) {
                    // Rebuffer: the other playing decks pause so they stay on the stopped clock.
                    stallStartNs = now
                    rebuffers++
                    for (s in slots) for (d in s.decks) {
                        if (d.player.playWhenReady && d.player.playbackState != Player.STATE_BUFFERING) {
                            d.player.playWhenReady = false
                            stallPaused += d
                        }
                    }
                }
                // Stop the clock: shift its origin by the time since the last vsync.
                wall0Ns += now - lastTickNs
                rebufferNs += now - lastTickNs
                lastTickNs = now
                Choreographer.getInstance().postFrameCallback(this)
                return
            }
            if (stallPaused.isNotEmpty()) {
                stallPaused.forEach { it.player.playWhenReady = true }
                stallPaused.clear()
            }
            if (!buffering) stallStartNs = 0L
            lastTickNs = now
            val tc = startT + ((now - wall0Ns) / 1000 * clockRate).toLong()
            if (tc >= plan.durUs) {
                skipped += (plan.durFrames - 1 - lastK).toInt().coerceAtLeast(0)
                ended = true
                playing = false
                endLatch?.countDown()
                return
            }
            schedule(tc, tc + leadUs)
            if (tc >= startT) {
                val k = GridTime.frameIndexOf(tc, plan.fps)
                if (k > lastK) {
                    // A held frame is retried on the next vsync while the clock runs on; when the
                    // clock reaches k + 1 first, k is dropped (counted in skippedFrames).
                    val r = composite(k, holdLateFrames)
                    when {
                        r == DRAWN -> {
                            if (k > lastK + 1) skipped += (k - lastK - 1).toInt()
                            lastK = k
                        }
                        r == MISSED -> {
                            // A slot's rule frame will not come (its deck already passed it): the
                            // frame is dropped (the previous output frame stays on screen).
                            skipped += (k - lastK).toInt()
                            missed++
                            lastK = k
                        }
                    }
                }
            }
            Choreographer.getInstance().postFrameCallback(this)
        }
    }

    /** True when a deck that plays the layer at player time [tp] is rebuffering (its clock has stopped). */
    private fun rebuffering(tp: Long): Boolean = slots.any { s ->
        val ip = s.activeAt(tp)
        if (ip < 0) return@any false
        val d = s.deckFor(ip)
        d.assigned == ip && d.player.playWhenReady && d.player.playbackState == Player.STATE_BUFFERING
    }

    /**
     * Drives the decks: the layer at player time [tp] plays on its deck (seeking only when the deck
     * is not already on it, or drifts > 1 frame), the next layer pre-rolls paused on the other deck
     * unless that deck still feeds the compositor at [tc]; every other deck pauses.
     */
    private fun schedule(tc: Long, tp: Long) {
        val nowMs = SystemClock.elapsedRealtime()
        for (s in slots) {
            val ic = s.activeAt(tc)
            val ip = s.activeAt(tp)
            var playingDeck: Deck? = null
            if (ip >= 0) {
                val d = s.deckFor(ip)
                playingDeck = d
                val want = s.positionMs(ip, tp)
                when {
                    d.assigned != ip || d.player.currentMediaItemIndex != ip -> {
                        d.position(ip, want)
                        s.stats.seeks++
                        d.lastCorrectionMs = nowMs
                    }
                    d.player.playbackState == Player.STATE_READY && d.player.isPlaying &&
                        abs(d.player.currentPosition - want) * 1000 > halfFrameUs * 2 &&
                        nowMs - d.lastCorrectionMs > correctionCooldownMs -> {
                        d.position(ip, want)
                        s.stats.driftCorrections++
                        d.lastCorrectionMs = nowMs
                    }
                }
                if (!d.player.playWhenReady) d.player.playWhenReady = true
            }
            val next = nextLayer(s, ip, tp)
            var standbyDeck: Deck? = null
            if (next >= 0) {
                val d = s.deckFor(next)
                if (d !== playingDeck) {
                    standbyDeck = d
                    val dueIn = GridTime.timeOfFrame(s.layers[next].k0, plan.gridFps) - tp
                    if (d.assigned != next && (ic < 0 || d.assigned != ic) && dueIn <= PREROLL_WINDOW_US) {
                        d.player.playWhenReady = false
                        d.position(next, 0)
                        s.stats.prerolls++
                    }
                }
            }
            for (d in s.decks) {
                if (d === playingDeck) continue
                val feeding = ic >= 0 && d.assigned == ic
                if (!feeding && d.player.playWhenReady) d.player.playWhenReady = false
                if (d === standbyDeck && d.assigned == next && d.player.playWhenReady) d.player.playWhenReady = false
            }
        }
    }

    /**
     * Composites output frame [k] from the latched deck textures and reads the probe rows.
     * With [hold], a frame for which some active slot has not latched its rule frame yet is not
     * drawn (returns false; the frame clock moves on, so a late frame becomes a dropped frame,
     * never a wrong one).
     */
    private fun composite(k: Long, hold: Boolean = false): Int {
        val started = System.nanoTime()
        val tk = GridTime.timeOfFrame(k, plan.fps)
        val pts = GridTime.platformTimeOfFrame(k, plan.fps)
        // 1. Latch every slot's rule frame (bottom → top), draining idle decks.
        val draws = ArrayList<Pair<Deck, LayerParams>>()
        var allExact = true
        var anyPassed = false
        for (s in slots.asReversed()) { // bottom sequence first; sequence 1 is the top
            val i = s.activeAt(tk)
            val d = if (i >= 0) s.deckFor(i) else null
            for (other in s.decks) {
                if (other === d) continue
                // A deck holding an upcoming layer keeps its queue (its first frames); idle decks drain.
                if (other.assigned >= 0 && s.startsAfter(other.assigned, tk)) other.pull() else other.latchNewest()
            }
            if (d == null || i < 0) continue
            val p = store.activeAt(s.seq, pts, plan.fps) ?: continue
            if (d.assigned != i) {
                allExact = false
                if (hold && holdReasons.size < 12) holdReasons += "k=$k seq${s.seq} deck on ${d.assigned}, layer $i active"
                continue
            }
            val rule = s.ruleAt(i, tk)
            d.latchFor(rule, halfFrameUs)
            if (d.latchedPts != rule) {
                allExact = false
                if (d.passed(rule, halfFrameUs)) anyPassed = true
                if (hold && holdReasons.size < 12) {
                    holdReasons += "k=$k seq${s.seq} rule=$rule latched=${d.latchedPts} queue=${d.queue.size} pos=${d.player.currentPosition} " +
                        "state=${d.player.playbackState} pwr=${d.player.playWhenReady} stale=${s.stats.staleImages}"
                }
            }
            if (d.latchedPts == Long.MIN_VALUE) continue
            draws += d to p
        }
        if (hold && !allExact) {
            if (anyPassed) return MISSED
            held++
            return WAIT
        }
        // 2. Draw.
        GLES20.glViewport(0, 0, plan.canvasW, plan.canvasH)
        val bg = plan.bgRgb()
        GLES20.glDisable(GLES20.GL_BLEND)
        GLES20.glClearColor(bg[0], bg[1], bg[2], 1f)
        GLES20.glClear(GLES20.GL_COLOR_BUFFER_BIT)
        GLES20.glEnable(GLES20.GL_BLEND)
        GLES30.glBlendFuncSeparate(GLES20.GL_SRC_ALPHA, GLES20.GL_ONE_MINUS_SRC_ALPHA, GLES20.GL_ONE, GLES20.GL_ONE_MINUS_SRC_ALPHA)
        for ((d, p) in draws) {
            program.use()
            program.setSamplerTexIdUniform("uTex", d.tex, 0)
            program.setFloatsUniform("uTexMatrix", d.matrix())
            program.setFloatsUniform("uRect", floatArrayOf(p.rect[0] / plan.canvasW, p.rect[1] / plan.canvasH, p.rect[2] / plan.canvasW, p.rect[3] / plan.canvasH))
            program.setFloatsUniform("uTint", p.tint)
            program.setFloatUniform("uAlpha", p.alpha)
            program.bindAttributesAndUniforms()
            // GlProgram binds by the reported sampler type; the emulator's GLES translator reports
            // samplerExternalOES as sampler2D, so bind the OES target explicitly (AND-01 finding).
            GLES20.glActiveTexture(GLES20.GL_TEXTURE0)
            GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, d.tex)
            GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4)
        }
        val readings = HashMap<String, RegionReading>()
        for (r in regions) {
            val bar = readRow(Barcode.barcodeY(r.rect))
            val samples = (0 until 16).map { bar(Barcode.columnX(r.rect, it)) }
            val grey = readRow(Barcode.greyY(r.rect))((r.rect[0] + r.rect[2] / 2).toInt())
            val marker = readRow(Barcode.markerY(r.rect))
            readings[r.name] = RegionReading(Barcode.decode(samples, bg), grey, marker((r.rect[0] + r.rect[2] * 0.25f).toInt()), marker((r.rect[0] + r.rect[2] * 0.75f).toInt()))
        }
        EGLExt.eglPresentationTimeANDROID(display, eglSurface, pts * 1000)
        EGL14.eglSwapBuffers(display, eglSurface)
        composed++
        compositeMs += (System.nanoTime() - started) / 1e6
        frames.add(ProbeFrame(pts, System.nanoTime(), readings))
        return DRAWN
    }

    private fun readRow(y: Int): (Int) -> Int {
        val glY = (plan.canvasH - 1 - y).coerceIn(0, plan.canvasH - 1)
        row.clear()
        GLES20.glReadPixels(0, glY, plan.canvasW, 1, GLES20.GL_RGBA, GLES20.GL_UNSIGNED_BYTE, row)
        val copy = ByteArray(plan.canvasW * 4)
        row.get(copy)
        return { x ->
            val i = x.coerceIn(0, plan.canvasW - 1) * 4
            ((copy[i].toInt() and 0xff) shl 16) or ((copy[i + 1].toInt() and 0xff) shl 8) or (copy[i + 2].toInt() and 0xff)
        }
    }

    /**
     * Exact seek through the slot players (contingency path; AND-17's PausedFrameRenderer is the
     * other one): seeks every slot to the rule frame of output frame [k], waits until each active
     * slot has latched that frame, composites once. Returns the latency in ms, or -1 on timeout.
     */
    fun seekExact(k: Long, timeoutMs: Long): Double {
        val started = System.nanoTime()
        val tk = GridTime.timeOfFrame(k, plan.fps)
        val targets = onThread {
            slots.map { s ->
                s.decks.forEach { it.player.playWhenReady = false }
                val i = s.activeAt(tk)
                if (i >= 0) {
                    val d = s.deckFor(i)
                    val rule = s.ruleAt(i, tk)
                    // Exact seek shows the first frame at or after the position (V-N18), so floor to ms.
                    d.position(i, (rule - s.clipStart[i]) / 1000)
                    s.stats.seeks++
                    Triple(d, rule, i)
                } else {
                    null
                }
            }
        }
        val end = SystemClock.elapsedRealtime() + timeoutMs
        var lastIssue = SystemClock.elapsedRealtime()
        while (SystemClock.elapsedRealtime() < end) {
            val done = onThread {
                targets.all { t ->
                    if (t == null) return@all true
                    t.first.latchNewest()
                    t.first.latchedPts == t.second
                }
            }
            if (done) {
                onThread { composite(k) }
                return (System.nanoTime() - started) / 1e6
            }
            // Watchdog: a deck that sits in BUFFERING without its target frame for STUCK_RESEEK_MS
            // (seen on cold starts of 4 and 6 slots on the loaded emulator: the decoder never
            // outputs) gets its exact seek re-issued. ExoPlayer drops a seek to the ms it already
            // reports while BUFFERING/READY, so the re-issue alternates between ms − 1 and ms: both
            // land on the rule frame (first frame with pts ≥ position, V-N18; frames are > 1 ms apart).
            if (SystemClock.elapsedRealtime() - lastIssue >= STUCK_RESEEK_MS) {
                lastIssue = SystemClock.elapsedRealtime()
                onThread {
                    for (t in targets) {
                        if (t == null) continue
                        val (d, rule, i) = t
                        d.latchNewest()
                        if (d.latchedPts != rule && d.player.playbackState == Player.STATE_BUFFERING) {
                            val ms = (rule - d.slot.clipStart[i]) / 1000
                            val nudge = d.slot.stats.reseeks % 2 == 0 && ms > 0
                            d.position(i, if (nudge) ms - 1 else ms, force = true)
                            d.slot.stats.reseeks++
                        }
                    }
                }
            }
            Thread.sleep(2)
        }
        return -1.0
    }

    /** Copies of the per-slot counters (seeks, re-seeks, recoveries, ...). */
    fun slotStats(): List<SlotStats> = onThread { slots.map { it.stats.copy() } }

    override fun close() {
        try {
            onThread {
                playing = false
                slots.forEach { it.release() }
                slots.clear()
                if (::program.isInitialized) program.delete()
                if (display != EGL14.EGL_NO_DISPLAY) {
                    EGL14.eglMakeCurrent(display, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_CONTEXT)
                    EGL14.eglDestroySurface(display, eglSurface)
                    EGL14.eglDestroyContext(display, eglContext)
                    EGL14.eglTerminate(display)
                }
            }
        } finally {
            thread.quitSafely()
        }
    }

    companion object {
        /** A standby deck pre-rolls its next layer when that layer starts within this window (µs). */
        private const val PREROLL_WINDOW_US = 1_000_000L

        /** Longest single frame-clock stop for a rebuffering deck before the clock runs on. */
        private const val MAX_STALL_MS = 2_000L

        /** Player-error recoveries per slot before the error is left standing. */
        private const val MAX_RECOVERIES = 5

        /** A deck stuck in BUFFERING without its exact-seek target this long gets the seek re-issued. */
        private const val STUCK_RESEEK_MS = 3_000L

        private const val DRAWN = 0
        private const val WAIT = 1
        private const val MISSED = 2

        /** Images held per deck (one bound + up to MAX_IMAGES − 2 queued). */
        const val MAX_IMAGES = 8

        /** Column-major y flip: (s, t) → (s, 1 − t). */
        val FLIP_Y = floatArrayOf(1f, 0f, 0f, 0f, 0f, -1f, 0f, 0f, 0f, 0f, 1f, 0f, 0f, 1f, 0f, 1f)

        /** The place shader of [PlaceShaders] sampling an OES texture through the SurfaceTexture matrix. */
        const val OES_FRAGMENT = """
#extension GL_OES_EGL_image_external : require
precision highp float;
uniform samplerExternalOES uTex;
uniform mat4 uTexMatrix;
uniform vec4 uRect;
uniform vec3 uTint;
uniform float uAlpha;
varying vec2 vPos;
void main() {
  vec2 c = vec2(vPos.x, 1.0 - vPos.y);
  vec2 uv = (c - uRect.xy) / uRect.zw;
  if (uv.x < 0.0 || uv.y < 0.0 || uv.x >= 1.0 || uv.y >= 1.0) {
    gl_FragColor = vec4(0.0);
    return;
  }
  vec2 st = (uTexMatrix * vec4(uv.x, 1.0 - uv.y, 0.0, 1.0)).xy;
  vec4 s = texture2D(uTex, st);
  gl_FragColor = vec4(clamp(s.rgb * uTint, 0.0, 1.0), uAlpha);
}
"""
    }
}
