@file:OptIn(UnstableApi::class, ExperimentalApi::class)
// OWNER: AND-16
//
// AND-16 · Android contingency preview engine, activated by ENG-06 after AND-01's NO-GO for
// CompositionPlayer (R1; AND-01.md §1, §2, §7; ARCH §13.3 "Preview session: AND-16
// MultiPlayerBackend"). This class is the `MultiPlayerBackend : PreviewBackend` of AND-01 §7: AND-10's
// PreviewSessionManager picks it up through its public no-argument constructor
// (`defaultBackend()`), so no AND-10 file changes when it lands.
//
// - Every PreviewBackend method is called on danaview-preview; this facade hops to danaview-gl,
//   where [MultiPlayerEngine] runs (decks, frame clock, EGL and compositing; GlThreadPolicy allows
//   GL only there), and completes from there.
// - Below the API 29 editor gate, or when the JNI shim or an ES 3 context is unavailable, it plays
//   through AND-10's StillFramesBackend instead (paused-exact stills on a frame clock), so a
//   session never fails to open because of the contingency engine.
// - [renderedRangeHook] (D-45) is AND-18's plug-in point: set it on the session's backend
//   (`ctx.previews.get(id)?.backend as? ContingencyPreviewBackend`); NONE by default.
// - Degradations signed off by the owner (D-43(e), 2026-10-11): layers over the tier's live decode
//   budget play as paused-exact stills during playback only; exact seek while playing shows the
//   nearest decoded frame first, then the exact one (+30% allowed); under load a frame is dropped,
//   never shown late or wrong; maxVisualSequences limits live preview only. Adaptive quality (full →
//   1/2 → 1/4 and back unless pinned) and thermal SEVERE are the session's QualityGovernor, fed by
//   this backend's frameDropped reports; a quality step resizes the render target and the decks'
//   ImageReaders.
// Never logs media paths or plan content.

package com.vecvel.danaview.editor.engine.preview.fallback

import android.annotation.SuppressLint
import android.os.Build
import android.util.Log
import android.view.Surface
import androidx.annotation.ChecksSdkIntAtLeast
import androidx.annotation.OptIn
import androidx.media3.common.util.ExperimentalApi
import androidx.media3.common.util.UnstableApi
import androidx.media3.exoplayer.mediacodec.MediaCodecSelector
import com.vecvel.danaview.editor.engine.core.Completion
import com.vecvel.danaview.editor.engine.core.EngineContext
import com.vecvel.danaview.editor.engine.core.EngineErrorCode
import com.vecvel.danaview.editor.engine.core.EngineErrors
import com.vecvel.danaview.editor.engine.core.EngineException
import com.vecvel.danaview.editor.engine.effects.EffectAssets
import com.vecvel.danaview.editor.engine.pigeon.CacheTrimLevelMsg
import com.vecvel.danaview.editor.engine.plan.RenderPlan
import com.vecvel.danaview.editor.engine.preview.FrameRange
import com.vecvel.danaview.editor.engine.preview.PausedFrameRenderer
import com.vecvel.danaview.editor.engine.preview.PreviewBackend
import com.vecvel.danaview.editor.engine.preview.PreviewBackendHost
import com.vecvel.danaview.editor.engine.preview.StillFramesBackend
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.ThreadFactory
import java.util.concurrent.atomic.AtomicInteger

/** The MultiPlayerBackend of AND-01 §7 (file header). */
typealias MultiPlayerBackend = ContingencyPreviewBackend

/**
 * AND-16's preview backend (file header). Keep the public no-argument constructor.
 *
 * The class is constructed on every API level (PreviewSessionManager.defaultBackend), but the
 * API 29 engine is only created in [open] behind the editor gate (SDK_INT >= 29 and the native shim
 * loaded); below it every call goes to the stills delegate, and each engine call is guarded by
 * [engineApi].
 */
class ContingencyPreviewBackend(private val config: Config) : PreviewBackend {
    /** The production backend. */
    constructor() : this(Config())

    /** Tuning and test hooks; read on danaview-gl. */
    class Config(
        /** Live decode slots (null = tier budget capped by the device's maxVisualSequences). */
        @Volatile override var liveBudget: Int? = null,
        /** LUT and sprite files (null = PreviewSessionManager's, else the app's ContentResolver). */
        @Volatile var effectAssets: EffectAssets? = null,
        /** Decoder choice of the decks (null = Media3's default). */
        @Volatile override var codecSelector: MediaCodecSelector? = null,
        /** Signed preview A/V offset of the audio decks (V-N23; + = video earlier). QA-03 measures it on devices. */
        @Volatile override var avOffsetUs: Long = 0L,
        /** Decks lead the compositor by this many output frames (AND-01: 2). */
        @Volatile override var leadFrames: Int = FrameClock.LEAD_FRAMES,
        /** Test hook: extra time per composited frame (injected load). */
        @Volatile override var injectedCompositeDelayMs: Long = 0L,
        /** D-45 rendered ranges (AND-18). */
        @Volatile override var rangeHook: RenderedRangeHook = RenderedRangeHook.NONE,
    ) : EngineOptions

    @Volatile private var delegate: PreviewBackend? = null
    private var engine: MultiPlayerEngine? = null
    private lateinit var host: PreviewBackendHost
    private var worker: ExecutorService? = null

    /** AND-18's rendered-range hook (D-45); [RenderedRangeHook.NONE] by default. */
    var renderedRangeHook: RenderedRangeHook
        get() = config.rangeHook
        set(value) {
            config.rangeHook = value
        }

    /** The tuning of this backend (tests). */
    val options: Config get() = config

    override val name: String get() = delegate?.name ?: NAME

    override val drawsOnSurface: Boolean get() = delegate?.drawsOnSurface ?: true

    /** Cold decks need 0.6–4.2 s for their first exact frame on the emulator (AND-01 §2), watchdog included. */
    override val exactSeekTimeoutMs: Long = EXACT_SEEK_TIMEOUT_MS

    /** Whether this backend plays through the stills fallback. */
    val usesStillsFallback: Boolean get() = delegate != null

    override fun open(host: PreviewBackendHost, done: Completion<Unit>) {
        this.host = host
        if (Build.VERSION.SDK_INT < HwbImport.MIN_API || !HwbImport.available) {
            fallBack(host, done, "API ${Build.VERSION.SDK_INT} or native shim missing")
            return
        }
        val gl = host.ctx.threads.gl
        val pool = Executors.newFixedThreadPool(WORKERS, Workers)
        worker = pool
        val assets = config.effectAssets ?: managerAssets(host) ?: EffectAssets.of(host.ctx.appContext.contentResolver)
        try {
            gl.execute {
                try {
                    val e = MultiPlayerEngine(host, gl, pool, assets, config)
                    e.ensureGl()
                    engine = e
                    done(Result.success(Unit))
                } catch (t: Throwable) {
                    pool.shutdownNow()
                    worker = null
                    host.previewLane.execute { fallBack(host, done, t.javaClass.simpleName) }
                }
            }
        } catch (e: RejectedExecutionException) {
            pool.shutdownNow()
            done(Result.failure(EngineException(EngineErrorCode.cancelled, "engine shut down")))
        }
    }

    /**
     * The LUT/sprite opener the session manager was configured with (tests set it; production
     * leaves it null and the app's ContentResolver opens the files), so playback draws LUTs and
     * sprites exactly like AND-17's paused renderer of the same session.
     */
    @SuppressLint("VisibleForTests")
    private fun managerAssets(host: PreviewBackendHost): EffectAssets? = host.ctx.previews.effectAssets

    private fun fallBack(host: PreviewBackendHost, done: Completion<Unit>, why: String) {
        Log.w(EngineContext.TAG, "contingency preview unavailable ($why); playing paused-exact stills")
        val d = StillFramesBackend()
        delegate = d
        d.open(host, done)
    }

    /** Whether the API 29 engine may run here (the editor gate; lint's NewApi check reads it). */
    @ChecksSdkIntAtLeast(api = HwbImport.MIN_API)
    private fun engineApi(): Boolean = Build.VERSION.SDK_INT >= HwbImport.MIN_API

    /** Runs [block] on danaview-gl with the engine; failures complete [done]. */
    private fun <T> onEngine(done: Completion<T>, block: (MultiPlayerEngine) -> T) {
        val gl = host.ctx.threads.gl
        try {
            gl.execute {
                val e = engine
                if (e == null) {
                    done(Result.failure(EngineException(EngineErrorCode.cancelled, "backend released")))
                    return@execute
                }
                done(runCatching { block(e) }.fold({ Result.success(it) }, { Result.failure(EngineErrors.from(it)) }))
            }
        } catch (e: RejectedExecutionException) {
            done(Result.failure(EngineException(EngineErrorCode.cancelled, "engine shut down")))
        }
    }

    /** Fire-and-forget on danaview-gl. */
    private fun onEngine(block: (MultiPlayerEngine) -> Unit) = onEngine<Unit>({ r ->
        r.exceptionOrNull()?.let { if (EngineErrors.from(it).code != EngineErrorCode.cancelled) Log.w(EngineContext.TAG, "contingency preview: ${EngineErrors.from(it).code}") }
    }) { block(it) }

    override fun rebuild(plan: RenderPlan, done: Completion<Unit>) {
        delegate?.let { return it.rebuild(plan, done) }
        if (!engineApi()) return done(Result.failure(EngineErrors.notSupported("contingency preview")))
        onEngine<Unit>({ r -> r.exceptionOrNull()?.let { done(Result.failure(it)) } }) { e ->
            e.rebuild(plan) { err -> done(if (err == null) Result.success(Unit) else Result.failure(EngineErrors.from(err))) }
        }
    }

    override fun attachSurface(surface: Surface, width: Int, height: Int, done: Completion<Unit>) {
        delegate?.let { return it.attachSurface(surface, width, height, done) }
        if (!engineApi()) return done(Result.failure(EngineErrors.notSupported("contingency preview")))
        onEngine(done) { it.attachSurface(surface, width, height) }
    }

    override fun detachSurface(done: Completion<Unit>) {
        delegate?.let { return it.detachSurface(done) }
        if (!engineApi()) return done(Result.failure(EngineErrors.notSupported("contingency preview")))
        onEngine(done) { it.detachSurface() }
    }

    override fun play(fromFrame: Long, loop: FrameRange?, done: Completion<Unit>) {
        delegate?.let { return it.play(fromFrame, loop, done) }
        if (!engineApi()) return done(Result.failure(EngineErrors.notSupported("contingency preview")))
        onEngine(done) { it.play(fromFrame, loop) }
    }

    override fun pause(done: Completion<Long>) {
        delegate?.let { return it.pause(done) }
        if (!engineApi()) return done(Result.failure(EngineErrors.notSupported("contingency preview")))
        onEngine(done) { it.pause() }
    }

    override fun seek(k: Long, exact: Boolean, done: Completion<Unit>) {
        delegate?.let { return it.seek(k, exact, done) }
        if (!engineApi()) return done(Result.failure(EngineErrors.notSupported("contingency preview")))
        onEngine(done) { it.seek(k, exact) }
    }

    override fun setRenderSize(width: Int, height: Int) {
        delegate?.let { return it.setRenderSize(width, height) }
        if (!engineApi()) return
        onEngine { it.setRenderSize(width, height) }
    }

    override fun setUseProxies(on: Boolean) {
        delegate?.let { return it.setUseProxies(on) }
        if (!engineApi()) return
        onEngine { it.setUseProxies(on) }
    }

    override fun capture(done: Completion<PausedFrameRenderer.Captured>) {
        delegate?.let { return it.capture(done) }
        if (!engineApi()) return done(Result.failure(EngineErrors.notSupported("contingency preview")))
        onEngine(done) { it.capture() }
    }

    override fun trim(level: CacheTrimLevelMsg) {
        delegate?.let { return it.trim(level) }
        if (!engineApi()) return
        onEngine { it.trim(level) }
    }

    override fun suspendForExport(done: Completion<Unit>) {
        delegate?.let { return it.suspendForExport(done) }
        if (!engineApi()) return done(Result.failure(EngineErrors.notSupported("contingency preview")))
        onEngine(done) { it.suspendDecks() }
    }

    override fun resumeAfterExport(done: Completion<Unit>) {
        delegate?.let { return it.resumeAfterExport(done) }
        // Decks are rebuilt by the next play or seek.
        done(Result.success(Unit))
    }

    override fun release(done: Completion<Unit>) {
        delegate?.let { return it.release(done) }
        if (!engineApi()) return done(Result.success(Unit))
        if (!this::host.isInitialized) return done(Result.success(Unit))
        onEngine<Unit>({ r ->
            worker?.shutdownNow()
            worker = null
            done(r.fold({ Result.success(Unit) }, { if (EngineErrors.from(it).code == EngineErrorCode.cancelled) Result.success(Unit) else Result.failure(it) }))
        }) { e ->
            try {
                e.release()
            } finally {
                engine = null
            }
        }
    }

    /** Runs [block] with the engine's counters on danaview-gl (tests and QA logs). */
    fun stats(done: Completion<EngineStats>) {
        if (delegate != null || !engineApi()) return done(Result.success(EngineStats()))
        onEngine(done) { it.stats.copy() }
    }

    /** The engine's state on danaview-gl (tests): mode name and whether it plays. */
    fun state(done: Completion<String>) {
        if (delegate != null || !engineApi()) return done(Result.success("stills"))
        onEngine(done) { it.modeName }
    }

    private object Workers : ThreadFactory {
        private val n = AtomicInteger()

        override fun newThread(r: Runnable): Thread = Thread(r, "danaview-contingency-${n.incrementAndGet()}").apply { isDaemon = true }
    }

    companion object {
        /** The backend's name (logs, tests). */
        const val NAME = "contingency"

        /** Exact-seek ack timeout (see [exactSeekTimeoutMs]). */
        const val EXACT_SEEK_TIMEOUT_MS = 4_000L

        /** Index builds, stills and images run on this many worker threads. */
        const val WORKERS = 2
    }
}
