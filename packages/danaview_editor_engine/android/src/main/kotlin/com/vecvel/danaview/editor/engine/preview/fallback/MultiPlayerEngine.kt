@file:OptIn(UnstableApi::class, ExperimentalApi::class)
// OWNER: AND-16
//
// MultiPlayerEngine: the engine behind ContingencyPreviewBackend (ARCH §13.3 "Preview session: AND-16
// MultiPlayerBackend", AND-01.md §2, §7; owner decision D-43(e), D-45). It runs entirely on
// danaview-gl (the only thread that may touch GL, effects/GlThreadPolicy): EGL and the compositor,
// the decks' application looper and ImageReader listeners, and the Choreographer frame clock.
//
// - Decks: per live packing slot two VideoDecks (one plays layer i, the other pre-rolls layer i + 1
//   paused at its first frame once it is < 1 s away); per audio lane two AudioDecks; per rendered
//   range set (D-45, [RenderedRangeHook]) one more deck pair that plays the range files during
//   playback only, in place of every slot.
// - Frame clock: Choreographer vsyncs → plan time ([FrameClock]); decks lead by 2 output frames.
//   Hold/miss: frame k is composited only when every active slot latched its rule frame (by pts),
//   otherwise it waits for the next vsync or is dropped once a deck passed it; a late frame is a
//   dropped frame (reported, quality input), never a wrong one. The clock stops while a playing
//   deck rebuffers (≤ 2 s at a time), follows the audio master, and drift > 1 frame re-seeks the
//   late deck (1 s cooldown).
// - Still layers (over the live budget, `hold` layers): during playback they show a paused-exact
//   still of the layer (fetched from SourceFrameCache when it becomes active); paused frames, scrubs
//   and exact seeks fetch the exact frame of every layer.
// - Seeks: exact seeks position every deck at floor((rule − clipStart)/1000) ms (V-N18) and the
//   frame is reported (host.frameDisplayed) only when every layer shows its rule frame. While
//   playing, an exact seek first shows the nearest decoded frames (CLOSEST_SYNC, not reported), then
//   refines to the exact frame (D-43(e): +30% allowed). Scrubs: one seek in flight, latest wins.
//   A stuck deck (BUFFERING 3 s without its frame) is re-seeked alternating ms − 1 and ms.
// - Structural re-plan by slot diff: setMediaItems on the changed slots' decks only.
// Never logs media paths or plan content.

package com.vecvel.danaview.editor.engine.preview.fallback

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.Log
import android.view.Choreographer
import android.view.Surface
import androidx.annotation.OptIn
import androidx.annotation.RequiresApi
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.common.util.ExperimentalApi
import androidx.media3.common.util.UnstableApi
import androidx.media3.exoplayer.SeekParameters
import androidx.media3.exoplayer.mediacodec.MediaCodecSelector
import com.vecvel.danaview.editor.engine.core.EngineContext
import com.vecvel.danaview.editor.engine.core.EngineErrorCode
import com.vecvel.danaview.editor.engine.core.EngineException
import com.vecvel.danaview.editor.engine.core.JobControl
import com.vecvel.danaview.editor.engine.core.Lane
import com.vecvel.danaview.editor.engine.effects.EffectAssets
import com.vecvel.danaview.editor.engine.effects.RenderGeometry
import com.vecvel.danaview.editor.engine.effects.SourceTexture
import com.vecvel.danaview.editor.engine.pigeon.CacheTrimLevelMsg
import com.vecvel.danaview.editor.engine.plan.FrameGrid
import com.vecvel.danaview.editor.engine.plan.LayerParams
import com.vecvel.danaview.editor.engine.plan.ParamSnapshot
import com.vecvel.danaview.editor.engine.plan.PlanLayer
import com.vecvel.danaview.editor.engine.plan.PlanLayerKind
import com.vecvel.danaview.editor.engine.plan.PlanPatches
import com.vecvel.danaview.editor.engine.plan.PlanSize
import com.vecvel.danaview.editor.engine.plan.RenderPlan
import com.vecvel.danaview.editor.engine.preview.EngineFrameSource
import com.vecvel.danaview.editor.engine.preview.FrameRange
import com.vecvel.danaview.editor.engine.preview.LayerCompositorGl
import com.vecvel.danaview.editor.engine.preview.PausedFrameRenderer
import com.vecvel.danaview.editor.engine.preview.PausedFrameRequest
import com.vecvel.danaview.editor.engine.preview.PausedFrames
import com.vecvel.danaview.editor.engine.preview.PreviewBackendHost
import com.vecvel.danaview.editor.engine.preview.PreviewSession
import com.vecvel.danaview.editor.engine.preview.SeekMath
import java.util.concurrent.ExecutorService
import java.util.concurrent.RejectedExecutionException

/** Engine tuning and test hooks (shared with [ContingencyPreviewBackend.Config]). */
interface EngineOptions {
    /** Live decode slots (null = the tier's budget capped by maxVisualSequences). */
    val liveBudget: Int?
    val codecSelector: MediaCodecSelector?
    val avOffsetUs: Long
    val leadFrames: Int
    val injectedCompositeDelayMs: Long
    val rangeHook: RenderedRangeHook
}

/** Counters of one engine (tests and QA logs; read on danaview-gl). */
class EngineStats {
    var composed = 0
    var dropped = 0
    var held = 0
    var missed = 0
    var rebuffers = 0
    var audioFollows = 0
    var audioClockReads = 0
    var nearestShown = 0
    var stillsFetched = 0
    var reseeks = 0
    var replans = 0
    var slotsReplanned = 0
    var deckCount = 0
    var rangeFrames = 0
    var exactStillFallbacks = 0
    val compositeMs = ArrayList<Double>()

    fun copy(): EngineStats = EngineStats().also {
        it.composed = composed; it.dropped = dropped; it.held = held; it.missed = missed; it.rebuffers = rebuffers
        it.audioFollows = audioFollows; it.audioClockReads = audioClockReads; it.nearestShown = nearestShown; it.stillsFetched = stillsFetched
        it.reseeks = reseeks; it.replans = replans; it.slotsReplanned = slotsReplanned; it.deckCount = deckCount
        it.rangeFrames = rangeFrames; it.exactStillFallbacks = exactStillFallbacks; it.compositeMs.addAll(compositeMs)
    }
}

/** The contingency engine (file header). Every method runs on danaview-gl. */
@RequiresApi(29)
internal class MultiPlayerEngine(
    private val host: PreviewBackendHost,
    private val lane: Lane,
    private val worker: ExecutorService,
    private val assets: EffectAssets,
    private val options: EngineOptions,
) : DeckEnv, Choreographer.FrameCallback {
    private enum class Mode { IDLE, PREROLL, PLAYING, SEEKING }

    private enum class Purpose { PLAYBACK, EXACT, NEAREST }

    private enum class Outcome { DRAWN, NOT_PRESENTED, WAIT, MISS }

    private inner class SlotRuntime(var spec: SlotSpec, val decks: List<VideoDeck>) {
        fun deckFor(i: Int): VideoDeck = decks[i % decks.size]

        fun release() = decks.forEach { it.release() }
    }

    private inner class LaneRuntime(var spec: AudioLaneSpec, val decks: List<AudioDeck>) {
        fun deckFor(i: Int): AudioDeck = decks[i % decks.size]

        fun release() = decks.forEach { it.release() }
    }

    private class StillTex(val layerKey: String, val request: PausedFrameRequest, val texture: SourceTexture)

    override val context: Context = host.ctx.appContext
    override val looper: Looper = requireNotNull(lane.looper) { "GL lane without looper" }
    override val handler: Handler = requireNotNull(lane.handler) { "GL lane without handler" }
    override val codecSelector: MediaCodecSelector? get() = options.codecSelector

    val stats = EngineStats()
    private val index = SourceFrameIndex(context)
    private val frameSource = EngineFrameSource(host.ctx)
    private var gl: FallbackGl? = null

    private var plan: SlotPlan = SlotPlan.empty(30)
    private var planSource: RenderPlan? = null
    private var planProxies = false
    private var planDirty = false
    private var buildSeq = 0
    private var frameTables: Map<String, LongArray> = emptyMap()
    private val slots = HashMap<Int, SlotRuntime>()
    private val lanes = ArrayList<LaneRuntime>()
    private var rangeRuntime: SlotRuntime? = null
    private var rangeItems: List<DeckItem> = emptyList()
    private var currentRange: RenderedRange? = null

    private val stills = HashMap<String, StillTex>()
    private val stillPending = HashSet<PausedFrameRequest>()
    private val stillWanted = java.util.concurrent.ConcurrentHashMap<String, PausedFrameRequest>()
    private val stillFailed = HashSet<String>()
    private val images = HashMap<PausedFrameRequest, SourceTexture>()
    private val imagePending = HashSet<PausedFrameRequest>()

    private var clock = FrameClock(FrameGrid.of(30), options.leadFrames)
    private var mode = Mode.IDLE
    private var token = 0
    private var loop: FrameRange? = null
    private var playFrom = 0L
    private var lastK = -1L

    /** The last presented output frame (-1: none). */
    var lastShown = -1L
        private set
    private var renderW = 0
    private var renderH = 0
    private var useProxies = false
    private var released = false
    private var stallStartNs = 0L
    private var lastTickNs = 0L
    private var lastFollowNs = 0L
    private val stallPaused = ArrayList<VideoDeck>()
    private var scrubbing = false
    private var pendingScrub: Long? = null
    private var resumeAfterSeek = false
    private var ticks = 0

    // ---- DeckEnv ----

    override fun deckFailed(error: PlaybackException) {
        host.failed(EngineException(EngineErrorCode.decodeFailed, "preview deck failed (${error.errorCodeName})", cause = error))
    }

    // ---- setup ----

    /** Creates the EGL context and compositor (open; throws when GL is unusable). */
    fun ensureGl(): FallbackGl = gl ?: FallbackGl(context, assets).also { gl = it }

    private val grid: FrameGrid get() = plan.grid

    private val frameCount: Long get() = SeekMath.frameCount(grid, plan.durUs)

    fun setRenderSize(w: Int, h: Int) {
        dbg("render size ${w}x$h")
        renderW = w
        renderH = h
    }

    fun setUseProxies(on: Boolean) {
        if (useProxies != on) planDirty = true
        useProxies = on
    }

    private fun readerSize(): Pair<Int, Int> {
        val p = planSource
        val w = if (renderW > 0) renderW else p?.canvas?.w ?: 2
        val h = if (renderH > 0) renderH else p?.canvas?.h ?: 2
        return w to h
    }

    // ---- plans ----

    /** Builds the deck plan of [renderPlan] (index I/O on the worker), then applies the slot diff. */
    fun rebuild(renderPlan: RenderPlan, done: (Throwable?) -> Unit) {
        val seq = ++buildSeq
        val proxies = useProxies
        val budgetOverride = options.liveBudget
        val hook = options.rangeHook
        try {
            worker.execute {
                val result = runCatching {
                    val budget = budgetOverride ?: liveBudgetOf(host.ctx)
                    val sp = SlotPlanner.plan(renderPlan, index, proxies, budget)
                    val tables = HashMap<String, LongArray>()
                    for (s in sp.slots) for (it in s.items) tables.getOrPut(it.uri) { index.frameTimes(it.uri) }
                    val ranges = hook.ranges(renderPlan.rev).sortedBy { it.first }
                    val rItems = ranges.mapNotNull { r -> rangeItem(r, renderPlan, tables) }
                    Triple(sp, tables, rItems)
                }
                post {
                    if (released) return@post done(null)
                    result.fold(
                        onSuccess = { (sp, tables, rItems) ->
                            if (seq == buildSeq) {
                                applyPlan(renderPlan, proxies, sp, tables, rItems)
                            }
                            done(null)
                        },
                        onFailure = { done(it) },
                    )
                }
            }
        } catch (e: RejectedExecutionException) {
            done(EngineException(EngineErrorCode.cancelled, "backend released"))
        }
    }

    private fun rangeItem(r: RenderedRange, p: RenderPlan, tables: HashMap<String, LongArray>): DeckItem? {
        val g = FrameGrid.of(p.canvas.fps)
        return try {
            val table = tables.getOrPut(r.uri) { index.frameTimes(r.uri) }
            val lastPts = g.platformTimeOfFrame(r.endExclusive - r.first)
            DeckItem(
                key = "range|${r.first}|${r.endExclusive}|${r.uri}",
                layer = null,
                t0 = g.timeOfFrame(r.first),
                t1 = g.timeOfFrame(r.endExclusive),
                uri = r.uri,
                clipStartUs = table.first(),
                clipEndUs = lastPts + SlotPlanner.CLIP_TAIL_US,
                rotation = 0,
                range = r,
            )
        } catch (e: Exception) {
            Log.w(EngineContext.TAG, "rendered range unusable (${e.javaClass.simpleName}); it plays live")
            null
        }
    }

    private fun applyPlan(source: RenderPlan, proxies: Boolean, sp: SlotPlan, tables: Map<String, LongArray>, rItems: List<DeckItem>) {
        val g = ensureGl()
        val changed = SlotPlanner.changedSlots(planSource?.let { plan }, sp)
        val changedLanes = SlotPlanner.changedLanes(planSource?.let { plan }, sp)
        val (rw, rh) = readerSize()
        g.current {
            for (seq in changed) {
                val spec = sp.slot(seq)
                val rt = slots[seq]
                if (spec == null || !spec.live || spec.items.isEmpty()) {
                    rt?.release()
                    slots.remove(seq)
                } else if (rt == null) {
                    slots[seq] = SlotRuntime(spec, List(2) { VideoDeck(this, it, spec.items, rw, rh) })
                } else {
                    rt.spec = spec
                    rt.decks.forEach { it.setItems(spec.items) }
                }
            }
            for ((seq, rt) in slots) sp.slot(seq)?.let { rt.spec = it }
            for (i in changedLanes.sorted()) {
                val spec = sp.audio.getOrNull(i)
                val rt = lanes.getOrNull(i)
                when {
                    spec == null -> rt?.release()
                    rt == null || rt.spec.stream != spec.stream -> {
                        rt?.release()
                        val created = LaneRuntime(spec, List(2) { AudioDeck(this, it, spec.items, spec.stream, options.avOffsetUs) })
                        if (i < lanes.size) lanes[i] = created else lanes += created
                    }
                    else -> {
                        rt.spec = spec
                        rt.decks.forEach { it.setItems(spec.items) }
                    }
                }
            }
            while (lanes.size > sp.audio.size) lanes.removeAt(lanes.size - 1)
            for ((i, rt) in lanes.withIndex()) sp.audio.getOrNull(i)?.let { rt.spec = it }
            if (rItems.map { it.key } != rangeItems.map { it.key }) {
                rangeRuntime?.release()
                rangeRuntime = if (rItems.isEmpty()) null else {
                    val spec = SlotSpec(RANGE_SEQ, rItems, true)
                    SlotRuntime(spec, List(2) { VideoDeck(this, it, rItems, rw, rh) })
                }
                rangeItems = rItems
            }
        }
        // Stills of layers that changed or left the plan.
        val keep = sp.stillLayers
        val drop = stills.filter { (id, st) -> id !in keep || source.layer(id)?.let { layerKeyOf(it) } != st.layerKey }.keys.toList()
        for (id in drop) stills.remove(id)?.let { g.delete(it.texture) }
        stillFailed.clear()
        if (changed.isNotEmpty()) stats.replans++
        stats.slotsReplanned += changed.size
        stats.deckCount = slots.values.sumOf { it.decks.size } + (rangeRuntime?.decks?.size ?: 0)
        if (clock.grid.fps != sp.fps) clock = FrameClock(FrameGrid.of(sp.fps), options.leadFrames)
        plan = sp
        planSource = source
        planProxies = proxies
        planDirty = false
        frameTables = tables
    }

    /** Runs [then] once the deck plan matches the session's snapshot (an unchanged structure only swaps the plan object). */
    private fun ensurePlan(then: (Throwable?) -> Unit) {
        val snap = host.snapshot.get().plan
        val current = planSource
        if (current != null && !planDirty && planProxies == useProxies) {
            if (current.rev == snap.rev || !PreviewSession.structurallyDiffers(current, snap)) {
                planSource = snap
                return then(null)
            }
        }
        rebuild(snap, then)
    }

    // ---- surface ----

    fun attachSurface(surface: Surface, w: Int, h: Int) {
        dbg("attach ${w}x$h mode=$mode")
        val g = ensureGl()
        g.attachWindow(surface, w, h)
        if (mode != Mode.PLAYING && lastShown >= 0 && g.canvasSize != null) {
            // A recovered or re-handed Surface shows the last frame again.
            g.present(grid.platformTimeOfFrame(lastShown))
        }
    }

    fun detachSurface() {
        dbg("detach mode=$mode")
        gl?.detachWindow()
    }

    fun capture(): PausedFrameRenderer.Captured = ensureGl().capture()

    // ---- transport ----

    fun play(from: Long, loopRange: FrameRange?) {
        dbg("play $from mode=$mode")
        val my = ++token
        stopAll()
        loop = loopRange
        mode = Mode.PREROLL
        ensurePlan { e ->
            if (my != token) return@ensurePlan
            if (e != null) return@ensurePlan fail(e)
            startPlayback(from, my)
        }
    }

    /** Stops playback; returns the frame on screen. */
    fun pause(): Long {
        dbg("pause mode=$mode")
        token++
        stopAll()
        mode = Mode.IDLE
        scrubbing = false
        pendingScrub = null
        resumeAfterSeek = false
        return if (lastShown >= 0) lastShown else playFrom
    }

    fun seek(k: Long, exact: Boolean) {
        dbg("seek $k exact=$exact mode=$mode")
        if (!exact && scrubbing && mode == Mode.SEEKING) {
            // One scrub in flight, the latest wins.
            pendingScrub = k
            return
        }
        val resume = mode == Mode.PLAYING || mode == Mode.PREROLL || (mode == Mode.SEEKING && resumeAfterSeek)
        val my = ++token
        stopAll()
        mode = Mode.SEEKING
        scrubbing = !exact
        resumeAfterSeek = resume
        pendingScrub = null
        ensurePlan { e ->
            if (my != token) return@ensurePlan
            if (e != null) return@ensurePlan fail(e)
            resizeDecks()
            val target = k.coerceIn(0, (frameCount - 1).coerceAtLeast(0))
            if (exact && resume) {
                nearestFirst(target, my) { startExact(target, my) }
            } else {
                startExact(target, my)
            }
        }
    }

    private fun fail(e: Throwable) {
        mode = Mode.IDLE
        host.failed(e)
    }

    private fun stopAll() {
        clock.stop()
        Choreographer.getInstance().removeFrameCallback(this)
        for (rt in allSlots()) rt.decks.forEach { it.setPlaying(false) }
        for (rt in lanes) rt.decks.forEach { it.setPlaying(false) }
        stallPaused.clear()
        if (stallStartNs != 0L) {
            stallStartNs = 0L
            host.recovered()
        }
    }

    private fun allSlots(): List<SlotRuntime> = slots.values.toList() + listOfNotNull(rangeRuntime)

    private fun resizeDecks() {
        val (w, h) = readerSize()
        val g = gl ?: return
        g.current { for (rt in allSlots()) rt.decks.forEach { it.resize(w, h) } }
    }

    // ---- exact seek and scrub ----

    /** Positions every live deck on output frame [k] (paused) with [params]; returns the decks that must show it. */
    private fun positionFor(k: Long, params: SeekParameters): List<VideoDeck> {
        val t = grid.timeOfFrame(k)
        val out = ArrayList<VideoDeck>()
        for (rt in slots.values) {
            val i = rt.spec.activeAt(t)
            rt.decks.forEach { it.setPlaying(false) }
            if (i < 0) continue
            val item = rt.spec.items[i]
            val d = rt.deckFor(i)
            d.position(i, item.positionMs(ruleOf(item, k)), params)
            out += d
        }
        return out
    }

    private fun nearestFirst(k: Long, my: Int, then: () -> Unit) {
        val decks = positionFor(k, SeekParameters.CLOSEST_SYNC)
        val started = SystemClock.uptimeMillis()
        fun poll() {
            if (my != token) return
            decks.forEach { it.latchNewest() }
            val ready = decks.all { it.hasEpochFrame }
            if (ready || SystemClock.uptimeMillis() - started >= NEAREST_WAIT_MS) {
                if (ready && composite(k, Purpose.NEAREST) == Outcome.DRAWN) stats.nearestShown++
                then()
                return
            }
            handler.postDelayed({ guarded { poll() } }, POLL_MS)
        }
        poll()
    }

    private fun startExact(k: Long, my: Int) {
        positionFor(k, SeekParameters.EXACT)
        val started = SystemClock.uptimeMillis()
        var lastWatch = started
        fun poll() {
            if (my != token) return
            when (composite(k, Purpose.EXACT)) {
                Outcome.DRAWN, Outcome.NOT_PRESENTED -> {
                    finishSeek(k, my)
                    return
                }
                else -> Unit
            }
            val now = SystemClock.uptimeMillis()
            if (now - lastWatch >= WATCH_INTERVAL_MS) {
                lastWatch = now
                watchdog(now)
            }
            if (now - started > SEEK_GIVE_UP_MS) {
                Log.w(EngineContext.TAG, "contingency preview: seek to $k gave up ${debugState()}")
                mode = Mode.IDLE
                scrubbing = false
                return
            }
            handler.postDelayed({ guarded { poll() } }, POLL_MS)
        }
        poll()
    }

    private fun finishSeek(k: Long, my: Int) {
        if (my != token) return
        val next = pendingScrub
        pendingScrub = null
        if (next != null && next != k) {
            scrubbing = false
            seek(next, false)
            return
        }
        scrubbing = false
        if (resumeAfterSeek) {
            resumeAfterSeek = false
            mode = Mode.PREROLL
            startPlayback(k, my)
        } else {
            mode = Mode.IDLE
        }
    }

    private fun watchdog(nowMs: Long) {
        for (rt in allSlots()) for (d in rt.decks) {
            if (d.stuck(nowMs, STUCK_RESEEK_MS)) {
                d.reseek()
                stats.reseeks++
            }
        }
    }

    // ---- playback ----

    private fun startPlayback(from: Long, my: Int) {
        val count = frameCount
        if (count <= 0) {
            mode = Mode.IDLE
            host.ended(0)
            return
        }
        resizeDecks()
        val k0 = from.coerceIn(0, count - 1)
        playFrom = k0
        val t0 = grid.timeOfFrame(k0)
        currentRange = null
        // Pre-roll: the decks that show k0 at their exact rule frames, audio at t0, stills of k0.
        schedule(t0, t0, prerolling = true)
        val started = SystemClock.uptimeMillis()
        var lastWatch = started
        fun poll() {
            if (my != token) return
            val ready = prerollReady(t0, k0)
            val now = SystemClock.uptimeMillis()
            if (ready || now - started > PREROLL_GIVE_UP_MS) {
                begin(k0)
                return
            }
            if (now - lastWatch >= WATCH_INTERVAL_MS) {
                lastWatch = now
                watchdog(now)
            }
            handler.postDelayed({ guarded { poll() } }, POLL_MS)
        }
        poll()
    }

    private fun prerollReady(t0: Long, k0: Long): Boolean {
        val inRange = rangeAt(t0)
        if (inRange != null) {
            val rt = rangeRuntime ?: return true
            val i = rt.spec.activeAt(t0)
            if (i < 0) return true
            val d = rt.deckFor(i)
            return d.player.playbackState == Player.STATE_READY || d.player.playbackState == Player.STATE_ENDED
        }
        for (rt in slots.values) {
            val i = rt.spec.activeAt(t0)
            if (i < 0) continue
            val d = rt.deckFor(i)
            if (d.assigned != i) return false
            val st = d.player.playbackState
            if (st != Player.STATE_READY && st != Player.STATE_ENDED) return false
        }
        for (rt in lanes) {
            val i = rt.spec.activeAt(t0)
            if (i < 0) continue
            val d = rt.deckFor(i)
            if (d.assigned != i) return false
            if (d.player.playbackState == Player.STATE_BUFFERING) return false
        }
        // Stills and images of k0 requested by the composite of the first frame; wait for them too.
        return stillsReady(k0)
    }

    private fun stillsReady(k: Long): Boolean {
        val snap = host.snapshot.get()
        val t = grid.timeOfFrame(k)
        for ((layer, params) in LayerCompositorGl.activeLayers(snap, t)) {
            when (layer.kind) {
                PlanLayerKind.MEDIA -> {
                    if (layer.id in plan.unavailable || layer.id in stillFailed) continue
                    if (!isStill(layer.id)) continue
                    val st = stills[layer.id]
                    if (st == null || st.layerKey != layerKeyOf(layer)) {
                        PausedFrames.request(snap.plan, layer, params, t, useProxies, geometry(snap.plan))?.let { requestStill(layer, it) }
                        return false
                    }
                }
                PlanLayerKind.IMAGE -> {
                    val req = PausedFrames.request(snap.plan, layer, params, t, useProxies, geometry(snap.plan)) ?: continue
                    if (req !in images) {
                        requestImage(req)
                        return false
                    }
                }
                else -> Unit
            }
        }
        return true
    }

    private fun begin(k0: Long) {
        dbg("begin k0=$k0 ready=${prerollReady(grid.timeOfFrame(k0), k0)} ${debugState()}")
        val now = System.nanoTime()
        mode = Mode.PLAYING
        clock.start(grid.timeOfFrame(k0), now)
        lastK = k0 - 1
        lastTickNs = now
        lastFollowNs = now
        stallStartNs = 0L
        schedule(clock.planTime(now), clock.deckTime(now), prerolling = false)
        Choreographer.getInstance().postFrameCallback(this)
    }

    override fun doFrame(frameTimeNanos: Long) = guarded {
        if (VideoDeck.DEBUG && ticks < 12) dbg("doFrame#$ticks mode=$mode")
        if (mode != Mode.PLAYING || released) {
            dbg("tick ignored mode=$mode")
            return@guarded
        }
        val now = System.nanoTime()
        val tp = clock.deckTime(now)
        val buffering = rebuffering(tp)
        if (VideoDeck.DEBUG && (ticks++ < 6 || ticks % 24 == 0)) dbg("tick k=${clock.frameAt(now)} lastK=$lastK buf=$buffering stall=${stallStartNs != 0L} ${debugState()}")
        if (buffering && (stallStartNs == 0L || (now - stallStartNs) / 1_000_000 < FrameClock.MAX_STALL_MS)) {
            if (stallStartNs == 0L) {
                stallStartNs = now
                stats.rebuffers++
                host.stalled()
                for (rt in allSlots()) for (d in rt.decks) {
                    if (d.player.playWhenReady && d.player.playbackState != Player.STATE_BUFFERING) {
                        d.setPlaying(false)
                        stallPaused += d
                    }
                }
                for (rt in lanes) rt.decks.forEach { it.setPlaying(false) }
            }
            clock.hold(now - lastTickNs)
            lastTickNs = now
            Choreographer.getInstance().postFrameCallback(this)
            return@guarded
        }
        if (stallPaused.isNotEmpty()) {
            stallPaused.forEach { it.setPlaying(true) }
            stallPaused.clear()
        }
        if (!buffering && stallStartNs != 0L) {
            stallStartNs = 0L
            host.recovered()
        }
        lastTickNs = now
        followAudio(now)
        val tc = clock.planTime(now)
        val k = clock.frameAt(now)
        val l = loop
        if (l != null && k >= l.endExclusive) {
            val my = ++token
            stopAll()
            mode = Mode.PREROLL
            startPlayback(l.first, my)
            return@guarded
        }
        if (k >= frameCount) {
            dbg("end k=$k frameCount=$frameCount dur=${plan.durUs} rev=${plan.rev}")
            for (dropped in SkipRange.of(lastK, frameCount)) host.frameDropped(dropped)
            stopAll()
            mode = Mode.IDLE
            host.ended(if (lastShown >= 0) lastShown else frameCount - 1)
            return@guarded
        }
        schedule(tc, clock.deckTime(now), prerolling = false)
        if (k > lastK && k >= playFrom) {
            noteBoundary(k)
            val outcome = composite(k, Purpose.PLAYBACK)
            if (VideoDeck.DEBUG && ticks < 12) dbg("k=$k -> $outcome")
            when (outcome) {
                Outcome.DRAWN, Outcome.NOT_PRESENTED -> {
                    reportDropped(HoldMiss.skipped(lastK, k))
                    lastK = k
                }
                Outcome.MISS -> {
                    stats.missed++
                    reportDropped(HoldMiss.skipped(lastK, k))
                    host.frameDropped(k)
                    stats.dropped++
                    lastK = k
                }
                Outcome.WAIT -> stats.held++
            }
        }
        Choreographer.getInstance().postFrameCallback(this)
    }

    private fun reportDropped(range: LongRange) {
        var n = 0
        for (k in range) {
            if (n++ >= MAX_DROP_REPORTS) break
            host.frameDropped(k)
            stats.dropped++
        }
    }

    private fun noteBoundary(k: Long) {
        val r = rangeAt(grid.timeOfFrame(k))
        if (r != currentRange) {
            currentRange = r
            try {
                options.rangeHook.onBoundary(k, r)
            } catch (e: RuntimeException) {
                Log.w(EngineContext.TAG, "rendered-range hook failed (${e.javaClass.simpleName})")
            }
        }
    }

    private fun rangeAt(t: Long): RenderedRange? {
        val rt = rangeRuntime ?: return null
        val i = rt.spec.activeAt(t)
        return if (i >= 0) rt.spec.items[i].range else null
    }

    /** True when a deck that plays the layer at deck time [tp] is rebuffering (its clock stopped). */
    private fun rebuffering(tp: Long): Boolean {
        val range = rangeAt(tp)
        val candidates = if (range != null) listOfNotNull(rangeRuntime) else slots.values.toList()
        return candidates.any { rt ->
            val i = rt.spec.activeAt(tp)
            if (i < 0) return@any false
            val d = rt.deckFor(i)
            d.assigned == i && d.player.playWhenReady && d.player.playbackState == Player.STATE_BUFFERING
        }
    }

    private fun followAudio(now: Long) {
        if (now - lastFollowNs < FOLLOW_INTERVAL_NS) return
        val nowMs = SystemClock.uptimeMillis()
        for (rt in lanes) for (d in rt.decks) {
            if (!d.player.playWhenReady || nowMs - d.playingSinceMs < AUDIO_WARMUP_MS) continue
            val audioT = d.planTimeNow() ?: continue
            lastFollowNs = now
            stats.audioClockReads++
            if (clock.follow(audioT, now) != 0L) stats.audioFollows++
            return
        }
    }

    /**
     * Drives the decks: the layer at deck time [tp] plays on its deck (seeking when the deck is not
     * on it, or drifts > 1 frame), the next layer pre-rolls paused on the other deck once it is less
     * than 1 s away unless that deck still feeds the compositor at [tc]; every other deck pauses.
     * Inside a rendered range the range deck plays and the slots pre-roll the range's end. Audio
     * lanes follow [tc]. [prerolling]: position only, play nothing.
     */
    private fun schedule(tc: Long, tp: Long, prerolling: Boolean) {
        val nowMs = SystemClock.uptimeMillis()
        val range = if (rangeRuntime != null) rangeAt(tp) else null
        rangeRuntime?.let { scheduleSlot(it, tc, tp, prerolling, nowMs, idleUntil = null) }
        val rangeEnd = range?.let { grid.timeOfFrame(it.endExclusive) }
        for (rt in slots.values) scheduleSlot(rt, tc, tp, prerolling, nowMs, rangeEnd)
        for (rt in lanes) scheduleLane(rt, tc, prerolling, nowMs)
        if (!prerolling) prefetchStills(tp)
    }

    private fun scheduleSlot(rt: SlotRuntime, tc: Long, tp: Long, prerolling: Boolean, nowMs: Long, idleUntil: Long?) {
        val spec = rt.spec
        val ic = spec.activeAt(tc)
        var playingDeck: VideoDeck? = null
        val ip: Int
        if (idleUntil != null) {
            // Inside a rendered range: nothing plays; pre-roll the item at the range end.
            ip = -1
            val atEnd = spec.activeAt(idleUntil)
            if (atEnd >= 0 && idleUntil - tp <= PREROLL_WINDOW_US) {
                val d = rt.deckFor(atEnd)
                val item = spec.items[atEnd]
                val k = grid.frameIndexOf(idleUntil)
                if (d.assigned != atEnd && (ic < 0 || d.assigned != ic)) {
                    d.setPlaying(false)
                    d.position(atEnd, item.positionMs(ruleOf(item, k)))
                    d.stats.prerolls++
                }
            }
        } else {
            ip = spec.activeAt(tp)
            if (ip >= 0) {
                val d = rt.deckFor(ip)
                playingDeck = d
                val item = spec.items[ip]
                val k = grid.frameIndexNearest(tp)
                val want = item.positionMs(ruleOf(item, k))
                when {
                    d.assigned != ip || d.player.currentMediaItemIndex != ip -> {
                        d.position(ip, want)
                        d.lastCorrectionMs = nowMs
                    }
                    !prerolling && d.player.playbackState == Player.STATE_READY && d.player.isPlaying &&
                        kotlin.math.abs(d.player.currentPosition - want) * 1000L > clock.halfFrameUs * 2 &&
                        nowMs - d.lastCorrectionMs > CORRECTION_COOLDOWN_MS -> {
                        d.position(ip, want, force = true)
                        d.stats.driftCorrections++
                        d.lastCorrectionMs = nowMs
                    }
                }
                d.setSpeed(item.speedAt(tp))
                d.setPlaying(!prerolling)
            }
        }
        val next = if (idleUntil != null) -1 else if (ip >= 0) (ip + 1).takeIf { it < spec.items.size } ?: -1 else spec.nextAfter(tp)
        var standby: VideoDeck? = null
        if (next >= 0) {
            val d = rt.deckFor(next)
            if (d !== playingDeck) {
                standby = d
                val dueIn = spec.items[next].t0 - tp
                if (d.assigned != next && (ic < 0 || d.assigned != ic) && dueIn <= PREROLL_WINDOW_US) {
                    d.setPlaying(false)
                    val item = spec.items[next]
                    d.position(next, item.positionMs(ruleOf(item, firstFrameAt(item.t0))))
                    d.stats.prerolls++
                }
            }
        }
        for (d in rt.decks) {
            if (d === playingDeck) continue
            val feeding = ic >= 0 && d.assigned == ic && d === rt.deckFor(ic)
            if (!feeding || d === standby) d.setPlaying(false)
        }
    }

    private fun scheduleLane(rt: LaneRuntime, tc: Long, prerolling: Boolean, nowMs: Long) {
        val spec = rt.spec
        val started = clock.running && tc >= grid.timeOfFrame(playFrom)
        val ic = spec.activeAt(tc)
        var playing: AudioDeck? = null
        if (ic >= 0) {
            val d = rt.deckFor(ic)
            playing = d
            if (d.assigned != ic) {
                d.position(ic, maxOf(tc, spec.items[ic].t0))
                d.lastCorrectionMs = nowMs
            } else if (started && !prerolling && nowMs - d.lastCorrectionMs > CORRECTION_COOLDOWN_MS && nowMs - d.playingSinceMs > AUDIO_WARMUP_MS) {
                val at = d.planTimeNow()
                if (at != null && kotlin.math.abs(at - tc) > AUDIO_DRIFT_US) {
                    d.position(ic, tc)
                    d.lastCorrectionMs = nowMs
                    d.stats.driftCorrections++
                }
            }
            d.setSpeedAt(tc)
            d.setPlaying(started && !prerolling)
        }
        val next = if (ic >= 0) (ic + 1).takeIf { it < spec.items.size } ?: -1 else spec.nextAfter(tc)
        if (next >= 0) {
            val d = rt.deckFor(next)
            if (d !== playing && d.assigned != next && spec.items[next].t0 - tc <= PREROLL_WINDOW_US) {
                d.setPlaying(false)
                d.position(next, spec.items[next].t0)
            }
        }
        for (d in rt.decks) if (d !== playing) d.setPlaying(false)
    }

    private fun prefetchStills(tp: Long) {
        if (plan.stillLayers.isEmpty()) return
        val snap = host.snapshot.get()
        val horizon = tp + PREROLL_WINDOW_US
        for (base in snap.plan.layers) {
            if (base.kind != PlanLayerKind.MEDIA || base.id !in plan.stillLayers) continue
            if (base.t1 <= tp - clock.leadUs || base.t0 > horizon) continue
            val st = stills[base.id]
            if (st != null && st.layerKey == layerKeyOf(base)) continue
            val layer = snap.layer(base.id) ?: continue
            val at = maxOf(base.t0, grid.timeOfFrame(grid.frameIndexNearest(tp)))
            if (at >= base.t1) continue
            val params = snap.paramsAt(base.id, at) ?: continue
            PausedFrames.request(snap.plan, layer, params, at, useProxies, geometry(snap.plan))?.let { requestStill(layer, it) }
        }
    }

    // ---- compositing ----

    private fun geometry(p: RenderPlan): RenderGeometry {
        val w = if (renderW > 0) renderW else p.canvas.w
        val h = if (renderH > 0) renderH else p.canvas.h
        return RenderGeometry(p.canvas.w, p.canvas.h, w, h)
    }

    /** The first output frame whose time is at or after plan time [t]. */
    private fun firstFrameAt(t: Long): Long {
        val k = grid.frameIndexOf(t)
        return if (grid.timeOfFrame(k) < t) k + 1 else k
    }

    private fun ruleOf(item: DeckItem, k: Long): Long {
        val table = frameTables[item.uri] ?: return item.clipStartUs
        return RuleFrameMath.rule(table, item.sourceAt(grid.timeOfFrame(k), grid))
    }

    private fun isStill(layerId: String): Boolean {
        if (layerId in plan.stillLayers) return true
        val seq = plan.layerSlot[layerId] ?: return false
        return slots[seq] == null
    }

    private fun layerKeyOf(l: PlanLayer): String = "${l.id}|${l.t0}|${l.t1}|${l.map}|${l.hold}|${l.asset}"

    private fun composite(k: Long, purpose: Purpose): Outcome {
        val g = gl ?: return Outcome.WAIT
        val started = System.nanoTime()
        val snap = host.snapshot.get()
        if (snap.plan.canvas.fps != plan.fps) return Outcome.WAIT
        val t = grid.timeOfFrame(k)
        val geom = geometry(snap.plan)
        val inputs = ArrayList<LayerCompositorGl.Input>()
        val used = HashSet<VideoDeck>()
        var missing = false
        var passed = false
        var stillFallbackUsed = false
        val range = if (purpose == Purpose.PLAYBACK) rangeAt(t) else null
        if (range != null) {
            val rt = rangeRuntime!!
            val i = rt.spec.activeAt(t)
            val item = rt.spec.items[i]
            val d = rt.deckFor(i)
            used += d
            g.bind()
            run {
                if (d.assigned != i) {
                    missing = true
                } else {
                    val rule = ruleOf(item, k)
                    d.latchFor(rule)
                    if (!d.hasLatched(rule)) {
                        missing = true
                        if (d.passed(rule)) passed = true
                    } else {
                        val layer = rangeLayer(snap.plan, item)
                        inputs += LayerCompositorGl.Input(layer, ParamSnapshot.evaluate(layer, snap.plan, t), d.texture)
                    }
                }
            }
        } else {
            g.bind()
            run {
                for ((layer, params) in LayerCompositorGl.activeLayers(snap, t)) {
                    when (layer.kind) {
                        PlanLayerKind.MEDIA -> {
                            if (layer.id in plan.unavailable || layer.id in stillFailed) continue
                            if (!isStill(layer.id)) {
                                val seq = plan.layerSlot[layer.id]
                                val rt = seq?.let { slots[it] }
                                val i = rt?.spec?.activeAt(t) ?: -1
                                val item = rt?.spec?.items?.getOrNull(i)
                                val itemLayer = item?.layer
                                if (rt == null || itemLayer == null || itemLayer.id != layer.id || PlanPatches.layerStructureChanged(itemLayer, layer)) {
                                    // The deck plan is behind the snapshot (a rebuild is pending): hold.
                                    if (purpose != Purpose.NEAREST) missing = true
                                    continue
                                }
                                val d = rt.deckFor(i)
                                used += d
                                if (d.assigned != i) {
                                    if (purpose != Purpose.NEAREST) missing = true
                                    continue
                                }
                                val rule = ruleOf(item, k)
                                if (purpose == Purpose.PLAYBACK) d.latchFor(rule) else d.latchNewest()
                                if (purpose == Purpose.NEAREST) {
                                    if (!d.hasEpochFrame) continue
                                } else if (!d.hasLatched(rule)) {
                                    if (purpose == Purpose.EXACT && d.hasEpochFrame && d.latchedPts > rule && d.player.playbackState == Player.STATE_READY) {
                                        // The decoder skipped the rule frame after the seek (the emulators'
                                        // hardware H.264 decoders drop the leading B-frames after a flush):
                                        // this paused frame shows the exact still of the layer instead.
                                        val tex = stillTexture(snap.plan, layer, params, t, geom, exact = true)
                                        if (tex == null) {
                                            missing = true
                                            continue
                                        }
                                        stillFallbackUsed = true
                                        inputs += LayerCompositorGl.Input(layer, params, tex)
                                        continue
                                    }
                                    missing = true
                                    if (purpose == Purpose.PLAYBACK && d.passed(rule)) passed = true
                                    continue
                                }
                                inputs += LayerCompositorGl.Input(layer, params, d.texture ?: continue)
                            } else {
                                val tex = stillTexture(snap.plan, layer, params, t, geom, exact = purpose == Purpose.EXACT)
                                if (tex == null) {
                                    if (purpose != Purpose.NEAREST) missing = true
                                    continue
                                }
                                inputs += LayerCompositorGl.Input(layer, params, tex)
                            }
                        }
                        PlanLayerKind.IMAGE -> {
                            val request = PausedFrames.request(snap.plan, layer, params, t, useProxies, geom) ?: continue
                            val tex = images[request]
                            if (tex == null) {
                                requestImage(request)
                                if (purpose != Purpose.NEAREST) missing = true
                                continue
                            }
                            inputs += LayerCompositorGl.Input(layer, params, tex)
                        }
                        PlanLayerKind.SOLID, PlanLayerKind.SPRITE -> inputs += LayerCompositorGl.Input(layer, params, null)
                    }
                }
            }
        }
        // Idle decks drain their queues (a deck holding an upcoming item keeps its first frames).
        g.bind()
        for (rt in allSlots()) for (d in rt.decks) {
            if (d in used) continue
            val assignedItem = rt.spec.items.getOrNull(d.assigned)
            if (assignedItem != null && assignedItem.t0 > t) d.pull() else d.latchNewest()
        }
        val verdict = if (purpose == Purpose.NEAREST) HoldMiss.Verdict.DRAW else HoldMiss.verdict(missing, passed)
        when (verdict) {
            HoldMiss.Verdict.WAIT -> return Outcome.WAIT
            HoldMiss.Verdict.MISS -> return Outcome.MISS
            HoldMiss.Verdict.DRAW -> Unit
        }
        val delay = options.injectedCompositeDelayMs
        if (delay > 0) SystemClock.sleep(delay)
        g.compose(snap.plan, geom, inputs)
        val sw = System.nanoTime()
        val presented = g.present(grid.platformTimeOfFrame(k))
        if (VideoDeck.DEBUG && stats.composed < 5) dbg("present k=$k took ${(System.nanoTime() - sw) / 1_000_000} ms window=${g.hasWindow}")
        stats.composed++
        if (range != null) stats.rangeFrames++
        if (stillFallbackUsed) stats.exactStillFallbacks++
        if (stats.compositeMs.size < MAX_TIMINGS) stats.compositeMs += (System.nanoTime() - started) / 1e6
        if (!presented) {
            dbg("not presented k=$k")
            return Outcome.NOT_PRESENTED
        }
        if (purpose != Purpose.NEAREST) {
            lastShown = k
            host.frameDisplayed(k)
        }
        return Outcome.DRAWN
    }

    /**
     * The still texture of [layer] for this frame, or null after requesting it: [exact] needs the
     * still of this very frame (paused, scrub, exact seek); playback accepts the layer's latest still.
     */
    private fun stillTexture(p: RenderPlan, layer: PlanLayer, params: LayerParams, t: Long, geom: RenderGeometry, exact: Boolean): SourceTexture? {
        val request = PausedFrames.request(p, layer, params, t, useProxies, geom) ?: return null
        val st = stills[layer.id]
        val ok = if (exact) st != null && st.request == request else st != null && st.layerKey == layerKeyOf(layer)
        if (!ok) {
            requestStill(layer, request)
            return null
        }
        return st!!.texture
    }

    private fun rangeLayer(p: RenderPlan, item: DeckItem): PlanLayer = PlanLayer(
        id = RANGE_LAYER_ID, z = 0, t0 = item.t0, t1 = item.t1, kind = PlanLayerKind.MEDIA,
        base = PlanSize(p.canvas.w.toDouble(), p.canvas.h.toDouble()),
    )

    // ---- stills and images ----

    private fun requestStill(layer: PlanLayer, request: PausedFrameRequest) {
        val id = layer.id
        // Only the latest wanted still of a layer is fetched (a scrub supersedes its earlier frames).
        stillWanted[id] = request
        if (!stillPending.add(request)) return
        val key = layerKeyOf(layer)
        val control = WorkControl()
        execute(
            work = { if (stillWanted[id] == request) frameSource.frame(request, control) else null },
            onResult = { r ->
                stillPending.remove(request)
                val g = gl
                if (released || g == null) return@execute
                r.fold(
                    onSuccess = { bitmap ->
                        if (bitmap != null) {
                            val tex = g.upload(bitmap)
                            stills.put(id, StillTex(key, request, tex))?.let { g.delete(it.texture) }
                            stats.stillsFetched++
                        }
                    },
                    onFailure = {
                        Log.w(EngineContext.TAG, "contingency preview: still unavailable (${it.javaClass.simpleName})")
                        stillFailed += id
                    },
                )
            },
        )
    }

    private fun requestImage(request: PausedFrameRequest) {
        if (!imagePending.add(request)) return
        execute(
            work = { frameSource.frame(request, WorkControl()) },
            onResult = { r ->
                imagePending.remove(request)
                val g = gl
                if (released || g == null) return@execute
                r.onSuccess { bitmap -> images.put(request, g.upload(bitmap))?.let { g.delete(it) } }
                r.onFailure { Log.w(EngineContext.TAG, "contingency preview: image unavailable (${it.javaClass.simpleName})") }
            },
        )
    }

    private inner class WorkControl : JobControl {
        override val jobId: String = "contingency-preview"
        override val isCancelled: Boolean get() = released
        override fun reportProgress(fraction: Double) = Unit
        override fun throwIfCancelled() {
            if (released) throw EngineException(EngineErrorCode.cancelled, "backend released")
        }
    }

    private fun <T> execute(work: () -> T, onResult: (Result<T>) -> Unit) {
        try {
            worker.execute {
                val r = runCatching(work)
                post { onResult(r) }
            }
        } catch (e: RejectedExecutionException) {
            // Released.
        }
    }

    // ---- lifecycle ----

    fun trim(level: CacheTrimLevelMsg) {
        if (level == CacheTrimLevelMsg.MEMORY_PRESSURE || level == CacheTrimLevelMsg.BACKGROUND || level == CacheTrimLevelMsg.CLEAR_ALL) {
            val g = gl ?: return
            for (st in stills.values) g.delete(st.texture)
            stills.clear()
            for (tex in images.values) g.delete(tex)
            images.clear()
            frameSource.clear()
            if (level == CacheTrimLevelMsg.CLEAR_ALL) SourceFrameIndex.clear()
        }
    }

    /** Releases every deck (decoders) for an export; the next play or seek rebuilds them. */
    fun suspendDecks() {
        token++
        stopAll()
        mode = Mode.IDLE
        releaseDecks()
        planSource = null
        plan = SlotPlan.empty(plan.fps)
    }

    private fun releaseDecks() {
        val g = gl
        val work = {
            slots.values.forEach { it.release() }
            slots.clear()
            lanes.forEach { it.release() }
            lanes.clear()
            rangeRuntime?.release()
            rangeRuntime = null
            rangeItems = emptyList()
        }
        if (g != null) g.current(work) else work()
        stats.deckCount = 0
    }

    fun release() {
        if (released) return
        token++
        stopAll()
        mode = Mode.IDLE
        released = true
        val g = gl
        try {
            releaseDecks()
            if (g != null) {
                for (st in stills.values) g.delete(st.texture)
                for (tex in images.values) g.delete(tex)
                g.release()
            }
        } finally {
            stills.clear()
            images.clear()
            gl = null
            frameSource.clear()
        }
    }

    /** Deck states for diagnostics (no content). */
    fun debugState(): String = allSlots().joinToString(" | ") { rt -> "slot ${rt.spec.seq}: " + rt.decks.joinToString("/") { it.debugState() } }

    /** The current mode name (tests). */
    val modeName: String get() = mode.name

    /** Whether playback runs. */
    val isPlaying: Boolean get() = mode == Mode.PLAYING

    /** Deck counters (tests). */
    fun deckStats(): List<DeckStats> = allSlots().flatMap { rt -> rt.decks.map { it.stats } }

    // ---- plumbing ----

    private fun dbg(msg: String) {
        if (VideoDeck.DEBUG) Log.d("AND16DBG", msg)
    }

    private fun post(block: () -> Unit) {
        try {
            lane.execute { guarded(block) }
        } catch (e: RejectedExecutionException) {
            // danaview-gl quit (engine teardown).
        }
    }

    private inline fun guarded(block: () -> Unit) {
        try {
            block()
        } catch (e: Exception) {
            Log.w(EngineContext.TAG, "contingency preview: ${e.javaClass.simpleName}")
            mode = Mode.IDLE
            host.failed(e)
        }
    }

    /** Frames skipped up to (exclusive) [end] after [lastK]. */
    private object SkipRange {
        fun of(lastK: Long, end: Long): LongRange = if (end > lastK + 1) (lastK + 1) until end else LongRange.EMPTY
    }

    companion object {
        /** Slot id of the rendered-range decks. */
        const val RANGE_SEQ = -1

        /** Layer id of a rendered range's full-canvas picture. */
        const val RANGE_LAYER_ID = "dv_rendered_range"

        /** A standby deck pre-rolls its next item when that starts within this window (µs). */
        const val PREROLL_WINDOW_US = 1_000_000L

        /** A deck stuck in BUFFERING without its frame this long is re-seeked. */
        const val STUCK_RESEEK_MS = 3_000L

        /** Stuck decks are looked for this often while a seek or pre-roll waits. */
        const val WATCH_INTERVAL_MS = 100L

        /** Drift corrections of one deck at most this often. */
        const val CORRECTION_COOLDOWN_MS = 1_000L

        /** Polling period of seeks and pre-rolls (ms). */
        const val POLL_MS = 4L

        /** The nearest-first preview of an exact seek while playing waits this long at most. */
        const val NEAREST_WAIT_MS = 400L

        /** A seek that cannot show its frame gives up after this long (the session acks what is shown at its timeout). */
        const val SEEK_GIVE_UP_MS = 20_000L

        /** A pre-roll that is not ready starts anyway after this long (hold/miss drops the late frames). */
        const val PREROLL_GIVE_UP_MS = 12_000L

        /** The frame clock follows the audio master at most this often. */
        const val FOLLOW_INTERVAL_NS = 250_000_000L

        /** Audio decks report a stable position after this warm-up (AudioTrack start). */
        const val AUDIO_WARMUP_MS = 300L

        /** An audio deck further than this from the clock is re-seeked (gross drift only; audio is the master). */
        const val AUDIO_DRIFT_US = 250_000L

        const val MAX_DROP_REPORTS = 240
        const val MAX_TIMINGS = 4096

        /** The live budget of this device (tier slots capped by maxVisualSequences, D-43(e)). */
        fun liveBudgetOf(ctx: EngineContext): Int {
            val tier = ctx.deviceProfile.tier()
            val cap = try {
                ctx.capabilities.current().takeIf { it.supported }?.maxVisualSequences
            } catch (e: Exception) {
                null
            }
            return SlotPlanner.liveBudget(tier, cap)
        }
    }
}
