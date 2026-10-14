@file:OptIn(UnstableApi::class, ExperimentalApi::class)
// OWNER: AND-17
//
// PausedFrameRenderer (D-36, ARCH §13.3 "Paused edits", §13.4): while the preview is paused, the
// frame on screen is drawn by the engine, not by a player. Media3 1.11.1 redraws only input 0 while
// paused and every rebuild recreates all players (AND-01 V-N3, R1 no-go), so paused param patches,
// transients, editing modes (normal, cropSource, matte) and structural edits are rendered here:
//
// - On pause and after each exact seek settles, [prefetch] fetches the EXACT source frames (rule
//   frame, ARCH §11.5: greatest PTS <= s + 500 µs, upright, SDR) of the media and image layers
//   active at t = timeOfFrame(k) (D-35) through a [PausedFrameSource] (production: AND-06's
//   SourceFrameCache and Media3's DataSourceBitmapLoader for images). Play and seek call [cancel],
//   which stops an in-flight prefetch or render (generation counter + JobControl).
// - [render] draws the current ParamSnapshot (plan + transients) at frame k with the editing mode
//   through LayerCompositorGl (AND-09's shaders, premultiplied source-over onto `bg`) into an
//   offscreen canvas-render-size target and presents it on the attached window surface (the
//   SurfaceProducer's Surface). Only frames not yet held are fetched, so a param patch or transient
//   costs one GL pass and a structural edit extracts only newly needed layers. Requests are
//   coalesced: a burst of transients renders the latest state once per pass.
// - The caller detaches the player from the Surface before [attachSurface] (with a Media3 player:
//   `clearVideoSurface(surface)`; the no-argument overload throws in 1.11.1, AND-01 §6.7) and
//   calls [detachSurface] (which destroys our EGL window surface) before reattaching the player on
//   play or seek. AND-16's decks render into their own ImageReaders and hand the Surface back and
//   forth the same way.
//
// Threads: every GL call runs on the danaview-gl lane passed in (the renderer owns one EGL context
// with a 1x1 pbuffer and makes it current at the start of each of its tasks, so the lane can be
// shared); blocking frame fetches run on the renderer's own "danaview-paused" worker; completions
// are called on the GL lane or the worker. Since AND-01 reported a NO-GO for CompositionPlayer
// preview, the parity reference of the paused frame is the Transformer export of the same plan
// (AND-08's mapper + AND-09's effect chain), checked by androidTest paused/PausedParityTest.
// Memory: the renderer holds the bitmaps and textures of the current frame's layers only; sources
// above 1080p are fetched at a power-of-two fraction of their size that still covers the layer's
// largest footprint ([PausedFrames.maxLongSide]). Never logs paths, URIs or user content.

package com.vecvel.danaview.editor.engine.preview

import android.content.Context
import android.graphics.Bitmap
import android.net.Uri
import android.opengl.EGL14
import android.opengl.EGLConfig
import android.opengl.EGLContext
import android.opengl.EGLDisplay
import android.opengl.EGLExt
import android.opengl.EGLSurface
import android.opengl.GLES20
import android.opengl.GLES30
import android.opengl.GLUtils
import android.util.Log
import android.view.Surface
import androidx.annotation.OptIn
import androidx.media3.common.util.ExperimentalApi
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.DataSourceBitmapLoader
import com.vecvel.danaview.editor.engine.core.Completion
import com.vecvel.danaview.editor.engine.core.EngineContext
import com.vecvel.danaview.editor.engine.core.EngineErrorCode
import com.vecvel.danaview.editor.engine.core.EngineErrors
import com.vecvel.danaview.editor.engine.core.EngineException
import com.vecvel.danaview.editor.engine.core.JobControl
import com.vecvel.danaview.editor.engine.core.Lane
import com.vecvel.danaview.editor.engine.effects.EffectAssets
import com.vecvel.danaview.editor.engine.effects.GlResources
import com.vecvel.danaview.editor.engine.effects.GlTarget
import com.vecvel.danaview.editor.engine.effects.LayerFrameOptions
import com.vecvel.danaview.editor.engine.effects.LayerFrames
import com.vecvel.danaview.editor.engine.effects.RenderGeometry
import com.vecvel.danaview.editor.engine.effects.ShaderPrograms
import com.vecvel.danaview.editor.engine.effects.ShaderSources
import com.vecvel.danaview.editor.engine.effects.SourceTexture
import com.vecvel.danaview.editor.engine.pigeon.CacheTrimLevelMsg
import com.vecvel.danaview.editor.engine.pigeon.EditingModeKindMsg
import com.vecvel.danaview.editor.engine.pigeon.EditingModeMsg
import com.vecvel.danaview.editor.engine.plan.LayerParams
import com.vecvel.danaview.editor.engine.plan.ParamSnapshot
import com.vecvel.danaview.editor.engine.plan.PlanAdjust
import com.vecvel.danaview.editor.engine.plan.PlanAsset
import com.vecvel.danaview.editor.engine.plan.PlanAssetKind
import com.vecvel.danaview.editor.engine.plan.PlanCanvas
import com.vecvel.danaview.editor.engine.plan.PlanChroma
import com.vecvel.danaview.editor.engine.plan.PlanCrop
import com.vecvel.danaview.editor.engine.plan.PlanDetail
import com.vecvel.danaview.editor.engine.plan.PlanLayer
import com.vecvel.danaview.editor.engine.plan.PlanLayerKind
import com.vecvel.danaview.editor.engine.plan.PlanMask
import com.vecvel.danaview.editor.engine.plan.PlanMaskShape
import com.vecvel.danaview.editor.engine.plan.PlanSize
import com.vecvel.danaview.editor.engine.plan.PlanTarget
import com.vecvel.danaview.editor.engine.plan.PlanTransform
import com.vecvel.danaview.editor.engine.plan.RenderPlan
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong
import java.util.concurrent.atomic.AtomicReference
import kotlin.math.abs
import kotlin.math.ceil
import kotlin.math.floor
import kotlin.math.max

/** The preview editing mode (ARCH §12.2 `PreviewEditingMode`); [item] is an item id. */
sealed class PausedEditingMode {
    /** Normal drawing. */
    data object Normal : PausedEditingMode()

    /** The whole uncropped source of [item], placed so the current crop stays where it is. */
    data class CropSource(val item: String) : PausedEditingMode()

    /** The chroma-key matte of [item] (alpha as grey). */
    data class Matte(val item: String) : PausedEditingMode()

    /** Whether this mode targets plan layer [layerId] (the item's `<itemId>#v` layer, or a layer named like the item). */
    fun targets(layerId: String): Boolean = when (this) {
        Normal -> false
        is CropSource -> layerId == "$item#v" || layerId == item
        is Matte -> layerId == "$item#v" || layerId == item
    }

    companion object {
        /** The mode of a Pigeon message (an item id is required for cropSource and matte). */
        fun of(msg: EditingModeMsg): PausedEditingMode = when (msg.kind) {
            EditingModeKindMsg.NORMAL -> Normal
            EditingModeKindMsg.CROP_SOURCE -> CropSource(requireNotNull(msg.itemId) { "cropSource without item" })
            EditingModeKindMsg.MATTE -> Matte(requireNotNull(msg.itemId) { "matte without item" })
        }
    }
}

/** What to fetch for one picture layer: a video frame (rule frame of [sourceTimeUs]) or a decoded image. */
data class PausedFrameRequest(
    /** VIDEO or IMAGE. */
    val kind: PlanAssetKind,
    /** The media URI (the proxy's when proxies are used). */
    val uri: String,
    /** Cache identity (the asset fingerprint, `#proxy` appended for a proxy), or null. */
    val fingerprint: String?,
    /** Source time on the asset's presentation timeline (0 for images). */
    val sourceTimeUs: Long,
    /** Long-side bound in px, or null for full size. */
    val maxLongSide: Int?,
)

/** Supplies the source pictures of the paused frame. Blocking; the returned bitmap is shared (never recycled by the renderer). */
fun interface PausedFrameSource {
    /** The upright, SDR, ARGB_8888 picture of [request]; throws EngineException. */
    fun frame(request: PausedFrameRequest, control: JobControl): Bitmap
}

/**
 * The production [PausedFrameSource]: video frames from the engine's SourceFrameCache (AND-06,
 * EXACT and cached), images through Media3's DataSourceBitmapLoader (the loader Transformer's
 * image path uses, EXIF orientation applied) with a small LRU.
 */
class EngineFrameSource(private val ctx: EngineContext) : PausedFrameSource {
    private val images = object : LinkedHashMap<String, Bitmap>(8, 0.75f, true) {
        override fun removeEldestEntry(eldest: MutableMap.MutableEntry<String, Bitmap>?): Boolean = size > IMAGE_CAPACITY
    }

    override fun frame(request: PausedFrameRequest, control: JobControl): Bitmap = when (request.kind) {
        PlanAssetKind.VIDEO -> ctx.sourceFrames.frame(request.uri, request.fingerprint, request.sourceTimeUs, request.maxLongSide, control)
        PlanAssetKind.IMAGE -> image(request, control)
        else -> throw EngineException(EngineErrorCode.unsupportedMedia, "not a picture asset")
    }

    private fun image(request: PausedFrameRequest, control: JobControl): Bitmap {
        val key = "${request.maxLongSide ?: 0}|${request.fingerprint ?: request.uri}"
        synchronized(images) { images[key]?.let { return it } }
        control.throwIfCancelled()
        val loader = DataSourceBitmapLoader.Builder(ctx.appContext)
            .setMaximumOutputDimension(request.maxLongSide ?: LayerFrames.MAX_RASTER_SIDE)
            .build()
        val decoded = try {
            loader.loadBitmap(Uri.parse(request.uri)).get(IMAGE_TIMEOUT_S, TimeUnit.SECONDS)
        } catch (e: Exception) {
            throw EngineException(EngineErrorCode.decodeFailed, "image could not be decoded", cause = e)
        }
        val bitmap = if (decoded.config != Bitmap.Config.ARGB_8888) decoded.copy(Bitmap.Config.ARGB_8888, false) else decoded
        synchronized(images) { images[key] = bitmap }
        return bitmap
    }

    /** Drops the decoded images. */
    fun clear() = synchronized(images) { images.clear() }

    private companion object {
        const val IMAGE_CAPACITY = 4
        const val IMAGE_TIMEOUT_S = 30L
    }
}

/** Pure parts of the paused frame (JVM-tested). */
object PausedFrames {
    /** Sources with more pixels than this are fetched downscaled when the layer needs less. */
    const val FULL_SIZE_LIMIT_PX: Long = 1920L * 1088L

    /** Smallest fraction of a source's size fetched. */
    const val MIN_FRACTION_LOG2 = 3

    /**
     * The source time of media layer [layer] at plan time [t] (ARCH §11.5): `hold` shows `map[0].s0`;
     * otherwise `s = s0 + (t − t0)·(s1 − s0)/(t1 − t0)` on the segment containing [t] (clamped to
     * the map), floored to µs. The rule frame (<= s + 500 µs) is resolved by the frame source.
     */
    fun sourceTimeUs(layer: PlanLayer, t: Long): Long {
        val map = layer.map
        require(map.isNotEmpty()) { "media layer without map" }
        if (layer.hold) return map[0].s0
        val seg = map.firstOrNull { t >= it.t0 && t < it.t1 } ?: if (t < map[0].t0) map[0] else map[map.size - 1]
        if (seg.t1 <= seg.t0) return seg.s0
        val tc = t.coerceIn(seg.t0, seg.t1)
        return floor(seg.sourceAt(tc.toDouble()) + 1e-6).toLong().coerceAtLeast(0L)
    }

    /** Display size (rotation applied) of [asset], or null when the plan does not carry it. */
    fun displaySize(asset: PlanAsset): Pair<Int, Int>? {
        val w = asset.w ?: return null
        val h = asset.h ?: return null
        if (w <= 0 || h <= 0) return null
        return if ((asset.rot ?: 0) % 180 != 0) Pair(h, w) else Pair(w, h)
    }

    /**
     * The long-side bound of the fetched picture: null (full size) for sources up to 1080p (the
     * export samples the full source, so paused and exported frames match), or for a larger source
     * the smallest power-of-two fraction (down to 1/8) of its long side that still covers the
     * layer's largest footprint `base·max(|s|, maxScale)·renderScale` over its crop.
     */
    fun maxLongSide(params: LayerParams, maxScale: Double, display: Pair<Int, Int>?, geometry: RenderGeometry): Int? {
        val (dw, dh) = display ?: return null
        if (dw.toLong() * dh.toLong() <= FULL_SIZE_LIMIT_PX) return null
        val scale = max(abs(params.xf.s), abs(maxScale))
        val cropW = params.crop.r - params.crop.l
        val cropH = params.crop.b - params.crop.t
        if (!(cropW > 0 && cropH > 0 && scale > 0)) return null
        val needX = params.base.w * scale * geometry.kx / cropW
        val needY = params.base.h * scale * geometry.ky / cropH
        val f = max(needX / dw, needY / dh)
        if (!f.isFinite() || f > 0.5) return null
        var fraction = 0.5
        var n = 1
        while (n < MIN_FRACTION_LOG2 && fraction / 2 >= f) {
            fraction /= 2
            n++
        }
        return ceil(max(dw, dh) * fraction).toInt()
    }

    /**
     * The fetch for a picture layer, or null for solids, sprites, a missing asset or an asset that is
     * not a picture. With [useProxies] a video asset's proxy is used when it has one.
     */
    fun request(plan: RenderPlan, layer: PlanLayer, params: LayerParams, t: Long, useProxies: Boolean, geometry: RenderGeometry): PausedFrameRequest? {
        val asset = layer.asset?.let { plan.assets[it] } ?: return null
        val bound = maxLongSide(params, ParamSnapshot.maxScale(layer), displaySize(asset), geometry)
        val fp = asset.fp.ifEmpty { null }
        return when (layer.kind) {
            PlanLayerKind.MEDIA -> {
                if (asset.kind != PlanAssetKind.VIDEO) return null
                val proxy = if (useProxies) asset.proxyUri else null
                PausedFrameRequest(
                    PlanAssetKind.VIDEO,
                    proxy ?: asset.uri,
                    if (proxy != null) "${fp ?: asset.uri}#proxy" else fp,
                    sourceTimeUs(layer, t),
                    bound,
                )
            }
            PlanLayerKind.IMAGE -> if (asset.kind == PlanAssetKind.IMAGE) PausedFrameRequest(PlanAssetKind.IMAGE, asset.uri, fp, 0L, bound) else null
            PlanLayerKind.SOLID, PlanLayerKind.SPRITE -> null
        }
    }

    /**
     * The layer as the editing [mode] shows it: params and frame options. cropSource shows the whole
     * source with the crop region where it is now (base grown by 1/crop, centre moved by the crop
     * offset through the placement's rotation, scale and flips; the item mask, which belongs to the
     * cropped box, is dropped); matte sets the matte flag.
     */
    fun applyMode(mode: PausedEditingMode, params: LayerParams): Pair<LayerParams, LayerFrameOptions> {
        if (!mode.targets(params.id)) return params to LayerFrameOptions()
        return when (mode) {
            is PausedEditingMode.Matte -> params to LayerFrameOptions(matte = true)
            is PausedEditingMode.CropSource -> uncropped(params) to LayerFrameOptions()
            PausedEditingMode.Normal -> params to LayerFrameOptions()
        }
    }

    /** [params] with the full source shown and the current crop region kept in place (see [applyMode]). */
    fun uncropped(params: LayerParams): LayerParams {
        val c = params.crop
        val cw = c.r - c.l
        val ch = c.b - c.t
        if (c.isFull || !(cw > 0 && ch > 0)) return params
        val fullW = params.base.w / cw
        val fullH = params.base.h / ch
        // Offset of the crop centre from the full centre, in base-local px.
        val dx = (c.l + c.r) / 2 * fullW - fullW / 2
        val dy = (c.t + c.b) / 2 * fullH - fullH / 2
        val xf = params.xf
        val (cos, sin) = LayerFrames.cosSinDeg(xf.r)
        val sx = if (xf.fx) -xf.s else xf.s
        val sy = if (xf.fy) -xf.s else xf.s
        val ox = cos * sx * dx - sin * sy * dy
        val oy = sin * sx * dx + cos * sy * dy
        val cx = xf.cx ?: 0.0
        val cy = xf.cy ?: 0.0
        return params.copy(
            base = PlanSize(fullW, fullH),
            crop = PlanCrop.FULL,
            xf = xf.copy(cx = cx - ox, cy = cy - oy),
            mask = null,
        )
    }
}

/**
 * The paused-frame renderer (file header). [glLane] is the danaview-gl lane, [frames] the source
 * pictures, [snapshot] the session's ParamSnapshot reference (shared with the effects / AND-16's
 * compositor), [assets] opens LUT and sprite files (null = the app's ContentResolver), [shaders]
 * reads the dv_*.glsl sources (null = the library's assets).
 */
class PausedFrameRenderer(
    private val appContext: Context,
    private val glLane: Lane,
    private val frames: PausedFrameSource,
    private val snapshot: AtomicReference<ParamSnapshot>,
    assets: EffectAssets? = null,
    private val shaders: ((String) -> String)? = null,
) {
    /** One render: frame [k] of plan [rev]; layer counts; frames fetched; times in ms (wall; [gpuNs] when timer queries exist). */
    data class RenderResult(
        val k: Long,
        val rev: Long,
        val layers: Int,
        val drawn: Int,
        val fetched: Int,
        val missing: Int,
        val fetchMs: Double,
        val glMs: Double,
        val totalMs: Double,
        val presented: Boolean,
        val gpuNs: Long?,
    )

    /** One prefetch: frame [k], picture layers, frames newly fetched, missing ones, wall ms. */
    data class PrefetchResult(val k: Long, val pictures: Int, val fetched: Int, val missing: Int, val wallMs: Double)

    /** A read-back of the last composed frame: [rgba] top-down rows, [width] × [height]. */
    class Captured(val width: Int, val height: Int, val rgba: ByteArray)

    private val effectAssets: EffectAssets = assets ?: EffectAssets.of(appContext.contentResolver)
    private val threadIds = AtomicInteger()
    private val worker: ExecutorService = Executors.newSingleThreadExecutor { r ->
        Thread(r, "danaview-paused-${threadIds.incrementAndGet()}").apply { isDaemon = true }
    }
    private val generation = AtomicLong()

    @Volatile private var frameIndex = 0L
    @Volatile private var mode: PausedEditingMode = PausedEditingMode.Normal
    @Volatile private var useProxies = false
    @Volatile private var disposed = false

    // Render request coalescing (guarded by `this`).
    private val pending = ArrayList<Completion<RenderResult>>()
    private var pendingSinceNs = 0L
    private var renderScheduled = false

    // Worker-confined: the bitmaps of the frame being shown.
    private var held = HashMap<PausedFrameRequest, Bitmap>()

    // GL-lane-confined state.
    private var egl: PausedEgl? = null
    private var programs: ShaderPrograms? = null
    private var compositor: LayerCompositorGl? = null
    private var canvas: GlTarget? = null
    private val textures = HashMap<PausedFrameRequest, SourceTexture>()
    private var window: EGLSurface = EGL14.EGL_NO_SURFACE
    private var windowW = 0
    private var windowH = 0
    @Volatile private var renderW = 0
    @Volatile private var renderH = 0

    /** Renders completed so far. */
    val renderCount: Long get() = renders.get()
    private val renders = AtomicLong()

    /** Frames fetched (not already held) so far. */
    val fetchCount: Long get() = fetches.get()
    private val fetches = AtomicLong()

    /** The frame index drawn (the paused playhead). */
    val frame: Long get() = frameIndex

    /** Whether a window surface is attached. */
    val hasSurface: Boolean get() = windowAttached
    @Volatile private var windowAttached = false

    // ---- state ----

    /** Sets the paused playhead frame k (output grid; D-35). */
    fun setFrame(k: Long) {
        require(k >= 0) { "negative frame" }
        frameIndex = k
    }

    /** Sets the editing mode; the next [render] shows it. */
    fun setEditingMode(mode: PausedEditingMode) {
        this.mode = mode
    }

    /** Whether video layers use their proxies (the preview's useProxies). */
    fun setUseProxies(on: Boolean) {
        useProxies = on
    }

    /** Sets the offscreen render size used while no surface is attached (the attached surface's size wins). */
    fun setRenderSize(width: Int, height: Int) {
        require(width > 0 && height > 0) { "render size" }
        renderW = width
        renderH = height
    }

    /** Stops an in-flight prefetch or render (play, seek, dispose); pending renders complete with `cancelled`. */
    fun cancel() {
        generation.incrementAndGet()
    }

    /**
     * Creates the EGL context, compiles every shader program and draws each pass once on a 32 × 32
     * target (session open), so the first paused edit does not pay the setup: drivers finish
     * compiling a program on its first draw (about 1.2 s for the first full frame on the API 35
     * emulator without warm-up).
     */
    fun warmUp(done: Completion<Unit>) {
        onGl(done) {
            val e = ensureGl()
            e.makeCurrent(if (window != EGL14.EGL_NO_SURFACE) window else null)
            programs?.compileAll()
            compositor?.let { warmDraw(it) }
            Unit
        }
    }

    /** GL lane: one tiny frame through look (chroma, grade), blur, detail (sharpen, vignette, mask), place and solid. */
    private fun warmDraw(comp: LayerCompositorGl) {
        val n = WARM_SIZE
        val texture = GlResources.createTexture(n, n)
        val target = GlTarget.rgba8(n, n)
        try {
            val plan = RenderPlan(
                rev = 0, target = PlanTarget.PREVIEW, canvas = PlanCanvas(n, n, 30), durUs = 1_000_000L,
                assets = emptyMap(), layers = emptyList(), audio = emptyList(),
            )
            val xf = PlanTransform(cx = n / 2.0, cy = n / 2.0, r = 10.0)
            val picture = LayerParams(
                id = "warm", kind = PlanLayerKind.MEDIA, t = 0, xf = xf, base = PlanSize(n.toDouble(), n.toDouble()), crop = PlanCrop.FULL,
                adj = PlanAdjust(contrast = 0.1), detail = PlanDetail(sharpen = 0.2, blur = 1.0, vignette = 0.2), lut = null,
                chroma = PlanChroma(key = 0x00FF00), mask = PlanMask(PlanMaskShape.ELLIPSE, feather = 0.1), reveal = null,
                cmasks = emptyList(), color = null,
            )
            val solid = picture.copy(id = "warm-solid", kind = PlanLayerKind.SOLID, color = 0x80FFFFFF.toInt(), detail = null, chroma = null, mask = null)
            val layer = PlanLayer(id = "warm", z = 0, t0 = 0, t1 = 1_000_000L, kind = PlanLayerKind.MEDIA)
            comp.compose(
                plan,
                RenderGeometry(n, n, n, n),
                listOf(
                    LayerCompositorGl.Input(layer, picture, SourceTexture(texture, n, n, transform = SourceTexture.TOP_DOWN, premultiplied = true)),
                    LayerCompositorGl.Input(layer.copy(id = "warm-solid", kind = PlanLayerKind.SOLID), solid, null),
                ),
                target,
            )
            GLES20.glFinish()
        } finally {
            target.release()
            GlResources.deleteTexture(texture)
            GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, 0)
        }
    }

    // ---- surface ----

    /**
     * Attaches the preview Surface ([width] × [height], the SurfaceProducer size) so [render]
     * presents onto it. The caller has detached its player first (`clearVideoSurface(surface)`).
     */
    fun attachSurface(surface: Surface, width: Int, height: Int, done: Completion<Unit>) {
        require(width > 0 && height > 0) { "surface size" }
        onGl(done) {
            val e = ensureGl()
            destroyWindow(e)
            window = e.createWindow(surface)
            windowW = width
            windowH = height
            renderW = width
            renderH = height
            windowAttached = true
            e.makeCurrent(window)
            EGL14.eglSwapInterval(e.display, 0)
        }
    }

    /** Destroys the EGL window surface so a player (or AND-16's frame clock) can render to the Surface again. */
    fun detachSurface(done: Completion<Unit>) {
        onGl(done) { egl?.let { destroyWindow(it) } }
    }

    /** Presents the last composed frame again (after a surface was re-attached); fails when nothing was composed. */
    fun present(done: Completion<Boolean>) {
        onGl(done) {
            val e = egl ?: throw EngineException(EngineErrorCode.internal, "nothing rendered")
            val c = canvas ?: throw EngineException(EngineErrorCode.internal, "nothing rendered")
            // ES 2 cannot blit the kept canvas; the caller renders again instead.
            if (programs?.caps?.isEs3 != true) false else presentCanvas(e, c, null, blit = true)
        }
    }

    // ---- prefetch and render ----

    /**
     * Sets the playhead to [k] and fetches the EXACT frames of the picture layers active at
     * timeOfFrame(k) (on pause and after each exact seek settles). Nothing is drawn.
     */
    fun prefetch(k: Long, done: Completion<PrefetchResult>? = null) {
        setFrame(k)
        if (disposed) {
            done?.invoke(Result.failure(EngineException(EngineErrorCode.cancelled, "renderer disposed")))
            return
        }
        val gen = generation.get()
        worker.execute {
            val started = System.nanoTime()
            val prepared = runCatching {
                checkAlive()
                val snap = snapshot.get()
                val t = snap.outputGrid.timeOfFrame(k)
                val geometry = geometry(snap.plan)
                val wanted = LinkedHashMap<PausedFrameRequest, Unit>()
                val active = LayerCompositorGl.activeLayers(snap, t)
                for ((layer, params) in active) {
                    val (p, _) = PausedFrames.applyMode(mode, params)
                    PausedFrames.request(snap.plan, layer, p, t, useProxies, geometry)?.let { wanted[it] = Unit }
                }
                val (fetched, missing) = resolve(wanted.keys, gen)
                val uploads = wanted.keys.mapNotNull { r -> held[r]?.let { r to it } }
                Triple(PrefetchResult(k, wanted.size, fetched, missing, 0.0), uploads, snap.plan to active.map { it.first })
            }.mapError()
            val value = prepared.getOrNull()
            if (value == null) {
                done?.invoke(Result.failure(prepared.exceptionOrNull()!!))
                return@execute
            }
            // GL: upload the fetched pictures and the active layers' LUT / sprite textures now, so
            // the first paused edit only draws.
            glLane.execute {
                val r = runCatching {
                    if (generation.get() != gen) throw EngineException(EngineErrorCode.cancelled, "cancelled")
                    checkAlive()
                    val e = ensureGl()
                    e.makeCurrent(if (window != EGL14.EGL_NO_SURFACE) window else null)
                    for ((request, bitmap) in value.second) if (!textures.containsKey(request)) textures[request] = upload(bitmap)
                    val (plan, layers) = value.third
                    for (layer in layers) compositor?.preload(plan, layer)
                    value.first.copy(wallMs = (System.nanoTime() - started) / 1e6)
                }.mapError()
                done?.invoke(r)
            }
        }
    }

    /**
     * Renders the current snapshot (plan + transients) at the paused frame with the editing mode and
     * presents it on the attached surface. Requests that arrive while one is queued are coalesced.
     */
    fun render(done: Completion<RenderResult>? = null) {
        if (disposed) {
            done?.invoke(Result.failure(EngineException(EngineErrorCode.cancelled, "renderer disposed")))
            return
        }
        synchronized(this) {
            if (pending.isEmpty() && !renderScheduled) pendingSinceNs = System.nanoTime()
            if (done != null) pending += done
            if (renderScheduled) return
            renderScheduled = true
        }
        worker.execute { runRender() }
    }

    private fun runRender() {
        val callbacks: List<Completion<RenderResult>>
        val since: Long
        synchronized(this) {
            callbacks = ArrayList(pending)
            pending.clear()
            since = pendingSinceNs
            renderScheduled = false
        }
        val gen = generation.get()
        val fetchStart = System.nanoTime()
        val list = try {
            checkAlive()
            buildDrawList(gen)
        } catch (t: Throwable) {
            val r = Result.failure<RenderResult>(EngineErrors.from(t))
            callbacks.forEach { it(r) }
            return
        }
        val fetchMs = (System.nanoTime() - fetchStart) / 1e6
        glLane.execute {
            val result = runCatching {
                if (generation.get() != gen) throw EngineException(EngineErrorCode.cancelled, "cancelled")
                checkAlive()
                val glStart = System.nanoTime()
                val (stats, presented) = drawList(list)
                val end = System.nanoTime()
                renders.incrementAndGet()
                RenderResult(
                    k = list.k,
                    rev = list.rev,
                    layers = list.entries.size,
                    drawn = stats.drawn,
                    fetched = list.fetched,
                    missing = list.missing,
                    fetchMs = fetchMs,
                    glMs = (end - glStart) / 1e6,
                    totalMs = (end - since) / 1e6,
                    presented = presented,
                    gpuNs = stats.gpuNs,
                )
            }.mapError()
            callbacks.forEach { it(result) }
        }
    }

    private class DrawEntry(val layer: PlanLayer, val params: LayerParams, val options: LayerFrameOptions, val request: PausedFrameRequest?, val bitmap: Bitmap?)

    private class DrawList(val k: Long, val rev: Long, val plan: RenderPlan, val geometry: RenderGeometry, val entries: List<DrawEntry>, val fetched: Int, val missing: Int)

    /** Worker: evaluates the active layers at the frame and resolves their pictures. */
    private fun buildDrawList(gen: Long): DrawList {
        val snap = snapshot.get()
        val k = frameIndex
        val t = snap.outputGrid.timeOfFrame(k)
        val geometry = geometry(snap.plan)
        val currentMode = mode
        val prepared = LayerCompositorGl.activeLayers(snap, t).map { (layer, params) ->
            val (p, options) = PausedFrames.applyMode(currentMode, params)
            Triple(layer, p to options, PausedFrames.request(snap.plan, layer, p, t, useProxies, geometry))
        }
        val (fetched, missing) = resolve(prepared.mapNotNull { it.third }, gen)
        val entries = prepared.map { (layer, po, request) ->
            DrawEntry(layer, po.first, po.second, request, request?.let { held[it] })
        }
        return DrawList(k, snap.rev, snap.plan, geometry, entries, fetched, missing)
    }

    /**
     * Worker: makes [wanted] the held set, fetching what is not held yet. Returns (fetched,
     * missing); a failed fetch leaves its layer out of the frame (cancellation propagates).
     */
    private fun resolve(wanted: Collection<PausedFrameRequest>, gen: Long): Pair<Int, Int> {
        val control = GenerationControl(gen)
        val next = HashMap<PausedFrameRequest, Bitmap>()
        var fetched = 0
        var missing = 0
        for (request in wanted) {
            if (next.containsKey(request)) continue
            val have = held[request]
            if (have != null) {
                next[request] = have
                continue
            }
            control.throwIfCancelled()
            try {
                next[request] = frames.frame(request, control)
                fetched++
                fetches.incrementAndGet()
            } catch (e: EngineException) {
                if (e.code == EngineErrorCode.cancelled || control.isCancelled) throw EngineException(EngineErrorCode.cancelled, "cancelled")
                missing++
                Log.w(EngineContext.TAG, "paused frame: source frame unavailable (${e.code})")
            }
        }
        held = next
        return fetched to missing
    }

    private inner class GenerationControl(private val gen: Long) : JobControl {
        override val jobId: String get() = "paused-frame"
        override val isCancelled: Boolean get() = generation.get() != gen || disposed
        override fun reportProgress(fraction: Double) = Unit
    }

    private fun geometry(plan: RenderPlan): RenderGeometry {
        val w = if (renderW > 0) renderW else plan.canvas.w
        val h = if (renderH > 0) renderH else plan.canvas.h
        return RenderGeometry(plan.canvas.w, plan.canvas.h, w, h)
    }

    /** GL lane: uploads new pictures, drops textures no longer shown, composes into the canvas target and presents it. */
    private fun drawList(list: DrawList): Pair<LayerCompositorGl.Stats, Boolean> {
        val e = ensureGl()
        if (window != EGL14.EGL_NO_SURFACE) e.makeCurrent(window) else e.makeCurrent(null)
        val comp = compositor!!
        val inUse = HashSet<PausedFrameRequest>()
        val inputs = ArrayList<LayerCompositorGl.Input>(list.entries.size)
        for (entry in list.entries) {
            val source = if (entry.request != null && entry.bitmap != null) {
                inUse += entry.request
                textures.getOrPut(entry.request) { upload(entry.bitmap) }
            } else {
                null
            }
            inputs += LayerCompositorGl.Input(entry.layer, entry.params, source, entry.options)
        }
        val stale = textures.keys.filter { it !in inUse }
        for (key in stale) textures.remove(key)?.let { GlResources.deleteTexture(it.id) }
        val g = list.geometry
        val target = canvasTarget(g.renderW, g.renderH)
        val stats = comp.compose(list.plan, g, inputs, target)
        if (window != EGL14.EGL_NO_SURFACE && !comp.programs.caps.isEs3) {
            // ES 2 has no blit: compose once more straight into the window's framebuffer.
            e.makeCurrent(window)
            GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, 0)
            GLES20.glViewport(0, 0, windowW, windowH)
            comp.compose(list.plan, RenderGeometry(g.canvasW, g.canvasH, windowW, windowH), inputs, null)
        }
        val presented = presentCanvas(e, target, list.k to list.plan.canvas.fps, blit = comp.programs.caps.isEs3)
        return stats to presented
    }

    private fun canvasTarget(w: Int, h: Int): GlTarget {
        val c = canvas
        if (c != null && c.width == w && c.height == h) return c
        c?.release()
        return GlTarget.rgba8(w, h).also { canvas = it }
    }

    /** Blits the canvas onto the window (ES 3; ES 2 composed into it already) and swaps; false without a window. */
    private fun presentCanvas(e: PausedEgl, c: GlTarget, frame: Pair<Long, Int>?, blit: Boolean): Boolean {
        if (window == EGL14.EGL_NO_SURFACE) return false
        e.makeCurrent(window)
        if (blit) blitToWindow(c)
        if (frame != null) {
            val (k, fps) = frame
            // pts = P(k) = round(k·1e6/fps) (D-35), in ns.
            val pts = Math.floorDiv(2 * k * 1_000_000L + fps, 2L * fps)
            EGLExt.eglPresentationTimeANDROID(e.display, window, pts * 1000L)
        }
        if (!EGL14.eglSwapBuffers(e.display, window)) {
            val code = EGL14.eglGetError()
            throw EngineException(EngineErrorCode.surfaceLost, "swap failed 0x${Integer.toHexString(code)}")
        }
        return true
    }

    private fun blitToWindow(c: GlTarget) {
        GLES30.glBindFramebuffer(GLES30.GL_READ_FRAMEBUFFER, c.framebuffer)
        GLES30.glBindFramebuffer(GLES30.GL_DRAW_FRAMEBUFFER, 0)
        val filter = if (c.width == windowW && c.height == windowH) GLES20.GL_NEAREST else GLES20.GL_LINEAR
        GLES30.glBlitFramebuffer(0, 0, c.width, c.height, 0, 0, windowW, windowH, GLES20.GL_COLOR_BUFFER_BIT, filter)
        GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, 0)
        val err = GLES20.glGetError()
        check(err == GLES20.GL_NO_ERROR) { "blit failed 0x${Integer.toHexString(err)}" }
    }

    /** An RGBA8 texture of [bitmap] (row 0 = top: TOP_DOWN, premultiplied as Android bitmaps are). */
    private fun upload(bitmap: Bitmap): SourceTexture {
        val src = if (bitmap.config == Bitmap.Config.ARGB_8888) bitmap else bitmap.copy(Bitmap.Config.ARGB_8888, false)
        val id = GlResources.createTexture(src.width, src.height)
        GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, id)
        GLUtils.texSubImage2D(GLES20.GL_TEXTURE_2D, 0, 0, 0, src)
        GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, 0)
        val err = GLES20.glGetError()
        if (err != GLES20.GL_NO_ERROR) {
            GlResources.deleteTexture(id)
            throw EngineException(EngineErrorCode.gpuUnavailable, "texture upload failed 0x${Integer.toHexString(err)}")
        }
        return SourceTexture(id, src.width, src.height, transform = SourceTexture.TOP_DOWN, premultiplied = src.hasAlpha() && src.isPremultiplied)
    }

    // ---- read-back, trim, dispose ----

    /** Reads the last composed frame back (debugCaptureFrame, tests). */
    fun capture(done: Completion<Captured>) {
        onGl(done) {
            val e = egl ?: throw EngineException(EngineErrorCode.internal, "nothing rendered")
            val c = canvas ?: throw EngineException(EngineErrorCode.internal, "nothing rendered")
            e.makeCurrent(if (window != EGL14.EGL_NO_SURFACE) window else null)
            GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, c.framebuffer)
            val buf = ByteBuffer.allocateDirect(c.width * c.height * 4).order(ByteOrder.nativeOrder())
            GLES20.glReadPixels(0, 0, c.width, c.height, GLES20.GL_RGBA, GLES20.GL_UNSIGNED_BYTE, buf)
            GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, 0)
            val out = ByteArray(c.width * c.height * 4)
            val stride = c.width * 4
            for (y in 0 until c.height) {
                buf.position((c.height - 1 - y) * stride)
                buf.get(out, y * stride, stride)
            }
            Captured(c.width, c.height, out)
        }
    }

    /**
     * Drops held pictures and their textures on memory pressure (the next render fetches again);
     * the shown frame stays on the surface.
     */
    fun trim(level: CacheTrimLevelMsg) {
        if (level == CacheTrimLevelMsg.MEMORY_PRESSURE || level == CacheTrimLevelMsg.BACKGROUND || level == CacheTrimLevelMsg.CLEAR_ALL) {
            worker.execute { held = HashMap() }
            glLane.execute {
                if (egl == null || disposed) return@execute
                egl?.makeCurrent(if (window != EGL14.EGL_NO_SURFACE) window else null)
                for (t in textures.values) GlResources.deleteTexture(t.id)
                textures.clear()
            }
        }
    }

    /** Releases every GL object, the EGL context and the worker. Pending renders complete with `cancelled`. */
    fun dispose(done: Completion<Unit>) {
        cancel()
        val wasDisposed = disposed
        disposed = true
        if (wasDisposed) {
            done(Result.success(Unit))
            return
        }
        worker.execute { held = HashMap() }
        worker.shutdown()
        glLane.execute {
            val r = runCatching { releaseGl() }.mapError()
            done(r)
        }
    }

    private fun releaseGl() {
        val e = egl ?: return
        e.makeCurrent(null)
        for (t in textures.values) GlResources.deleteTexture(t.id)
        textures.clear()
        canvas?.release()
        canvas = null
        compositor?.release()
        compositor = null
        programs?.release()
        programs = null
        destroyWindow(e)
        e.release()
        egl = null
    }

    // ---- GL plumbing ----

    private fun ensureGl(): PausedEgl {
        egl?.let { return it }
        val e = PausedEgl()
        egl = e
        e.makeCurrent(null)
        val p = if (shaders != null) ShaderPrograms.acquire(shaders) else ShaderPrograms.acquire(ShaderSources.assetReader(appContext))
        programs = p
        compositor = LayerCompositorGl(p, effectAssets)
        return e
    }

    private fun destroyWindow(e: PausedEgl) {
        if (window == EGL14.EGL_NO_SURFACE) return
        e.makeCurrent(null)
        EGL14.eglDestroySurface(e.display, window)
        window = EGL14.EGL_NO_SURFACE
        windowAttached = false
    }

    private fun checkAlive() {
        if (disposed) throw EngineException(EngineErrorCode.cancelled, "renderer disposed")
    }

    private fun <T> onGl(done: Completion<T>, block: () -> T) {
        if (disposed) {
            done(Result.failure(EngineException(EngineErrorCode.cancelled, "renderer disposed")))
            return
        }
        glLane.execute { done(runCatching(block).mapError()) }
    }

    private fun <T> Result<T>.mapError(): Result<T> = fold({ Result.success(it) }, { Result.failure(EngineErrors.from(it)) })

    private companion object {
        const val WARM_SIZE = 32
    }
}

/**
 * The renderer's EGL context: ES 3 (ES 2 fallback), a config for window and pbuffer surfaces and a
 * 1x1 pbuffer that is current while no window is attached. Used on the GL lane only.
 */
private class PausedEgl {
    val display: EGLDisplay = EGL14.eglGetDisplay(EGL14.EGL_DEFAULT_DISPLAY)
    private val config: EGLConfig
    val context: EGLContext
    private val pbuffer: EGLSurface

    init {
        val version = IntArray(2)
        check(EGL14.eglInitialize(display, version, 0, version, 1)) { "eglInitialize failed" }
        var chosen = choose(EGLExt.EGL_OPENGL_ES3_BIT_KHR)
        var ctx = chosen?.let { EGL14.eglCreateContext(display, it, EGL14.EGL_NO_CONTEXT, intArrayOf(EGL14.EGL_CONTEXT_CLIENT_VERSION, 3, EGL14.EGL_NONE), 0) }
        if (chosen == null || ctx == null || ctx == EGL14.EGL_NO_CONTEXT) {
            chosen = checkNotNull(choose(EGL14.EGL_OPENGL_ES2_BIT)) { "no EGL config" }
            ctx = EGL14.eglCreateContext(display, chosen, EGL14.EGL_NO_CONTEXT, intArrayOf(EGL14.EGL_CONTEXT_CLIENT_VERSION, 2, EGL14.EGL_NONE), 0)
        }
        if (ctx == null || ctx == EGL14.EGL_NO_CONTEXT) throw EngineException(EngineErrorCode.gpuUnavailable, "eglCreateContext failed 0x${Integer.toHexString(EGL14.eglGetError())}")
        config = chosen
        context = ctx
        pbuffer = EGL14.eglCreatePbufferSurface(display, config, intArrayOf(EGL14.EGL_WIDTH, 1, EGL14.EGL_HEIGHT, 1, EGL14.EGL_NONE), 0)
        if (pbuffer == EGL14.EGL_NO_SURFACE) {
            EGL14.eglDestroyContext(display, context)
            throw EngineException(EngineErrorCode.gpuUnavailable, "pbuffer failed 0x${Integer.toHexString(EGL14.eglGetError())}")
        }
    }

    private fun choose(renderable: Int): EGLConfig? {
        val attribs = intArrayOf(
            EGL14.EGL_RED_SIZE, 8, EGL14.EGL_GREEN_SIZE, 8, EGL14.EGL_BLUE_SIZE, 8, EGL14.EGL_ALPHA_SIZE, 8,
            EGL14.EGL_RENDERABLE_TYPE, renderable,
            EGL14.EGL_SURFACE_TYPE, EGL14.EGL_WINDOW_BIT or EGL14.EGL_PBUFFER_BIT,
            EGL14.EGL_NONE,
        )
        val configs = arrayOfNulls<EGLConfig>(1)
        val n = IntArray(1)
        return if (EGL14.eglChooseConfig(display, attribs, 0, configs, 0, 1, n, 0) && n[0] > 0) configs[0] else null
    }

    /** A window surface on [surface]; throws surfaceLost when it cannot be created (e.g. still connected to a player). */
    fun createWindow(surface: Surface): EGLSurface {
        val s = EGL14.eglCreateWindowSurface(display, config, surface, intArrayOf(EGL14.EGL_NONE), 0)
        if (s == null || s == EGL14.EGL_NO_SURFACE) {
            throw EngineException(EngineErrorCode.surfaceLost, "eglCreateWindowSurface failed 0x${Integer.toHexString(EGL14.eglGetError())}")
        }
        return s
    }

    /** Makes the context current on [surface] (null = the pbuffer) unless it already is. */
    fun makeCurrent(surface: EGLSurface?) {
        val s = surface ?: pbuffer
        if (EGL14.eglGetCurrentContext() == context && EGL14.eglGetCurrentSurface(EGL14.EGL_DRAW) == s) return
        if (!EGL14.eglMakeCurrent(display, s, s, context)) {
            throw EngineException(EngineErrorCode.gpuUnavailable, "eglMakeCurrent failed 0x${Integer.toHexString(EGL14.eglGetError())}")
        }
    }

    fun release() {
        EGL14.eglMakeCurrent(display, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_CONTEXT)
        EGL14.eglDestroySurface(display, pbuffer)
        EGL14.eglDestroyContext(display, context)
        // eglTerminate is not called: the default display is shared with every other EGL user of the process.
    }
}
