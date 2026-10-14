// OWNER: AND-10
//
// Preview sessions of the process (ARCH §12.2, §13.3; BUILD_PLAN AND-10). The glue calls it on
// danaview-preview: `open` creates a [PreviewSession] over a SurfaceProducer of the calling Flutter
// engine's TextureRegistry, `get` finds one, `releaseAll` disposes the sessions of a detached
// Flutter engine, `trim` forwards memory trims. Export suspension (ARCH §14.3, AND-11):
// `suspendForExport(jobId)` / `resumeAfterExport(jobId)` (thread-safe) pause the sessions and
// release their decoders while an export runs on a minimal, low or mid tier; high-tier devices
// keep previewing.
//
// Backend selection (AND-01 NO-GO, ENG-06): the session plays through AND-16's
// `preview/fallback/ContingencyPreviewBackend` as soon as that class implements [PreviewBackend]
// (it keeps a public no-argument constructor and receives everything else in
// `PreviewBackend.open(host)`); no file of AND-10 changes when AND-16 lands. Until then, and
// whenever it is absent, [StillFramesBackend] plays: every frame it shows is a paused-exact still
// of AND-17's PausedFrameRenderer, so playback is exact but drops frames (D-43(e): drop, never late
// or wrong) and plays no audio; seeks and scrubs are exact.

package com.vecvel.danaview.editor.engine.preview

import android.util.Log
import android.view.Surface
import androidx.annotation.VisibleForTesting
import com.vecvel.danaview.editor.engine.core.Cancellable
import com.vecvel.danaview.editor.engine.core.Capabilities
import com.vecvel.danaview.editor.engine.core.Completion
import com.vecvel.danaview.editor.engine.core.EngineContext
import com.vecvel.danaview.editor.engine.core.EngineErrorCode
import com.vecvel.danaview.editor.engine.core.EngineErrors
import com.vecvel.danaview.editor.engine.core.fail
import com.vecvel.danaview.editor.engine.core.succeed
import com.vecvel.danaview.editor.engine.effects.EffectAssets
import com.vecvel.danaview.editor.engine.pigeon.CacheTrimLevelMsg
import com.vecvel.danaview.editor.engine.pigeon.DeviceTierMsg
import com.vecvel.danaview.editor.engine.pigeon.PreviewConfigMsg
import com.vecvel.danaview.editor.engine.pigeon.PreviewOpenedMsg
import com.vecvel.danaview.editor.engine.plan.FrameGrid
import com.vecvel.danaview.editor.engine.plan.RenderPlan
import com.vecvel.danaview.editor.engine.preview.fallback.ContingencyPreviewBackend
import io.flutter.view.TextureRegistry
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicInteger

/** Preview sessions of the process (ARCH §12.2, §13; AND-10). Called on danaview-preview. */
class PreviewSessionManager(private val ctx: EngineContext) {
    private val sessions = ConcurrentHashMap<String, PreviewSession>()
    private val exportJobs = LinkedHashSet<String>()
    private val threadIds = AtomicInteger()
    private val stills: ExecutorService by lazy {
        Executors.newSingleThreadExecutor { r -> Thread(r, "danaview-stills-${threadIds.incrementAndGet()}").apply { isDaemon = true } }
    }

    /** Creates the playback backend of a new session (tests replace it). */
    @VisibleForTesting
    @Volatile
    var backendFactory: () -> PreviewBackend = { defaultBackend() }

    /** Opens LUT and sprite assets for the renderers (null = the app's ContentResolver; tests). */
    @VisibleForTesting
    @Volatile
    var effectAssets: EffectAssets? = null

    /** The preview long-side cap (null = the device tier's `maxPreviewLongSide`; tests). */
    @VisibleForTesting
    @Volatile
    var maxPreviewLongSideOverride: Int? = null

    /** Tiers whose sessions are suspended during an export (ARCH §14.3; tests may widen it). */
    @VisibleForTesting
    @Volatile
    var suspendTiers: Set<DeviceTierMsg> = setOf(DeviceTierMsg.MINIMAL, DeviceTierMsg.LOW, DeviceTierMsg.MID)

    /**
     * Opens a session whose texture comes from [textures] (the registry of the Flutter engine that
     * called) and completes with its session and texture ids.
     */
    fun open(config: PreviewConfigMsg, textures: TextureRegistry, done: Completion<PreviewOpenedMsg>) {
        val backend = try {
            backendFactory()
        } catch (t: Throwable) {
            return done.fail(EngineErrors.from(t))
        }
        val id = "pv_" + UUID.randomUUID().toString().replace("-", "").take(16)
        val longSide = maxPreviewLongSideOverride ?: Capabilities.TierLimits.of(ctx.deviceProfile.tier()).maxPreviewLongSide.toInt()
        val session = PreviewSession(id, ctx, config, textures, backend, effectAssets, longSide, stills) { sessions.remove(it.sessionId) }
        sessions[id] = session
        Log.i(TAG, "open ${backend.name} ${config.canvasWidth}x${config.canvasHeight}@${config.fps}")
        session.open { r ->
            if (r.isSuccess && synchronized(exportJobs) { exportJobs.isNotEmpty() } && suspends()) session.suspendForExport()
            done(r)
        }
    }

    /** The open session [sessionId], or null. */
    fun get(sessionId: String): PreviewSession? = sessions[sessionId]

    /** Open sessions (tests). */
    val openSessions: List<PreviewSession> get() = sessions.values.toList()

    /** Disposes every session whose texture came from [textures] (that Flutter engine detached). */
    fun releaseAll(textures: TextureRegistry) {
        for (s in sessions.values.toList()) if (s.textures === textures) s.dispose { }
    }

    /** Drops caches per [level] (`EngineHostApi.trimCaches`, memory warnings); called on danaview-preview. */
    fun trim(level: CacheTrimLevelMsg) {
        for (s in sessions.values) s.trim(level)
    }

    /**
     * An export [jobId] started (AND-11): on minimal, low and mid tiers every session pauses and
     * releases its decoders until the last export ends. Thread-safe.
     */
    fun suspendForExport(jobId: String) {
        val first = synchronized(exportJobs) { exportJobs.add(jobId) && exportJobs.size == 1 }
        if (!first || !suspends()) return
        ctx.threads.preview.execute { for (s in sessions.values) s.suspendForExport() }
    }

    /** Export [jobId] ended (done, failed or cancelled); the sessions resume after the last one. Thread-safe. */
    fun resumeAfterExport(jobId: String) {
        val last = synchronized(exportJobs) { exportJobs.remove(jobId) && exportJobs.isEmpty() }
        if (!last) return
        ctx.threads.preview.execute { for (s in sessions.values) s.resumeAfterExport() }
    }

    /** Whether an export suspends previews on this device. */
    private fun suspends(): Boolean = ctx.deviceProfile.tier() in suspendTiers

    companion object {
        private const val TAG = "DanaviewPreview"

        /** AND-16's backend when it implements [PreviewBackend], else [StillFramesBackend]. */
        fun defaultBackend(): PreviewBackend = contingencyBackend() ?: StillFramesBackend()

        /** AND-16's ContingencyPreviewBackend, once it implements [PreviewBackend]. */
        fun contingencyBackend(): PreviewBackend? = (ContingencyPreviewBackend() as Any) as? PreviewBackend
    }
}

/**
 * AND-10's built-in backend (file header): plays by drawing paused-exact stills of the current
 * output frame through the host's PausedFrameRenderer on a frame clock at the project fps. Each
 * displayed frame is exact; frames whose turn passes while one is being drawn are dropped
 * (reported to the quality governor). No audio. Seeks and scrubs draw the exact frame.
 */
class StillFramesBackend : PreviewBackend {
    override val name: String = "stills"
    override val drawsOnSurface: Boolean = false

    /** A still can need a cold EXACT extraction per layer (about 1–2 s on the emulator). */
    override val exactSeekTimeoutMs: Long = 5_000

    private lateinit var host: PreviewBackendHost
    private var playing = false
    private var epoch = 0L
    private var clockFrame = 0L
    private var clockStartMs = 0L
    private var loop: FrameRange? = null
    private var tick: Cancellable? = null
    private var rendering = false
    private var shown = 0L
    private var lastRequested = -1L
    private var seekEpoch = 0L

    override fun open(host: PreviewBackendHost, done: Completion<Unit>) {
        this.host = host
        done.succeed(Unit)
    }

    override fun rebuild(plan: RenderPlan, done: Completion<Unit>) {
        // Stills read the snapshot directly: nothing to rebuild.
        done.succeed(Unit)
    }

    override fun attachSurface(surface: Surface, width: Int, height: Int, done: Completion<Unit>) = done.succeed(Unit)

    override fun detachSurface(done: Completion<Unit>) = done.succeed(Unit)

    override fun play(fromFrame: Long, loop: FrameRange?, done: Completion<Unit>) {
        this.loop = loop
        playing = true
        epoch++
        rebase(fromFrame)
        shown = fromFrame - 1
        lastRequested = -1
        schedule(0)
        done.succeed(Unit)
    }

    override fun pause(done: Completion<Long>) {
        playing = false
        epoch++
        tick?.cancel()
        tick = null
        done.succeed(shown.coerceAtLeast(0))
    }

    override fun seek(k: Long, exact: Boolean, done: Completion<Unit>) {
        if (playing) {
            epoch++
            rebase(k)
            shown = k - 1
            lastRequested = -1
            host.renderer.cancel()
            schedule(0)
            done.succeed(Unit)
            return
        }
        val mine = ++seekEpoch
        host.renderer.cancel()
        drawStill(k, mine, attempt = 0)
        done.succeed(Unit)
    }

    /** Draws the exact still of frame [k] for seek [mine]; a render cancelled by someone else is retried. */
    private fun drawStill(k: Long, mine: Long, attempt: Int) {
        host.renderer.setFrame(k)
        host.renderer.render { r ->
            host.previewLane.execute {
                if (mine != seekEpoch || playing) return@execute
                val result = r.getOrNull()
                if (result != null && result.k == k) {
                    shown = k
                    host.frameDisplayed(k)
                    return@execute
                }
                val error = r.exceptionOrNull()
                val cancelled = error == null || EngineErrors.from(error).code == EngineErrorCode.cancelled
                if (cancelled && attempt < MAX_STILL_RETRIES) {
                    drawStill(k, mine, attempt + 1)
                } else if (error != null && !cancelled) {
                    host.failed(error)
                }
            }
        }
    }

    override fun setRenderSize(width: Int, height: Int) = Unit

    override fun setUseProxies(on: Boolean) = Unit

    override fun capture(done: Completion<PausedFrameRenderer.Captured>) = host.renderer.capture(done)

    override fun trim(level: CacheTrimLevelMsg) = Unit

    override fun suspendForExport(done: Completion<Unit>) {
        playing = false
        epoch++
        tick?.cancel()
        tick = null
        done.succeed(Unit)
    }

    override fun resumeAfterExport(done: Completion<Unit>) = done.succeed(Unit)

    override fun release(done: Completion<Unit>) {
        playing = false
        epoch++
        tick?.cancel()
        tick = null
        done.succeed(Unit)
    }

    private fun rebase(k: Long) {
        clockFrame = k
        clockStartMs = host.scheduler.nowMs()
    }

    private fun grid(): FrameGrid = host.snapshot.get().outputGrid

    /** The output frame the clock is at now (wraps in the loop; clamps at the end). */
    private fun clockNow(): Long {
        val fps = grid().fps
        val elapsed = host.scheduler.nowMs() - clockStartMs
        var k = clockFrame + Math.floorDiv(elapsed * fps, 1000L)
        val l = loop
        if (l != null && k >= l.endExclusive) {
            k = l.first + Math.floorMod(k - l.first, l.length)
        }
        return k
    }

    private fun schedule(delayMs: Long) {
        tick?.cancel()
        val myEpoch = epoch
        tick = host.scheduler.schedule(delayMs) { onTick(myEpoch) }
    }

    private fun onTick(myEpoch: Long) {
        if (!playing || myEpoch != epoch) return
        val count = host.frameCount
        val frameMs = 1000.0 / grid().fps
        var k = clockNow()
        if (loop == null && k >= count - 1) k = (count - 1).coerceAtLeast(0)
        if (!rendering && k != lastRequested) {
            rendering = true
            lastRequested = k
            host.renderer.setFrame(k)
            host.renderer.render { r ->
                host.previewLane.execute {
                    rendering = false
                    if (!playing || myEpoch != epoch) return@execute
                    val result = r.getOrNull()
                    if (result != null && result.presented && result.k == k) {
                        val prev = shown
                        val dropped = if (loop != null && k < prev) (loop!!.endExclusive - prev - 1) + (k - loop!!.first) else k - prev - 1
                        repeat(dropped.coerceIn(0, MAX_DROP_REPORTS).toInt()) { i -> host.frameDropped(prev + 1 + i) }
                        shown = k
                        host.frameDisplayed(k)
                    } else {
                        r.exceptionOrNull()?.let {
                            if (EngineErrors.from(it).code != EngineErrorCode.cancelled) host.failed(it)
                        }
                    }
                    if (loop == null && k >= count - 1) {
                        playing = false
                        tick?.cancel()
                        tick = null
                        host.ended(k)
                    }
                }
            }
        }
        // Next turn: the start of the next output frame on the clock.
        val elapsed = host.scheduler.nowMs() - clockStartMs
        val nextAt = Math.ceil((Math.floorDiv(elapsed * grid().fps, 1000L) + 1) * frameMs).toLong()
        schedule((nextAt - elapsed).coerceAtLeast(1))
    }

    private companion object {
        const val MAX_DROP_REPORTS = 240L
        const val MAX_STILL_RETRIES = 3
    }
}
