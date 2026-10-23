// OWNER: AND-10
//
// PreviewSession (ARCH §12.2, §12.7, §13.3 "Preview session"; BUILD_PLAN AND-10). AND-01 reported a
// NO-GO for CompositionPlayer (R1), so the session is a shell around a [PreviewBackend]: AND-16's
// MultiPlayerBackend (`preview/fallback/ContingencyPreviewBackend`, decks + frame clock) plays, while
// this class owns everything that does not depend on how frames are decoded during playback:
//
// - Texture: [SurfaceBridge] over `TextureRegistry.createSurfaceProducer(resetInBackground)`; on
//   surface cleanup the renderer (and a backend that draws on the Surface) detach while the main
//   thread waits <= 500 ms; on surface available they reattach and the last frame is presented again.
// - Plans: setPlan / applyPatch decode (PlanReader), validate (PlanValidator, `planInvalid`) and
//   classify (PlanPatches, `planOutOfSync` when `from` != rev). Every change swaps the session's
//   ParamSnapshot (an AtomicReference shared with the renderer and the backend). Structural
//   changes also go through AND-17's StructuralDebouncer (150 ms trailing, 600 ms max wait) to
//   PreviewBackend.rebuild; the frame on screen stays until the new one is drawn ("a rebuild keeps
//   the last frame"). Acks: {rev, structural, applyMs}; while paused applyMs runs until the updated
//   frame is presented (QA-04 reads it as commit → preview latency).
// - Paused edits (D-36): param patches, transients, editing modes, structural edits, refresh,
//   proxies and source frames while paused are drawn by AND-17's PausedFrameRenderer onto the
//   Surface; experimentalRedrawLastFrame is never used. A backend that draws on the Surface itself
//   (AND-16) hands it to the renderer for paused edits and takes it back on play or seek
//   ([Owner]); the renderer prefetches the exact frames on pause and after an exact seek settles.
//   A paused render asked for while a seek is in flight or pending waits until the seek is acked
//   and then draws the acked frame (QA-05 D10: taking the Surface from a backend that was
//   composing the seek's frame left that frame unpresented, and the seek was acked at its timeout
//   with the frame shown before it). The seek ack's timeout reports the frame actually on screen,
//   whoever drew it.
// - Transport and seq (ARCH §12.2): play, pause and seek take the next command seq; replies carry
//   it and clock samples carry the seq of the last command they reflect. Clock samples go out at
//   every state change and at 10 Hz while playing (EventHub coalesces to <= 10 Hz), with
//   `timeUs = timeOfFrame(k)` of the displayed frame (D-35). Seeks go through [SeekController].
// - Quality: [QualityGovernor] (auto full → 1/2 → 1/4 under dropped frames, back after 10 s clean,
//   pinned levels never move, thermal SEVERE caps at half); a change resizes the SurfaceProducer
//   and is reported with `degraded(q)` (`recovered` when auto is back at full) and `frameSize`.
//   When playback stops for good (pause, end of the plan, export suspension) auto returns to the
//   requested level at once, reports it as such a step and the renderer draws the paused frame
//   again at that size; a paused seek does the same, before it is issued, if it still finds a
//   lowered level, so the paused frame is never left at a lowered quality (QA-05 D11).
// - Look stills, colour sampling and trim-edge frames come from AND-06's SourceFrameCache
//   (FrameExtractor EXACT; look stills through LayerLookEffect overrides), off the preview lane.
// - Export suspension (ARCH §14.3): PreviewSessionManager suspends sessions on minimal/low/mid
//   tiers; a suspended session is paused, its backend releases its decoders, play and seek answer
//   `busy` and paused renders wait for the resume.
//
// Threads: every public method runs on danaview-preview (the glue's guarantee); backend, renderer
// and bridge completions are posted back to it. Never logs paths, URIs or plan content.

package com.vecvel.danaview.editor.engine.preview

import android.graphics.Bitmap
import android.os.Build
import android.os.PowerManager
import android.util.Log
import android.view.Surface
import androidx.annotation.RequiresApi
import androidx.annotation.VisibleForTesting
import com.vecvel.danaview.editor.engine.core.Cancellable
import com.vecvel.danaview.editor.engine.core.Completion
import com.vecvel.danaview.editor.engine.core.EngineContext
import com.vecvel.danaview.editor.engine.core.EngineErrorCode
import com.vecvel.danaview.editor.engine.core.EngineErrors
import com.vecvel.danaview.editor.engine.core.EngineException
import com.vecvel.danaview.editor.engine.core.JobControl
import com.vecvel.danaview.editor.engine.core.Lane
import com.vecvel.danaview.editor.engine.core.fail
import com.vecvel.danaview.editor.engine.core.succeed
import com.vecvel.danaview.editor.engine.effects.EffectAssets
import com.vecvel.danaview.editor.engine.effects.RenderGeometry
import com.vecvel.danaview.editor.engine.pigeon.CacheTrimLevelMsg
import com.vecvel.danaview.editor.engine.pigeon.ClockMsg
import com.vecvel.danaview.editor.engine.pigeon.ColorMsg
import com.vecvel.danaview.editor.engine.pigeon.EditingModeMsg
import com.vecvel.danaview.editor.engine.pigeon.LookSpecMsg
import com.vecvel.danaview.editor.engine.pigeon.LoopMsg
import com.vecvel.danaview.editor.engine.pigeon.PlanAckMsg
import com.vecvel.danaview.editor.engine.pigeon.PreviewConfigMsg
import com.vecvel.danaview.editor.engine.pigeon.PreviewEventKindMsg
import com.vecvel.danaview.editor.engine.pigeon.PreviewEventMsg
import com.vecvel.danaview.editor.engine.pigeon.PreviewOpenedMsg
import com.vecvel.danaview.editor.engine.pigeon.PreviewQualityMsg
import com.vecvel.danaview.editor.engine.pigeon.ResolvedMediaMsg
import com.vecvel.danaview.editor.engine.pigeon.SeekAckMsg
import com.vecvel.danaview.editor.engine.plan.FrameGrid
import com.vecvel.danaview.editor.engine.plan.ParamSnapshot
import com.vecvel.danaview.editor.engine.plan.PlanAsset
import com.vecvel.danaview.editor.engine.plan.PlanAssetKind
import com.vecvel.danaview.editor.engine.plan.PlanCanvas
import com.vecvel.danaview.editor.engine.plan.PlanFormatException
import com.vecvel.danaview.editor.engine.plan.PlanLayer
import com.vecvel.danaview.editor.engine.plan.PlanLayerKind
import com.vecvel.danaview.editor.engine.plan.PlanLut
import com.vecvel.danaview.editor.engine.plan.PlanOutOfSyncException
import com.vecvel.danaview.editor.engine.plan.PlanPatches
import com.vecvel.danaview.editor.engine.plan.PlanReader
import com.vecvel.danaview.editor.engine.plan.PlanSize
import com.vecvel.danaview.editor.engine.plan.PlanTarget
import com.vecvel.danaview.editor.engine.plan.PlanValidator
import com.vecvel.danaview.editor.engine.plan.RenderPlan
import io.flutter.view.TextureRegistry
import java.io.ByteArrayOutputStream
import java.util.concurrent.Executor
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.atomic.AtomicReference
import kotlin.math.min

/** Output frames [first, endExclusive) of a playback loop. */
data class FrameRange(val first: Long, val endExclusive: Long) {
    init {
        require(first >= 0 && endExclusive > first) { "empty loop" }
    }

    /** Frames in the loop. */
    val length: Long get() = endExclusive - first

    /** Whether frame [k] lies in the loop. */
    operator fun contains(k: Long): Boolean = k >= first && k < endExclusive
}

/**
 * What a [PreviewBackend] gets from its session. Properties are read on danaview-preview; the
 * report calls may come from any thread (the session posts them to danaview-preview).
 */
interface PreviewBackendHost {
    /** The session id (for events and logs; never content). */
    val sessionId: String

    /** The engine context (lanes, events, services, source-frame cache). */
    val ctx: EngineContext

    /**
     * The displayed parameter state: plan + transients (ARCH §11.2). Read it per frame; a
     * param-only patch or a transient only swaps this reference. Evaluate a platform time τ at
     * `timeOfFrame(frameIndexNearest(τ))` of the output grid (D-35, `ParamSnapshot.frameTimeOf`).
     */
    val snapshot: AtomicReference<ParamSnapshot>

    /** AND-17's paused-frame renderer of the session (paused-exact stills, D-43(e)). */
    val renderer: PausedFrameRenderer

    /** danaview-preview's scheduler (frame clocks, timeouts). */
    val scheduler: DebounceScheduler

    /** danaview-preview. */
    val previewLane: Lane

    /** Output frames of the current plan (the last valid frame is `frameCount − 1`). */
    val frameCount: Long

    /** Whether video layers use their proxies. */
    val useProxies: Boolean

    /** Output frame [k] is on screen (playback, seek or scrub); drives seek acks and the clock. */
    fun frameDisplayed(k: Long)

    /** Output frame [k] was dropped during playback (never shown late or wrong; quality input). */
    fun frameDropped(k: Long)

    /** Playback waits for data (the frame clock stopped). */
    fun stalled()

    /** Playback resumed after [stalled]. */
    fun recovered()

    /** Playback reached the end without a loop; frame [k] stays on screen. */
    fun ended(k: Long)

    /** A failure the session reports as `failed(f)`. */
    fun failed(error: Throwable)
}

/**
 * The playback engine behind a [PreviewSession] (ARCH §13.3). AND-16's
 * `preview/fallback/ContingencyPreviewBackend` implements it (PreviewSessionManager picks it up
 * when that class implements this interface; it must keep a public no-argument constructor);
 * until then [StillFramesBackend] plays exact stills through the session's PausedFrameRenderer.
 * Every method is called on danaview-preview; completions may be called on any thread.
 */
interface PreviewBackend {
    /** A short name for logs. */
    val name: String

    /**
     * True when the backend draws playback frames on the preview Surface itself (AND-16's frame
     * clock): the session then detaches the paused renderer before [play] and [seek] and calls
     * [detachSurface] before a paused edit. False when it draws through [PreviewBackendHost.renderer].
     */
    val drawsOnSurface: Boolean

    /** How long an exact seek may take before it is acked with the frame displayed (D-35: 500 ms). */
    val exactSeekTimeoutMs: Long get() = SeekController.EXACT_TIMEOUT_MS

    /** Binds the backend to its session (once, before anything else). */
    fun open(host: PreviewBackendHost, done: Completion<Unit>)

    /**
     * Structural change to [plan] (already in the snapshot), debounced by the session (D-36:
     * 150 ms trailing, 600 ms max wait), one at a time; play waits for it. The frame on screen
     * must stay until the backend's first new frame.
     */
    fun rebuild(plan: RenderPlan, done: Completion<Unit>)

    /** Draw on [surface] ([width] × [height]) from now on (only when [drawsOnSurface]). */
    fun attachSurface(surface: Surface, width: Int, height: Int, done: Completion<Unit>)

    /** Stop drawing on the Surface (its EGL surface destroyed, players detached with `clearVideoSurface(surface)`). */
    fun detachSurface(done: Completion<Unit>)

    /** Starts playback at output frame [fromFrame], looping over [loop] when given. */
    fun play(fromFrame: Long, loop: FrameRange?, done: Completion<Unit>)

    /** Stops playback; [done] gets the frame left on screen. */
    fun pause(done: Completion<Long>)

    /**
     * Starts a seek to frame [k] ([exact]: the rule frame of every layer; otherwise a scrub that may
     * show a nearby frame). [done] reports that the seek started (or failed); the frames shown are
     * reported through [PreviewBackendHost.frameDisplayed]. A later seek supersedes this one.
     */
    fun seek(k: Long, exact: Boolean, done: Completion<Unit>)

    /** The preview render size changed (quality); applies from the next frame. */
    fun setRenderSize(width: Int, height: Int)

    /** Proxies on or off for video layers. */
    fun setUseProxies(on: Boolean)

    /** RGBA (top-down) of the frame the backend shows (debugCaptureFrame while it owns the Surface). */
    fun capture(done: Completion<PausedFrameRenderer.Captured>)

    /** Drops caches per [level]. */
    fun trim(level: CacheTrimLevelMsg)

    /** Releases decoders for an export on a weak tier (ARCH §14.3); the session is paused first. */
    fun suspendForExport(done: Completion<Unit>)

    /** Undoes [suspendForExport]. */
    fun resumeAfterExport(done: Completion<Unit>)

    /** Releases everything (session dispose). */
    fun release(done: Completion<Unit>)

    /**
     * Mutes (true) or unmutes the backend's audio output while a voice recording captures (INT-07,
     * ARCH §15); applies to decks created later too. Backends without audio ignore it.
     */
    fun setMuted(muted: Boolean) = Unit
}

/** One live preview session (ARCH §12.2, §13; AND-10; file header). */
class PreviewSession internal constructor(
    override val sessionId: String,
    override val ctx: EngineContext,
    config: PreviewConfigMsg,
    /** The texture registry of the Flutter engine that opened the session (PreviewSessionManager.releaseAll). */
    val textures: TextureRegistry,
    /** The playback backend. */
    val backend: PreviewBackend,
    private val effectAssets: EffectAssets?,
    /** The tier's preview long-side cap (ARCH §12.5). */
    private val maxPreviewLongSide: Int,
    /** Runs blocking stills work (look stills, colour samples, source frames). */
    private val stillsExecutor: Executor,
    private val onReleased: (PreviewSession) -> Unit,
) : PreviewBackendHost {
    /** Who draws on the Surface now. */
    enum class Owner { NONE, RENDERER, BACKEND }

    override val previewLane: Lane = ctx.threads.preview
    override val scheduler: DebounceScheduler = HandlerDebounceScheduler(requireNotNull(previewLane.handler) { "preview lane without handler" })

    private val frames = PinnedFrameSource(EngineFrameSource(ctx))
    override val snapshot: AtomicReference<ParamSnapshot> = AtomicReference(ParamSnapshot.of(emptyPlan(config)))
    override val renderer: PausedFrameRenderer = PausedFrameRenderer(ctx.appContext, ctx.threads.gl, frames, snapshot, effectAssets)

    /** The quality governor. */
    val governor = QualityGovernor(config.quality)

    /** The texture bridge. */
    val bridge = SurfaceBridge(ctx.threads.main, previewLane, BridgeListener())

    /** Seek acks. */
    val seeks = SeekController(scheduler) { k, exact, done -> issueSeek(k, exact, done) }

    private val debouncer = StructuralDebouncer<RenderPlan>(scheduler) { plan, done ->
        backend.rebuild(plan) { r ->
            r.exceptionOrNull()?.let { onLane { reportFailure(it) } }
            done()
        }
    }
    private val idleWaiters = ArrayList<() -> Unit>()

    /** A paused render was asked for while a seek was busy (D10), and the callers waiting for it. */
    private var renderAfterSeek = false
    private val afterSeekWaiters = ArrayList<(PausedFrameRenderer.RenderResult?) -> Unit>()

    /** Paused renders queued or running and not finished yet (debugCaptureFrame waits for them). */
    private var pausedRendersInFlight = 0

    // ---- state (danaview-preview) ----
    private var committed: ParamSnapshot? = null
    private var canvas = PlanCanvas(config.canvasWidth.toInt(), config.canvasHeight.toInt(), config.fps.toInt())
    private var grid = FrameGrid.of(canvas.fps)
    override var frameCount: Long = 0
        private set
    override var useProxies: Boolean = config.useProxies
        private set

    /** The paused playhead (or, while playing, the last displayed frame). */
    var playhead: Long = 0
        private set

    /** Whether the session plays. */
    var playing: Boolean = false
        private set

    /** The seq of the last command issued. */
    var seq: Long = 0
        private set

    /** The seq of the last command whose effect clock samples reflect. */
    var appliedSeq: Long = 0
        private set

    private var surface: Surface? = null
    private var surfaceW = 0
    private var surfaceH = 0
    private var surfaceValid = false

    /** Who draws on the Surface. */
    var owner: Owner = Owner.NONE
        private set

    private var sourceFrameShown = false
    private var suspended = false
    private var renderAfterResume = false
    private var opened = false

    /** Whether [open] completed (texture, renderer and backend ready). */
    val isOpen: Boolean get() = opened
    private var disposed = false
    private var firstFrameSent = false
    private var ticker: Cancellable? = null
    private var thermalTicks = 0
    private var loop: FrameRange? = null

    // Serialized operations (surface hand-offs, transport, renders).
    private val ops = ArrayDeque<(next: () -> Unit) -> Unit>()
    private var opRunning = false

    /** Every presented paused render (tests and QA timing). */
    @VisibleForTesting
    @Volatile
    var onRendered: ((PausedFrameRenderer.RenderResult) -> Unit)? = null

    /** The last presented paused render. */
    @Volatile
    var lastRender: PausedFrameRenderer.RenderResult? = null
        private set

    /** The current render (Surface) size. */
    val renderSize: Pair<Int, Int> get() = surfaceW to surfaceH

    /** The committed plan (null before setPlan). */
    val plan: RenderPlan? get() = committed?.plan

    init {
        seeks.exactTimeoutMs = backend.exactSeekTimeoutMs
        debouncer.onIdle = {
            val waiting = idleWaiters.toList()
            idleWaiters.clear()
            waiting.forEach { it() }
        }
    }

    // ---- open ----

    /** Creates the texture, attaches the renderer and opens the backend; [done] gets the ids. */
    internal fun open(done: Completion<PreviewOpenedMsg>) {
        val (w, h) = targetRenderSize()
        renderer.setRenderSize(w, h)
        renderer.warmUp { r -> r.exceptionOrNull()?.let { Log.w(TAG, "warm-up failed: ${EngineErrors.from(it).code}") } }
        bridge.open(textures, w, h) bridgeOpened@{ result ->
            val o = result.getOrElse {
                done.fail(EngineErrors.from(it))
                release { }
                return@bridgeOpened
            }
            surface = o.surface
            surfaceW = o.width
            surfaceH = o.height
            surfaceValid = true
            renderer.attachSurface(o.surface, o.width, o.height) { attached ->
                onLane {
                    attached.exceptionOrNull()?.let {
                        done.fail(EngineErrors.from(it))
                        release { }
                        return@onLane
                    }
                    owner = Owner.RENDERER
                    backend.open(this) { b ->
                        onLane {
                            b.exceptionOrNull()?.let {
                                done.fail(EngineErrors.from(it))
                                release { }
                                return@onLane
                            }
                            backend.setRenderSize(o.width, o.height)
                            backend.setUseProxies(useProxies)
                            renderer.setUseProxies(useProxies)
                            opened = true
                            done.succeed(PreviewOpenedMsg(sessionId, o.textureId))
                        }
                    }
                }
            }
        }
    }

    // ---- plans ----

    /** Replaces the plan ([plan] is UTF-8 JSON, `PlanTransport.encodePlan`). */
    fun setPlan(plan: ByteArray, done: Completion<PlanAckMsg>) {
        if (disposed) return done.fail(cancelled())
        val started = System.nanoTime()
        val next = try {
            PlanReader.readPlan(plan)
        } catch (e: PlanFormatException) {
            return done.fail(EngineErrors.invalidPlan("plan format at ${e.path}"))
        } catch (t: Throwable) {
            return done.fail(EngineErrors.from(t))
        }
        validationError(next)?.let { return done.fail(it) }
        val old = committed
        val structural = old == null || structurallyDiffers(old.plan, next)
        committed = old?.withPlan(next) ?: ParamSnapshot.of(next)
        applyCommitted(structural, started, done)
    }

    /** Applies a patch; `planOutOfSync` when `patch.from` != the engine revision. */
    fun applyPatch(patch: ByteArray, done: Completion<PlanAckMsg>) {
        if (disposed) return done.fail(cancelled())
        val started = System.nanoTime()
        val old = committed ?: return done.fail(EngineException(EngineErrorCode.planOutOfSync, "no plan"))
        val p = try {
            PlanReader.readPatch(patch)
        } catch (e: PlanFormatException) {
            return done.fail(EngineErrors.invalidPlan("patch format at ${e.path}"))
        } catch (t: Throwable) {
            return done.fail(EngineErrors.from(t))
        }
        val next = try {
            PlanPatches.apply(old.plan, p)
        } catch (e: PlanOutOfSyncException) {
            return done.fail(EngineException(EngineErrorCode.planOutOfSync, "patch from ${e.patchFrom}, plan rev ${e.planRev}"))
        }
        validationError(next)?.let { return done.fail(it) }
        val structural = PlanPatches.isStructural(old.plan, p)
        val touched = HashSet<String>()
        p.layers.upsert.forEach { touched += it.id }
        touched += p.layers.remove
        committed = old.withPlan(next, touched)
        applyCommitted(structural, started, done)
    }

    private fun applyCommitted(structural: Boolean, startedNs: Long, done: Completion<PlanAckMsg>) {
        val snap = committed ?: return
        val plan = snap.plan
        val canvasChanged = plan.canvas.w != canvas.w || plan.canvas.h != canvas.h || plan.canvas.fps != canvas.fps
        canvas = plan.canvas
        grid = FrameGrid.of(canvas.fps)
        frameCount = SeekMath.frameCount(grid, plan.durUs)
        if (frameCount > 0 && playhead > frameCount - 1) playhead = frameCount - 1
        if (!sourceFrameShown) snapshot.set(snap)
        if (structural) debouncer.submit(plan)
        if (canvasChanged) applyQuality(null)
        fun ack() = done.succeed(PlanAckMsg(plan.rev, structural, (System.nanoTime() - startedNs) / 1_000_000))
        if (playing || suspended || sourceFrameShown) {
            if (suspended) renderAfterResume = true
            ack()
        } else {
            // A seek in flight owns the renderer's frame; otherwise draw the paused playhead.
            if (!seeks.isBusy) renderer.setFrame(playhead)
            requestPausedRender { ack() }
        }
    }

    private fun validationError(plan: RenderPlan): EngineException? {
        val violations = PlanValidator.validate(plan)
        if (violations.isEmpty()) return null
        val v = violations.first()
        Log.w(TAG, "invalid plan: ${v.code} ${v.id ?: ""}")
        return EngineException(EngineErrorCode.planInvalid, "${v.code}: ${v.message}", itemId = v.id)
    }

    // ---- transients ----

    /** Sets a transient parameter override (coalesced to one render per frame; UTF-8 JSON). */
    fun setTransient(itemId: String, params: ByteArray) {
        if (disposed) return
        val snap = committed ?: return
        val t = try {
            PlanReader.readTransient(params)
        } catch (e: Throwable) {
            Log.w(TAG, "bad transient: ${EngineErrors.from(e).code}")
            return
        }
        if (t.item != itemId) Log.w(TAG, "transient item differs from its id")
        committed = snap.withTransient(t)
        publishCommitted()
    }

    /** Clears a transient override. */
    fun clearTransient(itemId: String) {
        if (disposed) return
        val snap = committed ?: return
        val next = snap.withoutTransient(itemId)
        if (next === snap) return
        committed = next
        publishCommitted()
    }

    private fun publishCommitted() {
        if (sourceFrameShown) return
        snapshot.set(committed)
        if (!playing) requestPausedRender(null)
    }

    // ---- transport ----

    /** Starts playback, optionally looping [loop]; completes with the command seq. */
    fun play(loop: LoopMsg?, done: Completion<Long>) {
        if (disposed) return done.fail(cancelled())
        if (suspended) return done.fail(busy())
        val range = loop?.let { loopRange(it) ?: return done.fail(EngineErrors.invalidArgument("loop", "empty")) }
        val s = ++seq
        clearSourceFrame()
        debouncer.flush()
        enqueue { next ->
            if (disposed) {
                done.fail(cancelled())
                return@enqueue next()
            }
            whenRebuilt {
                if (committed == null || frameCount <= 0) {
                    appliedSeq = maxOf(appliedSeq, s)
                    emitClock()
                    done.succeed(s)
                    return@whenRebuilt next()
                }
                var from = playhead.coerceIn(0, frameCount - 1)
                if (range != null && from !in range) from = range.first
                if (range == null && from >= frameCount - 1) from = 0
                this.loop = range
                ensureOwner(playbackOwner()) {
                    renderer.cancel()
                    backend.play(from, range) { r ->
                        onLane {
                            r.exceptionOrNull()?.let {
                                done.fail(EngineErrors.from(it))
                                return@onLane next()
                            }
                            playing = true
                            playhead = from
                            appliedSeq = maxOf(appliedSeq, s)
                            governor.onPlaybackStarted()
                            pollThermal()
                            startTicker()
                            emitClock()
                            done.succeed(s)
                            next()
                        }
                    }
                }
            }
        }
    }

    /** Pauses; completes with the command seq. */
    fun pause(done: Completion<Long>) {
        if (disposed) return done.fail(cancelled())
        val s = ++seq
        enqueue { next ->
            if (!playing) {
                // Playback may have stopped without a reset (nothing to do when it had one).
                resetQualityOnStop()
                appliedSeq = maxOf(appliedSeq, s)
                emitClock()
                done.succeed(s)
                return@enqueue next()
            }
            stopPlayback {
                appliedSeq = maxOf(appliedSeq, s)
                emitClock()
                done.succeed(s)
                next()
            }
        }
    }

    /** Stops the backend and leaves the session paused on the frame it shows (no new seq). */
    private fun stopPlayback(then: () -> Unit) {
        backend.pause { r ->
            onLane {
                val k = r.getOrElse { playhead }
                playing = false
                stopTicker()
                playhead = if (frameCount > 0) k.coerceIn(0, frameCount - 1) else 0
                renderer.setFrame(playhead)
                if (backend.drawsOnSurface) {
                    renderer.prefetch(playhead) { }
                } else {
                    // The renderer drew the playback frames: draw the pause frame once more so the
                    // Surface shows exactly `playhead` even if a later frame was being composed.
                    renderer.cancel()
                    requestPausedRender(null)
                }
                resetQualityOnStop()
                then()
            }
        }
    }

    /** Seeks; exact seeks complete after the frame is in the texture (D-35). */
    fun seek(timeUs: Long, exact: Boolean, done: Completion<SeekAckMsg>) {
        if (disposed) return done.fail(cancelled())
        if (suspended) return done.fail(busy())
        val s = ++seq
        clearSourceFrame()
        val k = SeekMath.targetFrame(grid, timeUs, frameCount)
        // A paused seek renders at the requested quality (QA-05 D11): the resize is queued before
        // the seek is issued, so the ack comes after it.
        if (!playing) resetQualityOnStop()
        if (committed == null || frameCount <= 0) {
            playhead = k
            appliedSeq = maxOf(appliedSeq, s)
            emitClock()
            return done.succeed(SeekAckMsg(timeUs, grid.timeOfFrame(k), k, s))
        }
        seeks.request(SeekController.Request(timeUs, k, exact, s) { r ->
            onLane {
                val ack = r.getOrElse {
                    done.fail(EngineErrors.from(it))
                    renderDeferredAfterSeek()
                    return@onLane
                }
                val shown = ack.displayedFrame
                if (!playing) {
                    playhead = shown
                    renderer.setFrame(shown)
                    if (exact && backend.drawsOnSurface) renderer.prefetch(shown) { }
                }
                appliedSeq = maxOf(appliedSeq, ack.seq)
                emitClock()
                done.succeed(SeekAckMsg(timeUs, grid.timeOfFrame(shown), shown, ack.seq))
                renderDeferredAfterSeek()
            }
        })
    }

    /** Runs the paused render deferred while seeks were busy (D10), once none is in flight or pending. */
    private fun renderDeferredAfterSeek() {
        if (!renderAfterSeek || seeks.isBusy) return
        renderAfterSeek = false
        val waiting = afterSeekWaiters.toList()
        afterSeekWaiters.clear()
        requestPausedRender { r -> waiting.forEach { it(r) } }
    }

    private fun issueSeek(k: Long, exact: Boolean, done: Completion<Unit>) {
        enqueue { next ->
            if (disposed) {
                done.fail(cancelled())
                return@enqueue next()
            }
            ensureOwner(playbackOwner()) {
                if (backend.drawsOnSurface) renderer.cancel()
                try {
                    backend.seek(k, exact, done)
                } catch (t: Throwable) {
                    done.fail(EngineErrors.from(t))
                }
                next()
            }
        }
    }

    private fun loopRange(loop: LoopMsg): FrameRange? {
        val first = grid.frameIndexOf(loop.startUs.coerceAtLeast(0))
        var end = grid.frameIndexOf(loop.endUs)
        if (grid.timeOfFrame(end) < loop.endUs) end++
        if (frameCount > 0) end = min(end, frameCount)
        return if (end > first) FrameRange(first, end) else null
    }

    // ---- quality and proxies ----

    /** Sets the preview quality. */
    fun setQuality(quality: PreviewQualityMsg, done: Completion<Unit>) {
        if (disposed) return done.fail(cancelled())
        val change = governor.setRequested(quality)
        applyQuality(change, done)
    }

    /** Switches proxies on or off. */
    /** Whether the session's audio is muted while a voice recording captures (INT-07; preview thread). */
    var recordingMuted: Boolean = false
        private set

    /** Mutes or unmutes the audio while a recording captures (INT-07, ARCH §15). Called on danaview-preview. */
    fun setRecordingMuted(muted: Boolean) {
        if (disposed || recordingMuted == muted) return
        recordingMuted = muted
        backend.setMuted(muted)
    }

    fun setUseProxies(on: Boolean, done: Completion<Unit>) {
        if (disposed) return done.fail(cancelled())
        useProxies = on
        renderer.setUseProxies(on)
        backend.setUseProxies(on)
        if (!playing && committed != null && !sourceFrameShown) requestPausedRender { done.succeed(Unit) } else done.succeed(Unit)
    }

    /** The render size for the canvas at the governor's level. */
    private fun targetRenderSize(): Pair<Int, Int> =
        QualityGovernor.renderSize(canvas.w, canvas.h, governor.level, maxPreviewLongSide)

    /**
     * Playback stopped for good: auto goes back to the requested level (QA-05 D11) and reports it
     * like a governor step (`degraded(q)`, plus `recovered` at full); [applyQuality] draws the
     * paused frame again at the new size. Nothing happens when the level did not change.
     */
    private fun resetQualityOnStop() {
        if (disposed) return
        governor.onPlaybackStopped()?.let { applyQuality(it) }
    }

    /** Resizes the texture to the governor's level when it differs ([change] reports an automatic step). */
    private fun applyQuality(change: QualityGovernor.Change?, done: Completion<Unit>? = null) {
        val (w, h) = targetRenderSize()
        if (change != null && change.reason != QualityGovernor.Reason.REQUEST) {
            ctx.events.preview(sessionId, PreviewEventMsg(PreviewEventKindMsg.DEGRADED, quality = change.to.msg))
            // Back at full: also report the recovery, as iOS does (QA-05 D11).
            if (change.to == QualityLevel.FULL) ctx.events.preview(sessionId, PreviewEventMsg(PreviewEventKindMsg.RECOVERED))
        }
        if (w == surfaceW && h == surfaceH) {
            done?.succeed(Unit)
            return
        }
        enqueue { next ->
            bridge.resize(w, h) { r ->
                val o = r.getOrElse {
                    Log.w(TAG, "resize failed: ${EngineErrors.from(it).code}")
                    done?.succeed(Unit)
                    return@resize next()
                }
                val drawer = owner
                replaceSurface(o.surface, o.width, o.height) {
                    ctx.events.preview(sessionId, PreviewEventMsg(PreviewEventKindMsg.FRAME_SIZE, width = o.width.toLong(), height = o.height.toLong()))
                    // A backend that draws on the Surface only scales its last frame up: after a
                    // stop reset the renderer composes the paused frame at the new size (D11). The
                    // renderer, when it drew, has already done so in replaceSurface.
                    if (change?.reason == QualityGovernor.Reason.STOP && drawer == Owner.BACKEND && !playing && committed != null) {
                        requestPausedRender(null)
                    }
                    done?.succeed(Unit)
                    next()
                }
            }
        }
    }

    /** Test hook: replaces PowerManager's thermal status (THERMAL_STATUS_*) when set; lane only. */
    @VisibleForTesting
    var thermalStatusOverride: Int? = null

    private fun pollThermal() {
        thermalStatusOverride?.let { status -> governor.setThermalStatus(status)?.let { applyQuality(it) }; return }
        if (Build.VERSION.SDK_INT < 29) return
        val status = thermalStatus29() ?: return
        governor.setThermalStatus(status)?.let { applyQuality(it) }
    }

    @RequiresApi(29)
    private fun thermalStatus29(): Int? =
        (ctx.appContext.getSystemService(android.content.Context.POWER_SERVICE) as? PowerManager)?.currentThermalStatus

    // ---- editing mode, source frames, stills ----

    /** Sets the editing mode (normal, crop source, matte). */
    fun setEditingMode(mode: EditingModeMsg, done: Completion<Unit>) {
        if (disposed) return done.fail(cancelled())
        val m = try {
            PausedEditingMode.of(mode)
        } catch (e: IllegalArgumentException) {
            return done.fail(EngineErrors.invalidArgument("mode", "item id missing"))
        }
        renderer.setEditingMode(m)
        if (!playing && committed != null && !sourceFrameShown) requestPausedRender { done.succeed(Unit) } else done.succeed(Unit)
    }

    /** Shows a source frame of [media] at [sourceTimeUs] instead of the timeline (paused; cleared by seek/play). */
    fun showSourceFrame(media: ResolvedMediaMsg, sourceTimeUs: Long, done: Completion<Unit>) {
        if (disposed) return done.fail(cancelled())
        if (playing || suspended) return done.fail(busy())
        val longSide = maxOf(surfaceW, surfaceH, 2)
        offLane(done) {
            ctx.sourceFrames.frame(media.uri, media.fingerprint, sourceTimeUs, longSide, null)
        }.invoke { bitmap ->
            if (disposed || playing) {
                done.succeed(Unit)
            } else {
                val key = frames.pin(bitmap)
                sourceFrameShown = true
                snapshot.set(ParamSnapshot.of(sourceFramePlan(key, bitmap.width, bitmap.height)))
                renderer.setFrame(0)
                requestPausedRender { done.succeed(Unit) }
            }
        }
    }

    private fun clearSourceFrame() {
        if (!sourceFrameShown) return
        sourceFrameShown = false
        frames.unpin()
        snapshot.set(committed ?: ParamSnapshot.of(emptyPlan(canvas)))
        renderer.setFrame(playhead)
    }

    /** One picture layer filling the canvas (contain) with the pinned bitmap [key]. */
    private fun sourceFramePlan(key: String, w: Int, h: Int): RenderPlan {
        val scale = min(canvas.w.toDouble() / w, canvas.h.toDouble() / h)
        val one = grid.timeOfFrame(1)
        val layer = PlanLayer(
            id = SOURCE_FRAME_LAYER, z = 0, t0 = 0, t1 = one, kind = PlanLayerKind.IMAGE, asset = SOURCE_FRAME_ASSET,
            base = PlanSize(w * scale, h * scale),
        )
        return RenderPlan(
            rev = 0, target = PlanTarget.PREVIEW, canvas = PlanCanvas(canvas.w, canvas.h, canvas.fps, canvas.gridFps),
            durUs = one, assets = mapOf(SOURCE_FRAME_ASSET to PlanAsset(PlanAssetKind.IMAGE, key, fp = key, w = w, h = h)),
            layers = listOf(layer), audio = emptyList(),
        )
    }

    /** 3x3 average of the pre-key source of [itemId] at the normalized point, or null. */
    fun sampleColor(itemId: String, x: Double, y: Double, done: Completion<ColorMsg?>) {
        if (disposed) return done.fail(cancelled())
        val snap = committed ?: return done.succeed(null)
        val t = grid.timeOfFrame(playhead)
        val layer = itemLayer(snap, itemId, t) ?: return done.succeed(null)
        val asset = layer.asset?.let { snap.plan.assets[it] } ?: return done.succeed(null)
        val at = if (layer.covers(t)) t else layer.t0
        when (asset.kind) {
            PlanAssetKind.VIDEO -> {
                val src = PausedFrames.sourceTimeUs(layer, at)
                offLane(done) { ctx.sourceFrames.sampleColor(asset.uri, asset.fp.ifEmpty { null }, src, x, y, null) }
                    .invoke { done.succeed(it) }
            }
            PlanAssetKind.IMAGE -> {
                val request = PausedFrameRequest(PlanAssetKind.IMAGE, asset.uri, asset.fp.ifEmpty { null }, 0, null)
                offLane(done) {
                    val bitmap = frames.frame(request, NO_CONTROL)
                    val window = ColorSampling.window(bitmap.width, bitmap.height, x, y)
                    val argb = IntArray(window.width * window.height)
                    bitmap.getPixels(argb, 0, window.width, window.x, window.y, window.width, window.height)
                    ColorSampling.average(argb)
                }.invoke { done.succeed(it) }
            }
            else -> done.succeed(null)
        }
    }

    /** JPEG stills of [itemId], one per look (the item's frame at the playhead, its LUT replaced by each look). */
    fun renderLookStills(itemId: String, looks: List<LookSpecMsg>, heightPx: Long, done: Completion<List<ByteArray>>) {
        if (disposed) return done.fail(cancelled())
        val snap = committed ?: return done.fail(EngineErrors.invalidArgument("itemId", "no plan"))
        val t = grid.timeOfFrame(playhead)
        val layer = itemLayer(snap, itemId, t) ?: return done.fail(EngineErrors.invalidArgument("itemId", "not in the plan"))
        val asset = layer.asset?.let { snap.plan.assets[it] }
        if (asset == null || asset.kind != PlanAssetKind.VIDEO) {
            return done.fail(EngineException(EngineErrorCode.unsupportedMedia, "look stills need a video layer", itemId = itemId))
        }
        val at = if (layer.covers(t)) t else layer.t0
        val params = snap.paramsAt(layer.id, at) ?: return done.fail(EngineErrors.invalidArgument("itemId", "no params"))
        val geometry = RenderGeometry(canvas.w, canvas.h, canvas.w, canvas.h)
        val stills = looks.map { spec ->
            if (spec.lutUri.isEmpty() || spec.intensity <= 0.0) {
                LookStill(params.copy(lut = null), layer, snap.plan, geometry, effectAssets)
            } else {
                val assetId = "$LOOK_ASSET_PREFIX${spec.id}"
                val plan = snap.plan.copy(
                    assets = snap.plan.assets + (assetId to PlanAsset(PlanAssetKind.LUT, spec.lutUri, fp = "look:${spec.id}", n = spec.lutSize.toInt())),
                )
                LookStill(params.copy(lut = PlanLut(assetId, spec.intensity.coerceIn(0.0, 1.0))), layer, plan, geometry, effectAssets)
            }
        }
        val src = PausedFrames.sourceTimeUs(layer, at)
        offLane(done) {
            val bitmaps = ctx.sourceFrames.lookStills(asset.uri, asset.fp.ifEmpty { null }, src, heightPx.toInt(), stills, null)
            try {
                bitmaps.map { jpeg(it) }
            } finally {
                bitmaps.forEach { it.recycle() }
            }
        }.invoke { done.succeed(it) }
    }

    /** The plan layer of item [itemId] (`<itemId>#v` or the id itself), preferring one active at [t]. */
    private fun itemLayer(snap: ParamSnapshot, itemId: String, t: Long): PlanLayer? {
        val candidates = snap.plan.layers.filter { it.id == "$itemId#v" || it.id == itemId }
        val chosen = candidates.firstOrNull { it.covers(t) } ?: candidates.firstOrNull() ?: return null
        return snap.layer(chosen.id)
    }

    // ---- refresh, capture ----

    /** Redraws the current frame. */
    fun refresh(done: Completion<Unit>) {
        if (disposed) return done.fail(cancelled())
        if (playing || committed == null) return done.succeed(Unit)
        requestPausedRender { done.succeed(Unit) }
    }

    /** RGBA of the displayed frame (debug/profile builds). */
    fun debugCaptureFrame(done: Completion<ByteArray>) {
        if (disposed) return done.fail(cancelled())
        val reply: Completion<PausedFrameRenderer.Captured> = { r -> onLane { done(r.map { it.rgba }) } }
        // An exact seek in flight is handing the Surface to the backend, which has composed nothing
        // yet while the Surface still shows the earlier frame (QA-02 s18: a capture right after the
        // editor's opening seek failed with "nothing composed"). Wait, bounded by the seek's own
        // timeout, until that seek has put its frame on screen, then read the Surface's owner.
        // Likewise a paused render in flight (or deferred behind a seek, D10): the renderer's
        // canvas still holds its previous frame until the render presents, while the Surface shows
        // what the backend drew, so reading the canvas then returned a stale frame.
        val deadline = scheduler.nowMs() + seeks.exactTimeoutMs + CAPTURE_SEEK_GRACE_MS
        fun capture() {
            if (disposed) return done.fail(cancelled())
            val busy = seeks.isBusy || renderAfterSeek || pausedRendersInFlight > 0
            if (busy && scheduler.nowMs() < deadline) {
                scheduler.schedule(CAPTURE_POLL_MS) { capture() }
                return
            }
            enqueue { next ->
                if (owner == Owner.BACKEND) backend.capture(reply) else renderer.capture(reply)
                next()
            }
        }
        onLane { capture() }
    }

    // ---- lifecycle ----

    /** Drops caches per [level]. */
    fun trim(level: CacheTrimLevelMsg) {
        if (disposed) return
        renderer.trim(level)
        backend.trim(level)
    }

    /**
     * Export suspension on weak tiers (ARCH §14.3): pause, release decoders, defer paused renders.
     * [released] runs once the backend has released its decoders (or at once when there is nothing
     * to suspend); the export waits for it before it creates its own codecs (QA-05 D9).
     */
    internal fun suspendForExport(released: (() -> Unit)? = null) {
        if (disposed || suspended) {
            released?.invoke()
            return
        }
        suspended = true
        seeks.cancelAll(busy())
        enqueue { next ->
            val finish = {
                backend.suspendForExport { r ->
                    r.exceptionOrNull()?.let { Log.w(TAG, "backend suspend: ${EngineErrors.from(it).code}") }
                    released?.invoke()
                    onLane {
                        renderer.cancel()
                        renderer.trim(CacheTrimLevelMsg.BACKGROUND)
                        next()
                    }
                }
            }
            if (playing) {
                stopPlayback {
                    emitClock()
                    finish()
                }
            } else {
                finish()
            }
        }
    }

    /** Ends an export suspension. */
    internal fun resumeAfterExport() {
        if (disposed || !suspended) return
        enqueue { next ->
            backend.resumeAfterExport { r ->
                r.exceptionOrNull()?.let { Log.w(TAG, "backend resume: ${EngineErrors.from(it).code}") }
                onLane {
                    suspended = false
                    if (renderAfterResume && !playing && committed != null) requestPausedRender(null)
                    renderAfterResume = false
                    next()
                }
            }
        }
    }

    /** Whether an export suspension is active. */
    val isSuspended: Boolean get() = suspended

    /** Releases the session and its texture (idempotent). */
    fun dispose(done: Completion<Unit>) {
        if (disposed) return done.succeed(Unit)
        release(done)
    }

    private fun release(done: Completion<Unit>) {
        disposed = true
        playing = false
        stopTicker()
        debouncer.cancel()
        seeks.cancelAll(cancelled())
        renderer.cancel()
        ops.clear()
        val step3 = {
            bridge.release { r ->
                r.exceptionOrNull()?.let { Log.w(TAG, "texture release: ${EngineErrors.from(it).code}") }
                frames.unpin()
                onReleased(this)
                done.succeed(Unit)
            }
        }
        val step2 = {
            // Drain: the renderer's worker is FIFO, so this request completes only after every
            // render or prefetch already queued there has handed its GL step to danaview-gl; the
            // dispose posted next runs after those GL steps.
            renderer.render { _ ->
                renderer.dispose { r ->
                    r.exceptionOrNull()?.let { Log.w(TAG, "renderer dispose: ${EngineErrors.from(it).code}") }
                    onLane { step3() }
                }
            }
        }
        try {
            backend.release { r ->
                r.exceptionOrNull()?.let { Log.w(TAG, "backend release: ${EngineErrors.from(it).code}") }
                onLane { step2() }
            }
        } catch (t: Throwable) {
            Log.w(TAG, "backend release: ${EngineErrors.from(t).code}")
            step2()
        }
    }

    // ---- PreviewBackendHost reports ----

    override fun frameDisplayed(k: Long) = onLane {
        if (disposed) return@onLane
        seeks.onFrameDisplayed(k)
        if (playing) {
            playhead = k
            governor.onFrame(dropped = false)?.let { applyQuality(it) }
        }
        noteFirstFrame()
    }

    override fun frameDropped(k: Long) = onLane {
        if (disposed || !playing) return@onLane
        governor.onFrame(dropped = true)?.let { applyQuality(it) }
    }

    override fun stalled() = onLane {
        if (!disposed) ctx.events.preview(sessionId, PreviewEventMsg(PreviewEventKindMsg.STALLED))
    }

    override fun recovered() = onLane {
        if (!disposed) ctx.events.preview(sessionId, PreviewEventMsg(PreviewEventKindMsg.RECOVERED))
    }

    override fun ended(k: Long) = onLane {
        if (disposed || !playing) return@onLane
        playing = false
        stopTicker()
        playhead = if (frameCount > 0) k.coerceIn(0, frameCount - 1) else 0
        renderer.setFrame(playhead)
        if (backend.drawsOnSurface) renderer.prefetch(playhead) { }
        resetQualityOnStop()
        emitClock()
    }

    override fun failed(error: Throwable) = onLane { reportFailure(error) }

    private fun reportFailure(error: Throwable) {
        if (disposed) return
        val e = EngineErrors.from(error)
        Log.w(TAG, "preview failure: ${e.code}")
        ctx.events.preview(sessionId, PreviewEventMsg(PreviewEventKindMsg.FAILED, failure = EngineErrors.toFailureMsg(e)))
    }

    private fun noteFirstFrame() {
        if (firstFrameSent) return
        firstFrameSent = true
        ctx.events.preview(sessionId, PreviewEventMsg(PreviewEventKindMsg.FIRST_FRAME, width = surfaceW.toLong(), height = surfaceH.toLong()))
    }

    // ---- clock ----

    private fun emitClock() {
        if (disposed) return
        val k = playhead.coerceAtLeast(0)
        ctx.events.clock(sessionId, ClockMsg(grid.timeOfFrame(k), playing, if (playing) 1.0 else 0.0, appliedSeq))
    }

    private fun startTicker() {
        stopTicker()
        thermalTicks = 0
        fun tick() {
            ticker = scheduler.schedule(CLOCK_INTERVAL_MS) {
                if (!playing || disposed) return@schedule
                emitClock()
                if (++thermalTicks % THERMAL_POLL_TICKS == 0) pollThermal()
                tick()
            }
        }
        tick()
    }

    private fun stopTicker() {
        ticker?.cancel()
        ticker = null
    }

    // ---- paused rendering and surface ownership ----

    private fun requestPausedRender(done: ((PausedFrameRenderer.RenderResult?) -> Unit)?) {
        if (disposed) return done?.invoke(null) ?: Unit
        if (suspended) {
            renderAfterResume = true
            return done?.invoke(null) ?: Unit
        }
        if (seeks.isBusy) {
            // QA-05 D10: the backend may be composing the seek's frame on the Surface; taking the
            // Surface now would leave that frame unpresented. Draw after the ack, on the acked frame.
            renderAfterSeek = true
            done?.let { afterSeekWaiters += it }
            return
        }
        pausedRendersInFlight++
        enqueue { next ->
            if (playing || disposed) {
                pausedRendersInFlight--
                done?.invoke(null)
                return@enqueue next()
            }
            ensureOwner(Owner.RENDERER) {
                renderer.render { r ->
                    onLane {
                        pausedRendersInFlight--
                        val result = r.getOrNull()
                        r.exceptionOrNull()?.let {
                            val code = EngineErrors.from(it).code
                            if (code != EngineErrorCode.cancelled) Log.w(TAG, "paused render failed: $code")
                        }
                        if (result != null && result.presented) {
                            // The renderer's frame is the one on screen now: a seek acked at its
                            // timeout reports it, not an older backend frame (D10).
                            seeks.resetDisplayed(result.k)
                            lastRender = result
                            onRendered?.invoke(result)
                            noteFirstFrame()
                        }
                        done?.invoke(result)
                    }
                }
                next()
            }
        }
    }

    private fun playbackOwner(): Owner = if (backend.drawsOnSurface) Owner.BACKEND else Owner.RENDERER

    /** Hands the Surface to [target] (no-op when it already draws there). */
    private fun ensureOwner(target: Owner, then: () -> Unit) {
        if (owner == target) return then()
        if (!backend.drawsOnSurface && target == Owner.BACKEND) return then()
        val s = surface
        if (!surfaceValid || s == null) {
            owner = target
            return then()
        }
        when (target) {
            Owner.RENDERER -> backend.detachSurface { d ->
                d.exceptionOrNull()?.let { Log.w(TAG, "backend detach: ${EngineErrors.from(it).code}") }
                renderer.attachSurface(s, surfaceW, surfaceH) { a ->
                    onLane {
                        owner = if (a.isSuccess) Owner.RENDERER else Owner.NONE
                        a.exceptionOrNull()?.let { reportFailure(it) }
                        then()
                    }
                }
            }
            Owner.BACKEND -> {
                renderer.cancel()
                renderer.detachSurface { d ->
                    d.exceptionOrNull()?.let { Log.w(TAG, "renderer detach: ${EngineErrors.from(it).code}") }
                    onLane {
                        backend.attachSurface(s, surfaceW, surfaceH) { a ->
                            onLane {
                                owner = if (a.isSuccess) Owner.BACKEND else Owner.NONE
                                a.exceptionOrNull()?.let { reportFailure(it) }
                                then()
                            }
                        }
                    }
                }
            }
            Owner.NONE -> then()
        }
    }

    /** Moves the current owner onto a new Surface (quality resize or a recovered surface) and redraws. */
    private fun replaceSurface(next: Surface, w: Int, h: Int, then: () -> Unit) {
        val drawer = if (owner == Owner.NONE) Owner.RENDERER else owner
        val sizeChanged = w != surfaceW || h != surfaceH
        surface = next
        surfaceW = w
        surfaceH = h
        surfaceValid = true
        renderer.setRenderSize(w, h)
        backend.setRenderSize(w, h)
        val redraw = {
            onLane {
                if (!playing && committed != null && owner == Owner.RENDERER) {
                    if (sizeChanged) {
                        // The kept canvas has the old size: compose the frame again at the new one.
                        requestPausedRender(null)
                        then()
                    } else {
                        // Same size (a recovered surface): present the kept frame; ES 2 composes again.
                        renderer.present { p ->
                            onLane {
                                if (p.getOrNull() != true) requestPausedRender(null)
                                then()
                            }
                        }
                    }
                } else {
                    then()
                }
            }
        }
        if (drawer == Owner.BACKEND) {
            backend.detachSurface {
                backend.attachSurface(next, w, h) { a ->
                    onLane {
                        owner = if (a.isSuccess) Owner.BACKEND else Owner.NONE
                        a.exceptionOrNull()?.let { reportFailure(it) }
                        then()
                    }
                }
            }
        } else {
            renderer.attachSurface(next, w, h) { a ->
                onLane {
                    owner = if (a.isSuccess) Owner.RENDERER else Owner.NONE
                    a.exceptionOrNull()?.let { reportFailure(it) }
                    redraw()
                }
            }
        }
    }

    private inner class BridgeListener : SurfaceBridge.Listener {
        override fun onSurfaceLost(done: () -> Unit) {
            // Runs on danaview-preview, outside the op queue: the main thread waits on it.
            surfaceValid = false
            var remaining = if (backend.drawsOnSurface) 2 else 1
            val lock = Any()
            val one = {
                val last = synchronized(lock) { --remaining == 0 }
                if (last) done()
            }
            // No cancel: a render in flight (an exact seek's still) finishes offscreen and is
            // presented again on the next surface; detaching runs after it on danaview-gl.
            renderer.detachSurface { one() }
            if (backend.drawsOnSurface) {
                try {
                    backend.detachSurface { one() }
                } catch (t: Throwable) {
                    one()
                }
            }
            if (!disposed) ctx.events.preview(sessionId, PreviewEventMsg(PreviewEventKindMsg.SURFACE_LOST))
        }

        override fun onSurfaceAvailable(surface: Surface, width: Int, height: Int) {
            if (disposed) return
            enqueue { next ->
                val resized = width != surfaceW || height != surfaceH
                replaceSurface(surface, width, height) {
                    if (resized) {
                        ctx.events.preview(sessionId, PreviewEventMsg(PreviewEventKindMsg.FRAME_SIZE, width = width.toLong(), height = height.toLong()))
                    }
                    ctx.events.preview(sessionId, PreviewEventMsg(PreviewEventKindMsg.RECOVERED))
                    next()
                }
            }
        }
    }

    // ---- plumbing ----

    private fun enqueue(op: (next: () -> Unit) -> Unit) {
        ops.addLast(op)
        if (!opRunning) runNext()
    }

    private fun runNext() {
        val op = ops.removeFirstOrNull()
        if (op == null) {
            opRunning = false
            return
        }
        opRunning = true
        var called = false
        val next = {
            post {
                if (!called) {
                    called = true
                    runNext()
                }
            }
        }
        try {
            op(next)
        } catch (t: Throwable) {
            Log.w(TAG, "preview operation failed: ${EngineErrors.from(t).code}")
            next()
        }
    }

    /** Runs [then] once no structural rebuild is pending or running. */
    private fun whenRebuilt(then: () -> Unit) {
        if (!debouncer.isPending && !debouncer.isRebuilding) return then()
        idleWaiters += then
    }

    private fun post(block: () -> Unit) {
        try {
            previewLane.execute(block)
        } catch (_: RejectedExecutionException) {
            // The lane quit (engine teardown).
        }
    }

    private fun onLane(block: () -> Unit) {
        if (previewLane.isCurrentThread()) {
            block()
            return
        }
        try {
            previewLane.execute(block)
        } catch (_: RejectedExecutionException) {
            // The lane quit (engine teardown).
        }
    }

    /** Runs [work] on the stills executor and continues on the preview lane; failures go to [failTo]. */
    private fun <T, R> offLane(failTo: Completion<R>, work: () -> T): ((T) -> Unit) -> Unit = { onValue ->
        try {
            stillsExecutor.execute {
                val r = runCatching(work)
                onLane {
                    r.fold(onSuccess = onValue, onFailure = { failTo.fail(EngineErrors.from(it)) })
                }
            }
        } catch (e: RejectedExecutionException) {
            failTo.fail(cancelled())
        }
    }

    private fun cancelled() = EngineException(EngineErrorCode.cancelled, "preview session disposed")

    private fun busy() = EngineException(EngineErrorCode.busy, "preview suspended during export", retryable = true)

    companion object {
        private const val TAG = "DanaviewPreview"

        /** Clock samples while playing (ARCH §12.2: 10 Hz). */
        const val CLOCK_INTERVAL_MS = 100L

        /** debugCaptureFrame: poll interval and grace past the exact-seek timeout while a seek is in flight. */
        private const val CAPTURE_POLL_MS = 20L
        private const val CAPTURE_SEEK_GRACE_MS = 500L

        /** Thermal status is polled every this many clock ticks (1 s). */
        private const val THERMAL_POLL_TICKS = 10

        /** Id of the layer that shows a source frame (showSourceFrame). */
        const val SOURCE_FRAME_LAYER = "dv_source_frame"
        private const val SOURCE_FRAME_ASSET = "dv_source_frame_asset"
        private const val LOOK_ASSET_PREFIX = "dv_look_"
        private const val JPEG_QUALITY = 90

        private val NO_CONTROL = object : JobControl {
            override val jobId: String = "preview"
            override val isCancelled: Boolean = false
            override fun reportProgress(fraction: Double) = Unit
            override fun throwIfCancelled() = Unit
        }

        /** An empty preview plan of the config's canvas (before the first setPlan). */
        fun emptyPlan(config: PreviewConfigMsg): RenderPlan =
            emptyPlan(PlanCanvas(config.canvasWidth.toInt(), config.canvasHeight.toInt(), config.fps.toInt()))

        private fun emptyPlan(canvas: PlanCanvas): RenderPlan =
            RenderPlan(rev = 0, target = PlanTarget.PREVIEW, canvas = canvas, durUs = 0, assets = emptyMap(), layers = emptyList(), audio = emptyList())

        /** Whether replacing [a] by [b] is structural (ARCH §11.2 classification, as a full replacement). */
        fun structurallyDiffers(a: RenderPlan, b: RenderPlan): Boolean {
            if (a.canvas != b.canvas || a.durUs != b.durUs || a.assets != b.assets) return true
            if (a.layers.size != b.layers.size || a.audio.size != b.audio.size) return true
            val oldLayers = a.layers.associateBy { it.id }
            for (l in b.layers) {
                val o = oldLayers[l.id] ?: return true
                if (PlanPatches.layerStructureChanged(o, l)) return true
            }
            val oldAudio = a.audio.associateBy { it.id }
            for (s in b.audio) {
                val o = oldAudio[s.id] ?: return true
                if (PlanPatches.audioStructureChanged(o, s)) return true
            }
            return false
        }

        private fun jpeg(bitmap: Bitmap): ByteArray {
            val out = ByteArrayOutputStream()
            check(bitmap.compress(Bitmap.CompressFormat.JPEG, JPEG_QUALITY, out)) { "jpeg encoding failed" }
            return out.toByteArray()
        }
    }
}

/**
 * The session's [PausedFrameSource]: the engine's frames, plus one pinned bitmap served for a
 * synthetic URI (showSourceFrame), so a trim-edge frame is decoded once.
 */
internal class PinnedFrameSource(private val base: PausedFrameSource) : PausedFrameSource {
    @Volatile private var pinned: Pair<String, Bitmap>? = null
    private var counter = 0

    /** Pins [bitmap]; returns the URI that serves it. */
    @Synchronized
    fun pin(bitmap: Bitmap): String {
        val key = "danaview-pinned:${++counter}"
        pinned = key to bitmap
        return key
    }

    /** Forgets the pinned bitmap. */
    fun unpin() {
        pinned = null
    }

    override fun frame(request: PausedFrameRequest, control: JobControl): Bitmap {
        pinned?.let { (key, bitmap) -> if (request.uri == key) return bitmap }
        if (request.uri.startsWith("danaview-pinned:")) throw EngineException(EngineErrorCode.cancelled, "source frame cleared")
        return base.frame(request, control)
    }
}
